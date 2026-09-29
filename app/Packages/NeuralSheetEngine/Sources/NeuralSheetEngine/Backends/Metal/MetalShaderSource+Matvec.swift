// The decode step's matrix product, split out of MetalShaderSource.swift because it is where
// nearly all of a token's time goes and it has a blocking strategy of its own to explain.
// ggml's equivalent is `kernel_mul_mv_f16_f32` in ggml/src/ggml-metal/ggml-metal.metal, which
// blocks the same two ways: several weight rows per simdgroup and a short vector of halves per
// lane.

extension MetalShaderSource {
    /// How `matvec_f16` blocks the weight: a simdgroup reduces `rows` output rows at once and
    /// a threadgroup holds `simdgroups` of them.
    ///
    /// One definition, interpolated into the MSL below and read by `MetalKernels` for the grid
    /// and the threadgroup it dispatches -- the kernel unrolls over both numbers, so a Swift
    /// side that disagreed would leave rows unwritten or read a simdgroup's worth of weight
    /// nobody asked for, quietly.
    struct MatvecBlock: Sendable {
        /// `MATVEC_ROWS`, the output rows one simdgroup reduces.
        var rows: Int

        /// `MATVEC_SIMDGROUPS`, the simdgroups in one threadgroup.
        var simdgroups: Int

        /// The output rows one threadgroup covers.
        var rowsPerGroup: Int { rows * simdgroups }
    }

    /// Four rows and four simdgroups: on a plateau rather than a peak. Measured on an M2 Pro
    /// over `rows` in one, two, four and eight against `simdgroups` in two, four and eight --
    /// `medium`'s twenty-four `attn_qkv` products, best of thirty command buffers -- every
    /// shape with four or more simdgroups' worth of threads lands within five per cent of
    /// 0.89 ms, and only (1, 2) is clearly worse at 1.04 ms. The widened load below is what
    /// buys the speed; the row blocking is what stops the reduction being paid per output.
    static let matvecBlock = MatvecBlock(rows: 4, simdgroups: 4)

