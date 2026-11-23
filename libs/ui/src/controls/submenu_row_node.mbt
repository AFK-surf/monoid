// A panel's row opening the next menu beside it (submenu_row's) as nodes of the window's tree: a menu's row with a
// chevron toward where it opens. On 小屏 pressed, the presenters' menu of its items (a sheet, titled by its words); on
// 中屏 and 大屏 pressed, or the arrow key toward that side with the focus on it, its menu opens immediately (0 ms),
// while hovering with a mouse opens after `submenu_open_ms` and closes after `submenu_close_ms` once the pointer leaves
// both row and submenu (with `submenu_corridor_ms` grace while traversing the aiming triangle toward the submenu, and
// kept open while visible keyboard focus is inside the submenu). Standalone submenu rows participate in window-level
// L1 transient exclusion; rows embedded inside a hover card/panel share its parent scope.

///|
/// Hover open delay (ms) for a desktop submenu row; click/tap/keyboard open immediately (0 ms).
pub let submenu_open_ms : Double = 160.0

///|
/// Hover close delay (ms) after the pointer leaves both the submenu trigger row and its submenu panel.
pub let submenu_close_ms : Double = 160.0

///|
/// Maximum width (pt) of a submenu panel so long labels truncate cleanly instead of overflowing the window.
pub let submenu_max_w : Double = 380.0

///|
/// Grace delay (ms) when leaving the trigger row toward the submenu inside its safe aiming triangle.
let submenu_corridor_ms : Double = 300.0

///|
/// Which of a presented panel's submenu rows has its menu open (one at a time): lent by presented_nodes to each of what
/// it presents, let go with it.
// kept across runs: what each presented one is lent, let go with it
let panel_submenus_lent : @view.Lent[@signals.Signal[@view.View?]] = @view.Lent::new()

///|
/// Aiming-corridor check of whichever submenu row is currently open in the panel, so sibling rows can switch
/// immediately (0 ms) when the pointer is not inside the active submenu's safe aiming triangle.
// kept across runs: what each presented one is lent, let go with it
let panel_submenu_aim_lent : @view.Lent[Ref[(() -> Bool)?]] = @view.Lent::new()

///|
/// Where the menus of the submenu rows a panel holds are made: the panel's own layer (modal, over the window: the
/// keyboard's focus may go into what is made in it, and nothing the panel cuts cuts them), lent by its presenter
/// (dialog_layer_node, panel_node).
// kept across runs: what each panel's layer is lent, let go with it
let submenu_layer_lent : @view.Lent[@view.View] = @view.Lent::new()

///|
/// What presented_nodes lends `row`, the node one presented is made in: its submenu rows' one open, none at first.
fn panel_submenus_lend(row : @view.View) -> Unit {
  row.lends(panel_submenus_lent, @signals.signal_by(None, same=same_view)) |> ignore
  row.lends(panel_submenu_aim_lent, Ref(None)) |> ignore
}

///|
/// What a panel's presenter lends its layer: itself, where its submenu rows' menus are made.
fn submenu_layer_lend(layer : @view.View) -> Unit {
  layer.lends(submenu_layer_lent, layer) |> ignore
}

///|
/// The same node, or both none.
fn same_view(a : @view.View?, b : @view.View?) -> Bool {
  match (a, b) {
    (Some(x), Some(y)) => x.id() == y.id()
    (None, None) => true
    _ => false
  }
}

///|
/// Whether visible keyboard focus currently resides inside `holder`.
fn submenu_key_focus_in(holder : @view.View) -> Bool {
  let (fid, visible) = holder.tree.focused_now()
  match fid {
    Some(id) => visible && holder.alive() && holder.tree.holds(holder.id(), id)
    None => false
  }
}

