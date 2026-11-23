// The window's own buttons (window_keys.mbt) as nodes of the window's tree, made once: over all else of the window
// (View::over_all), shown where they are the app's to draw (@ui.window_keys_own_now: Windows and Linux with an inset
// title bar), on the line of the top row under them in each layout, reporting the maximize button's rect to the host
// (@ui.window_snap) for Windows' Snap Layouts: in one liquid glass pill (bar_pill_group_node), as the bars' groups of
// keys are.

///|
/// Where the pill holding the buttons stands in a window `width` wide (window_keys_at's), given `whole` and the tree's
/// tracked corner `roots`: (its top from the window's top, its side from the window's right).
fn window_keys_at_roots(width : Double, whole : Bool, roots : @ui.CornerRoots) -> (Double, Double) {
  if whole {
    return (bar_keys_top() - window_keys_pill_pad + window_keys_bar_extra, window_keys_side(roots~))
  }
  match layout(width) {
    Small => ((window_keys_band - window_keys_pill_h) / 2.0, window_keys_side(roots~))
    Medium => (window_in + tape_line - window_keys_pill_pad, window_keys_side_tape(roots~))
    Large => (bar_keys_top() - window_keys_pill_pad + window_keys_bar_extra, window_keys_side(roots~))
  }
}

///|
/// The window's own buttons over all else of the window in `root` (minimize, maximize/restore, close, in one liquid
/// glass pill), shown while `@ui.window_keys_own_now()` holds. `whole`: over a page alone over all the window (a window of
/// its own, a full-window tab or file preview), on its bar's line at any width.
#callsite(autofill(loc))
pub fn window_keys_node(
  root : @view.View,
  whole? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> Unit {
  window_keys_made(loc~, root, whole, fn(_) {  })
}

///|
/// window_keys_node's buttons, `made` given their pill as it is made (a test's hold on it).
#callsite(autofill(loc))
fn window_keys_made(root : @view.View, whole : () -> Bool, made : (@view.View) -> Unit, loc~ : SourceLoc) -> Unit {
  // (report the maximize button's rect to the host for Windows' Snap Layouts, and the pill's to the tree for what goes
  // beside another to go round it (a menu morphing out of a bar's pill beside them: Tree::keeps_away), updating as
  // own/width/whole/corners change)
  root.reacts(
    fn() {
      if !@ui.window_keys_own_now() {
        return None
      }
      let width = root.window().0
      let (pill_top, pill_side) = window_keys_at_roots(width, whole(), @ui.tree_corner_roots_now())
      Some((width - pill_side, pill_top))
    },
    fn(pos) {
      match pos {
        Some((right, top)) => {
          // (the maximize button is second from the right: past the pill's pad, close and the gap between them)
          let x = right - window_keys_pill_pad - bar_key_side - window_keys_gap - bar_key_side
          @ui.window_snap(x, top + window_keys_pill_pad, bar_key_side, bar_key_side)
          root.tree.keeps_away(Some((right - window_keys_w(), top, window_keys_w(), window_keys_pill_h)))
        }
        None => {
          @ui.window_snap(0.0, 0.0, 0.0, 0.0)
          root.tree.keeps_away(None)
        }
      }
    },
  )
  let tips = Some(window_tips())
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
    bar_pill_group_with(
      loc~,
      layer,
      height=window_keys_pill_h,
      pad=window_keys_pill_pad,
      gap=window_keys_gap,
      tint=Some(window_keys_glass_tint),
      adaptive=true,
      fn(r) {
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
        )
        |> ignore
        // (pressed with the keys alone: the pointer's press on it is the host's, the pill's press as the host says it is held)
        let max_btn = icon_button_by(
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
          on=fn() { @ui.window_snap_state() == 2 },
          lit=fn() { @ui.window_snap_state() == 1 },
        )
        bind_pill_press_by(max_btn, fn() { @ui.window_snap_state() == 2 })
        let close_btn = icon_button_by(
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
          ink=fn() { 0xFFFFFFFFL },
          hover_bg=fn() { if theme().dark { 0xFF453AD9L } else { 0xE53935D9L } },
        )
        close_btn.focus_ring(Is(Some((1.5, -1.5, 0xFFFFFFD9L)))) |> ignore
      },
    )
    |> made
  })
}
