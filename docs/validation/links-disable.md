# Links disable hands back the default browser · 2026-10-26

Source: changes based on `0946c8e`, committed with this record.

The host previously committed Links Off without a browser handoff. The regression
in `build/links-disable-red.log` reproduces that through the real host module action.

Explicit disable now waits for the Links owner to hand HTTP/HTTPS associations
still owned by Better macOS to the configured fallback browser. Profile fallbacks
resolve to their browser application; unavailable targets use Safari. The system
backend rechecks ownership before each scheme write. Other apps' associations stay
untouched. Readback must show that Better macOS no longer owns either scheme before
the host commits Off. Failure retains enabled Links and shows an error for retry.
Host shutdown waits while the handoff is pending. Quit alone does not hand back
associations. Rules and profile choices remain saved.

`build/links-disable-validation.log` records `tail -n +9 test.sh | bash -e`:

- 5,376 isolated checks, including host disable timing, duplicate requests, failure
  and retry, unchanged readback, profile-to-browser fallback, missing fallback,
  preservation of external defaults/unrelated errors, quit and direct admission.
- 44 native UI checks; 10 policy tests in three suites; Bluetooth and feature-index
  checks; packaging/build fixtures and 13 installer scenarios.
- Pinned lint/format and whitespace checks passed.

All browser mutations in tests use an injected backend. Live macOS default-browser
confirmation, partial HTTP/HTTPS ownership and refusal behavior remain unverified.
The full suite still has the earlier macOS 27 gesture-fixture gate; the command above
does not claim that gate passed.
