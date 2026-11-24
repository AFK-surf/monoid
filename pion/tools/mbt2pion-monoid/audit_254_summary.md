# Wave M1.1 Production Audit Diagnostic Histogram — Round 3 Final (`mbt2pion@6d22ff1f` + `invar@339c271e`)

- **Source**: `libs/ui/src/controls` (255 production `.mbt` files after `origin/main` rebase; **zero hand edits** to generated output)
- **Toolchain**: `AFK-surf/pion@6d22ff1f` (`mbt2pion` + `mbt_compat`), `AFK-surf/invar@339c271e` (Wave P0-1A unified `signals::Ref`), `pionc 0.1.0`
- **Runtime**: `mbt2pion --mode audit` **4306 ms**; `pionc check --json` **<1 s** (0 compiler crashes)

## 1. Round 1 (`35af4bb7`) → Round 2 (`b1d2a2b8`) → Round 3 (`6d22ff1f` + `invar@339c271e`) Progression

| Metric | Round 1 (`35af4bb7`) | Round 2 (`b1d2a2b8`) | Round 3 (`6d22ff1f` + `339c271e`) |
|---|---:|---:|---:|
| `mbt2pion` blockers | 1100 | 113 | **5095** |
| Generated `.pion` files | 254 (no `00_init_order.pion`) | 255 (`00_init_order.pion`) | **256** (`00_init_order.pion` emitted) |
| `pionc check --json` total diagnostics | 52080 | 34310 | **32226** |
| `pionc` `E_PARSE` diagnostics | 29769 | 14806 | **14279** |
| `pionc` `E_TYPE_MISMATCH` diagnostics | 24728 | 19054 | **17467** |
| Clean production files (0 `pionc` diags) | 14 / 254 | 24 / 254 | **24 / 255** |
| Layer 2 `m1_invar_blockers.json` hits | 188 | 738 | **712** (77 distinct symbols) |
| Strict `invar` blockers (`m1_invar_blockers.json`) | 65 | 65 | **58** (-7 after Wave P0-1A) |

## 2. `mbt2pion` Stage Diagnostics (`MBT2PION_*`)

| Code | Count |
|---|---:|
| `MBT2PION_UNDISPOSED_PROBE_SITE` | 1955 |
| `MBT2PION_UNDISPOSED_DIV_MOD` | 526 |
| `MBT2PION_AMBIGUOUS_CTOR` | 96 |
| `MBT2PION_PROBE_RESIDUAL` | 18 |
| `MBT2PION_MANUAL` | 14 |
| `MBT2PION_UNSUPPORTED_SYNTAX` | 2 |
| `MBT2PION_UNKNOWN_DERIVE` | 2 |
| `MBT2PION_PROBE_MISMATCH` | 1 |

## 3. Remaining Top 15 `mbt2pion_engine` Mechanical Buckets

