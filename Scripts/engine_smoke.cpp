// Exercises the C bridge end to end: load a checkpoint, transcribe 2 s of a
// 440 Hz sine, print the backend and the note count.
//
// Built and run by Scripts/engine-smoke.sh.

#include "../NeuralSheet/Engine/nsheet_engine.h"

#include <cmath>
#include <cstdio>
#include <vector>

namespace
{

constexpr int SAMPLE_RATE = 16000;
constexpr int DURATION_SECONDS = 2;

// The model misses a note that starts in the signal's very first frames, so the
// tone begins after a quarter second of silence and it reports A4 (pitch 69).
constexpr int LEAD_IN_SAMPLES = SAMPLE_RATE / 4;

bool onUpdate(const nsheet_update* update, void* /*ctx*/)
{
    std::printf("update: progress %.2f, %zu new notes, finalized through %.2f s\n",
                static_cast<double>(update->progress),
                update->count,
                update->finalized_through);
    return true;
}

} // namespace

int main(int argc, char** argv)
{
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <model.gguf>\n", argv[0]);
        return 2;
    }

    int error = NSHEET_OK;
    nsheet_transcriber* transcriber = nsheet_load(argv[1], true, &error);

    if (transcriber == nullptr) {
        std::fprintf(stderr, "load failed: %s (%d)\n", nsheet_describe_error(error), error);
        return 1;
    }

    std::printf("backend: %s\n", nsheet_backend_name(transcriber));

    std::vector<float> samples(static_cast<size_t>(SAMPLE_RATE) * DURATION_SECONDS, 0.0f);

    for (size_t i = LEAD_IN_SAMPLES; i < samples.size(); ++i) {
        const float seconds = static_cast<float>(i - LEAD_IN_SAMPLES) / static_cast<float>(SAMPLE_RATE);
        samples[i] = 0.5f * std::sin(2.0f * static_cast<float>(M_PI) * 440.0f * seconds);
    }

    nsheet_note* notes = nullptr;
    size_t count = 0;
    const int status =
        nsheet_transcribe(transcriber, samples.data(), samples.size(), nullptr, 0, onUpdate, nullptr, &notes, &count);

    if (status != NSHEET_OK) {
        std::fprintf(stderr, "transcribe failed: %s (%d)\n", nsheet_describe_error(status), status);
        nsheet_free(transcriber);
        return 1;
    }

    std::printf("notes: %zu\n", count);

    for (size_t i = 0; i < count && i < 5; ++i) {
        std::printf("  note %zu: onset %.2f, offset %.2f, pitch %d, program %d, drum %d\n",
                    i,
                    notes[i].onset,
                    notes[i].offset,
                    notes[i].pitch,
                    notes[i].program,
                    notes[i].is_drum ? 1 : 0);
    }

    nsheet_free_notes(notes);
    nsheet_free(transcriber);

    return 0;
}
