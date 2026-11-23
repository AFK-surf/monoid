// An agent's and a chat's quiet cards in a panel (the app's sheets over a chat: its info, an agent's card, its jobs;
// Android's ChatInfo.kt InfoList, InfoRow, AgentSheet.kt AgentTiles), as nodes of the window's tree made once: a card
// of rows on the ink at 5% (quiet_card_node), each row the ladder's inset in, its ground round as a row of the ladder's
// under the finger (quiet_row_node); a row's label in a column as wide as the widest of them (row_label_node,
// labels_across), its chevron and what stands beside its words on their first line (quiet_first_line); and the card of
// what an agent did and the figures that say most, each part of it opening its room as what it says comes
// (stats_card_node, reveal_part_node). The app gives what they say; these, how.

///|
/// A card of quiet rows round them: a card of the ladder's (what it holds is content: a model's tile, its words, its
/// allowance), its rows the ladder's inset in, so their words and tiles 16 in from its edges; the ink at 5%.
// kept across runs: a value (no field of it changes)
pub let quiet_card_style : @ui.Style = @ui.css("w=Full bg=A(Fg,O5) clip").then(@ui.style(p=room_of(corner_inset)))

///|
/// A quiet card's corner (a card of the ladder's), and its rows' (a row of the ladder's).
pub let quiet_card_corner : Double = card_corner

///|
pub let quiet_row_corner : Double = row_corner

///|
/// A row of a quiet card (Android InfoRow): 44 high at least, its words the ladder's inset in from its sides and 4 from
/// top and bottom, what it holds 12 apart.
// kept across runs: a value (no field of it changes)
pub let quiet_row_style : @ui.Style = @ui.css("row w=Full min_h=S11 py=S1 gap=S3").then(@ui.style(px=room_of(text_in)))

///|
/// A quiet row whose parts stand on its middle across (a row of one line).
// kept across runs: a value (no field of it changes)
pub let quiet_row_middle : @ui.Style = quiet_row_style.then(@ui.css("align=ACenter"))

///|
/// A quiet row whose parts stand on their tops (one with a line under its words: each part on their first line).
// kept across runs: a value (no field of it changes)
pub let quiet_row_top : @ui.Style = quiet_row_style.then(@ui.css("align=AStart"))

///|
/// A quiet row that leads with a tile (a model's mark): its tile the ladder's inset in from the row's top and start, so
/// round by the ladder's next step in the row's corner.
// kept across runs: a value (no field of it changes)
pub let quiet_row_tile : @ui.Style = @ui.style(p=room_of(corner_inset), align=AStart)

///|
/// A quiet row that leads with a dot `side` round, `over` under its words' top (a job's): the dot in the card's corner as
/// far from both its edges as makes it concentric with it (capsule_room), its words on the dot's line.
pub fn quiet_row_dot(side : Double, over : Double) -> @ui.Style {
  @ui.style(
    pl=capsule_room(quiet_card_corner, side, less=corner_inset),
    pt=capsule_room(quiet_card_corner, side, less=corner_inset + over),
  )
}

///|
/// A quiet card (info_list's) in `parent`: the ladder's card, its rows the ladder's inset in, `panel_card_in` from the
/// panel's sides; `last`: the last of what a dialog holds, its foot concentric with the dialog's (panel_card_last_node's
/// under it). What `rows` makes on it.
#callsite(autofill(loc))
pub fn quiet_card_node(
  parent : @view.View,
  rows : (@view.View) -> Unit,
  last? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(k) {
    if in_small_panel_node(k) {
      style_node(k, fn() { @ui.css("w=Full") })
    } else {
      style_node(k, fn() {
        let card = quiet_card_style.then(panel_card_out_node(k))
        if last() {
          card.then(panel_card_last_node(k))
        } else {
          card
        }
      })
      k.radius(Is(quiet_card_corner)) |> ignore
    }
    rows(k)
  })
  |> ignore
}

///|
/// A row of a quiet card (info_row's) in `parent`, laid out `look` (quiet_row_middle, or its tile's, its dot's, its
/// top's), its ground round as a row of the ladder's; what `body` makes in it; pressed (`press`; none: a row that leads
/// nowhere), `press` done, rippling round its corner, read out a button named `label`. Its node.
#callsite(autofill(loc))
pub fn quiet_row_node(
  parent : @view.View,
  label : () -> String,
  body : (@view.View) -> Unit,
  look? : @ui.Style = quiet_row_middle,
  press? : () -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(b) {
    let corner = if in_small_panel_node(b) { small_panel_inner(r_menu) } else { quiet_row_corner }
    style_node(b, fn() { look })
    b.radius(Is(corner)) |> ignore
    match press {
      Some(f) => rippled_node(loc~, b, f, corner, label)
      None => ()
    }
    body(b)
  })
}

///|
/// Node `c` as tall as a quiet row's words' first line at least (the Ui size's line on the theme, at the system's size
/// of words), what it holds down its middle: an icon, a label or a chevron beside its words stands on that first line,
/// never on the middle of all of them.
pub fn quiet_first_line(c : @view.View) -> Unit {
  c
  .min_height(By(fn() { Some(theme().t.ui_line * c.words_scale()) }))
  .shrink(Is(0.0))
  .lies_along(Is(Middle))
  |> ignore
}

