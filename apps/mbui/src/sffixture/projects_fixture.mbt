// Isolated test fixture for PR 3 Chat Classification System (`projects`, `tags`, `project`,
// `chats` grouped/filtered, `chat` proposal/classification, and all 6 classification commands).
// Strictly gated behind `fx_projects_on` (default false, reset in `fixture_reset`) so existing
// baseline scenes and snapshots are 100% untouched.

///|
/// Opt-in switch for chat classification fixture data. Default `false`; reset to `false` in `fixture_reset()`.
// kept across runs: reset by fx_projects_reset (made.mbt fixture_reset)
pub let fx_projects_on : Ref[Bool] = Ref(false)

///|
/// Toggle whether the workspace is writable in `fx_projects_on` mode (default `true`; set `false` for viewer/offline tests).
// kept across runs: reset by fx_projects_reset (made.mbt fixture_reset)
pub let fx_projects_writable : Ref[Bool] = Ref(true)

///|
// kept across runs: cleared by fx_projects_reset (made.mbt fixture_reset)
let fx_list_groups : Map[String, String] = Map([])

///|
// kept across runs: cleared by fx_projects_reset (made.mbt fixture_reset)
let fx_group_collapsed : Map[String, String] = Map([])

///|
// kept across runs: cleared by fx_projects_reset (made.mbt fixture_reset)
let fx_chat_project : Map[String, String?] = Map([])

///|
// kept across runs: cleared by fx_projects_reset (made.mbt fixture_reset)
let fx_chat_locked : Map[String, Bool] = Map([])

///|
// kept across runs: cleared by fx_projects_reset (made.mbt fixture_reset)
let fx_chat_tags : Map[String, Array[String]] = Map([])

///|
// kept across runs: cleared by fx_projects_reset (made.mbt fixture_reset)
let fx_proposal_state : Map[String, (String, String?)] = Map([])

///|
// kept across runs: cleared by fx_projects_reset (made.mbt fixture_reset)
let fx_project_notes : Map[String, (String, Array[String], String)] = Map([])

///|
// kept across runs: cleared by fx_projects_reset (made.mbt fixture_reset)
let fx_preset_projects : Map[String, String] = Map([])

///|
/// Pre-seed list grouping mode for isolated `projects-*` fixture scenes.
pub fn fx_set_list_group(scope : String, group : String) -> Unit {
  if group == "project" {
    fx_list_groups[scope] = "project"
  } else {
    fx_list_groups.remove(scope)
  }
}

///|
/// Pre-seed persisted group collapse JSON for isolated `projects-*` fixture scenes and restart tests.
pub fn fx_set_group_collapsed(scope : String, raw : String) -> Unit {
  if raw != "" {
    fx_group_collapsed[scope] = raw
  } else {
    fx_group_collapsed.remove(scope)
  }
}

///|
/// Reset all isolated classification fixture state. Called by `fixture_reset()`.
pub fn fx_projects_reset() -> Unit {
  fx_projects_on.val = false
  fx_projects_writable.val = true
  fx_list_groups.clear()
  fx_group_collapsed.clear()
  fx_chat_project.clear()
  fx_chat_locked.clear()
  fx_chat_tags.clear()
  fx_proposal_state.clear()
  fx_project_notes.clear()
  fx_preset_projects.clear()
}

///|
/// 80-char stress project name for layout & truncation tests.
pub let fx_stress_project_80 : String = "monoid-cross-platform-chat-classification-ui-architecture-long-project-name-80ch"

///|
/// 48-char stress tag name for chip truncation tests.
pub let fx_stress_tag_48 : String = "very-long-reusable-classification-tag-name-48chr"

///|
fn fx_list_groups_json() -> Json {
  let m : Map[String, Json] = Map([])
  for k, v in fx_list_groups {
    m[k] = Json::string(v)
  }
  Json::object(m)
}

///|
fn fx_group_collapsed_json() -> Json {
  let m : Map[String, Json] = Map([])
  for k, v in fx_group_collapsed {
    m[k] = Json::string(v)
  }
  Json::object(m)
}

