// The presenters (Presenters): a menu, a pick (one of a list, searched when long), a small panel,
// a confirm and a question with a line to write. A page says what it shows and what opened it, once, as it is pressed;
// the presenter decides how, by the screen alone (rule 3: the steps one after another near each
// other): on Small (@sf.layout) a sheet from the window's foot (the phone's: its grabber, dragged down or back to
// close); on Medium and Large, with either hand, the web's, a small panel beside what opened it (a menu, a pick, a
// panel) or a dialog in the middle of the window (a confirm, a question). One host draws them all over
// the shell (`presented`), after the pages, each frame: it keeps what is open, one over another, the topmost taking
// back, Escape and a press outside, and the focus going into it as it opens.
//
// A step further in changes page in the panel rather than stacking (the user, 2026-11-02: 「现有的多重弹窗太垃圾了」
// ); stacking is for what is asked and returned from.
// That is the host's to keep, not each page's (the user, 2026-11-09: 「小屏上多级抽屉感觉动效和交互有问题」, 2026-11-10:
// 「系统性全修一下」: only two flows had been put on panel_go, the rest closed one and opened the next). What is
// presented while one closed has had no frame drawn of its going is what that one closed for:
// - on a sheet it comes in that one's place: one sheet all along, where that one stood, on to its own height, the
//   scrim as it was, never one sinking as the next rises across it (`in_place`);
// - a menu, short pick, or confirm for a menu's item slides in place inside the same menu container (a level of the
//   same glass popover on Medium/Large via `menu_push`/`menu_push_confirm`, or a page of the same sheet on Small via
//   `panel_page`), with back taking it off to the menu;
// - a panel for what a panel held is a step further in from it on every screen (`under`): a back key before its
//   title, back, Escape and the system's back back to the one before (back_under, panel_back), a press outside, its
//   close button or the sheet dragged down closing all of it.

///|
/// What opened a presenter: a node of the window's tree (`Node`), a rectangle of the window (x, y, w, h: a point is
/// one 0 by 0, where a right click was), or nothing (what is asked by no press of the person's).
pub(all) enum Anchor {
  Node(@view.View)
  At(Double, Double, Double, Double)
  Unanchored
}

///|
/// The same opener: the same node, the same rectangle, or both nothing.
pub impl Eq for Anchor with equal(self, other) {
  match (self, other) {
    (Anchor::Node(a), Anchor::Node(b)) => a.id() == b.id()
    (Anchor::At(x, y, w, h), Anchor::At(x2, y2, w2, h2)) => x == x2 && y == y2 && w == w2 && h == h2
    (Unanchored, Unanchored) => true
    _ => false
  }
}

///|
/// What opened a menu or a pick, which stand beside it on Medium and Large (rule 3: the steps one
/// after another near each other): a node of the window's tree pressed (`Node`: beside it
/// where it is drawn, following it as it moves, the focus given back to it as it closes), or a rectangle of the window
/// (a right click's point). Never nothing: no page can open one beside nothing, as a dialog in the middle of the window.
pub(all) enum Beside {
  Node(@view.View)
  At(Double, Double, Double, Double)
}

///|
/// The same opener: the same node or the same rectangle (Anchor's).
pub impl Eq for Beside with equal(self, other) {
  self.anchor() == other.anchor()
}

///|
/// What opened it, as the presenters keep it.
pub fn Beside::anchor(self : Beside) -> Anchor {
  match self {
    Node(v) => Anchor::Node(v)
    At(x, y, w, h) => Anchor::At(x, y, w, h)
  }
}

///|
/// The point (`x`, `y`) of the window as what opened a presenter (a right click's).
pub fn at_point(x : Double, y : Double) -> Beside {
  At(x, y, 0.0, 0.0)
}

///|
/// One to pick (`pick`): what it is known by, its words, what it is (`note`: a sentence, a line under its words), what
/// it is at now (`value`: a word or two, a state, a count, at its row's end on its line), its icon (by name), or its
/// mark (`mark`: what marks it elsewhere, drawn as large as the row's mark column says: a station's, a maker's);
/// `disabled`: shown faint and not to be chosen (its note says why). A page says which each is; the presenter lays each
/// out as what it is, on every screen.
pub(all) struct Choice {
  key : String
  label : String
  note : String
  value : String
  icon : String
  mark : ChoiceMark?
  disabled : Bool
}

///|
/// What marks a choice (its `mark`), said as what it is, so that a sheet of the old frame and a panel of the window's
/// tree each draw it their own way (choice_mark, choice_mark_node): a station's (`OfStation`: its emoji and its icon,
/// station_icon's, this machine's or a station's where it has none (`here`), in `ink` as it is now), or a picture of
/// the app's by name (`Drawn`: a maker's, Slack's; in its own colours, Comma's one colour in the page's ink).
pub(all) enum ChoiceMark {
  OfStation(String, String, Bool, () -> Int64)
  Drawn(String)
}

///|
/// Choice mark `m` in `parent`, `size` across (choice_mark's, as nodes): a station's own mark where it has one, else
/// this machine's or a station's icon; a picture by its name.
#callsite(autofill(loc))
pub fn choice_mark_node(parent : @view.View, m : ChoiceMark, size : Double, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(b) {
    b.width(Is(Some(size))).height(Is(Some(size))) |> ignore
    match m {
      OfStation(emoji, icon, here, ink) =>
        if has_station_mark(emoji, icon) {
          station_mark_node(b, fn() { emoji }, fn() { icon }, size, ink, fn() { 0 })
        } else {
          icon_node(b, if here { "monitor" } else { "server" }, size, By(ink)) |> ignore
        }
      Drawn(name) => place_mark_node(b, name, size) |> ignore
    }
  })
  |> ignore
}

///|
pub fn choice(
  key : String,
  label : String,
  note? : String = "",
  value? : String = "",
  icon? : String = "",
  mark? : ChoiceMark,
  disabled? : Bool = false,
) -> Choice {
  { key, label, note, value, icon, mark, disabled }
}

///|
/// What a presenter shows.
priv enum Shows {
  /// a menu: its items (None a line between), its title ("" none), where a small panel lines up with what opened it
  /// and the side of it it stands on
  Menu(Array[MenuItem?], String, @ui.Along, @ui.Side)
  /// a pick: its title, the choices, the one chosen now, what choosing one does, where it lines up, the side it stands on,
  /// and whether a long one has a line to search them by
  Pick(String, Array[Choice], String, (String) -> Unit, @ui.Along, @ui.Side, Bool)
  /// a small panel, or with nothing that opened it a dialog (PanelOf)
  Panel(PanelOf)
  /// a confirm: its title, what it does, a warning, its action, whether that cannot be undone, what goes on once said
  Confirm(String, String, String, String, Bool, () -> Unit)
  /// a question: its title, the line at first, its placeholder, its action, the hint under it, whether a secret,
  /// whether an empty line can be said, what goes on with the line (trimmed)
  Ask(String, String, String, String, String, Bool, Bool, (String) -> Unit)
}

///|
/// A panel (panel_nodes'): its title ("" none), what it is about ("" nothing), how wide beside what opened it (or at
/// most, where it `fits` what it holds), whether a wide dialog; its title, its step's count and what it is about as they
/// are now (a wizard's), over those given; what it holds and its foot as nodes of the window's tree (`nodes`).
priv struct PanelOf {
  title : String
  description : String
  w : Double
  fits : Bool
  wide : Bool
  live : (() -> (String, String, String))?
  tall : Double
  grows : Bool
  focus : Bool
  ruled : Bool
  /// fade the panel and its contents together as it leaves
  fade_out_together : Bool
  form : Bool
  /// whether an upper-half anchored panel on Small may open as a popover beside its trigger (panel_nodes' `popover`)
  popover : Bool
  /// a picture shown alone over the window, its buttons under it (panel_nodes' `stage`)
  stage : Bool
  /// on a stage, what is chosen of the picture between it and its buttons (panel_nodes' `above`)
  above : ((@view.View) -> Unit)?
  /// beside what opened it, no head: what it holds draws its own (panel_nodes' `heads_itself`)
  heads_itself : Bool
  /// beside what opened it: on which side of it, along it where, how far from it (panel_nodes' `side`, `along`,
  /// `offset`), or flush with another small panel's outer box (`match_panel`: its serial, 0 none)
  side : @ui.Side
  along : @ui.Along
  offset : Double
  match_panel : Int
  /// beside what opened it, the page under it scrolled by the wheel while it stays open, its presses and keys still the
  /// panel's (panel_nodes' `scrolls_under`)
  scrolls_under : Bool
  /// what back does on its first step where its steps follow a flow kept elsewhere (panel_nodes' `back`)
  on_back : (() -> Unit)?
  /// what it holds and its foot as nodes of the window's tree
  nodes : PanelNodes
}

///|
/// What a panel presented by panel_nodes holds and what is at its foot, each made once as nodes of the window's tree in
/// the node the panel gives it, given what closes it.
priv struct PanelNodes {
  body : (@view.View, () -> Unit) -> Unit
  foot : ((@view.View, () -> Unit) -> Unit)?
  /// a share of the window tall (`tall`): as tall as what it holds up to that share, not that share whatever it holds
  hugs : Bool
  /// in the middle of the window (a dialog) as tall as what it holds up to its share, whatever `hugs` says on 小屏
  /// (panel_nodes' `hugs_centred`)
  hugs_centred : Bool
  /// beside what opened it on Medium/Large, hug content height up to `tall` when `hugs` is set (panel_nodes' `hugs_wide`)
  hugs_wide : Bool
  /// what it holds goes in steps in it, each made as nodes (panel_nodes' `steps`: panel_go_nodes, panel_back)
  steps : Bool
  /// where it heads itself (PanelOf's `heads_itself`), on a sheet too (the reader's layout): else headed there as ever,
  /// heading itself beside what opened it alone (panel_nodes' `heads_itself`)
  sheet_heads : Bool
  /// untitled, what it holds heads itself in the title's place in the middle of the window (panel_nodes' `heads_itself`)
  heads : Bool
  /// in the middle of the window, this share of its height down from its top, no close button, its room a row's (12)
  /// all round (panel_nodes' `top_share`; 0: in its middle as a dialog)
  top : Double
  /// beside what opened it, how tall what it holds shows at most before it scrolls in it (panel_nodes' `most`; None: as
  /// tall as the room beside what opened it leaves it)
  most : (() -> Double)?
  /// on a sheet across it, its column flush with the sheet's sides, what it holds laying out its own (a menu's and a
  /// pick's rows across it, a confirm's and a question's words as far in as a sheet's), as one a share of the window
  /// tall lays them out: sheet_node's `own_sides`
  flush : Bool
  /// on a sheet, what stands at the end of its title's line (panel_nodes' `head_end`)
  head_end : ((@view.View) -> Unit)?
}

