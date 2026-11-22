// A chat's list as both frames keep it (src/sfapp/chat.mbt the phone's, src/sfdesk's the desktop's): its rows, what
// the page keeps of a chat while it shows (Reading), where it was left, the rows new to it and their turns, the
// agents' lines lingering, the room they leave, what is read and where the reader is, told the core (client.focus,
// chat.place). Each frame draws the rows its own way.

///|
/// An entry of the list, with the room above the first (the bar's) and below the last (the
/// composer's).
#derive(Eq)
pub(all) enum Entry {
  Top
  /// the page before coming, or why it could not be read ("" coming)
  Older(String)
  Empty
  Line
  Said(Message)
  Sent(Elsewhere)
  Newer
  Out(Outgoing)
  /// where the chat stands (ChatView's `state`): its words, what leads them, what follows the lead
  State(String, String, String)
  Working(Agent)
  Foot
}

///|
pub fn Entry::id(self : Entry) -> String {
  match self {
    Top => "top"
    Older(_) => "older"
    Empty => "empty"
    Line => "line"
    Said(m) => "m:" + m.ts
    Sent(e) => "s:" + e.key
    Newer => "newer"
    Out(o) => "o:" + o.id
    State(_, _, _) => state_key
    Working(a) => "act:" + a.key
    Foot => "foot"
  }
}

///|
/// What the page keeps of a chat while it is open.
pub(all) struct Reading {
  /// what the room under its rows is kept for besides the composer (its end clear of the bell floating over it:
  /// ask_clears), the Foot row's version: its height goes to another as that changes (list_size.mbt)
  mut foot_sign : String
  /// the last words sent from here that let go of the composer (their row's key): the composer's room under the rows
  /// goes down where it comes to stand as they do, the Foot row's version with it
  mut sent_foot : String
  /// how its rows were last given laid out (shown_rows' `laid`): their versions read again as that changes
  mut rows_laid : String
  /// the first message's entry and where it was in the list, the last frame
  mut head : String
  mut head_at : Int
  /// the window's first entry and whether it was short of the chat's end, as its rows were last given (paged_in)
  mut first_was : Double
  mut newer_was : Bool
  /// put in place once (the unread line, where it was opened, or the end)
  mut placed : Bool
  /// put at a message by the app (a go-to), not moved by the reader since: the page before not asked while it stands
  /// there; and where it stands (ListReader::place: the first row in view, how far its top is above the list's), taken
  /// the first time the page before would be asked there
  mut put_there : Bool
  mut put_place : (Int, Double)?
  mut put : Bool
  /// the moment it was put in place (-1 not yet): what floats over it (the way to the newest, the bell, the outline's
  /// button) stands as it is found from the frame after, coming and going from then, never set out by the list coming
  /// to its place as it opens (floats_settled)
  mut put_at : Double
  /// the unread line shown: put at once it is (it may come after the chat opened, what came while the app was away
  /// read from the station after it)
  mut lined : Bool
  /// the first message when the page before was asked for (once per page)
  asked : @signals.Signal[Double]
  asked_newer : @signals.Signal[Double]
  /// the chat's latest page asked for in place of a window short of its end (chat_latest): the list goes to its end
  /// as it comes
  mut latest_asked : Bool
  /// its end asked for where the list is not built (an option picked in one of its rows: decision.mbt, where its key
  /// names no list): gone to as what follows the list is built (list_after)
  mut end_asked : Bool
  /// what the core was told of the chat shown, its end seen or not ("" nothing yet)
  mut told : String
  /// the newest message seen whole on this visit (-1 none): read up to there
  mut seen_whole : Double
  /// where the reader is: the message at the top of what shows (-1 none), and whether at the chat's end
  mut top_seq : Double
  /// the message at the foot of what shows (-1 none): what ⌘F starts at lies between
  mut bottom_seq : Double
  /// how far that message's top is below the list's (points: above it, less than 0)
  mut top_off : Double
  /// of a message drawn in pieces (a page made as nodes: a long message a block a piece), which of its pieces is at the
  /// top and how far its top is under the list's (as kept: kept_place_of); -1 none (the old page's, a message of one)
  mut top_piece : Int
  mut top_piece_off : Double
  mut at_end : Bool
  /// where the core was last told the chat is (chat.place: "" not yet), and the screen's scale it was laid out at
  mut told_place : String
  /// the message at the top as it was last told (its seq, "" at its end)
  mut told_at : String
  mut scale : Double
  /// the jump button: shown since when (or hidden since when), and which
  mut jump : Bool
  mut jump_at : Double
  /// more than the list's own height from the chat's end as its list was last laid out (its last row's bottom that far
  /// under the view's, or the window short of the chat's end): where a go-to in the chat keeps where the reader was
  /// (jump.mbt keep_place_of)
  mut far : Bool
  /// the bell to what waits to be decided: shown
  mut ask : Bool
  /// a scripted scroll through it (MBUI_CHAT_BENCH): frames so far, their times
  mut bench : Int
  /// 0: bringing in the pages before (up to 3000 messages), 1: measuring
  mut bench_phase : Int
  mut bench_rows : Int
  bench_ms : Array[Double]
  bench_present : Array[Double]
  /// the rows drawn so far, by key (arrived); whether it has been
  /// drawn; the rows new to it since, until they show
  known : Map[String, Bool]
  mut drawn : Bool
  /// the rows at its end that go from it as its turns go (by key): its agents' lines, where it stands. One gone leaves
  /// its room as a floor; an agent's line gone is forgotten (row_keys)
  acts : Map[String, Bool]
  /// its list shown (built, or kept as its build left it and drawn again) in the build begun last (`shown`), and in
  /// the build before that (`was_shown`: linger_tick hands one to the other as each build begins); its own data taken
  /// in the build begun last (chat_tick, once a build: what comes out of its avatars played on, its activities'
  /// lingering; let go as each build begins, linger_tick)
  mut shown : Bool
  mut was_shown : Bool
  /// the moment its list was last shown again after it did not show (this visit's first: floats_settled), and the
  /// first moment on this visit it was found laid out where it is (floats_laid)
  mut shown_from : Double
  mut laid_from : Double
  mut played : Bool
  mut ticked : Bool
  /// the rows new to it, by key, until they show
  fresh : Map[String, Bool]
  /// the rows that came new to it while it shows, by key: the how-manieth (`came_n`), and the agent whose avatar it
  /// came out of ("" none). Words sent from here are not among them: they fly in (flight.mbt)
  came : Map[String, (Int, String)]
  mut came_n : Int
  /// what a row that makes way (an agent's line, what was sent not in the chat yet) last saw come in over it, as last
  /// built ("" nothing): its cause to glide down (sfpages chat_list)
  makes_way : Map[String, String]
  /// the newest row that came in over rows at its end while it was followed (what is at the end stays where it shows,
  /// the rows over it go up for it: sfpages chat_list; "" none yet)
  mut over : String
  /// rows that came into it new (Turns::admit)
  admitted : Map[String, Bool]
  /// the newest row (not an agent's line) as last built, and whether the list follows one from its top (Follow.kt
  /// anchor: a message arriving while it is followed is read from its start)
  mut newest : String
  mut following_row : Bool
  mut follow_key : String
  /// the outbox entries messages were sent from here as, by seq
  sent : Map[Double, String]
  /// the key each row of the core's that what was sent from here became goes on by: the key it had as it was sent
  /// ("o:local:n"), its one identity from the press on (its outbox entry's and its message's keys to it)
  sent_as : Map[String, String]
  /// Told when a local row is taken over, so a viewer opened before that can follow its new core identity.
  sent_as_told : @signals.Signal[Int]
  /// the keys (sent_as's) of rows taken over that were sent close under the row before them (LocalSent's `joined`): that
  /// row `followed`, its time line gone, and the core's row joined, through the takeover as from the press, the core's
  /// word changing nothing seen (the coordinator of the migration, 2026-11-15: one block, sent here and the core's)
  sent_joined : Map[String, Bool]
  /// agents whose turn ended, still shown while their messages come out of their avatars: Lingering
  linger : Map[String, Lingering]
  /// the agents' lines in the order they first came to the list, by their keys: they stand so, one whose turn ended
  /// lingering where it was, not put after the others (a line gone past another at once, 2026-11-03)
  act_order : Map[String, Int]
  mut acts_seen : Int
  /// told as one comes to linger or goes (what reads `linger` built again for it: it is said before any page is built)
  linger_said : @signals.Signal[Int]
  /// the room agents' lines left as they went from the list (none left now: the list never gets shorter under the
  /// reader, floor_wbtest); the rows laid out whole that would leave it, by key
  mut floor : Double
  act_whole : Map[String, Bool]
  /// the agents running as last drawn
  running : Map[String, Agent]
  /// agents at work whose answer has come out of their avatars this turn, by their last turn then (Agent.last_turn):
  /// their line gone with it till that turn is over (chat_tick)
  answered : Map[String, String]
  /// agents whose answer was here as they were first seen at work: their line kept taking no room, unseen, till it is
  /// gone, what it is subscribed to as it was (with_lingering); till their next turn
  answered_unseen : Map[String, Bool]
  /// each agent's last turn as last ticked (Agent.last_turn)
  last_turns : Map[String, String]
  /// each agent at work, the last message here as it was first seen at work: what of its own comes past it is its answer
  turn_from : Map[String, Double]
  /// each agent not at work, the last message here as it was last ticked so: what of its own came past it came with
  /// its turn (turn_from)
  idle_here : Map[String, Double]
  /// a message gone to (a notification's) and how lit it is (flash_of)
  mut flash : String
  flash_lit : @motion.Anim
  /// flashes started (each one's own hold, with motion reduced)
  mut flash_n : Int
  /// what of it a quote that led there quoted ("" the whole of it: Chat.tsx flashRange), lit alone where it is found in
  /// its words; yet to be put in the list's middle when it lies low (`flash_centre`)
  mut flash_passage : String
  mut flash_centre : Bool
  /// a message the search opened the chat at ("" none) and its words marked in it (`found`),
  /// for as long as the chat shows; how far their strokes are drawn in (ms of drawFound's); its first word yet to be
  /// put in the list's middle when it lies low
  mut found_at : String
  mut found_words : Array[String]
  found_drawn : @motion.Anim
  mut found_centre : Bool
  /// its keys as the list's motion is told them (list_frame)
  mut motion_of : Array[String]
  mut motion_list : String
  mut motion_keys : Array[String]
  /// its rows as last shown, by key and what each shows (ListRows: what came, went and changed worked out by the
  /// list, mbui's ui/list_size.mbt)
  rows : @ui.ListRows[Entry]
}

