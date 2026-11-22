// After an agent ends a turn all_done, whether the chat has nothing left to do (station/src/sessions/review.ts): asked
// of the decision model on its own afterwards, with the latest messages that fit, newest first. A chat it finds
// finished is recommended for the archive; one it finds unfinished, or cannot tell, is not. It never holds an agent
// back. The archive policy's question and how its answer recommends are sessions/archive-policy.ts's
// (`dep.policyFrom`, `dep.policyQuestion`, `dep.recommends`, `dep.archiveMass`); whether an account may be asked,
// sessions/pool.ts `usable` (`dep.usable`).

///|
let archive_review_messages : Int = 400

///|
let archive_review_bytes : Int = 80000

///|
/// Whose archive policy a session's chat is under: its workspace's, None for the station's home one.
pub fn policy_ws(w : World, key : J) -> J raise {
  let ws = jopt(w.with_hub(h => h.ws_of_arg(key.to_json())))
  if ws is Null {
    return Null
  }
  let workspaces = w.with_hub(h => h.workspaces())
  if workspaces.length() > 0 && jeq(ws, js(workspaces[0])) {
    Null
  } else {
    ws
  }
}

///|
/// Which policy a check of a session's chat was made under: its number as saved (0 for the default).
pub async fn policy_stamp(w : World, key : String) -> J {
  let saved = w.with_threads_j(t => t.archive_policy(policy_ws(w, js(key)).to_json()))
  match at(at(Some(saved), "change"), "id") {
    Some(Null) | None => ji(0)
    Some(id) => id
  }
}

///|
/// Starts the review in the background (a fiber of the hub's).
/// (A station that runs it gives `forkReview`; the harness's TypeScript twin is told the stand-in fork it makes.)
pub async fn suggest_archive(w : World, key : String) -> Unit {
  if w.has("forkReview") {
    w.hub("forkReview", [js(key)]) |> ignore
  } else {
    w.hub("fork", [js("<effect>")]) |> ignore
  }
}

///|
/// The profiles whose verified model the rule names, in order: the ones a review may ask.
async fn candidates_of(w : World) -> Array[(J, J)] {
  let rule = at(at(Some(w.config()), "automaticDecisions"), "completion")
  let out = []
  for profile in arr_of(at(Some(w.config()), "profiles")).unwrap_or([]) {
    if at(Some(profile), "enabled") is Some(Bool(false)) {
      continue
    }
    let health = w.ask("accounts.healthOf", [at(Some(profile), "id").unwrap_or(Null)])
    if !@session_hub.usable(health.to_json(), None) {
      continue
    }
    let capability = at(at(Some(health), "check"), "decision")
    let decided = match capability {
      Some(Null) | None => None
      Some(c) => resolved_model(w, profile, c, at(rule, "model").unwrap_or(Null))
    }
    if decided is Some(d) {
      out.push((at(Some(profile), "id").unwrap_or(Null), d))
    }
  }
  out
}

///|
fn shown_message(m : J) -> J {
  jo([
    ("authorKind", at(Some(m), "authorKind").unwrap_or(Null)),
    ("author", at(Some(m), "author").unwrap_or(Null)),
    ("text", at(Some(m), "text").unwrap_or(Null)),
    ("ts", at(Some(m), "ts").unwrap_or(Null)),
    ("hasAttachments", jb(arr_of(at(Some(m), "attachments")).unwrap_or([]).length() > 0)),
  ])
}

