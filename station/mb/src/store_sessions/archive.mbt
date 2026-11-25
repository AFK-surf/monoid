// A session and its chats put out of lists and back (`setArchived`, `setThreadHidden`), named (`setThreadTitle`,
// `setAutoTitle`), what is asked of a chat's posts around them, and a session forgotten whole (`deleteSession`).

///|
/// store.ts LEADERS_RETURNING.
let leaders_returning : String = "RETURNING (SELECT json_group_array(parent) FROM opened_chats WHERE child_station = '' AND child = sessions.key AND parent_station = '' AND led = 1) AS leaders"

///|
/// The threads a session takes part in, the latest joined first (store.ts `sessionThreads`).
fn Store::session_threads(self : Store, session : Json) -> Array[Json] raise {
  self
  .all(
    "SELECT t.*, ts.connect FROM thread_sessions ts JOIN threads t ON t.id = ts.thread WHERE ts.session = ? ORDER BY ts.joined_at DESC, ts.rowid DESC LIMIT ?",
    [session, jnum(-1.0)],
  )
  .map(to_session_thread)
}

///|
fn thread_id_of(t : Json) -> Json {
  match field(t, "thread") {
    Some(th) => nullish(field(th, "id"))
    None => Json::null()
  }
}

///|
/// store.ts `lastEntry`.
fn Store::last_entry(self : Store, thread : Json) -> Json raise {
  match self.one("SELECT MAX(n) AS n FROM entries WHERE thread = ?", [thread]) {
    Some(r) => or_else(col(r, "n"), jnum(0.0))
    None => jnum(0.0)
  }
}

///|
/// store.ts `#setArchived`.
fn Store::set_archived_in(
  self : Store,
  key : String,
  archived : Bool,
  by : String,
  changes : Array[Json],
) -> Unit raise {
  let now = self.now_json()
  let settled_sessions : Array[String] = []
  let settled_threads : Array[Json] = []
  let mut targets : Array[String] = [key]
  let leaders = self.tx(() => {
    let anchor = @sql.conversation_of(self.db, key)
    let members = @sql.members_of(self.db, anchor)
    targets = if members.is_empty() { [key] } else { members }
    if !targets.contains(key) {
      targets.push(key)
    }
    let all_leaders : Array[Json] = []
    for m in targets {
      let row = if archived {
        self.one(
          "UPDATE sessions SET archived_at = ?, archived_by = ? WHERE key = ? \{leaders_returning}",
          [now, jstr(by), jstr(m)],
        )
      } else {
        self.one(
          "UPDATE sessions SET archived_at = NULL, archived_by = NULL, shown_at = COALESCE(?, shown_at) WHERE key = ? \{leaders_returning}",
          [if by == manual { now } else { Json::null() }, jstr(m)],
        )
      }
      let ls = match row {
        None => []
        Some(r) =>
          arr(js_parse(js_string(or_else(col(r, "leaders"), jstr("[]")))))
      }
      for p in ls {
        if !all_leaders.contains(p) {
          all_leaders.push(p)
        }
      }
    }
    ignore(
      self.run(
        "UPDATE threads SET hidden_at = ?, hidden_by = ? WHERE home = ?",
        [
          if archived {
            now
          } else {
            Json::null()
          },
          if archived {
            jstr(by)
          } else {
            Json::null()
          },
          jstr(anchor),
        ],
      ),
    )
    if !archived && by == manual {
      let birth_ids : Array[Json] = []
      for m in targets {
        for tid in @sql.birth_threads_of(self.db, m) {
          if !birth_ids.contains(tid) {
            birth_ids.push(tid)
          }
        }
      }
      for tid in birth_ids {
        let (ss, ts) = @sql.settle_conversation_in_tx(self.db, tid, now)
        for s in ss {
          if !settled_sessions.contains(s) {
            settled_sessions.push(s)
          }
        }
        for t in ts {
          if !settled_threads.contains(t) {
            settled_threads.push(t)
          }
        }
      }
    }
    all_leaders
  })
  let touched_threads : Array[Json] = settled_threads.copy()
  for m in targets {
    for t in self.session_threads(jstr(m)) {
      let id = thread_id_of(t)
      if !touched_threads.contains(id) {
        touched_threads.push(id)
      }
    }
  }
  for id in touched_threads {
    changes.push(thread_change(id))
  }
  let touched_sessions : Array[String] = targets.copy()
  for s in settled_sessions {
    if !touched_sessions.contains(s) {
      touched_sessions.push(s)
    }
  }
  for s in touched_sessions {
    changes.push(session_change(jstr(s)))
  }
  for parent in leaders {
    changes.push(session_change(parent))
  }
}

