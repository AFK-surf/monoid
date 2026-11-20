// ui.monoid Liquid Glass Studio (src/gallery shows it in a window and on the web; src/shots draws it offscreen):
// each of the library's parts over a Monoid optical studio wallpaper (drawn procedurally, deterministic on every run).
// `page` makes the one asked for: the overview (every part), the dialog open over it, the overview held (each part
// pressed or dragged, held still: its glass up), and the film's (the parts a film drags, each where the film's script
// finds it).

///|
/// The parts' glass, as held still for a picture of them held: what the interactive page presses as it is made.
priv struct Held {
  button : @lg.InteractiveHighlight
  toggle : @lg.DampedDrag
  slider : @lg.DampedDrag
  tabs : @lg.DampedDrag
  tabs_light : @lg.InteractiveHighlight
  tile : @lg.InteractiveHighlight
}

///|
/// Studio copy for Progressive Blur.
let progressive_copy : String = "One retained UI tree rendered straight on Metal, Vulkan, D3D11, GLES, and WebGL 2. Closed-form springs, concentric corner ladders, and real-time SDF liquid refraction — zero DOM, zero WebView."

///|
/// Studio copy for Optical Loupe (Magnifier).
let loupe_copy : String = "Glass::liquid(blur: 2.1, bezel: 20, refraction: 24, chroma: -0.06) — quarter-circle bevel refraction, inner shadow, specular glint, and 0.75pt external contour rendered in one GPU pass."

///|
/// Studio copy for Publish Dialog.
let dialog_copy : String = "Compile one MoonBit UI tree into native GPU bundles for macOS, iOS, Android, Windows, Linux, and WebGL 2 with zero WebView overhead."

///|
/// The page named `name` in the window's `root`: "overview", "dialog" (the overview, its dialog open) or
/// "interactive" (the overview, its parts held), "film" (the film's parts). `top`: room left over the parts, for what
/// lies over the page's top (the gallery's bar); `closed`: told as the dialog closes.
pub fn page(root : @view.View, name : String, top? : Double = 0.0, closed? : () -> Unit = fn() {  }) -> Unit {
  @ui.set_tree_theme(@lg.ui_theme)
  let grid_on = @signals.signal(true)
  let exposure = @signals.signal(64.0)
  let boost = @signals.signal(false)
  root.box(fn(w) {
    w.grow(Is(1.0)).clips(Is(true)) |> ignore
    wallpaper(w, fn() { grid_on.get() }, fn() { exposure.get() }, fn() { boost.get() })
    match name {
      "film" => film_page(w, top)
      "dialog" => {
        overview(w, None, top, grid_on, exposure, boost)
        let open = @signals.signal(true)
        @lg.liquid_dialog_node(
          w,
          fn() { open.get() },
          fn() {
            open.set(false)
            closed()
          },
          fn() { "Publish ui.monoid" },
          fn() { dialog_copy },
          cancel=fn() { "Cancel" },
          action=fn() { "Publish" },
          on_action=fn() {
            open.set(false)
            closed()
          },
        )
        |> ignore
      }
      "interactive" => overview(w, Some(held_now()), top, grid_on, exposure, boost)
      _ => overview(w, None, top, grid_on, exposure, boost)
    }
  })
  |> ignore
}

///|
/// Glass held as the interactive page shows it, not pressed yet (`press_all` presses it once each part is made).
fn held_now() -> Held {
  {
    button: @lg.InteractiveHighlight::new(),
    toggle: @lg.DampedDrag::new(1.0, lo=0.0, hi=1.0, held_scale=@lg.thumb_held_scale),
    slider: @lg.DampedDrag::new(64.0, lo=0.0, hi=100.0, threshold=0.01, held_scale=@lg.thumb_held_scale),
    tabs: @lg.DampedDrag::new(0.0, lo=0.0, hi=2.0, held_scale=@lg.tab_lens_held_scale),
    tabs_light: @lg.InteractiveHighlight::new(),
    tile: @lg.InteractiveHighlight::new(),
  }
}