///|
/// The review itself; done once its result is recorded.
pub async fn review(w : World, key : String) -> Unit {
  let rule = at(at(Some(w.config()), "automaticDecisions"), "completion").unwrap_or(Null)
  if !(at(Some(rule), "enabled") is Some(Bool(true))) {
    return
  }
  let candidates = candidates_of(w)
  let record = fn(detail : J) {
    try {
      ignore(w.with_threads_j(t => t.record_decision(Json::string(key), detail)))
    } catch {
      _ => ()
    }
  }
  let saved = w.with_threads_j(t => t.archive_policy(policy_ws(w, js(key)).to_json()))
  let policy = @session_storage.policy_from(opt_json(Some(saved)))
  let policy_at = match at(at(Some(saved), "change"), "id") {
    Some(Null) | None => ji(0)
    Some(id) => id
  }
  let verdict = fn(versions : Array[(J, J)], v : J) {
    for p in versions {
      try {
        ignore(w.with_threads_j(t => t.set_archive_verdict(Json::string(key), p.0.to_json(), p.1.to_json(), v)))
      } catch {
        _ => ()
      }
    }
  }
  let threads = arr_of(at(Some(w.with_threads_j(t => t.recent_session_threads(Json::string(key), Json::null()))), "threads")).unwrap_or([])
  if candidates.length() == 0 {
    let error = "配置的模型在现有 Profile 中暂不可用"
    record(
      jo([
        ("purpose", js("archive")),
        ("version", ji(3)),
        ("model", match at(Some(rule), "model") { Some(Null) | None => js(""); Some(m) => m }),
        ("accepted", jb(false)),
        ("elapsedMs", ji(0)),
        ("error", js(error)),
      ]),
    )
    let standing = []
    for t in threads {
      let id = at(at(Some(t), "thread"), "id").unwrap_or(Null)
      standing.push((id, w.with_threads_j(th => th.last_entry(id.to_json()))))
    }
    verdict(standing, jo([("error", js(error))]))
    return
  }
  let started = w.now()
  let versions : Array[(J, J)] = []
  let mut selected = 0
  let reviewed : Result[J, String] = try {
    let conversations = []
    for thread in threads {
      let id = at(at(Some(thread), "thread"), "id").unwrap_or(Null)
      let version = w.with_threads_j(t => t.last_entry(id.to_json()))
      let messages = arr_of(Some(w.with_db_j(db => @readops.latest_messages(db, { "thread": id.to_json(), "limit": Json::number((archive_review_messages + 1).to_double()) }))))
        .unwrap_or([])
        .copy()
      let omitted = messages.length() > archive_review_messages
      if omitted {
        messages.remove(0) |> ignore
      }
      let kept = []
      let mut size = 0
      for i = messages.length() - 1; i >= 0; i = i - 1 {
        let view = shown_message(messages[i])
        size += byte_length(stringify(view))
        if size > archive_review_bytes && kept.length() > 0 {
          break
        }
        kept.push(view)
      }
      let older = messages.length() - kept.length()
      kept.rev_in_place()
      let pending = w.with_db_j(db => @readops.review_pending_card(db, { "thread": id.to_json() }))
      let pending_j = if nullish(Some(pending)) {
        J::Null
      } else {
        let p0 = at_i(Some(pending), 0)
        jo([("ts", at(p0, "ts").unwrap_or(Null)), ("text", at(p0, "text").unwrap_or(Null))])
      }
      conversations.push(
        jo([
          ("thread", id),
          ("messages", ja(kept)),
          ("olderMessagesLeftOut", jb(older > 0 || omitted)),
          ("pendingCard", pending_j),
        ]),
      )
      versions.push((id, version))
    }
    if conversations.length() == 0 {
      raise fail_("archive review has no conversation evidence")
    }
    let state = jo([("agent", js(key)), ("conversations", ja(conversations)), ("attachmentContentsAvailable", jb(false))])
    let mut answer : Result[J, String] = Err("no decision profile available")
    for i in 0..<candidates.length() {
      selected = i
      try {
        answer = Ok(decide(w, candidates[i].1, @jsjson.JValue::of_json(@session_storage.policy_question(policy)), state))
        break
      } catch {
        e => answer = Err(thrown_message(e))
      }
    }
    answer
  } catch {
    e => Err(thrown_message(e))
  }
  let config = candidates[selected].1
  let threshold = at(Some(config), "threshold").unwrap_or(Null)
  let accepted = match reviewed {
    Ok(r) => @session_storage.recommends(r.to_json(), policy, num_of(Some(threshold)).unwrap_or(0.0))
    Err(_) => false
  }
  let picked = match reviewed {
    Ok(r) => {
      let sel = str_of(at(Some(r), "selected"))
      policy.options.search_by(o => Some(o.id) == sel).map(i => policy.options[i])
    }
    Err(_) => None
  }
  let now_rule = at(at(Some(w.config()), "automaticDecisions"), "completion").unwrap_or(Null)
  let mut unchanged = true
  for p in versions {
    if !jeq(w.with_threads_j(t => t.last_entry(p.0.to_json())), p.1) {
      unchanged = false
      break
    }
  }
  unchanged = unchanged &&
    jeq(at(Some(now_rule), "enabled").unwrap_or(Null), at(Some(rule), "enabled").unwrap_or(Null)) &&
    jeq(at(Some(now_rule), "model").unwrap_or(Null), at(Some(rule), "model").unwrap_or(Null)) &&
    jeq(policy_stamp(w, key), policy_at)
  let option = match picked {
    Some(o) => jo([("id", js(o.id)), ("name", js(o.name)), ("archive", jb(o.archive))])
    None => J::Null
  }
  let elapsed = w.now() - started
  record(
    jo([
      ("purpose", js("archive")),
      ("version", ji(3)),
      ("policyAt", policy_at),
      ("option", option),
      ("archiveMass", match reviewed { Ok(r) => jn(@session_storage.archive_mass(r.to_json(), policy)); Err(_) => J::Null }),
      ("profile", candidates[selected].0),
      ("provider", at(Some(config), "provider").unwrap_or(Null)),
      ("model", at(Some(config), "model").unwrap_or(Null)),
      ("threshold", threshold),
      ("elapsedMs", jn(elapsed)),
      ("threads", ja(versions.map(p => ja([p.0, p.1])))),
      ("accepted", jb(accepted && unchanged)),
      ("result", match reviewed { Ok(r) => r; Err(_) => J::Null }),
      ("error", match reviewed { Ok(_) => J::Null; Err(e) => js(e) }),
    ]),
  )
  if !unchanged {
    return
  }
  verdict(
    versions,
    match picked {
      Some(o) =>
        jo([
          ("option", js(o.id)),
          ("name", js(o.name)),
          ("archive", jb(o.archive)),
          ("recommended", jb(accepted)),
        ])
      None => jo([("error", js(match reviewed { Err(e) => e; Ok(_) => "没有判断结果" }))])
    },
  )
  for p in versions {
    try {
      if accepted {
        ignore(w.with_threads_j(t => t.suggest_archive(Json::string(key), p.0.to_json(), p.1.to_json())))
      } else {
        ignore(w.with_threads_j(t => t.clear_archive_suggestion(Json::string(key), p.0.to_json())))
      }
    } catch {
      _ => ()
    }
  }
}