///|
/// One presented: what it shows, what opened it, whether it is open (closed, it is drawn as it goes); the line written
/// in it (a question's, a pick's search).
priv struct Presented {
  serial : Int
  shows : Shows
  from : Anchor
  mut open : Bool
  line : @ui.Field
  /// what is let go of as it closes unsaid (back, Escape, a press outside, its close button), and whether it closed
  /// so or was said
  gone : () -> Unit
  mut ended : Bool
  /// how many pages a sheet of it has gone to (panel_page: each its count)
  mut steps_made : Int
  /// as a sheet of the window's tree: how tall it is drawn as it rises (sheet_node's `rises`), for a sheet under it
  /// pushed up out of its way (sheet_over)
  sheet_h : @signals.Signal[Double]
  /// as a sheet of the window's tree, as it closed: how tall it stood then (0 not drawn as one), what says so
  /// (`stands_now`, asked by close_from)
  mut stands : Double
  mut stands_now : (() -> Double)?
  /// closed, its going not yet seen by the window's tree (close_from; unsaid as presented_nodes takes the change):
  /// what is presented meanwhile (what was chosen or pressed in it opened another) comes in its place
  mut closed_now : Bool
  /// opened by a long-press hold (menu_held_node): stays a sheet on Small so the scrim lifts the held row
  held : Bool
  /// presented as a sheet closed whose going was not yet seen: how tall that one stood. As a sheet too, this one comes
  /// in its place (sheet_node: there at once that tall, on to its own height, the scrim as it was), not from below as
  /// that one sinks across it
  in_place : Double?
  /// the serial of the one presented in its place (`in_place`'s; 0 none): drawn no more once that one is a sheet in it
  mut taken_by : Int
  /// closed by what was chosen or said in it (presented_nodes' `done`), not unsaid
  mut chosen : Bool
  /// whether an inline menu confirmation level on this presenter has already executed its confirm action (blocks re-entry and menu continuation)
  mut confirm_said : Bool
  /// a panel presented by what a panel held, which closed for it (a row of the chat's own sheet, its agent's card): a
  /// step further in from that one (the file's head: 弹层里往里走), which is kept here, drawn no more; back from this
  /// one (its back key, the system's back, Escape) puts that one back in its place (back_under), a press outside or
  /// the sheet dragged down closes all of it
  mut under : Presented?
  /// a panel on a sheet: the panels a step further in from it that it closed for, each a page of the same sheet
  /// (panel_page: sheet_node's pages, each kept as it was left, sliding in over the one before); back takes the last
  /// off (panel_pop), a press outside or the sheet dragged down closes all of it
  more : @signals.Signal[Array[PanelPage]]
  /// a popover menu's pushed submenu or inline confirm levels (menu_push / menu_push_confirm: in-container horizontal
  /// slide inside the same glass menu shell); back pops the last level (menu_pop), while outside press or Escape closes
  /// the whole menu
  menu_more : @signals.Signal[Array[MenuLevel]]
}

///|
/// An inline confirmation level pushed onto an `AsPopover` menu.
priv struct MenuConfirm {
  words : String
  warning : String
  action : String
  danger : Bool
  run : () -> Unit
}

///|
/// What a menu level holds: either menu items (with per-row extras) or an inline confirmation view.
priv enum MenuLevelKind {
  MenuItems(Array[MenuItem?], (Int) -> MenuExtra)
  MenuConfirmLevel(MenuConfirm)
}

///|
/// A submenu or inline confirm level pushed onto an `AsPopover` menu (Presented's `menu_more`): its step number, title,
/// kind (items or confirm), and `gone` callback run when popped or dismissed unsaid.
priv struct MenuLevel {
  n : Int
  title : String
  kind : MenuLevelKind
  gone : () -> Unit
}

///|
/// A page of a sheet past its first (Presented's `more`): its number in it, its panel, what opened it, what is let go
/// of as it is left unsaid (gone back from, or the sheet closed with nothing chosen), and whether it is an inline confirm page.
priv struct PanelPage {
  n : Int
  x : PanelOf
  from : Anchor
  gone : () -> Unit
  is_confirm : Bool
  a11y_description : String
}

///|
/// How a presenter is drawn this frame (what a test reads).
// Debug for its tests
#warnings("-unused_value")
#derive(Eq, Debug)
priv enum How {
  AsSheet
  AsPopover
  AsDialog
}

///|
/// What is presented, the lowest first; how many were opened (each one's keys its own).
// kept across runs: put back by presenters_reset (parts_reset)
let presented_now : Ref[Array[Presented]] = Ref([])

///|
// kept across runs: put back by presenters_reset (parts_reset)
let presented_count : Ref[Int] = Ref(0)

///|
/// The serial of the presenter most recently opened or pushed onto (`panel_page`, `menu_push`).
// kept across runs: put back by presenters_reset (parts_reset)
let presented_last : Ref[Int] = Ref(0)

///|
/// What is presented as it was last told (presented_told): each one's serial, whether it is open, closed whether the
/// window's tree draws it still going out, the lowest first. What reads what is presented (the host, presented; presenting, the scrim's
/// owner, what of them the tree draws) built again as that changes, wherever it was asked from, not as what one of
/// them shows does (presented_items_of).
// kept across runs: put back by presenters_reset
let presented_said : Ref[@signals.Signal[Array[(Int, Bool, Bool)]]] = Ref(presented_said_new())

///|
fn presented_said_new() -> @signals.Signal[Array[(Int, Bool, Bool)]] {
  @signals.signal([], same=fn(a, b) { a == b })
}

///|
/// What each menu presented offers, as it was last told (presented_changed), by its serial: its items as they show
/// (label, icon, danger, disabled, chosen, heading), so that what draws them is built again as they show otherwise.
// kept across runs: put back by presenters_reset; one let go as it is
let presented_items_said : Map[Int, @signals.Signal[Array[(String, String, Bool, Bool, Bool?, Bool)?]]] = Map([])

///|
/// How `items` show, compared as they are given anew (presented_changed).
fn items_shown(items : Array[MenuItem?]) -> Array[(String, String, Bool, Bool, Bool?, Bool)?] {
  items.map(fn(x) { x.map(fn(m) { (m.label, m.icon, m.danger, m.disabled, m.chosen, m.heading) }) })
}

///|
/// The items of the menu presented as `serial` (`items`, where it keeps them), read: what reads them built again as
/// they are given anew showing otherwise (presented_changed).
fn presented_items_of(serial : Int, items : Array[MenuItem?]) -> Array[MenuItem?] {
  let s = match presented_items_said.get(serial) {
    Some(s) => s
    None => {
      let s = @signals.signal(items_shown(items), same=fn(a, b) { a == b })
      presented_items_said[serial] = s
      s
    }
  }
  s.get() |> ignore
  menu_clean_items(items)
}

///|
/// The serial of the sheet presented in the place of each sheet (present's `in_place`), by that one's serial: what is
/// marked while one is drawn (a row held, lifted while its menu is up: presented_drawn_of) stays so while what took
/// its place is, and what took that one's.
// kept across runs: put back by presenters_reset; one let go as what it leads to is gone
let took_place : Map[Int, Int] = Map([])

///|
/// Which are drawn (open, or going), by their serials: told each as it comes or is gone (presented_drawn_of).
// kept across runs: put back by presenters_reset
let presented_drawn_said : Ref[@signals.Keyed[Int]] = Ref(@signals.keyed())

///|
fn presented_told() -> Unit {
  // (one closed, whether the tree draws it still going out: what the host lets go of as it is gone)
  @view.transition(fn() {
    presented_said.val.set(presented_now.val.map(fn(p) { (p.serial, p.open, !p.open && tree_presented.contains(p.serial)) }))
  })
}

///|
/// What one presented shows changed where it is kept (a menu's items given anew as they are now): what draws it told,
/// where they show otherwise.
pub fn presented_changed() -> Unit {
  for p in presented_now.val {
    match (p.shows, presented_items_said.get(p.serial)) {
      (Shows::Menu(items, _, _, _), Some(s)) => s.set(items_shown(items))
      _ => ()
    }
  }
}

///|
/// Whether the host draws over nothing of the app's this frame (presented's `alone`).
// kept across runs: said by the host each frame; put back by presenters_reset (parts_reset)
let presented_alone : Ref[Bool] = Ref(false)

///|
/// How each one open was drawn in the last frame, the lowest first.
// kept across runs: put back by presenters_reset (parts_reset)
let presented_how : Array[How] = []

///|
/// Whether the next presenter opened was triggered by a long-press hold (menu_held_node).
// kept across runs: consumed by present(); put back by presenters_reset
let presented_held : Ref[Bool] = Ref(false)

///|
/// Window ID each live presented overlay serial was opened in (process-wide, never window-swapped) so security
/// revocations can drop an overlay immediately from any window.
// kept across runs: cleared by presenters_reset, entries removed when dropped or left
let presented_window_of : Map[Int, Int] = Map([])

///|
/// Nothing presented (the app begun again).
pub fn presenters_reset() -> Unit {
  presented_now.val.clear()
  presented_window_of.clear()
  took_place.clear()
  tree_presented.clear()
  tree_as_sheet.clear()
  presented_popovers.clear()
  presented_drawn_said.val.set([])
  presented_items_said.clear()
  presented_said.val.set([])
  presented_count.val = 0
  presented_last.val = 0
  presented_alone.val = false
  presented_how.clear()
  presented_sheets.val = false
  presented_win_h.val = 0.0
  presented_held.val = false
  presented_sheet_rests.clear()
  presented_sheet_next.val = 0
  presented_sheet_ended.val = -1.0
  sheet_win_h.val = 0.0
  sheet_foot_covers.clear()
  sheet_foot_next.val = 0
  sheet_foot_ver.val.set(0)
}

