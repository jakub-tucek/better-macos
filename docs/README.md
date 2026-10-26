# Documentation

[Project overview and install](../README.md) · [Usage guide](usage.md) · [Developer setup](development.md)

## Using Better macOS

- [Usage, shortcuts, defaults, permissions, and Clipboard privacy](usage.md)
- [Session Activity: outcomes, Clear, and privacy](activity.md)
- [Local diagnostics: logging levels and safe log reading](diagnostics.md)
- [Known gaps and validation evidence](validation/README.md)

## Developing

- [Design: visual style, surfaces, setup, and interaction checks](../DESIGN.md)
- [Build, test, lint, and format commands; tested toolchains](development.md)
- [Feature owners, UI entry points, shared services, and source credits](modules.md)
- [Host coordination glossary](glossary.md)
- [Clipboard SwiftPM ownership and named policy suites](swiftpm.md)
- [CI configuration and unverified hosted execution](ci.md)
- [Roadmap: implemented foundations and remaining work](roadmap.md)
- [Agent safety and repository instructions](../AGENTS.md)

### Architecture

| Guide | Boundary |
| --- | --- |
| [Built-in registration](architecture/builtin-registration.md) | Static metadata and typed choice preparation, not runtime plugins |
| [Keep awake](architecture/keep-awake-feature.md) | Feature ownership, host admission, presentation, and shared palettes |
| [Window execution](architecture/window-execution.md) | AX discovery, verified writes, shortcut sessions, and captured palette targets |
| [Bluetooth observation](architecture/bluetooth-observation.md) | Helper control versus native presentation, bounded subprocesses, and cycle delivery |
| [Bluetooth control qualification](architecture/bluetooth-qualified-control.md) | Read-only probe implementation; native connection control remains unqualified |

## Validation and release work

- [Evidence index and open acceptance](validation/README.md), including [current UI/shortcut work](validation/ui-window-shortcuts.md)
- [Release readiness checklist](releases/checklist.md)
- [Unreleased 1.0 notes draft](releases/1.0-notes-draft.md), not the current app version

Validation records contain historical failures, review findings, and revision-bound
test counts. A passing isolated suite is not live hardware, VoiceOver, minimum-OS,
or hosted-CI acceptance. Ignored local logs referenced in records are not bundled
with this documentation.

## Archive

These preserve original requirements and research, not current UI instructions:

- [UI/UX implementation record](archive/ui-ux-plan.md)
- [Animation research · 2026-10-14](archive/animation-research.md)
