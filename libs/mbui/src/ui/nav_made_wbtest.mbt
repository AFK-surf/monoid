// A page of a stack the window's tree holds made once as nodes (nav_view's `made`, Nav::made): made as it is put on,
// kept while it is on the stack (covered by another and come back to: the same nodes, what they hold as it was), what
// it becomes in place followed by those nodes, let go once as it has gone; back the stack's as its swipe from the left
// edge alone (a hold that went down in the middle, or on the edge of a page moved off it, no swipe back), the page's
// own back before the stack's; mixed with pages that are old views on the same stack.

///|
/// What the made pages did: how many times each kind was made, let go, and its taps counted by its own nodes.
priv struct MadeLog {
  made : Array[String]
  gone : Array[String]
  taps : Map[String, @signals.Signal[Int]]
  scrolls : Map[String, @view.Scroll]
  roots : Map[String, @view.NodeId]
  /// backs taken by a page's own (one named with "own" takes back itself)
  owns : Ref[Int]
  /// each page's time on top, as the stack gives it (what a picture it shows is asked for on)
  stints : Map[String, () -> Int]
  /// each page's times on top as what read it was told them (View::reacts), in order
  seen : Map[String, Array[Int]]
}

///|
/// A stack of pages named by words in the window's tree (390 × 844, a finger's): those starting "m" made once as nodes
/// (kind "m"): its name as it is now (what it becomes in place), a tap target counting its taps in a field of its own,
/// and 2000 high of words that scroll; the rest old views of their name.
fn made_stack() -> (Tester, Nav[String], MadeLog, Array[String]) {
  let left : Array[String] = []
  let log : MadeLog = { made: [], gone: [], taps: Map([]), scrolls: Map([]), roots: Map([]), owns: Ref(0), stints: Map([]), seen: Map([]) }
  let nav = Nav::new("a", on_leave=fn(p) { left.push(p) })
  let t = Tester::new(fn(_c) {  }, platform=1)
  t.check_looks(false)
  set_view_app(fn(root) {
    nav_view(
      root,
      nav,
      fn(c, p) { c.text(p, size=12.0) |> ignore },
      bg=fn() { 0xFFFFFFFFL },
      made=fn(p) {
        if p.has_prefix("m") {
          Some(
            (
              "m",
              fn(v, page, _under, stint, _k) {
                let first = @signals.untracked(page)
                log.made.push(first)
                let taps = @signals.signal(0)
                let scroll = @view.Scroll::new()
                log.taps[first] = taps
                log.scrolls[first] = scroll
                log.roots[first] = v.id()
                log.stints[first] = stint
                log.seen[first] = []
                v.reacts(stint, fn(s) { log.seen[first].push(s) })
                v.owns(fn() { log.gone.push(first) }) |> ignore
                if first.contains("own") {
                  v.box(fn(b) { b.over(Is(true)).takes_back(fn() { log.owns.val += 1 }) |> ignore }) |> ignore
                }
                v.box(fn(head) {
                  head
                  .height(Is(Some(60.0)))
                  .words(By(fn() { page() + " " + taps.get().to_string() }), look={ ..@view.words_plain, size: 12.0 })
                  .presses(Is(true))
                  .on_press(fn() { taps.set(taps.untracked() + 1) })
                  |> ignore
                })
                |> ignore
                v.box(fn(s) {
                  s.grow(Is(1.0)) |> ignore
                  s.scrolls(scroll, fn(body) { body.height(Is(Some(2000.0))) |> ignore }) |> ignore
                })
                |> ignore
              },
            ),
          )
        } else {
          None
        }
      },
    )
    |> ignore
  })
  t.draw()
  (t, nav, log, left)
}

///|
/// Moments on a test's clock after what was done: long after a fling of a finger's drag here set out (at rest by then),
/// a second on, half of one, and one a few frames into a push's slide (short of its end).
let long_after_ms : Double = 2000.0

