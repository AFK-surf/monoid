import { ulid } from "ulid";
import { STATIONS_PER_WORKSPACE } from "../../../client/limits.ts";
import { CODE_TTL_DAYS, isAdmin, newCode, normalizeCode } from "../admin";
import { b64url, digest, nowSeconds } from "../auth";
import type { AccountEvent, AddedView, AdminAuditEntry, AdminKeyView, AdminList, AdminPending, AdminUser, AdminWorkspace, Admission, InviteCodeView, RigView, Role, StationView } from "../types";
import type { DirectoryDb, DirectoryHost } from "./db";
import { AUDIT_KEPT, AUDIT_LISTED, HOURS_KEPT, LIST, MOVE_SKIPPED, OPERATOR_KEPT_S, PLANS, SHOWN_PICTURE, cleanName, emailsOf, fail, limitsOf, type AddedMail, type Attachment, type DirectoryLoad, type Plan, type Row } from "./types";

const ADMIN_KEY_PREFIX = "sfa_";
const ADMIN_KEYS_MAX = 50;

// ── operators, audit, cloud move, and admin console ─────────────────────

export class DirectoryAdmin {
  #db: DirectoryDb;
  #host: DirectoryHost;
  #getCounts: () => Map<string, number> | undefined;

  /** When an account was last noted opening the console (noteOperator), by its sub: noted again at most hourly. */
  #operatorsSeen = new Map<string, number>();

  /** The console's lists that changed since this was last told, told once what changed now is done (a burst one event). */
  #adminLists = new Set<AdminList>();

  constructor(db: DirectoryDb, host: DirectoryHost, getCounts: () => Map<string, number> | undefined) {
    this.#db = db;
    this.#host = host;
    this.#getCounts = getCounts;
  }

  /**
   * Tells the operator's connected devices `event` (their console reads it again): its accounts, found by their email.
   * The cron's, every minute: what this object counted of its requests is kept then too (#keepCounts).
   */
  tellAdmins(event: AccountEvent): void {
    this.keepCounts();
    this.#host.tell(this.adminSubs(), event);
  }

  /**
   * An account the console answered (api.ts: its `/v1/me` there, and each of its calls): with Cloudflare Access, anyone
   * of the team, not ADMIN_EMAIL's alone. Kept a week from when it was last seen, to be told what the console shows
   * changed (#adminSubs).
   */
  noteOperator(sub: string, email: string): void {
    const now = nowSeconds();
    const seen = this.#operatorsSeen.get(sub) ?? (this.#db.one("SELECT seen_at FROM operators WHERE sub = ?", sub)?.seen_at as number | undefined);
    if (seen !== undefined && now - seen < 3600) return void this.#operatorsSeen.set(sub, seen);
    this.#db.run("INSERT INTO operators (sub, email, seen_at) VALUES (?, ?, ?) ON CONFLICT (sub) DO UPDATE SET email = excluded.email, seen_at = excluded.seen_at", sub, email, now);
    this.#db.run("DELETE FROM operators WHERE seen_at < ?", now - OPERATOR_KEPT_S);
    this.#operatorsSeen.set(sub, now);
  }

