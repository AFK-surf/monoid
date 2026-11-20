// The corner rule (mbui's Tester::corner_faults, mbui's ui/corners.mbt) as each screen keeps it
// now: how many faults it still has, the bar they may only fall from (screen_check fails on one more, and on one less
// until the bar is lowered here). A screen not listed has none.

///|
let corners_known : Map[String, Int] = Map([])

///|
/// Every screen in every window (corners_wbtest.mbt), by window, language and screen: the bar it may only fall from. A
/// screen not listed has none. Listed: the rail on the tape (corners_tape_rail), and 安全's last card where its page
/// ends 5 short of its panel.
let corners_everywhere_known : Map[String, Int] = {
  let known = Map([])
  for win in ["touch", "desk-win"] {
    for lang in ["zh", "en"] {
      for mode in corners_tape_rail {
        known["\{win}-\{lang} \{mode}"] = 1
      }
    }
  }
  // 密钥 with a vault waiting to be keyed anew, in the tablet's window, in English: the rail's one, off the window's
  // side as the page shows (made as nodes: its old view was not swept).
  known["touch-en settings-vault-waits"] = 1
  // The same in Chinese: the rail's one, and its page, which does not fill its panel, ending with 删除此库's card 26 over
  // the panel's foot, 16 in, its foot corners where the panel's 42 would want them 16 (全部密钥 a card of its own over
  // how it keeps its secrets, as its old view had it). Where it ends is its words' and the window's, as 安全's above:
  // gone as the page's height is any other (English's has none).
  known["touch-zh settings-vault-waits"] = 3
  // 安全 made its person's only trusted device (lock-rebound-security) in the 600 wide window touch is in, in Chinese: the rail's
  // one (its workspace's mark in the panel's top left corner).
  known["touch-zh lock-rebound-security"] = 1
  // A request for the phone waiting (chat-phone-lacks, swept since 2026-11-11; the same card as chat-phone's, on main
  // unswept): its length's chooser, the last of its answer's row, stands in the card's foot end corner off concentric
  // with it where its words are long (闲置 1 小时后失效 on a phone; Until idle for 1 hour wherever English is), as the
  // request cards' rows of answers are laid (ask_buttons). The rail's one besides it where the window has a tape.
  known["phone-zh chat-phone-lacks"] = 1
  known["touch-en chat-phone-lacks"] = 2
  known["desk-en chat-phone-lacks"] = 2
  known["desk-win-en chat-phone-lacks"] = 3
  known["tablet-en chat-phone-lacks"] = 1
  known["wide-en chat-phone-lacks"] = 2
  known["wide-win-en chat-phone-lacks"] = 2
  // The board in a Windows window's 大屏, its sidebar closed (sfdesk's place_bare_now): the rail alone at the window's
  // corners, round as it is wide (21) 6 in where the window's are 8 round, its top and foot ends and its dock's: the
  // frame's for every place without a sidebar (place-connects and place-usage have the same 4 there, not swept), not
  // the board's.
  known["wide-win-zh board"] = 4
  known["wide-win-en board"] = 4
  // The same with a card's chat open beside the board (board-side, its first sweep 2026-11-17): the rail's four as the
  // board's, each said against two nodes of the whole window (170 and 174 then); and on a Mac's (wide), the chat's
  // bar's last key, 32 square, 6 from the window's end and 6.5 from its top where the window's corner (16) wants it
  // concentric, said against the same two (sfdesk board.mbt board_beside's bar, pane_chat_bar_ends): what was there
  // before the sweep saw this screen, not the line taken from between the chat and the board then.
  known["wide-win-zh board-side"] = 8
  known["wide-win-en board-side"] = 8
  known["wide-zh board-side"] = 2
  known["wide-en board-side"] = 2
  // An account on three stations' page in a 中屏 window (desk, desk-win; the rail's one besides it on the tape): its
  // stations' card's foot corners (Birch's row, 16 in from the panel's sides, 26 round; one on the Mac's, both on
  // Windows'): the page is shorter than its panel, so it does not scroll and its last card stands
  // 39 over the panel's foot, where its end would stand 16 (page_foot). Where a page that does not fill its panel ends
  // is its words' and the window's, no place it is stood at. Gone as the page's height is any other (a fourth station,
  // a phone's or a wide window).
  known["desk-zh settings-profile-account"] = 1
  known["desk-en settings-profile-account"] = 1
  known["desk-win-zh settings-profile-account"] = 3
  known["desk-win-en settings-profile-account"] = 3
  // 待处理 open beside the rail's bell in a Windows window's 中屏 (home-shared-bell): the rail's one on the tape (the
  // panel a presenter's of the window's tree, no old view holding the rail drawn again beside it).
  known["desk-win-zh home-shared-bell"] = 1
  known["desk-win-en home-shared-bell"] = 1
  known
}

