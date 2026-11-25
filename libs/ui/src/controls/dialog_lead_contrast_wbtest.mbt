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
