// The decided uses of secrets and the requests still waiting, read by their indexes (station/src/vault/use-index.ts
// `UseIndex`, use-reader-mb.ts `MbUseReader`): a read answered at once where its index is ready, else prepared a
// bounded batch at a time on a connection of its own (station/vaultuses's steps), under the backfills' one permit,
// with the recovery index and every workspace's old uses filled in the background between. Let go once idle.

///|
/// How long the connection is kept with nothing asked of it and its background done.
let use_idle_ms : Double = 60000.0

///|
let backfill_pause_ms : Double = 50.0

///|
let request_backfill_pause_ms : Double = 5.0

///|
/// An ask of the index: a page of uses, or a workspace's pending lookup prepared.
enum UseAsk {
  Read(@vaultuses.UseRead, @effect.Deferred[Array[String]])
  Pending(String, Bool, Bool, @effect.Deferred[Unit])
}

///|
pub struct UseIndex {
  w : World
  main : @vault_crypto.Db
  mut conn : @sql.Db?
  mut uses_done : Bool
  mut rebox_done : Bool
  mut rebox_turn : Bool
  waiting : Array[UseAsk]
  mut closed : Bool
  mut ready : Bool
  mut stepping : Bool
  mut scheduled : Bool
  mut idle : (() -> Unit)?
  /// What waits for the process before to be gone (use-index.ts `#previousGone`), None once it is.
  mut previous : @effect.Deferred[Unit]?
}

///|
/// The index of `db`: its schema and the recovery index's put in; its reader started once the process before is gone.
pub fn UseIndex::new(w : World, db : @vault_crypto.Db) -> UseIndex raise {
  initialize_use_index(db)
  initialize_rebox_index(db)
  let u : UseIndex = {
    w,
    main: db,
    conn: None,
    uses_done: false,
    rebox_done: false,
    rebox_turn: true,
    waiting: [],
    closed: false,
    ready: false,
    stepping: false,
    scheduled: false,
    idle: None,
    previous: None,
  }
  if w.index_db is Some(_) {
    match w.previous.gone {
      None => u.start()
      Some(gone) => {
        let d : @effect.Deferred[Unit] = @effect.Deferred::new()
        u.previous = Some(d)
        ignore(
          @effect.runtime().fork(name="vault use reader start", async fn() {
            gone() catch {
              e => {
                (w.log)("error", "vault", "the use reader could not start", obj([("error", js(message_of(e)))]))
                return
              }
            }
            u.previous = None
            ignore(d.succeed(()))
            if !u.closed {
              u.start()
            }
          }),
        )
      }
    }
  }
  u
}

///|
/// The reader started: its connection opened, its background set going.
fn UseIndex::start(self : UseIndex) -> Unit {
  if self.ready {
    return
  }
  self.ready = true
  self.schedule(0.0)
}

///|
fn UseIndex::connection(self : UseIndex) -> @sql.Db raise {
  match self.conn {
    Some(c) => c
    None =>
      match self.w.index_db {
        Some(open) => {
          let c = open()
          self.conn = Some(c)
          c
        }
        None => raise Failure("the vault's index has no connection of its own")
      }
  }
}

///|
fn UseIndex::more(self : UseIndex) -> Bool {
  self.waiting.length() > 0 || !self.uses_done || !self.rebox_done
}

///|
/// Nothing asked of it, nothing of the background left, no step under way: it may be let go.
fn UseIndex::idle_now(self : UseIndex) -> Bool {
  self.conn is Some(_) && !self.scheduled && !self.stepping && !self.more()
}

///|
fn UseIndex::pause(self : UseIndex) -> Double {
  if self.waiting.length() > 1 {
    request_backfill_pause_ms
  } else {
    backfill_pause_ms
  }
}

///|
fn UseIndex::schedule(self : UseIndex, delay : Double) -> Unit {
  if self.scheduled || self.closed || !self.ready {
    return
  }
  self.scheduled = true
  ignore(
    @effect.runtime().fork(name="vault use reader", async fn() {
      if delay > 0.0 {
        (self.w.sleep)(delay)
      } else {
        @effect.pause()
      }
      self.stepping = true
      self.step() catch {
        e => (self.w.log)("error", "vault", "the use reader stopped", obj([("error", js(message_of(e)))]))
      }
      self.stepping = false
      self.idle_later()
    }),
  )
}

///|
/// Answers `q` where its index is ready: true where it is answered.
fn UseIndex::answer_if_ready(self : UseIndex, q : UseAsk) -> Bool {
  let answered = (fn() -> Bool raise {
    let conn = self.connection()
    match q {
      Read(r, d) =>
        match @vaultuses.try_read_uses(conn, r) {
          Some(bodies) => {
            ignore(d.succeed(bodies.map(b => js_text(Some(b)))))
            true
          }
          None => false
        }
      Pending(ws, members, audit, d) =>
        if @vaultuses.pending_preparation_complete(conn, js(ws), members, audit) {
          ignore(d.succeed(()))
          true
        } else {
          false
        }
    }
  })() catch {
    e => {
      fail_ask(q, e)
      true
    }
  }
  answered
}

///|
fn fail_ask(q : UseAsk, e : Error) -> Unit {
  match q {
    Read(_, d) => ignore(d.fail(e))
    Pending(_, _, _, d) => ignore(d.fail(e))
  }
}

