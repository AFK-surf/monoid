import { ulid } from "ulid";
import { nowSeconds } from "../auth";
import type { Part } from "../changelog";
import type { FeedbackInput } from "../feedback";
import type { AdminFeedback, FeedbackReply, FeedbackStatus, WorkspaceFeedback } from "../types";
import type { DirectoryDb, DirectoryHost } from "./db";
import { FEEDBACK_LISTED, FEEDBACK_PER_DAY, FEEDBACK_REPLIES_PER_DAY, FEEDBACK_SHOWN, FEEDBACK_SLIM, contextOf, fail, replyOf, sessionOf, type Row } from "./types";

const SQL_BATCH = 90;

function chunked<T>(items: readonly T[], run: (batch: readonly T[], marks: string) => void): void {
  for (let i = 0; i < items.length; i += SQL_BATCH) {
    const batch = items.slice(i, i + SQL_BATCH);
    run(batch, batch.map(() => "?").join(", "));
  }
}

// ── bug reports (feedback.ts) ───────────────────────────────────────────

export class DirectoryFeedback {
  #db: DirectoryDb;
  #host: DirectoryHost;

  /** The fixes markFixed last marked by, while no report came since (addFeedback, moveImport). */
  #fixesMarked: string | null = null;

  constructor(db: DirectoryDb, host: DirectoryHost) {
    this.#db = db;
    this.#host = host;
  }

  resetFixesMarked(): void {
    this.#fixesMarked = null;
  }

