# Clipboard history UI

The dedicated nonactivating panel uses a compact, 56-point native list with text/image icons, 96-pixel downsampled PNG thumbnails, a single-line normalized text preview, relative age, source, and pin indicators. Pins appear first without duplication; retention/exclusions remain in Settings. A click selects, double-click/Return copies and dismisses; copying never pastes. Search keeps keyboard focus while arrows move selection. Escape dismisses.

Context menus offer Copy, Pin/Unpin, and Delete. Clear asks for confirmation and uses the existing memory/archive deletion path, including pins; it does not change the current clipboard or recording/persistence intent. Missing/deleted/expired selections are not silently redirected. Host transaction admission guards both shortcut opening and panel mutations, including deferred Clear confirmation.

## Isolated acceptance

`bash test.sh` includes `runClipboardPanelTests` in `Tests/ClipboardTests.swift`. All clipboard entries and PNG data are synthetic and memory-only, with a fake pasteboard and fake persistence. The fixture never calls `ClipboardModule.start()`, accesses the user's archive, or reads/writes the real clipboard. Only this synthetic fixture panel is displayed, without app activation.

Validated with `CLIPBOARD_FIXTURE_RENDER=1 bash test.sh`: 3,805 isolated checks plus all installer tests passed. `git diff --check` is clean. Full output is retained locally at `build/clipboard-validation.log`.

To render the same AppKit surface after building tests:

```sh
CLIPBOARD_FIXTURE_RENDER=1 build/isolated-tests
```

Generated images: `build/clipboard-history.png`, `build/clipboard-search.png`, `build/clipboard-no-results.png`, `build/clipboard-paused.png`, and a pixel-checked `build/clipboard-thumbnail.png`. These cache only the fixture content view, not the desktop or other windows.

Coverage: explicit opt-in/empty/paused/no-results states; pinned-first uniqueness; normalized previews; relative ages; thumbnail size/cache/invalid-data fallback/invalidation; search autofocus and arrows; selected identity through pin reorder; deletion and expiry selection clearing; contextual pin state; closed host admission; Return copy-only and dismissal; Escape dismissal; Clear preserving clipboard and privacy intent.

Real destination-app focus restoration and global Cmd-Shift-V registration remain manual acceptance gaps: exercising those against the running app would violate the no-live-panel/no-relaunch constraint. The panel retains its existing `.nonactivatingPanel` architecture and shortcut registration.

Shared-file seam: `AppDelegate.swift` sets `ClipboardModule.acceptsActions` for both injected and newly created modules, matching the existing Window Positions host-admission pattern. No dashboard/widget files or clipboard storage policy are changed.
