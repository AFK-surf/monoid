import { modelSpeed, type ModelSpeed } from "../../../client/core-ts/src/model-speed.ts";
// Sessions and chats as people make, change, archive and delete them (the Rust station's hub.rs: new_session, open_chat,
// add_to_thread, say, bind_single, configure, archive, archive_chat, auto_archive, delete_session,
// continue_machine_session). Archiving here is the record (archived, hidden) and what goes with it (the process ends,
// other stations are told); packing an archived session's files is the hub's ColdStorage.
import { COPY as PRESET_COPY_FILE, NoPreset, type PresetCopy, keepCopy, presetRefusal } from "./presets.ts";
import { createHash } from "node:crypto";
import { copyFile, lstat, mkdir, readdir, readFile, realpath, rename, rm, stat } from "node:fs/promises";
import { basename, dirname, join, relative, sep } from "node:path";
import { DISK_LOW_BYTES } from "../ops/disk.ts";
import { PlaceRefused } from "../ops/places.ts";
import { log } from "../ops/log.ts";
import { tr, type Lang, stationLang } from "../ops/i18n.ts";
import { clean, inside, samePath, within } from "../ops/paths.ts";
import { RELIEVE_FULL_EVERY_MS, pruneRepoWorktrees, relieveOrphanTranscripts, treeBytes } from "../ops/storage.ts";
import { IDLE_MEASURED_MAX, emptyUpkeepState, patchUpkeepState } from "../ops/upkeep-state.ts";
import { REPO_GIT_TIMEOUT_MS, type RepoGitRun, isProcessFile, pruneRepoBranchesIn, runRepoGit } from "../ops/repo-branches.ts";
import { checkContext } from "./context-cap.ts";
import { type MachineSession, type Roots, ROLLOUT_DEPTH, ROLLOUT_ENTRIES, extension, rolloutOf } from "../read/machine.ts";
import { usageNow } from "../read/usage.ts";
import { homesFirst, sessionPlaces, sharedTranscripts } from "../read/transcript.ts";
import { transcriptPathsSoon, transcriptSourcesSoon } from "../read/transcript-soon.ts";
import { forgetMarksSoon, marksDir } from "../read/transcripts.ts";
import { walkBounded, yieldLoop } from "../ops/walk.ts";
import { ARCHIVED_WORKSPACE_BATCH, AUTO, type ArchivedWorkspace, type Attachment, IDLE_UNARCHIVED_BATCH, MANUAL, type Quote, STILLFAIL_SURFACE, type ThreadRow, type WorkOf, type ArchiveLook, type SessionRow, recentConversations } from "../store/store.ts";
import { sessionBindingsReady } from "../store/session-bindings-index.ts";
import { archiveMarksReady } from "../store/archive-mark-index.ts";
import type { SessionChange } from "./accounts.ts";
import { runChanged, runShown } from "./run-change.ts";
import { collectWorktreeRegistrations, jsonlFilesSoon, packed, removeWorktreeRegistrations, unlockWorktrees, withLock } from "./archive.ts";
import { agentHomes } from "./agent-home.ts";
import { safeUrl } from "./clones.ts";
import { roomOfSoon } from "./footprint.ts";
import { noProfileHere, type Profile, type Runtime, runs, runtimeNamed, runtimeTitle } from "./config.ts";
import { billedPerUse, FAST_RUNTIMES } from "../agents/profiles.ts";
import { CLIENT_KEY_KEPT_MS, type Hub, connectOf, newChatKey, newSingleSessionKey, newToken } from "./hub.ts";
import { INTERNAL_CHANNEL, INTERNAL_CONNECT, chatKey, chatWorkspace } from "./internal.ts";
import { STATION_AUTHOR } from "../store/rows.ts";

/// A session of its own, talked to in the station's chat.
export type NewChat = {
  runtime: Runtime;
  profile?: string | null;
  profiles?: string[] | null;
  model?: string | null;
  effort?: string | null;
  fast?: boolean | null;
  speed?: ModelSpeed | null;
  tui?: boolean;
  /// The most context it runs with, in tokens (sessions/context-cap.ts); none: the model's whole window.
  context?: number | null;
  title?: string | null;
  createdBy: string;
  /// The key the asking client knows it by until it is made (`clientKey`): the sidebar's rows say it for a while.
  clientKey?: string | null;
  /// The workspace its chat is in (the asker's, or the opening session's); absent: the station's home one.
  ws?: string | null;
  /// The preset it is opened with (presets.ts), its copy kept with it; or the copy itself, another station's preset as
  /// the app read it there (`presetCopy`).
  preset?: string | null;
  presetCopy?: PresetCopy | null;
};

function checkSpeed(runtime: string, speed: ModelSpeed | null | undefined, supportsUltrafast: boolean, lang: Lang): void {
  if (speed == null) return;
  if (modelSpeed(speed) === null || !FAST_RUNTIMES.includes(runtime as Runtime)) throw new Error(tr(lang, "station.speed.invalid"));
  if (speed === "ultrafast" && (runtime !== "codex" || !supportsUltrafast)) {
    throw new Error(tr(lang, "station.speed.ultrafast_unavailable"));
  }
}

const trimmed = (v: string | null | undefined) => {
  const t = v?.trim();
  return t ? t : null;
};

/// Points a single-session connect at a session: an existing one (any session on the same runtime, whichever connect
/// started it) or, with null, a new empty one. The bound session's key.
export async function bindSingle(hub: Hub, connectId: string, target: string | null, title: string | null, createdBy: string | null): Promise<string> {
  return hub.oneSingle(connectId, () => bindSingleInTurn(hub, connectId, target, title, createdBy));
}

async function bindSingleInTurn(hub: Hub, connectId: string, target: string | null, title: string | null, createdBy: string | null): Promise<string> {
  const config = hub.config();
  const connect = connectOf(config, connectId);
  if (connect.mode !== "single-session") throw new Error(`connect ${connectId} is not single-session`);
  if (target === null) {
    const key = newSingleSessionKey(connect.id);
    await hub.createSession(config, key, connect, "all", null, trimmed(title), createdBy);
    hub.store.setBinding(connect.id, key);
    return key;
  }
  const row = hub.store.getSession(target);
  if (!row) throw new Error(`unknown session ${target}`);
  if (row.runtime !== connect.bind.runtime) throw new Error(`session ${target} runs ${row.runtime}, the connect runs ${connect.bind.runtime}`);
  // A connect's sessions are its workspace's chats: none of another workspace.
  const home = hub.workspaces()[0] ?? null;
  if (home !== null && hub.wsOf(row) !== (connect.workspace ?? home)) throw new Error(`session ${target} is in another workspace than the connect`);
  hub.store.setBinding(connect.id, target);
  log.info("hub", "single-session connect rebound", { connect: connect.id, session: target });
  return target;
}

/// Ensures the conversation's home chat exists (idempotent, §3.3): returns the existing home chat if present,
/// otherwise creates it with `home = conversationOf(session)`, title from the anchor's session title, and all
/// conversation members that have not left their birth thread (or `[session]` if all have left).
export function ensureConversationChat(hub: Hub, session: string, createdBy: string, title: string | null): ThreadRow {
  if (!hub.internal) throw new Error("still.fail chat is not available");
  const row = hub.store.getSession(session);
  if (!row) throw new Error(`unknown session ${session}`);
  const existing = hub.store.homeChat(session);
  if (existing !== null) return existing;
  const anchor = hub.store.conversationOf(session);
  const anchorRow = hub.store.getSession(anchor) ?? row;
  const name = title ?? anchorRow.title;
  const thread = hub.store.openThreadOf(STILLFAIL_SURFACE, INTERNAL_CHANNEL, hub.nextTs(), name, createdBy, anchor);
  const active = hub.store.activeConversationMembers(anchor, session);
  const ordered = active.includes(anchor) ? [anchor, ...active.filter((m) => m !== anchor)] : active;
  for (const member of ordered) {
    hub.store.joinThread(thread.id, member, INTERNAL_CONNECT);
  }
  return thread;
}

/// Opens a chat on the station's pages with a session in it. More sessions can join it later (addToThread).
export function openChat(hub: Hub, session: string, createdBy: string, title: string | null): ThreadRow {
  if (!hub.internal) throw new Error("still.fail chat is not available");
  const row = hub.store.getSession(session);
  if (!row) throw new Error(`unknown session ${session}`);
  // The first chat made with a session is its own; later ones are chats of their own (ThreadRow.home).
  const home = hub.store.homeChat(session) !== null ? null : session;
  // Its own chat keeps the name the session was given before it had one.
  const name = title ?? (home !== null ? row.title : null);
  const thread = hub.store.openThreadOf(STILLFAIL_SURFACE, INTERNAL_CHANNEL, hub.nextTs(), name, createdBy, home);
  hub.store.joinThread(thread.id, session, INTERNAL_CONNECT);
  return thread;
}

function stillfailChat(hub: Hub, thread: number): ThreadRow {
  const row = hub.store.getThread(thread);
  if (!row || row.surface !== STILLFAIL_SURFACE) throw new Error(`no still.fail chat ${thread}`);
  return row;
}

/// Brings another session into a chat on the station's pages; it hears what is said from then on.
export function addToThread(hub: Hub, thread: number, session: string) {
  stillfailChat(hub, thread);
  const row = hub.store.getSession(session);
  if (row === null) throw new Error(`unknown session ${session}`);
  // A chat is one workspace's: no session of another joins it. Outside any workspace, all are
  // the same one's.
  const there = hub.store.threadSessions(thread)[0];
  if (hub.workspaces().length > 0 && there !== undefined && hub.wsOf(there.session) !== hub.wsOf(row)) throw new Error(`session ${session} is in another workspace than the chat`);
  hub.store.joinThread(thread, session, INTERNAL_CONNECT);
}