///|
/// A row opening the next menu beside it in `parent` (submenu_row's): `label`, `icon` before it where it has one, a
/// chevron toward `side` at its end; `items` the menu's, as they are as it opens. Laid out as a panel's row where it
/// stands (panel_row_by, a menu's row: a small panel's, a sheet's, at a dialog's foot). Outside a presented panel its
/// menu is its own alone, made in `parent`'s layer.
#callsite(autofill(loc))
pub fn submenu_row_node(
  parent : @view.View,
  label : () -> String,
  items : () -> Array[MenuItem?],
  icon? : () -> String = fn() { "" },
  side? : @ui.Side = Right,
  loc~ : SourceLoc,
) -> Unit {
  let open_row = match parent.lent(panel_submenus_lent) {
    Some(o) => o
    None => @signals.signal_by(None, same=same_view)
  }
  let aim_slot = match parent.lent(panel_submenu_aim_lent) {
    Some(a) => a
    None => Ref(None)
  }
  let layer = parent.lent(submenu_layer_lent).unwrap_or(parent)
  let inside_transient = parent.lent(transient_parent_lent) is Some(_)
  let sub_id = Ref(0)
  // (opened by the keyboard: its first item's the focus as it opens)
  let by_key = Ref(false)
  // (opened by a touch tap on Medium/Large: stays open until outside press/selection/Escape/arrow)
  let by_hand = Ref(false)
  let small = fn() { layout(parent.window_w()) is Small }
  let open_due : Ref[(() -> Unit)?] = Ref(None)
  let close_due : Ref[(() -> Unit)?] = Ref(None)
  let stop_open = fn() {
    match open_due.val {
      Some(s) => s()
      None => ()
    }
    open_due.val = None
  }
  let stop_close = fn() {
    match close_due.val {
      Some(s) => s()
      None => ()
    }
    close_due.val = None
  }
  let holder_ref : Ref[@view.View?] = Ref(None)
  let menu_panel_ref : Ref[@view.View?] = Ref(None)
  let last_on_row : Ref[(Double, Double)?] = Ref(None)
  let in_aim_corridor = fn(r : @view.View) -> Bool {
    match (last_on_row.val, menu_panel_ref.val) {
      (Some((lx, ly)), Some(mp)) if mp.alive() => {
        let (mx, my, mw, mh) = mp.placed_window_now()
        let (px, py) = r.tree.pointer_said()
        @headless.submenu_in_aim_corridor(px, py, lx, ly, mx, my, mw, mh)
      }
      _ => false
    }
  }
  let row_ref : Ref[@view.View?] = Ref(None)
  // (closed, where it is this one's open: another's opened at that moment stays)
  let close = fn(r : @view.View) {
    stop_open()
    stop_close()
    by_hand.val = false
    if !inside_transient {
      transient_release(sub_id.val)
    }
    if same_view(open_row.untracked(), Some(r)) {
      aim_slot.val = None
      open_row.set(None)
    }
  }
  let open = fn(r : @view.View, key : Bool, hand : Bool) {
    stop_open()
    stop_close()
    if small() {
      present(Menu(items(), label(), Start, Bottom), Node(r))
      return
    }
    by_key.val = key
    by_hand.val = hand
    if !inside_transient {
      if sub_id.val == 0 {
        sub_id.val = transient_next_id()
      }
      transient_claim(sub_id.val, fn() { holder_ref.val }, fn() { false }, fn() { close(r) })
    }
    aim_slot.val = Some(fn() { in_aim_corridor(r) })
    open_row.set(Some(r))
  }
  let sub = @headless.Submenu::new(
    fn() {
      match row_ref.val {
        Some(r) => same_view(open_row.get(), Some(r))
        None => false
      }
    },
    fn(on) {
      match row_ref.val {
        Some(r) =>
          if on {
            open(r, false, true)
          } else {
            close(r)
          }
        None => ()
      }
    },
    open_delay_ms=submenu_open_ms,
    close_delay_ms=submenu_close_ms,
    corridor_ms=submenu_corridor_ms,
    rtl=side == Left,
  )
  let toward = if side == Left { @ui.key_code_left } else { @ui.key_code_right }
  panel_row_by(
    loc~,
    parent,
    label,
    fn(r) {
      if @ui.pointing() is Finger && !small() {
        sub.open_touch()
      } else {
        open(r, r.focus_shown(), false)
      }
    },
    icon,
    fn() { "" },
    if side == Left { "chevron-left" } else { "chevron-right" },
    false,
    plain=true,
    made=fn(r) {
      row_ref.val = Some(r)
      // (its menu made as it opens, as it was opened then: by the keyboard or not; let go at once as it closes; made in
      // the panel's layer, in what lives as long as its row does (View::lives_with: its scope the row's, as a tip's in
      // its layer): out of sight as its row starts leaving, back as that comes back, gone with it)
      let holder = layer.box(fn(h) { h.over(Is(true)) |> ignore }).lives_with(r)
      holder_ref.val = Some(holder)
      let was_on_row = Ref(false)
      let hover_state = fn() {
        let is_open = same_view(open_row.get(), Some(r))
        let on_row = hovered_node(r)
        if !is_open {
          (false, on_row, false)
        } else {
          (true, on_row, holder.pointed_in())
        }
      }
      r.reacts(hover_state, at_start=false, fn(st) {
        let (is_open, on_row, on_menu) = st
        let at = r.cause_at()
        let entered_row = on_row && !was_on_row.val
        let left_row = was_on_row.val && !on_row
        was_on_row.val = on_row
        if on_row {
          last_on_row.val = Some(r.tree.pointer_said())
        }
        if !is_open {
          stop_close()
          by_hand.val = false
          if !inside_transient {
            transient_release(sub_id.val)
          }
          if entered_row && !small() && @ui.pointing() is Mouse {
            stop_open()
            let sibling_open = open_row.untracked() is Some(_)
            let in_sibling_corridor = match aim_slot.val {
              Some(f) => f()
              None => false
            }
            if sibling_open && !in_sibling_corridor {
              if @signals.untracked(fn() { r.takes_input() }) {
                open(r, false, false)
              }
            } else {
              open_due.val = Some(
                r.at_moment(at + submenu_open_ms, fn() {
                  open_due.val = None
                  if r.alive() &&
                    !small() &&
                    @ui.pointing() is Mouse &&
                    @signals.untracked(fn() { r.pointed_in() && r.takes_input() }) {
                    open(r, false, false)
                  }
                }),
              )
            }
          } else if !on_row {
            stop_open()
          }
          return
        }
        stop_open()
        if on_row || on_menu {
          stop_close()
        } else if @ui.pointing() is Mouse && !by_hand.val && !submenu_key_focus_in(holder) && close_due.val is None {
          let delay = if left_row && in_aim_corridor(r) { submenu_corridor_ms } else { submenu_close_ms }
          close_due.val = Some(
            r.at_moment(at + delay, fn() {
              close_due.val = None
              if r.alive() &&
                same_view(open_row.untracked(), Some(r)) &&
                @ui.pointing() is Mouse &&
                !by_hand.val &&
                !submenu_key_focus_in(holder) &&
                !@signals.untracked(fn() { r.pointed_in() || holder.pointed_in() }) {
                close(r)
              }
            }),
          )
        }
      })
      // (asked of every node that takes keys, the topmost first: its own while it has the focus)
      r.on_key(fn(k) {
        if k.mods == 0 && k.code == toward && r.focused() && !small() {
          open(r, true, false)
          true
        } else {
          false
        }
      })
      |> ignore
      // (closed as it starts leaving (its menu out of sight from then: lives_with), and as it is let go)
      r.on_leaving(fn() {
        was_on_row.val = false
        close(r)
      })
      |> ignore
      r.owns(fn() {
        close(r)
        holder_ref.val = None
        menu_panel_ref.val = None
      })
      |> ignore
      holder.show(fn() { same_view(open_row.get(), Some(r)) }, at_once=true, fn(m) {
        // (the focus given back to its row as it goes: what opened it, kit's submenu's return_focus)
        m.over(Is(true)).opened_by(@view.ByNode(r.id())) |> ignore
        let items_now = items()
        let (sub_host, sub_offset) = match r.lent(floating_host_lent) {
          Some(h) if h.alive() => (Some(h.id()), floating_surface_gap)
          _ => (None, panel_pad + floating_surface_gap)
        }
        menu_node_by(
          m,
          fn() { true },
          fn(_) { r },
          fn() { items_now },
          "",
          Start,
          sub_offset,
          by_key.val,
          false,
          fn(item) {
            close(r)
            (item.select)()
          },
          fn() { close(r) },
          max_w=submenu_max_w,
          side~,
          modal=false,
          false,
          panel_ref=menu_panel_ref,
          host?=sub_host,
        )
      })
    },
  )
}
