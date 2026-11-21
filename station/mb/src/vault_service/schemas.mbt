// The vault's tables, indexes and triggers, as station/src/vault writes them (the same text, so a database either made
// holds the same schema): store.ts, secrets.ts, signin.ts, member-index.ts, pending-index.ts, use-index.ts,
// rebox-index.ts, signin-save-index.ts. Written out whole from their templates.

///|
let member_schema : String =
  #|
  #|CREATE TABLE IF NOT EXISTS vault_member_lookup (
  #|  ws TEXT NOT NULL, sub TEXT NOT NULL, vault TEXT NOT NULL, PRIMARY KEY (ws, sub, vault)
  #|) WITHOUT ROWID;
  #|CREATE TABLE IF NOT EXISTS vault_member_invalid (
  #|  ws TEXT NOT NULL, vault TEXT NOT NULL, PRIMARY KEY (ws, vault)
  #|) WITHOUT ROWID;
  #|CREATE TABLE IF NOT EXISTS vault_member_backfill (
  #|  ws TEXT PRIMARY KEY, after_id TEXT, done INTEGER NOT NULL
  #|) WITHOUT ROWID;
  #|-- An older completed member index may already have indexed the first of two members fields. Audit it in batches;
  #|-- triggers cover writes on both sides of the cursor, including writes from a previous Station.
  #|CREATE TABLE IF NOT EXISTS vault_member_duplicates_v2 (
  #|  ws TEXT NOT NULL, vault TEXT NOT NULL, PRIMARY KEY (ws, vault)
  #|) WITHOUT ROWID;
  #|CREATE TABLE IF NOT EXISTS vault_member_audit_v2 (
  #|  ws TEXT PRIMARY KEY, after_id TEXT, done INTEGER NOT NULL
  #|) WITHOUT ROWID;
  #|-- Older change triggers compared only json_extract's SQL value. An array and a string containing the array's JSON
  #|-- can have the same value, so repair old lookups and invalid markers before trusting them.
  #|CREATE TABLE IF NOT EXISTS vault_member_type_audit_v3 (
  #|  ws TEXT PRIMARY KEY, after_id TEXT, done INTEGER NOT NULL
  #|) WITHOUT ROWID;
  #|CREATE TABLE IF NOT EXISTS vault_member_nul_v4 (
  #|  ws TEXT NOT NULL, vault TEXT NOT NULL, PRIMARY KEY (ws, vault)
  #|) WITHOUT ROWID;
  #|CREATE TABLE IF NOT EXISTS vault_member_nul_audit_v4 (
  #|  ws TEXT PRIMARY KEY, after_id TEXT, done INTEGER NOT NULL
  #|) WITHOUT ROWID;
  #|CREATE TRIGGER IF NOT EXISTS vault_member_add AFTER INSERT ON vaults
  #|  WHEN EXISTS (SELECT 1 FROM vault_member_backfill WHERE ws = NEW.ws) BEGIN
  #|  INSERT INTO vault_member_invalid SELECT NEW.ws, NEW.id WHERE (CASE WHEN json_valid(NEW.body) THEN
  #|  CASE WHEN json_type(NEW.body, '$.members') = 'array' THEN 1 ELSE 0 END ELSE 0 END) = 0
  #|    ON CONFLICT(ws, vault) DO NOTHING;
  #|  INSERT INTO vault_member_lookup
  #|    SELECT NEW.ws, m.value, NEW.id FROM json_each(CASE WHEN (CASE WHEN json_valid(NEW.body) THEN
  #|  CASE WHEN json_type(NEW.body, '$.members') = 'array' THEN 1 ELSE 0 END ELSE 0 END) = 1 THEN NEW.body ELSE '{"members":[]}' END, '$.members') m WHERE m.type = 'text'
  #|    ON CONFLICT(ws, sub, vault) DO NOTHING;
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS vault_member_change AFTER UPDATE ON vaults
  #|  WHEN (OLD.ws IS NOT NEW.ws OR OLD.id IS NOT NEW.id
  #|    OR CASE WHEN json_valid(OLD.body) AND json_valid(NEW.body)
  #|      THEN json_extract(OLD.body, '$.members') IS NOT json_extract(NEW.body, '$.members')
  #|      ELSE OLD.body IS NOT NEW.body END)
  #|    AND (EXISTS (SELECT 1 FROM vault_member_backfill WHERE ws = OLD.ws)
  #|      OR EXISTS (SELECT 1 FROM vault_member_backfill WHERE ws = NEW.ws)) BEGIN
  #|  DELETE FROM vault_member_invalid WHERE ws = OLD.ws AND vault = OLD.id;
  #|  INSERT INTO vault_member_invalid SELECT NEW.ws, NEW.id WHERE (CASE WHEN json_valid(NEW.body) THEN
  #|  CASE WHEN json_type(NEW.body, '$.members') = 'array' THEN 1 ELSE 0 END ELSE 0 END) = 0
  #|    AND EXISTS (SELECT 1 FROM vault_member_backfill WHERE ws = NEW.ws)
  #|    ON CONFLICT(ws, vault) DO NOTHING;
  #|  DELETE FROM vault_member_lookup WHERE ws = OLD.ws AND vault = OLD.id AND sub IN
  #|    (SELECT value FROM json_each(CASE WHEN (CASE WHEN json_valid(OLD.body) THEN
  #|  CASE WHEN json_type(OLD.body, '$.members') = 'array' THEN 1 ELSE 0 END ELSE 0 END) = 1 THEN OLD.body ELSE '{"members":[]}' END, '$.members') WHERE type = 'text');
  #|  INSERT INTO vault_member_lookup
  #|    SELECT NEW.ws, m.value, NEW.id FROM json_each(CASE WHEN (CASE WHEN json_valid(NEW.body) THEN
  #|  CASE WHEN json_type(NEW.body, '$.members') = 'array' THEN 1 ELSE 0 END ELSE 0 END) = 1 THEN NEW.body ELSE '{"members":[]}' END, '$.members') m WHERE m.type = 'text'
  #|      AND EXISTS (SELECT 1 FROM vault_member_backfill WHERE ws = NEW.ws)
  #|    ON CONFLICT(ws, sub, vault) DO NOTHING;
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS vault_member_drop AFTER DELETE ON vaults
  #|  WHEN EXISTS (SELECT 1 FROM vault_member_backfill WHERE ws = OLD.ws) BEGIN
  #|  DELETE FROM vault_member_invalid WHERE ws = OLD.ws AND vault = OLD.id;
  #|  DELETE FROM vault_member_lookup WHERE ws = OLD.ws AND vault = OLD.id AND sub IN
  #|    (SELECT value FROM json_each(CASE WHEN (CASE WHEN json_valid(OLD.body) THEN
  #|  CASE WHEN json_type(OLD.body, '$.members') = 'array' THEN 1 ELSE 0 END ELSE 0 END) = 1 THEN OLD.body ELSE '{"members":[]}' END, '$.members') WHERE type = 'text');
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS vault_member_type_add_v3 AFTER INSERT ON vaults
  #|  WHEN EXISTS (SELECT 1 FROM vault_member_invalid WHERE ws = NEW.ws AND vault = NEW.id)
  #|    AND (CASE WHEN json_valid(NEW.body) THEN
  #|  CASE WHEN json_type(NEW.body, '$.members') = 'array' THEN 1 ELSE 0 END ELSE 0 END) = 1 BEGIN
  #|  DELETE FROM vault_member_invalid WHERE ws = NEW.ws AND vault = NEW.id;
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS vault_member_type_change_v3 AFTER UPDATE ON vaults
  #|  WHEN OLD.body IS NOT NEW.body AND (CASE WHEN json_valid(OLD.body) THEN
  #|  CASE WHEN json_type(OLD.body, '$.members') = 'array' THEN 1 ELSE 0 END ELSE 0 END) IS NOT (CASE WHEN json_valid(NEW.body) THEN
  #|  CASE WHEN json_type(NEW.body, '$.members') = 'array' THEN 1 ELSE 0 END ELSE 0 END)
  #|    AND (EXISTS (SELECT 1 FROM vault_member_backfill WHERE ws = OLD.ws)
  #|      OR EXISTS (SELECT 1 FROM vault_member_backfill WHERE ws = NEW.ws)) BEGIN
  #|  DELETE FROM vault_member_invalid WHERE ws = OLD.ws AND vault = OLD.id;
  #|  INSERT OR IGNORE INTO vault_member_invalid SELECT NEW.ws, NEW.id WHERE (CASE WHEN json_valid(NEW.body) THEN
  #|  CASE WHEN json_type(NEW.body, '$.members') = 'array' THEN 1 ELSE 0 END ELSE 0 END) = 0
  #|    AND EXISTS (SELECT 1 FROM vault_member_backfill WHERE ws = NEW.ws);
  #|  DELETE FROM vault_member_lookup WHERE ws = OLD.ws AND vault = OLD.id AND sub IN
  #|    (SELECT value FROM json_each(CASE WHEN (CASE WHEN json_valid(OLD.body) THEN
  #|  CASE WHEN json_type(OLD.body, '$.members') = 'array' THEN 1 ELSE 0 END ELSE 0 END) = 1 THEN OLD.body ELSE '{"members":[]}' END, '$.members') WHERE type = 'text');
  #|  INSERT OR IGNORE INTO vault_member_lookup
  #|    SELECT NEW.ws, m.value, NEW.id FROM json_each(CASE WHEN (CASE WHEN json_valid(NEW.body) THEN
  #|  CASE WHEN json_type(NEW.body, '$.members') = 'array' THEN 1 ELSE 0 END ELSE 0 END) = 1 THEN NEW.body ELSE '{"members":[]}' END, '$.members') m WHERE m.type = 'text'
  #|      AND EXISTS (SELECT 1 FROM vault_member_backfill WHERE ws = NEW.ws);
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS vault_member_duplicate_add_v2 AFTER INSERT ON vaults
  #|  WHEN EXISTS (SELECT 1 FROM vault_member_audit_v2 WHERE ws = NEW.ws) BEGIN
  #|  DELETE FROM vault_member_duplicates_v2 WHERE ws = NEW.ws AND vault = NEW.id;
  #|  INSERT OR IGNORE INTO vault_member_duplicates_v2 SELECT NEW.ws, NEW.id WHERE (CASE WHEN json_valid(NEW.body) THEN EXISTS
  #|  (SELECT 1 FROM json_each(NEW.body) WHERE key = 'members' LIMIT 1 OFFSET 1) ELSE 0 END) = 1;
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS vault_member_duplicate_change_v2 AFTER UPDATE ON vaults
  #|  WHEN (OLD.ws IS NOT NEW.ws OR OLD.id IS NOT NEW.id OR OLD.body IS NOT NEW.body)
  #|    AND (EXISTS (SELECT 1 FROM vault_member_audit_v2 WHERE ws = OLD.ws)
  #|      OR EXISTS (SELECT 1 FROM vault_member_audit_v2 WHERE ws = NEW.ws)) BEGIN
  #|  DELETE FROM vault_member_duplicates_v2 WHERE ws = OLD.ws AND vault = OLD.id;
  #|  DELETE FROM vault_member_duplicates_v2 WHERE ws = NEW.ws AND vault = NEW.id;
  #|  INSERT OR IGNORE INTO vault_member_duplicates_v2 SELECT NEW.ws, NEW.id
  #|    WHERE EXISTS (SELECT 1 FROM vault_member_audit_v2 WHERE ws = NEW.ws) AND (CASE WHEN json_valid(NEW.body) THEN EXISTS
  #|  (SELECT 1 FROM json_each(NEW.body) WHERE key = 'members' LIMIT 1 OFFSET 1) ELSE 0 END) = 1;
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS vault_member_duplicate_drop_v2 AFTER DELETE ON vaults
  #|  WHEN EXISTS (SELECT 1 FROM vault_member_audit_v2 WHERE ws = OLD.ws) BEGIN
  #|  DELETE FROM vault_member_duplicates_v2 WHERE ws = OLD.ws AND vault = OLD.id;
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS vault_member_nul_add_v4 AFTER INSERT ON vaults
  #|  WHEN EXISTS (SELECT 1 FROM vault_member_nul_audit_v4 WHERE ws = NEW.ws) BEGIN
  #|  DELETE FROM vault_member_nul_v4 WHERE ws = NEW.ws AND vault = NEW.id;
  #|  INSERT OR IGNORE INTO vault_member_nul_v4 SELECT NEW.ws, NEW.id WHERE (CASE WHEN instr(NEW.body, '\u0000') > 0 AND json_valid(NEW.body) THEN EXISTS
  #|  (SELECT 1 FROM json_each(NEW.body) WHERE instr(key, char(0)) > 0
  #|    AND substr(key, 1, instr(key, char(0)) - 1) = 'members') ELSE 0 END) = 1;
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS vault_member_nul_change_v4 AFTER UPDATE ON vaults
  #|  WHEN (OLD.ws IS NOT NEW.ws OR OLD.id IS NOT NEW.id OR OLD.body IS NOT NEW.body)
  #|    AND (EXISTS (SELECT 1 FROM vault_member_nul_audit_v4 WHERE ws = OLD.ws)
  #|      OR EXISTS (SELECT 1 FROM vault_member_nul_audit_v4 WHERE ws = NEW.ws)) BEGIN
  #|  DELETE FROM vault_member_nul_v4 WHERE ws = OLD.ws AND vault = OLD.id;
  #|  DELETE FROM vault_member_nul_v4 WHERE ws = NEW.ws AND vault = NEW.id;
  #|  INSERT OR IGNORE INTO vault_member_nul_v4 SELECT NEW.ws, NEW.id
  #|    WHERE EXISTS (SELECT 1 FROM vault_member_nul_audit_v4 WHERE ws = NEW.ws) AND (CASE WHEN instr(NEW.body, '\u0000') > 0 AND json_valid(NEW.body) THEN EXISTS
  #|  (SELECT 1 FROM json_each(NEW.body) WHERE instr(key, char(0)) > 0
  #|    AND substr(key, 1, instr(key, char(0)) - 1) = 'members') ELSE 0 END) = 1;
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS vault_member_nul_drop_v4 AFTER DELETE ON vaults
  #|  WHEN EXISTS (SELECT 1 FROM vault_member_nul_audit_v4 WHERE ws = OLD.ws) BEGIN
  #|  DELETE FROM vault_member_nul_v4 WHERE ws = OLD.ws AND vault = OLD.id;
  #|END;
  #|

