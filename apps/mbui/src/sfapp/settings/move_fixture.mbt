// What of Willow moves to another station, made up in the core's shape (MoveView: the core's move.ts of a station's
// GET /move), and the `move.*` calls (src/sfpages station_move_node.mbt). settings-station-move: the page, Maple
// chosen, some of each module there and nothing under way (its modules closed); -chats: one chat moving, one stopped
// waiting for a connect, one failed and one that cannot move, saying why (聊天 open by itself); -ended: that turn
// ended, the chat moved, each row's action at its end; -empty: every module empty; -none: no station chosen yet;
// -all: 全部迁移 asked; -section: Willow's own page with its 迁移; -offered: its ⋯ with 迁移到另一台 station.
// Every word here is made up.

///|
priv struct MoveFixture {
  /// Willow offers moving (its overview's `move.offered`)
  mut offered : Bool
  /// how far it is: "" nothing moved; "half" some of each there, nothing under way; "mid" a chat moving, one stopped,
  /// one failed; "ended" that turn ended, the chat there; "done" all of it there; "empty" every module empty
  mut stage : String
  /// the stations it may go to are online (Maple, Cedar; Birch offline after them); false: none it may go to (Maple on
  /// the stable release, Cedar offline), each saying why
  mut targets : Bool
  /// moving is off where it goes: a move is refused in its words
  mut off : Bool
  /// the call refused a moment ago, as the core's `doing` keeps it: its params and why
  mut refused : (Json, String)?
  /// the turn under way asked to stop (`move.stop`)
  mut stopping : Bool
}

///|
let fx_move : MoveFixture = { offered: false, stage: "", targets: true, off: false, refused: None, stopping: false }

///|
/// The `move.*` calls asked, as they were asked (name and params).
pub let fixture_move_asked : Array[(String, Json)] = []

///|
/// As a run starts.
fn move_fixture_reset() -> Unit {
  fx_station_beta.val = true
  fx_move.offered = false
  fx_move.stage = ""
  fx_move.targets = true
  fx_move.off = false
  fx_move.refused = None
  fx_move.stopping = false
  fixture_move_asked.clear()
  move_chosen.clear()
}

///|
/// A test's switch: Willow offers moving or not; how far it is; moving refused where it goes.
pub fn fixture_move(offered? : Bool = true, stage? : String = "half", off? : Bool = false, targets? : Bool = true) -> Unit {
  fx_move.offered = offered
  fx_move.stage = stage
  fx_move.off = off
  fx_move.targets = targets
  fx_changed()
}

///|
/// A fixture mode of these (its page opened by fixture_page): the stage, the station chosen, what is put up over it.
fn move_fixture_mode(m : String) -> Bool {
  match m {
    "settings-station-move"
    | "settings-station-move-chats"
    | "settings-station-move-ended"
    | "settings-station-move-empty"
    | "settings-station-move-none"
    | "settings-station-move-all" => {
      fx_move.offered = true
      fx_move.stage = match m {
        "settings-station-move-chats" => "mid"
        "settings-station-move-ended" => "ended"
        "settings-station-move-empty" => "empty"
        _ => "half"
      }
      if m != "settings-station-move-none" {
        move_chosen["ws1/st1"] = "st2"
      }
      if m == "settings-station-move-all" {
        fixture_open.desk = "move-all"
      }
      true
    }
    "settings-station-move-section" | "settings-station-move-offered" => {
      fx_move.offered = true
      fx_move.stage = if m == "settings-station-move-section" { "mid" } else { "" }
      station_parts["ws1/st1"] = "overview"
      true
    }
    _ => false
  }
}

///|
/// Willow's overview's `move`.
fn fx_move_offer() -> Json {
  obj([("offered", Json::boolean(fx_move.offered))])
}

///|
/// Whether Willow is updated on the test channel (a mode's `-stable` says not): it runs its `beta` features then.
// kept across runs: true as a run begins (move_fixture_reset)
let fx_station_beta : Ref[Bool] = Ref(true)

