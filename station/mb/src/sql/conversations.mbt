// Conversations: grouping multi-session platform threads (e.g. multiple bots mentioned in the same Slack thread)
// into a single conversation identified by an anchor session key (`sessions.conv`).
// Mirrors station/src/store/conversations.ts (§3.1, §3.2).

///|
pub let owned_ws_sql : String = "(ws IS NULL OR (ws NOT LIKE 'handed:%' AND ws NOT LIKE 'coming:%'))"

///|
pub fn is_owned_ws(ws : Json) -> Bool {
  match ws {
    String(w) => !w.has_prefix("handed:") && !w.has_prefix("coming:")
    _ => true
  }
}

///|
/// The anchor session key for `key`'s conversation (`conv ?? key`).
pub fn conversation_of(db : Db, key : String) -> String raise {
  match db.first("SELECT conv FROM sessions WHERE key = ?", [Json::string(key)]) {
    Some(r) =>
      match row_val(r, "conv") {
        String(c) if c != "" => c
        _ => key
      }
    None => key
  }
}

///|
/// All owned sessions belonging to conversation `anchor` (`conv = anchor OR key = anchor`).
pub fn members_of(db : Db, anchor : String, limit? : Int) -> Array[String] raise {
  let sql = match limit {
    Some(_) =>
      "SELECT key FROM sessions WHERE conv = ?1 AND \{owned_ws_sql} UNION SELECT key FROM sessions WHERE key = ?1 AND \{owned_ws_sql} LIMIT ?2"
    None =>
      "SELECT key FROM sessions WHERE conv = ?1 AND \{owned_ws_sql} UNION SELECT key FROM sessions WHERE key = ?1 AND \{owned_ws_sql}"
  }
  let args : Array[Json] = match limit {
    Some(n) => [Json::string(anchor), Json::number(n.to_double())]
    None => [Json::string(anchor)]
  }
  let out : Array[String] = []
  for r in db.all(sql, args) {
    if row_val(r, "key") is String(k) {
      out.push(k)
    }
  }
  out
}

///|
priv struct ConvMember {
  key : String
  mut conv : String?
  created_at : Double
  mut archived_at : Double?
  mut archived_by : String?
}

///|
priv struct ConvHome {
  id : Json
  mut hidden_at : Double?
  mut hidden_by : String?
}

///|
priv struct ConvGroup {
  anchor : String
  mut members : Array[ConvMember]
  home : ConvHome?
  has_share : Bool
  is_born : Bool
  is_manual : Bool
  earliest_at : Double
  earliest_key : String
}

///|
fn conv_num(v : Json) -> Double? {
  match v {
    Number(n, ..) => Some(n)
    _ => None
  }
}

///|
fn conv_str(v : Json) -> String? {
  match v {
    String(s) => Some(s)
    _ => None
  }
}

///|
fn conv_cmp_earliest(a_at : Double, a_key : String, b_at : Double, b_key : String) -> Int {
  if a_at != b_at {
    if a_at < b_at { -1 } else { 1 }
  } else if a_key < b_key {
    -1
  } else if a_key > b_key {
    1
  } else {
    0
  }
}

///|
fn conv_load_group_members(db : Db, anchor : String) -> Array[ConvMember] raise {
  let rows = db.all(
    "SELECT key, conv, created_at, archived_at, archived_by FROM sessions WHERE conv = ?1 AND \{owned_ws_sql} UNION SELECT key, conv, created_at, archived_at, archived_by FROM sessions WHERE key = ?1 AND \{owned_ws_sql}",
    [Json::string(anchor)],
  )
  let out : Array[ConvMember] = []
  for r in rows {
    if row_val(r, "key") is String(k) {
      out.push({
        key: k,
        conv: conv_str(row_val(r, "conv")).bind(c => if c == "" { None } else { Some(c) }),
        created_at: conv_num(row_val(r, "created_at")).unwrap_or(0.0),
        archived_at: conv_num(row_val(r, "archived_at")),
        archived_by: conv_str(row_val(r, "archived_by")),
      })
    }
  }
  out
}

///|
let conv_member_join_sql : String = "INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?1, ?2, ?3, ?4) ON CONFLICT (thread, session) DO UPDATE SET left_at = NULL WHERE thread_sessions.left_at IS NOT NULL"

