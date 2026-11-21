// ui.monoid · Liquid Glass — 100% Self-Hosted Component Library Application (`MBUI_LG_PAGE=library`, the default).
// Every shell control (top NavBar, Dark/Light SegmentedControl, studio Menu, sidebar SearchBar, reactive category List,
// status ProgressRing, floating BottomTabs, and global overlay host) is built strictly from `@lg.*` components.
// Zero glass-on-glass: exhibition canvases sit directly on the optical wallpaper so each floating glass component
// refracts real colour fields and calibration hairlines behind it.

///|
/// Category metadata for the 6 exhibition sections (34 Liquid Glass components total).
priv struct LibCategory {
  id : Int
  name : String
  count : String
  subtitle : String
  keywords : String
}

///|
let lib_categories : Array[LibCategory] = [
  {
    id: 0,
    name: "Optics",
    count: "Lab",
    subtitle: "Prism & Shader",
    keywords: "optics prism glass shader refraction blur chroma inspector",
  },
  {
    id: 1,
    name: "Controls",
    count: "7",
    subtitle: "Buttons & Sliders",
    keywords: "controls button icon group segmented toggle slider stepper",
  },
  {
    id: 2,
    name: "Inputs",
    count: "8",
    subtitle: "Fields & Badges",
    keywords: "inputs text field search morph checkbox radio chip badge count",
  },
  {
    id: 3,
    name: "Navigation",
    count: "7",
    subtitle: "Bars, Lists & Deck",
    keywords: "navigation nav bar toolbar collapsible tabs list disclosure card control tile adaptive",
  },
  {
    id: 4,
    name: "Overlays",
    count: "9",
    subtitle: "Menus, Sheets & Toasts",
    keywords: "overlays menu select popover tooltip sheet action dialog toast progress bar ring",
  },
  {
    id: 5,
    name: "Physics",
    count: "3",
    subtitle: "Loupe & 360° Merge",
    keywords: "physics loupe magnifier progressive blur merge capillary droplet",
  },
]

///|
/// Accessible deep Monoid Vermilion & Cobalt with >= 4.5:1 contrast against white text even through translucent glass.
let lib_vermilion : Int64 = 0xA62908FFL

///|
let lib_cobalt : Int64 = 0x004EA8FFL

