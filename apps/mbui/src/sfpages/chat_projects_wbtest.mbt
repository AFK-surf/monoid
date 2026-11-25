// Track B tests for PR 3 (`apps/mbui` chat classification UI):
// 1. Pending proposal renders strictly 2 buttons (`创建` + `编辑`) on the same row at `320×568 @ 1.3×`, zero overflow/audit faults.
// 2. `chat_body_shape` returns `None` when `projects_on && proposal is Some(_)`; multi-slice long message renders proposal ONCE (last slice).
// 3. Proposal actions: `创建` -> `action:"accept", entryN`; `编辑` panel top-level rename+create (`accept`+`name`),
//    reassign (`reassign`+`target`), mark cross (`dismiss`+`markCross:true`).
// 4. Already-resolved never stays busy (Astra P1-2): 200 `{ alreadyResolved: true, status: "reassigned", resolvedProject: "still.fail" }`
//    with no chat push immediately unlocks & converges to `已归入项目「still.fail」`; two stations same `seq` do not lock each other.
// 5. Wide bar `1280×800` shows inline project + neutral `#tag` attrs; medium `768×900` hides `fits` attrs block first without squeezing title;
//    narrow `390×844` classifies in chat info section.
// 6. `cv.projects == false` renders zero proposal / bar / info UI and adds zero bindings.
// 7. Multi-viewport (`1280×800`, `768×900`, `390×844`, `320×568`, `1.3×`, `en`) passes `t.audit()` with 0 faults and zero unexpected truncation.

///|
fn cp_reset() -> Unit {
  @sfbase.reset()
  reset()
  @sf.set_language(None)
  @ui.set_font_scale(None)
  @sf.set_words(@sfbase.fill)
}

///|
fn cp_proposal_msg(
  seq : Int,
  name? : String = "chat-projects",
  note? : String = "Agent 与人协作的 Chat 分类系统，用于管理跨站点对话归属。",
  refs? : Array[String] = ["AFK-surf/monoid", "https://github.com/AFK-surf/monoid"],
  status? : String = "pending",
  resolved_project? : String? = None,
  multi_slice? : Bool = false,
) -> Json {
  let prop : Map[String, Json] = {
    "id": Json::string("prop-" + seq.to_string()),
    "name": Json::string(name),
    "note": Json::string(note),
    "refs": Json::array(refs.map(Json::string)),
    "proposer": Json::string("agent"),
    "status": Json::string(status),
  }
  match resolved_project {
    Some(rp) => prop["resolvedProject"] = Json::string(rp)
    None => ()
  }
  let (txt, md) = if multi_slice {
    let p1 = "第一段：这是一个跨越多片渲染的长消息，确保静默提案条只在最后一片渲染一次。"
    let p2 = "第二段：继续补充更多说明内容，验证不会在中途切片重复出现确认条。"
    let p3 = "第三段：最后一片结束，下方应仅出现一次建议新建项目确认条。"
    (p1 + "\n\n" + p2 + "\n\n" + p3, Json::array([body_para(p1), body_para(p2), body_para(p3)]))
  } else {
    let p1 = "已完成分类分析，建议新建项目归档相关对话。"
    (p1, body_md(p1))
  }
  Json::object({
    "seq": Json::number(seq.to_double()),
    "thread": Json::number(7.0),
    "ts": Json::string("cp" + seq.to_string()),
    "createdAt": Json::number(1.7e12 + seq.to_double() * 60000.0),
    "authorKind": Json::string("agent"),
    "author": Json::string("Claude"),
    "text": Json::string(txt),
    "md": md,
    "by": Json::object({ "name": Json::string("Claude"), "agent": Json::string("s-c1") }),
    "proposal": Json::object(prop),
  })
}

