// The GPU half of `buildEvalGraph` in muscriptor.cpp's cpp/src/model.cpp. The C++ hands
// its graph to ggml, so the kernels it runs on the GPU are ggml's own
// (ggml/src/ggml-metal/ggml-metal.metal: `kernel_norm`, `kernel_mul_mv_f16_f32`,
// `kernel_mul_mm`, `kernel_soft_max`, `kernel_gelu_erf`, `kernel_add`, `kernel_cpy`).
// These nine are the same arithmetic written out for this one architecture, which is why
// they are a fraction of the size: no broadcasting, no strides, no types but F16 weights
// and F32 activations.
//
// The source is a Swift string and not a `.metal` file on purpose. A `.metal` file becomes
// a `default.metallib` inside a bundle, and the bundle differs between `swift test`, the
// app and an iOS device; compiling from source at load has one code path everywhere, and
// it costs about thirty milliseconds once per process.
//
// Every kernel matches, op for op, the CPU backend's equivalent in Backends/CPU. Where the
// two could reasonably differ -- the order a dot product accumulates in, the layer norm's
// reduction tree -- they do, and the oracle tolerances cover it; where they must not, the
// constants below are the same literals the Swift uses.

/// The Metal Shading Language the backend compiles at load. @see MetalKernels
enum MetalShaderSource {
    /// The whole library: these kernels and the prefill GEMM, which is long enough and
    /// self-contained enough to live in its own file. @see MetalShaderSource+GEMM
    static let source = core + gemm