///|
/// The screens whose rail stands on the tape (its 600 wide windows, a tablet's and Windows'), one fault each: the
/// ground of its first place, 30 square and 15 round, in the corner of the sidebar's panel (42 round): 13 in from its
/// left, as the rail's places stand, and 27 under its top, that place's middle on the line of the sidebar's first row
/// beside it, 新建对话's (pengxiao, 2026-10-25). The tablet is kept so for now (the user, 2026-11-09, moving the Mac window's up into its
/// corner alone). On main the rail was an old view's island, measured against the island's own square box, so the rule
/// never saw it; as nodes of the window's tree it is measured against the panel. A panel over Home (home-sheet, switcher,
/// new-workspace and new-workspace-code, …) has it too: the rail behind it, not the panel.
let corners_tape_rail : Array[String] = [
  // (a station's terminals among its screens, a terminal's page over the frame: the rail on the tape under them)
  "settings-station-terminals", "terminal", "terminal-taken",
  "webdemo", "home", "board", "board-side", "home-bars", "home-jobs", "home-shared-bell", "home-sheet", "home-news", "new-workspace", "new-workspace-code", "rail-menu",
  "home-station-updates", "station-updates", "home-station-updates-app", "station-updates-app", "place", "switcher", "switcher-found", "keys-dialog", "search", "search-jobs", "search-results", "chat", "chat-agent",
  "chat-agent-unsaid", "chat-answering", "chat-attach", "chat-attach-row", "chat-cards", "chat-compose",
  "chat-download", "chat-failed", "chat-feedback", "chat-image-coming", "chat-file-links", "chat-find", "chat-flash", "chat-flash-mine", "chat-flash-notice",
  "chat-history-side", "chat-history-side-working", "chat-info", "chat-info-bare", "chat-job", "chat-jobs", "chat-jobs-pop", "chat-jobs-side", "chat-letters",
  "chat-letters-info", "chat-letters-open", "chat-letters-pop", "chat-letters-side", "chat-things",
  "chat-things-side", "chat-info-pulls", "chat-link-menu", "chat-loading", "chat-login", "chat-long", "chat-md",
  "chat-model-pop", "chat-model-accounts", "chat-need", "chat-peek", "chat-pick", "chat-preview-apk",
  "chat-preview-audio", "chat-preview-code", "chat-preview-csv", "chat-preview-html", "chat-preview-image",
  "chat-preview-md", "chat-preview-none", "chat-preview-pdf", "chat-preview-step", "chat-preview-swipe",
  "chat-preview-video", "chat-publish", "chat-quote", "chat-screens", "chat-sending", "chat-service-side",
  "chat-station-file", "chat-station-files", "chat-station-ref", "chat-station-sheet", "chat-tabs-side",
  "chat-view-side", "chat-view-side-image", "chat-view-side-video", "chat-view-side-audio", "chat-update",
  "chat-vault-typed", "chat-viz", "chat-working", "chat-rig", "chat-outline-away", "chat-outline", "chat-outline-find",
  "archived", "history", "history-details", "drive",
  "drive-roots", "drive-download", "drive-empty", "drive-loading", "drive-sub", "drive-upload", "files",
  "files-add-folder", "files-clash", "files-columns", "files-list", "files-preview", "files-split",
  "files-transfers", "files-tree", "place-stations", "place-profiles",
  // (远程: its place, its tabs in the workbench, a chat's remote menu, a terminal in a chat's side panel)
  "place-remote", "place-remote-tabs", "chat-remote", "chat-terminal-side", "reader", "reader-bars", "reader-contents",
  "reader-layout", "reader-md", "newchat", "newchat-files", "newchat-lend", "share-card", "share-card-dark",
  "newchat-model", "newchat-station-models", "newchat-station-empty", "newchat-profiles", "newchat-reading", "newchat-station",
  // (a preset's dialog over 新对话 and its steps further in: the rail behind them, not the panel)
  "newchat-preset-new", "newchat-preset-new-add", "newchat-preset-new-browse", "newchat-preset-new-browse-repos",
  "newchat-preset-new-clone", "newchat-preset-new-clones",
  // (the presets' menu and its level further in: the rail behind them, not the menu)
  "newchat-preset", "newchat-preset-many", "newchat-preset-others", "newchat-preset-others-none", "newchat-preset-theirs",
    "newchat-preset-theirs-long", "player-audio", "player-audio-failed", "player-ended",
  "player-failed", "player-opening", "player-video", "service", "service-restart", "service-sized",
  "service-stopped", "share-in", "share-in-files", "share-in-stations", "lock-security", "lock-upgrade", "lock-needs-app-security", "lock-out-security",
  "lock-restart-security", "lock-rebound-security", "lock-replaced-security",
  "screen-agent-driving",
  "screen-agent-paused", "screen-clipboard-driving", "screen-clipboard-old-station", "screen-connecting",
  "screen-denied", "screen-ended", "screen-failed", "screen-files-done", "screen-files-going", "screen-full",
  "screen-full-tools", "screen-gone", "screen-keys", "screen-live", "screen-login-fill", "screen-login-pick",
  "screen-not-drivable", "screen-outdated", "screen-pages", "screen-read-only", "screen-reconnecting", "screen-trackpad",
  "screen-trackpad-command", "screen-user-pages", "screen-user-tabs", "screen-windows", "screen-window", "settings-home", "settings-appearance", "settings-experimental", "settings-me", "settings-me-reading",
  "settings-workspace", "settings-security", "settings-vault", "settings-vault-items", "settings-vault-item",
  "settings-stations", "settings-stations-unprotected", "settings-station", "settings-station-unprotected", "settings-station-offline", "settings-station-env",
  "settings-station-processes", "settings-station-mark", "settings-station-lower", "settings-station-versions",
  "settings-station-updated",
  "settings-station-network", "settings-station-copies", "settings-station-copies-alone", "settings-station-restore", "settings-station-restore-offer",
  "settings-station-restore-confirm", "settings-station-restore-confirm-long", "settings-station-restored", "settings-station-retire-panel", "settings-station-retire-panel-pick", "settings-station-retire-panel-none", "settings-station-retire-panel-joined", "settings-station-retire-panel-long", "settings-station-retire-sending", "settings-station-retire-sent", "settings-station-retire-sent-failed", "settings-station-retire-quiet", "settings-station-retire-failed", "settings-station-retire-accounts", "settings-station-retire-done", "settings-station-retire-done-left", "settings-station-taking", "settings-station-move", "settings-station-move-chats", "settings-station-move-ended", "settings-station-move-empty", "settings-station-move-none", "settings-station-move-all", "settings-station-move-section", "settings-station-move-offered", "settings-profile-move", "settings-profile-move-key", "settings-stations-add", "settings-stations-existing", "settings-stations-command",
  "settings-first-station", "settings-adb", "settings-adb-unpaired", "settings-adb-pairing",
  "settings-adb-connected", "settings-adb-failed", "settings-adb-chats", "settings-adb-chats-long", "settings-adb-lock-two",
  "settings-adb-idle", "settings-adb-desk", "chat-phone-lacks", "chat-phone-step-off", "chat-phone-step-developer",
  "chat-phone-step-wifi", "chat-phone-step-wireless", "chat-phone-step-refused", "chat-phone-step-code",
  "chat-phone-linked-unpaired", "chat-phone-linked-unauthorized", "chat-phone-linked-connected",
  "settings-profiles", "settings-profiles-monthly", "settings-profiles-fable", "settings-profiles-own3",
  "settings-profiles-week-fable", "settings-profiles-several", "settings-profile-account", "settings-profiles-station",
  "settings-profile", "settings-profile-fable", "settings-profile-own3",
  "settings-profile-week-fable", "settings-profile-quota", "settings-profile-quota-kinds",
  "settings-profile-lower", "settings-profile-unshareable", "settings-profile-login", "settings-profile-login-failed",
  "settings-profile-quota-failed", "settings-profile-blocked", "settings-profile-signin", "settings-profile-key", "settings-profile-copy",
  "settings-new-profile", "settings-new-profile-stations", "settings-new-profile-key", "settings-connects", "settings-connect", "settings-connect-menu", "settings-connect-mode",
  "settings-connect-run", "settings-new-connect", "settings-new-connect-platform", "settings-new-connect-scan",
  "settings-new-connect-app", "settings-new-connect-comma", "settings-connect-comma", "settings-connect-feishu", "settings-new-connect-platform-group", "settings-new-connect-group", "settings-connect-group", "settings-slack-app", "settings-memory", "settings-memory-doc", "settings-usage",
  "settings-archive", "settings-kept", "settings-kept-many", "settings-vault-off", "settings-vault-plain",
  "settings-vault-waits", "settings-vault-confirm", "settings-vault-syncing", "settings-vault-words", "settings-vault-add", "settings-vault-editor", "settings-vault-recover",
  "settings-lock-prompt", "settings-lock-prompt-role", "settings-add-people", "settings-workspace-mark", "settings-local-fonts",
  "settings-policy", "settings-policy-text", "settings-policy-option", "settings-security-join",
  "settings-security-off", "settings-security-open", "settings-security-pending", "settings-security-confirm", "settings-security-root", "settings-security-root-off", "settings-security-again", "settings-security-upgrade-station", "settings-security-upgrade-station-not", "settings-security-upgrade-member", "settings-security-upgrade-device", "settings-security-upgrade-many", "settings-security-upgrade-other", "settings-security-upgrade-updating", "settings-stations-tasks", "place-stations-tasks", "settings-station-tasks", "settings-station-tasks-other", "settings-station-tasks-locked", "settings-stations-devices", "place-stations-devices", "settings-station-devices", "settings-fonts",
  "settings-fonts-code", "settings-decisions", "settings-completion", "settings-bars", "settings-about",
  "settings-changelog", "settings-prices", "settings-notify-off", "settings-notify-denied", "share-card-poster",
  "share-card-receipt", "share-card-senren-adv", "share-card-senren-affection", "share-card-senren-cg",
  "share-card-senren-chat", "share-card-senren-chibi", "share-card-senren-ciallo", "share-card-senren-class",
  "share-card-senren-ema", "share-card-senren-gacha", "share-card-senren-gahou-koharu",
  "share-card-senren-gahou-lena", "share-card-senren-gahou-mako", "share-card-senren-gahou-murasame",
  "share-card-senren-gahou-roka", "share-card-senren-gahou-roka2", "share-card-senren-inumimi",
  "share-card-senren-kagura", "share-card-senren-ledger", "share-card-senren-map", "share-card-senren-menu",
  "share-card-senren-night", "share-card-senren-ninja", "share-card-senren-omikuji", "share-card-senren-parfait",
  "share-card-senren-party", "share-card-senren-photo", "share-card-senren-ryokan", "share-card-senren-staff",
  "share-card-senren-sword", "share-card-senren-title", "share-card-terminal",
]

