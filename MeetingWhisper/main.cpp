#include "whisper.h"
#include "audio_gate.h"

#include <algorithm>
#include <charconv>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <iomanip>
#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace {

bool parseInteger(const char * value, const int minimum, const int maximum, int & result) {
    const char * end = value + std::strlen(value);
    const auto parsed = std::from_chars(value, end, result);
    return parsed.ec == std::errc() && parsed.ptr == end && result >= minimum && result <= maximum;
}

std::string jsonEscape(const char * value) {
    std::string result;
    for (const unsigned char character : std::string(value ? value : "")) {
        switch (character) {
            case '"': result += "\\\""; break;
            case '\\': result += "\\\\"; break;
            case '\b': result += "\\b"; break;
            case '\f': result += "\\f"; break;
            case '\n': result += "\\n"; break;
            case '\r': result += "\\r"; break;
            case '\t': result += "\\t"; break;
            default:
                if (character < 0x20) {
                    char escaped[7];
                    std::snprintf(escaped, sizeof(escaped), "\\u%04x", character);
                    result += escaped;
                } else {
                    result += static_cast<char>(character);
                }
        }
    }
    return result;
}

bool emitChunk(whisper_context * context, whisper_full_params parameters,
               const std::vector<float> & samples, const double offsetSeconds,
               const double minimumLocalStart) {
    if (samples.empty()) return true;
    if (!meeting_whisper::hasSpeechLevelEnergy(samples.data(), samples.size())) return true;
    if (whisper_full(context, parameters, samples.data(), static_cast<int>(samples.size())) != 0) {
        std::cerr << "Whisper could not process a live audio chunk.\n";
        return false;
    }
    for (int index = 0; index < whisper_full_n_segments(context); ++index) {
        double start = static_cast<double>(whisper_full_get_segment_t0(context, index)) / 100.0;
        double end = static_cast<double>(whisper_full_get_segment_t1(context, index)) / 100.0;
        const char * text = whisper_full_get_segment_text(context, index);
        if (!text || std::strlen(text) == 0) continue;
        const double duration = static_cast<double>(samples.size()) / WHISPER_SAMPLE_RATE;
        start = std::clamp(start, minimumLocalStart, duration);
        end = std::clamp(end, minimumLocalStart, duration);
        if (end <= start) continue;

        std::string segmentText(text);
        if (minimumLocalStart > 0.0 &&
            whisper_full_get_segment_t0(context, index) < minimumLocalStart * 100.0) {
            // A segment can straddle the overlap boundary. Dropping that entire
            // segment loses the fresh speech it contains; retain its new words.
            struct Word { std::string text; double start; double end; };
            std::vector<Word> words;
            bool usableTimes = true;
            for (int tokenIndex = 0; tokenIndex < whisper_full_n_tokens(context, index); ++tokenIndex) {
                const auto token = whisper_full_get_token_data(context, index, tokenIndex);
                if (token.id >= whisper_token_eot(context)) continue;
                const char * tokenText = whisper_full_get_token_text(context, index, tokenIndex);
                if (!tokenText || !*tokenText) continue;
                if (token.t0 < 0 || token.t1 < token.t0 || (token.t0 == 0 && token.t1 == 0)) {
                    usableTimes = false;
                    break;
                }
                const double tokenStart = static_cast<double>(token.t0) / 100.0;
                const double tokenEnd = static_cast<double>(token.t1) / 100.0;
                if (words.empty() || std::isspace(static_cast<unsigned char>(*tokenText))) {
                    words.push_back({tokenText, tokenStart, tokenEnd});
                } else {
                    // Keep subword tokens together so trimming cannot produce
                    // a word fragment such as "ly" instead of "freshly".
                    words.back().text += tokenText;
                    words.back().end = std::max(words.back().end, tokenEnd);
                }
            }
            if (usableTimes && !words.empty()) {
                segmentText.clear();
                bool firstWord = true;
                for (const auto & word : words) {
                    if (word.end <= minimumLocalStart) continue;
                    if (firstWord) {
                        start = std::clamp(word.start, minimumLocalStart, end);
                        firstWord = false;
                    }
                    segmentText += word.text;
                }
                if (segmentText.empty() || end <= start) continue;
            }
            // If timestamps are unavailable, keep a crossing segment intact.
            // Repeated overlap text is preferable to silently losing new speech.
        }
        const double startSeconds = offsetSeconds + start;
        const double endSeconds = offsetSeconds + end;
        std::cout << "{\"type\":\"segment\",\"start\":" << startSeconds
                  << ",\"end\":" << endSeconds << ",\"text\":\""
                  << jsonEscape(segmentText.c_str()) << "\"}\n";
    }
    std::cout.flush();
    return static_cast<bool>(std::cout);
}

} // namespace

