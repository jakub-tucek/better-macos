# Keep-awake validation

Implemented timed and bundle-ID app rules, startup discovery, workspace launch/exit
notifications plus periodic reconciliation, overlapping reasons, Stop/Resume, and
module teardown. App-only assertions use renewable 60-second OS timeouts; a stalled
process cannot keep renewing them. Only idle-sleep assertion types are used.

`bash test.sh` passes with the normal signing configuration; the app bundle was not
launched. Isolated fake-backend tests cover sleep-sized continuous-clock jumps,
partial creation/release failure, retries, duration limits, app startup/exit/relaunch,
overlapping reasons, pause/resume, and module disable with saved preferences.
`git diff --check` passes. Tests use disposable preference domains.

The opt-in `build/isolated-tests --awake-power-probe` creates two three-second idle
assertions, observes them with `pmset -g assertions`, waits eight seconds, verifies
they are absent, renews them, and explicitly releases both. This passed on this Mac.
An initial probe using `IOPMAssertionCopyProperties`'s level field failed: that field
remained 255 after timeout even though `AssertTimedOutWhen` was present and `pmset`
confirmed no active assertions. The probe now uses the active `pmset` list. Failed
probe processes exited and their assertions were reclaimed; subsequent probes
explicitly release owned assertions. No sleep or display configuration was changed.

Independent adversarial review identified failed-Start rollback, rapid app restarts,
misleading failure status, and idle publication churn. Fixes preserve app reasons,
track paused process instances, expose retry status, avoid redundant idle publishing,
and use the same deactivate path in production and tests. Regression tests cover each.

Follow-up review found two more recovery gaps: timed-only failed disable lost its
timer, and initial app-assertion failure hid Stop. Activation now reinstates updates
for owned/pending cleanup, and Stop reflects requested reasons as well as ownership.
A real run-loop regression verifies scheduled cleanup without manual ticks; another
verifies Stop prevents a failed app request from activating after backend recovery.
The strengthened bounded probe independently checks both owned assertion types in
`pmset` after creation and renewal, and their absence after timeout and release.
The full signed build, 220 isolated checks, installer checks, strengthened probe,
and whitespace check passed after these fixes.

Not exercised: actual system sleep, lid close, interacting with the new app picker,
or real third-party app launch/quit notifications. No external apps were quit, no
monitors or user preferences were changed, and the installed app was not relaunched.
The policy's workspace snapshots are injected in tests; OS notification timing and
visual layout still need interactive verification.

## Native duration-entry regression coverage (2026-10-15)

The duration fixture hosts the production `AwakeDurationEditor` in an unpresented
`NSWindow`. It discovers the actual editable `NSTextField`, makes it first responder,
and inserts raw text through its `NSTextView` field editor. Responder resignation
exercises the real SwiftUI focus-loss callback. Tests cover:

- Typing 7 and invoking Start without Return or prior focus loss: the real host
  persists 7 and the fake assertion backend receives exactly 420 seconds.
- Focus-loss commit during an existing session: only the next duration changes;
  the existing deadline and assertion creation count are unchanged.
- Intervening model publication, including pending publication followed immediately
  by responder resignation and Start: the typed draft remains authoritative.
- Empty, zero, fractional and overflowing edits across focus loss and Start;
  invalid edits remain visible and never start the previously saved duration.
- Failed Start and another Start after backend recovery, native fixture close and
  reopen, and staged Setup edits across navigation and Cancel.

**Button-delivery limitation:** synthetic mouse events and accessibility press did
not invoke SwiftUI's button in the hidden window. Start therefore uses
`AwakeDurationEditorCommands`, which holds the exact action registered by the
mounted production Start button, and is revoked on removal. The fixture does not
replace the native text binding or supply a separate draft. This verifies native
text/focus integration plus the production button action, **not** real mouse click
routing, keypad hardware, visual layout or window activation behavior.

`bash test.sh` passed with 3,967 isolated checks and installer checks; no app bundle
was launched, no real power assertions were created, and only disposable preference
domains were used. Live device, clipboard and interactive verification were not run.

## Shared readable countdown (2026-10-15)

The widget, Settings session card and fallback global Stop row share
`AwakeCountdown` and the same session-status policy. Examples: `1 hr 24 min left`,
`12 min 08 sec left`, `45 sec left`. Seconds round upward first; at hour scale,
remaining minutes also round upward, so a positive partial minute is never lost.
Exact hours omit the zero-minute component. Unit abbreviations stay `hr`, `min`
and `sec` for both singular and plural values; countdown digits are monospaced.

Boundary tests cover 59/60 and 3599/3600 seconds, fractional seconds, exact hours,
the 24-hour cap and expiry. Zero, negative, non-finite and above-cap inputs return
no countdown before integer conversion. Failure, app-only protection, ending
ownership and pending/inactive sessions use state labels rather than false zero
time or a healthy countdown. Duration preferences and entry behavior are unchanged.

`bash test.sh` passed with 3,997 isolated checks and installer checks. No live app
launch, power assertions, device or clipboard actions were performed for this work.
