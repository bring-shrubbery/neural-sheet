// The attention block of muscriptor.cpp's cpp/src/model.cpp `buildEvalGraph`: the
// `ggml_mul_mat` of the cached keys against the queries, `ggml_soft_max_ext` with the
// causal mask, then the `ggml_mul_mat` of the probabilities against the cached values.
//
// The C++ keeps V transposed in its cache because that is the layout ggml's matmul
// wanted. With our own kernels the plain layout -- one row per position, the heads side
// by side within it -- is what both BLAS calls want, so the cache holds K and V the same
// way and neither needs a permute.

import Accelerate
import Dispatch

enum CPUAttention {
    /// Causal attention of `nNew` query rows over the `nPast + nNew` filled cache rows.
    ///
    /// `q` is `[nNew][qRowStride]` whose first `nHead · headDim` columns are the queries,
    /// and head `h` lives at columns `h · headDim ..< (h + 1) · headDim`; `kCache` and
    /// `vCache` are `[nCtx][nHead · headDim]` with rows `0 ..< nPast + nNew` filled, the
    /// caller having already written this step's keys and values at `nPast`; `out` is
    /// `[nNew][nHead · headDim]`.
    ///
    /// `qRowStride` is a parameter rather than `nHead · headDim` because the backend's
    /// queries are the first third of a `[nNew][3 · dim]` projection, where k and v follow
    /// them in the same row. BLAS takes a leading dimension anyway, so reading the slice
    /// in place costs nothing and saves copying the queries out once per layer.
    ///
    /// The mask is bottom-right causal: query row `i` sits at position `nPast + i`, so it
    /// may attend to cache rows `0 ... nPast + i` and no further. Because that region is
    /// a prefix of the row, the softmax runs over the prefix and the rest is set to zero,
    /// which is exactly what adding -infinity and exponentiating would give without
    /// putting an infinity through BLAS.
    ///
    /// `scores` is the caller's scratch, `nHead · nNew · (nPast + nNew)` floats: one
    /// `nNew × nKV` block per head, so the heads can run at the same time without either
    /// allocating or sharing.
    static func attend(
        q: UnsafePointer<Float>, qRowStride: Int,
        kCache: UnsafePointer<Float>, vCache: UnsafePointer<Float>,
        nNew: Int, nPast: Int, nHead: Int, headDim: Int, scale: Float,
        scores: UnsafeMutablePointer<Float>, out: UnsafeMutablePointer<Float>
    ) {
        let dim = nHead * headDim
        let nKV = nPast + nNew

        // A decode step is a single query row, and at a single row every cached position is
        // allowed -- the query sits at `nPast` and `nKV` is `nPast + 1` -- so there is no mask
        // to apply and both products are a matrix-vector. @see attendOneRow
        guard nNew > 1 else {
            attendOneRow(
                q: q, kCache: kCache, vCache: vCache, nKV: nKV, nHead: nHead, headDim: headDim,
                scale: scale, scores: scores, out: out)
            return
        }

        // One work item per head here, unlike `attendOneRow`'s even ranges per core. A
        // prefill's head is two GEMMs of 504 rows, which BLAS parallelises internally and which
        // do not all take the same time, so leaving the distribution to Dispatch is what keeps
        // the cores busy: eight even ranges over twelve heads measured 211 ms against 187 for
        // `small`'s CPU prefill, best of four runs each.
        DispatchQueue.concurrentPerform(iterations: nHead) { head in
            let offset = head * headDim
            let s = scores + head * nNew * nKV

            // s = q_h · K_hᵀ · scale. The head is a column slice of a wider row in both
            // operands, which is what the leading dimensions of `dim` say.
            cblas_sgemm(
                CblasRowMajor, CblasNoTrans, CblasTrans,
                Int32(nNew), Int32(nKV), Int32(headDim),
                scale, q + offset, Int32(qRowStride), kCache + offset, Int32(dim),
                0, s, Int32(nKV))

            for row in 0..<nNew {
                let allowed = nPast + row + 1
                CPUKernels.softmaxRows(s + row * nKV, rows: 1, columns: allowed, scale: 1, mask: nil)
                if allowed < nKV {
                    vDSP_vclr(s + row * nKV + allowed, 1, vDSP_Length(nKV - allowed))
                }
            }

            // out_h = P · V_h. The masked columns of P are zero, so the rows of the cache
            // past this query's position contribute nothing and need no special case.
            cblas_sgemm(
                CblasRowMajor, CblasNoTrans, CblasNoTrans,
                Int32(nNew), Int32(headDim), Int32(nKV),
                1, s, Int32(nKV), vCache + offset, Int32(dim),
                0, out + offset, Int32(dim))
        }
    }

