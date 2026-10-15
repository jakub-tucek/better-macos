# Development roadmap

Status at `f359f42` (2026-10-15). This is a development record, not a list of missing
user features or a release promise. Use [README.md](README.md) for current behavior
and [VALIDATION.md](VALIDATION.md) for evidence. Implementation and physical/native
acceptance are separate gates.

| Increment | Implementation | Remaining acceptance / scope |
| --- | --- | --- |
| 1A · Timed keep awake | Implemented | Physical sleep, expiry across sleep, explicit Sleep/lid-close behavior, interactive controls. |
| 1B · App-based keep awake | Implemented | Physical assertions and app/session interaction; see [awake evidence](AWAKE-VALIDATION.md). |
| 2A · Audio selection | Implemented | Actual independent microphone/output writes, headset/USB/monitor devices. |
| 2B · Audio routing rules | Implemented | Reconnect/unplug/wake, protected headphone behavior, external routing races. |
| 3A · Named window layouts | Implemented | Multi-app live Accessibility capture/restore, unsupported and ambiguous windows. |
| 3B · Reconnect/wake restoration | Implemented | Physical display cycles, settling and repeated notifications; see [window evidence](WINDOW-POSITIONS-VALIDATION.md). Current-desktop ordinary windows only. |
| 4A · Mouse acceleration/tracking | Implemented, opt-in mouse-class runtime backend | Physical effectiveness, trackpad invariance, reconnect and restoration. No per-device controls. |
| 4B · Separate wheel scrolling | Unsupported; not implemented | Reliable physical-device attribution is unresolved. No production wheel event tap. |
| 5A · Text clipboard history | Implemented | Live shortcut delivery, destination focus, keyboard/VoiceOver interaction. |
| 5B · Retention, pins, PNG | Implemented | Live responsiveness near archive caps and interactive privacy/recovery checks. Storage uses JSON, not SQLite. |
| UI B–D · Settings, widgets, setup | Implemented | E native acceptance remains partial; see [UI evidence](UI-REPLACEMENT-VALIDATION.md). |

## Future work boundaries

Wheel direction/speed needs a qualified attribution approach before implementation.
Per-device mouse control, cross-Space/full-screen window restoration, universal
animation suppression, notch-overflow panels, SQLite storage, and plugins are not
current capabilities or committed release work.

## Development gates

### Proposed organization work · not implemented

Consider an explicit built-in module registration interface and a feature-oriented
source layout after the release work settles. First preserve shared Audio/display
ownership, action admission, recovery and asynchronous cleanup semantics. A registry
would not itself provide dynamic plugins. There is no approved implementation or
release commitment for either change; [MODULES.md](MODULES.md) maps the current flat
layout. This documentation change does not move files or alter build inputs.

### Existing implementation gates

- Retain independent module lifecycles and saved settings; release owned timers,
  observers, event taps, and assertions when disabling a feature.
- Keep one owner for shared OS controls, including audio routing and display recovery.
- Use injected backends for policy checks. Record native and physical effects as
  separate evidence, including failures and untested hardware.
- Run `bash test.sh` and `git diff --check` for implementation changes. Review fixes
  and integration evidence by revision; test counts alone do not establish acceptance.
- Integrate reviewed changes one module at a time and recheck shutdown, shared UI,
  audio ownership, and display coordination.
