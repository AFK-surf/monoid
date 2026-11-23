// The headless toaster (@headless.toaster), under a look of the tests' own: the region a column at the window's top,
// each toast a box 200 by 40, its action (where it has one) a box 60 by 30 in it. Each toast's time from the moment it
// is given, stopped while the pointer is over one of them or the focus on one's action and going on from what was
// left; one given again by its id the same node saying what it says now; swiped, put away past a third or flicked,
// else back; its action taken once, its look's close as by itself; toaster_due and toaster_rest answering for them, a
// look's way too. Each window is made by `window` (window_test.mbt), which holds that toaster.mbt draws and lays out
// nothing.

///|
/// How long each toast stays in these cases.
let stays_ms : Double = 1000.0

///|
/// How long a finger's flick takes, from its press to its move (quick enough to be one: @view.flung_away).
let flick_ms : Double = 10.0

///|
/// How long a toast no longer given is held for its look's way out (the toaster's `leave`).
let toast_leave_ms : Double = 100.0

///|
/// What a toaster case keeps: its window, the toasts given, whether what holds the toaster is there, what was told
/// gone and acted on (by id), each toast's item by its id (the last made), the moment their looks say their way ends.
struct ToastCase {
  t : @ui.Tester
  toasts : @signals.Signal[Array[Said]]
  holder : @signals.Signal[Bool]
  gone : Array[String]
  acted : Array[String]
  items : Map[String, @headless.ToastItem[Said]]
  way_end : Ref[Double]
  start : Double
}

///|
/// A toast of these cases: its id, its title, its description, its action's words ("" none), how long it stays.
#derive(Eq, Debug)
struct Said {
  id : String
  title : String
  description : String
  action : String
  stays : Double
}

///|
fn said(id : String, title : String, description? : String = "", action? : String = "", stays? : Double = stays_ms) -> Said {
  { id, title, description, action, stays }
}

///|
/// A window with a box at its top taking the focus ("别处"), and a toaster (key "case") of `toasts` under it while the
/// case's `holder` holds (from a whole ms on, the case's start), its looks saying their way ends at `way_end` (-1 none).
fn toast_case(toasts : Array[Said]) -> ToastCase raise {
  let given = @signals.signal(toasts)
  let holder = @signals.signal(false)
  let gone = []
  let acted = []
  let items = Map([])
  let way_end = Ref(-1.0)
  let t = window(fn(root) {
    root.box(fn(e) {
      e
      .width(Is(Some(50.0)))
      .height(Is(Some(30.0)))
      .presses(Is(true))
      .focusable(Is(true))
      .says(Is(Some(@view.said(Button, label="别处"))))
      |> ignore
    })
    |> ignore
    root.show(at_once=true, fn() { holder.get() }, fn(h) {
      @headless.toaster(
        h,
        fn() { given.get() },
        fn(s) { s.id },
        fn(s) { (s.title, s.description) },
        fn(s) { s.stays },
        fn(region) { region.width(Is(Some(300.0))) |> ignore },
        fn(b, s) {
          items[@signals.untracked(fn() { s.toast().id })] = s
          s.moves(fn(now) { if way_end.val > now { way_end.val } else { -1.0 } })
          b.width(Is(Some(200.0))).height(Is(Some(40.0))).row(Is(true)) |> ignore
          b.show(fn() { s.toast().action != "" && s.live() }, fn(a) {
            a.width(Is(Some(60.0))).height(Is(Some(30.0))) |> ignore
            s.action(a, fn() { s.toast().action }) |> ignore
          })
        },
        fn(id) { acted.push(id) },
        fn(id) { gone.push(id) },
        key="case",
        label="通知",
        leave=toast_leave_ms,
      )
      |> ignore
    })
  })
  // (given from a whole ms: the moments the cases say, as they say them)
  t.run_for(t.time().ceil() - t.time())
  let start = t.time()
  holder.set(true)
  t.frame()
  // (held as `window` holds what it made: nothing of the toaster's own drawn or laid out)
  let tree = @ui.view_tree().unwrap()
  let drawn = []
  drawn_here(tree, tree.root(), drawn)
  assert_eq(drawn, [])
  { t, toasts: given, holder, gone, acted, items, way_end, start }
}

///|
/// The case's clock run on to `at` ms after it started.
fn ToastCase::run_to(self : ToastCase, at : Double) -> Unit {
  self.t.run_for(self.start + at - self.t.time())
}

