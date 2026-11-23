// What is presented drawn as nodes of the window's tree (presented_nodes), on every screen: a panel (on 小屏 a sheet,
// sheet_node; beside what opened it, panel_node; in the middle of the window, panel_centred_node), a stage (stage_node),
// a confirm (confirm_node) and a question (ask_node) in the middle of the window, a menu (menu_node) and a pick (short,
// as a menu of its choices; long, pick_node) beside what opened it, each at its place in the window's stack of layers
// (its serial). Closed (cancel, Escape, back), it closes and what is over it, what it holds let go of, once
// (dismissed_now); said, it closes and what it says goes on, at that moment. One going is presented till its way out is
// over (tree_presented), let go of then (presented_left), as presented_nodes follows what is presented. A menu's items
// given anew where they are kept (presented_changed) are read again by its rows, keys and choices.

///|
/// The serials of what of the presented the window's tree draws, while it is drawn (made, till it has gone).
// kept across runs: put back by presenters_reset; each let go as its node is
let tree_presented : Set[Int] = Set([])

///|
/// Whether the row of each serial draws it as a sheet (sheet_node): what a page is put on (panel_page) only where it
/// is.
// kept across runs: put back by presenters_reset
let tree_as_sheet : Map[Int, Bool] = Map([])

///|
/// Whether `p` is drawn as a sheet of the window's tree on screen `sheet` (小屏's) with window height `win_h`.
fn tree_sheet_of(p : Presented, sheet : Bool, win_h : Double) -> Bool {
  how_of(p.shows, p.from, p.held, sheet, win_h) == AsSheet
}

///|
/// Whether a pick of `choices` is a menu of them (short, or with no search), not a panel with a search.
fn pick_menu_of(choices : Array[Choice], search : Bool) -> Bool {
  choices.length() < pick_search_from || !search
}