///|
fn conv_push_unique_str(arr : Array[String], s : String) -> Unit {
  if !arr.contains(s) {
    arr.push(s)
  }
}

///|
fn conv_push_unique_json(arr : Array[Json], v : Json) -> Unit {
  if !arr.contains(v) {
    arr.push(v)
  }
}

///|
/// Idempotent grouping entry point (`settle(thread)` in §3.2). Must be called inside a write transaction.
/// Returns `(touched_sessions, touched_threads)`.
pub fn settle_conversation_in_tx(
  db : Db,
  thread_id : Json,
  now : Json,
  born? : String? = None,
) -> (Array[String], Array[Json]) raise {
  let thread = match db.first("SELECT id, surface, channel, thread_ts FROM threads WHERE id = ?", [thread_id]) {
    Some(r) => r
    None => return ([], [])
  }
  let channel = conv_str(row_val(thread, "channel")).unwrap_or("")
  let thread_ts = conv_str(row_val(thread, "thread_ts")).unwrap_or("")
  let suffix = ":\{channel}:\{thread_ts}"
  let raw = db.all(
    "SELECT s.key, s.conv, s.scope, s.created_at, s.archived_at, s.archived_by, s.ws, ts.left_at FROM thread_sessions ts JOIN sessions s ON s.key = ts.session WHERE ts.thread = ?",
    [thread_id],
  )
  let left_by_key : Map[String, Bool] = Map([])
  let anchors : Array[String] = []
  let mut birth_count = 0
  let mut sole_key = ""
  let mut sole_conv_null = false
  for r in raw {
    if conv_str(row_val(r, "scope")) != Some("thread") {
      continue
    }
    if !is_owned_ws(row_val(r, "ws")) {
      continue
    }
    let key = match conv_str(row_val(r, "key")) {
      Some(k) if k.has_suffix(suffix) => k
      _ => continue
    }
    birth_count += 1
    sole_key = key
    sole_conv_null = row_val(r, "conv") is Null
    let is_left = !(row_val(r, "left_at") is Null)
    left_by_key[key] = is_left
    let anchor = match conv_str(row_val(r, "conv")) {
      Some(c) if c != "" => c
      _ => key
    }
    conv_push_unique_str(anchors, anchor)
  }
  if birth_count < 2 {
    if birth_count == 1 && sole_conv_null {
      ignore(db.run("UPDATE sessions SET conv = key WHERE key = ? AND conv IS NULL", [Json::string(sole_key)]))
    }
    return ([], [])
  }

  let groups : Array[ConvGroup] = []
  for anchor in anchors {
    let members = conv_load_group_members(db, anchor)
    if members.is_empty() {
      continue
    }
    let mut earliest_at = members[0].created_at
    let mut earliest_key = members[0].key
    let mut has_share = false
    let mut is_manual = false
    for m in members {
      if conv_cmp_earliest(m.created_at, m.key, earliest_at, earliest_key) < 0 {
        earliest_at = m.created_at
        earliest_key = m.key
      }
      if !has_share && db.first("SELECT 1 FROM chat_shares WHERE session = ? LIMIT 1", [Json::string(m.key)]) is Some(_) {
        has_share = true
      }
      if m.archived_at is Some(_) && m.archived_by == Some("manual") {
        is_manual = true
      }
    }
    let home = match db.first("SELECT id, hidden_at, hidden_by FROM threads WHERE home = ? ORDER BY id LIMIT 1", [Json::string(anchor)]) {
      Some(h) =>
        Some({
          id: row_val(h, "id"),
          hidden_at: conv_num(row_val(h, "hidden_at")),
          hidden_by: conv_str(row_val(h, "hidden_by")),
        })
      None => None
    }
    let is_born = match born {
      Some(b) => members.length() == 1 && members[0].key == b && !has_share
      None => false
    }
    groups.push({ anchor, members, home, has_share, is_born, is_manual, earliest_at, earliest_key })
  }

  let touched_sessions : Array[String] = []
  let touched_threads : Array[Json] = []
  let final_groups : Array[ConvGroup] = []

  for manual_bucket in [true, false] {
    let bucket = groups.filter(g => g.is_manual == manual_bucket)
    if bucket.length() < 2 {
      for g in bucket {
        final_groups.push(g)
      }
      continue
    }
    let home_groups = bucket.filter(g => g.home is Some(_))
    let target = if home_groups.length() == 1 {
      home_groups[0]
    } else {
      let mut best = bucket[0]
      for i = 1; i < bucket.length(); i = i + 1 {
        let g = bucket[i]
        if conv_cmp_earliest(g.earliest_at, g.earliest_key, best.earliest_at, best.earliest_key) < 0 {
          best = g
        }
      }
      best
    }

    let accepted : Array[ConvGroup] = []
    let kept : Array[ConvGroup] = []
    for g in bucket {
      if g.anchor == target.anchor {
        continue
      }
      if g.home is Some(_) {
        kept.push(g)
        continue
      }
      if (target.has_share || g.has_share) && !g.is_born {
        kept.push(g)
        continue
      }
      accepted.push(g)
    }

    if accepted.length() > 0 {
      let merged : Array[ConvMember] = target.members.copy()
      for g in accepted {
        for m in g.members {
          if !merged.iter().any(x => x.key == m.key) {
            merged.push(m)
          }
        }
      }
      let anchor = target.anchor
      for m in merged {
        if m.conv != Some(anchor) {
          ignore(db.run("UPDATE sessions SET conv = ? WHERE key = ?", [Json::string(anchor), Json::string(m.key)]))
          m.conv = Some(anchor)
          conv_push_unique_str(touched_sessions, m.key)
        }
      }
      if manual_bucket {
        let mut max_at = 0.0
        for m in merged {
          if m.archived_at is Some(a) && a > max_at {
            max_at = a
          }
        }
        for m in merged {
          if m.archived_at != Some(max_at) || m.archived_by != Some("manual") {
            ignore(db.run("UPDATE sessions SET archived_at = ?, archived_by = ? WHERE key = ?", [Json::number(max_at), Json::string("manual"), Json::string(m.key)]))
            m.archived_at = Some(max_at)
            m.archived_by = Some("manual")
            conv_push_unique_str(touched_sessions, m.key)
          }
        }
        if target.home is Some(h) && (h.hidden_at != Some(max_at) || h.hidden_by != Some("manual")) {
          ignore(db.run("UPDATE threads SET hidden_at = ?, hidden_by = ? WHERE id = ?", [Json::number(max_at), Json::string("manual"), h.id]))
          h.hidden_at = Some(max_at)
          h.hidden_by = Some("manual")
          conv_push_unique_json(touched_threads, h.id)
        }
      } else {
        let any_live = merged.iter().any(m => m.archived_at is None)
        if any_live {
          for m in merged {
            if m.archived_at is Some(_) || m.archived_by is Some(_) {
              ignore(db.run("UPDATE sessions SET archived_at = NULL, archived_by = NULL WHERE key = ?", [Json::string(m.key)]))
              m.archived_at = None
              m.archived_by = None
              conv_push_unique_str(touched_sessions, m.key)
            }
          }
          if target.home is Some(h) && (h.hidden_at is Some(_) || h.hidden_by is Some(_)) {
            ignore(db.run("UPDATE threads SET hidden_at = NULL, hidden_by = NULL WHERE id = ?", [h.id]))
            h.hidden_at = None
            h.hidden_by = None
            conv_push_unique_json(touched_threads, h.id)
          }
        } else {
          let mut max_at = 0.0
          for m in merged {
            if m.archived_at is Some(a) && a > max_at {
              max_at = a
            }
          }
          for m in merged {
            if m.archived_at != Some(max_at) || m.archived_by != Some("auto") {
              ignore(db.run("UPDATE sessions SET archived_at = ?, archived_by = ? WHERE key = ?", [Json::number(max_at), Json::string("auto"), Json::string(m.key)]))
              m.archived_at = Some(max_at)
              m.archived_by = Some("auto")
              conv_push_unique_str(touched_sessions, m.key)
            }
          }
          if target.home is Some(h) && (h.hidden_at != Some(max_at) || h.hidden_by != Some("auto")) {
            ignore(db.run("UPDATE threads SET hidden_at = ?, hidden_by = ? WHERE id = ?", [Json::number(max_at), Json::string("auto"), h.id]))
            h.hidden_at = Some(max_at)
            h.hidden_by = Some("auto")
            conv_push_unique_json(touched_threads, h.id)
          }
        }
      }
      target.members = merged
    }

    final_groups.push(target)
    for g in kept {
      final_groups.push(g)
    }
  }

  for g in final_groups {
    guard g.home is Some(h) else { continue }
    if g.members.length() < 2 && !g.members.iter().any(m => m.conv is Some(_)) {
      continue
    }
    for m in g.members {
      if left_by_key.get(m.key) != Some(false) {
        continue
      }
      if db.run(conv_member_join_sql, [h.id, Json::string(m.key), Json::string("chat"), now]) > 0 {
        conv_push_unique_str(touched_sessions, m.key)
        conv_push_unique_json(touched_threads, h.id)
      }
    }
  }

  if touched_sessions.length() > 0 || touched_threads.length() > 0 {
    conv_push_unique_json(touched_threads, thread_id)
  }
  (touched_sessions, touched_threads)
}

