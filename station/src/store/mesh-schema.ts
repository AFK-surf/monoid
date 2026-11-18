// Bounded mesh identity state; created with the store before its reader opens.
export const ENROLLMENT_TABLES = `
CREATE TABLE IF NOT EXISTS mesh_relay_tokens (
  hash TEXT PRIMARY KEY, scope TEXT NOT NULL, name TEXT NOT NULL,
  made_by TEXT NOT NULL, expires INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS mesh_relay_tokens_scope ON mesh_relay_tokens(scope, expires);
CREATE TABLE IF NOT EXISTS mesh_relay_registrations (
  scope TEXT NOT NULL, node TEXT NOT NULL, issuer TEXT NOT NULL,
  generation INTEGER NOT NULL, name TEXT NOT NULL, made_by TEXT NOT NULL,
  revoked INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(scope, node)
);
`;
export const ANNOUNCEMENT_TABLE = `CREATE TABLE IF NOT EXISTS mesh_announcements (
 scope TEXT NOT NULL, node TEXT NOT NULL, revision INTEGER NOT NULL, body TEXT NOT NULL, signature TEXT NOT NULL,
 PRIMARY KEY(scope, node)
);`;
export const RELAY_RECORD_TABLE = `CREATE TABLE IF NOT EXISTS mesh_relay_records (
 scope TEXT NOT NULL, node TEXT NOT NULL, issuer TEXT NOT NULL, generation INTEGER NOT NULL,
 body TEXT NOT NULL, signature TEXT NOT NULL, PRIMARY KEY(scope,node)
);`;
