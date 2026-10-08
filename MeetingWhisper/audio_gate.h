#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>

namespace meeting_whisper {

// Ignore chunks that contain only the very low-level noise floor. Requiring
// two active 20 ms windows avoids treating a single click as speech while
// keeping short spoken words.
inline bool hasSpeechLevelEnergy(const float * samples, const size_t count) {
    constexpr size_t frameSamples = 320; // 20 ms at 16 kHz
    constexpr double minimumRMS = 1.0e-4; // -80 dBFS
    size_t consecutiveActiveFrames = 0;

    for (size_t start = 0; start < count; start += frameSamples) {
        const size_t length = std::min(frameSamples, count - start);
        if (length < frameSamples / 2) break;

        double sumSquares = 0.0;
        for (size_t index = start; index < start + length; ++index) {
            const double sample = samples[index];
            sumSquares += sample * sample;
        }
        const double rms = std::sqrt(sumSquares / static_cast<double>(length));
        if (rms >= minimumRMS) {
            if (++consecutiveActiveFrames >= 2) return true;
        } else {
            consecutiveActiveFrames = 0;
        }
    }
    return false;
}

} // namespace meeting_whisper