///|
/// Hides a session from lists, or shows it again, with its own chat; `by` is "manual" or "auto".
pub fn Store::set_archived(
  self : Store,
  key : String,
  archived : Bool,
  by : String,
) -> Unit raise {
  self.with_changes(changes => self.set_archived_in(key, archived, by, changes))
}

///|
/// store.ts `#outOfLists`.
fn Store::out_of_lists(self : Store, thread : Json) -> Bool raise {
  match self.one("SELECT hidden_at FROM threads WHERE id = ?", [thread]) {
    None => false
    Some(r) => {
      if !(col(r, "hidden_at") is Null) {
        return true
      }
      let shown = self.one(
          "SELECT 1 FROM thread_sessions ts JOIN sessions s ON s.key = ts.session WHERE ts.thread = ? AND s.archived_at IS NULL LIMIT 1",
          [thread],
        )
        is Some(_)
      !shown
    }
  }
}

///|
/// Out of lists by hand: the chat archived itself, or its sessions archived with one of them by hand.
pub fn Store::manually_archived(self : Store, thread : Json) -> Bool raise {
  let r = self.one("SELECT hidden_by FROM threads WHERE id = ?", [thread])
  guard r is Some(r) else { return false }
  if !self.out_of_lists(thread) {
    return false
  }
  if col(r, "hidden_by") == jstr(manual) {
    return true
  }
  self.one(
    "SELECT 1 FROM thread_sessions ts JOIN sessions s ON s.key = ts.session WHERE ts.thread = ? AND s.archived_by = ? LIMIT 1",
    [thread, jstr(manual)],
  )
  is Some(_)
}

///|
/// store.ts `#setThreadHidden`.
fn Store::set_thread_hidden_in(
  self : Store,
  thread : Json,
  hidden : Bool,
  by : String,
  changes : Array[Json],
) -> Unit raise {
  let now = self.now_json()
  if hidden {
    ignore(
      self.run("UPDATE threads SET hidden_at = ?, hidden_by = ? WHERE id = ?", [
        now,
        jstr(by),
        thread,
      ]),
    )
  } else {
    let shown = if by == manual { now } else { Json::null() }
    ignore(
      self.run(
        "UPDATE threads SET hidden_at = NULL, hidden_by = NULL, shown_at = COALESCE(?, shown_at) WHERE id = ?",
        [shown, thread],
      ),
    )
  }
  changes.push(thread_change(thread))
}

///|
pub fn Store::set_thread_hidden(
  self : Store,
  thread : Json,
  hidden : Bool,
  by : String,
) -> Unit raise {
  self.with_changes(changes => {
    self.set_thread_hidden_in(thread, hidden, by, changes)
  })
}

///|
fn thread_key(thread : Json) -> Int64 {
  match thread {
    Number(n, ..) => n.to_int64()
    _ => 0L
  }
}

///|
pub fn Store::set_thread_title(
  self : Store,
  thread : Json,
  title : Json,
) -> Unit raise {
  self.with_changes(changes => {
    ignore(
      self.run("UPDATE threads SET title = ?1 WHERE id = ?2", [title, thread]),
    )
    self.title_revisions[thread_key(thread)] = self.title_revision(thread) + 1
    changes.push(thread_change(thread))
  })
}

///|
/// A chat named by hand by another program (the MoonBit program serving devices): as `setThreadTitle`.
pub fn Store::retitled(self : Store, thread : Json) -> Unit {
  self.title_revisions[thread_key(thread)] = self.title_revision(thread) + 1
}

///|
pub fn Store::title_revision(self : Store, thread : Json) -> Int32 {
  self.title_revisions.get(thread_key(thread)).unwrap_or(0)
}