| # | Count | Mechanical Bucket | Sample |
|---:|---:|---|---|
| 1 | 9139 | E_TYPE_MISMATCH: undefined identifier (parse cascade / missing local/import) | `00_init_order.pion:1775:58 (undefined identifier `Title`)` |
| 2 | 3122 | E_TYPE_MISMATCH: cannot call undefined function | `00_init_order.pion:764:58 (cannot call undefined function `room`)` |
| 3 | 2813 | E_PARSE: unexpected `:` where expression expected | `accent_pick.pion:69:67 (expected expression, found `:`)` |
| 4 | 2268 | E_PARSE: Pion keyword `val` used as field/ident (`r.val` unlowered when Stage A.5 aborts) | `00_init_order.pion:1236:49 (expected field or method name, found `val`)` |
| 5 | 2174 | E_PARSE: unexpected `,` where expression expected | `accent_pick.pion:69:60 (expected expression, found `,`)` |
| 6 | 1363 | E_PARSE: unexpected `->` where expression expected | `accent_pick.pion:69:72 (expected expression, found `->`)` |
| 7 | 1064 | E_PARSE: expected `<tok>`, found `<tok>` (found `(`) | `accent_pick.pion:139:19 (expected `)`, found `(`)` |
| 8 | 1018 | E_TYPE_MISMATCH: struct `<sym>` has no field `<sym>` | `00_init_order.pion:1236:48 (struct `signals::Ref` has no field `<error>`)` |
| 9 | 971 | E_PARSE: unexpected `)` where expression expected | `00_init_order.pion:7237:48 (expected expression, found `)`)` |
| 10 | 582 | E_PARSE: expected `<tok>`, found `<tok>` (found `:`) | `accent_pick.pion:139:27 (expected `)`, found `:`)` |
| 11 | 540 | E_PARSE: unexpected `pub` where expression expected | `00_init_order.pion:7244:1 (expected expression, found `pub`)` |
| 12 | 383 | E_TYPE_MISMATCH: type mismatch in assignment | `00_init_order.pion:1236:49 (type mismatch in assignment)` |
| 13 | 337 | E_TYPE_MISMATCH: unknown named argument `<sym>` in call to `<sym>` | `00_init_order.pion:155:121 (unknown named argument `w` in call to `text_style`)` |
| 14 | 326 | E_TYPE_MISMATCH: missing/unmapped Invar symbol in `view::*` | `accent_pick.pion:139:29 (unknown path `view::View`)` |
| 15 | 303 | E_PARSE: expected `<tok>`, found `<tok>` (found `::`) | `align.pion:70:13 (expected `(`, found `::`)` |

## 4. Remaining Top 15 Layer 2 `invar_layer2_blocker` Symbols

| # | Count | Symbol (`expected_invar`) |
|---:|---:|---|
| 1 | 420 | `ui::css` |
| 2 | 44 | `ui::span` |
| 3 | 39 | `ui::style_words` |
| 4 | 24 | `ui::CornerOf` |
| 5 | 23 | `ui::style_ink` |
| 6 | 14 | `ui::long_press_ms` |
| 7 | 12 | `ui::CornerRoots` |
| 8 | 10 | `ui::sp_at` |
| 9 | 8 | `lg::in_liquid_pill` |
| 10 | 6 | `ui::text_advance` |
| 11 | 6 | `ui::shape_of` |
| 12 | 6 | `ui::window_keys_own` |
| 13 | 5 | `lg::liquid_pill_hover_ink` |
| 14 | 5 | `ui::words_shaped` |
| 15 | 5 | `ui::window_keys_own_now` |

## 5. Wave M1.2 Convergence Priority Roadmap

- **P0-1 — Multi-line top-level `let` / struct-record initializers & `00_init_order.pion` visibility**: 929 diagnostics in `00_init_order.pion`; 36 multi-line top-level `let` declarations in controls
- **P0-2 — Anonymous closures (`fn(...) { ... }` / `(...) => ...`) & typed parameter/arrow lowering**: 1029 arrow closures; drives top E_PARSE `:` / `,` / `->` cascades
- **P0-3 — Stage A.5 `Ref` / `.val` lowering resilience when partial `E_PARSE` remains**: Eliminates ~2,200+ `val` keyword E_PARSE + `signals::Ref` field cascades
- **P1-1 — `raise` / `try` / `catch` / `suberror` MoonBit error-handling lowering**: 1 keyword occurrences across controls
- **P1-2 — `extern "C"` / FFI & platform-split `font_assets`/`math_glyphs` bypass**: 2 extern declarations; 8 asset-bypass files already handled by `sf_assets_native`/`sf_assets_web`
- **P1-3 — Layer 2 `AFK-surf/invar` Wave P0-1B+ upstreaming (`m1_invar_blockers.json`)**: 58 strict invar blockers (down from 65 after P0-1A), 34 pure-logic candidates (led by `ui::css` 420 sites)
