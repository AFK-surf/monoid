// The store's statements as station/src/store's TypeScript says them, word for word (store.ts and the files it reads
// them from; test/mb-store-sessions.test.ts holds each to its TypeScript as `sql` answers them).

///|
let live_sessions : String =
  #|SELECT * FROM sessions WHERE archived_at IS NULL ORDER BY last_active_at DESC

///|
let any_running : String =
  #|SELECT 1 AS r FROM sessions WHERE running = 1 LIMIT 1

///|
let running_sessions : String =
  #|SELECT * FROM sessions WHERE running = 1

///|
let waiting_for_people : String =
  #|SELECT t.session_key AS key, s.title, t.need, t.ended_at FROM turns t INDEXED BY turns_ended
  #|  JOIN sessions s ON s.key = t.session_key
  #|  WHERE t.ended_at >= ?1 AND t.declared IN ('block', 'need_help', 'need_human', 'need_decision') AND s.archived_at IS NULL
  #|    AND t.id = (SELECT u.id FROM turns u WHERE u.session_key = t.session_key ORDER BY u.started_at DESC, u.rowid DESC LIMIT 1)
  #|    AND NOT EXISTS (SELECT 1 FROM deliveries d WHERE d.session = t.session_key AND d.delivered_at IS NULL)
  #|  ORDER BY t.ended_at DESC LIMIT ?2

///|
let failed_turn_near : String =
  #|SELECT * FROM turns INDEXED BY turns_by_end
  #|  WHERE session_key = ?1 AND ended_at >= ?2 AND ended_at <= ?3 AND outcome = 'failed'
  #|  ORDER BY ABS(ended_at - ?4), started_at, rowid LIMIT 1

///|
let process_by_group : String =
  #|SELECT * FROM processes WHERE pgid = ?

///|
let transcript_in_use : String =
  #|SELECT 1 FROM runtime_sessions r INDEXED BY runtime_sessions_by_id
  #|    CROSS JOIN sessions s ON s.key = r.session_key
  #|    WHERE r.id = ?1 AND COALESCE(r.runtime, s.original_runtime, s.runtime) = ?2 AND s.key <> ?3
  #|      AND (s.archived_at IS NULL OR s.running = 1)
  #|  UNION ALL SELECT 1 FROM sessions s INDEXED BY sessions_by_runtime_id
  #|    WHERE s.runtime_session_id = ?1 AND s.runtime = ?2 AND s.key <> ?3 AND (s.archived_at IS NULL OR s.running = 1)
  #|      AND NOT EXISTS (SELECT 1 FROM runtime_sessions r WHERE r.session_key = s.key AND r.id = ?1)
  #|  LIMIT 1

///|
let transcript_referenced : String =
  #|SELECT 1 FROM runtime_sessions r INDEXED BY runtime_sessions_by_id
  #|    CROSS JOIN sessions s ON s.key = r.session_key
  #|    WHERE r.id = ?1 AND COALESCE(r.runtime, s.original_runtime, s.runtime) = ?2 AND s.key <> ?3
  #|  UNION ALL SELECT 1 FROM sessions s INDEXED BY sessions_by_runtime_id
  #|    WHERE s.runtime_session_id = ?1 AND s.runtime = ?2 AND s.key <> ?3
  #|      AND NOT EXISTS (SELECT 1 FROM runtime_sessions r WHERE r.session_key = s.key AND r.id = ?1)
  #|  LIMIT 1

///|
let session_paths_page : String =
  #|SELECT key, workspace, cwd, archived_at FROM sessions WHERE key > ?1 ORDER BY key LIMIT ?2

///|
let stats_of : String =
  #|SELECT
  #|    ((SELECT COUNT(*) FROM deliveries d INDEXED BY deliveries_pending WHERE d.session = s.key AND d.delivered_at IS NULL) +
  #|         (SELECT COUNT(*) FROM letter_deliveries d WHERE d.session = s.key AND d.delivered_at IS NULL)) AS pending,
  #|    l.kind, l.outcome, l.declared, l.wait_seconds, l.wait_for, l.wait_watch, l.need, l.about_thread, l.about_n, l.about_ts, l.detail, l.started_at, l.ended_at
  #|  FROM sessions s
  #|  LEFT JOIN turns l ON l.id = (SELECT id FROM turns t2 WHERE t2.session_key = s.key ORDER BY t2.started_at DESC, t2.rowid DESC LIMIT 1)
  #|  WHERE s.key = ?

