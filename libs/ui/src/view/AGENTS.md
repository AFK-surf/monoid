# mbui window tree, layout, lists, and signals (for agents)

## Window tree model (`libs/ui/src/view/view.mbt`)

- Build new UI with `Tree` and `View`: pass properties as `Live` (`Is(v)` once, `By(fn)` bound), manage dynamic children with structures (`View::show`, `View::pick`, `View::each`), and run handlers (`on_press`, `on_key`, `on_drag`) outside tracking to write state.
- Declare shortcuts via `on_action` and `View::keymap` (`libs/ui/src/view/keymap.mbt`), never reading keys during build (`key-read`).
- Read animation time only at draw time (`moved_by`, look closures) or via framework entries (`Way::shown_on`, `View::drawn_while`, `View::goes_now`). `libs/ui/src/view/clock_read.mbt` fails untracked clock reads in tests.

## Unified entry, exit, and resize motion

- Dynamic additions and removals along a column animate through `View::comes` (flex `come_*`, `list-comes-off`) rather than per-page animations. Along a row, use `come_across` (`libs/ui/src/view/along_row.mbt`).
- Keep opacity invisible at half scale or below during grow/shrink transitions so elements never jump.
- Settle initial data answers (`@view.answering`, `libs/ui/src/view/answering.mbt`, `@signals.first_told`, reused blocks, woken parts) and stack pages (`at_once`) immediately without animating in.
- Group simultaneous column transitions into one `ComeGroup` so they start and land together. A reversed transition decelerates smoothly and reverses with continuous position, speed, and acceleration (`come_turned`, `come_back_path`).
- Clip animating nodes only along their travel axis (`Content::clips_self`, `clips_way`).
- Layout always reflects resting state, while drawing shows motion: do not hold old layout sizes during `pick` transitions (render leaving content fading in place via `libs/ui/src/view/pick_leave.mbt`). Only entering/leaving nodes scale open: a staying node that changes height (reflowed text, appended text) lays out at its new size immediately and opens downward via `Tree::grown_cut_of` (`libs/ui/src/view/list_flip_test.mbt`), never shrinking and regrowing.

## Parking and block reuse

- Keep off-screen switched structures at rest via `View::each` `keeps` (`View::park`, `@signals.rest`, `libs/ui/src/view/each_kept.mbt`) or stack roots via `Nav::replace_kept` / `nav_view` `keeps_made`. Parked nodes are unmounted from layout, draw, hit-testing, focus, and a11y. Watches unsubscribe and re-read on wake while `View::at_moment` and clocks keep advancing (`libs/ui/src/view/at_rest_today_wbtest.mbt`). Never use bare `@signals.effect` inside parked subtrees: use `View::reacts` or bindings.
- Reused list blocks (`View::scrolls_window` `reused`) behave like fresh blocks to callers. The framework saves and restores per-key state (`View::scrolls` except `Scroll::beside`, `View::reused_bool`, `View::on_reused` in `libs/ui/src/view/reused_state.mbt`) without passing keys down. Keep `Scroll::where_at` per row and read static block kind via `View::reused_kind`, never by reading the key untracked.

## Virtualized lists (`View::scrolls_window`)

- Use built-in `head` (scrolls over keys, never anchor) and `foot` (pinned over bottom, reserves tail room, passes non-interactive hits through) instead of spacer rows or manual offsets.
- Declare handler-driven height changes via `View::resizes` so they join the column's `ComeGroup`. Pass shown height to backgrounds via `View::shown_by`.
- Anchor reading position every frame: blocks mark content start with `View::read_from` (`libs/ui/src/view/list_read_from.mbt`), and the list pins the first visible marked start so growth above expands upward and growth inside expands downward (falling back to top visible block when unmarked).
- Defer `ListPlace` jumps (to top, middle, or foot) until a pass can build target rows and settle interfering motions, landing at the final foot (`libs/ui/src/view/list_to_end_lands_test.mbt`).
- Draw multi-block highlights as one unified ground via `View::scrolls_window` `bands`, never per-block pieces (blocks snap tops to pixel grid, creating 1 px seams).
- Draw one key in several blocks (a long message) with `View::scrolls_window` `slices` (`libs/ui/src/view/list_slices.mbt`), never by minting piece keys in the page: bands, `ListPlace::bring` and `Sight` speak of the key and its slice, `View::list_item_pointed` and `View::list_item_span` treat its slices as one, and `keep_first_slice` keeps the first slice (and a `View::sticky` part in it) while a later one shows.
- Hold a part at the top of what scrolls it with `View::sticky` (`libs/ui/src/view/sticky.mbt`), worked out in the drawn walk so drawing and hits agree; its node must be as tall as what it draws (an `over` box `from_top`), or its holder's foot leaves it no room. Reveal a subtree in the paint with `View::spatial_reveal`, never by `View::glyphs_by` on its words (that remakes them every frame).
- Never nest `View::scrolls_window` inside another (`Tree::rows_list_nested_said`). Snap list rows to host pixels (`libs/ui/src/flex/rows_grid_way_test.mbt`, `libs/ui/src/flex/rows_grid_held_way_test.mbt`).
- Keep clicked expanding controls stationary during expand/collapse (`libs/ui/src/view/press_stays.mbt`): controls simply declare `View::says` (`expanded`). Controls that open into sight at the foot declare `View::opens_in_sight`.
- Maintain slots only within `slots_margin` around the viewport with top/bottom spacers (`libs/ui/src/view/list_slots_wbtest.mbt`) so frame cost is O(1) from 30 to 15,000 keys.

