// Locked use: an agent works a Mac's desktop while its screen is locked. still.fail Helper unlocks it behind the
// Guard's overlay (`lockuse.begin`, its connection held) only while the station holds a lease, and locks it again
// once that connection closes: the last lease ended, or the station gone. Who may have it unlocked is decided here,
// before the Helper is asked (`mayUnlock`); the Guard and its authorization plugin check the rest on the Mac itself (the owner's binding in
// /Library/Application Support/still.fail/LockedUse.plist, written by an administrator).
//
// - Only an agent's own use of the screen asks: a screen task (`station_task screen: true`), a task's
//   `stillfail-job screen|show`, the `computer` tool on the desktop. A person's remote view never unlocks; while a
//   lease is held it is refused (desktop.ts), so no one watches a desktop its owner left locked.
// - The owner is the account the Mac is bound to (`binding.sub`), not a workspace's owner or admin (`managesStation`
//   is no one's Mac). A chat of this station's asks only when that account started it and wrote the message that
//   started this turn, in a still.fail chat (Slack's, Feishu's, Comma's and groups' say no reliable starter). A chat
//   another station opened (chat_create, sessions/opened.ts `parentStation`) also needs that station bound. A remote
//   task needs its station bound and the account it names as its requester the owner's: unsigned, so binding a station
//   is trusting it not to lie.
// - The switch (config.json `lockedUse: {until}`, epoch ms on the wall clock) is off unless the bound account turned it
//   on (`maySwitch`), and only until then: turned on, it holds SWITCH_MS (`switchedOn`); expired is off.
//
// A lease is one user of the screen (a session's view of the desktop, a task): the first asks the Helper to unlock,
// the last to end lets it lock again. Each ends when unused for its idle time (a view's: computer.ts IDLE_MS), and at
// most TERM_MS after it began or was last used, never later than CAP_MS after it began: then it is taken again,
// through the gate and the Helper's checks (cooldown, input seen) anew.
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";

/// A lease's term from its start or its last use.
export const TERM_MS = 15 * 60_000;
/// No lease outlives this from its start.
export const CAP_MS = 60 * 60_000;

/// What the Mac is bound to (the Helper's `lockuse.status` `binding`): the owner's account, the stations it trusts.
export type Binding = { sub: string; stations: string[] };

/// The Helper's `lockuse.status`: the Guard and plugin installed, this user bound.
export type LockUseStatus = { locked: boolean; installed: boolean; bound: boolean; uid?: number; binding?: Binding };

/// What wants the screen: a screen task, a task's `stillfail-job screen|show`, the `computer` tool on the desktop.
export type Source = "task" | "job" | "computer" | "other";

/// What kind of chat a session is: the station's own (`stillfail`), or one whose starter is not known for sure.
export type ChatKind = "stillfail" | "slack" | "feishu" | "comma" | "group" | "other";

/// Who asks. `local`: a session of this station's, with its chat's starter, the sender of the message this turn
/// answers, and the station that opened it (chat_create from another station; null: none). `remote`: another station's
/// task, by that station's key (the mesh's) and the requester it names.
export type Asker =
  | { kind: "local"; chat: ChatKind; createdBySub: string | null; senderSub: string | null; openedBy: string | null }
  | { kind: "remote"; station: string; requesterSub: string | null };

/// What the gate knows of the Mac: the switch, and the Helper's word.
export type Gate = { enabled: boolean; status: LockUseStatus | null };

/// Why an unlock is refused.
export type NoUnlock = "off" | "not-installed" | "not-bound" | "source" | "chat" | "creator" | "sender" | "opener" | "station" | "requester";

export type Verdict = { ok: true } | { ok: false; why: NoUnlock };

const no = (why: NoUnlock): Verdict => ({ ok: false, why });
const same = (a: string | null | undefined, b: string) => typeof a === "string" && a.trim() !== "" && a.trim() === b;

/// Whether `source` asked by `asker` may have the locked screen unlocked.
export function mayUnlock(source: Source, asker: Asker, gate: Gate): Verdict {
  if (!gate.enabled) return no("off");
  const s = gate.status;
  if (s === null || !s.installed) return no("not-installed");
  const binding = s.binding;
  if (!s.bound || binding === undefined || binding.sub.trim() === "") return no("not-bound");
  if (source === "other") return no("source");
  if (asker.kind === "remote") {
    if (!binding.stations.includes(asker.station)) return no("station");
    return same(asker.requesterSub, binding.sub) ? { ok: true } : no("requester");
  }
  if (asker.chat !== "stillfail") return no("chat");
  if (!same(asker.createdBySub, binding.sub)) return no("creator");
  if (!same(asker.senderSub, binding.sub)) return no("sender");
  if (asker.openedBy !== null && !binding.stations.includes(asker.openedBy)) return no("opener");
  return { ok: true };
}

