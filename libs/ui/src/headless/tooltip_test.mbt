// The headless tooltip (@headless.TooltipGroup, tooltip_bubble), under a look of the tests' own: three buttons of one
// group, their tip shown in a bubble while the group says so. The pointer resting on one opens its tip after the
// delay and not before; gone on to a neighbour while the group is warm, at once; a press, Escape, the trigger disabled
// or let go close it at once and call off what was waited for; a finger opens none. Each window is made by `window`
// (window_test.mbt), which holds that tooltip.mbt draws and lays out nothing.

///|
/// How long the pointer rests on a trigger before its tip opens (the group's `open_delay_ms`, its default).
let open_ms : Double = 400.0

///|
/// How long after a tip closed the group is warm (its `warmup_ms`, its default).
let warm_ms : Double = 300.0

///|
/// The least step of the clock a test takes: a moment before what is due, or past a window's end.
let tick_ms : Double = 1.0

///|
/// Long past every delay of the group: what was waited for is due by then, or never.
let quiet_ms : Double = 1000.0

///|
/// What a case keeps: its window, the tip shown (the caller's), whether 丙 is disabled and whether it is there, the
/// keys Escape came to below the tips (the root's own keys), the group, and each trigger's node by its name (the last
/// made of it).
struct TipCase {
  t : @ui.Tester
  shown : @signals.Signal[String?]
  off : @signals.Signal[Bool]
  there : @signals.Signal[Bool]
  escapes : Ref[Int]
  group : @headless.TooltipGroup[String]
  ids : Map[String, @view.NodeId]
}

///|
/// A window with the keymap `tooltip_keys`, three buttons 甲 乙 丙 (100 by 40, down a column; 丙 disabled while `off`,
/// made while `there`), each a trigger of one group (its tip the button's name), a box "别处" that takes the focus and
/// is no trigger, and the tip shown: a bubble read out as "提示：" and its key, made while the group says one is
/// shown. The root's own keys count the Escapes they are told.
fn tip_case(pointing? : @ui.Pointing = Mouse) -> TipCase raise {
  let flag = fn(v : Bool) { @signals.signal(v, same=fn(a : Bool, b : Bool) { a == b }) }
  let shown : @signals.Signal[String?] = @signals.signal(None)
  let (off, there) = (flag(false), flag(true))
  let escapes = Ref(0)
  let ids : Map[String, @view.NodeId] = Map([])
  let group = @headless.TooltipGroup::new(
    fn() { shown.get() },
    fn(k) { shown.set(k) },
    open_delay_ms=open_ms,
    warmup_ms=warm_ms,
  )
  let button = fn(parent : @view.View, name : String, disabled : () -> Bool) {
    @headless.button(parent, fn() { name }, fn(_) {  }, disabled~, fn(v, _) {
      v.width(Is(Some(100.0))).height(Is(Some(40.0))) |> ignore
      ids[name] = v.id()
      group.trigger(v, name, disabled~)
    })
    |> ignore
  }
  let t = window(pointing~, fn(root) {
    root
    .keymap(Is(@view.Keymap::new(@headless.tooltip_keys)))
    .on_key(fn(k) {
      if k.code == @ui.key_escape {
        escapes.val += 1
      }
      false
    })
    |> ignore
    button(root, "甲", fn() { false })
    button(root, "乙", fn() { false })
    root.show(at_once=true, fn() { there.get() }, fn(s) { button(s, "丙", fn() { off.get() }) })
    // (what takes the focus and is no trigger)
    root.box(fn(e) {
      e
      .width(Is(Some(50.0)))
      .height(Is(Some(30.0)))
      .presses(Is(true))
      .focusable(Is(true))
      .says(Is(Some(@view.said(Button, label="别处"))))
      .on_press(fn() {  })
      |> ignore
    })
    |> ignore
    root.show(at_once=true, fn() { shown.get() is Some(_) }, fn(s) {
      @headless.tooltip_bubble(s, fn() { "提示：" + shown.get().unwrap_or("") }, fn(v) {
        v.width(Is(Some(80.0))).height(Is(Some(24.0))) |> ignore
      })
      |> ignore
    })
  })
  { t, shown, off, there, escapes, group, ids }
}

