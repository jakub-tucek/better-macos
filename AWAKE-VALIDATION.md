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

Not exercised: actual system sleep, lid close, interacting with the new app picker,
or real third-party app launch/quit notifications. No external apps were quit, no
monitors or user preferences were changed, and the installed app was not relaunched.
The policy's workspace snapshots are injected in tests; OS notification timing and
visual layout still need interactive verification.