///|
let a_second_ms : Double = 1000.0

///|
let half_a_second_ms : Double = 500.0

///|
let into_slide_ms : Double = 60.0

///|
/// Pushed, its slide run out.
fn pushed(t : Tester, nav : Nav[String], p : String) -> Unit {
  view_event(fn() { nav.push(p) })
  t.run_for(nav.rest() - t.time() + 16.0)
}

///|
test "window tree: a made page covered and come back to is the same nodes, what they hold as it was; let go once as it goes" {
  let (t, nav, log, left) = made_stack()
  pushed(t, nav, "m1")
  assert_eq(log.made, ["m1"])
  // (tapped twice on its head, scrolled 300 down)
  t.tap(100.0, 30.0)
  t.tap(100.0, 30.0)
  t.drag(200.0, 600.0, 200.0, 300.0)
  t.run_for(long_after_ms)
  let tree = view_tree().unwrap()
  let scrolled = log.scrolls["m1"].at(tree)
  assert_eq(log.taps["m1"].get(), 2)
  assert_true(scrolled > 100.0, msg="scrolled \{scrolled}")
  // (an old view's page over it, its slide over: it shows no more, its nodes kept)
  pushed(t, nav, "b")
  assert_eq(log.gone, [])
  assert_true(t.find("m1 2") is None)
  // (back to it: the same nodes, its taps and where it was scrolled as they were, made no more)
  t.back()
  t.run_for(nav.rest() - t.time() + 16.0)
  assert_eq(log.made, ["m1"])
  assert_eq(log.gone, [])
  assert_eq(log.scrolls["m1"].at(view_tree().unwrap()), scrolled)
  assert_true(t.find("m1 2") is Some(_))
  // (gone back off the stack: let go once its slide is over, the stack told once)
  t.back()
  t.run_for(nav.rest() - t.time() + 16.0)
  assert_eq(log.gone, ["m1"])
  assert_eq(left.filter(fn(p) { p == "m1" }).length(), 1)
}

///|
test "window tree: a made page become another of its kind in place: the same nodes follow what it is now, their state kept" {
  let (t, nav, log, _) = made_stack()
  pushed(t, nav, "m1")
  t.tap(100.0, 30.0)
  view_event(fn() { nav.become("m2") })
  t.draw()
  assert_eq(log.made, ["m1"])
  assert_true(t.find("m2 1") is Some(_), msg="\{Repr(t.words().map(fn(w) { w.0 }))}")
  // (become an old view's: its nodes let go once, the old view there)
  view_event(fn() { nav.become("c") })
  t.draw()
  assert_eq(log.gone, ["m1"])
  assert_true(t.find("c") is Some(_))
  // (and a made one again: made anew)
  view_event(fn() { nav.become("m3") })
  t.draw()
  assert_eq(log.made, ["m1", "m3"])
}

///|
test "window tree: a made page taken back by a swipe from its left edge alone, not from its middle nor from where it was moved off" {
  let (t, nav, _, _) = made_stack()
  pushed(t, nav, "m1")
  // (from its middle across: not back)
  t.drag(200.0, 400.0, 380.0, 400.0)
  t.run_for(a_second_ms)
  assert_eq(nav.depth(), 2)
  // (from its left edge across, most of the way: back)
  t.drag(4.0, 400.0, 300.0, 400.0)
  t.run_for(nav.rest() - t.time() + 16.0)
  assert_eq(nav.depth(), 1)
  // (pushed again and, while it still slides in, a finger down where its left edge is not yet: not back)
  view_event(fn() { nav.push("m2") })
  t.run_for(into_slide_ms)
  t.drag(4.0, 400.0, 300.0, 400.0)
  t.run_for(nav.rest() - t.time() + 16.0)
  assert_eq(nav.depth(), 2)
}

