"""Isolated signing policy checks. Never touches the real Keychain or Git config."""
import importlib.util
from contextlib import ExitStack
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("signing", Path(__file__).resolve().parents[1] / "scripts/signing.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
A, B = "A" * 40, "B" * 40
create_identity = signing.create_identity


class SigningTests(unittest.TestCase):
    def enterContext(self, context):
        return self.contexts.enter_context(context)

    def setUp(self):
        self.contexts = ExitStack()
        self.addCleanup(self.contexts.close)
        temp = tempfile.TemporaryDirectory(prefix="better-macos-signing-test-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.enterContext(patch.dict(os.environ, {
            "GIT_CONFIG_GLOBAL": str(self.root / "global"), "GIT_CONFIG_NOSYSTEM": "1",
            "BETTER_MACOS_SIGNING_IDENTITY": "",
        }))
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.available = self.enterContext(patch.object(signing, "identities", return_value={(A, "Local")}))
        self.probe = self.enterContext(patch.object(signing, "probe"))
        self.create = self.enterContext(patch.object(signing, "create_identity", return_value=B))

    def configure(self, scope, value):
        signing.run("git", "-C", str(self.root), "config", scope, signing.KEY, value)

    def test_global_reuse_and_repository_and_environment_precedence(self):
        self.configure("--global", A)
        self.assertEqual(signing.resolve(self.root), A)
        self.available.return_value.add((B, "Other"))
        self.configure("--local", B)
        self.assertEqual(signing.resolve(self.root), B)
        with patch.dict(os.environ, BETTER_MACOS_SIGNING_IDENTITY=A):
            self.assertEqual(signing.resolve(self.root), A)

    def test_missing_configuration_never_defaults_to_adhoc(self):
        with self.assertRaisesRegex(RuntimeError, "not configured"):
            signing.resolve(self.root)

    def test_missing_or_expired_configured_identity_never_creates_replacement(self):
        self.configure("--local", B)
        with self.assertRaisesRegex(RuntimeError, "expired"):
            signing.setup(self.root)
        self.create.assert_not_called()

    def test_ambiguous_name_requires_fingerprint(self):
        self.available.return_value.add((B, "Local"))
        self.configure("--local", "Local")
        with self.assertRaisesRegex(RuntimeError, "ambiguous"):
            signing.resolve(self.root)

    def test_setup_reuses_and_is_idempotent(self):
        self.configure("--local", A)
        signing.setup(self.root)
        signing.setup(self.root)
        self.assertEqual(signing.config(self.root, "--global"), A)
        self.create.assert_not_called()
        self.probe.assert_called_with(A)

    def test_unconfigured_unique_identity_is_reused(self):
        signing.setup(self.root)
        self.assertEqual(signing.config(self.root, "--global"), A)
        self.create.assert_not_called()

    def test_unconfigured_multiple_identities_require_selection(self):
        self.available.return_value.add((B, "Other"))
        with self.assertRaisesRegex(RuntimeError, "Several"):
            signing.setup(self.root)
        self.create.assert_not_called()

    def test_creation_and_probe_must_succeed_before_configuration(self):
        self.available.return_value = set()
        self.create.side_effect = RuntimeError("import failed")
        with self.assertRaisesRegex(RuntimeError, "import failed"):
            signing.setup(self.root)
        self.assertEqual(signing.config(self.root), "")
        self.create.side_effect = None
        self.probe.side_effect = RuntimeError("key locked")
        with self.assertRaisesRegex(RuntimeError, "key locked"):
            signing.setup(self.root)
        self.assertEqual(signing.config(self.root), "")
        self.probe.side_effect = None
        signing.setup(self.root)
        self.assertEqual(signing.config(self.root), B)

    def test_failed_import_cleans_temporary_key_material(self):
        paths = []

        def command(*args):
            if args[:2] == ("security", "default-keychain"):
                return '"/isolated/login.keychain-db"'
            if args[:2] == ("openssl", "req"):
                key = Path(args[args.index("-keyout") + 1])
                key.write_text("fixture private key")
                paths.append(key)
                self.assertEqual(key.parent.stat().st_mode & 0o777, 0o700)
            if args[:2] == ("security", "import"):
                raise RuntimeError("import denied")
            return ""

        with patch.object(signing, "run", side_effect=command):
            with self.assertRaisesRegex(RuntimeError, "import denied"):
                create_identity()
        self.assertTrue(paths)
        self.assertFalse(paths[0].parent.exists())

    def test_existing_global_selection_is_preserved(self):
        self.configure("--global", B)
        self.configure("--local", A)
        signing.setup(self.root)
        self.assertEqual(signing.config(self.root, "--global"), B)

    def test_adhoc_requires_explicit_selection_and_cannot_be_setup_or_deployed(self):
        with patch.dict(os.environ, BETTER_MACOS_SIGNING_IDENTITY="-"):
            self.assertEqual(signing.resolve(self.root), "-")
            with self.assertRaisesRegex(RuntimeError, "persistent"):
                signing.resolve(self.root, persistent=True)
            with self.assertRaisesRegex(RuntimeError, "persistent"):
                signing.setup(self.root)


if __name__ == "__main__":
    unittest.main()
