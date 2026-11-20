// What the database keeps of chats and their messages as they are written, whichever station writes them: agents'
// posts by blocks (station/src/store/post-blocks.ts), the latest message not of the latest person (said-state.ts), a
// chat's last message's guard (archive-last.ts), widgets' sources (widget-sources.ts), copy destinations and a
// session's chat by its last message (cc-thread-index.ts, session-chat-index.ts), the thread a session heard from last
// (latest-thread-index.ts), card posts (card-post-index.ts), the card outcomes' queue (card-outbox.ts) and the usage
// page's chats (usage-chat-stats.ts). Each installed empty with its writers.

///|
let pb_post_block_size : String = "64"

///|
let pb_post_block_last : String = "63"

///|
fn pb_block(n : String) -> String {
(
  $|(\{n} / \{pb_post_block_size} - CASE WHEN \{n} < 0 AND \{n} % \{pb_post_block_size} != 0 THEN 1 ELSE 0 END)
)
}

///|
fn pb_is_post(row : String) -> String {
  "\{row}.kind = 'message' AND \{row}.author_kind = 'agent'"
}

///|
let pb_stage : String =
(
  $|
  $|  DELETE FROM post_blocks_replaced WHERE thread IS NOT NULL;
  $|  INSERT INTO post_blocks_replaced (thread, author, bucket)
  $|    SELECT e.thread, e.author, \{pb_block("e.n")} FROM entries e
  $|      WHERE e.thread = NEW.thread AND e.n = NEW.n AND \{pb_is_post("e")}
  $|    UNION
  $|    SELECT e.thread, e.author, \{pb_block("e.n")} FROM entries e
  $|      WHERE NEW.ts IS NOT NULL AND e.thread = NEW.thread AND e.ts = NEW.ts AND \{pb_is_post("e")};
)

///|
fn pb_no_post(marker : String) -> String {
(
  $|NOT EXISTS (SELECT 1 FROM entries e WHERE e.thread = \{marker}.thread
  $|  AND e.n >= \{marker}.bucket * \{pb_post_block_size} AND e.n <= \{marker}.bucket * \{pb_post_block_size} + \{pb_post_block_last}
  $|  AND \{pb_is_post("e")} AND e.author = \{marker}.author)
)
}

///|
let pb_clean_replaced : String =
(
  $|
  $|  DELETE FROM post_blocks WHERE (thread, author, bucket) IN (SELECT thread, author, bucket FROM post_blocks_replaced)
  $|    AND \{pb_no_post("post_blocks")};
  $|  DELETE FROM post_blocks_replaced WHERE thread IS NOT NULL;
)

///|
let pb_clean_old : String =
(
  $|
  $|  DELETE FROM post_blocks WHERE thread = OLD.thread AND author = OLD.author AND bucket = \{pb_block("OLD.n")}
  $|    AND OLD.kind = 'message' AND OLD.author_kind = 'agent' AND \{pb_no_post("post_blocks")};
)

///|
let pb_add_new : String =
(
  $|
  $|  INSERT INTO post_blocks (thread, author, bucket)
  $|    SELECT NEW.thread, NEW.author, \{pb_block("NEW.n")}
  $|    WHERE NEW.kind = 'message' AND NEW.author_kind = 'agent'
  $|      AND NOT EXISTS (SELECT 1 FROM post_blocks b WHERE b.thread = NEW.thread AND b.author = NEW.author AND b.bucket = \{pb_block("NEW.n")});
)

///|
let pb_changed : String = "OLD.thread IS NOT NEW.thread OR OLD.n IS NOT NEW.n OR OLD.kind IS NOT NEW.kind OR OLD.author_kind IS NOT NEW.author_kind OR OLD.author IS NOT NEW.author OR OLD.ts IS NOT NEW.ts"

///|
/// Agents' posts by blocks: markers and their writers, no old message scanned (`installPostBlocks`).
fn install_post_blocks(db : @sql.Db) -> Unit raise {
  let installed = () => exists(db, "table", "post_blocks_meta")
  if installed() {
    return
  }
  immediate(db, () => if !installed() {
    db.exec(
(
  $|
  $|      CREATE TABLE post_blocks(thread INTEGER NOT NULL, author TEXT NOT NULL, bucket INTEGER NOT NULL,
  $|        PRIMARY KEY(thread,author,bucket)) WITHOUT ROWID;
  $|      CREATE TABLE post_blocks_replaced(thread INTEGER NOT NULL, author TEXT NOT NULL, bucket INTEGER NOT NULL,
  $|        PRIMARY KEY(thread,author,bucket)) WITHOUT ROWID;
  $|      CREATE TABLE post_blocks_meta(id INTEGER PRIMARY KEY CHECK (id = 1), fresh INTEGER NOT NULL) WITHOUT ROWID;
  $|      CREATE TABLE post_blocks_coverage(thread INTEGER PRIMARY KEY, cursor INTEGER, complete INTEGER NOT NULL) WITHOUT ROWID;
  $|      INSERT INTO post_blocks_meta SELECT 1, NOT EXISTS (SELECT 1 FROM entries LIMIT 1);
  $|      CREATE TRIGGER post_blocks_before_insert BEFORE INSERT ON entries BEGIN \{pb_stage} END;
  $|      CREATE TRIGGER post_blocks_after_insert AFTER INSERT ON entries BEGIN \{pb_clean_replaced} \{pb_add_new} END;
  $|      CREATE TRIGGER post_blocks_before_update BEFORE UPDATE OF thread,n,kind,author_kind,author,ts ON entries
  $|        WHEN \{pb_changed} BEGIN \{pb_stage} END;
  $|      CREATE TRIGGER post_blocks_after_update AFTER UPDATE OF thread,n,kind,author_kind,author,ts ON entries
  $|        WHEN \{pb_changed} BEGIN \{pb_clean_old} \{pb_clean_replaced} \{pb_add_new} END;
  $|      CREATE TRIGGER post_blocks_after_delete AFTER DELETE ON entries BEGIN \{pb_clean_old} END;
  $|    
)
    )
  })
}

///|
let ss_eligible : String = "NEW.kind = 'message' AND NEW.letter IS NULL"

///|
let ss_conflict : String =
(
  $|(EXISTS (SELECT 1 FROM entries e WHERE e.thread = NEW.thread AND e.n = NEW.n)
  $|  OR (NEW.ts IS NOT NULL AND EXISTS (SELECT 1 FROM entries e WHERE e.thread = NEW.thread AND e.ts = NEW.ts)))
)

///|
let ss_rowid_victim : String = "SELECT thread FROM entries WHERE rowid=NEW.rowid AND kind='message' AND letter IS NULL"

///|
/// The latest ordinary message a write can prove from its thread's tail (said-state.ts `legacyWriteHead`).
fn ss_legacy_write_head(except? : String) -> String {
  let where_ = match except {
    None => "thread=NEW.thread"
    Some(e) => "thread=NEW.thread AND n != \{e}"
  }
  let ordinary = "kind='message' AND letter IS NULL"
  let bounded =
(
  $|(SELECT scanned FROM legacy_said_meta WHERE id=1)=1 AND NOT EXISTS (
  $|    SELECT 1 FROM legacy_said_dirty WHERE \{where_} LIMIT 1 OFFSET 64)
)
  let staged = "(SELECT n FROM (" + legacy_said_latest(except?=except).replace_all(old="?1", new="NEW.thread") + "))"
(
  $|WITH said_write_first AS MATERIALIZED (
  $|    SELECT n,kind,letter FROM entries WHERE \{where_} ORDER BY n DESC LIMIT 1
  $|  ), said_write_probe AS MATERIALIZED (
  $|    SELECT n,kind,letter FROM entries WHERE \{where_} ORDER BY n DESC LIMIT 65
  $|  ) SELECT
  $|    CASE WHEN (SELECT n FROM said_write_first) IS NULL THEN NULL
  $|      WHEN (SELECT \{ordinary} FROM said_write_first) THEN (SELECT n FROM said_write_first)
  $|      WHEN \{bounded} THEN \{staged}
  $|      ELSE (SELECT n FROM said_write_probe WHERE \{ordinary} ORDER BY n DESC LIMIT 1) END AS n,
  $|    CASE WHEN (SELECT n FROM said_write_first) IS NULL THEN 1
  $|      WHEN (SELECT \{ordinary} FROM said_write_first) THEN 1
  $|      WHEN \{bounded} THEN 1
  $|      WHEN EXISTS (SELECT 1 FROM said_write_probe WHERE \{ordinary}) THEN 1
  $|      WHEN (SELECT COUNT(*) FROM said_write_probe)<65 THEN 1 ELSE 0 END AS known
)
}

///|
/// The writers of a thread's state that keep the said boundary (said-state.ts `stateWriters`): (addState, beforeInsert).
fn ss_state_writers(legacy : Bool) -> (String, String) {
  let source = if legacy { "legacy_said" } else { "entries INDEXED BY entries_said" }
  let filter = if legacy { "" } else { " AND kind = 'message' AND letter IS NULL" }
  let prior =
(
  $|(SELECT n FROM \{source} WHERE thread = NEW.thread\{filter} ORDER BY n DESC LIMIT 1)
)
  let other = if legacy {
(
  $|(SELECT CASE WHEN p.known=1 AND p.n IS NULL THEN 0 ELSE 1 END
  $|    FROM (\{ss_legacy_write_head(except="NEW.n")}) p)
)
  } else {
(
  $|EXISTS (SELECT 1 FROM \{source} WHERE thread = NEW.thread\{filter} AND n != NEW.n LIMIT 1)
)
  }
  let same =
(
  $|EXISTS (SELECT 1 FROM entries p WHERE p.thread = NEW.thread AND p.n = \{prior}
  $|    AND p.author_kind = 'person' AND p.author = NEW.author)
)
  let append_same = if legacy {
(
  $|(\{ss_eligible} AND NEW.author_kind='person' AND COALESCE((
  $|    SELECT p.known=1 AND p.n IS NOT NULL AND NEW.n>p.n AND EXISTS (
  $|      SELECT 1 FROM entries e WHERE e.thread=NEW.thread AND e.n=p.n
  $|        AND e.author_kind='person' AND e.author=NEW.author)
  $|    FROM (\{ss_legacy_write_head()}) p),0))
)
  } else {
(
  $|(\{ss_eligible} AND NEW.author_kind = 'person' AND NEW.n > \{prior} AND \{same})
)
  }
  let initial_known = if legacy {
(
  $|CASE WHEN EXISTS (SELECT 1 FROM thread_state WHERE thread=NEW.thread) THEN 0
  $|        WHEN \{ss_eligible} AND NOT \{other} THEN 1 ELSE 0 END
)
  } else {
(
  $|CASE WHEN \{ss_eligible} AND NOT \{other} THEN 1 ELSE 0 END
)
  }
  let previous = if legacy {
    ss_legacy_write_head(except="NEW.n")
  } else {
(
  $|SELECT
  $|    (SELECT n FROM entries INDEXED BY entries_said WHERE thread=NEW.thread AND n != NEW.n
  $|      AND kind='message' AND letter IS NULL ORDER BY n DESC LIMIT 1) AS n,1 AS known
)
  }
  let after_state =
(
  $|(said_other_known,said_other_n) = (
  $|    WITH previous AS MATERIALIZED (\{previous}),
  $|    previous_context AS MATERIALIZED (
  $|      SELECT previous.n,previous.known,
  $|        EXISTS (SELECT 1 FROM entries p WHERE p.thread=NEW.thread AND p.n=previous.n
  $|          AND p.author_kind='person' AND p.author=NEW.author) AS same
  $|      FROM previous
  $|    )
  $|    SELECT said_other_known,said_other_n WHERE NOT (\{ss_eligible})
  $|    UNION ALL
  $|    SELECT CASE
  $|      WHEN p.known=0 THEN 0
  $|      WHEN p.n IS NOT NULL AND NEW.n <= p.n THEN 0
  $|      WHEN NEW.author_kind != 'person' OR p.n IS NULL OR NOT p.same THEN 1
  $|      WHEN said_n = p.n THEN said_other_known ELSE 0 END,
  $|    CASE
  $|      WHEN p.known=0 THEN said_other_n
  $|      WHEN p.n IS NOT NULL AND NEW.n <= p.n THEN said_other_n
  $|      WHEN NEW.author_kind != 'person' OR p.n IS NULL THEN NULL
  $|      WHEN NOT p.same THEN p.n
  $|      WHEN said_n = p.n THEN said_other_n ELSE NULL END
  $|    FROM previous_context p WHERE \{ss_eligible}
  $|  )
)
  let add_state =
(
  $|CREATE TRIGGER thread_state_add AFTER INSERT ON entries BEGIN
  $|  -- said_after_insert_v2
  $|  INSERT INTO thread_state (thread, last_n, said_n, person_n, letters, said_other_known)
  $|    VALUES (NEW.thread, NEW.n,
  $|      CASE WHEN NEW.kind = 'message' AND NEW.letter IS NULL THEN NEW.n END,
  $|      CASE WHEN NEW.kind = 'message' AND NEW.author_kind = 'person' THEN NEW.n END,
  $|      CASE WHEN NEW.kind = 'message' AND NEW.letter IS NOT NULL THEN 1 ELSE 0 END,
  $|      \{initial_known})
  $|  ON CONFLICT (thread) DO UPDATE SET
  $|    last_n = MAX(last_n, excluded.last_n),
  $|    said_n = CASE WHEN excluded.said_n IS NULL THEN said_n WHEN said_n IS NULL THEN excluded.said_n ELSE MAX(said_n, excluded.said_n) END,
  $|    person_n = CASE WHEN excluded.person_n IS NULL THEN person_n WHEN person_n IS NULL THEN excluded.person_n ELSE MIN(person_n, excluded.person_n) END,
  $|    letters = letters + excluded.letters,
  $|    \{after_state};
  $|  INSERT INTO thread_people SELECT NEW.thread, NEW.author, NEW.n WHERE NEW.kind = 'message' AND NEW.author_kind = 'person'
  $|  ON CONFLICT (thread, author) DO UPDATE SET first_n = MIN(first_n, excluded.first_n);
  $|END;
)
  let before_insert =
(
  $|CREATE TRIGGER said_state_before_insert BEFORE INSERT ON entries
  $|  WHEN \{ss_eligible} OR \{ss_conflict} OR EXISTS (\{ss_rowid_victim}) BEGIN
  $|  -- said_after_insert_v2
  $|  -- A replacement can remove an entry without firing DELETE triggers. An old-history scan stays valid across an
  $|  -- append by the same person, but any other eligible insertion can change the boundary it is looking for.
  $|  DELETE FROM said_state_guard WHERE thread = NEW.thread
  $|    AND (\{ss_conflict} OR (\{ss_eligible} AND NOT COALESCE(\{append_same}, 0)));
  $|  UPDATE thread_state SET said_other_known=0 WHERE thread=NEW.thread AND \{ss_conflict};
  $|  DELETE FROM said_state_guard WHERE thread = (\{ss_rowid_victim});
  $|  UPDATE thread_state SET said_other_known=0 WHERE thread = (\{ss_rowid_victim});
  $|END;
)
  (add_state, before_insert)
}

