// What the agents spent (usage/module.ts `UsageLive`), as the hub keeps it (session_hub usage.mbt: the counter, the
// drain of moved sessions' chats, the old statistics' retirement) and asks the station for: the transcripts read by the
// counter's program (`--builder usage-counter`, usage/counter-mb.ts: started at a read, let go IDLE_MS idle), the moved
// sessions' chats a batch at a time (usage-chat-stats.ts `drainUsageChatDirty`), the old statistics' writers stopped
// once the station before has gone and then freed and taken in by `--builder usage-retire` a step at a time.

///|
/// A program of the reader's asked a line at a time, its answers a line each, in the order asked (read/mb-reader.ts
/// `MbProcess` as usage/counter-mb.ts and `MbBackfill` use it).
priv struct LineProgram {
  host : @host.Host
  argv0 : String
  args : Array[String]
  name : String
  background : Bool
  mut proc : Proc?
  waiting : Array[@effect.Deferred[Result[Json, String]]]
  mut idle : @effect.Fiber[Unit]?
  idle_ms : Int?
}

///|
fn LineProgram::new(host : @host.Host, argv0 : String, args : Array[String], name : String, idle_ms? : Int, background? : Bool = false) -> LineProgram {
  { host, argv0, args, name, background, proc: None, waiting: [], idle: None, idle_ms }
}

///|
fn LineProgram::started(self : LineProgram) -> Proc raise {
  match self.idle {
    Some(f) => {
      f.interrupt()
      self.idle = None
    }
    None => ()
  }
  if self.proc is Some(p) { return p }
  let (program, args) = if self.background {
    backgrounded(self.argv0, self.args)
  } else {
    (self.argv0, self.args)
  }
  let p = spawn_lines(
    self.host,
    program,
    args,
    self.name + "'s lines",
    (_, line) => {
      if line == "" { return }
      let answer = @json.parse(line) catch { _ => Json::string(line) }
      if self.waiting.length() > 0 {
        ignore(self.waiting.remove(0).succeed(Ok(answer)))
      }
      self.idle_soon()
    },
    (p, code) =>
      if self.proc is Some(now) && physical_equal(now, p) {
        self.proc = None
        let why = "\{self.name} stopped (exit \{match code { Some(c) => c.to_string(); None => "null" }})"
        for w in self.waiting { ignore(w.succeed(Err(why))) }
        self.waiting.clear()
      },
  )
  self.proc = Some(p)
  p
}

///|
fn LineProgram::idle_soon(self : LineProgram) -> Unit {
  guard self.idle_ms is Some(ms) && self.waiting.length() == 0 && self.idle is None else { return }
  let p = self.proc
  self.idle = Some(
    self.host.rt.fork(name=self.name + " idle", async fn() {
      @effect.sleep(ms) // timer: a deadline (an idle program's process let go)
      self.idle = None
      if self.waiting.length() == 0 {
        match (self.proc, p) {
          (Some(now), Some(was)) if physical_equal(now, was) => self.close()
          _ => ()
        }
      }
    }),
  )
}

///|
/// One ask, its answer.
async fn LineProgram::ask(self : LineProgram, message : Json) -> Json {
  let p = self.started() catch { e => raise LiveError("\{self.name} did not start: \{said_of(e)}") }
  let d : @effect.Deferred[Result[Json, String]] = @effect.Deferred::new()
  self.waiting.push(d)
  ignore(p.write(@utf8.encode(message.stringify() + "\n")))
  match d.wait() {
    Ok(v) => v
    Err(why) => raise LiveError(why)
  }
}

///|
/// Its process let go where nothing is asked of it (resources' `trimIdle`): 1 where it was, else 0.
fn LineProgram::trim_idle(self : LineProgram) -> Int {
  if self.proc is Some(_) && self.waiting.length() == 0 {
    self.close()
    1
  } else {
    0
  }
}

///|
fn LineProgram::pid(self : LineProgram) -> Int? {
  self.proc.map(p => p.pid)
}

///|
/// Its process let go and what waits on it failed. `force`: killed at once (the station stopping or handing over, as
/// `LiveLocator::retire`), not left to end on SIGTERM.
fn LineProgram::close(self : LineProgram, force? : Bool = false) -> Unit {
  if self.idle is Some(f) {
    f.interrupt()
    self.idle = None
  }
  if self.proc is Some(p) {
    self.proc = None
    p.end_input()
    ignore(kill(p.pid, if force { "SIGKILL" } else { "SIGTERM" }))
  }
  for w in self.waiting {
    ignore(w.succeed(Err("\{self.name} stopped")))
  }
  self.waiting.clear()
}