///|
fn present(shows : Shows, from : Anchor, line? : String = "", gone? : () -> Unit = fn() {  }) -> Unit {
  let held_flag = presented_held.val
  presented_held.val = false
  let no_lower_closed = fn(old : Presented) -> Bool {
    match presented_now.val.search_by(fn(q) { q.serial == old.serial }) {
      Some(idx) => {
        for k in 0..<idx {
          if presented_now.val[k].closed_now {
            return false
          }
        }
        true
      }
      None => false
    }
  }
  let menu_can_push_sheet = fn(old : Presented) -> Bool {
    old.chosen &&
    !old.confirm_said &&
    choosing.val == old.serial &&
    old.shows is Menu(_, _, _, _) &&
    tree_presented.contains(old.serial) &&
    tree_as_sheet.get(old.serial).unwrap_or(false) &&
    !(old.more.untracked().last() is Some({ is_confirm: true, .. })) &&
    no_lower_closed(old)
  }
  let menu_can_push_popover = fn(old : Presented) -> Bool {
    old.chosen &&
    !old.confirm_said &&
    choosing.val == old.serial &&
    old.shows is Menu(_, _, _, _) &&
    tree_presented.contains(old.serial) &&
    !tree_as_sheet.get(old.serial).unwrap_or(false) &&
    !(old.menu_more.untracked().last() is Some({ kind: MenuConfirmLevel(_), .. })) &&
    no_lower_closed(old)
  }
  // (presented as a sheet closed, none drawn of that going yet (what was chosen or pressed in it presents this): in
  // that one's place, the topmost of them's; a menu, short pick, or confirm by what was chosen in a menu: a page of
  // that one's sheet. Resolved before `transient_dismiss_for_present` so in-place push keeps its anchor host alive.)
  let closed_sheet = presented_now.val.iter().filter(fn(q) { q.closed_now && q.stands > 0.0 && q.taken_by == 0 }).last()
  match (closed_sheet, shows) {
    (Some(old), Shows::Menu(items, title, _, _)) if menu_can_push_sheet(old) => {
      // (a page of that sheet, as a panel's step further in is)
      panel_page(old, menu_sheet_panel(old.serial, title, fn() { items }), from, gone)
      return
    }
    // (a short pick, the same: a page of that sheet, as its menu's further levels are)
    (Some(old), Pick(title, choices, chosen, choose, _, _, search)) if pick_menu_of(choices, search) &&
      menu_can_push_sheet(old) => {
      let serial = old.serial
      let page = sheet_nodes_panel(title, 0.0, fn(col, close) {
        sheet_pick_node(col, choices, chosen, @ui.Field::new(text=""), false, false, fn(k) {
          close()
          chosen_in(serial, fn() { choose(k) })
        })
      })
      panel_page(old, page, from, gone)
      return
    }
    // (a confirm from a sheet menu: a page of that sheet with `<` back to the menu; cancel closes the menu sheet)
    (Some(old), Confirm(title, words, warning, action, danger, run)) if menu_can_push_sheet(old) => {
      let serial = old.serial
      let next_n = old.steps_made + 1
      let a11y_desc = if warning == "" {
        words
      } else if words == "" {
        warning
      } else {
        words + "\n" + warning
      }
      let page = sheet_nodes_panel(title, 0.0, fn(col, _close) {
        sheet_confirm_node(
          col,
          words,
          warning,
          action,
          danger,
          fn() { dismissed_now(serial) },
          fn() { confirm_menu_run(serial, next_n, run) },
        )
      })
      panel_page(old, page, from, gone, is_confirm=true, a11y_description=a11y_desc)
      return
    }
    _ => ()
  }
  // (a menu, a short pick shown as one, or a confirm opened by choosing an item in an AsPopover menu: push as an
  // in-container level of the same menu, as every level further in from a menu goes in and back)
  let chosen_menu = presented_now.val.iter().filter(fn(q) { q.closed_now && q.chosen && q.taken_by == 0 }).last()
  match (chosen_menu, shows) {
    (Some(old), Shows::Menu(items, title, _, _)) if menu_can_push_popover(old) => {
      menu_push(old, items, title, gone)
      return
    }
    (Some(old), Pick(title, choices, chosen, choose, _, _, search)) if pick_menu_of(choices, search) &&
      menu_can_push_popover(old) => {
      menu_push(old, pick_menu_items(choices, chosen, choose), title, gone, extras=pick_menu_extras(choices))
      return
    }
    (Some(old), Confirm(title, words, warning, action, danger, run)) if menu_can_push_popover(old) => {
      menu_push_confirm(old, title, words, warning, action, danger, run, gone)
      return
    }
    _ => ()
  }
  // (a panel by what a panel on a sheet of the window's tree held, which closed for it: a page of that sheet)
  match (closed_sheet, shows) {
    (Some(old), Shows::Panel(x)) if old.chosen &&
      old.stands_now is Some(_) &&
      // (that sheet drawn still: not one the window's tree let go of as the window came to another screen)
      tree_presented.contains(old.serial) &&
      tree_as_sheet.get(old.serial).unwrap_or(false) &&
      sheet_panel_of(x) &&
      old.shows is Shows::Panel(_) => {
      panel_page(old, x, from, gone)
      return
    }
    _ => ()
  }
  transient_dismiss_for_present(from)
  let held = held_flag ||
    (match closed_sheet {
      Some(old) => tree_presented.contains(old.serial) && tree_as_sheet.get(old.serial).unwrap_or(false)
      None => false
    })
  presented_count.val += 1
  presented_last.val = presented_count.val
  match closed_sheet {
    Some(old) => {
      old.taken_by = presented_count.val
      took_place[old.serial] = presented_count.val
    }
    None => ()
  }
  // (a panel by what a panel held, which closed for it, no frame drawn of that going yet: a step further in from that
  // one, on a sheet or not)
  let under = match (presented_now.val.iter().filter(fn(q) { q.closed_now }).last(), shows) {
    (Some(old), Shows::Panel(x)) if old.chosen && !x.stage && old.shows is Shows::Panel(_) => Some(old)
    _ => None
  }
  // (what is presented written whole, then told as one change: what reads it as it is told finds it there)
  presented_window_of[presented_count.val] = @ui.current_window_id()
  presented_now.val.push({
    serial: presented_count.val,
    shows,
    from,
    open: true,
    line: @ui.Field::new(text=line),
    gone,
    ended: false,
    steps_made: 0,
    sheet_h: @signals.signal(0.0),
    stands: 0.0,
    stands_now: None,
    closed_now: false,
    held,
    in_place: closed_sheet.map(fn(old) { old.stands }),
    taken_by: 0,
    chosen: false,
    confirm_said: false,
    under,
    more: @signals.signal_ref([]),
    menu_more: @signals.signal_ref([]),
  })
  @signals.start_batch()
  presented_told()
  presented_drawn_said.val.set(presented_now.val.map(fn(p) { p.serial }))
  @signals.end_batch()
}

///|
/// A menu of `items` (None: a line between; parts.tsx Menu), opened by `from`: chosen, it closes and the item's
/// `select` goes on. `title` over them ("" none); `along`: how it lines up with what opened it beside it; `side`: the side
/// of what opened it it stands on as a small panel (a sheet's has none). `gone`: what is let go of as it closes with
/// nothing chosen (back, Escape, a press outside).
pub fn menu(
  items : Array[MenuItem?],
  from~ : Beside,
  title? : String = "",
  along? : @ui.Along = Start,
  side? : @ui.Side = Bottom,
  gone? : () -> Unit = fn() {  },
) -> Unit {
  present(Menu(items, title, along, side), from.anchor(), gone~)
}

///|
/// A link's menu (`href`), opened by `from`: open it (a web address's), copy it, each going on with `open` or `copy`.
/// Its words the screen's: touch's the phone's, keyboard and mouse's its context menu's.
pub fn link_menu(href : String, from~ : Beside, open : () -> Unit, copy : () -> Unit) -> Unit {
  let touch = native_input() is Finger
  let items : Array[MenuItem?] = []
  if href.has_prefix("https://") || href.has_prefix("http://") {
    items.push(
      Some(menu_item_of(t(if touch { "common.link.open" } else { "desktop.contextMenu.openLink" }), open, icon="external")),
    )
  }
  items.push(Some(menu_item_of(t(if touch { "common.link.copy" } else { "desktop.contextMenu.copyLink" }), copy, icon="copy")))
  menu(items, from~)
}

///|
/// A pick of one of `choices` (`chosen` the one now), titled `title` ("" none), opened by `from`: chosen, it closes and `choose`
/// goes on with its key. Longer than pick_search_from, a line to search them by is over them, unless not `search`
/// (a few steps of a number: nothing to look for, and no keyboard up for it).
pub fn pick(
  title : String,
  choices : Array[Choice],
  chosen : String,
  choose : (String) -> Unit,
  from~ : Beside,
  along? : @ui.Along = Start,
  side? : @ui.Side = Bottom,
  search? : Bool = true,
) -> Unit {
  present(Pick(title, choices, chosen, choose, along, side, search), from.anchor())
}

///|
/// A small panel titled `title` ("" none), opened by `from`, what it holds (`body`) and what is at its foot (`foot`)
/// made once as nodes of the window's tree, each in the node the panel gives it, given what closes it: beside what
/// opened it (panel_node: `w` wide there, under it by default, `side`, `along`, `offset` where it stands); opened by
/// nothing (Unanchored) or a `form` (what is filled in and said), a dialog in the middle of the window
/// (panel_centred_node: `description` under its title, `wide` 640 wide in place of 520; `live`: its title, its step's
/// count and what it is about as they are now, a wizard's). The window's tree draws it on every screen: on 小屏 a sheet
/// from the window's foot (sheet_node). `gone`: what is let go of as it closes unsaid (back, Escape, a press outside, its
/// close button), not by what `close` was given to. `tall`: what it holds fills the room it is given, this share of the
/// window (as a sheet that tall, beside what opened it at most that tall; 0: as tall as what it holds); `grows`: a long
/// list's, a sheet of it is dragged between half and nearly all of the window. Not `focus`: beside what opened it, the
/// focus stays where it is as it opens. `ruled`: its foot under a line across the panel, out to its sides. `hugs`: one
/// `tall` as tall as what it holds up to that share, as a sheet and a dialog in the middle of the window draw it, not
/// that share whatever it holds; `match_panel`: serial of a small panel whose outer box it goes beside while keeping its
/// own width `w`.
/// `steps`: what it holds goes in steps in it: a step in by panel_go_nodes, as what it holds is pressed, slides in over
/// the one before in the same dialog or sheet, back (its back key, Escape, the system's back) slides it off again, the
/// one before as it was left (steps_centred_node; on 小屏 the sheet's pages, sheet_node).
/// `back`: what back does on its first step where its steps follow a flow kept elsewhere.
/// `fits`, `heads_itself`, `fade_out_together`: beside what opened it, as wide as what it holds, `w` at most; no head of
/// the panel's, what it holds drawing its own (in the middle of the window too: its own head row in the title's place,
/// clear of the close button over its corner, untitled_clear_node); the panel and what it holds faded together as it
/// goes (what is behind it may show through while it goes, the model picker, 2026-11-02). `top_share`: in the middle of the window
/// across, that share of its height down from its top (⌘K's panel's 14%), over the night as a dialog, no close button
/// (Escape, back and a press outside close it), a row's room (12) in all round, its corner a pane's. `hugs_centred`: as
/// `hugs` in the middle of the window alone (a sheet on 小屏 keeps its share).
/// `most`: beside what opened it, what it holds that tall at most, scrolling in its own scroll past that (a popover's
/// list, as kit's in_room `most`); on 小屏 the sheet's room as ever.
/// `stage`: a picture to hand out shown alone, on every screen the same (stage_node): no panel round it, the window
/// under it the night (stage_scrim), what it holds laid out `w` wide (as it is handed out: one picture everywhere) in
/// the middle, drawn smaller where the window has not the room for it, 关闭 and its `foot`'s buttons under it on the
/// night; a press beside it, Escape and the back close it too; `above`, over those buttons, what is chosen of the
/// picture (the card to share's looks).
/// `popover`: opt in to opening as an anchored popover on Small when triggered in the upper half of the window
/// (non-stage, non-form, non-steps, non-growing, anchored); default `false` opens as a bottom sheet on Small.
/// `scrolls_under`: beside what opened it, a wheel that nothing in it moves goes on to the page under it, which scrolls
/// while the panel stays where it stands (a reading aid beside what is read); a press outside still closes it.
/// `head_end`: on a sheet, what stands at the end of its title's line (a quiet action of the whole panel's, as a panel
/// that heads itself beside what opened it has at its own head's end); not drawn where the panel has no such head.
pub fn panel_nodes(
  title : String,
  body : (@view.View, () -> Unit) -> Unit,
  from~ : Anchor,
  w? : Double = panel_w,
  fits? : Bool = false,
  heads_itself? : Bool = false,
  fade_out_together? : Bool = false,
  description? : String = "",
  foot? : (@view.View, () -> Unit) -> Unit,
  wide? : Bool = false,
  live? : () -> (String, String, String),
  gone? : () -> Unit = fn() {  },
  tall? : Double = 0.0,
  focus? : Bool = true,
  ruled? : Bool = false,
  form? : Bool = false,
  grows? : Bool = false,
  popover? : Bool = false,
  side? : @ui.Side = Bottom,
  along? : @ui.Along = Start,
  offset? : Double = panel_offset,
  hugs? : Bool = false,
  hugs_centred? : Bool = false,
  hugs_wide? : Bool = false,
  match_panel? : Int = 0,
  steps? : Bool = false,
  back? : () -> Unit,
  top_share? : Double = 0.0,
  most? : () -> Double,
  stage? : Bool = false,
  above? : (@view.View) -> Unit,
  head_end? : (@view.View) -> Unit,
  scrolls_under? : Bool = false,
) -> Unit {
  present(
    Panel({
      title,
      description,
      w,
      fits,
      wide,
      live,
      tall,
      grows,
      focus,
      ruled,
      fade_out_together,
      form,
      popover,
      stage,
      above,
      heads_itself,
      side,
      along,
      offset,
      match_panel,
      scrolls_under,
      on_back: back,
      nodes: { body, foot, hugs, hugs_centred, hugs_wide, steps, sheet_heads: false, heads: heads_itself, top: top_share, most, flush: false, head_end },
    }),
    from,
    gone~,
  )
}

