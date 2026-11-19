// The Router's reads and writes in the workspace's chats through a Comma connect (station/src/comma/chats.ts), apart
// from the part that wires them (module.mbt), so that they can be tried alone.

///|
/// An older station answers with raw entries. Bound retries through edits; if no message can be reached in that budget,
/// an explicit upgrade error is safer than answering that the chat has no more messages.
let legacy_read_pages : Int = 8

///|
let legacy_read_rows : Int = 100

///|
/// The JSON contains only this chat's already-validated hearing members, in their original order.
pub let router_targets_insert : String =
  #|INSERT INTO comma_router_once_targets (id, position, session)
  #|  SELECT o.id, CAST(j.key AS INTEGER), j.value FROM comma_router_once o, json_each(?) j WHERE o.key = ?

///|
/// A chat's messages and title for the Router, only after the station holding the chat confirms its workspace.
pub async fn router_reads(
  stats : CommaStats,
  reads : WorkspaceReads,
  ref_ : String,
  after : Double,
  limit : Double,
) -> J {
  let (thread, station) = match chat_of(ref_) {
    Some(c) => c
    None => raise fail_("no such chat")
  }
  let of = (reads.of)()
  let read = async fn(position : Double, count : Double) -> J {
    let args = jobj([
      ("thread", Num(thread)),
      ("after", Num(position)),
      ("limit", Num(count)),
      ("messagesOnly", Bool(true)),
    ])
    let text = match station {
      None =>
        (reads.here)("outflowMessages", match of {
          None => args
          Some(o) => with_fields(args, [("ws", ws_j(o))])
        })
      Some(s) => (reads.there)(s, "outflowMessages", args)
    }
    let got = parse_json(text)
    if got is Null {
      raise fail_("no such chat of the workspace")
    }
    let g = Some(got)
    let incomplete = !(prop(g, "messages") is Some(Arr(_))) ||
      !safe_int(prop(g, "last")) ||
      num_of(prop(g, "last")).unwrap_or(0.0) < 0.0 ||
      (prop(g, "more") is Some(v) && !(v is Bool(_))) ||
      (
        prop(g, "messagesOnly") is Some(Bool(true)) &&
        (
          !(prop(g, "more") is Some(Bool(_))) ||
          (prop(g, "more") is Some(Bool(true)) && arr_of(prop(g, "messages")).unwrap_or([]).length() == 0)
        )
      )
    if incomplete {
      raise fail_("that station's message answer is incomplete")
    }
    got
  }
  let mut cursor = after
  let mut got = read(cursor, limit)
  let mut pages = 1
  let messages : Array[J] = []
  while true {
    let g = Some(got)
    let last = num_of(prop(g, "last")).unwrap_or(0.0)
    if pages > 1 && last < cursor {
      raise fail_("that station's message answer is incomplete")
    }
    let messages_only = prop(g, "messagesOnly") is Some(Bool(true))
    let mut previous = cursor
    for entry in arr_of(prop(g, "messages")).unwrap_or([]) {
      let e = Some(entry)
      let n = num_of(prop(e, "n")).unwrap_or(0.0)
      if !safe_int(prop(e, "n")) ||
        n <= previous ||
        n > last ||
        (messages_only && !(str_of(prop(e, "kind")) == Some("message"))) {
        raise fail_("that station's message answer is incomplete")
      }
      previous = n
      if str_of(prop(e, "kind")) == Some("message") && messages.length().to_double() < limit {
        messages.push(entry)
      }
    }
    if messages_only ||
      !(prop(g, "more") is Some(Bool(true))) ||
      messages.length().to_double() >= limit {
      break
    }
    if previous <= cursor {
      raise fail_("that station's message cursor does not continue")
    }
    if pages >= legacy_read_pages {
      if messages.length() == 0 {
        raise fail_("that station needs an update to read past these edits")
      }
      break
    }
    cursor = previous
    got = read(cursor, legacy_read_rows.to_double())
    pages += 1
  }
  let title = stats.task_title(ref_)
  let taken = if messages.length().to_double() > limit {
    messages[0:limit.to_int()].to_array()
  } else {
    messages
  }
  jo([
    ("title", title),
    (
      "messages",
      Some(
        Arr(
          taken.map(m => {
            let mm = Some(m)
            let person = prop(mm, "person")
            jo([
              ("seq", prop(mm, "n")),
              ("author_kind", prop(mm, "authorKind")),
              ("author", nullish(prop(person, "name"), nullish(prop(person, "email"), prop(mm, "author")))),
              ("text", prop(mm, "text")),
              ("at", prop(mm, "at")),
            ])
          }),
        ),
      ),
    ),
    ("through", prop(Some(got), "last")),
  ])
}