///|
/// Where toast `title` is read out (near its start, in its middle), if it is.
fn ToastCase::at(self : ToastCase, title : String) -> (Double, Double)? {
  self.t.query(Status, label=title).map(fn(s) { (s.rect.0 + 20.0, s.rect.1 + s.rect.3 / 2.0) })
}

///|
/// toaster_due of the case, as ms after it started (-1 none counting).
fn ToastCase::due(self : ToastCase) -> Double {
  match @headless.toaster_due("case") {
    Some(d) if d >= 0.0 => d - self.start
    Some(_) => -1.0
    None => -2.0
  }
}

///|
/// Toast `id`'s item's readings: whether it is live, how far it is drawn.
fn ToastCase::item(self : ToastCase, id : String) -> (Bool, Double) {
  let s = self.items[id]
  @signals.untracked(fn() { (s.live(), s.dx()) })
}

///|
test "toaster: a region called by its label, each toast a status called by its title, its description its own" {
  let k = toast_case([said("a", "一", description="详"), said("b", "二")])
  let region = k.t.query(Region, label="通知")
  let a = k.t.query(Status, label="一")
  let b = k.t.query(Status, label="二")
  assert_eq(
    (region is Some(_), a.map(fn(s) { s.description }), b.map(fn(s) { s.description })),
    (true, Some("详"), Some("")),
  )
}

///|
test "toaster: a toast given at 0 goes by itself at its time, told gone once; toaster_due says when" {
  let k = toast_case([said("a", "一")])
  let due = k.due()
  k.run_to(stays_ms - 1.0)
  let before = k.gone.copy()
  k.run_to(stays_ms)
  let after = (k.gone.copy(), k.item("a").0, k.due())
  k.run_to(stays_ms * 3.0)
  assert_eq((due, before, after, k.gone), (stays_ms, [], (["a"], false, -1.0), ["a"]))
}

///|
test "toaster: the pointer over one at 400, still at its due, it stays; let go at 1500, it goes at 2100 (what was left), not before" {
  let k = toast_case([said("a", "一")])
  k.run_to(400.0)
  let (x, y) = k.at("一").unwrap()
  k.t.move_to(x, y)
  k.run_to(1000.0)
  let held = (k.gone.copy(), k.due())
  k.run_to(1500.0)
  k.t.move_to(390.0, 290.0)
  let due = k.due()
  k.run_to(2099.0)
  let before = k.gone.copy()
  k.run_to(2100.0)
  assert_eq((held, due, before, k.gone), (([], -1.0), 2100.0, [], ["a"]))
}

///|
test "toaster: the focus on one's action holds them, the pointer gone or not; the focus gone, its time goes on from what was left" {
  let k = toast_case([said("a", "一", action="做")])
  k.run_to(200.0)
  // (the focus: the box at the top, then the action)
  k.t.tab()
  k.t.tab()
  let focused = k.t.semantics().iter().any(fn(s) { s.label == "做" && s.focused })
  k.run_to(1500.0)
  let held = k.gone.copy()
  k.t.tab()
  // (from 200, 800 left)
  k.run_to(2299.0)
  let before = k.gone.copy()
  k.run_to(2300.0)
  assert_eq((focused, held, before, k.gone), (true, [], [], ["a"]))
}

///|
test "toaster: the pointer over one holds them all; let go, each goes on from what it had left" {
  let k = toast_case([said("a", "一")])
  k.run_to(100.0)
  k.toasts.set([said("a", "一"), said("b", "二")])
  k.t.frame()
  k.run_to(300.0)
  let (x, y) = k.at("一").unwrap()
  k.t.move_to(x, y)
  k.run_to(2000.0)
  let held = k.gone.copy()
  k.t.move_to(390.0, 290.0)
  // (a: 700 left, b: 800)
  k.run_to(2700.0)
  let first = k.gone.copy()
  k.run_to(2800.0)
  assert_eq((held, first, k.gone), ([], ["a"], ["a", "b"]))
}

///|
test "toaster: one saying it stays longer stays that much longer, counting on from when it was given" {
  let k = toast_case([said("a", "一")])
  k.run_to(300.0)
  k.toasts.set([said("a", "一", stays=1500.0)])
  k.t.frame()
  let due = k.due()
  k.run_to(1499.0)
  let before = k.gone.copy()
  k.run_to(1500.0)
  assert_eq((due, before, k.gone), (1500.0, [], ["a"]))
}

