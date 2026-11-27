// `Core`: takes messages from connected UIs, answers calls, keeps subscriptions (core.rs for the
// protocol). Construction opens the signed-in accounts' databases (data.ts), wires the modules together and starts the
// sync (sync/), which keeps everything the core holds current by itself; subscriptions only read what is held.
import { Cause, Deferred, Effect, Fiber, type Clock } from "effect";
import type { AccountView } from "./accounts.ts";
import { type AccountProvider, type AccountProviderFactory, type AccountSessions, stillfailAccountProvider } from "./account-provider.ts";
import * as brand from "./brand.ts";
import * as commands from "./commands.ts";
import { findGo } from "./chat-find.ts";
import { mentionView, relayView } from "./relay-pick.ts";
import { wordsAnswer } from "./words.ts";
import { args } from "./activity.ts";
import { copiedRef } from "./refLinks.ts";
import { toolCall, toolResult, type ToolPart } from "./tool-step.ts";
import * as fonts from "./fonts.ts";
import { MermaidAbsent, mermaidChart, provideMermaid } from "./mermaid.ts";
import { parseCall, cancellable, callStation, counts, type Call } from "./core/calls.ts";
import { execute, handlers, hooks, rereadAfterWrite } from "./core/execute.ts";
import { Router } from "./core/routing.ts";
import { importFormer } from "./db/import.ts";
import { Data, holds } from "./data.ts";
import { chatDerive } from "./views/views.ts";
import { Doing, FAILED_SHOWN_MS, heavy } from "./doing.ts";
import { DriveKept } from "./drive-kept.ts";
import { CoreError, HostError, asCoreError, failedIn } from "./error.ts";
import { HEDGE, type Host } from "./host.ts";
import { t } from "./i18n.ts";
import { markdown } from "./markdown.ts";
import { AHEAD_AFTER_MS, MdAhead } from "./md-ahead.ts";
import * as prefs from "./prefs.ts";
import { Beside, parseClientMessage, topicKey, type CallAuth, type ClientId, type ClientMessage, type CoreMessage, type RequestId, type Topic, type WireGen } from "./protocol.ts";
import { TRACES } from "./route.ts";
import { laterSleep, Runner } from "./runtime.ts";
import { stationId } from "./station/addr.ts";
import { Status, Waited } from "./status.ts";
import { Store } from "./store.ts";
import { topicScopeOf } from "./auth-gen.ts";
import { CloudSync } from "./sync/cloud.ts";
import { Priority, Scheduler } from "./sync/scheduler.ts";
import { Kind, SAMPLE, Tracer, service } from "./trace.ts";
import { UseCounts, builtSink, type UsageSink } from "./use-counts.ts";
import { ownBuild } from "./station/oldest.ts";
import { spent, spentClock, spentSince } from "./spent.ts";
import { checkWith, keepVerified } from "./vault/verified.ts";
import { Wakes, WakingHost } from "./wake.ts";
import { ofAddress, Workspaces } from "./workspace.ts";
import { install as installStationCalls } from "./station/calls.ts";
import { install as installScreens, screenViewAuthOf } from "./screens.ts";
import { install as installTerminals, terminalViewAuthOf } from "./terminals.ts";
import { install as installFarview, farviewViewAuthOf } from "./farview.ts";
import { Composers, install as installComposer } from "./composer.ts";
import { StationsSync } from "./station/sync.ts";
import { SendTrace } from "./station/send-trace.ts";
import { StationTopics } from "./station/topics.ts";
import type { StationWire } from "./station/wire.ts";
import type { Mesh } from "./mesh.ts";
import { credentialsFor, meshWire } from "./station/mesh-wire.ts";
import type { Iroh } from "./iroh.ts";
import { ViewCalls } from "./views/calls.ts";
import { Attend } from "./attend.ts";
import { Attention } from "./attention.ts";
import { Pills } from "./pill.ts";
import { AdminRelays } from "./sync/admin-relays.ts";
import type { Choose } from "./choose.ts";
import { installChoose } from "./choose-calls.ts";
import { install as installShareIn } from "./share-in.ts";
import { Changelog } from "./changelog.ts";
import { FeedbackReplies } from "./feedback-replies.ts";
import { FontFiles } from "./font-files.ts";
import { installForms, type Forms } from "./forms-calls.ts";
import { Loads } from "./preview-load.ts";
import { Asks } from "./asks.ts";
import { Adb } from "./adb.ts";
import { Rigs } from "./rigs.ts";
import { Devices } from "./devices.ts";
import { Signer } from "./lock.ts";
import { EarlyReads, PersonalLock } from "./personal-lock.ts";
import { answersOf, asked, bindPerson, enrolled, inForceOf, keepToPerson, lockSeen, movedBySelf, movedHere, ownLockEnv, ownLockFor, personStations, personalStations, pinHash, refusedAgain, safeNow, signerKnown, signerOf, signsAs, takeOffBound, tellStations, tookOrRefused, withBound } from "./views/lock.ts";
import { personalBegin, personalCancel, personalPairState, personalProve } from "./views/pair.ts";
import { envOf, Views } from "./views/views.ts";
import * as xshare from "./views/xshare.ts";
import * as memberships from "./views/memberships.ts";
import * as publish from "./views/publish.ts";
import * as lockCalls from "./views/lock.ts";
import * as pairing from "./views/pair.ts";
import * as vaultCalls from "./views/vault.ts";
import * as waysCalls from "./views/ways-stations.ts";
import * as stationMarkCalls from "./views/station-marks.ts";
import * as presetCalls from "./views/presets.ts";
import * as projectCalls from "./views/projects.ts";
import * as boardDraftCalls from "./views/board-drafts.ts";
import * as progressCalls from "./views/progress.ts";
import * as movedChats from "./views/moved.ts";
import { MOVED } from "./station/requests.ts";
import * as transferCalls from "./views/transfers.ts";
import * as browseCalls from "./views/browse.ts";
import * as downloads from "./views/downloads.ts";
import * as fill from "./fill.ts";
import { get, isObject, sha256 } from "./util.ts";

/// Where a device's member credentials are kept (`credential/<account>/<workspace>`), and how long one serves.
export const CREDENTIAL_KEY = "credential";
export const CREDENTIAL_FOR_S = 24 * 60 * 60;
export const CREDENTIAL_OTHERS = "others";
/// How many of the device's other endpoints' credentials are kept: one for every way a workspace is reached (each relay,
/// `lan`, `tailnet`, each fence), so none pushes out another's and sends it to the cloud again on its next dial (production
/// 2026-11-23: 16 of them on 8 kept, 112 asks refused for too many in 25 minutes).
export const CREDENTIAL_OTHERS_KEPT = 32;
/// How many of an account's credential asks are out at once: a device dialling every endpoint of every workspace's
/// stations asked them all together (production 2026-11-23: 379 refused in 4 minutes, and the account's other requests
/// with them).
export const CREDENTIAL_ASK_CONCURRENCY = 4;
/// How long an account asks no credential after the cloud refused one for too many (429): what was asked again at once
/// only used up the next minute too.
export const CREDENTIAL_429_COOLDOWN_MS = 15_000;
/// Where this device's push registration is kept.
export const PUSH_KEY = "push";

/// How far a call has got, for a UI that asked to hear it; `bytes` go beside the value, not in it (protocol.ts).
export type Progress = (value: unknown, bytes?: Uint8Array) => void;

/// What a start spent before the core's own first step, as its native host measured it (hosts/engine.ts), in ms:
/// `before_ms` from the process's start to the core's thread's (the system launching the app, the app's own start);
/// `shell_ms` the shell started, the core's script read and its runtime made; `script_ms` the script run. A start
/// slow before the core says which of these grew (core.start `boot.*`).
export type Boot = { before_ms?: number; shell_ms?: number; script_ms?: number };

export type Options = {
  /// How the core reaches stations: the mesh by default; tests' stations answer over the host's fetch.
  wire?: (inner: Inner) => StationWire;
  /// The share of traces recorded (0: none).
  sample?: number;
  /// Whether this device sends its traces from the start, as if its app had said so (`client.reports`) before it
  /// asked anything: a test's; none, the core waits for the app to say.
  reports?: boolean;
  /// The clock the core's timers run on (a TestClock in tests).
  clock?: Clock.Clock;
  /// The iroh this host has (iroh.ts); none: stations are not reached over the mesh.
  iroh?: Iroh | null;
  /// Who the accounts are with (account-provider.ts): still.fail cloud unless the embedding app gives another
  /// (`commaAccountProvider`, comma.ts).
  account?: AccountProviderFactory;
  /// Where what people use is counted to (use-counts.ts): the project this build was given unless a test gives its own.
  usage?: UsageSink | null;
  /// What the start spent before the core, where its host measured it.
  boot?: Boot;
};