///|
pub let readings : Map[String, Reading] = Map([])

///|
pub fn reading_of(key : String) -> Reading {
  match readings.get(key) {
    Some(r) => r
    None => {
      let r = {
        foot_sign: "",
        sent_foot: "",
        rows_laid: "",
        head: "",
        head_at: -1,
        first_was: -1.0,
        newer_was: false,
        placed: false,
        put_there: false,
        put_place: None,
        put: false,
        put_at: -1.0,
        lined: false,
        asked: @signals.signal(-1.0),
        asked_newer: @signals.signal(-1.0, same=fn(a, b) { a == b }),
        latest_asked: false,
        end_asked: false,
        told: "",
        seen_whole: -1.0,
        top_seq: -1.0,
        bottom_seq: -1.0,
        top_off: 0.0,
        top_piece: -1,
        top_piece_off: 0.0,
        at_end: true,
        told_place: "",
        told_at: "\u{0}",
        scale: 1.0,
        jump: false,
        far: false,
        ask: false,
        jump_at: -1.0e9,
        bench: 0,
        bench_phase: 0,
        bench_rows: 0,
        bench_ms: [],
        bench_present: [],
        known: {},
        drawn: false,
        acts: {},
        shown: false,
        was_shown: false,
        shown_from: -1.0,
        laid_from: -1.0,
        played: false,
        ticked: false,
        fresh: {},
        came: {},
        came_n: 0,
        makes_way: {},
        over: "",
        admitted: {},
        newest: "",
        following_row: false,
        follow_key: "",
        sent: {},
        sent_as: {},
        sent_as_told: @signals.signal(0),
        sent_joined: {},
        linger: {},
        act_order: {},
        acts_seen: 0,
        linger_said: @signals.signal(0),
        floor: 0.0,
        act_whole: {},
        running: {},
        answered: {},
        answered_unseen: {},
        last_turns: {},
        turn_from: {},
        idle_here: {},
        flash: "",
        flash_lit: @motion.Anim::new(0.0),
        flash_n: 0,
        flash_passage: "",
        flash_centre: false,
        found_at: "",
        found_words: [],
        found_drawn: @motion.Anim::new(0.0),
        found_centre: false,
        motion_of: [],
        motion_list: "",
        motion_keys: [],
        rows: @ui.ListRows::new(),
      }
      readings[key] = r
      r
    }
  }
}

///|
/// Where a chat was left this run (AppState.places): the message at the top of what showed (its seq) and
/// how far its top was below the list's (points); and, left at its end, the newest message then (else -1). It opens
/// there again before where the core says (`at`): the chat's view can outlive its page (opened again before the core
/// lets it go, a minute after: store.ts EVICT_AFTER_MS) and still say where it was opened the first time.
pub(all) struct KeptPlace {
  top : Double
  offset : Double
  bottom : Double
  /// where the page that kept it draws a message in pieces (a page made as nodes): the piece at its top (0 its first,
  /// -1 none said: the old page's, a test's, a message of one) and how far that piece's top is under the list's window's
  /// top, as `offset` is kept; `offset` stays the whole message's, which the old page and the core read
  piece : Int
  piece_offset : Double
}

///|
pub let kept_places : Map[String, KeptPlace] = Map([])

///|
/// A place as it is kept (KeptPlace's `offset`, `chat.place`'s and so the core's `at_offset`: how far a message's top is
/// under the top of its list's window, what the old page counts and every other device tells) of one told under what
/// covers the list's top (`cover` tall, the chat's bar): its top `under` below that edge (a page made as nodes: what is
/// in sight's `-into`). What is kept and told keeps that meaning, and a page made as nodes says and reads it through this
/// pair alone (kept_place_under is the way back); it stays when the old page is gone, the core's and other devices'
/// numbers no different then (the coordinator of the migration, 2026-11-14).
pub fn kept_place_of(under : Double, cover : Double) -> Double {
  cover + under
}

///|
/// ListPlace::bring's offset (from under what covers the list's top, `cover` tall: over that edge) of a place as it is
/// kept, `kept` (kept_place_of's): its message's top where the place had it in the list's window.
pub fn kept_place_under(kept : Double, cover : Double) -> Double {
  cover - kept
}


///|
/// The key of where a chat stands among its list's rows (Entry::id): one at a time, at its end.
let state_key : String = "state"

///|
/// The list's entries: the page before's spinner, the messages with the unread line over the
/// first unread and what went to Slack after each, the page after's spinner, the outbox, where it stands (said only at
/// its end: none while an agent works), its agents at work.
pub fn entries_of(v : ChatView) -> Array[Entry] {
  chat_entries(v).0
}