///|
/// The Router's write, as module.mbt and the Router give it.
pub(all) struct RouterSay {
  thread : Double
  text : String
  key : String
  requester : String
  connect : String
}

///|
/// What a keyed write's message asks of the store as it is written (lifecycle.ts `say`'s `once`), each in its
/// transaction: before the message is inserted, once it is, and whom it is delivered to.
pub(all) struct SayHooks {
  workspace : String?
  before : async () -> Unit
  inserted : async (Double) -> Unit
  targets : async () -> Array[String]
}

///|
/// What the Router's writes ask of the station's hub and store (its database, its sessions and threads, its delivery,
/// and lifecycle.ts `say`). A refusal of a busy store's write raises kind "MessageWriteBusy".
pub(all) struct RouterHub {
  /// A statement's first row (Null where none) on the store's database, its rows, and one that writes.
  get : async (String, Array[J]) -> J
  all : async (String, Array[J]) -> Array[J]
  run : async (String, Array[J]) -> Unit
  /// `store.threadSessions(thread)`: its members (`{session, leftAt, ...}`).
  thread_sessions : async (Double) -> Array[J]
  /// `store.getSession(key)`: its row, Null where there is none.
  get_session : async (String) -> J
  /// `hub.wsOf(session)`: of a row or a key.
  ws_of : async (J) -> String?
  /// `hub.deliver(thread, n, sessions, text, { retryPending: true, workspace })`.
  deliver : async (Double, Double, Array[String], String, String?) -> Unit
  /// `store.completeRouterWrite(id)`.
  complete_router_write : async (String) -> Bool
  /// lifecycle.ts `say(hub, thread, author, text, [], [], null, once)`: the message's n.
  say : async (Double, String, String, SayHooks?) -> Double
}

///|
/// The keyed write found again under its key.
struct RouterWrite {
  id : String
  thread : Double
  n : Double
  pending : Double
}

