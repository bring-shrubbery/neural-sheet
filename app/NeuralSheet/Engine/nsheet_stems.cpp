#include "nsheet_stems.h"

// The library's headers are vendored verbatim; their warnings are theirs.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include "model.hpp"
#pragma clang diagnostic pop

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <exception>
#include <mutex>
#include <new>
#include <string>
#include <thread>
#include <vector>

struct nsheet_separator {
    demucscpp::demucs_model model;
};

namespace
{

/// The library's multi-threaded driver, in a form that hands its progress out: the signal cut
/// into `threads` stretches with this much overlap either side, each run through the model on
/// its own thread, the outputs summed under a triangular weight and normalised.
constexpr float kOverlapSeconds = 0.75f;

struct Progress {
    std::mutex mutex;
    std::vector<float> perThread;
    float reported = 0;
    nsheet_stems_progress_fn cb = nullptr;
    void* ctx = nullptr;

    void update(int thread, float value)
    {
        std::lock_guard<std::mutex> guard(mutex);
        perThread[static_cast<size_t>(thread)] = std::max(perThread[static_cast<size_t>(thread)], value);

        float sum = 0;
        for (float p : perThread) {
            sum += p;
        }

        const float mean = sum / static_cast<float>(perThread.size());

        if (cb != nullptr && mean > reported) {
            reported = mean;
            cb(mean, ctx);
        }
    }
};

} // namespace

nsheet_separator* nsheet_stems_load(const char* model_path)
{
    if (model_path == nullptr) {
        return nullptr;
    }

    auto* separator = new (std::nothrow) nsheet_separator();

    if (separator == nullptr) {
        return nullptr;
    }

    try {
        if (!demucscpp::load_demucs_model(model_path, &separator->model)) {
            delete separator;
            return nullptr;
        }
    } catch (...) {
        delete separator;
        return nullptr;
    }

    return separator;
}

