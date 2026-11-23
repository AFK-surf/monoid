// The headless accordion (@headless.accordion, Accordion::trigger, Accordion::panel), under a look of the tests' own:
// its headers read out buttons expanded as their sections are open, each a stop of Tab's; ↓/↑ (→/← across) among the
// enabled headers around the ends (or not), Home and End; a disabled header passed by and never pressed; one open at a
// time, the open one's header closing it only where collapsible; each its own where Multiple; each panel a Region by its
// name while open. Each window is made by `window` (window_test.mbt), which holds that accordion.mbt draws and lays out
// nothing.

///|
/// What a case keeps: its window, the open sections (the caller's), the keys told, and whether 乙 is disabled.
struct AccCase {
  t : @ui.Tester
  open : @signals.Signal[Array[String]]
  told : Array[String]
  off : @signals.Signal[Bool]
}

///|
/// A window: an accordion of sections 甲 乙 丙 (乙 disabled while `off`), each a header 120 by 30 and, while open, its
/// panel "<name>内容" (120 by 40, holding a button "<name>按钮"); `kind` its kind, `vertical` and `wraps` as given.
fn acc_case(
  kind? : @headless.AccordionKind = Single(collapsible=true),
  vertical? : Bool = true,
  wraps? : Bool = true,
) -> AccCase raise {
  let open : @signals.Signal[Array[String]] = @signals.signal(["甲"])
  let told : Array[String] = []
  let off = @signals.signal(false)
  let single = kind is Single(..)
  let t = window(fn(root) {
    @headless.accordion(
      root,
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
      vertical~,
      wraps~,
      fn(v, a) {
        v.row(Is(!vertical)) |> ignore
        for name in ["甲", "乙", "丙"] {
          let disabled = if name == "乙" { fn() { off.get() } } else { fn() { false } }
          a.trigger(v, name, fn() { name }, disabled~, fn(h, _) {
            h.width(Is(Some(120.0))).height(Is(Some(30.0))) |> ignore
          })
          |> ignore
          v.show(fn() { open.get().contains(name) }, at_once=true, fn(s) {
            a.panel(s, name, fn() { name + "内容" }, fn(p) {
              p.width(Is(Some(120.0))) |> ignore
              @headless.button(p, fn() { name + "按钮" }, fn(_) {  }, fn(b, _) {
                b.width(Is(Some(120.0))).height(Is(Some(40.0))) |> ignore
              })
              |> ignore
            })
            |> ignore
          })
        }
      },
    )
    |> ignore
  })
  { t, open, told, off }
}

///|
/// The name of what has the focus ("none": nothing).
fn acc_focus(t : @ui.Tester) -> String {
  t.focused().map(fn(s) { s.label }).unwrap_or("none")
}

///|
test "an accordion's headers: read out buttons expanded as their sections are open, the open one's panel a Region by its name; a click opens another, closing the one open; a click on the open one closes it (collapsible)" {
  let k = acc_case()
  k.t.set_a11y(true)
  let first = (
    k.t.get(Button, label="甲").expanded,
    k.t.get(Button, label="乙").expanded,
    k.t.query(Region, label="甲内容") is Some(_),
    k.t.query(Region, label="乙内容") is Some(_),
  )
  k.t.click(Button, label="乙")
  let second = (k.t.get(Button, label="甲").expanded, k.t.get(Button, label="乙").expanded, k.open.get())
  k.t.click(Button, label="乙")
  assert_eq(
    (first, second, k.open.get(), k.told.copy()),
    ((Some(true), Some(false), true, false), (Some(false), Some(true), ["乙"]), [], ["乙", "乙"]),
  )
}

///|
test "one open at a time and not collapsible: a press on the open one's header tells nothing, it stays open" {
  let k = acc_case(kind=Single(collapsible=false))
  k.t.click(Button, label="甲")
  k.t.act(Button, Activate, label="甲")
  assert_eq((k.open.get(), k.told.copy(), k.t.get(Button, label="甲").expanded), (["甲"], [], Some(true)))
}

///|
test "each its own (Multiple): presses open two at once and close each alone" {
  let k = acc_case(kind=Multiple)
  k.t.click(Button, label="丙")
  let both = k.open.get()
  k.t.click(Button, label="甲")
  assert_eq(
    (both, k.open.get(), k.t.query(Region, label="丙内容") is Some(_)),
    (["甲", "丙"], ["丙"], true),
  )
}

///|
test "keys: Tab stops on each header and what an open panel holds; ↓/↑ go among the headers around the ends, a disabled one passed by and never pressed; Home and End" {
  let k = acc_case()
  k.t.act(Button, Focus, label="甲")
  k.t.tab()
  let tab1 = acc_focus(k.t)
  k.t.tab()
  let tab2 = acc_focus(k.t)
  k.t.act(Button, Focus, label="甲")
  k.t.key(@ui.key_code_down)
  let down = acc_focus(k.t)
  k.t.key(@ui.key_code_up)
  k.off.set(true)
  k.t.frame()
  k.t.key(@ui.key_code_down)
  let down_past = acc_focus(k.t)
  k.t.key(@ui.key_code_down)
  let wrapped = acc_focus(k.t)
  k.t.key(@ui.key_code_end)
  let end = acc_focus(k.t)
  k.t.key(@ui.key_code_home)
  let home = acc_focus(k.t)
  let (x, y, w, h) = k.t.get(Button, label="乙").rect
  k.t.tap(x + w / 2.0, y + h / 2.0)
  assert_eq(
    (tab1, tab2, down, down_past, wrapped, end, home, k.t.get(Button, label="乙").disabled, k.told.copy()),
    ("甲按钮", "乙", "乙", "丙", "甲", "丙", "甲", true, []),
  )
}

///|
test "across, not wrapping: →/← go among its headers and stop at the ends; ↓ is none of its" {
  let k = acc_case(vertical=false, wraps=false)
  k.t.act(Button, Focus, label="甲")
  k.t.key(@ui.key_code_left)
  let stays = acc_focus(k.t)
  k.t.key(@ui.key_code_right)
  let right = acc_focus(k.t)
  k.t.key(@ui.key_code_down)
  let down = acc_focus(k.t)
  k.t.key(@ui.key_code_end)
  k.t.key(@ui.key_code_right)
  assert_eq((stays, right, down, acc_focus(k.t)), ("甲", "乙", "乙", "丙"))
}
