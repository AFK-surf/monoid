// store.ts and the modules it reads by (card-kinds.ts, said-state.ts, the legacy lookups, the indexes' reads, the card
// guards' and the queue's tables): their statements as the TypeScript makes them, text for text, so this package asks
// SQLite exactly what the store asks it.

///|
let thread_insert_if_absent_sql : String =
  #|INSERT OR IGNORE INTO threads (surface, channel, thread_ts, title, created_by, created_at, home)
  #|  SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7 WHERE NOT EXISTS
  #|    (SELECT 1 FROM threads WHERE surface = ?1 AND channel = ?2 AND thread_ts = ?3)

///|
let member_join_if_needed_sql : String =
  #|INSERT INTO thread_sessions (thread, session, connect, joined_at)
  #|  SELECT ?1, ?2, ?3, ?4 WHERE NOT EXISTS
  #|    (SELECT 1 FROM thread_sessions WHERE thread = ?1 AND session = ?2 AND left_at IS NULL)
  #|  ON CONFLICT (thread, session) DO UPDATE SET left_at = NULL WHERE thread_sessions.left_at IS NOT NULL

///|
let session_thread_by_id_sql : String =
  #|SELECT t.*, ts.connect FROM thread_sessions ts JOIN threads t ON t.id = ts.thread
  #|  WHERE ts.thread = ?1 AND ts.session = ?2

///|
let delivery_insert_if_absent_sql : String =
  #|INSERT OR IGNORE INTO deliveries (thread, n, session)
  #|  SELECT ?1, ?2, ?3 WHERE NOT EXISTS
  #|    (SELECT 1 FROM deliveries WHERE thread = ?1 AND n = ?2 AND session = ?3) RETURNING (SELECT n FROM pending_cards WHERE thread = ?1) AS waited

///|
let delivery_insert_if_member_sql : String =
  #|INSERT OR IGNORE INTO deliveries (thread, n, session)
  #|  SELECT ?1, ?2, ?3 WHERE EXISTS
  #|    (SELECT 1 FROM thread_sessions ts JOIN sessions s ON s.key = ts.session
  #|     WHERE ts.thread = ?1 AND ts.session = ?3 AND ts.left_at IS NULL AND (s.archived_by IS NULL OR s.archived_by <> ?4))
  #|  AND EXISTS (SELECT 1 FROM entries WHERE thread = ?1 AND n = ?2 AND kind = 'message')
  #|  AND NOT EXISTS (SELECT 1 FROM deliveries WHERE thread = ?1 AND n = ?2 AND session = ?3) RETURNING (SELECT n FROM pending_cards WHERE thread = ?1) AS waited

///|
let router_workspace_mismatch_sql : String =
  #|SELECT 1 FROM thread_sessions ts LEFT JOIN sessions s ON s.key = ts.session
  #|  WHERE ts.thread = ?1 AND (s.key IS NULL OR COALESCE(s.ws, ?2) IS NOT ?3) LIMIT 1

///|
let recent_joined_threads_sql : String =
  #|SELECT t.*, ts.connect FROM thread_sessions ts INDEXED BY thread_sessions_session
  #|  CROSS JOIN threads t ON t.id = ts.thread WHERE ts.session = ?1 ORDER BY ts.rowid DESC LIMIT ?2

///|
let few_session_threads_sql : String =
  #|SELECT t.*, ts.connect FROM thread_sessions ts JOIN threads t ON t.id = ts.thread
  #|  WHERE ts.session = ?1 ORDER BY ts.joined_at DESC, ts.rowid DESC LIMIT ?2

///|
let session_home_thread_sql : String =
  #|SELECT t.*, ts.connect FROM threads t INDEXED BY threads_home
  #|  CROSS JOIN thread_sessions ts WHERE t.home = ?1 AND ts.thread = t.id AND ts.session = ?1
  #|  ORDER BY ts.joined_at DESC, ts.rowid DESC LIMIT 1

///|
let recent_connect_threads_sql : String =
  #|WITH recent AS MATERIALIZED (
  #|  SELECT t.id, t.surface, t.created_at, COALESCE(e.at, 0) AS said_at
  #|  FROM threads t LEFT JOIN thread_state s ON s.thread = t.id
  #|  LEFT JOIN entries e ON e.thread = t.id AND e.n = s.said_n AND e.kind = 'message'
  #|  ORDER BY said_at DESC, t.created_at DESC, t.id DESC LIMIT ?1
  #|) SELECT r.id, r.surface FROM recent r
  #|  WHERE EXISTS (SELECT 1 FROM thread_sessions m WHERE m.thread = r.id AND m.connect = ?2)
  #|  ORDER BY r.said_at DESC, r.created_at DESC, r.id DESC

///|
let last_known_sql : String =
  #|SELECT MAX(n) AS n FROM (WITH RECURSIVE few(viewer, count) AS (
  #|  SELECT (SELECT viewer FROM reads ORDER BY viewer LIMIT 1), 1
  #|  UNION ALL SELECT (SELECT viewer FROM reads WHERE viewer > v.viewer ORDER BY viewer LIMIT 1), v.count + 1
  #|    FROM few v WHERE v.viewer IS NOT NULL AND v.count < 33
  #|), more(viewer, count) AS (
  #|  SELECT (SELECT viewer FROM reads ORDER BY viewer LIMIT 1), 1
  #|  UNION ALL SELECT (SELECT viewer FROM reads WHERE viewer > v.viewer ORDER BY viewer LIMIT 1), v.count + 1
  #|    FROM more v WHERE v.viewer IS NOT NULL AND v.count < 257
  #|), all_viewers(viewer) AS (
  #|  SELECT (SELECT viewer FROM reads ORDER BY viewer LIMIT 1)
  #|  UNION ALL SELECT (SELECT viewer FROM reads WHERE viewer > v.viewer ORDER BY viewer LIMIT 1)
  #|    FROM all_viewers v WHERE v.viewer IS NOT NULL
  #|), bounds(span) AS (
  #|  SELECT (SELECT MAX(rowid) FROM reads) - (SELECT MIN(rowid) FROM reads)
  #|)
  #|SELECT CASE WHEN (SELECT COUNT(*) FROM few WHERE viewer IS NOT NULL) <= 32
  #|  THEN (SELECT MAX((SELECT n FROM reads WHERE viewer = v.viewer AND thread = ?1)) FROM few v WHERE v.viewer IS NOT NULL)
  #|  WHEN (SELECT span FROM bounds) < 512
  #|  THEN (SELECT MAX(n) FROM reads WHERE thread = ?1)
  #|  WHEN (SELECT COUNT(*) FROM more WHERE viewer IS NOT NULL) <= 256
  #|  THEN (SELECT MAX((SELECT n FROM reads WHERE viewer = v.viewer AND thread = ?1)) FROM more v WHERE v.viewer IS NOT NULL)
  #|  WHEN (SELECT span FROM bounds) < 16384
  #|  THEN (SELECT MAX(n) FROM reads WHERE thread = ?1)
  #|  ELSE (SELECT MAX((SELECT n FROM reads WHERE viewer = v.viewer AND thread = ?1)) FROM all_viewers v WHERE v.viewer IS NOT NULL) END AS n UNION ALL SELECT MAX(n) FROM deliveries WHERE thread = ?1)

///|
let latest_decisions_sql : String =
  #|SELECT id, session, created_at, result FROM decision_checks WHERE id IN (SELECT MAX(id) FROM decision_checks WHERE created_at >= ? GROUP BY +session) ORDER BY created_at, id

///|
let latest_decisions_scoped_fallback_sql : String =
  #|WITH latest AS MATERIALIZED (
  #|  SELECT MAX(id) AS id, session FROM decision_checks WHERE created_at >= ?1 GROUP BY +session
  #|)
  #|SELECT d.id, d.session, d.created_at, d.result FROM latest l
  #|LEFT JOIN sessions s ON s.key = l.session
  #|CROSS JOIN decision_checks d ON d.id = l.id
  #|WHERE s.ws = ?2 OR (?3 AND s.ws IS NULL)
  #|ORDER BY d.created_at, d.id

///|
let legacy_latest_decisions_sql : String =
  #|WITH index_state AS MATERIALIZED (SELECT complete FROM legacy_decision_time_meta WHERE id=1),
  #|latest AS MATERIALIZED (
  #|  SELECT MAX(d.id) AS id, d.session FROM index_state i CROSS JOIN decision_checks d
  #|    WHERE i.complete=0 AND d.created_at>=?1 GROUP BY +d.session
  #|  UNION ALL
  #|  SELECT MAX(d.id) AS id, d.session FROM index_state i CROSS JOIN legacy_decision_time d INDEXED BY legacy_decision_time_at
  #|    WHERE i.complete=1 AND d.created_at>=?1 GROUP BY +d.session
  #|)
  #|SELECT d.id,d.session,d.created_at,d.result FROM latest l CROSS JOIN decision_checks d ON d.id=l.id
  #|ORDER BY d.created_at,d.id

///|
let legacy_latest_decisions_scoped_fallback_sql : String =
  #|WITH index_state AS MATERIALIZED (SELECT complete FROM legacy_decision_time_meta WHERE id=1),
  #|latest AS MATERIALIZED (
  #|  SELECT MAX(d.id) AS id, d.session FROM index_state i CROSS JOIN decision_checks d
  #|    WHERE i.complete=0 AND d.created_at>=?1 GROUP BY +d.session
  #|  UNION ALL
  #|  SELECT MAX(d.id) AS id, d.session FROM index_state i CROSS JOIN legacy_decision_time d INDEXED BY legacy_decision_time_at
  #|    WHERE i.complete=1 AND d.created_at>=?1 GROUP BY +d.session
  #|)
  #|SELECT d.id,d.session,d.created_at,d.result FROM latest l
  #|LEFT JOIN sessions s ON s.key=l.session CROSS JOIN decision_checks d ON d.id=l.id
  #|WHERE s.ws=?2 OR (?3 AND s.ws IS NULL) ORDER BY d.created_at,d.id

///|
let recent_last_decision_sql : String =
  #|WITH
  #|recent AS MATERIALIZED (SELECT id,session FROM decision_checks NOT INDEXED ORDER BY id DESC LIMIT 64),
  #|chosen AS MATERIALIZED (SELECT id FROM recent WHERE session=?1 ORDER BY id DESC LIMIT 1)
  #|SELECT (SELECT COUNT(*) FROM recent) AS n, EXISTS(SELECT 1 FROM chosen) AS found,
  #|  (SELECT d.result FROM chosen c CROSS JOIN decision_checks d ON d.id=c.id) AS result

///|
let latest_decisions_scoped_sql : String =
  #|WITH RECURSIVE
  #|
  #|
  #|recent AS MATERIALIZED (
  #|  SELECT id FROM decision_checks INDEXED BY decision_checks_lately WHERE ?3 = 0 AND created_at >= ?1 LIMIT 65
  #|),
  #|
  #|connects(connect, n) AS (
  #|  SELECT (SELECT connect FROM sessions INDEXED BY sessions_by_connect ORDER BY connect LIMIT 1), 1
  #|  WHERE (SELECT COUNT(*) FROM recent) = 65
  #|  UNION ALL
  #|  SELECT (SELECT connect FROM sessions INDEXED BY sessions_by_connect WHERE connect > c.connect ORDER BY connect LIMIT 1), n + 1
  #|  FROM connects c WHERE c.connect IS NOT NULL AND n < 65
  #|),
  #|chosen AS MATERIALIZED (
  #|  SELECT s.key FROM connects c CROSS JOIN sessions s INDEXED BY sessions_by_connect
  #|  WHERE c.connect IS NOT NULL AND s.connect = c.connect AND s.ws = ?2 LIMIT 65
  #|),
  #|lookups AS MATERIALIZED (
  #|  SELECT c.key, (SELECT id FROM (
  #|    SELECT id, created_at FROM decision_checks INDEXED BY decision_checks_session WHERE session = c.key ORDER BY id DESC LIMIT 65
  #|  ) WHERE created_at >= ?1 ORDER BY id DESC LIMIT 1) AS id
  #|  FROM chosen c WHERE (SELECT COUNT(connect) FROM connects) <= 64 AND (SELECT COUNT(*) FROM chosen) <= 64
  #|),
  #|mode AS MATERIALIZED (
  #|  SELECT (SELECT COUNT(*) FROM recent) < 65 OR (SELECT COUNT(connect) FROM connects) > 64
  #|    OR (SELECT COUNT(*) FROM chosen) > 64 OR EXISTS (
  #|      SELECT 1 FROM lookups l WHERE l.id IS NULL AND EXISTS (
  #|        SELECT 1 FROM decision_checks INDEXED BY decision_checks_session WHERE session = l.key ORDER BY id DESC LIMIT 1 OFFSET 64
  #|      )
  #|    ) AS use_global
  #|),
  #|latest AS MATERIALIZED (
  #|  SELECT MAX(id) AS id, session FROM mode CROSS JOIN decision_checks WHERE use_global AND created_at >= ?1 GROUP BY +session
  #|  UNION ALL
  #|  SELECT id, key AS session FROM lookups WHERE id IS NOT NULL AND NOT (SELECT use_global FROM mode)
  #|)
  #|SELECT d.id, d.session, d.created_at, d.result FROM latest l
  #|LEFT JOIN sessions s ON s.key = l.session
  #|CROSS JOIN decision_checks d ON d.id = l.id
  #|WHERE s.ws = ?2 OR (?3 AND s.ws IS NULL)
  #|ORDER BY d.created_at, d.id

///|
let legacy_latest_decisions_scoped_sql : String =
  #|WITH RECURSIVE
  #|
  #|index_state AS MATERIALIZED (
  #|  SELECT complete, EXISTS (SELECT 1 FROM sqlite_master WHERE type='index' AND name='decision_checks_at') AS has_old
  #|  FROM legacy_decision_time_meta WHERE id=1
  #|),
  #|recent AS MATERIALIZED (
  #|  SELECT id FROM (SELECT d.id FROM index_state i CROSS JOIN decision_checks d
  #|    WHERE i.complete=0 AND i.has_old AND ?3=0 AND d.created_at>=?1 LIMIT 65)
  #|  UNION ALL SELECT id FROM (SELECT d.id FROM index_state i CROSS JOIN legacy_decision_time d INDEXED BY legacy_decision_time_at
  #|    WHERE i.complete=1 AND ?3=0 AND d.created_at>=?1 LIMIT 65)
  #|),
  #|recent_count AS MATERIALIZED (
  #|  SELECT CASE WHEN i.complete=0 AND NOT i.has_old AND ?3=0 THEN 65
  #|    ELSE (SELECT COUNT(*) FROM recent) END AS n FROM index_state i
  #|),
  #|connects(connect, n) AS (
  #|  SELECT (SELECT connect FROM sessions INDEXED BY sessions_by_connect ORDER BY connect LIMIT 1), 1
  #|  WHERE (SELECT n FROM recent_count) = 65
  #|  UNION ALL
  #|  SELECT (SELECT connect FROM sessions INDEXED BY sessions_by_connect WHERE connect > c.connect ORDER BY connect LIMIT 1), n + 1
  #|  FROM connects c WHERE c.connect IS NOT NULL AND n < 65
  #|),
  #|chosen AS MATERIALIZED (
  #|  SELECT s.key FROM connects c CROSS JOIN sessions s INDEXED BY sessions_by_connect
  #|  WHERE c.connect IS NOT NULL AND s.connect = c.connect AND s.ws = ?2 LIMIT 65
  #|),
  #|lookups AS MATERIALIZED (
  #|  SELECT c.key, (SELECT id FROM (
  #|    SELECT id, created_at FROM decision_checks INDEXED BY decision_checks_session WHERE session = c.key ORDER BY id DESC LIMIT 65
  #|  ) WHERE created_at >= ?1 ORDER BY id DESC LIMIT 1) AS id
  #|  FROM chosen c WHERE (SELECT COUNT(connect) FROM connects) <= 64 AND (SELECT COUNT(*) FROM chosen) <= 64
  #|),
  #|mode AS MATERIALIZED (
  #|  SELECT (SELECT n FROM recent_count) < 65 OR (SELECT COUNT(connect) FROM connects) > 64
  #|    OR (SELECT COUNT(*) FROM chosen) > 64 OR EXISTS (
  #|      SELECT 1 FROM lookups l WHERE l.id IS NULL AND EXISTS (
  #|        SELECT 1 FROM decision_checks INDEXED BY decision_checks_session WHERE session = l.key ORDER BY id DESC LIMIT 1 OFFSET 64
  #|      )
  #|    ) AS use_global
  #|),
  #|latest AS MATERIALIZED (
  #|  SELECT MAX(d.id) AS id,d.session FROM mode CROSS JOIN index_state i CROSS JOIN decision_checks d
  #|    WHERE use_global AND i.complete=0 AND d.created_at>=?1 GROUP BY +d.session
  #|  UNION ALL SELECT MAX(d.id) AS id,d.session FROM mode CROSS JOIN index_state i
  #|    CROSS JOIN legacy_decision_time d INDEXED BY legacy_decision_time_at
  #|    WHERE use_global AND i.complete=1 AND d.created_at>=?1 GROUP BY +d.session
  #|  UNION ALL
  #|  SELECT id, key AS session FROM lookups WHERE id IS NOT NULL AND NOT (SELECT use_global FROM mode)
  #|)
  #|SELECT d.id, d.session, d.created_at, d.result FROM latest l
  #|LEFT JOIN sessions s ON s.key = l.session
  #|CROSS JOIN decision_checks d ON d.id = l.id
  #|WHERE s.ws = ?2 OR (?3 AND s.ws IS NULL)
  #|ORDER BY d.created_at, d.id

///|
let latest_decisions_scoped_no_time_sql : String =
  #|WITH RECURSIVE
  #|
  #|
  #|recent AS MATERIALIZED (
  #|  SELECT NULL AS id WHERE 0
  #|),
  #|
  #|connects(connect, n) AS (
  #|  SELECT (SELECT connect FROM sessions INDEXED BY sessions_by_connect ORDER BY connect LIMIT 1), 1
  #|  WHERE 65 = 65
  #|  UNION ALL
  #|  SELECT (SELECT connect FROM sessions INDEXED BY sessions_by_connect WHERE connect > c.connect ORDER BY connect LIMIT 1), n + 1
  #|  FROM connects c WHERE c.connect IS NOT NULL AND n < 65
  #|),
  #|chosen AS MATERIALIZED (
  #|  SELECT s.key FROM connects c CROSS JOIN sessions s INDEXED BY sessions_by_connect
  #|  WHERE c.connect IS NOT NULL AND s.connect = c.connect AND s.ws = ?2 LIMIT 65
  #|),
  #|lookups AS MATERIALIZED (
  #|  SELECT c.key, (SELECT id FROM (
  #|    SELECT id, created_at FROM decision_checks INDEXED BY decision_checks_session WHERE session = c.key ORDER BY id DESC LIMIT 65
  #|  ) WHERE created_at >= ?1 ORDER BY id DESC LIMIT 1) AS id
  #|  FROM chosen c WHERE (SELECT COUNT(connect) FROM connects) <= 64 AND (SELECT COUNT(*) FROM chosen) <= 64
  #|),
  #|mode AS MATERIALIZED (
  #|  SELECT 65 < 65 OR (SELECT COUNT(connect) FROM connects) > 64
  #|    OR (SELECT COUNT(*) FROM chosen) > 64 OR EXISTS (
  #|      SELECT 1 FROM lookups l WHERE l.id IS NULL AND EXISTS (
  #|        SELECT 1 FROM decision_checks INDEXED BY decision_checks_session WHERE session = l.key ORDER BY id DESC LIMIT 1 OFFSET 64
  #|      )
  #|    ) AS use_global
  #|),
  #|latest AS MATERIALIZED (
  #|  SELECT MAX(id) AS id, session FROM mode CROSS JOIN decision_checks WHERE use_global AND created_at >= ?1 GROUP BY +session
  #|  UNION ALL
  #|  SELECT id, key AS session FROM lookups WHERE id IS NOT NULL AND NOT (SELECT use_global FROM mode)
  #|)
  #|SELECT d.id, d.session, d.created_at, d.result FROM latest l
  #|LEFT JOIN sessions s ON s.key = l.session
  #|CROSS JOIN decision_checks d ON d.id = l.id
  #|WHERE s.ws = ?2 OR (?3 AND s.ws IS NULL)
  #|ORDER BY d.created_at, d.id

