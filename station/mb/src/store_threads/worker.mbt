// The consumer of the queued card outcomes (card-outbox-worker.ts `CardOutcomeWorker`), on an effect runtime's clock:
// each turn examines one queue head; a card whose old edits must be paged is scanned by a fiber of its own, at most
// SCANS at once, so a long scan does not hold back the cards that are ready; a busy write or a failed scan is tried
// again after RETRY_MS; with nothing left it looks again after IDLE_MS (`timer:` what an interrupted producer left: a
// retry's deadline, as card-outbox-worker.ts says it).

///|
let retry_ms : Int = 250

///|
let idle_ms : Int = 30_000

///|
let scans : Int = 4

///|
/// The worker was closed while a scan read.
priv suberror Aborted

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
impl Show for Aborted with output(self, logger) {
  match self {
    Aborted => logger.write_string("the worker was closed while a scan read")
  }
}

///|
pub struct Worker {
  store : Store
  rt : @effect.Runtime
  page : async (Json, String, String?) -> Json
  message_page : async (Json, String, String?) -> Json
  scanning : Map[String, Bool]
  deferred : Map[String, Int]
  mut timer : Int?
  mut next_id : Int
  mut cursor : String
  mut again : Bool
  mut ready : Bool
  mut closed : Bool
  /// What it would have logged (log.warn), in order.
  warnings : Array[String]
}

///|
/// A worker of `store` on `rt`, reading old cards' pages with `page` and `message_page` (each `{kind, …}` as
/// card-outbox.ts `cardEditPage` and `cardMessagePage` give them). It begins once `previous_exited` is called.
pub fn Worker::new(
  store : Store,
  rt : @effect.Runtime,
  page : async (Json, String, String?) -> Json,
  message_page : async (Json, String, String?) -> Json,
) -> Worker {
  {
    store,
    rt,
    page,
    message_page,
    scanning: Map([]),
    deferred: Map([]),
    timer: None,
    next_id: 0,
    cursor: "0",
    again: false,
    ready: false,
    closed: false,
    warnings: [],
  }
}

///|
/// The station before has exited: the worker begins.
pub fn Worker::previous_exited(self : Worker) -> Unit {
  if !self.closed {
    self.ready = true
    self.wake()
  }
}

///|
/// The station before did not exit.
pub fn Worker::previous_failed(self : Worker, error : String) -> Unit {
  if !self.closed {
    self.warnings.push("the previous station did not exit: \{error}")
  }
}

///|
fn Worker::after(self : Worker, ms : Int, f : () -> Unit) -> Int {
  self.next_id += 1
  let id = self.next_id
  self.rt.after(ms, () => {
    if !self.closed {
      self.store.now = self.rt.now().to_double()
      f()
    }
  })
  id
}

///|
/// The request and its outcome saved together, the consumer woken after.
pub fn Worker::save(self : Worker, item : CardOutcome, save : () -> Unit raise) -> String raise {
  let id = self.store.save_card_outcome(item, save)
  self.wake()
  id
}

///|
/// After a queue item is committed; the idle look also finds those left by an interrupted producer.
pub fn Worker::wake(self : Worker) -> Unit {
  if self.closed || !self.ready {
    return
  }
  self.again = true
  let id = self.next_id + 1
  self.timer = Some(id)
  ignore(
    self.after(0, () => if self.timer == Some(id) {
      self.timer = None
      self.tick()
    }),
  )
}

///|
fn Worker::later(self : Worker, ms : Int) -> Unit {
  if self.closed || self.timer is Some(_) {
    return
  }
  let id = self.next_id + 1
  self.timer = Some(id)
  ignore(
    self.after(ms, () => if self.timer == Some(id) {
      self.timer = None
      self.tick()
    }),
  )
}

///|
fn Worker::defer_retry(self : Worker, key : String) -> Unit {
  if self.closed || self.deferred.contains(key) {
    return
  }
  let id = self.next_id + 1
  self.deferred[key] = id
  ignore(
    self.after(retry_ms, () => if self.deferred.get(key) == Some(id) {
      self.deferred.remove(key)
      self.wake()
    }),
  )
}

