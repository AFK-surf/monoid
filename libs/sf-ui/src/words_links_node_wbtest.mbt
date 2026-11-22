// Words' links pressed and carded once the words have one (words_links_node): words with none (most of a chat's) make
// no binding and no node for them, not even a room for their cards, the arrow over them as over words whose links
// are pressed; a link come into them later (edited or updated text) pressed, its card shown and the hand over it, in the
// same words' node.

///|
/// Words in pieces (`runs`, as they change) 40 in, 60 down, in a window 800 by 500 with a mouse, their links pressed and
/// carded by words_links_node where `links` (else the words alone, nothing made for links), each link's card its words
/// and 的卡; what was tapped pushed to `tapped`, the words' node put in `node`.
fn wl_rig(
  runs : @signals.Signal[Array[@ui.Run]],
  links : Bool,
  tapped : Array[String],
  node : Ref[@view.View?],
) -> @ui.Tester {
  set_words(fn(key, _) { key })
  let t = @ui.Tester::new(fn(_c) {  }, w=800.0, h=500.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    let layer : Ref[@view.View?] = Ref(None)
    let tips = TipLayer::new(fn() { layer.val })
    root.box(fn(col) {
      col.padding(Is((60.0, 40.0, 0.0, 40.0))) |> ignore
      let words = col.box(fn(w) { w.words_runs(By(fn() { runs.get() })).width(Is(Some(400.0))) |> ignore })
      node.val = Some(words)
      if links {
        words_links_node(col, words, fn() { runs.get() }, fn(h) { tapped.push(h) }, cards=Some((tips, fn(l) {
          Some({
            tile: false,
            body: fn(b) {
              b.box(fn(x) {
                x.words(By(fn() { (l.words)() + "的卡" })).says(Is(Some(@view.said(Text, label=l.href + "的卡")))) |> ignore
              })
              |> ignore
            },
          })
        })))
      }
    })
    |> ignore
    layer.val = Some(root.box(fn(l) { l.over(Is(true)).over_all(Is(true)) |> ignore }))
  })
  t.draw()
  t
}

///|
/// How many nodes and bindings the window's tree of the Tester made last holds.
fn wl_counts() -> (Int, Int) {
  match @ui.view_tree() {
    Some(tree) => (tree.alive(), tree.bindings_held())
    None => (0, 0)
  }
}

///|
/// Words with no link, then a link to a: 甲的链接.
fn wl_plain() -> Array[@ui.Run] {
  [@ui.plain("先看这里，"), @ui.plain("就这些。")]
}

///|
fn wl_linked() -> Array[@ui.Run] {
  [@ui.plain("先看这里，"), { ..@ui.plain("甲的链接"), link: "a" }, @ui.plain("，就这些。")]
}

///|
test "words with no link make no binding and no node for links, not even the room for their cards, the arrow over them; with one, its press and card made" {
  let bare = wl_rig(@signals.signal(wl_plain()), false, [], Ref(None))
  let (bare_nodes, bare_bindings) = wl_counts()
  ignore(bare)
  let t = wl_rig(@signals.signal(wl_plain()), true, [], Ref(None))
  let (nodes, bindings) = wl_counts()
  // (nothing beside the words: their cards' box made only as a link comes)
  assert_eq((nodes, bindings), (bare_nodes, bare_bindings))
  match t.run_rects("先看这里") {
    [r, ..] => t.move_to(r.0 + r.2 / 2.0, r.1 + r.3 / 2.0)
    [] => fail("no words drawn")
  }
  t.run_for(@ui.move_most_ms)
  assert_true(t.cursor() is Arrow, msg="the arrow over words with no link")
  let faults = t.audit()
  assert_true(faults.is_empty(), msg=faults.join(" | "))
  let l = wl_rig(@signals.signal(wl_linked()), true, [], Ref(None))
  let (linked_nodes, linked_bindings) = wl_counts()
  ignore(l)
  assert_true(linked_nodes > nodes && linked_bindings > bindings, msg="\{Repr((linked_nodes, linked_bindings, nodes, bindings))}")
}

