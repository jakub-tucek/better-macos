#!/usr/bin/env python3
"""Generate static Swift indexes and compiler inputs; never discover runtime plugins."""
import argparse
from pathlib import Path
import re


def collect(root):
    app = sorted(p for p in (root / "Sources").rglob("*.swift")
                 if root / "Sources/Features/Clipboard/Policy" not in p.parents
                 and p != root / "Sources/App/main.swift")
    tests = sorted(list((root / "Tests").glob("*Tests.swift"))
                   + list((root / "Tests/Support").rglob("*.swift"))
                   + list((root / "Tests/Features").rglob("*.swift")))
    registrations = sorted((root / "Sources/Features").rglob("*FeatureRegistration.swift"))
    suites = sorted((root / "Tests/Features").rglob("*FeatureTests.swift"))
    for paths in (app, tests, registrations, suites):
        names = [p.name for p in paths]
        if len(names) != len(set(names)):
            raise ValueError("Duplicate Swift filenames: use feature-prefixed filenames")
    for path in registrations + suites:
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", path.stem):
            raise ValueError("Registration/suite filename must be a Swift identifier")
    return app, tests, registrations, suites


def generate(root, output):
    app, tests, registrations, suites = collect(root)
    output.mkdir(parents=True, exist_ok=True)
    def write(name, text):
        path = output / name
        if not path.exists() or path.read_text() != text:
            path.write_text(text)
    write("BuiltinFeatureIndex.swift", "// Generated. Edit feature-owned registration files.\n"
          "enum BuiltinFeatureIndex {\n    static let registrations: [FeatureRegistration.Type] = [\n"
          + "".join(f"        {p.stem}.self,\n" for p in registrations) + "    ]\n}\n")
    write("RegisteredFeatureTests.swift", "// Generated. Add feature-owned test suites.\n"
          "enum RegisteredFeatureTests {\n    static let suites: [FeatureTestSuite.Type] = [\n"
          + "".join(f"        {p.stem}.self,\n" for p in suites)
          + "    ]\n    static func run() throws { for suite in suites { try suite.run() } }\n"
          "    static func render(directory: String?) throws { for suite in suites { try suite.render(directory: directory) } }\n}\n")
    for name, paths in (("app-sources.list", app), ("test-sources.list", tests)):
        write(name, "".join(str(p.relative_to(root)) + "\0" for p in paths))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--output", type=Path, default=Path("build/generated"))
    args = parser.parse_args()
    generate(args.root.resolve(), args.output)
