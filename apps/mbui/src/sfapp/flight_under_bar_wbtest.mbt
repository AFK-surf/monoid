// A picture under a chat's bar opened (the user, 2026-10-30: 「它在挪出来前就盖在了顶栏上面」, a recording of its first
// frame over the bar): the bar over it every frame till it is out from under it, the first the flight is drawn in too.
// A picture seen before asks the core nothing as it opens, so the frame it sets out in is built once: built before it
// set out, the pages had built that frame as if it had not, the bar under the picture (set out as its node is made: sfbase
// viewer_tree.mbt's image_layer).
// A film the same, opening and closing (the user, 2026-11-09: 「这个避让怎么又他妈坏了？没有测试？」, a recording of a
// video flying over the phone's chat bar both ways): since the bar on 小屏 became the page's nodes (#4863) only a
// picture's flight was drawn in the page's slot under it, a film's in the viewer's layer over everything.

///|
/// What is drawn last at (`x`, `y`) in the frame just drawn, within what it is cut to: its kind (4 a picture), -1
/// nothing.
fn last_kind_at(t : @ui.Tester, x : Double, y : Double) -> Int {
  let mut kind = -1
  for i in t.drawn_instances() {
    let cut = i[18] <= i[16] || (x >= i[16] && x <= i[18] && y >= i[17] && y <= i[19])
    if i[11] > 0.5 && x >= i[0] && x <= i[0] + i[2] && y >= i[1] && y <= i[1] + i[3] && cut {
      kind = i[5].to_int()
    }
  }
  kind
}

///|
/// The chat's 演示录屏.mp4 (a long reply after it: MBUI_FIXTURE=chat-download-on) in a window `w` wide (`platform`'s), a
/// row up at a time from the chat's end until it is drawn; where it is. `answer`: what the host does for the app (Tester's
/// `finish`) done by it instead, at each frame's start.
fn film_in_chat(
  platform? : Int = 2,
  w? : Double = 390.0,
  answer? : ((@ui.Tester) -> Unit)? = None,
  nodes? : Bool = false,
) -> (@ui.Tester, Double, Double) {
  new_run()
  // (the chat's page made as nodes, its composer too, where `nodes` says so: sfbase's chat_page_nodes)
  @sfbase.hold_chat_page_nodes(Some(nodes))
  let src = fixture("chat-download-on")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let made : Ref[@ui.Tester?] = Ref(None)
  let before = fn() {
    match (made.val, answer) {
      (Some(t), Some(f)) => f(t)
      _ => ()
    }
  }
  let t = @ui.Tester::new(
    fn(c) { view(c, src) },
    tree=app_tree(src),
    w~,
    h=844.0,
    platform~,
    finish=(answer is None),
    before~,
  )
  made.val = Some(t)
  nav_rested(t)
  files_page_over(t, w, 844.0)
  let mut tries = 0
  while film_at(t).length() == 0 && tries < 12 {
    let (first, _) = t.visible()
    t.scroll_to(if first > 0 { first - 1 } else { 0 })
    t.draw()
    tries += 1
  }
  t.run_for(@ui.image_fade_ms)
  let at = film_at(t)
  assert_true(at.length() > 0) catch { _ => () }
  let (x, y) = at[0]
  (t, x, y)
}

///|
/// A film closed: the frame its player shows, asked for to go back with (Viewer::leaving_grab), answered with its
/// recording's frame, as a host answers it.
fn film_frame_answered(t : @ui.Tester) -> Unit {
  let asked = t.views().filter(fn(l) { l.has_prefix("control ") })
  guard asked.last() is Some(l) else { return }
  let view = l.split(" ").to_array()[1].to_owned()
  let frame = fixture_file_png("演示录屏.mp4")
  t.view_said("{\"still\":{\"view\":\{view}},\"b\":\"\{hex_bytes(frame)}\"}") |> ignore
  t.draw()
}

