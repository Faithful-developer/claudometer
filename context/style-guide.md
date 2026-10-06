# Claudometer Style Guide

Source of truth for colours: `docs/palette.html`. Tokens are in `Sources/ClaudometerCore/UI/Palette.swift`. No hex values anywhere else.

## Colour tokens (light / dark)

| Role | Token | Light | Dark | Use |
|---|---|---|---|---|
| Brand / normal usage | `Palette.coral` | #E76F51 | #D76549 | Meter and ring fill below the warning threshold, brand mark |
| Meter gradient start | `Palette.coralLight` | #F29A72 | #E88A68 | Light (zero) end of the normal meter gradient; the value end is full coral |
| Brand tint | `Palette.coralSoft` | #FCEAE5 | #3B2520 | Hover / selected menu rows |
| Series 2 | `Palette.plum` | #51405F | #7D539D | Chats |
| Series 3 / success | `Palette.teal` | #278C82 | #00A99C | Cowork, "On track" pill |
| Warning | `Palette.warning` | #D59A32 | #E2A848 | ≥ warning threshold (default 60%) |
| Critical | `Palette.critical` | #C95656 | #E06A6A | ≥ critical threshold (default 85%) |
| Info | `Palette.info` | #5577C8 | #7393DF | "Ahead of pace" pill |
| Soft tints | `*Soft` | palette tints | dark steps | Status pill backgrounds |
| Canvas | `Palette.canvas` | #F7F6F3 | #1E1D23 | Popover wash over the menu material |
| Surface | `Palette.surface` | #FFFFFF | #26252C | Widget cards |
| Track | `Palette.track` | #F0EEEB | #34333A | Unfilled linear meter track |
| Ring track | `Palette.ringTrack` | #D9D6D0 | #55545C | Unfilled ring track (the only thing drawing the circle, so stronger). Accented/vibrant widgets use `Ink.trackVibrant` |
| Text | `Ink.primary/secondary/tertiary` | #20202B / #5A5A66 / #6E6E79 | #F1EFEA / #AEAEB8 / #8D8D97 | All text (every step ≥4.5:1 on canvas and surface) |
| Warning glyph | `Palette.warningGlyph` | #A87412 | #E2A848 | Warning symbols and icons (the #D59A32 fill is too light for glyphs) |

Rules:
- Text uses `Ink` only. It never uses series or status colours. Status meaning comes from a symbol next to the text.
- Surface colours stay with their surface, never their rank: Claude Code = coral, Chats = plum, Cowork = teal, unknown = grey.
- Status (amber, red) only appears above the thresholds and always comes with an SF Symbol and a label.
- The menu bar icon is a monochrome template image unless the level is warning or critical.

## Typography (SF Pro, system font)
- Popover title 13 bold. Row titles 13 regular. Values 13 medium monospaced digits. Captions 11–12. Section headers 11 semibold, secondary, Title Case.
- Percent figures use SF Rounded semibold, with the "%" at 55% size in secondary ink.

## Shape & spacing
- Popover width 300. Horizontal padding 14. Section vertical padding 8. Dividers are inset by 14.
- Stale rings fill with `Ink.secondary`; non-zero values draw at least one stroke width of arc.
- Meters are 6pt capsules (widgets 5pt) with a 2pt pace tick in secondary ink, outlined by a 1pt halo of the background colour. Rings use a 7–10pt round-cap stroke.
- Menu-style rows are 24pt tall, with a 6pt continuous corner radius on hover.
- Status pills: capsule, 8×3 padding, 11pt semibold.