///|
let pending_schema : String =
  #|
  #|CREATE TABLE IF NOT EXISTS vault_pending_lookup (
  #|  ws TEXT NOT NULL, id TEXT NOT NULL, owner_decides INTEGER NOT NULL, decider TEXT, at,
  #|  PRIMARY KEY (ws, id)
  #|) WITHOUT ROWID;
  #|CREATE INDEX IF NOT EXISTS vault_pending_decider ON vault_pending_lookup (ws, owner_decides, decider, id);
  #|CREATE INDEX IF NOT EXISTS vault_pending_at ON vault_pending_lookup (ws, at, id);
  #|CREATE TABLE IF NOT EXISTS vault_pending_backfill (
  #|  ws TEXT PRIMARY KEY, after_id TEXT, done INTEGER NOT NULL
  #|) WITHOUT ROWID;
  #|CREATE TABLE IF NOT EXISTS vault_pending_duplicates_v2 (
  #|  ws TEXT NOT NULL, id TEXT NOT NULL, PRIMARY KEY (ws, id)
  #|) WITHOUT ROWID;
  #|CREATE TABLE IF NOT EXISTS vault_pending_audit_v2 (
  #|  ws TEXT PRIMARY KEY, after_id TEXT, done INTEGER NOT NULL
  #|) WITHOUT ROWID;
  #|CREATE TABLE IF NOT EXISTS vault_pending_nul_v3 (
  #|  ws TEXT NOT NULL, id TEXT NOT NULL, PRIMARY KEY (ws, id)
  #|) WITHOUT ROWID;
  #|CREATE TABLE IF NOT EXISTS vault_pending_nul_audit_v3 (
  #|  ws TEXT PRIMARY KEY, after_id TEXT, done INTEGER NOT NULL
  #|) WITHOUT ROWID;
  #|CREATE TRIGGER IF NOT EXISTS vault_pending_add AFTER INSERT ON vault_requests
  #|  WHEN NEW.status = 'pending' AND EXISTS (SELECT 1 FROM vault_pending_backfill WHERE ws = NEW.ws) BEGIN
  #|  INSERT OR REPLACE INTO vault_pending_lookup VALUES (NEW.ws, NEW.id, CASE WHEN json_extract(NEW.body, '$.vault') = 'plain' OR CASE json_type(NEW.body, '$.save')
  #|  WHEN 'object' THEN 1 WHEN 'array' THEN 1 WHEN 'true' THEN 1
  #|  WHEN 'text' THEN json_extract(NEW.body, '$.save') != ''
  #|  WHEN 'integer' THEN json_extract(NEW.body, '$.save') != 0
  #|  WHEN 'real' THEN json_extract(NEW.body, '$.save') != 0 ELSE 0 END THEN 1 ELSE 0 END,
  #|  CASE WHEN json_extract(NEW.body, '$.vault') = 'plain' OR CASE json_type(NEW.body, '$.save')
  #|  WHEN 'object' THEN 1 WHEN 'array' THEN 1 WHEN 'true' THEN 1
  #|  WHEN 'text' THEN json_extract(NEW.body, '$.save') != ''
  #|  WHEN 'integer' THEN json_extract(NEW.body, '$.save') != 0
  #|  WHEN 'real' THEN json_extract(NEW.body, '$.save') != 0 ELSE 0 END
  #|  THEN json_extract(NEW.body, '$.owner') ELSE json_extract(NEW.body, '$.vault') END, json_extract(NEW.body, '$.at'));
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS vault_pending_change AFTER UPDATE ON vault_requests
  #|  WHEN CASE WHEN (EXISTS (SELECT 1 FROM vault_pending_backfill WHERE ws = OLD.ws)
  #|      OR EXISTS (SELECT 1 FROM vault_pending_backfill WHERE ws = NEW.ws))
  #|    AND (OLD.status = 'pending' OR NEW.status = 'pending') THEN (OLD.ws IS NOT NEW.ws OR OLD.id IS NOT NEW.id OR OLD.status IS NOT NEW.status
  #|  OR (CASE WHEN json_extract(OLD.body, '$.vault') = 'plain' OR CASE json_type(OLD.body, '$.save')
  #|  WHEN 'object' THEN 1 WHEN 'array' THEN 1 WHEN 'true' THEN 1
  #|  WHEN 'text' THEN json_extract(OLD.body, '$.save') != ''
  #|  WHEN 'integer' THEN json_extract(OLD.body, '$.save') != 0
  #|  WHEN 'real' THEN json_extract(OLD.body, '$.save') != 0 ELSE 0 END THEN 1 ELSE 0 END) IS NOT (CASE WHEN json_extract(NEW.body, '$.vault') = 'plain' OR CASE json_type(NEW.body, '$.save')
  #|  WHEN 'object' THEN 1 WHEN 'array' THEN 1 WHEN 'true' THEN 1
  #|  WHEN 'text' THEN json_extract(NEW.body, '$.save') != ''
  #|  WHEN 'integer' THEN json_extract(NEW.body, '$.save') != 0
  #|  WHEN 'real' THEN json_extract(NEW.body, '$.save') != 0 ELSE 0 END THEN 1 ELSE 0 END)
  #|  OR (CASE WHEN json_extract(OLD.body, '$.vault') = 'plain' OR CASE json_type(OLD.body, '$.save')
  #|  WHEN 'object' THEN 1 WHEN 'array' THEN 1 WHEN 'true' THEN 1
  #|  WHEN 'text' THEN json_extract(OLD.body, '$.save') != ''
  #|  WHEN 'integer' THEN json_extract(OLD.body, '$.save') != 0
  #|  WHEN 'real' THEN json_extract(OLD.body, '$.save') != 0 ELSE 0 END
  #|  THEN json_extract(OLD.body, '$.owner') ELSE json_extract(OLD.body, '$.vault') END) IS NOT (CASE WHEN json_extract(NEW.body, '$.vault') = 'plain' OR CASE json_type(NEW.body, '$.save')
  #|  WHEN 'object' THEN 1 WHEN 'array' THEN 1 WHEN 'true' THEN 1
  #|  WHEN 'text' THEN json_extract(NEW.body, '$.save') != ''
  #|  WHEN 'integer' THEN json_extract(NEW.body, '$.save') != 0
  #|  WHEN 'real' THEN json_extract(NEW.body, '$.save') != 0 ELSE 0 END
  #|  THEN json_extract(NEW.body, '$.owner') ELSE json_extract(NEW.body, '$.vault') END)
  #|  OR json_extract(OLD.body, '$.at') IS NOT json_extract(NEW.body, '$.at')) ELSE 0 END BEGIN
  #|  DELETE FROM vault_pending_lookup WHERE ws = OLD.ws AND id = OLD.id;
  #|  INSERT OR REPLACE INTO vault_pending_lookup SELECT NEW.ws, NEW.id, CASE WHEN json_extract(NEW.body, '$.vault') = 'plain' OR CASE json_type(NEW.body, '$.save')
  #|  WHEN 'object' THEN 1 WHEN 'array' THEN 1 WHEN 'true' THEN 1
  #|  WHEN 'text' THEN json_extract(NEW.body, '$.save') != ''
  #|  WHEN 'integer' THEN json_extract(NEW.body, '$.save') != 0
  #|  WHEN 'real' THEN json_extract(NEW.body, '$.save') != 0 ELSE 0 END THEN 1 ELSE 0 END,
  #|  CASE WHEN json_extract(NEW.body, '$.vault') = 'plain' OR CASE json_type(NEW.body, '$.save')
  #|  WHEN 'object' THEN 1 WHEN 'array' THEN 1 WHEN 'true' THEN 1
  #|  WHEN 'text' THEN json_extract(NEW.body, '$.save') != ''
  #|  WHEN 'integer' THEN json_extract(NEW.body, '$.save') != 0
  #|  WHEN 'real' THEN json_extract(NEW.body, '$.save') != 0 ELSE 0 END
  #|  THEN json_extract(NEW.body, '$.owner') ELSE json_extract(NEW.body, '$.vault') END, json_extract(NEW.body, '$.at')
  #|    WHERE NEW.status = 'pending' AND EXISTS (SELECT 1 FROM vault_pending_backfill WHERE ws = NEW.ws);
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS vault_pending_drop AFTER DELETE ON vault_requests
  #|  WHEN OLD.status = 'pending' AND EXISTS (SELECT 1 FROM vault_pending_backfill WHERE ws = OLD.ws) BEGIN
  #|  DELETE FROM vault_pending_lookup WHERE ws = OLD.ws AND id = OLD.id;
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS vault_pending_duplicate_add_v2 AFTER INSERT ON vault_requests
  #|  WHEN EXISTS (SELECT 1 FROM vault_pending_audit_v2 WHERE ws = NEW.ws) BEGIN
  #|  DELETE FROM vault_pending_duplicates_v2 WHERE ws = NEW.ws AND id = NEW.id;
  #|  INSERT OR IGNORE INTO vault_pending_duplicates_v2 SELECT NEW.ws, NEW.id
  #|    WHERE NEW.status = 'pending' AND (CASE WHEN json_valid(NEW.body) THEN EXISTS
  #|  (SELECT 1 FROM json_each(NEW.body) WHERE key IN ('vault', 'owner', 'save', 'at') GROUP BY key HAVING count(*) > 1)
  #|  ELSE 0 END) = 1;
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS vault_pending_duplicate_change_v2 AFTER UPDATE ON vault_requests
  #|  WHEN (OLD.ws IS NOT NEW.ws OR OLD.id IS NOT NEW.id OR OLD.status IS NOT NEW.status OR OLD.body IS NOT NEW.body)
  #|    AND (EXISTS (SELECT 1 FROM vault_pending_audit_v2 WHERE ws = OLD.ws)
  #|      OR EXISTS (SELECT 1 FROM vault_pending_audit_v2 WHERE ws = NEW.ws)) BEGIN
  #|  DELETE FROM vault_pending_duplicates_v2 WHERE ws = OLD.ws AND id = OLD.id;
  #|  DELETE FROM vault_pending_duplicates_v2 WHERE ws = NEW.ws AND id = NEW.id;
  #|  INSERT OR IGNORE INTO vault_pending_duplicates_v2 SELECT NEW.ws, NEW.id
  #|    WHERE NEW.status = 'pending' AND EXISTS (SELECT 1 FROM vault_pending_audit_v2 WHERE ws = NEW.ws)
  #|      AND (CASE WHEN json_valid(NEW.body) THEN EXISTS
  #|  (SELECT 1 FROM json_each(NEW.body) WHERE key IN ('vault', 'owner', 'save', 'at') GROUP BY key HAVING count(*) > 1)
  #|  ELSE 0 END) = 1;
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS vault_pending_duplicate_drop_v2 AFTER DELETE ON vault_requests BEGIN
  #|  DELETE FROM vault_pending_duplicates_v2 WHERE ws = OLD.ws AND id = OLD.id;
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS vault_pending_nul_add_v3 AFTER INSERT ON vault_requests
  #|  WHEN EXISTS (SELECT 1 FROM vault_pending_nul_audit_v3 WHERE ws = NEW.ws) BEGIN
  #|  DELETE FROM vault_pending_nul_v3 WHERE ws = NEW.ws AND id = NEW.id;
  #|  INSERT OR IGNORE INTO vault_pending_nul_v3 SELECT NEW.ws, NEW.id
  #|    WHERE NEW.status = 'pending' AND (CASE WHEN instr(NEW.body, '\u0000') > 0 AND json_valid(NEW.body) THEN EXISTS
  #|  (SELECT 1 FROM json_each(NEW.body) WHERE instr(key, char(0)) > 0) ELSE 0 END) = 1;
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS vault_pending_nul_change_v3 AFTER UPDATE ON vault_requests
  #|  WHEN (OLD.ws IS NOT NEW.ws OR OLD.id IS NOT NEW.id OR OLD.status IS NOT NEW.status OR OLD.body IS NOT NEW.body)
  #|    AND (EXISTS (SELECT 1 FROM vault_pending_nul_audit_v3 WHERE ws = OLD.ws)
  #|      OR EXISTS (SELECT 1 FROM vault_pending_nul_audit_v3 WHERE ws = NEW.ws)) BEGIN
  #|  DELETE FROM vault_pending_nul_v3 WHERE ws = OLD.ws AND id = OLD.id;
  #|  DELETE FROM vault_pending_nul_v3 WHERE ws = NEW.ws AND id = NEW.id;
  #|  INSERT OR IGNORE INTO vault_pending_nul_v3 SELECT NEW.ws, NEW.id
  #|    WHERE NEW.status = 'pending' AND EXISTS (SELECT 1 FROM vault_pending_nul_audit_v3 WHERE ws = NEW.ws)
  #|      AND (CASE WHEN instr(NEW.body, '\u0000') > 0 AND json_valid(NEW.body) THEN EXISTS
  #|  (SELECT 1 FROM json_each(NEW.body) WHERE instr(key, char(0)) > 0) ELSE 0 END) = 1;
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS vault_pending_nul_drop_v3 AFTER DELETE ON vault_requests BEGIN
  #|  DELETE FROM vault_pending_nul_v3 WHERE ws = OLD.ws AND id = OLD.id;
  #|END;
  #|CREATE TABLE IF NOT EXISTS vault_pending_owner_v4 (
  #|  ws TEXT NOT NULL, id TEXT NOT NULL, owner TEXT, at,
  #|  PRIMARY KEY (ws, id)
  #|) WITHOUT ROWID;
  #|CREATE INDEX IF NOT EXISTS vault_pending_owner_v4_owner ON vault_pending_owner_v4 (ws, owner, id);
  #|CREATE TRIGGER IF NOT EXISTS vault_pending_owner_add_v4 AFTER INSERT ON vault_requests
  #|  WHEN NEW.status = 'pending' AND json_valid(NEW.body) AND (json_type(NEW.body, '$.browse') = 'object' OR json_type(NEW.body, '$.cross') = 'object') BEGIN
  #|  INSERT OR REPLACE INTO vault_pending_owner_v4 VALUES (NEW.ws, NEW.id, json_extract(NEW.body, '$.owner'), json_extract(NEW.body, '$.at'));
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS vault_pending_owner_change_v4 AFTER UPDATE ON vault_requests
  #|  WHEN OLD.ws IS NOT NEW.ws OR OLD.id IS NOT NEW.id OR OLD.status IS NOT NEW.status OR OLD.body IS NOT NEW.body BEGIN
  #|  DELETE FROM vault_pending_owner_v4 WHERE ws = OLD.ws AND id = OLD.id;
  #|  DELETE FROM vault_pending_owner_v4 WHERE ws = NEW.ws AND id = NEW.id;
  #|  INSERT OR REPLACE INTO vault_pending_owner_v4
  #|    SELECT NEW.ws, NEW.id, json_extract(NEW.body, '$.owner'), json_extract(NEW.body, '$.at')
  #|    WHERE NEW.status = 'pending' AND json_valid(NEW.body) AND (json_type(NEW.body, '$.browse') = 'object' OR json_type(NEW.body, '$.cross') = 'object');
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS vault_pending_owner_drop_v4 AFTER DELETE ON vault_requests BEGIN
  #|  DELETE FROM vault_pending_owner_v4 WHERE ws = OLD.ws AND id = OLD.id;
  #|END;
  #|