///|
fn fx_apply_prefs_list_groups(params : Json) -> Unit {
  match field(Some(params), "listGroups") {
    Some(Object(m)) =>
      for k, v in m {
        match v {
          String("project") => fx_list_groups[k] = "project"
          Null => fx_list_groups.remove(k)
          _ => ()
        }
      }
    _ => ()
  }
  match field(Some(params), "groupCollapsed") {
    Some(Object(m)) =>
      for k, v in m {
        match v {
          String(s) if s != "" => fx_group_collapsed[k] = s
          Null | String("") => fx_group_collapsed.remove(k)
          _ => ()
        }
      }
    _ => ()
  }
}

///|
/// Build synthetic 8-group dataset for `projects-sticky` (with active lower groups) and
/// `projects-sticky-quiet` (all quiet), strictly isolated behind `fx_projects_on`.
fn fx_sticky_days(quiet : Bool) -> Array[Json] {
  let specs : Array[(String, String, Array[(String, String, String, Bool)])] = [
    (
      "",
      "今天",
      [
        ("整理本周迭代排期", "已同步各方结论", "", false),
        ("复盘线上告警收敛", "误报率下降 60%", "", false),
        ("梳理测试机资源清单", "已更新到共享表", "", false),
      ],
    ),
    (
      "alpha-api",
      "今天",
      [
        ("网关限流策略评审", "按租户令牌桶分档", "", false),
        ("清理废弃的 v1 接口", "确认无外部调用方", "", false),
        ("补齐 OpenAPI 校验", "已覆盖全部 POST 路由", "", false),
        ("优化批量查询 SQL", "P99 降到 12ms", "", false),
      ],
    ),
    (
      "board",
      "今天",
      [
        ("看板列拖拽排序微调", "跟手阻尼已对齐设计稿", "", false),
        ("筛选栏支持多标签组合", "单测全部通过", "", false),
        ("补齐卡片快捷键说明", "已补充到帮助面板", "", false),
        ("排查长标题截断高度", "1.3x 字号下无溢出", "", false),
      ],
    ),
    (
      "design-system",
      "昨天",
      [
        ("统一浮层圆角与描边", "全部切到 control_edge", "", false),
        ("暗色主题对比度核对", "满足 AA 级对比度", "", false),
        ("液态玻璃胶囊参数校准", "高光折射已调顺", "", false),
        ("整理图标库缺失矢量", "补齐 4 个方向箭头", "", false),
      ],
    ),
    (
      "infra-ops",
      "昨天",
      [
        ("升级构建节点缓存策略", "冷启动缩至 20 秒", "", false),
        ("排查东京站磁盘占用", "已释放 48 GB 旧镜像", "", false),
        ("证书自动续期演练", "预演脚本零报错", "", false),
        ("日志归档压缩比验证", "zstd 级别调至 6", "", false),
      ],
    ),
    (
      "mobile-shell",
      "昨天",
      [
        (
          "重构小屏底栏回落动画",
          "正在运行 120fps 轨迹回归",
          if quiet { "" } else { "run" },
          false,
        ),
        ("适配折叠屏半开态高度", "已核对安全区边距", "", false),
        ("修复软键盘弹起遮挡", "底部胶囊自动退让", "", false),
        ("手势返回边缘热区微调", "与列表滑动无冲突", "", false),
      ],
    ),
    (
      "monoid",
      "本周",
      [
        (
          "分组吸顶交互细节确认",
          "需要确认底部胶囊文案口径",
          if quiet { "" } else { "block" },
          !quiet,
        ),
        ("虚拟列表增量无障碍校验", "全量与增量结果一致", "", false),
        ("收起分组原地锚定测试", "4 档帧率全部绿灯", "", false),
        ("清理平铺模式冗余绑定", "节点数保持零增长", "", false),
      ],
    ),
    (
      "release-qa",
      "本周",
      [
        (
          "发布前夜间回归失败排查",
          "发现一处签名证书过期",
          if quiet { "" } else { "failed" },
          false,
        ),
        (
          "整理 Beta 1420 更新日志",
          "已完成中英文双语核对",
          if quiet { "" } else { "done" },
          !quiet,
        ),
        ("核对安卓安装包体积预算", "较上版减少 180 KB", "", false),
        ("全端离线缓存恢复验收", "冷启恢复耗时 < 80ms", "", false),
      ],
    ),
  ]
  let by_day : Map[String, Array[Json]] = Map([])
  let day_order : Array[String] = []
  let mut seq = 100
  for spec in specs {
    let (proj, day_lbl, chats) = spec
    let arr = match by_day.get(day_lbl) {
      Some(a) => a
      None => {
        let a : Array[Json] = []
        by_day[day_lbl] = a
        day_order.push(day_lbl)
        a
      }
    }
    for c in chats {
      let (title, summary, st, unread) = c
      seq += 1
      let extra : Map[String, Json] = {
        "last": last(summary),
      }
      if proj != "" {
        extra["project"] = Json::string(proj)
      }
      if unread {
        extra["unread"] = Json::boolean(true)
      }
      match st {
        "run" => {
          extra["state"] = Json::string("run")
          extra["tone"] = Json::string("busy")
        }
        "block" => {
          extra["state"] = Json::string("block")
          extra["tone"] = Json::string("wait")
          extra["stateLead"] = Json::string("need")
          extra["stateText"] = Json::string("要你帮忙：" + summary)
          extra["stateRest"] = Json::string(summary)
        }
        "failed" => {
          extra["state"] = Json::string("failed")
          extra["tone"] = Json::string("alert")
          extra["stateText"] = Json::string("出错了：" + summary)
          extra["stateRest"] = Json::string(summary)
        }
        "done" => {
          extra["tone"] = Json::string("done")
          extra["stateLead"] = Json::string("done")
          extra["stateText"] = Json::string("做完了：" + summary)
          extra["stateRest"] = Json::string(summary)
        }
        _ => ()
      }
      arr.push(row("sc" + seq.to_string(), title, "ws1/st1", "5 分钟前", extra))
    }
  }
  day_order.map(fn(lbl) {
    Json::object({
      "label": Json::string(lbl),
      "items": Json::array(by_day.get(lbl).unwrap_or([])),
    })
  })
}

