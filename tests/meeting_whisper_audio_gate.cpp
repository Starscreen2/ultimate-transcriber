#include "../MeetingWhisper/audio_gate.h"

#include <cmath>
#include <cstdio>
#include <vector>

int main() {
    constexpr size_t frame = 320;
    std::vector<float> silence(frame * 4, 0.0f);
    if (meeting_whisper::hasSpeechLevelEnergy(silence.data(), silence.size())) {
        std::fprintf(stderr, "digital silence was treated as speech\n");
        return 1;
    }

    std::vector<float> floorNoise(frame * 4, 0.00001f);
    if (meeting_whisper::hasSpeechLevelEnergy(floorNoise.data(), floorNoise.size())) {
        std::fprintf(stderr, "low-level noise was treated as speech\n");
        return 1;
    }

    std::vector<float> impulse(frame * 4, 0.0f);
    impulse[100] = 0.5f;
    if (meeting_whisper::hasSpeechLevelEnergy(impulse.data(), impulse.size())) {
        std::fprintf(stderr, "a single click was treated as speech\n");
        return 1;
    }

    std::vector<float> quietSpeech(frame * 4, 0.0f);
    for (size_t i = frame; i < frame * 3; ++i) {
        quietSpeech[i] = static_cast<float>(std::sin(static_cast<double>(i) * 0.1) * 0.0002);
    }
    if (!meeting_whisper::hasSpeechLevelEnergy(quietSpeech.data(), quietSpeech.size())) {
        std::fprintf(stderr, "quiet speech-level audio was discarded\n");
        return 1;
    }

    std::puts("Live audio gate regressions passed (silence, noise floor, clicks, quiet speech).");
    return 0;
}
