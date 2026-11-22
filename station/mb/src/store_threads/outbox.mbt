// A card's outcome saved with its request and queued (card-outbox.ts), the guards a restatement or a paged scan holds
// over a thread while it reads (restate-guard.ts, card-scan-guard.ts), and restating a card on its post: the author's
// own (`restateCard`) or the oldest queued outcome (`restateQueuedCard`, its old edits paged by `beginCardEditScan`).

///|
/// card-outbox.ts CardOutcome.
pub(all) struct CardOutcome {
  id : String
  thread : Json
  ts : Json
  agent : Json
  field : String
  close : Bool
  outcome : @jsjson.JValue
}

///|
/// card-outbox.ts CardEditScan: a live guard held before paging.
pub(all) struct CardEditScan {
  thread : Json
  ts : Json
  agent : Json
  target : String
  token : String
  schema : Int
}

///|
/// What a worker's paged scan found (store.ts `restateQueuedCard`'s `prepared`): the latest card edit (None: none),
/// and the message's latest edit where it read it (`edit`: None, undefined; Some(None), null).
pub(all) struct Prepared {
  scan : CardEditScan
  card : String?
  edit : String??
}

///|
pub fn CardOutcome::to_json(self : CardOutcome) -> Json {
  {
    "id": jstr(self.id),
    "thread": self.thread,
    "ts": self.ts,
    "agent": self.agent,
    "field": jstr(self.field),
    "close": jbool(self.close),
    "outcome": to_json(self.outcome),
  }
}

///|
pub fn CardOutcome::from_json(v : @jsjson.JValue) -> CardOutcome {
  {
    id: jtext(jget(v, "id")).unwrap_or(""),
    thread: jnullish(jget(v, "thread")),
    ts: jnullish(jget(v, "ts")),
    agent: jnullish(jget(v, "agent")),
    field: jtext(jget(v, "field")).unwrap_or(""),
    close: jget(v, "close") is Some(Bool(true)),
    outcome: jget(v, "outcome").unwrap_or(Obj([])),
  }
}

///|
pub fn CardEditScan::to_json(self : CardEditScan) -> Json {
  {
    "thread": self.thread,
    "ts": self.ts,
    "agent": self.agent,
    "target": jstr(self.target),
    "token": jstr(self.token),
    "schema": jint(self.schema),
  }
}

///|
pub fn CardEditScan::from_json(v : @jsjson.JValue) -> CardEditScan {
  {
    thread: jnullish(jget(v, "thread")),
    ts: jnullish(jget(v, "ts")),
    agent: jnullish(jget(v, "agent")),
    target: jtext(jget(v, "target")).unwrap_or(""),
    token: jtext(jget(v, "token")).unwrap_or(""),
    schema: match jget(v, "schema") {
      Some(Num(n)) => n.to_int()
      _ => 0
    },
  }
}

// ── the guards ──

///|
fn guard_installed(db : @sql.Db, meta : String, table : String, names : Array[String], thread_drop : String, mark : String) -> Bool raise {
  if !exists(db, "table", meta) {
    return false
  }
  let version = match one(db, "SELECT version FROM \{meta} WHERE id=1", []) {
    Some(r) => col(r, "version")
    None => Json::null()
  }
  if !is_num(version, 1.0) {
    let had = if version is Null { "missing" } else { version.stringify() }
    let what = if meta == "card_scan_meta" { "card scan guard" } else { "restate guard" }
    raise StoreError("\{what} version \{had} is incompatible with 1")
  }
  if !exists(db, "table", table) {
    return false
  }
  let found = db.all(
    "SELECT name,tbl_name,sql FROM sqlite_master WHERE type='trigger' AND name IN\n      ('\{names[0]}','\{names[1]}','\{names[2]}','\{names[3]}')",
    [],
  )
  names.iter().all(name => found.iter().any(row => col(row, "name") == jstr(name) &&
    col(row, "tbl_name") == jstr(if name == thread_drop { "threads" } else { "entries" }) &&
    col(row, "sql") is String(sql) &&
    sql.contains(mark)))
}