///|
pub fn Store::set_generated_title(
  self : Store,
  thread : Json,
  title : Json,
) -> Unit raise {
  self.with_changes(changes => {
    let n = self.last_entry(thread)
    ignore(
      self.run(
        "UPDATE threads SET title = NULL, auto_title = ?1, auto_title_n = ?2, auto_title_changes = auto_title_changes + CASE WHEN auto_title IS NULL THEN 0 ELSE 1 END WHERE id = ?3",
        [title, n, thread],
      ),
    )
    changes.push(thread_change(thread))
  })
}

///|
pub fn Store::auto_title(self : Store, thread : Json) -> Json raise {
  match
    self.one(
      "SELECT auto_title, auto_title_n, auto_title_changes FROM threads WHERE id = ?",
      [thread],
    ) {
    Some(r) =>
      {
        "title": col(r, "auto_title"),
        "n": or_else(col(r, "auto_title_n"), jnum(0.0)),
        "changes": col(r, "auto_title_changes"),
      }
    None => { "title": Json::null(), "n": 0, "changes": 0 }
  }
}

///|
/// Stores validated external links (JSON object with `web`/`app`) on a thread; no-op when unchanged.
pub fn Store::set_thread_links(
  self : Store,
  thread : Json,
  links : Json,
) -> Unit raise {
  let raw = match links {
    Object(m) if !m.is_empty() => Json::string(links.stringify())
    _ => Json::null()
  }
  match self.one("SELECT links FROM threads WHERE id = ?", [thread]) {
    None => return
    Some(r) => if col(r, "links") == raw { return }
  }
  self.with_changes(changes => {
    ignore(
      self.run("UPDATE threads SET links = ?1 WHERE id = ?2", [raw, thread]),
    )
    changes.push(thread_change(thread))
  })
}

///|
pub fn Store::set_auto_title(
  self : Store,
  thread : Json,
  title : Json,
  changed : Bool,
) -> Unit raise {
  self.with_changes(changes => {
    let n = self.last_entry(thread)
    ignore(
      self.run(
        "UPDATE threads SET auto_title = ?1, auto_title_n = ?2, auto_title_changes = auto_title_changes + ?3 WHERE id = ?4",
        [title, n, flag(changed), thread],
      ),
    )
    changes.push(thread_change(thread))
  })
}

///|
pub fn Store::people_said_after(
  self : Store,
  thread : Json,
  n : Json,
  limit : Double,
) -> Json raise {
  let most = if limit.is_nan() {
    0.0
  } else if limit < 0.0 {
    0.0
  } else {
    limit.floor()
  }
  match self.one(people_said_after, [thread, n, jnum(most)]) {
    Some(r) => col(r, "c")
    None => Json::null()
  }
}

///|
/// post-blocks.ts POST_BLOCK_SIZE.
let post_block_size : Double = 64.0

///|
/// The posts' history is not ready for these positions (post-blocks.ts `PostBlocksUnavailable`).
fn post_blocks_unavailable(positions : Array[Json]) -> StoreError {
  StoreError("post block history not ready", {
    "positions": Json::array(positions),
  })
}

///|
/// The session's first post in a thread after entry `n` (`{n, ts}`), null for none.
pub fn Store::post_after(
  self : Store,
  session : String,
  thread : Json,
  n : Json,
) -> Json raise {
  let ready = match self.one(post_blocks_ready, [thread, n]) {
    Some(r) => is_n(col(r, "ready"), 1.0)
    None => false
  }
  if !ready {
    let first = self.one(post_after_first, [thread, n])
    guard first is Some(first) else { return Json::null() }
    if col(first, "kind") is String("message") &&
      col(first, "author_kind") is String("agent") &&
      col(first, "author") == jstr(session) {
      return { "n": col(first, "n"), "ts": col(first, "ts") }
    }
    raise post_blocks_unavailable([{ "thread": thread, "n": n }])
  }
  let at = num_of(n).unwrap_or(0.0)
  match
    self.one(post_after_indexed, [
      thread,
      jstr(session),
      jnum((at / post_block_size).floor()),
      n,
    ]) {
    Some(r) => { "n": col(r, "n"), "ts": col(r, "ts") }
    None => Json::null()
  }
}