///|
let ss_changed : String = "OLD.thread IS NOT NEW.thread OR OLD.n IS NOT NEW.n OR OLD.rowid IS NOT NEW.rowid OR OLD.kind IS NOT NEW.kind OR OLD.author_kind IS NOT NEW.author_kind OR OLD.author IS NOT NEW.author OR OLD.letter IS NOT NEW.letter OR OLD.ts IS NOT NEW.ts"

///|
let ss_invalidate : String =
(
  $|
  $|CREATE TRIGGER said_state_before_delete BEFORE DELETE ON entries BEGIN
  $|  DELETE FROM said_state_guard WHERE thread = OLD.thread;
  $|  UPDATE thread_state SET said_other_known = 0 WHERE thread = OLD.thread;
  $|END;
  $|CREATE TRIGGER said_state_before_update BEFORE UPDATE OF thread,n,rowid,_rowid_,oid,kind,author_kind,author,letter,ts ON entries
  $|  WHEN \{ss_changed} BEGIN
  $|  -- said_rowid_v2
  $|  DELETE FROM said_state_guard WHERE thread IN (OLD.thread, NEW.thread);
  $|  UPDATE thread_state SET said_other_known = 0 WHERE thread IN (OLD.thread, NEW.thread);
  $|  DELETE FROM said_state_guard WHERE thread = (\{ss_rowid_victim} AND OLD.rowid IS NOT NEW.rowid);
  $|  UPDATE thread_state SET said_other_known=0 WHERE thread = (\{ss_rowid_victim} AND OLD.rowid IS NOT NEW.rowid);
  $|END;
)

