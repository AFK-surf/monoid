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
  levels : @signals.Signal[Array[(Int, String, Array[MenuItem?])]],
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
  let levels : @signals.Signal[Array[(Int, String, Array[MenuItem?])]] = @signals.signal_ref([])
  let panel : Ref[@view.View?] = Ref(None)
  let t = level_size_tester(levels, panel, level_size_first(wide))
  level_size_steps(t, levels, panel)
}

///|
/// The share level pushed (`levels`, the menu's), its panel's sizes as level_size_run says them.
fn level_size_steps(
  t : @ui.Tester,
  levels : @signals.Signal[Array[(Int, String, Array[MenuItem?])]],
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
      (
        1,
        "Share",
        [
          Some(menu_item_of("Copy chat link", fn() {  }, icon="copy")),
          Some(menu_item_of("Relay to channel", fn() {  }, icon="arrow-up-right", further=true)),
          Some(menu_item_of("Share as image", fn() {  }, icon="image")),
        ],
      ),
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
  let levels : @signals.Signal[Array[(Int, String, Array[MenuItem?])]] = @signals.signal_ref([])
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
  @view.transition(fn() { levels.set([(2, "Share", [Some(menu_item_of("Copy chat link", fn() {  }))])]) })
  t.run_for(level_size_mid_ms)
  t.back()
  // (what slides out the level it was going in to, not the first level it left before)
  t.run_for(level_size_leaving_ms)
  assert_true(t.find("Copy chat link") is Some(_), msg="the level going out drawn as itself")
  t.run_for(level_size_settle_ms)
  @view.transition(fn() { levels.set([(3, "Share", [Some(menu_item_of("Copy chat link", fn() {  }))])]) })
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
  let levels : @signals.Signal[Array[(Int, String, Array[MenuItem?])]] = @signals.signal_ref([])
  let panel : Ref[@view.View?] = Ref(None)
  let t = level_size_tester(levels, panel, level_size_first(true))
  t.run_for(level_size_rest_ms)
  @view.transition(fn() {
    levels.set([
      (
        1,
        "迁到",
        [Some(menu_item_of("Maple", fn() {  }, icon="server")), Some(menu_item_of("Cedar", fn() {  }, icon="server"))],
      ),
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
