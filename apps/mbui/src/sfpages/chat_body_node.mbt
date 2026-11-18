// A chat's messages as nodes of the window's tree, at rest (chat_list.mbt's chat_list as it stands, its rows'
// half): a page's list (View::scrolls_window) holding a block for each of its rows by the row's key (sfbase's
// Entry::id; what was sent from here going on by the key it was sent as once the core has it: row_keys'), each made
// once as it shows by its kind's row (chat_body_row), every row read through its key as the chat's view changes,
// never made again for that; the room over each row as the one before it says (top_at's), in from the pane's sides as
// the list's width lays it out (row_side), narrow or wide by that width alone.
// Not here, each where it comes in: what moves (a row coming in or going on the list's way, words sent flying in, a
// message coming out of its agent's picture, the room an agent's line leaves; the list's line's), the composer and
// what floats over the list (the bell, 对话目录's button and rail, the way to the newest) and what a message gone to shows of
// it (its flash through each row's `over`, a search's words marked in it) are chat_jump_node's, the page's; what else
// is laid over a row (words picked, the band of one whose menu is open: the overlays' line's), where the list opens (chat_open_place, asked here once as it is made) and what the core is told of
// what is read: those the page's, whether the list is at its foot read of its scroll (Scroll::at_foot_now), which rows
// show and how far down one is, which the list does not say yet.

///|
/// What a chat's list shows for each of its rows (chat_body_rows'): its key, what it is, the room over it.
priv struct ChatBodyRows {
  keys : Array[String]
  rows : Map[String, ChatBodyRow]
}

///|
/// A row of a chat's list: what it is (its entry as the chat's view says it now) and the room over it.
priv struct ChatBodyRow {
  entry : Entry
  gap : ChatBodyGap
  /// which of its message's blocks it draws (chat_body_pieces): from, up to (not), and whether it is the message's last
  /// piece; none, all of it
  piece : @sf.MdPiece?
}

///|
/// The room over a row (top_at's): none (the list's first, a row under its top's), joined_gap (a message close under
/// the one before), or the gap between messages (list_gap, narrow or wide).
#derive(Eq)
priv enum ChatBodyGap {
  NoGap
  Joined
  Apart
}

///|
/// What a chat's list keeps of its rows' keys as they go (row_keys' Reading's `sent` and `sent_as`), its own: the outbox
/// entry each message of the chat was sent from here as, by its seq; the key each row of the core's that took over
/// what was sent from here goes on by (the key it was sent as). Written only as
/// its keys are worked out (chat_body_rows, in the computed that does it), read by nothing else.
priv struct ChatBodyKept {
  sent : Map[Double, String]
  sent_as : Map[String, String]
  /// the keys what was sent from here goes by (as it was sent: kept as the core's row takes it over)
  here : Map[String, Bool]
}

///|
/// The rows chat view `v`'s entries `all` (the chat's list's: view_of_chat's) show, with what was sent from here the
/// core has not yet (`sending`, as sent: sfbase's sending_now) among them, by their keys: row_keys' keys (the core's
/// message sent from here by its outbox entry's key; what was sent from here, and the core's row that took it over
/// once it came, by the key it was sent as; the rest Entry::id), what is sent from here not in the chat yet after its
/// outbox and before where it stands and its agents' lines (sent_among's, its row before it followed where it is
/// joined), the agents whose card that answers at work after the rest (answered_at's), the room over each (top_at's).
/// Its Top and Foot are the list's room over and under its rows, not rows.
fn chat_body_rows(kept : ChatBodyKept, v : ChatView, all : Array[Entry], sending : Array[@sfbase.LocalSent]) -> ChatBodyRows {
  for o in v.outbox {
    if o.seq >= 0.0 {
      kept.sent[o.seq] = o.id
    }
  }
  for m in v.messages {
    if m.outgoing != "" {
      kept.sent[m.seq] = m.outgoing
    }
  }
  let core_keys = all.map(fn(e) {
    match e {
      Said(m) =>
        match kept.sent.get(m.seq) {
          Some(o) => "o:" + o
          None => e.id()
        }
      _ => e.id()
    }
  })
  let keys = core_keys.map(fn(k) { kept.sent_as.get(k).unwrap_or(k) })
  // what was sent from here: the first of the core's rows of this device's own not there as it was sent (an outbox
  // entry, or a message after the newest there then) takes it over, going on by its key (row_keys')
  let taken_by : Map[String, Bool] = Map([])
  for k in kept.sent_as.values() {
    taken_by[k] = true
  }
  let still : Array[@sfbase.LocalSent] = []
  for l in sending {
    let key = "o:" + l.row.id
    kept.here[key] = true
    if taken_by.contains(key) {
      continue
    }
    let mut came = false
    for i, e in all {
      let k = core_keys[i]
      let mine = match e {
        Out(_) => true
        Said(m) => m.mine && !m.system && m.seq > l.newest
        _ => false
      }
      if mine && !l.before.contains(k) && !kept.sent_as.contains(k) {
        kept.sent_as[k] = key
        taken_by[key] = true
        keys[i] = key
        came = true
        break
      }
    }
    if !came {
      still.push(l)
    }
  }
  let list : Array[Entry] = []
  let at_keys : Array[String] = []
  // (its Top and Foot no rows: the list's head and foot, View::scrolls_window's; the first row under its Top close
  // under it, as under the room it was)
  let mut top_first = false
  for i, e in all {
    if e is Top && list.is_empty() {
      top_first = true
    }
    if e is Foot || e is Top {
      continue
    }
    list.push(e)
    at_keys.push(keys[i])
  }
  // (what is still on its way: after the outbox, before where it stands, its agents' lines; its row before it followed
  // where it goes close under it, as its row will say)
  if still.length() > 0 {
    let mut at = list.length()
    for i, e in list {
      if e is (State(_, _, _) | Working(_)) {
        at = i
        break
      }
    }
    for j, l in still {
      list.insert(at + j, Out(l.row))
      at_keys.insert(at + j, "o:" + l.row.id)
      if l.row.joined && at + j > 0 {
        match list[at + j - 1] {
          Said(m) if !m.followed => list[at + j - 1] = Said({ ..m, followed: true })
          Out(o) if !o.followed => list[at + j - 1] = Out({ ..o, followed: true })
          _ => ()
        }
      }
    }
  }
  // (an agent whose card what is on its way from here answers: at work from the frame it is sent, under the key its
  // line will have once the core says so (Entry::id), its line coming with the answer, after the agents' lines the
  // core says: sfbase's answered_at, as row_keys has it)
  for a in @sfbase.answered_at(v, list) {
    list.push(Working(a))
    at_keys.push("act:" + a.key)
  }
  let rows : Map[String, ChatBodyRow] = Map([])
  let keys : Array[String] = []
  for i, e in list {
    let joined = match e {
      Said(m) => m.joined
      Out(o) => o.joined
      _ => false
    }
    let gap = if (i == 0 && top_first) || (i > 0 && list[i - 1] is Top) {
      NoGap
    } else if joined {
      Joined
    } else {
      Apart
    }
    let k = at_keys[i]
    match chat_body_pieces(e) {
      // (a long message a block a piece, each a block of the list: made as it comes to show, not all of it in the
      // frame its first line does; the room between two pieces the piece's own, as among its blocks drawn whole)
      Some(ps) =>
        for b, pc in ps {
          let pk = chat_piece_key(k, b)
          rows[pk] = { entry: e, gap: if b == 0 { gap } else { NoGap }, piece: Some(pc) }
          keys.push(pk)
        }
      None => {
        rows[k] = { entry: e, gap, piece: None }
        keys.push(k)
      }
    }
  }
  { keys, rows }
}

///|
/// What chat_body_rows made last, and of what (chat_body_rows_again's): the chat's view, its entries, whether anything
/// sent from here was on its way, the rows.
priv struct ChatBodyMade {
  view : ChatView
  all : Array[Entry]
  sending : Bool
  rows : ChatBodyRows
}

///|
/// chat_body_rows' rows of `v`'s entries `all` and what is on its way from here (`sending`), from what it made last
/// (`was`) where only entries changed where they stand, each the same row as before by its key (a streamed answer's
/// words, an agent's line, where the chat stands): those rows put again, their keys the same array, the rest of the
/// chat looked at no further than to find them. A row that came, went or moved, its gap or its pieces another, what is
/// sent from here or an outbox (their keys and the agents they set at work are chat_body_rows'): all of it made again.
/// The rows' map is the one made last, changed in place: what reads them reads them by key as they are now.
fn chat_body_rows_again(
  kept : ChatBodyKept,
  was : ChatBodyMade?,
  v : ChatView,
  all : Array[Entry],
  sending : Array[@sfbase.LocalSent],
) -> ChatBodyRows {
  guard was is Some(w) &&
    !w.sending &&
    sending.is_empty() &&
    v.outbox.is_empty() &&
    w.view.outbox.is_empty() else {
    return chat_body_rows(kept, v, all, sending)
  }
  guard all.length() == w.all.length() else { return chat_body_rows_tail(kept, w, v, all) }
  let changed : Array[Int] = []
  for i, e in all {
    let f = w.all[i]
    if physical_equal(e, f) || chat_entry_same(e, f) {
      continue
    }
    guard chat_entry_in_place(e, f) else { return chat_body_rows_tail(kept, w, v, all) }
    changed.push(i)
  }
  let updates : Array[(String, ChatBodyRow)] = []
  for i in changed {
    let e = all[i]
    let core_key = match e {
      Said(m) =>
        match kept.sent.get(m.seq) {
          Some(o) => "o:" + o
          None => e.id()
        }
      _ => e.id()
    }
    let k = kept.sent_as.get(core_key).unwrap_or(core_key)
    guard w.rows.rows.get(k) is Some(old) else { return chat_body_rows(kept, v, all, sending) }
    match (chat_body_pieces(e), chat_body_pieces(w.all[i])) {
      (Some(ps), Some(was_ps)) if ps.length() == was_ps.length() =>
        for b, pc in ps {
          let pk = chat_piece_key(k, b)
          updates.push((pk, { entry: e, gap: if b == 0 { old.gap } else { NoGap }, piece: Some(pc) }))
        }
      (None, None) => updates.push((k, { entry: e, gap: old.gap, piece: None }))
      _ => return chat_body_rows(kept, v, all, sending)
    }
  }
  for u in updates {
    w.rows.rows[u.0] = u.1
  }
  { keys: w.rows.keys, rows: w.rows.rows }
}