///|
/// card-scan-guard.ts and restate-guard.ts `ensure…`: install only empty guard state; the schema it is in.
fn Store::ensure_guard(self : Store, scan : Bool) -> Int raise {
  let (meta, table, names, thread_drop, mark, tables, triggers) = if scan {
    (
      "card_scan_meta",
      "card_scan_guard",
      ["card_scan_add", "card_scan_change", "card_scan_drop", "card_scan_thread_drop"],
      "card_scan_thread_drop",
      "card_scan_guard_v1",
      card_scan_tables_sql,
      card_scan_triggers_sql,
    )
  } else {
    (
      "restate_guard_meta",
      "restate_guard",
      ["restate_guard_add", "restate_guard_change", "restate_guard_drop", "restate_guard_thread_drop"],
      "restate_guard_thread_drop",
      "restate_guard_v1",
      restate_guard_tables_sql,
      restate_guard_triggers_sql,
    )
  }
  let cached = if scan { self.scan_guard_schema } else { self.restate_guard_schema }
  let installed = () => guard_installed(self.db, meta, table, names, thread_drop, mark)
  let (schema, ready) = self.snapshot(if scan { "card_scan_schema" } else { "restate_guard_schema" }, () => {
    let schema = schema_version(self.db)
    (schema, cached == Some(schema) || installed())
  })
  let mut schema = schema
  if !ready {
    self.db.exec("BEGIN IMMEDIATE")
    let work = () => {
      if !installed() {
        self.db.exec(tables)
        for name in names {
          self.db.exec("DROP TRIGGER IF EXISTS \{name}")
        }
        self.db.exec(triggers)
      }
      if !installed() {
        raise StoreError(if scan { "card scan guard installation did not finish" } else { "restate guard installation did not finish" })
      }
      schema = schema_version(self.db)
      self.db.exec("COMMIT")
    }
    work() catch {
      e => {
        self.db.exec("ROLLBACK") catch {
          _ => ()
        }
        raise e
      }
    }
  }
  if scan {
    self.scan_guard_schema = Some(schema)
  } else {
    self.restate_guard_schema = Some(schema)
  }
  schema
}

// ── the queue ──

///|
/// card-outbox.ts `hasCardOutbox`.
fn Store::has_card_outbox(self : Store) -> Bool raise {
  let schema = schema_version(self.db)
  let version_ok = () => match self.one("SELECT version FROM card_outbox_meta WHERE id=1", []) {
    Some(r) => is_num(col(r, "version"), 1.0)
    None => false
  }
  if self.outbox_schema == Some(schema) {
    if !version_ok() {
      raise StoreError("card outcome outbox has an unsupported version")
    }
    return true
  }
  if !exists(self.db, "table", "card_outbox_meta") {
    return false
  }
  if !version_ok() {
    raise StoreError("card outcome outbox has an unsupported version")
  }
  if !is_num(
      col(
        self.one("SELECT COUNT(*) AS n FROM sqlite_master WHERE type='table' AND name IN ('card_outbox','card_outbox_head')", []).unwrap(),
        "n",
      ),
      2.0,
    ) {
    raise StoreError("card outcome outbox tables are missing")
  }
  if self.depth == 0 {
    self.outbox_schema = Some(schema)
  }
  true
}

///|
/// card-outbox.ts `installCardOutbox`.
fn Store::install_card_outbox(self : Store) -> Unit raise {
  if self.has_card_outbox() {
    return
  }
  self.db.exec("SAVEPOINT card_outbox_install")
  self.depth += 1
  let work = () => {
    if self.has_card_outbox() {
      self.depth -= 1
      self.db.exec("RELEASE card_outbox_install")
      return
    }
    self.db.exec(
      "CREATE TABLE IF NOT EXISTS card_outbox_meta(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL,\n        next_id INTEGER NOT NULL) WITHOUT ROWID;\n      INSERT OR IGNORE INTO card_outbox_meta VALUES(1,1,0);",
    )
    if !(self.one("SELECT version FROM card_outbox_meta WHERE id=1", []) is Some(r) && is_num(col(r, "version"), 1.0)) {
      raise StoreError("card outcome outbox has an unsupported version")
    }
    self.db.exec(
      "\{card_outbox_table_sql};\n      CREATE TABLE IF NOT EXISTS card_outbox_head(id INTEGER PRIMARY KEY,thread INTEGER NOT NULL,ts TEXT NOT NULL);",
    )
    self.depth -= 1
    self.db.exec("RELEASE card_outbox_install")
    ignore(self.has_card_outbox())
  }
  work() catch {
    e => {
      if self.depth > 0 {
        self.depth -= 1
      }
      self.db.exec("ROLLBACK TO card_outbox_install; RELEASE card_outbox_install") catch {
        _ => ()
      }
      raise e
    }
  }
}