    private static let core = """
        #include <metal_stdlib>
        using namespace metal;

        // The parameter blocks, mirrored field for field by the Swift structs in
        // MetalKernels.swift. Every field is four bytes wide so that the two layouts
        // cannot drift apart over a padding rule.

        struct LayerNormParams {
            uint dim;
            float eps;
        };

        struct MatmulParams {
            uint outFeatures;
            uint inFeatures;
            uint rows;
        };

        struct CopyKVParams {
            uint dim;
            uint nPast;
        };

        struct AttentionParams {
            uint nNew;
            uint nKV;
            uint nPast;
            uint nHead;
            uint headDim;
            uint dim;
            float scale;
        };

        struct SoftmaxParams {
            uint columns;
        };

        // The width of the two reduction kernels' threadgroups. It is a macro rather than a
        // parameter because it is also the size of their threadgroup arrays, and the
        // reduction tree below halves it, so it has to be a power of two known at compile
        // time. The Swift dispatches exactly this many threads.
        #define REDUCE_THREADS 256

        // 1 / sqrt(2), the same literal CPUKernels.geluErf uses.
        #define INVERSE_ROOT_TWO 0.70710678118654752440f

        /// The error function, which MSL's math library does not have: Abramowitz and
        /// Stegun 7.1.26, in Hastings' form, accurate to about 1.5e-7 absolute.
        ///
        /// This is `erf_approx` from ggml's own ggml-metal.metal, constant for constant,
        /// because that is the function the reference's Metal backend puts through
        /// `kernel_gelu_erf` and so the function the Metal oracle dump was made with. The
        /// CPU backend calls libm's `erff` instead, for the same reason: it is what
        /// `ggml_gelu_erf` calls there. The two differ by less than an F32 ulp of the
        /// activation, which is far below what a layer norm's reduction order already costs.
        inline float erf_hastings(float x)
        {
            const float signum = sign(x);
            const float magnitude = fabs(x);
            const float t = 1.0f / (1.0f + 0.3275911f * magnitude);
            const float series =
                ((((1.061405429f * t - 1.453152027f) * t + 1.421413741f) * t - 0.284496736f) * t
                    + 0.254829592f) * t;

            return signum * (1.0f - series * exp(-magnitude * magnitude));
        }

        /// LayerNorm with affine parameters, one threadgroup per row.
        ///
        /// The mean and the variance accumulate in F32 here and in F64 on the CPU. The
        /// tree reduction makes up most of the difference -- summing 768 values in a tree
        /// of depth eight is far more accurate than summing them in sequence -- and what is
        /// left is inside the oracle's tolerance.
        ///
        /// `out` may alias `x`: a thread only ever writes the elements it read.
        kernel void layer_norm(
            device const float *x [[buffer(0)]],
            device float *out [[buffer(1)]],
            device const float *weight [[buffer(2)]],
            device const float *bias [[buffer(3)]],
            constant LayerNormParams &p [[buffer(4)]],
            uint row [[threadgroup_position_in_grid]],
            uint tid [[thread_position_in_threadgroup]])
        {
            threadgroup float partial[REDUCE_THREADS];

            device const float *source = x + (ulong)row * p.dim;
            device float *destination = out + (ulong)row * p.dim;

            float total = 0.0f;
            for (uint i = tid; i < p.dim; i += REDUCE_THREADS) {
                total += source[i];
            }

            partial[tid] = total;
            threadgroup_barrier(mem_flags::mem_threadgroup);

            for (uint stride = REDUCE_THREADS / 2; stride > 0; stride >>= 1) {
                if (tid < stride) {
                    partial[tid] += partial[tid + stride];
                }
                threadgroup_barrier(mem_flags::mem_threadgroup);
            }

            const float mean = partial[0] / float(p.dim);

            // Every thread has to have read partial[0] before the sum of squares overwrites it.
            threadgroup_barrier(mem_flags::mem_threadgroup);

            float squares = 0.0f;
            for (uint i = tid; i < p.dim; i += REDUCE_THREADS) {
                const float centred = source[i] - mean;
                squares += centred * centred;
            }

            partial[tid] = squares;
            threadgroup_barrier(mem_flags::mem_threadgroup);

            for (uint stride = REDUCE_THREADS / 2; stride > 0; stride >>= 1) {
                if (tid < stride) {
                    partial[tid] += partial[tid + stride];
                }
                threadgroup_barrier(mem_flags::mem_threadgroup);
            }

            const float inverse = rsqrt(partial[0] / float(p.dim) + p.eps);

            for (uint i = tid; i < p.dim; i += REDUCE_THREADS) {
                destination[i] = (source[i] - mean) * inverse * weight[i] + bias[i];
            }
        }

        /// `out = W . x` for a single input row, one simdgroup per output row.
        ///
        /// This is the decode step's whole cost: 200 MB of F16 weights streamed once per
        /// token. One simdgroup per row and a strided slice per lane is what makes the
        /// reads contiguous across the lanes, which is what a memory-bound kernel needs.
        /// The reduction is `simd_sum` and not a threadgroup tree because the Swift
        /// dispatches exactly one simdgroup's worth of threads.
        kernel void matvec_f16(
            device const half *weights [[buffer(0)]],
            device const float *x [[buffer(1)]],
            device float *out [[buffer(2)]],
            constant MatmulParams &p [[buffer(3)]],
            uint row [[threadgroup_position_in_grid]],
            uint lane [[thread_position_in_threadgroup]],
            uint width [[threads_per_threadgroup]])
        {
            device const half *w = weights + (ulong)row * p.inFeatures;

            float accumulator = 0.0f;
            for (uint i = lane; i < p.inFeatures; i += width) {
                accumulator = fma(float(w[i]), x[i], accumulator);
            }

            accumulator = simd_sum(accumulator);

            if (lane == 0) {
                out[row] = accumulator;
            }
        }

        /// The keys and values of this window into the cache at rows `nPast ..< nPast + nNew`.
        ///
        /// `attn_qkv` stacks q, k and v in that order, so a row of the projection is
        /// `3 . dim` wide and the two halves that are cached start at `dim` and `2 . dim`.
        kernel void copy_kv(
            device const float *qkv [[buffer(0)]],
            device float *keys [[buffer(1)]],
            device float *values [[buffer(2)]],
            constant CopyKVParams &p [[buffer(3)]],
            uint2 gid [[thread_position_in_grid]])
        {
            const ulong source = (ulong)gid.y * 3 * p.dim + gid.x;
            const ulong destination = (ulong)(p.nPast + gid.y) * p.dim + gid.x;

            keys[destination] = qkv[source + p.dim];
            values[destination] = qkv[source + 2 * p.dim];
        }

        /// The scaled, causally masked attention scores, one thread per (key, query, head).
        ///
        /// The mask is bottom-right causal: query row `i` sits at position `nPast + i`, so
        /// it may attend to cache rows `0 ... nPast + i` and no further. The scale is
        /// folded in here, as the CPU folds it into the GEMM's alpha, so that the softmax
        /// below is a plain softmax.
        kernel void attn_scores(
            device const float *qkv [[buffer(0)]],
            device const float *keys [[buffer(1)]],
            device float *scores [[buffer(2)]],
            constant AttentionParams &p [[buffer(3)]],
            uint3 gid [[thread_position_in_grid]])
        {
            device float *out = scores + ((ulong)gid.z * p.nNew + gid.y) * p.nKV + gid.x;

            if (gid.x > p.nPast + gid.y) {
                *out = -INFINITY;
                return;
            }

            device const float *q = qkv + (ulong)gid.y * 3 * p.dim + gid.z * p.headDim;
            device const float *k = keys + (ulong)gid.x * p.dim + gid.z * p.headDim;

            float accumulator = 0.0f;
            for (uint d = 0; d < p.headDim; ++d) {
                accumulator = fma(q[d], k[d], accumulator);
            }

            *out = accumulator * p.scale;
        }

        /// Softmax over one score row, in place, one threadgroup per (head, query).
        ///
        /// A masked entry is -infinity, so it exponentiates to exactly zero and drops out
        /// of both the sum and the weighted sum below -- the same zero the CPU writes by
        /// running the softmax over the allowed prefix and clearing the rest. No row can be
        /// entirely masked, because a query may always attend to itself, so the maximum
        /// subtracted is always finite.
        kernel void softmax_rows(
            device float *scores [[buffer(0)]],
            constant SoftmaxParams &p [[buffer(1)]],
            uint row [[threadgroup_position_in_grid]],
            uint tid [[thread_position_in_threadgroup]])
        {
            threadgroup float partial[REDUCE_THREADS];

            device float *values = scores + (ulong)row * p.columns;

            float highest = -INFINITY;
            for (uint i = tid; i < p.columns; i += REDUCE_THREADS) {
                highest = max(highest, values[i]);
            }

            partial[tid] = highest;
            threadgroup_barrier(mem_flags::mem_threadgroup);

            for (uint stride = REDUCE_THREADS / 2; stride > 0; stride >>= 1) {
                if (tid < stride) {
                    partial[tid] = max(partial[tid], partial[tid + stride]);
                }
                threadgroup_barrier(mem_flags::mem_threadgroup);
            }

            const float maximum = partial[0];
            threadgroup_barrier(mem_flags::mem_threadgroup);

            float total = 0.0f;
            for (uint i = tid; i < p.columns; i += REDUCE_THREADS) {
                const float weight = exp(values[i] - maximum);
                values[i] = weight;
                total += weight;
            }

            partial[tid] = total;
            threadgroup_barrier(mem_flags::mem_threadgroup);

            for (uint stride = REDUCE_THREADS / 2; stride > 0; stride >>= 1) {
                if (tid < stride) {
                    partial[tid] += partial[tid + stride];
                }
                threadgroup_barrier(mem_flags::mem_threadgroup);
            }

            const float inverse = 1.0f / partial[0];

            for (uint i = tid; i < p.columns; i += REDUCE_THREADS) {
                values[i] *= inverse;
            }
        }

        /// The weighted sum of the cached values, one thread per (channel, query, head).
        ///
        /// The whole `nKV` row is summed, masked tail included: those probabilities are
        /// exactly zero, so the rows past the query's own position contribute nothing and
        /// need no special case.
        kernel void attn_values(
            device const float *scores [[buffer(0)]],
            device const float *values [[buffer(1)]],
            device float *out [[buffer(2)]],
            constant AttentionParams &p [[buffer(3)]],
            uint3 gid [[thread_position_in_grid]])
        {
            device const float *probabilities = scores + ((ulong)gid.z * p.nNew + gid.y) * p.nKV;
            device const float *v = values + gid.z * p.headDim + gid.x;

            float accumulator = 0.0f;
            for (uint j = 0; j < p.nKV; ++j) {
                accumulator = fma(probabilities[j], v[(ulong)j * p.dim], accumulator);
            }

            out[(ulong)gid.y * p.dim + gid.z * p.headDim + gid.x] = accumulator;
        }

        /// GELU in its exact erf form, in place. `ggml_gelu` is the tanh approximation and
        /// this is `ggml_gelu_erf`; the two differ by up to about 1e-3 per activation,
        /// which compounds over the layers, so the form matters.
        kernel void gelu_erf(
            device float *x [[buffer(0)]],
            uint index [[thread_position_in_grid]])
        {
            const float value = x[index];
            x[index] = 0.5f * value * (1.0f + erf_hastings(value * INVERSE_ROOT_TWO));
        }

        /// `y += x`, the residual add.
        kernel void add_inplace(
            device float *y [[buffer(0)]],
            device const float *x [[buffer(1)]],
            uint index [[thread_position_in_grid]])
        {
            y[index] += x[index];
        }
        """
}