/// What the core holds: every module.
export class Inner {
  host!: Host;
  runner!: Runner;
  tracer!: Tracer;
  /// What a start reads of this device's keys once (`signer`: views/lock.ts `install`; `box`: views/vault.ts `install`),
  /// told as each is read: the start's span (`startTrace`).
  startRead: (what: "signer" | "box") => void = () => {};
  /// When the core's own first step began (the host's monotonic ms; -1: not yet): the start's span's zero
  /// (`startTrace`), what the app's first page is timed from too (`app.first_page` `since_core_ms`).
  startedAt = -1;
  /// What people use, counted for still.fail's PostHog project where the app says so (use-counts.ts).
  useCounts!: UseCounts;
  /// What app the UI said it is (`client.device`'s `app`): the counts' `app`.
  deviceApp = "";
  /// Whether client telemetry (error/metric/send-trace spans) is enabled; controlled by `client.reports` (null: not yet
  /// told, the spans made then kept on this device until it is: trace.ts `Tracer.setOn`).
  reporting: boolean | null = null;
  /// Counter for deterministic 20% `bar.switch` sampling.
  barSwitchCount = 0;
  /// End-to-end `chat.send` -> first live event tracer.
  sendTrace!: SendTrace;
  /// Client errors recorded lately, by source and message, and when.
  reported = new Map<string, number>();
  /// The control plane the accounts are with, and the accounts.
  provider!: AccountProvider;
  accounts!: AccountSessions;
  store!: Store;
  data!: Data;
  workspaces!: Workspaces;
  /// What the device waits on: still.fail cloud, its sockets, the relay for no station.
  status!: Status;
  /// The requests waited on now, every workspace's and the device's (status.ts).
  waited!: Waited;
  /// Files of the stations' drives kept on this device once read, for an app that asks (drive-kept.ts).
  driveKept!: DriveKept;
  wakes!: Wakes;
  scheduler!: Scheduler;
  cloudSync!: CloudSync;
  stations!: StationsSync;
  stationTopics!: StationTopics;
  views!: Views;
  /// The iroh this host has, and the mesh over it once up (mesh.ts).
  iroh: Iroh | null = null;
  /// None until a wire over the mesh is made (a core whose stations answer otherwise has none).
  mesh: () => Effect.Effect<Mesh, CoreError> = () => Effect.fail(new CoreError("unsupported", t("station.core.oneWay")));
  meshNow: () => Mesh | null = () => null;
  attention!: Attention;
  choose!: Choose;
  /// A person's presets and starred models as their devices carry them (views/presets.ts).
  presets!: presetCalls.PresetViews;
  /// A person's drafts of 待派发 as their devices carry them (views/board-drafts.ts).
  boardDrafts!: boardDraftCalls.BoardDraftViews;
  /// How a person's agents are asked for progress, as their devices carry it (views/progress.ts).
  progress!: progressCalls.ProgressViews;
  changelog!: Changelog;
  forms!: Forms;
  adb!: Adb;
  /// The workspaces' rigs (rigs.ts).
  rigs!: Rigs;
  /// The workspaces' devices (devices.ts).
  devices!: Devices;
  viewCalls!: ViewCalls;
  /// This device's downloads of chats' files (views/downloads.ts).
  downloads!: downloads.Downloads;
  /// What was opened and let go, brought whole after everything else (fill.ts).
  fill!: fill.Fill;
  router!: Router;
  /// The calls under way that a UI can stop, by `client/id`.
  calls = new Map<string, Fiber.Fiber<unknown, unknown>>();
  doing = new Doing();
  /// What is being written in each chat (composer.ts).
  composers!: Composers;
  /// The accounts as last shown, so a change UIs cannot see (a refreshed token) is not one.
  shownAccounts: AccountView[] = [];
  /// Recomputes authoritative `(account, workspace)` authorization digest for `ws`.
  syncWorkspaceAuth?: (ws: string) => void;
  /// Workspaces whose `authGen` advanced on a same-owner downgrade/revocation/safeMode boundary and are awaiting
  /// fresh post-boundary per-topic/per-station data confirmation before releasing held `Data` records.
  pendingAuthConfirm = new Map<string, { gen: number; confirmedKeys: Set<string> }>();
  /// Confirms fresh post-boundary data for `ws` (per `topic` when given, or whole workspace if omitted) and wakes blocked subscribers.
  confirmWorkspaceAuth?: (ws: string, topic: Topic, readGen: number) => void;
}

/// The start's span (`core.start`): each step's ms as it ends (`step`); then, once the person's own lock of every account
/// and this device's keys are read from the device, or `START_TOLD_MS` passed, or the core stopped first, how long each
/// took from the start (`ownLock`) with what the core's parts spent meanwhile; what was spent before `Core.make`, where
/// the host measured it (`Boot`), with them.
function startTrace(inner: Inner, boot: Boot | undefined): { step: (name: string) => void; set: (key: string, value: number | boolean | string) => void; ownLock: () => void } {
  const span = inner.tracer.root("core.start", Kind.Internal);
  for (const [key, ms] of Object.entries(boot ?? {})) span.set(`stillfail.boot.${key}`, ms);
  const t0 = inner.host.monotonicMs();
  inner.startedAt = t0;
  const spentFrom = { ...spent };
  const since = () => Math.round(inner.host.monotonicMs() - t0);
  const keys = { signer: Deferred.makeUnsafe<void>(), box: Deferred.makeUnsafe<void>() };
  inner.startRead = (what) => {
    if (Deferred.isDoneUnsafe(keys[what])) return;
    span.set(`stillfail.${what}_ms`, since());
    Deferred.doneUnsafe(keys[what], Effect.void);
  };
  let at = t0;
  return {
    step: (name) => {
      const now = inner.host.monotonicMs();
      span.set(`stillfail.ms.${name}`, Math.round(now - at));
      at = now;
    },
    set: (key, value) => span.set(key, value),
    ownLock: () => {
      const subs = inner.accounts.list().map((a) => a.sub);
      span.set("stillfail.accounts", subs.length);
      const personal = inner.adb.personal();
      const own = Effect.tap(Effect.forEach(subs, (sub) => personal.whenLoaded(sub), { discard: true, concurrency: "unbounded" }), () =>
        Effect.sync(() => span.set("stillfail.own_lock_ms", since())));
      const all = Effect.all([own, Deferred.await(keys.signer), Deferred.await(keys.box)], { discard: true, concurrency: "unbounded" });
      const told = (read: boolean) => {
        span.set("stillfail.own_lock_read", read);
        span.set("stillfail.start_ms", since());
        for (const [part, ms] of spentSince(spentFrom)) span.set(`stillfail.part.${part}`, Math.round(ms));
        span.end();
      };
      inner.runner.fork(
        Effect.onInterrupt(
          Effect.andThen(
            Effect.timeoutOption(all, START_TOLD_MS), // timer: a deadline, the start told though a read never ends
            (done) => Effect.sync(() => told(done._tag === "Some")),
          ),
          // (the core stopped first, the app quit soon: told all the same, or the starts told would be those that lasted)
          () => Effect.sync(() => told(false)),
        ),
      );
    },
  };
}
const START_TOLD_MS = 30_000;

/// Process-wide monotonic connection instance counter (seeded from persisted device storage on `Core.make`),
/// ensuring Core restarts never regress `conn` to a value `<=` the client's previous `conn_id`.
let nextConnSeq = 0;

export class Core {
  readonly inner: Inner;
  #nextClient = 1;
  readonly #connectedClients = new Set<ClientId>();
  readonly #authRetryFibers = new Map<ClientId, ReturnType<Runner["fork"]>>();

  private constructor(inner: Inner) {
    this.inner = inner;
  }

  /// A core on `host`, its timers on `options.clock`; it starts syncing at once, from what the database holds.
  static create(host: Host, options: Options = {}): Promise<Core> {
    const inner = new Inner();
    inner.runner = new Runner(options.clock);
    return inner.runner.run(Core.make(inner, host, options));
  }

