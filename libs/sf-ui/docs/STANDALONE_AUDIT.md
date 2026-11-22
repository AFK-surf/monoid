# `libs/sf-ui` Standalone Release Audit (`ui.monoid`)

> Audit baseline: `origin/main` @ `76e78a1a10` (`libs/sf-ui/src`: 252 non-test `.mbt` files).
> Every file path, line number, and reference count below is verified directly against the repository source.

---

## 1. Business-Specific Component Inventory

`libs/sf-ui/AGENTS.md` states: *"Only general parts and design atoms go in `src`: a part bound to one kind of the app's things (a station, an agent, a vault item, a login's step) is the app's, made in `apps/mbui` from these parts."*

The table below classifies all domain-coupled files currently living in `libs/sf-ui/src/` into:
- **Move to `apps/mbui`**: bound to still.fail domain models (stations, workspaces, logins, quotas, chat composer, brand drawables).
- **Generalize & Keep in `ui.monoid`**: underlying UI patterns are generic and reusable once still.fail-specific names/copy are generalized.

### 1A. Should Move Back to `apps/mbui`

| File (`libs/sf-ui/src/`) | Lines | `apps/mbui` Refs (prod / test / files) | Key Public Symbols & Primary Coupling |
| --- | ---: | :---: | --- |
| `station_choice_node.mbt` | 101 | 8 / 0 / 4 | `StationChoice` (`:9`), `station_choice_node` (`:24`) — station picker card |
| `station_net_node.mbt` | 494 | 30 / 1 / 5 | `NetLook` (`:15`), `station_net_line_node` (`:62`), `summary_mark_card_node` (`:276`), `summary_mark_side` (`:362`) — station RTT / latency readout (`android-settings.stations.rtt`, `web-pages.stations.latency`) |
| `workspace_row_node.mbt` | 327 | 31 / 0 / 5 | `workspace_label_node` (`:11`), `workspace_row_node` (`:27`), `workspace_mark_node` (`:103`), `workspace_card_node` (`:124`), `invitation_line_node` (`:144`), `provider_mark_node` (`:202`), `provider_badge_node` (`:216`) — workspace switcher & invite actions |
| `login_step_card_node.mbt` | 828 | 137 / 0 / 5 | `LoginSaid` (`:18`), `LoginStep` (`:30`), `login_step_card_node` (`:64`), `login_ended_node` (`:125`), `login_paste_node` (`:270`), `login_card` (`:395`) — CLI/OAuth login step card & code paste flow |
| `composer_notice_node.mbt` | 229 | 7 / 0 / 2 | `composer_notice_node` (`:37`) — chat composer inline notice banner |
| `composer_waiting_node.mbt` | 122 | 1 / 0 / 1 | `file_waiting_node` (`:22`) — composer pending attachment / paste retry pill |
| `app_icon.mbt` | 195 | 25 / 0 / 3 | `AppAvatar` (`:12`), `app_makers` (`:24`), `avatars_base` (`:45`), `app_buddies_ask` (`:60`), `app_avatar_icon` (`:134`), `app_own_icon` (`:167`) — still.fail agent buddy & maker avatar mapping |
| `sync_key_node.mbt` | 187 | 3 / 0 / 3 | `sync_key_node` (`:13`) — still.fail sync key / recovery code display |
| `quota_chip.mbt` | 624 | 12 / 0 / 8 | `has_quota` (`:7`), `quota_chips` (`:33`), `quota_mark` (`:396`), `quota_figure` (`:412`), `meter_chip` (`:500`), `meter_line` (`:562`) — legacy `Ctx` AI provider quota chips |
| `quota_lines_node.mbt` | 84 | 2 / 0 / 2 | `quota_lines_node` (`:14`) — provider quota detail lines |
| `quota_node.mbt` | 828 | 21 / 0 / 14 | `fill_chip_node` (`:11`), `quota_chips_node` (`:156`), `dials_node` (`:208`), `meter_chips_node` (`:392`), `quota_worded_node` (`:447`), `nav_quota_room_node` (`:650`), `nav_quota_chips_node` (`:696`) — AI quota meters & nav chips (`fill_chip_node` / `dials_node` can be extracted as generic meter atoms before moving the quota layer) |
| `drawable_data.mbt` | 3302 | 0 direct (`@sf`) — internal to `marks_node.mbt`, `picture.mbt`, `way_in_node.mbt` | 71 vectors: 33 `maker_*`, 19 `tool_*`, 4 IM logos (`slack`, `feishu`, `comma`, `group`), 15 still.fail marks/illustrations/launcher icons. Contains third-party trademarks — must move to `apps/mbui` or an app-supplied drawable registry |
| `peek_cards_node.mbt` | 1118 | 71 / 0 / 5 | `PeekFact` (`:16`), `peek_page_tile_node` (`:29`), `peek_change_node` (`:112`), `peek_state_pill_node` (`:223`), `peek_copy_node` (`:280`), `peek_file_head_node` (`:406`), `peek_file_entries_node` (`:515`) — GitHub PR/Issue & Drive peek preview cards |