///|
/// A test's switch: Willow updated on the test channel (`beta`) or the stable one, whatever the app's own channel.
pub fn fixture_station_channel(beta : Bool) -> Unit {
  fx_station_beta.val = beta
  fx_changed()
}

///|
/// Its overview's `features` (station/src/features.ts): on the test channel its terminals; and moving, graduated, said
/// for apps from before wherever it offers it (`GRADUATED_SAID`).
fn fx_station_features() -> Json {
  let out : Array[Json] = []
  if fx_station_beta.val {
    out.push(Json::string("terminal"))
  }
  if fx_move.offered {
    out.push(Json::string("stationMove"))
  }
  Json::array(out)
}

///|
/// An item as the core shapes it, its action as the core gives it (`acts`: nothing under way, a station chosen).
fn fx_move_item(acts : Bool, id : String, label : String, state : String, text_ : String, note? : String = "", progress? : Json = Json::null()) -> Json {
  let action = match (acts, state) {
    (false, _) => ""
    (_, "there") => "back"
    (_, "failed") => "retry"
    (_, "here") => "move"
    _ => ""
  }
  obj([
    ("id", str(id)),
    ("label", str(label)),
    ("state", str(state)),
    ("stateText", str(text_)),
    ("note", str(note)),
    ("progress", progress),
    ("action", str(action)),
  ])
}

