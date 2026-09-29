// The prefill's attention: the two matrix products around the softmax, tiled over
// `simdgroup_float8x8` the way MetalShaderSource+GEMM tiles the weights.
//
// At 504 query rows both products are real GEMMs -- 504 x 504 x 64 per head for the scores and
// 504 x 64 x 504 for the values -- and `attn_scores` and `attn_values` are not written as GEMMs
// at all: a thread per output element, walking both operands out of device memory for one dot
// product. Measured on `large`, 218 ms and 115 ms of a 912 ms prefill, which is 0.34 TFLOP/s
// where the same device does 2.4 on the weights. These two are the same arithmetic blocked the
// same way as the GEMM, plus the causal mask, which also lets a tile entirely above the
// diagonal skip its multiplication altogether.
//
// The three kernels they replace stay: `attn_decode` handles a decode step, and `softmax_rows`
// still runs between these two. @see MetalShaderSource+Attention, MetalKernels.attentionScores

extension MetalShaderSource {
    /// How the two kernels below block their output, in the same terms as `gemmTile`.
    ///
    /// 32 x 64 over four simdgroups, each holding 2 x 4 accumulators, which is the accumulator
    /// budget the GEMM found: eight `simdgroup_float8x8` per simdgroup is what fits before they
    /// spill. The output block is staged through the same threadgroup memory the operands use,
    /// so it is the smaller of the two tiles that sets the allocation -- 8 kB here -- and both
    /// kernels have an epilogue over the block anyway, for the mask and the scale in one and
    /// for a `nKV` that is not a multiple of eight in the other.
    ///
    /// `features` is 64, which is every checkpoint's `headDim`, so the value product's output
    /// is exactly one tile wide.
    static let attentionTile = GEMMTile(
        rows: 32, features: 64, depth: 16, simdgroupRows: 2, simdgroupColumns: 2)

    /// The threadgroup floats both kernels need. Not `GEMMTile.threadgroupFloats`: these two
    /// stage the *whole* output block rather than one 8 x 8 block per simdgroup, because both
    /// have an epilogue over every element of it, so it is the block and not the operands that
    /// sets the allocation -- 2048 floats, 8 kB.
    static var attentionStageFloats: Int {
        max(
            attentionTile.rows * attentionTile.depth + attentionTile.depth * attentionTile.features,
            attentionTile.rows * attentionTile.features)
    }