///|
/// In a panel of nodes that goes in steps (panel_nodes' `steps`), as what it holds is pressed: a step in, in the same
/// panel, titled `title` (`description` under it), what it holds `body` and what is at its foot `foot` made as nodes
/// (each given what closes the panel), as tall as the panel's first step says (its `tall`, `hugs`): it slides in over
/// the step it is in, back (its back key, Escape, the system's back) taking it off again, back to the step before as it
/// was left; a press outside, the sheet dragged down, its close button close the panel, all its steps with it. `left`:
/// what is let go of as it is left for good (gone back from, or the panel closed), once. `back`: where the steps follow
/// a flow kept elsewhere (the core's wizard), what back does on it in place of taking it off (told to that flow, which
/// takes the step off as it goes: panel_back), as panel_go's; `live`: its title, which of the flow's steps it is and
/// what it is about as they are now, where they change while it shows.
pub fn panel_go_nodes(
  title : String,
  body : (@view.View, () -> Unit) -> Unit,
  description? : String = "",
  foot? : (@view.View, () -> Unit) -> Unit,
  left? : () -> Unit = fn() {  },
  back? : () -> Unit,
  live? : () -> (String, String, String),
) -> Unit {
  let steps_base = fn(q : Presented) -> (PanelOf, Anchor)? {
    let more = q.more.untracked()
    if more.length() > 0 {
      let pg = more[more.length() - 1]
      if pg.x.nodes.steps {
        Some((pg.x, pg.from))
      } else {
        None
      }
    } else {
      match q.shows {
        Panel({ nodes: { steps: true, .. }, .. } as x) => Some((x, q.from))
        _ => None
      }
    }
  }
  match presented_now.val.iter().filter(fn(q) { q.open && steps_base(q) is Some(_) }).last() {
    Some(p) =>
      match steps_base(p) {
        Some((x, from)) => {
          let n = x.nodes
          let step : PanelOf = {
            ..x,
            title,
            description,
            live,
            on_back: back,
            nodes: {
              body,
              foot,
              hugs: n.hugs,
              hugs_centred: n.hugs_centred,
              hugs_wide: n.hugs_wide,
              steps: true,
              sheet_heads: false,
              heads: false,
              top: 0.0,
              most: n.most,
              flush: n.flush,
              head_end: None,
            },
          }
          // (opened by what opened the stepping panel: on a sheet as far in as its first step, sheet_node's `pressed`)
          panel_page(p, step, from, left)
        }
        None => ()
      }
    None => ()
  }
}

///|
/// In a panel that goes in steps, as what it holds is pressed: back to the step before (its back key's), or to the step
/// `to` deep (1 the first: a step's work done, back where it began), the one on top sliding away over it: a page of a
/// sheet past its first taken off; a panel a step further in from another, which closed for it, back to that one; to
/// the step `to` deep, a step back at a time till it is that deep, in the same change. Whether there was one to go back
/// to.
pub fn panel_back(to? : Int) -> Bool {
  let back_one = fn() {
    match presented_now.val.iter().filter(fn(q) { q.open && (q.more.untracked().length() > 0 || q.under is Some(_)) }).last() {
      Some(p) => panel_pop(p) || back_under(p)
      None => false
    }
  }
  match to {
    None => back_one()
    Some(d) => {
      let mut went = false
      @signals.start_batch()
      while steps_in_now() > d && back_one() {
        went = true
      }
      @signals.end_batch()
      went
    }
  }
}

///|
/// How many steps deep the topmost open panel of nodes stands (1 its first): its sheet's pages, and the panels it is a
/// step further in from, each with its own.
fn steps_in_now() -> Int {
  fn deep(p : Presented) -> Int {
    1 +
    p.more.untracked().length() +
    (match p.under {
      Some(u) => deep(u)
      None => 0
    })
  }

  match presented_now.val.iter().filter(fn(q) { q.open }).last() {
    Some(p) => deep(p)
    None => 0
  }
}

///|
/// How many steps deep the topmost open panel of nodes stands (1 its first, 0 when none is open): pass to
/// `panel_back(to=...)` to return to a panel opened as a step inside another without unwinding past it.
pub fn panel_depth() -> Int {
  steps_in_now()
}

///|
/// Whether what is drawn now is a panel's body (the presenters', in whatever way it shows): what lays itself out as a
/// page's (a page's column in the window, the room over and under it the frame leaves) lays itself out in the panel's
/// room instead.
pub fn in_panel() -> Bool {
  panel_body_now.val > 0
}

///|
// kept across runs: counted up and down round what a panel's body draws (0 between them)
let panel_body_now : Ref[Int] = Ref(0)

///|
// kept across runs: a value (no field of it changes)
let sheet_column_box : @ui.Style = @ui.css("w=Full")

///|
/// How far in from the column a panel's body stands in its words go (each block of them, a row's), so they stand on
/// the panel's words' line wherever it is drawn: a row's padding in a small panel (its column at its padding: text_in),
/// what a sheet's rows leave of its words' 20 in a sheet a press opened (sheet_held: its column at its rows'), none
/// where the column is at the words' line already (a sheet opened by nothing) or outside a panel.
pub fn panel_words_in() -> @ui.Style {
  @ui.style(px=room(words_in_now.val))
}

///|
// kept across runs: a value (no field of it changes)
let no_card_out : @ui.Style = @ui.css("")

///|
// kept across runs: said by the presenters while a panel's body is drawn
let words_in_now : Ref[Double] = { val: 0.0 }

///|
/// The one presented last (what `close_presented_of` is given to close it).
pub fn last_presented() -> Int {
  presented_last.val
}

///|
/// Closes the one presented as `serial` (last_presented), and what is over it, as back does; nothing when it is gone
/// or going (closed already: what was opened over it since is not its).
pub fn close_presented_of(serial : Int) -> Unit {
  close_from_serial(serial)
}

///|
/// Immediately removes `presented_now[i..]` without an exit animation, running each entry's `gone` hook once.
fn drop_presented_from(i : Int) -> Unit {
  let dropped = presented_now.val[i:].to_owned()
  for p in dropped.rev() {
    p.open = false
    p.closed_now = false
    if !p.ended {
      p.ended = true
      gone_all(p)
    }
  }
  for p in dropped {
    let serial = p.serial
    presented_window_of.remove(serial)
    tree_presented.remove(serial)
    presented_items_said.remove(serial)
    tree_as_sheet.remove(serial)
    if !took_place.contains(serial) {
      let mut end = serial
      while true {
        match took_place.iter().find_first(fn(e) { e.1 == end }) {
          Some((from, _)) => {
            took_place.remove(from)
            end = from
          }
          None => break
        }
      }
    }
  }
  presented_now.val = presented_now.val[:i].to_owned()
  @signals.start_batch()
  presented_told()
  presented_drawn_said.val.set(presented_now.val.map(fn(p) { p.serial }))
  @signals.end_batch()
}

///|
fn drop_presented_in_window(serial : Int) -> Bool {
  let mut s = serial
  while true {
    match presented_now.val.search_by(fn(q) { q.serial == s }) {
      Some(i) => {
        drop_presented_from(i)
        return true
      }
      None =>
        match took_place.get(s) {
          Some(next) => s = next
          None => return false
        }
    }
  }
  false
}

///|
/// Immediately removes the presented overlay `serial` (and anything chained or stacked over it, such as a
/// confirmation dialog) without an exit animation, searching its owning window (or all open windows in this process).
/// Used when revoking sensitive dialogs on lock, cover, or switch so titles, labels, and plaintext vanish on frame 1.
pub fn drop_presented_of_any_window(serial : Int) -> Unit {
  let cur = @ui.current_window_id()
  match presented_window_of.get(serial) {
    Some(wid) => {
      if wid == cur {
        if drop_presented_in_window(serial) {
          return
        }
      } else {
        let mut found = false
        @ui.as_window(wid, fn() { found = drop_presented_in_window(serial) })
        if found {
          return
        }
      }
    }
    None => ()
  }
  if drop_presented_in_window(serial) {
    return
  }
  if cur != 0 {
    let mut found = false
    @ui.as_window(0, fn() { found = drop_presented_in_window(serial) })
    if found {
      return
    }
  }
  for w in @ui.windows_open_here() {
    let wid = w.0
    if wid != cur && wid != 0 {
      let mut found = false
      @ui.as_window(wid, fn() { found = drop_presented_in_window(serial) })
      if found {
        return
      }
    }
  }
}

