// A place in a panel's foot that comes and goes (foot_place_node): one button and two, at a sheet's foot with a finger
// and with a mouse and at a dialog's in the middle of a window, each where it stood when it stood where the old foot's
// (drawing a button or not each frame) did, and as wide; one going, the other's width at once.

///|
/// Where each of the foot's buttons stands (by its words), a panel opened by nothing on a window `at`, its foot holding 稍后
/// while `two` says so and 下载 always (foot_place_node), at rest; then, `two` turned, at that frame and at rest. Closed
/// after, gone.
fn foot_place_stood(at : (Int, Double, Double)) -> Array[String] raise {
  let two = @signals.signal(true)
  let open = fn(_from : Anchor) {
    panel_nodes(
      "一个",
      from=Unanchored,
      fn(v, _) { words_node(v, fn() { "它说的话" }, fn() { secondary }) |> ignore },
      foot=fn(v, _) {
        foot_place_node(v, fn() { two.get() }, fn(p) { button_node(p, fn() { "稍后" }, fn() {  }, tone=Ghost) |> ignore })
        button_node(v, fn() { "下载" }, fn() {  }, tone=Primary) |> ignore
      },
    )
  }
  presenters_reset()
  let (platform, w, h) = at
  let t = @ui.Tester::new(
    fn(c) { c.with_theme(ui_theme(), fn() { @ui.old_views_here(c) }) },
    tree=presented_tree(presenting_view(open)),
    w~,
    h~,
    platform~,
  )
  t.check_looks(false)
  t.draw()
  t.tap_text("打开")
  t.run_for(@ui.move_most_ms)
  t.leave()
  t.draw()
  let k = fn(v : Double) { (v * 1000.0).round() / 1000.0 }
  let stood : Array[String] = []
  let say = fn(when : String) {
    for label in ["稍后", "下载"] {
      let all = t.all(Button, label~)
      let r = if all.length() == 1 { "\{k(all[0].rect.0)},\{k(all[0].rect.1)} \{k(all[0].rect.2)}x\{k(all[0].rect.3)}" } else { "\{all.length()} of it" }
      stood.push("\{when}: \{label} \{r}")
    }
  }
  say("two")
  two.set(false)
  t.draw()
  say("one, at once")
  t.run_for(@ui.move_most_ms)
  say("one")
  two.set(true)
  t.draw()
  say("two again, at once")
  close_all_presented()
  t.run_for(@ui.move_most_ms)
  assert_false(presented_drawn(), msg="closed")
  stood
}

///|
test "a place in a panel's foot that comes and goes: a sheet's with a finger and with a mouse, a dialog's in the middle of a window" {
  let seen : Array[String] = []
  for screen in [("sheet", phone), ("sheet, with a mouse", (0, 390.0, 844.0)), ("dialog", (0, 800.0, 600.0))] {
    let (about, at) = screen
    seen.push("\{about}:")
    seen.append(foot_place_stood(at))
  }
  inspect(seen.join("\n"), content=(
    #|sheet:
    #|two: 稍后 20,788 171x32
    #|two: 下载 199,788 171x32
    #|one, at once: 稍后 0 of it
    #|one, at once: 下载 20,788 350x32
    #|one: 稍后 0 of it
    #|one: 下载 20,788 350x32
    #|two again, at once: 稍后 20,788 171x32
    #|two again, at once: 下载 199,788 171x32
    #|sheet, with a mouse:
    #|two: 稍后 20,788 171x32
    #|two: 下载 199,788 171x32
    #|one, at once: 稍后 0 of it
    #|one, at once: 下载 20,788 350x32
    #|one: 稍后 0 of it
    #|one: 下载 20,788 350x32
    #|two again, at once: 稍后 20,788 171x32
    #|two again, at once: 下载 199,788 171x32
    #|dialog:
    #|two: 稍后 518,329.5 54x32
    #|two: 下载 580,329.5 54x32
    #|one, at once: 稍后 0 of it
    #|one, at once: 下载 580,329.5 54x32
    #|one: 稍后 0 of it
    #|one: 下载 580,329.5 54x32
    #|two again, at once: 稍后 518,329.5 54x32
    #|two again, at once: 下载 580,329.5 54x32

  ))
}

///|
test "a place in a sheet's foot takes a button's share whatever it holds: words alone in it, the button beside it as wide as beside a button" {
  // (下载's place beside a place holding a button, then beside one holding words alone: the same)
  let stood = fn(words_only : Bool) -> String raise {
    let open = fn(_from : Anchor) {
      panel_nodes(
        "一个",
        from=Unanchored,
        fn(v, _) { words_node(v, fn() { "它说的话" }, fn() { secondary }) |> ignore },
        foot=fn(v, _) {
          foot_place_node(v, fn() { true }, fn(p) {
            if words_only {
              words_node(p, fn() { "稍后" }, fn() { secondary }) |> ignore
            } else {
              button_node(p, fn() { "稍后" }, fn() {  }, tone=Ghost) |> ignore
            }
          })
          button_node(v, fn() { "下载" }, fn() {  }, tone=Primary) |> ignore
        },
      )
    }
    presenters_reset()
    let t = @ui.Tester::new(
      fn(c) { c.with_theme(ui_theme(), fn() { @ui.old_views_here(c) }) },
      tree=presented_tree(presenting_view(open)),
      w=phone.1,
      h=phone.2,
      platform=phone.0,
    )
    t.check_looks(false)
    t.draw()
    t.tap_text("打开")
    t.run_for(@ui.move_most_ms)
    let all = t.all(Button, label="下载")
    assert_eq(all.length(), 1)
    let r = all[0].rect
    close_all_presented()
    t.run_for(@ui.move_most_ms)
    assert_false(presented_drawn(), msg="closed")
    "\{r.0},\{r.1} \{r.2}x\{r.3}"
  }
  assert_eq(stood(true), stood(false))
}