///|
/// What of the presented the window's tree draws, in `root` (over all of it the root holds: each at its place in the
/// window's stack of layers), made as one is presented and let go once it has gone; and under them the reader's
/// layout's panel while one is open (reader_layout_nodes).
#callsite(autofill(loc))
pub fn presented_nodes(root : @view.View, loc~ : SourceLoc) -> Unit {
  // (when the tree moves only for explicit causes, each presented overlay is its own transition boundary so a
  // dialog/sheet's internal transitions stay within it without turning standalone sf-ui tests static)
  let isolated = !root.transition_gate()
  // (the tips of what they hold: one layer of them for the window, over all of it, each presented one's lent it;
  // made after them, its keys (Escape shutting a tip) asked before theirs)
  let tips_at : Ref[@view.View?] = Ref(None)
  let tips = TipLayer::new(fn() { tips_at.val })
  // (the reader's layout's panel, laid over it: under what is presented, which stands in the window's stack of layers)
  reader_layout_nodes(root)
  // (page-level transient hover layer: created lazily on first hover so screens without hover pay zero node overhead)
  window_hover_root.val = Some((root, loc))
  window_hover_at.val = None
  // (what is presented followed as it is told, on the screen it is drawn on: how each open one is drawn, what closed
  // unsaid let go of, what has gone let go: presented_followed)
  root.reacts(
    fn() { (presented_said.val.get(), layout(root.window_w()) is Small, root.window_h()) },
    fn(told) { presented_followed(told.1, told.2) },
  )
  root.each(
    fn() {
      presented_said.val.get() |> ignore
      let w = root.window_w()
      let h = root.window_h()
      // (a panel, a confirm, a question, a menu or a pick drawn by what screen it is on, none before the window has its
      // size: what it is drawn as, a sheet or not, is picked as it is made)
      presented_now
      .filter(fn(p) { (w > 0.0 && h > 0.0) || (p.shows is Panel(x) && x.stage) })
      .map(fn(p) { PresentedItem::{ p: p } })
    },
    fn(it) { it.p.serial },
    fn(row, item) {
      // (its own presented, given it by the list as it is made: no walk of what is presented for it)
      let p = item.untracked().p
      let serial = p.serial
      // (a sheet from the window's foot, on 小屏 as it is made when not a popover in the upper half: sheet_node)
      let as_sheet = tree_sheet_of(
        p,
        @signals.untracked(fn() { layout(root.window_w()) is Small }),
        @signals.untracked(fn() { root.window_h() }),
      )
      tree_as_sheet[serial] = as_sheet
      // (the root's node it is in at its place in the window's stack of layers: its serial, as the host's presented are)
      if isolated {
        row.transitions_only() |> ignore
      }
      row.over(Is(true)).stacked(Is(serial)) |> ignore
      // (what opened it, for every kind it is drawn as: the focus given back to that as it goes, where it still takes
      // it, not to what had the focus as it opened: View::opened_by)
      match p.from {
        Node(v) => row.opened_by(@view.ByNode(v.id())) |> ignore
        At(_, _, _, _) | Unanchored => ()
      }
      // (the tips of what its body and its foot are made of: the window's layer of them, panel_tips_lent)
      row.lends(panel_tips_lent, tips) |> ignore
      // (which of its submenu rows has its menu open, one at a time, its own: panel_submenus_lent)
      panel_submenus_lend(row)
      let open = fn() {
        presented_said.val.get() |> ignore
        presented_open_of(serial)
      }
      // (drawn from its layer made till its way out is over: one closed before it ever showed, never)
      let shown = fn() { tree_presented.add(serial) }
      let gone = fn() {
        // (its way out over: the host lets it go, as its own once drawn no more)
        tree_presented.remove(serial)
        presented_told()
      }
      // (dimming what is under it only where nothing presented under it does: one scrim however many are over one
      // another, scrim_owner)
      let dims = fn() { scrim_owner(false) == serial }
      // (another dialog over it: dimmed over itself)
      let covered = fn() { dialog_covered(serial) }
      // (said: it closes, and what is over it, then what it says goes on, at that moment)
      let done = fn(f : () -> Unit) {
        p.ended = true
        p.chosen = true
        close_from_serial(serial)
        chosen_in(serial, f)
      }
      match p.shows {
        // (on 小屏, a panel (no stage, no steps of its own) whatever it holds, and a confirm, a question, a menu or a
        // pick: a sheet from the window's foot, as the host's are there)
        _ if as_sheet => {
          let x = sheet_panel_now(p)
          sheet_node(
            row,
            open,
            // (its own, then those a step further in from it: panel_page)
            fn() {
              let close = fn() { done(fn() {  }) }
              let all : Array[SheetPage] = [{ n: 0, x, close, from: p.from }]
              for more in p.more.get() {
                all.push({ n: more.n, x: more.x, close, from: more.from })
              }
              all
            },
            fn() { dismissed_now(serial) },
            shown~,
            gone~,
            covered_by=fn() { sheet_over(serial) },
            // (how tall it rises, for a sheet under it pushed up out of its way so far: sheet_over's, as the host's)
            rises=fn(h) { p.sheet_h.set(h) },
            in_place?=p.in_place,
            // (a step further in from another presenter's panel: back from it back to that one)
            step_back?=if p.under is Some(_) { Some(fn() { dismissed_now(serial, back=true) }) } else { None },
            // (a page back, where it is past its first)
            // (where its steps follow a flow kept elsewhere, told to that flow: flow_back)
            page_back=fn() { flow_back(p) || panel_pop(p) },
            stood=fn() { p.stands },
            // (how tall it stands as it closes, for what comes in its place: close_from)
            stands_by=fn(f) { p.stands_now = Some(f) },
            taken=fn() {
              presented_said.val.get() |> ignore
              p.taken_by != 0
            },
            chosen=fn() {
              presented_said.val.get() |> ignore
              p.chosen && p.taken_by == 0
            },
            // (dimming what is under it only where no sheet under it does, the host's sheets among them: scrim_owner)
            dims=fn() { scrim_owner(true) == serial },
          )
        }
        Confirm(title, words, warning, action, danger, run) =>
          confirm_node(
            row,
            open,
            fn() { title },
            fn() { words },
            fn() { action },
            danger,
            fn() { dismissed_now(serial) },
            fn() { done(run) },
            warning~,
            shown~,
            gone~,
            dims~,
            covered~,
          )
        Ask(title, value, placeholder, action, hint, secret, empty, run) =>
          ask_node(
            row,
            open,
            title,
            p.line,
            value,
            placeholder,
            action,
            hint,
            secret,
            empty,
            fn() { dismissed_now(serial) },
            fn(line) { done(fn() { run(line) }) },
            shown~,
            gone~,
            dims~,
            covered~,
          )
        Menu(items, title, along, side) => {
          // (beside what opened it, where it was drawn as it opened; opened by the keyboard where that showed its focus:
          // menu_anchor_now)
          let (anchor, by_key, offset, keep_field) = @signals.untracked(fn() { menu_anchor_now(p.from) })
          // (what it holds as it is now, where it is kept: given anew there whole, then told, presented_changed; what
          // reads it, its rows, keys and choices, read it again then; what a choice does, as it is there then)
          menu_node_by(
            row,
            open,
            anchor,
            fn() { presented_items_of(serial, items) },
            title,
            along,
            offset,
            by_key,
            keep_field,
            fn(item) { done(item.select) },
            fn() { dismissed_now(serial) },
            side~,
            shown~,
            gone~,
            false,
            sub_levels=fn() { p.menu_more.get().map(fn(lv) { (lv.n, lv.title, menu_clean_items(lv.items)) }) },
            level_back=fn() { menu_pop(p) },
          )
        }
        Panel(x) if x.stage =>
          stage_node(
            row,
            open,
            x,
            fn() { done(fn() {  }) },
            fn() { dismissed_now(serial) },
            shown~,
            gone~,
            covered~,
          )
        // (one of nodes that goes in steps in the middle of the window: its steps pages of one dialog)
        Panel({ nodes: { steps: true, .. }, .. } as x) if p.from == Unanchored || x.form =>
          steps_centred_node(
            row,
            open,
            x,
            fn() { done(fn() {  }) },
            fn() { dismissed_now(serial) },
            p,
            shown~,
            gone~,
            dims~,
            covered~,
          )
        Panel(x) if p.from == Unanchored || x.form =>
          panel_centred_node(
            row,
            open,
            x,
            fn() { done(fn() {  }) },
            fn() { dismissed_now(serial) },
            p,
            shown~,
            gone~,
            dims~,
            covered~,
          )
        Panel(x) => {
          // (beside what opened it, where it is drawn: as a menu's)
          let (anchor, _, _, _) = @signals.untracked(fn() { menu_anchor_now(p.from) })
          panel_node(
            row,
            open,
            anchor,
            x,
            fn() { done(fn() {  }) },
            fn() { dismissed_now(serial) },
            p,
            shown~,
            gone~,
          )
        }
        Pick(title, choices, chosen, choose, along, side, search) if !pick_menu_of(choices, search) => {
          // (a panel with its search over its list: pick_node)
          // (panel_offset off what opened it, a point too: @kit.popover's, as a long pick gives no other)
          let (anchor, _, _, _) = @signals.untracked(fn() { menu_anchor_now(p.from) })
          let offset = panel_offset
          pick_node(
            row,
            open,
            anchor,
            title,
            choices,
            chosen,
            p.line,
            along,
            offset,
            fn(k) { done(fn() { choose(k) }) },
            fn() { dismissed_now(serial) },
            shown~,
            gone~,
            side~,
          )
        }
        Pick(title, choices, chosen, choose, along, side, _) => {
          // (a menu of its choices, a short pick's: the one chosen checked where one is, else each its icon;
          // what each is under its words, its value at its row's end, its own mark after its check)
          let (anchor, by_key, offset, keep_field) = @signals.untracked(fn() { menu_anchor_now(p.from) })
          let one_chosen = choices.iter().any(fn(x) { x.key == chosen })
          let items : Array[MenuItem?] = choices.map(fn(x) {
            Some({
              label: x.label,
              icon: if one_chosen { "" } else { x.icon },
              danger: false,
              disabled: x.disabled,
              chosen: if one_chosen { Some(x.key == chosen) } else { None },
              checkbox: false,
              heading: false,
              further: false,
              select: fn() { choose(x.key) },
            })
          })
          menu_node(
            row,
            open,
            anchor,
            fn() { items },
            title,
            along,
            offset,
            by_key,
            keep_field,
            fn(item) { done(item.select) },
            fn() { dismissed_now(serial) },
            side~,
            shown~,
            gone~,
            extras=fn(i) {
              match choices.get(i) {
                Some(x) => { note: x.note, value: x.value, mark: x.mark, end: None }
                None => menu_no_extra
              }
            },
            min_w=chooser_menu_w,
          )
        }
      }
    },
  )
  tips_at.val = Some(root.box(made_for=loc, fn(l) { l.over(Is(true)).over_all(Is(true)) |> ignore }))
  window_tips_at.val = tips_at.val
}