///|
let last_turn_of_session : String =
  #|SELECT l.kind, l.outcome, l.declared, l.wait_seconds, l.wait_for, l.wait_watch, l.need,
  #|  l.about_thread, l.about_n, l.about_ts, l.detail, l.started_at, l.ended_at FROM sessions s
  #|  LEFT JOIN turns l ON l.id = (SELECT id FROM turns t2 WHERE t2.session_key = s.key ORDER BY t2.started_at DESC, t2.rowid DESC LIMIT 1)
  #|  WHERE s.key = ?

///|
let work_of_session : String =
  #|SELECT
  #|  CASE WHEN EXISTS (SELECT 1 FROM deliveries d INDEXED BY deliveries_pending WHERE d.session = s.key AND d.delivered_at IS NULL)
  #|    THEN 1 ELSE EXISTS (SELECT 1 FROM letter_deliveries d INDEXED BY letter_deliveries_pending WHERE d.session = s.key AND d.delivered_at IS NULL) END AS pending,
  #|  l.kind, l.outcome, l.declared, l.wait_seconds, l.wait_for, l.wait_watch, l.need,
  #|  l.about_thread, l.about_n, l.about_ts, l.detail, l.started_at, l.ended_at FROM sessions s
  #|  LEFT JOIN turns l ON l.id = (SELECT id FROM turns t2 WHERE t2.session_key = s.key ORDER BY t2.started_at DESC, t2.rowid DESC LIMIT 1)
  #|  WHERE s.key = ?

///|
let last_read_at : String =
  #|WITH RECURSIVE few(viewer, count) AS (
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
  #|  THEN (SELECT MAX((SELECT at FROM reads WHERE viewer = v.viewer AND thread = ?1)) FROM few v WHERE v.viewer IS NOT NULL)
  #|  WHEN (SELECT span FROM bounds) < 512
  #|  THEN (SELECT MAX(at) FROM reads WHERE thread = ?1)
  #|  WHEN (SELECT COUNT(*) FROM more WHERE viewer IS NOT NULL) <= 256
  #|  THEN (SELECT MAX((SELECT at FROM reads WHERE viewer = v.viewer AND thread = ?1)) FROM more v WHERE v.viewer IS NOT NULL)
  #|  WHEN (SELECT span FROM bounds) < 16384
  #|  THEN (SELECT MAX(at) FROM reads WHERE thread = ?1)
  #|  ELSE (SELECT MAX((SELECT at FROM reads WHERE viewer = v.viewer AND thread = ?1)) FROM all_viewers v WHERE v.viewer IS NOT NULL) END AS at

///|
let models_used_by : String =
  #|SELECT runtime, model, COUNT(*) AS n FROM sessions INDEXED BY sessions_models WHERE created_by = ? AND created_at >= ? GROUP BY runtime, model

///|
let efforts_used_by : String =
  #|SELECT effort, COUNT(*) AS n, MAX(created_at) AS last FROM sessions INDEXED BY sessions_efforts WHERE created_by = ? AND runtime = ? AND model IS ? AND created_at >= ? AND effort IS NOT NULL AND effort != '' GROUP BY effort ORDER BY n DESC, last DESC

///|
let efforts_used_by_before_index : String =
  #|SELECT effort, COUNT(*) AS n, MAX(created_at) AS last FROM sessions INDEXED BY sessions_models WHERE created_by = ? AND runtime = ? AND model IS ? AND created_at >= ? AND effort IS NOT NULL AND effort != '' GROUP BY effort ORDER BY n DESC, last DESC