///|
/// transcript.ts `allTranscriptHints`: every hint kept here, for the counter's program.
fn all_transcript_hints() -> Json {
  let h = transcript_hints
  {
    "elsewhere": Json::array(h.elsewhere.to_array().map(kv => Json::array([Json::string(kv.0), jopt(kv.1)]))),
    "rollouts": Json::array(h.rollouts.to_array().map(kv => Json::array([Json::string(kv.0), Json::string(kv.1)]))),
    "said": Json::array(
      h.said
      .to_array()
      .map(kv => Json::array([
        Json::string(kv.0),
        Json::array(
          kv.1.to_array().map(d => Json::array([Json::string(d.0), { "suffix": Json::string(d.1.suffix), "seen": Json::boolean(d.1.seen) }])),
        ),
      ])),
    ),
  }
}

///|
/// transcript.ts `takeTranscriptHints`: what the counter's program found, kept.
fn take_transcript_hints(found : Json) -> Unit {
  let h = transcript_hints
  let id_of = (key : String) => match key.find("\u{0}") {
    Some(i) => key[i + 1:].to_owned()
    None => key
  }
  for pair in jitems(jfield(found, "elsewhere")) {
    match pair {
      Array([String(key), p]) => {
        let path = as_text(p)
        if h.elsewhere.get(key) != Some(path) {
          h.elsewhere[key] = path
          h.changed(id_of(key))
        }
      }
      _ => ()
    }
  }
  for pair in jitems(jfield(found, "rollouts")) {
    guard pair is Array([String(key), String(path)]) else { continue }
    if h.rollouts.get(key) != Some(path) {
      h.rollouts[key] = path
      h.changed(id_of(key))
    }
  }
  for said in jitems(jfield(found, "said")) {
    guard said is Array([String(id), Array(dirs)]) else { continue }
    for d in dirs {
      guard d is Array([String(dir), entry]) else { continue }
      match h.said.get(id).bind(m => m.get(dir)) {
        Some(old) if Some(old.suffix) == jtext(entry, "suffix") && jfield(entry, "seen") is True && !old.seen => {
          old.seen = true
          h.changed(id)
        }
        _ => ()
      }
    }
  }
}

///|
/// The counter's program and the retirement's, made as they are first asked.
let usage_counter_program : Ref[LineProgram?] = Ref(None)

///|
let usage_retire_program : Ref[LineProgram?] = Ref(None)

///|
let usage_reads : Ref[Int] = Ref(0)

///|
/// usage-chat-stats.ts `drainUsageChatDirty`: one transaction of the chats of a session that moved, given its new
/// workspace; `done` where none waits.
fn drain_usage_chat_dirty(db : @sql.Db, limit : Int) -> Json raise {
  db.exec("BEGIN IMMEDIATE")
  let r : Json = try {
    let dirty = db.all("SELECT session, thread_after FROM usage_chat_dirty ORDER BY session LIMIT 1", [])
    match dirty.get(0) {
      None => ({ "done": true, "processed": 0 } : Json)
      Some(d) => {
        let session = d.get("session").unwrap_or(Json::null())
        let ws = match db.all("SELECT ws FROM sessions WHERE key = ?", [session]).get(0) {
          Some(row) => (row.get("ws").unwrap_or(Json::null()), 1)
          None => (Json::null(), 0)
        }
        let rows = match d.get("thread_after") {
          Some(Null) | None =>
            db.all(
              "SELECT thread FROM usage_chat_members INDEXED BY usage_chat_members_session WHERE session = ? ORDER BY thread LIMIT ?",
              [session, ji(limit)],
            )
          Some(after) =>
            db.all(
              "SELECT thread FROM usage_chat_members INDEXED BY usage_chat_members_session WHERE session = ? AND thread > ? ORDER BY thread LIMIT ?",
              [session, after, ji(limit)],
            )
        }
        let present = ji(ws.1)
        for row in rows {
          let thread = row.get("thread").unwrap_or(Json::null())
          ignore(
            db.run(
              "UPDATE usage_chat_members SET ws = ?, present = ? WHERE session = ? AND thread = ? AND (ws IS NOT ? OR present IS NOT ?)",
              [ws.0, present, session, thread, ws.0, present],
            ),
          )
        }
        if rows.length() < limit {
          ignore(db.run("DELETE FROM usage_chat_dirty_scope WHERE session = ?", [session]))
          ignore(db.run("DELETE FROM usage_chat_dirty WHERE session = ?", [session]))
        } else {
          ignore(db.run("UPDATE usage_chat_dirty SET thread_after = ? WHERE session = ?", [rows[rows.length() - 1].get("thread").unwrap_or(Json::null()), session]))
        }
        let done = db.all("SELECT 1 FROM usage_chat_dirty LIMIT 1", []).length() == 0
        ({ "done": Json::boolean(done), "processed": ji(rows.length()) } : Json)
      }
    }
  } catch {
    e => {
      db.exec("ROLLBACK") catch {
        _ => ()
      }
      raise e
    }
  }
  db.exec("COMMIT")
  r
}