///|
/// The key chat_body_rows gives entry `e` with nothing sent from here on its way (its core key, or the key what was sent
/// from here as goes by once the core's row took it over).
fn chat_body_key(kept : ChatBodyKept, e : Entry) -> String {
  let core_key = match e {
    Said(m) =>
      match kept.sent.get(m.seq) {
        Some(o) => "o:" + o
        None => e.id()
      }
    _ => e.id()
  }
  kept.sent_as.get(core_key).unwrap_or(core_key)
}

///|
/// The keys chat_body_rows gives entry `e` (its pieces' where it is in pieces), its Top and Foot none.
fn chat_body_keys_of(kept : ChatBodyKept, e : Entry, out : Array[String]) -> Unit {
  if e is Top || e is Foot {
    return
  }
  let k = chat_body_key(kept, e)
  match chat_body_pieces(e) {
    Some(ps) => for b in 0..<ps.length() { out.push(chat_piece_key(k, b)) }
    None => out.push(k)
  }
}

///|
/// chat_body_rows_again's where entries came or went at the chat's end (a message come, an agent's line under it), with
/// nothing sent from here on its way and no outbox (then nothing is put among them, no agent set at work by what is on
/// its way: chat_body_rows' `still` and answered_at have nothing): the rows of the entries over the first that is not
/// as it was kept as they are, those from it on made again as chat_body_rows makes them, the rest of the chat looked at
/// no further. Where the entries before that are not a row of the list and its Top over it, or what the rows were made
/// of is not what this would say they were (their keys as they end), chat_body_rows' all of it again.
fn chat_body_rows_tail(kept : ChatBodyKept, w : ChatBodyMade, v : ChatView, all : Array[Entry]) -> ChatBodyRows {
  let whole = fn() { chat_body_rows(kept, v, all, []) }
  // (what is sent from here as it is told among the chat's messages: a key of one more means a row's key another,
  // anywhere in it)
  let sent_was = kept.sent.length()
  for m in v.messages {
    if m.outgoing != "" {
      kept.sent[m.seq] = m.outgoing
    }
  }
  guard kept.sent.length() == sent_was else { return whole() }
  let n = all.length()
  let was_n = w.all.length()
  let mut p = 0
  while p < n && p < was_n && (physical_equal(all[p], w.all[p]) || chat_entry_same(all[p], w.all[p])) {
    p = p + 1
  }
  // (a row of the list kept over what is made again, its Top first: each made again has a row over it, its gap its
  // own, never the first's; nothing on its way from here among them, none set at work by it)
  guard p >= 2 && all[0] is Top else { return whole() }
  let mut rows_before = false
  for i in 1..<p {
    if !(all[i] is Top || all[i] is Foot) {
      rows_before = true
      break
    }
  }
  guard rows_before else { return whole() }
  for i in p..<n {
    if all[i] is (Top | Out(_)) {
      return whole()
    }
  }
  for i in p..<was_n {
    if w.all[i] is (Top | Out(_)) {
      return whole()
    }
  }
  let old_keys : Array[String] = []
  for i in p..<was_n {
    chat_body_keys_of(kept, w.all[i], old_keys)
  }
  let keep = w.rows.keys.length() - old_keys.length()
  guard keep >= 0 else { return whole() }
  for j, k in old_keys {
    guard w.rows.keys[keep + j] == k else { return whole() }
  }
  let rows = w.rows.rows
  for k in old_keys {
    rows.remove(k)
  }
  let keys = w.rows.keys[0:keep].to_owned()
  for i in p..<n {
    let e = all[i]
    if e is Foot {
      continue
    }
    let joined = match e {
      Said(m) => m.joined
      _ => false
    }
    let gap = if joined { Joined } else { Apart }
    let k = chat_body_key(kept, e)
    match chat_body_pieces(e) {
      Some(ps) =>
        for b, pc in ps {
          let pk = chat_piece_key(k, b)
          rows[pk] = { entry: e, gap: if b == 0 { gap } else { NoGap }, piece: Some(pc) }
          keys.push(pk)
        }
      None => {
        rows[k] = { entry: e, gap, piece: None }
        keys.push(k)
      }
    }
  }
  { keys, rows }
}

///|
/// Whether entry `b` says what `a` did (chat_body_row_same's entries: a message, what was said elsewhere, what was sent
/// from here or an agent's line the same one, read again only as it changed; the rest by what they say).
fn chat_entry_same(a : Entry, b : Entry) -> Bool {
  match (a, b) {
    (Top, Top) | (Empty, Empty) | (Line, Line) | (Newer, Newer) | (Foot, Foot) => true
    (Older(x), Older(y)) => x == y
    (Said(x), Said(y)) => physical_equal(x, y)
    (Sent(x), Sent(y)) => physical_equal(x, y)
    (Out(x), Out(y)) => physical_equal(x, y)
    (State(w1, l1, r1), State(w2, l2, r2)) => w1 == w2 && l1 == l2 && r1 == r2
    (Working(x), Working(y)) => physical_equal(x, y)
    _ => false
  }
}

///|
/// Whether entry `a` is entry `b` changed where it stands, its row's key and the room over it as they were
/// (chat_body_rows_again's): a message by its time and seq, what it was sent from here as and whether it joins the one
/// before; what was said elsewhere, an agent's line by their keys; where the chat stands, the page before.
fn chat_entry_in_place(a : Entry, b : Entry) -> Bool {
  match (a, b) {
    (Said(x), Said(y)) => x.ts == y.ts && x.seq == y.seq && x.outgoing == y.outgoing && x.joined == y.joined
    (Sent(x), Sent(y)) => x.key == y.key
    (Working(x), Working(y)) => x.key == y.key
    (State(_, _, _), State(_, _, _)) | (Older(_), Older(_)) => true
    _ => false
  }
}

///|
/// What holds the pieces after the first of the message of key `k` while they are made (ChatBodyKeeps' `pieces`).
fn chat_pieces_of(
  pieces : Map[String, @signals.Signal[Array[@view.View]]],
  k : String,
) -> @signals.Signal[Array[@view.View]] {
  match pieces.get(k) {
    Some(s) => s
    None => {
      let s = @signals.signal_by([], same=fn(_, _) { false })
      pieces[k] = s
      s
    }
  }
}

///|
/// The key of the `b`th piece of the message whose row's key is `k` (its first piece's: `k` itself).
fn chat_piece_key(k : String, b : Int) -> String {
  if b == 0 {
    k
  } else {
    k + "#" + b.to_string()
  }
}

///|
/// The key of the message a row's key `k` is a piece of (`k` itself where it is no piece).
fn chat_piece_of(k : String) -> String {
  match k.rev_find("#") {
    Some(i) if k.has_prefix("m:") => k.unsafe_substring(start=0, end=i)
    _ => k
  }
}

///|
/// The pieces entry `e` is drawn in, a block of the list each (none: one, as ever): an agent's message whose words
/// the core read as more than one piece (sf's markdown_pieces: a block each, a table a few rows each), its card in
/// their place none. A long message
/// made whole as its first line came to show made a frame of hundreds of nodes (a table's, a fling over one: 229 on the
/// workspace of real size; a phone's hang reports 400 to 600, 2026-11-15).
fn chat_body_pieces(e : Entry) -> Array[@sf.MdPiece]? {
  guard e is Said(m) && !m.mine && !m.system && m.author_kind != "person" && agent_card_kind(m) == "" else {
    return None
  }
  @sf.markdown_pieces(m.text, m.md)
}

///|
/// Whether a row of entry `e` come among a chat's list's keys comes in (sfbase's row_keys' `comes`; the list says where
/// it is seen): a message the core says was said while the chat shows (Message's `said`), an outbox entry (one from
/// another device of the viewer's; what was sent from here on its own way, as the send's), an agent's line at work
/// (`started`); anything else (a message caught up on or read in, what was said elsewhere, where the chat stands, the
/// unread line) is simply there.
fn chat_body_comes(e : Entry) -> Bool {
  match e {
    Said(m) => m.said
    Out(_) => true
    Working(a) => a.started
    _ => false
  }
}

///|
/// Whether row `b` is what row `a` was: the same room over it and the same entry, an entry the same as the chat's list
/// keeps it (its message, what was said elsewhere, what was sent from here or an agent's line the same one, read again
/// only as it changed: sfbase's chat_read; the rest by what they say). What a row reads of its key (chat_body_row's)
/// changes only so: one row's entry changed, or one more come, none of the others' read again.
fn chat_body_row_same(a : ChatBodyRow, b : ChatBodyRow) -> Bool {
  physical_equal(a, b) || (a.gap == b.gap && a.piece == b.piece && chat_entry_same(a.entry, b.entry))
}

///|
/// The room a row's gap is (top_at's) in a list `w` wide.
fn chat_body_gap_room(gap : ChatBodyGap, w : Double) -> Double {
  match gap {
    NoGap => 0.0
    Joined => joined_gap
    Apart => if w <= chat_narrow_w { list_gap_narrow } else { list_gap }
  }
}

