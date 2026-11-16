// MBUI_FIXTURE=board (board-dark, board-list: the same chats as Home's list): a workspace's chats at every stand the
// board sorts them by (waiting on a decision, on help, failed; at work, waiting on CI; done; keeping watch), on Willow
// and Maple, with Claude, Codex and Gemini, 林, Ana and 周, from Slack and Feishu, each chat with what was said in it;
// two drafts in 待派发, kept in the prefs as the core keeps them (`boardViews`, `boardDrafts`: board-list none, the
// list shown). The made-up station goes on as a person does: a decision made or words sent in a chat that waited, it
// is at work again; a draft started, its chat made under its key (`newChat.create`: a pending row, as the core's) and
// its words sent into it (`chat.send`: at work at once, the station's row keeping the key it was made under).

///|
/// Whether `mode` is one of the board's.
pub fn board_mode(mode : String) -> Bool {
  mode == "board" || mode.has_prefix("board-")
}

///|
/// The chats the drafts started became, newest first, as the made-up station keeps them (each by the key it was made
/// under: a pending row till its words are sent).
// kept across runs: put back as a fixture is made (fixture)
pub let board_started_rows : Array[Json] = []

///|
/// The board's prefs as the core keeps them (`boardViews`, `boardGroups`, `boardShowEmpty`, `boardDrafts`), each by workspace.
// kept across runs: put back as a fixture is made (board_prefs_seed)
pub let board_prefs : Map[String, Map[String, Json]] = Map([])

///|
/// Why the made-up station refuses to make a draft's chat ("" it makes it): a test's, put back as a fixture is made.
// kept across runs: put back as a fixture is made (board_prefs_seed)
pub let board_create_refused : Ref[String] = Ref("")

///|
/// The board's prefs a fixture of `mode` starts with: board-list none; the others the board shown in ws1 (board-off
/// not shown), its two drafts.
pub fn board_prefs_seed(mode : String) -> Unit {
  board_create_refused.val = ""
  board_prefs.clear()
  for k in ["boardViews", "boardGroups", "boardShowEmpty", "boardDrafts"] {
    board_prefs[k] = Map([])
  }
  guard board_mode(mode) && mode != "board-list" else { return }
  if mode != "board-off" {
    board_prefs["boardViews"]["ws1"] = Json::string("board")
  }
  board_prefs["boardDrafts"]["ws1"] = [
    { "id": "new:board-seed-1", "title": "给导出加上按月份筛选", "station": "ws1/st1", "stationName": "Willow" },
    {
      "id": "new:board-seed-2",
      "title": "看一下 Android 冷启动为什么慢了 300ms",
      "station": "ws1/st2",
      "stationName": "Maple",
    },
  ]
}

///|
/// The board's prefs into the prefs' value `o`.
pub fn board_prefs_into(o : Map[String, Json]) -> Unit {
  for k, m in board_prefs {
    o[k] = Json::object(m)
  }
}

///|
/// The board's prefs as `prefs.set` puts them (`params`): each workspace's entry replaced, null (or no drafts) letting
/// it go.
pub fn board_prefs_set(params : Json) -> Unit {
  for k in ["boardViews", "boardGroups", "boardShowEmpty", "boardDrafts"] {
    match field(Some(params), k) {
      Some(Object(given)) => {
        let m = match board_prefs.get(k) {
          Some(m) => m
          None => {
            let m : Map[String, Json] = Map([])
            board_prefs[k] = m
            m
          }
        }
        for ws, v in given {
          match v {
            Null | Array([]) => m.remove(ws)
            _ => m[ws] = v
          }
        }
      }
      _ => ()
    }
  }
}

///|
/// Whether something was said in chat `session` since it was made up (a message sent, on its way, or a card answered):
/// its agent at work on it.
fn board_answered(session : String) -> Bool {
  let sent = match fix_chats.get(session) {
    Some(fc) => fc.sent.length() > 0 || fc.outbox.length() > 0
    None => false
  }
  sent || (session == "s-c1" && fix_decided.contains(8))
}