///|
let use_schema : String =
  #|
  #|CREATE TABLE IF NOT EXISTS vault_use_lookup (
  #|  ws TEXT NOT NULL, id TEXT NOT NULL, vault TEXT, owner TEXT, at INTEGER,
  #|  PRIMARY KEY (ws, id)
  #|) WITHOUT ROWID;
  #|CREATE INDEX IF NOT EXISTS vault_use_lookup_vault ON vault_use_lookup (ws, vault, at DESC, id DESC);
  #|CREATE INDEX IF NOT EXISTS vault_use_lookup_owner ON vault_use_lookup (ws, vault, owner, at DESC, id DESC);
  #|CREATE TABLE IF NOT EXISTS vault_use_backfill (
  #|  ws TEXT PRIMARY KEY, after_id TEXT, done INTEGER NOT NULL
  #|) WITHOUT ROWID;
  #|CREATE TABLE IF NOT EXISTS vault_use_backfill_all (
  #|  id INTEGER PRIMARY KEY CHECK (id = 1), after_ws TEXT, done INTEGER NOT NULL
  #|);
  #|-- Exceptional requests are indexed from JSON.parse by the reader, in bounded batches. BLOB keys preserve the exact
  #|-- JavaScript UTF-16 code units, including isolated surrogates. Old Station writers only have to mark a row dirty.
  #|CREATE TABLE IF NOT EXISTS vault_use_ambiguous_v2 (
  #|  ws TEXT NOT NULL, id TEXT NOT NULL, dirty INTEGER NOT NULL, is_use INTEGER NOT NULL,
  #|  vault BLOB, owner BLOB, at INTEGER, PRIMARY KEY (ws, id)
  #|) WITHOUT ROWID;
  #|CREATE INDEX IF NOT EXISTS vault_use_ambiguous_dirty_v2 ON vault_use_ambiguous_v2 (ws, dirty, id);
  #|CREATE INDEX IF NOT EXISTS vault_use_ambiguous_vault_v2 ON vault_use_ambiguous_v2 (ws, vault, at DESC, id DESC)
  #|  WHERE dirty = 0 AND is_use = 1;
  #|CREATE INDEX IF NOT EXISTS vault_use_ambiguous_owner_v2 ON vault_use_ambiguous_v2 (ws, vault, owner, at DESC, id DESC)
  #|  WHERE dirty = 0 AND is_use = 1;
  #|CREATE TABLE IF NOT EXISTS vault_use_ambiguous_audit_v2 (
  #|  ws TEXT PRIMARY KEY, after_id TEXT, done INTEGER NOT NULL
  #|) WITHOUT ROWID;
  #|CREATE TRIGGER IF NOT EXISTS vault_use_lookup_add AFTER INSERT ON vault_requests BEGIN
  #|  DELETE FROM vault_use_lookup WHERE ws = NEW.ws AND id = NEW.id;
  #|  INSERT OR REPLACE INTO vault_use_lookup
  #|    SELECT NEW.ws, NEW.id, json_extract(NEW.body, '$.vault'), json_extract(NEW.body, '$.owner'), json_extract(NEW.body, '$.at')
  #|    WHERE NEW.status IN ('granted', 'denied') AND json_extract(NEW.body, '$.save') IS NULL;
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS vault_use_lookup_change AFTER UPDATE ON vault_requests BEGIN
  #|  DELETE FROM vault_use_lookup WHERE ws = OLD.ws AND id = OLD.id;
  #|  INSERT OR REPLACE INTO vault_use_lookup
  #|    SELECT NEW.ws, NEW.id, json_extract(NEW.body, '$.vault'), json_extract(NEW.body, '$.owner'), json_extract(NEW.body, '$.at')
  #|    WHERE NEW.status IN ('granted', 'denied') AND json_extract(NEW.body, '$.save') IS NULL;
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS vault_use_lookup_drop AFTER DELETE ON vault_requests BEGIN
  #|  DELETE FROM vault_use_lookup WHERE ws = OLD.ws AND id = OLD.id;
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS vault_use_ambiguous_add_v2 AFTER INSERT ON vault_requests BEGIN
  #|  DELETE FROM vault_use_ambiguous_v2 WHERE ws = NEW.ws AND id = NEW.id;
  #|  INSERT OR IGNORE INTO vault_use_ambiguous_v2 (ws,id,dirty,is_use)
  #|    SELECT NEW.ws, NEW.id, 1, 0 WHERE NEW.status IN ('granted','denied') AND (CASE WHEN json_valid(NEW.body) THEN
  #|  (instr(NEW.body, '\ud') > 0 OR instr(NEW.body, '\uD') > 0 OR
  #|    (instr(NEW.body, '\u0000') > 0 AND EXISTS (SELECT 1 FROM json_each(NEW.body) WHERE instr(key, char(0)) > 0)) OR
  #|    EXISTS (SELECT 1 FROM json_each(NEW.body) WHERE key IN ('vault','owner','save','at') GROUP BY key HAVING count(*) > 1))
  #|  ELSE 0 END) = 1;
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS vault_use_ambiguous_change_v2 AFTER UPDATE ON vault_requests
  #|  WHEN OLD.ws IS NOT NEW.ws OR OLD.id IS NOT NEW.id OR OLD.status IS NOT NEW.status OR OLD.body IS NOT NEW.body BEGIN
  #|  DELETE FROM vault_use_ambiguous_v2 WHERE ws = OLD.ws AND id = OLD.id;
  #|  DELETE FROM vault_use_ambiguous_v2 WHERE ws = NEW.ws AND id = NEW.id;
  #|  INSERT OR IGNORE INTO vault_use_ambiguous_v2 (ws,id,dirty,is_use)
  #|    SELECT NEW.ws, NEW.id, 1, 0 WHERE NEW.status IN ('granted','denied') AND (CASE WHEN json_valid(NEW.body) THEN
  #|  (instr(NEW.body, '\ud') > 0 OR instr(NEW.body, '\uD') > 0 OR
  #|    (instr(NEW.body, '\u0000') > 0 AND EXISTS (SELECT 1 FROM json_each(NEW.body) WHERE instr(key, char(0)) > 0)) OR
  #|    EXISTS (SELECT 1 FROM json_each(NEW.body) WHERE key IN ('vault','owner','save','at') GROUP BY key HAVING count(*) > 1))
  #|  ELSE 0 END) = 1;
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS vault_use_ambiguous_drop_v2 AFTER DELETE ON vault_requests BEGIN
  #|  DELETE FROM vault_use_ambiguous_v2 WHERE ws = OLD.ws AND id = OLD.id;
  #|END;
  #|CREATE TABLE IF NOT EXISTS vault_cross_use_lookup (
  #|  ws TEXT NOT NULL, id TEXT NOT NULL, owner TEXT NOT NULL, at INTEGER,
  #|  PRIMARY KEY (ws, id)
  #|) WITHOUT ROWID;
  #|CREATE INDEX IF NOT EXISTS vault_cross_use_owner ON vault_cross_use_lookup (ws, owner, at DESC, id DESC);
  #|CREATE TRIGGER IF NOT EXISTS vault_cross_use_add AFTER INSERT ON vault_requests BEGIN
  #|  DELETE FROM vault_cross_use_lookup WHERE ws = NEW.ws AND id = NEW.id;
  #|  INSERT OR REPLACE INTO vault_cross_use_lookup
  #|    SELECT NEW.ws, NEW.id, json_extract(NEW.body, '$.owner'), json_extract(NEW.body, '$.at')
  #|    WHERE NEW.status IN ('granted', 'denied') AND json_valid(NEW.body) AND json_type(NEW.body, '$.cross') = 'object' AND json_type(NEW.body, '$.owner') = 'text';
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS vault_cross_use_change AFTER UPDATE ON vault_requests
  #|  WHEN OLD.ws IS NOT NEW.ws OR OLD.id IS NOT NEW.id OR OLD.status IS NOT NEW.status OR OLD.body IS NOT NEW.body BEGIN
  #|  DELETE FROM vault_cross_use_lookup WHERE ws = OLD.ws AND id = OLD.id;
  #|  DELETE FROM vault_cross_use_lookup WHERE ws = NEW.ws AND id = NEW.id;
  #|  INSERT OR REPLACE INTO vault_cross_use_lookup
  #|    SELECT NEW.ws, NEW.id, json_extract(NEW.body, '$.owner'), json_extract(NEW.body, '$.at')
  #|    WHERE NEW.status IN ('granted', 'denied') AND json_valid(NEW.body) AND json_type(NEW.body, '$.cross') = 'object' AND json_type(NEW.body, '$.owner') = 'text';
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS vault_cross_use_drop AFTER DELETE ON vault_requests BEGIN
  #|  DELETE FROM vault_cross_use_lookup WHERE ws = OLD.ws AND id = OLD.id;
  #|END;
  #|INSERT OR IGNORE INTO vault_use_backfill_all (id, after_ws, done) VALUES (1, NULL, 0);
  #|

