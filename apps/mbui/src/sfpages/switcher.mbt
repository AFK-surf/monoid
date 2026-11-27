// The search (still.fail web/src/Switcher.tsx Finder, Found; web/src/mobile/Home.tsx SearchPage, FoundRow, FoundChatRow,
// FoundItemRow; Switcher.css.ts, mobile/Home.css.ts mFound…): one in every tier, its words and what they find; where
// it sits is its frame's (⌘K's panel over the window, the phone's page over Home's list: sfdesk's switcher.mbt, sfapp's
// search.mbt). What a few words find in the workspace is the core's `search` (its chats, the messages
// that have them, what every station finds besides, each kind under its heading, a few of each; 查看更多 that kind
// alone, 全部结果 back to all), and what can be done here by its name the core's `commands.find` of what the frame
// offers. With nothing typed, the latest chats where the frame says so (⌘K), then what can be done. One line for all it
// finds (its sizes the theme's: @sf.Found); where the screen has keys, ↑ / ↓ choose and Enter opens, a press anywhere.

///|
/// What can be done here, as the frame offers it: a key's action it answers now, or one of its
/// own; for one the core does not name (a settings page), its `label`, `group`, other `words`, and whether it is only
/// found by typing; for one whose name the core words with something, the version an update goes to and the station
/// updated ("" none); its icon, its keys (a key's action's, as kept on this device), what it does.
pub(all) struct Offered {
  id : String
  label : String
  group : String
  words : String
  typed : Bool
  version : String
  station : String
  icon : String
  keys : String
  run : () -> Unit
}

///|
/// A command as the list shows it: its part, its part's heading, its name, as the core says.
#derive(Eq)
priv struct Listed {
  id : String
  group : String
  heading : String
  label : String
}

///|
/// A line of the list (SearchPage's rows, and the headings and words between).
priv enum FindLine {
  Head(String)
  /// over one kind alone: back to every kind (全部结果)
  Back
  /// 查看更多 under a kind: that kind alone
  More(String)
  Command(Listed, Offered)
  Chat(FoundChat)
  Message(FoundMessage)
  Item(FoundItem)
  /// a line of quiet words (none found, the core too old to search)
  Note(String)
  /// the stations still answering, or one that could not be searched (red)
  Wait(String, Bool)
  /// what the core says of the rest
  Said(String)
}

///|
/// Two lines the same: what they show, a command by what it is offered as (its id; what it runs is the frame's now).
impl Eq for FindLine with equal(a, b) {
  match (a, b) {
    (FindLine::Head(x), FindLine::Head(y)) | (More(x), More(y)) | (FindLine::Note(x), FindLine::Note(y)) | (Said(x), Said(y)) => x == y
    (Back, Back) => true
    (Command(l, o), Command(m, p)) => l == m && o.id == p.id && o.icon == p.icon && o.keys == p.keys
    (FindLine::Chat(x), FindLine::Chat(y)) => x == y
    (Message(x), Message(y)) => x == y
    (FindLine::Item(x), FindLine::Item(y)) => x == y
    (Wait(x, e), Wait(y, f)) => x == y && e == f
    _ => false
  }
}

///|
/// The search as it stands: the kind looked at alone ("" every kind); the row chosen (its place among those to choose),
/// and whether it is shown so (where the screen has keys: a finger's mark none, so its keyboard's search key opens
/// nothing); its field and what is typed; the view last read (kept while the next words are looked up) and whether
/// reading it failed; what was last asked of `commands.find`, its last answer and what it answered (kept: the list
/// opened again with the same words has it at once; for other words none until the core has answered them); the lines
/// as last shown (what Enter opens) and those of them to choose; how many times ↑ ↓ chose a line (the one chosen
/// brought into view then) and the list was sent back to its top (into one kind or out of it). Each a signal: what
/// shows it follows it.
priv struct Finder {
  kind : @signals.Signal[String]
  chosen : @signals.Signal[Int]
  mut chosen_shown : Bool
  field : @ui.Field
  mut query : String
  kept : @signals.Signal[SearchView?]
  kept_of : @signals.Signal[(Int, String, String)]
  failed : @signals.Signal[Bool]
  asked : @signals.Signal[String]
  listed : @sf.LiveArray[Listed]
  listed_for : @signals.Signal[String]
  lines : @signals.Signal[Array[FindLine]]
  picks : @signals.Signal[Array[Int]]
  keyed : @signals.Signal[Int]
  to_top : @signals.Signal[Int]
  /// the `search` topic read last (its params), let go of as the next words are read or the search closes: one read
  /// and kept is shown to the core, which asks its stations again with each change of theirs (each a search of the
  /// machine's files there)
  mut held : Map[String, Json]?
}

///|
let finder : Finder = {
  kind: @signals.signal("", same=fn(a, b) { a == b }),
  chosen: @signals.signal(0, same=fn(a, b) { a == b }),
  chosen_shown: false,
  field: @ui.Field::new(),
  query: "",
  kept: @signals.signal(None),
  kept_of: @signals.signal((-1, "", ""), same=fn(a, b) { a == b }),
  failed: @signals.signal(false, same=fn(a, b) { a == b }),
  asked: @signals.signal("", same=fn(a, b) { a == b }),
  listed: @sf.LiveArray::new(),
  listed_for: @signals.signal("", same=fn(a, b) { a == b }),
  // (by the one array: a command's line holds the function it runs)
  lines: @signals.signal_ref([]),
  picks: @signals.signal([]),
  keyed: @signals.signal(0, same=fn(a, b) { a == b }),
  to_top: @signals.signal(0, same=fn(a, b) { a == b }),
  held: None,
}

///|
/// How the search read last is let go of as the search closes.
let finder_leave : Ref[(() -> Unit)?] = Ref(None)

///|
fn finder_reset() -> Unit {
  finder_cleared()
  finder.asked.set("")
  finder.listed.clear()
  finder.listed_for.set("")
}

