// A row said in parts (row_compound_node.mbt: row_box_node and its RowScope) drawn as link_row_node draws the same row,
// instance for instance: narrow (390, a card's rows) and wide (1280, a list's), at the system's size of words 1 and
// 1.3, with keyboard and mouse and with a finger; every one of them clear of the audit, the corner rule, the first
// line rule and words giving way beside others. Pressed it does what it is given; busy, nothing.

///|
/// The rows each way: a value said and going nowhere; one that acts; one that acts with a note and a bar below it; one
/// that goes somewhere; one out of the app; one by an icon with a note of lines; one with a value in amber and a dot;
/// one that takes away, busy. `compound`: said in parts (row_box_node), else link_row_node's.
fn compound_rows(g : @view.View, compound : Bool) -> Unit {
  let bar = fn(b : @view.View) {
    b.box(fn(p) {
      p.grow(Is(1.0)) |> ignore
      progress_node(p, fn() { Some(0.4) }, fn() { @ui.tree_theme().line }, fn() { theme().p.accent }) |> ignore
    })
    |> ignore
  }
  let long_note = fn() { "下载完成后会在下次打开时自动安装，安装前不会打断正在进行的对话" }
  if compound {
    row_box_node(g, fn() { "still.fail 1.0.42" }, fn(_) {  })
    row_box_node(g, fn() { "检查更新" }, press=fn() {  }, fn(row) { row.title(tone=RowAccent) })
    row_box_node(g, fn() { "正在下载 1.0.43" }, press=fn() {  }, fn(row) {
      row.title(tone=RowAccent)
      row.note(fn() { "已下载 40%" })
      row.below(bar)
    })
    row_box_node(g, fn() { "更新日志" }, press=fn() {  }, fn(row) { row.chevron() })
    row_box_node(g, fn() { "服务条款" }, press=fn() {  }, fn(row) { row.chevron(kind=ChevronOut) })
    row_box_node(g, fn() { "Station" }, press=fn() {  }, fn(row) {
      row.icon("server")
      row.note(long_note)
      row.chevron()
    })
    row_box_node(g, fn() { "证书" }, press=fn() {  }, fn(row) {
      row.value(fn() { "3 天后过期" }, tone=NoteWarn, dot=fn() { true })
      row.chevron()
    })
    row_box_node(g, fn() { "删除这台设备" }, press=fn() {  }, busy=fn() { true }, fn(row) { row.title(tone=RowDanger) })
  } else {
    link_row_node(g, fn() { "still.fail 1.0.42" }, fn() {  }, goes=false)
    link_row_node(g, fn() { "检查更新" }, fn() {  }, acts=true)
    link_row_node(g, fn() { "正在下载 1.0.43" }, fn() {  }, note=fn() { "已下载 40%" }, acts=true, below=bar, below_open=fn() {
      1.0
    })
    link_row_node(g, fn() { "更新日志" }, fn() {  })
    link_row_node(g, fn() { "服务条款" }, fn() {  }, out=true)
    link_row_node(g, fn() { "Station" }, fn() {  }, note=long_note, lead=LeadIcon("server"))
    link_row_node(g, fn() { "证书" }, fn() {  }, value=fn() { "3 天后过期" }, value_warn=fn() { true }, value_dot=fn() {
      true
    })
    link_row_node(g, fn() { "删除这台设备" }, fn() {  }, danger=true, chevron=false, busy=fn() { true })
  }
}

