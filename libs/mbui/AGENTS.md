# Working in mbui (for agents)

Follow these owner rules yourself without waiting for PR review. CI enforces what can be checked (`libs/mbui/scripts/detlint` and Tester checks). Add a check whenever you can.

Subsystem rules live in narrower `AGENTS.md` files loaded when touching those directories:

- `libs/mbui/src/view/AGENTS.md`: window tree, `View::comes` motion, parking and block reuse, `scrolls_window` invariants, hover, `View::fits`, signals, one-way layout, focus, detlint guards, callsite tracing, generic shells
- `libs/mbui/src/ui/AGENTS.md`: tree-only and multi-window runtime, native views/streams, a11y, FPS invariance, motion smoothness bars, idle skipping, Tester diagnostics and isolation
- `libs/mbui/src/headless/AGENTS.md`: 3-layer component model, `headless.mbt` contract, `kit` deprecation
- `libs/mbui/src/host/AGENTS.md`: adding host calls, between-frame delivery, Android mimalloc allocator

## Its parts

- `libs/mbui/src/view`: retained window tree, made once. `libs/mbui/src/ui`: legacy immediate-mode `Ctx` plus shared runtime, styles (`style.mbt`, `@ui.css`), theme, text fields, Tester, and `FakeHost`.
- `libs/mbui/src/signals`: alien-signals port. `libs/mbui/src/motion`: motion as data. `libs/mbui/src/headless`: headless tree controls. `libs/mbui/src/player`: streaming audio/video player state machine. `libs/mbui/src/kit`: legacy Radix-like controls on `Ctx` (frozen except toasts).
- `libs/mbui/src/flex`, `text`, `shape`, `paint`, `skia`, `svg`, `pixels`: layout and drawing. `src/hostapi` and `src/host`: host interface and platform backends. `src/effect`: Effect-TS model on the frame clock.
- `libs/mbui/tools`: MoonBit build and check tools (`detlint`, `mbc`, `wasmhost`, `chk`, `wasmgas`).

## It knows no app

- mbui builds and tests independently of any app. Nothing in `libs/mbui/` may name an app or reach outside this directory (detlint `app-word`, configured in `detlint.json`).
- App-specific native calls pass through `@hostapi.app_said` / `app_tell` (`libs/mbui/src/host/app_calls.h`), site names via `@hostapi.set_site_name`, and app identity via build settings (`MBUI_APP_ID`, Info.plist, APK resources).

## Two views: the old one and the one made once

- Make each node once in `libs/mbui/src/view` when it first shows and keep it until it leaves. Bind changing properties to signals so only changed work reruns.
- Write no new code on `Ctx`. Legacy detlint counts (`old-island`, `old-list`, `click-read`, `key-read`, `submitted-read`, `build-motion`, `layout-read-back`, `ui-current`, `build-clock`) only fall, and APIs are removed at zero.
- When migrating an old view or fixing UI in `src/view`, read the existing code logic, state, data flow, and git history first, then express it with `src/view`, `src/motion`, and `src/headless`. Never guess from rendered pictures, diff `drawn_rects()` or frame coordinates against the old view, or add per-scene framework hacks to pixel-fit an old page.
- Core tree invariants (details in `libs/mbui/src/view/AGENTS.md` and `libs/mbui/src/ui/AGENTS.md`):
  - Layout flows strictly one way (`View::by_room`, no `layout-told`).
  - Dynamic column/row changes animate through `View::comes`, not per-page code. Initial answers settle immediately.
  - `View::scrolls_window` owns virtualization, reading anchors, unified `bands`, and `press_stays` stability.
  - State read by bindings must be a signal (`T : Eq`), and detlint performance counts only fall.
  - Interactive tree nodes must be named for screen readers (`Tester::hold_named`), and focus (`Tree::takes_keys`) stays independent of hover (`View::pointed`).

## Components: headless, their looks apart

- Keep behavior in `libs/mbui/src/headless`, visual styling in look libraries (`libs/sf-ui`, `libs/comma-ui`), and shared tree/list mechanics in `libs/mbui/src/view`. Read `libs/mbui/src/headless/AGENTS.md` and `libs/mbui/src/headless/headless.mbt` before adding controls.

## Time in a test is declared, never waited for