///|
test "a link come into words with none (updated in place): pressed, its card shown under a mouse and the hand over it, in the same words' node" {
  let runs = @signals.signal(wl_plain())
  let tapped : Array[String] = []
  let node : Ref[@view.View?] = Ref(None)
  let t = wl_rig(runs, true, tapped, node)
  let was = node.val.unwrap().id()
  let (nodes, bindings) = wl_counts()
  runs.set(wl_linked())
  t.run_for(@ui.move_most_ms)
  let words = node.val.unwrap()
  assert_true(words.alive() && words.id() == was, msg="the same words' node")
  let (now_nodes, now_bindings) = wl_counts()
  assert_true(now_nodes > nodes && now_bindings > bindings, msg="\{Repr((now_nodes, now_bindings, nodes, bindings))}")
  let (px, py, pw, ph) = match t.run_rects("甲的链接") {
    [r, ..] => r
    [] => fail("no link drawn")
  }
  t.move_to(px + pw / 2.0, py + ph / 2.0)
  t.run_for(hover_card_open_ms + hover_card_in_ms + 20.0)
  assert_true(t.cursor() is Hand, msg="the hand over the link")
  match t.rect_of("甲的链接的卡") {
    Some((x, y, _, _)) => assert_true(x > px && x < px + 40.0 && y > py + ph, msg="\{Repr((x, y, px, py, ph))}")
    None => fail("its card not drawn")
  }
  t.move_to(760.0, 480.0)
  t.run_for(hover_card_close_ms + hover_card_out_ms + 40.0)
  t.tap(px + pw / 2.0, py + ph / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_true(tapped.contains("a"), msg="\{Repr(tapped)}")
  let faults = t.audit()
  assert_true(faults.is_empty(), msg=faults.join(" | "))
}

///|
/// Markdown of two paragraphs and a list (`linked`: a link in its first paragraph) as nodes, with its links' cards
/// (`cards`) or not; how many nodes and bindings the window's tree holds then.
fn wl_markdown_counts(linked : Bool, cards : Bool) -> (Int, Int) {
  let s = fn(x : String) { Json::string(x) }
  let p = fn(xs : Array[Json]) { Json::array([s("p"), Json::array(xs)]) }
  let li = fn(kids : Array[Json]) { Json::array([s("li"), Json::array(kids), Json::object({})]) }
  let first = if linked {
    p([s("先看 "), Json::array([s("a"), Json::array([s("说明")]), Json::object({ "href": s("https://example.com/notes") })])])
  } else {
    p([s("先看说明。")])
  }
  let tree = Json::array([
    first,
    p([s("第二段，没有链接。")]),
    Json::array([s("list"), Json::array([li([s("第一项")]), li([s("第二项")])]), Json::object({})]),
  ])
  let text = if linked { "先看 [说明](https://example.com/notes)\n\n第二段" } else { "先看说明。\n\n第二段" }
  set_words(fn(key, _) { key })
  let t = @ui.Tester::new(fn(_c) {  }, w=800.0, h=500.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    let layer : Ref[@view.View?] = Ref(None)
    let tips = TipLayer::new(fn() { layer.val })
    root.box(fn(col) {
      if cards {
        markdown_node(col, fn() { text }, tree=fn() { Some(tree) }, link_cards=(tips, fn(_) { None })) |> ignore
      } else {
        markdown_node(col, fn() { text }, tree=fn() { Some(tree) }) |> ignore
      }
    })
    |> ignore
    layer.val = Some(root.box(fn(l) { l.over(Is(true)).over_all(Is(true)) |> ignore }))
  })
  t.draw()
  let faults = t.audit()
  guard faults.is_empty() else { return (-1, -1) }
  wl_counts()
}

///|
test "Markdown with no link: its links' cards make no binding and no node; with one, its own made beside its words" {
  let bare = wl_markdown_counts(false, false)
  let carded = wl_markdown_counts(false, true)
  assert_true(bare.0 > 0, msg="audited: \{Repr(bare)}")
  // (two paragraphs and two items' words, none with a link: nothing made for their cards)
  assert_eq(carded, bare)
  let linked_bare = wl_markdown_counts(true, false)
  let linked_carded = wl_markdown_counts(true, true)
  // (the linked paragraph's cards' box and its list of them, no other paragraph's)
  assert_true(linked_carded.0 > linked_bare.0, msg="\{Repr((linked_carded, linked_bare))}")
}
