// The library's accordion (accordion_node.mbt): its headers read out buttons expanded as their sections are open, each
// open section's panel a region; one open at a time (closing the open one by its header where collapsible) or each its
// own; ↓ ↑ Home End along the headers past a disabled one, Enter and Space turning one; a hairline between sections and
// none before the first or after the last; its chevrons on their titles' first lines, no fault of the audit's.

///|
/// A window `w` wide, keyboard and mouse, the library's light theme, holding a node "别处" that takes the focus and then
/// what `make` makes, 16 in from its sides, 16 apart.
fn w2_case(make : (@view.View) -> Unit, w? : Double = 600.0, h? : Double = 640.0) -> @ui.Tester {
  presenters_reset()
  let t = @ui.Tester::new(fn(_c) {  }, w~, h~, platform=0)
  t.check_looks(false)
  set_dark(Some(false))
  @ui.set_tree_theme(ui_theme_now)
  @ui.set_view_app(fn(root) {
    root.padding(Is((16.0, 16.0, 16.0, 16.0))).gap(Is(16.0)) |> ignore
    root.box(fn(e) {
      e
      .width(Is(Some(40.0)))
      .height(Is(Some(40.0)))
      .presses(Is(true))
      .focusable(Is(true))
      .says(Is(Some(@view.said(Button, label="别处"))))
      .on_press(fn() {  })
      |> ignore
    })
    |> ignore
    make(root)
  })
  t.draw()
  t
}

///|
/// What an accordion case keeps: its window, the keys told, whether 高级 is disabled.
struct Acc2 {
  t : @ui.Tester
  told : Array[String]
  off : @signals.Signal[Bool]
}

///|
/// An accordion of 概览, 权限 and 高级 (高级 disabled while `off`), 概览 open, its panels' words "<name>的内容"; `kind`
/// its kind; `w` the window's width, `title` 权限's title.
fn acc2(
  kind? : @headless.AccordionKind = Single(collapsible=true),
  w? : Double = 600.0,
  long? : String = "权限",
) -> Acc2 {
  let open : @signals.Signal[Array[String]] = @signals.signal(["概览"])
  let told : Array[String] = []
  let off = @signals.signal(true)
  let single = kind is Single(..)
  let t = w2_case(w~, fn(root) {
    let section = fn(name : String, title : String, disabled : () -> Bool) {
      accordion_section(
        name,
        fn() { title },
        fn(p) { words_node(p, fn() { name + "的内容" }, fn() { paragraph }) |> ignore },
        disabled~,
      )
    }
    accordion_node(
      root,
      [section("概览", "概览", fn() { false }), section("权限", long, fn() { false }), section("高级", "高级", fn() { off.get() })],
      fn(k) { open.get().contains(k) },
      fn(k) {
        told.push(k)
        let now = open.get()
        if now.contains(k) {
          open.set(now.filter(fn(x) { x != k }))
        } else if single {
          open.set([k])
        } else {
          open.set(now + [k])
        }
      },
      kind~,
    )
    |> ignore
  })
  { t, told, off }
}

///|
/// The names of the headers read out expanded, and of the panels read out.
fn acc2_open(t : @ui.Tester) -> (Array[String], Array[String]) {
  (t.all(Button, expanded=true).map(fn(s) { s.label }), t.all(Region).map(fn(s) { s.label }))
}

///|
test "accordion, one open at a time: a press on another header opens it and closes the one open, a press on the open one closes it (collapsible); each open panel a region, its words shown; nothing the audit finds" {
  let k = acc2()
  assert_eq(acc2_open(k.t), (["概览"], ["概览"]))
  assert_true(k.t.rect_of("概览的内容") is Some(_))
  assert_eq(k.t.audit(), [])
  k.t.click(Button, label="权限")
  k.t.run_for(@ui.move_most_ms)
  assert_eq(acc2_open(k.t), (["权限"], ["权限"]))
  assert_true(k.t.rect_of("概览的内容") is None)
  assert_true(k.t.rect_of("权限的内容") is Some(_))
  assert_eq(k.t.audit(), [])
  k.t.click(Button, label="权限")
  k.t.run_for(@ui.move_most_ms)
  assert_eq(acc2_open(k.t), ([], []))
  assert_eq(k.told, ["权限", "权限"])
}

