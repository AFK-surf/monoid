// Bilingual (English / Chinese) website showcase fixtures for monoid.build:
// - chat-site-duo: iPhone chat (Login page on phones)
// - chat-site-android: Android phone chat (Login page on phones, virtual screen test)
// - chat-site-web: Web browser chat (CSV export for orders, Markdown table + code)
// - settings-station-site: Desktop station overview (Willow / Mini / Laptop / Server)
// Kept separate from test fixtures so existing snapshots and checks stay unchanged.

///|
fn site_mode(mode : String) -> Bool {
  mode == "chat-site-duo" ||
  mode == "chat-site-android" ||
  mode == "chat-site-web" ||
  mode == "settings-station-site" ||
  mode == "place-stations-site"
}

///|
fn site_chat_mode(mode : String) -> Bool {
  mode == "chat-site-duo" || mode == "chat-site-android" || mode == "chat-site-web"
}

///|
fn site_person(id : String, name : String, mine : Bool, en : Bool) -> Json {
  {
    "id": Json::string(id),
    "name": Json::string(name),
    "email": Json::string(id),
    "via": "cloud",
    "shown": {
      "name": Json::string(name),
      "display": Json::string(if mine { if en { "You" } else { "你" } } else { name }),
      "mine": Json::boolean(mine),
    },
  }
}

///|
fn site_by_agent(name : String, maker : String, runtime : String, key : String) -> Json {
  {
    "name": Json::string(name),
    "agent": Json::string(key),
    "maker": { "id": Json::string(maker), "name": Json::string(maker) },
    "runtime": Json::string(runtime),
  }
}

///|
fn site_days(mode : String) -> Array[Json] {
  let en = @sf.language() == "en"
  let lin = site_person("lin@acme.dev", if en { "Lin Xiao" } else { "林晓" }, true, en)
  let zhou = site_person("zhou@acme.dev", if en { "Zhou Ning" } else { "周宁" }, false, en)
  let ana = site_person("ana@acme.dev", "Ana", false, en)
  let is_web = mode == "chat-site-web"
  [
    {
      "label": Json::string(if en { "Today" } else { "今天" }),
      "items": [
        row(
          "c1",
          if en { "Login page on phones" } else { "手机上的登录页" },
          "ws1/st1",
          if en { "6m" } else { "6 分钟前" },
          {
            "state": "run",
            "tone": "busy",
            "unread": Json::boolean(is_web),
            "last": last(
              if en {
                "The login button was fixed at 320px wide on phones, wider than the screen."
              } else {
                "登录按钮在手机上写死了 320px 宽，超出了屏幕。"
              },
            ),
            "agents": [agent("anthropic", "claude")],
            "people": [lin, zhou],
            "creator": { "id": "lin@acme.dev", "name": if en { "Lin Xiao" } else { "林晓" }, "via": "cloud" },
          },
        ),
        row(
          "c2",
          if en { "CSV export for orders" } else { "订单导出支持 CSV" },
          "ws1/st1",
          if en { "3m" } else { "3 分钟前" },
          {
            "unread": Json::boolean(!is_web),
            "tone": "done",
            "stateText": Json::string(
              if en {
                "Done: streams rows by current filters, merged into main"
              } else {
                "做完了：按当前筛选流式写出，已合进 main"
              },
            ),
            "stateLead": "done",
            "stateRest": Json::string(
              if en {
                "the export streams rows by current filters…"
              } else {
                "按当前筛选流式写出，10 万行约 2.3 秒…"
              },
            ),
            "agents": [agent("openai", "codex")],
            "people": [lin],
          },
        ),
        row(
          "c3",
          if en { "Weekly dependency updates" } else { "每周依赖升级" },
          "ws1/st2",
          if en { "58m" } else { "58 分钟前" },
          {
            "state": "block",
            "tone": "wait",
            "unread": true,
            "stateText": Json::string(
              if en {
                "Needs input: the other 23 packages are updated, upgrade Router 8?"
              } else {
                "待决定：其余 23 个包都升好了，本周一起升 Router 8 吗？"
              },
            ),
            "stateLead": "need",
            "stateRest": Json::string(
              if en {
                "The other 23 packages are updated…"
              } else {
                "其余 23 个包都升好了，测试通过…"
              },
            ),
            "agents": [agent("anthropic", "claude")],
            "people": [zhou],
          },
        ),
        row(
          "c4",
          if en { "Why API p99 got slow" } else { "排查 API p99 变慢" },
          "ws1/st1",
          if en { "2h" } else { "2 小时前" },
          {
            "tone": "done",
            "stateText": Json::string(
              if en {
                "Done: added composite index on orders(user_id, created_at)"
              } else {
                "做完了：已给 orders 补上联合索引，p99 回到 140ms"
              },
            ),
            "stateLead": "done",
            "stateRest": Json::string(
              if en {
                "added composite index on orders…"
              } else {
                "已补上联合索引，p99 回到 140ms"
              },
            ),
            "agents": [agent("deepseek", "dsh")],
            "people": [lin, ana],
          },
        ),
      ],
    },
    {
      "label": Json::string(if en { "Yesterday" } else { "昨天" }),
      "items": [
        row(
          "c5",
          if en { "Release checklist" } else { "整理发布清单" },
          "ws1/st1",
          if en { "1d" } else { "昨天" },
          {
            "last": last(if en { "Signed builds verified across macOS and Android." } else { "macOS 和 Android 安装包签名均已核对。" }),
            "agents": [agent("anthropic", "claude")],
            "people": [ana],
          },
        ),
        row(
          "c6",
          if en { "Duplicate push notifications" } else { "推送通知重复" },
          "ws1/st2",
          if en { "1d" } else { "昨天" },
          {
            "last": last(
              if en {
                "Deduplicated by message id on the device; two days without a repeat."
              } else {
                "改成在设备端按消息 id 去重，观察两天没再重复。"
              },
            ),
            "agents": [agent("openai", "codex")],
            "people": [zhou],
          },
        ),
        row(
          "c7",
          if en { "Home page first paint" } else { "首页首屏加载" },
          "ws1/st1",
          if en { "1d" } else { "昨天" },
          {
            "last": last(
              if en {
                "Inlined critical CSS and deferred the charts: LCP 2.4 s → 1.1 s."
              } else {
                "关键 CSS 内联、图表延后加载，LCP 从 2.4 秒降到 1.1 秒。"
              },
            ),
            "agents": [agent("anthropic", "claude")],
            "people": [lin, ana],
          },
        ),
      ],
    },
  ]
}