### 1B. Generalizable — Rename & Keep in `ui.monoid`

| File (`libs/sf-ui/src/`) | Lines | `apps/mbui` Refs (prod / test / files) | Generalization Path |
| --- | ---: | :---: | --- |
| `agent_stats_node.mbt` | 254 | 51 / 0 / 2 | Exports are already generic (`quiet_card_node` `:59`, `quiet_row_node` `:85`, `quiet_first_line` `:108`, `row_label_node` `:121`, `quiet_row_tile` `:42`, `quiet_row_dot` `:47`); only the filename is domain-named. Rename to `quiet_card_node.mbt`. |
| `chat_list.mbt` | 605 | 97 / 13 / 15 | Provides generic sidebar list geometry & slot helpers (`ListAt` `:287`, `band_pad_in` `:250`, `side_row_at` `:261`, `list_line` `:299`, `list_foot_in` `:319`, `list_row_slot` `:346`) alongside `ChatList` (`:9`). Split `ChatList` out to `apps/mbui` and rename the generic list primitives to `side_list.mbt`. |
| `chat_notice_pill_node.mbt` | 521 | 33 / 0 / 7 | Contains generic feedback & swatch atoms (`labeled_rule_node` `:15`, `list_coming_node` `:43`, `list_failed_node` `:54`, `list_none_node` `:64`, `empty_words_node` `:98`, `words_button_node` `:121`, `notice_pill_node` `:146`, `color_swatch_node` `:363`, `color_swatches_node` `:384`). Rename to `notice_pill_node.mbt` and split swatch helpers into `form_swatch_node.mbt`. |
| `quote_card_node.mbt` | 212 | 5 / 0 / 3 | `quote_card_node` (`:14`) is a generic quoted-content card; `composer_quote_card_node` (`:161`) is composer-specific (can move to `apps/mbui` or stay as a removable-quote variant). |
| `ask.mbt`, `ask_card_node.mbt`, `ask_line_node.mbt` | 98 / 110 / 147 | 59+34+7 / 3 / 12+10+2 | Decision / confirmation card layouts (`ask_card_node`, `ask_words_node`, `ask_buttons_node`, `foot_chooser_node`). Generic once `ask_history_trigger` (`web-main.history.details`) label becomes an explicit parameter. |

---

## 2. Remaining `@kit` (Legacy `Ctx`) Reference Cleanup Plan

Only **6 non-test files** (50 code lines total) and **2 whitebox test files** (`lift_wbtest.mbt`: 7 lines, `seg_fill_node_wbtest.mbt`: 1 line) in `libs/sf-ui/src/` still call `@kit.*`. Eliminating these 6 files removes `"mbui/kit"` from `libs/sf-ui/src/moon.pkg`.

