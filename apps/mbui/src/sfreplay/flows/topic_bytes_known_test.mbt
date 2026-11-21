// The bars of what the core sends for the app's subscriptions (src/sfreplay/topic_bytes.mbt), counted as the check
// first ran (2026-11-10): the 81 traces 3684 KB sent whole, 269 values sent again whole for what had had one, 11
// messages for what was let go of. Each only falls: a trace's KB within a tenth (2 KB at least) under its bar, its
// counts as they are; one that gets fewer has its bar brought down, more fails. A trace a flow reads has one
// (sfreplay's trace).

///|
fn init {
  // (a trace: the KB of values that came whole, how many came again whole for what had had one, how many came for
  // what was let go of)
  @sfreplay.tape_topics_known([
    ("agent-reply", 24, 0, 0),
    ("answer-option", 26, 3, 0),
    ("appearance-kept", 32, 0, 0),
    ("archive-restore", 18, 0, 0),
    ("bar-archive", 25, 1, 0),
    ("bar-glass", 32, 10, 1),
    ("bar-going-down", 25, 2, 0),
    ("card-motion", 24, 1, 0),
    ("chat-audio", 34, 1, 0),
    ("chinese-enter", 25, 3, 0),
    ("close-option", 27, 0, 0),
    ("delete-failed", 35, 6, 0),
    ("dismiss", 26, 4, 0),
    ("draft", 27, 4, 0),
    ("draft-restart", 42, 0, 0),
    ("drive-delete", 43, 1, 0),
    ("drive-download-many", 21, 1, 0),
    ("drive-lend", 50, 1, 0),
    ("drive-list", 43, 4, 0),
    ("drive-play", 117, 14, 0),
    ("drive-read", 55, 5, 0),
    ("drive-rename", 42, 1, 0),
    ("drive-sheet-closing", 41, 0, 0),
    ("drive-upload", 24, 2, 0),
    ("drive-zip", 42, 0, 0),
    ("glass", 29, 11, 0),
    ("history", 26, 1, 0),
    ("home-new-chat", 16, 1, 0),
    ("lock-wait", 16, 0, 0),
    ("mark-read", 25, 1, 0),
    ("markdown", 55, 4, 0),
    ("new-chat", 43, 4, 2),
    ("notice-cancel", 45, 1, 0),
    ("notice-failed", 49, 2, 0),
    // (notice-looking recorded again 2026-11-20: its `chatRow` (945 B) asked again as the page is left before its first
    // value came, `driveTransfers` (52 B) asked again back on Home, and the snapshot of `live` (101 B): 3 that came
    // again whole, its KB down from 47 to 25)
    ("notice-looking", 25, 3, 0),
    ("notify-off", 62, 7, 0),
    ("offline-retry", 37, 8, 0),
    ("open-link", 30, 0, 0),
    ("paste-long", 26, 1, 0),
    ("paste-short", 25, 0, 0),
    ("pick-words", 24, 1, 0),
    ("pin", 40, 2, 0),
    ("places", 39, 10, 0),
    ("quote", 25, 2, 0),
    ("reader", 43, 1, 0),
    ("send-card-paced", 28, 9, 0),
    ("send-flying", 24, 1, 0),
    // (send-paced recorded again 2026-11-20 with MBUI_CHAT_ROW on: its chats' list's rows each `chatRow` (1.2 KB), and
    // what main's shell asks since (`prefs` 11.9 KB, `workspace` 1.2 KB): 31 KB, the values that came again whole down)
    ("send-paced", 31, 1, 0),
    ("send-text", 25, 0, 0),
    ("service-page", 26, 3, 0),
    ("settings-add-station", 37, 2, 0),
    ("settings-appearance", 39, 0, 0),
    ("settings-connect", 56, 4, 1),
    ("settings-decisions", 37, 1, 0),
    ("settings-device-pages", 41, 0, 0),
    ("settings-profile", 51, 2, 0),
    ("settings-run-settings", 28, 2, 0),
    ("settings-sheet-sinking", 41, 0, 0),
    ("settings-station-mark", 41, 2, 0),
    ("settings-station-settings", 41, 3, 0),
    ("settings-vault-item", 39, 0, 0),
    ("settings-workspace-people", 38, 0, 0),
    ("share", 27, 3, 0),
    ("share-files", 29, 2, 0),
    ("share-new-chat", 25, 1, 0),
    ("sheet-drag", 56, 2, 0),
    ("sheets-sinking", 25, 3, 0),
    ("station-file-sent", 38, 3, 0),
    ("station-files", 26, 1, 0),
    ("station-rename", 50, 1, 0),
    ("video-frames", 24, 0, 0),
    ("viewer", 28, 3, 0),
    ("wide-answer-reply", 26, 0, 0),
    ("wide-new-chat", 22, 3, 0),
    ("wide-newline", 26, 0, 0),
    // (wide-places recorded again 2026-11-17, 文件 made once as nodes: its home folder's listing and browsing now come
    // before the run goes on to the chats (drive 0.4 KB, driveBrowse 0.3 KB, what 主目录 shows; the old run let go of
    // them unanswered), and stationUpdates, which the shell asks since the last recording (0.15 KB): 31 KB)
    ("wide-places", 31, 6, 0),
    ("wide-resize", 40, 1, 0),
    ("wide-row-menu", 19, 0, 0),
    ("wide-send", 26, 0, 0),
    ("wide-switcher", 31, 2, 0),
    ("workspace-members", 36, 0, 0),
  ])
}

