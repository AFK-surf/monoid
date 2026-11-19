// What agents do in their own conversations (station/src/sessions/conversations.ts: chat_post, chat_state,
// chat_history, chat_leave, slack_api and what they rest on): post (with files and a card, ending the turn or not),
// record how the turn ends, read a thread, and call Slack as their bot. What a tool says of the turn reaches its
// session's actor, in turn with the rest. How a tool's arguments are read is src/sessions/args.ts's (`dep.stateArg`,
// `dep.needArg`, `dep.cardArg`...), as is the readers' finding of a question (`dep.readStateQuestion`,
// `dep.readStatePendingCard`).

///|
/// store/card-post-index.ts CARD_POSTS_PENDING.
let card_posts_pending : String = "card posts pending:"

///|
fn need_about_question() -> Thrown {
  fail_("need_human about must point to your visible question, not a person's message or another agent's post")
}

///|
fn question_not_pending() -> Thrown {
  fail_(
    "that question is no longer pending. Read what the person said; if a decision is still needed, ask again with a new card",
  )
}

///|
/// A need must still point at an actionable question.
async fn check_question(w : World, key : String, m : J) -> Unit {
  if str_of(at(Some(m), "authorKind")) != Some("agent") ||
    str_of(at(Some(m), "author")) != Some(key) ||
    trim(str_of(at(Some(m), "text")).unwrap_or("")) == "" {
    raise need_about_question()
  }
  let thread = at(Some(m), "thread").unwrap_or(Null)
  let n = at(Some(m), "n").unwrap_or(Null)
  let entry = at_i(Some(w.store("entriesBetween", [thread, n, n])), 0)
  let carded = match entry {
    Some(Null) | None => false
    Some(e) => !nullish(at(Some(e), "card")) || !nullish(at(Some(e), "options"))
  }
  let gone = if carded {
    let pending = w.store("pendingCard", [thread])
    let pn = at(at_i(Some(pending), 0), "n")
    match pn {
      Some(x) => !jeq(x, n)
      None => true
    }
  } else {
    w.store("askingMessage", [thread, n, ja([ji(0), ji(0)])]) is Null
  }
  if gone {
    raise question_not_pending()
  }
}

///|
/// The message a state is about: [thread, n, ts].
async fn message_for_about(w : World, key : String, thread : J, ts : String, question : Bool) -> J {
  if !question {
    let n = w.store("messageNumberAt", [thread, js(ts)])
    return if n is Null { Null } else { ja([thread, n, js(ts)]) }
  }
  let message = w.store("messageAt", [thread, js(ts)])
  if message is Null {
    return Null
  }
  check_question(w, key, message)
  ja([at(Some(message), "thread").unwrap_or(Null), at(Some(message), "n").unwrap_or(Null), at(Some(message), "ts").unwrap_or(Null)])
}

///|
fn question_result(found : J) -> J raise Thrown {
  match str_of(at(Some(found), "kind")) {
    Some("missing") => Null
    Some("invalid") => raise need_about_question()
    Some("answered") => raise question_not_pending()
    _ => at(Some(found), "about").unwrap_or(Null)
  }
}

///|
fn needs_question_preparation(e : Error) -> Bool {
  thrown_kind(e) == "LegacyEditsUnavailable" || starts(thrown_message(e), card_posts_pending)
}

///|
async fn data_version(w : World) -> J {
  at(Some(w.ask("db.get", [js("PRAGMA main.data_version")])), "data_version").unwrap_or(Null)
}

///|
fn same_ids(a : Array[J], b : Array[J]) -> Bool {
  a.length() == b.length() && a.iter().zip(b.iter()).all(p => jeq(p.0, p.1))
}

