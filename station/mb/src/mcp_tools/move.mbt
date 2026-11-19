// station_move (station/src/tools/move.ts): the migration scheduler's face (move/AGENTS.md). A plan of what a move of
// this station's chats to another would be; one item moved or moved back, its needs first where asked; everything
// moved, confirmed once on a card by an owner or admin of the workspace in the app (`MoveAsks`); where each stands.
// What it asks (`move.*`): `here`, `wsOf`, `roster`, `cards.post`, `notify`, and where this station has them `ask`,
// `setWait`, `refusal`, `room`, `told.asked`, `told.run`; the scheduler `move.scheduler.*`. Its asks are kept in
// <data>/move/asks.json, written whole (`fs.*`, `crypto.randomBytes` for the temporary name).

///|
/// What of MoveAsksDeps a station gives (the rest always are).
pub(all) struct MoveHas {
  ask : Bool
  set_wait : Bool
  refusal : Bool
  room : Bool
  told : Bool
}

///|
/// An all-moving asked, waiting for its card's choice.
struct Ask {
  id : String
  session : String
  ws : String
  to : String
  to_name : String
  mut state : String
  mut thread : JV
  mut ts : JV
  mut by : JV
}

///|
fn Ask::to_jv(self : Ask) -> JV {
  jobj([
    ("id", js(self.id)),
    ("session", js(self.session)),
    ("ws", js(self.ws)),
    ("to", js(self.to)),
    ("toName", js(self.to_name)),
    ("state", js(self.state)),
    ("thread", self.thread),
    ("ts", self.ts),
    ("by", self.by),
  ])
}

///|
fn Ask::of_jv(v : JV) -> Ask {
  {
    id: js_string(v.get("id")),
    session: js_string(v.get("session")),
    ws: js_string(v.get("ws")),
    to: js_string(v.get("to")),
    to_name: js_string(v.get("toName")),
    state: js_string(v.get("state")),
    thread: v.get("thread").unwrap_or(Null),
    ts: v.get("ts").unwrap_or(Null),
    by: v.get("by").unwrap_or(Null),
  }
}

///|
pub struct MoveAsks {
  c : Ctx
  data : String
  has : MoveHas
  mut asks : Array[Ask]
  running : Array[@effect.Fiber[Unit]]
}

///|
/// The asks as they were kept (none where the file is not there or not read).
pub async fn MoveAsks::new(c : Ctx, data : String, has : MoveHas) -> MoveAsks {
  let path = path_join([data, "move", "asks.json"])
  let asks = match (try Some(c.b.ask("fs.readFileSync", [js(path), js("utf8")])) catch { _ => None }) {
    Some(Str(t)) =>
      match try_parse(t) {
        Some(Arr(items)) => items.map(Ask::of_jv)
        Some(Obj(_)) => []
        _ => []
      }
    _ => []
  }
  { c, data, has, asks, running: [] }
}

///|
/// Everything set going by a choice, done.
pub async fn MoveAsks::settle(self : MoveAsks) -> Unit {
  while self.running.length() > 0 {
    let f = self.running.remove(0)
    ignore(f.wait())
  }
}

///|
fn refusal_of(message : String) -> Refusal {
  Refusal(message)
}

///|
fn find_station(roster : Array[JV], s : String) -> JV? {
  match roster.iter().find_first(r => jstr(r.get("id")) == Some(s)) {
    Some(r) => return Some(r)
    None => ()
  }
  match roster.iter().find_first(r => lower(js_string(r.get("name"))) == lower(s)) {
    Some(r) => return Some(r)
    None => ()
  }
  roster
  .iter()
  .find_first(r => s.length() >= 8 && js_string(r.get("id")).has_prefix(s))
}

///|
async fn MoveAsks::roster(self : MoveAsks, ws : String) -> Array[JV] {
  jitems(Some(self.c.b.ask("move.roster", [js(ws)])))
}

///|
async fn MoveAsks::here(self : MoveAsks) -> JV {
  self.c.b.ask("move.here", [])
}

