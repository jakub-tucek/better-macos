# Design

Use this when adding or changing a screen, widget, palette, or setup step.

## Design direction

**Open:** minimalist, native macOS UI. Keep content visible, hierarchy clear, and
everyday actions close. Use system fonts, SF Symbols, neutral surfaces, subtle
borders, and generous spacing. Reserve accent color for selection and primary
actions; pair status colors with text or icons.

- Reuse `AppHeading`, `AppSurface`, `AppSymbolBadge`, and `AppActionRow` from
  `Sources/SharedUI/AppStyle.swift`. Use its tokens rather than inventing a theme.
- Lead with useful status and the main action. Put explanation and advanced
  controls below. Use previews when behavior is easier to show than describe.
- Write short, concrete labels: “Battery details”, “End session”, “Restore layout”.
  Show units, distinguish estimates from measurements, and label missing data
  “Unavailable” rather than inventing zero values.

## Surfaces and navigation

- **Quick actions:** compact status and frequent actions. Expanded widgets add
  detail; full configuration belongs in Settings. Keep awake, Displays, and
  Clipboard lead the suggested order. Preserve the user's saved layout.
- **Settings:** group related controls. Give substantial features a focused detail
  page. A widget's details link must land on visible, relevant content, not the top
  of an unrelated group. Reuse the existing Settings window.
- **Palettes:** use the shared action-palette layout for quick choices, with
  keyboard navigation, shortcut labels, and Escape to dismiss.
- Show one primary app surface at a time. Keep drafts when hiding a window;
  opening a view or palette must not execute its featured action.

## Setup and state

- Introduce the feature, offer **Enable & configure / Skip**, check required access,
  then configure. Keep setup large, centered, and bounded by the screen.
- Stage edits until **Finish**. Preserve saved choices on repeat setup. Offer
  **Easy setup · enable all**, followed by access checks and review.
- Show per-feature results with icons, clear outcomes, and a working Review link
  when attention is needed. Keep defaults aligned with [usage](docs/usage.md).
- Treat feature enablement, widget visibility, and live operation as separate
  choices. Route actions through existing host/owner callbacks.

## Before handing back

Check light/dark appearance, minimum window width, scrolling, keyboard access,
accessible labels, and Reduce Motion for animations. Exercise the actual link or
button path, including reopening an existing window. Show empty, unavailable, and
failure states. Use isolated UI fixtures and relevant regression tests; record live
checks separately from fixture evidence. See [development](docs/development.md) for
commands and [module guide](docs/modules.md#find-the-ui-first) for UI ownership.