///|
/// card-outbox.ts `takeRigOutcomes`.
fn Store::take_rig_outcomes(self : Store) -> Unit raise {
  guard sql_of(self.db, "table", "card_outbox") is Some(sql) else { return }
  if sql.contains("'rig'") {
    return
  }
  self.db.exec(
    "\{card_outbox_wider_table_sql};\n    INSERT INTO card_outbox_wider SELECT thread,ts,id,agent,field,close_card,outcome FROM card_outbox;\n    DROP TABLE card_outbox;\n    ALTER TABLE card_outbox_wider RENAME TO card_outbox;",
  )
}

///|
/// card-outbox.ts `enqueueCardOutcome`.
fn Store::enqueue_card_outcome(self : Store, item : CardOutcome) -> String raise {
  if self.depth == 0 {
    raise StoreError("card outcome must be queued with its request in a transaction")
  }
  let outcome = stringify(item.outcome)
  guard self.one(
      "UPDATE card_outbox_meta SET next_id=next_id+1\n    WHERE id=1 AND next_id<9223372036854775807 RETURNING CAST(next_id AS TEXT) AS id",
      [],
    )
    is Some(next) else {
    raise StoreError("card outcome sequence is exhausted")
  }
  let id = js_text(col(next, "id"))
  ignore(
    self.run(
      "INSERT INTO card_outbox_head(id,thread,ts) SELECT CAST(? AS INTEGER),?,?\n    WHERE NOT EXISTS (SELECT 1 FROM card_outbox WHERE thread=? AND ts=? LIMIT 1)",
      [jstr(id), item.thread, item.ts, item.thread, item.ts],
    ),
  )
  ignore(
    self.run("INSERT INTO card_outbox(thread,ts,id,agent,field,close_card,outcome) VALUES(?,?,CAST(? AS INTEGER),?,?,?,?)", [
      item.thread,
      item.ts,
      jstr(id),
      item.agent,
      jstr(item.field),
      jint(if item.close { 1 } else { 0 }),
      jstr(outcome),
    ]),
  )
  id
}

///|
/// card-outbox.ts `saveWithCardOutcome`.
fn Store::save_with_card_outcome(self : Store, item : CardOutcome, save : () -> Unit raise) -> String raise {
  self.db.exec("SAVEPOINT card_outbox_save")
  self.depth += 1
  let work = () => {
    if !self.has_card_outbox() {
      self.install_card_outbox()
    }
    if item.field == "rig" {
      self.take_rig_outcomes()
    }
    save()
    let id = self.enqueue_card_outcome(item)
    self.depth -= 1
    self.db.exec("RELEASE card_outbox_save")
    id
  }
  work() catch {
    e => {
      self.depth -= 1
      self.db.exec("ROLLBACK TO card_outbox_save; RELEASE card_outbox_save") catch {
        _ => ()
      }
      raise e
    }
  }
}

///|
/// card-outbox.ts `cardOutcomeHeads`.
pub fn Store::card_outcome_heads(self : Store, after : String, limit : Int) -> Array[CardOutcome] raise {
  if limit < 1 || limit > 64 {
    raise StoreError("card outcome page must contain 1 to 64 cards")
  }
  self
  .all(
    "SELECT CAST(q.id AS TEXT) AS id,q.thread,q.ts,q.agent,q.field,q.close_card,q.outcome\n    FROM card_outbox_head h CROSS JOIN card_outbox q ON q.thread=h.thread AND q.ts=h.ts AND q.id=h.id\n    WHERE h.id>CAST(? AS INTEGER) ORDER BY h.id LIMIT ?",
    [jstr(after), jint(limit)],
  )
  .map(r => {
    id: js_text(col(r, "id")),
    thread: col(r, "thread"),
    ts: col(r, "ts"),
    agent: col(r, "agent"),
    field: js_text(col(r, "field")),
    close: is_num(col(r, "close_card"), 1.0),
    outcome: match col(r, "outcome") {
      String(s) => @jsjson.parse(s) catch { _ => Null }
      _ => Null
    },
  })
}