///|
/// Whether an agent's activity shows: at work, or given words it has yet to take (queued), which it goes on to work on.
/// Gone while queued, its line went and came back each time words were sent to it (2026-11-09).
fn at_work(a : Agent) -> Bool {
  a.status == "running" || a.status == "queued"
}

///|
/// The agents of view `v` whose card an answer on its way from here quotes (`all`'s outgoing rows: the core's outbox
/// and what was sent from here before the core has it), not at work by the view nor in `all` yet: at work from the
/// frame the answer is sent, as the core says them once it has it (views.ts answeredAt), so the agent's line comes in
/// with the answer, the card folding and the answer coming on one way of the list, not a moment after it (the user,
/// 2026-11-09: 「点选项时「处理中」立刻出来」). The old page's rows (row_keys) and the page made as nodes'
/// (sfpages' chat_body_rows) alike.
pub fn answered_at(v : ChatView, all : Array[Entry]) -> Array[Agent] {
  let out : Array[Agent] = []
  let take = fn(by : String) {
    match v.agents.search_by(fn(a) { a.key == by }) {
      Some(i) => {
        let a = v.agents[i]
        let shown = all.iter().any(fn(x) { x is Working(w) && w.key == a.key })
        if !at_work(a) && !shown && !out.iter().any(fn(x) { x.key == a.key }) {
          out.push({ ..a, status: "queued", started: true })
        }
      }
      None => ()
    }
  }
  // (the chat's last word a card, answered by what is on its way: words sent under it answer it as a pick does)
  let last = v.messages.rev_iter().find_first(fn(m) { !m.system })
  for e in all {
    guard e is Out(o) && o.state != "failed" else { continue }
    for q in o.quotes {
      guard q.role == "agent" && q.ts != "" else { continue }
      match v.messages.search_by(fn(m) { m.ts == q.ts && m.card is Some(_) }) {
        Some(i) => take(v.messages[i].by.agent)
        None => ()
      }
    }
    match last {
      Some(m) if m.card is Some(_) && m.by.agent != "" && (m.decision is Some(d) && d.resolved && !d.dismissed) =>
        take(m.by.agent)
      _ => ()
    }
  }
  out
}

///|
/// Chat `r`'s view `v` and its entries `list` as the core will say them once it has the words sent from here that it
/// does not have yet (sent.mbt's local_sending: in the list from the frame they are sent, LocalSent), where the chat's
/// last card still waits: they answer it at once, and the core says so from the moment it has them, all in one word
/// of its own (decisions.ts inMessages: what is sending answers the last card; views.ts: the card no more asked, the
/// chat's asks without it, where it stands gone as its agent has words to take). That word comes a few frames after
/// the press, more on a phone: till then the words' row came in alone, the list going up for it, and the card folded,
/// the line of where the chat stands went and the room kept clear of the bell closed only then, the list turning
/// back down under the hand (the user, 2026-11-10: 「现在发一条消息都会有奇怪的跳动」). Said so from the frame they are
/// sent, all of it goes on one way with them (their agent's line too: answered_at). Not sent after all, their row
/// gone, the core's word stands again: the card waits.
fn sent_here_view(r : ChatRef, v : ChatView, list : Array[Entry]) -> (ChatView, Array[Entry]) {
  let rk = r.station + "\u{1}" + r.session
  guard local_sending.get(rk) is Some(sending) && !sending.is_empty() else {
    // (nothing sent from here on its way: what was made of its views while there was, let go)
    sent_here_made.remove(rk)
    return (v, list)
  }
  // (made of this view and these words already: that, the same rows to the list)
  let sig = sending.map(fn(l) { l.row.id + "@" + l.newest.to_string() }).join(",")
  let kept = match sent_here_made.get(rk) {
    Some(k) => k
    None => {
      let k : Array[SentHereMade] = []
      sent_here_made[rk] = k
      k
    }
  }
  for m in kept {
    if physical_equal(m.of, v) && physical_equal(m.list, list) && m.sending == sig {
      return (m.view, m.entries)
    }
  }
  let mut at = -1
  for i, m in v.messages {
    if m.card is Some(_) {
      at = i
    }
  }
  guard at >= 0 else { return (v, list) }
  let m = v.messages[at]
  // (answered already, or a person's words after it in the chat: the core's word stands)
  guard m.decision is Some(d) && !d.resolved else { return (v, list) }
  // (there as they were sent: a card come since, their agent's answer to them, is not what they answer; the frame the
  // core has them, its view read before their row is taken over, would have said that one answered for a frame)
  guard sending.iter().any(fn(l) { m.seq <= l.newest }) else { return (v, list) }
  for i in (at + 1)..<v.messages.length() {
    if v.messages[i].author_kind == "person" {
      return (v, list)
    }
  }
  let said = @sf.t("core-logic.decisions.replied", args=[("name", @sf.t("core-logic.decisions.you"))])
  let messages = v.messages.copy()
  // (no more asked: letting it go is not offered under it)
  messages[at] = { ..m, asked: false, decision: Some({ resolved: true, dismissed: false, text: Some(said), chosen: None }) }
  let asks = v.asks.filter(fn(seq) { seq != m.seq })
  let made = { ..v, messages, asks, ask_clear: v.ask_clear && !asks.is_empty(), state: None, state_ask: None }
  let out = (made, chat_entries(made).0)
  // (of other words sent, or more than its readers are: let go)
  kept.retain(fn(m) { m.sending == sig })
  if kept.length() >= sent_here_kept_most {
    kept.remove(0) |> ignore
  }
  kept.push({ of: v, list, sending: sig, view: out.0, entries: out.1 })
  out
}

///|
/// What sent_here_view made of a chat's view, and of what: the core's view and entries it was made from and the words
/// sent then. The same again while those are (each frame of the words' flight reads it, a phone's core answering many
/// frames after the press): a view and entries made anew each read were other rows to the list every frame, all of
/// them built again, twice a frame while the frame is built again for what it set. One for each of the chat's readers
/// (its page, the frame round it, linger_tick: each its source's own view of it), a few at most.
priv struct SentHereMade {
  of : ChatView
  list : Array[Entry]
  sending : String
  view : ChatView
  entries : Array[Entry]
}

///|
// kept across runs: forgotten with what was sent (sent_reset, as a run starts)
let sent_here_made : Map[String, Array[SentHereMade]] = Map([])

///|
/// How many of a chat's views sent_here_view keeps what it made of: more readers than this at once make theirs again.
let sent_here_kept_most : Int = 4

///|
/// The entries and where their messages end, before the live rows at the foot.
fn chat_entries(v : ChatView) -> (Array[Entry], Int) {
  let out : Array[Entry] = [Top]
  if v.more {
    out.push(Older(if v.older == "failed" { v.older_failed } else { "" }))
  }
  // (nothing in it: not a window showing none of it, what it shows before being brought, `more`)
  if v.messages.length() == 0 && v.outbox.length() == 0 && v.elsewhere.length() == 0 && !v.more {
    out.push(Empty)
  }
  for e in v.elsewhere {
    out.push(Sent(e))
  }
  for m in v.messages {
    chat_entry_message(out, m, v.unread_line)
  }
  let end = out.length()
  chat_entry_tail(out, v)
  (out, end)
}

///|
fn chat_entry_message(out : Array[Entry], m : Message, unread : Double?) -> Unit {
  match unread {
    Some(l) if l == m.seq => out.push(Line)
    _ => ()
  }
  out.push(Said(m))
  for e in m.elsewhere {
    out.push(Sent(e))
  }
}