///|
let rebox_schema : String =
  #|
  #|CREATE TABLE IF NOT EXISTS vault_rebox_lookup (
  #|  ws TEXT NOT NULL, id TEXT NOT NULL, PRIMARY KEY (ws, id)
  #|) WITHOUT ROWID;
  #|CREATE TABLE IF NOT EXISTS vault_rebox_backfill (
  #|  id INTEGER PRIMARY KEY CHECK (id = 1), after_ws TEXT, after_id TEXT, done INTEGER NOT NULL
  #|);
  #|CREATE TRIGGER IF NOT EXISTS vault_rebox_add AFTER INSERT ON vault_requests BEGIN
  #|  DELETE FROM vault_rebox_lookup WHERE ws = NEW.ws AND id = NEW.id AND NEW.status != 'pending';
  #|  INSERT INTO vault_rebox_lookup SELECT NEW.ws, NEW.id WHERE NEW.status = 'pending'
  #|    ON CONFLICT(ws, id) DO NOTHING;
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS vault_rebox_change AFTER UPDATE ON vault_requests
  #|  WHEN (OLD.status = 'pending' OR NEW.status = 'pending')
  #|    AND (OLD.ws IS NOT NEW.ws OR OLD.id IS NOT NEW.id OR OLD.status IS NOT NEW.status) BEGIN
  #|  DELETE FROM vault_rebox_lookup WHERE ws = OLD.ws AND id = OLD.id;
  #|  INSERT INTO vault_rebox_lookup SELECT NEW.ws, NEW.id WHERE NEW.status = 'pending'
  #|    ON CONFLICT(ws, id) DO NOTHING;
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS vault_rebox_drop AFTER DELETE ON vault_requests WHEN OLD.status = 'pending' BEGIN
  #|  DELETE FROM vault_rebox_lookup WHERE ws = OLD.ws AND id = OLD.id;
  #|END;
  #|INSERT OR IGNORE INTO vault_rebox_backfill (id, after_ws, after_id, done)
  #|  VALUES (1, NULL, NULL, CASE WHEN EXISTS (SELECT 1 FROM vault_requests LIMIT 1) THEN 0 ELSE 1 END);
  #|

