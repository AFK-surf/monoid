///|
/// The flows whose pace pass (orders: the strict pass again with run_for's frames at 7 a second, and at 120) tells
/// the core otherwise than the strict pass, by trace, at which rates: each stops at its first split (PACE-SPLIT says
/// where, message by message). Only falls: a flow that splits and is not here fails, one here that splits no more
/// fails till it is taken out. A cause mended a layer down may show the next one further on, the flow still here.
/// Grouped by the first message apart (the pace pass's | the strict pass's); the cause said where it was traced, the
/// rest by what shows: what the app reads of the core it asks as a frame is built, so a sparser display's frames
/// ask it later than an input that came meanwhile (the coordinator of the migration, 2026-11-11: the next step,
/// what a page reads said as it is made).
///
/// It rises only where the measure came truer (the coordinator of the migration, 2026-11-11), never for the app: each
/// flow so added shows the app unchanged and the split a device's already, and the migration's coordinator agrees.
/// A cause mended takes flows out too: 2026-11-17 (the owner: 「不登记，去改框架」), a press between two frames on what
/// the old view drew has it drawn at the press's moment first (ui's frame_at_press), so a sheet's button coming in is
/// where it is then, not where a sparser display's frame before it drew it: 22 flows out at 7 a second.
/// Once so: #5519 (the fake host tells what is posted at the moment it is posted, as a device's host does, no longer as
/// the next frame begins; not a line of what a device runs changed) took 120 a second from 10 flows to 11: share and
/// station-files out, glass, settings-run-settings and wide-answer-reply in (each says why where it is).
// kept across runs: a value
let pace_splits_known : Map[String, Array[Int]] = {
  // 20: sub {"scope":…,"topic":"stations"} | strict sub {"topic":"chat","compact":true,"session":…,"station":…}
  // (the first tap on a chat's row comes before the frame that builds Home's list and sends its reads (they go
  // out as a frame is built): at 7 a second it falls on the bar under it, Station's tab (glass: Home's
  // subscriptions at 1159 here, 1033-1050 in the strict pass; the tap at 1150))
  "service-page": [7],
  // (two sends 67 ms apart, under a frame at 7 a second (142.86 ms): the second's composer.take goes out before the
  // frame that sends the first's chat.send; the trace recorded again with its frames, 120 a second the same)
  "send-flying": [7],
  // 6: sub {"topic":"workspace","workspace":…} | strict sub {"topic":"doing"}
  "drive-lend": [7],
  "drive-play": [7],
  // 5: sub {"query":…,"scope":…,"topic":"search"} | strict call cache.usage {}
  "settings-profile": [7],
  "settings-station-settings": [7],
  "settings-workspace-people": [7],
  // 4: - | strict sub {"topic":"chat","compact":true,"session":…,"station":…}
  "notice-looking": [7],
  // wide-answer-reply at 120 (#5519): the new chat page sends its composer, machineSessions.list and status's
  // release in the frame at 1050 ms, notify.permission (sent once notify's values are in, which came after that
  // frame) in the next, at 1058.3; the strict pass sends all four in its frame at 1083.3, notify.permission before
  // machineSessions.list; gone with what a page reads said as it is made
  "wide-answer-reply": [7],
  "wide-send": [7],
  // 3: sub {"query":…,"scope":…,"topic":"shareIn","source":…} | strict sub {"topic":"notify"}
  "share": [7],
  "share-files": [7],
  "share-new-chat": [7],
  // 2: unsub {"topic":"status"} | strict sub {"topic":"workspace","workspace":…}
  "places": [7],
  // 1: - | strict call drive.remove {"path":"照片-082940.jpg",...,"permanent":true}
  // (Menu -> Confirm now slides horizontally inside the same 390pt sheet over move_ms(390)=350ms; the old trace taps
  // `=删除` 176.9ms after `icon:trash` mid-slide, so at 7fps two frames = 285.7ms moves the right-aligned button ~45pt
  // left of strict's mid-slide kept_point; 60fps strict and 120fps pace both pass)
  "drive-delete": [7],
  // 1: - | strict call lock.pair {"workspace":…}
  "lock-wait": [7],
  // 1: - | strict call link.parse {"url":…}
  "notice-failed": [7],
  // 1: - | strict call session.warm {"key":…,"station":…}
  "wide-newline": [7],
  // 1: unsub {"topic":"doing"} | strict sub {"scope":…,"topic":"newChat"}
  "wide-places": [7],
  // 1: sub {"topic":"workspaceMarks","workspace":…} | strict sub {"scope":…,"topic":"longJobs"}
  "wide-resize": [7],
  // 1: sub {"query":…,"scope":…,"topic":"search"} | strict call notify.permission {"state":"unknown"}
  "wide-switcher": [7],
}

