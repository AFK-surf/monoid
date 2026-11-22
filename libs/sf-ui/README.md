# `stillfail/sf` (`ui.monoid`)

`stillfail/sf` is the default MoonBit component library for **ui.monoid** (`ui.monoid.build`), built directly on [`mbui`](../mbui) (`libs/mbui`). It ships the design tokens, themes, motion presets, and production-tested node components used by the cross-platform app (`apps/mbui`) across macOS, Windows, Linux, iOS, Android, and Web.

---

## Architecture (Three-Layer Design)

`stillfail/sf` strictly imports only `mbui/*` and `moonbitlang/core/*` (enforced by `detlint`'s `library-import` rule), with zero dependency on any application business logic:

1. **Layer 1 — Rendering & Signals (`mbui/ui`, `mbui/view`, `mbui/signals`, `mbui/motion`)**: Retains the persistent scene tree, layout engine, GPU renderer, and reactive signals.
2. **Layer 2 — Headless Interaction Primitives (`mbui/headless`)**: Owns accessible roles, keyboard navigation, focus management, press/hold/drag states, menus, comboboxes, dialogs, sliders, split panes, tables, and toasters.
3. **Layer 3 — Styled Design System (`stillfail/sf` / `ui.monoid`)**: Adds visual tokens, light/dark/high-contrast palettes, typography, motion presets (`src/motion.mbt`), icons, and ready-to-use styled node components (`*_node.mbt`).

---

## Design Tokens & Themes

- **Palette & Themes** (`src/theme.mbt`, `src/palette_data.mbt`, `src/tokens.mbt`):
  - Supports **Light** (`web_light`), **Dark** (`web_dark`), and **High-Contrast** variants via reactive theme signals.
  - Semantic color tokens (`bg`, `canvas`, `surface`, `raised`, `text`, `muted`, `subtle`, `line`, `border`, `accent`, `accent_text`, `danger`, `warn`, `ok`, etc.).
- **Typography, Spacing & Radii** (`src/tokens.mbt`, `src/control_edge.mbt`):
  - Consistent type scale (`t.ui`, `t.body`, `t.meta`, `t.code`, etc.), concentric corner radii, and unified hairline control borders (`B0_5` / `control_edge_w`: `Line` at rest, `Border` on hover/focus, `B2` in `Fg` for selected rings).
- **Motion System** (`src/motion.mbt`):
  - Nine canonical motion kinds with calibrated springs/tweens, driven purely by causal frames (no layout-diff animations or time-window polling).

---

## Component Overview

| Category | Representative Node Components |
| --- | --- |
| **Buttons & Actions** | `button_node`, `icon_button_node`, `button_while_node`, `hold_button_node`, `copy_button_node`, `seg_node`, `filter_pill_node` |
| **Inputs & Forms** | `input_node`, `textarea_node`, `search_input_node`, `secret_field_node`, `select_node`, `combo_node`, `offers_node`, `pick_node`, `switch_node`, `slider_node`, `radio_node`, `choices_node`, `form_swatch_node` |
| **Layout & Navigation** | `page_node`, `page_wide_node`, `panel_nodes`, `row_box_node` (compound `RowScope` slots), `link_row_node`, `settings_rows_node`, `tab_bar_node`, `nav_bar`, `address_bar_node`, `way_node`, `split` |
| **Overlays & Feedback** | `menu_node`, `submenu`, `popover_node`, `sheet_node`, `sheet_shows_node`, `confirm_node`, `ask_node`, `presenters`, `toast_node`, `toaster_node`, `tip_node`, `progress_node`, `spinner_node`, `waiting_node` |
| **Content & Media** | `markdown`, `table_node`, `code_display_node`, `math` (MathJax TeX outlines), `reader_node`, `reader_layout_node`, `player_node`, `viewer_frame`, `viewer_bar_node`, `viewer_head_node`, `avatar_node`, `icon_node` |

> For the ongoing standalone extraction roadmap (separating still.fail domain widgets, remaining `@kit` legacy wrappers, asset generation scripts, and storybook), see [`docs/STANDALONE_AUDIT.md`](docs/STANDALONE_AUDIT.md).

---

## Built-in Bilingual Copy (zh / en) & Custom `set_words`

`stillfail/sf` ships with built-in Chinese and English fallback strings (`src/default_words.mbt`) for every key referenced by library components, so external MoonBit apps work out of the box without supplying a catalog:

```moonbit
// Switch built-in language at runtime ("zh" or "en", or None to follow MBUI_LOCALE):
@sf.set_language(Some("en"))
let label = @sf.t("common.cancel") // "Cancel"

// Variable interpolation & English singular `.one` support:
@sf.t("web-main.file.remove", args=[("name", "notes.md")]) // "Remove notes.md"
@sf.t("web-pages.drive.reader.foundCount", args=[("n", "1")]) // "1 found"
```

Host applications with their own i18n catalog can override all lookups once at startup via `@sf.set_words(...)`, optionally delegating unknown keys back to `@sf.default_words`:

```moonbit
@sf.set_words(fn(key, args) {
  match my_app_catalog(key, args) {
    Some(text) => text
    None => @sf.default_words(key, args)
  }
})
```

---

## Standalone Verification

Run the full library check (determinism lint via `detlint.json`, native & JS type-checking, and native unit tests):

```bash
cd libs/sf-ui && sh scripts/check.sh
```

---

## License & Third-Party Notices

Licensed under the [MIT License](LICENSE). Embedded third-party assets (JetBrains Mono under SIL OFL 1.1, MathJax TeX 4.1.3 outlines under Apache 2.0, and brand vector assets) are documented in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
