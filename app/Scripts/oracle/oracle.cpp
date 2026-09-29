// Dumps what the C++ engine computes -- hyperparameters, intermediate tensors,
// greedy token streams and note lists -- into the fixture directory the Swift
// port's tests compare against (docs/design/2026-09-29-swift-engine-design.md
// section 6). Built and run by Scripts/oracle/oracle.sh; see README.md there.
//
// Everything is written from the public headers plus cpp/src/instrument_groups.hpp,
// so this file is the only place that knows the fixture layout.

#include <muscriptor/model.hpp>
#include <muscriptor/muscriptor.hpp>
#include <muscriptor/stft.hpp>

#include <instrument_groups.hpp>

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <expected>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace fs = std::filesystem;

namespace
{

// The oracle pins the context to the design's figure rather than the header's
// default, so the Swift model can allocate exactly as much KV cache.
constexpr int N_CTX = 2538;

constexpr int CHUNK_SAMPLES = msl::Transcriber::SEGMENT_SAMPLES; // 80 000
constexpr int CHUNK_FRAMES = 501;                                // 1 + 80 000 / 160
constexpr int EOS_ID = 1;
constexpr int MAX_TOKENS = msl::Transcriber::MAX_TOKENS_PER_CHUNK;
constexpr int DUMPED_ROWS = 8;     // position rows and STFT frames
constexpr int DECODE_STEPS = 16;   // decode steps after the prefill

// The `band` selection of muscriptor.cpp's docs/TESTING.md, in its order: the
// conditioning rows and the forbidden mask both depend on it.
constexpr std::array<std::string_view, 5> BAND_INSTRUMENTS = {
    "distorted_electric_guitar", "synth_lead", "electric_bass", "drums", "voice"};

[[noreturn]] void fail(const std::string& inMessage)
{
    throw std::runtime_error(inMessage);
}

// --- WAV ---------------------------------------------------------------------

// Walks RIFF chunks and returns the `data` payload as float32, asserting the
// fixture's format: IEEE float (3), mono, 16 kHz. The Swift Fixtures.swift
// reader does the same walk, so a mismatch here is a mismatch there.
std::vector<float> readWav(const fs::path& inPath)
{
    std::ifstream in(inPath, std::ios::binary);

    if (!in) {
        fail("cannot open " + inPath.string());
    }

    std::vector<char> bytes((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());

    if (bytes.size() < 12 || std::memcmp(bytes.data(), "RIFF", 4) != 0 || std::memcmp(bytes.data() + 8, "WAVE", 4) != 0) {
        fail(inPath.string() + " is not a RIFF/WAVE file");
    }

    const auto readU32 = [&bytes](std::size_t inOffset) {
        std::uint32_t value = 0;
        std::memcpy(&value, bytes.data() + inOffset, 4);
        return value;
    };
    const auto readU16 = [&bytes](std::size_t inOffset) {
        std::uint16_t value = 0;
        std::memcpy(&value, bytes.data() + inOffset, 2);
        return value;
    };

    std::vector<float> samples;
    bool sawFormat = false;

    for (std::size_t offset = 12; offset + 8 <= bytes.size();) {
        const std::string id(bytes.data() + offset, 4);
        const std::size_t size = readU32(offset + 4);
        const std::size_t payload = offset + 8;

        if (payload + size > bytes.size()) {
            fail(inPath.string() + ": chunk " + id + " runs past the end of the file");
        }

        if (id == "fmt ") {
            if (size < 16) {
                fail(inPath.string() + ": fmt chunk is too short");
            }

            const std::uint16_t format = readU16(payload);
            const std::uint16_t channels = readU16(payload + 2);
            const std::uint32_t sampleRate = readU32(payload + 4);
            const std::uint16_t bits = readU16(payload + 14);

            if (format != 3 || channels != 1 || sampleRate != 16000 || bits != 32) {
                fail(inPath.string() + ": expected mono 16 kHz float32 (format 3), got format "
                     + std::to_string(format) + ", " + std::to_string(channels) + " channels, "
                     + std::to_string(sampleRate) + " Hz, " + std::to_string(bits) + " bits");
            }

            sawFormat = true;
        } else if (id == "data") {
            samples.resize(size / sizeof(float));
            std::memcpy(samples.data(), bytes.data() + payload, samples.size() * sizeof(float));
        }

        offset = payload + size + (size % 2); // chunks are padded to an even length
    }

    if (!sawFormat || samples.empty()) {
        fail(inPath.string() + ": no fmt or no data chunk");
    }

    return samples;
}

// --- writing -----------------------------------------------------------------

void writeFloats(const fs::path& inPath, std::span<const float> inValues)
{
    std::ofstream out(inPath, std::ios::binary);
    out.write(reinterpret_cast<const char*>(inValues.data()), static_cast<std::streamsize>(inValues.size_bytes()));

    if (!out) {
        fail("cannot write " + inPath.string());
    }
}

// %.17g round-trips a double exactly; %.9g does the same for a float, and keeps
// the hyperparameters readable.
std::string jsonDouble(double inValue)
{
    std::array<char, 64> buffer {};
    std::snprintf(buffer.data(), buffer.size(), "%.17g", inValue);
    return buffer.data();
}

std::string jsonFloat(float inValue)
{
    std::array<char, 64> buffer {};
    std::snprintf(buffer.data(), buffer.size(), "%.9g", static_cast<double>(inValue));
    return buffer.data();
}

std::string jsonString(std::string_view inValue)
{
    std::string quoted = "\"";

    for (const char c : inValue) {
        if (c == '"' || c == '\\') {
            quoted += '\\';
        }

        quoted += c;
    }

    return quoted + "\"";
}

template<typename T>
std::string jsonIntArray(std::span<const T> inValues)
{
    std::string text = "[";

    for (std::size_t i = 0; i < inValues.size(); ++i) {
        if (i != 0) {
            text += ", ";
        }

        text += std::to_string(inValues[i]);
    }

    return text + "]";
}

std::ofstream openJson(const fs::path& inPath)
{
    std::ofstream out(inPath);

    if (!out) {
        fail("cannot write " + inPath.string());
    }

    return out;
}

// --- dumps -------------------------------------------------------------------

void writeHparams(const fs::path& inPath,
                  const msl::Hparams& inHparams,
                  std::string_view inBackend,
                  std::string_view inCheckpoint,
                  std::string_view inCommit)
{
    std::ofstream out = openJson(inPath);

    out << "{\n";
    out << "  \"dim\": " << inHparams.dim << ",\n";
    out << "  \"n_head\": " << inHparams.n_head << ",\n";
    out << "  \"head_dim\": " << inHparams.head_dim << ",\n";
    out << "  \"n_layer\": " << inHparams.n_layer << ",\n";
    out << "  \"ffn_dim\": " << inHparams.ffn_dim << ",\n";
    out << "  \"vocab_size\": " << inHparams.vocab_size << ",\n";
    out << "  \"initial_token_id\": " << inHparams.initial_token_id << ",\n";
    out << "  \"logit_mask_start\": " << inHparams.logit_mask_start << ",\n";
    out << "  \"layer_norm_eps\": " << jsonFloat(inHparams.layer_norm_eps) << ",\n";
    out << "  \"max_period\": " << jsonFloat(inHparams.max_period) << ",\n";
    out << "  \"sample_rate\": " << inHparams.sample_rate << ",\n";
    out << "  \"n_fft\": " << inHparams.n_fft << ",\n";
    out << "  \"hop_length\": " << inHparams.hop_length << ",\n";
    out << "  \"frame_rate\": " << inHparams.frame_rate << ",\n";
    out << "  \"n_mels\": " << inHparams.n_mels << ",\n";
    out << "  \"log_eps\": " << jsonFloat(inHparams.log_eps) << ",\n";
    out << "  \"n_ctx\": " << N_CTX << ",\n";
    out << "  \"backend\": " << jsonString(inBackend) << ",\n";
    out << "  \"checkpoint\": " << jsonString(inCheckpoint) << ",\n";
    out << "  \"muscriptor_cpp_commit\": " << jsonString(inCommit) << "\n";
    out << "}\n";
}

// positions.f32, stft.f32, cond.f32, prefill_logits.f32, decode_logits.f32 and
// decode_steps.json: everything below the token level, from chunk 0.
void writeTensors(const fs::path& inDir, msl::Model& inModel, std::span<const float> inChunk0, std::span<const float> inCond)
{
    const msl::Hparams& hparams = inModel.hparams();

    const std::span<const float> positions = inModel.positionEmbeddings();
    writeFloats(inDir / "positions.f32", positions.first(static_cast<std::size_t>(DUMPED_ROWS) * hparams.dim));

    const std::vector<float> spectrum = inModel.stft().magnitudes(inChunk0);
    writeFloats(inDir / "stft.f32",
                std::span<const float>(spectrum).first(static_cast<std::size_t>(DUMPED_ROWS) * hparams.n_freq()));

    writeFloats(inDir / "cond.f32", inCond);

    inModel.reset();
    const std::array<std::int32_t, 1> prompt = {hparams.initial_token_id};
    std::vector<float> logits = inModel.prefill(inCond, CHUNK_FRAMES, prompt);
    writeFloats(inDir / "prefill_logits.f32", logits);

    const auto argmax = [](std::span<const float> inLogits) {
        std::int32_t best = 0;

        for (std::int32_t i = 1; i < static_cast<std::int32_t>(inLogits.size()); ++i) {
            if (inLogits[static_cast<std::size_t>(i)] > inLogits[static_cast<std::size_t>(best)]) {
                best = i;
            }
        }

        return best;
    };

    std::vector<std::int32_t> fed;
    std::vector<std::int32_t> picked;
    std::vector<float> decodeLogits;
    decodeLogits.reserve(static_cast<std::size_t>(DECODE_STEPS) * logits.size());

    for (int step = 0; step < DECODE_STEPS; ++step) {
        const std::int32_t token = argmax(logits); // the previous step's pick, the prefill's at step 0
        fed.push_back(token);
        logits = inModel.decode(token);
        picked.push_back(argmax(logits));
        decodeLogits.insert(decodeLogits.end(), logits.begin(), logits.end());
    }

    writeFloats(inDir / "decode_logits.f32", decodeLogits);

    std::ofstream out = openJson(inDir / "decode_steps.json");
    out << "{\n";
    out << "  \"fed\": " << jsonIntArray(std::span<const std::int32_t>(fed)) << ",\n";
    out << "  \"argmax\": " << jsonIntArray(std::span<const std::int32_t>(picked)) << "\n";
    out << "}\n";
}

void writeTokens(const fs::path& inDir, msl::Model& inModel, std::span<const float> inSamples)
{
    std::ofstream out = openJson(inDir / "tokens.json");
    out << "{\n  \"chunks\": [\n";

    const std::size_t chunks = inSamples.size() / CHUNK_SAMPLES;

    for (std::size_t chunk = 0; chunk < chunks; ++chunk) {
        const std::span<const float> audio = inSamples.subspan(chunk * CHUNK_SAMPLES, CHUNK_SAMPLES);

        inModel.reset();
        const std::vector<float> cond = inModel.encodeAudio(audio);
        const std::vector<std::int32_t> tokens = inModel.generate(cond, CHUNK_FRAMES, MAX_TOKENS, EOS_ID);

        std::printf("  tokens chunk %zu: %zu tokens, last %d\n", chunk, tokens.size(), tokens.empty() ? -1 : tokens.back());

        out << "    " << jsonIntArray(std::span<const std::int32_t>(tokens));
        out << (chunk + 1 == chunks ? "\n" : ",\n");
    }

    out << "  ]\n}\n";
}

// The band variant at the token level: the conditioning rows lengthen the
// prefix and the forbidden ids mask every other instrument away.
void writeBandTokens(const fs::path& inDir,
                     msl::Model& inModel,
                     std::span<const float> inCond,
                     std::span<const msl::InstrumentGroup> inBand)
{
    inModel.setInstrumentRows(msl::InstrumentGroups::conditioningRows(inBand));
    inModel.setForbiddenTokens(msl::InstrumentGroups::forbiddenTokenIds(inBand));

    inModel.reset();
    const std::vector<std::int32_t> tokens = inModel.generate(inCond, CHUNK_FRAMES, MAX_TOKENS, EOS_ID);

    std::ofstream out = openJson(inDir / "tokens_band.json");
    out << "{\n  \"instruments\": [";

    for (std::size_t i = 0; i < inBand.size(); ++i) {
        out << (i == 0 ? "" : ", ") << jsonString(msl::instrumentName(inBand[i]));
    }

    out << "],\n";
    out << "  \"chunk0\": " << jsonIntArray(std::span<const std::int32_t>(tokens)) << "\n";
    out << "}\n";
}

struct Update {
    double finalized_through = 0.0;
    float progress = 0.0f;
    std::size_t new_notes = 0;
};

void writeNotes(const fs::path& inDir,
                msl::Transcriber& inTranscriber,
                std::span<const float> inSamples,
                std::string_view inVariant,
                const msl::TranscribeOptions& inOptions)
{
    std::vector<Update> updates;
    const msl::NoteCallback callback = [&updates](const msl::TranscriptionUpdate& inUpdate) {
        updates.push_back({inUpdate.finalized_through, inUpdate.progress, inUpdate.new_notes.size()});
        return true;
    };

    const std::expected<std::vector<msl::Note>, msl::Error> notes =
        inTranscriber.transcribe(inSamples, inOptions, callback);

    if (!notes) {
        fail(std::string("transcribe (") + std::string(inVariant) + ") failed: " + msl::describe(notes.error()));
    }

    std::ofstream out = openJson(inDir / ("notes_" + std::string(inVariant) + ".json"));
    out << "{\n";
    out << "  \"variant\": " << jsonString(inVariant) << ",\n";
    out << "  \"instruments\": [";

    for (std::size_t i = 0; i < inOptions.instruments.size(); ++i) {
        out << (i == 0 ? "" : ", ") << jsonString(msl::instrumentName(inOptions.instruments[i]));
    }

    out << "],\n";
    out << "  \"prelude_forcing\": " << (inOptions.prelude_forcing ? "true" : "false") << ",\n";
    out << "  \"notes\": [\n";

    for (std::size_t i = 0; i < notes->size(); ++i) {
        const msl::Note& note = (*notes)[i];
        out << "    {\"onset\": " << jsonDouble(note.onset) << ", \"offset\": " << jsonDouble(note.offset)
            << ", \"pitch\": " << note.pitch << ", \"program\": " << note.program
            << ", \"is_drum\": " << (note.is_drum ? "true" : "false") << "}";
        out << (i + 1 == notes->size() ? "\n" : ",\n");
    }

    out << "  ],\n";
    out << "  \"updates\": [\n";

    for (std::size_t i = 0; i < updates.size(); ++i) {
        out << "    {\"finalized_through\": " << jsonDouble(updates[i].finalized_through)
            << ", \"progress\": " << jsonFloat(updates[i].progress) << ", \"new_notes\": " << updates[i].new_notes
            << "}";
        out << (i + 1 == updates.size() ? "\n" : ",\n");
    }

    out << "  ]\n}\n";

    std::printf("  notes_%s.json: %zu notes, %zu updates\n", std::string(inVariant).c_str(), notes->size(), updates.size());
}

std::vector<msl::InstrumentGroup> groupsFor(std::span<const std::string_view> inNames)
{
    std::vector<msl::InstrumentGroup> groups;

    for (const std::string_view name : inNames) {
        const std::optional<msl::InstrumentGroup> group = msl::InstrumentGroups::groupForName(name);

        if (!group) {
            fail("no instrument group named " + std::string(name));
        }

        groups.push_back(*group);
    }

    return groups;
}

int run(int argc, char** argv)
{
    if (argc != 6) {
        std::fprintf(stderr, "usage: %s <model.gguf> <cpu|gpu> <fixture.wav> <out-dir> <muscriptor-commit>\n", argv[0]);
        return 2;
    }

    const fs::path gguf = argv[1];
    const std::string_view device = argv[2];
    const fs::path wav = argv[3];
    const fs::path outDir = argv[4];
    const std::string_view commit = argv[5];

    if (device != "cpu" && device != "gpu") {
        std::fprintf(stderr, "error: device must be cpu or gpu, not %s\n", argv[2]);
        return 2;
    }

    const bool gpu = device == "gpu";
    const char* expected = gpu ? "Metal" : "CPU";

    const std::vector<float> samples = readWav(wav);

    if (samples.size() % CHUNK_SAMPLES != 0) {
        fail("the fixture must be a whole number of 5 s chunks, got " + std::to_string(samples.size()) + " samples");
    }

    fs::create_directories(outDir);

    const std::vector<msl::InstrumentGroup> band = groupsFor(BAND_INSTRUMENTS);
    const std::span<const float> chunk0(samples.data(), CHUNK_SAMPLES);

    // The model and the transcriber each hold their own copy of the weights, so
    // the model is released before the transcriber loads.
    {
        msl::Model model = msl::Model::load(gguf, {.n_ctx = N_CTX, .use_gpu = gpu});

        if (std::string_view(model.backendName()) != expected) {
            fail(std::string("model backend is ") + model.backendName() + ", expected " + expected);
        }

        const msl::Hparams& hparams = model.hparams();
        writeHparams(outDir / "hparams.json", hparams, expected, gguf.filename().string(), commit);

        const std::vector<float> cond = model.encodeAudio(chunk0);

        if (cond.size() != static_cast<std::size_t>(CHUNK_FRAMES) * hparams.dim) {
            fail("conditioning is " + std::to_string(cond.size()) + " floats, expected "
                 + std::to_string(static_cast<std::size_t>(CHUNK_FRAMES) * hparams.dim));
        }

        std::printf("%s %s: dim %d, vocab %d, backend %s\n",
                    gguf.filename().string().c_str(),
                    expected,
                    hparams.dim,
                    hparams.vocab_size,
                    model.backendName());

        writeTensors(outDir, model, chunk0, cond);
        writeTokens(outDir, model, samples);
        writeBandTokens(outDir, model, cond, band);
    }

    std::expected<msl::Transcriber, msl::Error> transcriber = msl::Transcriber::load(gguf, {.use_gpu = gpu});

    if (!transcriber) {
        fail(std::string("Transcriber::load failed: ") + msl::describe(transcriber.error()));
    }

    if (std::string_view(transcriber->backendName()) != expected) {
        fail(std::string("transcriber backend is ") + transcriber->backendName() + ", expected " + expected);
    }

    const std::vector<msl::InstrumentGroup> bass = groupsFor(std::array<std::string_view, 1> {"electric_bass"});

    writeNotes(outDir, *transcriber, samples, "plain", {.prelude_forcing = false});
    writeNotes(outDir, *transcriber, samples, "prelude", {.prelude_forcing = true});
    writeNotes(outDir, *transcriber, samples, "bass", {.instruments = bass, .prelude_forcing = true});
    writeNotes(outDir, *transcriber, samples, "band", {.instruments = band, .prelude_forcing = true});

    return 0;
}

} // namespace

int main(int argc, char** argv)
{
    try {
        return run(argc, argv);
    } catch (const std::exception& error) {
        std::fprintf(stderr, "error: %s\n", error.what());
        return 1;
    }
}
