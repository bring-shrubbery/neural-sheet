// The decode step's attention, split out of MetalShaderSource.swift because it is one kernel
// standing in for three and the reason it is shaped the way it is takes a page. ggml does the
// same fusion in `kernel_flash_attn_ext`, for the same reason: at one query row the scores are
// a single row of the cache's length, and writing that row to device memory so that two more
// kernels can read it back is most of the work.
//
// `attn_scores`, `softmax_rows` and `attn_values` in MetalShaderSource stay for the prefill,
// where the scores are an `nNew x nKV` block that does not fit in threadgroup memory and the
// causal mask matters. @see MetalKernels.attentionDecode

extension MetalShaderSource {
    /// The threadgroup `attn_decode` is dispatched with.
    ///
    /// The kernel puts one threadgroup on each head, and a checkpoint has only twelve to
    /// twenty-four of those against this machine's nineteen GPU cores, so the threadgroup is
    /// all the parallelism there is: how many key rows the score phase has in flight and how
    /// many cached rows the value phase reads at once are both set by it. Measured over
    /// `medium`'s twenty-four layers of one decode step at nKV = 601, best of thirty command
    /// buffers: 5.32 ms at 128 threads, 2.76 at 256, 1.52 at 512 and 0.98 at 1024. It is a
    /// power of two because the reduction tree halves it, and a multiple of the checkpoints'
    /// 64-wide head so that the value blocks divide it evenly.
    ///
    /// 1024 is the most Metal allows in a threadgroup at all, and a device or a driver that
    /// will not run that many of *this* kernel falls back to the three it replaces rather than
    /// failing. @see MetalKernels.canFuseAttention
    static let attentionThreads = 1024

