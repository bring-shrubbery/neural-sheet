// The prefill's matrix product, split out of MetalShaderSource.swift because it is the one
// kernel in the library with a blocking strategy of its own to explain. ggml's equivalent is
// `kernel_mul_mm` in ggml/src/ggml-metal/ggml-metal.metal, which blocks it the same way and
// through the same instruction.

extension MetalShaderSource {
    /// How `matmul_tiled_f16` blocks the output: a threadgroup owns a `rows` x `features` block
    /// and walks K in steps of `depth`, and the `simdgroupRows` x `simdgroupColumns` simdgroups
    /// in it each own one rectangle of that block as a grid of 8 x 8 accumulators.
    ///
    /// One definition, interpolated into the MSL below and read by `MetalKernels` for the grid
    /// and the threadgroup it dispatches. It was two -- these numbers and a matching set of
    /// `#define`s -- held together by a comment, and the two disagreeing is not a compile
    /// error: too few threads leaves part of every tile unwritten, too many reads threadgroup
    /// memory nothing staged, and either way the wrong answer comes back quietly.
    struct GEMMTile: Sendable {
        /// `GEMM_TM`, the rows of the output one threadgroup owns. A multiple of
        /// `8 . simdgroupRows`.
        var rows: Int

        /// `GEMM_TN`, the output features one threadgroup owns. A multiple of
        /// `8 . simdgroupColumns`.
        var features: Int

        /// `GEMM_TK`, how far into K one staged pass reaches. A multiple of eight.
        var depth: Int

        /// `GEMM_SM`, the simdgroups down the tile.
        var simdgroupRows: Int

        /// `GEMM_SN`, the simdgroups across it.
        var simdgroupColumns: Int

        /// `GEMM_THREADS`, and so the threadgroup size the kernel must be dispatched with.
        /// A simdgroup is 32 lanes wide, which is what `simdgroup_float8x8` is defined over
        /// and what MetalKernels checks the device agrees with.
        var threads: Int { simdgroupRows * simdgroupColumns * 32 }

        /// The threadgroup floats the kernel needs: the two staged operands while it walks K,
        /// and, afterwards, one 8 x 8 block per simdgroup to bounds-check the store through.
        var threadgroupFloats: Int {
            max(rows * depth, simdgroupRows * simdgroupColumns * 64)
        }
    }

    /// The shape measured fastest on an M2 Pro, over `medium`'s `attn_qkv` and `ffn_up` at 504
    /// rows: a 64 x 64 tile over eight simdgroups, each holding 2 x 4 accumulators. Doubling
    /// either side of the tile, halving it, or a depth of 8 or 32 instead of 16 is 2 to 27 per
    /// cent worse. The eight accumulators are the budget -- sixteen spill to device memory and
    /// cost seven times as much. @see docs/design/2026-09-29-swift-engine-plan.md
    static let gemmTile = GEMMTile(
        rows: 64, features: 64, depth: 16, simdgroupRows: 4, simdgroupColumns: 2)