///|
let people_said_after : String =
  #|SELECT COUNT(*) AS c FROM (SELECT n FROM entries INDEXED BY entries_people_by_n WHERE thread = ? AND n > ? AND kind = 'message' AND author_kind = 'person' ORDER BY n LIMIT ?)

///|
let post_blocks_ready : String =
  #|SELECT fresh OR EXISTS (SELECT 1 FROM post_blocks_coverage
  #|  WHERE thread = ?1 AND (complete = 1 OR cursor <= ?2 + 1)) AS ready FROM post_blocks_meta WHERE id = 1

///|
let post_after_first : String =
  #|SELECT n, ts, kind, author_kind, author FROM entries WHERE thread = ? AND n > ? ORDER BY n LIMIT 1

///|
let post_after_indexed : String =
  #|WITH first(bucket) AS MATERIALIZED (
  #|  SELECT bucket FROM post_blocks WHERE thread = ?1 AND author = ?2 AND bucket >= ?3 ORDER BY bucket LIMIT 1
  #|), second(bucket) AS MATERIALIZED (
  #|  SELECT bucket FROM post_blocks WHERE thread = ?1 AND author = ?2 AND bucket > (SELECT bucket FROM first) ORDER BY bucket LIMIT 1
  #|)
  #|SELECT n, ts FROM (
  #|  SELECT e.n, e.ts FROM entries e
  #|  WHERE e.thread = ?1 AND +e.n > ?4 AND e.n >= (SELECT bucket FROM first) * 64
  #|    AND e.n <= (SELECT bucket FROM first) * 64 + 63
  #|    AND e.kind = 'message' AND e.author_kind = 'agent' AND e.author = ?2 ORDER BY e.n LIMIT 1
  #|)
  #|UNION ALL SELECT n, ts FROM (
  #|  SELECT e.n, e.ts FROM entries e
  #|  WHERE e.thread = ?1 AND +e.n > ?4 AND e.n >= (SELECT bucket FROM second) * 64
  #|    AND e.n <= (SELECT bucket FROM second) * 64 + 63
  #|    AND e.kind = 'message' AND e.author_kind = 'agent' AND e.author = ?2 ORDER BY e.n LIMIT 1
  #|) LIMIT 1

///|
let jobs_running : String =
  #|SELECT * FROM jobs WHERE state = 'running' ORDER BY started_at DESC, port, rowid

///|
let jobs_up : String =
  #|SELECT * FROM (SELECT * FROM jobs WHERE state = 'running' UNION ALL SELECT * FROM jobs WHERE state = 'exited' AND port IS NOT NULL) ORDER BY started_at DESC

///|
let live_on_profile : String =
  #|SELECT key FROM sessions INDEXED BY sessions_live WHERE archived_at IS NULL AND profile = ?1 AND key NOT IN (SELECT session FROM handed_over) LIMIT ?2

///|
let last_jobs_of : String =
  #|SELECT session_key AS k, rowid AS r, ended_at AS e, state FROM jobs WHERE rowid IN (SELECT MAX(rowid) FROM jobs INDEXED BY jobs_by_session WHERE session_key IN (SELECT value FROM json_each(?1)) GROUP BY session_key)

///|
let job_at_port : String =
  #|SELECT id, name, port FROM (
  #|  SELECT id, name, port, started_at FROM jobs INDEXED BY jobs_up WHERE state = 'running' AND port = ?1
  #|  UNION ALL
  #|  SELECT id, name, port, started_at FROM jobs INDEXED BY jobs_up WHERE state = 'exited' AND port = ?1
  #|) ORDER BY started_at DESC LIMIT 1

///|
let session_jobs : String =
  #|SELECT * FROM jobs WHERE session_key = ? ORDER BY started_at DESC

///|
let session_of_runtime : String =
  #|SELECT key FROM (
  #|    SELECT key, last_active_at FROM sessions s WHERE runtime_session_id = ?2 AND runtime = ?1
  #|      AND NOT EXISTS (SELECT 1 FROM runtime_sessions r WHERE r.session_key = s.key AND r.id = ?2 AND COALESCE(r.runtime, s.original_runtime, s.runtime) != ?1)
  #|    UNION ALL SELECT s.key, s.last_active_at FROM runtime_sessions r JOIN sessions s ON s.key = r.session_key WHERE r.id = ?2 AND COALESCE(r.runtime, s.original_runtime, s.runtime) = ?1
  #|  ) ORDER BY last_active_at DESC LIMIT 1

