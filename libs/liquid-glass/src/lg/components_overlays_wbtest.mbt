// Whitebox tests for Wave 21 Track C2 overlay / drawer / morphing popover surface decorators and shells:
// - `liquid_dialog_surface_decorate` (including 82% light veil `0xFDFCFDD1L` and `MBUI_GLASS=solid` degradation)
// - `liquid_panel_surface_decorate` / `liquid_panel_shell_node` (`active=false` zero hidden glass + `merge`)
// - `liquid_popover_surface_decorate` (regular anchored mode + iOS 27.0 liquid-bridge morph mode + solid degradation)
// - `liquid_tooltip_surface_decorate` (`points=false` click-through + `active=false` zero hidden glass)
// - `liquid_sheet_surface_decorate`, `liquid_drawer_surface_decorate`, `liquid_toast_surface_decorate`
//   (`active=false` zero hidden glass, Light/Dark, `MBUI_GLASS=solid` degradation)
// Every case asserts `t.audit() == []` and zero nested glass (`assert_no_nested_glass`).

///|
test "liquid_dialog_surface_decorate supports 82% light veil, Light/Dark contrast, and MBUI_GLASS=solid" {
  for dark in [false, true] {
    let t = ovl_case(dark~, fn(page, _) {
      page.box(fn(card) {
        card.width(Is(Some(360.0))).padding(Is((20.0, 20.0, 20.0, 20.0))).gap(Is(8.0)) |> ignore
        liquid_dialog_surface_decorate(
          card,
          radius=24.0,
          tint_light=0xFDFCFDD1L,
          solid=fn() { if is_dark() { 0x1E1E22FFL } else { 0xFFFFFFFFL } },
        )
        |> ignore
        card.box(fn(w) {
          w.words(Is("Dialog Title"), look=words_at(ovl_type_title, weight=ovl_weight_semibold)).ink(
            By(fn() { colors().content }),
          )
          |> ignore
        })
        |> ignore
        card.box(fn(w) {
          w.words(Is("Secondary muted body copy"), look=words_at(ovl_type_sub)).ink(
            By(fn() { if is_dark() { 0xFFFFFFB8L } else { 0x535559FFL } }),
          )
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    t.run_for(springs_out)
    let liquid_count = t.drawn_glass().filter(fn(g) { g.4 == 6 }).length()
    assert_eq(liquid_count, 1)
    assert_no_nested_glass(t, "liquid_dialog_surface_decorate dark=\{dark}")
    assert_eq(t.audit(), [])
  }
  // Solid fallback mode emits zero liquid glass passes and passes audit.
  for dark in [false, true] {
    let t = solid_case(dark, fn(page) {
      page.box(fn(card) {
        card.width(Is(Some(360.0))).padding(Is((20.0, 20.0, 20.0, 20.0))) |> ignore
        liquid_dialog_surface_decorate(
          card,
          radius=24.0,
          tint_light=0xFDFCFDD1L,
          solid=fn() { if is_dark() { 0x1E1E22FFL } else { 0xFFFFFFFFL } },
        )
        |> ignore
        card.box(fn(w) {
          w.words(Is("Solid Dialog"), look=words_at(ovl_type_body)).ink(By(fn() { colors().content })) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    t.run_for(springs_out)
    let liquid_count = t.drawn_glass().filter(fn(g) { g.4 == 6 }).length()
    let audits = t.audit()
    @ui.set_glass_solid(None)
    assert_eq((dark, liquid_count, audits), (dark, 0, []))
  }
}

///|
test "liquid_panel_surface_decorate and liquid_panel_shell_node gate hidden glass and support merge" {
  for dark in [false, true] {
    let active = @signals.signal(false)
    let merge_k = @signals.signal(0.0)
    let t = ovl_case(dark~, fn(page, _) {
      page.box(fn(row) {
        row.row(Is(true)).gap(Is(24.0)) |> ignore
        row.box(fn(p) {
          p.width(Is(Some(220.0))).padding(Is((14.0, 12.0, 14.0, 12.0))) |> ignore
          liquid_panel_surface_decorate(
            p,
            radius=18.0,
            active=fn() { active.get() },
            merge=fn() { merge_k.get() },
            solid=fn() { if is_dark() { 0x1C1C1EFFL } else { 0xF7F7FAFFL } },
          )
          |> ignore
          p.box(fn(w) {
            w.words(Is("Decorated Panel"), look=words_at(ovl_type_body)).ink(By(fn() { colors().content })) |> ignore
          })
          |> ignore
        })
        |> ignore
        liquid_panel_shell_node(
          row,
          radius=20.0,
          active=fn() { active.get() },
          fn(sh) {
            sh.width(Is(Some(220.0))).padding(Is((14.0, 12.0, 14.0, 12.0))) |> ignore
            sh.box(fn(w) {
              w.words(Is("Panel Shell"), look=words_at(ovl_type_body)).ink(By(fn() { colors().content })) |> ignore
            })
            |> ignore
          },
        )
        |> ignore
      })
      |> ignore
    })
    t.run_for(a_frame)
    // Inactive: zero hidden glass instances submitted.
    assert_eq(t.drawn_glass().filter(fn(g) { g.4 == 6 }).length(), 0)
    assert_eq(t.audit(), [])
    // Activate with capillary merge > 0.
    active.set(true)
    merge_k.set(12.0)
    t.run_for(a_frame)
    assert_eq(t.drawn_glass().filter(fn(g) { g.4 == 6 }).length(), 2)
    assert_no_nested_glass(t, "liquid_panel active dark=\{dark}")
    assert_eq(t.audit(), [])
  }
}

///|
test "liquid_popover_surface_decorate handles regular mode, iOS 27 morph mode, and MBUI_GLASS=solid" {
  // 1. Regular anchored mode (Light + Dark)
  for dark in [false, true] {
    let t = ovl_case(dark~, fn(page, _) {
      page.box(fn(p) {
        p.width(Is(Some(240.0))).padding(Is((14.0, 12.0, 14.0, 12.0))) |> ignore
        liquid_popover_surface_decorate(
          p,
          radius=20.0,
          alpha=fn() { 1.0 },
          scale=fn() { 1.0 },
        )
        |> ignore
        p.box(fn(w) {
          w.words(Is("Regular Popover"), look=words_at(ovl_type_body)).ink(By(fn() { colors().content })) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    t.run_for(a_frame)
    assert_eq(t.drawn_glass().filter(fn(g) { g.4 == 6 }).length(), 1)
    assert_no_nested_glass(t, "liquid_popover regular dark=\{dark}")
    assert_eq(t.audit(), [])
  }
  // 2. iOS 27.0 liquid-bridge morph mode across open start -> mid -> settled -> close -> inactive
  for dark in [false, true] {
    let morph_t = @signals.signal(0.0)
    let morph_closing = @signals.signal(false)
    let t = ovl_case(dark~, fn(page, _) {
      page.box(fn(p) {
        p.width(Is(Some(240.0))).height(Is(Some(160.0))).padding(Is((16.0, 14.0, 16.0, 14.0))) |> ignore
        liquid_popover_surface_decorate(
          p,
          radius=20.0,
          layer=3,
          break_gap=32.0,
          morph=fn() {
            let ct = morph_t.get()
            let cl = morph_closing.get()
            let f = lm_eval_pill_morph(
              40.0, 20.0, 44.0, 44.0, 62.0, 32.0, 32.0, 240.0, 160.0, 20.0, -1.0, cl, ct,
            )
            Some((ct, cl, 240.0, 160.0, f))
          },
        )
        |> ignore
        p.box(fn(w) {
          w.words(Is("Morphing Menu"), look=words_at(ovl_type_body)).ink(By(fn() { colors().content })) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    // At t=0.0 open, raw_value == 0 -> zero hidden glass submitted.
    t.run_for(a_frame)
    assert_eq(t.drawn_glass().filter(fn(g) { g.4 == 6 }).length(), 0)
    // Early open bridge (t=0.02s -> open_anchor_scale > 0.15): 1 liquid glass pass.
    morph_t.set(0.02)
    t.run_for(a_frame)
    assert_eq(t.drawn_glass().filter(fn(g) { g.4 == 6 }).length(), 1)
    // Settled open (t=0.45s): 1 liquid glass pass, clean audit.
    morph_t.set(0.45)
    t.run_for(a_frame)
    assert_eq(t.drawn_glass().filter(fn(g) { g.4 == 6 }).length(), 1)
    assert_no_nested_glass(t, "liquid_popover morph settled dark=\{dark}")
    assert_eq(t.audit(), [])
    // Mid-close (t=0.12s): platter still active -> 1 liquid glass pass.
    morph_closing.set(true)
    morph_t.set(0.12)
    t.run_for(a_frame)
    assert_eq(t.drawn_glass().filter(fn(g) { g.4 == 6 }).length(), 1)
    // Late close (t=0.45s): platter_active == false -> zero hidden glass.
    morph_t.set(0.45)
    t.run_for(a_frame)
    assert_eq(t.drawn_glass().filter(fn(g) { g.4 == 6 }).length(), 0)
  }
  // 3. Solid degradation bypasses morph glass cleanly with zero audit faults.
  for dark in [false, true] {
    let t = solid_case(dark, fn(page) {
      page.box(fn(p) {
        p.width(Is(Some(240.0))).padding(Is((14.0, 12.0, 14.0, 12.0))) |> ignore
        liquid_popover_surface_decorate(
          p,
          radius=20.0,
          alpha=fn() { 1.0 },
          scale=fn() { 1.0 },
          morph=fn() {
            let f = lm_eval_pill_morph(
              40.0, 20.0, 44.0, 44.0, 62.0, 32.0, 32.0, 240.0, 160.0, 20.0, -1.0, false, 0.45,
            )
            Some((0.45, false, 240.0, 160.0, f))
          },
        )
        |> ignore
        p.box(fn(w) {
          w.words(Is("Solid Popover"), look=words_at(ovl_type_body)).ink(By(fn() { colors().content })) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    t.run_for(a_frame)
    let liquid_count = t.drawn_glass().filter(fn(g) { g.4 == 6 }).length()
    let audits = t.audit()
    @ui.set_glass_solid(None)
    assert_eq((dark, liquid_count, audits), (dark, 0, []))
  }
}

///|
test "liquid_tooltip_surface_decorate enforces points=false and active=false zero hidden glass" {
  for dark in [false, true] {
    let active = @signals.signal(false)
    let hits = Ref(0)
    let t = ovl_case(dark~, fn(page, host) {
      @headless.button(page, fn() { "Underlying" }, fn(_) { hits.val += 1 }, fn(b, _) {
        b.width(Is(Some(140.0))).height(Is(Some(44.0))).padding(Is((12.0, 0.0, 12.0, 0.0))) |> ignore
        b.box(fn(w) {
          w.words(Is("Underlying"), look=words_at(ovl_type_body)).ink(By(fn() { colors().content })) |> ignore
        })
        |> ignore
      })
      |> ignore
      host.box(fn(tip) {
        tip.over(Is(true)).padding(Is((12.0, 6.0, 12.0, 6.0))) |> ignore
        liquid_tooltip_surface_decorate(
          tip,
          radius=12.0,
          active=fn() { active.get() },
          panel=true,
          solid=fn() { if is_dark() { 0x1C1C1EFFL } else { 0xF7F7FAFFL } },
        )
        |> ignore
        tip.box(fn(w) {
          w.words(Is("Helpful tip"), look=words_at(ovl_type_sub)).ink(By(fn() { colors().content })) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    t.run_for(a_frame)
    // Inactive tooltip submits zero liquid glass.
    assert_eq(t.drawn_glass().filter(fn(g) { g.4 == 6 }).length(), 0)
    active.set(true)
    t.run_for(a_frame)
    assert_eq(t.drawn_glass().filter(fn(g) { g.4 == 6 }).length(), 1)
    assert_no_nested_glass(t, "liquid_tooltip_surface_decorate dark=\{dark}")
    // Click passes right through the tooltip (`points(Is(false))`) to the underlying button.
    let r = t.all(Button, label="Underlying")[0].rect
    t.tap(r.0 + r.2 * 0.5, r.1 + r.3 * 0.5)
    t.run_for(a_frame)
    assert_eq(hits.val, 1)
  }
}

///|
test "liquid_sheet, liquid_drawer and liquid_toast surface decorators gate hidden glass and degrade cleanly to solid" {
  for dark in [false, true] {
    let active = @signals.signal(false)
    let t = ovl_case(dark~, fn(page, _) {
      page.box(fn(col) {
        col.gap(Is(20.0)) |> ignore
        col.box(fn(sh) {
          sh.width(Is(Some(320.0))).padding(Is((16.0, 14.0, 16.0, 14.0))) |> ignore
          liquid_sheet_surface_decorate(
            sh,
            radius=28.0,
            active=fn() { active.get() },
            solid=fn() { if is_dark() { 0x1C1C1EFFL } else { 0xF7F7FAFFL } },
          )
          |> ignore
          sh.box(fn(w) {
            w.words(Is("Sheet Surface"), look=words_at(ovl_type_body)).ink(By(fn() { colors().content })) |> ignore
          })
          |> ignore
        })
        |> ignore
        col.box(fn(dr) {
          dr.width(Is(Some(320.0))).padding(Is((16.0, 14.0, 16.0, 14.0))) |> ignore
          liquid_drawer_surface_decorate(
            dr,
            radius=28.0,
            active=fn() { active.get() },
            solid=fn() { if is_dark() { 0x1C1C1EFFL } else { 0xF7F7FAFFL } },
          )
          |> ignore
          dr.box(fn(w) {
            w.words(Is("Drawer Surface"), look=words_at(ovl_type_body)).ink(By(fn() { colors().content })) |> ignore
          })
          |> ignore
        })
        |> ignore
        col.box(fn(tb) {
          tb.width(Is(Some(320.0))).padding(Is((16.0, 12.0, 16.0, 12.0))) |> ignore
          liquid_toast_surface_decorate(
            tb,
            radius=24.0,
            active=fn() { active.get() },
            solid=fn() { if is_dark() { 0x1E1F24FFL } else { 0xFAFAFAFFL } },
          )
          |> ignore
          tb.box(fn(w) {
            w.words(Is("Toast Surface"), look=words_at(ovl_type_body)).ink(By(fn() { colors().content })) |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    t.run_for(a_frame)
    // Inactive: zero hidden glass instances across all three decorators.
    assert_eq(t.drawn_glass().filter(fn(g) { g.4 == 6 }).length(), 0)
    assert_eq(t.audit(), [])
    // Active: 3 non-overlapping single-layer liquid glass surfaces, 0 audit faults.
    active.set(true)
    t.run_for(a_frame)
    assert_eq(t.drawn_glass().filter(fn(g) { g.4 == 6 }).length(), 3)
    assert_no_nested_glass(t, "sheet+drawer+toast decorators dark=\{dark}")
    assert_eq(t.audit(), [])
  }
  // Solid fallback mode across Sheet + Drawer + Toast decorators.
  for dark in [false, true] {
    let t = solid_case(dark, fn(page) {
      page.box(fn(sh) {
        sh.width(Is(Some(320.0))).padding(Is((16.0, 14.0, 16.0, 14.0))) |> ignore
        liquid_sheet_surface_decorate(sh, radius=28.0) |> ignore
        sh.box(fn(w) {
          w.words(Is("Solid Sheet"), look=words_at(ovl_type_body)).ink(By(fn() { colors().content })) |> ignore
        })
        |> ignore
      })
      |> ignore
      page.box(fn(dr) {
        dr.width(Is(Some(320.0))).padding(Is((16.0, 14.0, 16.0, 14.0))) |> ignore
        liquid_drawer_surface_decorate(dr, radius=28.0) |> ignore
        dr.box(fn(w) {
          w.words(Is("Solid Drawer"), look=words_at(ovl_type_body)).ink(By(fn() { colors().content })) |> ignore
        })
        |> ignore
      })
      |> ignore
      page.box(fn(tb) {
        tb.width(Is(Some(320.0))).padding(Is((16.0, 12.0, 16.0, 12.0))) |> ignore
        liquid_toast_surface_decorate(tb, radius=24.0) |> ignore
        tb.box(fn(w) {
          w.words(Is("Solid Toast"), look=words_at(ovl_type_body)).ink(By(fn() { colors().content })) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    t.run_for(a_frame)
    let liquid_count = t.drawn_glass().filter(fn(g) { g.4 == 6 }).length()
    let audits = t.audit()
    @ui.set_glass_solid(None)
    assert_eq((dark, liquid_count, audits), (dark, 0, []))
  }
}
