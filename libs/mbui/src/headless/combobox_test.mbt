// The headless combobox (@headless.combobox, Combobox::listbox, Combobox::option), under a look of the tests' own with
// a field of ui's in it: read out a Combobox (expanded), a Listbox and its Options; ↓/↑ from the field (the keymap's
// combobox_keys) move what is active among the enabled options shown, the field keeping the focus and what is written
// in it; a filter that takes the active option away moves it to the first left; Enter chooses it; Escape closes; a
// press on an option chooses it at once and moves no focus; with no field the list takes the focus by Tab and Home,
// End and Space are its. Each window is made by `window` (window_test.mbt), which holds that combobox.mbt draws and
// lays out nothing.

///|
/// What a case keeps: its window, its field, what was chosen, whether it is open, the key the keys are on (the
/// caller's), which options are disabled, the combobox and its options as their looks read them.
struct ComboCase {
  t : @ui.Tester
  field : @ui.Field
  chosen : Array[String]
  open : @signals.Signal[Bool]
  active : @signals.Signal[String?]
  off : @signals.Signal[Array[String]]
  cb : Ref[@headless.Combobox[String]?]
  opts : Map[String, @headless.ComboOption]
}

///|
/// The options of the tests' combobox, filtered by what is written: those whose name holds it.
let combo_all : Array[String] = ["苹果", "香蕉", "橙子", "葡萄"]

///|
/// A window with a button "前" and a combobox "水果" over `combo_all`: its field "搜索" (one line; none where `field` is
/// false, its list then taking the focus), its options filtered by the field's words, made by `each` in its list; the
/// keymap `combobox_keys` where `keymap`.
fn combo_case(
  field? : Bool = true,
  keymap? : Bool = true,
  pointing? : @ui.Pointing = Mouse,
) -> ComboCase raise {
  let words = @signals.signal("")
  let f = @ui.Field::new(text="")
  let chosen : Array[String] = []
  let last : @signals.Signal[String?] = @signals.signal(None)
  let open = @signals.signal(true)
  let active : @signals.Signal[String?] = @signals.signal(None)
  let off : @signals.Signal[Array[String]] = @signals.signal([])
  let cb_ref : Ref[@headless.Combobox[String]?] = Ref(None)
  let opts : Map[String, @headless.ComboOption] = Map([])
  let shown = fn() { combo_all.filter(fn(k) { k.contains(words.get()) }) }
  let t = window(pointing~, fn(root) {
    if keymap {
      root.keymap(Is(@view.Keymap::new(@headless.combobox_keys))) |> ignore
    }
    root.box(fn(before) {
      before
      .width(Is(Some(40.0)))
      .height(Is(Some(30.0)))
      .presses(Is(true))
      .focusable(Is(true))
      .says(Is(Some(@view.said(Button, label="前"))))
      .on_press(fn() {  })
      |> ignore
    })
    |> ignore
    @headless.combobox(
      root,
      fn() { "水果" },
      shown,
      fn() { active.get() },
      fn(k) { active.set(k) },
      fn(k) {
        chosen.push(k)
        last.set(Some(k))
        open.set(false)
      },
      open=fn() { open.get() },
      chosen=fn() { last.get() },
      key_disabled=fn(k) { off.get().contains(k) },
      on_close=fn() { open.set(false) },
      field~,
      fn(c, cb) {
        cb_ref.val = Some(cb)
        if field {
          @ui.field(c, f, label="搜索", max_lines=1, edited=fn(w) { words.set(w) }) |> ignore
        }
        cb.listbox(c, fn(l) {
          l.each(shown, fn(k) { k }, at_once=true, fn(slot, k) {
            let name = k.untracked()
            cb.option(slot, fn() { name }, fn() { name }, in_node=true, fn(v, o) {
              opts[name] = o
              v
              .width(Is(Some(160.0)))
              .height(Is(Some(28.0)))
              .ground(By(fn() { if o.active() || o.hovered() { c_pressed } else { c_rest } }))
              |> ignore
            })
            |> ignore
          })
        })
        |> ignore
      },
    )
    |> ignore
  })
  { t, field: f, chosen, open, active, off, cb: cb_ref, opts }
}

