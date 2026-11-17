// The jobs module (station/src/move/jobs.ts; move/AGENTS.md): an item is one job or service a chat had running
// (`<session>#<name>`). A chat held has its jobs stopped and kept here (`move/jobs.log`, a line a change), so that a job
// runs on one station at a time; moving it starts it there once its chat is there (`move.job.start`); moving it back
// stops it there and starts it here. A chat whose move failed, or that goes on here, has its kept jobs started again.

///|
/// A job's item id (`<session>#<name>`) of a carried job (replica/carry.ts `CarriedJob`, a JSON object).
pub fn job_item_id(j : J) -> String {
  "\{text(get(Some(j), "session")).unwrap_or("")}#\{text(get(Some(j), "name")).unwrap_or("")}"
}

///|
pub(all) struct JobsDeps {
  data : String
  disk : Disk
  /// The jobs and services of sessions `keys` (None: of `ws`'s chats) up now, each with its `id` (a carried job and it).
  up : async (Array[String]?, String?) -> Array[J]
  stop : async (String, String) -> Unit
  start : async (J) -> Unit
  chat_of : async (String) -> String
  ask : async (String, J) -> J
  here : () -> String
  clock : Clock
  say : Say
}

///|
pub struct Jobs {
  priv d : JobsDeps
  priv k : KeptLog
  priv kept_of : Map[String, Array[String]]
  priv moving : Set[String]
}

///|
pub fn Jobs::new(d : JobsDeps) -> Jobs {
  let k = KeptLog::new(
    d.disk,
    @nodepath.join("/", [d.data, "move", "jobs.log"]),
    from=(@nodepath.join("/", [d.data, "move", "jobs.json"]), raw => {
      let out = []
      for j in arr(get(Some(raw), "kept")).unwrap_or([]) {
        out.push((job_item_id(j), jo([("kept", j)])))
      }
      for m in arr(get(Some(raw), "moved")).unwrap_or([]) {
        let job = get(Some(m), "job").unwrap_or(jo([]))
        out.push((
          job_item_id(job),
          jo([("moved", job), ("to", get(Some(m), "to").unwrap_or(Null))]),
        ))
      }
      out
    }),
  )
  let jobs = { d, k, kept_of: {}, moving: Set::new() }
  for v in k.values() {
    match get(Some(v), "kept") {
      Some(j) => jobs.index(j, true)
      None => ()
    }
  }
  jobs
}

///|
fn Jobs::index(self : Jobs, j : J, kept : Bool) -> Unit {
  let session = text(get(Some(j), "session")).unwrap_or("")
  let set = self.kept_of.get(session).unwrap_or([])
  let id = job_item_id(j)
  if kept {
    if !set.contains(id) {
      set.push(id)
    }
  } else {
    match set.search(id) {
      Some(i) => ignore(set.remove(i))
      None => ()
    }
  }
  if set.length() > 0 {
    self.kept_of[session] = set
  } else {
    self.kept_of.remove(session)
  }
}

///|
fn Jobs::kept(self : Jobs, id : String) -> J? {
  get(self.k.get(id), "kept")
}

///|
fn Jobs::moved(self : Jobs, id : String) -> (J, String)? {
  let k = self.k.get(id)
  match get(k, "moved") {
    Some(j) => Some((j, text(get(k, "to")).unwrap_or("")))
    None => None
  }
}

///|
/// Job `j` kept here, stopped (`Some(None)`), moved there (`Some(Some(to))`), or neither (`None`): its line written.
async fn Jobs::put(self : Jobs, j : J, kept : Bool, to : String?) -> Unit {
  let id = job_item_id(j)
  self.index(j, kept)
  if kept {
    self.k.set(id, jo([("kept", j)]))
  } else {
    match to {
      Some(t) => self.k.set(id, jo([("moved", j), ("to", js(t))]))
      None => self.k.delete(id)
    }
  }
}

///|
/// The jobs of `keys` up now stopped and kept (a chat held).
pub async fn Jobs::keep(self : Jobs, keys : Array[String], why : String) -> Array[J] {
  let up = (self.d.up)(Some(keys), None)
  for j in up {
    let job = del(j, "id")
    if self.kept(job_item_id(job)) is None {
      self.put(job, true, None)
    }
  }
  for j in up {
    let id = text(get(Some(j), "id")).unwrap_or("")
    (self.d.stop)(id, why) catch {
      e =>
        self.d.say.log(
          "warn",
          "a job not stopped",
          jo([("job", js(id)), ("error", js(message_of(e)))]),
        )
    }
  }
  up.map(j => del(j, "id"))
}