///|
/// A reader's answer, confirmed in the current snapshot where it may have gone stale meanwhile.
async fn state_read(
  w : World,
  key : String,
  threads_of : async () -> Array[J],
  read : async (Array[J]) -> J,
  confirm : async (Array[J]) -> J,
  can_confirm : async () -> Bool,
) -> J {
  while true {
    let before = data_version(w)
    let threads = threads_of()
    let changed = Ref::new(false)
    let stop = w.store("subscribe", [
      (w.callback)(async fn(a) {
        let change = a.get(0).unwrap_or(Null)
        let ty = str_of(at(Some(change), "type"))
        if (ty == Some("thread") || ty == Some("threadRemoved")) && jincludes(threads, at(Some(change), "id").unwrap_or(Null)) {
          changed.val = true
        }
        if ty == Some("sessionRemoved") && str_of(at(Some(change), "key")) == Some(key) {
          changed.val = true
        }
        Null
      }),
    ])
    let mut found = try read(threads) catch {
      e => {
        w.call_fn(stop, []) |> ignore
        raise e
      }
    }
    w.call_fn(stop, []) |> ignore
    let current = threads_of()
    let after = data_version(w)
    if changed.val || !jeq(before, after) || !same_ids(current, threads) {
      if !can_confirm() {
        continue
      }
      found = confirm(current) catch {
        e => {
          if needs_question_preparation(e) {
            continue
          }
          raise e
        }
      }
    }
    return found
  }
  Null
}

///|
/// Rechecks and writes in one SQLite transaction, never waiting for another connection's writer.
async fn state_write(w : World, write : async () -> Unit) -> Unit {
  let timeout = at(Some(w.ask("db.get", [js("PRAGMA busy_timeout")])), "timeout").unwrap_or(Null)
  let timeout_text = js_string_of(Some(timeout))
  w.ask("db.exec", [js("PRAGMA busy_timeout=0")]) |> ignore
  let mut begun = false
  let mut failed : Error? = None
  try {
    w.ask("db.exec", [js("BEGIN IMMEDIATE")]) |> ignore
    begun = true
  } catch {
    e => {
      let code = num_of(at(Some(w.thrown.val), "errcode"))
      failed = Some(match code {
        Some(c) if (c.to_int() & 255) == 5 || (c.to_int() & 255) == 6 => Thrown("StateWriteBusy", "")
        _ => e
      })
    }
  }
  try {
    w.ask("db.exec", [js("PRAGMA busy_timeout=\{timeout_text}")]) |> ignore
  } catch {
    e => {
      if begun {
        try {
          w.ask("db.exec", [js("ROLLBACK")]) |> ignore
        } catch {
          _ => ()
        }
      }
      raise e
    }
  }
  if failed is Some(e) {
    raise e
  }
  try {
    write()
    w.ask("db.exec", [js("COMMIT")]) |> ignore
  } catch {
    e => {
      try {
        w.ask("db.exec", [js("ROLLBACK")]) |> ignore
      } catch {
        _ => ()
      }
      raise e
    }
  }
}

///|
/// An actor's identity as the hub holds it now (`hub.actors.get(key)`), to tell whether it is the same one later.
async fn actor_id(w : World, key : String) -> J {
  w.hub("actorId", [js(key)])
}

///|
async fn record_question_for_turn(
  w : World,
  key : String,
  turn : J,
  kind : J,
  words : J,
  about : J,
  watch : Bool,
  threads_of : async () -> Array[J],
  ts : String,
  missing : String,
) -> Bool {
  let mut delay = 10.0
  while true {
    let result = try {
      let save_cb = (w.callback)(async fn(a) {
        let save = a.get(0).unwrap_or(Null)
        state_write(w, async fn() {
          let store = read_store(w)
          let current = question_result(w.dep("readStateQuestion", [store, js(key), ja(threads_of()), js(ts)]))
          if current is Null {
            raise fail_(missing)
          }
          w.call_fn(save, [current]) |> ignore
        })
        Null
      })
      Some(w.actor(key, "stateForTurn", [turn, kind, words, about, jb(watch), save_cb]))
    } catch {
      Thrown("StateWriteBusy", _) => {
        w.sleep(delay)
        delay = @cmp.minimum(delay * 2.0, 250.0)
        None
      }
      e => {
        if needs_question_preparation(e) {
          question_for_about(w, key, threads_of, ts) |> ignore
          None
        } else {
          raise e
        }
      }
    }
    match result {
      Some(v) => return v is Bool(true)
      None => continue
    }
  }
  false
}