/// A person's message in a chat on the station's pages: recorded with its quotes and files and delivered to every
/// session in the chat, like a Slack message. `client`: the app it was sent from, as it said. Its entry number.
export function say(hub: Hub, thread: number, user: string, text: string, attachments: Attachment[] = [], quotes: Quote[] = [], client: string | null = null,
  once?: { before: () => void; inserted: (n: number) => void; targets: () => string[]; workspace: string | null }): number {
  const checkChat = () => {
    stillfailChat(hub, thread);
    if (hub.store.manuallyArchived(thread)) throw new Error(tr(stationLang(), "station.chat.archived"));
  };
  checkChat();
  const before = once === undefined ? undefined : () => { once.before(); checkChat(); };
  const [n, fresh] = hub.store.insertMessage({ thread, ts: hub.nextTs(), authorKind: "person", author: user, text, attachments, quotes, client }, before, once?.inserted);
  // A different process may have used the same timestamp. It is not this keyed write and must not be delivered as it.
  if (once !== undefined && !fresh) throw new Error("message timestamp already used; retry the write");
  const sessions = once?.targets() ?? hub.store.threadSessions(thread).map((m) => m.session);
  hub.deliver(thread, n, sessions, text, once === undefined ? undefined : { workspace: once.workspace });
  return n;
}

/// A session of its own, talked to in the station's chat: the runtime, model and effort chosen by whoever starts it
/// rather than a connect's, and the profile: one given keeps it there; else the pool picks one with the model on. Only
/// the profiles allowed in its workspace.
export async function newSession(hub: Hub, options: NewChat, lang: Lang = stationLang()): Promise<[string, ThreadRow]> {
  const client = trimmed(options.clientKey);
  // A reply can be lost when the station restarts. The same request must find the rows already made, including when
  // the process stopped between inserting the session, the thread and its membership.
  const key = client === null ? newChatKey() : chatKey(`c-${createHash("sha256").update(JSON.stringify([options.ws ?? null, options.createdBy, client])).digest("hex").slice(0, 32)}`, (k) => hub.store.getSession(k) !== null);
  // The same request again while this one waits on the disk (a retry): it waits for this one, then finds what it made,
  // picking no account and writing nothing.
  return client === null ? sessionMade(hub, key, client, options, lang) : oneByKey(hub, key, () => sessionMade(hub, key, client, options, lang));
}

/// The new sessions being made by their keys, of each hub (`newSession`).
const making = new WeakMap<Hub, Map<string, Promise<unknown>>>();
function oneByKey<T>(hub: Hub, key: string, f: () => Promise<T>): Promise<T> {
  let mine = making.get(hub);
  if (mine === undefined) making.set(hub, (mine = new Map()));
  const run = (mine.get(key) ?? Promise.resolve()).then(f, f);
  const done = run.then(() => {}, () => {});
  mine.set(key, done);
  void done.then(() => {
    if (mine.get(key) === done) mine.delete(key);
  });
  return run;
}

async function sessionMade(hub: Hub, key: string, client: string | null, options: NewChat, lang: Lang): Promise<[string, ThreadRow]> {
  const config = hub.config();
  const made = (): [string, ThreadRow] | null => {
    const existing = hub.store.getSession(key);
    if (existing === null) return null;
    if (client !== null) hub.clientKeysMade.set(key, [client, hub.now()]);
    const thread = hub.store.homeChat(key) ?? openChat(hub, key, options.createdBy, existing.title);
    hub.store.joinThread(thread.id, key, INTERNAL_CONNECT);
    return [key, thread];
  };
  const before = made();
  if (before !== null) return before;
  const runtime = options.runtime;
  const all = config.profiles.filter((p) => p.runtimes.includes(runtime));
  if (all.length === 0) throw new Error(`no ${runtime} profile configured`);
  const rawList = Array.isArray(options.profiles) ? [...new Set(options.profiles.map((x) => x.trim()).filter((x) => x !== ""))] : [];
  const wantedProfiles = rawList.length > 0 ? rawList : options.profile ? [options.profile] : null;
  if (wantedProfiles !== null) {
    for (const id of wantedProfiles) {
      const requested = all.find((p) => p.id === id);
      if (requested?.enabled === false) throw new Error(tr(lang, "station.profile.disabled", { profile: requested.name }));
    }
  }
  const here = new Set(hub.profilesIn(options.ws ?? null).map((p) => p.id));
  const profiles = all.filter((p) => here.has(p.id));
  if (profiles.length === 0) throw new Error(noProfileHere(lang, runtime, all));
  const model = trimmed(options.model);
  // (what its preset binds it to, held here too: an app from before or another way in changes none of it)
  const preset = trimmed(options.preset);
  const bound = options.presetCopy ?? (preset !== null ? await hub.presets.get(options.ws ?? hub.workspaces()[0] ?? null, preset) : null);
  const refused = bound === null ? null : presetRefusal(bound, hub.station(), { runtime, model }, lang);
  if (refused !== null) throw new Error(refused);
  // (one that names no preset of its workspace makes no chat, nor its directory)
  if (!options.presetCopy && preset !== null && bound === null) throw new NoPreset(preset);
  const pickAccount = (candidates: Profile[]) => {
    if (options.speed !== "ultrafast") return hub.accounts.pick(candidates, model, true);
    const eligible = candidates.filter((p) => hub.accounts.supportsUltrafast(p, model));
    checkSpeed(runtime, options.speed, eligible.length > 0, lang);
    return hub.accounts.pick(eligible, model, true);
  };
  let profile;
  let candidatePool: Profile[] = profiles;
  if (wantedProfiles !== null) {
    const subset = [];
    for (const id of wantedProfiles) {
      const found = profiles.find((p) => p.id === id);
      if (!found) {
        const there = all.find((p) => p.id === id);
        throw new Error(there ? tr(lang, "station.profile.notHere", { profile: there.name }) : `no ${runtime} profile ${id}`);
      }
      if (model !== null && !runs(found, model)) throw new Error(tr(lang, "station.profile.modelOff", { profile: found.name, model }));
      subset.push(found);
    }
    candidatePool = subset;
    profile = subset.length === 1 ? subset[0]! : pickAccount(subset);
  } else profile = pickAccount(profiles);
  const effort = options.effort ? options.effort : null;
  checkSpeed(runtime, options.speed, options.speed === "ultrafast" && hub.accounts.supportsUltrafast(profile, model), lang);
  checkContext(runtime, options.context, lang);
  if (effort !== null) {
    const allowed = hub.accounts.modelEfforts(runtime, model, wantedProfiles, (p) => here.has(p.id));
    if (!allowed.includes(effort)) throw new Error(`effort must be one of ${allowed.join(", ")}`);
  }
  const workspace = chatWorkspace(config.dataDir, key);
  await mkdir(workspace, { recursive: true });
  // (before its rows: one that names no preset of its workspace makes no chat)
  if (options.presetCopy) await keepCopy(workspace, options.presetCopy);
  else if (preset !== null) await hub.presets.keepFor(workspace, options.ws ?? hub.workspaces()[0] ?? null, preset);
  await mkdir(join(config.dataDir, "repos"), { recursive: true });
  const now = hub.now();
  // Known before its rows are (their events can reach the client before this answers), and for a while after.
  if (client !== null) {
    for (const [k, [, at]] of hub.clientKeysMade) if (now - at >= CLIENT_KEY_KEPT_MS) hub.clientKeysMade.delete(k);
    hub.clientKeysMade.set(key, [Array.from(client).slice(0, 120).join(""), now]);
  }
  const title = trimmed(options.title);
  hub.store.insertSession({
    key,
    connect: INTERNAL_CONNECT,
    scope: "all",
    title,
    createdBy: options.createdBy,
    runtime,
    profile: profile.id,
    profilePinned: wantedProfiles?.length === 1,
    profiles: wantedProfiles,
    model: model ?? profile.model ?? null,
    effort,
    fast: FAST_RUNTIMES.includes(runtime) ? (options.speed ? options.speed !== "standard" : options.fast ?? null) : null,
    tui: runtime === "claude" && options.tui === true,
    speed: options.speed ?? null,
    context: options.context ?? null,
    workspace,
    cwd: null,
    runtimeSessionId: null,
    token: newToken(),
    createdAt: now,
    lastActiveAt: now,
    ws: options.ws ?? null,
  });
  log.info("hub", "session created", { session: key, connect: INTERNAL_CONNECT, runtime, profile: profile.id, model, preset });
  if (wantedProfiles?.length !== 1 && billedPerUse(profile) && candidatePool.some((p) => !billedPerUse(p))) {
    hub.noteBilledFallback({ session: key, workspace: options.ws ?? null, runtime, profile });
  }
  return [key, openChat(hub, key, options.createdBy, title)];
}