///|
/// The kept jobs of `keys` started here again (their chat goes on here).
pub fn Jobs::start_kept(self : Jobs, keys : Array[String]) -> Unit {
  let mine = []
  for k in keys {
    for id in self.kept_of.get(k).unwrap_or([]).copy() {
      match self.kept(id) {
        Some(j) => mine.push(j)
        None => ()
      }
    }
  }
  for j in mine {
    // (the log's line let go now, as the TypeScript's `#put` sets the index at once)
    self.index(j, false)
    let write = match self.k.delete_soon(job_item_id(j)) {
      Some(w) => w
      None => continue
    }
    (self.d.clock.spawn)(async fn() {
      write() catch {
        e =>
          self.d.say.log(
            "warn",
            "a job started again here not written so",
            jo([("job", get(Some(j), "name").unwrap_or(Null)), ("error", js(message_of(e)))]),
          )
      }
    })
  }
  for j in mine {
    self.start_here(j)
  }
}

///|
fn Jobs::start_here(self : Jobs, j : J) -> Unit {
  (self.d.clock.spawn)(async fn() {
    (self.d.start)(j) catch {
      e =>
        self.d.say.log(
          "warn",
          "a job not started again here",
          jo([("job", get(Some(j), "name").unwrap_or(Null)), ("error", js(message_of(e)))]),
        )
    }
  })
}

///|
/// The jobs module's seam.
pub fn Jobs::module(self : Jobs) -> Module {
  {
    id: "jobs",
    needs: ["chats"],
    plan: async fn(ws, _to, _reads) {
      let items = []
      let seen : Set[String] = Set::new()
      let add = async fn(j : J) {
        let id = job_item_id(j)
        if seen.contains(id) {
          return
        }
        seen.add(id)
        let label = "\{text(get(Some(j), "name")).unwrap_or("undefined")} (\{text(get(Some(j), "command")).unwrap_or("undefined")})"
        let chat = (self.d.chat_of)(text(get(Some(j), "session")).unwrap_or(""))
        items.push(new_item("jobs", id, label, [{ module: "chats", id: chat }]))
      }
      for j in (self.d.up)(None, Some(ws)) {
        add(j)
      }
      for k in self.k.values() {
        match get(Some(k), "kept") {
          Some(j) => add(j)
          None => add(get(Some(k), "moved").unwrap_or(jo([])))
        }
      }
      items
    },
    move: async fn(item, to, _progress, _arrive) {
      let id = item_id(item)
      let session = slice(id, 0, index_of(id, "#"))
      let job = match self.kept(id) {
        Some(j) => j
        None => {
          let up = (self.d.up)(Some([session]), None)
          match up.search_by(j => job_item_id(j) == id) {
            Some(i) => up[i]
            None => raise Failed("job \{item_label(item)} is not kept here")
          }
        }
      }
      self.moving.add(id)
      let r = try Ok({
        if has_key(job, "id") {
          (self.d.stop)(
            text(get(Some(job), "id")).unwrap_or(""),
            "it moves to another station with its chat",
          )
        }
        let carried = del(job, "id")
        ignore(
          (self.d.ask)(
            to,
            jo([("method", js("move.job.start")), ("job", carried)]),
          ),
        )
        self.put(carried, false, Some(to))
      }) catch { e => Err(e) }
      self.moving.remove(id)
      match r {
        Ok(_) => ()
        Err(e) => raise e
      }
    },
    back: async fn(item, from, stopped_for) {
      let (job, _) = match self.moved(item_id(item)) {
        Some(m) => m
        None => raise Failed("job \{item_label(item)} did not move from here")
      }
      ignore(
        (self.d.ask)(
          from,
          jo([
            ("method", js("move.job.stop")),
            ("session", get(Some(job), "session").unwrap_or(Null)),
            ("name", get(Some(job), "name").unwrap_or(Null)),
          ]),
        ),
      )
      self.put(job, stopped_for is Some(_), None)
      if stopped_for is None {
        self.start_here(job)
      }
    },
    state: async fn(item) {
      let id = item_id(item)
      if self.moving.contains(id) {
        return st("moving")
      }
      if self.moved(id) is Some(_) {
        return st("there")
      }
      if self.kept(id) is Some(_) {
        return st("stopped")
      }
      st("here")
    },
    usable_here: None,
    usable_there: None,
    can_lend: None,
    lend: None,
    lent_for: None,
    left: None,
    is_here: None,
    abandon: None,
    ready: None,
    stop: None,
    resume: Some(async fn(item) {
      match self.kept(item_id(item)) {
        Some(j) => {
          self.put(j, false, None)
          self.start_here(j)
        }
        None => ()
      }
    }),
  }
}