///|
fn chat_entry_tail(out : Array[Entry], v : ChatView) -> Unit {
  if v.newer {
    out.push(Newer)
  }
  for o in v.outbox {
    out.push(Out(o))
  }
  if !v.newer {
    match v.state {
      Some((words, lead, rest)) => out.push(State(words, lead, rest))
      None => ()
    }
  }
  if !v.newer {
    for a in v.agents {
      if at_work(a) {
        out.push(Working(a))
      }
    }
  }
  out.push(Foot)
}

///|
/// Chat `r`'s view (chat_view), its list's entries and its topic's error: worked out once for each version of it,
/// whoever reads it in a frame (the page, its side panel, the frame round it, the chats kept: linger_tick).
pub fn view_of_chat(src : Source, r : ChatRef) -> (ChatView?, Array[Entry], Json?) {
  let key = chat_inputs_key(r)
  let live = match chat_inputs.peek_from(src, key) {
    Some(input) => input.live
    None => Ref(true)
  }
  let input = chat_inputs.read(src, key, fn(was) {
    if !live.val {
      // The page has left. Tell anything still following this computation to read again, without re-subscribing as
      // the old subscription ends; a reader still in use obtains a new input on its next read.
      match was {
        Some(before) => { source: before.source, read: before.read, topic: before.topic, live }
        None => @halt.saying("a chat input was left before it was read")
      }
    } else {
      let (read, topic) = chat_read.read(src, chat_params(r))
      { source: src.topic_read, read, topic, live }
    }
  }, same=fn(a, b) {
    b.live.val && physical_equal(a, b)
  })
  let read = input.read
  let topic = input.topic
  page_chat_view_read(src, r, read.map(fn(chat) { chat.view }))
  match (read, topic.value, fresh_view(r)) {
    // (the chat a new chat became is never said to be empty: its first message is in it from the frame it was sent,
    // sent_local, while the core has it made and not yet sent to)
    (Some(c), Some(Object(_)), Some(_)) if c.list.iter().any(fn(e) { e is Empty }) =>
      (Some(c.view), c.list.filter(fn(e) { !(e is Empty) }), topic.error)
    (Some(c), Some(Object(_)), _) => {
      // (what was sent from here and the core does not have yet answers the last card waiting: sent_here_view)
      let (view, list) = sent_here_view(r, c.view, c.list)
      (Some(view), list, topic.error)
    }
    // the chat a new chat became as its first words were sent, till the core's view of it is read: a chat with
    // nothing in it yet but what was sent from here (its own first view, as the core's will be: views.ts pendingChat)
    (_, _, Some((v, list))) => (Some(v), list, None)
    _ => (None, [], topic.error)
  }
}

///|
/// The topic and its derived messages are shared by reads of a chat until the topic changes. A different source gets
/// its own reading. The fresh view is still read by each caller above: its full ChatRef can differ for the same topic.
// kept across runs: the Kept is registered on first use and its stored inputs are cleared by kept_reset (derived.mbt)
let chat_inputs : SourceKept[ChatInput] = { kept: {}, listed: false }

///|
priv struct ChatInput {
  source : (String, Map[String, Json]) -> Topic
  read : ChatRead?
  topic : Topic
  live : Ref[Bool]
}

///|
/// A distinct key for each pair, without relying on a separator being absent from a station or session.
fn chat_inputs_key(r : ChatRef) -> String {
  r.station.length().to_string() + ":" + r.station + r.session
}

///|
/// Let the computed go before the core's chat topic is left, so an ending topic cannot cause it to subscribe again.
pub fn chat_inputs_left(r : ChatRef) -> Unit {
  let key = chat_inputs_key(r)
  match chat_inputs.kept.get(key) {
    Some(entries) =>
      for entry in entries {
        match entry.value.peek() {
          Some(input) => input.live.val = false
          None => ()
        }
      }
    None => ()
  }
  // (what was read of it kept for its page opened again: chat_seeds_put)
  chat_seeds_put(key, chat_read.kept(chat_params(r)), chat_head_read.kept(chat_params(r)))
  chat_inputs.forget(key)
  chat_heads.forget(key)
  chat_head_jsons.forget(key)
  // (its messages by key let go with it: read again from its list as it is read again, those that did not change
  // taken as they were read)
  chat_messages_kept.remove(key)
}

///|
/// What was made of chat `r` from source `src` (its read, its head's), nothing following it, let go of: one read untracked
/// holds the chat's subscription till it is. What is still read is kept.
pub fn chat_reads_forget_from(src : Source, r : ChatRef) -> Unit {
  let key = chat_inputs_key(r)
  // (what reads them first, then them: each let go leaves what it read unread by it)
  chat_heads.forget_unwatched_from(src, key)
  chat_head_jsons.forget_unwatched_from(src, key)
  chat_read.forget_from(src, chat_params(r))
  chat_head_read.forget_from(src, chat_params(r))
}

///|
/// Let one source's chat input go without invalidating another source that still reads the chat.
pub fn chat_inputs_left_from(src : Source, r : ChatRef) -> Unit {
  let key = chat_inputs_key(r)
  match chat_inputs.peek_from(src, key) {
    Some(input) => input.live.val = false
    None => ()
  }
  // (what was read of it kept for its page opened again: chat_seeds_put)
  chat_seeds_put(key, chat_read.kept_from(src, chat_params(r)), chat_head_read.kept_from(src, chat_params(r)))
  chat_reads_forget_from(src, r)
  chat_inputs.forget_from(src, key)
  chat_heads.forget_from(src, key)
  chat_head_jsons.forget_from(src, key)
  // (its messages by key let go with it, chat_read_left having told where it was left: read again from its list as it
  // is read again, those that did not change taken as they were read)
  chat_messages_kept.remove(key)
}

///|
/// The chats' reads as their pages were left (chat_read's, by the chat's key), the last `chats_kept` of them: the core's
/// client keeps as many chats' values as it lets them go (@core.Client::keep), and a page of one opened again (a source
/// of its own, its read made from nothing) is given that value again (`same`) or what changed from it, each message
/// that did not change the same JSON. So that page's read is made from the one kept (chat_read_seed): none of those
/// messages read again, only what changed. Never shown: what the page shows is what the core answers, as before.
// kept across runs: emptied as a run begins (chat_seeds_reset)
let chat_read_seeds : Array[(String, ChatRead)] = []

///|
/// The read kept of the chat whose value `v` (its messages `message_json`) is (chat_read_seeds): one whose value is it,
/// or of whose messages one is the same JSON, as the core's client keeps them (the newest first); none else.
fn chat_read_seed(v : Json, message_json : Array[Json]) -> ChatRead? {
  let m = message_json.length()
  let mut i = chat_read_seeds.length() - 1
  while i >= 0 {
    let w = chat_read_seeds[i].1
    let n = w.read.length()
    if physical_equal(w.raw, v) ||
      (n > 0 && m > 0 &&
      (physical_equal(w.read[0].0, message_json[0]) ||
      physical_equal(w.read[n - 1].0, message_json[m - 1]) ||
      (n <= m && physical_equal(w.read[n - 1].0, message_json[n - 1])))) {
      return Some(w)
    }
    i -= 1
  }
  None
}

///|
/// Chat `r`'s view as a frame read it last (view_of_chat), if one did since the last: its topic not asked for (a chat
/// whose page was never drawn, or is left, asks nothing of the core for it).
pub fn chat_kept(r : ChatRef) -> ChatView? {
  match chat_read.kept(chat_params(r)) {
    Some(c) => Some(c.view)
    // (a page that reads the chat by key read its head alone: chat_head)
    None => chat_head_read.kept(chat_params(r)).map(fn(h) { h.view })
  }
}