- Tests execute inputs step by step, declare the exact moment (`run_for`), and assert. Output at a moment must be identical at 60, 120, 24, 7 fps, or in one jump (`libs/mbui/src/ui/AGENTS.md`).
- Skip idle time (`Tester::run_shown`), represent motion as data (no `@effect.next_frame` loops or frame counters), and enforce non-increasing smoothness bars (`MBUI_TEST_MOTION`).
- Never wait for things to settle or animations to end (`rest`, `settle`, sleeps, retries, longer timeouts). `assert_idle` and `at_rest` are assertions only. End-to-end steps wait only for external named events or state facts.

## What is seen, traced to its line

- Under a Tester, tree nodes record callsites (`libs/mbui/src/view/source.mbt`, while device hosts record none). Use `Tester::audit()` for layout rules and `Tester::sources_at(x, y)` / `Tester::sources_of(words)` to trace faults to callers (`mbui/…` vs `stillfail/…`) after reading the code.
- Parts and property setters forward `#callsite(autofill(loc))` / `loc~ : SourceLoc` via `made_for=loc` (detlint `part-place`).

## Pictures come from the Tester's draw list

- Compare screens via Tester draw lists at declared moments, and verify pixels via per-host offscreen renders (`libs/mbui/scripts/render_*.sh`) against host references.
- Never run screenshot diffs on devices, emulators, simulators, or desktop windows. Devices run only host contracts, render contracts, and event-driven smoke flows whose pictures are for human review (detlint `device-shot` blocks new device shots).

## A test links no host

- All host calls go through `libs/mbui/src/hostapi` (`Host` trait). Only app mains import `libs/mbui/src/host` (detlint `host-import`), while Tester installs `FakeHost` (`libs/mbui/src/ui/fake_host.mbt`), keeping native tests runnable on Linux CI.
- Deliver external posts and picker results between frames, never deferring to frame start (`libs/mbui/src/host/AGENTS.md`). Never branch app code on whether a Tester is running (detlint `tester-branch`).
- mbui's film (`libs/mbui/src/film`) links on every host. Apple (`libs/mbui/src/host/apple_film.m`) and Linux (`libs/mbui/src/host/linux_film.c`) film natively; every other host (Android, Windows, iOS) links `libs/mbui/src/host/film_none.c` (`mbf_supported` 0). Film asks a native host only through `mbf_` calls, never a renderer's own name; a new call is written in all three in the same change (`libs/mbui/scripts/film_calls.sh`, run by `libs/mbui/scripts/check.sh`), so no app writes stubs of its own.

## There are no flaky failures

- A check that fails and passes on the same commit means uncontrolled nondeterminism entered the system. Never rerun it green, label it flaky, or add retries/waits: find and isolate or remove the nondeterminism.
- Never call `abort` directly: use `@halt.saying(msg)` (`abort-unsaid`). Never write `test "panic …"` (`panic-test`). Keep every test isolated (`Tester::own_read_said`, `read-before-run`, `leaked_state`, see `libs/mbui/src/ui/AGENTS.md`).

## Tools are MoonBit, not Python

- Write build, CI, and check tools in MoonBit under `libs/mbui/tools` (built on demand by wrapper scripts like `libs/mbui/scripts/chk`) or in shell when only orchestrating commands.
- In development, run tools on wasm-gc via `libs/mbui/scripts/wasmrun.mjs` without compiling C. In CI, build natively (`libs/mbui/scripts/tooltarget.sh`). Route OS calls through `libs/mbui/tools/sys`. Write no new Python. Rewrite existing Python scripts when they need changes.

## Arrays let go of what they held

- On native, `Array::clear`, `truncate`, `pop` and `remove` leave what they took out in the slots past the end, still counted as held. On a long-lived or pooled array of references or closures (a node's children or handlers, a tree's queues, a frame's tells, a reuse pool), follow them with `release_unused(placeholder=…)`, or `shrink_to_fit()` once it is empty, or what they held stays alive and two such arrays can hold each other in a ring.

## Before a PR

- Keep generic tree/list functions as thin shells over non-generic bodies to prevent C monomorphization bloat (`libs/mbui/src/view/AGENTS.md`).
- Every compiler warning is an error or explicitly disabled (`libs/mbui/moon.mod`, matching `apps/mbui/AGENTS.md` Warnings).
- Open one PR per task, squash with `git reset --soft $(git merge-base HEAD origin/main)` (never directly onto `origin/main`), and verify `git diff origin/main --stat` contains only your files.
