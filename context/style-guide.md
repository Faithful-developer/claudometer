# Claudometer Style Guide

Source of truth for colours: `docs/palette.html`. Tokens are in `Sources/ClaudometerCore/UI/Palette.swift`. No hex values anywhere else.

## Colour tokens (light / dark)

| Role | Token | Light | Dark | Use |
|---|---|---|---|---|
| Brand / normal usage | `Palette.coral` | #E76F51 | #D76549 | Meter and ring fill below the warning threshold, brand mark |
| Meter gradient start | `Palette.coralLight` | #F29A72 | #E88A68 | Light (zero) end of the normal meter gradient; the value end is full coral |
| Brand tint | `Palette.coralSoft` | #FCEAE5 | #3B2520 | Selected account segment, soft fills |
| Row hover | `Palette.rowHover` | #F7DCD3 | #4D2D24 | Hovered menu and limit rows on the canvas (1.20 / 1.37:1 vs canvas); text on it is primary or secondary, never tertiary. The hero ring's track steps up to `trackIncreased` and the pace-tick halo takes this colour |
| Row pressed | `Palette.rowPressed` | #F4CFC3 | #5A3329 | Pressed menu and limit rows |
| Track hover | `Palette.trackHover` | #F2D2C7 | #5A3A31 | Hover on controls that sit on `track`: account segments, notice buttons (1.22 / 1.24:1 vs track); labels go primary |
| Track pressed | `Palette.trackPressed` | #EFCBBF | #5E3D34 | Pressed account segments and notice buttons |
| Stale fill | `Palette.staleFill` | = `Ink.secondary` | = `Ink.secondary` | Every fill for last known data: rings, meters, daily bars, breakdown (5.87 / 5.68:1 vs track). Stale status glyphs are `Ink.secondary` too |
| Series 2 | `Palette.plum` | #51405F | #7D539D | Chats |
| Series 3 / success | `Palette.teal` | #278C82 | #00A99C | Cowork, "On track" pill |
| Warning | `Palette.warning` | #D59A32 | #E2A848 | ≥ warning threshold (default 60%) |
| Critical | `Palette.critical` | #C95656 | #E06A6A | ≥ critical threshold (default 85%) |
| Info | `Palette.info` | #5577C8 | #7393DF | "Ahead of pace" pill |
| Soft tints | `*Soft` | palette tints | dark steps | Status pill backgrounds |
| Canvas | `Palette.canvas` | #F7F6F3 | #1E1D23 | Popover wash over the menu material |
| Surface | `Palette.surface` | #FFFFFF | #26252C | Widget cards |
| Border | `Palette.border` | #E8E6E2 | #36353C | Outline of small buttons and the selected account segment |
| Track | `Palette.track` | #F0EEEB | #34333A | Unfilled linear meter track |
| Ring track | `Palette.ringTrack` | #D9D6D0 | #55545C | Unfilled ring track (the only thing drawing the circle, so stronger). Accented/vibrant widgets use `Ink.trackVibrant` |
| Text | `Ink.primary/secondary/tertiary` | #20202B / #5A5A66 / #6E6E79 | #F1EFEA / #AEAEB8 / #8D8D97 | All text (every step ≥4.5:1 on canvas and surface) |
| Warning glyph | `Palette.warningGlyph` | #A87412 | #E2A848 | Warning symbols and icons (the #D59A32 fill is too light for glyphs) |

Rules:
- Text uses `Ink` only. It never uses series or status colours. Status meaning comes from a symbol next to the text.
- Surface colours stay with their surface, never their rank: Claude Code = coral, Chats = plum, Cowork = teal, unknown = grey.
- Status (amber, red) only appears above the thresholds and always comes with an SF Symbol and a label.
- The menu bar icon is a monochrome template image unless the level is warning or critical.

## Liquid Glass (macOS 26 and later)
Source: `agents/apple-design-skill-main/references/hig/liquid-glass.md`. Older macOS keeps everything above.
- Glass is only for the functional layer. The menu window keeps the system's own material: no `MenuBackground` wash on top. The notice buttons are `.buttonStyle(.glass)` and the account switcher is the system segmented control. Rings, meters, charts, rows and pills never get glass.
- `isOnGlass` (environment) marks system surfaces: the menu, Settings, and the macOS 26 widget, which uses the system background (`WidgetBackground`). There the `Ink` text steps resolve to `labelColor` / `secondaryLabelColor`; tertiary also takes secondary, since the system tertiary is under 4.5:1. Vibrant widgets (the desktop behind windows) resolve the same way.
- Fills on glass come from `GlassFill`: neutral, see-through (`Color.primary` at low opacity) so they adapt to whatever is behind. Hover 9%, pressed 15%, inset boxes 6%, meter track 10% (22% Increase Contrast), ring track 16% (24% on a hovered row). The warm `rowHover` / `trackHover` tints stay for the opaque menu only.
- Brand coral, status colours and series colours stay on data and status, never on controls (HIG Liquid Glass › Color on glass).
- The pace tick's halo is a cut-out on glass (`.destinationOut`), since there's no single background colour to match.
- Vibrant widgets: meter and ring fills are `Color.primary` on `Ink.trackVibrant`, so the value is the brightest mark.
- `ImageRenderer` can't draw the material or the native glass controls. `popover-glass-*` renders show the glass colours over the window colour, with the drawn controls in place of the native ones. Check the real look in the running app.

## Typography (SF Pro, system font)
- Popover title 13 bold. Row titles 13 regular. Values 13 medium monospaced digits. Captions 11–12. Section headers 11 semibold, secondary, Title Case.
- Percent figures use SF Rounded semibold, with the "%" at 55% size in secondary ink.

## Shape & spacing
- Popover width 300. Horizontal padding 14. Section vertical padding 8. Dividers are inset by 14.
- Stale rings fill with `Ink.secondary`; non-zero values draw at least one stroke width of arc.
- Meters are 6pt capsules (widgets 5pt) with a 2pt pace tick in secondary ink, outlined by a 1pt halo of the background colour (a cut-out on glass). Rings use a 7–10pt round-cap stroke.
- Menu-style rows are 24pt tall, with a 6pt continuous corner radius on hover.
- Status pills: capsule, 8×3 padding, 11pt semibold.
- Account switcher (2+ accounts): a 24pt track (`Palette.track`, 8pt radius, 2pt inset) of equal segments, 12pt text; the selected one is `Palette.surface` with a `Palette.border` outline and semibold text and keeps its full name first.