///|
fn cp_chat_view(
  projects : Bool,
  msgs : Array[Json],
  project? : String? = Some("monoid"),
  locked? : Bool = true,
  tags? : Array[String] = ["ui-review", "ios"],
  title? : String = "Chat 分类系统联调",
) -> ChatView {
  let base : Map[String, Json] = {
    "title": Json::string(title),
    "thread": Json::object({ "id": Json::number(7.0) }),
    "messages": Json::array([]),
    "projects": Json::boolean(projects),
    "projectsWritable": Json::boolean(projects),
    "projectLocked": Json::boolean(locked),
    "tags": Json::array(tags.map(Json::string)),
  }
  match project {
    Some(p) => base["project"] = Json::string(p)
    None => ()
  }
  let v = @sfbase.chat_view_made(Json::object(base))
  { ..v, messages: msgs.map(@sfbase.message_of) }
}

///|
fn cp_source(
  on_call : (String, Json, (Result[Json, Json]) -> Unit) -> Unit,
) -> Source {
  @sffixture.fx_projects_on.val = true
  let base = @sffixture.fixture("chat")
  { ..base, call: on_call }
}

///|
fn cp_find_word(t : @ui.Tester, want : String) -> (String, Double, Double, Double, Double, Double)? {
  for s in t.words_said() {
    if s.0 == want {
      return Some(s)
    }
  }
  None
}

///|
fn cp_count_word(t : @ui.Tester, want : String) -> Int {
  let mut n = 0
  for s in t.words_said() {
    if s.0 == want {
      n += 1
    }
  }
  n
}

///|
fn cp_has_substr(t : @ui.Tester, sub : String) -> Bool {
  t.words_said().iter().any(fn(s) { s.0.contains(sub) })
}

///|
test "proposal bar: strictly 2 buttons on same row at 320x568 @ 1.3x with zero audit faults" {
  cp_reset()
  let calls : Array[(String, Json)] = []
  let src = cp_source(fn(name, params, done) {
    calls.push((name, params))
    done(Ok(Json::object({ "ok": Json::boolean(true) })))
  })
  let cv = cp_chat_view(true, [cp_proposal_msg(10)])
  let view = @signals.signal(cv)
  let entries = @signals.signal(@sfbase.entries_of(cv))
  let t = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      let here : MessageNodeHere = {
        station: "ws1/st1",
        session: "s-c7",
        view: fn() { view.get() },
        width: fn() { 320.0 },
        tips,
        stint: fn() { 0 },
        jump: None,
        picture: None,
      }
      root.box(fn(f) {
        f.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        chat_body_node(f, src, here, fn() { entries.get() }, foot=fn() { body_foot(view.get()) }) |> ignore
      })
      |> ignore
      @sf.presented_nodes(root)
    },
    w=320.0,
    h=568.0,
    platform=2,
    scale=2.0,
  )
  @ui.set_font_scale(Some(1.3))
  t.set_rows_on_pixels(true)
  t.run_for(@ui.move_most_ms)
  // Title, note, refs shown; never internal term "静默提案"
  assert_true(cp_has_substr(t, "建议新建项目：chat-projects"))
  assert_true(cp_has_substr(t, "Agent 与人协作"))
  assert_true(cp_has_substr(t, "AFK-surf/"))
  assert_true(cp_has_substr(t, "monoid"))
  assert_false(cp_has_substr(t, "静默提案"))
  // Strictly 2 buttons: 创建 + 编辑, on the exact same row and within 320pt width
  let create_w = cp_find_word(t, "创建")
  let edit_w = cp_find_word(t, "编辑")
  assert_true(create_w is Some(_))
  assert_true(edit_w is Some(_))
  assert_false(cp_has_substr(t, "设为跨项目 / 其他"))
  assert_false(cp_has_substr(t, "仅忽略"))
  match (create_w, edit_w) {
    (Some(c), Some(e)) => {
      assert_true((c.2 - e.2).abs() < 2.0)
      assert_true(c.1 + c.3 <= 320.0)
      assert_true(e.1 + e.3 <= 320.0)
    }
    _ => fail("missing create/edit buttons")
  }
  assert_eq(t.audit(), [])
}

