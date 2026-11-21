// The gallery's pictures and film, drawn offscreen by mbui's renderer (@film.picture, @film.film: a Tester with the
// host's own text and pictures), no window. Each page light and dark at 3 pixels a point (or MBUI_LG_W/H/SCALE when
// set); a film at 60 fps of the film page's parts held, dragged and let go (`film_script`), light and dark; and
// `MBUI_LG_ONLY=stage` recording `stage-demo-dark.mp4` (1120×690 @ 2× 60 fps) of the Spatial Optical Stage.
//
//   MBUI_LG_SHOTS=<dir> shots.exe          <dir>/<page>-<light|dark>.png, <dir>/film-<light|dark>.mp4
//                                          <dir>/gallery-<page|hover|focus>-<light|dark>.png
//   MBUI_LG_ONLY=<page|film|gallery|stage> one of them alone
//   MBUI_LG_W / MBUI_LG_H / MBUI_LG_SCALE  optional override for page picture size & scale

///|
/// Parse a positive decimal string (e.g. "1120", "2.0") or return `fallback` when empty/invalid.
fn env_double(name : String, fallback : Double) -> Double {
  let s = @ui.env(name)
  if s == "" {
    return fallback
  }
  let mut val = 0.0
  let mut frac = 0.0
  let mut div = 1.0
  let mut in_frac = false
  let mut seen = false
  for ch in s {
    if ch == '.' && !in_frac {
      in_frac = true
    } else if ch >= '0' && ch <= '9' {
      seen = true
      let d = (ch.to_int() - '0'.to_int()).to_double()
      if in_frac {
        div = div * 10.0
        frac = frac + d / div
      } else {
        val = val * 10.0 + d
      }
    } else {
      return fallback
    }
  }
  if seen && val + frac > 0.0 { val + frac } else { fallback }
}

///|
/// What the film does, step by step (mbui's drive script; where each part is: src/pages film_page): the button held,
/// pulled and let go; the toggle's thumb dragged on and tapped off; the slider's thumb dragged along; the tabs' lens
/// dragged across to the third tab.
let film_script : String =
  #|wait 400
  #|holdon 300 90 18 500 @70,64
  #|wait 700
  #|drag 62 142 30 0 400
  #|wait 900
  #|tapxy 62 142
  #|wait 900
  #|drag 196 208 220 0 700
  #|wait 900
  #|drag 108 292 270 0 800
  #|wait 1200

///|
/// Interactive 60 fps demo of the 1120×690 Spatial Optical Stage: drag the Glass Prism across the Monoid Vermilion
/// sun, inverse-luminance plate, and `ui.monoid` wordmark -> drag Refraction & Chroma sliders -> drag Dock to Deck and
/// sweep Backdrop Luminance -> switch to Loupe and drag the optical magnifier across MoonBit source code.
let stage_script : String =
  #|wait 350
  #|drag 374 331 96 -42 650
  #|wait 250
  #|drag 470 289 -148 76 750
  #|wait 350
  #|drag 918 212 110 0 550
  #|wait 250
  #|drag 888 269 120 0 550
  #|wait 450
  #|drag 428 640 132 0 650
  #|wait 550
  #|drag 982 252 -260 0 750
  #|wait 550
  #|tapxy 692 640
  #|wait 550
  #|drag 632 370 -140 20 750
  #|wait 700

///|
/// Liquid merge & split demo script (src/pages merge_page):
/// 1) Drag right from merged to stretch bridge -> snap at break_gap -> auto-separate to 48pt
/// 2) Pause at full separation
/// 3) Drag left to gap ~4pt and release -> pause to prove strictly zero magnetic attraction
/// 4) Drag left past contact (gap <= 0) -> instant capillary fusion & absorption
/// 5) Tap Split then Merge button for programmatic transition
let merge_script : String =
  #|wait 350
  #|drag 248 118 34 0 550
  #|wait 700
  #|drag 304 118 -44 0 650
  #|wait 650
  #|drag 260 118 -14 0 350
  #|wait 750
  #|tap Split
  #|wait 850
  #|tap Merge
  #|wait 850

///|
/// Interactive 60 fps 2D free-drag demo of the 1120×690 Spatial Optical Stage `Merge` scene:
/// Optics -> tap Dock `Merge` (0.00px dock stability) -> drag `Drag Droplet` freely right & up past pinch-off ->
/// orbit across the top of the capsule -> hover ~3pt above the top edge (zero magnetic pull) -> press into the top
/// edge (instant 2D capillary fusion) -> pull upward past pinch-off and release (auto-separate) -> tap `Fuse Droplet`
/// (zero-pull 2D approach and contact fusion) -> return to `Optics`.
let stage_merge_script : String =
  #|wait 300
  #|tapxy 735 640
  #|wait 500
  #|drag 470 331 110 -120 650
  #|wait 350
  #|drag 580 211 -240 0 650
  #|wait 350
  #|drag 340 211 0 55 450
  #|wait 600
  #|drag 340 266 0 14 300
  #|wait 650
  #|drag 340 277 -10 -34 450
  #|wait 650
  #|tap Fuse Droplet
  #|wait 850
  #|tapxy 384 640
  #|wait 450

