// The window's own buttons (window_keys.mbt) as nodes of the window's tree, made once: over all else of the window
// (View::over_all), shown where they are the app's to draw (@ui.window_keys_own_now: Windows and Linux with an inset
// title bar), on the line of the top row under them in each layout, reporting the maximize button's rect to the host
// (@ui.window_snap) for Windows' Snap Layouts.

///|
/// Where the buttons stand in a window `width` wide, given `whole` and the tree's tracked corner `roots`:
/// (top from the window's top, side from the window's right).
fn window_keys_at_roots(width : Double, whole : Bool, roots : @ui.CornerRoots) -> (Double, Double) {
  if whole {
    return (bar_keys_top(), window_keys_side(roots~))
  }
  match layout(width) {
    Small => ((window_keys_band - bar_key_side) / 2.0, window_key_in(window_keys_in, roots~))
    Medium => (window_in + tape_line, window_keys_side_tape(roots~))
    Large => (bar_keys_top(), window_keys_side(roots~))
  }
}

///|
/// The window's own buttons over all else of the window in `root` (minimize, maximize/restore, close, after a hairline
/// rule), shown while `@ui.window_keys_own_now()` holds. `whole`: over a page alone over all the window (a window of
/// its own, a full-window tab or file preview), on its bar's line at any width.
#callsite(autofill(loc))
pub fn window_keys_node(
  root : @view.View,
  whole? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> Unit {
  // (report the maximize button's rect to the host for Windows' Snap Layouts, updating as own/width/whole/corners change)
  root.reacts(
    fn() {
      if !@ui.window_keys_own_now() {
        return None
      }
      let width = root.window().0
      let (top, side) = window_keys_at_roots(width, whole(), @ui.tree_corner_roots_now())
      // (the maximize button is second from the right: past close and the gap between them)
      let x = width - side - bar_key_side - window_keys_gap - bar_key_side
      Some((x, top))
    },
    fn(pos) {
      match pos {
        Some((x, top)) => @ui.window_snap(x, top, bar_key_side, bar_key_side)
        None => @ui.window_snap(0.0, 0.0, 0.0, 0.0)
      }
    },
  )
  let tips = Some(window_tips())
  let linked = fn() { Some(window_corner_key()) }
  let never_disabled = fn() { false }
  root.show(at_once=true, @ui.window_keys_own_now, fn(layer) {
    layer
    .made_for(loc)
    .over(Is(true))
    .over_all(Is(true))
    .row(Is(true))
    .lies_along(Is(End))
    .lines_up(Is(Some(Start)))
    .padding(
      By(fn() {
        let (top, side) = window_keys_at_roots(layer.window_w(), whole(), @ui.tree_corner_roots_now())
        (0.0, top, side, 0.0)
      }),
    )
    |> ignore
    layer.box(made_for=loc, fn(r) {
      r.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(window_keys_gap)) |> ignore
      r.box(made_for=loc, fn(rule) {
        rule
        .width(Is(Some(window_rule_w)))
        .height(Is(Some(window_rule_h)))
        .margin(Is((window_rule_before, 0.0, window_rule_after, 0.0)))
        .ground(By(fn() { theme().p.line }))
        |> ignore
      })
      |> ignore
      icon_button_by(
        loc~,
        r,
        "minus",
        fn() { t("desktop.menu.minimize") },
        fn(_) { @ui.window_act(1) },
        tips,
        bar_key_side,
        16.0,
        None,
        never_disabled,
        linked~,
      )
      |> ignore
      // (pressed with the keys alone: the pointer's press on it is the host's)
      icon_button_by(
        loc~,
        r,
        "square",
        fn() { t(if @ui.window_zoomed() { "desktop.window.restore" } else { "desktop.window.maximize" }) },
        fn(_) { @ui.window_act(2) },
        tips,
        bar_key_side,
        16.0,
        Some(fn() { if @ui.window_zoomed() { "copy" } else { "square" } }),
        never_disabled,
        linked~,
        on=fn() { @ui.window_snap_state() == 2 },
        lit=fn() { @ui.window_snap_state() == 1 },
      )
      |> ignore
      icon_button_by(
        loc~,
        r,
        "close",
        fn() { t("desktop.menu.close") },
        fn(_) { @ui.window_act(3) },
        tips,
        bar_key_side,
        16.0,
        None,
        never_disabled,
        linked~,
        ink=fn() { theme().p.red },
      )
      |> ignore
    })
    |> ignore
  })
}