///|
test "chat_body_shape exits reuse for proposal when projects_on, and multi-slice renders proposal once" {
  cp_reset()
  let src = cp_source(fn(_, _, done) { done(Ok(Json::object({ "ok": Json::boolean(true) }))) })
  let msg = @sfbase.message_of(cp_proposal_msg(11, multi_slice=true))
  let row : ChatBodyRow = { entry: Entry::Said(msg), gap: Apart, slices: 3 }
  let cv_on = cp_chat_view(true, [cp_proposal_msg(11, multi_slice=true)])
  let cv_off = cp_chat_view(false, [cp_proposal_msg(11, multi_slice=true)])
  let tips = @sf.TipLayer::new(fn() { None })
  let here_on : MessageNodeHere = {
    station: "ws1/st1",
    session: "s-c7",
    view: fn() { cv_on },
    width: fn() { 800.0 },
    tips,
    stint: fn() { 0 },
    jump: None,
    picture: None,
  }
  let here_off : MessageNodeHere = { ..here_on, view: fn() { cv_off } }
  // projects_on && proposal is Some(_) => None (exits block reuse)
  assert_eq(chat_body_shape(here_on, row, None), None)
  // projects_on == false => normal reuse shape (Some(_))
  assert_true(chat_body_shape(here_off, row, None) is Some(_))
  // Render multi-slice long message: proposal bar must render ONCE (on last slice only)
  let view = @signals.signal(cv_on)
  let entries = @signals.signal(@sfbase.entries_of(cv_on))
  let t = body_new(src, 800.0, 900.0, 0, view, entries)
  t.run_for(@ui.move_most_ms)
  assert_eq(cp_count_word(t, "创建"), 1)
  assert_eq(cp_count_word(t, "编辑"), 1)
  assert_eq(t.audit(), [])
}

///|
test "proposal actions: create sends accept+entryN; edit panel exposes rename-create, reassign, and mark-cross at top level" {
  cp_reset()
  let calls : Array[(String, Json)] = []
  let src = cp_source(fn(name, params, done) {
    calls.push((name, params))
    done(Ok(Json::object({ "ok": Json::boolean(true) })))
  })
  // 1. Direct 创建 -> action:"accept", entryN:12
  let cv1 = cp_chat_view(true, [cp_proposal_msg(12)])
  let view1 = @signals.signal(cv1)
  let entries1 = @signals.signal(@sfbase.entries_of(cv1))
  let t1 = body_new(src, 900.0, 700.0, 0, view1, entries1)
  t1.run_for(@ui.move_most_ms)
  let c1 = cp_find_word(t1, "创建").unwrap()
  t1.tap(c1.1 + c1.3 / 2.0, c1.2 + c1.4 / 2.0)
  t1.run_for(@ui.move_most_ms)
  assert_eq(calls.length(), 1)
  assert_eq(calls[0].0, "proposal.resolve")
  assert_eq(@sfbase.text(Some(calls[0].1), "action"), "accept")
  assert_eq(@sfbase.text(Some(calls[0].1), "name"), "chat-projects")
  assert_eq(@sfbase.number(Some(calls[0].1), "entryN"), 12.0)
  assert_true(cp_has_substr(t1, "已创建项目「chat-projects」"))

  // 2. 编辑 panel -> top-level 改名创建 / 改归已有 / 设为未归类
  calls.clear()
  let cv2 = cp_chat_view(true, [cp_proposal_msg(13)])
  let view2 = @signals.signal(cv2)
  let entries2 = @signals.signal(@sfbase.entries_of(cv2))
  let t2 = body_new(src, 900.0, 700.0, 0, view2, entries2)
  t2.run_for(@ui.move_most_ms)
  let e2 = cp_find_word(t2, "编辑").unwrap()
  t2.tap(e2.1 + e2.3 / 2.0, e2.2 + e2.4 / 2.0)
  t2.run_for(@ui.move_most_ms)
  assert_true(cp_find_word(t2, "改名创建") is Some(_))
  assert_true(cp_find_word(t2, "改归已有") is Some(_))
  assert_true(cp_find_word(t2, "不归入项目") is Some(_))
  assert_true(cp_find_word(t2, "board") is Some(_))
  // Click 改名创建 -> accept + name
  let rc = cp_find_word(t2, "改名创建").unwrap()
  t2.tap(rc.1 + rc.3 / 2.0, rc.2 + rc.4 / 2.0)
  t2.run_for(@ui.move_most_ms)
  assert_eq(calls.length(), 1)
  assert_eq(@sfbase.text(Some(calls[0].1), "action"), "accept")
  assert_eq(@sfbase.text(Some(calls[0].1), "name"), "chat-projects")

  // 3. 编辑 -> 改归已有项目 ("board") -> reassign + target:"board"
  calls.clear()
  let cv3 = cp_chat_view(true, [cp_proposal_msg(14)])
  let view3 = @signals.signal(cv3)
  let entries3 = @signals.signal(@sfbase.entries_of(cv3))
  let t3 = body_new(src, 900.0, 700.0, 0, view3, entries3)
  t3.run_for(@ui.move_most_ms)
  let e3 = cp_find_word(t3, "编辑").unwrap()
  t3.tap(e3.1 + e3.3 / 2.0, e3.2 + e3.4 / 2.0)
  t3.run_for(@ui.move_most_ms)
  let board_row = cp_find_word(t3, "board").unwrap()
  t3.tap(board_row.1 + board_row.3 / 2.0, board_row.2 + board_row.4 / 2.0)
  t3.run_for(@ui.move_most_ms)
  assert_eq(calls.length(), 1)
  assert_eq(@sfbase.text(Some(calls[0].1), "action"), "reassign")
  assert_eq(@sfbase.text(Some(calls[0].1), "target"), "board")
  assert_true(cp_has_substr(t3, "已归入项目「board」"))

  // 4. 编辑 -> 设为未归类 -> dismiss + markCross:true
  calls.clear()
  let cv4 = cp_chat_view(true, [cp_proposal_msg(15)])
  let view4 = @signals.signal(cv4)
  let entries4 = @signals.signal(@sfbase.entries_of(cv4))
  let t4 = body_new(src, 900.0, 700.0, 0, view4, entries4)
  t4.run_for(@ui.move_most_ms)
  let e4 = cp_find_word(t4, "编辑").unwrap()
  t4.tap(e4.1 + e4.3 / 2.0, e4.2 + e4.4 / 2.0)
  t4.run_for(@ui.move_most_ms)
  let cross_row = cp_find_word(t4, "不归入项目").unwrap()
  t4.tap(cross_row.1 + cross_row.3 / 2.0, cross_row.2 + cross_row.4 / 2.0)
  t4.run_for(@ui.move_most_ms)
  assert_eq(calls.length(), 1)
  assert_eq(@sfbase.text(Some(calls[0].1), "action"), "dismiss")
  assert_true(@sfbase.flag(Some(calls[0].1), "markCross"))
  assert_true(cp_has_substr(t4, "已忽略项目建议"))
}

