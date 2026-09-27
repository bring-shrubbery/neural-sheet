#ifndef NSHEET_STEMS_H
#define NSHEET_STEMS_H

/**
 * A C surface over demucs.cpp, so Swift can separate a take into stems
 * (stem separation design §3). Included from the Swift bridging header, so
 * it must compile as C as well as C++.
 */

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/** An opaque loaded separation model. Free it with nsheet_stems_free. */
typedef struct nsheet_separator nsheet_separator;

/** The stems nsheet_stems_separate produces, in the order they come out. */
enum nsheet_stem {
    NSHEET_STEM_DRUMS = 0,
    NSHEET_STEM_BASS = 1,
    NSHEET_STEM_OTHER = 2,
    NSHEET_STEM_VOCALS = 3,
    NSHEET_STEM_COUNT = 4
};

/** The sample rate the model works at; the caller resamples to and from it. */
#define NSHEET_STEMS_SAMPLE_RATE 44100

typedef enum nsheet_stems_error {
    NSHEET_STEMS_OK = 0,
    NSHEET_STEMS_ERR_INVALID_ARGUMENT,
    NSHEET_STEMS_ERR_OUT_OF_MEMORY,
    NSHEET_STEMS_ERR_INTERNAL
} nsheet_stems_error;

/**
 * Called from the worker threads, serialised, as the separation advances.
 * `progress` is 0 to 1 and non-decreasing.
 */
typedef void (*nsheet_stems_progress_fn)(float progress, void* ctx);

/**
 * Load the ggml weights. Blocking, well under a second.
 *
 * @return The model, or null when the file is missing or not a Demucs
 *         checkpoint.
 */
nsheet_separator* nsheet_stems_load(const char* model_path);

/**
 * Separate a 44.1 kHz stereo signal into four stems. Blocking, minutes for a
 * song; never call it from an audio thread. One call at a time per model.
 *
 * @param threads How many stretches the signal is cut into and processed in
 *        parallel, 1 to 8; each holds its own working buffers.
 * @param out_stems On NSHEET_STEMS_OK, a malloc'd planar array of
 *        NSHEET_STEM_COUNT × 2 × frames floats -- stem, then channel, then
 *        frame -- the caller frees with nsheet_stems_free_audio.
 * @return NSHEET_STEMS_OK, or the failure.
 */
int nsheet_stems_separate(const nsheet_separator* separator,
                          const float* left,
                          const float* right,
                          size_t frames,
                          int threads,
                          nsheet_stems_progress_fn cb,
                          void* ctx,
                          float** out_stems);

/** Free an array handed out by nsheet_stems_separate. Null is a no-op. */
void nsheet_stems_free_audio(float* stems);

/** Free a model. Null is a no-op. */
void nsheet_stems_free(nsheet_separator* separator);

/** @return A short, stable description of an nsheet_stems_error. */
const char* nsheet_stems_describe_error(int error);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* NSHEET_STEMS_H */