///|
test "window tree: back on a made page taken by what the page says takes it before the stack's" {
  let (t, nav, log, _) = made_stack()
  pushed(t, nav, "m-own")
  t.back()
  t.run_for(half_a_second_ms)
  assert_eq(log.owns.val, 1)
  assert_eq(nav.depth(), 2)
}

///|
test "window tree: a made page covered while the window changes height: come back to, how far it can scroll the window's as it is now, and followed after" {
  let (t, nav, log, _) = made_stack()
  pushed(t, nav, "m1")
  t.drag(200.0, 600.0, 200.0, 300.0)
  t.run_for(long_after_ms)
  let scroll = log.scrolls["m1"]
  let most_before = scroll.most()
  let at_before = scroll.at(view_tree().unwrap())
  assert_true(at_before > 0.0)
  pushed(t, nav, "b")
  // (made 300 shorter while covered: its room 300 more to scroll through)
  t.h = t.h - 300.0
  t.draw()
  t.back()
  t.run_for(nav.rest() - t.time() + 16.0)
  assert_eq(log.made, ["m1"])
  assert_eq(scroll.most(), most_before + 300.0)
  assert_eq(scroll.at(view_tree().unwrap()), at_before)
  // (and taller again while it shows: followed, as it changes)
  t.h = t.h + 500.0
  t.draw()
  assert_eq(scroll.most(), most_before - 200.0)
  assert_true(scroll.at(view_tree().unwrap()) <= scroll.most())
}

///|
test "window tree: a made page's time on top its own entry's: kept while another is over it, a new one as it is come back to" {
  let (t, nav, log, _) = made_stack()
  pushed(t, nav, "m1")
  let s1 = (log.stints["m1"])()
  pushed(t, nav, "m2")
  let s2 = (log.stints["m2"])()
  assert_true(s2 != s1)
  // (covered: its own still, not the one on top's)
  assert_eq((log.stints["m1"])(), s1)
  t.back()
  t.run_for(nav.rest() - t.time() + 16.0)
  let again = (log.stints["m1"])()
  assert_true(again != s1 && again != s2, msg="\{s1} \{s2} \{again}")
}

///|
test "window tree: a made page in the hand by a scripted run's drag (its steps taken after each frame's work, as a device's input between frames): each frame that drew it in the hand says a page held by a finger, none other does; at rest again, none" {
  let (t, nav, _, _) = made_stack()
  pushed(t, nav, "m1")
  let held = Ref(0)
  let missed : Array[Int] = []
  let said_free : Array[Int] = []
  // (in the hand as the frame was drawn: as the step of the frame before left it, nothing between the two)
  let drawn_held = Ref(nav.mode == 3)
  t.drive("drag 4 400 60 0 300\nwait 800\nexit", each=fn(_) {
    if drawn_held.val {
      held.val += 1
      if !g().page_in_hand {
        missed.push(g().frame_no)
      }
    } else if g().page_in_hand {
      said_free.push(g().frame_no)
    }
    drawn_held.val = nav.mode == 3
  })
  |> ignore
  assert_true(held.val > 3, msg="frames in the hand: \{held.val}")
  assert_eq((missed, said_free), ([], []))
  // (let go short of a third: back where it was, at rest, no page in the hand)
  assert_eq(nav.depth(), 2)
  assert_eq(nav.mode, 0)
  assert_true(!g().page_in_hand, msg="at rest")
}

