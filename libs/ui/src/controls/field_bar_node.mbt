// Floating liquid-glass editing bar for a focused text field (`@ui.field_menu_now()`): reuses `pick_bar_node`
// (single-layer liquid glass `glass_menu()`, outside-only `float_shadow()`, hairline `control_edge_w` in solid mode,
// 32pt rounded ripple buttons), positioned above the selection/caret by default and automatically flipped below
// (clearing the 25pt teardrop handle) when near the top of the window.

///|
/// Localized action labels for `field_bar_node`.
pub(all) struct FieldBarLabels {
  cut : String
  copy : String
  paste : String
  select_all : String
}

///|
/// Floating liquid-glass editing bar for focused text fields, mounted in `root` (`over_all`, above presented layers
/// and below `loupe_node`), active while `on()` holds. Idle cost is a single inert host node with zero children.
#callsite(autofill(loc))
pub fn field_bar_node(
  root : @view.View,
  on : () -> Bool,
  labels : () -> FieldBarLabels,
  on_copied? : () -> Unit = fn() {  },
  loc~ : SourceLoc,
) -> Unit {
  let last : Ref[@ui.FieldMenuNow?] = Ref(None)
  let current = fn() -> @ui.FieldMenuNow? {
    if on() {
      match @ui.field_menu_now() {
        Some(m) if m.can != 0 => {
          last.val = Some(m)
          Some(m)
        }
        _ => None
      }
    } else {
      None
    }
  }
  let made = Ref(false)
  let make = fn() {
    guard !made.val else { return }
    made.val = true
    root.box(made_for=loc, fn(host) {
      host.over(Is(true)).over_all(Is(true)) |> ignore
      host.show(
        fn() { current() is Some(_) },
        fn(layer) {
          let (enter, exit) = @signals.untracked(fn() { (pop_in_for(layer), pop_out_for(layer)) })
          let (look, live) = @motion.overlay_presence(layer, enter~, exit~)
          layer.over(Is(true)) |> ignore
          layer.box(made_for=loc, fn(b) {
            @ui.keeps_field_menu(b)
            .over(Is(true))
            .alpha(By(fn() { look().alpha }))
            .scale(By(fn() { look().sx }), about=FromBeside, max_shift=pop_max_shift)
            .in_use(By(live))
            |> ignore
            b.reacts(
              fn() { (current(), root.clear().0) },
              fn(state) {
                guard state.0 is Some(m) else { return }
                let top_safe = state.1
                let above = m.y >= top_safe + field_bar_flip_room
                let side : @view.Side = if above { Top } else { Bottom }
                let offset = if above { field_bar_over } else { field_bar_under }
                b.beside(
                  root.id(),
                  side~,
                  along=Middle,
                  offset~,
                  padding=field_bar_pad,
                  piece=fn(_, _) { Some((m.x, m.y, m.w, m.h)) },
                )
                |> ignore
              },
            )
            b.pick(
              at_once=true,
              fn() {
                let m = match current() {
                  Some(cur) => cur
                  None =>
                    match last.val {
                      Some(prev) => prev
                      None => return None
                    }
                }
                let count = (if (m.can & @hostapi.text_menu_cut) != 0 { 1 } else { 0 }) +
                  (if (m.can & @hostapi.text_menu_copy) != 0 { 1 } else { 0 }) +
                  (if (m.can & @hostapi.text_menu_paste) != 0 { 1 } else { 0 }) +
                  (if (m.can & @hostapi.text_menu_select_all) != 0 { 1 } else { 0 })
                let tight = count >= 4 && root.window_w() - 2.0 * field_bar_pad < 340.0 * root.words_scale()
                Some((m.field, m.can, tight))
              },
              fn(slot, key) {
                guard key is Some((fid, can, tight)) else { return }
                let l = @signals.untracked(labels)
                let items : Array[PickBarItem] = []
                if (can & @hostapi.text_menu_cut) != 0 {
                  items.push({
                    label: l.cut,
                    icon: if tight { "" } else { "cut" },
                    mark: false,
                    press: fn() { @ui.field_edit_now(fid, @hostapi.text_menu_cut) },
                  })
                }
                if (can & @hostapi.text_menu_copy) != 0 {
                  items.push({
                    label: l.copy,
                    icon: if tight { "" } else { "copy" },
                    mark: false,
                    press: fn() {
                      @ui.field_edit_now(fid, @hostapi.text_menu_copy)
                      on_copied()
                    },
                  })
                }
                if (can & @hostapi.text_menu_paste) != 0 {
                  items.push({
                    label: l.paste,
                    icon: if tight { "" } else { "paste" },
                    mark: false,
                    press: fn() { @ui.field_edit_now(fid, @hostapi.text_menu_paste) },
                  })
                }
                if (can & @hostapi.text_menu_select_all) != 0 {
                  items.push({
                    label: l.select_all,
                    icon: if tight { "" } else { "select-all" },
                    mark: false,
                    press: fn() { @ui.field_edit_now(fid, @hostapi.text_menu_select_all) },
                  })
                }
                if !items.is_empty() {
                  pick_bar_node(slot, items, compact=tight, loc~) |> ignore
                }
              },
            )
          })
          |> ignore
        },
        leave=@motion.pop_out_ms,
      )
    })
    |> ignore
  }
  root.reacts(fn() { current() is Some(_) }, fn(shown) { if shown { make() } })
}

///|
/// Gap above the selection/caret when the bar sits above it (clears composer top border).
let field_bar_over : Double = 20.0

///|
/// Gap below the selection/caret when the bar flips below it (clears the 18pt teardrop handle).
let field_bar_under : Double = 28.0

///|
/// Minimum headroom above the selection/caret before flipping the bar below it.
let field_bar_flip_room : Double = 64.0

///|
/// Minimum horizontal padding from the window's edges.
let field_bar_pad : Double = 8.0