///|
/// What one opening of the search leaves behind, put back as it closes (its frame says when): the `search` topic it
/// read last let go of.
pub fn finder_cleared() -> Unit {
  match finder_leave.val {
    Some(leave) => leave()
    None => ()
  }
  finder_leave.val = None
  finder.held = None
  finder.kind.set("")
  finder.chosen.set(0)
  finder.query = ""
  finder.field.set("")
  // (as it is, nothing set: what is cleared as a page is built changes nothing it reads where it was clear)
  @signals.untracked(fn() {
    if finder.kept.get() is Some(_) {
      finder.kept.set(None)
    }
    if finder.lines.get().length() > 0 {
      finder.lines.set([])
    }
    if finder.picks.get().length() > 0 {
      finder.picks.set([])
    }
  })
  finder.kept_of.set((-1, "", ""))
  finder.failed.set(false)
}

///|
/// The search opened with `words` typed and `kind` alone ("" every kind): a made-up run's start.
pub fn finder_start(words : String, kind? : String = "") -> Unit {
  finder_cleared()
  finder.query = words
  finder.field.set(words)
  finder.kind.set(kind)
}

///|
/// The field the frame's editor writes the words in.
pub fn finder_field() -> @ui.Field {
  finder.field
}

///|
/// The kind looked at alone ("" every kind).
pub fn finder_kind() -> String {
  finder.kind.untracked()
}

///|
/// What is typed now.
pub fn finder_query() -> String {
  finder.query
}

///|
/// The words in the field as the frame's editor has them now: the first line chosen again when they change.
pub fn finder_typed(words : String) -> Unit {
  if words != finder.query {
    finder.query = words
    finder.chosen.set(if finder.kind.untracked() != "" { 1 } else { 0 })
  }
}

///|
/// Esc: words typed, cleared first (a Mac's search field's Esc: the owner, 2026-11-16, 照苹果的来); then as
/// finder_back. Whether it took it (else the frame closes the search).
pub fn finder_escape() -> Bool {
  if finder.field.text() != "" {
    finder.field.set("")
    finder_typed("")
    return true
  }
  finder_back()
}

///|
/// In one kind's list, back to all of them (全部结果, back, and Esc with nothing typed). Whether it went back.
pub fn finder_back() -> Bool {
  if finder.kind.untracked() == "" {
    return false
  }
  finder.kind.set("")
  finder.chosen.set(0)
  finder.to_top.set(finder.to_top.untracked() + 1)
  true
}

///|
/// Enter: the line chosen opened where it is shown chosen (`close` first, where the frame closes the search as one
/// opens).
pub fn finder_enter(close : () -> Unit) -> Unit {
  match finder.picks.untracked().get(finder.chosen.untracked()) {
    Some(k) if finder.chosen_shown => finder_go(finder.lines.untracked()[k], close)
    _ => ()
  }
}

///|
/// What the `search` topic is asked for `query` over workspace `scope`, of the kind looked at alone where there is one.
fn search_params(scope : String, query : String) -> Map[String, Json] {
  let params : Map[String, Json] = { "scope": Json::string(scope), "query": Json::string(query) }
  let kind = finder.kind.untracked()
  if kind != "" {
    params["kind"] = Json::string(kind)
  }
  params
}

///|
/// The `search` topic asked with `params` held from now: the one held before let go of where it was asked otherwise,
/// this one as the search closes (finder_cleared).
fn search_hold(src : Source, params : Map[String, Json]) -> Unit {
  match finder.held {
    Some(before) if before != params => (src.leave)("search", before, @sfbase.TopicLeave::Legacy)
    Some(_) => return
    None => ()
  }
  finder.held = Some(params)
  finder_leave.val = Some(fn() { (src.leave)("search", params, @sfbase.TopicLeave::Legacy) })
}

///|
/// What the search's `topic` says of `query` taken: whether reading it failed; its value the view kept, the last read
/// kept while the next is looked up.
fn search_took(topic : @sfbase.TopicState, query : String) -> Unit {
  finder.failed.set(topic.error is Some(_))
  match topic.value {
    Some(v) => {
      let of = (topic.version, query, finder.kind.untracked())
      if finder.kept_of.untracked() != of || finder.kept.untracked() is None {
        finder.kept.set(Some(search_view(v)))
        finder.kept_of.set(of)
      }
    }
    None => ()
  }
}

///|
/// What the words find (the `search` topic over the workspace: with none, the latest chats) read now, held
/// (search_hold) and taken (search_took): the last view read while the next is looked up. (Held by its tests,
/// finder_held_wbtest.mbt: the list made once holds and takes it as it reads it, finder_list_node.)
#warnings("-unused_value")
fn search_of(src : Source, scope : String, query : String) -> SearchView? {
  let params = search_params(scope, query)
  search_hold(src, params)
  search_took(src.topic("search", params).get(), query)
  finder.kept.untracked()
}