  static make(inner: Inner, host: Host, options: Options): Effect.Effect<Core> {
    return Effect.gen(function* () {
      inner.wakes = new Wakes();
      // Everything the core asks of the host is given up or opened again when a UI comes back (wake.ts).
      inner.host = new WakingHost(host, inner.wakes, HEDGE);
      Signer.bindRunner(inner.host, inner.runner);
      inner.driveKept = new DriveKept(inner.host);
      // (the files kept for messages left behind a week)
      inner.runner.fork(inner.driveKept.dropOldUploads());
      brand.setTestChannel(inner.host.testChannel());
      brand.setCloud(inner.host.cloudOrigin());
      fonts.setOrigin(inner.host.cloudOrigin(), inner.host.testChannel());
      // (sending nothing until the app has said, as its settings say, that it may: client.reports)
      inner.tracer = new Tracer(inner.host, inner.runner, options.sample ?? SAMPLE, TRACES, options.reports ?? null);
      inner.reporting = options.reports ?? null;
      inner.sendTrace = new SendTrace(inner.tracer, inner.runner, () => inner.host.monotonicMs(), () => inner.reporting !== false);
      inner.useCounts = new UseCounts(inner.host, inner.runner, options.usage === undefined ? builtSink() : options.usage, () => inner.accounts.list()[0]?.sub ?? null, () => ({
        app: inner.deviceApp !== "" ? inner.deviceApp : service.os === "browser" ? "web" : "",
        os: service.os,
        build: ownBuild(),
      }));
      prefs.setCounted(inner.useCounts.sends);
      prefs.setTraced((options.sample ?? SAMPLE) > 0);
      spentClock(() => inner.host.monotonicMs());
      // How long this start took, by step, and till what the person's own lock is read from the device (the vaults'
      // pages and cards wait on it, views/vault.ts `lockRead`): a start grown slow says which step grew.
      const start = startTrace(inner, options.boot);
      // A failure let go of is a span of its own: Cloud Trace has it though nothing waited on it.
      inner.runner.onIgnored = (what, error) => {
        const span = inner.tracer.root("ignored", Kind.Internal);
        span.set("stillfail.ignored", what);
        failedIn(span, asCoreError(error));
        span.end();
      };
      inner.waited = new Waited(() => inner.host.nowMs());
      inner.status = new Status(inner.host, inner.runner, inner.waited);
      inner.provider = yield* (options.account ?? stillfailAccountProvider)({ host: inner.host, tracer: inner.tracer, status: inner.status });
      inner.accounts = inner.provider.accounts;
      start.step("accounts");
      // (what the device keeps of each person's own lock read beside the databases, not after them: views/vault.ts
      // `lockRead`)
      const early = new EarlyReads(inner.host, inner.runner, inner.accounts.list().map((a) => a.sub));
      inner.workspaces = new Workspaces(inner.host, inner.runner, inner.waited);
      inner.store = new Store(inner.host, inner.runner, inner.tracer);
      inner.syncWorkspaceAuth = (ws: string) => syncWorkspaceAuth(inner, ws);
      inner.confirmWorkspaceAuth = (ws: string, topic: Topic, readGen: number) => {
        const pending = inner.pendingAuthConfirm.get(ws);
        if (pending === undefined) return;
        if (inner.store.authGen.workspaceAuthGen(ws) !== readGen) return;
        const k = topicKey(topic);
        if (!pending.confirmedKeys.has(k)) {
          pending.confirmedKeys.add(k);
          inner.store.changed(topic);
        }
      };
      const store = inner.store;
      // Each signed-in account's database, opened before any network: the first view is answered from it.
      inner.data = new Data(inner.host, inner.runner, {
        owner: (workspace) => inner.workspaces.owner(workspace),
        ownerVerified: (workspace) => {
          const sub = inner.workspaces.owner(workspace);
          return sub !== null && !inner.cloudSync?.hasEarlierDeferred(sub);
        },
        derive: chatDerive,
      });
      // What the former records store and the Rust core's kept chunks held, brought into an account's new database once
      // before the database is published in `#dbs` (so a concurrent sign-out cannot close it mid-import).
      inner.data.onOpened = (db) =>
        importFormer(inner.host, inner.runner, inner.data, inner.accounts.list().map((a) => a.sub), db);
      // What was done here and kept in it goes on once the database is published (opened after the start: deferred or signed in).
      inner.data.onPublished = (db) => inner.views?.local.opened(db);
      inner.data.onSignedOut = (sub, me) => inner.cloudSync?.signedOut(sub, me);
      inner.data.onNote = () => inner.status.setDb(inner.data.notes);
      inner.data.onRoomAgain = (kept) => inner.stations?.roomAgain(kept);
      inner.data.onReplay = (affected) => inner.stations?.replayWrites(affected);
      // (this device's notice settings read beside the databases, not after them: each read at a start waits its turn on
      // the host's disk)
      const attend = inner.runner.fork(Attend.load(inner.host));
      const subs = inner.accounts.list().map((a) => a.sub);
      const tDevice = inner.host.monotonicMs();
      yield* inner.data.loadDevice();
      const dbDeviceMs = inner.host.monotonicMs() - tDevice;
      const activeWs = prefs.lastWorkspace(inner.data);
      const cachedOwners = inner.data.device.get("choice", "workspaceOwners");
      const primarySub = activeWs !== null && isObject(cachedOwners) && typeof cachedOwners[activeWs] === "string" ? cachedOwners[activeWs] : null;
      const defer = subs.length > 1 && primarySub !== null && subs.includes(primarySub);
      const firstSubs = defer ? [primarySub] : subs;
      const restSubs = defer ? subs.filter((s) => s !== primarySub) : [];
      inner.data.setOrder(subs, restSubs);
      const dbTiming = { openMs: 0, ensureMs: 0, importMs: 0 };
      yield* inner.data.openAccounts(firstSubs, dbTiming);
      start.set("stillfail.ms.db_device", Math.round(dbDeviceMs));
      start.set("stillfail.ms.db_open", Math.round(dbTiming.openMs));
      start.set("stillfail.ms.db_ensure", Math.round(dbTiming.ensureMs));
      start.set("stillfail.ms.db_import", Math.round(dbTiming.importMs));
      start.set("stillfail.db_deferred", restSubs.length);
      start.step("db");
      // Seed monotonic cross-restart connection id counter from device storage and wall clock (microseconds + jitter)
      // so even an unclean crash before flushing device storage or same-ms startup never collides with a previous connId.
      const storedConn = inner.data.device.get("auth", "connSeq");
      const floorConn = Math.floor(Date.now() * 1000) + Math.floor(Math.random() * 1000);
      if (floorConn > nextConnSeq) nextConnSeq = floorConn;
      if (typeof storedConn === "number" && Number.isInteger(storedConn) && storedConn > nextConnSeq) {
        nextConnSeq = storedConn;
      }
      if (!inner.data.device.isUnloaded("auth")) {
        inner.data.device.put("auth", "connSeq", nextConnSeq);
        yield* Effect.ignore(inner.data.device.flushTable("auth"));
      }
      // Authorization gate: refuse reading/emitting positive held Data records for workspaces or accounts not currently
      // authorized by a signed-in account, or while awaiting fresh post-boundary per-topic/per-station confirmation
      // after same-owner downgrade/revocation/safeMode changes. Pure local topics (`draft`, `prefs`) are never gated.
      store.setAuthorize((topic, authGen) => {
        if (topic.topic === "draft" || topic.topic === "prefs") return true;
        // Gate held Data records (`holds(topic)`): derived view topics (`lock`, `vaults`, `station`, `adb`, etc.)
        // must always be allowed to recompute and emit fresh empty / `{ gone: true }` / locked states.
        if (!holds(topic)) return true;
        const scope = topicScopeOf(topic);
        if (scope.kind === "device" || scope.kind === "global") return true;
        if (scope.kind === "account") {
          return scope.account === "" || inner.accounts.list().some((a) => a.sub === scope.account);
        }
        const ws = scope.workspace;
        if (ws === "" || ws === "all" || ws === "*") return true;
        const owner = inner.workspaces.owner(ws);
        if (owner === null || !inner.accounts.list().some((a) => a.sub === owner)) return false;
        // Pure local `drivePlace` still requires workspace ownership above, but never waits on post-downgrade station re-read.
        if (topic.topic === "drivePlace") return true;
        const pending = inner.pendingAuthConfirm.get(ws);
        if (pending !== undefined && authGen >= pending.gen && !pending.confirmedKeys.has(topicKey(topic))) {
          return false;
        }
        return true;
      });
      // (signatures checked once on this device, kept with its own values: vault/verified.ts)
      keepVerified({ get: (k) => inner.data.device.get("verified", k), put: (k, ok) => void inner.data.device.put("verified", k, ok) });
      // (checked by the host's own, where it has one: a native app's shell, libcrux)
      checkWith(inner.host.verify ? (alg, key, signature, message) => inner.host.verify!(alg, key, signature, message) : null);
      // (a device whose prefs say it sends nothing (the settings' switch where the host keeps none of its own: macOS,
      // Windows, Linux, the web) sends no trace from its start, before its app has said so)
      if (prefs.reportsOff(inner.data)) {
        inner.reporting = false;
        inner.tracer.setOn(false);
      }
      prefs.followLang(inner.data);
      prefs.followApp(inner.data);
      // What goes out is what the clients' types say (client/core-ts/src/shapes/schema.ts).
      store.setShaped();
      store.setHeld((topic) => topic.topic === "draft"
        ? inner.composers.readDraft(String(topic.station), String(topic.chat))
        : inner.data.shared(topic), (topic) => inner.data.release(topic));
      inner.data.onChange((topic) => {
        if (topic.topic === "*") {
          for (const [ws] of inner.workspaces.owned()) syncWorkspaceAuth(inner, ws);
          for (const t of store.liveTopics()) if (holds(t)) store.changed(t);
        } else {
          if (topic.topic === "workspace" && typeof topic.workspace === "string") {
            syncWorkspaceAuth(inner, topic.workspace);
          }
          store.changed(topic);
        }
      });
      // Why a station down is not reached is said again as still.fail cloud is reached, or no longer is.
      inner.status.onCloud = () => inner.stations?.recause();
      inner.scheduler = new Scheduler(inner.runner, inner.runner.root);
      inner.cloudSync = new CloudSync(inner);
      inner.status.setNames((address) => inner.cloudSync.nameOf(address));
      inner.workspaces.wireStatus((address) => inner.cloudSync.nameOf(address));
      inner.router = new Router(inner);
      store.setSource(inner.router);
      inner.iroh = options.iroh ?? null;
      inner.stations = new StationsSync(inner, options.wire ? options.wire(inner) : meshWire(inner));
      inner.stationTopics = new StationTopics(inner, inner.stations);
      inner.router.owners.push(inner.stationTopics);
      installStationCalls();
      installScreens();
      installTerminals();
      installFarview();
      inner.composers = new Composers(inner);
      installComposer();
      inner.views = new Views(envOf(inner));
      inner.views.local.onMade = (station, key) => inner.composers.made(station, key);
      inner.router.owners.push(inner.views);
      inner.viewCalls = new ViewCalls(inner, inner.views);
      inner.viewCalls.install();
      // What agents said lately read ahead, kept on the device: a chat opens with its Markdown read (md-ahead.ts).
      const ahead = new MdAhead(inner.data, inner.runner, () => inner.host.nowMs(), (station, of) => inner.data.mdChanged(station, of), () => inner.store.turn());
      inner.data.onOldMd = (station, of, text) => ahead.refresh(station, of, text);
      // (what reading and showing them notes of the trees written after what pages wait for: data.ts `flushMd`)
      inner.data.mdTurn = () => inner.store.turn();
      inner.data.onLogChange((table, station, id) => {
        if (table === "entry") ahead.thread(station, Number(id));
      });
      xshare.install(inner);
      memberships.install(inner);
      publish.install(inner);
      lockCalls.install(inner);
      pairing.install(inner);
      vaultCalls.install(inner);
      waysCalls.install(inner);
      stationMarkCalls.install(inner);
      inner.presets = presetCalls.install(inner);
      projectCalls.install(inner);
      inner.boardDrafts = boardDraftCalls.install(inner);
      inner.progress = progressCalls.install(inner);
      movedChats.install(inner);
      transferCalls.install(inner);
      browseCalls.install(inner);
      downloads.install(inner);
      fill.install(inner);
      start.step("install");
      inner.attention = new Attention(inner, yield* Fiber.join(attend));
      start.step("attend");
      inner.router.owners.push(inner.attention);
      inner.router.after = (topic, value) => inner.attention.attended(topic, value);
      inner.router.attends = (topic) => topic.topic === "chat";
      inner.attention.install();
      inner.choose = installChoose(inner);
      installShareIn(inner);
      inner.forms = installForms(inner);
      const asks = new Asks(inner.host, (from, to) => inner.changelog.brings(from, to), (address) => inner.views?.stationNow(address) ?? address, (address, by) => inner.data.chatNow(address, by));
      asks.follow(inner.accounts);
      // A release may be out (still.fail cloud said one is, or its events socket opened again: what it said while closed
      // is not said again): the newest of each feed read again when next asked, and the app told (the `releases`
      // topic's `told`) so the build it gets ready is the newest, not one read before.
      let told = 0;
      const releaseOut = () => {
        asks.released();
        told += 1;
        inner.store.invalidate({ topic: "releases" });
      };
      inner.router.owners.push({ owns: (topic) => topic.topic === "releases", compute: () => ({ ok: { told } }) });
      inner.cloudSync.onRelease = releaseOut;
      inner.adb = new Adb({
        host: inner.host,
        runner: inner.runner,
        store: inner.store,
        mesh: () => inner.mesh(),
        credentials: credentialsFor(inner, () => inner.meshNow()),
        relays: (workspace) => inner.cloudSync.workspaceRelays(workspace),
        off: (workspace) => inner.cloudSync.workspaceOff(workspace),
        part: (station, key, name, offset, length) => inner.stations.requests.filePart(station, key, name, offset, length, null, undefined, undefined, undefined, true),
        lends: () => inner.host.tcp !== undefined && (inner.data.shared({ topic: "prefs" }) as { device?: { app?: unknown } } | undefined)?.device?.app === "android",
        personal: new PersonalLock({
          host: inner.host,
          runner: inner.runner,
          early,
          cloud: (sub, method, path, body) => inner.provider.request(sub, method, path, body),
          device: () => Effect.map(inner.mesh(), (m) => m.deviceId()),
          label: () => prefs.deviceName(inner.data) ?? "",
          signKey: () => signerOf(inner),
          makeSignKey: () => (inner.host.appKeys ? Effect.map(Effect.orElseSucceed(Signer.make(inner.host), () => null), (signer) => {
            if (signer) signerKnown(inner, signer.id);
            return signer?.id ?? null;
          }) : Effect.succeed(null)),
          ...ownLockEnv(inner),
          changed: () => {
            inner.adb.touched();
            inner.rigs?.touched();
            for (const [ws] of inner.workspaces.owned()) {
              lockSeen(inner).touch(`lock ${ws}`);
              inner.runner.fork(bindPerson(inner, ws));
              inner.runner.fork(keepToPerson(inner, ws));
              inner.runner.fork(ownLockFor(inner, ws));
              refusedAgain(inner, ws);
              // (handed over by itself once a station took all it said: views/lock.ts `movedBySelf`)
              inner.runner.fork(movedBySelf(inner, ws));
              // (where its chain moved, the state in force made anew of the person's log now, the vaults following it:
              // views/lock.ts `inForceOf`, whether or not anything shown reads it)
              if (movedHere(inner, ws)) inner.runner.fork(laterSleep(0).pipe(Effect.andThen(Effect.sync(() => (inForceOf(inner, ws), syncWorkspaceAuth(inner, ws))))));
              // (no safe mode: the vault goes by this very lock, views/vault.ts `personalLockOf`; its page and the chats'
              // cards answered again, what it takes held, as a workspace's lock coming does)
              else if (!safeNow(inner, ws)) inner.runner.fork(laterSleep(0).pipe(Effect.andThen(Effect.sync(() => (syncWorkspaceAuth(inner, ws), vaultCalls.vaultCome(inner, ws))))));
            }
          },
          told: (sub, chain) => tellStations(inner, sub, chain),
          stations: personalStations(inner),
          asked: () => asked(inner),
        }),
        // (the vaults read first, while the device is still in: views/vault.ts `levelVaults`)
        tookOff: (sub, id, removal) => Effect.andThen(vaultCalls.levelVaultsOf(inner, sub, id), withBound(inner, sub, Effect.tap(removal, () => takeOffBound(inner, sub, id)))),
        subOf: (workspace) => inner.workspaces.owner(workspace),
        stationsOf: (sub) => personStations(inner, sub).map(String),
        subs: () => inner.accounts.list().map((a) => ({ sub: a.sub, email: a.email })),
        pair: {
          begin: (subs) => personalBegin(inner, subs),
          code: (typed) => personalProve(inner, typed),
          cancel: () => personalCancel(inner),
          state: (sub) => personalPairState(inner, sub),
        },
      });
      handlers.adb = (_i, call) => inner.adb.run((call as Extract<Call, { kind: "adb" }>).call);
      // The workspaces' rigs (a station that only runs tasks), as their stations say them; what their person signs for them.
      inner.rigs = new Rigs({
        host: inner.host,
        store: inner.store,
        personal: () => inner.adb.personal(),
        subOf: (workspace) => inner.workspaces.owner(workspace),
        view: (workspace) => inner.data.shared({ topic: "workspace", workspace }),
        call: (station, method, path, body) => inner.stations.requests.call(station, method, path, body, { quiet: true }),
        // (a station's mode changed: the workspace's view it answers with is held at once, as a write through `op` is,
        // so its page follows with no event of the cloud's; core/execute.ts)
        cloud: (sub, method, path, body) => {
          const wsMatch = /^\/v1\/workspaces\/([^/]+)/.exec(path.split("?")[0]!);
          const wsId = wsMatch ? decodeURIComponent(wsMatch[1]!) : null;
          const preReadGen = wsId !== null ? inner.store.authGen.workspaceAuthGen(wsId) : undefined;
          return Effect.tap(inner.provider.request(sub, method, path, body), (answer) =>
            method === "PATCH" ? rereadAfterWrite(inner, inner.cloudSync.afterWrite(sub, method, path, answer, preReadGen), null) : Effect.void);
        },
        first: (asks, at) => answersOf(inner, asks, tookOrRefused, at),
        lock: {
          locked: (workspace) => signsAs(inner, workspace).locked,
          enrolled: (sub, workspace, made) => enrolled(inner, sub, workspace, made),
          signsAs: (workspace) => signsAs(inner, workspace).as,
          pinHash: (workspace) => pinHash(inner, workspace),
          signAdd: (_workspace, bytes) =>
            Effect.flatMap(Signer.load(inner.host), (signer) =>
              signer === null ? Effect.fail(new CoreError("lock_no_signer", t("core-misc.rig.notSigner"))) : Effect.succeed({ key: signer.id, sig: signer.signBytes(bytes) })),
        },
        sha256,
      });
      handlers.rig = (_i, call) => inner.rigs.run((call as Extract<Call, { kind: "rig" }>).call);
      // (read whole as a station is first read; after that its `rigs` event says each change, a stream that was away
      // told the last of them as it goes on)
      inner.stations.also.push({ read: (address) => inner.rigs.read(address), event: (address, name, data) => inner.rigs.heard(address, name, data) });
      // The workspaces' devices: the whole stations' own, the rigs' (as the rigs say them), the phones lent to stations.
      inner.devices = new Devices({
        host: inner.host,
        store: inner.store,
        rigs: () => inner.rigs,
        personal: () => inner.adb.personal(),
        subOf: (workspace) => inner.workspaces.owner(workspace),
        emailOf: (workspace) => {
          const sub = inner.workspaces.owner(workspace);
          return sub === null ? null : (inner.accounts.list().find((a) => a.sub === sub)?.email ?? null);
        },
        view: (workspace) => inner.data.shared({ topic: "workspace", workspace }),
        call: (station, method, path, body) => inner.stations.requests.call(station, method, path, body, { quiet: true }),
      });
      handlers.device = (_i, call) => inner.devices.run((call as Extract<Call, { kind: "device" }>).call);
      inner.stations.also.push({ read: (address) => inner.devices.read(address), event: (address, name, data) => inner.devices.heard(address, name, data) });
      // This person's chats' grants of their phone, as each station says them.
      inner.stations.also.push({
        read: (address) => inner.adb.readGrants(address),
        event: (address, name, data, readGen) =>
          name === "adb-grant"
            ? inner.adb.heard(address, data, readGen)
            : name === "adb-revoke"
              ? inner.adb.heardRevoke(address, data)
              : undefined,
        resume: true,
      });
      handlers.ask = (_i, call) => asks.run((call as Extract<Call, { kind: "ask" }>).ask, inner.accounts);
      inner.changelog = new Changelog(inner.host, inner.store, inner.data);
      inner.router.owners.push(inner.changelog);
      const feedbackReplies = new FeedbackReplies(inner.host, inner.data, (workspace) => inner.workspaces.owner(workspace));
      inner.router.owners.push(feedbackReplies);
      handlers.changelogSeen = () => Effect.sync(() => (inner.changelog.seen(), null));
      handlers.feedbackDismiss = (_i, call) => {
        const c = call as Extract<Call, { kind: "feedbackDismiss" }>;
        return Effect.sync(() => (feedbackReplies.dismiss(c.workspace, c.id, c.reply), null));
      };
      handlers.historyTool = (_i, call) => {
        const c = call as Extract<Call, { kind: "historyTool" }>;
        // A chat the call names by its link (chat_read, session_history, session_send) shown by its title, linking to
        // it, where the device's lists know it: the link alone reads as an address, not as which chat.
        // (read from the call as given: its fields may say an opaque link as 其他对话)
        const given = args(c.call);
        const titled = (r: { key: string; value: string; form: "short" | "long" | "json"; prose?: true }) => {
          const raw = given?.[r.key];
          if ((r.key !== "chat" && r.key !== "to") || typeof raw !== "string") return r;
          const link = raw.trim().replace(/^@/, "").replace(/^<(.*)>$/, "$1");
          const title = /^https?:\/\//.test(link) ? inner.views?.chatTitleOfLink(link) : undefined;
          return title === undefined ? r : { key: r.key, value: copiedRef(title, link).plain, form: "long" as const };
        };
        // Markdown read here for the clients that draw its tree (markdown.ts), as everywhere else.
        const withMd = (parts: ToolPart[]) =>
          parts.map((part) => {
            if (part.kind === "markdown") return { ...part, md: markdown(part.text) };
            if (part.kind === "fields") {
              return {
                ...part,
                rows: part.rows.map(titled).map((r) => (r.form === "long" ? { ...r, md: markdown(r.value) } : r)),
              };
            }
            return part;
          });
        return Effect.sync(() => ({
          call: withMd(toolCall(c.name, c.call, c.said, t)),
          result: c.result === null ? null : withMd(toolResult(c.name, c.call, c.result, c.failed, t)),
        }));
      };
      handlers.words = (_i, call) => {
        const c = call as Extract<Call, { kind: "words" }>;
        return Effect.sync(() => wordsAnswer(c.what, c.text, c.caret, c.here));
      };
      handlers.chatFindGo = (_i, call) => {
        const c = call as Extract<Call, { kind: "chatFindGo" }>;
        return Effect.sync(() => findGo(c.hits, c.at, c.by, c.from, c.to, c.drawn));
      };
      handlers.relayView = (_i, call) => {
        const c = call as Extract<Call, { kind: "relayView" }>;
        return Effect.sync(() => relayView(c.connects, c.query, c.all, c.bot, t, c.place));
      };
      handlers.relayMentions = (_i, call) => {
        const c = call as Extract<Call, { kind: "relayMentions" }>;
        return Effect.sync(() => mentionView(c.people, c.note));
      };
      handlers.commandsFind = (_i, call) => {
        const c = call as Extract<Call, { kind: "commandsFind" }>;
        return Effect.sync(() => commands.find(c.query, c.offered, t));
      };
      handlers.mermaidChart = (_i, call) => {
        const c = call as Extract<Call, { kind: "mermaidChart" }>;
        // refused: the chart's code as mermaid read it is no chart this draws (the app shows it another way)
        return Effect.tryPromise({
          try: () => mermaidChart(c.code, c.look, c.width),
          catch: (e) => new CoreError(e instanceof MermaidAbsent ? "mermaid_absent" : "unsupported", e instanceof Error ? e.message : String(e)),
        });
      };
      handlers.mermaidLoad = (_i, call) => {
        const c = call as Extract<Call, { kind: "mermaidLoad" }>;
        return Effect.tryPromise({
          try: () => provideMermaid(c.bytes).then(() => null),
          catch: (e) => new CoreError("unsupported", e instanceof Error ? e.message : String(e)),
        });
      };
      const fontFiles = new FontFiles(inner.host, inner.store);
      fonts.setKeptAt((sha256) => fontFiles.at(sha256));
      inner.router.owners.push(fontFiles);
      handlers.fonts = (_i, call) => fontFiles.run((call as Extract<Call, { kind: "fonts" }>).call);
      hooks.device = (_inner, facts) => inner.changelog.device(facts);
      const adminRelays = new AdminRelays(inner);
      inner.router.owners.push(adminRelays);
      inner.cloudSync.onRelayLoad = (sub) => adminRelays.told(sub);
      inner.cloudSync.onAdminSubList = (sub, prefix) => adminRelays.told(sub, prefix);
      inner.router.owners.push(new Pills(inner.store, inner.runner, () => inner.host.nowMs(), (station) => inner.views.stationName(station)));
      // The stations every account reaches are linked, as the workspaces say (once a burst of changes settles).
      let reconciling = false;
      inner.cloudSync.onReach = () => {
        if (reconciling) return;
        reconciling = true;
        inner.runner.fork(
          Effect.sync(() => {
            reconciling = false;
            inner.stations.reconcile();
          }),
        );
      };
      const seedAuthWhenLockLoaded = (subs: readonly string[]) => {
        for (const sub of subs) {
          inner.runner.fork(
            inner.adb.personal().whenLoaded(sub).pipe(
              Effect.andThen(
                Effect.sync(() => {
                  for (const [ws, owner] of inner.workspaces.owned()) {
                    if (owner === sub) syncWorkspaceAuth(inner, ws);
                  }
                }),
              ),
            ),
          );
        }
      };
      inner.shownAccounts = inner.accounts.list();
      inner.store.authGen.syncAccounts(inner.shownAccounts.map((a) => a.sub));
      inner.adb.accountsKnown();
      seedAuthWhenLockLoaded(inner.shownAccounts.map((a) => a.sub));
      inner.tracer.setExport((body) => {
        const account = inner.accounts.list()[0];
        // Sent again when the network or the cloud was down; not one the cloud refused (it would be refused again).
        const refused = (e: CoreError) => e.status !== undefined && e.status >= 400 && e.status < 500 && e.status !== 408 && e.status !== 429;
        return account ? Effect.catch(inner.provider.traces(account.sub, body), (e) => (refused(e) ? Effect.void : Effect.fail(e))) : Effect.void;
      });
      // An account signed in has its database opened; one signed out, removed (before what it reached is let go).
      inner.accounts.onChange((removed) => {
        const subs = inner.accounts.list().map((a) => a.sub);
        inner.store.authGen.syncAccounts(subs);
        inner.adb.accountsKnown();
        seedAuthWhenLockLoaded(subs);
        inner.runner.fork(Effect.andThen(inner.data.accounts(subs, removed), Effect.sync(() => inner.cloudSync.accountsChanged())));
      });
      // From now on the core keeps what it holds current, whatever the UI shows.
      inner.provider.start();
      inner.cloudSync.start();
      inner.stations.reconcile();
      // Account-owned post-publish lifecycle: runs inside Data's runner-owned open fiber once per published DB (or
      // unrecoverable deferred failure) so cancelling an on-demand caller can never drop resumeFor/syncSockets/reconcile.
      inner.data.onPublished = (db) => {
        inner.views.local.opened(db);
        inner.cloudSync.adoptDb(db);
        inner.cloudSync.recomputeOwners();
        inner.viewCalls.resumeFor(db);
        inner.cloudSync.syncSockets();
        inner.stations.reconcile();
      };
      inner.data.onDeferredCleared = () => {
        inner.cloudSync.recomputeOwners();
        inner.cloudSync.syncSockets();
        inner.stations.reconcile();
      };
      inner.data.onDbCommitted = (db) => {
        inner.cloudSync.retryPendingLiveMe(db);
      };
      if (restSubs.length > 0) {
        const firstChats = Deferred.makeUnsafe<void>();
        inner.store.onFirstChats = (scope) => {
          if (activeWs !== null && scope !== activeWs) return false;
          Deferred.doneUnsafe(firstChats, Effect.void);
          return true;
        };
        const activateDeferred = (sub: string) => Effect.asVoid(inner.data.openAccount(sub));
        inner.cloudSync.onNeedDeferred = (workspace: string, beforeSub?: string | null, includeTarget = false) =>
          Effect.gen(function* () {
            const ordered = inner.accounts.list().map((a) => a.sub);
            if (beforeSub) {
              // Verify against every deferred account strictly earlier in sign-in order than the provisional owner
              // (and open `beforeSub` itself when `includeTarget` is true because its live `/v1/me` already owns `workspace`).
              for (const sub of ordered) {
                if (sub === beforeSub) {
                  if (includeTarget && inner.data.isDeferred(sub)) yield* activateDeferred(sub);
                  break;
                }
                if (inner.data.isDeferred(sub)) yield* activateDeferred(sub);
              }
              return;
            }
            const cached = inner.data.device.get("choice", "workspaceOwners");
            const hinted = isObject(cached) && typeof cached[workspace] === "string" ? cached[workspace] : null;
            if (hinted !== null && ordered.includes(hinted)) {
              for (const sub of ordered) {
                if (inner.data.isDeferred(sub)) yield* activateDeferred(sub);
                if (sub === hinted) break;
              }
              const owner = inner.workspaces.owner(workspace);
              if (owner !== null && !inner.cloudSync.hasEarlierDeferred(owner)) return;
            }
            for (const sub of ordered) {
              if (!inner.data.isDeferred(sub)) continue;
              yield* activateDeferred(sub);
              const owner = inner.workspaces.owner(workspace);
              if (owner !== null && !inner.cloudSync.hasEarlierDeferred(owner)) return;
            }
          });
        inner.runner.fork(
          Effect.gen(function* () {
            // Wait until the selected startup workspace's first `chats` topic is sent to the UI (or a short fallback
            // deadline when no UI subscribes, such as push notifications, sign-in, or headless tests), then yield.
            yield* Effect.raceFirst(
              Deferred.await(firstChats),
              laterSleep(1200), // timer: fallback deadline so deferred accounts still open when no UI subscribes to chats
            );
            for (const sub of restSubs) {
              if (!inner.data.isDeferred(sub)) continue;
              yield* inner.store.turn();
              if (!inner.data.isDeferred(sub)) continue;
              yield* activateDeferred(sub);
            }
          }),
        );
      }
      // The chats spoken in latest, read ahead once what the first views ask has gone.
      inner.runner.fork(Effect.andThen(laterSleep(AHEAD_AFTER_MS), Effect.sync(() => ahead.seed())));
      // What was on its way when the core last stopped goes on.
      inner.viewCalls.resume();
      inner.downloads.resume();
      inner.fill.start();
      start.step("rest");
      start.ownLock();
      // What changed in still.fail: read now, and again each time an account's events socket opens (a release missed
      // while it was closed too).
      inner.scheduler.enqueue("cloud", "changelog", Priority.background, inner.changelog.read());
      inner.cloudSync.onOpen = () => {
        inner.store.checkMoments();
        inner.views.checkMoments();
        inner.scheduler.enqueue("cloud", "changelog", Priority.background, inner.changelog.read());
        inner.cloudSync.onRelease();
      };
      return new Core(inner);
    });
  }