///|
let heard_in_sql : String =
  #|SELECT 1 FROM deliveries INDEXED BY deliveries_session WHERE session = ? AND thread = ? AND delivered_at IS NOT NULL LIMIT 1

///|
let closed_card_after_sql : String =
  #|SELECT
  #|  EXISTS (SELECT 1 FROM entries INDEXED BY entries_people_by_n WHERE thread = ?1 AND n > ?2 AND kind = 'message' AND author_kind = 'person')
  #|  OR EXISTS (SELECT 1 FROM entries INDEXED BY entries_cards WHERE thread = ?1 AND n > ?2 AND kind = 'message' AND card IS NOT NULL)
  #|  OR EXISTS (SELECT 1 FROM entries INDEXED BY entries_options WHERE thread = ?1 AND n > ?2 AND kind = 'message' AND options IS NOT NULL) AS ended

///|
let card_before_latest_person_sql : String =
  #|WITH person(n) AS MATERIALIZED (
  #|  SELECT COALESCE((SELECT n FROM entries WHERE thread = ?1 AND n < ?2 AND kind = 'message' AND author_kind = 'person'
  #|    ORDER BY n DESC LIMIT 1), -9223372036854775808)
  #|)
  #|SELECT MAX(n) AS n FROM (
  #|  SELECT (SELECT MAX(n) FROM entries WHERE thread = ?1 AND n < ?2 AND n >= (SELECT n FROM person)
  #|    AND kind = 'message' AND card IS NOT NULL) AS n
  #|  UNION ALL
  #|  SELECT (SELECT MAX(n) FROM entries WHERE thread = ?1 AND n < ?2 AND n >= (SELECT n FROM person)
  #|    AND kind = 'message' AND options IS NOT NULL)
  #|)

///|
let has_pending_message_sql : String =
  #|SELECT 1 FROM deliveries d INDEXED BY deliveries_pending
  #|  JOIN entries m ON m.thread = d.thread AND m.n = d.n AND m.kind = 'message'
  #|  JOIN threads t ON t.id = d.thread
  #|  JOIN thread_sessions ts ON ts.thread = t.id AND ts.session = d.session
  #|  WHERE d.session = ? AND d.delivered_at IS NULL LIMIT 1

///|
let has_pending_letter_sql : String =
  #|SELECT 1 FROM letter_deliveries d INDEXED BY letter_deliveries_pending
  #|  JOIN letters l ON l.thread = d.thread AND l.n = d.n
  #|  JOIN threads t ON t.id = d.thread
  #|  JOIN thread_sessions ts ON ts.thread = t.id AND ts.session = d.session
  #|  WHERE d.session = ? AND d.delivered_at IS NULL LIMIT 1

///|
let pending_count_sql : String =
  #|SELECT
  #|  (SELECT COUNT(*) FROM deliveries d INDEXED BY deliveries_pending
  #|    JOIN entries m ON m.thread = d.thread AND m.n = d.n AND m.kind = 'message'
  #|    JOIN threads t ON t.id = d.thread
  #|    JOIN thread_sessions ts ON ts.thread = t.id AND ts.session = d.session
  #|    WHERE d.session = ?1 AND d.delivered_at IS NULL)
  #|  + (SELECT COUNT(*) FROM letter_deliveries d INDEXED BY letter_deliveries_pending
  #|    JOIN letters l ON l.thread = d.thread AND l.n = d.n
  #|    JOIN threads t ON t.id = d.thread
  #|    JOIN thread_sessions ts ON ts.thread = t.id AND ts.session = d.session
  #|    WHERE d.session = ?1 AND d.delivered_at IS NULL) AS n

///|
let pending_sessions_sql : String =
  #|WITH RECURSIVE
  #|  said(session) AS (
  #|    VALUES ((SELECT session FROM deliveries INDEXED BY deliveries_pending WHERE delivered_at IS NULL ORDER BY session LIMIT 1))
  #|    UNION ALL
  #|    SELECT (SELECT session FROM deliveries INDEXED BY deliveries_pending WHERE delivered_at IS NULL AND session > said.session ORDER BY session LIMIT 1)
  #|      FROM said WHERE said.session IS NOT NULL
  #|  ),
  #|  letters_pending(session) AS (
  #|    VALUES ((SELECT session FROM letter_deliveries INDEXED BY letter_deliveries_pending WHERE delivered_at IS NULL ORDER BY session LIMIT 1))
  #|    UNION ALL
  #|    SELECT (SELECT session FROM letter_deliveries INDEXED BY letter_deliveries_pending WHERE delivered_at IS NULL AND session > letters_pending.session ORDER BY session LIMIT 1)
  #|      FROM letters_pending WHERE letters_pending.session IS NOT NULL
  #|  )
  #|  SELECT session FROM said WHERE session IS NOT NULL
  #|  UNION SELECT session FROM letters_pending WHERE session IS NOT NULL

///|
let login_cards_sql : String =
  #|SELECT thread, n, author FROM entries INDEXED BY entries_login_cards WHERE kind = 'message' AND author_kind = 'agent' AND card LIKE '%"login"%' AND card LIKE ? AND NOT EXISTS (SELECT 1 FROM closed_cards c WHERE c.thread = entries.thread AND c.n = entries.n)

///|
let small_decision_scope_native_sql : String =
  #|WITH
  #|recent AS MATERIALIZED (SELECT id,session FROM decision_checks INDEXED BY decision_checks_lately WHERE created_at>=?1 LIMIT 65),
  #|size AS MATERIALIZED (SELECT COUNT(*) AS n FROM recent),
  #|latest AS MATERIALIZED (SELECT MAX(id) AS id,session FROM recent WHERE (SELECT n FROM size)<=64 GROUP BY +session),
  #|selected AS MATERIALIZED (
  #|  SELECT d.id,d.session,d.created_at,d.result FROM latest l
  #|  CROSS JOIN sessions s ON s.key=l.session AND s.ws=?2
  #|  CROSS JOIN decision_checks d ON d.id=l.id
  #|)
  #|SELECT size.n,selected.id,selected.session,selected.created_at,selected.result FROM size
  #|LEFT JOIN selected ON 1 ORDER BY selected.created_at,selected.id

///|
let small_decision_scope_old_sql : String =
  #|WITH
  #|recent AS MATERIALIZED (SELECT id,session FROM decision_checks INDEXED BY decision_checks_at WHERE created_at>=?1 LIMIT 65),
  #|size AS MATERIALIZED (SELECT COUNT(*) AS n FROM recent),
  #|latest AS MATERIALIZED (SELECT MAX(id) AS id,session FROM recent WHERE (SELECT n FROM size)<=64 GROUP BY +session),
  #|selected AS MATERIALIZED (
  #|  SELECT d.id,d.session,d.created_at,d.result FROM latest l
  #|  CROSS JOIN sessions s ON s.key=l.session AND s.ws=?2
  #|  CROSS JOIN decision_checks d ON d.id=l.id
  #|)
  #|SELECT size.n,selected.id,selected.session,selected.created_at,selected.result FROM size
  #|LEFT JOIN selected ON 1 ORDER BY selected.created_at,selected.id

///|
let small_decision_scope_prepared_sql : String =
  #|WITH
  #|recent AS MATERIALIZED (SELECT id,session FROM legacy_decision_time INDEXED BY legacy_decision_time_at WHERE created_at>=?1 LIMIT 65),
  #|size AS MATERIALIZED (SELECT COUNT(*) AS n FROM recent),
  #|latest AS MATERIALIZED (SELECT MAX(id) AS id,session FROM recent WHERE (SELECT n FROM size)<=64 GROUP BY +session),
  #|selected AS MATERIALIZED (
  #|  SELECT d.id,d.session,d.created_at,d.result FROM latest l
  #|  CROSS JOIN sessions s ON s.key=l.session AND s.ws=?2
  #|  CROSS JOIN decision_checks d ON d.id=l.id
  #|)
  #|SELECT size.n,selected.id,selected.session,selected.created_at,selected.result FROM size
  #|LEFT JOIN selected ON 1 ORDER BY selected.created_at,selected.id

///|
let decision_scoped_shared_native_sql : String =
  #|WITH RECURSIVE
  #|session_state AS MATERIALIZED (SELECT complete FROM legacy_decision_time_meta WHERE id=1),
  #|
  #|recent AS MATERIALIZED (
  #|  SELECT id FROM decision_checks INDEXED BY decision_checks_lately WHERE ?3 = 0 AND created_at >= ?1 LIMIT 65
  #|),
  #|
  #|connects(connect, n) AS (
  #|  SELECT (SELECT connect FROM sessions INDEXED BY sessions_by_connect ORDER BY connect LIMIT 1), 1
  #|  WHERE (SELECT COUNT(*) FROM recent) = 65
  #|  UNION ALL
  #|  SELECT (SELECT connect FROM sessions INDEXED BY sessions_by_connect WHERE connect > c.connect ORDER BY connect LIMIT 1), n + 1
  #|  FROM connects c WHERE c.connect IS NOT NULL AND n < 65
  #|),
  #|chosen AS MATERIALIZED (
  #|  SELECT s.key FROM connects c CROSS JOIN sessions s INDEXED BY sessions_by_connect
  #|  WHERE c.connect IS NOT NULL AND s.connect = c.connect AND s.ws = ?2 LIMIT 65
  #|),
  #|lookups AS MATERIALIZED (
  #|  SELECT c.key, (SELECT id FROM (
  #|    SELECT d.id,d.created_at FROM session_state i CROSS JOIN legacy_decision_time p INDEXED BY legacy_decision_time_by_session
  #|  CROSS JOIN decision_checks d ON d.id=p.id WHERE i.complete=1 AND p.session=c.key ORDER BY p.id DESC LIMIT 65
  #|  ) WHERE created_at >= ?1 ORDER BY id DESC LIMIT 1) AS id
  #|  FROM chosen c WHERE (SELECT COUNT(connect) FROM connects) <= 64 AND (SELECT COUNT(*) FROM chosen) <= 64
  #|),
  #|mode AS MATERIALIZED (
  #|  SELECT (SELECT complete FROM session_state)=0 OR (SELECT COUNT(*) FROM recent) < 65 OR (SELECT COUNT(connect) FROM connects) > 64
  #|    OR (SELECT COUNT(*) FROM chosen) > 64 OR EXISTS (
  #|      SELECT 1 FROM lookups l WHERE l.id IS NULL AND EXISTS (
  #|        SELECT 1 FROM session_state i CROSS JOIN legacy_decision_time p INDEXED BY legacy_decision_time_by_session
  #|  WHERE i.complete=1 AND p.session=l.key ORDER BY p.id DESC LIMIT 1 OFFSET 64
  #|      )
  #|    ) AS use_global
  #|),
  #|latest AS MATERIALIZED (
  #|  SELECT MAX(id) AS id, session FROM mode CROSS JOIN decision_checks WHERE use_global AND created_at >= ?1 GROUP BY +session
  #|  UNION ALL
  #|  SELECT id, key AS session FROM lookups WHERE id IS NOT NULL AND NOT (SELECT use_global FROM mode)
  #|)
  #|SELECT d.id, d.session, d.created_at, d.result FROM latest l
  #|LEFT JOIN sessions s ON s.key = l.session
  #|CROSS JOIN decision_checks d ON d.id = l.id
  #|WHERE s.ws = ?2 OR (?3 AND s.ws IS NULL)
  #|ORDER BY d.created_at, d.id

///|
let decision_scoped_shared_legacy_sql : String =
  #|WITH RECURSIVE
  #|session_state AS MATERIALIZED (SELECT complete FROM legacy_decision_time_meta WHERE id=1),
  #|index_state AS MATERIALIZED (
  #|  SELECT complete, EXISTS (SELECT 1 FROM sqlite_master WHERE type='index' AND name='decision_checks_at') AS has_old
  #|  FROM legacy_decision_time_meta WHERE id=1
  #|),
  #|recent AS MATERIALIZED (
  #|  SELECT id FROM (SELECT d.id FROM index_state i CROSS JOIN decision_checks d
  #|    WHERE i.complete=0 AND i.has_old AND ?3=0 AND d.created_at>=?1 LIMIT 65)
  #|  UNION ALL SELECT id FROM (SELECT d.id FROM index_state i CROSS JOIN legacy_decision_time d INDEXED BY legacy_decision_time_at
  #|    WHERE i.complete=1 AND ?3=0 AND d.created_at>=?1 LIMIT 65)
  #|),
  #|recent_count AS MATERIALIZED (
  #|  SELECT CASE WHEN i.complete=0 AND NOT i.has_old AND ?3=0 THEN 65
  #|    ELSE (SELECT COUNT(*) FROM recent) END AS n FROM index_state i
  #|),
  #|connects(connect, n) AS (
  #|  SELECT (SELECT connect FROM sessions INDEXED BY sessions_by_connect ORDER BY connect LIMIT 1), 1
  #|  WHERE (SELECT n FROM recent_count) = 65
  #|  UNION ALL
  #|  SELECT (SELECT connect FROM sessions INDEXED BY sessions_by_connect WHERE connect > c.connect ORDER BY connect LIMIT 1), n + 1
  #|  FROM connects c WHERE c.connect IS NOT NULL AND n < 65
  #|),
  #|chosen AS MATERIALIZED (
  #|  SELECT s.key FROM connects c CROSS JOIN sessions s INDEXED BY sessions_by_connect
  #|  WHERE c.connect IS NOT NULL AND s.connect = c.connect AND s.ws = ?2 LIMIT 65
  #|),
  #|lookups AS MATERIALIZED (
  #|  SELECT c.key, (SELECT id FROM (
  #|    SELECT d.id,d.created_at FROM session_state i CROSS JOIN legacy_decision_time p INDEXED BY legacy_decision_time_by_session
  #|  CROSS JOIN decision_checks d ON d.id=p.id WHERE i.complete=1 AND p.session=c.key ORDER BY p.id DESC LIMIT 65
  #|  ) WHERE created_at >= ?1 ORDER BY id DESC LIMIT 1) AS id
  #|  FROM chosen c WHERE (SELECT COUNT(connect) FROM connects) <= 64 AND (SELECT COUNT(*) FROM chosen) <= 64
  #|),
  #|mode AS MATERIALIZED (
  #|  SELECT (SELECT complete FROM session_state)=0 OR (SELECT n FROM recent_count) < 65 OR (SELECT COUNT(connect) FROM connects) > 64
  #|    OR (SELECT COUNT(*) FROM chosen) > 64 OR EXISTS (
  #|      SELECT 1 FROM lookups l WHERE l.id IS NULL AND EXISTS (
  #|        SELECT 1 FROM session_state i CROSS JOIN legacy_decision_time p INDEXED BY legacy_decision_time_by_session
  #|  WHERE i.complete=1 AND p.session=l.key ORDER BY p.id DESC LIMIT 1 OFFSET 64
  #|      )
  #|    ) AS use_global
  #|),
  #|latest AS MATERIALIZED (
  #|  SELECT MAX(d.id) AS id,d.session FROM mode CROSS JOIN index_state i CROSS JOIN decision_checks d
  #|    WHERE use_global AND i.complete=0 AND d.created_at>=?1 GROUP BY +d.session
  #|  UNION ALL SELECT MAX(d.id) AS id,d.session FROM mode CROSS JOIN index_state i
  #|    CROSS JOIN legacy_decision_time d INDEXED BY legacy_decision_time_at
  #|    WHERE use_global AND i.complete=1 AND d.created_at>=?1 GROUP BY +d.session
  #|  UNION ALL
  #|  SELECT id, key AS session FROM lookups WHERE id IS NOT NULL AND NOT (SELECT use_global FROM mode)
  #|)
  #|SELECT d.id, d.session, d.created_at, d.result FROM latest l
  #|LEFT JOIN sessions s ON s.key = l.session
  #|CROSS JOIN decision_checks d ON d.id = l.id
  #|WHERE s.ws = ?2 OR (?3 AND s.ws IS NULL)
  #|ORDER BY d.created_at, d.id

///|
let decision_scoped_shared_no_time_sql : String =
  #|WITH RECURSIVE
  #|session_state AS MATERIALIZED (SELECT complete FROM legacy_decision_time_meta WHERE id=1),
  #|
  #|recent AS MATERIALIZED (
  #|  SELECT NULL AS id WHERE 0
  #|),
  #|
  #|connects(connect, n) AS (
  #|  SELECT (SELECT connect FROM sessions INDEXED BY sessions_by_connect ORDER BY connect LIMIT 1), 1
  #|  WHERE 65 = 65
  #|  UNION ALL
  #|  SELECT (SELECT connect FROM sessions INDEXED BY sessions_by_connect WHERE connect > c.connect ORDER BY connect LIMIT 1), n + 1
  #|  FROM connects c WHERE c.connect IS NOT NULL AND n < 65
  #|),
  #|chosen AS MATERIALIZED (
  #|  SELECT s.key FROM connects c CROSS JOIN sessions s INDEXED BY sessions_by_connect
  #|  WHERE c.connect IS NOT NULL AND s.connect = c.connect AND s.ws = ?2 LIMIT 65
  #|),
  #|lookups AS MATERIALIZED (
  #|  SELECT c.key, (SELECT id FROM (
  #|    SELECT d.id,d.created_at FROM session_state i CROSS JOIN legacy_decision_time p INDEXED BY legacy_decision_time_by_session
  #|  CROSS JOIN decision_checks d ON d.id=p.id WHERE i.complete=1 AND p.session=c.key ORDER BY p.id DESC LIMIT 65
  #|  ) WHERE created_at >= ?1 ORDER BY id DESC LIMIT 1) AS id
  #|  FROM chosen c WHERE (SELECT COUNT(connect) FROM connects) <= 64 AND (SELECT COUNT(*) FROM chosen) <= 64
  #|),
  #|mode AS MATERIALIZED (
  #|  SELECT (SELECT complete FROM session_state)=0 OR 65 < 65 OR (SELECT COUNT(connect) FROM connects) > 64
  #|    OR (SELECT COUNT(*) FROM chosen) > 64 OR EXISTS (
  #|      SELECT 1 FROM lookups l WHERE l.id IS NULL AND EXISTS (
  #|        SELECT 1 FROM session_state i CROSS JOIN legacy_decision_time p INDEXED BY legacy_decision_time_by_session
  #|  WHERE i.complete=1 AND p.session=l.key ORDER BY p.id DESC LIMIT 1 OFFSET 64
  #|      )
  #|    ) AS use_global
  #|),
  #|latest AS MATERIALIZED (
  #|  SELECT MAX(id) AS id, session FROM mode CROSS JOIN decision_checks WHERE use_global AND created_at >= ?1 GROUP BY +session
  #|  UNION ALL
  #|  SELECT id, key AS session FROM lookups WHERE id IS NOT NULL AND NOT (SELECT use_global FROM mode)
  #|)
  #|SELECT d.id, d.session, d.created_at, d.result FROM latest l
  #|LEFT JOIN sessions s ON s.key = l.session
  #|CROSS JOIN decision_checks d ON d.id = l.id
  #|WHERE s.ws = ?2 OR (?3 AND s.ws IS NULL)
  #|ORDER BY d.created_at, d.id