///|
/// The chat's compare.png (`film`: its recording, 演示录屏.mp4) in a window `w` wide (`platform`'s), seen once, wheeled
/// till its top is `top` (under the chat's bar), pressed and let go a little over its foot: what went wrong in the
/// frames while it went out from under the bar, and back in under it as it is closed (none, as it should be); on a
/// chat's page made as nodes where `nodes` says so (its thumbnail the end of View::shared's flight that stays).
fn picture_under_bar_faults(top : Double, platform : Int, w : Double, film? : Bool = false, nodes? : Bool = false) -> Array[String] {
  let (t, x, y) = if film { film_in_chat(platform~, w~, nodes~) } else { image_in_chat("compare.png", platform~, w~, nodes~) }
  // opened once and closed: its whole read and kept, as a picture seen before is (the frame it sets out in again asks
  // the core nothing, built once)
  t.tap(x, y)
  t.run_for(@ui.move_most_ms)
  t.back()
  if film {
    film_frame_answered(t)
  }
  t.run_for(@ui.move_most_ms)
  let i = t.drawn_images().filter(fn(i) { i[8] > 0.5 && x >= i[0] && x <= i[0] + i[2] && y >= i[1] && y <= i[1] + i[3] })
  assert_true(i.length() > 0) catch { _ => () }
  let (left, was, w0, h) = (i[0][0], i[0][1], i[0][2], i[0][3])
  t.wheel(x, y, was - top)
  t.run_for(@ui.scrollbar_hold_ms + @ui.scrollbar_fade_ms)
  let moved = t.drawn_images().filter(fn(i) { i[8] > 0.5 && (i[0] - left).abs() < 1.0 && (i[2] - w0).abs() < 1.0 })
  assert_true(moved.length() > 0) catch { _ => () }
  // (each frame built as a host builds it: not built once more to check its rows kept, which would draw a second
  // build of the frame)
  t.check_looks(false)
  t.drawn_again(true)
  let faults : Array[String] = []
  let frame = Ref(0)
  let set_out = Ref(false)
  let flying = Ref(false)
  // (the middle of the chat's bar over where the picture lies: its frosted glass across the picture's middle, the
  // highest)
  let mut under = -1.0
  for i in t.drawn_instances() {
    if i[5] == 5.0 && i[0] <= x && x <= i[0] + i[2] && i[3] < 200.0 && (under < 0.0 || i[1] + i[3] / 2.0 < under) {
      under = i[1] + i[3] / 2.0
    }
  }
  if under < 0.0 {
    faults.push("no bar over it")
  }
  t.each_frame(
    Some(fn() {
      let v = match viewer.get() {
        Some(v) => Some(v)
        None => pv_leaving.get()
      }
      let flies = match v {
        Some(v) => pic_flies(t, v)
        None => false
      }
      let over = last_kind_at(t, x, under) == 4
      // (the frame it sets out in: the bar over it)
      if flies && !flying.val && over {
        faults.push("frame \{frame.val}: set out over the bar")
      }
      // (the frame it comes back to rest in: the bar over it again)
      if !flies && flying.val && over {
        faults.push("frame \{frame.val}: landed over the bar")
      }
      if flies {
        set_out.val = true
      }
      flying.val = flies
      frame.val += 1
    }),
  )
  // (the press and its release, each in a frame of its own, as a host has them; then a frame at a time while it goes)
  t.press_at(x, top + h - h / 8.0)
  t.release(x, top + h - h / 8.0)
  let mut opened = 0.0
  while opened < @ui.move_most_ms {
    t.run_for(@ui.frame_period_default)
    opened += @ui.frame_period_default
  }
  // and closed: back in under the bar, the bar over it every frame from the one it has shrunk to its size in
  t.back()
  if film {
    film_frame_answered(t)
  }
  // (a frame at a time, as a host draws them while it goes)
  let mut gone = 0.0
  while gone < @ui.move_most_ms {
    t.run_for(@ui.frame_period_default)
    gone += @ui.frame_period_default
  }
  t.each_frame(None)
  t.check_looks(true)
  t.drawn_again(false)
  if !set_out.val {
    faults.push("it never flew")
  }
  faults
}

///|
test "a picture under a chat's bar, the old page's and one made as nodes: the bar over it every frame till it is out from under it" {
  // a phone's (a wide window, the tape's, open it in a tab beside the chat: view_beside_wbtest.mbt); its top a little
  // under the bar's, and half of it over the window's top
  for nodes in [false, true] {
    for screen in [(2, 390.0)] {
      for top in [10.0, -100.0] {
        let faults = picture_under_bar_faults(top, screen.0, screen.1, nodes~)
        assert_true(faults.is_empty(), msg="\{if nodes { "nodes" } else { "old" }}, \{screen.1} wide, its top at \{top}: \{Repr(faults)}")
      }
    }
  }
}

///|
test "a film under a chat's bar, the old page's and one made as nodes: the bar over it every frame till it is out from under it" {
  for nodes in [false, true] {
    for screen in [(2, 390.0)] {
      for top in [10.0, -100.0] {
        let faults = picture_under_bar_faults(top, screen.0, screen.1, film=true, nodes~)
        assert_true(faults.is_empty(), msg="\{if nodes { "nodes" } else { "old" }}, \{screen.1} wide, its top at \{top}: \{Repr(faults)}")
      }
    }
  }
}