///|
fn site_md_json(raw : String) -> Json {
  @json.parse(raw) catch { _ => Json::null() }
}

///|
let site_web_answer_en : String =
  #|Done — switched the orders export to chunked streaming and merged into `main` (`a3f9c21`).
  #|
  #|| Approach | 100k rows | Peak RAM | Result |
  #|| :-- | --: | --: | :-: |
  #|| Full buffer | 6.8 s | 412 MB | OOM risk |
  #|| Batched cursor | 3.1 s | 64 MB | Okay |
  #|| Streamed rows | 2.3 s | 14 MB | Shipped |
  #|
  #|```ts
  #|export async function* streamOrdersCsv(filter: OrderFilter) {
  #|  yield 'id,customer,total,created_at\n'
  #|  for await (const row of db.orders.iterate(filter)) {
  #|    yield `${row.id},${csv(row.customer)},${row.total},${row.createdAt}\n`
  #|  }
  #|}
  #|```

///|
let site_web_md_en : String =
  #|[["p",[[0,71],["code",{"content":[72,76]}],[77,79],["code",{"content":[80,87]}],[88,90]]],["table",[["tr",[["th",[[94,102]]],["th",[[105,114]]],["th",[[117,125]]],["th",[[128,134]]]]],["tr",[["td",[[165,176]]],["td",[[179,184]]],["td",[[187,193]]],["td",[[196,204]]]]],["tr",[["td",[[209,223]]],["td",[[226,231]]],["td",[[234,239]]],["td",[[242,246]]]]],["tr",[["td",[[251,264]]],["td",[[267,272]]],["td",[[275,280]]],["td",[[283,290]]]]]],{"align":["left","right","right","center"],"md":"| Approach | 100k rows | Peak RAM | Result |\n| :-- | --: | --: | :-: |\n| Full buffer | 6.8 s | 412 MB | OOM risk |\n| Batched cursor | 3.1 s | 64 MB | Okay |\n| Streamed rows | 2.3 s | 14 MB | Shipped |","csv":"Approach,100k rows,Peak RAM,Result\nFull buffer,6.8 s,412 MB,OOM risk\nBatched cursor,3.1 s,64 MB,Okay\nStreamed rows,2.3 s,14 MB,Shipped"}],["pre",{"code":[300,538],"lang":"ts","ink":"g7h16i15cj6c2l11c6g6ed30e4g10ch6j4g3j2cj6ci7cj6c9g6ed62e4c3"}]]

