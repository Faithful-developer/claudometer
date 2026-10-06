# Claudometer

macOS menu bar app + WidgetKit widget showing Claude plan usage limits. Spec: `TZ.md`. Build: `scripts/build-app.sh`; tests: `scripts/test.sh` (not plain `swift test`, see the script).

## Visual Development

### Design Principles
- Design checklist: `context/design-principles.md`
- Style guide and colour tokens: `context/style-guide.md` (source palette: `docs/palette.html`)
- Refer to both for any UI change. Colours come only from `Palette` / `Ink` in `Sources/ClaudometerCore/UI/Palette.swift`.
- Command Line Tools only: no SwiftUI `@State` or `@Entry` macros (use `@StateObject` / `EnvironmentKey`).

### Quick Visual Check
Immediately after any UI change:
1. Identify the changed views (popover, menu bar icon, widgets, settings).
2. Render them: `B=$(swift build --show-bin-path)/Claudometer; $B --render-previews review/renders [--sample high|stale|signedout]`
3. Read the PNGs and compare them against the two context docs.
4. Check light and dark, and every affected state.

### Comprehensive Design Review
Use the `design-review` agent (`.claude/agents/design-review.md`) or `/design-review` when finishing significant UI work.