///|
/// What the pace passes came to split at, besides pace_splits_known, as the replay came to give each message at its own
/// moment and its strict pass the run's steps at the run's moments (the replay's rig, the coordinator of the migration,
/// 2026-11-12): a split each, untraced yet, found where a stop before it had hidden it or where the measure came truer.
/// Held as pace_splits_known is, and only falls: each is traced in turn and goes with its cause.
// kept across runs: a value (each split as PACE says it in the flow's run: none left)
let pace_splits_untraced : Map[String, Array[Int]] = Map([])

///|
/// The flows whose strict pass asks what their run did not, known, by trace: each ask exactly, in its order, at its
/// moment on the app's clock; any other is the flow's failure as ever, and one that asks it no more fails till it is
/// taken out. Only falls (the coordinator of the migration, 2026-11-11: no ask allowed by its kind, no trace recorded
/// again over one).
// kept across runs: a value
let strict_diverged_known : Map[String, Array[(Double, String)]] = {
  // lock-wait (#5519; anew with what the first screen reads declared, #5589; anew with notify.permission told as
  // notify is answered, between frames, #5613: it takes the id before doing's and driveTransfers', and what the
  // replay held for it comes a frame sooner): at 22116.7 the lock's delta (safe mode off) takes the waiting page away
  // and with it what it had taken over of what was declared as the workspace came in view, doing and driveTransfers
  // (taken over, then its reader gone, the next not come yet: a gap a declaration does not mend; driveTransfers no
  // longer since Home's transfers key is made as nodes, at rest while it does not show); Home's frame at
  // 22133.3 asks doing again. The run's device took it in the frame that built the next page, behind a message before
  // it, so nothing was let go. Gone with #5135 (what is read kept by its topic while a page is covered), whose merge
  // takes this out.
  // (timestamps shifted +5.6108ms with lazy moves_for settlement: non-transition messages no longer lay out between frames)
  "lock-wait": [
    (23102.5849609375, "{\"id\":14,\"unsubscribe\":true}"),
    (23116.666666666668, "{\"id\":24,\"subscribe\":{\"topic\":\"doing\"},\"keyed\":true}"),
  ],
}

///|
/// How long after the last message its run had before its first step each flow's first step found what it waits for
/// so (its first screen: Flow::first_screen), in ms and the display's frames drawn meanwhile, in the strict pass. Its
/// waits before that step wait (the moments there are those of the app that recorded the run, before #5589 and #5618,
/// asking otherwise as it started), so how long the first screen takes is measured here instead: only falls, each
/// flow's ms and frames at most its own, one under them to be brought down (the coordinator of the migration,
/// 2026-11-12: B). Once the traces are recorded again under the strict pass's moments, those waits are assertions and
/// this goes.
// kept across runs: a value
let first_screen_known : Map[String, (Double, Int)] = Map([])

