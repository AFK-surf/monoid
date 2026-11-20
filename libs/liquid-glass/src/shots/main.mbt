// The gallery's pictures and film, drawn offscreen by mbui's renderer (@film.picture, @film.film: a Tester with the
// host's own text and pictures), no window. Each page light and dark at 3 pixels a point; and a film at 60 frames a
// second of the film page's parts held, dragged and let go (film_script), light and dark.
//
//   MBUI_LG_SHOTS=<dir> shots.exe     <dir>/<page>-<light|dark>.png, <dir>/film-<light|dark>.mp4
//                                     <dir>/gallery-<page|hover|focus>-<light|dark>.png
//   MBUI_LG_ONLY=<page|film|gallery>  one of them alone
//
// The gallery (src/pages gallery.mbt) is drawn as src/gallery shows it, its bar over the overview, the interactive page
// and the dialog page (gone while the dialog is open), and over the overview under the pointer on Interactive and with
// the keyboard on the look (gallery_shots), its window as much taller as the bar takes.

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
/// The gallery's pictures: each its name, the page first shown, and what is done before it is drawn.
let gallery_shots : Array[(String, String, String)] = [
  ("overview", "overview", ""),
  ("interactive", "interactive", ""),
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
        fn(root) { @pages.page(root, page) },
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
  if failed > 0 {
    println("shots: \{failed} failed")
  }
}