///|
/// How row `r` is made (chat_body_row's): its kind, and of an agent's message read before the chat showed it, which make
/// of piece it is (chat_body_piece_make), what such a row's nodes are made as (a long message's first piece, under its
/// head; a piece after it, its block alone; the last, its files and what it asks under it); -1 for any other. Made again
/// only as that changes. A piece after the first of one said while the chat shows is so too, with its block, whether it
/// holds its table's head and whether it is the last: it comes out of no picture, and its message streamed in makes it
/// another piece (a table come to more rows than a piece holds, its rows after the first a piece of their own, scrolled
/// across with them: chat_table_kept).
fn chat_body_made_as(r : ChatBodyRow) -> (ChatBodyKind, Int) {
  let kind = chat_body_kind(r.entry)
  match r.entry {
    Said(m) if kind == KAgent && !m.said => (kind, chat_body_piece_make(r.piece))
    Said(_) if kind == KAgent && chat_piece_after_first(r.piece) => {
      // (which block it is and whether it holds its table's head too: what its nodes are made for)
      let (from, head, last) = match r.piece {
        Some(pc) => (pc.from, pc.rows.map_or(true, fn(rows) { rows.0 == 0 }), pc.last)
        None => (0, true, true)
      }
      (kind, (((from * 2 + (if head { 1 } else { 0 })) * 8 + chat_body_piece_make(r.piece)) * 2) + (if last { 1 } else { 0 }))
    }
    _ => (kind, -1)
  }
}

///|
/// Whether a piece of a message is one after its first (agent_said_node draws it its blocks alone, no head over it).
fn chat_piece_after_first(piece : @sf.MdPiece?) -> Bool {
  match piece {
    Some(pc) => pc.from > 0 || (pc.rows is Some((r, _)) && r > 0)
    None => false
  }
}

///|
/// Which make of piece of a message a row is (ChatBodyRow's `piece`): 0 all of it; one block alone, 1 its first, 2 one
/// after it, 3 its last; 4 some rows of a table or items of a list.
fn chat_body_piece_make(piece : @sf.MdPiece?) -> Int {
  match piece {
    None => 0
    Some(pc) if pc.rows is None && pc.upto == pc.from + 1 => if pc.from == 0 { 1 } else if pc.last { 3 } else { 2 }
    Some(_) => 4
  }
}

///|
/// The make of block row `r` of chat `here`'s list is put by as and taken for (View::scrolls_window's `reused`): a
/// message read before the chat showed it (not `said`: nothing of it moves as it comes) with no files (what files draw
/// is made by them), by who said it (the viewer, a person, still.fail's notice, an agent) and, an agent's with no card
/// and nothing asked, which make of piece (chat_body_piece_make: no table's rows or list's items); whether its agent is
/// one, and one of the chat's (its paths its files, its name's card), and whether the chat offers its messages (its
/// thread: message_share_of), each made by it as the block is made. None for any other row: made and let go as it shows.
/// A block taken for another row of its make shows it as one made for it would (chat_body_row, through its key).
fn chat_body_shape(here : MessageNodeHere, r : ChatBodyRow) -> Int? {
  guard r.entry is Said(m) && !m.said && m.attachments.is_empty() else { return None }
  let made = if m.mine {
    0
  } else if m.system {
    1
  } else if m.author_kind == "person" {
    2
  } else {
    guard m.card is None && m.options is None && !m.asked else { return None }
    match chat_body_piece_make(r.piece) {
      4 => return None
      p => 3 + p
    }
  }
  let agent = if made < 3 || m.by.agent == "" {
    0
  } else if @signals.untracked(fn() { message_agent_of(here, m.by.agent) }) == "" {
    1
  } else {
    2
  }
  let shares = if @signals.untracked(here.view).thread is Some(_) { 1 } else { 0 }
  Some((made * 3 + agent) * 2 + shares)
}

///|
/// What kind of row an entry is drawn as (entry_row's and message_row's cases): what is made again only as a row of
/// one key comes to be another kind (what was sent from here coming to be the core's message).
#derive(Eq)
priv enum ChatBodyKind {
  KTop
  KOlder
  KOlderFailed
  KEmpty
  KLine
  KNewer
  KMine
  KNotice
  KPerson
  KAgent
  KSent
  KState
  KWorking
}

///|
/// What kind of row entry `e` is drawn as.
fn chat_body_kind(e : Entry) -> ChatBodyKind {
  match e {
    Top | Foot => KTop
    Older("") => KOlder
    Older(_) => KOlderFailed
    Empty => KEmpty
    Line => KLine
    Newer => KNewer
    Said(m) =>
      if m.mine {
        KMine
      } else if m.system {
        KNotice
      } else if m.author_kind == "person" {
        KPerson
      } else {
        KAgent
      }
    Sent(_) => KSent
    // (what was sent from here the viewer's own message on its way: one row with what the core's message makes of it)
    Out(_) => KMine
    State(_, _, _) => KState
    Working(_) => KWorking
  }
}

///|
/// The agents of a chat's list whose turn's answer came out (by the agent's key: the turn it answered). `lingers` is
/// no more written: an agent's line kept while its answer waits to come out is the list's held keys' (chat_body_node's).
// `lingers`: made by chat_body_keyed's default `turns` alone, read by nothing; to go with that line
#warnings("-unused_field")
priv struct ChatTurnsOut {
  answered : @sf.LiveMap[String, String]
  lingers : @sf.LiveMap[String, Agent]
}

///|
/// The agent of chat `here` whose message `m` is (its by), as the chat's view says it now; none for another's.
fn chat_agent_of(here : MessageNodeHere, m : Message) -> Agent? {
  @signals.untracked(fn() {
    let k = message_agent_of(here, m.by.agent)
    (here.view)().agents.iter().find_first(fn(a) { a.key == k && k != "" })
  })
}

///|
/// Message `m`, an agent's ending its turn (its `ending`), come by data into the list of chat `here` and out of no
/// picture (none held for it: chat_body_node's held keys): its agent's line goes at once, the answer taking its place on the list's
/// one way (the old view's chat_tick: `answered`). One held goes as it comes out (chat_body_node's held keys, as it is let in).
fn chat_turn_out(v : @view.View, here : MessageNodeHere, turns : ChatTurnsOut, m : Message) -> Unit {
  guard chat_agent_of(here, m) is Some(a) else { return }
  v.at_moment(v.cause_at(), fn() { turns.answered[a.key] = a.last_turn }) |> ignore
}

///|
/// Whether a chat's list follows its foot (what comes at it followed: Scroll::follows_now, as the old list's `at_end ||
/// gliding || following_row`: a tall answer held at its top by ListPlace::follow_from, the next still followed).
fn chat_follows_foot(scroll : @view.Scroll) -> Bool {
  scroll.follows_now()
}

///|
/// How far from a chat's list's end what came by a change is looked for (chat_body_node's `held_came`): what comes
/// by data comes at its end, a few rows at a time.
let chat_held_tail : Int = 64

///|
/// The key over `k` in keys `ks` that is not left out (`out`); none where `k` is first or not among them.
fn chat_key_before(ks : Array[String], k : String, out : (String) -> Bool) -> String? {
  let mut i = ks.length() - 1
  while i >= 0 && ks[i] != k {
    i = i - 1
  }
  i = i - 1
  while i >= 0 {
    if !out(ks[i]) {
      return Some(ks[i])
    }
    i = i - 1
  }
  None
}

///|
/// A chat's list's keys `ks` with the messages `held` holds out of them (each with its pieces) left out, and each agent's
/// line kept for one (`lingering`) that `ks` has no more put back under the key it stood under (at the end where that
/// is gone): chat_body_node's held keys.
fn chat_keys_held(
  ks : Array[String],
  held : Map[String, AgentOutPlan],
  lingering : Map[String, (ChatBodyRow, String?)],
) -> Array[String] {
  if held.is_empty() {
    return ks
  }
  let out : Array[String] = []
  for k in ks {
    if !held.contains(chat_piece_of(k)) {
      out.push(k)
    }
  }
  for ak, l in lingering {
    if out.contains(ak) {
      continue
    }
    let at = match l.1 {
      Some(b) =>
        match out.search(b) {
          Some(i) => i + 1
          None => out.length()
        }
      None => out.length()
    }
    out.insert(at, ak)
  }
  out
}

///|
/// The agent whose line key `k` is (Entry::id's `act:<agent>`), none for another row's.
fn chat_working_key_agent(k : String) -> String? {
  match k.strip_prefix("act:") {
    Some(a) => Some(a.to_owned())
    None => None
  }
}

///|
/// The agents of chat view `v` whose line shows (at work), each as its line reads it, `turns`' answered left out: their
/// answer to this turn out, nothing of their line left to show. One whose answer waits to come out of its picture, its
/// turn said over meanwhile, is kept by the list's held keys (chat_body_node's), not here.
fn chat_working_kept(v : ChatView, turns : ChatTurnsOut) -> Array[Agent] {
  let out = []
  for a in v.agents {
    if (a.status == "running" || a.status == "queued") && turns.answered.get(a.key) != Some(a.last_turn) {
      out.push(a)
    }
  }
  out
}

///|
/// The chat's entries `all` (view_of_chat's) with the agents' lines as chat_working_kept has them: an agent's whose answer
/// to its turn is out left out.
fn chat_working_entries(all : Array[Entry], turns : ChatTurnsOut) -> Array[Entry] {
  if turns.answered.is_empty() {
    return all
  }
  all.filter(fn(e) {
    match e {
      Working(a) => turns.answered.get(a.key) != Some(a.last_turn)
      _ => true
    }
  })
}

///|
/// What a chat's list keeps of its rows that is theirs, by key, across their blocks being made and let go: which
/// notices are open (notices_open, the old view's), when each said 已复制, each agent's line's words as they steadied.
priv struct ChatBodyKeeps {
  opened : @sf.LiveMap[String, Bool]
  copied : @sf.LiveMap[String, Double]
  steadies : ActivitySteadies
  /// each agent at work's picture on its line, by its key, while that line is made (working_said_node's): what a
  /// message of its coming by data comes out of (agent_said_node's `out_of`)
  faces : Map[String, AgentFace]
  /// what holds each piece after the first of a long message, by its message's key, while it is made: whether the
  /// pointer is on one of them, the first's ⋯ shown as it is on the first (agent_said_node's `pieces_pointed`)
  pieces : Map[String, @signals.Signal[Array[@view.View]]]
  /// what the pieces of each long table scroll across beside and what they keep of its columns together, by its
  /// message's key and its block (agent_said_node's `across_of`, `tracks_of`): all of them as one
  tables : Map[String, (@view.Scroll, @view.TracksKept)]
}

///|
/// How many long tables a chat's page keeps what their pieces scroll across beside (ChatBodyKeeps' `tables`): those
/// asked of last, the rest let go (a table come back to then at its start).
let chat_tables_most : Int = 64

