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
}

///|
pub fn Told::nothing() -> Told {
  { sessions: [], threads: [], removed_sessions: [], removed_threads: [], marks: [] }
}

///|
pub fn Told::to_json(self : Told) -> J {
  jo([
    ("sessions", jstrs(self.sessions)),
    ("threads", ja(self.threads.map(jn))),
    ("removedSessions", ja(self.removed_sessions)),
    ("removedThreads", ja(self.removed_threads)),
    ("marks", ja(self.marks)),
  ])
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