///|
/// The option active now (the combobox's reading, as its look reads it), "" none.
fn ComboCase::now(self : ComboCase) -> String {
  match self.cb.val {
    Some(cb) => cb.active().unwrap_or("")
    None => ""
  }
}

///|
/// The options read out now, in order.
fn ComboCase::shown(self : ComboCase) -> Array[String] {
  self.t.all(Option).map(fn(s) { s.label })
}

///|
test "a combobox with a field: read out a Combobox expanded, a Listbox of Options; the first enabled option active at first; ↓/↑ from the field move it around the ends and pass a disabled one by, the field keeping the focus and its words; Enter chooses" {
  let k = combo_case()
  assert_eq(
    (
      k.t.get(Combobox, label="水果").expanded,
      k.t.all(Listbox).length(),
      k.shown(),
      k.t.get(Option, label="苹果").selected,
    ),
    (Some(true), 1, combo_all, Some(false)),
  )
  // nothing said active: the first shown is; the options take no focus
  k.off.set(["香蕉"])
  k.t.frame()
  let first = k.now()
  k.t.act(TextField, Focus, label="搜索")
  k.t.key(@ui.key_code_down)
  let next = k.now()
  k.t.key(@ui.key_code_down)
  k.t.key(@ui.key_code_down)
  let wrapped = k.now()
  k.t.key(@ui.key_code_up)
  let back = k.now()
  let focus = focus_name(k.t)
  // what the look reads: the active option's own reading, and no other's
  let look_active = combo_all.filter(fn(n) { k.opts.get(n).map_or(false, fn(o) { o.active() }) })
  assert_eq((first, next, wrapped, back, focus, look_active), ("苹果", "橙子", "苹果", "葡萄", "搜索", ["葡萄"]))
  // Enter chooses "葡萄", read out selected; nothing of the keys was written in the field
  k.t.enter()
  assert_eq(
    (k.chosen.copy(), k.t.get(Option, label="葡萄").selected, k.field.text(), k.t.get(Combobox, label="水果").expanded),
    (["葡萄"], Some(true), "", Some(false)),
  )
  // closed, its keys are not its: ↓ goes to the field (nothing moves)
  k.t.key(@ui.key_code_down)
  assert_eq(k.now(), "葡萄")
}

///|
test "a filter that takes the active option away moves it to the first left, and one that leaves it keeps it; Escape from the field closes it" {
  let k = combo_case()
  k.t.act(TextField, Focus, label="搜索")
  k.t.key(@ui.key_code_down)
  k.t.key(@ui.key_code_down)
  let was = k.now()
  // "子": only "橙子" left, the active one; "葡": "橙子" gone, "葡萄" the first left
  k.t.type_text("子")
  let kept = (k.shown(), k.now())
  k.field.set("")
  k.t.type_text("葡")
  let moved = (k.shown(), k.now(), k.active.get())
  // the filter taking all away: none active, Enter chooses none
  k.t.type_text("无")
  let none = (k.shown(), k.now())
  k.t.enter()
  let chose_none = k.chosen.copy()
  k.t.key(@ui.key_escape)
  assert_eq(
    (was, kept, moved, none, chose_none, k.open.get(), k.field.text()),
    (
      "橙子",
      (["橙子"], "橙子"),
      (["葡萄"], "葡萄", Some("橙子")),
      ([], ""),
      [],
      false,
      "葡无",
    ),
  )
}

///|
test "a press on an option makes it active and chooses it at once, moving no focus; a press on a disabled option does nothing" {
  let k = combo_case(pointing=Finger)
  k.off.set(["香蕉"])
  k.t.frame()
  k.t.click(Option, label="香蕉")
  let after_off = (k.chosen.copy(), k.now())
  k.t.click(Option, label="橙子")
  assert_eq(
    (after_off, k.chosen.copy(), k.active.get(), k.t.focused() is None),
    (([], "苹果"), ["橙子"], Some("橙子"), true),
  )
}