| File (`libs/sf-ui/src/`) | `@kit.` Lines | `@kit` APIs Used | `apps/mbui` Callers of File's Legacy Symbols | Replacement / Removal Path |
| --- | --- | --- | --- | --- |
| `lift.mbt` | L66, L81 (2) | `@kit.sheet_place`, `@kit.sheet_top` | `@sf.lift_held` (1 ref: `sfpages/chat_row_node.mbt`), `@sf.lift_of` (4 refs in 3 files: `sfpages/chat_row.mbt`, `chat_row_node.mbt`, `message_files.mbt`), `@sf.lift_over` (8 refs in 4 files) | Read sheet geometry from `sheet_node.mbt` (node tree state) instead of `@kit.sheet_place`/`sheet_top`, then drop legacy `Ctx` `lift` path once `chat_row.mbt` finishes migrating to `chat_row_node.mbt`. |
| `parts.mbt` | L602, L609, L655, L764, L773, L774, L954, L964, L1012, L1134, L1138, L1316, L1324, L1331, L1334, L1338, L1563, L1569, L1573–1575, L1594, L1601, L1770, L1773, L1818, L1821, L2281, L2625, L2628, L2897–2898, L2952–2953, L3252, L3261, L3325, L3630 (38) | `@kit.toggle_group`, `item`, `part_id`, `PopState`, `in_room`, `slider`, `slider_look_of`, `tooltip`, `MenuItemState`, `Entry`, `Menu`, `dropdown_menu`, `menu_separator`, `menu_label`, `menu_radio`, `menu_item`, `SwitchState`, `switch_look_of`, `switch`, `dialog`, `Field`, `text_field`, `radio_group` | Legacy `Ctx` widgets: `@sf.button` (34 refs / 13 files), `@sf.switch` / `@sf.slider` / `@sf.text_field` / `@sf.dropdown_menu` / `@sf.dialog` / `@sf.tooltip` / `@sf.within_room`. Shared pure data types (`MenuItem`: 115 refs / 46 files; `Tone`, `PillTone`) live in the same file. | 1. Split pure data types (`MenuItem`, `Tone`, `PillTone`) out of `parts.mbt` into `types.mbt` / `menu_types.mbt`.<br>2. Migrate remaining `apps/mbui` callers (`sfapp/settings/{phone,rig,vault}_ask.mbt`, `sfdesk/drive_tab.mbt`, `sfbase/viz_mbui_node.mbt`, etc.) to node equivalents (`button_node`, `switch_node`, `slider_node`, `input_node`, `menu_node`, `tip_node`, `confirm_node`).<br>3. Delete legacy `Ctx` functions in `parts.mbt`. |
| `popover_from.mbt` | L16, L20, L24, L26 (4) | `@kit.popover_look`, `@kit.popover` | Legacy `Ctx` `popover_from` callers in `apps/mbui` (replaced by `popover_node.mbt` / `presenters.mbt`). | Migrate remaining callers to `popover_node` (`popover_node.mbt`) and delete `popover_from.mbt`. |
| `presented_rest.mbt` | L46 (1) | `@kit.sheet_rest` | Test/flow helper checking overlay settle state (`presented_rest`). | Remove `@kit.sheet_rest("sf-present")` branch once no `@kit.sheet` overlays remain; keep only `sheet_node` settle check. |
| `seg.mbt` | L37, L91 (2) | `@kit.item`, `@kit.toggle_group` | Legacy `Ctx` `seg` (node replacement `seg_node.mbt` already exists). | Migrate remaining `Ctx` `seg` callers to `seg_node` and remove `seg.mbt` (and update `seg_fill_node_wbtest.mbt` L1 `@kit.` ref). |
| `waiting.mbt` | L167, L176, L384 (3) | `@kit.progress`, `@kit.progress_look_of`, `@kit.progress_ms` | `@sf.progress` (4 refs: `sfbase/updates.mbt`, `viz_chart_node.mbt`, `viz_mbui_node.mbt`, `sfdesk/transfers.mbt`), `@sf.progress_spinner` (2 refs: `sfpages/chat_rows.mbt`, `composer.mbt`), `@sf.spinner` (19 refs / 12 files), `@sf.waiting` (7 refs / 6 files). Node equivalents (`progress_node`, `spinner_node`, `waiting_node`, `wait_line_node`) already have 140+ refs. | 1. Inline `progress_ms` constant in `libs/sf-ui/src/motion.mbt` or `progress_node.mbt`.<br>2. Migrate the 4 `@sf.progress` + 2 `@sf.progress_spinner` callers to `progress_node` / `spinner_node`.<br>3. Delete legacy `Ctx` `progress` / `spinner` / `waiting` functions. |

