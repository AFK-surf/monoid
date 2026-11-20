// ui.monoid · Spatial Optical Stage (src/gallery shows it in a window and on the web; src/shots draws it offscreen):
// a single-viewport (1120×690 zero-scroll, also responsive to 1280×1040) interactive optical workbench with a floating
// glass Dock switching three scenes — Optics (draggable liquid prism + live Glass::liquid inspector), Deck (full 2×2
// Monoid hardware deck + continuous Adaptive Luminance bench), and Loupe (Progressive Blur + MoonBit source magnifier).

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
/// Studio copy for Optical Loupe (MoonBit source specimen).
let loupe_source_copy : String = "let prism = @paint.Glass::liquid(\n  blur=1.8, bezel=22.0, refraction=28.0, chroma=-0.06,\n  saturation=1.18, rim=0.68, adaptive=false,\n)\n// One GPU pass on Metal, Vulkan, D3D11, GLES & WebGL 2."

///|
/// Studio copy for Publish Dialog.
let dialog_copy : String = "Compile one MoonBit UI tree into native GPU bundles for macOS, iOS, Android, Windows, Linux, and WebGL 2 with zero WebView overhead."

///|
/// Format a non-negative number to one decimal place (e.g. `1.8`).
fn fmt_tenth(v : Double) -> String {
  let t = (v * 10.0).round().to_int()
  let whole = t / 10
  let frac = t % 10
  "\{whole}.\{frac}"
}

///|
/// Format a chroma value `0..15` as `-0.06`.
fn fmt_chroma(v : Double) -> String {
  let c = v.round().to_int()
  if c == 0 {
    "0.00"
  } else if c < 10 {
    "-0.0\{c}"
  } else {
    "-0.\{c}"
  }
}

///|
/// Format a 0..100 percentage as `0.88`.
fn fmt_unit(v : Double) -> String {
  let h = (@lg.clamp(v, 0.0, 100.0)).round().to_int()
  let whole = h / 100
  let frac = h % 100
  let pad = if frac < 10 { "0" } else { "" }
  "\{whole}.\{pad}\{frac}"
}

///|
/// Format a signed integer coordinate with explicit sign and 2-digit pad (e.g. `+00`, `-18`).
fn fmt_signed(v : Double) -> String {
  let n = v.round().to_int()
  let sign = if n < 0 { "-" } else { "+" }
  let a = if n < 0 { -n } else { n }
  let pad = if a < 10 { "0" } else { "" }
  "\{sign}\{pad}\{a}"
}

///|
/// The page named `name` in the window's `root`: "overview", "dialog" (the overview, its dialog open) or
/// "interactive" (the overview, its parts held), "film" (the film's parts). `top`: room left over the parts, for what
/// lies over the page's top (the gallery's bar); `closed`: told as the dialog closes.
pub fn page(root : @view.View, name : String, top? : Double = 0.0, closed? : () -> Unit = fn() {  }) -> Unit {
  @ui.set_tree_theme(@lg.ui_theme)
  let grid_on = @signals.signal(true)
  let boost = @signals.signal(false)
  let dialog_open = @signals.signal(name == "dialog")
  root.box(fn(w) {
    w.grow(Is(1.0)).clips(Is(true)) |> ignore
    wallpaper(w, fn() { grid_on.get() }, fn() { boost.get() })
    match name {
      "film" => film_page(w, top)
      "merge" => merge_page(w, top)
      _ => {
        let held = if name == "interactive" { Some(held_now()) } else { None }
        overview(w, held, top, grid_on, boost, dialog_open)
        @lg.liquid_dialog_node(
          w,
          fn() { dialog_open.get() },
          fn() {
            dialog_open.set(false)
            if name == "dialog" {
              closed()
            }
          },
          fn() { "Publish ui.monoid" },
          fn() { dialog_copy },
          cancel=fn() { "Cancel" },
          action=fn() { "Publish" },
          on_action=fn() {
            dialog_open.set(false)
            if name == "dialog" {
              closed()
            }
          },
        )
        |> ignore
      }
    }
  })
  |> ignore
}

///|
/// Glass held as the interactive page shows it, not pressed yet (`overview` presses it once each part is made).
fn held_now() -> Held {
  {
    button: @lg.InteractiveHighlight::new(),
    toggle: @lg.DampedDrag::new(1.0, lo=0.0, hi=1.0, held_scale=@lg.thumb_held_scale),
    slider: @lg.DampedDrag::new(28.0, lo=0.0, hi=56.0, threshold=0.01, held_scale=@lg.thumb_held_scale),
    tabs: @lg.DampedDrag::new(0.0, lo=0.0, hi=2.0, held_scale=@lg.tab_lens_held_scale),
    tabs_light: @lg.InteractiveHighlight::new(),
    tile: @lg.InteractiveHighlight::new(),
  }
}

