#!/usr/bin/env python3
"""Exercise streaming boundaries and invalid input with a deterministic engine."""
import json
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class MeetingWhisperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="meeting-whisper-tests-")
        cls.executable = pathlib.Path(cls.temporary.name) / "meeting-whisper"
        compiler = shutil.which("clang++") or shutil.which("c++")
        command = [compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror"]
        if sys.platform == "darwin":
            sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
            command += ["-isystem", f"{sdk}/usr/include/c++/v1"]
        command += ["-I", str(ROOT / "vendor/whisper.cpp/include"),
                    "-I", str(ROOT / "vendor/whisper.cpp/ggml/include"),
                    str(ROOT / "MeetingWhisper/main.cpp"),
                    str(ROOT / "tests/meeting_whisper_fixture.cpp"),
                    "-o", str(cls.executable)]
        subprocess.run(command, check=True, timeout=60)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def invoke(self, audio=b"", model="normal", extra=()):
        result = subprocess.run([str(self.executable), "--model", model, *extra],
                                input=audio, capture_output=True, timeout=5)
        records = [json.loads(line) for line in result.stdout.splitlines()]
        return result, records

    @staticmethod
    def voiced_audio(seconds):
        # A constant low-amplitude signal is sufficient for the deterministic
        # fixture and passes the production silence gate.
        return struct.pack("<f", 0.01) * (int(seconds * 16000))

    def test_crossing_segment_retains_fresh_words_and_subword_tokens(self):
        result, records = self.invoke(self.voiced_audio(6))
        self.assertEqual(result.returncode, 0, result.stderr)
        segments = [record for record in records if record["type"] == "segment"]
        self.assertEqual([segment["text"] for segment in segments], [" old words.", " freshly arrived."])
        self.assertEqual([(segment["start"], segment["end"]) for segment in segments], [(0, 4), (4, 6)])
        self.assertEqual(records[-1]["type"], "finished")

    def test_missing_token_times_preserve_crossing_speech(self):
        result, records = self.invoke(self.voiced_audio(6), model="unknown-times")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(records[-2]["text"], " old words. freshly arrived.")

    def test_segment_wholly_inside_overlap_is_not_repeated(self):
        result, records = self.invoke(self.voiced_audio(6), model="overlap-only")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(sum(record["type"] == "segment" for record in records), 1)

    def test_short_final_chunk_has_bounded_timestamps(self):
        result, records = self.invoke(self.voiced_audio(4.25))
        self.assertEqual(result.returncode, 0)
        segments = [record for record in records if record["type"] == "segment"]
        self.assertEqual(segments[-1]["end"], 4.25)
        self.assertTrue(all(0 <= segment["start"] < segment["end"] <= 4.25 for segment in segments))

    def test_empty_stream_finishes_cleanly(self):
        result, records = self.invoke()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(records, [{"type": "ready"}, {"type": "finished"}])

    def test_partial_float_is_rejected(self):
        result, records = self.invoke(b"\0\0\0")
        self.assertEqual(result.returncode, 4)
        self.assertIn(b"incomplete float32", result.stderr)
        self.assertNotIn({"type": "finished"}, records)

    def test_nonfinite_samples_are_rejected_in_full_and_final_chunks(self):
        for size in (1600, 64000):
            for value in (float("nan"), float("inf")):
                with self.subTest(size=size, value=value):
                    result, records = self.invoke(struct.pack("f", value) + b"\0" * ((size - 1) * 4))
                    self.assertEqual(result.returncode, 4)
                    self.assertIn(b"non-finite PCM", result.stderr)
                    self.assertFalse(any(record["type"] == "segment" for record in records))

    def test_invalid_arguments_are_rejected_before_model_loading(self):
        for arguments in (("--oops",), ("--threads",), ("--threads", "1abc"),
                          ("--threads", "0"), ("--threads", "999999999999999999999"),
                          ("--chunk-seconds", "3"), ("--chunk-seconds", "31"),
                          ("--chunk-seconds", "garbage"), ("--language", "invalid")):
            with self.subTest(arguments=arguments):
                result, records = self.invoke(model="fail-load", extra=arguments)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(records, [])

    def test_model_and_inference_failures_have_distinct_nonzero_status(self):
        result, records = self.invoke(model="fail-load")
        self.assertEqual(result.returncode, 3)
        self.assertEqual(records, [])
        result, records = self.invoke(self.voiced_audio(4), model="fail-inference")
        self.assertEqual(result.returncode, 5)
        self.assertEqual(records, [{"type": "ready"}])


if __name__ == "__main__":
    unittest.main()