///|
async fn MoveAsks::station(self : MoveAsks, ws : String, v : JV?) -> (String, String) {
  let s = trimmed(v)
  if s == "" {
    raise refusal_of("to: name the other station (station_list lists them)")
  }
  let roster = self.roster(ws)
  guard find_station(roster, s) is Some(found) else {
    raise refusal_of(
      "no station \{s} in this chat's workspace: station_list lists them",
    )
  }
  let id = js_string(found.get("id"))
  if self.here() is Str(h) && h == id {
    raise refusal_of("that is this station: name another")
  }
  (id, js_string(found.get("name")))
}

///|
async fn random_hex(b : ToolsBackend, n : Int) -> String {
  let got = b.ask("crypto.randomBytes", [jint(n)])
  let bytes = @api_routes.bytes_of(got).unwrap_or(b"")
  let hex = "0123456789abcdef"
  let out = StringBuilder::new()
  for x in bytes {
    let v = x.to_int()
    out.write_char(hex.unsafe_charcode_at(v >> 4).unsafe_to_char())
    out.write_char(hex.unsafe_charcode_at(v & 15).unsafe_to_char())
  }
  out.to_string()
}

///|
/// station_move for a session here (move.ts `tool`).
pub async fn MoveAsks::tool(self : MoveAsks, session : String, args : JV) -> JV {
  let b = self.c.b
  let ws = match b.ask("move.wsOf", [js(session)]) {
    Str(w) => w
    _ => raise refusal_of("this chat is of no workspace here")
  }
  // (another station asked to do it, of its own items: as station_retire asked one)
  match args.get("station") {
    Some(Str(st)) if trim_js(st) != "" => {
      let roster = self.roster(ws)
      let s = trim_js(st)
      guard find_station(roster, s) is Some(at) else {
        raise refusal_of(
          "no station \{s} in this chat's workspace: station_list lists them",
        )
      }
      let at_id = js_string(at.get("id"))
      let here = self.here()
      if !(here is Str(h) && h == at_id) {
        if is_true(args.get("all")) {
          raise refusal_of(
            "moving all of station \{js_string(at.get("name"))} is confirmed on a card in a chat on that station: ask from one there (chat_create opens one)",
          )
        }
        if !self.has.ask {
          raise refusal_of("other stations cannot be asked from here")
        }
        let rest = without(args, "station")
        let action = args.get("action")
        if self.has.told &&
          (action is Some(Str("move")) || action is Some(Str("back"))) {
          let key = "tool:\{js_string(action)}:\{random_hex(b, 6)}"
          return b.ask("move.told.asked", [
            js(at_id),
            js(key),
            jobj([
              ("method", js("move.tool")),
              ("workspace", js(ws)),
              ("args", rest),
              ("told", js(key)),
            ]),
          ])
        }
        return b.ask("move.ask", [
          js(at_id),
          jobj([("method", js("move.tool")), ("workspace", js(ws)), ("args", rest)]),
        ])
      }
    }
    _ => ()
  }
  self.tool_in(ws, Some(session), args)
}

///|
/// station_move asked by another station (`move.tool`, `workspace` its chat's).
pub async fn MoveAsks::answer(
  self : MoveAsks,
  peer : String,
  workspace : String,
  request : JV,
) -> JV {
  let args = match jget(Some(request), "args") {
    None | Some(Null) => jobj([])
    Some(a) if is_undef(a) => jobj([])
    Some(a) => a
  }
  let key = match jget(Some(request), "told") {
    Some(Str(k)) if k.length() <= 300 => Some(k)
    _ => None
  }
  match key {
    Some(k) if self.has.told => {
      self.c.b.tell("move.told.run", [js(peer), js(k)])
      self.tool_in(workspace, None, args)
    }
    _ => self.tool_in(workspace, None, args)
  }
}