    /// Appended to `core`, so `AttentionParams` and the includes are in scope.
    static let prefillAttention = """

        // The tile, from MetalShaderSource.attentionTile. @see MetalShaderSource+GEMM
        #define ATT_TM \(attentionTile.rows)
        #define ATT_TN \(attentionTile.features)
        #define ATT_TK \(attentionTile.depth)
        #define ATT_SM \(attentionTile.simdgroupRows)
        #define ATT_SN \(attentionTile.simdgroupColumns)
        #define ATT_THREADS \(attentionTile.threads)
        #define ATT_AM (ATT_TM / ATT_SM / 8)
        #define ATT_AN (ATT_TN / ATT_SN / 8)
        #define ATT_STAGE \(attentionStageFloats)

        /// The scaled, causally masked attention scores, a 32 x 64 tile of (query, key) per
        /// threadgroup and one head per grid slice.
        ///
        /// `out[q][j] = scale . sum_d q[q][d] . K[j][d]`, so the key operand is transposed;
        /// `simdgroup_load` transposes an 8 x 8 block on the way in, which is why the staging
        /// below writes the depth on the rows and the key on the columns.
        ///
        /// The mask is bottom-right causal: query row `i` sits at position `nPast + i`, so it
        /// may attend to cache rows `0 ... nPast + i` and no further. A tile whose first key is
        /// past the last query's position is wholly masked and returns without multiplying
        /// anything, which is most of the upper triangle: at nNew = nKV = 504 it is a little
        /// under half of the tiles.
        kernel void attn_scores_tiled(
            device const float *qkv [[buffer(0)]],
            device const float *keys [[buffer(1)]],
            device float *scores [[buffer(2)]],
            constant AttentionParams &p [[buffer(3)]],
            uint3 group [[threadgroup_position_in_grid]],
            uint tid [[thread_index_in_threadgroup]],
            uint sg [[simdgroup_index_in_threadgroup]])
        {
            threadgroup float staged[ATT_STAGE];
            threadgroup float *aTile = staged;
            threadgroup float *bTile = staged + ATT_TM * ATT_TK;

            const uint rowBase = group.y * ATT_TM;
            const uint colBase = group.x * ATT_TN;
            const uint head = group.z;
            const uint channel = head * p.headDim;
            const uint qStride = 3 * p.dim;

            device float *out = scores + ((ulong)head * p.nNew + rowBase) * p.nKV + colBase;

            // Wholly above the diagonal: every (query, key) in the tile is masked.
            if (colBase > p.nPast + rowBase + ATT_TM - 1) {
                for (uint e = tid; e < ATT_TM * ATT_TN; e += ATT_THREADS) {
                    const uint m = e / ATT_TN;
                    const uint n = e % ATT_TN;

                    if (rowBase + m < p.nNew && colBase + n < p.nKV) {
                        out[(ulong)m * p.nKV + n] = -INFINITY;
                    }
                }

                return;
            }

            const uint sgRow = sg / ATT_SN;
            const uint sgCol = sg % ATT_SN;

            simdgroup_float8x8 acc[ATT_AM][ATT_AN];
            for (uint i = 0; i < ATT_AM; ++i) {
                for (uint j = 0; j < ATT_AN; ++j) {
                    acc[i][j] = make_filled_simdgroup_matrix<float, 8, 8>(0.0f);
                }
            }

            const uint depth = p.headDim & ~7u;

            for (uint dBase = 0; dBase < depth; dBase += ATT_TK) {
                // Both operands have the depth contiguous in device memory, so the depth goes
                // on the fast axis of both staging loops and consecutive threads read
                // consecutive addresses. The 8 x 8 blocks are laid out contiguously, which is
                // the layout `simdgroup_load` reads at its default stride.
                for (uint e = tid; e < ATT_TM * ATT_TK; e += ATT_THREADS) {
                    const uint d = e % ATT_TK;
                    const uint m = e / ATT_TK;
                    const uint block = (d / 8) * (ATT_TM / 8) + m / 8;
                    aTile[block * 64 + (m % 8) * 8 + d % 8] =
                        (rowBase + m < p.nNew && dBase + d < depth)
                        ? qkv[(ulong)(rowBase + m) * qStride + channel + dBase + d] : 0.0f;
                }

                for (uint e = tid; e < ATT_TN * ATT_TK; e += ATT_THREADS) {
                    const uint d = e % ATT_TK;
                    const uint n = e / ATT_TK;
                    const uint block = (d / 8) * (ATT_TN / 8) + n / 8;
                    // Transposed on the way in: the block holds K[key][depth], and the product
                    // wants B[depth][key].
                    bTile[block * 64 + (n % 8) * 8 + d % 8] =
                        (colBase + n < p.nKV && dBase + d < depth)
                        ? keys[(ulong)(colBase + n) * p.dim + channel + dBase + d] : 0.0f;
                }

                threadgroup_barrier(mem_flags::mem_threadgroup);

                for (uint d = 0; d < ATT_TK; d += 8) {
                    threadgroup const float *aBlocks = aTile + (d / 8) * ATT_TM * 8;
                    threadgroup const float *bBlocks = bTile + (d / 8) * ATT_TN * 8;

                    simdgroup_float8x8 a[ATT_AM];
                    simdgroup_float8x8 b[ATT_AN];

                    for (uint i = 0; i < ATT_AM; ++i) {
                        simdgroup_load(a[i], aBlocks + (sgRow * ATT_AM + i) * 64);
                    }

                    simdgroup_barrier(mem_flags::mem_none);

                    for (uint j = 0; j < ATT_AN; ++j) {
                        simdgroup_load(b[j], bBlocks + (sgCol * ATT_AN + j) * 64, 8, ulong2(0), true);
                    }

                    for (uint i = 0; i < ATT_AM; ++i) {
                        for (uint j = 0; j < ATT_AN; ++j) {
                            simdgroup_multiply_accumulate(acc[i][j], a[i], b[j], acc[i][j]);
                        }
                    }
                }

                threadgroup_barrier(mem_flags::mem_threadgroup);
            }

            for (uint i = 0; i < ATT_AM; ++i) {
                for (uint j = 0; j < ATT_AN; ++j) {
                    simdgroup_store(
                        acc[i][j], staged, ATT_TN,
                        ulong2((sgCol * ATT_AN + j) * 8, (sgRow * ATT_AM + i) * 8));
                }
            }

            threadgroup_barrier(mem_flags::mem_threadgroup);

            for (uint e = tid; e < ATT_TM * ATT_TN; e += ATT_THREADS) {
                const uint m = e / ATT_TN;
                const uint n = e % ATT_TN;
                const uint query = rowBase + m;
                const uint key = colBase + n;

                if (query >= p.nNew || key >= p.nKV) {
                    continue;
                }

                if (key > p.nPast + query) {
                    out[(ulong)m * p.nKV + n] = -INFINITY;
                    continue;
                }

                float value = staged[e];

                // A `headDim` that is not a multiple of eight leaves a tail the blocks above
                // cannot cover. No checkpoint has one -- all three are 64 -- so this never runs
                // there; it is here so that one that did could not fail quietly.
                for (uint d = depth; d < p.headDim; ++d) {
                    value = fma(
                        qkv[(ulong)query * qStride + channel + d],
                        keys[(ulong)key * p.dim + channel + d], value);
                }

                out[(ulong)m * p.nKV + n] = value * p.scale;
            }
        }

        /// The weighted sum of the cached values, a 32 x 64 tile of (query, channel) per
        /// threadgroup and one head per grid slice.
        ///
        /// `out[q][d] = sum_j P[q][j] . V[j][d]`, with both operands already in the layout the
        /// product wants: the probabilities have the key contiguous and the cache has the
        /// channel contiguous, so nothing is transposed.
        ///
        /// The masked columns of P are exactly zero, so the rows of the cache past a query's
        /// own position contribute nothing and need no special case.
        kernel void attn_values_tiled(
            device const float *scores [[buffer(0)]],
            device const float *values [[buffer(1)]],
            device float *out [[buffer(2)]],
            constant AttentionParams &p [[buffer(3)]],
            uint3 group [[threadgroup_position_in_grid]],
            uint tid [[thread_index_in_threadgroup]],
            uint sg [[simdgroup_index_in_threadgroup]])
        {
            threadgroup float staged[ATT_STAGE];
            threadgroup float *aTile = staged;
            threadgroup float *bTile = staged + ATT_TM * ATT_TK;

            const uint rowBase = group.y * ATT_TM;
            const uint colBase = group.x * ATT_TN;
            const uint head = group.z;
            const uint channel = head * p.headDim;

            device const float *probabilities = scores + ((ulong)head * p.nNew + rowBase) * p.nKV;

            const uint sgRow = sg / ATT_SN;
            const uint sgCol = sg % ATT_SN;

            simdgroup_float8x8 acc[ATT_AM][ATT_AN];
            for (uint i = 0; i < ATT_AM; ++i) {
                for (uint j = 0; j < ATT_AN; ++j) {
                    acc[i][j] = make_filled_simdgroup_matrix<float, 8, 8>(0.0f);
                }
            }

            const uint depth = p.nKV & ~7u;

            for (uint kBase = 0; kBase < depth; kBase += ATT_TK) {
                for (uint e = tid; e < ATT_TM * ATT_TK; e += ATT_THREADS) {
                    const uint k = e % ATT_TK;
                    const uint m = e / ATT_TK;
                    const uint block = (k / 8) * (ATT_TM / 8) + m / 8;
                    aTile[block * 64 + (m % 8) * 8 + k % 8] =
                        (rowBase + m < p.nNew && kBase + k < depth)
                        ? probabilities[(ulong)m * p.nKV + kBase + k] : 0.0f;
                }

                // The cache has the channel contiguous, so here it is the *channel* that goes
                // on the fast axis of the staging loop.
                for (uint e = tid; e < ATT_TN * ATT_TK; e += ATT_THREADS) {
                    const uint n = e % ATT_TN;
                    const uint k = e / ATT_TN;
                    const uint block = (k / 8) * (ATT_TN / 8) + n / 8;
                    bTile[block * 64 + (k % 8) * 8 + n % 8] =
                        (colBase + n < p.headDim && kBase + k < depth)
                        ? values[(ulong)(kBase + k) * p.dim + channel + colBase + n] : 0.0f;
                }

                threadgroup_barrier(mem_flags::mem_threadgroup);

                for (uint k = 0; k < ATT_TK; k += 8) {
                    threadgroup const float *aBlocks = aTile + (k / 8) * ATT_TM * 8;
                    threadgroup const float *bBlocks = bTile + (k / 8) * ATT_TN * 8;

                    simdgroup_float8x8 a[ATT_AM];
                    simdgroup_float8x8 b[ATT_AN];

                    for (uint i = 0; i < ATT_AM; ++i) {
                        simdgroup_load(a[i], aBlocks + (sgRow * ATT_AM + i) * 64);
                    }

                    simdgroup_barrier(mem_flags::mem_none);

                    for (uint j = 0; j < ATT_AN; ++j) {
                        simdgroup_load(b[j], bBlocks + (sgCol * ATT_AN + j) * 64);
                    }

                    for (uint i = 0; i < ATT_AM; ++i) {
                        for (uint j = 0; j < ATT_AN; ++j) {
                            simdgroup_multiply_accumulate(acc[i][j], a[i], b[j], acc[i][j]);
                        }
                    }
                }

                threadgroup_barrier(mem_flags::mem_threadgroup);
            }

            for (uint i = 0; i < ATT_AM; ++i) {
                for (uint j = 0; j < ATT_AN; ++j) {
                    simdgroup_store(
                        acc[i][j], staged, ATT_TN,
                        ulong2((sgCol * ATT_AN + j) * 8, (sgRow * ATT_AM + i) * 8));
                }
            }

            threadgroup_barrier(mem_flags::mem_threadgroup);

            for (uint e = tid; e < ATT_TM * ATT_TN; e += ATT_THREADS) {
                const uint m = e / ATT_TN;
                const uint n = e % ATT_TN;
                const uint query = rowBase + m;

                if (query >= p.nNew || colBase + n >= p.headDim) {
                    continue;
                }

                float value = staged[e];

                // An `nKV` that is not a multiple of eight leaves a tail. A prefill's window is
                // 502 to 504 positions depending on the conditioning rows, so unlike the other
                // kernel's tail this one does run.
                for (uint k = depth; k < p.nKV; ++k) {
                    value = fma(
                        probabilities[(ulong)m * p.nKV + k],
                        values[(ulong)k * p.dim + channel + colBase + n], value);
                }

                out[(ulong)query * p.dim + channel + colBase + n] = value;
            }
        }

        #undef ATT_TM
        #undef ATT_TN
        #undef ATT_TK
        #undef ATT_SM
        #undef ATT_SN
        #undef ATT_THREADS
        #undef ATT_AM
        #undef ATT_AN
        #undef ATT_STAGE
        """
}
