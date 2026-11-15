// A chat's list's rows by key (chat_body_node's, where its source keeps the chat's messages by key: sfbase's
// ChatMessages): each message's rows (the unread line over it where it is there, its blocks, what went elsewhere after
// it) worked out of that message alone, its own computed, and the list's keys of each message's keys and the chat's
// head (its page before, its emptiness, what went elsewhere before its messages; what is newer, where it stands and
// its agents at work after them). So a word streamed into a message works out that message's rows and reads none of
// the others; the list's keys are made again only as a message comes, goes or moves, or a message's own keys change
// (a block more), and a row reads only what it is. What is sent from here and what waits in the outbox are
// chat_body_rows' still: while there is any, the list goes by it (ChatBodyList::of_made).

///|
/// A chat's list as its rows read it: its keys (told only as they change) and each row by its key (told only as that
/// row is another).
priv struct ChatBodyList {
  keys : () -> Array[String]
  row : (String) -> ChatBodyRow?
}

///|
/// Whether the list has a row of key `k`, as its keys say.
fn ChatBodyList::has(self : ChatBodyList, k : String) -> Bool {
  (self.row)(k) is Some(_)
}

///|
/// The list of rows chat_body_rows made, as `made` gives them as they change (each read of a row reads all of them).
fn ChatBodyList::of_made(made : () -> ChatBodyRows) -> ChatBodyList {
  { keys: fn() { made().keys }, row: fn(k) { made().rows.get(k) } }
}

///|
/// The rows of one message (chat_body_parts_of's): their keys in order, each row by its key.
priv struct ChatBodyParts {
  keys : Array[String]
  rows : Map[String, ChatBodyRow]
}

///|
/// The rows message `m` is shown in, as chat_body_rows has them: the unread line over it where the chat's unread line
/// (`unread`) is at it; its own, a block a piece where it is in pieces, by its key (chat_body_key's, what was sent from
/// here as as `kept` says); what went elsewhere after it. The first of them, where it is the list's first (`first`), with
/// no room over it; the message's as it joins the one before or not; the rest apart.
fn chat_body_parts_of(kept : ChatBodyKept, m : Message, unread : Double?, first : Bool) -> ChatBodyParts {
  let keys : Array[String] = []
  let rows : Map[String, ChatBodyRow] = Map([])
  let mut lead = first
  let gap_of = fn(joined : Bool) {
    if lead {
      NoGap
    } else if joined {
      Joined
    } else {
      Apart
    }
  }
  if unread == Some(m.seq) {
    keys.push("line")
    rows["line"] = { entry: Entry::Line, gap: gap_of(false), piece: None }
    lead = false
  }
  let e = Entry::Said(m)
  if m.outgoing != "" {
    kept.sent[m.seq] = m.outgoing
  }
  let k = chat_body_key(kept, e)
  let gap = gap_of(m.joined)
  lead = false
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
  for s in m.elsewhere {
    let se = Entry::Sent(s)
    let sk = se.id()
    rows[sk] = { entry: se, gap: Apart, piece: None }
    keys.push(sk)
  }
  { keys, rows }
}

///|
/// The rows of a chat's head over its messages (`first_in`: whether its first message's first row is the list's
/// first, nothing of these over it) and under them, as chat_entries and chat_body_rows have them: the page before, the
/// chat empty, what went elsewhere before its messages; what is newer, where it stands and its agents at work.
fn chat_body_head_parts(v : ChatView, empty : Bool) -> (ChatBodyParts, ChatBodyParts) {
  let over : ChatBodyParts = { keys: [], rows: Map([]) }
  let under : ChatBodyParts = { keys: [], rows: Map([]) }
  // (the list's first row has no room over it: the first over the messages, or under them where nothing is over them)
  let put = fn(p : ChatBodyParts, e : Entry, first : Bool) {
    let k = e.id()
    p.rows[k] = { entry: e, gap: if first { NoGap } else { Apart }, piece: None }
    p.keys.push(k)
  }
  if v.more {
    put(over, Entry::Older(if v.older == "failed" { v.older_failed } else { "" }), over.keys.is_empty())
  }
  if empty && v.outbox.length() == 0 && v.elsewhere.length() == 0 && !v.more {
    put(over, Entry::Empty, over.keys.is_empty())
  }
  for e in v.elsewhere {
    put(over, Entry::Sent(e), over.keys.is_empty())
  }
  let lone = fn() { empty && over.keys.is_empty() && under.keys.is_empty() }
  if v.newer {
    put(under, Entry::Newer, lone())
  } else {
    match v.state {
      Some((words, lead, rest)) => put(under, Entry::State(words, lead, rest), lone())
      None => ()
    }
    for a in v.agents {
      if a.status == "running" || a.status == "queued" {
        put(under, Entry::Working(a), lone())
      }
    }
  }
  (over, under)
}