///|
let signin_save_schema : String =
  #|
  #|CREATE TABLE IF NOT EXISTS signin_save_lookup (ask TEXT PRIMARY KEY, session TEXT NOT NULL, save TEXT NOT NULL) WITHOUT ROWID;
  #|CREATE INDEX IF NOT EXISTS signin_save_by_request ON signin_save_lookup (session, save, ask);
  #|CREATE TABLE IF NOT EXISTS signin_save_progress (session TEXT PRIMARY KEY, status TEXT, row INTEGER, done INTEGER NOT NULL) WITHOUT ROWID;
  #|CREATE TABLE IF NOT EXISTS signin_save_pending (session TEXT NOT NULL, save TEXT NOT NULL, status TEXT NOT NULL,
  #|  PRIMARY KEY (session, save)) WITHOUT ROWID;
  #|CREATE TRIGGER IF NOT EXISTS signin_save_add AFTER INSERT ON signin_asks BEGIN DELETE FROM signin_save_lookup WHERE ask = NEW.id AND
  #|  (session IS NOT NEW.session OR save IS NOT json_extract(NEW.body, '$.save')); INSERT INTO signin_save_lookup (ask, session, save)
  #|  SELECT NEW.id, NEW.session, json_extract(NEW.body, '$.save')
  #|  WHERE json_type(NEW.body, '$.save') = 'text' AND NOT EXISTS (SELECT 1 FROM signin_save_lookup WHERE ask = NEW.id); END;
  #|CREATE TRIGGER IF NOT EXISTS signin_save_change AFTER UPDATE OF id, session, body ON signin_asks BEGIN
  #|  DELETE FROM signin_save_lookup WHERE ask = OLD.id AND OLD.id IS NOT NEW.id;
  #|  DELETE FROM signin_save_lookup WHERE ask = NEW.id AND
  #|  (session IS NOT NEW.session OR save IS NOT json_extract(NEW.body, '$.save')); INSERT INTO signin_save_lookup (ask, session, save)
  #|  SELECT NEW.id, NEW.session, json_extract(NEW.body, '$.save')
  #|  WHERE json_type(NEW.body, '$.save') = 'text' AND NOT EXISTS (SELECT 1 FROM signin_save_lookup WHERE ask = NEW.id);
  #|END;
  #|CREATE TRIGGER IF NOT EXISTS signin_save_drop AFTER DELETE ON signin_asks BEGIN
  #|  DELETE FROM signin_save_lookup WHERE ask = OLD.id;
  #|END;

