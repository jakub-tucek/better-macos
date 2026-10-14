# macOS animation research — 2026-10-14

Target: locally confirmed **Tahoe 26.6.2 (25G83)**, with Reduce Motion already enabled. Internet/source investigation, installed-binary inspection, and a hidden AppKit timing probe; no persistent preferences changed, private APIs executed, or live animations tested. No inspected upstream source establishes exact **26.6.2** compatibility. “Source-confirmed” below means implementation inspected, not runtime validation.

## Conclusions

- **Horizontal Spaces:** strafe / InstantSpaceSwitcher / iss provide the strongest non-SIP route. They replace horizontal gestures with synthetic high-velocity gestures, not a global animation switch. strafe publishes measurements on **26.3**, not 26.6.2. [S1–S3]
- **Mission Control overview and Control Center residual fades:** no verified universal preference or usable global kill-animation API emerged. Reduce Motion promises reduction, not zero duration. Horizontal switching fixes intentionally pass vertical gestures through. [A1, S1–S3]
- **Dock:** launch bounce has an official setting; hide/show timing preferences are reasonable isolated experiments. Minimize “scale” selects an effect, not no effect. [A2, P1]
- **AppKit:** `NSWindowResizeTime` actually remains documented by Apple, but its scope is narrow. `NSAutomaticWindowAnimationsEnabled` has much weaker evidence and is not a proven Tahoe/global fix. [A3, P2]
- **Private/injected route:** yabai and instantspaces patch Dock's Spaces duration. This is concrete source, but neither establishes elimination of Mission Control overview / Control Center fades. SIP changes and build-specific matching are material prerequisites. [Y1–Y3, I1]

## Scope and practical options

| Target | Concrete option | Evidence / limits | Activation and undo |
|---|---|---|---|
| Launch bounce | Desktop & Dock → disable **Animate opening applications**; equivalent candidate `defaults write com.apple.dock launchanim -bool false` | Apple documents bounce setting; dotfiles document key. Does not suppress every attention-request bounce. [A2, P1] | UI normally applies directly; raw key experiment: restart Dock. Restore previous setting. SIP intact. |
| Dock reveal delay | `defaults write com.apple.dock autohide-delay -float 0` | Historical source recipe; changes waiting before reveal, not animation duration. Exact Tahoe behavior untested. [P1] | Restart Dock (`killall Dock`); restore prior value or delete only if previously absent. SIP intact. |
| Dock hide/show duration | `defaults write com.apple.dock autohide-time-modifier -float 0` | Separate historical recipe, specifically hide/show motion. High-priority local validation candidate. [P1] | Same Dock restart and per-key restoration. |
| Minimize/restore | Desktop & Dock minimize effect **Scale**; candidate `defaults write com.apple.dock mineffect -string scale` | Official effect selector + source recipe; still an animation. No verified `none` value or zero-duration Tahoe preference found. [A2, P1] | UI or Dock restart; restore previous effect. SIP intact. |
| AppKit automatic window opening/closing | Candidate `defaults write -g NSAutomaticWindowAnimationsEnabled -bool false` | Historical recipe only; no Apple guarantee found, no 26.6.2 test. Cannot assume it affects SwiftUI/custom CA animations or system components. [P2] | Relaunch target app for controlled test; restore value/absence and relaunch. SIP intact. |
| AppKit animated frame resize | Candidate `defaults write -g NSWindowResizeTime -float 0.001` | Apple explicitly documents seconds **per 150 pixels** for base `NSWindow.animationResizeTime(_:)`; subclasses can override. Not a fullscreen/Spaces/global speed control. [A3] | Relaunch target app; restore prior value/absence and relaunch. SIP intact. |
| Mission Control overview | `expose-animation-duration` | Old dotfiles prescribe it; FastMissionControl explicitly says it does not fix current macOS. Treat as historical/unverified, not a working Tahoe solution. [P1, F1] | No reason to bulk-apply; if experimentally set, restore exact previous value and restart Dock. |
| Native Control Center | No verified zero-fade preference found | Neither Spaces synthesis nor Dock duration patches target Control Center. Changing `NSPopover.animates` in our app cannot mutate another process's popover. [A4, S1, Y1] | No implementation recommendation without local discovery of the owning animation path. |

Preference rollback means restoring the original **type, value, and absence**; deleting a key is correct only when it was absent before. A successful `defaults write` proves storage, not that a process reads the key. The suggested relaunches are experimental hygiene, not evidence of Tahoe support.

## Horizontal Spaces: source evidence