///|
let decision_scoped_separate_native_sql : String =
  #|WITH RECURSIVE
  #|session_state AS MATERIALIZED (SELECT complete FROM legacy_decision_session_meta WHERE id=1),
  #|
  #|recent AS MATERIALIZED (
  #|  SELECT id FROM decision_checks INDEXED BY decision_checks_lately WHERE ?3 = 0 AND created_at >= ?1 LIMIT 65
  #|),
  #|
  #|connects(connect, n) AS (
  #|  SELECT (SELECT connect FROM sessions INDEXED BY sessions_by_connect ORDER BY connect LIMIT 1), 1
  #|  WHERE (SELECT COUNT(*) FROM recent) = 65
  #|  UNION ALL
  #|  SELECT (SELECT connect FROM sessions INDEXED BY sessions_by_connect WHERE connect > c.connect ORDER BY connect LIMIT 1), n + 1
  #|  FROM connects c WHERE c.connect IS NOT NULL AND n < 65
  #|),
  #|chosen AS MATERIALIZED (
  #|  SELECT s.key FROM connects c CROSS JOIN sessions s INDEXED BY sessions_by_connect
  #|  WHERE c.connect IS NOT NULL AND s.connect = c.connect AND s.ws = ?2 LIMIT 65
  #|),
  #|lookups AS MATERIALIZED (
  #|  SELECT c.key, (SELECT id FROM (
  #|    SELECT d.id,d.created_at FROM session_state i CROSS JOIN legacy_decision_session p INDEXED BY legacy_decision_session_by_session
  #|  CROSS JOIN decision_checks d ON d.id=p.id WHERE i.complete=1 AND p.session=c.key ORDER BY p.id DESC LIMIT 65
  #|  ) WHERE created_at >= ?1 ORDER BY id DESC LIMIT 1) AS id
  #|  FROM chosen c WHERE (SELECT COUNT(connect) FROM connects) <= 64 AND (SELECT COUNT(*) FROM chosen) <= 64
  #|),
  #|mode AS MATERIALIZED (
  #|  SELECT (SELECT complete FROM session_state)=0 OR (SELECT COUNT(*) FROM recent) < 65 OR (SELECT COUNT(connect) FROM connects) > 64
  #|    OR (SELECT COUNT(*) FROM chosen) > 64 OR EXISTS (
  #|      SELECT 1 FROM lookups l WHERE l.id IS NULL AND EXISTS (
  #|        SELECT 1 FROM session_state i CROSS JOIN legacy_decision_session p INDEXED BY legacy_decision_session_by_session
  #|  WHERE i.complete=1 AND p.session=l.key ORDER BY p.id DESC LIMIT 1 OFFSET 64
  #|      )
  #|    ) AS use_global
  #|),
  #|latest AS MATERIALIZED (
  #|  SELECT MAX(id) AS id, session FROM mode CROSS JOIN decision_checks WHERE use_global AND created_at >= ?1 GROUP BY +session
  #|  UNION ALL
  #|  SELECT id, key AS session FROM lookups WHERE id IS NOT NULL AND NOT (SELECT use_global FROM mode)
  #|)
  #|SELECT d.id, d.session, d.created_at, d.result FROM latest l
  #|LEFT JOIN sessions s ON s.key = l.session
  #|CROSS JOIN decision_checks d ON d.id = l.id
  #|WHERE s.ws = ?2 OR (?3 AND s.ws IS NULL)
  #|ORDER BY d.created_at, d.id

///|
let decision_scoped_separate_legacy_sql : String =
  #|WITH RECURSIVE
  #|session_state AS MATERIALIZED (SELECT complete FROM legacy_decision_session_meta WHERE id=1),
  #|index_state AS MATERIALIZED (
  #|  SELECT complete, EXISTS (SELECT 1 FROM sqlite_master WHERE type='index' AND name='decision_checks_at') AS has_old
  #|  FROM legacy_decision_time_meta WHERE id=1
  #|),
  #|recent AS MATERIALIZED (
  #|  SELECT id FROM (SELECT d.id FROM index_state i CROSS JOIN decision_checks d
  #|    WHERE i.complete=0 AND i.has_old AND ?3=0 AND d.created_at>=?1 LIMIT 65)
  #|  UNION ALL SELECT id FROM (SELECT d.id FROM index_state i CROSS JOIN legacy_decision_time d INDEXED BY legacy_decision_time_at
  #|    WHERE i.complete=1 AND ?3=0 AND d.created_at>=?1 LIMIT 65)
  #|),
  #|recent_count AS MATERIALIZED (
  #|  SELECT CASE WHEN i.complete=0 AND NOT i.has_old AND ?3=0 THEN 65
  #|    ELSE (SELECT COUNT(*) FROM recent) END AS n FROM index_state i
  #|),
  #|connects(connect, n) AS (
  #|  SELECT (SELECT connect FROM sessions INDEXED BY sessions_by_connect ORDER BY connect LIMIT 1), 1
  #|  WHERE (SELECT n FROM recent_count) = 65
  #|  UNION ALL
  #|  SELECT (SELECT connect FROM sessions INDEXED BY sessions_by_connect WHERE connect > c.connect ORDER BY connect LIMIT 1), n + 1
  #|  FROM connects c WHERE c.connect IS NOT NULL AND n < 65
  #|),
  #|chosen AS MATERIALIZED (
  #|  SELECT s.key FROM connects c CROSS JOIN sessions s INDEXED BY sessions_by_connect
  #|  WHERE c.connect IS NOT NULL AND s.connect = c.connect AND s.ws = ?2 LIMIT 65
  #|),
  #|lookups AS MATERIALIZED (
  #|  SELECT c.key, (SELECT id FROM (
  #|    SELECT d.id,d.created_at FROM session_state i CROSS JOIN legacy_decision_session p INDEXED BY legacy_decision_session_by_session
  #|  CROSS JOIN decision_checks d ON d.id=p.id WHERE i.complete=1 AND p.session=c.key ORDER BY p.id DESC LIMIT 65
  #|  ) WHERE created_at >= ?1 ORDER BY id DESC LIMIT 1) AS id
  #|  FROM chosen c WHERE (SELECT COUNT(connect) FROM connects) <= 64 AND (SELECT COUNT(*) FROM chosen) <= 64
  #|),
  #|mode AS MATERIALIZED (
  #|  SELECT (SELECT complete FROM session_state)=0 OR (SELECT n FROM recent_count) < 65 OR (SELECT COUNT(connect) FROM connects) > 64
  #|    OR (SELECT COUNT(*) FROM chosen) > 64 OR EXISTS (
  #|      SELECT 1 FROM lookups l WHERE l.id IS NULL AND EXISTS (
  #|        SELECT 1 FROM session_state i CROSS JOIN legacy_decision_session p INDEXED BY legacy_decision_session_by_session
  #|  WHERE i.complete=1 AND p.session=l.key ORDER BY p.id DESC LIMIT 1 OFFSET 64
  #|      )
  #|    ) AS use_global
  #|),
  #|latest AS MATERIALIZED (
  #|  SELECT MAX(d.id) AS id,d.session FROM mode CROSS JOIN index_state i CROSS JOIN decision_checks d
  #|    WHERE use_global AND i.complete=0 AND d.created_at>=?1 GROUP BY +d.session
  #|  UNION ALL SELECT MAX(d.id) AS id,d.session FROM mode CROSS JOIN index_state i
  #|    CROSS JOIN legacy_decision_time d INDEXED BY legacy_decision_time_at
  #|    WHERE use_global AND i.complete=1 AND d.created_at>=?1 GROUP BY +d.session
  #|  UNION ALL
  #|  SELECT id, key AS session FROM lookups WHERE id IS NOT NULL AND NOT (SELECT use_global FROM mode)
  #|)
  #|SELECT d.id, d.session, d.created_at, d.result FROM latest l
  #|LEFT JOIN sessions s ON s.key = l.session
  #|CROSS JOIN decision_checks d ON d.id = l.id
  #|WHERE s.ws = ?2 OR (?3 AND s.ws IS NULL)
  #|ORDER BY d.created_at, d.id

///|
let decision_scoped_separate_no_time_sql : String =
  #|WITH RECURSIVE
  #|session_state AS MATERIALIZED (SELECT complete FROM legacy_decision_session_meta WHERE id=1),
  #|
  #|recent AS MATERIALIZED (
  #|  SELECT NULL AS id WHERE 0
  #|),
  #|
  #|connects(connect, n) AS (
  #|  SELECT (SELECT connect FROM sessions INDEXED BY sessions_by_connect ORDER BY connect LIMIT 1), 1
  #|  WHERE 65 = 65
  #|  UNION ALL
  #|  SELECT (SELECT connect FROM sessions INDEXED BY sessions_by_connect WHERE connect > c.connect ORDER BY connect LIMIT 1), n + 1
  #|  FROM connects c WHERE c.connect IS NOT NULL AND n < 65
  #|),
  #|chosen AS MATERIALIZED (
  #|  SELECT s.key FROM connects c CROSS JOIN sessions s INDEXED BY sessions_by_connect
  #|  WHERE c.connect IS NOT NULL AND s.connect = c.connect AND s.ws = ?2 LIMIT 65
  #|),
  #|lookups AS MATERIALIZED (
  #|  SELECT c.key, (SELECT id FROM (
  #|    SELECT d.id,d.created_at FROM session_state i CROSS JOIN legacy_decision_session p INDEXED BY legacy_decision_session_by_session
  #|  CROSS JOIN decision_checks d ON d.id=p.id WHERE i.complete=1 AND p.session=c.key ORDER BY p.id DESC LIMIT 65
  #|  ) WHERE created_at >= ?1 ORDER BY id DESC LIMIT 1) AS id
  #|  FROM chosen c WHERE (SELECT COUNT(connect) FROM connects) <= 64 AND (SELECT COUNT(*) FROM chosen) <= 64
  #|),
  #|mode AS MATERIALIZED (
  #|  SELECT (SELECT complete FROM session_state)=0 OR 65 < 65 OR (SELECT COUNT(connect) FROM connects) > 64
  #|    OR (SELECT COUNT(*) FROM chosen) > 64 OR EXISTS (
  #|      SELECT 1 FROM lookups l WHERE l.id IS NULL AND EXISTS (
  #|        SELECT 1 FROM session_state i CROSS JOIN legacy_decision_session p INDEXED BY legacy_decision_session_by_session
  #|  WHERE i.complete=1 AND p.session=l.key ORDER BY p.id DESC LIMIT 1 OFFSET 64
  #|      )
  #|    ) AS use_global
  #|),
  #|latest AS MATERIALIZED (
  #|  SELECT MAX(id) AS id, session FROM mode CROSS JOIN decision_checks WHERE use_global AND created_at >= ?1 GROUP BY +session
  #|  UNION ALL
  #|  SELECT id, key AS session FROM lookups WHERE id IS NOT NULL AND NOT (SELECT use_global FROM mode)
  #|)
  #|SELECT d.id, d.session, d.created_at, d.result FROM latest l
  #|LEFT JOIN sessions s ON s.key = l.session
  #|CROSS JOIN decision_checks d ON d.id = l.id
  #|WHERE s.ws = ?2 OR (?3 AND s.ws IS NULL)
  #|ORDER BY d.created_at, d.id

///|
let decision_scoped_repair_native_sql : String =
  #|WITH RECURSIVE
  #|session_state AS MATERIALIZED (SELECT complete FROM legacy_decision_session_repair_meta WHERE id=1),
  #|
  #|recent AS MATERIALIZED (
  #|  SELECT id FROM decision_checks INDEXED BY decision_checks_lately WHERE ?3 = 0 AND created_at >= ?1 LIMIT 65
  #|),
  #|
  #|connects(connect, n) AS (
  #|  SELECT (SELECT connect FROM sessions INDEXED BY sessions_by_connect ORDER BY connect LIMIT 1), 1
  #|  WHERE (SELECT COUNT(*) FROM recent) = 65
  #|  UNION ALL
  #|  SELECT (SELECT connect FROM sessions INDEXED BY sessions_by_connect WHERE connect > c.connect ORDER BY connect LIMIT 1), n + 1
  #|  FROM connects c WHERE c.connect IS NOT NULL AND n < 65
  #|),
  #|chosen AS MATERIALIZED (
  #|  SELECT s.key FROM connects c CROSS JOIN sessions s INDEXED BY sessions_by_connect
  #|  WHERE c.connect IS NOT NULL AND s.connect = c.connect AND s.ws = ?2 LIMIT 65
  #|),
  #|lookups AS MATERIALIZED (
  #|  SELECT c.key, (SELECT id FROM (
  #|    SELECT d.id,d.created_at FROM session_state i CROSS JOIN legacy_decision_session_repair p INDEXED BY legacy_decision_session_repair_by_session
  #|  CROSS JOIN decision_checks d ON d.id=p.id WHERE i.complete=1 AND p.session=c.key ORDER BY p.id DESC LIMIT 65
  #|  ) WHERE created_at >= ?1 ORDER BY id DESC LIMIT 1) AS id
  #|  FROM chosen c WHERE (SELECT COUNT(connect) FROM connects) <= 64 AND (SELECT COUNT(*) FROM chosen) <= 64
  #|),
  #|mode AS MATERIALIZED (
  #|  SELECT (SELECT complete FROM session_state)=0 OR (SELECT COUNT(*) FROM recent) < 65 OR (SELECT COUNT(connect) FROM connects) > 64
  #|    OR (SELECT COUNT(*) FROM chosen) > 64 OR EXISTS (
  #|      SELECT 1 FROM lookups l WHERE l.id IS NULL AND EXISTS (
  #|        SELECT 1 FROM session_state i CROSS JOIN legacy_decision_session_repair p INDEXED BY legacy_decision_session_repair_by_session
  #|  WHERE i.complete=1 AND p.session=l.key ORDER BY p.id DESC LIMIT 1 OFFSET 64
  #|      )
  #|    ) AS use_global
  #|),
  #|latest AS MATERIALIZED (
  #|  SELECT MAX(id) AS id, session FROM mode CROSS JOIN decision_checks WHERE use_global AND created_at >= ?1 GROUP BY +session
  #|  UNION ALL
  #|  SELECT id, key AS session FROM lookups WHERE id IS NOT NULL AND NOT (SELECT use_global FROM mode)
  #|)
  #|SELECT d.id, d.session, d.created_at, d.result FROM latest l
  #|LEFT JOIN sessions s ON s.key = l.session
  #|CROSS JOIN decision_checks d ON d.id = l.id
  #|WHERE s.ws = ?2 OR (?3 AND s.ws IS NULL)
  #|ORDER BY d.created_at, d.id

///|
let decision_scoped_repair_legacy_sql : String =
  #|WITH RECURSIVE
  #|session_state AS MATERIALIZED (SELECT complete FROM legacy_decision_session_repair_meta WHERE id=1),
  #|index_state AS MATERIALIZED (
  #|  SELECT complete, EXISTS (SELECT 1 FROM sqlite_master WHERE type='index' AND name='decision_checks_at') AS has_old
  #|  FROM legacy_decision_time_meta WHERE id=1
  #|),
  #|recent AS MATERIALIZED (
  #|  SELECT id FROM (SELECT d.id FROM index_state i CROSS JOIN decision_checks d
  #|    WHERE i.complete=0 AND i.has_old AND ?3=0 AND d.created_at>=?1 LIMIT 65)
  #|  UNION ALL SELECT id FROM (SELECT d.id FROM index_state i CROSS JOIN legacy_decision_time d INDEXED BY legacy_decision_time_at
  #|    WHERE i.complete=1 AND ?3=0 AND d.created_at>=?1 LIMIT 65)
  #|),
  #|recent_count AS MATERIALIZED (
  #|  SELECT CASE WHEN i.complete=0 AND NOT i.has_old AND ?3=0 THEN 65
  #|    ELSE (SELECT COUNT(*) FROM recent) END AS n FROM index_state i
  #|),
  #|connects(connect, n) AS (
  #|  SELECT (SELECT connect FROM sessions INDEXED BY sessions_by_connect ORDER BY connect LIMIT 1), 1
  #|  WHERE (SELECT n FROM recent_count) = 65
  #|  UNION ALL
  #|  SELECT (SELECT connect FROM sessions INDEXED BY sessions_by_connect WHERE connect > c.connect ORDER BY connect LIMIT 1), n + 1
  #|  FROM connects c WHERE c.connect IS NOT NULL AND n < 65
  #|),
  #|chosen AS MATERIALIZED (
  #|  SELECT s.key FROM connects c CROSS JOIN sessions s INDEXED BY sessions_by_connect
  #|  WHERE c.connect IS NOT NULL AND s.connect = c.connect AND s.ws = ?2 LIMIT 65
  #|),
  #|lookups AS MATERIALIZED (
  #|  SELECT c.key, (SELECT id FROM (
  #|    SELECT d.id,d.created_at FROM session_state i CROSS JOIN legacy_decision_session_repair p INDEXED BY legacy_decision_session_repair_by_session
  #|  CROSS JOIN decision_checks d ON d.id=p.id WHERE i.complete=1 AND p.session=c.key ORDER BY p.id DESC LIMIT 65
  #|  ) WHERE created_at >= ?1 ORDER BY id DESC LIMIT 1) AS id
  #|  FROM chosen c WHERE (SELECT COUNT(connect) FROM connects) <= 64 AND (SELECT COUNT(*) FROM chosen) <= 64
  #|),
  #|mode AS MATERIALIZED (
  #|  SELECT (SELECT complete FROM session_state)=0 OR (SELECT n FROM recent_count) < 65 OR (SELECT COUNT(connect) FROM connects) > 64
  #|    OR (SELECT COUNT(*) FROM chosen) > 64 OR EXISTS (
  #|      SELECT 1 FROM lookups l WHERE l.id IS NULL AND EXISTS (
  #|        SELECT 1 FROM session_state i CROSS JOIN legacy_decision_session_repair p INDEXED BY legacy_decision_session_repair_by_session
  #|  WHERE i.complete=1 AND p.session=l.key ORDER BY p.id DESC LIMIT 1 OFFSET 64
  #|      )
  #|    ) AS use_global
  #|),
  #|latest AS MATERIALIZED (
  #|  SELECT MAX(d.id) AS id,d.session FROM mode CROSS JOIN index_state i CROSS JOIN decision_checks d
  #|    WHERE use_global AND i.complete=0 AND d.created_at>=?1 GROUP BY +d.session
  #|  UNION ALL SELECT MAX(d.id) AS id,d.session FROM mode CROSS JOIN index_state i
  #|    CROSS JOIN legacy_decision_time d INDEXED BY legacy_decision_time_at
  #|    WHERE use_global AND i.complete=1 AND d.created_at>=?1 GROUP BY +d.session
  #|  UNION ALL
  #|  SELECT id, key AS session FROM lookups WHERE id IS NOT NULL AND NOT (SELECT use_global FROM mode)
  #|)
  #|SELECT d.id, d.session, d.created_at, d.result FROM latest l
  #|LEFT JOIN sessions s ON s.key = l.session
  #|CROSS JOIN decision_checks d ON d.id = l.id
  #|WHERE s.ws = ?2 OR (?3 AND s.ws IS NULL)
  #|ORDER BY d.created_at, d.id