---

## 3. External Asset Generator Scripts & `core-ts` Protocol Decoupling

### 3A. External Generator Scripts (Outside `libs/sf-ui/`)

All 6 generated data files inside `libs/sf-ui/src/` are currently produced by scripts residing in parent/sibling directories of the monorepo:

| Generated File in `libs/sf-ui/src/` | Size | Current Generator Script | Current Input Source | Decoupling Action for Standalone Repo |
| --- | ---: | --- | --- | --- |
| `palette_data.mbt` | 2.2 KB | `scripts/palette.ts` | `web/ui/src/palette.ts` | Move canonical palette JSON/TS definition and generator into `libs/sf-ui/tools/` (or make `libs/sf-ui` the single source of truth exported to `web/ui`). |
| `font_assets.mbt` (+ `font_assets_js.mbt`) | 960.8 KB | `apps/mbui/scripts/fontassets.py` | `apps/mbui/assets/fonts/jetbrains_mono.ttf` | Move script + TTF asset (or split into optional package `stillfail/sf-fonts`, see §3C). Remove hardcoded `globalThis.__mbassets` web bridge assumption in `font_assets_js.mbt:8` in favor of a host-injected loader hook. |
| `icon_data.mbt` | 90.7 KB | `apps/mbui/scripts/icons.py` | `design/icons/*.svg` (161 SVGs) | Move `icons.py` and the general UI SVG set into `libs/sf-ui/assets/icons/` + `libs/sf-ui/scripts/`. |
| `drawable_data.mbt` | 195.3 KB | `apps/mbui/scripts/drawables` | `apps/mbui/android` + `design/station-icons` (71 vectors) | Move `drawable_data.mbt` back to `apps/mbui` (see §1A & `THIRD_PARTY_NOTICES.md` §5); expose an app-level `register_drawables(Map[String, @pixels.Vector])` hook if `marks_node.mbt` stays in `sf-ui`. |
| `math_glyphs.mbt` (+ `math.json`) | 853.5 KB | `client/core-ts/scripts/math-font.ts`, `math-fixture.ts` | `client/math/font.json` (MathJax TeX 4.1.3) | Split into optional package `stillfail/sf-math` (see §3C) with its own generator script. |
| `kept_wbtest.mbt`, `kept_test.mbt` | — | `client/core-ts/scripts/kept-answers.ts` | Live `client/core-ts` pure calls (`markdown`, `code.ink`, `reader.*`, `ref.words`) | Decouple `sf-ui` tests from `core-ts` by defining a typed MoonBit document/highlight AST interface (see §3B), keeping JSON fixtures only for the optional `core-ts` adapter. |

### 3B. `core-ts` Protocol Coupling in `md_core.mbt` & `kept_call`

- `libs/sf-ui/src/md_core.mbt` (352 lines) decodes the private JSON AST produced by `client/core-ts/src/markdown.ts` (`["p", [...]]`, `["code", {path, line, shown, math, drawing}]`, `["pre", {lang, code, ink}]`, `["a", {href, to, bare}]`).
- `LinkTo` (`md_core.mbt:300–352`) directly encodes still.fail domain link cards: `chat : Bool`, `card : String` (`"screen"`, `"adb"`, `"service"`, `"terminal"`), `station : String`, `screen : String`, `job : String`, `peek : String` (`"pull"`, `"issue"`).
- **Decoupling path**:
  1. Promote `MdBlock` / `MdInline` / `MdTable` in `md_core.mbt` to a public, protocol-agnostic MoonBit IR (`pub enum MdBlock`, `pub enum MdInline`) and replace `LinkTo` with an extensible `LinkMeta` / custom inline-renderer callback.
  2. Move the `core-ts` JSON decoder (`core_blocks`, `core_inlines`, `link_to_of`) and `kept_call` bridge into `apps/mbui/src/sfbase` (or a small adapter package `stillfail/sf-core-bridge`).
  3. External `ui.monoid` apps can then feed any Markdown parser (MoonBit native or JS) into `markdown_node` without depending on `client/core-ts`.