///|
let site_web_answer_zh : String =
  #|做好了：订单导出已按当前筛选条件改成流式写出，合进 `main`（`a3f9c21`）。
  #|
  #|| 方案 | 10 万行耗时 | 峰值内存 | 结论 |
  #|| :-- | --: | --: | :-: |
  #|| 全量缓冲 | 6.8 s | 412 MB | 易 OOM |
  #|| 分批游标 | 3.1 s | 64 MB | 可用 |
  #|| 流式写出 | 2.3 s | 14 MB | 采用 |
  #|
  #|```ts
  #|export async function* streamOrdersCsv(filter: OrderFilter) {
  #|  yield 'id,customer,total,created_at\n'
  #|  for await (const row of db.orders.iterate(filter)) {
  #|    yield `${row.id},${csv(row.customer)},${row.total},${row.createdAt}\n`
  #|  }
  #|}
  #|```

///|
let site_web_md_zh : String =
  #|[["p",[[0,26],["code",{"content":[27,31]}],[32,33],["code",{"content":[34,41]}],[42,44]]],["table",[["tr",[["th",[[48,50]]],["th",[[53,60]]],["th",[[63,67]]],["th",[[70,72]]]]],["tr",[["td",[[103,107]]],["td",[[110,115]]],["td",[[118,124]]],["td",[[127,132]]]]],["tr",[["td",[[137,141]]],["td",[[144,149]]],["td",[[152,157]]],["td",[[160,162]]]]],["tr",[["td",[[167,171]]],["td",[[174,179]]],["td",[[182,187]]],["td",[[190,192]]]]]],{"align":["left","right","right","center"],"md":"| 方案 | 10 万行耗时 | 峰值内存 | 结论 |\n| :-- | --: | --: | :-: |\n| 全量缓冲 | 6.8 s | 412 MB | 易 OOM |\n| 分批游标 | 3.1 s | 64 MB | 可用 |\n| 流式写出 | 2.3 s | 14 MB | 采用 |","csv":"方案,10 万行耗时,峰值内存,结论\n全量缓冲,6.8 s,412 MB,易 OOM\n分批游标,3.1 s,64 MB,可用\n流式写出,2.3 s,14 MB,采用"}],["pre",{"code":[202,440],"lang":"ts","ink":"g7h16i15cj6c2l11c6g6ed30e4g10ch6j4g3j2cj6ci7cj6c9g6ed62e4c3"}]]

///|
let site_duo_reply_en : String =
  #|The login button was fixed at 320px wide on phones, wider than the screen.
  #|
  #|- It now fills its container; checked in a screenshot at 375px, it fits
  #|- Branch `fix/login-button`

///|
let site_duo_md_en : String =
  #|[["p",[[0,74]]],["list",[["li",[[78,147]]],["li",[[150,157],["code",{"content":[158,174]}]]]]]]

///|
let site_duo_reply_zh : String =
  #|登录按钮在手机上写死了 320px 宽，超出了屏幕。
  #|
  #|- 已改为自适应容器宽度，375px 宽截图核对通过
  #|- 分支 `fix/login-button`

///|
let site_duo_md_zh : String =
  #|[["p",[[0,26]]],["list",[["li",[[30,54]]],["li",[[57,60],["code",{"content":[61,77]}]]]]]]