///|
async fn question_for_about(w : World, key : String, threads_of : async () -> Array[J], ts : String) -> J {
  let bounded = async fn() {
    w.ask_u("db.get", [
      js(
        "SELECT 1 WHERE\n    EXISTS (SELECT 1 FROM sqlite_master WHERE type='index' AND name='entries_edits') OR\n    EXISTS (SELECT 1 FROM sqlite_master WHERE type='view' AND name='merged' AND instr(sql, 'legacy_edit_meta') > 0)",
      ),
    ])
    is Some(_)
  }
  let found = state_read(
    w,
    key,
    threads_of,
    async fn(threads) { w.hub("stateQuestion", [js(key), ja(threads), js(ts)]) },
    async fn(threads) { w.dep("readStateQuestion", [read_store(w), js(key), ja(threads), js(ts)]) },
    bounded,
  )
  question_result(found)
}

///|
async fn pending_for_state(w : World, key : String, threads_of : async () -> Array[J]) -> J {
  state_read(
    w,
    key,
    threads_of,
    async fn(threads) { w.hub("statePendingCard", [ja(threads)]) },
    async fn(threads) { w.dep("readStatePendingCard", [read_store(w), ja(threads)]) },
    async fn() { true },
  )
}

///|
pub let need_visible_question : String = "need_human requires a visible question: post what you need with chat_post kind=need_human, or give about pointing to your question (a pending answer card is used by default). need alone is not a message to the person"

///|
async fn record_pending_for_turn(
  w : World,
  key : String,
  actor : J,
  turn : J,
  kind : J,
  words : J,
  about : J,
  watch : Bool,
  threads_of : async () -> Array[J],
  require_question : Bool,
) -> Bool {
  let mut delay = 10.0
  while true {
    if !jeq(actor_id(w, key), actor) {
      return false
    }
    let result = try {
      let save_cb = (w.callback)(async fn(a) {
        let save = a.get(0).unwrap_or(Null)
        state_write(w, async fn() {
          let store = read_store(w)
          let current = w.dep("readStatePendingCard", [store, ja(threads_of())])
          if current is Null && require_question {
            raise fail_(need_visible_question)
          }
          w.call_fn(save, [current]) |> ignore
        })
        Null
      })
      Some(w.actor(key, "stateForTurn", [turn, kind, words, about, jb(watch), save_cb]))
    } catch {
      Thrown("StateWriteBusy", _) => {
        w.sleep(delay)
        delay = @cmp.minimum(delay * 2.0, 250.0)
        None
      }
      e => {
        if needs_question_preparation(e) {
          pending_for_state(w, key, threads_of) |> ignore
          None
        } else {
          raise e
        }
      }
    }
    match result {
      Some(v) => return v is Bool(true)
      None => continue
    }
  }
  false
}

///|
async fn recent_thread_ids(w : World, key : String) -> Array[J] {
  arr_of(at(Some(w.store("recentSessionThreads", [js(key)])), "threads"))
  .unwrap_or([])
  .map(t => at(at(Some(t), "thread"), "id").unwrap_or(Null))
}

///|
/// A thread of this session the agent named with to=, and how the session posts there.
pub async fn target(w : World, key : String, to : J?) -> J {
  if w.store("getSession", [js(key)]) is Null {
    raise fail_("unknown session")
  }
  let known = async fn() {
    let threads = arr_of(Some(w.dep("threadsToldOf", [js(key)]))).unwrap_or([])
    if threads.length() == 0 {
      "none yet"
    } else {
      threads.map(t => str_of(Some(t)).unwrap_or("")).join(", ")
    }
  }
  let given = match to {
    Some(Str(u)) if trim(@jsjson.sanitize_str(u)) != "" => @jsjson.sanitize_str(u)
    _ => raise fail_("to is required: the thread attribute of the message you are answering. This session's threads: \{known()}")
  }
  guard parse_thread_address(given) is Some((channel, ts)) else {
    raise fail_("to must look like CHANNEL/THREAD_TS, got \{quoted(given)}")
  }
  let thread = w.store("sessionThread", [js(key), js(channel), js(ts)])
  if nullish(Some(thread)) {
    raise fail_("\{given} is not a conversation of this session. Its threads: \{known()}")
  }
  thread
}

///|
let most_attached : Double = 52428800.0