///|
/// A quiet row's label in its column (agent_label's) in `row`: `label` in the Meta size, muted, on a line, `width` wide
/// as it is now (labels_across), at the row's start, on the baseline of its value's first line (a Ui line, as tall as
/// that line at least so a row on its middle keeps it there too: on_baseline).
#callsite(autofill(loc))
pub fn row_label_node(row : @view.View, label : String, width : () -> Double, loc~ : SourceLoc) -> Unit {
  row.box(made_for=loc, fn(l) {
    l
    .min_height(By(fn() {
      l.words_redone() |> ignore
      Some(node_sp(l, @ui.tree_theme().text_size(Ui).1))
    }))
    .shrink(Is(0.0))
    .width(By(fn() { Some(width()) }))
    .lines_up(Is(Some(Start)))
    |> ignore
    on_baseline(loc~, words_node(l, fn() { label }, fn() { quiet_row_label }), Ui, Meta) |> ignore
  })
  |> ignore
}

///|
/// A quiet row's label: Meta, muted, on a line.
// kept across runs: a value (no field of it changes)
pub let quiet_row_label : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
/// How wide a column of quiet rows' labels `labels` is in `v` (row_label_node's): as the widest of them in this
/// language and at the system's size of words, so the values beside them line up; worked out again as that changes.
pub fn labels_across(v : @view.View, labels : Array[String]) -> Double {
  v.words_redone() |> ignore
  let size = theme().t.meta * v.words_scale()
  labels.fold(init=0.0, fn(w, label) { dmax(w, @ui.text_advance(label, size~).ceil()) })
}

///|
/// A quiet row's chevron at its end (chevron's) in `parent`: 14, in the subtle ink.
#callsite(autofill(loc))
pub fn row_chevron_node(parent : @view.View, loc~ : SourceLoc) -> Unit {
  icon_node(loc~, parent, "chevron-right", quiet_chevron, By(fn() { theme().p.subtle })) |> ignore
}

///|
let quiet_chevron : Double = 14.0

///|
/// The card of what an agent did and the figures that say most (AgentSheet's) in `parent`, while `says()` says it says
/// anything: a quiet card out of the panel's sides (panel_card_out_node), each of `parts` a part of it there while its
/// own says so (what `make` makes in it), opening its room as what it says comes (reveal_part_node: the card read after
/// the panel rose, its top not stepping up as its height does), and the room of the panel's cards under it.
#callsite(autofill(loc))
pub fn stats_card_node(
  parent : @view.View,
  says : () -> Bool,
  parts : Array[(() -> Bool, (@view.View) -> Unit)],
  loc~ : SourceLoc,
) -> Unit {
  reveal_part_node(loc~, parent, says, look=fn(b) { panel_card_out_node(b) }, fn(c) {
    c.box(fn(k) {
      style_node(k, fn() { quiet_card_style })
      k.radius(Is(quiet_card_corner)) |> ignore
      for part in parts {
        let (shown, make) = part
        reveal_part_node(loc~, k, shown, make)
      }
    })
    |> ignore
    c.box(fn(g) { style_node(g, fn() { stats_card_under }) }) |> ignore
  })
}

///|
/// The room under a panel's stats card: as far as its sides are in (panel_card_in).
// kept across runs: a value (no field of it changes)
let stats_card_under : @ui.Style = @ui.style(h=Fixed(panel_card_in))

///|
/// A part of a card in `parent` (group_rows', as nodes) while `shown()` says so, what `make` makes in it: there whole
/// as it is made where it shows then; one that comes to show later opens its room from none to all of its height (a
/// Move as long as it is tall, cut to the room it has so far), what is under it going down with it, and closes again
/// as it goes; its words faded in from half as it opens (reveal's). `look`: where it stands (out of its column).
#callsite(autofill(loc))
pub fn reveal_part_node(
  parent : @view.View,
  shown : () -> Bool,
  make : (@view.View) -> Unit,
  look? : (@view.View) -> @ui.Style,
  loc~ : SourceLoc,
) -> Unit {
  // (where it starts said as it is made, by what a reader reads: a topic read outside any reader would be held by the
  // core's client for good)
  let share = @motion.NodeWay::new(0.0)
  let made = Ref(false)
  // (while it closes, what it holds still there, let go once it has)
  let closing = @signals.signal(false)
  let stop : Ref[() -> Unit] = Ref(fn() {  })
  parent.by_room(loc~, fn(b, room) {
    let inner : Ref[@view.View?] = Ref(None)
    let tall = fn() {
      match inner.val {
        Some(i) => room.tall(i)
        None => 0.0
      }
    }
    // (where what it holds stands out of its column (a card a panel's sides set), it stands so itself: cut to itself)
    match look {
      Some(l) => style_node(b, fn() { l(b) })
      None => ()
    }
    b.clips(Is(true)).height(By(fn() { Some(tall() * share.shown(b)) })) |> ignore
    inner.val = Some(
      b.box(fn(i) {
        i.alpha(By(fn() { 0.5 + 0.5 * share.shown(b) })) |> ignore
        i.show(at_once=true, fn() { shown() || closing.get() }, make)
      }),
    )
    b.reacts(shown, fn(on) {
      if !made.val {
        made.val = true
        share.put(if on { 1.0 } else { 0.0 })
        return
      }
      // (as far as it is tall once made: what has not been laid out yet goes as a row of words does)
      let far = dmax(@signals.untracked(tall), reveal_least)
      share.go(b, if on { 1.0 } else { 0.0 }, @motion.moved(points=far))
      (stop.val)()
      stop.val = fn() {  }
      if !on {
        closing.set(true)
        stop.val = b.at_moment(share.end(), fn() { closing.set(false) })
      }
    })
  })
  |> ignore
}

///|
/// How far a revealed part's way goes at least, where it has not been laid out yet as it comes: a row's.
pub let reveal_least : Double = 44.0