///|
/// A chat view last read through this source, without acquiring its topic.
pub fn chat_kept_from(src : Source, r : ChatRef) -> ChatView? {
  match chat_read.kept_from(src, chat_params(r)) {
    Some(c) => Some(c.view)
    // (a page that reads the chat by key read its head alone: chat_head)
    None => chat_head_read.kept_from(src, chat_params(r)).map(fn(h) { h.view })
  }
}

///|
/// A chat as chat_read made it: its view, its list's entries, and each message with the JSON it was read from (the
/// next version's same JSON, a message that did not change, not read again: made_again).
priv struct ChatRead {
  /// the topic's value it was read from: what of it is the same JSON in the next is not read again (chat_view_of's)
  raw : Json
  message_json : Array[Json]
  view : ChatView
  list : Array[Entry]
  message_end : Int
  read : Array[(Json, Message)]
}

///|
/// Whether the messages are still the ones made last. A source can reuse its array and change its contents in place,
/// so compare to the recorded messages, not just the array's identity.
fn same_chat_messages(jsons : Array[Json], read : Array[(Json, Message)]) -> Bool {
  if jsons.length() != read.length() {
    return false
  }
  for i, j in jsons {
    if !physical_equal(j, read[i].0) {
      return false
    }
  }
  true
}

///|
/// The rows are unchanged for a chat with no outbox, external messages or running activities when these inputs are
/// unchanged. With any of those dynamic rows, make the list afresh from the new view.
fn chat_entries_same(a : ChatView, b : ChatView) -> Bool {
  physical_equal(a.messages, b.messages) &&
  a.more == b.more &&
  a.newer == b.newer &&
  a.unread_line == b.unread_line &&
  a.state == b.state &&
  a.elsewhere.is_empty() && b.elsewhere.is_empty() &&
  a.outbox.is_empty() && b.outbox.is_empty() &&
  a.agents.iter().all(fn(agent) { !at_work(agent) }) &&
  b.agents.iter().all(fn(agent) { !at_work(agent) })
}

///|
/// Messages changed where they stand (an edited or patched message), and appended after the history before, keep the
/// entries of all the rest: the old ones copied, the changed messages' put in their place and the new ones' after them.
/// The old array remains untouched, since a frame may still use it. Other list changes take the ordinary path. A
/// message changed in place keeps its seq (the unread line stays where it was over it) and says nothing elsewhere,
/// before or now (no Sent entries of its own to put again).
fn chat_entries_appended(v : ChatView, was : ChatRead) -> (Array[Entry], Int)? {
  let before = was.view.messages
  if before.is_empty() || before.length() > v.messages.length() ||
     was.view.more != v.more || was.view.unread_line != v.unread_line ||
     (v.more && (was.view.older != v.older || was.view.older_failed != v.older_failed)) ||
     !was.view.elsewhere.is_empty() || !v.elsewhere.is_empty() {
    return None
  }
  // (the messages changed where they stand, the last first)
  let changed : Array[Int] = []
  let mut i = before.length() - 1
  while i >= 0 {
    let a = before[i]
    let b = v.messages[i]
    if !physical_equal(a, b) {
      guard a.seq == b.seq && a.elsewhere.is_empty() && b.elsewhere.is_empty() else { return None }
      changed.push(i)
    }
    i -= 1
  }
  let out = was.list.copy()
  while out.length() > was.message_end {
    out.pop() |> ignore
  }
  // (each changed message's entry found from the end of the messages': no more of them gone through than lie after
  // the first changed)
  if !changed.is_empty() {
    let mut m = before.length() - 1
    let mut c = 0
    let mut at = out.length() - 1
    while at >= 0 && c < changed.length() {
      if out[at] is Said(_) {
        if m == changed[c] {
          out[at] = Said(v.messages[m])
          c += 1
        }
        m -= 1
      }
      at -= 1
    }
    guard c == changed.length() else { return None }
  }
  for i in before.length()..<v.messages.length() {
    chat_entry_message(out, v.messages[i], v.unread_line)
  }
  let end = out.length()
  chat_entry_tail(out, v)
  Some((out, end))
}

///|
/// The messages of `message_json` read from those of a chat read before (`was`) where they changed only where they
/// stand or came after them (an edited message, a new message appended at the end): each the same JSON as before taken
/// as it was, each changed where it stands (its key the same) and each come read, no other looked at or keyed. None
/// where any came or went elsewhere, or moved: made_again's to find.
fn chat_read_again(message_json : Array[Json], was : ChatRead) -> (Array[(Json, Message)], Array[Message])? {
  let n = was.read.length()
  guard n > 0 && message_json.length() >= n && was.view.messages.length() == n else { return None }
  let read = was.read.copy()
  let messages = was.view.messages.copy()
  for i in 0..<n {
    let j = message_json[i]
    let (wj, _) = was.read[i]
    guard !physical_equal(j, wj) else { continue }
    guard message_key(j) == message_key(wj) else { return None }
    let m = message_read(j)
    read[i] = (j, m)
    messages[i] = m
  }
  for i in n..<message_json.length() {
    let j = message_json[i]
    let m = message_read(j)
    read.push((j, m))
    messages.push(m)
  }
  Some((read, messages))
}

///|
/// A chat's view and its list's entries, as the core's `chat` topic gives them: its messages read again only as they
/// changed (one came: that one read), and what else it says read again only where it is not the same JSON as before
/// (chat_view_of's `was`).
// kept across runs: what it keeps is let go of by a run anew and by reset (derived.mbt)
let chat_read : Derived[ChatRead] = Derived::new_ref("chat", fn(v, was) {
  chat_read_made.val += 1
  let message_json = items(Some(v), "messages")
  // (made from nothing, a source's first: from what was read of this chat as a page of it was left, where it is the
  // same chat's, as from the read before: chat_read_seeds)
  let was = match was {
    Some(_) => was
    None => chat_read_seed(v, message_json)
  }
  let (read, messages) = match was {
    Some(w) if physical_equal(w.message_json, message_json) && same_chat_messages(message_json, w.read) =>
      (w.read, w.view.messages)
    _ => {
      let again = match was {
        Some(w) => chat_read_again(message_json, w)
        None => None
      }
      match again {
        Some(both) => both
        None => {
          let read = made_again(
            message_json,
            match was {
              Some(w) => w.read
              None => []
            },
            message_key,
            message_read,
          )
          (read, read.map(fn(p) { p.1 }))
        }
      }
    }
  }
  let view = chat_view_of(v, messages, match was {
    Some(w) => Some((w.raw, w.view))
    None => None
  })
  let (list, message_end) = match was {
    Some(w) if chat_entries_same(w.view, view) => (w.list, w.message_end)
    Some(w) =>
      match chat_entries_appended(view, w) {
        Some(entries) => entries
        None => chat_entries(view)
      }
    None => chat_entries(view)
  }
  { raw: v, message_json, view, list, message_end, read }
})

///|
/// A message's key in its chat, as the core keys them (client/core-ts collections.ts: `seq` and `outgoing`).
fn message_key(m : Json) -> String {
  let s = Some(m)
  number(s, "seq").to_string() + "\u{1}" + text(s, "outgoing")
}