///|
let recover_waits : String =
  #|SELECT s.*, t.outcome AS recovery_outcome, t.detail AS recovery_detail
  #|  FROM session_recover_waits w CROSS JOIN sessions s ON s.key = w.session
  #|  CROSS JOIN turns t ON t.rowid = (SELECT rowid FROM turns INDEXED BY turns_by_session
  #|    WHERE session_key = s.key ORDER BY started_at DESC, rowid DESC LIMIT 1)
  #|  WHERE s.archived_at IS NULL AND s.running != 1 AND t.ended_at IS NOT NULL
  #|    AND (t.declared = 'waiting' OR (t.outcome = 'failed' AND substr(t.detail, 1, 11) = 'rate_limit:'))
  #|  ORDER BY s.last_active_at DESC, s.rowid DESC

///|
let recover_awake_waits : String =
  #|SELECT t.ended_at, t.wait_seconds FROM session_recover_waits w CROSS JOIN sessions s ON s.key = w.session
  #|  CROSS JOIN turns t ON t.rowid = (SELECT rowid FROM turns INDEXED BY turns_by_session
  #|    WHERE session_key = s.key ORDER BY started_at DESC, rowid DESC LIMIT 1)
  #|  WHERE s.archived_at IS NULL AND s.running != 1 AND t.ended_at IS NOT NULL AND t.declared = 'waiting'

///|
let awake_wait_status : String =
  #|SELECT
  #|  EXISTS (SELECT 1 FROM session_awake_deadlines WHERE deadline = -9007199254740991 LIMIT 1) AS uncertain,
  #|  EXISTS (SELECT 1 FROM session_awake_deadlines WHERE deadline > ? LIMIT 1) AS awake

///|
let session_count_total : String =
  #|SELECT n FROM session_count_totals WHERE kind = ? AND ws = ?

///|
let session_count_connect : String =
  #|SELECT n FROM session_count_groups WHERE kind = ? AND ws = ? AND connect = ?

///|
let session_counts : String =
  #|SELECT connect, CASE kind WHEN 0 THEN NULL ELSE ws END AS ws, n
  #|  FROM session_count_groups ORDER BY connect, ws

///|
let session_counts_visible : String =
  #|SELECT connect, ws, n FROM session_count_groups
  #|  WHERE kind = 1 AND ws = ? ORDER BY connect

///|
let session_counts_home : String =
  #|SELECT connect, CASE kind WHEN 0 THEN NULL ELSE ws END AS ws, n
  #|  FROM session_count_groups WHERE (kind = 1 AND ws = ?) OR kind = 0 ORDER BY connect, ws

///|
let share_dirty : String =
  #|SELECT session FROM chat_share_dirty ORDER BY session LIMIT ?

///|
let share_live_rows : String =
  #|WITH keys AS (
  #|  SELECT t.session FROM chat_share_targets t INDEXED BY chat_share_target_time WHERE t.used > ?1 AND NOT EXISTS (SELECT 1 FROM chat_share_dirty d WHERE d.session = t.session)
  #|  UNION SELECT session FROM chat_share_dirty UNION SELECT session FROM chat_share_uncertain
  #|)
  #|SELECT c.* FROM keys k CROSS JOIN chat_shares c ON c.session = k.session ORDER BY c.rowid

///|
let share_due : String =
  #|WITH keys AS (
  #|  SELECT t.session FROM chat_share_targets t INDEXED BY chat_share_target_time WHERE t.used > ?1 AND t.used <= ?2 AND NOT EXISTS (SELECT 1 FROM chat_share_dirty d WHERE d.session = t.session)
  #|  UNION SELECT session FROM chat_share_dirty UNION SELECT session FROM chat_share_uncertain
  #|)
  #|SELECT c.* FROM keys k CROSS JOIN chat_shares c ON c.session = k.session ORDER BY c.rowid

