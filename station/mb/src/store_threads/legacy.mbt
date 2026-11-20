// What the store asks of an older database's lookups, each read as the TypeScript reads it (legacy-said-build.ts,
// legacy-login-cards.ts, archive-policy-index.ts, legacy-decision-time.ts, legacy-decision-session.ts,
// legacy-edits-build.ts, legacy-edits-read.ts, widget-sources.ts, schema.ts `repairMergedEditLookup`).

///|
fn sql_of(db : @sql.Db, kind : String, name : String) -> String? raise {
  match one(db, "SELECT sql FROM sqlite_master WHERE type=? AND name=?", [jstr(kind), jstr(name)]) {
    Some(r) => text_of(col(r, "sql"))
    None => None
  }
}

///|
fn scanned_ok(m : Map[String, Json], name : String) -> Bool {
  is_num(col(m, name), 0.0) || is_num(col(m, name), 1.0)
}

///|
/// legacy-said-build.ts `hasLegacySaid`.
fn has_legacy_said(db : @sql.Db) -> Bool raise {
  if !exists(db, "view", "legacy_said") {
    return false
  }
  if !exists(db, "table", "legacy_said_meta") {
    raise StoreError("legacy said view has no metadata")
  }
  guard one(db, "SELECT version,scanned FROM legacy_said_meta WHERE id=1", []) is Some(m) &&
    is_num(col(m, "version"), 1.0) &&
    scanned_ok(m, "scanned") else {
    raise StoreError("legacy said view has an unsupported version")
  }
  true
}

///|
/// legacy-login-cards.ts `hasLegacyLoginCards`.
fn has_legacy_login_cards(db : @sql.Db) -> Bool raise {
  if !exists(db, "table", "login_card_meta") {
    return false
  }
  guard one(db, "SELECT version,scanned FROM login_card_meta WHERE id=1", []) is Some(m) &&
    is_num(col(m, "version"), 1.0) &&
    scanned_ok(m, "scanned") else {
    raise StoreError("legacy login-card lookup has an unsupported version")
  }
  true
}

///|
/// archive-policy-index.ts `hasLegacyArchivePolicy`.
fn has_legacy_archive_policy(db : @sql.Db) -> Bool raise {
  if !exists(db, "table", "archive_policy_lookup_meta") {
    return false
  }
  guard one(db, "SELECT version,complete FROM archive_policy_lookup_meta WHERE id=1", []) is Some(m) &&
    is_num(col(m, "version"), 1.0) &&
    scanned_ok(m, "complete") else {
    raise StoreError("archive policy lookup has an unsupported version")
  }
  true
}

///|
/// legacy-decision-time.ts `hasLegacyDecisionTime`.
fn has_legacy_decision_time(db : @sql.Db) -> Bool raise {
  if !exists(db, "table", "legacy_decision_time_meta") {
    return false
  }
  if !exists(db, "table", "legacy_decision_time") {
    raise StoreError("legacy decision-time metadata has no lookup")
  }
  guard one(db, "SELECT version,complete FROM legacy_decision_time_meta WHERE id=1", []) is Some(m) &&
    is_num(col(m, "version"), 1.0) &&
    scanned_ok(m, "complete") else {
    raise StoreError("legacy decision-time lookup has an unsupported version")
  }
  true
}

///|
/// legacy-decision-session.ts `sessionState`.
fn session_state(db : @sql.Db, table : String) -> Int? raise {
  if !exists(db, "table", "\{table}_meta") {
    return None
  }
  if !exists(db, "table", table) {
    raise StoreError("legacy decision-session metadata has no lookup")
  }
  guard one(db, "SELECT version,complete FROM \{table}_meta WHERE id=1", []) is Some(m) &&
    is_num(col(m, "version"), 1.0) &&
    (
      scanned_ok(m, "complete") ||
      (table == "legacy_decision_session_repair" && is_num(col(m, "complete"), 2.0))
    ) else {
    raise StoreError("legacy decision-session lookup has an unsupported version")
  }
  Some(num(col(m, "complete")).to_int())
}

///|
/// legacy-decision-session.ts `hasSessionLookup`.
fn has_session_lookup(db : @sql.Db, table : String) -> Bool raise {
  match session_state(db, table) {
    None | Some(2) => false
    Some(_) => exists(db, "index", "\{table}_by_session")
  }
}

///|
/// legacy-decision-session.ts `hasSharedDecisionSession`.
fn has_shared_decision_session(db : @sql.Db) -> Bool raise {
  if !exists(db, "index", "legacy_decision_time_by_session") {
    return false
  }
  if !has_legacy_decision_time(db) {
    raise StoreError("shared decision-session index has no time lookup")
  }
  true
}

///|
/// legacy-edits-build.ts `hasLegacyEdits`.
fn has_legacy_edits(db : @sql.Db) -> Bool raise {
  if !exists(db, "table", "legacy_edit_meta") {
    return false
  }
  guard one(db, "SELECT version,scanned,old_index FROM legacy_edit_meta WHERE id=1", []) is Some(m) &&
    is_num(col(m, "version"), 1.0) &&
    scanned_ok(m, "scanned") &&
    scanned_ok(m, "old_index") else {
    raise StoreError("legacy edit lookup has an unsupported version")
  }
  true
}