///|
/// The done chats no decision has answered as they stand now.
pub async fn undecided(w : World) -> Array[String] {
  let live = w.with_store(s => s.live_sessions()).map(of_json_j)
  let keys = []
  let policies : Array[(J, J)] = []
  for s in live {
    if at(Some(s), "running") is Some(Bool(true)) {
      continue
    }
    let skey = str_of(at(Some(s), "key")).unwrap_or("")
    let last = w.with_store_j(st => st.last_turn(Json::string(skey)))
    if nullish(Some(last)) || nullish(at(Some(last), "endedAt")) || str_of(at(Some(last), "ending")) != Some("all_done") {
      continue
    }
    if w.with_threads_j(t => t.has_undelivered(Json::string(skey))) is Bool(true) {
      continue
    }
    let ws = policy_ws(w, s)
    let policy = match policies.search_by(p => jeq(p.0, ws)) {
      Some(i) => policies[i].1
      None => {
        let p = match at(at(Some(w.with_threads_j(t => t.archive_policy(ws.to_json()))), "change"), "id") {
          Some(Null) | None => ji(0)
          Some(id) => id
        }
        policies.push((ws, p))
        p
      }
    }
    let threads = arr_of(at(Some(w.with_threads_j(t => t.recent_session_threads(Json::string(skey), Json::null()))), "threads"))
      .unwrap_or([])
      .map(t => at(at(Some(t), "thread"), "id").unwrap_or(Null))
    let decided = w.with_threads_j(t => t.last_decision(Json::string(skey)))
    let decided_at = match at(Some(decided), "policyAt") {
      Some(Null) | None => ji(0)
      Some(x) => x
    }
    let same_policy = jeq(decided_at, policy)
    if threads.length() == 0 {
      continue
    }
    if same_policy {
      let mut all = true
      for id in threads {
        if !(w.with_threads_j(t => t.archive_suggested(id.to_json())) is Bool(true)) {
          all = false
          break
        }
      }
      if all {
        continue
      }
    }
    let seen = arr_of(at(Some(decided), "threads")).unwrap_or([])
    let result = at(Some(decided), "result")
    if !nullish(result) && nullish(at(Some(decided), "error")) && same_policy {
      let mut all = true
      for id in threads {
        let s0 = seen.iter().filter(p => jeq(at_i(Some(p), 0).unwrap_or(Null), id)).last()
        let v = match s0 {
          Some(p) => at_i(Some(p), 1)
          None => None
        }
        let last_entry = w.with_threads_j(t => t.last_entry(id.to_json()))
        let same = match v {
          Some(x) => jeq(x, last_entry)
          None => false
        }
        if !same {
          all = false
          break
        }
      }
      if all {
        continue
      }
    }
    keys.push(skey)
  }
  keys
}

///|
/// Asked from the pages: the sweep started, and how many chats it has to look at (None when no model can be asked).
pub async fn start_review(w : World) -> Double? {
  let enabled = async fn() {
    at(at(at(Some(w.config()), "automaticDecisions"), "completion"), "enabled") is Some(Bool(true))
  }
  if !enabled() || candidates_of(w).length() == 0 {
    return None
  }
  let keys = try {
    undecided(w)
  } catch {
    Thrown("DecisionSessionsUnavailable", _) => {
      w.store("prepareDecisionSessions", []) |> ignore
      if !enabled() || candidates_of(w).length() == 0 {
        return None
      }
      undecided(w)
    }
    e => raise e
  }
  // (the sweep goes on by itself in the station: here it is run to its end before the count is said)
  review_undecided_once(w)
  Some(keys.length().to_double())
}

///|
/// Reviews each undecided chat, one after another (one sweep: asked again while one runs, the station goes over them
/// again after, `reviewUndecided`'s loop).
pub async fn review_undecided_once(w : World) -> Unit {
  let enabled = async fn() {
    at(at(at(Some(w.config()), "automaticDecisions"), "completion"), "enabled") is Some(Bool(true))
  }
  if !enabled() || candidates_of(w).length() == 0 {
    return
  }
  let keys = try {
    undecided(w)
  } catch {
    Thrown("DecisionSessionsUnavailable", _) => {
      w.store("prepareDecisionSessions", []) |> ignore
      if !enabled() || candidates_of(w).length() == 0 {
        return
      }
      undecided(w)
    }
    e => raise e
  }
  for key in keys {
    if !enabled() {
      break
    }
    review(w, key) catch {
      _ => ()
    }
  }
}