///|
/// An agent whose turn ended, its activity still shown (with_lingering) while its messages come out of its avatar.
pub(all) struct Lingering {
  agent : Agent
  /// a turn begun and over between two ticks: there in the one tick that found it, as one seen running is
  mut once : Bool
  /// there taking no room and unseen, its activity read as a seen one's is (its answer, if any, out of where its avatar
  /// would be): never coming in and going a moment after (the list down and up again)
  unseen : Bool
  /// the answer its turn is about, told over before that answer came (by its seq; -1 none): it stays till the answer
  /// comes and leaves its avatar, the two changing places on the list's one way, not its room closed alone and the
  /// answer's opened a moment after (the list down and up again: 2026-11-09 the user, 「现在发个消息都抖了」「偶现」)
  mut awaits : Double
}

///|
/// Each frame, before any page is built, whatever page shows: from each chat kept's own data (its agents running, its
/// messages coming out of an avatar), whose activity stays as its turn ends (while its messages come out of its avatar,
/// no longer: chat_tick); a chat under another page lets them go meanwhile. The chat's page draws what it says.
/// `in_front`: the app shown (what is said then is watched). As each build begins (here, before any page): whether each
/// chat's list was shown in the one before (Reading's `was_shown`), and not yet in this one; its data not taken in this
/// one yet.
pub fn linger_tick(c : @ui.Ctx, src : Source, in_front~ : Bool) -> Unit {
  ignore(c)
  ignore(in_front)
  for rk, rd in readings {
    rd.was_shown = rd.shown
    rd.shown = false
    rd.played = false
    rd.ticked = false
    let (station, session) = match rk.find("\u{1}") {
      Some(i) => (rk.exact_view(end=i).to_owned(), rk.exact_view(start=i + 1).to_owned())
      None => continue
    }
    let r : ChatRef = { station, session, title: "", station_name: "" }
    let page_src = page_source_for_chat(src, r)
    if physical_equal(page_src, src) {
      continue
    }
    let keyed = match chat_heads.peek_from(page_src, chat_inputs_key(r)) {
      Some(_) => chat_messages(page_src, r)
      None => None
    }
    match keyed {
      Some(ms) =>
        match chat_head(page_src, r).0 {
          Some(v) => chat_tick_lingering(rk, rd, v, ms~)
          None => ()
        }
      _ =>
        if chat_read.kept_from(page_src, chat_params(r)) is Some(_) {
          match view_of_chat(page_src, r).0 {
            Some(v) => chat_tick_lingering(rk, rd, v)
            None => ()
          }
        }
    }
  }
}

///|
/// Chat view `v`'s messages (those kept by key, `ms`, where it holds none: its head's) from the newest back, each
/// given to `go` till it says no more.
fn said_back(v : ChatView, ms : ChatMessages?, go : (Message) -> Bool) -> Unit {
  match ms {
    Some(ms) if v.messages.is_empty() => {
      let keys = ms.peek_keys()
      let mut i = keys.length() - 1
      while i >= 0 {
        match ms.peek(keys[i]) {
          Some(m) => if !go(m) { return }
          None => ()
        }
        i = i - 1
      }
    }
    _ => {
      let mut i = v.messages.length() - 1
      while i >= 0 {
        if !go(v.messages[i]) {
          return
        }
        i = i - 1
      }
    }
  }
}

///|
/// A chat's own data, once a build, before its page is built (linger_tick): whose activity stays as its turn ends.
fn chat_tick_lingering(rk : String, rd : Reading, v : ChatView, ms? : ChatMessages) -> Unit {
  if rd.ticked {
    return
  }
  rd.ticked = true
  let running : Map[String, Agent] = Map([])
  if !v.newer {
    for a in v.agents {
      if at_work(a) {
        running[a.key] = a
      }
    }
  }
  let em = emits_of(rk)
  let keeps = emit_keeps(em)
  let here = match ms {
    Some(ms) if v.messages.is_empty() =>
      match ms.peek_keys().last().bind(fn(k) { ms.peek(k) }) {
        Some(m) => m.notice_last_seq
        None => -1.0
      }
    _ => v.messages.iter().fold(init=-1.0, fn(m, x) { if x.notice_last_seq > m { x.notice_last_seq } else { m } })
  }
  let on_its_way = fn(a : Agent) {
    match a.about {
      Some(seq) if seq > here && !v.newer => seq
      _ => -1.0
    }
  }
  for k, a in rd.running {
    if !running.contains(k) && !rd.linger.contains(k) {
      let now = v.agents.iter().find_first(fn(b) { b.key == k }).unwrap_or(a)
      let awaits = on_its_way(now)
      if keeps.contains(k) || awaits >= 0.0 {
        rd.linger[k] = { agent: a, once: false, unseen: false, awaits }
        linger_told(rd)
      }
    }
  }
  if !v.newer {
    for a in v.agents {
      match rd.last_turns.get(a.key) {
        Some(was) if a.last_turn != was &&
          a.last_turn != "" &&
          !running.contains(a.key) &&
          !rd.running.contains(a.key) &&
          !rd.linger.contains(a.key) => {
          rd.linger[a.key] = { agent: a, once: true, unseen: true, awaits: -1.0 }
          linger_told(rd)
        }
        _ => ()
      }
      rd.last_turns[a.key] = a.last_turn
    }
  }
  match em.current {
    Some(t) if t.pose != Fold &&
      running.contains(t.agent) &&
      !rd.answered.contains(t.agent) &&
      !keeps.contains(t.agent) &&
      ends_turn(v, t.seq) => {
      rd.answered[t.agent] = running.get(t.agent).map(fn(a) { a.last_turn }).unwrap_or("")
      linger_told(rd)
    }
    _ => ()
  }
  for k, a in running {
    let first = !rd.turn_from.contains(k)
    if first {
      rd.answered_unseen.remove(k) |> ignore
      let idle = rd.idle_here.get(k).unwrap_or(-1.0)
      let from = Ref(-1.0)
      said_back(v, ms, fn(m) {
        if !(m.author_kind == "agent" && m.by.agent == k && m.said && m.seq > idle) {
          from.val = m.seq
          false
        } else {
          true
        }
      })
      rd.turn_from[k] = from.val
    }
    if rd.answered.contains(k) || keeps.contains(k) {
      continue
    }
    let from = rd.turn_from[k]
    let came_ = Ref(false)
    said_back(v, ms, fn(m) {
      guard m.seq > from else { return false }
      if m.author_kind == "agent" &&
        m.by.agent == k &&
        !m.mine &&
        !m.system &&
        m.ending != "" &&
        !emit_goes(em, m.seq) {
        came_.val = true
        return false
      }
      true
    })
    let came = came_.val
    if came {
      rd.answered[k] = a.last_turn
      if first {
        rd.answered_unseen[k] = true
      }
      linger_told(rd)
    }
  }
  for a in v.agents {
    if !running.contains(a.key) {
      rd.idle_here[a.key] = here
    }
  }
  let gone_by = rd.turn_from.keys().filter(fn(k) { !running.contains(k) }).collect()
  for k in gone_by {
    rd.turn_from.remove(k)
  }
  let done = rd.answered
    .iter()
    .filter(fn(e) {
      match running.get(e.0) {
        Some(a) => a.last_turn != e.1
        None => true
      }
    })
    .map(fn(e) { e.0 })
    .collect()
  for k in done {
    rd.answered.remove(k)
  }
  if !done.is_empty() {
    linger_told(rd)
  }
  rd.running.clear()
  for k, a in running {
    rd.running[k] = a
  }
  let over : Array[String] = []
  for k, l in rd.linger {
    if l.once && !running.contains(k) {
      l.once = false
      continue
    }
    if l.awaits >= 0.0 && l.awaits <= here {
      l.awaits = -1.0
    }
    if running.contains(k) || (!keeps.contains(k) && l.awaits < 0.0) {
      over.push(k)
    }
  }
  for k in over {
    rd.linger.remove(k)
  }
  if !over.is_empty() {
    linger_told(rd)
  }
}