///|
/// legacy-edits-build.ts `hasOldEditIndex`.
fn has_old_edit_index(db : @sql.Db) -> Bool raise {
  let columns = db.all("SELECT name,coll FROM pragma_index_xinfo('entries_target') WHERE \"key\"=1 ORDER BY seqno", [])
  guard columns is [a, b] &&
    col(a, "name") == jstr("thread") &&
    col(a, "coll") == jstr("BINARY") &&
    col(b, "name") == jstr("target") &&
    col(b, "coll") == jstr("BINARY") else {
    return false
  }
  ignore(
    db.all("EXPLAIN QUERY PLAN SELECT MAX(n) FROM entries INDEXED BY entries_target WHERE thread=? AND target=?", [
      jint(0),
      jint(0),
    ]),
  ) catch {
    _ => return false
  }
  true
}

///|
/// legacy-edits-build.ts `usesLegacyEdits`.
fn uses_legacy_edits(db : @sql.Db) -> Bool raise {
  !exists(db, "index", "entries_edits") && has_legacy_edits(db)
}

///|
/// legacy-edits-build.ts `legacyEditsUseOldIndex`.
fn legacy_edits_use_old_index(db : @sql.Db) -> Bool raise {
  if !has_legacy_edits(db) {
    raise StoreError("legacy edit lookup has not been installed")
  }
  match one(db, "SELECT old_index FROM legacy_edit_meta WHERE id=1", []) {
    Some(r) => is_num(col(r, "old_index"), 1.0)
    None => false
  }
}

///|
/// legacy-edits-build.ts `mergedView`.
priv struct MergedView {
  legacy : Bool
  indexed : Bool
  old_index : Bool
  old_index_missing : Bool
}

///|
fn merged_view(db : @sql.Db) -> MergedView raise {
  let sql = sql_of(db, "view", "merged")
  let legacy = sql is Some(s) && s.contains("legacy_edit_meta")
  let old_index = legacy && sql is Some(s) && s.contains("INDEXED BY entries_target")
  {
    legacy,
    indexed: exists(db, "index", "entries_edits"),
    old_index,
    old_index_missing: old_index && !has_old_edit_index(db),
  }
}

///|
/// legacy-edits-build.ts `legacyMergedNeedsRepair`.
fn legacy_merged_needs_repair(db : @sql.Db) -> Bool raise {
  let view = merged_view(db)
  view.old_index_missing || (!view.legacy && !view.indexed)
}

///|
/// legacy-edits-build.ts `legacyMergedEditMode`.
fn legacy_merged_edit_mode(db : @sql.Db) -> String raise {
  let view = merged_view(db)
  if view.old_index_missing || (!view.legacy && !view.indexed) {
    return "repair"
  }
  if view.indexed {
    return "native"
  }
  if view.old_index {
    "legacy-old-index"
  } else {
    "legacy"
  }
}

///|
/// legacy-edits-build.ts `legacyMergedReadReady`.
fn legacy_merged_read_ready(db : @sql.Db) -> Bool raise {
  let view = merged_view(db)
  if view.old_index_missing {
    return false
  }
  if !view.legacy {
    return view.indexed
  }
  guard one(
      db,
      "SELECT scanned=1 AND NOT EXISTS (SELECT 1 FROM legacy_edit_dirty LIMIT 1 OFFSET 64) AS ready\n    FROM legacy_edit_meta WHERE id=1",
      [],
    )
    is Some(r) else {
    raise StoreError("legacy edit lookup metadata is missing")
  }
  is_num(col(r, "ready"), 1.0)
}

///|
/// legacy-edits-read.ts `boundedEditKey`: the latest edit's key (text), None when there is none, or `Err(())`
/// (undefined) when old edits need preparation.
fn bounded_edit_key(db : @sql.Db, thread : Json, n : String) -> Result[String?, Unit] raise {
  let read = (sql : String) => one(db, sql, [thread, jstr(n)])
  let mut edit = read(last_message_recent_edit_sql)
  let count = (e : Map[String, Json]?) => match e {
    Some(r) => num(col(r, "count")).to_int()
    None => 0
  }
  let key = (e : Map[String, Json]?) => match e {
    Some(r) => text_of(col(r, "n"))
    None => None
  }
  if key(edit) is None && count(edit) == 65 {
    let meta = if has_legacy_edits(db) {
      one(db, "SELECT scanned,old_index FROM legacy_edit_meta WHERE id=1", [])
    } else {
      None
    }
    if meta is Some(m) &&
      is_num(col(m, "scanned"), 0.0) &&
      is_num(col(m, "old_index"), 1.0) &&
      has_old_edit_index(db) {
      edit = read(last_message_old_edits_sql)
    }
    if count(edit) == 65 {
      return Err(())
    }
  }
  Ok(key(edit))
}