    /// The same attention for a single query row, without BLAS.
    ///
    /// `cblas_sgemm` at M = 1 is a matrix-vector product, and calling it twice per head from
    /// inside a `concurrentPerform` over the heads was costing far more than the arithmetic:
    /// Accelerate's BLAS has a thread pool of its own, so a decode step made twenty-four to
    /// forty-eight of those calls from eight Dispatch workers at once. The damage did not land
    /// on the attention -- it landed on the GEMVs after it. Measured on `small`, interleaving
    /// one `attend` between every four of a decode step's fifty-six weight products took those
    /// products from 3.38 ms to 4.77 ms while the `attend` calls themselves cost 0.73 ms.
    ///
    /// This is the same arithmetic in plain SIMD: a dot product per cached row for the scores,
    /// then the weighted sum of the cached values a block of channels at a time, with the block
    /// in registers and the rows walked once. Four independent accumulators in each, because a
    /// single one makes the loop a chain of dependent multiply-adds.
    ///
    /// The reduction order is fixed here rather than left to a library, so two runs on the same
    /// input give the same bits; it is not the order BLAS used, and the token streams are the
    /// gate on that.
    private static func attendOneRow(
        q: UnsafePointer<Float>, kCache: UnsafePointer<Float>, vCache: UnsafePointer<Float>,
        nKV: Int, nHead: Int, headDim: Int, scale: Float,
        scores: UnsafeMutablePointer<Float>, out: UnsafeMutablePointer<Float>
    ) {
        let dim = nHead * headDim

        // One even range of heads per performance core rather than one work item per head. A
        // twelve-head model over eight workers leaves four of them idle for the second round,
        // and the cost of that does not land here but on the weight products after it: measured
        // on `small`, interleaving one `attend` between every four of a decode step's fifty-six
        // products took those products from 3.15 ms to 4.69 ms, where interleaving a plain
        // eight-way parallel read of the same bytes cost 0.43 ms and a serial read of them cost
        // nothing at all.
        let ranges = min(CPUKernels.threadCount, nHead)

        DispatchQueue.concurrentPerform(iterations: ranges) { range in
            for head in (nHead * range / ranges) ..< (nHead * (range + 1) / ranges) {
                let offset = head * headDim
                let s = scores + head * nKV
                let query = UnsafeRawPointer(q + offset)

                for row in 0 ..< nKV {
                    s[row] = dot(UnsafeRawPointer(kCache + row * dim + offset), query, headDim) * scale
                }

                CPUKernels.softmaxRows(s, rows: 1, columns: nKV, scale: 1, mask: nil)

                // Thirty-two channels at a time, which is four `SIMD8` accumulators: enough to keep
                // the multiply-adds independent, few enough to stay in registers. A head wider than
                // the block reads its slice of the cache once per block, and those reads are of the
                // same cache lines, so the second pass is served by L2.
                var channel = 0

                while channel + 32 <= headDim {
                    let base = vCache + offset + channel
                    var a0 = SIMD8<Float>()
                    var a1 = SIMD8<Float>()
                    var a2 = SIMD8<Float>()
                    var a3 = SIMD8<Float>()

                    for row in 0 ..< nKV {
                        let weight = SIMD8<Float>(repeating: s[row])
                        let v = UnsafeRawPointer(base + row * dim)
                        a0 += weight * singles(v, 0)
                        a1 += weight * singles(v, 8)
                        a2 += weight * singles(v, 16)
                        a3 += weight * singles(v, 24)
                    }

                    let destination = out + offset + channel
                    for lane in 0 ..< 8 {
                        destination[lane] = a0[lane]
                        destination[lane + 8] = a1[lane]
                        destination[lane + 16] = a2[lane]
                        destination[lane + 24] = a3[lane]
                    }

                    channel += 32
                }

                // The checkpoints' heads are all 64 wide, so this never runs there; it is here so
                // that a head that is not a multiple of the block cannot fail quietly.
                while channel < headDim {
                    var total = Float(0)
                    for row in 0 ..< nKV {
                        total += s[row] * vCache[row * dim + offset + channel]
                    }
                    out[offset + channel] = total
                    channel += 1
                }
            }
        }
    }

    /// The dot product of two F32 vectors, in a fixed order: four accumulators over blocks of
    /// thirty-two, folded pairwise, then whatever is left added in sequence.
    private static func dot(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer, _ count: Int) -> Float {
        var a0 = SIMD8<Float>()
        var a1 = SIMD8<Float>()
        var a2 = SIMD8<Float>()
        var a3 = SIMD8<Float>()

        var index = 0
        while index + 32 <= count {
            a0 += singles(a, index) * singles(b, index)
            a1 += singles(a, index + 8) * singles(b, index + 8)
            a2 += singles(a, index + 16) * singles(b, index + 16)
            a3 += singles(a, index + 24) * singles(b, index + 24)
            index += 32
        }
        while index + 8 <= count {
            a0 += singles(a, index) * singles(b, index)
            index += 8
        }

        let folded = (a0 + a1) + (a2 + a3)
        var total =
            (folded[0] + folded[1]) + (folded[2] + folded[3])
            + ((folded[4] + folded[5]) + (folded[6] + folded[7]))

        while index < count {
            total += a.loadUnaligned(fromByteOffset: index * 4, as: Float.self)
                * b.loadUnaligned(fromByteOffset: index * 4, as: Float.self)
            index += 1
        }

        return total
    }

    /// Eight F32 values at `index`.
    private static func singles(_ p: UnsafeRawPointer, _ index: Int) -> SIMD8<Float> {
        p.loadUnaligned(fromByteOffset: index * MemoryLayout<Float>.stride, as: SIMD8<Float>.self)
    }
}
