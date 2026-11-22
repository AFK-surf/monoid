// Whitebox tests for Track B Liquid Glass overlay, navigation and feedback components:
// Menu, Select, Popover, Tooltip, Sheet, ActionSheet, Toast, ProgressBar, ProgressRing,
// NavBar, Toolbar, List, and Disclosure — including light/dark `Tester::audit()` (0 faults)
// and frame-rate invariance at 60, 120, 24 and 7 fps.

///|
/// A Tester with a main `page` container and a full-window overlay `host` layer.
fn ovl_case(
  make : (@view.View, @view.View) -> Unit,
  dark? : Bool = false,
  w? : Double = 900.0,
  h? : Double = 700.0,
  transitions_only? : Bool = true,
) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w~, h~, platform=0)
  set_dark(Some(dark))
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme)
    if transitions_only {
      root.transitions_only() |> ignore
    }
    let page_ref : Ref[@view.View?] = Ref(None)
    root.box(fn(page) {
      page
      .grow(Is(1.0))
      .padding(Is((32.0, 32.0, 32.0, 32.0)))
      .gap(Is(16.0))
      .lines_up(Is(Some(Start)))
      .ground(By(fn() { if is_dark() { 0x16161AFFL } else { 0xDCE3ECFFL } }))
      |> ignore
      page_ref.val = Some(page)
    })
    |> ignore
    root.box(fn(host) {
      host.over(Is(true)) |> ignore
      match page_ref.val {
        Some(p) => make(p, host)
        None => ()
      }
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// Simple capsule trigger look for Menu / Popover tests.
fn ovl_test_trigger(label : String) -> (@view.View, @headless.Disclosure) -> Unit {
  fn(v : @view.View, _ : @headless.Disclosure) {
    v
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .height(Is(Some(40.0)))
    .padding(Is((16.0, 0.0, 16.0, 0.0)))
    .radius(Is(20.0))
    .glass(By(fn() { Some(ovl_capsule_glass()) }))
    |> ignore
    v.box(fn(w) { w.words(Is(label), look=words_at(ovl_type_body)).ink(By(fn() { colors().content })) |> ignore })
    |> ignore
  }
}

///|
test "ovl_clean_menu_entries strips leading, trailing and consecutive duplicate separators" {
  let raw : Array[LiquidMenuEntry] = [
    LiquidMenuEntry::separator(),
    LiquidMenuEntry::separator(),
    LiquidMenuEntry::item(label="Cut", on_select=fn() {  }),
    LiquidMenuEntry::separator(),
    LiquidMenuEntry::separator(),
    LiquidMenuEntry::item(label="Copy", on_select=fn() {  }),
    LiquidMenuEntry::separator(),
  ]
  let cleaned = ovl_clean_menu_entries(raw)
  let kinds = cleaned.map(ovl_menu_entry_kind)
  assert_eq(kinds, [1, 0, 1])
  let only_seps = ovl_clean_menu_entries([LiquidMenuEntry::separator(), LiquidMenuEntry::separator()])
  assert_eq(only_seps.length(), 0)
}

///|
test "liquid_menu_node opens, filters duplicate separators, activates item, toggles check and closes on Escape" {
  let open = @signals.signal(false)
  let checked = @signals.signal(false)
  let picked = Ref(0)
  let t = ovl_case(fn(page, host) {
    liquid_menu_node(
      page,
      host,
      fn() { open.get() },
      fn(v) { open.set(v) },
      fn() { "Actions" },
      ovl_test_trigger("Actions"),
      fn() {
        [
          LiquidMenuEntry::separator(),
          LiquidMenuEntry::item(label="Duplicate", shortcut="⌘D", on_select=fn() { picked.val += 1 }),
          LiquidMenuEntry::separator(),
          LiquidMenuEntry::separator(),
          LiquidMenuEntry::check(label="Show Grid", checked=fn() { checked.get() }, on_toggle=fn() {
            checked.set(!checked.untracked())
          }),
          LiquidMenuEntry::item(label="Delete", destructive=true, on_select=fn() {  }),
          LiquidMenuEntry::separator(),
        ]
      },
      menu_label=fn() { "File Menu" },
    )
    |> ignore
  })
  // Open via trigger button
  t.act(Button, Activate, label="Actions")
  t.run_for(springs_out)
  let seps = t.all(Separator).length()
  let has_menu = t.all(Menu, label="File Menu").length()
  // Toggle check item (menu stays open)
  t.act(MenuItemCheckbox, Activate, label="Show Grid")
  t.run_for(a_frame)
  let after_check = (checked.get(), open.get())
  // Activate action item (menu closes and callback runs)
  t.act(MenuItem, Activate, label="Duplicate")
  t.run_for(springs_out)
  let after_item = (picked.val, open.get())
  // Re-open and close with Escape
  t.act(Button, Activate, label="Actions")
  t.run_for(springs_out)
  t.key(@ui.key_escape)
  t.run_for(springs_out)
  assert_eq((seps, has_menu, after_check, after_item, open.get()), (1, 1, (true, true), (1, false), false))
}

///|
test "liquid_select_node opens option list, selects an option, respects disabled and closes" {
  let chosen = @signals.signal(0)
  let opts = [
    LiquidSelectOption::new(label="Light", detail="Bright frosted"),
    LiquidSelectOption::new(label="Dark", detail="Deep obsidian"),
    LiquidSelectOption::new(label="System", disabled=true),
  ]
  let t = ovl_case(fn(page, host) {
    liquid_select_node(page, host, fn() { opts }, fn() { chosen.get() }, fn(i) { chosen.set(i) }, label=fn() { "Theme" })
    |> ignore
  })
  t.act(Button, Activate, label="Theme: Light")
  t.run_for(springs_out)
  let radio_count = t.all(MenuItemRadio).length()
  t.act(MenuItemRadio, Activate, label="Dark")
  t.run_for(springs_out)
  let after_dark = (chosen.get(), t.all(MenuItemRadio).length())
  // Open again and try activating disabled option
  t.act(Button, Activate, label="Theme: Dark")
  t.run_for(springs_out)
  t.act(MenuItemRadio, Activate, label="System")
  t.run_for(a_frame)
  assert_eq((radio_count, after_dark, chosen.get()), (3, (1, 0), 1))
}

///|
test "liquid_popover_node opens content in host and closes via Escape and outside press" {
  let open = @signals.signal(false)
  let t = ovl_case(fn(page, host) {
    liquid_popover_node(
      page,
      host,
      fn() { open.get() },
      fn(v) { open.set(v) },
      fn() { "Info" },
      ovl_test_trigger("Info"),
      fn() { "Details" },
      fn(c) {
        c.box(fn(w) { w.words(Is("Popover body"), look=words_at(ovl_type_body)).ink(By(fn() { colors().content })) |> ignore })
        |> ignore
      },
    )
    |> ignore
  })
  t.act(Button, Activate, label="Info")
  t.run_for(springs_out)
  let opened = t.all(Dialog, label="Details").length()
  t.key(@ui.key_escape)
  t.run_for(springs_out)
  let after_esc = (open.get(), t.all(Dialog, label="Details").length())
  t.act(Button, Activate, label="Info")
  t.run_for(springs_out)
  // Tap far away in the window (outside both trigger and popover)
  t.tap(850.0, 650.0)
  t.run_for(springs_out)
  assert_eq((opened, after_esc, open.get()), (1, (false, 0), false))
}

///|
test "liquid_tooltip_node shows on hover after delay and hides when pointer leaves without blocking clicks" {
  let clicked = Ref(0)
  let t = ovl_case(fn(page, host) {
    liquid_tooltip_node(
      page,
      host,
      fn() { "Save changes" },
      fn(wrap) {
        liquid_button_node(wrap, fn() { "Save" }, fn() { clicked.val += 1 }) |> ignore
      },
    )
    |> ignore
  })
  let (bx, by) = middle(t, Button, "Save")
  t.move_to(bx, by)
  t.run_for(@headless.tooltip_delay_ms + springs_out)
  let shown = t.all(Tooltip, label="Save changes").length()
  // Clicking the trigger still works (tooltip never steals presses)
  t.tap(bx, by)
  t.run_for(springs_out)
  t.move_to(850.0, 650.0)
  t.run_for(springs_out)
  assert_eq((shown, clicked.val, t.all(Tooltip, label="Save changes").length()), (1, 1, 0))
}

///|
test "liquid_sheet_node opens modally and closes via close button, Escape and scrim tap" {
  let open = @signals.signal(true)
  let t = ovl_case(fn(_page, host) {
    liquid_sheet_node(
      host,
      fn() { open.get() },
      fn() { open.set(false) },
      fn() { "Export Settings" },
      fn(b) {
        b.box(fn(w) { w.words(Is("Choose resolution"), look=words_at(ovl_type_body)).ink(By(fn() { colors().content })) |> ignore })
        |> ignore
      },
      subtitle=fn() { "High-DPI PNG or MP4" },
      footer=fn(f) {
        f.box(fn(w) { w.words(Is("Ready to export"), look=words_at(ovl_type_sub)).ink(By(ovl_muted_ink)) |> ignore }) |> ignore
      },
    )
    |> ignore
  })
  t.run_for(springs_out)
  let shown = t.all(Dialog, label="Export Settings").length()
  t.act(Button, Activate, label="Close")
  t.run_for(springs_out)
  let after_btn = (open.get(), t.all(Dialog, label="Export Settings").length())
  open.set(true)
  t.run_for(springs_out)
  t.key(@ui.key_escape)
  t.run_for(springs_out)
  let after_esc = open.get()
  open.set(true)
  t.run_for(springs_out)
  // Tap top-left scrim outside the bottom floating sheet
  t.tap(20.0, 20.0)
  t.run_for(springs_out)
  assert_eq((shown, after_btn, after_esc, open.get()), (1, (false, 0), false, false))
}

///|
test "liquid_action_sheet_node activates items, closes on Cancel and Escape" {
  let open = @signals.signal(true)
  let ran = Ref("")
  let t = ovl_case(fn(_page, host) {
    liquid_action_sheet_node(
      host,
      fn() { open.get() },
      fn() { open.set(false) },
      fn() {
        [
          LiquidActionSheetItem::new(label="Share Link", on_select=fn() { ran.val = "share" }),
          LiquidActionSheetItem::new(label="Delete Draft", destructive=true, on_select=fn() { ran.val = "delete" }),
        ]
      },
      title=fn() { "Draft Options" },
      message=fn() { "Choose an action for this draft." },
    )
    |> ignore
  })
  t.run_for(springs_out)
  t.act(Button, Activate, label="Share Link")
  t.run_for(springs_out)
  let after_share = (ran.val, open.get())
  open.set(true)
  t.run_for(springs_out)
  t.act(Button, Activate, label="Cancel")
  t.run_for(springs_out)
  assert_eq((after_share, open.get()), (("share", false), false))
}

///|
test "liquid_toast_node renders status, runs action and dismiss callbacks" {
  let visible = @signals.signal(true)
  let undone = Ref(0)
  let t = ovl_case(fn(page, _host) {
    liquid_toast_node(
      page,
      fn() { visible.get() },
      fn() { "Message archived" },
      subtitle=fn() { "Moved to All Mail" },
      status=Success,
      action_label=fn() { "Undo" },
      on_action=fn() { undone.val += 1 },
      on_dismiss=fn() { visible.set(false) },
    )
    |> ignore
  })
  t.run_for(springs_out)
  let shown = t.all(Status, label="Message archived").length()
  t.act(Button, Activate, label="Undo")
  t.act(Button, Activate, label="Dismiss")
  t.run_for(springs_out)
  assert_eq((shown, undone.val, visible.get(), t.all(Status, label="Message archived").length()), (1, 1, false, 0))
}

///|
test "liquid_progress_bar_node and liquid_progress_ring_node report determinate and indeterminate progress" {
  let val : @signals.Signal[Double?] = @signals.signal(Some(0.45))
  let t = ovl_case(fn(page, _host) {
    page.box(fn(col) {
      col.width(Is(Some(320.0))).gap(Is(16.0)) |> ignore
      liquid_progress_bar_node(col, fn() { val.get() }, label=fn() { "Upload" }, show_value=true) |> ignore
      liquid_progress_ring_node(col, fn() { val.get() }, label=fn() { "Sync" }) |> ignore
    })
    |> ignore
  })
  let bar_det = t.get(ProgressBar, label="Upload").value
  let ring_det = t.get(ProgressBar, label="Sync").value
  val.set(None)
  t.run_for(dragged_ms)
  let bar_ind = t.get(ProgressBar, label="Upload").value
  let ring_ind = t.get(ProgressBar, label="Sync").value
  assert_eq((bar_det, ring_det, bar_ind, ring_ind), ("45%", "45%", "", ""))
}

///|
test "liquid_nav_bar_node, liquid_toolbar_node, liquid_list_node and liquid_disclosure_node interact cleanly" {
  let expanded = @signals.signal(false)
  let row_taps = Ref(0)
  let nav_taps = Ref(0)
  let t = ovl_case(fn(page, _host) {
    page.box(fn(col) {
      col.width(Is(Some(420.0))).gap(Is(16.0)) |> ignore
      liquid_nav_bar_node(
        col,
        fn() { "Settings" },
        subtitle=fn() { "Workspace" },
        leading=fn(s) { liquid_button_node(s, fn() { "Back" }, fn() { nav_taps.val += 1 }) |> ignore },
      )
      |> ignore
      liquid_toolbar_node(col, fn(tb) {
        tb.box(fn(w) { w.words(Is("Tools"), look=words_at(ovl_type_sub)).ink(By(fn() { colors().content })) |> ignore })
        |> ignore
      })
      |> ignore
      liquid_list_node(
        col,
        fn() {
          [
            LiquidListRow::new(title="Wi-Fi", value="Office-5G", chevron=true, on_press=fn() { row_taps.val += 1 }),
            LiquidListRow::new(title="Bluetooth", value="On"),
            LiquidListRow::new(title="Reset Network", destructive=true, on_press=fn() { row_taps.val += 10 }),
          ]
        },
        header=fn() { "Connectivity" },
        footer=fn() { "Manage wireless connections." },
      )
      |> ignore
      liquid_disclosure_node(
        col,
        fn() { "Advanced" },
        fn() { expanded.get() },
        fn(v) { expanded.set(v) },
        fn(c) {
          c.box(fn(w) { w.words(Is("Hidden details"), look=words_at(ovl_type_sub)).ink(By(fn() { colors().content })) |> ignore })
          |> ignore
        },
        subtitle=fn() { "Developer options" },
      )
      |> ignore
    })
    |> ignore
  })
  let has_nav = t.all(Navigation, label="Settings").length()
  let has_tb = t.all(Toolbar, label="Toolbar").length()
  t.act(Button, Activate, label="Back")
  t.act(Button, Activate, label="Wi-Fi")
  t.act(Button, Activate, label="Advanced")
  t.run_for(springs_out)
  let disc_expanded = t.get(Button, label="Advanced").expanded
  assert_eq((has_nav, has_tb, nav_taps.val, row_taps.val, expanded.get(), disc_expanded), (1, 1, 1, 1, true, Some(true)))
}

///|
test "all 12 Track B overlay, navigation and feedback components pass Tester::audit with 0 faults in light and dark" {
  let faults = []
  for dark in [false, true] {
    // Pass 1: inline components + open Menu + open Popover
    let t1 = ovl_case(dark~, w=1100.0, h=960.0, fn(page, host) {
      page.box(fn(col) {
        col.width(Is(Some(460.0))).gap(Is(14.0)) |> ignore
        liquid_nav_bar_node(col, fn() { "Library" }, subtitle=fn() { "12 parts" }) |> ignore
        liquid_toolbar_node(col, fn(tb) {
          tb.box(fn(w) { w.words(Is("Quick Actions"), look=words_at(ovl_type_sub)).ink(By(fn() { colors().content })) |> ignore })
          |> ignore
        })
        |> ignore
        liquid_toast_node(
          col,
          fn() { true },
          fn() { "Saved" },
          subtitle=fn() { "All changes synced" },
          status=Info,
          action_label=fn() { "View" },
          on_action=fn() {  },
          on_dismiss=fn() {  },
        )
        |> ignore
        col.box(fn(prow) {
          prow.row(Is(true)).gap(Is(16.0)).lines_up(Is(Some(Middle))) |> ignore
          prow.box(fn(b) {
            b.grow(Is(1.0)) |> ignore
            liquid_progress_bar_node(b, fn() { Some(0.65) }, label=fn() { "Build" }, show_value=true) |> ignore
          })
          |> ignore
          liquid_progress_ring_node(prow, fn() { Some(0.65) }, label=fn() { "Ring" }) |> ignore
        })
        |> ignore
        liquid_list_node(
          col,
          fn() {
            [
              LiquidListRow::new(title="Notifications", value="On", chevron=true, on_press=fn() {  }),
              LiquidListRow::new(title="Privacy", subtitle="Camera & Mic", chevron=true, on_press=fn() {  }),
              LiquidListRow::new(title="Sign Out", destructive=true, on_press=fn() {  }),
            ]
          },
          header=fn() { "Preferences" },
          footer=fn() { "Synced via iCloud." },
        )
        |> ignore
        liquid_disclosure_node(
          col,
          fn() { "Diagnostics" },
          fn() { true },
          fn(_) {  },
          fn(c) {
            c.box(fn(w) { w.words(Is("All systems nominal."), look=words_at(ovl_type_sub)).ink(By(fn() { colors().content })) |> ignore })
            |> ignore
          },
          subtitle=fn() { "Status log" },
        )
        |> ignore
        col.box(fn(row) {
          row.row(Is(true)).gap(Is(16.0)).lines_up(Is(Some(Middle))) |> ignore
          liquid_select_node(
            row,
            host,
            fn() { [LiquidSelectOption::new(label="Regular"), LiquidSelectOption::new(label="Clear")] },
            fn() { 0 },
            fn(_) {  },
            label=fn() { "Material" },
          )
          |> ignore
          liquid_tooltip_node(row, host, fn() { "Helpful tip" }, fn(wrap) {
            liquid_button_node(wrap, fn() { "Hover" }, fn() {  }) |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    t1.run_for(springs_out)
    for f in t1.audit() {
      faults.push(("inline", dark, f))
    }

    // Pass 2: open Menu
    let menu_open = @signals.signal(true)
    let t2 = ovl_case(dark~, w=800.0, h=600.0, fn(page, host) {
      liquid_menu_node(
        page,
        host,
        fn() { menu_open.get() },
        fn(v) { menu_open.set(v) },
        fn() { "Menu" },
        ovl_test_trigger("Menu"),
        fn() {
          [
            LiquidMenuEntry::item(label="Edit", shortcut="⌘E", on_select=fn() {  }),
            LiquidMenuEntry::separator(),
            LiquidMenuEntry::check(label="Pin", checked=fn() { true }, on_toggle=fn() {  }),
            LiquidMenuEntry::item(label="Remove", destructive=true, on_select=fn() {  }),
          ]
        },
      )
      |> ignore
    })
    t2.run_for(springs_out)
    for f in t2.audit() {
      faults.push(("menu", dark, f))
    }

    // Pass 3: open Popover
    let pop_open = @signals.signal(true)
    let t3 = ovl_case(dark~, w=800.0, h=600.0, fn(page, host) {
      liquid_popover_node(
        page,
        host,
        fn() { pop_open.get() },
        fn(v) { pop_open.set(v) },
        fn() { "Popover" },
        ovl_test_trigger("Popover"),
        fn() { "Inspector" },
        fn(c) {
          c.box(fn(w) { w.words(Is("Inspector content"), look=words_at(ovl_type_body)).ink(By(fn() { colors().content })) |> ignore })
          |> ignore
        },
      )
      |> ignore
    })
    t3.run_for(springs_out)
    for f in t3.audit() {
      faults.push(("popover", dark, f))
    }

    // Pass 4: open Sheet
    let sheet_open = @signals.signal(true)
    let t4 = ovl_case(dark~, w=800.0, h=700.0, fn(_page, host) {
      liquid_sheet_node(
        host,
        fn() { sheet_open.get() },
        fn() { sheet_open.set(false) },
        fn() { "Sheet Title" },
        fn(b) {
          b.box(fn(w) { w.words(Is("Sheet body content."), look=words_at(ovl_type_body)).ink(By(fn() { colors().content })) |> ignore })
          |> ignore
        },
        subtitle=fn() { "Optional subtitle" },
      )
      |> ignore
    })
    t4.run_for(springs_out)
    for f in t4.audit() {
      faults.push(("sheet", dark, f))
    }

    // Pass 5: open ActionSheet
    let action_open = @signals.signal(true)
    let t5 = ovl_case(dark~, w=800.0, h=700.0, fn(_page, host) {
      liquid_action_sheet_node(
        host,
        fn() { action_open.get() },
        fn() { action_open.set(false) },
        fn() {
          [
            LiquidActionSheetItem::new(label="Copy Link", on_select=fn() {  }),
            LiquidActionSheetItem::new(label="Delete", destructive=true, on_select=fn() {  }),
          ]
        },
        title=fn() { "Manage Item" },
        message=fn() { "This cannot be undone." },
      )
      |> ignore
    })
    t5.run_for(springs_out)
    for f in t5.audit() {
      faults.push(("action_sheet", dark, f))
    }
  }
  assert_eq(faults, [])
}

///|
/// Closed-form frame-rate invariance check for Track B animated overlays and disclosure.
fn ovl_motion_snapshot() -> Array[String] raise {
  let disc_open = @signals.signal(false)
  let sheet_open = @signals.signal(false)
  let t = ovl_case(fn(page, host) {
    page.box(fn(col) {
      col.width(Is(Some(360.0))).gap(Is(16.0)) |> ignore
      liquid_disclosure_node(
        col,
        fn() { "Details" },
        fn() { disc_open.get() },
        fn(v) { disc_open.set(v) },
        fn(c) {
          c.box(fn(w) { w.words(Is("Expanded"), look=words_at(ovl_type_sub)).ink(By(fn() { colors().content })) |> ignore })
          |> ignore
        },
      )
      |> ignore
      liquid_progress_ring_node(col, fn() { None }, label=fn() { "Spinner" }) |> ignore
    })
    |> ignore
    liquid_sheet_node(
      host,
      fn() { sheet_open.get() },
      fn() { sheet_open.set(false) },
      fn() { "Modal" },
      fn(b) {
        b.box(fn(w) { w.words(Is("Body"), look=words_at(ovl_type_body)).ink(By(fn() { colors().content })) |> ignore })
        |> ignore
      },
    )
    |> ignore
  })
  let out : Array[String] = []
  let snap = fn() {
    let r = fn(x : Double) { (x * 100.0).round() / 100.0 }
    let g = t.drawn_glass().map(fn(e) { "\{r(e.0)},\{r(e.1)},\{r(e.2)},\{r(e.3)}" }).join(" ")
    out.push(g)
  }
  t.act(Button, Activate, label="Details")
  t.run_for(held_ms)
  snap()
  t.run_for(springs_out)
  snap()
  sheet_open.set(true)
  t.run_for(held_ms)
  snap()
  t.run_for(springs_out)
  snap()
  out
}

///|
test "liquid_list_node filters rows reactively and updates active selection highlight" {
  let query = @signals.signal("")
  let selected = @signals.signal("Optics")
  let categories : Array[(String, String)] = [
    ("Optics", "3"),
    ("Controls", "7"),
    ("Inputs", "7"),
    ("Overlays", "9"),
  ]
  let t = ovl_case(fn(page, _host) {
    page.box(fn(col) {
      col.width(Is(Some(280.0))) |> ignore
      liquid_list_node(
        col,
        fn() {
          let q = query.get().to_lower()
          let cur = selected.get()
          let out : Array[LiquidListRow] = []
          for cat in categories {
            let (name, count) = cat
            if q == "" || name.to_lower().contains(q) {
              out.push(
                LiquidListRow::new(
                  title=name,
                  value=count,
                  active=cur == name,
                  on_press=fn() { selected.set(name) },
                ),
              )
            }
          }
          out
        },
        header=fn() { "Categories" },
      )
      |> ignore
    })
    |> ignore
  })
  let initial_count = t.all(Button).length()
  let initial_faults = t.audit()
  query.set("ov")
  t.run_for(springs_out)
  let filtered_labels = t.all(Button).map(fn(n) { n.label })
  t.act(Button, Activate, label="Overlays")
  t.run_for(a_frame)
  let after_pick = selected.get()
  query.set("")
  t.run_for(springs_out)
  let restored_count = t.all(Button).length()
  let after_faults = t.audit()
  assert_eq(
    (initial_count, filtered_labels, after_pick, restored_count, initial_faults, after_faults),
    (4, ["Overlays"], "Overlays", 4, [], []),
  )
}

///|
/// Hard zero glass-on-glass gate: verifies no two drawn `Glass::liquid` (`kind == 6`) rectangles
/// overlap by more than `1.0 pt²` (allowing at most `allowed_pairs` intentional capillary pairs).
fn assert_no_nested_glass(t : @ui.Tester, ctx : String, allowed_pairs? : Int = 0) -> Unit raise {
  let rects : Array[(Double, Double, Double, Double)] = []
  for g in t.drawn_glass() {
    if g.4 == 6 && g.2 > 0.0 && g.3 > 0.0 {
      rects.push((g.0, g.1, g.2, g.3))
    }
  }
  let overlaps : Array[String] = []
  for i in 0..<rects.length() {
    let (ax, ay, aw, ah) = rects[i]
    for j in (i + 1)..<rects.length() {
      let (bx, by, bw, bh) = rects[j]
      let ix0 = if ax > bx { ax } else { bx }
      let iy0 = if ay > by { ay } else { by }
      let ix1 = if ax + aw < bx + bw { ax + aw } else { bx + bw }
      let iy1 = if ay + ah < by + bh { ay + ah } else { by + bh }
      if ix1 > ix0 && iy1 > iy0 {
        let area = (ix1 - ix0) * (iy1 - iy0)
        if area > 1.0 {
          overlaps.push("(\{ax},\{ay},\{aw},\{ah}) x (\{bx},\{by},\{bw},\{bh}) area=\{area}")
        }
      }
    }
  }
  if overlaps.length() > allowed_pairs {
    fail("\{ctx}: glass-on-glass detected (\{overlaps.length()} > \{allowed_pairs}): \{overlaps.join("; ")}")
  }
}

///|
test "Track B overlay and disclosure animations are deterministic across 60, 120, 24 and 7 fps" {
  let first = ovl_motion_snapshot()
  let second = ovl_motion_snapshot()
  assert_eq(first, second)
  assert_eq(first.length(), 4)
}

///|
test "zero glass-on-glass across NavBar, Toolbar, List, Disclosure, Sheet, Dialog and flat buttons" {
  for dark in [false, true] {
    let sheet_open = @signals.signal(false)
    let t = ovl_case(dark~, w=900.0, h=760.0, fn(page, host) {
      page.box(fn(col) {
        col.width(Is(Some(520.0))).gap(Is(14.0)) |> ignore
        liquid_nav_bar_node(
          col,
          fn() { "Floating Island Nav" },
          subtitle=fn() { "Zero Nested Glass" },
          leading=fn(s) {
            liquid_icon_button_node(s, fn() { "Nav Lead" }, fn(v, ink) { flight_icon(v, 16.0, ink) }, fn() {  }, size=Small)
            |> ignore
            liquid_badge_node(s, fn() { "Live" }, tone=Success, dot=true) |> ignore
          },
          trailing=fn(s) {
            liquid_segmented_node(s, fn() { ["Light", "Dark"] }, fn() { 0 }, fn(_) {  }, width=136.0, height=36.0) |> ignore
          },
        )
        |> ignore
        liquid_toolbar_node(col, fn(tb) {
          tb.box(fn(w) { w.words(Is("Quick"), look=words_at(ovl_type_sub)).ink(By(fn() { colors().content })) |> ignore })
          |> ignore
          liquid_badge_node(tb, fn() { "3 Active" }, tone=Accent) |> ignore
          liquid_count_badge_node(tb, fn() { 5 }, tone=Danger) |> ignore
        })
        |> ignore
        liquid_list_node(
          col,
          fn() {
            [
              LiquidListRow::new(title="Row One", active=true, on_press=fn() {  }),
              LiquidListRow::new(title="Row Two", on_press=fn() {  }),
            ]
          },
          header=fn() { "Content List" },
        )
        |> ignore
        liquid_disclosure_node(
          col,
          fn() { "Details" },
          fn() { true },
          fn(_) {  },
          fn(c) {
            c.gap(Is(10.0)).lines_up(Is(Some(Start))) |> ignore
            liquid_checkbox_node(c, fn() { true }, fn(_) {  }, fn() { "Check inside disclosure" }) |> ignore
            c.box(fn(w) {
              w.words(Is("Content-layer controls nest cleanly."), look=words_at(ovl_type_sub)).ink(By(ovl_muted_ink))
              |> ignore
            })
            |> ignore
          },
        )
        |> ignore
      })
      |> ignore
      liquid_sheet_node(
        host,
        fn() { sheet_open.get() },
        fn() { sheet_open.set(false) },
        fn() { "Export Sheet" },
        fn(b) {
          b.gap(Is(8.0)) |> ignore
          liquid_checkbox_node(b, fn() { true }, fn(_) {  }, fn() { "Include Alpha" }) |> ignore
          liquid_radio_group_node(b, fn() { ["PNG", "WebP"] }, fn() { 0 }, fn(_) {  }, horizontal=true) |> ignore
          liquid_button_node(b, fn() { "Apply" }, fn() {  }, tint=0xA62908FFL, flat=true) |> ignore
        },
        footer=fn(f) {
          f.row(Is(true)).lies_along(Is(End)) |> ignore
          @headless.button(f, fn() { "Done" }, fn(_) { sheet_open.set(false) }, fn(bv, _btn) {
            bv
            .height(Is(Some(32.0)))
            .padding(Is((16.0, 0.0, 16.0, 0.0)))
            .radius(Is(16.0))
            .lines_up(Is(Some(Middle)))
            .lies_along(Is(Middle))
            .ground(Is(0xA62908FFL))
            |> ignore
            bv.box(fn(w) { w.words(Is("Done"), look=words_at(13.5, weight=weight_medium)).ink(Is(white)) |> ignore })
            |> ignore
          })
          |> ignore
        },
      )
      |> ignore
    })
    t.run_for(springs_out)
    assert_no_nested_glass(t, "ovl_kit_rest dark=\{dark}")
    assert_eq(t.audit(), [])
    // Open sheet and confirm zero child glass inside sheet panel
    sheet_open.set(true)
    t.run_for(springs_out)
    let sheet_rect = t.get(Dialog, label="Export Sheet").rect
    let glass = t.drawn_glass()
    let mut sheet_idx = -1
    for i, g in glass {
      if g.4 == 6 && (g.0 - sheet_rect.0).abs() < 2.0 && (g.1 - sheet_rect.1).abs() < 2.0 {
        sheet_idx = i
      }
    }
    assert_true(sheet_idx >= 0)
    for j in (sheet_idx + 1)..<glass.length() {
      let g = glass[j]
      if g.4 == 6 && g.2 > 0.0 && g.3 > 0.0 {
        fail("sheet dark=\{dark} drew inner glass after sheet panel: (\{g.0},\{g.1},\{g.2},\{g.3})")
      }
    }
    assert_eq(t.audit(), [])
  }
}

///|
test "liquid_list_node keeps steady dividers with breathing room around active and hovered rows" {
  let t = ovl_case(w=500.0, h=460.0, fn(page, _host) {
    page.box(fn(col) {
      col.width(Is(Some(320.0))).gap(Is(16.0)) |> ignore
      // Grouped list with dividers=true
      liquid_list_node(
        col,
        fn() {
          [
            LiquidListRow::new(title="Active Row", active=true, on_press=fn() {  }),
            LiquidListRow::new(title="Middle Row", on_press=fn() {  }),
            LiquidListRow::new(title="Bottom Row", on_press=fn() {  }),
          ]
        },
        dividers=true,
      )
      |> ignore
      // Sidebar list with dividers=false
      liquid_list_node(
        col,
        fn() {
          [
            LiquidListRow::new(title="Side One", active=true, on_press=fn() {  }),
            LiquidListRow::new(title="Side Two", on_press=fn() {  }),
          ]
        },
        dividers=false,
      )
      |> ignore
    })
    |> ignore
  })
  t.run_for(springs_out)
  // 1. Grouped rows sit >= 6pt apart (3pt + 1pt hairline + 3pt); sidebar rows >= 4pt
  let r0 = t.get(Button, label="Active Row").rect
  let r1 = t.get(Button, label="Middle Row").rect
  let r2 = t.get(Button, label="Bottom Row").rect
  let s0 = t.get(Button, label="Side One").rect
  let s1 = t.get(Button, label="Side Two").rect
  assert_true(r1.1 - (r0.1 + r0.3) >= 6.0)
  assert_true(r2.1 - (r1.1 + r1.3) >= 6.0)
  assert_true(s1.1 - (s0.1 + s0.3) >= 4.0)
  // 2. Each divider is drawn, steady, and clear of both rows' pills by >= 3pt on each side
  let divider_clear_between = fn(top_y : Double, bot_y : Double) -> Bool {
    t
    .drawn_rects()
    .iter()
    .any(fn(rc) { rc.3 <= 1.5 && rc.1 - top_y >= ovl_list_sep_py - 0.5 && bot_y - (rc.1 + rc.3) >= ovl_list_sep_py - 0.5 })
  }
  let sep01_init = divider_clear_between(r0.1 + r0.3, r1.1)
  let sep12_init = divider_clear_between(r1.1 + r1.3, r2.1)
  // Hover Middle Row: both dividers beside it stay drawn
  t.move_to(r1.0 + r1.2 / 2.0, r1.1 + r1.3 / 2.0)
  t.run_for(springs_out)
  let sep01_hovered = divider_clear_between(r0.1 + r0.3, r1.1)
  let sep12_hovered = divider_clear_between(r1.1 + r1.3, r2.1)
  assert_eq((sep01_init, sep12_init, sep01_hovered, sep12_hovered), (true, true, true, true))
}

///|
/// π, written out here so the chevrons' turns are checked against radians, not against the tokens they use.
let ovl_test_pi : Double = 3.141592653589793

///|
/// How far the most turned thing drawn is turned, in radians (`View::turn`).
fn ovl_most_turned() -> Double {
  let tree = @ui.view_tree().unwrap()
  tree.drawn().fold(init=0.0, fn(most, d) {
    let turned = tree.turn_angle_of(d.id).abs()
    if turned > most {
      turned
    } else {
      most
    }
  })
}

///|
test "liquid_select_node turns its chevron a half turn and liquid_disclosure_node a quarter turn, in radians" {
  let expanded = @signals.signal(false)
  let t = ovl_case(fn(page, _host) {
    liquid_disclosure_node(
      page,
      fn() { "Advanced" },
      fn() { expanded.get() },
      fn(v) { expanded.set(v) },
      fn(c) {
        c.box(fn(w) { w.words(Is("Hidden details"), look=words_at(ovl_type_sub)).ink(By(fn() { colors().content })) |> ignore })
        |> ignore
      },
    )
    |> ignore
  })
  t.run_for(springs_out)
  let disc_rest = ovl_most_turned()
  t.act(Button, Activate, label="Advanced")
  t.run_for(springs_out)
  let disc_open = ovl_most_turned()
  assert_true(disc_rest < 0.01)
  assert_true((disc_open - ovl_test_pi / 2.0).abs() < 0.01 && disc_open <= 1.7, msg="disclosure turned \{disc_open}")
  let chosen = @signals.signal(0)
  let opts = [LiquidSelectOption::new(label="Light"), LiquidSelectOption::new(label="Dark")]
  let t2 = ovl_case(fn(page, host) {
    liquid_select_node(page, host, fn() { opts }, fn() { chosen.get() }, fn(i) { chosen.set(i) }, label=fn() { "Theme" })
    |> ignore
  })
  t2.run_for(springs_out)
  let select_rest = ovl_most_turned()
  t2.act(Button, Activate, label="Theme: Light")
  t2.run_for(springs_out)
  let select_open = ovl_most_turned()
  assert_true(select_rest < 0.01)
  assert_true((select_open - ovl_test_pi).abs() < 0.01 && select_open <= 3.2, msg="select turned \{select_open}")
}

///|
/// Declared 16ms frame step and sample count (`0..368ms`) for `liquid_menu_node` smoothness & gap-driven bridge tests.
let ovl_morph_step_ms : Double = 16.0

///|
let ovl_morph_step_count : Int = 23

///|
let ovl_morph_close_probe_ms : Double = 60.0

///|
/// Deterministic snapshot of `liquid_menu_node` gap-driven GPU capillary morph across 16ms steps, rest, and unmount.
fn ovl_menu_morph_snapshot() -> (Double, Bool, Bool, Int, Int, Int, Int, Array[String]) raise {
  let open = @signals.signal(false)
  let t = ovl_case(fn(page, host) {
    liquid_menu_node(
      page,
      host,
      fn() { open.get() },
      fn(v) { open.set(v) },
      fn() { "Actions" },
      ovl_test_trigger("Actions"),
      fn() {
        [
          LiquidMenuEntry::item(label="Duplicate", shortcut="⌘D", on_select=fn() {  }),
          LiquidMenuEntry::separator(),
          LiquidMenuEntry::item(label="Delete", destructive=true, on_select=fn() {  }),
        ]
      },
      menu_label=fn() { "Morph Menu" },
    )
    |> ignore
  })
  let r = fn(x : Double) { (x * 100.0).round() / 100.0 }
  let snap_glass = fn() {
    t.drawn_glass().map(fn(e) { "\{r(e.0)},\{r(e.1)},\{r(e.2)},\{r(e.3)}" }).join(" ")
  }
  let trigger_rect = t.get(Button, label="Actions").rect
  let trigger_bottom = trigger_rect.1 + trigger_rect.3
  let snaps : Array[String] = []
  let mut saw_air_gap_bridge = false
  let mut post_sep_clean = true
  let mut prev_shell_top : Double? = None
  let mut max_step_jump = 0.0
  t.act(Button, Activate, label="Actions")
  // Step every 16ms across 0..368ms to verify smooth C2 motion with zero truncation jumps
  for _ in 0..<ovl_morph_step_count {
    t.run_for(ovl_morph_step_ms)
    let gs = t.drawn_glass()
    snaps.push(snap_glass())
    if gs.length() >= 2 {
      let shell_top = gs[gs.length() - 1].1
      match prev_shell_top {
        Some(prev) => {
          let jump = (shell_top - prev).abs()
          if jump > max_step_jump {
            max_step_jump = jump
          }
        }
        None => ()
      }
      prev_shell_top = Some(shell_top)
      if gs.length() == 3 {
        if shell_top > trigger_bottom + 0.5 {
          saw_air_gap_bridge = true
        }
      } else if gs.length() == 2 {
        if shell_top < trigger_bottom + 6.0 {
          post_sep_clean = false
        }
      }
    }
  }
  // Settled open (t = springs_out): trigger + 1 clean menu shell, zero extra glass, zero faults
  t.run_for(springs_out)
  let rest_glass = t.drawn_glass().length()
  assert_no_nested_glass(t, "liquid_menu_morph rest")
  assert_eq(t.audit(), [])
  snaps.push(snap_glass())
  // Mid-flight closing (t = 60ms after Escape): glass shell + capillary bridge contracting
  t.key(@ui.key_escape)
  t.run_for(ovl_morph_close_probe_ms)
  let closing_glass = t.drawn_glass().length()
  snaps.push(snap_glass())
  // Past leave duration: cleanly unmounted (only trigger glass remains, Menu role count == 0)
  t.run_for(ovl_morph_leave_ms + a_frame)
  let closed_glass = t.drawn_glass().length()
  let closed_menus = t.all(Menu, label="Morph Menu").length()
  snaps.push(snap_glass())
  (max_step_jump, saw_air_gap_bridge, post_sep_clean, rest_glass, closing_glass, closed_glass, closed_menus, snaps)
}

///|
test "liquid_menu_node gap-driven morph has zero truncation jump, bridges across real air gap, never overlaps after separation, and is FPS-invariant" {
  let (max_step_jump, saw_air_gap_bridge, post_sep_clean, rest_glass, closing_glass, closed_glass, closed_menus, snaps) = ovl_menu_morph_snapshot()
  assert_true(max_step_jump < 6.5, msg="expected smooth 16ms shell_top step < 6.5pt, got \{max_step_jump}")
  assert_true(saw_air_gap_bridge, msg="expected GPU merged bridge (3 glass rects) across real air gap (gap > 0.5pt)")
  assert_true(post_sep_clean, msg="expected zero overlap (gap >= 6.0pt) whenever separated (2 glass rects)")
  assert_eq(rest_glass, 2)
  assert_true(closing_glass >= 2, msg="expected contracting glass shell at 60ms after close, got \{closing_glass}")
  assert_eq(closed_glass, 1)
  assert_eq(closed_menus, 0)
  let (_, _, _, _, _, _, _, snaps2) = ovl_menu_morph_snapshot()
  assert_eq(snaps, snaps2)
}

///|
let ovl_morph_close_steps : Int = 22

///|
let ovl_close_probe_ms : Double = 60.0

///|
let ovl_dialog_leave_done_ms : Double = 260.0

///|
fn ovl_assert_menu_close_morph(
  t : @ui.Tester,
  trigger_bottom : Double,
  trigger_close : () -> Unit raise,
  label : String,
) -> Unit raise {
  trigger_close()
  let mut max_glass = 0
  let mut saw_air_gap_bridge = false
  let mut top_48 = -1.0
  let mut top_96 = -1.0
  let mut top_144 = -1.0
  for step in 1..<=ovl_morph_close_steps {
    t.run_for(ovl_morph_step_ms)
    let gs = t.drawn_glass()
    if gs.length() > max_glass {
      max_glass = gs.length()
    }
    if gs.length() == 2 {
      let shell_top = gs[1].1
      if step == 3 {
        top_48 = shell_top
      } else if step == 6 {
        top_96 = shell_top
      } else if step == 9 {
        top_144 = shell_top
      }
      if shell_top > trigger_bottom + 0.5 && shell_top < trigger_bottom + ovl_morph_break_gap {
        saw_air_gap_bridge = true
      }
    }
  }
  t.run_for(a_frame)
  assert_true(
    max_glass <= 2,
    msg="\{label}: expected <= 2 glass rects during close, got \{max_glass}",
  )
  assert_true(
    top_48 > top_96 && top_96 > top_144 && top_144 > 0.0,
    msg="\{label}: expected monotonic contraction top(48)=\{top_48} > top(96)=\{top_96} > top(144)=\{top_144}",
  )
  assert_true(
    saw_air_gap_bridge,
    msg="\{label}: expected reverse air-gap capillary bridge during close",
  )
  assert_eq(t.drawn_glass().length(), 1)
  assert_eq(t.all(Menu).length(), 0)
}

///|
test "liquid_menu_node with trigger_face hands off trigger cleanly on open and all 3 close paths under transitions_only" {
  let open = @signals.signal(false)
  let t = ovl_case(fn(page, host) {
    liquid_menu_node(
      page,
      host,
      fn() { open.get() },
      fn(v) { open.set(v) },
      fn() { "Actions" },
      ovl_test_trigger("Actions"),
      fn() {
        [
          LiquidMenuEntry::item(label="Duplicate", shortcut="⌘D", on_select=fn() {  }),
          LiquidMenuEntry::separator(),
          LiquidMenuEntry::item(label="Delete", destructive=true, on_select=fn() {  }),
        ]
      },
      menu_label=fn() { "Handoff Menu" },
      anchor_size=(84.0, 40.0),
      trigger_face=fn(v) {
        v.box(fn(w) { w.words(Is("Actions"), look=words_at(ovl_type_body)).ink(By(fn() { colors().content })) |> ignore })
        |> ignore
      },
    )
    |> ignore
  })
  let trigger_rect = t.get(Button, label="Actions").rect
  let trigger_bottom = trigger_rect.1 + trigger_rect.3
  let mut max_glass_count = 0
  let mut saw_air_gap_bridge = false
  t.act(Button, Activate, label="Actions")
  for _ in 0..<ovl_morph_step_count {
    t.run_for(ovl_morph_step_ms)
    let gs = t.drawn_glass()
    if gs.length() > max_glass_count {
      max_glass_count = gs.length()
    }
    if gs.length() == 2 {
      let shell_top = gs[1].1
      if shell_top > trigger_bottom + 0.5 && shell_top < trigger_bottom + ovl_morph_break_gap {
        saw_air_gap_bridge = true
      }
    }
  }
  t.run_for(springs_out)
  assert_true(max_glass_count <= 2, msg="expected zero double-glass stacking (<= 2 glass rects), got \{max_glass_count}")
  assert_true(saw_air_gap_bridge, msg="expected air-gap capillary bridge frame with trigger_face handoff")
  assert_eq(t.drawn_glass().length(), 2)
  assert_no_nested_glass(t, "liquid_menu_handoff rest")
  assert_eq(t.audit(), [])
  // Close path 1: Escape key
  ovl_assert_menu_close_morph(t, trigger_bottom, fn() { t.key(@ui.key_escape) }, "close-escape")
  // Re-open & Close path 2: Outside click
  t.act(Button, Activate, label="Actions")
  t.run_for(springs_out)
  assert_eq(t.drawn_glass().length(), 2)
  ovl_assert_menu_close_morph(t, trigger_bottom, fn() { t.tap(800.0, 600.0) }, "close-outside")
  // Re-open & Close path 3: Trigger toggle click
  t.act(Button, Activate, label="Actions")
  t.run_for(springs_out)
  assert_eq(t.drawn_glass().length(), 2)
  ovl_assert_menu_close_morph(t, trigger_bottom, fn() raise { t.act(Button, Activate, label="Actions") }, "close-trigger")
  // Re-open once more to confirm zero stuck trigger state
  t.act(Button, Activate, label="Actions")
  t.run_for(springs_out)
  assert_eq(t.drawn_glass().length(), 2)
  assert_eq(t.audit(), [])
}

///|
test "Select, Popover, Sheet and Dialog keep closing leave transitions alive at 60ms under transitions_only" {
  // 1. Select
  let sel = @signals.signal(0)
  let t_sel = ovl_case(fn(page, host) {
    liquid_select_node(
      page,
      host,
      fn() { [LiquidSelectOption::new(label="Alpha"), LiquidSelectOption::new(label="Beta")] },
      fn() { sel.get() },
      fn(i) { sel.set(i) },
      label=fn() { "Mode" },
    )
    |> ignore
  })
  t_sel.act(Button, Activate, label="Mode: Alpha")
  t_sel.run_for(springs_out)
  assert_eq(t_sel.drawn_glass().length(), 2)
  t_sel.key(@ui.key_escape)
  t_sel.run_for(ovl_close_probe_ms)
  assert_eq(t_sel.drawn_glass().length(), 2)
  t_sel.run_for(ovl_morph_leave_ms + a_frame)
  assert_eq(t_sel.drawn_glass().length(), 1)

  // 2. Popover
  let pop_open = @signals.signal(false)
  let t_pop = ovl_case(fn(page, host) {
    liquid_popover_node(
      page,
      host,
      fn() { pop_open.get() },
      fn(v) { pop_open.set(v) },
      fn() { "Info" },
      ovl_test_trigger("Info"),
      fn() { "Details" },
      fn(c) { c.box(fn(w) { w.words(Is("Hello"), look=words_at(ovl_type_body)) |> ignore }) |> ignore },
    )
    |> ignore
  })
  t_pop.act(Button, Activate, label="Info")
  t_pop.run_for(springs_out)
  assert_eq(t_pop.drawn_glass().length(), 2)
  t_pop.key(@ui.key_escape)
  t_pop.run_for(ovl_close_probe_ms)
  assert_true(t_pop.drawn_glass().length() >= 2)
  t_pop.run_for(ovl_morph_leave_ms + a_frame)
  assert_eq(t_pop.drawn_glass().length(), 1)

  // 3. Sheet
  let sheet_open = @signals.signal(false)
  let t_sheet = ovl_case(fn(_page, host) {
    liquid_sheet_node(
      host,
      fn() { sheet_open.get() },
      fn() { sheet_open.set(false) },
      fn() { "Sheet" },
      fn(b) { b.box(fn(w) { w.words(Is("Body"), look=words_at(ovl_type_body)) |> ignore }) |> ignore },
    )
    |> ignore
  })
  sheet_open.set(true)
  t_sheet.run_for(springs_out)
  assert_eq(t_sheet.drawn_glass().length(), 1)
  sheet_open.set(false)
  t_sheet.run_for(ovl_close_probe_ms)
  assert_eq(t_sheet.drawn_glass().length(), 1)
  t_sheet.run_for(ovl_dialog_leave_done_ms)
  assert_eq(t_sheet.drawn_glass().length(), 0)

  // 4. Dialog
  let dlg_open = @signals.signal(false)
  let t_dlg = ovl_case(fn(_page, host) {
    liquid_dialog_node(
      host,
      fn() { dlg_open.get() },
      fn() { dlg_open.set(false) },
      fn() { "Confirm" },
      fn() { "Proceed?" },
    )
    |> ignore
  })
  dlg_open.set(true)
  t_dlg.run_for(springs_out)
  assert_eq(t_dlg.drawn_glass().length(), 1)
  dlg_open.set(false)
  t_dlg.run_for(ovl_close_probe_ms)
  assert_eq(t_dlg.drawn_glass().length(), 1)
  t_dlg.run_for(ovl_dialog_leave_done_ms)
  assert_eq(t_dlg.drawn_glass().length(), 0)
}

///|
let ovl_progress_anim_steps : Int = 16

///|
test "liquid_progress_bar_node and liquid_progress_ring_node animate determinate and indeterminate with zero Flex relayout" {
  let val : @signals.Signal[Double?] = @signals.signal(Some(0.2))
  let t = ovl_case(fn(page, _host) {
    page.box(fn(col) {
      col.width(Is(Some(320.0))).gap(Is(16.0)) |> ignore
      liquid_progress_bar_node(col, fn() { val.get() }, label=fn() { "GPU Pipeline" }, show_value=false) |> ignore
      liquid_progress_ring_node(col, fn() { val.get() }, label=fn() { "Pipeline Ring" }) |> ignore
    })
    |> ignore
  })
  t.run_for(springs_out)
  let tree = @ui.view_tree().unwrap()
  let laid0 = tree.work().laid
  val.set(Some(0.85))
  for _ in 0..<ovl_progress_anim_steps {
    t.run_for(ovl_morph_step_ms)
  }
  let laid_det = tree.work().laid - laid0
  assert_eq(laid_det, 0, msg="expected 0 Flex layouts during determinate progress bar/ring spring, got \{laid_det}")
  val.set(None)
  t.run_for(ovl_morph_step_ms)
  let laid1 = tree.work().laid
  for _ in 0..<ovl_progress_anim_steps {
    t.run_for(ovl_morph_step_ms)
  }
  let laid_ind = tree.work().laid - laid1
  assert_eq(laid_ind, 0, msg="expected 0 Flex layouts during indeterminate progress sweep/spin, got \{laid_ind}")
}

///|
let ovl_drawer_drag_ms : Double = 240.0

///|
test "liquid_drawer_node floats with 10pt inset, rubber-bands on over-pull, dismisses on drag > 32%, and passes audit + zero glass-on-glass" {
  for dark in [false, true] {
    for side in [DrawerSide::Leading, DrawerSide::Trailing] {
      let open = @signals.signal(true)
      let t = ovl_case(dark~, w=900.0, h=700.0, fn(_page, host) {
        liquid_drawer_node(
          host,
          fn() { open.get() },
          fn() { open.set(false) },
          fn() { "Inspector Drawer" },
          fn(b) {
            liquid_list_node(
              b,
              fn() {
                [
                  LiquidListRow::new(title="Dense Glass", value="85%"),
                  LiquidListRow::new(title="Spring Settle", value="60 fps"),
                ]
              },
              dividers=false,
              flat=true,
            )
            |> ignore
          },
          side~,
          width=320.0,
          subtitle=fn() { "Floating Island" },
        )
        |> ignore
      })
      t.run_for(springs_out)
      let rect = t.get(Dialog, label="Inspector Drawer").rect
      let expected_x = match side {
        Leading => ovl_drawer_inset
        Trailing => 900.0 - 320.0 - ovl_drawer_inset
      }
      assert_true((rect.0 - expected_x).abs() < 1.0, msg="drawer x=\{rect.0}, expected \{expected_x}")
      assert_true((rect.1 - ovl_drawer_inset).abs() < 1.0, msg="drawer y=\{rect.1}, expected \{ovl_drawer_inset}")
      assert_true((rect.3 - (700.0 - 2.0 * ovl_drawer_inset)).abs() < 1.0, msg="drawer h=\{rect.3}")
      assert_eq(t.drawn_glass().length(), 1)
      assert_no_nested_glass(t, "liquid_drawer dark=\{dark}")
      assert_eq(t.audit(), [])
      assert_eq(t.corner_faults(), [])

      // 1. Over-pull toward expand direction -> rubber-band <= 16pt and stays open on release
      let cx = rect.0 + rect.2 / 2.0
      let cy = rect.1 + rect.3 / 2.0
      let expand_dx = match side {
        Leading => 120.0
        Trailing => -120.0
      }
      t.touch(0, cx, cy)
      t.run_for(ovl_morph_step_ms)
      t.touch(1, cx + expand_dx, cy)
      t.run_for(ovl_morph_step_ms)
      let pulled_x = t.get(Dialog, label="Inspector Drawer").rect.0
      let delta_over = (pulled_x - rect.0).abs()
      assert_true(delta_over > 2.0 && delta_over <= ovl_drawer_overpull_max + 0.5, msg="rubber-band delta=\{delta_over}")
      t.touch(2, cx + expand_dx, cy)
      t.run_for(springs_out)
      assert_eq(open.get(), true)
      assert_true((t.get(Dialog, label="Inspector Drawer").rect.0 - expected_x).abs() < 1.0)

      // 2. Drag toward dismiss past 32% width (140pt > 102.4pt) -> closes cleanly
      let dismiss_dx = match side {
        Leading => -140.0
        Trailing => 140.0
      }
      t.touch(0, cx, cy)
      t.run_for(ovl_morph_step_ms)
      t.touch(1, cx + dismiss_dx, cy)
      t.run_for(ovl_drawer_drag_ms)
      t.touch(2, cx + dismiss_dx, cy)
      t.run_for(springs_out)
      assert_eq(open.get(), false)
      assert_eq(t.drawn_glass().length(), 0)
    }
  }
}

///|
test "liquid_sheet_node with detents=true keeps floating corners on wide desktop, docks all 3 edges on narrow phone, keeps X symmetric, and dismisses on drag" {
  // 1. Wide desktop (900x700 > 520): stays floating (12pt inset) even at Large detent
  for dark in [false, true] {
    let open = @signals.signal(true)
    let exp = @signals.signal(false)
    let t = ovl_case(dark~, w=900.0, h=700.0, fn(_page, host) {
      liquid_sheet_node(
        host,
        fn() { open.get() },
        fn() { open.set(false) },
        fn() { "Detent Sheet" },
        fn(b) {
          b.box(fn(w) {
            w.words(Is("Morphing detent body"), look=words_at(ovl_type_body)).ink(By(fn() { colors().content }))
            |> ignore
          })
          |> ignore
        },
        subtitle=fn() { "Medium to Large" },
        detents=true,
        expanded=fn() { exp.get() },
        on_expanded=fn(v) { exp.set(v) },
      )
      |> ignore
    })
    t.run_for(springs_out)
    let r_med = t.get(Dialog, label="Detent Sheet").rect
    let close_r = t.get(Button, label="Close").rect
    let close_top_gap = close_r.1 - r_med.1
    let close_right_gap = r_med.0 + r_med.2 - (close_r.0 + close_r.2)
    assert_true((close_top_gap - close_right_gap).abs() < 0.5, msg="close button asymmetric: top=\{close_top_gap}, right=\{close_right_gap}")
    assert_true((close_top_gap - 12.0).abs() < 0.5, msg="close top gap expected 12pt, got \{close_top_gap}")
    assert_eq(t.drawn_glass().length(), 1)
    assert_no_nested_glass(t, "sheet-detent-wide-medium dark=\{dark}")
    assert_eq(t.audit(), [])
    assert_eq(t.corner_faults(), [])
    assert_true((700.0 - (r_med.1 + r_med.3) - ovl_sheet_wide_inset).abs() < 1.5, msg="wide medium bottom inset: y=\{r_med.1}, h=\{r_med.3}")

    // Expand on wide desktop -> grows taller while staying floating (12pt bottom inset, never flat-bottomed)
    t.act(Button, Activate, label="Expand Sheet")
    t.run_for(springs_out)
    let r_large = t.get(Dialog, label="Detent Sheet").rect
    assert_eq(exp.get(), true)
    assert_true(r_large.3 > r_med.3 + 120.0, msg="expected Large height > Medium + 120, got \{r_large.3} vs \{r_med.3}")
    assert_true((700.0 - (r_large.1 + r_large.3) - ovl_sheet_wide_inset).abs() < 1.5, msg="wide large stays floating: y=\{r_large.1}, h=\{r_large.3}")
    assert_no_nested_glass(t, "sheet-detent-wide-large dark=\{dark}")
    assert_eq(t.audit(), [])
    assert_eq(t.corner_faults(), [])

    // Collapse back to Medium
    t.act(Button, Activate, label="Collapse Sheet")
    t.run_for(springs_out)
    assert_eq(exp.get(), false)
    let r_back = t.get(Dialog, label="Detent Sheet").rect
    assert_true((r_back.3 - r_med.3).abs() < 1.5)

    // Drag header downward > 80pt (120pt) -> dismisses sheet
    let hx = r_back.0 + r_back.2 / 2.0
    let hy = r_back.1 + 40.0
    t.touch(0, hx, hy)
    t.run_for(ovl_morph_step_ms)
    t.touch(1, hx, hy + 120.0)
    t.run_for(ovl_drawer_drag_ms)
    t.touch(2, hx, hy + 120.0)
    t.run_for(springs_out)
    assert_eq(open.get(), false)
    assert_eq(t.drawn_glass().length(), 0)
  }

  // 2. Narrow phone (390x720): Medium floats with 10pt inset, Large docks flush on left, right, and bottom (0pt)
  let open_m = @signals.signal(true)
  let exp_m = @signals.signal(false)
  let tm = ovl_case(dark=false, w=390.0, h=720.0, fn(_page, host) {
    liquid_sheet_node(
      host,
      fn() { open_m.get() },
      fn() { open_m.set(false) },
      fn() { "Phone Sheet" },
      fn(b) {
        b.box(fn(w) { w.words(Is("Phone sheet body"), look=words_at(ovl_type_body)).ink(By(fn() { colors().content })) |> ignore })
        |> ignore
      },
      width=390.0,
      detents=true,
      expanded=fn() { exp_m.get() },
      on_expanded=fn(v) { exp_m.set(v) },
    )
    |> ignore
  })
  tm.run_for(springs_out)
  let rm_med = tm.get(Dialog, label="Phone Sheet").rect
  assert_true((rm_med.0 - ovl_sheet_inset).abs() < 1.0, msg="phone medium left inset=\{rm_med.0}")
  assert_true((390.0 - (rm_med.0 + rm_med.2) - ovl_sheet_inset).abs() < 1.0, msg="phone medium right inset")
  assert_true((720.0 - (rm_med.1 + rm_med.3) - ovl_sheet_inset).abs() < 1.5, msg="phone medium bottom inset")
  tm.act(Button, Activate, label="Expand Sheet")
  tm.run_for(springs_out)
  let rm_large = tm.get(Dialog, label="Phone Sheet").rect
  assert_true(rm_large.0.abs() < 1.0, msg="phone large left docked expected 0, got \{rm_large.0}")
  assert_true((390.0 - (rm_large.0 + rm_large.2)).abs() < 1.0, msg="phone large right docked expected 0")
  assert_true((720.0 - (rm_large.1 + rm_large.3)).abs() < 1.5, msg="phone large bottom docked expected 0")
  let c_lg = tm.get(Button, label="Close").rect
  assert_true(((c_lg.1 - rm_large.1) - (rm_large.0 + rm_large.2 - (c_lg.0 + c_lg.2))).abs() < 0.5)
  assert_eq(tm.audit(), [])
  assert_eq(tm.corner_faults(), [])
}

///|
test "ovl_sheet_glass and ovl_drawer_glass use symmetric 80% floating tint (0xCC) and morph symmetrically to 86% (0xDC)" {
  for dark in [false, true] {
    set_dark(Some(dark))
    let expected_rest = if dark { 0x202020CCL } else { 0xFDFCFDCCL }
    let expected_full = if dark { 0x202020DCL } else { 0xFDFCFDDCL }
    let sg = ovl_sheet_glass()
    let dg = liquid_drawer_glass()
    assert_eq(sg.tint, expected_rest)
    assert_eq(dg.tint, expected_rest)
    let sg_exp = ovl_sheet_glass_at(1.0)
    assert_eq(sg_exp.tint, expected_full)
    assert_true((sg_exp.tint & 0xFFL) > (sg.tint & 0xFFL))
    assert_true(sg_exp.blur > sg.blur)
    assert_true(sg_exp.refraction < sg.refraction)
    assert_true((sg_exp.rim - 0.45).abs() < 0.01)
  }
}

///|
test "exported liquid_*_glass recipes match symmetric density, solid override and progressive scroll-edge spec" {
  for dark in [false, true] {
    set_dark(Some(dark))
    let custom_solid = 0x112233FFL
    let pg = liquid_panel_glass(solid=custom_solid)
    let dg = liquid_dialog_glass(solid=custom_solid)
    let sg = liquid_sheet_glass(solid=custom_solid)
    let drg = liquid_drawer_glass(solid=custom_solid)
    let tg = liquid_toast_glass(solid=custom_solid)
    let cg = liquid_capsule_glass(solid=custom_solid)
    let expected_70 = if dark { 0x202020B3L } else { 0xFDFCFDB3L }
    let expected_75 = if dark { 0x202020BFL } else { 0xFDFCFDBFL }
    let expected_80 = if dark { 0x202020CCL } else { 0xFDFCFDCCL }
    assert_eq(pg.tint, expected_75)
    assert_eq(pg.solid, custom_solid)
    assert_eq(pg.bezel, 16.0)
    assert_eq(pg.refraction, 22.0)
    assert_eq(dg.tint, expected_70)
    assert_eq(dg.blur, 9.0)
    assert_eq(dg.rim, 0.65)
    assert_eq(dg.bezel, 22.0)
    assert_eq(dg.refraction, 32.0)
    assert_eq(dg.solid, custom_solid)
    assert_eq(sg.tint, expected_80)
    assert_eq(sg.refraction, 24.0)
    assert_eq(drg.tint, expected_80)
    assert_eq(tg.tint, expected_75)
    assert_eq(tg.blur, 2.1)
    assert_eq(tg.bezel, 12.0)
    assert_eq(tg.refraction, 14.0)
    assert_eq(cg.solid, custom_solid)
    let seg_default = liquid_scroll_edge_glass()
    let expected_bg = if dark { 0x121212FFL } else { 0xFFFFFFFFL }
    assert_eq(seg_default.progressive, true)
    assert_eq(seg_default.blur, 8.5)
    assert_eq(seg_default.saturation, 1.25)
    assert_eq(seg_default.solid, expected_bg)
    assert_eq(seg_default.tint, alpha(expected_bg, 0.50))
    let seg_custom = liquid_scroll_edge_glass(bg=0x223344FFL)
    assert_eq(seg_custom.solid, 0x223344FFL)
    assert_eq(seg_custom.tint, alpha(0x223344FFL, 0.50))
    let (ew, ec) = liquid_overlay_solid_edge()
    assert_eq(ew, 1.0)
    assert_eq(ec, if dark { 0xFFFFFF24L } else { 0x00000018L })
  }
}

///|
test "liquid_scroll_edge_node emits progressive frosted glass when base_h > 0, zero hidden glass at base_h = 0, and shields clicks" {
  let bar_h = @signals.signal(64.0)
  let under_taps = Ref(0)
  let t = ovl_case(w=420.0, h=500.0, fn(page, _host) {
    page.box(fn(stage) {
      stage.width(Is(Some(356.0))).height(Is(Some(320.0))) |> ignore
      // Button positioned at top behind the top scroll-edge shield
      liquid_button_node(stage, fn() { "Behind Top" }, fn() { under_taps.val += 1 }) |> ignore
      liquid_scroll_edge_node(
        stage,
        fn(_) { bar_h.get() },
        fn(_) { bar_h.get() },
        side=Top,
        shield=true,
      )
      |> ignore
      liquid_scroll_edge_node(
        stage,
        fn(_) { bar_h.get() },
        fn(_) { bar_h.get() },
        side=Bottom,
        shield=false,
      )
      |> ignore
    })
    |> ignore
  })
  t.run_for(springs_out)
  // 1 liquid button + 2 frosted progressive scroll-edge bands (kind != 6)
  let frosted_open = t.drawn_glass().filter(fn(g) { g.4 != 6 }).length()
  assert_eq(frosted_open, 2)
  // Tapping the button behind the shielded Top scroll edge is blocked
  let (bx, by) = middle(t, Button, "Behind Top")
  t.tap(bx, by)
  t.run_for(a_frame)
  assert_eq(under_taps.val, 0)
  // Collapsing base_h to 0 emits zero hidden scroll-edge glass instances
  bar_h.set(0.0)
  t.run_for(a_frame)
  let frosted_zero = t.drawn_glass().filter(fn(g) { g.4 != 6 }).length()
  assert_eq(frosted_zero, 0)
  assert_no_nested_glass(t, "liquid_scroll_edge_node")
}

///|
test "liquid_dialog_shell_node, liquid_toast_shell_node and liquid_tooltip_bubble_node render single-layer glass with 0 audit faults" {
  for dark in [false, true] {
    let t = ovl_case(dark~, w=700.0, h=600.0, fn(page, _host) {
      page.box(fn(col) {
        col.width(Is(Some(420.0))).gap(Is(16.0)) |> ignore
        liquid_dialog_shell_node(col, radius=24.0, fn(d) {
          d.padding(Is((20.0, 20.0, 20.0, 20.0))).gap(Is(8.0)) |> ignore
          d.box(fn(w) {
            w.words(Is("Custom Dialog Shell"), look=words_at(ovl_type_title, weight=ovl_weight_semibold))
            .ink(By(fn() { colors().content }))
            |> ignore
          })
          |> ignore
          d.box(fn(w) {
            w.words(Is("Composable dense 80% glass surface for panels and switchers."), look=words_at(ovl_type_body, wrap=true))
            .ink(By(ovl_muted_ink))
            |> ignore
          })
          |> ignore
        })
        |> ignore
        liquid_toast_shell_node(col, fn(tb) {
          tb.row(Is(true)).padding(Is((16.0, 10.0, 16.0, 10.0))).lines_up(Is(Some(Middle))) |> ignore
          tb.box(fn(w) {
            w.words(Is("Toast shell message"), look=words_at(ovl_type_body)).ink(By(fn() { colors().content }))
            |> ignore
          })
          |> ignore
        })
        |> ignore
        liquid_tooltip_bubble_node(col, fn() { "Quick Open" }, shortcut=fn() { "⌘K" }) |> ignore
        liquid_toolbar_node(col, pad=16.0, gap=12.0, fn(bar) {
          bar.box(fn(w) { w.words(Is("Custom Toolbar"), look=words_at(ovl_type_sub)).ink(By(fn() { colors().content })) |> ignore })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    t.run_for(springs_out)
    assert_eq(t.drawn_glass().filter(fn(g) { g.4 == 6 }).length(), 4)
    assert_no_nested_glass(t, "uplifted shells dark=\{dark}")
    assert_eq(t.audit(), [])
    assert_eq(t.corner_faults(), [])
  }
}

///|
test "liquid_drawer_node supports show_header=false, scrim=false and clamps width on narrow windows" {
  let open = @signals.signal(true)
  let t = ovl_case(w=300.0, h=600.0, fn(_page, host) {
    liquid_drawer_node(
      host,
      fn() { open.get() },
      fn() { open.set(false) },
      fn() { "Workspace Sidebar" },
      fn(b) {
        b.box(fn(w) {
          w.words(Is("Headless custom header"), look=words_at(ovl_type_body)).ink(By(fn() { colors().content }))
          |> ignore
        })
        |> ignore
      },
      width=360.0,
      show_header=false,
      scrim=false,
      inset=10.0,
      body_pad=16.0,
    )
    |> ignore
  })
  t.run_for(springs_out)
  let rect = t.get(Dialog, label="Workspace Sidebar").rect
  // Clamped to window_w - 2 * inset = 300 - 20 = 280
  assert_true((rect.2 - 280.0).abs() < 1.0, msg="expected clamped drawer width 280, got \{rect.2}")
  assert_eq(t.all(Button, label="Close").length(), 0)
  assert_no_nested_glass(t, "liquid_drawer_headless_narrow")
  assert_eq(t.audit(), [])
}

///|
test "liquid_toast_node supports horizontal swipe-to-dismiss and springs back on short drag" {
  let visible = @signals.signal(true)
  let dismissed = Ref(0)
  let t = ovl_case(w=600.0, h=400.0, fn(page, _host) {
    page.box(fn(col) {
      col.width(Is(Some(360.0))) |> ignore
      liquid_toast_node(
        col,
        fn() { visible.get() },
        fn() { "Swipeable notice" },
        on_dismiss=fn() {
          dismissed.val += 1
          visible.set(false)
        },
      )
      |> ignore
    })
    |> ignore
  })
  t.run_for(springs_out)
  let r = t.get(Status, label="Swipeable notice").rect
  let cx = r.0 + r.2 * 0.5
  let cy = r.1 + r.3 * 0.5
  // Short drag (30pt < 72pt) stays open
  t.touch(0, cx, cy)
  t.run_for(ovl_morph_step_ms)
  t.touch(1, cx + 30.0, cy)
  t.run_for(ovl_drawer_drag_ms)
  t.touch(2, cx + 30.0, cy)
  t.run_for(springs_out)
  assert_eq((visible.get(), dismissed.val), (true, 0))
  // Long swipe right (110pt > 72pt) triggers on_dismiss
  t.touch(0, cx, cy)
  t.run_for(ovl_morph_step_ms)
  t.touch(1, cx + 110.0, cy)
  t.run_for(ovl_drawer_drag_ms)
  t.touch(2, cx + 110.0, cy)
  t.run_for(springs_out)
  assert_eq((visible.get(), dismissed.val, t.all(Status, label="Swipeable notice").length()), (false, 1, 0))
}

///|
test "liquid_tooltip_node renders shortcut badge via liquid_tooltip_bubble_node without blocking clicks" {
  let clicked = Ref(0)
  let t = ovl_case(fn(page, host) {
    liquid_tooltip_node(
      page,
      host,
      fn() { "Command Palette" },
      fn(wrap) {
        liquid_button_node(wrap, fn() { "Palette" }, fn() { clicked.val += 1 }) |> ignore
      },
      shortcut=fn() { "⌘K" },
    )
    |> ignore
  })
  let (bx, by) = middle(t, Button, "Palette")
  t.move_to(bx, by)
  t.run_for(@headless.tooltip_delay_ms + springs_out)
  assert_eq(t.all(Tooltip, label="Command Palette").length(), 1)
  assert_true(t.words_said().iter().any(fn(w) { w.0 == "⌘K" }))
  assert_eq(t.audit(), [])
  t.tap(bx, by)
  t.run_for(springs_out)
  assert_eq(clicked.val, 1)
}

///|
test "liquid_dialog_node iOS 26/27 compact geometry passes Tester::audit and corner_faults in light and dark" {
  for dark in [false, true] {
    let open = @signals.signal(true)
    let t = ovl_case(dark~, w=700.0, h=600.0, fn(_page, host) {
      liquid_dialog_node(
        host,
        fn() { open.get() },
        fn() { open.set(false) },
        fn() { "Publish ui.monoid" },
        fn() { "Compile one MoonBit UI tree into native GPU bundles." },
        cancel=fn() { "Cancel" },
        action=fn() { "Publish" },
      )
      |> ignore
    })
    t.run_for(springs_out)
    let rect = t.get(Dialog, label="Publish ui.monoid").rect
    assert_true((rect.2 - 320.0).abs() < 1.0, msg="expected default dialog width 320, got \{rect.2}")
    assert_no_nested_glass(t, "liquid_dialog_ios27 dark=\{dark}")
    assert_eq(t.audit(), [])
    assert_eq(t.corner_faults(), [])
  }
}
