// nav_tree_view: a stack for a window that is the tree alone (Tester::tree), every page made once as nodes and no old
// view built; slides layered, root pages another takes the place of kept at rest, pages over the root kept by the key
// they say, on the theme's ground as it changes.

///|
/// How far into a tab's swap (of its length) the one going is looked at, a few frames in, and the one coming.
let tree_nav_tab_going : Double = 20.0 / 260.0

///|
let tree_nav_tab_coming : Double = 55.0 / 260.0

///|
/// What the stack's pages did: each made (by what it was first), each let go, and the taps each counted in a signal of
/// its own (what it holds, kept as long as its nodes are).
priv struct TreeNavLog {
  made : Array[String]
  gone : Array[String]
  taps : Map[String, @signals.Signal[Int]]
}

///|
/// What kind a page named `p` is: "doc:<id>@<version>" a document, "tab:<name>" a root tab, else a plain page.
fn tree_nav_kind(p : String) -> String {
  if p.has_prefix("doc:") {
    "doc"
  } else if p.has_prefix("tab:") {
    "tab"
  } else {
    "page"
  }
}

///|
/// A document's id, the key it is kept by as it leaves the stack ("doc:7@v1": "7"); none for the rest.
fn tree_nav_doc_id(p : String) -> String? {
  guard p.has_prefix("doc:") else { return None }
  p.clamped_view(start=4).split("@").next().map(fn(id) { id.to_owned() })
}

///|
/// A window that is the tree alone (390 × 844, a finger's), dark as `dark` says, holding nav_tree_view of a stack whose
/// root is `root` with all its defaults but the key documents are kept by: each page a head 60 tall saying "page:" and
/// what it is now with its taps, counting them as it is pressed.
fn tree_nav(root : String, dark : @signals.Signal[Bool]) -> (Tester, Nav[String], TreeNavLog) {
  let log : TreeNavLog = { made: [], gone: [], taps: Map([]) }
  let nav = Nav::new(root)
  let t = Tester::tree(
    fn(v) {
      nav_tree_view(
        v,
        nav,
        tree_nav_kind,
        fn(m, page, _under, _stint, _k) {
          let first = @signals.untracked(page)
          log.made.push(first)
          let taps = @signals.signal(0)
          log.taps[first] = taps
          m.owns(fn() { log.gone.push(first) }) |> ignore
          m.box(fn(head) {
            head
            .height(Is(Some(60.0)))
            .words(By(fn() { "page:" + page() + " " + taps.get().to_string() }), look={
              ..@view.words_plain,
              size: 14.0,
            })
            .presses(Is(true))
            .on_press(fn() { taps.set(taps.untracked() + 1) })
            |> ignore
          })
          |> ignore
        },
        keeps_left=tree_nav_doc_id,
      )
      |> ignore
    },
    platform=1,
    theme=fn() { if dark.get() { Theme::dark() } else { Theme::light() } },
  )
  (t, nav, log)
}

///|
/// Where the words starting `start` are drawn (x) and how seen (alpha), the first such.
fn tree_nav_word(t : Tester, start : String) -> (Double, Double)? {
  t.words().iter().find_first(fn(w) { w.0.has_prefix(start) }).map(fn(w) { (w.1, w.5) })
}

///|
/// The black veils drawn over the whole of a page (their alphas).
fn tree_nav_veils(t : Tester) -> Array[Int64] {
  t
  .drawn_rects()
  .filter(fn(r) { r.2 >= 380.0 && r.3 >= 800.0 && (r.4 >> 8) == 0L && (r.4 & 0xFFL) > 0L })
  .map(fn(r) { r.4 & 0xFFL })
}

///|
/// The black hairlines one wide down the whole of a page.
fn tree_nav_edges(t : Tester) -> Int {
  t
  .drawn_rects()
  .filter(fn(r) { (r.2 - 1.0).abs() < 0.1 && r.3 >= 800.0 && (r.4 >> 8) == 0L && (r.4 & 0xFFL) > 0L })
  .length()
}

///|
/// The run's own checks once it is done: nothing laid out against its rules, no frame nothing asked for drawing anew,
/// nothing left to come.
fn tree_nav_done(t : Tester) -> Unit raise {
  assert_eq(t.audit(), [])
  assert_eq(t.unasked_faults(), [])
  t.assert_idle()
}

