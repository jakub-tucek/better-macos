#!/usr/bin/env python3
"""Stable per-Mac signing. Only setup may modify Keychain or Git configuration."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

KEY = "bettermacos.signingIdentity"


def run(*args):
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or f"{args[0]} failed")
    return result.stdout.strip()


def config(source, scope=None):
    args = ["git", "-C", str(source), "config"]
    if scope:
        args.append(scope)
    result = subprocess.run(args + ["--get", KEY], text=True, capture_output=True)
    if result.returncode not in (0, 1):
        raise RuntimeError(result.stderr.strip())
    return result.stdout.strip()


def identities():
    return set(re.findall(r'^\s*\d+\) ([A-Fa-f0-9]{40}) "([^"]+)"\s*$',
                          run("security", "find-identity", "-v", "-p", "codesigning"), re.M))


def resolve(source, persistent=False):
    selected = os.environ.get("BETTER_MACOS_SIGNING_IDENTITY") or config(source)
    if not selected:
        raise RuntimeError("Signing is not configured. Run: bash scripts/dev signing setup")
    if selected == "-":
        if persistent:
            raise RuntimeError("This command requires a persistent certificate, not ad-hoc signing")
        return selected
    matches = {fingerprint.upper() for fingerprint, name in identities()
               if selected.upper() == fingerprint.upper() or selected == name}
    if len(matches) != 1:
        raise RuntimeError("Signing certificate is missing, expired or ambiguous; select a valid full fingerprint. No ad-hoc fallback.")
    return matches.pop()


def probe(identity):
    with tempfile.TemporaryDirectory(prefix="better-macos-signing-probe-") as directory:
        target = Path(directory) / "probe"
        shutil.copyfile("/usr/bin/true", target)
        target.chmod(0o700)
        run("codesign", "--force", "--sign", identity, str(target))
        run("codesign", "--verify", "--strict", f'-R=certificate leaf = H"{identity}"', str(target))


def create_identity():
    # No existing keys are exported. Temporary new key material is mode 0600,
    # inside a private directory, removed even when import/trust fails.
    name = "Better macOS Local " + str(uuid.uuid4())
    keychain = run("security", "default-keychain", "-d", "user").strip('"')
    with tempfile.TemporaryDirectory(prefix="better-macos-signing-") as directory:
        root = Path(directory)
        key, cert, archive = (root / value for value in ("key.pem", "cert.pem", "identity.p12"))
        settings = root / "openssl.cnf"
        settings.write_text("[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=signing\n"
                            f"[dn]\nCN={name}\n[signing]\nbasicConstraints=critical,CA:false\n"
                            "keyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\n")
        run("openssl", "req", "-new", "-newkey", "rsa:3072", "-nodes", "-x509", "-days", "3650",
            "-config", str(settings), "-keyout", str(key), "-out", str(cert))
        run("openssl", "pkcs12", "-export", "-inkey", str(key), "-in", str(cert),
            "-out", str(archive), "-passout", "pass:")
        run("security", "import", str(archive), "-k", keychain, "-P", "", "-T", "/usr/bin/codesign")
        # User-domain code-signing trust only. macOS may request confirmation.
        run("security", "add-trusted-cert", "-r", "trustRoot", "-p", "codeSign", "-k", keychain, str(cert))
        matches = {fingerprint.upper() for fingerprint, label in identities() if label == name}
        if len(matches) != 1:
            raise RuntimeError(f"Imported {name}, but it is not usable. Inspect Keychain before retrying setup.")
        return matches.pop()


def setup(source):
    selected = os.environ.get("BETTER_MACOS_SIGNING_IDENTITY") or config(source)
    if selected:
        identity = resolve(source, persistent=True)
    else:
        available = {fingerprint.upper() for fingerprint, _ in identities()}
        if len(available) > 1:
            raise RuntimeError("Several signing identities exist. Select one with BETTER_MACOS_SIGNING_IDENTITY=<fingerprint> and rerun setup.")
        identity = available.pop() if available else create_identity()
    probe(identity)
    if not config(source, "--global"):
        run("git", "-C", str(source), "config", "--global", KEY, identity)
    print(f"Signing ready: {identity}. Existing repository and global selections retained.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["setup", "status", "resolve"])
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--persistent", action="store_true")
    args = parser.parse_args()
    if args.command == "setup":
        os.umask(0o077)
        setup(args.source)
    else:
        print(resolve(args.source, args.persistent))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError) as error:
        print(f"Signing stopped: {error}", file=sys.stderr)
        sys.exit(1)