///|
let share_next_time : String =
  #|SELECT t.used FROM chat_share_targets t INDEXED BY chat_share_target_time
  #|  WHERE t.used > ? AND NOT EXISTS (SELECT 1 FROM chat_share_dirty d WHERE d.session = t.session) ORDER BY t.used LIMIT 1

///|
let share_lapsed_workspace : String =
  #|SELECT 1 FROM chat_share_targets t INDEXED BY chat_share_target_workspace
  #|  WHERE t.workspace = ? AND t.used <= ? AND NOT EXISTS (SELECT 1 FROM chat_share_dirty d WHERE d.session = t.session) LIMIT 1

///|
let session_up_job : String =
  #|SELECT 1 FROM session_up_job_rows WHERE session = ? LIMIT 1

///|
let session_up_jobs : String =
  #|SELECT j.id FROM session_up_job_rows i
  #|  CROSS JOIN jobs j ON j.rowid = i.job_rowid WHERE i.session = ? ORDER BY j.started_at DESC

///|
let session_bindings_exists : String =
  #|SELECT 1 FROM session_binding_rows WHERE session = ? LIMIT 1

///|
let session_bindings_delete : String =
  #|DELETE FROM bindings WHERE rowid IN
  #|  (SELECT binding_rowid FROM session_binding_rows WHERE session = ?)

///|
let widget_source_missing : String =
  #|SELECT ts.thread FROM thread_sessions ts JOIN threads t ON t.id=ts.thread
  #|  LEFT JOIN widget_source_scopes s ON s.thread=ts.thread
  #|  WHERE ts.session=? AND COALESCE(s.complete,0)=0

///|
let widget_source_unusual : String =
  #|SELECT 1 FROM thread_sessions ts JOIN threads t ON t.id=ts.thread
  #|  CROSS JOIN widget_source_invalid i ON i.thread=ts.thread WHERE ts.session=? LIMIT 1

///|
let widget_source : String =
  #|SELECT t.channel, t.thread_ts, i.name FROM thread_sessions ts
  #|  JOIN threads t ON t.id = ts.thread
  #|  JOIN widget_source_rows i ON (i.thread, i.n, i.slot) = (
  #|    SELECT x.thread, x.n, x.slot FROM widget_source_rows x
  #|    WHERE x.thread = ts.thread AND x.path = ?2 ORDER BY x.at DESC, x.n, x.slot LIMIT 1
  #|  ) WHERE ts.session = ?1 ORDER BY i.at DESC, ts.rowid LIMIT 1

///|
let widget_source_original : String =
  #|SELECT t.channel, t.thread_ts, json_extract(a.value, '$.name') AS name FROM merged m
  #|  JOIN threads t ON t.id = m.thread JOIN thread_sessions ts ON ts.thread = t.id AND ts.session = ?1, json_each(m.attachments) a
  #|  WHERE m.attachments IS NOT NULL AND json_extract(a.value, '$.path') = ?2 ORDER BY m.created_at DESC LIMIT 1

///|
let awake_jobs : String =
  #|SELECT j.session_key, j.started_at FROM active_watch_jobs w
  #|  CROSS JOIN jobs j ON j.id = w.job WHERE j.state = 'running' AND j.watch <> 0
  #|  UNION ALL
  #|  SELECT session_key, started_at FROM jobs INDEXED BY jobs_up WHERE state = 'running' AND port IS NULL AND watch = 0

///|
let running_limit : String =
  #|SELECT job FROM (
  #|  SELECT job FROM active_watch_jobs INDEXED BY active_watch_jobs_session WHERE session = ?1
  #|  UNION ALL
  #|  SELECT job FROM active_other_jobs WHERE session = ?1
  #|) LIMIT 1 OFFSET ?2

///|
let running_job_sessions : String =
  #|SELECT c.value AS session FROM json_each(?1) c
  #|  WHERE EXISTS (SELECT 1 FROM active_watch_jobs INDEXED BY active_watch_jobs_session WHERE session = c.value)
  #|    OR EXISTS (SELECT 1 FROM active_other_jobs WHERE session = c.value)