///|
/// The tool's work for workspace `ws` (`session`: the chat asking here; None: asked by another station).
pub async fn MoveAsks::tool_in(
  self : MoveAsks,
  ws : String,
  session : String?,
  args : JV,
) -> JV {
  let b = self.c.b
  if self.has.set_wait {
    b.tell("move.setWait", [jbool(!is_false(args.get("wait")))])
  }
  let module = jstr(args.get("module"))
  let item = jstr(args.get("item"))
  let sel = [
    ("module", jundef_or(module)),
    ("item", jundef_or(item)),
    ("withNeeds", jbool(is_true(args.get("withNeeds")))),
    ("all", jbool(is_true(args.get("all")))),
    ("arriveStopped", jbool(is_true(args.get("arriveStopped")))),
  ]
  let jsession = match session {
    Some(s) => js(s)
    None => Null
  }
  let follow = if module == Some("chats") { jstrs(["jobs"]) } else { jundef }
  match jstr(args.get("action")) {
    Some("plan") | Some("status") => {
      let status = args.get("action") is Some(Str("status"))
      let to = if absent(args.get("to")) && status {
        None
      } else {
        Some(self.station(ws, args.get("to")))
      }
      let to_id = match to {
        Some((id, _)) => id
        None => ""
      }
      let plan = b.ask("move.scheduler.planShown", [js(ws), js(to_id)])
      // (one item, a module's a page at a time, or the summary: never every item, whatever the station's size)
      match item {
        Some(i) => {
          let x = jitems(plan.get("items")).iter().find_first(x => jstr(x.get("id")) ==
              Some(i) &&
            (module is None || jstr(x.get("module")) == module))
          guard x is Some(x) else {
            let of = match module {
              Some(m) if m != "" => " of \{m}"
              _ => ""
            }
            raise refusal_of(
              "no item \{i}\{of} in the plan: plan with module lists them",
            )
          }
          return jobj([("item", brief(x))])
        }
        None => ()
      }
      match module {
        Some(m) =>
          return page_of(
            plan,
            m,
            jstr(args.get("after")),
            match args.get("limit") {
              Some(Num(n)) => n
              _ => page.to_double()
            },
          )
        None => ()
      }
      // (the bytes of the chats that would go, as far as they are measured, and the free bytes there)
      let going = jitems(plan.get("items"))
        .filter(x => x.get("module") is Some(Str("chats")) &&
          !(x.get("state") is Some(Str("there"))))
        .map(x => field(x, "id"))
      let room = if self.has.room {
        match (try Some(b.ask("move.room", [js(ws), js(to_id), jarr(going)])) catch { _ => None }) {
          Some(Null) | None => None
          Some(r) if is_undef(r) => None
          Some(r) => Some(r)
        }
      } else {
        None
      }
      let stopped = b.ask("move.scheduler.stopped", [])
      let summary = summary_of(plan, stopped)
      let summary = match room {
        Some(r) => spread(summary, [("room", r)])
        None => summary
      }
      let to_name = match to {
        Some((_, n)) => n
        None => ""
      }
      let words = plan_words(plan, to_name, status)
      let say = match room {
        Some(r) => "\{words} \{room_words(r)}"
        None => words
      }
      jobj([("summary", summary), ("say", js(say))])
    }
    Some("move") => {
      let (to_id, to_name) = self.station(ws, args.get("to"))
      if self.has.refusal {
        match b.ask("move.refusal", [js(ws), js(to_id)]) {
          Str(why) if why != "" => raise refusal_of(why)
          _ => ()
        }
      }
      if is_true(args.get("all")) {
        guard session is Some(session) else {
          raise refusal_of(
            "moving all of a station is confirmed on a card in a chat on it",
          )
        }
        return self.ask_all(session, ws, to_id, to_name)
      }
      if module is None || item is None {
        raise refusal_of(
          "move: name the module and the item (station_move plan lists them), or all",
        )
      }
      let out = b.ask("move.scheduler.move", [
        js(ws),
        js(to_id),
        jobj([..sel, ("follow", follow)]),
        jsession,
      ])
      jobj([
        ("outcome", outcome_of(out)),
        ("say", js(outcome_words(out, "moved to", to_name))),
      ])
    }
    Some("back") => {
      let (from_id, from_name) = self.station(ws, args.get("to"))
      if module is None || (item is None && !is_true(args.get("all"))) {
        raise refusal_of(
          "back: name the module and the item (station_move status lists them), and to: the station it is on",
        )
      }
      if self.has.refusal {
        match b.ask("move.refusal", [js(ws), js(from_id)]) {
          Str(why) if why != "" => raise refusal_of(why)
          _ => ()
        }
      }
      let out = b.ask("move.scheduler.back", [
        js(ws),
        js(from_id),
        jobj([..sel, ("follow", follow)]),
        jsession,
      ])
      jobj([
        ("outcome", outcome_of(out)),
        ("say", js(outcome_words(out, "back here from", from_name))),
      ])
    }
    Some("stop") => {
      if !truthy(Some(b.ask("move.scheduler.stopTurn", [jsession]))) {
        raise refusal_of(
          self.c.tr(self.c.consts.station_lang, "station.move.notRunning"),
        )
      }
      jobj([
        ("stopping", jbool(true)),
        (
          "say",
          js(
            "The move under way stops: nothing further of it starts; a chat not yet gone goes on here, one already gone completes there. Its outcome is told as it ends.",
          ),
        ),
      ])
    }
    _ => raise refusal_of("action is one of plan, move, back, status, stop")
  }
}

