// The Comma Tasks a Comma connect's agents work in (station/src/comma/tasks.ts), kept in <data>/comma-tasks.json: for
// each connect, each Task by its address at Comma (`task`, as task.invite named it), the thread it is here (channel
// TASK, its ts made from the address), how it was started (who asked, the runtime and model it was asked to run), how
// far Comma gave it (`fetched`: task.put's `through`, what task.hello says) and through which Message the station's
// session answered it already (`answered`: Comma says so with an invite made again; those Messages are not handed to
// the session again). Kept as the JSON the file holds, so what is written again is what the TypeScript writes.

///|
/// Where Comma Tasks are, as threads here.
pub let task_channel : String = "TASK"

///|
/// How a Task was started, as task.invite said: who asked (a Comma user's id), and what it asked to run.
pub(all) struct Start {
  requester : String
  title : String?
  runtime : String?
  model : String?
}

///|
pub fn Start::to_j(self : Start) -> J {
  jobj([
    ("requester", jstr(self.requester)),
    ("title", self.title.map(jstr).unwrap_or(Null)),
    ("runtime", self.runtime.map(jstr).unwrap_or(Null)),
    ("model", self.model.map(jstr).unwrap_or(Null)),
  ])
}

///|
/// A Start as a kept Task says it.
pub fn Start::of_j(v : J?) -> Start {
  {
    requester: str_of(prop(v, "requester")).unwrap_or(""),
    title: str_of(prop(v, "title")),
    runtime: str_of(prop(v, "runtime")),
    model: str_of(prop(v, "model")),
  }
}

///|
/// A Task as it is kept.
pub(all) struct Task {
  task : String
  thread_ts : String
  start : Start
  fetched : Double
  answered : Double
  left : Bool
}

///|
pub fn Task::of_j(v : J) -> Task {
  {
    task: str_of(prop(Some(v), "task")).unwrap_or(""),
    thread_ts: str_of(prop(Some(v), "threadTs")).unwrap_or(""),
    start: Start::of_j(prop(Some(v), "start")),
    fetched: num_of(prop(Some(v), "fetched")).unwrap_or(0.0),
    answered: num_of(prop(Some(v), "answered")).unwrap_or(0.0),
    left: prop(Some(v), "left") is Some(Bool(true)),
  }
}

///|
/// A Task's thread ts, made of its address as a thread's ts reads (`<seconds>.<micros>`), the same for the same Task.
pub fn thread_ts_of(task : String) -> String {
  let h = sha256_hex(utf8_of(task))
  let word = (at : Int) => {
    let mut v = 0.0
    for i in 0..<8 {
      let c = h.unsafe_charcode_at(at * 2 + i)
      let d = if c >= 'a' { c - 'a' + 10 } else { c - '0' }
      v = v * 16.0 + d.to_double()
    }
    v
  }
  let a = word(0)
  let b = word(4)
  let micros = (b - (b / 1000000.0).floor() * 1000000.0).to_int()
  let ms = micros.to_string()
  let padded = "000000".unsafe_substring(start=0, end=6 - ms.length()) + ms
  "\{num_text(a)}.\{padded}"
}

///|
/// An object's entries as JavaScript goes through them (Object.values, `in`): its array-index keys first, ascending,
/// then the rest as they were put.
fn js_order(entries : Array[(String, J)]) -> Array[(String, J)] {
  let ints = []
  let rest = []
  for e in entries {
    match @jsjson.index_key(e.0) {
      Some(v) => ints.push((v, e))
      None => rest.push(e)
    }
  }
  ints.sort_by((a, b) => a.0.compare(b.0))
  ints.map(x => x.1) + rest
}

///|
fn entry_at(entries : Array[(String, J)], key : String) -> Int? {
  for i, e in entries {
    if e.0 == key {
      return Some(i)
    }
  }
  None
}

