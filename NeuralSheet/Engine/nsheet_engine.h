#ifndef NSHEET_ENGINE_H
#define NSHEET_ENGINE_H

/**
 * A C surface over muscriptor.cpp's C++23 API, so Swift can drive it.
 * `std::expected` and `std::span` do not bridge; errors come back as codes and
 * notes as a malloc'd array the caller frees with nsheet_free_notes.
 *
 * This header is included from the Swift bridging header, so it must compile
 * as C as well as C++.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** An opaque loaded model. Free it with nsheet_free. */
typedef struct nsheet_transcriber nsheet_transcriber;

/** One transcribed note; mirrors msl::Note. */
typedef struct {
    double onset;   /* seconds from the start of the signal */
    double offset;  /* seconds */
    int32_t pitch;  /* MIDI note number; the GM percussion note for drums */
    int32_t program;/* decoded MIDI program, or 128 for drums */
    bool is_drum;
} nsheet_note;

/** What one chunk added. Valid only for the duration of the callback. */
typedef struct {
    const nsheet_note* new_notes;
    size_t count;
    double finalized_through; /* seconds; every note ending before this is reported */
    float progress;           /* 0 to 1, non-decreasing */
} nsheet_update;

/**
 * Called synchronously on the transcribing thread, once per chunk and once
 * more at the end. Return false to cancel; nsheet_transcribe then returns
 * NSHEET_ERR_CANCELLED.
 */
typedef bool (*nsheet_progress_fn)(const nsheet_update* update, void* ctx);

/** Maps msl::Error one to one, plus NSHEET_OK. */
typedef enum nsheet_error {
    NSHEET_OK = 0,
    NSHEET_ERR_FILE_NOT_FOUND,
    NSHEET_ERR_INVALID_CHECKPOINT,
    NSHEET_ERR_UNSUPPORTED_ARCH,
    NSHEET_ERR_UNSUPPORTED_CHECKPOINT_VERSION,
    NSHEET_ERR_OUT_OF_MEMORY,
    NSHEET_ERR_CONTEXT_OVERFLOW,
    NSHEET_ERR_CANCELLED,
    NSHEET_ERR_INVALID_ARGUMENT,
    NSHEET_ERR_INTERNAL
} nsheet_error;

/**
 * Load a GGUF checkpoint. Blocking, seconds for a large model.
 *
 * @param out_error Receives NSHEET_OK, or the failure, when non-null.
 * @return The model, or null on failure.
 */
nsheet_transcriber* nsheet_load(const char* gguf_path, bool use_gpu, int* out_error);

/** @return "CPU", "Metal" or "Vulkan"; null for a null transcriber. */
const char* nsheet_backend_name(const nsheet_transcriber* transcriber);

/**
 * Transcribe a whole signal: 16 kHz mono float32. Blocking, seconds to
 * minutes; never call it from an audio thread. One call at a time per model.
 *
 * @param groups Instrument groups to restrict decoding to, or null for all.
 * @param cb Optional progress and cancellation; `ctx` is passed back to it.
 * @param out_notes On NSHEET_OK, a malloc'd array of `*out_count` notes the
 *        caller frees with nsheet_free_notes. Null when there are no notes.
 * @return NSHEET_OK, or the failure.
 */
int nsheet_transcribe(nsheet_transcriber* transcriber,
                      const float* samples,
                      size_t count,
                      const int32_t* groups,
                      size_t group_count,
                      nsheet_progress_fn cb,
                      void* ctx,
                      nsheet_note** out_notes,
                      size_t* out_count);

/** Free an array handed out by nsheet_transcribe. Null is a no-op. */
void nsheet_free_notes(nsheet_note* notes);

/** Free a model. Null is a no-op. */
void nsheet_free(nsheet_transcriber* transcriber);

/** @return A short, stable description of an nsheet_error, for logs. */
const char* nsheet_describe_error(int error);

/**
 * Every named instrument group, in enumerator order.
 *
 * @param out Where to write them, or null to only ask for the total.
 * @param cap How many fit in `out`.
 * @return The number written, or the total (35) when `out` is null.
 */
size_t nsheet_all_groups(int32_t* out, size_t cap);

/** @return The program the model emits for `group`, or -1 for an unknown one. */
int32_t nsheet_program_for(int32_t group);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* NSHEET_ENGINE_H */
