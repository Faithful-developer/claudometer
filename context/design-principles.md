# Claudometer Design Principles (macOS menu bar app + widgets)

Adapted from the S-tier dashboard checklist (`agents/claude-code-workflows-main/design-review/design-principles-example.md`) for a native macOS utility.

## 1. Native first (Apple HIG)
- [ ] The app looks like a system menu bar extra (Battery, Wi‑Fi, Control Center): menu material, SF Pro, SF Symbols, menu-style action rows with shortcuts.
- [ ] Controls behave natively: hover highlight, disabled state, keyboard shortcuts (⌘R, ⌘,, ⌘Q).
- [ ] Settings use toolbar tabs with grouped forms.
- [ ] Widgets follow WidgetKit conventions: glanceable, no interactive clutter, readable at a distance.

## 2. Glanceability & hierarchy
- [ ] One hero figure per view (the menu bar metric). Everything else is secondary.
- [ ] Text order holds in both modes: title > value > caption > hint. Secondary text must never look darker than primary.
- [ ] Each number answers a question: how much is used, when it resets, and whether I'm on pace.

## 3. Colour & data
- [ ] Only palette tokens are used (`context/style-guide.md`).
- [ ] Status colour appears only when there is something to say, always with a symbol and a label.
- [ ] Usage by surface: one stacked bar plus a legend with values. Colour is never the only way to identify a surface.
- [ ] Light and dark are both selected palettes with comparable contrast (no automatic flip).

## 4. States (robustness)
- [ ] Normal, warning, critical, stale/offline and signed-out states each render clearly and say what to do next.
- [ ] Stale data is visibly marked (dimmed, plus a notice) and never passed off as live.
- [ ] Long names, 0%, 100%+, a missing reset time and unknown limit kinds don't break the layout.

## 5. Accessibility
- [ ] WCAG AA contrast for text (4.5:1 body, 3:1 large or UI). Meter fills have at least 3:1 against the track, or a text value next to them.
- [ ] VoiceOver: every meter or ring has a combined label (title, percent, reset).
- [ ] Respects Reduce Motion, Increase Contrast and the system appearance (plus the in-app override).

## 6. Craft
- [ ] Spacing follows a 4pt grid, with consistent insets between sections.
- [ ] Alignment: left edges line up and values are right-aligned with monospaced digits.
- [ ] Copy is short, sentence case for text and Title Case for headers. No jargon.
