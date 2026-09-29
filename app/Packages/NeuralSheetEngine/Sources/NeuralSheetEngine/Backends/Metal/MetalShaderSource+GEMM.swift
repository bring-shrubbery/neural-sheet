// The prefill's matrix product, split out of MetalShaderSource.swift because it is the one
// kernel in the library with a blocking strategy of its own to explain. ggml's equivalent is
// `kernel_mul_mm` in ggml/src/ggml-metal/ggml-metal.metal, which does the same thing through
// `simdgroup_matrix`; this does it with threadgroup memory and per-thread registers, which
// asks nothing of the device beyond what the rest of the library already asks.

extension MetalShaderSource {
    /// How `matmul_tiled_f16` blocks the output: a threadgroup owns a `rows` x `features`
    /// block and walks K in steps of `depth`, and each of its threads keeps a
    /// `perThread` x `perThread` square of that block in registers.
    ///
    /// One definition, interpolated into the MSL below and read by `MetalKernels` for the
    /// grid it dispatches. It was two -- these numbers and a matching set of `#define`s --
    /// held together by a comment, and the two disagreeing is not a compile error: too few
    /// threads leaves part of every tile unwritten, too many reads threadgroup memory
    /// nothing staged, and either way the wrong answer comes back quietly.
    struct GEMMTile: Sendable {
        /// `GEMM_TM`, the rows of the output one threadgroup owns.
        var rows: Int

        /// `GEMM_TN`, the output features one threadgroup owns.
        var features: Int

        /// `GEMM_TK`, how far into K one staged pass reaches.
        var depth: Int

        /// `GEMM_TW`, the side of the square one thread owns.
        var perThread: Int

        /// `GEMM_THREADS`, and so the threadgroup size the kernel must be dispatched with.
        var threads: Int { (rows / perThread) * (features / perThread) }
    }

    /// The shape measured fastest of sixteen on an M2 Pro, on a plateau rather than a peak:
    /// 64 x 32 and 64 x 128 tiles and depths of 8 and 32 are all within a few per cent, while
    /// 8 x 8 outputs per thread is four times worse because the accumulators stop fitting in
    /// registers. @see docs/design/2026-09-29-swift-engine-plan.md
    static let gemmTile = GEMMTile(rows: 64, features: 64, depth: 16, perThread: 4)

