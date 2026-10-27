# Link destination aliases · 2026-10-27

Source: alias changes based on `31001b2`, committed with this record.

Text is now the initial editor mode; Visual remains available. `alias: work ->
com.google.Chrome:Profile 1` declares a reusable destination, referenced with
`@work`. Definitions and rules save atomically in `links.config`. Rules retain
resolved destination IDs, so routing does not depend on alias lookup. Earlier
configuration decodes with an empty alias dictionary.

`build/links-alias-validation.log` records the pipeline from line 9 of `test.sh`:
5,389 isolated checks, 44 native UI checks, 10 policy tests in three suites,
Bluetooth checks, feature-index checks, packaging/build fixtures and 13 installer
scenarios. Pinned lint/format and whitespace checks passed.

Alias tests cover forward references, browser-name resolution, offline round-trip,
stable rule IDs, duplicate/invalid names, missing references, rejected chains,
case sensitivity, Visual/Text switching, draft redirection, Discard, persistence,
conflict rejection, atomic invalid-save rejection and explicit blank deletion.

The browser backend is injected; no test opens a live browser or profile. The
existing macOS 27 gesture-fixture gate still prevents a full `test.sh` pass on this
host. Native UI checks exercise the existing setup/global-alert host, not new
alias-specific accessibility or VoiceOver acceptance.

## Profile picker follow-up · 2026-10-27

Changes based on `f28f7c1` add Profile aliases controls alongside both editors.
The dropdown includes automatically discovered profiles, manual profiles and
browsers. Adding/remapping changes the shared draft, not live routing. Invalid
text blocks picker edits rather than replacing unfinished input.

Rules now retain an optional alias name alongside their resolved destination ID.
This prevents `@home` and `@work` from collapsing into one reference when both
currently point to the same browser. Older rules still decode without that field.

`build/links-alias-picker-validation.log`: 5,395 isolated checks, 44 existing native
UI checks and supporting pipeline/installer fixtures passed. New checks cover
picker-driven add/remap, shared-target alias independence, reference persistence
and unfinished-text preservation. Pinned lint/format and whitespace checks passed.
Live profile launching and alias-specific VoiceOver acceptance remain unverified.
