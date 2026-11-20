// The headless list box (@headless.listbox, Listbox::option), under a look of the tests' own: a Listbox of Options read
// out selected as their caller says; one Tab stop (the first selected, else the first enabled; then the last with the
// focus); ↓/↑ among the enabled options (stopping at the ends, or around them), Home and End, choosing nothing; Enter,
// Space, a click and Activate choosing one (one of one: not again where it is chosen; multiple: each press told); a
// disabled option passed by and never chosen; typeahead finding the next option by what was typed within 500 ms of the
// letter before (the moment of each key: the same at any rate of frames), the same letter again going on, and begun
// anew past it. Each window is made by `window` (window_test.mbt), which holds that listbox.mbt draws and lays out
// nothing.

///|
/// How long letters typed together find an option (the list box's `typeahead_ms`, its default).
let typed_ms : Double = 500.0

///|
/// The least step of the clock a test takes.
let lb_tick_ms : Double = 1.0

///|
/// What a case keeps: its window, the selected options (the caller's), and the keys told.
struct LbCase {
  t : @ui.Tester
  selected : @signals.Signal[Array[String]]
  told : Array[String]
}

///|
/// The options: their keys and names.
let lb_names : Array[(String, String)] = [
  ("apple", "Apple"),
  ("apricot", "Apricot"),
  ("banana", "Banana"),
  ("blueberry", "Blueberry"),
  ("cherry", "Cherry"),
]

///|
/// A window: a button "前", the list box "水果" of `lb_names` (Banana disabled where `off`), each 120 by 24 down a
/// column, and a button "后"; `multiple` and `wraps` as given; at first `start` selected.
fn lb_case(
  multiple? : Bool = false,
  wraps? : Bool = false,
  off? : Bool = false,
  start? : Array[String] = [],
) -> LbCase raise {
  let selected : @signals.Signal[Array[String]] = @signals.signal(start)
  let told : Array[String] = []
  let side = fn(root : @view.View, name : String) {
    @headless.button(root, fn() { name }, fn(_) {  }, fn(v, _) {
      v.width(Is(Some(40.0))).height(Is(Some(24.0))) |> ignore
    })
    |> ignore
  }
  let t = window(fn(root) {
    side(root, "前")
    @headless.listbox(
      root,
      fn() { "水果" },
      fn(k) { selected.get().contains(k) },
      fn(k) {
        told.push(k)
        let now = selected.get()
        if !multiple {
          selected.set([k])
        } else if now.contains(k) {
          selected.set(now.filter(fn(x) { x != k }))
        } else {
          selected.set(now + [k])
        }
      },
      multiple~,
      wraps~,
      fn(v, lb) {
        for e in lb_names {
          let (key, name) = e
          let disabled = if key == "banana" && off { fn() { true } } else { fn() { false } }
          lb.option(v, key, fn() { name }, disabled~, fn(o, _) {
            o.width(Is(Some(120.0))).height(Is(Some(24.0))) |> ignore
          })
          |> ignore
        }
      },
    )
    |> ignore
    side(root, "后")
  })
  { t, selected, told }
}

///|
/// The name of what has the focus ("none": nothing).
fn lb_focus(t : @ui.Tester) -> String {
  t.focused().map(fn(s) { s.label }).unwrap_or("none")
}

///|
/// The letter `c` typed (its key, as a keyboard's is told).
fn lb_type(t : @ui.Tester, c : Char) -> Unit {
  t.key(@ui.key_of_char(c))
}