    /// Appended to `core`, so the `MatmulParams` struct and the includes above are in scope.
    static let gemm = """

        // The tile, from MetalShaderSource.gemmTile. Macros rather than constants because
        // they size the threadgroup arrays below and the inner loops are unrolled over them.
        #define GEMM_TM \(gemmTile.rows)
        #define GEMM_TN \(gemmTile.features)
        #define GEMM_TK \(gemmTile.depth)
        #define GEMM_SM \(gemmTile.simdgroupRows)
        #define GEMM_SN \(gemmTile.simdgroupColumns)
        #define GEMM_THREADS \(gemmTile.threads)

        // The 8 x 8 accumulators one simdgroup owns, down and across.
        #define GEMM_AM (GEMM_TM / GEMM_SM / 8)
        #define GEMM_AN (GEMM_TN / GEMM_SN / 8)

        /// `out = X . Wt` for several input rows: a tiled GEMM over `simdgroup_float8x8`.
        ///
        /// A thread per output element -- the obvious kernel -- reads the weight `inFeatures`
        /// apart across the lanes of a simdgroup, so every lane pulls its own cache line;
        /// splitting one dot product across a simdgroup's lanes instead makes those reads
        /// contiguous but reads the whole of both operands once per output element and spends
        /// most of its instructions on the `simd_sum` that ends each one. Measured at the
        /// prefill's 504 rows it reached about 0.47 TFLOP/s, a fifteenth of this device's peak.
        ///
        /// Staging both operands through threadgroup memory and giving each *thread* a square
        /// of the output was the next step and is what this kernel was: it fixes the arithmetic
        /// intensity and reached 1.6 TFLOP/s, but it cannot go further, because the square has
        /// to stay 4 x 4. Measured over `medium`'s twenty-four `attn_qkv` products at 504 rows,
        /// 8 x 8 outputs per thread costs 590 ms against 49 -- twelve times worse, not four --
        /// because sixty-four accumulators plus the operands and the addresses do not fit in a
        /// thread's registers and spill to device memory.
        ///
        /// What breaks that ceiling is holding the accumulators in the simdgroup's matrix
        /// registers instead of each thread's, which is what `simdgroup_float8x8` is: one
        /// `simdgroup_multiply_accumulate` is a whole 8 x 8 x 8 product, so a simdgroup keeps
        /// GEMM_AM x GEMM_AN of them -- 1024 accumulated values over 32 lanes here -- and the
        /// inner loop is GEMM_AM + GEMM_AN threadgroup loads for GEMM_AM x GEMM_AN products.
        /// ggml's `kernel_mul_mm` is the same instruction on the same reasoning.
        ///
        /// Measured over `medium`'s prefill at 504 rows, best of thirty command buffers:
        /// `attn_qkv` 49.2 ms -> 25.1 and `ffn_up` 65.6 -> 33.4, which is 1.6 TFLOP/s against
        /// 3.0.
        ///
        /// The accumulation is F32, as `GGML_PREC_F32` asks, and runs straight up K in staged
        /// passes; within one 8 x 8 x 8 product the order of the eight terms is the hardware's,
        /// which is why MetalGEMMTests compares against a reference in the same shape rather
        /// than against a scalar loop. The token streams are the gate on the difference, and
        /// the Metal oracle fixtures for all three checkpoints are unchanged by it.
        kernel void matmul_tiled_f16(
            device const half *weights [[buffer(0)]],
            device const float *x [[buffer(1)]],
            device float *out [[buffer(2)]],
            constant MatmulParams &p [[buffer(3)]],
            uint2 group [[threadgroup_position_in_grid]],
            uint tid [[thread_index_in_threadgroup]],
            uint sg [[simdgroup_index_in_threadgroup]])
        {
            // One allocation for both phases: the staged operands while the kernel walks K,
            // then one 8 x 8 block per simdgroup for the store, which needs somewhere to land
            // that a thread can bounds-check because `simdgroup_store` cannot.
            threadgroup float staged[\(gemmTile.threadgroupFloats)];
            threadgroup half bTile[GEMM_TK * GEMM_TN];
            threadgroup float *aTile = staged;

            const uint rowBase = group.y * GEMM_TM;
            const uint colBase = group.x * GEMM_TN;

            // The simdgroups tile the block, GEMM_SM down by GEMM_SN across.
            const uint sgRow = sg / GEMM_SN;
            const uint sgCol = sg % GEMM_SN;

            simdgroup_float8x8 acc[GEMM_AM][GEMM_AN];
            for (uint i = 0; i < GEMM_AM; ++i) {
                for (uint j = 0; j < GEMM_AN; ++j) {
                    acc[i][j] = make_filled_simdgroup_matrix<float, 8, 8>(0.0f);
                }
            }

            // The device reads of one staged pass are issued while the simdgroups are still
            // multiplying the pass before it: a thread keeps its share of the next pass in
            // registers -- GEMM_TM . GEMM_TK / GEMM_THREADS of A and as many of B -- and only
            // writes it into the tiles once every simdgroup is done reading them. Without this
            // the loads are serialised behind the products, which measured 31.0 ms against the
            // 25.2 ms the same kernel takes with the loads elided altogether.
            #define GEMM_APER (GEMM_TM * GEMM_TK / GEMM_THREADS)
            #define GEMM_BPER (GEMM_TN * GEMM_TK / GEMM_THREADS)

            float aNext[GEMM_APER];
            half bNext[GEMM_BPER];

            // A row or column past the end of the matrix, or a K past `inFeatures`, reads an
            // exact zero, which contributes nothing to the product and so needs no bound in the
            // inner loop.
            #define GEMM_FETCH(kBase) \
                for (uint n = 0; n < GEMM_APER; ++n) { \
                    const uint e = tid + n * GEMM_THREADS; \
                    const uint k = e % GEMM_TK; \
                    const uint row = rowBase + e / GEMM_TK; \
                    aNext[n] = (row < p.rows && (kBase) + k < p.inFeatures) \
                        ? x[(ulong)row * p.inFeatures + (kBase) + k] : 0.0f; \
                } \
                for (uint n = 0; n < GEMM_BPER; ++n) { \
                    const uint e = tid + n * GEMM_THREADS; \
                    const uint k = e % GEMM_TK; \
                    const uint col = colBase + e / GEMM_TK; \
                    bNext[n] = (col < p.outFeatures && (kBase) + k < p.inFeatures) \
                        ? weights[(ulong)col * p.inFeatures + (kBase) + k] : half(0.0f); \
                }

            // The staging writes put the K index on the fast axis of `e`, so that consecutive
            // threads read consecutive addresses out of both operands above. Where they land is
            // the interleaved 8 x 8 block layout, which is a scatter -- but it is paid once per
            // staged pass and read GEMM_TK / 8 times by every simdgroup.
            #define GEMM_PUBLISH() \
                for (uint n = 0; n < GEMM_APER; ++n) { \
                    const uint e = tid + n * GEMM_THREADS; \
                    const uint k = e % GEMM_TK; \
                    const uint m = e / GEMM_TK; \
                    aTile[((k / 8) * (GEMM_TM / 8) + m / 8) * 64 + (m % 8) * 8 + k % 8] = aNext[n]; \
                } \
                for (uint n = 0; n < GEMM_BPER; ++n) { \
                    const uint e = tid + n * GEMM_THREADS; \
                    const uint k = e % GEMM_TK; \
                    const uint j = e / GEMM_TK; \
                    bTile[((k / 8) * (GEMM_TN / 8) + j / 8) * 64 + (k % 8) * 8 + j % 8] = bNext[n]; \
                }

            GEMM_FETCH(0)
            GEMM_PUBLISH()
            threadgroup_barrier(mem_flags::mem_threadgroup);

            for (uint kBase = 0; kBase < p.inFeatures; kBase += GEMM_TK) {
                if (kBase + GEMM_TK < p.inFeatures) {
                    GEMM_FETCH(kBase + GEMM_TK)
                }

                for (uint k = 0; k < GEMM_TK; k += 8) {
                    threadgroup const float *aBlocks = aTile + (k / 8) * GEMM_TM * 8;
                    threadgroup const half *bBlocks = bTile + (k / 8) * GEMM_TN * 8;

                    simdgroup_float8x8 a[GEMM_AM];
                    simdgroup_half8x8 b[GEMM_AN];

                    for (uint i = 0; i < GEMM_AM; ++i) {
                        simdgroup_load(a[i], aBlocks + (sgRow * GEMM_AM + i) * 64);
                    }

                    // The loads and the products below are independent within a simdgroup, and
                    // this is what ggml's `kernel_mul_mm` puts between them: without it the
                    // compiler is free to interleave the second set of loads with the first
                    // set's products and run out of matrix registers.
                    simdgroup_barrier(mem_flags::mem_none);

                    for (uint j = 0; j < GEMM_AN; ++j) {
                        simdgroup_load(b[j], bBlocks + (sgCol * GEMM_AN + j) * 64);
                    }

                    for (uint i = 0; i < GEMM_AM; ++i) {
                        for (uint j = 0; j < GEMM_AN; ++j) {
                            simdgroup_multiply_accumulate(acc[i][j], a[i], b[j], acc[i][j]);
                        }
                    }
                }

                if (kBase + GEMM_TK < p.inFeatures) {
                    // Every simdgroup has to be done reading the tiles before they are refilled,
                    // and done refilling them before the next pass reads them.
                    threadgroup_barrier(mem_flags::mem_threadgroup);
                    GEMM_PUBLISH()
                    threadgroup_barrier(mem_flags::mem_threadgroup);
                }
            }

            #undef GEMM_APER
            #undef GEMM_BPER
            #undef GEMM_FETCH
            #undef GEMM_PUBLISH

            // A tile wholly inside the matrix -- which every one of them is for a weight whose
            // `outFeatures` is a multiple of GEMM_TN and a window that fills its rows -- stores
            // straight to device memory. The rest go through threadgroup memory an 8 x 8 block
            // per simdgroup at a time, because `simdgroup_store` has no bounds and a column
            // past `outFeatures` would land in the next row of the output.
            if (rowBase + GEMM_TM <= p.rows && colBase + GEMM_TN <= p.outFeatures) {
                device float *block = out + (ulong)rowBase * p.outFeatures + colBase;

                for (uint i = 0; i < GEMM_AM; ++i) {
                    for (uint j = 0; j < GEMM_AN; ++j) {
                        simdgroup_store(
                            acc[i][j], block, p.outFeatures,
                            ulong2((sgCol * GEMM_AN + j) * 8, (sgRow * GEMM_AM + i) * 8));
                    }
                }

                return;
            }

            for (uint i = 0; i < GEMM_AM; ++i) {
                for (uint j = 0; j < GEMM_AN; ++j) {
                    // The staged operands are dead by now, but a simdgroup may still be reading
                    // its own 8 x 8 slot from the round before.
                    threadgroup_barrier(mem_flags::mem_threadgroup);
                    simdgroup_store(acc[i][j], staged + sg * 64, 8);
                    threadgroup_barrier(mem_flags::mem_threadgroup);

                    for (uint e = tid; e < GEMM_SM * GEMM_SN * 64; e += GEMM_THREADS) {
                        const uint slot = e / 64;
                        const uint local = e % 64;
                        const uint row =
                            rowBase + ((slot / GEMM_SN) * GEMM_AM + i) * 8 + local / 8;
                        const uint col =
                            colBase + ((slot % GEMM_SN) * GEMM_AN + j) * 8 + local % 8;

                        if (row < p.rows && col < p.outFeatures) {
                            out[(ulong)row * p.outFeatures + col] = staged[e];
                        }
                    }
                }
            }
        }

        // This fragment is concatenated onto the rest of the library, so the macros would
        // otherwise stay defined for whatever is appended after it.
        #undef GEMM_TM
        #undef GEMM_TN
        #undef GEMM_TK
        #undef GEMM_SM
        #undef GEMM_SN
        #undef GEMM_THREADS
        #undef GEMM_AM
        #undef GEMM_AN
        """
}
