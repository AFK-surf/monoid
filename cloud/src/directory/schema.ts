import { nowSeconds } from "../auth";
import { MESH_RELAY_TABLES } from "../mesh-relay-registry";
import { RELAY_TABLES } from "../relay-registry";
import type { DirectoryDb } from "./db";

/** Sets up Durable Object SQLite tables and forward-only column migrations. */
export function initSchema(db: DirectoryDb, runMigrations: { freePlan(): void; stationMembers(): void }): void {
  db.ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS users (sub TEXT PRIMARY KEY, email TEXT NOT NULL, name TEXT NOT NULL DEFAULT '', picture TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL, last_seen INTEGER, admitted TEXT, beta INTEGER);
      CREATE TABLE IF NOT EXISTS workspaces (id TEXT PRIMARY KEY, name TEXT NOT NULL, created_by TEXT NOT NULL, created_at INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS workspaces_by_creator ON workspaces (created_by);
      CREATE TABLE IF NOT EXISTS told (workspace TEXT PRIMARY KEY, rev INTEGER NOT NULL, view TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS members (workspace TEXT NOT NULL, sub TEXT NOT NULL, role TEXT NOT NULL, added_at INTEGER NOT NULL, PRIMARY KEY (workspace, sub));
      CREATE INDEX IF NOT EXISTS members_by_user ON members (sub);
      CREATE TABLE IF NOT EXISTS invitations (id TEXT PRIMARY KEY, workspace TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE, role TEXT NOT NULL, email TEXT, created_by TEXT NOT NULL, expires_at INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS invitations_by_email ON invitations (email, expires_at);
      CREATE INDEX IF NOT EXISTS invitations_by_workspace ON invitations (workspace, expires_at);
      CREATE TABLE IF NOT EXISTS stations (id TEXT PRIMARY KEY, last_seen INTEGER, version TEXT);
      CREATE TABLE IF NOT EXISTS station_members (workspace TEXT NOT NULL, station TEXT NOT NULL, name TEXT NOT NULL, emoji TEXT, icon TEXT, enrolled_at INTEGER NOT NULL, enrolled_by TEXT NOT NULL, PRIMARY KEY (workspace, station));
      CREATE INDEX IF NOT EXISTS station_members_by_station ON station_members (station, enrolled_at);
      CREATE TABLE IF NOT EXISTS enrollments (token_hash TEXT PRIMARY KEY, workspace TEXT NOT NULL, name TEXT NOT NULL, created_by TEXT NOT NULL, expires_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS revocations (workspace TEXT NOT NULL, kind TEXT NOT NULL, id TEXT NOT NULL, at INTEGER NOT NULL, PRIMARY KEY (workspace, kind, id));
      CREATE TABLE IF NOT EXISTS added (workspace TEXT NOT NULL, email TEXT NOT NULL, role TEXT NOT NULL, added_by TEXT NOT NULL, added_at INTEGER NOT NULL, PRIMARY KEY (workspace, email));
      CREATE INDEX IF NOT EXISTS added_by_email ON added (email);
      CREATE TABLE IF NOT EXISTS added_mails (workspace TEXT NOT NULL, email TEXT NOT NULL, at INTEGER NOT NULL, PRIMARY KEY (workspace, email));
      CREATE TABLE IF NOT EXISTS added_mail_retries (workspace TEXT NOT NULL, email TEXT NOT NULL, PRIMARY KEY (workspace, email));
      CREATE TABLE IF NOT EXISTS pending (email TEXT PRIMARY KEY, beta INTEGER, may_create INTEGER, added_by TEXT NOT NULL, added_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS invite_codes (code TEXT PRIMARY KEY, note TEXT NOT NULL DEFAULT '', created_by TEXT NOT NULL, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, revoked_at INTEGER, used_by TEXT, used_at INTEGER, workspace TEXT);
      CREATE TABLE IF NOT EXISTS push (id TEXT PRIMARY KEY, sub TEXT NOT NULL, sid TEXT NOT NULL, kind TEXT NOT NULL, endpoint TEXT, p256dh TEXT, auth TEXT, token TEXT, created INTEGER NOT NULL);
      CREATE UNIQUE INDEX IF NOT EXISTS push_by_endpoint ON push (sub, endpoint);
      CREATE UNIQUE INDEX IF NOT EXISTS push_by_token ON push (sub, token);
      CREATE INDEX IF NOT EXISTS push_by_user ON push (sub, sid);
      CREATE TABLE IF NOT EXISTS feedback (id TEXT PRIMARY KEY, number INTEGER NOT NULL UNIQUE, key TEXT NOT NULL, channel TEXT NOT NULL, sender TEXT NOT NULL, station TEXT, workspace TEXT, account TEXT, title TEXT NOT NULL, body TEXT NOT NULL, area TEXT NOT NULL, reporter TEXT NOT NULL DEFAULT '', context TEXT, logs TEXT, status TEXT NOT NULL DEFAULT 'new', created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
      CREATE UNIQUE INDEX IF NOT EXISTS feedback_by_key ON feedback (sender, key);
      CREATE INDEX IF NOT EXISTS feedback_by_sender ON feedback (sender, created_at);
      CREATE INDEX IF NOT EXISTS feedback_by_station ON feedback (station, number);
      CREATE TABLE IF NOT EXISTS feedback_replies (id TEXT PRIMARY KEY, feedback TEXT NOT NULL, author TEXT NOT NULL, by TEXT NOT NULL DEFAULT '', text TEXT NOT NULL, created_at INTEGER NOT NULL, delivered_at INTEGER);
      CREATE INDEX IF NOT EXISTS feedback_replies_by_feedback ON feedback_replies (feedback, created_at);
      CREATE TABLE IF NOT EXISTS migrations (name TEXT PRIMARY KEY, at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS lock_entries (workspace TEXT NOT NULL, seq INTEGER NOT NULL, hash TEXT NOT NULL, entry TEXT NOT NULL, PRIMARY KEY (workspace, seq));
      CREATE TABLE IF NOT EXISTS devices (workspace TEXT NOT NULL, sub TEXT NOT NULL, device TEXT NOT NULL, base TEXT, kind TEXT, label TEXT, first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL, PRIMARY KEY (workspace, sub, device));
      CREATE TABLE IF NOT EXISTS lock_aside (workspace TEXT NOT NULL, hash TEXT NOT NULL, entry TEXT NOT NULL, PRIMARY KEY (workspace, hash));
      CREATE TABLE IF NOT EXISTS lock_turned_off (workspace TEXT NOT NULL, genesis TEXT NOT NULL, seq INTEGER NOT NULL, entry TEXT NOT NULL, PRIMARY KEY (workspace, genesis, seq));
      CREATE TABLE IF NOT EXISTS lock_requests (workspace TEXT NOT NULL, base TEXT NOT NULL, sub TEXT NOT NULL, request TEXT NOT NULL, created_at INTEGER NOT NULL, PRIMARY KEY (workspace, base));
      CREATE INDEX IF NOT EXISTS users_by_email ON users (lower(email));
      CREATE TABLE IF NOT EXISTS apple_identities (apple_sub TEXT PRIMARY KEY, user_sub TEXT NOT NULL, email TEXT NOT NULL, refresh_token TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS apple_identities_by_user ON apple_identities (user_sub);
      CREATE TABLE IF NOT EXISTS outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, key TEXT NOT NULL, body TEXT NOT NULL, tries INTEGER NOT NULL DEFAULT 0, next_at INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS live (kind TEXT NOT NULL, key TEXT NOT NULL, gen INTEGER NOT NULL, PRIMARY KEY (kind, key));
      CREATE TABLE IF NOT EXISTS hits (hour INTEGER NOT NULL, family TEXT NOT NULL, n INTEGER NOT NULL, PRIMARY KEY (hour, family));
      CREATE TABLE IF NOT EXISTS operators (sub TEXT PRIMARY KEY, email TEXT NOT NULL, seen_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS admin_audit (id TEXT PRIMARY KEY, created_at INTEGER NOT NULL, actor TEXT NOT NULL, action TEXT NOT NULL, target TEXT NOT NULL DEFAULT '', detail TEXT NOT NULL DEFAULT '');
      CREATE INDEX IF NOT EXISTS idx_admin_audit_at ON admin_audit (created_at DESC);
      CREATE TABLE IF NOT EXISTS admin_keys (id TEXT PRIMARY KEY, name TEXT NOT NULL, prefix TEXT NOT NULL, key_hash TEXT NOT NULL UNIQUE, created_by TEXT NOT NULL, created_by_email TEXT NOT NULL, created_at INTEGER NOT NULL, expires_at INTEGER, last_used_at INTEGER, revoked_at INTEGER);
      CREATE INDEX IF NOT EXISTS admin_keys_hash ON admin_keys (key_hash);
      CREATE TABLE IF NOT EXISTS provision_keys (id TEXT PRIMARY KEY, workspace TEXT NOT NULL, name TEXT NOT NULL, prefix TEXT NOT NULL, key_hash TEXT NOT NULL UNIQUE, created_by TEXT NOT NULL, created_at INTEGER NOT NULL, expires_at INTEGER, last_used_at INTEGER, revoked_at INTEGER);
      CREATE INDEX IF NOT EXISTS provision_keys_workspace ON provision_keys (workspace, created_at DESC);
    `);
  // users had neither column before invite codes, nor beta (1: let into the test channel) before it, nor blocked (1:
  // the admin blocked the account; the account's own object is what keeps it out) before the console could block,
  // nor own_picture (the picture the account put up for itself: setOwnPicture) before it could; the table in
  // production gains them here.
  const columns = new Set(db.rows("PRAGMA table_info(users)").map((r) => r.name as string));
  for (const column of ["last_seen INTEGER", "admitted TEXT", "beta INTEGER", "blocked INTEGER", "own_picture TEXT"]) {
    if (!columns.has(column.split(" ")[0]!)) db.run(`ALTER TABLE users ADD COLUMN ${column}`);
  }
  // Nor had feedback where it was fixed (the changelog's version and parts, changelog.ts) and when its station was
  // told, before the changelog.
  const reported = new Set(db.rows("PRAGMA table_info(feedback)").map((r) => r.name as string));
  for (const column of ["fixed_in INTEGER", "fixed_parts TEXT", "told_at INTEGER"]) {
    if (!reported.has(column.split(" ")[0]!)) db.run(`ALTER TABLE feedback ADD COLUMN ${column}`);
  }
  // Nor had invite codes the test channel to give with them (1), before they could.
  if (!db.rows("PRAGMA table_info(invite_codes)").some((r) => r.name === "beta")) db.run("ALTER TABLE invite_codes ADD COLUMN beta INTEGER");
  // Nor had workspaces relays of their own (a JSON array of URLs, null for none), before they could have.
  if (!db.rows("PRAGMA table_info(workspaces)").some((r) => r.name === "relays")) db.run("ALTER TABLE workspaces ADD COLUMN relays TEXT");
  // Nor ways turned off (a JSON array of relay URLs and kinds of way, null for none: setWay), before they could be.
  if (!db.rows("PRAGMA table_info(workspaces)").some((r) => r.name === "ways_off")) db.run("ALTER TABLE workspaces ADD COLUMN ways_off TEXT");
  // Nor which record of its stations' those two are (`ways_at` its time in ms, `ways_station` the station that made
  // it, "" a change made here: #waysPut), before the stations said theirs.
  for (const column of ["ways_at INTEGER", "ways_station TEXT"]) {
    if (!db.rows("PRAGMA table_info(workspaces)").some((r) => r.name === column.split(" ")[0])) db.run(`ALTER TABLE workspaces ADD COLUMN ${column}`);
  }
  // Nor whether whoever signs in through the cloud's OpenID provider joins it (1: joinBySignIn), before a machine's
  // cloud let its organization's people in so (selfhost/setup.ts).
  if (!db.rows("PRAGMA table_info(workspaces)").some((r) => r.name === "sign_in_joins")) db.run("ALTER TABLE workspaces ADD COLUMN sign_in_joins INTEGER");
  // Nor did push keep a device's language, before there were languages.
  if (!db.rows("PRAGMA table_info(push)").some((r) => r.name === "lang")) db.run("ALTER TABLE push ADD COLUMN lang TEXT");
  // Nor what a device shows of notices (JSON: noticeText.ts Shows; null all, in full), before a device said.
  if (!db.rows("PRAGMA table_info(push)").some((r) => r.name === "shows")) db.run("ALTER TABLE push ADD COLUMN shows TEXT");
  // Nor whether an APNs token is a development build's (1) or not, before there was APNs.
  if (!db.rows("PRAGMA table_info(push)").some((r) => r.name === "sandbox")) db.run("ALTER TABLE push ADD COLUMN sandbox INTEGER");
  // The credential that last took an app's token (its Firebase project, its APNs topic: push.ts), tried first.
  if (!db.rows("PRAGMA table_info(push)").some((r) => r.name === "app")) db.run("ALTER TABLE push ADD COLUMN app TEXT");
  // Nor had workspaces a mark of their own (an emoji, an icon, as a station's), before they could; their first letter till then.
  const marked = new Set(db.rows("PRAGMA table_info(workspaces)").map((r) => r.name as string));
  for (const column of ["emoji TEXT", "icon TEXT"]) {
    if (!marked.has(column.split(" ")[0]!)) db.run(`ALTER TABLE workspaces ADD COLUMN ${column}`);
  }
  // Nor had workspaces limits of their own (people, stations; both or neither), before the admin could make one for
  // a company. max_stations stays for old clients and records; the current cap is shared by all workspaces.
  for (const column of ["max_members INTEGER", "max_stations INTEGER"]) {
    if (!marked.has(column.split(" ")[0]!)) db.run(`ALTER TABLE workspaces ADD COLUMN ${column}`);
  }
  runMigrations.freePlan();
  runMigrations.stationMembers();
  // A rig (a station that only runs tasks, 2026-11-10): a machine that only runs what the workspace's stations send it, its person's (the one
  // who added it: `enrolled_by`). `rig` is 1 on its row and on the enrollment that makes one; absent before them.
  for (const table of ["station_members", "enrollments"]) {
    if (!db.rows(`PRAGMA table_info(${table})`).some((r) => r.name === "rig")) db.run(`ALTER TABLE ${table} ADD COLUMN rig INTEGER`);
  }
  // The cloud's list of relays (relay-registry.ts), and the tokens made for relays to put themselves on it. (What a
  // deploy's config said before was taken as the list once, 2026-11-17: the `relays-listed` migration.)
  db.ctx.storage.sql.exec(RELAY_TABLES);
  db.ctx.storage.sql.exec(MESH_RELAY_TABLES);
}

/**
 * A station was in one workspace, its row in `stations` saying which and what it is called there (with an emoji and
 * an icon, which it gained later: absent from a table older than them). It may be in several now: `stations` keeps
 * the machine, `station_members` each workspace it is in, named there. An old table is
 * split here, each row into one of each; one already split has no `workspace` and is left alone.
 */
export function migrateStationMembers(db: DirectoryDb): void {
  const columns = new Set(db.rows("PRAGMA table_info(stations)").map((r) => r.name as string));
  if (!columns.has("workspace")) return;
  const kept = (column: string) => (columns.has(column) ? column : "NULL");
  db.ctx.storage.transactionSync(() => {
    db.run(`INSERT OR IGNORE INTO station_members (workspace, station, name, emoji, icon, enrolled_at, enrolled_by)
      SELECT workspace, id, name, ${kept("emoji")}, ${kept("icon")}, enrolled_at, enrolled_by FROM stations ORDER BY enrolled_at, rowid`);
    db.run("CREATE TABLE stations_split (id TEXT PRIMARY KEY, last_seen INTEGER, version TEXT)");
    db.run("INSERT INTO stations_split (id, last_seen, version) SELECT id, last_seen, version FROM stations");
    db.run("DROP TABLE stations");
    db.run("ALTER TABLE stations_split RENAME TO stations");
  });
}

/**
 * Before the free plan, having created a workspace was itself the right to create more; it is the standard plan's
 * now, so those who created one keep it as if the admin had said so. Once: creating on the free plan says 'free'.
 */
export function migrateFreePlan(db: DirectoryDb): void {
  if (db.one("SELECT 1 AS x FROM migrations WHERE name = 'free-plan'")) return;
  db.ctx.storage.transactionSync(() => {
    db.run(`UPDATE users SET admitted = 'granted' WHERE sub IN (SELECT created_by FROM workspaces)
      AND (admitted IS NULL OR admitted NOT IN ('code', 'granted')) AND NOT (admitted IS NULL AND sub IN (SELECT sub FROM members))`);
    db.run("INSERT INTO migrations (name, at) VALUES ('free-plan', ?)", nowSeconds());
  });
}