///|
/// What the pieces of the long table at block `b` of the message of key `whole` scroll across beside and keep of its
/// columns together (ChatBodyKeeps' `tables`), made as it is first asked: the last asked of them last, those asked
/// longest ago let go first past chat_tables_most.
fn chat_table_kept(
  tables : Map[String, (@view.Scroll, @view.TracksKept)],
  whole : String,
  b : Int,
) -> (@view.Scroll, @view.TracksKept) {
  let tk = whole + "#" + b.to_string()
  match tables.get(tk) {
    Some(kept) => {
      tables.remove(tk)
      tables[tk] = kept
      kept
    }
    None => {
      let kept = (@view.Scroll::across(), @view.TracksKept::new())
      if tables.length() >= chat_tables_most {
        match tables.keys().head() {
          Some(first) => tables.remove(first)
          None => ()
        }
      }
      tables[tk] = kept
      kept
    }
  }
}

///|
/// A chat's messages (chat_list's rows, at rest) in `v`, taking the room it is given: the chat `here` is (its view as
/// it changes, the list's width as it changes: narrow or wide by it), its rows the entries `entries` says as they
/// change (view_of_chat's) with what was sent from here and not in the chat yet (`sending`: sfbase's sending_now),
/// answered with `core` where something is (a login's card, a request's answer); under the chat's bar, `cover` tall
/// (where the bar is drawn to: what hides the list's top, what the list holds what is read under), `room` more over its
/// first row (the list's head, the two together: its top), `foot` under its last, then the composer `composer` builds
/// in the list's foot (its room under the rows as tall as the two are laid out, as the composer changes: at once as
/// yet). In `scroll`,
/// put where `place` asks: where it opens as chat_open_place says (its unread line `lead` under its top, where it was
/// left, else at its end, followed there), and at an unread line come after while it is still at its end; a chat too short to fill what shows at its foot, over the composer (the old
/// list's from_end); the page before asked as it nears its top. `made`, told each row's key and what holds it as its row
/// is made (a block made, or made again as its key comes to be another kind of row). `read`, given `place`, `scroll` and
/// its rows, for what is told the core of what is read (chat_read_node). `to`: the chat it is (none in a list's own tests), its
/// way to the newest in the list's foot over the composer and the message it is told to go to brought in
/// (chat_jump_node's), while `shows` (it is drawn) where the reader is kept for a go-to inside it. `cover_to`: how tall
/// what covers the list's top comes to be (the bar's second row measured as the bar is laid out, after the list was
/// made, or pressed open or shut; none: never another), where the list the page put somewhere and the reader has not
/// moved since glides on with it, what it put there not under it (chat_stand_again).
fn chat_body_node(
  v : @view.View,
  src : Source,
  here : MessageNodeHere,
  entries : () -> Array[Entry],
  sending? : () -> Array[@sfbase.LocalSent] = fn() { [] },
  core? : @settings.Core? = None,
  cover? : () -> Double = fn() { bar_foot },
  cover_to? : () -> Double,
  room? : Double = list_room,
  foot? : () -> Double = fn() { list_foot },
  composer? : (@view.View) -> Unit,
  lead? : Double = unread_lead,
  scroll? : @view.Scroll = @view.Scroll::list(),
  place? : @view.ListPlace[String] = @view.ListPlace::new(),
  keeps? : ChatBodyKeeps = { opened: notices_open, copied: @sf.LiveMap::new(), steadies: ActivitySteadies::new(), faces: Map([]), pieces: Map([]), tables: Map([]) },
  made? : (String, @view.View) -> Unit = fn(_, _) {  },
  read? : (@view.ListPlace[String], @view.Scroll, ChatBodyList) -> Unit = fn(_, _, _) {  },
  to? : ChatRef,
  shows? : () -> Bool = fn() { true },
  msgs? : () -> @sfbase.ChatMessages? = fn() { None },
) -> @view.View {
  let jump = ChatJump::new()
  // (the list's top: the bar and the room under it, its head; where it opens, where a go-to puts a message and the
  // unread line are counted from it, as before the bar's own edge was told the list)
  let top = fn() { cover() + room }
  let kept : ChatBodyKept = { sent: {}, sent_as: {}, here: {} }
  // (when each key came into the list by data, by the list's `comes`, asked at its cause: what its row reads as it is
  // made; none for one there as the chat opened, simply there, or come by an answer at once)
  let came_at : Map[String, Double] = Map([])
  // (an agent's message come by data while its agent's line shows and the list is at its foot: how it comes out of
  // that line's picture, worked out as its key comes, by the message's key (its first piece's), read by its row as it
  // is made; taken by that row, so a row made again later is simply there; what its pieces after the first read, their
  // glyphs on its clock: `out_taken`)
  let out_plans : Map[String, AgentOutPlan] = Map([])
  let out_taken : Map[String, AgentOutPlan] = Map([])
  // (each agent at work whose answer, a message ending its turn, came out: the turn it answered (its line goes for it);
  // and each agent whose line stays while its answer comes out of its picture, its turn over meanwhile:
  // chat_working_kept's)
  let turns : ChatTurnsOut = { answered: @sf.LiveMap::new(), lingers: @sf.LiveMap::new() }
  // (worked out once as the view, its entries or what is on its way change, from what was worked out last where only
  // rows changed where they stand (chat_body_rows_again); the keys only change as rows come, go or are taken over)
  let made_last : Ref[ChatBodyMade?] = Ref(None)
  // (how many times the rows were made whole: what was sent from here as, kept, read again by the rows by key as they
  // go on from them)
  let made_whole = Ref(0)
  let rows = @signals.computed_by(fn(_) {
    let view = (here.view)()
    let all = chat_working_entries(entries(), turns)
    let on_way = sending()
    let rs = chat_body_rows_again(kept, made_last.val, view, all, on_way)
    made_last.val = Some({ view, all, sending: !on_way.is_empty(), rows: rs })
    made_whole.val += 1
    rs
  }, same=fn(_, _) { false })
  // (by key where the chat's messages are kept so (chat_body_keyed: a message's change reads that message's rows alone,
  // what is sent from here and the outbox too); else made whole of its entries, chat_body_rows')
  // (the messages by key as `msgs` comes to give them: a chat a new chat became reads its entries whole till the core's
  // view of it comes, then by key, the same list going on; the list given kept, its rows made of it once, made anew of
  // another the source comes to keep in its place (its chat read again: chat_messages), the rows' era another with it;
  // given none after, the one given goes on)
  let msgs_given : Ref[@sfbase.ChatMessages?] = Ref(None)
  let by_key_made : Ref[ChatBodyList?] = Ref(None)
  // (0 none given yet; counted up as each other list is given)
  let keyed_gen = @signals.computed(
    fn(was) {
      let n = was.unwrap_or(0)
      match (msgs_given.val, msgs()) {
        (Some(g), Some(m)) if !physical_equal(g, m) => {
          msgs_given.val = Some(m)
          by_key_made.val = None
          n + 1
        }
        (Some(_), _) => n
        (None, Some(m)) => {
          msgs_given.val = Some(m)
          n + 1
        }
        (None, None) => n
      }
    },
    same=fn(a, b) { a == b },
  )
  let keyed_now = fn() { keyed_gen.get() > 0 }
  let era = @signals.computed(
    fn(_) {
      // (both only counting up: another as either does)
      keyed_gen.get() + made_whole.val
    },
    same=fn(a, b) { a == b },
  )
  let chat_ref : ChatRef = { station: here.station, session: here.session, title: "", station_name: "" }
  let by_key_of = fn(m : @sfbase.ChatMessages) {
    // (the last card that words sent from here answer, answered: sfbase's chat_sent_here; found of the messages and
    // what is on its way alone, none of the head, and answered again only as that card is another)
    let card_of = @signals.computed(fn(_) { @sfbase.chat_sent_card(chat_ref, m) }, same=fn(a, b) {
      match (a, b) {
        (None, None) => true
        (Some((ka, ma)), Some((kb, mb))) => ka == kb && physical_equal(ma, mb)
        _ => false
      }
    })
    let card = @signals.computed(fn(_) { card_of.get().map(fn(c) { (c.0, @sfbase.chat_card_answered(c.1)) }) })
    chat_body_keyed(kept, era, here.view, m, sending~, card=fn() { card.get() }, turns~)
  }
  // (made as the messages by key are given, read only once they are)
  let by_key = fn() -> ChatBodyList? {
    guard keyed_now() else { return None }
    match by_key_made.val {
      Some(l) => Some(l)
      None => {
        guard msgs_given.val is Some(m) else { return None }
        let l = by_key_of(m)
        by_key_made.val = Some(l)
        Some(l)
      }
    }
  }
  let whole = ChatBodyList::of_made(fn() { rows.get() })
  // (the list as the core's rows and what is on its way make it, before what is held out of it: below)
  let listed : ChatBodyList = {
    taken: fn() {
      match by_key() {
        Some(l) => (l.taken)()
        None => (whole.taken)()
      }
    },
    keys: fn() {
      match by_key() {
        Some(l) => (l.keys)()
        None => (whole.keys)()
      }
    },
    row: fn(k) {
      match by_key() {
        Some(l) => (l.row)(k)
        None => (whole.row)(k)
      }
    },
  }
  // an agent's message come by data while its agent's line shows and the list follows its foot is out of the list till
  // its agent's picture sets out for it (its plan's Float: agent_out_plan), as the old list's (sfbase's emit.mbt: waiting
  // its turn, a message is not in the list yet), its line folding to its picture meanwhile and kept where its turn is
  // said over first; at that moment, the one change of its coming out (`release`), it comes in and the line its answer
  // ends goes, one swap on the list's one way (View::scrolls_window's `flips`): nothing laid out unseen under the line,
  // nothing to undo. Its picture's flight, its words' and its going home are its row's and its plan's (agent_out_steps,
  // agent_out_return), on that plan's clock. Words sent from here still flying to their row go first: the plan set out
  // as they land (the old list's emit_step `held_until`)
  // (each held message by its key, its first piece's: its plan; its pieces after it held with it)
  let held : Map[String, AgentOutPlan] = Map([])
  // (each agent's line kept for a held answer that ends its turn (its key, act:<agent>): its row as last read, and the key
  // it stood under (none: at the list's end))
  let lingering : Map[String, (ChatBodyRow, String?)] = Map([])
  // (each agent's line's row as last read: what is kept of it as its turn is said over before its answer comes out)
  let act_rows : Map[String, ChatBodyRow] = Map([])
  // (counted on as a held message is let in: what the keys are worked out again by)
  let held_told = @signals.signal(0)
  let listed_was : Ref[Array[String]] = Ref([])
  // (when the words last sent from here land in their row (-1: none), as they set out: what a plan waits for)
  let sent_lands = Ref(-1.0)
  let row_of_listed = fn(k : String) -> ChatBodyRow? {
    let r = (listed.row)(k)
    match r {
      Some(row) if row.entry is Working(_) => act_rows[k] = row
      _ => ()
    }
    r
  }
  // (message `k`, `m`, held as its agent's picture at work `face` plans it, from `now`; the line it ends, `ak` as the list
  // stood (`ks`, and before: `was`), kept meanwhile)
  let hold = fn(k : String, m : Message, face : AgentFace, ks : Array[String], was : Array[String]) {
    let now = @sf.dmax(v.cause_at(), sent_lands.val)
    let plan = agent_out_plan(face, now)
    held[k] = plan
    out_plans[k] = plan
    let ends = if m.ending != "" && !m.system { chat_agent_of(here, m) } else { None }
    match ends {
      Some(a) => {
        let ak = "act:" + a.key
        let row = match @signals.untracked(fn() { (listed.row)(ak) }) {
          Some(r) => Some(r)
          None => act_rows.get(ak)
        }
        match row {
          Some(r) => lingering[ak] = (r, chat_key_before(if was.contains(ak) { was } else { ks }, ak, fn(o) { held.contains(chat_piece_of(o)) }))
          None => ()
        }
      }
      None => ()
    }
    // (set off once what works the keys out is over: a way and the moments of the plan, none of the keys' own)
    @signals.after_computing(fn() {
      if plan.folds {
        // det-ok(motion-length): emit.mbt's Fold, the line folding to its picture from the plan's start
        face.fold.go(0.0, @motion.tween(@sfbase.Pose::Fold.ms(), ease=Out, delay=plan.came - v.cause_at()), at=v.cause_at())
      }
      v.at_moment(plan.float_at, fn() {
        // (where the line's picture is as it lets the message out, before the line goes in this change)
        if plan.folds {
          plan.face_at.val = Some(agent_face_at(face))
        }
        held.remove(k)
        match ends {
          Some(a) => {
            lingering.remove("act:" + a.key)
            turns.answered[a.key] = a.last_turn
          }
          None => ()
        }
        face.away.set(true)
        held_told.set(held_told.untracked() + 1)
      })
      |> ignore
      v.at_moment(plan.spit_end, fn() {
        // (a plan its row never took (not shown as it came) is none to a row made later: simply there)
        out_plans.remove(k)
        let ending = match (listed.row)(k) {
          Some({ entry: Said(m), .. }) => m.ending != ""
          _ => true
        }
        agent_out_return(face, plan, ending)
      })
      |> ignore
    })
  }
  // (what came at the list's end by the change from `was` to `ks`, in order: words sent from here on their way, and an
  // agent's message come while its line shows, held. Not as the list first has keys, nor by an answer told at once: what
  // was there simply there)
  let held_came = fn(ks : Array[String], was : Array[String]) {
    guard was.length() > 0 && !@view.answering_now() else { return }
    // (what comes by data comes among the last rows, over the agents' lines and what is on its way: the last few of
    // them looked through, those not among the last of the keys before)
    let seen : Map[String, Bool] = Map([])
    for i in dmax_int(was.length() - 2 * chat_held_tail, 0)..<was.length() {
      seen[was[i]] = true
    }
    for j in dmax_int(ks.length() - chat_held_tail, 0)..<ks.length() {
      let k = ks[j]
      guard !seen.contains(k) && chat_piece_of(k) == k && !held.contains(k) else { continue }
      match @signals.untracked(fn() { (listed.row)(k) }) {
        Some({ entry: Out(_), .. }) if @sfbase.sent_from_waits(k) =>
          sent_lands.val = @sf.dmax(sent_lands.val, v.cause_at() + @sfbase.flight_desk_ms)
        Some({ entry: Said(m) as e, .. }) if m.author_kind == "agent" &&
          !m.mine &&
          chat_body_comes(e) &&
          !out_taken.contains(k) &&
          @signals.untracked(fn() { chat_follows_foot(scroll) }) &&
          !@ui.reduced_motion() =>
          match keeps.faces.get(@signals.untracked(fn() { message_agent_of(here, m.by.agent) })) {
            Some(face) => hold(k, m, face, ks, was)
            None => ()
          }
        _ => ()
      }
    }
  }
  let list : ChatBodyList = {
    taken: listed.taken,
    keys: fn() {
      held_told.get() |> ignore
      let ks = (listed.keys)()
      if !physical_equal(ks, listed_was.val) {
        let was = listed_was.val
        listed_was.val = ks
        held_came(ks, was)
      }
      chat_keys_held(ks, held, lingering)
    },
    row: fn(k) {
      match row_of_listed(k) {
        Some(r) => Some(r)
        None => lingering.get(k).map(fn(l) { l.0 })
      }
    },
  }
  let keys = @signals.computed(fn(_) { (list.keys)() }, same=fn(a, b) { physical_equal(a, b) || a == b })
  // (the keys the core's rows that took over what was sent from here go on by, given the chat's viewer, which names an
  // occurrence of a picture by its row's key here and asks the core by the core's: told again as a row is taken over,
  // which only adds one)
  let taken_over = @signals.computed(fn(_) {
    // (what was sent from here is taken over as the rows are worked out: chat_body_rows and chat_body_keyed write it)
    (list.taken)() |> ignore
    kept.sent_as.length()
  }, same=fn(a, b) { a == b })
  let sent_as = fn() {
    taken_over.get() |> ignore
    kept.sent_as
  }
  let chat_key = here.station + "\u{1}" + here.session
  @sfbase.rows_sent_as[chat_key] = sent_as
  // (what was sent from here that a core's row took over leaves what is on its way: sfbase's sent_local_taken)
  v.reacts(fn() { taken_over.get() }, fn(_) { @sfbase.sent_local_taken(chat_key, kept.sent_as) })
  v.owns(fn() {
    if @sfbase.rows_sent_as.get(chat_key) is Some(f) && physical_equal(f, sent_as) {
      @sfbase.rows_sent_as.remove(chat_key)
    }
  })
  |> ignore
  let width = here.width
  let side = fn() { row_side(width()) }
  // the page before asked of the core as the list nears its top (list_after's: once for each first entry it has, not
  // while the core reads one, nor while it waits after a read that failed: it says when to ask again; asked again
  // where the read failed), chat_grow_rows more each time; not while it stands where a go-to put it (ChatJump's
  // `put`: only once the reader moves it)
  let wants_older = fn() {
    let now = (here.view)()
    now.more && now.older == "" && now.thread is Some(_) && jump.put.get() == 0
  }
  let asked_from : Ref[Double?] = Ref(None)
  // (a read that failed asked again a while after, longer each time it fails again, while it is still wanted)
  let older_fails = Ref(0)
  fn ask_older(grow : Bool) -> Unit {
    let now = @signals.untracked(here.view)
    guard now.thread is Some(thread) else { return }
    let first = match now.first_entry {
      Some(f) => f
      None =>
        match to.map(fn(r) { chat_said_all(src, r, here.view) }).unwrap_or(now.messages).get(0) {
          Some(m) => m.seq
          None => -1.0
        }
    }
    guard asked_from.val != Some(first) else { return }
    asked_from.val = Some(first)
    let params : Map[String, Json] = { "station": Json::string(here.station), "thread": Json::number(thread) }
    if grow {
      params["rows"] = Json::number(@sfbase.chat_grow_rows.to_double())
    }
    (src.call)("chat.older", Json::object(params), fn(res) {
      if res is Err(_) {
        asked_from.val = None
        v.at_moment(v.cause_at() + ask_again_ms(older_fails.val), fn() {
          if @signals.untracked(wants_older) {
            ask_older(grow)
          }
        })
        |> ignore
        older_fails.val += 1
      } else {
        older_fails.val = 0
      }
    })
  }
  // the page after asked as the list nears its foot while the window is short of the chat's end (list_after's: once
  // for each last entry it has; asked again where the read failed)
  let wants_newer = fn() {
    let now = (here.view)()
    now.newer && now.thread is Some(_)
  }
  let asked_after : Ref[Double?] = Ref(None)
  let newer_fails = Ref(0)
  fn ask_newer() -> Unit {
    let now = @signals.untracked(here.view)
    guard now.thread is Some(thread) else { return }
    let last = match now.last_entry {
      Some(l) => l
      None =>
        match to.map(fn(r) { chat_said_all(src, r, here.view) }).unwrap_or(now.messages).last() {
          Some(m) => m.seq
          None => -1.0
        }
    }
    guard asked_after.val != Some(last) else { return }
    asked_after.val = Some(last)
    (src.call)("chat.newer", { "station": Json::string(here.station), "thread": Json::number(thread) }, fn(res) {
      if res is Err(_) {
        asked_after.val = None
        v.at_moment(v.cause_at() + ask_again_ms(newer_fails.val), fn() {
          if @signals.untracked(wants_newer) {
            ask_newer()
          }
        })
        |> ignore
        newer_fails.val += 1
      } else {
        newer_fails.val = 0
      }
    })
  }
  // (the key of the row under each, as the list's keys are: what a message's band reaches down to, read only while one
  // is lit; worked out again only as the keys change)
  let under_keys = @signals.computed_by(
    fn(_) {
      let ks = (list.keys)()
      let m : Map[String, String] = Map([])
      for i in 1..<ks.length() {
        m[ks[i - 1]] = ks[i]
      }
      m
    },
    // (a map made anew as the keys change: no value to compare)
    same=fn(a, b) { physical_equal(a, b) },
  )
  let under = fn(k : String) { under_keys.get().get(k) }
  // (a row's block in `slot`, of the row whose key `key` says as it is now: chat_body_row's)
  let row_of = fn(slot : @view.View, key : () -> String) {
    chat_body_row(slot, src, here, key, list, side, top, core, keeps, made, jump, fn() { came_at.get(key()) }, fn() {
      let k = @signals.untracked(key)
      let base = chat_piece_of(k)
      if base == k {
        let plan = out_plans.get(k)
        out_plans.remove(k)
        match plan {
          Some(p) => out_taken[k] = p
          None => ()
        }
        plan
      } else {
        out_taken.get(base)
      }
    }, fn(e) { sent_lands.val = @sf.dmax(sent_lands.val, e) })
  }
  // (the list's head, a block of what it holds: what tells it its rows are laid out anew, at
  // another width, as the page sets off to another (column_laid))
  let head_v : Ref[@view.View?] = Ref(None)
  // (put in place once, as it is made: chat_open_place's; else at its end, where it is made; at a message the chat is
  // to go to first, chat_goes_to's; while standing where opened away from its end, near_top waits for the reader to move)
  let chat = here.station + "\u{1}" + here.session
  let opens = fn() {
    @signals.untracked(fn() {
      chat_open_place(list, (here.view)(), @sfbase.kept_places.get(chat), v.pixel_scale(), cover(), top(), lead, width())
    })
  }
  let opened = opens()
  if opened is Some(_) && !@sfbase.go_tos.contains(chat) {
    jump.put.set(1)
  }
  v.box(fn(o) {
    o.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
    let bands = chat_body_bands(o, list, under, jump, here)
    // (its column laid out anew at another width as the page sets off on its way to it (a side panel sliding in or out
    // beside it: @sfbase.column_sets_off, told at that way's cause): its rows' heights and places going there on the
    // list's one way from that moment, set out from where they were drawn (its inner set-out), as the old list's laid_w
    // had them go, not stepping there in that frame; the window made another size lays it out anew at once)
    match to {
      Some(r) => {
        let chat = r.station + "\u{1}" + r.session
        @sfbase.column_set_off_by(chat, o, fn() {
          match head_v.val {
            Some(h) if h.alive() => h.resizes() |> ignore
            _ => ()
          }
        })
      }
      None => ()
    }
    o.scrolls_window(
      scroll,
      fn() { keys.get() },
      est=chat_row_est,
      bar=@ui.tree_scroll_bar(),
      // (what hides its top is the bar alone, as it is drawn: a message whose words start in the room under it is seen,
      // and held where it is (View::read_from). Its bar kept clear of the room too, where it was)
      top_covered=cover,
      // (and what covers its foot the composer alone: the room under its last row over it (`foot`, the bell's room
      // with it) the rows show through, as the old page's list was told its room (pv_lists' `room`); so a picture
      // there is seen whole, flying to the viewer and back from where it is, not from under a foot it is not under)
      foot_clear=foot,
      bands~,
      bar_clear=fn() { (top(), 0.0) },
      // (its Top, the chat's bar and the room under it, the list's head; its Foot, the list's foot: the room under its
      // rows, then the composer (`composer`), the room under the last row as tall as both are laid out)
      head=fn(h) {
        h.height(By(fn() { Some(top()) })) |> ignore
        head_v.val = Some(h)
        made("top", h)
      },
      foot=fn(f) {
        match to {
          // (对话目录's rail at the list's right, in its middle, where the page leaves it room)
          Some(r) => chat_rail_node(f, src, r, jump, here.view, width, top, o, here.tips, here.stint, scroll~, room=foot, bar=cover)
          None => ()
        }
        f.box(fn(g) { g.height(By(fn() { Some(foot()) })) |> ignore }) |> ignore
        // (the round buttons standing on the composer's top, float_lift over it as the old page's float_box: after the
        // room under the last row, not on its top, which stood them that room (list_foot, and the bell's ask_clear)
        // higher, over the last message)
        match to {
          Some(r) => {
            chat_to_newest_node(f, src, r, jump, place, here.view, width, here.tips)
            chat_outline_node(f, src, r, jump, here.view, width, here.tips, here.stint)
            chat_ask_node(f, r, src, jump, place, here.view, list, width, here.tips)
          }
          None => ()
        }
        match composer {
          Some(build) => build(f)
          None => ()
        }
      },
      follows=fn() { true },
      // (an agent's line gone from the list's end with its turn, no answer of it come out over it: its room left under
      // the last row, what is over it not coming down (the old list's room agents' lines left); its answer out over it,
      // it goes as any row, what is over it coming down into its room on the list's way)
      leaves_room=fn(k) {
        match chat_working_key_agent(k) {
          Some(a) =>
            match turns.answered.get(a) {
              // (answered this turn: the turn it is at as the line goes, or the one before where it is over and none is
              // said since)
              Some(turn) =>
                !(here.view)().agents.iter().any(fn(g) { g.key == a && (g.last_turn == turn || g.last_turn == "") })
              None => true
            }
          None => false
        }
      },
      // (what comes with a way, as row_keys' `comes`: a message the core says was said while the chat shows, an outbox
      // entry, an agent at work; the rest, caught up on, read in or there as the chat opened, simply there: what was
      // said before it was shown moves not, sf/motion.mbt's head)
      comes=fn(k) {
        let comes = match (list.row)(k) {
          Some(r) => chat_body_comes(r.entry)
          None => false
        }
        // (the moment it came by data, as its cause is taken: an agent's line's first words come in glyph by glyph from
        // then (working_said_node's `came`); none where it is simply there, or came by an answer at once)
        if comes && !@view.answering_now() {
          came_at[k] = v.cause_at()
        } else {
          came_at.remove(k)
        }
        // (its first piece's key the message's: what comes out of its agent's picture planned once for all of it, as it
        // was held (held_came); come by another way, nothing of a plan before)
        if chat_piece_of(k) == k && !out_plans.contains(k) {
          out_taken.remove(k)
          // (the answer to its agent's turn come out of no picture: its line goes at once, the answer taking its place
          // on the list's one way, never the line left folded and empty under it till the turn is said over (old view's
          // chat_tick: `answered`); one held goes as it is let in)
          if comes && !@view.answering_now() {
            match (list.row)(k).map(fn(r) { r.entry }) {
              Some(Said(m)) if m.author_kind == "agent" && !m.mine && !m.system && m.ending != "" =>
                chat_turn_out(v, here, turns, m)
              _ => ()
            }
          }
        }
        comes
      },
      // (what its keys bring or take laid out once as it ends, each row drawn off on one way: mbui's View::scrolls_window
      // `flips`, nothing laid out again on the way)
      flips=true,
      // (what shows held by what is read: not by the row saying the page before comes, which what comes in is put in
      // under, going on down with what shows)
      holds=fn(k) { k != "older" },
      from_end=true,
      place~,
      near_top=(1.0, wants_older, fn() { ask_older(true) }),
      near_foot=(1.0, wants_newer, ask_newer),
      // (a message read before the chat showed it, as it no more shows put by for the next of its make to come to show,
      // its key that one's: what a hand scrolling through a chat's history comes to, nothing made or let go for it
      // (chat_body_shape); what moves as it comes (what came by data, what was sent from here), what has files and the
      // rest made and let go as before)
      reused=fn(k) {
        guard !came_at.contains(k) && !out_plans.contains(chat_piece_of(k)) && !out_taken.contains(chat_piece_of(k)) &&
          !@sfbase.sent_from_waits(k) else {
          return None
        }
        @signals.untracked(fn() { (list.row)(k) }).bind(fn(r) { chat_body_shape(here, r) })
      },
      make_reused=fn(slot, key) { row_of(slot, key) },
      fn(slot, k) { row_of(slot, fn() { k }) },
    )
    |> ignore
    // (cut to itself at rest; not while its column is laid out narrower than it is drawn, the page on its way to another
    // width as the side panel slides (@sfbase.column_laid): what is in its foot is drawn as wide as the column is drawn
    // (the composer, the round buttons over it, the rail), past the narrower width the list is laid out at, and was cut
    // there, the composer's ＋ and send gone from it as the panel set off)
    // (cut at rest, bound to the way only once a column has first set off on one, at that cause)
    let chat_k = here.station + "\u{1}" + here.session
    let bind = fn() { o.clips(By(fn() { @sfbase.column_laid(chat_k, o).by <= 0.0 })) |> ignore }
    if @signals.untracked(fn() { @sfbase.column_set_off_count() > 0 }) {
      bind()
    } else {
      o.clips(Is(true)) |> ignore
      let bound = Ref(false)
      o.reacts(fn() { @sfbase.column_set_off_count() > 0 }, at_start=false, fn(going) {
        if going && !bound.val && o.alive() {
          bound.val = true
          bind()
        }
      })
    }
  })
  |> ignore
  if opened is Some((k, offset)) && !@sfbase.go_tos.contains(chat) {
    chat_stand(jump, place, k, offset)
  }
  // (where the core says the chat was left come only after the list was made at its end, nothing done there since (the
  // hand, a go-to, words sent): put there then, once)
  let late = Ref(opened is None && @signals.untracked(here.view).at is None)
  let sent_then = @signals.untracked(fn() { @sfbase.sent_here_count(chat) })
  v.reacts(fn() { (here.view)().at }, at_start=false, fn(at) {
    guard late.val && at is Some(_) else { return }
    late.val = false
    guard !scroll.in_hand() &&
      scroll.at_foot_now() &&
      !@sfbase.go_tos.contains(chat) &&
      @sfbase.sent_here_count(chat) == sent_then else {
      return
    }
    match opens() {
      Some((k, offset)) => {
        jump.put.set(1)
        chat_stand(jump, place, k, offset)
      }
      None => ()
    }
  })
  v.reacts(fn() { scroll.in_hand() }, at_start=false, fn(held) { if held { late.val = false } })
  // (what covers its top come to be taller, the bar's second row measured: where the page put the list, under it)
  match cover_to {
    Some(to) => v.reacts(to, at_start=false, fn(to) { chat_stand_again(jump, place, to, @signals.untracked(cover)) })
    None => ()
  }
  match to {
    Some(r) => {
      chat_goes_to(v, src, r, jump, place, scroll, list, here.view, cover, top, width, shows)
      // (over the list: a passage a mouse picked in a message quoted by its pill)
      chat_quote_node(v, src, r, here, list, place)
      // (a picture's 复制图片 chosen in its menu: read whole and put on the clipboard)
      menus_image_node(v)
      // something sent from here into the chat (words, an answer picked on a card: sfbase's sent_here_told), read up
      // the list: it goes to its end as it is sent (where the window is short of the chat's end, as its latest page,
      // asked by the send, comes in: chat_jump_node's)
      v.reacts(
        fn() { @sfbase.sent_here_count(chat) },
        fn(_) {
          if @signals.untracked(here.view).newer {
            jump.latest = true
          } else if !scroll.at_foot_now() {
            // (a go-to: words sent from the composer take the reader to its foot in the send's frame, their bubble
            // flying in as at its foot with no glide beside a flight; an answer picked on a card has no flight, so the
            // list glides smoothly to its end as the old list did)
            place.to_end(glide=!@sfbase.sent_here_flies(chat))
          }
        },
        at_start=false,
      )
      // ⌘↓ (chat.latest, the keymap's Chat with the field empty): as the way to the newest is pressed
      v.on_action("chat.latest", fn(_) {
        chat_to_newest(src, r, jump, place, here.view)
        true
      })
      // ⌘G 对话目录, ⌥⇧↑ and ⌥⇧↓ the message a person said before and after the reader's (outline_entries_of's keys;
      // none in a replay of a run from before the outline, Source's `asks_outline`); ⌘G's beside the round button
      // while it shows, else beside the rail while that does; the steps along the outline while the rail holds it
      .on_action("chat.outline", fn(_) {
        (src.asks_outline)() &&
        outline_open_keys(
          src,
          r,
          chat_whole(src, r, @signals.untracked(here.view)),
          stint=@signals.untracked(here.stint),
          button?=jump.outline_at,
          rail?=jump.rail_at,
        )
      })
      .on_action("chat.said.prev", fn(_) {
        (src.asks_outline)() && said_go(src, r, chat_whole(src, r, @signals.untracked(here.view)), -1, railed=jump.rail_at is Some(_))
      })
      .on_action("chat.said.next", fn(_) {
        (src.asks_outline)() && said_go(src, r, chat_whole(src, r, @signals.untracked(here.view)), 1, railed=jump.rail_at is Some(_))
      })
      |> ignore
    }
    None => ()
  }
  // the unread line come after it was made (what came while the app was away, read after the chat opened): there once,
  // as at a chat opened with it, while the list is still at its end and no message is asked to be gone to
  let lined = Ref(@signals.untracked(fn() { list.has("line") }))
  v.reacts(
    fn() { list.has("line") },
    fn(has) {
      guard has && !lined.val else { return }
      lined.val = true
      if chat_follows_foot(scroll) && !@sfbase.go_tos.contains(chat) {
        // (the line itself `lead` under the list's top, the room over its block over that: chat_open_place's)
        let gap = match (list.row)("line") {
          Some(row) => chat_body_gap_room(row.gap, width())
          None => 0.0
        }
        chat_stand(
          jump,
          place,
          "line",
          @sfbase.kept_place_under(@signals.untracked(top) + lead - gap, @signals.untracked(cover)),
        )
      }
    },
    at_start=false,
  )
  // the newest row come while the list follows its foot (sfbase's follow_newest: not where it stands, an agent's line,
  // the way to the newer): read from its top, its foot followed no further than its top as far under the bar as the
  // list's head keeps its first row, and follow_margin more (ListPlace::follow_from); the viewer's own followed all the
  // way to the foot, as they wrote it. Taken as the keys change, at that change's moment, while it is at its foot then;
  // only for a key that came by that change: the newest another because the last went (a refused send deleted, a
  // message taken back) is no answer come, and says nothing
  // (the keys as they were before the change that gave these: read again for the same change, the same)
  let keys_now : Ref[Array[String]] = Ref([])
  let keys_before : Ref[Array[String]] = Ref([])
  // (whether a key came by the change that gave these keys, as last found: the same keys and key, not looked for among
  // all of them again for each word streamed into a row)
  let came_last : Ref[(Array[String], String, Bool)?] = Ref(None)
  // (a message by its key, its first piece's: a long message streamed on into another piece is the message it was, its
  // top what is followed from, never a piece of it come)
  let newest = fn() -> (String, Bool, Bool)? {
    let rs_keys = keys.get()
    if !physical_equal(rs_keys, keys_now.val) {
      keys_before.val = keys_now.val
      keys_now.val = rs_keys
    }
    let before = keys_before.val
    let mut i = rs_keys.length() - 1
    while i >= 0 {
      let k = chat_piece_of(rs_keys[i])
      let came = match came_last.val {
        Some((b, ck, c)) if physical_equal(b, before) && ck == k => c
        _ => {
          let c = !before.contains(k)
          came_last.val = Some((before, k, c))
          c
        }
      }
      match (list.row)(k).map(fn(r) { r.entry }) {
        Some(State(_, _, _) | Working(_) | Newer) | None => ()
        Some(Out(_)) => return Some((k, true, came))
        Some(Said(m)) => return Some((k, m.mine, came))
        Some(_) => return Some((k, false, came))
      }
      i = i - 1
    }
    None
  }
  let newest_was : Ref[String?] = Ref(@signals.untracked(newest).map(fn(n) { n.0 }))
  // (whether the list is at its foot read with the newest, by this watch, as the same change gives both: read untracked
  // as it was told, the list's at-foot was worked out with nothing following it, and so held what it read, the
  // chat's subscription with it, past the page)
  v.reacts(
    fn() { (newest(), chat_follows_foot(scroll)) },
    fn(now_at) {
      let (now, at_foot) = now_at
      let was = newest_was.val
      newest_was.val = now.map(fn(n) { n.0 })
      guard now is Some((k, own, true)) && was is Some(w) && w != k && at_foot else { return }
      if own {
        place.follow_from(None)
      } else {
        place.follow_from(Some(k), margin=room + @sfbase.follow_margin)
      }
    },
    at_start=false,
  )
  read(place, scroll, list)
  v
}