///|
/// Each topic's largest value that came whole in any trace, in KB.
let topic_whole_known : Map[String, Int] = {
  let known = Map([])
  for k in [
      ("accounts", 1),
      ("agentCard", 1),
      ("agentEnvForm", 1),
      ("archive", 1),
      ("changelog", 1),
      ("chat", 19),
      ("chatFeedback", 1),
      ("chatJobs", 1),
      ("chatOutline", 1),
      // (send-paced recorded again 2026-11-20 with MBUI_CHAT_ROW on, the old recordings had it off: 1215 B)
      ("chatRow", 2),
      ("chatThings", 1),
      ("chats", 4),
      ("composer", 1),
      ("connectFlow", 9),
      ("connects", 5),
      ("decisionForm", 1),
      ("doing", 1),
      ("downloads", 1),
      ("drive", 2),
      ("driveBrowse", 1),
      ("drivePlace", 1),
      ("driveTransfers", 1),
      ("filesTabs", 1),
      ("history", 2),
      ("host", 2),
      ("imageNear", 1),
      ("job", 1),
      ("joinable", 1),
      ("live", 1),
      ("lock", 2),
      ("lockPrompts", 1),
      ("loginSessions", 2),
      ("longJobs", 1),
      ("memberships", 1),
      ("newChat", 40),
      ("notices", 1),
      ("notify", 1),
      ("pick", 3),
      ("prefs", 11),
      ("previewLoad", 1),
      ("profileFlow", 13),
      ("profiles", 4),
      ("resources", 6),
      ("screens", 1),
      ("search", 3),
      ("settings", 1),
      // (share-files recorded again 2026-11-20: 2417 B, the trace's whole down from 38 KB to 29 KB, again 4 to 2)
      ("shareIn", 3),
      ("slackTokens", 1),
      ("stationNet", 1),
      ("stationUpdates", 1),
      ("stations", 19),
      ("status", 1),
      ("usage", 3),
      ("vaultItems", 1),
      ("vaultUses", 1),
      ("vaults", 1),
      // (draft recorded again 2026-11-20, with what main's shell asks of the workspace since: 1207 B, the trace's whole
      // down from 66 KB to 27 KB, again 6 to 4)
      ("workspace", 2),
      ("workspaceMarks", 2),
      ("workspaces", 1),
  ] {
    known[k.0] = k.1
  }
  known
}
