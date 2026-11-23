// White-box tests for Tester::check_pattern and Tester::assert_pattern across all 13 WAI-ARIA APG patterns,
// including RTL navigation, `within` scoping, and negative mutation tests for every violation class.

///|
fn pat_box(parent : @view.View, w : Double, h : Double, body : (@view.View) -> Unit) -> @view.View {
  parent.box(fn(v) {
    v.width(Is(Some(w))).height(Is(Some(h))) |> ignore
    body(v)
  })
}

///|
fn make_tabs_tree(
  root : @view.View,
  rtl? : Bool = false,
  manual? : Bool = false,
  two_tab_stops? : Bool = false,
  broken_arrows? : Bool = false,
) -> Unit {
  let selected = @signals.signal(0)
  let nodes : Array[@view.View] = []
  let labels = ["General", "Security", "Billing"]
  let next_code = if rtl { key_left } else { key_right }
  let prev_code = if rtl { key_right } else { key_left }
  pat_box(root, 360.0, 40.0, fn(tl) {
    tl
    .says(Is(Some(@view.said(TabList, label="Settings"))))
    .on_key(fn(k) {
      if broken_arrows || k.mods != 0 {
        return false
      }
      let cur = nodes.search_by(fn(n) { n.focused() })
      guard cur is Some(i) else { return false }
      let n = nodes.length()
      let to = if k.code == next_code {
        Some((i + 1) % n)
      } else if k.code == prev_code {
        Some((i + n - 1) % n)
      } else if k.code == key_home {
        Some(0)
      } else if k.code == key_end {
        Some(n - 1)
      } else {
        None
      }
      match to {
        Some(j) => {
          if !manual {
            selected.set(j)
          }
          nodes[j].ask_focus(visible=true) |> ignore
          true
        }
        None => false
      }
    })
    |> ignore
    for i, lbl in labels {
      let idx = i
      let tab = pat_box(tl, 100.0, 32.0, fn(v) {
        let is_stop = if two_tab_stops { idx <= 1 } else { idx == 0 }
        v
        .presses(Is(true))
        .focusable(Is(true), tab=is_stop)
        .says(By(fn() { Some(@view.said(Tab, label=lbl, selected=selected.get() == idx)) }))
        .on_press(fn() { selected.set(idx) })
        |> ignore
      })
      nodes.push(tab)
    }
  })
  |> ignore
  pat_box(root, 360.0, 80.0, fn(panel) {
    panel.says(By(fn() { Some(@view.said(TabPanel, label=labels[selected.get()], selected=true)) })) |> ignore
  })
  |> ignore
}

///|
fn make_radio_group_tree(
  root : @view.View,
  vertical? : Bool = false,
  rtl? : Bool = false,
  two_tab_stops? : Bool = false,
) -> Unit {
  let chosen = @signals.signal(0)
  let nodes : Array[@view.View] = []
  let labels = ["Small", "Medium", "Large"]
  let next_code = if vertical { key_down } else if rtl { key_left } else { key_right }
  let prev_code = if vertical { key_up } else if rtl { key_right } else { key_left }
  pat_box(root, 360.0, 120.0, fn(rg) {
    rg
    .says(Is(Some(@view.said(RadioGroup, label="Size"))))
    .on_key(fn(k) {
      if k.mods != 0 {
        return false
      }
      let cur = nodes.search_by(fn(n) { n.focused() })
      guard cur is Some(i) else { return false }
      let n = nodes.length()
      let to = if k.code == next_code {
        Some((i + 1) % n)
      } else if k.code == prev_code {
        Some((i + n - 1) % n)
      } else if k.code == key_home {
        Some(0)
      } else if k.code == key_end {
        Some(n - 1)
      } else {
        None
      }
      match to {
        Some(j) => {
          chosen.set(j)
          nodes[j].ask_focus(visible=true) |> ignore
          true
        }
        None => false
      }
    })
    |> ignore
    for i, lbl in labels {
      let idx = i
      let item = pat_box(rg, 100.0, 32.0, fn(v) {
        let is_stop = if two_tab_stops { idx <= 1 } else { idx == 0 }
        v
        .presses(Is(true))
        .focusable(Is(true), tab=is_stop)
        .says(
          By(fn() {
            Some(@view.said(Radio, label=lbl, check=if chosen.get() == idx { On } else { Off }))
          }),
        )
        .on_press(fn() { chosen.set(idx) })
        |> ignore
      })
      nodes.push(item)
    }
  })
  |> ignore
}