///|
/// The middle of the button called `name`.
fn TipCase::middle(self : TipCase, name : String) -> (Double, Double) {
  let (x, y, w, h) = self.t.get(Button, label=name).rect
  (x + w / 2.0, y + h / 2.0)
}

///|
/// The pointer moved onto the button called `name`.
fn TipCase::onto(self : TipCase, name : String) -> Unit {
  let (x, y) = self.middle(name)
  self.t.move_to(x, y)
}

///|
/// The pointer moved off every button, where nothing is.
fn TipCase::away(self : TipCase) -> Unit {
  self.t.move_to(390.0, 290.0)
}

///|
/// The tips read out now, as their words.
fn TipCase::tips(self : TipCase) -> Array[String] {
  self.t.all(Tooltip).map(fn(s) { s.label })
}

///|
test "the pointer resting on a trigger: its tip not open 399 ms after, open at 400, read out a Tooltip; the pointer gone, closed at once" {
  let k = tip_case()
  k.onto("甲")
  k.t.run_for(open_ms - tick_ms)
  let before = (k.shown.get(), k.tips())
  k.t.run_for(tick_ms)
  let at = (k.shown.get(), k.tips(), k.group.is_open("甲"), k.group.shown())
  k.away()
  assert_eq(
    (before, at, k.shown.get(), k.tips()),
    ((None, []), (Some("甲"), ["提示：甲"], true, Some("甲")), None, []),
  )
}

///|
test "the pointer leaving before the delay is out calls its opening off: none opens at 400 ms, nor later" {
  let k = tip_case()
  k.onto("甲")
  k.t.run_for(open_ms / 2.0)
  k.away()
  k.t.run_for(quiet_ms)
  assert_eq(k.shown.get(), None)
}

///|
test "warm: gone on from one tip to the next, at once; 100 ms after one closed, at once; more than 300 ms after, the whole delay again" {
  let k = tip_case()
  k.onto("甲")
  k.t.run_for(open_ms)
  // (straight from 甲 to 乙: 乙's at once)
  k.onto("乙")
  let next = k.shown.get()
  // (off, and back on 甲 100 ms later: at once)
  k.away()
  k.t.run_for(warm_ms / 3.0)
  k.onto("甲")
  let soon = k.shown.get()
  // (off, and onto 乙 301 ms later: cold, 399 ms none, 400 ms it)
  k.away()
  k.t.run_for(warm_ms + tick_ms)
  k.onto("乙")
  k.t.run_for(open_ms - tick_ms)
  let cold = k.shown.get()
  k.t.run_for(tick_ms)
  assert_eq((next, soon, cold, k.shown.get(), k.tips()), (Some("乙"), Some("甲"), None, Some("乙"), ["提示：乙"]))
}

///|
test "a press on the trigger closes its tip at once and it does not open again while the pointer stays; left and come back warm, at once" {
  let k = tip_case()
  let (x, y) = k.middle("甲")
  k.t.move_to(x, y)
  k.t.run_for(open_ms)
  k.t.press_at(x, y)
  let down = k.shown.get()
  k.t.release(x, y)
  k.t.run_for(quiet_ms)
  let after = k.shown.get()
  // (a press before the delay is out calls the opening off)
  k.away()
  k.t.run_for(quiet_ms)
  k.onto("乙")
  k.t.run_for(warm_ms / 3.0)
  let (bx, by) = k.middle("乙")
  k.t.press_at(bx, by)
  k.t.release(bx, by)
  k.t.run_for(quiet_ms)
  let called_off = k.shown.get()
  // (warm from the press's close: off and onto 甲 within 300 ms of a tip closing by a press)
  k.away()
  k.t.move_to(x, y)
  k.t.run_for(open_ms)
  k.t.press_at(x, y)
  k.t.release(x, y)
  k.onto("乙")
  assert_eq((down, after, called_off, k.shown.get()), (None, None, None, Some("乙")))
}