///|
test "alreadyResolved 200 without follow-up push immediately unlocks and converges; cross-station same seq isolated" {
  cp_reset()
  let held : Ref[((Result[Json, Json]) -> Unit)?] = Ref(None)
  let src = cp_source(fn(name, _, done) {
    if name == "proposal.resolve" {
      held.val = Some(done)
    } else {
      done(Ok(Json::object({ "ok": Json::boolean(true) })))
    }
  })
  let cv = cp_chat_view(true, [cp_proposal_msg(20)])
  let view = @signals.signal(cv)
  let entries = @signals.signal(@sfbase.entries_of(cv))
  let t = body_new(src, 900.0, 700.0, 0, view, entries)
  t.run_for(@ui.move_most_ms)
  let c = cp_find_word(t, "创建").unwrap()
  t.tap(c.1 + c.3 / 2.0, c.2 + c.4 / 2.0)
  t.run_for(@sf.dur_ms)
  // Station 1 is busy, station 2 with identical seq=20 is NOT locked
  assert_true(@sfbase.proposal_is_pending(body_ref.station, 7.0, 20.0))
  assert_false(@sfbase.proposal_is_pending("ws1/st-other", 7.0, 20.0))
  // Complete with 200 alreadyResolved and NO chat topic push
  match held.val {
    Some(done) =>
      done(
        Ok(
          Json::object({
            "ok": Json::boolean(true),
            "alreadyResolved": Json::boolean(true),
            "status": Json::string("reassigned"),
            "resolvedProject": Json::string("still.fail"),
          }),
        ),
      )
    None => fail("proposal.resolve was not called")
  }
  t.run_for(@ui.move_most_ms)
  assert_false(@sfbase.proposal_is_pending(body_ref.station, 7.0, 20.0))
  assert_true(cp_has_substr(t, "已归入项目「still.fail」"))
  assert_eq(t.audit(), [])
}

