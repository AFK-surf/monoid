// station/src/read/store.ts's reads that station/readops does not give as reads of their own (its `original_runtime`,
// `pending_card_number`, `state_pending_card` and `state_question` it gives already): a session, a thread and its
// members as the database has them, and which threads ever had a card.

///|
fn row_json(r : Map[String, Json]) -> Json {
  Json::object(r)
}

///|
/// store.ts `getSession`'s row (its columns as they are), None where there is none.
pub fn store_session(db : @sql.Db, key : String) -> Json? raise {
  match db.all("SELECT * FROM sessions WHERE key = ?", [js(key)]) {
    [r, ..] => Some(row_json(r))
    _ => None
  }
}

///|
/// store.ts `getThread`'s row.
pub fn store_thread(db : @sql.Db, id : Double) -> Json? raise {
  match db.all("SELECT * FROM threads WHERE id = ?", [jn(id)]) {
    [r, ..] => Some(row_json(r))
    _ => None
  }
}

///|
/// store.ts `threadSessions`' rows: a thread's members as they joined.
pub fn store_thread_sessions(db : @sql.Db, thread : Double) -> Array[Json] raise {
  db.all("SELECT * FROM thread_sessions WHERE thread = ? ORDER BY joined_at, rowid", [jn(thread)]).map(row_json)
}

///|
/// store.ts `threadsWithCards`: of `threads`, those that ever had a card or options posted.
pub fn threads_with_cards(db : @sql.Db, threads : Array[Double]) -> Array[Double] raise {
  threads.filter(fn(t) raise {
    db.all("SELECT 1 FROM entries INDEXED BY entries_cards WHERE thread = ? AND card IS NOT NULL LIMIT 1", [jn(t)]).length() > 0 ||
    db.all("SELECT 1 FROM entries INDEXED BY entries_options WHERE thread = ? AND options IS NOT NULL LIMIT 1", [jn(t)]).length() > 0
  })
}
