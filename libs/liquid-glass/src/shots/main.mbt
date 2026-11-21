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
/// Interactive 60 fps demo of the 1280×800 self-hosted `ui.monoid · Liquid Glass` 32-component library:
/// Controls (drag SegmentedControl lens, press button, increment Stepper) -> Inputs (Checkbox bounce,
/// Radio dot bounce, Chip bounce) -> Navigation (grouped List & Disclosure smooth chevron/slide) ->
/// Overlays (Select 180° chevron flip + refractive menu, Sheet with flat Done button) -> top floating-island
/// Light/Dark toggle -> Physics (360° Capillary Merge split & fuse).
let library_film_script : String =
  #|wait 350
  #|drag 380 345 190 0 500
  #|wait 350
  #|drag 570 345 -190 0 450
  #|wait 300
  #|tap Publish
  #|wait 300
  #|tap Increase Blur Radius
  #|wait 300
  #|tap Increase Blur Radius
  #|wait 350
  #|tap Inputs
  #|wait 450
  #|tap Chromatic dispersion
  #|wait 400
  #|tap iOS 27 Dark
  #|wait 400
  #|tap Vulkan
  #|wait 400
  #|tap Navigation
  #|wait 450
  #|tap Concentric Audit
  #|wait 350
  #|tap MoonBit API Snippet
  #|wait 550
  #|tap Overlays
  #|wait 450
  #|tap Material: iOS 27 Regular
  #|wait 550
  #|key escape
  #|wait 350
  #|tap Open Sheet
  #|wait 650
  #|key escape
  #|wait 400
  #|tapxy 1114 42
  #|wait 600
  #|tapxy 1176 42
  #|wait 500
  #|tap Physics
  #|wait 450
  #|tapxy 512 105
  #|wait 600
  #|tap Split Droplet
  #|wait 650
  #|tap Fuse Droplet
  #|wait 650

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
  let font = @ui.env("MBUI_LG_FONT")
  if font != "" {
    ignore(@ui.face_add(@hostapi.face_ui, font))
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
  if only == "sync-loupe" {
    // 1. Merge 4-step visual/state lockstep frames (1120×637 dark @ 3×):
    //    Stage at 1120×637: x=28, y=68, w=692, h=473 -> main_x=226 (254..446), sat_y=204.5 (y=272.5, center y=304.5).
    //    Initial dx = -6.5 (visual gap = -8.0) -> sat center x = 254 + 192 - 6.5 + 32 = 471.5 -> (472, 305).
    let merge_frames : Array[(String, String)] = [
      ("merge-sync-1-pre-split", "tapxy 735 587\nwait 400\ndrag 472 305 18 0 300"),
      ("merge-sync-2-post-split", "tapxy 735 587\nwait 400\ndrag 472 305 26 0 350\nwait 600"),
      ("merge-sync-3-near-hover", "tapxy 735 587\nwait 400\ndrag 472 305 26 0 300\nwait 600\ndrag 528 305 -45 0 400\nwait 300"),
      ("merge-sync-4-contact-fuse", "tapxy 735 587\nwait 400\ndrag 472 305 26 0 300\nwait 600\ndrag 528 305 -48 0 400\nwait 500"),
    ]
    @lg.set_dark(Some(true))
    for frame in merge_frames {
      let (fname, script) = frame
      let path = "\{dir}/\{fname}.png"
      let ok = @film.picture(
        fn(root) { @pages.page(root, "overview") },
        path~,
        w=1120.0,
        h=637.0,
        scale=3.0,
        dark=true,
        script~,
        at=1000.0,
      )
      println("shots: \{path} \{if ok { "ok" } else { "failed" }}")
      if !ok {
        failed += 1
      }
    }
    // 2. Loupe 3× shots (1120×637 light & dark, landing on `Metal, Vulkan` on line 4):
    //    Loupe tab is index 2 in 468pt dock (326..794) -> center x = 326 + 2 * 117 + 58 = 618, y = 587.
    for dark in [false, true] {
      @lg.set_dark(Some(dark))
      let path = "\{dir}/loupe-1120x637-\{if dark { "dark" } else { "light" }}.png"
      let ok = @film.picture(
        fn(root) { @pages.page(root, "overview") },
        path~,
        w=1120.0,
        h=637.0,
        scale=3.0,
        dark~,
        script="tapxy 618 587\nwait 600",
        at=1000.0,
      )
      println("shots: \{path} \{if ok { "ok" } else { "failed" }}")
      if !ok {
        failed += 1
      }
    }
    // 3. 60fps Merge lockstep clip (1120×637 dark @ 2×) to inspect exact pre-split (+9.0pt) & post-split frames:
    @lg.set_dark(Some(true))
    let clip_out = "\{dir}/merge-sync-demo.mp4"
    let clip_ok = @film.film(
      fn(root) { @pages.page(root, "overview") },
      script="tapxy 735 587\nwait 350\ndrag 472 305 26 0 800\nwait 500\ndrag 528 305 -45 0 400\nwait 400\ndrag 483 305 -10 0 300\nwait 450",
      out=clip_out,
      w=1120.0,
      h=637.0,
      scale=2.0,
      dark=true,
      fps=60,
    )
    println("shots: \{clip_out} \{if clip_ok { "ok" } else { "failed" }}")
    if !clip_ok {
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
  if only == "library" {
    let lib_scale = env_double("MBUI_LG_SCALE", 2.0)
    let lib_shots : Array[(String, Bool, Double, Double, String)] = [
      ("lib-controls-dark", true, 1280.0, 800.0, ""),
      ("lib-controls-light", false, 1280.0, 800.0, ""),
      ("lib-inputs-dark", true, 1280.0, 800.0, "tap Inputs\nwait 500"),
      ("lib-nav-dark", true, 1280.0, 800.0, "tap Navigation\nwait 500"),
      ("lib-nav-light", false, 1280.0, 800.0, "tap Navigation\nwait 500"),
      ("lib-overlays-dark", true, 1280.0, 800.0, "tap Overlays\nwait 500\ntap Open Menu\nwait 500"),
      ("lib-overlays-light", false, 1280.0, 800.0, "tap Overlays\nwait 500\ntap Open Menu\nwait 500"),
      ("lib-optics-dark", true, 1280.0, 800.0, "tap Optics\nwait 500"),
      ("lib-physics-dark", true, 1280.0, 800.0, "tap Physics\nwait 500"),
      // Exact 1120×690 website hero & scene shots
      ("web-lg-hero-dark", true, 1120.0, 690.0, ""),
      ("web-lg-hero-light", false, 1120.0, 690.0, ""),
      ("web-lg-overlays-dark", true, 1120.0, 690.0, "tap Overlays\nwait 500\ntap Open Menu\nwait 500"),
      ("web-lg-inputs-light", false, 1120.0, 690.0, "tap Inputs\nwait 500"),
      ("web-lg-physics-dark", true, 1120.0, 690.0, "tap Physics\nwait 500\ntapxy 512 105\nwait 500"),
    ]
    for item in lib_shots {
      let (name, dark, w, h, script) = item
      @lg.set_dark(Some(dark))
      let path = "\{dir}/\{name}.png"
      let ok = @film.picture(
        fn(root) { @pages.gallery(root, "library", chrome=true) },
        path~,
        w~,
        h~,
        scale=lib_scale,
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
  if only == "library-film" {
    @lg.set_dark(Some(true))
    let out = "\{dir}/lg-library-demo-dark.mp4"
    let ok = @film.film(
      fn(root) { @pages.gallery(root, "library", chrome=true) },
      script=library_film_script,
      out~,
      w=1280.0,
      h=800.0,
      scale=2.0,
      dark=true,
      fps=60,
    )
    println("shots: \{out} \{if ok { "ok" } else { "failed" }}")
    if !ok {
      failed += 1
    }
  }
  if failed > 0 {
    println("shots: \{failed} failed")
  }
}