///|
let store_schema : String =
  #|
  #|CREATE TABLE IF NOT EXISTS vaults (
  #|  ws TEXT NOT NULL,
  #|  id TEXT NOT NULL,
  #|  seq INTEGER NOT NULL,
  #|  body TEXT NOT NULL,
  #|  PRIMARY KEY (ws, id)
  #|);
  #|CREATE TABLE IF NOT EXISTS vault_items (
  #|  ws TEXT NOT NULL,
  #|  vault TEXT NOT NULL,
  #|  id TEXT NOT NULL,
  #|  version INTEGER NOT NULL,
  #|  body TEXT NOT NULL,
  #|  PRIMARY KEY (ws, vault, id)
  #|);
  #|CREATE TABLE IF NOT EXISTS vault_boxes (
  #|  ws TEXT NOT NULL,
  #|  device TEXT NOT NULL,
  #|  body TEXT NOT NULL,
  #|  PRIMARY KEY (ws, device)
  #|);
  #|-- A previous station can have validated a write before this station commits a deletion. These checks also apply to
  #|-- its already-prepared UPSERT statements when it resumes, without scanning old rows during installation.
  #|CREATE TRIGGER IF NOT EXISTS vault_item_deleted_insert BEFORE INSERT ON vault_items
  #|  WHEN EXISTS (SELECT 1 FROM vaults v WHERE v.ws = NEW.ws AND v.id = NEW.vault
  #|    AND CASE WHEN json_valid(v.body) THEN json_type(v.body, '$.deleted') = 'true' ELSE 0 END)
  #|  BEGIN SELECT RAISE(ABORT, 'vault was deleted during the write'); END;
  #|CREATE TRIGGER IF NOT EXISTS vault_item_deleted_update BEFORE UPDATE ON vault_items
  #|  WHEN EXISTS (SELECT 1 FROM vaults v WHERE v.ws = NEW.ws AND v.id = NEW.vault
  #|    AND CASE WHEN json_valid(v.body) THEN json_type(v.body, '$.deleted') = 'true' ELSE 0 END)
  #|  BEGIN SELECT RAISE(ABORT, 'vault was deleted during the write'); END;
  #|CREATE TRIGGER IF NOT EXISTS vault_deleted_stays_deleted_insert BEFORE INSERT ON vaults
  #|  WHEN EXISTS (SELECT 1 FROM vaults v WHERE v.ws = NEW.ws AND v.id = NEW.id
  #|    AND CASE WHEN json_valid(v.body) THEN json_type(v.body, '$.deleted') = 'true' ELSE 0 END)
  #|    AND (CASE WHEN json_valid(NEW.body) THEN json_type(NEW.body, '$.deleted') IS NOT 'true' ELSE 1 END)
  #|  BEGIN SELECT RAISE(ABORT, 'vault was deleted during the write'); END;
  #|CREATE TRIGGER IF NOT EXISTS vault_deleted_stays_deleted BEFORE UPDATE OF body ON vaults
  #|  WHEN (CASE WHEN json_valid(OLD.body) THEN json_type(OLD.body, '$.deleted') = 'true' ELSE 0 END)
  #|    AND (CASE WHEN json_valid(NEW.body) THEN json_type(NEW.body, '$.deleted') IS NOT 'true' ELSE 1 END)
  #|  BEGIN SELECT RAISE(ABORT, 'vault was deleted during the write'); END;
  #|-- Older stations save the deleted version and remove its items in separate statements. Do the removal inside their
  #|-- first statement as well, so a crash or error between those statements does not leave the items behind.
  #|CREATE TRIGGER IF NOT EXISTS vault_deleted_items_insert AFTER INSERT ON vaults
  #|  WHEN CASE WHEN json_valid(NEW.body) THEN json_type(NEW.body, '$.deleted') = 'true' ELSE 0 END
  #|  BEGIN DELETE FROM vault_items WHERE ws = NEW.ws AND vault = NEW.id; END;
  #|CREATE TRIGGER IF NOT EXISTS vault_deleted_items_update AFTER UPDATE OF body ON vaults
  #|  WHEN CASE WHEN json_valid(NEW.body) THEN json_type(NEW.body, '$.deleted') = 'true' ELSE 0 END
  #|  BEGIN DELETE FROM vault_items WHERE ws = NEW.ws AND vault = NEW.id; END;
  #|

