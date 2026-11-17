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
  inspect(out.to_string(), content=(
    #|waiting narrow 28266:48ebce4
    #|waiting wide 61683:3054759f
    #|waiting-dark narrow 28184:69addc0e
    #|waiting-dark wide 61509:b88b1cc7
    #|finding narrow 46043:94f8aac
    #|finding wide 80479:f262fd37
    #|finding-dark narrow 46096:a35103c2
    #|finding-dark wide 80440:df46edad
    #|code narrow 32244:2c263ebc
    #|code wide 65801:5a87a684
    #|code-dark narrow 32119:1dc2d214
    #|code-dark wide 65584:6a5cd420
    #|wrong narrow 28231:1639fd5e
    #|wrong wide 61821:7a816eec
    #|wrong-dark narrow 28333:70817de5
    #|wrong-dark wide 61831:7730c129
    #|checking narrow 35312:6c7fd234
    #|checking wide 69704:d1daefe4
    #|checking-dark narrow 35404:3fce8187
    #|checking-dark wide 69704:34a03a1
    #|none narrow 39102:bd17869f
    #|none wide 72792:a8dbb5f5
    #|none-dark narrow 38980:21de7adc
    #|none-dark wide 72578:6498f91a
    #|failed narrow 23493:7c14292
    #|failed wide 56479:9d82874d
    #|failed-dark narrow 23495:7fa9b70c
    #|failed-dark wide 56389:44b6de83
    #|nocode narrow 28266:48ebce4
    #|nocode wide 61683:3054759f
    #|nocode-dark narrow 28184:69addc0e
    #|nocode-dark wide 61509:b88b1cc7
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
  inspect(out.to_string(), content=(
    #|settings narrow 78734:6ed5f02a
    #|station narrow 77764:aac1b66a
    #|me-reading narrow 24224:218c49a4
    #|settings wide 195544:c8c7b08a
    #|station wide 260021:902ae401
    #|me-reading wide 190263:7fccc390
    #|settings-dark narrow 79002:b7e47031
    #|station-dark narrow 77674:f41d83a6
    #|me-reading-dark narrow 24352:6c5ccf8
    #|settings-dark wide 195440:653724
    #|station-dark wide 259700:8b112d25
    #|me-reading-dark wide 190225:5db95445
    #|




  ))
}