///|
/// The board's rows, as the core lists them (one day: today, then yesterday's).
pub fn board_days(f : Fixture) -> Array[Json] {
  let at_work = fn(id : String, title : String, station : String, ago : String, words : String, more : Map[String, Json]) {
    let m = more.copy()
    m["state"] = "run"
    m["stage"] = "run"
    m["tone"] = "busy"
    m["stateText"] = Json::string(words)
    m["stateLead"] = ""
    m["stateRest"] = Json::string(words)
    row(id, title, station, ago, m)
  }
  // (a chat that waited, answered here: at work on it)
  let waits = fn(id : String, title : String, station : String, ago : String, more : Map[String, Json], then : String) {
    if board_answered("s-" + id) {
      let m = more.copy()
      for k in ["decision", "stateLead", "stateLeadText", "stateRest", "stateText", "state", "tone", "stage"] {
        m.remove(k)
      }
      at_work(id, title, station, "刚刚", then, m)
    } else {
      row(id, title, station, ago, more)
    }
  }
  let claude = agent("anthropic", "claude")
  let codex = agent("openai", "codex")
  let gemini = agent("google", "gemini")
  let today : Array[Json] = board_started_rows.copy()
  today.append(
    [
      waits("c1", "整理发布清单", "ws1/st1", "6 分钟前", {
        "unread": true,
        "tone": "wait",
        "stage": "wait",
        "decision": { "seq": 8, "options": [], "text": "等 林 决定 · 要不要把旧的截图也一起换掉？" },
        "stateText": "等 林 决定 · 要不要把旧的截图也一起换掉？",
        "stateLead": "decision",
        "stateLeadText": "等 林 决定",
        "stateRest": " · 要不要把旧的截图也一起换掉？",
        "agents": [claude],
        "people": [me, ana],
        "creator": { "id": "lin@example.com", "name": "林", "via": "cloud" },
      }, "正在按你的决定更新截图与清单…"),
      waits("c3", "夜里的构建又失败了", "ws1/st2", "15 分钟前", {
        "state": "block",
        "tone": "wait",
        "stage": "wait",
        "stateText": "要你帮忙：测试机的磁盘满了，要不要清理旧的缓存？",
        "stateLead": "need",
        "stateRest": "测试机的磁盘满了，要不要清理旧的缓存？",
        "agents": [codex],
        "people": [me],
      }, "正在按你的回复清理缓存并重跑构建…"),
      waits("c9", "迁移数据库的演练", "ws1/st2", "32 分钟前", {
        "state": "failed",
        "tone": "alert",
        "stage": "wait",
        "stateText": "出错：演练到第二步时 Maple 连接中断",
        "agents": [claude],
        "people": [me, zhou],
      }, "正在从第二步重新演练…"),
      // (it leads another chat (chat_create for me), at work under it: said on its card, not a card of its own)
      at_work("c11", "首页的列表改成按天分组", "ws1/st1", "2 分钟前", "正在把分组标题换成相对日期，已改完 3 个文件", {
        "agents": [gemini],
        "people": [me, zhou],
        "pinned": true,
        "subchats": "1 个子会话进行中",
      }),
      row("c12", "接入飞书的审批通知", "ws1/st2", "9 分钟前", {
        "state": "run",
        "tone": "busy",
        "stage": "run",
        "stateText": "等 CI：第 3 项检查还在跑",
        "stateLead": "wait",
        "stateRest": "第 3 项检查还在跑",
        "connect": "feishu-1",
        "originKind": "feishu",
        "originText": "飞书 · 星火 · 审批群",
        "agents": [claude, codex],
        "people": [ana],
        "creator": { "id": "ana@example.com", "name": "Ana", "via": "cloud" },
      }),
      // (a card 周 decides: at work for the viewer, never theirs to answer)
      row("c13", "补一下部署文档", "ws1/st1", "12 分钟前", {
        "tone": "wait",
        "stage": "run",
        "decision": { "seq": 6, "options": [], "text": "等 周 决定 · 回滚写成脚本还是保留手动步骤？" },
        "stateText": "等 周 决定 · 回滚写成脚本还是保留手动步骤？",
        "stateLead": "decision",
        "stateLeadText": "等 周 决定",
        "stateRest": " · 回滚写成脚本还是保留手动步骤？",
        "agents": [codex],
        "people": [zhou],
        "creator": { "id": "zhou@example.com", "name": "周", "via": "cloud" },
      }),
    ],
  )
  let earlier = [
    // (read, and newer than the result not read under it: 待收口 puts the unread first all the same)
    row("c7", "Slack 里问的报销流程", "ws1/st2", "25 分钟前", {
      "tone": "done",
      "connect": "slack-1",
      "originKind": "slack",
      "originText": "Slack · 星火 · #行政",
      "stateText": "做完了：三个步骤整理成了一页文档",
      "stateLead": "done",
      "stateRest": "三个步骤整理成了一页文档",
      "agents": [claude],
      "people": [ana],
      "creator": { "id": "ana@example.com", "name": "Ana", "via": "cloud" },
    }),
    row("c4", "给设置页加一个深色模式开关", "ws1/st1", "40 分钟前", {
      "unread": true,
      "tone": "done",
      "stateText": "做完了：开关和三处颜色都改好了，已合进 main",
      "stateLead": "done",
      "stateRest": "开关和三处颜色都改好了，已合进 main",
      "agents": [codex],
      "people": [me],
    }),
    row("c8", "把旧的截图都换成新的", "ws1/st1", "昨天 10:30", {
      "settled": true,
      "stateText": "做完了：首页和聊天页的 12 张截图都换了",
      "stateLead": "done",
      "stateRest": "首页和聊天页的 12 张截图都换了",
      "agents": [gemini],
      "people": [me, ana],
    }),
    // (its watch woke it: at work for a moment, watching all the same)
    row("c5", "盯着 CI，绿了告诉我", "ws1/st2", "1 小时前", {
      "state": "run",
      "tone": "busy",
      "stage": "watch",
      "stateText": "正在巡检：主干构建刚刚变绿",
      "stateLead": "",
      "stateRest": "正在巡检：主干构建刚刚变绿",
      "watch": { "text": "监控中：主干构建", "ask": "「主干构建」仍在监控。归档会停止监控。" },
      "agents": [claude],
      "people": [me],
    }),
  ]
  [
    { "daysAgo": 0, "at": 0, "label": "今天", "items": kept(f, today) },
    { "daysAgo": 1, "at": 0, "label": "昨天", "items": kept(f, earlier) },
  ]
}