///|
test "window tree: a made page come back to tells what reads its time on top the new one, by a back and by the stack's own pop" {
  let (t, nav, log, _) = made_stack()
  pushed(t, nav, "m1")
  pushed(t, nav, "m2")
  t.back()
  t.run_for(nav.rest() - t.time() + 16.0)
  let again = (log.stints["m1"])()
  assert_eq(log.seen["m1"].last(), Some(again), msg="by a back: \{Repr(log.seen["m1"])}")
  pushed(t, nav, "m3")
  view_event(fn() { nav.pop() |> ignore })
  t.run_for(nav.rest() - t.time() + 16.0)
  let then = (log.stints["m1"])()
  assert_true(then != again)
  assert_eq(log.seen["m1"].last(), Some(then), msg="by the stack's pop: \{Repr(log.seen["m1"])}")
  // (popped as an app pops it from outside any event: what reads its time on top told the new one all the same)
  pushed(t, nav, "m4")
  nav.pop() |> ignore
  t.run_for(nav.rest() - t.time() + 16.0)
  let last = (log.stints["m1"])()
  assert_true(last != then)
  assert_eq(log.seen["m1"].last(), Some(last), msg="by a pop from outside an event: \{Repr(log.seen["m1"])}")
}

///|
/// made_stack's, its pages made once kept as they leave the stack (nav_view's `keeps_left`: by their name, of kind "m";
/// Nav's kept left), those let go for good told (`gone_for_good`, Nav's on_entry_gone).
fn made_stack_kept() -> (Tester, Nav[String], MadeLog, Array[String], Array[String]) {
  let left : Array[String] = []
  let gone_for_good : Array[String] = []
  let log : MadeLog = { made: [], gone: [], taps: Map([]), scrolls: Map([]), roots: Map([]), owns: Ref(0), stints: Map([]), seen: Map([]) }
  let nav = Nav::new("a", on_leave=fn(p) { left.push(p) }, on_entry_gone=fn(_, p) { gone_for_good.push(p) })
  let t = Tester::new(fn(_c) {  }, platform=1)
  t.check_looks(false)
  set_view_app(fn(root) {
    nav_view(
      root,
      nav,
      fn(c, p) { c.text(p, size=12.0) |> ignore },
      bg=fn() { 0xFFFFFFFFL },
      keeps_left=fn(p) { if p.has_prefix("m") { Some((p, "m")) } else { None } },
      made=fn(p) {
        if p.has_prefix("m") {
          Some(
            (
              "m",
              fn(v, page, _under, _stint, _k) {
                let first = @signals.untracked(page)
                log.made.push(first)
                let taps = @signals.signal(0)
                log.taps[first] = taps
                v.owns(fn() { log.gone.push(first) }) |> ignore
                v.box(fn(head) {
                  head
                  .height(Is(Some(60.0)))
                  .words(By(fn() { page() + " " + taps.get().to_string() }), look={ ..@view.words_plain, size: 12.0 })
                  .presses(Is(true))
                  .on_press(fn() { taps.set(taps.untracked() + 1) })
                  |> ignore
                })
                |> ignore
              },
            ),
          )
        } else {
          None
        }
      },
    )
    |> ignore
  })
  t.draw()
  (t, nav, log, left, gone_for_good)
}

///|
/// Popped, its slide run out.
fn popped(t : Tester, nav : Nav[String]) -> Unit {
  view_event(fn() { nav.pop() |> ignore })
  t.run_for(nav.rest() - t.time() + 16.0)
}

