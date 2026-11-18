// The library's quiet cards (agent_stats_node.mbt): their rows' labels in one column as wide as the widest, a label and
// a chevron on their value's first line where a line goes under it, a row pressed doing what it does; the stats card
// not there while it says nothing, a part coming later opening its room.

///|
/// A window with keyboard and mouse holding what `make` makes, 420 wide.
fn u13_case(make : (@view.View) -> Unit) -> @ui.Tester {
  presenters_reset()
  let t = @ui.Tester::new(fn(_c) {  }, w=420.0, h=600.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) { make(root) })
  t.draw()
  t
}

///|
// kept across runs: a value (no field of it changes)
let u13_value : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let u13_under : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted)

///|
/// A quiet row in `k` as a page makes one: its label in the column, its value (and a line under it, `under`), its
/// chevron on the value's first line; pressed, `press`.
fn u13_row(k : @view.View, label : String, value : String, across : () -> Double, under? : String = "", press : () -> Unit) -> Unit {
  let look = if under != "" { quiet_row_top } else { quiet_row_middle }
  quiet_row_node(k, fn() { label + " " + value }, look~, press~, fn(row) {
    row_label_node(row, label, across)
    row.box(fn(w) {
      w.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      words_node(w, fn() { value }, fn() { u13_value }) |> ignore
      if under != "" {
        words_node(w, fn() { under }, fn() { u13_under }) |> ignore
      }
    })
    |> ignore
    row.box(fn(c) {
      quiet_first_line(c)
      row_chevron_node(c)
    })
    |> ignore
  })
  |> ignore
}

///|
test "a quiet card: its values start in one column past the widest label, its label on its value's first line" {
  let pressed = Ref("")
  let labels = ["账号", "一个很长的标签"]
  let t = u13_case(fn(root) {
    quiet_card_node(root, fn(k) {
      let across = fn() { labels_across(k, labels) }
      u13_row(k, labels[0], "甲", across, under="本周还剩 62%", fn() { pressed.val = "账号" })
      u13_row(k, labels[1], "乙", across, fn() { pressed.val = "长" })
    })
  })
  let (ax, ay, _, ah) = t.rect_of("甲").unwrap()
  let (bx, _, _, _) = t.rect_of("乙").unwrap()
  let (lx, _, lw, _) = t.rect_of("一个很长的标签").unwrap()
  let (_, ly, _, lh) = t.rect_of("账号").unwrap()
  let (_, uy, _, _) = t.rect_of("本周还剩 62%").unwrap()
  assert_eq(ax, bx)
  assert_true(ax >= lx + lw, msg="\{ax} \{lx} \{lw}")
  // (the label on the value's first line, not on the middle of it and the line under it)
  assert_true(ly < uy, msg="\{ly} \{uy}")
  assert_true((ly + lh / 2.0 - (ay + ah / 2.0)).abs() <= 1.0, msg="\{ly} \{lh} \{ay} \{ah}")
  t.tap_text("乙")
  t.run_for(@ui.move_most_ms)
  assert_eq(pressed.val, "长")
  assert_eq(t.audit(), [])
}

///|
test "a stats card: not there while it says nothing; a part come later opens its room, what is under it going down" {
  let lines = @signals.signal(false)
  let t = u13_case(fn(root) {
    stats_card_node(root, fn() { lines.get() }, [
      (fn() { lines.get() }, fn(l) { words_node(l, fn() { "正在跑 detlint" }, fn() { u13_value }) |> ignore }),
    ])
    words_node(root, fn() { "下面的行" }, fn() { u13_value }) |> ignore
  })
  assert_true(t.rect_of("正在跑 detlint") is None)
  let (_, y0, _, _) = t.rect_of("下面的行").unwrap()
  lines.set(true)
  t.run_for(@ui.move_most_ms)
  assert_true(t.rect_of("正在跑 detlint") is Some(_))
  let (_, y1, _, _) = t.rect_of("下面的行").unwrap()
  assert_true(y1 > y0, msg="\{y0} \{y1}")
  assert_eq(t.audit(), [])
}