**strafe `37ec57e0dd7ae91c22225bc36bf5cd210ff9cba7`:** `CStrafe.c` sets private CGEvent fields 55 (type 30/DockControl), 110 (HID type 23), 123 (horizontal=1), 124 (progress), 129/130 (velocity), 132 (phase). Pre-27 path uses signed `FLT_TRUE_MIN` progress; `strafe_post_switch_gesture` posts began → changed → ended. `SwipeInterceptor.swift` suppresses only horizontal Dock swipes and passes through while Exposé is active. All three phases matter; source warns two break Mission Control state. [S1]

Its published 26.3 benchmark: median first delivered event 168.5 → 49.6 ms, transition/input-unlock 164.4 → 42.3 ms (20 trials each). These are **maintainer measurements**, not independently reproduced and not literal zero latency. Latest README says older OS versions were not retested for the macOS 27 update. Private payload/version branches therefore remain relevant even on maintained upstream. [S1]

**InstantSpaceSwitcher `f7616e42651b1ed8d81625e3640eceed6efa8018`:** same gesture family; CLI exposed as `InstantSpaceSwitcher.app/Contents/MacOS/ISSCli --help`. README says no SIP disable and Accessibility required. Current `ISS.c` has newer serialized-event support; avoid treating strafe's historical `docs/SPEC.md` as the current ISS implementation. [S2]

**joshuarli/iss `493b008f2ea8e9215877c39700e8ea3add800e97`:** minimal C variant, session event tap, paired companion gesture events; pre-27 end velocity ±400, newer IOHID payload branch. Explicitly filters horizontal swipes; Mission Control/App Exposé pass through. Source still contains an SDK-based pre-27 direction macro, so do not assume identical behavior across all build SDKs from README compatibility claims alone. [S3]

Operational options: standalone `strafe switch left|right`, its swipe interceptor, or ISS CLI/hotkeys. Accessibility permission, no SIP reduction or Dock injection; strafe requires relaunch after first Accessibility grant. Stop interception/quit to undo; uninstall any login agent if installed. These do not automatically intercept every native keyboard, app-activation, or Mission Control-triggered Space change. [S1–S3]

## Private SkyLight / CGS: what the symbols actually do

The NUIKit/CGSInternal headers are **reverse-engineered historical declarations**, not Apple ABI contracts or proof of modern exports. Use them to interpret local symbol findings, not to blindly declare every `CGS` name as an equivalent `SLS` function. [G1–G3]

| API / mechanism | Demonstrated semantics | Why it is not a global off-switch |
|---|---|---|
| `CGSNewTransition(cid, spec, &id)`; `CGSInvokeTransition(cid, id, duration)`; `CGSReleaseTransition` | Creates/runs/releases a transition owned by caller; duration in seconds; spec `wid=0` means fullscreen transition, `kCGSTransitionNone` selects no effect. [G1] | Fullscreen describes effect coverage, not authority to cancel every other process's animation. No enumeration/cancellation of all system transitions shown. |
| `CGSCreateGenieWindowAnimation(..., &animation)`; `CGSCreateMetalSheetWindowAnimationWithParent(..., &animation)` | Creates specific genie/sheet animation objects. [G2] | Creating your own animation is not disabling Dock/AppKit's animation objects. |
| `CGSSetWindowAnimationProgress(CGSAnimationRef animation, CGFloat progress)`; `CGSReleaseWindowAnimation(animation)` | Progress/release acts on **animation object**, not a window ID or global connection. [G2] | Must possess the correct object and ABI; cannot pass arbitrary window ID to finish another process's effect. No Tahoe-tested universal completion primitive found. |
| `CGSSetWindowListAlpha(cid, windows, count, alpha, duration)` | Changes listed windows' alpha over duration. [G2] | Property manipulation, not disabling future fades; ownership restrictions apply. |
| `SLSSetWindowAlpha(int cid, uint32_t wid, float alpha)`; `SLSTransactionSetWindowSystemAlpha(...)` | Actual modern declarations/use in yabai injected payload; yabai implements its own fades by repeatedly setting alpha. [Y1] | Forcing alpha does not stop the owner's next animation update. Historical CGS header uses `CGFloat` for alpha whereas yabai's SLS declaration uses `float`: ABI cannot be guessed from name similarity. |
| `SLSShowSpaces`; `SLSHideSpaces`; `SLSManagedDisplaySetCurrentSpace` | yabai's `do_space_focus` shows destination, hides source, updates current Space and Dock's `_currentSpace` ivar. [Y1] | These calls are made **inside Dock**, with Dock state synchronized; not evidence a normal helper can call them equivalently. |
| `CGSGetDebugOptions`; `CGSSetDebugOptions` | Historical global diagnostic flags; header says flags survive caller death. [G3] | Enumerated flags cover shadows, drawing/debugging, etc.; no substantiated “disable all animations” flag. Do not invent a magic mask. |