///|
/// Whether anything presented is still drawn (open, or going).
pub fn presented_drawn() -> Bool {
  !presented_now.val.is_empty()
}

///|
/// Whether the one presented as `serial` is open (not going, nor gone).
pub fn presented_open_of(serial : Int) -> Bool {
  presented_now.val.iter().any(fn(p) { p.serial == serial && p.open })
}

///|
/// Whether the one presented as `serial` — or any sheet that took its place (`took_place`) — is still open
/// (not closing, nor gone), read reactively (`presented_said`).
pub fn presented_open_chain_of(serial : Int) -> Bool {
  presented_said.val.get() |> ignore
  let mut s = serial
  while true {
    if presented_now.val.iter().any(fn(p) { p.serial == s && p.open }) {
      return true
    }
    match took_place.get(s) {
      Some(n) => s = n
      None => break
    }
  }
  false
}

///|
/// Whether the one presented as `serial` is still drawn (open, or going).
pub fn presented_drawn_of(serial : Int) -> Bool {
  // (it, or the sheet that took its place, or the one that took that one's: a row's menu, then what its item opened)
  let mut s = serial
  while true {
    // (read so: what reads it built again as it is presented or gone, not as others are)
    presented_drawn_said.val.has(s) |> ignore
    if presented_now.val.iter().any(fn(p) { p.serial == s }) {
      return true
    }
    match took_place.get(s) {
      Some(n) => s = n
      None => break
    }
  }
  false
}

///|
/// Asks before `action` (parts.tsx Confirm): `title`, what it does (`words`), the cancel and
/// `action` (in red when `danger`: what cannot be undone). A `warning`, if given, is shown in red. Said, it closes and
/// `run` goes on.
pub fn confirm(
  title : String,
  words : String,
  action : String,
  run : () -> Unit,
  danger? : Bool = false,
  warning? : String = "",
  from? : Anchor = Unanchored,
) -> Unit {
  present(Confirm(title, words, warning, action, danger, run), from)
}

///|
/// Asks for a line: `title`, a field (`value` in it at first, `placeholder` while it is empty,
/// `hint` under it, as dots when `secret`), the cancel and `action`, which can be pressed once the line has words that
/// differ from `value` (Enter too); `empty`: an empty line too, where that says something (`hint` says what: a name
/// cleared to be given again). Said, it closes and `run` goes on with the line, trimmed.
pub fn ask(
  title : String,
  action : String,
  run : (String) -> Unit,
  value? : String = "",
  placeholder? : String = "",
  hint? : String = "",
  secret? : Bool = false,
  empty? : Bool = false,
  from? : Anchor = Unanchored,
) -> Unit {
  present(Ask(title, value, placeholder, action, hint, secret, empty, run), from, line=value)
}

///|
/// Whether a question's line can be said (ask): words other than it had at first, or none where `empty` lets it.
fn ask_can(words : String, value : String, empty : Bool) -> Bool {
  (words != "" || empty) && words != value
}

///|
/// Words asked of a thing that can take them where it is (a row's title renamed): with touch asked over the
/// page as `ask` does (the keyboard rising over the list would cover the row), with keyboard and mouse where it is: `here` makes
/// the thing its own field, which says the words itself.
pub fn ask_here(
  title : String,
  action : String,
  run : (String) -> Unit,
  here : () -> Unit,
  value? : String = "",
  placeholder? : String = "",
  hint? : String = "",
) -> Unit {
  if native_input() is Finger {
    ask(title, action, run, value~, placeholder~, hint~)
  } else {
    here()
  }
}

///|
/// Whether anything is presented now (the shell's own back waits while it is).
pub fn presenting() -> Bool {
  // (read: what asks is built again as one is presented or let go)
  presented_said.val.get() |> ignore
  presented_now.val.iter().any(fn(p) { p.open })
}

///|
/// Whether a presenter still occupies the screen, including its declared exit transition.
pub fn presenter_visible() -> Bool {
  presented_said.val.get() |> ignore
  !presented_now.val.is_empty()
}

///|
/// Closes everything presented, each going as it goes (a page opened from a link over all of it).
pub fn close_all_presented() -> Unit {
  close_from(0)
}

///|
/// Closes the topmost presented, as back does.
pub fn close_presented() -> Unit {
  for i = presented_now.val.length() - 1; i >= 0; i = i - 1 {
    if presented_now.val[i].open {
      close_from(i)
      return
    }
  }
}

///|
/// Closes the one at `i` and all over it (a pick a panel opened goes with the panel).
fn close_from(i : Int) -> Unit {
  // (what is closed written first, then told once: what reads it finds it whole)
  let mut closed = false
  for k in i..<presented_now.val.length() {
    let q = presented_now.val[k]
    if q.open {
      q.open = false
      q.closed_now = true
      closed = true
      // (a sheet of the window's tree: how tall it stands now, for what comes in its place)
      match q.stands_now {
        Some(f) => q.stands = f()
        None => ()
      }
    }
  }
  presented_told()
  // (what the event or frame that closed it presents comes in its place; once that is over, nothing more does, and
  // what is let go of then is: presented_left)
  if closed {
    closed_over(fn() {
      for q in presented_now.val {
        if !q.open {
          q.closed_now = false
        }
      }
      presented_left()
    })
  }
}

///|
/// What close_from leaves for once nothing more comes in the place of what it closed, while `closing_together` runs
/// (None otherwise): held till that is over.
// kept across runs: said only while closing_together runs, None again after it
let closing_held : Ref[Array[() -> Unit]?] = Ref(None)

///|
/// `f` left for once nothing more comes in the place of what close_from closed: the end of the event or frame that
/// closed it, or of `closing_together` where that holds it.
fn closed_over(f : () -> Unit) -> Unit {
  match closing_held.val {
    Some(held) => held.push(f)
    None => @ui.after_frame(f)
  }
}

///|
/// `f`, which closes a presented one and presents what comes in its place, as one: what close_from leaves for after it
/// is done once `f` is over, where `f` runs outside any event or frame too (a moment come on the window's tree's
/// timeline, ChoiceHeld::answer's), or what it closed would be let go of before what comes in its place is presented.
fn closing_together(f : () -> Unit) -> Unit {
  guard closing_held.val is None else { return f() }
  let held : Array[() -> Unit] = []
  closing_held.val = Some(held)
  f()
  closing_held.val = None
  for g in held {
    @ui.after_frame(g)
  }
}

///|
/// The one presented as `serial` dismissed by the hand at that moment (back, Escape, a press outside it: its layer told so,
/// @ui.Ctx::with_dismissed): where it is open still, it closes, and what is over it, and what it holds is let go of, once,
/// then; its view draws it going from the next frame on.
fn dismissed_now(serial : Int, back? : Bool = false) -> Unit {
  match presented_now.val.search_by(fn(q) { q.serial == serial }) {
    // (a step further in, gone back from: a submenu level popped, a page of its sheet taken off, or a panel back)
    Some(i) if back &&
      presented_now.val[i].open &&
      (menu_pop(presented_now.val[i]) || panel_pop(presented_now.val[i]) || back_under(presented_now.val[i])) => ()
    Some(i) if presented_now.val[i].open => {
      // (it and what is over it, each closed unsaid let go of once, from the top)
      let closing = presented_now.val[i:].to_owned().filter(fn(q) { q.open && !q.ended }).rev()
      for q in closing {
        q.ended = true
      }
      close_from(i)
      for q in closing {
        gone_all(q)
      }
    }
    _ => ()
  }
}

///|
/// Panel `x` (opened by `from`, `gone` as panel_nodes') presented by what a page of sheet `p` held, which closed the
/// sheet for it: a page of `p`, a step further in. `p`, closed as its page said so, is open again.
fn panel_page(
  p : Presented,
  x : PanelOf,
  from : Anchor,
  gone : () -> Unit,
  is_confirm? : Bool = false,
  a11y_description? : String = "",
) -> Unit {
  presented_last.val = p.serial
  p.open = true
  p.closed_now = false
  p.ended = false
  p.chosen = false
  p.confirm_said = false
  p.steps_made += 1
  // (how tall it stands now, for the page put on to set out from: sheet_node's `stood`, as panel_pop has it)
  match p.stands_now {
    Some(f) => p.stands = f()
    None => ()
  }
  // (a dialog in steps to its new step's height, from as it is now)
  @view.transition(fn() {
    match steps_reshaping.get(p.serial) {
      Some(f) => f()
      None => ()
    }
    p.more.set([..p.more.untracked(), { n: p.steps_made, x, from, gone, is_confirm, a11y_description }])
    presented_told()
  })
}

///|
/// Back on the page of `p` that shows where its steps follow a flow kept elsewhere (its `on_back`: panel_nodes' and
/// panel_go_nodes' `back`): told to that flow, which takes the page off as it goes (panel_back), or closes it. Whether
/// it was told.
fn flow_back(p : Presented) -> Bool {
  let more = p.more.untracked()
  let top = if more.length() > 0 {
    Some(more[more.length() - 1].x)
  } else {
    match p.shows {
      Panel(x) => Some(x)
      _ => None
    }
  }
  match top.bind(fn(x) { x.on_back }) {
    Some(f) => {
      f()
      true
    }
    None => false
  }
}

///|
/// The last page of sheet `p` taken off, back to the one before, where it is past its first: what it held let go of.
/// Whether one was.
fn panel_pop(p : Presented) -> Bool {
  let more = p.more.untracked()
  guard p.open && more.length() > 0 else { return false }
  let last = more[more.length() - 1]
  p.steps_made += 1
  // (how tall it stands now, for the page before to set out from: sheet_node's `stood`)
  match p.stands_now {
    Some(f) => p.stands = f()
    None => ()
  }
  @view.transition(fn() {
    match steps_reshaping.get(p.serial) {
      Some(f) => f()
      None => ()
    }
    p.more.set(more[:more.length() - 1].to_owned())
  })
  (last.gone)()
  true
}

