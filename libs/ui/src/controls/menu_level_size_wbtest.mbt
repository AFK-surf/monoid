// A menu (menu_node_by) whose submenu levels are pushed and gone back from in its own panel: the panel's width and
// height going their ways between the levels' sizes, never snapping (sizes_steady).

///|
/// Past the menu's opening and a level's slide, at rest.
let level_size_rest_ms : Double = 700.0

///|
/// A level's slide part way: on its way, neither where it was nor where it goes.
let level_size_mid_ms : Double = 100.0

///|
/// Just after a level was gone back from: what it was still sliding out.
let level_size_leaving_ms : Double = 30.0

///|
/// The rest of a level's slide and past it.
let level_size_settle_ms : Double = 600.0

///|
fn level_size_tester(
  levels : @signals.Signal[Array[MenuLevel]],
  panel : Ref[@view.View?],
  first : Array[MenuItem?],
  extras? : (Int) -> MenuExtra = fn(_) { menu_no_extra },
) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=800.0, h=600.0, dark=false, platform=0)
  set_dark(Some(false))
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    let btn_ref : Ref[@view.View?] = Ref(None)
    root.box(fn(page) {
      page.grow(Is(1.0)).padding(Is((64.0, 64.0, 64.0, 64.0))).ground(By(fn() { theme().p.bg })) |> ignore
      let btn = page.box(fn(o) {
        o
        .width(Is(Some(80.0)))
        .height(Is(Some(36.0)))
        .presses(Is(true))
        .says(Is(Some(@view.said(Button, label="Actions"))))
        |> ignore
      })
      btn_ref.val = Some(btn)
    })
    |> ignore
    root.box(fn(l) {
      l.over(Is(true)) |> ignore
      menu_node_by(
        l,
        fn() { true },
        fn(_) { btn_ref.val.unwrap() },
        fn() { first },
        "",
        Start,
        panel_offset,
        false,
        false,
        fn(_) {  },
        fn() {  },
        false,
        sub_levels=fn() { levels.get() },
        extras~,
        level_back=fn() {
          let now = levels.untracked()
          if now.is_empty() {
            false
          } else {
            @view.transition(fn() { levels.set(now[:now.length() - 1].to_owned()) })
            true
          }
        },
        panel_ref=panel,
      )
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// The first level of a chat's menu, its last row going in to `share` (`wide`: with a row wider than the level it goes
/// in to, as where the chat may be moved).
fn level_size_first(wide : Bool) -> Array[MenuItem?] {
  let items : Array[MenuItem?] = [
    Some(menu_item_of("Pin", fn() {  }, icon="pin")),
    Some(menu_item_of("Rename", fn() {  }, icon="pencil")),
    Some(menu_item_of("Keep", fn() {  }, icon="pin")),
    Some(menu_item_of("Archive", fn() {  }, icon="archive")),
    None,
  ]
  if wide {
    items.push(Some(menu_item_of("Move to another station", fn() {  }, icon="move", further=true)))
  }
  items.push(Some(menu_item_of("Share", fn() {  }, icon="share", further=true)))
  items
}

///|
/// A level pushed into a menu and gone back from (`wide`: the first level wider than the pushed one, else narrower):
/// the panel's width and height each go their way from as they stood to as the level that shows makes them, both ways,
/// sizes steady at every frame (the Tester's sizes_steady: the width snapping to the new level's as it changed, and the
/// height held at the shorter level's all the way back then snapping to the taller one's, each failed it). Its sizes
/// (width, height) at rest on the first level, on its way in, at rest on the pushed one, on its way back.
fn level_size_run(wide : Bool) -> Array[(Double, Double)] raise {
  presenters_reset()
  let levels : @signals.Signal[Array[MenuLevel]] = @signals.signal_ref([])
  let panel : Ref[@view.View?] = Ref(None)
  let t = level_size_tester(levels, panel, level_size_first(wide))
  level_size_steps(t, levels, panel)
}

///|
/// The share level pushed (`levels`, the menu's), its panel's sizes as level_size_run says them.
fn level_size_steps(
  t : @ui.Tester,
  levels : @signals.Signal[Array[MenuLevel]],
  panel : Ref[@view.View?],
) -> Array[(Double, Double)] raise {
  t.run_for(level_size_rest_ms)
  let size = fn() {
    let (_, _, w, h) = panel.val.unwrap().placed_window_now()
    (w, h)
  }
  let out = [size()]
  @view.transition(fn() {
    levels.set([
      {
        n: 1,
        title: "Share",
        kind: MenuItems(
          [
            Some(menu_item_of("Copy chat link", fn() {  }, icon="copy")),
            Some(menu_item_of("Relay to channel", fn() {  }, icon="arrow-up-right", further=true)),
            Some(menu_item_of("Share as image", fn() {  }, icon="image")),
          ],
          fn(_) { menu_no_extra },
        ),
        gone: fn() {  },
      },
    ])
  })
  t.run_for(level_size_mid_ms)
  out.push(size())
  t.run_for(level_size_settle_ms)
  out.push(size())
  t.back()
  t.run_for(level_size_mid_ms)
  out.push(size())
  t.run_for(level_size_settle_ms)
  assert_eq(size(), out[0], msg="back at rest on the first level as it stood")
  out
}

///|
fn level_size_text(s : Array[(Double, Double)]) -> String {
  let sb = StringBuilder()
  for x in s {
    sb.write_string("\{x.0}x\{x.1} ")
  }
  sb.to_string()
}

///|
fn level_size_between(x : Double, a : Double, b : Double) -> Bool {
  (x > a && x < b) || (x < a && x > b)
}

///|
test "menu panel goes its width and height both ways through a narrower submenu level" {
  defer {
    set_dark(None)
    presenters_reset()
  }
  let s = level_size_run(true)
  let (w0, h0) = s[0]
  let (w1, h1) = s[2]
  assert_true(w1 < w0 && h1 < h0, msg="the pushed level narrower and shorter: \{level_size_text(s)}")
  assert_true(level_size_between(s[1].0, w0, w1) && level_size_between(s[1].1, h0, h1), msg="on its way in, between: \{level_size_text(s)}")
  assert_true(level_size_between(s[3].0, w1, w0) && level_size_between(s[3].1, h1, h0), msg="on its way back, between: \{level_size_text(s)}")
}

///|
test "menu panel goes its width and height both ways through a wider submenu level" {
  defer {
    set_dark(None)
    presenters_reset()
  }
  let s = level_size_run(false)
  let (w0, h0) = s[0]
  let (w1, h1) = s[2]
  assert_true(w1 > w0 && h1 < h0, msg="the pushed level wider and shorter: \{level_size_text(s)}")
  assert_true(level_size_between(s[1].0, w0, w1) && level_size_between(s[1].1, h0, h1), msg="on its way in, between: \{level_size_text(s)}")
  assert_true(level_size_between(s[3].0, w1, w0) && level_size_between(s[3].1, h1, h0), msg="on its way back, between: \{level_size_text(s)}")
}

///|
/// A level as it comes back mid-slide: what the first level's rows have besides their items (a value at a row's end,
/// a note under its words) drawn by the picture that sizes the panel as by the rows, so the panel comes to rest as wide
/// as they make it without a snap at the end (sizes_steady); going in again and back while that slides, the level
/// that leaves drawn as itself.
test "menu panel comes back to a first level with values and notes, and goes back mid-slide, without a snap" {
  defer {
    set_dark(None)
    presenters_reset()
  }
  presenters_reset()
  let levels : @signals.Signal[Array[MenuLevel]] = @signals.signal_ref([])
  let panel : Ref[@view.View?] = Ref(None)
  let first = level_size_first(false)
  let t = level_size_tester(levels, panel, first, extras=fn(i) {
    if i == 0 {
      { note: "", value: "12 GB", mark: None, end: None }
    } else if i == 1 {
      { note: "正在迁入另一个会话", value: "", mark: None, end: None }
    } else {
      menu_no_extra
    }
  })
  let s = level_size_steps(t, levels, panel)
  assert_true(level_size_between(s[3].0, s[2].0, s[0].0), msg="on its way back: \{level_size_text(s)}")
  // (in again, and back before it is there: the level that leaves the one it went in to; in again after)
  @view.transition(fn() {
    levels.set([{ n: 2, title: "Share", kind: MenuItems([Some(menu_item_of("Copy chat link", fn() {  }))], fn(_) { menu_no_extra }), gone: fn() {  } }])
  })
  t.run_for(level_size_mid_ms)
  t.back()
  // (what slides out the level it was going in to, not the first level it left before)
  t.run_for(level_size_leaving_ms)
  assert_true(t.find("Copy chat link") is Some(_), msg="the level going out drawn as itself")
  t.run_for(level_size_settle_ms)
  @view.transition(fn() {
    levels.set([{ n: 3, title: "Share", kind: MenuItems([Some(menu_item_of("Copy chat link", fn() {  }))], fn(_) { menu_no_extra }), gone: fn() {  } }])
  })
  t.run_for(level_size_settle_ms)
  t.back()
  t.run_for(level_size_settle_ms)
  let (_, _, w, h) = panel.val.unwrap().placed_window_now()
  assert_eq((w, h), s[0], msg="back at rest on the first level as it stood")
  assert_true(t.find("12 GB") is Some(_) && t.find("正在迁入另一个会话") is Some(_))
}

///|
/// A level whose rows have a column before their words (here their icons): its head a row as they are, as far in and as
/// wide (concentric with the panel's corner as they are: the Tester's audit), its title where their words begin
/// (menu_back_row_node; before, a round `<` concentric with the corner stood 5 nearer the edge than their icons and
/// the title 4 further in than their words).
test "a submenu level's back and title stand on its rows' mark column and words" {
  defer {
    set_dark(None)
    presenters_reset()
  }
  presenters_reset()
  set_words(fn(key, _) { if key == "common.back" { "返回" } else { key } })
  let levels : @signals.Signal[Array[MenuLevel]] = @signals.signal_ref([])
  let panel : Ref[@view.View?] = Ref(None)
  let t = level_size_tester(levels, panel, level_size_first(true))
  t.run_for(level_size_rest_ms)
  @view.transition(fn() {
    levels.set([
      {
        n: 1,
        title: "迁到",
        kind: MenuItems(
          [Some(menu_item_of("Maple", fn() {  }, icon="server")), Some(menu_item_of("Cedar", fn() {  }, icon="server"))],
          fn(_) { menu_no_extra },
        ),
        gone: fn() {  },
      },
    ])
  })
  t.run_for(level_size_settle_ms)
  let back = t.get(Button, label="返回")
  let row = t.get(MenuItem, label="Maple")
  assert_true((back.rect.0 - row.rect.0).abs() < 0.5 && (back.rect.2 - row.rect.2).abs() < 0.5, msg="back at \{back.rect.0} \{back.rect.2} wide, a row at \{row.rect.0} \{row.rect.2} wide")
  let word_x = fn(s : String) {
    match t.words().iter().find_first(fn(w) { w.0 == s }) {
      Some(w) => w.1
      None => -1.0
    }
  }
  let row_words = word_x("Maple")
  assert_true(row_words > 0.0 && (word_x("迁到") - row_words).abs() < 0.5, msg="title \{word_x("迁到")}, rows' words \{row_words}")
  assert_eq(t.audit(), [])
  // (back on the first level, pressed: its rows again)
  t.click(Button, label="返回")
  t.run_for(level_size_settle_ms)
  assert_true(t.find("Rename") is Some(_))
}

///|
test "inline confirm level: right edge (200pt room) locks side with smooth position, narrow 320pt, short scrolling window, 1.3x font scale, long path + warning, and >= 4.5 contrast" {
  defer {
    set_dark(None)
    presenters_reset()
  }
  // 1) Right edge with ~200pt room: expanding from narrow menu to 280pt confirm must stay on Right without flipping to Left,
  //    and push -> back -> mid-slide reversal must stay steady (no snap or side flip)
  presenters_reset()
  let cancel_label = t("common.cancel")
  let back_label = t("common.back")
  let levels : @signals.Signal[Array[MenuLevel]] = @signals.signal_ref([])
  let panel : Ref[@view.View?] = Ref(None)
  let t = @ui.Tester::new(fn(_c) {  }, w=800.0, h=600.0, dark=false, platform=0)
  set_dark(Some(false))
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    let btn_ref : Ref[@view.View?] = Ref(None)
    root.box(fn(page) {
      page.grow(Is(1.0)).ground(By(fn() { theme().p.bg })) |> ignore
      // Anchor at x=520, w=80 -> right edge at 600 -> 200pt room on Right, 520pt room on Left
      let btn = page.box(fn(o) {
        o
        .over(Is(true))
        .offset(Is((520.0, 480.0)))
        .width(Is(Some(80.0)))
        .height(Is(Some(36.0)))
        .presses(Is(true))
        .says(Is(Some(@view.said(Button, label="More"))))
        |> ignore
      })
      btn_ref.val = Some(btn)
    })
    |> ignore
    root.box(fn(l) {
      l.over(Is(true)) |> ignore
      menu_node_by(
        l,
        fn() { true },
        fn(_) { btn_ref.val.unwrap() },
        fn() { [Some(menu_item_of("编辑", fn() {  })), Some(menu_item_of("删除", fn() {  }, danger=true))] },
        "",
        Start,
        panel_offset,
        false,
        false,
        fn(_) {  },
        fn() {  },
        side=Right,
        false,
        sub_levels=fn() { levels.get() },
        level_back=fn() {
          let now = levels.untracked()
          if now.is_empty() {
            false
          } else {
            @view.transition(fn() { levels.set(now[:now.length() - 1].to_owned()) })
            true
          }
        },
        panel_ref=panel,
      )
    })
    |> ignore
  })
  t.draw()
  t.run_for(level_size_rest_ms)
  let (x0, y0, w0, h0) = panel.val.unwrap().placed_window_now()
  assert_true(x0 >= 600.0, msg="initial menu sits on Right side: x0=\{x0}")
  let push_confirm = fn(n : Int) {
    @view.transition(fn() {
      levels.set([
        {
          n,
          title: "删除预设「Production API Gateway Configuration」？",
          kind: MenuConfirmLevel({
            words: "删除后不会影响已经创建的对话记录，但该预设配置无法恢复。",
            warning: "同时移除关联的快捷入口。",
            action: "删除",
            danger: true,
            run: fn() {  },
            facts: [],
          }),
          gone: fn() {  },
        },
      ])
    })
  }
  push_confirm(1)
  // Step frame-by-frame on push: sizes_steady + no horizontal/vertical side-flip jump
  let mut prev_x = x0
  let mut prev_y = y0
  for _ in 0..<24 {
    t.run_for(@ui.frame_period_default)
    let (nx, ny, nw, _) = panel.val.unwrap().placed_window_now()
    assert_true((nx - prev_x).abs() < 60.0, msg="no horizontal side-flip jump on push: \{prev_x} -> \{nx}")
    assert_true((ny - prev_y).abs() < 40.0, msg="no vertical side-flip jump on push: \{prev_y} -> \{ny}")
    assert_true(nx + nw <= 800.0 - 7.0, msg="clamped within right viewport edge: x=\{nx} w=\{nw}")
    prev_x = nx
    prev_y = ny
  }
  t.run_for(level_size_settle_ms)
  let (xf, yf, wf, hf) = panel.val.unwrap().placed_window_now()
  assert_true(wf > w0 && wf <= 297.0, msg="expanded to confirm width: \{wf}")
  assert_true(xf >= 490.0 && xf + wf <= 800.0 - 7.0, msg="stayed on right side clamped in viewport: x=\{xf} w=\{wf}")
  assert_true(yf >= 0.0 && yf + hf <= 600.0, msg="within vertical bounds")
  assert_eq(t.audit(), [])
  // Back to root menu: verify smooth return without jump
  t.back()
  prev_x = xf
  prev_y = yf
  for _ in 0..<24 {
    t.run_for(@ui.frame_period_default)
    let (nx, ny, _, _) = panel.val.unwrap().placed_window_now()
    assert_true((nx - prev_x).abs() < 60.0, msg="no horizontal jump on back: \{prev_x} -> \{nx}")
    assert_true((ny - prev_y).abs() < 40.0, msg="no vertical jump on back: \{prev_y} -> \{ny}")
    prev_x = nx
    prev_y = ny
  }
  t.run_for(level_size_settle_ms)
  let (_, _, wb, hb) = panel.val.unwrap().placed_window_now()
  assert_eq((wb, hb), (w0, h0), msg="returned cleanly to initial menu size")
  // Mid-slide reversal: push confirm -> back mid-slide -> settle cleanly without snap
  push_confirm(2)
  t.run_for(level_size_mid_ms)
  t.back()
  let (mx, my, _, _) = panel.val.unwrap().placed_window_now()
  prev_x = mx
  prev_y = my
  for _ in 0..<24 {
    t.run_for(@ui.frame_period_default)
    let (nx, ny, _, _) = panel.val.unwrap().placed_window_now()
    assert_true((nx - prev_x).abs() < 60.0, msg="no horizontal jump on mid-slide reversal: \{prev_x} -> \{nx}")
    assert_true((ny - prev_y).abs() < 40.0, msg="no vertical jump on mid-slide reversal: \{prev_y} -> \{ny}")
    prev_x = nx
    prev_y = ny
  }
  t.run_for(level_size_settle_ms)
  assert_eq(panel.val.unwrap().placed_window_now().2, w0, msg="mid-slide reversal settles at root width")

  // 2) Short narrow window (320x220) + 1.3x font scale + very long multi-line title + warning:
  //    header+body scroll smoothly while footer [Cancel, Delete] stays permanently visible & clickable
  presenters_reset()
  let deleted = Ref(0)
  let cancelled = Ref(0)
  let levels2 : @signals.Signal[Array[MenuLevel]] = @signals.signal_ref([
    {
      n: 1,
      title: "删除预设「Production API Gateway Cluster Configuration & Staging Routing Profile」？",
      kind: MenuConfirmLevel({
        words: "删除后不会影响已经创建的对话记录，但该预设配置无法恢复。此说明刻意拉长以验证短窗口内标题与正文共用滚动区而底部按钮固定可见且可点击。",
        warning: "同时移除关联的快捷入口与默认工作区绑定。",
        action: "删除",
        danger: true,
        run: fn() { deleted.val += 1 },
        facts: [],
      }),
      gone: fn() {  },
    },
  ])
  let panel2 : Ref[@view.View?] = Ref(None)
  let t2 = @ui.Tester::new(fn(_c) {  }, w=320.0, h=220.0, dark=false, platform=0)
  t2.set_font_scale(1.3)
  set_dark(Some(false))
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    let btn_ref : Ref[@view.View?] = Ref(None)
    root.box(fn(page) {
      page.grow(Is(1.0)).ground(By(fn() { theme().p.bg })) |> ignore
      let btn = page.box(fn(o) {
        o
        .over(Is(true))
        .offset(Is((16.0, 16.0)))
        .width(Is(Some(60.0)))
        .height(Is(Some(32.0)))
        .presses(Is(true))
        .says(Is(Some(@view.said(Button, label="More"))))
        |> ignore
      })
      btn_ref.val = Some(btn)
    })
    |> ignore
    root.box(fn(l) {
      l.over(Is(true)) |> ignore
      menu_node_by(
        l,
        fn() { true },
        fn(_) { btn_ref.val.unwrap() },
        fn() { [Some(menu_item_of("编辑", fn() {  }))] },
        "",
        Start,
        panel_offset,
        false,
        false,
        fn(_) {  },
        fn() { cancelled.val += 1 },
        false,
        sub_levels=fn() { levels2.get() },
        level_back=fn() {
          let now = levels2.untracked()
          if now.is_empty() {
            false
          } else {
            @view.transition(fn() { levels2.set(now[:now.length() - 1].to_owned()) })
            true
          }
        },
        panel_ref=panel2,
      )
    })
    |> ignore
  })
  t2.draw()
  t2.run_for(level_size_rest_ms)
  let del_btn = t2.get(Button, label="删除")
  let cancel_btn = t2.get(Button, label=cancel_label)
  assert_true(del_btn.rect.1 + del_btn.rect.3 <= 220.0, msg="confirm action button stays visible in short window: \{Repr(del_btn.rect)}")
  assert_true(cancel_btn.rect.1 + cancel_btn.rect.3 <= 220.0, msg="cancel button stays visible in short window: \{Repr(cancel_btn.rect)}")
  // Scroll inside the header+body scroll region, assert real scroll displacement, click Cancel & Delete, then Back
  let back_y_before = t2.get(Button, label=back_label).rect.1
  let (px, py, pw, _) = panel2.val.unwrap().placed_window_now()
  t2.wheel(px + pw / 2.0, py + 40.0, 80.0)
  t2.run_for(level_size_rest_ms)
  let back_y_after = t2.get(Button, label=back_label).rect.1
  assert_true(back_y_after < back_y_before - 10.0, msg="scroll moved content upward: \{back_y_before} -> \{back_y_after}")
  t2.click(Button, label=cancel_label)
  t2.click(Button, label="删除")
  assert_eq(cancelled.val, 1, msg="cancel button clickable in short window with long title")
  assert_eq(deleted.val, 1, msg="delete button clickable in short window with long title")
  assert_eq(t2.audit(), [])
  // Back from scrolled confirm state: leaving snapshot preserves scrolled y offset on frame 1 (does not jump to top)
  let warn_y_before = t2.words().iter().find_first(fn(w) { w.0.contains("同时移除关联的快捷入口") }).unwrap().2
  t2.back()
  t2.frame()
  let warn_y_leaving = t2.words().iter().find_first(fn(w) { w.0.contains("同时移除关联的快捷入口") }).unwrap().2
  assert_true(
    (warn_y_leaving - warn_y_before).abs() <= 2.0,
    msg="leaving confirm snapshot preserves scrolled vertical position: \{warn_y_before} -> \{warn_y_leaving}",
  )
  t2.run_for(level_size_settle_ms)
  assert_true(t2.find("编辑") is Some(_), msg="Back from scrolled confirm returns to menu")

  // 2b) Real pill_morph capsule anchor (`bar_pill_group_node`): draw first so pill layout completes before opening
  //     the menu via click (hits the live liquid-pill morph branch), then push confirm and assert zero frame-0 jump
  presenters_reset()
  let pill_open = @signals.signal(false)
  let pill_levels : @signals.Signal[Array[MenuLevel]] = @signals.signal_ref([])
  let pill_panel : Ref[@view.View?] = Ref(None)
  let tp = @ui.Tester::new(fn(_c) {  }, w=800.0, h=600.0, dark=false, platform=0)
  set_dark(Some(false))
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    let trig_ref : Ref[@view.View?] = Ref(None)
    root.box(fn(page) {
      page.grow(Is(1.0)).ground(By(fn() { theme().p.bg })) |> ignore
      page.box(fn(bar) {
        bar.over(Is(true)).offset(Is((580.0, 48.0))).row(Is(true)) |> ignore
        bar_pill_group_node(bar, height=36.0, pad=2.0, gap=2.0, fn(g) {
          icon_button_node(g, "search", fn() { "搜索" }, fn() {  }) |> ignore
          let b = icon_button_node(g, "more", fn() { "更多" }, fn() { pill_open.set(true) })
          trig_ref.val = Some(b)
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
    root.box(fn(l) {
      l.over(Is(true)) |> ignore
      menu_node_by(
        l,
        fn() { pill_open.get() },
        fn(_) { trig_ref.val.unwrap() },
        fn() { [Some(menu_item_of("编辑", fn() {  })), Some(menu_item_of("删除", fn() {  }, danger=true))] },
        "",
        End,
        panel_offset,
        false,
        false,
        fn(_) {  },
        fn() { pill_open.set(false) },
        side=Bottom,
        false,
        sub_levels=fn() { pill_levels.get() },
        level_back=fn() {
          let now = pill_levels.untracked()
          if now.is_empty() {
            false
          } else {
            @view.transition(fn() { pill_levels.set(now[:now.length() - 1].to_owned()) })
            true
          }
        },
        panel_ref=pill_panel,
      )
    })
    |> ignore
  })
  tp.draw()
  tp.click(Button, label="更多")
  tp.run_for(level_size_rest_ms)
  let (px0, py0, pw0, _) = pill_panel.val.unwrap().placed_window_now()
  @view.transition(fn() {
    pill_levels.set([
      {
        n: 1,
        title: "删除预设「默认开发配置」？",
        kind: MenuConfirmLevel({ words: "已经用它开的对话不受影响。", warning: "", action: "删除", danger: true, run: fn() {  }, facts: [] }),
        gone: fn() {  },
      },
    ])
  })
  // First frame after transition must keep right edge pinned (`along=End`) and vertical origin exact (zero δ jump)
  tp.frame()
  let (px1, py1, pw1, _) = pill_panel.val.unwrap().placed_window_now()
  assert_true(
    ((px1 + pw1) - (px0 + pw0)).abs() < 0.5 && (py1 - py0).abs() < 0.5 && (px1 - px0).abs() < 15.0,
    msg="pill_morph first-frame smooth expansion with zero jump: (\{px0}, \{py0}, \{pw0}) -> (\{px1}, \{py1}, \{pw1})",
  )
  tp.run_for(level_size_settle_ms)
  tp.back()
  tp.run_for(level_size_settle_ms)
  assert_eq(tp.audit(), [])

  // 3) Contrast >= 4.5:1 for warning ink on light glass (#F5F5F7), dark glass (#4F5053), and solid panel grounds
  set_dark(Some(false))
  let light_warn = menu_confirm_warning_ink()
  let light_solid_bg = panel_ground()
  assert_true(@ui.contrast_ratio(light_warn, 0xF5F5F7FFL) >= 4.5, msg="light glass warning contrast >= 4.5")
  assert_true(@ui.contrast_ratio(light_warn, light_solid_bg) >= 4.5, msg="light solid warning contrast >= 4.5")
  set_dark(Some(true))
  let dark_warn = menu_confirm_warning_ink()
  let dark_solid_bg = panel_ground()
  assert_true(@ui.contrast_ratio(dark_warn, 0x4F5053FFL) >= 4.5, msg="dark glass warning contrast >= 4.5")
  assert_true(@ui.contrast_ratio(dark_warn, dark_solid_bg) >= 4.5, msg="dark solid warning contrast >= 4.5")
}

///|
test "menu_node_by and pick_node opened Left/Right from inside a floating panel align to host outer edge with floating_surface_gap (8pt)" {
  defer {
    set_dark(None)
    presenters_reset()
  }
  // 1) panel_nodes -> button -> menu(..., side=Right) -> inline confirm: exact 8pt outer-to-outer gap on both levels
  presenters_reset()
  set_dark(Some(false))
  let t = @ui.Tester::new(fn(_c) {  }, w=1000.0, h=700.0, dark=false, platform=0)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(page) {
      page.grow(Is(1.0)).ground(By(fn() { theme().p.bg })).padding(Is((100.0, 100.0, 0.0, 0.0))) |> ignore
      button_opens_node(page, fn() { "打开面板" }, fn(from) {
        panel_nodes(
          "预设列表",
          fn(body, _) {
            body.gap(Is(8.0)).padding(Is((8.0, 0.0, 8.0, 8.0))) |> ignore
            button_opens_node(body, fn() { "更多操作" }, fn(btn) {
              menu(
                [
                  Some(menu_item_of("编辑", fn() {  })),
                  Some(
                    menu_item_of(
                      "删除",
                      fn() { confirm("删除预设？", "删除后不可恢复。", "删除", danger=true, fn() {  }) },
                      danger=true,
                      further=true,
                    ),
                  ),
                ],
                from=Node(btn),
                side=Right,
              )
            })
            |> ignore
            button_opens_node(body, fn() { "选择目标" }, fn(btn) {
              let choices : Array[Choice] = []
              for i in 0..<12 {
                choices.push(choice("k\{i}", "选项 \{i}"))
              }
              pick("目标列表", choices, "k0", fn(_) {  }, from=Node(btn), side=Right)
            })
            |> ignore
          },
          from=Node(from),
          w=260.0,
        )
      })
      |> ignore
    })
    |> ignore
    presented_nodes(root)
  })
  t.draw()
  t.click(Button, label="打开面板")
  t.run_for(level_size_settle_ms)
  let host_rect = t.get(Dialog, label="预设列表").rect
  let host_right = host_rect.0 + host_rect.2
  // Open menu side=Right from inside the floating panel
  t.click(Button, label="更多操作")
  t.run_for(level_size_settle_ms)
  let menu_rect = t.get(Menu, label="").rect
  let gap_menu = menu_rect.0 - host_right
  assert_true(
    (gap_menu - floating_surface_gap).abs() <= 0.5,
    msg="menu opened Right inside panel_node must keep floating_surface_gap (8pt): host_right=\{host_right}, menu_left=\{menu_rect.0}, gap=\{gap_menu}",
  )
  // Push inline confirm level: gap must stay exactly 8pt
  t.tap_text("删除")
  t.run_for(level_size_settle_ms)
  let confirm_rect = t.get(Dialog, label="删除预设？").rect
  let gap_confirm = confirm_rect.0 - host_right
  assert_true(
    (gap_confirm - floating_surface_gap).abs() <= 0.5,
    msg="inline confirm level must keep floating_surface_gap (8pt): host_right=\{host_right}, confirm_left=\{confirm_rect.0}, gap=\{gap_confirm}",
  )
  assert_true(
    (confirm_rect.2 - menu_confirm_w).abs() <= 0.5,
    msg="inline confirm width at 1.0x words_scale must stay 296pt: \{confirm_rect.2}",
  )
  // At 1.3x words_scale in a wide window, confirm width scales proportionally up to submenu_max_w (380pt)
  t.set_font_scale(1.3)
  t.run_for(level_size_settle_ms)
  let confirm_rect_130 = t.get(Dialog, label="删除预设？").rect
  assert_true(
    (confirm_rect_130.2 - submenu_max_w).abs() <= 0.5,
    msg="inline confirm width at 1.3x words_scale must scale to submenu_max_w (380pt): \{confirm_rect_130.2}",
  )
  t.set_font_scale(1.0)
  t.run_for(level_size_settle_ms)
  t.key(@ui.key_escape)
  t.run_for(level_size_settle_ms)
  // 2) Long pick (>= 10 items, uses pick_node) opened side=Right from inside the same floating panel: exact 8pt gap
  t.click(Button, label="选择目标")
  t.run_for(level_size_settle_ms)
  let pick_rect = t.get(Dialog, label="目标列表").rect
  let gap_pick = pick_rect.0 - host_right
  assert_true(
    (gap_pick - floating_surface_gap).abs() <= 0.5,
    msg="long pick_node opened Right inside panel_node must keep floating_surface_gap (8pt): host_right=\{host_right}, pick_left=\{pick_rect.0}, gap=\{gap_pick}",
  )
  assert_eq(t.audit(), [])
}
