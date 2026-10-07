#!/usr/bin/env python3
"""Sign local builds with one persistent, certificate-bound identity.

Uses a dedicated keychain, never changes system trust or the login keychain.
An explicit SIGNING_IDENTITY uses the developer's existing identity instead.
"""
import contextlib
import fcntl
import hashlib
import os
from pathlib import Path
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile

SECURITY = "/usr/bin/security"
CODESIGN = "/usr/bin/codesign"
BUNDLE_ID = "local.transcribetotext.app"


def run(args, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, **kwargs)
    if result.returncode:
        # Never print command arguments: security receives keychain passwords.
        raise RuntimeError(f"{Path(args[0]).name} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


@contextlib.contextmanager
def local_identity():
    folder = Path.home() / "Library/Application Support/TranscribeToText/Signing"
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    folder.chmod(0o700)
    with (folder / "identity.lock").open("a") as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        keychain = folder / "local-signing.keychain-db"
        password_file = folder / "keychain-password"
        certificate = folder / "certificate.der"
        paths = [keychain, password_file, certificate]
        if not any(path.exists() for path in paths):
            # Initialize in a private staging directory; publish only a complete
            # identity. Restore the keychain search list after create-keychain.
            with tempfile.TemporaryDirectory(prefix=".identity-", dir=folder) as temp:
                staging = Path(temp)
                password = secrets.token_hex(32)
                (staging / "keychain-password").write_text(password)
                (staging / "keychain-password").chmod(0o600)
                config = staging / "certificate.cnf"
                config.write_text("""[req]
prompt = no
distinguished_name = dn
x509_extensions = signing
[dn]
CN = TranscribeToText Local Development
[signing]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
""")
                openssl = shutil.which("openssl") or "/usr/bin/openssl"
                run([openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "7300",
                     "-config", str(config), "-keyout", str(staging / "key.pem"), "-out", str(staging / "cert.pem")])
                run([openssl, "x509", "-in", str(staging / "cert.pem"), "-outform", "DER", "-out", str(staging / "certificate.der")])
                run([openssl, "pkcs12", "-export", "-in", str(staging / "cert.pem"), "-inkey", str(staging / "key.pem"),
                     "-name", "TranscribeToText Local Development", "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES",
                     "-macalg", "sha1", "-passout", "file:" + str(staging / "keychain-password"), "-out", str(staging / "identity.p12")])
                staged_keychain = staging / keychain.name
                # security emits quoted paths, including paths with spaces.
                try:
                    run([SECURITY, "create-keychain", "-p", password, str(staged_keychain)])
                    run([SECURITY, "unlock-keychain", "-p", password, str(staged_keychain)])
                    run([SECURITY, "import", str(staging / "identity.p12"), "-k", str(staged_keychain),
                         "-P", password, "-x", "-T", CODESIGN])
                    # Restrict non-interactive signing access to codesign in this
                    # dedicated keychain; never change ACLs of existing keys.
                    run([SECURITY, "set-key-partition-list", "-S", "codesign:", "-s", "-k", password, str(staged_keychain)])
                finally:
                    current_search = shlex.split(run([SECURITY, "list-keychains", "-d", "user"]))
                    run([SECURITY, "list-keychains", "-d", "user", "-s", *[p for p in current_search if p != str(staged_keychain)]])
                for path in paths:
                    shutil.move(str(staging / path.name), str(path))
                    path.chmod(0o600)
        elif not all(path.is_file() for path in paths):
            raise RuntimeError("The local signing identity is incomplete. Restore its Signing folder; it will not be silently replaced.")
        password = password_file.read_text().strip()
        fingerprint = hashlib.sha1(certificate.read_bytes()).hexdigest().upper()
        original_search = shlex.split(run([SECURITY, "list-keychains", "-d", "user"]))
        added_to_search = str(keychain) not in original_search
        run([SECURITY, "unlock-keychain", "-p", password, str(keychain)])
        try:
            # codesign's private-key lookup also needs the keychain in the search
            # list, even when --keychain narrows the certificate lookup.
            if added_to_search:
                run([SECURITY, "list-keychains", "-d", "user", "-s", *original_search, str(keychain)])
            yield fingerprint, keychain
        finally:
            try:
                run([SECURITY, "lock-keychain", str(keychain)])
            finally:
                if added_to_search:
                    current_search = shlex.split(run([SECURITY, "list-keychains", "-d", "user"]))
                    run([SECURITY, "list-keychains", "-d", "user", "-s", *[p for p in current_search if p != str(keychain)]])


def sign(app, identity, keychain=None):
    args = [CODESIGN, "--force", "--sign", identity, "--timestamp=none"]
    if keychain:
        args += ["--keychain", str(keychain)]
    for name in ["whisper-cli", "meeting-whisper", "llama-cli", "sherpa-onnx-offline-speaker-diarization"]:
        helper = app / "Contents/Resources" / name
        if helper.is_file():
            run([*args, "--identifier", BUNDLE_ID + "." + name, str(helper)])
    if keychain:
        requirement = f'designated => identifier "{BUNDLE_ID}" and certificate leaf = H"{identity}"'
        run([*args, "--requirements", "=" + requirement, str(app)])
    else:
        run([*args, str(app)])
    run([CODESIGN, "--verify", "--deep", "--strict", str(app)])


def main():
    if len(sys.argv) != 2:
        raise RuntimeError("Usage: sign-app.py /path/to/TranscribeToText.app")
    app = Path(sys.argv[1]).resolve()
    if not (app / "Contents/Info.plist").is_file():
        raise RuntimeError("Expected an app bundle with Info.plist.")
    identity = os.environ.get("SIGNING_IDENTITY")
    if identity:
        if identity == "-":
            raise RuntimeError("Ad-hoc signing cannot preserve recording approvals across rebuilds. Use a certificate identity.")
        sign(app, identity)
    else:
        with local_identity() as (identity, keychain):
            sign(app, identity, keychain)
    print("Verified certificate-signed app with a stable recording-permission identity.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError) as error:
        print(f"App signing failed: {error}", file=sys.stderr)
        sys.exit(1)
