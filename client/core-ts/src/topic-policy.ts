// Single source of truth for per-topic retention, caching, and store delivery policies.
// Exhaustively keyed by `TopicName` (`keyof typeof TOPICS`): adding a topic to `protocol.ts` without
// classifying it here fails TypeScript compilation.
// `apps/mbui/scripts/gen-topic-policy.mjs` imports this module directly to generate
// `apps/mbui/src/sfbase/topic_policy_gen.mbt`.
//
// PR-B2s unconditional security ceiling: `sensitive` topics and `stationPart(machineLogins|logins)`
// unconditionally forbid retention (`keep`, `showKept`, `lasting`, `have`, `same`, `from`) in both
// Core Store and Client regardless of legacy tables, trace switches, or client hints.
// `station` and `profiles` sanitize sensitive fields (`machineLogins`, `logins`, `manages`) when
// stored in `#kept` / `Client::kept` / `last_said` so first-frame SWR holds zero sensitive fields.
import { TOPICS, type TopicName } from "./protocol.ts";

/// Retention tier for a topic:
/// - `sensitive`: unconditional security ceiling; never kept, never shown stale, never `have`/`same`/`from`.
/// - `live`: never kept or shown stale; always waits for fresh values.
/// - `delta`: kept for `have`/`same`/`kept: true` delta compression, never shown before the core answers.
/// - `swr`: kept and shown immediately while the core answers (either via `lasting` `last_said` or `showKept`).
export type TopicRetention = "sensitive" | "live" | "delta" | "swr";

export type TopicPolicyBase = {
  readonly retention: TopicRetention;
  /// Bar/rail opening lists kept in `sfbase` `last_said` and shown immediately (`source.mbt` `lasting`).
  readonly lasting?: true;
  /// Subset of `lasting` that are Home's own lists (`MBUI_HOME_SAME` replay switch).
  readonly homeLasting?: true;
  /// Client keep capacity when `MBUI_SWR_VIEWS` is enabled (for `delta` or `showKept` topics).
  readonly keep?: number;
  /// Client keep capacity before `MBUI_SWR_VIEWS` (only differs for `chat`: 4 vs 8).
  readonly keepBeforeViews?: number;
  /// Client shows the kept value immediately before the core answers (`@core.Client::show_kept`).
  readonly showKept?: true;
  /// Gated by `MBUI_TOPIC_POLICY` replay switch on the client (enabled in production; off in pre-B2b replay traces).
  /// Never applies to `sensitive` topics (security ceiling is unconditional).
  readonly topicPolicy?: true;
  /// Store: topics of words typed (`store.ts` `ASKED_BY_WORDS`).
  readonly askedByWords?: true;
  /// Store: expensive derived topics not recomputed while idle during eviction grace (`store.ts` `LAZY_WHEN_IDLE`).
  readonly lazyWhenIdle?: true;
  /// Store: topics emitted even while no page is in view (`store.ts` `UNSEEN`).
  readonly unseen?: true;
};

export type TopicPolicy = TopicPolicyBase & {
  /// Optional parameter-driven overrides (e.g. `stationPart.part` specialization).
  readonly byParam?: {
    readonly key: string;
    readonly values: Readonly<Record<string, Partial<TopicPolicyBase>>>;
  };
};

export type EvaluatedTopicPolicy = {
  readonly retention: TopicRetention;
  readonly sensitive: boolean;
  readonly lasting: boolean;
  readonly homeLasting: boolean;
  readonly keep: number;
  readonly keepBeforeViews: number;
  readonly showKept: boolean;
  readonly askedByWords: boolean;
  readonly lazyWhenIdle: boolean;
  readonly unseen: boolean;
};

/// How many values let go of keeping them (`keep`) are remembered for a client (`store.ts` `#kept`, `sfbase` `kept_most_by(true)`).
export const KEPT_PER_CLIENT = 96;
/// Client global kept cap before `MBUI_SWR_VIEWS` (`sfbase` `kept_most_by(false)`).
export const KEPT_MOST_BEFORE_VIEWS = 64;
/// Per-topic keep capacity for `lasting` lists (`sfbase` `last_most`).
export const LASTING_KEPT = 64;