///|
test "nav_tree_view: layered by default: a push and a pop slide the page under at about 0.28 of the top's way, veiled, the top's leading edge drawn; a tab's swap moves both ends" {
  let dark = @signals.signal(false)
  let (t, nav, _) = tree_nav("tab:home", dark)
  let dur = move_ms(390.0)
  view_event(fn() { nav.push("page:detail") })
  t.run_for(dur * 0.4)
  let (x_top, _) = tree_nav_word(t, "page:page:detail").unwrap()
  let (x_under, _) = tree_nav_word(t, "page:tab:home").unwrap()
  let ratio = -x_under / (390.0 - x_top)
  assert_true(x_top > 0.0 && x_top < 390.0, msg="top at \{x_top}")
  assert_true(ratio > 0.22 && ratio < 0.34, msg="parallax \{ratio}: top \{x_top}, under \{x_under}")
  assert_true(!tree_nav_veils(t).is_empty(), msg="the page under veiled")
  assert_true(tree_nav_edges(t) > 0, msg="the top's leading edge")
  t.run_for(nav.rest() - t.time() + 16.0)
  assert_eq(tree_nav_veils(t), [])
  assert_eq(tree_nav_word(t, "page:page:detail").map(fn(w) { w.0 }), Some(0.0))
  // (popped: the same the other way, the page under coming back from its parallax)
  view_event(fn() { nav.pop() |> ignore })
  t.run_for(dur * 0.4)
  let (x_back, _) = tree_nav_word(t, "page:tab:home").unwrap()
  assert_true(x_back < 0.0, msg="under comes back from the left: \{x_back}")
  assert_true(!tree_nav_veils(t).is_empty(), msg="veiled as it comes back")
  t.run_for(nav.rest() - t.time() + 16.0)
  assert_eq(tree_nav_veils(t), [])
  assert_eq(tree_nav_word(t, "page:tab:home").map(fn(w) { w.0 }), Some(0.0))
  // (a tab's swap: the one going fades and moves off as the one coming fades and moves in, neither gone at once)
  let tab_ms = NavTransition::layered().tab_ms
  view_event(fn() { nav.replace_tab("tab:inbox", way=1, dur=tab_ms) })
  // (a few frames into it, the one going not yet gone; then a fifth of the way, the one coming already moving in)
  t.run_for(tab_ms * tree_nav_tab_going)
  let (out_x, out_a) = tree_nav_word(t, "page:tab:home").unwrap()
  assert_true(out_x < 0.0 && out_a > 0.1 && out_a < 0.85, msg="going a few frames in: x \{out_x}, alpha \{out_a}")
  t.run_for(tab_ms * (tree_nav_tab_coming - tree_nav_tab_going))
  let (in_x, in_a) = tree_nav_word(t, "page:tab:inbox").unwrap()
  assert_true(in_x > 0.0 && in_a > 0.01 && in_a < 1.0, msg="coming a fifth of the way: x \{in_x}, alpha \{in_a}")
  t.run_for(tab_ms)
  assert_eq(tree_nav_word(t, "page:tab:inbox"), Some((0.0, 1.0)))
  assert_true(tree_nav_word(t, "page:tab:home") is None)
  assert_true(nav.shelved("tab:home") is Some(_), msg="the tab gone put by")
  tree_nav_done(t)
}

///|
test "nav_tree_view: a root tab another is put in place of kept at rest by default: come back to, the same nodes, made once, what they hold as it was" {
  let dark = @signals.signal(false)
  let (t, nav, log) = tree_nav("tab:home", dark)
  t.tap(100.0, 30.0)
  t.tap(100.0, 30.0)
  assert_true(t.find("page:tab:home 2") is Some(_))
  view_event(fn() { nav.replace_kept("tab:inbox") })
  t.draw()
  // (put by: not drawn, nothing let go, a tap the tab on top's)
  assert_true(nav.shelved("tab:home") is Some(_))
  assert_true(t.find("page:tab:home 2") is None)
  assert_eq(log.gone, [])
  t.tap(100.0, 30.0)
  assert_eq((log.taps["tab:home"].get(), log.taps["tab:inbox"].get()), (2, 1))
  // (back and forth: each made once, its taps as they were)
  view_event(fn() { nav.replace_kept("tab:home") })
  t.draw()
  view_event(fn() { nav.replace_kept("tab:inbox") })
  t.draw()
  view_event(fn() { nav.replace_kept("tab:home") })
  t.draw()
  assert_eq(log.made, ["tab:home", "tab:inbox"])
  assert_eq(log.gone, [])
  assert_true(t.find("page:tab:home 2") is Some(_), msg="\{Repr(t.words().map(fn(w) { w.0 }))}")
  t.tap(100.0, 30.0)
  assert_true(t.find("page:tab:home 3") is Some(_))
  tree_nav_done(t)
}

