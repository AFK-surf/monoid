// Single source of truth for per-topic retention, caching, and store delivery policies.
// Exhaustively keyed by `TopicName` (`keyof typeof TOPICS`): adding a topic to `protocol.ts` without
// classifying it here fails TypeScript compilation.
// `apps/mbui/scripts/gen-topic-policy.mjs` imports this module directly to generate
// `apps/mbui/src/sfbase/topic_policy_gen.mbt`.
import { TOPICS, type TopicName } from "./protocol.ts";

/// Retention tier for a topic:
/// - `live`: never kept or shown stale; always waits for fresh values.
/// - `delta`: kept for `have`/`same`/`kept: true` delta compression, never shown before the core answers.
/// - `swr`: kept and shown immediately while the core answers (either via `lasting` `last_said` or `showKept`).
export type TopicRetention = "live" | "delta" | "swr";

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

const LIVE: TopicPolicy = { retention: "live" };
const LASTING: TopicPolicy = { retention: "swr", lasting: true };
const HOME_LASTING: TopicPolicy = { retention: "swr", lasting: true, homeLasting: true };
const viewKept = (keep: number): TopicPolicy => ({ retention: "swr", keep, showKept: true });

export const TOPIC_POLICY: Record<TopicName, TopicPolicy> = {
  accounts: LIVE,
  workspaces: LIVE,
  workspace: LASTING,
  link: LIVE,
  overview: LIVE,
  sessions: LIVE,
  session: LIVE,
  live: LIVE,
  host: LIVE,
  memory: LIVE,
  presets: LIVE,
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
  jobLog: LIVE,
  machineLogins: LIVE,
  machineLogin: LIVE,
  machineLoginScreen: LIVE,
  loginSessions: LIVE,
  admin: LIVE,
  adminList: LIVE,
  adminItem: LIVE,
  adminOverview: LIVE,
  adminRelays: LIVE,
  chats: HOME_LASTING,
  projects: viewKept(8),
  project: viewKept(16),
  tags: viewKept(8),
  chatRow: viewKept(32),
  stations: LASTING,
  station: viewKept(16),
  stationPart: viewKept(24),
  profiles: LASTING,
  profile: viewKept(16),
  profilesOverview: { retention: "live", lazyWhenIdle: true },
  connects: LASTING,
  connect: viewKept(16),
  connectCandidates: viewKept(8),
  chat: { retention: "delta", keep: 8, keepBeforeViews: 4 },
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
  stationSearch: LIVE,
  linkPreview: LIVE,
  filePeek: LIVE,
  messagePeek: LIVE,
  newChat: LIVE,
  preset: LIVE,
  otherPresets: LIVE,
  boardDrafts: LIVE,
  shareIn: LIVE,
  pick: viewKept(12),
  chatJobs: viewKept(16),
  chatLetters: LIVE,
  chatFeedback: LIVE,
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
  rigs: LIVE,
  devices: LIVE,
  previewLoad: LIVE,
  slackTokens: LIVE,
  connectFlow: LIVE,
  decisionForm: LIVE,
  policyForm: LIVE,
  agentEnvForm: LIVE,
  profileFlow: LIVE,
  changelog: HOME_LASTING,
  releases: LIVE,
  fonts: LIVE,
  workspaceMarks: { retention: "live", unseen: true },
  workspaceWays: LIVE,
  lock: LIVE,
  joinable: LIVE,
  memberships: LIVE,
  screens: LASTING,
  terminals: LASTING,
  screenCard: LIVE,
  terminalCard: LIVE,
  lockDraft: LIVE,
  lockPrompts: LIVE,
  vaults: LASTING,
  vaultItems: LIVE,
  driveTransfers: { retention: "live", unseen: true },
  driveBrowse: LIVE,
  filesTabs: LIVE,
  downloads: { retention: "live", unseen: true },
  vaultUses: LIVE,
};

export const TOPIC_NAMES: readonly TopicName[] = Object.keys(TOPICS) as TopicName[];

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
/// optional `byParam` overrides, and search-parameter (`q` / non-empty `query`) downgrade to `live`.
export function evaluateTopicPolicy(
  name: string,
  params?: Readonly<Record<string, unknown>> | null,
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