///|
/// The list's lines (Finder, SearchPage): one kind alone, 全部结果 first; with words, what can be done first, then the
/// chats (查看更多 under them), the messages (查看更多), each kind the stations found under its heading (查看更多),
/// none found, the stations still answering or failing, what the core says of the rest. With none typed, the latest
/// chats where `idle_chats` (⌘K's), then what can be done.
fn lines_of(view : SearchView?, typed : Bool, idle_chats : Bool, commands : Array[(Listed, Offered)]) -> Array[FindLine] {
  let lines : Array[FindLine] = []
  let kind = finder.kind.get()
  let actions = if kind != "" { [] } else { commands }
  let add_actions = fn() {
    for k, x in actions {
      if k == 0 || actions[k - 1].0.group != x.0.group {
        lines.push(Head(x.0.heading))
      }
      lines.push(Command(x.0, x.1))
    }
  }
  if kind != "" && typed {
    lines.push(Back)
  }
  if typed && view is None && finder.failed.get() {
    lines.push(Note(@sf.t("android-chat.search.update")))
  }
  if typed {
    add_actions()
  }
  let chats = match view {
    Some(v) if typed || idle_chats => v.chats
    _ => []
  }
  if chats.length() > 0 && (actions.length() > 0 || typed) {
    lines.push(Head(@sf.t("web-main.switcher.chats")))
  }
  for ch in chats {
    lines.push(Chat(ch))
  }
  match view {
    Some(v) if typed && kind == "" && v.chats_more => lines.push(More("chat"))
    _ => ()
  }
  if !typed {
    add_actions()
  }
  match view {
    Some(v) if typed => {
      if v.messages.length() > 0 {
        lines.push(Head(@sf.t("web-main.switcher.messages")))
      }
      for m in v.messages {
        lines.push(Message(m))
      }
      if kind == "" && v.messages_more {
        lines.push(More("message"))
      }
      for g in v.groups {
        lines.push(Head(g.title))
        for it in g.items {
          lines.push(Item(it))
        }
        if kind == "" && g.more {
          lines.push(More(g.kind))
        }
      }
      let none = v.chats.length() == 0 &&
        v.messages.length() == 0 &&
        v.groups.iter().all(fn(g) { g.items.length() == 0 }) &&
        actions.length() == 0
      if none && !v.reading {
        lines.push(Note(@sf.t("web-main.switcher.noMatch")))
      }
      if v.reading {
        lines.push(Wait(v.wait_text.unwrap_or(@sf.t("common.reading")), false))
      }
      for f in v.failing {
        lines.push(Wait(f, true))
      }
      match v.note {
        Some(n) => lines.push(Said(n))
        None => ()
      }
    }
    Some(v) if idle_chats && v.chats.length() == 0 && actions.length() == 0 && !v.reading =>
      lines.push(Note(@sf.t("web-main.switcher.none")))
    _ => ()
  }
  lines
}

///|
/// A line picked (Enter, a press): a command done, a chat opened (a message at it, its words marked), something else
/// where the core says it opens, each after `close`; 查看更多 its kind alone, 全部结果 all again.
fn finder_go(line : FindLine, close : () -> Unit) -> Unit {
  let words = match finder.kept.untracked() {
    Some(v) => v.words
    None => []
  }
  match line {
    Back => ignore(finder_back())
    More(kind) => {
      finder.kind.set(kind)
      finder.chosen.set(1)
      finder.to_top.set(finder.to_top.untracked() + 1)
    }
    Command(_, o) => {
      close()
      (o.run)()
    }
    Chat(ch) => {
      close()
      open_page(@sfbase.Page::Chat(@sfbase.chat_ref_of(ch.item)))
    }
    Message(m) => {
      close()
      @sfbase.open_chat_found(@sfbase.chat_ref_of(m.chat), m.seq, words)
    }
    Item(it) => {
      close()
      @sfbase.open_found(it)
    }
    Head(_) | Note(_) | Wait(_, _) | Said(_) => ()
  }
}

///|
/// Whether a line is one to choose (↑ / ↓, Enter).
fn pickable(l : FindLine) -> Bool {
  match l {
    Head(_) | Note(_) | Wait(_, _) | Said(_) => false
    _ => true
  }
}

///|
/// A line's key: what it is, so the pointer and the list keep it.
fn finder_key(line : FindLine) -> String {
  match line {
    Head(w) => "h/" + w
    Back => "back"
    More(k) => "more/" + k
    Command(l, _) => "cmd/" + l.id
    Chat(ch) => "c/" + ch.item.station + "/" + ch.item.id
    Message(m) => "m/" + m.station + "/" + m.chat.session + "/" + m.seq.to_string()
    Item(it) => "i/" + it.key
    Note(w) => "note/" + w
    // (waiting and failed apart: a block of its own each, a spinner's or the words in red: quiet_line_node)
    Wait(w, e) => (if e { "wait!/" } else { "wait/" }) + w
    Said(w) => "said/" + w
  }
}

///|
/// A line's height, as the list first takes it (the theme's: one line, two, a heading, quiet words; `stacked`: who,
/// where and when under its words, two).
fn finder_h(l : FindLine, f : @sf.Found, stacked : Bool) -> Double {
  match l {
    Head(_) => f.head_h
    Note(_) | Wait(_, _) | Said(_) => f.quiet_h
    _ => if finder_two(l, stacked) { f.two_h } else { f.row_h }
  }
}

///|
/// A line's height at the system's size of words (finder_h's, grown as its words are by `grown`: FoundGrown).
fn finder_line_h(l : FindLine, f : @sf.Found, grown : FoundGrown, stacked : Bool) -> Double {
  finder_h(l, f, stacked) +
  (match l {
    Head(_) => grown.head
    _ if finder_two(l, stacked) => grown.two
    _ => 0.0
  })
}

///|
/// How much a heading and a line of two grow at the system's size of words `scale` (@sf.found_grown).
priv struct FoundGrown {
  head : Double
  two : Double
}

///|
fn FoundGrown::at(f : @sf.Found, scale : Double) -> FoundGrown {
  { head: @sf.found_grown(f, scale, two=false), two: @sf.found_grown(f, scale, two=true) }
}

///|
/// Whether a line says something under its first line (a message its chat, an item its line with the words, a chat the
/// words found in it; `stacked`: who, where and when under the words of a chat or an item).
fn finder_two(l : FindLine, stacked : Bool) -> Bool {
  match l {
    Message(_) => true
    Item(it) => it.text != "" || stacked
    Chat(ch) => ch.found is Some(_) || stacked
    _ => false
  }
}

///|
/// Narrower than this, a line says who, where and when under its first line (beside where it is, where it says one):
/// its first line all its words' (a chat's title, the words found), one line or two (as a file's row puts its size and
/// time under its name narrower than its row_stack_below).
let found_stack_below : Double = 440.0

///|
/// Whether a line in a list `width` wide says who, where and when under its words.
pub fn found_stacked(width : Double) -> Bool {
  width < found_stack_below
}

// ── made once ──────────────────────────────────────────────────────────

