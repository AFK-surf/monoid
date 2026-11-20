# ui.monoid — Liquid Glass

Liquid glass controls for [mbui](../mbui), the MoonBit UI framework that draws the same window on macOS, Windows,
Linux, iOS, Android and the web. Each part is a 1:1 port of the component catalog of
[Kyant0/AndroidLiquidGlass](https://github.com/Kyant0/AndroidLiquidGlass) (Apache-2.0): the same colours, sizes,
springs, lens depths and highlights, drawn by mbui's own glass instead of Jetpack Compose.

What a control is to the hand, the keyboard and a screen reader comes from mbui's headless components, so every part
takes a tap, a drag, Tab and the arrow keys, and is read out by its role and name.

Gallery: [ui.monoid.build/liquid-glass](https://ui.monoid.build/liquid-glass/)

## The parts

All of them are in `src/lg` (`@lg`):

| Part | What it is |
| --- | --- |
| `liquid_button_node` | A capsule of glass 48 high, clear, with a surface colour or tinted; lit and stretched by a finger on it. A button. |
| `liquid_toggle_node` | A switch whose thumb turns to glass while held and can be dragged across. |
| `liquid_slider_node` | A track and a glass thumb, moved by a drag, a tap on the track or the arrow keys. |
| `liquid_bottom_tabs_node` | A bar of tabs with a lens over the chosen one; drag the lens to choose. A tab list. |
| `liquid_control_tile_node`, `liquid_control_item_node`, `liquid_card_node` | The control center's glass tiles, cards and switches. |
| `liquid_dialog_node` | A modal dialog of glass over a dimmed page, with Cancel and an action. |
| `liquid_merge_node`, `LiquidMerge` | Two liquid glass bodies with capillary bridge hysteresis: zero attraction before contact, smooth liquid bridge while pulling, crisp snap-off and auto-separation past `break_gap`. |
| `liquid_progressive_blur_node`, `liquid_adaptive_surface_node`, `liquid_magnifier_node` | A blur that fades out, glass that follows how light the page under it is, and a lens over text. |
| `DampedDrag`, `InteractiveHighlight` | The springs behind the parts (the catalog's DampedDragAnimation and InteractiveHighlight), for a caller that holds or drives them itself. |

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
