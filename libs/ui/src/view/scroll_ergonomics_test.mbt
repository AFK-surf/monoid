// Ergonomic scroll defaults: `Scroll::new()` uses platform list feel (`as_list=true`, supporting `grew_above`),
// `Scroll::plain()` retains legacy capped-box physics (`as_list=false`), and `View::scroll_column` omits boilerplate.
// Every box that scrolls fades what it holds towards an end it goes on past, whichever feel it has; a page's own list
// (`Scroll::list`) does not.

///|
test "Scroll::new defaults to list feel and supports grew_above without aborting" {
  let s = @view.Scroll::new()
  let ids : Map[String, @view.NodeId] = Map([])
  let t = @view.Tree::new(
    fn(root) {
      root.box(fn(sc) {
        ids["sc"] = sc.id()
        sc
        .width(Is(Some(240.0)))
        .height(Is(Some(120.0)))
        .scrolls(s, fn(inner) {
          for i in 0..<20 {
            inner.box(fn(r) { r.height(Is(Some(30.0))).words(Is("row-\{i}")) |> ignore }) |> ignore
          }
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(300.0, 200.0, now=0.0) |> ignore
  assert_eq(s.most(), 480.0)
  // Put scroll down, then grow content above by 60px: must adjust offset cleanly instead of aborting.
  t.event(16.0, fn() { s.put(100.0) })
  t.frame(300.0, 200.0, now=16.0) |> ignore
  assert_eq(s.at(t), 100.0)
  t.event(32.0, fn() { s.grew_above(60.0) })
  t.frame(300.0, 200.0, now=32.0) |> ignore
  assert_eq(s.at(t), 160.0)
}

///|
/// A box 120 tall scrolling 10 rows of 30 in `s` at 0, then put at 50 and at its foot (180): how far it fades at each.
fn fades_along(s : @view.Scroll) -> Array[(Double, Double, Double, Double)] {
  let ids : Map[String, @view.NodeId] = Map([])
  let t = @view.Tree::new(
    fn(root) {
      root.box(fn(sc) {
        ids["sc"] = sc.id()
        sc
        .width(Is(Some(240.0)))
        .height(Is(Some(120.0)))
        .scrolls(s, fn(inner) {
          for i in 0..<10 {
            inner.box(fn(r) { r.height(Is(Some(30.0))).words(Is("row-\{i}")) |> ignore }) |> ignore
          }
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(300.0, 200.0, now=0.0) |> ignore
  let out = [t.fades_of(ids["sc"])]
  t.event(16.0, fn() { s.put(50.0) })
  t.frame(300.0, 200.0, now=16.0) |> ignore
  out.push(t.fades_of(ids["sc"]))
  t.event(32.0, fn() { s.put(180.0) })
  t.frame(300.0, 200.0, now=32.0) |> ignore
  out.push(t.fades_of(ids["sc"]))
  out
}

///|
test "Scroll::new fades what it holds towards an end it goes on past, as a plain box does; a page's own list does not" {
  let soft = [(0.0, 0.0, 0.0, 24.0), (0.0, 24.0, 0.0, 24.0), (0.0, 24.0, 0.0, 0.0)]
  // (a panel's list, a menu, a sidebar: cut softly, never sharply mid-row, with the list feel as without)
  assert_eq(fades_along(@view.Scroll::new()), soft)
  assert_eq(fades_along(@view.Scroll::plain()), soft)
  // (a page's own list ends at the window's or its bars' edges: none)
  let none = (0.0, 0.0, 0.0, 0.0)
  assert_eq(fades_along(@view.Scroll::list()), [none, none, none])
}

///|
test "Scroll::plain retains legacy capped-box scroll behavior with edge fades" {
  let s = @view.Scroll::plain()
  let ids : Map[String, @view.NodeId] = Map([])
  let t = @view.Tree::new(
    fn(root) {
      root.box(fn(sc) {
        ids["sc"] = sc.id()
        sc
        .width(Is(Some(240.0)))
        .height(Is(Some(120.0)))
        .scrolls(s, fn(inner) {
          for i in 0..<10 {
            inner.box(fn(r) { r.height(Is(Some(30.0))).words(Is("plain-\{i}")) |> ignore }) |> ignore
          }
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(300.0, 200.0, now=0.0) |> ignore
  assert_eq(s.most(), 180.0)
  // Legacy plain scroll applies bottom edge fade (top=0, bottom=24) when more content lies below.
  assert_eq(t.fades_of(ids["sc"]), (0.0, 0.0, 0.0, 24.0))
  t.event(16.0, fn() { s.put(50.0) })
  t.frame(300.0, 200.0, now=16.0) |> ignore
  assert_eq(t.fades_of(ids["sc"]), (0.0, 24.0, 0.0, 24.0))
}

///|
test "View::scroll_column creates Scroll automatically and fills parent flex without overflowing" {
  let ids : Map[String, @view.NodeId] = Map([])
  let explicit = @view.Scroll::new()
  let t = @view.Tree::new(
    fn(root) {
      // Auto-created Scroll, default fill=true under a 40px header in a 200px tall column.
      root.box(fn(col) {
        col.width(Is(Some(260.0))).height(Is(Some(200.0))) |> ignore
        col.box(fn(hdr) { hdr.height(Is(Some(40.0))) |> ignore }) |> ignore
        col.box(fn(sc) {
          ids["auto"] = sc.id()
          sc.scroll_column(fn(inner) {
            for i in 0..<15 {
              inner.box(fn(r) { r.height(Is(Some(30.0))).words(Is("auto-\{i}")) |> ignore }) |> ignore
            }
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
      // Explicit Scroll with fill=false keeps its own explicit height.
      root.box(fn(sc2) {
        ids["explicit"] = sc2.id()
        sc2
        .width(Is(Some(200.0)))
        .height(Is(Some(90.0)))
        .scroll_column(scroll=explicit, fill=false, fn(inner) {
          for i in 0..<10 {
            inner.box(fn(r) { r.height(Is(Some(30.0))).words(Is("exp-\{i}")) |> ignore }) |> ignore
          }
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(400.0, 400.0, now=0.0) |> ignore
  let auto_d = t.drawn_of(ids["auto"]).unwrap()
  assert_eq((auto_d.w, auto_d.h), (260.0, 160.0), msg="scroll_column fills remaining parent height")
  let exp_d = t.drawn_of(ids["explicit"]).unwrap()
  assert_eq((exp_d.w, exp_d.h), (200.0, 90.0))
  assert_eq(explicit.most(), 210.0)
}

///|
test "Scroll::new nested inside Scroll::new and inside Scroll::list scrolls cleanly without rows_list_nested_said" {
  let outer_list = @view.Scroll::list()
  let inner_in_list = @view.Scroll::new()
  let outer_new = @view.Scroll::new()
  let inner_in_new = @view.Scroll::new()
  let told : Array[String] = []
  @view.faults_stop.val = false
  @view.fault_told.val = Some(fn(said) { told.push(said) })
  let t = @view.Tree::new(
    fn(root) {
      root.box(fn(o) {
        o
        .width(Is(Some(240.0)))
        .height(Is(Some(140.0)))
        .scrolls(outer_list, fn(oh) {
          oh.box(fn(i) {
            i
            .width(Is(Some(220.0)))
            .height(Is(Some(80.0)))
            .scrolls(inner_in_list, fn(ih) {
              for k in 0..<8 {
                ih.box(fn(r) { r.height(Is(Some(30.0))).words(Is("in-list-\{k}")) |> ignore }) |> ignore
              }
            })
            |> ignore
          })
          |> ignore
          oh.box(fn(pad) { pad.height(Is(Some(200.0))) |> ignore }) |> ignore
        })
        |> ignore
      })
      |> ignore
      root.box(fn(o2) {
        o2
        .width(Is(Some(240.0)))
        .height(Is(Some(140.0)))
        .scrolls(outer_new, fn(oh) {
          oh.box(fn(i) {
            i
            .width(Is(Some(220.0)))
            .height(Is(Some(80.0)))
            .scrolls(inner_in_new, fn(ih) {
              for k in 0..<8 {
                ih.box(fn(r) { r.height(Is(Some(30.0))).words(Is("in-new-\{k}")) |> ignore }) |> ignore
              }
            })
            |> ignore
          })
          |> ignore
          oh.box(fn(pad) { pad.height(Is(Some(200.0))) |> ignore }) |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(300.0, 400.0, now=0.0) |> ignore
  @view.faults_stop.val = true
  @view.fault_told.val = None
  assert_eq(told, [], msg="nested Scroll::new must not trigger rows_list_nested_said")
  t.event(16.0, fn() {
    outer_list.put(40.0)
    inner_in_list.put(60.0)
    outer_new.put(30.0)
    inner_in_new.put(50.0)
  })
  t.frame(300.0, 400.0, now=16.0) |> ignore
  assert_eq((outer_list.at(t), inner_in_list.at(t)), (40.0, 60.0))
  assert_eq((outer_new.at(t), inner_in_new.at(t)), (30.0, 50.0))
}

///|
test "Scroll::list nested inside Scroll::list still triggers rows_list_nested_said guard" {
  let outer = @view.Scroll::list()
  let inner = @view.Scroll::list()
  let told : Array[String] = []
  @view.faults_stop.val = false
  @view.fault_told.val = Some(fn(said) { told.push(said) })
  let t = @view.Tree::new(
    fn(root) {
      root.box(fn(o) {
        o
        .width(Is(Some(240.0)))
        .height(Is(Some(140.0)))
        .scrolls(outer, fn(oh) {
          oh.box(fn(i) {
            i
            .width(Is(Some(220.0)))
            .height(Is(Some(80.0)))
            .scrolls(inner, fn(ih) {
              ih.box(fn(r) { r.height(Is(Some(30.0))).words(Is("nested")) |> ignore }) |> ignore
            })
            |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(300.0, 300.0, now=0.0) |> ignore
  @view.faults_stop.val = true
  @view.fault_told.val = None
  assert_true(told.length() > 0, msg="nested Scroll::list must still fault")
  assert_true(told[0].contains("a page's list made in a row of another page's list"), msg=told[0])
}

///|
/// A column 20 padded at its foot, a box 120 tall scrolling 10 rows of 30 in it, then `under` points of something more
/// (0: nothing): how far past its foot the box draws what it holds, saying it goes on into the column's room with 8 more.
fn past_at_foot(under : Double) -> Double {
  let ids : Map[String, @view.NodeId] = Map([])
  let t = @view.Tree::new(
    fn(root) {
      root.box(fn(col) {
        col.width(Is(Some(240.0))).padding(Is((0.0, 0.0, 0.0, 20.0))) |> ignore
        col.box(fn(sc) {
          ids["sc"] = sc.id()
          sc
          .height(Is(Some(120.0)))
          .scrolls(@view.Scroll::new(), fn(inner) {
            for i in 0..<10 {
              inner.box(fn(r) { r.height(Is(Some(30.0))).words(Is("row-\{i}")) |> ignore }) |> ignore
            }
          })
          .fades_past(col, beyond=8.0)
          |> ignore
        })
        |> ignore
        if under > 0.0 {
          col.box(fn(b) { b.height(Is(Some(under))) |> ignore }) |> ignore
        }
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(300.0, 400.0, now=0.0) |> ignore
  t.clips_past_of(ids["sc"])
}

///|
test "View::fades_past: a box scrolling at the end of what holds it goes on into the room under it, none with anything under it" {
  // (the column's padding at its foot, and the room said beyond it)
  assert_eq(past_at_foot(0.0), 28.0)
  // (a field under it: cut at its own foot)
  assert_eq(past_at_foot(40.0), 0.0)
}