///|
/// legacy-edits-read.ts `boundedCardEdit`: the latest card-bearing edit's card (None: none), or `Err(())` when a full
/// page held no answer.
fn bounded_card_edit(db : @sql.Db, thread : Json, n : String, native : Bool) -> Result[String?, Unit] raise {
  let probe = (index : String) => {
    let from = match index {
      "edits" => "entries INDEXED BY entries_edits WHERE thread=?1 AND target=CAST(?2 AS INTEGER)"
      "cards" => "entries INDEXED BY entries_cards WHERE thread=?1 AND card IS NOT NULL"
      _ => "entries WHERE thread=?1"
    }
    let r = one(
      db,
      "WITH candidates AS MATERIALIZED (\n      SELECT n,kind,target,card FROM \{from} ORDER BY n DESC LIMIT 65\n    ) SELECT (SELECT card FROM candidates WHERE kind='edit' AND target=CAST(?2 AS INTEGER)\n      AND card IS NOT NULL ORDER BY n DESC LIMIT 1) AS card,(SELECT COUNT(*) FROM candidates) AS count",
      [thread, jstr(n)],
    )
    match r {
      Some(r) => (text_of(col(r, "card")), num(col(r, "count")).to_int())
      None => (None, 0)
    }
  }
  if native {
    let (card, count) = probe("edits")
    if card is Some(_) || count < 65 {
      return Ok(card)
    }
  }
  let has_cards = exists(db, "index", "entries_cards")
  let (card, count) = probe(if has_cards { "cards" } else { "tail" })
  if card is Some(_) || count < 65 {
    Ok(card)
  } else {
    Err(())
  }
}

///|
/// legacy-edits-build.ts `installLegacyEdits(db, true)`.
fn install_legacy_edits(db : @sql.Db) -> Bool raise {
  if has_legacy_edits(db) {
    return true
  }
  if !exists(db, "index", "entries_ts") {
    raise StoreError("legacy edit preparation requires entries_ts")
  }
  db.exec("BEGIN IMMEDIATE")
  let done = () => {
    if !has_legacy_edits(db) && !exists(db, "index", "entries_edits") {
      db.exec(if has_old_edit_index(db) { legacy_edits_schema_old_index_sql } else { legacy_edits_schema_sql })
    }
    db.exec("COMMIT")
    has_legacy_edits(db)
  }
  done() catch {
    e => {
      db.exec("ROLLBACK") catch {
        _ => ()
      }
      raise e
    }
  }
}

///|
/// schema.ts `repairMergedEditLookup`.
fn repair_merged_edit_lookup(db : @sql.Db) -> Unit raise {
  let view = () => sql_of(db, "view", "merged").unwrap_or("")
  let has_edit_index = () => exists(db, "index", "entries_edits")
  let needs_repair = (sql : String) => if sql.contains("legacy_edit_meta") {
    sql.contains("INDEXED BY entries_target") && !has_old_edit_index(db)
  } else {
    !has_edit_index()
  }
  let view_needs_repair = needs_repair(view())
  if !view_needs_repair && !@store_schema.widget_source_before_add_needs_repair(db) {
    return
  }
  if view_needs_repair && !has_edit_index() {
    ignore(install_legacy_edits(db))
  }
  db.exec("BEGIN IMMEDIATE")
  let work = () => {
    if needs_repair(view()) {
      if has_legacy_edits(db) && legacy_edits_use_old_index(db) && !has_old_edit_index(db) {
        ignore(db.run("UPDATE legacy_edit_meta SET old_index=0 WHERE id=1", []))
      }
      let merged = if uses_legacy_edits(db) {
        if legacy_edits_use_old_index(db) {
          merged_legacy_old_index_sql
        } else {
          merged_legacy_sql
        }
      } else {
        merged_sql
      }
      db.exec("DROP VIEW IF EXISTS merged; \{merged}")
    }
    @store_schema.repair_widget_source_before_add(db)
    db.exec("COMMIT")
  }
  work() catch {
    e => {
      db.exec("ROLLBACK") catch {
        _ => ()
      }
      raise e
    }
  }
}

///|
/// legacy-said-build.ts `legacySaidReadHead`: (known, the latest ordinary message's n, author_kind, author).
fn legacy_said_read_head(db : @sql.Db, thread : Json) -> (Bool, Map[String, Json]?) raise {
  guard one(db, @readops.legacy_said_head_first_sql, [thread]) is Some(first) else { return (true, None) }
  if !(col(first, "n") is Null) {
    return (true, Some(first))
  }
  if one(db, @readops.legacy_said_needs_drain_sql, [thread]) is None {
    return (true, one(db, @readops.legacy_said_latest_sql, [thread]))
  }
  guard one(db, @readops.legacy_said_head_tail_sql, [thread]) is Some(tail) else { return (false, None) }
  if !(col(tail, "n") is Null) {
    return (true, Some(tail))
  }
  (num(col(tail, "count")) < 65.0, None)
}