///|
/// Decorate `chats` topic output when `fx_projects_on` is true; returns `v` untouched when false.
fn fx_decorate_chats(v : Json, params : Map[String, Json], mode? : String = "") -> Json {
  if !fx_projects_on.val {
    return v
  }
  guard v is Object(m) else { return v }
  let out = m.copy()
  out["projects"] = Json::boolean(true)
  if fx_projects_writable.val {
    out["projectsWritable"] = Json::boolean(true)
  }
  if mode == "projects-sticky" || mode == "projects-sticky-quiet" {
    let raw_days = fx_sticky_days(mode == "projects-sticky-quiet")
    let new_days : Array[Json] = []
    for d in raw_days {
      guard d is Object(dm) else { continue }
      let d_items : Array[Json] = []
      for item in items(Some(d), "items") {
        if fx_item_matches_filters(item, params) {
          d_items.push(item)
        }
      }
      if !d_items.is_empty() {
        let dm2 = dm.copy()
        dm2["items"] = Json::array(d_items)
        new_days.push(Json::object(dm2))
      }
    }
    out["days"] = Json::array(new_days)
    if text(Some(Json::object(params)), "groupBy") == "project" {
      out["groups"] = Json::array(fx_build_groups(new_days))
    }
    return Json::object(out)
  }
  // Decorate items with deterministic project/tags metadata
  let all_items : Array[Json] = []
  let new_days : Array[Json] = []
  let mut idx = 0
  for d in items(Some(v), "days") {
    guard d is Object(dm) else { continue }
    let d_items : Array[Json] = []
    for raw in items(Some(d), "items") {
      let item = fx_decorate_chat_item(raw, idx)
      idx += 1
      if fx_item_matches_filters(item, params) {
        d_items.push(item)
        all_items.push(item)
      }
    }
    if !d_items.is_empty() {
      let dm2 = dm.copy()
      dm2["items"] = Json::array(d_items)
      new_days.push(Json::object(dm2))
    }
  }
  out["days"] = Json::array(new_days)
  if text(Some(Json::object(params)), "groupBy") == "project" {
    out["groups"] = Json::array(fx_build_groups(new_days))
  }
  Json::object(out)
}

