// A chat's own find on the desktop: ⌘F opens its bar in the chat's
// bar, in place of its buttons, so it covers nothing of the chat. The core looks in all the chat's messages
// (`chat.find`: those not in the window shown too, and with `bring` those not on the device), 120 ms after the last
// key, answering which have the words and how many times; the list goes to the one the reader is at (the window moved
// about it first where it is outside: `chat.around`), the words bold, each coloured in with a highlighter and the
// time the reader is at stroked under (search_marks.mbt). Enter the next, ⇧Enter the one before, Esc closes it;
// closed, what was looked for is forgotten. The list it goes along is the page's (FindList).

///|
/// What the core found (`chat.find`): the words looked for, the messages that have them (oldest first, each with how
/// many times), how many of the chat's entries were looked in of how many, and whether that was all of them.
#derive(Eq)
pub(all) struct Found {
  words : Array[String]
  hits : Array[(Double, Int)]
  held : Int
  of : Int
  whole : Bool
}

///|
/// What the find keeps of its own: the chat its bar is open in (its key, "" closed), its field, what is typed and what
/// was last asked of the core, what the core found (None nothing asked yet), the time the reader is at (which of its
/// messages, which time in it), whether what is not on the device is being read.
pub(all) struct Finding {
  chat : @signals.Signal[String]
  field : @ui.Field
  mut query : String
  asked : @signals.Signal[String]
  found : @signals.Signal[Found?]
  at : @signals.Signal[Int]
  k : @signals.Signal[Int]
  position : @signals.Signal[Int]
  total : @signals.Signal[Int]
  mut moves : Int
  bringing : @signals.Signal[Bool]
}

///|
pub let finding : Finding = {
  chat: @signals.signal("", same=fn(a, b) { a == b }),
  field: @ui.Field::new(),
  query: "",
  asked: @signals.signal("", same=fn(a, b) { a == b }),
  found: @signals.signal(None),
  at: @signals.signal(-1, same=fn(a, b) { a == b }),
  k: @signals.signal(0, same=fn(a, b) { a == b }),
  position: @signals.signal(0, same=fn(a, b) { a == b }),
  total: @signals.signal(0, same=fn(a, b) { a == b }),
  moves: 0,
  bringing: @signals.signal(false, same=fn(a, b) { a == b }),
}

///|
/// The list the find goes along (the page's message list): the messages showing (the first's
/// and the last's seq; -1 none), the list to a message with the words marked in it, its marks let go; how many times
/// the words are in each of the messages asked (by seq) it holds as it draws and marks them (what it holds not: the
/// core's count).
pub(all) struct FindList {
  showing : () -> (Double, Double)
  go : (Double, Array[String]) -> Unit
  forget : () -> Unit
  drawn : (Array[String], Array[Double]) -> Map[Double, Int]
}

///|
/// How many times `words` are in message `m` as its row draws and marks them: an agent's words as markdown_node draws
/// them (a link's address, a code block's none of them: @sf.markdown_found_count), else its words as they are.
fn find_times_drawn(m : Message, words : Array[String]) -> Int {
  match m.md {
    Some(_) => @sf.markdown_found_count(m.text, m.md, words)
    None => @sf.find_words(m.text, words).length()
  }
}

///|
/// A chat's key among the desktop's own: its station and session.
pub fn chat_key(r : ChatRef) -> String {
  r.station + "\u{1}" + r.session
}

///|
/// The chat ⌘F's bar is open in ("" none).
pub fn find_chat() -> String {
  finding.chat.get()
}

///|
/// ⌘F's bar open in the chat `key` (opened again: its field takes the keyboard again, as it comes to hold it).
pub fn find_open(key : String) -> Unit {
  // (the person's ⌘F: what it changes on the chat's page goes its way, @view.transition)
  @view.transition(fn() {
    if finding.chat.untracked() != key {
      find_close_now()
      // (what was typed before, kept by the bar as it went: forgotten as it opens again)
      finding.field.set("")
      finding.chat.set(key)
    }
    finding.field.focus()
  })
}

///|
/// ⌘F's bar closed: what it looked for forgotten (what the list marked for it is the page's to let go: FindList), the
/// keyboard let go of. Its field's words are left as they were for the bar as it leaves (it fades out showing what it
/// showed: find_bar_node), and emptied as it is opened again (find_open).
pub fn find_close() -> Unit {
  // (the person's: what it changes on the chat's page goes its way, @view.transition)
  @view.transition(find_close_now)
}

///|
/// find_close's work.
fn find_close_now() -> Unit {
  finding.field.let_go()
  finding.chat.set("")
  finding.query = ""
  finding.asked.set("")
  finding.found.set(None)
  finding.at.set(-1)
  finding.k.set(0)
  finding.position.set(0)
  finding.total.set(0)
  finding.moves = 0
  finding.bringing.set(false)
}

