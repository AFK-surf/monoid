// The deadlines of chats shared with other workspaces prepared in bounded batches (station/src/xshare/index-builder.ts
// `ChatShareIndexBuilder`): once the station before has let go, and only once the table has more shares than are
// cheaper to read whole, station/mb src/activity (`share_install`, `share_step`) makes the lookup a batch at a time on a
// connection of its own; the store's reads take it once it is done (`refresh_index`). Until then they read the table.

///|
/// More shares than this are read by their deadlines (chat-share-index.ts `SHARE_MANY`).
let share_many_sql : String = "SELECT 1 FROM chat_shares LIMIT 1 OFFSET 32"

///|
pub struct ChatShareIndexBuilder {
  priv shares : SqlChatShares
  /// A connection of its own to the station's database (None: the store is no file).
  priv open : () -> @sql.Db? raise
  priv previous : @effect.Deferred[Bool]
  priv cancelled : @effect.Deferred[Bool]
  priv tasks : Tasks
  priv log : Log
  priv mut pending : @effect.Deferred[Bool]?
  priv mut stopped : Bool
}

///|
/// `previous`: once the station before is gone (true), or could not be waited for (false).
pub fn ChatShareIndexBuilder::new(
  shares : SqlChatShares,
  open : () -> @sql.Db? raise,
  previous : @effect.Deferred[Bool],
  rt : @effect.Runtime,
  log : Log,
) -> ChatShareIndexBuilder {
  {
    shares,
    open,
    previous,
    cancelled: @effect.Deferred::new(),
    tasks: Tasks::new(rt, log, "xshare"),
    log,
    pending: None,
    stopped: false,
  }
}

///|
pub fn ChatShareIndexBuilder::request(self : ChatShareIndexBuilder) -> Unit {
  if self.stopped || self.pending is Some(_) {
    return
  }
  let wanted = try {
    if self.shares.index_ready() {
      false
    } else {
      // A few shares are cheaper to read directly. Do not install anything until the table grows past this probe.
      self.shares.has_index() || self.shares.db.all(share_many_sql, []).length() > 0
    }
  } catch {
    e => {
      self.log.warn("xshare", "the share lookup could not be checked", jobj([("error", jstr(error_words(e)))]))
      false
    }
  }
  if !wanted {
    return
  }
  let work : @effect.Deferred[Bool] = @effect.Deferred::new()
  self.pending = Some(work)
  self.tasks.spawn(async fn() {
    let done = try {
      let first : @effect.Deferred[Bool] = @effect.Deferred::new()
      let watch = (d : @effect.Deferred[Bool]) => self.tasks.spawn(async fn() {
        let ok = d.wait() catch { _ => false }
        ignore(first.succeed(ok))
      })
      watch(self.previous)
      watch(self.cancelled)
      if !first.wait() || self.stopped {
        false
      } else {
        self.run()
      }
    } catch {
      e => {
        self.log.warn("xshare", "the share lookup could not be prepared", jobj([("error", jstr(error_words(e)))]))
        false
      }
    }
    if self.pending is Some(p) && physical_equal(p, work) {
      self.pending = None
    }
    ignore(work.succeed(done))
  })
}

///|
/// Once what was asked is done.
pub async fn ChatShareIndexBuilder::settled(self : ChatShareIndexBuilder) -> Unit {
  if self.pending is Some(p) {
    ignore(p.wait())
  }
}

///|
async fn ChatShareIndexBuilder::run(self : ChatShareIndexBuilder) -> Bool {
  guard (self.open)() is Some(db) else {
    self.log.warn("xshare", "the share lookup's backfill requires a file-backed store", jnull())
    return false
  }
  defer db.close()
  db.exec("PRAGMA synchronous = NORMAL")
  let mut done = false
  while !self.stopped {
    let step = try {
      @activity.share_install(db)
      Some(@activity.share_step(db))
    } catch {
      e =>
        if @sql.busy(e) {
          Some(false)
        } else {
          self.log.warn("xshare", "a share batch stopped", jobj([("error", jstr(error_words(e)))]))
          None
        }
    }
    match step {
      Some(true) => {
        done = true
        break
      }
      Some(false) => @effect.pause()
      None => break
    }
  }
  if done && !self.stopped {
    try {
      done = self.shares.refresh_index()
    } catch {
      e => {
        done = false
        self.log.warn("xshare", "the prepared share lookup could not be found", jobj([("error", jstr(error_words(e)))]))
      }
    }
  } else {
    done = false
  }
  if !done && !self.stopped {
    self.log.warn("xshare", "the share worker stopped before finishing", jnull())
  }
  done
}

///|
pub async fn ChatShareIndexBuilder::close(self : ChatShareIndexBuilder) -> Unit {
  if self.stopped {
    return
  }
  self.stopped = true
  ignore(self.cancelled.succeed(false))
  self.settled()
}
