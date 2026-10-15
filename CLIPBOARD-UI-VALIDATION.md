# Clipboard history UI

The dedicated nonactivating panel uses a compact, 56-point native list with text/image icons, 96-pixel downsampled PNG thumbnails, a single-line normalized text preview, relative age, source, and pin indicators. Pins appear first without duplication; retention/exclusions remain in Settings. A click selects, double-click/Return copies and dismisses; copying never pastes. Search keeps keyboard focus while arrows move selection. Escape dismisses.

Context menus offer Copy, Pin/Unpin, and Delete. Clear asks for confirmation and uses the existing memory/archive deletion path, including pins; it does not change the current clipboard or recording/persistence intent. Missing/deleted/expired selections are not silently redirected. Host transaction admission guards both shortcut opening and panel mutations, including deferred Clear confirmation.

## Isolated acceptance

`bash test.sh` includes `runClipboardPanelTests` in `Tests/ClipboardTests.swift`. All clipboard entries and PNG data are synthetic and memory-only, with a fake pasteboard and fake persistence. The fixture never calls `ClipboardModule.start()`, accesses the user's archive, or reads/writes the real clipboard. Only this synthetic fixture panel is displayed, without app activation.

Initial UI validation with `CLIPBOARD_FIXTURE_RENDER=1 bash test.sh`: 3,805 isolated checks plus all installer tests passed. Output is retained locally at `build/clipboard-validation.log`; follow-up validation is recorded below.

To render the same AppKit surface after building tests:

```sh
CLIPBOARD_FIXTURE_RENDER=1 build/isolated-tests
```

Generated images: `build/clipboard-history.png`, `build/clipboard-search.png`, `build/clipboard-no-results.png`, `build/clipboard-paused.png`, and a pixel-checked `build/clipboard-thumbnail.png`. These cache only the fixture content view, not the desktop or other windows.

Coverage: explicit opt-in/empty/paused/no-results states; pinned-first uniqueness; normalized previews; relative ages; thumbnail size/cache/invalid-data fallback/invalidation; search autofocus and arrows; selected identity through pin reorder; deletion and expiry selection clearing; contextual pin state; closed host admission; Return copy-only and dismissal; Escape dismissal; Clear preserving clipboard and privacy intent.

Real destination-app focus restoration and global Cmd-Shift-V registration remain manual acceptance gaps: exercising those against the running app would violate the no-live-panel/no-relaunch constraint. The panel retains its existing `.nonactivatingPanel` architecture and shortcut registration.

Shared-file seam: `AppDelegate.swift` sets `ClipboardModule.acceptsActions` for both injected and newly created modules, matching the existing Window Positions host-admission pattern. No dashboard/widget files or clipboard storage policy are changed.

## Independent-review follow-up

- Search and previews now share one normalized representation, including the displayed PNG kind. Search uses the complete content, not its 240-character preview. Regressions cover newline/tab phrases, normalized query whitespace, image kind, and text beyond the preview cutoff. The phrase regression failed against the original implementation before the fix.
- Thumbnail requests return a placeholder immediately. A fixed-size PNG IHDR preflight rejects zero dimensions, edges over 8,192, more than 16,777,216 input pixels, and encoded input over the existing 4 MiB limit **before ImageIO is called**. ImageIO metadata is checked again before thumbnail decoding. These are thumbnail-only limits: the original entry remains listed/copyable with an icon fallback; capture and storage policy are unchanged.
- ImageIO executes on an operation queue with two utility workers and at most eight submitted/in-flight operations. Up to eight recent requests can be deferred at capacity; worker completion automatically drains them without waiting for another render. Both successful and failed results use a strict 48-entry LRU; output exceeding 96 pixels per edge is rejected. Request deduplication and cancellation are main-thread-owned. Closing the panel, filtering out a request, deleting/changing its payload, Clear, and module stop cancel relevant work. A running ImageIO call cannot be forcibly interrupted; its bounded-input result is ignored after cancellation. This is an input/pixel/concurrency bound, not a hard decoder time or process-RSS guarantee.
- Main-thread completion requires the current request token, entry UUID, and image bytes to match. Deleted, canceled, or same-ID/replaced-payload results cannot repopulate the cache or notify the view. Synthetic blocked-worker tests verify UI heartbeat responsiveness, two-worker/eight-request bounds, deduplication, cancellation, late-result rejection, failed-result caching, and the 48-entry cache limit. The synchronous-return regression failed before the fix.
- The fixture now dispatches actual key events through the native panel to its search field editor and table, and exercises the native Clear button/sheet responses for Cancel, confirmation, and admission closing while the sheet is open. These tests still use only synthetic memory-backed data and isolated preferences; they do not exercise real global shortcut delivery or another app's focus restoration.

Final follow-up validation: `CLIPBOARD_FIXTURE_RENDER=1 bash test.sh` passed **3,843 isolated checks plus all installer tests**, with regenerated native fixture images. `git diff --check` is clean. Full output: `build/clipboard-followup-validation.log`. The capacity-resumption regression was also observed failing before adding the bounded deferred queue.
