// Slack messages extracted from session transcripts (`slack_said`) and per-station user names (`slack_who`) (account.ts).
import { readItem, type Said } from "../elsewhere.ts";
import type { SqlRow, SqlValue } from "../host.ts";
import { equal } from "../util.ts";
import { type DbEnv, HEARD, type J, K, parse, slackId } from "./collection.ts";
import { ensureSlackSaid, ensureSlackWho } from "./schema.ts";

export class SlackSaidStore {
  readonly #env: DbEnv;
  #slackSaidMade: boolean | undefined;
  /// Whether `slack_who` is there (made as the database opens).
  #slackWhoMade = false;
  #fillingSaid = false;
  #slackNames = new Map<string, [string, string][]>();
  #slackNamesStale = new Set<string>();

  constructor(env: DbEnv) {
    this.#env = env;
  }

  open(): void {
    const sql = this.#env.sql;
    try {
      const said = ensureSlackSaid(sql);
      let who = false;
      try {
        who = ensureSlackWho(sql);
        this.#slackWhoMade = true;
      } catch {
        // No room to make it: who was heard is read of slack_said, as before it was.
        this.#slackWhoMade = false;
      }
      if (said) this.#fillSlackSaid();
      if (this.#slackWhoMade && (said || who)) this.#fillSlackWho();
    } catch {
      // No room to make it: what agents said in Slack is not shown in their chats this time.
    }
  }

  onRollback(): void {
    this.#slackNames.clear();
  }

  onSlackTold(station: string): void {
    // (slack_who, where it is kept, says when its names change: #heardWho)
    if (!this.#slackWhoMade) this.#slackNames.delete(station);
  }

  forgetStation(station: string, tellSlack: (session: string) => void): void {
    if (this.hasSlackSaid()) {
      const sessions = this.#env.sql.all("SELECT DISTINCT session FROM slack_said WHERE station = ?", [station]);
      if (this.#env.sql.run("DELETE FROM slack_said WHERE station = ?", [station]) > 0) {
        for (const [session] of sessions) tellSlack(String(session));
      }
    }
    if (this.#slackWhoMade) this.#env.sql.run("DELETE FROM slack_who WHERE station = ?", [station]);
    this.#slackNames.delete(station);
  }

  hasSlackSaid(): boolean {
    this.#slackSaidMade ??= this.#env.sql.all("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'slack_said'").length > 0;
    return this.#slackSaidMade;
  }

  /// Whether slack_said's rows written are kept in slack_who as they are (not while slack_said is filled whole: it is
  /// filled whole after).
  get #keepWho(): boolean {
    return this.#slackWhoMade && !this.#fillingSaid;
  }

  /// What transcript items of a session say of Slack, into `slack_said`; calls' results, onto what they sent. Answers
  /// whether anything changed.
  readSlackSaid(station: string, session: string, items: [number, J][]): boolean {
    let changed = false;
    // (the people a row written over named, found again once all is written)
    const again = new Set<string>();
    for (const [n, e] of [...items].sort((a, b) => a[0] - b[0])) {
      const read = readItem(n, e);
      if (read === null) continue;
      if ("said" in read) {
        for (const s of read.said) {
          if (this.#keepWho) {
            const was = this.#env.sql.all(`SELECT user, who, at FROM slack_said WHERE station = ? AND session = ? AND i = ? AND k = ? AND ${HEARD}`, [station, session, n, s.k])[0];
            if (was !== undefined && (s.out || was[0] !== s.user || was[1] !== s.who || was[2] !== s.at)) again.add(slackId(String(was[0])));
          }
          this.#env.sql.run(
            "INSERT OR REPLACE INTO slack_said (station, session, i, k, out, call, user, who, at, dest, text, failed) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)",
            [station, session, n, s.k, s.out ? 1 : 0, s.call, s.user, s.who, s.at, s.to, s.text],
          );
          if (this.#keepWho && !s.out && s.user && s.who) this.#heardWho(station, slackId(s.user), s.who, s.at);
          changed = true;
        }
        continue;
      }
      const r = read.result;
      // Its call by its id, else the item just before it.
      const where = r.call !== null ? "call = ?" : "i = ?";
      const row = this.#env.sql.all(`SELECT i, dest, failed, refused FROM slack_said WHERE station = ? AND session = ? AND out = 1 AND ${where}`, [station, session, r.call ?? n - 1])[0];
      if (row === undefined) continue;
      const dest = String(row[1]);
      // A message of its own in a channel: Slack's answer says its thread.
      const to = r.ts !== null && !dest.includes("/") ? `${dest}/${r.ts}` : dest;
      if (to === dest && (row[2] === 1) === r.failed && (row[3] === 1) === r.refused) continue;
      this.#env.sql.run("UPDATE slack_said SET dest = ?, failed = ?, refused = ? WHERE station = ? AND session = ? AND i = ? AND out = 1", [to, r.failed ? 1 : 0, r.refused ? 1 : 0, station, session, row[0] as number]);
      changed = true;
    }
    for (const user of again) this.#whoAgain(station, user);
    return changed;
  }

  /// `user` heard at a station as `who` at `at`, into slack_who: first heard the earliest, named as heard the latest.
  /// What is named and in what order changing lets the names kept go (slackNames).
  #heardWho(station: string, user: string, who: string, at: number): void {
    const was = this.#env.sql.all("SELECT first, who, at FROM slack_who WHERE station = ? AND user = ?", [station, user])[0];
    if (was === undefined) {
      this.#env.sql.run("INSERT INTO slack_who (station, user, first, who, at) VALUES (?, ?, ?, ?, ?)", [station, user, at, who, at]);
      this.#slackNamesStale.add(station);
      return;
    }
    const first = Math.min(was[0] as number, at);
    const later = at >= (was[2] as number);
    const name = later ? who : String(was[1]);
    const last = later ? at : (was[2] as number);
    if (first === was[0] && name === was[1] && last === was[2]) return;
    this.#env.sql.run("UPDATE slack_who SET first = ?, who = ?, at = ? WHERE station = ? AND user = ?", [first, name, last, station, user]);
    if (first !== was[0] || name !== was[1]) this.#slackNamesStale.add(station);
  }

  /// slack_who's row of `user` at a station found again of slack_said (some of their rows gone or written over).
  #whoAgain(station: string, user: string): void {
    const ids = [station, user, `<@${user}>`];
    const of = (r: SqlRow) => slackId(String(r[0])) === user;
    const firsts = this.#env.sql.all(`SELECT user, MIN(at) FROM slack_said WHERE station = ? AND user IN (?, ?) AND ${HEARD} GROUP BY user`, ids).filter(of);
    const lasts = this.#env.sql.all(`SELECT user, who, MAX(at) FROM slack_said WHERE station = ? AND user IN (?, ?) AND ${HEARD} GROUP BY user`, ids).filter(of);
    const was = this.#env.sql.all("SELECT first, who, at FROM slack_who WHERE station = ? AND user = ?", [station, user])[0];
    if (firsts.length === 0) {
      if (was !== undefined) {
        this.#env.sql.run("DELETE FROM slack_who WHERE station = ? AND user = ?", [station, user]);
        this.#slackNamesStale.add(station);
      }
      return;
    }
    const first = Math.min(...firsts.map((r) => r[1] as number));
    const latest = lasts.reduce((a, b) => ((b[2] as number) > (a[2] as number) ? b : a));
    const who = String(latest[1]);
    const at = latest[2] as number;
    if (was !== undefined && first === was[0] && who === was[1] && at === was[2]) return;
    this.#env.sql.run("INSERT OR REPLACE INTO slack_who (station, user, first, who, at) VALUES (?, ?, ?, ?, ?)", [station, user, first, who, at]);
    if (was === undefined || first !== was[0] || who !== was[1]) this.#slackNamesStale.add(station);
  }