///|
/// Pushes a submenu level onto an `AsPopover` menu `p` in place (same glass container, horizontal slide),
/// reopening `p` from the `closed_now` state set by choosing the parent item.
fn menu_push(
  p : Presented,
  items : Array[MenuItem?],
  title : String,
  gone : () -> Unit,
  extras? : (Int) -> MenuExtra = fn(_) { menu_no_extra },
) -> Unit {
  presented_last.val = p.serial
  p.open = true
  p.closed_now = false
  p.ended = false
  p.chosen = false
  p.confirm_said = false
  p.steps_made += 1
  // (its lines cleaned here as menu_clean_items does, each row kept with where it was given: what `extras` says of the
  // k-th given is said of the row it came to)
  let kept : Array[MenuItem?] = []
  let given_at : Array[Int] = []
  let mut rule = false
  for j, x in items {
    match x {
      None => rule = kept.length() > 0
      Some(_) => {
        if rule {
          kept.push(None)
          given_at.push(-1)
          rule = false
        }
        kept.push(x)
        given_at.push(j)
      }
    }
  }
  let kept_extras = fn(i : Int) {
    match given_at.get(i) {
      Some(j) if j >= 0 => extras(j)
      _ => menu_no_extra
    }
  }
  @view.transition(fn() {
    match steps_reshaping.get(p.serial) {
      Some(f) => f()
      None => ()
    }
    p.menu_more.set([..p.menu_more.untracked(), { n: p.steps_made, title, kind: MenuItems(kept, kept_extras), gone }])
    presented_told()
  })
}

///|
/// Pushes an inline confirmation level onto an `AsPopover` menu `p` in place (same glass container, horizontal slide).
fn menu_push_confirm(
  p : Presented,
  title : String,
  words : String,
  warning : String,
  action : String,
  danger : Bool,
  run : () -> Unit,
  gone : () -> Unit,
) -> Unit {
  presented_last.val = p.serial
  p.open = true
  p.closed_now = false
  p.ended = false
  p.chosen = false
  p.confirm_said = false
  p.steps_made += 1
  let serial = p.serial
  let level_n = p.steps_made
  let confirm : MenuConfirm = {
    words,
    warning,
    action,
    danger,
    run: fn() { confirm_menu_run(serial, level_n, run) },
  }
  @view.transition(fn() {
    match steps_reshaping.get(p.serial) {
      Some(f) => f()
      None => ()
    }
    p.menu_more.set([..p.menu_more.untracked(), { n: level_n, title, kind: MenuConfirmLevel(confirm), gone }])
    presented_told()
  })
}

///|
/// Executes an inline menu confirmation's `run` callback at most once, only if `serial` is still open and its topmost
/// level/page matches `level_n`. Closes the menu presenter and invokes `run()` outside `chosen_in` so `choosing.val`
/// stays `0` (preventing re-attachment to the consumed menu while still permitting Small Sheet `in_place` handoff).
fn confirm_menu_run(serial : Int, level_n : Int, run : () -> Unit) -> Unit {
  guard presented_now.val.search_by(fn(q) { q.serial == serial }) is Some(i) else { return }
  let p = presented_now.val[i]
  guard p.open && !p.ended && !p.confirm_said else { return }
  let as_sheet = tree_as_sheet.get(serial).unwrap_or(false)
  let top_matches = if as_sheet {
    match p.more.untracked().last() {
      Some(pg) => pg.n == level_n && pg.is_confirm
      None => false
    }
  } else {
    match p.menu_more.untracked().last() {
      Some(lv) => lv.n == level_n && lv.kind is MenuConfirmLevel(_)
      None => false
    }
  }
  guard top_matches else { return }
  p.confirm_said = true
  p.ended = true
  p.chosen = true
  close_from_serial(serial)
  run()
}

///|
/// Pops the topmost submenu level from `p` if open and past its first level, running its `gone` callback.
fn menu_pop(p : Presented) -> Bool {
  let more = p.menu_more.untracked()
  guard p.open && more.length() > 0 else { return false }
  let last = more[more.length() - 1]
  p.steps_made += 1
  @view.transition(fn() {
    match steps_reshaping.get(p.serial) {
      Some(f) => f()
      None => ()
    }
    p.menu_more.set(more[:more.length() - 1].to_owned())
  })
  (last.gone)()
  true
}

///|
/// What `p` holds let go of as it closes unsaid: its submenu levels', its pages', the last first, then its own.
fn gone_all(p : Presented) -> Unit {
  for lv in p.menu_more.untracked().rev() {
    (lv.gone)()
  }
  for pg in p.more.untracked().rev() {
    (pg.gone)()
  }
  (p.gone)()
}

///|
/// Back from `p`, a step further in from a panel (`under`): `p` closes unsaid (what it holds let go of), and the panel
/// it came from is presented again as it was presented (on a sheet, in `p`'s place), what that one came from under it
/// still. Whether it went back so.
fn back_under(p : Presented) -> Bool {
  guard p.under is Some(u) && p.open else { return false }
  guard presented_now.val.search_by(fn(q) { q.serial == p.serial }) is Some(i) else { return false }
  let closing = presented_now.val[i:].to_owned().filter(fn(q) { q.open && !q.ended }).rev()
  // (closed and the one before presented as one change: what draws `p` going finds that one in its place already)
  @signals.start_batch()
  for q in closing {
    q.ended = true
  }
  close_from(i)
  for q in closing {
    gone_all(q)
  }
  let before = presented_count.val
  present(u.shows, u.from, gone=u.gone)
  match presented_now.val.last() {
    Some(q) if presented_count.val > before => {
      q.under = u.under
      // (the pages it had past its first, with it)
      q.steps_made = u.steps_made
      q.more.set(u.more.untracked())
    }
    _ => ()
  }
  @signals.end_batch()
  true
}

///|
/// Which one presented dims what is under it (its serial; 0 none): one scrim however many are over one another (the
/// person's 2026-11-02: no darker for each). The lowest of those that dim (a sheet; a dialog in the middle, not a
/// stage, whose night is its own) open now, so what is over it is no darker and, it closed under one still open, the
/// one over it dims at once as it goes; none open, the lowest still drawn as it goes, its scrim fading with it. Read
/// as one is presented, closed or let go (`sheet`: whether they are drawn as sheets, the window Small).
fn scrim_owner(sheet : Bool) -> Int {
  presented_said.val.get() |> ignore
  let dims = fn(p : Presented) {
    match p.shows {
      Panel(x) if x.stage => false
      _ => presented_how_of(p, sheet) != AsPopover
    }
  }
  for p in presented_now.val {
    if p.open && dims(p) {
      return p.serial
    }
  }
  for p in presented_now.val {
    // (still drawn: told as it is let go)
    if dims(p) && presented_drawn_said.val.has(p.serial) {
      return p.serial
    }
  }
  0
}

///|
/// Whether the one presented as `serial` is a dialog with another open over it (it takes nothing then: dimmed over
/// itself, dialog_veil), read as one is presented or closed.
fn dialog_covered(serial : Int) -> Bool {
  presented_said.val.get() |> ignore
  match presented_now.val.search_by(fn(q) { q.serial == serial }) {
    Some(i) => {
      if !presented_now.val[i].open {
        return false
      }
      for k = i + 1; k < presented_now.val.length(); k = k + 1 {
        let q = presented_now.val[k]
        if q.open && presented_how_of(q, false) == AsDialog {
          return true
        }
      }
      false
    }
    None => false
  }
}

///|
/// How tall the topmost sheet open over the one presented as `serial` is, while it is open and one is (present_sheet's
/// covered, its `over`'s height): None otherwise.
fn sheet_over(serial : Int) -> Double? {
  presented_said.val.get() |> ignore
  match presented_now.val.search_by(fn(q) { q.serial == serial }) {
    Some(i) if presented_now.val[i].open => {
      for k = presented_now.val.length() - 1; k > i; k = k - 1 {
        let q = presented_now.val[k]
        if q.open && presented_how_of(q, true) == AsSheet {
          return Some(q.sheet_h.get())
        }
      }
      None
    }
    _ => None
  }
}

///|
/// Whether the one presented in sheet `p`'s place (`taken_by`) is a sheet too (the host's, present_sheet, or the
/// tree's, sheet_node), so in its place indeed: `p` is drawn no more.
fn taken_as_sheet(p : Presented) -> Bool {
  if p.taken_by == 0 {
    return false
  }
  for k = 0; k < presented_now.val.length(); k = k + 1 {
    let q = presented_now.val[k]
    if q.serial == p.taken_by && q.in_place is Some(_) && presented_how_of(q, true) == AsSheet {
      return true
    }
  }
  false
}

///|
/// How far apart a sheet pushed up and the sheet over it that pushed it stand (the scrim between them).
let pushed_gap : Double = 8.0

///|
/// How far up a sheet goes for a sheet `over` tall risen under it (the person's 2026-11-02: 「把上一层整个挤上去」,
/// 「往上推到上面被遮盖」, 「为啥叠着」): its foot, which reaches on under the window's (sheet_under), all of it over that
/// one, `pushed_gap` apart, its own foot's corners shown; what of it that takes past the window's top is cut off there.
fn push_of(over : Double) -> Double {
  over + sheet_under + pushed_gap
}

///|
/// What the shell once drew what is presented by (the old frame's host): what is presented is the window's tree's now
/// (presented_nodes), so it is told only whether nothing of the app's is under it (`alone`: a share over another app, a
/// sheet on the page's paper, not frosted). Called by the shell once a frame, at the window's top level.
pub fn presented(_c : @ui.Ctx, alone? : Bool = false) -> Unit {
  presented_alone.val = alone
}

///|
/// Whether what is presented is drawn as sheets (the window Small), as presented_nodes last told it.
// kept across runs: said by presented_nodes as the window comes to another screen; put back by presenters_reset
let presented_sheets : Ref[Bool] = Ref(false)

///|
/// The window's height as presented_nodes last told it, for choosing popover vs. sheet by trigger position on Small.
// kept across runs: said by presented_nodes; put back by presenters_reset
let presented_win_h : Ref[Double] = Ref(0.0)

///|
/// Share of window height above which an anchored trigger on Small opens a popover/dropdown instead of a bottom sheet.
let small_upper_share : Double = 0.5

///|
/// Vertical midpoint of `from` in window coordinates, or None when unanchored or not yet placed.
fn anchor_center_y(from : Anchor) -> Double? {
  match from {
    Node(v) => {
      let (_, y, _, h) = v.placed_window_now()
      if h > 0.0 || y > 0.0 {
        Some(y + h / 2.0)
      } else {
        None
      }
    }
    At(_, y, _, h) => Some(y + h / 2.0)
    Unanchored => None
  }
}

///|
/// Maximum non-separator item count for an upper-half `Menu` or non-searchable `Pick` on Small
/// to open as an anchored popover; longer lists use a bottom sheet instead.
let small_popover_menu_most : Int = 12

