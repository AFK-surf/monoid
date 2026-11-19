# Working on still.fail's apps (for agents)

This is still.fail's single app across every platform (see `apps/mbui/README.md`), written in MoonBit on `libs/mbui` (unpinned, changed in the same PR). `libs/mbui/AGENTS.md` and `libs/sf-ui/AGENTS.md` apply here too.

Subsystem rules live in narrower `AGENTS.md` files loaded when touching those directories:

- `apps/mbui/src/sfbase/AGENTS.md`: instant bar places, SWR, open gates, kept roots, workspace switch < 300 ms, ahead reads, `press_wait`, beside-chat tabs, topic subscriptions, feature registry
- `apps/mbui/src/sfpages/AGENTS.md`: card block granularity, keyed chat page, block reuse, `chatPage` flag, width bindings, Farview client
- `apps/mbui/src/sfapp/AGENTS.md`: screen sweeps, `fixed_outgrown`, `shown_known`, real-size budgets, replay topic bytes and trace switches, offscreen stills/video, latency

## The terms (术语)

Use these four terms in PR descriptions and user-facing text (never 电脑版, 手机版, 桌面端, 移动端, or 触屏设备):

- **屏幕** (`@sf.layout`: `Small` / `Medium` / `Large`, 小屏 / 中屏 / 大屏, plus half-open foldables laid out as 小屏 and upright phones): decides pane layout and sheets from bottom (小屏) vs. popovers beside trigger (中屏, 大屏).
- **原生操控** (`@sf.native_input()`): touch or keyboard-and-mouse fixed at startup. Decides drawn sizes (press targets stay >= 44x44 without overlap on every input), hover-only affordances vs. touch equivalents, Enter, scrollbars, and ⌘K (list-top search field appears on every input).
- **当前操控** (`@ui.pointing()`): live input mode. Decides interaction feedback only, never what shows, where, or how big.
- **页面宽窄** (`@sf.look()`): 窄排法 / 宽排法 based on the page's own box width.

## The app

- One app runs on every native platform and on the web (`web/mbui.html`, `apps/mbui/scripts/web-app.sh`). Build every page here once for all screens. `web/` keeps only the web host and a few Preact pages (sign-in callback, share page, admin console).
- Do not restore mbui self-comparisons removed in #881. Show before-and-after evidence in PRs for any visible or timing change.

## The component library

- Shared UI parts live once in `libs/sf-ui/src` (`stillfail/sf`, `libs/sf-ui/AGENTS.md`), which imports nothing from the app (detlint `library-import`).
- Controls wrap `libs/mbui/src/headless` for behavior and add only still.fail styling: `@headless.button`, `@headless.toggle`, `@headless.disclosure`, `@headless.choice`, `@headless.combobox` (`combo_node`, `offers_node`, `pick_node`, `search_combo_node`), `@headless.menu` (`menu_node`), `@headless.toaster` (`toaster_node`), `@headless.radio_group`, `@headless.slider`, `@headless.split`, and `@headless.table`. Conditional buttons use `button_while_node`, and fading disabled buttons stay disabled while hidden. Detlint `button-by-hand` forbids hand-rolled buttons. Pass long-press tips/ripples via `@headless.Hold` and switch holds via `hold_press`.
- Showcase components and states in `apps/mbui/src/sfstorybook` (`foundations.mbt`, `stories.mbt`, `apps/mbui/src/sfstories`), built by `apps/mbui/scripts/kit-web.sh` and deployed to `kit.monoid.zone` (`cloud/wrangler.kit.jsonc`).
- Beside a multi-line block, align icons, marks, chevrons, and one-line parts to the first line, never centered on block height (`Tester::first_line_faults`, `corners_first_line_known`). Below a line starting with a mark and words, start following lines at the mark or at those words, never in between (`Tester::line_start_faults`, `corners_line_start_known`).
- Never end labels in `…` to indicate another step (menu, dialog, sub-page): write full words and add a trailing chevron (`@sf.menu_item_of` `further=true`). Keep `…` only for ongoing work (`正在…`) and macOS system menu bar items.
- Write constant top-level styles as `@ui.css("...")` strings rather than `@ui.style(...)` (avoids megabytes of generated startup C, enforced by detlint `style-text`). Use `@ui.style(...)` only for computed or variable values or inside functions.

## One app: tiers, input, pages, shell

- Six principles: equal ease on both inputs, >= 44x44 non-overlapping press targets, bottom sheets on Small vs. anchored popovers on Medium/Large, screen decides layout while input decides feedback and drawn scale, identical capabilities across tiers, and actions near their targets.
- Package split while merging legacy pages: `libs/sf-ui/src` (library), `apps/mbui/src/sfbase` (model, topics, `Source`, `Page`, `Shell`, shared machinery, importing no pages), `apps/mbui/src/sfdesk` (unmerged Medium/Large pages and frame), `apps/mbui/src/sfapp` (Small frame and remaining Small pages, `pub using` `sfbase`), and `apps/mbui/src/sfpages` (merged cross-screen pages).
- Move shared code down to `sfbase` or `libs/sf-ui`. Keep business logic in the core and copy in `@sf.t`. Navigate via `@sfbase.open_page` and `@sfbase.open_detail`, never pushing onto `app.nav`.
- Never branch inside a page on `@sf.layout`, `@sf.native_input()`, or `@ui.pointing()`: adapt layout by page width, ask the library for input-aware parts, and use library primitives (`c.lit`, `c.menu_asked`, tips). Merged pages must be no worse on any screen than before.
- Presenters (`libs/sf-ui/src/presenters.mbt`) own stepping deeper inside overlays (弹层里往里走): pages call `close()` and open the next without tracking step state or back buttons. On 小屏, chained panels, confirms, questions, menus, and picks slide inside one `sheet_node` (`sheet_shows_node.mbt`) without dropping the scrim.
- See `apps/mbui/src/sfbase/AGENTS.md` for data readiness, workspace switching, open gates, unified beside-chat tabs, topic discipline, and the feature registry.