///|
/// Startup repair (§3.2): scan only truly grouped sessions (`conv IS NOT NULL AND conv != key`)
/// via `sessions_conv_grouped`.
pub fn repair_conversations(db : Db) -> Unit raise {
  let rows = db.all(
    "SELECT key, conv, created_at, archived_at, archived_by, ws FROM sessions INDEXED BY sessions_conv_grouped WHERE conv IS NOT NULL AND conv != key",
    [],
  )
  let by_conv : Map[String, Array[ConvMember]] = Map([])
  for r in rows {
    if !is_owned_ws(row_val(r, "ws")) {
      continue
    }
    guard conv_str(row_val(r, "key")) is Some(key) else { continue }
    guard conv_str(row_val(r, "conv")) is Some(c) && c != "" else { continue }
    let m : ConvMember = {
      key,
      conv: Some(c),
      created_at: conv_num(row_val(r, "created_at")).unwrap_or(0.0),
      archived_at: conv_num(row_val(r, "archived_at")),
      archived_by: conv_str(row_val(r, "archived_by")),
    }
    match by_conv.get(c) {
      Some(list) => list.push(m)
      None => by_conv[c] = [m]
    }
  }
  if by_conv.is_empty() {
    return
  }

  let dirty : Array[String] = []
  for anchor, list in by_conv {
    if !list.iter().any(m => m.key == anchor) {
      if db.first(
        "SELECT key, conv, created_at, archived_at, archived_by FROM sessions WHERE key = ? AND \{owned_ws_sql}",
        [Json::string(anchor)],
      ) is Some(a) {
        list.push({
          key: anchor,
          conv: conv_str(row_val(a, "conv")).bind(c => if c == "" { None } else { Some(c) }),
          created_at: conv_num(row_val(a, "created_at")).unwrap_or(0.0),
          archived_at: conv_num(row_val(a, "archived_at")),
          archived_by: conv_str(row_val(a, "archived_by")),
        })
      }
    }
    let home = db.first("SELECT id, hidden_at, hidden_by FROM threads WHERE home = ? ORDER BY id LIMIT 1", [Json::string(anchor)])
    let first = list[0]
    let members_match = list.iter().all(m => m.archived_at == first.archived_at && m.archived_by == first.archived_by)
    let home_match = match home {
      None => true
      Some(h) => conv_num(row_val(h, "hidden_at")) == first.archived_at && conv_str(row_val(h, "hidden_by")) == first.archived_by
    }
    let conv_ok = list.iter().all(m => m.conv == Some(anchor))
    if !members_match || !home_match || !conv_ok {
      dirty.push(anchor)
    }
  }
  if dirty.is_empty() {
    return
  }

  db.write(() => {
    for anchor in dirty {
      let members = conv_load_group_members(db, anchor)
      if members.is_empty() {
        continue
      }
      let live = members.filter(m => m.archived_at is None)
      let auto = members.filter(m => m.archived_at is Some(_) && m.archived_by != Some("manual"))
      let manual = members.filter(m => m.archived_at is Some(_) && m.archived_by == Some("manual"))

      let reanchor = (remaining : Array[ConvMember]) => {
        if remaining.is_empty() {
          return anchor
        }
        if remaining.iter().any(m => m.key == anchor) {
          for m in remaining {
            if m.conv != Some(anchor) {
              ignore(db.run("UPDATE sessions SET conv = ? WHERE key = ?", [Json::string(anchor), Json::string(m.key)]))
            }
          }
          return anchor
        }
        let mut best = remaining[0]
        for i = 1; i < remaining.length(); i = i + 1 {
          let m = remaining[i]
          if conv_cmp_earliest(m.created_at, m.key, best.created_at, best.key) < 0 {
            best = m
          }
        }
        let next_anchor = best.key
        for m in remaining {
          ignore(db.run("UPDATE sessions SET conv = ? WHERE key = ?", [Json::string(next_anchor), Json::string(m.key)]))
        }
        ignore(db.run("UPDATE threads SET home = ? WHERE home = ?", [Json::string(next_anchor), Json::string(anchor)]))
        next_anchor
      }

      if live.length() > 0 {
        for m in auto {
          ignore(db.run("UPDATE sessions SET archived_at = NULL, archived_by = NULL WHERE key = ?", [Json::string(m.key)]))
        }
        for m in manual {
          ignore(db.run("UPDATE sessions SET conv = NULL WHERE key = ?", [Json::string(m.key)]))
        }
        let remaining = live + auto
        let eff = reanchor(remaining)
        ignore(db.run("UPDATE threads SET hidden_at = NULL, hidden_by = NULL WHERE home = ?", [Json::string(eff)]))
      } else if auto.length() > 0 && manual.length() > 0 {
        for m in manual {
          ignore(db.run("UPDATE sessions SET conv = NULL WHERE key = ?", [Json::string(m.key)]))
        }
        let eff = reanchor(auto)
        let mut max_at = 0.0
        for m in auto {
          if m.archived_at is Some(a) && a > max_at {
            max_at = a
          }
        }
        for m in auto {
          ignore(db.run("UPDATE sessions SET archived_at = ?, archived_by = ? WHERE key = ?", [Json::number(max_at), Json::string("auto"), Json::string(m.key)]))
        }
        ignore(db.run("UPDATE threads SET hidden_at = ?, hidden_by = ? WHERE home = ?", [Json::number(max_at), Json::string("auto"), Json::string(eff)]))
      } else if auto.length() > 0 {
        let mut max_at = 0.0
        for m in auto {
          if m.archived_at is Some(a) && a > max_at {
            max_at = a
          }
        }
        let eff = reanchor(auto)
        for m in auto {
          ignore(db.run("UPDATE sessions SET archived_at = ?, archived_by = ? WHERE key = ?", [Json::number(max_at), Json::string("auto"), Json::string(m.key)]))
        }
        ignore(db.run("UPDATE threads SET hidden_at = ?, hidden_by = ? WHERE home = ?", [Json::number(max_at), Json::string("auto"), Json::string(eff)]))
      } else if manual.length() > 0 {
        let mut max_at = 0.0
        for m in manual {
          if m.archived_at is Some(a) && a > max_at {
            max_at = a
          }
        }
        let eff = reanchor(manual)
        for m in manual {
          ignore(db.run("UPDATE sessions SET archived_at = ?, archived_by = ? WHERE key = ?", [Json::number(max_at), Json::string("manual"), Json::string(m.key)]))
        }
        ignore(db.run("UPDATE threads SET hidden_at = ?, hidden_by = ? WHERE home = ?", [Json::number(max_at), Json::string("manual"), Json::string(eff)]))
      }
    }
  })
}