**SIP nuance:** private API use itself does not automatically require disabling SIP (gesture tools illustrate this). Foreign-window authority and injection into protected Dock are separate constraints. No source inspected establishes a normal-app `SLS/CGSSetGlobalAnimation…` toggle with a valid signature and global semantics. Exported names alone will not establish either. [S1, Y1–Y2, G2]

## Dock injection: yabai and instantspaces

- **yabai `dd845723416f5fe92af49fad5ebab00369e07edd`:** `src/osax/payload.m` scans Dock for `animation_time_addr`, changes page permissions with `vm_protect`, and patches instructions: arm64 `0x2f00e400`, x86_64 `0x660fefc0660fefc0`. This happens during scripting-addition initialization. `verify_os_version` admits major 26 as “Tahoe Preview” using Sequoia state; exact 26.6.2 matching is unproven. [Y1]
- `yabai -m space --focus next` is the concrete Space-switch operation; source's direct Space manipulation is separate from the duration patch. `window_animation_duration 0` controls **yabai's own** movement animation, not all macOS motion. [Y1, Y3]
- **flawnn/instantspaces `53b9b597d526db8a6f9353c4084cfa1bc4490080`:** isolates the Dock patch, Apple Silicon/arm64e. `src/payload.m` has a major-26 pattern and searches/patches matching duration sites. Modes are `zero` (`0x2f00e400`) and `min0125` (`0x1e681000`, `fmov d0,#0.125`). README claims Tahoe support, but no exact 26.6.2 verification. [I1]
- instantspaces recommends 0.125 s because its author observed floating windows/popups not redrawing with zero duration. That is a documented maintainer observation, not a universal causal proof. “Total sites patched” verifies matching/writes, not correct visual behavior. [I1]
- yabai's Apple Silicon macOS 13+ instructions require partially disabling filesystem/debugging/NVRAM SIP protections in Recovery, rebooting, and enabling `-arm64e_preview_abi` boot argument with another reboot. instantspaces broadly requires SIP disabled and uses LLDB injection. These are not comparable to ordinary per-user preferences. [Y2, I1]
- Patches are in-process: stop reinjection/login watchers and restart Dock to remove the loaded patch; uninstall payload/agent for persistence cleanup. Restore original boot arguments and re-enable SIP in Recovery/reboot when reversing that setup. A Dock restart alone is ineffective while a watcher immediately reinjects. [I1, Y2]

## Own app windows, sheets, and popovers

- `window.animationBehavior = .none` is Apple-supported for automatic `orderFront` / `orderOut` animations on **that window**. It does not promise no miniaturization, fullscreen, custom layer animation, or every sheet transition. [A5]
- `setFrame(_:display:animate: false)` avoids requesting animated resize; `animationResizeTime(_:)` supplies duration when animated resize is requested. The documented `NSWindowResizeTime` default is 0.20 seconds per 150 pixels, subject to OS changes and subclass override. [A3]
- `popover.animates = false` controls showing, closing, moving, detaching, and content-size transitions, but Apple explicitly calls it a **hint that may not be respected**. [A4]
- `NSAnimationContext.duration = 0` applies to animatable changes in the current context, not all processes. Sheet animations may have a separate AppKit/server path; no verified global sheet-duration preference for 26.6.2 found. [A6, G2]
- These in-process changes require neither SIP changes nor system restart; undo by restoring the object's prior setting/code. Applying equivalent interception inside an Apple system process would be a separate injection/reverse-engineering project.

## Mission Control replacement worth evaluating

**FastMissionControl `85c1d3ad94b89aca256a9344c13f309fdbe0ece8`** builds its own overview using captured windows. It does not patch native Mission Control. README identifies an unsigned alpha needing Screen Recording + Accessibility and missing some Space/window-drag features. [F1]

Source is more precise than “fast”: `AppSettings.swift` defaults open animation to **0.22 s**, selection dismissal **0.18 s**, UI ranges minimum **0.05 s**; `OverviewWindowController.swift` explicitly animates panel alpha during dismissal and uses 0.28 s relayouts. Consequently it is a promising **modifiable replacement**, not an out-of-box zero-animation answer. No SIP change documented; quit/unbind replacement shortcut to undo. [F2]

## Local Tahoe findings