## Made once, as nodes

- Build new and rewritten UI as tree nodes (`@sf.page_node`, `@sf.panel_nodes`, `View::each`, `View::scrolls_window`, `*_node.mbt`), acting in handlers (`on_press`, `on_pick`, `on_change`). Never wrap a node part back into `Ctx`.
- When migrating or fixing UI, read code logic, state, subscriptions, and git history first, then express it in the node architecture. Never diff `drawn_rects()`, pixel-fit the old view, or guess from screenshots.
- Legacy detlint counts (`old-island`, `old-list`, `old-panel`, `click-read`, `key-read`, `submitted-read`, `build-motion`, `layout-read-back`, `ui-current`) only fall. Migrate touched code rather than adding counts.
- See `apps/mbui/src/sfpages/AGENTS.md` for keyed chat nodes, block reuse, experimental migration flags, width bindings, and Farview.

## Motion

- Read `libs/sf-ui/src/motion.mbt` before changing motion:
  - Every motion belongs to one of the nine defined kinds with its presets.
  - Move position or size only from its cause frame, never from layout diffs or measured targets (window, sidebar, keyboard, or tier changes are not motions).
  - Never use time windows as causes or read whether a motion is running in logic.
  - Scale transitions keep full scale from origin and stay invisible at <= 0.5 scale via `@sf.seen_at(scale)`.

## Running in development

- Source `apps/mbui/scripts/env.sh` before running MoonBit (including remote tasks) and keep its `moon` wrapper on `PATH` so diagnostics stay compact. Never call the raw `moon` binary directly.
- Run dev builds in Wasm inside the native shell without compiling app C: `apps/mbui/scripts/wasm-app.sh run` (or `build`), or `PLATFORM=android|ios|windows apps/mbui/scripts/wasm-app.sh run`. Use `apps/mbui/e2e/run.sh mac|android|ios` for local E2E. Native scripts (`mac.sh`, `android.sh`, `ios.sh`, `win.sh`) are for CI and releases.
- On a borrowed user phone (`phone_use`), install only the dev package `fail.still.android.dev` (default `VARIANT`), never a per-chat id and never overwriting stable or beta. Enable test hooks with `adb shell setprop debug.mbui.hooks 1`.

## Checks, host boundary, and where tests run

- Check changed screens with `t.audit()`, `t.sources_of(words)`, and `t.sources_at(x, y)` after reading code logic. See `apps/mbui/src/sfapp/AGENTS.md` for sweeps, budgets, replays, and offscreen media.
- App code calls the host through `@hostapi` or `@ui` and never imports `libs/mbui/src/host` (detlint `host-import`, only mains like `apps/mbui/src/stillfail` import it), so native tests run on Linux (`TARGETS=native apps/mbui/scripts/test.sh`).
- `apps/mbui/scripts/test.sh` and `libs/mbui/scripts/test.sh` run in CI only (they refuse outside CI to avoid serial wasm-gc queues on shared Macs). Locally or on build stations, run `check`, `libs/mbui/scripts/detlint`, targeted test files (`moon test --target wasm-gc --release src/sfapp/<file>_wbtest.mbt`), and benchmarks for speed changes. Never ask an agent to run the full suite before opening a PR.
- Measure speed deterministically with `apps/mbui/scripts/instrbench.sh` (`compare` side by side, reporting numbers without automated pass/fail verdicts) and real frame time with `apps/mbui/scripts/appbench.sh`. Track build size and idle memory via `.github/workflows/mbui-size.yml` (`scripts/size.sh`, `scripts/idlemem.sh`, `mbui-size` branch, reporting before/after on size work).
- Push only when ready to merge (use `station_task` `dir` for remote checks). Watch PR CI asynchronously with `ci-wait.sh` from `stillfail-github-ci`, fixing failures from logs until all checks pass.

## Warnings

- Every compiler warning is an error or explicitly disabled (`warnings` in `apps/mbui/moon.mod`, `libs/mbui/moon.mod`, `libs/mbui/tools`, `apps/mbui/tools`, `libs/mbui/bench/signals`) so unchanged packages skip re-checking on `moon check`.
- Permanently disabled warnings: `33` (long single-line asset data), `79` (`derive` boilerplate on public types), and `29` (side-effect/target-specific package imports).
- Use `Repr(x)` or `#derive(Debug)` for debugging, `Show` for human-readable text, and `some_text`/`list_text`/`rect_text` (`libs/mbui/src/ui/shown_text.mbt`) for serialized values in keys or tests.
- Suppress intentionally unused items locally with `#warnings("-unused_value")` / `-unused_field` / `-unused_constructor` / `-struct_never_constructed` plus a comment naming the reason (and the field name on structs). Delete everything else unused.
- CI tracks the latest MoonBit release hourly (`.github/workflows/mbui-moonbit.yml`). Fix newly triggered warnings or deprecations forward using CI's `moon version --all`.

## Before a PR

- Do not run `moon fmt` here because it reformats untouched files across the tree.
