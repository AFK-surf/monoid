// The headless popover and hover card (@headless.Popover, @headless.HoverCard), under a look of the tests' own.
// A popover: its trigger read out a button expanded as it is open; pressed open and closed; its content a Dialog by
// its name, the focus in it as it opens and back on the trigger as it goes; Escape and a press outside closing it, a
// press on it or on its trigger not twice; from the cause that closes it none of it read out or pressed. A hover card:
// opened 300 ms after the pointer came onto its trigger and not before; kept open as the pointer crosses to the card;
// closed 150 ms after it left both; at once by the focus shown and by Escape; never by a finger. Each window is made by
// `window` (window_test.mbt), which holds that popover.mbt draws and lays out nothing.

///|
/// How long the tests' popover and card take to go (View::show's leave).
let pop_leave_ms : Double = 200.0

///|
/// What a popover case keeps: its window, whether it is open (the caller's), and the presses of "别处".
struct PopCase {
  t : @ui.Tester
  open : @signals.Signal[Bool]
  elsewhere : Ref[Int]
}

///|
/// A window: the trigger "筛选" (120 by 40), a button "别处" under it, and while open the content "筛选项" 200 right of
/// where it is made, 160 by 120, holding a button "全部" (pressed, nothing).
fn pop_case() -> PopCase raise {
  let open = @signals.signal(false)
  let elsewhere = Ref(0)
  let pop = @headless.Popover::new(fn() { open.get() }, fn(v) { open.set(v) })
  let size = fn(v : @view.View) { v.width(Is(Some(120.0))).height(Is(Some(40.0))) |> ignore }
  let t = window(fn(root) {
    pop.trigger(root, fn() { "筛选" }, fn(v, _) { size(v) }) |> ignore
    @headless.button(root, fn() { "别处" }, fn(_) { elsewhere.val += 1 }, fn(v, _) { size(v) }) |> ignore
    root.show(fn() { open.get() }, leave=pop_leave_ms, fn(s) {
      pop.content(s, fn() { "筛选项" }, fn(v) {
        v
        .over(Is(true))
        .offset(Is((200.0, 0.0)))
        .width(Is(Some(160.0)))
        .height(Is(Some(120.0)))
        .ground(Is(c_rest))
        |> ignore
        @headless.button(v, fn() { "全部" }, fn(_) {  }, fn(b, _) { size(b) }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  { t, open, elsewhere }
}

///|
/// The middle of the button called `name`.
fn pop_middle(t : @ui.Tester, name : String) -> (Double, Double) raise {
  let (x, y, w, h) = t.get(Button, label=name).rect
  (x + w / 2.0, y + h / 2.0)
}

///|
/// The name of what has the focus ("none": nothing).
fn pop_focus(t : @ui.Tester) -> String {
  t.focused().map(fn(s) { s.label }).unwrap_or("none")
}

///|
test "a popover's trigger: read out a button expanded false, then true as a press opens it, its content a Dialog by its name with the focus on its first button; pressed again, closed, the focus back on the trigger" {
  let k = pop_case()
  k.t.set_a11y(true)
  let closed = k.t.get(Button, label="筛选").expanded
  k.t.act(Button, Focus, label="筛选")
  k.t.enter()
  let opened = (k.t.get(Button, label="筛选").expanded, k.t.query(Dialog, label="筛选项") is Some(_), pop_focus(k.t))
  // (a click on the trigger while open: closed once, not opened again by the press outside the content)
  k.t.click(Button, label="筛选")
  let again = (k.open.get(), k.t.query(Dialog, label="筛选项") is Some(_), pop_focus(k.t))
  assert_eq((closed, opened, again), (Some(false), (Some(true), true, "全部"), (false, false, "筛选")))
}

///|
test "Escape with the focus in it closes it, the focus back on the trigger; a press on what it holds, or on its own ground, keeps it open" {
  let k = pop_case()
  k.t.click(Button, label="筛选")
  k.t.click(Button, label="全部")
  // (its ground, 10 above its foot, under 全部)
  let (px, py, pw, ph) = k.t.get(Dialog, label="筛选项").rect
  k.t.tap(px + pw / 2.0, py + ph - 10.0)
  let kept = k.open.get()
  k.t.act(Button, Focus, label="全部")
  k.t.key(@ui.key_escape)
  assert_eq((kept, k.open.get(), pop_focus(k.t)), (true, false, "筛选"))
}

///|
test "a press outside it closes it as it goes down, and is what it lands on's: 别处 pressed; from then nothing of it pressed while it goes" {
  let k = pop_case()
  let (ex, ey) = pop_middle(k.t, "别处")
  k.t.click(Button, label="筛选")
  let (ax, ay) = pop_middle(k.t, "全部")
  k.t.tap(ex, ey)
  let after = (k.open.get(), k.elsewhere.val)
  // (its way out still drawn: a press where 全部 is reaches nothing of it, nor opens it)
  k.t.run_for(pop_leave_ms / 4.0)
  k.t.tap(ax, ay)
  assert_eq((after, k.open.get(), k.t.query(Dialog, label="筛选项") is Some(_)), ((false, 1), false, false))
}

///|
/// The tests' hover card's delays: its own defaults.
let card_open_ms : Double = 300.0

///|
let card_close_ms : Double = 150.0

///|
/// The least step of the clock a test takes.
let card_tick_ms : Double = 1.0

///|
/// What a hover card case keeps: its window and whether it is open (the caller's).
struct CardCase {
  t : @ui.Tester
  open : @signals.Signal[Bool]
}

///|
/// A window: a button "别处", the trigger "作者" (a button, 120 by 40) under it, and while open the card "作者简介" 120
/// right of where it is made and 40 up (beside the trigger, touching it), 160 by 100, holding a button "关注".
fn card_case(pointing? : @ui.Pointing = Mouse) -> CardCase raise {
  let open = @signals.signal(false)
  let card = @headless.HoverCard::new(fn() { open.get() }, fn(v) { open.set(v) })
  let size = fn(v : @view.View) { v.width(Is(Some(120.0))).height(Is(Some(40.0))) |> ignore }
  let t = window(pointing~, fn(root) {
    @headless.button(root, fn() { "别处" }, fn(_) {  }, fn(v, _) { size(v) }) |> ignore
    @headless.button(root, fn() { "作者" }, fn(_) {  }, fn(v, _) {
      size(v)
      card.trigger(v)
    })
    |> ignore
    root.show(fn() { open.get() }, leave=pop_leave_ms, fn(s) {
      card.card(s, fn() { "作者简介" }, fn(v) {
        v.over(Is(true)).offset(Is((120.0, -40.0))).width(Is(Some(160.0))).height(Is(Some(100.0))) |> ignore
        @headless.button(v, fn() { "关注" }, fn(_) {  }, fn(b, _) { size(b) }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  { t, open }
}

///|
test "the pointer resting on a hover card's trigger: closed 299 ms after, open at 300, read out a Group by its name; gone from both, open 149 ms after, closed at 150" {
  let k = card_case()
  let (x, y) = pop_middle(k.t, "作者")
  k.t.move_to(x, y)
  k.t.run_for(card_open_ms - card_tick_ms)
  let before = k.open.get()
  k.t.run_for(card_tick_ms)
  let at = (k.open.get(), k.t.query(Group, label="作者简介") is Some(_))
  k.t.move_to(390.0, 290.0)
  k.t.run_for(card_close_ms - card_tick_ms)
  let lingering = k.open.get()
  k.t.run_for(card_tick_ms)
  assert_eq((before, at, lingering, k.open.get()), (false, (true, true), true, false))
}

///|
test "the pointer crossing from the trigger to the card keeps it open (its closing called off as it comes onto the card); leaving the trigger before 300 ms opens none" {
  let k = card_case()
  let (x, y) = pop_middle(k.t, "作者")
  k.t.move_to(x, y)
  k.t.run_for(card_open_ms / 2.0)
  k.t.move_to(390.0, 290.0)
  k.t.run_for(card_open_ms * 2.0)
  let never = k.open.get()
  k.t.move_to(x, y)
  k.t.run_for(card_open_ms)
  // (off the trigger, past nothing, then onto the card within 150 ms: kept)
  k.t.move_to(390.0, 290.0)
  k.t.run_for(card_close_ms / 2.0)
  let (cx, cy) = pop_middle(k.t, "关注")
  k.t.move_to(cx, cy)
  k.t.run_for(card_close_ms * 4.0)
  assert_eq((never, k.open.get()), (false, true))
}

///|
test "the focus shown on the trigger opens it at once; Escape closes it at once; the focus going elsewhere closes it" {
  let k = card_case()
  k.t.act(Button, Focus, label="别处")
  k.t.tab()
  let by_tab = k.open.get()
  k.t.key(@ui.key_escape)
  let by_escape = k.open.get()
  k.t.tab(back=true)
  k.t.tab()
  let again = k.open.get()
  k.t.tab(back=true)
  assert_eq((by_tab, by_escape, again, k.open.get()), (true, false, true, false))
}

///|
test "a finger opens no hover card: a tap and a long press on its trigger leave it closed, nothing waited for" {
  let k = card_case(pointing=Finger)
  let (x, y) = pop_middle(k.t, "作者")
  k.t.tap(x, y)
  k.t.run_for(card_open_ms * 2.0)
  k.t.press_at(x, y)
  k.t.run_for(card_open_ms * 2.0)
  k.t.release(x, y)
  assert_eq(k.open.get(), false)
}

///|
test "Popover::layer + View::float_beside positions beside opener, closes on Escape and outside press, and clears opener when trigger unmounts" {
  let open = @signals.signal(false)
  let show_trigger = @signals.signal(true)
  let pop = @headless.Popover::new(fn() { open.get() }, fn(v) { open.set(v) })
  let size = fn(v : @view.View) { v.width(Is(Some(120.0))).height(Is(Some(40.0))) |> ignore }
  let t = window(fn(root) {
    root.show(at_once=true, fn() { show_trigger.get() }, fn(s) {
      pop.trigger(s, fn() { "筛选" }, fn(v, _) { size(v) }) |> ignore
    })
    @headless.button(root, fn() { "别处" }, fn(_) {  }, fn(v, _) { size(v) }) |> ignore
    pop.layer(
      root,
      fn() { "浮层菜单" },
      fn(v, anchor) {
        v
        .float_beside(anchor, side=Bottom, along=Start, offset=4.0)
        .width(Is(Some(140.0)))
        .height(Is(Some(80.0)))
        .ground(Is(c_rest))
        |> ignore
        @headless.button(v, fn() { "选项" }, fn(_) {  }, fn(b, _) { size(b) }) |> ignore
      },
      at_once=true,
    )
  })
  assert_true(pop.opener() is Some(_))
  let (_tx, ty, _tw, th) = t.get(Button, label="筛选").rect
  t.click(Button, label="筛选")
  let (px, py, pw, ph) = t.get(Dialog, label="浮层菜单").rect
  // (x clamped to default 8px window padding since trigger sits at x=0)
  assert_eq((px, py, pw, ph), (8.0, ty + th + 4.0, 140.0, 80.0))
  // Escape closes it
  t.key(@ui.key_escape)
  assert_eq((open.get(), t.query(Dialog, label="浮层菜单") is Some(_)), (false, false))
  // Reopen and close by pressing outside both trigger and popover
  t.click(Button, label="筛选")
  assert_true(t.query(Dialog, label="浮层菜单") is Some(_))
  t.tap(300.0, 200.0)
  assert_eq((open.get(), t.query(Dialog, label="浮层菜单") is Some(_)), (false, false))
  // Unmounting the trigger clears opener()
  show_trigger.set(false)
  t.draw()
  assert_true(pop.opener() is None)
}

///|
test "HoverCard::opener exposes trigger node while mounted and None after trigger unmounts" {
  let open = @signals.signal(false)
  let show_trigger = @signals.signal(true)
  let card = @headless.HoverCard::new(fn() { open.get() }, fn(v) { open.set(v) })
  let t = window(fn(root) {
    root.show(at_once=true, fn() { show_trigger.get() }, fn(s) {
      @headless.button(s, fn() { "作者" }, fn(_) {  }, fn(v, _) {
        v.width(Is(Some(120.0))).height(Is(Some(40.0))) |> ignore
        card.trigger(v)
      })
      |> ignore
    })
  })
  assert_true(card.opener() is Some(_))
  show_trigger.set(false)
  t.draw()
  assert_true(card.opener() is None)
}
