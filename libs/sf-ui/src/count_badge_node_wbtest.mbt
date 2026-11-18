// The library's count (count_badge_node.mbt): a mark 16 high whatever the system's size of words, its figures held in
// it, a dot 8 across with no count, `max+` past its most; a count in a line growing with its words.

///|
/// The counts `make` makes in a row, the words at `scale`, each node kept in `nodes` in the order made.
fn count_case(make : (@view.View, Array[@view.View]) -> Unit, scale? : Double = 1.0) -> (@ui.Tester, Array[@view.View]) {
  let nodes : Array[@view.View] = []
  let t = u5_case(scale~, fn(root) {
    root.box(fn(r) {
      r.row(Is(true)).gap(Is(12.0)).lines_up(Is(Some(Start))) |> ignore
      make(r, nodes)
    })
    |> ignore
  })
  (t, nodes)
}

///|
test "a count's mark: 16 high and round at any size of words, its figures in it, 99+ past 99, a dot 8 across with no count" {
  for scale in [1.0, 1.3] {
    let (t, nodes) = count_case(scale~, fn(r, nodes) {
      nodes.push(count_badge_node(r, count=fn() { 3 }))
      nodes.push(count_badge_node(r, count=fn() { 120 }, max=99, tone=CountAccent))
      nodes.push(count_badge_node(r))
    })
    let at = "scale \{scale}"
    assert_eq(t.fixed_outgrown(), [], msg=at)
    let (_, _, w3, h3) = nodes[0].placed_window_now()
    let (_, _, wmax, hmax) = nodes[1].placed_window_now()
    let (_, _, wd, hd) = nodes[2].placed_window_now()
    assert_eq((w3, h3, hmax, wd, hd), (16.0, 16.0, 16.0, 8.0, 8.0), msg=at)
    assert_true(wmax > 16.0, msg="\{at}: \{wmax}")
    let said = t.words().map(fn(w) { w.0 })
    assert_true(said.contains("3") && said.contains("99+"), msg="\{at}: \{Repr(said)}")
  }
}

///|
test "a count in a line: as tall as its words, taller as the system's words are set larger" {
  let height = fn(scale : Double) raise {
    let (t, nodes) = count_case(scale~, fn(r, nodes) { nodes.push(count_badge_node(r, count=fn() { 7 }, look=Inline, tone=CountAccent)) })
    assert_eq(t.fixed_outgrown(), [])
    nodes[0].placed_window_now().3
  }
  let at_1 = height(1.0)
  let at_13 = height(1.3)
  assert_true(at_13 > at_1, msg="\{at_1} \{at_13}")
}

///|
test "count_words: the count as it is, past max said max+" {
  assert_eq((count_words(5), count_words(99, max=99), count_words(100, max=99), count_words(1000)), ("5", "99", "99+", "1000"))
}