///|
/// usage/module.ts `tryStopUsageIndexes`: the contexts kept with the station's own writers and the old statistics'
/// writers stopped, without waiting behind another connection; false where one held the database.
fn try_stop_usage_indexes(db : @sql.Db) -> Bool raise {
  let timeout = match db.all("PRAGMA busy_timeout", []).get(0) {
    Some(r) =>
      opt_num(r.get("timeout")).map(n => n.to_int()).unwrap_or(5000)
    None => 5000
  }
  db.exec("PRAGMA busy_timeout = 0")
  let r = try {
    @store_schema.install_compact_usage(db) catch {
      e => {
        if @sql.busy(e) {
          raise e
        }
        // (even where the contexts cannot be kept, the old per-call writers are not left running)
        slice_log("warn", "usage", "the usage contexts could not be installed", { "error": jstr(said_of(e)) })
      }
    }
    @store_schema.stop_usage_indexes(db)
    true
  } catch {
    e => {
      db.exec("PRAGMA busy_timeout = \{timeout}") catch {
        _ => ()
      }
      if @sql.busy(e) {
        return false
      }
      raise e
    }
  }
  db.exec("PRAGMA busy_timeout = \{timeout}")
  r
}

///|
/// What the hub's usage asks of the station (session_hub usage.mbt's world).
async fn P52::usage_ask(self : P52, what : String, args : Json) -> Json {
  let db = self.bus.db
  let db_path = path([self.data, "stillfail.db"])
  match what {
    "usage.read" => {
      // (none started again once the station stopped or handed over: close_helpers let the last one go)
      if self.closed {
        raise LiveError("the station is closed")
      }
      let program = match usage_counter_program.val {
        Some(p) => p
        None => {
          let p = LineProgram::new(
            self.host,
            self.bus.argv0,
            ["--builder", "usage-counter", "--db", db_path, "--sep", sep()],
            "the usage counter's program",
            idle_ms=60000,
            background=true,
          )
          usage_counter_program.val = Some(p)
          p
        }
      }
      usage_reads.val += 1
      let ask = match args {
        Object(m) => m.copy()
        _ => {}
      }
      ask["id"] = ji(usage_reads.val)
      ask["op"] = "read"
      ask["hints"] = all_transcript_hints()
      let answer = program.ask(Json::object(ask))
      match jfield(answer, "error") {
        String(e) => raise LiveError(e)
        _ => ()
      }
      take_transcript_hints(jfield(answer, "hints"))
      answer
    }
    "usage.drainStep" =>
      drain_usage_chat_dirty(
        db,
        match args {
          Number(n, ..) => n.to_int()
          _ => 32
        },
      )
    "usage.stopIndexes" => Json::boolean(try_stop_usage_indexes(db))
    // (the station's store is a file: what a database in memory cannot have retired does not arise)
    "usage.inMemory" => Json::boolean(false)
    "usage.retireStep" => {
      if self.closed {
        raise LiveError("the station is closed")
      }
      let program = match usage_retire_program.val {
        Some(p) => p
        None => {
          let p = LineProgram::new(self.host, self.bus.argv0, ["--builder", "usage-retire", "--db", db_path], "usage retirement", background=true)
          usage_retire_program.val = Some(p)
          p
        }
      }
      let answer = program.ask(args)
      match jfield(answer, "error") {
        String(e) => raise LiveError(e)
        _ => ()
      }
      if jfield(answer, "done") is True && !(jfield(args, "drop") is True) {
        program.close()
        usage_retire_program.val = None
      }
      answer
    }
    _ => raise LiveError("the usage asks nothing called \{what}")
  }
}

///|
/// usage/module.ts `UsageLive`: the counter started with the hub; once the station before has gone, the moved sessions'
/// chats drained and the old statistics retired.
async fn P52::start_usage(self : P52) -> Unit {
  guard self.hub is Some(hub) else { return }
  hub.usage_start() catch {
    e => slice_log("warn", "usage", "the usage counter did not start", { "error": jstr(said_of(e)) })
  }
  fork_bg(self.host, "usage after the station before", async fn() {
    (self.bus.previous_gone)()
    hub.usage_drain()
    hub.retire_usage() catch {
      e => slice_log("warn", "usage", "the old usage statistics were not retired", { "error": jstr(said_of(e)) })
    }
  })
}