///|
/// The layer over all of the window the presented's tips are in (presented_nodes'), once there is one.
// kept across runs: said again as presented_nodes makes its layer
let window_tips_at : Ref[@view.View?] = Ref(None)

///|
/// The layer over all of the window (presented_nodes' tips'): for what floats over a page's rows, beside them, on
/// every screen (a bar over words a finger picked), not the page's own (on 小屏 its node).
pub fn window_tips() -> TipLayer {
  TipLayer::new(fn() {
    // (the window's now: one a run before made, of another tree, none)
    match (window_tips_at.val, @ui.view_tree()) {
      (Some(l), Some(t)) if t.root_holds(l.id()) => Some(l)
      _ => None
    }
  })
}

///|
/// What a menu presented `from` goes beside, as the host's menus had it: what opened it where it is drawn
/// (@ui.old_anchor: the window's corner, nothing wide, where it never was, as kit's menu_anchor has it), a point,
/// or the window's middle a third down; whether the keyboard opened it (what opened it shows the focus), how far off it
/// it stands (at a point, none), and whether a finger opened it with a field focused (kit's dropdown_menu: the focus
/// left there).
fn menu_anchor_now(from : Anchor) -> ((@view.View) -> @view.View, Bool, Double, Bool) {
  let c = @ui.current()
  // (as kit's dropdown_menu: opened by the keyboard, its first item's; else by a finger with a field focused, that
  // field's still)
  let keep = @ui.pointing() is Finger && c.field_focused()
  let (ww, wh) = c.window_size()
  let middle = (ww / 2.0, wh / 3.0, 0.0, 0.0)
  match from {
    // (a node of the window's tree: beside it where it is drawn)
    Node(v) => {
      let by_key = v.focus_shown()
      (fn(_) { v }, by_key, panel_offset, keep && !by_key)
    }
    At(x, y, w, h) =>
      (
        fn(layer) { fixed_anchor(layer, (x, y, w, h)) },
        false,
        if w == 0.0 && h == 0.0 { 0.0 } else { panel_offset },
        keep,
      )
    Unanchored => (fn(layer) { fixed_anchor(layer, middle) }, false, panel_offset, keep)
  }
}

