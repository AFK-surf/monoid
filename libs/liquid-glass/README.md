# ui.monoid — Liquid Glass

Liquid glass controls for [mbui](../mbui), the MoonBit UI framework that draws the same window on macOS, Windows,
Linux, iOS, Android and the web. Its foundational optical controls and damped springs originate from the component
catalog of [Kyant0/AndroidLiquidGlass](https://github.com/Kyant0/AndroidLiquidGlass) (Apache-2.0), expanded into a
complete 35-component library built on `mbui`'s `@headless` primitives and the iOS 27 `@paint.Glass::liquid` optical
model.

What a control is to the hand, the keyboard and a screen reader comes from mbui's headless components, so every part
takes a tap, a drag, Tab and the arrow keys, and is read out by its role and name.

Gallery: [ui.monoid.build/liquid-glass](https://ui.monoid.build/liquid-glass/) · Design Specification: [DESIGN.md](DESIGN.md)

## The 35 parts

All of them live in `src/lg` (`@lg`) and are showcased live in the self-hosted `library` app (`src/pages/library.mbt`, default entry), following the strict two-layer material architecture in [DESIGN.md](DESIGN.md) (Floating Liquid Glass Layer vs. Content Layer, zero glass-on-glass):

### Controls
| Part | What it is |
| --- | --- |
| `liquid_button_node` | A capsule of glass 48 high (or `flat=true` for inside glass overlays), clear, with a surface colour or tinted; lit and stretched by a finger on it. |
| `liquid_icon_button_node` | Circular glass icon action (`Small` 36 / `Regular` 44 / `Large` 52 pt) with active tint and touch spotlight. |
| `liquid_button_group_node` | Unified floating glass capsule holding multiple icon actions with concentric inner pills and hairline dividers. |
| `liquid_segmented_node` | Draggable refractive glass lens sliding over equal-width segments with closed-form jelly squeeze. |
| `liquid_toggle_node` | A switch whose thumb turns to glass while held and can be dragged across. |
| `liquid_slider_node` | A track and a glass thumb, moved by a drag, a tap on the track or the arrow keys. |
| `liquid_stepper_node` | Compact decrement/increment glass capsule with live formatted numeric readout. |

### Inputs & Selection
| Part | What it is |
| --- | --- |
| `liquid_text_field_node` | Capsule glass text field over `@headless.TextField` with lead icon, clear button, label, and error state. |
| `liquid_search_bar_node` | Floating glass search capsule with vector magnifier, live `edited` callback, and `show`-gated clear button. |
| `liquid_search_morph_node` | iOS 26 search orb (`48pt`) morphing into a full-width liquid glass search bar with a capillary-budded circular `×` cancel orb (`@motion.LiquidBond` hysteresis). |
| `liquid_checkbox_node` | Content-layer checkbox (checked / unchecked / mixed) with vector checkmark/dash and first-line label alignment (safe inside glass overlays). |
| `liquid_radio_group_node` | Content-layer vertical or horizontal radio group over `@headless.radio_group` (safe inside glass overlays). |
| `liquid_chip_node` | Toggleable filter/selection glass chip with optional leading icon and removable `×` button. |
| `liquid_badge_node` | Content-layer semantic status pill (`Neutral`, `Accent`, `Success`, `Warning`, `Danger`) with optional live indicator dot. |
| `liquid_count_badge_node` | Content-layer numeric counter capsule with `99+` overflow clamping and automatic hide at `0`. |

### Navigation & Containers
| Part | What it is |
| --- | --- |
| `liquid_nav_bar_node` | iOS 26/27 floating-island navigation bar (transparent chrome hosting floating glass islands in `leading`/`trailing`, or optional `glass=true` when child-glass-free) with centered title/subtitle. |
| `liquid_toolbar_node` | Floating capsule toolbar container (`r = height / 2`) for quick actions. |
| `liquid_bottom_tabs_node`, `liquid_bottom_tab_node` | A bar of tabs with a draggable refractive lens over the chosen tab. |
| `liquid_collapsible_tabs_node` | iOS 26 `TabBarMinimizeBehavior` floating glass tab bar that smoothly collapses into a compact active-tab glass orb beside a detached circular Search/Action orb. |
| `liquid_list_node`, `LiquidListRow` | Single-layer Liquid Glass grouped inset list (`r=24pt`, optional `dividers=false` sidebar mode) with flat inner rows, `active` highlight, and hover-avoiding hairlines. |
| `liquid_disclosure_node` | Single-layer Liquid Glass collapsible disclosure card (`r=22pt`) with closed-form animated chevron and smooth slide/fade body. |
| `liquid_card_node`, `liquid_control_tile_node`, `liquid_control_item_node` | Control center glass tiles, cards and switches. |

### Overlays & Feedback
| Part | What it is |
| --- | --- |
| `liquid_menu_node`, `LiquidMenuEntry` | Anchored refractive dropdown menu supporting action items, check items, shortcuts, icons, and cleaned separators. |
| `liquid_select_node`, `LiquidSelectOption` | Capsule select trigger with floating refractive option menu and detail subtitles. |
| `liquid_popover_node` | Anchored floating refractive popover panel positioned via `@headless.Placement`. |
| `liquid_tooltip_node` | Hover/focus glass tooltip capsule that never blocks pointer clicks. |
| `liquid_drawer_node`, `DrawerSide` | Floating island side drawer (`Leading`/`Trailing`, 10pt margin, `r=28pt`) with horizontal drag-to-dismiss, rubber-band over-pull, and velocity-continuous spring settle. |
| `liquid_sheet_node` | Detached floating modal glass sheet (`r=36pt`) with interactive vertical drag-to-dismiss and optional `detents=true` morphing to a full-height docked reading surface. |
| `liquid_action_sheet_node`, `LiquidActionSheetItem` | Separated iOS-style action group with independent Cancel glass capsule. |
| `liquid_dialog_node` | Modal refractive glass dialog over a dimmed page, with Cancel and primary action. |
| `liquid_toast_node`, `LiquidStatus` | Floating status capsule (`Info`, `Success`, `Warning`, `Error`) with optional action pill and dismiss button. |
| `liquid_progress_bar_node`, `liquid_progress_ring_node` | Determinate (`Some(0..1)`) and closed-form indeterminate (`None`) linear and circular progress indicators. |

### Optics & Physics
| Part | What it is |
| --- | --- |
| `liquid_merge_node`, `LiquidMerge` | Two liquid glass bodies with 360° 2D capillary bridge hysteresis: zero attraction before contact, smooth liquid bridge while pulling, crisp snap-off and auto-separation past `break_gap`. |
| `liquid_progressive_blur_node` | Smoothstep progressive blur overlay fading cleanly over scrolling or dense text. |
| `liquid_adaptive_surface_node`, `adaptive_glass` | Luminance-aware glass that continuously adapts to the brightness of the backdrop underneath. |
| `liquid_magnifier_node` | Draggable 1.5× glyph-snapped optical loupe over text and source code. |
| `DampedDrag`, `InteractiveHighlight` | Closed-form spring controllers (`DampedDragAnimation` and `InteractiveHighlight`) for caller-driven motion. |

`set_dark` chooses the light or dark look, `colors()` gives the catalog's colours in it, and `ui_theme` is mbui's
theme in the catalog's look.

## Use it

Put the library and mbui in your module's workspace and import it.

`moon.work`:

```
members = [
  ".",
  "path/to/libs/liquid-glass",
  "path/to/libs/mbui",
]
```

`moon.mod`:

```
import {
  "mbui@0.1.0",
  "liquid-glass@0.1.0",
}
```

Your package's `moon.pkg` imports `mbui/ui`, `mbui/signals` and `liquid-glass/lg`. Then:

```moonbit
fn main {
  @lg.set_dark(Some(false))
  let wifi = @signals.signal(true)
  @ui.run_tree("Liquid Glass", fn(root) {
    @ui.set_tree_theme(@lg.ui_theme)
    root.box(fn(page) {
      page.grow(Is(1.0)).gap(Is(24.0)).padding(Is((40.0, 40.0, 40.0, 40.0))) |> ignore
      @lg.liquid_button_node(page, fn() { "Send" }, fn() { println("sent") }, tint=0x0088FFFFL) |> ignore
      @lg.liquid_toggle_node(page, fn() { wifi.get() }, fn(v) { wifi.set(v) }, fn() { "Wi-Fi" }) |> ignore
    })
    |> ignore
  })
}
```

Glass bends and blurs what is drawn under it, so the parts look their best over a picture or colour, as the gallery's
wallpaper (`src/pages`) shows.

## Run the gallery

The gallery (`src/gallery`) shows every part over a wallpaper, under a bar that chooses the page (Overview,
Interactive, Dialog) and the look (Light, Dark). As it starts it reads:

- `MBUI_LG_PAGE`: `overview` (the default), `interactive` (every part held, as a finger holds it), `dialog`, or `film`
- `MBUI_DARK=1`: the dark look
- `MBUI_LG_CHROME=0`: no bar, for showing one page inside another

From the repository's root:

```sh
# macOS, in a window
APP=gallery MBUI_APP_MOD=libs/liquid-glass libs/mbui/scripts/mac.sh run

# the web: index.html, host.js and app.js in out/web (serve the folder over http)
sh libs/liquid-glass/scripts/web.sh out/web
```

On the web the same settings are the page's query: `index.html?MBUI_LG_PAGE=interactive&MBUI_DARK=1`. Without
`MBUI_DARK`, the page follows the system's light or dark.

## Draw it offscreen

`src/shots` draws each page, light and dark, at 3 pixels a point, and a 60 fps film of the parts held and dragged,
with no window:

```sh
cd libs/liquid-glass
moon build --target native --release src/shots
MBUI_LG_SHOTS=/tmp/lg _build/native/release/build/liquid-glass/shots/shots.exe   # MBUI_LG_ONLY=overview for one
```

## Check it

```sh
sh libs/liquid-glass/scripts/check.sh
```

It runs the determinism lint, type-checks every package on native and JavaScript, and runs the library's tests. The
tests hold each part to mbui's audit (contrast, names, press targets) and check that a drag draws the same at 60,
120, 24 and 7 frames a second.

## Licence

Apache License 2.0 ([LICENSE](LICENSE)). It is a port of AndroidLiquidGlass, copyright 2025 Kyant; see
[NOTICE](NOTICE).