///|
test "window tree: a made page gone back from kept at rest, taken back the same nodes as it is pushed again; its leaving told once a stay, the least lately used let go for good past the most kept" {
  let (t, nav, log, left, gone_for_good) = made_stack_kept()
  pushed(t, nav, "m1")
  let (m1, _) = nav.top_stay()
  t.tap(100.0, 30.0)
  t.tap(100.0, 30.0)
  assert_true(t.find("m1 2") is Some(_))
  popped(t, nav)
  // (gone from the stack: kept, its nodes put by at rest, not drawn, nothing let go; its leaving told once)
  assert_true(nav.is_kept_left(m1))
  assert_eq(nav.pages(), ["a"])
  assert_eq(log.gone, [])
  assert_eq(left, ["m1"])
  assert_eq(gone_for_good, [])
  assert_true(t.find("m1 2") is None)
  // (a tap where its head was while it is put by: the page on top's, not its)
  t.tap(100.0, 30.0)
  assert_eq(log.taps["m1"].get(), 2)
  // (pushed again: the same nodes, its taps as they were, made no more)
  pushed(t, nav, "m1")
  assert_eq(log.made, ["m1"])
  assert_eq(nav.top_stay().0, m1)
  assert_true(!nav.is_kept_left(m1))
  assert_true(t.find("m1 2") is Some(_), msg="\{Repr(t.words().map(fn(w) { w.0 }))}")
  t.tap(100.0, 30.0)
  assert_eq(log.taps["m1"].get(), 3)
  popped(t, nav)
  assert_eq(left, ["m1", "m1"])
  // (three others kept after it: it the least lately used, let go for good, its leaving not told again)
  for p in ["m2", "m3", "m4"] {
    pushed(t, nav, p)
    popped(t, nav)
  }
  assert_eq(log.gone, ["m1"])
  assert_eq(gone_for_good, ["m1"])
  assert_eq(left, ["m1", "m1", "m2", "m3", "m4"])
  // (pushed again once let go: made anew)
  pushed(t, nav, "m1")
  assert_eq(log.made, ["m1", "m2", "m3", "m4", "m1"])
  assert_true(t.find("m1 0") is Some(_))
  // (the shelf emptied, as the workspace in view changes: those kept let go for good with it)
  popped(t, nav)
  view_event(fn() { nav.shelf_empty() })
  t.draw()
  assert_eq(gone_for_good, ["m1", "m2", "m3", "m4", "m1"])
}

///|
test "window tree: a made page put by as another is put in place of it over the root, taken back as it is put there again; one never shown kept not" {
  let (t, nav, log, left, _) = made_stack_kept()
  pushed(t, nav, "m1")
  view_event(fn() { nav.replace_above(1, ["m2"]) })
  t.draw()
  assert_eq(left, ["m1"])
  assert_eq(log.gone, [])
  view_event(fn() { nav.replace_above(1, ["m1"]) })
  t.draw()
  assert_eq(log.made, ["m1", "m2"])
  assert_true(t.find("m1 0") is Some(_))
  // (one pushed and put in place of before a frame showed it: made nothing, kept nothing)
  view_event(fn() {
    nav.push("m5")
    nav.replace("m6")
  })
  t.draw()
  assert_true(!log.made.contains("m5"))
  // (the root put in place: what was kept let go for good with the stack over it)
  view_event(fn() { nav.replace_above(0, ["b"]) })
  t.draw()
  assert_true(log.gone.contains("m2"), msg="\{Repr(log.gone)}")
}

