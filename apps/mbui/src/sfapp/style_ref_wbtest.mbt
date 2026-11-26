// What the styles' migration (mbui's ui/style.mbt) must leave as it was, byte for byte: the draw lists of the lock's
// waiting page in each of its states, and of screens with kit's components, narrow and wide, light and dark. Each is
// kept as its length and its FNV-1a hash; one that changes is a change to what is drawn.

///|
fn fnv(s : String) -> String {
  let mut h = 0x811c9dc5U
  for ch in s {
    h = (h ^ ch.to_int().reinterpret_as_uint()) * 0x01000193U
  }
  s.length().to_string() + ":" + h.to_string(radix=16)
}

///|
/// The system a screen this wide is drawn on: a phone's width a phone's (Android: the phone the screens are of), a
/// desktop's the Mac's.
fn platform_of(w : Double) -> Int {
  if w < @sf.medium_from {
    2
  } else {
    0
  }
}

///|
/// The app over fixture `mode`, `w` × `h`, its first frame (and, with `page`, a settings page pushed): the draw list.
fn screen_drawlist(mode : String, w : Double, h : Double, page? : String = "") -> String {
  new_run()
  @settings.reset()
  let src = fixture(mode)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform=platform_of(w))
  if page != "" {
    open_setting(page)
  }
  t.draw()
  t.run_for(@ui.move_most_ms)
  t.drawlist()
}

///|
let style_ref_sizes : Array[(String, Double, Double)] = [("narrow", 390.0, 844.0), ("wide", 1280.0, 800.0)]

///|
test "styles: the lock's waiting page, every state, drawn as before" {
  let out = StringBuilder()
  for state in ["waiting", "finding", "code", "wrong", "checking", "none", "failed", "nocode"] {
    for dark in ["", "-dark"] {
      for size in style_ref_sizes {
        let (name, w, h) = size
        let d = screen_drawlist("lock-" + state + dark, w, h)
        out.write_string(state + dark + " " + name + " " + fnv(d) + "\n")
      }
    }
  }
  // Home narrow top bar uses pure progressive scroll-edge glass + adaptive ink/pills.
  inspect(out.to_string(), content=(
    #|waiting narrow 28740:fe38e6d9
    #|waiting wide 65715:fecec222
    #|waiting-dark narrow 28659:c8554067
    #|waiting-dark wide 65546:1baa3fe0
    #|finding narrow 46541:447aedfb
    #|finding wide 84583:a8d475b5
    #|finding-dark narrow 46595:53883c63
    #|finding-dark wide 84549:803a7c53
    #|code narrow 32718:54f00286
    #|code wide 69833:7b0d732e
    #|code-dark narrow 32594:9ab800e0
    #|code-dark wide 69621:76e1d126
    #|wrong narrow 28705:894df07b
    #|wrong wide 65853:134bd288
    #|wrong-dark narrow 28808:a66a7d2e
    #|wrong-dark wide 65868:1e5c25ad
    #|checking narrow 35810:c522aa8d
    #|checking wide 73808:a69ef9e6
    #|checking-dark narrow 35903:f9d5cfd4
    #|checking-dark wide 73813:a43c825b
    #|none narrow 39576:f3f46d2c
    #|none wide 76824:f66b8e56
    #|none-dark narrow 39455:ebf0e07
    #|none-dark wide 76615:b50ddd9
    #|failed narrow 23967:58b14959
    #|failed wide 60511:b82a3014
    #|failed-dark narrow 23970:4557bf59
    #|failed-dark wide 60426:de6932f8
    #|nocode narrow 28740:fe38e6d9
    #|nocode wide 65715:fecec222
    #|nocode-dark narrow 28659:c8554067
    #|nocode-dark wide 65546:1baa3fe0
    #|














































  ))
}

///|
test "styles: screens with kit's components (switches, a sheet), drawn as before" {
  let out = StringBuilder()
  for dark in ["", "-dark"] {
    for size in style_ref_sizes {
      let (name, w, h) = size
      let home = screen_drawlist("settings" + dark, w, h, page="home")
      out.write_string("settings" + dark + " " + name + " " + fnv(home) + "\n")
      // (a station's page made once: what lies in the window drawn as the old list drew it, each of the four drawn to a
      // picture the same to the byte as main's at 16203ebae7, every glyph shown in the same box and every word seen at
      // the same place; the tree also hands the draw list the rows wholly under the window's foot, cut out by the page's
      // clip, and the shapes they draw, which the old list never drew)
      let station = screen_drawlist("settings" + dark, w, h, page="station:ws1/st1")
      out.write_string("station" + dark + " " + name + " " + fnv(station) + "\n")
      // a settings page's wait line, in its list's rows (built as the list is laid out: still.fail#791)
      let reading = screen_drawlist("settings-me-reading" + dark, w, h, page="me")
      out.write_string("me-reading" + dark + " " + name + " " + fnv(reading) + "\n")
    }
  }
  // (the wide ones, 2026-11-10: 共享调试 a row of the settings' sidebar on a computer too, 关于 under the window's
  // foot for it; the narrow ones, a phone's, had the row)
  // (a station's, 2026-11-15: 屏幕、浏览器与终端 a block a row, its card drawn as pieces of one ground meeting edge to
  // edge where it was one; every glyph at the same place, and what lies under the window's foot made only as it comes)
  // (the wide ones again, 2026-11-10: a sidebar's marks, words and headings 2 in, where its rows' foot capsules start)
  // (the wide ones again, 2026-11-16: a setting's switch on its title's line, line_end_node's, never across the middle
  // of the title and its note)
  // The narrow station settings use the wider glass switch in both themes.
  // Whole-pixel View::shift lets ride_kept_for hit across the narrow page slide, moving cached segment coordinates by 1 ULP (2e-14 px).
  // Adaptive liquid-glass back button icon bands encode center-relative offsets in slots 6-7 (+16 bytes on narrow screens).
  // iOS 27 pressed-lens calibration updated resting Switch shadow/track and Segmented track ground on wide station pages.
  // Narrow pushed page_node screens now use a single-row floating liquid glass top bar (circular < + inline title + glass trailing actions).
  // P0 Regular Liquid Glass optics fix restored recipe blur 2.0/2.2 on narrow bars/pills.
  // iOS 27.0 resting segmented/pill thumb aligned to #68686E dark fill with zero border/shadow in Light and Dark.
  // iOS 27.0 Regular Liquid Glass calibration sets full-res blur=1.2 on narrow bars/pills.
  // The settings' list has one more row, 进度汇报.
  // The settings' list has one more row, MCP 服务.
  // Pure progressive scroll-edge blur + bare adaptive ink + adaptive bar pills on narrow page_node bars.
  // The rail's workspace letter bare at rest, its ring only pointed at.
  inspect(out.to_string(), content=(
    #|settings narrow 116777:56ee14b1
    #|station narrow 97469:2987ccf7
    #|me-reading narrow 31397:fa2b2609
    #|settings wide 217971:2fabbc07
    #|station wide 289879:1d76cbdf
    #|me-reading wide 212690:7149de90
    #|settings-dark narrow 117012:c3e49cc1
    #|station-dark narrow 97277:c47c7a1e
    #|me-reading-dark narrow 31529:73f4c577
    #|settings-dark wide 217831:3f003495
    #|station-dark wide 289477:98cc3260
    #|me-reading-dark wide 212616:2246834b
    #|

  ))
}