///|
let requests_schema : String =
  #|
  #|CREATE TABLE IF NOT EXISTS vault_requests (
  #|  ws TEXT NOT NULL,
  #|  id TEXT NOT NULL,
  #|  session TEXT NOT NULL,
  #|  status TEXT NOT NULL,
  #|  body TEXT NOT NULL,
  #|  thread INTEGER,
  #|  card_ts TEXT,
  #|  PRIMARY KEY (ws, id)
  #|);
  #|CREATE TABLE IF NOT EXISTS vault_audit (
  #|  ws TEXT NOT NULL,
  #|  at INTEGER NOT NULL,
  #|  request TEXT NOT NULL,
  #|  vault TEXT NOT NULL,
  #|  item TEXT NOT NULL,
  #|  session TEXT NOT NULL,
  #|  kind TEXT NOT NULL,
  #|  detail TEXT NOT NULL
  #|);
  #|CREATE TABLE IF NOT EXISTS vault_renewals (
  #|  ws TEXT NOT NULL,
  #|  item TEXT NOT NULL,
  #|  body TEXT NOT NULL,
  #|  PRIMARY KEY (ws, item)
  #|);
  #|CREATE TABLE IF NOT EXISTS vault_grants (
  #|  ws TEXT NOT NULL,
  #|  id TEXT NOT NULL,
  #|  session TEXT NOT NULL,
  #|  body TEXT NOT NULL,
  #|  PRIMARY KEY (ws, id)
  #|);
  #|-- A session's grants (move/vault.ts: whose secrets a chat that moves needs).
  #|CREATE INDEX IF NOT EXISTS vault_grants_session ON vault_grants (session);
  #|CREATE TABLE IF NOT EXISTS vault_cross_listings (
  #|  ws TEXT NOT NULL,
  #|  session TEXT NOT NULL,
  #|  item TEXT NOT NULL,
  #|  body TEXT NOT NULL,
  #|  at INTEGER NOT NULL,
  #|  PRIMARY KEY (ws, session, item)
  #|) WITHOUT ROWID;
  #|CREATE INDEX IF NOT EXISTS vault_cross_listings_session ON vault_cross_listings (session, ws, item);
  #|

///|
let signin_schema : String =
  #|CREATE TABLE IF NOT EXISTS signin_asks (
  #|  id TEXT PRIMARY KEY,
  #|  session TEXT NOT NULL,
  #|  owner TEXT NOT NULL,
  #|  status TEXT NOT NULL,
  #|  body TEXT NOT NULL
  #|);
  #|CREATE INDEX IF NOT EXISTS signin_asks_by_session ON signin_asks (session, status);
