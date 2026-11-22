// A page made once laid out wide (page_wide_node.mbt): its sections, groups and rows drawn as page.mbt draws them wide;
// its arrangement by the width it is given, made again only as that arrangement changes, lent to what is made in it
// later as well.

///|
/// What the wide page draws outside its switch controls, rounded to a hundredth and sorted.
fn wide_drawn(t : @ui.Tester) -> Array[String] raise {
  t.draw()
  let usage = t.get(Switch, label="发送使用统计")
  let performance = t.get(Switch, label="性能记录")
  assert_true(usage.check is Some(On))
  assert_true(performance.check is Some(Off))
  let switches = [usage.rect, performance.rect]
  // Switch paint has its own tests. Compare the rest of the wide page at both text sizes.
  let all = t.drawn_instances_keyed().filter(fn(a) {
    !switches.iter().any(fn(rect) {
      let (x, y, w, h) = rect
      a[0] >= x && a[1] >= y && a[0] + a[2] <= x + w && a[1] + a[3] <= y + h
    })
  }).map(fn(a) {
    a
    .mapi(fn(j, x) {
      if a[5] == 1.0 && j == 12 {
        if x >= 16384.0 { "colour" } else { "mono" }
      } else if a[5] == 1.0 && j == 13 {
        "-"
      } else {
        ((x * 100.0).round() / 100.0).to_string()
      }
    })
    .join(",")
  })
  all.sort()
  all
}

///|
/// 关于's blocks on a wide page, 760 wide (a lane's column less its blocks' room), at the system's size of words
/// `scale`: as nodes, each a section of its own titled (heads false: a wide page's title all the same), a list's rows,
/// a card of words with a switch, a list's switch and a row that acts.
fn about_blocks_drawn(scale : Double) -> Array[String] raise {
  let t = @ui.Tester::new(fn(_c) {  }, w=760.0, h=900.0)
  t.set_font_scale(scale)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.lends(part_at, { look: Wide, section: false, list: false, card: false }) |> ignore
      section_node(b, fn() { "版本" }, heads=false, fn(s) {
        group_node(s, fn(g) {
          link_row_node(g, fn() { "still.fail 1.0" }, fn() {  }, goes=false)
          link_row_node(g, fn() { "检查更新" }, fn() {  }, note=fn() { "已是最新版本" }, chevron=false)
          link_row_node(g, fn() { "更新日志" }, fn() {  })
        })
      })
      section_node(b, fn() { "隐私" }, heads=false, fn(s) {
        group_node(s, card=true, fn(g) {
          switch_row_node(g, fn() { "发送使用统计" }, fn() { true }, fn(_) {  }, note=fn() { "帮助改进 still.fail" })
        })
      })
      section_node(b, fn() { "法律" }, heads=false, fn(s) {
        group_node(s, fn(g) { link_row_node(g, fn() { "服务条款" }, fn() {  }, out=true) })
      })
      section_node(b, fn() { "诊断" }, heads=false, fn(s) {
        group_node(s, fn(g) {
          switch_row_node(g, fn() { "性能记录" }, fn() { false }, fn(_) {  }, note=fn() { "保存在本机" })
          link_row_node(g, fn() { "分享记录" }, fn() {  }, acts=true)
        })
      })
    })
    |> ignore
  })
  wide_drawn(t)
}

///|
test "关于 on a wide page keeps the switches' states and draws the blocks around them at text sizes 1 and 2" {
  for scale in [1.0, 2.0] {
    let made = about_blocks_drawn(scale)
    assert_true(made.length() > 0, msg="at \{scale}")
  }
}

///|
test "a page made once by the width it is given: made again only as its arrangement changes (wide to narrow), not as it widens or narrows within one; what is shown in it later laid out as the page is then" {
  let _t = @ui.Tester::new(fn(_c) {  }, w=900.0, h=700.0)
  let width = @signals.signal(900.0)
  let shown = @signals.signal(false)
  let made : Array[Look] = []
  let later : Array[Look] = []
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.height(Is(Some(700.0))) |> ignore
      page_node(
        b,
        fn() { "关于" },
        fn() { ["a"] },
        fn(v, _k) {
          made.push(look_node(v))
          v.show(fn() { shown.get() }, fn(s) { later.push(look_node(s)) })
        },
        on_back=fn() {  },
        width=fn() { width.get() },
      )
    })
    |> ignore
  })
  _t.draw()
  assert_true(made == [Wide])
  // (narrower, wide still: nothing made again)
  width.set(700.0)
  _t.draw()
  assert_true(made == [Wide])
  // (shown later: as the page is laid out)
  shown.set(true)
  _t.draw()
  assert_true(later == [Wide])
  // (narrow now: made again, narrow, what shows in it as well)
  width.set(500.0)
  _t.draw()
  assert_true(made == [Wide, Narrow])
  assert_true(later == [Wide, Narrow])
}

///|
test "a wide panel's list card holds a one-line setting's control out of its corners at its first and last rows" {
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w=760.0, h=400.0)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.lends(pane_lent, true).lends(part_at, { look: Wide, section: false, list: false, card: false }) |> ignore
      group_node(b, fn(g) {
        setting_choice_node(g, fn() { "语言" }, fn() { ["跟随系统", "中文", "English"] }, fn() { 0 }, fn(_) {  })
      })
    })
    |> ignore
  })
  t.draw()
  assert_eq(t.corner_faults(), [])
}
