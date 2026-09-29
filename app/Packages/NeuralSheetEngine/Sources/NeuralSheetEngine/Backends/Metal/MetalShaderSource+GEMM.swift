// The prefill's matrix product, split out of MetalShaderSource.swift because it is the one
// kernel in the library with a blocking strategy of its own to explain. ggml's equivalent is
// `kernel_mul_mm` in ggml/src/ggml-metal/ggml-metal.metal, which does the same thing through
// `simdgroup_matrix`; this does it with threadgroup memory and per-thread registers, which
// asks nothing of the device beyond what the rest of the library already asks.

extension MetalShaderSource {
    /// Appended to `core`, so the `MatmulParams` struct and the includes above are in scope.
    static let gemm = """

        // The prefill GEMM's tile. A threadgroup owns a GEMM_TM x GEMM_TN block of the
        // output and walks K in steps of GEMM_TK; each of its threads owns a
        // GEMM_TW x GEMM_TW square of that block, so the threadgroup is
        // (GEMM_TM / GEMM_TW) x (GEMM_TN / GEMM_TW) threads. These are macros because they
        // size the threadgroup arrays and are unrolled over, and the Swift dispatches the
        // matching grid -- MetalKernels.gemmTile has to be changed with them.
        #define GEMM_TM 64
        #define GEMM_TN 64
        #define GEMM_TK 16
        #define GEMM_TW 4
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
                // The staging loops put the K index on the fast axis, so consecutive threads
                // read consecutive addresses out of both operands. A row or column past the
                // end of the matrix, or a K past `inFeatures`, stages an exact zero, which
                // contributes nothing to the sum and needs no bound in the inner loop.
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
        """
}