///|
/// How far in from the column a panel's body is given node `v`'s words go (panel_words_in's, where the body is nodes:
/// panel_nodes); none outside a panel.
pub fn panel_words_in_node(v : @view.View) -> @ui.Style {
  @ui.style(px=room(panel_words_at_node(v)))
}

///|
/// How far apart a panel's body's parts stand in node `v` of it, where the body lays them out itself (one share of
/// the window tall, its parts in a box of its own): as its presenter lays out a body's parts, a dialog's in the middle
/// of the window 16 apart (dialog_body), a sheet's 10 (sheet_panel); none outside a panel.
pub fn panel_parts_gap_node(v : @view.View) -> Double {
  match v.lent(panel_in_lent) {
    Some(p) if p.centred => @ui.Space::px(S4)
    Some(_) => @ui.Space::px(S2_5)
    None => 0.0
  }
}

///|
/// How far in from the column a field over a panel's rows stands in node `v` of its body: in a small panel beside what
/// opened it at the column, its capsule on the rows' grounds' line as a pick's search is (pick_node's); in a sheet or a
/// dialog on its words' line, as a sheet's own field is (the things' 筛选); none outside a panel.
pub fn panel_field_in_node(v : @view.View) -> @ui.Style {
  let words = match v.lent(panel_in_lent) {
    Some(p) if !p.small => p.words
    _ => 0.0
  }
  @ui.style(px=room(words))
}

