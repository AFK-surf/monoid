// What the app shows of a migration (station/src/move/routes.ts; move/AGENTS.md): `GET /move?to=<station>` answers,
// for the asker's workspace and that station, the modules in order with their needs, each module's done of total, how
// many of its items here cannot move and a page of its items; `last`: the workspace's last turn. `POST /move`,
// `POST /move/back` and `POST /move/stop` are the people's way to what station_move does, answered 202 at once.

///|
pub let move_page : Int = 50

///|
pub let move_page_most : Int = 200

///|
/// GET /move's answer for `plan` (routes.ts `moveView`): `module`/`after` the page of one module that goes on from
/// `after`; `name`: what the roster calls a station.
pub async fn move_view(
  plan : J,
  order : Array[String],
  stopped : Array[(Need, Waits)],
  module? : String,
  after? : String,
  limit? : Int = move_page,
  last? : J,
  stopping? : Bool = false,
  name? : (String) -> String = id => slice_to(id, 12),
  current? : Need,
  held? : (Scheduler, Held),
) -> J {
  let limit = if limit < 1 { 1 } else if limit > move_page_most { move_page_most } else { limit }
  let asked : Array[(J, J)] = []
  let now = async fn(x : J) -> J {
    match asked.search_by(p => physical_equal(p.0, x)) {
      Some(i) => asked[i].1
      None => {
        let (s, _) = held.unwrap()
        let n = s.now_of(x)
        asked.push((x, n))
        n
      }
    }
  }
  let held_at = fn(n : Need) -> J? {
    match held {
      Some((_, h)) =>
        match h.at.get(n.named()) {
          Some(i) => h.by_module.get(n.module).map(l => l[i])
          None => None
        }
      None => None
    }
  }
  let items = arr(get(Some(plan), "items")).unwrap_or([])
  let moving = match held {
    Some(_) =>
      match current {
        None => None
        Some(c) =>
          match held_at(c) {
            Some(x) => Some(now(x))
            None => None
          }
      }
    None =>
      match items.search_by(x => state_name(x) == "moving") {
        Some(i) => Some(items[i])
        None =>
          match current {
            None => None
            Some(c) =>
              match items.search_by(x => item_module(x) == c.module && item_id(x) == c.id) {
                Some(i) => Some(items[i])
                None => None
              }
          }
      }
  }
  let of : Map[String, Array[J]] = {}
  for id in order {
    of[id] = match held {
      Some((_, h)) => h.by_module.get(id).unwrap_or([])
      None => []
    }
  }
  if held is None {
    for x in items {
      match of.get(item_module(x)) {
        Some(l) => l.push(x)
        None => ()
      }
    }
  }
  let needs_of : Map[String, J] = {}
  for m in arr(get(Some(plan), "modules")).unwrap_or([]) {
    needs_of[text(get(Some(m), "id")).unwrap_or("")] = get(Some(m), "needs").unwrap_or(ja([]))
  }
  let named_j = (n : J) => js(need_of(n).named())
  let modules = []
  for id in order {
    let mine = of[id]
    let from = if module == Some(id) && after is Some(a) {
      (match held {
        Some((_, h)) => h.at.get("\{id} \{a}").unwrap_or(-1)
        None =>
          match mine.search_by(x => item_id(x) == a) {
            Some(i) => i
            None => -1
          }
      }) +
      1
    } else {
      0
    }
    let end = if from + limit > mine.length() { mine.length() } else { from + limit }
    let slice_ = if from < end { mine[from:end].to_array() } else { [] }
    let page = match held {
      Some(_) => {
        let out = []
        for x in slice_ {
          out.push(now(x))
        }
        out
      }
      None => slice_
    }
    let mut done = 0
    let mut cannot = 0
    match held {
      Some((_, h)) =>
        match h.counts.get(id) {
          Some((d, _, c)) => {
            done = d
            cannot = c
          }
          None => ()
        }
      None =>
        for x in mine {
          let s = state_name(x)
          if s == "there" {
            done += 1
          } else if s == "here" && item_cannot(x) is Some(_) {
            cannot += 1
          }
        }
    }
    let rows = page.map(x => {
      let pairs = [
        ("id", get(Some(x), "id").unwrap_or(Null)),
        ("label", get(Some(x), "label").unwrap_or(Null)),
        ("state", get(Some(x), "state").unwrap_or(Null)),
        ("needs", ja(arr(get(Some(x), "needs")).unwrap_or([]).map(named_j))),
      ]
      let waits_for = get(Some(x), "waitsFor")
      match waits_for {
        Some(Obj(_) as w) => pairs.push(("waitsFor", named_j(w)))
        _ => ()
      }
      match text(get(Some(x), "at")) {
        Some(a) => pairs.push(("at", js(name(a))))
        None => ()
      }
      match text(get(waits_for, "at")) {
        Some(a) => pairs.push(("waitsAt", js(name(a))))
        None =>
          match (text(get(Some(x), "waits")), text(get(Some(x), "from"))) {
            (Some("station"), Some(f)) => pairs.push(("waitsAt", js(name(f))))
            _ => ()
          }
      }
      match get(Some(x), "cannot") {
        Some(c) => pairs.push(("cannot", c))
        None => ()
      }
      match get(Some(x), "leaves") {
        Some(c) => pairs.push(("leaves", c))
        None => ()
      }
      match get(Some(x), "error") {
        Some(Str(u)) if u.length() > 0 => pairs.push(("error", Str(u)))
        Some(Null) | Some(Bool(false)) | Some(Str(_)) | None => ()
        Some(Num(n)) if n == 0.0 || n != n => ()
        Some(e) => pairs.push(("error", e))
      }
      match get(Some(x), "progress") {
        None | Some(Null) | Some(Bool(false)) => ()
        Some(p) => pairs.push(("progress", p))
      }
      match text(get(Some(x), "lentTo")) {
        Some(l) => pairs.push(("lentTo", js(name(l))))
        None => ()
      }
      match get(Some(x), "waits") {
        Some(w) => pairs.push(("waits", w))
        None => ()
      }
      let would = arr(get(Some(x), "wouldStop")).unwrap_or([])
      if would.length() > 0 {
        pairs.push(("wouldStop", ja(would.map(named_j))))
      }
      jo(pairs)
    })
    let more = if from + limit < mine.length() {
      match page.last() {
        Some(p) => get(Some(p), "id").unwrap_or(Null)
        None => Null
      }
    } else {
      Null
    }
    modules.push(
      jo([
        ("id", js(id)),
        ("needs", needs_of.get(id).unwrap_or(ja([]))),
        ("done", ji(done)),
        ("total", ji(mine.length())),
        ("cannot", ji(cannot)),
        ("items", ja(rows)),
        ("more", more),
      ]),
    )
  }
  let moving_j = match moving {
    None => J::Null
    Some(m) => {
      let pairs = [
        ("module", get(Some(m), "module").unwrap_or(Null)),
        ("id", get(Some(m), "id").unwrap_or(Null)),
        ("label", get(Some(m), "label").unwrap_or(Null)),
        (
          "progress",
          match get(Some(m), "progress") {
            Some(p) => p
            None => Null
          },
        ),
      ]
      match get(Some(m), "waits") {
        Some(w) => pairs.push(("waits", w))
        None => ()
      }
      if stopping {
        pairs.push(("stopping", jb(true)))
      }
      jo(pairs)
    }
  }
  let last_j = match last {
    None => J::Null
    Some(l) => {
      let list = (k : String) => arr(get(Some(l), k)).unwrap_or([])
      let pairs = [
        ("at", get(Some(l), "at").unwrap_or(Null)),
        ("by", get(Some(l), "by").unwrap_or(Null)),
        ("how", get(Some(l), "how").unwrap_or(Null)),
        ("station", get(Some(l), "station").unwrap_or(Null)),
      ]
      match get(Some(l), "stoppedBy") {
        Some(s) => pairs.push(("stoppedBy", s))
        None => ()
      }
      pairs.push(("done", ja(list("done").map(named_j))))
      pairs.push((
        "refused",
        ja(
          list("refused").map(x => jo([
            ("item", named_j(get(Some(x), "item").unwrap_or(jo([])))),
            ("why", get(Some(x), "why").unwrap_or(Null)),
          ])),
        ),
      ))
      pairs.push((
        "stopped",
        ja(
          list("stopped").map(x => jo([
            ("item", named_j(get(Some(x), "item").unwrap_or(jo([])))),
            ("waitsFor", named_j(get(Some(x), "waitsFor").unwrap_or(jo([])))),
          ])),
        ),
      ))
      pairs.push(("resumed", ja(list("resumed").map(named_j))))
      pairs.push((
        "failed",
        match get(Some(l), "failed") {
          None | Some(Null) => Null
          Some(f) =>
            jo([
              (
                "item",
                match get(Some(f), "item") {
                  None | Some(Null) => Null
                  Some(i) => named_j(i)
                },
              ),
              ("error", get(Some(f), "error").unwrap_or(Null)),
            ])
        },
      ))
      if list("failures").length() > 0 {
        pairs.push((
          "failures",
          ja(
            list("failures").map(f => jo([
              ("item", named_j(get(Some(f), "item").unwrap_or(jo([])))),
              ("error", get(Some(f), "error").unwrap_or(Null)),
            ])),
          ),
        ))
      }
      if list("returned").length() > 0 {
        pairs.push(("returned", ja(list("returned").map(named_j))))
      }
      if list("lent").length() > 0 {
        pairs.push(("lent", ja(list("lent").map(named_j))))
      }
      jo(pairs)
    }
  }
  jo([
    ("ws", get(Some(plan), "ws").unwrap_or(Null)),
    ("to", get(Some(plan), "to").unwrap_or(Null)),
    ("modules", ja(modules)),
    ("moving", moving_j),
    (
      "stopped",
      ja(
        stopped.map(s => jo([
          ("item", js(s.0.named())),
          ("waitsFor", js(s.1.need().named())),
        ])),
      ),
    ),
    ("last", last_j),
  ])
}