  /// slack_said's rows of a station `where` (of a session) go; slack_who's people they may have been the first or the
  /// last heard of found again. Answers whether any went.
  forgetSaid(station: string, where: string, params: SqlValue[]): boolean {
    const going = this.#keepWho ? this.#env.sql.all(`SELECT user, MIN(at), MAX(at) FROM slack_said WHERE station = ? AND ${where} AND ${HEARD} GROUP BY user`, [station, ...params]) : [];
    if (this.#env.sql.run(`DELETE FROM slack_said WHERE station = ? AND ${where}`, [station, ...params]) === 0) return false;
    const again = new Set<string>();
    for (const [raw, lo, hi] of going) {
      const user = slackId(String(raw));
      const was = this.#env.sql.all("SELECT first, at FROM slack_who WHERE station = ? AND user = ?", [station, user])[0];
      if (was === undefined || (lo as number) <= (was[0] as number) || (hi as number) >= (was[1] as number)) again.add(user);
    }
    for (const user of again) this.#whoAgain(station, user);
    return true;
  }

  /// slack_who filled whole of slack_said (either made now).
  #fillSlackWho(): void {
    const heard = new Map<string, { station: string; user: string; first: number; who: string; at: number }>();
    for (const [station, raw, first] of this.#env.sql.all(`SELECT station, user, MIN(at) FROM slack_said WHERE ${HEARD} GROUP BY station, user`)) {
      const user = slackId(String(raw));
      const key = K(String(station), user);
      const was = heard.get(key);
      if (was === undefined) heard.set(key, { station: String(station), user, first: first as number, who: "", at: -Infinity });
      else was.first = Math.min(was.first, first as number);
    }
    for (const [station, raw, who, at] of this.#env.sql.all(`SELECT station, user, who, MAX(at) FROM slack_said WHERE ${HEARD} GROUP BY station, user`)) {
      const was = heard.get(K(String(station), slackId(String(raw))));
      if (was !== undefined && (at as number) > was.at) {
        was.who = String(who);
        was.at = at as number;
      }
    }
    this.#env.sql.exec("BEGIN IMMEDIATE");
    try {
      this.#env.sql.run("DELETE FROM slack_who", []);
      for (const h of heard.values()) this.#env.sql.run("INSERT INTO slack_who (station, user, first, who, at) VALUES (?, ?, ?, ?, ?)", [h.station, h.user, h.first, h.who, h.at]);
      this.#env.sql.exec("COMMIT");
    } catch (e) {
      try {
        this.#env.sql.exec("ROLLBACK");
      } catch {
        // Rolled back already.
      }
      throw e;
    }
    this.#slackNames.clear();
  }

