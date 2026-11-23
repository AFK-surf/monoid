// Comma's floating parts and the rest of its base parts as the hand, the keyboard and a screen reader meet them: a menu
// opened, walked by the arrow keys, done by Enter and shut by Escape; a dropdown's choice; a dialog over all, shut by
// Escape or its scrim; a tooltip by the keyboard's focus; a toast gone at its time; a slider stepped; a collapse opened;
// a button group's and a radio group's choice; and all of it open at once held to mbui's audit.

///|
/// A Tester of a 1000 × 700 window in Comma's theme, its layer made first, `make` making the page; drawn.
fn floating_case(
  make : (@view.View, Layer) -> Unit,
  dark? : Bool = false,
  w? : Double = 1000.0,
  h? : Double = 700.0,
) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w~, h~, platform=0)
  set_dark(Some(dark))
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme)
    let layer = Layer::new()
    layer_node(root, layer)
    root.box(fn(w) {
      w.grow(Is(1.0)).ground(By(fn() { colors().bg_primary })) |> ignore
      w.box(fn(page) {
        page.grow(Is(1.0)).padding(Is((24.0, 24.0, 24.0, 24.0))).gap(Is(12.0)) |> ignore
        make(page, layer)
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// How long a floating part takes at most to come or go (the longest of Comma's enter and exit durations it uses).
let floating_ms : Double = 400.0

///|
test "a menu opens from its button, its rows walked by the arrow keys, Enter doing one and shutting it, Escape shutting it" {
  let open = @signals.signal(false)
  let done = Ref([])
  let t = floating_case(fn(p, layer) {
    let a = button_node(p, fn() { "Options" }, fn() { open.set(true) }, hierarchy=SecondaryGray)
    menu_node(layer, a, open, fn() {
      [menu_item("Profile", fn() { done.val.push("Profile") }), menu_item("Settings", fn() { done.val.push("Settings") })]
    })
  })
  t.act(Button, Activate, label="Options")
  t.run_for(floating_ms)
  let shown = t.all(Menu, label="Menu").length()
  t.key(@ui.key_code_down)
  t.key(@ui.key_code_down)
  t.key(@ui.key_code_enter)
  t.run_for(floating_ms)
  let after_enter = (open.get(), t.all(Menu, label="Menu").length())
  t.act(Button, Activate, label="Options")
  t.run_for(floating_ms)
  t.key(@ui.key_escape)
  t.run_for(floating_ms)
  assert_eq((shown, done.val, after_enter, open.get()), (1, ["Settings"], (false, 0), false))
}

///|
test "a dropdown's trigger (a disclosure) opens its list, a menu of radios; an option activated is chosen, read out in the trigger's name, and the list shut" {
  let chosen = @signals.signal(-1)
  let t = floating_case(fn(p, layer) {
    p.box(fn(b) {
      b.width(Is(Some(240.0))) |> ignore
      dropdown_node(b, layer, ["Light", "Dark", "System"], chosen, label="Appearance") |> ignore
    })
    |> ignore
  })
  let before = t.get(Button, label="Appearance").expanded
  t.act(Button, Activate, label="Appearance")
  t.run_for(floating_ms)
  let open = (t.get(Button, label="Appearance").expanded, t.all(MenuItemRadio).map(fn(s) { s.label }))
  t.act(MenuItemRadio, Activate, label="Dark")
  t.run_for(floating_ms)
  assert_eq(
    (before, open, chosen.get(), t.query(Button, label="Appearance: Dark") is Some(_), t.all(Menu).length()),
    (Some(false), (Some(true), ["Light", "Dark", "System"]), 1, true, 0),
  )
}

///|
test "a dialog takes all input over the page while it is open; Escape shuts it, and so does a press on its scrim" {
  let open = @signals.signal(false)
  let t = floating_case(fn(p, layer) {
    button_node(p, fn() { "Delete" }, fn() { open.set(true) }, hierarchy=Destructive) |> ignore
    dialog_node(layer, open, fn() { "Delete this project?" }, actions=fn(f) {
      button_node(f, fn() { "Cancel" }, fn() { open.set(false) }, hierarchy=SecondaryGray, size=Sm) |> ignore
    })
  })
  t.act(Button, Activate, label="Delete")
  t.run_for(floating_ms)
  let shown = (t.all(Dialog, label="Delete this project?").length(), @headless.overlays_open(@ui.view_tree().unwrap()))
  t.key(@ui.key_escape)
  t.run_for(floating_ms)
  let escaped = (open.get(), t.all(Dialog, label="Delete this project?").length(), @headless.overlays_open(@ui.view_tree().unwrap()))
  t.act(Button, Activate, label="Delete")
  t.run_for(floating_ms)
  let reopened = @headless.overlays_open(@ui.view_tree().unwrap())
  t.tap(10.0, 10.0)
  t.run_for(floating_ms)
  assert_eq(
    (shown, escaped, reopened, open.get(), @headless.overlays_open(@ui.view_tree().unwrap())),
    ((1, 1), (false, 0, 0), 1, false, 0),
  )
}

///|
test "a tooltip shows as the keyboard's focus comes on its control, and goes as it leaves" {
  let t = floating_case(fn(p, layer) {
    let a = button_node(p, fn() { "Save" }, fn() {  })
    tooltip_node(layer, a, fn() { "Save the draft" })
    button_node(p, fn() { "Next" }, fn() {  }) |> ignore
  })
  t.tab()
  t.run_for(floating_ms)
  let shown = t.all(Tooltip, label="Save the draft").length()
  t.tab()
  t.run_for(floating_ms)
  assert_eq((shown, t.all(Tooltip, label="Save the draft").length()), (1, 0))
}

///|
test "a toast stays its time and is gone after it; its Dismiss takes it away before" {
  let toaster = Toaster::new()
  let t = floating_case(fn(p, layer) {
    button_node(p, fn() { "Save" }, fn() { toaster.show("Changes saved", intent=Success) }) |> ignore
    button_node(p, fn() { "Fail" }, fn() { toaster.show("Upload failed", intent=Error) }) |> ignore
    toaster_node(layer, toaster)
  })
  t.act(Button, Activate, label="Save")
  t.run_for(floating_ms)
  let shown = t.all(Status, label="Changes saved").length()
  t.run_for(toast_stays)
  let after = t.all(Status, label="Changes saved").length()
  t.act(Button, Activate, label="Fail")
  t.run_for(floating_ms)
  t.act(Button, Activate, label="Dismiss")
  t.run_for(floating_ms)
  assert_eq((shown, after, t.all(Status, label="Upload failed").length()), (1, 0, 0))
}

///|
test "a slider steps by a screen reader's Increment and Decrement and by the arrow keys, kept in its range" {
  let value = @signals.signal(98.0)
  let t = floating_case(fn(p, _) {
    p.box(fn(b) {
      b.width(Is(Some(320.0))) |> ignore
      slider_node(b, value, fn() { "Volume" }) |> ignore
    })
    |> ignore
  })
  t.act(Slider, Increment, label="Volume")
  t.act(Slider, Increment, label="Volume")
  t.act(Slider, Increment, label="Volume")
  let top = value.get()
  t.tab()
  t.key(@ui.key_code_left)
  t.key(@ui.key_code_home)
  t.key(@ui.key_code_right)
  assert_eq((top, value.get(), t.get(Slider, label="Volume").range), (100.0, 1.0, Some((0.0, 1.0, 100.0))))
}

///|
test "a collapse opens and shuts what it holds as its title is activated, read out expanded or not" {
  let open = @signals.signal(false)
  let t = floating_case(fn(p, _) {
    collapse_node(p, fn() { "Details" }, open, fn(b) {
      b.words(Is("Hidden words"), look=words_in(type_small)) |> ignore
    })
    |> ignore
  })
  let shut = (t.get(Button, label="Details").expanded, t.words().iter().any(fn(w) { w.0 == "Hidden words" }))
  t.act(Button, Activate, label="Details")
  t.run_for(floating_ms)
  assert_eq((shut, t.get(Button, label="Details").expanded, t.words().iter().any(fn(w) { w.0 == "Hidden words" })), ((Some(false), false), Some(true), true))
}

///|
test "a button group and a radio group choose as one of theirs is activated, each read out a group of radios" {
  let (segment, plan) = (@signals.signal(0), @signals.signal(0))
  let t = floating_case(fn(p, _) {
    button_group_node(p, ["Day", "Week", "Month"], segment) |> ignore
    radio_group_node(p, [("Basic", ""), ("Business", "")], plan, label="Plan") |> ignore
  })
  t.act(Radio, Activate, label="Month")
  t.act(Radio, Activate, label="Business")
  assert_eq(
    (segment.get(), t.get(Radio, label="Month").check, plan.get(), t.get(Radio, label="Business").check),
    (2, Some(On), 1, Some(On)),
  )
}

///|
test "every one of these parts, its floating ones open, light and dark, holds to mbui's audit" {
  let faults = []
  for dark in [false, true] {
    let toaster = Toaster::new()
    let t = floating_case(dark~, fn(p, layer) {
      p.box(fn(r) {
        r.row(Is(true)).gap(Is(24.0)).lines_up(Is(Some(Start))) |> ignore
        radio_group_node(r, [("Basic", "Up to 10 users.")], @signals.signal(0), label="Plan") |> ignore
        check_group_node(r, [("Email", "")], @signals.signal([true]), label="Notify") |> ignore
        r.box(fn(s) {
          s.width(Is(Some(200.0))) |> ignore
          slider_node(s, @signals.signal(40.0), fn() { "Volume" }, width=200.0) |> ignore
        })
        |> ignore
        // (the dot on its line: in a slot a line high, beside the choices' first lines)
        r.box(fn(i) {
          i.height(Is(Some(20.0))).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
          indicator_node(i, Good, "Online") |> ignore
        })
        |> ignore
      })
      |> ignore
      collapse_node(p, fn() { "Details" }, @signals.signal(true), fn(b) {
        b.words(Is("More"), look=words_in(type_small)).ink(By(fn() { colors().text_tertiary })) |> ignore
      })
      |> ignore
      // (last, the menu opening into the room under it)
      p.box(fn(r) {
        r.row(Is(true)).gap(Is(12.0)).lines_up(Is(Some(Start))) |> ignore
        let a = button_node(r, fn() { "Options" }, fn() {  }, hierarchy=SecondaryGray)
        menu_node(layer, a, @signals.signal(true), fn() { [menu_item("Profile", fn() {  }, checked=true), menu_item("Log out", fn() {  }, danger=true, divided=true)] })
        let b = button_node(r, fn() { "Help" }, fn() {  }, hierarchy=TertiaryGray)
        tooltip_node(layer, b, fn() { "Get help" }, shown=fn() { true })
        button_group_node(r, ["Day", "Week"], @signals.signal(0)) |> ignore
      })
      |> ignore
      toaster_node(layer, toaster)
      toaster.show("Changes saved", intent=Success)
    })
    t.run_for(floating_ms)
    for f in t.audit() {
      faults.push((dark, f))
    }
  }
  assert_eq(faults, [])
}

///|
/// What of Comma's own design falls short of mbui's contrast rule (4.5:1 for words): a dialog's description, xs in the
/// quaternary's on popup-primary, 3.86:1 in the light (Cue's dialog/styles.ts). Drawn as Comma says; held here so it is
/// seen, not mended in this library alone.
let comma_contrast_known : Array[String] = ["\"It cannot be undone.\""]

///|
test "a dialog open, light and dark, holds to mbui's audit but for Comma's own description's contrast" {
  let (faults, known) = ([], [])
  for dark in [false, true] {
    let t = floating_case(dark~, fn(p, layer) {
      button_node(p, fn() { "Delete" }, fn() {  }, hierarchy=Destructive) |> ignore
      dialog_node(layer, @signals.signal(true), fn() { "Delete this project?" }, description=fn() { "It cannot be undone." }, actions=fn(f) {
        button_node(f, fn() { "Cancel" }, fn() {  }, hierarchy=SecondaryGray, size=Sm) |> ignore
        button_node(f, fn() { "Delete" }, fn() {  }, hierarchy=Destructive, size=Sm) |> ignore
      })
    })
    t.run_for(floating_ms)
    for f in t.audit() {
      if comma_contrast_known.iter().any(fn(k) { f.contains(k) && f.contains("under 4.5") }) {
        known.push(dark)
      } else {
        faults.push((dark, f))
      }
    }
  }
  assert_eq((faults, known), ([], [false]))
}

///|
test "a status indicator shows the chosen status, read out as the checked one of four radios, and chooses another as it is activated" {
  let chosen = @signals.signal(InProgress)
  let t = floating_case(fn(p, _) { status_node(p, chosen) |> ignore })
  let before = t.all(Radio).filter(fn(r) { r.check == Some(On) }).map(fn(r) { r.label })
  t.act(Radio, Activate, label="Done")
  t.run_for(floating_ms)
  assert_eq((before, chosen.get(), t.get(Radio, label="Done").check, t.all(Radio).length()), (["In progress"], Done, Some(On), 4))
}

///|
test "a scroll area fades only where what it holds goes on: under its foot at its top, over both between, over its top at its foot" {
  assert_eq(
    (edge_fades(0.0, 300.0), edge_fades(10.0, 300.0), edge_fades(150.0, 300.0), edge_fades(300.0, 300.0), edge_fades(0.0, 0.0)),
    ((0.0, 24.0), (10.0, 24.0), (24.0, 24.0), (24.0, 0.0), (0.0, 0.0)),
  )
}

///|
test "a menu's rows are mbui's headless menu's: read out as its items, ↑ from the first round to the last, End and Home to the ends, a row pressed doing it and shutting the menu" {
  let open = @signals.signal(false)
  let done = Ref([])
  let t = floating_case(fn(p, layer) {
    let a = button_node(p, fn() { "Options" }, fn() { open.set(true) }, hierarchy=SecondaryGray)
    menu_node(layer, a, open, fn() {
      [
        menu_item("Profile", fn() { done.val.push("Profile") }),
        menu_item("Settings", fn() { done.val.push("Settings") }),
        menu_item("Log out", fn() { done.val.push("Log out") }, danger=true),
      ]
    })
  })
  t.act(Button, Activate, label="Options")
  t.run_for(floating_ms)
  let items = t.all(MenuItem).map(fn(s) { s.label })
  t.key(@ui.key_code_down)
  t.key(@ui.key_code_up)
  let round = t.focused().map(fn(s) { s.label })
  t.key(@ui.key_code_home)
  let home = t.focused().map(fn(s) { s.label })
  t.key(@ui.key_code_end)
  let end = t.focused().map(fn(s) { s.label })
  t.act(MenuItem, Activate, label="Settings")
  t.run_for(floating_ms)
  assert_eq(
    (items, round, home, end, done.val, open.get()),
    (["Profile", "Settings", "Log out"], Some("Log out"), Some("Profile"), Some("Log out"), ["Settings"], false),
  )
}

///|
test "a toast's time stops while the pointer is over it, going on from what it had left once it leaves" {
  let toaster = Toaster::new()
  let t = floating_case(fn(p, layer) {
    button_node(p, fn() { "Save" }, fn() { toaster.show("Changes saved", intent=Success) }) |> ignore
    toaster_node(layer, toaster)
  })
  t.act(Button, Activate, label="Save")
  t.run_for(floating_ms)
  t.run_for(toast_stays / 4.0)
  let (x, y, w, h) = t.get(Status, label="Changes saved").rect
  t.move_to(x + w / 2.0, y + h / 2.0)
  t.run_for(toast_stays)
  let held = t.all(Status, label="Changes saved").length()
  t.move_to(10.0, 690.0)
  t.run_for(toast_stays / 2.0)
  let left = t.all(Status, label="Changes saved").length()
  t.run_for(toast_stays / 2.0)
  assert_eq((held, left, t.all(Status, label="Changes saved").length()), (1, 1, 0))
}

///|
test "dialog_node: releasing modal on first exit frame lets clicks pass through mid-exit" {
  let open = @signals.signal(false)
  let under_clicks = Ref(0)
  let t = floating_case(fn(p, layer) {
    button_node(p, fn() { "Open" }, fn() { open.set(true) }) |> ignore
    button_node(p, fn() { "Underneath" }, fn() { under_clicks.val = under_clicks.val + 1 }) |> ignore
    dialog_node(layer, open, fn() { "Confirm action" }, actions=fn(f) {
      button_node(f, fn() { "Cancel" }, fn() { open.set(false) }, hierarchy=SecondaryGray, size=Sm) |> ignore
    })
  })
  t.act(Button, Activate, label="Open")
  t.run_for(floating_ms)
  assert_eq(t.all(Dialog, label="Confirm action").length(), 1)
  // Close dialog and advance only half of ms_dialog_exit (dialog still fading out)
  open.set(false)
  t.run_for(ms_dialog_exit / 2.0)
  let (bx, by, bw, bh) = t.get(Button, label="Underneath").rect
  t.tap(bx + bw / 2.0, by + bh / 2.0)
  t.draw()
  assert_eq(under_clicks.val, 1, msg="click during dialog exit should pass through immediately")
}

///|
test "dropdown_node and status_node keep exact heights at 1.0x and grow cleanly at 2.0x font scale with zero new audit faults" {
  let t = floating_case(fn(p, layer) {
    p.box(fn(b) {
      b.width(Is(Some(280.0))) |> ignore
      dropdown_node(b, layer, ["Light", "Dark", "System"], @signals.signal(1), label="Appearance") |> ignore
    })
    |> ignore
    status_node(p, @signals.signal(InProgress)) |> ignore
  })
  t.run_for(floating_ms)
  let dd_h1 = t.get(Button, label="Appearance: Dark").rect.3
  let st_chosen_h1 = t.get(Radio, label="In progress").rect.3
  let st_other_h1 = t.get(Radio, label="Done").rect.3
  assert_eq((dd_h1, st_chosen_h1, st_other_h1), (40.0, 24.0, 24.0))
  // (Comma's dropdown trigger (14/12) and status pill (4/8) have intentional asymmetric horizontal padding; check no other faults)
  let faults1 = t.audit().filter(fn(f) { !f.has_prefix("rule 4:") })
  assert_eq(faults1, [])
  t.set_font_scale(2.0)
  t.draw()
  t.run_for(floating_ms)
  let dd_h2 = t.get(Button, label="Appearance: Dark").rect.3
  let st_chosen_h2 = t.get(Radio, label="In progress").rect.3
  assert_true(dd_h2 > 40.0 && st_chosen_h2 > 24.0, msg="2.0x heights: dropdown=\{dd_h2}, status=\{st_chosen_h2}")
  // (at 2.0x the chosen status pill grows with text while unchosen dot radios stay 24x24 circles, triggering the row-height rule)
  let faults2 = t.audit().filter(fn(f) { !f.has_prefix("rule 4:") && !f.has_prefix("height:") })
  assert_eq(faults2, [])
}

///|
test "dialog_node footer wraps in reverse at 2.0x font scale without overflowing the dialog" {
  let t = floating_case(fn(p, layer) {
    button_node(p, fn() { "Open" }, fn() {  }, hierarchy=Destructive) |> ignore
    dialog_node(
      layer,
      @signals.signal(true),
      fn() { "Delete this project?" },
      description=fn() { "It cannot be undone." },
      width=300.0,
      actions=fn(f) {
        button_node(f, fn() { "Cancel" }, fn() {  }, hierarchy=SecondaryGray, size=Sm) |> ignore
        button_node(f, fn() { "Delete this project" }, fn() {  }, hierarchy=Destructive, size=Sm) |> ignore
      },
    )
  })
  t.set_font_scale(2.0)
  t.draw()
  t.run_for(floating_ms)
  let (dx, _, dw, _) = t.get(Dialog, label="Delete this project?").rect
  let (cx, cy, cw, _) = t.get(Button, label="Cancel").rect
  let (px, py, pw, _) = t.get(Button, label="Delete this project").rect
  assert_true(cy > py, msg="wrap_reverse puts earlier line below wrapped line: cancel_y=\{cy}, primary_y=\{py}")
  assert_true(cx + cw <= dx + dw && px + pw <= dx + dw, msg="buttons stay within dialog right edge")
  let faults = []
  for f in t.audit() {
    if !comma_contrast_known.iter().any(fn(k) { f.contains(k) && f.contains("under 4.5") }) {
      faults.push(f)
    }
  }
  assert_eq(faults, [])
}

///|
test "dialog_node hides from the semantics tree immediately on close before exit animation finishes" {
  let open = @signals.signal(false)
  let t = floating_case(fn(p, layer) {
    button_node(p, fn() { "Open" }, fn() { open.set(true) }) |> ignore
    dialog_node(layer, open, fn() { "Confirm hide" }, actions=fn(f) {
      button_node(f, fn() { "Cancel" }, fn() { open.set(false) }, hierarchy=SecondaryGray, size=Sm) |> ignore
    })
  })
  t.act(Button, Activate, label="Open")
  t.run_for(floating_ms)
  assert_eq(t.all(Dialog, label="Confirm hide").length(), 1)
  open.set(false)
  t.draw()
  let at_once = t.all(Dialog, label="Confirm hide").length()
  t.run_for(ms_dialog_exit / 2.0)
  let mid_exit = t.all(Dialog, label="Confirm hide").length()
  assert_eq((at_once, mid_exit), (0, 0))
}

///|
test "radio_group_node and check_group_node align controls with first-line labels at 1.0x and 2.0x with zero audit faults" {
  let t = floating_case(fn(p, _) {
    p.box(fn(r) {
      r.row(Is(true)).gap(Is(24.0)).lines_up(Is(Some(Start))) |> ignore
      r.box(fn(b) {
        b.width(Is(Some(240.0))) |> ignore
        radio_group_node(
          b,
          [("Basic plan", "Up to 10 users."), ("Business plan", "Up to 20 users.")],
          @signals.signal(0),
          label="Plan",
        )
        |> ignore
      })
      |> ignore
      r.box(fn(b) {
        b.width(Is(Some(240.0))) |> ignore
        check_group_node(
          b,
          [("Email", "Weekly digest."), ("Push", "")],
          @signals.signal([true, false]),
          label="Notify",
        )
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  fn check_aligned(scale : Double) -> Unit raise {
    let words = t.words()
    let pairs : Array[(@view.Role, String)] = [
      (Radio, "Basic plan"),
      (Radio, "Business plan"),
      (Checkbox, "Email"),
      (Checkbox, "Push"),
    ]
    for p in pairs {
      let (role, name) = p
      let (_, cy, _, ch) = t.get(role, label=name).rect
      let ctrl_mid = cy + ch / 2.0
      let mut label_mid : Double? = None
      for w in words {
        if w.0 == name {
          label_mid = Some(w.2 + w.4 / 2.0)
          break
        }
      }
      match label_mid {
        Some(lm) =>
          assert_true(
            (ctrl_mid - lm).abs() < 1.0,
            msg="scale=\{scale} \{name}: ctrl_mid=\{ctrl_mid} vs label_mid=\{lm}",
          )
        None => assert_true(false, msg="label \{name} not found in words")
      }
    }
    assert_eq(t.audit(), [])
  }
  t.run_for(floating_ms)
  check_aligned(1.0)
  t.set_font_scale(2.0)
  t.draw()
  t.run_for(floating_ms)
  check_aligned(2.0)
}

///|
test "menu_node hides from the semantics tree immediately on close before exit animation finishes" {
  let open = @signals.signal(false)
  let t = floating_case(fn(p, layer) {
    let a = button_node(p, fn() { "Options" }, fn() { open.set(true) }, hierarchy=SecondaryGray)
    menu_node(layer, a, open, fn() {
      [menu_item("Profile", fn() {  }), menu_item("Settings", fn() {  })]
    })
  })
  t.act(Button, Activate, label="Options")
  t.run_for(floating_ms)
  assert_eq(t.all(Menu, label="Menu").length(), 1)
  open.set(false)
  t.draw()
  let at_once = t.all(Menu, label="Menu").length()
  t.run_for(ms_menu_exit / 2.0)
  let mid_exit = t.all(Menu, label="Menu").length()
  assert_eq((at_once, mid_exit), (0, 0))
}

///|
test "narrow viewports keep toast_card, popup_node, menu_node, and slider_node within bounds with zero audit faults" {
  // 1. toast_card in 390x700 (24pt padding on each side => 342pt available, card default 356pt)
  let toaster = Toaster::new()
  let t_toast = floating_case(w=390.0, h=700.0, fn(p, layer) {
    button_node(p, fn() { "Notify" }, fn() {
      toaster.show(
        "Workspace synchronization completed with warnings",
        description="design-system-tokens.fig is larger than 100 MB and was skipped.",
        intent=Warning,
      )
    })
    |> ignore
    toaster_node(layer, toaster)
  })
  t_toast.act(Button, Activate, label="Notify")
  t_toast.run_for(floating_ms)
  let (tx, _, tw, _) = t_toast.get(Status, label="Workspace synchronization completed with warnings").rect
  assert_true(
    tx >= 0.0 && tx + tw <= 390.0 && tw <= 342.0,
    msg="toast overflow in 390px window: x=\{tx}, w=\{tw}",
  )
  // (Comma's toast_text_secondary is #7f8286 on #ffffff, 3.86:1, same known token as dialog description)
  let toast_faults = t_toast.audit().filter(fn(f) { !f.contains("3.86:1, under 4.5") })
  assert_eq(toast_faults, [])

  // 2. popup_node (default width 360pt) in 340x700
  let t_popup = floating_case(w=340.0, h=700.0, fn(p, layer) {
    let a = button_node(p, fn() { "Share" }, fn() {  }, hierarchy=SecondaryGray)
    popup_node(layer, a, @signals.signal(true), label="Share popup", fn(body) {
      body.gap(Is(space_md)) |> ignore
      body.box(fn(w) {
        w
        .words(Is("Share this workspace with collaborators"), look=words_in(type_regular, weight=weight_semibold, wrap=true))
        .ink(By(fn() { colors().text_primary }))
        |> ignore
      })
      |> ignore
      input_node(body, @ui.Field::new(text="comma.surf/w/design"), label="Link") |> ignore
    })
  })
  t_popup.run_for(floating_ms)
  let (px, _, pw, _) = t_popup.get(Dialog, label="Share popup").rect
  assert_true(
    px >= 0.0 && px + pw <= 340.0,
    msg="popup overflow in 340px window: x=\{px}, w=\{pw}",
  )
  assert_eq(t_popup.audit(), [])

  // 3. menu_node (width 360pt) in 340x700
  let t_menu = floating_case(w=340.0, h=700.0, fn(p, layer) {
    let a = button_node(p, fn() { "Options" }, fn() {  }, hierarchy=SecondaryGray)
    menu_node(
      layer,
      a,
      @signals.signal(true),
      width=360.0,
      fn() { [menu_item("Profile", fn() {  }), menu_item("Settings", fn() {  }, checked=true)] },
    )
  })
  t_menu.run_for(floating_ms)
  let (mx, _, mw, _) = t_menu.get(Menu, label="Menu").rect
  assert_true(
    mx >= 0.0 && mx + mw <= 340.0,
    msg="menu overflow in 340px window: x=\{mx}, w=\{mw}",
  )
  assert_eq(t_menu.audit(), [])

  // 4. slider_node (default width 320pt) inside a 240pt container
  let vol = @signals.signal(40.0)
  let t_slider = floating_case(w=390.0, h=700.0, fn(p, _) {
    p.box(fn(box) {
      box.width(Is(Some(240.0))).says(Is(Some(@view.said(Group, label="Slider box")))) |> ignore
      slider_node(box, vol, fn() { "Volume" }) |> ignore
    })
    |> ignore
  })
  t_slider.run_for(floating_ms)
  let (bx, _, bw, _) = t_slider.get(Group, label="Slider box").rect
  let (sx, sy, sw, sh) = t_slider.get(Slider, label="Volume").rect
  assert_true(
    sx >= bx && sx + sw <= bx + bw && sw <= 240.0,
    msg="slider overflow in 240px container: box=(\{bx},\{bw}), slider=(\{sx},\{sw})",
  )
  // verify drag still works when clamped
  t_slider.drag(sx + sw * 0.4, sy + sh / 2.0, sx + sw * 0.8, sy + sh / 2.0)
  t_slider.draw()
  assert_true(vol.get() > 50.0, msg="slider drag in narrow container should update value: vol=\{vol.get()}")
  assert_eq(t_slider.audit(), [])
}