///|
/// First later posts for a batch (`{thread, n}` each), in its order.
pub fn Store::posts_after(
  self : Store,
  session : String,
  messages : Array[Json],
) -> Json raise {
  let out = Array::make(messages.length(), Json::null())
  let missing : Array[Json] = []
  if messages.length() == 0 {
    return Json::array(out)
  }
  let num = (m : Json, k : String) => {
    num_of(nullish(field(m, k))).unwrap_or(0.0)
  }
  let ordered = Array::makei(messages.length(), i => i)
  ordered.sort_by((a, b) => {
    let (x, y) = (messages[a], messages[b])
    let c = num(x, "thread").compare(num(y, "thread"))
    if c != 0 {
      return c
    }
    let d = num(x, "n").compare(num(y, "n"))
    if d != 0 {
      d
    } else {
      a.compare(b)
    }
  })
  self.savepoint("posts_after", () => {
    let mut thread : Double? = None
    let mut next : Json = Json::null()
    let mut searched = false
    let mut skip = false
    for index in ordered {
      let m = messages[index]
      let t = num(m, "thread")
      if thread != Some(t) {
        thread = Some(t)
        searched = false
        skip = false
      }
      if skip {
        continue
      }
      let after_next = match next {
        Null => false
        nx => num(m, "n") >= num(nx, "n")
      }
      if !searched || after_next {
        let found = Some(
          self.post_after(
            session,
            nullish(field(m, "thread")),
            nullish(field(m, "n")),
          ),
        ) catch {
          StoreError("post block history not ready", _) => {
            missing.push({
              "thread": nullish(field(m, "thread")),
              "n": nullish(field(m, "n")),
            })
            skip = true
            None
          }
          e => raise e
        }
        guard found is Some(f) else { continue }
        next = f
        searched = true
      }
      if !(next is Null) {
        out[index] = nullish(field(next, "ts"))
      }
    }
  })
  if missing.length() != 0 {
    raise post_blocks_unavailable(missing)
  }
  Json::array(out)
}

///|
pub fn Store::last_read_at(self : Store, thread : Json) -> Json raise {
  match self.one(last_read_at, [thread]) {
    Some(r) => col(r, "at")
    None => Json::null()
  }
}

///|
pub fn Store::conversation_of(self : Store, key : String) -> String raise {
  @sql.conversation_of(self.db, key)
}

///|
pub fn Store::members_of(self : Store, anchor : String, limit? : Int) -> Array[String] raise {
  @sql.members_of(self.db, anchor, limit?)
}

///|
pub fn Store::settle_conversation(self : Store, thread : Json, born? : String? = None) -> Bool raise {
  self.with_changes(changes => {
    let (sessions, threads) = self.tx(() => @sql.settle_conversation_in_tx(self.db, thread, self.now_json(), born~))
    for s in sessions {
      changes.push(session_change(jstr(s)))
    }
    for id in threads {
      changes.push(thread_change(id))
    }
    sessions.length() > 0 || threads.length() > 0
  })
}

///|
pub fn Store::active_conversation_members(self : Store, anchor : String, fallback_session : String) -> Array[String] raise {
  @sql.active_conversation_members(self.db, anchor, fallback_session)
}

///|
pub fn Store::home_chat(self : Store, session : Json) -> Json raise {
  let anchor = match str_of(session) {
    Some(k) => jstr(@sql.conversation_of(self.db, k))
    None => session
  }
  match
    self.one("SELECT * FROM threads WHERE home = ? ORDER BY id LIMIT 1", [
      anchor,
    ]) {
    Some(r) => to_thread(r)
    None => Json::null()
  }
}

///|
pub fn Store::chats_of_their_own(self : Store) -> Array[Json] raise {
  self
  .all(
    "SELECT * FROM threads WHERE surface = ? AND home IS NULL AND hidden_at IS NULL",
    [jstr(stillfail_surface)],
  )
  .map(to_thread)
}

