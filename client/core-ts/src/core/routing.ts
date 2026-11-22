// Topic routing and the values the core computes as they go out. Subscriptions only read what is
// held (rule 6): nothing here asks the network for anything; a topic with nothing held yet shows nothing (or why it
// cannot have anything), and fills in as the sync brings it.
import type { Inner } from "../core.ts";
import { CoreError } from "../error.ts";
import { t } from "../i18n.ts";
import { RECHECKING } from "../station/words.ts";
import { Loads } from "../preview-load.ts";
import * as status from "../status.ts";
import { topicKey, type Topic } from "../protocol.ts";
import { computed, untracked, type Derived } from "../reactive.ts";
import type { Source, Value, Watch } from "../store.ts";
import { timed } from "../spent.ts";

/// What a module that owns topics of its own plugs in (the station topics, the views, …).
export interface Owner {
  owns(topic: Topic): boolean;
  start?(topic: Topic): void;
  resume?(topic: Topic): void;
  idle?(topic: Topic): void;
  stop?(topic: Topic): void;
  compute?(topic: Topic): Value | undefined;
  waits?(topic: Topic): boolean;
  opened?(topic: Topic): void;
}

/// Whether two values `after` made of one are the same: each field the very same, a list's items each the very same
/// (what it puts in a chat: its unread line, the messages said and the agents started while it shows).
function sameSaid(a: Value | undefined, b: Value | undefined): boolean {
  if (a === undefined || b === undefined || !("ok" in a) || !("ok" in b)) return a === b;
  const [x, y] = [a.ok as Record<string, unknown>, b.ok as Record<string, unknown>];
  if (x === y) return true;
  if (typeof x !== "object" || typeof y !== "object" || x === null || y === null) return false;
  const keys = Object.keys(x);
  if (keys.length !== Object.keys(y).length) return false;
  return keys.every((k) => {
    const [u, w] = [x[k], y[k]];
    if (u === w) return true;
    return Array.isArray(u) && Array.isArray(w) && u.length === w.length && u.every((item, i) => item === w[i]);
  });
}

/// The topics a chat's page holds, named by its station and its thread (a chat's also by its session): where the chat
/// went to another station (views/moved.ts), each is its copy's there (`#movedTo`), the page's own topic all along.
const OF_A_CHAT = new Set(["chat", "thread", "letters", "chatLetters", "chatThings", "chatOutline", "chatJobs", "imageNear"]);

/// The prefix of the keys of chats asked for here and not made yet (views/local.ts PENDING_PREFIX): none moved.
const PENDING = "new:";

/// The topics named by a chat's session (`session`) that answer it only by the session its station made it under: a
/// chat a new chat's page became is named by the key it was sent under (`new:…`) all along, so once its station made it
/// each is that session's (`#madeTo`), the page's own topic all along. `chat` and what is made of it (`chatJobs`,
/// `imageNear`) follow the key themselves (views.ts `pendingThread`); a topic of `TOPICS` named by `session` is one of
/// the two (test/made-key.test.ts).
export const OF_A_SESSION = new Set(["chatRow", "chatFeedback"]);
export const SESSION_FOLLOWS_KEY = new Set(["chat", "chatJobs", "imageNear"]);

export class Router implements Source {
  readonly #core: Inner;
  readonly owners: Owner[] = [];
  /// What a topic's value goes through once computed (a chat as its UIs attend to it), and the topics it changes
  /// (`attends`): their value is made in a computed of their own (#made), apart from what `after` reads, so a UI's focus
  /// moving (`client.focus`, sent at every switch of workspace or chat, whatever it shows) puts the chat as it was made
  /// through `after` again, and does not make it again (3-6 ms in Hermes, twice as a switch of workspace committed onto
  /// a chat, 2026-11-11).
  after: (topic: Topic, value: Value | undefined) => Value | undefined = (_topic, value) => value;
  attends: (topic: Topic) => boolean = () => false;
  readonly #made = new Map<string, { value: Derived<Value | undefined>; said: { of: Value | undefined; out: Value | undefined } | undefined }>();
  /// What each topic of a chat that moved is shown of, held while it is (`#aim`): by the topic's key, the one there.
  readonly #aimed = new Map<string, { key: string; watch: Watch }>();

