// A chat read by key (the core's own way: client/core-ts AGENTS.md, rule 6): its head (all its view says but its
// messages) worked out of the topic's value as anything but a message changes it, and its messages kept by key as the
// core changes them item by item (@core.Sub::keyed's @signals.KeyedList), each read as a Message only as its item
// changes. So a word streamed into one message tells what reads that message and nothing else: no reader walks the
// chat, and what one change costs is the same in a chat of 50 messages as in one of 5,000. What reads the chat whole
// (view_of_chat: the old page, a chat's sheets) reads it as before.

///|
/// A chat's messages by key (the core's key of them as its JSON text: `seq` and `outgoing`), each read as a Message
/// only as its item changes (the same item, the same Message).
pub struct ChatMessages {
  priv list : @signals.KeyedList[String, Json]
  priv read : Map[String, (Json, Message)]
}

///|
/// Its keys in order: what reads them is told as one comes, goes or moves, never as a message changes.
pub fn ChatMessages::keys(self : ChatMessages) -> Array[String] {
  self.list.keys()
}

///|
/// Its keys in order as they stand, read by nothing.
pub fn ChatMessages::peek_keys(self : ChatMessages) -> Array[String] {
  self.list.peek_keys()
}

///|
/// Message `k` (none where it is not there): what reads it is told as that message changes, comes or goes.
pub fn ChatMessages::get(self : ChatMessages, k : String) -> Message? {
  match self.list.get(k) {
    Some(j) => Some(self.of(k, j))
    None => {
      self.read.remove(k)
      None
    }
  }
}

///|
/// Message `k` as it stands, read by nothing.
pub fn ChatMessages::peek(self : ChatMessages, k : String) -> Message? {
  match self.list.peek(k) {
    Some(j) => Some(self.of(k, j))
    None => None
  }
}

///|
/// How many it holds, read by nothing.
pub fn ChatMessages::count(self : ChatMessages) -> Int {
  self.list.count()
}

///|
/// The last of its messages from the end that `pick` takes (none where none does), read by what it reads of each:
/// looked at from the end no further than to find it (the newest, the last that is no system line).
pub fn ChatMessages::last_where(self : ChatMessages, pick : (Message) -> Bool) -> Message? {
  let keys = self.keys()
  let mut i = keys.length() - 1
  while i >= 0 {
    match self.get(keys[i]) {
      Some(m) if pick(m) => return Some(m)
      _ => ()
    }
    i = i - 1
  }
  None
}

///|
/// Message `k`'s item `j` read: as it was where it is the same item.
fn ChatMessages::of(self : ChatMessages, k : String, j : Json) -> Message {
  match self.read.get(k) {
    Some((was, m)) if physical_equal(was, j) => m
    _ => {
      chat_messages_read.val += 1
      let m = message_of(j)
      self.read[k] = (j, m)
      m
    }
  }
}

///|
/// How many messages chat_messages has read as Messages (message_of) in this run: what a test of the work a change
/// costs counts.
// kept across runs: a count a test reads as the difference over what it does, never its value
pub let chat_messages_read : Ref[Int] = Ref(0)

///|
// kept across runs: each kept by its list, which is its subscription's; one whose list is another made again
let chat_messages_kept : Map[String, ChatMessages] = Map([])

///|
/// Chat `r`'s messages by key as `src` keeps them (Source's topic_keyed), the same subscription its topic is read by:
/// none where the source keeps none (a made-up core that gives values whole: read through view_of_chat).
pub fn chat_messages(src : Source, r : ChatRef) -> ChatMessages? {
  let list = @signals.untracked(fn() {
    (src.topic_keyed)("chat", chat_params(r), "messages", ["seq", "outgoing"])
  })
  guard list is Some(list) else { return None }
  let key = chat_inputs_key(r)
  match chat_messages_kept.get(key) {
    Some(m) if physical_equal(m.list, list) => Some(m)
    _ => {
      let m = { list, read: {} }
      chat_messages_kept[key] = m
      Some(m)
    }
  }
}

///|
/// A chat's head as chat_head_read made it: the topic's value it was read from and the view.
priv struct ChatHead {
  raw : Json
  view : ChatView
}

///|
/// Whether chat heads `a` and `b` say the same (each part chat_view_of keeps as it was where its JSON is: by identity;
/// the rest by value).
fn chat_head_same(a : ChatView, b : ChatView) -> Bool {
  a.title == b.title &&
  a.thread == b.thread &&
  a.unread == b.unread &&
  physical_equal(a.people, b.people) &&
  physical_equal(a.agents, b.agents) &&
  physical_equal(a.elsewhere, b.elsewhere) &&
  a.more == b.more &&
  a.newer == b.newer &&
  a.first_entry == b.first_entry &&
  a.last_entry == b.last_entry &&
  a.older == b.older &&
  a.older_failed == b.older_failed &&
  a.letters == b.letters &&
  a.at == b.at &&
  a.at_offset == b.at_offset &&
  a.unread_line == b.unread_line &&
  a.unread_above == b.unread_above &&
  physical_equal(a.outbox, b.outbox) &&
  a.joins_until == b.joins_until &&
  a.offline == b.offline &&
  a.offline_note == b.offline_note &&
  a.updating == b.updating &&
  a.cache_cold == b.cache_cold &&
  a.state == b.state &&
  a.state_ask == b.state_ask &&
  a.ask_clear == b.ask_clear &&
  a.archived == b.archived &&
  a.archivable == b.archivable &&
  a.pending == b.pending &&
  a.key == b.key &&
  physical_equal(a.asks, b.asks) &&
  physical_equal(a.station_update, b.station_update) &&
  a.me == b.me &&
  physical_equal(a.tabs, b.tabs) &&
  physical_equal(a.cc, b.cc) &&
  physical_equal(a.screens, b.screens) &&
  physical_equal(a.opener, b.opener) &&
  physical_equal(a.opened, b.opened) &&
  a.opened_text == b.opened_text
}