///|
/// ↓ and ↑ in node `v`, which holds the search's field and its list (⌘K's panel, the search's page): each chooses the
/// line after or before the one chosen, at its key's moment, and brings it into view (finder_list_node).
pub fn finder_keys_node(v : @view.View) -> Unit {
  let step = fn(by : Int) -> Bool {
    let at = finder.chosen.untracked() + by
    if at >= 0 && at < finder.picks.untracked().length() {
      finder.chosen.set(at)
      finder.keyed.set(finder.keyed.untracked() + 1)
    }
    true
  }
  v.key_context("Finder").on_action("finder.down", fn(_) { step(1) }).on_action("finder.up", fn(_) { step(-1) }) |> ignore
}

///|
/// What the search is to the keys and a screen reader, in node `v` that holds its field (⌘K's search box, the search
/// page's): the library's search combobox (`@sf.search_combo_node`, mbui's headless combobox in `v` itself), called
/// `label`, its options the lines to choose (pickable, by their keys: finder_key), the one active the one chosen, read
/// out selected where the screen has keys (as it is shown so). ↓ and ↑ from the field (the keymap's: @sf's
/// combobox_bindings) choose the line after or before it, no further than the ends, and bring it into view
/// (finder_list_node); a line pressed is chosen and opened (`close` first, as finder_go), and Enter opens the one chosen
/// where it is shown chosen (as finder_enter); Escape stays the panel's or the page's (finder_escape). The combobox, for
/// the list's lines (finder_list_node).
pub fn finder_combobox_node(v : @view.View, label : () -> String, close : () -> Unit) -> @sf.SearchCombo {
  let picked = fn() {
    let ls = finder.lines.get()
    finder.picks.get().map(fn(i) { finder_key(ls[i]) })
  }
  let active = fn() {
    match finder.picks.get().get(finder.chosen.get()) {
      Some(i) => finder.lines.get().get(i).map(finder_key)
      None => None
    }
  }
  // (the key a press made active, chosen at once after it: opened whether or not the screen shows what is chosen;
  // whether the keys' last move changed the line chosen, brought into view then)
  let pressed : Ref[String?] = Ref(None)
  let changed = Ref(false)
  @sf.search_combo_node(
    v,
    label,
    picked,
    active,
    fn(k) {
      changed.val = false
      match k {
        Some(key) => {
          pressed.val = k
          match @signals.untracked(picked).search(key) {
            Some(j) if j != finder.chosen.untracked() => {
              finder.chosen.set(j)
              changed.val = true
            }
            _ => ()
          }
        }
        None => ()
      }
    },
    fn(key) {
      let by_press = pressed.val == Some(key)
      pressed.val = None
      if by_press || finder.chosen_shown {
        match finder.lines.untracked().iter().find_first(fn(l) { finder_key(l) == key }) {
          Some(l) => finder_go(l, close)
          None => ()
        }
      }
    },
    // (read out selected where the screen shows it chosen)
    chosen=fn() { if @sf.theme().chat_list.keys { active() } else { None } },
    moved=fn(_) {
      pressed.val = None
      if changed.val {
        finder.keyed.set(finder.keyed.untracked() + 1)
      }
    },
  )
}

