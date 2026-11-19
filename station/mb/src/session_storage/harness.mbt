// This package asked line by line (reader `--builder harness-session-storage`), as station/test/mb-session-storage.test.ts
// asks the TypeScript's on the same files and the same station: each line `{id, op, args}` answered `{id, value}` or
// `{id, error: {kind, message, code}}`; every call of a station's part goes to the test on stdout, `{call: n, name,
// args}`, answered on stdin `{ret: n, value}` or `{ret: n, throw: {kind, message, ...}}`. Asks are taken as they come,
// each in a fiber of its own (one waits on the station while the next is asked).

///|
priv struct Harness {
  host : @host.Host
  waiting : Map[Int, @effect.Deferred[Result[Json, Error]]]
  mut next : Int
}

///|
async fn Harness::call(self : Harness, name : String, args : Array[Json]) -> Json {
  self.next += 1
  let n = self.next
  let done = @effect.Deferred::new()
  self.waiting[n] = done
  self.host.say(jo([("call", ji(n)), ("name", js(name)), ("args", ja(args))]).stringify())
  match done.wait() {
    Ok(v) => v
    Err(e) => raise e
  }
}

///|
fn opt_str(v : Json?) -> String? {
  match v {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
fn strings(v : Json?) -> Array[String] {
  items(v).filter_map(x => if x is String(s) { Some(s) } else { None })
}

///|
fn listed_of(v : Json?) -> Array[Listed] {
  items(v).map(f => { path: str(f, "path").unwrap_or(""), name: str(f, "name").unwrap_or(""), size: num(f, "size").unwrap_or(0.0) })
}

///|
fn profiles_of(v : Json?) -> Array[ProfileHome] {
  items(v).map(p => { id: str(p, "id").unwrap_or(""), runtimes: strings(get(p, "runtimes")), home: str(p, "home").unwrap_or("") })
}

///|
fn pairs_json(pairs : Array[(String, String)]) -> Json {
  ja(pairs.map(p => ja([js(p.0), js(p.1)])))
}

///|
fn named_json(n : Named) -> Json {
  match n {
    Thread(t) => jo([("type", js("thread")), ("thread", t)])
    Session(k, e) => jo([("type", js("session")), ("key", js(k)), ("entry", match e { Some(x) => ji(x); None => Json::null() })])
  }
}

///|
async fn Harness::answer(self : Harness, s : Storage, op : String, a : Array[Json]) -> Json {
  let fs = s.fs
  let arg = (i : Int) => a.get(i)
  let text = (i : Int) => opt_str(arg(i)).unwrap_or("")
  let ws_at = (i : Int) => opt_str(arg(i))
  let peers = async fn(station : String, request : Json) { s.ask("peers.call", [js(station), request]) }
  match op {
    // archive.ts
    "withExtension" => js(fs.with_extension(text(0), text(1)))
    "packFile" => { fs.pack_file(text(0)); Json::null() }
    "segmentFile" => jb(fs.segment_file(text(0)))
    "restoreFile" => { fs.restore_file(text(0)); Json::null() }
    "jsonlFiles" => {
      let out = strings(arg(1))
      fs.jsonl_files(text(0), out)
      ja(out.map(x => js(x)))
    }
    "packWorkspace" => { fs.pack_workspace(text(0)); Json::null() }
    "restoreWorkspace" => { fs.restore_workspace(text(0)); Json::null() }
    "emptyWorkspace" => { fs.empty_workspace(text(0)); Json::null() }
    "holdsMoreRoom" => jb(fs.holds_more(text(0)))
    "workspaceFile" =>
      match fs.with_lock(text(0), async fn() { fs.workspace_file(text(0), text(1), s.reads) }) {
        Some(b) => js(@base64.encode(b))
        None => Json::null()
      }
    "unlockWorktrees" => { fs.unlock_worktrees(text(0)); Json::null() }
    "removeTree" => { fs.remove_tree(text(0)); Json::null() }
    // cold.ts
    "archiveRoom" => {
      s.find_room(text(0))
      jopt(s.archive_room(text(0)))
    }
    "cleanRebuildable" => jn(s.clean_rebuildable(text(0)))
    "historyFiles" => ja(s.history_files(text(0), arg(1) is Some(True)).map(x => js(x)))
    "isCold" => jb(s.is_cold(text(0)))
    "restore" => { s.cold_restore(text(0)); Json::null() }
    "expire" => { s.cold_expire(text(0), as_num(arg(1)).unwrap_or(0.0)); Json::null() }
    "holdsMore" => jb(s.cold_holds_more(text(0)))
    "pack" => { s.cold_pack(text(0)); Json::null() }
    "finishLegacyCopies" => { s.finish_legacy_copies(); Json::null() }
    "segmentHistories" => { s.segment_histories(); Json::null() }
    "roomOf" => jopt(s.room_of(text(0)))
    // archive-policy.ts
    "policyQuestion" => policy_question(checked_policy(arg(0)))
    "archiveMass" => jn(archive_mass(arg(0).unwrap_or(jo([])), checked_policy(arg(1))))
    "recommends" => jb(recommends(arg(0).unwrap_or(jo([])), checked_policy(arg(1)), as_num(arg(2)).unwrap_or(0.0)))
    "checkedPolicy" => checked_policy(arg(0)).to_json()
    "changeSummary" => js(change_summary(checked_policy(arg(0)), checked_policy(arg(1))))
    "policyFrom" => policy_from(arg(0)).to_json()
    "currentPolicy" => s.current_policy(ws_at(0)).to_json()
    "savePolicy" => jopt(s.save_policy(arg(0), arg(1).unwrap_or(Json::null()), ws_at(2)))
    "policyChecks" => {
      let mine = strings(arg(1))
      policy_checks(items(arg(0)), x => arg(1) is (None | Some(Null)) || mine.contains(x))
    }
    "policyView" => s.policy_view(ws_at(0), arg(1).unwrap_or(Json::null()), arg(2))
    "policySince" => jn(policy_since(as_num(arg(0)).unwrap_or(0.0)))
    "defaultPolicy" => default_policy.to_json()
    // chat-archive.ts
    "chatArchive" => js(s.chat_archive(text(0), arg(1).unwrap_or(jo([]))))
    "archiveForPeer" => s.archive_for_peer(arg(0).unwrap_or(Json::null()), ws_at(1))
    // chat-configure.ts
    "chatConfigure" => js(s.chat_configure(text(0), arg(1).unwrap_or(jo([]))))
    "configureForPeer" => s.configure_for_peer(arg(0).unwrap_or(Json::null()), ws_at(1))
    // clones.ts
    "cloneUrl" => js(clone_url(arg(0)))
    "safeUrl" => js(safe_url(text(0)))
    "repoName" => js(repo_name(text(0)))
    "originIn" => jopt(origin_in(text(0)))
    "clonesStart" => {
      let tag = text(3)
      s.clones_start(ws_at(0), arg(1), text(2), async fn() { s.st.tell("clones.changed", [js(tag)]) })
    }
    "clonesDrop" => jb(s.clones_drop(ws_at(0), text(1)))
    "clonesList" => ja(s.clones_list(ws_at(0)))
    "settle" => {
      while s.going.length() > 0 {
        let f = s.going.remove(0)
        ignore(f.wait())
      }
      Json::null()
    }
    // agent-home.ts
    "workspaceAgentHomePath" => js(fs.workspace_agent_home_path(text(0), ws_at(1), ws_at(2)))
    "workspaceAgentHome" => js(s.workspace_agent_home(text(0), ws_at(1), ws_at(2), text(3), ws_at(4)))
    "agentHomes" => ja(fs.agent_homes(text(0)).map(x => js(x)))
    "writeBuiltinSkills" => { s.write_builtin_skills(text(0), arg(1) is Some(True), text(2), ws_at(3), move=!(arg(4) is Some(False))); Json::null() }
    "linkSiteSkills" => { s.link_site_skills(text(0), text(1)); Json::null() }
    "unlinkAgentHome" => { fs.unlink_agent_home(text(0), profiles_of(arg(1))); Json::null() }
    "sessionSkills" => { fs.session_skills(text(0), text(1)); Json::null() }
    "linkTranscripts" => { s.link_transcripts(text(0), profiles_of(arg(1))); Json::null() }
    // others.ts
    "linkedSession" =>
      match linked_session(text(0)) {
        Some((k, e)) => ja([js(k), match e { Some(x) => ji(x); None => Json::null() }])
        None => Json::null()
      }
    "linkedStation" => jopt(linked_station(text(0)))
    "linkedWorkspace" => jopt(linked_workspace(text(0)))
    "splitN" => ja(split_n(text(0), text(1), as_num(arg(2)).unwrap_or(0.0).to_int()).map(x => js(x)))
    "formatSteps" => js(format_steps(as_num(arg(0)).unwrap_or(0.0).to_int(), items(arg(1)), as_num(arg(2)).unwrap_or(0.0).to_int()))
    "fromBefore" => jb(from_before(text(0)))
    "named" => named_json(s.named(text(0), ws_at(1), write=arg(2) is Some(True)))
    "sessionThreadOf" => s.session_thread_of(text(0))
    "reachable" => jb(s.reachable(text(0), ws_at(1), write=arg(2) is Some(True)))
    "threadIn" => jb(s.thread_in(arg(0).unwrap_or(Json::null()), ws_at(1)))
    "scopeOf" => jopt(s.scope_of(text(0)))
    "elsewhere" => jopt(s.elsewhere(text(0), text(1)))
    "readAfar" => js(s.read_afar(text(0), text(1), text(2), arg(3).unwrap_or(jo([]))))
    "forPeer" => s.for_peer(text(0), arg(1).unwrap_or(Json::null()), ws_at(2))
    "chatsTouched" => ja(s.chats_touched(arg(0).unwrap_or(Json::null())).map(x => js(x)))
    "chatList" => js(s.chat_list(text(0), arg(1).unwrap_or(jo([]))))
    "listForPeer" => s.list_for_peer(arg(0).unwrap_or(Json::null()), ws_at(1))
    "chatRead" => {
      let seen = []
      let t = s.chat_read(text(0), arg(1).unwrap_or(jo([])), if arg(2) is Some(True) { Some(seen) } else { None }, ws_at(3))
      jo([("text", js(t)), ("seen", ja(seen))])
    }
    "sessionHistory" => js(s.session_history(arg(0).unwrap_or(jo([])), ws_at(1)))
    // peer-files.ts
    "fileForPeer" => s.file_for_peer(arg(0).unwrap_or(Json::null()), ws_at(1))
    "fetchAttachments" => {
      let (here, left) = s.fetch_attachments(text(0), peers, text(1), text(2), listed_of(arg(3)), strings(arg(4)))
      jo([("here", pairs_json(here)), ("left", ja(left.map(x => js(x))))])
    }
    "sendable" => ja(s.sendable(text(0), strings(arg(1))).map(f => jo([("path", js(f.path)), ("name", js(f.name)), ("size", jn(f.size))])))
    "sendAlong" => {
      let sent = s.send_along(peers, text(0), text(1), text(2), listed_of(arg(3)))
      ja(sent.map(p => jo([("id", js(p.0)), ("name", js(p.1))])))
    }
    "putForPeer" => s.put_for_peer(text(0), arg(1).unwrap_or(Json::null()), ws_at(2))
    "claim" => ja(s.claim(text(0), text(1), text(2), arg(3)))
    // relay.ts
    "relayPlaces" => ja(s.relay_places(arg(0).unwrap_or(Json::null())))
    "relayPeople" => s.relay_people(arg(0).unwrap_or(Json::null()), arg(1).unwrap_or(Json::null()))
    "mentioned" => js(mentioned(text(0), items(arg(1)), id => "<m:\{id}>"))
    "relay" => s.relay(arg(0).unwrap_or(Json::null()), arg(1).unwrap_or(Json::null()), arg(2).unwrap_or(Json::null()), text(3))
    // text
    "iso" => js(iso(as_num(arg(0)).unwrap_or(0.0)))
    "percentDecode" => js(percent_decode(text(0)))
    "parseThreadAddress" =>
      match parse_thread_address(text(0)) {
        Some((c, t)) => ja([js(c), js(t)])
        None => Json::null()
      }
    _ => raise failed("no op \{op}")
  }
}

///|
fn error_json(e : Error) -> Json {
  let fields = [("message", js(message_of(e)))]
  match e {
    Thrown(kind, said) => {
      fields.push(("kind", js(kind)))
      match get(said, "code") {
        Some(c) => fields.push(("code", c))
        None => ()
      }
    }
    _ => fields.push(("kind", js("Error")))
  }
  jo(fields)
}

///|
pub async fn harness(host : @host.Host) -> Unit {
  let h : Harness = { host, waiting: {}, next: 0 }
  let s = Storage::new(Station::new((name, args) => h.call(name, args)), Files::new(host))
  while host.line() is Some(line) {
    let said = @json.parse(line) catch { _ => continue }
    match said {
      { "ret": Number(n, ..), .. } =>
        match h.waiting.get(n.to_int()) {
          Some(done) => {
            h.waiting.remove(n.to_int())
            match get(said, "throw") {
              Some(t) => ignore(done.succeed(Err(Thrown(str(t, "kind").unwrap_or("Error"), t))))
              None => ignore(done.succeed(Ok(get(said, "value").unwrap_or(jundef))))
            }
          }
          None => ()
        }
      { "op": String(op), .. } => {
        let id = get(said, "id").unwrap_or(Json::null())
        let args = items(get(said, "args"))
        ignore(
          host.rt.fork(name="harness ask", async fn() {
            let out = try h.answer(s, op, args) catch {
              e => jo([("id", id), ("error", error_json(e))])
            } noraise {
              v => jo([("id", id), ("value", v)])
            }
            host.say(out.stringify())
          }),
        )
      }
      _ => ()
    }
  }
}