///|
fn fx_decorate_chat_item(raw : Json, idx : Int) -> Json {
  guard raw is Object(m) else { return raw }
  let out = m.copy()
  let key = text(Some(raw), "station") + ":" + text(Some(raw), "id")
  let proj : String? = match fx_chat_project.get(key) {
    Some(p) => p
    None =>
      if idx % 5 == 0 {
        Some("monoid")
      } else if idx % 5 == 1 {
        Some("board")
      } else if idx % 5 == 2 {
        Some(fx_stress_project_80)
      } else if idx % 5 == 3 {
        None
      } else {
        Some("")
      }
  }
  match proj {
    Some(p) => out["project"] = Json::string(p)
    None => out.remove("project")
  }
  let locked = fx_chat_locked.get(key).unwrap_or(idx % 5 == 0)
  if locked {
    out["projectLocked"] = Json::boolean(true)
  }
  let tags = match fx_chat_tags.get(key) {
    Some(ts) => ts
    None =>
      if idx % 5 == 0 {
        ["ui-review", "ios"]
      } else if idx % 5 == 1 {
        ["board"]
      } else if idx % 5 == 2 {
        [fx_stress_tag_48, "ui-review", "proactive"]
      } else {
        []
      }
  }
  if !tags.is_empty() {
    out["tags"] = Json::array(tags.map(Json::string))
  }
  Json::object(out)
}

///|
fn fx_item_matches_filters(item : Json, params : Map[String, Json]) -> Bool {
  let s = Some(item)
  if params.get("unclassified") is Some(True) || params.get("project") is Some(String("")) {
    match field(s, "project") {
      Some(String(p)) if p != "" => return false
      _ => ()
    }
  } else if params.get("project") is Some(String(want)) {
    match field(s, "project") {
      Some(String(got)) if got == want => ()
      _ => return false
    }
  }
  match params.get("tag") {
    Some(String(want_tag)) if want_tag != "" => {
      let has = items(s, "tags").iter().any(fn(t) { t == Json::string(want_tag) })
      if !has {
        return false
      }
    }
    _ => ()
  }
  true
}