///|
/// The search's list (finder_list's, made once) in node `v`, for the workspace in view (`workspace()`): what the words
/// in the field find and what of `offered()` can be done by them; with nothing typed the latest chats where
/// `idle_chats`. `most()`: as tall as its lines up to so much (⌘K's panel), else the room it is given. A line chosen by
/// ↑ / ↓ (finder_combobox_node, on what holds its field) or by the pointer over it where the screen has keys, shown so,
/// opened by Enter or a press (what the frame does as one opens the combobox's `close`: ⌘K closes; the phone's page
/// stays under the chat). `stacked()`: who, where and when said under a line's words (its list narrow: found_stacked). `at`:
/// where its list stands (a panel's, ⌘K's, as a side column's; the phone's search across the whole screen), its lines
/// in and rounded so. `foot_in`: room after its last line (⌘K's panel). Each line a block of the list by its key, made
/// only while it shows (View::scrolls_window), what it shows told it by that key (View::keyed_by). Its list the listbox
/// of `combo` (finder_combobox_node), its lines to choose its options.
pub fn finder_list_node(
  v : @view.View,
  combo : @sf.SearchCombo,
  src : Source,
  workspace : () -> Workspace?,
  offered : () -> Array[Offered],
  stacked : () -> Bool,
  idle_chats? : Bool = false,
  most? : () -> Double? = fn() { None },
  at? : @sf.ListAt = Side,
  foot_in? : Double = 0.0,
) -> Unit {
  let theme = fn() { @sf.theme().chat_list }
  // (the words as the field has them, as they are typed: the first line chosen again as they change)
  v.reacts(fn() { finder.field.text() }, fn(words) { finder_typed(words) })
  let query = @signals.computed(fn(_) { finder.field.text().trim(chars=" \t\n\r\u{3000}").to_owned() })
  // what can be done by its name: the core's `commands.find` of what is offered, asked as what is asked changes; none
  // until it has answered these words
  let asked = @signals.computed(fn(_) { commands_params(query.get(), offered()).stringify() })
  v.reacts(fn() { asked.get() }, fn(a) {
    if offered().is_empty() || finder.asked.untracked() == a {
      return
    }
    finder.asked.set(a)
    let params = @json.parse(a) catch { _ => Json::null() }
    (src.call)("commands.find", params, fn(res) {
      match res {
        Ok(v) if finder.asked.untracked() == a => {
          let listed : Array[Listed] = []
          for g in items(Some(v), "groups") {
            let g = Some(g)
            for f in items(g, "commands") {
              listed.push({ id: text(Some(f), "id"), group: text(g, "group"), heading: text(g, "title"), label: text(Some(f), "label") })
            }
          }
          finder.listed.replace(listed)
          finder.listed_for.set(a)
        }
        _ => ()
      }
    })
  })
  let commands = @signals.computed_by(
    fn(_) {
      let out : Array[(Listed, Offered)] = []
      let all = offered()
      if all.is_empty() || finder.listed_for.get() != asked.get() {
        return out
      }
      for l in finder.listed {
        for o in all {
          if o.id == l.id {
            out.push((l, o))
            break
          }
        }
      }
      out
    },
    // (by the one array: a command holds the function it runs)
    same=fn(a, b) { physical_equal(a, b) },
  )
  // what the words find: the `search` topic over the workspace (with none, the latest chats), the last view read kept
  // while the next is looked up; the one read held, the one before let go of (search_hold)
  v.reacts(
    fn() {
      match workspace() {
        Some(w) => {
          finder.kind.get() |> ignore
          let params = search_params(w.id, query.get())
          Some((params, src.topic("search", params).get()))
        }
        None => None
      }
    },
    fn(now) {
      match now {
        Some((params, topic)) => {
          search_hold(src, params)
          search_took(topic, query.untracked())
        }
        None => ()
      }
    },
  )
  // its lines, by their keys, each told what it is by its key; those to choose, and the one chosen
  let lines = @signals.computed_by(
    fn(_) { lines_of(finder.kept.get(), query.get() != "", idle_chats, commands.get()) },
    // (made anew as anything it is made of changes: a command's line holds the function it runs)
    same=fn(a, b) { physical_equal(a, b) },
  )
  let place : @view.ListPlace[String] = @view.ListPlace::new()
  // (the words the lines were last made for: other words, the list from its top)
  let made_for : Ref[String?] = Ref(None)
  v.reacts(fn() { lines.get() }, fn(ls) {
    let picks : Array[Int] = []
    for i, l in ls {
      if pickable(l) {
        picks.push(i)
      }
    }
    // The list at its top stays there as the lines change under it with its first line chosen (what can be done by
    // the words answered after what they found, put over it), and goes back to its top for other words: else it
    // holds the line it showed at its top where it was, the line chosen, the first, over what shows.
    let words = query.untracked()
    let was = finder.lines.untracked()
    // (where a place asked of it is not yet done, what it has in sight is where it was, not where it goes)
    let at_top = place.asking() ||
      (match place.sight_now() {
        Some(s) => was.get(0).map(finder_key) == Some(s.first) && s.into <= 0.5
        None => true
      })
    let first = if finder.kind.untracked() != "" { 1 } else { 0 }
    // (the same first line: the list held by it stays at its top as it is, nothing asked of it)
    let first_moved = was.get(0).map(finder_key) != ls.get(0).map(finder_key)
    if made_for.val != Some(words) || (first_moved && at_top && finder.chosen.untracked() <= first) {
      match ls.get(0) {
        Some(l) => place.bring(finder_key(l))
        None => ()
      }
    }
    made_for.val = Some(words)
    finder.lines.set(ls)
    finder.picks.set(picks)
    // (the one chosen kept among them)
    let n = picks.length()
    if finder.chosen.untracked() >= n {
      finder.chosen.set(if n > 0 { n - 1 } else { 0 })
    }
  })
  let keys = @signals.computed(fn(_) { lines.get().map(finder_key) })
  let of_key = @signals.computed_by(
    fn(_) {
      let m : Map[String, (FindLine, Int)] = Map([])
      let mut k = 0
      for l in lines.get() {
        let pick = if pickable(l) { k } else { -1 }
        if pickable(l) {
          k = k + 1
        }
        m[finder_key(l)] = (l, pick)
      }
      m
    },
    same=fn(a, b) { physical_equal(a, b) },
  )
  // (chosen by the keys where the screen has them: shown so, Enter opens it)
  v.reacts(fn() { theme().keys }, fn(on) { finder.chosen_shown = on })
  let chosen_key = @signals.computed(fn(_) {
    match finder.picks.get().get(finder.chosen.get()) {
      Some(i) => finder.lines.get().get(i).map(finder_key)
      None => None
    }
  })
  // (several stations: what is found says which it is on)
  let several = @signals.computed(fn(_) {
    match workspace() {
      Some(w) => @sfbase.station_marks(src, w.id).length() > 1
      None => false
    }
  })
  // ↑ ↓: the line chosen brought into view only where it is not wholly in it, the list moved no further than that
  // (its top at the top where it lay over it, with its kind's heading over it where it is the first of its kind; its
  // foot at the foot, over the room that fades after the last line, where it lay under it); in view, the list stays
  v.reacts(fn() { finder.keyed.get() }, at_start=false, fn(_) {
    let ls = finder.lines.untracked()
    match finder.picks.untracked().get(finder.chosen.untracked()) {
      Some(i) => {
        let f = theme().found
        let grown = FoundGrown::at(f, v.words_scale())
        let narrow = @signals.untracked(stacked)
        let tops : Array[Double] = []
        let mut y = 0.0
        for line in ls {
          tops.push(y)
          y = y + finder_line_h(line, f, grown, narrow)
        }
        let h = fn(j : Int) { finder_line_h(ls[j], f, grown, narrow) }
        // (from its kind's heading where it is its first line; from the list's top where none is chosen over it)
        let from = if i > 0 && ls[i - 1] is Head(_) { i - 1 } else { i }
        let mut over = false
        for j in 0..<from {
          if pickable(ls[j]) {
            over = true
            break
          }
        }
        let from = if over { from } else { 0 }
        let sight = place.sight_now()
        let at = sight.bind(fn(s) {
          for j in 0..<ls.length() {
            if finder_key(ls[j]) == s.first {
              return Some((s, tops[j] + s.into))
            }
          }
          None
        })
        match at {
          Some((s, top)) => {
            let room = s.shows - foot_in
            if tops[from] < top - 0.5 {
              place.bring(finder_key(ls[from]))
            } else if tops[i] + h(i) > top + room + 0.5 {
              // (the line whose block the list's top then lies in, as far down it as that is)
              let want = dmax(0.0, tops[i] + h(i) - room)
              let mut j = 0
              while j + 1 < ls.length() && tops[j + 1] <= want {
                j = j + 1
              }
              place.bring(finder_key(ls[j]), offset=want - tops[j])
            }
          }
          None => place.bring(finder_key(ls[from]))
        }
      }
      None => ()
    }
  })
  v.reacts(fn() { finder.to_top.get() }, at_start=false, fn(_) {
    match finder.lines.untracked().get(0) {
      Some(l) => place.bring(finder_key(l))
      None => ()
    }
  })
  v.box(fn(l) {
    // (as high as its lines come to at the system's size of words, `most` at most; else the room it is given)
    l
    .grow(By(fn() { if most() is None { 1.0 } else { 0.0 } }))
    .min_height(Is(Some(0.0)))
    .height(By(fn() {
      match most() {
        Some(m) => {
          let f = theme().found
          let grown = FoundGrown::at(f, l.words_scale())
          let narrow = stacked()
          let est = lines.get().fold(init=foot_in, fn(h, line) { h + finder_line_h(line, f, grown, narrow) })
          Some(dmin(m, est))
        }
        None => None
      }
    }))
    |> ignore
    // (what scrolls past its foot fading out over the room after its last line: ⌘K's panel's curve)
    if foot_in > 0.0 {
      l.fades(Is((0.0, 0.0, 0.0, foot_in))) |> ignore
    }
    combo.list_node(l)
    let lit = l.selected(fn() { chosen_key.get() })
    // (a line's block taken by the next line of its make to show as it no more does, or as the words typed bring
    // others, its key that one's: finder_line_shape; the room under its last line the list's end_room, no block of it:
    // never what holds what shows, so lines told after it shows come in under the list's top)
    l.scrolls_reused(
      @view.Scroll::list(),
      fn() { keys.get() },
      shape=fn(k) { finder_line_shape(of_key.untracked().get(k)) },
      reuses=fn(k) { of_key.untracked().get(k) is Some(_) },
      est=@signals.untracked(fn() { theme().found.row_h }),
      slop=@ui.touch_slop(),
      bar=@ui.tree_scroll_bar(),
      place~,
      // (what the words find stands there as it is found, each line there or gone at once, as the words are typed: no
      // line making its way in or out under the hand at each key)
      comes=fn(_) { false },
      goes=fn(_) { false },
      end_room=fn() { foot_in },
      fn(b, k) {
        let held = @signals.computed_by(fn(_) { of_key.get().get(k()) }, same=fn(a, b) {
          match (a, b) {
            (Some(x), Some(y)) => physical_equal(x.0, y.0) && x.1 == y.1
            (None, None) => true
            _ => false
          }
        })
        let line = fn() { held.get() }
        // (what it is made as: its make, which never changes for a block, finder_line_shape's)
        match @signals.untracked(line) {
          Some((first, pick)) if pick >= 0 =>
            found_line_node(b, combo, first, line, k, lit, several, at, stacked)
          Some((first, _)) => quiet_line_node(b, first, line, at)
          None => ()
        }
      },
    )
    |> ignore
  })
  |> ignore
}

