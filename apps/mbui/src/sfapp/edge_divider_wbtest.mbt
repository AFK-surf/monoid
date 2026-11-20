// No line drawn at rest along an edge dragged for a width (the user, 2026-10-26, #2012: 「这个分割线不对，去掉，搞坏了宽度
// 调整的样式」; again 2026-11-17 of the chat beside the board: 「这个分割线怎么又出现了」「不是改了么」): what is dragged
// for a width and the page beside it are set apart by their grounds, and the edge's own line (sf's edge_look_node, its
// ends clear) shows only under a pointer, focused or in hand. Every screen of corner_modes in every window of
// corner_windows is held to it as corners_check opens it (no screen let off); the chat beside the board here, at rest and
// under the pointer.

///|
/// What is dragged for a width on screen `t`, each by what it is called and where: its separators (sf's edge_node,
/// headless split, the old view's edge) and the sidebar's edge while it is open (sfdesk's pane_edge, a button saying
/// what its press does).
fn width_edges(t : @ui.Tester) -> Array[(String, (Double, Double, Double, Double))] {
  let out = []
  for n in t.all(Separator) {
    out.push((n.label, n.rect))
  }
  let sidebar = @sf.t("web-pages.workspace.resizeSidebar") + " · " + @sf.t("web-main.sidebar.close")
  for n in t.all(Button, label=sidebar) {
    out.push((n.label, n.rect))
  }
  out.filter(fn(e) { e.1.2 > 0.0 && e.1.3 > 0.0 })
}

///|
/// Whether a rectangle drawn (`r`: x, y, w, h, its colour with its alpha last) is a line along edge `e` (x, y, w, h):
/// its middle across within the edge (half a point either side), as thin as a line (2.5 at most), down half the edge's
/// height or more, seen.
fn edge_line_along(r : (Double, Double, Double, Double, Int64), e : (Double, Double, Double, Double)) -> Bool {
  let (rx, _, rw, rh, color) = r
  let (ex, _, ew, eh) = e
  let mid = rx + rw / 2.0
  mid >= ex - 0.5 && mid <= ex + ew + 0.5 && rw > 0.0 && rw <= 2.5 && rh >= eh * 0.5 && (color & 0xFFL) > 0L
}

///|
/// The lines drawn on screen `t` as it is now along an edge dragged for a width, each said with that edge and where it
/// is drawn: none at rest.
fn edge_divider_faults(t : @ui.Tester) -> Array[String] {
  let edges = width_edges(t)
  if edges.is_empty() {
    return []
  }
  let rects = t.drawn_rects()
  let out = []
  for e in edges {
    let (label, rect) = e
    for r in rects {
      if edge_line_along(r, rect) {
        let (rx, ry, rw, rh, color) = r
        out.push(
          "a line along 「\{label}」 at \{@ui.rect_text(rect)}: \{@ui.rect_text((rx, ry, rw, rh))} 0x\{color.to_string(radix=16)}",
        )
      }
    }
  }
  out
}

///|
test "大屏 1280: the chat beside the board, no line between them at rest; under the pointer its edge's line and bar alone, gone again as it leaves" {
  new_run()
  let src = fixture("board-side")
  open_fixture_over("board-side", src)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0)
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.board_pick.get() is Some(_), msg="its chat open beside the board")
  guard t.query(Separator, label=@sf.t("web-pages.chat.resizePanel")) is Some(edge) else {
    fail("the chat beside the board has no edge")
  }
  let (ex, ey, ew, eh) = edge.rect
  // at rest: no line along its edge, nor along any other edge of the screen
  assert_eq(edge_divider_faults(t), [])
  // (its edge over the chat's start, handle_out of it over the board)
  assert_eq((1280.0 - ex - @sf.handle_out).round().to_int(), 460)
  let seen_in = fn() {
    t.drawn_rects().filter(fn(r) {
      let (rx, _, rw, _, color) = r
      let mid = rx + rw / 2.0
      mid >= ex - 0.5 && mid <= ex + ew + 0.5 && (color & 0xFFL) > 0L && rw <= @sf.edge_bar_w + 0.5
    })
  }
  // (nor anything else drawn in it)
  assert_eq(seen_in().map(fn(r) { @ui.rect_text((r.0, r.1, r.2, r.3)) }), [])
  // the pointer on it: its line, in pieces clear toward its ends (none of them a line its height), and its bar
  t.move_to(ex + ew / 2.0, ey + eh / 2.0)
  t.run_for(@ui.move_most_ms)
  let lit = seen_in()
  let pieces = lit.filter(fn(r) { r.2 <= 2.5 })
  let bars = lit.filter(fn(r) { (r.2 - @sf.edge_bar_w).abs() < 0.5 })
  assert_true(pieces.length() >= 20, msg="its line under the pointer: \{pieces.length()} pieces")
  assert_true(pieces.iter().all(fn(r) { r.3 < eh * 0.5 }), msg="a line its height under the pointer")
  assert_eq(bars.length(), 1, msg="its bar under the pointer")
  assert_eq(edge_divider_faults(t), [])
  // the pointer gone: nothing drawn there again
  t.leave()
  t.run_for(@ui.move_most_ms)
  assert_eq(seen_in().map(fn(r) { @ui.rect_text((r.0, r.1, r.2, r.3)) }), [])
  assert_eq(edge_divider_faults(t), [])
}