///|
async fn MoveAsks::ask_all(
  self : MoveAsks,
  session : String,
  ws : String,
  to_id : String,
  to_name : String,
) -> JV {
  let b = self.c.b
  let plan = b.ask("move.scheduler.plan", [js(ws), js(to_id)])
  let lang = self.c.consts.station_lang
  let a : Ask = {
    id: "m_\{random_hex(b, 6)}",
    session,
    ws,
    to: to_id,
    to_name,
    state: "asked",
    thread: Null,
    ts: Null,
    by: Null,
  }
  let confirm = self.c.tr(lang, "station.move.card.confirm")
  let card = jobj([
    ("type", js("options")),
    (
      "options",
      jarr([
        jobj([
          ("label", js(confirm)),
          ("detail", js(self.c.tr(lang, "station.move.card.confirmDetail"))),
          ("action", js("close")),
          ("recommended", jbool(true)),
        ]),
        jobj([
          ("label", js(self.c.tr(lang, "station.move.card.decline"))),
          ("detail", js(self.c.tr(lang, "station.move.card.declineDetail"))),
          ("action", js("close")),
        ]),
      ]),
    ),
    (
      "move",
      jobj([("ask", js(a.id)), ("to", js(to_id)), ("toName", js(to_name))]),
    ),
  ])
  let n = jitems(plan.get("items"))
    .filter(x => !(x.get("state") is Some(Str("there"))))
    .length()
  let posted = b.ask("move.cards.post", [
    js(session),
    js(
      self.c.tr(lang, "station.move.card.title", args=[
        ("to", to_name),
        ("n", n.to_string()),
      ]),
    ),
    card,
  ])
  a.thread = match jget(Some(posted), "thread") {
    None | Some(Null) => Null
    Some(t) if is_undef(t) => Null
    Some(t) => t
  }
  a.ts = match jget(Some(posted), "ts") {
    None | Some(Null) => Null
    Some(t) if is_undef(t) => Null
    Some(t) => t
  }
  let kept = self.asks.filter(x => !(x.session == session && x.state == "asked"))
  kept.push(a)
  self.asks = if kept.length() > 20 {
    kept[kept.length() - 20:].to_array()
  } else {
    kept
  }
  self.save()
  jobj([
    ("ask", js(a.id)),
    ("card", js("posted")),
    (
      "say",
      js(
        "A card is in this chat: an owner or admin of the workspace confirms it (\{confirm}) in the still.fail app; nothing moves until then. You are told what came of it. The plan: \{plan_words(plan, to_name, false)}",
      ),
    ),
  ])
}

///|
fn MoveAsks::ask_at(self : MoveAsks, card : JV, at : JV) -> Ask? {
  let id = jget(jget(Some(card), "move"), "ask")
  match self.asks.iter().find_first(x => id is Some(Str(i)) && x.id == i) {
    Some(a) if a.thread == field(at, "thread") && a.ts == field(at, "ts") =>
      Some(a)
    _ => None
  }
}

///|
/// Whether `viewer` may choose on the card (None: they may), else why not.
pub fn MoveAsks::may(self : MoveAsks, viewer : JV, card : JV, at : JV) -> String? {
  let lang = self.c.consts.station_lang
  guard self.ask_at(card, at) is Some(a) else {
    return Some(self.c.tr(lang, "station.move.askGone"))
  }
  if !@api_routes.manages_station(viewer) ||
    !(jstr(viewer.get("workspace")) == Some(a.ws)) {
    return Some(self.c.tr(lang, "station.move.ownersOnly"))
  }
  None
}