const SENSITIVE: TopicPolicy = { retention: "sensitive" };
const LIVE: TopicPolicy = { retention: "live" };
/// Bar/rail opening lists (`lasting` in `sfbase` `last_said`): shown immediately when a place is
/// re-opened until the core answers. Leaving a place drops its subscriptions, and returning used to
/// flash skeleton bones until the core answered across its thread (2026-11-10). Read-only lists
/// only: nothing typed for (`q`), nothing written in (forms/drafts), no chat. `station_marks`
/// never takes a kept value (`core_signal_wbtest.mbt`).
const LASTING: TopicPolicy = { retention: "swr", lasting: true };
/// Home's own `lasting` lists (`chats`, `longJobs`, `changelog`, gated by `MBUI_HOME_SAME` in
/// replays): on small screens Home rests on the stack shelf and drops its reads; when taken back
/// without `last_said`, long jobs and chat rows vanished and rebuilt as slivers for 50–68 ms
/// (2026-11-12, `bar_places_kept_test.mbt`). `stationUpdates` is also `lasting` for Home's bar.
const HOME_LASTING: TopicPolicy = { retention: "swr", lasting: true, homeLasting: true };
/// Read-only topics of a page, panel, popover, or card (`views_kept`, `MBUI_SWR_VIEWS`): kept on
/// unsubscribe and shown immediately (`showKept: true`) until the core answers so re-opening a
/// card/popover/page draws its prior content instead of bones or an empty list.
const viewKept = (keep: number): TopicPolicy => ({ retention: "swr", keep, showKept: true });
/// PR-B2b extended read-only view topics gated by `MBUI_TOPIC_POLICY` (enabled in production;
/// off in pre-B2b replay traces).
const viewKeptPolicy = (keep: number): TopicPolicy => ({ retention: "swr", keep, showKept: true, topicPolicy: true });
/// `chat` keeps the last 8 decoded chats (`4` before `MBUI_SWR_VIEWS`), oldest forgotten, so
/// re-opening or prefetching a recent chat receives a delta instead of a whole chat payload
/// (~180 KB, 17–21 ms to decode on a phone), while still waiting for the core before drawing.
const CHAT_DELTA: TopicPolicy = { retention: "delta", keep: 8, keepBeforeViews: 4 };