///|
/// Which block of the search's list a line takes as it comes to show (View::scrolls_reused's `shape`): each make its
/// own (found_line_node's and quiet_line_node's by what the line is; a station's line by whether it has a mark).
fn finder_line_shape(held : (FindLine, Int)?) -> Int {
  match held {
    Some((FindLine::Head(_), _)) => 0
    Some((FindLine::Note(_), _)) => 1
    Some((Wait(_, false), _)) => 2
    Some((Wait(_, true), _)) => 3
    Some((Said(_), _)) => 4
    Some((Back, _)) => 5
    Some((More(_), _)) => 6
    Some((Command(_, _), _)) => 7
    Some((FindLine::Chat(_), _)) => 8
    Some((Message(_), _)) => 9
    Some((FindLine::Item(it), _)) =>
      if it.kind != "station" {
        10
      } else if @sf.has_station_mark(it.station_emoji, it.station_icon) {
        11
      } else {
        12
      }
    None => 13
  }
}

///|
/// What `commands.find` is asked for `query` of `offered` (by name, id or other words, part by part; with nothing typed
/// all but what is only found by typing).
fn commands_params(query : String, offered : Array[Offered]) -> Json {
  {
    "query": Json::string(query),
    "offered": Json::array(
      offered.map(fn(o) {
        let m : Map[String, Json] = { "id": Json::string(o.id) }
        if o.label != "" {
          m["label"] = Json::string(o.label)
        }
        if o.group != "" {
          m["group"] = Json::string(o.group)
        }
        if o.words != "" {
          m["words"] = Json::string(o.words)
        }
        if o.typed {
          m["typed"] = Json::boolean(true)
        }
        if o.version != "" {
          m["version"] = Json::string(o.version)
        }
        if o.station != "" {
          m["station"] = Json::string(o.station)
        }
        Json::object(m)
      }),
    ),
  }
}

///|
/// What is not chosen (quiet_line's, as nodes) in block `b`: a kind's heading, none found, the stations still
/// answering (or one that could not be searched, in red), what the core says; `first` the line it was made for, `line()`
/// it as it is now.
fn quiet_line_node(b : @view.View, first : FindLine, line : () -> (FindLine, Int)?, at : @sf.ListAt) -> Unit {
  let f = fn() { @sf.theme().chat_list.found }
  let words = fn() {
    match line() {
      Some((FindLine::Head(w) | FindLine::Note(w) | Wait(w, _) | Said(w), _)) => w
      _ => ""
    }
  }
  b.box(fn(q) {
    match first {
      Head(_) => {
        @sf.style_node(q, fn() { f().head.then(@sf.found_head_in(at)) })
        @sf.words_node(q, words, fn() { f().head_words }) |> ignore
      }
      Note(_) => {
        @sf.style_node(q, fn() { f().quiet.then(@sf.found_line_in(at)) })
        @sf.words_node(q, words, fn() { f().quiet_words }) |> ignore
      }
      Wait(_, false) => {
        @sf.style_node(q, fn() { f().wait.then(@sf.found_line_in(at)) })
        @sf.wait_line_node(q, words) |> ignore
      }
      Wait(_, true) => {
        @sf.style_node(q, fn() { f().wait_failing.then(@sf.found_line_in(at)) })
        @sf.words_node(q, words, fn() { f().quiet_words.then(@sf.bad) }) |> ignore
      }
      Said(_) => {
        @sf.style_node(q, fn() { f().wait.then(@sf.found_line_in(at)) })
        @sf.words_node(q, words, fn() { f().said_words }) |> ignore
      }
      _ => ()
    }
  })
  |> ignore
}

