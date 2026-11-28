import { ulid } from "ulid";
import { digest, nowSeconds, randomSecret } from "../auth";
import type { PendingInvitation, Role, WorkspaceView } from "../types";
import type { DirectoryDb, DirectoryHost } from "./db";
import { ADDED_MAIL_EVERY_SEC, INVITATION_TTL_SEC, LIMITS, LIST, MANAGERS, ROLES, emailsOf, fail, type AddedMail, type ChangedView } from "./types";

// ── members, invitations, roles, and account deletion ───────────────────

export class DirectoryMembers {
  #db: DirectoryDb;
  #host: DirectoryHost;

  constructor(db: DirectoryDb, host: DirectoryHost) {
    this.#db = db;
    this.#host = host;
  }

  /**
   * Adds people by email, no invitation to accept: those with an account are members at once, the others as soon as they
   * first sign in with that email. What each became: joined, added (waiting for a first sign-in), or already a member.
   */
  addMembers(sub: string, workspace: string, role: Role, emails: unknown, reportsSent = false): { joined: string[]; added: string[]; already: string[]; view: WorkspaceView; mail: AddedMail } {
    const mine = this.#db.role(sub, workspace, MANAGERS);
    if (!ROLES.includes(role)) fail(400, "invalid_role");
    if (role === "owner" && mine !== "owner") fail(403, "forbidden");
    const { joined, added, already, view } = this.addEmails(sub, workspace, role, emailsOf(emails));
    return { joined, added, already, view: this.#host.view(sub, workspace, view), mail: this.toMail(sub, workspace, joined, added, already, reportsSent) };
  }

  /**
   * Who of those just added is told so by mail (api.ts sends it): each email once a day in a workspace at most, so
   * taking someone out and adding them again cannot send the cloud's address to anyone over and over. Noted as sent
   * here; one that could not be sent waits separately (`mailFailed`), so adding them again tries again even when
   * they are already a member and the day's records have gone. It waits only while that member or added email stays.
   */
  toMail(by: string, workspace: string, joined: string[], added: string[], already: string[], reportsSent: boolean): AddedMail {
    const now = nowSeconds();
    this.#db.run("DELETE FROM added_mails WHERE at <= ?", now - ADDED_MAIL_EVERY_SEC);
    const waiting = (email: string) => this.#db.one("SELECT 1 AS x FROM added_mail_retries WHERE workspace = ? AND email = ?", workspace, email);
    const retry = reportsSent ? already.filter(waiting) : [];
    const to: { email: string; joined: boolean }[] = [];
    for (const [emails, isJoined] of [[[...joined, ...retry], true], [added, false]] as const) {
      for (const email of emails) {
        // An older API reports only failures: it cannot acknowledge and clear a pending retry after success.
        if (!reportsSent && waiting(email)) continue;
        if (this.#db.one("SELECT 1 AS x FROM added_mails WHERE workspace = ? AND email = ?", workspace, email)) continue;
        this.#db.run("INSERT INTO added_mails (workspace, email, at) VALUES (?, ?, ?)", workspace, email, now);
        to.push({ email, joined: isJoined });
      }
    }
    const inviter = this.#db.one("SELECT COALESCE(NULLIF(name, ''), email) AS n FROM users WHERE sub = ?", by)?.n as string | undefined;
    const name = this.#db.one("SELECT name FROM workspaces WHERE id = ?", workspace)?.name as string | undefined;
    return { to, inviter: inviter ?? "", workspace: name ?? "" };
  }

  /**
   * Failure frees its daily slot and waits while its recipient stays; success clears a retry. Keep the old RPC and
   * make successes optional: a Worker and its Directory may run different versions while code is being deployed.
   */
  mailFailed(workspace: string, emails: string[], sent: string[] = []): void {
    this.#db.ctx.storage.transactionSync(() => {
      for (const email of emails) {
        this.#db.run("DELETE FROM added_mails WHERE workspace = ? AND email = ?", workspace, email);
        if (this.#mailRecipient(workspace, email)) this.#db.run("INSERT OR IGNORE INTO added_mail_retries (workspace, email) VALUES (?, ?)", workspace, email);
        else this.#db.run("DELETE FROM added_mail_retries WHERE workspace = ? AND email = ?", workspace, email);
      }
      for (const email of sent) this.#db.run("DELETE FROM added_mail_retries WHERE workspace = ? AND email = ?", workspace, email);
    });
  }

  #mailRecipient(workspace: string, email: string): boolean {
    return Boolean(this.#db.one(`SELECT 1 AS x FROM added WHERE workspace = ? AND email = ?
      UNION ALL SELECT 1 FROM members m JOIN users u ON u.sub = m.sub WHERE m.workspace = ? AND lower(u.email) = lower(?) LIMIT 1`, workspace, email.toLowerCase(), workspace, email));
  }

  /** Taking someone out ends their pending mail too; becoming a signed-in member does not. */
  forgetMailRetry(workspace: string, email: string): void {
    if (!this.#mailRecipient(workspace, email)) this.#db.run("DELETE FROM added_mail_retries WHERE workspace = ? AND email = ?", workspace, email.toLowerCase());
  }

  /** addMembers once allowed: each email a member now, or as soon as it first signs in. */
  addEmails(by: string, workspace: string, role: Role, wanted: string[]): { joined: string[]; added: string[]; already: string[]; view: ChangedView | null } {
    const joined: string[] = [];
    const added: string[] = [];
    const already: string[] = [];
    const cap = this.#host.memberCap(workspace);
    this.#db.ctx.storage.transactionSync(() => {
      for (const email of wanted) {
        if (this.#db.one("SELECT 1 AS x FROM members m JOIN users u ON u.sub = m.sub WHERE m.workspace = ? AND lower(u.email) = ?", workspace, email)) {
          already.push(email);
          continue;
        }
        // An open invitation to this email, or its being added already, is replaced: its seat is this one.
        const replaces = this.#db.one(`SELECT (SELECT COUNT(*) FROM invitations WHERE workspace = ? AND email = ? AND expires_at > ?)
          + (SELECT COUNT(*) FROM added WHERE workspace = ? AND email = ?) AS n`, workspace, email, nowSeconds(), workspace, email)!.n as number;
        if (this.#host.seats(workspace, true) - replaces >= cap) fail(429, "too_many_members");
        // An invitation to the same email is replaced by being added.
        this.#db.run("DELETE FROM invitations WHERE workspace = ? AND email = ?", workspace, email);
        const accounts = this.#db.byEmail(email);
        if (accounts.length > 0) {
          for (const account of accounts) {
            this.#db.run("INSERT INTO members (workspace, sub, role, added_at) VALUES (?, ?, ?, ?) ON CONFLICT (workspace, sub) DO NOTHING", workspace, account, role, nowSeconds());
            this.#db.run("UPDATE users SET admitted = 'invitation' WHERE sub = ? AND admitted IS NULL", account);
          }
          joined.push(email);
        } else {
          this.#db.run(`INSERT INTO added (workspace, email, role, added_by, added_at) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (workspace, email) DO UPDATE SET role = excluded.role, added_by = excluded.added_by`, workspace, email, role, by, nowSeconds());
          added.push(email);
        }
      }
    });
    const view = this.#host.changed(workspace, true, joined.flatMap((e) => this.#db.byEmail(e)));
    return { joined, added, already, view };
  }

  /** Takes back an email added but not signed in yet. */
  removeAdded(sub: string, workspace: string, email: string): WorkspaceView {
    this.#db.role(sub, workspace, MANAGERS);
    this.#db.run("DELETE FROM added WHERE workspace = ? AND email = ?", workspace, email.trim().toLowerCase());
    this.forgetMailRetry(workspace, email.trim().toLowerCase());
    return this.#host.view(sub, workspace, this.#host.changed(workspace, true));
  }

  async invite(sub: string, workspace: string, role: Role, email: string | null): Promise<{ token: string; id: string; expires_at: number }> {
    const mine = this.#db.role(sub, workspace, MANAGERS);
    if (!ROLES.includes(role)) fail(400, "invalid_role");
    if (role === "owner" && mine !== "owner") fail(403, "forbidden");
    if (email === null || !/^[^\s@]{1,64}@[^\s@]{1,190}$/.test(email)) fail(400, "invalid_email");
    if (this.#db.one("SELECT 1 AS x FROM members m JOIN users u ON u.sub = m.sub WHERE m.workspace = ? AND lower(u.email) = lower(?)", workspace, email!)) fail(409, "already_member");
    const open = this.#db.one("SELECT COUNT(*) AS n FROM invitations WHERE workspace = ? AND expires_at > ?", workspace, nowSeconds())!.n as number;
    // Every open invitation holds a seat, but a newer one to the same email takes the older one's.
    const replaces = this.#db.one("SELECT 1 AS x FROM invitations WHERE workspace = ? AND email = ? AND expires_at > ?", workspace, email!.toLowerCase(), nowSeconds()) ? 1 : 0;
    if (open - replaces >= LIMITS.openInvitations) fail(429, "too_many_invitations");
    if (this.#host.seats(workspace, true) - replaces >= this.#host.memberCap(workspace)) fail(429, "too_many_members");
    const token = randomSecret();
    const id = ulid();
    const expires = nowSeconds() + INVITATION_TTL_SEC;
    // A newer invitation for the same email replaces the older one.
    this.#db.run("DELETE FROM invitations WHERE workspace = ? AND email = ?", workspace, email!.toLowerCase());
    this.#db.run("INSERT INTO invitations (id, workspace, token_hash, role, email, created_by, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      id, workspace, await digest(token), role, email!.toLowerCase(), sub, expires);
    this.#host.changed(workspace, false);
    this.#host.tell(this.#db.byEmail(email), LIST);
    return { token, id, expires_at: expires };
  }

  /** What an invitation leads to, for the page that asks to accept it. */
  async previewInvitation(token: string): Promise<{ workspace: string; name: string; role: Role; inviter: string; email: string | null }> {
    const row = this.#db.one(`SELECT i.workspace, w.name, i.role, i.email, COALESCE(u.name, u.email, '') AS inviter FROM invitations i
      JOIN workspaces w ON w.id = i.workspace LEFT JOIN users u ON u.sub = i.created_by WHERE i.token_hash = ? AND i.expires_at > ?`, await digest(token), nowSeconds());
    if (!row) fail(404, "invitation_not_found");
    return { workspace: row!.workspace as string, name: row!.name as string, role: row!.role as Role, inviter: row!.inviter as string, email: (row!.email as string | null) ?? null };
  }

  async acceptInvitation(sub: string, email: string, token: string): Promise<WorkspaceView> {
    const hash = await digest(token);
    const row = this.#db.one("SELECT id, workspace, role, email FROM invitations WHERE token_hash = ? AND expires_at > ?", hash, nowSeconds());
    if (!row) fail(404, "invitation_not_found");
    if (row!.email && (row!.email as string) !== email.toLowerCase()) fail(403, "invitation_for_other_email");
    const workspace = row!.workspace as string;
    const existing = this.#db.one("SELECT role FROM members WHERE workspace = ? AND sub = ?", workspace, sub);
    if (!existing && this.#host.seats(workspace) >= this.#host.memberCap(workspace)) fail(429, "too_many_members");
    this.#db.ctx.storage.transactionSync(() => {
      this.#db.run("DELETE FROM invitations WHERE id = ?", row!.id);
      // Accepting never lowers a role someone already has.
      this.#db.run("UPDATE users SET admitted = 'invitation' WHERE sub = ? AND admitted IS NULL", sub);
      if (!existing) this.#db.run("INSERT INTO members (workspace, sub, role, added_at) VALUES (?, ?, ?, ?)", workspace, sub, row!.role, nowSeconds());
      else if (ROLES.indexOf(row!.role as Role) < ROLES.indexOf(existing.role as Role)) this.#db.run("UPDATE members SET role = ? WHERE workspace = ? AND sub = ?", row!.role, workspace, sub);
    });
    return this.#host.view(sub, workspace, this.#host.changed(workspace, true));
  }

  /** Invitations waiting for this email: what someone sees right after signing in. */
  invitationsFor(email: string): PendingInvitation[] {
    return this.#db.rows(`SELECT i.id, i.workspace, w.name, i.role, COALESCE(NULLIF(u.name, ''), u.email, '') AS inviter, i.expires_at FROM invitations i
      JOIN workspaces w ON w.id = i.workspace LEFT JOIN users u ON u.sub = i.created_by
      WHERE i.email = ? AND i.expires_at > ? ORDER BY i.expires_at`, email.toLowerCase(), nowSeconds()) as unknown as PendingInvitation[];
  }

  /** Accepts an invitation addressed to this account's email, by id (no link needed). */
  acceptById(sub: string, email: string, id: string): WorkspaceView {
    const row = this.#db.one("SELECT id, workspace, role, email FROM invitations WHERE id = ? AND expires_at > ?", id, nowSeconds());
    if (!row) fail(404, "invitation_not_found");
    if ((row!.email as string | null) !== email.toLowerCase()) fail(403, "invitation_for_other_email");
    const workspace = row!.workspace as string;
    const existing = this.#db.one("SELECT role FROM members WHERE workspace = ? AND sub = ?", workspace, sub);
    if (!existing && this.#host.seats(workspace) >= this.#host.memberCap(workspace)) fail(429, "too_many_members");
    this.#db.ctx.storage.transactionSync(() => {
      this.#db.run("DELETE FROM invitations WHERE id = ?", id);
      this.#db.run("UPDATE users SET admitted = 'invitation' WHERE sub = ? AND admitted IS NULL", sub);
      if (!existing) this.#db.run("INSERT INTO members (workspace, sub, role, added_at) VALUES (?, ?, ?, ?)", workspace, sub, row!.role, nowSeconds());
      // As with the invitation's link, accepting grants its role without lowering one already held.
      else if (ROLES.indexOf(row!.role as Role) < ROLES.indexOf(existing.role as Role)) this.#db.run("UPDATE members SET role = ? WHERE workspace = ? AND sub = ?", row!.role, workspace, sub);
    });
    return this.#host.view(sub, workspace, this.#host.changed(workspace, true));
  }

  declineById(email: string, id: string): void {
    const row = this.#db.one("SELECT workspace FROM invitations WHERE id = ? AND email = ?", id, email.toLowerCase());
    if (!row) return;
    this.#db.run("DELETE FROM invitations WHERE id = ?", id);
    this.#host.changed(row.workspace as string, false);
    this.#host.tell(this.#db.byEmail(email), LIST);
  }

  revokeInvitation(sub: string, workspace: string, id: string): void {
    this.#db.role(sub, workspace, MANAGERS);
    const row = this.#db.one("SELECT email FROM invitations WHERE id = ? AND workspace = ?", id, workspace);
    if (!row) return;
    this.#db.run("DELETE FROM invitations WHERE id = ?", id);
    this.#host.changed(workspace, false);
    this.#host.tell(this.#db.byEmail(row.email as string | null), LIST);
  }

  async setRole(sub: string, workspace: string, target: string, role: Role): Promise<WorkspaceView> {
    this.#db.role(sub, workspace, ["owner"]);
    if (!ROLES.includes(role)) fail(400, "invalid_role");
    const current = this.#db.one("SELECT role FROM members WHERE workspace = ? AND sub = ?", workspace, target);
    if (!current) fail(404, "member_not_found");
    if (current!.role === "owner" && role !== "owner") this.#keepAnOwner(workspace);
    this.#db.run("UPDATE members SET role = ? WHERE workspace = ? AND sub = ?", role, workspace, target);
    // The credentials it holds name its old role: its stations take none of them from now on (it gets a new one).
    this.#host.revoke(workspace, "sub", target);
    const kept = this.#host.changed(workspace, false);
    this.#host.tell([target], LIST);
    const view = this.#host.view(sub, workspace, kept);
    await this.#host.delivered();
    return view;
  }

  /** Removes a member; anyone may remove themselves (leave). */
  async removeMember(sub: string, workspace: string, target: string): Promise<void> {
    const mine = this.#db.role(sub, workspace);
    const row = this.#db.one("SELECT role FROM members WHERE workspace = ? AND sub = ?", workspace, target);
    if (!row) fail(404, "member_not_found");
    if (target !== sub) {
      if (!MANAGERS.includes(mine)) fail(403, "forbidden");
      if (row!.role === "owner" && mine !== "owner") fail(403, "forbidden");
    }
    if (row!.role === "owner") this.#keepAnOwner(workspace);
    this.#db.run("DELETE FROM members WHERE workspace = ? AND sub = ?", workspace, target);
    const email = this.#db.one("SELECT email FROM users WHERE sub = ?", target)?.email as string | undefined;
    if (email) this.forgetMailRetry(workspace, email);
    this.#host.rigsGone(workspace, target);
    this.#host.revoke(workspace, "sub", target);
    this.#host.changed(workspace, true, [target]);
    await this.#host.delivered();
  }

  /**
   * The account deletes itself (DELETE /v1/me; its sessions end in its own object): the workspaces only it is in go as
   * deleteWorkspace takes them, it leaves the others, and what is kept of it goes: its row, push registrations, devices,
   * lock requests, bug reports, and what waits for its email (pending, added, invitations). Refused (409 sole_owner)
   * while it is the only owner of a workspace others are in: they would be left with no one to manage it.
   */
  async deleteAccount(sub: string): Promise<{ appleTokens: string[] }> {
    const email = this.#db.one("SELECT email FROM users WHERE sub = ?", sub)?.email as string | undefined;
    const memberships = this.#db.rows("SELECT workspace, role FROM members WHERE sub = ?", sub).map((r) => ({ workspace: r.workspace as string, role: r.role as Role }));
    const alone = memberships.filter((m) => this.#db.members(m.workspace).length === 1).map((m) => m.workspace);
    for (const m of memberships) {
      if (m.role !== "owner" || alone.includes(m.workspace)) continue;
      if ((this.#db.one("SELECT COUNT(*) AS n FROM members WHERE workspace = ? AND role = 'owner'", m.workspace)!.n as number) <= 1) fail(409, "sole_owner");
    }
    for (const workspace of alone) {
      this.#db.role(sub, workspace, ["owner"]);
      this.#host.removeWorkspace(workspace);
    }
    for (const { workspace } of memberships.filter((m) => !alone.includes(m.workspace))) {
      this.#db.run("DELETE FROM members WHERE workspace = ? AND sub = ?", workspace, sub);
      this.#host.rigsGone(workspace, sub);
      this.#host.revoke(workspace, "sub", sub);
      this.#host.changed(workspace, true);
    }
    const appleTokens: string[] = [];
    this.#db.ctx.storage.transactionSync(() => {
      for (const row of this.#db.rows("SELECT refresh_token FROM apple_identities WHERE user_sub = ? AND refresh_token IS NOT NULL", sub)) {
        if (typeof row.refresh_token === "string" && row.refresh_token) appleTokens.push(row.refresh_token);
      }
      this.#db.run("DELETE FROM apple_identities WHERE user_sub = ?", sub);
      for (const table of ["push", "devices", "lock_requests"]) this.#db.run(`DELETE FROM ${table} WHERE sub = ?`, sub);
      this.#db.run("DELETE FROM feedback_replies WHERE feedback IN (SELECT id FROM feedback WHERE account = ?)", sub);
      this.#db.run("DELETE FROM feedback WHERE account = ?", sub);
      if (email) {
        this.#db.run("DELETE FROM pending WHERE lower(email) = lower(?)", email);
        this.#db.run("DELETE FROM added WHERE lower(email) = lower(?)", email);
        this.#db.run("DELETE FROM invitations WHERE lower(email) = lower(?)", email);
        this.#db.run("DELETE FROM added_mail_retries WHERE lower(email) = lower(?)", email);
      }
      this.#db.run("DELETE FROM users WHERE sub = ?", sub);
    });
    this.#host.resetDevicesSeen({ sub });
    this.#host.tell([sub], LIST);
    this.#host.adminChanged("users", "workspaces", "feedback");
    await this.#host.delivered();
    return { appleTokens };
  }

  #keepAnOwner(workspace: string): void {
    const owners = this.#db.one("SELECT COUNT(*) AS n FROM members WHERE workspace = ? AND role = 'owner'", workspace)!.n as number;
    if (owners <= 1) fail(409, "last_owner");
  }
}