///|
fn fx_build_groups(new_days : Array[Json]) -> Array[Json] {
  let by_proj : Map[String, Array[(String, Json)]] = Map([])
  let proj_order : Array[String] = []
  let unclass : Array[(String, Json)] = []
  // Pinned chats stay inside their own project group (or unified unclassified), pinned first,
  // preserving each item's day label for time sub-grouping (`dayBreaks`).
  for d in new_days {
    let day_label = text(Some(d), "label")
    for item in items(Some(d), "items") {
      let s = Some(item)
      let entry = (day_label, item)
      match field(s, "project") {
        Some(String(p)) if p != "" =>
          match by_proj.get(p) {
            Some(arr) => arr.push(entry)
            None => {
              by_proj[p] = [entry]
              proj_order.push(p)
            }
          }
        _ => unclass.push(entry)
      }
    }
  }
  let mk = fn(key : String, kind : String, label : String, proj : String?, rows : Array[(String, Json)]) -> Json {
    // Ensure pinned rows appear first within the group, then non-pinned in day order.
    let ordered : Array[(String, Json)] = []
    for r in rows {
      if flag(Some(r.1), "pinned") {
        ordered.push(("已固定", r.1))
      }
    }
    for r in rows {
      if !flag(Some(r.1), "pinned") {
        ordered.push(r)
      }
    }
    let sorted_rows : Array[Json] = []
    let day_breaks : Array[Json] = []
    let mut last_day = ""
    for i, entry in ordered {
      sorted_rows.push(entry.1)
      if entry.0 != "" && entry.0 != last_day {
        day_breaks.push(Json::object({ "at": Json::number(i.to_double()), "label": Json::string(entry.0) }))
        last_day = entry.0
      }
    }
    let mut running = 0
    let mut alert = 0
    let mut asking = 0
    let mut unread = 0
    for r in sorted_rows {
      let rs = Some(r)
      let tone = text(rs, "tone")
      let st = text(rs, "state")
      if tone == "busy" || st == "run" { running += 1 }
      if tone == "alert" || st == "failed" { alert += 1 }
      if tone == "wait" || st == "block" || text(rs, "stateLead") == "need" { asking += 1 }
      if flag(rs, "unread") || tone == "done" { unread += 1 }
    }
    let m : Map[String, Json] = {
      "key": Json::string(key),
      "kind": Json::string(kind),
      "label": Json::string(label),
      "chatCount": Json::number(sorted_rows.length().to_double()),
      "runningCount": Json::number(running.to_double()),
      "alertCount": Json::number(alert.to_double()),
      "askingCount": Json::number(asking.to_double()),
      "unreadCount": Json::number(unread.to_double()),
      "items": Json::array(sorted_rows),
    }
    if !day_breaks.is_empty() {
      m["dayBreaks"] = Json::array(day_breaks)
    }
    match proj {
      Some(p) => m["project"] = Json::string(p)
      None => ()
    }
    Json::object(m)
  }
  // As the core orders them (views.ts `projectGroupsOf`): unclassified first, then projects by name.
  let groups : Array[Json] = []
  if !unclass.is_empty() {
    groups.push(mk("unclassified", "unclassified", "未归类", None, unclass))
  }
  proj_order.sort()
  for p in proj_order {
    match by_proj.get(p) {
      Some(rows) => groups.push(mk("project:" + p, "project", p, Some(p), rows))
      None => ()
    }
  }
  groups
}

///|
/// Decorate `chat` topic output when `fx_projects_on` is true; returns `v` untouched when false.
fn fx_decorate_chat(v : Json, params : Map[String, Json]) -> Json {
  if !fx_projects_on.val {
    return v
  }
  guard v is Object(m) else { return v }
  let out = m.copy()
  out["projects"] = Json::boolean(true)
  if fx_projects_writable.val {
    out["projectsWritable"] = Json::boolean(true)
  }
  let station = text(Some(Json::object(params)), "station")
  let session = text(Some(Json::object(params)), "session")
  let key = station + ":" + session
  let proj : String? = match fx_chat_project.get(key) {
    Some(p) => p
    None => Some("monoid")
  }
  match proj {
    Some(p) => out["project"] = Json::string(p)
    None => out.remove("project")
  }
  out["projectLocked"] = Json::boolean(fx_chat_locked.get(key).unwrap_or(true))
  let tags = fx_chat_tags.get(key).unwrap_or(["ui-review", "ios"])
  out["tags"] = Json::array(tags.map(Json::string))
  // Attach a pending proposal to the last message if present
  let msgs = items(Some(v), "messages")
  if !msgs.is_empty() {
    let last_i = msgs.length() - 1
    let last = msgs[last_i]
    if last is Object(lm) {
      let lm2 = lm.copy()
      let seq = number(Some(last), "seq").to_int()
      let pk = station + ":" + seq.to_string()
      let (st, rp) = fx_proposal_state.get(pk).unwrap_or(("pending", None))
      let prop : Map[String, Json] = {
        "id": Json::string("prop-1"),
        "name": Json::string("chat-projects"),
        "note": Json::string("Agent 与人协作的 Chat 分类系统"),
        "refs": Json::array([Json::string("AFK-surf/monoid")]),
        "proposer": Json::string("agent"),
        "status": Json::string(st),
      }
      match rp {
        Some(p) => prop["resolvedProject"] = Json::string(p)
        None => ()
      }
      lm2["proposal"] = Json::object(prop)
      let msgs2 = msgs.copy()
      msgs2[last_i] = Json::object(lm2)
      out["messages"] = Json::array(msgs2)
    }
  }
  Json::object(out)
}

