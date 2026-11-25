// What a dialog says under its title (parts.mbt dialog_lead) reads on the unified 50% liquid dialog glass
// (glass/tokens_overlays.mbt liquid_dialog_glass): muted in the light, in the dark three quarters of the way from
// muted to the words' own ink, more contrast asked bringing it nearer still; and the dialog's glass is the unified
// recipe's, not the light-only 82% veil it once laid over it (dialog_surface_decorate).

///|
/// What dark liquid glass at 50% lets show of a bright backdrop under it: white (#636363) and a vivid green (#286438),
/// the grounds where muted words alone fell under 4.5:1.
let dark_glass_bright_grounds : Array[Int64] = [0x636363FFL, 0x286438FFL]

///|
test "dialog_lead: muted in the light, muted three quarters to the ink in the dark, >= 4.5:1 on bright dark glass" {
  assert_eq(dialog_lead.base.color, Some(@ui.Muted))
  assert_eq(dialog_lead.dark.map(fn(p) { p.color }), Some(Some(@ui.Over(Muted, A(Fg, O75)))))
  for more in [false, true] {
    let th = ui_theme_of(theme_of(true, more))
    let ink = th.color(dialog_lead.dark.unwrap().color.unwrap())
    let muted = th.color(Muted)
    for ground in dark_glass_bright_grounds {
      let r = @ui.contrast_ratio(ink, ground)
      assert_true(r >= 4.5, msg="dialog_lead in the dark (more=\{more}) on \{ground}: \{r}")
      // muted alone, as it was, falls short where more contrast is not asked
      if !more && ground == 0x636363FFL {
        assert_true(@ui.contrast_ratio(muted, ground) < 4.5)
      }
    }
    // never past the words' own ink: still a quieter line than the title
    assert_true(@ui.contrast_ratio(ink, 0x636363FFL) < @ui.contrast_ratio(th.color(Fg), 0x636363FFL) + 1.0e-9)
  }
  // more contrast asked: the lead nearer the ink than without
  let plain = ui_theme_of(theme_of(true, false))
  let more = ui_theme_of(theme_of(true, true))
  let c = dialog_lead.dark.unwrap().color.unwrap()
  assert_true(@ui.contrast_ratio(more.color(c), 0x636363FFL) > @ui.contrast_ratio(plain.color(c), 0x636363FFL))
}

///|
test "dialog_surface_decorate draws the unified 50% dialog glass in light and dark, its lead words clean of contrast faults" {
  for dark in [false, true] {
    let t = @ui.Tester::new(fn(_c) {  }, w=480.0, h=360.0, dark~, platform=0)
    set_dark(Some(dark))
    @ui.set_view_app(fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      root.box(fn(page) {
        // (the theme's own page under it: a dialog over its app, not over a bare white window)
        page.grow(Is(1.0)).padding(Is((40.0, 40.0, 40.0, 40.0))).ground(By(fn() { ui_theme_now().bg })) |> ignore
        page.box(fn(d) {
          d.width(Is(Some(320.0))).padding(Is((24.0, 24.0, 24.0, 24.0))) |> ignore
          dialog_surface_decorate(d) |> ignore
          words_node(d, fn() { "Title" }, fn() { dialog_title }) |> ignore
          words_node(d, fn() { "What the dialog says under its title." }, fn() { dialog_lead }) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    t.draw()
    let tints = t
      .drawn_instances()
      .filter(fn(i) { i[5] == 6.0 })
      .map(fn(i) { ((i[8] * 255.0).round().to_int(), (i[11] * 255.0).round().to_int()) })
    let faults = t.contrast_faults()
    set_dark(None)
    // one liquid glass, its tint the unified recipe's (0x80 in light and dark; never the old light 0xD1 veil)
    assert_eq((dark, tints), (dark, [(if dark { 0x20 } else { 0xFD }, 0x80)]))
    assert_eq((dark, faults), (dark, []))
  }
}

///|
test "dark menu danger row & heading hierarchy: clean glass, >= 4.5:1 on app/scene glass, clear heading hierarchy" {
  let th = ui_theme_of(theme_of(true, false))
  let danger_ink = th.color(Over(Danger, A(Fg, O25)))
  let heading_ink = th.color(Over(Muted, A(Fg, O55)))
  let normal_hover = th.color(A(Fg, O5))
  // Real dark app glass surfaces (#232325, #2F2F32, #3C3D40) + mid-bright scene glass (#4F5053)
  let dark_surfaces : Array[Int64] = [0x232325FFL, 0x2F2F32FFL, 0x3C3D40FFL]
  for g in dark_surfaces {
    assert_true(@ui.contrast_ratio(danger_ink, g) >= 4.5, msg="danger rest on \{g}")
    assert_true(@ui.contrast_ratio(danger_ink, @ui.over(g, normal_hover)) >= 4.5, msg="danger hover on \{g}")
    assert_true(@ui.contrast_ratio(heading_ink, g) >= 4.5, msg="heading on \{g}")
  }
  assert_true(@ui.contrast_ratio(danger_ink, 0x4F5053FFL) >= 4.5, msg="danger rest on #4F5053 >= 4.5")
  assert_true(@ui.contrast_ratio(danger_ink, @ui.over(0x636363FFL, normal_hover)) >= 3.0, msg="danger hover on pure white glass >= 3.0")
  // Heading stays visibly quieter than primary Fg ink in dark menus
  assert_true(@ui.contrast_ratio(heading_ink, 0x3C3D40FFL) + 1.0 < @ui.contrast_ratio(th.color(Fg), 0x3C3D40FFL))
  // Real menu component check: opening a dark desktop menu emits lifted Danger ink & quieter heading with 0 contrast faults
  presenters_reset()
  let t = @ui.Tester::new(fn(_c) {  }, w=1280.0, h=800.0, dark=true, platform=0)
  set_dark(Some(true))
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(page) {
      page.grow(Is(1.0)).ground(By(fn() { ui_theme_now().bg })) |> ignore
      button_node(page, fn() { "打开" }, fn() {
        menu(
          [
            Some(menu_item_of("这个对话", fn() {  }, heading=true)),
            Some(menu_item_of("重命名", fn() {  })),
            Some(menu_item_of("删除对话", fn() {  }, danger=true)),
          ],
          from=at_point(400.0, 200.0),
        )
      })
      |> ignore
    })
    |> ignore
    presented_nodes(root)
  })
  t.draw()
  t.tap_text("打开")
  t.run_for(@ui.move_most_ms)
  t.draw()
  assert_eq(inks_of(t, "删除对话"), [danger_ink])
  assert_eq(inks_of(t, "这个对话"), [heading_ink])
  let faults = t.contrast_faults()
  set_dark(None)
  assert_eq(faults, [])
  // Normal dark overlay hover brightens rather than darkens, and keeps Fg >= 4.5:1 over pure-white 0x80 glass (#636363)
  let dark_menu_body = 0x3A3A3CFFL
  assert_true(@ui.contrast_ratio(@ui.over(dark_menu_body, normal_hover), 0x000000FFL) > @ui.contrast_ratio(dark_menu_body, 0x000000FFL))
  assert_true(@ui.contrast_ratio(th.color(Fg), @ui.over(0x636363FFL, normal_hover)) >= 4.5)
  // Light overlay selected checkmarks use accent_text (>= 3.0:1 over 0x80 light glass over black + Hover)
  let light_th = ui_theme_of(theme_of(false, false))
  let light_hover_bg = @ui.over(0xC9C9C9FFL, light_th.color(Hover))
  assert_true(@ui.contrast_ratio(light_th.color(AccentText), light_hover_bg) >= 3.0)
}