///|
let decision_scoped_repair_no_time_sql : String =
  #|WITH RECURSIVE
  #|session_state AS MATERIALIZED (SELECT complete FROM legacy_decision_session_repair_meta WHERE id=1),
  #|
  #|recent AS MATERIALIZED (
  #|  SELECT NULL AS id WHERE 0
  #|),
  #|
  #|connects(connect, n) AS (
  #|  SELECT (SELECT connect FROM sessions INDEXED BY sessions_by_connect ORDER BY connect LIMIT 1), 1
  #|  WHERE 65 = 65
  #|  UNION ALL
  #|  SELECT (SELECT connect FROM sessions INDEXED BY sessions_by_connect WHERE connect > c.connect ORDER BY connect LIMIT 1), n + 1
  #|  FROM connects c WHERE c.connect IS NOT NULL AND n < 65
  #|),
  #|chosen AS MATERIALIZED (
  #|  SELECT s.key FROM connects c CROSS JOIN sessions s INDEXED BY sessions_by_connect
  #|  WHERE c.connect IS NOT NULL AND s.connect = c.connect AND s.ws = ?2 LIMIT 65
  #|),
  #|lookups AS MATERIALIZED (
  #|  SELECT c.key, (SELECT id FROM (
  #|    SELECT d.id,d.created_at FROM session_state i CROSS JOIN legacy_decision_session_repair p INDEXED BY legacy_decision_session_repair_by_session
  #|  CROSS JOIN decision_checks d ON d.id=p.id WHERE i.complete=1 AND p.session=c.key ORDER BY p.id DESC LIMIT 65
  #|  ) WHERE created_at >= ?1 ORDER BY id DESC LIMIT 1) AS id
  #|  FROM chosen c WHERE (SELECT COUNT(connect) FROM connects) <= 64 AND (SELECT COUNT(*) FROM chosen) <= 64
  #|),
  #|mode AS MATERIALIZED (
  #|  SELECT (SELECT complete FROM session_state)=0 OR 65 < 65 OR (SELECT COUNT(connect) FROM connects) > 64
  #|    OR (SELECT COUNT(*) FROM chosen) > 64 OR EXISTS (
  #|      SELECT 1 FROM lookups l WHERE l.id IS NULL AND EXISTS (
  #|        SELECT 1 FROM session_state i CROSS JOIN legacy_decision_session_repair p INDEXED BY legacy_decision_session_repair_by_session
  #|  WHERE i.complete=1 AND p.session=l.key ORDER BY p.id DESC LIMIT 1 OFFSET 64
  #|      )
  #|    ) AS use_global
  #|),
  #|latest AS MATERIALIZED (
  #|  SELECT MAX(id) AS id, session FROM mode CROSS JOIN decision_checks WHERE use_global AND created_at >= ?1 GROUP BY +session
  #|  UNION ALL
  #|  SELECT id, key AS session FROM lookups WHERE id IS NOT NULL AND NOT (SELECT use_global FROM mode)
  #|)
  #|SELECT d.id, d.session, d.created_at, d.result FROM latest l
  #|LEFT JOIN sessions s ON s.key = l.session
  #|CROSS JOIN decision_checks d ON d.id = l.id
  #|WHERE s.ws = ?2 OR (?3 AND s.ws IS NULL)
  #|ORDER BY d.created_at, d.id

///|
let last_message_sql : String =
  #|SELECT * FROM merged WHERE thread = ?1 AND n = (
  #|  SELECT MAX(n) FROM (
  #|    SELECT (SELECT n FROM entries INDEXED BY entries_said WHERE thread = ?1 AND kind = 'message' AND letter IS NULL ORDER BY n DESC LIMIT 1) AS n
  #|    UNION ALL SELECT (SELECT n FROM entries WHERE thread = ?1 AND kind = 'message' AND letter IS NOT NULL ORDER BY n DESC LIMIT 1)
  #|  )
  #|)

///|
let legacy_last_message_sql : String =
  #|SELECT * FROM merged WHERE thread = ?1 AND n = (
  #|  SELECT MAX(n) FROM (
  #|    SELECT (SELECT n FROM (WITH dirty_latest AS MATERIALIZED (
  #|    SELECT e.n,e.author_kind,e.author FROM legacy_said_meta m CROSS JOIN legacy_said_dirty d
  #|      CROSS JOIN entries e ON e.thread=d.thread AND e.n=d.n
  #|    WHERE m.id=1 AND m.scanned=1 AND d.thread=?1 AND e.kind='message' AND e.letter IS NULL
  #|    ORDER BY d.n DESC LIMIT 1
  #|  )
  #|  SELECT n,author_kind,author FROM dirty_latest
  #|  UNION ALL
  #|  SELECT n,author_kind,author FROM (
  #|    SELECT s.n,s.author_kind,s.author FROM legacy_said_meta m CROSS JOIN legacy_said_build s
  #|    WHERE m.id=1 AND m.scanned=1 AND s.thread=?1
  #|      AND s.n >= COALESCE((SELECT n FROM dirty_latest), -9223372036854775808)
  #|      AND NOT EXISTS (SELECT 1 FROM legacy_said_dirty d WHERE d.thread=s.thread AND d.n=s.n)
  #|    ORDER BY s.n DESC LIMIT 1
  #|  )
  #|  UNION ALL
  #|  SELECT n,author_kind,author FROM (
  #|    SELECT e.n,e.author_kind,e.author FROM legacy_said_meta m CROSS JOIN entries e
  #|    WHERE m.id=1 AND m.scanned=0 AND e.thread=?1 AND e.kind='message' AND e.letter IS NULL
  #|    ORDER BY e.n DESC LIMIT 1
  #|  )
  #|  ORDER BY n DESC LIMIT 1)) AS n
  #|    UNION ALL SELECT (SELECT n FROM entries WHERE thread = ?1 AND kind = 'message' AND letter IS NOT NULL ORDER BY n DESC LIMIT 1)
  #|  )
  #|)

///|
let messages_before_sql : String =
  #|SELECT * FROM merged WHERE thread = ?1 AND n IN (
  #|  SELECT n FROM entries INDEXED BY entries_said
  #|    WHERE thread = ?1 AND n < ?2 AND kind = 'message' AND letter IS NULL
  #|  UNION ALL
  #|  SELECT n FROM entries
  #|    WHERE thread = ?1 AND n < ?2 AND kind = 'message' AND letter IS NOT NULL
  #|  ORDER BY n DESC LIMIT ?3) ORDER BY n DESC

///|
let legacy_messages_before_sql : String =
  #|SELECT * FROM merged WHERE thread = ?1 AND n IN (
  #|  SELECT n FROM legacy_said WHERE thread = ?1 AND n < ?2
  #|  UNION ALL
  #|  SELECT n FROM entries WHERE thread = ?1 AND n < ?2 AND kind = 'message' AND letter IS NOT NULL
  #|  ORDER BY n DESC LIMIT ?3) ORDER BY n DESC

///|
let message_page_entries_sql : String =
  #|SELECT e.* FROM json_each(?2) j
  #|  CROSS JOIN entries e ON e.thread=?1 AND e.n=CAST(j.value AS INTEGER) ORDER BY e.n

///|
let people_at_sql : String =
  #|SELECT p.author, e.at FROM thread_people p JOIN entries e ON e.thread = p.thread AND e.n = p.first_n WHERE p.thread = ?

///|
let letter_sql_sql : String =
  #|(letter IS NOT NULL)

///|
let answer_after_sql : String =
  #|SELECT 1 AS x FROM entries p WHERE p.thread = ?1 AND p.kind = 'message' AND p.author_kind = 'person'
  #|  AND p.n > ?2 AND ((SELECT surface FROM threads WHERE id = ?1) = 'chat' OR EXISTS (SELECT 1 FROM deliveries d WHERE d.thread = ?1 AND d.n = p.n)) LIMIT 1

///|
let answer_between_sql : String =
  #|SELECT 1 AS x FROM entries p WHERE p.thread = ?1 AND p.kind = 'message' AND p.author_kind = 'person'
  #|  AND p.n > ?2 AND p.n < ?3 AND ((SELECT surface FROM threads WHERE id = ?1) = 'chat' OR EXISTS (SELECT 1 FROM deliveries d WHERE d.thread = ?1 AND d.n = p.n)) LIMIT 1

///|
let answer_at_sql : String =
  #|SELECT 1 AS x FROM entries p WHERE p.thread = ?1 AND p.n = ?2 AND p.kind = 'message' AND p.author_kind = 'person'
  #|  AND ((SELECT surface FROM threads WHERE id = ?1) = 'chat' OR EXISTS (SELECT 1 FROM deliveries d WHERE d.thread = ?1 AND d.n = ?2))

///|
let conversation_card_before_sql : String =
  #|SELECT c.n AS n FROM card_posts c JOIN entries e ON e.thread = c.thread AND e.n = c.n
  #|  WHERE c.thread = ?1 AND c.n < ?2 AND NOT (CASE WHEN e.card IS NULL OR NOT json_valid(e.card) THEN 0 ELSE COALESCE(json_extract(e.card, '$.type') = 'login' OR json_type(e.card, '$.vault') = 'object' OR json_type(e.card, '$.adb') = 'object' OR json_type(e.card, '$.rig') = 'object' OR json_type(e.card, '$.signin') = 'object', 0) END) ORDER BY c.n DESC LIMIT 1

///|
let conversation_card_latest_sql : String =
  #|SELECT c.n AS n FROM card_posts c JOIN entries e ON e.thread = c.thread AND e.n = c.n
  #|  WHERE c.thread = ?1 AND NOT (CASE WHEN e.card IS NULL OR NOT json_valid(e.card) THEN 0 ELSE COALESCE(json_extract(e.card, '$.type') = 'login' OR json_type(e.card, '$.vault') = 'object' OR json_type(e.card, '$.adb') = 'object' OR json_type(e.card, '$.rig') = 'object' OR json_type(e.card, '$.signin') = 'object', 0) END) ORDER BY c.n DESC LIMIT 1

///|
let system_card_waiting_sql : String =
  #|SELECT s.n AS n FROM pending_system_cards s WHERE s.thread = ?1
  #|  AND NOT EXISTS (SELECT 1 FROM closed_cards c WHERE c.thread = s.thread AND c.n = s.n) ORDER BY s.n DESC LIMIT 1

///|
let system_card_at_sql : String =
  #|SELECT 1 AS x FROM entries e WHERE e.thread = ?1 AND e.n = ?2 AND e.kind = 'message' AND (CASE WHEN e.card IS NULL OR NOT json_valid(e.card) THEN 0 ELSE COALESCE(json_extract(e.card, '$.type') = 'login' OR json_type(e.card, '$.vault') = 'object' OR json_type(e.card, '$.adb') = 'object' OR json_type(e.card, '$.rig') = 'object' OR json_type(e.card, '$.signin') = 'object', 0) END)

///|
let system_card_kept_sql : String =
  #|SELECT 1 AS x FROM pending_system_cards WHERE thread = ?1 AND n = ?2

///|
let asked_latest_sql : String =
  #|SELECT n FROM entries WHERE thread = ? AND kind = 'message' AND author_kind = 'agent' AND at <= ? ORDER BY at DESC LIMIT 1

///|
let system_card_of_card_sql : String =
  #|(CASE WHEN card IS NULL OR NOT json_valid(card) THEN 0 ELSE COALESCE(json_extract(card, '$.type') = 'login' OR json_type(card, '$.vault') = 'object' OR json_type(card, '$.adb') = 'object' OR json_type(card, '$.rig') = 'object' OR json_type(card, '$.signin') = 'object', 0) END)

///|
let system_card_of_e_card_sql : String =
  #|(CASE WHEN e.card IS NULL OR NOT json_valid(e.card) THEN 0 ELSE COALESCE(json_extract(e.card, '$.type') = 'login' OR json_type(e.card, '$.vault') = 'object' OR json_type(e.card, '$.adb') = 'object' OR json_type(e.card, '$.rig') = 'object' OR json_type(e.card, '$.signin') = 'object', 0) END)

///|
let said_latest_sql : String =
  #|SELECT n, author_kind, author FROM entries INDEXED BY entries_said WHERE thread = ?1 AND kind = 'message' AND letter IS NULL ORDER BY n DESC LIMIT 1

///|
let said_state_sql : String =
  #|SELECT s.said_n, s.said_other_n, s.said_other_known,
  #|    g.author AS guard_author, g.other_n AS guard_other_n, g.ready AS guard_ready
  #|  FROM thread_state s LEFT JOIN said_state_guard g ON g.thread = s.thread WHERE s.thread = ?1
  #|  UNION ALL SELECT NULL, NULL, NULL, g.author, g.other_n, g.ready FROM said_state_guard g
  #|    WHERE g.thread = ?1 AND NOT EXISTS (SELECT 1 FROM thread_state s WHERE s.thread = ?1) LIMIT 1

///|
let said_scan_sql : String =
  #|SELECT n, author_kind, author FROM entries INDEXED BY entries_said
  #|  WHERE thread = ?1 AND kind = 'message' AND letter IS NULL AND n < ?2 ORDER BY n DESC LIMIT ?3

///|
let legacy_said_latest_sql : String =
  #|WITH dirty_latest AS MATERIALIZED (
  #|    SELECT e.n,e.author_kind,e.author FROM legacy_said_meta m CROSS JOIN legacy_said_dirty d
  #|      CROSS JOIN entries e ON e.thread=d.thread AND e.n=d.n
  #|    WHERE m.id=1 AND m.scanned=1 AND d.thread=?1 AND e.kind='message' AND e.letter IS NULL
  #|    ORDER BY d.n DESC LIMIT 1
  #|  )
  #|  SELECT n,author_kind,author FROM dirty_latest
  #|  UNION ALL
  #|  SELECT n,author_kind,author FROM (
  #|    SELECT s.n,s.author_kind,s.author FROM legacy_said_meta m CROSS JOIN legacy_said_build s
  #|    WHERE m.id=1 AND m.scanned=1 AND s.thread=?1
  #|      AND s.n >= COALESCE((SELECT n FROM dirty_latest), -9223372036854775808)
  #|      AND NOT EXISTS (SELECT 1 FROM legacy_said_dirty d WHERE d.thread=s.thread AND d.n=s.n)
  #|    ORDER BY s.n DESC LIMIT 1
  #|  )
  #|  UNION ALL
  #|  SELECT n,author_kind,author FROM (
  #|    SELECT e.n,e.author_kind,e.author FROM legacy_said_meta m CROSS JOIN entries e
  #|    WHERE m.id=1 AND m.scanned=0 AND e.thread=?1 AND e.kind='message' AND e.letter IS NULL
  #|    ORDER BY e.n DESC LIMIT 1
  #|  )
  #|  ORDER BY n DESC LIMIT 1

///|
let legacy_said_scan_sql : String =
  #|SELECT n, author_kind, author FROM legacy_said WHERE thread = ?1 AND n < ?2 ORDER BY n DESC LIMIT ?3

///|
let legacy_said_needs_drain_sql : String =
  #|SELECT 1 FROM legacy_said_meta m WHERE m.id=1 AND m.scanned=1 AND EXISTS (
  #|    SELECT 1 FROM legacy_said_dirty WHERE thread=?1 LIMIT 1 OFFSET 64)

///|
let legacy_said_head_first_sql : String =
  #|SELECT CASE WHEN e.kind='message' AND e.letter IS NULL THEN e.n END AS n,
  #|    CASE WHEN e.kind='message' AND e.letter IS NULL THEN e.author_kind END AS author_kind,
  #|    CASE WHEN e.kind='message' AND e.letter IS NULL THEN e.author END AS author
  #|    FROM entries e WHERE e.thread=? ORDER BY e.n DESC LIMIT 1

///|
let legacy_said_head_tail_sql : String =
  #|WITH tail AS MATERIALIZED (
  #|      SELECT n,kind,letter,author_kind,author FROM entries WHERE thread=? ORDER BY n DESC LIMIT 65
  #|    ), latest AS MATERIALIZED (
  #|      SELECT n,author_kind,author FROM tail WHERE kind='message' AND letter IS NULL ORDER BY n DESC LIMIT 1
  #|    ) SELECT (SELECT n FROM latest) AS n,(SELECT author_kind FROM latest) AS author_kind,
  #|      (SELECT author FROM latest) AS author,(SELECT COUNT(*) FROM tail) AS count

///|
let legacy_said_boundary_tail_sql : String =
  #|WITH tail AS MATERIALIZED (
  #|      SELECT n,kind,letter,author_kind,author FROM entries WHERE thread=?1 AND n<?2 ORDER BY n DESC LIMIT 65
  #|    ) SELECT (SELECT n FROM tail WHERE kind='message' AND letter IS NULL
  #|      AND NOT (author_kind='person' AND author=?3) ORDER BY n DESC LIMIT 1) AS n,
  #|      (SELECT COUNT(*) FROM tail) AS count

///|
let legacy_unread_sql : String =
  #|SELECT CASE WHEN (SELECT scanned FROM legacy_said_meta WHERE id=1)=0 THEN
  #|  (SELECT COUNT(*) FROM entries e WHERE e.thread=?1 AND e.n>?2 AND e.kind='message' AND e.letter IS NULL AND NOT (e.author_kind='person' AND e.author IN (SELECT value FROM json_each(?3))))
  #|  ELSE
  #|  (SELECT COUNT(*) FROM legacy_said_build s WHERE s.thread=?1 AND s.n>?2 AND NOT (s.author_kind='person' AND s.author IN (SELECT value FROM json_each(?3))))
  #|  - (SELECT COUNT(*) FROM legacy_said_dirty d CROSS JOIN legacy_said_build s ON s.thread=d.thread AND s.n=d.n
  #|      WHERE d.thread=?1 AND d.n>?2 AND NOT (s.author_kind='person' AND s.author IN (SELECT value FROM json_each(?3))))
  #|  + (SELECT COUNT(*) FROM legacy_said_dirty d CROSS JOIN entries e ON e.thread=d.thread AND e.n=d.n
  #|      WHERE d.thread=?1 AND d.n>?2 AND e.kind='message' AND e.letter IS NULL AND NOT (e.author_kind='person' AND e.author IN (SELECT value FROM json_each(?3)))) END AS c