///|
/// card-outbox.ts `completeCardOutcome`.
fn Store::complete_card_outcome(self : Store, item : CardOutcome) -> Bool raise {
  if self.depth == 0 {
    raise StoreError("card outcome must be completed with its message edit in a transaction")
  }
  let removed = self.run("DELETE FROM card_outbox_head WHERE thread=? AND ts=? AND id=CAST(? AS INTEGER)", [
    item.thread,
    item.ts,
    jstr(item.id),
  ])
  if removed == 0 {
    return false
  }
  ignore(self.run("DELETE FROM card_outbox WHERE thread=? AND ts=? AND id=CAST(? AS INTEGER)", [item.thread, item.ts, jstr(item.id)]))
  ignore(
    self.run("INSERT INTO card_outbox_head(id,thread,ts)\n    SELECT id,thread,ts FROM card_outbox WHERE thread=? AND ts=? ORDER BY id LIMIT 1", [
      item.thread,
      item.ts,
    ]),
  )
  true
}

///|
/// store.ts `saveCardOutcome`: the request saved, its card closed where asked, its outcome queued, in one transaction;
/// the close told once it commits.
pub fn Store::save_card_outcome(self : Store, item : CardOutcome, save : () -> Unit raise) -> String raise {
  if self.depth > 0 {
    raise StoreError("card outcome save must run outside an existing transaction")
  }
  self.with_(changes => {
    let mut closed : Json? = None
    let id = self.tx(() => self.save_with_card_outcome(item, () => {
      save()
      if item.close {
        match
          self.one(
            "SELECT n FROM entries WHERE thread=? AND ts=? AND kind='message' AND author_kind='agent' AND author=? AND card IS NOT NULL",
            [item.thread, item.ts, item.agent],
          ) {
          Some(row) =>
            if self.run("INSERT OR IGNORE INTO closed_cards(thread,n,viewer,at) VALUES(?,?,?,?)", [
                item.thread,
                col(row, "n"),
                item.agent,
                self.now_json(),
              ]) >
              0 {
              closed = Some(col(row, "n"))
            }
          None => ()
        }
      }
    }))
    if closed is Some(n) {
      changes.push({ "type": "thread", "id": item.thread, "entries": [], "closed": n })
    }
    id
  })
}

// ── restating ──

