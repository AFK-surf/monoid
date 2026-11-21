// A chat, read (Messages): its bar over its messages
// (back, the title, its people and its agents' marks with the station they run on, "…"), the messages as the core's
// `chat` view gives them, newest at the bottom, the list following its newest while it is at its end and "jump to
// the newest" over the composer's room otherwise; the page before loaded as the reader nears the top, what is in view
// staying put. While the chat is read the first time, the messages to come in their bones (the library's Waiting), what is
// wrong over them in red.
//
// What the page tells the core of the reader (the chat shown and its end seen: `client.focus`, which marks it read;
// where it was left: `chat.place`) is not said with MBUI_READONLY=1 (Source.readonly): a run on a real account then
// changes nothing in it. The composer at its foot is composer.mbt's.



///|
/// The bar's height (Home's top bar's, bar_h: the two bars' lines meet as the page is swiped back) and the room
/// the list keeps under it; the composer's room at the foot (ChatHost.kt roomForList: a line of words, the capsule's
/// insets, its toolbar and margins) and the list's under it.
let chat_bar_h : Double = bar_h

///|
/// The title's line in the bar (16 on the theme's 1.4em).
let chat_title_line : Double = 16.0 * 1.4

///|
/// Where the chat's bar ends, from the list's top (the list runs on under it), and what the list keeps over its first
/// row: 14 under the bar.
fn bar_foot() -> Double {
  status_top() + chat_bar_h
}

///|
/// Where the chat's bar is drawn to now (its second row as far as it shows): what covers the list's top, its room under
/// it the list's (list_room).
fn bar_foot_live(v : @view.View, r : ChatRef) -> Double {
  bar_foot() + bar_extra_shown(v, r)
}

///|
/// The room the list keeps under the chat's bar over its first row: 14.
let list_room : Double = 14.0

///|
/// What the list keeps under its last row over the composer's room: 10.
fn list_foot() -> Double {
  10.0
}

///|
/// How far under the list's top the unread line opens: a few lines of what came before it in view.
fn unread_lead() -> Double {
  85.0
}

///|
/// A chat opened over Home from the start at its message `seq`, as a notification opens it; `held`: its flash kept at
/// its peak (screenshots of it).
pub fn open_chat_at(r : ChatRef, seq : Double, held? : Bool = false) -> Unit {
  @sfbase.history_push()
  flash_held.val = held
  go_to(r, seq, keep_place=false)
  app.nav.push(Chat(r))
}

///|
/// The chat left (its page gone): the core told it shows no more, and where it was left (`chat.place`: the message
/// at the top, none at its end). Never with Source.readonly.
fn chat_left(src : Source, r : ChatRef, saved? : ChatView? = None) -> Unit {
  let k = r.station + "\u{1}" + r.session
  let kept = match saved { Some(view) => Some(view); None => @sfbase.chat_kept_from(src, r) }
  // (a page made as nodes tells it of what its list had in sight: sfpages' chat_read_node)
  let told = @sfpages.chat_read_left(src, r, kept)
  match (kept, readings.get(k)) {
    (Some(v), Some(rd)) if !told && !src.read_only => {
      (src.call)("client.focus", { "left": focus_chat(r, v, None) }, @sfbase.answer_unread)
      match v.thread {
        Some(_) if rd.placed => tell_place(src, r, v, rd, exact=true)
        _ => ()
      }
    }
    _ => ()
  }
  pick_clear()
  readings.remove(k)
  // (its bar made as nodes keeps its state while the page's nodes are kept, put by on the stack's kept left: only
  // closed again, let go as that bar is, chat_bar_of)
  match chat_bar_states.get(k) {
    Some(state) => state.manual_expanded.set(false)
    None => ()
  }
  // what holds the chat's thread at the core with it (its jobs in the bar and their sheets, the images beside one
  // opened from it): while any is held the core keeps the thread's window as first read, and the chat opened again
  // where it was first opened, not where it was left (views.ts: chatJobs and imageNear are of the chat's topic)
  @sfbase.chat_inputs_left_from(src, r)
  (src.leave)("chat", chat_params(r), @sfbase.TopicLeave::Legacy)
  (src.leave)("chatJobs", chat_params(r), @sfbase.TopicLeave::Legacy)
  (src.leave)("chatJobs", chat_jobs_summary_params(r), @sfbase.TopicLeave::Legacy)
  (src.leave)("chatFeedback", chat_params(r), @sfbase.TopicLeave::Legacy)
  // what its agents' lines and its jobs' sheets read: their work as it goes, their logs as they grow
  @sfbase.let_go(src, @sfbase.chat_scope(r.station, r.session))
  @sfbase.let_go(src, @sfbase.jobs_scope(r.station))
  // what its agents and other chats' wrote each other, read for its sheet: let go if it was (held only once opened)
  match dui.letters_held.get(k) {
    Some(th) => {
      (src.leave)("chatLetters", letters_params(r, th), @sfbase.TopicLeave::Legacy)
      dui.letters_held.remove(k)
    }
    None => ()
  }
  near_left(src, r.station)
}

///|
/// Which of the chat's asks the bell went to last, by chat (it goes to the next one each time, round again).
let ask_turns : Map[String, Int] = Map([])

///|
let bar_drop_people : Int = 1

///|
/// The tag's height (its words' 16 and 2 over and under), its words' room at its ends, its dot's side.
let station_tag_h : Double = 20.0

///|
/// Where the dot leading a station's tag stands in its round end (a capsule's: round, @sf.capsule_in's room its half).
let station_dot_in : Double = @ui.capsule_in(station_tag_h / 2.0, via_dot_side, room=station_tag_h / 2.0)

///|
let station_tag_end : Double = 8.0

///|
let via_dot_side : Double = 7.0

///|
/// An agent's mark in the bar: 22 square on the card's ground with a line round it, its maker .6 of it,
/// a station's mark 13.
fn mark_side() -> Double {
  22.0
}

///|
fn mark_ground() -> (Int64, Double) {
  let p = @sf.theme().p
  (p.card, 1.0)
}

///|
/// Its corner: 6.
fn mark_corner(_side : Double) -> Double {
  6.0
}

///|
fn mark_logo(side : Double) -> Double {
  side * 0.6
}

///|
fn mark_station() -> Double {
  13.0
}

///|
fn station_part_type() -> (Double, Double, Double) {
  (96.0, 5.0, 14.0)
}

///|
/// MBUI_CHAT_BENCH=1: once the chat is in place, the pages before are brought in (held at its top) until it has 3000
/// messages or no more (a minute at most); then from its end it is scrolled up 600 frames at 40 a frame, and the
/// frames' times are said (CHATBENCH …) and the app ends.
let bench_on : Ref[Int] = { val: -1 }

///|
/// The bar's keys at its end (its archive, its jobs, its "…") as far apart as makes each a press's room across
/// (@sf.keys_apart: 2 with keyboard and mouse, 10 with touch), the room before each.
fn bar_keys_apart() -> Double {
  @sf.keys_apart(size=nav_key_side)
}