///|
/// What of Willow moves to `to` ("" none chosen) with `module`'s items open, as the core says it now.
fn fx_move_view(params : Map[String, Json]) -> Json {
  let p = Some(Json::object(params))
  let to = text(p, "to")
  let open = text(p, "module")
  let mid = fx_move.stage == "mid"
  // (the turn that moved a chat ended: what it left as it was)
  let ended = fx_move.stage == "ended"
  let some = fx_move.stage != "" && fx_move.stage != "empty"
  let acts = to != "" && !mid
  let name = match to {
    "st2" => "Maple"
    "st3" => "Cedar"
    _ => ""
  }
  let moving = obj([("done", Json::number(12.0 * 1048576.0)), ("total", Json::number(40.0 * 1048576.0)), ("text", str("12 MB / 40 MB"))])
  let there_ = tr("core-views.move.state.there")
  let chats = if mid || ended {
    [
      fx_move_item(acts, "k1", "整理发布清单", "there", there_),
      fx_move_item(acts, "k2", "周会纪要：本周发布前要逐项确认的事情和每一项的负责人", "there", there_),
      if mid {
        fx_move_item(acts, "k3", "修复登录后首页闪白", "moving", tr("core-views.move.state.moving"), progress=moving)
      } else {
        fx_move_item(acts, "k3", "修复登录后首页闪白", "there", there_)
      },
      fx_move_item(acts, "k4", "发版前跑一遍回归", "stopped", fill("core-views.move.state.stopped", [("what", "Slack · 星火")])),
      fx_move_item(acts, "k5", "整理设计稿", "failed", tr("core-views.move.state.failed"), note="Maple 的磁盘只剩 2.1 GB，这个聊天的文件要 3.4 GB：在 Maple 上腾出空间再试"),
      fx_move_item(acts, "k6", "周报", "cannot", tr("core-views.move.state.cannot"), note="它的工作目录在 station 之外（/Volumes/Work）：把目录移进 station 的工作区再迁"),
      fx_move_item(acts, "k7", "草稿", "here", ""),
    ]
  } else {
    [
      fx_move_item(acts, "k1", "整理发布清单", if some { "there" } else { "here" }, if some { there_ } else { "" }),
      fx_move_item(acts, "k2", "周会纪要：本周发布前要逐项确认的事情和每一项的负责人", if some { "there" } else { "here" }, if some { there_ } else { "" }),
      fx_move_item(acts, "k3", "修复登录后首页闪白", "here", ""),
      fx_move_item(acts, "k4", "发版前跑一遍回归", "here", ""),
      fx_move_item(acts, "k7", "草稿", "here", ""),
    ]
  }
  // ("done": all of it there)
  let full = fx_move.stage == "done"
  let block_of = fn(id : String, needs : Array[String], done : Int, total : Int, mark : String, all : Array[Json]) {
    let done = if full { total } else { done }
    let action = if !acts { "" } else if done >= total { "back" } else { "move" }
    obj([
      ("id", str(id)),
      ("needs", Json::array(needs.map(fn(n) { str(n) }))),
      ("done", Json::number(done.to_double())),
      ("total", Json::number(total.to_double())),
      ("count", str(fill("core-views.move.count", [("done", done.to_string()), ("total", total.to_string())]))),
      ("mark", str(mark)),
      ("markText", str(if mark == "" { "" } else { tr("core-views.move.mark." + mark) })),
      ("opens", Json::boolean(mark != "")),
      ("action", str(action)),
      ("items", Json::array(if open == id { all } else { [] })),
      ("more", Json::boolean(false)),
    ])
  }
  let d = fn(n : Int) { if some { n } else { 0 } }
  // (those that have items: jobs has none, so is not shown; "empty", none has any)
  let modules = if fx_move.stage == "empty" {
    []
  } else {
    [
      block_of("accounts", [], d(2), 3, "", [
        fx_move_item(acts, "p1", "Claude 主账号", if some { "there" } else { "here" }, if some { there_ } else { "" }),
        fx_move_item(acts, "p2", "ChatGPT 团队", if some { "there" } else { "here" }, if some { there_ } else { "" }),
        fx_move_item(acts, "p3", "本机 Codex 登录", "cannot", tr("core-views.move.state.cannot"), note="这台机器自己的登录不迁：在 Maple 上登录它自己的"),
      ]),
      // (in the order the core gives them, move.ts MODULES: what the chats need, the station's settings, the chats;
      // jobs has none here, so is not shown)
      block_of("connects", ["chats"], 0, 2, "", []),
      block_of("repos", [], d(2), 4, "", []),
      block_of("vault", [], d(1), 1, "", []),
      block_of("settings", [], 0, 1, "", []),
      block_of(
        "chats",
        ["accounts", "connects", "repos", "vault"],
        if ended { 3 } else { d(2) },
        if mid || ended { 7 } else { 5 },
        if mid { "moving" } else if ended { "failed" } else { "" },
        chats,
      ),
    ]
  }
  // (what cannot move of the items read: 本机 Codex 登录, and 周报 once a turn moved chats)
  let cannot = if fx_move.stage == "empty" { 0 } else if mid || ended { 2 } else { 1 }
  let target = fn(id, name, free, why) {
    obj([("station", str(id)), ("name", str(name)), ("free", str(free)), ("why", str(why))])
  }
  let targets = if fx_move.targets {
    [
      target("st2", "Maple", fill("core-views.move.free", [("size", "120 GB")]), ""),
      target("st3", "Cedar", fill("core-views.move.free", [("size", "2.1 TB")]), ""),
      target("st4", "Birch", "", tr("core-views.move.why.offline")),
    ]
  } else {
    [
      target("st2", "Maple", fill("core-views.move.free", [("size", "120 GB")]), tr("core-views.move.why.stable")),
      target("st3", "Cedar", "", tr("core-views.move.why.offline")),
    ]
  }
  let left = modules.fold(init=0, fn(n, m) { n + number(Some(m), "total").to_int() - number(Some(m), "done").to_int() })
  let there = modules.fold(init=0, fn(n, m) { n + number(Some(m), "done").to_int() })
  obj([
    ("to", str(to)),
    ("toName", str(name)),
    ("targets", Json::array(targets)),
    ("canMove", Json::boolean(true)),
    (
      "moving",
      if mid {
        obj([("module", str("chats")), ("item", str("k3")), ("line", str(tr("core-views.move.module.chats") + " · 修复登录后首页闪白 · 12 MB / 40 MB")), ("progress", moving), ("stopping", Json::boolean(fx_move.stopping))])
      } else {
        Json::null()
      },
    ),
    // (its station's page's row: a move under way, something stopped or failed; something there alone, none: move.ts)
    ("active", Json::boolean(mid || ended)),
    // (no station chosen, its station's page: the last move went to Maple)
    ("title", str(if some { fill("core-views.move.summary.to", [("name", if name == "" { "Maple" } else { name })]) } else { tr("core-views.move.summary.title") })),
    ("count", str(fill("core-views.move.count", [("done", there.to_string()), ("total", (left + there).to_string())]))),
    (
      "note",
      str(
        if mid {
          [
            fill("core-views.move.summary.failed", [("n", "1")]),
            fill("core-views.move.summary.stopped", [("n", "1")]),
            fill("core-views.move.summary.moving", [("module", tr("core-views.move.module.chats")), ("label", "修复登录后首页闪白")]),
          ].join(" · ")
        } else if ended {
          [fill("core-views.move.summary.failed", [("n", "1")]), fill("core-views.move.summary.stopped", [("n", "1")])].join(" · ")
        } else {
          ""
        },
      ),
    ),
    ("allThere", Json::boolean(full && acts)),
    (
      "allMove",
      if !acts || left == 0 {
        Json::null()
      } else {
        let n = fill("core-views.move.all.text", [("n", left.to_string())])
        let text_ = if cannot == 0 { n } else { n + " · " + fill("core-views.move.all.cannot", [("n", cannot.to_string())]) }
        obj([("n", Json::number(left.to_double())), ("title", str(fill("core-views.move.all.title", [("name", name)]))), ("text", str(text_))])
      },
    ),
    (
      "allBack",
      if !acts || there == 0 {
        Json::null()
      } else {
        obj([("n", Json::number(there.to_double())), ("title", str(fill("core-views.move.back.title", [("name", name)]))), ("text", str(fill("core-views.move.back.text", [("n", there.to_string())])))])
      },
    ),
    ("modules", Json::array(modules)),
    ("nothing", str(if fx_move.stage == "empty" { tr("core-views.move.nothing") } else { "" })),
  ])
}