  /// `slack_said` made now: filled from the transcripts held.
  #fillSlackSaid(): void {
    const sessions = this.#env.sql.all("SELECT DISTINCT station, session FROM transcript");
    if (sessions.length === 0) return;
    this.#env.sql.exec("BEGIN IMMEDIATE");
    this.#fillingSaid = true;
    try {
      for (const [station, session] of sessions) {
        const items = this.#env.sql.all("SELECT i, json FROM transcript WHERE station = ? AND session = ? ORDER BY i", [station as string, session as string]).map((r) => [r[0] as number, parse(r[1])] as [number, J]);
        this.readSlackSaid(station as string, session as string, items);
      }
      this.#env.sql.exec("COMMIT");
    } catch (e) {
      try {
        this.#env.sql.exec("ROLLBACK");
      } catch {
        // Rolled back already.
      }
      throw e;
    } finally {
      this.#fillingSaid = false;
    }
  }

  /// What a session said in Slack and heard from it, in the order of its transcript.
  slackSaid(station: string, session: string): Said[] {
    if (!this.hasSlackSaid()) return [];
    return this.#env.sql.all("SELECT i, k, out, call, user, who, at, dest, text, failed, refused FROM slack_said WHERE station = ? AND session = ? ORDER BY i, k", [station, session])
      .map((r) => ({
        i: r[0] as number, k: r[1] as number, out: r[2] === 1, call: (r[3] as string | null) ?? null, user: (r[4] as string | null) ?? null,
        who: (r[5] as string | null) ?? null, at: r[6] as number, to: r[7] as string, text: r[8] as string, failed: r[9] === 1,
        refused: r[10] === 1,
      }));
  }

  /// The Slack people a station's agents were given messages from, by Slack id: their names as last heard (a bot is said
  /// as its mention, `<@U…>`: its id out of it), in the order they were first heard. Read of slack_who, kept until
  /// what it names or its order changes (`#slackNamesStale`), and the list it was while it reads the same.
  slackNames(station: string): [string, string][] {
    if (!this.hasSlackSaid()) return [];
    const was = this.#slackNames.get(station);
    if (was !== undefined && !this.#slackNamesStale.has(station)) return was;
    this.#slackNamesStale.delete(station);
    const names: [string, string][] = this.#slackWhoMade
      ? this.#env.sql.all("SELECT user, who FROM slack_who WHERE station = ? ORDER BY first, user", [station]).map((r) => [String(r[0]), String(r[1])])
      : [...new Map(this.#env.sql.all(`SELECT user, who FROM slack_said WHERE station = ? AND ${HEARD} ORDER BY at`, [station]).map((r) => [slackId(String(r[0])), String(r[1])])).entries()];
    const kept = was !== undefined && equal(was, names) ? was : names;
    this.#slackNames.set(station, kept);
    return kept;
  }
}