///|
/// What was chosen on the card: declined, or everything moved.
pub async fn MoveAsks::chosen(
  self : MoveAsks,
  viewer : JV,
  card : JV,
  option : String,
  at : JV,
) -> Unit {
  let b = self.c.b
  guard self.ask_at(card, at) is Some(a) && a.state == "asked" else { return }
  let email = js_string(viewer.get("email"))
  a.by = field(viewer, "email")
  let chose = trim_js(option)
  if chose != self.c.tr(self.c.consts.station_lang, "station.move.card.confirm") {
    a.state = "declined"
    // (kept before the chat is told: its file's write waits on the shell's thread, so a fiber of its own would be told
    // after it)
    self.save() catch {
      _ => ()
    }
    b.tell("move.notify", [
      js(a.session),
      js("\{email} chose \{chose} on the card: nothing was moved."),
    ])
    return
  }
  a.state = "confirmed"
  // (kept before anything moves or the chat is told, as the decline is)
  self.save() catch {
    _ => ()
  }
  let move_ = async fn() {
    let out = b.ask("move.scheduler.move", [
      js(a.ws),
      js(a.to),
      jobj([("all", jbool(true)), ("follow", jstrs(["jobs"]))]),
      js(email),
    ]) catch {
      e => {
        b.tell("move.notify", [
          js(a.session),
          js(
            "\{email} confirmed moving everything to \{a.to_name}, but it did not begin: \{message_of(e)}",
          ),
        ])
        return
      }
    }
    b.tell("move.notify", [
      js(a.session),
      js(
        "\{email} confirmed moving everything to \{a.to_name}. \{outcome_words(out, "moved to", a.to_name)}",
      ),
    ])
  }
  self.running.push(
    @effect.runtime().fork(name="move all", async fn() {
      move_() catch {
        _ => ()
      }
    }),
  )
}

///|
async fn MoveAsks::save(self : MoveAsks) -> Unit {
  let b = self.c.b
  let path = path_join([self.data, "move", "asks.json"])
  b.tell("fs.mkdir", [js(path_dirname(path)), jobj([("recursive", jbool(true))])])
  let tmp = "\{path}.\{random_hex(b, 4)}.tmp"
  b.tell("fs.writeFile", [js(tmp), js(stringify(jarr(self.asks.map(a => a.to_jv()))))])
  b.tell("fs.rename", [js(tmp), js(path)])
}

///|
/// The items of a page the tool answers (module, after, limit), and the most a page asks.
pub let page : Int = 50

///|
pub let page_most : Int = 200

///|
/// The most examples a group of the summary names, the most groups it lists, and how long a label it says.
pub let examples : Int = 3

///|
pub let groups : Int = 20

///|
let label_most : Int = 80

///|
fn short(s : String) -> String {
  if s.length() > label_most {
    slice(s, 0, to=label_most - 1) + "…"
  } else {
    s
  }
}

///|
/// An item as the scheduler names it in what it says (move/module.ts `named`).
fn named_need(n : JV) -> String {
  "\{js_string(n.get("module"))} \{js_string(n.get("id"))}"
}

///|
/// An item as the tool answers it: a line's worth.
fn brief(x : JV) -> JV {
  let out = [
    ("module", field(x, "module")),
    ("item", field(x, "id")),
    ("label", field(x, "label")),
    ("state", field(x, "state")),
  ]
  let needs = jitems(x.get("needs"))
  if needs.length() > 0 {
    out.push(("needs", jstrs(needs.map(named_need))))
  }
  if !absent(x.get("cannot")) {
    out.push(("cannot", field(x, "cannot")))
  }
  if !absent(x.get("leaves")) {
    out.push(("leaves", field(x, "leaves")))
  }
  if truthy(x.get("error")) {
    out.push(("error", field(x, "error")))
  }
  if truthy(x.get("waitsFor")) {
    out.push(("waitsFor", js(named_need(field(x, "waitsFor")))))
  }
  let stops = jitems(x.get("wouldStop"))
  if stops.length() > 0 {
    out.push(("wouldStop", jstrs(stops.map(named_need))))
  }
  if truthy(x.get("progress")) {
    out.push(("progress", field(x, "progress")))
  }
  jobj(out)
}