/// Changes how a session runs from its next turn on: another profile of its runtime (another account, say), another
/// model it can run, another effort. Its transcript is shared by the runtime's profiles, so the next message resumes it
/// with all it had; its process ends so the change takes: at once when idle, else when the running turn is over, before
/// the next one starts (nobody waits for the turn to end to change it). Another model starts over
/// what went with the old one: its effort back to the runtime's default, its profile back to the station's choice
/// (picked here, among those that run the model), unless given with it. Given back to the station to pick again
/// (`repick`), its account is picked now as a new session's would be. Whether it goes on afresh once its prompt cache is
/// over (`afresh`, null: as the station is set) is read as its next turn starts: its process goes on.
export async function configure(hub: Hub, key: string, change: SessionChange, lang: Lang = stationLang()) {
  const { afresh, ...rest } = change;
  if (afresh !== undefined) {
    if (!hub.store.getSession(key)) throw new Error(`unknown session ${key}`);
    hub.store.setSessionAfresh(key, afresh);
    log.info("hub", "going on afresh once its cache is over set", { session: key, afresh: afresh ?? "station's" });
    if (Object.keys(rest).length === 0) return;
  }
  const { row, runtime, model, effort, profile, profiles, pinned, repick } = hub.accounts.change(key, change, lang);
  const account = hub.accounts.profile(profile ?? row.profile);
  const kept = profiles === undefined ? row.profiles : profiles;
  const fixed = typeof profile === "string" || (profiles === undefined && row.profilePinned);
  const wantsUltrafast = change.speed === "ultrafast" || row.speed === "ultrafast";
  const supportsUltrafast = wantsUltrafast && runtime === "codex" && (fixed
    ? account !== null && hub.accounts.supportsUltrafast(account, model)
    : hub.profilesIn(row.ws ?? null).some((p) => p.runtimes.includes("codex") && (!kept?.length || kept.includes(p.id))
      && (model === null || runs(p, model)) && hub.accounts.supportsUltrafast(p, model)));
  const speed = change.speed !== undefined ? change.speed : change.fast !== undefined || runtime !== row.runtime || (row.speed === "ultrafast" && !supportsUltrafast) ? null : row.speed ?? null;
  checkSpeed(runtime, speed, supportsUltrafast, lang);
  const movedRuntime = runtime !== row.runtime && typeof profile === "string";
  const recapped = change.context !== undefined && change.context !== row.context;
  // Its runtime compacts on its own only some calls into a new process: what it holds over a lower most is compacted
  // once this turn is over, not sent whole again first.
  const over = !movedRuntime && typeof change.context === "number" && (usageNow(hub.store, key)?.contextTokens ?? 0) > change.context;
  if (movedRuntime) {
    if (row.runtimeSessionId) hub.store.ranIn(key, row.runtimeSessionId, row.profile);
    hub.store.setSessionRuntime(key, runtime, profile, pinned === true, model, effort, change.fast ?? null, change.context ?? null, profiles ?? null);
    hub.store.setSessionContextBefore(key, null);
  } else {
    const leftPool = profiles !== undefined && profiles !== null && profiles.length > 1 && !profiles.includes(row.profile);
    if (profiles !== undefined) hub.store.setSessionProfile(key, profile ?? row.profile, profile !== null, profiles);
    if (model !== row.model || effort !== row.effort) hub.store.setSessionModel(key, model, effort);
    if (change.fast !== undefined) hub.store.setSessionFast(key, change.fast);
    if (recapped) {
      hub.store.setSessionContext(key, change.context ?? null);
      hub.store.setSessionContextBefore(key, over ? (row.contextBefore ?? row.context ?? 0) : null);
    }
    if (change.speed !== undefined || (change.fast === undefined && (row.speed ?? null) !== speed)) hub.store.setSessionSpeed(key, speed);
    if (repick || leftPool) hub.accounts.repick(key);
    else if (profile === null || (!fixed && speed === "ultrafast" && change.speed !== undefined)) hub.accounts.runOn(key, false, true);
  }
  const tui = runtime === "claude" && (change.tui ?? row.tui ?? false);
  const modeChanged = tui !== (row.tui ?? false);
  if (modeChanged) hub.store.setSessionTui(key, tui);
  if (movedRuntime && speed !== null) hub.store.setSessionSpeed(key, speed);
  // Another most context is what its process starts with (Claude Code's settings, a Codex thread's config): only a new
  // one takes it.
  await hub.changed(key, movedRuntime || recapped || modeChanged);
  // Another runtime, model, effort or speed: said in its chat, before and after.
  const now = hub.store.getSession(key);
  if (now) {
    const named = (id: string) => {
      const name = hub.accounts.profile(id)?.name;
      return typeof name === "string" ? name : null;
    };
    const change = { was: runShown(row, named), now: runShown(now, named) };
    if (runChanged(change)) await hub.actor(now).runChanged(change);
  }
  if (recapped && over) await hub.actor(hub.store.getSession(key) ?? row).compactToCap();
  log.info("hub", "session changed", { session: key, profile: hub.store.getSession(key)?.profile ?? "", model, effort, context: hub.store.getSession(key)?.context ?? "" });
  // Its last turn stopped at the allowance, or waits to be tried again on a model at capacity: changed, it goes on by
  // itself (at once).
  const last = hub.store.lastTurn(key);
  const detail = last?.outcome === "failed" ? (last.detail ?? "") : "";
  if (detail.startsWith("rate_limit") || (detail.startsWith("overloaded") && last?.declared === "waiting")) void hub.actor(hub.store.getSession(key) ?? row).goOn();
}

/// Where an archived session's transcript copy is.
const transcriptCopy = (hub: Hub, key: string) => join(hub.store.archiveDir(), "transcripts", `${key}.jsonl.zst`);

/// Hides a session from lists, or shows it again; `by` is MANUAL or AUTO. Archiving also ends its idle process and
/// hands its files to cold storage once it is idle; they are restored before the next runtime starts, and before it is
/// shown again (a promise then, when cold storage takes its time: the session is shown once they are back).
export function archiveBy(hub: Hub, key: string, archived: boolean, by: string, known?: SessionRow, knownMembers?: string[]): void | Promise<void> {
  const row = known ?? hub.store.getSession(key);
  if (!row) throw new Error(`unknown session ${key}`);
  const members = knownMembers !== undefined && knownMembers.length > 0
    ? knownMembers
    : (() => {
        const anchor = hub.store.conversationOf(key);
        const found = hub.store.membersOf(anchor);
        return found.length > 0 ? found : [key];
      })();
  if (!archived) {
    const shown = async () => {
      hub.store.setArchived(key, false, by);
      for (const m of members) await rm(transcriptCopy(hub, m), { force: true });
    };
    const restoring: Promise<void>[] = [];
    for (const m of members) {
      const r = hub.cold.restore(m);
      if (r) restoring.push(r);
    }
    return restoring.length > 0 ? Promise.all(restoring).then(shown) : shown();
  }
  hub.store.setArchived(key, archived, by);
  for (const m of members) {
    hub.forgetIdleMeasured(m);
    hub.closed(m);
    const mRow = m === key ? row : hub.store.getSession(m);
    if (!mRow) continue;
    const actor = hub.actor(mRow);
    void actor
      .putAway()
      // (what it left in the background ends with it: an archived session keeps nothing running; a turn under way runs
      // to its end, which ends it then: hub.ts `idleNow`)
      .then(() => actor.evict(true))
      .then(() => actor.cleanArchive());
  }
}

/// Hides a session from lists, or shows it again, by hand.
export const archive = (hub: Hub, key: string, archived: boolean) => archiveBy(hub, key, archived, MANUAL);

/// Archives a chat on the pages, or shows it again: a session's own chat goes with its session; a chat of its own goes
/// alone, its sessions staying as they are. Lists show a chat through a session that is shown, so one shown again with
/// none brings its sessions back first.
export function archiveChat(hub: Hub, thread: number, archived: boolean): void | Promise<void> {
  const chat = stillfailChat(hub, thread);
  if (chat.home !== null) return archive(hub, chat.home, archived);
  const show = () => hub.store.setThreadHidden(thread, archived, MANUAL);
  if (archived) return show();
  const sessions = hub.store.threadSessions(thread).map((m) => m.session);
  if (sessions.length === 0 || sessions.some((s) => hub.store.getSession(s)?.archivedAt == null)) return show();
  return Promise.all(sessions.map((s) => archive(hub, s, false))).then(show);
}

/// A snapshot-bounded walk of archived workspaces; no main-thread query returns more than a page.
async function* archivedWorkspaces(
  hub: Hub,
  through: number | ArchivedWorkspace,
  needed: () => boolean | Promise<boolean> = () => true,
  start: ArchivedWorkspace | null = null,
): AsyncGenerator<ArchivedWorkspace> {
  let after: ArchivedWorkspace | null = start;
  for (;;) {
    if (!(await needed())) return;
    const page = hub.store.archivedSessions(after, through);
    for (const s of page) yield s;
    if (page.length < ARCHIVED_WORKSPACE_BATCH) return;
    after = page[page.length - 1]!;
    // Even if every file check completes immediately, other station work gets a turn before the next database page.
    await new Promise<void>((resolve) => setImmediate(resolve));
  }
}

/// Minimum interval between periodic archive backfill (`packUnfinishedArchived`) and idle rebuildable cleanup
/// (`cleanIdleRebuildable`) rounds (10 minutes): packing up to 16 sessions per round clears a backlog of several
/// hundred sessions within a few hours without contending with the main lifecycle loop.
export const ARCHIVE_UPKEEP_EVERY_MS = 10 * 60_000;

/// Short startup grace (60 seconds) before `runArchiveUpkeepIfDue` may run after a hub starts: prevents a burst
/// at the exact moment of startup while allowing persisted `lastArchiveUpkeepAt` to run promptly after a restart
/// instead of waiting another full 10 minutes.
export const ARCHIVE_UPKEEP_STARTUP_GRACE_MS = 60_000;

/// Max unfinished archived sessions packed per periodic round to prevent a startup/timer storm.
export const PACK_BACKFILL_MAX_PER_ROUND = 16;

/// Max archived sessions checked per periodic backfill round before advancing the cross-round cursor.
export const PACK_BACKFILL_CHECK_MAX_PER_ROUND = 256;

/// Unarchived sessions idle this long have their rebuildable directories (node_modules, target, ...) cleaned:
/// 24 hours makes returning the next day and reinstalling dependencies acceptable.
export const IDLE_REBUILD_MS = 24 * 3_600_000;

/// Aggressive idle threshold for cleaning rebuildable directories of unarchived sessions when disk is below `diskLow`.
export const IDLE_REBUILD_LOW_MS = 3_600_000;

/// Max idle unarchived sessions measured per periodic round.
export const IDLE_REBUILD_MAX_PER_ROUND = 16;

function recordIdleMeasured(hub: Hub, key: string, lastActiveAt: number): void {
  const map = hub.idleMeasured;
  map.delete(key);
  map.set(key, lastActiveAt);
  if (map.size > IDLE_MEASURED_MAX) {
    const oldest = map.keys().next().value;
    if (oldest !== undefined) map.delete(oldest);
  }
  hub.idleMeasuredDirty = true;
}

function idleMeasuredRecord(hub: Hub): Record<string, number> {
  const out: Record<string, number> = {};
  for (const [k, v] of hub.idleMeasured) out[k] = v;
  return out;
}