///|
/// A chat's list by key (the head above): its head `head` as it changes (sfbase's chat_head: none of its messages),
/// its messages `msgs` by key (sfbase's ChatMessages), what was sent from here as `kept` keeps it (read again as
/// `kept_told` changes: chat_body_rows wrote it). Each message's rows a computed of its own, made as its key is first
/// seen and let go as it goes.
fn chat_body_keyed(
  kept : ChatBodyKept,
  kept_told : @signals.Computed[Int],
  head : () -> ChatView,
  msgs : @sfbase.ChatMessages,
) -> ChatBodyList {
  // (the message whose first row is the list's first: the first, where nothing of the head is over it)
  let first = @signals.computed(
    fn(_) {
      let v = head()
      if v.more || !v.elsewhere.is_empty() {
        None
      } else {
        msgs.keys().get(0)
      }
    },
    same=fn(a, b) { a == b },
  )
  let unread = @signals.computed(fn(_) { head().unread_line }, same=fn(a, b) { a == b })
  let parts : Map[String, @signals.Computed[ChatBodyParts]] = Map([])
  let part_keys : Map[String, @signals.Computed[Array[String]]] = Map([])
  let parts_of = fn(mk : String) -> @signals.Computed[ChatBodyParts] {
    match parts.get(mk) {
      Some(p) => p
      None => {
        let none : ChatBodyParts = { keys: [], rows: Map([]) }
        // (where it stands as the head says: the unread line over it, the list's first; as that changes for it, not
        // as it changes for another: a bool of its own, the rows made again only for the one it changed for)
        let at = @signals.computed(
          fn(_) {
            let line = match (unread.get(), msgs.get(mk)) {
              (Some(l), Some(m)) => l == m.seq
              _ => false
            }
            (line, first.get() == Some(mk))
          },
          same=fn(a, b) { a == b },
        )
        let p = @signals.computed(fn(_) {
          kept_told.get() |> ignore
          let (line, lead) = at.get()
          match msgs.get(mk) {
            Some(m) => chat_body_parts_of(kept, m, if line { Some(m.seq) } else { None }, lead)
            None => none
          }
        })
        parts[mk] = p
        p
      }
    }
  }
  let keys_of = fn(mk : String) -> @signals.Computed[Array[String]] {
    match part_keys.get(mk) {
      Some(p) => p
      None => {
        let p = @signals.computed(fn(_) { parts_of(mk).get().keys }, same=fn(a, b) { a == b })
        part_keys[mk] = p
        p
      }
    }
  }
  let ends = @signals.computed(
    fn(_) { chat_body_head_parts(head(), msgs.keys().is_empty()) },
    same=fn(a, b) {
      a.0.keys == b.0.keys &&
      a.1.keys == b.1.keys &&
      a.0.keys.iter().all(fn(k) { chat_body_row_same(a.0.rows[k], b.0.rows[k]) }) &&
      a.1.keys.iter().all(fn(k) { chat_body_row_same(a.1.rows[k], b.1.rows[k]) })
    },
  )
  // (whose each row is: a message's key, or "" for the head's; as the keys were last made)
  let owner : Map[String, String] = Map([])
  let keys = @signals.computed(
    fn(_) {
      let (over, under) = ends.get()
      let out = over.keys.copy()
      owner.clear()
      for k in over.keys {
        owner[k] = ""
      }
      let order = msgs.keys()
      for mk in order {
        for k in keys_of(mk).get() {
          owner[k] = mk
          out.push(k)
        }
      }
      for k in under.keys {
        owner[k] = ""
        out.push(k)
      }
      // (a message gone: its rows' computeds let go)
      if parts.length() > order.length() {
        let here : Map[String, Bool] = Map([])
        for mk in order {
          here[mk] = true
        }
        let gone = parts.keys().filter(fn(mk) { !here.contains(mk) }).collect()
        for mk in gone {
          parts.remove(mk)
          part_keys.remove(mk)
        }
      }
      out
    },
    same=fn(a, b) { physical_equal(a, b) || a == b },
  )
  {
    keys: fn() { keys.get() },
    row: fn(k) {
      keys.get() |> ignore
      match owner.get(k) {
        Some("") => {
          let (over, under) = ends.get()
          match over.rows.get(k) {
            Some(r) => Some(r)
            None => under.rows.get(k)
          }
        }
        Some(mk) => parts_of(mk).get().rows.get(k)
        None => None
      }
    },
  }
}

