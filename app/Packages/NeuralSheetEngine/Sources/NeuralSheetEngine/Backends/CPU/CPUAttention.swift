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
    /// `q` is `[nNew][nHead · headDim]` and head `h` lives at columns
    /// `h · headDim ..< (h + 1) · headDim`; `kCache` and `vCache` are `[nCtx][nHead · headDim]`
    /// with rows `0 ..< nPast + nNew` filled, the caller having already written this
    /// step's keys and values at `nPast`; `out` is `[nNew][nHead · headDim]`.
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
        q: UnsafePointer<Float>, kCache: UnsafePointer<Float>, vCache: UnsafePointer<Float>,
        nNew: Int, nPast: Int, nHead: Int, headDim: Int, scale: Float,
        scores: UnsafeMutablePointer<Float>, out: UnsafeMutablePointer<Float>
    ) {
        let dim = nHead * headDim
        let nKV = nPast + nNew

        DispatchQueue.concurrentPerform(iterations: nHead) { head in
            let offset = head * headDim
            let s = scores + head * nNew * nKV

            // s = q_h · K_hᵀ · scale. The head is a column slice of a wider row in both
            // operands, which is what the leading dimensions of `dim` say.
            cblas_sgemm(
                CblasRowMajor, CblasNoTrans, CblasTrans,
                Int32(nNew), Int32(nKV), Int32(headDim),
                scale, q + offset, Int32(dim), kCache + offset, Int32(dim),
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
}