///|
/// Whether `shows` opened from `from` on Small uses a popover beside its trigger instead of a bottom sheet:
/// anchored short `Menu` (<= `small_popover_menu_most` items), short non-searchable `Pick`, and anchored
/// non-stage/non-form/non-steps/non-growing `Panel` explicitly opting in via `popover=true`, triggered in the upper half.
fn small_as_popover(shows : Shows, from : Anchor, held : Bool, win_h : Double) -> Bool {
  guard !held && win_h > 0.0 else { return false }
  guard anchor_center_y(from) is Some(cy) && cy < win_h * small_upper_share else { return false }
  match shows {
    Menu(items, _, _, _) =>
      items.iter().filter(fn(x) { x is Some(_) }).count() <= small_popover_menu_most
    Pick(_, choices, _, _, _, _, search) =>
      choices.length() <= small_popover_menu_most && pick_menu_of(choices, search)
    Panel(x) => x.popover && !x.stage && !x.form && !x.nodes.steps && !x.grows && from != Unanchored
    Confirm(_, _, _, _, _, _) | Ask(_, _, _, _, _, _, _, _) => false
  }
}

///|
/// What is presented as it is told (presented_said's change, as presented_nodes follows it, `sheet` the screen's): how
/// each open one is drawn (presented_how); each closed unsaid let go of, once, once the event or frame that closed it is
/// over; and what has gone let go (presented_left).
fn presented_followed(sheet : Bool, win_h : Double) -> Unit {
  presented_sheets.val = sheet
  presented_win_h.val = win_h
  presented_how.clear()
  for p in presented_now.val {
    if p.open {
      presented_how.push(presented_how_of(p, sheet))
    } else if !p.ended {
      p.ended = true
      @ui.after_frame(fn() { gone_all(p) })
    }
  }
  presented_how.shrink_to_fit()
  presented_left()
}

///|
/// What is presented and gone let go: each closed whose going the window's tree draws no more (its way out over, or
/// never shown), and a sheet another sheet took the place of (taken_as_sheet), once nothing more comes in its place
/// (`closed_now`, close_from): its levels let go, what led to it leading nowhere, what reads whether it is drawn told.
fn presented_left() -> Unit {
  let sheet = presented_sheets.val
  let gone = presented_now.val
    .filter(fn(p) {
      !p.open &&
      !p.closed_now &&
      (!tree_presented.contains(p.serial) || (sheet && p.stands > 0.0 && taken_as_sheet(p)))
    })
    .map(fn(p) { p.serial })
  guard !gone.is_empty() else { return }
  // (one closed unsaid whose letting go was not done yet: done now, as it goes)
  for p in presented_now.val {
    if gone.contains(p.serial) && !p.ended {
      p.ended = true
      gone_all(p)
    }
  }
  for serial in gone {
    presented_window_of.remove(serial)
    presented_items_said.remove(serial)
    tree_as_sheet.remove(serial)
    // (gone with none in its place: what led to it leads nowhere)
    if !took_place.contains(serial) {
      let mut end = serial
      while true {
        match took_place.iter().find_first(fn(e) { e.1 == end }) {
          Some((from, _)) => {
            took_place.remove(from)
            end = from
          }
          None => break
        }
      }
    }
  }
  presented_now.val = presented_now.val.filter(fn(p) { !gone.contains(p.serial) })
  @signals.start_batch()
  presented_told()
  // (what read whether one of them is drawn told: a row marked while its menu is, built again unmarked)
  presented_drawn_said.val.set(presented_now.val.map(fn(p) { p.serial }))
  @signals.end_batch()
}

///|
fn how_of(shows : Shows, from : Anchor, held : Bool, sheet : Bool, win_h : Double) -> How {
  match (sheet, shows) {
    (_, Shows::Panel(x)) if x.stage => AsDialog
    (true, _) => if small_as_popover(shows, from, held, win_h) { AsPopover } else { AsSheet }
    (false, Shows::Panel(x)) if from == Unanchored || x.form => AsDialog
    (false, Shows::Menu(_, _, _, _) | Pick(_, _, _, _, _, _, _) | Shows::Panel(_)) => AsPopover
    (false, Confirm(_, _, _, _, _, _) | Ask(_, _, _, _, _, _, _, _)) => AsDialog
  }
}

///|
/// How presented item `p` is drawn, honoring the sheet/popover decision frozen in `tree_as_sheet` when its node was made
/// so scrim ownership, stacking, and exit handling stay in sync even if the anchor moves or leaves.
fn presented_how_of(p : Presented, sheet : Bool) -> How {
  if sheet {
    match tree_as_sheet.get(p.serial) {
      Some(as_sheet) =>
        match p.shows {
          Panel(x) if x.stage => AsDialog
          _ => if as_sheet { AsSheet } else { AsPopover }
        }
      None => how_of(p.shows, p.from, p.held, true, presented_win_h.val)
    }
  } else {
    how_of(p.shows, p.from, p.held, false, presented_win_h.val)
  }
}

///|
/// Whether a pick of `n` has its search (the phone's run picker's and the web's chooser's, past a screenful).
pub let pick_search_from : Int = 8

///|
/// How far a small panel stands from what opened it, by default (the web's popovers' sideOffset: 6).
pub let panel_offset : Double = floating_trigger_gap

///|
/// A small panel's width beside what opened it, by default (parts.css.ts popover: 280, and what its rows' words came
/// further in by from their grounds when that went from 8 to text_in's 16, so they keep the room they had: a station's
/// row its tags, 2026-11-03).
pub let panel_w : Double = 280.0 + 2.0 * (text_in - corner_inset)

///|
/// What a pick's list holds at most before it scrolls in a small panel (the web's chooser: 320).
pub let pick_list_most : Double = 320.0

///|
/// The choices whose words or note hold every word of `query` (case aside), in their order; all of them for none.
fn pick_found(choices : Array[Choice], query : String) -> Array[Choice] {
  let words = query.split(" ").filter(fn(w) { !w.is_empty() }).map(fn(w) { w.to_owned() }).collect()
  if words.is_empty() {
    return choices
  }
  choices.filter(fn(x) {
    let hay = (x.label + "\n" + x.note + "\n" + x.value).to_lower()
    words.iter().all(fn(w) { hay.contains(w.to_lower()) })
  })
}

// ---------------------------------------------------------------------------
// The web's: a small panel beside what opened it, a dialog in the middle of the window

///|
/// A step's head in a dialog: as high as a titled dialog's head (dialog_head's, its close button over its corner now).
// kept across runs: a value (no field of it changes)
let dialog_step_head : @ui.Style = @ui.style(row=true, w=Full, align=ACenter, min_h=Fixed(dialog_close), pt=room(dialog_head_over))

///|
// kept across runs: a value (no field of it changes)
let stage_foot : @ui.Style = @ui.css("row gap=S2 align=ACenter justify=JCenter")

///|
/// Under what a stage holds: what is chosen of it (`above`) over its buttons, as far apart as the stage's parts.
// kept across runs: a value (no field of it changes)
let stage_under : @ui.Style = @ui.css("gap=S5 align=ACenter")

///|
/// How far what a stage holds stands from its buttons (the column's gap), and the stage from the window's edges.
let stage_gap : Double = @ui.Space::px(S5)

///|
let stage_margin : Double = @ui.Space::px(S6)

///|
/// What a dialog takes of a share of the window besides what it holds: the window's room round it, its padding over and
/// under (dialog_room, dialog_pad).
let dialog_frame_h : Double = dialog_room + dialog_pad + dialog_pad

///|
fn close_from_serial(serial : Int) -> Unit {
  match presented_now.val.search_by(fn(q) { q.serial == serial }) {
    // (one closed already, going: what was opened over it since is not its, as one opened as it went)
    Some(i) if presented_now.val[i].open => close_from(i)
    _ => ()
  }
}

///|
/// The menu whose item's choice is being done now (chosen_in: its serial; 0 none): what that choice may hold open as it
/// waits (choice_held).
// kept across runs: said only while a choice is done, 0 again after it
let choosing : Ref[Int] = Ref(0)

///|
/// What was chosen in the menu presented as `serial` done (`f`), closed for it already: while `f` runs, what it waits
/// for before it opens what it opens may hold that menu open (choice_held).
fn chosen_in(serial : Int, f : () -> Unit) -> Unit {
  let was = choosing.val
  choosing.val = serial
  f()
  choosing.val = was
}

///|
/// A menu held open as it was by what was chosen in it, while that waits for the core before it opens what it opens
/// (choice_held): still held, and what lets it go.
pub struct ChoiceHeld {
  priv serial : Int
  priv steps_made : Int
  priv mut on : Bool
}

///|
/// Said by what a menu's item does (its `select`, as it is chosen) where it waits for the core before it opens what it
/// opens (sfbase's press_wait): the menu it was chosen in, closed for the choice, is open again and stays as it was
/// meanwhile, the screen as it was (the coordinator of the migration's switches still: 其他成员的预设 closed its menu at
/// the press and opened the next 800 ms later, two changes for one press), till that opens what it waited for in its
/// place, a level of it as one opened at once would be (ChoiceHeld::close, chosen), or it gives up (unsaid). None
/// where no menu's choice is being done, or that one is gone.
pub fn choice_held() -> ChoiceHeld? {
  guard choosing.val > 0 else { return None }
  let target = choosing.val
  let mut found : Int? = None
  for k = 0; k < presented_now.val.length(); k = k + 1 {
    if presented_now.val[k].serial == target {
      found = Some(k)
      break
    }
  }
  match found {
    Some(i) if presented_now.val[i].shows is Menu(_, _, _, _) &&
      presented_now.val[i].closed_now &&
      !presented_now.val[i].confirm_said &&
      !(presented_now.val[i].menu_more.untracked().last() is Some({ kind: MenuConfirmLevel(_), .. })) &&
      !(presented_now.val[i].more.untracked().last() is Some({ is_confirm: true, .. })) => {
      let p = presented_now.val[i]
      // (open again as it was: closed for the choice in this same handler, no frame drawn of its going; as a level's
      // page put on reopens it, panel_page, menu_level)
      p.open = true
      p.closed_now = false
      p.ended = false
      p.chosen = false
      presented_told()
      Some({ serial: p.serial, steps_made: p.steps_made, on: true })
    }
    _ => None
  }
}

///|
/// What the menu was held for answered: as a change of its own at the answer's moment (the window's tree's), never
/// inside the answer that told it, which would settle at once what comes in the menu's place (@view.answering: the
/// menu's sheet a whole level taller in a frame), what the press opens (`go`) comes in its place, a level of it, the
/// menu closed for it, where what it was pressed in stays as it was (`still_pressed`) and the menu is held still;
/// else the menu closes unsaid and what it asked is let go of (`let_go`).
pub fn ChoiceHeld::answer(
  self : ChoiceHeld,
  still_pressed : () -> Bool,
  go : () -> Unit,
  let_go : () -> Unit,
) -> Unit {
  // (closed and what comes in its place presented as one: at a moment of its own, outside any event or frame)
  let done = fn() {
    closing_together(fn() {
      if still_pressed() && self.still() {
        self.close(chosen=true)
        chosen_in(self.serial, go)
      } else {
        self.close(chosen=false)
        let_go()
      }
    })
  }
  match @ui.view_tree() {
    Some(tree) => {
      let root = tree.root()
      root.at_moment(root.cause_at(), done) |> ignore
    }
    None => done()
  }
}