///|
/// ⌘F's bar closed and its field emptied too (a run's start: nothing of the run before kept).
pub fn find_reset() -> Unit {
  find_close()
  finding.field.set("")
}

///|
/// ⌘F's bar open in chat `key` with `words` typed (a screen's fixture).
pub fn find_preset(key : String, words : String) -> Unit {
  finding.chat.set(key)
  finding.field.set(words)
}

///|
/// The words to mark in every message of chat `key` drawn now: what ⌘F found while its bar is open in it.
pub fn find_words_in(key : String) -> Array[String] {
  match finding.found.get() {
    Some(f) if finding.chat.get() == key => f.words
    _ => []
  }
}

///|
/// Which time of what ⌘F found in message `seq` of chat `key` the reader is at (0 the first; -1 none: they are at
/// another message, or its bar is not open in the chat).
pub fn find_at_in(key : String, seq : Double) -> Int {
  let at = finding.at.get()
  match finding.found.get() {
    Some(f) if finding.chat.get() == key && at >= 0 && at < f.hits.length() && f.hits[at].0 == seq => finding.k.get()
    _ => -1
  }
}

///|
/// Which time in the message gone to the reader is at (0 the first).
pub fn find_k() -> Int {
  finding.k.get()
}

///|
/// Which of the messages found the reader is at (-1 none), and what is typed (a test's).
pub fn find_at() -> Int {
  finding.at.get()
}

///|
pub fn find_query() -> String {
  finding.query
}

///|
/// What the core answered `chat.find` with.
fn found_of(v : Json) -> Found {
  let words : Array[String] = []
  for w in items(Some(v), "words") {
    if w is String(s) {
      words.push(s)
    }
  }
  let hits = items(Some(v), "hits").map(fn(h) { (number(Some(h), "seq"), number(Some(h), "count").to_int()) })
  {
    words,
    hits,
    held: number(Some(v), "held").to_int(),
    of: number(Some(v), "of").to_int(),
    whole: flag(Some(v), "whole"),
  }
}

///|
/// The list to the time the reader is at: its message gone to, the words marked there.
fn find_go(list : FindList) -> Unit {
  match finding.found.get() {
    Some(f) if finding.at.get() >= 0 && finding.at.get() < f.hits.length() => (list.go)(f.hits[finding.at.get()].0, f.words)
    _ => ()
  }
}

///|
/// Where the reader goes among what was found, as the core says (`chat.find.go`, chat-find.ts): with `by` 0 where they
/// are while what was found still has it, else where they start (from the messages showing); else the next (1) or the
/// one before (-1). The list goes there as the reader moves to another message or another time in one. How many times
/// the words are in what the list holds as it marks them told (`drawn`), so a step goes along those marked, not those
/// the core counts in a message's text (a link's address, a code block's: never marked, a step onto them not moving).
fn find_move(src : Source, key : String, list : FindList, by : Int) -> Unit {
  let f = match finding.found.get() {
    Some(f) => f
    None => return
  }
  let at : Json = if finding.at.get() >= 0 && finding.at.get() < f.hits.length() {
    { "seq": Json::number(f.hits[finding.at.get()].0), "k": Json::number(finding.k.get().to_double()) }
  } else {
    Json::null()
  }
  let (from, to) = (list.showing)()
  let params : Map[String, Json] = {
    "hits": Json::array(
      f.hits.map(fn(h) { { "seq": Json::number(h.0), "count": Json::number(h.1.to_double()) } }),
    ),
    "at": at,
    "by": Json::number(by.to_double()),
  }
  if from >= 0.0 && to >= 0.0 {
    params["from"] = Json::number(from)
    params["to"] = Json::number(to)
  }
  let held = (list.drawn)(f.words, f.hits.map(fn(h) { h.0 }))
  let drawn : Map[String, Json] = Map([])
  for h in f.hits {
    match held.get(h.0) {
      Some(n) => drawn[h.0.to_int().to_string()] = Json::number(n.to_double())
      None => ()
    }
  }
  if !drawn.is_empty() {
    params["drawn"] = Json::object(drawn)
  }
  finding.moves += 1
  let n = finding.moves
  (src.call)("chat.find.go", Json::object(params), fn(res) {
    // (closed, typed on, or moved again since: an answer to what is no longer asked)
    if finding.chat.untracked() != key || finding.moves != n {
      return
    }
    match (res, finding.found.get()) {
      (Ok(j), Some(now)) => {
        let was = (finding.at.get(), finding.k.get())
        let seq = match field(Some(j), "at") {
          Some(Object(_)) as a => Some((number(a, "seq"), number(a, "k").to_int()))
          _ => None
        }
        match seq {
          Some((s, k)) => {
            finding.at.set(now.hits.search_by(fn(h) { h.0 == s }).unwrap_or(-1))
            finding.k.set(k)
          }
          None => {
            finding.at.set(-1)
            finding.k.set(0)
          }
        }
        finding.position.set(number(Some(j), "position").to_int())
        finding.total.set(number(Some(j), "total").to_int())
        if (finding.at.get(), finding.k.get()) != was {
          find_go(list)
        }
      }
      // the core an older one: where the reader is stays as it is
      _ => ()
    }
  })
}