///|
/// A chat's head: its view as the core gives it but its messages (none read: ChatMessages' by key), each part read
/// again only where its JSON is another (chat_view_of's `was`), and the view of before where it says the same, so what
/// reads it is told only as its head changes, not as a word comes into a message.
// kept across runs: what it keeps is let go of by a run anew and by reset (derived.mbt)
let chat_head_read : Derived[ChatHead] = Derived::new("chat", fn(v, was) {
  let view = chat_view_of(v, [], match was {
    Some(w) => Some((w.raw, w.view))
    None => None
  })
  match was {
    Some(w) if chat_head_same(w.view, view) => { raw: v, view: w.view }
    _ => { raw: v, view }
  }
})

///|
// kept across runs: the Kept is registered on first use and its stored values are cleared by kept_reset (derived.mbt)
let chat_heads : SourceKept[(ChatView?, Json?)] = { kept: {}, listed: false }

///|
/// Chat `r`'s head as `src` reads it (chat_head_read: its view but its messages) and its topic's error: what reads
/// it is told only as the head or the error is another, not as a message changes.
pub fn chat_head(src : Source, r : ChatRef) -> (ChatView?, Json?) {
  chat_heads.read(
    src,
    chat_inputs_key(r),
    fn(_) {
      let (read, topic) = chat_head_read.read(src, chat_params(r))
      (read.map(fn(h) { h.view }), topic.error)
    },
    same=fn(a, b) {
      let same_view = match (a.0, b.0) {
        (Some(x), Some(y)) => physical_equal(x, y)
        (None, None) => true
        _ => false
      }
      same_view && a.1 == b.1
    },
  )
}

///|
/// Chat `r`'s view for what reads its head alone (its bar, its composer, whether it needs the viewer): its head
/// (chat_head, what is on its way from here answering its last card as the core will say: chat_sent_here) where it is
/// no chat just made from here and `src` keeps its messages by key (what wants them reads them so: chat_messages), else
/// as view_of_chat works it out (sent_here_view's the same). Told as the head changes, not as a word
/// comes into a message.
pub fn chat_view_now(src : Source, r : ChatRef) -> ChatView? {
  if fresh_view(r) is None {
    // (the head read first: what holds the topic, whose messages by key are then there; what is on its way from here
    // answering its last card, as the core will say once it has it)
    match chat_head(src, r).0 {
      Some(h) =>
        match chat_messages(src, r) {
          Some(ms) => return Some(chat_sent_here(r, h, ms).0)
          None => ()
        }
      None => ()
    }
  }
  view_of_chat(src, r).0
}

///|
/// A chat's messages by key of list `list` (a subscription's, Sub::keyed's; a test's own), each read as a Message as it
/// is asked.
pub fn chat_messages_of(list : @signals.KeyedList[String, Json]) -> ChatMessages {
  { list, read: {} }
}

///|
/// How many times chat_read worked a chat out whole in this run (its view, its entries): what a test of the work a
/// change costs counts.
// kept across runs: a count a test reads as the difference over what it does, never its value
pub let chat_read_made : Ref[Int] = Ref(0)

///|
/// What words sent from here before the core has them make of chat `r`'s head `head` and its messages by key `ms`
/// (sent_here_view's, by key): where the chat's last card still waits and they were sent as it showed, with no
/// person's words after it, they answer it at once (no more asked, its decision theirs, the chat's asks without it,
/// where it stands gone as its agent has words to take), as the core will say once it has them. The head so, and the
/// card's message so by its key (none where they answer none). Looked for from the newest back no further than that card
/// or a person's words after it.
pub fn chat_sent_here(
  r : ChatRef,
  head : ChatView,
  ms : ChatMessages,
) -> (ChatView, (String, Message)?) {
  let sending = sending_now(r.station + "\u{1}" + r.session)
  guard !sending.is_empty() else { return (head, None) }
  let keys = ms.keys()
  let mut i = keys.length() - 1
  let mut card : (String, Message)? = None
  while i >= 0 {
    match ms.get(keys[i]) {
      Some(m) if m.card is Some(_) => {
        card = Some((keys[i], m))
        break
      }
      // (a person's words after the last card: the core's word stands)
      Some(m) if m.author_kind == "person" => return (head, None)
      _ => ()
    }
    i = i - 1
  }
  guard card is Some((k, m)) else { return (head, None) }
  guard m.decision is Some(d) && !d.resolved else { return (head, None) }
  guard sending.iter().any(fn(l) { m.seq <= l.newest }) else { return (head, None) }
  let said = @sf.t("core-logic.decisions.replied", args=[("name", @sf.t("core-logic.decisions.you"))])
  let answered = { ..m, asked: false, decision: Some({ resolved: true, dismissed: false, text: Some(said), chosen: None }) }
  let asks = head.asks.filter(fn(seq) { seq != m.seq })
  (
    { ..head, asks, ask_clear: head.ask_clear && !asks.is_empty(), state: None, state_ask: None },
    Some((k, answered)),
  )
}