///|
let site_and_md_en : String =
  #|[["p",[[0,11],["code",{"content":[12,25]}],[26,43],["code",{"content":[44,60]}],[61,71],["code",{"content":[72,76]}],[77,124]]]]

///|
let site_and_md_zh : String =
  #|[["p",[[0,5],["code",{"content":[6,19]}],[20,24],["code",{"content":[25,29]}],[30,42],["code",{"content":[43,59]}],[60,79]]]]

///|
fn site_chat(mode : String) -> Json {
  let en = @sf.language() == "en"
  let lin = site_person("lin@acme.dev", if en { "Lin Xiao" } else { "林晓" }, true, en)
  let zhou = site_person("zhou@acme.dev", if en { "Zhou Ning" } else { "周宁" }, false, en)
  if mode == "chat-site-web" {
    let codex = site_by_agent("Codex", "openai", "codex", "s-c2")
    let answer = if en { site_web_answer_en } else { site_web_answer_zh }
    let ask_text = if en {
      "Add a CSV export to the orders list and compare streaming vs buffered memory usage."
    } else {
      "给订单列表加上 CSV 导出，顺便对比流式和全量缓冲的内存占用。"
    }
    let web_more : Map[String, Json] = {
      "ending": "all_done",
      "md": site_md_json(if en { site_web_md_en } else { site_web_md_zh }),
    }
    let plain : Map[String, Json] = Map([])
    let look_text = if en {
      "The current export reads the whole result into memory before writing it, so 100k orders peak above 400 MB. I'll try three ways and compare time and memory."
    } else {
      "看了现在的导出：先把整页结果读进内存再拼成 CSV，10 万条订单时内存峰值超过 400 MB。我按三种写法各跑一遍，对比耗时和内存。"
    }
    let keep_text = if en {
      "Keep it the same as the list: same filters, same sort order."
    } else {
      "导出结果要跟列表页一致，筛选条件和排序都别变。"
    }
    let kept_text = if en {
      "Done: the export takes the list's filter and sort as they are, so it matches what's on screen row for row."
    } else {
      "好的，导出直接复用列表页的筛选和排序，和页面上看到的逐行一致。"
    }
    let messages : Array[Json] = [
      msg(1, "person", by_person(if en { "Lin Xiao" } else { "林晓" }), ask_text, if en { "26 min ago" } else { "26 分钟前" }, {
        "mine": true,
        "author": "lin@acme.dev",
      }),
      msg(2, "agent", codex, look_text, if en { "24 min ago" } else { "24 分钟前" }, plain),
      msg(3, "person", by_person(if en { "Lin Xiao" } else { "林晓" }), keep_text, if en { "18 min ago" } else { "18 分钟前" }, {
        "mine": true,
        "author": "lin@acme.dev",
      }),
      msg(4, "agent", codex, kept_text, if en { "15 min ago" } else { "15 分钟前" }, plain),
      msg(5, "agent", codex, answer, if en { "3 min ago" } else { "3 分钟前" }, web_more),
    ]
    return {
      "archived": false,
      "me": { "email": "lin@acme.dev" },
      "thread": { "id": 2, "unread": 0 },
      "title": Json::string(if en { "CSV export for orders" } else { "订单导出支持 CSV" }),
      "people": [lin],
      "agents": [
        {
          "session": {
            "key": "s-c2",
            "runtime": "codex",
            "maker": { "id": "openai", "name": "OpenAI" },
            "agentText": "Codex",
            "statusText": Json::string(if en { "Idle" } else { "空闲" }),
            "tone": "neutral",
          },
          "status": "idle",
        },
      ],
      "messages": Json::array(messages),
      "more": false,
      "newer": false,
      "outbox": [],
      "offline": false,
      "archivable": true,
      "asks": [],
      "askClear": true,
    }
  }
  // chat-site-duo & chat-site-android: Login page on phones
  let claude = site_by_agent("Opus 5.5", "anthropic", "claude", "s-c1")
  let is_android = mode == "chat-site-android"
  let ask_text = if en {
    "The login page looks wrong on phones, can you fix it?"
  } else {
    "手机上的登录页样式不对，能修一下吗？"
  }
  let reply_text = if is_android {
    if en {
      "The login button was fixed at 320px wide on phones, wider than the screen. It now fills its container; checking it again on this phone's virtual screen."
    } else {
      "登录按钮在手机上写死了 320px 宽，超出了屏幕。已改为自适应容器宽度，正在这台手机的虚拟屏上复测。"
    }
  } else if en {
    site_duo_reply_en
  } else {
    site_duo_reply_zh
  }
  let messages : Array[Json] = {
    let shot_text = if en {
      "Took screenshots at 375, 390 and 430 px wide: at 375 px the sign-in button runs 24 px past the right edge; the other two look right."
    } else {
      "先在 375、390、430 三个宽度下各截了一张图：375 宽时登录按钮右边超出屏幕 24px，另外两个宽度正常。"
    }
    let first_reply = if en {
      "Found it — `.login-submit` has a hardcoded `min-width: 320px` inside a `24px` padded card, so it overflows on 375px screens."
    } else {
      "定位到了：`.login-submit` 在带 `24px` 内边距的卡片里写死了 `min-width: 320px`，375px 宽的小屏会直接撑出边界。"
    }
    let first_more : Map[String, Json] = {
      "md": site_md_json(if en { site_and_md_en } else { site_and_md_zh }),
    }
    let followup = if en {
      "Check dark mode too — Zhou Ning saw low contrast on the secondary link."
    } else {
      "深色模式也顺手看一下，周宁说次要链接对比度偏低。"
    }
    let reply_more : Map[String, Json] = if is_android {
      Map([])
    } else {
      { "md": site_md_json(if en { site_duo_md_en } else { site_duo_md_zh }) }
    }
    [
      msg(1, "person", by_person(if en { "Lin Xiao" } else { "林晓" }), ask_text, if en { "14 min ago" } else { "14 分钟前" }, {
        "mine": true,
        "author": "lin@acme.dev",
      }),
      msg(2, "agent", claude, shot_text, if en { "13 min ago" } else { "13 分钟前" }, Map([])),
      msg(3, "agent", claude, first_reply, if en { "11 min ago" } else { "11 分钟前" }, first_more),
      msg(4, "person", by_person(if en { "Lin Xiao" } else { "林晓" }), followup, if en { "8 min ago" } else { "8 分钟前" }, {
        "mine": true,
        "author": "lin@acme.dev",
      }),
      msg(5, "agent", claude, reply_text, if en { "6 min ago" } else { "6 分钟前" }, reply_more),
    ]
  }
  {
    "archived": false,
    "me": { "email": "lin@acme.dev" },
    "thread": { "id": 1, "unread": 0 },
    "title": Json::string(if en { "Login page on phones" } else { "手机上的登录页" }),
    "people": [lin, zhou],
    "agents": [
      {
        "session": {
          "key": "s-c1",
          "runtime": "claude",
          "maker": { "id": "anthropic", "name": "Anthropic" },
          "agentText": "Opus 5.5",
          "statusText": Json::string(if en { "Working" } else { "正在工作" }),
          "tone": "accent",
        },
        "status": "running",
        "since": -12000.0,
      },
    ],
    "messages": Json::array(messages),
    "more": false,
    "newer": false,
    "outbox": [],
    "offline": false,
    "archivable": true,
    "asks": [],
    "askClear": true,
  }
}

///|
fn site_live_activity(mode : String) -> Json? {
  let en = @sf.language() == "en"
  match mode {
    "chat-site-duo" =>
      Some({
        "loaded": true,
        "activity": {
          "now": {
            "key": "call:site-duo",
            "text": Json::string(if en { "Running pnpm test login" } else { "正在运行 pnpm test login" }),
            "important": false,
          },
        },
      })
    "chat-site-android" =>
      Some({
        "loaded": true,
        "activity": {
          "now": {
            "key": "call:site-android",
            "text": Json::string(if en { "Screenshot: login page at 375px" } else { "截图：375px 宽的登录页" }),
            "important": false,
          },
        },
      })
    _ => None
  }
}