    /// Appended to `core`, so the `MatmulParams` struct and the includes above are in scope.
    static let gemm = """

        // The tile, from MetalShaderSource.gemmTile. Macros rather than constants because
        // they size the threadgroup arrays below and the inner loops are unrolled over them.
        #define GEMM_TM \(gemmTile.rows)
        #define GEMM_TN \(gemmTile.features)
        #define GEMM_TK \(gemmTile.depth)
        #define GEMM_TW \(gemmTile.perThread)
        #define GEMM_THREADS ((GEMM_TM / GEMM_TW) * (GEMM_TN / GEMM_TW))

        /// `out = X . Wt` for several input rows: a classic tiled GEMM.
        ///
        /// A thread per output element -- the obvious kernel -- reads the weight `inFeatures`
        /// apart across the lanes of a simdgroup, so every lane pulls its own cache line;
        /// splitting one dot product across a simdgroup's lanes instead, which is what this
        /// kernel was, makes those reads contiguous but reads the whole of both operands once
        /// per output element and spends most of its instructions on the `simd_sum` that ends
        /// each one. Measured at the prefill's 504 rows it reached about 0.47 TFLOP/s, a
        /// fifteenth of this device's peak.
        ///
        /// Staging both operands through threadgroup memory and giving each thread a square
        /// of the output is what fixes the arithmetic intensity: a GEMM_TK-deep pass reads
        /// GEMM_TM x GEMM_TK floats and GEMM_TN x GEMM_TK halves and does
        /// GEMM_TM x GEMM_TN x GEMM_TK multiply-adds with them, so the nominal traffic falls
        /// by a factor of the tile's width, and each thread's inner loop is GEMM_TW + GEMM_TW
        /// threadgroup loads for GEMM_TW x GEMM_TW fused multiply-adds out of registers.
        ///
        /// The accumulation is F32 and runs straight up K, which is a different order from the
        /// simdgroup reduction it replaces; the token streams are the gate on that, and the
        /// Metal oracle fixtures are unchanged by it.
        kernel void matmul_tiled_f16(
            device const half *weights [[buffer(0)]],
            device const float *x [[buffer(1)]],
            device float *out [[buffer(2)]],
            constant MatmulParams &p [[buffer(3)]],
            uint2 group [[threadgroup_position_in_grid]],
            uint tid [[thread_index_in_threadgroup]])
        {
            // Indexed [k][m] rather than [m][k] so that the inner loop's GEMM_TW loads are
            // adjacent, which is the access that runs GEMM_TK times per pass.
            threadgroup float aTile[GEMM_TK][GEMM_TM];
            threadgroup float bTile[GEMM_TK][GEMM_TN];

            const uint rowBase = group.y * GEMM_TM;
            const uint colBase = group.x * GEMM_TN;
            const uint ty = tid / (GEMM_TN / GEMM_TW);
            const uint tx = tid % (GEMM_TN / GEMM_TW);

            float acc[GEMM_TW][GEMM_TW];
            for (uint i = 0; i < GEMM_TW; ++i) {
                for (uint j = 0; j < GEMM_TW; ++j) {
                    acc[i][j] = 0.0f;
                }
            }

            for (uint kBase = 0; kBase < p.inFeatures; kBase += GEMM_TK) {
                // The staging loops put the K index on the fast axis, so that consecutive
                // threads *read* consecutive addresses out of both operands in device
                // memory, which is the access worth coalescing. Their writes into the tiles
                // are strided by GEMM_TM and GEMM_TN instead, and deliberately: the tiles
                // are indexed [k][m] for the sake of the inner loop, which reads them
                // GEMM_TK times for every once this stages them.
                //
                // A row or column past the end of the matrix, or a K past `inFeatures`,
                // stages an exact zero, which contributes nothing to the sum and so needs no
                // bound in the inner loop.
                for (uint e = tid; e < GEMM_TM * GEMM_TK; e += GEMM_THREADS) {
                    const uint k = e % GEMM_TK;
                    const uint row = rowBase + e / GEMM_TK;
                    aTile[k][e / GEMM_TK] = (row < p.rows && kBase + k < p.inFeatures)
                        ? x[(ulong)row * p.inFeatures + kBase + k] : 0.0f;
                }

                for (uint e = tid; e < GEMM_TN * GEMM_TK; e += GEMM_THREADS) {
                    const uint k = e % GEMM_TK;
                    const uint col = colBase + e / GEMM_TK;
                    bTile[k][e / GEMM_TK] = (col < p.outFeatures && kBase + k < p.inFeatures)
                        ? float(weights[(ulong)col * p.inFeatures + kBase + k]) : 0.0f;
                }

                threadgroup_barrier(mem_flags::mem_threadgroup);

                for (uint k = 0; k < GEMM_TK; ++k) {
                    float a[GEMM_TW];
                    float b[GEMM_TW];

                    for (uint i = 0; i < GEMM_TW; ++i) {
                        a[i] = aTile[k][ty * GEMM_TW + i];
                    }

                    for (uint j = 0; j < GEMM_TW; ++j) {
                        b[j] = bTile[k][tx * GEMM_TW + j];
                    }

                    for (uint i = 0; i < GEMM_TW; ++i) {
                        for (uint j = 0; j < GEMM_TW; ++j) {
                            acc[i][j] = fma(a[i], b[j], acc[i][j]);
                        }
                    }
                }

                // The next pass overwrites both tiles, so every thread has to be done reading
                // them before it may start.
                threadgroup_barrier(mem_flags::mem_threadgroup);
            }

            for (uint i = 0; i < GEMM_TW; ++i) {
                const uint row = rowBase + ty * GEMM_TW + i;

                if (row >= p.rows) {
                    continue;
                }

                for (uint j = 0; j < GEMM_TW; ++j) {
                    const uint col = colBase + tx * GEMM_TW + j;

                    if (col < p.outFeatures) {
                        out[(ulong)row * p.outFeatures + col] = acc[i][j];
                    }
                }
            }
        }

        // This fragment is concatenated onto the rest of the library, so the macros would
        // otherwise stay defined for whatever is appended after it.
        #undef GEMM_TM
        #undef GEMM_TN
        #undef GEMM_TK
        #undef GEMM_TW
        #undef GEMM_THREADS
        """
}