///|
/// A module's items a page at a time, in the plan's order.
fn page_of(plan : JV, module : String, after : String?, limit : Double) -> JV raise Refusal {
  let mine = jitems(plan.get("items")).filter(x => jstr(x.get("module")) == Some(module))
  let modules = jitems(plan.get("modules"))
  if mine.length() == 0 &&
    !modules.iter().any(m => jstr(m.get("id")) == Some(module)) {
    raise refusal_of(
      "no module \{module}: one of \{modules.map(m => js_string(m.get("id"))).join(", ")}",
    )
  }
  let from = match after {
    None => 0
    Some(a) => {
      let mut i = -1
      for k, x in mine {
        if jstr(x.get("id")) == Some(a) {
          i = k
          break
        }
      }
      i + 1
    }
  }
  let n = {
    let f = limit.floor()
    let f = if f.is_nan() || f == 0.0 { page.to_double() } else { f }
    let f = if f > page_most.to_double() { page_most.to_double() } else { f }
    if f < 1.0 {
      1
    } else {
      f.to_int()
    }
  }
  let end = if from + n < mine.length() { from + n } else { mine.length() }
  let shown = if from < end { mine[from:end].to_array() } else { [] }
  let more = if from + n < mine.length() {
    match shown.last() {
      Some(x) =>
        match x.get("id") {
          None => @api_routes.JV::Null
          Some(id) => id
        }
      None => Null
    }
  } else {
    Null
  }
  jobj([
    ("module", js(module)),
    ("total", jint(mine.length())),
    ("items", jarr(shown.map(brief))),
    ("more", more),
  ])
}

///|
/// Items grouped by what is said of them, each group counted, a few named; and how many groups were left out.
fn grouped(
  xs : Array[JV],
  key : (JV) -> String,
  example : (JV) -> String,
) -> (Array[(String, Int, Array[String])], Int) {
  let order : Array[String] = []
  let by : Map[String, (String, Ref[Int], Array[String])] = Map::new()
  for x in xs {
    let k = key(x)
    let g = match by.get(k) {
      Some(g) => g
      None => {
        let g = (short(k), Ref::new(0), [])
        by[k] = g
        order.push(k)
        g
      }
    }
    g.1.val += 1
    if g.2.length() < examples {
      g.2.push(short(example(x)))
    }
  }
  let all = order.map(k => {
    let g = by.get(k).unwrap()
    (g.0, g.1.val, g.2)
  })
  // (stable, by count, the most first)
  let sorted = stable_sorted(all, (a, b) => b.1 - a.1)
  let shown = if sorted.length() > groups {
    sorted[0:groups].to_array()
  } else {
    sorted
  }
  (shown, if sorted.length() > groups { sorted.length() - groups } else { 0 })
}

///|
fn groups_jv(g : (Array[(String, Int, Array[String])], Int)) -> JV {
  jarr(
    g.0.map(x => jobj([
      ("why", js(x.0)),
      ("count", jint(x.1)),
      ("examples", jstrs(x.2)),
    ])),
  )
}

///|
/// What the tool answers of a plan by default (move.ts `summaryOf`): bounded whatever the station's size.
pub fn summary_of(plan : JV, stopped : JV) -> JV {
  let names : Array[String] = []
  let counts : Map[String, Array[(String, Int)]] = Map::new()
  let fresh = () => [
    ("here", 0),
    ("there", 0),
    ("moving", 0),
    ("stopped", 0),
    ("failed", 0),
    ("cannot", 0),
  ]
  for m in jitems(plan.get("modules")) {
    let id = js_string(m.get("id"))
    if !counts.contains(id) {
      names.push(id)
    }
    counts[id] = fresh()
  }
  let bump = (c : Array[(String, Int)], k : String) => {
    for i, p in c {
      if p.0 == k {
        c[i] = (k, p.1 + 1)
        return
      }
    }
    c.push((k, 1))
  }
  let items = jitems(plan.get("items"))
  for x in items {
    let module = js_string(x.get("module"))
    let c = match counts.get(module) {
      Some(c) => c
      None => {
        let c = fresh()
        counts[module] = c
        names.push(module)
        c
      }
    }
    bump(c, js_string(x.get("state")))
    if !absent(x.get("cannot")) && !(x.get("state") is Some(Str("there"))) {
      bump(c, "cannot")
    }
  }
  let modules = jobj(
    names.map(n => (n, jobj(counts.get(n).unwrap().map(p => (p.0, jint(p.1)))))),
  )
  let left = items.filter(x => !(x.get("state") is Some(Str("there"))))
  let cannot = grouped(
    left.filter(x => !absent(x.get("cannot"))),
    x => "\{js_string(x.get("module"))}: \{js_string(x.get("cannot"))}",
    x => js_string(x.get("label")),
  )
  let would_stop = grouped(
    left.filter(x => jitems(x.get("wouldStop")).length() > 0),
    x => "moving \{named_need(x)} alone stops \{jitems(x.get("wouldStop")).length()} here",
    x => {
      let w = jitems(x.get("wouldStop"))
      (if w.length() > examples { w[0:examples].to_array() } else { w })
      .map(named_need)
      .join(", ")
    },
  )
  let lent = grouped(
    items.filter(x => !absent(x.get("lentTo"))),
    x => "\{js_string(x.get("module"))} lent to \{js_string(x.get("lentTo"))}",
    x => js_string(x.get("label")),
  )
  let stopped_groups = grouped(
    jitems(Some(stopped)),
    s => "waits for \{named_need(field(s, "waitsFor"))}",
    s => named_need(field(s, "item")),
  )
  jobj([
    ("items", jint(items.length())),
    ("modules", modules),
    ("cannot", groups_jv(cannot)),
    ("wouldStop", groups_jv(would_stop)),
    ("lent", groups_jv(lent)),
    ("stopped", groups_jv(stopped_groups)),
  ])
}

