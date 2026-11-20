// What the core gives its clients, declared once (Types): every value the core sends on a topic
// passes through its shape first (conform.ts), and the web's types are made from these by scripts/shapes.ts —
// web/src/core/shapes.ts, checked in CI so it cannot drift. A field a client
// reads is here, with its type, or it is not sent. Whole numbers (times in ms, counts) are `i64` on the wire and `I54`
// to the clients (a JS number holds them); an absent `opt` is left out.
//
// Station shapes are as station/src/admin/types.ts has them; what the core puts in for the clients to show is marked
// so (present.ts, format.ts, views/, history.ts, activity.ts). Compatibility: a new field is an `opt` (or has a
// `default`), and none is removed or renamed while a client may read it.
import type { Shape, Ty } from "./dsl.ts";
import { COMMON_SHAPES } from "./common.ts";
import { CHAT_SHAPES } from "./chat.ts";
import { COMPOSER_SHAPES } from "./composer.ts";
import { SEARCH_SHAPES } from "./search.ts";
import { PRESET_SHAPES } from "./presets.ts";
import { STATION_SHAPES } from "./station.ts";
import { PROFILE_SHAPES } from "./profiles.ts";
import { CONNECT_SHAPES } from "./connect.ts";
import { DRIVE_SHAPES } from "./drive.ts";
import { LOCK_SHAPES } from "./lock.ts";
import { VAULT_SHAPES } from "./vault.ts";
import { DEVICE_SHAPES } from "./devices.ts";
import { PREF_SHAPES } from "./prefs.ts";
import { USAGE_SHAPES } from "./usage.ts";
import { HISTORY_SHAPES } from "./history.ts";

export { LISTED_CHAT } from "./chat.ts";

export const SHAPES: Record<string, Shape> = {
  ...COMMON_SHAPES,
  ...CHAT_SHAPES,
  ...COMPOSER_SHAPES,
  ...SEARCH_SHAPES,
  ...PRESET_SHAPES,
  ...STATION_SHAPES,
  ...PROFILE_SHAPES,
  ...CONNECT_SHAPES,
  ...DRIVE_SHAPES,
  ...LOCK_SHAPES,
  ...VAULT_SHAPES,
  ...DEVICE_SHAPES,
  ...PREF_SHAPES,
  ...USAGE_SHAPES,
  ...HISTORY_SHAPES,
};

/// Each topic's shape: what present.ts conforms its value to before it goes out (topics with none go as they are).
export const TOPIC_SHAPES: Record<string, Ty> = {
  chats: "ChatsView",
  chatRow: { opt: "ChatItem" },
  chatSearch: "ChatSearchView",
  search: "SearchView",
  chat: "ChatView",
  stations: { vec: "StationRow" },
  station: { opt: "StationView" },
  connects: "ConnectsView",
  connect: { opt: "ConnectView" },
  connectCandidates: { opt: "ConnectCandidates" },
  history: "HistoryView",
  live: "Live",
  overview: "Overview",
  sessions: { vec: "Session" },
  session: "SessionDetail",
  threads: { vec: "ChatThread" },
  host: "Host",
  status: "StatusView",
  connection: "ConnectionView",
  notices: "NoticesView",
  draft: "DraftView",
  notify: "NotifyView",
  archive: "ArchiveView",
  newChat: "NewChatView",
  preset: "PresetOne",
  otherPresets: "OtherPresetsView",
  boardDrafts: "BoardDraftsView",
  shareIn: "ShareInView",
  pick: "PickView",
  chatJobs: "ChatJobsView",
  chatLetters: "ChatLettersView",
  chatFeedback: "ChatFeedbackView",
  chatThings: "ChatThingsView",
  chatOutline: "ChatOutlineView",
  imageNear: "ImageNear",
  agentCard: "AgentCardView",
  stationNet: { opt: "StationNet" },
  stationDiag: { opt: "StationDiag" },
  longJobs: "LongJobsView",
  profiles: "ProfilesView",
  profilesOverview: "ProfilesOverviewView",
  profile: { opt: "WorkspaceProfile" },
  usage: "UsageView",
  agentRates: "AgentRatesView",
  fleet: "FleetView",
  railCard: "RailCard",
  stationUpdates: "StationUpdates",
  settings: "SettingsView",
  job: "Job",
  drive: "DriveFolder",
  drivePlace: { opt: "DrivePlace" },
  jobLog: "JobLogView",
  machineLogins: "MachineLoginsView",
  memory: "StationMemory",
  presets: "StationPresets",
  stationMove: "MoveView",
  linkPreview: { opt: "LinkPreview" },
  filePeek: { opt: "FilePeek" },
  messagePeek: { opt: "MessagePeek" },
  machineLogin: { opt: "MachineLoginShown" },
  machineLoginScreen: { opt: "MachineLoginScreen" },
  prefs: "PrefsView",
  changelog: "ChangelogView",
  releases: "ReleasesView",
  connectFlow: "ConnectFlowView",
  slackTokens: "SlackTokensView",
  doing: "DoingView",
  adbShare: "AdbShareView",
  workspaceMarks: "WorkspaceMarksView",
  workspaceWays: "WorkspaceWaysView",
  lock: "LockView",
  lockDraft: "LockDraftView",
  lockPrompts: "LockPromptsView",
  vaults: "VaultsView",
  vaultItems: "VaultItemsView",
  driveTransfers: "DriveTransfersView",
  driveBrowse: "DriveBrowseView",
  filesTabs: { opt: "FilesTabsView" },
  downloads: "DownloadsView",
  vaultUses: "VaultUsesView",
  joinable: "JoinableView",
  memberships: "MembershipsView",
  screens: "ScreensView",
  terminals: "TerminalsView",
  screenCard: "ScreenCard",
  terminalCard: "TerminalCard",
  adbCard: "AdbCard",
  rigs: "RigsView",
  devices: "DevicesView",
};