  constructor(core: Inner) {
    this.#core = core;
  }

  start(topic: Topic): void {
    const owner = this.owners.find((o) => o.owns(topic));
    if (owner?.start) timed(`${topic.topic}.start`, () => owner.start!(topic));
    // Computed when it goes out: its first value now.
    this.#core.store.invalidate(topic);
  }

  resume(topic: Topic): void {
    this.owners.find((o) => o.owns(topic))?.resume?.(topic);
  }

  idle(topic: Topic): void {
    this.owners.find((o) => o.owns(topic))?.idle?.(topic);
  }

  opened(topic: Topic): void {
    this.owners.find((o) => o.owns(topic))?.opened?.(topic);
  }

  stop(topic: Topic): void {
    this.#made.delete(topicKey(topic));
    this.#aim(topic, null);
    this.owners.find((o) => o.owns(topic))?.stop?.(topic);
  }

  waits(topic: Topic): boolean {
    return this.owners.find((o) => o.owns(topic))?.waits?.(topic) === true;
  }

  compute(topic: Topic): Value | undefined {
    const core = this.#core;
    switch (topic.topic) {
      case "accounts":
        return { ok: core.accounts.list() };
      case "workspaces":
        // What the accounts' `/v1/me` said, as held; nothing while no account's is.
        if (core.accounts.list().length > 0 && !core.accounts.list().some((a) => core.data.record("me", a.sub) !== undefined || core.cloudSync.mes.has(a.sub))) return undefined;
        return { ok: core.cloudSync.workspacesValue() };
      case "workspace": {
        const error = core.cloudSync.workspaceError(topic.workspace as string);
        return error ? { err: error } : undefined;
      }
      case "loginSessions":
      case "admin": {
        // An account signed out: nothing of it is shown any more.
        if (!core.accounts.list().some((a) => a.sub === topic.account)) return { err: CoreError.signedOut(t("core-logic.accounts.signed_out")) };
        const error = core.cloudSync.topicError(topic);
        return error ? { err: error } : undefined;
      }
      case "status":
        return { ok: this.statusValue(typeof topic.workspace === "string" ? topic.workspace : null) };
      case "doing": {
        // A write on a station that went quiet is being asked again: it says so.
        const rechecking = (params: Map<string, string>) => {
          const address = params.get("station");
          return address !== undefined && core.workspaces.ofStation(address).status.waits({ station: address }, RECHECKING());
        };
        return { ok: core.doing.value(rechecking) };
      }
      case "draft":
        return { ok: { text: "", quotes: [], files: [] } };
      case "composer":
        return { ok: core.composers.value(String(topic.key)) };
      case "adbShare":
        return { ok: core.adb.value() };
      case "adbCard":
        return { ok: core.adb.card(String(topic.station)) };
      case "rigs":
        return { ok: core.rigs.value(String(topic.workspace)) };
      case "devices":
        return { ok: core.devices.value(String(topic.workspace)) };
      case "previewLoad":
        return { ok: core.workspaces.ofStation(topic.station as string).part("previewLoad", () => new Loads()).value(topic) };
      case "prefs":
        return { ok: {} };
      case "drivePlace":
        return { ok: null };
    }
    // A chat's page's topic whose chat went to another station: its copy's there, nothing of the one it left.
    const moved = this.#movedTo(topic);
    const ofMade = moved === null ? this.#madeTo(topic) : null;
    this.#aim(topic, moved?.topic ?? ofMade);
    if (moved !== null) return this.after(topic, asHere(core.store.value(moved.topic), moved));
    if (ofMade !== null) return this.after(topic, core.store.value(ofMade));
    const owner = this.owners.find((o) => o.owns(topic));
    if (!this.attends(topic)) return this.after(topic, owner?.compute?.(topic));
    // (made in a computed of its own: what `after` alone reads, a UI's focus, puts it through again as it was made)
    const key = topicKey(topic);
    let made = this.#made.get(key);
    if (made === undefined) this.#made.set(key, (made = { value: computed(() => owner?.compute?.(topic)), said: undefined }));
    const value = made.value.get();
    const said = this.after(topic, value);
    // (and as it went through before where that made the same of it: the very value, which goes out as it did)
    if (made.said !== undefined && made.said.of === value && sameSaid(made.said.out, said)) return made.said.out;
    made.said = { of: value, out: said };
    return said;
  }