///|
/// Whether the menu is held still: open, nothing chosen in it, no level change or confirm, and not closed since.
pub fn ChoiceHeld::still(self : ChoiceHeld) -> Bool {
  self.on &&
  (match presented_now.val.search_by(fn(q) { q.serial == self.serial }) {
    Some(i) => {
      let p = presented_now.val[i]
      p.open && !p.ended && !p.confirm_said && p.steps_made == self.steps_made
    }
    None => false
  })
}

///|
/// Closes the held menu as chosen and runs `go` inside `chosen_in(self.serial, ...)` when still held so any
/// follow-up menu/pick/confirm opened by `go` (e.g. a deadline timeout in `press_wait`) keeps the menu source.
pub fn ChoiceHeld::close_then(self : ChoiceHeld, go : () -> Unit) -> Unit {
  guard self.still() else { return }
  closing_together(fn() {
    self.close(chosen=true)
    chosen_in(self.serial, go)
  })
}

///|
/// The menu let go of: closed for what was chosen in it (`chosen`: what is presented now comes in its place, a level of
/// it) or unsaid (what it holds let go of, as a press outside it would); nothing where it is held no more.
pub fn ChoiceHeld::close(self : ChoiceHeld, chosen~ : Bool) -> Unit {
  guard self.still() else {
    self.on = false
    return
  }
  self.on = false
  if chosen {
    match presented_now.val.search_by(fn(q) { q.serial == self.serial }) {
      Some(i) => {
        let p = presented_now.val[i]
        p.ended = true
        p.chosen = true
        close_from(i)
      }
      None => ()
    }
  } else {
    dismissed_now(self.serial)
  }
}

///|
/// What a choice is at now at its row's end (a word or two: 当前, 离线; 13, muted).
// kept across runs: a value (no field of it changes)
let pick_value : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, wrap=false)

///|
/// How much of the window a sheet takes at most: nearly all of it, up to just under the status bar (Sheet.kt's
/// largest detent), what it holds past that scrolling in it; and a long pick's (the run picker's: 66%). A confirm and a
/// question are as tall as what they hold, their buttons straight under their words (the person's 2026-11-02: 「为啥弹出
/// 的面板按钮跑那么高」, under a share of the window, PageParts.kt's 36% and 42%, they stood high over empty room).
pub let sheet_most : Double = 0.94

///|
let sheet_long_pick : Double = 0.66

///|
/// The window height in force while building what a sheet holds (0 outside a sheet).
// kept across runs: put back by presenters_reset
let sheet_win_h : Ref[Double] = Ref(0.0)

///|
/// The height of the window a sheet's body made of nodes is laid out by (sheet_window_h's), lent by sheet_node to it.
// kept across runs: what each sheet lends its body, let go with it
let sheet_win_lent : @view.Lent[() -> Double] = @view.Lent::new()

///|
/// The height of the window for what node `v` of a sheet's body made of nodes is laid out by (the
/// screen's full height while no field in the sheet has the focus, the room over the soft keyboard while one does);
/// outside a sheet, the window's.
pub fn sheet_window_h_node(v : @view.View) -> Double {
  match v.lent(sheet_win_lent) {
    Some(f) => f()
    None => v.window_h()
  }
}

///|
/// A step's back key (a dialog's close button's size), and how far its chevron (16) stands in from its edge: so far out
/// of the words' line it stands, its chevron on it.
let step_back_side : Double = dialog_close

///|
let step_back_in : Double = (dialog_close - 16.0) / 2.0

///|
/// A step's back key offset from the small panel's title line (panel_pad + text_in) to keep it concentric with r_menu.
let step_back_out_px : Double = r_menu - step_back_side / 2.0 - panel_pad - text_in

///|
/// A step's back key before a title's row of its own: concentric with the small panel's top-left corner (`r_menu`).
// kept across runs: a value (no field of it changes)
let step_back_out : @ui.Style = @ui.style(ml=room(step_back_out_px))

///|
/// A step's back key before a dialog's title in its head's row (dialog_head, its parts S3 apart): as far out of the
/// words' line, its chevron as near the title as a step's head has it (step_head_gap).
// kept across runs: a value (no field of it changes)
let dialog_back_at : @ui.Style = @ui.style(ml=room(-step_back_in), mr=room(@ui.Space::px(S1) - @ui.Space::px(S3)))

///|
// kept across runs: a value (no field of it changes)
let step_head_gap : @ui.Style = @ui.css("gap=S1")

///|
/// Where a long list's sheet settles as it is dragged (and nearly all of the window).
// kept across runs: a table, never written
let sheet_grows_to : Array[Double] = [0.55, sheet_most]

///|
/// A sheet's row's check (14).
let sheet_row_check : Double = 14.0

///|
/// The room left in a sheet of a share (a long pick's list).
// kept across runs: a value (no field of it changes)
let sheet_grows : @ui.Style = @ui.style(w=Full, h=grow)

///|
// kept across runs: a value (no field of it changes)
let sheet_title_row : @ui.Style = @ui.css("row w=Full pt=S1 pb=S2_5 align=ACenter").then(@ui.style(px=room(sheet_panel_sides)))

///|
// kept across runs: a value (no field of it changes)
let sheet_title_words : @ui.TextStyle = @ui.text_style(size=Title, weight=Bold, color=Fg)

///|
/// How far in from a sheet's sides its rows are (sheet_rows' px).
let sheet_row_sides : Double = panel_card_in

///|
/// A line between a sheet's rows (a menu's None): the line's colour, 8 in from the rows' ground, 4 over and under.
// kept across runs: a value (no field of it changes)
let sheet_rule : @ui.Style = rule_line.then(@ui.css("mx=S2 my=S1"))

///|
/// Between a sheet's row's mark and its words (sheet_row_box's S3).
let sheet_row_gap : Double = 12.0

///|
/// A sheet's row's words: one line, cut short where the row has not the room for them, saying so (a long name in a
/// menu's 编辑「X」 or 复制「X」为我的预设).
// kept across runs: a value (no field of it changes)
let sheet_row_words : @ui.TextStyle = @ui.text_style(wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let sheet_row_note : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted)

///|
/// What a panel holds in a sheet: 20 in from its sides as the phone's sheets' words are (PageParts.kt confirm, ask;
/// Composer.kt askToShare), 24 under.
// kept across runs: a value (no field of it changes)
let sheet_panel : @ui.Style = @ui.style(w=Full, px=room(sheet_panel_sides), pb=room(sheet_panel_foot), gap=S2_5)

///|
/// What a sheet's panel leaves under what it holds, its foot (sheet_panel): 24.
pub let sheet_panel_foot : Double = 24.0

///|
/// What a panel a share of the window caps holds in a sheet: the room the sheet leaves it, its foot under it.
// kept across runs: a value (no field of it changes)
let sheet_capped_room : @ui.Style = sheet_grows.then(@ui.style(pb=room(sheet_panel_foot)))

///|
/// What a panel opened by a press holds in a sheet: 16 in at its sides (sheet_row_sides, as its cards are), 24 under.
// kept across runs: a value (no field of it changes)
let sheet_held : @ui.Style = @ui.style(w=Full, px=room(sheet_row_sides), pb=S6)

///|
/// The same with a foot under it (the foot's room under it, not its own).
// kept across runs: a value (no field of it changes)
let sheet_held_sides : @ui.Style = @ui.style(w=Full, px=room(sheet_row_sides))

///|
/// How far in from a sheet's sides what a panel opened by nothing holds is (sheet_panel's px).
let sheet_panel_sides : Double = panel_words

///|
/// A confirm's and a question's words (ask): 20 in, 10 apart.
// kept across runs: a value (no field of it changes)
let sheet_words_at : @ui.Style = @ui.style(w=Full, px=room(sheet_panel_sides), gap=S2_5)

///|
/// What a panel says under its title on a sheet (its description), as far over what it holds as a dialog's
/// (dialog_body's pt): none between them left it pressed against what came first (pengxiao, 2026-11-16: the relay's
/// bots right under its words).
// kept across runs: a value (no field of it changes)
let sheet_lead_at : @ui.Style = sheet_words_at.then(@ui.css("pb=S4_5"))

///|
// kept across runs: a value (no field of it changes)
let sheet_lead : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=Muted)

///|
// kept across runs: a value (no field of it changes)
let sheet_warning : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=Danger)

///|
// kept across runs: a value (no field of it changes)
let sheet_hint : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted)

///|
/// A panel's buttons in a sheet (its foot): 20 in, as far under what is over them (the line over a run picker's foot,
/// a form's last field) as over the sheet's foot, 24, across it (each its share: parts.mbt foot_fills), 8 apart.
// kept across runs: a value (no field of it changes)
let sheet_foot_at : @ui.Style = @ui.css("row w=Full px=S5 pt=S6 pb=S6 gap=S2 align=ACenter justify=JEnd")

///|
/// The same under a ruled foot (`sheet_foot_rule`): as far under the rule as the rule is under what is over it, 16 over
/// the sheet's foot.
// kept across runs: a value (no field of it changes)
let sheet_ruled_foot_at : @ui.Style = @ui.css("row w=Full px=S5 pt=S3 pb=S4 gap=S2 align=ACenter justify=JEnd")

///|
/// The line over a ruled panel's foot (`panel`'s `ruled`), across the panel: a hairline, the line's colour faded.
// kept across runs: a value (no field of it changes)
let foot_rule : @ui.Style = rule_line

///|
/// The same in a sheet: as far under what it holds as its rows are in from its sides (sheet_held_sides: 12).
// kept across runs: a value (no field of it changes)
let sheet_foot_rule : @ui.Style = rule_line.then(@ui.style(mt=room(sheet_rule_over)))

///|
let sheet_rule_over : Double = 12.0

///|
/// A small panel's foot (beside what opened it): a row, its buttons at its end, 8 apart, 8 under what is over them;
/// what it holds over it, as tall as the panel is made, the rest.
// kept across runs: a value (no field of it changes)
let panel_foot_at : @ui.Style = @ui.css("row w=Full pt=S2 gap=S2 align=ACenter justify=JEnd")

///|
/// The room a panel leaves over its foot's buttons (panel_foot_at's pt) for what scrolls at its body's end to go on
/// into (panel_fades_past): none over a ruled foot (its line stays clear of it; the body's padding over the line the
/// room then) or without a foot.
fn panel_foot_room(footed : Bool, ruled : Bool) -> Double {
  if footed && !ruled {
    @ui.Space::S2.px()
  } else {
    0.0
  }
}

///|
// kept across runs: a value (no field of it changes)
let panel_grows : @ui.Style = @ui.style(w=Full, h=grow)