  /** The accounts that opened the console in the last week (noteOperator). */
  #operators(): string[] {
    return this.#db.rows("SELECT sub FROM operators WHERE seen_at >= ?", nowSeconds() - OPERATOR_KEPT_S).map((r) => r.sub as string);
  }

  /** Who is told what the console shows: ADMIN_EMAIL's accounts and those that opened it (with Access, its team). */
  adminSubs(): string[] {
    return [...new Set([...this.#db.byEmail(this.#db.env.ADMIN_EMAIL ?? null), ...this.#operators()])];
  }

  /** Whether an account is ADMIN_EMAIL's, which no operator of the console blocks. */
  isAdminAccount(sub: string): boolean {
    const row = this.#db.one("SELECT email FROM users WHERE sub = ?", sub);
    return !!row && isAdmin(this.#db.env, row.email as string);
  }

  /**
   * What the console shows changed: the accounts that opened it told which of its lists to read again (`admin`). Not
   * ADMIN_EMAIL's that did not: no console of theirs is open to read them.
   */
  adminChanged(...lists: AdminList[]): void {
    const first = this.#adminLists.size === 0;
    for (const list of lists) this.#adminLists.add(list);
    if (!first) return;
    queueMicrotask(() => {
      const changed = [...this.#adminLists].sort();
      this.#adminLists.clear();
      const operators = this.#operators();
      if (operators.length > 0 && changed.length > 0) this.#host.tell(operators, { type: "admin", lists: changed });
    });
  }

  // ── moving into another cloud (move.ts) ─────────────────────────────────

  /** Every table but what is of this object's own sockets and counts (MOVE_SKIPPED), row by row. */
  moveExport(): Record<string, Row[]> {
    const tables = this.#db.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE '\\_%' ESCAPE '\\' AND name NOT LIKE 'sqlite_%'").map((r) => r.name as string);
    return Object.fromEntries(tables.filter((t) => !MOVE_SKIPPED.has(t)).map((t) => [t, this.#db.rows(`SELECT * FROM "${t}"`)]));
  }

  /** Each of `tables` made what another cloud's moveExport said, in one transaction (its rows taken out first); what
   * a table here does not have of a row's columns refuses the whole. How many rows each now has. */
  moveImport(tables: Record<string, Row[]>): Record<string, number> {
    this.#host.resetFixesMarked();
    const here = new Set(this.#db.rows("SELECT name FROM sqlite_master WHERE type = 'table'").map((r) => r.name as string));
    return this.#db.ctx.storage.transactionSync(() => {
      const counts: Record<string, number> = {};
      for (const [table, rows] of Object.entries(tables)) {
        if (MOVE_SKIPPED.has(table) || !here.has(table) || !/^[a-z_]+$/.test(table)) throw new Error(`move: no table ${table}`);
        const columns = new Set(this.#db.rows(`PRAGMA table_info("${table}")`).map((r) => r.name as string));
        this.#db.run(`DELETE FROM "${table}"`);
        for (const row of rows) {
          const names = Object.keys(row);
          if (names.some((n) => !columns.has(n))) throw new Error(`move: ${table} has no column of ${names.join(",")}`);
          this.#db.run(`INSERT INTO "${table}" (${names.map((n) => `"${n}"`).join(", ")}) VALUES (${names.map(() => "?").join(", ")})`, ...names.map((n) => row[n] as SqlStorageValue));
        }
        counts[table] = rows.length;
      }
      return counts;
    });
  }

  /** The accounts there are (moving each one's object: move.ts). */
  moveAccounts(): string[] {
    return this.#db.rows("SELECT sub FROM users ORDER BY sub").map((r) => r.sub as string);
  }

  // ── what the operators changed (the console's 操作记录) ─────────────────────

  /** Notes a change an operator made (api.ts, index.ts): the newest AUDIT_KEPT kept. */
  recordAudit(actor: string, action: string, target = "", detail = ""): void {
    this.#db.run("INSERT INTO admin_audit (id, created_at, actor, action, target, detail) VALUES (?, ?, ?, ?, ?, ?)", ulid(), nowSeconds(), actor, action, target.slice(0, 200), detail.slice(0, 200));
    // (in the order they were noted: ids of one second are in no order of their own)
    this.#db.run(`DELETE FROM admin_audit WHERE rowid NOT IN (SELECT rowid FROM admin_audit ORDER BY created_at DESC, rowid DESC LIMIT ${AUDIT_KEPT})`);
    this.adminChanged("audit");
  }

  /** What an operator's change was to, as the console's record names it: `user:<sub>` its email, `workspace:<id>` its
   * name, `feedback:<id>` FB-<n>; anything else as it is. */
  auditName(ref: string): string {
    const [kind, id] = [ref.slice(0, ref.indexOf(":")), ref.slice(ref.indexOf(":") + 1)];
    if (kind === "user") return (this.#db.one("SELECT email FROM users WHERE sub = ?", id)?.email as string | undefined) ?? id;
    if (kind === "workspace") return (this.#db.one("SELECT name FROM workspaces WHERE id = ?", id)?.name as string | undefined) ?? id;
    if (kind === "feedback") {
      const n = this.#db.one("SELECT number FROM feedback WHERE id = ?", id)?.number;
      return typeof n === "number" ? `FB-${n}` : id;
    }
    return ref;
  }

  /** The operators' changes, newest first. */
  adminAudit(): AdminAuditEntry[] {
    return this.#db.rows(`SELECT id, created_at, actor, action, target, detail FROM admin_audit ORDER BY created_at DESC, rowid DESC LIMIT ${AUDIT_LISTED}`) as unknown as AdminAuditEntry[];
  }

  // ── the admin's console ─────────────────────────────────────────────────
  // The caller has checked that the account is the admin's (admin.ts).

  adminUsers(): AdminUser[] {
    const memberships = new Map<string, AdminUser["workspaces"]>();
    for (const row of this.#db.rows("SELECT m.sub, w.id, w.name, m.role FROM members m JOIN workspaces w ON w.id = m.workspace ORDER BY w.created_at")) {
      const list = memberships.get(row.sub as string) ?? [];
      list.push({ id: row.id as string, name: row.name as string, role: row.role as Role });
      memberships.set(row.sub as string, list);
    }
    return this.#db.rows(`SELECT sub, email, name, ${SHOWN_PICTURE} AS picture, created_at, last_seen, admitted, beta, blocked FROM users ORDER BY created_at DESC`).map((row) => {
      const sub = row.sub as string;
      const workspaces = memberships.get(sub) ?? [];
      const admin = isAdmin(this.#db.env, row.email as string);
      const admission: Admission | null = admin ? "admin" : (row.admitted as Admission | null) ?? (workspaces.length ? "early" : null);
      // As #standard has it, without a query per account.
      const mayCreate = admin || row.admitted === "code" || row.admitted === "granted" || (row.admitted === null && workspaces.length > 0);
      return {
        sub, email: row.email as string, name: row.name as string, picture: row.picture as string,
        created_at: row.created_at as number, last_seen: row.last_seen as number | null, admission, workspaces, beta: Boolean(row.beta),
        // creator: no longer keeps the standard plan by itself (#standard); false so the console lets it be taken back.
        may_create: mayCreate, plan: admin ? "admin" : mayCreate ? "standard" : "free", creator: false, blocked: Boolean(row.blocked),
      };
    });
  }

  /**
   * The admin puts an account on the standard plan, as a code would (`granted`), or back on the free one: `free` if it
   * created a workspace, `invitation` if it is only in others', or, in none, nothing. Its workspaces go with it (#plan);
   * what they hold beyond the free plan stays, only nothing more is let in.
   */
  setMayCreate(sub: string, on: boolean): { sub: string; may_create: boolean } {
    const row = this.#db.one("SELECT email FROM users WHERE sub = ?", sub);
    if (!row) fail(404, "user_not_found");
    if (on) this.#db.run("UPDATE users SET admitted = 'granted' WHERE sub = ? AND (admitted IS NULL OR admitted IN ('invitation', 'free'))", sub);
    else {
      const creator = this.#db.one("SELECT 1 AS x FROM workspaces WHERE created_by = ? LIMIT 1", sub);
      const member = this.#db.one("SELECT 1 AS x FROM members WHERE sub = ? LIMIT 1", sub);
      this.#db.run("UPDATE users SET admitted = ? WHERE sub = ?", creator ? "free" : member ? "invitation" : null, sub);
    }
    this.adminChanged("users", "workspaces");
    return { sub, may_create: isAdmin(this.#db.env, row!.email as string) || this.#host.standard(sub) };
  }

  /** The emails the admin gave rights to that nobody has signed in with yet, the latest first. */
  adminPending(): AdminPending[] {
    return this.#db.rows("SELECT email, beta, may_create, added_at FROM pending ORDER BY added_at DESC").map((row) => ({
      email: row.email as string, beta: Boolean(row.beta), may_create: Boolean(row.may_create), added_at: row.added_at as number,
    }));
  }

  /**
   * The admin gives rights to an email, which needs no one to have signed in with it: the test channel, the standard plan
   * (`beta`, `may_create`; one not given, or null, stays as it was). An account already signed in with it has them at once (`sub`,
   * the first such); otherwise the account that first signs in with it does (#takePending; `sub` null).
   */
  setPending(by: string, email: unknown, beta: boolean | null | undefined, mayCreate: boolean | null | undefined): { email: string; sub: string | null } {
    const address = typeof email === "string" ? email.trim().toLowerCase() : "";
    if (!/^[^\s@]{1,64}@[^\s@]{1,190}$/.test(address)) fail(400, "invalid_email");
    const accounts = this.#db.byEmail(address);
    if (accounts.length > 0) {
      for (const sub of accounts) {
        if (typeof beta === "boolean") this.#host.setBeta(sub, beta);
        if (typeof mayCreate === "boolean") this.#host.setMayCreate(sub, mayCreate);
      }
      return { email: address, sub: accounts[0]! };
    }
    const on = (v: boolean | null | undefined) => (typeof v === "boolean" ? (v ? 1 : 0) : null);
    this.#db.run(`INSERT INTO pending (email, beta, may_create, added_by, added_at) VALUES (?, COALESCE(?, 0), COALESCE(?, 0), ?, ?)
      ON CONFLICT (email) DO UPDATE SET beta = COALESCE(?, beta), may_create = COALESCE(?, may_create)`,
      address, on(beta), on(mayCreate), by, nowSeconds(), on(beta), on(mayCreate));
    this.adminChanged("users");
    return { email: address, sub: null };
  }

  /** Takes back the rights given to an email nobody has signed in with yet. */
  removePending(email: unknown): { ok: true } {
    this.#db.run("DELETE FROM pending WHERE email = ?", typeof email === "string" ? email.trim().toLowerCase() : "");
    this.adminChanged("users");
    return { ok: true };
  }

  /** Notes that the admin blocked the account or let it back (the account's own object is what keeps it out). */
  setBlocked(sub: string, on: boolean): void {
    this.#db.run("UPDATE users SET blocked = ? WHERE sub = ?", on ? 1 : null, sub);
    this.adminChanged("users");
  }

  /** Lets an account into the test channel (BETA_ORIGIN), or out of it. */
  setBeta(sub: string, on: boolean): { sub: string; beta: boolean } {
    if (!this.#db.one("SELECT 1 AS x FROM users WHERE sub = ?", sub)) fail(404, "user_not_found");
    this.#db.run("UPDATE users SET beta = ? WHERE sub = ?", on ? 1 : null, sub);
    this.betaTold(sub);
    // Its `/v1/me` says so: its devices read it again (the 测试版 switch of its stations comes or goes at once).
    this.#host.tell([sub], LIST);
    this.adminChanged("users");
    return { sub, beta: on };
  }

  /** Whether the account may use the test channel (its object asks once, then is told: #betaTold). */
  isBeta(sub: string): boolean {
    return Boolean(this.#db.one("SELECT beta FROM users WHERE sub = ?", sub)?.beta);
  }

  /** The account's object keeps whether it is let into the test channel (account.ts `live`): it is told it now. */
  betaTold(sub: string): void {
    this.#host.deliver("account", sub, { beta: Boolean(this.#db.one("SELECT beta FROM users WHERE sub = ?", sub)?.beta) }, { always: true });
  }

  /** The operator removes a workspace as its owner would; one made for a company may have no owner signed in yet. */
  async adminDeleteWorkspace(id: string): Promise<void> {
    if (!this.#db.one("SELECT 1 AS x FROM workspaces WHERE id = ?", id)) fail(404, "workspace_not_found");
    this.#host.removeWorkspace(id);
    await this.#host.delivered();
  }

  /**
   * The admin makes a workspace for a company (「企业 workspace」): its owners by email, members at once or
   * when they first sign in, and limits of its own, the creator's plan aside. The admin is its creator but not in it.
   */
  adminCreateWorkspace(by: string, input: { name?: unknown; owners?: unknown; members?: unknown; stations?: unknown }): { id: string; joined: string[]; added: string[] } {
    const name = cleanName(input.name) ?? fail(400, "invalid_name");
    const owners = emailsOf(input.owners);
    const limits = limitsOf(input);
    if (owners.length > limits.members) fail(429, "too_many_members");
    const id = ulid();
    this.#db.run("INSERT INTO workspaces (id, name, created_by, created_at, max_members, max_stations) VALUES (?, ?, ?, ?, ?, ?)", id, name, by, nowSeconds(), limits.members, limits.stations);
    const { joined, added } = this.#host.addEmails(by, id, "owner", owners);
    this.adminChanged("workspaces", "users");
    return { id, joined, added };
  }

  /**
   * The admin sets how many people a workspace may hold; stations have the shared limit. `reset` (or members null)
   * gives it back to its creator's plan: no limits of its own, an enterprise one no more.
   */
  adminSetLimits(workspace: string, input: { members?: unknown; stations?: unknown; reset?: unknown }): { members: number; stations: number; reset?: true } {
    if (!this.#db.one("SELECT 1 AS x FROM workspaces WHERE id = ?", workspace)) fail(404, "workspace_not_found");
    if (input.reset === true || input.members === null) {
      this.#db.run("UPDATE workspaces SET max_members = NULL, max_stations = NULL WHERE id = ?", workspace);
      this.adminChanged("workspaces");
      return { members: this.#host.memberCap(workspace), stations: STATIONS_PER_WORKSPACE, reset: true };
    }
    const limits = limitsOf(input);
    this.#db.run("UPDATE workspaces SET max_members = ?, max_stations = ? WHERE id = ?", limits.members, limits.stations, workspace);
    this.adminChanged("workspaces");
    return limits;
  }

  /**
   * An enrollment the admin makes without being in the workspace: a station installed for a company, before it is
   * theirs. Only a workspace made for a company (with its own member limit) none of whose owners has signed in yet; from then
   * on its stations are its owners' to add.
   */
  async adminEnrollment(by: string, workspace: string, name: unknown): Promise<{ token: string; expires_at: number }> {
    const w = this.#db.one("SELECT max_members FROM workspaces WHERE id = ?", workspace);
    if (!w) fail(404, "workspace_not_found");
    if (w!.max_members === null || this.#hasOwner(workspace)) fail(409, "not_before_owner");
    return this.#host.enrollment(by, workspace, name);
  }

  #hasOwner(workspace: string): boolean {
    return Boolean(this.#db.one("SELECT 1 AS x FROM members WHERE workspace = ? AND role = 'owner' LIMIT 1", workspace));
  }

  /**
   * The admin makes emails owners of a workspace it is not in (a company whose owner left, or lost their way in):
   * a member made one at once (the credentials it holds name its old role, as setRole's), an account not in it
   * joined, an email nobody signed in with added. Those told by mail as addMembers tells them (api.ts).
   */
  adminAddOwners(by: string, workspace: string, emails: unknown): { joined: string[]; added: string[]; already: string[]; mail: AddedMail } {
    if (!this.#db.one("SELECT 1 AS x FROM workspaces WHERE id = ?", workspace)) fail(404, "workspace_not_found");
    const wanted = emailsOf(emails);
    const promoted: string[] = [];
    const rest: string[] = [];
    for (const email of wanted) {
      const members = this.#db.rows("SELECT m.sub, m.role FROM members m JOIN users u ON u.sub = m.sub WHERE m.workspace = ? AND lower(u.email) = ?", workspace, email);
      if (members.length === 0) rest.push(email);
      else if (members.some((m) => m.role !== "owner")) promoted.push(email);
    }
    const subs: string[] = [];
    this.#db.ctx.storage.transactionSync(() => {
      for (const email of promoted) {
        for (const m of this.#db.rows("SELECT m.sub FROM members m JOIN users u ON u.sub = m.sub WHERE m.workspace = ? AND lower(u.email) = ? AND m.role != 'owner'", workspace, email)) {
          this.#db.run("UPDATE members SET role = 'owner' WHERE workspace = ? AND sub = ?", workspace, m.sub);
          this.#host.revoke(workspace, "sub", m.sub as string);
          subs.push(m.sub as string);
        }
      }
    });
    if (subs.length > 0) {
      this.#host.changed(workspace, false);
      this.#host.tell(subs, LIST);
    }
    const { joined, added, already } = rest.length > 0 ? this.#host.addEmails(by, workspace, "owner", rest) : { joined: [], added: [], already: [] };
    const owners = wanted.filter((e) => !promoted.includes(e) && !rest.includes(e));
    this.adminChanged("workspaces", "users");
    return { joined: [...promoted, ...joined], added, already: [...owners, ...already], mail: this.#host.toMail(by, workspace, joined, added, [], true) };
  }

  /** The admin takes back an email added to a workspace that has not signed in yet (one written wrong). */
  adminRemoveAdded(workspace: string, email: unknown): { ok: true } {
    if (typeof email !== "string" || email.trim() === "") fail(400, "invalid_email");
    if (!this.#db.one("SELECT 1 AS x FROM workspaces WHERE id = ?", workspace)) fail(404, "workspace_not_found");
    const address = (email as string).trim().toLowerCase();
    this.#db.run("DELETE FROM added WHERE workspace = ? AND email = ?", workspace, address);
    this.#host.forgetMailRetry(workspace, address);
    this.#host.changed(workspace, true);
    return { ok: true };
  }

  adminWorkspaces(): AdminWorkspace[] {
    const now = nowSeconds();
    // Three reads for all of them, grouped here: a query per workspace grows with every one made.
    const group = <T>(rows: Row[]): Map<string, T[]> => {
      const by = new Map<string, T[]>();
      for (const { workspace, ...rest } of rows) {
        const list = by.get(workspace as string) ?? [];
        list.push(rest as T);
        by.set(workspace as string, list);
      }
      return by;
    };
    const members = group<AdminWorkspace["members"][number]>(this.#db.rows(`SELECT m.workspace, m.sub, COALESCE(u.email, '') AS email, COALESCE(u.name, '') AS name,
      COALESCE(${SHOWN_PICTURE}, '') AS picture, m.role, m.added_at, u.last_seen FROM members m LEFT JOIN users u ON u.sub = m.sub ORDER BY m.added_at`));
    const stations = group<StationView>(this.#db.stationViews(null) as unknown as Row[]);
    const rigs = group<RigView>(this.#db.rigViews(null) as unknown as Row[]);
    const invitations = group<AdminWorkspace["invitations"][number]>(this.#db.rows(`SELECT i.workspace, i.id, i.role, i.email, i.created_by, i.expires_at,
      COALESCE(NULLIF(u.name, ''), u.email, '') AS inviter FROM invitations i LEFT JOIN users u ON u.sub = i.created_by WHERE i.expires_at > ? ORDER BY i.expires_at`, now));
    const added = group<AddedView>(this.#db.rows("SELECT workspace, email, role, added_by, added_at FROM added ORDER BY added_at"));
    // As #plan has it, in the same read.
    const plan = (w: Row): Plan => w.sub === null ? "free" : isAdmin(this.#db.env, w.email as string) ? "admin"
      : w.admitted === "code" || w.admitted === "granted" || (w.admitted === null && w.member) ? "standard" : "free";
    return this.#db.rows(`SELECT w.id, w.name, w.created_at, w.max_members, w.max_stations, u.sub, u.email, u.name AS user_name, ${SHOWN_PICTURE} AS picture, u.admitted,
      EXISTS (SELECT 1 FROM members m WHERE m.sub = u.sub) AS member FROM workspaces w
      LEFT JOIN users u ON u.sub = w.created_by ORDER BY w.created_at DESC`).map((w) => ({
      id: w.id as string,
      name: w.name as string,
      created_at: w.created_at as number,
      created_by: w.sub === null ? null : { sub: w.sub as string, email: w.email as string, name: w.user_name as string, picture: w.picture as string },
      members: members.get(w.id as string) ?? [],
      stations: stations.get(w.id as string) ?? [],
      invitations: invitations.get(w.id as string) ?? [],
      added: added.get(w.id as string) ?? [],
      // As adminEnrollment has it: one made for a company, none of its owners signed in yet.
      enrollable: w.max_members !== null && !(members.get(w.id as string) ?? []).some((m) => m.role === "owner"),
      // (none said with none, as before there were any)
      ...(rigs.has(w.id as string) ? { rigs: rigs.get(w.id as string)! } : {}),
      // As #memberCap has it: its own, or its creator's plan's. Stations use the same cap for all workspaces.
      station_seats: STATIONS_PER_WORKSPACE,
      ...(w.max_members !== null && w.max_stations !== null
        ? { seats: w.max_members as number, plan: "enterprise" as const }
        : { seats: PLANS[plan(w)].members, plan: plan(w) }),
    }));
  }

  /**
   * How loaded this object is, for the console (its 中继 page, relay-load.ts): its calls an hour by what they serve (the
   * last HOURS_KEPT hours, oldest first), the sockets it still holds (those of before their objects, which leave as
   * they reconnect), the objects told what is for their sockets, deliveries waiting to be tried again, and its storage.
   */
  adminLoad(): DirectoryLoad {
    this.keepCounts();
    const now = nowSeconds();
    const first = Math.floor(now / 3600) - HOURS_KEPT + 1;
    const families: Record<string, number[]> = {};
    for (const r of this.#db.rows("SELECT hour, family, n FROM hits WHERE hour >= ? ORDER BY hour", first)) {
      (families[r.family as string] ??= new Array<number>(HOURS_KEPT).fill(0))[(r.hour as number) - first] = r.n as number;
    }
    const held = this.#db.ctx.getWebSockets().map((ws) => ws.deserializeAttachment() as Attachment);
    const live = (kind: string) => this.#db.one("SELECT COUNT(*) AS n FROM live WHERE kind = ?", kind)!.n as number;
    return {
      at: now,
      calls: { start: first * 3600, step: 3600, families },
      held: { devices: held.filter((a) => "sub" in a).length, stations: held.filter((a) => "station" in a && !a.dropped).length },
      live: { accounts: live("account"), stations: live("station") },
      waiting: this.#db.one("SELECT COUNT(*) AS n FROM outbox")!.n as number,
      bytes: this.#db.ctx.storage.sql.databaseSize,
    };
  }

  /** The calls counted since it last ran, kept (the cron's minute: tellAdmins; adminLoad), and the hours past HOURS_KEPT gone. */
  keepCounts(): void {
    const counts = this.#getCounts();
    if (!counts?.size) return;
    this.#db.ctx.storage.transactionSync(() => {
      for (const [k, n] of counts) {
        const [hour, family] = k.split(" ");
        this.#db.run("INSERT INTO hits (hour, family, n) VALUES (?, ?, ?) ON CONFLICT (hour, family) DO UPDATE SET n = n + excluded.n", Number(hour), family!, n);
      }
      this.#db.run("DELETE FROM hits WHERE hour <= ?", Math.floor(nowSeconds() / 3600) - HOURS_KEPT);
    });
    counts.clear();
  }

  inviteCodes(): InviteCodeView[] {
    return this.#db.rows(`SELECT c.code, c.note, c.beta, c.created_at, c.expires_at, c.revoked_at, c.used_at, u.sub, u.email, u.name, ${SHOWN_PICTURE} AS picture, w.id, w.name AS workspace_name
      FROM invite_codes c LEFT JOIN users u ON u.sub = c.used_by LEFT JOIN workspaces w ON w.id = c.workspace ORDER BY c.created_at DESC, c.code`).map((row) => ({
      code: row.code as string,
      note: row.note as string,
      beta: Boolean(row.beta),
      created_at: row.created_at as number,
      expires_at: row.expires_at as number,
      revoked_at: row.revoked_at as number | null,
      used_at: row.used_at as number | null,
      used_by: row.sub === null ? null : { sub: row.sub as string, email: row.email as string, name: row.name as string, picture: row.picture as string },
      workspace: row.id === null ? null : { id: row.id as string, name: row.workspace_name as string },
    }));
  }

  /** A code; with `beta`, the account that redeems it is let into the test channel too. */
  createInviteCode(sub: string, note: unknown, days: unknown, beta = false): InviteCodeView {
    const clean = typeof note === "string" ? note.trim().replace(/\s+/g, " ") : "";
    if (clean.length > 200) fail(400, "invalid_note");
    const ttl = days === undefined ? CODE_TTL_DAYS : Number.isInteger(days) && (days as number) >= 1 && (days as number) <= 365 ? (days as number) : fail(400, "invalid_expiry");
    const code = newCode();
    const now = nowSeconds();
    this.#db.run("INSERT INTO invite_codes (code, note, created_by, created_at, expires_at, beta) VALUES (?, ?, ?, ?, ?, ?)", code, clean, sub, now, now + ttl * 24 * 60 * 60, beta ? 1 : null);
    this.adminChanged("invite-codes");
    return this.#host.inviteCodes().find((c) => c.code === code)!;
  }

  /** Stops an unused code from being redeemed; a used one has done its work and stays as it is. */
  revokeInviteCode(value: string): void {
    const code = normalizeCode(value) ?? fail(404, "invite_code_invalid");
    const row = this.#db.one("SELECT used_by FROM invite_codes WHERE code = ?", code);
    if (!row) fail(404, "invite_code_invalid");
    if (row!.used_by !== null) fail(409, "invite_code_used");
    this.#db.run("UPDATE invite_codes SET revoked_at = COALESCE(revoked_at, ?) WHERE code = ?", nowSeconds(), code);
    this.adminChanged("invite-codes");
  }

  // ── admin API keys ──────────────────────────────────────────────────────

  adminKeys(): AdminKeyView[] {
    return this.#db.rows("SELECT id, name, prefix, created_by, created_by_email, created_at, expires_at, last_used_at, revoked_at FROM admin_keys ORDER BY created_at DESC, id DESC").map((r) => ({
      id: r.id as string,
      name: r.name as string,
      prefix: r.prefix as string,
      created_by: r.created_by as string,
      created_by_email: r.created_by_email as string,
      created_at: r.created_at as number,
      expires_at: (r.expires_at as number | null) ?? null,
      last_used_at: (r.last_used_at as number | null) ?? null,
      revoked_at: (r.revoked_at as number | null) ?? null,
    }));
  }

  async createAdminKey(sub: string, email: string, name: unknown, days?: unknown): Promise<AdminKeyView & { key: string }> {
    const clean = cleanName(name) ?? fail(400, "invalid_name");
    const now = nowSeconds();
    let expiresAt: number | null = null;
    if (days !== undefined && days !== null) {
      if (typeof days !== "number" || !Number.isInteger(days) || days < 1 || days > 3650) fail(400, "invalid_days");
      expiresAt = now + (days as number) * 24 * 60 * 60;
    }
    const active = this.#db.one("SELECT COUNT(*) AS n FROM admin_keys WHERE revoked_at IS NULL AND (expires_at IS NULL OR expires_at > ?)", now)!.n as number;
    if (active >= ADMIN_KEYS_MAX) fail(409, "too_many_keys");
    const id = `ak_${ulid()}`;
    const raw = b64url(crypto.getRandomValues(new Uint8Array(32)));
    const key = `${ADMIN_KEY_PREFIX}${raw}`;
    const prefix = key.slice(0, 12);
    const keyHash = await digest(key);
    this.#db.run(
      "INSERT INTO admin_keys (id, name, prefix, key_hash, created_by, created_by_email, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      id, clean, prefix, keyHash, sub, email, now, expiresAt,
    );
    this.#host.adminChanged("keys");
    return { id, name: clean, prefix, created_by: sub, created_by_email: email, created_at: now, expires_at: expiresAt, last_used_at: null, revoked_at: null, key };
  }

  revokeAdminKey(id: unknown): { id: string; name: string; prefix: string; ok: true } {
    if (typeof id !== "string" || !id) fail(404, "key_not_found");
    const keyId = id as string;
    const row = this.#db.one("SELECT id, name, prefix, revoked_at FROM admin_keys WHERE id = ?", keyId);
    if (!row) fail(404, "key_not_found");
    if (row!.revoked_at === null) {
      this.#db.run("UPDATE admin_keys SET revoked_at = ? WHERE id = ?", nowSeconds(), keyId);
      this.#host.adminChanged("keys");
    }
    return { id: row!.id as string, name: row!.name as string, prefix: row!.prefix as string, ok: true };
  }

  verifyAdminKey(keyHash: string): { id: string; name: string; prefix: string; created_by: string; created_by_email: string } | null {
    const now = nowSeconds();
    const row = this.#db.one(
      "SELECT id, name, prefix, created_by, created_by_email, last_used_at FROM admin_keys WHERE key_hash = ? AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at > ?)",
      keyHash, now,
    );
    if (!row) return null;
    const last = row.last_used_at as number | null;
    if (last === null || now - last >= 300) {
      this.#db.run("UPDATE admin_keys SET last_used_at = ? WHERE id = ?", now, row.id);
    }
    return {
      id: row.id as string,
      name: row.name as string,
      prefix: row.prefix as string,
      created_by: row.created_by as string,
      created_by_email: row.created_by_email as string,
    };
  }
}
