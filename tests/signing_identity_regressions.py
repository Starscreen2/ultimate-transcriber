#!/usr/bin/env python3
"""Verify changed builds retain one cryptographic identity; reject an impostor."""
import importlib.util
import pathlib
import plistlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("sign_app", ROOT / "scripts/sign-app.py")
signer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signer)


def signature(app, field):
    result = subprocess.run([signer.CODESIGN, "--display", "--verbose=4", "-r-", str(app)], capture_output=True, text=True, check=True)
    return next(line for line in (result.stdout + result.stderr).splitlines() if line.startswith(field))


with tempfile.TemporaryDirectory(prefix="signing-identity-tests-") as directory:
    root = pathlib.Path(directory)
    apps = []
    for revision in [1, 2, 3]:
        app = root / f"Version{revision}.app"
        executable = app / "Contents/MacOS/Probe"
        executable.parent.mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": signer.BUNDLE_ID, "CFBundleExecutable": "Probe", "CFBundlePackageType": "APPL"
        }))
        source = root / f"Probe{revision}.swift"
        source.write_text(f'print("Build {revision}")\n')
        subprocess.run(["swiftc", str(source), "-o", str(executable)], check=True)
        apps.append(app)
    for app in apps[:2]:
        subprocess.run(["python3", str(ROOT / "scripts/sign-app.py"), str(app)], check=True)
    old_requirement = signature(apps[0], "designated =>").split("=>", 1)[1].strip()
    new_requirement = signature(apps[1], "designated =>").split("=>", 1)[1].strip()
    assert old_requirement == new_requirement, "Rebuild changed the app identity used for recording permissions"
    assert "certificate leaf" in old_requirement and "cdhash" not in old_requirement, "Identity is not pinned to a certificate"
    assert signature(apps[0], "CDHash=") != signature(apps[1], "CDHash="), "Fixture did not change the executable"
    signer.run([signer.CODESIGN, "--verify", "--strict", "-R", "=" + old_requirement, str(apps[1])])
    signer.run([signer.CODESIGN, "--force", "--sign", "-", "--identifier", signer.BUNDLE_ID, str(apps[2])])
    impostor = subprocess.run([signer.CODESIGN, "--verify", "-R", "=" + old_requirement, str(apps[2])], capture_output=True)
    assert impostor.returncode != 0, "An unsigned lookalike satisfied the saved app identity"
print("Signing identity regressions passed (different binaries, same certificate identity, original requirement accepts update and rejects lookalike).")