///|
/// What the tool says of a plan in words (move.ts `planWords`).
pub fn plan_words(plan : JV, to : String, status : Bool) -> String {
  let items = jitems(plan.get("items"))
  let by = (s : String) => items.filter(x => jstr(x.get("state")) == Some(s)).length()
  let parts = [
    "\{items.length()} items\{if to != "" { " for \{to}" } else { "" }}: \{by("here")} here, \{by("there")} there, \{by("moving")} moving, \{by("stopped")} stopped, \{by("failed")} failed.",
  ]
  let left = items.filter(x => !(x.get("state") is Some(Str("there"))))
  let (cannot, more) = grouped(
    left.filter(x => !absent(x.get("cannot"))),
    x => "\{js_string(x.get("module"))}: \{js_string(x.get("cannot"))}",
    x => js_string(x.get("label")),
  )
  if !status && cannot.length() > 0 {
    let said = cannot
      .map(g => "\{g.1} (e.g. \{g.2.join(", ")}): \{g.0}")
      .join("; ")
    let and_ = if more > 0 { "; and \{more} other reasons" } else { "" }
    parts.push("Cannot move: \{said}\{and_}.")
  }
  let stops = left.filter(x => jitems(x.get("wouldStop")).length() > 0)
  if !status && stops.length() > 0 {
    let eg = (if stops.length() > examples {
        stops[0:examples].to_array()
      } else {
        stops
      })
      .map(x => "\{named_need(x)} stops \{jitems(x.get("wouldStop")).length()}")
      .join(", ")
    parts.push(
      "\{stops.length()} items would stop what needs them here if moved alone (e.g. \{eg}): move them with what needs them, or all.",
    )
  }
  if items.length() > 0 {
    parts.push("plan with module (and after, limit) lists a module's items; with item, one.")
  }
  parts.join(" ")
}

///|
fn first_page(xs : Array[JV]) -> JV {
  jarr(if xs.length() > page { xs[0:page].to_array() } else { xs })
}

///|
/// A turn's outcome as the tool answers it: each list's first page and how many it has (move.ts `outcomeOf`).
pub fn outcome_of(out : JV) -> JV {
  let list = (k : String) => match out.get(k) {
    None | Some(Null) => []
    Some(v) if is_undef(v) => []
    v => jitems(v)
  }
  let lists = [
    ("done", list("done")),
    (
      "refused",
      list("refused").map(r => jobj([
        ("item", field(r, "item")),
        ("why", js(short(js_string(r.get("why"))))),
      ])),
    ),
    ("stopped", list("stopped")),
    ("resumed", list("resumed")),
    (
      "failures",
      list("failures").map(f => jobj([
        ("item", field(f, "item")),
        ("error", js(short(js_string(f.get("error"))))),
      ])),
    ),
    ("returned", list("returned")),
    ("lent", list("lent")),
  ]
  let fields = lists.map(p => (p.0, first_page(p.1)))
  let failed = match out.get("failed") {
    Some(Null) => @api_routes.JV::Null
    Some(f) if !is_undef(f) =>
      jobj([
        ("item", field(f, "item")),
        ("error", js(short(js_string(f.get("error"))))),
      ])
    _ => jobj([("item", jundef), ("error", js(short("undefined")))])
  }
  fields.push(("failed", failed))
  fields.push(("counts", jobj(lists.map(p => (p.0, jint(p.1.length()))))))
  jobj(fields)
}