///|
test "a combobox with no field: its list takes the focus by Tab; ↓, End, Home, ↑ move what is active with no keymap at all; Space chooses; with the focus outside it the keys are not its" {
  let k = combo_case(field=false, keymap=false)
  k.t.act(Button, Focus, label="前")
  k.t.key(@ui.key_code_down)
  let outside = (k.now(), k.active.get())
  k.t.tab()
  let focus = k.t.focused().map(fn(s) { s.role == Listbox && s.label == "水果" })
  k.t.key(@ui.key_code_down)
  let down = k.now()
  k.t.key(@ui.key_code_end)
  let end = k.now()
  k.t.key(@ui.key_code_home)
  let home = k.now()
  k.t.key(@ui.key_code_up)
  let up = k.now()
  k.t.key(@ui.key_space)
  assert_eq(
    (outside, focus, down, end, home, up, k.chosen.copy()),
    (("苹果", None), Some(true), "香蕉", "葡萄", "苹果", "葡萄", ["葡萄"]),
  )
}

///|
test "a combobox not wrapping: ↓ stops at the last enabled option, ↑ at the first" {
  let active : @signals.Signal[String?] = @signals.signal(None)
  let cb_ref : Ref[@headless.Combobox[String]?] = Ref(None)
  let t = window(fn(root) {
    @headless.combobox(
      root,
      fn() { "数" },
      fn() { ["一", "二"] },
      fn() { active.get() },
      fn(k) { active.set(k) },
      fn(_) {  },
      field=false,
      wraps=false,
      fn(c, cb) {
        cb_ref.val = Some(cb)
        cb.listbox(c, fn(l) {
          for name in ["一", "二"] {
            cb.option(l, fn() { name }, fn() { name }, fn(v, _) {
              v.width(Is(Some(80.0))).height(Is(Some(28.0))) |> ignore
            })
            |> ignore
          }
        })
        |> ignore
      },
    )
    |> ignore
  })
  let now = fn() { cb_ref.val.unwrap().active().unwrap_or("") }
  t.tab()
  t.key(@ui.key_code_down)
  t.key(@ui.key_code_down)
  let last = now()
  t.key(@ui.key_code_up)
  t.key(@ui.key_code_up)
  assert_eq((last, now()), ("二", "一"))
}

///|
test "a combobox in the node that holds its field (in_node): that node read out the Combobox; `moved` told the key the keys made active, a press none" {
  let active : @signals.Signal[String?] = @signals.signal(None)
  let moved : Array[String] = []
  let chosen : Array[String] = []
  let f = @ui.Field::new(text="")
  let t = window(fn(root) {
    root.keymap(Is(@view.Keymap::new(@headless.combobox_keys))) |> ignore
    root.box(fn(holder) {
      @headless.combobox(
        holder,
        fn() { "水果" },
        fn() { combo_all },
        fn() { active.get() },
        fn(k) { active.set(k) },
        fn(k) { chosen.push(k) },
        moved=fn(k) { moved.push(k) },
        in_node=true,
        fn(c, cb) {
          @ui.field(c, f, label="搜索", max_lines=1) |> ignore
          cb.listbox(c, fn(l) {
            for name in combo_all {
              cb.option(l, fn() { name }, fn() { name }, fn(v, _) {
                v.width(Is(Some(160.0))).height(Is(Some(28.0))) |> ignore
              })
              |> ignore
            }
          })
          |> ignore
        },
      )
      |> ignore
    })
    |> ignore
  })
  let combo = t.get(Combobox, label="水果")
  t.act(TextField, Focus, label="搜索")
  t.key(@ui.key_code_down)
  t.key(@ui.key_code_down)
  t.click(Option, label="葡萄")
  assert_eq((t.all(Combobox).length(), combo.expanded, moved, chosen, active.get()), (1, Some(true), ["香蕉", "橙子"], ["葡萄"], Some("葡萄")))
}