///|
/// Handle `projects`, `project`, and `tags` topics when `fx_projects_on` is true.
fn fx_projects_topic(name : String, params : Map[String, Json]) -> Json? {
  if !fx_projects_on.val {
    return None
  }
  let p = Some(Json::object(params))
  let cur = text(p, "cursor")
  let q = text(p, "q").to_lower()
  match name {
    "projects" => {
      let page1 : Array[Json] = [
        {
          "name": "monoid",
          "chatCount": 14,
          "runningCount": 2,
          "askingCount": 1,
          "unreadCount": 3,
          "latestActiveAt": 1795610000.0,
          "hasInfo": true,
          "refsCount": 2,
          "stations": ["ws1/st1"],
        },
        {
          "name": "board",
          "chatCount": 6,
          "runningCount": 0,
          "askingCount": 0,
          "unreadCount": 1,
          "latestActiveAt": 1795605000.0,
          "hasInfo": false,
          "refsCount": 1,
          "stations": ["ws1/st1"],
        },
      ]
      let page2 : Array[Json] = [
        {
          "name": Json::string(fx_stress_project_80),
          "chatCount": 3,
          "runningCount": 1,
          "askingCount": 0,
          "unreadCount": 0,
          "latestActiveAt": 1795600000.0,
          "hasInfo": true,
          "refsCount": 1,
          "stations": ["ws1/st1"],
        },
      ]
      let rows = if cur == "p2" { page2 } else { page1 }
      let filtered = if q == "" {
        rows
      } else {
        rows.filter(fn(r) { text(Some(r), "name").to_lower().contains(q) })
      }
      let out : Map[String, Json] = {
        "items": Json::array(filtered),
        "total": Json::number(3.0),
        "unclassifiedCount": Json::number(3.0),
        "crossCount": Json::number(0.0),
      }
      if cur == "" && q == "" {
        out["nextCursor"] = Json::string("p2")
      }
      Some(Json::object(out))
    }
    "tags" => {
      let page1 : Array[Json] = [
        { "name": "ui-review", "chatCount": 8, "latestActiveAt": 1795610000.0 },
        { "name": "ios", "chatCount": 5, "latestActiveAt": 1795608000.0 },
      ]
      let page2 : Array[Json] = [
        { "name": Json::string(fx_stress_tag_48), "chatCount": 2, "latestActiveAt": 1795601000.0 },
      ]
      let rows = if cur == "t2" { page2 } else { page1 }
      let filtered = if q == "" {
        rows
      } else {
        rows.filter(fn(r) { text(Some(r), "name").to_lower().contains(q) })
      }
      let out : Map[String, Json] = {
        "items": Json::array(filtered),
        "total": Json::number(3.0),
      }
      if cur == "" && q == "" {
        out["nextCursor"] = Json::string("t2")
      }
      Some(Json::object(out))
    }
    "project" => {
      let pname = text(p, "name")
      let (note, refs, rev) = fx_project_notes.get(pname).unwrap_or((
        "第一页项目说明。第二页补充说明。",
        ["AFK-surf/monoid", "https://github.com/AFK-surf/monoid"],
        "rev0000000000001",
      ))
      if cur == "" {
        // Page 1: first part of note + nextCursor "r:0"
        let out : Map[String, Json] = {
          "name": Json::string(pname),
          "note": Json::string(note),
          "refs": Json::array([]),
          "updatedAt": Json::number(1795610000.0),
          "infoRevision": Json::string(rev),
          "chatCount": Json::number(14.0),
          "runningCount": Json::number(2.0),
          "askingCount": Json::number(1.0),
          "unreadCount": Json::number(3.0),
          "nextCursor": Json::string("r:0"),
        }
        Some(Json::object(out))
      } else {
        // Page 2 (final): refs + consistent infoRevision, no nextCursor
        let out : Map[String, Json] = {
          "name": Json::string(pname),
          "refs": Json::array(refs.map(Json::string)),
          "updatedAt": Json::number(1795610000.0),
          "infoRevision": Json::string(rev),
          "chatCount": Json::number(14.0),
          "runningCount": Json::number(2.0),
          "askingCount": Json::number(1.0),
          "unreadCount": Json::number(3.0),
        }
        Some(Json::object(out))
      }
    }
    _ => None
  }
}