///|
/// `o[key] = v`: in its place where it was there, last where it was not.
fn put_field(entries : Array[(String, J)], key : String, v : J) -> Unit {
  match entry_at(entries, key) {
    Some(i) => entries[i] = (entries[i].0, v)
    None => entries.push((key, v))
  }
}

///|
pub struct CommaTasks {
  path : String
  priv io : Io
  /// What is kept, as the file holds it: by connect, by Task.
  priv mut kept : Array[(String, J)]
  /// What is to be written next, and the writer at work (PrivateFile's `#latest`, `#writing`).
  priv mut latest : String?
  priv mut writing : @effect.Deferred[Unit]?
  /// The saves waiting on the write under way: each is told of its failure (each `save` catches the one promise).
  priv mut waiters : Int
  priv runtime : @effect.Runtime
}

///|
/// The Tasks kept at `path`, read once, before the station serves.
pub fn CommaTasks::new(path : String, io : Io, runtime : @effect.Runtime) -> CommaTasks {
  let tasks = { path, io, kept: [], latest: None, writing: None, waiters: 0, runtime }
  let read = try {
    match (io.read_text)(path) {
      Some(text) => Ok(Some(parse_json(text)))
      None => Ok(None)
    }
  } catch {
    e => Err(e)
  }
  match read {
    Ok(Some(Obj(entries))) => tasks.kept = entries
    Ok(_) => ()
    Err(e) => io.warn("comma tasks file unreadable; starting empty", [("error", Some(jstr(message_of(e))))])
  }
  tasks
}

///|
/// Kept in memory at once, written off the main thread (those asked while a write is on its way: the latest after it).
fn CommaTasks::save(self : CommaTasks) -> Unit {
  self.latest = Some(stringify(Obj(self.kept)))
  self.waiters += 1
  if self.writing is Some(_) {
    return
  }
  let done : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.writing = Some(done)
  ignore(
    self.runtime.fork_daemon("comma tasks write", on_error=e => {
        self.waiters = 0
        self.writing = None
        ignore(done.succeed(()))
        self.io.warn("comma tasks not kept", [("error", Some(jstr(message_of(e))))])
      }, async fn() {
      let mut failed : String? = None
      while self.latest is Some(text) {
        self.latest = None
        (self.io.write_private)(self.path, text) catch {
          e => {
            failed = Some(message_of(e))
            break
          }
        }
      }
      let told = self.waiters
      self.waiters = 0
      self.writing = None
      ignore(done.succeed(()))
      match failed {
        Some(m) =>
          for _ in 0..<told {
            self.io.warn("comma tasks not kept", [("error", Some(jstr(m)))])
          }
        None => ()
      }
    }),
  )
}

///|
/// Once what was changed is written.
pub async fn CommaTasks::written(self : CommaTasks) -> Unit {
  match self.writing {
    Some(d) => d.wait() catch { _ => () }
    None => ()
  }
}

///|
fn CommaTasks::of(self : CommaTasks, connect : String) -> Array[(String, J)]? {
  match entry_at(self.kept, connect) {
    Some(i) =>
      match self.kept[i].1 {
        Obj(entries) => Some(entries)
        _ => None
      }
    None => None
  }
}

///|
/// The Task as it is kept, if it is.
pub fn CommaTasks::get_j(self : CommaTasks, connect : String, task : String) -> J? {
  match self.of(connect) {
    Some(entries) =>
      match entry_at(entries, task) {
        Some(i) => Some(entries[i].1)
        None => None
      }
    None => None
  }
}

///|
pub fn CommaTasks::get(self : CommaTasks, connect : String, task : String) -> Task? {
  self.get_j(connect, task).map(Task::of_j)
}

///|
/// The Task whose thread here has this ts.
pub fn CommaTasks::by_thread_j(self : CommaTasks, connect : String, thread_ts : String) -> J? {
  match self.of(connect) {
    Some(entries) => {
      for e in js_order(entries) {
        if str_of(prop(Some(e.1), "threadTs")) == Some(thread_ts) {
          return Some(e.1)
        }
      }
      None
    }
    None => None
  }
}