///|
let legacy_asked_during_sql : String =
  #|SELECT MAX(n) AS n FROM (
  #|  SELECT e.n FROM legacy_agent_meta m CROSS JOIN entries e
  #|    WHERE m.id=1 AND m.scanned=0 AND e.thread=?1 AND e.kind='message' AND e.author_kind='agent' AND e.at>=?2 AND e.at<=?3
  #|  UNION ALL
  #|  SELECT s.n FROM legacy_agent_meta m CROSS JOIN legacy_agent_build s
  #|    WHERE m.id=1 AND m.scanned=1 AND s.thread=?1 AND s.at>=?2 AND s.at<=?3
  #|      AND NOT EXISTS (SELECT 1 FROM legacy_agent_dirty d WHERE d.thread=s.thread AND d.n=s.n)
  #|  UNION ALL
  #|  SELECT e.n FROM legacy_agent_meta m CROSS JOIN legacy_agent_times t
  #|    CROSS JOIN entries e ON e.thread=t.thread AND e.n=t.n
  #|    WHERE m.id=1 AND m.scanned=1 AND t.thread=?1 AND t.at>=?2 AND t.at<=?3
  #|      AND e.kind='message' AND e.author_kind='agent' AND e.at=t.at
  #|)

///|
let legacy_login_cards_sql : String =
  #|SELECT e.thread,e.n,e.author FROM login_card_meta m
  #|  CROSS JOIN entries e INDEXED BY entries_cards WHERE m.id=1 AND m.scanned=0 AND e.card IS NOT NULL
  #|    AND e.kind='message' AND e.author_kind='agent' AND e.card LIKE '%"login"%' AND e.card LIKE ?2
  #|    AND NOT EXISTS(SELECT 1 FROM closed_cards c WHERE c.thread=e.thread AND c.n=e.n)
  #|  UNION ALL
  #|  SELECT e.thread,e.n,e.author FROM login_card_meta m CROSS JOIN login_card_keys k
  #|    CROSS JOIN entries e ON e.thread=k.thread AND e.n=k.n WHERE m.id=1 AND m.scanned=1 AND k.login=?1
  #|    AND e.kind='message' AND e.author_kind='agent' AND e.card LIKE '%"login"%' AND e.card LIKE ?2
  #|    AND NOT EXISTS(SELECT 1 FROM closed_cards c WHERE c.thread=e.thread AND c.n=e.n)

///|
let legacy_login_cards_native_sql : String =
  #|SELECT e.thread,e.n,e.author FROM login_card_meta m
  #|  CROSS JOIN entries e INDEXED BY entries_login_cards WHERE m.id=1 AND m.scanned=0 AND e.card IS NOT NULL
  #|    AND e.kind='message' AND e.author_kind='agent' AND e.card LIKE '%"login"%' AND e.card LIKE ?2
  #|    AND NOT EXISTS(SELECT 1 FROM closed_cards c WHERE c.thread=e.thread AND c.n=e.n)
  #|  UNION ALL
  #|  SELECT e.thread,e.n,e.author FROM login_card_meta m CROSS JOIN login_card_keys k
  #|    CROSS JOIN entries e ON e.thread=k.thread AND e.n=k.n WHERE m.id=1 AND m.scanned=1 AND k.login=?1
  #|    AND e.kind='message' AND e.author_kind='agent' AND e.card LIKE '%"login"%' AND e.card LIKE ?2
  #|    AND NOT EXISTS(SELECT 1 FROM closed_cards c WHERE c.thread=e.thread AND c.n=e.n)

///|
let legacy_login_cards_fallback_sql : String =
  #|SELECT thread,n,author FROM entries INDEXED BY entries_cards
  #|  WHERE card IS NOT NULL AND kind='message' AND author_kind='agent' AND card LIKE '%"login"%' AND card LIKE ?
  #|    AND NOT EXISTS(SELECT 1 FROM closed_cards c WHERE c.thread=entries.thread AND c.n=entries.n)

///|
let legacy_card_edit_latest_old_index_sql : String =
  #|CASE WHEN (SELECT scanned FROM legacy_edit_meta WHERE id=1)=0 THEN
  #|    (SELECT x.n FROM entries x INDEXED BY entries_target WHERE x.thread=?1 AND x.target=?2 AND (x.kind='edit' AND x.card IS NOT NULL)
  #|      ORDER BY x.n DESC LIMIT 1)
  #|  WHEN NOT EXISTS (SELECT 1 FROM legacy_edit_dirty LIMIT 1) THEN
  #|    (SELECT s.n FROM legacy_edit_build s CROSS JOIN entries x ON x.thread=s.thread AND x.n=s.n
  #|      WHERE s.thread=?1 AND s.target=?2 AND (x.kind='edit' AND x.card IS NOT NULL) ORDER BY s.n DESC LIMIT 1)
  #|  WHEN NOT EXISTS (SELECT 1 FROM legacy_edit_targets t WHERE t.thread=?1 AND t.target=?2) THEN
  #|    (SELECT s.n FROM legacy_edit_build s CROSS JOIN entries x ON x.thread=s.thread AND x.n=s.n
  #|      WHERE s.thread=?1 AND s.target=?2 AND (x.kind='edit' AND x.card IS NOT NULL)
  #|        AND NOT EXISTS (SELECT 1 FROM legacy_edit_dirty d WHERE d.thread=s.thread AND d.n=s.n)
  #|      ORDER BY s.n DESC LIMIT 1)
  #|  ELSE (WITH witness AS MATERIALIZED (
  #|    SELECT x.n FROM entries x INDEXED BY entries_target WHERE x.thread=?1 AND x.target=?2 AND (x.kind='edit' AND x.card IS NOT NULL)
  #|      ORDER BY x.rowid DESC LIMIT 1
  #|  ), dirty_latest AS MATERIALIZED (
  #|    SELECT x.n FROM witness w CROSS JOIN legacy_edit_meta m CROSS JOIN legacy_edit_targets t
  #|      CROSS JOIN entries x ON x.thread=t.thread AND x.n=t.n
  #|    WHERE m.id=1 AND m.scanned=1 AND t.thread=?1 AND t.target=?2 AND x.target=t.target AND (x.kind='edit' AND x.card IS NOT NULL) AND t.n>=w.n
  #|    ORDER BY t.n DESC LIMIT 1
  #|  ) SELECT n FROM (
  #|    SELECT n FROM witness UNION ALL
  #|    SELECT n FROM dirty_latest
  #|    UNION ALL
  #|    SELECT n FROM (SELECT s.n FROM witness w CROSS JOIN legacy_edit_meta m CROSS JOIN legacy_edit_build s CROSS JOIN entries x ON x.thread=s.thread AND x.n=s.n
  #|      WHERE m.id=1 AND m.scanned=1 AND s.thread=?1 AND s.target=?2 AND (x.kind='edit' AND x.card IS NOT NULL)
  #|        AND s.n>=COALESCE((SELECT n FROM dirty_latest),w.n)
  #|        AND NOT EXISTS (SELECT 1 FROM legacy_edit_dirty d WHERE d.thread=s.thread AND d.n=s.n)
  #|      ORDER BY s.n DESC LIMIT 1)
  #|  ) ORDER BY n DESC LIMIT 1) END

///|
let legacy_card_edit_latest_sql : String =
  #|CASE WHEN (SELECT scanned FROM legacy_edit_meta WHERE id=1)=0 THEN
  #|    (SELECT x.n FROM entries x WHERE x.thread=?1 AND x.target=?2 AND (x.kind='edit' AND x.card IS NOT NULL)
  #|      ORDER BY x.n DESC LIMIT 1)
  #|  WHEN NOT EXISTS (SELECT 1 FROM legacy_edit_dirty LIMIT 1) THEN
  #|    (SELECT s.n FROM legacy_edit_build s CROSS JOIN entries x ON x.thread=s.thread AND x.n=s.n
  #|      WHERE s.thread=?1 AND s.target=?2 AND (x.kind='edit' AND x.card IS NOT NULL) ORDER BY s.n DESC LIMIT 1)
  #|  WHEN NOT EXISTS (SELECT 1 FROM legacy_edit_targets t WHERE t.thread=?1 AND t.target=?2) THEN
  #|    (SELECT s.n FROM legacy_edit_build s CROSS JOIN entries x ON x.thread=s.thread AND x.n=s.n
  #|      WHERE s.thread=?1 AND s.target=?2 AND (x.kind='edit' AND x.card IS NOT NULL)
  #|        AND NOT EXISTS (SELECT 1 FROM legacy_edit_dirty d WHERE d.thread=s.thread AND d.n=s.n)
  #|      ORDER BY s.n DESC LIMIT 1)
  #|  ELSE (WITH dirty_latest AS MATERIALIZED (
  #|    SELECT x.n FROM legacy_edit_meta m CROSS JOIN legacy_edit_targets t
  #|      CROSS JOIN entries x ON x.thread=t.thread AND x.n=t.n
  #|    WHERE m.id=1 AND m.scanned=1 AND t.thread=?1 AND t.target=?2 AND x.target=t.target AND (x.kind='edit' AND x.card IS NOT NULL)
  #|    ORDER BY t.n DESC LIMIT 1
  #|  ) SELECT n FROM (
  #|    
  #|    SELECT n FROM dirty_latest
  #|    UNION ALL
  #|    SELECT n FROM (SELECT s.n FROM legacy_edit_meta m CROSS JOIN legacy_edit_build s CROSS JOIN entries x ON x.thread=s.thread AND x.n=s.n
  #|      WHERE m.id=1 AND m.scanned=1 AND s.thread=?1 AND s.target=?2 AND (x.kind='edit' AND x.card IS NOT NULL)
  #|        AND s.n>=COALESCE((SELECT n FROM dirty_latest),-9223372036854775808)
  #|        AND NOT EXISTS (SELECT 1 FROM legacy_edit_dirty d WHERE d.thread=s.thread AND d.n=s.n)
  #|      ORDER BY s.n DESC LIMIT 1)
  #|  ) ORDER BY n DESC LIMIT 1) END

///|
let merged_legacy_old_index_sql : String =
  #|CREATE VIEW merged AS
  #|  SELECT m.thread, m.n, m.ts, m.author_kind, m.author,
  #|    CASE WHEN e.n IS NULL THEN m.text ELSE e.text END AS text,
  #|    CASE WHEN e.n IS NULL THEN m.attachments ELSE e.attachments END AS attachments,
  #|    CASE WHEN e.n IS NULL THEN m.quotes ELSE e.quotes END AS quotes,
  #|    m.declared, m.client, m.agent_identity, m.at AS created_at, e.at AS edited_at, m.letter
  #|  FROM entries m
  #|  LEFT JOIN entries e ON e.thread = m.thread
  #|    AND e.n = (CASE WHEN (SELECT scanned FROM legacy_edit_meta WHERE id=1)=0 THEN
  #|    (SELECT x.n FROM entries x INDEXED BY entries_target WHERE x.thread=m.thread AND x.target=m.n
  #|      ORDER BY x.n DESC LIMIT 1)
  #|  WHEN NOT EXISTS (SELECT 1 FROM legacy_edit_dirty LIMIT 1) THEN
  #|    (SELECT s.n FROM legacy_edit_build s
  #|      WHERE s.thread=m.thread AND s.target=m.n ORDER BY s.n DESC LIMIT 1)
  #|  WHEN NOT EXISTS (SELECT 1 FROM legacy_edit_targets t WHERE t.thread=m.thread AND t.target=m.n) THEN
  #|    (SELECT s.n FROM legacy_edit_build s
  #|      WHERE s.thread=m.thread AND s.target=m.n
  #|        AND NOT EXISTS (SELECT 1 FROM legacy_edit_dirty d WHERE d.thread=s.thread AND d.n=s.n)
  #|      ORDER BY s.n DESC LIMIT 1)
  #|  ELSE (WITH witness AS MATERIALIZED (
  #|    SELECT x.n FROM entries x INDEXED BY entries_target WHERE x.thread=m.thread AND x.target=m.n
  #|      ORDER BY x.rowid DESC LIMIT 1
  #|  ), dirty_latest AS MATERIALIZED (
  #|    SELECT x.n FROM witness w CROSS JOIN legacy_edit_meta m CROSS JOIN legacy_edit_targets t
  #|      CROSS JOIN entries x ON x.thread=t.thread AND x.n=t.n
  #|    WHERE m.id=1 AND m.scanned=1 AND t.thread=m.thread AND t.target=m.n AND x.target=t.target AND t.n>=w.n
  #|    ORDER BY t.n DESC LIMIT 1
  #|  ) SELECT n FROM (
  #|    SELECT n FROM witness UNION ALL
  #|    SELECT n FROM dirty_latest
  #|    UNION ALL
  #|    SELECT n FROM (SELECT s.n FROM witness w CROSS JOIN legacy_edit_meta m CROSS JOIN legacy_edit_build s
  #|      WHERE m.id=1 AND m.scanned=1 AND s.thread=m.thread AND s.target=m.n
  #|        AND s.n>=COALESCE((SELECT n FROM dirty_latest),w.n)
  #|        AND NOT EXISTS (SELECT 1 FROM legacy_edit_dirty d WHERE d.thread=s.thread AND d.n=s.n)
  #|      ORDER BY s.n DESC LIMIT 1)
  #|  ) ORDER BY n DESC LIMIT 1) END)
  #|  WHERE m.kind = 'message';

///|
let merged_legacy_sql : String =
  #|CREATE VIEW merged AS
  #|  SELECT m.thread, m.n, m.ts, m.author_kind, m.author,
  #|    CASE WHEN e.n IS NULL THEN m.text ELSE e.text END AS text,
  #|    CASE WHEN e.n IS NULL THEN m.attachments ELSE e.attachments END AS attachments,
  #|    CASE WHEN e.n IS NULL THEN m.quotes ELSE e.quotes END AS quotes,
  #|    m.declared, m.client, m.agent_identity, m.at AS created_at, e.at AS edited_at, m.letter
  #|  FROM entries m
  #|  LEFT JOIN entries e ON e.thread = m.thread
  #|    AND e.n = (CASE WHEN (SELECT scanned FROM legacy_edit_meta WHERE id=1)=0 THEN
  #|    (SELECT x.n FROM entries x WHERE x.thread=m.thread AND x.target=m.n
  #|      ORDER BY x.n DESC LIMIT 1)
  #|  WHEN NOT EXISTS (SELECT 1 FROM legacy_edit_dirty LIMIT 1) THEN
  #|    (SELECT s.n FROM legacy_edit_build s
  #|      WHERE s.thread=m.thread AND s.target=m.n ORDER BY s.n DESC LIMIT 1)
  #|  WHEN NOT EXISTS (SELECT 1 FROM legacy_edit_targets t WHERE t.thread=m.thread AND t.target=m.n) THEN
  #|    (SELECT s.n FROM legacy_edit_build s
  #|      WHERE s.thread=m.thread AND s.target=m.n
  #|        AND NOT EXISTS (SELECT 1 FROM legacy_edit_dirty d WHERE d.thread=s.thread AND d.n=s.n)
  #|      ORDER BY s.n DESC LIMIT 1)
  #|  ELSE (WITH dirty_latest AS MATERIALIZED (
  #|    SELECT x.n FROM legacy_edit_meta m CROSS JOIN legacy_edit_targets t
  #|      CROSS JOIN entries x ON x.thread=t.thread AND x.n=t.n
  #|    WHERE m.id=1 AND m.scanned=1 AND t.thread=m.thread AND t.target=m.n AND x.target=t.target
  #|    ORDER BY t.n DESC LIMIT 1
  #|  ) SELECT n FROM (
  #|    
  #|    SELECT n FROM dirty_latest
  #|    UNION ALL
  #|    SELECT n FROM (SELECT s.n FROM legacy_edit_meta m CROSS JOIN legacy_edit_build s
  #|      WHERE m.id=1 AND m.scanned=1 AND s.thread=m.thread AND s.target=m.n
  #|        AND s.n>=COALESCE((SELECT n FROM dirty_latest),-9223372036854775808)
  #|        AND NOT EXISTS (SELECT 1 FROM legacy_edit_dirty d WHERE d.thread=s.thread AND d.n=s.n)
  #|      ORDER BY s.n DESC LIMIT 1)
  #|  ) ORDER BY n DESC LIMIT 1) END)
  #|  WHERE m.kind = 'message';

///|
let merged_sql : String =
  #|CREATE VIEW merged AS
  #|  SELECT m.thread, m.n, m.ts, m.author_kind, m.author,
  #|    CASE WHEN e.n IS NULL THEN m.text ELSE e.text END AS text,
  #|    CASE WHEN e.n IS NULL THEN m.attachments ELSE e.attachments END AS attachments,
  #|    CASE WHEN e.n IS NULL THEN m.quotes ELSE e.quotes END AS quotes,
  #|    m.declared, m.client, m.agent_identity, m.at AS created_at, e.at AS edited_at, m.letter
  #|  FROM entries m
  #|  LEFT JOIN entries e ON e.thread = m.thread
  #|    AND e.n = (SELECT MAX(x.n) FROM entries x WHERE x.thread = m.thread AND x.target = m.n)
  #|  WHERE m.kind = 'message';

///|
let last_message_recent_edit_sql : String =
  #|WITH tail AS MATERIALIZED (
  #|    SELECT n,target FROM entries WHERE thread=?1 ORDER BY n DESC LIMIT 65
  #|  ) SELECT (SELECT CAST(n AS TEXT) FROM tail WHERE target=CAST(?2 AS INTEGER) ORDER BY n DESC LIMIT 1) AS n,
  #|    (SELECT COUNT(*) FROM tail) AS count

///|
let last_message_old_edits_sql : String =
  #|WITH edits AS MATERIALIZED (
  #|    SELECT x.n FROM entries x INDEXED BY entries_target WHERE x.thread=?1 AND x.target=CAST(?2 AS INTEGER)
  #|      ORDER BY x.rowid DESC LIMIT 65
  #|  ) SELECT CAST(MAX(n) AS TEXT) AS n,COUNT(*) AS count FROM edits

///|
let last_message_with_edit_sql : String =
  #|SELECT m.thread,m.n,m.ts,m.author_kind,m.author,
  #|    CASE WHEN e.n IS NULL THEN m.text ELSE e.text END AS text,
  #|    CASE WHEN e.n IS NULL THEN m.attachments ELSE e.attachments END AS attachments,
  #|    CASE WHEN e.n IS NULL THEN m.quotes ELSE e.quotes END AS quotes,
  #|    m.declared,m.client,m.agent_identity,m.at AS created_at,e.at AS edited_at,m.letter
  #|  FROM entries m LEFT JOIN entries e ON e.thread=m.thread AND e.n=CAST(?3 AS INTEGER)
  #|  WHERE m.thread=?1 AND m.n=CAST(?2 AS INTEGER) AND m.kind='message'