///|
/// What lights a message whole, in the list `o` makes (View::scrolls_window's `bands`): one band under all its rows
/// (a long message's pieces, each a row of `list`), across the list, from the middle of the room over its first row to
/// the middle of the room over the row `under` its last (that row's room as the list has it; none under it, as far
/// again as it starts under its own top), so the bands of two messages meet; never a piece of it each row's (2026-11-17:
/// a long answer's 11 rows each lit apart, a pixel between each where the list set their tops on the pixels). Lit so: the
/// message gone to whole (its flash, `jump`'s, chat_band_lit), and the last whose menu showed, right clicked or its ⋯'s
/// (lit while it shows, going as it closes, till another's shows).
fn chat_body_bands(
  o : @view.View,
  list : ChatBodyList,
  under : (String) -> String?,
  jump : ChatJump,
  here : MessageNodeHere,
) -> (() -> Array[@view.ListBand[String]], (@view.View, () -> @view.ListBand[String]) -> Unit) {
  let menu_last : @signals.Signal[String] = @signals.signal("", same=fn(a, b) { a == b })
  o.reacts(
    fn() {
      let k = @sfbase.message_menu.get()
      if k != "" {
        k
      } else {
        @sfbase.message_more.get()
      }
    },
    fn(k) { if k != "" { menu_last.set(k) } },
  )
  let lit = fn() {
    let out : Array[@view.ListBand[String]] = []
    let ks : Array[String] = []
    match chat_gone(jump) {
      (k, at, "") if k != "" && at >= 0.0 => ks.push(k)
      _ => ()
    }
    let m = menu_last.get()
    if m != "" && !ks.contains(m) {
      ks.push(m)
    }
    let w = (here.width)()
    for k in ks {
      guard (list.row)(k) is Some(first) else { continue }
      let mut last = k
      while true {
        match under(last) {
          Some(n) if chat_piece_of(n) == k => last = n
          _ => break
        }
      }
      let top = chat_body_gap_room(first.gap, w) / 2.0
      let foot = match under(last).bind(fn(n) { (list.row)(n) }) {
        Some(r) => chat_body_gap_room(r.gap, w) / 2.0
        None => top
      }
      out.push({ from: k, upto: last, top, foot })
    }
    out
  }
  let look = fn(v : @view.View, b : () -> @view.ListBand[String]) {
    let key = fn() { b().from }
    chat_band_lit(v, key, jump, chat_flash_way(v, key, jump), message_menu_band_way(v, key))
  }
  (lit, look)
}