///|
test "wide 1280x800 shows inline fits attrs; tight 768x900 hides fits attrs before squeezing title; narrow 390x844 classifies in info" {
  cp_reset()
  let calls : Array[(String, Json)] = []
  let src = cp_source(fn(name, params, done) {
    calls.push((name, params))
    done(Ok(Json::object({ "ok": Json::boolean(true) })))
  })
  let chat_ref : ChatRef = { station: "ws1/st1", session: "s-c7", title: "对话标题", station_name: "st1" }
  let cv_long = cp_chat_view(
    true,
    [],
    title="一个非常长的对话标题用来测试中屏空间不足时优先隐藏属性块而不是挤压标题本身",
  )
  let view = @signals.signal(cv_long)
  // 1. Wide 1280x800: inline project & tags visible
  let t_wide = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      root.box(fn(row) {
        row
        .row(Is(true))
        .height(Is(Some(@sf.wide_bar_h)))
        .padding(Is((12.0, 0.0, 12.0, 0.0)))
        .gap(Is(10.0))
        .lines_up(Is(Some(Middle)))
        .keeps_held(Is(true))
        .fits(Is(true))
        |> ignore
        row.box(fn(tw) {
          tw.shrink(Is(1.0)).max_width(Is(Some(500.0))) |> ignore
          @sf.words_node(tw, fn() { view.get().title }, fn() {
            @ui.text_style(size=Title, weight=Semibold, color=Fg, wrap=false, w=Cut)
          })
          |> ignore
        })
        |> ignore
        chat_bar_project_attrs_node(row, src, chat_ref, fn() { Some(view.get()) }, tips)
      })
      |> ignore
      @sf.presented_nodes(root)
    },
    w=1280.0,
    h=800.0,
    platform=0,
    scale=2.0,
  )
  t_wide.run_for(@ui.move_most_ms)
  assert_true(cp_find_word(t_wide, "monoid") is Some(_))
  assert_true(cp_find_word(t_wide, "#ui-review") is Some(_))
  assert_true(cp_find_word(t_wide, "#ios") is Some(_))
  assert_eq(t_wide.audit(), [])

  // 2. Medium 768x900 with constrained title row (360pt bar room): fits hides attrs first, title stays intact
  let t_med = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      root.box(fn(row) {
        row
        .row(Is(true))
        .width(Is(Some(360.0)))
        .height(Is(Some(@sf.wide_bar_h)))
        .padding(Is((12.0, 0.0, 12.0, 0.0)))
        .gap(Is(10.0))
        .lines_up(Is(Some(Middle)))
        .keeps_held(Is(true))
        .fits(Is(true))
        |> ignore
        row.box(fn(tw) {
          tw.shrink(Is(1.0)).min_width(Is(Some(120.0))) |> ignore
          @sf.words_node(tw, fn() { view.get().title }, fn() {
            @ui.text_style(size=Title, weight=Semibold, color=Fg, wrap=false, w=Cut)
          })
          |> ignore
        })
        |> ignore
        chat_bar_project_attrs_node(row, src, chat_ref, fn() { Some(view.get()) }, tips)
      })
      |> ignore
      @sf.presented_nodes(root)
    },
    w=768.0,
    h=900.0,
    platform=0,
    scale=2.0,
  )
  t_med.run_for(@ui.move_most_ms)
  assert_true(cp_find_word(t_med, "monoid") is None)
  assert_true(cp_find_word(t_med, "#ui-review") is None)
  assert_eq(t_med.audit(), [])

  // 3. Narrow 390x844: classify in chat info section
  let t_narrow = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.box(fn(col) {
        col.grow(Is(1.0)) |> ignore
        chat_info_projects_section_node(col, src, chat_ref, fn() { Some(view.get()) }, in_sheet=true)
      })
      |> ignore
      @sf.presented_nodes(root)
    },
    w=390.0,
    h=844.0,
    platform=2,
    scale=2.0,
  )
  t_narrow.run_for(@ui.move_most_ms)
  assert_true(cp_find_word(t_narrow, "项目与标签") is Some(_))
  assert_true(cp_find_word(t_narrow, "monoid") is Some(_))
  assert_true(cp_find_word(t_narrow, "#ui-review") is Some(_))
  assert_true(cp_has_substr(t_narrow, "由成员指定，Agent 不会自动改归"))
  // Click project row to open picker and select "board"
  let prow = cp_find_word(t_narrow, "monoid").unwrap()
  t_narrow.tap(prow.1 + prow.3 / 2.0, prow.2 + prow.4 / 2.0)
  t_narrow.run_for(@ui.move_most_ms)
  let board_opt = cp_find_word(t_narrow, "board").unwrap()
  t_narrow.tap(board_opt.1 + board_opt.3 / 2.0, board_opt.2 + board_opt.4 / 2.0)
  t_narrow.run_for(@ui.move_most_ms)
  assert_true(calls.iter().any(fn(c) { c.0 == "chat.classify" && @sfbase.text(Some(c.1), "project") == "board" }))
  assert_eq(t_narrow.audit(), [])
}