    /// Appended to `core`, so `MatmulParams` and the includes are in scope.
    static let matvec = """

        // How `matvec_f16` blocks the weight, from MetalShaderSource.matvecBlock. Macros
        // rather than constants because the inner loops are unrolled over them, and the
        // Swift dispatches the threadgroup they imply. @see MetalShaderSource.MatvecBlock
        #define MATVEC_ROWS \(matvecBlock.rows)
        #define MATVEC_SIMDGROUPS \(matvecBlock.simdgroups)

        /// `out = W . x` for a single input row: MATVEC_ROWS output rows per simdgroup,
        /// four halves per lane per load.
        ///
        /// This is the decode step's whole cost: the model's F16 weights streamed once per
        /// token -- 200 MB for `small`, 2.7 GB for `large` -- so what matters is how close
        /// to the machine's bandwidth the weight arrives, and that is set by how much each
        /// load instruction fetches and how many of them are in flight at once.
        ///
        /// One row per simdgroup with one `half` per lane per iteration, which this was,
        /// measured 64 GB/s of the M2 Pro's 200: a 32-lane load of 64 bytes is one cache
        /// line per instruction, the `simd_sum` that ends each row is paid once per output,
        /// and a 32-thread threadgroup occupies a core's scheduling slot for very little
        /// work. Reading a `half4` per lane fetches four lines per instruction; folding
        /// MATVEC_ROWS rows into one simdgroup shares each `float4` of `x` across them,
        /// keeps that many independent load streams in flight, and amortises the reduction;
        /// and MATVEC_SIMDGROUPS of those per threadgroup is what fills a core.
        /// Measured over every matvec of one decode step at nKV = 601, best of thirty command
        /// buffers: 1.57 ms against 3.15 ms for `small`, 3.63 against 5.78 for `medium` and
        /// 15.7 against 24.1 for `large` -- 127 GB/s of the machine's 200 for `small`, where it
        /// was 64.
        ///
        /// The accumulation is an explicit chain of `fma` up the four lanes of each block
        /// rather than `dot`, whose order MSL does not fix, so the result is the same bits
        /// on every device and every build; the lanes' partial sums are strided by
        /// `4 . simdWidth` and combined by `simd_sum`, which is a different order from the
        /// one-half-per-lane version's but no less accurate, and the token streams are the
        /// gate on that.
        ///
        /// A `half4` load needs eight-byte alignment and a `float4` sixteen: the weight
        /// rows are `inFeatures` apart with `inFeatures` a multiple of 32 in every
        /// checkpoint, tensor offsets are bound at sixteen (MetalBackend.offset), and the
        /// activation buffers are bound at zero, so the quad loop below is always aligned
        /// when it runs at all. `inFeatures` that is not a multiple of four leaves a tail,
        /// which one lane adds after the reduction so that the order stays fixed.
        kernel void matvec_f16(
            device const half *weights [[buffer(0)]],
            device const float *x [[buffer(1)]],
            device float *out [[buffer(2)]],
            constant MatmulParams &p [[buffer(3)]],
            uint group [[threadgroup_position_in_grid]],
            uint sg [[simdgroup_index_in_threadgroup]],
            uint lane [[thread_index_in_simdgroup]],
            uint width [[threads_per_simdgroup]])
        {
            const uint rowBase = (group * MATVEC_SIMDGROUPS + sg) * MATVEC_ROWS;

            if (rowBase >= p.outFeatures) {
                return;
            }

            // Each block's rows, clamped to the last one that exists. An `outFeatures` that
            // is not a multiple of the block -- the LM head's 1395 -- would otherwise have its
            // final simdgroup read a row past the tensor, which the guarded store makes
            // harmless but which may be past the buffer as well.
            device const half *rows[MATVEC_ROWS];
            float accumulator[MATVEC_ROWS];

            for (uint r = 0; r < MATVEC_ROWS; ++r) {
                rows[r] = weights + (ulong)min(rowBase + r, p.outFeatures - 1) * p.inFeatures;
                accumulator[r] = 0.0f;
            }

            // The quad loop runs only when the row is a whole number of `half4`s, as
            // `layer_norm`'s `float4` loop does: an `inFeatures` that is not a multiple of four
            // puts the *next* row at an eight-byte offset that is not a multiple of eight, so
            // the vector load would be misaligned rather than merely short. No checkpoint has
            // one -- every shape is a multiple of 32 -- and the scalar tail below covers it.
            const uint quads = (p.inFeatures % 4 == 0) ? p.inFeatures / 4 : 0;

            for (uint q = lane; q < quads; q += width) {
                const uint i = q * 4;
                const float4 xv = *(device const float4 *)(x + i);

                for (uint r = 0; r < MATVEC_ROWS; ++r) {
                    const half4 wv = *(device const half4 *)(rows[r] + i);
                    float sum = accumulator[r];
                    sum = fma(float(wv.x), xv.x, sum);
                    sum = fma(float(wv.y), xv.y, sum);
                    sum = fma(float(wv.z), xv.z, sum);
                    sum = fma(float(wv.w), xv.w, sum);
                    accumulator[r] = sum;
                }
            }

            for (uint r = 0; r < MATVEC_ROWS; ++r) {
                float total = simd_sum(accumulator[r]);

                // The checkpoints' shapes are all multiples of 32, so this tail never runs
                // there; it is here so that a shape that is not cannot fail quietly. One lane
                // adds it, after the reduction, so the order does not depend on the width.
                if (lane == 0) {
                    for (uint i = quads * 4; i < p.inFeatures; ++i) {
                        total = fma(float(rows[r][i]), x[i], total);
                    }

                    if (rowBase + r < p.outFeatures) {
                        out[rowBase + r] = total;
                    }
                }
            }
        }

        // This fragment is concatenated with the GEMM's, so the macros would otherwise stay
        // defined for it.
        #undef MATVEC_ROWS
        #undef MATVEC_SIMDGROUPS
        """
}