  /// Keeps times in words fresh while anything is shown (a UI's core).
  keepTime(): void {
    this.inner.store.setClock();
  }

  #cancelAuthRetry(client: ClientId): void {
    const fiber = this.#authRetryFibers.get(client);
    if (fiber !== undefined) {
      this.#authRetryFibers.delete(client);
      this.inner.runner.interrupt(fiber);
    }
  }

  #scheduleAuthPersistRetry(client: ClientId): void {
    if (!this.#connectedClients.has(client) || this.#authRetryFibers.has(client)) return;
    const DELAYS_MS = [2_000, 5_000, 10_000, 30_000];
    let fiber!: ReturnType<Runner["fork"]>;
    const retry = Effect.gen({ self: this }, function* () {
      for (let attempt = 0; ; attempt++) {
        const delay = DELAYS_MS[Math.min(attempt, DELAYS_MS.length - 1)]!;
        // timer: bounded exponential backoff retry for device/auth persistence after storage failure.
        yield* Effect.sleep(delay);
        if (!this.#connectedClients.has(client) || !this.inner.store.isAuthFailed(client)) return;
        const attemptRes = yield* Effect.result(
          Effect.gen({ self: this }, function* () {
            const device = this.inner.data.device;
            if (device.isUnloaded("auth")) {
              const loaded = yield* device.reload("auth");
              if (!loaded) return yield* Effect.fail(new HostError("device/auth has not been read"));
            }
            let finalConnId = ++nextConnSeq;
            const diskSeq = Number(device.get("auth", "connSeq") ?? 0);
            if (Number.isFinite(diskSeq) && diskSeq >= finalConnId) {
              nextConnSeq = Math.max(nextConnSeq, Math.floor(diskSeq) + 1);
              finalConnId = nextConnSeq;
            }
            device.put("auth", "connSeq", finalConnId);
            yield* device.flushTable("auth");
            return finalConnId;
          }),
        );
        if (attemptRes._tag === "Success") {
          if (!this.#connectedClients.has(client) || !this.inner.store.isAuthFailed(client)) return;
          this.inner.store.registerClient(client, attemptRes.success, false, false);
          this.inner.store.markClientAuthReady(client);
          return;
        }
      }
    }).pipe(
      Effect.ensuring(
        Effect.sync(() => {
          if (this.#authRetryFibers.get(client) === fiber) this.#authRetryFibers.delete(client);
        }),
      ),
    );
    fiber = this.inner.runner.fork(retry);
    this.#authRetryFibers.set(client, fiber);
  }

  /// Persists a monotonic `connId` in `device/auth` before allowing any `{ id: 0, auth }` snapshot or conn-tagged
  /// message to be emitted to `client`. Recovers from cold-start `#unloaded` `device/auth` via `reload("auth")` and
  /// fails explicitly (without leaking unpersisted `connId` or hanging callers) if persistence fails, then schedules
  /// bounded exponential-backoff background recovery.
  #persistClientAuth(client: ClientId, initialConnId: number): void {
    this.#cancelAuthRetry(client);
    this.inner.store.registerClient(client, initialConnId, false, false);
    const failPersist = (err: unknown) => {
      this.inner.store.failClientAuth(client, err);
      // Do NOT call `runner.onDefect` (all production hosts treat `onDefect` as fatal and crash-loop on disk full);
      // record a non-fatal warning on the tracer instead, and schedule bounded backoff recovery.
      const span = this.inner.tracer.root("core.auth_persist_failed", Kind.Internal);
      span.set("stillfail.error", err instanceof Error ? err.message : String(err));
      span.fail();
      span.end();
      this.#scheduleAuthPersistRetry(client);
    };
    try {
      this.inner.runner.fork(
        Effect.gen({ self: this }, function* () {
          const device = this.inner.data.device;
          if (device.isUnloaded("auth")) {
            const loaded = yield* device.reload("auth");
            if (!loaded) return yield* Effect.fail(new HostError("device/auth has not been read"));
          }
          const diskSeq = Number(device.get("auth", "connSeq") ?? 0);
          let finalConnId = initialConnId;
          if (Number.isFinite(diskSeq) && diskSeq >= finalConnId) {
            nextConnSeq = Math.max(nextConnSeq, Math.floor(diskSeq) + 1);
            finalConnId = nextConnSeq;
            this.inner.store.updateClientConn(client, finalConnId);
          }
          device.put("auth", "connSeq", finalConnId);
          yield* device.flushTable("auth");
          this.inner.store.markClientAuthReady(client);
        }).pipe(Effect.catch((err) => Effect.sync(() => failPersist(err)))),
      );
    } catch (err) {
      failPersist(err);
    }
  }

  /// A UI connected; its messages and emissions use this id.
  /// When `options.authHandshake` is true (all production hosts), registers the connection with a strictly
  /// monotonic cross-restart `connId` and schedules the initial `{ id: 0, auth }` snapshot.
  connect(options?: { authHandshake?: boolean; requireCallAuth?: boolean }): ClientId {
    const client = this.#nextClient++;
    this.#connectedClients.add(client);
    if (options?.authHandshake === true) {
      const connId = ++nextConnSeq;
      if (options?.requireCallAuth === true) {
        this.inner.store.setAuthEnforced(client);
      }
      this.#persistClientAuth(client, connId);
    }
    return client;
  }

  /// Immediately flushes the authoritative `{ id: 0, auth }` snapshot for `client` (or registers it if unregistered)
  /// and enforces explicit `CallAuth` on protected write RPCs from this client.
  syncAuth(client: ClientId): void {
    this.inner.store.setAuthEnforced(client);
    if (this.inner.store.connOf(client) === 0) {
      const connId = ++nextConnSeq;
      this.#persistClientAuth(client, connId);
    } else {
      this.inner.store.flushAuthSnapshot(client);
    }
  }

  /// A UI went away: its subscriptions end, its calls that hold something open for it stop.
  disconnect(client: ClientId): void {
    this.#connectedClients.delete(client);
    this.#cancelAuthRetry(client);
    this.inner.store.dropClient(client);
    this.inner.attention.attend.gone(client);
    this.inner.forms.disconnect(this.inner, client);
    for (const [key, fiber] of [...this.inner.calls]) {
      if (key.startsWith(`${client}/`)) {
        this.inner.calls.delete(key);
        this.inner.runner.interrupt(fiber);
      }
    }
  }

  /// A message from a UI as JSON (what the native hosts are given): one that is none answers `bad_message`.
  receiveJson(client: ClientId, json: string, bytes?: Uint8Array): void {
    let raw: unknown;
    try {
      raw = JSON.parse(json);
    } catch {
      return;
    }
    this.receiveRaw(client, raw, bytes);
  }

  /// A message from a UI as an object; `bytes`, those a native host handed over beside it.
  receiveRaw(client: ClientId, raw: unknown, bytes?: Uint8Array): void {
    const message = parseClientMessage(raw, bytes);
    if ("invalid" in message) {
      const id = isObject(raw) && typeof raw.id === "number" && Number.isInteger(raw.id) && raw.id >= 0 ? raw.id : null;
      if (id !== null) this.inner.host.emit(client, { id, error: new CoreError("bad_message", t("core-misc.host.bad_message", { error: message.invalid })) });
      return;
    }
    this.receive(client, message);
  }

  /// A message from a UI. Answers and values go out through `Host.emit`.
  receive(client: ClientId, message: ClientMessage): void {
    const inner = this.inner;
    switch (message.kind) {
      case "subscribe": {
        const clientGen =
          message.conn !== undefined || message.authGen !== undefined || message.vaultGen !== undefined
            ? {
                ...(message.conn !== undefined ? { conn: message.conn } : {}),
                ...(message.authGen !== undefined ? { authGen: message.authGen } : {}),
                ...(message.vaultGen !== undefined ? { vaultGen: message.vaultGen } : {}),
              }
            : undefined;
        return inner.store.subscribe(client, message.id, message.subscribe, message.keyed === true, message.from, message.have, clientGen);
      }
      case "unsubscribe":
        return inner.store.unsubscribe(client, message.id, message.keep === true);
      case "cancel": {
        const key = `${client}/${message.id}`;
        const fiber = inner.calls.get(key);
        if (fiber) {
          inner.calls.delete(key);
          inner.runner.interrupt(fiber);
        }
        return;
      }
      case "call":
        return this.#call(client, message.id, message.call, message.params, message.bytes, message.auth);
    }
  }

  #call(client: ClientId, id: RequestId, name: string, params: unknown, bytes: Uint8Array | undefined, auth?: CallAuth): void {
    const inner = this.inner;
    const asked = heavy(name) ? null : params;
    let call: Call;
    // (what it names aimed where its chat is now: views/moved.ts)
    const aimed = movedChats.aimed(inner, params);
    try {
      call = parseCall(name, aimed, bytes);
    } catch (e) {
      inner.host.emit(client, answer(id, { err: asCoreError(e) }));
      return;
    }
    const target = callAuthTarget(inner, client, call, name);
    const conn = inner.store.connOf(client);
    if (auth !== undefined) inner.store.setAuthEnforced(client);
    if (inner.store.isAuthFailed(client) && (target.protectedWrite || auth !== undefined || inner.store.isAuthEnforced(client))) {
      inner.host.emit(client, answer(id, { err: new CoreError("storage_failed", t("core-logic.status.db.full")) }));
      return;
    }
    const enforced = conn > 0 && inner.store.isAuthEnforced(client);
    const verifyFor = (tgt: ReturnType<typeof callAuthTarget>): CoreError | null => {
      if (auth === undefined && (!tgt.protectedWrite || !enforced)) return null;
      return inner.store.authGen.verifyCallAuth(
        auth,
        conn,
        (ws) => inner.workspaces.owner(ws),
        new Set(inner.accounts.list().map((a) => a.sub)),
        tgt,
        tgt.protectedWrite && enforced,
      );
    };
    const authErr = verifyFor(target);
    if (authErr !== null) {
      inner.host.emit(client, answer(id, { err: authErr }));
      return;
    }
    const genWs = target.workspace ?? auth?.workspace;
    const genVault = target.vault ?? auth?.vault;
    const callGen: WireGen | undefined =
      conn > 0
        ? {
            conn,
            authGen: genWs !== undefined ? inner.store.authGen.workspaceAuthGen(genWs) : inner.store.authGen.globalGen,
            ...(target.isVault
              ? {
                  vaultGen:
                    genWs !== undefined && genVault !== undefined
                      ? inner.store.authGen.vaultGen(genWs, genVault)
                      : genWs !== undefined
                        ? inner.store.authGen.vaultWorkspaceGen(genWs)
                        : inner.store.authGen.vaultGlobalGen,
                }
              : {}),
          }
        : undefined;
    // Under way from now until it answers, for every page to show where it is (doing.ts).
    // What people use (use-counts.ts): each call by its name, but what the UI says of itself (`client.*`).
    if (!name.startsWith("client.")) inner.useCounts.used(name);
    let doing: number | null = null;
    if (asked !== null && counts(call, name)) {
      doing = inner.doing.start(name, asked, inner.host.nowMs());
    }
    // Each call is a trace: what it asks of stations and still.fail cloud are its spans. One that asks nothing and
    // answers at once is not sent (trace.ts QUIET_MS).
    const span = inner.tracer.root(name, Kind.Internal);
    span.quiet();
    const station = callStation(call);
    if (station !== null) span.set("stillfail.station", stationId(station));
    // A preview's resource: its page's progress counts it (preview-load.ts).
    const loads = call.kind === "stationPreview" ? inner.workspaces.ofStation(call.station).part("previewLoad", () => new Loads()) : null;
    const resource = loads !== null && call.kind === "stationPreview" ? loads.start(call.station, call.port, call.method, call.path, call.headers, inner.host.nowMs()) : null;
    const progress: Progress = (value, bytes) => {
      const head = isObject(value) && isObject(value.head) ? value.head : null;
      if (loads && resource && head && typeof head.status === "number") {
        loads.head(resource, head.status);
        // Event streams stay open after they have connected.
        const stream = Array.isArray(head.headers) && head.headers.some((h) => Array.isArray(h) && typeof h[0] === "string" && h[0].toLowerCase() === "content-type" && typeof h[1] === "string" && h[1].startsWith("text/event-stream"));
        if (stream) loads.end(resource, inner.host.nowMs(), null);
      }
      inner.store.emitClient(
        client,
        bytes === undefined
          ? callGen
            ? { id, value, ...callGen }
            : { id, value }
          : callGen
            ? { id, value, bytes, ...callGen }
            : { id, value, bytes },
        true,
      );
    };
    const key = `${client}/${id}`;
    const stoppable = cancellable(call);
    // Its station answered that the chat it names went to another (views/moved.ts): asked there, once.
    const again = (error: CoreError): Effect.Effect<unknown, CoreError> => {
      if (error.code !== MOVED) return Effect.fail(error);
      const there = movedChats.aimed(inner, params);
      if (get(there, "station") === get(aimed, "station") && get(there, "thread") === get(aimed, "thread")) return Effect.fail(error);
      return Effect.try({ try: () => parseCall(name, there, bytes), catch: asCoreError }).pipe(
        Effect.flatMap((c) => {
          const redirectedErr = verifyFor(callAuthTarget(inner, client, c, name));
          if (redirectedErr !== null) return Effect.fail(redirectedErr);
          return execute(inner, c, progress, [client, id], span.context);
        }),
        Effect.mapError(asCoreError),
      );
    };
    // Re-verify authorization immediately before starting execution, without interrupting already-started
    // non-stoppable writes or turning a committed write into a false `auth_stale` error.
    const guarded = Effect.suspend(() => {
      const preErr = verifyFor(target);
      if (preErr !== null) return Effect.fail(preErr);
      return execute(inner, call, progress, [client, id], span.context);
    });
    const run = guarded.pipe(
      Effect.mapError(asCoreError),
      Effect.catch(again),
      // Stopped (a UI cancelled it, or went): it says so.
      Effect.onInterrupt(() =>
        Effect.sync(() => {
          inner.calls.delete(key);
          span.cancel();
          const cancelled = new CoreError("cancelled", t("core-misc.call.cancelled"));
          // Its resource ends with it: the page's progress counts it as failed.
          if (loads && resource) {
            loads.end(resource, inner.host.nowMs(), cancelled.message);
          }
          if (doing !== null) {
            inner.doing.end(doing);
          }
          inner.store.emitClient(client, answer(id, { err: cancelled }, callGen), true);
        }),
      ),
      Effect.exit,
      Effect.flatMap((exit) =>
        Effect.gen(function* () {
          if (stoppable) inner.calls.delete(key);
          const result: { ok: unknown } | { err: CoreError } =
            exit._tag === "Success" ? { ok: exit.value } : { err: failureOf(exit.cause) };
          if ("err" in result) failedIn(span, result.err);
          if (loads && resource) {
            const said = "ok" in result ? (result.ok instanceof Beside ? result.ok.value : result.ok) : undefined;
            const status = isObject(said) ? said.status : undefined;
            if (typeof status === "number") loads.head(resource, status);
            loads.end(resource, inner.host.nowMs(), "err" in result ? result.err.message : null);
          }
          span.end();
          let failed: number | null = null;
          if (doing !== null) {
            if ("err" in result) {
              inner.doing.fail(doing, result.err.message);
              failed = doing;
            } else inner.doing.end(doing);
          }
          inner.store.emitClient(client, answer(id, result, callGen), true);
          if (failed !== null) {
            yield* Effect.sleep(FAILED_SHOWN_MS);
            inner.doing.end(failed);
          }
        }),
      ),
    );
    // Only a call that holds something open for its page, or streams to it what it reads, can be stopped (cancellable);
    // any other runs to its end whoever waits.
    const fiber = inner.runner.fork(run);
    if (stoppable) inner.calls.set(key, fiber as Fiber.Fiber<unknown, unknown>);
  }

  #closing: Promise<void> | null = null;

  /// Lets the core go: its fibers stop, then what the device's tables changed and were yet to write is written (a core
  /// that follows on the same storage reads it). Fails with what could not be written; the core is gone all the same.
  close(): Promise<void> {
    if (this.#closing) return this.#closing;
    const { runner, data } = this.inner;
    let liveMeError: HostError | null = null;
    try {
      // (the trees read and not yet written, and what is written and not yet committed: kept for the core that follows)
      this.inner.sendTrace.close();
      data.closing();
      liveMeError = this.inner.cloudSync.flushLiveMe();
    } catch (e) {
      liveMeError = e instanceof HostError ? e : new HostError(e instanceof Error ? e.message : String(e));
    } finally {
      runner.shutdown();
    }
    this.#closing = runner.run(
      Effect.gen({ self: this }, function* () {
        const pruneErr = yield* this.inner.cloudSync.reconcilePendingMeOnClose();
        yield* data.device.close();
        if (pruneErr) return yield* Effect.fail(pruneErr);
        if (liveMeError) return yield* Effect.fail(liveMeError);
      }),
    );
    return this.#closing;
  }
}