///|
/// Chat `session` of the board's (board_days'), what was said in it: the first row's the rich chat's up to its
/// decision; the others what was asked, how it went, where it stands.
pub fn board_chat(f : Fixture, session : String) -> Json {
  if session == "s-c1" {
    match rich_chat(0) {
      Object(m) => {
        let o = m.copy()
        o["messages"] = Json::array(
          items(Some(Json::object(m)), "messages")
          .filter(fn(x) { number(Some(x), "seq") <= 8.0 })
          // (its words alone: no picture to hand over beside the board)
          .map(fn(x) {
            match x {
              Object(xm) => {
                let y = xm.copy()
                y["attachments"] = []
                y.remove("placed")
                if number(Some(x), "seq") == 5.0 {
                  y["text"] = "列表改好了：几千条消息也能顺滑地滚，首页和聊天页都换成了虚拟列表。"
                }
                Json::object(y)
              }
              _ => x
            }
          }),
        )
        o["asks"] = [{ "seq": 8 }]
        return Json::object(o)
      }
      v => return v
    }
  }
  let mut title = ""
  for d in board_days(f) {
    for r in items(Some(d), "items") {
      if text(Some(r), "session") == session {
        title = text(Some(r), "title")
      }
    }
  }
  let (runtime, maker) = match session {
    "s-c3" | "s-c4" | "s-c13" => ("codex", "openai")
    "s-c11" | "s-c8" => ("gemini", "google")
    _ => ("claude", "anthropic")
  }
  let by = by_agent(maker, runtime, session)
  let said : Array[(String, String)] = match session {
    "s-c3" => [("person", "夜里的构建又失败了，帮我看看是什么原因。"), ("agent", "看了日志：是测试机的磁盘满了，`/var/cache/build` 占了 41 GB。"), ("agent", "要不要清理旧的缓存？清掉后重跑一次构建。")]
    "s-c9" => [("person", "在 Maple 上演练一下数据库迁移，先别动线上。"), ("agent", "第一步：导出快照，完成。"), ("agent", "第二步执行到一半时 Maple 连接中断了，迁移脚本没有写入任何数据。")]
    "s-c11" => [("person", "首页的列表改成按天分组，标题用相对日期。"), ("agent", "好的。已经改完 `list/days.mbt`、`list/heading.mbt` 和 `home.mbt`，正在跑截图对比。")]
    "s-c12" => [("person", "审批群里有新审批时，通知一下对应的人。"), ("agent", "接好了飞书的审批事件，正在等 CI：第 3 项检查还在跑。")]
    "s-c13" => [("person", "补一下部署文档，尤其是回滚。"), ("agent", "前三节写完了，正在补第四节：回滚的步骤。")]
    "s-c4" => [("person", "给设置页加一个深色模式开关。"), ("agent", "做完了：开关和三处颜色都改好了，已合进 main（a3f9c21）。")]
    "s-c7" => [("person", "报销流程是怎样的？"), ("agent", "做完了：三个步骤整理成了一页文档，放在共享盘的「行政」里。")]
    "s-c8" => [("person", "把旧的截图都换成新的。"), ("agent", "做完了：首页和聊天页的 12 张截图都换了。")]
    "s-c5" => [("person", "盯着 CI，绿了告诉我。"), ("agent", "好，每 5 分钟看一次主干的构建，绿了就告诉你。")]
    _ => [("person", title), ("agent", "好的，我来处理。")]
  }
  let messages = said.mapi(fn(i, s) {
    if s.0 == "person" {
      msg(i + 1, "person", by_person("林"), s.1, "1 小时前", { "mine": true, "author": "lin@example.com" })
    } else {
      msg(i + 1, "agent", by, s.1, "30 分钟前", {})
    }
  })
  match small_chat(title, session) {
    Object(m) => {
      let o = m.copy()
      o["messages"] = Json::array(messages)
      o["people"] = [me]
      Json::object(o)
    }
    v => v
  }
}