int main(int argc, char ** argv) {
    std::string modelPath;
    std::string language = "auto";
    int threads = std::max(2, static_cast<int>(std::thread::hardware_concurrency()) - 2);
    int chunkSeconds = 4;

    for (int index = 1; index < argc; ++index) {
        const std::string argument(argv[index]);
        if (argument == "--help" || argument == "-h") {
            std::cout << "meeting-whisper --model <ggml-model> [--language auto] [--threads N (1-1024)] [--chunk-seconds N (4-30)]\n"
                         "Reads mono 16 kHz float32 PCM from stdin and emits JSON transcript segments on stdout.\n";
            return 0;
        }
        if (argument != "--model" && argument != "-m" && argument != "--language" &&
            argument != "--threads" && argument != "--chunk-seconds") {
            std::cerr << "Unknown argument: " << argument << '\n';
            return 2;
        }
        if (index + 1 >= argc) {
            std::cerr << "Missing value for " << argument << '\n';
            return 2;
        }
        const char * value = argv[++index];
        if (argument == "--model" || argument == "-m") modelPath = value;
        else if (argument == "--language") language = value;
        else if (argument == "--threads" && !parseInteger(value, 1, 1024, threads)) {
            std::cerr << "--threads must be an integer between 1 and 1024.\n";
            return 2;
        } else if (argument == "--chunk-seconds" && !parseInteger(value, 4, 30, chunkSeconds)) {
            std::cerr << "--chunk-seconds must be an integer between 4 and 30.\n";
            return 2;
        }
    }

    if (modelPath.empty()) {
        std::cerr << "A Whisper model path is required.\n";
        return 2;
    }
    if (language != "auto" && whisper_lang_id(language.c_str()) < 0) {
        std::cerr << "Unknown Whisper language: " << language << '\n';
        return 2;
    }

    auto contextParameters = whisper_context_default_params();
    contextParameters.use_gpu = true;
    std::unique_ptr<whisper_context, decltype(&whisper_free)> context(
        whisper_init_from_file_with_params(modelPath.c_str(), contextParameters), whisper_free);
    if (!context) {
        std::cerr << "Could not load the Whisper model.\n";
        return 3;
    }

    auto parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    parameters.n_threads = threads;
    parameters.language = language.c_str();
    // `language = "auto"` performs language detection and continues transcription.
    // `detect_language = true` is a detection-only mode in whisper.cpp and returns
    // before decoding any text.
    parameters.detect_language = false;
    parameters.no_context = true;
    parameters.token_timestamps = true;
    parameters.print_progress = false;
    parameters.print_realtime = false;
    parameters.print_timestamps = false;
    parameters.suppress_blank = true;
    parameters.temperature = 0.0f;
    parameters.no_speech_thold = 0.65f;

    std::cout << std::setprecision(17) << "{\"type\":\"ready\"}\n" << std::flush;

    constexpr int sampleRate = 16000;
    const size_t chunkSamples = static_cast<size_t>(sampleRate) * static_cast<size_t>(chunkSeconds);
    const size_t overlapSamples = static_cast<size_t>(sampleRate) * 2;
    std::vector<float> buffer(chunkSamples);
    size_t carriedBytes = 0;
    size_t completedSamples = 0;

    while (true) {
        const size_t count = std::fread(reinterpret_cast<unsigned char *>(buffer.data()) + carriedBytes,
                                       1, chunkSamples * sizeof(float) - carriedBytes, stdin);
        carriedBytes += count;
        if (carriedBytes == chunkSamples * sizeof(float)) {
            if (!std::all_of(buffer.begin(), buffer.end(), [](float sample) { return std::isfinite(sample); })) {
                std::cerr << "The live audio stream contains a non-finite PCM sample.\n";
                return 4;
            }
            const double offset = static_cast<double>(completedSamples) / sampleRate;
            if (!emitChunk(context.get(), parameters, buffer, offset, completedSamples == 0 ? 0.0 : 2.0)) {
                return 5;
            }
            completedSamples += chunkSamples - overlapSamples;
            std::copy(buffer.end() - overlapSamples, buffer.end(), buffer.begin());
            carriedBytes = overlapSamples * sizeof(float);
        }
        if (count == 0) {
            if (std::ferror(stdin)) {
                std::cerr << "Could not read the live audio stream.\n";
                return 4;
            }
            if (std::feof(stdin)) break;
        }
    }

    if (carriedBytes % sizeof(float) != 0) {
        std::cerr << "The live audio stream ends with an incomplete float32 PCM sample.\n";
        return 4;
    }
    const size_t carried = carriedBytes / sizeof(float);
    if (carried > (completedSamples == 0 ? 0 : overlapSamples)) {
        buffer.resize(carried);
        if (!std::all_of(buffer.begin(), buffer.end(), [](float sample) { return std::isfinite(sample); })) {
            std::cerr << "The live audio stream contains a non-finite PCM sample.\n";
            return 4;
        }
        if (!emitChunk(context.get(), parameters, buffer, static_cast<double>(completedSamples) / sampleRate,
                       completedSamples == 0 ? 0.0 : 2.0)) {
            return 5;
        }
    }
    context.reset();
    std::cout << "{\"type\":\"finished\"}\n" << std::flush;
    return 0;
}