///|
/// A device's request of a route (api/request.ts `Request`): what the routes read of it.
pub(all) struct MoveRequest {
  method_ : String
  path : String
  query : Array[(String, String)]
  body : String
  email : String
  role : String
  workspace : String?
  lang : String
}

///|
/// A route (api/admin.ts `Route`).
pub(all) struct MoveRoute {
  method_ : String
  matches : (String) -> Bool
  handle : async (MoveRequest) -> (Int, J)
}

///|
pub(all) struct MoveRoutesDeps {
  scheduler : Scheduler
  order : () -> Array[String]
  home : () -> String?
  /// A station of `ws` by its id or name: its id, and whether it only runs tasks.
  station : (String, String) -> (String, Bool)?
  here : () -> String?
  rig : () -> Bool
  name : ((String, String) -> String?)?
  refusal : async (String, String, String) -> String?
  /// What the turn begun will be waited on by (a test's; the route answers 202 either way).
  begun : ((@effect.Deferred[J]) -> Unit)?
  say : Say
}

///|
fn error_answer(status : Int, message : String) -> (Int, J) {
  (status, jo([("error", js(message))]))
}

///|
/// `Number(s)` of what a query says (`NaN`: None).
pub fn js_number(s : String) -> Double? {
  let n = @jsjson.js_number(s)
  if @jsjson.is_finite(n) { Some(n) } else { None }
}