///|
let running_wait_jobs : String =
  #|SELECT j.id FROM (
  #|  SELECT job FROM active_watch_jobs INDEXED BY active_watch_jobs_session WHERE session = ?1
  #|  UNION ALL
  #|  SELECT job FROM active_other_jobs WHERE session = ?1
  #|) active CROSS JOIN jobs j ON j.id = active.job
  #|WHERE j.watch <> 0 OR j.port IS NULL
  #|ORDER BY j.started_at DESC, (j.watch = 0), j.id

///|
let up_jobs_of_session : String =
  #|SELECT id FROM (
  #|  SELECT j.id, j.started_at, (j.watch = 0) AS sort_kind, j.id AS sort_id, NULL AS sort_port, j.rowid AS sort_rowid FROM (
  #|    SELECT job FROM active_watch_jobs INDEXED BY active_watch_jobs_session WHERE session = ?1
  #|    UNION ALL
  #|    SELECT job FROM active_other_jobs WHERE session = ?1
  #|  ) active CROSS JOIN jobs j ON j.id = active.job
  #|  UNION ALL
  #|  SELECT id, started_at, 2 AS sort_kind, NULL AS sort_id, port AS sort_port, rowid AS sort_rowid
  #|    FROM jobs INDEXED BY jobs_up WHERE state = 'exited' AND port IS NOT NULL AND session_key = ?1
  #|) ORDER BY started_at DESC, sort_kind, sort_id, sort_port, sort_rowid

///|
let remote_queue_jobs : String =
  #|SELECT * FROM (
  #|  SELECT j.id, j.session_key, j.started_at, j.queued, j.screen, j.small, j.rowid AS queue_rowid FROM active_watch_jobs w
  #|    CROSS JOIN jobs j ON j.id = w.job WHERE w.job >= 'remote_' AND w.job < 'remote`'
  #|  UNION ALL
  #|  SELECT j.id, j.session_key, j.started_at, j.queued, j.screen, j.small, j.rowid AS queue_rowid FROM active_other_jobs a INDEXED BY active_other_remote_jobs
  #|    CROSS JOIN jobs j ON j.id = a.job WHERE a.job >= 'remote_' AND a.job < 'remote`'
  #|) ORDER BY started_at DESC, queue_rowid

///|
let awake_jobs_before_upgrade : String =
  #|SELECT session_key, started_at FROM jobs INDEXED BY jobs_state
  #|  WHERE state = 'running' AND (watch <> 0 OR port IS NULL)

///|
let running_limit_before_upgrade : String =
  #|SELECT id FROM jobs INDEXED BY jobs_by_session
  #|  WHERE session_key = ?1 AND state = 'running' LIMIT 1 OFFSET ?2

///|
let running_job_sessions_before_upgrade : String =
  #|SELECT c.value AS session FROM json_each(?1) c
  #|  WHERE EXISTS (SELECT 1 FROM jobs INDEXED BY jobs_by_session WHERE session_key = c.value AND state = 'running')

///|
let running_wait_jobs_before_upgrade : String =
  #|SELECT id FROM jobs INDEXED BY jobs_by_session
  #|  WHERE session_key = ?1 AND state = 'running' AND (watch <> 0 OR port IS NULL)
  #|  ORDER BY started_at DESC, (watch = 0), id

///|
let up_jobs_before_upgrade : String =
  #|SELECT id FROM jobs INDEXED BY jobs_by_session
  #|  WHERE session_key = ?1 AND (state = 'running' OR (state = 'exited' AND port IS NOT NULL))
  #|  ORDER BY started_at DESC, CASE WHEN state = 'running' THEN (watch = 0) ELSE 2 END,
  #|    CASE WHEN state = 'running' THEN id END, CASE WHEN state = 'exited' THEN port END, rowid

///|
let remote_queue_before_upgrade : String =
  #|SELECT id, session_key, started_at, queued, screen, small FROM jobs
  #|  WHERE id >= 'remote_' AND id < 'remote`' AND state = 'running' ORDER BY started_at DESC, rowid

