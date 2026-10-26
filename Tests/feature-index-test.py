#!/usr/bin/env python3
"""Offline generator tests: independent feature additions need no shared list edit."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("feature_index", Path(__file__).resolve().parents[1] / "scripts/generate-feature-index.py")
index = importlib.util.module_from_spec(spec)
spec.loader.exec_module(index)


class FeatureIndexTests(unittest.TestCase):
    def test_parallel_additions_and_removal(self):
        with tempfile.TemporaryDirectory(prefix="feature-index-") as temporary:
            root = Path(temporary)
            def add(path):
                target = root / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("// fixture\n")
                return target
            add("Sources/App/main.swift")
            add("Sources/Features/Clipboard/Policy/ClipboardHistory.swift")
            add("Tests/ClipboardPolicyTests/ClipboardPolicyTests.swift")
            add("Tests/DiagnosticsRegressions/main.swift")
            add("Sources/Features/Alpha/AlphaFeatureRegistration.swift")
            add("Tests/Features/Alpha/AlphaFeatureTests.swift")
            output = root / "build/generated"
            index.generate(root, output)
            self.assertIn("AlphaFeatureRegistration.self", (output / "BuiltinFeatureIndex.swift").read_text())
            beta = add("Sources/Features/Beta/BetaFeatureRegistration.swift")
            add("Sources/Features/Beta/File with spaces.swift")
            add("Tests/Features/Beta/BetaFeatureTests.swift")
            index.generate(root, output)
            registrations = (output / "BuiltinFeatureIndex.swift").read_text()
            suites = (output / "RegisteredFeatureTests.swift").read_text()
            self.assertIn("AlphaFeatureRegistration.self", registrations)
            self.assertIn("BetaFeatureRegistration.self", registrations)
            self.assertIn("AlphaFeatureTests.self", suites)
            self.assertIn("BetaFeatureTests.self", suites)
            app = (output / "app-sources.list").read_text().split("\0")
            self.assertIn("Sources/Features/Beta/File with spaces.swift", app)
            self.assertNotIn("Sources/App/main.swift", app)
            self.assertNotIn("Sources/Features/Clipboard/Policy/ClipboardHistory.swift", app)
            tests = (output / "test-sources.list").read_text()
            self.assertNotIn("ClipboardPolicyTests", tests)
            self.assertNotIn("DiagnosticsRegressions", tests)
            index.generate(root, output)
            self.assertEqual(registrations, (output / "BuiltinFeatureIndex.swift").read_text())
            beta.unlink()
            index.generate(root, output)
            self.assertNotIn("BetaFeatureRegistration.self", (output / "BuiltinFeatureIndex.swift").read_text())

    def test_duplicate_names_fail(self):
        with tempfile.TemporaryDirectory(prefix="feature-index-") as temporary:
            root = Path(temporary)
            for folder in ("Alpha", "Beta"):
                path = root / "Sources/Features" / folder / "SameFeatureRegistration.swift"
                path.parent.mkdir(parents=True)
                path.write_text("")
            with self.assertRaises(ValueError):
                index.generate(root, root / "build/generated")


if __name__ == "__main__":
    unittest.main()