///|
test "Escape closes a tip shown, taken by the keymap's tooltip_close; with none shown it is left to what is under it" {
  let k = tip_case()
  k.t.key(@ui.key_escape)
  let none_shown = k.escapes.val
  k.onto("甲")
  k.t.run_for(open_ms)
  let open = k.shown.get()
  k.t.key(@ui.key_escape)
  // (the pointer still on it: it does not open again by itself)
  k.t.run_for(quiet_ms)
  assert_eq((none_shown, open, k.shown.get(), k.tips()), (1, Some("甲"), None, []))
}

///|
test "the focus come to a trigger by the keyboard opens its tip at once; gone on by Tab, the next one's; the focus gone, closed" {
  let k = tip_case()
  k.t.tab()
  let first = k.shown.get()
  k.t.tab()
  let second = k.shown.get()
  k.t.tab()
  k.t.tab()
  assert_eq((first, second, k.t.focused().map(fn(s) { s.label }), k.shown.get()), (Some("甲"), Some("乙"), Some("别处"), None))
}

///|
test "a trigger disabled closes its tip at once and calls its opening off; disabled, the pointer on it opens none" {
  let k = tip_case()
  k.onto("丙")
  k.t.run_for(open_ms)
  let open = k.shown.get()
  k.off.set(true)
  k.t.draw()
  let closed = k.shown.get()
  k.away()
  k.t.run_for(quiet_ms)
  k.onto("丙")
  k.t.run_for(quiet_ms)
  let still = k.shown.get()
  // (enabled again, and disabled before the delay is out: none opens)
  k.off.set(false)
  k.away()
  k.t.run_for(quiet_ms)
  k.onto("丙")
  k.t.run_for(open_ms / 2.0)
  k.off.set(true)
  k.t.run_for(quiet_ms)
  assert_eq((open, closed, still, k.shown.get()), (Some("丙"), None, None, None))
}

///|
test "a trigger let go: its tip closed with it, its opening called off, nothing of it coming due after" {
  let k = tip_case()
  k.onto("丙")
  k.t.run_for(open_ms)
  let open = k.shown.get()
  k.there.set(false)
  k.t.draw()
  let gone = (k.shown.get(), k.tips())
  // (made again, the pointer onto it and it let go before the delay is out)
  k.there.set(true)
  k.away()
  k.t.run_for(quiet_ms)
  k.onto("丙")
  k.t.run_for(open_ms / 2.0)
  k.there.set(false)
  k.t.run_for(quiet_ms)
  assert_eq((open, gone, k.shown.get()), (Some("丙"), (None, []), None))
}

///|
test "under a finger: a tap, a long press and a finger resting on a trigger open no tip" {
  let k = tip_case(pointing=Finger)
  let (x, y) = k.middle("甲")
  k.t.tap(x, y)
  k.t.run_for(quiet_ms)
  let tapped = k.shown.get()
  k.t.press_at(x, y)
  k.t.run_for(@ui.long_press_ms + quiet_ms)
  let held = k.shown.get()
  k.t.release(x, y)
  k.t.run_for(quiet_ms)
  assert_eq((tapped, held, k.shown.get(), k.tips()), (None, None, None, []))
}

///|
test "the tip's bubble takes no press: a press where it is lands on nothing" {
  let k = tip_case()
  k.onto("甲")
  k.t.run_for(open_ms)
  let (x, y, w, h) = k.t.get(Tooltip).rect
  assert_eq(k.t.press_lands_at(x + w / 2.0, y + h / 2.0), "")
}

///|
/// Where the tip shown now came from, as the trigger's name and the moment from the case's start (`at0`); none where it
/// came from nowhere. (The moment to the nearest ms: the clock's start is no round number, so a difference of it is
/// not either.)
fn TipCase::glided(self : TipCase, at0 : Double) -> (String, Int)? {
  self.group
  .glided_from()
  .map(fn(g) {
    let name = self.ids.iter().find_first(fn(e) { e.1 == g.0 }).map(fn(e) { e.0 }).unwrap_or("?")
    (name, (g.1 - at0 + 0.5).floor().to_int())
  })
}