function failureOf(cause: Cause.Cause<unknown>): CoreError {
  // The cause's failure: a CoreError (a defect said as one).
  return asCoreError(Cause.squash(cause));
}

export function answer(id: RequestId, result: { ok: unknown } | { err: CoreError }, gen?: WireGen): CoreMessage {
  if (!("ok" in result)) return gen ? { id, error: result.err, ...gen } : { id, error: result.err };
  if (result.ok instanceof Beside) return gen ? { id, ok: result.ok.value, bytes: result.ok.bytes, ...gen } : { id, ok: result.ok.value, bytes: result.ok.bytes };
  return gen ? { id, ok: result.ok, ...gen } : { id, ok: result.ok };
}

/// The relays a `/v1/me` names: `relay_urls`, still.fail's own first, or `relay_url` alone from a cloud from before.
export function relaysOf(me: unknown): string[] | null {
  if (!isObject(me)) return null;
  const all = Array.isArray(me.relay_urls) ? me.relay_urls.filter((v): v is string => typeof v === "string") : [];
  if (all.length > 0) return all;
  return typeof me.relay_url === "string" ? [me.relay_url] : null;
}

/// The forwarding entries a `/v1/me` names (`relay_entries`, cloud relays.ts), separate from the relays themselves.
export function entriesOf(me: unknown): string[] {
  if (!isObject(me) || !Array.isArray(me.relay_entries)) return [];
  return me.relay_entries.filter((v): v is string => typeof v === "string");
}