///|
/// Row `k` of a chat's list in `slot` (entry_row's, its row's room round it: message_row_frame_node), as its kind's
/// row draws it, reading what it is by its key in `rows` as that changes; made again only as it comes to be another
/// kind. What it shows of being gone to (its flash, a search's words marked in it) as `jump` says; `came`, when its key
/// came into the list by data (an agent's line's first words in glyph by glyph from then; none: simply there). Its key
/// as it is now (`key`): one key all along for a block made for it, or the key of each row a block put by is taken for
/// in turn (View::scrolls_window's `reused`, chat_body_shape), what it shows of its row read through it, so the block
/// shows a row taken for it as one made for that row would.
fn chat_body_row(
  slot : @view.View,
  src : Source,
  here : MessageNodeHere,
  key : () -> String,
  rows : ChatBodyList,
  side : () -> Double,
  list_top : () -> Double,
  core : @settings.Core?,
  keeps : ChatBodyKeeps,
  made : (String, @view.View) -> Unit,
  jump : ChatJump,
  came : () -> Double?,
  out_plan : () -> AgentOutPlan?,
  lands : (Double) -> Unit,
) -> Unit {
  let first = @signals.untracked(fn() { (rows.row)(key()) })
  guard first is Some(first) else { return }
  // (as the list says it now, only as that row changed (chat_body_row_same): what changed in another row reads none of
  // this one again; one let go as its key goes reads what it last was; taken for another key, that key's)
  let last = Ref(first)
  let now = @signals.computed_by(fn(_) {
    match (rows.row)(key()) {
      Some(r) => {
        last.val = r
        r
      }
      None => last.val
    }
  }, same=chat_body_row_same)
  let row = fn() { now.get() }
  let entry = fn() { row().entry }
  let top = fn() { chat_body_gap_room(row().gap, (here.width)()) }
  // (the words ⌘F found while its bar is open in this chat, bold in a message's words, each coloured in and the time
  // the reader is at stroked: find_words_in, find_at_in; else a search's in the message it opened the chat at, bold,
  // each stroked: found_all)
  let chat = here.station + "\u{1}" + here.session
  let found = fn() {
    if find_chat() == chat {
      return find_words_in(chat)
    }
    match jump.found.get() {
      (at, marked) if at == chat_piece_of(key()) => marked
      _ => []
    }
  }
  let found_at = fn() -> Int? {
    guard find_chat() == chat else {
      return if jump.found.get().0 == chat_piece_of(key()) { Some(@sf.found_all) } else { None }
    }
    match entry() {
      Said(m) => Some(find_at_in(chat, m.seq))
      _ => Some(-1)
    }
  }
  slot.pick(fn() { chat_body_made_as(row()) }, fn(p, made_as) {
    let kind = made_as.0
    // (told what holds it as it is made, and again as it is taken for another key)
    made(@signals.untracked(key), p)
    p.reacts(key, fn(k) { made(k, p) }, at_start=false)
    let whole_key = fn() { chat_piece_of(key()) }
    // (gone to by a quote of a passage of it: that passage lit in its words alone as its flash goes (chat_passage_lit),
    // a piece of a long message gone to as the message is; one gone to whole is lit by the list's band:
    // chat_body_bands)
    let flash = chat_flash_way(p, whole_key, jump)
    let lit = chat_passage_lit(p, whole_key, jump, flash)
    let m0 = match @signals.untracked(entry) {
      Said(m) => m
      _ => chat_body_none
    }
    let m = fn() {
      match entry() {
        Said(m) => m
        _ => m0
      }
    }
    let frame = fn(body : (@view.View) -> Unit) { message_row_frame_node(p, key, side, top, body) |> ignore }
    match kind {
      KTop => p.box(fn(b) { b.height(By(fn() { Some(list_top()) })) |> ignore }) |> ignore
      KOlder => frame(fn(b) { pages_coming_node(b, fn() { true }) |> ignore })
      KOlderFailed =>
        frame(fn(b) {
          older_failed_node(b, fn() {
            match entry() {
              Older(why) => why
              _ => ""
            }
          })
          |> ignore
        })
      KEmpty => frame(fn(b) { chat_empty_node(b) |> ignore })
      KLine => frame(fn(b) { unread_line_node(b) |> ignore })
      KNewer => frame(fn(b) { pages_coming_node(b, fn() { false }) |> ignore })
      KMine => {
        // (on its way, or the core's message that took it over: one row, its words' node kept as it is taken over)
        let out = fn() -> Outgoing? {
          match entry() {
            Out(o) => Some(o)
            _ => None
          }
        }
        let mine = fn() {
          match entry() {
            Out(o) => outgoing_row(o)
            _ => m()
          }
        }
        // (正在发送 seen once it has been on its way a while, counted from when it was sent, the source's time of day
        // (chat_rows.mbt outbox_row's): that moment on the frames' clock, worked out as the row is made and as when it
        // was sent changes (the core's row taking it over), not read of the source's clock as it is drawn)
        // (at the column's right as it is drawn, on the page's way to another width, laid out where it goes: in from the
        // right edge it is drawn at by as much as the words at the left are in from its left (where they stood as it set
        // off, going to where they stand), so it goes with the page's right edge as they go with its left, never
        // stepping where the column is laid out anew: as much further right as the column is drawn wider, less what the
        // column is moved across by, twice (its own offset's, and the room in from the right as much again) (sfbase's
        // column_laid))
        p.offset(By(fn() {
          let c = @sfbase.column_laid(chat, p)
          (c.by - 2.0 * c.across, 0.0)
        }))
        |> ignore
        let since = @signals.signal(0.0)
        if @signals.untracked(fn() { out() is Some(_) }) {
          p.reacts(fn() { out().map(fn(o) { o.created_at }) }, fn(at) {
            match at {
              Some(at) => since.set(p.cause_at() - ((src.now)() - at))
              None => ()
            }
          })
        }
        mine_said_node(p, src, here, key, side, top, mine, found~, found_at~, lit~, share=message_share_of(src, here, mine), out~, since=fn() { since.get() }, lands~) |> ignore
      }
      KNotice => {
        // (its words, picked with the pointer, are of its key, as a message's are from where they are read: quoted by
        // it, all of them taken by 全选, chat_quote_node)
        picked_of_by(p, key)
        // (across the column's middle as it is drawn, on the page's way to another width: as a message of one's own
        // goes with the right edge (by - 2·across past where it is laid out) and the words at the left with the left
        // (no more than the column's own across), its pill goes half of the one, its middle with the drawn middle,
        // never stepping where the column is laid out anew (sfbase's column_laid))
        p.offset(By(fn() {
          let c = @sfbase.column_laid(chat, p)
          (c.by / 2.0 - c.across, 0.0)
        }))
        |> ignore
        notice_said_node(p, src, here, key, side, top, m, keeps.opened, keeps.copied) |> ignore
      }
      KPerson =>
        person_said_node(p, src, here, key, side, top, m, found~, found_at~, lit~, share=message_share_of(src, here, m)) |> ignore
      KAgent =>
        agent_said_node(p, src, here, whole_key, side, top, m, found~, found_at~, lit~, share=message_share_of(src, here, m), core~, ask_sought=fn() { jump.asked_card.get() == whole_key() }, out_of=out_plan(), piece=fn() { row().piece }, across_of=fn(b) {
          // (by the message it is of now, followed: a block taken for another's row scrolls that one's table across)
          // (a long table's alone, cut a few rows a piece: one in a block scrolls across on its own, the list's)
          chat_table_kept(keeps.tables, whole_key(), b).0
        }, tracks_of=fn(b) {
          // (its columns measured once for all its pieces, by the message it is of now as its scroll is)
          Some(chat_table_kept(keeps.tables, whole_key(), b).1)
        }, pieces_pointed=fn() {
          chat_pieces_of(keeps.pieces, whole_key()).get().iter().any(@sf.hovered_in_node)
        }, piece_made=fn(at) {
          // (among the pieces of the message it is a piece of now: of another, taken for a piece of that one)
          let put = fn(whole : String) {
            let held = chat_pieces_of(keeps.pieces, whole)
            held.set(@signals.untracked(fn() { held.get() }) + [at])
          }
          let take = fn(whole : String) {
            let held = chat_pieces_of(keeps.pieces, whole)
            held.set(@signals.untracked(fn() { held.get() }).filter(fn(o) { o.id() != at.id() }))
          }
          let of = Ref(@signals.untracked(whole_key))
          put(of.val)
          at.reacts(whole_key, fn(now) {
            take(of.val)
            of.val = now
            put(now)
          }, at_start=false)
          at.owns(fn() { take(of.val) }) |> ignore
        }, code=fn(lang) {
          let tag = (match lang.find(" ") {
            Some(i) => lang.clamped_view(end=i).to_owned()
            None => lang
          }).to_lower()
          if tag == "mermaid" {
            Some(fn(b, code) { @sfbase.viz_mermaid_node(b, src, here.station, code, fn() { @sf.theme().p.subtle }, here.tips) })
          } else {
            None
          }
        }) |> ignore
      KSent => {
        let s0 = match @signals.untracked(entry) {
          Sent(s) => s
          _ => @sfbase.elsewhere_of({})
        }
        sent_elsewhere_node(p, src, here, @signals.untracked(key), side, top, fn() {
          match entry() {
            Sent(s) => s
            _ => s0
          }
        })
        |> ignore
      }
      KState => {
        let said = fn() {
          match entry() {
            State(w, l, r) => (w, l, r)
            _ => ("", "", "")
          }
        }
        frame(fn(b) { chat_state_node(b, src, here, fn() { said().0 }, fn() { said().1 }, fn() { said().2 }) })
      }
      KWorking => {
        let a0 = match @signals.untracked(entry) {
          Working(a) => a
          _ => @sfbase.agent_of({})
        }
        working_said_node(
          p,
          src,
          here,
          @signals.untracked(key),
          side,
          top,
          fn() {
            match entry() {
              Working(a) => a
              _ => a0
            }
          },
          came,
          keeps.steadies,
          faces=keeps.faces,
        )
        |> ignore
      }
    }
  })
}

///|
/// A message as none: what a row of a message reads where its key says another kind of entry for the moment before it
/// is made again (chat_body_row's).
// kept across runs: a value (no field of it changes)
let chat_body_none : Message = @sfbase.message_of({})

///|
/// What was sent from here as none (chat_body_none's, of an outbox entry).
// kept across runs: a value (no field of it changes)
let chat_body_no_out : Outgoing = {
  id: "",
  text: "",
  words: None,
  attachments: [],
  quotes: [],
  state: "",
  error: "",
  joined: false,
  followed: false,
  seq: -1.0,
  time: None,
  waits: "",
  progress: None,
  uploads: [],
  created_at: 0.0,
  refused: false,
  held: false,
  unsure: false,
}

///|
/// How long after a read of the pages before or after failed (its `fails`th in a row, from 0) it is asked again: 300 ms,
/// twice as long each time it fails again, 30 s at most.
fn ask_again_ms(fails : Int) -> Double {
  let mut ms = 300.0
  for _ in 0..<fails {
    ms = ms * 2.0
    if ms >= 30000.0 {
      return 30000.0
    }
  }
  ms
}