///|
test "a list box: read out a Listbox of Options selected as chosen; Tab stops on the selected option, one stop for it; ↓/↑ move the focus, stopping at the ends, choosing nothing; Enter and Space choose the one with the focus" {
  let k = lb_case(start=["banana"])
  k.t.set_a11y(true)
  let list = k.t.query(Listbox, label="水果") is Some(_)
  let sel = (k.t.get(Option, label="Banana").selected, k.t.get(Option, label="Apple").selected)
  k.t.act(Button, Focus, label="前")
  k.t.tab()
  let in_at = lb_focus(k.t)
  k.t.tab()
  let out = lb_focus(k.t)
  k.t.tab(back=true)
  k.t.key(@ui.key_code_down)
  k.t.key(@ui.key_code_down)
  k.t.key(@ui.key_code_down)
  let at_end = (lb_focus(k.t), k.told.copy())
  k.t.key(@ui.key_code_home)
  k.t.key(@ui.key_code_up)
  let at_top = lb_focus(k.t)
  k.t.enter()
  k.t.key(@ui.key_code_end)
  k.t.key(@ui.key_space)
  assert_eq(
    (list, sel, in_at, out, at_end, at_top, k.told.copy(), k.selected.get()),
    (true, (Some(true), Some(false)), "Banana", "后", ("Cherry", []), "Apple", ["apple", "cherry"], ["cherry"]),
  )
}

///|
test "one of one: a click on the one chosen tells nothing; multiple: each click told, the caller turning it; a disabled option passed by the keys and never chosen" {
  let k = lb_case(off=true, start=["apple"])
  k.t.click(Option, label="Apple")
  let one = k.told.copy()
  let m = lb_case(multiple=true, off=true)
  m.t.click(Option, label="Apple")
  m.t.click(Option, label="Cherry")
  m.t.act(Option, Activate, label="Apple")
  m.t.act(Option, Focus, label="Apricot")
  m.t.key(@ui.key_code_down)
  let past_off = lb_focus(m.t)
  let (x, y, w, h) = m.t.get(Option, label="Banana").rect
  m.t.tap(x + w / 2.0, y + h / 2.0)
  assert_eq(
    (one, m.told.copy(), m.selected.get(), past_off, m.t.get(Option, label="Banana").disabled),
    ([], ["apple", "cherry", "apple"], ["cherry"], "Blueberry", true),
  )
}

///|
test "wraps: ↓ past the last comes to the first, ↑ before the first to the last" {
  let k = lb_case(wraps=true)
  k.t.act(Option, Focus, label="Cherry")
  k.t.key(@ui.key_code_down)
  let first = lb_focus(k.t)
  k.t.key(@ui.key_code_up)
  assert_eq((first, lb_focus(k.t)), ("Apple", "Cherry"))
}

///|
test "typeahead: letters within 500 ms of each other find together; the same letter again goes on to the next; past 500 ms what is typed begins anew; a disabled option passed by; nothing chosen" {
  let k = lb_case(off=true)
  k.t.act(Option, Focus, label="Apple")
  // (b: from after Apple, Banana disabled, Blueberry)
  lb_type(k.t, 'b')
  let b = lb_focus(k.t)
  // (c then h 499 ms after: "ch", Cherry)
  k.t.run_for(typed_ms + lb_tick_ms)
  lb_type(k.t, 'c')
  k.t.run_for(typed_ms - lb_tick_ms)
  lb_type(k.t, 'h')
  let ch = lb_focus(k.t)
  // (a, a again within 500 ms: Apple, then on to Apricot; a again: around to Apple)
  k.t.run_for(typed_ms + lb_tick_ms)
  lb_type(k.t, 'a')
  let a1 = lb_focus(k.t)
  k.t.run_for(typed_ms / 2.0)
  lb_type(k.t, 'a')
  let a2 = lb_focus(k.t)
  k.t.run_for(typed_ms / 2.0)
  lb_type(k.t, 'A')
  let a3 = lb_focus(k.t)
  // ("ap" then "r" 501 ms after: begun anew, "r" finds none, the focus stays)
  k.t.run_for(typed_ms + lb_tick_ms)
  lb_type(k.t, 'r')
  assert_eq((b, ch, a1, a2, a3, lb_focus(k.t), k.told.copy()), ("Blueberry", "Cherry", "Apple", "Apricot", "Apple", "Apple", []))
}