int nsheet_stems_separate(const nsheet_separator* separator,
                          const float* left,
                          const float* right,
                          size_t frames,
                          int threads,
                          nsheet_stems_progress_fn cb,
                          void* ctx,
                          float** out_stems)
{
    if (separator == nullptr || left == nullptr || right == nullptr || out_stems == nullptr || frames == 0) {
        return NSHEET_STEMS_ERR_INVALID_ARGUMENT;
    }

    *out_stems = nullptr;

    const int total = static_cast<int>(frames);
    const int overlap = static_cast<int>(std::floor(kOverlapSeconds * NSHEET_STEMS_SAMPLE_RATE));
    // A stretch has to be longer than its overlaps for the split to mean anything.
    int count = std::clamp(threads, 1, 8);
    while (count > 1 && total / count < 4 * overlap) {
        --count;
    }

    try {
        Eigen::MatrixXf full(2, total);
        for (int i = 0; i < total; ++i) {
            full(0, i) = left[i];
            full(1, i) = right[i];
        }

        const int segmentLength = static_cast<int>(std::ceil(static_cast<float>(total) / static_cast<float>(count)));
        std::vector<Eigen::MatrixXf> segments;
        segments.reserve(static_cast<size_t>(count));

        for (int i = 0; i < count; ++i) {
            const int start = i * segmentLength;
            const int end = std::min(total, start + segmentLength);
            const int length = end - start;
            Eigen::MatrixXf segment = Eigen::MatrixXf::Zero(2, length + 2 * overlap);

            // The lead-in: the signal before the stretch, or the first sample held.
            if (i == 0) {
                segment.block(0, 0, 2, overlap).colwise() = full.col(0);
            } else {
                segment.block(0, 0, 2, overlap) = full.block(0, start - overlap, 2, overlap);
            }

            // The tail: the signal after the stretch, or whatever remains.
            if (i == count - 1) {
                const int remaining = total - end;
                segment.block(0, length + overlap, 2, remaining) = full.block(0, end, 2, remaining);
            } else {
                segment.block(0, length + overlap, 2, overlap) = full.block(0, end, 2, overlap);
            }

            segment.block(0, overlap, 2, length) = full.block(0, start, 2, length);
            segments.push_back(std::move(segment));
        }

        Progress progress;
        progress.perThread.assign(static_cast<size_t>(count), 0.0f);
        progress.cb = cb;
        progress.ctx = ctx;

        std::vector<Eigen::Tensor3dXf> outputs(static_cast<size_t>(count));
        std::vector<std::string> failures(static_cast<size_t>(count));
        std::vector<std::thread> workers;
        workers.reserve(static_cast<size_t>(count));

        for (int i = 0; i < count; ++i) {
            workers.emplace_back([&, i]() {
                try {
                    outputs[static_cast<size_t>(i)] = demucscpp::demucs_inference(
                        separator->model, segments[static_cast<size_t>(i)],
                        [&progress, i](float value, const std::string&) { progress.update(i, value); });
                } catch (const std::exception& error) {
                    failures[static_cast<size_t>(i)] = error.what();
                } catch (...) {
                    failures[static_cast<size_t>(i)] = "unknown error";
                }
            });
        }

        for (auto& worker : workers) {
            worker.join();
        }

        for (const auto& failure : failures) {
            if (!failure.empty()) {
                return failure.find("alloc") != std::string::npos ? NSHEET_STEMS_ERR_OUT_OF_MEMORY : NSHEET_STEMS_ERR_INTERNAL;
            }
        }

        const int sources = NSHEET_STEM_COUNT;
        auto* result = static_cast<float*>(std::calloc(static_cast<size_t>(sources) * 2 * frames, sizeof(float)));

        if (result == nullptr) {
            return NSHEET_STEMS_ERR_OUT_OF_MEMORY;
        }

        std::vector<float> weightSum(static_cast<size_t>(total), 0.0f);
        std::vector<float> ramp(static_cast<size_t>(segmentLength));
        for (int i = 0; i < segmentLength; ++i) {
            ramp[static_cast<size_t>(i)] = static_cast<float>(std::min(i + 1, segmentLength - i));
        }
        const float rampMax = *std::max_element(ramp.begin(), ramp.end());
        for (auto& value : ramp) {
            value /= rampMax;
        }

        for (int i = 0; i < count; ++i) {
            const auto& output = outputs[static_cast<size_t>(i)];
            const int segmentStart = i * segmentLength;
            const int span = static_cast<int>(output.dimension(2));

            for (int j = 0; j < span; ++j) {
                const int global = segmentStart + j - overlap;

                if (global < 0 || global >= total) {
                    continue;
                }

                float weight = 1.0f;
                if (j < overlap) {
                    weight = ramp[static_cast<size_t>(j)];
                } else if (j >= segmentLength) {
                    const int index = segmentLength + 2 * overlap - j - 1;
                    weight = ramp[static_cast<size_t>(std::clamp(index, 0, segmentLength - 1))];
                }

                for (int t = 0; t < sources && t < output.dimension(0); ++t) {
                    for (int ch = 0; ch < 2; ++ch) {
                        result[(static_cast<size_t>(t) * 2 + static_cast<size_t>(ch)) * frames + static_cast<size_t>(global)] +=
                            output(t, ch, j) * weight;
                    }
                }

                weightSum[static_cast<size_t>(global)] += weight;
            }
        }

        // The driver normalises by the summed weight over the stems and channels it added.
        for (int global = 0; global < total; ++global) {
            const float sum = weightSum[static_cast<size_t>(global)];
            if (sum <= 0) {
                continue;
            }

            for (int t = 0; t < sources; ++t) {
                for (int ch = 0; ch < 2; ++ch) {
                    result[(static_cast<size_t>(t) * 2 + static_cast<size_t>(ch)) * frames + static_cast<size_t>(global)] /= sum;
                }
            }
        }

        *out_stems = result;
        return NSHEET_STEMS_OK;
    } catch (const std::bad_alloc&) {
        return NSHEET_STEMS_ERR_OUT_OF_MEMORY;
    } catch (...) {
        return NSHEET_STEMS_ERR_INTERNAL;
    }
}

void nsheet_stems_free_audio(float* stems)
{
    std::free(stems);
}

void nsheet_stems_free(nsheet_separator* separator)
{
    delete separator;
}

const char* nsheet_stems_describe_error(int error)
{
    switch (error) {
        case NSHEET_STEMS_OK:
            return "ok";
        case NSHEET_STEMS_ERR_INVALID_ARGUMENT:
            return "invalid argument";
        case NSHEET_STEMS_ERR_OUT_OF_MEMORY:
            return "out of memory";
        case NSHEET_STEMS_ERR_INTERNAL:
            return "internal error";
        default:
            return "unknown error";
    }
}
