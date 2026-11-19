// The headless toggle group (@headless.toggle_group, ToggleGroup::item), under a look of the tests' own: a Group of
// buttons read out pressed as their caller says; a press telling its key and what it is to be; Multiple each its own,
// Single one at a time (the caller's); Tab stops on one item (the last with the focus, else the first on, else the
// first enabled); ←/→ among the enabled items around the ends, Home and End, turning nothing; a disabled item passed by
// and never turned. Each window is made by `window` (window_test.mbt), which holds that toggle_group.mbt draws and lays
// out nothing.

///|
/// What a case keeps: its window, the items on (the caller's), and what was told.
struct TgCase {
  t : @ui.Tester
  on : @signals.Signal[Array[String]]
  told : Array[(String, Bool)]
}

///|
/// A window: a button "前", the group "格式" of 粗 斜 下 (斜 disabled where `mid_off`), each 50 by 30 in a row, and a
/// button "后"; `kind` its kind; at first `start` on.
fn tg_case(
  kind? : @headless.ToggleGroupKind = Multiple,
  mid_off? : Bool = false,
  start? : Array[String] = [],
) -> TgCase raise {
  let on : @signals.Signal[Array[String]] = @signals.signal(start)
  let told : Array[(String, Bool)] = []
  let single = kind is Single
  let side = fn(root : @view.View, name : String) {
    @headless.button(root, fn() { name }, fn(_) {  }, fn(v, _) {
      v.width(Is(Some(40.0))).height(Is(Some(30.0))) |> ignore
    })
    |> ignore
  }
  let t = window(fn(root) {
    side(root, "前")
    @headless.toggle_group(
      root,
      fn() { "格式" },
      fn(k) { on.get().contains(k) },
      fn(k, to) {
        told.push((k, to))
        let now = on.get()
        if !to {
          on.set(now.filter(fn(x) { x != k }))
        } else if single {
          on.set([k])
        } else {
          on.set(now + [k])
        }
      },
      kind~,
      fn(v, g) {
        v.row(Is(true)) |> ignore
        for name in ["粗", "斜", "下"] {
          let disabled = if name == "斜" && mid_off { fn() { true } } else { fn() { false } }
          g.item(v, name, fn() { name }, disabled~, fn(i, _) {
            i.width(Is(Some(50.0))).height(Is(Some(30.0))) |> ignore
          })
          |> ignore
        }
      },
    )
    |> ignore
    side(root, "后")
  })
  { t, on, told }
}

///|
/// The name of what has the focus ("none": nothing).
fn tg_focus(t : @ui.Tester) -> String {
  t.focused().map(fn(s) { s.label }).unwrap_or("none")
}

///|
test "a toggle group: read out a Group of buttons pressed as they are on; each its own: presses turn two on and one off, each told its key and what it is to be" {
  let k = tg_case()
  k.t.set_a11y(true)
  let group = k.t.query(Group, label="格式") is Some(_)
  k.t.click(Button, label="粗")
  k.t.click(Button, label="下")
  let two = (k.t.get(Button, label="粗").pressed, k.t.get(Button, label="下").pressed, k.t.get(Button, label="斜").pressed)
  k.t.act(Button, Activate, label="粗")
  assert_eq(
    (group, two, k.on.get(), k.told.copy()),
    (true, (Some(true), Some(true), Some(false)), ["下"], [("粗", true), ("下", true), ("粗", false)]),
  )
}

///|
test "one at a time: turning one on, the caller turns the other off; a press on the one on turns it off" {
  let k = tg_case(kind=Single, start=["粗"])
  k.t.click(Button, label="斜")
  let moved = k.on.get()
  k.t.click(Button, label="斜")
  assert_eq((moved, k.on.get(), k.told.copy()), (["斜"], [], [("斜", true), ("斜", false)]))
}

///|
test "keys: Tab stops on the first on, one stop for the group; →/← among the enabled items around the ends, a disabled one passed by and turning nothing; Home and End; Tab comes back to the last that had the focus" {
  let k = tg_case(mid_off=true, start=["下"])
  k.t.act(Button, Focus, label="前")
  k.t.tab()
  let in_at = tg_focus(k.t)
  k.t.tab()
  let out = tg_focus(k.t)
  k.t.act(Button, Focus, label="粗")
  k.t.key(@ui.key_code_right)
  let past_off = tg_focus(k.t)
  k.t.key(@ui.key_code_right)
  let wrapped = tg_focus(k.t)
  k.t.key(@ui.key_code_end)
  let end = tg_focus(k.t)
  k.t.key(@ui.key_code_home)
  let home = tg_focus(k.t)
  k.t.act(Button, Focus, label="后")
  k.t.tab(back=true)
  let back_in = tg_focus(k.t)
  let (x, y, w, h) = k.t.get(Button, label="斜").rect
  k.t.tap(x + w / 2.0, y + h / 2.0)
  assert_eq(
    (in_at, out, past_off, wrapped, end, home, back_in, k.told.copy(), k.on.get()),
    ("下", "后", "下", "粗", "下", "粗", "粗", [], ["下"]),
  )
}