export const TOPIC_POLICY: Record<TopicName, TopicPolicy> = {
  accounts: SENSITIVE,
  workspaces: LIVE,
  workspace: LASTING,
  link: LIVE,
  overview: LIVE,
  sessions: LIVE,
  session: LIVE,
  live: LIVE,
  host: LIVE,
  memory: LIVE,
  presets: viewKeptPolicy(8),
  profilePace: LIVE,
  stationMove: LIVE,
  net: LIVE,
  way: LIVE,
  threads: LIVE,
  thread: LIVE,
  letters: LIVE,
  chatRows: LIVE,
  slackApp: LIVE,
  jobs: LIVE,
  jobLog: { retention: "delta", keep: 8, topicPolicy: true },
  machineLogins: SENSITIVE,
  machineLogin: SENSITIVE,
  machineLoginScreen: SENSITIVE,
  loginSessions: SENSITIVE,
  admin: SENSITIVE,
  adminList: SENSITIVE,
  adminItem: SENSITIVE,
  adminOverview: SENSITIVE,
  adminRelays: SENSITIVE,
  chats: HOME_LASTING,
  projects: viewKept(8),
  project: viewKept(16),
  tags: viewKept(8),
  chatRow: viewKept(32),
  stations: LASTING,
  station: viewKept(16),
  stationPart: {
    retention: "live",
    byParam: {
      key: "part",
      values: {
        machineLogins: SENSITIVE,
        logins: SENSITIVE,
        archiving: LIVE,
        automaticDecisions: LIVE,
        profiles: viewKept(24),
        updates: viewKept(24),
        copies: viewKept(24),
      },
    },
  },
  profiles: LASTING,
  profile: viewKept(16),
  profilesOverview: { retention: "swr", keep: 4, showKept: true, lazyWhenIdle: true, topicPolicy: true },
  connects: LASTING,
  connect: viewKept(16),
  connectCandidates: viewKept(8),
  chat: CHAT_DELTA,
  history: LIVE,
  agentCard: viewKept(16),
  stationNet: LASTING,
  stationDiag: LIVE,
  status: LIVE,
  notices: LIVE,
  connection: LIVE,
  draft: LIVE,
  composer: LIVE,
  notify: { retention: "live", unseen: true },
  chatSearch: { retention: "live", askedByWords: true },
  archivedRows: LIVE,
  archive: LASTING,
  search: { retention: "live", askedByWords: true },
  stationSearch: { retention: "live", askedByWords: true },
  linkPreview: LIVE,
  filePeek: LIVE,
  messagePeek: LIVE,
  newChat: LIVE,
  preset: LIVE,
  otherPresets: viewKeptPolicy(8),
  boardDrafts: LIVE,
  shareIn: LIVE,
  pick: viewKept(12),
  chatJobs: viewKept(16),
  chatLetters: LIVE,
  chatFeedback: { retention: "delta", keep: 8, topicPolicy: true },
  chatThings: LIVE,
  chatOutline: viewKept(8),
  chatSubchats: { retention: "live", askedByWords: true },
  imageNear: LIVE,
  longJobs: HOME_LASTING,
  stationUsage: LIVE,
  stationRates: LIVE,
  usage: LASTING,
  agentRates: viewKept(4),
  fleet: LIVE,
  railCard: viewKept(16),
  stationUpdates: LASTING,
  settings: LIVE,
  stationResources: LIVE,
  resources: LIVE,
  job: LIVE,
  drive: LIVE,
  drivePlace: viewKept(24),
  prefs: LIVE,
  doing: LIVE,
  adbShare: LIVE,
  adbCard: LIVE,
  rigs: SENSITIVE,
  devices: SENSITIVE,
  previewLoad: LIVE,
  slackTokens: SENSITIVE,
  connectFlow: LIVE,
  decisionForm: LIVE,
  policyForm: LIVE,
  agentEnvForm: LIVE,
  profileFlow: LIVE,
  changelog: HOME_LASTING,
  releases: viewKeptPolicy(4),
  fonts: viewKeptPolicy(4),
  workspaceMarks: { retention: "live", unseen: true },
  workspaceWays: LIVE,
  lock: SENSITIVE,
  joinable: SENSITIVE,
  memberships: SENSITIVE,
  screens: LASTING,
  terminals: LASTING,
  screenCard: LIVE,
  terminalCard: LIVE,
  lockDraft: SENSITIVE,
  lockPrompts: SENSITIVE,
  vaults: SENSITIVE,
  vaultItems: SENSITIVE,
  driveTransfers: { retention: "live", unseen: true },
  driveBrowse: LIVE,
  filesTabs: LIVE,
  downloads: { retention: "live", unseen: true },
  vaultUses: SENSITIVE,
};

export const TOPIC_NAMES: readonly TopicName[] = Object.keys(TOPICS) as TopicName[];

/// Single source of truth for device-global and transport-only topics exempt from `(account, workspace)` `authGen`.
/// Generated into MoonBit (`topic_policy_device_global`) by `apps/mbui/scripts/gen-topic-policy.mjs`.
/// Note: `downloads` is NOT device-global (it carries station/path/filename user data).
export const DEVICE_GLOBAL_TOPICS: readonly TopicName[] = [
  "releases",
  "fonts",
  "changelog",
  "prefs",
  "doing",
  "adbShare",
  // Transport link/reachability state written directly by StationsSync (not user data):
  "link",
  "connection",
  "way",
  "net",
];

export const DEVICE_GLOBAL_TOPIC_SET: ReadonlySet<string> = new Set(DEVICE_GLOBAL_TOPICS);

export function isKnownTopic(name: string): name is TopicName {
  return Object.hasOwn(TOPICS, name);
}

export function topicsWhere(predicate: (policy: TopicPolicy, name: TopicName) => boolean): ReadonlySet<TopicName> {
  const out = new Set<TopicName>();
  for (const name of TOPIC_NAMES) {
    if (predicate(TOPIC_POLICY[name], name)) out.add(name);
  }
  return out;
}