  /// Where a chat a page's topic names (OF_A_CHAT) is now, where its station said it went (data.ts chatNow): the same
  /// topic of its copy there, its thread here and there. Null where it did not go.
  #movedTo(topic: Topic): { topic: Topic; here: number | null; there: number | null } | null {
    if (!OF_A_CHAT.has(topic.topic) || typeof topic.station !== "string") return null;
    const data = this.#core.data;
    if (typeof topic.thread === "number") {
      const now = data.chatNow(topic.station, { thread: topic.thread });
      return now === null || now.thread === null ? null : { topic: { ...topic, station: now.station, thread: now.thread }, here: topic.thread, there: now.thread };
    }
    const session = topic.topic === "chat" && typeof topic.session === "string" && !topic.session.startsWith(PENDING) ? topic.session : null;
    if (session === null) return null;
    const now = data.chatNow(topic.station, { session });
    if (now === null) return null;
    const there: Topic = now.thread !== null ? { ...topic, station: now.station, thread: now.thread, session: null } : { ...topic, station: now.station };
    return { topic: there, here: data.moved(topic.station, session)?.thread ?? null, there: now.thread };
  }

  /// The same topic of the session its station made a chat under, where `topic` names it by the key it was asked for
  /// here by (OF_A_SESSION); null where it names none so, or that chat is not made yet.
  #madeTo(topic: Topic): Topic | null {
    if (!OF_A_SESSION.has(topic.topic) || typeof topic.station !== "string" || typeof topic.session !== "string" || !topic.session.startsWith(PENDING)) return null;
    const pending = this.#core.views.local.pending(topic.session);
    return pending?.station === topic.station && pending.made !== null ? { ...topic, session: pending.made[0] } : null;
  }

  /// The topic a moved one is shown of held while it is (`target`; null: none), so the sync keeps it current.
  #aim(topic: Topic, target: Topic | null): void {
    const key = topicKey(topic);
    const was = this.#aimed.get(key);
    const to = target === null ? null : topicKey(target);
    if (was?.key === to) return;
    untracked(() => {
      if (was !== undefined) {
        this.#aimed.delete(key);
        was.watch.drop();
      }
      if (target !== null && to !== null) this.#aimed.set(key, { key: to, watch: this.#core.store.watch(target, () => {}) });
    });
  }

  /// What is waited on: of a workspace, its own waits, its account's socket and the relay opened for no station; of
  /// none, every workspace's and all the device's, each station said with its workspace's name when there are several
  /// (one station may be in several workspaces).
  statusValue(workspace: string | null): unknown {
    const core = this.#core;
    if (workspace !== null) {
      const of = core.workspaces.of(workspace);
      return status.value([
        [of.status, "all"],
        [core.status, { for: of.owner !== null ? [of.owner] : [] }],
      ]);
    }
    const all = core.workspaces.all();
    const parts: [status.Status, status.Take, string | null][] = all.map((w) => [w.status, "all", all.length > 1 ? (core.cloudSync.workspaceName(w.id) ?? w.id) : null]);
    parts.push([core.status, "all", null]);
    return status.value(parts);
  }
}

/// A moved chat's topic's value as its copy there has it, its thread named as the page names it (what it sends is aimed
/// there: views/moved.ts `aimed`).
function asHere(value: Value | undefined, moved: { here: number | null; there: number | null }): Value | undefined {
  if (value === undefined || !("ok" in value) || moved.here === null) return value;
  const v = value.ok as Record<string, unknown> | null;
  const thread = v !== null && typeof v === "object" ? (v.thread as Record<string, unknown> | undefined) : undefined;
  if (thread === null || typeof thread !== "object" || thread.id !== moved.there) return value;
  return { ok: { ...v, thread: { ...thread, id: moved.here } } };
}
