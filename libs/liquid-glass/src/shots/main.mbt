// The gallery's pictures and film, drawn offscreen by mbui's renderer (@film.picture, @film.film: a Tester with the
// host's own text and pictures), no window. Each page light and dark at 3 pixels a point; and a film at 60 frames a
// second of the film page's parts held, dragged and let go (film_script), light and dark.
//
//   MBUI_LG_SHOTS=<dir> shots.exe     <dir>/<page>-<light|dark>.png, <dir>/film-<light|dark>.mp4
//   MBUI_LG_ONLY=<page|film>          one of them alone

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
fn main {
  let dir = @ui.env("MBUI_LG_SHOTS")
  if dir == "" {
    println("shots: MBUI_LG_SHOTS=<dir> says where the pictures go")
    return
  }
  let only = @ui.env("MBUI_LG_ONLY")
  let mut failed = 0
  for page in ["overview", "dialog", "interactive", "film"] {
    if only != "" && only != page {
      continue
    }
    for dark in [false, true] {
      @lg.set_dark(Some(dark))
      let path = "\{dir}/\{page}-\{if dark { "dark" } else { "light" }}.png"
      let (w, h) = if page == "film" { (600.0, 400.0) } else { (1280.0, 1040.0) }
      let ok = @film.picture(
        fn(_c) {  },
        tree=fn(root) { @pages.page(root, page) },
        path~,
        w~,
        h~,
        scale=3.0,
        dark~,
        at=1000.0,
      )
      println("shots: \{path} \{if ok { "ok" } else { "failed" }}")
      if !ok {
        failed += 1
      }
    }
  }
  if only == "" || only == "film" {
    for dark in [false, true] {
      @lg.set_dark(Some(dark))
      let out = "\{dir}/film-\{if dark { "dark" } else { "light" }}.mp4"
      let ok = @film.film(
        fn(_c) {  },
        tree=fn(root) { @pages.page(root, "film") },
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
  if failed > 0 {
    println("shots: \{failed} failed")
  }
}
