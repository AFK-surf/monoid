// P5-5's live parts of the station (main.ts's Layers of them, on the shared bus, live_bus.mbt): the connects (Slack,
// Feishu, Comma, the group, and the workspace's connects across its stations: live_p5_5_connects.mbt), the copies of
// the chats and a station's retirement (live_p5_5_copies.mbt), the moves between stations (live_p5_5_moves.mbt), the
// updates and the station's `beta` features (live_p5_5_updates.mbt). What they offer the other slices is asked of
// `bus.coord_ask` by name (`P55::ask`, below).
//
// A part's routes of the admin API (StationParts `routes`) take the request as JSON and answer it as JSON:
//   asked `{"method", "path", "query": {…}, "body": <the body parsed, or null>, "viewer": {…}, "lang"}`,
//   answered `{"status": <n>, "body": <JSON>}`
// (api/request.ts `Request` and `Answer` as the admin API serves them: P5-1's, which matches `path` by the route's).

///|
/// The slice's own state: what each part made, and what it answers on `coord_ask`.
priv struct P55 {
  bus : LiveBus
  ops : Map[String, async (Json) -> Json]
  /// What answers the ops whose name begins so (`slack/index.`, `slack.apps.`, `slack.chat:`), given the whole name.
  prefix_ops : Array[(String, async (String, Json) -> Json)]
  mut updates : @updates.Updates?
  closers : Array[async () -> Unit]
  /// The reads of the moves' latest pages of sessions, by their page's `handle` (P55::wrap_session_page): what the
  /// plan's checks read a page's sessions through, one statement for the page (move/live.ts gives the SessionPage).
  pages : Map[Int, @replica_coord.SessionReads]
  mut next_page : Int
}

///|
pub async fn start_live_p5_5(bus : LiveBus) -> Unit {
  let p : P55 = { bus, ops: Map([]), prefix_ops: [], updates: None, closers: [], pages: Map([]), next_page: 0 }
  bus.coord_ask.val = async fn(op, arg) { p.ask(op, arg) }
  // (each part on its own: one that fails to be made is said, the others made all the same)
  let parts : Array[(String, async () -> Unit)] = [
    ("features", async fn() { p.start_features() }),
    ("updates", async fn() { p.start_updates() }),
    ("copies", async fn() { p.start_copies() }),
    ("moves", async fn() { p.start_moves() }),
    ("connects", async fn() { p.start_connects() }),
  ]
  for part in parts {
    (part.1)() catch {
      e => err_write("station: the \{part.0} part is not made: \{p55_said_of(e)}\n")
    }
  }
  // (closed as the station stops, each on its own; the station's run waits for them before its process ends:
  // `p55_closed`)
  let closed : @effect.Deferred[Unit] = @effect.Deferred::new()
  p55_closed.val = Some(closed)
  fork_bg(bus.host, "p5-5 close", async fn() {
    ignore(bus.stopped.wait())
    for c in p.closers.rev() {
      c() catch {
        _ => ()
      }
    }
    ignore(closed.succeed(()))
  })
}

///|
/// Once the slice's parts are closed as the station stops (their processes ended: the copies' export).
let p55_closed : Ref[@effect.Deferred[Unit]?] = Ref(None)

///|
/// What the station's run waits for before its process ends, a while at most.
async fn wait_live_p5_5_closed() -> Unit {
  match p55_closed.val {
    Some(d) => ignore(@effect.timeout(10_000, async fn() { d.wait() }))
    None => ()
  }
}

///|
/// What the slice answers the other slices (`coord_ask`), by name.
async fn P55::ask(self : P55, op : String, arg : Json) -> Json {
  let f : async (Json) -> Json = match self.ops.get(op) {
    Some(f) => f
    None =>
      match self.prefix_ops.search_by(p => op.has_prefix(p.0)) {
        Some(i) => {
          let g = self.prefix_ops[i].1
          async fn(a) { g(op, a) }
        }
        None => raise BusError("coord: no such op \{op}")
      }
  }
  // (what a part refuses, as the admin API's routes take it: its kind, its words)
  f(arg) catch {
    e => raise p55_thrown_of(e)
  }
}

///|
fn P55::prefix_op(self : P55, prefix : String, f : async (String, Json) -> Json) -> Unit {
  self.prefix_ops.push((prefix, f))
}

///|
fn P55::op(self : P55, name : String, f : async (Json) -> Json) -> Unit {
  self.ops[name] = f
}

///|
fn P55::closing(self : P55, f : async () -> Unit) -> Unit {
  self.closers.push(f)
}

///|
fn P55::warn(_self : P55, part : String, words : String, e : Error) -> Unit {
  err_write("\{part}: \{words}: \{p55_said_of(e)}\n")
}

///|
/// An error's words, whichever part's it is.
fn p55_said_of(e : Error) -> String {
  match e {
    BusError(m) => m
    @updates.Thrown(_, _) => @updates.message_of(e)
    @replica_coord.Thrown(_, _) => @replica_coord.message_of(e)
    @feishu.FeishuError(_) | @feishu.ApiError(_, _) => @feishu.error_words(e)
    @slack.SlackApiError(_, _, _) | @slack.SlackWords(_, _) | @slack.Thrown(_, _) | @slack.Unanswered(_) | @slack.WsRefused(_, _) =>
      @slack.message_of(e)
    @comma.Thrown(_, _) => @comma.message_of(e)
    @session_chats.Thrown(_, m) => m
    @api_routes.Thrown(_, _) | @api_routes.Refused(_, _) => @api_routes.message_of(e)
    @gate.PeerRefused(_)
    | @gate.Refused(_)
    | @gate.LockRefusal(_)
    | @gate.NoLink(_)
    | @gate.NoBytes(_)
    | @gate.WaysRefusal(_)
    | @gate.MarkRefusal(_)
    | @gate.PeerGone(_, _)
    | @gate.HttpRefusal(_, _, _)
    | @gate.DeviceRefused(_, _) => @gate.words_of(e)
    e => @move_coord.message_of(e)
  }
}