## Pointer hover, row fitting, layout, and focus

- A pointer-dependent layout can oscillate. Limit its passes, keep other observers responsive, and retry held observers when their inputs or geometry change.
- Recompute hover (`View::pointed`, tips, hover cards) only on input, immediate change, or end of a geometry-moving transition (`Tree::hand_at_end`, `Prop::moves_hits`), never mid-motion. Batch multi-sample touch frames into one layout at the last sample (`libs/ui/src/ui/touches.mbt`). Clock, layout, and hover changes never bump hits (`Tree::hits_bump`).
- Declaring `View::pointed` makes a node hoverable even without taking presses (`View::points`, `Node::points_alone`). Set `points=false` for `pointer-events: none`. `Node::covers` still governs click occlusion. Pointer hit-testing (`Tree::target_in`) and hover (`Tree::points_over`) skip nodes whose resting composed opacity is `<= 0.001` (not mid-fade) unless opted in via `View::takes_unseen(Is(true))`.
- In `View::fits` rows, hide optional direct children before shrinking `View::cuts` text down to 4 em (`cut_kept_ems`), keeping `View::keeps_held` (`fit_least_held`) until siblings also hit minimum, then shrinking text below 4 em only as a last resort (`fit_soft_held`, `libs/ui/src/ui/fits_row_least_wbtest.mbt`).
- Layout flows strictly one way: compute room-dependent structure inside `View::by_room` (`libs/ui/src/view/room.mbt`) without mutating outside state. Never read layout back outside the tree (`layout-told`, use `View::moved_by`, `Scroll::tucks`, `@ui.old_given`, `@ui.old_went`, `View::pointer_piece`).
- Derive a nested corner from the container lent to it (`View::corner_scope`, `View::corner_inset`, `View::concentric_radius`, `View::concentric_end_pad` in `libs/ui/src/view/container_corner.mbt`) rather than subtracting constants by hand, so it follows when the container's corner changes (a window maximized).
- Keyboard focus queries `Tree::takes_keys` (no modal cover, takes press, `in_use`) independently of pointer reach (`Tree::pressless_at`). Disable background subtrees once on their container with `View::in_use` (`libs/ui/src/view/in_use.mbt`).

## Signals, transitions, tracing, and detlint guards

- `signal` and `computed` require `T : Eq` (`@signals.same_value`) so equal recomputations stop propagating. For handles or non-value types, use `signal_ref`/`computed_ref` or `*_by` with a comment above explaining why. Never create effects inside a computed getter (`@signals.effect_in_computed`) except declared read-scoped resources (`@signals.held_while_read`).
- Use `@signals.derived_signal` for writable derivations (resetting on input change), `@signals.optimistic` for pending edits cleared in one batch with authority updates, and `@view.HoldGate` (with finite `most`) for local transitions while opening remote waits directly into `View::bones`.
- Fix untracked reads (`[STRICT_READ_UNTRACKED]`: bind or call `.untracked()`) and misplaced effects (`[EFFECT_IN_WATCH]`, `[EFFECT_IN_COMPUTED]`).
- Detlint counts only fall (justify rare exceptions inline with `det-ok`): `scoped-computed`, `raw-effect`, `pick-loop`, `each-min-height`, `each-lookup` (use `View::keyed_by` and `View::selected`, `libs/ui/src/view/keyed_by.mbt`), `layout-drawn-while`, `width-structure`, `reused-untracked-key`, `manual-fade-way` (use `View::show` `leave`).
- Parts that construct boxes in a passed `View` and property setters accept `#callsite(autofill(loc))` / `loc~ : SourceLoc` and forward `made_for=loc` (`libs/ui/src/view/source.mbt`, `part-place`) so `Tester::audit()` traces faults to callers.
- Keep generic framework wrappers (`View::pick`, `Tree::structured`, `View::scrolls_window`) as thin shells over non-generic bodies (`Picked`, `Tree::structured_by`, `ListKeys`, `View::scrolls_window_ids`) to avoid MoonBit C monomorphization bloat.
