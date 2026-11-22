// Where the export's work runs (runner.ts): station/replica's `Exporter`, in this program, asked a step at a time.
// What the export is told (export.ts `Told`) and says (`Passed` with `empty`) are as the TypeScript has them.

///|
pub(all) struct Runner {
  places : async (J) -> Unit
  pass : async (J) -> J
  new_generations : async (Double) -> Unit
  sources : async (Array[String]) -> J
  close : async () -> Unit
}

///|
/// The export of the station whose database is `db` (replica's `Exporter`), made as it is first asked and made again
/// after one that failed to be made; told the workspaces again then.
pub fn program_runner(fs : Fs, db : String, replica : String, data : String, origin : String, now : () -> Double) -> Runner {
  let exporter : Ref[@replica.Exporter?] = Ref(None)
  let places : Ref[J?] = Ref(None)
  let closed = Ref(false)
  let get = () => {
    if closed.val {
      raise failed("the copies' thread is closed")
    }
    match exporter.val {
      Some(e) => e
      None => {
        let e = @replica.Exporter::new(fs.host, fs.sep, db, replica, data, origin, now) catch {
          x => raise failed("the copies' thread failed: \{message_of(x)}")
        }
        match places.val {
          Some(p) => e.set_places(p)
          None => ()
        }
        exporter.val = Some(e)
        e
      }
    }
  }
  {
    places: async fn(p) {
      places.val = Some(p)
      get().set_places(p)
    },
    pass: async fn(told) { get().pass(told) },
    new_generations: async fn(after) { get().new_generations(after) },
    sources: async fn(hashes) { get().sources(hashes) },
    close: async fn() {
      match exporter.val {
        Some(e) => e.close()
        None => ()
      }
      exporter.val = None
      closed.val = true
    },
  }
}

///|
/// What the store said changed since the last pass (export.ts `Told`).
pub struct Told {
  sessions : Array[String]
  threads : Array[Double]
  removed_sessions : Array[J]
  removed_threads : Array[J]
  marks : Array[J]
  mut transcripts : Bool
}

///|
pub fn Told::nothing() -> Told {
  { sessions: [], threads: [], removed_sessions: [], removed_threads: [], marks: [], transcripts: false }
}

///|
pub fn Told::to_json(self : Told) -> J {
  let fields : Array[(String, J)] = [
    ("sessions", jstrs(self.sessions)),
    ("threads", ja(self.threads.map(jn))),
    ("removedSessions", ja(self.removed_sessions)),
    ("removedThreads", ja(self.removed_threads)),
    ("marks", ja(self.marks)),
  ]
  if self.transcripts {
    fields.push(("transcripts", jb(true)))
  }
  jo(fields)
}

///|
/// The store's change put into `t`, what the next pass is to read again (copies.ts `tell`); false where it says
/// nothing of what is copied.
pub fn tell(t : Told, change : J) -> Bool {
  let key = (k : String) => js(text_at(change, k))
  let ws = () => match at(change, "ws") {
    Some(Str(u)) => J::Str(u)
    _ => J::Null
  }
  let mark = (table : String, fields : Array[(String, J)]) => t.marks.push(jo([("table", js(table)), ("key", jo(fields))]))
  match str_at(change, "type") {
    Some("session") | Some("conversation") => {
      t.sessions.push(text_at(change, "key"))
      true
    }
    Some("sessionRemoved") => {
      t.removed_sessions.push(jo([("key", key("key")), ("ws", ws())]))
      true
    }
    Some("thread") => {
      // (its entries are found by their rowid; only what else of it changed is read by its id)
      if items(at(change, "entries")).length() == 0 || !(at(change, "closed") is None) {
        t.threads.push(num_at(change, "id").unwrap_or(0.0))
      }
      true
    }
    Some("letters") => true
    Some("threadRemoved") => {
      t.removed_threads.push(jo([("id", at(change, "id").unwrap_or(Null)), ("ws", ws())]))
      true
    }
    Some("read") => {
      mark("reads", [("viewer", at(change, "viewer").unwrap_or(Null)), ("thread", at(change, "thread").unwrap_or(Null))])
      true
    }
    Some("hidden") => {
      mark("hidden_chats", [("viewer", at(change, "viewer").unwrap_or(Null)), ("thread", at(change, "thread").unwrap_or(Null))])
      true
    }
    Some("muted") => {
      mark("muted_chats", [("viewer", at(change, "viewer").unwrap_or(Null)), ("thread", at(change, "thread").unwrap_or(Null))])
      true
    }
    Some("pins") => {
      match at(change, "session") {
        Some(s) => mark("pins", [("viewer", at(change, "viewer").unwrap_or(Null)), ("session", s)])
        None => ()
      }
      true
    }
    Some("dismissed") => {
      match at(change, "card") {
        Some(card) =>
          mark("dismissed", [
            ("viewer", at(change, "viewer").unwrap_or(Null)),
            ("thread", at(card, "thread").unwrap_or(Null)),
            ("n", at(card, "n").unwrap_or(Null)),
          ])
        None => ()
      }
      match at(change, "kept") {
        Some(kept) => mark("kept_chats", [("viewer", at(change, "viewer").unwrap_or(Null)), ("thread", at(kept, "thread").unwrap_or(Null))])
        None => ()
      }
      true
    }
    Some("chatMark") => {
      if !(at(change, "opened") is None) {
        t.sessions.push(text_at(change, "session"))
      }
      match at(change, "thread") {
        Some(Null) | None => ()
        Some(n) => t.threads.push(num_of(Some(n)).unwrap_or(0.0))
      }
      true
    }
    _ => false
  }
}