///|
/// A window `wide` (1280, a list's rows) or narrow (390, a card's), with keyboard and mouse (platform 0) or a finger
/// (platform 2), its words at `scale`, holding compound_rows' rows on a group: its Tester, drawn.
fn compound_case(compound : Bool, wide : Bool, platform : Int, scale : Double) -> @ui.Tester {
  presenters_reset()
  let t = @ui.Tester::new(fn(_c) {  }, w=if wide { 1280.0 } else { 390.0 }, h=900.0, platform~)
  t.set_font_scale(scale)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      if wide {
        b.lends(part_at, { look: Wide, section: false, list: false, card: false }) |> ignore
        section_node(b, fn() { "版本" }, heads=false, fn(s) { group_node(s, fn(g) { compound_rows(g, compound) }) })
      } else {
        page_block(b, fn(room) { group_node(room, fn(g) { compound_rows(g, compound) }) })
      }
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// What is drawn, each instance's numbers rounded to a hundredth (a glyph's place in its atlas left out), in one order.
fn compound_drawn(t : @ui.Tester) -> Array[String] {
  let all = t.drawn_instances_keyed().map(fn(a) {
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
test "rows said in parts are drawn as link_row_node's, narrow and wide, mouse and finger, words 1 and 1.3, every rule kept" {
  for wide in [false, true] {
    for platform in [0, 2] {
      for scale in [1.0, 1.3] {
        let at = "wide \{wide} platform \{platform} scale \{scale}"
        let old = compound_drawn(compound_case(false, wide, platform, scale))
        let t = compound_case(true, wide, platform, scale)
        let now = compound_drawn(t)
        let only_old = old.filter(fn(x) { !now.contains(x) })
        let only_now = now.filter(fn(x) { !old.contains(x) })
        assert_eq(now, old, msg="\{at}\nonly link_row_node's:\n\{only_old.join("\n")}\nonly row_box_node's:\n\{only_now.join("\n")}")
        assert_eq(t.audit(), [], msg=at)
        assert_eq(t.corner_faults(), [], msg=at)
        assert_eq(t.first_line_faults(), [], msg=at)
        assert_eq(t.beside_faults(), [], msg=at)
      }
    }
  }
}

///|
test "an icon before a row's title stays on its first line as its note takes lines under it" {
  let t = compound_case(true, false, 2, 1.3)
  let (_, ty, _, th) = t.rect_of("Station").unwrap()
  let (_, ny, _, nh) = t.rect_of("下载完成后会在下次打开时自动安装，安装前不会打断正在进行的对话").unwrap()
  assert_true(nh > th * 1.5, msg="the note on lines of its own: \{nh} against \{th}")
  assert_true(ny >= ty + th - 0.5, msg="the note under the title")
  assert_eq(t.first_line_faults(), [])
}

///|
test "a row said in parts: pressed, it does what it is given; busy, nothing until it is not; given no press, read out as no link" {
  let busy = @signals.signal(true)
  let done = Ref(0)
  let gone = Ref(0)
  let narrow = Ref(false)
  let under = Ref(true)
  presenters_reset()
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=400.0, platform=2)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      page_block(b, fn(room) {
        group_node(room, fn(g) {
          row_box_node(g, fn() { "更新日志" }, press=fn() { gone.val += 1 }, fn(row) {
            narrow.val = row.narrow
            row.chevron()
          })
          row_box_node(g, fn() { "删除这台设备" }, press=fn() { done.val += 1 }, busy=fn() { busy.get() }, fn(row) {
            row.title(tone=RowDanger)
          })
          row_box_node(g, fn() { "still.fail 1.0.42" }, fn(row) { under.val = row.has_under() })
        })
      })
    })
    |> ignore
  })
  t.draw()
  assert_true(narrow.val)
  assert_true(!under.val)
  t.tap_text("更新日志")
  t.run_for(@ui.move_most_ms)
  assert_eq(gone.val, 1)
  t.tap_text("删除这台设备")
  t.run_for(@ui.move_most_ms)
  assert_eq(done.val, 0)
  busy.set(false)
  t.draw()
  t.tap_text("删除这台设备")
  t.run_for(@ui.move_most_ms)
  assert_eq(done.val, 1)
  assert_true(t.query(Link, label="更新日志") is Some(_))
  assert_true(t.query(Link, label="still.fail 1.0.42") is None)
}
