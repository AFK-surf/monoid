// Execution history header beside a chat on Medium and Large screens (`sfdesk/history.mbt`,
// `sfpages/history_steps_node.mbt`): long text attention warnings shrink instead of crushing
// `model_triple_node`, show their full text in a tooltip when truncated, and leave quota chips whole.

///|
test "wide: a long account attention note beside an agent's history's control shrinks instead of crushing the model button, and shows its full text in a tooltip when cut" {
  new_run()
  let base = fixture("chat")
  let full = "「Google AI Pro · hisenxpress@gmail.com」需要重新登录"
  let note : Json = { "kind": "account", "text": full }
  let src : Source = {
    ..base,
    topic_read: fn(name, params) {
      let got = base.topic(name, params).get().snapshot()
      match (name, got.value) {
        ("chat", Some(Object(chat)) as v) => {
          let agents = items(v, "agents").map(fn(a) {
            match a {
              Object(o) => {
                let o = o.copy()
                o["attention"] = [note]
                Json::object(o)
              }
              other => other
            }
          })
          let chat = chat.copy()
          chat["agents"] = Json::array(agents)
          { ..got, value: Some(Json::object(chat)) }
        }
        _ => got
      }
    },
  }
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="打开侧栏")
  t.run_for(@ui.move_most_ms)
  for w = 1100.0; w <= 1600.0; w = w + 50.0 {
    t.resize(w, 800.0)
    t.frame()
    let only_io = t.get(Button, label="只看收发").rect
    let head_y = only_io.1 + only_io.3 / 2.0
    let model_btn = t
      .semantics()
      .iter()
      .find_first(fn(s) {
        s.role == Button &&
        s.label != "只看收发" &&
        s.label != "详情" &&
        s.rect.0 < only_io.0 &&
        s.rect.1 < head_y &&
        s.rect.1 + s.rect.3 > head_y &&
        s.rect.0 > w / 2.0
      })
      .unwrap()
    let (mx, my, mw, mh) = model_btn.rect
    // Model button keeps room for its icon, name, and chevron instead of collapsing to padding.
    assert_true(mw >= 70.0, msg="w=\{w}: model button crushed to \{mw} (\{model_btn.label})")
    let model_words = t
      .text_runs()
      .filter(fn(run) { run.base > my && run.base < my + mh && run.x0 >= mx - 0.5 && run.x1 <= mx + mw + 0.5 })
    assert_true(model_words.length() > 0, msg="w=\{w}: no model name drawn inside \{Repr(model_btn.rect)}")
    // The red account warning starts after the model button and stays before 只看收发.
    let warn_boxes = t
      .words()
      .filter(fn(item) {
        item.5 > 0.5 &&
        item.2 + item.4 > my &&
        item.2 < my + mh &&
        item.1 >= mx &&
        item.1 < only_io.0 &&
        item.0.contains("Google")
      })
    assert_true(warn_boxes.length() > 0, msg="w=\{w}: warning missing")
    let (_, wx, _, ww, _, _) = warn_boxes[0]
    assert_true(
      wx >= mx + mw - 0.5,
      msg="w=\{w}: warning overlaps model button (btn right=\{mx + mw}, warn x=\{wx})",
    )
    assert_true(
      wx + ww <= only_io.0 + 0.5,
      msg="w=\{w}: warning overlaps 只看收发 (warn right=\{wx + ww}, io x=\{only_io.0})",
    )
  }
  // At narrow desktop width (1100), hovering the truncated warning reveals the full text in a tooltip.
  t.resize(1100.0, 800.0)
  t.frame()
  assert_eq(t.audit().filter(fn(f) { !f.contains("edge_node.mbt") }), [])
  let only_io = t.get(Button, label="只看收发").rect
  let head_y = only_io.1 + only_io.3 / 2.0
  let (_, wx, _, ww, _, _) = t
    .words()
    .filter(fn(item) {
      item.5 > 0.5 && item.2 < head_y && item.2 + item.4 > head_y && item.0.contains("Google")
    })[0]
  assert_true(t.lines_of("Google").iter().any(fn(l) { l.has_suffix("…") }), msg="warning should ellipsize at 1100")
  t.move_to(wx + ww / 2.0, head_y)
  t.run_for(@sf.tip_delay_ms + @ui.move_most_ms)
  assert_true(
    t.words().filter(fn(item) { item.0 == full && item.5 > 0.5 }).length() >= 2,
    msg="tooltip should show full warning text, saw: \{Repr(t.words().filter(fn(item) { item.0.contains("Google") }))}",
  )
}

///|
test "wide: a quota chip and a long account warning together keep the quota figure whole and the model button intact" {
  new_run()
  let base = fixture("chat")
  let quota_note : Json = {
    "kind": "quota",
    "text": "每周额度剩 23%",
    "quota": { "left": 23, "mark": "W", "level": "amber" },
  }
  let account_note : Json = { "kind": "account", "text": "「Google AI Pro · hisenxpress@gmail.com」需要重新登录" }
  let src : Source = {
    ..base,
    topic_read: fn(name, params) {
      let got = base.topic(name, params).get().snapshot()
      match (name, got.value) {
        ("chat", Some(Object(chat)) as v) => {
          let agents = items(v, "agents").map(fn(a) {
            match a {
              Object(o) => {
                let o = o.copy()
                o["attention"] = [quota_note, account_note]
                Json::object(o)
              }
              other => other
            }
          })
          let chat = chat.copy()
          chat["agents"] = Json::array(agents)
          { ..got, value: Some(Json::object(chat)) }
        }
        _ => got
      }
    },
  }
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1600.0, h=800.0, platform=0)
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="打开侧栏")
  t.run_for(@ui.move_most_ms)
  let figure = fn() { t.words().filter(fn(w) { w.0 == "23%" && w.5 > 0.5 }) }
  let whole = figure()[0].3
  for w = 1100.0; w <= 1600.0; w = w + 100.0 {
    t.resize(w, 800.0)
    t.frame()
    let now = figure()
    assert_true(now.length() == 1 && now[0].3 >= whole - 0.5, msg="w=\{w}: quota cut \{Repr(now)} (whole=\{whole})")
    let only_io = t.get(Button, label="只看收发").rect
    let head_y = only_io.1 + only_io.3 / 2.0
    let model_btn = t
      .semantics()
      .iter()
      .find_first(fn(s) {
        s.role == Button &&
        s.label != "只看收发" &&
        s.label != "详情" &&
        s.rect.0 < only_io.0 &&
        s.rect.1 < head_y &&
        s.rect.1 + s.rect.3 > head_y &&
        s.rect.0 > w / 2.0
      })
      .unwrap()
    assert_true(model_btn.rect.2 >= 70.0, msg="w=\{w}: model button crushed to \{model_btn.rect.2}")
    assert_true(now[0].1 >= model_btn.rect.0 + model_btn.rect.2 - 0.5, msg="w=\{w}: quota overlaps model button")
  }
}