///|
/// One came to linger or went: told to what reads which do (with_lingering).
fn linger_told(rd : Reading) -> Unit {
  rd.linger_said.set(rd.linger_said.untracked() + 1)
}

///|
/// Whether the message `seq` is a post that ended its agent's turn (all_done, need_help, waiting), not one saying how
/// far it got. (From the end: what comes out of an avatar is among the newest.)
fn ends_turn(v : ChatView, seq : Double) -> Bool {
  for i = v.messages.length() - 1; i >= 0; i = i - 1 {
    if v.messages[i].seq == seq {
      return v.messages[i].ending != ""
    }
  }
  false
}

///|
/// The list with the activities of agents whose turn just ended, kept while their messages come out of their avatars.
pub fn with_lingering(rd : Reading, list : Array[Entry]) -> Array[Entry] {
  rd.linger_said.get() |> ignore
  // (an agent at work whose answer came out of its avatar: its line gone, chat_tick)
  let list = if rd.answered.is_empty() {
    list
  } else {
    list.filter(fn(e) { !(e is Working(a) && rd.answered.contains(a.key) && !rd.answered_unseen.contains(a.key)) })
  }
  if rd.linger.is_empty() {
    return acts_in_order(rd, list)
  }
  // after the running ones, before the foot
  let out = list.copy()
  let foot = match out.last() {
    Some(Foot) => out.pop()
    _ => None
  }
  for _, l in rd.linger {
    out.push(Working(l.agent))
  }
  match foot {
    Some(f) => out.push(f)
    None => ()
  }
  acts_in_order(rd, out)
}

///|
/// `list` with its agents' lines (at its end, before its foot) in the order they first came (Reading's `act_order`):
/// the list itself where they are so already.
fn acts_in_order(rd : Reading, list : Array[Entry]) -> Array[Entry] {
  let mut end = list.length()
  if end > 0 && list[end - 1] is Foot {
    end = end - 1
  }
  let mut start = end
  while start > 0 && list[start - 1] is Working(_) {
    start = start - 1
  }
  let order = fn(e : Entry) {
    let k = e.id()
    match rd.act_order.get(k) {
      Some(n) => n
      None => {
        rd.acts_seen += 1
        rd.act_order[k] = rd.acts_seen
        rd.acts_seen
      }
    }
  }
  let mut sorted = true
  for i in start..<end {
    if i > start && order(list[i - 1]) > order(list[i]) {
      sorted = false
    }
  }
  if sorted {
    return list
  }
  let out = list.copy()
  let block = out[start:end].to_owned()
  block.sort_by(fn(a, b) { order(a).compare(order(b)) })
  for i, e in block {
    out[start + i] = e
  }
  out
}

///|
/// What the chat's page builds from where its list is (messages): whether it is laid out, near its top (the page
/// before asked for) or its end (the page after), at its end, away from it (the way to the newest), and whether the
/// asks waiting are all in view (the bell over the way to the end, jump_to_ask). A scroll changing none of that builds
/// nothing again.
#derive(Eq)
pub(all) struct ListMade {
  laid : Bool
  near_top : Bool
  near_end : Bool
  at_end : Bool
  away : Bool
  asks_seen : Bool
}

///|
pub fn list_made(info : @ui.ListInfo?, n : Int, ask_rows : Array[Int], lr : @ui.ListReader) -> ListMade {
  match info {
    Some(i) =>
      {
        laid: i.first >= 0,
        near_top: i.first >= 0 && chat_short_above(i, lr),
        near_end: i.last >= n - 4,
        at_end: i.at_end,
        away: i.first >= 0 && i.below > 120.0 && !i.gliding,
        asks_seen: asks_in_view(ask_rows, info),
      }
    None => { laid: false, near_top: false, near_end: false, at_end: false, away: false, asks_seen: false }
  }
}

///|
/// Whether a chat's list wants the page before it (`info` as it was last laid out, `lr` the list as it is now): what it
/// lays out does not fill its window (the screen shows less than it could), or the reader has moved it off its end
/// (it is not pinned to its newest: info's `at_end`) and less than a screen of it is above what shows. Its page then
/// asks for more before it (chat_grow_rows), so that a hand reading it back at its fastest never comes to its top
/// before they are in; while it sits at its end, as it opens or as messages come, nothing is asked ahead of need.
/// Measured in points: the rows above at the height they were laid out at, one not laid out yet (above where it
/// opened) at the least a row the core counts has (chat_row_least), never more than it can be; counted only as far as a
/// screen.
pub fn chat_short_above(info : @ui.ListInfo, lr : @ui.ListReader) -> Bool {
  if info.content < info.height {
    return true
  }
  if info.at_end {
    return false
  }
  match lr.place() {
    Some((first, off, _)) => {
      let mut above = off
      for k in 0..<first {
        if above >= info.height {
          break
        }
        above += lr.row_height(k).unwrap_or(chat_row_least)
      }
      above < info.height
    }
    None => false
  }
}

///|
/// The rows of the asks waiting in the chat (its cards to decide; what an agent needs where the chat's end says it,
/// the core's `stateAsk`; none in a chat archived or not made yet): -1 for one not in the list.
pub fn ask_rows_of(v : ChatView, list : Array[Entry]) -> Array[Int] {
  let asks = if v.archived || v.thread is None { [] } else { v.asks }
  asks.map(fn(seq) {
    let mut at = -1
    for i, e in list {
      match e {
        Said(m) if m.seq == seq && v.state_ask != Some(seq) => {
          at = i
          break
        }
        State(_, _, _) if v.state_ask == Some(seq) => {
          at = i
          break
        }
        _ => ()
      }
    }
    at
  })
}

///|
/// Whether there are asks waiting and every one is in view.
pub fn asks_in_view(ask_rows : Array[Int], info : @ui.ListInfo?) -> Bool {
  ask_rows.length() > 0 &&
  ask_rows.iter().all(fn(at) {
    match info {
      Some(i) => at >= 0 && at >= i.first && at <= i.last
      None => false
    }
  })
}

///|
/// Whether the list follows its end (at it, gliding to it, a row followed): what the rows coming in are built from.
pub fn follows(info : @ui.ListInfo?) -> Bool? {
  match info {
    Some(i) => Some(i.at_end || i.gliding || i.following_row)
    None => None
  }
}

///|
/// Where the reader is, as the list stands once the frame's builds are over (messages): the last message wholly in view
/// between the bar (`top`) and the composer (`room` over the list's foot), while the window is not short of the chat's
/// end (read up to there: a message shown whole on a page in front is read, its end seen or not); the first and the
/// last message in view, and how far the first's top is below the list's.
pub fn read_place(
  rd : Reading,
  v : ChatView,
  list : Array[Entry],
  lr : @ui.ListReader,
  top : Double,
  room : Double,
) -> Unit {
  let n = list.length()
  let info = lr.info()
  match (info, lr.place()) {
    (Some(i), Some((first, past, _))) if i.first >= 0 && !v.newer => {
      let foot = i.height - room
      let mut y = -past
      let mut k = first
      while k <= i.last && k < n {
        let h = lr.row_height(k).unwrap_or(0.0)
        match list[k] {
          // (a notice folding several is read to its last)
          Said(m) if y >= top - 0.5 && y + h <= foot + 0.5 && m.notice_last_seq > rd.seen_whole => rd.seen_whole = m.notice_last_seq
          _ => ()
        }
        y = y + h
        k = k + 1
      }
    }
    _ => ()
  }
  rd.top_seq = match info {
    Some(i) if i.first >= 0 => {
      let mut k = i.first
      while k < n && !(list[k] is Said(_)) {
        k = k + 1
      }
      match list.get(k) {
        Some(Said(m)) => m.seq
        _ => -1.0
      }
    }
    _ => -1.0
  }
  rd.bottom_seq = match info {
    Some(i) if i.first >= 0 => {
      let mut k = if i.last < n { i.last } else { n - 1 }
      while k >= 0 && !(list[k] is Said(_)) {
        k = k - 1
      }
      match list.get(k) {
        Some(Said(m)) => m.seq
        _ => -1.0
      }
    }
    _ => -1.0
  }
  // that message's top, below the list's (the first row in view scrolled past its top, the rows over it)
  rd.top_off = match (info, lr.place()) {
    (Some(i), Some((first, past, _))) if i.first >= 0 => {
      let mut y = -past
      let mut k = first
      while k < n && !(list[k] is Said(_)) {
        y = y + lr.row_height(k).unwrap_or(0.0)
        k = k + 1
      }
      y
    }
    _ => 0.0
  }
}