///|
pub suberror AlreadySaid {
  AlreadySaid(RouterWrite)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for AlreadySaid with output(self, logger) {
  match self {
    AlreadySaid(w) => logger.write_string("the router's write \{w.id} was said already")
  }
}

///|
/// The write an AlreadySaid names, as JSON (what crosses to a hook's caller and back).
pub fn already_said_j(e : Error) -> J? {
  match e {
    AlreadySaid(w) =>
      Some(jobj([("id", jstr(w.id)), ("thread", Num(w.thread)), ("n", Num(w.n)), ("pending", Num(w.pending))]))
    _ => None
  }
}

///|
/// The older process only knows the other database. Reject while it is still alive rather than letting a timed-out
/// request take effect later, after its caller has already been told it failed.
pub fn router_says_after(
  hub : RouterHub,
  stats : CommaStats,
  previous_exited : async () -> Unit,
  io : Io,
  runtime : @effect.Runtime,
) -> async (String?, RouterSay) -> Double {
  let ready = Ref(false)
  ignore(
    runtime.fork_daemon("comma previous exited", on_error=_ => (), async fn() {
      previous_exited() catch {
        _ => return
      }
      ready.val = true
    }),
  )
  async fn(workspace, w) {
    if !ready.val {
      raise fail_("the previous station is still handing over; retry the write")
    }
    router_says(hub, stats, workspace, w, io)
  }
}

///|
/// The Router's message in chat `thread` of this station, as `requester` of the Comma connect `connect` (named so in
/// the chat, as a person of that connect is), once per `key`: its `n`. Only a chat of workspace `home` (one of the
/// station's, the connect's) on the station's pages; a Slack or Feishu chat is answered where it is.
pub async fn router_says(hub : RouterHub, stats : CommaStats, home : String?, w : RouterSay, io : Io) -> Double {
  router_says_once(hub, stats, home, w, io) catch {
    Thrown("MessageWriteBusy", _) =>
      raise fail_(
        if w.key == "" {
          "the station is busy; retry the write"
        } else {
          "the station is busy; retry the Router request with the same key"
        },
      )
    e => raise e
  }
}

///|
fn write_of(row : J) -> RouterWrite? {
  if row is Null {
    return None
  }
  let r = Some(row)
  Some({
    id: str_of(prop(r, "id")).unwrap_or(""),
    thread: num_of(prop(r, "thread")).unwrap_or(0.0),
    n: num_of(prop(r, "n")).unwrap_or(0.0),
    pending: num_of(prop(r, "pending")).unwrap_or(0.0),
  })
}

///|
async fn router_says_once(hub : RouterHub, stats : CommaStats, home : String?, w : RouterSay, io : Io) -> Double {
  let find = async fn() -> RouterWrite? {
    write_of(
      (hub.get)("SELECT CAST(id AS TEXT) AS id, thread, n, pending FROM comma_router_once WHERE key = ?", [
        jstr(w.key),
      ]),
    )
  }
  let mirror = async fn(written : RouterWrite) -> Double {
    match find() {
      Some(f) if f.id == written.id => ()
      _ => raise fail_("the Router's recorded write changed; retry")
    }
    // Keep old stations' lookup in step, too. A failed write can be retried without recording the message again.
    if stats.said(w.key) is None {
      stats.remember(w.key, written.n)
    }
    written.n
  }
  let finish = async fn(written : RouterWrite) -> Double {
    // The state and targets must come from one snapshot: cleanup may otherwise remove part of the target list after a
    // retry read the old pending state. The identity stays distinct even after this key expires and is reused.
    let rows = (hub.all)(
      (
        #|SELECT o.pending, t.session FROM comma_router_once o
        #|      LEFT JOIN comma_router_once_targets t ON t.id = o.id WHERE o.id = ? AND o.key = ? ORDER BY t.position
      ),
      [jstr(written.id), jstr(w.key)],
    )
    let state = if rows.length() > 0 { prop(Some(rows[0]), "pending") } else { None }
    guard state is Some(state) else { raise fail_("the Router's recorded write changed; retry") }
    if state is Num(2.0) {
      raise fail_("the Router's write has expired")
    }
    if !(state is Num(0.0)) {
      let entry = (hub.get)("SELECT text FROM entries WHERE thread = ? AND n = ? AND kind = 'message'", [
        Num(written.thread),
        Num(written.n),
      ])
      let text = match prop(Some(entry), "text") {
        Some(Str(u)) => utext(u)
        _ => raise fail_("the Router's recorded message is unavailable")
      }
      let current = (hub.thread_sessions)(written.thread)
      let mut foreign = current.length() == 0
      for member in current {
        if foreign {
          break
        }
        let session = (hub.get_session)(str_of(prop(Some(member), "session")).unwrap_or(""))
        if session is Null || (hub.ws_of)(session) != home {
          foreign = true
        }
      }
      if foreign {
        raise fail_("no such chat of the workspace")
      }
      let members = current.map(m => str_of(prop(Some(m), "session")).unwrap_or(""))
      let targets = []
      for row in rows {
        match prop(Some(row), "session") {
          Some(Str(u)) => {
            let session = utext(u)
            if members.contains(session) && !((hub.get_session)(session) is Null) {
              targets.push(session)
            }
          }
          _ => ()
        }
      }
      (hub.deliver)(written.thread, written.n, targets, text, home)
      if !(hub.complete_router_write)(written.id) {
        raise fail_("the Router's recorded write changed; retry")
      }
    }
    mirror(written)
  }
  let recorded = if w.key == "" { None } else { find() }
  match recorded {
    Some(r) => return finish(r)
    None => ()
  }
  let had = if w.key == "" { None } else { stats.said(w.key) }
  match had {
    Some(n) => return n
    None => ()
  }
  // The Task index tells a chat the Router wrote in by this form of its author (read/outflow.ts routerWrote): durable
  // where comma_router_once is not, and for the writes without a key, which leave none.
  let author = "slack:\{w.connect}:\{w.requester}"
  if w.key == "" {
    let members = (hub.thread_sessions)(w.thread)
    let mut foreign = members.length() == 0
    for m in members {
      if foreign {
        break
      }
      if (hub.ws_of)(or_null(prop(Some(m), "session"))) != home {
        foreign = true
      }
    }
    if foreign {
      raise fail_("no such chat of the workspace")
    }
    return (hub.say)(w.thread, author, w.text, None)
  }
  let encoded_targets = Ref("[]")
  let inserted_write : Ref[RouterWrite?] = Ref(None)
  let hooks : SayHooks = {
    workspace: home,
    before: async fn() {
      match find() {
        Some(old) => raise AlreadySaid(old)
        None => ()
      }
      // Membership and workspace must be checked under the same write lock as the entry. A session can join or move
      // workspaces between the request arriving and this transaction beginning.
      let members = (hub.thread_sessions)(w.thread)
      if members.length() == 0 {
        raise fail_("no such chat of the workspace")
      }
      let targets = []
      for m in members {
        let key = str_of(prop(Some(m), "session")).unwrap_or("")
        let session = (hub.get_session)(key)
        if session is Null || (hub.ws_of)(session) != home {
          raise fail_("no such chat of the workspace")
        }
        if prop(Some(m), "leftAt") is (Some(Null) | None) &&
          str_of(prop(Some(session), "archivedBy")) != Some(manual) {
          targets.push(key)
        }
      }
      encoded_targets.val = stringify(Arr(targets.map(jstr)))
    },
    inserted: async fn(n) {
      let now = (io.now)()
      // Expire at most 64 keys and 64 targets at a time. A failed delivery can have many targets: remove it in batches
      // too, without letting a retry deliver only the targets that happen to remain during cleanup.
      let expired = jn(now - build_days.to_double() * day_ms)
      let oldest = "SELECT id FROM comma_router_once INDEXED BY comma_router_once_age WHERE at < ? ORDER BY at LIMIT 64"
      (hub.run)(
        "UPDATE comma_router_once SET pending = 2 WHERE pending = 1 AND id IN (\{oldest})",
        [expired],
      )
      (hub.run)(
        "DELETE FROM comma_router_once_targets WHERE (id, position) IN (\n          SELECT t.id, t.position FROM (\{oldest}) a CROSS JOIN comma_router_once_targets t WHERE t.id = a.id LIMIT 64\n        )",
        [expired],
      )
      (hub.run)(
        "DELETE FROM comma_router_once WHERE id IN\n          (SELECT a.id FROM (\{oldest}) a WHERE NOT EXISTS (SELECT 1 FROM comma_router_once_targets t WHERE t.id = a.id))",
        [expired],
      )
      let row = (hub.get)(
        "INSERT INTO comma_router_once (key, thread, n, at, pending) VALUES (?, ?, ?, ?, 1) RETURNING CAST(id AS TEXT) AS id",
        [jstr(w.key), Num(w.thread), Num(n), Num(now)],
      )
      inserted_write.val = Some({
        id: str_of(prop(Some(row), "id")).unwrap_or(""),
        thread: w.thread,
        n,
        pending: 1.0,
      })
      // Capture only the original members who were hearing at commit. Someone who rejoins or is unarchived before a
      // retry must not receive a message from before that change.
      (hub.run)(router_targets_insert, [jstr(encoded_targets.val), jstr(w.key)])
    },
    targets: async fn() {
      guard inserted_write.val is Some(write) else {
        raise fail_("the Router's recorded write is unavailable")
      }
      (hub.all)("SELECT session FROM comma_router_once_targets WHERE id = ? ORDER BY position", [jstr(write.id)]).map(
        t => str_of(prop(Some(t), "session")).unwrap_or(""),
      )
    },
  }
  let n = (hub.say)(w.thread, author, w.text, Some(hooks)) catch {
    AlreadySaid(old) => return finish(old)
    // (one that came back through the hub's own caller, said as JSON)
    Thrown("AlreadySaid", said) =>
      match (try { Some(parse_json(said)) } catch { _ => None }).map(write_of) {
        Some(Some(old)) => return finish(old)
        _ => raise fail_("Router key already recorded")
      }
    e => raise e
  }
  match inserted_write.val {
    Some(written) if written.n == n && (hub.complete_router_write)(written.id) => mirror(written)
    _ => raise fail_("the Router's recorded write changed; retry")
  }
}

///|
/// Who archived a session by hand (store.ts MANUAL).
pub let manual : String = "manual"