///|
/// What a move would send and what is free there, in words.
pub fn room_words(r : JV) -> String {
  let measuring = match r.get("measuring") {
    Some(Num(n)) => n
    _ => 0.0
  }
  let s = (k : String) => js_string(r.get(k))
  let known = if measuring > 0.0 {
    "\{s("known")} of \{s("of")} chats measured, \{s("measuring")} being measured"
  } else {
    "all \{s("of")} chats measured"
  }
  let there = if r.get("freeThere") is Some(Str(_)) {
    " \{s("freeThere")} free there, \{s("floorThere")} of it kept free; what is in place there already is not sent again, so a whole move asks it first what it has of each room."
  } else {
    ""
  }
  "Their files: \{s("sends")} (\{known}).\{there}"
}

///|
/// A list said in words: a few of it, and how many more.
fn some(
  xs : Array[JV],
  said : (JV) -> String,
  sep? : String = ", ",
  most? : Int = groups,
) -> String {
  let shown = if xs.length() > most { xs[0:most].to_array() } else { xs }
  let more = if xs.length() > most {
    "\{sep}and \{xs.length() - most} more"
  } else {
    ""
  }
  shown.map(said).join(sep) + more
}

///|
/// A turn's outcome in words (move.ts `outcomeWords`).
pub fn outcome_words(out : JV, how : String, station : String) -> String {
  let list = (k : String) => match out.get(k) {
    None | Some(Null) => []
    Some(v) if is_undef(v) => []
    v => jitems(v)
  }
  let parts = []
  let done = list("done")
  parts.push(
    if done.length() == 0 {
      "Nothing \{how} \{station}."
    } else {
      "\{upper(slice(how, 0, to=1))}\{slice(how, 1)} \{station} (\{done.length()}): \{some(done, named_need)}."
    },
  )
  let refused = list("refused")
  if refused.length() > 0 {
    let (g, _) = grouped(refused, r => js_string(r.get("why")), r => named_need(field(r, "item")))
    parts.push(
      "Not moved (\{refused.length()}): \{g.map(x => "\{x.1} (e.g. \{x.2.join(", ")}): \{x.0}").join("; ")}.",
    )
  }
  let stopped = list("stopped")
  if stopped.length() > 0 {
    parts.push(
      "Stopped here, waiting for what they need (\{stopped.length()}): \{some(stopped, s => "\{named_need(field(s, "item"))} (waits for \{named_need(field(s, "waitsFor"))})")}.",
    )
  }
  let resumed = list("resumed")
  if resumed.length() > 0 {
    parts.push("Going on here again (\{resumed.length()}): \{some(resumed, named_need)}.")
  }
  let returned = list("returned")
  if returned.length() > 0 {
    parts.push(
      "Brought back, as what they moved for did not go: \{some(returned, named_need)}.",
    )
  }
  let failures = match out.get("failures") {
    None | Some(Null) =>
      match out.get("failed") {
        Some(Null) => []
        Some(f) if !is_undef(f) => [f]
        _ => [jobj([])]
      }
    Some(v) if is_undef(v) =>
      match out.get("failed") {
        Some(Null) => []
        Some(f) if !is_undef(f) => [f]
        _ => [jobj([])]
      }
    v => jitems(v)
  }
  if failures.length() > 0 {
    parts.push(
      "Failed (\{failures.length()}): \{some(failures, f => "\{named_need(field(f, "item"))}: \{short(js_string(f.get("error")))}", sep="; ")}. Everything else of the turn went on; what needs a failed item was not started (said above). Ask again for those once the cause is fixed.",
    )
  }
  parts.join(" ")
}

///|
/// The tool, on the asks.
pub fn move_tools(asks : MoveAsks) -> Array[Tool] {
  [
    Tool::new(asks.c.decl("station_move"), (session, args, _) => pretty(
      asks.tool(session, args),
    )),
  ]
}