///|
/// What an export in a process of its own says next (`--builder replica-export`): a piece of its stdout, something
/// else (its stderr), or its end, its code and signal.
pub(all) enum ExportSaid {
  Said(Bytes)
  Other
  Ended(Int?, String?)
}

///|
/// An export's process as the runner asks it: a line written to its stdin (false where it takes no more), its stdin
/// closed, what it says next.
pub(all) struct ExportProcess {
  write : (Bytes) -> Bool
  end_input : () -> Unit
  next : async () -> ExportSaid
}

///|
priv struct Running {
  p : ExportProcess
  /// What it said past its last whole line.
  pending : @buffer.Buffer
  mut ended : Bool
}

///|
/// The export in a process of its own (replica/runner.ts `exportThread`), `start`ed as it is first asked and again at
/// the next ask after one that ended, told the workspaces again. Asked a step at a time on its stdin, `{id, type, now,
/// …}`, answered `{id, answer}` or `{id, error}` a line each, one ask at a time. What it says is read only by whoever
/// holds the turn (`one`), its end too: `close` tells it to end and waits its turn for that end, so an ask reading it
/// meanwhile is answered by the end and the end is never taken from under the close (its process left running).
pub fn process_runner(start : () -> ExportProcess raise, now : () -> Double) -> Runner {
  let proc : Ref[Running?] = Ref(None)
  let places : Ref[J?] = Ref(None)
  let closed = Ref(false)
  let next = Ref(0)
  let one = @effect.Semaphore::new(1)
  let gone = (r : Running) => if proc.val is Some(x) && physical_equal(x, r) { proc.val = None }
  let line_of = async fn(r : Running) -> String {
    while true {
      let had = r.pending.to_bytes()
      let mut nl : Int? = None
      for i = 0; i < had.length(); i = i + 1 {
        if had[i] == b'\n' {
          nl = Some(i)
          break
        }
      }
      if nl is Some(i) {
        let line = @utf8.decode_lossy(had[0:i].to_owned())
        let rest = had[i + 1:].to_owned()
        r.pending.reset()
        r.pending.write_bytes(rest)
        return line
      }
      if r.ended {
        raise failed("the copies' export ended")
      }
      match (r.p.next)() {
        Said(b) => r.pending.write_bytes(b)
        Other => ()
        Ended(code, signal) => {
          r.ended = true
          gone(r)
          r.pending.reset()
          let c = match code {
            Some(c) => c.to_string()
            None => "null"
          }
          raise failed("the copies' export ended (\{c}, \{signal.unwrap_or("null")})")
        }
      }
    }
    ""
  }
  let ask_now = async fn(r : Running, kind : String, fields : Array[(String, J)]) -> J {
    next.val += 1
    let id = next.val
    let asked_fields = [("id", ji(id)), ("type", js(kind)), ("now", jn(now()))]
    asked_fields.append(fields)
    let asked = jo(asked_fields)
    if !(r.p.write)(@utf8.encode(stringify(asked) + "\n")) {
      gone(r)
      raise failed("the copies' export took nothing more")
    }
    while true {
      let line = line_of(r)
      guard (try Some(parse(line)) catch { _ => None }) is Some(said) else { continue }
      if at(said, "failed") is Some(Str(why)) {
        gone(r)
        raise failed("the copies' thread failed: \{@jsjson.sanitize_str(why)}")
      }
      guard at(said, "id") is Some(Num(n)) && n == id.to_double() else { continue }
      match at(said, "error") {
        Some(Str(e)) => raise failed(@jsjson.sanitize_str(e))
        _ => return at(said, "answer").unwrap_or(Null)
      }
    }
    Null
  }
  let started = async fn() -> Running {
    if closed.val {
      raise failed("the copies' thread is closed")
    }
    match proc.val {
      Some(r) => r
      None => {
        let r : Running = { p: start(), pending: @buffer.new(), ended: false }
        proc.val = Some(r)
        if places.val is Some(pl) {
          ignore(ask_now(r, "places", [("places", pl)]))
        }
        r
      }
    }
  }
  let ask = async fn(kind : String, fields : Array[(String, J)]) -> J {
    one.with_permit(async fn() { ask_now(started(), kind, fields) })
  }
  {
    places: async fn(p) {
      places.val = Some(p)
      ignore(ask("places", [("places", p)]))
    },
    pass: async fn(told) { ask("pass", [("told", told)]) },
    new_generations: async fn(after) { ignore(ask("newGenerations", [("after", jn(after))])) },
    sources: async fn(hashes) { ask("sources", [("hashes", jstrs(hashes))]) },
    close: async fn() {
      closed.val = true
      guard proc.val is Some(r) else { return }
      proc.val = None
      ignore((r.p.write)(@utf8.encode("{\"id\":0,\"type\":\"close\"}\n")))
      (r.p.end_input)()
      // (its end waited for in turn: an ask reading it now is answered by that end, then it is here)
      one.with_permit(async fn() {
        while !r.ended {
          if (r.p.next)() is Ended(_, _) {
            r.ended = true
          }
        }
      })
    },
  }
}
