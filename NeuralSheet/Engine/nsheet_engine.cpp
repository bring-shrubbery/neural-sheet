#include "nsheet_engine.h"

#include <muscriptor/muscriptor.hpp>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <mutex>
#include <new>
#include <span>
#include <string_view>
#include <utility>
#include <vector>

struct nsheet_transcriber {
    explicit nsheet_transcriber(msl::Transcriber&& inTranscriber)
        : transcriber(std::move(inTranscriber))
    {
    }

    msl::Transcriber transcriber;
};

namespace
{

int toCode(msl::Error inError)
{
    switch (inError) {
        case msl::Error::FileNotFound:
            return NSHEET_ERR_FILE_NOT_FOUND;
        case msl::Error::InvalidCheckpoint:
            return NSHEET_ERR_INVALID_CHECKPOINT;
        case msl::Error::UnsupportedArch:
            return NSHEET_ERR_UNSUPPORTED_ARCH;
        case msl::Error::UnsupportedCheckpointVersion:
            return NSHEET_ERR_UNSUPPORTED_CHECKPOINT_VERSION;
        case msl::Error::OutOfMemory:
            return NSHEET_ERR_OUT_OF_MEMORY;
        case msl::Error::ContextOverflow:
            return NSHEET_ERR_CONTEXT_OVERFLOW;
        case msl::Error::Cancelled:
            return NSHEET_ERR_CANCELLED;
        case msl::Error::InvalidArgument:
            return NSHEET_ERR_INVALID_ARGUMENT;
        case msl::Error::Internal:
            return NSHEET_ERR_INTERNAL;
    }

    return NSHEET_ERR_INTERNAL;
}

msl::Error toError(int inCode)
{
    switch (inCode) {
        case NSHEET_ERR_FILE_NOT_FOUND:
            return msl::Error::FileNotFound;
        case NSHEET_ERR_INVALID_CHECKPOINT:
            return msl::Error::InvalidCheckpoint;
        case NSHEET_ERR_UNSUPPORTED_ARCH:
            return msl::Error::UnsupportedArch;
        case NSHEET_ERR_UNSUPPORTED_CHECKPOINT_VERSION:
            return msl::Error::UnsupportedCheckpointVersion;
        case NSHEET_ERR_OUT_OF_MEMORY:
            return msl::Error::OutOfMemory;
        case NSHEET_ERR_CONTEXT_OVERFLOW:
            return msl::Error::ContextOverflow;
        case NSHEET_ERR_CANCELLED:
            return msl::Error::Cancelled;
        case NSHEET_ERR_INVALID_ARGUMENT:
            return msl::Error::InvalidArgument;
        default:
            return msl::Error::Internal;
    }
}

nsheet_note toNote(const msl::Note& inNote)
{
    nsheet_note note;
    note.onset = inNote.onset;
    note.offset = inNote.offset;
    note.pitch = static_cast<int32_t>(inNote.pitch);
    note.program = static_cast<int32_t>(inNote.program);
    note.is_drum = inNote.is_drum;
    return note;
}

/** ggml's warnings and errors, once per process, on stderr. */
void installLogSink()
{
    static std::once_flag once;

    std::call_once(once, [] {
        msl::setLogCallback(
            [](msl::LogLevel, std::string_view inText) {
                std::fprintf(stderr, "%.*s", static_cast<int>(inText.size()), inText.data());
            },
            msl::LogLevel::Warn);
    });
}

} // namespace

nsheet_transcriber* nsheet_load(const char* gguf_path, bool use_gpu, int* out_error)
{
    if (out_error != nullptr) {
        *out_error = NSHEET_OK;
    }

    if (gguf_path == nullptr) {
        if (out_error != nullptr) {
            *out_error = NSHEET_ERR_INVALID_ARGUMENT;
        }

        return nullptr;
    }

    installLogSink();

    try {
        auto loaded = msl::Transcriber::load(std::filesystem::path(gguf_path), {.use_gpu = use_gpu});

        if (!loaded) {
            if (out_error != nullptr) {
                *out_error = toCode(loaded.error());
            }

            return nullptr;
        }

        return new nsheet_transcriber(std::move(*loaded));
    } catch (const msl::Exception& e) {
        if (out_error != nullptr) {
            *out_error = toCode(e.error());
        }
    } catch (const std::bad_alloc&) {
        if (out_error != nullptr) {
            *out_error = NSHEET_ERR_OUT_OF_MEMORY;
        }
    } catch (...) {
        if (out_error != nullptr) {
            *out_error = NSHEET_ERR_INTERNAL;
        }
    }

    return nullptr;
}