///|
/// Where the chat's 演示录屏.mp4 is reached by a finger: called by its name on the old page, by what pressing it does
/// (「播放 …」) on a chat's page made as nodes.
fn film_at(t : @ui.Tester) -> Array[(Double, Double)] {
  let named = t.reachable("演示录屏.mp4")
  if named.length() > 0 {
    return named
  }
  t.reachable(@sf.t("web-main.file.play", args=[("name", "演示录屏.mp4")]))
}

///|
/// On a chat's page made as nodes (its thumbnails the window's tree's: View::shared's end that stays) in a window `w`
/// wide (`platform`'s), the chat's film (`film`) or compare.png opened and closed: what went wrong in each frame from the
/// press till its flight in ended and from the close till its flight back ended. In each, one picture of it drawn
/// (never none, never the thumbnail and its flight both, nor the player's own picture over the flight), the first where
/// the thumbnail is, each a step on from the one before; at rest in, where the viewer shows it; at rest out, the
/// thumbnail where it was.
fn tree_flight_faults(film : Bool, platform : Int, w : Double) -> Array[String] {
  let (t, x, y) = if film {
    film_in_chat(platform~, w~, nodes=true)
  } else {
    image_in_chat("compare.png", platform~, w~, nodes=true)
  }
  let faults : Array[String] = []
  guard pic_at(t, x, y) is Some((thumb, _)) else { return ["no thumbnail drawn"] }
  // (where pictures of it may be drawn: the window; one counted where its middle lies within the thumbnail's column
  // of the screen, as wide as the window's middle, and taller than a line of words)
  let of_it = fn(p : Array[Double]) { p[2] > 60.0 && p[3] > 40.0 && p[8] > 0.5 }
  let frame = Ref(0)
  let last : Ref[(Double, Double, Double, Double)?] = Ref(None)
  // (where its flight should set out: its thumbnail as it opens, where it rested as it closes)
  let from = Ref(thumb)
  let check = fn(said : String, id : String) {
    let pics = t.drawn_images().filter(of_it)
    match t.flight_of(id) {
      Some((r, _)) => {
        // (the thumbnail drawn nowhere while it flies, nor another picture of it over the flight's (the player's own,
        // as wide and tall as it, the same shape): one picture; the chat's others under the viewer's ground are theirs)
        let shape = r.2 / dmax(r.3, 1.0)
        // (its own picture drawn in its box as the end that stays draws it, contained: a point or two off the box)
        let near = fn(a : Double, b : Double, size : Double) { (a - b).abs() <= dmax(1.5, size * 0.02) }
        let others = pics.filter(fn(p) {
          !(near(p[0], r.0, r.2) && near(p[1], r.1, r.3) && near(p[2], r.2, r.2) && near(p[3], r.3, r.3))
        }).filter(fn(p) {
          ((p[0] - thumb.0).abs() < 1.5 && (p[1] - thumb.1).abs() < 1.5 && (p[2] - thumb.2).abs() < 1.5) ||
          (
            p[0] < r.0 + r.2 &&
            r.0 < p[0] + p[2] &&
            p[1] < r.1 + r.3 &&
            r.1 < p[1] + p[3] &&
            (p[2] / dmax(p[3], 1.0) - shape).abs() < shape * 0.1 &&
            p[2] * p[3] > r.2 * r.3 * 0.5
          )
        })
        if others.length() > 0 {
          faults.push("\{said} frame \{frame.val}: another picture beside its flight \{Repr(r)}: \{Repr(others.map(fn(p) { (p[0], p[1], p[2], p[3]) }))}")
        }
        match last.val {
          Some(l) if (l.1 - r.1).abs() > 120.0 || (l.2 - r.2).abs() > 160.0 =>
            faults.push("\{said} frame \{frame.val}: it jumped from \{Repr(l)} to \{Repr(r)}")
          None if (r.1 - from.val.1).abs() > 60.0 || (r.2 - from.val.2).abs() > 80.0 =>
            faults.push("\{said} frame \{frame.val}: it set out at \{Repr(r)}, not from \{Repr(from.val)}")
          _ => ()
        }
        last.val = Some(r)
      }
      None => if pics.length() == 0 { faults.push("\{said} frame \{frame.val}: no picture of it drawn") }
    }
    frame.val += 1
  }
  t.tap(x, y)
  let v = viewer.get()
  guard v is Some(v) else { return ["nothing opened"] }
  let id = v.thumb_id()
  t.each_frame(Some(fn() { check("in", id) }))
  t.draw()
  let end = t.flight_end(id).unwrap_or(t.time())
  if t.flight_end(id) is None {
    faults.push("it never flew in")
  }
  t.run_shown(end - t.time() + @ui.frame_period_default)
  t.each_frame(None)
  t.run_for(@ui.move_most_ms)
  // in: at rest where the viewer shows it, its flight's end (a film: its player's own picture there)
  match last.val {
    Some(l) => {
      // (the last frame it was seen flying a frame's way short of its end, its Move all but at rest: within two
      // hundredths of its size of where it rests)
      let near = fn(x : Double, y : Double, w : Double) {
        let k = dmax(2.0, l.2 * 0.02)
        (x - l.0).abs() < k && (y - l.1).abs() < k && (w - l.2).abs() < k
      }
      if !t.drawn_images().filter(of_it).iter().any(fn(p) { near(p[0], p[1], p[2]) }) &&
        !t.holes().iter().any(fn(h) { near(h.0, h.1, h.2) }) {
        faults.push("in: not at rest where its flight ended, \{Repr(l)}: \{Repr(t.drawn_images().filter(of_it).map(fn(p) { (p[0], p[1], p[2], p[3]) }))}")
      }
    }
    None => ()
  }
  // and closed: back into its thumbnail (a film's frame asked for first, given as a host gives it)
  match last.val {
    Some(l) => from.val = l
    None => ()
  }
  last.val = None
  frame.val = 0
  t.back()
  if film {
    film_frame_answered(t)
  }
  t.each_frame(Some(fn() { check("out", id) }))
  t.draw()
  let end = t.flight_end(id).unwrap_or(t.time())
  if t.flight_end(id) is None {
    faults.push("it never flew back")
  }
  t.run_shown(end - t.time() + @ui.frame_period_default)
  t.each_frame(None)
  t.run_for(@ui.move_most_ms)
  match pic_at(t, x, y) {
    Some((b, _)) if (b.0 - thumb.0).abs() < 1.5 && (b.1 - thumb.1).abs() < 1.5 && (b.2 - thumb.2).abs() < 1.5 => ()
    other => faults.push("out: the thumbnail not drawn where it was, \{Repr(thumb)}: \{Repr(other.map(fn(o) { o.0 }))}")
  }
  if viewer.get() is Some(_) || pv_leaving.get() is Some(_) {
    faults.push("out: the viewer not gone")
  }
  faults
}

