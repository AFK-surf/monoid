// Where a scripted run's step presses a node of the window's tree that something lies over in part (reachable,
// tree_reach_point): its middle under a page's bar, the point of it in sight nearest its middle that a finger reaches,
// as an old view's is found (reach_point); all of it under a scrim, none, and the failure says what lies over it.

///|
/// A picture 240 tall from 46 above the window's top (its middle at 74), pressed; a bar 88 tall over the window's top,
/// pressed; and, while `scrim`, a scrim over all of the window, pressed.
fn reach_tester(scrim : @signals.Signal[Bool], pressed : Ref[Int]) -> Tester {
  let t = Tester::new(fn(_c) {  }, w=390.0, h=844.0, platform=0, images=[("tree/glyph/cat.png", 390, 240)])
  set_view_app(fn(root) {
    root.box(fn(p) {
      p
      .over(Is(true), edges=(Some(0.0), Some(-46.0), None, None))
      .width(Is(Some(390.0)))
      .height(Is(Some(240.0)))
      .image(Is(Some(("tree/glyph/cat.png", "", 64))))
      .says(Is(Some(@view.said(Button, label="图片"))))
      .presses(Is(true))
      .on_press(fn() { pressed.val += 1 })
      |> ignore
    })
    |> ignore
    root.box(fn(b) {
      b
      .over(Is(true), edges=(Some(0.0), Some(0.0), None, None))
      .width(Is(Some(390.0)))
      .height(Is(Some(88.0)))
      .ground(Is(0xFFFFFFFFL))
      .says(Is(Some(@view.said(Button, label="顶栏"))))
      .presses(Is(true))
      .on_press(fn() {  })
      |> ignore
    })
    |> ignore
    root.show(fn() { scrim.get() }, fn(l) {
      l.over(Is(true)) |> ignore
      l.box(fn(s) {
        s
        .over(Is(true))
        .ground(Is(0x00000080L))
        .says(Is(Some(@view.said(Button, label="遮罩"))))
        .presses(Is(true))
        .on_press(fn() {  })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "a picture whose middle is under a page's bar: reached at the point of it in sight nearest its middle, just under the bar, and a scripted tap presses it there" {
  let scrim = @signals.signal(false)
  let pressed = Ref(0)
  let t = reach_tester(scrim, pressed)
  let seen = t.locate("img:glyph/cat")
  let at = t.reachable("img:glyph/cat")
  // (its middle 195,74 under the bar; on the grid of 4 from the window's corner, 2 past each line: the row at 90 the
  // first below the bar's foot at 88, and of it 194 and 198 as near, the one further left)
  assert_eq((seen, at), ([(195.0, 74.0)], [(194.0, 90.0)]))
  t.tap(at[0].0, at[0].1)
  assert_eq(pressed.val, 1, msg="tapped where reached")
  t.fake.logs.clear()
  drive_start("timeout 1000\ntap img:glyph/cat\nexit", "")
  let mut n = 0
  while driver.val is Some(_) && n < 300 {
    t.frame()
    n = n + 1
  }
  let log = t.fake.logs.copy()
  assert_true(log.iter().any(fn(l) { l.contains("DRIVE PASS") }), msg=log.join("\n"))
  assert_eq(pressed.val, 2, msg=log.join("\n"))
}

///|
test "a picture all under a scrim: not reached, and the failure says what lies over it, where, how big and what it is called" {
  let scrim = @signals.signal(true)
  let pressed = Ref(0)
  let t = reach_tester(scrim, pressed)
  assert_eq(t.reachable("img:glyph/cat"), [])
  let why = not_reachable(g(), "img:glyph/cat", 1000.0)
  assert_eq(
    why,
    "on screen but under something else to press (what lies over it: a composer, a sheet, a scrim) after 1000 ms: " +
    "at 195,74 a tree node taking presses 0,0 390x844 holding \"遮罩\"",
  )
  assert_eq(pressed.val, 0)
}

///|
test "words over what takes the press under them (a sheet's title over the top that drags it): reached there, a scripted drag from them drags what is under them" {
  let dragged = Ref(0.0)
  let t = Tester::new(fn(_c) {  }, w=390.0, h=844.0, platform=0)
  set_view_app(fn(root) {
    root.box(fn(sheet) {
      sheet.over(Is(true), edges=(Some(0.0), Some(500.0), Some(0.0), None)).height(Is(Some(300.0))) |> ignore
      // (its top: what drags it, under its title)
      sheet.box(fn(top) {
        top
        .over(Is(true), edges=(Some(0.0), Some(0.0), Some(0.0), None))
        .height(Is(Some(64.0)))
        .as_ground()
        .on_drag(fn(d) { dragged.val = d.wy })
        |> ignore
      })
      |> ignore
      sheet.box(fn(head) {
        head.padding(Is((24.0, 28.0, 24.0, 0.0))) |> ignore
        head.box(fn(w) { w.words(Is("标题")) |> ignore }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let at = t.reachable("标题")
  assert_eq(at.length(), 1, msg=Repr(at).to_string())
  t.fake.logs.clear()
  drive_start("timeout 1000\ndragon 0 -100 200 标题\nexit", "")
  let mut n = 0
  while driver.val is Some(_) && n < 300 {
    t.frame()
    n = n + 1
  }
  let log = t.fake.logs.copy()
  assert_true(log.iter().any(fn(l) { l.contains("DRIVE PASS") }), msg=log.join("\n"))
  assert_true(dragged.val > 0.0 && dragged.val < at[0].1, msg="dragged to \{dragged.val}")
}

///|
test "words over what takes the press under them: not reached where a small button's finger room past its box takes the press, nor under a button drawn over them" {
  let words : Ref[@view.NodeId?] = Ref(None)
  let t = Tester::new(fn(_c) {  }, w=390.0, h=844.0, platform=2)
  set_view_app(fn(root) {
    root.box(fn(sheet) {
      sheet.over(Is(true), edges=(Some(0.0), Some(500.0), Some(0.0), None)).height(Is(Some(300.0))) |> ignore
      sheet.box(fn(top) {
        top
        .over(Is(true), edges=(Some(0.0), Some(0.0), Some(0.0), None))
        .height(Is(Some(64.0)))
        .as_ground()
        .on_drag(fn(_) {  })
        |> ignore
      })
      |> ignore
      // (a button 24 across ending 6 before the words, at 30 to 54: its finger room, 44 across, reaches past 60)
      sheet.box(fn(b) {
        b
        .over(Is(true), edges=(Some(30.0), Some(24.0), None, None))
        .width(Is(Some(24.0)))
        .height(Is(Some(24.0)))
        .ground(Is(0xFF0000FFL))
        .says(Is(Some(@view.said(Button, label="小"))))
        .presses(Is(true))
        .on_press(fn() {  })
        |> ignore
      })
      |> ignore
      sheet.box(fn(head) {
        head.padding(Is((60.0, 24.0, 24.0, 0.0))) |> ignore
        head.box(fn(l) {
          l.words(Is("标题标题标题标题")) |> ignore
          words.val = Some(l.id())
        })
        |> ignore
      })
      |> ignore
      // (a button over the words' middle, at 100 to 124 across, drawn after them)
      sheet.box(fn(x) {
        x
        .over(Is(true), edges=(Some(100.0), Some(24.0), None, None))
        .width(Is(Some(24.0)))
        .height(Is(Some(24.0)))
        .ground(Is(0x00FF00FFL))
        .says(Is(Some(@view.said(Button, label="关"))))
        .presses(Is(true))
        .on_press(fn() {  })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let tree = view_app.val.unwrap()
  let target = words.val.unwrap()
  let y = 500.0 + 24.0 + 6.0
  // (on the words, clear of both buttons: the top that drags under them takes it)
  assert_true(tree_reaches_at(g(), tree, target, 80.0, y), msg="clear of both")
  // (on the words, in the small button's finger room past its box: a finger's, 44 across)
  assert_true(view_presses_at(62.0, y) is Some(_), msg="the room taken")
  assert_false(tree_reaches_at(g(), tree, target, 62.0, y), msg="in the small button's room")
  // (on the words, under the button drawn over them)
  assert_false(tree_reaches_at(g(), tree, target, 112.0, y), msg="under the button over them")
}
