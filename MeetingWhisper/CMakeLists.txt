cmake_minimum_required(VERSION 3.16)
project(TranscribeToTextMeetingWhisper LANGUAGES C CXX)

if(NOT DEFINED WHISPER_CPP_PATH OR NOT EXISTS "${WHISPER_CPP_PATH}/CMakeLists.txt")
    message(FATAL_ERROR "WHISPER_CPP_PATH must point to a whisper.cpp checkout")
endif()

set(GGML_METAL ON CACHE BOOL "Enable Metal acceleration" FORCE)
set(GGML_METAL_EMBED_LIBRARY ON CACHE BOOL "Embed Metal shaders in the bundled tools" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "Link backends into the bundled tools" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build static libraries" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "Disable whisper.cpp tests" FORCE)
set(WHISPER_BUILD_EXAMPLES ON CACHE BOOL "Build whisper.cpp command line tools" FORCE)

add_subdirectory("${WHISPER_CPP_PATH}" whisper.cpp)

add_executable(meeting-whisper main.cpp)
target_link_libraries(meeting-whisper PRIVATE whisper)
target_compile_features(meeting-whisper PRIVATE cxx_std_17)
set_target_properties(meeting-whisper PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