///|
let latest_thread_attempt_sql : String =
  #|WITH small AS MATERIALIZED (
  #|    SELECT thread FROM thread_sessions INDEXED BY thread_sessions_session WHERE session=?1 LIMIT 2
  #|  ), choice AS MATERIALIZED (
  #|    SELECT (SELECT version FROM latest_thread_meta WHERE id=1) AS version,
  #|      (SELECT COUNT(*) FROM small) AS members,
  #|      COALESCE((SELECT complete FROM latest_thread_scopes WHERE session=?1),0) AS ready
  #|  )
  #|  SELECT p.version AS _latest_version,p.members AS _latest_members,p.ready AS _latest_ready,t.*,ts.connect
  #|  FROM choice p LEFT JOIN thread_sessions ts ON ts.session=?1 AND ts.thread = CASE
  #|    WHEN p.ready=1 THEN (SELECT t2.id FROM latest_thread_rows r
  #|      CROSS JOIN thread_sessions m ON m.session=r.session AND m.thread=r.thread
  #|      CROSS JOIN threads t2 ON t2.id=r.thread WHERE r.session=?1
  #|      ORDER BY r.has_last DESC,r.last_delivery DESC,r.joined_at DESC,r.member_rowid DESC LIMIT 1)
  #|    WHEN p.members<2 THEN (SELECT thread FROM small LIMIT 1)
  #|    ELSE NULL END
  #|  LEFT JOIN threads t ON t.id=ts.thread

///|
let latest_threads_indexed_sql : String =
  #|SELECT t.*,m.connect FROM latest_thread_rows r
  #|  CROSS JOIN thread_sessions m ON m.session=r.session AND m.thread=r.thread
  #|  CROSS JOIN threads t ON t.id=r.thread WHERE r.session=?1
  #|  ORDER BY r.has_last DESC,r.last_delivery DESC,r.joined_at DESC,r.member_rowid DESC LIMIT ?2

///|
let session_chat_small_sql : String =
  #|WITH small AS MATERIALIZED
  #|  (SELECT thread FROM thread_sessions INDEXED BY thread_sessions_session WHERE session=?1 LIMIT 2)
  #|  SELECT (SELECT version FROM session_chat_meta WHERE id=1) AS _session_chat_version,
  #|    (SELECT COUNT(*) FROM small) AS _member_count,t.* FROM (SELECT 1) x
  #|  LEFT JOIN threads t ON (SELECT COUNT(*) FROM small)=1 AND t.id=(SELECT thread FROM small LIMIT 1)

///|
let session_chat_indexed_sql : String =
  #|SELECT t.* FROM session_chat_rows r
  #|  CROSS JOIN threads t ON t.id=r.thread WHERE r.session=?1
  #|  ORDER BY r.has_last DESC,r.last_at DESC,r.created_at DESC,r.thread DESC LIMIT 1


///|
let cc_session_keys_sql : String =
  #|SELECT CAST(thread AS TEXT) AS thread FROM cc_session_rows INDEXED BY cc_session_order
  #|  WHERE session=?1 AND surface != 'chat' ORDER BY last_at DESC,created_at DESC,cc_session_rows.thread DESC LIMIT 20

///|
let cc_indexed_threads_sql : String =
  #|SELECT t.*,o.connect FROM json_each(?1) c
  #|  CROSS JOIN threads t ON t.id=CAST(json_extract(c.value,'$[0]') AS INTEGER)
  #|  CROSS JOIN thread_sessions o ON o.thread=t.id AND o.session=json_extract(c.value,'$[1]')
  #|  WHERE t.surface != 'chat'
  #|  ORDER BY (SELECT e.at FROM thread_state st JOIN entries e ON e.thread=st.thread AND e.n=st.last_n
  #|    WHERE st.thread=t.id) DESC, t.created_at DESC, t.id DESC LIMIT 20

///|
let recent_chat_list_sql : String =
  #|SELECT t.id, COUNT(*) OVER () AS total FROM threads t
  #|  LEFT JOIN sessions h ON h.key = t.home
  #|  LEFT JOIN thread_state s ON s.thread = t.id
  #|  LEFT JOIN entries e ON e.thread = t.id AND e.n = s.said_n AND e.kind = 'message'
  #|  WHERE ?1 IS NULL OR CASE
  #|    WHEN t.home IS NOT NULL THEN COALESCE(h.ws, ?2) = ?1
  #|    WHEN NOT EXISTS (SELECT 1 FROM thread_sessions m WHERE m.thread = t.id) THEN ?2 = ?1
  #|    ELSE EXISTS (SELECT 1 FROM thread_sessions m LEFT JOIN sessions a ON a.key = m.session
  #|                 WHERE m.thread = t.id AND COALESCE(a.ws, ?2) = ?1)
  #|  END ORDER BY COALESCE(e.at, t.created_at) DESC, COALESCE(e.at, 0) DESC, t.created_at DESC, t.id DESC LIMIT ?3

///|
let search_chat_list_sql : String =
  #|SELECT t.*, e.at AS said_at,
  #|    CASE WHEN e.n IS NULL THEN NULL ELSE COALESCE((SELECT m.text FROM merged m WHERE m.thread = t.id AND m.n = s.said_n), '') END AS said_text,
  #|    (SELECT substr(m.text, 1, 300) FROM merged m WHERE m.thread = t.id AND m.n = s.person_n) AS first_text,
  #|    (SELECT json_group_array(json_object('session', x.session, 'connect', x.connect, 'joinedAt', x.joined_at,
  #|       'title', x.title, 'archivedAt', x.archived_at, 'ws', x.ws, 'present', x.present))
  #|     FROM (SELECT m.session, m.connect, m.joined_at, a.title, a.archived_at, a.ws, a.key IS NOT NULL AS present
  #|       FROM thread_sessions m LEFT JOIN sessions a ON a.key = m.session WHERE m.thread = t.id
  #|       ORDER BY m.joined_at, m.rowid) x) AS members
  #|  FROM threads t
  #|  LEFT JOIN sessions h ON h.key = t.home
  #|  LEFT JOIN thread_state s ON s.thread = t.id
  #|  LEFT JOIN entries e ON e.thread = t.id AND e.n = s.said_n AND e.kind = 'message'
  #|  WHERE ?1 IS NULL OR CASE
  #|    WHEN t.home IS NOT NULL THEN COALESCE(h.ws, ?2) = ?1
  #|    WHEN NOT EXISTS (SELECT 1 FROM thread_sessions m WHERE m.thread = t.id) THEN ?2 = ?1
  #|    ELSE EXISTS (SELECT 1 FROM thread_sessions m LEFT JOIN sessions a ON a.key = m.session
  #|                 WHERE m.thread = t.id AND COALESCE(a.ws, ?2) = ?1)
  #|  END ORDER BY COALESCE(e.at, t.created_at) DESC, COALESCE(e.at, 0) DESC, t.created_at DESC, t.id DESC


///|
let has_active_watch_sql : String =
  #|SELECT 1 FROM thread_sessions t
  #|  CROSS JOIN active_watch_jobs w INDEXED BY active_watch_jobs_session ON w.session = t.session
  #|  WHERE t.thread = ? LIMIT 1

///|
let has_session_active_watch_sql : String =
  #|SELECT 1 FROM active_watch_jobs INDEXED BY active_watch_jobs_session WHERE session = ? LIMIT 1

///|
let has_active_watch_before_upgrade_sql : String =
  #|SELECT 1 FROM thread_sessions t
  #|  CROSS JOIN jobs j INDEXED BY jobs_by_session ON j.session_key = t.session
  #|  WHERE t.thread = ? AND j.state = 'running' AND j.watch <> 0 LIMIT 1

///|
let has_session_active_watch_before_upgrade_sql : String =
  #|SELECT 1 FROM jobs INDEXED BY jobs_by_session
  #|  WHERE session_key = ? AND state = 'running' AND watch <> 0 LIMIT 1

///|
let workspace_activity_sql : String =
  #|SELECT s.* FROM workspace_activity a
  #|  CROSS JOIN sessions s ON s.key = a.session
  #|  WHERE a.ws = ? AND s.ws = a.ws

///|
let archive_pin_exists_sql : String =
  #|SELECT 1 FROM archive_pin_rows WHERE session = ? LIMIT 1

///|
let archive_keep_exists_sql : String =
  #|SELECT 1 FROM archive_keep_rows WHERE thread = ? LIMIT 1

///|
let archive_policy_sql : String =
  #|SELECT id, at, policy, author, summary FROM archive_policy WHERE ws IS ? ORDER BY id DESC LIMIT 1

///|
let legacy_archive_policy_sql : String =
  #|SELECT p.id,p.at,p.policy,p.author,p.summary FROM archive_policy p WHERE p.id = CASE
  #|  WHEN (SELECT complete FROM archive_policy_lookup_meta WHERE id=1)=1 THEN
  #|    (SELECT k.id FROM archive_policy_lookup k INDEXED BY archive_policy_lookup_ws WHERE k.ws IS ?1 ORDER BY k.id DESC LIMIT 1)
  #|  ELSE (SELECT q.id FROM archive_policy q WHERE q.ws IS ?1 ORDER BY q.id DESC LIMIT 1) END

///|
let legacy_last_decision_shared_sql : String =
  #|SELECT d.result FROM legacy_decision_time p INDEXED BY legacy_decision_time_by_session
  #|    CROSS JOIN decision_checks d ON d.id=p.id WHERE p.session=?1 ORDER BY p.id DESC LIMIT 1

///|
let legacy_last_decision_separate_sql : String =
  #|SELECT d.result FROM legacy_decision_session p INDEXED BY legacy_decision_session_by_session
  #|    CROSS JOIN decision_checks d ON d.id=p.id WHERE p.session=?1 ORDER BY p.id DESC LIMIT 1

///|
let legacy_last_decision_repair_sql : String =
  #|SELECT d.result FROM legacy_decision_session_repair p
  #|  INDEXED BY legacy_decision_session_repair_by_session CROSS JOIN decision_checks d ON d.id=p.id
  #|  WHERE p.session=?1 ORDER BY p.id DESC LIMIT 1

///|
let archive_last_first_sql : String =
  #|SELECT CASE WHEN e.kind='message' THEN CAST(e.n AS TEXT) END AS n,
  #|    CASE WHEN e.kind='message' THEN e.at END AS at
  #|  FROM entries e WHERE e.thread=? ORDER BY e.n DESC LIMIT 1

///|
let archive_last_guard_sql : String =
  #|SELECT CAST(g.before_n AS TEXT) AS n,g.at FROM archive_last_meta m CROSS JOIN archive_last_guard g
  #|  WHERE m.id=1 AND g.thread=? AND g.epoch=m.epoch AND g.ready=1

///|
let archive_last_tail_sql : String =
  #|WITH tail AS MATERIALIZED (
  #|    SELECT e.n,e.kind,e.at FROM entries e WHERE e.thread=? ORDER BY e.n DESC LIMIT 65
  #|  ), last AS MATERIALIZED (SELECT n,at FROM tail WHERE kind='message' ORDER BY n DESC LIMIT 1)
  #|  SELECT (SELECT CAST(n AS TEXT) FROM last) AS n,(SELECT at FROM last) AS at,(SELECT COUNT(*) FROM tail) AS count


///|
let widget_before_gate_old_index_sql : String =
  #|CREATE VIEW widget_source_before_gate(thread,n,kind,target,ts,entry_rowid,attachments) AS
  #|  SELECT NULL,NULL,NULL,NULL,NULL,NULL,NULL WHERE 0;
  #|  CREATE TRIGGER widget_source_before_gate_run INSTEAD OF INSERT ON widget_source_before_gate
  #|    BEGIN DELETE FROM widget_source_changed WHERE thread IS NOT NULL;
  #|  INSERT INTO widget_source_changed (thread, n, existed, attachments, at, dirty)
  #|    SELECT k.thread, k.n, m.n IS NOT NULL, m.attachments, m.created_at, 0
  #|    FROM (SELECT NEW.thread AS thread, NEW.n AS n WHERE NEW.kind = 'message'
  #|  UNION SELECT NEW.thread, NEW.target WHERE NEW.target IS NOT NULL UNION SELECT e.thread, e.n FROM entries e WHERE e.thread = NEW.thread AND e.n = NEW.n AND e.kind = 'message'
  #|  UNION SELECT e.thread, e.target FROM entries e WHERE e.thread = NEW.thread AND e.n = NEW.n AND e.target IS NOT NULL
  #|  UNION SELECT e.thread, e.n FROM entries e WHERE NEW.ts IS NOT NULL AND e.thread = NEW.thread AND e.ts = NEW.ts AND e.kind = 'message'
  #|  UNION SELECT e.thread, e.target FROM entries e WHERE NEW.ts IS NOT NULL AND e.thread = NEW.thread AND e.ts = NEW.ts AND e.target IS NOT NULL
  #|  UNION SELECT e.thread, e.n FROM entries e WHERE e.rowid = NEW.entry_rowid AND e.kind = 'message'
  #|  UNION SELECT e.thread, e.target FROM entries e WHERE e.rowid = NEW.entry_rowid AND e.target IS NOT NULL) k
  #|    LEFT JOIN merged m ON m.thread = k.thread AND m.n = k.n
  #|    WHERE EXISTS (SELECT 1 FROM widget_source_scopes s WHERE s.thread=k.thread) AND ((NEW.kind = 'message' AND NEW.target IS NOT NULL)
  #|  OR (NEW.target IS NOT NULL AND EXISTS (SELECT 1 FROM merged m
  #|    WHERE m.thread=NEW.thread AND m.n=NEW.target AND m.attachments IS NOT NEW.attachments
  #|      AND COALESCE((CASE WHEN (SELECT scanned FROM legacy_edit_meta WHERE id=1)=0 THEN
  #|    (SELECT x.n FROM entries x INDEXED BY entries_target WHERE x.thread=NEW.thread AND x.target=NEW.target
  #|      ORDER BY x.n DESC LIMIT 1)
  #|  WHEN NOT EXISTS (SELECT 1 FROM legacy_edit_dirty LIMIT 1) THEN
  #|    (SELECT s.n FROM legacy_edit_build s
  #|      WHERE s.thread=NEW.thread AND s.target=NEW.target ORDER BY s.n DESC LIMIT 1)
  #|  WHEN NOT EXISTS (SELECT 1 FROM legacy_edit_targets t WHERE t.thread=NEW.thread AND t.target=NEW.target) THEN
  #|    (SELECT s.n FROM legacy_edit_build s
  #|      WHERE s.thread=NEW.thread AND s.target=NEW.target
  #|        AND NOT EXISTS (SELECT 1 FROM legacy_edit_dirty d WHERE d.thread=s.thread AND d.n=s.n)
  #|      ORDER BY s.n DESC LIMIT 1)
  #|  ELSE (WITH witness AS MATERIALIZED (
  #|    SELECT x.n FROM entries x INDEXED BY entries_target WHERE x.thread=NEW.thread AND x.target=NEW.target
  #|      ORDER BY x.rowid DESC LIMIT 1
  #|  ), dirty_latest AS MATERIALIZED (
  #|    SELECT x.n FROM witness w CROSS JOIN legacy_edit_meta m CROSS JOIN legacy_edit_targets t
  #|      CROSS JOIN entries x ON x.thread=t.thread AND x.n=t.n
  #|    WHERE m.id=1 AND m.scanned=1 AND t.thread=NEW.thread AND t.target=NEW.target AND x.target=t.target AND t.n>=w.n
  #|    ORDER BY t.n DESC LIMIT 1
  #|  ) SELECT n FROM (
  #|    SELECT n FROM witness UNION ALL
  #|    SELECT n FROM dirty_latest
  #|    UNION ALL
  #|    SELECT n FROM (SELECT s.n FROM witness w CROSS JOIN legacy_edit_meta m CROSS JOIN legacy_edit_build s
  #|      WHERE m.id=1 AND m.scanned=1 AND s.thread=NEW.thread AND s.target=NEW.target
  #|        AND s.n>=COALESCE((SELECT n FROM dirty_latest),w.n)
  #|        AND NOT EXISTS (SELECT 1 FROM legacy_edit_dirty d WHERE d.thread=s.thread AND d.n=s.n)
  #|      ORDER BY s.n DESC LIMIT 1)
  #|  ) ORDER BY n DESC LIMIT 1) END)<=NEW.n,1)))
  #|  OR EXISTS (SELECT 1 FROM entries e WHERE e.thread=NEW.thread AND e.n=NEW.n)
  #|  OR (NEW.ts IS NOT NULL AND EXISTS (SELECT 1 FROM entries e WHERE e.thread=NEW.thread AND e.ts=NEW.ts))
  #|  OR EXISTS (SELECT 1 FROM entries e WHERE e.rowid=NEW.entry_rowid)); END;