const LIVE_EVALUATED: EvaluatedTopicPolicy = {
  retention: "live",
  sensitive: false,
  lasting: false,
  homeLasting: false,
  keep: 0,
  keepBeforeViews: 0,
  showKept: false,
  askedByWords: false,
  lazyWhenIdle: false,
  unseen: false,
};

function hasSearchParam(params: Readonly<Record<string, unknown>> | null | undefined): boolean {
  if (!params || typeof params !== "object") return false;
  if (Object.hasOwn(params, "q") && params.q !== undefined) return true;
  if (Object.hasOwn(params, "query") && typeof params.query === "string" && params.query.length > 0) return true;
  return false;
}

/// Evaluates the effective policy for `(name, params)`, accounting for own-property lookup,
/// optional `byParam` overrides, unconditional `sensitive` ceiling, optional `topicPolicy` switch
/// (`MBUI_TOPIC_POLICY`, enabled by default), and search-parameter (`q` / non-empty `query`) downgrade to `live`.
export function evaluateTopicPolicy(
  name: string,
  params?: Readonly<Record<string, unknown>> | null,
  opts?: { readonly topicPolicy?: boolean },
): EvaluatedTopicPolicy {
  if (!isKnownTopic(name)) return LIVE_EVALUATED;
  const base: TopicPolicy = TOPIC_POLICY[name];
  let effective: TopicPolicyBase = base;
  if (base.byParam && params && typeof params === "object" && Object.hasOwn(params, base.byParam.key)) {
    const rawVal = params[base.byParam.key];
    if (typeof rawVal === "string" && Object.hasOwn(base.byParam.values, rawVal)) {
      effective = { ...base, ...base.byParam.values[rawVal] };
    }
  }
  if (effective.retention === "sensitive") {
    return {
      retention: "sensitive",
      sensitive: true,
      lasting: false,
      homeLasting: false,
      keep: 0,
      keepBeforeViews: 0,
      showKept: false,
      askedByWords: Boolean(effective.askedByWords),
      lazyWhenIdle: Boolean(effective.lazyWhenIdle),
      unseen: Boolean(effective.unseen),
    };
  }
  if (opts?.topicPolicy === false && effective.topicPolicy === true) {
    return {
      retention: "live",
      sensitive: false,
      lasting: false,
      homeLasting: false,
      keep: 0,
      keepBeforeViews: 0,
      showKept: false,
      askedByWords: Boolean(effective.askedByWords),
      lazyWhenIdle: Boolean(effective.lazyWhenIdle),
      unseen: Boolean(effective.unseen),
    };
  }
  const typed = hasSearchParam(params);
  const lasting = Boolean(effective.lasting) && !typed;
  const homeLasting = Boolean(effective.homeLasting);
  const showKept = Boolean(effective.showKept) && !typed;
  let keep = 0;
  let keepBeforeViews = 0;
  if (effective.retention === "delta") {
    keep = effective.keep ?? 0;
    keepBeforeViews = effective.keepBeforeViews ?? keep;
  } else if (lasting) {
    keep = LASTING_KEPT;
    keepBeforeViews = LASTING_KEPT;
  } else if (!typed && effective.keep !== undefined) {
    keep = effective.keep;
    keepBeforeViews = effective.keepBeforeViews ?? 0;
  }
  const retention: TopicRetention = typed && effective.retention === "swr" ? "live" : effective.retention;
  return {
    retention,
    sensitive: false,
    lasting,
    homeLasting,
    keep,
    keepBeforeViews,
    showKept,
    askedByWords: Boolean(effective.askedByWords),
    lazyWhenIdle: Boolean(effective.lazyWhenIdle),
    unseen: Boolean(effective.unseen),
  };
}