///|
/// The core's `doing` of a move refused a moment ago (failed_of's).
fn fx_move_doing() -> Array[Json] {
  match fx_move.refused {
    Some((params, why)) => [obj([("call", str("move.start")), ("stage", str("failed")), ("error", str(why)), ("params", params)])]
    None => []
  }
}

///|
/// A `move.*` call answered as the core would: asked of Willow, the station it goes to named; refused in the station's
/// words where moving is off there (kept as the core's `doing` keeps a failure).
fn move_fixture_call(name : String, p : Json?) -> Result[Json, Json]? {
  guard name == "move.start" || name == "move.back" || name == "move.stop" else { return None }
  fixture_move_asked.push((name, p.unwrap_or(Json::null())))
  if name == "move.stop" {
    guard text(p, "station") == "ws1/st1" else { return Some(Err(obj([("code", str("invalid")), ("message", str("missing station"))]))) }
    fx_move.stopping = true
    fx_changed()
    return Some(Ok(obj([("stopping", Json::boolean(true))])))
  }
  let at = text(p, if name == "move.back" { "from" } else { "to" })
  if text(p, "station") != "ws1/st1" || at == "" {
    return Some(Err(obj([("code", str("invalid")), ("message", str("missing station or to"))])))
  }
  if fx_move.off {
    let why = "这台 station 还没开放在 station 之间迁移聊天：没有迁移任何内容。"
    fx_move.refused = Some((p.unwrap_or(Json::null()), why))
    fx_changed()
    return Some(Err(obj([("code", str("http_409")), ("message", str(why))])))
  }
  Some(Ok(obj([("started", Json::boolean(true))])))
}