///|
let widget_before_gate_sql : String =
  #|CREATE VIEW widget_source_before_gate(thread,n,kind,target,ts,entry_rowid,attachments) AS
  #|  SELECT NULL,NULL,NULL,NULL,NULL,NULL,NULL WHERE 0;
  #|  CREATE TRIGGER widget_source_before_gate_run INSTEAD OF INSERT ON widget_source_before_gate
  #|    BEGIN DELETE FROM widget_source_changed WHERE thread IS NOT NULL;
  #|  INSERT INTO widget_source_changed (thread, n, existed, attachments, at, dirty)
  #|    SELECT k.thread, k.n, m.n IS NOT NULL, m.attachments, m.created_at, 0
  #|    FROM (SELECT NEW.thread AS thread, NEW.n AS n WHERE NEW.kind = 'message'
  #|  UNION SELECT NEW.thread, NEW.target WHERE NEW.target IS NOT NULL UNION SELECT e.thread, e.n FROM entries e WHERE e.thread = NEW.thread AND e.n = NEW.n AND e.kind = 'message'
  #|  UNION SELECT e.thread, e.target FROM entries e WHERE e.thread = NEW.thread AND e.n = NEW.n AND e.target IS NOT NULL
  #|  UNION SELECT e.thread, e.n FROM entries e WHERE NEW.ts IS NOT NULL AND e.thread = NEW.thread AND e.ts = NEW.ts AND e.kind = 'message'
  #|  UNION SELECT e.thread, e.target FROM entries e WHERE NEW.ts IS NOT NULL AND e.thread = NEW.thread AND e.ts = NEW.ts AND e.target IS NOT NULL
  #|  UNION SELECT e.thread, e.n FROM entries e WHERE e.rowid = NEW.entry_rowid AND e.kind = 'message'
  #|  UNION SELECT e.thread, e.target FROM entries e WHERE e.rowid = NEW.entry_rowid AND e.target IS NOT NULL) k
  #|    LEFT JOIN merged m ON m.thread = k.thread AND m.n = k.n
  #|    WHERE EXISTS (SELECT 1 FROM widget_source_scopes s WHERE s.thread=k.thread) AND ((NEW.kind = 'message' AND NEW.target IS NOT NULL)
  #|  OR (NEW.target IS NOT NULL AND EXISTS (SELECT 1 FROM merged m
  #|    WHERE m.thread=NEW.thread AND m.n=NEW.target AND m.attachments IS NOT NEW.attachments
  #|      AND COALESCE((CASE WHEN (SELECT scanned FROM legacy_edit_meta WHERE id=1)=0 THEN
  #|    (SELECT x.n FROM entries x WHERE x.thread=NEW.thread AND x.target=NEW.target
  #|      ORDER BY x.n DESC LIMIT 1)
  #|  WHEN NOT EXISTS (SELECT 1 FROM legacy_edit_dirty LIMIT 1) THEN
  #|    (SELECT s.n FROM legacy_edit_build s
  #|      WHERE s.thread=NEW.thread AND s.target=NEW.target ORDER BY s.n DESC LIMIT 1)
  #|  WHEN NOT EXISTS (SELECT 1 FROM legacy_edit_targets t WHERE t.thread=NEW.thread AND t.target=NEW.target) THEN
  #|    (SELECT s.n FROM legacy_edit_build s
  #|      WHERE s.thread=NEW.thread AND s.target=NEW.target
  #|        AND NOT EXISTS (SELECT 1 FROM legacy_edit_dirty d WHERE d.thread=s.thread AND d.n=s.n)
  #|      ORDER BY s.n DESC LIMIT 1)
  #|  ELSE (WITH dirty_latest AS MATERIALIZED (
  #|    SELECT x.n FROM legacy_edit_meta m CROSS JOIN legacy_edit_targets t
  #|      CROSS JOIN entries x ON x.thread=t.thread AND x.n=t.n
  #|    WHERE m.id=1 AND m.scanned=1 AND t.thread=NEW.thread AND t.target=NEW.target AND x.target=t.target
  #|    ORDER BY t.n DESC LIMIT 1
  #|  ) SELECT n FROM (
  #|    
  #|    SELECT n FROM dirty_latest
  #|    UNION ALL
  #|    SELECT n FROM (SELECT s.n FROM legacy_edit_meta m CROSS JOIN legacy_edit_build s
  #|      WHERE m.id=1 AND m.scanned=1 AND s.thread=NEW.thread AND s.target=NEW.target
  #|        AND s.n>=COALESCE((SELECT n FROM dirty_latest),-9223372036854775808)
  #|        AND NOT EXISTS (SELECT 1 FROM legacy_edit_dirty d WHERE d.thread=s.thread AND d.n=s.n)
  #|      ORDER BY s.n DESC LIMIT 1)
  #|  ) ORDER BY n DESC LIMIT 1) END)<=NEW.n,1)))
  #|  OR EXISTS (SELECT 1 FROM entries e WHERE e.thread=NEW.thread AND e.n=NEW.n)
  #|  OR (NEW.ts IS NOT NULL AND EXISTS (SELECT 1 FROM entries e WHERE e.thread=NEW.thread AND e.ts=NEW.ts))
  #|  OR EXISTS (SELECT 1 FROM entries e WHERE e.rowid=NEW.entry_rowid)); END;

///|
let widget_before_add_legacy_sql : String =
  #|CREATE TRIGGER widget_source_before_add BEFORE INSERT ON entries
  #|  WHEN EXISTS (SELECT 1 FROM widget_source_scopes s WHERE s.thread=NEW.thread)
  #|  OR EXISTS (SELECT 1 FROM entries e JOIN widget_source_scopes s ON s.thread=e.thread WHERE e.rowid=NEW.rowid)
  #|  OR EXISTS (SELECT 1 FROM widget_source_changed) BEGIN INSERT INTO widget_source_before_gate(thread,n,kind,target,ts,entry_rowid,attachments)
  #|        VALUES(NEW.thread,NEW.n,NEW.kind,NEW.target,NEW.ts,NEW.rowid,NEW.attachments); END;

///|
let widget_before_add_sql : String =
  #|CREATE TRIGGER widget_source_before_add BEFORE INSERT ON entries
  #|  WHEN EXISTS (SELECT 1 FROM widget_source_scopes s WHERE s.thread=NEW.thread)
  #|  OR EXISTS (SELECT 1 FROM entries e JOIN widget_source_scopes s ON s.thread=e.thread WHERE e.rowid=NEW.rowid)
  #|  OR EXISTS (SELECT 1 FROM widget_source_changed) BEGIN DELETE FROM widget_source_changed WHERE thread IS NOT NULL;
  #|  INSERT INTO widget_source_changed (thread, n, existed, attachments, at, dirty)
  #|    SELECT k.thread, k.n, m.n IS NOT NULL, m.attachments, m.created_at, 0
  #|    FROM (SELECT NEW.thread AS thread, NEW.n AS n WHERE NEW.kind = 'message'
  #|  UNION SELECT NEW.thread, NEW.target WHERE NEW.target IS NOT NULL UNION SELECT e.thread, e.n FROM entries e WHERE e.thread = NEW.thread AND e.n = NEW.n AND e.kind = 'message'
  #|  UNION SELECT e.thread, e.target FROM entries e WHERE e.thread = NEW.thread AND e.n = NEW.n AND e.target IS NOT NULL
  #|  UNION SELECT e.thread, e.n FROM entries e WHERE NEW.ts IS NOT NULL AND e.thread = NEW.thread AND e.ts = NEW.ts AND e.kind = 'message'
  #|  UNION SELECT e.thread, e.target FROM entries e WHERE NEW.ts IS NOT NULL AND e.thread = NEW.thread AND e.ts = NEW.ts AND e.target IS NOT NULL
  #|  UNION SELECT e.thread, e.n FROM entries e WHERE e.rowid = NEW.rowid AND e.kind = 'message'
  #|  UNION SELECT e.thread, e.target FROM entries e WHERE e.rowid = NEW.rowid AND e.target IS NOT NULL) k
  #|    LEFT JOIN merged m ON m.thread = k.thread AND m.n = k.n
  #|    WHERE EXISTS (SELECT 1 FROM widget_source_scopes s WHERE s.thread=k.thread) AND ((NEW.kind = 'message' AND NEW.target IS NOT NULL)
  #|  OR (NEW.target IS NOT NULL AND EXISTS (SELECT 1 FROM merged m
  #|    WHERE m.thread=NEW.thread AND m.n=NEW.target AND m.attachments IS NOT NEW.attachments
  #|      AND NOT EXISTS (SELECT 1 FROM entries x WHERE x.thread=NEW.thread AND x.target=NEW.target AND x.n>NEW.n)))
  #|  OR EXISTS (SELECT 1 FROM entries e WHERE e.thread=NEW.thread AND e.n=NEW.n)
  #|  OR (NEW.ts IS NOT NULL AND EXISTS (SELECT 1 FROM entries e WHERE e.thread=NEW.thread AND e.ts=NEW.ts))
  #|  OR EXISTS (SELECT 1 FROM entries e WHERE e.rowid=NEW.rowid)); END;

///|
let card_outbox_table_sql : String =
  #|CREATE TABLE IF NOT EXISTS card_outbox(thread INTEGER NOT NULL,ts TEXT NOT NULL,id INTEGER NOT NULL,
  #|        agent TEXT NOT NULL,field TEXT NOT NULL CHECK(field IN ('adb','rig','signin','vault')),
  #|        close_card INTEGER NOT NULL CHECK(close_card IN (0,1)),outcome TEXT NOT NULL,
  #|        PRIMARY KEY(thread,ts,id)) WITHOUT ROWID

///|
let card_outbox_wider_table_sql : String =
  #|CREATE TABLE IF NOT EXISTS card_outbox_wider(thread INTEGER NOT NULL,ts TEXT NOT NULL,id INTEGER NOT NULL,
  #|        agent TEXT NOT NULL,field TEXT NOT NULL CHECK(field IN ('adb','rig','signin','vault')),
  #|        close_card INTEGER NOT NULL CHECK(close_card IN (0,1)),outcome TEXT NOT NULL,
  #|        PRIMARY KEY(thread,ts,id)) WITHOUT ROWID

///|
let legacy_edits_schema_sql : String =
  #|
  #|      CREATE TABLE legacy_edit_meta(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL,scanned INTEGER NOT NULL,old_index INTEGER NOT NULL,
  #|        cursor_thread INTEGER,cursor_n INTEGER,end_thread INTEGER,end_n INTEGER) WITHOUT ROWID;
  #|      INSERT INTO legacy_edit_meta VALUES(1,1,0,0,NULL,NULL,
  #|        (SELECT thread FROM entries ORDER BY thread DESC,n DESC LIMIT 1),
  #|        (SELECT n FROM entries ORDER BY thread DESC,n DESC LIMIT 1));
  #|      CREATE TABLE legacy_edit_build(thread INTEGER NOT NULL,target INTEGER NOT NULL,n INTEGER NOT NULL,
  #|        PRIMARY KEY(thread,target,n)) WITHOUT ROWID;
  #|      CREATE TABLE legacy_edit_dirty(thread INTEGER NOT NULL,n INTEGER NOT NULL,old_target INTEGER,
  #|        PRIMARY KEY(thread,n)) WITHOUT ROWID;
  #|      CREATE TABLE legacy_edit_targets(thread INTEGER NOT NULL,target INTEGER NOT NULL,n INTEGER NOT NULL,
  #|        PRIMARY KEY(thread,target,n)) WITHOUT ROWID;
  #|      CREATE INDEX legacy_edit_targets_by_key ON legacy_edit_targets(thread,n,target);
  #|      CREATE TRIGGER legacy_edit_before_insert BEFORE INSERT ON entries WHEN NEW.target IS NOT NULL BEGIN INSERT INTO legacy_edit_dirty(thread,n,old_target)
  #|  SELECT NEW.thread,NEW.n,e.target FROM (SELECT 1) x LEFT JOIN entries e ON e.thread=NEW.thread AND e.n=NEW.n
  #|  WHERE NEW.thread IS NOT NULL AND NEW.n IS NOT NULL
  #|    AND NOT EXISTS (SELECT 1 FROM legacy_edit_dirty d WHERE d.thread=NEW.thread AND d.n=NEW.n);
  #|  INSERT INTO legacy_edit_targets(thread,target,n) SELECT NEW.thread,NEW.target,NEW.n
  #|  WHERE NEW.thread IS NOT NULL AND NEW.n IS NOT NULL AND NEW.target IS NOT NULL
  #|    AND NOT EXISTS (SELECT 1 FROM legacy_edit_targets x WHERE x.thread=NEW.thread AND x.target=NEW.target AND x.n=NEW.n); END;
  #|      CREATE TRIGGER legacy_edit_before_insert_conflict BEFORE INSERT ON entries WHEN (EXISTS (SELECT 1 FROM entries e WHERE e.thread=NEW.thread AND e.n=NEW.n AND e.target IS NOT NULL)
  #|  OR (NEW.ts IS NOT NULL AND EXISTS (SELECT 1 FROM entries e WHERE e.thread=NEW.thread AND e.ts=NEW.ts AND e.target IS NOT NULL))
  #|  OR EXISTS (SELECT 1 FROM entries e WHERE e.rowid=NEW.rowid AND e.target IS NOT NULL))
  #|        BEGIN INSERT INTO legacy_edit_dirty(thread,n,old_target)
  #|  SELECT k.thread,k.n,e.target FROM (SELECT e.thread,e.n FROM (
  #|  SELECT rowid AS id FROM entries WHERE thread=NEW.thread AND n=NEW.n
  #|  UNION SELECT rowid FROM entries INDEXED BY entries_ts WHERE NEW.ts IS NOT NULL AND thread=NEW.thread AND ts=NEW.ts
  #|  UNION SELECT rowid FROM entries WHERE rowid=NEW.rowid
  #|) p CROSS JOIN entries e ON e.rowid=p.id WHERE e.target IS NOT NULL) k LEFT JOIN entries e ON e.thread=k.thread AND e.n=k.n
  #|  WHERE k.thread IS NOT NULL AND k.n IS NOT NULL
  #|    AND NOT EXISTS (SELECT 1 FROM legacy_edit_dirty d WHERE d.thread=k.thread AND d.n=k.n);
  #|  INSERT INTO legacy_edit_targets(thread,target,n)
  #|    SELECT t.thread,t.target,t.n FROM (
  #|      SELECT e.thread,e.target,e.n FROM (SELECT e.thread,e.n FROM (
  #|  SELECT rowid AS id FROM entries WHERE thread=NEW.thread AND n=NEW.n
  #|  UNION SELECT rowid FROM entries INDEXED BY entries_ts WHERE NEW.ts IS NOT NULL AND thread=NEW.thread AND ts=NEW.ts
  #|  UNION SELECT rowid FROM entries WHERE rowid=NEW.rowid
  #|) p CROSS JOIN entries e ON e.rowid=p.id WHERE e.target IS NOT NULL) k JOIN entries e ON e.thread=k.thread AND e.n=k.n
  #|        WHERE e.target IS NOT NULL
  #|      
  #|    ) t WHERE t.thread IS NOT NULL AND t.n IS NOT NULL AND t.target IS NOT NULL
  #|      AND NOT EXISTS (SELECT 1 FROM legacy_edit_targets x WHERE x.thread=t.thread AND x.target=t.target AND x.n=t.n); END;
  #|      CREATE TRIGGER legacy_edit_before_update BEFORE UPDATE ON entries WHEN (OLD.thread IS NOT NEW.thread OR OLD.n IS NOT NEW.n OR OLD.rowid IS NOT NEW.rowid
  #|  OR OLD.target IS NOT NEW.target OR OLD.ts IS NOT NEW.ts) AND
  #|        (OLD.target IS NOT NULL OR NEW.target IS NOT NULL OR (EXISTS (SELECT 1 FROM entries e WHERE e.thread=NEW.thread AND e.n=NEW.n AND e.target IS NOT NULL)
  #|  OR (NEW.ts IS NOT NULL AND EXISTS (SELECT 1 FROM entries e WHERE e.thread=NEW.thread AND e.ts=NEW.ts AND e.target IS NOT NULL))
  #|  OR EXISTS (SELECT 1 FROM entries e WHERE e.rowid=NEW.rowid AND e.target IS NOT NULL)))
  #|        BEGIN INSERT INTO legacy_edit_dirty(thread,n,old_target)
  #|  SELECT k.thread,k.n,e.target FROM (SELECT OLD.thread AS thread,OLD.n AS n WHERE OLD.target IS NOT NULL UNION SELECT NEW.thread AS thread,NEW.n AS n WHERE NEW.target IS NOT NULL UNION SELECT e.thread,e.n FROM (
  #|  SELECT rowid AS id FROM entries WHERE thread=NEW.thread AND n=NEW.n
  #|  UNION SELECT rowid FROM entries INDEXED BY entries_ts WHERE NEW.ts IS NOT NULL AND thread=NEW.thread AND ts=NEW.ts
  #|  UNION SELECT rowid FROM entries WHERE rowid=NEW.rowid
  #|) p CROSS JOIN entries e ON e.rowid=p.id WHERE e.target IS NOT NULL) k LEFT JOIN entries e ON e.thread=k.thread AND e.n=k.n
  #|  WHERE k.thread IS NOT NULL AND k.n IS NOT NULL
  #|    AND NOT EXISTS (SELECT 1 FROM legacy_edit_dirty d WHERE d.thread=k.thread AND d.n=k.n);
  #|  INSERT INTO legacy_edit_targets(thread,target,n)
  #|    SELECT t.thread,t.target,t.n FROM (
  #|      SELECT e.thread,e.target,e.n FROM (SELECT OLD.thread AS thread,OLD.n AS n WHERE OLD.target IS NOT NULL UNION SELECT NEW.thread AS thread,NEW.n AS n WHERE NEW.target IS NOT NULL UNION SELECT e.thread,e.n FROM (
  #|  SELECT rowid AS id FROM entries WHERE thread=NEW.thread AND n=NEW.n
  #|  UNION SELECT rowid FROM entries INDEXED BY entries_ts WHERE NEW.ts IS NOT NULL AND thread=NEW.thread AND ts=NEW.ts
  #|  UNION SELECT rowid FROM entries WHERE rowid=NEW.rowid
  #|) p CROSS JOIN entries e ON e.rowid=p.id WHERE e.target IS NOT NULL) k JOIN entries e ON e.thread=k.thread AND e.n=k.n
  #|        WHERE e.target IS NOT NULL
  #|      UNION SELECT NEW.thread AS thread,NEW.target AS target,NEW.n AS n WHERE NEW.target IS NOT NULL
  #|    ) t WHERE t.thread IS NOT NULL AND t.n IS NOT NULL AND t.target IS NOT NULL
  #|      AND NOT EXISTS (SELECT 1 FROM legacy_edit_targets x WHERE x.thread=t.thread AND x.target=t.target AND x.n=t.n); END;
  #|      CREATE TRIGGER legacy_edit_before_delete BEFORE DELETE ON entries WHEN OLD.target IS NOT NULL BEGIN INSERT INTO legacy_edit_dirty(thread,n,old_target)
  #|  SELECT k.thread,k.n,e.target FROM (SELECT OLD.thread AS thread,OLD.n AS n WHERE OLD.target IS NOT NULL) k LEFT JOIN entries e ON e.thread=k.thread AND e.n=k.n
  #|  WHERE k.thread IS NOT NULL AND k.n IS NOT NULL
  #|    AND NOT EXISTS (SELECT 1 FROM legacy_edit_dirty d WHERE d.thread=k.thread AND d.n=k.n);
  #|  INSERT INTO legacy_edit_targets(thread,target,n)
  #|    SELECT t.thread,t.target,t.n FROM (
  #|      SELECT e.thread,e.target,e.n FROM (SELECT OLD.thread AS thread,OLD.n AS n WHERE OLD.target IS NOT NULL) k JOIN entries e ON e.thread=k.thread AND e.n=k.n
  #|        WHERE e.target IS NOT NULL
  #|      
  #|    ) t WHERE t.thread IS NOT NULL AND t.n IS NOT NULL AND t.target IS NOT NULL
  #|      AND NOT EXISTS (SELECT 1 FROM legacy_edit_targets x WHERE x.thread=t.thread AND x.target=t.target AND x.n=t.n); END;
  #|    