// ── JSON at hand ──

// ── the admin API's routes as JSON (above) ──

///|
fn answered(status : Int, body : Json) -> Json {
  { "status": Json::number(status.to_double()), "body": body }
}

///|
fn refused(status : Int, message : String) -> Json {
  answered(status, { "error": Json::string(message) })
}

///|
/// Whether a viewer manages the station's workspace (mesh/credential.ts `managesStation`: its owner or an admin).
fn manages(viewer : Json) -> Bool {
  p51_manages(viewer)
}

///|
fn lang_in(r : Json) -> String {
  match jtext(r, "lang") {
    Some(l) if l != "" => l
    _ => "zh"
  }
}

///|
fn p55_route(meth : String, path : String, answer : async (Json) -> Json) -> PartRoute {
  { meth, path, answer }
}

///|
/// Whether `request` is answered by a route of `routes` (its method, its path matching the route's pattern as
/// `pattern_matches` reads it): its answer, else None.
pub async fn answer_route(routes : Array[PartRoute], request : Json) -> Json? {
  let meth = jtext_or_empty(request, "method")
  let p = jtext_or_empty(request, "path")
  for r in routes {
    if r.meth == meth && pattern_matches(r.path, p) {
      return Some((r.answer)(request))
    }
  }
  None
}

///|
/// A route's pattern as the slice writes them: `^`, literal segments, `([^/]+)` for one segment, `(.*)` for the rest,
/// `(/.*)?` for what is under it or nothing, `$` (api/admin.ts's patterns are regular expressions of that shape).
pub fn pattern_matches(pattern : String, p : String) -> Bool {
  // (`^/move(/.*)?$`: the path and anything under it)
  if pattern.has_suffix("(/.*)?$") {
    let base = pattern.unsafe_substring(start=if pattern.has_prefix("^") { 1 } else { 0 }, end=pattern.length() - 7)
    return p == base || p.has_prefix(base + "/")
  }
  let pat = if pattern.has_prefix("^") { pattern.unsafe_substring(start=1, end=pattern.length()) } else { pattern }
  let pat = if pat.has_suffix("$") { pat.unsafe_substring(start=0, end=pat.length() - 1) } else { pat }
  let ps = pat.split("/").map(x => x.to_owned()).to_array()
  let xs = p.split("/").map(x => x.to_owned()).to_array()
  let mut i = 0
  while i < ps.length() {
    let seg = ps[i].replace_all(old="\\/", new="/")
    if seg == "(.*)" {
      return true
    }
    if i >= xs.length() {
      return false
    }
    if seg == "([^/]+)" {
      if xs[i] == "" {
        return false
      }
    } else if seg != xs[i] {
      return false
    }
    i += 1
  }
  i == xs.length()
}

///|
/// The segment `n` of a request's path (0: before the first `/`).
fn path_seg(r : Json, n : Int) -> String {
  let xs = jtext_or_empty(r, "path").split("/").map(x => x.to_owned()).to_array()
  if n < xs.length() {
    xs[n]
  } else {
    ""
  }
}

// ── the control plane's state, as cloud.json says it (bus.cloud_state) ──

///|
/// The workspaces this station is in: (workspace, name, home, its stations as cloud.json lists them).
fn P55::memberships(self : P55) -> Array[(String, String, Bool, Array[Json])] {
  let state = (self.bus.cloud_state.val)().unwrap_or(Json::null())
  let out = []
  let home = jtext_or_empty(state, "workspace")
  if home != "" && !(jfield(state, "removed_at") is Number(_, ..)) {
    out.push((home, jtext_or_empty(state, "workspace_name"), true, match jfield(state, "peers") { Array(xs) => xs; _ => [] }))
  }
  match jfield(state, "joined") {
    Array(xs) =>
      for j in xs {
        let ws = jtext_or_empty(j, "workspace")
        if ws != "" && ws != home {
          out.push((ws, jtext_or_empty(j, "workspace_name"), false, match jfield(j, "peers") { Array(ps) => ps; _ => [] }))
        }
      }
    _ => ()
  }
  out
}

///|
fn P55::home(self : P55) -> String? {
  for m in self.memberships() {
    if m.2 {
      return Some(m.0)
    }
  }
  None
}

///|
/// A workspace's stations (id, name, whether it only runs tasks), or None where this station is not in it.
fn P55::roster(self : P55, ws : String) -> Array[(String, String, Bool)]? {
  for m in self.memberships() {
    if m.0 == ws {
      return Some(
        m.3.filter_map(p => match jtext(p, "id") {
          Some(id) => Some((id, jtext_or_empty(p, "name"), jtext(p, "mode") == Some("tasks")))
          None => None
        }),
      )
    }
  }
  None
}

///|
/// Whether `peer` is a station of a workspace this one is in.
fn P55::in_workspace(self : P55, peer : String) -> Bool {
  self.memberships().iter().any(m => m.3.iter().any(p => jtext(p, "id") == Some(peer)))
}

///|
/// The origin of still.fail cloud (or Comma's) this station is in: where its releases are (ControlPlane.releaseBase).
fn P55::release_base(self : P55) -> String? {
  let state = (self.bus.cloud_state.val)().unwrap_or(Json::null())
  match jtext(state, "origin") {
    Some(o) if o != "" => Some(if jtext(state, "provider") == Some("comma") { "\{o}/stations" } else { o })
    _ => None
  }
}
