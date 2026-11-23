// The lines between a capsule's segments (segment_rule_node): rule_down in rule_color at rest, gone while a mouse is on a
// segment beside one (the segment after it made after it), the other line kept, and back as the mouse leaves.

///|
/// The lines down drawn (rule_w wide, not clear): their left edges.
fn segment_rules_seen(t : @ui.Tester) -> Array[Double] {
  t.drawn_rects().filter(fn(r) { r.2 == rule_w && (r.4 & 0xFFL) != 0L }).map(fn(r) { r.0 })
}

///|
test "a capsule's segments: the lines between them gone while the mouse is on one beside them, back as it leaves" {
  let t = @ui.Tester::new(fn(_c) {  }, w=360.0, h=120.0, platform=0)
  @ui.set_tree_theme(ui_theme_now)
  @ui.set_view_app(fn(root) {
    root.box(fn(page) {
      page.pad(Is(24.0)).lines_up(Is(Some(Start))) |> ignore
      page.box(fn(pill) {
        pill.row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
        let segs = Segments::new()
        for i, w in ["一号", "二号", "三号"] {
          if i > 0 {
            segment_rule_node(pill, segs, fn() { (i - 1, i) }) |> ignore
          }
          action_box_node(pill, fn() { w }, fn(_) {  }, fn(k) {
            k.row(Is(true)).padding(Is((10.0, 6.0, 10.0, 6.0))) |> ignore
            segs.made(i, k)
            words_node(k, fn() { w }, fn() { segment_words }) |> ignore
          })
          |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let rest = segment_rules_seen(t)
  assert_eq(rest.length(), 2, msg="at rest: \{Repr(rest)}")
  for r in t.drawn_rects().filter(fn(r) { r.2 == rule_w }) {
    assert_eq(r.4, rule_color(), msg="at rest: its colour")
  }
  // (on the last: the line before it gone, the first kept)
  let (x3, y3, w3, h3) = t.rect_of("三号").unwrap()
  t.move_to(x3 + w3 / 2.0, y3 + h3 / 2.0)
  t.run_for(dur_ms + 30.0)
  assert_eq(segment_rules_seen(t), [rest[0]], msg="on 三号")
  // (on the middle one: both gone)
  let (x2, y2, w2, h2) = t.rect_of("二号").unwrap()
  t.move_to(x2 + w2 / 2.0, y2 + h2 / 2.0)
  t.run_for(dur_ms + 30.0)
  assert_eq(segment_rules_seen(t).length(), 0, msg="on 二号")
  // (off the capsule: both back)
  t.move_to(340.0, 110.0)
  t.run_for(dur_ms + 30.0)
  assert_eq(segment_rules_seen(t), rest, msg="left")
}

///|
let segment_words : @ui.TextStyle = @ui.text_style(size=Meta, wrap=false)