/// Who asks, from a session's key and what the store says of it: another station's task (`remote:<…>:<station>:<key>`,
/// its requester not said yet: none passes), else this station's chat (the station's own connect `chat`, or another).
export function askerOf(key: string, o: { connect: string | null; createdBySub: string | null; senderSub: string | null; openedBy: string | null }): Asker {
  if (key.startsWith("remote:")) {
    const parts = key.split(":");
    return { kind: "remote", station: parts[2] ?? "", requesterSub: null };
  }
  return { kind: "local", chat: o.connect === "chat" ? "stillfail" : "other", createdBySub: o.createdBySub, senderSub: o.senderSub, openedBy: o.openedBy };
}

/// How long the switch holds once turned on.
export const SWITCH_MS = 24 * 60 * 60_000;

/// What config.json keeps as the switch turned on at `now`.
export const switchedOn = (now: number): { until: number } => ({ until: now + SWITCH_MS });

/// Whether the switch as config.json keeps it (`lockedUse`) is on at `now`: a time not yet passed.
export function switchOn(kept: unknown, now: number): boolean {
  const until = (kept as { until?: unknown } | null | undefined)?.until;
  return typeof until === "number" && Number.isFinite(until) && until > now;
}

/// Whether `sub` may turn the switch on or off: the bound account alone.
export function maySwitch(status: LockUseStatus | null, sub: string | null): boolean {
  return status?.bound === true && status.binding !== undefined && same(sub, status.binding.sub);
}

/// What an agent is told when the locked Mac is not unlocked for it, with what to do next.
export function refusedText(why: NoUnlock): string {
  const ask = "This Mac's screen is locked, so nothing on it can be seen or driven now. Ask its owner (chat_post kind=need_human) to unlock it, then try again";
  switch (why) {
    case "off":
      return `${ask}; or, if they want agents to use it while it is locked, to turn on locked use in this station's settings (only the account the Mac is bound to can; it stays on for 24 hours).`;
    case "not-installed":
      return `${ask}. Locked use is not installed on this Mac (an administrator installs it from the station's settings).`;
    case "not-bound":
      return `${ask}. Locked use is installed but this Mac's user is bound to no still.fail account yet (its owner binds it in the station's settings, on the Mac itself).`;
    case "chat":
      return `${ask}. Locked use works only from a still.fail chat its owner started, not Slack, Feishu, Comma or group chats.`;
    case "creator":
    case "sender":
      return `${ask}. Locked use unlocks it only for a chat its owner started, on a message its owner wrote.`;
    case "opener":
    case "station":
      return `${ask}. The station this request comes from is not one the owner bound for locked use.`;
    case "requester":
      return `${ask}. The task was not asked for by the account this Mac is bound to.`;
    case "source":
      return `${ask}.`;
  }
}

/// What the Helper's `lockuse.begin` refused with (`code`), as an agent is told it.
export function beginRefusedText(code: string, said?: string): string {
  switch (code) {
    case "cooldown":
      return "Someone used this Mac in the last minute, so it was not unlocked: wait a minute and try again, or ask its owner to unlock it.";
    case "suppressed":
      return "Someone touched this Mac while an agent used it, so it locked again and stays locked until its owner unlocks it by hand: ask them (chat_post kind=need_human).";
    case "secure-input":
      return "An app on this Mac holds secure keyboard input (a password field), so it was not unlocked: ask its owner to unlock it.";
    case "busy":
      return "This Mac is being unlocked or locked again right now: try again in a few seconds.";
    case "disabled":
    case "not-installed":
    case "not-bound":
      return `Locked use is not available on this Mac (${code}): ask its owner to unlock it, or to set up locked use in the station's settings.`;
    default:
      return `This Mac could not be unlocked${said ? ` (${said})` : ""}: ask its owner to unlock it.`;
  }
}

/// A connection to still.fail Helper (helper/app.ts `connect`: its request written, the rest the caller's).
export type LockLine = {
  setEncoding(encoding: "utf8"): unknown;
  on(event: "data", listener: (chunk: string) => void): unknown;
  on(event: "close" | "error", listener: () => void): unknown;
  destroy(): unknown;
};
/// What locked use needs of the Helper: a held `lockuse.begin` connection (helper/app.ts `connect`).
export type LockHelper = { connect(op: Record<string, unknown>): Promise<LockLine> };

/// Where the leases' timers are (a test's own; the station's `wall` otherwise).
export type LeaseClock = { now(): number; later(ms: number, f: () => void): () => void };
const WALL: LeaseClock = { now: () => wall.now(), later: (ms, f) => wall.after(ms, f) };