///|
let legacy_edits_schema_old_index_sql : String =
  #|
  #|      CREATE TABLE legacy_edit_meta(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL,scanned INTEGER NOT NULL,old_index INTEGER NOT NULL,
  #|        cursor_thread INTEGER,cursor_n INTEGER,end_thread INTEGER,end_n INTEGER) WITHOUT ROWID;
  #|      INSERT INTO legacy_edit_meta VALUES(1,1,0,1,NULL,NULL,
  #|        (SELECT thread FROM entries ORDER BY thread DESC,n DESC LIMIT 1),
  #|        (SELECT n FROM entries ORDER BY thread DESC,n DESC LIMIT 1));
  #|      CREATE TABLE legacy_edit_build(thread INTEGER NOT NULL,target INTEGER NOT NULL,n INTEGER NOT NULL,
  #|        PRIMARY KEY(thread,target,n)) WITHOUT ROWID;
  #|      CREATE TABLE legacy_edit_dirty(thread INTEGER NOT NULL,n INTEGER NOT NULL,old_target INTEGER,
  #|        PRIMARY KEY(thread,n)) WITHOUT ROWID;
  #|      CREATE TABLE legacy_edit_targets(thread INTEGER NOT NULL,target INTEGER NOT NULL,n INTEGER NOT NULL,
  #|        PRIMARY KEY(thread,target,n)) WITHOUT ROWID;
  #|      CREATE INDEX legacy_edit_targets_by_key ON legacy_edit_targets(thread,n,target);
  #|      CREATE TRIGGER legacy_edit_before_insert BEFORE INSERT ON entries WHEN NEW.target IS NOT NULL BEGIN INSERT INTO legacy_edit_dirty(thread,n,old_target)
  #|  SELECT NEW.thread,NEW.n,e.target FROM (SELECT 1) x LEFT JOIN entries e ON e.thread=NEW.thread AND e.n=NEW.n
  #|  WHERE NEW.thread IS NOT NULL AND NEW.n IS NOT NULL
  #|    AND NOT EXISTS (SELECT 1 FROM legacy_edit_dirty d WHERE d.thread=NEW.thread AND d.n=NEW.n);
  #|  INSERT INTO legacy_edit_targets(thread,target,n) SELECT NEW.thread,NEW.target,NEW.n
  #|  WHERE NEW.thread IS NOT NULL AND NEW.n IS NOT NULL AND NEW.target IS NOT NULL
  #|    AND NOT EXISTS (SELECT 1 FROM legacy_edit_targets x WHERE x.thread=NEW.thread AND x.target=NEW.target AND x.n=NEW.n); END;
  #|      CREATE TRIGGER legacy_edit_before_insert_conflict BEFORE INSERT ON entries WHEN (EXISTS (SELECT 1 FROM entries e WHERE e.thread=NEW.thread AND e.n=NEW.n AND e.target IS NOT NULL)
  #|  OR (NEW.ts IS NOT NULL AND EXISTS (SELECT 1 FROM entries e WHERE e.thread=NEW.thread AND e.ts=NEW.ts AND e.target IS NOT NULL))
  #|  OR EXISTS (SELECT 1 FROM entries e WHERE e.rowid=NEW.rowid AND e.target IS NOT NULL))
  #|        BEGIN INSERT INTO legacy_edit_dirty(thread,n,old_target)
  #|  SELECT k.thread,k.n,e.target FROM (SELECT e.thread,e.n FROM (
  #|  SELECT rowid AS id FROM entries WHERE thread=NEW.thread AND n=NEW.n
  #|  UNION SELECT rowid FROM entries INDEXED BY entries_ts WHERE NEW.ts IS NOT NULL AND thread=NEW.thread AND ts=NEW.ts
  #|  UNION SELECT rowid FROM entries WHERE rowid=NEW.rowid
  #|) p CROSS JOIN entries e ON e.rowid=p.id WHERE e.target IS NOT NULL) k LEFT JOIN entries e ON e.thread=k.thread AND e.n=k.n
  #|  WHERE k.thread IS NOT NULL AND k.n IS NOT NULL
  #|    AND NOT EXISTS (SELECT 1 FROM legacy_edit_dirty d WHERE d.thread=k.thread AND d.n=k.n);
  #|  INSERT INTO legacy_edit_targets(thread,target,n)
  #|    SELECT t.thread,t.target,t.n FROM (
  #|      SELECT e.thread,e.target,e.n FROM (SELECT e.thread,e.n FROM (
  #|  SELECT rowid AS id FROM entries WHERE thread=NEW.thread AND n=NEW.n
  #|  UNION SELECT rowid FROM entries INDEXED BY entries_ts WHERE NEW.ts IS NOT NULL AND thread=NEW.thread AND ts=NEW.ts
  #|  UNION SELECT rowid FROM entries WHERE rowid=NEW.rowid
  #|) p CROSS JOIN entries e ON e.rowid=p.id WHERE e.target IS NOT NULL) k JOIN entries e ON e.thread=k.thread AND e.n=k.n
  #|        WHERE e.target IS NOT NULL
  #|      
  #|    ) t WHERE t.thread IS NOT NULL AND t.n IS NOT NULL AND t.target IS NOT NULL
  #|      AND NOT EXISTS (SELECT 1 FROM legacy_edit_targets x WHERE x.thread=t.thread AND x.target=t.target AND x.n=t.n); END;
  #|      CREATE TRIGGER legacy_edit_before_update BEFORE UPDATE ON entries WHEN (OLD.thread IS NOT NEW.thread OR OLD.n IS NOT NEW.n OR OLD.rowid IS NOT NEW.rowid
  #|  OR OLD.target IS NOT NEW.target OR OLD.ts IS NOT NEW.ts) AND
  #|        (OLD.target IS NOT NULL OR NEW.target IS NOT NULL OR (EXISTS (SELECT 1 FROM entries e WHERE e.thread=NEW.thread AND e.n=NEW.n AND e.target IS NOT NULL)
  #|  OR (NEW.ts IS NOT NULL AND EXISTS (SELECT 1 FROM entries e WHERE e.thread=NEW.thread AND e.ts=NEW.ts AND e.target IS NOT NULL))
  #|  OR EXISTS (SELECT 1 FROM entries e WHERE e.rowid=NEW.rowid AND e.target IS NOT NULL)))
  #|        BEGIN INSERT INTO legacy_edit_dirty(thread,n,old_target)
  #|  SELECT k.thread,k.n,e.target FROM (SELECT OLD.thread AS thread,OLD.n AS n WHERE OLD.target IS NOT NULL UNION SELECT NEW.thread AS thread,NEW.n AS n WHERE NEW.target IS NOT NULL UNION SELECT e.thread,e.n FROM (
  #|  SELECT rowid AS id FROM entries WHERE thread=NEW.thread AND n=NEW.n
  #|  UNION SELECT rowid FROM entries INDEXED BY entries_ts WHERE NEW.ts IS NOT NULL AND thread=NEW.thread AND ts=NEW.ts
  #|  UNION SELECT rowid FROM entries WHERE rowid=NEW.rowid
  #|) p CROSS JOIN entries e ON e.rowid=p.id WHERE e.target IS NOT NULL) k LEFT JOIN entries e ON e.thread=k.thread AND e.n=k.n
  #|  WHERE k.thread IS NOT NULL AND k.n IS NOT NULL
  #|    AND NOT EXISTS (SELECT 1 FROM legacy_edit_dirty d WHERE d.thread=k.thread AND d.n=k.n);
  #|  INSERT INTO legacy_edit_targets(thread,target,n)
  #|    SELECT t.thread,t.target,t.n FROM (
  #|      SELECT e.thread,e.target,e.n FROM (SELECT OLD.thread AS thread,OLD.n AS n WHERE OLD.target IS NOT NULL UNION SELECT NEW.thread AS thread,NEW.n AS n WHERE NEW.target IS NOT NULL UNION SELECT e.thread,e.n FROM (
  #|  SELECT rowid AS id FROM entries WHERE thread=NEW.thread AND n=NEW.n
  #|  UNION SELECT rowid FROM entries INDEXED BY entries_ts WHERE NEW.ts IS NOT NULL AND thread=NEW.thread AND ts=NEW.ts
  #|  UNION SELECT rowid FROM entries WHERE rowid=NEW.rowid
  #|) p CROSS JOIN entries e ON e.rowid=p.id WHERE e.target IS NOT NULL) k JOIN entries e ON e.thread=k.thread AND e.n=k.n
  #|        WHERE e.target IS NOT NULL
  #|      UNION SELECT NEW.thread AS thread,NEW.target AS target,NEW.n AS n WHERE NEW.target IS NOT NULL
  #|    ) t WHERE t.thread IS NOT NULL AND t.n IS NOT NULL AND t.target IS NOT NULL
  #|      AND NOT EXISTS (SELECT 1 FROM legacy_edit_targets x WHERE x.thread=t.thread AND x.target=t.target AND x.n=t.n); END;
  #|      CREATE TRIGGER legacy_edit_before_delete BEFORE DELETE ON entries WHEN OLD.target IS NOT NULL BEGIN INSERT INTO legacy_edit_dirty(thread,n,old_target)
  #|  SELECT k.thread,k.n,e.target FROM (SELECT OLD.thread AS thread,OLD.n AS n WHERE OLD.target IS NOT NULL) k LEFT JOIN entries e ON e.thread=k.thread AND e.n=k.n
  #|  WHERE k.thread IS NOT NULL AND k.n IS NOT NULL
  #|    AND NOT EXISTS (SELECT 1 FROM legacy_edit_dirty d WHERE d.thread=k.thread AND d.n=k.n);
  #|  INSERT INTO legacy_edit_targets(thread,target,n)
  #|    SELECT t.thread,t.target,t.n FROM (
  #|      SELECT e.thread,e.target,e.n FROM (SELECT OLD.thread AS thread,OLD.n AS n WHERE OLD.target IS NOT NULL) k JOIN entries e ON e.thread=k.thread AND e.n=k.n
  #|        WHERE e.target IS NOT NULL
  #|      
  #|    ) t WHERE t.thread IS NOT NULL AND t.n IS NOT NULL AND t.target IS NOT NULL
  #|      AND NOT EXISTS (SELECT 1 FROM legacy_edit_targets x WHERE x.thread=t.thread AND x.target=t.target AND x.n=t.n); END;
  #|    

///|
let card_scan_tables_sql : String =
  #|CREATE TABLE IF NOT EXISTS card_scan_meta(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL,
  #|            schema_version INTEGER NOT NULL,has_ts_index INTEGER NOT NULL) WITHOUT ROWID;
  #|          INSERT OR IGNORE INTO card_scan_meta VALUES(1,1,0,0);
  #|          CREATE TABLE IF NOT EXISTS card_scan_guard(thread INTEGER NOT NULL,target INTEGER NOT NULL,token TEXT NOT NULL,dirty INTEGER NOT NULL,
  #|            PRIMARY KEY(thread,target)) WITHOUT ROWID;

///|
let card_scan_triggers_sql : String =
  #|CREATE TRIGGER card_scan_add BEFORE INSERT ON entries WHEN EXISTS (SELECT 1 FROM card_scan_guard LIMIT 1) AND (SELECT schema_version FROM pragma_schema_version)=(SELECT schema_version FROM card_scan_meta WHERE id=1)
  #|          AND (EXISTS (SELECT 1 FROM card_scan_guard g
  #|  WHERE g.thread=NEW.thread AND g.target IN (NEW.n,NEW.target)) OR EXISTS (SELECT 1 FROM entries e WHERE e.thread=NEW.thread AND e.n=NEW.n AND EXISTS (SELECT 1 FROM card_scan_guard g
  #|  WHERE g.thread=e.thread AND g.target IN (e.n,e.target)))
  #|  OR EXISTS (SELECT 1 FROM (SELECT 1 FROM card_scan_meta WHERE id=1 AND has_ts_index=1) present
  #|    CROSS JOIN entries e WHERE NEW.ts IS NOT NULL AND e.thread=NEW.thread AND e.ts=NEW.ts AND EXISTS (SELECT 1 FROM card_scan_guard g
  #|  WHERE g.thread=e.thread AND g.target IN (e.n,e.target)))
  #|  OR EXISTS (SELECT 1 FROM entries e WHERE e.rowid=NEW.rowid AND EXISTS (SELECT 1 FROM card_scan_guard g
  #|  WHERE g.thread=e.thread AND g.target IN (e.n,e.target))))
  #|          BEGIN -- card_scan_guard_v1
  #|            UPDATE card_scan_guard SET dirty=1 WHERE dirty=0 AND (thread,target) IN (SELECT NEW.thread AS thread,NEW.n AS target
  #|  UNION SELECT NEW.thread,NEW.target WHERE NEW.target IS NOT NULL
  #|  
  #|  UNION SELECT e.thread,e.n FROM (SELECT e.thread,e.n,e.target FROM entries e WHERE e.thread=NEW.thread AND e.n=NEW.n
  #|  UNION SELECT e.thread,e.n,e.target FROM (SELECT 1 FROM card_scan_meta WHERE id=1 AND has_ts_index=1) present
  #|    CROSS JOIN entries e WHERE NEW.ts IS NOT NULL AND e.thread=NEW.thread AND e.ts=NEW.ts
  #|  UNION SELECT e.thread,e.n,e.target FROM entries e WHERE e.rowid=NEW.rowid) e
  #|  UNION SELECT e.thread,e.target FROM (SELECT e.thread,e.n,e.target FROM entries e WHERE e.thread=NEW.thread AND e.n=NEW.n
  #|  UNION SELECT e.thread,e.n,e.target FROM (SELECT 1 FROM card_scan_meta WHERE id=1 AND has_ts_index=1) present
  #|    CROSS JOIN entries e WHERE NEW.ts IS NOT NULL AND e.thread=NEW.thread AND e.ts=NEW.ts
  #|  UNION SELECT e.thread,e.n,e.target FROM entries e WHERE e.rowid=NEW.rowid) e WHERE e.target IS NOT NULL); END;
  #|          CREATE TRIGGER card_scan_change BEFORE UPDATE ON entries WHEN EXISTS (SELECT 1 FROM card_scan_guard LIMIT 1) AND (SELECT schema_version FROM pragma_schema_version)=(SELECT schema_version FROM card_scan_meta WHERE id=1)
  #|          AND (EXISTS (SELECT 1 FROM card_scan_guard g
  #|  WHERE g.thread=OLD.thread AND g.target IN (OLD.n,OLD.target)) OR EXISTS (SELECT 1 FROM card_scan_guard g
  #|  WHERE g.thread=NEW.thread AND g.target IN (NEW.n,NEW.target)) OR EXISTS (SELECT 1 FROM entries e WHERE e.thread=NEW.thread AND e.n=NEW.n AND EXISTS (SELECT 1 FROM card_scan_guard g
  #|  WHERE g.thread=e.thread AND g.target IN (e.n,e.target)))
  #|  OR EXISTS (SELECT 1 FROM (SELECT 1 FROM card_scan_meta WHERE id=1 AND has_ts_index=1) present
  #|    CROSS JOIN entries e WHERE NEW.ts IS NOT NULL AND e.thread=NEW.thread AND e.ts=NEW.ts AND EXISTS (SELECT 1 FROM card_scan_guard g
  #|  WHERE g.thread=e.thread AND g.target IN (e.n,e.target)))
  #|  OR EXISTS (SELECT 1 FROM entries e WHERE e.rowid=NEW.rowid AND EXISTS (SELECT 1 FROM card_scan_guard g
  #|  WHERE g.thread=e.thread AND g.target IN (e.n,e.target))))
  #|          BEGIN -- card_scan_guard_v1
  #|            UPDATE card_scan_guard SET dirty=1 WHERE dirty=0 AND (thread,target) IN (SELECT NEW.thread AS thread,NEW.n AS target
  #|  UNION SELECT NEW.thread,NEW.target WHERE NEW.target IS NOT NULL
  #|  UNION SELECT OLD.thread,OLD.n UNION SELECT OLD.thread,OLD.target WHERE OLD.target IS NOT NULL
  #|  UNION SELECT e.thread,e.n FROM (SELECT e.thread,e.n,e.target FROM entries e WHERE e.thread=NEW.thread AND e.n=NEW.n
  #|  UNION SELECT e.thread,e.n,e.target FROM (SELECT 1 FROM card_scan_meta WHERE id=1 AND has_ts_index=1) present
  #|    CROSS JOIN entries e WHERE NEW.ts IS NOT NULL AND e.thread=NEW.thread AND e.ts=NEW.ts
  #|  UNION SELECT e.thread,e.n,e.target FROM entries e WHERE e.rowid=NEW.rowid) e
  #|  UNION SELECT e.thread,e.target FROM (SELECT e.thread,e.n,e.target FROM entries e WHERE e.thread=NEW.thread AND e.n=NEW.n
  #|  UNION SELECT e.thread,e.n,e.target FROM (SELECT 1 FROM card_scan_meta WHERE id=1 AND has_ts_index=1) present
  #|    CROSS JOIN entries e WHERE NEW.ts IS NOT NULL AND e.thread=NEW.thread AND e.ts=NEW.ts
  #|  UNION SELECT e.thread,e.n,e.target FROM entries e WHERE e.rowid=NEW.rowid) e WHERE e.target IS NOT NULL); END;
  #|          CREATE TRIGGER card_scan_drop BEFORE DELETE ON entries WHEN (SELECT schema_version FROM pragma_schema_version)=(SELECT schema_version FROM card_scan_meta WHERE id=1) AND EXISTS (SELECT 1 FROM card_scan_guard g
  #|  WHERE g.thread=OLD.thread AND g.target IN (OLD.n,OLD.target))
  #|          BEGIN -- card_scan_guard_v1
  #|            UPDATE card_scan_guard SET dirty=1 WHERE thread=OLD.thread AND target IN (OLD.n,OLD.target) AND dirty=0; END;
  #|          CREATE TRIGGER card_scan_thread_drop AFTER DELETE ON threads
  #|          BEGIN -- card_scan_guard_v1
  #|            DELETE FROM card_scan_guard WHERE thread=OLD.id; END;

///|
let restate_guard_tables_sql : String =
  #|CREATE TABLE IF NOT EXISTS restate_guard_meta(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL) WITHOUT ROWID;
  #|          INSERT OR IGNORE INTO restate_guard_meta VALUES(1,1);
  #|          CREATE TABLE IF NOT EXISTS restate_guard(thread INTEGER PRIMARY KEY,token TEXT NOT NULL,dirty INTEGER NOT NULL) WITHOUT ROWID;

///|
let restate_guard_triggers_sql : String =
  #|CREATE TRIGGER restate_guard_add BEFORE INSERT ON entries
  #|          WHEN EXISTS (SELECT 1 FROM restate_guard WHERE thread=NEW.thread)
  #|            OR EXISTS (SELECT 1 FROM entries e JOIN restate_guard g ON g.thread=e.thread WHERE e.rowid=NEW.rowid)
  #|          BEGIN -- restate_guard_v1
  #|            UPDATE restate_guard SET dirty=1 WHERE dirty=0 AND thread IN
  #|            (NEW.thread,(SELECT e.thread FROM entries e WHERE e.rowid=NEW.rowid)); END;
  #|        CREATE TRIGGER restate_guard_change BEFORE UPDATE ON entries
  #|          WHEN EXISTS (SELECT 1 FROM restate_guard WHERE thread IN (OLD.thread,NEW.thread))
  #|            OR EXISTS (SELECT 1 FROM entries e JOIN restate_guard g ON g.thread=e.thread WHERE e.rowid=NEW.rowid)
  #|          BEGIN -- restate_guard_v1
  #|            UPDATE restate_guard SET dirty=1 WHERE dirty=0 AND thread IN
  #|            (OLD.thread,NEW.thread,(SELECT e.thread FROM entries e WHERE e.rowid=NEW.rowid)); END;
  #|        CREATE TRIGGER restate_guard_drop BEFORE DELETE ON entries
  #|          WHEN EXISTS (SELECT 1 FROM restate_guard WHERE thread=OLD.thread)
  #|          BEGIN -- restate_guard_v1
  #|            UPDATE restate_guard SET dirty=1 WHERE dirty=0 AND thread=OLD.thread; END;
  #|        CREATE TRIGGER restate_guard_thread_drop AFTER DELETE ON threads
  #|          BEGIN -- restate_guard_v1
  #|            DELETE FROM restate_guard WHERE thread=OLD.id; END;