### 3C. Package Split Recommendation for Heavy Binary Assets (`font_assets.mbt` & `math_glyphs.mbt`)

`font_assets.mbt` (**960.8 KB**) and `math_glyphs.mbt` (**853.5 KB**) together account for **1.81 MB** of embedded source bytes in `libs/sf-ui/src/` and carry separate licenses (SIL OFL 1.1 and Apache 2.0).

Recommended standalone package layout:
- `ui.monoid/core` (or `stillfail/sf`): MIT-only core tokens, themes, icons, and general UI components (zero embedded font/math blobs).
- `ui.monoid/code-font` (optional): bundles `font_assets.mbt` (JetBrains Mono, SIL OFL 1.1) and registers via `give_faces(...)`.
- `ui.monoid/math` (optional): bundles `math_glyphs.mbt` (MathJax TeX 4.1.3, Apache 2.0) and `math.mbt` formula renderer.

---

## 4. `apps/mbui/src/sfstorybook` Extraction Checklist

`apps/mbui/src/sfstorybook/moon.pkg` currently imports only **two** app-level packages beyond `mbui/*` and `stillfail/sf`:
- `"stillfail/sfbase"` (`moon.pkg:10`)
- `"stillfail/sfkept"` (`moon.pkg:11`)

Every single reference to `@sfbase` and `@sfkept` across `apps/mbui/src/sfstorybook/*.mbt` (14 occurrences total):

| File & Line (`apps/mbui/src/sfstorybook/`) | Current Call | Replacement in Standalone Storybook |
| --- | --- | --- |
| `shell.mbt:57` | `@sf.kept_call.val = Some(@sfkept.answer)` | Replace with `libs/sf-ui`'s own fixture answers (or typed Markdown/code sample structs once §3B lands), eliminating `"stillfail/sfkept"`. |
| `shell.mbt:63` | `@sf.set_words(@sfbase.fill)` | **Already eliminated by Track P3**: remove this line and rely on `libs/sf-ui`'s built-in `default_words` (which responds live to `@sf.set_language`). |
| `shell.mbt:115` | `@sfbase.toasts_node(root, fn() { 24.0 })` | Mount `@sf.toaster_node` directly in storybook shell with a local storybook toast signal/queue. |
| `foundations.mbt:160` | `@sfbase.copy_out(words, said="已复制 " + words)` | Call `@ui.copy_text(words)` (or host clipboard hook) + local storybook toast helper. |
| `stories.mbt:1062` | `@sfbase.toast_later("已复制")` | Call local storybook `story_toast("已复制")`. |
| `stories.mbt:1091` | `@sfbase.toast_later("已删除")` | Call local storybook `story_toast("已删除")`. |
| `stories.mbt:1098` | `@sfbase.toast_later("已改名为「\{name}」")` | Call local storybook `story_toast(...)`. |
| `stories.mbt:1115` | `@sfbase.toast_later("已复制链接")` | Call local storybook `story_toast("已复制链接")`. |
| `stories_u3.mbt:72` | `@sfbase.toast_later("已改名为「\{w}」")` | Call local storybook `story_toast(...)`. |
| `stories_u3.mbt:74` | `@sfbase.toast_later("没有改名")` | Call local storybook `story_toast(...)`. |
| `stories_u3.mbt:93` | `@sfbase.toast_later("已改名为「\{w}」")` | Call local storybook `story_toast(...)`. |
| `stories_u3.mbt:94` | `@sfbase.toast_later("没有改名")` | Call local storybook `story_toast(...)`. |
| `stories_u3.mbt:125` | `@sfbase.toast_later("已关闭查找")` | Call local storybook `story_toast(...)`. |
| `stories_motion_wbtest.mbt:194` | `t.run_for(@sfbase.viz_reveal_ms + @ui.move_most_ms)` | Replace `@sfbase.viz_reveal_ms` with a local constant or `@sf` motion duration token. |

**Conclusion**: Extracting `sfstorybook` into `libs/sf-ui/storybook` (or `ui.monoid/storybook`) requires **only 14 line edits** — 10 toast calls, 1 clipboard helper, 1 `set_words` deletion, 1 `kept_call` fixture swap, and 1 test duration constant.