/// The relay on the other side of each entry, when the cloud knows it.
export function entryTargetsOf(me: unknown): Record<string, string> {
  if (!isObject(me) || !isObject(me.relay_entry_targets)) return {};
  return Object.fromEntries(Object.entries(me.relay_entry_targets).filter((entry): entry is [string, string] => typeof entry[1] === "string"));
}

/// Resolves the authoritative authorization target (`account`, `workspace`, `vault`) and whether a parsed
/// `Call` is a protected write RPC that must carry matching `CallAuth` on a handshaked connection.
function callAuthTarget(
  inner: Inner,
  client: ClientId,
  call: Call,
  name: string,
): { protectedWrite: boolean; account?: string; workspace?: string; vault?: string; isVault?: boolean; viewAuthGen?: number } {
  switch (call.kind) {
    case "vault": {
      const action = call.name;
      const readOnly = action === "state" || action === "prompts";
      const ws = call.workspace;
      const v = typeof call.params.vault === "string" && call.params.vault.length > 0 ? call.params.vault : undefined;
      return {
        protectedWrite: !readOnly,
        isVault: !readOnly && action !== "lock",
        ...(ws.length > 0 ? { workspace: ws } : {}),
        ...(v !== undefined ? { vault: v } : {}),
      };
    }
    case "lock": {
      const action = call.name;
      const readOnly = action === "state" || action === "prompts";
      const ws = call.workspace;
      return {
        protectedWrite: !readOnly,
        ...(ws.length > 0 ? { workspace: ws } : {}),
      };
    }
    case "terminal": {
      if (call.call.kind === "view") {
        return { protectedWrite: false, workspace: ofAddress(call.call.station) };
      }
      const bound = terminalViewAuthOf(inner, client, call.call.view);
      return {
        protectedWrite: true,
        ...(bound ? { workspace: bound.workspace, viewAuthGen: bound.authGen } : {}),
      };
    }
    case "screen": {
      if (call.call.kind === "view") {
        return { protectedWrite: false, workspace: ofAddress(call.call.station) };
      }
      const isWrite =
        call.call.kind === "input" ||
        call.call.kind === "clipboard" ||
        call.call.kind === "control" ||
        call.call.kind === "micOn" ||
        call.call.kind === "mic";
      const bound = screenViewAuthOf(inner, client, call.call.view);
      return {
        protectedWrite: isWrite,
        ...(bound ? { workspace: bound.workspace, viewAuthGen: bound.authGen } : {}),
      };
    }
    case "farview": {
      if (call.call.kind === "view") {
        return { protectedWrite: false, workspace: ofAddress(call.call.station) };
      }
      const bound = farviewViewAuthOf(inner, client, call.call.view);
      return {
        protectedWrite: true,
        ...(bound ? { workspace: bound.workspace, viewAuthGen: bound.authGen } : {}),
      };
    }
    case "signOut":
    case "deleteAccount":
      return { protectedWrite: true, account: call.account };
    case "chatSend":
    case "chatSendTo":
    case "chatCreate":
    case "chatArchive":
    case "chatChange":
    case "chatRetry":
    case "chatRetryIn":
    case "chatDiscard":
    case "chatDiscardIn":
    case "decisionAnswer":
    case "decisionReply":
    case "decisionDismiss":
    case "draftPut":
    case "stationUpload":
    case "stationUploadPart":
    case "driveUploadPart":
    case "chatXshare":
    case "chatXshareAdd": {
      const st = callStation(call);
      const ws = "workspace" in call && typeof call.workspace === "string" && call.workspace.length > 0 ? call.workspace : st ? ofAddress(st) : undefined;
      return { protectedWrite: true, ...(ws ? { workspace: ws } : {}) };
    }
    case "composer": {
      const ws = call.key.startsWith("new:")
        ? call.key.slice(4)
        : call.key.includes("/")
          ? ofAddress(call.key)
          : undefined;
      return { protectedWrite: true, ...(ws ? { workspace: ws } : {}) };
    }
    case "stationJoin":
    case "feedbackDismiss":
      return { protectedWrite: true, workspace: call.workspace };
    case "shareIn":
      return { protectedWrite: true, workspace: call.scope };
    case "op": {
      const method = call.op.method.toUpperCase();
      if (method === "GET") return { protectedWrite: false };
      let ws: string | undefined;
      if ("station" in call.op.target) ws = ofAddress(call.op.target.station);
      else {
        const m = /^\/v1\/workspaces\/([^/]+)/.exec(call.op.path);
        if (m) ws = decodeURIComponent(m[1]!);
      }
      const account = "cloud" in call.op.target && call.op.target.cloud ? call.op.target.cloud : undefined;
      return { protectedWrite: true, ...(ws ? { workspace: ws } : {}), ...(account ? { account } : {}) };
    }
    default: {
      if (name.startsWith("vault.") || name.startsWith("lock.")) {
        const st = callStation(call);
        return { protectedWrite: true, ...(st ? { workspace: ofAddress(st) } : {}) };
      }
      return { protectedWrite: false };
    }
  }
}