function stripLoginField(item: unknown): unknown {
  if (item === null || typeof item !== "object" || Array.isArray(item)) return item;
  const obj = item as Record<string, unknown>;
  const hasLogin = Object.hasOwn(obj, "login");
  const nestedProfile = obj.profile;
  const nestedObj =
    nestedProfile !== null && typeof nestedProfile === "object" && !Array.isArray(nestedProfile)
      ? (nestedProfile as Record<string, unknown>)
      : null;
  const hasNestedLogin = nestedObj !== null && Object.hasOwn(nestedObj, "login");
  if (!hasLogin && !hasNestedLogin) return item;
  const out: Record<string, unknown> = {};
  for (const k of Object.keys(obj)) {
    if (k === "login") continue;
    if (k === "profile" && hasNestedLogin && nestedObj !== null) {
      const cleanProfile: Record<string, unknown> = {};
      for (const pk of Object.keys(nestedObj)) {
        if (pk === "login") continue;
        cleanProfile[pk] = nestedObj[pk];
      }
      out.profile = cleanProfile;
    } else {
      out[k] = obj[k];
    }
  }
  return out;
}

function stripLoginArray(arr: unknown): { changed: boolean; value: unknown } {
  if (!Array.isArray(arr)) return { changed: false, value: arr };
  let changed = false;
  const mapped = arr.map((item) => {
    const clean = stripLoginField(item);
    if (clean !== item) changed = true;
    return clean;
  });
  return changed ? { changed: true, value: mapped } : { changed: false, value: arr };
}

/// Strips sensitive / privilege / active-login fields from aggregate topics (`profiles`, `station`,
/// and `stationPart(part="profiles")`) before retaining them in `#kept` / `Client::kept` / `last_said`,
/// so cached values and first-frame SWR contain zero sensitive fields (`machineLogins`, `logins`,
/// `manages`, `profiles[].login`, `overview.profiles[].login`) while preserving fresh values.
/// Returns the original reference unchanged when nothing needs stripping.
export function sanitizeKeptValue(
  name: string,
  value: unknown,
  params?: Readonly<Record<string, unknown>> | null,
): unknown {
  if (name === "stationPart") {
    const part = params && typeof params === "object" ? params.part : undefined;
    if (part === undefined || part === "profiles") {
      return stripLoginArray(value).value;
    }
    return value;
  }
  if (value === null || typeof value !== "object" || Array.isArray(value)) return value;
  const obj = value as Record<string, unknown>;
  if (name === "profiles") {
    const hasTop = Object.hasOwn(obj, "machineLogins") || Object.hasOwn(obj, "manages");
    const itemsClean = stripLoginArray(obj.items);
    const profilesClean = stripLoginArray(obj.profiles);
    if (!hasTop && !itemsClean.changed && !profilesClean.changed) return value;
    const out: Record<string, unknown> = {};
    for (const k of Object.keys(obj)) {
      if (k === "machineLogins" || k === "manages") continue;
      if (k === "items" && itemsClean.changed) out.items = itemsClean.value;
      else if (k === "profiles" && profilesClean.changed) out.profiles = profilesClean.value;
      else out[k] = obj[k];
    }
    return out;
  }
  if (name === "station") {
    const hasTop = Object.hasOwn(obj, "machineLogins") || Object.hasOwn(obj, "manages");
    const ov = obj.overview;
    const ovObj = ov !== null && typeof ov === "object" && !Array.isArray(ov) ? (ov as Record<string, unknown>) : null;
    const ovProfilesClean = ovObj !== null ? stripLoginArray(ovObj.profiles) : { changed: false, value: undefined };
    const hasOv =
      ovObj !== null &&
      (Object.hasOwn(ovObj, "machineLogins") || Object.hasOwn(ovObj, "logins") || ovProfilesClean.changed);
    if (!hasTop && !hasOv) return value;
    const out: Record<string, unknown> = {};
    for (const k of Object.keys(obj)) {
      if (k === "machineLogins" || k === "manages") continue;
      if (k === "overview" && hasOv && ovObj !== null) {
        const cleanOv: Record<string, unknown> = {};
        for (const ok of Object.keys(ovObj)) {
          if (ok === "machineLogins" || ok === "logins") continue;
          if (ok === "profiles" && ovProfilesClean.changed) cleanOv.profiles = ovProfilesClean.value;
          else cleanOv[ok] = ovObj[ok];
        }
        out.overview = cleanOv;
      } else {
        out[k] = obj[k];
      }
    }
    return out;
  }
  return value;
}