///|
/// Whether `staged` may have something to copy.
pub async fn may_stage(w : World, args : J, links : Bool) -> Bool {
  if !(w.ask("places.mac", []) is Bool(true)) {
    return false
  }
  match at(Some(args), "files") {
    Some(Arr(xs)) if xs.length() > 0 => return true
    _ => ()
  }
  if links && at(Some(args), "text") is Some(Str(u)) {
    for p in named_local_paths(w, @jsjson.sanitize_str(u)) {
      if w.ask("places.protects", [js(p.1)]) is Bool(true) {
        return true
      }
    }
  }
  false
}

///|
fn dirname(p : String) -> String {
  let i = last_index_of(p, "/")
  if i < 0 {
    "."
  } else if i == 0 {
    "/"
  } else {
    slice(p, 0, b=i)
  }
}

///|
fn basename(p : String) -> String {
  let mut q = p
  while q.length() > 1 && ends(q, "/") {
    q = slice(q, 0, b=q.length() - 1)
  }
  let i = last_index_of(q, "/")
  if i < 0 {
    q
  } else {
    slice(q, i + 1)
  }
}

///|
/// `/:[0-9]+(:[0-9]+)?$/`: where a path's line (and column) begins.
fn line_suffix(path : String) -> Int? {
  let n = path.length()
  let mut i = n
  while i > 0 && path.unsafe_charcode_at(i - 1) >= '0' && path.unsafe_charcode_at(i - 1) <= '9' {
    i -= 1
  }
  if i == n || i == 0 || path.unsafe_charcode_at(i - 1) != ':' {
    return None
  }
  let first = i - 1
  let mut j = first
  while j > 0 && path.unsafe_charcode_at(j - 1) >= '0' && path.unsafe_charcode_at(j - 1) <= '9' {
    j -= 1
  }
  if j < first && j > 0 && path.unsafe_charcode_at(j - 1) == ':' {
    Some(j - 1)
  } else {
    Some(first)
  }
}

///|
/// Files an agent names for a message that are in a folder macOS protects, copied into the session's uploads first:
/// the arguments to go on with, and the copies to remove once the message is sent (`staged_done`).
pub async fn staged(w : World, key : String, args : J, links : Bool) -> (J, Array[String]) {
  let row = w.store("getSession", [js(key)])
  let copies : Array[String] = []
  let has_files = at(Some(args), "files") is Some(Arr(_))
  let has_text = at(Some(args), "text") is Some(Str(_))
  if row is Null || (!has_files && !(links && has_text)) {
    return (args, copies)
  }
  let workspace = str_of(at(Some(row), "workspace")).unwrap_or("")
  let into = join_path([workspace, "uploads"])
  let asker = jo([("lang", js("en")), ("agent", jb(true))])
  let take = async fn(path : String) -> String {
    let copy = str_of(Some(w.ask("places.file", [js(path), js(into), asker, jn(most_attached)]))).unwrap_or("")
    if copy != path {
      copies.push(copy)
    }
    copy
  }
  try {
    let mut next = args
    match at(Some(args), "files") {
      Some(Arr(given)) => {
        let files = []
        for f in given {
          let g = js_string(f)
          let full = if is_absolute(g) { g } else { join_path([workspace, g]) }
          let copy = take(full)
          files.push(js(if copy == full { g } else { copy }))
        }
        next = set_field(next, "files", ja(files))
      }
      _ => ()
    }
    if links && at(Some(args), "text") is Some(Str(u)) {
      let mut text = @jsjson.sanitize_str(u)
      for p in named_local_paths(w, text) {
        let (destination, path) = p
        if !(w.ask("places.protects", [js(path)]) is Bool(true)) {
          continue
        }
        let line = line_suffix(path)
        let copy = try {
          take(path)
        } catch {
          e => {
            guard line is Some(at_) && thrown_kind(e) == "PlaceRefused:gone" else { raise e }
            take(slice(path, 0, b=at_))
          }
        }
        let as_ = if copy.contains(" ") { "<\{copy}>" } else { copy }
        text = split(text, "](<\{destination}>").join("](\{as_}")
        text = split(text, "](\{destination}").join("](\{as_}")
      }
      next = set_field(next, "text", js(text))
    }
    (next, copies)
  } catch {
    e => {
      staged_done(w, copies)
      raise e
    }
  }
}