///|
/// A chat's list as read at once (ChatBodyList::read): its keys then, and each row by its key as it is asked.
priv struct ChatBodyNow {
  keys : Array[String]
  row_of : (String) -> ChatBodyRow?
}

///|
/// Its keys as they are now, and its rows as each is asked (what reads them in a computed follows what it reads).
fn ChatBodyList::read(self : ChatBodyList) -> ChatBodyNow {
  { keys: (self.keys)(), row_of: self.row }
}

///|
/// Row `k`.
fn ChatBodyNow::get(self : ChatBodyNow, k : String) -> ChatBodyRow? {
  (self.row_of)(k)
}

///|
/// Chat `r`'s view `v` with its messages: as it is where it holds them (read whole: view_of_chat's), else its head with
/// those `src` keeps by key (sfbase's ChatMessages), all of them read. For what a press reads of the whole chat (the
/// outline's steps, a message found by its time), never as a row is drawn.
fn chat_whole(src : Source, r : ChatRef, v : ChatView) -> ChatView {
  guard v.messages.is_empty() else { return v }
  { ..v, messages: chat_said_all(src, r, fn() { v }) }
}

///|
/// Chat `r`'s messages, its view `view`'s where it holds them, else those `src` keeps by key: read at once, followed by
/// nothing (a press's).
fn chat_said_all(src : Source, r : ChatRef, view : () -> ChatView) -> Array[Message] {
  @signals.untracked(fn() {
    let v = view()
    guard v.messages.is_empty() else { return v.messages }
    match @sfbase.chat_messages(src, r) {
      Some(ms) => ms.peek_keys().filter_map(fn(k) { ms.peek(k) })
      // (a source that keeps none by key: the chat read whole)
      None =>
        match @sfbase.view_of_chat(src, r).0 {
          Some(w) => w.messages
          None => v.messages
        }
    }
  })
}

///|
/// Chat `r`'s first and last messages (its view `view`'s, else those `src` keeps by key: the first and last of its keys),
/// as they change.
fn chat_said_ends(src : Source, r : ChatRef, view : () -> ChatView) -> (Message?, Message?) {
  let v = view()
  guard v.messages.is_empty() else { return (v.messages.get(0), v.messages.last()) }
  match @sfbase.chat_messages(src, r) {
    Some(ms) => {
      let keys = ms.keys()
      (keys.get(0).bind(fn(k) { ms.get(k) }), keys.last().bind(fn(k) { ms.get(k) }))
    }
    None => (None, None)
  }
}

///|
/// The newest of chat `r`'s messages' seqs (-1: none), as chat_said_ends reads them: its last.
fn chat_said_latest(src : Source, r : ChatRef, view : () -> ChatView) -> Double {
  let v = view()
  guard v.messages.is_empty() else {
    return v.messages.fold(init=-1.0, fn(m, x) { if x.seq > m { x.seq } else { m } })
  }
  match chat_said_ends(src, r, view).1 {
    Some(m) => m.seq
    None => -1.0
  }
}

///|
/// The entries a chat's page reads where its rows are by key (none: chat_body_keyed's own), the same each time.
// kept across runs: never written
let chat_no_entries : Array[Entry] = []