///|
test "nav_tree_view: a document kept by its id as it leaves: pushed again, the same nodes, what they hold kept, what it is now followed; another id made anew" {
  let dark = @signals.signal(false)
  let (t, nav, log) = tree_nav("tab:home", dark)
  view_event(fn() { nav.push("doc:7@v1") })
  t.run_for(nav.rest() - t.time() + 16.0)
  t.tap(100.0, 30.0)
  assert_true(t.find("page:doc:7@v1 1") is Some(_))
  view_event(fn() { nav.pop() |> ignore })
  t.run_for(nav.rest() - t.time() + 16.0)
  assert_eq(log.gone, [])
  assert_true(t.find("page:doc:7@v1 1") is None)
  // (the same id at another version: taken back, made no more, its words what it is now, its taps kept)
  view_event(fn() { nav.push("doc:7@v2") })
  t.run_for(nav.rest() - t.time() + 16.0)
  assert_eq(log.made, ["tab:home", "doc:7@v1"])
  assert_true(t.find("page:doc:7@v2 1") is Some(_), msg="\{Repr(t.words().map(fn(w) { w.0 }))}")
  // (become another version in place: followed by the same nodes)
  view_event(fn() { nav.become("doc:7@v3") })
  t.draw()
  assert_true(t.find("page:doc:7@v3 1") is Some(_))
  view_event(fn() { nav.pop() |> ignore })
  t.run_for(nav.rest() - t.time() + 16.0)
  // (another id: made anew; a page saying no key let go as it leaves)
  view_event(fn() { nav.push("doc:8") })
  t.run_for(nav.rest() - t.time() + 16.0)
  view_event(fn() { nav.pop() |> ignore })
  t.run_for(nav.rest() - t.time() + 16.0)
  view_event(fn() { nav.push("page:plain") })
  t.run_for(nav.rest() - t.time() + 16.0)
  view_event(fn() { nav.pop() |> ignore })
  t.run_for(nav.rest() - t.time() + 16.0)
  assert_eq(log.made, ["tab:home", "doc:7@v1", "doc:8", "page:plain"])
  assert_eq(log.gone, ["page:plain"])
  tree_nav_done(t)
}

///|
test "nav_tree_view: its pages on the theme's ground by default, followed as the theme turns dark and back, nothing made again" {
  let dark = @signals.signal(false)
  let (t, nav, log) = tree_nav("tab:home", dark)
  let light_bg = Theme::light().bg
  let dark_bg = Theme::dark().bg
  // (the page under a push drawn off its place: its ground, not the window's, is where it is)
  let under_ground = fn(bg : Int64) {
    t.drawn_rects().iter().any(fn(r) { r.0 < -1.0 && r.2 >= 380.0 && r.3 >= 800.0 && r.4 == bg })
  }
  view_event(fn() { nav.push("page:detail") })
  t.run_for(move_ms(390.0) * 0.4)
  assert_true(under_ground(light_bg), msg="light ground under")
  assert_false(under_ground(dark_bg))
  t.run_for(nav.rest() - t.time() + 16.0)
  view_event(fn() { dark.set(true) })
  t.draw()
  view_event(fn() { nav.pop() |> ignore })
  t.run_for(move_ms(390.0) * 0.4)
  assert_true(under_ground(dark_bg), msg="dark ground under")
  assert_false(under_ground(light_bg))
  t.run_for(nav.rest() - t.time() + 16.0)
  view_event(fn() { dark.set(false) })
  t.draw()
  view_event(fn() { nav.push("page:detail") })
  t.run_for(move_ms(390.0) * 0.4)
  assert_true(under_ground(light_bg), msg="light again")
  t.run_for(nav.rest() - t.time() + 16.0)
  assert_eq(log.made, ["tab:home", "page:detail", "page:detail"])
  tree_nav_done(t)
}

///|
test "nav_tree_view: a tree alone builds no old view at all as pages come, go, swap and are kept" {
  let dark = @signals.signal(false)
  let olds = old_made.val
  let (t, nav, _) = tree_nav("tab:home", dark)
  assert_false(old_around.val, msg="no old frame round it")
  view_event(fn() { nav.push("doc:1") })
  t.run_for(nav.rest() - t.time() + 16.0)
  view_event(fn() { nav.rise("page:sheet") })
  t.run_for(nav.rest() - t.time() + 16.0)
  view_event(fn() { nav.pop() |> ignore })
  t.run_for(nav.rest() - t.time() + 16.0)
  view_event(fn() { nav.pop() |> ignore })
  t.run_for(nav.rest() - t.time() + 16.0)
  view_event(fn() { nav.replace_tab("tab:inbox", way=1) })
  t.run_for(NavTransition::layered().tab_ms + 16.0)
  view_event(fn() { nav.replace_kept("tab:home") })
  t.draw()
  assert_eq(old_made.val, olds, msg="no old island made")
  assert_eq(old_islands.length(), 0)
  assert_false(old_around.val)
  tree_nav_done(t)
}