///|
/// When `deleteSession` deletes an anchor, move remaining members' `conv` and `threads.home` to the earliest
/// `(created_at, key)` remaining member. Must run inside `deleteSession`'s transaction.
pub fn reanchor_on_delete_in_tx(db : Db, deleted_key : String) -> (Array[String], Array[Json]) raise {
  let rest = db.all(
    "SELECT key, created_at FROM sessions WHERE conv = ?1 AND key != ?1 AND \{owned_ws_sql} ORDER BY created_at, key",
    [Json::string(deleted_key)],
  )
  if rest.is_empty() {
    return ([], [])
  }
  let new_anchor = match conv_str(row_val(rest[0], "key")) {
    Some(k) => k
    None => return ([], [])
  }
  ignore(db.run("UPDATE sessions SET conv = ?1 WHERE conv = ?2 AND key != ?2 AND \{owned_ws_sql}", [Json::string(new_anchor), Json::string(deleted_key)]))
  let home_rows = db.all("SELECT id FROM threads WHERE home = ?", [Json::string(deleted_key)])
  if home_rows.length() > 0 {
    ignore(db.run("UPDATE threads SET home = ? WHERE home = ?", [Json::string(new_anchor), Json::string(deleted_key)]))
  }
  let sessions : Array[String] = []
  for r in rest {
    if conv_str(row_val(r, "key")) is Some(k) {
      sessions.push(k)
    }
  }
  let threads = home_rows.map(r => row_val(r, "id"))
  (sessions, threads)
}

