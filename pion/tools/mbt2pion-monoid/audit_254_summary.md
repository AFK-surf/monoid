# Wave M1.2 Production Audit Diagnostic Histogram (`libs/ui/src/controls`)

- **Reproduce**: `MBT2PION_BIN=<path> MBT_COMPAT_DIR=<dir> sh pion/tools/mbt2pion-monoid/run_audit_histogram.sh --check`
- **File Accounting (Git-Enumerated, Zero Subtraction)**: **253** native-target emitted `.pion` files + **2** target-excluded JS-only files (`font_assets_js.mbt, math_glyphs_js.mbt`) = **255** Git-tracked production `.mbt` files (explicitly tagging all **8** manifest asset-bypass files: `font_assets.mbt, font_assets_js.mbt, font_assets_native.mbt, icon_data.mbt, math_glyphs.mbt, math_glyphs_js.mbt, math_glyphs_native.mbt, palette_data.mbt`); plus **1** synthesized file (`00_init_order.pion`) = **254** generated `.pion` files (**0 hand edits**, **real Stage A.5 probes**).
- **Toolchain**: `AFK-surf/pion@6d22ff1f` (`mbt2pion` + `mbt_compat`), `AFK-surf/invar@339c271e`, `AFK-surf/monoid@41601bf5`, `pionc 0.1.0`

## 1. Summary

- `mbt2pion` Gate #12a blockers: **5003** (explicit per-site drift accounting; zero silent drift)
- `pionc check --json` total diagnostics: **36654** (`E_PARSE`: **14324**, `E_TYPE_MISMATCH`: **21921**)
- Clean native-target production files (0 `pionc` diagnostics): **21 / 253**
- Layer 2 `m1_invar_blockers.json` hits: **643** (76 distinct symbols)

## 2. `mbt2pion` Stage Diagnostics (`MBT2PION_*`)

| Code | Count |
|---|---:|
| `MBT2PION_UNDISPOSED_PROBE_SITE` | 1958 |
| `MBT2PION_UNDISPOSED_DIV_MOD` | 533 |
| `MBT2PION_PROBE_RESIDUAL` | 18 |
| `MBT2PION_UNKNOWN_DERIVE` | 2 |
| `MBT2PION_PROBE_MISMATCH` | 1 |

## 3. Remaining Top 15 `mbt2pion_engine` Mechanical Buckets

| # | Count | Mechanical Bucket | Sample |
|---:|---:|---|---|
| 1 | 10159 | E_TYPE_MISMATCH: undefined identifier (parse cascade / missing local/import) | `00_init_order.pion:87:59 (undefined identifier `Ui`)` |
| 2 | 6936 | E_TYPE_MISMATCH: cannot call undefined function | `00_init_order.pion:421:84 (cannot call undefined function `A`)` |
| 3 | 2826 | E_PARSE: unexpected `:` where expression expected | `accent_pick.pion:71:67 (expected expression, found `:`)` |
| 4 | 2268 | E_PARSE: Pion keyword `val` used as field/ident (`r.val` unlowered when Stage A.5 aborts) | `00_init_order.pion:1239:49 (expected expression, found `val`)` |
| 5 | 2182 | E_PARSE: unexpected `,` where expression expected | `accent_pick.pion:71:60 (expected expression, found `,`)` |
| 6 | 1371 | E_PARSE: unexpected `->` where expression expected | `accent_pick.pion:71:72 (expected expression, found `->`)` |
| 7 | 1076 | E_PARSE: expected `<tok>`, found `<tok>` (found `(`) | `accent_pick.pion:160:19 (expected `)`, found `(`)` |
| 8 | 1001 | E_TYPE_MISMATCH: struct `<sym>` has no field `<sym>` | `00_init_order.pion:1239:48 (struct `signals::Ref` has no field `<error>`)` |
| 9 | 975 | E_PARSE: unexpected `)` where expression expected | `00_init_order.pion:7253:48 (expected expression, found `)`)` |
| 10 | 587 | E_PARSE: expected `<tok>`, found `<tok>` (found `:`) | `accent_pick.pion:160:27 (expected `)`, found `:`)` |
| 11 | 544 | E_PARSE: unexpected `pub` where expression expected | `00_init_order.pion:7260:1 (expected expression, found `pub`)` |
| 12 | 382 | E_TYPE_MISMATCH: type mismatch in assignment | `00_init_order.pion:1239:49 (type mismatch in assignment)` |
| 13 | 338 | E_TYPE_MISMATCH: unknown named argument `<sym>` in call to `<sym>` | `00_init_order.pion:158:83 (unknown named argument `w` in call to `text_style`)` |
| 14 | 327 | E_TYPE_MISMATCH: missing/unmapped Invar symbol in `view::*` | `accent_pick.pion:160:29 (unknown path `view::View`)` |
| 15 | 295 | E_PARSE: expected `<tok>`, found `<tok>` (found `::`) | `align.pion:70:13 (expected `(`, found `::`)` |

## 4. Remaining Top 15 Layer 2 `invar_layer2_blocker` Symbols

| # | Count | Symbol (`expected_invar`) |
|---:|---:|---|
| 1 | 420 | `ui::css` |
| 2 | 25 | `ui::span` |
| 3 | 24 | `ui::CornerOf` |
| 4 | 14 | `ui::long_press_ms` |
| 5 | 14 | `ui::style_words` |
| 6 | 12 | `ui::CornerRoots` |
| 7 | 10 | `ui::sp_at` |
| 8 | 8 | `lg::in_liquid_pill` |
| 9 | 6 | `ui::shape_of` |
| 10 | 6 | `ui::window_keys_own` |
| 11 | 5 | `lg::liquid_pill_hover_ink` |
| 12 | 5 | `ui::has_image` |
| 13 | 5 | `ui::text_advance` |
| 14 | 5 | `ui::words_shaped` |
| 15 | 4 | `ui::field_edit_now` |