///|
pub fn CommaTasks::by_thread(self : CommaTasks, connect : String, thread_ts : String) -> Task? {
  self.by_thread_j(connect, thread_ts).map(Task::of_j)
}

///|
/// The connect's Tasks it still takes part in (not left).
pub fn CommaTasks::taking_j(self : CommaTasks, connect : String) -> Array[J] {
  match self.of(connect) {
    Some(entries) =>
      js_order(entries).filter(e => !(prop(Some(e.1), "left") is Some(Bool(true)))).map(e => e.1)
    None => []
  }
}

///|
pub fn CommaTasks::taking(self : CommaTasks, connect : String) -> Array[Task] {
  self.taking_j(connect).map(Task::of_j)
}

///|
/// The station takes part in `task` (again, with an invite made again: what it answered through is kept as the most
/// said).
pub fn CommaTasks::invited(self : CommaTasks, connect : String, task : String, start : Start, answered : Double) -> J {
  let at = match self.of(connect) {
    Some(entries) => entries
    None => {
      let entries = []
      put_field(self.kept, connect, Obj(entries))
      entries
    }
  }
  let had = match entry_at(at, task) {
    Some(i) => Some(at[i].1)
    None => None
  }
  let thread_ts = match str_of(prop(had, "threadTs")) {
    Some(ts) => jstr(ts)
    None =>
      match prop(had, "threadTs") {
        Some(Null) | None => jstr(thread_ts_of(task))
        Some(v) => v
      }
  }
  let fetched = match prop(had, "fetched") {
    Some(Null) | None => jn(0.0)
    Some(v) => v
  }
  let had_answered = match prop(had, "answered") {
    Some(Null) | None => 0.0
    Some(Num(n)) => n
    Some(_) => @double.not_a_number
  }
  let t = jobj([
    ("task", jstr(task)),
    ("threadTs", thread_ts),
    ("start", start.to_j()),
    ("fetched", fetched),
    ("answered", Num(js_max(had_answered, answered))),
  ])
  put_field(at, task, t)
  self.save()
  t
}

///|
/// `Math.max(a, b)`.
fn js_max(a : Double, b : Double) -> Double {
  if a.is_nan() || b.is_nan() {
    @double.not_a_number
  } else if a > b {
    a
  } else {
    b
  }
}

///|
/// Comma gave the Task through `through`, and said its session answered it through `answered`.
pub fn CommaTasks::given(
  self : CommaTasks,
  connect : String,
  task : String,
  through : Double?,
  answered : Double?,
) -> Unit {
  guard self.get_j(connect, task) is Some(Obj(t)) else { return }
  match through {
    Some(n) => {
      let had = num_of(prop(Some(Obj(t)), "fetched")).unwrap_or(@double.not_a_number)
      put_field(t, "fetched", Num(js_max(had, n)))
    }
    None => ()
  }
  match answered {
    Some(n) => {
      let had = num_of(prop(Some(Obj(t)), "answered")).unwrap_or(@double.not_a_number)
      put_field(t, "answered", Num(js_max(had, n)))
    }
    None => ()
  }
  self.save()
}

///|
/// The Task runs elsewhere now (task.leave): nothing of it is taken again.
pub fn CommaTasks::left(self : CommaTasks, connect : String, task : String) -> Unit {
  guard self.get_j(connect, task) is Some(Obj(t)) else { return }
  match prop(Some(Obj(t)), "left") {
    Some(Null | Bool(false)) | None => ()
    Some(Num(n)) if n == 0.0 || n.is_nan() => ()
    Some(Str("")) => ()
    Some(_) => return
  }
  put_field(t, "left", Bool(true))
  self.save()
}

///|
/// A connect removed: its Tasks with it.
pub fn CommaTasks::forget(self : CommaTasks, connect : String) -> Unit {
  guard entry_at(self.kept, connect) is Some(i) else { return }
  self.kept.remove(i) |> ignore
  self.save()
}