///|
/// Extracts `(channel, thread_ts)` from a `scope = 'thread'` session key (`<connect>:<channel>:<thread_ts>`).
fn split_session_thread(key : String) -> (String, String)? {
  match key.rev_find(":") {
    Some(last) if last > 0 && last + 1 < key.length() => {
      let head = key.unsafe_substring(start=0, end=last)
      match head.rev_find(":") {
        Some(prev) if prev + 1 < last =>
          Some((head.unsafe_substring(start=prev + 1, end=last), key.unsafe_substring(start=last + 1, end=key.length())))
        _ => None
      }
    }
    _ => None
  }
}

///|
/// Birth thread id(s) of a `scope = 'thread'` session, looked up in O(1) via `threads_at (channel, thread_ts)`
/// and `thread_sessions (thread, session)` primary key (`LIMIT 8`).
pub fn birth_threads_of(db : Db, key : String) -> Array[Json] raise {
  match db.first("SELECT scope, ws FROM sessions WHERE key = ?", [Json::string(key)]) {
    Some(s) if conv_str(row_val(s, "scope")) == Some("thread") && is_owned_ws(row_val(s, "ws")) => ()
    _ => return []
  }
  guard split_session_thread(key) is Some((ch, ts)) else { return [] }
  let rows = db.all(
    "SELECT t.id FROM threads t INDEXED BY threads_at JOIN thread_sessions ts ON ts.thread = t.id AND ts.session = ?1 WHERE t.channel = ?2 AND t.thread_ts = ?3 LIMIT 8",
    [Json::string(key), Json::string(ch), Json::string(ts)],
  )
  rows.map(r => row_val(r, "id"))
}