function ensureUpkeepStateLoaded(hub: Hub): Promise<void> {
  hub.upkeepStateLoad ??= (async () => {
    let saved;
    try {
      saved = await hub.readUpkeepState(hub.config().dataDir);
    } catch {
      saved = emptyUpkeepState();
    }
    // Preserve any entries already recorded in memory in this process (newer than disk), while restoring prior entries.
    const existing = [...hub.idleMeasured.entries()];
    hub.idleMeasured.clear();
    for (const [k, v] of Object.entries(saved.idleMeasured)) {
      hub.idleMeasured.set(k, v);
    }
    for (const [k, v] of existing) {
      hub.idleMeasured.delete(k);
      hub.idleMeasured.set(k, v);
    }
    while (hub.idleMeasured.size > IDLE_MEASURED_MAX) {
      const oldest = hub.idleMeasured.keys().next().value;
      if (oldest === undefined) break;
      hub.idleMeasured.delete(oldest);
    }
    if (hub.lastArchiveUpkeepAt === null) hub.lastArchiveUpkeepAt = saved.lastArchiveUpkeepAt;
    if (hub.lastFullRelieveAt === null) hub.lastFullRelieveAt = saved.lastFullRelieveAt;
  })();
  return hub.upkeepStateLoad;
}

async function persistHubUpkeepState(
  hub: Hub,
  opts: { idleMeasured?: boolean; lastArchiveUpkeepAt?: boolean; lastFullRelieveAt?: boolean },
): Promise<void> {
  const patch: {
    idleMeasured?: Record<string, number>;
    lastArchiveUpkeepAt?: number | null;
    lastFullRelieveAt?: number | null;
  } = {};
  let any = false;
  if (opts.idleMeasured && hub.idleMeasuredDirty) {
    patch.idleMeasured = idleMeasuredRecord(hub);
    any = true;
  }
  if (opts.lastArchiveUpkeepAt) {
    patch.lastArchiveUpkeepAt = hub.lastArchiveUpkeepAt;
    any = true;
  }
  if (opts.lastFullRelieveAt) {
    patch.lastFullRelieveAt = hub.lastFullRelieveAt;
    any = true;
  }
  if (!any) return;
  await patchUpkeepState(hub.config().dataDir, patch);
  if (opts.idleMeasured) hub.idleMeasuredDirty = false;
}

/// Earliest timestamp when `runArchiveUpkeepIfDue` will next be eligible to run (respecting both the startup grace
/// and the persisted `lastArchiveUpkeepAt` cadence).
export function nextArchiveUpkeepAt(hub: Hub, everyMs = ARCHIVE_UPKEEP_EVERY_MS): number {
  const grace = hub.startedAt + ARCHIVE_UPKEEP_STARTUP_GRACE_MS;
  if (hub.lastArchiveUpkeepAt === null) return grace;
  return Math.max(grace, hub.lastArchiveUpkeepAt + everyMs);
}

/// Empties the workspaces of sessions archived past archivedWorkspaceMs, one after another: each keeps the files sent in
/// its chat, its history and its transcripts (cold.ts `expire`). Returns when the next one archived comes due (null:
/// none, or off).
export async function expireArchived(hub: Hub, now: number): Promise<number | null> {
  const after = hub.config().archivedWorkspaceMs;
  const { cold } = hub;
  if (after <= 0 || !cold.expire || !cold.holdsMore) return null;
  for await (const s of archivedWorkspaces(hub, now - after)) {
    try {
      if (await cold.holdsMore(s.key)) await cold.expire(s.key, now - after);
    } catch (error) {
      log.warn("hub", "the workspace of a long-archived session was not emptied", { session: s.key, error: (error as Error).message });
    }
  }
  const next = hub.store.nextArchivedAt(now - after);
  return next === null ? null : next + after;
}

/// Periodically finishes packing archived sessions that are not yet past `archivedWorkspaceMs` and still lack a `cold`
/// mark (e.g. after a transient archive failure). Uses a cross-round cursor so persistent failures at the head do not
/// starve later sessions, caps both checked (`checkLimit`) and packed (`limit`) sessions per round, and yields between
/// sessions.
export async function packUnfinishedArchived(
  hub: Hub,
  now: number,
  limit = PACK_BACKFILL_MAX_PER_ROUND,
  checkLimit = PACK_BACKFILL_CHECK_MAX_PER_ROUND,
): Promise<number> {
  const { cold } = hub;
  if (!cold.needsPack || limit <= 0 || checkLimit <= 0) return 0;
  const through = hub.store.lastArchivedSession();
  if (through === null) {
    hub.packBackfillCursor = null;
    return 0;
  }
  const afterMs = hub.config().archivedWorkspaceMs;
  const windowFloor = afterMs > 0 ? now - afterMs : -Infinity;
  const windowStart: ArchivedWorkspace | null = afterMs > 0 ? { archivedAt: now - afterMs, key: "" } : null;
  const saved = hub.packBackfillCursor;
  const savedInWindow =
    saved !== null &&
    saved.archivedAt >= windowFloor &&
    (saved.archivedAt < through.archivedAt || (saved.archivedAt === through.archivedAt && saved.key < through.key));
  const start = savedInWindow ? saved : windowStart;

  let checked = 0;
  let attempted = 0;
  let packedCount = 0;
  let lastSeen: ArchivedWorkspace | null = null;
  let stoppedEarly = false;
  for await (const s of archivedWorkspaces(hub, through, () => checked < checkLimit && attempted < limit, start)) {
    if (checked >= checkLimit || attempted >= limit) {
      stoppedEarly = true;
      break;
    }
    checked++;
    lastSeen = s;
    try {
      if (!(await cold.needsPack(s.key))) continue;
      const row = hub.store.getSession(s.key);
      if (!row || row.archivedAt === null) continue;
      attempted++;
      await hub.actor(row).cleanArchive();
      packedCount++;
    } catch (error) {
      log.warn("hub", "an archived session's files not put away on backfill", { session: s.key, error: (error as Error).message });
    }
    await yieldLoop();
    if (checked >= checkLimit || attempted >= limit) {
      stoppedEarly = true;
      break;
    }
  }
  hub.packBackfillCursor = stoppedEarly && lastSeen !== null ? lastSeen : null;
  return packedCount;
}

/// Cleans rebuildable build/install directories from idle unarchived sessions (`last_active_at <= now - idleMs`),
/// oldest activity first, one at a time, capped at `limit` measured sessions per round. Memoizes `key -> lastActiveAt`
/// so already-measured sessions are skipped until new activity updates `last_active_at`. Never packs, writes `cold`,
/// or touches transcripts.
export async function cleanIdleRebuildable(
  hub: Hub,
  now: number,
  options?: { idleMs?: number; limit?: number; persist?: boolean },
): Promise<number> {
  const { cold } = hub;
  if (!cold.cleanIdleRebuildable) return 0;
  const idleMs = options?.idleMs ?? IDLE_REBUILD_MS;
  const limit = options?.limit ?? IDLE_REBUILD_MAX_PER_ROUND;
  if (limit <= 0) return 0;
  await ensureUpkeepStateLoaded(hub);
  const measuredMap = hub.idleMeasured;
  const through = now - idleMs;
  let after: { lastActiveAt: number; key: string } | null = null;
  let measured = 0;
  for (;;) {
    if (measured >= limit) break;
    const page = hub.store.idleUnarchivedSessions(after, through, IDLE_UNARCHIVED_BATCH);
    for (const s of page) {
      if (measured >= limit) break;
      if (measuredMap.get(s.key) === s.lastActiveAt) continue;
      try {
        const freed = await cold.cleanIdleRebuildable(s.key);
        if (freed !== null) {
          recordIdleMeasured(hub, s.key, s.lastActiveAt);
          measured++;
        }
      } catch (error) {
        log.warn("hub", "rebuildable files of an idle session not cleaned", { session: s.key, error: (error as Error).message });
      }
      await yieldLoop();
    }
    if (page.length < IDLE_UNARCHIVED_BATCH) break;
    const last = page[page.length - 1]!;
    after = { lastActiveAt: last.lastActiveAt, key: last.key };
  }
  if (options?.persist !== false) {
    await persistHubUpkeepState(hub, { idleMeasured: true });
  }
  return measured;
}

/// Runs `packUnfinishedArchived` and `cleanIdleRebuildable` on their own cadence (`ARCHIVE_UPKEEP_EVERY_MS`),
/// independent of how frequently `expireArchived` wakes. Respects a short startup grace (`ARCHIVE_UPKEEP_STARTUP_GRACE_MS`)
/// so startup never runs an immediate burst, then uses the persisted `lastArchiveUpkeepAt` so frequent restarts do not
/// starve upkeep. Returns whether a round ran.
export async function runArchiveUpkeepIfDue(
  hub: Hub,
  now: number,
  everyMs = ARCHIVE_UPKEEP_EVERY_MS,
): Promise<boolean> {
  await ensureUpkeepStateLoaded(hub);
  if (now - hub.startedAt < ARCHIVE_UPKEEP_STARTUP_GRACE_MS) return false;
  if (hub.lastArchiveUpkeepAt !== null && now - hub.lastArchiveUpkeepAt < everyMs) return false;
  hub.lastArchiveUpkeepAt = now;
  try {
    await packUnfinishedArchived(hub, now);
  } catch (error) {
    log.warn("hub", "backfilling unfinished archived workspaces failed", { error: (error as Error).message });
  }
  try {
    await cleanIdleRebuildable(hub, now, { persist: false });
  } catch (error) {
    log.warn("hub", "cleaning rebuildable files of idle sessions failed", { error: (error as Error).message });
  }
  await persistHubUpkeepState(hub, { idleMeasured: true, lastArchiveUpkeepAt: true });
  return true;
}

