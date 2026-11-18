// Where a chat's page made as nodes opens its list (the old list's list_after, put in place once), out of what is known
// as the list is made: its rows, the chat's view, where it was left this run (sfbase's kept_places, chat_read_node's),
// the screen's scale. Asked once, as the list is made (chat_body_node), never as it is laid out.

///|
/// Where a chat's list of rows `rows` (chat view `v`'s, the list `w` wide) opens, as the row's key and where it stands
/// (ChatStandAt: where a place kept has it in the list's window, or under what covers the list's top, `cover` tall: the
/// chat's bar, whatever it comes to be); None at its end. At its
/// unread line, the line `lead` under the list's top (`top`: the bar and the room under it), the room over its block
/// (chat_body_gap_room) over that; else where it was left this run (`kept`: the message
/// at its top as far under the list's window's top, as kept: sfbase's kept_place_under), unless it was left at its end
/// with nothing come since (its last message the one its end was then: at its end; something come since is read from
/// where it was left, as the old list's left_at_end); of a message drawn in pieces, the piece that was at its top as
/// far under the window's top, where the place says it (`piece`; else the message's first, as far as `offset` says);
/// else where the core says it was left (`v.at`: the first message at or after it, its top `v.at_offset` under the
/// window's top in the screen's pixels of `scale`, as kept; else what is read in it at the list's top, the room over its
/// block over that, as a go-to puts it: chat_goes_to).
fn chat_open_place(
  list : ChatBodyList,
  v : ChatView,
  kept : @sfbase.KeptPlace?,
  scale : Double,
  cover : Double,
  top : Double,
  lead : Double,
  w : Double,
) -> (String, ChatStandAt)? {
  let rows = list.read()
  let gap = fn(k : String) {
    match rows.get(k) {
      Some(row) => chat_body_gap_room(row.gap, w)
      None => 0.0
    }
  }
  if rows.get("line") is Some(_) {
    return Some(("line", UnderBar(gap("line") - (top - cover) - lead)))
  }
  // (its last message, looked for from its end)
  let mut newest = -1.0
  let mut i = rows.keys.length() - 1
  while i >= 0 {
    match rows.get(rows.keys[i]).map(fn(row) { row.entry }) {
      Some(Said(m)) => {
        newest = m.seq
        break
      }
      _ => i = i - 1
    }
  }
  if kept is Some(p) && p.bottom >= 0.0 && p.bottom == newest {
    return None
  }
  // (the first message's row that is one `want` takes, by its key)
  let said = fn(want : (Message) -> Bool) {
    rows.keys.iter().find_first(fn(k) { rows.get(k) is Some(row) && row.entry is Said(m) && want(m) })
  }
  if kept is Some(p) && said(fn(m) { m.seq == p.top }) is Some(k) {
    return Some(
      match chat_piece_kept(rows, k, p.piece) {
        // (the piece it was at, still one: that piece's top where it was)
        Some(pk) => (pk, AtWindow(p.piece_offset))
        // (none said, or the message drawn otherwise now: the whole message's top where it was)
        None => (k, AtWindow(p.offset))
      },
    )
  }
  guard v.at is Some(at) && said(fn(m) { m.seq >= at }) is Some(k) else { return None }
  Some(
    (
      k,
      match v.at_offset {
        Some(px) => AtWindow(px / scale)
        None => UnderBar(gap(k) - (top - cover))
      },
    ),
  )
}
