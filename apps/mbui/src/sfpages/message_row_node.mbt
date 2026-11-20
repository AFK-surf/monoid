// A row of a chat's list as a node of the window's tree (chat_list.mbt row_box's, the row's half of it): the node it
// is, found by its key (sfbase's Entry::id: `m:<ts>`, `o:<id>`, `act:<agent>`, `state`, `older`, `newer`, `empty`,
// `line`), and its room: in from the pane's sides to the column, the room over it. What lights a message (its band as
// it is gone to, as its menu is open) is no row's: the list draws it under all the rows of the message, once
// (chat_body_bands). A row writes nothing for anything else (what else needs to know of a row reads it by its key in
// the chat's view).

///|
/// A row of a chat's list as made: its key (Entry::id) and its outermost node, what is anchored on it (a menu, the bar
/// over picked words, where words sent land) anchored there; whether its own ⋯'s menu is open (as that changes; never,
/// for a row with none: what is laid over it lit meanwhile, by what draws that).
// the chat's page as nodes: held by its tests, not used by the app yet
#warnings("-unused_field")
priv struct MessageRowNode {
  key : () -> String
  node : @view.View
  menu_on : () -> Bool
}

///|
/// What the words node `v` holds are of, said whole (@ui.picked_of's: quoted by it, all of them taken by 全选,
/// chat_quote_node), as its row's key `of` is now: a block put by and taken for another row (View::scrolls_window's
/// `reused`) that row's.
fn picked_of_by(v : @view.View, of : () -> String) -> Unit {
  v.reacts(of, fn(k) { @ui.picked_of(v, k, whole=true) |> ignore })
}

///|
/// Which kind of room over a row `room` is (chat_body_gap_room's): 0 none, 1 a joined one's, 2 the gap between
/// messages, whichever of its two widths.
fn row_top_kind(room : Double) -> Int {
  if room <= 0.0 {
    0
  } else if room <= joined_gap {
    1
  } else {
    2
  }
}

///|
/// A row's room in `parent` (row_box's): `top` over it (as that changes: none, joined_gap, list_gap),
/// in from the pane's sides by `side` each (as the list's width gives it: row_side's; the trailing side the system's
/// inset beside its bars, native_row_inset's), its body made by `body` in the column's middle, as wide as is left. Its
/// key as it is now: a block put by and taken for another row (View::scrolls_window's `reused`) that row's.
fn message_row_frame_node(
  parent : @view.View,
  key : () -> String,
  side : () -> Double,
  top : () -> Double,
  body : (@view.View) -> Unit,
) -> MessageRowNode {
  let node = parent.box(fn(root) {
    // (across all of the list, as the old row's column (row_column): its look said once, no binding for what never
    // changes)
    root.fills_across(Is(true)) |> ignore
    // (the room over it, as the row before it says: one kind of room in the other's place as that changes (none, a
    // joined one's, the gap between messages), the row's own structure, its way the column's; the list's way of it with
    // its neighbours' once it holds a block's. How tall that kind is follows the list's width at once: the narrow
    // list's gap for the wide's is what the window or the system's bars did, no motion of the row's (sf/motion.mbt).
    // Picked by the room itself, a list narrowed under chat_narrow_w by the bars the system took made its way from
    // the wide gap to the narrow, laid out none till its end, then stepped there: chat_pops_wbtest's 中屏 beside them)
    // (the room laid out anew at another width as the page's column sets off on its way to it (a side panel sliding in
    // or out: sfbase's column_sets_off), its height going on its list's way from that moment, what is under it in the
    // row with it, never a step of the gap's in the frame it sets off)
    root.pick(fn() { row_top_kind(top()) }, fn(gap, _) {
      gap.height(By(fn() { Some(top()) })) |> ignore
      @sfbase.column_set_off_each(gap, fn() {
        if gap.alive() {
          let over = @sfbase.column_set_off_over()
          if over > 0.0 {
            gap.resizes(spec=(@ui.move_ms(over), fn(p) { @ui.Ease::Move.at(p) })) |> ignore
          } else {
            gap.resizes() |> ignore
          }
        }
      })
    })
    // (its middle, as wide as the list less its sides, those its padding: the old row's line and its middle
    // (row_line, row_middle) one node, no box of room either side)
    root.box(fn(m) {
      m
      .fills_across(Is(true))
      .padding(By(fn() { (side(), 0.0, if @sf.native_side() { native_row_inset() } else { side() }, 0.0) }))
      |> ignore
      body(m)
    })
    |> ignore
  })
  { key, node, menu_on: fn() { false } }
}

///|
/// How long a small part of a chat's row that holds words fades where it is as it goes, one in its place seen once that
/// is gone and its place holds it whole (View::pick's `leave`, pick_leave.mbt; the coordinator of the migration,
/// 2026-11-13: no words of it cut by its way): what goes from a list, as long (@sf.leave_ms). A fold stays a fold, and
/// what a row shows only while it is the last of its run goes at once (mine_said_node's `lone`).
let msg_part_leave_ms : Double = @sf.leave_ms
