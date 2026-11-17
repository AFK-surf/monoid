// The store's opening driven by the station's tests (reader `--builder harness-store-schema --db <path>`,
// station/test/mb-store-schema.test.ts): each line an ask, answered by a line, each on a connection of its own.
// - {"op": "open", "now": ms, "archive"?: dir}: the database opened as Store.open opens it;
// - {"op": "compact"}, {"op": "stop"}, {"op": "left"}: what usage/module.ts does once the station before has gone
//   (installCompactUsage, stopUsageIndexes, usageIndexesLeft);
// - {"op": "repair"}: the writer's repair of the merged view (repairMergedEditLookup);
// - {"op": "outbox", "rig"?: true}: the card outcomes' queue as a request's save makes it (installCardOutbox, and
//   takeRigOutcomes for a rig's card, in a savepoint).
// Answered {"done": true} (with "left" for "left"), or {"error": words}.

///|
fn words(e : Error) -> String {
  match e {
    Refused(m) => m
    @wire.ShellError(m) => m
    Failure(m) => m
    e => e.to_string()
  }
}

///|
/// One ask on a connection of its own to `path`.
fn answer(host : @host.Host, path : String, ask : Json) -> Json raise {
  let db = @sql.Db::create(host, path, wait=5000)
  defer db.close()
  match ask {
    { "op": "open", "now": Number(now, ..), "archive": String(archive), .. } => {
      open(db, host, path, now.to_int64(), archive~)
      { "done": true }
    }
    { "op": "open", "now": Number(now, ..), .. } => {
      open(db, host, path, now.to_int64())
      { "done": true }
    }
    { "op": "compact", .. } => {
      install_compact_usage(db)
      { "done": true }
    }
    { "op": "stop", .. } => {
      stop_usage_indexes(db)
      { "done": true }
    }
    { "op": "left", .. } => { "done": true, "left": Json::boolean(usage_indexes_left(db)) }
    { "op": "repair", .. } => {
      repair_merged_edit_lookup(db)
      { "done": true }
    }
    { "op": "outbox", .. } => {
      db.exec("SAVEPOINT card_outbox_save")
      errdefer (db.exec("ROLLBACK TO card_outbox_save; RELEASE card_outbox_save") catch { _ => () })
      if !has_card_outbox(db) {
        install_card_outbox(db)
      }
      if ask is { "rig": True, .. } {
        take_rig_outcomes(db)
      }
      db.exec("RELEASE card_outbox_save")
      { "done": true }
    }
    _ => { "error": "invalid store schema request" }
  }
}

///|
/// The harness: the asks on stdin, each answered on stdout.
pub async fn harness(host : @host.Host, path : String) -> Unit {
  while host.line() is Some(line) {
    if line == "" {
      continue
    }
    let ask : Json = @json.parse(line) catch { _ => Json::null() }
    let said : Json = answer(host, path, ask) catch { e => { "error": Json::string(words(e)) } }
    host.say(said.stringify())
  }
}