///|
test "a chat's page made as nodes: a film and a picture fly from their thumbnails as they open and back into them as they close, one picture in every frame, on 小屏" {
  // (on 中屏 and 大屏 they open in a tab beside the chat: view_beside_wbtest.mbt)
  for screen in [(2, 390.0)] {
    for film in [true, false] {
      let faults = tree_flight_faults(film, screen.0, screen.1)
      assert_true(faults.is_empty(), msg="\{if film { "film" } else { "picture" }}, \{screen.1} wide: \{Repr(faults)}")
    }
  }
}

///|
/// The opacity of a ground over all the window drawn after the flying picture (the last picture drawn `w0` wide or
/// wider) at its middle, where one is.
fn ground_over_flight(t : @ui.Tester, w0 : Double) -> Double? {
  let inst = t.drawn_instances()
  let mut k = -1
  for j, i in inst {
    if i[5] == 4.0 && i[8] > 0.5 && i[2] >= w0 - 1.0 {
      k = j
    }
  }
  guard k >= 0 else { return None }
  let p = inst[k]
  let (cx, cy) = (p[0] + p[2] / 2.0, p[1] + p[3] / 2.0)
  let (ww, wh) = t.size()
  for j in (k + 1)..<inst.length() {
    let i = inst[j]
    if i[5] == 0.0 && i[11] > 0.02 && i[2] >= ww - 1.0 && i[3] >= wh - 1.0 && cx >= i[0] && cy >= i[1] {
      return Some(i[11])
    }
  }
  None
}