///|
/// store.ts `deleteViewerMarks`: how a table of viewers' marks is cleared of a thread's or a session's (by its
/// viewers, one at a time, on a large table; whole on a small one).
priv struct Marks {
  choice : String
  indexed : String
  small : String
}

///|
fn delete_viewer_marks(table : String, key : String) -> Marks {
  let choice = "WITH RECURSIVE few(viewer, count) AS (\n" +
    "    SELECT (SELECT viewer FROM \{table} ORDER BY viewer LIMIT 1), 1\n" +
    "    UNION ALL SELECT (SELECT viewer FROM \{table} WHERE viewer > v.viewer ORDER BY viewer LIMIT 1), v.count + 1\n" +
    "      FROM few v WHERE v.viewer IS NOT NULL AND v.count < 33\n" +
    "  ), more(viewer, count) AS (\n" +
    "    SELECT (SELECT viewer FROM \{table} ORDER BY viewer LIMIT 1), 1\n" +
    "    UNION ALL SELECT (SELECT viewer FROM \{table} WHERE viewer > v.viewer ORDER BY viewer LIMIT 1), v.count + 1\n" +
    "      FROM more v WHERE v.viewer IS NOT NULL AND v.count < 257\n" +
    "  ), bounds(span) AS (SELECT (SELECT MAX(rowid) FROM \{table}) - (SELECT MIN(rowid) FROM \{table}))\n" +
    "  SELECT CASE WHEN COALESCE((SELECT span FROM bounds), 0) < 512 THEN 0\n" +
    "    WHEN (SELECT span FROM bounds) >= 32768 THEN 1\n" +
    "    WHEN (SELECT COUNT(*) FROM few WHERE viewer IS NOT NULL) <= 32 THEN 1\n" +
    "    WHEN (SELECT span FROM bounds) < 16384 THEN 0\n" +
    "    WHEN (SELECT COUNT(*) FROM more WHERE viewer IS NOT NULL) <= 256 THEN 1 ELSE 0 END AS seek"
  let indexed = "WITH RECURSIVE viewers(viewer) AS MATERIALIZED (\n" +
    "    SELECT (SELECT viewer FROM \{table} ORDER BY viewer LIMIT 1)\n" +
    "    UNION ALL SELECT (SELECT viewer FROM \{table} WHERE viewer > v.viewer ORDER BY viewer LIMIT 1)\n" +
    "      FROM viewers v WHERE v.viewer IS NOT NULL\n" +
    "  ) DELETE FROM \{table} WHERE viewer IN (SELECT viewer FROM viewers WHERE viewer IS NOT NULL) AND \{key} = ?"
  { choice, indexed, small: "DELETE FROM \{table} WHERE \{key} = ?", }
}

///|
fn Store::delete_marks(self : Store, marks : Marks, key : Json) -> Unit raise {
  let seek = match self.one(marks.choice, []) {
    Some(r) => truthy(col(r, "seek"))
    None => false
  }
  ignore(self.run(if seek { marks.indexed } else { marks.small }, [key]))
}

///|
/// session-bindings-index.ts `sessionBindingsReady`.
fn Store::session_bindings_ready(self : Store) -> Bool raise {
  match
    self.one(
      "SELECT version, complete FROM session_binding_meta WHERE id = 1",
      [],
    ) {
    None => raise store_error("session binding index version marker is missing")
    Some(meta) => {
      if !is_n(col(meta, "version"), 1.0) {
        raise store_error(
          "session binding index version \{js_string(col(meta, "version"))} is incompatible with 1",
        )
      }
      is_n(col(meta, "complete"), 1.0)
    }
  }
}