///|
fn make_listbox_tree(root : @view.View, broken_arrows? : Bool = false) -> Unit {
  let chosen = @signals.signal(0)
  let nodes : Array[@view.View] = []
  let labels = ["Apple", "Banana", "Cherry"]
  pat_box(root, 240.0, 140.0, fn(lb) {
    lb
    .says(Is(Some(@view.said(Listbox, label="Fruits"))))
    .on_key(fn(k) {
      if broken_arrows || k.mods != 0 {
        return false
      }
      let cur = nodes.search_by(fn(n) { n.focused() })
      guard cur is Some(i) else { return false }
      let n = nodes.length()
      let to = if k.code == key_down {
        Some((i + 1) % n)
      } else if k.code == key_up {
        Some((i + n - 1) % n)
      } else if k.code == key_home {
        Some(0)
      } else if k.code == key_end {
        Some(n - 1)
      } else {
        None
      }
      match to {
        Some(j) => {
          nodes[j].ask_focus(visible=true) |> ignore
          true
        }
        None => false
      }
    })
    |> ignore
    for i, lbl in labels {
      let idx = i
      let opt = pat_box(lb, 220.0, 32.0, fn(v) {
        v
        .presses(Is(true))
        .focusable(Is(true), tab=idx == 0)
        .says(By(fn() { Some(@view.said(Option, label=lbl, selected=chosen.get() == idx)) }))
        .on_press(fn() { chosen.set(idx) })
        |> ignore
      })
      nodes.push(opt)
    }
  })
  |> ignore
}

///|
fn make_menu_tree(root : @view.View, broken_arrows? : Bool = false) -> Unit {
  let enabled_nodes : Array[@view.View] = []
  pat_box(root, 240.0, 180.0, fn(m) {
    m
    .says(Is(Some(@view.said(Menu, label="Actions"))))
    .on_key(fn(k) {
      if broken_arrows || k.mods != 0 {
        return false
      }
      let cur = enabled_nodes.search_by(fn(n) { n.focused() })
      guard cur is Some(i) else { return false }
      let n = enabled_nodes.length()
      let to = if k.code == key_down {
        Some((i + 1) % n)
      } else if k.code == key_up {
        Some((i + n - 1) % n)
      } else if k.code == key_home {
        Some(0)
      } else if k.code == key_end {
        Some(n - 1)
      } else {
        None
      }
      match to {
        Some(j) => {
          enabled_nodes[j].ask_focus(visible=true) |> ignore
          true
        }
        None => false
      }
    })
    |> ignore
    let item1 = pat_box(m, 200.0, 32.0, fn(v) {
      v
      .presses(Is(true))
      .focusable(Is(true), tab=false)
      .says(Is(Some(@view.said(MenuItem, label="Open"))))
      |> ignore
    })
    enabled_nodes.push(item1)
    // Disabled item in the middle: must be skipped by ArrowDown/ArrowUp.
    pat_box(m, 200.0, 32.0, fn(v) {
      v
      .presses(Is(false))
      .focusable(Is(false), tab=false)
      .says(Is(Some(@view.said(MenuItem, label="Disabled Action"))))
      |> ignore
    })
    |> ignore
    let item2 = pat_box(m, 200.0, 32.0, fn(v) {
      v
      .presses(Is(true))
      .focusable(Is(true), tab=false)
      .says(Is(Some(@view.said(MenuItemCheckbox, label="Word Wrap", check=On))))
      |> ignore
    })
    enabled_nodes.push(item2)
    let item3 = pat_box(m, 200.0, 32.0, fn(v) {
      v
      .presses(Is(true))
      .focusable(Is(true), tab=false)
      .says(Is(Some(@view.said(MenuItemRadio, label="Sort A-Z", check=Off))))
      |> ignore
    })
    enabled_nodes.push(item3)
  })
  |> ignore
}