///|
test "where a tip came from: cold, from nowhere; gone straight on from 甲 to 乙, from 甲 at that moment; closed, none" {
  let k = tip_case()
  let at0 = k.t.time()
  k.onto("甲")
  k.t.run_for(open_ms)
  let cold = k.glided(at0)
  k.t.run_for(tick_ms)
  k.onto("乙")
  let warm = (k.shown.get(), k.glided(at0))
  k.away()
  assert_eq((cold, warm, k.shown.get(), k.glided(at0)), (None, (Some("乙"), Some(("甲", (open_ms + tick_ms).to_int()))), None, None))
}

///|
test "where a tip came from across a gap: under warmup_ms from the one before; past it, from nowhere; the same trigger again, from nowhere" {
  let k = tip_case()
  let at0 = k.t.time()
  k.onto("甲")
  k.t.run_for(open_ms)
  // (off, and onto 乙 100 ms later: from 甲)
  k.away()
  k.t.run_for(warm_ms / 3.0)
  k.onto("乙")
  let brief = (k.shown.get(), k.glided(at0))
  // (off, and onto 甲 301 ms later: cold)
  k.away()
  k.t.run_for(warm_ms + tick_ms)
  k.onto("甲")
  k.t.run_for(open_ms)
  let cooled = (k.shown.get(), k.glided(at0))
  // (off, and back onto 甲 100 ms later: at once, but from nowhere)
  k.away()
  k.t.run_for(warm_ms / 3.0)
  k.onto("甲")
  let same = (k.shown.get(), k.glided(at0))
  assert_eq(
    (brief, cooled, same),
    (
      (Some("乙"), Some(("甲", (open_ms + warm_ms / 3.0).to_int()))),
      (Some("甲"), None),
      (Some("甲"), None),
    ),
  )
}

///|
test "where a tip came from by the keyboard: Tab from 甲's to 乙's, from 甲; the first by Tab, from nowhere" {
  let k = tip_case()
  k.t.tab()
  let at0 = k.t.time()
  let first = (k.shown.get(), k.glided(at0))
  k.t.tab()
  assert_eq((first, k.shown.get(), k.glided(at0)), ((Some("甲"), None), Some("乙"), Some(("甲", 0))))
}

///|
test "a trigger let go is where no tip comes from: 丙's tip, 丙 let go, 甲's within warmup_ms opens at once from nowhere" {
  let k = tip_case()
  k.onto("丙")
  k.t.run_for(open_ms)
  let open = k.shown.get()
  k.there.set(false)
  k.t.draw()
  k.onto("甲")
  assert_eq((open, k.shown.get(), k.group.glided_from()), (Some("丙"), Some("甲"), None))
}