///|
/// The same, in points (panel_words_in_node's).
pub fn panel_words_at_node(v : @view.View) -> Double {
  match v.lent(panel_in_lent) {
    Some(p) => p.words
    None => 0.0
  }
}

///|
/// How far in from the column a panel's body is given node `v` its title starts, in points: beside what opened it, as
/// far as its head puts it (panel_head_box's S4, text_in); on a sheet, on the words' line; none outside a panel. What its body
/// lines up under the title by (the board's draft's panel: its words and what it runs on).
pub fn panel_title_at_node(v : @view.View) -> Double {
  match v.lent(panel_in_lent) {
    Some(p) if p.small => text_in
    Some(p) => p.words
    None => 0.0
  }
}

///|
/// Whether node `v` is made in the body of a small panel beside what opened it (in_small_panel's, where the body is
/// nodes): its rows at its padding, as a menu's are; not in a sheet, a dialog or outside a panel.
pub fn in_small_panel_node(v : @view.View) -> Bool {
  panel_in_of(v).small
}

///|
/// What reaches a panel's sides on purpose in node `v` of its body (panel_bleed's, where the body is nodes: a strip that
/// scrolls under them, attach's photos): out across the room the panel leaves at its sides; none outside a panel.
pub fn panel_bleed_node(v : @view.View) -> @ui.Style {
  @ui.style(mx=room(-panel_in_of(v).sides))
}

///|
/// How far in from the panel's edges node `v`'s body column sits (panel_bleed_node's width on each side), in points.
pub fn panel_sides_at_node(v : @view.View) -> Double {
  panel_in_of(v).sides
}

///|
/// Node `v` of a panel's body clear of an untitled dialog's close button at its end (untitled_clear's, where the body is
/// nodes); none elsewhere.
pub fn untitled_clear_node(v : @view.View) -> @ui.Style {
  @ui.style(pr=room(panel_clear_at_node(v)))
}

///|
/// How far clear of an untitled dialog's close button node `v` of a panel's body is (untitled_clear_node's), in points.
fn panel_clear_at_node(v : @view.View) -> Double {
  match v.lent(panel_in_lent) {
    Some(p) => p.clear
    None => 0.0
  }
}

///|
/// Whether what a node is in is a sheet's foot whose buttons go across it, each its share (foot_fills, as nodes): lent by
/// sheet_node to its foot's row; read by button_node and foot_spacer_node.
// kept across runs: what each sheet lends its foot, let go with it
let foot_fills_lent : @view.Lent[Bool] = @view.Lent::new()

///|
/// What stands between a foot's buttons at its start and those at its end (Ctx::spacer's, as a node) in `parent`: the
/// room left between them; at a sheet's foot, a share of it as each button's (foot_fills: the old spacer's Fill there).
#callsite(autofill(loc))
pub fn foot_spacer_node(parent : @view.View, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(s) { s.grow(Is(1.0)).basis(Is(Some(0.0))) |> ignore }) |> ignore
}

///|
/// The room what is put over the window has (a dialog in its middle, a panel or a menu beside what opened it): the
/// window, less what the system's bars reach in over it at each edge (View::clear: an iPhone Duo's bars of the app's
/// actions over its top and its tabs at its foot or down its side, a status bar, the home indicator), followed.
pub fn over_room(v : @view.View) -> (Double, Double) {
  let (w, h) = v.window()
  let (top, right, foot, left) = v.clear()
  (dmax(0.0, w - left - right), dmax(0.0, h - top - foot))
}

///|
/// What is presented as the window's tree's list of it (presented_nodes' View::each) has it. One is drawn as it was
/// when it was made and its serial is its key, never another's, so it is told as the same item by its serial alone:
/// what is presented is no value to compare.
priv struct PresentedItem {
  p : Presented
}

///|
impl Eq for PresentedItem with equal(a, b) {
  a.p.serial == b.p.serial
}
