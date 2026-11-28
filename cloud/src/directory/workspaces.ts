import { ulid } from "ulid";
import { isAdmin, normalizeCode } from "../admin";
import { clock, nowSeconds, type Identity } from "../auth";
import { publicOrigins } from "../compat";
import { MAX_RELAYS, parseRelays, relays, relayUrls, sameUrl, waysOf } from "../relays";
import type { AccountEvent, AddedView, InvitationView, MeView, MemberView, Role, ViewTold, WorkspaceSummary, WorkspaceView } from "../types";
import type { DirectoryDb, DirectoryHost } from "./db";
import { LIST, MANAGERS, PLANS, ROLES, SHOWN_PICTURE, cleanEmoji, cleanIcon, cleanName, cleanPicture, fail, marks, offOf, viewTold, type AlikeView, type ChangedView, type Plan } from "./types";

// ── workspaces, accounts, sign-in, and view diffs ───────────────────────

export class DirectoryWorkspaces {
  #db: DirectoryDb;
  #host: DirectoryHost;

  constructor(db: DirectoryDb, host: DirectoryHost) {
    this.#db = db;
    this.#host = host;
  }

  /**
   * A workspace changed: its members (and `also`) are told, with `workspaces`
   * too when what their lists show changed (a name, a role, a count).
   */
  changed(workspace: string, list: boolean, also: Iterable<string> = [], only: "lock" | "requests" | null = null): ChangedView | null {
    for (const station of this.#db.stationsIn(workspace)) this.#host.sendState(station);
    // (its lock moving on, or its requests to be let in, are nothing the console lists)
    if (only === null) this.#host.adminChanged("workspaces");
    if (only !== null) {
      const said = only === "lock" ? { lock: { head: this.#host.lockHead(workspace), locked: this.#host.locked(workspace) } } : { requests: true as const };
      this.#host.tell([...this.#db.members(workspace), ...also], { type: "workspace", id: workspace, ...said });
      return null;
    }
    // Each member is told what changed of the view and of their entry of the list (`#told`), so their devices read
    // neither again: every device of every member read both whole at each change (the locks' end to end, 2026-11-15:
    // of an account's 187 requests in a minute, 49 `/v1/me` and 61 the view). Those whose role changed, or who were not
    // members before, get the view whole as before (what they see of it changed beyond what the others are told), and
    // whoever else is told (`also`: taken out, or invited) the list read again.
    // (who is told never hangs on what is told: the members as the Directory has them, whatever `#told` comes to)
    const subs = this.#db.members(workspace);
    const plain: AccountEvent = { type: "workspace", id: workspace };
    const groups = new Map<string, { subs: string[]; events: AccountEvent[] }>();
    let kept: ChangedView | null = null;
    try {
      const told = this.#told(workspace);
      kept = told ? { now: told.now, rev: told.rev[1] } : null;
      const roles = new Map((told?.now.members ?? []).map((m) => [m.sub, m.role]));
      const before = new Map((told?.before?.members ?? []).map((m) => [m.sub, m.role]));
      const into = (key: string, sub: string, events: () => AccountEvent[]) => {
        let group = groups.get(key);
        if (!group) groups.set(key, (group = { subs: [], events: events() }));
        group.subs.push(sub);
      };
      for (const sub of subs) {
        const role = roles.get(sub);
        if (role === undefined || !told) {
          into("plain", sub, () => [...(list ? [LIST] : []), plain]);
          continue;
        }
        const same = told.before !== null && before.get(sub) === role;
        const manager = MANAGERS.includes(role);
        into(`${role} ${same}`, sub, () => [...(list ? [{ type: "workspaces", entry: told.entry(role) } as AccountEvent] : []), same ? { type: "workspace", id: workspace, rev: told.rev, ...told.change(manager) } : plain]);
      }
    } catch (error) {
      // What tells a change never fails the request it follows (2026-11-15: a first version answered 500 to an
      // invitation already made): the view as last told let go of and begun again from now, at a version above any
      // before, and every member told plainly, as before there were versions.
      console.warn(`told: ${workspace}'s view as last told not read (${error instanceof Error ? error.message : String(error)}); its members told plainly, told anew from now`);
      groups.clear();
      groups.set("plain", { subs, events: [...(list ? [LIST] : []), plain] });
      kept = this.#toldAnew(workspace);
    }
    const others = [...new Set(also)].filter((sub) => !subs.includes(sub));
    if (others.length > 0) groups.set("others", { subs: others, events: [...(list ? [LIST] : []), plain] });
    for (const { subs: targetSubs, events } of groups.values()) this.#host.tell(targetSubs, ...events);
    return kept;
  }

  /** A workspace's view as last told let go of, and kept again as it is now at a version above the one let go of and
   * this second's thousandths (`#told`); where even that fails, none kept, the next change beginning it. */
  #toldAnew(workspace: string): ChangedView | null {
    try {
      const was = this.#db.one("SELECT rev FROM told WHERE workspace = ?", workspace);
      this.#db.run("DELETE FROM told WHERE workspace = ?", workspace);
      const now = this.#alike(workspace);
      if (!now) return null;
      const rev = Math.max(nowSeconds() * 1000, typeof was?.rev === "number" ? was.rev + 1 : 0);
      this.#db.run("INSERT INTO told (workspace, rev, view) VALUES (?, ?, ?)", workspace, rev, JSON.stringify(now));
      return { now, rev };
    } catch (error) {
      console.warn(`told: ${workspace}'s view not kept anew (${error instanceof Error ? error.message : String(error)})`);
      return null;
    }
  }

  /** What a workspace's view says alike to every member: `#view` but the viewer's role and lock requests, the managers'
   * parts (invitations, added) of it, `rigs` with none too. */
  #alike(id: string): AlikeView | null {
    const w = this.#db.one("SELECT id, name, created_at, relays, ways_off, emoji, icon FROM workspaces WHERE id = ?", id);
    if (!w) return null;
    const members = this.#db.rows(`
      SELECT m.sub, COALESCE(u.email, '') AS email, COALESCE(u.name, '') AS name, COALESCE(${SHOWN_PICTURE}, '') AS picture, m.role, m.added_at
      FROM members m LEFT JOIN users u ON u.sub = m.sub WHERE m.workspace = ? ORDER BY m.added_at`, id) as unknown as MemberView[];
    const stations = this.#db.stationViews(id).map(({ workspace: _, ...station }) => station);
    const invitations = this.#db.rows("SELECT id, role, email, created_by, expires_at FROM invitations WHERE workspace = ? AND expires_at > ? ORDER BY expires_at", id, nowSeconds()) as unknown as InvitationView[];
    const added = this.#db.rows("SELECT email, role, added_by, added_at FROM added WHERE workspace = ? ORDER BY added_at", id) as unknown as AddedView[];
    const ownRelays = parseRelays(w.relays);
    const waysOff = parseRelays(w.ways_off);
    return { id, name: w.name as string, ...marks(w.emoji, w.icon), created_at: w.created_at as number, members, stations, rigs: this.#db.rigViews(id), invitations, added, relays: ownRelays, ...(waysOff.length > 0 ? { ways_off: waysOff } : {}), ways: waysOf(this.#db.relays(this.#host.meshRelays()), ownRelays, waysOff), lock: this.#host.lockHead(id), ...(this.#host.locked(id) ? { locked: true } : {}) };
  }

  /**
   * A workspace's view as it is now against the one last told (kept in `told`, with its version): the versions before
   * and after (one more where anything changed), what changed for a manager and for anyone else, and a member's entry
   * of their list by their role. Nothing kept yet (a workspace not changed since, or moved in): what is now is kept,
   * at a version above any before (this second's thousandths), and `before` is null.
   */
  #told(workspace: string): { before: AlikeView | null; now: AlikeView; rev: [number, number]; change: (manager: boolean) => ViewTold; entry: (role: Role) => WorkspaceSummary } | null {
    const now = this.#alike(workspace);
    if (!now) return null;
    const kept = this.#db.one("SELECT rev, view FROM told WHERE workspace = ?", workspace);
    const before = kept ? (JSON.parse(kept.view as string) as AlikeView) : null;
    const text = JSON.stringify(now);
    const was = kept ? (kept.rev as number) : nowSeconds() * 1000;
    const rev: [number, number] = [was, !kept || kept.view === text ? was : was + 1];
    if (kept?.view !== text) this.#db.run("INSERT INTO told (workspace, rev, view) VALUES (?, ?, ?) ON CONFLICT (workspace) DO UPDATE SET rev = excluded.rev, view = excluded.view", workspace, rev[1], text);
    const { members, stations, ...rest } = now;
    return {
      before,
      now,
      rev,
      change: (manager) => (before === null ? {} : viewTold(before, now, manager)),
      entry: (role) => ({ id: now.id, name: now.name, ...marks(rest.emoji, rest.icon), role, created_at: now.created_at, stations: stations.length, members: members.length, relays: now.relays, ...(now.ways_off ? { ways_off: now.ways_off } : {}) }) as WorkspaceSummary,
    };
  }

  /**
   * The account a sign-in that proved it holds `email` (Google's, or a code sent to it: login.ts) is, with the name and
   * picture it has: the one `sub` already is, else the first signed in with that email, so whoever signed up one way and
   * signs in the other is the same account, with its workspaces; null for a new one. App Store review's (`pw-`,
   * password.ts) is nobody's but its own, and an unlinked Apple account (`apple_`) never shadows ADMIN_EMAIL's Google account.
   */
  accountFor(sub: string, email: string): { sub: string; name: string; picture: string } | null {
    const adminEmail = isAdmin(this.#db.env, email);
    const row =
      this.#db.one("SELECT sub, name, picture FROM users WHERE sub = ?", sub) ??
      this.#db.one(
        `SELECT sub, name, picture FROM users WHERE lower(email) = lower(?) AND sub NOT LIKE 'pw-%'${adminEmail ? " AND sub NOT LIKE 'apple_%'" : ""} ORDER BY created_at, rowid LIMIT 1`,
        email,
      );
    return row ? { sub: row.sub as string, name: row.name as string, picture: row.picture as string } : null;
  }

  /**
   * Resolves a verified Sign in with Apple identity:
   * - `linked`: `appleSub` is already linked to a live user row in `apple_identities`.
   * - `conflict`: `appleSub` is new, but an existing non-`pw-` user already holds `email` (caller must require email OTP before linking).
   * - `new`: no existing link or matching email; safe to create a new `apple_` account.
   */
  appleAccount(
    appleSub: string,
    email: string,
  ): { status: "linked" | "conflict"; account: { sub: string; email: string; name: string; picture: string } } | { status: "new" } {
    const linked = this.#db.one("SELECT user_sub FROM apple_identities WHERE apple_sub = ?", appleSub);
    if (linked) {
      const user = this.#db.one("SELECT sub, email, name, picture FROM users WHERE sub = ?", linked.user_sub as string);
      if (user) {
        return {
          status: "linked",
          account: { sub: user.sub as string, email: user.email as string, name: user.name as string, picture: user.picture as string },
        };
      }
      // Stale link after user deletion: clean up and fall through.
      this.#db.run("DELETE FROM apple_identities WHERE apple_sub = ?", appleSub);
    }
    const existing = this.#db.one(
      "SELECT sub, email, name, picture FROM users WHERE lower(email) = lower(?) AND sub NOT LIKE 'pw-%' ORDER BY created_at, rowid LIMIT 1",
      email,
    );
    if (existing) {
      return {
        status: "conflict",
        account: { sub: existing.sub as string, email: existing.email as string, name: existing.name as string, picture: existing.picture as string },
      };
    }
    return { status: "new" };
  }

  /** Records or updates the link from an Apple `sub` to an account `sub`, keeping any previously stored refresh token when a new one is absent. */
  linkApple(appleSub: string, userSub: string, email: string, refreshToken: string | null): void {
    const now = nowSeconds();
    this.#db.run(
      `INSERT INTO apple_identities (apple_sub, user_sub, email, refresh_token, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT (apple_sub) DO UPDATE SET
         user_sub = excluded.user_sub,
         email = excluded.email,
         refresh_token = COALESCE(excluded.refresh_token, apple_identities.refresh_token),
         updated_at = excluded.updated_at`,
      appleSub,
      userSub,
      email.toLowerCase(),
      refreshToken,
      now,
      now,
    );
  }

  upsertUser(identity: Identity): void {
    const old = this.#db.one("SELECT email, name, picture FROM users WHERE sub = ?", identity.sub);
    const nextName = identity.name || ((old?.name as string | undefined) ?? "");
    const nextPicture = identity.picture || ((old?.picture as string | undefined) ?? "");
    this.#db.run(
      `INSERT INTO users (sub, email, name, picture, created_at, last_seen) VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT (sub) DO UPDATE SET
         email = excluded.email,
         name = CASE WHEN excluded.name != '' THEN excluded.name ELSE users.name END,
         picture = CASE WHEN excluded.picture != '' THEN excluded.picture ELSE users.picture END,
         last_seen = excluded.last_seen`,
      identity.sub, identity.email, identity.name, identity.picture, nowSeconds(), nowSeconds(),
    );
    this.#joinAdded(identity.sub, identity.email);
    this.#takePending(identity.sub, identity.email);
    if (!old || old.email !== identity.email || old.name !== nextName || old.picture !== nextPicture) this.#host.adminChanged("users");
    if (!old || (old.email === identity.email && old.name === nextName && old.picture === nextPicture)) return;
    // Members lists show them; invitations they sent show their name; a new email has other invitations.
    for (const row of this.#db.rows("SELECT workspace FROM members WHERE sub = ?", identity.sub)) {
      if (old.email !== identity.email) this.#host.forgetMailRetry(row.workspace as string, old.email as string);
      this.changed(row.workspace as string, false);
    }
    const invited = this.#db.rows("SELECT i.email FROM invitations i WHERE i.created_by = ? AND i.expires_at > ?", identity.sub, nowSeconds()).flatMap((r) => this.#db.byEmail(r.email as string));
    this.#host.tell([...invited, ...(old.email === identity.email ? [] : [identity.sub])], LIST);
  }

  /**
   * The picture the account put up for itself (kept here: api.ts puts one sent in the bucket), shown instead of its
   * sign-in's wherever that was (`/v1/me`, members lists, the console); signing in again leaves it, as upsertUser
   * changes only the sign-in's. null takes it away, the sign-in's shown again. Its own devices and its workspaces'
   * members hear of it.
   */
  setOwnPicture(sub: string, picture: unknown): { picture: string } {
    const own = picture === null ? null : cleanPicture(picture, publicOrigins(this.#db.env)) ?? fail(400, "invalid_icon");
    this.#db.run("UPDATE users SET own_picture = ? WHERE sub = ?", own, sub);
    for (const row of this.#db.rows("SELECT workspace FROM members WHERE sub = ?", sub)) this.changed(row.workspace as string, false);
    this.#host.tell([sub], LIST);
    return { picture: own ?? (this.#db.one("SELECT picture FROM users WHERE sub = ?", sub)?.picture as string | undefined) ?? "" };
  }

  /** An account whose email was added to workspaces: a member of each from now on. */
  #joinAdded(sub: string, email: string): void {
    const rows = this.#db.rows("SELECT workspace, role FROM added WHERE email = ?", email.toLowerCase());
    if (rows.length === 0) return;
    this.#db.ctx.storage.transactionSync(() => {
      for (const row of rows) {
        this.#db.run("INSERT INTO members (workspace, sub, role, added_at) VALUES (?, ?, ?, ?) ON CONFLICT (workspace, sub) DO NOTHING", row.workspace, sub, row.role, nowSeconds());
      }
      this.#db.run("DELETE FROM added WHERE email = ?", email.toLowerCase());
      this.#db.run("UPDATE users SET admitted = 'invitation' WHERE sub = ? AND admitted IS NULL", sub);
    });
    for (const row of rows) this.changed(row.workspace as string, true);
  }

  /**
   * A self-hosted cloud's workspace that whoever its OpenID provider (OIDC_ISSUER) signs in joins as a member, or no
   * longer does (selfhost/setup.ts `open_to_sign_in`): a machine's cloud whose provider lets in only its organization's
   * people (monoid's console) lets each of them in, not only the first to sign in. Those already in stay.
   */
  openToSignIn(workspace: string, open: boolean): void {
    this.#db.run("UPDATE workspaces SET sign_in_joins = ? WHERE id = ?", open ? 1 : null, workspace);
  }

  /**
   * Someone the cloud's OpenID provider has just vouched for (login.ts, before their session is made), in each
   * workspace open to its sign-in (openToSignIn), with `role`, the one the provider gives them (OIDC_ROLE_CLAIM; null:
   * it gives none). Not yet in it: added as addMembers adds an email (an invitation to it replaced), as a member
   * where it gives none (an invitation of their own then left for them to accept), so the session's upsertUser makes them one (#joinAdded). In it: their role made the
   * provider's, as setRole makes it, but for its last owner's (the workspace keeps one). Not beyond its seats. Taken
   * out, they are in again as they sign in again: who is in, and as what, is the provider's to say.
   */
  async joinBySignIn(email: string, role: Role | null = null): Promise<void> {
    const address = email.toLowerCase();
    if (role !== null && !ROLES.includes(role)) role = null;
    const open = this.#db.rows("SELECT id, created_by FROM workspaces WHERE sign_in_joins = 1");
    const changed = new Map<string, string[]>();
    this.#db.ctx.storage.transactionSync(() => {
      for (const row of open) {
        const workspace = row.id as string;
        const members = this.#db.rows("SELECT m.sub, m.role FROM members m JOIN users u ON u.sub = m.sub WHERE m.workspace = ? AND lower(u.email) = ?", workspace, address);
        if (members.length > 0) {
          if (role === null) continue;
          for (const m of members) {
            if (m.role === role) continue;
            const owners = this.#db.one("SELECT COUNT(*) AS n FROM members WHERE workspace = ? AND role = 'owner'", workspace)!.n as number;
            if (m.role === "owner" && owners <= 1) continue;
            this.#db.run("UPDATE members SET role = ? WHERE workspace = ? AND sub = ?", role, workspace, m.sub);
            // (the credentials it holds name its old role, as setRole's)
            this.#host.revoke(workspace, "sub", m.sub as string);
            changed.set(workspace, [...(changed.get(workspace) ?? []), m.sub as string]);
          }
          continue;
        }
        const added = this.#db.one("SELECT role FROM added WHERE workspace = ? AND email = ?", workspace, address);
        if (added && (role === null || added.role === role)) continue;
        const invited = this.#db.one("SELECT COUNT(*) AS n FROM invitations WHERE workspace = ? AND email = ? AND expires_at > ?", workspace, address, nowSeconds())!.n as number;
        // (without a role of the provider's, an invitation of their own is theirs to accept, with its role)
        if (role === null && invited > 0) continue;
        const replaces = added ? 1 : invited;
        if (this.seats(workspace, true) - replaces >= this.memberCap(workspace)) continue;
        this.#db.run("DELETE FROM invitations WHERE workspace = ? AND email = ?", workspace, address);
        this.#db.run(`INSERT INTO added (workspace, email, role, added_by, added_at) VALUES (?, ?, ?, ?, ?)
          ON CONFLICT (workspace, email) DO UPDATE SET role = excluded.role`, workspace, address, role ?? "member", row.created_by, nowSeconds());
        changed.set(workspace, changed.get(workspace) ?? []);
      }
    });
    for (const [workspace, also] of changed) {
      this.changed(workspace, true, also);
      this.#host.tell(also, LIST);
    }
    if (changed.size > 0) this.#host.tell(this.#db.byEmail(address), LIST);
    if ([...changed.values()].some((also) => also.length > 0)) await this.#host.delivered();
  }

  /** An account signing in with an email the admin gave rights to before it had one: they are its from now on. */
  #takePending(sub: string, email: string): void {
    const row = this.#db.one("SELECT beta, may_create FROM pending WHERE email = ?", email.toLowerCase());
    if (!row) return;
    this.#db.ctx.storage.transactionSync(() => {
      if (row.beta) {
        this.#db.run("UPDATE users SET beta = 1 WHERE sub = ?", sub);
        this.#host.betaTold(sub);
      }
      if (row.may_create) this.#db.run("UPDATE users SET admitted = 'granted' WHERE sub = ? AND (admitted IS NULL OR admitted IN ('invitation', 'free'))", sub);
      this.#db.run("DELETE FROM pending WHERE email = ?", email.toLowerCase());
    });
  }

  me(sub: string): { user: MeView | null; workspaces: WorkspaceSummary[] } & ReturnType<typeof relays> {
    const row = this.#db.one(`SELECT sub, email, name, ${SHOWN_PICTURE} AS picture, own_picture, beta FROM users WHERE sub = ?`, sub);
    // beta and own_picture only when set: clients from before them know no such field, and an account without them says
    // nothing.
    const user = row ? { sub: row.sub as string, email: row.email as string, name: row.name as string, picture: row.picture as string, ...(row.own_picture ? { own_picture: true as const } : {}), ...(row.beta ? { beta: true as const } : {}) } : undefined;
    const workspaces = this.#db.rows(`
      SELECT w.id, w.name, m.role, w.created_at,
        (SELECT COUNT(*) FROM station_members s WHERE s.workspace = w.id AND s.rig IS NULL) AS stations,
        (SELECT COUNT(*) FROM members x WHERE x.workspace = w.id) AS members, w.relays, w.ways_off, w.emoji, w.icon
      FROM members m JOIN workspaces w ON w.id = m.workspace WHERE m.sub = ? ORDER BY w.created_at`, sub)
      .map(({ relays: wsRelays, ways_off, emoji, icon, ...w }) => ({ ...w, relays: parseRelays(wsRelays), ...offOf(ways_off), ...marks(emoji, icon) })) as unknown as WorkspaceSummary[];
    return { user: user ?? null, workspaces, ...relays(this.#db.relays(this.#host.meshRelays()), true) };
  }

  /**
   * Anyone signed in may create a workspace on the free plan (PLANS.free.workspaces of them). The standard plan's are
   * the account's to earn: the admin's say, or a code (used up by the workspace it is redeemed with), or having been in
   * a workspace before codes existed. An account on the free plan that has used its free ones is asked for a code, and
   * redeeming it makes the account, and so every workspace it created, standard. Nothing here awaits, so two creations
   * with one code cannot both see it unused.
   */
  createWorkspace(sub: string, name: string, admin: boolean, code: unknown): WorkspaceView {
    const clean = cleanName(name) ?? fail(400, "invalid_name");
    // Those the admin made for others (with limits of their own) are not the admin's to count.
    const made = this.#db.one("SELECT COUNT(*) AS n FROM workspaces WHERE created_by = ? AND max_members IS NULL", sub)!.n as number;
    const standard = admin || this.standard(sub);
    const given = typeof code === "string" && code.trim() !== "";
    // A code given on the free plan is redeemed even while a free workspace is left: it is what the person asked for.
    const redeem = standard || (!given && made < PLANS.free.workspaces) ? null : this.#redeemable(code);
    if (made >= PLANS[admin ? "admin" : "standard"].workspaces) fail(429, "too_many_workspaces");
    const id = ulid();
    const now = nowSeconds();
    this.#db.ctx.storage.transactionSync(() => {
      this.#db.run("INSERT INTO workspaces (id, name, created_by, created_at) VALUES (?, ?, ?, ?)", id, clean, sub, now);
      this.#db.run("INSERT INTO members (workspace, sub, role, added_at) VALUES (?, ?, 'owner', ?)", id, sub, now);
      if (redeem) {
        this.#db.run("UPDATE invite_codes SET used_by = ?, used_at = ?, workspace = ? WHERE code = ?", sub, now, id, redeem);
        // A code made with the test channel lets its account in too.
        this.#db.run("UPDATE users SET beta = 1 WHERE sub = ? AND (SELECT beta FROM invite_codes WHERE code = ?) = 1", sub, redeem);
        this.#host.betaTold(sub);
        this.#db.run("UPDATE users SET admitted = 'code' WHERE sub = ? AND (admitted IS NULL OR admitted IN ('invitation', 'free'))", sub);
      } else if (!standard) {
        // In a workspace, but not from before codes (#standard).
        this.#db.run("UPDATE users SET admitted = 'free' WHERE sub = ? AND (admitted IS NULL OR admitted = 'invitation')", sub);
      }
    });
    this.#host.tell([sub], LIST);
    if (redeem) this.#host.adminChanged("workspaces", "users", "invite-codes");
    else this.#host.adminChanged("workspaces", "users");
    return this.view(sub, id);
  }

  /** Whether an account is on the standard plan (the admin aside): see createWorkspace. */
  standard(sub: string): boolean {
    return Boolean(this.#db.one(`SELECT 1 AS x FROM users WHERE sub = ? AND admitted IN ('code', 'granted')
      UNION ALL SELECT 1 FROM users u JOIN members m ON m.sub = u.sub WHERE u.sub = ? AND u.admitted IS NULL LIMIT 1`, sub, sub));
  }

  /** The plan a workspace is on: its creator's. */
  #plan(workspace: string): Plan {
    const creator = this.#db.one("SELECT u.sub, u.email FROM workspaces w JOIN users u ON u.sub = w.created_by WHERE w.id = ?", workspace);
    if (!creator) return "free";
    return isAdmin(this.#db.env, creator.email as string, creator.sub as string) ? "admin" : this.standard(creator.sub as string) ? "standard" : "free";
  }

  /** How many people a workspace may hold: its own limit, or its creator's plan's. */
  memberCap(workspace: string): number {
    const own = this.#db.one("SELECT max_members, max_stations FROM workspaces WHERE id = ?", workspace);
    if (own && own.max_members !== null && own.max_stations !== null) return own.max_members as number;
    return PLANS[this.#plan(workspace)].members;
  }

  /** Who a workspace holds or has let in: members, emails added but not signed in yet, and, with `invited`, open invitations. */
  seats(workspace: string, invited = false): number {
    return this.#db.one(`SELECT (SELECT COUNT(*) FROM members WHERE workspace = ?) + (SELECT COUNT(*) FROM added WHERE workspace = ?)
      + (CASE WHEN ? THEN (SELECT COUNT(*) FROM invitations WHERE workspace = ? AND expires_at > ?) ELSE 0 END) AS n`,
      workspace, workspace, invited ? 1 : 0, workspace, nowSeconds())!.n as number;
  }

  /** The stored form of a code that may be redeemed now; fails with why not. */
  #redeemable(value: unknown): string {
    if (typeof value !== "string" || !value.trim()) fail(403, "invite_code_required");
    const code = normalizeCode(value) ?? fail(404, "invite_code_invalid");
    const row = this.#db.one("SELECT expires_at, revoked_at, used_by FROM invite_codes WHERE code = ?", code);
    if (!row || row.revoked_at !== null) fail(404, "invite_code_invalid");
    if (row!.used_by !== null) fail(409, "invite_code_used");
    if ((row!.expires_at as number) <= nowSeconds()) fail(410, "invite_code_expired");
    return code;
  }

  workspace(sub: string, id: string): WorkspaceView {
    return this.view(sub, id);
  }

  /** A workspace as the caller sees it (what its changes answer with: called within them, it is not counted again). */
  view(sub: string, id: string, kept?: ChangedView | null): WorkspaceView {
    const role = this.#db.role(sub, id);
    const { rigs, invitations, added, ...alike } = kept?.now ?? this.#alike(id)!;
    const rev = kept?.rev ?? (this.#db.one("SELECT rev FROM told WHERE workspace = ?", id)?.rev as number | undefined);
    const manager = MANAGERS.includes(role);
    return { ...(rev !== undefined ? { rev } : {}), ...alike, role, ...(rigs.length ? { rigs } : {}), invitations: manager ? invitations : [], added: manager ? added : [], lock_requests: this.#host.lockRequestCount(id, sub, role) };
  }

  /**
   * The workspace's own relays, used besides still.fail's by its stations (told in their state) and by its members'
   * devices (in `/v1/me`): https URLs (http too when the cloud itself is on http: a local setup), at most MAX_RELAYS,
   * still.fail's own left out. Whether one answers is not asked here: the cloud may be where it cannot be reached from
   * (one inside mainland China), and one that does not answer is passed over where it is measured.
   */
  setRelays(sub: string, id: string, input: unknown): WorkspaceView {
    this.#db.role(sub, id, MANAGERS);
    if (!Array.isArray(input) || input.length > MAX_RELAYS) fail(400, "invalid_relays");
    const currentRelays = this.#db.relays(this.#host.meshRelays());
    const ours = relayUrls(currentRelays).map(sameUrl);
    const insecure = this.#db.env.PUBLIC_ORIGIN.startsWith("http:");
    const list: string[] = [];
    for (const raw of input as unknown[]) {
      const url = typeof raw === "string" && URL.canParse(raw.trim()) ? new URL(raw.trim()) : null;
      if (!url || !(url.protocol === "https:" || (insecure && url.protocol === "http:")) || url.username || url.password || url.search || url.hash) fail(400, "invalid_relay");
      const clean = url!.href.replace(/\/+$/, "");
      if (!ours.includes(sameUrl(clean)) && !list.some((u) => sameUrl(u) === sameUrl(clean))) list.push(clean);
    }
    // A relay of its own taken away is no longer among those turned off either; if none of its relays would stay on,
    // still.fail's come back on.
    const off = parseRelays(this.#db.one("SELECT ways_off FROM workspaces WHERE id = ?", id)?.ways_off);
    const ways = waysOf(currentRelays, list, []).map((w) => sameUrl(w.id));
    const filtered = off.filter((o) => o === "ours" || ways.includes(sameUrl(o)));
    const kept = waysOf(currentRelays, list, filtered).some((w) => w.kind === "relay" && w.on)
      ? filtered
      : filtered.filter((o) => o !== "ours" && !ours.includes(sameUrl(o)));
    this.#db.ctx.storage.transactionSync(() => {
      this.#db.run("UPDATE workspaces SET relays = ? WHERE id = ?", list.length ? JSON.stringify(list) : null, id);
      this.#db.run("UPDATE workspaces SET ways_off = ?, ways_at = ?, ways_station = '' WHERE id = ?", kept.length ? JSON.stringify(kept) : null, clock.now(), id);
    });
    return this.view(sub, id, this.changed(id, true));
  }

  /**
   * One way the workspace's devices reach its stations turned on or off (`ways` of its view: a relay, still.fail's or
   * its own, or a kind of way that is no relay; `ours` for all of still.fail's relays): those off are told to its
   * members in `/v1/me` as `ways_off`, and their devices do not go that way to its stations (client/core-ts mesh.ts).
   * A relay stays on: the web app goes through relays alone, and a device that never reached a station yet knows of no
   * other way there.
   */
  setWay(sub: string, id: string, way: unknown, on: unknown): WorkspaceView {
    this.#db.role(sub, id, MANAGERS);
    if (typeof way !== "string" || typeof on !== "boolean") fail(400, "invalid_way");
    const row = this.#db.one("SELECT relays, ways_off FROM workspaces WHERE id = ?", id)!;
    const own = parseRelays(row.relays);
    const nowOff = parseRelays(row.ways_off);
    const currentRelays = this.#db.relays(this.#host.meshRelays());
    const ours = relayUrls(currentRelays).map(sameUrl);
    let off: string[];
    if (way === "ours") {
      off = nowOff.filter((o) => o !== "ours" && !ours.includes(sameUrl(o)));
      if (!on) off.push("ours");
    } else {
      const ways = waysOf(currentRelays, own, nowOff);
      const target = ways.find((w) => sameUrl(w.id) === sameUrl(way as string)) ?? fail(400, "invalid_way");
      off = ways.filter((w) => (w === target ? !on : !w.on)).map((w) => w.id);
    }
    if (!waysOf(currentRelays, own, off).some((w) => w.kind === "relay" && w.on)) fail(409, "last_relay");
    this.#db.run("UPDATE workspaces SET ways_off = ?, ways_at = ?, ways_station = '' WHERE id = ?", off.length ? JSON.stringify(off) : null, clock.now(), id);
    return this.view(sub, id, this.changed(id, true));
  }

  /** Fails unless the caller manages the workspace, or owns the named rig (before a picture it sends is kept: api.ts). */
  manages(sub: string, id: string, station?: string): void {
    if (
      !MANAGERS.includes(this.#db.role(sub, id))
      && (!station || !this.#db.one("SELECT 1 AS x FROM station_members WHERE station = ? AND workspace = ? AND rig = 1 AND enrolled_by = ?", station, id, sub))
    ) {
      fail(403, "forbidden");
    }
  }

  /** A new name, a new emoji, a new icon (null or "" takes either away; a station's, cleanIcon), or several; what is not given stays. */
  updateWorkspace(sub: string, id: string, input: { name?: unknown; emoji?: unknown; icon?: unknown }): WorkspaceView {
    this.#db.role(sub, id, MANAGERS);
    const name = input.name === undefined ? undefined : cleanName(input.name) ?? fail(400, "invalid_name");
    const emoji = input.emoji === undefined ? undefined : input.emoji === null || input.emoji === "" ? null : cleanEmoji(input.emoji) ?? fail(400, "invalid_emoji");
    const icon = input.icon === undefined ? undefined : input.icon === null || input.icon === "" ? null : cleanIcon(input.icon, publicOrigins(this.#db.env)) ?? fail(400, "invalid_icon");
    if (name === undefined && emoji === undefined && icon === undefined) fail(400, "invalid_name");
    if (name !== undefined) this.#db.run("UPDATE workspaces SET name = ? WHERE id = ?", name, id);
    if (emoji !== undefined) this.#db.run("UPDATE workspaces SET emoji = ? WHERE id = ?", emoji, id);
    if (icon !== undefined) this.#db.run("UPDATE workspaces SET icon = ? WHERE id = ?", icon, id);
    // Invitations show the name; the switchers, the mark.
    return this.view(sub, id, this.changed(id, true, name !== undefined ? this.#db.invitees(id) : []));
  }

  async deleteWorkspace(sub: string, id: string): Promise<void> {
    this.#db.role(sub, id, ["owner"]);
    this.remove(id);
    await this.#host.delivered();
  }

  /** A workspace gone: its people told, its stations let go. */
  remove(id: string): void {
    const told = [...this.#db.members(id), ...this.#db.invitees(id)];
    const stations = this.#db.stationsIn(id).map((station) => ({ station, home: this.#db.memberships(station)[0] }));
    this.#db.ctx.storage.transactionSync(() => {
      for (const table of ["members", "invitations", "added", "added_mails", "added_mail_retries", "station_members", "enrollments", "lock_entries", "lock_aside", "devices", "lock_requests", "provision_keys", "told"]) this.#db.run(`DELETE FROM ${table} WHERE workspace = ?`, id);
      this.#db.run("DELETE FROM workspaces WHERE id = ?", id);
    });
    this.#host.resetDevicesSeen({ workspace: id });
    this.#host.tell(told, LIST, { type: "workspace", id });
    this.#host.adminChanged("workspaces", "users");
    // Its stations leave it; those in no other workspace are let go as before.
    for (const { station, home } of stations) this.#host.left(station, home!);
  }
}