/// Low-disk reclamation of rebuildable directories from idle unarchived sessions (threshold `IDLE_REBUILD_LOW_MS`,
/// oldest activity first). When `full` is true, cleans all eligible sessions without stopping early when `free() >= low`;
/// otherwise stops as soon as `free()` reaches `low`. Shares the `last_active_at` measurement cache with
/// `cleanIdleRebuildable`. Runs before `relieveArchived`.
export async function relieveIdleRebuildable(
  hub: Hub,
  free: () => number | Promise<number>,
  low = DISK_LOW_BYTES,
  idleMs = IDLE_REBUILD_LOW_MS,
  options?: { full?: boolean; persist?: boolean },
): Promise<number> {
  const { cold } = hub;
  const full = options?.full === true;
  if (!cold.cleanIdleRebuildable) return 0;
  if (!full && (await free()) >= low) return 0;
  await ensureUpkeepStateLoaded(hub);
  const measuredMap = hub.idleMeasured;
  const through = hub.now() - idleMs;
  let after: { lastActiveAt: number; key: string } | null = null;
  let measured = 0;
  try {
    for (;;) {
      if (!full && (await free()) >= low) break;
      const page = hub.store.idleUnarchivedSessions(after, through, IDLE_UNARCHIVED_BATCH);
      for (const s of page) {
        if (!full && (await free()) >= low) return measured;
        if (measuredMap.get(s.key) === s.lastActiveAt) continue;
        try {
          const freed = await cold.cleanIdleRebuildable(s.key);
          if (freed !== null) {
            recordIdleMeasured(hub, s.key, s.lastActiveAt);
            measured++;
          }
        } catch (error) {
          log.warn("hub", "rebuildable files of an idle session not cleaned", { session: s.key, error: (error as Error).message });
        }
        await yieldLoop();
      }
      if (page.length < IDLE_UNARCHIVED_BATCH) break;
      const last = page[page.length - 1]!;
      after = { lastActiveAt: last.lastActiveAt, key: last.key };
    }
    return measured;
  } finally {
    if (options?.persist !== false) {
      await persistHubUpkeepState(hub, { idleMeasured: true });
    }
  }
}

/// The disk of the station's data is low (ops/disk.ts): archived workspaces are emptied before archivedWorkspaceMs, the
/// longest archived first. When `full` is true, empties all eligible archived workspaces without stopping early when
/// `free() >= low`; otherwise stops once `free() >= low`. None with archivedWorkspaceDays 0 (kept on purpose).
export async function relieveArchived(
  hub: Hub,
  free: () => number | Promise<number>,
  low = DISK_LOW_BYTES,
  options?: { full?: boolean },
): Promise<void> {
  const { cold } = hub;
  const full = options?.full === true;
  if (hub.config().archivedWorkspaceMs <= 0 || !cold.expire || !cold.holdsMore) return;
  if (!full && (await free()) >= low) return;
  const through = hub.store.lastArchivedSession();
  if (through === null) return;
  for await (const s of archivedWorkspaces(hub, through, full ? () => true : async () => (await free()) < low)) {
    if (!full && (await free()) >= low) return;
    try {
      // Shown and archived again since, it is not the one looked at: `expire` leaves it.
      if (!(await cold.holdsMore(s.key))) continue;
      if (!full && (await free()) >= low) return;
      await cold.expire(s.key, s.archivedAt);
    } catch (error) {
      log.warn("hub", "the workspace of an archived session was not emptied", { session: s.key, error: (error as Error).message });
    }
  }
}

/// Runs a full low-disk reclamation pass across all four steps (idle rebuildables, archived workspaces,
/// orphan UUID transcripts, and unreferenced shared clones) without stopping early between steps when
/// `free() < low`, throttled to at most once per `RELIEVE_FULL_EVERY_MS` (30 minutes). Each step is isolated
/// so a failure in one step never skips the remaining steps or the cooldown timestamp. Returns whether a pass ran.
export async function relieveLowDiskFull(
  hub: Hub,
  free: () => number | Promise<number>,
  low = DISK_LOW_BYTES,
  options?: { git?: RepoGitRun; cooldownMs?: number },
): Promise<boolean> {
  if ((await free()) >= low) return false;
  await ensureUpkeepStateLoaded(hub);
  const now = hub.now();
  const cooldownMs = options?.cooldownMs ?? RELIEVE_FULL_EVERY_MS;
  const prev = hub.lastFullRelieveAt;
  if (prev !== null && now - prev < cooldownMs) return false;
  try {
    await relieveIdleRebuildable(hub, free, low, IDLE_REBUILD_LOW_MS, { full: true, persist: false });
  } catch (error) {
    log.warn("hub", "cleaning rebuildable files of idle sessions failed", { error: (error as Error).message });
  }
  try {
    await relieveArchived(hub, free, low, { full: true });
  } catch (error) {
    log.warn("hub", "making room on the disk failed", { error: (error as Error).message });
  }
  try {
    await relieveOrphanTranscripts(hub.config().dataDir, now, hub.store, free, low, { full: true });
  } catch (error) {
    log.warn("hub", "reclaiming orphan transcripts failed", { error: (error as Error).message });
  }
  try {
    await relieveRepos(hub, free, low, { full: true, git: options?.git });
  } catch (error) {
    log.warn("hub", "reclaiming unused shared clones failed", { error: (error as Error).message });
  }
  hub.lastFullRelieveAt = hub.now();
  await persistHubUpkeepState(hub, { idleMeasured: true, lastFullRelieveAt: true });
  return true;
}

/// A shared clone in `<data>/repos` untouched for this long may be reclaimed when disk space is below the low mark:
/// 3 days protects active work across a weekend while letting low-disk reclamation free unused shared clones promptly.
export const REPO_IDLE_MS = 3 * 24 * 3_600_000;
export { REPO_GIT_TIMEOUT_MS, type RepoGitRun };

async function repoLastTouchedMs(repoPath: string): Promise<number | null> {
  let latest: number | null = null;
  for (const rel of [".git/HEAD", ".git/FETCH_HEAD", ".git/index", ".git/logs/HEAD"]) {
    const st = await stat(join(repoPath, rel)).catch(() => null);
    if (st !== null && (latest === null || st.mtimeMs > latest)) latest = st.mtimeMs;
  }
  return latest;
}