///|
/// The gallery's pictures: each its name, the page first shown, and what is done before it is drawn.
let gallery_shots : Array[(String, String, String)] = [
  ("overview", "overview", ""),
  ("interactive", "interactive", ""),
  ("merge", "merge", ""),
  ("dialog", "dialog", ""),
  ("hover", "overview", "hover Interactive"),
  ("focus", "overview", "key shift+tab"),
]

///|
fn main {
  let dir = @ui.env("MBUI_LG_SHOTS")
  if dir == "" {
    println("shots: MBUI_LG_SHOTS=<dir> says where the pictures go")
    return
  }
  let only = @ui.env("MBUI_LG_ONLY")
  let page_w = env_double("MBUI_LG_W", 1280.0)
  let page_h = env_double("MBUI_LG_H", 1040.0)
  let page_scale = env_double("MBUI_LG_SCALE", 3.0)
  let mut failed = 0
  for page in ["overview", "dialog", "interactive", "film", "merge"] {
    if only != "" && only != page {
      continue
    }
    for dark in [false, true] {
      @lg.set_dark(Some(dark))
      let path = "\{dir}/\{page}-\{if dark { "dark" } else { "light" }}.png"
      let (w, h, scale) = if page == "film" {
        (600.0, 400.0, 3.0)
      } else if page == "merge" {
        (560.0, 360.0, 3.0)
      } else {
        (page_w, page_h, page_scale)
      }
      let ok = @film.picture(
        fn(root) { @pages.page(root, page) },
        path~,
        w~,
        h~,
        scale~,
        dark~,
        at=1000.0,
      )
      println("shots: \{path} \{if ok { "ok" } else { "failed" }}")
      if !ok {
        failed += 1
      }
    }
  }
  if only == "" || only == "gallery" {
    for dark in [false, true] {
      for shot in gallery_shots {
        let (name, first, script) = shot
        @lg.set_dark(Some(dark))
        let path = "\{dir}/gallery-\{name}-\{if dark { "dark" } else { "light" }}.png"
        let ok = @film.picture(
          fn(root) { @pages.gallery(root, first) },
          path~,
          w=1280.0,
          h=1040.0 + @pages.bar_top + @pages.bar_h,
          scale=3.0,
          dark~,
          script~,
          at=1000.0,
        )
        println("shots: \{path} \{if ok { "ok" } else { "failed" }}")
        if !ok {
          failed += 1
        }
      }
    }
  }
  if only == "" || only == "film" {
    for dark in [false, true] {
      @lg.set_dark(Some(dark))
      let out = "\{dir}/film-\{if dark { "dark" } else { "light" }}.mp4"
      let ok = @film.film(
        fn(root) { @pages.page(root, "film") },
        script=film_script,
        out~,
        w=600.0,
        h=400.0,
        scale=2.0,
        dark~,
        fps=60,
      )
      println("shots: \{out} \{if ok { "ok" } else { "failed" }}")
      if !ok {
        failed += 1
      }
    }
  }
  if only == "stage" {
    @lg.set_dark(Some(true))
    let out = "\{dir}/stage-demo-dark.mp4"
    let ok = @film.film(
      fn(root) { @pages.page(root, "overview") },
      script=stage_script,
      out~,
      w=1120.0,
      h=690.0,
      scale=2.0,
      dark=true,
      fps=60,
    )
    println("shots: \{out} \{if ok { "ok" } else { "failed" }}")
    if !ok {
      failed += 1
    }
  }
  if only == "stage-merge" {
    let sizes : Array[(String, Double, Double, Int)] = [
      ("1120x637", 1120.0, 637.0, 587),
      ("1120x690", 1120.0, 690.0, 640),
    ]
    for sz in sizes {
      let (tag, w, h, dock_y) = sz
      for dark in [false, true] {
        @lg.set_dark(Some(dark))
        let path = "\{dir}/stage-merge-\{tag}-\{if dark { "dark" } else { "light" }}.png"
        let ok = @film.picture(
          fn(root) { @pages.page(root, "overview") },
          path~,
          w~,
          h~,
          scale=3.0,
          dark~,
          script="tapxy 735 \{dock_y}\nwait 1000",
          at=1000.0,
        )
        println("shots: \{path} \{if ok { "ok" } else { "failed" }}")
        if !ok {
          failed += 1
        }
      }
    }
    @lg.set_dark(Some(true))
    let out = "\{dir}/stage-merge-demo-dark.mp4"
    let ok = @film.film(
      fn(root) { @pages.page(root, "overview") },
      script=stage_merge_script,
      out~,
      w=1120.0,
      h=690.0,
      scale=2.0,
      dark=true,
      fps=60,
    )
    println("shots: \{out} \{if ok { "ok" } else { "failed" }}")
    if !ok {
      failed += 1
    }
  }
  if only == "" || only == "merge" {
    for dark in [false, true] {
      @lg.set_dark(Some(dark))
      let out = "\{dir}/merge-\{if dark { "dark" } else { "light" }}.mp4"
      let ok = @film.film(
        fn(root) { @pages.page(root, "merge") },
        script=merge_script,
        out~,
        w=560.0,
        h=360.0,
        scale=2.0,
        dark~,
        fps=60,
      )
      println("shots: \{out} \{if ok { "ok" } else { "failed" }}")
      if !ok {
        failed += 1
      }
    }
  }
  if failed > 0 {
    println("shots: \{failed} failed")
  }
}