///|
/// Monoid optical studio wallpaper: Obsidian `#0B0C10` / warm stone `#F3EFE8` base, five soft 24-layer colour fields
/// driven by `exposure` (and `boost`), and a precision optical calibration layer (80pt architectural grid, diagonal
/// refraction ribbons, oversized `ui.monoid` wordmarks, and restrained concentric target reticles) toggled by `grid_on`.
/// No fullscreen `Glass::frosted` is used so WebGL 2 stays at 60 fps local-damage speed.
fn wallpaper(
  w : @view.View,
  grid_on : () -> Bool,
  exposure : () -> Double,
  boost : () -> Bool,
) -> Unit {
  w.box(fn(paper) {
    paper
    .over(Is(true))
    .clips(Is(true))
    .ground(By(fn() { if @lg.is_dark() { 0x0B0C10FFL } else { 0xF3EFE8FFL } }))
    |> ignore
    // Soft Monoid colour fields: (x, y, diameter, light_color, dark_color)
    let blots : Array[(Double, Double, Double, Int64, Int64)] = [
      // Top-left / mid-left: Monoid Vermilion
      (-140.0, -120.0, 560.0, 0xFF9E78FFL, 0xB83E18FFL),
      // Top-right: Deep Cobalt
      (680.0, -180.0, 580.0, 0x7CC4FAFFL, 0x1D4ED8FFL),
      // Bottom-right: Warm Amber Gold
      (780.0, 500.0, 560.0, 0xF6C177FFL, 0x9A4D16FFL),
      // Bottom-left: Slate Teal / Emerald
      (-160.0, 540.0, 580.0, 0x7ED8B2FFL, 0x115E59FFL),
      // Center: subtle violet halo
      (360.0, 240.0, 520.0, 0xC7B8FAFFL, 0x3B2475FFL),
    ]
    for b in blots {
      let (x, y, d, light, dark) = b
      let cx = x + d / 2.0
      let cy = y + d / 2.0
      let layers = 24
      for k in 0..<layers {
        let t = k.to_double() / (layers - 1).to_double()
        let ld = d * (1.82 - 1.66 * t)
        let base_a = 0.022 + 0.022 * t
        paper.box(fn(c) {
          c
          .over(Is(true))
          .width(Is(Some(ld)))
          .height(Is(Some(ld)))
          .radius(Is(ld / 2.0))
          .offset(Is((cx - ld / 2.0, cy - ld / 2.0)))
          .ground(By(fn() {
            let exp_gain = 0.65 + 0.55 * (@lg.clamp(exposure(), 0.0, 100.0) / 100.0)
            let boost_gain = if boost() { 1.24 } else { 1.0 }
            let a = @lg.clamp(base_a * exp_gain * boost_gain, 0.0, 0.14)
            @lg.alpha(if @lg.is_dark() { dark } else { light }, a)
          }))
          |> ignore
        })
        |> ignore
      }
    }
    // Precision optical calibration layer (toggled live by Optical Grid without rebuilding nodes)
    paper.box(fn(cal) {
      cal
      .over(Is(true))
      .clips(Is(true))
      .points(Is(false))
      .alpha(By(fn() { if grid_on() { 1.0 } else { 0.0 } }))
      |> ignore
      // 80pt architectural baseline grid (1px hairlines)
      for col in 1..<20 {
        cal.box(fn(vl) {
          vl
          .over(Is(true))
          .width(Is(Some(1.0)))
          .height(Is(Some(1400.0)))
          .offset(Is((col.to_double() * 80.0, 0.0)))
          .ground(By(fn() { if @lg.is_dark() { 0xFFFFFF0DL } else { 0x1717170DL } }))
          |> ignore
        })
        |> ignore
      }
      for row_i in 1..<16 {
        cal.box(fn(hl) {
          hl
          .over(Is(true))
          .width(Is(Some(1800.0)))
          .height(Is(Some(1.0)))
          .offset(Is((0.0, row_i.to_double() * 80.0)))
          .ground(By(fn() { if @lg.is_dark() { 0xFFFFFF0DL } else { 0x1717170DL } }))
          |> ignore
        })
        |> ignore
      }
      // Three diagonal highlight optical refraction ribbons (-0.32 rad)
      let ribbons : Array[(Double, Double)] = [(160.0, 4.0), (500.0, 5.0), (840.0, 4.0)]
      for rb in ribbons {
        let (ry, rh) = rb
        cal.box(fn(s) {
          s
          .over(Is(true))
          .width(Is(Some(2400.0)))
          .height(Is(Some(rh)))
          .offset(Is((-420.0, ry)))
          .turn(Is(-0.32))
          .ground(By(fn() { if @lg.is_dark() { 0xFFFFFF24L } else { 0xFFFFFF8CL } }))
          |> ignore
        })
        |> ignore
      }
      // Subtle Monoid Vermilion refraction hairline
      cal.box(fn(vr) {
        vr
        .over(Is(true))
        .width(Is(Some(2400.0)))
        .height(Is(Some(3.0)))
        .offset(Is((-420.0, 330.0)))
        .turn(Is(-0.32))
        .ground(Is(0xEF633438L))
        |> ignore
      })
      |> ignore
      // Oversized architectural wordmark watermarks (`ui.monoid`, 132pt weight 600)
      let watermarks : Array[(Double, Double)] = [(590.0, 56.0), (28.0, 748.0)]
      for wm in watermarks {
        let (wx, wy) = wm
        cal.box(fn(t) {
          t
          .over(Is(true))
          .offset(Is((wx, wy)))
          .words(Is("ui.monoid"), look=@lg.words_at(132.0, weight=600))
          .ink(By(fn() { if @lg.is_dark() { 0xFFFFFF12L } else { 0x17171710L } }))
          |> ignore
        })
        |> ignore
      }
      // Restrained concentric optical target reticles at key calibration coordinates
      let targets : Array[(Double, Double, Double)] = [
        (240.0, 240.0, 120.0),
        (960.0, 400.0, 152.0),
        (480.0, 720.0, 108.0),
      ]
      for tg in targets {
        let (tx, ty, td) = tg
        for ratio in [1.0, 0.56] {
          let rd = td * ratio
          cal.box(fn(ring) {
            ring
            .over(Is(true))
            .width(Is(Some(rd)))
            .height(Is(Some(rd)))
            .radius(Is(rd / 2.0))
            .offset(Is((tx - rd / 2.0, ty - rd / 2.0)))
            .edge(By(fn() { (1.5, if @lg.is_dark() { 0xFFFFFF18L } else { 0x17171714L }) }))
            |> ignore
          })
          |> ignore
        }
      }
    })
    |> ignore
  })
  |> ignore
}