///|
/// The rows in the list and their keys, as they move (a message sent from here keeps its outbox row's: Chat.kt
/// sentAs), and which are new: what comes while the list follows its end and the chat shows, not caught up on (Chat.kt
/// arrived, caught). What comes then (a message simply coming in, an agent's line, an outbox entry) is in the list at
/// once, its room opening from then (Turns::admit), as is what was sent from here, the frame it is sent, before the
/// core has it (LocalSent).
///|
/// How far under the list's room at its top a row followed from its top stops.
pub let follow_margin : Double = 12.0

///|
pub let flash_held : Ref[Bool] = Ref(false)

///|
/// A message gone to flashes: the accent's ground in over `flash_in_ms` on Ease.Out, held to
/// `flash_held_ms`, gone by `flash_ms` on the standard curve.
pub let flash_in_ms : Double = 160.0

///|
pub let flash_held_ms : Double = 900.0

///|
pub let flash_ms : Double = 1700.0

///|
/// When the flash of the messages gone to (in every chat read) is over (the frames' clock; once over, the end it was
/// given, Anim::ended_at; -1: none has flashed): a test
/// runs to it after opening a chat at a message (a notification tapped, a decision's post).
pub fn flash_rest() -> Double {
  let mut end = flash_rest_nodes.val
  readings.each(fn(_, rd) { if rd.flash_lit.ended_at() > end { end = rd.flash_lit.ended_at() } })
  end
}

///|
/// When the flash of the message last gone to on a chat's page made as nodes is over (sfpages' chat_flash_node: its
/// go-to's moment and flash_ms; -1 none): flash_rest's as well.
// kept across runs: put back by the package's reset (pages.mbt)
pub let flash_rest_nodes : Ref[Double] = Ref(-1.0)

///|
/// MBUI_CHAT_AT_END=1: a chat opens at its end, whatever the core says of where it was left (scripted runs).
pub let at_end_env : Ref[Int] = { val: -1 }

///|
pub fn at_end_asked() -> Bool {
  if at_end_env.val < 0 {
    at_end_env.val = if @ui.env("MBUI_CHAT_AT_END") == "1" { 1 } else { 0 }
  }
  at_end_env.val == 1
}

///|
/// Tells the core the chat shows, its end seen or not, and the last message seen
/// whole (`seen`), as either changes; it marks what is read and where the unread line goes. Never with
/// Source.readonly.
pub fn tell_focus(
  src : Source,
  r : ChatRef,
  v : ChatView,
  rd : Reading,
  seen : Bool,
  whole : Double,
) -> Unit {
  if src.read_only {
    return
  }
  let said = "\{seen} \{whole}"
  if rd.told == said {
    return
  }
  rd.told = said
  let chat = focus_chat(r, v, Some(seen))
  if whole >= 0.0 {
    match chat {
      Object(o) => o["seen"] = Json::number(whole)
      _ => ()
    }
  }
  (src.call)("client.focus", { "chat": chat }, answer_unread)
}

///|
/// Asked at once, for a page made as nodes (its press's handler): the place kept forgotten, and where the
/// window is short of the chat's end its latest page asked (true; false where it is not short of it).
pub fn chat_latest_now(
  src : Source,
  r : ChatRef,
  v : ChatView,
  what : String,
  failed? : () -> Unit = fn() {  },
) -> Bool {
  place_forget(r.station + "\u{1}" + r.session)
  guard v.newer && v.thread is Some(th) else { return false }
  let rd = reading_of(r.station + "\u{1}" + r.session)
  rd.latest_asked = true
  chat_latest_act(src, r.station, th, what, rd, failed~)
  true
}

///|
/// The chat's latest page asked (`chat.latest`), its Reading `rd` told where it fails, and `failed`.
fn chat_latest_act(
  src : Source,
  station : String,
  th : Double,
  what : String,
  rd : Reading,
  failed? : () -> Unit = fn() {  },
) -> Unit {
  act(src, what, "", "chat.latest", { "station": Json::string(station), "thread": Json::number(th) }, failed=fn() {
    rd.latest_asked = false
    failed()
  })
}

///|
pub fn focus_chat(r : ChatRef, v : ChatView, end : Bool?) -> Json {
  let o : Map[String, Json] = {
    "station": Json::string(r.station),
    "session": Json::string(r.session),
  }
  match v.thread {
    Some(th) => o["thread"] = Json::number(th)
    None => ()
  }
  match end {
    Some(e) => o["end"] = Json::boolean(e)
    None => ()
  }
  Json::object(o)
}

///|
/// Where the chat is, told the core (`chat.place`): the message at the top and how far its top is below
/// the list's (in the screen's pixels, as Android's app tells it), none at its end; told again as the message at the
/// top changes, and where it is to the pixel as it is left (`exact`). Not each pixel it moves: rows moving on their own
/// (words sent going up into the list) moved it each frame, told and written down each frame (2026-11-08: 20 a send).
/// Opened again this run, it is where it was to the pixel (kept_places).
pub fn tell_place(src : Source, r : ChatRef, v : ChatView, rd : Reading, exact? : Bool = false) -> Unit {
  // kept here too, for opening it again this run
  if rd.top_seq >= 0.0 {
    kept_places[r.station + "\u{1}" + r.session] = {
      top: rd.top_seq,
      offset: rd.top_off,
      piece: -1,
      piece_offset: 0.0,
      bottom: if rd.at_end {
        match v.messages.last() {
          Some(m) => m.seq
          None => -1.0
        }
      } else {
        -1.0
      },
    }
  }
  guard v.thread is Some(th) && !src.read_only else { return }
  let scale = rd.scale
  let place : Map[String, Json] = { "station": Json::string(r.station), "thread": Json::number(th) }
  if !rd.at_end && rd.top_seq >= 0.0 {
    place["seq"] = Json::number(rd.top_seq)
    place["offset"] = Json::number((rd.top_off * scale).round())
  }
  let said = Json::object(place).stringify()
  let at = match place.get("seq") {
    Some(seq) => seq.stringify()
    None => ""
  }
  if said == rd.told_place || (!exact && at == rd.told_at) {
    return
  }
  rd.told_place = said
  rd.told_at = at
  (src.call)("chat.place", Json::object(place), answer_unread)
}

///|
/// Whether the end of chat `v`'s list keeps clear of the bell floating over it (what waits to be decided there, its
/// end not one: the core's `askClear`): the room under its rows the taller.
pub fn ask_clears(v : ChatView) -> Bool {
  !(v.archived || v.thread is None) && !v.asks.is_empty() && v.ask_clear
}