///|
test "TooltipGroup::trigger: within, repeats, takes_input guard, and touch_hold" {
  let shown : @signals.Signal[String?] = @signals.signal(None)
  let in_use = @signals.signal(true)
  let group = @headless.TooltipGroup::new(
    fn() { shown.get() },
    fn(k) { shown.set(k) },
    open_delay_ms=100.0,
    warmup_ms=200.0,
  )
  let t = window(fn(root) {
    // 1. within=true container with child button
    root.box(fn(holder) {
      holder
      .width(Is(Some(140.0)))
      .height(Is(Some(40.0)))
      .presses(By(fn() { in_use.get() }))
      .points(Is(true))
      .ground(Is(c_rest))
      |> ignore
      @headless.button(holder, fn() { "子按钮" }, fn(_) {  }, fn(b, _) {
        b.width(Is(Some(80.0))).height(Is(Some(32.0))).ground(Is(c_rest)) |> ignore
      })
      |> ignore
      group.trigger(holder, "容器", within=true)
    })
    |> ignore
    // 2. repeats=true on a wide box whose short words are NOT cut
    root.box(fn(full) {
      full
      .width(Is(Some(200.0)))
      .height(Is(Some(30.0)))
      .points(Is(true))
      .words(Is("短词"))
      .ground(Is(c_rest))
      |> ignore
      group.trigger(full, "完整", repeats=true)
    })
    |> ignore
    // 3. touch_hold=true trigger
    root.box(fn(touch_btn) {
      touch_btn
      .width(Is(Some(100.0)))
      .height(Is(Some(40.0)))
      .presses(Is(true))
      .ground(Is(c_rest))
      .says(Is(Some(@view.said(Button, label="长按提示"))))
      |> ignore
      group.trigger(touch_btn, "长按", touch_hold=true)
    })
    |> ignore
  })
  let tip_open_ms = 100.0
  let tip_past_ms = 300.0
  let tip_hold_ms = 500.0
  let tip_lift_check_ms = 200.0
  // Hover child inside within=true container opens "容器" tooltip; takes_input=false closes it immediately.
  t.move_to(40.0, 16.0)
  t.run_for(tip_open_ms)
  let opened_within = shown.get()
  in_use.set(false)
  t.draw()
  let closed_no_input = shown.get()
  in_use.set(true)
  t.draw()
  // Hover uncut repeats=true node does NOT open tooltip.
  t.move_to(40.0, 55.0)
  t.run_for(tip_past_ms)
  let uncut_shown = shown.get()
  // Long-press touch_hold trigger opens tip, stays open after lift for tooltip_lifted_ms, and closes on next press.
  let (tx, ty, tw, th) = t.get(Button, label="长按提示").rect
  t.press_at(tx + tw / 2.0, ty + th / 2.0)
  t.run_for(tip_hold_ms)
  let after_hold = shown.get()
  t.release(tx + tw / 2.0, ty + th / 2.0)
  t.run_for(tip_lift_check_ms)
  let while_lifted = shown.get()
  t.tap(350.0, 250.0)
  let after_tap_dismiss = shown.get()
  assert_eq(
    (opened_within, closed_no_input, uncut_shown, after_hold, while_lifted, after_tap_dismiss),
    (Some("容器"), None, None, Some("长按"), Some("长按"), None),
  )
}

///|
test "TooltipGroup::trigger: a tip saying just the words its control shows whole opens none, one saying more or over them cut short opens" {
  let shown : @signals.Signal[String?] = @signals.signal(None)
  let group = @headless.TooltipGroup::new(
    fn() { shown.get() },
    fn(k) { shown.set(k) },
    open_delay_ms=100.0,
    warmup_ms=-1.0,
  )
  let t = window(fn(root) {
    // a chip whose name, in a box it holds, is its tip's words
    root.box(fn(chip) {
      chip.width(Is(Some(200.0))).height(Is(Some(30.0))).points(Is(true)).ground(Is(c_rest)) |> ignore
      chip.box(fn(w) { w.words(Is("monoid")) |> ignore }) |> ignore
      group.trigger(chip, "名字", says=fn() { "monoid" })
    })
    |> ignore
    // the same words with a tip saying more
    root.box(fn(more) {
      more.width(Is(Some(200.0))).height(Is(Some(30.0))).points(Is(true)).words(Is("monoid")).ground(Is(c_rest))
      |> ignore
      group.trigger(more, "更多", says=fn() { "选一个项目" })
    })
    |> ignore
    // its words cut short: its tip says them whole
    root.box(fn(cut) {
      cut
      .width(Is(Some(20.0)))
      .height(Is(Some(30.0)))
      .points(Is(true))
      .words(Is("a-very-long-project-name"))
      .ground(Is(c_rest))
      |> ignore
      group.trigger(cut, "截断", says=fn() { "a-very-long-project-name" })
    })
    |> ignore
  })
  let tip_past_ms = 300.0
  t.move_to(40.0, 15.0)
  t.run_for(tip_past_ms)
  let on_chip = shown.get()
  t.move_to(40.0, 45.0)
  t.run_for(tip_past_ms)
  let on_more = shown.get()
  t.move_to(10.0, 75.0)
  t.run_for(tip_past_ms)
  let on_cut = shown.get()
  assert_eq((on_chip, on_more, on_cut), (None, Some("更多"), Some("截断")))
}