/// The Helper refused to unlock (`code`: its word), told to the agent as `message`.
export class UnlockRefused extends Error {
  readonly code: string;
  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

type Lease = { started: number; idleMs: number | null; stopIdle: () => void; stopTerm: () => void };

/// The leases on the locked screen, counted. The first opens `lockuse.begin` on a connection of its own, held while
/// any lease is: the Helper unlocks and answers one line, and locks again once it is closed (the last lease ended) or
/// lost (the station gone, stopped or restarted: nothing to tell it then). The Helper closing it ends every lease.
export class Leases {
  readonly #helper: LockHelper;
  readonly #clock: LeaseClock;
  readonly #leases = new Map<string, Lease>();
  /// The unlock asked for and not answered yet: takers meanwhile wait on it.
  #beginning: Promise<void> | null = null;
  /// The held `lockuse.begin` connection while unlocked.
  #line: LockLine | null = null;
  #n = 0;
  readonly #listeners = new Set<() => void>();

  constructor(o: { helper: LockHelper; clock?: LeaseClock }) {
    this.#helper = o.helper;
    this.#clock = o.clock ?? WALL;
  }

  /// Whether any lease is held (a person's view is refused meanwhile).
  held(): boolean {
    return this.#leases.size > 0;
  }

  holds(id: string): boolean {
    return this.#leases.has(id);
  }

  /// Told as the first lease is taken and the last ends.
  onChange(f: () => void): () => void {
    this.#listeners.add(f);
    return () => this.#listeners.delete(f);
  }

  /// A lease `id` for `reason`, ended after `idleMs` unused (null: only when released or at its term). Resolves once
  /// the screen is unlocked; throws UnlockRefused where the Helper says no.
  async take(id: string, reason: string, idleMs: number | null): Promise<void> {
    if (this.#leases.has(id)) return this.touch(id);
    if (this.#line === null) {
      this.#beginning ??= this.#begin(`L${++this.#n}`, reason).finally(() => (this.#beginning = null));
      await this.#beginning;
    }
    if (this.#leases.has(id)) return this.touch(id);
    const lease: Lease = { started: this.#clock.now(), idleMs, stopIdle: () => {}, stopTerm: () => {} };
    this.#leases.set(id, lease);
    this.#arm(id, lease);
    if (this.#leases.size === 1) this.#tell();
  }

  async #begin(lease: string, reason: string): Promise<void> {
    let line: LockLine;
    try {
      line = await this.#helper.connect({ op: "lockuse.begin", lease, reason });
    } catch (error) {
      throw new UnlockRefused("failed", beginRefusedText("failed", (error as Error).message));
    }
    const answer = await new Promise<any>((resolve) => {
      let got = "";
      let answered = false;
      line.setEncoding("utf8");
      line.on("data", (chunk: string) => {
        if (answered) return;
        got += chunk;
        const at = got.indexOf("\n");
        if (at < 0) return;
        answered = true;
        try {
          resolve(JSON.parse(got.slice(0, at)));
        } catch {
          resolve({ error: "an answer that is not JSON", code: "failed" });
        }
      });
      line.on("error", () => {});
      line.on("close", () => {
        if (!answered) return (answered = true), resolve({ error: "still.fail Helper closed the connection", code: "failed" });
        // The Helper ended it (it locked again: input seen, an error, it quit): every lease with it.
        if (this.#line === line) this.#ended("still.fail Helper ended it");
      });
    });
    if (answer?.ok !== true) {
      line.destroy();
      const code = typeof answer?.code === "string" ? answer.code : "failed";
      throw new UnlockRefused(code, beginRefusedText(code, typeof answer?.error === "string" ? answer.error : undefined));
    }
    this.#line = line;
    log.info("screens", "locked use began", { lease, reason });
  }

  /// Used now: its idle time starts again, its term runs TERM_MS from now (never past CAP_MS from its start).
  touch(id: string) {
    const lease = this.#leases.get(id);
    if (lease !== undefined) this.#arm(id, lease);
  }

  #arm(id: string, lease: Lease) {
    lease.stopIdle();
    lease.stopTerm();
    if (lease.idleMs !== null) lease.stopIdle = this.#clock.later(lease.idleMs, () => this.release(id));
    const left = Math.min(TERM_MS, lease.started + CAP_MS - this.#clock.now());
    lease.stopTerm = this.#clock.later(Math.max(0, left), () => this.release(id));
  }

  /// Lease `id` ends; with the last, the held connection closes and the Helper locks the screen again.
  release(id: string) {
    const lease = this.#leases.get(id);
    if (lease === undefined) return;
    lease.stopIdle();
    lease.stopTerm();
    this.#leases.delete(id);
    if (this.#leases.size === 0) this.#ended("its last lease ended");
  }

  /// Every lease ends and the connection closes (`why` for the log).
  #ended(why: string) {
    for (const lease of this.#leases.values()) lease.stopIdle(), lease.stopTerm();
    const had = this.#leases.size > 0 || this.#line !== null;
    this.#leases.clear();
    const line = this.#line;
    this.#line = null;
    line?.destroy();
    if (!had) return;
    log.info("screens", "locked use ended", { why });
    this.#tell();
  }

  #tell() {
    for (const f of [...this.#listeners]) f();
  }
}