///|
test "cv.projects == false renders zero proposal, bar, or info classification UI" {
  cp_reset()
  let src = cp_source(fn(_, _, done) { done(Ok(Json::object({ "ok": Json::boolean(true) }))) })
  let cv_off = cp_chat_view(false, [cp_proposal_msg(30)])
  let view = @signals.signal(cv_off)
  let entries = @signals.signal(@sfbase.entries_of(cv_off))
  let chat_ref : ChatRef = { station: "ws1/st1", session: "s-c7", title: "关闭开关", station_name: "st1" }
  let t = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      let here : MessageNodeHere = {
        station: "ws1/st1",
        session: "s-c7",
        view: fn() { view.get() },
        width: fn() { 800.0 },
        tips,
        stint: fn() { 0 },
        jump: None,
        picture: None,
      }
      root.box(fn(col) {
        col.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        col.box(fn(bar) {
          bar.row(Is(true)).fits(Is(true)) |> ignore
          chat_bar_project_attrs_node(bar, src, chat_ref, fn() { Some(view.get()) }, tips)
        })
        |> ignore
        chat_info_projects_section_node(col, src, chat_ref, fn() { Some(view.get()) }, in_sheet=false)
        col.box(fn(body_box) {
          body_box.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
          chat_body_node(body_box, src, here, fn() { entries.get() }, foot=fn() { body_foot(view.get()) }) |> ignore
        })
        |> ignore
      })
      |> ignore
      @sf.presented_nodes(root)
    },
    w=800.0,
    h=700.0,
    platform=0,
    scale=2.0,
  )
  t.set_rows_on_pixels(true)
  t.run_for(@ui.move_most_ms)
  assert_false(cp_has_substr(t, "建议新建项目："))
  assert_true(cp_find_word(t, "创建") is None)
  assert_true(cp_find_word(t, "编辑") is None)
  assert_true(cp_find_word(t, "项目与标签") is None)
  assert_true(cp_find_word(t, "#ui-review") is None)
  assert_eq(t.audit(), [])
}