///|
fn make_dialog_tree(
  root : @view.View,
  is_alert~ : Bool,
  modal~ : Bool,
  label~ : String,
  focus_inside~ : Bool,
) -> Unit {
  pat_box(root, 120.0, 32.0, fn(v) {
    v
    .presses(Is(true))
    .focusable(Is(true))
    .says(Is(Some(@view.said(Button, label="Background"))))
    |> ignore
  })
  |> ignore
  pat_box(root, 300.0, 180.0, fn(dlg) {
    if focus_inside {
      dlg.focus_opens_first() |> ignore
    }
    if modal {
      dlg.modal(Is(true)) |> ignore
    }
    dlg
    .says(Is(Some(@view.said(if is_alert { AlertDialog } else { Dialog }, label~))))
    .presses(Is(true))
    .focusable(Is(true), keys=0, tab=false)
    |> ignore
    pat_box(dlg, 100.0, 32.0, fn(v) {
      v
      .presses(Is(true))
      .focusable(Is(true))
      .says(Is(Some(@view.said(Button, label="Confirm"))))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
fn make_accordion_tree(root : @view.View) -> Unit {
  let open0 = @signals.signal(false)
  let open1 = @signals.signal(false)
  let open2 = @signals.signal(true)
  let states = [open0, open1, open2]
  let labels = ["Section 1", "Section 2", "Section 3"]
  let triggers : Array[@view.View] = []
  pat_box(root, 300.0, 200.0, fn(acc) {
    acc
    .on_key(fn(k) {
      if k.mods != 0 {
        return false
      }
      let cur = triggers.search_by(fn(n) { n.focused() })
      guard cur is Some(i) else { return false }
      let n = triggers.length()
      let to = if k.code == key_down {
        Some((i + 1) % n)
      } else if k.code == key_up {
        Some((i + n - 1) % n)
      } else if k.code == key_home {
        Some(0)
      } else if k.code == key_end {
        Some(n - 1)
      } else {
        None
      }
      match to {
        Some(j) => {
          triggers[j].ask_focus(visible=true) |> ignore
          true
        }
        None => false
      }
    })
    |> ignore
    for i, lbl in labels {
      let sig = states[i]
      let trig = pat_box(acc, 260.0, 32.0, fn(v) {
        v
        .presses(Is(true))
        .focusable(Is(true))
        .says(By(fn() { Some(@view.said(Button, label=lbl, expanded=sig.get())) }))
        .on_press(fn() { sig.set(!sig.get()) })
        |> ignore
      })
      triggers.push(trig)
    }
  })
  |> ignore
}

///|
fn make_disclosure_tree(
  root : @view.View,
  label? : String = "Details",
  with_expanded? : Bool = true,
  broken_toggle? : Bool = false,
) -> Unit {
  let open = @signals.signal(false)
  pat_box(root, 160.0, 36.0, fn(v) {
    v
    .presses(Is(true))
    .focusable(Is(true))
    .says(
      By(fn() {
        if with_expanded {
          Some(@view.said(Button, label~, expanded=open.get()))
        } else {
          Some(@view.said(Button, label~))
        }
      }),
    )
    .on_press(fn() {
      if !broken_toggle {
        open.set(!open.get())
      }
    })
    |> ignore
  })
  |> ignore
}

///|
fn make_combobox_tree(root : @view.View, open~ : Bool) -> Unit {
  let active = @signals.signal(0)
  let labels = ["Alpha", "Beta", "Gamma"]
  pat_box(root, 260.0, 200.0, fn(cb) {
    cb
    .presses(Is(true))
    .focusable(Is(true), keys=0)
    .says(Is(Some(@view.said(Combobox, label="Search items", expanded=open))))
    .on_key(fn(k) {
      if !open || k.mods != 0 {
        return false
      }
      let n = labels.length()
      if k.code == key_down {
        active.set((active.get() + 1) % n)
        true
      } else if k.code == key_up {
        active.set((active.get() + n - 1) % n)
        true
      } else {
        false
      }
    })
    |> ignore
    if open {
      pat_box(cb, 240.0, 120.0, fn(lb) {
        lb.says(Is(Some(@view.said(Listbox, label="Search items")))) |> ignore
        for i, lbl in labels {
          let idx = i
          pat_box(lb, 220.0, 30.0, fn(opt) {
            opt
            .presses(Is(true))
            .says(By(fn() { Some(@view.said(Option, label=lbl, selected=active.get() == idx)) }))
            |> ignore
          })
          |> ignore
        }
      })
      |> ignore
    }
  })
  |> ignore
}

///|
fn make_slider_tree(
  root : @view.View,
  label? : String = "Volume",
  with_range? : Bool = true,
  rtl? : Bool = false,
  initial? : Double = 50.0,
) -> @signals.Signal[Double] {
  let val = @signals.signal(initial)
  let inc_code = if rtl { key_left } else { key_right }
  let dec_code = if rtl { key_right } else { key_left }
  pat_box(root, 240.0, 36.0, fn(v) {
    v
    .presses(Is(true))
    .focusable(Is(true), keys=0)
    .says(
      By(fn() {
        let cur = val.get()
        if with_range {
          Some(@view.said(Slider, label~, range=(0.0, cur, 100.0), actions=[Increment, Decrement]))
        } else {
          Some(@view.said(Slider, label~, actions=[Increment, Decrement]))
        }
      }),
    )
    .on_key(fn(k) {
      if k.mods != 0 {
        return false
      }
      let cur = val.get()
      if k.code == inc_code || k.code == key_up {
        val.set(if cur + 10.0 > 100.0 { 100.0 } else { cur + 10.0 })
        true
      } else if k.code == dec_code || k.code == key_down {
        val.set(if cur - 10.0 < 0.0 { 0.0 } else { cur - 10.0 })
        true
      } else if k.code == key_home {
        val.set(0.0)
        true
      } else if k.code == key_end {
        val.set(100.0)
        true
      } else {
        false
      }
    })
    |> ignore
  })
  |> ignore
  val
}

///|
fn make_toggle_tree(
  root : @view.View,
  role~ : Role,
  label? : String = "Toggle",
  with_check? : Bool = true,
  broken_toggle? : Bool = false,
) -> Unit {
  let on = @signals.signal(false)
  pat_box(root, 160.0, 36.0, fn(v) {
    v
    .presses(Is(true))
    .focusable(Is(true), keys=@view.focus_space)
    .says(
      By(fn() {
        if with_check {
          Some(@view.said(role, label~, check=if on.get() { On } else { Off }))
        } else {
          Some(@view.said(role, label~))
        }
      }),
    )
    .on_press(fn() {
      if !broken_toggle {
        on.set(!on.get())
      }
    })
    |> ignore
  })
  |> ignore
}

///|
fn make_toolbar_tree(root : @view.View, rtl? : Bool = false, two_tab_stops? : Bool = false) -> Unit {
  let nodes : Array[@view.View] = []
  let labels = ["Bold", "Italic", "Underline"]
  let next_code = if rtl { key_left } else { key_right }
  let prev_code = if rtl { key_right } else { key_left }
  pat_box(root, 360.0, 44.0, fn(tb) {
    tb
    .says(Is(Some(@view.said(Toolbar, label="Formatting"))))
    .on_key(fn(k) {
      if k.mods != 0 {
        return false
      }
      let cur = nodes.search_by(fn(n) { n.focused() })
      guard cur is Some(i) else { return false }
      let n = nodes.length()
      let to = if k.code == next_code {
        Some((i + 1) % n)
      } else if k.code == prev_code {
        Some((i + n - 1) % n)
      } else if k.code == key_home {
        Some(0)
      } else if k.code == key_end {
        Some(n - 1)
      } else {
        None
      }
      match to {
        Some(j) => {
          nodes[j].ask_focus(visible=true) |> ignore
          true
        }
        None => false
      }
    })
    |> ignore
    for i, lbl in labels {
      let idx = i
      let btn = pat_box(tb, 90.0, 32.0, fn(v) {
        let is_stop = if two_tab_stops { idx <= 1 } else { idx == 0 }
        v
        .presses(Is(true))
        .focusable(Is(true), tab=is_stop)
        .says(Is(Some(@view.said(Button, label=lbl))))
        |> ignore
      })
      nodes.push(btn)
    }
  })
  |> ignore
}

// ============================================================================
// Positive tests: all 13 APG patterns (including RTL and `within` scoping)
// ============================================================================

///|
test "pattern positive: Tabs (auto, manual, and RTL)" {
  let t1 = Tester::tree(fn(root) { make_tabs_tree(root) }, w=400.0, h=200.0)
  assert_eq(t1.check_pattern(Tabs), [])
  t1.assert_pattern(Tabs, label="tabs-auto")

  let t2 = Tester::tree(fn(root) { make_tabs_tree(root, manual=true) }, w=400.0, h=200.0)
  assert_eq(t2.check_pattern(Tabs), [])
  t2.assert_pattern(Tabs, label="tabs-manual")

  let t3 = Tester::tree(fn(root) { make_tabs_tree(root, rtl=true) }, w=400.0, h=200.0)
  assert_eq(t3.check_pattern(Tabs, rtl=true), [])
  t3.assert_pattern(Tabs, rtl=true, label="tabs-rtl")
}

///|
test "pattern positive: RadioGroup (horizontal, vertical, and RTL)" {
  let t1 = Tester::tree(fn(root) { make_radio_group_tree(root) }, w=400.0, h=200.0)
  assert_eq(t1.check_pattern(RadioGroup), [])
  t1.assert_pattern(RadioGroup, label="radio-horizontal")

  let t2 = Tester::tree(fn(root) { make_radio_group_tree(root, vertical=true) }, w=400.0, h=200.0)
  assert_eq(t2.check_pattern(RadioGroup), [])
  t2.assert_pattern(RadioGroup, label="radio-vertical")

  let t3 = Tester::tree(fn(root) { make_radio_group_tree(root, rtl=true) }, w=400.0, h=200.0)
  assert_eq(t3.check_pattern(RadioGroup, rtl=true), [])
  t3.assert_pattern(RadioGroup, rtl=true, label="radio-rtl")
}

///|
test "pattern positive: Listbox" {
  let t = Tester::tree(fn(root) { make_listbox_tree(root) }, w=400.0, h=200.0)
  assert_eq(t.check_pattern(Listbox), [])
  t.assert_pattern(Listbox, label="listbox")
}

///|
test "pattern positive: Menu with disabled item skipped" {
  let t = Tester::tree(fn(root) { make_menu_tree(root) }, w=400.0, h=240.0)
  assert_eq(t.check_pattern(Menu), [])
  t.assert_pattern(Menu, label="menu")
}

///|
test "pattern positive: Dialog and AlertDialog" {
  let t1 = Tester::tree(
    fn(root) { make_dialog_tree(root, is_alert=false, modal=true, label="Edit Profile", focus_inside=true) },
    w=400.0,
    h=260.0,
  )
  t1.act(Button, Focus, label="Confirm")
  assert_eq(t1.check_pattern(Dialog), [])
  t1.assert_pattern(Dialog, label="dialog")

  let t2 = Tester::tree(
    fn(root) { make_dialog_tree(root, is_alert=true, modal=true, label="Delete Account", focus_inside=true) },
    w=400.0,
    h=260.0,
  )
  t2.act(Button, Focus, label="Confirm")
  assert_eq(t2.check_pattern(AlertDialog), [])
  t2.assert_pattern(AlertDialog, label="alert-dialog")
}

///|
test "pattern positive: Accordion" {
  let t = Tester::tree(fn(root) { make_accordion_tree(root) }, w=400.0, h=240.0)
  assert_eq(t.check_pattern(Accordion), [])
  t.assert_pattern(Accordion, label="accordion")
}

///|
test "pattern positive: Disclosure" {
  let t = Tester::tree(fn(root) { make_disclosure_tree(root) }, w=400.0, h=120.0)
  assert_eq(t.check_pattern(Disclosure), [])
  t.assert_pattern(Disclosure, label="disclosure")
}

///|
test "pattern positive: Combobox (expanded and collapsed)" {
  let t1 = Tester::tree(fn(root) { make_combobox_tree(root, open=true) }, w=400.0, h=240.0)
  assert_eq(t1.check_pattern(Combobox), [])
  t1.assert_pattern(Combobox, label="combobox-open")

  let t2 = Tester::tree(fn(root) { make_combobox_tree(root, open=false) }, w=400.0, h=120.0)
  assert_eq(t2.check_pattern(Combobox), [])
  t2.assert_pattern(Combobox, label="combobox-closed")
}

///|
test "pattern positive: Slider (LTR and RTL, restores initial value)" {
  let sig1 : Ref[@signals.Signal[Double]?] = Ref(None)
  let t1 = Tester::tree(fn(root) { sig1.val = Some(make_slider_tree(root, initial=40.0)) }, w=400.0, h=120.0)
  assert_eq(t1.check_pattern(Slider), [])
  t1.assert_pattern(Slider, label="slider-ltr")
  assert_eq(sig1.val.unwrap().get(), 40.0)

  let sig2 : Ref[@signals.Signal[Double]?] = Ref(None)
  let t2 = Tester::tree(
    fn(root) { sig2.val = Some(make_slider_tree(root, rtl=true, initial=60.0)) },
    w=400.0,
    h=120.0,
  )
  assert_eq(t2.check_pattern(Slider, rtl=true), [])
  t2.assert_pattern(Slider, rtl=true, label="slider-rtl")
  assert_eq(sig2.val.unwrap().get(), 60.0)
}

///|
test "pattern positive: Switch and Checkbox" {
  let t1 = Tester::tree(
    fn(root) { make_toggle_tree(root, role=Switch, label="Dark mode") },
    w=400.0,
    h=120.0,
  )
  assert_eq(t1.check_pattern(Switch), [])
  t1.assert_pattern(Switch, label="switch")

  let t2 = Tester::tree(
    fn(root) { make_toggle_tree(root, role=Checkbox, label="Accept terms") },
    w=400.0,
    h=120.0,
  )
  assert_eq(t2.check_pattern(Checkbox), [])
  t2.assert_pattern(Checkbox, label="checkbox")
}

///|
test "pattern positive: Toolbar (LTR and RTL)" {
  let t1 = Tester::tree(fn(root) { make_toolbar_tree(root) }, w=400.0, h=120.0)
  assert_eq(t1.check_pattern(Toolbar), [])
  t1.assert_pattern(Toolbar, label="toolbar-ltr")

  let t2 = Tester::tree(fn(root) { make_toolbar_tree(root, rtl=true) }, w=400.0, h=120.0)
  assert_eq(t2.check_pattern(Toolbar, rtl=true), [])
  t2.assert_pattern(Toolbar, rtl=true, label="toolbar-rtl")
}

///|
test "pattern positive: within scopes check to one region" {
  let t = Tester::tree(
    fn(root) {
      pat_box(root, 360.0, 60.0, fn(r1) {
        r1.says(Is(Some(@view.said(Region, label="Good region")))) |> ignore
        make_toggle_tree(r1, role=Switch, label="Notifications")
      })
      |> ignore
      pat_box(root, 360.0, 60.0, fn(r2) {
        r2.says(Is(Some(@view.said(Region, label="Broken region")))) |> ignore
        make_toggle_tree(r2, role=Switch, label="", broken_toggle=true)
      })
      |> ignore
    },
    w=400.0,
    h=200.0,
    unnamed_press_held=false,
  )
  let good = t.pattern_semantics().iter().find_first(fn(s) { s.role == Region && s.label == "Good region" }).unwrap()
  let bad = t.pattern_semantics().iter().find_first(fn(s) { s.role == Region && s.label == "Broken region" }).unwrap()
  assert_eq(t.check_pattern(Switch, within=good), [])
  let faults = t.check_pattern(Switch, within=bad)
  assert_true(faults.length() >= 2, msg=faults.join("\n"))
  assert_true(faults.iter().any(fn(f) { f.contains("missing-label") }), msg=faults.join("\n"))
  assert_true(faults.iter().any(fn(f) { f.contains("keyboard-toggle") }), msg=faults.join("\n"))
}

// ============================================================================
// Negative mutation tests: every violation class
// ============================================================================

///|
test "pattern negative: missing label on Switch, Checkbox, Dialog, and Slider" {
  let t_sw = Tester::tree(
    fn(root) { make_toggle_tree(root, role=Switch, label="") },
    w=400.0,
    h=120.0,
    unnamed_press_held=false,
  )
  let f_sw = t_sw.check_pattern(Switch)
  assert_true(f_sw.iter().any(fn(f) { f.contains("[ARIA/Switch]") && f.contains("missing-label") }), msg=f_sw.join("\n"))

  let t_cb = Tester::tree(
    fn(root) { make_toggle_tree(root, role=Checkbox, label="   ") },
    w=400.0,
    h=120.0,
    unnamed_press_held=false,
  )
  let f_cb = t_cb.check_pattern(Checkbox)
  assert_true(
    f_cb.iter().any(fn(f) { f.contains("[ARIA/Checkbox]") && f.contains("missing-label") }),
    msg=f_cb.join("\n"),
  )

  let t_dlg = Tester::tree(
    fn(root) { make_dialog_tree(root, is_alert=false, modal=true, label="", focus_inside=true) },
    w=400.0,
    h=260.0,
    unnamed_press_held=false,
  )
  let f_dlg = t_dlg.check_pattern(Dialog)
  assert_true(
    f_dlg.iter().any(fn(f) { f.contains("[ARIA/Dialog]") && f.contains("missing-label") }),
    msg=f_dlg.join("\n"),
  )

  let t_sl = Tester::tree(
    fn(root) { make_slider_tree(root, label="") |> ignore },
    w=400.0,
    h=120.0,
    unnamed_press_held=false,
  )
  let f_sl = t_sl.check_pattern(Slider)
  assert_true(
    f_sl.iter().any(fn(f) { f.contains("[ARIA/Slider]") && f.contains("missing-label") }),
    msg=f_sl.join("\n"),
  )
}

///|
test "pattern negative: missing range on Slider, check on Switch, expanded on Disclosure" {
  let t_sl = Tester::tree(
    fn(root) { make_slider_tree(root, with_range=false) |> ignore },
    w=400.0,
    h=120.0,
  )
  let f_sl = t_sl.check_pattern(Slider)
  assert_true(
    f_sl.iter().any(fn(f) { f.contains("[ARIA/Slider]") && f.contains("missing-range") }),
    msg=f_sl.join("\n"),
  )

  let t_sw = Tester::tree(
    fn(root) { make_toggle_tree(root, role=Switch, label="Audio", with_check=false) },
    w=400.0,
    h=120.0,
  )
  let f_sw = t_sw.check_pattern(Switch)
  assert_true(
    f_sw.iter().any(fn(f) { f.contains("[ARIA/Switch]") && f.contains("missing-state") }),
    msg=f_sw.join("\n"),
  )

  let t_dis = Tester::tree(
    fn(root) { make_disclosure_tree(root, label="More info", with_expanded=false) },
    w=400.0,
    h=120.0,
  )
  let f_dis = t_dis.check_pattern(Disclosure)
  assert_true(
    f_dis.iter().any(fn(f) { f.contains("[ARIA/Disclosure]") && f.contains("missing-state") }),
    msg=f_dis.join("\n"),
  )
}

///|
test "pattern negative: two tab stops in RadioGroup, Tabs, and Toolbar" {
  let t_rg = Tester::tree(fn(root) { make_radio_group_tree(root, two_tab_stops=true) }, w=400.0, h=200.0)
  let f_rg = t_rg.check_pattern(RadioGroup)
  assert_true(
    f_rg.iter().any(fn(f) { f.contains("[ARIA/RadioGroup]") && f.contains("single-tab-stop") }),
    msg=f_rg.join("\n"),
  )

  let t_tabs = Tester::tree(fn(root) { make_tabs_tree(root, two_tab_stops=true) }, w=400.0, h=200.0)
  let f_tabs = t_tabs.check_pattern(Tabs)
  assert_true(
    f_tabs.iter().any(fn(f) { f.contains("[ARIA/Tabs]") && f.contains("single-tab-stop") }),
    msg=f_tabs.join("\n"),
  )

  let t_tb = Tester::tree(fn(root) { make_toolbar_tree(root, two_tab_stops=true) }, w=400.0, h=120.0)
  let f_tb = t_tb.check_pattern(Toolbar)
  assert_true(
    f_tb.iter().any(fn(f) { f.contains("[ARIA/Toolbar]") && f.contains("single-tab-stop") }),
    msg=f_tb.join("\n"),
  )
}

///|
test "pattern negative: arrow keys fail to move focus in Tabs, Listbox, and Menu" {
  let t_tabs = Tester::tree(fn(root) { make_tabs_tree(root, broken_arrows=true) }, w=400.0, h=200.0)
  let f_tabs = t_tabs.check_pattern(Tabs)
  assert_true(
    f_tabs.iter().any(fn(f) { f.contains("[ARIA/Tabs]") && f.contains("keyboard-nav") }),
    msg=f_tabs.join("\n"),
  )

  let t_lb = Tester::tree(fn(root) { make_listbox_tree(root, broken_arrows=true) }, w=400.0, h=200.0)
  let f_lb = t_lb.check_pattern(Listbox)
  assert_true(
    f_lb.iter().any(fn(f) { f.contains("[ARIA/Listbox]") && f.contains("keyboard-nav") }),
    msg=f_lb.join("\n"),
  )

  let t_menu = Tester::tree(fn(root) { make_menu_tree(root, broken_arrows=true) }, w=400.0, h=240.0)
  let f_menu = t_menu.check_pattern(Menu)
  assert_true(
    f_menu.iter().any(fn(f) { f.contains("[ARIA/Menu]") && f.contains("keyboard-nav") }),
    msg=f_menu.join("\n"),
  )
}

///|
test "pattern negative: AlertDialog missing modal=true or focus leaked outside dialog" {
  let t_nomodal = Tester::tree(
    fn(root) { make_dialog_tree(root, is_alert=true, modal=false, label="Confirm delete", focus_inside=true) },
    w=400.0,
    h=260.0,
  )
  t_nomodal.act(Button, Focus, label="Confirm")
  let f_nomodal = t_nomodal.check_pattern(AlertDialog)
  assert_true(
    f_nomodal.iter().any(fn(f) { f.contains("[ARIA/AlertDialog]") && f.contains("missing-modal") }),
    msg=f_nomodal.join("\n"),
  )

  let t_outside = Tester::tree(
    fn(root) { make_dialog_tree(root, is_alert=true, modal=false, label="Confirm delete", focus_inside=false) },
    w=400.0,
    h=260.0,
  )
  t_outside.act(Button, Focus, label="Background")
  let f_outside = t_outside.check_pattern(AlertDialog)
  assert_true(
    f_outside.iter().any(fn(f) { f.contains("[ARIA/AlertDialog]") && f.contains("missing-modal") }),
    msg=f_outside.join("\n"),
  )
  assert_true(
    f_outside.iter().any(fn(f) { f.contains("[ARIA/AlertDialog]") && f.contains("focus-containment") }),
    msg=f_outside.join("\n"),
  )
}

///|
test "pattern negative: Space fails to toggle Switch, Checkbox, and Disclosure" {
  let t_sw = Tester::tree(
    fn(root) { make_toggle_tree(root, role=Switch, label="Mute", broken_toggle=true) },
    w=400.0,
    h=120.0,
  )
  let f_sw = t_sw.check_pattern(Switch)
  assert_true(
    f_sw.iter().any(fn(f) { f.contains("[ARIA/Switch]") && f.contains("keyboard-toggle") }),
    msg=f_sw.join("\n"),
  )

  let t_cb = Tester::tree(
    fn(root) { make_toggle_tree(root, role=Checkbox, label="Subscribe", broken_toggle=true) },
    w=400.0,
    h=120.0,
  )
  let f_cb = t_cb.check_pattern(Checkbox)
  assert_true(
    f_cb.iter().any(fn(f) { f.contains("[ARIA/Checkbox]") && f.contains("keyboard-toggle") }),
    msg=f_cb.join("\n"),
  )

  let t_dis = Tester::tree(
    fn(root) { make_disclosure_tree(root, label="Show logs", broken_toggle=true) },
    w=400.0,
    h=120.0,
  )
  let f_dis = t_dis.check_pattern(Disclosure)
  assert_true(
    f_dis.iter().any(fn(f) { f.contains("[ARIA/Disclosure]") && f.contains("keyboard-toggle") }),
    msg=f_dis.join("\n"),
  )
}