const char* nsheet_backend_name(const nsheet_transcriber* transcriber)
{
    return transcriber == nullptr ? nullptr : transcriber->transcriber.backendName();
}

int nsheet_transcribe(nsheet_transcriber* transcriber,
                      const float* samples,
                      size_t count,
                      const int32_t* groups,
                      size_t group_count,
                      nsheet_progress_fn cb,
                      void* ctx,
                      nsheet_note** out_notes,
                      size_t* out_count)
{
    if (transcriber == nullptr || out_notes == nullptr || out_count == nullptr
        || (samples == nullptr && count > 0) || (groups == nullptr && group_count > 0)) {
        return NSHEET_ERR_INVALID_ARGUMENT;
    }

    *out_notes = nullptr;
    *out_count = 0;

    try {
        msl::TranscribeOptions options;
        options.instruments.reserve(group_count);

        for (size_t i = 0; i < group_count; ++i) {
            options.instruments.push_back(static_cast<msl::InstrumentGroup>(groups[i]));
        }

        // Reused across chunks so the copy does not reallocate every time.
        std::vector<nsheet_note> staged;

        msl::NoteCallback callback;

        if (cb != nullptr) {
            callback = [cb, ctx, &staged](const msl::TranscriptionUpdate& inUpdate) {
                staged.clear();
                staged.reserve(inUpdate.new_notes.size());

                for (const msl::Note& note: inUpdate.new_notes) {
                    staged.push_back(toNote(note));
                }

                nsheet_update update;
                update.new_notes = staged.empty() ? nullptr : staged.data();
                update.count = staged.size();
                update.finalized_through = inUpdate.finalized_through;
                update.progress = inUpdate.progress;

                return cb(&update, ctx);
            };
        }

        auto result = transcriber->transcriber.transcribe(std::span<const float>(samples, count), options, callback);

        if (!result) {
            return toCode(result.error());
        }

        const std::vector<msl::Note>& notes = *result;

        if (notes.empty()) {
            return NSHEET_OK;
        }

        auto* out = static_cast<nsheet_note*>(std::malloc(notes.size() * sizeof(nsheet_note)));

        if (out == nullptr) {
            return NSHEET_ERR_OUT_OF_MEMORY;
        }

        for (size_t i = 0; i < notes.size(); ++i) {
            out[i] = toNote(notes[i]);
        }

        *out_notes = out;
        *out_count = notes.size();

        return NSHEET_OK;
    } catch (const msl::Exception& e) {
        return toCode(e.error());
    } catch (const std::bad_alloc&) {
        return NSHEET_ERR_OUT_OF_MEMORY;
    } catch (...) {
        return NSHEET_ERR_INTERNAL;
    }
}

void nsheet_free_notes(nsheet_note* notes)
{
    std::free(notes);
}

void nsheet_free(nsheet_transcriber* transcriber)
{
    delete transcriber;
}

const char* nsheet_describe_error(int error)
{
    if (error == NSHEET_OK) {
        return "ok";
    }

    return msl::describe(toError(error));
}

size_t nsheet_all_groups(int32_t* out, size_t cap)
{
    const std::span<const msl::InstrumentGroup> groups = msl::allInstrumentGroups();

    if (out == nullptr) {
        return groups.size();
    }

    const size_t n = cap < groups.size() ? cap : groups.size();

    for (size_t i = 0; i < n; ++i) {
        out[i] = static_cast<int32_t>(groups[i]);
    }

    return n;
}

int32_t nsheet_program_for(int32_t group)
{
    return static_cast<int32_t>(msl::programFor(static_cast<msl::InstrumentGroup>(group)));
}