function isRecoverableRemoteUrl(raw: string): boolean {
  const url = raw.trim();
  if (url === "" || /^file:/i.test(url)) return false;
  if (url.startsWith("/") || url.startsWith("./") || url.startsWith("../") || url === "." || url === ".." || /^[A-Za-z]:[\\/]/.test(url) || url.startsWith("\\\\")) {
    return false;
  }
  if (/^(https?|ssh|git):\/\/[^/?#]+\/.+/i.test(url)) return true;
  if (/^[A-Za-z0-9._-]+@[A-Za-z0-9][A-Za-z0-9.-]*:(?!:)\S+$/.test(url)) return true;
  return false;
}

/// Reads a JSON file strictly: returns `{ kind: "missing" }` only on ENOENT, `{ kind: "ok", value }` on valid object,
/// or `{ kind: "error" }` on any other read/parse error so callers can fail closed.
async function readJsonObjectStrict(path: string): Promise<{ kind: "missing" } | { kind: "error" } | { kind: "ok"; value: Record<string, unknown> }> {
  let text: string;
  try {
    text = await readFile(path, "utf8");
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "ENOENT" ? { kind: "missing" } : { kind: "error" };
  }
  try {
    const parsed = JSON.parse(text);
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return { kind: "error" };
    return { kind: "ok", value: parsed as Record<string, unknown> };
  } catch {
    return { kind: "error" };
  }
}

/// Reclaims unreferenced shared clones in `<data>/repos` when disk space remains below `low` after `relieveArchived`:
/// least recently used first, stopping as soon as free space reaches `low`. Only clones that are real directories under
/// `<data>/repos`, clean, pushed to a non-local remote, have no stash or worktree registrations, are unreferenced by
/// presets, sessions (including unarchived sessions' preset copies), active jobs, or `move/repos.json`, and have not
/// been touched for REPO_IDLE_MS are removed.
export async function relieveRepos(
  hub: Hub,
  free: () => number | Promise<number>,
  low = DISK_LOW_BYTES,
  options?: { git?: RepoGitRun; full?: boolean },
): Promise<string[]> {
  const full = options?.full === true;
  if (!full && (await free()) >= low) return [];
  if (hub.clones.hasActive()) return [];
  const { dataDir, agentHome } = hub.config();
  await pruneRepoWorktrees(dataDir);
  const rawRepos = clean(join(dataDir, "repos"));
  const realRepos = await realpath(rawRepos).catch(() => null);
  if (realRepos === null) return [];

  // Collect all referenced paths once: presets across all workspaces, all session rows (plus preset copies of
  // unarchived sessions), active jobs, and move/repos.json. Fail closed if any reference file exists but is unreadable.
  const refs = new Set<string>();
  const addRef = async (p: string | null | undefined) => {
    if (!p) return;
    refs.add(clean(p));
    const r = await realpath(p).catch(() => null);
    if (r !== null) refs.add(r);
  };
  for (const home of await agentHomes(agentHome)) {
    const res = await readJsonObjectStrict(join(home, "presets.json"));
    if (res.kind === "error") return [];
    if (res.kind === "missing") continue;
    const presets = res.value.presets;
    if (presets !== undefined && !Array.isArray(presets)) return [];
    for (const preset of (presets as any[]) ?? []) {
      if (!Array.isArray(preset?.dirs)) continue;
      for (const dir of preset.dirs) {
        if (typeof dir?.path === "string") await addRef(dir.path);
      }
    }
  }
  let afterKey = "";
  for (;;) {
    const page = hub.store.sessionPathsPage(afterKey);
    for (const s of page) {
      await addRef(s.workspace);
      await addRef(s.cwd);
      if (s.archivedAt === null) {
        const copyRes = await readJsonObjectStrict(join(s.workspace, PRESET_COPY_FILE));
        if (copyRes.kind === "error") return [];
        if (copyRes.kind === "ok" && Array.isArray(copyRes.value.dirs)) {
          for (const dir of copyRes.value.dirs as any[]) {
            if (typeof dir?.path === "string" && (typeof dir?.elsewhere !== "string" || dir.elsewhere === "")) {
              await addRef(dir.path);
            }
          }
        }
      }
    }
    if (page.length === 0) break;
    afterKey = page[page.length - 1]!.key;
    await new Promise<void>((resolve) => setImmediate(resolve));
  }
  try {
    for (const job of hub.store.jobsUp()) await addRef(job.cwd);
  } catch {
    return [];
  }
  const moveReposRes = await readJsonObjectStrict(join(dataDir, "move", "repos.json"));
  if (moveReposRes.kind === "error") return [];
  if (moveReposRes.kind === "ok") {
    for (const entry of Object.values(moveReposRes.value)) {
      if (typeof (entry as any)?.dir === "string") await addRef((entry as any).dir);
    }
  }

  const now = hub.now();
  const candidates: { name: string; path: string; rawPath: string; mtime: number }[] = [];
  for (const name of await readdir(realRepos).catch(() => [] as string[])) {
    if (name.startsWith(".")) continue;
    const repoPath = join(realRepos, name);
    const rawPath = join(rawRepos, name);
    const st = await lstat(repoPath).catch(() => null);
    if (st === null || !st.isDirectory() || st.isSymbolicLink()) continue;
    // Condition 4: no worktree registrations remaining (including locked ones).
    const worktrees = await readdir(join(repoPath, ".git", "worktrees")).catch((e: NodeJS.ErrnoException) => (e.code === "ENOENT" ? [] : null));
    if (worktrees === null || worktrees.length > 0) continue;
    // Condition 5: no preset, session, active job, or move/repos.json references this clone or a subdir.
    let referenced = false;
    for (const ref of refs) {
      if (within(ref, repoPath) || within(ref, rawPath)) {
        referenced = true;
        break;
      }
    }
    if (referenced) continue;
    // Condition 6: untouched for at least REPO_IDLE_MS.
    const mtime = await repoLastTouchedMs(repoPath);
    if (mtime === null || now - mtime < REPO_IDLE_MS) continue;
    candidates.push({ name, path: repoPath, rawPath, mtime });
  }

  candidates.sort((a, b) => a.mtime - b.mtime);
  const git = options?.git ?? runRepoGit;
  const removed: string[] = [];
  for (const cand of candidates) {
    if (!full && (await free()) >= low) break;
    if (hub.clones.hasActive()) break;
    // Condition 2: has a non-local remote, no unpushed commits (including detached HEAD / all refs), no refs/stash.
    const remotesRes = await git(cand.path, ["remote"]);
    if (!remotesRes.ok) continue;
    const remotes = remotesRes.stdout.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
    if (remotes.length === 0) continue;
    const primary = remotes.includes("origin") ? "origin" : remotes[0]!;
    const urlRes = await git(cand.path, ["remote", "get-url", primary]);
    const remoteUrl = urlRes.stdout.trim();
    if (!urlRes.ok || !isRecoverableRemoteUrl(remoteUrl)) continue;
    // Run local branch cleanup (unthrottled by daily cadence) so merged/applied/process-only branches are dropped
    // and stale (>14d) unpushed branches are archived into a verified bundle before checking remaining unpushed tips.
    await pruneRepoBranchesIn(dataDir, cand.name, cand.path, now, { git });
    const revRes = await git(cand.path, ["rev-list", "--count", "--all", "HEAD", "--not", "--remotes"]);
    if (!revRes.ok || revRes.stdout.trim() !== "0") continue;
    const stashRes = await git(cand.path, ["for-each-ref", "refs/stash"]);
    if (!stashRes.ok || stashRes.stdout.trim() !== "") continue;
    // Condition 3: main working tree has no tracked changes; untracked files are allowed only if all are process files.
    const statusRes = await git(cand.path, ["-c", "core.quotepath=false", "--no-optional-locks", "status", "--porcelain", "--untracked-files=all"]);
    if (!statusRes.ok) continue;
    let dirty = false;
    for (const line of statusRes.stdout.split(/\r?\n/)) {
      if (line === "") continue;
      if (!line.startsWith("?? ")) {
        dirty = true;
        break;
      }
      const rel = line.slice(3).trim();
      if (!isProcessFile(rel)) {
        dirty = true;
        break;
      }
    }
    if (dirty) continue;
    // Re-check before rm: a session may have added a worktree or touched the repo during the git checks.
    const recheckWt = await readdir(join(cand.path, ".git", "worktrees")).catch((e: NodeJS.ErrnoException) => (e.code === "ENOENT" ? [] : null));
    if (recheckWt === null || recheckWt.length > 0) continue;
    const recheckMtime = await repoLastTouchedMs(cand.path);
    if (recheckMtime === null || recheckMtime !== cand.mtime) continue;
    if (hub.clones.hasActive() || (!full && (await free()) >= low)) break;
    const { bytes } = await treeBytes(cand.path);
    await rm(cand.path, { recursive: true, force: true });
    log.info("hub", "reclaimed unused shared clone", { path: cand.path, remote: safeUrl(remoteUrl), freed: bytes });
    removed.push(cand.name);
  }
  return removed;
}

/// Archives what has idled past autoArchiveMs (counted from its last activity, or from being shown again by hand) and is
/// done: nothing running or waiting to be heard, no background job or service of its own still up (a watch above all),
/// not stopped at a block for someone, nothing its chat's starter has not read, and no single-session connect feeding
/// it. Anything new said brings it back. Returns when the next one not idle long enough yet will have (null: none, or
/// auto-archiving off): what is idle but not done by now is not on a clock, so it is looked at again after a while.
/// A session heard only in Slack goes after slackArchiveMs even when stopped at a block: nobody answers it from here.
/// The autoArchiveKeep most lately active conversations of each workspace never go this way
/// (`recentConversations`). With autoArchiveReviewed, the rest goes only once the archive review recommended each of its
/// chats. Of a session, its recent chats (store `recentSessionThreads`) are what is looked at, as the review looks at them,
/// however many it joined.
export function autoArchive(hub: Hub, now: number, prepareUnread?: (thread: number) => void, prepareBindings?: () => void,
  prepareJobs?: (session: string) => void, prepareMarks?: () => void, prepareLast?: (thread: number) => void,
  look?: ArchiveLook): number | null {
  const { store } = hub;
  const { autoArchiveMs: after, slackArchiveMs, autoArchiveReviewed, autoArchiveKeep, automaticDecisions } = hub.config();
  if (after <= 0 && slackArchiveMs <= 0) return null;
  let next: number | null = null;
  const idle = (at: (number | null | undefined)[], wait = after) => {
    if (wait <= 0) return false;
    const due = Math.max(0, ...at.filter((x): x is number => typeof x === "number")) + wait;
    if (due > now && (next === null || due < next)) next = due;
    return due <= now;
  };
  const unread = (t: ThreadRow) => {
    if (t.createdBy === null || t.surface !== STILLFAIL_SURFACE) return false;
    const answer = store.unreadForArchive(t.createdBy, t.id);
    if (answer === null) { prepareUnread?.(t.id); return true; }
    return answer;
  };
  // A reader's look (`look`): what it read of every session shown and chat of its own, and of those idle long enough
  // what the rest needs; nothing of them is read here but of those archived.
  if (look !== undefined) {
    if (!look.marksReady) { prepareMarks?.(); return null; }
    for (const thread of look.ownUnknown) prepareLast?.(thread);
    next = look.next;
  }
  // Over the sessions shown and the chats of their own (and those chats' sessions), never every one ever archived.
  const live = look !== undefined ? [] : store.liveSessions();
  const own = look !== undefined ? look.own : store.chatsOfTheirOwn();
  if (look === undefined && live.length === 0 && own.length === 0) return null;
  // An old station's reverse mark lookup may be incomplete. Never guess that a chat is unpinned or not kept.
  if (look === undefined && !archiveMarksReady(store.db)) { prepareMarks?.(); return null; }
  const bindingsReady = look !== undefined || live.length === 0 || sessionBindingsReady(store.db);
  const waitingForBindings = !bindingsReady && prepareBindings !== undefined;
  if (waitingForBindings) prepareBindings?.();
  const oldBindings = !bindingsReady && !waitingForBindings ? store.listBindings() : null;
  // Each session's undelivered messages and last turn, read for those idle long enough alone, once each: read for every
  // session shown and every member of their chats at each look, the station's thread was held 17 s on a station short of
  // memory (2026-11-03), what was said meanwhile waiting.
  const statsRead = new Map<string, WorkOf | undefined>();
  const statOf = (key: string): WorkOf | undefined => {
    if (!statsRead.has(key)) statsRead.set(key, store.workOf(key));
    return statsRead.get(key);
  };
  let oldJobs: Set<string> | null = null;
  const jobsRead = new Map<string, boolean>();
  const hasUpJob = (key: string) => {
    if (jobsRead.has(key)) return jobsRead.get(key)!;
    const found = store.sessionHasUpJob(key);
    let answer = found;
    if (answer === null && prepareJobs !== undefined) { prepareJobs(key); answer = true; }
    if (answer === null) { oldJobs ??= new Set(store.jobsUp().map((j) => j.sessionKey)); answer = oldJobs.has(key); }
    jobsRead.set(key, answer);
    return answer;
  };
  const working = (key: string) => {
    const row = store.getSession(key);
    if (!row) return true;
    const stat = statOf(key);
    const last = stat?.lastTurn ?? null;
    return row.running || hub.processState(key) === "running" || stat?.pending === true || (last !== null && last.endedAt === null) || hasUpJob(key);
  };
  const busy = (key: string) => working(key) || statOf(key)?.lastTurn?.declared === "block";
  // A chat someone pinned stays in the lists until put away by hand. (Read as a chat of its own needs it, where a reader
  // says it of the sessions.)
  let marks: ReturnType<typeof store.archiveMarks> | null = null;
  const pinned = (key: string) => (marks ??= store.archiveMarks()).pinned(key);
  const kept = (thread: number) => (marks ??= store.archiveMarks()).kept(thread);
  // Where only what the archive review recommended goes (`autoArchiveReviewed`): none while the review is off.
  const recommended = (thread: number) => !autoArchiveReviewed || (automaticDecisions.completion.enabled && store.archiveSuggested(thread));
  // Those the look found idle long enough, with what the reader read of each (null: its index not built yet).
  const lookPassed = new Map<string, { row: SessionRow; convMembers?: string[] }>();
  for (const { row: s, quiet, quietLong, facts: f } of look?.sessions ?? []) {
    if (f.work === null) continue;
    if (f.bound === null) { prepareBindings?.(); continue; }
    if (f.pinned === null || f.kept === null) { prepareMarks?.(); continue; }
    if (f.bound || f.pinned) continue;
    if (f.upJob === null) prepareJobs?.(s.key);
    const last = f.work.lastTurn;
    const workingNow = s.running || hub.processState(s.key) === "running" || f.work.pending || (last !== null && last.endedAt === null) || f.upJob !== false;
    const busyNow = workingNow || last?.declared === "block";
    const threads = f.threads;
    const slack = threads.length > 0 && threads.every((t) => t.thread.surface !== STILLFAIL_SURFACE);
    const done = quiet && !busyNow;
    const lingering = slack && quietLong && !workingNow;
    if (!done && !lingering) continue;
    if (!lingering && !threads.every((t) => recommended(t.thread.id))) continue;
    if (threads.some((t) => f.kept!.includes(t.thread.id) || unread(t.thread))) continue;
    lookPassed.set(s.key, { row: s, convMembers: f.convMembers });
  }
  const archivedLook = new Set<string>();
  for (const [k, item] of lookPassed) {
    const anchor = item.row.conv ?? k;
    if (archivedLook.has(anchor)) continue;
    archivedLook.add(anchor);
    const members = item.convMembers ?? store.membersOf(anchor);
    if (members.length > 0 && members.every((m) => lookPassed.has(m))) {
      log.info("hub", "archiving an idle session", { session: anchor });
      archiveBy(hub, anchor, true, AUTO, lookPassed.get(anchor)?.row, members);
    }
  }
  const livePassed = new Map<string, SessionRow>();
  // The latest conversations of each workspace stay in the lists (a reader's look leaves them out already).
  const recent = live.length > 0 ? recentConversations(store.db, hub.workspaces()[0] ?? null, autoArchiveKeep) : new Set<string>();
  for (const s of live) {
    if (recent.has(s.conv ?? s.key)) continue;
    if (waitingForBindings || (bindingsReady ? store.preparedSessionBound(s.key) : oldBindings!.has(s.key)) || pinned(s.key)) continue;
    // Idle long enough by its times alone, before anything else of it is read.
    const quiet = idle([s.lastActiveAt, s.shownAt]);
    const quietLong = idle([s.lastActiveAt, s.shownAt], slackArchiveMs);
    if (!quiet && !quietLong) continue;
    const threads = store.recentSessionThreads(s.key).threads;
    const slack = threads.length > 0 && threads.every((t) => t.thread.surface !== STILLFAIL_SURFACE);
    const done = quiet && !busy(s.key);
    const lingering = slack && quietLong && !working(s.key);
    if (!done && !lingering) continue;
    if (!lingering && !threads.every((t) => recommended(t.thread.id))) continue;
    if (threads.some((t) => kept(t.thread.id) || unread(t.thread))) continue;
    livePassed.set(s.key, s);
  }
  const archivedLive = new Set<string>();
  for (const k of livePassed.keys()) {
    const anchor = store.conversationOf(k);
    if (archivedLive.has(anchor)) continue;
    archivedLive.add(anchor);
    const members = store.membersOf(anchor);
    if (members.length > 0 && members.every((m) => livePassed.has(m))) {
      log.info("hub", "archiving an idle session", { session: anchor });
      archiveBy(hub, anchor, true, AUTO, livePassed.get(anchor));
    }
  }
  for (const t of own) {
    // (A reader's look gives those idle long enough and not kept alone.)
    if (look === undefined) {
      if (kept(t.id)) continue;
      const said = store.lastMessageAtForArchive(t.id);
      if (!said.known) { prepareLast?.(t.id); continue; }
      if (!idle([t.createdAt, said.at, t.shownAt])) continue;
    }
    if (unread(t) || !recommended(t.id)) continue;
    if (store.threadSessions(t.id).some((m) => pinned(m.session) || busy(m.session))) continue;
    log.info("hub", "archiving an idle chat", { thread: t.id });
    store.setThreadHidden(t.id, true, AUTO);
  }
  return next;
}

/// Check on the usual schedule, and try again when an old chat's missing unread boundary is ready.
export function startAutoArchiveTimer(hub: Hub, time: { after(ms: number, run: () => void): () => void },
  readers: { prepareSaid(threads: readonly number[], signal?: AbortSignal): Promise<void>; prepareSessionBindings(signal?: AbortSignal): Promise<void>;
    prepareSessionUpJobs(sessions: readonly string[], signal?: AbortSignal): Promise<void>; prepareArchiveMarks?(signal?: AbortSignal): Promise<void>;
    prepareArchiveLast?(threads: readonly number[], signal?: AbortSignal): Promise<void>;
    read?(op: string, args: Record<string, unknown>, lang: string): Promise<string> }): () => void {
  const cancel = new AbortController();
  let timer: (() => void) | null = null;
  let preparing = false;
  let preparingBindings = false;
  let preparingJobs = false;
  let preparingMarks = false;
  let preparingLast = false;
  let reading = false;
  const schedule = (ms: number) => {
    timer?.();
    timer = time.after(ms, check);
  };
  // A look: what to look at read by a reader where there is one (`archiveLook`), the archiving done here.
  const check = () => {
    timer = null;
    const read = readers.read;
    if (read === undefined) return pass(undefined);
    if (reading) return;
    reading = true;
    const { autoArchiveMs, slackArchiveMs, autoArchiveKeep } = hub.config();
    void read.call(readers, "archiveLook", { now: hub.now(), after: autoArchiveMs, slackAfter: slackArchiveMs, home: hub.workspaces()[0] ?? null, keep: autoArchiveKeep }, "zh").then((answer) => {
      reading = false;
      if (!cancel.signal.aborted) pass(JSON.parse(answer) as ArchiveLook);
    }, (error) => {
      reading = false;
      if (cancel.signal.aborted) return;
      log.warn("hub", "reading what to auto-archive failed", { error: (error as Error).message });
      schedule(600_000);
    });
  };
  const pass = (look: ArchiveLook | undefined) => {
    let next: number | null = null;
    const missing = new Set<number>();
    const missingJobs = new Set<string>();
    const missingLast = new Set<number>();
    let missingBindings = false;
    let missingMarks = false;
    try {
      next = autoArchive(hub, hub.now(), (thread) => missing.add(thread), () => { missingBindings = true; }, (session) => missingJobs.add(session),
        () => { missingMarks = true; }, (thread) => missingLast.add(thread), look);
    } catch (error) {
      log.warn("hub", "auto-archiving failed", { error: (error as Error).message });
    }
    schedule(Math.min(600_000, next === null ? Infinity : next - hub.now()));
    if (!preparingLast && missingLast.size && readers.prepareArchiveLast) {
      preparingLast = true;
      void readers.prepareArchiveLast([...missingLast], cancel.signal).then(() => {
        preparingLast = false;
        if (!cancel.signal.aborted) schedule(0);
      }, (error) => {
        preparingLast = false;
        if (!cancel.signal.aborted) log.warn("hub", "preparing last messages for auto-archiving failed", { error: (error as Error).message });
      });
    }
    if (!preparingMarks && missingMarks && readers.prepareArchiveMarks) {
      preparingMarks = true;
      void readers.prepareArchiveMarks(cancel.signal).then(() => {
        preparingMarks = false;
        if (!cancel.signal.aborted) schedule(0);
      }, (error) => {
        preparingMarks = false;
        if (!cancel.signal.aborted) log.warn("hub", "preparing archive marks failed", { error: (error as Error).message });
      });
    }
    if (!preparing && missing.size) {
      preparing = true;
      void readers.prepareSaid([...missing], cancel.signal).then(() => {
        preparing = false;
        if (!cancel.signal.aborted) schedule(0);
      }, (error) => {
        preparing = false;
        if (!cancel.signal.aborted) log.warn("hub", "preparing unread state for auto-archiving failed", { error: (error as Error).message });
      });
    }
    if (!preparingBindings && missingBindings) {
      preparingBindings = true;
      void readers.prepareSessionBindings(cancel.signal).then(() => {
        preparingBindings = false;
        if (!cancel.signal.aborted) schedule(0);
      }, (error) => {
        preparingBindings = false;
        if (!cancel.signal.aborted) log.warn("hub", "preparing bindings for auto-archiving failed", { error: (error as Error).message });
      });
    }
    if (!preparingJobs && missingJobs.size) {
      // Retry one archive pass when the requested batch is done, not one full pass per session. The regular timer
      // still checks sessions whose preparation finished while another has a longer old history.
      preparingJobs = true;
      void readers.prepareSessionUpJobs([...missingJobs], cancel.signal).then(() => {
        preparingJobs = false;
        if (!cancel.signal.aborted) schedule(0);
      }, (error) => {
        preparingJobs = false;
        if (!cancel.signal.aborted) log.warn("hub", "preparing jobs for auto-archiving failed", { error: (error as Error).message });
      });
    }
  };
  schedule(60_000);
  return () => { cancel.abort(); timer?.(); timer = null; };
}

/// Deletes a session: its process ends, its rows go (with the threads only it was in) and its workspace directory,
/// transcript copy, exclusive transcripts under `<data>`, and what the readers kept of its transcripts' reading with
/// them. Runtime transcripts in a person's own profile home outside `<data>`, or referenced by any other session row
/// (including archived ones), are never deleted.
export async function deleteSession(hub: Hub, key: string) {
  const row = hub.store.getSession(key);
  if (!row) throw new Error(`unknown session ${key}`);
  const actor = hub.dropActor(key);
  await actor?.dispose();
  // Flush any unread transcript tail into usage statistics before removing the session row and its transcripts.
  await hub.live.flushUsage(key).catch((error) => log.warn("hub", "flushing usage before session delete failed", { session: key, error: (error as Error).message }));
  hub.live.forget(key);
  hub.forgetIdleMeasured(key);
  const { dataDir, profiles } = hub.config();
  const sources = hub.store.runtimeSessionSources(key);
  const places = sessionPlaces(row);
  const transcripts = (await transcriptSourcesSoon(dataDir, profiles, sources, places)).paths.map((p) => p.path);
  // Collect exclusive transcript files and Claude session directories under `<data>` before removing the session row.
  const realData = await realpath(dataDir).catch(() => null);
  const exclusiveFiles: string[] = [];
  const exclusiveDirs: string[] = [];
  if (realData !== null) {
    for (const source of sources) {
      if (hub.store.transcriptReferenced(source.runtime, source.id, key)) continue;
      const runtime = runtimeNamed(source.runtime);
      if (!runtime) continue;
      const found = (await transcriptPathsSoon(runtime, dataDir, homesFirst(profiles, source.profile), [source.id], places)).paths[0];
      if (found === undefined) continue;
      const parent = await realpath(dirname(found)).catch((error: NodeJS.ErrnoException) => (error.code === "ENOENT" ? null : Promise.reject(error)));
      if (parent === null || !within(parent, realData)) continue;
      const logical = join(parent, basename(found));
      exclusiveFiles.push(logical);
      if (runtime === "claude") {
        const subDir = join(parent, basename(found, ".jsonl"));
        await jsonlFilesSoon(subDir, exclusiveFiles);
        exclusiveDirs.push(subDir);
      }
    }
  }
  hub.store.deleteSession(key);
  hub.closed(key);
  await rm(transcriptCopy(hub, key), { force: true });
  await forgetMarksSoon(marksDir(dataDir), transcripts);
  if (realData !== null) {
    for (const logical of new Set(exclusiveFiles)) {
      for (const candidate of [logical, packed(logical)]) {
        const st = await lstat(candidate).catch(() => null);
        if (st === null || st.isSymbolicLink()) continue;
        const realPath = await realpath(candidate).catch(() => null);
        if (realPath === null || !within(realPath, realData)) continue;
        await rm(candidate, { force: true }).catch((error) => log.warn("hub", "exclusive transcript not removed", { session: key, path: candidate, error: (error as Error).message }));
      }
    }
    for (const dir of new Set(exclusiveDirs)) {
      const st = await lstat(dir).catch(() => null);
      if (st === null || !st.isDirectory() || st.isSymbolicLink()) continue;
      const realDir = await realpath(dir).catch(() => null);
      if (realDir === null || !within(realDir, realData) || samePath(realDir, realData)) continue;
      await rm(dir, { recursive: true, force: true }).catch((error) => log.warn("hub", "exclusive transcript directory not removed", { session: key, path: dir, error: (error as Error).message }));
    }
  }
  // Sessions made by the station keep their workspace in a directory of their own under `<data>/sessions`.
  // Never remove directories outside `<data>/sessions` (e.g. a user's own repository).
  const room = await roomOfSoon(dataDir, row.workspace);
  if (room !== null) {
    await withLock(room, async () => {
      const worktrees = await collectWorktreeRegistrations(room);
      await unlockWorktrees(room);
      await rm(room, { recursive: true, force: true });
      const rawRoom = clean(dirname(row.workspace));
      await removeWorktreeRegistrations(worktrees, rawRoom === room ? [room] : [room, rawRoom]);
    });
  } else {
    const realSessions = await realpath(join(dataDir, "sessions")).catch(() => null);
    const realWs = await realpath(row.workspace).catch(() => null);
    if (realSessions !== null && realWs !== null && inside(realWs, realSessions)) {
      await rm(realWs, { recursive: true, force: true });
    } else if (realWs !== null) {
      log.warn("hub", "not removing session workspace outside station sessions directory", { session: key, workspace: row.workspace });
    }
  }
  log.info("hub", "session deleted", { session: key });
}

/// Copies a machine session's transcript to where the station's runtimes keep theirs (`shared`:
/// data/transcripts/<runtime>), at the same place under it, so a profile resumes it there: for Codex every file it keeps
/// the thread in. The originals are not touched. Where the transcript read is. Off the main thread: a Codex home's
/// rollouts walked as read/machine.ts `transcriptOf` walks them, bounded the same (ops/walk.ts), and a transcript of
/// hundreds of MB copied by the file system's own copy.
async function copyTranscript(roots: Roots, session: MachineSession, shared: string): Promise<string> {
  const root = session.runtime === "claude" ? roots.claude : roots.codex;
  const files = [session.path];
  if (session.runtime === "codex") {
    await walkBounded(
      root,
      (e) => {
        if (e.file && e.depth > 0 && e.name.startsWith("rollout-") && extension(e.name) === "jsonl" && e.path !== session.path && rolloutOf(e.path, session.id)) files.push(e.path);
      },
      { maxDepth: ROLLOUT_DEPTH, maxEntries: ROLLOUT_ENTRIES, followRoot: true },
    );
  }
  const under = (path: string) => {
    const rel = relative(root, path);
    if (rel.startsWith("..") || rel === "") throw new Error(`${path} is not the machine's`);
    return rel;
  };
  for (const from of files) {
    const to = join(shared, under(from));
    await mkdir(dirname(to), { recursive: true });
    const partial = to.replace(/\.jsonl$/, "") + ".jsonl.part";
    await copyFile(from, partial);
    await rename(partial, to);
  }
  return join(shared, under(session.path));
}

/// Goes on in a chat with a session the machine's own Claude Code or Codex kept (run in a terminal). Its transcript is
/// copied into the shared transcripts (the original is left as it was, and can go on in the terminal on its own); the
/// new session resumes it, running in the directory it ran in. The chat starts with a note of where it came from,
/// linking to the session's execution history, which shows what was said before (it is not copied into the chat). A
/// session already going on with it is that one's chat, brought back if archived. `ws`: the workspace the new chat is in
/// (null: the home one's).
export async function continueMachineSession(hub: Hub, roots: Roots, found: MachineSession, createdBy: string, lang: Lang = stationLang(), ws: string | null = null): Promise<[string, ThreadRow]> {
  const { store } = hub;
  const runtime = found.runtime;
  // One it went on in (a runtime session left for a new one included).
  const going = store.sessionOfRuntime(runtime, found.id);
  if (going) {
    const thread = store.homeChat(going.key);
    if (thread) {
      if (going.archivedAt !== null) {
        // Its files come back before its runtime starts in any case: a failure here is only told.
        void Promise.resolve()
          .then(() => archive(hub, going.key, false))
          .catch((error) => log.warn("hub", "archived session not shown again", { session: going.key, error: (error as Error).message }));
      }
      return [going.key, thread];
    }
  }
  // Looked at as ops/places.ts does: never on this thread in a folder macOS protects (still.fail Helper asked instead).
  try {
    await hub.places.directory(found.cwd, { lang });
  } catch (e) {
    if (e instanceof PlaceRefused && (e.code === "gone" || e.code === "not_a_directory")) throw new Error(tr(lang, "station.session.cwdGone", { cwd: found.cwd }));
    throw e;
  }
  // Looked at again, in case it was continued meanwhile.
  const already = store.sessionOfRuntime(runtime, found.id);
  if (already) {
    const thread = store.homeChat(already.key);
    if (thread) return [already.key, thread];
  }
  const config = hub.config();
  // On the profiles the chat's workspace runs on.
  const profiles = hub.profilesIn(ws).filter((p) => p.runtimes.includes(runtime));
  if (profiles.length === 0) throw new Error(tr(lang, "station.session.noProfile", { runtime: runtimeTitle(runtime) }));
  // The model it ran, where a profile runs it; else the one picked runs its own.
  const keptModel = found.model !== null && profiles.some((p) => p.models.includes(found.model!)) ? found.model : null;
  const profile = hub.accounts.pick(profiles, keptModel, false);
  const model = keptModel ?? profile.model ?? profile.models[0] ?? null;
  const copy = await copyTranscript(roots, found, sharedTranscripts(config.dataDir, runtime));
  // Where its execution history is when it comes here: its last entry, counted as the history reads it (from the shared
  // place, read/transcript.ts `transcriptPathsSoon`), by the readers, not on this thread.
  const entries = await hub.live.counted(runtime, copy);
  const last = entries > 0 ? entries - 1 : null;
  const key = newChatKey();
  const workspace = chatWorkspace(config.dataDir, key);
  await mkdir(workspace, { recursive: true });
  await mkdir(join(config.dataDir, "repos"), { recursive: true });
  const now = hub.now();
  const titleOf = found.title ?? found.first;
  const title = titleOf !== null ? Array.from(titleOf).slice(0, 80).join("") : null;
  store.insertSession({
    key,
    connect: INTERNAL_CONNECT,
    scope: "all",
    title,
    createdBy,
    runtime,
    profile: profile.id,
    profilePinned: false,
    model,
    effort: null,
    fast: null,
    workspace,
    cwd: found.cwd,
    runtimeSessionId: found.id,
    token: newToken(),
    createdAt: now,
    lastActiveAt: now,
    ...(ws !== null ? { ws } : {}),
  });
  log.info("hub", "session continued from the machine's own", { session: key, runtime, profile: profile.id, from: found.id, cwd: found.cwd });
  const thread = openChat(hub, key, createdBy, title);
  // What was said before stays in its transcript: the note links to the session's execution history, which shows it, at
  // where it was when it came here (the pages open `?history=<session>&entry=<n>` links there).
  const at = last !== null ? `&entry=${last}` : "";
  const note = tr(lang, "station.session.continued", { runtime: runtimeTitle(runtime), cwd: found.cwd, link: `?history=${key}${at}` });
  store.insertMessage({ thread: thread.id, ts: hub.nextTs(), authorKind: STATION_AUTHOR, author: STATION_AUTHOR, text: note });
  store.setRead(createdBy, thread.id, store.lastEntry(thread.id));
  return [key, thread];
}