///|
/// Words a box with its height said does not hold (mbui's Tester::fixed_outgrown) on every screen in every window
/// (corners_wbtest.mbt), by window, language and screen: the bar it may only fall from, counted as the rule first ran
/// (2026-11-11). A screen not listed has none; none is now (智能体's card's spend, an old view's, on its own line of 26
/// since, as its box was).
let corners_outgrown_known : Map[String, Int] = Map([])

///|
/// What is pressed side by side another height than the rest of its row (mbui's Tester::height_faults; the user,
/// 2026-10-30: what can be pressed is one height) on every screen in every window (corners_wbtest.mbt), by window,
/// language and screen: the bar it may only fall from, counted as the rule first ran (2026-11-14). A screen not listed
/// has none, and none is now. Listed till then: 连接's 继续 (a connect's session waiting to go on) in the wide windows, its button 36 and the
/// icon's button beside it 32. And what old views hosted in the window's tree show, not measured till the spacing rules
/// took the tree's nodes in each after its parent (2026-11-14): 屏幕's pages in the wide windows till their ＋ was as
/// high as their tabs (2026-11-17; their address field beside 后退, 2026-11-15); a chat's 任务 beside it in the
/// wide windows till it was made of nodes (2026-11-15); 连接's waiting app's ⋯ beside its 继续 till it was
/// as high as its row's first line (2026-11-17).
let corners_heights_known : Map[String, Int] = Map([])