    /// Appended to `core`, so `AttentionParams` and the includes are in scope.
    static let attention = """

        // The threadgroup, from MetalShaderSource.attentionThreads. A macro rather than a
        // parameter because it sizes the reduction array and the tree below halves it, so it
        // has to be a power of two known at compile time. The Swift dispatches exactly this
        // many threads.
        #define ATTN_THREADS \(attentionThreads)

        /// Scores, softmax and values for a single query row, one threadgroup per head.
        ///
        /// Only for `nNew == 1`, and that is what makes it this short. The one query sits at
        /// position `nPast`, so every cached row `0 ... nPast` is allowed and there is no mask
        /// to apply: `nKV` is `nPast + 1` exactly. The score row is `nKV` floats -- at most
        /// 2538, the engine's whole context, or 10 kB -- so it lives in threadgroup memory for
        /// the softmax instead of going out to device memory and being read back twice.
        ///
        /// The three kernels it replaces cost 3.87 ms of `small`'s 5.66 ms decode step, and
        /// almost all of that was `attn_values`: a thread per (channel, query, head) is 768
        /// threads for the whole GPU, and each walked the cache with a stride of `dim`, so
        /// every 128-byte line it fetched carried one useful float. Here a block of `headDim`
        /// consecutive threads reads one cached row's slice of the head in one go,
        /// ATTN_THREADS / headDim such blocks share the rows between them, and their partial
        /// sums are combined at the end. The scores are blocked the other way round -- one
        /// simdgroup per key row, its lanes striding the head -- which makes that read
        /// contiguous too.
        ///
        /// Measured over one decode step at nKV = 601, best of thirty command buffers, against
        /// the three kernels on the same shape: `small` 3.87 ms -> 0.54 ms, `medium`
        /// 6.03 -> 0.99, `large` 13.49 -> 2.39. `medium`'s 4.9 MB of cache per layer arrives at
        /// 121 GB/s of the machine's 200, where the three kernels managed 20.
        ///
        /// Every sum here is in a different order from the three kernels' -- a lane-strided
        /// `simd_sum` for a score, interleaved block partials for a channel -- and F32
        /// throughout, as ggml is. The token streams are the gate on that, and the oracle
        /// dumps for all three checkpoints are unchanged by it.
        ///
        /// `row` is `nKV` floats of threadgroup memory, bound by the dispatch.
        kernel void attn_decode(
            device const float *qkv [[buffer(0)]],
            device const float *keys [[buffer(1)]],
            device const float *values [[buffer(2)]],
            device float *out [[buffer(3)]],
            constant AttentionParams &p [[buffer(4)]],
            threadgroup float *row [[threadgroup(0)]],
            uint head [[threadgroup_position_in_grid]],
            uint tid [[thread_position_in_threadgroup]],
            uint sg [[simdgroup_index_in_threadgroup]],
            uint lane [[thread_index_in_simdgroup]],
            uint width [[threads_per_simdgroup]],
            uint simdgroups [[simdgroups_per_threadgroup]])
        {
            threadgroup float partial[ATTN_THREADS];

            // The head is a column slice of a wider row in all three operands, and the query
            // is row 0 of the projection because there is only one.
            const uint channel = head * p.headDim;
            device const float *q = qkv + channel;

            for (uint j = sg; j < p.nKV; j += simdgroups) {
                device const float *k = keys + (ulong)j * p.dim + channel;

                float part = 0.0f;
                for (uint d = lane; d < p.headDim; d += width) {
                    part = fma(q[d], k[d], part);
                }

                const float total = simd_sum(part);

                if (lane == 0) {
                    row[j] = total * p.scale;
                }
            }

            threadgroup_barrier(mem_flags::mem_threadgroup);

            float highest = -INFINITY;
            for (uint i = tid; i < p.nKV; i += ATTN_THREADS) {
                highest = max(highest, row[i]);
            }

            partial[tid] = highest;
            threadgroup_barrier(mem_flags::mem_threadgroup);

            for (uint stride = ATTN_THREADS / 2; stride > 0; stride >>= 1) {
                if (tid < stride) {
                    partial[tid] = max(partial[tid], partial[tid + stride]);
                }
                threadgroup_barrier(mem_flags::mem_threadgroup);
            }

            const float maximum = partial[0];

            // Every thread has to have read partial[0] before the sum overwrites it.
            threadgroup_barrier(mem_flags::mem_threadgroup);

            float sum = 0.0f;
            for (uint i = tid; i < p.nKV; i += ATTN_THREADS) {
                const float weight = exp(row[i] - maximum);
                row[i] = weight;
                sum += weight;
            }

            partial[tid] = sum;
            threadgroup_barrier(mem_flags::mem_threadgroup);

            for (uint stride = ATTN_THREADS / 2; stride > 0; stride >>= 1) {
                if (tid < stride) {
                    partial[tid] += partial[tid + stride];
                }
                threadgroup_barrier(mem_flags::mem_threadgroup);
            }

            const float inverse = 1.0f / partial[0];

            for (uint i = tid; i < p.nKV; i += ATTN_THREADS) {
                row[i] *= inverse;
            }

            // Both because the accumulation below reads the whole normalised row, and because
            // it is about to overwrite the reduction array every thread has just read from.
            threadgroup_barrier(mem_flags::mem_threadgroup);

            // `headDim` consecutive threads per cached row, so the slice of the head they read
            // is one contiguous run; `blocks` such groups share the rows between them. The
            // Swift only dispatches this kernel when `headDim` is at most the threadgroup, so
            // there is always at least one block, and the threads past the last one idle.
            const uint blocks = ATTN_THREADS / p.headDim;
            const uint block = tid / p.headDim;
            const uint channelInHead = tid - block * p.headDim;

            float accumulator = 0.0f;

            if (block < blocks) {
                device const float *v = values + channel + channelInHead;

                for (uint j = block; j < p.nKV; j += blocks) {
                    accumulator = fma(row[j], v[(ulong)j * p.dim], accumulator);
                }
            }

            partial[tid] = accumulator;
            threadgroup_barrier(mem_flags::mem_threadgroup);

            if (tid < p.headDim) {
                float total = 0.0f;

                for (uint b = 0; b < blocks; ++b) {
                    total += partial[b * p.headDim + tid];
                }

                out[channel + tid] = total;
            }
        }

        // This fragment is concatenated with the others, so the macro would otherwise stay
        // defined for them.
        #undef ATTN_THREADS
        """
}
