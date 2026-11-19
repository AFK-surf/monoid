# mbui window runtime, multi-window, Tester, FPS, and motion bars (for agents)

## Tree-only windows, native views, and multi-window state

- Run pure-tree windows with `@ui.run_tree` (tests: `Tester::tree`) and pass the theme at creation, never via `Ctx::set_theme`. Unrequested frames must draw nothing new (`Tester::unasked_faults`, `libs/mbui/src/ui/tester_unasked.mbt`).
- Host native views (`libs/mbui/src/ui/tree_native.mbt`, `kept` to outlive node) and decoded host streams (`libs/mbui/src/ui/tree_stream.mbt`, `closes` for external ownership) directly as tree nodes, never inside an old `Ctx`. Hide while undrawn and close on unmount unless kept.
- Desktop runs support multiple windows in one process (`@hostapi.windows_in_process`, `libs/mbui/src/ui/window_slots.mbt`), swapping per-window globals on each frame or input and restoring window 0 afterward. Register any new per-window global in `libs/mbui/src/ui/window_kept.mbt` (or via `@ui.window_kept` from upper packages), leaving process-wide caches (pictures, streams, native views, text caches, messages, fibers) outside. Store per-window signals as `Ref[Signal]`, never bare values, so windows do not wake each other.

## Accessibility and focus checks

- Emit incremental screen-reader updates (`libs/mbui/src/ui/a11y.mbt`: `Tree::said_marked`, `Tree::said_pass`), never diffing the full tree every frame. `Tester::set_a11y` verifies incremental diffs match the full tree after every update.
- Every interactive tree node must have a name (`Tester::hold_named`, excluding legacy `Ctx` widgets). Query targets by role and name (`Tester::get`, `Find`).
- Keyboard navigation (Tab, Shift+Tab, arrows) that moves focus completely outside the window fails (`libs/mbui/src/ui/tester_focus_off.mbt`).

## Frame-rate invariance, motion smoothness, and idle-time skipping

- Tester runs every test across frame rates via `MBUI_TEST_FPS` (`libs/mbui/scripts/fps_check.sh`: 60, 120, 24, 7 fps on `main` post-merge, and 120, 60, 24 fps on PRs for changed app test files via `rates-changed`). All rates must match identically. Resting screen sweeps (`screens`, `squeeze_said`, `words_large`, `corners`, `contrast`) run at the default rate only.
- Frame-to-frame smoothness (`sizes_steady`, `sizes_across`, `rows_steady`, `words_over`, `gaps_steady`) runs on the default run and under `MBUI_TEST_MOTION` at 60/120 fps (`libs/mbui/src/ui/tester_fps.mbt`, `libs/mbui/scripts/motion_bars.sh`). `*_known` bars and `@ui.motion_counted` only shrink. Lower bars or remove files in the same change that fixes a fault (`motion_bars.sh` fails `main` on stale high bars). `@view.answering` (`libs/mbui/src/view/answer_marked.mbt`) marks immediate data changes, while mid-transition nodes (`Tree::on_way_at`) are still checked for mid-motion jumps. Tests stepping custom frames to measure motion return early when `@ui.test_at_a_rate()` is true.
- Skip idle time instead of stepping empty frames: `Tester::each_frame` advances with `Tester::run_shown` (display cadence only while frames are requested, jumping straight across rest to the next due time). `set_frame_period` and `Tester::frame_as_host` skip unrequested frames (`Tester::frame_unasked`), while recorded tapes (`set_frame_times`) replay their recorded ticks. Stepping spans with `Tester::frame` is counted by `frame-walk`, which only falls.
- Motion is data computed from start, end, curve, and cause moment. Never step animations with `@effect.next_frame` loops, trigger motion by comparing previous frame geometry, or use time windows. A `View::at_moment` scheduled in the past fires at the request moment (`libs/mbui/src/view/at_moment_past_test.mbt`).
- Never read frame counters (`Ctx::frame_number`, `Ctx::build_number`, detlint `frame-number`) or global context (`@ui.current()`, detlint `ui-current`). Pass `Ctx`/`View` and record causes directly.

## Tester diagnostics and test isolation

- Use `Tester::hold_faults` (`[SILENT_HOLD]`, `[LONG_HOLD]`), `Tester::waterfall_faults` (`[ASYNC_WATERFALL]`), and `Tester::set_fanout_limit` (`[FAN_OUT]`) to catch hidden waits, serial waterfalls, and excess wakeups.
- `Tester::frame` retains rows like a real device (`libs/mbui/src/ui/tester_rows.mbt`) to expose untracked mutable state. `built-by-hand` forbids `Ctx::forget_parts` and `built_from_changed`.
- Never call `abort` directly (`abort-unsaid`): call `@halt.saying(msg)` (`libs/mbui/src/halt`) so wasm-gc prints the message and location.
- Never write `test "panic …"` (`panic-test`): panics leave wasm-gc process globals dirty for subsequent tests (`leaked_state`). Assert faults via `@view.faults_stop`/`@view.fault_told` or two-step checks (`css_read`, `Tester::idle_said`, `draw_said`, `flex.reuse_refused`).
- Finish reading one `Tester` before creating another (`Tester::own_read_said`, `libs/mbui/src/ui/tester_own.mbt`). Always start a fresh run (`new_run`, `Tester`) before reading app state (`read-before-run`).
- App code never checks whether a Tester runs (`tester-branch`, no `fake.val`). Vary test behavior only through `FakeHost` (`libs/mbui/src/ui/fake_host.mbt`) or Tester hooks (`pass_look`, `frame_said`, `shot_watch`).