///|
fn Worker::tick(self : Worker) -> Unit {
  if self.closed || !self.ready {
    return
  }
  let head = try {
    if !self.store.has_card_outbox() {
      self.cursor = "0"
      self.later(idle_ms)
      return
    }
    let heads = self.store.card_outcome_heads(self.cursor, 1)
    heads.get(0)
  } catch {
    e => {
      self.warnings.push("reading queued card outcomes failed: \{sql_message(e)}")
      self.cursor = "0"
      self.later(retry_ms)
      return
    }
  }
  guard head is Some(item) else {
    self.cursor = "0"
    if self.again {
      self.again = false
      self.later(0)
    } else {
      self.later(idle_ms)
    }
    return
  }
  self.cursor = item.id
  let key = Json::array([item.thread, item.ts]).stringify()
  if !self.scanning.contains(key) && !self.deferred.contains(key) {
    (try {
      if self.store.restate_queued_card(item, None) is None {
        if self.scanning.length() < scans {
          self.start_scan(key, item)
        }
      }
    } catch {
      e => {
        if !(e is MessageWriteBusy) {
          self.warnings.push("writing a card outcome failed: \{sql_message(e)}")
        }
        self.defer_retry(key)
      }
    })
  }
  self.later(0)
}

///|
fn Worker::start_scan(self : Worker, key : String, item : CardOutcome) -> Unit {
  self.scanning[key] = true
  ignore(
    self.rt.fork_quiet(
      async fn() noraise {
        let done = try self.scan(item) catch {
          e => {
            if !self.closed && !(e is MessageWriteBusy) {
              self.warnings.push("reading an old card failed: \{sql_message(e)}")
            }
            self.defer_retry(key)
            true
          }
        } noraise {
          done => {
            if !done {
              self.defer_retry(key)
            }
            done
          }
        }
        ignore(done)
        self.scanning.remove(key)
        self.wake()
      },
      name="card scan",
    ),
  )
}

///|
fn Worker::check(self : Worker) -> Unit raise {
  if self.closed {
    raise Aborted
  }
}

///|
async fn Worker::scan(self : Worker, item : CardOutcome) -> Bool {
  self.store.now = self.rt.now().to_double()
  guard self.store.begin_card_edit_scan(item) is Some(scan) else { return false }
  let read = async fn() -> Bool {
    let mut edit : String?? = None
    if !legacy_merged_read_ready(self.store.db) {
      let mut before : String? = None
      while true {
        self.check()
        let page = (self.message_page)(scan.thread, scan.target, before)
        match page {
          { "kind": "found", "n": String(n), .. } => {
            edit = Some(Some(n))
            break
          }
          { "kind": "next", "before": String(b), .. } => before = Some(b)
          _ => {
            edit = Some(None)
            break
          }
        }
      }
    }
    let mut before : String? = None
    let mut card : String? = None
    while true {
      self.check()
      let page = (self.page)(scan.thread, scan.target, before)
      match page {
        { "kind": "found", "card": String(c), .. } => {
          card = Some(c)
          break
        }
        { "kind": "next", "before": String(b), .. } => before = Some(b)
        _ => break
      }
    }
    self.check()
    self.store.now = self.rt.now().to_double()
    self.store.restate_queued_card(item, Some({ scan, card, edit })) is Some(_)
  }
  let result = read() catch {
    e => {
      self.end(scan)
      raise e
    }
  }
  self.end(scan)
  result
}

///|
fn Worker::end(self : Worker, scan : CardEditScan) -> Unit {
  self.store.end_card_edit_scan(scan) catch {
    e =>
      if !self.closed && !(e is MessageWriteBusy) {
        self.warnings.push("releasing a card scan failed: \{sql_message(e)}")
      }
  }
}

///|
/// Stops: no timer fires after, a scan reading stops at its next page.
pub fn Worker::close(self : Worker) -> Unit {
  self.closed = true
  self.timer = None
  self.deferred.clear()
}

///|
/// What it holds now: where its look is, whether it looks again, the cards it scans and those it waits to try again.
pub fn Worker::state(self : Worker) -> Json {
  let keys = (m : Iter[String]) => {
    let ks = m.collect()
    ks.sort()
    Json::array(ks.map(jstr))
  }
  {
    "cursor": jstr(self.cursor),
    "again": jbool(self.again),
    "scanning": keys(self.scanning.keys()),
    "deferred": keys(self.deferred.keys()),
    "timer": jbool(self.timer is Some(_)),
  }
}

///|
/// Runs its clock on to `until` (ms), each timer at its time and what each wakes before the next.
pub fn Worker::run_until(self : Worker, until : Int64) -> Unit {
  let ms = until - self.rt.now()
  self.rt.advance(if ms > 0L { ms.to_int() } else { 0 })
  ignore(self.rt.run_ready())
  while self.rt.next_timer() is Some(at) && at <= self.rt.now() {
    self.rt.advance(0)
    ignore(self.rt.run_ready())
  }
}