///|
/// A line of what was found (found_line's, as nodes) in block `b`, by the key `k()` it shows now, `first` the line it
/// was made for and `line()` it as it is now: its mark, then what it is, or the words found in it (they bold, stroked
/// under: @sf.found_words_node), with who, where and when at its first line's end, or under it where `stacked()`; where
/// it is under that (its chat; an item's line with the words) where it says one. A chat its agent's maker, a message
/// its chat's; a station its mark; something else its kind's icon; a command its icon, its keys at its end; 全部结果
/// and 查看更多 in the link's ink. Chosen (`lit(k())`, where the screen has keys: the pointer over it chooses it too),
/// on the words' tint; an option of `combo`'s: pressed, rippled and opened as finder_combobox_node opens it.
/// `several()`: more than one station, so where is said.
fn found_line_node(
  b : @view.View,
  combo : @sf.SearchCombo,
  first : FindLine,
  line : () -> (FindLine, Int)?,
  k : () -> String,
  lit : (String) -> Bool,
  several : @signals.Computed[Bool],
  at : @sf.ListAt,
  stacked : () -> Bool,
) -> Unit {
  let f = fn() { @sf.theme().chat_list.found }
  let keys = fn() { @sf.theme().chat_list.keys }
  let now = fn() {
    match line() {
      Some((l, _)) => l
      None => first
    }
  }
  // who, where and when (`meta`), said at the end of its words
  let parts = @signals.computed(fn(_) {
    let all : Array[String] = match now() {
      Chat(ch) =>
        [
          if ch.archived { @sf.t("web-main.switcher.archived") } else { "" },
          if ch.item.hidden == Some(true) { @sf.t("web-main.filter.hidden") } else { "" },
          if several.get() { ch.item.station_name } else { "" },
          ch.item.ago,
        ]
      Message(m) => [m.by, m.ago]
      Item(it) => [if it.kind != "station" && several.get() { it.station_name } else { "" }, it.ago]
      Command(_, o) => [o.keys]
      _ => []
    }
    all.filter(fn(p) { p != "" })
  })
  // (where the line is narrow, who, where and when under its words, its first line all theirs)
  let under_meta = fn() { stacked() && parts.get().length() > 0 }
  let has_under = fn() {
    match now() {
      Message(_) => true
      Item(it) => it.text != ""
      Chat(ch) => ch.found is Some(_)
      _ => false
    }
  }
  let two = @signals.computed(fn(_) { under_meta() || has_under() })
  let label = fn() {
    match now() {
      Back => @sf.t("web-main.switcher.back")
      More(_) => @sf.t("web-main.switcher.more")
      Command(l, _) => l.label
      Chat(ch) => ch.item.title
      Message(m) => m.text
      Item(it) => it.title
      _ => ""
    }
  }
  b.box(fn(row) {
    // (in from its list's sides as found_row_in has it; in a side column round as a row of it is, @sf.row_corner)
    @sf.style_node(row, fn() {
      (if two.get() { f().two } else { f().row }).then(match at {
        Whole => @sf.found_row_in(Whole)
        Side | Tape => found_side_in_node
      })
    })
    if !(at is Whole) {
      row.radius(Is(@sf.row_corner)) |> ignore
    }
    // (chosen by the keys: on the words' tint)
    row.ground(By(fn() { if keys() && lit(k()) { @ui.tree_theme().color(Tint) } else { 0L } })) |> ignore
    // (an option of the search's combobox: pressed, chosen and opened, finder_combobox_node; its key the line's now,
    // the block taken for another: View::scrolls_reused)
    @sf.ripple_option_node(row, combo, k, label, @sf.row_corner)
    // (the pointer moving onto it chooses it, as the keys do)
    row.on_pointer_moved(fn() {
      if @signals.untracked(keys) {
        match @signals.untracked(line) {
          Some((_, pick)) if pick >= 0 => finder.chosen.set(pick)
          _ => ()
        }
      }
    })
    |> ignore
    // its mark: as high as its first line, on its middle however large its words, in a line of two (found_mark_h)
    row.box(fn(m) {
      @sf.style_node(
        m,
        fn() {
          let h = if two.get() { @sf.found_mark_h(f(), m.words_scale()) } else { 0.0 }
          if h > 0.0 {
            f().mark.then(@ui.style(min_h=Fixed(h)))
          } else {
            f().mark
          }
        },
        in_row=true,
      )
      let icon = fn(name : () -> String) {
        @sf.icon_node(m, "", @sf.theme().chat_list.found.icon, By(fn() { @sf.theme().p.muted }), name_now=name) |> ignore
      }
      // a chat's picture: its first agent's maker's mark, as the line now says it (the agent changed while it shows)
      let picture = fn() {
        let made = fn() {
          let item = match now() {
            Chat(ch) => Some(ch.item)
            Message(msg) => Some(msg.chat)
            _ => None
          }
          match item {
            Some(i) => i.agents.get(0).map(fn(a) { (a.maker, a.runtime) })
            None => None
          }
        }
        m.pick(at_once=true, made, fn(p, mk) {
          match mk {
            Some((maker, runtime)) => @sf.maker_mark_node(p, maker, runtime, @sf.theme().chat_list.found.logo) |> ignore
            None => @sf.icon_node(p, "chat", @sf.theme().chat_list.found.icon, By(fn() { @sf.theme().p.muted })) |> ignore
          }
        })
      }
      match first {
        Back => icon(fn() { "chevron-left" })
        More(_) => icon(fn() { "more" })
        // (its icon as the line now says it: the block taken for another command)
        Command(_, o) =>
          icon(fn() {
            match now() {
              Command(_, now) => now.icon
              _ => o.icon
            }
          })
        Chat(_) | Message(_) => picture()
        Item(it) =>
          if it.kind == "station" {
            if @sf.has_station_mark(it.station_emoji, it.station_icon) {
              // (its emoji and icon as the line now says them)
              let station = fn() {
                match now() {
                  Item(i) => i
                  _ => it
                }
              }
              @sf.station_mark_node(m, fn() { station().station_emoji }, fn() { station().station_icon }, @sf.theme().chat_list.found.icon, fn() {
                @sf.theme().p.muted
              }, fn() { 0 })
            } else {
              icon(fn() { "server" })
            }
          } else {
            // (its kind's icon as the line now says it: the block taken for another item)
            icon(fn() {
              let it = match now() {
                Item(i) => i
                _ => it
              }
              if it.kind == "file" && it.dir {
                "folder"
              } else {
                @sf.kind_icon(it.kind)
              }
            })
          }
        _ => ()
      }
    })
    |> ignore
    // its words: the first line, and under it where there is one; who, where and when at the first line's end where
    // the line is wide enough to leave the words theirs, else at the end of the line under it
    row.box(fn(col) {
      @sf.style_node(col, fn() { f().column }, in_row=true)
      col.min_width(Is(Some(0.0))) |> ignore
      let said = fn(p : @view.View) {
        // (who and where leave the line before its words are cut to fewer than four of their size; when stays)
        p.box(fn(s) {
          // (as wide as they are; beside where it is as far apart as what its line holds, at the first line's end one
          // line of words, a space after each `·`, as the old view said them joined: @sf.join_meta)
          @sf.style_node(s, fn() { f().second.then(if under_meta() { said_hug } else { said_joined }) }, in_row=true)
          s.fits(Is(true)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
          s.each(fn() { Array::makei(parts.get().length(), fn(i) { i }) }, fn(i) { i }, at_once=true, fn(e, i) {
            let i = i.untracked()
            let words = fn() {
              let ps = parts.get()
              match ps.get(i) {
                Some(w) =>
                  if i + 1 >= ps.length() {
                    w
                  } else if under_meta() {
                    w + " ·"
                  } else {
                    w + " · "
                  }
                None => ""
              }
            }
            e.drops(By(fn() { if i + 1 < parts.get().length() { 1 } else { 0 } })) |> ignore
            @sf.words_node(e, words, fn() { f().meta }) |> ignore
          })
        })
        |> ignore
      }
      col.box(fn(top) {
        @sf.style_node(top, fn() { f().first })
        top.min_width(Is(Some(0.0))) |> ignore
        match first {
          Back | More(_) =>
            @sf.words_node(top, label, fn() { f().link }) |> ignore
          Command(_, _) =>
            name_words_node(top, label, fn() { f().title })
          Chat(_) => {
            // (what it says of the chat follows the words typed: found in its words, or its name alone)
            let found = fn() {
              match now() {
                Chat({ found: Some(_), .. }) => true
                _ => false
              }
            }
            top.show(at_once=true, found, fn(fw) {
              fw.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
              @sf.found_words_node(
                fw,
                fn() {
                  match now() {
                    Chat({ found: Some(w), .. }) => w
                    _ => ""
                  }
                },
                fn() {
                  match now() {
                    Chat(c) => c.marks
                    _ => []
                  }
                },
                fn() { f().words },
                fn() { @sf.theme().p.text },
              )
              |> ignore
            })
            top.show(at_once=true, fn() { !found() }, fn(nw) {
              nw.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
              name_words_node(nw, label, fn() { f().title })
            })
          }
          Message(_) =>
            @sf.found_words_node(top, label, fn() {
              match now() {
                Message(msg) => msg.marks
                _ => []
              }
            }, fn() { f().words }, fn() { @sf.theme().p.text })
            |> ignore
          Item(_) => name_words_node(top, label, fn() { f().title })
          _ => ()
        }
        top.show(at_once=true, fn() { !under_meta() && parts.get().length() > 0 }, said)
      })
      |> ignore
      col.show(at_once=true, fn() { two.get() }, fn(second) {
        @sf.style_node(second, fn() { f().second })
        second.min_width(Is(Some(0.0))) |> ignore
        let under = fn() {
          match now() {
            Chat(ch) if ch.found is Some(_) => ch.item.title
            Message(msg) => msg.chat.title
            _ => ""
          }
        }
        match first {
          Chat(_) | Message(_) =>
            second.show(at_once=true, fn() { under() != "" }, fn(n) {
              n.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
              name_words_node(n, under, fn() { f().under })
            })
          Item(_) =>
            second.show(at_once=true, fn() {
              match now() {
                Item(it) => it.text != ""
                _ => false
              }
            }, fn(n) {
              n.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
              @sf.found_words_node(
                n,
                fn() {
                  match now() {
                    Item(it) => it.text
                    _ => ""
                  }
                },
                fn() {
                  match now() {
                    Item(it) => it.marks
                    _ => []
                  }
                },
                fn() { f().under_words },
                fn() { @sf.theme().p.text },
              )
              |> ignore
            })
          _ => ()
        }
        second.show(at_once=true, fn() { under_meta() }, said)
      })
    })
    |> ignore
  })
  |> ignore
}

///|
/// A name (a chat's, a file's, a station's: name_words', as a node) in `parent`, taking what its line leaves the rest of
/// what is on it, cut short there.
fn name_words_node(parent : @view.View, words : () -> String, style : () -> @ui.TextStyle) -> Unit {
  parent.box(fn(n) {
    n.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    @sf.words_node(n, words, fn() { style().then(name_cut_node) }).min_width(Is(Some(0.0))) |> ignore
  })
  |> ignore
}

///|
// kept across runs: a value (no field of it changes)
let name_cut_node : @ui.TextStyle = @ui.text_style(wrap=false, w=Cut)

///|
/// Who, where and when on a line: as wide as they are.
// kept across runs: a value (no field of it changes)
let said_hug : @ui.Style = @ui.css("w=Hug")

///|
/// Who, where and when at a first line's end: as wide as they are, the words' own spaces between them.
// kept across runs: a value (no field of it changes)
let said_joined : @ui.Style = @ui.css("w=Hug gap=S0")

///|
/// A line of what is found in a side column (found_row_in's, as nodes: its corner the node's own, a row's).
// kept across runs: a value (no field of it changes)
let found_side_in_node : @ui.Style = @ui.css("px=S3")
