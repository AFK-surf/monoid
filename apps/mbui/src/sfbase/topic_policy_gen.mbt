// Made by apps/mbui/scripts/gen-topic-policy.mjs from client/core-ts/src/topic-policy.ts: do not edit.

let topic_policy_kept_per_client : Int = 96

let topic_policy_kept_most_before : Int = 64

let topic_policy_last_most : Int = 64

///|
fn topic_policy_typed(params : Json) -> Bool {
  match params {
    Object(p) =>
      if p.contains("q") {
        true
      } else {
        match p.get("query") {
          Some(String(s)) => s.length() > 0
          _ => false
        }
      }
    _ => false
  }
}

///|
/// Whether topic `name` is one of the 125 protocol topics in `client/core-ts/src/protocol.ts`.
#warnings("-unused_value") // verified by sfbase/topic_policy_wbtest.mbt
fn topic_policy_known(name : String, _params : Json) -> Bool {
  match name {
    "accounts" => true
    "workspaces" => true
    "workspace" => true
    "link" => true
    "overview" => true
    "sessions" => true
    "session" => true
    "live" => true
    "host" => true
    "memory" => true
    "presets" => true
    "profilePace" => true
    "stationMove" => true
    "net" => true
    "way" => true
    "threads" => true
    "thread" => true
    "letters" => true
    "chatRows" => true
    "slackApp" => true
    "jobs" => true
    "jobLog" => true
    "machineLogins" => true
    "machineLogin" => true
    "machineLoginScreen" => true
    "loginSessions" => true
    "admin" => true
    "adminList" => true
    "adminItem" => true
    "adminOverview" => true
    "adminRelays" => true
    "chats" => true
    "projects" => true
    "project" => true
    "tags" => true
    "chatRow" => true
    "stations" => true
    "station" => true
    "stationPart" => true
    "profiles" => true
    "profile" => true
    "profilesOverview" => true
    "connects" => true
    "connect" => true
    "connectCandidates" => true
    "chat" => true
    "history" => true
    "agentCard" => true
    "stationNet" => true
    "stationDiag" => true
    "status" => true
    "notices" => true
    "connection" => true
    "draft" => true
    "composer" => true
    "notify" => true
    "chatSearch" => true
    "archivedRows" => true
    "archive" => true
    "search" => true
    "stationSearch" => true
    "linkPreview" => true
    "filePeek" => true
    "messagePeek" => true
    "newChat" => true
    "preset" => true
    "otherPresets" => true
    "boardDrafts" => true
    "shareIn" => true
    "pick" => true
    "chatJobs" => true
    "chatLetters" => true
    "chatFeedback" => true
    "chatThings" => true
    "chatOutline" => true
    "chatSubchats" => true
    "imageNear" => true
    "longJobs" => true
    "stationUsage" => true
    "stationRates" => true
    "usage" => true
    "agentRates" => true
    "fleet" => true
    "railCard" => true
    "stationUpdates" => true
    "settings" => true
    "stationResources" => true
    "resources" => true
    "job" => true
    "drive" => true
    "drivePlace" => true
    "prefs" => true
    "doing" => true
    "adbShare" => true
    "adbCard" => true
    "rigs" => true
    "devices" => true
    "previewLoad" => true
    "slackTokens" => true
    "connectFlow" => true
    "decisionForm" => true
    "policyForm" => true
    "agentEnvForm" => true
    "profileFlow" => true
    "changelog" => true
    "releases" => true
    "fonts" => true
    "workspaceMarks" => true
    "workspaceWays" => true
    "lock" => true
    "joinable" => true
    "memberships" => true
    "screens" => true
    "terminals" => true
    "screenCard" => true
    "terminalCard" => true
    "lockDraft" => true
    "lockPrompts" => true
    "vaults" => true
    "vaultItems" => true
    "driveTransfers" => true
    "driveBrowse" => true
    "filesTabs" => true
    "downloads" => true
    "vaultUses" => true
    _ => false
  }
}

///|
/// Whether `(name, params)` is a bar/rail opening list kept in `last_said`.
pub fn topic_policy_lasting(name : String, params : Json) -> Bool {
  if topic_policy_typed(params) {
    return false
  }
  match name {
    "workspace"
    | "chats"
    | "stations"
    | "profiles"
    | "connects"
    | "stationNet"
    | "archive"
    | "longJobs"
    | "usage"
    | "stationUpdates"
    | "changelog"
    | "screens"
    | "terminals"
    | "vaults" => true
    _ => false
  }
}

///|
/// Whether `(name, params)` is one of Home's own `lasting` lists (`MBUI_HOME_SAME`).
pub fn topic_policy_home_lasting(name : String, _params : Json) -> Bool {
  match name {
    "chats"
    | "longJobs"
    | "changelog" => true
    _ => false
  }
}

///|
/// How many values of `(name, params)` the core's client keeps as they are let go of (`views` = `MBUI_SWR_VIEWS`).
pub fn topic_policy_keep(name : String, params : Json, views : Bool) -> Int {
  match name {
    "chat" => if views { 8 } else { 4 }
    "workspace"
    | "chats"
    | "stations"
    | "profiles"
    | "connects"
    | "stationNet"
    | "archive"
    | "longJobs"
    | "usage"
    | "stationUpdates"
    | "changelog"
    | "screens"
    | "terminals"
    | "vaults" =>
      if topic_policy_typed(params) {
        0
      } else {
        topic_policy_last_most
      }
    "projects" => if views && !topic_policy_typed(params) { 8 } else { 0 }
    "project" => if views && !topic_policy_typed(params) { 16 } else { 0 }
    "tags" => if views && !topic_policy_typed(params) { 8 } else { 0 }
    "chatRow" => if views && !topic_policy_typed(params) { 32 } else { 0 }
    "station" => if views && !topic_policy_typed(params) { 16 } else { 0 }
    "stationPart" => if views && !topic_policy_typed(params) { 24 } else { 0 }
    "profile" => if views && !topic_policy_typed(params) { 16 } else { 0 }
    "connect" => if views && !topic_policy_typed(params) { 16 } else { 0 }
    "connectCandidates" => if views && !topic_policy_typed(params) { 8 } else { 0 }
    "agentCard" => if views && !topic_policy_typed(params) { 16 } else { 0 }
    "pick" => if views && !topic_policy_typed(params) { 12 } else { 0 }
    "chatJobs" => if views && !topic_policy_typed(params) { 16 } else { 0 }
    "chatOutline" => if views && !topic_policy_typed(params) { 8 } else { 0 }
    "agentRates" => if views && !topic_policy_typed(params) { 4 } else { 0 }
    "railCard" => if views && !topic_policy_typed(params) { 16 } else { 0 }
    "drivePlace" => if views && !topic_policy_typed(params) { 24 } else { 0 }
    _ => 0
  }
}

///|
/// Whether `(name, params)` shows its kept value immediately before the core answers (`views` = `MBUI_SWR_VIEWS`).
pub fn topic_policy_show_kept(name : String, params : Json, views : Bool) -> Bool {
  if !views || topic_policy_typed(params) {
    return false
  }
  match name {
    "projects"
    | "project"
    | "tags"
    | "chatRow"
    | "station"
    | "stationPart"
    | "profile"
    | "connect"
    | "connectCandidates"
    | "agentCard"
    | "pick"
    | "chatJobs"
    | "chatOutline"
    | "agentRates"
    | "railCard"
    | "drivePlace" => true
    _ => false
  }
}