///|
test "toaster: given again by its id saying other words and an action, the same node saying them; its action taken once, and it goes" {
  let k = toast_case([said("a", "一")])
  k.run_to(200.0)
  let before = k.t.query(Status, label="一").map(fn(s) { s.id })
  k.toasts.set([said("a", "二", action="做")])
  k.t.frame()
  let after = k.t.query(Status, label="二").map(fn(s) { s.id })
  let b = k.t.query(Button, label="做").unwrap()
  k.t.tap(b.rect.0 + 30.0, b.rect.1 + 15.0)
  let acted = (k.acted.copy(), k.gone.copy(), k.item("a").0, k.due())
  // (taken once: its time out after, nothing more told)
  k.run_to(3000.0)
  assert_eq(
    (before is Some(_), before == after, acted, k.acted, k.gone),
    (true, true, (["a"], [], false, -1.0), ["a"], []),
  )
}

///|
test "toaster: drawn to the right, it follows the finger; let go short of a third, slowly, it comes back and stays" {
  let k = toast_case([said("a", "一")])
  k.run_to(200.0)
  let (x, y) = k.at("一").unwrap()
  k.t.press_at(x, y)
  k.t.move_to(x + 30.0, y)
  let held = k.item("a")
  k.t.move_to(x - 20.0, y)
  let left = k.item("a").1
  k.t.move_to(x + 30.0, y)
  k.t.release(x + 30.0, y)
  let back = (k.item("a"), k.gone.copy())
  assert_eq((held, left, back), ((true, 30.0), 0.0, ((true, 0.0), [])))
}

///|
test "toaster: drawn past a third of it and let go, it goes, told gone once" {
  let k = toast_case([said("a", "一")])
  k.run_to(200.0)
  let (x, y) = k.at("一").unwrap()
  k.t.press_at(x, y)
  k.t.move_to(x + 80.0, y)
  k.t.release(x + 80.0, y)
  let after = (k.gone.copy(), k.item("a"), k.due())
  k.run_to(3000.0)
  assert_eq((after, k.gone), ((["a"], (false, 0.0), -1.0), ["a"]))
}

///|
test "toaster: flicked to the right a little and let go, it goes" {
  let k = toast_case([said("a", "一")])
  k.run_to(200.0)
  let (x, y) = k.at("一").unwrap()
  k.t.press_at(x, y)
  k.t.run_for(flick_ms)
  k.t.move_to(x + 20.0, y)
  k.t.release(x + 20.0, y)
  assert_eq(k.gone, ["a"])
}

///|
test "toaster: closed by its look, it goes as by itself, once" {
  let k = toast_case([said("a", "一")])
  k.run_to(200.0)
  let s = k.items["a"]
  s.close()
  s.close()
  k.run_to(3000.0)
  assert_eq((k.gone, k.acted, k.item("a").0), (["a"], [], false))
}

///|
test "toaster: no longer given, it is held `leave` for its way out, toaster_rest its letting go or its look's way, the later; then none of it left" {
  let k = toast_case([said("a", "一")])
  k.run_to(200.0)
  // (its look's way: done at 250)
  k.way_end.val = k.start + 250.0
  let coming = @headless.toaster_rest("case").unwrap() - k.start
  k.toasts.set([])
  k.t.frame()
  let going = (@headless.toaster_rest("case").unwrap() - k.start, k.item("a").0)
  k.run_to(200.0 + toast_leave_ms - 1.0)
  // (still there for its way out, none of it read out)
  let there = (k.items["a"].row().alive(), k.t.query(Status, label="一") is None)
  k.run_to(200.0 + toast_leave_ms)
  let after = (!k.items["a"].row().alive(), @headless.toaster_rest("case"), k.gone)
  assert_eq(
    (coming, going, there, after),
    (250.0, (200.0 + toast_leave_ms, false), (true, true), (true, Some(-1.0), [])),
  )
}

///|
test "toaster: going out, given again by its id, it is there again, its time from what it had left" {
  let k = toast_case([said("a", "一")])
  k.run_to(200.0)
  k.toasts.set([])
  k.t.frame()
  k.run_to(250.0)
  let going = k.t.query(Status, label="一") is None
  k.toasts.set([said("a", "一")])
  k.t.frame()
  let back = (k.item("a").0, k.t.query(Status, label="一") is Some(_))
  k.run_to(3000.0)
  assert_eq((going, back, k.gone), (true, (true, true), ["a"]))
}

///|
test "toaster: what holds it let go, no toaster by its key; none of it waited for" {
  let k = toast_case([said("a", "一")])
  k.run_to(200.0)
  k.holder.set(false)
  k.t.frame()
  assert_eq(
    (@headless.toaster_due("case"), @headless.toaster_rest("case"), k.t.query(Region, label="通知") is None, k.t.next_wake()),
    (None, None, true, None),
  )
}