///|
/// How long after the last key the chat is looked in.
pub let find_typing_ms : Double = 120.0

///|
/// The chat (station `station`, thread `thread`) looked in for `query`: at once in what the device holds, then with
/// what it does not.
fn find_ask(src : Source, station : String, thread : Double, key : String, list : FindList, query : String) -> Unit {
  finding.asked.set(query)
  let q = query.trim(chars=" ").to_owned()
  if q == "" {
    finding.found.set(None)
    finding.at.set(-1)
    finding.k.set(0)
    finding.position.set(0)
    finding.total.set(0)
    finding.bringing.set(false)
    return
  }
  ask_bringing(
    src,
    "chat.find",
    { "station": Json::string(station), "thread": Json::number(thread), "query": Json::string(q) },
    // (typed on since, or closed: an answer to what is no longer asked)
    fn() { finding.asked.get() == query && finding.chat.untracked() == key },
    fn(j, bring) {
      let f = found_of(j)
      // where the reader was, as a message of what is found now (gone: none)
      let was = match finding.found.get() {
        Some(o) if bring && finding.at.get() >= 0 && finding.at.get() < o.hits.length() => o.hits[finding.at.get()].0
        _ => -1.0
      }
      finding.found.set(Some(f))
      finding.bringing.set(false)
      finding.at.set(f.hits.search_by(fn(h) { h.0 == was }).unwrap_or(-1))
      if finding.at.get() < 0 {
        finding.k.set(0)
      }
      finding.position.set(0)
      finding.total.set(f.hits.fold(init=0, fn(n, h) { n + h.1 }))
      // kept where it is still found, else where the reader starts (the core's)
      find_move(src, key, list, 0)
    },
    bringing=fn() { finding.bringing.set(true) },
    // its station away, or the core an older one: what was found stays as it is
    failed=fn() { finding.bringing.set(false) },
  )
}

///|
/// A chat looked in for words as the chat's find and its outline look (`call`: `chat.find`, `chat.outline.find`, with
/// `params`, its station, thread and query): at once in what the device holds, then, where that answer says it was not
/// all of the chat (`whole`), again with what it does not (`bring`), `bringing` told as that is asked. Each answer given
/// `answer` (with whether it was the one that brought the rest) while `still()` holds (typed on since, or closed: an
/// answer to what is no longer asked, let be); `failed` as one fails (its station away, the core an older one).
pub fn ask_bringing(
  src : Source,
  call : String,
  params : Map[String, Json],
  still : () -> Bool,
  answer : (Json, Bool) -> Unit,
  bringing? : () -> Unit = fn() {  },
  failed? : () -> Unit = fn() {  },
) -> Unit {
  fn ask(bring : Bool) {
    let p = params.copy()
    p["bring"] = Json::boolean(bring)
    (src.call)(call, Json::object(p), fn(res) {
      if !still() {
        return
      }
      match res {
        Ok(j) => {
          answer(j, bring)
          if !bring && !flag(Some(j), "whole") {
            bringing()
            ask(true)
          }
        }
        Err(_) => failed()
      }
    })
  }

  ask(false)
}

///|
/// Which of how many times the words are in the chat the reader is at (1 the first; 0 none), as the core said it.
pub fn find_position() -> (Int, Int) {
  (finding.position.get(), finding.total.get())
}

///|
pub let find_key : String = "find/field"

///|
/// How wide its field is (less where the bar has less: 160 at least), and each of its
/// buttons (button: 26 square).
let find_field_w : Double = 320.0

///|
let find_field_least : Double = 160.0

///|
let find_button_w : Double = 26.0

///|
/// The field's height (32: S8): a capsule.
pub let find_field_h : Double = 32.0

///|
/// How light the strokes under the words in the messages other than the one the reader is at are.
pub let find_faint : Double = 0.45

///|
// kept across runs: a value (no field of it changes)
let find_bar_style : @ui.Style = @ui.css("row gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let find_note_box : @ui.Style = @ui.style(max_w=Fixed(find_field_w), clip=true)

///|
// kept across runs: a value (no field of it changes)
let find_field_style : @ui.Style = @ui.style(
  row=true,
  w=Fixed(find_field_w),
  min_w=Fixed(find_field_least),
  h=S8,
  pl=S3,
  pr=@sf.capsule_end_room(find_field_h, find_button_w),
  gap=S0_5,
  align=ACenter,
  radius=Full,
  border=B1,
  border_color=Line,
  bg=Raised,
)

///|
// kept across runs: a value (no field of it changes)
let find_meta : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)
