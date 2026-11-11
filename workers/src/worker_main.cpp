#include <whisper.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <vector>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

namespace {

constexpr int kFailureExit = 1;
constexpr std::size_t kMaxDiagnosticBytes = 1024;
constexpr std::size_t kMaxReadyFieldBytes = 256;
constexpr std::uint32_t kMaxServeFrameBytes = 4 * 1024 * 1024;
constexpr std::uint32_t kServeProtocolVersion = 1;
constexpr float kSilentPeakThreshold = 0.001F;
constexpr float kSilentRmsThreshold = 0.0005F;
constexpr float kMaximumNoSpeechProbability = 0.7F;
constexpr const char* kVadModelFilename = "ggml-silero-v6.2.0.bin";

struct Arguments {
    std::filesystem::path model;
    std::filesystem::path input;
};

struct ServeArguments {
    std::filesystem::path model;
};

enum class FrameReadResult {
    Frame,
    EndOfStream,
    Invalid,
};

std::string escape_json(const std::string& value) {
    std::string escaped;
    escaped.reserve(value.size());
    for (unsigned char character : value) {
        switch (character) {
        case '"': escaped += "\\\""; break;
        case '\\': escaped += "\\\\"; break;
        case '\b': escaped += "\\b"; break;
        case '\f': escaped += "\\f"; break;
        case '\n': escaped += "\\n"; break;
        case '\r': escaped += "\\r"; break;
        case '\t': escaped += "\\t"; break;
        default:
            if (character < 0x20) {
                escaped += "?";
            } else {
                escaped += static_cast<char>(character);
            }
        }
    }
    return escaped;
}

void emit_result(std::uint64_t elapsed_ms, const std::string& transcript, int exit_status, const std::string& failure_code) {
    const std::string diagnostic = failure_code.substr(0, kMaxDiagnosticBytes);
    std::cout << "{\"backend\":\"" << WORKER_BACKEND
              << "\",\"workerBuild\":\"" << WORKER_BUILD_ID
              << "\",\"modelRevision\":\"" << WORKER_MODEL_REVISION
              << "\",\"elapsedMs\":" << elapsed_ms
              << ",\"transcript\":\"" << escape_json(transcript)
              << "\",\"exitStatus\":" << exit_status
              << ",\"diagnostics\":{";
    if (!diagnostic.empty()) {
        std::cout << "\"failureCode\":\"" << escape_json(diagnostic) << "\"";
    }
    std::cout << "}}" << std::endl;
}

void emit_ready() {
    const auto backend = escape_json(std::string(WORKER_BACKEND).substr(0, kMaxReadyFieldBytes));
    const auto worker_build = escape_json(std::string(WORKER_BUILD_ID).substr(0, kMaxReadyFieldBytes));
    const auto model_revision = escape_json(std::string(WORKER_MODEL_REVISION).substr(0, kMaxReadyFieldBytes));
    std::cout << "{\"event\":\"ready\",\"protocolVersion\":" << kServeProtocolVersion
              << ",\"maxFrameBytes\":" << kMaxServeFrameBytes
              << ",\"backend\":\"" << backend
              << "\",\"workerBuild\":\"" << worker_build
              << "\",\"modelRevision\":\"" << model_revision
              << "\"}" << std::endl;
}

bool parse_arguments(int argc, char** argv, Arguments& arguments) {
    if (argc != 8 || std::string(argv[1]) != "--model" || std::string(argv[3]) != "--language"
        || std::string(argv[4]) != "vi" || std::string(argv[5]) != "--input"
        || std::string(argv[7]) != "--json") {
        return false;
    }
    arguments.model = argv[2];
    arguments.input = argv[6];
    return std::filesystem::is_regular_file(arguments.model)
        && std::filesystem::is_regular_file(arguments.input);
}

bool parse_serve_arguments(int argc, char** argv, ServeArguments& arguments) {
    if (argc != 7 || std::string(argv[1]) != "--model" || std::string(argv[3]) != "--language"
        || std::string(argv[4]) != "vi" || std::string(argv[5]) != "--serve"
        || std::string(argv[6]) != "--json") {
        return false;
    }
    arguments.model = argv[2];
    return std::filesystem::is_regular_file(arguments.model);
}

std::uint16_t read_u16(const std::vector<std::uint8_t>& bytes, std::size_t offset) {
    return static_cast<std::uint16_t>(bytes[offset])
        | (static_cast<std::uint16_t>(bytes[offset + 1]) << 8U);
}

std::uint32_t read_u32(const std::vector<std::uint8_t>& bytes, std::size_t offset) {
    return static_cast<std::uint32_t>(bytes[offset])
        | (static_cast<std::uint32_t>(bytes[offset + 1]) << 8U)
        | (static_cast<std::uint32_t>(bytes[offset + 2]) << 16U)
        | (static_cast<std::uint32_t>(bytes[offset + 3]) << 24U);
}

bool load_pcm16_wav_bytes(const std::vector<std::uint8_t>& bytes, std::vector<float>& samples) {
    if (bytes.size() < 44 || std::string(reinterpret_cast<const char*>(bytes.data()), 4) != "RIFF"
        || std::string(reinterpret_cast<const char*>(bytes.data() + 8), 4) != "WAVE") {
        return false;
    }

    std::size_t offset = 12;
    bool valid_format = false;
    const std::uint8_t* pcm = nullptr;
    std::size_t pcm_bytes = 0;
    while (offset + 8 <= bytes.size()) {
        const std::string chunk(reinterpret_cast<const char*>(bytes.data() + offset), 4);
        const std::uint32_t chunk_size = read_u32(bytes, offset + 4);
        offset += 8;
        if (offset + chunk_size > bytes.size()) {
            return false;
        }
        if (chunk == "fmt " && chunk_size >= 16) {
            valid_format = read_u16(bytes, offset) == 1 && read_u16(bytes, offset + 2) == 1
                && read_u32(bytes, offset + 4) == 16000 && read_u16(bytes, offset + 14) == 16;
        } else if (chunk == "data") {
            pcm = bytes.data() + offset;
            pcm_bytes = chunk_size;
        }
        offset += chunk_size + (chunk_size % 2);
    }
    if (!valid_format || pcm == nullptr || pcm_bytes == 0 || pcm_bytes % 2 != 0) {
        return false;
    }
    samples.clear();
    samples.reserve(pcm_bytes / 2);
    for (std::size_t index = 0; index < pcm_bytes; index += 2) {
        const auto value = static_cast<std::int16_t>(static_cast<std::uint16_t>(pcm[index])
            | (static_cast<std::uint16_t>(pcm[index + 1]) << 8U));
        samples.push_back(static_cast<float>(value) / 32768.0F);
    }
    return true;
}

bool load_pcm16_wav(const std::filesystem::path& path, std::vector<float>& samples) {
    std::ifstream input(path, std::ios::binary);
    std::vector<std::uint8_t> bytes((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
    return load_pcm16_wav_bytes(bytes, samples);
}

std::filesystem::path vad_model_path_for(const char* executable) {
    return std::filesystem::absolute(std::filesystem::path(executable)).parent_path()
        / kVadModelFilename;
}

bool is_effectively_silent(const std::vector<float>& samples) {
    if (samples.empty()) {
        return true;
    }

    float peak = 0.0F;
    double sum_squares = 0.0;
    for (const float sample : samples) {
        peak = std::max(peak, std::abs(sample));
        sum_squares += static_cast<double>(sample) * sample;
    }
    const double rms = std::sqrt(sum_squares / samples.size());
    return peak < kSilentPeakThreshold && rms < kSilentRmsThreshold;
}

bool transcribe_loaded_context(
        whisper_context* context,
        const std::filesystem::path& vad_model,
        bool use_vad,
        const std::vector<float>& samples,
        std::string& transcript) {
    if (is_effectively_silent(samples)) {
        return true;
    }
    if (use_vad && !std::filesystem::is_regular_file(vad_model)) {
        return false;
    }

    // Prefer the strongest deterministic transcript among several candidates.
    whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH);
    params.beam_search.beam_size = 5;
    params.language = "vi";
    params.translate = false;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.no_timestamps = true;
    params.no_context = true;
    params.suppress_nst = true;
    params.temperature = 0.0F;
    params.temperature_inc = 0.0F;
    params.no_speech_thold = kMaximumNoSpeechProbability;
    const std::string vad_model_path = vad_model.string();
    if (use_vad) {
        params.vad = true;
        params.vad_model_path = vad_model_path.c_str();
        params.vad_params = whisper_vad_default_params();
        params.vad_params.threshold = 0.35F;
        params.vad_params.min_speech_duration_ms = 120;
        params.vad_params.min_silence_duration_ms = 200;
        params.vad_params.speech_pad_ms = 120;
    }
    const int result = whisper_full(context, params, samples.data(), static_cast<int>(samples.size()));
    if (result == 0) {
        const int segments = whisper_full_n_segments(context);
        for (int index = 0; index < segments; ++index) {
            if (whisper_full_get_segment_no_speech_prob(context, index) < kMaximumNoSpeechProbability) {
                transcript += whisper_full_get_segment_text(context, index);
            }
        }
    }
    return result == 0;
}

bool transcribe(const Arguments& arguments, std::string& transcript) {
    std::vector<float> samples;
    if (!load_pcm16_wav(arguments.input, samples)) {
        return false;
    }
    whisper_context_params context_params = whisper_context_default_params();
    whisper_context* context = whisper_init_from_file_with_params(arguments.model.string().c_str(), context_params);
    if (context == nullptr) {
        return false;
    }
    const bool completed = transcribe_loaded_context(context, {}, false, samples, transcript);
    whisper_free(context);
    return completed && !transcript.empty();
}

bool set_serve_binary_stdio() {
#ifdef _WIN32
    return _setmode(_fileno(stdin), _O_BINARY) != -1
        && _setmode(_fileno(stdout), _O_BINARY) != -1;
#else
    return true;
#endif
}

FrameReadResult read_next_frame(std::vector<std::uint8_t>& frame) {
    std::uint8_t header[sizeof(std::uint32_t)] = {};
    std::cin.read(reinterpret_cast<char*>(header), sizeof(header));
    const std::streamsize header_bytes = std::cin.gcount();
    if (header_bytes == 0 && std::cin.eof()) {
        return FrameReadResult::EndOfStream;
    }
    if (header_bytes != static_cast<std::streamsize>(sizeof(header))) {
        return FrameReadResult::Invalid;
    }
    const std::uint32_t length = static_cast<std::uint32_t>(header[0])
        | (static_cast<std::uint32_t>(header[1]) << 8U)
        | (static_cast<std::uint32_t>(header[2]) << 16U)
        | (static_cast<std::uint32_t>(header[3]) << 24U);
    if (length == 0) {
        return FrameReadResult::EndOfStream;
    }
    if (length > kMaxServeFrameBytes) {
        return FrameReadResult::Invalid;
    }
    frame.resize(length);
    std::cin.read(reinterpret_cast<char*>(frame.data()), static_cast<std::streamsize>(frame.size()));
    return std::cin.gcount() == static_cast<std::streamsize>(frame.size())
        ? FrameReadResult::Frame
        : FrameReadResult::Invalid;
}

int run_serve(const ServeArguments& arguments, const std::filesystem::path& vad_model) {
    if (!set_serve_binary_stdio()) {
        emit_result(0, "", kFailureExit, "stdio-binary-mode-failed");
        std::cerr << "worker failed: stdio-binary-mode-failed" << std::endl;
        return kFailureExit;
    }
    if (!std::filesystem::is_regular_file(vad_model)) {
        emit_result(0, "", kFailureExit, "vad-model-missing");
        std::cerr << "worker failed: vad-model-missing" << std::endl;
        return kFailureExit;
    }

    whisper_context_params context_params = whisper_context_default_params();
    whisper_context* context = whisper_init_from_file_with_params(arguments.model.string().c_str(), context_params);
    if (context == nullptr) {
        emit_result(0, "", kFailureExit, "model-load-failed");
        std::cerr << "worker failed: model-load-failed" << std::endl;
        return kFailureExit;
    }

    emit_ready();
    for (;;) {
        std::vector<std::uint8_t> wav;
        const FrameReadResult frame_result = read_next_frame(wav);
        if (frame_result == FrameReadResult::EndOfStream) {
            whisper_free(context);
            return 0;
        }
        if (frame_result == FrameReadResult::Invalid) {
            emit_result(0, "", kFailureExit, "invalid-frame");
            std::cerr << "worker failed: invalid-frame" << std::endl;
            whisper_free(context);
            return kFailureExit;
        }

        const auto started = std::chrono::steady_clock::now();
        std::vector<float> samples;
        if (!load_pcm16_wav_bytes(wav, samples)) {
            const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - started).count();
            emit_result(static_cast<std::uint64_t>(std::max<std::int64_t>(0, elapsed)), "", kFailureExit, "invalid-wav");
            continue;
        }

        whisper_reset_timings(context);
        std::string transcript;
        if (!transcribe_loaded_context(context, vad_model, true, samples, transcript)) {
            const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - started).count();
            emit_result(static_cast<std::uint64_t>(std::max<std::int64_t>(0, elapsed)), "", kFailureExit, "transcription-failed");
            continue;
        }
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - started).count();
        // An empty transcript is a successful no-speech result in serve mode.
        emit_result(static_cast<std::uint64_t>(std::max<std::int64_t>(0, elapsed)), transcript, 0, "");
    }
}

} // namespace

int main(int argc, char** argv) {
    const auto started = std::chrono::steady_clock::now();
    const auto vad_model = vad_model_path_for(argv[0]);
    Arguments arguments;
    if (parse_arguments(argc, argv, arguments)) {
        std::string transcript;
        if (!transcribe(arguments, transcript)) {
            const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - started).count();
            emit_result(static_cast<std::uint64_t>(std::max<std::int64_t>(0, elapsed)), "", kFailureExit, "transcription-failed");
            std::cerr << "worker failed: transcription-failed" << std::endl;
            return kFailureExit;
        }
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - started).count();
        emit_result(static_cast<std::uint64_t>(std::max<std::int64_t>(0, elapsed)), transcript, 0, "");
        return 0;
    }

    ServeArguments serve_arguments;
    if (parse_serve_arguments(argc, argv, serve_arguments)) {
        return run_serve(serve_arguments, vad_model);
    }

    emit_result(0, "", kFailureExit, "invalid-arguments");
    std::cerr << "worker failed: invalid-arguments" << std::endl;
    return kFailureExit;
}
