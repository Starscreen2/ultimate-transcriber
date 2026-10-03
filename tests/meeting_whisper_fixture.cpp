// Deterministic Whisper adapter used to test the streaming protocol without a
// downloaded model or GPU. The production executable links real whisper.cpp.
#include "whisper.h"

#include <cstring>
#include <string>

struct whisper_context {
    std::string scenario;
    int chunks = 0;
};

extern "C" {
whisper_context_params whisper_context_default_params() { return {}; }
whisper_full_params whisper_full_default_params(whisper_sampling_strategy) { return {}; }
whisper_context * whisper_init_from_file_with_params(const char * path, whisper_context_params) {
    return std::strcmp(path, "fail-load") == 0 ? nullptr : new whisper_context{path};
}
void whisper_free(whisper_context * context) { delete context; }
int whisper_lang_id(const char * language) { return std::strcmp(language, "en") == 0 ? 0 : -1; }
int whisper_full(whisper_context * context, whisper_full_params parameters, const float *, int) {
    ++context->chunks;
    if (!parameters.token_timestamps || parameters.detect_language) return 1;
    return context->scenario == "fail-inference" ? 1 : 0;
}
int whisper_full_n_segments(whisper_context *) { return 1; }
int64_t whisper_full_get_segment_t0(whisper_context *, int) { return 0; }
int64_t whisper_full_get_segment_t1(whisper_context * context, int) {
    return context->scenario == "overlap-only" && context->chunks > 1 ? 150 : 900;
}
const char * whisper_full_get_segment_text(whisper_context * context, int) {
    return context->chunks == 1 ? " old words." : " old words. freshly arrived.";
}
int whisper_full_n_tokens(whisper_context * context, int) { return context->chunks == 1 ? 2 : 6; }
whisper_token whisper_token_eot(whisper_context *) { return 1000; }
whisper_token_data whisper_full_get_token_data(whisper_context * context, int, int tokenIndex) {
    whisper_token_data result{};
    const int64_t starts[] = {0, 100, 195, 198, 225, 300};
    const int64_t ends[] = {100, 190, 198, 225, 300, 400};
    result.id = tokenIndex == 5 ? 1000 : tokenIndex;
    result.t0 = starts[tokenIndex];
    result.t1 = ends[tokenIndex];
    if (context->scenario == "unknown-times") result.t0 = result.t1 = -1;
    return result;
}
const char * whisper_full_get_token_text(whisper_context *, int, int tokenIndex) {
    const char * values[] = {" old", " words.", " fresh", "ly", " arrived.", "<eot>"};
    return values[tokenIndex];
}
}