///|
/// Removes what `staged` copied (each copy's folder).
pub async fn staged_done(w : World, copies : Array[String]) -> Unit {
  for c in copies {
    w.ask("fs.rm", [js(dirname(c))]) |> ignore
  }
}

///|
/// Copies files the agent attaches into the session's uploads (`into`'s), measured where they are pictures or films.
pub async fn attach(w : World, key : String, paths : Array[String], into : String) -> J {
  let row = w.store("getSession", [js(key)])
  let target_row = if into == key { row } else { w.store("getSession", [js(into)]) }
  if row is Null || target_row is Null {
    raise fail_("unknown session")
  }
  if paths.length() > 10 {
    raise fail_("at most 10 files per message")
  }
  let workspace = str_of(at(Some(row), "workspace")).unwrap_or("")
  let dir = join_path([str_of(at(Some(target_row), "workspace")).unwrap_or(""), "uploads"])
  w.ask("fs.mkdir", [js(dir)]) |> ignore
  let out = []
  for given in paths {
    let path = if is_absolute(given) { given } else { join_path([workspace, given]) }
    let meta = try {
      w.ask("fs.stat", [js(path)])
    } catch {
      _ => raise fail_("no such file: \{given}")
    }
    if !(at(Some(meta), "isFile") is Some(Bool(true))) {
      raise fail_("not a file: \{given}")
    }
    let size = num_of(at(Some(meta), "size")).unwrap_or(0.0)
    if size > 52428800.0 {
      raise fail_("too large (over 50 MB): \{given}")
    }
    let name = basename(path)
    let iso = str_of(Some(w.dep("iso", [jn(w.now())]))).unwrap_or("")
    let stamp = replace_all(replace_all(slice(iso, 0, b=19), ":", "-"), ".", "-")
    let safe = StringBuilder::new()
    for c in name {
      if c == '\\' || c == '/' || c.to_int() < 0x20 {
        safe.write_char('_')
      } else {
        safe.write_char(c)
      }
    }
    let copy = join_path([dir, "\{stamp}-\{safe}"])
    w.ask("fs.copyFile", [js(path), js(copy)]) |> ignore
    let facts = w.dep("shownFactsSoon", [js(copy)])
    out.push(spread(jo([("name", js(name)), ("path", js(copy)), ("size", jn(size))]), facts))
  }
  ja(out)
}

///|
/// Why a card may not wait for `assignee` in chat `thread`, or None.
async fn runner_assignee(w : World, thread : J, assignee : String) -> String? {
  let own = (v : J?) => match str_of(v) {
    Some(s) => lower(trim(s))
    None => ""
  }
  let profiles = arr_of(at(Some(w.config()), "profiles")).unwrap_or([])
  if !profiles.iter().any(p => own(at(Some(p), "name")) == assignee || own(at(Some(p), "email")) == assignee) {
    return None
  }
  if w.ask_u("db.get", [js("SELECT 1 FROM thread_people WHERE thread = ? AND lower(author) = ? LIMIT 1"), thread, js(assignee)]) is Some(_) {
    return None
  }
  let wrote = arr_of(
      Some(
        w.ask("db.all", [
          js("SELECT author FROM thread_people WHERE thread = ? AND author LIKE '%@%' AND author NOT LIKE '%:%' LIMIT 10"),
          thread,
        ]),
      ),
    )
    .unwrap_or([])
  let people = wrote.map(r => str_of(at(Some(r), "author")).unwrap_or(""))
  let who = if people.length() > 0 { ": who wrote here is \{people.join(", ")}" } else { "" }
  Some(
    "card.assignee \{assignee} is an account agents run on here, not a person in this chat (an email your runtime calls its user's is that account). Set it to the deciding person's email from their message's from\{who}.",
  )
}

///|
/// A reader of the station's store, opened on its database and data directory (read/store.ts `makeStore`).
async fn read_store(w : World) -> J {
  w.dep("makeReadStore", [at(Some(w.config()), "dataDir").unwrap_or(Null)])
}
