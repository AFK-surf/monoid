// The headless tabs (@headless.Tabs: Tabs::list, RadioGroup::item, Tabs::panel), under a look of the tests' own: a
// TabList of Tabs read out selected as their caller says; ←/→ choosing what they come to (or, manual, moving the focus
// alone, Enter choosing); the chosen tab's panel read out a TabPanel by its name and only it; what a panel holds made
// while its tab is chosen and let go as another is, or, keep_mounted, kept (its state with it) and hidden, taking no
// focus, while another is. Each window is made by `window` (window_test.mbt), which holds that tabs.mbt draws and lays
// out nothing.

///|
/// What a case keeps: its window, the chosen tab (the caller's), how many times each panel's content was made, and the
/// count each panel's button keeps (its state, made with it).
struct TabsCase {
  t : @ui.Tester
  chosen : @signals.Signal[String]
  made : Map[String, Int]
  counts : Map[String, Ref[Int]]
}

///|
/// A window: tabs 一 二 三 (二 disabled where `mid_off`), each 80 by 30 in a row, then each tab's panel "<name>页"
/// holding a button "<name>加" that counts its presses in a count made with it; `keep` keep_mounted, `manual` as given.
fn tabs_case(keep? : Bool = false, manual? : Bool = false, mid_off? : Bool = false) -> TabsCase raise {
  let chosen = @signals.signal("一")
  let made : Map[String, Int] = Map([])
  let counts : Map[String, Ref[Int]] = Map([])
  let tabs = @headless.Tabs::new(fn() { chosen.get() }, fn(k) { chosen.set(k) }, manual~)
  let names = ["一", "二", "三"]
  let t = window(fn(root) {
    tabs.list(root, fn() { "视图" }, fn(v, g) {
      v.row(Is(true)) |> ignore
      for name in names {
        let disabled = if name == "二" && mid_off { fn() { true } } else { fn() { false } }
        g.item(v, fn() { name }, fn() { name }, disabled~, fn(i, _) {
          i.width(Is(Some(80.0))).height(Is(Some(30.0))) |> ignore
        })
        |> ignore
      }
    })
    |> ignore
    for name in names {
      tabs.panel(
        root,
        name,
        fn() { name + "页" },
        keep_mounted=keep,
        fn(p, s) { p.width(Is(Some(200.0))).height(By(fn() { Some(if s.selected() { 40.0 } else { 0.0 }) })) |> ignore },
        fn(p) {
          made[name] = made.get(name).unwrap_or(0) + 1
          let count = Ref(0)
          counts[name] = count
          @headless.button(p, fn() { name + "加" }, fn(_) { count.val += 1 }, fn(b, _) {
            b.width(Is(Some(80.0))).height(Is(Some(30.0))) |> ignore
          })
          |> ignore
        },
      )
      |> ignore
    }
  })
  { t, chosen, made, counts }
}

///|
/// The name of what has the focus ("none": nothing).
fn tabs_focus(t : @ui.Tester) -> String {
  t.focused().map(fn(s) { s.label }).unwrap_or("none")
}

///|
/// The names of the tab panels read out now.
fn tabs_panels(t : @ui.Tester) -> Array[String] {
  t.all(TabPanel).map(fn(s) { s.label })
}

///|
test "tabs: a TabList of Tabs read out selected as chosen; only the chosen tab's panel read out a TabPanel; → chooses the next and shows its panel, made anew each time it is chosen" {
  let k = tabs_case()
  k.t.set_a11y(true)
  let list = k.t.query(TabList, label="视图") is Some(_)
  let first = (k.t.get(Tab, label="一").selected, k.t.get(Tab, label="二").selected, tabs_panels(k.t))
  k.t.act(Tab, Focus, label="一")
  k.t.key(@ui.key_code_right)
  let next = (k.chosen.get(), tabs_focus(k.t), tabs_panels(k.t))
  k.t.key(@ui.key_code_left)
  assert_eq(
    (list, first, next, k.chosen.get(), k.made.get("一"), k.made.get("二")),
    (true, (Some(true), Some(false), ["一页"]), ("二", "二", ["二页"]), "一", Some(2), Some(1)),
  )
}

///|
test "kept mounted: what a panel holds is made once and keeps its state across choosing; while another is chosen it is not read out and Tab passes it by" {
  let k = tabs_case(keep=true)
  k.t.click(Button, label="一加")
  k.t.click(Tab, label="二")
  let hidden = (tabs_panels(k.t), k.t.query(Button, label="一加").map(fn(s) { s.hidden }).unwrap_or(true))
  // (Tab from 二's tab: 二's own button, not 一's, which is kept but out of use)
  k.t.act(Tab, Focus, label="二")
  k.t.tab()
  let tabbed = tabs_focus(k.t)
  k.t.click(Tab, label="一")
  k.t.click(Button, label="一加")
  assert_eq(
    (hidden, tabbed, k.made.get("一"), k.made.get("二"), k.counts.get("一").map(fn(c) { c.val })),
    ((["二页"], true), "二加", Some(1), Some(1), Some(2)),
  )
}

///|
test "manual: → moves the focus alone, the chosen tab and its panel as they were; Enter chooses it; a disabled tab passed by" {
  let k = tabs_case(manual=true, mid_off=true)
  k.t.act(Tab, Focus, label="一")
  k.t.key(@ui.key_code_right)
  let moved = (tabs_focus(k.t), k.chosen.get(), tabs_panels(k.t))
  k.t.enter()
  assert_eq((moved, k.chosen.get(), tabs_panels(k.t)), (("三", "一", ["一页"]), "三", ["三页"]))
}
