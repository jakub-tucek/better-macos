#!/usr/bin/env python3
"""One guarded bundle replacement path for local development and source installs."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time
import uuid

BUNDLE_ID = "io.github.jakub-tucek.better-macos"


def run(*args, env=None, timeout=60):
    result = subprocess.run(args, env=env, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=timeout)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f"{args[0]} failed")
    return result.stdout.strip()


def metadata(app):
    with (app / "Contents/Info.plist").open("rb") as stream:
        value = plistlib.load(stream)
    if value.get("CFBundleIdentifier") != BUNDLE_ID:
        raise RuntimeError(f"Not a Better macOS bundle: {app}")
    return value


def health_failures(report, revision, baseline=None):
    if not report or report.get("schema") != 1:
        return ["No live health response"]
    failures = []
    if report.get("revision") != revision:
        failures.append("Running revision differs from the installed revision")
    if abs(time.time() - report.get("timestamp", 0)) > 15:
        failures.append("Health response is stale")
    checks = report.get("checks", {})
    if checks.get("watchdog") != "ready":
        failures.append("Recovery watchdog is not ready")
    if baseline:
        if report.get("session") == baseline.get("session"):
            failures.append("Old GUI session is still running")
        if report.get("configurationHash") != baseline.get("configurationHash"):
            failures.append("Saved configuration changed across restart")
        for key, value in baseline.get("checks", {}).items():
            if value == "ready" and checks.get(key) != "ready":
                failures.append(f"Readiness regressed: {key}")
    return failures


def prune_backups(store, destination, keep=2):
    """Bound successful backups; failed transactions remain for recovery."""
    candidates = []
    for path in store.glob("transaction-*/receipt.json"):
        try:
            receipt = json.loads(path.read_text())
            previous = path.parent / "previous.app"
            if (receipt.get("destination") == str(destination) and receipt.get("state") in ("healthy", "unverified")
                    and previous.is_dir() and not previous.is_symlink()):
                metadata(previous)
                candidates.append((path.stat().st_mtime_ns, previous))
        except (OSError, ValueError, RuntimeError):
            continue
    for _, previous in sorted(candidates, reverse=True)[keep:]:
        shutil.rmtree(previous)


class NativeOperations:
    def __init__(self, helper, identity=None):
        self.helper = helper
        self.identity = identity

    def verify(self, app):
        metadata(app)
        run("codesign", "--verify", "--strict", str(app))
        if self.identity and self.identity != "-":
            run("codesign", "--verify", "--strict", f'-R=certificate leaf = H"{self.identity}"', str(app))

    def copy(self, source, target):
        run("ditto", str(source), str(target))

    def replace(self, source, target):
        source.rename(target)

    def status(self, app):
        return json.loads(run(str(self.helper), "--deployment-status", str(app), timeout=15))

    def quit(self, app):
        return json.loads(run(str(self.helper), "--deployment-quit", str(app), timeout=55))

    def legacy_quit(self, app):
        # One-time migration from versions without the live endpoint. Never force quit.
        run("osascript", "-e", 'with timeout of 30 seconds\n'
            f'if application id "{BUNDLE_ID}" is running then\n'
            f'tell application id "{BUNDLE_ID}" to quit\nend if\nend timeout', timeout=40)
        deadline = time.monotonic() + 30
        while subprocess.run(["pgrep", "-x", "better-macos"], stdout=subprocess.DEVNULL).returncode == 0:
            if time.monotonic() >= deadline:
                raise RuntimeError("Legacy GUI did not finish quitting; installed bundle left intact")
            time.sleep(0.5)
        return None

    def launch(self, app):
        run("open", str(app))

    def await_health(self, app, revision, baseline):
        deadline = time.monotonic() + 60
        failures = ["No GUI response"]
        while time.monotonic() < deadline:
            try:
                report = self.status(app)
                failures = health_failures(report, revision, baseline)
                if not failures:
                    return report
            except (RuntimeError, subprocess.TimeoutExpired, ValueError) as error:
                failures = [str(error)]
            time.sleep(1)
        raise RuntimeError("Post-launch health failed: " + "; ".join(failures))


def deploy(bundle, destination, operations, *, no_open=False, legacy_bootstrap=False):
    """Old bundle survives until health succeeds; rollback always uses normal host quit."""
    info = metadata(bundle)
    operations.verify(bundle)
    if destination.exists():
        metadata(destination)
    store = destination.parent / ".better-macos-deployment"
    store.mkdir(mode=0o700, exist_ok=True)
    if store.is_symlink():
        raise RuntimeError("Deployment storage must not be a symlink")
    transaction = store / ("transaction-" + uuid.uuid4().hex)
    transaction.mkdir(mode=0o700)
    staged, previous = transaction / "new.app", transaction / "previous.app"
    receipt = {"destination": str(destination), "revision": info.get("BetterMacOSRevision"), "state": "staging"}

    def record(state, **extra):
        receipt.update(state=state, **extra)
        (transaction / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")

    published = False
    try:
        operations.copy(bundle, staged)
        operations.verify(staged)
        try:
            baseline = operations.status(destination)
        except RuntimeError:
            if not legacy_bootstrap or not destination.exists() or metadata(destination).get("BetterMacOSDeploymentProtocol") == 1:
                raise
            baseline = None
            print("Legacy bootstrap: no pre-update health baseline; using normal quit.")
            operations.legacy_quit(destination)
        if baseline:
            if not destination.exists() or baseline.get("revision") != metadata(destination).get("BetterMacOSRevision"):
                raise RuntimeError("Running GUI does not match the on-disk installation; resolve that mismatch before updating")
            if baseline.get("blockers"):
                raise RuntimeError("Update deferred:\n" + "\n".join(baseline["blockers"]))
        # Recheck even if initially offline: a GUI may have launched during staging.
        # Fresh host authorization, checkpoint flush and ordinary quit. It can veto.
        flushed = operations.quit(destination)
        if flushed is not None:
            baseline = flushed
        record("prepared", baseline=baseline)
        if destination.exists():
            operations.replace(destination, previous)
        try:
            operations.replace(staged, destination)
        except BaseException:
            if previous.exists():
                operations.replace(previous, destination)
                if baseline and not no_open:
                    operations.launch(destination)
            raise
        published = True
        record("published")
        if no_open:
            record("unverified")
            print(f"Installed without launch; health unverified. Rollback retained: {previous}")
        else:
            operations.launch(destination)
            report = operations.await_health(destination, receipt["revision"], baseline)
            record("healthy", health=report)
            warnings = [key for key, value in report.get("checks", {}).items() if value == "unavailable"]
            print(f"Installed and healthy: {receipt['revision'][:7]}")
            if warnings:
                print("Existing/unqualified conditions: " + ", ".join(warnings))
            if previous.exists():
                print(f"Rollback retained: {previous}")
        try:
            prune_backups(store, destination)
        except OSError as error:
            print(f"Older backup cleanup deferred: {error}", file=sys.stderr)
        return transaction
    except BaseException as error:
        if published and previous.exists():
            try:
                operations.quit(destination)  # Never replace a live or vetoing GUI.
                operations.replace(destination, transaction / "failed.app")
                operations.replace(previous, destination)
                operations.launch(destination)
                record("rolled-back", error=str(error))
            except BaseException as rollback_error:
                record("rollback-pending", error=str(error), rollbackError=str(rollback_error))
                raise RuntimeError(f"{error}\nRollback needs attention: {rollback_error}\nBundles retained in {transaction}") from error
        else:
            record("failed-before-publication", error=str(error))
            if staged.exists():
                shutil.rmtree(staged)
        raise


def signing_identity(source):
    identity = os.environ.get("BETTER_MACOS_SIGNING_IDENTITY")
    if not identity:
        identity = run("git", "-C", str(source), "config", "--local", "--get", "bettermacos.signingIdentity")
    if not identity or identity == "-":
        raise RuntimeError("Local deploy requires a persistent signing identity; configure bettermacos.signingIdentity")
    import re
    matches = [fingerprint for fingerprint, name in re.findall(r'([A-Fa-f0-9]{40}) "([^"]+)"', run("security", "find-identity", "-v", "-p", "codesigning"))
               if identity.upper() == fingerprint.upper() or identity == name]
    if len(matches) != 1:
        raise RuntimeError("Signing identity is missing or ambiguous; use its full fingerprint")
    return matches[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--destination", type=Path, default=Path.home() / "Applications/Better macOS.app")
    parser.add_argument("--identity")
    parser.add_argument("--no-open", action="store_true")
    parser.add_argument("--legacy-bootstrap", action="store_true", help="one-time normal quit for a pre-health-endpoint installation")
    parser.add_argument("--update", action="store_true", help="fast-forward a clean main checkout before building")
    parser.add_argument("--revision", help="exact offered revision, required with --update")
    parser.add_argument("--rollback", action="store_true", help="install the most recently retained previous bundle")
    parser.add_argument("--status", action="store_true", help="read fresh health from the installed GUI without building or restarting")
    args = parser.parse_args()
    destination = args.destination.expanduser().absolute()
    if args.status:
        operations = NativeOperations(destination / "Contents/MacOS/better-macos")
        print(json.dumps(operations.status(destination), indent=2))
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    lock = destination.parent / ".better-macos-deploy.lock"
    try:
        lock.mkdir()
    except FileExistsError as error:
        raise RuntimeError(f"Another deployment holds {lock}; inspect it before retrying") from error
    try:
        source = (args.source or Path(__file__).resolve().parent.parent).resolve()
        bundle = args.bundle.resolve() if args.bundle else None
        identity = args.identity
        if args.rollback:
            identity = signing_identity(source)
            candidates = []
            for receipt_path in (destination.parent / ".better-macos-deployment").glob("transaction-*/receipt.json"):
                receipt = json.loads(receipt_path.read_text())
                previous = receipt_path.parent / "previous.app"
                if receipt.get("destination") == str(destination) and previous.is_dir():
                    candidates.append(previous)
            if not candidates:
                raise RuntimeError("No retained rollback bundle")
            bundle = max(candidates, key=lambda path: path.parent.stat().st_mtime)
        if not bundle:
            if run("git", "-C", str(source), "status", "--porcelain"):
                raise RuntimeError("Commit local changes before deployment; use 'dev preview' while iterating")
            identity = signing_identity(source)
            if args.update:
                import re
                if not args.revision or not re.fullmatch("[0-9a-f]{40}", args.revision):
                    raise RuntimeError("Update requires the exact offered --revision")
                if run("git", "-C", str(source), "branch", "--show-current") != "main":
                    raise RuntimeError("Updates require the main branch")
                run("git", "-C", str(source), "fetch", "origin", "main", timeout=120)
                run("git", "-C", str(source), "merge-base", "--is-ancestor", args.revision, "origin/main")
                run("git", "-C", str(source), "merge-base", "--is-ancestor", "HEAD", args.revision)
                run("git", "-C", str(source), "merge", "--ff-only", args.revision)
            env = dict(os.environ, BETTER_MACOS_SIGNING_IDENTITY=identity, BETTER_MACOS_SOURCE_INSTALL="1",
                       BETTER_MACOS_LOCAL_DEVELOPMENT="1", BETTER_MACOS_INSTALL_DESTINATION=str(destination))
            print("Building committed source; the installed app remains running.", flush=True)
            print(run("bash", str(source / "build.sh"), env=env, timeout=600))
            bundle = source / "build/Better macOS.app"
        if not args.rollback:
            info = metadata(bundle)
            if (info.get("BetterMacOSSourceInstall") is not True
                    or Path(info.get("BetterMacOSInstallDestination", "")).absolute() != destination
                    or not info.get("BetterMacOSSourceDirectory")):
                raise RuntimeError("Bundle lacks matching source-install metadata; build it through 'dev deploy'")
        # A retained old bundle may predate the endpoint; use the current executable for IPC.
        helper_bundle = destination if args.rollback else bundle
        operations = NativeOperations(helper_bundle / "Contents/MacOS/better-macos", identity)
        if not args.bundle and not args.legacy_bootstrap and destination.exists():
            operations.verify(destination)
        if args.rollback:
            # Keep the client outside the bundle being moved during rollback.
            import tempfile
            with tempfile.TemporaryDirectory(prefix="better-macos-deploy-client-") as temp:
                helper = Path(temp) / "better-macos"
                shutil.copy2(operations.helper, helper)
                operations.helper = helper
                deploy(bundle, destination, operations, no_open=args.no_open)
        else:
            deploy(bundle, destination, operations, no_open=args.no_open, legacy_bootstrap=args.legacy_bootstrap)
    finally:
        lock.rmdir()


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.TimeoutExpired, ValueError) as error:
        print(f"Deployment stopped: {error}", file=sys.stderr)
        sys.exit(1)