Read-only inspection on this Mac used `defaults export`, `strings -a`, and Xcode's `dyld_info` (`-exports`, `-section __TEXT __cstring`, `-disassemble`). String/symbol presence is evidence for investigation, not proof of a working preference or callable cross-process control.

- Existing preferences: Reduce Motion **on**; Dock auto-hide **on**, reveal delay **0**, hide/show modifier **0.25**; `expose-animation-duration` already **0** despite the reported residual fade. Launch-animation, no-bouncing, Finder `DisableAllAnimations`, and the listed global AppKit animation preferences are unset.
- Installed **Dock** contains `autohide-delay`, `autohide-time-modifier`, `launchanim`, `no-bouncing`, and `mineffect`. `expose-animation-duration` was absent from its extracted strings. Absence alone cannot rule out dynamically constructed keys or another owner.
- Installed **Finder** contains `DisableAllAnimations`; actual affected operations remain untested.
- Installed **AppKit** contains `NSAutomaticWindowAnimationsEnabled`, `NSWindowResizeTime`, `NSScrollAnimationEnabled`, `NSScrollViewRubberbanding`, and `NSSheetAnimationTime`. These are scoped candidates, not established global switches. Disabling rubber-banding changes scrolling feedback rather than window fades.
- **Measured AppKit result:** a fresh process created an offscreen, never-ordered `NSWindow` and called public `animationResizeTime(_:)` for a 400×300 → 800×600 resize. Default reported **0.35 s**; process-local `-NSWindowResizeTime 0` still reported **0.35 s**; `0.05` reported **0.0971 s**; `0.001` reported **0.001942 s**. This verifies the base timing calculation, not rendered duration or application overrides. Preferences were supplied only through the process argument domain.
- Installed private **WindowManager.framework** exports `WindowManagerPreferencesController.animationSpeed` and `.disableTilingAnimations`. Static disassembly shows their getters messaging `AnimationSpeed` and `DisableTilingAnimations`. These are concrete new leads for window-management/tiling effects; preference storage domain, accepted values, affected consumers, and live behavior have **not** been established. They are not yet a Mission Control fade fix.
- Installed **ControlCenter** contains `MenuFadeCoordinator`, `CrossfadeEffectView`, and `_BentoTransitionCoordinator`. No general disable-animation preference emerged from the string search. These internal names suggest animation paths to trace, not an external API for cancelling them.
- Installed **SkyLight** exports `SLSNewTransition`, `SLSInvokeTransition`, `SLSReleaseTransition`, `SLSSetWindowAnimationProgress`, `SLSSetDebugOptions`, and the Space-management calls discussed above. It also contains `DisableCosmeticSessionTransition`; its name does not establish scope, preference domain, or usability. No private calls were attempted.

Best next experiments: independently test Dock hide/show modifier **0**, launch/attention bounce suppression, and selected AppKit preferences with exact preference restoration. Separately trace WindowManager's two concrete animation properties before proposing a tiling module. Native Control Center and Mission Control fades remain unresolved.

### Follow-up: implemented system preset

The preset now includes Dock reveal delay, hide/show timing, launch/attention bounce,
magnification, Scale minimization, Finder effects, AppKit automatic window effects,
resize timing, smooth scrolling, and experimental window-tiling suppression.
Scale remains an animation; these are requested preferences, not a guarantee that
every application honors them. Turning the preset off restores original values
and absence. Upgrades extend the saved snapshot without replacing earlier originals.

A disposable Objective-C probe loaded Tahoe's WindowManager framework and inspected
its NSUserDefaults category. `AnimationSpeed` and `DisableTilingAnimations` getters
return objects (`@16@0:8`). With a `com.apple.WindowManager` suite, both returned nil;
a process-only NSArgumentDomain override produced 10 and 1 respectively. This proves
the category reads those keys, not that a live compositor consumes them. Only
`DisableTilingAnimations=true` is included, explicitly experimental; no animation-speed
number is guessed. A new login may be needed for the live window manager to reload it.
The first Swift runtime-enumeration probe crashed its own disposable process; the
Objective-C probe avoided Swift class bridging and completed successfully.

## Primary references