///|
/// One turn: an ask answered where it is ready, else one bounded batch toward it or of the background, under the permit.
fn UseIndex::step(self : UseIndex) -> Unit raise {
  self.scheduled = false
  if self.closed {
    return
  }
  let q = if self.waiting.is_empty() { None } else { Some(self.waiting.remove(0)) }
  if q is Some(a) {
    if self.answer_if_ready(a) {
      if self.more() {
        self.schedule(if self.waiting.is_empty() { backfill_pause_ms } else { request_backfill_pause_ms })
      }
      return
    }
  }
  if !(self.w.backfill_take)() {
    if q is Some(a) {
      self.waiting.push(a)
    }
    self.schedule(self.pause())
    return
  }
  let conn = self.connection()
  (fn() raise {
    match q {
      Some(a) => {
        let done = (fn() -> Bool raise {
          match a {
            Read(r, d) =>
              if @vaultuses.backfill_use_preparation(conn, r.ws) {
                match @vaultuses.try_read_uses(conn, r) {
                  Some(bodies) => {
                    ignore(d.succeed(bodies.map(b => js_text(Some(b)))))
                    true
                  }
                  None => false
                }
              } else {
                false
              }
            Pending(ws, members, audit, d) =>
              if @vaultuses.backfill_pending_preparation(conn, js(ws), members, audit) {
                ignore(d.succeed(()))
                true
              } else {
                false
              }
          }
        })() catch {
          e => {
            fail_ask(a, e)
            true
          }
        }
        // (other workspaces get a turn between this one's batches)
        if !done {
          self.waiting.push(a)
        }
      }
      None =>
        if !self.rebox_done && (self.uses_done || self.rebox_turn) {
          // (another process's write holding the database is a wait, as the TypeScript reader's `busy`: tried again)
          self.rebox_done = @vaultuses.backfill_rebox(conn) catch {
            e if @sql.busy(e) => false
            e => {
              (self.w.log)("error", "vault", "the recovery index backfill stopped", obj([("error", js(message_of(e)))]))
              true
            }
          }
          self.rebox_turn = false
        } else if !self.uses_done {
          self.uses_done = @vaultuses.backfill_next_workspace(conn) catch {
            e if @sql.busy(e) => false
            e => {
              (self.w.log)("error", "vault", "the use history backfill stopped", obj([("error", js(message_of(e)))]))
              true
            }
          }
          self.rebox_turn = true
        }
    }
  })() catch {
    e => {
      (self.w.backfill_give)()
      raise e
    }
  }
  (self.w.backfill_give)()
  if self.more() {
    self.schedule(if self.waiting.is_empty() { backfill_pause_ms } else { request_backfill_pause_ms })
  }
}

///|
/// Nothing asked and the background done: the connection goes after IDLE_MS unless asked again.
fn UseIndex::idle_later(self : UseIndex) -> Unit {
  if self.closed || self.idle is Some(_) || !self.idle_now() {
    return
  }
  // timer: a deadline (an idle connection let go)
  self.idle = Some(
    (self.w.after)(use_idle_ms, () => {
      self.idle = None
      if self.idle_now() {
        self.let_go()
      }
    }),
  )
}

///|
fn UseIndex::let_go(self : UseIndex) -> Unit {
  match self.idle {
    Some(cancel) => cancel()
    None => ()
  }
  self.idle = None
  match self.conn {
    Some(c) => c.close()
    None => ()
  }
  self.conn = None
}

///|
/// The connection let go at once if nothing is asked of it and its background is done: 1, else 0.
pub fn UseIndex::trim_idle(self : UseIndex) -> Int {
  if self.closed || !self.idle_now() {
    return 0
  }
  self.let_go()
  1
}

///|
async fn UseIndex::ask(self : UseIndex, q : UseAsk) -> Unit {
  if self.previous is Some(d) {
    d.wait()
  }
  if self.closed {
    raise Failure("station stopping")
  }
  match self.idle {
    Some(cancel) => cancel()
    None => ()
  }
  self.idle = None
  if !self.answer_if_ready(q) {
    self.waiting.push(q)
    self.schedule(0.0)
  }
}

///|
/// A page of the decided uses of a vault (or of the plain library's, `owner`'s), the latest first.
pub async fn UseIndex::read(self : UseIndex, ws : String, vault : String, owner : String?, limit : Int) -> Array[String] {
  let d : @effect.Deferred[Array[String]] = @effect.Deferred::new()
  let r : @vaultuses.UseRead = {
    ws: js(ws),
    vault: @jsjson.units(vault),
    owner: owner.map(o => @jsjson.units(o)),
    limit: ji(limit),
  }
  self.ask(Read(r, d))
  d.wait()
}

///|
/// One workspace's pending lookup prepared in bounded transactions.
pub async fn UseIndex::prepare_pending(self : UseIndex, ws : String, members : Bool, audit? : Bool = false) -> Unit {
  if self.closed {
    raise Failure("station stopping")
  }
  if pending_preparation_complete(self.main, ws, members, audit) {
    return
  }
  let d : @effect.Deferred[Unit] = @effect.Deferred::new()
  self.ask(Pending(ws, members, audit, d))
  d.wait()
}

///|
pub fn UseIndex::close(self : UseIndex) -> Unit {
  self.closed = true
  for q in self.waiting {
    fail_ask(q, Failure("station stopping"))
  }
  self.waiting.clear()
  self.let_go()
}

///|
/// The background's batches all taken now, one after another (the recovery index, then every workspace's uses): what
/// the reader would have come to.
pub fn UseIndex::drain(self : UseIndex) -> Unit raise {
  let conn = self.connection()
  while !self.rebox_done {
    self.rebox_done = @vaultuses.backfill_rebox(conn)
  }
  while !self.uses_done {
    self.uses_done = @vaultuses.backfill_next_workspace(conn)
  }
}
