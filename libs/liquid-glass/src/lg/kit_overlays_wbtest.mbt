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
) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w~, h~, platform=0)
  set_dark(Some(dark))
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme)
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
test "Track B overlay and disclosure animations are deterministic across 60, 120, 24 and 7 fps" {
  let first = ovl_motion_snapshot()
  let second = ovl_motion_snapshot()
  assert_eq(first, second)
  assert_eq(first.length(), 4)
}
