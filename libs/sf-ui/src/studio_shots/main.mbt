// Offscreen Metal captures and 60 fps interactive demo recording for ui.monoid · LIVE STUDIO.
//   MBUI_STD_SHOTS=<dir> studio_shots.exe
//     writes glass-hero-dark.png, glass-hero-light.png, std-hero-light.png, std-hero-dark.png, std-demo-dark.mp4
//   MBUI_STD_ONLY=glass-dark|glass-light|std-light|std-dark|stills|film
//     render a single target (or all 4 hero stills with "stills")

///|
/// Interactive 60 fps demo script at 1120x690:
/// 1. Switch OKLCH accent to Blue in header
/// 2. Switch Release Channel segmented control to Beta
/// 3. Click Run Build to advance progress bar and trigger Toast
/// 4. Switch bottom bar to Glass and trigger Separate
/// 5. Switch bottom bar to Tokens and click Teal accent
/// 6. Switch bottom bar to Overlays and open Confirm Dialog
let demo_script : String =
  #|wait 400
  #|tap Accent Blue
  #|wait 550
  #|tap Beta
  #|wait 550
  #|tap Run Build
  #|wait 750
  #|tap Glass
  #|wait 600
  #|tap Separate
  #|wait 650
  #|tap Tokens
  #|wait 600
  #|tap Theme Teal
  #|wait 650
  #|tap Overlays
  #|wait 550
  #|tap Open Confirm Dialog
  #|wait 850

///|
fn main {
  let dir = @ui.env("MBUI_STD_SHOTS")
  if dir == "" {
    println("studio_shots: MBUI_STD_SHOTS=<dir> says where the pictures go")
    return
  }
  let only = @ui.env("MBUI_STD_ONLY")
  let mut failed = 0
  let make_root = fn(dark : Bool, first_scene : Int) {
    fn(root : @view.View) {
      @sf.set_language(Some("en"))
      @sf.set_product("ui.monoid")
      @sf.set_accent("")
      @sf.set_dark(Some(dark))
      @studio_pages.studio(root, first_scene~)
    }
  }
  let capture = fn(name : String, dark : Bool, first_scene : Int) {
    let path = "\{dir}/\{name}.png"
    let ok = @film.picture(
      make_root(dark, first_scene),
      path~,
      w=1120.0,
      h=690.0,
      scale=2.0,
      dark~,
      theme=@sf.ui_theme_now,
      at=1000.0,
    )
    println("studio_shots: \{path} \{if ok { "ok" } else { "failed" }}")
    if !ok {
      failed += 1
    }
  }
  if only == "" || only == "stills" || only == "glass-dark" {
    capture("glass-hero-dark", true, 1)
  }
  if only == "" || only == "stills" || only == "glass-light" {
    capture("glass-hero-light", false, 1)
  }
  if only == "" || only == "stills" || only == "std-light" || only == "light" {
    capture("std-hero-light", false, 0)
  }
  if only == "" || only == "stills" || only == "std-dark" || only == "dark" {
    capture("std-hero-dark", true, 0)
  }
  if only == "" || only == "film" {
    let out = "\{dir}/std-demo-dark.mp4"
    let ok = @film.film(
      make_root(true, 0),
      script=demo_script,
      out~,
      w=1120.0,
      h=690.0,
      scale=2.0,
      dark=true,
      theme=@sf.ui_theme_now,
      fps=60,
    )
    println("studio_shots: \{out} \{if ok { "ok" } else { "failed" }}")
    if !ok {
      failed += 1
    }
  }
  if failed > 0 {
    println("studio_shots: \{failed} failed")
  }
}
