// The window's own buttons (window_keys.mbt) as nodes of the window's tree, made once: over all else of the window
// (View::over_all), shown where they are the app's to draw (@ui.window_keys_own_now: Windows and Linux with an inset
// title bar), on the line of the top row under them in each layout, reporting the maximize button's rect to the host
// (@ui.window_snap) for Windows' Snap Layouts: in one liquid glass pill (bar_pill_group_node), as the bars' groups of
// keys are.

///|
/// Which top-row band the window's own buttons (`window_keys_node`) align to, driven by the active shell.
/// - `Bar`: wide top bar or full-window viewer bar (`y = 9..45`, centerline `27pt`, symmetric `9pt` top/right inset).
/// - `Tape`: Medium tape card header (`y = window_in + tape_line - pad`, concentric with the tape panel's top-right).
/// - `Band`: Small dedicated top band (`54pt` tall, pill centered vertically at `y = 9..45`).
#derive(Eq)
pub(all) enum KeysLine {
  Bar
  Tape
  Band
}

///|
/// Resolve which `KeysLine` applies: explicit shell-driven `line` when provided, else legacy `whole` + `layout(width)`.
fn window_keys_line_for(width : Double, whole : Bool, line : (() -> KeysLine)?) -> KeysLine {
  match line {
    Some(f) => f()
    None =>
      if whole {
        Bar
      } else {
        match layout(width) {
          Small => Band
          Medium => Tape
          Large => Bar
        }
      }
  }
}

///|
/// Where the pill holding the buttons stands for `kl` and tracked corner `roots`: (top from window top, side from right).
fn window_keys_at_line(kl : KeysLine, roots : @ui.CornerRoots) -> (Double, Double) {
  match kl {
    Bar => (bar_keys_top() - window_keys_pill_pad + window_keys_bar_extra, window_keys_side(roots~))
    Tape => (window_in + tape_line - window_keys_pill_pad, window_keys_side_tape(roots~))
    Band => ((window_keys_band - window_keys_pill_h) / 2.0, window_keys_side(roots~))
  }
}

///|
/// The window's own buttons over all else of the window in `root` (minimize, maximize/restore, close, in one liquid
/// glass pill), shown while `@ui.window_keys_own_now()` holds. `line`: shell-driven band (`Bar`, `Tape`, or `Band`);
/// when omitted, falls back to `whole` + `layout(width)`.
#callsite(autofill(loc))
pub fn window_keys_node(
  root : @view.View,
  whole? : () -> Bool = fn() { false },
  line? : () -> KeysLine,
  loc~ : SourceLoc,
) -> Unit {
  window_keys_made(loc~, root, whole, fn(_) {  }, line?)
}

///|
/// window_keys_node's buttons, `made` given their pill as it is made (a test's hold on it).
#callsite(autofill(loc))
fn window_keys_made(
  root : @view.View,
  whole : () -> Bool,
  made : (@view.View) -> Unit,
  line? : () -> KeysLine,
  loc~ : SourceLoc,
) -> Unit {
  let pill_owner : @signals.Signal[@view.NodeId?] = @signals.signal(None, same=fn(a, b) { a == b })
  // (report the maximize button's rect to the host for Windows' Snap Layouts, and the pill's to the tree for what goes
  // beside another to go round it (a menu morphing out of a bar's pill beside them: Tree::keeps_away), updating as
  // own/width/whole/line/corners/owner change)
  root.reacts(
    fn() {
      if !@ui.window_keys_own_now() {
        return None
      }
      let width = root.window().0
      let kl = window_keys_line_for(width, whole(), line)
      let (pill_top, pill_side) = window_keys_at_line(kl, @ui.tree_corner_roots_now())
      Some((width - pill_side, pill_top, kl is Band, pill_owner.get()))
    },
    fn(pos) {
      match pos {
        Some((right, top, is_band, owner)) => {
          // (the maximize button is second from the right: past the pill's pad, close and the gap between them)
          let x = right - window_keys_pill_pad - bar_key_side - window_keys_gap - bar_key_side
          @ui.window_snap(x, top + window_keys_pill_pad, bar_key_side, bar_key_side)
          root.tree.keeps_away(
            Some((right - window_keys_w(), top, window_keys_w(), window_keys_pill_h)),
            owner?,
            band=is_band,
          )
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
        let kl = window_keys_line_for(layer.window_w(), whole(), line)
        let (top, side) = window_keys_at_line(kl, @ui.tree_corner_roots_now())
        (0.0, top, side, 0.0)
      }),
    )
    |> ignore
    let pill = bar_pill_group_with(
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
    let pid = pill.id()
    pill_owner.set(Some(pid))
    pill.owns(fn() {
      if pill_owner.untracked() == Some(pid) {
        pill_owner.set(None)
      }
    })
    |> ignore
    made(pill)
  })
}