- [A1] Apple, Tahoe-versioned [Customize onscreen motion](https://support.apple.com/guide/mac-help/mchlc03f57a1/26/mac/26). Unversioned pages now describe macOS 27; use versioned links.
- [A2] Apple, Tahoe-versioned [Desktop & Dock settings](https://support.apple.com/guide/mac-help/mchlp1119/26/mac/26).
- [A3] Apple [`animationResizeTime(_:)`](https://developer.apple.com/documentation/appkit/nswindow/animationresizetime(_:)); [readable documentation JSON](https://developer.apple.com/tutorials/data/documentation/appkit/nswindow/animationresizetime(_:).json).
- [A4] Apple [`NSPopover.animates`](https://developer.apple.com/documentation/appkit/nspopover/animates); [JSON](https://developer.apple.com/tutorials/data/documentation/appkit/nspopover/animates.json).
- [A5] Apple [`NSWindow.animationBehavior`](https://developer.apple.com/documentation/appkit/nswindow/animationbehavior-swift.property); [JSON](https://developer.apple.com/tutorials/data/documentation/appkit/nswindow/animationbehavior-swift.property.json).
- [A6] Apple [`NSAnimationContext.duration`](https://developer.apple.com/documentation/appkit/nsanimationcontext/duration).
- [P1] Mathias Bynens' own [dotfiles `.macos`](https://github.com/mathiasbynens/dotfiles/blob/main/.macos): primary evidence of the recipe, **not** proof the proprietary OS still implements it.
- [P2] Original [animation-disable gist](https://gist.github.com/j8/8ef9b6e39449cbe2069a): historical recipe, no exact Tahoe validation.
- [S1] strafe pinned [README/benchmark claims](https://github.com/rileycx/strafe/blob/37ec57e0dd7ae91c22225bc36bf5cd210ff9cba7/README.md), [C implementation](https://github.com/rileycx/strafe/blob/37ec57e0dd7ae91c22225bc36bf5cd210ff9cba7/Sources/CStrafe/CStrafe.c), [interceptor](https://github.com/rileycx/strafe/blob/37ec57e0dd7ae91c22225bc36bf5cd210ff9cba7/Sources/strafe/SwipeInterceptor.swift).
- [S2] InstantSpaceSwitcher pinned [README](https://github.com/jurplel/InstantSpaceSwitcher/blob/f7616e42651b1ed8d81625e3640eceed6efa8018/README.md), [ISS.c](https://github.com/jurplel/InstantSpaceSwitcher/blob/f7616e42651b1ed8d81625e3640eceed6efa8018/Sources/ISS/ISS.c).
- [S3] iss pinned [README](https://github.com/joshuarli/iss/blob/493b008f2ea8e9215877c39700e8ea3add800e97/README.md), [iss.c](https://github.com/joshuarli/iss/blob/493b008f2ea8e9215877c39700e8ea3add800e97/iss.c).
- [G1] CGSInternal pinned [`CGSTransitions.h`](https://github.com/NUIKit/CGSInternal/blob/c4f6f559d624dc1cfc2bf24c8c19dbf653317fcf/CGSTransitions.h).
- [G2] CGSInternal pinned [`CGSWindow.h`](https://github.com/NUIKit/CGSInternal/blob/c4f6f559d624dc1cfc2bf24c8c19dbf653317fcf/CGSWindow.h).
- [G3] CGSInternal pinned [`CGSDebug.h`](https://github.com/NUIKit/CGSInternal/blob/c4f6f559d624dc1cfc2bf24c8c19dbf653317fcf/CGSDebug.h).
- [Y1] yabai pinned [`payload.m`](https://github.com/koekeishiya/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/osax/payload.m).
- [Y2] yabai maintainers' [SIP instructions](https://github.com/koekeishiya/yabai/wiki/Disabling-System-Integrity-Protection). Its historical SIP-introduction date is inaccurate; relied on here for project prerequisites only.
- [Y3] yabai [configuration manual](https://github.com/koekeishiya/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/doc/yabai.asciidoc).
- [I1] instantspaces pinned [README](https://github.com/flawnn/instantspaces/blob/53b9b597d526db8a6f9353c4084cfa1bc4490080/README.md), [payload](https://github.com/flawnn/instantspaces/blob/53b9b597d526db8a6f9353c4084cfa1bc4490080/src/payload.m).
- [F1] FastMissionControl pinned [README](https://github.com/tomeraviv/FastMissionControl/blob/85c1d3ad94b89aca256a9344c13f309fdbe0ece8/README.md).
- [F2] FastMissionControl pinned [settings/durations](https://github.com/tomeraviv/FastMissionControl/blob/85c1d3ad94b89aca256a9344c13f309fdbe0ece8/FastMissionControl/App/AppSettings.swift), [overview controller](https://github.com/tomeraviv/FastMissionControl/blob/85c1d3ad94b89aca256a9344c13f309fdbe0ece8/FastMissionControl/Overlay/OverviewWindowController.swift).