///|
/// The board's chats made and started (a key `new:board-…`, as the board makes them): `newChat.create` a pending row
/// under the key (as the core's local rows: titled 新对话), `chat.send` its words sent, at work at once (the station's
/// row, its key kept); None for any other call.
pub fn fixture_board_call(f : Fixture, name : String, params : Json) -> Result[Json, Json]? {
  let p = Some(params)
  match name {
    "newChat.create" if text(p, "key").has_prefix("new:board-") && board_create_refused.val != "" =>
      Some(Err({ "code": "unavailable", "message": Json::string(board_create_refused.val) }))
    "newChat.create" if text(p, "key").has_prefix("new:board-") => {
      let key = text(p, "key")
      let station = text(p, "station")
      board_started_rows.retain(fn(r) { text(Some(r), "clientKey") != key })
      board_started_rows.insert(
        0,
        row(key, "新对话", station, "刚刚", {
          "state": "",
          "stage": "run",
          "pending": true,
          "clientKey": Json::string(key),
          "agents": [],
          "people": [me],
        }),
      )
      f.changed()
      Some(Ok({ "key": Json::string(key) }))
    }
    "chat.send" if text(p, "session").has_prefix("new:board-") => {
      let key = text(p, "session")
      let station = text(p, "station")
      let n = board_started_rows.length()
      board_started_rows.retain(fn(r) { text(Some(r), "clientKey") != key })
      board_started_rows.insert(
        0,
        row("cb\{n}", text(p, "text"), station, "刚刚", {
          "state": "run",
          "stage": "run",
          "tone": "busy",
          "stateText": "正在读取仓库与分析改动点…",
          "stateLead": "",
          "stateRest": "正在读取仓库与分析改动点…",
          "clientKey": Json::string(key),
          "agents": [agent("anthropic", "claude")],
          "people": [me],
        }),
      )
      f.changed()
      Some(Ok(Json::object({})))
    }
    _ => None
  }
}

///|
/// The board's 待处理 (the core's `workspaceMarks`), as the core lists it of the board's chats (client/core-ts
/// views/marks.ts): what waits for the viewer read or not (整理发布清单's decision, unread; 夜里的构建又失败了's need,
/// read), what went wrong for them, then what is unread (给设置页加一个深色模式开关).
pub fn board_marks() -> Json {
  let item = fn(kind : String, session : String, title : String, text : String, what : String, station : String, at : Double) {
    let m : Map[String, Json] = {
      "kind": Json::string(kind),
      "workspace": "ws1",
      "station": Json::string(station),
      "stationName": Json::string(if station == "ws1/st1" { "Willow" } else { "Maple" }),
      "session": Json::string("s-" + session),
      "thread": Json::number(session.length().to_double()),
      "title": Json::string(title),
      "text": Json::string(text),
      "what": Json::string(what),
      "at": Json::number(at),
    }
    m
  }
  let c1 = item("wait", "c1", "整理发布清单", "等 林 决定 · 要不要把旧的截图也一起换掉？", "要不要把旧的截图也一起换掉？", "ws1/st1", 6.0)
  c1["seq"] = Json::number(8.0)
  let c3 = item("wait", "c3", "夜里的构建又失败了", "要你帮忙：测试机的磁盘满了，要不要清理旧的缓存？", "测试机的磁盘满了，要不要清理旧的缓存？", "ws1/st2", 5.0)
  let c9 = item("alert", "c9", "迁移数据库的演练", "出错：演练到第二步时 Maple 连接中断", "演练到第二步时 Maple 连接中断", "ws1/st2", 4.0)
  c9["failure"] = "ws1/st2/c9@4"
  let c4 = item("done", "c4", "给设置页加一个深色模式开关", "做完了：开关和三处颜色都改好了，已合进 main", "开关和三处颜色都改好了，已合进 main", "ws1/st1", 3.0)
  c4["seq"] = Json::number(4.0)
  {
    "workspaces": {
      "ws1": {
        "workspaceName": "星火工作室",
        "alert": 1,
        "wait": 2,
        "unread": 1,
        "tone": "alert",
        "label": "1 个出错 · 2 个待你处理 · 1 个有新消息",
        "badge": 4,
        "items": [Json::object(c9), Json::object(c1), Json::object(c3), Json::object(c4)],
      },
    },
    "badge": 4,
    "badgeKinds": { "on": true, "wait": true, "failed": true, "done": true, "message": true, "services": true },
  }
}