///|
/// A numbered Studio section in `parent`: Swiss uppercase label over what `body` makes.
fn section(parent : @view.View, title : String, body : (@view.View) -> Unit) -> Unit {
  parent.box(fn(s) {
    s.gap(Is(10.0)) |> ignore
    s.box(fn(t) {
      t
      .words(Is(title), look={ ..@lg.words_at(11.5, weight=600), tracking: Points(0.8) })
      .ink(By(fn() { @lg.alpha(@lg.colors().content, 0.56) }))
      |> ignore
    })
    |> ignore
    body(s)
  })
  |> ignore
}

///|
/// A row of parts in `parent`, 16 apart, their middles in line.
fn row(parent : @view.View, body : (@view.View) -> Unit) -> Unit {
  parent.box(fn(r) {
    r.row(Is(true)).gap(Is(16.0)).lines_up(Is(Some(Middle))) |> ignore
    body(r)
  })
  |> ignore
}

///|
/// Top minimal Studio title strip spanning full width: left Monoid mark + `ui.monoid` + `LIQUID GLASS STUDIO`,
/// right vermilion dot + `iOS 27 Optics · WebGL 2 / Metal`.
fn studio_header(parent : @view.View) -> Unit {
  parent.box(fn(hdr) {
    hdr.row(Is(true)).height(Is(Some(28.0))).lines_up(Is(Some(Middle))).lies_along(Is(Between)) |> ignore
    hdr.box(fn(left) {
      left.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(8.0)) |> ignore
      icon_brand_mark(left, 18.0, fn() { @lg.colors().content })
      left.box(fn(w) {
        w.words(Is("ui.monoid"), look=@lg.words_at(15.0, weight=600)).ink(By(fn() { @lg.colors().content })) |> ignore
      })
      |> ignore
      left.box(fn(dot) {
        dot
        .width(Is(Some(3.0)))
        .height(Is(Some(3.0)))
        .radius(Is(1.5))
        .shrink(Is(0.0))
        .ground(By(fn() { @lg.alpha(@lg.colors().content, 0.36) }))
        |> ignore
      })
      |> ignore
      left.box(fn(w) {
        w
        .words(Is("LIQUID GLASS STUDIO"), look={ ..@lg.words_at(11.0, weight=500), tracking: Points(0.9) })
        .ink(By(fn() { @lg.alpha(@lg.colors().content, 0.58) }))
        |> ignore
      })
      |> ignore
    })
    |> ignore
    hdr.box(fn(right) {
      right.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(7.0)) |> ignore
      right.box(fn(dot) {
        dot.width(Is(Some(6.0))).height(Is(Some(6.0))).radius(Is(3.0)).shrink(Is(0.0)).ground(Is(monoid_vermilion))
        |> ignore
      })
      |> ignore
      right.box(fn(w) {
        w
        .words(Is("iOS 27 Optics · WebGL 2 / Metal"), look=@lg.words_at(12.0, weight=500))
        .ink(By(fn() { @lg.alpha(@lg.colors().content, 0.62) }))
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// Every part, in two Studio columns over the optical wallpaper, `top` more room over them; with `held`, each held as
/// that says (pressed as the page is made).
fn overview(
  root : @view.View,
  held : Held?,
  top : Double,
  grid_on : @signals.Signal[Bool],
  exposure : @signals.Signal[Double],
  boost : @signals.Signal[Bool],
) -> Unit {
  let tab3 = @signals.signal(0)
  let tab4 = @signals.signal(1)
  let build_count = @signals.signal(0)
  let last_action = @signals.signal("60 fps · SDF Glass")
  let sc = @view.Scroll::new()
  root.by_room(fn(host, room) {
    let wide_layout = fn() { room.width() >= 1260.0 }
    let pad_x = fn() { if wide_layout() { 44.0 } else { 24.0 } }
    let pad_y = fn() { if wide_layout() { 26.0 } else { 20.0 } }
    let col_gap = fn() { if wide_layout() { 44.0 } else { 28.0 } }
    let left_w = fn() {
      if wide_layout() {
        532.0
      } else {
        let avail = @lg.clamp(room.width() - 2.0 * pad_x() - col_gap(), 400.0, 1200.0)
        (avail * 0.48).floor()
      }
    }
    let right_w = fn() {
      if wide_layout() {
        616.0
      } else {
        let avail = @lg.clamp(room.width() - 2.0 * pad_x() - col_gap(), 400.0, 1200.0)
        avail - left_w()
      }
    }
    let slider_tabs_w = fn() {
      if wide_layout() {
        480.0
      } else {
        let lw = left_w()
        if lw < 480.0 { lw } else { 480.0 }
      }
    }
    let adaptive_card_w = fn() {
      if wide_layout() {
        220.0
      } else {
        let aw = ((right_w() - 16.0) / 2.0).floor()
        if aw < 220.0 { aw } else { 220.0 }
      }
    }
    host.grow(Is(1.0)).scrolls(sc, slop=@ui.touch_slop(), bar=@ui.tree_scroll_bar(), fn(page) {
      page.gap(Is(18.0)).padding(By(fn() { (pad_x(), pad_y() + top, pad_x(), pad_y()) })) |> ignore
      studio_header(page)
      page.box(fn(cols) {
        cols.row(Is(true)).gap(By(col_gap)) |> ignore
        cols.box(fn(left) {
          left.width(By(fn() { Some(left_w()) })).shrink(Is(0.0)).gap(Is(24.0)) |> ignore
          section(left, "01 / ACTIONS", fn(s) {
            row(s, fn(r) {
              @lg.liquid_button_node(
                r,
                fn() { "Build Native" },
                fn() {
                  let n = build_count.untracked() + 1
                  build_count.set(n)
                  last_action.set("Built · #\{n}")
                },
                light?=held.map(fn(h) { h.button }),
              )
              |> ignore
              @lg.liquid_button_node(
                r,
                fn() { "Inspect Tree" },
                fn() { last_action.set("Inspected tree") },
                surface=0xFFFFFF4DL,
              )
              |> ignore
            })
            row(s, fn(r) {
              @lg.liquid_button_node(
                r,
                fn() { "Publish Release" },
                fn() { last_action.set("Ready to publish") },
                tint=monoid_vermilion,
              )
              |> ignore
              @lg.liquid_button_node(
                r,
                fn() { "Preview Wasm" },
                fn() { last_action.set("Wasm preview live") },
                tint=0x1D68F5FFL,
              )
              |> ignore
            })
          })
          section(left, "02 / LIVE OPTICS", fn(s) {
            s.box(fn(toggles) {
              toggles.row(Is(true)).gap(Is(28.0)).lines_up(Is(Some(Middle))) |> ignore
              toggles.box(fn(t1) {
                t1.row(Is(true)).gap(Is(10.0)).lines_up(Is(Some(Middle))) |> ignore
                @lg.liquid_toggle_node(
                  t1,
                  fn() { @lg.is_dark() },
                  fn(v) {
                    @lg.set_dark(Some(v))
                    last_action.set(if v { "Dark Studio" } else { "Light Studio" })
                  },
                  fn() { "Dark Studio" },
                )
                |> ignore
                t1.box(fn(lbl) {
                  lbl
                  .words(Is("Dark Studio"), look=@lg.words_at(13.0, weight=500))
                  .ink(By(fn() { @lg.colors().content }))
                  |> ignore
                })
                |> ignore
              })
              |> ignore
              toggles.box(fn(t2) {
                t2.row(Is(true)).gap(Is(10.0)).lines_up(Is(Some(Middle))) |> ignore
                @lg.liquid_toggle_node(
                  t2,
                  fn() { grid_on.get() },
                  fn(v) {
                    grid_on.set(v)
                    last_action.set(if v { "Grid enabled" } else { "Grid hidden" })
                  },
                  fn() { "Optical Grid" },
                  drag?=held.map(fn(h) { h.toggle }),
                )
                |> ignore
                t2.box(fn(lbl) {
                  lbl
                  .words(Is("Optical Grid"), look=@lg.words_at(13.0, weight=500))
                  .ink(By(fn() { @lg.colors().content }))
                  |> ignore
                })
                |> ignore
              })
              |> ignore
            })
            |> ignore
            s.box(fn(b) {
              b.width(By(fn() { Some(slider_tabs_w()) })).gap(Is(6.0)).padding(Is((0.0, 4.0, 0.0, 0.0))) |> ignore
              b.box(fn(sh) {
                sh.row(Is(true)).lies_along(Is(Between)).lines_up(Is(Some(Middle))) |> ignore
                sh.box(fn(l) {
                  l
                  .words(Is("Exposure"), look=@lg.words_at(13.0, weight=500))
                  .ink(By(fn() { @lg.alpha(@lg.colors().content, 0.82) }))
                  |> ignore
                })
                |> ignore
                sh.box(fn(v) {
                  v
                  .words(By(fn() { "\{exposure.get().round().to_int()}%" }), look=@lg.words_at(13.0, weight=600))
                  .ink(By(fn() { @lg.alpha(@lg.colors().content, 0.72) }))
                  |> ignore
                })
                |> ignore
              })
              |> ignore
              @lg.liquid_slider_node(
                b,
                fn() { exposure.get() },
                fn(v) { exposure.set(v) },
                fn() { "Exposure" },
                drag?=held.map(fn(h) { h.slider }),
              )
              |> ignore
            })
            |> ignore
          })
          section(left, "03 / NAVIGATION", fn(s) {
            s.box(fn(b) {
              b.width(By(fn() { Some(slider_tabs_w()) })).gap(Is(18.0)) |> ignore
              @lg.liquid_bottom_tabs_node(
                b,
                ["Canvas", "Optics", "Inspect"],
                fn() { tab3.get() },
                fn(i) { tab3.set(i) },
                label="Studio views",
                faces=[
                  studio_tab_face("Canvas", icon_canvas),
                  studio_tab_face("Optics", icon_prism),
                  studio_tab_face("Inspect", icon_sliders),
                ],
                drag?=held.map(fn(h) { h.tabs }),
                light?=held.map(fn(h) { h.tabs_light }),
              )
              |> ignore
              @lg.liquid_bottom_tabs_node(
                b,
                ["Home", "Layers", "Motion", "Tokens"],
                fn() { tab4.get() },
                fn(i) { tab4.set(i) },
                label="Modules",
                faces=[
                  studio_tab_face("Home", icon_brand_mark),
                  studio_tab_face("Layers", icon_layers),
                  studio_tab_face("Motion", icon_spark),
                  studio_tab_face("Tokens", icon_terminal),
                ],
              )
              |> ignore
            })
            |> ignore
          })
        })
        |> ignore
        cols.box(fn(right) {
          right.width(By(fn() { Some(right_w()) })).shrink(Is(0.0)).gap(Is(22.0)) |> ignore
          section(right, "04 / STUDIO DECK", fn(s) {
            row(s, fn(r) {
              let wide = @lg.tile_size * 2.0 + @lg.tile_gap
              // (its corners round what it holds, 16 in: the catalog's 34 would cut closer to its capsules than they sit to
              // its edge)
              @lg.liquid_card_node(
                r,
                wide,
                wide,
                fn() { "Studio controls" },
                radius=@lg.tile_inner / 2.0 + @lg.tile_gap,
                light?=held.map(fn(h) { h.tile }),
                press=fn() {  },
                content=fn(c) {
                  c.padding(Is((@lg.tile_gap, @lg.tile_gap, @lg.tile_gap, @lg.tile_gap))).lies_along(Is(Between)) |> ignore
                  c.box(fn(rr) {
                    rr.row(Is(true)).lies_along(Is(Between)) |> ignore
                    @lg.liquid_control_item_node(
                      rr,
                      fn() { @lg.is_dark() },
                      fn(v) {
                        @lg.set_dark(Some(v))
                        last_action.set(if v { "Dark Studio" } else { "Light Studio" })
                      },
                      fn() { "Dark Studio" },
                      icon=fn(box, _ink) {
                        let deck_ink = fn() { if @lg.is_dark() { @lg.white } else { 0x1C2430D9L } }
                        box.pick(fn() { @lg.is_dark() }, at_once=true, fn(inner, d) {
                          if d {
                            icon_moon(inner, 26.0, deck_ink)
                          } else {
                            icon_sun(inner, 26.0, deck_ink)
                          }
                        })
                      },
                    )
                    |> ignore
                    @lg.liquid_control_item_node(
                      rr,
                      fn() { grid_on.get() },
                      fn(v) {
                        grid_on.set(v)
                        last_action.set(if v { "Grid enabled" } else { "Grid hidden" })
                      },
                      fn() { "Optical Grid" },
                      icon=fn(box, _ink) {
                        icon_grid(box, 26.0, fn() {
                          if grid_on.get() || @lg.is_dark() { @lg.white } else { 0x1C2430D9L }
                        })
                      },
                    )
                    |> ignore
                  })
                  |> ignore
                  c.box(fn(rr) {
                    rr.row(Is(true)) |> ignore
                    @lg.liquid_control_item_node(
                      rr,
                      fn() { boost.get() },
                      fn(v) {
                        boost.set(v)
                        last_action.set(if v { "Glow boost on" } else { "Glow boost off" })
                      },
                      fn() { "Optical Boost" },
                      icon=fn(box, _ink) {
                        icon_bolt(box, 26.0, fn() {
                          if boost.get() || @lg.is_dark() { @lg.white } else { 0x1C2430D9L }
                        })
                      },
                    )
                    |> ignore
                  })
                  |> ignore
                },
              )
              |> ignore
              r.box(fn(col) {
                col.gap(Is(@lg.tile_gap)) |> ignore
                row(col, fn(rr) {
                  let tile_ink = fn() { if @lg.is_dark() { @lg.white } else { 0x1C2430E6L } }
                  @lg.liquid_control_tile_node(
                    rr,
                    fn() { "Play pulse" },
                    fn() { last_action.set("Pulse · 60 fps") },
                    icon=fn(box, _ink) { icon_play(box, 26.0, tile_ink) },
                  )
                  |> ignore
                  @lg.liquid_control_tile_node(
                    rr,
                    fn() { "Reset" },
                    fn() {
                      exposure.set(64.0)
                      grid_on.set(true)
                      boost.set(false)
                      last_action.set("60 fps · SDF Glass")
                    },
                    angle=135.0,
                    icon=fn(box, _ink) { icon_refresh(box, 26.0, tile_ink) },
                  )
                  |> ignore
                })
                @lg.liquid_card_node(
                  col,
                  wide,
                  @lg.tile_size,
                  fn() { "Studio status" },
                  content=fn(c) {
                    c
                    .row(Is(true))
                    .padding(Is((16.0, 0.0, 16.0, 0.0)))
                    .lines_up(Is(Some(Middle)))
                    .gap(Is(10.0))
                    .clips(Is(true))
                    |> ignore
                    c.box(fn(dot) {
                      dot
                      .width(Is(Some(6.0)))
                      .height(Is(Some(6.0)))
                      .radius(Is(3.0))
                      .shrink(Is(0.0))
                      .ground(Is(monoid_vermilion))
                      |> ignore
                    })
                    |> ignore
                    c.box(fn(info) {
                      info.grow(Is(1.0)).gap(Is(1.0)).clips(Is(true)) |> ignore
                      info.box(fn(main_lbl) {
                        main_lbl
                        .words(Is("ui.monoid"), look={ ..@lg.words_at(13.0, weight=600), line: 16.0 })
                        .ink(By(fn() { @lg.colors().content }))
                        |> ignore
                      })
                      |> ignore
                      info.box(fn(sub_lbl) {
                        sub_lbl
                        .words(By(fn() { last_action.get() }), look={ ..@lg.words_at(11.0, weight=400), line: 14.0 })
                        .ink(By(fn() { @lg.alpha(@lg.colors().content, 0.68) }))
                        |> ignore
                      })
                      |> ignore
                    })
                    |> ignore
                  },
                )
                |> ignore
              })
              |> ignore
            })
          })
          section(right, "05 / ADAPTIVE LUMINANCE", fn(s) {
            row(s, fn(r) {
              for lum in [0.92, 0.08] {
                r.box(fn(b) {
                  b
                  .width(By(fn() { Some(adaptive_card_w()) }))
                  .height(Is(Some(196.0)))
                  .radius(Is(28.0))
                  .lines_up(Is(Some(Middle)))
                  .lies_along(Is(Middle))
                  .ground(Is(if lum > 0.5 { 0xF5F3EEFFL } else { 0x14151BFFL }))
                  |> ignore
                  b.box(fn(stripes) {
                    // (six lines, 32 from its top and 24 from its foot, cut to its corners: the card's shadow over it is not)
                    stripes
                    .over(Is(true))
                    .clips(Is(true))
                    .radius(Is(28.0))
                    .padding(Is((0.0, 32.0, 0.0, 0.0)))
                    .gap(Is(24.0))
                    |> ignore
                    for _ in 0..<6 {
                      stripes.box(fn(line) {
                        line.height(Is(Some(3.0))).ground(Is(if lum > 0.5 { 0xDDD8CEFFL } else { 0x2A2D38FFL }))
                        |> ignore
                      })
                      |> ignore
                    }
                  })
                  |> ignore
                  @lg.liquid_adaptive_surface_node(b, fn() { lum }, size=150.0) |> ignore
                })
                |> ignore
              }
            })
          })
          section(right, "06 / PROGRESSIVE BLUR", fn(s) {
            s.box(fn(b) {
              b.radius(Is(24.0)).clips(Is(true)) |> ignore
              b.box(fn(text) {
                text.padding(Is((20.0, 16.0, 20.0, 16.0))).ground(By(fn() { @lg.alpha(@lg.colors().paper, 0.5) }))
                |> ignore
                text.box(fn(t) {
                  t
                  .words(Is(progressive_copy), look=@lg.words_at(15.0, wrap=true))
                  .ink(By(fn() { @lg.colors().content }))
                  |> ignore
                })
                |> ignore
              })
              |> ignore
              b.box(fn(o) {
                o.over(Is(true)) |> ignore
                @lg.liquid_progressive_blur_node(o, words=fn() { "Progressive Blur · ui.monoid" }, height=96.0)
                |> ignore
              })
              |> ignore
            })
            |> ignore
          })
          section(right, "07 / OPTICAL LOUPE", fn(s) {
            @lg.liquid_magnifier_node(s, fn() { loupe_copy }, label=fn() { "Optical Loupe" }, at=(60.0, 40.0)) |> ignore
          })
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
    match held {
      Some(h) =>
        @signals.untracked(fn() {
          // (each held as a finger holds it: the button pressed and pulled right, the toggle's thumb and the slider's,
          // the tabs' lens between its first two tabs, a tile pressed)
          h.button.down(60.0, 24.0, 240.0, 48.0)
          h.button.moved(120.0, 34.0)
          h.toggle.press()
          h.slider.press()
          h.tabs.press()
          h.tabs.update_value(0.55)
          h.tabs_light.down(80.0, 32.0, 480.0, 64.0)
          h.tile.down(110.0, 40.0, 152.0, 152.0)
        })
      None => ()
    }
  })
  |> ignore
}

///|
/// The film's page: the parts its script drags, each where the script finds it (src/shots, film_script): 40 in from
/// the window's top left (`top` more down), 40 apart down it, 520 wide.
fn film_page(root : @view.View, top : Double) -> Unit {
  let on = @signals.signal(false)
  let level = @signals.signal(30.0)
  let tab = @signals.signal(0)
  root.box(fn(page) {
    page.grow(Is(1.0)).gap(Is(40.0)).padding(Is((40.0, 40.0 + top, 40.0, 40.0))).lines_up(Is(Some(Start))) |> ignore
    @lg.liquid_button_node(page, fn() { "Build Native" }, fn() {  }) |> ignore
    @lg.liquid_toggle_node(page, fn() { on.get() }, fn(v) { on.set(v) }, fn() { "Toggle" }) |> ignore
    page.box(fn(b) {
      b.width(Is(Some(520.0))) |> ignore
      @lg.liquid_slider_node(b, fn() { level.get() }, fn(v) { level.set(v) }, fn() { "Slider" }) |> ignore
    })
    |> ignore
    page.box(fn(b) {
      b.width(Is(Some(520.0))) |> ignore
      @lg.liquid_bottom_tabs_node(
        b,
        ["Home", "Layers", "Motion", "Tokens"],
        fn() { tab.get() },
        fn(i) { tab.set(i) },
        label="Modules",
        faces=[
          studio_tab_face("Home", icon_brand_mark),
          studio_tab_face("Layers", icon_layers),
          studio_tab_face("Motion", icon_spark),
          studio_tab_face("Tokens", icon_terminal),
        ],
      )
      |> ignore
    })
    |> ignore
  })
  |> ignore
}