///|
let remote_queue_prepared : String =
  #|SELECT * FROM (
  #|  SELECT j.id, j.session_key, j.started_at, j.queued, j.screen, j.small, j.rowid AS queue_rowid FROM active_watch_jobs w
  #|    CROSS JOIN jobs j ON j.id = w.job WHERE w.job >= 'remote_' AND w.job < 'remote`'
  #|  UNION ALL
  #|  SELECT j.id, j.session_key, j.started_at, j.queued, j.screen, j.small, j.rowid AS queue_rowid FROM active_remote_job_rows a
  #|    CROSS JOIN jobs j ON j.id = a.job WHERE a.job >= 'remote_' AND a.job < 'remote`'
  #|) ORDER BY started_at DESC, queue_rowid

///|
let delete_expired_remote_runs : String =
  #|DELETE FROM remote_runs WHERE job IN
  #|  (SELECT job FROM remote_run_by_time WHERE at < ? ORDER BY at, seq)

///|
let quota_hours_read : String =
  #|SELECT profile, hour, at, windows_json FROM profile_quota_hours INDEXED BY profile_quota_hours_hour
  #|  WHERE hour >= ? ORDER BY profile, hour

///|
let spend_hours_read : String =
  #|SELECT (CASE WHEN quarter >= 0 THEN quarter / 4 ELSE (quarter - 3) / 4 END) AS hour,
  #|    profile, runtime, model, fast,
  #|    SUM(calls) AS calls, SUM(input) AS input, SUM(cache_read) AS cache_read,
  #|    SUM(cache_write) AS cache_write, SUM(cache_write_long) AS cache_write_long, SUM(output) AS output,
  #|    SUM(gen_ms) AS gen_ms, SUM(gen_output) AS gen_output
  #|  FROM usage_15m INDEXED BY usage_15m_quarter
  #|  WHERE quarter >= ? AND profile <> '' AND calls > 0
  #|  GROUP BY 1, 2, 3, 4, 5
  #|  ORDER BY profile, hour

///|
/// profile-hours.ts SPEED_QUARTERS_READ.
let speed_quarters_read : String =
  #|SELECT quarter, profile, model, SUM(gen_ms) AS gen_ms, SUM(gen_output) AS gen_output
  #|  FROM usage_15m INDEXED BY usage_15m_quarter
  #|  WHERE quarter >= ? AND profile <> '' AND model <> '' AND gen_ms > 0
  #|  GROUP BY 1, 2, 3
  #|  ORDER BY quarter, profile, model

///|
let turns_from : String =
  #|SELECT IFNULL((SELECT MAX(started_at) FROM turns WHERE session_key = ?1 AND started_at <= ?2),
  #|  (SELECT MIN(started_at) FROM turns WHERE session_key = ?1)) AS at

///|
let turns_between : String =
  #|SELECT id, kind, started_at, profile, person, thread FROM turns WHERE session_key = ?1 AND started_at >= ?2 AND started_at <= ?3 ORDER BY started_at

///|
let taken_since : String =
  #|SELECT d.delivered_at AS at, CASE WHEN t.surface = ?2 THEN e.author ELSE 'slack:' || ts.connect || ':' || e.author END AS who, e.thread AS thread
  #|  FROM deliveries d JOIN entries e ON e.thread = d.thread AND e.n = d.n JOIN threads t ON t.id = d.thread
  #|  JOIN thread_sessions ts ON ts.thread = d.thread AND ts.session = d.session
  #|  WHERE d.session = ?1 AND d.delivered_at IS NOT NULL AND d.delivered_at >= ?3 AND e.author_kind = 'person' ORDER BY d.delivered_at

///|
let last_contexts : String =
  #|SELECT u.turn, u.profile, u.model, u.context, u.context_window, u.at, u.fast, u.cache_write, u.cache_write_long
  #|  FROM usage_main_calls m JOIN usage u ON u.id = m.id WHERE m.session = ?1 ORDER BY m.at DESC, m.id DESC LIMIT ?2