///|
/// Forgets a session: its row, turns, deliveries, memberships and bindings, and the threads only it took part in,
/// with their entries and reads.
pub fn Store::delete_session(self : Store, key : String) -> Unit raise {
  self.with_changes(changes => {
    let session = self.one("SELECT ws FROM sessions WHERE key = ?", [jstr(key)])
    let ws = match session {
      Some(r) => col(r, "ws")
      None => Json::null()
    }
    let kept = []
    let removed = []
    let mut reanchored_sessions : Array[String] = []
    let mut reanchored_threads : Array[Json] = []
    let k = jstr(key)
    self.tx(() => {
      let (rs, rt) = @sql.reanchor_on_delete_in_tx(self.db, key)
      reanchored_sessions = rs
      reanchored_threads = rt
      let threads = self
        .all("SELECT thread FROM thread_sessions WHERE session = ?", [k])
        .map(r => col(r, "thread"))
      let run = (sql : String) => ignore(self.run(sql, [k]))
      run("DELETE FROM thread_sessions WHERE session = ?")
      run("DELETE FROM slack_stops WHERE session = ?")
      run("DELETE FROM session_first WHERE session = ?")
      run("DELETE FROM deliveries WHERE session = ?")
      run("DELETE FROM comma_router_once_targets WHERE session = ?")
      run("DELETE FROM letter_deliveries WHERE session = ?")
      run("DELETE FROM turns WHERE session_key = ?")
      run("DELETE FROM runtime_sessions WHERE session_key = ?")
      run(
        if self.session_bindings_ready() {
          session_bindings_delete
        } else {
          "DELETE FROM bindings WHERE session_key = ?"
        },
      )
      run(
        "DELETE FROM job_notices WHERE job_id IN (SELECT id FROM jobs WHERE session_key = ?)",
      )
      run("DELETE FROM jobs WHERE session_key = ?")
      run("DELETE FROM session_up_job_scopes WHERE session = ?")
      run("DELETE FROM widget_states WHERE session = ?")
      self.delete_marks(delete_viewer_marks("pins", "session"), k)
      run("DELETE FROM transcript_lengths WHERE session = ?")
      run("DELETE FROM session_usage WHERE session = ?")
      run("DELETE FROM pending_proposals WHERE author = ?")
      run("DELETE FROM sessions WHERE key = ?")
      self.ws_of.remove(key)
      let tokens = []
      for token, of in self.token_key {
        if of == key {
          tokens.push(token)
        }
      }
      for token in tokens {
        self.token_key.remove(token)
      }
      for thread in threads {
        if self.one("SELECT 1 FROM thread_sessions WHERE thread = ? LIMIT 1", [
            thread,
          ])
          is Some(_) {
          kept.push(thread)
          continue
        }
        removed.push(thread)
        let of = (sql : String) => ignore(self.run(sql, [thread]))
        of(
          "DELETE FROM comma_router_once_targets WHERE id IN (SELECT id FROM comma_router_once WHERE thread = ?)",
        )
        of("DELETE FROM comma_router_once WHERE thread = ?")
        of("DELETE FROM deliveries WHERE thread = ?")
        of("DELETE FROM entries WHERE thread = ?")
        of("DELETE FROM letter_deliveries WHERE thread = ?")
        of("DELETE FROM letters WHERE thread = ?")
        self.delete_marks(delete_viewer_marks("reads", "thread"), thread)
        self.delete_marks(delete_viewer_marks("dismissed", "thread"), thread)
        of("DELETE FROM closed_cards WHERE thread = ?")
        of("DELETE FROM entry_proposals WHERE thread = ?")
        of("DELETE FROM proposal_outcomes WHERE thread = ?")
        of("DELETE FROM open_proposals WHERE thread = ?")
        of("DELETE FROM pending_proposals WHERE thread = ?")
        of("DELETE FROM card_choices WHERE thread = ?")
        self.delete_marks(delete_viewer_marks("kept_chats", "thread"), thread)
        self.delete_marks(delete_viewer_marks("hidden_chats", "thread"), thread)
        self.delete_marks(delete_viewer_marks("muted_chats", "thread"), thread)
        of("DELETE FROM threads WHERE id = ?")
      }
    })
    if session is Some(_) {
      self.session_workspace_changed()
    }
    changes.push({ "type": "sessionRemoved", "key": k, "ws": ws })
    for id in removed {
      changes.push({ "type": "threadRemoved", "id": id, "ws": ws })
    }
    for id in kept {
      changes.push(thread_change(id))
    }
    for s in reanchored_sessions {
      changes.push(session_change(jstr(s)))
    }
    for id in reanchored_threads {
      changes.push(thread_change(id))
    }
  })
}