///|
/// Subtle uppercase section header with a trailing hairline rule (zero glass-on-glass).
fn lib_section_head(parent : @view.View, title : String, detail : String) -> Unit {
  parent.box(fn(hdr) {
    hdr.gap(Is(6.0)) |> ignore
    hdr.box(fn(row) {
      row.row(Is(true)).wraps(Is(Some(4.0))).lies_along(Is(Between)).lines_up(Is(Some(Middle))).gap(Is(12.0)) |> ignore
      row.box(fn(l) {
        l
        .words(Is(title), look={ ..@lg.words_at(11.0, weight=600), tracking: Points(0.9) })
        .ink(By(fn() { @lg.alpha(@lg.colors().content, 0.78) }))
        |> ignore
      })
      |> ignore
      if detail != "" {
        row.box(fn(r) {
          r
          .words(Is(detail), look=@lg.words_at(11.5, weight=500, wrap=true))
          .ink(By(fn() { @lg.alpha(@lg.colors().content, 0.70) }))
          |> ignore
        })
        |> ignore
      }
    })
    |> ignore
    hdr.box(fn(line) {
      line.height(Is(Some(1.0))).ground(By(fn() { @lg.alpha(@lg.colors().content, 0.12) })) |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// Small caption label above an inline control specimen.
fn lib_caption(parent : @view.View, text : String) -> Unit {
  parent.box(fn(w) {
    w
    .words(Is(text), look=@lg.words_at(12.0, weight=500))
    .ink(By(fn() { @lg.alpha(@lg.colors().content, 0.74) }))
    |> ignore
  })
  |> ignore
}

///|
/// Detached circular Liquid Glass Search/Catalog orb (`64×64`, `r=32`) paired beside the 4-tab main dock capsule
/// on compact mobile viewports (Apple iOS 26 Music / App Store / TV split-island bottom dock pattern).
/// Matches `tabs_glass()` material identically with `InteractiveHighlight` touch stretch & glow.
fn lib_dock_catalog_orb(parent : @view.View, is_open : () -> Bool, on_open : () -> Unit) -> Unit {
  @headless.button(parent, fn() { "Search & Catalog" }, fn(_) { on_open() }, fn(v, btn) {
    let light = @lg.InteractiveHighlight::new()
    light.attach(v)
    let orb_shape = fn(n : @view.View) -> @view.GroundShape {
      let (dx, dy, sx, sy) = light.stretch(n)
      if dx == 0.0 && dy == 0.0 && sx == 1.0 && sy == 1.0 {
        return @view.ground_as_laid
      }
      let dw = 64.0 * (sx - 1.0)
      let dh = 64.0 * (sy - 1.0)
      let r = (64.0 + dh) / 2.0
      { dx: dx - dw / 2.0, dy: dy - dh / 2.0, dw, dh, corners: Some((r, r, r, r)) }
    }
    v
    .width(Is(Some(64.0)))
    .height(Is(Some(64.0)))
    .shrink(Is(0.0))
    .radius(Is(32.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .shadow(Is(@lg.shadow_default))
    .shadow_outside(Is(true))
    .glass(By(fn() {
      let dark = @lg.is_dark()
      Some(
        @paint.Glass::liquid(
          blur=2.1,
          tint=if dark { 0x202020FFL } else { 0xFDFCFD67L },
          solid=if dark { 0x1E1F24FFL } else { 0xFAFAFAFFL },
          saturation=1.0,
          rim=0.6,
          bezel=20.0,
          refraction=28.0,
          chroma=0.0,
          merge=0.0,
          adaptive=false,
        ),
      )
    }))
    .ground_drawn(By(fn() { orb_shape(v) }))
    .gesture(
      @ui.touch_slop(),
      press=fn(d) { light.down(d.x, d.y, d.w, d.h) },
      tap=fn(_) {
        light.up()
        btn.press()
      },
      drag=fn(d) {
        match d.kind {
          Down | Moved => light.moved(d.x, d.y)
          Up => {
            light.up()
            if d.x >= 0.0 && d.x <= d.w && d.y >= 0.0 && d.y <= d.h {
              btn.press()
            }
          }
          Off => light.up()
        }
      },
    )
    |> ignore
    v.box(fn(ov) {
      ov
      .over(Is(true))
      .points(Is(false))
      .radius(Is(32.0))
      .ground(Is(@lg.white))
      .alpha(By(fn() { @lg.clamp(light.pressed(ov), 0.0, 1.0) * 0.14 }))
      .ground_drawn(By(fn() { orb_shape(ov) }))
      |> ignore
    })
    |> ignore
    v.box(fn(ic) {
      ic
      .points(Is(false))
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      .offset(By(fn() {
        let (dx, dy, _, _) = light.stretch(v)
        (dx, dy)
      }))
      .scale(By(fn() {
        let (_, _, sx, sy) = light.stretch(v)
        (sx + sy) / 2.0
      }))
      |> ignore
      icon_search(ic, 22.0, fn() { if is_open() { @lg.colors().accent } else { @lg.colors().content } })
    })
    |> ignore
    v.show(fn() { btn.focus_shown() }, fn(ring) {
      ring
      .over(Is(true))
      .points(Is(false))
      .margin(Is((-3.0, -3.0, -3.0, -3.0)))
      .radius(Is(35.0))
      .edge(By(fn() { (2.0, @lg.colors().accent) }))
      |> ignore
    })
  })
  |> ignore
}

///|
/// Floating Liquid Glass circular search/catalog button (36×36, r=18) for tablet portrait viewports in the top NavBar.
fn lib_nav_catalog_button(parent : @view.View, on_open : () -> Unit) -> Unit {
  @headless.button(parent, fn() { "Search & Catalog" }, fn(_) { on_open() }, fn(v, btn) {
    v
    .width(Is(Some(36.0)))
    .height(Is(Some(36.0)))
    .shrink(Is(0.0))
    .radius(Is(18.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .shadow(Is(@lg.shadow_default))
    .shadow_outside(Is(true))
    .glass(By(fn() {
      let dark = @lg.is_dark()
      Some(
        @paint.Glass::liquid(
          blur=2.1,
          tint=if dark { 0x202020FFL } else { 0xFDFCFD67L },
          solid=if dark { 0x1E1F24FFL } else { 0xFAFAFAFFL },
          saturation=1.0,
          rim=0.6,
          bezel=14.0,
          refraction=18.0,
          chroma=0.0,
          merge=0.0,
          adaptive=false,
        ),
      )
    }))
    |> ignore
    icon_search(v, 16.0, fn() { @lg.colors().content })
    v.show(fn() { btn.focus_shown() }, fn(ring) {
      ring
      .over(Is(true))
      .points(Is(false))
      .margin(Is((-3.0, -3.0, -3.0, -3.0)))
      .radius(Is(21.0))
      .edge(By(fn() { (2.0, @lg.colors().accent) }))
      |> ignore
    })
  })
  |> ignore
}

///|
/// Floating Liquid Glass circular trigger (36×36, r=18) for `@lg.liquid_menu_node` inside the
/// transparent floating-island `@lg.liquid_nav_bar_node` (single glass layer, zero glass-on-glass).
fn lib_nav_menu_trigger(v : @view.View, d : @headless.Disclosure) -> Unit {
  v
  .width(Is(Some(36.0)))
  .height(Is(Some(36.0)))
  .shrink(Is(0.0))
  .radius(Is(18.0))
  .lines_up(Is(Some(Middle)))
  .lies_along(Is(Middle))
  .shadow_outside(Is(true))
  .shadow(Is(@lg.shadow_default))
  .glass(By(fn() {
    let dark = @lg.is_dark()
    Some(
      @paint.Glass::liquid(
        blur=2.1,
        tint=if dark { 0x202020FFL } else { 0xFDFCFD67L },
        solid=if dark { 0x1E1F24FFL } else { 0xFAFAFAFFL },
        saturation=1.0,
        rim=0.6,
        bezel=14.0,
        refraction=18.0,
        chroma=0.0,
        merge=0.0,
        adaptive=false,
      ),
    )
  }))
  |> ignore
  icon_sliders(v, 16.0, fn() { @lg.colors().content })
  v.show(fn() { d.focus_shown() }, fn(ring) {
    ring
    .over(Is(true))
    .points(Is(false))
    .margin(Is((-3.0, -3.0, -3.0, -3.0)))
    .radius(Is(21.0))
    .edge(By(fn() { (2.0, @lg.colors().accent) }))
    |> ignore
  })
}

///|
/// Capsule trigger look for `@lg.liquid_menu_node` and `@lg.liquid_popover_node` on the exhibition canvas.
fn lib_glass_trigger(
  label : String,
  tint? : Int64 = @lg.clear,
  width? : Double,
) -> (@view.View, @headless.Disclosure) -> Unit {
  fn(v : @view.View, d : @headless.Disclosure) {
    let has_tint = tint != @lg.clear
    v
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .height(Is(Some(48.0)))
    .padding(Is((18.0, 0.0, 18.0, 0.0)))
    .gap(Is(8.0))
    .radius(Is(24.0))
    .shadow_outside(Is(true))
    .shadow(Is(@lg.shadow_default))
    .glass(By(fn() {
      let dark = @lg.is_dark()
      let g_tint = if has_tint {
        @lg.alpha(tint, if dark { 0.72 } else { 0.84 })
      } else if dark {
        0x202020FFL
      } else {
        0xFDFCFD67L
      }
      let solid = if has_tint {
        tint
      } else if dark {
        0x1E1F24FFL
      } else {
        0xFAFAFAFFL
      }
      Some(
        @paint.Glass::liquid(
          blur=2.1,
          tint=g_tint,
          solid~,
          saturation=1.0,
          rim=0.6,
          bezel=14.0,
          refraction=18.0,
          chroma=0.0,
          merge=0.0,
          adaptive=false,
        ),
      )
    }))
    |> ignore
    match width {
      Some(w) => v.width(Is(Some(w))) |> ignore
      None => ()
    }
    v.box(fn(w) {
      w
      .words(Is(label), look=@lg.words_at(15.0, weight=@lg.weight_medium))
      .ink(By(fn() { if has_tint { @lg.white } else { @lg.colors().content } }))
      |> ignore
    })
    |> ignore
    v.show(fn() { d.focus_shown() }, fn(ring) {
      ring
      .over(Is(true))
      .points(Is(false))
      .margin(Is((-3.0, -3.0, -3.0, -3.0)))
      .radius(Is(27.0))
      .edge(By(fn() { (2.0, @lg.colors().accent) }))
      |> ignore
    })
  }
}

///|
/// Section 1 — `Controls` (7 components): Button, IconButton, ButtonGroup, Segmented, Toggle, Slider, Stepper.
fn lib_controls_section(
  parent : @view.View,
  seg_idx : @signals.Signal[Int],
  icon_active : @signals.Signal[Bool],
  group_active : @signals.Signal[Int],
  toggle_a : @signals.Signal[Bool],
  toggle_b : @signals.Signal[Bool],
  bezel_val : @signals.Signal[Double],
  step_val : @signals.Signal[Int],
  last_evt : @signals.Signal[String],
) -> Unit {
  parent.box(fn(col) {
    col.gap(Is(20.0)) |> ignore
    // 1. Buttons & Icon Buttons
    col.box(fn(sec) {
      sec.gap(Is(12.0)) |> ignore
      lib_section_head(sec, "BUTTONS & ICON ACTIONS", "liquid_button · liquid_icon_button · liquid_button_group")
      sec.box(fn(row) {
        row.row(Is(true)).wraps(Is(Some(12.0))).gap(Is(12.0)).lines_up(Is(Some(Middle))) |> ignore
        @lg.liquid_button_node(row, fn() { "Transparent" }, fn() { last_evt.set("Transparent button") }) |> ignore
        @lg.liquid_button_node(
          row,
          fn() { "Surface" },
          fn() { last_evt.set("Surface button") },
          surface=0xFFFFFF4DL,
        )
        |> ignore
        @lg.liquid_button_node(
          row,
          fn() { "Publish" },
          fn() { last_evt.set("Publish tinted") },
          tint=lib_vermilion,
        )
        |> ignore
        @lg.liquid_button_node(
          row,
          fn() { "Deploy" },
          fn() { last_evt.set("Deploy tinted") },
          tint=lib_cobalt,
        )
        |> ignore
      })
      |> ignore
      sec.box(fn(row) {
        row.row(Is(true)).wraps(Is(Some(12.0))).gap(Is(14.0)).lines_up(Is(Some(Middle))) |> ignore
        @lg.liquid_icon_button_node(
          row,
          fn() { "Small Prism" },
          fn(ic, ink) { icon_prism(ic, 16.0, ink) },
          fn() { last_evt.set("Small icon") },
          size=Small,
        )
        |> ignore
        @lg.liquid_icon_button_node(
          row,
          fn() { "Toggle Boost" },
          fn(ic, ink) { icon_bolt(ic, 20.0, ink) },
          fn() {
            let next = !icon_active.untracked()
            icon_active.set(next)
            last_evt.set(if next { "Boost active" } else { "Boost idle" })
          },
          size=Regular,
          active=fn() { icon_active.get() },
          tint=lib_vermilion,
        )
        |> ignore
        @lg.liquid_icon_button_node(
          row,
          fn() { "Large Spark" },
          fn(ic, ink) { icon_spark(ic, 22.0, ink) },
          fn() { last_evt.set("Large icon") },
          size=Large,
        )
        |> ignore
        @lg.liquid_button_group_node(
          row,
          fn() {
            [
              @lg.LiquidGroupAction::new(
                label=fn() { "Group Prism" },
                icon=fn(ic, ink) { icon_prism(ic, 18.0, ink) },
                press=fn() {
                  group_active.set(0)
                  last_evt.set("Tool: Prism")
                },
                active=fn() { group_active.get() == 0 },
              ),
              @lg.LiquidGroupAction::new(
                label=fn() { "Group Grid" },
                icon=fn(ic, ink) { icon_grid(ic, 18.0, ink) },
                press=fn() {
                  group_active.set(1)
                  last_evt.set("Tool: Grid")
                },
                active=fn() { group_active.get() == 1 },
              ),
              @lg.LiquidGroupAction::new(
                label=fn() { "Group Layers" },
                icon=fn(ic, ink) { icon_layers(ic, 18.0, ink) },
                press=fn() {
                  group_active.set(2)
                  last_evt.set("Tool: Layers")
                },
                active=fn() { group_active.get() == 2 },
              ),
            ]
          },
          size=Regular,
        )
        |> ignore
      })
      |> ignore
    })
    |> ignore

    // 2. Segmented Control & Stepper
    col.box(fn(sec) {
      sec.gap(Is(12.0)) |> ignore
      lib_section_head(sec, "SEGMENTED LENS & STEPPER", "liquid_segmented · liquid_stepper")
      sec.box(fn(row) {
        row.row(Is(true)).wraps(Is(Some(12.0))).gap(Is(20.0)).lines_up(Is(Some(Middle))) |> ignore
        row.box(fn(seg_col) {
          seg_col.gap(Is(6.0)) |> ignore
          lib_caption(seg_col, "Drag refractive lens across segments")
          @lg.liquid_segmented_node(
            seg_col,
            fn() { ["Glass", "Clear", "Tinted"] },
            fn() { seg_idx.get() },
            fn(i) {
              seg_idx.set(i)
              last_evt.set("Segment #\{i + 1}")
            },
            width=300.0,
          )
          |> ignore
        })
        |> ignore
        row.box(fn(st_col) {
          st_col.gap(Is(6.0)) |> ignore
          lib_caption(st_col, "Blur Radius Stepper")
          @lg.liquid_stepper_node(
            st_col,
            fn() { step_val.get() },
            fn(v) {
              step_val.set(v)
              last_evt.set("Blur \{v} pt")
            },
            min=0,
            max=24,
            step=2,
            label=fn() { "Blur Radius" },
            format=fn(v) { "\{v} pt" },
          )
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore

    // 3. Toggles & Slider
    col.box(fn(sec) {
      sec.gap(Is(12.0)) |> ignore
      lib_section_head(sec, "TOGGLES & CONTINUOUS SLIDER", "liquid_toggle · liquid_slider")
      sec.box(fn(row) {
        row.row(Is(true)).wraps(Is(Some(12.0))).gap(Is(24.0)).lines_up(Is(Some(Middle))) |> ignore
        row.box(fn(t1) {
          t1.row(Is(true)).gap(Is(10.0)).lines_up(Is(Some(Middle))) |> ignore
          @lg.liquid_toggle_node(t1, fn() { toggle_a.get() }, fn(v) { toggle_a.set(v) }, fn() { "Refraction" })
          |> ignore
          t1.box(fn(w) {
            w.words(Is("Refraction"), look=@lg.words_at(14.0, weight=500)).ink(By(fn() { @lg.colors().content }))
            |> ignore
          })
          |> ignore
        })
        |> ignore
        row.box(fn(t2) {
          t2.row(Is(true)).gap(Is(10.0)).lines_up(Is(Some(Middle))) |> ignore
          @lg.liquid_toggle_node(t2, fn() { toggle_b.get() }, fn(v) { toggle_b.set(v) }, fn() { "Specular Glint" })
          |> ignore
          t2.box(fn(w) {
            w.words(Is("Specular Glint"), look=@lg.words_at(14.0, weight=500)).ink(By(fn() { @lg.colors().content }))
            |> ignore
          })
          |> ignore
        })
        |> ignore
        row.box(fn(sl) {
          sl.grow(Is(1.0)).min_width(Is(Some(240.0))).max_width(Is(Some(360.0)), within=true) |> ignore
          param_slider(
            sl,
            "Bezel Depth",
            fn() { "\{bezel_val.get().round().to_int()} pt" },
            fn() { bezel_val.get() },
            fn(v) { bezel_val.set(v) },
            4.0,
            40.0,
          )
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore

    // Live interaction readout
    col.box(fn(stat) {
      stat.row(Is(true)).gap(Is(8.0)).lines_up(Is(Some(Middle))) |> ignore
      @lg.liquid_badge_node(stat, fn() { "Last action" }, tone=Neutral) |> ignore
      stat.box(fn(w) {
        w
        .words(By(fn() { last_evt.get() }), look=@lg.words_at(13.0, weight=500))
        .ink(By(fn() { @lg.alpha(@lg.colors().content, 0.78) }))
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// Section 2 — `Inputs` (7 components): TextField, SearchBar, Checkbox, RadioGroup, Chip, Badge, CountBadge.
fn lib_inputs_section(
  parent : @view.View,
  is_phone : () -> Bool,
  window_w : () -> Double,
  name_field : @ui.Field,
  err_field : @ui.Field,
  demo_search : @ui.Field,
  morph_search_field : @ui.Field,
  morph_search_open : @signals.Signal[Bool],
  cb_a : @signals.Signal[Bool],
  cb_b : @signals.Signal[Bool],
  cb_mixed : @signals.Signal[Bool],
  radio_idx : @signals.Signal[Int],
  chip_metal : @signals.Signal[Bool],
  chip_vulkan : @signals.Signal[Bool],
  chip_webgl : @signals.Signal[Bool],
  chip_beta_kept : @signals.Signal[Bool],
  badge_count : @signals.Signal[Int],
) -> Unit {
  let morph_w = fn() {
    let w = window_w()
    if w <= 0.0 || w >= 560.0 {
      352.0
    } else {
      @lg.clamp((w - 48.0).floor(), 240.0, 340.0)
    }
  }
  parent.box(fn(col) {
    col.gap(Is(20.0)) |> ignore
    // 1. TextField, SearchBar & iOS 26 Search Morph
    col.box(fn(sec) {
      sec.gap(Is(12.0)) |> ignore
      lib_section_head(sec, "TEXT FIELDS & SEARCH BAR", "liquid_text_field · liquid_search_bar · liquid_search_morph")
      sec.box(fn(row) {
        row
        .row(By(fn() { !is_phone() }))
        .wraps(By(fn() { if is_phone() { None } else { Some(12.0) } }))
        .gap(By(fn() { if is_phone() { 12.0 } else { 16.0 } }))
        .lines_up(By(fn() { if is_phone() { None } else { Some(Start) } }))
        |> ignore
        row.box(fn(f1) {
          f1.width(By(fn() { if is_phone() { None } else { Some(260.0) } })) |> ignore
          @lg.liquid_text_field_node(
            f1,
            name_field,
            placeholder="Glass shader name...",
            label=fn() { "Preset Name" },
            clearable=true,
            lead=fn(ic, ink) { icon_prism(ic, 16.0, ink) },
          )
          |> ignore
        })
        |> ignore
        row.box(fn(f2) {
          f2.width(By(fn() { if is_phone() { None } else { Some(240.0) } })) |> ignore
          @lg.liquid_text_field_node(
            f2,
            err_field,
            placeholder="e.g. 22.0",
            label=fn() { "Bezel Radius" },
            error=fn() { "Value must be >= 4 pt" },
            invalid=fn() { true },
          )
          |> ignore
        })
        |> ignore
        row.box(fn(f3) {
          f3
          .width(By(fn() { if is_phone() { None } else { Some(240.0) } }))
          .padding(By(fn() { if is_phone() { (0.0, 0.0, 0.0, 0.0) } else { (0.0, 22.0, 0.0, 0.0) } }))
          |> ignore
          @lg.liquid_search_bar_node(
            f3,
            demo_search,
            placeholder="Search tokens...",
            label=fn() { "Demo Search" },
          )
          |> ignore
        })
        |> ignore
      })
      |> ignore
      sec.box(fn(morph_col) {
        morph_col.gap(Is(8.0)) |> ignore
        lib_caption(morph_col, "Search Morph · tap orb to expand")
        morph_col.pick(morph_w, at_once=true, fn(slot, mw) {
          @lg.liquid_search_morph_node(
            slot,
            morph_search_field,
            fn() { morph_search_open.get() },
            fn(v) { morph_search_open.set(v) },
            width=mw,
            placeholder="Search Liquid Glass...",
            label=fn() { "Morph Search" },
            cancel_label=fn() { "Cancel Morph Search" },
          )
          |> ignore
        })
      })
      |> ignore
    })
    |> ignore

    // 2. Checkboxes & RadioGroup
    col.box(fn(sec) {
      sec.gap(Is(12.0)) |> ignore
      lib_section_head(sec, "CHECKBOXES & RADIO GROUP", "liquid_checkbox · liquid_radio_group")
      sec.box(fn(row) {
        row.row(Is(true)).wraps(Is(Some(12.0))).gap(Is(36.0)).lines_up(Is(Some(Start))) |> ignore
        row.box(fn(cbs) {
          cbs.gap(Is(10.0)) |> ignore
          @lg.liquid_checkbox_node(cbs, fn() { cb_a.get() }, fn(v) { cb_a.set(v) }, fn() { "Backdrop refraction" })
          |> ignore
          @lg.liquid_checkbox_node(cbs, fn() { cb_b.get() }, fn(v) { cb_b.set(v) }, fn() { "Chromatic dispersion" })
          |> ignore
          @lg.liquid_checkbox_node(
            cbs,
            fn() { false },
            fn(_) { cb_mixed.set(!cb_mixed.untracked()) },
            fn() { "Mixed layer overrides" },
            mixed=fn() { cb_mixed.get() },
          )
          |> ignore
        })
        |> ignore
        row.box(fn(rgs) {
          rgs.gap(Is(8.0)) |> ignore
          lib_caption(rgs, "Optical Transfer Profile")
          @lg.liquid_radio_group_node(
            rgs,
            fn() { ["iOS 27 Light", "iOS 27 Dark", "Clear Adaptive"] },
            fn() { radio_idx.get() },
            fn(i) { radio_idx.set(i) },
          )
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore

    // 3. Chips, Badges & CountBadge
    col.box(fn(sec) {
      sec.gap(Is(12.0)) |> ignore
      lib_section_head(sec, "CHIPS, BADGES & COUNTERS", "liquid_chip · liquid_badge · liquid_count_badge")
      sec.box(fn(chips) {
        chips.row(Is(true)).wraps(Is(Some(12.0))).gap(Is(10.0)).lines_up(Is(Some(Middle))) |> ignore
        @lg.liquid_chip_node(
          chips,
          fn() { "Metal" },
          fn() { chip_metal.set(!chip_metal.untracked()) },
          selected=fn() { chip_metal.get() },
          lead=fn(ic, ink) { icon_bolt(ic, 14.0, ink) },
          tint=lib_cobalt,
        )
        |> ignore
        @lg.liquid_chip_node(
          chips,
          fn() { "Vulkan" },
          fn() { chip_vulkan.set(!chip_vulkan.untracked()) },
          selected=fn() { chip_vulkan.get() },
          tint=lib_cobalt,
        )
        |> ignore
        @lg.liquid_chip_node(
          chips,
          fn() { "WebGL 2" },
          fn() { chip_webgl.set(!chip_webgl.untracked()) },
          selected=fn() { chip_webgl.get() },
          tint=lib_cobalt,
        )
        |> ignore
        chips.show(fn() { chip_beta_kept.get() }, fn(slot) {
          @lg.liquid_chip_node(
            slot,
            fn() { "Removable Tag" },
            fn() {  },
            toggleable=false,
            on_remove=fn() { chip_beta_kept.set(false) },
            remove_label=fn() { "Remove tag" },
          )
          |> ignore
        })
      })
      |> ignore
      sec.box(fn(badges) {
        badges.row(Is(true)).wraps(Is(Some(12.0))).gap(Is(10.0)).lines_up(Is(Some(Middle))) |> ignore
        @lg.liquid_badge_node(badges, fn() { "Neutral" }, tone=Neutral) |> ignore
        @lg.liquid_badge_node(badges, fn() { "Accent" }, tone=Accent, dot=true) |> ignore
        @lg.liquid_badge_node(badges, fn() { "Passing" }, tone=Success, dot=true) |> ignore
        @lg.liquid_badge_node(badges, fn() { "Warning" }, tone=Warning) |> ignore
        @lg.liquid_badge_node(badges, fn() { "Error" }, tone=Danger) |> ignore
        badges.box(fn(cnt_row) {
          cnt_row.row(Is(true)).gap(Is(8.0)).lines_up(Is(Some(Middle))).padding(Is((10.0, 0.0, 0.0, 0.0))) |> ignore
          @lg.liquid_stepper_node(
            cnt_row,
            fn() { badge_count.get() },
            fn(v) { badge_count.set(v) },
            min=0,
            max=120,
            step=10,
            label=fn() { "Badge Counter" },
            show_value=false,
          )
          |> ignore
          @lg.liquid_count_badge_node(cnt_row, fn() { badge_count.get() }, tone=Danger) |> ignore
          cnt_row.box(fn(w) {
            w
            .words(
              By(fn() {
                let c = badge_count.get()
                if c == 0 { "0 (auto-hidden)" } else { "count: \{c}" }
              }),
              look=@lg.words_at(12.0, weight=500),
            )
            .ink(By(fn() { @lg.alpha(@lg.colors().content, 0.68) }))
            |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// Section 3 — `Navigation` (6 components): NavBar, Toolbar, List, Disclosure, Card + ControlTile, AdaptiveSurface.
fn lib_navigation_section(
  parent : @view.View,
  is_phone : () -> Bool,
  is_nav_stack : () -> Bool,
  window_w : () -> Double,
  grid_on : @signals.Signal[Bool],
  boost : @signals.Signal[Bool],
  list_active : @signals.Signal[Int],
  disc_open : @signals.Signal[Bool],
  live_lum : @signals.Signal[Double],
  ctab_idx : @signals.Signal[Int],
  ctab_min : @signals.Signal[Bool],
  last_nav : @signals.Signal[String],
) -> Unit {
  let ctab_w = fn() {
    let w = window_w()
    if w <= 0.0 || w >= 560.0 {
      300.0
    } else {
      @lg.clamp((w - 122.0).floor(), 180.0, 280.0)
    }
  }
  parent.box(fn(col) {
    col.gap(Is(18.0)) |> ignore
    // 1. Embedded NavBar, Toolbar & iOS 26 Collapsible Tabs
    col.box(fn(sec) {
      sec.gap(Is(12.0)) |> ignore
      lib_section_head(sec, "NAVIGATION BAR & TOOLBAR", "liquid_nav_bar · liquid_toolbar · liquid_collapsible_tabs")
      @lg.liquid_nav_bar_node(
        sec,
        fn() { "Optical Inspector" },
        subtitle=fn() { if is_phone() { "Metal · WebGL" } else { "Metal · WebGL 2" } },
        compact=is_phone,
        leading=fn(s) {
          @lg.liquid_icon_button_node(
            s,
            fn() { "Inspector Prism" },
            fn(ic, ink) { icon_prism(ic, 16.0, ink) },
            fn() { last_nav.set("Nav island: Prism") },
            size=Small,
          )
          |> ignore
          s.show(fn() { !is_phone() }, at_once=true, fn(slot) {
            @lg.liquid_badge_node(slot, fn() { "Live" }, tone=Success, dot=true) |> ignore
          })
        },
        trailing=fn(s) {
          s.show(fn() { !is_phone() }, at_once=true, fn(slot) {
            @lg.liquid_badge_node(slot, fn() { "60 fps" }, tone=Neutral) |> ignore
          })
          @lg.liquid_icon_button_node(
            s,
            fn() { "Inspector Refresh" },
            fn(ic, ink) { icon_refresh(ic, 16.0, ink) },
            fn() { last_nav.set("Nav island: Refresh") },
            size=Small,
          )
          |> ignore
        },
      )
      |> ignore
      sec.box(fn(tb_row) {
        tb_row.row(Is(true)).wraps(Is(Some(12.0))).gap(Is(14.0)).lines_up(Is(Some(Middle))) |> ignore
        @lg.liquid_toolbar_node(tb_row, fn(tb) {
          tb.box(fn(w) {
            w.words(Is("Quick Tools"), look=@lg.words_at(13.0, weight=500)).ink(By(fn() { @lg.colors().content }))
            |> ignore
          })
          |> ignore
          @lg.liquid_badge_node(tb, fn() { "3 Active" }, tone=Accent) |> ignore
        })
        |> ignore
        tb_row.box(fn(w) {
          w
          .words(By(fn() { last_nav.get() }), look=@lg.words_at(12.5, weight=500))
          .ink(By(fn() { @lg.alpha(@lg.colors().content, 0.72) }))
          |> ignore
        })
        |> ignore
      })
      |> ignore
      sec.box(fn(ct_col) {
        ct_col.gap(Is(8.0)) |> ignore
        ct_col.box(fn(ct_hdr) {
          ct_hdr.row(Is(true)).wraps(Is(Some(8.0))).gap(Is(12.0)).lines_up(Is(Some(Middle))) |> ignore
          lib_caption(ct_hdr, "Collapsible Tabs · minimize to orb")
          @lg.liquid_button_node(
            ct_hdr,
            fn() { if ctab_min.get() { "Expand" } else { "Minimize" } },
            fn() { ctab_min.set(!ctab_min.untracked()) },
            flat=true,
          )
          |> ignore
        })
        |> ignore
        ct_col.pick(ctab_w, at_once=true, fn(slot, ew) {
          @lg.liquid_collapsible_tabs_node(
            slot,
            ["Home", "Browse", "Radio"],
            fn() { ctab_idx.get() },
            fn(i) {
              ctab_idx.set(i)
              let name = match i {
                0 => "Home"
                1 => "Browse"
                _ => "Radio"
              }
              last_nav.set("Collapsible tab: \{name}")
            },
            fn() { ctab_min.get() },
            fn() {
              ctab_min.set(false)
              last_nav.set("Collapsible tabs expanded")
            },
            fn() { last_nav.set("Collapsible tab: Search") },
            action_label=fn() { "Collapsible Search" },
            compact_icons=[
              fn(ic, ink) { icon_prism(ic, 22.0, ink) },
              fn(ic, ink) { icon_grid(ic, 22.0, ink) },
              fn(ic, ink) { icon_spark(ic, 22.0, ink) },
            ],
            label="Collapsible Tabs",
            expanded_width=ew,
          )
          |> ignore
        })
      })
      |> ignore
    })
    |> ignore

    // 2. Two-column List + Disclosure on left, Control Center + Adaptive Surface on right
    col.box(fn(split) {
      split
      .row(By(fn() { !is_nav_stack() }))
      .gap(Is(20.0))
      .lines_up(By(fn() { if is_nav_stack() { None } else { Some(Start) } }))
      |> ignore
      split.box(fn(left) {
        left
        .grow(By(fn() { if is_nav_stack() { 0.0 } else { 1.0 } }))
        .min_width(Is(Some(0.0)))
        .gap(Is(14.0))
        |> ignore
        lib_section_head(left, "LIST & DISCLOSURE", "liquid_list · liquid_disclosure")
        @lg.liquid_list_node(
          left,
          fn() {
            let cur = list_active.get()
            [
              @lg.LiquidListRow::new(
                title="GPU Backend",
                subtitle="Single retained render pass",
                value="Metal / WebGL 2",
                icon=fn(ic, ink) { icon_bolt(ic, 16.0, ink) },
                chevron=true,
                active=cur == 0,
                on_press=fn() {
                  list_active.set(0)
                  last_nav.set("Selected: GPU Backend")
                },
              ),
              @lg.LiquidListRow::new(
                title="Concentric Audit",
                subtitle="Strict corners & contrast",
                value="0 faults",
                icon=fn(ic, ink) { icon_grid(ic, 16.0, ink) },
                chevron=true,
                active=cur == 1,
                on_press=fn() {
                  list_active.set(1)
                  last_nav.set("Selected: Concentric Audit")
                },
              ),
              @lg.LiquidListRow::new(
                title="Closed-Form Springs",
                value="7–120 fps",
                icon=fn(ic, ink) { icon_spark(ic, 16.0, ink) },
                chevron=true,
                active=cur == 2,
                on_press=fn() {
                  list_active.set(2)
                  last_nav.set("Selected: Closed-Form Springs")
                },
              ),
            ]
          },
          header=fn() { "ENGINE CAPABILITIES" },
        )
        |> ignore
        @lg.liquid_disclosure_node(
          left,
          fn() { "MoonBit API Snippet" },
          fn() { disc_open.get() },
          fn(v) { disc_open.set(v) },
          fn(c) {
            c.box(fn(w) {
              w
              .words(
                Is("@lg.liquid_nav_bar_node(root, fn() { \"Studio\" })\n@lg.liquid_list_node(root, fn() { rows })"),
                look=@lg.words_at(12.0, weight=500, wrap=true),
              )
              .ink(By(fn() { @lg.colors().content }))
              |> ignore
            })
            |> ignore
          },
          subtitle=fn() { "Expand to inspect live usage" },
        )
        |> ignore
      })
      |> ignore

      split.box(fn(right) {
        right
        .width(By(fn() { if is_nav_stack() { None } else { Some(320.0) } }))
        .shrink(By(fn() { if is_nav_stack() { 1.0 } else { 0.0 } }))
        .gap(Is(14.0))
        |> ignore
        lib_section_head(right, "DECK & ADAPTIVE", "card · tiles · adaptive")
        right.box(fn(deck_row) {
          deck_row.row(Is(true)).wraps(Is(Some(12.0))).gap(Is(14.0)).lines_up(Is(Some(Middle))) |> ignore
          let wide = @lg.tile_size * 2.0 + @lg.tile_gap
          @lg.liquid_card_node(
            deck_row,
            wide,
            wide,
            fn() { "Library deck" },
            radius=@lg.tile_inner / 2.0 + @lg.tile_gap,
            press=fn() {  },
            content=fn(c) {
              c.padding(Is((@lg.tile_gap, @lg.tile_gap, @lg.tile_gap, @lg.tile_gap))).lies_along(Is(Between)) |> ignore
              c.box(fn(rr) {
                rr.row(Is(true)).lies_along(Is(Between)) |> ignore
                @lg.liquid_control_item_node(
                  rr,
                  fn() { @lg.is_dark() },
                  fn(v) { @lg.set_dark(Some(v)) },
                  fn() { "Deck Theme" },
                  icon=fn(box, _ink) {
                    let ink = fn() { if @lg.is_dark() { @lg.white } else { 0x1C2430D9L } }
                    box.pick(fn() { @lg.is_dark() }, at_once=true, fn(inner, d) {
                      if d { icon_moon(inner, 24.0, ink) } else { icon_sun(inner, 24.0, ink) }
                    })
                  },
                )
                |> ignore
                @lg.liquid_control_item_node(
                  rr,
                  fn() { grid_on.get() },
                  fn(v) { grid_on.set(v) },
                  fn() { "Deck Grid" },
                  icon=fn(box, _ink) {
                    icon_grid(box, 24.0, fn() { if grid_on.get() || @lg.is_dark() { @lg.white } else { 0x1C2430D9L } })
                  },
                )
                |> ignore
              })
              |> ignore
              c.box(fn(rr) {
                rr.row(Is(true)).lies_along(Is(Between)) |> ignore
                @lg.liquid_control_item_node(
                  rr,
                  fn() { boost.get() },
                  fn(v) { boost.set(v) },
                  fn() { "Deck Glow" },
                  icon=fn(box, _ink) {
                    icon_bolt(box, 24.0, fn() { if boost.get() || @lg.is_dark() { @lg.white } else { 0x1C2430D9L } })
                  },
                )
                |> ignore
                @lg.liquid_control_item_node(
                  rr,
                  fn() { false },
                  fn(_) { last_nav.set("Deck pulse") },
                  fn() { "Deck Pulse" },
                  icon=fn(box, _ink) {
                    icon_play(box, 22.0, fn() { if @lg.is_dark() { @lg.white } else { 0x1C2430D9L } })
                  },
                )
                |> ignore
              })
              |> ignore
            },
          )
          |> ignore
          right_tile_stack(deck_row, last_nav)
        })
        |> ignore
        param_slider(
          right,
          "Backdrop Luminance",
          fn() { fmt_unit(live_lum.get()) },
          fn() { live_lum.get() },
          fn(v) { live_lum.set(v) },
          0.0,
          100.0,
        )
        right.box(fn(plate) {
          plate
          .height(Is(Some(148.0)))
          .radius(Is(24.0))
          .lines_up(Is(Some(Middle)))
          .lies_along(Is(Middle))
          .ground(By(fn() { @lg.lerp_color(0x14151BFFL, 0xF5F3EEFFL, @lg.clamp(live_lum.get() / 100.0, 0.0, 1.0)) }))
          |> ignore
          plate_stripes(
            plate,
            24.0,
            fn() { @lg.lerp_color(0x2A2D38FFL, 0xDDD8CEFFL, @lg.clamp(live_lum.get() / 100.0, 0.0, 1.0)) },
            20.0,
            22.0,
          )
          @lg.liquid_adaptive_surface_node(plate, fn() { @lg.clamp(live_lum.get() / 100.0, 0.0, 1.0) }, size=116.0)
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// Helper for two vertical `liquid_control_tile_node` tiles beside the 2×2 control card.
fn right_tile_stack(parent : @view.View, last_nav : @signals.Signal[String]) -> Unit {
  parent.box(fn(col) {
    col.gap(Is(@lg.tile_gap)) |> ignore
    let ink = fn() { if @lg.is_dark() { @lg.white } else { 0x1C2430E6L } }
    @lg.liquid_control_tile_node(
      col,
      fn() { "Tile Play" },
      fn() { last_nav.set("Tile: Play") },
      icon=fn(box, _ink) { icon_play(box, 24.0, ink) },
    )
    |> ignore
    @lg.liquid_control_tile_node(
      col,
      fn() { "Tile Reset" },
      fn() { last_nav.set("Tile: Reset") },
      angle=135.0,
      icon=fn(box, _ink) { icon_refresh(box, 24.0, ink) },
    )
    |> ignore
  })
  |> ignore
}

///|
/// Section 4 — `Overlays` (9 components): Menu, Select, Popover, Tooltip, Sheet, ActionSheet, Dialog, Toast,
/// ProgressBar & ProgressRing. All floating panels mount on `overlay_host` at root Z-order.
fn lib_overlays_section(
  parent : @view.View,
  overlay_host : @view.View,
  demo_menu_open : @signals.Signal[Bool],
  demo_menu_pin : @signals.Signal[Bool],
  select_idx : @signals.Signal[Int],
  popover_open : @signals.Signal[Bool],
  sheet_open : @signals.Signal[Bool],
  action_sheet_open : @signals.Signal[Bool],
  dialog_open : @signals.Signal[Bool],
  toast_visible : @signals.Signal[Bool],
  toast_status_idx : @signals.Signal[Int],
  prog_val : @signals.Signal[Double],
  prog_indet : @signals.Signal[Bool],
  last_ovl : @signals.Signal[String],
) -> Unit {
  parent.box(fn(col) {
    col.gap(Is(20.0)) |> ignore
    // 1. Anchored overlays: Menu, Select, Popover, Tooltip
    col.box(fn(sec) {
      sec.gap(Is(12.0)) |> ignore
      lib_section_head(sec, "ANCHORED OVERLAYS", "liquid_menu · liquid_select · liquid_popover · liquid_tooltip")
      sec.box(fn(row) {
        row.row(Is(true)).wraps(Is(Some(12.0))).gap(Is(12.0)).lines_up(Is(Some(Middle))) |> ignore
        @lg.liquid_menu_node(
          row,
          overlay_host,
          fn() { demo_menu_open.get() },
          fn(v) { demo_menu_open.set(v) },
          fn() { "Open Menu" },
          lib_glass_trigger("Open Menu", width=116.0),
          fn() {
            [
              @lg.LiquidMenuEntry::item(
                label="Duplicate Preset",
                shortcut="⌘D",
                icon=fn(ic, ink) { icon_layers(ic, 15.0, ink) },
                on_select=fn() { last_ovl.set("Menu: Duplicate Preset") },
              ),
              @lg.LiquidMenuEntry::check(
                label="Pin Inspector",
                shortcut="⌘P",
                checked=fn() { demo_menu_pin.get() },
                on_toggle=fn() {
                  let next = !demo_menu_pin.untracked()
                  demo_menu_pin.set(next)
                  last_ovl.set(if next { "Menu: Pinned" } else { "Menu: Unpinned" })
                },
              ),
              @lg.LiquidMenuEntry::separator(),
              @lg.LiquidMenuEntry::item(
                label="Reset Shader",
                destructive=true,
                on_select=fn() { last_ovl.set("Menu: Reset Shader") },
              ),
            ]
          },
          menu_label=fn() { "Demo Menu" },
          anchor_size=(116.0, 48.0),
          trigger_face=fn(v) {
            v.box(fn(w) {
              w.words(Is("Open Menu"), look=@lg.words_at(15.0, weight=@lg.weight_medium)).ink(By(fn() { @lg.colors().content }))
              |> ignore
            })
            |> ignore
          },
        )
        |> ignore
        @lg.liquid_select_node(
          row,
          overlay_host,
          fn() {
            [
              @lg.LiquidSelectOption::new(label="iOS 27 Regular", detail="Balanced blur & rim"),
              @lg.LiquidSelectOption::new(label="iOS 27 Clear", detail="High transparency"),
              @lg.LiquidSelectOption::new(label="Obsidian Dark", detail="Deep night tint"),
            ]
          },
          fn() { select_idx.get() },
          fn(i) {
            select_idx.set(i)
            last_ovl.set("Select: #\{i + 1}")
          },
          label=fn() { "Material" },
          width=220.0,
        )
        |> ignore
        @lg.liquid_popover_node(
          row,
          overlay_host,
          fn() { popover_open.get() },
          fn(v) { popover_open.set(v) },
          fn() { "Open Popover" },
          lib_glass_trigger("Popover", width=100.0),
          fn() { "Shader Telemetry" },
          fn(c) {
            c.gap(Is(8.0)) |> ignore
            c.box(fn(w) {
              w
              .words(Is("Optical Pipeline"), look=@lg.words_at(14.0, weight=600))
              .ink(By(fn() { @lg.colors().content }))
              |> ignore
            })
            |> ignore
            c.box(fn(w) {
              w
              .words(
                Is("Single-pass SDF bevel refraction with shared backdrop capture."),
                look=@lg.words_at(13.0, wrap=true),
              )
              .ink(By(fn() { @lg.alpha(@lg.colors().content, 0.78) }))
              |> ignore
            })
            |> ignore
          },
          placement=BelowStart,
          anchor_size=(100.0, 48.0),
          trigger_face=fn(v) {
            v.box(fn(w) {
              w.words(Is("Popover"), look=@lg.words_at(15.0, weight=@lg.weight_medium)).ink(By(fn() { @lg.colors().content }))
              |> ignore
            })
            |> ignore
          },
        )
        |> ignore
        @lg.liquid_tooltip_node(
          row,
          overlay_host,
          fn() { "Rendered directly on GPU via @paint.Glass::liquid" },
          fn(wrap) {
            @lg.liquid_button_node(wrap, fn() { "Hover Tooltip" }, fn() { last_ovl.set("Tooltip trigger tapped") })
            |> ignore
          },
        )
        |> ignore
      })
      |> ignore
    })
    |> ignore

    // 2. Modal overlays: Sheet, ActionSheet, Dialog
    col.box(fn(sec) {
      sec.gap(Is(12.0)) |> ignore
      lib_section_head(sec, "MODAL SHEETS & DIALOG", "liquid_sheet · liquid_action_sheet · liquid_dialog")
      sec.box(fn(row) {
        row.row(Is(true)).wraps(Is(Some(12.0))).gap(Is(12.0)).lines_up(Is(Some(Middle))) |> ignore
        @lg.liquid_button_node(
          row,
          fn() { "Open Sheet" },
          fn() { sheet_open.set(true) },
          tint=lib_vermilion,
        )
        |> ignore
        @lg.liquid_button_node(
          row,
          fn() { "Action Sheet" },
          fn() { action_sheet_open.set(true) },
          surface=0xFFFFFF4DL,
        )
        |> ignore
        @lg.liquid_button_node(row, fn() { "Open Dialog" }, fn() { dialog_open.set(true) }) |> ignore
        row.box(fn(w) {
          w
          .words(By(fn() { last_ovl.get() }), look=@lg.words_at(12.5, weight=500))
          .ink(By(fn() { @lg.alpha(@lg.colors().content, 0.72) }))
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore

    // 3. Feedback: Toast + ProgressBar & ProgressRing
    col.box(fn(sec) {
      sec.gap(Is(12.0)) |> ignore
      lib_section_head(sec, "TOAST & PROGRESS", "liquid_toast · liquid_progress_bar · liquid_progress_ring")
      sec.box(fn(row) {
        row.row(Is(true)).wraps(Is(Some(12.0))).gap(Is(14.0)).lines_up(Is(Some(Middle))) |> ignore
        @lg.liquid_segmented_node(
          row,
          fn() { ["Info", "Success", "Warning", "Error"] },
          fn() { toast_status_idx.get() },
          fn(i) {
            toast_status_idx.set(i)
            toast_visible.set(true)
          },
          width=380.0,
          height=38.0,
        )
        |> ignore
        @lg.liquid_button_node(
          row,
          fn() { if toast_visible.get() { "Hide Toast" } else { "Show Toast" } },
          fn() { toast_visible.set(!toast_visible.untracked()) },
        )
        |> ignore
      })
      |> ignore
      sec.box(fn(toast_slot) {
        toast_slot.max_width(Is(Some(480.0))) |> ignore
        toast_slot.pick(fn() { toast_status_idx.get() }, at_once=true, fn(slot, idx) {
          let (st, title, sub) = match idx {
            1 => (@lg.LiquidStatus::Success, "Bundle compiled", "Metal + WebGL ready")
            2 => (@lg.LiquidStatus::Warning, "High refraction", "Bezel depth > 32 pt")
            3 => (@lg.LiquidStatus::Error, "Shader fallback", "Using solid fallback")
            _ => (@lg.LiquidStatus::Info, "Liquid Glass synced", "34 parts at 60 fps")
          }
          @lg.liquid_toast_node(
            slot,
            fn() { toast_visible.get() },
            fn() { title },
            subtitle=fn() { sub },
            status=st,
            action_label=fn() { "Inspect" },
            on_action=fn() { last_ovl.set("Toast action: \{title}") },
            on_dismiss=fn() { toast_visible.set(false) },
          )
          |> ignore
        })
      })
      |> ignore
      sec.box(fn(prow) {
        prow.row(Is(true)).wraps(Is(Some(12.0))).gap(Is(20.0)).lines_up(Is(Some(Middle))) |> ignore
        prow.box(fn(pb) {
          pb.grow(Is(1.0)).min_width(Is(Some(220.0))).max_width(Is(Some(280.0)), within=true).gap(Is(10.0)) |> ignore
          @lg.liquid_progress_bar_node(
            pb,
            fn() { if prog_indet.get() { None } else { Some(prog_val.get() / 100.0) } },
            label=fn() { "GPU Pipeline" },
            show_value=true,
          )
          |> ignore
          @lg.liquid_slider_node(
            pb,
            fn() { prog_val.get() },
            fn(v) {
              prog_indet.set(false)
              prog_val.set(v)
            },
            fn() { "Progress Value" },
            least=0.0,
            most=100.0,
          )
          |> ignore
        })
        |> ignore
        @lg.liquid_progress_ring_node(
          prow,
          fn() { if prog_indet.get() { None } else { Some(prog_val.get() / 100.0) } },
          size=44.0,
          stroke=4.0,
          label=fn() { "Pipeline Ring" },
        )
        |> ignore
        prow.box(fn(ind) {
          ind.row(Is(true)).gap(Is(10.0)).lines_up(Is(Some(Middle))) |> ignore
          @lg.liquid_toggle_node(ind, fn() { prog_indet.get() }, fn(v) { prog_indet.set(v) }, fn() { "Indeterminate" })
          |> ignore
          ind.box(fn(w) {
            w.words(Is("Indeterminate"), look=@lg.words_at(13.5, weight=500)).ink(By(fn() { @lg.colors().content }))
            |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// Section 5 — `Physics` (3 components): Progressive Blur + 1.5× Optical Loupe, and 360° Capillary Merge,
/// switched cleanly via `@lg.liquid_segmented_node` so each stage has full breathing room.
fn lib_physics_section(
  parent : @view.View,
  phys_mode : @signals.Signal[Int],
  merge_ctrl : @lg.LiquidMerge,
) -> Unit {
  parent.box(fn(col) {
    col.grow(Is(1.0)).gap(Is(14.0)) |> ignore
    col.box(fn(bar) {
      bar.row(Is(true)).wraps(Is(Some(8.0))).lies_along(Is(Between)).lines_up(Is(Some(Middle))).gap(Is(12.0)) |> ignore
      @lg.liquid_segmented_node(
        bar,
        fn() { ["Loupe & Blur", "Capillary Merge"] },
        fn() { phys_mode.get() },
        fn(i) { phys_mode.set(i) },
        width=280.0,
        height=38.0,
      )
      |> ignore
      @lg.liquid_badge_node(
        bar,
        fn() { if phys_mode.get() == 0 { "1.5× Glyph Loupe" } else { "360° LiquidBond" } },
        tone=Accent,
        dot=true,
      )
      |> ignore
    })
    |> ignore
    col.box(fn(stage) {
      stage.grow(Is(1.0)) |> ignore
      stage.pick(fn() { phys_mode.get() }, at_once=true, fn(slot, m) {
        slot.grow(Is(1.0)) |> ignore
        if m == 1 {
          merge_scene(slot, merge_ctrl)
        } else {
          loupe_scene(slot)
        }
      })
    })
    |> ignore
  })
  |> ignore
}

///|
/// Category icon lookup for sidebar & bottom tabs.
fn lib_cat_icon(id : Int) -> (@view.View, Double, () -> Int64) -> Unit {
  match id {
    0 => icon_prism
    1 => icon_sliders
    2 => icon_terminal
    3 => icon_grid
    4 => icon_layers
    _ => icon_merge
  }
}

///|
/// Fullscreen 100% self-hosted `ui.monoid · Liquid Glass` Component Library application.
fn library_page(
  root : @view.View,
  grid_on : @signals.Signal[Bool],
  boost : @signals.Signal[Bool],
) -> Unit {
  let active_cat = @signals.signal(1)
  let sidebar_open = @signals.signal(true)
  let top_menu_open = @signals.signal(false)
  let search_field = @ui.Field::new()
  let search_q = @signals.signal("")

  // Optics state
  let refraction_val = @signals.signal(28.0)
  let chroma_val = @signals.signal(6.0)
  let blur_val = @signals.signal(1.8)
  let light_angle_val = @signals.signal(0.0)
  let prism_pos = @signals.signal((0.0, 0.0))

  // Controls state
  let seg_idx = @signals.signal(0)
  let icon_active = @signals.signal(true)
  let group_active = @signals.signal(0)
  let toggle_a = @signals.signal(true)
  let toggle_b = @signals.signal(false)
  let bezel_val = @signals.signal(22.0)
  let step_val = @signals.signal(8)
  let last_ctrl = @signals.signal("Ready · drag or tap any control")

  // Inputs state
  let name_field = @ui.Field::new(text="iOS 27 Prism")
  let err_field = @ui.Field::new(text="2")
  let demo_search = @ui.Field::new()
  let morph_search_field = @ui.Field::new()
  let morph_search_open = @signals.signal(false)
  let cb_a = @signals.signal(true)
  let cb_b = @signals.signal(false)
  let cb_mixed = @signals.signal(true)
  let radio_idx = @signals.signal(0)
  let chip_metal = @signals.signal(true)
  let chip_vulkan = @signals.signal(false)
  let chip_webgl = @signals.signal(true)
  let chip_beta_kept = @signals.signal(true)
  let badge_count = @signals.signal(12)

  // Navigation state
  let list_active = @signals.signal(0)
  let disc_open = @signals.signal(false)
  let live_lum = @signals.signal(84.0)
  let ctab_idx = @signals.signal(0)
  let ctab_min = @signals.signal(false)
  let last_nav = @signals.signal("Tap a row or expand disclosure")

  // Overlays state
  let demo_menu_open = @signals.signal(false)
  let demo_menu_pin = @signals.signal(true)
  let select_idx = @signals.signal(0)
  let popover_open = @signals.signal(false)
  let sheet_open = @signals.signal(false)
  let action_sheet_open = @signals.signal(false)
  let dialog_open = @signals.signal(false)
  let toast_visible = @signals.signal(true)
  let toast_status_idx = @signals.signal(1)
  let prog_val = @signals.signal(68.0)
  let prog_indet = @signals.signal(false)
  let last_ovl = @signals.signal("All overlays mount in root Z-layer")

  // Physics state
  let phys_mode = @signals.signal(0)
  let merge_ctrl = @lg.LiquidMerge::new(separated=false)

  let reset_demos = fn() {
    grid_on.set(true)
    boost.set(false)
    refraction_val.set(28.0)
    chroma_val.set(6.0)
    blur_val.set(1.8)
    light_angle_val.set(0.0)
    @ui.set_glass_light_angle(0.0)
    prism_pos.set((0.0, 0.0))
    seg_idx.set(0)
    icon_active.set(true)
    group_active.set(0)
    toggle_a.set(true)
    toggle_b.set(false)
    bezel_val.set(22.0)
    step_val.set(8)
    cb_a.set(true)
    cb_b.set(false)
    cb_mixed.set(true)
    radio_idx.set(0)
    chip_metal.set(true)
    chip_vulkan.set(false)
    chip_webgl.set(true)
    chip_beta_kept.set(true)
    badge_count.set(12)
    morph_search_open.set(false)
    morph_search_field.set("")
    list_active.set(0)
    disc_open.set(false)
    live_lum.set(84.0)
    ctab_idx.set(0)
    ctab_min.set(false)
    select_idx.set(0)
    toast_visible.set(true)
    toast_status_idx.set(1)
    prog_val.set(68.0)
    prog_indet.set(false)
    phys_mode.set(0)
    search_q.set("")
    last_ctrl.set("All demos reset")
    last_ovl.set("All demos reset")
  }

  let canvas_scroll = @view.Scroll::new()
  let catalog_scroll = @view.Scroll::new()
  let catalog_sheet_open = @signals.signal(false)
  let mobile_extra_cat = @signals.signal(5)
  root.reacts(at_start=false, fn() { active_cat.get() }, fn(cat) {
    if cat == 2 || cat == 3 || cat == 5 {
      mobile_extra_cat.set(cat)
    }
  })
  let is_narrow = fn() {
    let w = root.window_w()
    w > 0.0 && w < 820.0
  }
  let is_compact_dock = fn() {
    let w = root.window_w()
    w > 0.0 && w < 640.0
  }
  let is_phone = fn() {
    let w = root.window_w()
    w > 0.0 && w < 560.0
  }
  let is_nav_stack = fn() {
    let w = root.window_w()
    w > 0.0 && w < 760.0
  }
  let mobile_selected = fn() {
    match active_cat.get() {
      0 => 0
      1 => 1
      4 => 2
      _ => 3
    }
  }
  let mobile_select = fn(i : Int) {
    match i {
      0 => active_cat.set(0)
      1 => active_cat.set(1)
      2 => active_cat.set(4)
      _ => active_cat.set(mobile_extra_cat.get())
    }
  }

  let shell_ref : Ref[@view.View?] = Ref(None)
  let host_ref : Ref[@view.View?] = Ref(None)

  // Main layout shell mounted on `root` (locked to exact viewport bounds)
  root.box(fn(shell) {
    shell
    .over(Is(true))
    .padding(By(fn() {
      if is_phone() {
        (12.0, 10.0, 12.0, dock_room)
      } else {
        (20.0, 14.0, 20.0, dock_room)
      }
    }))
    .gap(By(fn() { if is_phone() { 10.0 } else { 16.0 } }))
    |> ignore
    shell_ref.val = Some(shell)
  })
  |> ignore

  // Floating bottom tabs (`@lg.liquid_bottom_tabs_node`, pinned 18pt from window bottom):
  // - Compact mobile (`w < 640`): iOS 26 split-island dock (spacious 4-tab capsule + 10pt gap + 64×64 Search/Catalog orb)
  // - Wide / desktop (`w >= 640`): full 600pt 6-tab capsule
  root.box(fn(dock_row) {
    dock_row
    .over(Is(true))
    .points(Is(false))
    .lies_along(Is(End))
    .lines_up(Is(Some(Middle)))
    .padding(Is((0.0, 0.0, 0.0, dock_gap)))
    |> ignore
    dock_row.show(is_compact_dock, at_once=true, fn(split_dock) {
      split_dock.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(10.0)).points(Is(false)) |> ignore
      split_dock.box(fn(dock_w) {
        dock_w
        .width(By(fn() {
          let w = root.window_w()
          let side_pad = if w > 0.0 && w < 380.0 { 12.0 } else { 14.0 }
          let avail = w - 2.0 * side_pad - 10.0 - 64.0
          Some(@lg.clamp(avail, 236.0, 320.0))
        }))
        .shrink(Is(0.0))
        .points(Is(true))
        |> ignore
        @lg.liquid_bottom_tabs_node(
          dock_w,
          ["Optics", "Controls", "Overlays", "More"],
          mobile_selected,
          mobile_select,
          label="Library sections",
          faces=[
            studio_tab_face_mobile("Optics", icon_prism),
            studio_tab_face_mobile("Controls", icon_sliders),
            studio_tab_face_mobile("Overlays", icon_layers),
            studio_tab_face_dynamic(fn() { mobile_extra_cat.get() }),
          ],
        )
        |> ignore
      })
      |> ignore
      lib_dock_catalog_orb(split_dock, fn() { catalog_sheet_open.get() }, fn() { catalog_sheet_open.set(true) })
    })
    dock_row.show(fn() { !is_compact_dock() }, at_once=true, fn(dock_w) {
      dock_w.width(Is(Some(600.0))).shrink(Is(0.0)).points(Is(true)) |> ignore
      @lg.liquid_bottom_tabs_node(
        dock_w,
        ["Optics", "Controls", "Inputs", "Nav", "Overlays", "Physics"],
        fn() { active_cat.get() },
        fn(i) { active_cat.set(i) },
        label="Library sections",
        faces=[
          studio_tab_face("Optics", icon_prism),
          studio_tab_face("Controls", icon_sliders),
          studio_tab_face("Inputs", icon_terminal),
          studio_tab_face("Nav", icon_grid),
          studio_tab_face("Overlays", icon_layers),
          studio_tab_face("Physics", icon_merge),
        ],
      )
      |> ignore
    })
  })
  |> ignore

  // Global root overlay host (strictly above shell & bottom dock)
  root.box(fn(host) {
    host.over(Is(true)).points(Is(false)) |> ignore
    host_ref.val = Some(host)
  })
  |> ignore

  let make_cat_rows = fn(close_sheet : Bool) {
    fn() {
      let q = search_q.get().to_lower()
      let cur = active_cat.get()
      let out : Array[@lg.LiquidListRow] = []
      for cat in lib_categories {
        let hit = q == "" || cat.name.to_lower().contains(q) || cat.keywords.contains(q)
        if hit {
          let cid = cat.id
          let icon_fn = lib_cat_icon(cid)
          out.push(
            @lg.LiquidListRow::new(
              title=cat.name,
              subtitle=cat.subtitle,
              value=cat.count,
              icon=fn(ic, ink) { icon_fn(ic, 16.0, ink) },
              active=cur == cid,
              on_press=fn() {
                active_cat.set(cid)
                if close_sheet {
                  catalog_sheet_open.set(false)
                }
              },
            ),
          )
        }
      }
      if out.length() == 0 {
        out.push(
          @lg.LiquidListRow::new(
            title="No matching parts",
            subtitle="Try menu, slider, toast, merge",
          ),
        )
      }
      out
    }
  }

  match (shell_ref.val, host_ref.val) {
    (Some(shell), Some(overlay_host)) => {
      // 1. Self-hosted Top Navigation Bar (`@lg.liquid_nav_bar_node`)
      @lg.liquid_nav_bar_node(
        shell,
        fn() { if is_phone() { "Liquid Glass" } else { "ui.monoid · Liquid Glass" } },
        subtitle=fn() { if is_phone() { "" } else { "iOS 27 Optical Component Library" } },
        compact=is_phone,
        leading=fn(s) {
          icon_brand_mark(s, 20.0, fn() { @lg.colors().content })
          s.show(fn() { !is_narrow() }, at_once=true, fn(slot) {
            @lg.liquid_badge_node(slot, fn() { "34 Components" }, tone=Accent, dot=true) |> ignore
          })
          s.show(fn() { is_narrow() && !is_compact_dock() }, at_once=true, fn(slot) {
            lib_nav_catalog_button(slot, fn() { catalog_sheet_open.set(true) })
          })
        },
        trailing=fn(s) {
          let theme_seg = @lg.liquid_segmented_node(
            s,
            fn() { ["Light", "Dark"] },
            fn() { if @lg.is_dark() { 1 } else { 0 } },
            fn(i) { @lg.set_dark(Some(i == 1)) },
            width=124.0,
            height=36.0,
          )
          theme_seg
          .width(By(fn() { if is_phone() { Some(96.0) } else { Some(124.0) } }))
          .max_width(By(fn() { if is_phone() { Some(96.0) } else { Some(124.0) } }), within=true)
          |> ignore
          @lg.liquid_menu_node(
            s,
            overlay_host,
            fn() { top_menu_open.get() },
            fn(v) { top_menu_open.set(v) },
            fn() { "Studio options" },
            lib_nav_menu_trigger,
            fn() {
              let nav_entry = if is_narrow() {
                @lg.LiquidMenuEntry::item(
                  label="Search & Catalog",
                  on_select=fn() { catalog_sheet_open.set(true) },
                )
              } else {
                @lg.LiquidMenuEntry::check(
                  label="Sidebar",
                  checked=fn() { sidebar_open.get() },
                  on_toggle=fn() { sidebar_open.set(!sidebar_open.untracked()) },
                )
              }
              [
                @lg.LiquidMenuEntry::check(
                  label="Calibration Grid",
                  checked=fn() { grid_on.get() },
                  on_toggle=fn() { grid_on.set(!grid_on.untracked()) },
                ),
                @lg.LiquidMenuEntry::check(
                  label="Ambient Glow",
                  checked=fn() { boost.get() },
                  on_toggle=fn() { boost.set(!boost.untracked()) },
                ),
                nav_entry,
                @lg.LiquidMenuEntry::separator(),
                @lg.LiquidMenuEntry::item(
                  label="Reset Demos",
                  on_select=reset_demos,
                ),
              ]
            },
            menu_label=fn() { "Studio Menu" },
            placement=BelowEnd,
            anchor_size=(36.0, 36.0),
            trigger_face=fn(v) { icon_sliders(v, 16.0, fn() { @lg.colors().content }) },
          )
          |> ignore
        },
      )
      |> ignore

      // 2. Body Row: Left Self-Hosted Sidebar (`264pt`, desktop only) + Right Interactive Exhibition Canvas
      shell.box(fn(body_row) {
        body_row
        .row(Is(true))
        .grow(Is(1.0))
        .basis(Is(Some(0.0)))
        .min_height(Is(Some(0.0)))
        .gap(By(fn() { if is_narrow() { 0.0 } else { 20.0 } }))
        |> ignore

        // Left floating glass sidebar (SearchBar + reactive category List + ProgressRing footer)
        body_row.show(fn() { !is_narrow() && sidebar_open.get() }, fn(side) {
          side.width(Is(Some(264.0))).shrink(Is(0.0)).gap(Is(12.0)).lies_along(Is(Between)) |> ignore
          side.box(fn(top_part) {
            top_part.gap(Is(12.0)) |> ignore
            @lg.liquid_search_bar_node(
              top_part,
              search_field,
              placeholder="Filter 34 parts...",
              label=fn() { "Filter components" },
              edited=fn(s) { search_q.set(s) },
              on_clear=fn() { search_q.set("") },
            )
            |> ignore
            @lg.liquid_list_node(
              top_part,
              make_cat_rows(false),
              header=fn() { "CATEGORIES · 34 PARTS" },
              dividers=false,
            )
            |> ignore
          })
          |> ignore

          // Sidebar footer status line
          side.box(fn(foot) {
            foot.row(Is(true)).gap(Is(10.0)).lines_up(Is(Some(Middle))).padding(Is((12.0, 4.0, 12.0, 4.0))) |> ignore
            @lg.liquid_progress_ring_node(
              foot,
              fn() { Some(1.0) },
              size=18.0,
              stroke=2.2,
              label=fn() { "Frame rate status" },
            )
            |> ignore
            foot.box(fn(w) {
              w
              .words(Is("60 fps · Apache-2.0"), look=@lg.words_at(12.0, weight=500))
              .ink(By(fn() { @lg.alpha(@lg.colors().content, 0.74) }))
              |> ignore
            })
            |> ignore
          })
          |> ignore
        })

        // Right Main Exhibition Canvas (reuses Optics / Loupe / Merge scenes; scrolls cleanly for dense galleries)
        body_row.box(fn(main_area) {
          main_area.grow(Is(1.0)).basis(Is(Some(0.0))).fills_across(Is(true)).min_height(Is(Some(0.0)))
          |> ignore
          main_area.pick(fn() { active_cat.get() }, at_once=true, fn(scene_slot, cat_id) {
            scene_slot.grow(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
            match cat_id {
              0 =>
                optics_scene(
                  scene_slot,
                  None,
                  grid_on,
                  refraction_val,
                  chroma_val,
                  blur_val,
                  light_angle_val,
                  prism_pos,
                  dialog_open,
                )
              5 => lib_physics_section(scene_slot, phys_mode, merge_ctrl)
              _ => {
                let sc = scene_slot.scrolls(
                  canvas_scroll,
                  slop=@ui.touch_slop(),
                  bar=@ui.tree_scroll_bar(),
                  fn(s) {
                    s.padding(By(fn() {
                      if is_phone() {
                        (8.0, 8.0, 8.0, 20.0)
                      } else {
                        (16.0, 14.0, 16.0, 24.0)
                      }
                    }))
                    |> ignore
                    match cat_id {
                      1 =>
                        lib_controls_section(
                          s,
                          seg_idx,
                          icon_active,
                          group_active,
                          toggle_a,
                          toggle_b,
                          bezel_val,
                          step_val,
                          last_ctrl,
                        )
                      2 =>
                        lib_inputs_section(
                          s,
                          is_phone,
                          fn() { root.window_w() },
                          name_field,
                          err_field,
                          demo_search,
                          morph_search_field,
                          morph_search_open,
                          cb_a,
                          cb_b,
                          cb_mixed,
                          radio_idx,
                          chip_metal,
                          chip_vulkan,
                          chip_webgl,
                          chip_beta_kept,
                          badge_count,
                        )
                      3 =>
                        lib_navigation_section(
                          s,
                          is_phone,
                          is_nav_stack,
                          fn() { root.window_w() },
                          grid_on,
                          boost,
                          list_active,
                          disc_open,
                          live_lum,
                          ctab_idx,
                          ctab_min,
                          last_nav,
                        )
                      _ =>
                        lib_overlays_section(
                          s,
                          overlay_host,
                          demo_menu_open,
                          demo_menu_pin,
                          select_idx,
                          popover_open,
                          sheet_open,
                          action_sheet_open,
                          dialog_open,
                          toast_visible,
                          toast_status_idx,
                          prog_val,
                          prog_indet,
                          last_ovl,
                        )
                    }
                  },
                )
                sc.grow(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
              }
            }
          })
        })
        |> ignore
      })
      |> ignore

      // 3. Global Modal Overlays mounted on `overlay_host`
      // Mobile & tablet catalog drawer (flat inner search + list -> strictly zero glass-on-glass inside sheet)
      @lg.liquid_sheet_node(
        overlay_host,
        fn() { catalog_sheet_open.get() },
        fn() { catalog_sheet_open.set(false) },
        fn() { "Components · 34 Parts" },
        fn(b) {
          let sc = b.scrolls(catalog_scroll, slop=@ui.touch_slop(), bar=@ui.tree_scroll_bar(), fn(col) {
            col.gap(Is(12.0)) |> ignore
            @lg.liquid_search_bar_node(
              col,
              search_field,
              placeholder="Filter 34 parts...",
              label=fn() { "Filter components" },
              edited=fn(s) { search_q.set(s) },
              on_clear=fn() { search_q.set("") },
              flat=true,
            )
            |> ignore
            @lg.liquid_list_node(
              col,
              make_cat_rows(true),
              header=fn() { "CATEGORIES · 34 PARTS" },
              dividers=false,
              flat=true,
            )
            |> ignore
            col.box(fn(foot) {
              foot.row(Is(true)).gap(Is(10.0)).lines_up(Is(Some(Middle))).padding(Is((8.0, 2.0, 8.0, 2.0))) |> ignore
              @lg.liquid_progress_ring_node(
                foot,
                fn() { Some(1.0) },
                size=18.0,
                stroke=2.2,
                label=fn() { "Frame rate status" },
              )
              |> ignore
              foot.box(fn(w) {
                w
                .words(Is("60 fps · Apache-2.0"), look=@lg.words_at(12.0, weight=500))
                .ink(By(fn() { @lg.alpha(@lg.colors().content, 0.74) }))
                |> ignore
              })
              |> ignore
            })
            |> ignore
          })
          sc.max_height(Is(Some(420.0))) |> ignore
        },
        width=420.0,
        max_height=560.0,
      )
      |> ignore

      @lg.liquid_sheet_node(
        overlay_host,
        fn() { sheet_open.get() },
        fn() { sheet_open.set(false) },
        fn() { "Optical Export Sheet" },
        fn(b) {
          b.gap(Is(10.0)) |> ignore
          b.box(fn(w) {
            w
            .words(
              Is("Detached floating Liquid Glass sheet with concentric grabber, dimmed scrim and Escape dismissal."),
              look=@lg.words_at(14.5, wrap=true),
            )
            .ink(By(fn() { @lg.colors().content }))
            |> ignore
          })
          |> ignore
          @lg.liquid_progress_bar_node(b, fn() { Some(0.82) }, label=fn() { "Metal Shader Cache" }, show_value=true)
          |> ignore
        },
        subtitle=fn() { "ui.monoid · 3× Offscreen Capture" },
        footer=fn(f) {
          f.row(Is(true)).lies_along(Is(End)).gap(Is(10.0)) |> ignore
          @lg.liquid_button_node(
            f,
            fn() { "Done" },
            fn() { sheet_open.set(false) },
            tint=lib_vermilion,
            flat=true,
          )
          |> ignore
        },
      )
      |> ignore

      @lg.liquid_action_sheet_node(
        overlay_host,
        fn() { action_sheet_open.get() },
        fn() { action_sheet_open.set(false) },
        fn() {
          [
            @lg.LiquidActionSheetItem::new(
              label="Copy MoonBit Snippet",
              on_select=fn() { last_ovl.set("ActionSheet: Copied snippet") },
            ),
            @lg.LiquidActionSheetItem::new(
              label="Export 3× PNG",
              on_select=fn() { last_ovl.set("ActionSheet: Exported PNG") },
            ),
            @lg.LiquidActionSheetItem::new(
              label="Clear Shader Cache",
              destructive=true,
              on_select=fn() { last_ovl.set("ActionSheet: Cache cleared") },
            ),
          ]
        },
        title=fn() { "Component Actions" },
        message=fn() { "Separated iOS Liquid Glass action group with independent Cancel capsule." },
      )
      |> ignore

      @lg.liquid_dialog_node(
        overlay_host,
        fn() { dialog_open.get() },
        fn() { dialog_open.set(false) },
        fn() { "Publish ui.monoid" },
        fn() { dialog_copy },
        cancel=fn() { "Cancel" },
        action=fn() { "Publish" },
        on_action=fn() {
          dialog_open.set(false)
          last_ovl.set("Dialog: Published")
        },
      )
      |> ignore
    }
    _ => ()
  }
}
