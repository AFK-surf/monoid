// What the core keeps in sync with still.fail cloud (or the account provider in its place: account-provider.ts), by
// itself, whatever the UI shows (rule 6): each signed-in account's `/v1/events` socket, held for as long as the account is signed in; its `/v1/me` (whom it
// reaches), each workspace it reaches, its signed-in devices, and an operator's lists. The topics that show them only
// read the records (data.ts). Every time a socket opens, the account is read again (nothing is replayed); its events
// say what changed. A write to still.fail cloud answers once what it changed is read again.
import { SignalMap } from "../reactive.ts";
import { record, said } from "../record.ts";
import { Deferred, Effect, Exit, Fiber, Scope, Semaphore } from "effect";
import type { AccountView } from "../accounts.ts";
import { NOT_BETA, cloudError, notBetaText, readCredential, type Credential } from "../cloud.ts";
import { CREDENTIAL_429_COOLDOWN_MS, CREDENTIAL_ASK_CONCURRENCY, CREDENTIAL_FOR_S, CREDENTIAL_KEY, CREDENTIAL_OTHERS, CREDENTIAL_OTHERS_KEPT, entriesOf, entryTargetsOf, PUSH_KEY, relaysOf, type Inner } from "../core.ts";
import type { AccountDb } from "../db/account.ts";
import { CoreError, asCoreError } from "../error.ts";
import { HostError, type Pull } from "../host.ts";
import { current, t } from "../i18n.ts";
import { encode } from "../ops.ts";
import { topicKey, type Topic } from "../protocol.ts";
import { CLOUD } from "../status.ts";
import { GONE, NETWORK } from "../wake.ts";
import { equal, isObject, parseJson, pointer, toJsonBytes } from "../util.ts";
import { CARRY_BYTES, type LockClaim } from "../lock.ts";
import * as prefs from "../prefs.ts";
import { Priority } from "./scheduler.ts";
import { keptMarks, overlaid } from "../station-marks-kept.ts";

/// The first wait before an events socket is opened again; it doubles up to a minute, back to the first after one
/// held a minute.
export const SOCKET_RETRY_MS = 1_000;
/// How long a read the cloud turned away for too many asks (429) waits to be asked again.
export const LIMITED_MS = 10_000;
export const SOCKET_RETRY_MAX_MS = 60_000;
/// An events socket that heard nothing this long is opened again, including before its first heartbeat.
export const SOCKET_IDLE_MS = 2 * 25_000 + 10_000;
export { EVENTS_PROTOCOL } from "../account-provider.ts";
/// still.fail cloud's operator lists.
export const ADMIN_LISTS = ["users", "workspaces", "invite-codes", "feedback"];

/// Which of an operator's lists a write to `/v1/admin/<at>` changes (its relays are read apart): a report's status its
/// reports; a code its codes; someone pending, or one's leave to make workspaces, the users and the workspaces (it is
/// given at once to one signed in, and so the plan of what they made); another user's mark the users; a workspace made,
/// deleted or changed the workspaces and the users (who is in which). A path not known here reads them all.
export function adminListsForWrite(at: string): string[] {
  if (at === "/v1/admin/me") return [];
  if (at.startsWith("/v1/admin/keys")) return [];
  if (at.startsWith("/v1/admin/feedback")) return ["feedback"];
  if (at.startsWith("/v1/admin/invite-codes")) return ["invite-codes"];
  if (at.startsWith("/v1/admin/pending")) return ["users", "workspaces"];
  if (at.startsWith("/v1/admin/users/")) return at.endsWith("/may-create") ? ["users", "workspaces"] : ["users"];
  if (at.startsWith("/v1/admin/workspaces")) return ["workspaces", "users"];
  return ADMIN_LISTS;
}

export class CloudSync {
  readonly #core: Inner;
  /// Whether each account's latest `/v1/me` answered this run (null), or why it failed.
  readonly mes = new SignalMap<string, CoreError | null>();
  /// Told each time an account's events socket opens (what else is read again then).
  onOpen: () => void = () => {};
  /// What a workspace read last failed with, while nothing is held of it.
  readonly errors = new SignalMap<string, CoreError>();
  /// Each account's socket and the persistent session ID it was opened for, while it is signed in.
  readonly #sockets = new Map<string, { fiber: Fiber.Fiber<void, never>; sid: string }>();
  /// The relays the mesh uses, as the first `/v1/me` of this run or the kept one said.
  relays: string[] | null = null;
  /// The account whose cloud supplied this run's relays; a later refresh from it may update the entrances.
  #relaySource: string | null = null;
  /// Told when the source account's `/v1/me` names relays and entrances (the mesh may be up on those kept from the last).
  onRelays: ((relays: string[], entries: string[], targets: Record<string, string>) => void) | null = null;
  /// Told when the stations each account reaches may have changed (the station sync follows).
  onReach: (() => void) | null = null;
  /// Told when still.fail cloud says a release is out (asks.ts reads the newest again when next asked).
  onRelease: () => void = () => {};
  /// Told when still.fail cloud says it sampled its relays, to an operator's account (sync/admin-relays.ts).
  onRelayLoad: (sub: string) => void = () => {};
  /// Told when an operator's list read only while shown changed (`audit`; `feedback/`, a report's own): sync/admin-relays.ts.
  onAdminSubList: (sub: string, prefix: string) => void = () => {};
  /// Asked to open deferred account database(s) on demand when a workspace's owner is not yet resolved or verified
  /// against earlier deferred accounts in sign-in order.
  onNeedDeferred: ((workspace: string, beforeSub?: string | null, includeTarget?: boolean) => Effect.Effect<void>) | null = null;
  /// The lock entries a hello to a station of the workspace brings (views/lock.ts `carried`): none, null.
  carry: ((workspace: string) => import("../lock.ts").Entry[] | null) | null = null;
  /// The chain of the person's own lock a hello brings to a station (views/lock.ts `carriedPerson`).
  carryPerson: ((workspace: string) => import("../lock.ts").Entry[] | null) | null = null;
  /// Whose operator lists are synced (as `admin.me` answered).
  readonly #admins = new Set<string>();
  /// An operator's lists that failed to come (the network, still.fail cloud's 5xx): the wait before they are asked
  /// again, by account, and the retry waiting.
  readonly #adminRetry = new Map<string, { ms: number; fiber: Fiber.Fiber<unknown, unknown> | null }>();
  /// A workspace's view to read again, the cloud having turned it away for too many asks.
  readonly #workspaceRetry = new Map<string, Fiber.Fiber<unknown, unknown>>();
  /// A credential asked of the cloud and not answered yet, by device and key (`#credential`): what every dial of the
  /// device that wants it meanwhile waits on, renewed or not.
  readonly #asking = new Map<string, Deferred.Deferred<Credential, CoreError>>();
  /// One write at a time of a workspace's kept credentials, by key (`credential/<account>/<workspace>`): the other
  /// endpoints' are one list, read, changed and written back, so two answered together each wrote it without the other's.
  readonly #keeping = new Map<string, ReturnType<typeof Semaphore.makeUnsafe>>();
  /// How many times a workspace's kept credentials were removed (an account signed out), by key: an ask answered after
  /// keeps nothing.
  readonly #removed = new Map<string, number>();
  /// Monotonic generation bumped whenever a fresh credential is saved to a specific storage key, so a stale queued
  /// delete never overwrites a credential saved after re-sign-in.
  readonly #credSaved = new Map<string, number>();
  /// Workspaces whose initial or live workspace/feedback sync was deferred while an earlier account DB was still
  /// unopened or unreadable; re-dispatched in `recomputeOwners` once verified ownership is established.
  readonly #deferredWorkspaceSync = new Set<string>();
  /// Authoritative full-read baseline `(owner, authGen)` per workspace; delta patches require an exact match.
  readonly #confirmedBase = new Map<string, { owner: string; gen: number }>();
  readonly #deferredFeedbackSync = new Set<string>();
  /// Authoritative `/v1/me` payloads (or `null` for `NOT_BETA` rejection) held in memory by `(sub, loginGen, sessionId)`
  /// when an account has no writable DB or its DB write has not yet been confirmed committed on disk. Always takes
  /// precedence over stale disk rows in `#meOf(sub)` and is cleared only after `db.written` confirms persistence.
  readonly #liveMe = new Map<string, { gen: number; sid: string; me: unknown | null }>();
  /// Accounts currently running `#persistLiveMe` (prevents re-entrant retries during the same commit settlement).
  readonly #persistingLiveMe = new Set<string>();
  /// Accounts whose `pendingMe` entry was cleared (persisted to disk DB or signed out) while `device/choice` was
  /// still unloaded; pruned once `device/choice` reloads so stale disk `pendingMe` never overwrites fresher state.
  readonly #pendingMeCleared = new Set<string>();
  /// Accounts signed out while `device/choice` was unloaded, mapping `sub` -> snapshot of `#credSaved` counters for
  /// `credential/<sub>/*` at sign-out time so reload/close can collect historical `credWorkspaces`/`pendingMe`
  /// deletes without touching credentials freshly saved after a later re-login.
  readonly #signedOutWhileChoiceUnloaded = new Map<string, Map<string, number>>();
  /// `(gen, sid)` at which `sub` already persisted an authoritative `/v1/me` (or `NOT_BETA`) to a persistent DB
  /// in this run (retained even if a later refresh hits a transient 503).
  readonly #persistedMe = new Map<string, { gen: number; sid: string }>();
  /// Ensures `#onChoiceLoaded()` runs at most once after `device/choice` finishes loading.
  #choiceHydrated = false;
  /// Active `ensureVerifiedOwners()` calls that started while `device/choice` was unloaded and still need
  /// `device.choiceRecovery()` for post-reload verification; snapshot is released once this drops back to 0.
  #choiceReloadWaiters = 0;
  /// `(gen, sid)` at which `sub` received `NOT_BETA` (preserved independently of `this.mes`, so a subsequent
  /// transient 503 never causes a `NOT_BETA`-rejected account without a DB to re-block other accounts).
  readonly #notBeta = new Map<string, { gen: number; sid: string }>();
  /// Persistent session ID that last set `this.mes.get(sub)`.
  readonly #mesSid = new Map<string, string>();
  /// Persistent session ID that last saved each credential storage key in this run.
  readonly #credSavedSession = new Map<string, string>();
  /// Accounts that underwent in-place session replacement whose old-session workspace list could not yet be fully
  /// enumerated (e.g. SQLite read error or unloaded `device/choice`); blocks legacy (no-session) credential hits
  /// and retries cleanup once readable.
  readonly #replacedUnverified = new Map<string, string>();
  /// An account's credential asks out at once, by account (`CREDENTIAL_ASK_CONCURRENCY`).
  readonly #askTurn = new Map<string, ReturnType<typeof Semaphore.makeUnsafe>>();
  /// Until when (ms) an account asks no credential, the cloud having refused one for too many (`CREDENTIAL_429_COOLDOWN_MS`).
  readonly #credentialBackoff = new Map<string, number>();
  /// Last observed persistent session ID per account sub so in-place re-login (same sub, new session) is detected
  /// even when `AccountView` fields are identical.
  readonly #shownSessions = new Map<string, string>();
  /// Workspace id currently applying a full authoritative `GET /v1/workspaces/<id>` response in `#took`.
  #takingFullRead: string | null = null;

  constructor(core: Inner) {
    this.#core = core;
  }

