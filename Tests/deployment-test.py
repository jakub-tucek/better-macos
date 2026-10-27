import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import tempfile
import time
import unittest

spec = importlib.util.spec_from_file_location("deployment", Path(__file__).resolve().parents[1] / "scripts/deploy.py")
deployment = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deployment)


def bundle(path, revision):
    (path / "Contents").mkdir(parents=True)
    with (path / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleIdentifier": deployment.BUNDLE_ID, "BetterMacOSRevision": revision}, stream)


def report(revision="old", session="old-session"):
    return dict(schema=1, revision=revision, session=session, pid=123, timestamp=time.time(),
                configurationHash="saved-choices", blockers=[], checks={"watchdog": "ready", "windowShortcuts": "ready", "accessibility": "ready"})


class FakeOperations:
    def __init__(self):
        self.events = []
        self.baseline = report()
        self.fail_health = False
        self.fail_verify = False
        self.refuse_quit = False
        self.refuse_rollback = False
        self.quit_count = 0
        self.offline = False
        self.fail_swap = False

    def copy(self, source, target):
        shutil.copytree(source, target)

    def replace(self, source, target):
        if self.fail_swap and source.name == "new.app":
            raise OSError("swap failed")
        source.rename(target)

    def verify(self, app):
        if self.fail_verify:
            raise RuntimeError("signature invalid")

    def status(self, app):
        return None if self.offline else dict(self.baseline, revision=deployment.metadata(app)["BetterMacOSRevision"])

    def quit(self, app):
        if self.offline:
            return None
        self.quit_count += 1
        self.events.append("quit")
        if self.refuse_quit or (self.refuse_rollback and self.quit_count > 1):
            raise RuntimeError("host veto")
        # The host's checkpoint flush changes the baseline before exiting.
        value = dict(self.baseline, configurationHash="flushed-checkpoint")
        return value

    def launch(self, app):
        self.events.append("launch:" + deployment.metadata(app)["BetterMacOSRevision"])

    def await_health(self, app, revision, baseline):
        self.events.append("health")
        if self.fail_health:
            raise RuntimeError("shortcut registration regressed")
        value = report(revision, "new-session")
        value["configurationHash"] = "flushed-checkpoint" if baseline else "saved-choices"
        failures = deployment.health_failures(value, revision, baseline)
        if failures:
            raise RuntimeError(str(failures))
        return value


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="better-macos-deployment-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "Applications/Better macOS.app"
        self.new = self.root / "build/Better macOS.app"
        bundle(self.app, "old")
        bundle(self.new, "new")
        self.ops = FakeOperations()

    def deploy(self, **args):
        return deployment.deploy(self.new, self.app, self.ops, **args)

    def revision(self):
        return deployment.metadata(self.app)["BetterMacOSRevision"]

    def test_success_keeps_previous_until_health_and_uses_flushed_baseline(self):
        transaction = self.deploy()
        self.assertEqual(self.revision(), "new")
        self.assertEqual(deployment.metadata(transaction / "previous.app")["BetterMacOSRevision"], "old")
        self.assertEqual(self.ops.events, ["quit", "launch:new", "health"])
        self.assertEqual(json.loads((transaction / "receipt.json").read_text())["state"], "healthy")

    def test_signature_failure_never_quits(self):
        self.ops.fail_verify = True
        with self.assertRaises(RuntimeError):
            self.deploy()
        self.assertEqual(self.ops.events, [])
        self.assertEqual(self.revision(), "old")

    def test_active_session_defers_without_quitting(self):
        self.ops.baseline["blockers"] = ["Keep awake session is active"]
        with self.assertRaisesRegex(RuntimeError, "Update deferred"):
            self.deploy()
        self.assertEqual(self.ops.events, [])
        self.assertEqual(self.revision(), "old")

    def test_second_host_check_can_veto_after_preflight(self):
        self.ops.refuse_quit = True
        with self.assertRaisesRegex(RuntimeError, "host veto"):
            self.deploy()
        self.assertEqual(self.revision(), "old")
        self.assertNotIn("launch:new", self.ops.events)

    def test_health_failure_rolls_back_and_relaunches_old(self):
        self.ops.fail_health = True
        with self.assertRaisesRegex(RuntimeError, "regressed"):
            self.deploy()
        self.assertEqual(self.revision(), "old")
        self.assertEqual(self.ops.events, ["quit", "launch:new", "health", "quit", "launch:old"])

    def test_failed_publication_restores_previous_bundle(self):
        self.ops.fail_swap = True
        with self.assertRaisesRegex(OSError, "swap failed"):
            self.deploy()
        self.assertEqual(self.revision(), "old")
        self.assertEqual(self.ops.events, ["quit", "launch:old"])

    def test_rollback_veto_never_replaces_running_bundle(self):
        self.ops.fail_health = True
        self.ops.refuse_rollback = True
        with self.assertRaisesRegex(RuntimeError, "Rollback needs attention"):
            self.deploy()
        self.assertEqual(self.revision(), "new")
        self.assertEqual(len(list(self.root.glob("Applications/.better-macos-deployment/transaction-*/previous.app"))), 1)

    def test_no_open_keeps_backup_without_claiming_health(self):
        transaction = self.deploy(no_open=True)
        self.assertEqual(self.ops.events, ["quit"])
        self.assertEqual(json.loads((transaction / "receipt.json").read_text())["state"], "unverified")

    def test_offline_install_launches_and_checks_health(self):
        self.ops.offline = True
        self.deploy()
        self.assertEqual(self.ops.events, ["launch:new", "health"])

    def test_only_two_successful_backups_are_kept(self):
        for _ in range(4):
            self.deploy(no_open=True)
        self.assertEqual(len(list(self.root.glob("Applications/.better-macos-deployment/transaction-*/previous.app"))), 2)

    def test_health_rejects_old_session_wrong_revision_and_changed_settings(self):
        baseline = report()
        for changed in [dict(session="old-session"), dict(revision="wrong"), dict(configurationHash="lost"), dict(timestamp=0)]:
            value = report("new", "new-session")
            value.update(changed)
            self.assertTrue(deployment.health_failures(value, "new", baseline))

    def test_health_reports_regressions_not_existing_denied_permissions(self):
        baseline = report()
        baseline["checks"]["accessibility"] = "unavailable"
        value = report("new", "new-session")
        value["checks"]["accessibility"] = "unavailable"
        self.assertEqual(deployment.health_failures(value, "new", baseline), [])
        value["checks"]["windowShortcuts"] = "unavailable"
        self.assertTrue(deployment.health_failures(value, "new", baseline))


if __name__ == "__main__":
    unittest.main()