///|
test "window tree: a flat stack's made page put in place of over its root kept, kept shown while the one in its place waits and put by once that shows, taken back the same nodes as it is put there again" {
  for owned in [false, true] {
    let made : Array[String] = []
    let gone : Array[String] = []
    let left : Array[String] = []
    let ready = @signals.signal(true)
    let nav = Nav::new("root", on_leave=fn(p) { left.push(p) })
    let t = Tester::new(fn(_c) {  }, w=390.0, h=600.0)
    set_view_app(fn(root) {
      if owned {
        // (an owner as the panes' (page_wait.mbt): the page shown kept while the one put in its place waits)
        nav.flat_owned(true)
        let shown = Ref(@signals.untracked(fn() { nav.top_stay() }))
        root.reacts(fn() { (nav.top_stay(), ready.get()) }, fn(now) {
          if now.0 == shown.val {
            return
          }
          if now.1 {
            shown.val = now.0
            nav.flat_keep(None)
          } else {
            nav.flat_keep(Some(shown.val))
          }
        })
      }
      nav_flat_view(
        root,
        nav,
        fn(c, p) { c.text(p, size=12.0) |> ignore },
        fn(_) { true },
        0.0,
        keeps_left=fn(p) { if p.has_prefix("m") { Some((p, "m")) } else { None } },
        made=fn(p) {
          if !p.has_prefix("m") {
            return None
          }
          Some(
            (
              "m",
              fn(v, page, _under, _stint, _k) {
                let name = @signals.untracked(page)
                made.push(name)
                v.box(fn(w) { w.words(By(fn() { "page " + page() })) |> ignore }) |> ignore
                v.owns(fn() { gone.push(name) }) |> ignore
              },
            ),
          )
        },
      )
      |> ignore
    })
    t.draw()
    nav.replace_above(1, ["mA"])
    t.draw()
    assert_true(t.find("page mA") is Some(_), msg="\{owned}")
    // (B put in its place, waiting where an owner keeps A shown meanwhile: A still shown, then put by as B shows)
    ready.set(false)
    nav.replace_above(1, ["mB"])
    t.draw()
    if owned {
      assert_true(t.find("page mA") is Some(_), msg="kept shown")
      assert_eq(left, [], msg="kept shown")
    }
    ready.set(true)
    t.draw()
    assert_true(t.find("page mB") is Some(_), msg="\{owned}")
    assert_true(t.find("page mA") is None, msg="\{owned}")
    assert_eq((made, gone, left), (["mA", "mB"], [], ["mA"]), msg="\{owned}")
    // (A again: the same nodes, made no more; B put by)
    nav.replace_above(1, ["mA"])
    t.draw()
    assert_true(t.find("page mA") is Some(_), msg="\{owned}")
    assert_eq((made, gone, left), (["mA", "mB"], [], ["mA", "mB"]), msg="\{owned}")
  }
}

///|
test "window tree: a made page with a focused tree field covered by another page: returning by pop or by back_gesture restores focus and ime to the field" {
  let nav = Nav::new("a")
  let f = Field::new()
  let t = Tester::new(fn(_c) {  }, platform=1)
  t.check_looks(false)
  set_view_app(fn(root) {
    nav_view(
      root,
      nav,
      fn(c, p) { c.text(p, size=12.0) |> ignore },
      bg=fn() { 0xFFFFFFFFL },
      made=fn(p) {
        if p == "m1" {
          Some(
            (
              "m",
              fn(v, _page, _under, _stint, _k) {
                v.box(fn(h) {
                  h.height(Is(Some(60.0))) |> ignore
                  field(h, f, placeholder="页内字段", label="页内字段") |> ignore
                })
                |> ignore
              },
            ),
          )
        } else {
          None
        }
      },
    )
    |> ignore
  })
  t.draw()
  pushed(t, nav, "m1")
  f.focus()
  t.draw()
  t.type_text("a")
  t.draw()
  assert_true(f.focused() && t.ime().0, msg="focused before push: focused=\{f.focused()} ime=\{Repr(t.ime())}")
  // (push a page over m1 until settled: m1 is laid out nowhere and loses focus)
  pushed(t, nav, "b")
  assert_true(!f.focused() && !t.ime().0, msg="covered page drops focus and ime")
  // (return by nav.pop(): focus and ime restored to the tree field)
  view_event(fn() { nav.pop() |> ignore })
  t.run_for(nav.rest() - t.time() + 16.0)
  assert_true(f.focused() && t.ime().0, msg="after pop: focused=\{f.focused()} ime=\{Repr(t.ime())}")
  t.type_text("b")
  t.draw()
  assert_eq(f.text(), "ab", msg="typing after pop")
  // (push again until settled, then return by back_gesture: focus and ime restored too)
  pushed(t, nav, "b")
  assert_true(!f.focused() && !t.ime().0, msg="covered page drops focus and ime before back_gesture")
  t.back_gesture(200.0, true)
  t.run_for(nav.rest() - t.time() + 16.0)
  assert_true(f.focused() && t.ime().0, msg="after back_gesture: focused=\{f.focused()} ime=\{Repr(t.ime())}")
  t.type_text("c")
  t.draw()
  assert_eq(f.text(), "abc", msg="typing after back_gesture")
}