///|
/// The traces recorded before a run kept its display's frames (`{"frame":…}` lines, mbui's @ui.trace_frames): their
/// strict pass's frames on a grid of their own, a phase apart from the run's, so whether a step's screen was so at the
/// run's moment for it is measured there, not judged (LATE-UNFRAMED; the coordinator of the migration, 2026-11-12: a
/// phase guessed from the steps' moments would still be a frame's building off). Only falls: each trace recorded again
/// keeps its frames and leaves it; a new one is recorded with them.
// kept across runs: a value
let frames_unrecorded_known : Array[String] = [
  "answer-option",
  "appearance-kept",
  "archive-restore",
  "bar-archive",
  "bar-glass",
  "bar-going-down",
  "chat-audio",
  "chinese-enter",
  "delete-failed",
  "dismiss",
  "draft-restart",
  "drive-delete",
  "drive-lend",
  "drive-list",
  "drive-play",
  "drive-read",
  "drive-rename",
  "drive-sheet-closing",
  "drive-upload",
  "drive-zip",
  "glass",
  "home-new-chat",
  "lock-wait",
  "markdown",
  "new-chat",
  "notice-cancel",
  "notice-failed",
  "notify-off",
  "offline-retry",
  "pin",
  "places",
  "reader",
  "send-card-paced",
  "settings-add-station",
  "settings-appearance",
  "settings-connect",
  "settings-decisions",
  "settings-device-pages",
  "settings-profile",
  "settings-sheet-sinking",
  "settings-station-mark",
  "settings-station-settings",
  "settings-vault-item",
  "settings-workspace-people",
  "station-file-sent",
  "station-rename",
  "workspace-members",
]

///|
/// The flows whose strict pass (orders' first: the run's steps at the run's moments, src/sfreplay/steps.mbt) fails, by
/// trace: its first failure as it says it, and what it is, traced to its line, or "untraced". A new measure's baseline
/// as it came in (the coordinator of the migration, 2026-11-12), only falls: a flow failing otherwise, or one here that
/// fails no more, fails. The flow's own checks are the lenient pass's, whole, whatever its strict pass came to.
/// drive-download-many's and wide-places' are one kind, untraced yet: nothing moves at the run's moment, and what the
/// step waits for is the core's next answers, which the replay gives later than the run's moment; which of the replay's
/// steps makes them late is to be found (the coordinator of the migration, 2026-11-12), both to go with it.
// kept across runs: a value
let strict_known : Map[String, (String, String)] = Map([
  (
    "settings-add-station",
    (
      "its motion at rest at 2295.209228515625 ms, 16.55908203125 ms after the run's next step (2278.650146484375 ms; its timeline 13.2421875 ms later from its first step); said since the last step that acted: ",
      "untraced: a motion at rest 16.6 ms after the run's next step, nothing said since the last step that acted (the list's ＋ a node's press since the stations' list was made once: sfpages' stations_list.mbt, page_add_node)",
    ),
  ),
  (
    "wide-places",
    (
      "src/sfreplay/flows/wide_places_test.mbt:12:5-12:17@stillfail: not so at 1097.4521484375 ms, the run's moment for it (its timeline 14.4169921875 ms later from its first step): so at 2084.735107421875 ms, 987.282958984375 ms later",
      "traced (recorded again 2026-11-17, its 文件 made once as nodes; main's app replays it the same): the run's app asked 文件's folder (driveBrowse, drive.browse, drive) before the core answered its `workspace`, so the trace has that answer after those asks, and the replay gives it only once they are made again (core/replay.mbt Replay::ready); the replay's app shows 文件, and makes its folder, once what it reads at rest is answered, `workspace` among it (sfbase/page_reads.mbt page_reads, sfdesk/frame.mbt pane_opens): each waits for the other till page_local_ms (1000 ms) lets the page show, 992 ms after the run's moment",
    ),
  ),
])

///|
/// What a flow's own judgement says where the app does as a device does and the cause is traced to its line, by
/// trace: each as it says it, its moment with it, and why, so that a pass that comes to it notes it and goes on to the
/// flow's next step, its checks after it judged as ever (the coordinator of the migration, 2026-11-12). Only what is
/// traced to its line comes in, and only falls: said otherwise (later, or other words) it fails as ever, and one no
/// longer said fails, to be taken out. Another flow said so for the same cause may come in by the same entry; any other
/// cause is the coordinator's to say.
// kept across runs: a value
let judged_traced_known : Map[String, Array[(String, String)]] = Map([])
