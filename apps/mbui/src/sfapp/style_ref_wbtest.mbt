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
    #|waiting narrow 28264:ba6ceb2d
    #|waiting wide 61340:58dfaf67
    #|waiting-dark narrow 28182:619bad93
    #|waiting-dark wide 61166:a59a1537
    #|finding narrow 46041:a28d2bdf
    #|finding wide 80128:53fd1206
    #|finding-dark narrow 46094:30c3d6b1
    #|finding-dark wide 80089:e3938060
    #|code narrow 32242:a3becb0b
    #|code wide 65458:5d4d4f7c
    #|code-dark narrow 32117:5652fcc3
    #|code-dark wide 65241:78d4f47e
    #|wrong narrow 28229:7e53333f
    #|wrong wide 61478:8ab97cc2
    #|wrong-dark narrow 28331:af440018
    #|wrong-dark wide 61488:f0e5abf1
    #|checking narrow 35310:5805713d
    #|checking wide 69353:2e61bb1a
    #|checking-dark narrow 35402:3f56047e
    #|checking-dark wide 69353:6dbbc2c9
    #|none narrow 39100:b264c5b2
    #|none wide 72449:a597d550
    #|none-dark narrow 38978:d220c7f5
    #|none-dark wide 72235:c67f0dcd
    #|failed narrow 23491:4185eecb
    #|failed wide 56136:a04459d5
    #|failed-dark narrow 23493:2aa685b9
    #|failed-dark wide 56046:d401868b
    #|nocode narrow 28264:ba6ceb2d
    #|nocode wide 61340:58dfaf67
    #|nocode-dark narrow 28182:619bad93
    #|nocode-dark wide 61166:a59a1537
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
  inspect(out.to_string(), content=(
    #|settings narrow 79224:1e1c4ba
    #|station narrow 77764:dfaaba87
    #|me-reading narrow 24226:e04f7391
    #|settings wide 183891:88273550
    #|station wide 247752:38dd31b2
    #|me-reading wide 178610:9a65fafb
    #|settings-dark narrow 79492:72dbe261
    #|station-dark narrow 77674:804e74b
    #|me-reading-dark narrow 24354:78389ffb
    #|settings-dark wide 183799:3b8279ab
    #|station-dark wide 247443:9b28d061
    #|me-reading-dark wide 178584:3dfeb7f7
    #|




  ))
}