///|
test "English locale and 1.3x text scale render cleanly with zero audit faults" {
  cp_reset()
  let src = cp_source(fn(_, _, done) { done(Ok(Json::object({ "ok": Json::boolean(true) }))) })
  let cv = cp_chat_view(true, [cp_proposal_msg(40)])
  let view = @signals.signal(cv)
  let entries = @signals.signal(@sfbase.entries_of(cv))
  let chat_ref : ChatRef = { station: "ws1/st1", session: "s-c7", title: "Projects", station_name: "st1" }
  let t = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      let here : MessageNodeHere = {
        station: "ws1/st1",
        session: "s-c7",
        view: fn() { view.get() },
        width: fn() { 320.0 },
        tips,
        stint: fn() { 0 },
        jump: None,
        picture: None,
      }
      root.box(fn(col) {
        col.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        chat_info_projects_section_node(col, src, chat_ref, fn() { Some(view.get()) }, in_sheet=true)
        col.box(fn(body_box) {
          body_box.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
          chat_body_node(body_box, src, here, fn() { entries.get() }, foot=fn() { body_foot(view.get()) }) |> ignore
        })
        |> ignore
      })
      |> ignore
      @sf.presented_nodes(root)
    },
    w=320.0,
    h=700.0,
    platform=2,
    scale=2.0,
  )
  @sf.set_language(Some("en"))
  @ui.set_font_scale(Some(1.3))
  t.set_rows_on_pixels(true)
  t.run_for(@ui.move_most_ms)
  assert_true(cp_find_word(t, "Projects & Tags") is Some(_))
  assert_true(cp_find_word(t, "Create") is Some(_))
  assert_true(cp_find_word(t, "Edit") is Some(_))
  // Opus P1-1: at 320px @ 1.3x, every proposal card word & button must stay strictly inside the viewport right edge
  let create_box = cp_find_word(t, "Create").unwrap()
  let edit_box = cp_find_word(t, "Edit").unwrap()
  assert_true(create_box.1 >= 0.0 && create_box.1 + create_box.3 <= 320.0 - 12.0)
  assert_true(edit_box.1 >= 0.0 && edit_box.1 + edit_box.3 <= 320.0 - 12.0)
  assert_eq(t.audit(), [])
  @sf.set_language(None)
}

///|
test "proposal accept with infoError stays retryable until PROJECTS.jsonl sync succeeds" {
  cp_reset()
  let attempt : Ref[Int] = Ref(0)
  let src = cp_source(fn(name, _, done) {
    if name == "proposal.resolve" {
      attempt.val += 1
      if attempt.val == 1 {
        done(
          Ok(
            Json::object({
              "proposal": Json::object({
                "status": Json::string("pending"),
                "resolvedProject": Json::string("chat-projects"),
              }),
              "alreadyResolved": Json::boolean(false),
              "infoError": Json::string("EACCES: PROJECTS.jsonl locked"),
            }),
          ),
        )
      } else {
        done(
          Ok(
            Json::object({
              "proposal": Json::object({
                "status": Json::string("accepted"),
                "resolvedProject": Json::string("chat-projects"),
              }),
              "alreadyResolved": Json::boolean(true),
            }),
          ),
        )
      }
    } else {
      done(Ok(Json::object({ "ok": Json::boolean(true) })))
    }
  })
  let cv = cp_chat_view(true, [cp_proposal_msg(55)])
  let view = @signals.signal(cv)
  let entries = @signals.signal(@sfbase.entries_of(cv))
  let t = body_new(src, 900.0, 700.0, 0, view, entries)
  t.run_for(@ui.move_most_ms)
  // First click returns 200 + infoError -> bar MUST stay retryable even across a server refresh / reopen!
  let c1 = cp_find_word(t, "创建").unwrap()
  t.tap(c1.1 + c1.3 / 2.0, c1.2 + c1.4 / 2.0)
  t.run_for(@ui.move_most_ms)
  // Simulate server refresh / chat reopen still returning status: "pending" while info_synced = 0
  let cv_reopen = cp_chat_view(true, [cp_proposal_msg(55)])
  view.set(cv_reopen)
  entries.set(@sfbase.entries_of(cv_reopen))
  t.run_for(@ui.move_most_ms)
  assert_eq(attempt.val, 1)
  assert_true(cp_find_word(t, "创建") is Some(_), msg="infoError must keep proposal bar retryable after refresh")
  assert_false(cp_has_substr(t, "已创建项目「chat-projects」"))
  // Second click replays idempotent resolve -> succeeds cleanly and converges!
  let c2 = cp_find_word(t, "创建").unwrap()
  t.tap(c2.1 + c2.3 / 2.0, c2.2 + c2.4 / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(attempt.val, 2)
  assert_true(cp_has_substr(t, "已创建项目「chat-projects」"))
}