///|
/// The said boundary's coverage added without walking existing messages (`installSaidState`).
fn install_said_state(db : @sql.Db) -> Unit raise {
  let installed = () => exists(db, "table", "said_state_guard")
  let legacy = has_legacy_said(db)
  let current = () => {
    let source = if legacy { "said_write_probe" } else { "entries_said" }
    let writes = ["said_state_before_insert", "thread_state_add"].iter().all(name => {
      let sql = sql_of(db, "trigger", name) catch { _ => None }
      let sql = sql.unwrap_or("")
      sql.contains(source) && sql.contains("said_after_insert_v2")
    })
    writes && sql_of(db, "trigger", "said_state_before_update").unwrap_or("").contains("said_rowid_v2")
  }
  if installed() && current() {
    return
  }
  immediate(db, () => {
    let (add_state, before_insert) = ss_state_writers(legacy)
    if !installed() {
      db.exec(
(
  $|ALTER TABLE thread_state ADD COLUMN said_other_n INTEGER;
  $|        ALTER TABLE thread_state ADD COLUMN said_other_known INTEGER NOT NULL DEFAULT 0;
  $|        CREATE TABLE said_state_guard(thread INTEGER PRIMARY KEY, token TEXT NOT NULL,
  $|          author TEXT, other_n INTEGER, ready INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID;
  $|        DROP TRIGGER thread_state_add;
  $|        \{add_state}
  $|        \{before_insert}
  $|        \{ss_invalidate}
)
      )
    } else if !current() {
      db.exec(
(
  $|DROP TRIGGER IF EXISTS thread_state_add; DROP TRIGGER IF EXISTS said_state_before_insert;
  $|        DROP TRIGGER IF EXISTS said_state_before_delete; DROP TRIGGER IF EXISTS said_state_before_update;
  $|        \{add_state} \{before_insert} \{ss_invalidate}
)
      )
    }
  })
}

///|
let al_mark : String = "archive_last_v1"

///|
let archive_last_names : Array[String] = [
  "archive_last_insert", "archive_last_update", "archive_last_delete", "archive_last_thread_delete",
]

///|
let al_same_victim : String =
(
  $|(EXISTS (SELECT 1 FROM entries e WHERE e.thread=NEW.thread AND e.n=NEW.n AND e.kind='message')
  $|  OR (NEW.ts IS NOT NULL AND EXISTS (SELECT 1 FROM entries e
  $|    WHERE e.thread=NEW.thread AND e.ts=NEW.ts AND e.kind='message')))
)

///|
let al_rowid_victim : String = "SELECT e.thread FROM entries e WHERE e.rowid=NEW.rowid AND e.kind='message'"

///|
let al_triggers : String =
(
  $|
  $|CREATE TRIGGER archive_last_insert BEFORE INSERT ON entries
  $|  WHEN EXISTS (SELECT 1 FROM archive_last_guard LIMIT 1) BEGIN
  $|  -- \{al_mark}
  $|  DELETE FROM archive_last_guard WHERE thread=NEW.thread AND (NEW.kind='message' OR \{al_same_victim});
  $|  DELETE FROM archive_last_guard WHERE thread=(\{al_rowid_victim});
  $|END;
  $|CREATE TRIGGER archive_last_update BEFORE UPDATE OF thread,n,rowid,_rowid_,oid,kind,at,ts ON entries
  $|  WHEN EXISTS (SELECT 1 FROM archive_last_guard LIMIT 1) AND
  $|    (OLD.thread IS NOT NEW.thread OR OLD.n IS NOT NEW.n OR OLD.rowid IS NOT NEW.rowid OR OLD.kind IS NOT NEW.kind
  $|      OR OLD.at IS NOT NEW.at OR OLD.ts IS NOT NEW.ts) BEGIN
  $|  -- \{al_mark}
  $|  DELETE FROM archive_last_guard WHERE thread=OLD.thread AND OLD.kind='message';
  $|  DELETE FROM archive_last_guard WHERE thread=NEW.thread AND (NEW.kind='message' OR \{al_same_victim});
  $|  DELETE FROM archive_last_guard WHERE thread=(\{al_rowid_victim} AND OLD.rowid IS NOT NEW.rowid);
  $|END;
  $|CREATE TRIGGER archive_last_delete BEFORE DELETE ON entries
  $|  WHEN OLD.kind='message' BEGIN
  $|  -- \{al_mark}
  $|  DELETE FROM archive_last_guard WHERE thread=OLD.thread;
  $|END;
  $|CREATE TRIGGER archive_last_thread_delete AFTER DELETE ON threads BEGIN
  $|  -- \{al_mark}
  $|  DELETE FROM archive_last_guard WHERE thread=OLD.id;
  $|END;
)

///|
/// A chat's last message's guard installed without reading history; where another opener removed a guard trigger, the
/// epoch changed before it is restored (archive-last.ts `installArchiveLast`, as the store opens: `repair`).
fn install_archive_last(db : @sql.Db) -> Bool raise {
  let current = () => {
    if !exists(db, "table", "archive_last_meta") || !exists(db, "table", "archive_last_guard") {
      return false
    }
    let version = first_row(db, "SELECT version FROM archive_last_meta WHERE id=1")
    if version is None {
      return false
    }
    if !is_num(version, "version", 1) {
      refuse("archive last metadata has an unsupported version")
    }
    for name in archive_last_names {
      if !sql_of(db, "trigger", name).unwrap_or("").contains(al_mark) {
        return false
      }
    }
    true
  }
  if current() {
    return true
  }
  immediate(db, () => if !current() {
    db.exec(
(
  $|CREATE TABLE IF NOT EXISTS archive_last_meta(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL,
  $|          epoch TEXT NOT NULL) WITHOUT ROWID;
  $|        CREATE TABLE IF NOT EXISTS archive_last_guard(thread INTEGER PRIMARY KEY,epoch TEXT NOT NULL,
  $|          before_n INTEGER,at INTEGER,ready INTEGER NOT NULL) WITHOUT ROWID;
)
    )
    let version = first_row(db, "SELECT version FROM archive_last_meta WHERE id=1")
    if version is Some(_) && !is_num(version, "version", 1) {
      refuse("archive last version \{shown(version, "version", "undefined")} is incompatible")
    }
    ignore(
      db.run(
(
  $|INSERT INTO archive_last_meta VALUES(1,?,lower(hex(randomblob(16))))
  $|        ON CONFLICT(id) DO UPDATE SET epoch=excluded.epoch
)
        , [Json::number(1.0)],
      ),
    )
    for name in archive_last_names {
      db.exec("DROP TRIGGER IF EXISTS \{name}")
    }
    db.exec(al_triggers)
  })
  true
}

///|
let wsrc_version : Int = 1

///|
fn wsrc_candidates(row : String) -> String {
(
  $|SELECT \{row}.thread AS thread, \{row}.n AS n WHERE \{row}.kind = 'message'
  $|  UNION SELECT \{row}.thread, \{row}.target WHERE \{row}.target IS NOT NULL
)
}

///|
fn wsrc_conflicts(entry_rowid : String) -> String {
(
  $|SELECT e.thread, e.n FROM entries e WHERE e.thread = NEW.thread AND e.n = NEW.n AND e.kind = 'message'
  $|  UNION SELECT e.thread, e.target FROM entries e WHERE e.thread = NEW.thread AND e.n = NEW.n AND e.target IS NOT NULL
  $|  UNION SELECT e.thread, e.n FROM entries e WHERE NEW.ts IS NOT NULL AND e.thread = NEW.thread AND e.ts = NEW.ts AND e.kind = 'message'
  $|  UNION SELECT e.thread, e.target FROM entries e WHERE NEW.ts IS NOT NULL AND e.thread = NEW.thread AND e.ts = NEW.ts AND e.target IS NOT NULL
  $|  UNION SELECT e.thread, e.n FROM entries e WHERE e.rowid = \{entry_rowid} AND e.kind = 'message'
  $|  UNION SELECT e.thread, e.target FROM entries e WHERE e.rowid = \{entry_rowid} AND e.target IS NOT NULL
)
}

///|
fn wsrc_needs_insert(legacy_edits : Bool, old_index : Bool, entry_rowid : String) -> String {
  let latest = if legacy_edits {
(
  $|COALESCE((\{legacy_edit_latest("NEW.thread", "NEW.target", "1", old_index)})<=NEW.n,1)
)
  } else {
    "NOT EXISTS (SELECT 1 FROM entries x WHERE x.thread=NEW.thread AND x.target=NEW.target AND x.n>NEW.n)"
  }
(
  $|(NEW.kind = 'message' AND NEW.target IS NOT NULL)
  $|  OR (NEW.target IS NOT NULL AND EXISTS (SELECT 1 FROM merged m
  $|    WHERE m.thread=NEW.thread AND m.n=NEW.target AND m.attachments IS NOT NEW.attachments
  $|      AND \{latest}))
  $|  OR EXISTS (SELECT 1 FROM entries e WHERE e.thread=NEW.thread AND e.n=NEW.n)
  $|  OR (NEW.ts IS NOT NULL AND EXISTS (SELECT 1 FROM entries e WHERE e.thread=NEW.thread AND e.ts=NEW.ts))
  $|  OR EXISTS (SELECT 1 FROM entries e WHERE e.rowid=\{entry_rowid})
)
}

///|
let wsrc_tracked_insert : String =
(
  $|EXISTS (SELECT 1 FROM widget_source_scopes s WHERE s.thread=NEW.thread)
  $|  OR EXISTS (SELECT 1 FROM entries e JOIN widget_source_scopes s ON s.thread=e.thread WHERE e.rowid=NEW.rowid)
  $|  OR EXISTS (SELECT 1 FROM widget_source_changed)
)

///|
let wsrc_tracked_update : String =
(
  $|(\{wsrc_tracked_insert}) OR EXISTS (SELECT 1 FROM widget_source_scopes s WHERE s.thread=OLD.thread)
)

///|
fn wsrc_stage(updating : Bool, legacy_edits : Bool, old_index : Bool, entry_rowid : String) -> String {
  let union_old = if updating { " UNION \{wsrc_candidates("OLD")}" } else { "" }
  let gate = if updating { "" } else { " AND (\{wsrc_needs_insert(legacy_edits, old_index, entry_rowid)})" }
(
  $|DELETE FROM widget_source_changed WHERE thread IS NOT NULL;
  $|  INSERT INTO widget_source_changed (thread, n, existed, attachments, at, dirty)
  $|    SELECT k.thread, k.n, m.n IS NOT NULL, m.attachments, m.created_at, 0
  $|    FROM (\{wsrc_candidates("NEW")} UNION \{wsrc_conflicts(entry_rowid)}\{union_old}) k
  $|    LEFT JOIN merged m ON m.thread = k.thread AND m.n = k.n
  $|    WHERE EXISTS (SELECT 1 FROM widget_source_scopes s WHERE s.thread=k.thread)\{gate};
)
}

///|
fn wsrc_before_gate(old_index : Bool) -> String {
(
  $|CREATE VIEW widget_source_before_gate(thread,n,kind,target,ts,entry_rowid,attachments) AS
  $|  SELECT NULL,NULL,NULL,NULL,NULL,NULL,NULL WHERE 0;
  $|  CREATE TRIGGER widget_source_before_gate_run INSTEAD OF INSERT ON widget_source_before_gate
  $|    BEGIN \{wsrc_stage(false, true, old_index, "NEW.entry_rowid")} END;
)
}

///|
fn wsrc_before_add(legacy_edits : Bool) -> String {
  let body = if legacy_edits {
(
  $|INSERT INTO widget_source_before_gate(thread,n,kind,target,ts,entry_rowid,attachments)
  $|        VALUES(NEW.thread,NEW.n,NEW.kind,NEW.target,NEW.ts,NEW.rowid,NEW.attachments);
)
  } else {
    wsrc_stage(false, false, false, "NEW.rowid")
  }
(
  $|CREATE TRIGGER widget_source_before_add BEFORE INSERT ON entries
  $|  WHEN \{wsrc_tracked_insert} BEGIN \{body} END;
)
}

///|
let wsrc_changed : String =
(
  $|(c.dirty = 1 OR c.existed IS NOT (m.n IS NOT NULL)
  $|  OR c.attachments IS NOT m.attachments OR c.at IS NOT m.created_at)
)

///|
let wsrc_changes : String =
(
  $|SELECT c.thread, c.n FROM widget_source_changed c
  $|  LEFT JOIN merged m ON m.thread = c.thread AND m.n = c.n WHERE \{wsrc_changed}
)

///|
let wsrc_affected : String = "SELECT thread,n FROM widget_source_changed WHERE dirty=1"

///|
let wsrc_valid_attachments : String = "CASE WHEN json_valid(m.attachments) THEN m.attachments ELSE '[]' END"

///|
let wsrc_path_of : String = "CASE WHEN json_valid(a.value) THEN json_extract(a.value, '$.path') END"

///|
let wsrc_name_of : String = "CASE WHEN json_valid(a.value) THEN json_extract(a.value, '$.name') END"

///|
let wsrc_invalid : String =
(
  $|(m.attachments IS NOT NULL AND (NOT json_valid(m.attachments) OR EXISTS
  $|  (SELECT 1 FROM json_each(\{wsrc_valid_attachments}) a WHERE a.value IS NOT NULL AND NOT json_valid(a.value))))
)

///|
fn wsrc_insert_rows(messages : String) -> String {
(
  $|INSERT INTO widget_source_rows (thread,n,slot,path,at,name)
  $|  SELECT m.thread, m.n, a.id, \{wsrc_path_of}, m.created_at, \{wsrc_name_of}
  $|  FROM (\{messages}) k CROSS JOIN merged m ON m.thread = k.thread AND m.n = k.n
  $|  CROSS JOIN json_each(\{wsrc_valid_attachments}) a
  $|  WHERE typeof(\{wsrc_path_of}) = 'text' AND NOT EXISTS (SELECT 1 FROM widget_source_rows i
  $|    WHERE i.thread = m.thread AND i.n = m.n AND i.slot = a.id);
)
}

///|
fn wsrc_insert_invalid(messages : String) -> String {
(
  $|INSERT INTO widget_source_invalid (thread,n)
  $|  SELECT m.thread, m.n FROM (\{messages}) k CROSS JOIN merged m ON m.thread = k.thread AND m.n = k.n
  $|  WHERE \{wsrc_invalid} AND NOT EXISTS (SELECT 1 FROM widget_source_invalid i WHERE i.thread = m.thread AND i.n = m.n);
)
}

///|
let wsrc_reconcile : String =
(
  $|UPDATE widget_source_changed SET dirty=1 WHERE (thread,n) IN (\{wsrc_changes});
  $|  DELETE FROM widget_source_rows WHERE (thread,n) IN (\{wsrc_affected});
  $|  DELETE FROM widget_source_invalid WHERE (thread,n) IN (\{wsrc_affected});
  $|  \{wsrc_insert_rows(wsrc_affected)} \{wsrc_insert_invalid(wsrc_affected)} DELETE FROM widget_source_changed WHERE thread IS NOT NULL;
)

///|
let wsrc_old_messages : String =
(
  $|SELECT OLD.thread AS thread, OLD.n AS n WHERE OLD.kind = 'message'
  $|  UNION SELECT OLD.thread, OLD.target WHERE OLD.target IS NOT NULL
)

///|
let wsrc_new_message : String = "SELECT NEW.thread AS thread, NEW.n AS n"

///|
let wsrc_after_delete : String =
(
  $|DELETE FROM widget_source_rows WHERE (thread,n) IN (\{wsrc_old_messages});
  $|  DELETE FROM widget_source_invalid WHERE (thread,n) IN (\{wsrc_old_messages});
  $|  \{wsrc_insert_rows(wsrc_old_messages)} \{wsrc_insert_invalid(wsrc_old_messages)}
  $|  UPDATE widget_source_changed SET dirty = 1 WHERE (thread,n) IN (\{wsrc_old_messages});
)

///|
let wsrc_updated : String =
(
  $|OLD.rowid IS NOT NEW.rowid OR OLD.thread IS NOT NEW.thread OR OLD.n IS NOT NEW.n OR OLD.kind IS NOT NEW.kind
  $|  OR OLD.target IS NOT NEW.target OR OLD.ts IS NOT NEW.ts OR OLD.attachments IS NOT NEW.attachments OR OLD.at IS NOT NEW.at
)

///|
/// Whether the installed insert trigger no longer matches the edit lookup (`widgetSourceBeforeAddNeedsRepair`).
pub fn widget_source_before_add_needs_repair(db : @sql.Db) -> Bool raise {
  guard sql_of(db, "trigger", "widget_source_before_add") is Some(sql) else { return false }
  let gated = sql.contains("widget_source_before_gate")
  let gate = exists(db, "view", "widget_source_before_gate")
  let gate_sql = sql_of(db, "trigger", "widget_source_before_gate_run")
  let legacy = uses_legacy_edits(db)
  let old_index = legacy && legacy_edits_use_old_index(db)
  gated != legacy ||
  gate != legacy ||
  (gate_sql is Some(_)) != legacy ||
  (!gated && sql.contains("FROM entries x INDEXED BY entries_target")) ||
  (legacy && gate_sql is Some(g) && g.contains("INDEXED BY entries_target") != old_index)
}

///|
/// Called while the caller holds the write transaction, after changing the merged lookup.
pub fn repair_widget_source_before_add(db : @sql.Db) -> Unit raise {
  if !widget_source_before_add_needs_repair(db) {
    return
  }
  let legacy = uses_legacy_edits(db)
  let gate = if legacy { wsrc_before_gate(legacy_edits_use_old_index(db)) } else { "" }
  db.exec(
(
  $|DROP TRIGGER widget_source_before_add;
  $|    DROP TRIGGER IF EXISTS widget_source_before_gate_run; DROP VIEW IF EXISTS widget_source_before_gate;
  $|    \{gate} \{wsrc_before_add(legacy)}
)
  )
}

///|
fn check_widget_sources(db : @sql.Db) -> Unit raise {
  let meta = first_row(db, "SELECT version FROM widget_source_meta WHERE id=1")
  if meta is None || !is_num(meta, "version", wsrc_version) {
    refuse("widget source index version \{shown(meta, "version", "missing")} is incompatible with \{wsrc_version}")
  }
}

///|
/// Widgets' sources: tables and the writers that follow both old and new stations (`installWidgetSources`).
fn install_widget_sources(db : @sql.Db) -> Unit raise {
  let installed = () => exists(db, "table", "widget_source_meta")
  if installed() {
    check_widget_sources(db)
    if !widget_source_before_add_needs_repair(db) {
      return
    }
    immediate(db, () => {
      check_widget_sources(db)
      repair_widget_source_before_add(db)
    })
    return
  }
  immediate(db, () => if !installed() {
    let legacy = uses_legacy_edits(db)
    let gate = if legacy { wsrc_before_gate(legacy_edits_use_old_index(db)) } else { "" }
    db.exec(
(
  $|
  $|      CREATE TABLE widget_source_meta (id INTEGER PRIMARY KEY CHECK (id=1), version INTEGER NOT NULL) WITHOUT ROWID;
  $|      INSERT INTO widget_source_meta SELECT 1, \{wsrc_version};
  $|      CREATE TABLE widget_source_scopes (thread INTEGER PRIMARY KEY, last_n INTEGER, end_n INTEGER, complete INTEGER NOT NULL) WITHOUT ROWID;
  $|      CREATE TABLE widget_source_rows (thread INTEGER NOT NULL, n INTEGER NOT NULL, slot INTEGER NOT NULL,
  $|        path TEXT NOT NULL, at INTEGER NOT NULL, name, PRIMARY KEY(thread,n,slot)) WITHOUT ROWID;
  $|      CREATE INDEX widget_source_by_path ON widget_source_rows (thread,path,at DESC,n,slot);
  $|      CREATE TABLE widget_source_invalid (thread INTEGER NOT NULL, n INTEGER NOT NULL, PRIMARY KEY(thread,n)) WITHOUT ROWID;
  $|      CREATE TABLE widget_source_changed (thread INTEGER NOT NULL, n INTEGER NOT NULL, existed INTEGER NOT NULL,
  $|        attachments TEXT, at INTEGER, dirty INTEGER NOT NULL, PRIMARY KEY(thread,n)) WITHOUT ROWID;
  $|      \{gate}
  $|      \{wsrc_before_add(legacy)}
  $|      CREATE TRIGGER widget_source_add AFTER INSERT ON entries WHEN EXISTS (SELECT 1 FROM widget_source_changed) BEGIN \{wsrc_reconcile} END;
  $|      CREATE TRIGGER widget_source_fast_add AFTER INSERT ON entries WHEN NEW.kind='message' AND NEW.target IS NULL
  $|        AND EXISTS (SELECT 1 FROM widget_source_scopes WHERE thread=NEW.thread)
  $|        AND NOT EXISTS (SELECT 1 FROM widget_source_changed)
  $|        AND ((NEW.attachments IS NOT NULL AND NEW.attachments <> '[]')
  $|          OR EXISTS (SELECT 1 FROM entries e WHERE e.thread=NEW.thread AND e.target=NEW.n))
  $|        BEGIN \{wsrc_insert_rows(wsrc_new_message)} \{wsrc_insert_invalid(wsrc_new_message)} END;
  $|      CREATE TRIGGER widget_source_before_change BEFORE UPDATE OF rowid,_rowid_,oid,thread,n,kind,target,ts,attachments,at ON entries
  $|        WHEN (\{wsrc_updated}) AND (\{wsrc_tracked_update}) BEGIN \{wsrc_stage(true, false, false, "NEW.rowid")} END;
  $|      CREATE TRIGGER widget_source_change AFTER UPDATE OF rowid,_rowid_,oid,thread,n,kind,target,ts,attachments,at ON entries
  $|        WHEN (\{wsrc_updated}) AND EXISTS (SELECT 1 FROM widget_source_changed) BEGIN \{wsrc_reconcile} END;
  $|      CREATE TRIGGER widget_source_drop AFTER DELETE ON entries
  $|        WHEN EXISTS (SELECT 1 FROM widget_source_scopes WHERE thread=OLD.thread) BEGIN \{wsrc_after_delete} END;
  $|      CREATE TRIGGER widget_source_drop_thread AFTER DELETE ON threads
  $|        WHEN NOT EXISTS (SELECT 1 FROM entries WHERE thread=OLD.id)
  $|        BEGIN DELETE FROM widget_source_scopes WHERE thread=OLD.id; END;
  $|    
)
    )
  } else {
    check_widget_sources(db)
    repair_widget_source_before_add(db)
  })
}

///|
let cx_version : Int = 1

///|
fn cx_order_change(thread : String) -> String {
(
  $|
  $|  INSERT INTO cc_order_dispatch(thread, after_session, through_session)
  $|    SELECT \{thread}, NULL, (SELECT session FROM cc_session_rows INDEXED BY cc_rows_thread
  $|      WHERE thread=\{thread} ORDER BY session DESC LIMIT 1) WHERE \{thread} IS NOT NULL
  $|      AND EXISTS (SELECT 1 FROM cc_session_rows INDEXED BY cc_rows_thread WHERE thread=\{thread} LIMIT 1)
  $|      AND NOT EXISTS (SELECT 1 FROM cc_order_dispatch WHERE thread=\{thread});
)
}

///|
fn cx_member_change(thread : String, session : String) -> String {
(
  $|
  $|  INSERT INTO cc_session_dirty(session, thread)
  $|    SELECT \{session}, \{thread} WHERE \{session} IS NOT NULL AND \{thread} IS NOT NULL
  $|      AND EXISTS (SELECT 1 FROM cc_sessions WHERE session=\{session})
  $|      AND NOT EXISTS (SELECT 1 FROM cc_session_dirty WHERE session=\{session} AND thread=\{thread});
)
}

///|
let cx_displaced_member_thread : String = "(SELECT thread FROM thread_sessions WHERE rowid=NEW.rowid)"

///|
let cx_displaced_member_session : String = "(SELECT session FROM thread_sessions WHERE rowid=NEW.rowid)"

///|
let cx_displaced_entry : String = "(SELECT thread FROM entries WHERE rowid=NEW.rowid)"

///|
let cx_displaced_thread : String =
(
  $|(SELECT id FROM threads WHERE surface=NEW.surface AND channel=NEW.channel
  $|  AND thread_ts=NEW.thread_ts)
)

///|
fn check_cc_index(db : @sql.Db) -> Unit raise {
  let row = first_row(db, "SELECT version FROM cc_index_meta WHERE id=1")
  if !is_num(row, "version", cx_version) {
    refuse("copy destination index version \{shown(row, "version", "missing")} is incompatible with \{cx_version}")
  }
}

///|
/// Copy destinations of the requested sessions (`installCcIndex`).
fn install_cc_index(db : @sql.Db) -> Unit raise {
  let installed = () => exists(db, "table", "cc_index_meta")
  if installed() {
    check_cc_index(db)
    return
  }
  immediate(db, () => if !installed() {
    db.exec(
(
  $|
  $|      CREATE TABLE cc_index_meta (id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL) WITHOUT ROWID;
  $|      INSERT INTO cc_index_meta VALUES(1, \{cx_version});
  $|      CREATE TABLE cc_sessions (session TEXT PRIMARY KEY, scan_after INTEGER, scan_end INTEGER,
  $|        complete INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID;
  $|      -- Keep memberships whose thread is missing or currently internal too: a later thread write may expose them.
  $|      CREATE TABLE cc_session_rows (session TEXT NOT NULL, thread INTEGER NOT NULL, surface TEXT,
  $|        created_at INTEGER, last_at INTEGER, PRIMARY KEY(session,thread)) WITHOUT ROWID;
  $|      CREATE INDEX cc_session_order ON cc_session_rows(session,last_at DESC,created_at DESC,thread DESC)
  $|        WHERE surface != '\{stillfail_surface}';
  $|      CREATE INDEX cc_rows_thread ON cc_session_rows(thread,session);
  $|      CREATE TABLE cc_session_dirty (session TEXT NOT NULL, thread INTEGER NOT NULL,
  $|        PRIMARY KEY(session,thread)) WITHOUT ROWID;
  $|      CREATE TABLE cc_order_dispatch (thread INTEGER PRIMARY KEY, after_session TEXT, through_session TEXT NOT NULL);
  $|      CREATE TABLE cc_order_turn (id INTEGER PRIMARY KEY CHECK(id=1), after_thread INTEGER, through_thread INTEGER);
  $|      INSERT INTO cc_order_turn VALUES(1,NULL,NULL);
  $|
  $|      -- An old writer can replace a different membership by rowid without a DELETE trigger.
  $|      CREATE TRIGGER cc_member_before_add BEFORE INSERT ON thread_sessions BEGIN
  $|        \{cx_member_change("NEW.thread", "NEW.session")}
  $|        \{cx_member_change(cx_displaced_member_thread, cx_displaced_member_session)}
  $|      END;
  $|      CREATE TRIGGER cc_member_add AFTER INSERT ON thread_sessions BEGIN \{cx_member_change("NEW.thread", "NEW.session")} END;
  $|      CREATE TRIGGER cc_member_before_change BEFORE UPDATE ON thread_sessions
  $|        WHEN OLD.thread IS NOT NEW.thread OR OLD.session IS NOT NEW.session OR OLD.rowid IS NOT NEW.rowid BEGIN
  $|          \{cx_member_change("OLD.thread", "OLD.session")}
  $|          \{cx_member_change("NEW.thread", "NEW.session")}
  $|          \{cx_member_change(cx_displaced_member_thread, cx_displaced_member_session)}
  $|      END;
  $|      CREATE TRIGGER cc_member_change AFTER UPDATE ON thread_sessions
  $|        WHEN OLD.thread IS NOT NEW.thread OR OLD.session IS NOT NEW.session OR OLD.rowid IS NOT NEW.rowid BEGIN
  $|          \{cx_member_change("NEW.thread", "NEW.session")}
  $|      END;
  $|      -- A departed membership no longer needs a row or a future reconciliation, even if its session is never read again.
  $|      CREATE TRIGGER cc_member_drop AFTER DELETE ON thread_sessions BEGIN
  $|        DELETE FROM cc_session_rows WHERE session=OLD.session AND thread=OLD.thread;
  $|        DELETE FROM cc_session_dirty WHERE session=OLD.session AND thread=OLD.thread;
  $|      END;
  $|
  $|      -- A row added behind a running distributor's cursor stays dirty until that distribution has ended.
  $|      CREATE TRIGGER cc_row_add AFTER INSERT ON cc_session_rows
  $|        WHEN EXISTS (SELECT 1 FROM cc_order_dispatch WHERE thread=NEW.thread) BEGIN
  $|          \{cx_member_change("NEW.thread", "NEW.session")}
  $|      END;
  $|
  $|      CREATE TRIGGER cc_thread_before_add BEFORE INSERT ON threads BEGIN
  $|        \{cx_order_change("NEW.id")} \{cx_order_change(cx_displaced_thread)}
  $|      END;
  $|      CREATE TRIGGER cc_thread_add AFTER INSERT ON threads BEGIN \{cx_order_change("NEW.id")} END;
  $|      CREATE TRIGGER cc_thread_before_change BEFORE UPDATE ON threads
  $|        WHEN OLD.id IS NOT NEW.id OR OLD.surface IS NOT NEW.surface OR OLD.created_at IS NOT NEW.created_at
  $|          OR OLD.channel IS NOT NEW.channel OR OLD.thread_ts IS NOT NEW.thread_ts BEGIN
  $|        \{cx_order_change("OLD.id")} \{cx_order_change("NEW.id")} \{cx_order_change(cx_displaced_thread)}
  $|      END;
  $|      CREATE TRIGGER cc_thread_change AFTER UPDATE ON threads
  $|        WHEN OLD.id IS NOT NEW.id OR OLD.surface IS NOT NEW.surface OR OLD.created_at IS NOT NEW.created_at
  $|          OR OLD.channel IS NOT NEW.channel OR OLD.thread_ts IS NOT NEW.thread_ts BEGIN
  $|        \{cx_order_change("OLD.id")} \{cx_order_change("NEW.id")}
  $|      END;
  $|      CREATE TRIGGER cc_thread_drop AFTER DELETE ON threads BEGIN \{cx_order_change("OLD.id")} END;
  $|
  $|      -- Track the source of the original query's timestamp, including manual changes and REPLACE by rowid.
  $|      CREATE TRIGGER cc_state_add AFTER INSERT ON thread_state BEGIN \{cx_order_change("NEW.thread")} END;
  $|      CREATE TRIGGER cc_state_change AFTER UPDATE OF thread,last_n ON thread_state
  $|        WHEN OLD.thread IS NOT NEW.thread OR OLD.last_n IS NOT NEW.last_n BEGIN
  $|          \{cx_order_change("OLD.thread")} \{cx_order_change("NEW.thread")}
  $|      END;
  $|      CREATE TRIGGER cc_state_drop AFTER DELETE ON thread_state BEGIN \{cx_order_change("OLD.thread")} END;
  $|      CREATE TRIGGER cc_entry_before_add BEFORE INSERT ON entries BEGIN \{cx_order_change(cx_displaced_entry)} END;
  $|      CREATE TRIGGER cc_entry_add AFTER INSERT ON entries BEGIN \{cx_order_change("NEW.thread")} END;
  $|      CREATE TRIGGER cc_entry_before_change BEFORE UPDATE OF rowid,_rowid_,oid,thread,n,ts,at ON entries BEGIN
  $|        \{cx_order_change("OLD.thread")} \{cx_order_change("NEW.thread")} \{cx_order_change(cx_displaced_entry)}
  $|      END;
  $|      CREATE TRIGGER cc_entry_change AFTER UPDATE OF rowid,_rowid_,oid,thread,n,ts,at ON entries BEGIN
  $|        \{cx_order_change("OLD.thread")} \{cx_order_change("NEW.thread")}
  $|      END;
  $|      CREATE TRIGGER cc_entry_drop AFTER DELETE ON entries BEGIN \{cx_order_change("OLD.thread")} END;
  $|    
)
    )
  } else {
    check_cc_index(db)
  })
}

///|
let sx_version : Int = 1

///|
fn sx_last_at(thread : String) -> String {
(
  $|(SELECT at FROM entries WHERE thread=\{thread} ORDER BY n DESC LIMIT 1)
)
}

///|
fn sx_exists(session : String, thread : String) -> String {
(
  $|(EXISTS
  $|  (SELECT 1 FROM thread_sessions m JOIN threads t ON t.id=m.thread WHERE m.session=\{session} AND m.thread=\{thread}))
)
}

///|
fn sx_refresh(session : String, thread : String) -> String {
(
  $|UPDATE cc_session_rows SET
  $|    name_present=\{sx_exists(session, thread)},
  $|    name_has_last=CASE WHEN \{sx_exists(session, thread)} THEN (\{sx_last_at(thread)} IS NOT NULL) END,
  $|    name_last_at=CASE WHEN \{sx_exists(session, thread)} THEN COALESCE(\{sx_last_at(thread)},0) END,
  $|    name_created_at=(SELECT created_at FROM threads WHERE id=\{thread})
  $|  WHERE session=\{session} AND thread=\{thread}
  $|    AND EXISTS (SELECT 1 FROM session_chat_scopes WHERE session=\{session})
  $|    AND (name_present IS NOT \{sx_exists(session, thread)} OR (\{sx_exists(session, thread)} AND
  $|      (name_has_last IS NOT (\{sx_last_at(thread)} IS NOT NULL) OR name_last_at IS NOT COALESCE(\{sx_last_at(thread)},0)
  $|        OR name_created_at IS NOT (SELECT created_at FROM threads WHERE id=\{thread}))))
)
}

///|
fn sx_ensure(session : String, thread : String) -> String {
(
  $|INSERT OR IGNORE INTO session_chat_rows(session,has_last,last_at,created_at,thread)
  $|  SELECT session,name_has_last,name_last_at,name_created_at,thread FROM cc_session_rows
  $|  WHERE session=\{session} AND thread=\{thread} AND name_present=1
  $|    AND EXISTS (SELECT 1 FROM session_chat_scopes WHERE session=\{session})
)
}

///|
fn check_session_chat_index(db : @sql.Db) -> Unit raise {
  let row = first_row(db, "SELECT version FROM session_chat_meta WHERE id=1")
  if !is_num(row, "version", sx_version) {
    refuse("session chat index version \{shown(row, "version", "missing")} is incompatible with \{sx_version}")
  }
}

///|
/// A session's chat by its last message, over the copy rows (`installSessionChatIndex`).
fn install_session_chat_index(db : @sql.Db) -> Unit raise {
  let installed = () => exists(db, "table", "session_chat_meta")
  if installed() {
    check_session_chat_index(db)
    return
  }
  immediate(db, () => if !installed() {
    db.exec(
(
  $|CREATE TABLE session_chat_meta (id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL) WITHOUT ROWID;
  $|  INSERT INTO session_chat_meta VALUES(1,\{sx_version});
  $|  CREATE TABLE session_chat_scopes (
  $|    session TEXT PRIMARY KEY, scan_after INTEGER, scan_end INTEGER, complete INTEGER NOT NULL DEFAULT 0
  $|  ) WITHOUT ROWID;
  $|  -- Store the old order key on the already-tracked copy row; this permits one ordered tree for names.
  $|  ALTER TABLE cc_session_rows ADD COLUMN name_present INTEGER NOT NULL DEFAULT 0;
  $|  ALTER TABLE cc_session_rows ADD COLUMN name_has_last INTEGER;
  $|  ALTER TABLE cc_session_rows ADD COLUMN name_last_at;
  $|  ALTER TABLE cc_session_rows ADD COLUMN name_created_at INTEGER;
  $|  CREATE TABLE session_chat_rows (
  $|    session TEXT NOT NULL, has_last INTEGER NOT NULL, last_at NOT NULL, created_at INTEGER NOT NULL, thread INTEGER NOT NULL,
  $|    PRIMARY KEY(session,has_last DESC,last_at DESC,created_at DESC,thread DESC)
  $|  ) WITHOUT ROWID;
  $|  CREATE TRIGGER session_chat_session_drop AFTER DELETE ON sessions BEGIN
  $|    DELETE FROM session_chat_scopes WHERE session=OLD.key;
  $|  END;
  $|  CREATE TRIGGER session_chat_scope_drop AFTER DELETE ON session_chat_scopes BEGIN
  $|    DELETE FROM session_chat_rows WHERE session=OLD.session;
  $|  END;
  $|  CREATE TRIGGER session_chat_cc_drop AFTER DELETE ON cc_session_rows BEGIN
  $|    DELETE FROM session_chat_rows WHERE session=OLD.session AND has_last=OLD.name_has_last AND last_at=OLD.name_last_at
  $|      AND created_at=OLD.name_created_at AND thread=OLD.thread AND OLD.name_present=1;
  $|  END;
  $|  CREATE TRIGGER session_chat_cc_name AFTER UPDATE OF name_present,name_has_last,name_last_at,name_created_at ON cc_session_rows
  $|    WHEN OLD.name_present IS NOT NEW.name_present OR OLD.name_has_last IS NOT NEW.name_has_last
  $|      OR OLD.name_last_at IS NOT NEW.name_last_at OR OLD.name_created_at IS NOT NEW.name_created_at BEGIN
  $|    DELETE FROM session_chat_rows WHERE session=OLD.session AND has_last=OLD.name_has_last AND last_at=OLD.name_last_at
  $|      AND created_at=OLD.name_created_at AND thread=OLD.thread AND OLD.name_present=1;
  $|    INSERT OR IGNORE INTO session_chat_rows(session,has_last,last_at,created_at,thread)
  $|      SELECT NEW.session,NEW.name_has_last,NEW.name_last_at,NEW.name_created_at,NEW.thread
  $|      WHERE NEW.name_present=1 AND EXISTS (SELECT 1 FROM session_chat_scopes WHERE session=NEW.session);
  $|  END;
  $|  -- Name scopes are created only after copy tracking is complete. Later changes become dirty before their copy row
  $|  -- changes; refresh once as that work settles, even if the copy row itself was unchanged (an old partial deletion).
  $|  CREATE TRIGGER session_chat_cc_settled AFTER DELETE ON cc_session_dirty
  $|    WHEN EXISTS (SELECT 1 FROM session_chat_scopes WHERE session=OLD.session) BEGIN
  $|      \{sx_refresh("OLD.session", "OLD.thread")};
  $|      \{sx_ensure("OLD.session", "OLD.thread")};
  $|  END;
)
    )
  } else {
    check_session_chat_index(db)
  })
}

///|
let lt_version : Int = 1

///|
fn lt_last_delivery(session : String, thread : String, extra : String) -> String {
(
  $|(SELECT d.rowid FROM deliveries d INDEXED BY deliveries_session
  $|  WHERE d.session=\{session} AND d.thread=\{thread} \{extra} ORDER BY d.rowid DESC LIMIT 1)
)
}

///|
let lt_prior_delivery : String = lt_last_delivery("NEW.session", "NEW.thread", "AND d.rowid<>NEW.rowid")

///|
let lt_changed : String = "EXISTS (SELECT 1 FROM latest_thread_changed LIMIT 1)"

///|
let lt_updating : String = "EXISTS (SELECT 1 FROM latest_thread_updating LIMIT 1)"

///|
fn lt_stage(keys : String, table? : String = "latest_thread_changed", missing_thread? : Bool = false) -> String {
  let valid = if missing_thread { "" } else { "AND t.id IS NOT NULL" }
(
  $|DELETE FROM \{table};
  $|  INSERT INTO \{table}(session,thread,old_valid,old_has,old_last,old_joined,old_member)
  $|    SELECT k.session,k.thread,m.rowid IS NOT NULL \{valid},
  $|      \{lt_last_delivery("k.session", "k.thread", "")} IS NOT NULL,COALESCE(\{lt_last_delivery("k.session", "k.thread", "")},0),m.joined_at,m.rowid
  $|    FROM (\{keys}) k LEFT JOIN thread_sessions m ON m.session=k.session AND m.thread=k.thread
  $|      LEFT JOIN threads t ON t.id=k.thread
  $|    WHERE k.session IS NOT NULL AND k.thread IS NOT NULL
  $|      AND EXISTS (SELECT 1 FROM latest_thread_scopes s WHERE s.session=k.session);
)
}

///|
let lt_latest_thread_refresh_updating : String =
(
  $|UPDATE latest_thread_updating
  $|    SET (old_valid,old_has,old_last,old_joined,old_member) =
  $|      (SELECT m.rowid IS NOT NULL AND t.id IS NOT NULL,
  $|        \{lt_last_delivery("x.session", "x.thread", "")} IS NOT NULL,COALESCE(\{lt_last_delivery("x.session", "x.thread", "")},0),m.joined_at,m.rowid
  $|        FROM latest_thread_changed x LEFT JOIN thread_sessions m ON m.session=x.session AND m.thread=x.thread
  $|          LEFT JOIN threads t ON t.id=x.thread
  $|        WHERE x.session=latest_thread_updating.session AND x.thread=latest_thread_updating.thread)
  $|    WHERE (session,thread) IN (SELECT session,thread FROM latest_thread_changed);
)

///|
fn lt_reconcile(table? : String = "latest_thread_changed") -> String {
  let refresh = if table == "latest_thread_changed" { lt_latest_thread_refresh_updating } else { "" }
(
  $|DELETE FROM latest_thread_rows WHERE (session,has_last,last_delivery,joined_at,member_rowid) IN
  $|    (SELECT session,old_has,old_last,old_joined,old_member FROM \{table} WHERE old_valid=1);
  $|  DELETE FROM latest_thread_members WHERE (thread,session) IN
  $|    (SELECT x.thread,x.session FROM \{table} x WHERE NOT EXISTS
  $|      (SELECT 1 FROM thread_sessions m WHERE m.thread=x.thread AND m.session=x.session));
  $|  INSERT INTO latest_thread_members(thread,session)
  $|    SELECT m.thread,m.session FROM \{table} x
  $|      CROSS JOIN thread_sessions m ON m.thread=x.thread AND m.session=x.session
  $|    WHERE NOT EXISTS (SELECT 1 FROM latest_thread_members r WHERE r.thread=m.thread AND r.session=m.session);
  $|  INSERT INTO latest_thread_rows(session,has_last,last_delivery,joined_at,member_rowid,thread)
  $|    SELECT m.session,d.rowid IS NOT NULL,COALESCE(d.rowid,0),m.joined_at,m.rowid,m.thread
  $|    FROM \{table} x CROSS JOIN thread_sessions m ON m.session=x.session AND m.thread=x.thread
  $|      CROSS JOIN threads t ON t.id=m.thread
  $|      LEFT JOIN deliveries d ON d.rowid=\{lt_last_delivery("m.session", "m.thread", "")}
  $|    WHERE NOT EXISTS (SELECT 1 FROM latest_thread_rows r WHERE r.session=m.session AND r.has_last=(d.rowid IS NOT NULL)
  $|      AND r.last_delivery=COALESCE(d.rowid,0) AND r.joined_at IS m.joined_at AND r.member_rowid=m.rowid);
  $|  \{refresh}
  $|  DELETE FROM \{table};
)
}

///|
fn lt_delivery_keys(update : Bool) -> String {
  let union_old = if update { "UNION SELECT OLD.session,OLD.thread" } else { "" }
(
  $|SELECT NEW.session AS session,NEW.thread AS thread
  $|  UNION SELECT d.session,d.thread FROM deliveries d WHERE d.rowid=NEW.rowid
  $|  UNION SELECT d.session,d.thread FROM deliveries d WHERE d.thread=NEW.thread AND d.n=NEW.n AND d.session=NEW.session
  $|  \{union_old}
)
}

///|
fn lt_member_keys(update : Bool) -> String {
  let union_old = if update { "UNION SELECT OLD.session,OLD.thread" } else { "" }
(
  $|SELECT NEW.session AS session,NEW.thread AS thread
  $|  UNION SELECT m.session,m.thread FROM thread_sessions m WHERE m.rowid=NEW.rowid
  $|  UNION SELECT m.session,m.thread FROM thread_sessions m WHERE m.thread=NEW.thread AND m.session=NEW.session
  $|  \{union_old}
)
}

///|
fn lt_thread_keys(ids : String) -> String {
(
  $|SELECT m.session,m.thread FROM latest_thread_members m WHERE m.thread IN (\{ids})
)
}

///|
let lt_displaced_thread : String =
(
  $|(SELECT id FROM threads WHERE surface=NEW.surface AND channel=NEW.channel AND thread_ts=NEW.thread_ts)
)

///|
let lt_delivery_conflict : String =
(
  $|EXISTS (SELECT 1 FROM deliveries WHERE rowid=NEW.rowid)
  $|  OR EXISTS (SELECT 1 FROM deliveries WHERE thread=NEW.thread AND n=NEW.n AND session=NEW.session)
)

///|
let lt_member_conflict : String =
(
  $|EXISTS (SELECT 1 FROM thread_sessions WHERE rowid=NEW.rowid)
  $|  OR EXISTS (SELECT 1 FROM thread_sessions WHERE thread=NEW.thread AND session=NEW.session)
)

///|
let lt_delivery_changed : String = "OLD.rowid IS NOT NEW.rowid OR OLD.thread IS NOT NEW.thread OR OLD.n IS NOT NEW.n OR OLD.session IS NOT NEW.session"

///|
let lt_member_changed : String = "OLD.rowid IS NOT NEW.rowid OR OLD.thread IS NOT NEW.thread OR OLD.session IS NOT NEW.session OR OLD.joined_at IS NOT NEW.joined_at"

///|
let lt_thread_changed : String = "OLD.id IS NOT NEW.id OR OLD.surface IS NOT NEW.surface OR OLD.channel IS NOT NEW.channel OR OLD.thread_ts IS NOT NEW.thread_ts"

///|
let lt_fast_delivery : String =
(
  $|INSERT INTO latest_thread_members(thread,session)
  $|    SELECT m.thread,m.session FROM thread_sessions m WHERE m.session=NEW.session AND m.thread=NEW.thread
  $|      AND NOT EXISTS (SELECT 1 FROM latest_thread_members r WHERE r.thread=m.thread AND r.session=m.session);
  $|  DELETE FROM latest_thread_rows WHERE session=NEW.session AND thread=NEW.thread
  $|    AND has_last=(\{lt_prior_delivery} IS NOT NULL) AND last_delivery=COALESCE(\{lt_prior_delivery},0)
  $|    AND joined_at IS (SELECT joined_at FROM thread_sessions WHERE session=NEW.session AND thread=NEW.thread)
  $|    AND member_rowid=(SELECT rowid FROM thread_sessions WHERE session=NEW.session AND thread=NEW.thread);
  $|  INSERT INTO latest_thread_rows(session,has_last,last_delivery,joined_at,member_rowid,thread)
  $|    SELECT m.session,1,NEW.rowid,m.joined_at,m.rowid,m.thread FROM thread_sessions m
  $|    WHERE m.session=NEW.session AND m.thread=NEW.thread AND NOT EXISTS
  $|      (SELECT 1 FROM latest_thread_rows r WHERE r.session=m.session AND r.has_last=1 AND r.last_delivery=NEW.rowid
  $|        AND r.joined_at IS m.joined_at AND r.member_rowid=m.rowid);
)

///|
let lt_fast_member : String =
(
  $|INSERT INTO latest_thread_members(thread,session)
  $|    SELECT m.thread,m.session FROM thread_sessions m WHERE m.session=NEW.session AND m.thread=NEW.thread
  $|      AND EXISTS (SELECT 1 FROM latest_thread_scopes s WHERE s.session=m.session)
  $|      AND NOT EXISTS (SELECT 1 FROM latest_thread_members r WHERE r.thread=m.thread AND r.session=m.session);
  $|  INSERT INTO latest_thread_rows(session,has_last,last_delivery,joined_at,member_rowid,thread)
  $|    SELECT m.session,d.rowid IS NOT NULL,COALESCE(d.rowid,0),m.joined_at,m.rowid,m.thread
  $|    FROM thread_sessions m CROSS JOIN threads t ON t.id=m.thread
  $|      LEFT JOIN deliveries d ON d.rowid=\{lt_last_delivery("m.session", "m.thread", "")}
  $|    WHERE m.session=NEW.session AND m.thread=NEW.thread AND EXISTS
  $|      (SELECT 1 FROM latest_thread_scopes s WHERE s.session=m.session) AND NOT EXISTS
  $|      (SELECT 1 FROM latest_thread_rows r WHERE r.session=m.session AND r.has_last=(d.rowid IS NOT NULL)
  $|        AND r.last_delivery=COALESCE(d.rowid,0) AND r.joined_at IS m.joined_at AND r.member_rowid=m.rowid);
)

///|
fn check_latest_thread_index(db : @sql.Db) -> Unit raise {
  let row = first_row(db, "SELECT version FROM latest_thread_meta WHERE id=1")
  if !is_num(row, "version", lt_version) {
    refuse("latest thread index version \{shown(row, "version", "missing")} is incompatible with \{lt_version}")
  }
}

///|
/// The thread a requested session heard from last (`installLatestThreadIndex`).
fn install_latest_thread_index(db : @sql.Db) -> Unit raise {
  let installed = () => exists(db, "table", "latest_thread_meta")
  if installed() {
    check_latest_thread_index(db)
    return
  }
  immediate(db, () => if !installed() {
    db.exec(
(
  $|CREATE TABLE latest_thread_meta(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL) WITHOUT ROWID;
  $|      INSERT INTO latest_thread_meta VALUES(1,\{lt_version});
  $|      CREATE TABLE latest_thread_scopes(session TEXT PRIMARY KEY,scan_after INTEGER,scan_end INTEGER,
  $|        complete INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID;
  $|      CREATE TABLE latest_thread_rows(session TEXT NOT NULL,has_last INTEGER NOT NULL,last_delivery INTEGER NOT NULL,
  $|        joined_at NOT NULL,member_rowid INTEGER NOT NULL,thread INTEGER NOT NULL,
  $|        PRIMARY KEY(session,has_last DESC,last_delivery DESC,joined_at DESC,member_rowid DESC)) WITHOUT ROWID;
  $|      -- Only tracked memberships, including those whose thread is temporarily missing. This bounds thread changes
  $|      -- by the requested sessions without adding another index to every delivery.
  $|      CREATE TABLE latest_thread_members(thread INTEGER NOT NULL,session TEXT NOT NULL,
  $|        PRIMARY KEY(thread,session)) WITHOUT ROWID;
  $|      CREATE TABLE latest_thread_changed(session TEXT NOT NULL,thread INTEGER NOT NULL,old_valid INTEGER NOT NULL,
  $|        old_has INTEGER NOT NULL,old_last INTEGER NOT NULL,old_joined,old_member INTEGER,
  $|        PRIMARY KEY(session,thread)) WITHOUT ROWID;
  $|      CREATE TABLE latest_thread_updating(session TEXT NOT NULL,thread INTEGER NOT NULL,old_valid INTEGER NOT NULL,
  $|        old_has INTEGER NOT NULL,old_last INTEGER NOT NULL,old_joined,old_member INTEGER,
  $|        PRIMARY KEY(session,thread)) WITHOUT ROWID;
  $|      -- A conflicting thread insert or update may be ignored. Remember at most its old thread ids until it really
  $|      -- changes; only then examine the tracked members. Memberships and deliveries survive a thread replacement,
  $|      -- so their current order also identifies the rows that were present before it.
  $|      CREATE TABLE latest_thread_change_ids(op INTEGER NOT NULL,id INTEGER NOT NULL,PRIMARY KEY(op,id)) WITHOUT ROWID;
  $|
  $|      CREATE TRIGGER latest_delivery_before_add BEFORE INSERT ON deliveries
  $|        WHEN \{lt_changed} OR \{lt_delivery_conflict} BEGIN \{lt_stage(lt_delivery_keys(false))} END;
  $|      CREATE TRIGGER latest_delivery_add AFTER INSERT ON deliveries WHEN \{lt_changed} BEGIN \{lt_reconcile()} END;
  $|      CREATE TRIGGER latest_delivery_fast_add AFTER INSERT ON deliveries
  $|        WHEN EXISTS (SELECT 1 FROM latest_thread_scopes WHERE session=NEW.session)
  $|          AND EXISTS (SELECT 1 FROM thread_sessions m JOIN threads t ON t.id=m.thread
  $|            WHERE m.session=NEW.session AND m.thread=NEW.thread)
  $|          AND (\{lt_prior_delivery} IS NULL OR NEW.rowid>\{lt_prior_delivery}) BEGIN \{lt_fast_delivery} END;
  $|      CREATE TRIGGER latest_delivery_before_change BEFORE UPDATE OF rowid,_rowid_,oid,thread,n,session ON deliveries
  $|        WHEN \{lt_delivery_changed}
  $|        BEGIN \{lt_stage(lt_delivery_keys(true), table="latest_thread_updating")} END;
  $|      CREATE TRIGGER latest_delivery_change AFTER UPDATE OF rowid,_rowid_,oid,thread,n,session ON deliveries
  $|        WHEN (\{lt_delivery_changed}) AND \{lt_updating} BEGIN \{lt_reconcile(table="latest_thread_updating")} END;
  $|      -- A session deletion removes its memberships before its deliveries. Once a membership is gone, its old
  $|      -- deliveries cannot affect the prepared order; do not stage each one as the session is cleared.
  $|      CREATE TRIGGER latest_delivery_before_drop BEFORE DELETE ON deliveries
  $|        WHEN \{lt_changed} OR EXISTS (SELECT 1 FROM thread_sessions m JOIN latest_thread_scopes s ON s.session=m.session
  $|          WHERE m.thread=OLD.thread AND m.session=OLD.session)
  $|        BEGIN \{lt_stage("SELECT OLD.session AS session,OLD.thread AS thread")} END;
  $|      CREATE TRIGGER latest_delivery_drop AFTER DELETE ON deliveries WHEN \{lt_changed} BEGIN \{lt_reconcile()} END;
  $|
  $|      CREATE TRIGGER latest_member_before_add BEFORE INSERT ON thread_sessions
  $|        WHEN \{lt_changed} OR \{lt_member_conflict} BEGIN \{lt_stage(lt_member_keys(false))} END;
  $|      CREATE TRIGGER latest_member_add AFTER INSERT ON thread_sessions WHEN \{lt_changed} BEGIN \{lt_reconcile()} END;
  $|      CREATE TRIGGER latest_member_fast_add AFTER INSERT ON thread_sessions BEGIN \{lt_fast_member} END;
  $|      CREATE TRIGGER latest_member_before_change BEFORE UPDATE OF rowid,_rowid_,oid,thread,session,joined_at ON thread_sessions
  $|        WHEN \{lt_member_changed}
  $|        BEGIN \{lt_stage(lt_member_keys(true), table="latest_thread_updating")} END;
  $|      CREATE TRIGGER latest_member_change AFTER UPDATE OF rowid,_rowid_,oid,thread,session,joined_at ON thread_sessions
  $|        WHEN (\{lt_member_changed}) AND \{lt_updating} BEGIN \{lt_reconcile(table="latest_thread_updating")} END;
  $|      CREATE TRIGGER latest_member_before_drop BEFORE DELETE ON thread_sessions
  $|        BEGIN \{lt_stage("SELECT OLD.session AS session,OLD.thread AS thread")} END;
  $|      CREATE TRIGGER latest_member_drop AFTER DELETE ON thread_sessions WHEN \{lt_changed} BEGIN \{lt_reconcile()} END;
  $|
  $|      CREATE TRIGGER latest_thread_before_add BEFORE INSERT ON threads
  $|        BEGIN
  $|          DELETE FROM latest_thread_change_ids WHERE op=0;
  $|          INSERT OR IGNORE INTO latest_thread_change_ids SELECT 0,\{lt_displaced_thread} WHERE \{lt_displaced_thread} IS NOT NULL;
  $|        END;
  $|      CREATE TRIGGER latest_thread_add AFTER INSERT ON threads BEGIN
  $|        \{lt_stage(lt_thread_keys("SELECT id FROM latest_thread_change_ids WHERE op=0 UNION SELECT NEW.id"), table="latest_thread_changed", missing_thread=true)}
  $|        DELETE FROM latest_thread_change_ids WHERE op=0;
  $|        \{lt_reconcile()}
  $|      END;
  $|      CREATE TRIGGER latest_thread_before_change BEFORE UPDATE OF id,surface,channel,thread_ts ON threads
  $|        WHEN \{lt_thread_changed}
  $|        BEGIN
  $|          DELETE FROM latest_thread_change_ids WHERE op=1;
  $|          INSERT OR IGNORE INTO latest_thread_change_ids SELECT 1,OLD.id UNION SELECT 1,NEW.id
  $|            UNION SELECT 1,\{lt_displaced_thread} WHERE \{lt_displaced_thread} IS NOT NULL;
  $|        END;
  $|      CREATE TRIGGER latest_thread_change AFTER UPDATE OF id,surface,channel,thread_ts ON threads
  $|        WHEN \{lt_thread_changed} BEGIN
  $|          \{lt_stage(lt_thread_keys("SELECT id FROM latest_thread_change_ids WHERE op=1"), table="latest_thread_changed", missing_thread=true)}
  $|          DELETE FROM latest_thread_change_ids WHERE op=1;
  $|          \{lt_reconcile()}
  $|        END;
  $|      CREATE TRIGGER latest_thread_before_drop BEFORE DELETE ON threads
  $|        BEGIN \{lt_stage(lt_thread_keys("OLD.id"))} END;
  $|      CREATE TRIGGER latest_thread_drop AFTER DELETE ON threads WHEN \{lt_changed} BEGIN \{lt_reconcile()} END;
  $|      CREATE TRIGGER latest_thread_session_drop AFTER DELETE ON sessions BEGIN
  $|        DELETE FROM latest_thread_members WHERE (thread,session) IN
  $|          (SELECT thread,session FROM thread_sessions INDEXED BY thread_sessions_session WHERE session=OLD.key);
  $|        DELETE FROM latest_thread_rows WHERE session=OLD.key;
  $|        DELETE FROM latest_thread_changed WHERE session=OLD.key;
  $|        DELETE FROM latest_thread_updating WHERE session=OLD.key;
  $|        DELETE FROM latest_thread_scopes WHERE session=OLD.key;
  $|      END;
)
    )
  } else {
    check_latest_thread_index(db)
  })
}

///|
let cp_version : Int = 1

///|
let cp_candidate : String = "NEW.kind='message' AND (NEW.card IS NOT NULL OR NEW.options IS NOT NULL)"

///|
let cp_conflicts : String =
(
  $|SELECT e.thread,e.n FROM entries e WHERE e.thread=NEW.thread AND e.n=NEW.n
  $|  UNION SELECT e.thread,e.n FROM entries e WHERE NEW.ts IS NOT NULL AND e.thread=NEW.thread AND e.ts=NEW.ts
  $|  UNION SELECT e.thread,e.n FROM entries e WHERE e.rowid=NEW.rowid
)

///|
let cp_displaced : String =
(
  $|EXISTS (SELECT 1 FROM card_posts p WHERE p.thread=NEW.thread AND p.n=NEW.n)
  $|  OR EXISTS (SELECT 1 FROM entries e JOIN card_posts p ON p.thread=e.thread AND p.n=e.n WHERE e.rowid=NEW.rowid)
  $|  OR (NEW.ts IS NOT NULL AND EXISTS (SELECT 1 FROM entries e JOIN card_posts p ON p.thread=e.thread AND p.n=e.n
  $|    WHERE e.thread=NEW.thread AND e.ts=NEW.ts))
)

///|
let cp_needs_insert : String =
(
  $|(\{cp_displaced}) OR EXISTS (SELECT 1 FROM card_post_changed)
)

///|
let cp_needs_update : String =
(
  $|(\{cp_needs_insert}) OR (\{cp_candidate} AND EXISTS (SELECT 1 FROM card_post_scopes WHERE thread=NEW.thread))
  $|  OR EXISTS (SELECT 1 FROM card_posts WHERE thread=OLD.thread AND n=OLD.n)
)

///|
fn cp_stage(update : Bool) -> String {
  let union_old = if update { "UNION SELECT OLD.thread,OLD.n" } else { "" }
(
  $|DELETE FROM card_post_changed;
  $|  INSERT INTO card_post_changed(thread,n)
  $|  SELECT k.thread,k.n FROM (SELECT NEW.thread AS thread,NEW.n AS n UNION \{cp_conflicts}
  $|    \{union_old}) k
  $|  WHERE EXISTS (SELECT 1 FROM card_post_scopes s WHERE s.thread=k.thread);
)
}

///|
let cp_card_post_add_changed : String =
(
  $|INSERT INTO card_posts(thread,n)
  $|  SELECT e.thread,e.n FROM card_post_changed c CROSS JOIN entries e ON e.thread=c.thread AND e.n=c.n
  $|  WHERE e.kind='message' AND (e.card IS NOT NULL OR e.options IS NOT NULL)
)

///|
let cp_reconcile : String =
(
  $|DELETE FROM card_posts WHERE (thread,n) IN (SELECT thread,n FROM card_post_changed);
  $|  \{cp_card_post_add_changed}; DELETE FROM card_post_changed;
)

///|
fn check_card_posts(db : @sql.Db) -> Unit raise {
  let meta = first_row(db, "SELECT version FROM card_post_meta WHERE id=1")
  if meta is None || !is_num(meta, "version", cp_version) {
    refuse("card post index version \{shown(meta, "version", "missing")} is incompatible with \{cp_version}")
  }
}

///|
/// Card posts of requested threads, kept by their writers (`installCardPosts`).
fn install_card_posts(db : @sql.Db) -> Unit raise {
  let installed = () => exists(db, "table", "card_post_meta")
  if installed() {
    check_card_posts(db)
    return
  }
  immediate(db, () => if !installed() {
    db.exec(
(
  $|
  $|      CREATE TABLE card_post_meta (id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL) WITHOUT ROWID;
  $|      INSERT INTO card_post_meta VALUES(1,\{cp_version});
  $|      CREATE TABLE card_post_scopes (thread INTEGER PRIMARY KEY, last_n INTEGER, end_n INTEGER, phase INTEGER NOT NULL) WITHOUT ROWID;
  $|      CREATE TABLE card_posts (thread INTEGER NOT NULL,n INTEGER NOT NULL,PRIMARY KEY(thread,n)) WITHOUT ROWID;
  $|      CREATE TABLE card_post_changed (thread INTEGER NOT NULL,n INTEGER NOT NULL,PRIMARY KEY(thread,n)) WITHOUT ROWID;
  $|      CREATE TRIGGER card_post_new_thread AFTER INSERT ON threads
  $|      WHEN NOT EXISTS (SELECT 1 FROM entries WHERE thread=NEW.id LIMIT 1) BEGIN
  $|        INSERT INTO card_post_scopes(thread,last_n,end_n,phase) VALUES(NEW.id,NULL,NULL,2)
  $|        ON CONFLICT(thread) DO NOTHING;
  $|      END;
  $|      CREATE TRIGGER card_post_before_insert BEFORE INSERT ON entries WHEN \{cp_needs_insert} BEGIN \{cp_stage(false)} END;
  $|      CREATE TRIGGER card_post_insert AFTER INSERT ON entries WHEN EXISTS (SELECT 1 FROM card_post_changed) BEGIN \{cp_reconcile} END;
  $|      -- A new post with no displaced indexed row needs no staging. If the reconciliation trigger ran first, it may
  $|      -- already have inserted this post; the existence check keeps either trigger order correct.
  $|      CREATE TRIGGER card_post_fast_insert AFTER INSERT ON entries WHEN \{cp_candidate}
  $|        AND EXISTS (SELECT 1 FROM card_post_scopes WHERE thread=NEW.thread)
  $|        AND NOT EXISTS (SELECT 1 FROM card_post_changed) BEGIN
  $|        INSERT INTO card_posts(thread,n) SELECT NEW.thread,NEW.n
  $|          WHERE NOT EXISTS (SELECT 1 FROM card_posts WHERE thread=NEW.thread AND n=NEW.n);
  $|      END;
  $|      CREATE TRIGGER card_post_before_update BEFORE UPDATE OF rowid,_rowid_,oid,thread,n,kind,ts,card,options ON entries
  $|      WHEN \{cp_needs_update} BEGIN \{cp_stage(true)} END;
  $|      CREATE TRIGGER card_post_update AFTER UPDATE OF rowid,_rowid_,oid,thread,n,kind,ts,card,options ON entries
  $|      WHEN EXISTS (SELECT 1 FROM card_post_changed) BEGIN \{cp_reconcile} END;
  $|      CREATE TRIGGER card_post_delete AFTER DELETE ON entries
  $|      WHEN OLD.kind='message' AND (OLD.card IS NOT NULL OR OLD.options IS NOT NULL) BEGIN
  $|        DELETE FROM card_posts WHERE thread=OLD.thread AND n=OLD.n;
  $|      END;
  $|      CREATE TRIGGER card_post_drop_thread AFTER DELETE ON threads
  $|      WHEN NOT EXISTS (SELECT 1 FROM entries WHERE thread=OLD.id) BEGIN
  $|        DELETE FROM card_post_scopes WHERE thread=OLD.id;
  $|      END;
  $|    
)
    )
  } else {
    check_card_posts(db)
  })
}

///|
/// The card outcomes' queue's table, under `name` (card-outbox.ts `outboxTable`).
fn outbox_table(name : String) -> String {
(
  $|CREATE TABLE IF NOT EXISTS \{name}(thread INTEGER NOT NULL,ts TEXT NOT NULL,id INTEGER NOT NULL,
  $|        agent TEXT NOT NULL,field TEXT NOT NULL CHECK(field IN ('adb','rig','signin','vault')),
  $|        close_card INTEGER NOT NULL CHECK(close_card IN (0,1)),outcome TEXT NOT NULL,
  $|        PRIMARY KEY(thread,ts,id)) WITHOUT ROWID
)
}

///|
/// A queue made before a rig's card had an outcome made again with one more field, what waits in it kept
/// (`takeRigOutcomes`); a caller's savepoint holds it.
pub fn take_rig_outcomes(db : @sql.Db) -> Unit raise {
  guard sql_of(db, "table", "card_outbox") is Some(sql) else { return }
  if sql.contains("'rig'") {
    return
  }
  db.exec(
(
  $|\{outbox_table("card_outbox_wider")};
  $|    INSERT INTO card_outbox_wider SELECT thread,ts,id,agent,field,close_card,outcome FROM card_outbox;
  $|    DROP TABLE card_outbox;
  $|    ALTER TABLE card_outbox_wider RENAME TO card_outbox;
)
  )
}

///|
/// Whether the queue is there, of this version (`hasCardOutbox`).
pub fn has_card_outbox(db : @sql.Db) -> Bool raise {
  if !exists(db, "table", "card_outbox_meta") {
    return false
  }
  if !is_num(first_row(db, "SELECT version FROM card_outbox_meta WHERE id=1"), "version", 1) {
    refuse("card outcome outbox has an unsupported version")
  }
  if !is_num(
      first_row(db, "SELECT COUNT(*) AS n FROM sqlite_master WHERE type='table' AND name IN ('card_outbox','card_outbox_head')"),
      "n",
      2,
    ) {
    refuse("card outcome outbox tables are missing")
  }
  true
}

///|
/// The card outcomes' queue: constant-size metadata only (`installCardOutbox`).
pub fn install_card_outbox(db : @sql.Db) -> Unit raise {
  if has_card_outbox(db) {
    return
  }
  db.exec("SAVEPOINT card_outbox_install")
  errdefer (db.exec("ROLLBACK TO card_outbox_install; RELEASE card_outbox_install") catch { _ => () })
  if has_card_outbox(db) {
    db.exec("RELEASE card_outbox_install")
    return
  }
  db.exec(
(
  $|CREATE TABLE IF NOT EXISTS card_outbox_meta(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL,
  $|        next_id INTEGER NOT NULL) WITHOUT ROWID;
  $|      INSERT OR IGNORE INTO card_outbox_meta VALUES(1,1,0);
)
  )
  if !is_num(first_row(db, "SELECT version FROM card_outbox_meta WHERE id=1"), "version", 1) {
    refuse("card outcome outbox has an unsupported version")
  }
  db.exec(
(
  $|\{outbox_table("card_outbox")};
  $|      CREATE TABLE IF NOT EXISTS card_outbox_head(id INTEGER PRIMARY KEY,thread INTEGER NOT NULL,ts TEXT NOT NULL);
)
  )
  db.exec("RELEASE card_outbox_install")
  ignore(has_card_outbox(db))
}

///|
fn ch_place(row : String) -> String {
(
  $|CASE WHEN instr(\{row}.surface, ':') = 0 THEN \{row}.surface
  $|  ELSE substr(\{row}.surface, 1, instr(\{row}.surface, ':') - 1) END
)
}

///|
fn ch_ensure(thread : String) -> String {
(
  $|INSERT INTO usage_chat_stats
  $|  SELECT \{thread}, CASE WHEN t.id IS NULL THEN '' ELSE \{ch_place("t")} END, t.id IS NOT NULL,
  $|    t.id IS NOT NULL AND t.hidden_at IS NOT NULL, 0, 0
  $|  FROM (SELECT 1) LEFT JOIN threads t ON t.id = \{thread}
  $|  WHERE NOT EXISTS (SELECT 1 FROM usage_chat_stats WHERE thread = \{thread});
)
}

///|
fn ch_refresh(thread : String, when? : String = "1") -> String {
(
  $|
  $|  DELETE FROM usage_chat_scopes WHERE thread = \{thread} AND (\{when});
  $|  INSERT OR IGNORE INTO usage_chat_scopes SELECT thread, 0, '' FROM usage_chat_stats WHERE thread = \{thread} AND (\{when});
  $|  INSERT OR IGNORE INTO usage_chat_scopes SELECT thread, 1, '' FROM usage_chat_stats s WHERE s.thread = \{thread} AND s.live = 1 AND (\{when})
  $|    AND (NOT EXISTS (SELECT 1 FROM usage_chat_members m WHERE m.thread = s.thread)
  $|      OR EXISTS (SELECT 1 FROM usage_chat_members m WHERE m.thread = s.thread AND m.present = 1 AND m.ws IS NULL));
  $|  INSERT OR IGNORE INTO usage_chat_scopes SELECT m.thread, 2, m.ws FROM usage_chat_members m
  $|    WHERE m.thread = \{thread} AND m.present = 1 AND m.ws IS NOT NULL AND (\{when})
  $|      AND EXISTS (SELECT 1 FROM usage_chat_stats s WHERE s.thread = m.thread AND s.live = 1) GROUP BY m.thread, m.ws;
  $|  INSERT OR IGNORE INTO usage_chat_scopes SELECT m.thread, 3, m.ws FROM usage_chat_members m
  $|    WHERE m.thread = \{thread} AND m.present = 1 AND m.ws IS NOT NULL AND (\{when})
  $|      AND EXISTS (SELECT 1 FROM usage_chat_scopes s WHERE s.thread = m.thread AND s.kind = 1 AND s.ws = '') GROUP BY m.thread, m.ws;
)
}

///|
fn ch_is_home(thread : String) -> String {
(
  $|EXISTS (SELECT 1 FROM usage_chat_stats s WHERE s.thread = \{thread} AND s.live = 1)
  $|  AND (NOT EXISTS (SELECT 1 FROM usage_chat_members m WHERE m.thread = \{thread}) OR EXISTS
  $|    (SELECT 1 FROM usage_chat_members m WHERE m.thread = \{thread} AND m.present = 1 AND m.ws IS NULL))
)
}

///|
fn ch_home_scope(thread : String) -> String {
(
  $|EXISTS (SELECT 1 FROM usage_chat_scopes WHERE thread = \{thread} AND kind = 1 AND ws = '')
)
}

///|
fn ch_refresh_home(thread : String) -> String {
(
  $|
  $|  DELETE FROM usage_chat_scopes WHERE thread = \{thread} AND kind = 3
  $|    AND \{ch_home_scope(thread)} AND NOT (\{ch_is_home(thread)});
  $|  DELETE FROM usage_chat_scopes WHERE thread = \{thread} AND kind = 1 AND ws = '' AND NOT (\{ch_is_home(thread)});
  $|  INSERT OR IGNORE INTO usage_chat_scopes SELECT thread, 3, ws FROM usage_chat_scopes
  $|    WHERE thread = \{thread} AND kind = 2 AND (\{ch_is_home(thread)}) AND NOT (\{ch_home_scope(thread)});
  $|  INSERT OR IGNORE INTO usage_chat_scopes SELECT thread, 1, '' FROM usage_chat_stats
  $|    WHERE thread = \{thread} AND (\{ch_is_home(thread)});
)
}

///|
fn ch_add_member_scope(row : String) -> String {
(
  $|
  $|  INSERT INTO usage_chat_scopes SELECT s.thread, 2, \{row}.ws FROM usage_chat_stats s
  $|    WHERE s.thread = \{row}.thread AND s.live = 1 AND \{row}.present = 1 AND \{row}.ws IS NOT NULL
  $|      AND NOT EXISTS (SELECT 1 FROM usage_chat_scopes x WHERE x.thread = s.thread AND x.kind = 2 AND x.ws = \{row}.ws);
  $|  INSERT INTO usage_chat_scopes SELECT s.thread, 3, \{row}.ws FROM usage_chat_stats s
  $|    WHERE s.thread = \{row}.thread AND s.live = 1 AND \{row}.present = 1 AND \{row}.ws IS NOT NULL
  $|      AND \{ch_home_scope(row + ".thread")}
  $|      AND NOT EXISTS (SELECT 1 FROM usage_chat_scopes x WHERE x.thread = s.thread AND x.kind = 3 AND x.ws = \{row}.ws);
)
}

///|
fn ch_remove_member_scope(row : String) -> String {
(
  $|
  $|  DELETE FROM usage_chat_scopes WHERE thread = \{row}.thread AND kind IN (2, 3) AND ws = \{row}.ws
  $|    AND \{row}.present = 1 AND \{row}.ws IS NOT NULL AND NOT EXISTS
  $|      (SELECT 1 FROM usage_chat_members m WHERE m.thread = \{row}.thread AND m.present = 1 AND m.ws = \{row}.ws);
)
}

///|
fn ch_keep_member(row : String) -> String {
(
  $|
  $|  \{ch_ensure(row + ".thread")}
  $|  INSERT INTO usage_chat_members VALUES (\{row}.thread, \{row}.session,
  $|    (SELECT ws FROM sessions WHERE key = \{row}.session), EXISTS (SELECT 1 FROM sessions WHERE key = \{row}.session))
  $|  ON CONFLICT (thread, session) DO UPDATE SET ws = excluded.ws, present = excluded.present;
)
}

///|
fn ch_picked(row : String) -> String {
(
  $|(\{row}.said != 0 OR EXISTS (SELECT 1 FROM closed_cards x
  $|  WHERE x.thread = \{row}.thread AND x.n = \{row}.n AND x.viewer != \{row}.author))
)
}

///|
fn ch_keep_card(row : String) -> String {
(
  $|
  $|  \{ch_ensure(row + ".thread")}
  $|  INSERT INTO usage_chat_cards VALUES (\{row}.thread, \{row}.n, \{ch_picked(row)})
  $|  ON CONFLICT (thread, n) DO UPDATE SET picked = excluded.picked;
)
}

///|
fn ch_recheck_card(row : String) -> String {
(
  $|UPDATE usage_chat_cards SET picked = COALESCE((
  $|  SELECT \{ch_picked("c")} FROM card_outcomes c WHERE c.thread = \{row}.thread AND c.n = \{row}.n), 0)
  $|  WHERE thread = \{row}.thread AND n = \{row}.n;
)
}

///|
fn ch_dirty_session(session : String, workspace : String, when? : String = "1") -> String {
(
  $|
  $|  INSERT INTO usage_chat_dirty SELECT \{session}, NULL
  $|    WHERE (\{when}) AND EXISTS (SELECT 1 FROM usage_chat_members WHERE session = \{session})
  $|  ON CONFLICT (session) DO UPDATE SET thread_after = NULL;
  $|  INSERT OR IGNORE INTO usage_chat_dirty_scope
  $|    SELECT \{session}, CASE WHEN \{workspace} IS NULL THEN 1 ELSE 2 END, COALESCE(\{workspace}, '')
  $|    WHERE (\{when}) AND EXISTS (SELECT 1 FROM usage_chat_dirty WHERE session = \{session});
)
}

///|
fn ch_dirty_previous(session : String) -> String {
(
  $|INSERT OR IGNORE INTO usage_chat_dirty_scope
  $|  SELECT \{session}, CASE WHEN ws IS NULL THEN 1 ELSE 2 END, COALESCE(ws, '')
  $|  FROM usage_chat_members INDEXED BY usage_chat_members_session_present
  $|  WHERE session = \{session} AND present = 1 ORDER BY thread LIMIT 1;
)
}

///|
let usage_chat_schema : String =
(
  $|
  $|CREATE TABLE usage_chat_stats (thread INTEGER PRIMARY KEY, place TEXT NOT NULL, live INTEGER NOT NULL,
  $|  archived INTEGER NOT NULL, cards INTEGER NOT NULL, picked INTEGER NOT NULL);
  $|CREATE TABLE usage_chat_members (thread INTEGER NOT NULL, session TEXT NOT NULL, ws TEXT, present INTEGER NOT NULL,
  $|  PRIMARY KEY (thread, session)) WITHOUT ROWID;
  $|CREATE INDEX usage_chat_members_session ON usage_chat_members (session, thread);
  $|CREATE INDEX usage_chat_members_session_present ON usage_chat_members (session, present, thread);
  $|CREATE INDEX usage_chat_members_workspace ON usage_chat_members (thread, present, ws);
  $|CREATE TABLE usage_chat_cards (thread INTEGER NOT NULL, n INTEGER NOT NULL, picked INTEGER NOT NULL,
  $|  PRIMARY KEY (thread, n)) WITHOUT ROWID;
  $|CREATE TABLE usage_chat_dirty (session TEXT PRIMARY KEY, thread_after INTEGER) WITHOUT ROWID;
  $|CREATE TABLE usage_chat_dirty_scope (session TEXT NOT NULL, kind INTEGER NOT NULL, ws TEXT NOT NULL,
  $|  PRIMARY KEY (session, kind, ws)) WITHOUT ROWID;
  $|CREATE INDEX usage_chat_dirty_scope_workspace ON usage_chat_dirty_scope (kind, ws, session);
  $|CREATE TABLE usage_chat_scopes (thread INTEGER NOT NULL, kind INTEGER NOT NULL, ws TEXT NOT NULL,
  $|  PRIMARY KEY (thread, kind, ws)) WITHOUT ROWID;
  $|CREATE TABLE usage_chat_totals (kind INTEGER NOT NULL, ws TEXT NOT NULL, place TEXT NOT NULL,
  $|  chats INTEGER NOT NULL, archived INTEGER NOT NULL, cards INTEGER NOT NULL, picked INTEGER NOT NULL,
  $|  PRIMARY KEY (kind, ws, place)) WITHOUT ROWID;
  $|CREATE TABLE usage_chat_progress (id INTEGER PRIMARY KEY CHECK (id = 1), stage INTEGER NOT NULL,
  $|  thread_after INTEGER, thread_end INTEGER, member_after INTEGER, member_end INTEGER,
  $|  card_thread INTEGER, card_n INTEGER, card_end_thread INTEGER, card_end_n INTEGER, done INTEGER NOT NULL);
  $|INSERT INTO usage_chat_progress
  $|  SELECT 1, 0, NULL, (SELECT MAX(id) FROM threads), NULL, (SELECT MAX(rowid) FROM thread_sessions), NULL, NULL,
  $|    (SELECT thread FROM card_outcomes ORDER BY thread DESC, n DESC LIMIT 1),
  $|    (SELECT n FROM card_outcomes ORDER BY thread DESC, n DESC LIMIT 1),
  $|    NOT EXISTS (SELECT 1 FROM threads LIMIT 1) AND NOT EXISTS (SELECT 1 FROM thread_sessions LIMIT 1)
  $|      AND NOT EXISTS (SELECT 1 FROM card_outcomes LIMIT 1);
  $|
  $|CREATE TRIGGER usage_chat_scope_add AFTER INSERT ON usage_chat_scopes BEGIN
  $|  INSERT INTO usage_chat_totals SELECT NEW.kind, NEW.ws, s.place, s.live, s.live * s.archived, s.cards, s.picked
  $|    FROM usage_chat_stats s WHERE s.thread = NEW.thread
  $|  ON CONFLICT (kind, ws, place) DO UPDATE SET chats = chats + excluded.chats, archived = archived + excluded.archived,
  $|    cards = cards + excluded.cards, picked = picked + excluded.picked;
  $|END;
  $|CREATE TRIGGER usage_chat_scope_drop AFTER DELETE ON usage_chat_scopes BEGIN
  $|  UPDATE usage_chat_totals SET
  $|    chats = chats - (SELECT live FROM usage_chat_stats WHERE thread = OLD.thread),
  $|    archived = archived - (SELECT live * archived FROM usage_chat_stats WHERE thread = OLD.thread),
  $|    cards = cards - (SELECT cards FROM usage_chat_stats WHERE thread = OLD.thread),
  $|    picked = picked - (SELECT picked FROM usage_chat_stats WHERE thread = OLD.thread)
  $|    WHERE kind = OLD.kind AND ws = OLD.ws AND place = (SELECT place FROM usage_chat_stats WHERE thread = OLD.thread);
  $|  DELETE FROM usage_chat_totals WHERE kind = OLD.kind AND ws = OLD.ws
  $|    AND place = (SELECT place FROM usage_chat_stats WHERE thread = OLD.thread)
  $|    AND chats = 0 AND archived = 0 AND cards = 0 AND picked = 0;
  $|END;
  $|CREATE TRIGGER usage_chat_stats_add AFTER INSERT ON usage_chat_stats BEGIN \{ch_refresh("NEW.thread")} END;
  $|CREATE TRIGGER usage_chat_stats_before BEFORE UPDATE ON usage_chat_stats
  $|  WHEN OLD.place IS NOT NEW.place OR OLD.live IS NOT NEW.live OR OLD.archived IS NOT NEW.archived
  $|    OR OLD.cards IS NOT NEW.cards OR OLD.picked IS NOT NEW.picked BEGIN
  $|  UPDATE usage_chat_totals SET chats = chats - OLD.live, archived = archived - OLD.live * OLD.archived,
  $|    cards = cards - OLD.cards, picked = picked - OLD.picked WHERE place = OLD.place AND (kind, ws) IN
  $|      (SELECT kind, ws FROM usage_chat_scopes WHERE thread = OLD.thread);
  $|  DELETE FROM usage_chat_totals WHERE place = OLD.place AND (kind, ws) IN
  $|    (SELECT kind, ws FROM usage_chat_scopes WHERE thread = OLD.thread)
  $|    AND chats = 0 AND archived = 0 AND cards = 0 AND picked = 0;
  $|END;
  $|CREATE TRIGGER usage_chat_stats_after AFTER UPDATE ON usage_chat_stats
  $|  WHEN OLD.place IS NOT NEW.place OR OLD.live IS NOT NEW.live OR OLD.archived IS NOT NEW.archived
  $|    OR OLD.cards IS NOT NEW.cards OR OLD.picked IS NOT NEW.picked BEGIN
  $|  INSERT INTO usage_chat_totals SELECT s.kind, s.ws, NEW.place, NEW.live, NEW.live * NEW.archived, NEW.cards, NEW.picked
  $|    FROM usage_chat_scopes s WHERE s.thread = NEW.thread
  $|  ON CONFLICT (kind, ws, place) DO UPDATE SET chats = chats + excluded.chats, archived = archived + excluded.archived,
  $|    cards = cards + excluded.cards, picked = picked + excluded.picked;
  $|  \{ch_refresh("NEW.thread", when="OLD.live IS NOT NEW.live")}
  $|END;
  $|CREATE TRIGGER usage_chat_stats_drop BEFORE DELETE ON usage_chat_stats BEGIN
  $|  DELETE FROM usage_chat_scopes WHERE thread = OLD.thread;
  $|END;
  $|
  $|CREATE TRIGGER usage_chat_thread_add AFTER INSERT ON threads BEGIN
  $|  INSERT INTO usage_chat_stats VALUES (NEW.id, \{ch_place("NEW")}, 1, NEW.hidden_at IS NOT NULL, 0, 0)
  $|  ON CONFLICT (thread) DO UPDATE SET place = excluded.place, live = 1, archived = excluded.archived;
  $|END;
  $|CREATE TRIGGER usage_chat_thread_change AFTER UPDATE OF surface, hidden_at ON threads BEGIN
  $|  INSERT INTO usage_chat_stats VALUES (NEW.id, \{ch_place("NEW")}, 1, NEW.hidden_at IS NOT NULL, 0, 0)
  $|  ON CONFLICT (thread) DO UPDATE SET place = excluded.place, live = 1, archived = excluded.archived;
  $|END;
  $|CREATE TRIGGER usage_chat_thread_drop AFTER DELETE ON threads BEGIN
  $|  UPDATE usage_chat_stats SET place = '', live = 0, archived = 0 WHERE thread = OLD.id;
  $|  DELETE FROM usage_chat_stats WHERE thread = OLD.id AND cards = 0
  $|    AND NOT EXISTS (SELECT 1 FROM usage_chat_members WHERE thread = OLD.id);
  $|END;
  $|
  $|CREATE TRIGGER usage_chat_member_add AFTER INSERT ON usage_chat_members BEGIN
  $|  \{ch_add_member_scope("NEW")}
  $|END;
  $|CREATE TRIGGER usage_chat_member_change AFTER UPDATE ON usage_chat_members
  $|  WHEN OLD.ws IS NOT NEW.ws OR OLD.present IS NOT NEW.present BEGIN
  $|  \{ch_remove_member_scope("OLD")}
  $|  \{ch_add_member_scope("NEW")}
  $|END;
  $|CREATE TRIGGER usage_chat_member_drop AFTER DELETE ON usage_chat_members BEGIN
  $|  \{ch_remove_member_scope("OLD")}
  $|  DELETE FROM usage_chat_stats WHERE thread = OLD.thread AND live = 0 AND cards = 0
  $|    AND NOT EXISTS (SELECT 1 FROM usage_chat_members WHERE thread = OLD.thread);
  $|END;
  $|CREATE TRIGGER usage_chat_member_home_add AFTER INSERT ON usage_chat_members
  $|  WHEN (\{ch_is_home("NEW.thread")}) != (\{ch_home_scope("NEW.thread")}) BEGIN \{ch_refresh_home("NEW.thread")} END;
  $|CREATE TRIGGER usage_chat_member_home_change AFTER UPDATE ON usage_chat_members
  $|  WHEN (OLD.ws IS NOT NEW.ws OR OLD.present IS NOT NEW.present)
  $|    AND (\{ch_is_home("NEW.thread")}) != (\{ch_home_scope("NEW.thread")}) BEGIN \{ch_refresh_home("NEW.thread")} END;
  $|CREATE TRIGGER usage_chat_member_home_drop AFTER DELETE ON usage_chat_members
  $|  WHEN (\{ch_is_home("OLD.thread")}) != (\{ch_home_scope("OLD.thread")}) BEGIN \{ch_refresh_home("OLD.thread")} END;
  $|CREATE TRIGGER usage_chat_membership_add AFTER INSERT ON thread_sessions BEGIN \{ch_keep_member("NEW")} END;
  $|CREATE TRIGGER usage_chat_membership_change AFTER UPDATE ON thread_sessions BEGIN
  $|  DELETE FROM usage_chat_members WHERE thread = OLD.thread AND session = OLD.session
  $|    AND (OLD.thread IS NOT NEW.thread OR OLD.session IS NOT NEW.session);
  $|  \{ch_keep_member("NEW")}
  $|END;
  $|CREATE TRIGGER usage_chat_membership_drop AFTER DELETE ON thread_sessions BEGIN
  $|  DELETE FROM usage_chat_members WHERE thread = OLD.thread AND session = OLD.session;
  $|END;
  $|-- REPLACE may also evict another session through the unique token, without firing its DELETE trigger.
  $|CREATE TRIGGER usage_chat_session_token_add BEFORE INSERT ON sessions
  $|  WHEN EXISTS (SELECT 1 FROM sessions WHERE token = NEW.token AND key <> NEW.key) BEGIN
  $|  \{ch_dirty_session("(SELECT key FROM sessions WHERE token = NEW.token)", "(SELECT ws FROM sessions WHERE token = NEW.token)")}
  $|END;
  $|CREATE TRIGGER usage_chat_session_token_change BEFORE UPDATE OF token ON sessions
  $|  WHEN OLD.token IS NOT NEW.token AND EXISTS (SELECT 1 FROM sessions WHERE token = NEW.token AND key <> NEW.key) BEGIN
  $|  \{ch_dirty_session("(SELECT key FROM sessions WHERE token = NEW.token)", "(SELECT ws FROM sessions WHERE token = NEW.token)")}
  $|END;
  $|CREATE TRIGGER usage_chat_session_add AFTER INSERT ON sessions BEGIN
  $|  \{ch_dirty_previous("NEW.key")}
  $|  \{ch_dirty_session("NEW.key", "NEW.ws")}
  $|END;
  $|CREATE TRIGGER usage_chat_session_change AFTER UPDATE OF key, ws ON sessions
  $|  WHEN OLD.key IS NOT NEW.key OR OLD.ws IS NOT NEW.ws BEGIN
  $|  \{ch_dirty_session("OLD.key", "OLD.ws")}
  $|  \{ch_dirty_session("NEW.key", "NEW.ws")}
  $|END;
  $|CREATE TRIGGER usage_chat_session_drop AFTER DELETE ON sessions BEGIN
  $|  \{ch_dirty_session("OLD.key", "OLD.ws")}
  $|END;
  $|
  $|CREATE TRIGGER usage_chat_card_add AFTER INSERT ON usage_chat_cards BEGIN
  $|  UPDATE usage_chat_stats SET cards = cards + 1, picked = picked + NEW.picked WHERE thread = NEW.thread;
  $|END;
  $|CREATE TRIGGER usage_chat_card_change AFTER UPDATE OF picked ON usage_chat_cards WHEN OLD.picked IS NOT NEW.picked BEGIN
  $|  UPDATE usage_chat_stats SET picked = picked + NEW.picked - OLD.picked WHERE thread = NEW.thread;
  $|END;
  $|CREATE TRIGGER usage_chat_card_drop AFTER DELETE ON usage_chat_cards BEGIN
  $|  UPDATE usage_chat_stats SET cards = cards - 1, picked = picked - OLD.picked WHERE thread = OLD.thread;
  $|  DELETE FROM usage_chat_stats WHERE thread = OLD.thread AND live = 0 AND cards = 0
  $|    AND NOT EXISTS (SELECT 1 FROM usage_chat_members WHERE thread = OLD.thread);
  $|END;
  $|CREATE TRIGGER usage_chat_outcome_add AFTER INSERT ON card_outcomes BEGIN \{ch_keep_card("NEW")} END;
  $|CREATE TRIGGER usage_chat_outcome_change AFTER UPDATE ON card_outcomes BEGIN
  $|  DELETE FROM usage_chat_cards WHERE thread = OLD.thread AND n = OLD.n AND (OLD.thread IS NOT NEW.thread OR OLD.n IS NOT NEW.n);
  $|  \{ch_keep_card("NEW")}
  $|END;
  $|CREATE TRIGGER usage_chat_outcome_drop AFTER DELETE ON card_outcomes BEGIN
  $|  DELETE FROM usage_chat_cards WHERE thread = OLD.thread AND n = OLD.n;
  $|END;
  $|CREATE TRIGGER usage_chat_closed_add AFTER INSERT ON closed_cards BEGIN \{ch_recheck_card("NEW")} END;
  $|CREATE TRIGGER usage_chat_closed_change AFTER UPDATE ON closed_cards BEGIN \{ch_recheck_card("OLD")} \{ch_recheck_card("NEW")} END;
  $|CREATE TRIGGER usage_chat_closed_drop AFTER DELETE ON closed_cards BEGIN \{ch_recheck_card("OLD")} END;
  $|
)

///|
/// The usage page's chats: only empty statistics and their writers (`installUsageChatStats`).
fn install_usage_chat_stats(db : @sql.Db) -> Unit raise {
  let installed = () => exists(db, "table", "usage_chat_progress")
  if installed() {
    return
  }
  immediate(db, () => if !installed() { db.exec(usage_chat_schema) })
}