  /** Keeps a report; the same sender's same key again is the one kept. null: the sender sent too many today. */
  addFeedback(input: FeedbackInput): { id: string; number: number; duplicate: boolean } | null {
    const kept = this.#db.one("SELECT id, number FROM feedback WHERE sender = ? AND key = ?", input.sender, input.key);
    if (kept) return { id: kept.id as string, number: kept.number as number, duplicate: true };
    const now = nowSeconds();
    const today = this.#db.one("SELECT COUNT(*) AS n FROM feedback WHERE sender = ? AND created_at > ?", input.sender, now - 24 * 60 * 60);
    if ((today?.n as number) >= FEEDBACK_PER_DAY) return null;
    // A station's report is of the workspace it names (one it is in), else of its home.
    const memberships = input.station ? this.#db.memberships(input.station) : [];
    if (input.workspace && !memberships.includes(input.workspace)) fail(403, "not_in_workspace");
    const workspace = input.station ? (input.workspace ?? memberships[0] ?? null) : null;
    const number = ((this.#db.one("SELECT MAX(number) AS n FROM feedback")?.n as number | null) ?? 0) + 1;
    const id = ulid();
    this.#db.run(
      `INSERT INTO feedback (id, number, key, channel, sender, station, workspace, account, title, body, area, reporter, context, logs, status, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'new', ?, ?)`,
      id, number, input.key, input.channel, input.sender, input.station, workspace, input.account, input.title, input.body, input.area, input.reporter, input.context, input.logs, now, now,
    );
    // (a changelog may name it already: markFixed runs it again)
    this.#fixesMarked = null;
    this.#host.adminChanged("feedback");
    return { id, number, duplicate: false };
  }

  /**
   * The reports, newest first, with the station, workspace and account they came from, and their replies. `slim` (the
   * console's list): without their logs, only whether each has any (`has_logs`), as up to FEEDBACK_LISTED of them at
   * 64 KB each is what every console carried at each change; a report's own page reads its logs (adminFeedbackItem).
   */
  adminFeedback(slim = false): AdminFeedback[] {
    const replies = new Map<string, FeedbackReply[]>();
    for (const r of this.#db.rows(`SELECT * FROM feedback_replies WHERE feedback IN (SELECT id FROM feedback ORDER BY number DESC LIMIT ${FEEDBACK_LISTED}) ORDER BY created_at, rowid`)) {
      const reply = replyOf(r);
      const list = replies.get(r.feedback as string) ?? [];
      list.push(reply);
      replies.set(r.feedback as string, list);
    }
    const rows = this.#db.rows(`SELECT ${slim ? FEEDBACK_SLIM : "f.*"}, s.name AS station_name, w.name AS workspace_name, u.email AS account_email, u.name AS account_name
      FROM feedback f LEFT JOIN station_members s ON s.station = f.station AND s.workspace = f.workspace LEFT JOIN workspaces w ON w.id = f.workspace LEFT JOIN users u ON u.sub = f.account
      ORDER BY f.number DESC LIMIT ${FEEDBACK_LISTED}`);
    return rows.map((r) => this.#feedbackOf(r, replies.get(r.id as string) ?? [], slim));
  }

  /**
   * One report whole, its logs too, by its id or its number (`FB-12`, `fb-12`, `12`): any of them, not only the
   * newest the list holds.
   */
  adminFeedbackItem(idOrRef: string): AdminFeedback {
    const number = /^(?:fb-)?([0-9]{1,9})$/i.exec(idOrRef)?.[1];
    const r = this.#db.one(`SELECT f.*, s.name AS station_name, w.name AS workspace_name, u.email AS account_email, u.name AS account_name
      FROM feedback f LEFT JOIN station_members s ON s.station = f.station AND s.workspace = f.workspace LEFT JOIN workspaces w ON w.id = f.workspace LEFT JOIN users u ON u.sub = f.account
      WHERE ${number !== undefined ? "f.number = ?" : "f.id = ?"}`, number !== undefined ? Number(number) : idOrRef);
    if (!r) fail(404, "feedback_not_found");
    const replies = this.#db.rows("SELECT * FROM feedback_replies WHERE feedback = ? ORDER BY created_at, rowid", r!.id).map(replyOf);
    return this.#feedbackOf(r!, replies, false);
  }

  /** A report's row as the console has it. */
  #feedbackOf(r: Row, replies: FeedbackReply[], slim: boolean): AdminFeedback {
    let context: Record<string, unknown> | null = null;
    try {
      context = r.context ? (JSON.parse(r.context as string) as Record<string, unknown>) : null;
    } catch {
      // Cut at its limit: shown as it came.
      context = { text: r.context };
    }
    return {
      id: r.id as string,
      number: r.number as number,
      channel: r.channel === "beta" ? "beta" : "stable",
      station: r.station ? { id: r.station as string, name: (r.station_name as string | null) ?? "" } : null,
      workspace: r.workspace ? { id: r.workspace as string, name: (r.workspace_name as string | null) ?? "" } : null,
      account: r.account ? { sub: r.account as string, email: (r.account_email as string | null) ?? "", name: (r.account_name as string | null) ?? "" } : null,
      title: r.title as string,
      body: r.body as string,
      area: r.area as AdminFeedback["area"],
      reporter: r.reporter as string,
      context,
      logs: slim ? null : ((r.logs as string | null) ?? null),
      has_logs: slim ? Boolean(r.has_logs) : typeof r.logs === "string" && r.logs.trim() !== "",
      status: r.status as FeedbackStatus,
      fixed_in: (r.fixed_in as number | null) ?? null,
      told_at: (r.told_at as number | null) ?? null,
      created_at: r.created_at as number,
      updated_at: r.updated_at as number,
      replies,
    };
  }

  setFeedbackStatus(id: string, status: FeedbackStatus): void {
    if (!this.#db.one("SELECT 1 AS found FROM feedback WHERE id = ?", id)) fail(404, "feedback_not_found");
    this.#db.run("UPDATE feedback SET status = ?, updated_at = ? WHERE id = ?", status, nowSeconds(), id);
    this.#host.adminChanged("feedback");
  }

  /**
   * Marks the reports the changelog says are fixed (newest entry first): the version and parts of the latest fix of
   * each, until its station is told; one the team marked won't fix stays so.
   */
  markFixed(fixes: { number: number; version: number; parts: string[] }[]): void {
    // The same changelog as last time, and no report since: nothing more to mark (every console's list and every
    // station's ask runs it).
    const said = JSON.stringify(fixes);
    if (said === this.#fixesMarked) return;
    const untold = this.#db.rows("SELECT number, fixed_in FROM feedback WHERE told_at IS NULL");
    if (untold.length === 0) {
      this.#fixesMarked = said;
      return;
    }
    const currentByNumber = new Map<number, number | null>(untold.map((r) => [r.number as number, r.fixed_in as number | null]));
    const pending = new Map<number, { number: number; version: number; parts: string[] }>();
    for (const fix of fixes) {
      const current = currentByNumber.get(fix.number);
      if (current === undefined || (current !== null && current >= fix.version)) continue;
      const prev = pending.get(fix.number);
      if (!prev || fix.version > prev.version) pending.set(fix.number, fix);
    }
    if (pending.size === 0) {
      this.#fixesMarked = said;
      return;
    }
    const now = nowSeconds();
    let marked = 0;
    this.#db.ctx.storage.transactionSync(() => {
      for (const { number, version, parts } of pending.values()) {
        marked += this.#db.ctx.storage.sql.exec(
          `UPDATE feedback SET fixed_in = ?, fixed_parts = ?, status = CASE WHEN status = 'wontfix' THEN status ELSE 'fixed' END, updated_at = ?
           WHERE number = ? AND told_at IS NULL AND (fixed_in IS NULL OR fixed_in < ?)`,
          version, JSON.stringify(parts), now, number, version,
        ).rowsWritten;
      }
    });
    this.#fixesMarked = said;
    if (marked > 0) this.#host.adminChanged("feedback");
  }

  /** A station's reports that are fixed and it has not told of yet, with where it reported each. */
  fixedUntold(station: string): { desktopPlatform: string | null; id: string; number: number; title: string; channel: "stable" | "beta"; version: number; parts: Part[]; session: string | null; thread: string | null }[] {
    return this.#db.rows("SELECT id, number, title, channel, fixed_in, fixed_parts, context FROM feedback WHERE station = ? AND fixed_in IS NOT NULL AND told_at IS NULL AND status = 'fixed' ORDER BY number", station).map((r) => {
      let context: Record<string, unknown> = {};
      let parts: Part[] = [];
      try {
        context = JSON.parse((r.context as string | null) ?? "{}") as Record<string, unknown>;
      } catch {
        // Cut at its limit: no session to tell.
      }
      try {
        parts = JSON.parse((r.fixed_parts as string | null) ?? "[]") as Part[];
      } catch {
        parts = [];
      }
      const said = (v: unknown) => (typeof v === "string" && v ? v : null);
      return { desktopPlatform: said(context.desktopPlatform), id: r.id as string, number: r.number as number, title: r.title as string, channel: r.channel === "beta" ? "beta" : "stable", version: r.fixed_in as number, parts, session: said(context.session), thread: said(context.thread) };
    });
  }

  /**
   * The workspace a station's report came from a chat of: the one the station said (context.workspace, from stations
   * that say it), else the one its link names (context.link, `/o/<workspace>/…`); only while the station is in it.
   * Not the report's `workspace`, which is the station's home where it said none. null: none to show it in.
   */
  #chatWorkspace(station: string | null, context: string | null): string | null {
    if (!station) return null;
    const said = contextOf(context);
    const named = typeof said.workspace === "string" ? said.workspace : typeof said.link === "string" ? (/\/o\/([0-9A-HJKMNP-TV-Z]{26})\//.exec(said.link)?.[1] ?? null) : null;
    return named && this.#db.memberships(station).includes(named) ? named : null;
  }

  /**
   * The team's reply on a report (`by`: the admin's email or the feedback monitor), shown to the people of the chat it
   * was reported from, in its workspace's members' apps (feedbackOf), never given to a station or its agents: each of
   * them is told on its events socket. One with no such chat (an account's report, or one whose chat cannot be found)
   * reaches no one: answered why (`undeliverable`), not kept.
   */
  replyToFeedback(id: string, by: string, text: string): { id: string; delivery: "pending" } | { undeliverable: "no_station" | "no_chat" } {
    const report = this.#db.one("SELECT station, context FROM feedback WHERE id = ?", id);
    if (!report) fail(404, "feedback_not_found");
    if (!report!.station) return { undeliverable: "no_station" };
    const workspace = this.#chatWorkspace(report!.station as string, report!.context as string | null);
    if (!workspace || !sessionOf(report!.context as string | null)) return { undeliverable: "no_chat" };
    const reply = ulid();
    const now = nowSeconds();
    this.#db.run("INSERT INTO feedback_replies (id, feedback, author, by, text, created_at) VALUES (?, ?, 'team', ?, ?, ?)", reply, id, by, text, now);
    this.#db.run("UPDATE feedback SET updated_at = ? WHERE id = ?", now, id);
    this.#host.tell(this.#db.members(workspace), { type: "feedback", workspace });
    this.#host.adminChanged("feedback");
    return { id: reply, delivery: "pending" };
  }

  /** The reporter's agent answers one of its station's reports (FB-`number`): kept with the team's replies. null: too many today. */
  reporterReply(station: string, number: number, text: string, session: string | null): { id: string } | null {
    const report = this.#db.one("SELECT id, context FROM feedback WHERE number = ? AND station = ?", number, station);
    if (!report) fail(404, "feedback_not_found");
    const now = nowSeconds();
    const today = this.#db.one("SELECT COUNT(*) AS n FROM feedback_replies r JOIN feedback f ON f.id = r.feedback WHERE f.station = ? AND r.author = 'reporter' AND r.created_at > ?", station, now - 24 * 60 * 60);
    if ((today?.n as number) >= FEEDBACK_REPLIES_PER_DAY) return null;
    return { id: this.#reporterSaid(report!.id as string, session ? `session:${session}` : "", text, report!.context as string | null, station) };
  }

  /** A reply from the reporter's side (`by`: `session:<key>`, its agent's; `account:<sub>`, a person's in the app), told to the chat's people. */
  #reporterSaid(id: string, by: string, text: string, context: string | null, station: string): string {
    const reply = ulid();
    const now = nowSeconds();
    this.#db.run("INSERT INTO feedback_replies (id, feedback, author, by, text, created_at) VALUES (?, ?, 'reporter', ?, ?, ?)", reply, id, by, text, now);
    this.#db.run("UPDATE feedback SET updated_at = ? WHERE id = ?", now, id);
    const workspace = this.#chatWorkspace(station, context);
    if (workspace) this.#host.tell(this.#db.members(workspace), { type: "feedback", workspace });
    this.#host.adminChanged("feedback");
    return reply;
  }

  /**
   * The reports with a reply of the team's from chats of a workspace, for a member's device to show in each chat (by
   * its station and session), newest first; the team's replies given are marked delivered. Who may read them is who
   * may read those chats: the workspace's members.
   */
  feedbackOf(sub: string, workspace: string): { feedback: WorkspaceFeedback[] } {
    this.#db.role(sub, workspace);
    const rows = this.#db.rows(`SELECT f.id, f.number, f.title, f.station, f.context FROM feedback f JOIN station_members s ON s.station = f.station AND s.workspace = ?
      WHERE EXISTS (SELECT 1 FROM feedback_replies r WHERE r.feedback = f.id AND r.author = 'team') ORDER BY f.number DESC LIMIT ${FEEDBACK_SHOWN}`, workspace)
      .filter((r) => this.#chatWorkspace(r.station as string, r.context as string | null) === workspace);
    if (rows.length === 0) return { feedback: [] };

    const feedbackIds = rows.map((r) => r.id as string);
    const repliesByFeedback = new Map<string, Row[]>();
    const undelivered: string[] = [];
    const subs = new Set<string>();
    chunked(feedbackIds, (batch, marks) => {
      for (const reply of this.#db.rows(
        `SELECT feedback, id, author, by, text, created_at, delivered_at FROM feedback_replies WHERE feedback IN (${marks}) ORDER BY created_at, rowid`,
        ...batch,
      )) {
        const fid = reply.feedback as string;
        const list = repliesByFeedback.get(fid);
        if (list) list.push(reply);
        else repliesByFeedback.set(fid, [reply]);
        if (reply.author === "team" && reply.delivered_at === null) undelivered.push(reply.id as string);
        const by = reply.by as string;
        if (by.startsWith("account:")) subs.add(by.slice("account:".length));
      }
    });

    const names = new Map<string, string>();
    chunked([...subs], (batch, marks) => {
      for (const u of this.#db.rows(`SELECT sub, name, email FROM users WHERE sub IN (${marks})`, ...batch)) {
        names.set(`account:${u.sub as string}`, (u.name as string) || (u.email as string));
      }
    });

    if (undelivered.length > 0) {
      const now = nowSeconds();
      this.#db.ctx.storage.transactionSync(() => {
        chunked(undelivered, (batch, marks) => {
          this.#db.run(`UPDATE feedback_replies SET delivered_at = ? WHERE id IN (${marks})`, now, ...batch);
        });
      });
    }

    const feedback = rows.map((r): WorkspaceFeedback => {
      const replies = repliesByFeedback.get(r.id as string) ?? [];
      const context = contextOf(r.context as string | null);
      return {
        id: r.id as string,
        number: r.number as number,
        title: r.title as string,
        station: r.station as string,
        session: sessionOf(r.context as string | null) ?? "",
        thread: typeof context.thread === "string" ? context.thread : null,
        replies: replies.map((reply) => {
          const by = reply.by as string;
          const from = reply.author === "team" ? "team" : by.startsWith("account:") ? "person" : "agent";
          return { id: reply.id as string, from, name: from === "person" ? (names.get(by) ?? "") : "", text: reply.text as string, created_at: reply.created_at as number };
        }),
      };
    });
    return { feedback };
  }

  /** A member answers, in the app, a report shown in a chat of the workspace: kept as theirs. */
  memberFeedbackReply(sub: string, workspace: string, id: string, text: string): { id: string } {
    this.#db.role(sub, workspace);
    const report = this.#db.one("SELECT station, context FROM feedback WHERE id = ?", id);
    if (!report || this.#chatWorkspace(report.station as string | null, report.context as string | null) !== workspace) fail(404, "feedback_not_found");
    return { id: this.#reporterSaid(id, `account:${sub}`, text, report!.context as string | null, report!.station as string) };
  }

  /** The station has told these of its reports' fixes. */
  toldFixed(station: string, ids: string[]): void {
    const now = nowSeconds();
    let told = 0;
    for (const id of ids) told += this.#db.ctx.storage.sql.exec("UPDATE feedback SET told_at = ? WHERE id = ? AND station = ? AND fixed_in IS NOT NULL AND told_at IS NULL", now, id, station).rowsWritten;
    // (the console shows when each was told)
    if (told > 0) this.#host.adminChanged("feedback");
  }
}