///|
priv suberror Restate {
  Retry
  Repair
  Missing
  Stale
  Pending
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
impl Show for Restate with output(self, logger) {
  match self {
    Retry => logger.write_string("the outbox's write is to be tried again")
    Repair => logger.write_string("the outbox is to be repaired first")
    Missing => logger.write_string("the outbox's entry is missing")
    Stale => logger.write_string("the outbox's entry is stale")
    Pending => logger.write_string("the outbox's entry is still pending")
  }
}

///|
/// What a restatement read of its post: the message as merged, its card as last restated (None: none that parses),
/// and whether the merged lookup must be repaired first.
priv struct Current {
  message : Map[String, Json]
  card : @jsjson.JValue?
  broken : Bool
}

///|
/// card-outbox.ts `cardEditPage`: one bounded page of possible card edits, newest first.
pub fn card_edit_page(db : @sql.Db, thread : Json, target : String, before : String?) -> Json raise {
  let indexed = exists(db, "index", "entries_cards")
  let from = if indexed { "entries INDEXED BY entries_cards" } else { "entries" }
  let range = if before is Some(_) { " AND n<CAST(?3 AS INTEGER)" } else { "" }
  let params = match before {
    Some(b) => [thread, jstr(target), jstr(b)]
    None => [thread, jstr(target)]
  }
  let rows = db.all(
    "SELECT CAST(n AS TEXT) AS position,\n      CASE WHEN kind='edit' AND target=CAST(?2 AS INTEGER) THEN card ELSE NULL END AS card\n    FROM (SELECT n,kind,target,card FROM \{from} WHERE thread=?1\{if indexed { " AND card IS NOT NULL" } else { "" }}\{range}\n      ORDER BY n DESC LIMIT 64) ORDER BY n DESC",
    params,
  )
  for r in rows {
    if !(col(r, "card") is Null) {
      return { "kind": "found", "card": col(r, "card") }
    }
  }
  if rows.length() < 64 {
    { "kind": "end" }
  } else {
    { "kind": "next", "before": col(rows[rows.length() - 1], "position") }
  }
}

///|
/// card-outbox.ts `cardMessagePage`: an old message's last target entry, a page at a time.
pub fn card_message_page(db : @sql.Db, thread : Json, target : String, before : String?) -> Json raise {
  let range = if before is Some(_) { " AND n<CAST(?3 AS INTEGER)" } else { "" }
  let params = match before {
    Some(b) => [thread, jstr(target), jstr(b)]
    None => [thread, jstr(target)]
  }
  let row = one(
    db,
    "WITH page AS MATERIALIZED (\n      SELECT n,target FROM entries WHERE thread=?1\{range} ORDER BY n DESC LIMIT 512\n    ) SELECT (SELECT CAST(n AS TEXT) FROM page WHERE target=CAST(?2 AS INTEGER) ORDER BY n DESC LIMIT 1) AS edit,\n      CAST(MIN(n) AS TEXT) AS before,COUNT(*) AS count FROM page",
    params,
  ).unwrap()
  if !(col(row, "edit") is Null) {
    return { "kind": "found", "n": col(row, "edit") }
  }
  if num(col(row, "count")) < 512.0 {
    { "kind": "end" }
  } else {
    { "kind": "next", "before": col(row, "before") }
  }
}

///|
/// `{ ...card, [field]: { ...card?.[field], outcome } }`.
fn with_outcome(card : @jsjson.JValue?, field : String, outcome : @jsjson.JValue) -> @jsjson.JValue {
  let base = card.unwrap_or(Null)
  let inner = match base {
    Obj(_) => jget(base, field).unwrap_or(Null)
    _ => Null
  }
  jset(base, field, jset(inner, "outcome", outcome))
}

///|
/// store.ts `restateCard`: the author's card restated on its post, by `card`. Whether the post was found.
pub fn Store::restate_card(self : Store, agent : Json, thread : Json, ts : Json, card : (@jsjson.JValue?) -> @jsjson.JValue raise) -> Json raise {
  match self.restate(agent, thread, ts, card, None, None) {
    Some(b) => jbool(b)
    None => undefined
  }
}

///|
/// store.ts `restateQueuedCard`: the oldest queued outcome applied to its card (or discarded where its post is gone).
/// Some(false): another consumer advanced that card; None (undefined): its old edits need a guarded paged read.
pub fn Store::restate_queued_card(self : Store, item : CardOutcome, prepared : Prepared?) -> Bool? raise {
  if prepared is Some(p) && (p.scan.thread != item.thread || p.scan.ts != item.ts || p.scan.agent != item.agent) {
    raise StoreError("card scan belongs to a different outcome")
  }
  let result = self.try_now(() => self.restate(
    item.agent,
    item.thread,
    item.ts,
    card => with_outcome(card, item.field, item.outcome),
    Some(item),
    prepared,
  )) catch {
    e => {
      if prepared is Some(p) {
        self.end_card_edit_scan(p.scan) catch {
          _ => ()
        }
      }
      raise e
    }
  }
  if prepared is Some(p) {
    self.end_card_edit_scan(p.scan) catch {
      _ => ()
    }
  }
  result
}

///|
/// store.ts `beginCardEditScan`: the target guarded before a worker pages through its older card edits.
pub fn Store::begin_card_edit_scan(self : Store, item : CardOutcome) -> CardEditScan? raise {
  self.try_now(() => {
    let find = "SELECT CAST(n AS TEXT) AS n FROM entries WHERE thread=? AND ts=? AND kind='message' AND author_kind='agent' AND author=? AND card IS NOT NULL"
    guard self.one(find, [item.thread, item.ts, item.agent]) is Some(first) else { return None }
    let checked = self.ensure_guard(true)
    let token = self.token()
    let target = js_text(col(first, "n"))
    let registered = self.tx(
      () => {
        if schema_version(self.db) != checked {
          return false
        }
        let has_ts = if exists(self.db, "index", "entries_ts") { 1 } else { 0 }
        ignore(
          self.run("UPDATE card_scan_meta SET schema_version=?,has_ts_index=? WHERE id=1\n          AND (schema_version<>? OR has_ts_index<>?)", [
            jint(checked),
            jint(has_ts),
            jint(checked),
            jint(has_ts),
          ]),
        )
        ignore(
          self.run(
            "INSERT INTO card_scan_guard(thread,target,token,dirty) VALUES(?,CAST(? AS INTEGER),?,0)\n          ON CONFLICT(thread,target) DO UPDATE SET token=excluded.token,dirty=0",
            [item.thread, jstr(target), jstr(token)],
          ),
        )
        true
      },
      try_write=true,
    )
    if !registered {
      return None
    }
    let mut keep = false
    let scan = self.snapshot("card_edit_scan", () => {
      let schema = schema_version(self.db)
      let row = self.one(find, [item.thread, item.ts, item.agent])
      let guard_row = self.one("SELECT token,dirty FROM card_scan_guard WHERE thread=? AND target=CAST(? AS INTEGER)", [
        item.thread,
        jstr(target),
      ])
      guard schema == checked &&
        row is Some(r) &&
        js_text(col(r, "n")) == target &&
        guard_row is Some(g) &&
        col(g, "token") == jstr(token) &&
        is_num(col(g, "dirty"), 0.0) else {
        return None
      }
      keep = true
      Some({ thread: item.thread, ts: item.ts, agent: item.agent, target, token, schema })
    }) catch {
      e => {
        ignore(
          self.run("DELETE FROM card_scan_guard WHERE thread=? AND target=CAST(? AS INTEGER) AND token=?", [
            item.thread,
            jstr(target),
            jstr(token),
          ]),
        )
        raise e
      }
    }
    if !keep {
      ignore(
        self.run("DELETE FROM card_scan_guard WHERE thread=? AND target=CAST(? AS INTEGER) AND token=?", [
          item.thread,
          jstr(target),
          jstr(token),
        ]),
      )
    }
    scan
  })
}

///|
pub fn Store::end_card_edit_scan(self : Store, scan : CardEditScan) -> Unit raise {
  self.try_now(() => ignore(
    self.run("DELETE FROM card_scan_guard WHERE thread=? AND target=CAST(? AS INTEGER) AND token=?", [
      scan.thread,
      jstr(scan.target),
      jstr(scan.token),
    ]),
  ))
}

///|
/// store.ts `#restateCard`.
fn Store::restate(
  self : Store,
  agent : Json,
  thread : Json,
  ts : Json,
  card : (@jsjson.JValue?) -> @jsjson.JValue raise,
  queued : CardOutcome?,
  prepared : Prepared?,
) -> Bool? raise {
  self.with_(changes => {
    let post_sql = "SELECT 1 FROM entries WHERE thread=? AND ts=? AND kind='message' AND author_kind='agent' AND author=? AND card IS NOT NULL"
    let post_exists = () => self.one(post_sql, [thread, ts, agent]) is Some(_)
    let discard = () => self.tx(
      () => {
        if post_exists() {
          return None
        }
        Some(self.complete_card_outcome(queued.unwrap()))
      },
      try_write=true,
    )
    if !post_exists() {
      guard queued is Some(_) else { return Some(false) }
      if discard() is Some(result) {
        return Some(result)
      }
    }
    // the message and its card as last restated; Err(()) where it is undefined
    let read = fn() -> Result[Current?, Unit] raise {
      guard
        self.one(
          "SELECT CAST(n AS TEXT) AS n,card FROM entries WHERE thread = ? AND ts = ? AND kind = 'message' AND author_kind = 'agent' AND author = ? AND card IS NOT NULL",
          [thread, ts, agent],
        )
        is Some(r) else {
        return Ok(None)
      }
      let rn = js_text(col(r, "n"))
      if prepared is Some(p) && p.scan.target != rn {
        return Err(())
      }
      let mode = legacy_merged_edit_mode(self.db)
      if queued is Some(_) {
        // last: None undefined, Some(None) null, Some(Some(card))
        let mut last : String?? = None
        let message = if legacy_merged_read_ready(self.db) {
          match self.message_at(thread, ts) {
            Object(m) => Some(m)
            _ => None
          }
        } else {
          let edit : String?? = match prepared {
            Some(p) => p.edit
            None =>
              match bounded_edit_key(self.db, thread, rn) {
                Ok(e) => Some(e)
                Err(_) => None
              }
          }
          guard edit is Some(edit) else { return Err(()) }
          let row = self.one(last_message_with_edit_sql, [thread, jstr(rn), jopt(edit)])
          let message = match row {
            Some(row) =>
              match message_of(row) {
                Object(m) => Some(m)
                _ => None
              }
            None => None
          }
          match edit {
            None => last = Some(None)
            Some(e) =>
              match self.one("SELECT kind,card FROM entries WHERE thread=? AND n=CAST(? AS INTEGER)", [thread, jstr(e)]) {
                Some(entry) if col(entry, "kind") == jstr("edit") && !(col(entry, "card") is Null) =>
                  last = Some(text_of(col(entry, "card")))
                _ => ()
              }
          }
          message
        }
        guard message is Some(message) else { return Ok(None) }
        if prepared is Some(p) {
          last = Some(p.card)
        } else if last is None {
          last = match bounded_card_edit(self.db, thread, rn, mode == "native") {
            Ok(c) => Some(c)
            Err(_) => None
          }
        }
        guard last is Some(last) else { return Err(()) }
        let text = match last {
          Some(c) => jstr(c)
          None => col(r, "card")
        }
        return Ok(Some({ message, card: parsed(text), broken: false }))
      }
      let broken = mode == "repair"
      let message = if broken {
        let latest = match
          self.one("SELECT CAST(MAX(n) AS TEXT) AS n FROM entries WHERE thread=?1 AND target=CAST(?2 AS INTEGER)", [thread, jstr(rn)]) {
          Some(x) => col(x, "n")
          None => Json::null()
        }
        match self.one(last_message_with_edit_sql, [thread, jstr(rn), latest]) {
          Some(row) =>
            match message_of(row) {
              Object(m) => Some(m)
              _ => None
            }
          None => None
        }
      } else {
        match self.message_at(thread, ts) {
          Object(m) => Some(m)
          _ => None
        }
      }
      guard message is Some(message) else { return Ok(None) }
      let last = if mode == "legacy" || mode == "legacy-old-index" {
        let latest = if mode == "legacy-old-index" { legacy_card_edit_latest_old_index_sql } else { legacy_card_edit_latest_sql }
        self.one("SELECT x.card FROM entries x WHERE x.thread=?1 AND x.n=(\{latest})", [thread, jstr(rn)])
      } else {
        self.one("SELECT card FROM entries WHERE thread = ? AND kind = 'edit' AND target = ? AND card IS NOT NULL ORDER BY n DESC LIMIT 1", [
          thread,
          jstr(rn),
        ])
      }
      let text = match last {
        Some(l) if !(col(l, "card") is Null) => col(l, "card")
        _ => col(r, "card")
      }
      Ok(Some({ message, card: parsed(text), broken }))
    }
    let token = match prepared {
      Some(p) => p.scan.token
      None => self.token()
    }
    let mut retries = 0
    let mut registered = prepared is Some(_)
    let release = () => if registered {
      (try {
        match prepared {
          Some(p) =>
            ignore(
              self.run("DELETE FROM card_scan_guard WHERE thread=? AND target=CAST(? AS INTEGER) AND token=?", [
                thread,
                jstr(p.scan.target),
                jstr(token),
              ]),
            )
          None => ignore(self.run("DELETE FROM restate_guard WHERE thread=? AND token=?", [thread, jstr(token)]))
        }
      } catch {
        _ => ()
      }) |> ignore
    }
    let outcome = (fn() -> Bool? raise {
      while true {
        let checked_schema = match prepared {
          Some(p) => p.scan.schema
          None => self.ensure_guard(false)
        }
        if prepared is None {
          let inserted = try {
            ignore(
              self.run("INSERT INTO restate_guard(thread,token,dirty) VALUES(?,?,0)\n                ON CONFLICT(thread) DO UPDATE SET token=excluded.token,dirty=0", [
                thread,
                jstr(token),
              ]),
            )
            true
          } catch {
            e => {
              if schema_version(self.db) != checked_schema {
                retries += 1
                false
              } else {
                raise e
              }
            }
          }
          if !inserted {
            continue
          }
          registered = true
        }
        let (current, schema) = self.snapshot("restate_card_read", () => {
          let schema = schema_version(self.db)
          let guard_row = match prepared {
            Some(p) =>
              self.one("SELECT token,dirty FROM card_scan_guard WHERE thread=? AND target=CAST(? AS INTEGER)", [
                thread,
                jstr(p.scan.target),
              ])
            None => None
          }
          let stale = prepared is Some(_) &&
            (
              schema != checked_schema ||
              !(guard_row is Some(g) && col(g, "token") == jstr(token) && is_num(col(g, "dirty"), 0.0))
            )
          let current = if stale { Err(()) } else { read() }
          (current, schema)
        })
        guard current is Ok(current) else { return None }
        guard current is Some(current) else {
          guard queued is Some(_) else { return Some(false) }
          if discard() is Some(result) {
            return Some(result)
          }
          continue
        }
        if schema != checked_schema {
          retries += 1
          continue
        }
        if current.broken || @store_schema.widget_source_before_add_needs_repair(self.db) {
          repair_merged_edit_lookup(self.db)
        }
        let mut current = current
        let field = (k : String) => current.message.get(k).unwrap_or(Json::null())
        let entry : Entry = {
          agent_identity: None,
          thread,
          n: 0.0,
          kind: "edit",
          target: field("n"),
          ts: Json::null(),
          author_kind: text_of(field("authorKind")).unwrap_or(""),
          author: text_of(field("author")).unwrap_or(""),
          text: field("text"),
          attachments: values_of(field("attachments")),
          quotes: values_of(field("quotes")),
          declared: Json::null(),
          client: Json::null(),
          profile: Json::null(),
          runtime: Json::null(),
          options: None,
          card: None,
          at: self.now_json(),
          letter: None,
          change: None,
        }
        let mut closed : Json? = None
        let attempt = try {
          self.append(
            entry,
            changes,
            before=Some(() => {
              if schema_version(self.db) != schema {
                raise Retry
              }
              if legacy_merged_needs_repair(self.db) || @store_schema.widget_source_before_add_needs_repair(self.db) {
                raise Repair
              }
              let guard_row = match prepared {
                Some(p) =>
                  self.one("SELECT token,dirty FROM card_scan_guard WHERE thread=? AND target=CAST(? AS INTEGER)", [
                    thread,
                    jstr(p.scan.target),
                  ])
                None => self.one("SELECT token,dirty FROM restate_guard WHERE thread=?", [thread])
              }
              if !(guard_row is Some(g) && col(g, "token") == jstr(token) && is_num(col(g, "dirty"), 0.0)) {
                if prepared is Some(_) {
                  raise Retry
                }
                if retries < 1 {
                  raise Retry
                }
                match read() {
                  Err(_) => raise Pending
                  Ok(None) => raise Missing
                  Ok(Some(c)) => {
                    if c.broken {
                      raise Repair
                    }
                    current = c
                    let f = (k : String) => c.message.get(k).unwrap_or(Json::null())
                    entry.target = f("n")
                    entry.author_kind = text_of(f("authorKind")).unwrap_or("")
                    entry.author = text_of(f("author")).unwrap_or("")
                    entry.text = f("text")
                    entry.attachments = values_of(f("attachments"))
                    entry.quotes = values_of(f("quotes"))
                  }
                }
              }
              match prepared {
                Some(p) =>
                  ignore(
                    self.run("DELETE FROM card_scan_guard WHERE thread=? AND target=CAST(? AS INTEGER) AND token=?", [
                      thread,
                      jstr(p.scan.target),
                      jstr(token),
                    ]),
                  )
                None => ignore(self.run("DELETE FROM restate_guard WHERE thread=? AND token=?", [thread, jstr(token)]))
              }
              if queued is Some(q) {
                if !self.complete_card_outcome(q) {
                  raise Stale
                }
                let n = current.message.get("n").unwrap_or(Json::null())
                if q.close &&
                  self.run("INSERT OR IGNORE INTO closed_cards (thread,n,viewer,at) VALUES (?,?,?,?)", [thread, n, agent, self.now_json()]) >
                  0 {
                  closed = Some(n)
                }
              }
              entry.card = Some(card(current.card))
            }),
            try_write=queued is Some(_),
            committed=Some(() => if closed is Some(n) {
              changes.push({ "type": "thread", "id": thread, "entries": [], "closed": n })
            }),
          )
          Ok(())
        } catch {
          e => Err(e)
        }
        match attempt {
          Ok(_) => {
            registered = false
            return Some(true)
          }
          Err(Pending) => return None
          Err(Stale) => return Some(false)
          Err(Missing) => {
            guard queued is Some(_) else { return Some(false) }
            if discard() is Some(result) {
              return Some(result)
            }
            continue
          }
          Err(Retry) => {
            if prepared is Some(_) {
              return None
            }
            retries += 1
            continue
          }
          Err(Repair) => {
            repair_merged_edit_lookup(self.db)
            if prepared is Some(_) {
              return None
            }
            retries += 1
            continue
          }
          Err(e) => raise e
        }
      }
      None
    })() catch {
      e => {
        release()
        raise e
      }
    }
    release()
    outcome
  })
}