  /// Starts keeping still.fail cloud's data current: whom each account reaches, from what is held first.
  start(): void {
    for (const a of this.#core.accounts.list()) {
      this.#shownSessions.set(a.sub, this.#core.accounts.sessionId(a.sub));
    }
    // Register Runner-owned reload hook so even if every caller waiting on `device.reload("choice")` is interrupted,
    // the background reload still runs `#onChoiceLoaded()` (hydrate -> recompute -> drain) to completion.
    this.#core.data.device.onTableReloaded = (table) => {
      if (table === "choice") this.#onChoiceLoaded();
    };
    if (!this.#core.data.device.isUnloaded("choice")) {
      this.#onChoiceLoaded();
    } else {
      this.recomputeOwners();
    }
    // Each account's socket reads the account as it opens (or, failing its first try, at once).
    this.syncSockets();
  }

  #baseCredKey(storageKey: string): string {
    const suffix = `/${CREDENTIAL_OTHERS}`;
    return storageKey.endsWith(suffix) ? storageKey.slice(0, -suffix.length) : storageKey;
  }

  #readPendingCredentialDeletes(): string[] {
    const raw = this.#core.data.device.get("choice", "pendingCredentialDeletes");
    return Array.isArray(raw) ? raw.filter((k): k is string => typeof k === "string" && k.length > 0) : [];
  }

  #isPendingCredentialDelete(storageKey: string): boolean {
    return this.#readPendingCredentialDeletes().includes(storageKey);
  }

  #addPendingCredentialDeletes(keys: readonly string[]): void {
    if (keys.length === 0) return;
    const prev = this.#readPendingCredentialDeletes();
    const next = [...new Set([...prev, ...keys])];
    if (next.length !== prev.length) this.#core.data.device.put("choice", "pendingCredentialDeletes", next);
  }

  #removePendingCredentialDelete(key: string): void {
    const prev = this.#readPendingCredentialDeletes();
    if (!prev.includes(key)) return;
    const next = prev.filter((k) => k !== key);
    this.#core.data.device.put("choice", "pendingCredentialDeletes", next.length > 0 ? next : undefined);
  }

  /// Retries any credential storage deletes persisted before/during an earlier sign-out.
  /// Serialized per credential key alongside fresh writes and removes only individually confirmed keys.
  #drainPendingCredentialDeletes(): void {
    const core = this.#core;
    const keys = this.#readPendingCredentialDeletes();
    if (keys.length === 0) return;
    const byBase = new Map<string, Array<[string, number]>>();
    for (const k of keys) {
      const base = this.#baseCredKey(k);
      let list = byBase.get(base);
      if (!list) byBase.set(base, (list = []));
      list.push([k, this.#credSaved.get(k) ?? 0]);
    }
    for (const [base, list] of byBase) {
      core.runner.fork(
        this.#keepingOf(base).withPermits(1)(
          Effect.gen({ self: this }, function* () {
            for (const [k, savedAt] of list) {
              if ((this.#credSaved.get(k) ?? 0) !== savedAt) continue;
              const r = yield* Effect.result(core.host.storageDelete(k));
              if (r._tag === "Success") this.#removePendingCredentialDelete(k);
            }
          }),
        ),
      );
    }
  }

  #isNotBeta(sub: string): boolean {
    const e = this.#notBeta.get(sub);
    return e !== undefined && e.gen === this.#core.data.accountGen(sub) && e.sid === this.#core.accounts.sessionId(sub);
  }

  #hasPersistedMe(sub: string): boolean {
    const e = this.#persistedMe.get(sub);
    return e !== undefined && e.gen === this.#core.data.accountGen(sub) && e.sid === this.#core.accounts.sessionId(sub);
  }

  #hasLiveMe(sub: string): boolean {
    const live = this.#liveMe.get(sub);
    return live !== undefined && live.gen === this.#core.data.accountGen(sub) && live.sid === this.#core.accounts.sessionId(sub);
  }

  /// Latest known `/v1/me` payload for `sub`: prefers same-generation, same-session in-memory authoritative `/v1/me`
  /// (including `null` tombstone for `NOT_BETA`) without querying SQLite, while always registering the reactive
  /// `$account-record/me` dependency so live `workspaces` subscriptions stay current even if disk SELECT fails.
  #meOf(sub: string): unknown {
    const core = this.#core;
    const live = this.#liveMe.get(sub);
    if (live !== undefined && live.gen === core.data.accountGen(sub) && live.sid === core.accounts.sessionId(sub)) {
      core.data.trackAccountRecord(sub, "me");
      return live.me === null ? undefined : live.me;
    }
    return core.data.record("me", sub);
  }

  #rememberWorkspacesOf(sub: string, me: unknown): void {
    if (!isObject(me) || !Array.isArray(me.workspaces)) return;
    for (const w of me.workspaces) {
      if (isObject(w) && typeof w.id === "string" && w.id.length > 0) {
        this.#rememberCredentialWorkspace(sub, w.id);
      }
    }
  }

  #readPendingMe(): Record<string, unknown | null> {
    const raw = this.#core.data.device.get("choice", "pendingMe");
    if (!isObject(raw)) return {};
    return { ...(raw as Record<string, unknown | null>) };
  }

  #readSessionMap(key: "pendingMeSessions" | "accountSessions"): Record<string, string> {
    const raw = this.#core.data.device.get("choice", key);
    if (!isObject(raw)) return {};
    const out: Record<string, string> = {};
    for (const [sub, v] of Object.entries(raw)) {
      if (typeof v === "string" && v.length > 0) out[sub] = v;
    }
    return out;
  }

  #recordAccountSession(sub: string): void {
    const core = this.#core;
    if (core.accounts.isUnloaded() || core.data.device.isUnloaded("choice") || this.#replacedUnverified.has(sub)) return;
    const sid = core.accounts.sessionId(sub);
    const sessions = this.#readSessionMap("accountSessions");
    if (sid.length > 0) {
      if (sessions[sub] === sid) return;
      sessions[sub] = sid;
      core.data.device.put("choice", "accountSessions", sessions);
    } else if (Object.prototype.hasOwnProperty.call(sessions, sub)) {
      delete sessions[sub];
      core.data.device.put("choice", "accountSessions", Object.keys(sessions).length > 0 ? sessions : undefined);
    }
  }

  #savePendingMe(sub: string, me: unknown | null): void {
    this.#pendingMeCleared.delete(sub);
    const sid = this.#core.accounts.sessionId(sub);
    const next = this.#readPendingMe();
    const sessions = this.#readSessionMap("pendingMeSessions");
    const sameMe = Object.prototype.hasOwnProperty.call(next, sub) && equal(next[sub], me);
    const sameSid = (sessions[sub] ?? "") === sid;
    if (sameMe && sameSid) return;
    next[sub] = me;
    this.#core.data.device.put("choice", "pendingMe", next);
    if (sid.length > 0 || Object.prototype.hasOwnProperty.call(sessions, sub)) {
      if (sid.length > 0) sessions[sub] = sid;
      else delete sessions[sub];
      this.#core.data.device.put("choice", "pendingMeSessions", Object.keys(sessions).length > 0 ? sessions : undefined);
    }
  }

  #clearPendingMe(sub: string): void {
    if (this.#core.data.device.isUnloaded("choice")) {
      this.#pendingMeCleared.add(sub);
    }
    const next = this.#readPendingMe();
    if (Object.prototype.hasOwnProperty.call(next, sub)) {
      delete next[sub];
      this.#core.data.device.put("choice", "pendingMe", Object.keys(next).length > 0 ? next : undefined);
    }
    const sessions = this.#readSessionMap("pendingMeSessions");
    if (Object.prototype.hasOwnProperty.call(sessions, sub)) {
      delete sessions[sub];
      this.#core.data.device.put("choice", "pendingMeSessions", Object.keys(sessions).length > 0 ? sessions : undefined);
    }
  }

  #syncAccountSessions(): void {
    const core = this.#core;
    if (core.accounts.isUnloaded() || core.data.device.isUnloaded("choice")) return;
    const sessions = this.#readSessionMap("accountSessions");
    let changed = false;
    const subs = new Set<string>();
    for (const a of core.accounts.list()) {
      subs.add(a.sub);
      if (this.#replacedUnverified.has(a.sub)) continue;
      const sid = core.accounts.sessionId(a.sub);
      if (sid.length > 0) {
        if (sessions[a.sub] !== sid) {
          sessions[a.sub] = sid;
          changed = true;
        }
      } else if (Object.prototype.hasOwnProperty.call(sessions, a.sub)) {
        delete sessions[a.sub];
        changed = true;
      }
    }
    for (const sub of Object.keys(sessions)) {
      if (!subs.has(sub)) {
        delete sessions[sub];
        changed = true;
      }
    }
    if (changed) {
      core.data.device.put("choice", "accountSessions", Object.keys(sessions).length > 0 ? sessions : undefined);
    }
  }

  /// Hydrates any authoritative `/v1/me` (or `NOT_BETA` tombstone) persisted in device storage when an earlier run
  /// closed while an account had no writable DB, ensuring offline restarts never revert to stale disk rows.
  /// Never overwrites accounts that already received a fresher authoritative `/v1/me`, cleared `pendingMe`, or
  /// re-logged in with a different persistent session ID; never prunes entries while `accounts` failed to load.
  #hydratePendingMe(): void {
    const core = this.#core;
    const raw = this.#readPendingMe();
    const pendingSessions = this.#readSessionMap("pendingMeSessions");
    const entries = Object.entries(raw);
    if (entries.length === 0) {
      this.#pendingMeCleared.clear();
      this.#syncAccountSessions();
      return;
    }
    const accountsUnloaded = core.accounts.isUnloaded();
    const subs = new Set(core.accounts.list().map((a) => a.sub));
    let pruned = false;
    let sessionsChanged = false;
    for (const [sub, me] of entries) {
      const signedIn = subs.has(sub);
      if ((!signedIn && !accountsUnloaded) || this.#pendingMeCleared.has(sub)) {
        delete raw[sub];
        pruned = true;
        if (Object.prototype.hasOwnProperty.call(pendingSessions, sub)) {
          delete pendingSessions[sub];
          sessionsChanged = true;
        }
        continue;
      }
      if (!signedIn) continue;
      const curSid = core.accounts.sessionId(sub);
      const entrySid = pendingSessions[sub] ?? "";
      if (entrySid !== curSid) {
        // Stale pendingMe from an earlier login session before sign-out -> re-login: drop it!
        delete raw[sub];
        pruned = true;
        if (Object.prototype.hasOwnProperty.call(pendingSessions, sub)) {
          delete pendingSessions[sub];
          sessionsChanged = true;
        }
        continue;
      }
      const gen = core.data.accountGen(sub);
      const existingLive = this.#liveMe.get(sub);
      if (existingLive !== undefined && existingLive.gen === gen && existingLive.sid === curSid) {
        // Current run already holds a fresher in-memory authoritative result for this generation & session:
        // advance stale disk `pendingMe` to the fresher payload rather than keeping an older value.
        if (!equal(raw[sub], existingLive.me)) {
          raw[sub] = existingLive.me;
          pruned = true;
        }
        continue;
      }
      if ((this.mes.get(sub) === null && this.#mesSid.get(sub) === curSid) || this.#hasPersistedMe(sub) || this.#isNotBeta(sub)) {
        // Current run already received and persisted an authoritative `/v1/me` (or `NOT_BETA`) for this generation:
        // drop the stale disk `pendingMe` entry rather than reverting SQLite!
        delete raw[sub];
        pruned = true;
        if (Object.prototype.hasOwnProperty.call(pendingSessions, sub)) {
          delete pendingSessions[sub];
          sessionsChanged = true;
        }
        continue;
      }
      const entry = { gen, sid: curSid, me };
      this.#liveMe.set(sub, entry);
      if (me === null) this.#notBeta.set(sub, { gen, sid: curSid });
      const db = core.data.db(sub);
      if (db && !db.readOnly) this.#persistLiveMe(sub, db, entry);
    }
    this.#pendingMeCleared.clear();
    if (pruned) {
      core.data.device.put("choice", "pendingMe", Object.keys(raw).length > 0 ? raw : undefined);
    }
    if (sessionsChanged) {
      core.data.device.put("choice", "pendingMeSessions", Object.keys(pendingSessions).length > 0 ? pendingSessions : undefined);
    }
    this.#syncAccountSessions();
  }

  /// Collects historical workspace credentials from the compact pre-merge `device/choice` recovery snapshot (and
  /// current device table for accounts still signed out) for:
  /// 1. accounts signed out during this run while `device/choice` was unloaded (preserving credentials freshly saved
  ///    after a later re-login via `#credSaved`),
  /// 2. orphaned signed-out accounts remaining in `device/choice` from a previous run whose `Core.close()` failed
  ///    while `device/choice` was unreadable (ONLY when `accounts` loaded cleanly, never when `accounts.isUnloaded()`),
  /// 3. signed-in accounts whose persistent `sessionId(sub)` differs from `device/choice`'s recorded session ID
  ///    (cross-process sign-out -> re-login across any number of failed closes).
  #collectSignedOutUnloadedDeletes(): Array<[string, number]> {
    const core = this.#core;
    const device = core.data.device;
    const recovery = device.choiceRecovery();
    const diskPendingMe = recovery?.pendingMe ?? null;
    const diskPendingMeSessions = recovery?.pendingMeSessions ?? null;
    const diskAccountSessions = recovery?.accountSessions ?? null;
    const diskOwners = recovery?.workspaceOwners ?? null;
    const diskCredWorkspaces = recovery?.credWorkspaces ?? null;
    const curPendingMe = this.#readPendingMe();
    const curOwners = device.get("choice", "workspaceOwners");
    const accountsUnloaded = core.accounts.isUnloaded();
    const signedInSubs = new Set(core.accounts.list().map((a) => a.sub));

    const targets = new Map<string, Map<string, number>>(this.#signedOutWhileChoiceUnloaded);
    if (!accountsUnloaded) {
      const noteOrphan = (sub: string) => {
        if (sub.length > 0 && !signedInSubs.has(sub) && !targets.has(sub)) {
          targets.set(sub, new Map<string, number>());
        }
      };
      if (diskCredWorkspaces) for (const sub of diskCredWorkspaces.keys()) noteOrphan(sub);
      for (const k of device.keys("choice")) {
        if (k.startsWith("credWorkspaces/")) noteOrphan(k.slice("credWorkspaces/".length));
      }
      if (diskPendingMe) for (const sub of Object.keys(diskPendingMe)) noteOrphan(sub);
      for (const sub of Object.keys(curPendingMe)) noteOrphan(sub);
      if (diskOwners) for (const owner of Object.values(diskOwners)) if (typeof owner === "string") noteOrphan(owner);
      if (isObject(curOwners)) for (const owner of Object.values(curOwners)) if (typeof owner === "string") noteOrphan(owner);

      // Cross-process re-login detection: signed-in account's persistent session ID differs from disk choice's.
      for (const a of core.accounts.list()) {
        const sub = a.sub;
        const curSid = core.accounts.sessionId(sub);
        if (targets.has(sub)) continue;
        const hasDiskCreds = (diskCredWorkspaces?.get(sub)?.length ?? 0) > 0;
        const hasDiskPending = diskPendingMe !== null && Object.prototype.hasOwnProperty.call(diskPendingMe, sub);
        const hasDiskOwned = diskOwners !== null && Object.values(diskOwners).includes(sub);
        const recordedAccountSid = diskAccountSessions?.[sub] ?? "";
        const recordedPendingSid = diskPendingMeSessions?.[sub] ?? "";
        if (
          (hasDiskPending && recordedPendingSid !== curSid)
          || ((hasDiskCreds || hasDiskOwned) && recordedAccountSid !== curSid)
        ) {
          targets.set(sub, new Map<string, number>());
        }
      }
    }

    if (targets.size === 0) return [];

    const addFromMe = (wsIds: Set<string>, me: unknown) => {
      if (isObject(me) && Array.isArray(me.workspaces)) {
        for (const w of me.workspaces) {
          if (isObject(w) && typeof w.id === "string" && w.id.length > 0) wsIds.add(w.id);
        }
      }
    };
    const addFromList = (wsIds: Set<string>, raw: unknown) => {
      if (Array.isArray(raw)) {
        for (const w of raw) if (typeof w === "string" && w.length > 0) wsIds.add(w);
      }
    };
    const addFromOwners = (wsIds: Set<string>, owners: unknown, sub: string) => {
      if (isObject(owners)) {
        for (const [ws, owner] of Object.entries(owners)) {
          if (owner === sub) wsIds.add(ws);
        }
      }
    };

    const queued: Array<[string, number]> = [];
    const keysToQueue: string[] = [];
    for (const [sub, savedAtSignOut] of targets) {
      const wsIds = new Set<string>();
      const stillSignedOut = !signedInSubs.has(sub);
      // Always read pre-merge disk snapshot first so a re-login's new pendingMe/credWorkspaces never masks old workspaces.
      if (diskCredWorkspaces) addFromList(wsIds, diskCredWorkspaces.get(sub));
      if (diskPendingMe) addFromMe(wsIds, diskPendingMe[sub]);
      addFromOwners(wsIds, diskOwners, sub);
      // Also inspect current merged table when the account is still signed out (catches anything remembered before sign-out).
      if (stillSignedOut) {
        addFromList(wsIds, device.get("choice", `credWorkspaces/${sub}`));
        addFromMe(wsIds, curPendingMe[sub]);
        addFromOwners(wsIds, curOwners, sub);
      }
      const curIndexedRaw = device.get("choice", `credWorkspaces/${sub}`);
      const curIndexed = Array.isArray(curIndexedRaw) ? curIndexedRaw.filter((v): v is string => typeof v === "string" && v.length > 0) : [];
      const keptWs = new Set<string>();
      if (!stillSignedOut) {
        // Preserve workspaces freshly remembered after re-login that were not in the pre-sign-out set.
        for (const w of curIndexed) if (!wsIds.has(w)) keptWs.add(w);
      }
      for (const ws of wsIds) {
        const key = `${CREDENTIAL_KEY}/${sub}/${ws}`;
        const othersKey = `${key}/${CREDENTIAL_OTHERS}`;
        const keySavedAfter = (this.#credSaved.get(key) ?? 0) !== (savedAtSignOut.get(key) ?? 0);
        const othersSavedAfter = (this.#credSaved.get(othersKey) ?? 0) !== (savedAtSignOut.get(othersKey) ?? 0);
        if (!stillSignedOut && (keySavedAfter || othersSavedAfter)) {
          keptWs.add(ws);
        }
        if (!othersSavedAfter) {
          const savedAt = savedAtSignOut.get(othersKey) ?? 0;
          keysToQueue.push(othersKey);
          queued.push([othersKey, savedAt]);
        }
        if (!keySavedAfter) {
          const savedAt = savedAtSignOut.get(key) ?? 0;
          this.#removed.set(key, (this.#removed.get(key) ?? 0) + 1);
          keysToQueue.push(key);
          queued.push([key, savedAt]);
        }
      }
      device.put("choice", `credWorkspaces/${sub}`, keptWs.size > 0 ? [...keptWs] : undefined);
    }
    this.#signedOutWhileChoiceUnloaded.clear();
    this.#addPendingCredentialDeletes(keysToQueue);
    return queued;
  }

  /// Resolves the exact pre-wait effective owner of `workspace` in sign-in order (`preReloadOrder`), combining
  /// the pre-merge disk `device/choice` recovery snapshot (`pendingMe`, `workspaceOwners`) with `preLocalHolders`.
  /// Distinguishes the true pre-wait owner from lower-priority secondary members (so signing out a lower-priority
  /// member does not cancel the primary owner's edit, while a disk-backed owner losing membership or signing out does).
  #effectivePreHolder(
    workspace: string,
    preReloadOrder: readonly string[],
    preLocalHolders: ReadonlySet<string>,
    preSupersededPendingMe: ReadonlySet<string>,
    preSessions: ReadonlyMap<string, string>,
  ): string | null {
    const recovery = this.#core.data.device.choiceRecovery();
    const diskPendingMe = recovery?.pendingMe ?? null;
    const diskPendingMeSessions = recovery?.pendingMeSessions ?? null;
    const diskAccountSessions = recovery?.accountSessions ?? null;
    const diskOwners = recovery?.workspaceOwners ?? null;
    for (const sub of preReloadOrder) {
      if (diskPendingMe !== null && Object.prototype.hasOwnProperty.call(diskPendingMe, sub) && !preSupersededPendingMe.has(sub)) {
        const entrySid = diskPendingMeSessions?.[sub] ?? "";
        const subSid = preSessions.get(sub) ?? "";
        if (entrySid === subSid) {
          const me = diskPendingMe[sub];
          if (isObject(me) && Array.isArray(me.workspaces) && me.workspaces.some((w) => isObject(w) && w.id === workspace)) {
            return sub;
          }
          continue;
        }
      }
      if (preLocalHolders.has(sub)) return sub;
    }
    if (diskOwners !== null && typeof diskOwners[workspace] === "string" && diskOwners[workspace].length > 0) {
      const cached = diskOwners[workspace];
      if (preReloadOrder.includes(cached) && (diskAccountSessions?.[cached] ?? "") === (preSessions.get(cached) ?? "")) {
        return cached;
      }
    }
    return null;
  }

  /// Runs all recovery actions AT MOST ONCE once BOTH `accounts` and `device/choice` have loaded:
  /// collect deferred/orphan/re-login sign-out credential deletes, hydrate unpersisted `pendingMe`,
  /// recompute workspace ownership, drain queued credential deletes, and release recovery snapshot if no waiters remain.
  #onChoiceLoaded(): void {
    const core = this.#core;
    if (this.#choiceHydrated || core.data.device.isUnloaded("choice")) return;
    if (core.accounts.isUnloaded()) {
      // Defer full hydration & orphan cleanup until `accounts` finishes loading (or Comma confirms identity).
      this.recomputeOwners();
      return;
    }
    this.#choiceHydrated = true;
    this.#collectSignedOutUnloadedDeletes();
    this.#hydratePendingMe();
    for (const [sub, sid] of [...this.#replacedUnverified]) {
      if (core.accounts.sessionId(sub) === sid) this.#invalidateReplacedSession(sub, sid);
      else this.#replacedUnverified.delete(sub);
    }
    this.recomputeOwners();
    this.#drainPendingCredentialDeletes();
    if (this.#choiceReloadWaiters === 0) core.data.device.clearChoiceRecovery();
  }

  #setLiveMe(sub: string, me: unknown | null, sid = this.#core.accounts.sessionId(sub)): { gen: number; sid: string; me: unknown | null } {
    const gen = this.#core.data.accountGen(sub);
    const prevMe = this.#meOf(sub);
    if (me === null) {
      // Preserve every workspace previously known for `sub` (from `#liveMe` or SQLite) into the durable
      // credential-cleanup index before overwriting `#liveMe` with the `NOT_BETA` tombstone.
      this.#rememberWorkspacesOf(sub, prevMe);
    } else if (isObject(prevMe) && Array.isArray(prevMe.workspaces)) {
      const nextIds = new Set(
        isObject(me) && Array.isArray(me.workspaces)
          ? me.workspaces.flatMap((w) => (isObject(w) && typeof w.id === "string" ? [w.id] : []))
          : [],
      );
      for (const w of prevMe.workspaces) {
        if (isObject(w) && typeof w.id === "string" && w.id.length > 0 && !nextIds.has(w.id)) {
          this.#rememberCredentialWorkspace(sub, w.id);
        }
      }
    }
    const entry = { gen, sid, me };
    this.#liveMe.set(sub, entry);
    const db = this.#core.data.db(sub);
    if (!this.#core.data.isPersistentDb(db)) this.#savePendingMe(sub, me);
    this.#core.data.notifyAccountRecord(sub, "me");
    return entry;
  }

  #clearLiveMe(sub: string): void {
    this.#clearPendingMe(sub);
    if (this.#liveMe.delete(sub)) this.#core.data.notifyAccountRecord(sub, "me");
  }

  /// Writes or drops `live.me` in `db` and removes the in-memory + device-pending copy ONLY once `db.written`
  /// finishes on a persistent disk DB and the committed on-disk row actually matches `live.me` (keeping `#liveMe`
  /// and `pendingMe` intact for ephemeral memory DBs or if `SQLITE_FULL` rolls back).
  #persistLiveMe(sub: string, db: AccountDb, live: { gen: number; sid: string; me: unknown | null }): void {
    const core = this.#core;
    if (db.readOnly || live.gen !== core.data.accountGen(sub) || live.sid !== core.accounts.sessionId(sub)) return;
    const persistent = core.data.isPersistentDb(db);
    this.#persistingLiveMe.add(sub);
    const topic: Topic = { topic: "$account-record", account: sub, name: "me" };
    if (live.me === null) db.dropAccountDoc("me", topic);
    else db.putAccountDoc("me", live.me, core.host.nowMs(), topic);
    core.runner.fork(
      Effect.andThen(
        Effect.ignore(db.written),
        Effect.sync(() => {
          this.#persistingLiveMe.delete(sub);
          if (!persistent) return;
          if (this.#liveMe.get(sub) !== live) return;
          if (core.data.db(sub) !== db || db.readOnly || live.gen !== core.data.accountGen(sub) || live.sid !== core.accounts.sessionId(sub)) return;
          try {
            const persisted = db.accountDoc("me");
            const matches = live.me === null ? persisted === undefined : equal(persisted, live.me);
            if (matches) {
              this.#persistedMe.set(sub, { gen: live.gen, sid: live.sid });
              this.#liveMe.delete(sub);
              this.#clearPendingMe(sub);
            }
          } catch {
            // Read failed; keep `#liveMe` intact for retry / close verification.
          }
        }),
      ),
    );
  }

  /// Persists any same-generation, same-session in-memory authoritative `/v1/me` (or `NOT_BETA` tombstone) into a newly
  /// published account DB BEFORE `recomputeOwners()` / `resumeFor()` so stale disk rows never overwrite fresher cloud state.
  adoptDb(db: AccountDb): void {
    const sub = db.sub;
    const replacedSid = this.#replacedUnverified.get(sub);
    if (replacedSid !== undefined && this.#core.accounts.sessionId(sub) === replacedSid) {
      this.#invalidateReplacedSession(sub, replacedSid);
    }
    const live = this.#liveMe.get(sub);
    if (live === undefined) return;
    if (live.gen !== this.#core.data.accountGen(sub) || live.sid !== this.#core.accounts.sessionId(sub)) {
      this.#clearLiveMe(sub);
      return;
    }
    if (!db.readOnly) this.#persistLiveMe(sub, db, live);
  }

  /// Retries persisting an unconfirmed `#liveMe` record once a persistent disk `db` commits cleanly again (e.g.
  /// after transient `SQLITE_FULL` clears) so subsequent offline restarts see the authoritative `/v1/me` on disk.
  retryPendingLiveMe(db: AccountDb): void {
    const sub = db.sub;
    if (!this.#core.data.isPersistentDb(db) || db.full || this.#persistingLiveMe.has(sub)) return;
    const live = this.#liveMe.get(sub);
    if (live === undefined || live.gen !== this.#core.data.accountGen(sub) || live.sid !== this.#core.accounts.sessionId(sub)) return;
    this.#persistLiveMe(sub, db, live);
  }

  /// Verifies every pending `#liveMe` record against on-disk SQLite after `Data.closing()` has settled in-flight
  /// transactions; retries and commits any rolled-back/unpersisted entry per account (never letting one account's
  /// SQLite read/write error abort others), persists DB-less/read-only/ephemeral-memory entries into
  /// `device/choice["pendingMe"]` before `device.close()` flushes, and returns a `HostError` if any persistent
  /// writable disk DB still fails to persist.
  flushLiveMe(): HostError | null {
    const core = this.#core;
    const failed: string[] = [];
    for (const [sub, live] of [...this.#liveMe]) {
      if (live.gen !== core.data.accountGen(sub) || live.sid !== core.accounts.sessionId(sub)) continue;
      const db = core.data.db(sub);
      if (!core.data.isPersistentDb(db)) {
        try {
          this.#savePendingMe(sub, live.me);
        } catch {
          failed.push(`me/${sub}`);
        }
        continue;
      }
      const matches = () => {
        const persisted = db.accountDoc("me");
        return live.me === null ? persisted === undefined : equal(persisted, live.me);
      };
      this.#persistingLiveMe.add(sub);
      try {
        if (matches()) {
          this.#persistedMe.set(sub, { gen: live.gen, sid: live.sid });
          this.#liveMe.delete(sub);
          this.#clearPendingMe(sub);
          continue;
        }
        const topic: Topic = { topic: "$account-record", account: sub, name: "me" };
        if (live.me === null) db.dropAccountDoc("me", topic);
        else db.putAccountDoc("me", live.me, core.host.nowMs(), topic);
        db.commitNow();
        if (matches()) {
          this.#persistedMe.set(sub, { gen: live.gen, sid: live.sid });
          this.#liveMe.delete(sub);
          this.#clearPendingMe(sub);
        } else {
          try { this.#savePendingMe(sub, live.me); } catch { /* reported below */ }
          failed.push(`me/${sub}`);
        }
      } catch {
        try { this.#savePendingMe(sub, live.me); } catch { /* reported below */ }
        failed.push(`me/${sub}`);
      } finally {
        this.#persistingLiveMe.delete(sub);
      }
    }
    return failed.length > 0 ? new HostError(`failed to persist authoritative /v1/me on close: ${failed.join(", ")}`) : null;
  }

  /// If `device/choice` was still unloaded at close time and this run cleared/updated `pendingMe` or signed out an
  /// account, reloads `device/choice`, collects historical credential deletes for unloaded sign-outs (preserving
  /// re-login protection), strips superseded disk `pendingMe` entries, and attempts the queued deletes before
  /// `device.close()` flushes so a subsequent offline restart never reverts SQLite or leaks credentials.
  reconcilePendingMeOnClose(): Effect.Effect<HostError | null> {
    return Effect.gen({ self: this }, function* () {
      const core = this.#core;
      if (!core.data.device.isUnloaded("choice")) return null;
      const needsChoice = this.#pendingMeCleared.size > 0 || this.#signedOutWhileChoiceUnloaded.size > 0;
      if (!needsChoice && this.#liveMe.size === 0) return null;
      const loaded = yield* core.data.device.reload("choice", false);
      if (!loaded) {
        return needsChoice
          ? new HostError("device/choice could not be reloaded on close to reconcile pendingMe / sign-out cleanup")
          : null;
      }
      const deleteTargets = this.#collectSignedOutUnloadedDeletes();
      const raw = this.#readPendingMe();
      const pendingSessions = this.#readSessionMap("pendingMeSessions");
      let changed = false;
      let sessionsChanged = false;
      const accountsUnloaded = core.accounts.isUnloaded();
      const subs = new Set(core.accounts.list().map((a) => a.sub));
      for (const sub of Object.keys(raw)) {
        const signedIn = subs.has(sub);
        const gen = core.data.accountGen(sub);
        const curSid = core.accounts.sessionId(sub);
        const live = this.#liveMe.get(sub);
        const staleSession = signedIn && (pendingSessions[sub] ?? "") !== curSid;
        if ((!signedIn && !accountsUnloaded) || this.#pendingMeCleared.has(sub) || staleSession) {
          delete raw[sub];
          changed = true;
          if (Object.prototype.hasOwnProperty.call(pendingSessions, sub)) {
            delete pendingSessions[sub];
            sessionsChanged = true;
          }
        } else if (signedIn && live !== undefined && live.gen === gen && live.sid === curSid) {
          if (!equal(raw[sub], live.me)) {
            raw[sub] = live.me;
            changed = true;
          }
        } else if (signedIn && ((this.mes.get(sub) === null && this.#mesSid.get(sub) === curSid) || this.#hasPersistedMe(sub) || this.#isNotBeta(sub))) {
          delete raw[sub];
          changed = true;
          if (Object.prototype.hasOwnProperty.call(pendingSessions, sub)) {
            delete pendingSessions[sub];
            sessionsChanged = true;
          }
        }
      }
      this.#pendingMeCleared.clear();
      if (changed) {
        core.data.device.put("choice", "pendingMe", Object.keys(raw).length > 0 ? raw : undefined);
      }
      if (sessionsChanged) {
        core.data.device.put("choice", "pendingMeSessions", Object.keys(pendingSessions).length > 0 ? pendingSessions : undefined);
      }
      this.#syncAccountSessions();
      core.data.device.clearChoiceRecovery();
      for (const [k, savedAt] of deleteTargets) {
        if ((this.#credSaved.get(k) ?? 0) !== savedAt) continue;
        const r = yield* Effect.result(core.host.storageDelete(k));
        if (r._tag === "Success") this.#removePendingCredentialDelete(k);
      }
      return null;
    });
  }

  /// Whether `sub`'s workspace memberships are currently unknown because its disk DB was busy/failed (fell back
  /// to an empty memory DB or failed to open) and cloud `/v1/me` has not yet populated a readable `me` record
  /// (nor rejected the account with `NOT_BETA` in the current login generation).
  #meUnreadable(sub: string): boolean {
    const core = this.#core;
    if (core.data.notes.size === 0) return false;
    const note = core.data.notes.get(sub);
    if (note?.kind !== "busy" && note?.kind !== "failed") return false;
    if (this.#isNotBeta(sub)) return false;
    if (this.#hasLiveMe(sub)) return false;
    if (core.data.record("me", sub) !== undefined) return false;
    return !(this.mes.get(sub)?.code === NOT_BETA && this.#mesSid.get(sub) === core.accounts.sessionId(sub));
  }

  /// Whether `sub`'s local workspace membership list is not yet verified (deferred open or unreadable disk DB before `/v1/me`).
  #isUnverified(sub: string): boolean {
    return this.#core.data.isDeferred(sub) || this.#meUnreadable(sub);
  }

  /// Whether `sub`'s DB cannot accept local writes (opened read-only for a newer schema, or busy/failed without a DB).
  #dbUnavailable(sub: string): boolean {
    const core = this.#core;
    const db = core.data.db(sub);
    if (db !== undefined) return db.readOnly;
    const note = core.data.notes.get(sub);
    return note?.kind === "busy" || note?.kind === "failed";
  }

  /// Whether any signed-in non-console account currently has unverified workspace memberships, or `accounts` /
  /// `device/choice` failed its initial disk read and has not yet completed recovery.
  hasUnverifiedAccounts(): boolean {
    const core = this.#core;
    if (core.accounts.isUnloaded()) return true;
    if (core.data.device.isUnloaded("choice") || !this.#choiceHydrated) return true;
    if (core.data.hasDeferred()) return true;
    if (core.data.notes.size === 0) return false;
    return core.accounts.list().some((a) => !this.#isConsole(a.sub) && this.#meUnreadable(a.sub));
  }

  /// Whether local account-DB writes need ownership or DB-writability verification before running.
  needsWriteVerification(): boolean {
    if (this.hasUnverifiedAccounts()) return true;
    return this.#core.accounts.list().some((a) => this.#dbUnavailable(a.sub));
  }

  #meListsWorkspace(sub: string, workspace: string): boolean {
    const me = this.#meOf(sub);
    return isObject(me) && Array.isArray(me.workspaces)
      && me.workspaces.some((w) => isObject(w) && w.id === workspace);
  }

  /// Whether any non-console account strictly earlier than `sub` in sign-in order still has unverified memberships
  /// (deferred DB, unreadable busy/failed disk DB without cloud `/v1/me`, or unread `accounts`/`device/choice` recovery).
  hasEarlierDeferred(sub: string): boolean {
    const core = this.#core;
    if (core.accounts.isUnloaded()) return true;
    if (core.data.device.isUnloaded("choice") || !this.#choiceHydrated) return true;
    if (!this.hasUnverifiedAccounts()) return false;
    for (const account of core.accounts.list()) {
      if (this.#isConsole(account.sub)) continue;
      if (account.sub === sub) return false;
      if (this.#isUnverified(account.sub)) return true;
    }
    return false;
  }

  /// Accounts in sign-in order that could currently own `workspace`: every unknown-membership account up to (and
  /// including) the first non-console account whose known membership (open DB or same-session live `/v1/me`) lists
  /// `workspace`, never including strictly later accounts once an earlier account already holds `workspace`.
  #candidateOwners(workspace: string): { candidates: Set<string>; firstOpenHolder: string | null; needsVerify: boolean; includeTarget: boolean } {
    const core = this.#core;
    const candidates = new Set<string>();
    const order: string[] = [];
    let firstHolder: string | null = null;
    let sawUnverifiedBeforeHolder = false;
    for (const account of core.accounts.list()) {
      if (this.#isConsole(account.sub)) continue;
      order.push(account.sub);
      const unverified = this.#isUnverified(account.sub);
      const known = !unverified || this.#hasLiveMe(account.sub) || this.#isNotBeta(account.sub);
      if (!known) {
        candidates.add(account.sub);
        sawUnverifiedBeforeHolder = true;
        continue;
      }
      if (this.#meListsWorkspace(account.sub, workspace)) {
        firstHolder = account.sub;
        candidates.add(account.sub);
        if (unverified) sawUnverifiedBeforeHolder = true;
        break;
      }
      if (unverified) sawUnverifiedBeforeHolder = true;
    }
    const pubOwner = core.workspaces.owner(workspace);
    const holderIdx = firstHolder !== null ? order.indexOf(firstHolder) : -1;
    const pubIdx = pubOwner !== null ? order.indexOf(pubOwner) : -1;
    if (pubOwner !== null && (holderIdx < 0 || (pubIdx >= 0 && pubIdx <= holderIdx))) {
      candidates.add(pubOwner);
    }
    const includeTarget = firstHolder !== null && core.data.isDeferred(firstHolder);
    const needsVerify = this.hasUnverifiedAccounts() && (
      firstHolder !== null
        ? sawUnverifiedBeforeHolder
        : (pubOwner === null || this.hasEarlierDeferred(pubOwner))
    );
    return { candidates, firstOpenHolder: firstHolder ?? pubOwner, needsVerify, includeTarget };
  }

  /// Whether `sub`'s workspace membership list was genuinely unknown BEFORE `ensureVerifiedOwners` started waiting
  /// (neither open/readable DB, nor same-session authoritative live `/v1/me` / `NOT_BETA` tombstone even while DB was
  /// deferred, nor same-session non-superseded disk `pendingMe` record).
  #preWaitMembershipUnknown(
    sub: string,
    choiceUnloaded: boolean,
    preKnownMembership: ReadonlySet<string>,
    preSupersededPendingMe: ReadonlySet<string>,
    preSessions: ReadonlyMap<string, string>,
  ): boolean {
    if (preKnownMembership.has(sub)) return false;
    if (!choiceUnloaded) return true;
    const recovery = this.#core.data.device.choiceRecovery();
    const diskPendingMe = recovery?.pendingMe ?? null;
    if (diskPendingMe !== null && Object.prototype.hasOwnProperty.call(diskPendingMe, sub) && !preSupersededPendingMe.has(sub)) {
      const entrySid = recovery?.pendingMeSessions?.[sub] ?? "";
      const subSid = preSessions.get(sub) ?? "";
      if (entrySid === subSid) return false;
    }
    return true;
  }

  /// Ensures every workspace in `workspaces` has a verified owner with an available DB (opening earlier deferred
  /// accounts if needed) before any local write, draft persistence, carry, or mutation touches an account DB.
  /// Snapshots ALL candidate owners, pre-wait holders, known memberships, and session IDs across every workspace
  /// before the first await, and whenever any wait occurs re-verifies EVERY workspace in `workspaces`. Fails with
  /// `cancelled` if any candidate signs out or changes session, any pre-wait holder loses membership, ownership
  /// remains unverified, or the resolved owner's DB is unavailable.
  ensureVerifiedOwners(workspaces: Iterable<string>): Effect.Effect<void, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const core = this.#core;
      if (!this.needsWriteVerification()) return;
      if (core.accounts.isUnloaded()) {
        return yield* Effect.fail(new CoreError("cancelled", t("core-misc.call.cancelled")));
      }
      const list = [...new Set(workspaces)].filter((ws) => ws.length > 0);
      if (list.length === 0) return;
      const choiceUnloaded = core.data.device.isUnloaded("choice") || !this.#choiceHydrated;
      const preReloadOrder = core.accounts.list().filter((a) => !this.#isConsole(a.sub)).map((a) => a.sub);
      const preSessions = new Map<string, string>();
      const preKnownMembership = new Set<string>();
      for (const sub of preReloadOrder) {
        preSessions.set(sub, core.accounts.sessionId(sub));
        if (!this.#isUnverified(sub) || this.#hasLiveMe(sub) || this.#isNotBeta(sub)) {
          preKnownMembership.add(sub);
        }
      }
      const preLocalHolders = new Map<string, Set<string>>();
      const preSupersededPendingMe = new Set<string>();
      const wsCandidates = new Map<string, Set<string>>();
      const allSnapTargets = new Set<string>();
      const allChecks: Array<[string, string | null]> = [];
      let waits: Array<[string, string | null, boolean]> = [];
      for (const ws of list) {
        const info = this.#candidateOwners(ws);
        wsCandidates.set(ws, new Set(info.candidates));
        for (const sub of info.candidates) allSnapTargets.add(sub);
        const firstKnownHolder = preReloadOrder.find((sub) => preKnownMembership.has(sub) && this.#meListsWorkspace(sub, ws)) ?? info.firstOpenHolder;
        if (firstKnownHolder !== null) allSnapTargets.add(firstKnownHolder);
        allChecks.push([ws, firstKnownHolder]);
        if (info.needsVerify) waits.push([ws, info.firstOpenHolder, info.includeTarget]);
      }
      if (choiceUnloaded) {
        for (const sub of preReloadOrder) {
          allSnapTargets.add(sub);
          const curSid = preSessions.get(sub) ?? "";
          if (
            this.#pendingMeCleared.has(sub)
            || this.#hasPersistedMe(sub)
            || (this.mes.get(sub) === null && this.#mesSid.get(sub) === curSid)
            || this.#isNotBeta(sub)
            || this.#hasLiveMe(sub)
          ) {
            preSupersededPendingMe.add(sub);
          }
        }
        for (const ws of list) {
          const holders = new Set<string>();
          for (const sub of preReloadOrder) {
            if (preKnownMembership.has(sub) && this.#meListsWorkspace(sub, ws)) holders.add(sub);
          }
          preLocalHolders.set(ws, holders);
        }
      }
      if (!choiceUnloaded && waits.length === 0) {
        for (const [ws] of allChecks) {
          const postOwner = core.workspaces.owner(ws);
          if (postOwner !== null && this.#dbUnavailable(postOwner)) {
            return yield* Effect.fail(new CoreError("cancelled", t("core-misc.call.cancelled")));
          }
        }
        return;
      }
      // Snapshot pre-wait login generations BEFORE the very first await (including device/choice reload), then
      // evaluate sign-outs, session replacements, membership losses, and determinate owner changes per workspace.
      const snap = core.data.accountSessionSnapshot(allSnapTargets);
      const body = Effect.gen({ self: this }, function* () {
        if (choiceUnloaded) {
          const loaded = yield* core.data.device.reload("choice");
          if (!loaded) {
            return yield* Effect.fail(new CoreError("cancelled", t("core-misc.call.cancelled")));
          }
          this.#onChoiceLoaded();
          // Recompute deferred waits after hydrating pendingMe/owners (keeping original allChecks & snap!).
          waits = [];
          for (const ws of list) {
            const info = this.#candidateOwners(ws);
            const set = wsCandidates.get(ws)!;
            for (const sub of info.candidates) set.add(sub);
            if (info.needsVerify) waits.push([ws, info.firstOpenHolder, info.includeTarget]);
          }
        }
        if (this.onNeedDeferred && core.data.hasDeferred() && waits.length > 0) {
          for (const [ws, beforeSub, includeTarget] of waits) {
            yield* this.onNeedDeferred(ws, beforeSub, includeTarget);
          }
        }
        for (const [ws, preHolder] of allChecks) {
          const effectiveHolder = choiceUnloaded
            ? this.#effectivePreHolder(ws, preReloadOrder, preLocalHolders.get(ws)!, preSupersededPendingMe, preSessions)
            : preHolder;
          if (effectiveHolder !== null && !this.#meListsWorkspace(effectiveHolder, ws)) {
            return yield* Effect.fail(new CoreError("cancelled", t("core-misc.call.cancelled")));
          }
          const postOwner = core.workspaces.owner(ws);
          if (postOwner === null || this.hasEarlierDeferred(postOwner) || this.#dbUnavailable(postOwner)) {
            return yield* Effect.fail(new CoreError("cancelled", t("core-misc.call.cancelled")));
          }
          // Only an earlier account whose pre-wait membership was genuinely unknown (neither open/live nor already
          // answered by a same-session live/disk `pendingMe` record) may supersede `effectiveHolder` once verified;
          // otherwise bind the write to `effectiveHolder` and cancel if an earlier account newly gained `ws`.
          if (effectiveHolder !== null && postOwner !== effectiveHolder) {
            const holderIdx = preReloadOrder.indexOf(effectiveHolder);
            const postIdx = preReloadOrder.indexOf(postOwner);
            const earlierMembershipUnknown =
              postIdx >= 0
              && postIdx < holderIdx
              && this.#preWaitMembershipUnknown(postOwner, choiceUnloaded, preKnownMembership, preSupersededPendingMe, preSessions);
            if (!earlierMembershipUnknown) {
              return yield* Effect.fail(new CoreError("cancelled", t("core-misc.call.cancelled")));
            }
          }
          const relevant = new Map<string, number>();
          const addRelevant = (sub: string) => {
            const gen = snap.gens.get(sub);
            if (gen !== undefined) relevant.set(sub, gen);
          };
          if (effectiveHolder !== null) addRelevant(effectiveHolder);
          addRelevant(postOwner);
          for (const sub of wsCandidates.get(ws) ?? []) addRelevant(sub);
          if (choiceUnloaded) {
            const ownerIdx = preReloadOrder.indexOf(postOwner);
            const limit = ownerIdx >= 0 ? ownerIdx + 1 : preReloadOrder.length;
            for (let i = 0; i < limit; i++) addRelevant(preReloadOrder[i]);
          }
          if (core.data.accountSignedOutSince({ gens: relevant })) {
            return yield* Effect.fail(new CoreError("cancelled", t("core-misc.call.cancelled")));
          }
          for (const sub of relevant.keys()) {
            const beforeSid = preSessions.get(sub);
            if (beforeSid !== undefined && core.accounts.sessionId(sub) !== beforeSid) {
              return yield* Effect.fail(new CoreError("cancelled", t("core-misc.call.cancelled")));
            }
          }
        }
      });
      if (!choiceUnloaded) return yield* body;
      this.#choiceReloadWaiters++;
      return yield* Effect.ensuring(
        body,
        Effect.sync(() => {
          this.#choiceReloadWaiters--;
          if (this.#choiceReloadWaiters === 0 && this.#choiceHydrated) {
            core.data.device.clearChoiceRecovery();
          }
        }),
      );
    });
  }

  /// Ensures `workspace`'s owner is verified against sign-in order (opening earlier deferred accounts if needed)
  /// before any local write, draft persistence, credential lookup, or mutation touches an account DB.
  /// Fails with `cancelled` if any potentially owning account signs out or changes login generation mid-wait.
  ensureVerifiedOwner(workspace: string): Effect.Effect<void, CoreError> {
    return this.ensureVerifiedOwners([workspace]);
  }

  // ── what the topics read ──

  /// A station's name by its address, as its workspace is held.
  nameOf(address: string): string | null {
    const at = address.indexOf("/");
    if (at < 0) return null;
    const workspace = this.#core.data.shared({ topic: "workspace", workspace: address.slice(0, at) });
    const id = address.slice(at + 1);
    const stations = isObject(workspace) && Array.isArray(workspace.stations) ? workspace.stations : [];
    const station = stations.find((s) => isObject(s) && s.id === id);
    return isObject(station) && typeof station.name === "string" ? station.name : null;
  }

  /// A workspace's name, as it is held; null while not known.
  workspaceName(id: string): string | null {
    const workspace = this.#core.data.shared({ topic: "workspace", workspace: id });
    return isObject(workspace) && typeof workspace.name === "string" && workspace.name !== "" ? workspace.name : null;
  }

  /// Every account with what its `/v1/me` said. `loaded` only once it answered this run.
  workspacesValue(): unknown {
    const core = this.#core;
    return core.accounts.list().map((account) => {
      const record = this.#meOf(account.sub);
      const me = isObject(record) ? record : {};
      const entry: Record<string, unknown> = {
        account,
        workspaces: me.workspaces === undefined ? [] : me.workspaces,
        ownedWorkspaces: core.workspaces.owned().filter(([, o]) => o === account.sub).map(([id]) => id),
        invitations: me.invitations === undefined ? [] : me.invitations,
        relay_url: me.relay_url === undefined ? null : me.relay_url,
        loaded: this.mes.has(account.sub) && this.mes.get(account.sub) === null,
      };
      if (pointer(record, "/user/beta") === true) entry.beta = true;
      // Its picture is one it put up for itself (account.setPicture), which it may take away.
      if (pointer(record, "/user/own_picture") === true) entry.ownPicture = true;
      const error = this.mes.get(account.sub);
      if (error) {
        entry.error = error;
        if (error.code === NOT_BETA) entry.blocked = notBetaText();
      }
      return entry;
    });
  }

  /// A workspace topic with nothing held: why, once it is known no account reaches it (or its read failed).
  workspaceError(workspace: string): CoreError | null {
    const failed = this.errors.get(workspace);
    if (failed) return failed;
    const accounts = this.#core.accounts.list();
    // Not known yet while an account has not answered.
    if (accounts.some((a) => !this.mes.has(a.sub))) return null;
    if (this.#core.workspaces.owner(workspace) !== null) return null;
    return new CoreError("not_found", t("core-misc.account.no_access"), 404);
  }

  /// A topic of an account's that failed while nothing is held of it.
  topicError(topic: Topic): CoreError | null {
    return this.errors.get(topicKey(topic)) ?? null;
  }

  // ── reading still.fail cloud ──

  /// An account's `/v1/me`, then what it reaches: its workspaces, its devices, an operator's lists.
  #account(sub: string): Effect.Effect<void, CoreError> {
    return Effect.gen({ self: this }, function* () {
      yield* this.#me(sub);
      const me = this.#meOf(sub);
      const ids = (isObject(me) && Array.isArray(me.workspaces) ? me.workspaces : []).flatMap((w) => (isObject(w) && typeof w.id === "string" ? [w.id] : []));
      const scheduler = this.#core.scheduler;
      // (the console's origin serves none of these: only its operator's lists, `#isConsole`)
      if (!this.#isConsole(sub)) {
        for (const id of ids) {
          const o = this.#core.workspaces.owner(id);
          if (o === sub && !this.hasEarlierDeferred(sub)) scheduler.enqueue("cloud", `workspace/${id}`, Priority.background, this.#workspace(id));
          else if (this.hasUnverifiedAccounts() && (o === sub || o === null)) this.#deferredWorkspaceSync.add(id);
        }
        // The team's replies on bug reports from each one's chats: what changed while the socket was closed.
        if (this.#core.provider.supports("feedback")) {
          for (const id of ids) {
            const o = this.#core.workspaces.owner(id);
            if (o === sub && !this.hasEarlierDeferred(sub)) this.feedbackChanged(id);
            else if (this.hasUnverifiedAccounts() && (o === sub || o === null)) this.#deferredFeedbackSync.add(id);
          }
        }
        // What only some providers have: login sessions, an operator's lists.
        if (this.#core.provider.supports("loginSessions")) scheduler.enqueue("cloud", `sessions/${sub}`, Priority.background, this.#loginSessions(sub));
      }
      // (an operator's lists only where its `/v1/me` does not say it is none: a cloud from before says nothing)
      if (this.#core.provider.supports("admin") && pointer(me, "/operator") !== false) scheduler.enqueue("cloud", `admin/${sub}`, Priority.background, this.#admin(sub));
      else this.#admins.delete(sub);
    });
  }

  /// The account's list changed (`workspaces`): its `/v1/me` again, and the workspaces new to it. One already held is
  /// told on its own (a `workspace` event comes with each change to it), and its sign-ins and an operator's lists are
  /// not what the list tells: read with the rest as the socket opens. (A member added had each device of the person's
  /// ask the cloud six things, its workspace three times: seven devices used up the account's 120 a minute, and the
  /// next member taken out was refused, the locks' end to end, 2026-11-10.)
  #listed(sub: string): Effect.Effect<void, CoreError> {
    return Effect.gen({ self: this }, function* () {
      yield* this.#me(sub);
      if (this.#isConsole(sub)) return;
      const me = this.#meOf(sub);
      const ids = (isObject(me) && Array.isArray(me.workspaces) ? me.workspaces : []).flatMap((w) => (isObject(w) && typeof w.id === "string" ? [w.id] : []));
      for (const id of ids) {
        const o = this.#core.workspaces.owner(id);
        if (o === sub && !this.hasEarlierDeferred(sub)) {
          if (!isObject(this.#core.data.shared({ topic: "workspace", workspace: id }))) {
            this.#core.scheduler.enqueue("cloud", `workspace/${id}`, Priority.background, this.#workspace(id));
          }
        } else if (this.hasUnverifiedAccounts() && (o === sub || o === null)) {
          this.#deferredWorkspaceSync.add(id);
        }
      }
    });
  }

  /// Every account read again, waited on (after a write to still.fail cloud: the call answers once it is; a write by
  /// one account may change what another sees, an invitation to it).
  refreshAll(): Effect.Effect<void> {
    return Effect.all(
      this.#core.accounts.list().map((a) => this.refreshAccount(a.sub)),
      { concurrency: "unbounded", discard: true },
    );
  }

  /// What a write of `sub`'s to still.fail cloud changed that no event tells, read again, waited on (core/execute.ts
  /// answers the call once it is). What it changed in a workspace or in the account's list the cloud tells every device
  /// of its members, this one too (`workspace`, `workspaces` on `/v1/events`), read as it is told like another device's
  /// change; so here only: the workspace's view the write answered with, held at once with no request, or, where a
  /// write in a workspace answered otherwise (people added, a station taken out), that one workspace read again: what
  /// the core does next goes by it (the people just added are signed into its lock by their subs), and its event
  /// alone would bring it only as the socket opens again where it is down; the account's
  /// `/v1/me` where the write changes which workspaces it reaches or the account itself (a workspace made, deleted or
  /// left, an invitation taken: the page that goes there next reads which account reaches it); its sign-ins and an
  /// operator's lists, which no event tells. Until 2026-11-15 every account was read whole after every write (`/v1/me`,
  /// every workspace, the sign-ins), an invitation only looked at too: in the locks' end to end 75 of a run's 443
  /// requests to the cloud were `/v1/me`, and an owner's own act was turned away by the account's limit.
  afterWrite(sub: string, method: string, path: string, answer: unknown, preReadGen?: number): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      const core = this.#core;
      const scheduler = core.scheduler;
      const at = path.split("?")[0]!;
      const ws = /^\/v1\/workspaces\/([^/]+)(?:\/([^/]+)(?:\/([^/]+))?)?/.exec(at);
      const id = ws ? decodeURIComponent(ws[1]!) : null;
      const made = method === "POST" && at === "/v1/workspaces";
      const joined = at.startsWith("/v1/invitations/") && at.endsWith("/accept");
      const reaches = made || joined
        || at === "/v1/me" || at.startsWith("/v1/me/")
        || (method === "DELETE" && ws !== null && (ws[2] === undefined || (ws[2] === "members" && ws[3] !== undefined && decodeURIComponent(ws[3]) === sub)));
      const readGen = preReadGen ?? (id !== null ? core.store.authGen.workspaceAuthGen(id) : 0);
      // (first: a workspace made, or joined, is the account's once its `/v1/me` lists it, and its view is then held as answered)
      if (reaches) yield* Effect.ignore(scheduler.ask("cloud", this.#meKey(sub), Priority.asked, this.#listed(sub)), { log: "Unhandled", message: "me read" });
      // (the view as the write answered it: the answer itself, or its `view`, people added)
      const view = viewIn(answer) ?? (isObject(answer) ? viewIn(answer.view) : null);
      const viewOf = view === null ? null : made || joined ? (view.id as string) : id;
      const reads: Effect.Effect<void>[] = [];
      if (viewOf !== null && view!.id === viewOf && core.workspaces.owner(viewOf) === sub) {
        if (viewOf === id) {
          this.#took(viewOf, view, readGen);
        } else {
          // Newly discovered workspace (e.g., invitation accept / workspace creation): perform a full authoritative
          // `#workspace(viewOf)` reread under current authGen rather than stamping post-write gen onto the response.
          reads.push(Effect.ignore(scheduler.ask("cloud", `workspace/${viewOf}`, Priority.asked, this.#workspace(viewOf)), { log: "Unhandled", message: "workspace read" }));
        }
      }
      // (a write inside a workspace still this account's that did not answer with its view; a bug report's answer is
      // read by its own path, core/execute.ts)
      const inside = ws !== null && ws[2] !== undefined && ws[2] !== "feedback" && view === null && !reaches && core.workspaces.owner(id!) === sub;
      if (inside) reads.push(Effect.ignore(scheduler.ask("cloud", `workspace/${id}`, Priority.asked, this.#workspace(id!)), { log: "Unhandled", message: "workspace read" }));
      if (at.startsWith("/v1/auth/") && core.provider.supports("loginSessions")) reads.push(Effect.ignore(scheduler.ask("cloud", `sessions/${sub}`, Priority.asked, this.#loginSessions(sub)), { log: "Unhandled", message: "login sessions read" }));
      // (the relays' page is read apart, while it shows: sync/admin-relays.ts)
      if (at.startsWith("/v1/admin/relays/")) this.onRelayLoad(sub);
      // (only the lists the write changed: each of the operator's lists is all of a kind, and `/v1/admin/me` changes by none)
      else if (at.startsWith("/v1/admin/") && this.#admins.has(sub)) {
        for (const list of adminListsForWrite(at)) reads.push(Effect.ignore(scheduler.ask("cloud", `admin/${sub}/${list}`, Priority.asked, Effect.asVoid(this.adminList(sub, list))), { log: "Unhandled", message: "admin read" }));
        if (at.startsWith("/v1/admin/feedback")) this.onAdminSubList(sub, "feedback/");
        if (at.startsWith("/v1/admin/keys")) this.onAdminSubList(sub, "keys");
      }
      // (every change of an operator's is in its 操作记录, the relays' too)
      if (at.startsWith("/v1/admin/") && at !== "/v1/admin/me" && method !== "GET") this.onAdminSubList(sub, "audit");
      yield* Effect.all(reads, { concurrency: "unbounded", discard: true });
    });
  }

  #meKey(sub: string): string {
    return `me/${sub}#${this.#core.accounts.sessionId(sub)}`;
  }

  /// Everything of an account read again, waited on.
  refreshAccount(sub: string): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      const scheduler = this.#core.scheduler;
      yield* Effect.ignore(scheduler.ask("cloud", this.#meKey(sub), Priority.asked, this.#me(sub)), { log: "Unhandled", message: "me read" });
      const me = this.#meOf(sub);
      const ids = (isObject(me) && Array.isArray(me.workspaces) ? me.workspaces : []).flatMap((w) => (isObject(w) && typeof w.id === "string" ? [w.id] : []));
      const onConsole = this.#isConsole(sub);
      const reads = onConsole ? [] : ids.filter((id) => this.#core.workspaces.owner(id) === sub).map((id) => Effect.ignore(scheduler.ask("cloud", `workspace/${id}`, Priority.asked, this.#workspace(id)), { log: "Unhandled", message: "workspace read" }));
      if (!onConsole && this.#core.provider.supports("loginSessions")) reads.push(Effect.ignore(scheduler.ask("cloud", `sessions/${sub}`, Priority.asked, this.#loginSessions(sub)), { log: "Unhandled", message: "login sessions read" }));
      if (this.#admins.has(sub)) reads.push(Effect.ignore(scheduler.ask("cloud", `admin/${sub}`, Priority.asked, this.#admin(sub)), { log: "Unhandled", message: "admin read" }));
      yield* Effect.all(reads, { concurrency: "unbounded" });
    });
  }

  /// Whether the account is signed in on an operator's console (its `/v1/me` says `console`): its own origin serves
  /// sign-in, `/v1/me`, `/v1/events` and `/v1/admin/*` alone, so nothing of its workspaces, its sign-ins or pushes is
  /// asked of it (each a 404, every time the console opened, of the account's requests a minute). A cloud from before
  /// says nothing: read as before.
  #isConsole(sub: string): boolean {
    return pointer(this.#meOf(sub), "/console") === true;
  }

  #me(sub: string): Effect.Effect<void, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const core = this.#core;
      if (!core.accounts.list().some((a) => a.sub === sub)) return;
      const snap = core.data.accountSessionSnapshot([sub]);
      const sid = core.accounts.sessionId(sub);
      const gen = core.store.readGen({ topic: "accounts" });
      const answer = yield* Effect.result(core.provider.me(sub));
      if (core.data.accountSignedOutSince(snap) || !core.accounts.list().some((a) => a.sub === sub) || core.accounts.sessionId(sub) !== sid) return;
      if (core.store.readGen({ topic: "accounts" }).authGen !== gen.authGen) return;
      if (answer._tag === "Success") {
        const relays = relaysOf(answer.success);
        if (this.#relaySource !== null && !core.accounts.list().some((a) => a.sub === this.#relaySource)) {
          this.#relaySource = null;
          this.relays = null;
        }
        const first = relays !== null && this.relays === null;
        if (first) this.#relaySource = sub;
        if (relays !== null && this.#relaySource === sub) this.relays = relays;
        const db = core.data.db(sub);
        this.#notBeta.delete(sub);
        if (this.#replacedUnverified.get(sub) === sid) {
          this.#invalidateReplacedSession(sub, sid);
        }
        const live = this.#setLiveMe(sub, answer.success, sid);
        if (db !== undefined && !db.readOnly) this.#persistLiveMe(sub, db, live);
        if (relays !== null && this.#relaySource === sub) this.onRelays?.(relays, entriesOf(answer.success), entryTargetsOf(answer.success));
        this.mes.set(sub, null);
        this.#mesSid.set(sub, sid);
      } else {
        // A beta app the account may not use: what it reached is not reached through this app.
        if (answer.failure.code === NOT_BETA) {
          const db = core.data.db(sub);
          this.#notBeta.set(sub, { gen: core.data.accountGen(sub), sid });
          const live = this.#setLiveMe(sub, null, sid);
          if (db !== undefined && !db.readOnly) this.#persistLiveMe(sub, db, live);
        }
        this.mes.set(sub, answer.failure);
        this.#mesSid.set(sub, sid);
      }
      this.recomputeOwners();
      this.forgetUnreachable();
    });
  }

  /// Proactively re-reads `/v1/workspaces/<id>` after a cloud-side downgrade so `{ topic: "workspace" }`
  /// confirms under the new `authGen` without waiting for a later cloud event.
  refreshWorkspace(id: string): void {
    if (this.#takingFullRead === id) return;
    const core = this.#core;
    const sub = core.workspaces.owner(id);
    if (sub === null || this.hasEarlierDeferred(sub)) return;
    core.scheduler.enqueue("cloud", `workspace/${id}`, Priority.shown, this.#workspace(id));
  }

  /// A workspace's view as the cloud gave it (its read, or a write of this device's answered with it), held.
  #took(id: string, view: unknown, readGen: number, fullRead = false): void {
    const core = this.#core;
    if (core.store.authGen.workspaceAuthGen(id) !== readGen) return;
    const topic: Topic = { topic: "workspace", workspace: id };
    this.errors.delete(id);
    this.forgetGoneStations(id, view);
    // Stations it said were not online and now says are (their `station` event went by while the socket was down):
    // tried now, as when the event says so.
    const was = core.data.shared(topic);
    const offline = new Set((isObject(was) && Array.isArray(was.stations) ? was.stations : []).flatMap((s) => (isObject(s) && typeof s.id === "string" && s.online === false ? [s.id] : [])));
    // (its stations' names and marks as the stations keep them laid over the cloud's list: station-marks-kept.ts)
    if (fullRead) this.#takingFullRead = id;
    try {
      core.data.set(topic, overlaid(view, keptMarks(core.data, id)));
      // Run `syncWorkspaceAuth` synchronously while `#takingFullRead` is active so any role downgrade
      // in this authoritative `fullRead` bumps `authGen` immediately (no 1-tick window before `data.onChange`)
      // and avoids scheduling a redundant second `GET /v1/workspaces/<id>`.
      core.syncWorkspaceAuth?.(id);
    } finally {
      if (fullRead && this.#takingFullRead === id) this.#takingFullRead = null;
    }
    // A full `GET /v1/workspaces/<id>` that itself triggered a role downgrade inside `core.data.set` IS the
    // authoritative post-downgrade workspace view; confirm `{ topic: "workspace" }` under its new gen while
    // keeping all station held topics gated until independently confirmed.
    const confirmGen = fullRead ? core.store.authGen.workspaceAuthGen(id) : readGen;
    core.confirmWorkspaceAuth?.(id, topic, confirmGen);
    if (fullRead) {
      const owner = core.workspaces.owner(id);
      if (owner !== null) this.#confirmedBase.set(id, { owner, gen: confirmGen });
    }
    for (const s of isObject(view) && Array.isArray(view.stations) ? view.stations : []) {
      if (isObject(s) && typeof s.id === "string" && s.online === true && offline.has(s.id)) core.stations?.cameOnline(`${id}/${s.id}`);
    }
    this.onReach?.();
  }

  #workspace(id: string): Effect.Effect<void, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const core = this.#core;
      const sub = core.workspaces.owner(id);
      if (sub === null || this.hasEarlierDeferred(sub)) {
        if (this.hasUnverifiedAccounts()) this.#deferredWorkspaceSync.add(id);
        return;
      }
      const topic: Topic = { topic: "workspace", workspace: id };
      const gen = core.store.readGen(topic);
      const answer = yield* Effect.result(core.provider.request(sub, "GET", `/v1/workspaces/${encode(id)}`, null));
      if (core.workspaces.owner(id) !== sub) {
        if (this.hasUnverifiedAccounts()) this.#deferredWorkspaceSync.add(id);
        return;
      }
      if (core.store.readGen(topic).authGen !== gen.authGen) return;
      if (answer._tag === "Success") this.#took(id, answer.success, gen.authGen, true);
      else {
        const error = answer.failure;
        // Gone (deleted, or the account left it): what is held of it goes.
        if (error.status === 404 || error.status === 403) {
          core.data.dropWorkspace(id);
          this.errors.set(id, error);
        } else if (core.data.get(topic) === undefined) this.errors.set(id, error);
        // Turned away for the account's asks this minute (its devices all read at once as its lock moves): read again
        // a little later, else what it says (how far the lock goes) stayed behind until it changed once more.
        if (error.status === 429) this.#workspaceLater(id);
        core.store.invalidate(topic);
      }
    });
  }

  /// The team's replies on bug reports from a workspace's chats changed (its event, or this device answered one): read
  /// again.
  feedbackChanged(id: string): void {
    if (!this.#core.provider.supports("feedback")) return;
    const sub = this.#core.workspaces.owner(id);
    if (sub === null || this.hasEarlierDeferred(sub)) {
      if (this.hasUnverifiedAccounts()) this.#deferredFeedbackSync.add(id);
      return;
    }
    this.#core.scheduler.enqueue("cloud", `feedback/${id}`, Priority.background, this.#feedback(id));
  }

  /// A workspace's reports with the team's replies (feedback-replies.ts), as its member reads them; what was kept stays
  /// when they cannot be read, and goes when the account is no member.
  #feedback(id: string): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      const core = this.#core;
      const sub = core.workspaces.owner(id);
      if (sub === null || this.hasEarlierDeferred(sub)) {
        if (this.hasUnverifiedAccounts()) this.#deferredFeedbackSync.add(id);
        return;
      }
      const wsTopic: Topic = { topic: "workspace", workspace: id };
      const gen = core.store.readGen(wsTopic);
      const answer = yield* Effect.result(core.provider.request(sub, "GET", `/v1/workspaces/${encode(id)}/feedback`, null));
      if (core.workspaces.owner(id) !== sub) {
        if (this.hasUnverifiedAccounts()) this.#deferredFeedbackSync.add(id);
        return;
      }
      if (core.store.readGen(wsTopic).authGen !== gen.authGen) return;
      if (answer._tag === "Success") core.data.put("feedback", id, isObject(answer.success) ? answer.success : { feedback: [] });
      else if (answer.failure.status === 404 || answer.failure.status === 403) {
        core.data.forgetRecord("feedback", id);
        core.data.forgetRecord("feedbackDismissed", id);
      }
    });
  }

  #workspaceLater(id: string): void {
    const core = this.#core;
    if (this.#workspaceRetry.has(id)) return;
    const again = Effect.sleep(LIMITED_MS).pipe( // timer: a retry after a failure (429)
      Effect.andThen(Effect.sync(() => {
        this.#workspaceRetry.delete(id);
        if (core.workspaces.owner(id) !== null) core.scheduler.enqueue("cloud", `workspace/${id}`, Priority.shown, this.#workspace(id));
      })),
    );
    this.#workspaceRetry.set(id, core.runner.fork(again) as Fiber.Fiber<unknown, unknown>);
  }

  #loginSessions(sub: string): Effect.Effect<void, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const core = this.#core;
      const topic: Topic = { topic: "loginSessions", account: sub };
      const gen = core.store.readGen(topic);
      const answer = yield* Effect.result(core.provider.request(sub, "GET", "/v1/auth/sessions", null));
      if (!core.accounts.list().some((a) => a.sub === sub) || core.store.readGen(topic).authGen !== gen.authGen) return;
      if (answer._tag === "Success") {
        const sessions = isObject(answer.success) ? answer.success.sessions : undefined;
        this.errors.delete(topicKey(topic));
        core.data.set(topic, sessions === undefined ? [] : sessions);
      } else if (core.data.get(topic) === undefined) {
        this.errors.set(topicKey(topic), answer.failure);
        core.store.invalidate(topic);
      }
    });
  }

  /// An operator's lists, for an account still.fail cloud says is one (`/v1/admin/me`). One that failed for a reason
  /// other than the account's (the network, a 5xx) is asked again after a wait: nothing else would ask while the
  /// events socket stays open, and the console would wait on it until reloaded.
  #admin(sub: string): Effect.Effect<void, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const core = this.#core;
      const me = yield* Effect.result(core.provider.request(sub, "GET", "/v1/admin/me", null));
      if (me._tag === "Failure") {
        this.#admins.delete(sub);
        if (passing(me.failure)) this.#adminAgain(sub);
        return;
      }
      this.#admins.add(sub);
      // (what a page has open of them is read again too: as it is first shown and as the events socket opens again)
      this.onRelayLoad(sub);
      this.onAdminSubList(sub, "audit");
      this.onAdminSubList(sub, "feedback/");
      const failed = yield* Effect.all(ADMIN_LISTS.map((list) => this.adminList(sub, list)), { concurrency: "unbounded" });
      if (failed.some((e) => e !== null && passing(e))) this.#adminAgain(sub);
      else this.#adminRetry.delete(sub);
    });
  }

  #adminAgain(sub: string): void {
    const core = this.#core;
    let retry = this.#adminRetry.get(sub);
    if (!retry) this.#adminRetry.set(sub, (retry = { ms: SOCKET_RETRY_MS, fiber: null }));
    if (retry.fiber !== null) return;
    const wait = retry.ms;
    retry.ms = Math.min(retry.ms * 2, SOCKET_RETRY_MAX_MS);
    const again = Effect.sleep(wait).pipe( // timer: a retry after a failure, with a backoff
      Effect.andThen(Effect.sync(() => {
        retry.fiber = null;
        if (this.#adminRetry.get(sub) !== retry || !core.accounts.list().some((a) => a.sub === sub)) return;
        core.scheduler.enqueue("cloud", `admin/${sub}`, Priority.background, this.#admin(sub));
      })),
    );
    retry.fiber = core.runner.fork(again) as Fiber.Fiber<unknown, unknown>;
  }

  /// One of an operator's lists read again (`/v1/admin/<list>`); what was read before stays when it fails. What it
  /// failed with, or null.
  adminList(sub: string, list: string): Effect.Effect<CoreError | null> {
    return Effect.gen({ self: this }, function* () {
      const core = this.#core;
      const topic: Topic = { topic: "admin", account: sub, list };
      const gen = core.store.readGen(topic);
      const answer = yield* Effect.result(core.provider.request(sub, "GET", `/v1/admin/${list}`, null));
      if (!core.accounts.list().some((a) => a.sub === sub) || core.store.readGen(topic).authGen !== gen.authGen) return null;
      if (answer._tag === "Success") {
        this.errors.delete(topicKey(topic));
        core.data.set(topic, answer.success);
        return null;
      }
      if (core.data.get(topic) === undefined) {
        this.errors.set(topicKey(topic), answer.failure);
        core.store.invalidate(topic);
      }
      return answer.failure;
    });
  }

  /// Which account reaches each workspace: the first (in sign-in order) whose last `/v1/me` lists it. An account
  /// signed out: what it reached goes, with its credentials. While earlier accounts in sign-in order are still
  /// deferred, workspaces they may own are left unassigned rather than provisionally assigned to a later account.
  recomputeOwners(): void {
    const core = this.#core;
    const accounts = core.accounts.list();
    for (const sub of [...this.mes.keys()]) if (!accounts.some((a) => a.sub === sub)) this.mes.delete(sub);
    const hasUnverified = this.hasUnverifiedAccounts();
    const cachedRaw = hasUnverified ? core.data.device.get("choice", "workspaceOwners") : null;
    const cachedOwners = isObject(cachedRaw) ? (cachedRaw as Record<string, unknown>) : null;
    const owners = new Map<string, string>();
    let sawEarlierUnverified = core.accounts.isUnloaded() || core.data.device.isUnloaded("choice") || !this.#choiceHydrated;
    for (const account of accounts) {
      // (a console's account reaches no workspace from here: nothing of it is asked there, no station dialled)
      if (this.#isConsole(account.sub)) continue;
      if (this.#isUnverified(account.sub)) {
        sawEarlierUnverified = true;
        continue;
      }
      const me = this.#meOf(account.sub);
      for (const w of isObject(me) && Array.isArray(me.workspaces) ? me.workspaces : []) {
        if (!isObject(w) || typeof w.id !== "string" || owners.has(w.id)) continue;
        // If an earlier account in sign-in order is still unverified (deferred or busy/failed disk DB without /v1/me),
        // only assign workspaces whose cached owner is confirmed to be this account. Any shared or uncached workspace
        // waits until earlier accounts' memberships are known so writes never land in the wrong DB.
        if (sawEarlierUnverified && cachedOwners?.[w.id] !== account.sub) continue;
        owners.set(w.id, account.sub);
      }
    }
    const prevOwned = new Map(core.workspaces.owned());
    core.workspaces.setOwners(owners);
    const ownersChanged =
      prevOwned.size !== owners.size ||
      [...owners].some(([id, o]) => prevOwned.get(id) !== o);
    if (ownersChanged) core.store.invalidate({ topic: "workspaces" });
    if (!hasUnverified) {
      core.data.device.put("choice", "workspaceOwners", Object.fromEntries(owners));
      this.#syncAccountSessions();
    }
    if (this.#deferredWorkspaceSync.size > 0) {
      for (const id of [...this.#deferredWorkspaceSync]) {
        const o = core.workspaces.owner(id);
        if (o !== null && !this.hasEarlierDeferred(o)) {
          this.#deferredWorkspaceSync.delete(id);
          // If `o`'s own `/v1/me` has not run yet, `#account(o)` will fetch `workspace/<id>` once its socket opens.
          if (this.mes.has(o)) core.scheduler.enqueue("cloud", `workspace/${id}`, Priority.background, this.#workspace(id));
        } else if (!hasUnverified) {
          this.#deferredWorkspaceSync.delete(id);
        }
      }
    }
    if (this.#deferredFeedbackSync.size > 0) {
      for (const id of [...this.#deferredFeedbackSync]) {
        const o = core.workspaces.owner(id);
        if (o !== null && !this.hasEarlierDeferred(o)) {
          this.#deferredFeedbackSync.delete(id);
          if (this.mes.has(o) && core.provider.supports("feedback")) core.scheduler.enqueue("cloud", `feedback/${id}`, Priority.background, this.#feedback(id));
        } else if (!hasUnverified) {
          this.#deferredFeedbackSync.delete(id);
        }
      }
    }
    for (const w of core.workspaces.all()) core.syncWorkspaceAuth?.(w.id);
    core.data.flushPendingDrafts();
    core.views?.vaultChanged(null);
    this.onReach?.();
  }

  /// Records that `sub` stored a credential for `workspace` (along with its current persistent session ID) so sign-out
  /// can remove every credential key and subsequent startups recognize credentials belonging to the current session.
  #rememberCredentialWorkspace(sub: string, workspace: string): void {
    const device = this.#core.data.device;
    const indexKey = `credWorkspaces/${sub}`;
    const raw = device.get("choice", indexKey);
    const list = Array.isArray(raw) ? raw.filter((v): v is string => typeof v === "string") : [];
    if (!list.includes(workspace)) device.put("choice", indexKey, [...list, workspace]);
    this.#recordAccountSession(sub);
  }

  /// An account signed out (its database goes with all it held): the credentials it had for its workspaces go too.
  signedOut(sub: string, me: unknown): void {
    const core = this.#core;
    this.#replacedUnverified.delete(sub);
    this.#notBeta.delete(sub);
    this.#persistedMe.delete(sub);
    this.#persistingLiveMe.delete(sub);
    this.#mesSid.delete(sub);
    this.#clearPendingMe(sub);
    if (core.data.device.isUnloaded("choice")) {
      const prefix = `${CREDENTIAL_KEY}/${sub}/`;
      const savedAtSignOut = new Map<string, number>();
      for (const [k, v] of this.#credSaved) {
        if (k.startsWith(prefix)) savedAtSignOut.set(k, v);
      }
      this.#signedOutWhileChoiceUnloaded.set(sub, savedAtSignOut);
    }
    const live = this.#liveMe.get(sub);
    const useLive = live !== undefined && (live.gen < core.data.accountGen(sub) || !core.accounts.list().some((a) => a.sub === sub));
    if (useLive) this.#clearLiveMe(sub);
    this.#askTurn.delete(sub);
    this.#credentialBackoff.delete(sub);
    const wsIds = new Set<string>();
    for (const src of [me, useLive ? live.me : undefined]) {
      for (const w of isObject(src) && Array.isArray(src.workspaces) ? src.workspaces : []) {
        if (isObject(w) && typeof w.id === "string") wsIds.add(w.id);
      }
    }
    const indexed = core.data.device.get("choice", `credWorkspaces/${sub}`);
    if (Array.isArray(indexed)) {
      for (const w of indexed) if (typeof w === "string" && w.length > 0) wsIds.add(w);
    }
    const cachedOwners = core.data.device.get("choice", "workspaceOwners");
    if (isObject(cachedOwners)) {
      for (const [ws, owner] of Object.entries(cachedOwners)) {
        if (owner === sub) wsIds.add(ws);
      }
    }
    core.data.device.put("choice", `credWorkspaces/${sub}`, undefined);
    if (!core.data.device.isUnloaded("choice")) {
      const sessions = this.#readSessionMap("accountSessions");
      if (Object.prototype.hasOwnProperty.call(sessions, sub)) {
        delete sessions[sub];
        core.data.device.put("choice", "accountSessions", Object.keys(sessions).length > 0 ? sessions : undefined);
      }
    }
    const allDeleteKeys: string[] = [];
    for (const ws of wsIds) {
      const key = `${CREDENTIAL_KEY}/${sub}/${ws}`;
      allDeleteKeys.push(`${key}/${CREDENTIAL_OTHERS}`, key);
    }
    // Persist delete intent BEFORE starting async host IO so Core.close()/crash mid-delete still retries on next start.
    this.#addPendingCredentialDeletes(allDeleteKeys);
    for (const ws of wsIds) {
      const key = `${CREDENTIAL_KEY}/${sub}/${ws}`;
      const othersKey = `${key}/${CREDENTIAL_OTHERS}`;
      this.#removed.set(key, (this.#removed.get(key) ?? 0) + 1);
      const targets: Array<[string, number]> = [
        [othersKey, this.#credSaved.get(othersKey) ?? 0],
        [key, this.#credSaved.get(key) ?? 0],
      ];
      const removing = Effect.gen({ self: this }, function* () {
        for (const [k, savedAt] of targets) {
          if ((this.#credSaved.get(k) ?? 0) !== savedAt) continue;
          const r = yield* Effect.result(core.host.storageDelete(k));
          if (r._tag === "Success") this.#removePendingCredentialDelete(k);
        }
      });
      core.runner.fork(this.#keepingOf(key).withPermits(1)(removing));
    }
  }

  /// What is held of stations no signed-in account reaches any more goes — decided only once every account's
  /// `/v1/me` is known, since one not heard from may reach them.
  forgetUnreachable(): void {
    const core = this.#core;
    if (this.hasUnverifiedAccounts() || core.accounts.list().some((a) => this.#meOf(a.sub) === undefined)) return;
    const workspaces = new Set(core.workspaces.owned().map(([id]) => id));
    for (const [id, base] of [...this.#confirmedBase]) {
      if (!workspaces.has(id) || core.workspaces.owner(id) !== base.owner || core.store.authGen.workspaceAuthGen(id) !== base.gen) {
        this.#confirmedBase.delete(id);
      }
    }
    // (a workspace's own, held as a station's are: its new chat's draft)
    core.data.retain((station) => {
      const at = station.indexOf("/");
      return workspaces.has(at >= 0 ? station.slice(0, at) : station);
    }, workspaces);
  }

  /// A workspace's stations as it lists them now: what is held of the others in it goes.
  forgetGoneStations(workspace: string, view: unknown): void {
    const stations = isObject(view) && Array.isArray(view.stations) ? view.stations : [];
    const ids = new Set(stations.flatMap((s) => (isObject(s) && typeof s.id === "string" ? [s.id] : [])));
    this.#core.data.retain((station) => {
      const at = station.indexOf("/");
      return at < 0 || station.slice(0, at) !== workspace || ids.has(station.slice(at + 1));
    }, null);
  }

  /// The signed-in account that reaches `workspace`, verifying against earlier unverified/deferred accounts in sign-in
  /// order and reading every account's `/v1/me` if it is not known yet.
  owner(workspace: string): Effect.Effect<string, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const core = this.#core;
      if (core.accounts.isUnloaded()) {
        return yield* Effect.fail(new CoreError("cancelled", t("core-misc.call.cancelled")));
      }
      if (core.data.device.isUnloaded("choice") || !this.#choiceHydrated) {
        if (yield* core.data.device.reload("choice")) {
          this.#onChoiceLoaded();
        }
      }
      const verified = () => {
        const sub = core.workspaces.owner(workspace);
        return sub !== null && core.accounts.list().some((a) => a.sub === sub) && !this.hasEarlierDeferred(sub) ? sub : null;
      };
      const first = verified();
      if (first !== null) return first;
      if (core.data.hasDeferred() && this.onNeedDeferred) {
        yield* this.onNeedDeferred(workspace, core.workspaces.owner(workspace));
        const afterDeferred = verified();
        if (afterDeferred !== null) return afterDeferred;
      }
      yield* Effect.all(
        core.accounts.list().map((a) => Effect.ignore(core.scheduler.ask("cloud", this.#meKey(a.sub), Priority.asked, this.#me(a.sub)), { log: "Unhandled", message: "me read" })),
        { concurrency: "unbounded" },
      );
      const after = verified();
      if (after === null) return yield* Effect.fail(new CoreError("not_found", t("core-misc.account.no_access"), 404));
      return after;
    });
  }

  /// The relays the mesh uses, from any account's `/v1/me`.
  relaysNow(): Effect.Effect<string[], CoreError> {
    return Effect.gen({ self: this }, function* () {
      if (this.relays) return this.relays;
      const core = this.#core;
      for (const account of core.accounts.list()) {
        const r = relaysOf(this.#meOf(account.sub));
        if (r) return r;
      }
      let last = CoreError.signedOut(t("core-misc.account.none"));
      for (const account of core.accounts.list()) {
        yield* Effect.ignore(core.scheduler.ask("cloud", this.#meKey(account.sub), Priority.asked, this.#me(account.sub)), { log: "Unhandled", message: "me read" });
        const r = relaysOf(this.#meOf(account.sub));
        if (r) return r;
        last = this.mes.get(account.sub) ?? last;
      }
      return yield* Effect.fail(last);
    });
  }

  /// The same account's `/v1/me` that supplies the relays, live or kept from the last run.
  #relayMe(): unknown {
    if (this.#relaySource !== null) return this.#meOf(this.#relaySource);
    for (const account of this.#core.accounts.list()) {
      const me = this.#meOf(account.sub);
      if (relaysOf(me) !== null) return me;
    }
    return null;
  }

  /// The relay entries that account's `/v1/me` named; none from a cloud from before them.
  entriesNow(): string[] {
    return entriesOf(this.#relayMe());
  }

  entryTargetsNow(): Record<string, string> {
    return entryTargetsOf(this.#relayMe());
  }

  /// A workspace's own relays, as its stations keep them (views/ways-stations.ts), else as its members' `/v1/me` name
  /// them (stations from before): used besides still.fail's for its stations alone.
  workspaceRelays(workspace: string): string[] {
    const kept = this.#core.data.record("ways", workspace);
    if (isObject(kept) && Array.isArray(kept.relays)) return kept.relays.flatMap((r) => (isObject(r) && typeof r.url === "string" ? [r.url] : []));
    for (const account of this.#core.accounts.list()) {
      const me = this.#meOf(account.sub);
      const found = (isObject(me) && Array.isArray(me.workspaces) ? me.workspaces : []).find((w) => isObject(w) && w.id === workspace);
      if (isObject(found) && Array.isArray(found.relays)) return found.relays.filter((u): u is string => typeof u === "string");
    }
    return [];
  }

  /// The ways a workspace turned off (its `ways_off`: relays, `lan`, `tailnet`, `direct`), as its stations keep them,
  /// else as its members' `/v1/me` name them: none of its stations reached that way (mesh.ts `Mesh.link`).
  workspaceOff(workspace: string): string[] {
    const kept = this.#core.data.record("ways", workspace);
    if (isObject(kept) && Array.isArray(kept.off)) return kept.off.filter((u): u is string => typeof u === "string");
    for (const account of this.#core.accounts.list()) {
      const me = this.#meOf(account.sub);
      const found = (isObject(me) && Array.isArray(me.workspaces) ? me.workspaces : []).find((w) => isObject(w) && w.id === workspace);
      if (isObject(found)) return Array.isArray(found.ways_off) ? found.ways_off.filter((u): u is string => typeof u === "string") : [];
    }
    return [];
  }

  /// This device's member credential for a workspace, kept on the device: what gets it into the workspace's stations
  /// with no still.fail cloud on the way. Kept, it serves until it runs out; a day old, a new one is asked for beside its
  /// use, for the next; when none is kept or a station refused it (`fresh`), one is asked for and waited on. `main`:
  /// the mesh's device key, when the mesh is up (another key's are kept apart).
  /// `claim`: the device's base key's word that `device` is its own endpoint (lock.ts), told to the cloud with the ask
  /// (it lists the devices for a lock's owner to check) and to the station with the credential.
  credential(workspace: string, device: string, fresh: boolean, main: string | null, claim: LockClaim | null = null): Effect.Effect<Credential, CoreError> {
    const entries = claim === null ? null : (this.carry?.(workspace) ?? null);
    // (both, only as they fit a station's head together: the entries then, which a station that has not heard of this
    // device yet needs to let it in at all)
    const chain = claim === null ? null : (this.carryPerson?.(workspace) ?? null);
    const person = chain !== null && entries !== null && JSON.stringify(entries).length + JSON.stringify(chain).length > CARRY_BYTES ? null : chain;
    // (and what the device is: the station lists it for the lock's owner, as the cloud did from the ask)
    const about = { kind: this.#core.host.appKeys ? "app" : "web", label: prefs.deviceName(this.#core.data) ?? "" };
    const claimed = (c: Credential): Credential => (claim === null ? c : { ...c, lock: { ...claim, ...about, ...(entries ? { entries } : {}), ...(person ? { person } : {}) } });
    return Effect.map(this.#credential(workspace, device, fresh, main, claim), claimed);
  }

  #credential(workspace: string, device: string, fresh: boolean, main: string | null, claim: LockClaim | null): Effect.Effect<Credential, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const core = this.#core;
      const sub = yield* this.owner(workspace);
      const key = `${CREDENTIAL_KEY}/${sub}/${workspace}`;
      const othersKey = `${key}/${CREDENTIAL_OTHERS}`;
      const other = main !== null && main !== device;
      const targetKey = other ? othersKey : key;
      const now = core.host.nowMs() / 1000;
      const removed = this.#removed.get(key) ?? 0;
      const sid = core.accounts.sessionId(sub);
      const snap = core.data.accountSessionSnapshot([sub]);
      const stillSignedIn = () =>
        !core.data.accountSignedOutSince(snap) &&
        (this.#removed.get(key) ?? 0) === removed &&
        core.accounts.list().some((a) => a.sub === sub) &&
        core.accounts.sessionId(sub) === sid;
      const read = (k: string) => Effect.map(Effect.orElseSucceed(core.host.storageGet(k), () => null), parseJson);
      const readOthers = Effect.map(read(othersKey), (raw) => {
        if (!Array.isArray(raw)) return [];
        const parsed = raw.map(readKept);
        return parsed.every((k) => k !== null) ? (parsed as KeptCredential[]) : [];
      });
      const allowLegacy = !this.#replacedUnverified.has(sub);
      const matchesSession = (k: KeptCredential | null): KeptCredential | null =>
        k && (k.session === sid || (k.session === undefined && allowLegacy)) ? k : null;
      let keptOne: KeptCredential | null;
      if (other) {
        keptOne = this.#isPendingCredentialDelete(othersKey)
          ? null
          : matchesSession((yield* readOthers).find((k) => k.device === device) ?? null);
      } else {
        const k = this.#isPendingCredentialDelete(key) ? null : readKept(yield* read(key));
        keptOne = k && k.device === device ? matchesSession(k) : null;
      }
      if (!stillSignedIn()) return yield* Effect.fail(CoreError.signedOut(t("core-misc.account.none")));
      const kept: Credential | null =
        keptOne && keptOne.expires_at > now + 60 && !fresh && !this.#isPendingCredentialDelete(targetKey)
          ? strip(keptOne)
          : null;
      if (kept && now - kept.issued_at < CREDENTIAL_FOR_S) return kept;
      const said = claim === null ? undefined : { base: claim.device, proof: claim.proof, kind: core.host.appKeys ? "app" : "web", label: prefs.deviceName(core.data) ?? "" };
      const keeping = this.#keepingOf(key);
      const turn = this.#askTurnOf(sub);
      const self = this;
      const cooled = () => core.host.nowMs() < (this.#credentialBackoff.get(sub) ?? 0);
      // (a few asks of the account's out at once, and none while the cloud said too many: the rest wait their turn, then
      // fail as the cloud would have, asking nothing)
      const asked = turn.withPermits(1)(
        Effect.suspend(() => {
          if (cooled()) return Effect.fail(cloudError("rate_limited", 429));
          return core.provider.credential(sub, workspace, device, said).pipe(
            // (one answered after another of the same turn was refused leaves its cool-down as it is: the minute is used up all
            // the same)
            Effect.tap(() => Effect.sync(() => {
              if (!cooled()) self.#credentialBackoff.delete(sub);
            })),
            Effect.tapError((e) => Effect.sync(() => {
              if (e.status === 429) self.#credentialBackoff.set(sub, core.host.nowMs() + CREDENTIAL_429_COOLDOWN_MS);
            })),
          );
        }),
      );
      const ask = Effect.gen(function* () {
        const c = yield* asked;
        if (!stillSignedIn()) return yield* Effect.fail(CoreError.signedOut(t("core-misc.account.none")));
        const k: KeptCredential = sid.length > 0 ? { device, session: sid, ...c } : { device, ...c };
        // (the keeping takes turns of its own, apart from the asks': a write waits on no ask)
        yield* keeping.withPermits(1)(Effect.gen(function* () {
          if (!stillSignedIn()) return;
          const targetKey = other ? othersKey : key;
          let payload: Uint8Array;
          if (other) {
            // If `othersKey` is marked pending delete, start from an empty list so stale signed-out devices are never kept.
            const prevOthers = self.#isPendingCredentialDelete(othersKey)
              ? []
              : (yield* readOthers).filter((o) => o.session === undefined || o.session === sid);
            const others = [k, ...prevOthers.filter((o) => o.device !== device)].slice(0, CREDENTIAL_OTHERS_KEPT);
            payload = toJsonBytes(others);
          } else payload = toJsonBytes(k);
          const savedBefore = self.#credSaved.get(targetKey) ?? 0;
          const saved = yield* Effect.result(core.host.storageSet(targetKey, payload));
          // Re-verify login, session & removal generation AFTER async storageSet returns so a write started before
          // sign-out or in-place re-login can never bump #credSaved, record accountSessions, or leave stale bytes.
          if (saved._tag === "Success") {
            if (stillSignedIn()) {
              self.#credSaved.set(targetKey, savedBefore + 1);
              self.#credSavedSession.set(targetKey, sid);
              self.#removePendingCredentialDelete(targetKey);
              self.#rememberCredentialWorkspace(sub, workspace);
            } else if ((self.#credSaved.get(targetKey) ?? 0) === savedBefore) {
              const del = yield* Effect.result(core.host.storageDelete(targetKey));
              if (del._tag === "Failure") self.#addPendingCredentialDeletes([targetKey]);
            }
          }
        }));
        if (!stillSignedIn()) return yield* Effect.fail(CoreError.signedOut(t("core-misc.account.none")));
        return c;
      });
      // One ask out at a time for a device's credential, which every dial wanting it meanwhile waits on: a device
      // dialling its workspace's stations at once asked once a station (the locks' end to end, 2026-11-15: 23 of an
      // account's 187 requests in a minute, in pairs of the same millisecond). It runs apart from those waiting, so one
      // of them interrupted ends nobody else's. Scoped by account login generation, removal count, and persistent
      // session ID so a re-sign-in (including in-place re-login) never coalesces onto an earlier session's ask.
      const k = `${device}/${key}#${core.data.accountGen(sub)}:${removed}:${sid}`;
      const once = Effect.suspend(() => {
        const out = this.#asking.get(k);
        if (out) return Deferred.await(out);
        const answered = Deferred.makeUnsafe<Credential, CoreError>();
        this.#asking.set(k, answered);
        core.runner.fork(Effect.flatMap(Effect.exit(ask), (exit) => Effect.sync(() => {
          if (this.#asking.get(k) === answered) this.#asking.delete(k);
          Deferred.doneUnsafe(answered, exit);
        })));
        return Deferred.await(answered);
      });
      // A day old and still good: it serves now, and the new one is asked for beside it, for the next. Asked first, every
      // dial waited on still.fail cloud once a day, far from a phone in China (2026-10-30).
      // While the cloud said too many, it serves alone.
      if (kept) {
        if (!stillSignedIn() || this.#isPendingCredentialDelete(targetKey)) return yield* Effect.fail(CoreError.signedOut(t("core-misc.account.none")));
        if (!this.#asking.has(k) && !cooled()) core.runner.fork(Effect.ignore(once, { log: "Unhandled", message: "credential renewed" }));
        return kept;
      }
      if (!this.#asking.has(k) && cooled()) return yield* Effect.fail(cloudError("rate_limited", 429));
      const freshCred = yield* once;
      if (!stillSignedIn()) return yield* Effect.fail(CoreError.signedOut(t("core-misc.account.none")));
      return freshCred;
    });
  }

  #askTurnOf(sub: string): ReturnType<typeof Semaphore.makeUnsafe> {
    let turn = this.#askTurn.get(sub);
    if (turn === undefined) this.#askTurn.set(sub, (turn = Semaphore.makeUnsafe(CREDENTIAL_ASK_CONCURRENCY)));
    return turn;
  }

  #keepingOf(key: string): ReturnType<typeof Semaphore.makeUnsafe> {
    let turn = this.#keeping.get(key);
    if (turn === undefined) this.#keeping.set(key, (turn = Semaphore.makeUnsafe(1)));
    return turn;
  }

  /// Gives this device's push registration (as kept) to the signed-in accounts that do not have it yet.
  pushRegistered(): Effect.Effect<null, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const core = this.#core;
      // A provider that delivers pushes its own way (Comma: its app's) is given none.
      if (!core.provider.supports("push")) return null;
      const raw = parseJson(yield* Effect.orElseSucceed(core.host.storageGet(PUSH_KEY), () => null));
      if (!isObject(raw) || !("registration" in raw)) return null;
      // (a console's origin takes no push registration)
      const accounts = core.accounts.list().filter((a) => !this.#isConsole(a.sub));
      let withSubs = (Array.isArray(raw.with) ? raw.with : []).filter((s): s is string => typeof s === "string" && accounts.some((a) => a.sub === s));
      let lang = typeof raw.lang === "string" ? raw.lang : null;
      const code = current();
      // What it shows of notices (which kinds, whether what was said: the cloud makes each push so) changed since it
      // was given, or its language: given again to every account.
      const shows = core.attention?.attend.shows() ?? null;
      if (lang !== code || !equal(raw.shows ?? null, shows)) {
        withSubs = [];
        lang = code;
      }
      const registration = raw.registration;
      if (isObject(registration)) {
        registration.lang = code;
        if (shows) Object.assign(registration, shows);
      }
      let failed: CoreError | null = null;
      for (const account of accounts.filter((a) => !withSubs.includes(a.sub))) {
        const sent = yield* Effect.result(core.provider.request(account.sub, "POST", "/v1/push", registration));
        if (sent._tag === "Success") withSubs.push(account.sub);
        else failed = sent.failure;
      }
      yield* Effect.ignore(core.host.storageSet(PUSH_KEY, toJsonBytes({ registration, with: withSubs, lang, shows })), { log: "Unhandled", message: "push registration kept" });
      if (failed) return yield* Effect.fail(failed);
      return null;
    });
  }

  /// Cleans credentials, stale in-memory membership state, sockets, and recovery records from a previous login session
  /// when `sub` re-logged in in-place (same `sub`, new persistent `sessionId`) without going through `signOut`.
  /// Registers `#replacedUnverified` FIRST so even if reading SQLite `me` throws `SQLITE_IOERR` or `device/choice`
  /// is unloaded, legacy (no-session) credentials are immediately blocked from cache hits and cleanup retries later.
  #invalidateReplacedSession(sub: string, newSid: string): void {
    const core = this.#core;
    const firstForSession = this.#replacedUnverified.get(sub) !== newSid;
    this.#replacedUnverified.set(sub, newSid);
    if (firstForSession) {
      this.#askTurn.delete(sub);
      this.#credentialBackoff.delete(sub);
    }
    const prevLive = this.#liveMe.get(sub);
    const wsIds = new Set<string>();
    let meReadFailed = false;
    let diskMe: unknown;
    try {
      diskMe = core.data.record("me", sub);
    } catch {
      meReadFailed = true;
    }
    for (const src of [prevLive?.me, diskMe]) {
      for (const w of isObject(src) && Array.isArray(src.workspaces) ? src.workspaces : []) {
        if (isObject(w) && typeof w.id === "string") wsIds.add(w.id);
      }
    }
    if (prevLive !== undefined && prevLive.sid !== newSid) {
      this.#liveMe.delete(sub);
      this.#persistingLiveMe.delete(sub);
      core.data.notifyAccountRecord(sub, "me");
    }
    if (this.#notBeta.get(sub)?.sid !== newSid) this.#notBeta.delete(sub);
    if (this.#persistedMe.get(sub)?.sid !== newSid) this.#persistedMe.delete(sub);
    if (this.#mesSid.get(sub) !== newSid) {
      this.mes.delete(sub);
      this.#mesSid.delete(sub);
    }
    const oldSock = this.#sockets.get(sub);
    if (oldSock !== undefined && oldSock.sid !== newSid) {
      core.runner.interrupt(oldSock.fiber as Fiber.Fiber<unknown, unknown>);
      this.#sockets.delete(sub);
      core.status.socketUp(sub);
      if (!core.runner.closed && !core.data.isDeferred(sub)) {
        this.#sockets.set(sub, { fiber: core.runner.fork(this.#follow(sub, newSid)), sid: newSid });
      }
    }
    const pendingSessions = this.#readSessionMap("pendingMeSessions");
    if ((pendingSessions[sub] ?? "") !== newSid) {
      this.#clearPendingMe(sub);
    }
    const indexed = core.data.device.get("choice", `credWorkspaces/${sub}`);
    if (Array.isArray(indexed)) {
      for (const w of indexed) if (typeof w === "string" && w.length > 0) wsIds.add(w);
    }
    const cachedOwners = core.data.device.get("choice", "workspaceOwners");
    if (isObject(cachedOwners)) {
      for (const [ws, owner] of Object.entries(cachedOwners)) {
        if (owner === sub) wsIds.add(ws);
      }
    }
    const pendingVerifyKeys: string[] = [];
    for (const ws of wsIds) {
      const key = `${CREDENTIAL_KEY}/${sub}/${ws}`;
      const othersKey = `${key}/${CREDENTIAL_OTHERS}`;
      if (this.#credSavedSession.get(key) !== newSid) pendingVerifyKeys.push(key);
      if (this.#credSavedSession.get(othersKey) !== newSid) pendingVerifyKeys.push(othersKey);
    }
    // Persist pending-delete guards BEFORE async storageGet/storageDelete so a transient read failure on an old
    // legacy (no-session) credential blocks cache hits and preserves retry intent.
    this.#addPendingCredentialDeletes(pendingVerifyKeys);
    const incomplete = meReadFailed || core.data.isDeferred(sub) || this.#meUnreadable(sub) || core.data.device.isUnloaded("choice");
    if (!incomplete) {
      this.#replacedUnverified.delete(sub);
      const recordedSid = this.#readSessionMap("accountSessions")[sub] ?? "";
      if (recordedSid !== newSid) {
        core.data.device.put("choice", `credWorkspaces/${sub}`, undefined);
        this.#recordAccountSession(sub);
      }
    }
    for (const ws of wsIds) {
      const key = `${CREDENTIAL_KEY}/${sub}/${ws}`;
      const othersKey = `${key}/${CREDENTIAL_OTHERS}`;
      const needKey = this.#credSavedSession.get(key) !== newSid;
      const needOthers = this.#credSavedSession.get(othersKey) !== newSid;
      if (firstForSession) {
        this.#removed.set(key, (this.#removed.get(key) ?? 0) + 1);
      }
      if (!needKey && !needOthers) continue;
      const removing = Effect.gen({ self: this }, function* () {
        const curRes = yield* Effect.result(core.host.storageGet(key));
        if (curRes._tag === "Success") {
          const curRaw = curRes.success;
          if (curRaw === null) {
            this.#removePendingCredentialDelete(key);
          } else {
            const curKept = readKept(parseJson(curRaw));
            if (curKept?.session === newSid) {
              this.#removePendingCredentialDelete(key);
            } else {
              const del = yield* Effect.result(core.host.storageDelete(key));
              if (del._tag === "Success") this.#removePendingCredentialDelete(key);
            }
          }
        }
        const othersRes = yield* Effect.result(core.host.storageGet(othersKey));
        if (othersRes._tag === "Success") {
          const othersRaw = othersRes.success;
          if (othersRaw === null) {
            this.#removePendingCredentialDelete(othersKey);
          } else {
            const parsed = parseJson(othersRaw);
            const list = Array.isArray(parsed) ? parsed.map(readKept).filter((x): x is KeptCredential => x !== null) : [];
            const keep = list.filter((x) => x.session === newSid);
            if (keep.length === 0) {
              const del = yield* Effect.result(core.host.storageDelete(othersKey));
              if (del._tag === "Success") this.#removePendingCredentialDelete(othersKey);
            } else if (keep.length !== list.length) {
              const wr = yield* Effect.result(core.host.storageSet(othersKey, toJsonBytes(keep)));
              if (wr._tag === "Success") this.#removePendingCredentialDelete(othersKey);
            } else {
              this.#removePendingCredentialDelete(othersKey);
            }
          }
        }
      });
      core.runner.fork(this.#keepingOf(key).withPermits(1)(removing));
    }
  }

  /// The accounts as UIs see them changed (a token refresh alone changes nothing here).
  accountsChanged(): void {
    const core = this.#core;
    if (!this.#choiceHydrated && !core.accounts.isUnloaded() && !core.data.device.isUnloaded("choice")) {
      this.#onChoiceLoaded();
    }
    const list = core.accounts.list();
    const replaced: Array<[string, string]> = [];
    const currentSubs = new Set<string>();
    for (const a of list) {
      currentSubs.add(a.sub);
      const curSid = core.accounts.sessionId(a.sub);
      const prevSid = this.#shownSessions.get(a.sub);
      if (prevSid !== undefined && prevSid !== curSid) {
        replaced.push([a.sub, curSid]);
      }
      this.#shownSessions.set(a.sub, curSid);
    }
    for (const sub of [...this.#shownSessions.keys()]) {
      if (!currentSubs.has(sub)) this.#shownSessions.delete(sub);
    }
    for (const [sub, newSid] of replaced) {
      this.#invalidateReplacedSession(sub, newSid);
    }
    if (JSON.stringify(core.shownAccounts) === JSON.stringify(list)) {
      if (replaced.length > 0) this.recomputeOwners();
      return;
    }
    const before = new Set(core.shownAccounts.map((a) => a.sub));
    core.shownAccounts = list;
    this.recomputeOwners();
    this.forgetUnreachable();
    this.syncSockets();
    // (an account gone takes its credential asks' turns and wait with it)
    for (const sub of before) {
      if (list.some((a) => a.sub === sub)) continue;
      this.#askTurn.delete(sub);
      this.#credentialBackoff.delete(sub);
    }
    // Someone signed in: their devices hear pushes too.
    core.runner.fork(Effect.ignore(this.pushRegistered(), { log: "Unhandled", message: "push registration sent" }));
  }

  // ── still.fail cloud's events ──

  /// One socket per signed-in account, for as long as it is signed in.
  syncSockets(): void {
    const core = this.#core;
    if (core.runner.closed) return;
    const wanted = core.accounts.list().map((a: AccountView) => a.sub).filter((sub) => !core.data.isDeferred(sub));
    for (const [sub, sock] of [...this.#sockets]) {
      if (wanted.includes(sub)) continue;
      core.runner.interrupt(sock.fiber as Fiber.Fiber<unknown, unknown>);
      this.#sockets.delete(sub);
      core.status.socketUp(sub);
    }
    for (const sub of wanted) {
      const sid = core.accounts.sessionId(sub);
      const cur = this.#sockets.get(sub);
      if (cur === undefined) {
        this.#sockets.set(sub, { fiber: core.runner.fork(this.#follow(sub, sid)), sid });
      } else if (cur.sid !== sid) {
        core.runner.interrupt(cur.fiber as Fiber.Fiber<unknown, unknown>);
        this.#sockets.delete(sub);
        core.status.socketUp(sub);
        this.#sockets.set(sub, { fiber: core.runner.fork(this.#follow(sub, sid)), sid });
      }
    }
  }

  /// Opens an account's events (still.fail cloud's socket, with a token good now), in the caller's scope.
  #open(sub: string) {
    return this.#core.provider.events(sub);
  }

  #onEvent(sub: string, text: string): void {
    const core = this.#core;
    const event = parseJson(text);
    if (!isObject(event)) return;
    if (event.type === "release") this.onRelease();
    else if (event.type === "relays") this.onRelayLoad(sub);
    else if (event.type === "admin" && this.#admins.has(sub)) {
      // An operator's lists changed (another operator's write, someone signed up, a report sent): those it names read
      // again, each alone; all where it names none.
      const named: unknown[] | null = Array.isArray(event.lists) ? event.lists : null;
      const lists = named !== null ? named.filter((l): l is string => typeof l === "string" && ADMIN_LISTS.includes(l)) : ADMIN_LISTS;
      // (those read only while shown: a report's own page, the operators' changes)
      if (named === null || named.includes("feedback")) this.onAdminSubList(sub, "feedback/");
      if (named === null || named.includes("audit")) this.onAdminSubList(sub, "audit");
      if (named === null || named.includes("keys")) this.onAdminSubList(sub, "keys");
      for (const list of lists) {
        core.scheduler.enqueue("cloud", `admin/${sub}/${list}`, Priority.shown, Effect.flatMap(this.adminList(sub, list), (e): Effect.Effect<void> => {
          if (e !== null && passing(e)) this.#adminAgain(sub);
          return Effect.void;
        }));
      }
    }
    // (a console's origin serves nothing of its workspaces: what they tell is not read there)
    else if (this.#isConsole(sub)) return;
    else if (event.type === "workspaces") {
      // The account's own entry of a workspace it stays in, told: in place, no request (every device of every member
      // read its `/v1/me` whole at each change of a workspace's people or stations, the locks' end to end, 2026-11-15).
      if (!this.#entered(sub, event.entry)) core.scheduler.enqueue("cloud", this.#meKey(sub), Priority.shown, this.#listed(sub));
    }
    else if (event.type === "feedback" && typeof event.workspace === "string") this.feedbackChanged(event.workspace);
    else if (event.type === "workspace" && typeof event.id === "string") {
      const owner = core.workspaces.owner(event.id);
      if (owner === null || this.hasEarlierDeferred(owner)) {
        if (this.hasUnverifiedAccounts()) this.#deferredWorkspaceSync.add(event.id);
        return;
      }
      if (sub !== owner) {
        // Never merge an event from a different account's socket (e.g. an admin socket's invitations/added delta)
        // into the owning account's view; enqueue a full authoritative reread under the owner instead.
        core.scheduler.enqueue("cloud", `workspace/${event.id}`, Priority.shown, this.#workspace(event.id));
        return;
      }
      const lock = event.lock;
      const topic = { topic: "workspace", workspace: event.id } as const;
      // Only its lock moved on, as the event says: in place, no request (the lock itself is read of the stations,
      // views/lock.ts; each entry signed had every device of its members ask for the workspace again, using up the
      // account's budget).
      if (!core.pendingAuthConfirm.has(event.id) && isObject(lock) && "head" in lock && isObject(core.data.shared(topic))) {
        const head = isObject(lock.head) ? lock.head : null;
        core.data.update(topic, (w) => {
          if (!isObject(w)) return w;
          const { locked: _, ...rest } = w;
          return { ...rest, lock: head, ...(lock.locked === true ? { locked: true } : {}) };
        });
      } else if (event.requests === true) {
        // Only its requests to be let in moved (the cloud's, which apps from before ask and drop): nothing this core
        // shows of the workspace says them (its view's `lock_requests` is held as the cloud last gave it, read by none),
        // so nothing is asked; every device of every member read the whole workspace for each.
      } else if (!this.#changedIn(sub, event.id, event)) core.scheduler.enqueue("cloud", `workspace/${event.id}`, Priority.shown, this.#workspace(event.id));
    } else if (event.type === "station" && typeof event.workspace === "string" && typeof event.id === "string" && typeof event.online === "boolean") {
      if (core.workspaces.owner(event.workspace) !== sub) return;
      // A station came online or went: in place, no request (unless workspace is pending auth confirmation, in which case force a full reread).
      const online = event.online;
      const id = event.id;
      if (core.pendingAuthConfirm.has(event.workspace)) {
        core.scheduler.enqueue("cloud", `workspace/${event.workspace}`, Priority.shown, this.#workspace(event.workspace));
      } else {
        core.data.update({ topic: "workspace", workspace: event.workspace }, (w) => {
          const station = isObject(w) && Array.isArray(w.stations) ? w.stations.find((s) => isObject(s) && s.id === id) : undefined;
          if (isObject(station)) {
            station.online = online;
            station.last_seen = Math.floor(core.host.nowMs() / 1000);
          }
          return w;
        });
      }
      // Back: tried now rather than when its wait ends (station/sync.ts OFFLINE_RETRY_MS).
      if (online) core.stations?.cameOnline(`${event.workspace}/${id}`);
      this.onReach?.();
    }
  }

  /// The account's entry of a workspace in its list, as the cloud told it (`workspaces` with `entry`, of one it stays in),
  /// put in place of the one held; false where the list held does not name that workspace (read whole then).
  #entered(sub: string, entry: unknown): boolean {
    const core = this.#core;
    const me = this.#meOf(sub);
    if (!isObject(entry) || typeof entry.id !== "string" || !isObject(me) || !Array.isArray(me.workspaces)) return false;
    const at = me.workspaces.findIndex((w) => isObject(w) && w.id === entry.id);
    if (at < 0) return false;
    const workspaces = [...me.workspaces];
    workspaces[at] = { ...(workspaces[at] as Record<string, unknown>), ...entry } as (typeof workspaces)[number];
    const updated = { ...me, workspaces };
    const db = core.data.db(sub);
    const live = this.#setLiveMe(sub, updated);
    if (db !== undefined && !db.readOnly) this.#persistLiveMe(sub, db, live);
    return true;
  }

  /// What a `workspace` event says changed of the view (cloud directory.ts `#told`), taken in place: nothing to do where
  /// the view held is that version or later (this device's own write answered with it), patched where it is the version
  /// before; false otherwise (none held, none said, a change missed: read whole then).
  #changedIn(sub: string, id: string, event: Record<string, unknown>): boolean {
    const held = this.#core.data.shared({ topic: "workspace", workspace: id });
    const [before, after] = Array.isArray(event.rev) ? event.rev : [];
    if (this.#core.pendingAuthConfirm.has(id)) return false;
    const owner = this.#core.workspaces.owner(id);
    if (sub !== owner) return false;
    const readGen = this.#core.store.authGen.workspaceAuthGen(id);
    const base = this.#confirmedBase.get(id);
    if (!base || base.owner !== owner || base.gen !== readGen) return false;
    if (!isObject(held) || typeof before !== "number" || typeof after !== "number") return false;
    if (typeof held.rev === "number" && held.rev >= after) return true;
    if (held.rev !== before) return false;
    this.#took(id, patched(held, event, after), readGen);
    return true;
  }

  /// Holds an account's `/v1/events` socket open, reconnecting with backoff, until the account signs out (the fiber
  /// is interrupted). Each open reads the account again; a socket that went silent is opened anew;
  /// one suspected as the UI comes back has another opened beside it, which takes its place once open.
  #follow(sub: string, sid: string): Effect.Effect<void, never> {
    const core = this.#core;
    const self = this;
    type Opened = { frames: Pull<string>; scope: Scope.Closeable };
    type Ev = { frame: string | null } | { broke: CoreError } | { idle: true } | { suspect: true } | { beside: Opened } | { replacementFailed: true };
    // A socket in a scope of its own inside `scope`: one replaced by another is closed alone.
    const openIn = (scope: Scope.Scope) =>
      Effect.gen(function* () {
        const own = yield* Scope.fork(scope);
        const frames = yield* Effect.provideService(self.#open(sub), Scope.Scope, own).pipe(Effect.onError(() => Scope.close(own, Exit.void)));
        return { frames, scope: own } as Opened;
      });
    // One connection of the socket: open, read until it ends; what it ends as.
    type Ended = { failed: CoreError } | { ended: string; again: boolean };
    // Whether a try to open the socket failed: one that opens after it says the device's network is back.
    let down = false;
    const connection = (wait: { ms: number }): Effect.Effect<Ended> =>
      Effect.scoped(
        Effect.gen(function* () {
          const scope = yield* Effect.scope;
          const tryAt = core.host.nowMs();
          const waiting = core.status.begin(CLOUD, t("core-misc.status.connect"), true);
          const opened = yield* Effect.result(openIn(scope).pipe(Effect.ensuring(Effect.sync(() => waiting.end()))));
          if (opened._tag === "Failure") {
            down = true;
            record(core.host, "cloud socket", () => `${sub.slice(0, 8)} open failed after ${Math.round(core.host.nowMs() - tryAt)}ms: ${said(opened.failure.message)}`);
            return { failed: opened.failure } as Ended;
          }
          record(core.host, "cloud socket", () => `${sub.slice(0, 8)} open after ${Math.round(core.host.nowMs() - tryAt)}ms${down ? " (after a failed open: stations not reached tried now)" : ""}`);
          if (down) core.stations?.networkBack();
          down = false;
          let socket = opened.success;
          let frames = socket.frames;
          const openedAt = core.host.nowMs();
          self.onOpen();
          core.status.socketUp(sub);
          // Nothing is replayed: what changed while it was closed is read now.
          core.scheduler.enqueue("cloud", self.#meKey(sub), Priority.shown, self.#account(sub));
          let woke = false;
          let idle = false;
          let beside: Effect.Effect<Ev> | null = null;
          for (;;) {
            const racers: Effect.Effect<Ev>[] = [
              frames.take.pipe(
                Effect.map((frame): Ev => ({ frame })),
                Effect.catch((e) => Effect.succeed<Ev>({ broke: asCoreError(e) })),
              ),
            ];
            racers.push(Effect.sleep(SOCKET_IDLE_MS).pipe(Effect.as<Ev>({ idle: true })));
            racers.push(beside ?? core.wakes.until((w) => w.suspectsConnections()).pipe(Effect.as<Ev>({ suspect: true })));
            const ev = yield* Effect.raceAllFirst(racers);
            if ("frame" in ev) {
              if (ev.frame === null) break;
              if (ev.frame !== "pong") self.#onEvent(sub, ev.frame);
            } else if ("broke" in ev) {
              const m = ev.broke.message;
              woke = m === GONE || m === NETWORK || m === t("core-misc.wake.gone") || m === t("core-misc.wake.network");
              break;
            } else if ("idle" in ev) {
              idle = true;
              break;
            } else if ("suspect" in ev) {
              // Another opened beside it; the old one stays watched meanwhile.
              const opening = yield* Effect.forkIn(
                openIn(scope).pipe(
                  Effect.map((f): Ev => ({ beside: f })),
                  Effect.catch(() => Effect.succeed<Ev>({ replacementFailed: true })),
                ),
                scope,
              );
              beside = Fiber.join(opening);
            } else if ("replacementFailed" in ev) {
              // Keep the old socket, but listen for the next wake again.
              beside = null;
            } else {
              beside = null;
              yield* Scope.close(socket.scope, Exit.void);
              socket = ev.beside;
              frames = socket.frames;
              core.scheduler.enqueue("cloud", self.#meKey(sub), Priority.shown, self.#account(sub));
            }
          }
          if (woke || idle || core.host.nowMs() - openedAt >= 60_000) wait.ms = SOCKET_RETRY_MS;
          record(core.host, "cloud socket", () => `${sub.slice(0, 8)} ended after ${Math.round((core.host.nowMs() - openedAt) / 1000)}s: ${idle ? "silent" : "dropped"}${woke ? " (a wake suspected it)" : ""}`);
          return { ended: idle ? t("core-misc.socket.silent") : t("core-misc.socket.dropped"), again: woke || idle } as Ended;
        }),
      );
    return Effect.gen(function* () {
      const wait = { ms: SOCKET_RETRY_MS };
      let first = true;
      for (;;) {
        const ended = yield* connection(wait);
        let down: string;
        if ("failed" in ended && first) {
          // Its first try failed: the account is read anyway, so what can be shown is.
          core.scheduler.enqueue("cloud", self.#meKey(sub), Priority.shown, self.#account(sub));
        }
        first = false;
        if ("failed" in ended) {
          if (ended.failed.code === "signed_out") {
            if (self.#sockets.get(sub)?.sid === sid) {
              self.#sockets.delete(sub);
              core.status.socketUp(sub);
            }
            return;
          }
          down = ended.failed.message;
        } else {
          down = ended.ended;
          // Taken for gone as the UI came back, or silent: opened again at once.
          if (ended.again) continue;
        }
        core.status.socketDown(sub, down, core.host.nowMs() + wait.ms);
        // A UI back after being away wants it now: the wait starts over.
        const woken = yield* Effect.raceFirst(Effect.sleep(wait.ms).pipe(Effect.as(false)), core.wakes.next.pipe(Effect.as(true)));
        wait.ms = woken ? SOCKET_RETRY_MS : Math.min(wait.ms * 2, SOCKET_RETRY_MAX_MS);
      }
    });
  }
}

type KeptCredential = Credential & { device: string; session?: string };

/// A workspace's view, as a write answered with it or its event read whole.
function viewIn(v: unknown): Record<string, unknown> | null {
  return isObject(v) && typeof v.id === "string" && Array.isArray(v.members) ? v : null;
}

/// A view's lists, each by the key of its entries.
const KEYED: Record<string, string> = { members: "sub", stations: "id", rigs: "id", invitations: "id", added: "email" };

/// A view held made the version `after` by what its event said: `set` its fields put, `unset` those gone, `put` its
/// lists' entries put (over the one held of the same key, what the device knows of it besides staying: a station's
/// `online`), `gone` their keys taken out. A new object; the view held is shared, never written.
function patched(held: Record<string, unknown>, event: Record<string, unknown>, after: number): Record<string, unknown> {
  const next: Record<string, unknown> = { ...held, ...(isObject(event.set) ? event.set : {}), rev: after };
  for (const k of Array.isArray(event.unset) ? event.unset : []) if (typeof k === "string") delete next[k];
  for (const [list, key] of Object.entries(KEYED)) {
    const put = isObject(event.put) && Array.isArray(event.put[list]) ? event.put[list].filter(isObject) : [];
    const gone = new Set(isObject(event.gone) && Array.isArray(event.gone[list]) ? event.gone[list] : []);
    if (put.length === 0 && gone.size === 0) continue;
    const fresh = new Map(put.map((e) => [e[key], e]));
    const items = (Array.isArray(held[list]) ? held[list] : []).flatMap((e) => {
      if (!isObject(e)) return [e];
      if (gone.has(e[key])) return [];
      const p = fresh.get(e[key]);
      if (p === undefined) return [e];
      fresh.delete(e[key]);
      return [{ ...e, ...p }];
    });
    items.push(...fresh.values());
    if (list === "rigs" && items.length === 0) delete next.rigs;
    else next[list] = items;
  }
  return next;
}

function readKept(v: unknown): KeptCredential | null {
  if (!isObject(v) || typeof v.device !== "string") return null;
  const c = readCredential(v);
  if (typeof c === "string") return null;
  return typeof v.session === "string" && v.session.length > 0 ? { ...c, device: v.device, session: v.session } : { ...c, device: v.device };
}

function strip(k: KeptCredential): Credential {
  return { credential: k.credential, issued_at: k.issued_at, expires_at: k.expires_at, relay_url: k.relay_url };
}

/// A failure that may pass if asked again: no answer, or still.fail cloud's own trouble (a 5xx, 429), not the account's.
function passing(e: CoreError): boolean {
  return e.code !== "signed_out" && (e.status === undefined || e.status === 429 || e.status >= 500);
}
