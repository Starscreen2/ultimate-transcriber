#!/usr/bin/env python3
"""Verify bundle replacement in an isolated fixture without compiling engines."""
import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
PACKAGING_SCRIPT = (ROOT / "build-app.sh").read_text().split('STAGING_ROOT="', 1)[1]
PACKAGING_SCRIPT = 'STAGING_ROOT="' + PACKAGING_SCRIPT
MOCK_TOOL = r'''#!/usr/bin/env python3
import os
import pathlib
import subprocess
import sys
tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
if tool == "swiftc":
    if os.environ.get("FAIL_SWIFT") == "1":
        sys.exit(1)
    pathlib.Path(args[args.index("-o") + 1]).write_text("compiled app")
elif tool == "otool":
    print(args[-1] + ":")
    library = "/tmp/unbundled.dylib" if os.environ.get("UNBUNDLED") == "1" else "/usr/lib/libSystem.B.dylib"
    print("\t" + library + " (compatibility version 1.0.0, current version 1.0.0)")
elif tool == "sips":
    pathlib.Path(args[args.index("--out") + 1]).write_text("resized icon")
elif tool == "iconutil":
    pathlib.Path(args[args.index("-o") + 1]).write_text("icns")
elif tool == "mv":
    if os.environ.get("FAIL_REPLACEMENT") == "1" and "/.TranscribeToText-build." in args[0] and args[0].endswith("/TranscribeToText.app"):
        sys.exit(1)
    sys.exit(subprocess.call(["/bin/mv", *args]))
elif tool != "lipo":
    sys.exit(1)
'''


class BuildPackagingTests(unittest.TestCase):
    def run_packaging(self, **overrides):
        temporary = tempfile.TemporaryDirectory(prefix="build-packaging-tests-")
        self.addCleanup(temporary.cleanup)
        fixture = pathlib.Path(temporary.name)
        app = fixture / "build/TranscribeToText.app"
        app.mkdir(parents=True)
        (app / "sentinel").write_text("existing working app")
        for file in ("build/meeting-whisper/bin/whisper-cli",
                     "build/meeting-whisper/bin/meeting-whisper",
                     "vendor/llama.cpp/build/bin/llama-cli",
                     "vendor/sherpa-onnx/build/bin/sherpa-onnx-offline-speaker-diarization",
                     "vendor/llama.cpp/LICENSE", "ThirdPartyLicenses/example.txt", "Assets/AppIcon.png"):
            path = fixture / file
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture")
        mock_bin = fixture / "mock-bin"
        mock_bin.mkdir()
        for tool in ("swiftc", "lipo", "otool", "sips", "iconutil", "mv"):
            path = mock_bin / tool
            path.write_text(MOCK_TOOL)
            path.chmod(0o755)
        environment = os.environ.copy()
        environment.update({"FIXTURE_ROOT": str(fixture),
                            "PATH": str(mock_bin) + os.pathsep + environment["PATH"], **overrides})
        prelude = '''set -euo pipefail
ROOT="$FIXTURE_ROOT"
APP_DESTINATION="$ROOT/build/TranscribeToText.app"
LLAMA="$ROOT/vendor/llama.cpp"
SHERPA="$ROOT/vendor/sherpa-onnx"
'''
        result = subprocess.run(["/bin/bash", "-c", prelude + PACKAGING_SCRIPT],
                                env=environment, capture_output=True, text=True, timeout=15)
        return result, fixture, app

    def assert_old_bundle_preserved(self, fixture, app):
        self.assertEqual((app / "sentinel").read_text(), "existing working app")
        self.assertEqual(list((fixture / "build").glob(".TranscribeToText-build.*")), [])

    def test_compile_failure_preserves_previous_bundle(self):
        result, fixture, app = self.run_packaging(FAIL_SWIFT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assert_old_bundle_preserved(fixture, app)

    def test_unbundled_library_preserves_previous_bundle(self):
        result, fixture, app = self.run_packaging(UNBUNDLED="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("libraries outside the app", result.stderr)
        self.assert_old_bundle_preserved(fixture, app)

    def test_failed_replacement_restores_previous_bundle(self):
        result, fixture, app = self.run_packaging(FAIL_REPLACEMENT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assert_old_bundle_preserved(fixture, app)

    def test_success_replaces_bundle_and_cleans_staging(self):
        result, fixture, app = self.run_packaging()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((app / "sentinel").exists())
        self.assertTrue((app / "Contents/MacOS/TranscribeToText").is_file())
        self.assertTrue((app / "Contents/Resources/meeting-whisper").is_file())
        self.assertTrue((app / "Contents/Info.plist").is_file())
        self.assertEqual(list((fixture / "build").glob(".TranscribeToText-build.*")), [])


if __name__ == "__main__":
    unittest.main()