///|
/// A mark beside a block of several lines off its first line (mbui's Tester::first_line_faults; the user, 2026-11-14:
/// beside several lines an icon, a mark or a chevron sits on the first, never centred on them) on every screen in every
/// window (corners_wbtest.mbt), by window, language and screen: the bar it may only fall from, counted as the rule
/// first ran (2026-11-15). A screen not listed has none. Listed: rows whose icon is centred on a name over a line under
/// it: 连接's connects (and a new one's choices), a station's commands, a preset's folders (its icon and chevron), a
/// file's card in a chat (published files), a found message in the outline, 决策's chevron, a run's model in its
/// history's details (its icon and chevron). And what old views hosted in the window's tree show, measured once the
/// rules took the tree's nodes in each after its parent (#6294, 2026-11-15): a chat's files and references, its
/// agent's card, 文件's rows, a station's settings; fewer since a chat's page is made as nodes on the test channel
/// (2026-11-19): its files, references and screens there on their first lines.
let corners_first_line_known : Map[String, Int] = Map([
  ("phone-en history-details", 2),
  ("phone-zh history-details", 2),
  ("desk-en newchat-preset-new-browse", 2),
  ("desk-win-en newchat-preset-new-browse", 2),
  ("desk-win-zh newchat-preset-new-browse", 2),
  ("desk-zh newchat-preset-new-browse", 2),
  ("phone-en settings-connects", 2),
  ("phone-en settings-new-connect", 2),
  ("phone-en settings-new-connect-app", 2),
  ("phone-en settings-new-connect-comma", 2),
  ("phone-en settings-new-connect-platform", 2),
  ("phone-en settings-new-connect-platform-group", 2),
  ("phone-en settings-new-connect-group", 2),
  ("phone-en settings-new-connect-scan", 2),
  ("phone-zh settings-connects", 2),
  ("phone-zh settings-new-connect", 2),
  ("phone-zh settings-new-connect-app", 2),
  ("phone-zh settings-new-connect-comma", 2),
  ("phone-zh settings-new-connect-platform", 2),
  ("phone-zh settings-new-connect-platform-group", 2),
  ("phone-zh settings-new-connect-group", 2),
  ("phone-zh settings-new-connect-scan", 2),
  ("tablet-en chat-outline-find", 1),
  ("tablet-en chat-publish", 2),
  ("tablet-en newchat-preset-new-browse", 2),
  ("tablet-en settings-connects", 2),
  ("tablet-en settings-new-connect", 2),
  ("tablet-en settings-new-connect-app", 2),
  ("tablet-en settings-new-connect-comma", 2),
  ("tablet-en settings-new-connect-platform", 2),
  ("tablet-en settings-new-connect-platform-group", 2),
  ("tablet-en settings-new-connect-group", 2),
  ("tablet-en settings-new-connect-scan", 2),
  ("tablet-zh chat-outline-find", 1),
  ("tablet-zh chat-publish", 2),
  ("tablet-zh newchat-preset-new-browse", 2),
  ("tablet-zh settings-connects", 2),
  ("tablet-zh settings-new-connect", 2),
  ("tablet-zh settings-new-connect-app", 2),
  ("tablet-zh settings-new-connect-comma", 2),
  ("tablet-zh settings-new-connect-platform", 2),
  ("tablet-zh settings-new-connect-platform-group", 2),
  ("tablet-zh settings-new-connect-group", 2),
  ("tablet-zh settings-new-connect-scan", 2),
  ("touch-en chat-outline-find", 1),
  ("touch-en chat-publish", 2),
  ("touch-en newchat-preset-new-browse", 2),
  ("touch-zh chat-outline-find", 1),
  ("touch-zh chat-publish", 2),
  ("touch-zh newchat-preset-new-browse", 2),
  ("wide-en chat-publish", 2),
  ("wide-en newchat-preset-new-browse", 2),
  ("wide-en settings-connects", 2),
  ("wide-en settings-new-connect", 2),
  ("wide-en settings-new-connect-app", 2),
  ("wide-en settings-new-connect-comma", 2),
  ("wide-en settings-new-connect-platform", 2),
  ("wide-en settings-new-connect-platform-group", 2),
  ("wide-en settings-new-connect-group", 2),
  ("wide-en settings-new-connect-scan", 2),
  ("wide-win-en chat-publish", 2),
  ("wide-win-en newchat-preset-new-browse", 2),
  ("wide-win-en settings-connects", 2),
  ("wide-win-en settings-new-connect", 2),
  ("wide-win-en settings-new-connect-app", 2),
  ("wide-win-en settings-new-connect-comma", 2),
  ("wide-win-en settings-new-connect-platform", 2),
  ("wide-win-en settings-new-connect-platform-group", 2),
  ("wide-win-en settings-new-connect-group", 2),
  ("wide-win-en settings-new-connect-scan", 2),
  ("wide-win-zh chat-publish", 2),
  ("wide-win-zh newchat-preset-new-browse", 2),
  ("wide-win-zh settings-connects", 2),
  ("wide-win-zh settings-new-connect", 2),
  ("wide-win-zh settings-new-connect-app", 2),
  ("wide-win-zh settings-new-connect-comma", 2),
  ("wide-win-zh settings-new-connect-platform", 2),
  ("wide-win-zh settings-new-connect-platform-group", 2),
  ("wide-win-zh settings-new-connect-group", 2),
  ("wide-win-zh settings-new-connect-scan", 2),
  ("wide-zh chat-publish", 2),
  ("wide-zh newchat-preset-new-browse", 2),
  ("wide-zh settings-connects", 2),
  ("wide-zh settings-new-connect", 2),
  ("wide-zh settings-new-connect-app", 2),
  ("wide-zh settings-new-connect-comma", 2),
  ("wide-zh settings-new-connect-platform", 2),
  ("wide-zh settings-new-connect-platform-group", 2),
  ("wide-zh settings-new-connect-group", 2),
  ("wide-zh settings-new-connect-scan", 2),
  ("phone-en chat-station-file", 1),
  ("phone-en chat-station-sheet", 1),
  ("phone-en service-restart", 1),
  ("phone-zh chat-station-file", 1),
  ("phone-zh chat-station-sheet", 1),
  ("phone-zh service-restart", 1),
  ("tablet-en chat-station-file", 1),
  ("tablet-en chat-station-sheet", 1),
  ("tablet-zh chat-station-file", 1),
  ("tablet-zh chat-station-sheet", 1),
  ("wide-en chat-station-file", 1),
  ("wide-en chat-station-sheet", 1),
  ("wide-win-en chat-station-file", 1),
  ("wide-win-en chat-station-sheet", 1),
  ("wide-win-zh chat-station-file", 1),
  ("wide-win-zh chat-station-sheet", 1),
  ("wide-zh chat-station-file", 1),
  ("wide-zh chat-station-sheet", 1),
])

///|
/// A line under a marked line starting between its mark and its words (mbui's Tester::line_start_faults; a profile's
/// row in 设置, its state line under the middle of its logo, 「感觉这个对齐有点问题」, 2026-11-15) on every screen in
/// every window (corners_wbtest.mbt), by window, language and screen: the bar it may only fall from, counted as the
/// rule first ran (2026-11-15). A screen not listed has none. Listed: a profile's row in the profiles' list, its line
/// of what is wrong (没能使用) from the row's words' inset, under its logo drawn out to its chips' capsules.
let corners_line_start_known : Map[String, Int] = Map([])