///|
test "accordion, one open at a time and not collapsible: a press on the open one's header tells nothing, it stays open" {
  let k = acc2(kind=Single(collapsible=false))
  k.t.click(Button, label="概览")
  k.t.run_for(@ui.move_most_ms)
  assert_eq(acc2_open(k.t), (["概览"], ["概览"]))
  assert_eq(k.told, [])
}

///|
test "accordion, each its own: a press on another header opens it beside the one open" {
  let k = acc2(kind=Multiple)
  k.t.click(Button, label="权限")
  k.t.run_for(@ui.move_most_ms)
  assert_eq(acc2_open(k.t), (["概览", "权限"], ["概览", "权限"]))
  assert_eq(k.t.audit(), [])
}

///|
test "accordion keys: Tab comes to the first header, ↓ ↑ go along them past the disabled one and round the ends, Home and End to the first and last enabled; Enter and Space turn the one the keyboard is on" {
  let k = acc2()
  let at = fn() { k.t.focused().map(fn(s) { s.label }).unwrap_or("none") }
  k.t.act(Button, Focus, label="别处")
  k.t.tab()
  let first = at()
  k.t.key(@ui.key_code_down)
  let down = at()
  k.t.key(@ui.key_code_down)
  let round = at()
  k.t.key(@ui.key_code_up)
  let up = at()
  k.t.key(@ui.key_code_end)
  let end = at()
  k.t.key(@ui.key_code_home)
  let home = at()
  assert_eq([first, down, round, up, end, home], ["概览", "权限", "概览", "权限", "权限", "概览"])
  k.t.key(@ui.key_code_down)
  k.t.enter()
  k.t.run_for(@ui.move_most_ms)
  assert_eq(acc2_open(k.t).0, ["权限"])
  k.t.key(@ui.key_space)
  k.t.run_for(@ui.move_most_ms)
  assert_eq(acc2_open(k.t).0, [])
  assert_eq(k.told, ["权限", "权限"])
}

///|
test "accordion, a disabled header: read out disabled, a press on it tells nothing; enabled again, it opens" {
  let k = acc2()
  assert_true(k.t.get(Button, label="高级").disabled)
  k.t.click(Button, label="高级")
  k.t.run_for(@ui.move_most_ms)
  assert_eq(k.told, [])
  k.off.set(false)
  k.t.draw()
  k.t.click(Button, label="高级")
  k.t.run_for(@ui.move_most_ms)
  assert_eq(acc2_open(k.t), (["高级"], ["高级"]))
}

///|
test "accordion: a hairline between each section and the next, none before the first or after the last, however many are open" {
  let k = acc2(kind=Multiple)
  let rules = fn() {
    k.t.drawn_rects().filter(fn(r) { r.3 <= 1.0 && r.2 > 400.0 }).length()
  }
  let closed_one = rules()
  k.t.click(Button, label="权限")
  k.t.click(Button, label="高级")
  k.t.run_for(@ui.move_most_ms)
  assert_eq((closed_one, rules()), (2, 2))
}

///|
test "accordion in a phone's width, a title in lines: its chevron on the title's first line, nothing the audit finds" {
  let k = acc2(w=390.0, long="谁能看到这个工作区里的对话、文件和每一台机器上正在运行的任务")
  let (_, ty, _, _) = k.t.rect_of("谁能看到这个工作区里的对话、文件和每一台机器上正在运行的任务").unwrap()
  assert_eq(k.t.audit(), [])
  // (its title in two lines or more: the header taller than one line's)
  let head = k.t.get(Button, label="谁能看到这个工作区里的对话、文件和每一台机器上正在运行的任务")
  assert_true(head.rect.3 > 60.0, msg="\{head.rect.3}")
  assert_true(ty < head.rect.1 + 16.0)
}