function roleRank(role: unknown): number {
  switch (role) {
    case "owner":
      return 3;
    case "admin":
      return 2;
    case "member":
      return 1;
    default:
      return 0;
  }
}

function isCloudAuthDowngrade(prevDigest: string | undefined, next: [string | null, unknown, boolean, boolean, boolean]): boolean {
  if (prevDigest === undefined) return false;
  let prev: unknown;
  try {
    prev = JSON.parse(prevDigest);
  } catch {
    return true;
  }
  if (!Array.isArray(prev) || prev.length < 5) return true;
  const [prevOwner, prevRole, prevMember] = prev;
  const [nextOwner, nextRole, nextMember] = next;
  if (prevOwner !== nextOwner) return true;
  if (prevMember === true && !nextMember) return true;
  if (roleRank(nextRole) < roleRank(prevRole)) return true;
  return false;
}

function isCloudAuthUpgrade(prevDigest: string | undefined, next: [string | null, unknown, boolean, boolean, boolean]): boolean {
  if (prevDigest === undefined) return false;
  let prev: unknown;
  try {
    prev = JSON.parse(prevDigest);
  } catch {
    return false;
  }
  if (!Array.isArray(prev) || prev.length < 5) return false;
  const [prevOwner, prevRole, prevMember] = prev;
  const [nextOwner, nextRole, nextMember] = next;
  if (prevOwner !== nextOwner) return false;
  return (prevMember === false && nextMember === true) || roleRank(nextRole) > roleRank(prevRole);
}