///|
/// Handle the 6 classification commands in `sffixture`. Returns `true` if handled.
fn fx_projects_call(
  f : Fixture,
  name : String,
  params : Json,
  done : (Result[Json, Json]) -> Unit,
) -> Bool {
  let s = Some(params)
  match name {
    "chat.classify" => {
      let station = text(s, "station")
      let thread = number(s, "thread").to_int()
      let key = station + ":s-c" + thread.to_string()
      match field(s, "project") {
        Some(String(p)) => {
          fx_chat_project[key] = Some(p)
          fx_chat_locked[key] = true
        }
        Some(Null) => {
          fx_chat_project[key] = None
          fx_chat_locked[key] = false
        }
        _ => ()
      }
      match field(s, "tags") {
        Some(Array(arr)) =>
          fx_chat_tags[key] = arr.filter_map(fn(x) {
            match x {
              String(t) => Some(t)
              _ => None
            }
          })
        _ => ()
      }
      f.changed()
      done(Ok(Json::object({ "ok": Json::boolean(true) })))
      true
    }
    "proposal.resolve" => {
      let station = text(s, "station")
      let entry_n = number(s, "entryN").to_int()
      let action = text(s, "action")
      let pk = station + ":" + entry_n.to_string()
      let (st, rp) = if action == "accept" {
        ("accepted", Some(match text(s, "name") { "" => "chat-projects"; n => n }))
      } else if action == "reassign" {
        ("reassigned", Some(text(s, "target")))
      } else if flag(s, "markCross") {
        ("dismissed", Some(""))
      } else {
        ("dismissed", None)
      }
      fx_proposal_state[pk] = (st, rp)
      f.changed()
      let prop : Map[String, Json] = { "status": Json::string(st) }
      match rp {
        Some(p) => prop["resolvedProject"] = Json::string(p)
        None => ()
      }
      let res : Map[String, Json] = {
        "ok": Json::boolean(true),
        "alreadyResolved": Json::boolean(false),
        "proposal": Json::object(prop),
      }
      done(Ok(Json::object(res)))
      true
    }
    "preset.setProject" => {
      let preset_id = text(s, "presetId")
      match field(s, "project") {
        Some(String(p)) => fx_preset_projects[preset_id] = p
        _ => fx_preset_projects.remove(preset_id)
      }
      f.changed()
      done(Ok(Json::object({ "ok": Json::boolean(true), "synced": Json::boolean(true) })))
      true
    }
    "project.updateInfo" => {
      let pname = text(s, "name")
      let (old_note, old_refs, _) = fx_project_notes.get(pname).unwrap_or((
        "第一页项目说明。第二页补充说明。",
        ["AFK-surf/monoid", "https://github.com/AFK-surf/monoid"],
        "rev0000000000001",
      ))
      let note = match field(s, "note") {
        Some(String(n)) => n
        _ => old_note
      }
      let refs = match field(s, "refs") {
        Some(Array(arr)) =>
          arr.filter_map(fn(x) {
            match x {
              String(u) => Some(u)
              _ => None
            }
          })
        _ => old_refs
      }
      fx_project_notes[pname] = (note, refs, "rev0000000000002")
      f.changed()
      done(Ok(Json::object({ "ok": Json::boolean(true) })))
      true
    }
    "project.rename" | "project.merge" => {
      let from = text(s, "from")
      let to = text(s, "to")
      match fx_project_notes.get(from) {
        Some(v) => {
          fx_project_notes.remove(from)
          if to != "" {
            fx_project_notes[to] = v
          }
        }
        None => ()
      }
      f.changed()
      done(Ok(Json::object({ "ok": Json::boolean(true), "peers": Json::array([]) })))
      true
    }
    _ => false
  }
}