///|
/// High-contrast Monoid architectural studio wallpaper: Obsidian `#090A0E` / warm stone `#F4F1EA` base, three
/// restrained 18-layer colour fields (vermilion, cobalt, teal) with subtle `boost` gain, and a toggleable precision
/// calibration layer (80pt hairlines, two crisp diagonal refraction ribbons, and two concentric target reticles).
/// Zero fullscreen `Glass::frosted` keeps WebGL 2 at 60 fps local-damage speed.
fn wallpaper(w : @view.View, grid_on : () -> Bool, boost : () -> Bool) -> Unit {
  w.box(fn(paper) {
    paper
    .over(Is(true))
    .clips(Is(true))
    .ground(By(fn() { if @lg.is_dark() { 0x090A0EFFL } else { 0xF4F1EAFFL } }))
    |> ignore
    // Three restrained soft colour fields: (x, y, diameter, light_color, dark_color)
    let blots : Array[(Double, Double, Double, Int64, Int64)] = [
      // Top-left: Monoid Vermilion
      (-160.0, -140.0, 520.0, 0xFF9E78FFL, 0xB83E18FFL),
      // Top-right: Deep Cobalt
      (640.0, -180.0, 560.0, 0x7CC4FAFFL, 0x1D4ED8FFL),
      // Bottom-left: Slate Teal
      (-160.0, 380.0, 540.0, 0x7ED8B2FFL, 0x115E59FFL),
    ]
    for b in blots {
      let (x, y, d, light, dark) = b
      let cx = x + d / 2.0
      let cy = y + d / 2.0
      let layers = 18
      for k in 0..<layers {
        let t = k.to_double() / (layers - 1).to_double()
        let ld = d * (1.76 - 1.60 * t)
        let base_a = 0.018 + 0.018 * t
        paper.box(fn(c) {
          c
          .over(Is(true))
          .width(Is(Some(ld)))
          .height(Is(Some(ld)))
          .radius(Is(ld / 2.0))
          .offset(Is((cx - ld / 2.0, cy - ld / 2.0)))
          .ground(By(fn() {
            let gain = if boost() { 1.32 } else { 1.0 }
            let a = @lg.clamp(base_a * gain, 0.0, 0.12)
            @lg.alpha(if @lg.is_dark() { dark } else { light }, a)
          }))
          |> ignore
        })
        |> ignore
      }
    }
    // Precision optical calibration layer (toggled live via alpha without rebuilding nodes)
    paper.box(fn(cal) {
      cal
      .over(Is(true))
      .clips(Is(true))
      .points(Is(false))
      .alpha(By(fn() { if grid_on() { 1.0 } else { 0.0 } }))
      |> ignore
      // 80pt architectural baseline grid (1px hairlines)
      for col in 1..<18 {
        cal.box(fn(vl) {
          vl
          .over(Is(true))
          .width(Is(Some(1.0)))
          .height(Is(Some(1200.0)))
          .offset(Is((col.to_double() * 80.0, 0.0)))
          .ground(By(fn() { if @lg.is_dark() { 0xFFFFFF0DL } else { 0x1717170DL } }))
          |> ignore
        })
        |> ignore
      }
      for row_i in 1..<15 {
        cal.box(fn(hl) {
          hl
          .over(Is(true))
          .width(Is(Some(1600.0)))
          .height(Is(Some(1.0)))
          .offset(Is((0.0, row_i.to_double() * 80.0)))
          .ground(By(fn() { if @lg.is_dark() { 0xFFFFFF0DL } else { 0x1717170DL } }))
          |> ignore
        })
        |> ignore
      }
      // Two crisp diagonal refraction ribbons (-0.32 rad): primary highlight + Monoid Vermilion hairline
      cal.box(fn(s1) {
        s1
        .over(Is(true))
        .width(Is(Some(2200.0)))
        .height(Is(Some(4.0)))
        .offset(Is((-360.0, 220.0)))
        .turn(Is(-0.32))
        .ground(By(fn() { if @lg.is_dark() { 0xFFFFFF22L } else { 0x14172018L } }))
        |> ignore
      })
      |> ignore
      cal.box(fn(s2) {
        s2
        .over(Is(true))
        .width(Is(Some(2200.0)))
        .height(Is(Some(3.0)))
        .offset(Is((-360.0, 420.0)))
        .turn(Is(-0.32))
        .ground(Is(0xEF63344DL))
        |> ignore
      })
      |> ignore
      // Two restrained concentric optical target reticles
      let targets : Array[(Double, Double, Double)] = [(160.0, 160.0, 112.0), (1040.0, 560.0, 128.0)]
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
            .edge(By(fn() { (1.5, if @lg.is_dark() { 0xFFFFFF16L } else { 0x17171714L }) }))
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
/// Compact pill button for the Studio Bar (`height: 30`, `radius: 15`) built on `@headless.button`.
fn studio_bar_pill(
  parent : @view.View,
  label : () -> String,
  on_press : () -> Unit,
  body : (@view.View) -> Unit,
) -> Unit {
  @headless.button(parent, label, fn(_) { on_press() }, fn(b, btn) {
    b
    .row(Is(true))
    .height(Is(Some(30.0)))
    .padding(Is((12.0, 0.0, 12.0, 0.0)))
    .radius(Is(15.0))
    .gap(Is(6.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .ground(By(fn() {
      let d = @lg.is_dark()
      if btn.pressed() || btn.hovered() {
        if d { 0xFFFFFF24L } else { 0x14172018L }
      } else if d {
        0xFFFFFF14L
      } else {
        0xFFFFFFA8L
      }
    }))
    .edge(By(fn() { (1.0, if @lg.is_dark() { 0xFFFFFF22L } else { 0x1417201AL }) }))
    |> ignore
    body(b)
    b.show(fn() { btn.focus_shown() }, fn(ring) {
      ring
      .over(Is(true))
      .margin(Is((-3.0, -3.0, -3.0, -3.0)))
      .radius(Is(18.0))
      .edge(By(fn() { (2.0, @lg.colors().accent) }))
      |> ignore
    })
  })
  |> ignore
}

///|
/// Top Studio Bar (`height: 36`): left Monoid mark + `ui.monoid · OPTICAL STAGE`, right status + Dark/Light + Dialog.
fn studio_bar(parent : @view.View, dialog_open : @signals.Signal[Bool]) -> Unit {
  parent.box(fn(hdr) {
    hdr
    .row(Is(true))
    .height(Is(Some(36.0)))
    .shrink(Is(0.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Between))
    |> ignore
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
        .words(Is("OPTICAL STAGE"), look={ ..@lg.words_at(11.0, weight=600), tracking: Points(1.0) })
        .ink(By(fn() { @lg.alpha(@lg.colors().content, 0.58) }))
        |> ignore
      })
      |> ignore
    })
    |> ignore
    hdr.box(fn(right) {
      right.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(12.0)) |> ignore
      right.box(fn(status) {
        status.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(7.0)) |> ignore
        status.box(fn(dot) {
          dot.width(Is(Some(6.0))).height(Is(Some(6.0))).radius(Is(3.0)).shrink(Is(0.0)).ground(Is(monoid_vermilion))
          |> ignore
        })
        |> ignore
        status.box(fn(w) {
          w
          .words(Is("60 fps · Metal / WebGL 2"), look=@lg.words_at(12.0, weight=500))
          .ink(By(fn() { @lg.alpha(@lg.colors().content, 0.64) }))
          |> ignore
        })
        |> ignore
      })
      |> ignore
      studio_bar_pill(
        right,
        fn() { if @lg.is_dark() { "Switch to Light" } else { "Switch to Dark" } },
        fn() { @lg.set_dark(Some(!@lg.is_dark())) },
        fn(b) {
          b.pick(fn() { @lg.is_dark() }, at_once=true, fn(ic, d) {
            if d {
              icon_moon(ic, 14.0, fn() { @lg.colors().content })
            } else {
              icon_sun(ic, 14.0, fn() { @lg.colors().content })
            }
          })
          b.box(fn(w) {
            w
            .words(By(fn() { if @lg.is_dark() { "Dark" } else { "Light" } }), look=@lg.words_at(12.0, weight=500))
            .ink(By(fn() { @lg.colors().content }))
            |> ignore
          })
          |> ignore
        },
      )
      studio_bar_pill(
        right,
        fn() { "Dialog" },
        fn() { dialog_open.set(true) },
        fn(b) {
          b.box(fn(w) {
            w.words(Is("Dialog"), look=@lg.words_at(12.0, weight=500)).ink(By(fn() { @lg.colors().content })) |> ignore
          })
          |> ignore
        },
      )
    })
    |> ignore
  })
  |> ignore
}

///|
/// Five horizontal calibration hairlines inside a contrast plate (helper keeps `pick` bodies loop-free for detlint).
fn plate_stripes(parent : @view.View, radius : Double, stripe_color : () -> Int64, top_pad : Double, gap : Double) -> Unit {
  parent.box(fn(stripes) {
    stripes
    .over(Is(true))
    .clips(Is(true))
    .points(Is(false))
    .radius(Is(radius))
    .padding(Is((0.0, top_pad, 0.0, 0.0)))
    .gap(Is(gap))
    |> ignore
    let add = fn() {
      stripes.box(fn(line) { line.height(Is(Some(3.0))).ground(By(stripe_color)) |> ignore }) |> ignore
    }
    add()
    add()
    add()
    add()
    add()
  })
  |> ignore
}

///|
/// Inspector floating glass container material.
fn inspector_glass() -> @paint.Glass {
  let d = @lg.is_dark()
  @paint.Glass::liquid(
    blur=7.0,
    tint=if d { 0x1B1D2678L } else { 0xFFFFFF82L },
    solid=if d { 0x161820FFL } else { 0xFAF8F4FFL },
    saturation=1.05,
    rim=0.6,
    bezel=20.0,
    refraction=24.0,
    chroma=0.0,
    merge=0.0,
    adaptive=false,
  )
}

///|
/// Parameter slider row inside the Glass Inspector or Deck: label left, formatted readout right, slider below.
fn param_slider(
  parent : @view.View,
  name : String,
  readout : () -> String,
  value : () -> Double,
  change : (Double) -> Unit,
  least : Double,
  most : Double,
  drag? : @lg.DampedDrag,
) -> Unit {
  parent.box(fn(b) {
    b.gap(Is(4.0)) |> ignore
    b.box(fn(sh) {
      sh.row(Is(true)).lies_along(Is(Between)).lines_up(Is(Some(Middle))) |> ignore
      sh.box(fn(l) {
        l
        .words(Is(name), look=@lg.words_at(12.5, weight=500))
        .ink(By(fn() { @lg.alpha(@lg.colors().content, 0.82) }))
        |> ignore
      })
      |> ignore
      sh.box(fn(v) {
        v
        .words(By(readout), look=@lg.words_at(12.5, weight=600))
        .ink(By(fn() { @lg.alpha(@lg.colors().content, 0.72) }))
        |> ignore
      })
      |> ignore
    })
    |> ignore
    @lg.liquid_slider_node(b, value, change, fn() { name }, least~, most~, drag?) |> ignore
  })
  |> ignore
}

///|
/// Scene 0 — `Optics`: left interactive optical stage (Monoid Vermilion sun + inverse-luminance architectural plate +
/// oversized `ui.monoid` wordmark + draggable 268×176 live liquid glass prism) and right 348pt `Glass Inspector`.
fn optics_scene(
  parent : @view.View,
  held : Held?,
  grid_on : @signals.Signal[Bool],
  refraction_val : @signals.Signal[Double],
  chroma_val : @signals.Signal[Double],
  blur_val : @signals.Signal[Double],
  prism_pos : @signals.Signal[(Double, Double)],
  dialog_open : @signals.Signal[Bool],
) -> Unit {
  let last_drag = Ref((0.0, 0.0))
  parent.box(fn(row) {
    row.row(Is(true)).grow(Is(1.0)).gap(Is(24.0)).lines_up(Is(Some(Middle))) |> ignore
    // Left interactive optical stage: fixed 500pt optical canvas height, grows horizontally with viewport
    row.box(fn(stage_host) {
      stage_host.grow(Is(1.0)).height(Is(Some(500.0))).clips(Is(true)) |> ignore
      stage_host.by_room(fn(stage, room) {
        stage.grow(Is(1.0)).height(Is(Some(500.0))).clips(Is(true)) |> ignore
        let rw = fn() { room.width() }
        let rh = fn() { 500.0 }
        let prism_w = 268.0
        let prism_h = 176.0
        // 1. Monoid Vermilion Sun (236pt solid circle, upper-middle of left stage)
        stage.box(fn(sun) {
          sun
          .over(Is(true))
          .points(Is(false))
          .width(Is(Some(236.0)))
          .height(Is(Some(236.0)))
          .radius(Is(118.0))
          .offset(By(fn() { (rw() * 0.43 - 118.0, rh() * 0.38 - 118.0) }))
          .ground(Is(monoid_vermilion))
          |> ignore
        })
        |> ignore
        // 2. Inverse-luminance architectural contrast plate (248×132, overlapping sun)
        stage.box(fn(plate) {
          plate
          .over(Is(true))
          .points(Is(false))
          .width(Is(Some(248.0)))
          .height(Is(Some(132.0)))
          .radius(Is(26.0))
          .clips(Is(true))
          .offset(By(fn() { (rw() * 0.56 - 92.0, rh() * 0.54 - 66.0) }))
          .ground(By(fn() { if @lg.is_dark() { 0xF5F2EBFFL } else { 0x151720FFL } }))
          |> ignore
          plate_stripes(
            plate,
            26.0,
            fn() { if @lg.is_dark() { 0xDDD8CEFFL } else { 0x292D3BFFL } },
            20.0,
            20.0,
          )
          plate.box(fn(tag) {
            tag
            .over(Is(true))
            .padding(Is((16.0, 10.0, 16.0, 12.0)))
            .lines_up(Is(Some(End)))
            .lies_along(Is(End))
            |> ignore
            tag.box(fn(w) {
              w
              .words(
                By(fn() { if @lg.is_dark() { "L 0.92" } else { "L 0.08" } }),
                look={ ..@lg.words_at(10.5, weight=600), tracking: Points(0.6) },
              )
              .ink(By(fn() { if @lg.is_dark() { 0x14151B80L } else { 0xFFFFFF80L } }))
              |> ignore
            })
            |> ignore
          })
          |> ignore
        })
        |> ignore
        // 3. Oversized architectural wordmark `ui.monoid` (116pt weight 700)
        stage.box(fn(wm) {
          wm
          .over(Is(true))
          .points(Is(false))
          .offset(By(fn() { (rw() * 0.5 - 264.0, rh() * 0.67 - 42.0) }))
          .words(Is("ui.monoid"), look=@lg.words_at(116.0, weight=700))
          .ink(By(fn() { if @lg.is_dark() { 0xFFFFFF26L } else { 0x1417201FL } }))
          |> ignore
        })
        |> ignore
        // 4. Draggable 268×176 live Liquid Glass Prism
        stage.box(fn(prism) {
          let clamped_pos = fn() {
            let (dx, dy) = prism_pos.get()
            let max_x = @lg.clamp((rw() - prism_w) / 2.0 - 8.0, 0.0, 600.0)
            let max_y = @lg.clamp((rh() - prism_h) / 2.0 - 8.0, 0.0, 400.0)
            (@lg.clamp(dx, -max_x, max_x), @lg.clamp(dy, -max_y, max_y))
          }
          prism
          .over(Is(true))
          .width(Is(Some(prism_w)))
          .height(Is(Some(prism_h)))
          .radius(Is(32.0))
          .padding(Is((20.0, 20.0, 20.0, 20.0)))
          .lies_along(Is(Between))
          .shadow(Is(@lg.shadow_default))
          .shadow_outside(Is(true))
          .glass(By(fn() {
            Some(
              @paint.Glass::liquid(
                blur=blur_val.get(),
                tint=if @lg.is_dark() { 0x1D202A42L } else { 0xFFFFFF36L },
                solid=if @lg.is_dark() { 0x1A1C24FFL } else { 0xFAF8F4FFL },
                saturation=1.18,
                rim=0.68,
                bezel=22.0,
                refraction=refraction_val.get(),
                chroma=-chroma_val.get() / 100.0,
                merge=0.0,
                adaptive=false,
              ),
            )
          }))
          .offset(By(fn() {
            let (dx, dy) = clamped_pos()
            ((rw() - prism_w) / 2.0 + dx, (rh() - prism_h) / 2.0 + dy)
          }))
          .says(By(fn() { Some(@view.said(Group, label="Optical Prism")) }))
          .gesture(@ui.touch_slop(), press=fn(d) { last_drag.val = (d.wx, d.wy) }, drag=fn(d) {
            match d.kind {
              Down => last_drag.val = (d.wx, d.wy)
              Moved => {
                let (lx, ly) = last_drag.val
                let (px, py) = prism_pos.untracked()
                let max_x = @lg.clamp((rw() - prism_w) / 2.0 - 8.0, 0.0, 600.0)
                let max_y = @lg.clamp((rh() - prism_h) / 2.0 - 8.0, 0.0, 400.0)
                prism_pos.set((@lg.clamp(px + d.wx - lx, -max_x, max_x), @lg.clamp(py + d.wy - ly, -max_y, max_y)))
                last_drag.val = (d.wx, d.wy)
              }
              Up | Off => ()
            }
          })
          |> ignore
          // Minimal top-left HUD pill (leaves most of the prism transparent for refraction)
          prism.box(fn(top_row) {
            top_row.row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
            top_row.box(fn(pill) {
              pill
              .row(Is(true))
              .height(Is(Some(24.0)))
              .padding(Is((10.0, 0.0, 10.0, 0.0)))
              .radius(Is(12.0))
              .gap(Is(6.0))
              .lines_up(Is(Some(Middle)))
              .ground(By(fn() { if @lg.is_dark() { 0x0B0C1080L } else { 0xFFFFFFA6L } }))
              |> ignore
              pill.box(fn(dot) {
                dot
                .width(Is(Some(6.0)))
                .height(Is(Some(6.0)))
                .radius(Is(3.0))
                .shrink(Is(0.0))
                .ground(Is(monoid_vermilion))
                |> ignore
              })
              |> ignore
              pill.box(fn(lbl) {
                lbl
                .words(Is("DRAG PRISM"), look={ ..@lg.words_at(10.5, weight=600), tracking: Points(0.8) })
                .ink(By(fn() { @lg.colors().content }))
                |> ignore
              })
              |> ignore
            })
            |> ignore
          })
          |> ignore
          // Bottom HUD row: live offset coordinates left, prism icon right
          prism.box(fn(bot_row) {
            bot_row.row(Is(true)).lies_along(Is(Between)).lines_up(Is(Some(Middle))) |> ignore
            bot_row.box(fn(coord_pill) {
              coord_pill
              .height(Is(Some(24.0)))
              .padding(Is((10.0, 0.0, 10.0, 0.0)))
              .radius(Is(12.0))
              .lines_up(Is(Some(Middle)))
              .lies_along(Is(Middle))
              .ground(By(fn() { if @lg.is_dark() { 0x0B0C1078L } else { 0xFFFFFFA6L } }))
              |> ignore
              coord_pill.box(fn(w) {
                w
                .words(
                  By(fn() {
                    let (dx, dy) = clamped_pos()
                    "x \{fmt_signed(dx)}  y \{fmt_signed(dy)}"
                  }),
                  look=@lg.words_at(11.0, weight=500),
                )
                .ink(By(fn() { @lg.colors().content }))
                |> ignore
              })
              |> ignore
            })
            |> ignore
            bot_row.box(fn(ic_pill) {
              ic_pill
              .width(Is(Some(24.0)))
              .height(Is(Some(24.0)))
              .radius(Is(12.0))
              .lines_up(Is(Some(Middle)))
              .lies_along(Is(Middle))
              .ground(By(fn() { if @lg.is_dark() { 0x0B0C1078L } else { 0xFFFFFFA6L } }))
              |> ignore
              icon_prism(ic_pill, 15.0, fn() { @lg.colors().content })
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
    // Right floating Glass Inspector island (348pt wide, vertically centered)
    row.box(fn(insp_col) {
      insp_col.shrink(Is(0.0)).lies_along(Is(Middle)) |> ignore
      insp_col.box(fn(insp) {
      insp
      .width(Is(Some(348.0)))
      .shrink(Is(0.0))
      .radius(Is(44.0))
      .padding(Is((20.0, 18.0, 20.0, 20.0)))
      .gap(Is(12.0))
      .shadow(Is(@lg.shadow_default))
      .shadow_outside(Is(true))
      .glass(By(fn() { Some(inspector_glass()) }))
      |> ignore
      // Header row
      insp.box(fn(ih) {
        ih.row(Is(true)).lies_along(Is(Between)).lines_up(Is(Some(Middle))) |> ignore
        ih.box(fn(l) {
          l
          .words(Is("OPTICAL PARAMETERS"), look={ ..@lg.words_at(11.0, weight=600), tracking: Points(0.9) })
          .ink(By(fn() { @lg.alpha(@lg.colors().content, 0.62) }))
          |> ignore
        })
        |> ignore
        ih.box(fn(r) {
          r
          .words(Is("iOS 27 SDF"), look=@lg.words_at(11.0, weight=500))
          .ink(By(fn() { @lg.alpha(@lg.colors().content, 0.52) }))
          |> ignore
        })
        |> ignore
      })
      |> ignore
      // Three live optical parameter sliders
      param_slider(
        insp,
        "Refraction",
        fn() { "\{refraction_val.get().round().to_int()} px" },
        fn() { refraction_val.get() },
        fn(v) { refraction_val.set(v) },
        0.0,
        56.0,
        drag?=held.map(fn(h) { h.slider }),
      )
      param_slider(
        insp,
        "Chroma",
        fn() { fmt_chroma(chroma_val.get()) },
        fn() { chroma_val.get() },
        fn(v) { chroma_val.set(v) },
        0.0,
        15.0,
      )
      param_slider(
        insp,
        "Blur",
        fn() { "\{fmt_tenth(blur_val.get())} pt" },
        fn() { blur_val.get() },
        fn(v) { blur_val.set(v) },
        0.0,
        12.0,
      )
      // Toggles row: Dark + Grid
      insp.box(fn(toggles) {
        toggles.row(Is(true)).gap(Is(20.0)).lines_up(Is(Some(Middle))).padding(Is((0.0, 2.0, 0.0, 2.0))) |> ignore
        toggles.box(fn(t1) {
          t1.row(Is(true)).gap(Is(8.0)).lines_up(Is(Some(Middle))) |> ignore
          @lg.liquid_toggle_node(t1, fn() { @lg.is_dark() }, fn(v) { @lg.set_dark(Some(v)) }, fn() { "Dark" }) |> ignore
          t1.box(fn(lbl) {
            lbl.words(Is("Dark"), look=@lg.words_at(12.5, weight=500)).ink(By(fn() { @lg.colors().content })) |> ignore
          })
          |> ignore
        })
        |> ignore
        toggles.box(fn(t2) {
          t2.row(Is(true)).gap(Is(8.0)).lines_up(Is(Some(Middle))) |> ignore
          @lg.liquid_toggle_node(
            t2,
            fn() { grid_on.get() },
            fn(v) { grid_on.set(v) },
            fn() { "Grid" },
            drag?=held.map(fn(h) { h.toggle }),
          )
          |> ignore
          t2.box(fn(lbl) {
            lbl.words(Is("Grid"), look=@lg.words_at(12.5, weight=500)).ink(By(fn() { @lg.colors().content })) |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
      // Live MoonBit code pill
      insp.box(fn(code) {
        code
        .radius(Is(14.0))
        .padding(Is((12.0, 8.0, 12.0, 8.0)))
        .ground(By(fn() { if @lg.is_dark() { 0x090A0E7AL } else { 0x1417200FL } }))
        .edge(By(fn() { (1.0, if @lg.is_dark() { 0xFFFFFF14L } else { 0x14172014L }) }))
        |> ignore
        code.box(fn(w) {
          w
          .words(
            By(fn() {
              let b = fmt_tenth(blur_val.get())
              let rf = refraction_val.get().round().to_int()
              let ch = fmt_chroma(chroma_val.get())
              "Glass::liquid(blur: \{b}, refraction: \{rf},\n  chroma: \{ch})"
            }),
            look={ ..@lg.words_at(11.5, weight=500, wrap=true), line: 16.0 },
          )
          .ink(By(fn() { @lg.alpha(@lg.colors().content, 0.88) }))
          |> ignore
        })
        |> ignore
      })
      |> ignore
      // Bottom action row: Reset + Publish
      insp.box(fn(acts) {
        acts.row(Is(true)).gap(Is(10.0)).lines_up(Is(Some(Middle))) |> ignore
        acts.box(fn(b1) {
          b1.grow(Is(1.0)) |> ignore
          @lg.liquid_button_node(
            b1,
            fn() { "Reset" },
            fn() {
              prism_pos.set((0.0, 0.0))
              refraction_val.set(28.0)
              chroma_val.set(6.0)
              blur_val.set(1.8)
              grid_on.set(true)
            },
            light?=held.map(fn(h) { h.button }),
          )
          |> ignore
        })
        |> ignore
        acts.box(fn(b2) {
          b2.grow(Is(1.0)) |> ignore
          @lg.liquid_button_node(b2, fn() { "Publish" }, fn() { dialog_open.set(true) }, tint=monoid_vermilion) |> ignore
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
/// Scene 1 — `Deck`: centered symmetric two-column Bento (`max_width: 980`) with full 2×2 Monoid hardware deck +
/// semantic buttons on the left and a live continuous `Adaptive Luminance` bench on the right.
fn deck_scene(
  parent : @view.View,
  held : Held?,
  grid_on : @signals.Signal[Bool],
  boost : @signals.Signal[Bool],
  live_lum : @signals.Signal[Double],
  build_count : @signals.Signal[Int],
  last_action : @signals.Signal[String],
  reset_all : () -> Unit,
) -> Unit {
  parent.box(fn(wrap) {
    wrap.grow(Is(1.0)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
    wrap.box(fn(bento) {
      bento
      .row(Is(true))
      .width(Is(Some(980.0)))
      .max_width(Is(Some(980.0)), within=true)
      .gap(Is(24.0))
      .lines_up(Is(Some(Middle)))
      |> ignore
      // Left column: 2x2 full deck + action tiles + status capsule + 2x2 buttons
      bento.box(fn(left) {
        left.grow(Is(1.0)).gap(Is(18.0)) |> ignore
        left.box(fn(hdr) {
          hdr
          .words(Is("STUDIO DECK & ACTIONS"), look={ ..@lg.words_at(11.0, weight=600), tracking: Points(0.9) })
          .ink(By(fn() { @lg.alpha(@lg.colors().content, 0.60) }))
          |> ignore
        })
        |> ignore
        left.box(fn(deck_row) {
          deck_row.row(Is(true)).gap(Is(16.0)).lines_up(Is(Some(Middle))) |> ignore
          let wide = @lg.tile_size * 2.0 + @lg.tile_gap
          @lg.liquid_card_node(
            deck_row,
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
                rr.row(Is(true)).lies_along(Is(Between)) |> ignore
                @lg.liquid_control_item_node(
                  rr,
                  fn() { boost.get() },
                  fn(v) {
                    boost.set(v)
                    last_action.set(if v { "Glow boost on" } else { "Glow boost off" })
                  },
                  fn() { "Glow Boost" },
                  icon=fn(box, _ink) {
                    icon_bolt(box, 26.0, fn() {
                      if boost.get() || @lg.is_dark() { @lg.white } else { 0x1C2430D9L }
                    })
                  },
                )
                |> ignore
                // Fourth symmetric slot: Quick Reset
                @lg.liquid_control_item_node(
                  rr,
                  fn() { false },
                  fn(_) { reset_all() },
                  fn() { "Quick Reset" },
                  icon=fn(box, _ink) {
                    icon_refresh(box, 24.0, fn() { if @lg.is_dark() { @lg.white } else { 0x1C2430D9L } })
                  },
                )
                |> ignore
              })
              |> ignore
            },
          )
          |> ignore
          deck_row.box(fn(col) {
            col.gap(Is(@lg.tile_gap)) |> ignore
            col.box(fn(rr) {
              rr.row(Is(true)).gap(Is(@lg.tile_gap)).lines_up(Is(Some(Middle))) |> ignore
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
                fn() { reset_all() },
                angle=135.0,
                icon=fn(box, _ink) { icon_refresh(box, 26.0, tile_ink) },
              )
              |> ignore
            })
            |> ignore
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
        |> ignore
        // 2x2 semantic LiquidButton group
        left.box(fn(btns) {
          btns.gap(Is(12.0)) |> ignore
          btns.box(fn(r1) {
            r1.row(Is(true)).gap(Is(12.0)).lines_up(Is(Some(Middle))) |> ignore
            @lg.liquid_button_node(
              r1,
              fn() { "Build Native" },
              fn() {
                let n = build_count.untracked() + 1
                build_count.set(n)
                last_action.set("Built · #\{n}")
              },
            )
            |> ignore
            @lg.liquid_button_node(
              r1,
              fn() { "Inspect Tree" },
              fn() { last_action.set("Inspected tree") },
              surface=0xFFFFFF4DL,
            )
            |> ignore
          })
          |> ignore
          btns.box(fn(r2) {
            r2.row(Is(true)).gap(Is(12.0)).lines_up(Is(Some(Middle))) |> ignore
            @lg.liquid_button_node(
              r2,
              fn() { "Publish Release" },
              fn() { last_action.set("Ready to publish") },
              tint=monoid_vermilion,
            )
            |> ignore
            @lg.liquid_button_node(
              r2,
              fn() { "Preview Wasm" },
              fn() { last_action.set("Wasm preview live") },
              tint=0x1D68F5FFL,
            )
            |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
      // Right column: interactive Adaptive Luminance bench (440pt wide, concentric 44pt outer / 24pt inner + 20pt pad)
      bento.box(fn(right) {
        right
        .width(Is(Some(440.0)))
        .shrink(Is(0.0))
        .radius(Is(44.0))
        .padding(Is((20.0, 20.0, 20.0, 20.0)))
        .gap(Is(14.0))
        .shadow(Is(@lg.shadow_default))
        .shadow_outside(Is(true))
        .glass(By(fn() { Some(inspector_glass()) }))
        |> ignore
        right.box(fn(rh) {
          rh.row(Is(true)).lies_along(Is(Between)).lines_up(Is(Some(Middle))) |> ignore
          rh.box(fn(l) {
            l
            .words(Is("ADAPTIVE LUMINANCE"), look={ ..@lg.words_at(11.0, weight=600), tracking: Points(0.9) })
            .ink(By(fn() { @lg.alpha(@lg.colors().content, 0.62) }))
            |> ignore
          })
          |> ignore
          rh.box(fn(r) {
            r
            .words(Is("LIVE BENCH"), look={ ..@lg.words_at(10.5, weight=500), tracking: Points(0.6) })
            .ink(By(fn() { @lg.alpha(@lg.colors().content, 0.50) }))
            |> ignore
          })
          |> ignore
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
        right.box(fn(plates) {
          plates.row(Is(true)).gap(Is(16.0)).lines_up(Is(Some(Middle))) |> ignore
          // Left: dynamic live-luminance plate
          plates.box(fn(b) {
            b
            .width(Is(Some(192.0)))
            .height(Is(Some(184.0)))
            .radius(Is(24.0))
            .lines_up(Is(Some(Middle)))
            .lies_along(Is(Middle))
            .ground(By(fn() { @lg.lerp_color(0x14151BFFL, 0xF5F3EEFFL, @lg.clamp(live_lum.get() / 100.0, 0.0, 1.0)) }))
            |> ignore
            plate_stripes(
              b,
              24.0,
              fn() { @lg.lerp_color(0x2A2D38FFL, 0xDDD8CEFFL, @lg.clamp(live_lum.get() / 100.0, 0.0, 1.0)) },
              26.0,
              26.0,
            )
            @lg.liquid_adaptive_surface_node(b, fn() { @lg.clamp(live_lum.get() / 100.0, 0.0, 1.0) }, size=136.0)
            |> ignore
          })
          |> ignore
          // Right: fixed dark reference plate (0.08)
          plates.box(fn(b) {
            b
            .width(Is(Some(192.0)))
            .height(Is(Some(184.0)))
            .radius(Is(24.0))
            .lines_up(Is(Some(Middle)))
            .lies_along(Is(Middle))
            .ground(Is(0x14151BFFL))
            |> ignore
            plate_stripes(b, 24.0, fn() { 0x2A2D38FFL }, 26.0, 26.0)
            @lg.liquid_adaptive_surface_node(b, fn() { 0.08 }, size=136.0) |> ignore
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
/// Scene 2 — `Loupe`: centered compact two-tier specimen stage (`max_width: 960`) with single-layer Progressive Blur
/// above and a draggable MoonBit source Optical Loupe below.
fn loupe_scene(parent : @view.View) -> Unit {
  parent.box(fn(wrap) {
    wrap.grow(Is(1.0)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
    wrap.box(fn(col) {
      col.width(Is(Some(640.0))).max_width(Is(Some(640.0)), within=true).gap(Is(18.0)) |> ignore
      // Top tier: Progressive Blur
      col.box(fn(sec1) {
        sec1.gap(Is(10.0)) |> ignore
        sec1.box(fn(lbl) {
          lbl
          .words(Is("PROGRESSIVE BLUR"), look={ ..@lg.words_at(11.0, weight=600), tracking: Points(0.9) })
          .ink(By(fn() { @lg.alpha(@lg.colors().content, 0.60) }))
          |> ignore
        })
        |> ignore
        sec1.box(fn(b) {
          b.radius(Is(24.0)).clips(Is(true)) |> ignore
          b.box(fn(text) {
            text.padding(Is((22.0, 20.0, 22.0, 20.0))).ground(By(fn() { @lg.alpha(@lg.colors().paper, 0.56) }))
            |> ignore
            text.box(fn(t) {
              t
              .words(Is(progressive_copy), look=@lg.words_at(15.5, wrap=true))
              .ink(By(fn() { @lg.colors().content }))
              |> ignore
            })
            |> ignore
          })
          |> ignore
          b.box(fn(o) {
            o.over(Is(true)) |> ignore
            @lg.liquid_progressive_blur_node(o, words=fn() { "Progressive Blur · ui.monoid" }, height=74.0) |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
      // Bottom tier: Optical Loupe over MoonBit source code
      col.box(fn(sec2) {
        sec2.gap(Is(10.0)) |> ignore
        sec2.box(fn(lbl) {
          lbl
          .words(Is("OPTICAL LOUPE · MOONBIT SOURCE"), look={ ..@lg.words_at(11.0, weight=600), tracking: Points(0.9) })
          .ink(By(fn() { @lg.alpha(@lg.colors().content, 0.60) }))
          |> ignore
        })
        |> ignore
        @lg.liquid_magnifier_node(sec2, fn() { loupe_source_copy }, label=fn() { "Optical Loupe" }, at=(72.0, 28.0))
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// Spatial Optical Stage: full-viewport three-tier Flex column (zero outer scroll) with top Studio Bar, reactive
/// 3-scene stage (`Optics` / `Deck` / `Loupe`), and bottom centered floating glass Dock (`396 × 64`).
fn overview(
  root : @view.View,
  held : Held?,
  top : Double,
  grid_on : @signals.Signal[Bool],
  boost : @signals.Signal[Bool],
  dialog_open : @signals.Signal[Bool],
) -> Unit {
  let scene = @signals.signal(0)
  let refraction_val = @signals.signal(28.0)
  let chroma_val = @signals.signal(6.0)
  let blur_val = @signals.signal(1.8)
  let prism_pos = @signals.signal(if held is Some(_) { (36.0, -18.0) } else { (0.0, 0.0) })
  let live_lum = @signals.signal(88.0)
  let build_count = @signals.signal(0)
  let last_action = @signals.signal("60 fps · SDF Glass")
  let reset_all = fn() {
    prism_pos.set((0.0, 0.0))
    refraction_val.set(28.0)
    chroma_val.set(6.0)
    blur_val.set(1.8)
    live_lum.set(88.0)
    grid_on.set(true)
    boost.set(false)
    last_action.set("60 fps · SDF Glass")
  }
  root.box(fn(stage_col) {
    stage_col
    .grow(Is(1.0))
    .clips(Is(true))
    .padding(Is((28.0, 18.0 + top, 28.0, 18.0)))
    .gap(Is(14.0))
    |> ignore
    // 1. Top Studio Bar (height 36)
    studio_bar(stage_col, dialog_open)
    // 2. Center Main Stage (switched by bottom Dock)
    stage_col.box(fn(center) {
      center.grow(Is(1.0)).clips(Is(true)) |> ignore
      center.pick(fn() { scene.get() }, at_once=true, fn(scene_host, idx) {
        scene_host.grow(Is(1.0)).clips(Is(true)) |> ignore
        match idx {
          1 => deck_scene(scene_host, held, grid_on, boost, live_lum, build_count, last_action, reset_all)
          2 => loupe_scene(scene_host)
          _ =>
            optics_scene(
              scene_host,
              held,
              grid_on,
              refraction_val,
              chroma_val,
              blur_val,
              prism_pos,
              dialog_open,
            )
        }
      })
    })
    |> ignore
    // 3. Bottom Centered Floating Glass Dock (396 × 64, pinned cleanly to viewport bottom)
    stage_col.box(fn(dock_row) {
      dock_row.shrink(Is(0.0)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
      dock_row.box(fn(dock_w) {
        dock_w.width(Is(Some(396.0))).shrink(Is(0.0)) |> ignore
        @lg.liquid_bottom_tabs_node(
          dock_w,
          ["Optics", "Deck", "Loupe"],
          fn() { scene.get() },
          fn(i) { scene.set(i) },
          label="Stage scenes",
          faces=[
            studio_tab_face("Optics", icon_prism),
            studio_tab_face("Deck", icon_sliders),
            studio_tab_face("Loupe", icon_terminal),
          ],
          drag?=held.map(fn(h) { h.tabs }),
          light?=held.map(fn(h) { h.tabs_light }),
        )
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
  match held {
    Some(h) =>
      @signals.untracked(fn() {
        h.button.down(60.0, 24.0, 148.0, 48.0)
        h.button.moved(96.0, 30.0)
        h.toggle.press()
        h.slider.press()
        h.tabs.press()
        h.tabs.update_value(0.55)
        h.tabs_light.down(80.0, 32.0, 396.0, 64.0)
      })
    None => ()
  }
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

///|
/// The liquid merge & split page: interactive capillary drag + programmatic button toggle over the wallpaper.
fn merge_page(root : @view.View, top : Double) -> Unit {
  let drag_ctrl = @lg.LiquidMerge::new(separated=false)
  let toggle_ctrl = @lg.LiquidMerge::new(separated=false)
  root.box(fn(page) {
    page.grow(Is(1.0)).gap(Is(36.0)).padding(Is((48.0, 48.0 + top, 48.0, 48.0))).lines_up(Is(Some(Start))) |> ignore
    page.box(fn(s) {
      s.gap(Is(12.0)) |> ignore
      s.box(fn(t) {
        t.words(Is("Drag to Split & Fuse"), look=@lg.words_at(13.0, weight=600)).ink(By(fn() { @lg.alpha(@lg.colors().content, 0.6) }))
        |> ignore
      })
      |> ignore
      @lg.liquid_merge_node(s, controller=drag_ctrl, label=fn() { "Drag Droplet" }) |> ignore
    })
    |> ignore
    page.box(fn(s) {
      s.gap(Is(12.0)) |> ignore
      s.box(fn(t) {
        t.words(Is("Programmatic Split / Merge"), look=@lg.words_at(13.0, weight=600)).ink(By(fn() { @lg.alpha(@lg.colors().content, 0.6) }))
        |> ignore
      })
      |> ignore
      s.box(fn(r) {
        r.row(Is(true)).gap(Is(16.0)).lines_up(Is(Some(Middle))) |> ignore
        @lg.liquid_merge_node(r, controller=toggle_ctrl, label=fn() { "Toggle Droplet" }) |> ignore
        let btn_ref : Ref[@view.View?] = Ref(None)
        let btn = @lg.liquid_button_node(
          r,
          fn() { if toggle_ctrl.is_separated() { "Merge" } else { "Split" } },
          fn() {
            let at = match btn_ref.val {
              Some(n) => n.cause_at()
              None => 0.0
            }
            toggle_ctrl.set_separated(!toggle_ctrl.is_separated(), at~)
          },
        )
        btn_ref.val = Some(btn)
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}