function isAuthDowngrade(prevDigest: string | undefined, next: [string | null, unknown, boolean, boolean, boolean]): boolean {
  if (isCloudAuthDowngrade(prevDigest, next)) return true;
  if (prevDigest === undefined) return false;
  let prev: unknown;
  try {
    prev = JSON.parse(prevDigest);
  } catch {
    return true;
  }
  if (!Array.isArray(prev) || prev.length < 5) return true;
  const [, , , prevSafe, prevTrusted] = prev;
  const [, , , nextSafe, nextTrusted] = next;
  if (prevTrusted === true && !nextTrusted) return true;
  if (prevSafe === false && nextSafe === true) return true;
  return false;
}

/// Recomputes the authoritative authorization digest for `ws` (owner, role, membership, safe mode, trusted device)
/// and advances `authGen(ws)` if and only if the digest changed.
/// Cold-start guard: before `ws` is seeded, unknown owner / unloaded `wsView` / loading personal lock never seed
/// or advance `authGen`, preventing cold-start "unknown -> known" false invalidations.
/// On downgrade/revocation/enter-safeMode boundary ONLY, marks `pendingAuthConfirm` so stale held `Data` records
/// are gated per `(ws, topicKey)` until fresh post-boundary confirmation arrives.
export function syncWorkspaceAuth(inner: Inner, ws: string): void {
  const owner = inner.workspaces.owner(ws);
  const wsView = inner.data.shared({ topic: "workspace", workspace: ws });
  const prevDigest = inner.store.authGen.workspaceDigest(ws);
  const alreadySeeded = prevDigest !== undefined;
  const deps = vaultCalls.dependentVaultWorkspaces(inner, ws);
  if (owner === null || wsView === undefined) {
    if (!alreadySeeded) return;
    const nextTuple: [string | null, unknown, boolean, boolean, boolean] = [owner, null, false, false, false];
    const digest = JSON.stringify(nextTuple);
    const changed = inner.store.authGen.syncWorkspace(ws, digest, deps);
    if (changed && isAuthDowngrade(prevDigest, nextTuple)) {
      inner.pendingAuthConfirm.set(ws, { gen: inner.store.authGen.workspaceAuthGen(ws), confirmedKeys: new Set() });
      inner.stations?.refreshWorkspace(ws);
    }
    return;
  }
  const role = get(wsView, "role") ?? null;
  let safe = false;
  let trusted = true;
  try {
    if (inner.adb !== undefined && !inner.adb.personal().isLoaded(owner)) {
      return;
    }
    safe = safeNow(inner, ws);
    const s = signsAs(inner, ws);
    trusted = !s.locked || s.as !== null;
  } catch {
    // Lock state not yet initialized; do not seed or advance until lock loads.
    return;
  }
  const nextTuple: [string | null, unknown, boolean, boolean, boolean] = [owner, role, true, safe, trusted];
  const digest = JSON.stringify(nextTuple);
  const changed = inner.store.authGen.syncWorkspace(ws, digest, deps);
  if (changed) {
    const wsKey = topicKey({ topic: "workspace", workspace: ws });
    const prior = inner.pendingAuthConfirm.get(ws);
    if (isAuthDowngrade(prevDigest, nextTuple)) {
      const cloudDowngrade = isCloudAuthDowngrade(prevDigest, nextTuple);
      // Lock-only downgrades (`safe: false -> true`, `trusted: true -> false`) keep cloud membership/role
      // unchanged; pre-confirm `{ topic: "workspace" }` ONLY when no prior cloud downgrade is still unconfirmed,
      // so `station`/`stations`/`lock` views immediately surface blocked/safe-mode states without ever bypassing
      // an in-flight cloud downgrade gate, while keeping all station held data gated.
      const preconfirm = !cloudDowngrade && (prior === undefined || prior.confirmedKeys.has(wsKey));
      const confirmedKeys = preconfirm ? new Set<string>([wsKey]) : new Set<string>();
      inner.pendingAuthConfirm.set(ws, { gen: inner.store.authGen.workspaceAuthGen(ws), confirmedKeys });
      if (!preconfirm) inner.cloudSync?.refreshWorkspace(ws);
      inner.stations?.refreshWorkspace(ws);
    } else if (prior !== undefined && !prior.confirmedKeys.has(wsKey) && !isCloudAuthUpgrade(prevDigest, nextTuple)) {
      // Preserve an unconfirmed cloud downgrade across a lock-only upgrade and re-fetch under the new gen.
      inner.pendingAuthConfirm.set(ws, { gen: inner.store.authGen.workspaceAuthGen(ws), confirmedKeys: new Set<string>() });
      inner.cloudSync?.refreshWorkspace(ws);
      inner.stations?.refreshWorkspace(ws);
    } else {
      inner.pendingAuthConfirm.delete(ws);
    }
  }
}

export function gone(): CoreError {
  return new CoreError("closed", t("core-misc.core.closed"));
}