///|
/// The routes of a migration (routes.ts `moveRoutes`).
pub fn move_routes(d : MoveRoutesDeps) -> Array[MoveRoute] {
  let start = async fn(r : MoveRequest, back : Bool) -> (Int, J) {
    if r.role != "owner" && r.role != "admin" {
      return error_answer(403, d.say.tr_in(r.lang, "station.move.managersOnly", []))
    }
    let ws = match r.workspace {
      Some(w) => w
      None =>
        match (d.home)() {
          Some(h) => h
          None => return error_answer(404, "this station is in no workspace")
        }
    }
    if (d.rig)() {
      return error_answer(409, d.say.tr_in(r.lang, "station.move.isRig", []))
    }
    let b = if r.body.length() == 0 {
      Some(jo([]))
    } else {
      match (try Ok(parse(r.body)) catch { e => Err(e) }) {
        Ok(v) => Some(v)
        Err(_) => None
      }
    }
    let b = match b {
      Some((Obj(_) | Arr(_)) as v) => v
      _ =>
        return error_answer(
          400,
          "the body is JSON: {to, module, item} (POST /move/back: {from, …})",
        )
    }
    let given = match text(get(Some(b), if back { "from" } else { "to" })) {
      Some(s) => js_trim(s)
      None => ""
    }
    let at = if given == "" { None } else { (d.station)(ws, given) }
    let (at, tasks) = match at {
      Some(a) => a
      None =>
        return error_answer(
          400,
          d.say.tr_in(r.lang, "station.move.noStation", [("station", given)]),
        )
    }
    if Some(at) == (d.here)() {
      return error_answer(400, d.say.tr_in(r.lang, "station.move.self", []))
    }
    if tasks {
      return error_answer(
        409,
        d.say.tr_in(r.lang, "station.move.notWhole", [("station", given)]),
      )
    }
    let module = match text(get(Some(b), "module")) {
      Some(m) if m != "" => Some(m)
      _ => None
    }
    let item = match text(get(Some(b), "item")) {
      Some(m) if m != "" => Some(m)
      _ => None
    }
    let all = is_true(get(Some(b), "all"))
    if !all && (module is None || (item is None && !back)) {
      return error_answer(400, d.say.tr_in(r.lang, "station.move.pick", []))
    }
    match (d.refusal)(ws, at, r.lang) {
      Some(why) => return error_answer(409, why)
      None => ()
    }
    if d.scheduler.busy() {
      return error_answer(409, d.say.tr_in(r.lang, "station.move.running", []))
    }
    let follow = if all || module == Some("chats") { Some(["jobs"]) } else { None }
    let sel : Selection = {
      module,
      item,
      all,
      with_needs: !back && is_true(get(Some(b), "withNeeds")),
      follow,
      arrive_stopped: !back && is_true(get(Some(b), "arriveStopped")),
    }
    let run = if back {
      d.scheduler.back_soon(ws, at, sel, Some(r.email))
    } else {
      d.scheduler.move_soon(ws, at, sel, Some(r.email))
    }
    match d.begun {
      Some(f) => f(run)
      None => ()
    }
    (202, jo([("started", jb(true))]))
  }
  let is_path = (path : String, want : String) => path == want || path == want + "/"
  [
    { method_: "POST", matches: p => is_path(p, "/move"), handle: r => start(r, false) },
    {
      method_: "POST",
      matches: p => is_path(p, "/move/back"),
      handle: r => start(r, true),
    },
    {
      method_: "POST",
      matches: p => is_path(p, "/move/stop"),
      handle: async fn(r) {
        if r.role != "owner" && r.role != "admin" {
          return error_answer(403, d.say.tr_in(r.lang, "station.move.managersOnly", []))
        }
        if !d.scheduler.stop_turn(Some(r.email)) {
          return error_answer(409, d.say.tr_in(r.lang, "station.move.notRunning", []))
        }
        (200, jo([("ok", jb(true))]))
      },
    },
    {
      method_: "GET",
      matches: p => is_path(p, "/move"),
      handle: async fn(r) {
        let ws = match r.workspace {
          Some(w) => w
          None =>
            match (d.home)() {
              Some(h) => h
              None => return error_answer(404, "this station is in no workspace")
            }
        }
        let param = (name : String) => match r.query.search_by(q => q.0 == name) {
          Some(i) => Some(r.query[i].1)
          None => None
        }
        let given = param("to").unwrap_or("")
        let to = if given == "" {
          ""
        } else {
          match (d.station)(ws, given) {
            Some((id, _)) => id
            None =>
              return error_answer(
                400,
                d.say.tr_in(r.lang, "station.move.noStation", [("station", given)]),
              )
          }
        }
        let r_ = try Ok({
          let held = d.scheduler.held(ws, to)
          let plan = match held {
            Some(h) => h.plan
            None => d.scheduler.plan(ws, to)
          }
          let limit = match js_number(param("limit").unwrap_or(move_page.to_string())) {
            Some(n) if n == n && n - n == 0.0 => n
            _ => move_page.to_double()
          }
          let limit = if limit < 1.0 {
            1
          } else if limit > move_page_most.to_double() {
            move_page_most
          } else {
            limit.floor().to_int()
          }
          move_view(
            plan,
            (d.order)(),
            d.scheduler.stopped_list(),
            module?=param("module"),
            after?=param("after"),
            limit~,
            last?=d.scheduler.last(ws),
            stopping=d.scheduler.stopping(),
            name=id => match d.name {
              Some(n) =>
                match n(ws, id) {
                  Some(x) => x
                  None => slice_to(id, 12)
                }
              None => slice_to(id, 12)
            },
            current?=d.scheduler.current(),
            held?=held.map(h => (d.scheduler, h)),
          )
        }) catch { e => Err(e) }
        match r_ {
          Ok(v) => (200, v)
          Err(e) => error_answer(409, message_of(e))
        }
      },
    },
  ]
}
