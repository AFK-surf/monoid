// A queued card outcome's pages (station/src/store/card-outbox.ts `cardEditPage`, `cardMessagePage`; read/pool.ts
// `cardEditPage`, `cardMessagePage`): one bounded page at a time, newest first, its cursor and what it found SQLite's
// integers as text. The station's own reads, never a device's (reader/serve.mbt routes none here, and `changed` reads
// only lists).

///|
/// The args of a card page: the chat, the target's number as text, and where the last page ended (none: the first).
fn card_page_args(args : Json) -> (Json, Json, Json?) {
  let thread = args.value("thread").unwrap_or(Json::null())
  let target = args.value("target").unwrap_or(Json::null())
  let before = match args.value("before") {
    Some(Null) | None => None
    Some(b) => Some(b)
  }
  (thread, target, before)
}

///|
/// card-outbox.ts `cardMessagePage`: the newest entry of the chat at `target`'s message among a page of 512 entries.
pub fn card_message_page(db : @sql.Db, args : Json) -> Json raise {
  let (thread, target, before) = card_page_args(args)
  let range = if before is None { "" } else { " AND n<CAST(?3 AS INTEGER)" }
  let params = match before {
    None => [thread, target]
    Some(b) => [thread, target, b]
  }
  let rows = db.all(
    "WITH page AS MATERIALIZED (\n      SELECT n,target FROM entries WHERE thread=?1\{range} ORDER BY n DESC LIMIT 512\n    ) SELECT (SELECT CAST(n AS TEXT) FROM page WHERE target=CAST(?2 AS INTEGER) ORDER BY n DESC LIMIT 1) AS edit,\n      CAST(MIN(n) AS TEXT) AS before,COUNT(*) AS count FROM page",
    params,
  )
  guard rows.get(0) is Some(row) else { return { "kind": "end" } }
  if row.get("edit") is Some(String(_) as edit) {
    return { "kind": "found", "n": edit }
  }
  let count = match row.get("count") {
    Some(Number(c, ..)) => c
    _ => 0.0
  }
  if count < 512.0 {
    { "kind": "end" }
  } else {
    { "kind": "next", "before": row.get("before").unwrap_or(Json::null()) }
  }
}

///|
/// card-outbox.ts `cardEditPage`: a page of 64 of the chat's entries with a card (by `entries_cards` where it is
/// there), the newest edit of `target` with a card among them.
pub fn card_edit_page(db : @sql.Db, args : Json) -> Json raise {
  let (thread, target, before) = card_page_args(args)
  let indexed = db.all("SELECT 1 AS x FROM sqlite_master WHERE type='index' AND name='entries_cards'", []).length() > 0
  let from = if indexed { "entries INDEXED BY entries_cards" } else { "entries" }
  let carded = if indexed { " AND card IS NOT NULL" } else { "" }
  let range = if before is None { "" } else { " AND n<CAST(?3 AS INTEGER)" }
  let params = match before {
    None => [thread, target]
    Some(b) => [thread, target, b]
  }
  let rows = db.all(
    "SELECT CAST(n AS TEXT) AS position,\n      CASE WHEN kind='edit' AND target=CAST(?2 AS INTEGER) THEN card ELSE NULL END AS card\n    FROM (SELECT n,kind,target,card FROM \{from} WHERE thread=?1\{carded}\{range}\n      ORDER BY n DESC LIMIT 64) ORDER BY n DESC",
    params,
  )
  for row in rows {
    match row.get("card") {
      Some(Null) | None => ()
      Some(card) => return { "kind": "found", "card": card }
    }
  }
  if rows.length() < 64 {
    { "kind": "end" }
  } else {
    { "kind": "next", "before": rows[rows.length() - 1].get("position").unwrap_or(Json::null()) }
  }
}
