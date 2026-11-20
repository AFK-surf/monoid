// Layout ergonomics (`View::fill`, `View::center`), `View::scrolls(fill=true)`, `View::list_reused`,
// `View::pick` / `View::switch_by` native `keeps` / `keeps_max`, and `View::float_beside`.

///|
test "View::fill fills remaining space in nested flex row and column without overflowing parent" {
  let ids : Map[String, @view.NodeId] = Map([])
  let long_text = "a very long single-line string that would otherwise expand its flex item past the parent container width when min-width is not zero"
  let t = @view.Tree::new(
    fn(root) {
      // Nested flex row: fixed 80px sibling + fill() box holding long text inside a 300x100 parent.
      root.box(fn(row) {
        ids["row"] = row.id()
        row.row(Is(true)).width(Is(Some(300.0))).height(Is(Some(100.0))) |> ignore
        row.box(fn(side) { side.width(Is(Some(80.0))).height(Is(Some(100.0))) |> ignore }) |> ignore
        row.box(fn(main) {
          ids["row_fill"] = main.id()
          main.fill() |> ignore
          main.box(fn(lbl) { lbl.words(Is(long_text)) |> ignore }) |> ignore
        })
        |> ignore
      })
      |> ignore
      // Nested flex column: fixed 50px header + fill() box holding a 400px tall child inside a 300x200 parent.
      root.box(fn(col) {
        ids["col"] = col.id()
        col.width(Is(Some(300.0))).height(Is(Some(200.0))) |> ignore
        col.box(fn(hdr) { hdr.height(Is(Some(50.0))) |> ignore }) |> ignore
        col.box(fn(body) {
          ids["col_fill"] = body.id()
          body.fill() |> ignore
          body.box(fn(tall) { tall.height(Is(Some(400.0))) |> ignore }) |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(400.0, 400.0) |> ignore
  let row_d = t.drawn_of(ids["row"]).unwrap()
  let row_fill_d = t.drawn_of(ids["row_fill"]).unwrap()
  assert_eq((row_d.w, row_d.h), (300.0, 100.0))
  assert_eq((row_fill_d.w, row_fill_d.h), (220.0, 100.0))
  let col_d = t.drawn_of(ids["col"]).unwrap()
  let col_fill_d = t.drawn_of(ids["col_fill"]).unwrap()
  assert_eq((col_d.w, col_d.h), (300.0, 200.0))
  assert_eq((col_fill_d.w, col_fill_d.h), (300.0, 150.0))
}

///|
test "View::center centers child both horizontally and vertically" {
  let ids : Map[String, @view.NodeId] = Map([])
  let t = @view.Tree::new(
    fn(root) {
      root.box(fn(box) {
        box.width(Is(Some(200.0))).height(Is(Some(120.0))).center() |> ignore
        box.box(fn(child) {
          ids["child"] = child.id()
          child.width(Is(Some(60.0))).height(Is(Some(30.0))) |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(300.0, 300.0) |> ignore
  let c = t.drawn_of(ids["child"]).unwrap()
  assert_eq((c.x, c.y, c.w, c.h), (70.0, 45.0, 60.0, 30.0))
}

///|
test "View::scrolls(fill=true) fills remaining parent height without overflowing" {
  let s = @view.Scroll::new()
  let ids : Map[String, @view.NodeId] = Map([])
  let t = @view.Tree::new(
    fn(root) {
      root.box(fn(col) {
        col.width(Is(Some(300.0))).height(Is(Some(200.0))) |> ignore
        col.box(fn(hdr) { hdr.height(Is(Some(40.0))) |> ignore }) |> ignore
        col.box(fn(sc) {
          ids["sc"] = sc.id()
          sc.scrolls(s, fill=true, fn(inner) {
            for i in 0..<20 {
              inner.box(fn(r) { r.height(Is(Some(30.0))).words(Is("row-\{i}")) |> ignore }) |> ignore
            }
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(400.0, 400.0) |> ignore
  let d = t.drawn_of(ids["sc"]).unwrap()
  assert_eq((d.w, d.h), (300.0, 160.0))
  assert_eq(s.most(), 440.0)
}

///|
test "View::list_reused virtualizes 1000 items, reuses rows on scroll, and fills parent by default" {
  let s = @view.Scroll::new()
  let keys = Array::makei(1000, fn(i) { i })
  let made = Ref(0)
  let ids : Map[String, @view.NodeId] = Map([])
  let t = @view.Tree::new(
    fn(root) {
      root.box(fn(col) {
        col.width(Is(Some(300.0))).height(Is(Some(200.0))) |> ignore
        col.box(fn(hdr) { hdr.height(Is(Some(40.0))) |> ignore }) |> ignore
        col.box(fn(list) {
          ids["list"] = list.id()
          list.list_reused(
            fn() { keys },
            fn(row, key) {
              made.val += 1
              row.height(Is(Some(40.0))).words(By(fn() { "item-\{key()}" })) |> ignore
            },
            scroll=s,
            est=40.0,
            at_once=true,
          )
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(400.0, 400.0) |> ignore
  let d = t.drawn_of(ids["list"]).unwrap()
  assert_eq((d.w, d.h), (300.0, 160.0))
  assert_true(made.val > 0 && made.val < 30, msg="only visible window rows created initially")
  let initial_made = made.val
  let shown0 = t.drawn().filter(fn(x) { x.words.has_prefix("item-") }).map(fn(x) { x.words })
  assert_true(shown0.contains("item-0"))
  // Scroll far down (row 50 is at y = 2000.0) and verify reuse without rebuilding 50+ rows.
  t.event(16.0, fn() { s.put(2000.0) })
  t.frame(400.0, 400.0, now=16.0) |> ignore
  t.frame(400.0, 400.0, now=32.0) |> ignore
  let shown1 = t.drawn().filter(fn(x) { x.words.has_prefix("item-") }).map(fn(x) { x.words })
  assert_true(shown1.contains("item-50"), msg="scrolled to item-50")
  assert_true(made.val <= initial_made + 10, msg="rows reused instead of recreated")
}

///|
test "View::pick(keeps=true) parks inactive branches, rests bindings while parked, and wakes without remaking" {
  let tab = @signals.signal("a", same=fn(a, b) { a == b })
  let value = @signals.signal(1, same=fn(a, b) { a == b })
  let made : Map[String, Int] = Map([])
  let evals : Map[String, Int] = Map([])
  let nodes : Map[String, @view.View] = Map([])
  let t = @view.Tree::new(
    fn(root) {
      root.pick(
        fn() { tab.get() },
        fn(v, k) {
          made[k] = made.get(k).unwrap_or(0) + 1
          nodes[k] = v
          v.height(Is(Some(40.0))).words(By(fn() {
            evals[k] = evals.get(k).unwrap_or(0) + 1
            "\{k}:\{value.get()}"
          }))
          |> ignore
        },
        keeps=true,
      )
    },
    time=fn() { 0.0 },
  )
  t.frame(300.0, 200.0, now=0.0) |> ignore
  let a_node = nodes["a"]
  assert_eq(t.drawn().filter(fn(d) { d.words != "" }).map(fn(d) { d.words }), ["a:1"])
  assert_eq(made.get("a"), Some(1))
  let a_evals_before = evals["a"]
  // Switch to "b": "a" is parked (alive, not drawn).
  t.event(16.0, fn() { tab.set("b") })
  t.frame(300.0, 200.0, now=16.0) |> ignore
  assert_true(a_node.alive())
  assert_eq(t.drawn().filter(fn(d) { d.words != "" }).map(fn(d) { d.words }), ["b:1"])
  // Mutate signal while "a" is parked: "a"'s binding must NOT recompute.
  t.event(32.0, fn() { value.set(42) })
  t.frame(300.0, 200.0, now=32.0) |> ignore
  assert_eq(evals["a"], a_evals_before)
  assert_eq(t.drawn().filter(fn(d) { d.words != "" }).map(fn(d) { d.words }), ["b:42"])
  // Switch back to "a": same node, make NOT re-run, wakes and syncs latest value 42.
  t.event(48.0, fn() { tab.set("a") })
  t.frame(300.0, 200.0, now=48.0) |> ignore
  assert_eq(made.get("a"), Some(1))
  assert_eq(nodes["a"].id(), a_node.id())
  assert_eq(evals["a"], a_evals_before + 1)
  assert_eq(t.drawn().filter(fn(d) { d.words != "" }).map(fn(d) { d.words }), ["a:42"])
}

///|
test "View::pick(keeps=true) wakes parked inner show changes immediately without playing comes animation" {
  let tab = @signals.signal("a", same=fn(a, b) { a == b })
  let extra = @signals.signal(false, same=fn(a, b) { a == b })
  let nodes : Map[String, @view.View] = Map([])
  let extra_id : Ref[@view.NodeId?] = Ref(None)
  let t = @view.Tree::new(
    fn(root) {
      root.pick(
        fn() { tab.get() },
        fn(v, k) {
          nodes[k] = v
          v.box(fn(b) { b.height(Is(Some(30.0))).words(Is("head-\{k}")) |> ignore }) |> ignore
          if k == "a" {
            v.show(fn() { extra.get() }, fn(s) {
              extra_id.val = Some(s.id())
              s.height(Is(Some(40.0))).words(Is("extra-shown")) |> ignore
            })
          }
        },
        keeps=true,
      )
    },
    time=fn() { 0.0 },
  )
  t.frame(300.0, 200.0, now=0.0) |> ignore
  // Switch away to "b", flip inner `show` while "a" is parked.
  t.event(16.0, fn() { tab.set("b") })
  t.frame(300.0, 200.0, now=16.0) |> ignore
  t.event(32.0, fn() { extra.set(true) })
  t.frame(300.0, 200.0, now=32.0) |> ignore
  // Switch back to "a": inner `show` settles immediately at full height with no comes animation.
  t.event(48.0, fn() { tab.set("a") })
  t.frame(300.0, 200.0, now=48.0) |> ignore
  assert_eq(nodes["a"].comes_end(), -1.0, msg="no comes animation played when waking parked branch")
  let ed = t.drawn_of(extra_id.val.unwrap()).unwrap()
  assert_eq((ed.words, ed.h), ("extra-shown", 40.0))
}

///|
test "View::switch_by(keeps=true, keeps_max=2) evicts LRU branch and releases all parked branches when parent dies" {
  let alive = @signals.signal(true, same=fn(a, b) { a == b })
  let tab = @signals.signal("a", same=fn(a, b) { a == b })
  let made : Map[String, Int] = Map([])
  let nodes : Map[String, @view.View] = Map([])
  let t = @view.Tree::new(
    fn(root) {
      root.show(at_once=true, fn() { alive.get() }, fn(host) {
        host.switch_by(
          fn() { tab.get() },
          fn(v, k) {
            made[k] = made.get(k).unwrap_or(0) + 1
            nodes[k] = v
            v.height(Is(Some(30.0))).words(Is(k)) |> ignore
          },
          keeps=true,
          keeps_max=2,
        )
      })
    },
    time=fn() { 0.0 },
  )
  t.frame(300.0, 200.0, now=0.0) |> ignore
  let na = nodes["a"]
  // a -> b -> c: parked = [a, b], active = c.
  t.event(16.0, fn() { tab.set("b") })
  t.frame(300.0, 200.0, now=16.0) |> ignore
  let nb = nodes["b"]
  t.event(32.0, fn() { tab.set("c") })
  t.frame(300.0, 200.0, now=32.0) |> ignore
  let nc = nodes["c"]
  assert_true(na.alive() && nb.alive() && nc.alive())
  // c -> a: hits parked "a" before parking "c", so parked = [b, c], active = a, nothing evicted.
  t.event(48.0, fn() { tab.set("a") })
  t.frame(300.0, 200.0, now=48.0) |> ignore
  assert_eq(made.get("a"), Some(1))
  assert_true(na.alive() && nb.alive() && nc.alive())
  // a -> d: parks "a", parked exceeds 2 -> evicts LRU "b"; parked = [c, a], active = d.
  t.event(64.0, fn() { tab.set("d") })
  t.frame(300.0, 200.0, now=64.0) |> ignore
  let nd = nodes["d"]
  assert_false(nb.alive(), msg="LRU branch b evicted")
  assert_true(nc.alive() && na.alive() && nd.alive())
  // d -> b: b was evicted, so it must be remade; parks "d", evicts LRU "c".
  t.event(80.0, fn() { tab.set("b") })
  t.frame(300.0, 200.0, now=80.0) |> ignore
  let nb2 = nodes["b"]
  assert_eq(made.get("b"), Some(2))
  assert_false(nc.alive(), msg="LRU branch c evicted")
  assert_true(na.alive() && nd.alive() && nb2.alive())
  // Destroy parent container: active AND all parked branches must be released (zero leak).
  t.event(96.0, fn() { alive.set(false) })
  t.frame(300.0, 200.0, now=96.0) |> ignore
  assert_false(na.alive())
  assert_false(nd.alive())
  assert_false(nb2.alive())
}

///|
test "View::float_beside floats over parent and positions beside anchor when present" {
  let ids : Map[String, @view.NodeId] = Map([])
  let t = @view.Tree::new(
    fn(root) {
      let anchor = root.box(fn(a) {
        ids["a"] = a.id()
        a.over(Is(true)).offset(Is((60.0, 40.0))).width(Is(Some(80.0))).height(Is(Some(24.0))) |> ignore
      })
      root.box(fn(f) {
        ids["f"] = f.id()
        f.float_beside(Some(anchor), side=Bottom, along=Start, offset=6.0).width(Is(Some(100.0))).height(Is(Some(30.0)))
        |> ignore
      })
      |> ignore
      root.box(fn(n) {
        ids["n"] = n.id()
        n.float_beside(None).width(Is(Some(50.0))).height(Is(Some(20.0))) |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(400.0, 300.0) |> ignore
  let fd = t.drawn_of(ids["f"]).unwrap()
  assert_eq((fd.x, fd.y, fd.w, fd.h), (60.0, 70.0, 100.0, 30.0))
  let nd = t.drawn_of(ids["n"]).unwrap()
  assert_eq((nd.x, nd.y, nd.w, nd.h), (0.0, 0.0, 50.0, 20.0))
}

///|
test "View::fixed, View::rigid, View::as_row, View::clip, and View::cut prevent squashing and compose cleanly" {
  let ids : Map[String, @view.NodeId] = Map([])
  let long_label = "an extraordinarily long title that definitely overflows a narrow row unless it gives way via cut"
  let t = @view.Tree::new(
    fn(root) {
      // Narrow 160px row: fixed(36, 36) avatar + cut() single-line title + rigid() 44px badge.
      root.box(fn(row) {
        ids["row"] = row.id()
        row.as_row().clip().width(Is(Some(160.0))).height(Is(Some(48.0))) |> ignore
        row.box(fn(avatar) {
          ids["avatar"] = avatar.id()
          avatar.fixed(36.0, 36.0) |> ignore
        })
        |> ignore
        row.box(fn(title) {
          ids["title"] = title.id()
          title.cut().words(Is(long_label), one_line=true) |> ignore
        })
        |> ignore
        row.box(fn(badge) {
          ids["badge"] = badge.id()
          badge.width(Is(Some(44.0))).height(Is(Some(24.0))).rigid() |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(300.0, 200.0) |> ignore
  let row_d = t.drawn_of(ids["row"]).unwrap()
  let avatar_d = t.drawn_of(ids["avatar"]).unwrap()
  let title_d = t.drawn_of(ids["title"]).unwrap()
  let badge_d = t.drawn_of(ids["badge"]).unwrap()
  assert_true(row_d.clips, msg="View::clip enables clipping")
  assert_eq((avatar_d.w, avatar_d.h), (36.0, 36.0), msg="View::fixed keeps exact size under pressure")
  assert_eq((badge_d.w, badge_d.h), (44.0, 24.0), msg="View::rigid prevents flex shrink")
  // Row lays out horizontally: avatar on left, title in middle, badge on right.
  assert_eq(avatar_d.x, 0.0)
  assert_eq(title_d.x, 36.0)
  assert_eq(title_d.w, 80.0, msg="View::cut shrinks title to remaining row width")
  assert_eq(badge_d.x, 116.0)
  assert_true(t.allows_ellipsis(ids["title"]), msg="View::cut marks node as allowing ellipsis")
}

///|
test "WordsLook::of and chainable helpers derive looks, and View::words supports one_line and optical" {
  let base = @view.WordsLook::of(14.0)
  assert_eq(base.size, 14.0)
  assert_eq(base.weight, 400)
  assert_eq(base.line, 0.0)
  assert_true(base.wrap)
  assert_eq(base.tracking, @view.letters_own)
  assert_false(base.balance)
  assert_eq(base.max_lines, 0)

  let derived = base.with_weight(600).with_line(-1.4).one_line()
  assert_eq(derived.size, 14.0)
  assert_eq(derived.weight, 600)
  assert_eq(derived.line, -1.4)
  assert_false(derived.wrap)

  let resized_keep = derived.with_size(18.0)
  assert_eq((resized_keep.size, resized_keep.line, resized_keep.weight), (18.0, -1.4, 600))
  let resized_new = derived.with_size(20.0, line=26.0)
  assert_eq((resized_new.size, resized_new.line), (20.0, 26.0))

  let clamped = derived.with_max_lines(2)
  assert_true(clamped.wrap)
  assert_eq(clamped.max_lines, 2)

  let ids : Map[String, @view.NodeId] = Map([])
  let t = @view.Tree::new(
    fn(root) {
      root.box(fn(pill) {
        ids["pill"] = pill.id()
        pill.words(Is("Action"), look=@view.WordsLook::of(13.0, weight=500), one_line=true, optical=true) |> ignore
      })
      |> ignore
      root.box(fn(plain) {
        ids["plain"] = plain.id()
        plain.words(Is("Plain")) |> ignore
      })
      |> ignore
    },
    time=fn() { 0.0 },
  )
  t.frame(300.0, 200.0) |> ignore
  let pill_d = t.drawn_of(ids["pill"]).unwrap()
  assert_false(pill_d.words_look.wrap, msg="one_line=true overrides wrap to false")
  assert_eq(pill_d.words_look.size, 13.0)
  assert_eq(pill_d.words_look.weight, 500)
  assert_true(pill_d.words_optical, msg="optical=true enables words_optical")
  let plain_d = t.drawn_of(ids["plain"]).unwrap()
  assert_true(plain_d.words_look.wrap)
  assert_false(plain_d.words_optical)
}
