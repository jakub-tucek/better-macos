# Window positions (roadmap 3A / 3B)

Implemented named, persisted layouts per stable display UUID set; exact bundle-ID/title matching rejects duplicates and untitled windows. Restore reports missing, ambiguous, unsupported, excluded, and failed windows. Frames are display-relative and clamped to current visible bounds. AX permission is explicitly requested from the Windows dashboard.

Automatic restoration defaults off. Wake and display-set changes restore once after the existing display quiet period, fresh snapshot, watchdog readiness, recovery, and confirmation gates. Saved selection resolves multiple layouts for a set; otherwise restoration requires a unique layout. Pause and comma-separated app bundle-ID exclusions persist across module unload, as do layouts and selection. No app launches or Space switching.

Isolated evidence: `bash test.sh` builds the complete host/UI and runs injected backend tests for clamping, ambiguity, exclusions, permission denial, wake/confirmation gating, deduplication, reconnect, cancellation, and persistence. Tests never call the live AX backend or change displays. No live window-moving, app relaunch, or hardware validation was performed.

Hardware validation still needed: multiple actual displays including rotation/scaling, Dock/menu-bar insets, wake/reconnect notification timing, TCC under signed app identity, and app-specific AX minimum sizes/refusals. Exact-title matching deliberately skips renamed documents and cannot identify a different document reusing the same unique title. Apps with unavailable full-screen metadata are conservatively unsupported. No cross-Space or full-screen restoration is promised. Window titles are stored locally in preferences with the layout.

Independent review of initial commit `60ab300` blocked on cumulative main-thread AX delays, ambiguous same-geometry visibility correlation, reconnects hidden by debounce, and resize-before-move behavior. Follow-up changes add a 750 ms discovery budget (incomplete scans fail closed), explicit 50 ms AX element timeouts, one write per main-queue turn with generation/display checks, conservative rejection of same-geometry siblings, fresh eligibility/AX identity validation before each move, raw add/remove callback coalescing, and destination move–resize–position sequencing. These are isolated/code-level protections; actual macOS timeout enforcement and destination resizing remain hardware acceptance checks. An individual AX call already in progress cannot be canceled; subsequent writes are canceled.

Additional isolated coverage exercises the real AppDelegate readiness adapter with a fake backend, a two-app queued restore interrupted by confirmation, a rapid disconnect/reconnect retaining the same final display set, changed bounds before a queued write, duplicate saved matches, unsupported/missing windows, and ambiguous visibility geometry. No live AX calls are used in these tests.

Second independent review (`e275ff6`) found swap-induced geometry collisions, discovery timeouts misrepresented as empty snapshots, and incomplete metadata undermining ambiguity checks. The next fix plans collision-free ordering with bounded one-pixel parking for cycles; discovery now throws on timeout or incomplete metadata and cannot create an empty saved layout on failure. Failed enumeration/title reads invalidate the matching domain. Tests update fake geometry and reproduce the swapped same-app case. Callback registration now uses a weak, locked registry rather than dereferencing module pointers; scheduled writes include a 10 ms run-loop gap for heartbeat timers.

Conservative limitations: an incomplete AX snapshot aborts the operation with an explicit error; retry after the affected app responds. Same-app targets with unavoidable identical geometry or no safe parking space are rejected before writing. Cancellation after temporary parking may leave that window one pixel from its starting position; rerun Restore now when stable. Restoration is best effort, not transactional rollback.

Display-set coverage includes negative coordinates, translation of display B, multiple saved layouts requiring explicit selection, and A–B–C → A–C → A–B–C without discarding stored layouts or repeating restores.

GPT-6.1 Sol independently reviewed `e283d5d..274fb06`: no critical issue; one warning remained for CoreGraphics failure/permission loss becoming empty discovery. Both paths now throw and have adapter-level regressions with injected permission/window-list functions, making no live AX or WindowServer reads. The earlier in-flight review also identified failure-dependent destination collisions: any failed write now stops the plan, and each live write validates fresh destination occupancy. New isolated checks exercise these failure paths. Global fail-closed discovery remains deliberate: even an excluded unreadable app can abort capture/restore; exclusions prevent movement, not discovery failures.

Validation at `6e36672`: `bash test.sh` passed the full host/UI build, 238 isolated checks, and all seven installer fixtures. `git diff --check e283d5d HEAD` passed. No live window movement, display changes, or app relaunch occurred. Installer tests use disposable fixture applications rather than the user's installed app.

## Verified execution seam · 2026-10-22

Candidate 1 implementation, uncommitted working tree based on `355f8d4`:
[Windows execution](../architecture/window-execution.md) moves production discovery,
identity validation and verified write ordering behind a native-access seam. The
existing `WindowPositionBackend` interface, `AXWindowPositionBackend` constructors
and static helper tests remain. Host admission, coordinator guards and shortcut
lifecycle are unchanged. The new deterministic native-access adapter exercises the
actual execution algorithm, not a replacement `WindowPositionBackend` algorithm.

Final `bash test.sh` passed the full signed app/UI build, packaging/compiler-input
and rollback fixtures, **4,924 legacy isolated checks**, **10 policy tests in three
suites**, and **13 installer fixtures**. Pinned lint and format checks passed across
76 files; `git diff --check` passed. Logs: `build/window-execution-test.log`,
`build/window-execution-lint.log`, `build/window-execution-format.log`.

An intermediate expanded run failed a new test's incorrect expected native write
handle after intervening discovery refreshed the cache. The fixture now changes
handles again before moving and verifies semantic native identity equality against
the element cached at move entry. No production behavior was changed to satisfy
the assertion. Failure retained in
`build/window-execution-test-alias-assertion-failure.log`. The known SwiftPM native
build-system deprecation warnings remain visible in the passing run.

No live AX discovery/writes, window movement, display changes, app launch/relaunch,
permission requests or user preference changes were performed. Existing native
timeout, focus, TCC and app-specific resize acceptance gaps remain open. The scan
budget still cannot preempt an in-flight native call; this refactor adds no end-of-
scan deadline check or write rollback.