///|
/// Members of conversation `anchor` that have not left their birth thread (`left_at IS NULL`);
/// if all have left, falls back to `[fallback_session]` (§3.3).
/// Each member's birth thread is checked in O(1) via `threads_at` + `thread_sessions` PK (`LIMIT 8`).
pub fn active_conversation_members(db : Db, anchor : String, fallback_session : String) -> Array[String] raise {
  let members = members_of(db, anchor)
  let active : Array[String] = []
  for m in members {
    let is_thread = match db.first("SELECT scope FROM sessions WHERE key = ?", [Json::string(m)]) {
      Some(s) => conv_str(row_val(s, "scope")) == Some("thread")
      None => false
    }
    if is_thread {
      if split_session_thread(m) is Some((ch, ts)) {
        let rows = db.all(
          "SELECT ts.left_at FROM threads t INDEXED BY threads_at JOIN thread_sessions ts ON ts.thread = t.id AND ts.session = ?1 WHERE t.channel = ?2 AND t.thread_ts = ?3 LIMIT 8",
          [Json::string(m), Json::string(ch), Json::string(ts)],
        )
        if rows.length() > 0 && rows.iter().all(r => !(row_val(r, "left_at") is Null)) {
          continue
        }
      }
    }
    active.push(m)
  }
  if active.is_empty() { [fallback_session] } else { active }
}

///|
/// One bounded batch of background conversation backfill (`--builder session-backfill`, `conversation-backfill`).
/// Uses `sessions_conv_todo` partial index and converges by writing `conv = key` on lone/orphaned rows.
/// Returns true when no more rows remain.
pub fn backfill_conversations_step(db : Db, now : Json, limit? : Int = 32) -> Bool raise {
  let rows = db.all(
    "SELECT key FROM sessions INDEXED BY sessions_conv_todo WHERE scope = 'thread' AND conv IS NULL AND \{owned_ws_sql} ORDER BY key LIMIT ?",
    [Json::number(limit.to_double())],
  )
  if rows.is_empty() {
    return true
  }
  let settled : Array[Json] = []
  db.write(() => {
    for r in rows {
      guard conv_str(row_val(r, "key")) is Some(key) else { continue }
      for tid in birth_threads_of(db, key) {
        if !settled.contains(tid) {
          settled.push(tid)
          ignore(settle_conversation_in_tx(db, tid, now))
        }
      }
      ignore(db.run("UPDATE sessions SET conv = key WHERE key = ? AND conv IS NULL", [Json::string(key)]))
    }
  })
  rows.length() < limit
}