///|
/// The chat's compare.png (`film`: its recording) on a chat's page made as nodes in a window `w` wide (`platform`'s),
/// seen once, wheeled till half of it lies under the composer, pressed and let go a little under its top, then closed:
/// what went wrong in the frames while it flew (the user, 2026-11-17: 「飞行过程中盖在输入框上」). At its own size (going
/// out from under the composer, or coming back in under it) none of it drawn over the composer: what is drawn last where
/// the composer's words are is never it then.
fn picture_under_composer_faults(platform : Int, w : Double, film? : Bool = false) -> Array[String] {
  let (t, x, y) = if film {
    film_in_chat(platform~, w~, nodes=true)
  } else {
    image_in_chat("compare.png", platform~, w~, nodes=true)
  }
  t.tap(x, y)
  t.run_for(@ui.move_most_ms)
  t.back()
  if film {
    film_frame_answered(t)
  }
  t.run_for(@ui.move_most_ms)
  let i = t.drawn_images().filter(fn(i) { i[8] > 0.5 && x >= i[0] && x <= i[0] + i[2] && y >= i[1] && y <= i[1] + i[3] })
  guard i.length() > 0 else { return ["no thumbnail drawn"] }
  let (left, was, w0, h) = (i[0][0], i[0][1], i[0][2], i[0][3])
  // (the composer's words, its middle: what lies over the foot of the chat's list)
  // (its words as it waits for them: 发消息 by touch, 按空格输入 where the keyboard's space takes the hand to it)
  guard t.words().iter().find_first(fn(wd) { wd.0 == @sf.t("web-main.composer.placeholder") || wd.0 == "按空格输入" }) is Some(field) else {
    return ["no composer: \{Repr(t.words().filter(fn(wd) { wd.2 > 600.0 }).map(fn(wd) { (wd.0, wd.2) }))}"]
  }
  let under = field.2 + field.4 / 2.0
  // (half of it under the composer)
  let top = under - h / 2.0
  t.wheel(x, y, was - top)
  t.run_for(@ui.scrollbar_hold_ms + @ui.scrollbar_fade_ms)
  let moved = t.drawn_images().filter(fn(i) { i[8] > 0.5 && (i[0] - left).abs() < 1.0 && (i[2] - w0).abs() < 1.0 })
  guard moved.iter().any(fn(m) { (m[1] - top).abs() < 2.0 }) else {
    return ["not wheeled under the composer: \{Repr(moved.map(fn(m) { m[1] }))}, \{top}"]
  }
  t.check_looks(false)
  t.drawn_again(true)
  let faults : Array[String] = []
  let frame = Ref(0)
  let flew = Ref(false)
  t.each_frame(
    Some(fn() {
      let v = match viewer.get() {
        Some(v) => Some(v)
        None => pv_leaving.get()
      }
      if v is Some(v) && pic_flies(t, v) {
        flew.val = true
        // (at its own size, going out from under the composer or back in under it: a picture as wide as the thumbnail
        // over where the composer's words are, drawn last there)
        let own = t.drawn_images().iter().any(fn(i) {
          i[8] > 0.5 && (i[2] - w0).abs() < 1.0 && x >= i[0] && x <= i[0] + i[2] && under >= i[1] && under <= i[1] + i[3]
        })
        if own && last_kind_at(t, x, under) == 4 {
          faults.push("frame \{frame.val}: drawn over the composer at its own size")
        }
        // (nor faded under the viewer's ground: the flying picture, the last as wide as the thumbnail or wider, with
        // nothing over all the window drawn after it at its middle, seen through, as it goes out from under the composer)
        match ground_over_flight(t, w0) {
          Some(a) => faults.push("frame \{frame.val}: the viewer's ground over the flying picture at \{a}")
          None => ()
        }
      }
      frame.val += 1
    }),
  )
  t.press_at(x, top + h / 8.0)
  t.release(x, top + h / 8.0)
  if viewer.get() is None {
    faults.push("nothing opened")
  }
  t.run_shown(@ui.move_most_ms)
  t.back()
  if film {
    film_frame_answered(t)
  }
  t.run_shown(@ui.move_most_ms)
  t.each_frame(None)
  t.check_looks(true)
  t.drawn_again(false)
  if !flew.val {
    faults.push("it never flew")
  }
  faults
}

///|
test "a picture and a film half under the composer of a chat's page made as nodes: none of it over the composer at its own size, going out from under it and back in, on 小屏" {
  // (on 中屏 and 大屏 they open in a tab beside the chat: view_beside_wbtest.mbt)
  for screen in [(2, 390.0)] {
    for film in [false, true] {
      let faults = picture_under_composer_faults(screen.0, screen.1, film~)
      assert_true(
        faults.is_empty(),
        msg="\{if film { "film" } else { "picture" }}, \{screen.1} wide: \{Repr(faults)}",
      )
    }
  }
}
