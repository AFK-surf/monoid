// A person's round picture and a station's mark as nodes (mark_node.mbt) drawn as the old views are (avatar,
// station_mark), each instance the same: a face's initial while its picture decodes, the picture at once once it is,
// the initial for good where it cannot be; its picture changed, the initial again till the new one is; a mark's glyph,
// its emoji, its picture put up (an address's, while it comes its emoji), a data URL's.

///|
/// What the window draws, each instance's numbers rounded to a hundredth (a glyph's place in its atlas left out: where
/// the order glyphs were first drawn put it), in one order; read at once.
fn marks_drawn(t : @ui.Tester) -> Array[String] {
  let all = t.drawn_instances().map(fn(a) {
    a
    .mapi(fn(j, x) {
      if a[5] == 1.0 && j == 12 {
        if x >= 16384.0 { "colour" } else { "mono" }
      } else if a[5] == 1.0 && j == 13 {
        "-"
      } else {
        ((x * 100.0).round() / 100.0).to_string()
      }
    })
    .join(",")
  })
  all.sort()
  all
}

///|
/// Two faces (one decoding, one that will not), 46 across, `pics` their pictures as they change; their decodes left
/// for the test to finish.
fn faces_tester(pics : @signals.Signal[(String, String)]) -> @ui.Tester {
  let images = [("lin.jpg", 96, 96), ("mo.jpg", 96, 96), ("lin2.jpg", 96, 96)]
  let t = @ui.Tester::new(fn(_c) {  }, images~, finish=false, w=200.0, h=200.0)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.lines_up(Is(Some(Start))) |> ignore
      avatar_node(b, fn() { "lin@example.com" }, fn() { "lin" }, fn() { pics.get().0 }, identity_mark)
      avatar_node(b, fn() { "mo@example.com" }, fn() { "mo" }, fn() { pics.get().1 }, identity_mark)
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// The faces' run: as first drawn; one decoded, one failed; Lin's picture changed (decoding); that one decoded. What is
/// drawn at each, and what was asked to be decoded.
fn faces_run() -> (Array[Array[String]], Array[(String, Int)]) {
  let pics = @signals.signal(("lin.jpg", "mo.jpg"), same=fn(a, b) { a == b })
  let t = faces_tester(pics)
  let seen = [marks_drawn(t)]
  let decoding = t.pending()
  t.finish(1, decoding[0].1)
  t.finish(1, decoding[1].1, ok=false)
  t.frame()
  seen.push(marks_drawn(t))
  pics.set(("lin2.jpg", "mo.jpg"))
  t.draw()
  seen.push(marks_drawn(t))
  let more = t.pending()
  t.finish(1, more[more.length() - 1].1)
  t.frame()
  seen.push(marks_drawn(t))
  (seen, t.image_loads())
}

///|
test "a face as a node: its initial while its picture decodes, the picture at once, the initial where it cannot be, its picture changed the initial till it is" {
  let (made, made_loads) = faces_run()
  assert_eq(made_loads.length(), 3)
  assert_true(made[1].iter().any(fn(x) { x.split(",").collect()[5].to_owned() == "4" }))
  assert_true(made[3].iter().any(fn(x) { x.split(",").collect()[5].to_owned() == "4" }))
}

///|
/// A mark of `emoji` and `icon`, `size` across, as a node, its picture put up (an address: the one picture_of hands
/// over as itself) decoding as the test says: what is drawn first, then (its decode finished) at the first frame after,
/// partway through its fade and once faded in.
fn mark_drawn(emoji : String, icon : String, size : Double) -> Array[Array[String]] {
  let images = [("https://example.com/m.png", 128, 96)]
  let t = @ui.Tester::new(fn(_c) {  }, images~, finish=false, w=200.0, h=200.0)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.lines_up(Is(Some(Start))) |> ignore
      station_mark_node(b, fn() { emoji }, fn() { icon }, size, fn() { theme().p.text }, fn() { 1 })
    })
    |> ignore
  })
  t.draw()
  let seen = [marks_drawn(t)]
  for p in t.pending() {
    t.finish(1, p.1)
  }
  let t0 = t.time()
  for dt in [16.0, 75.0, 200.0] {
    t.frame_at(t0 + dt)
    seen.push(marks_drawn(t))
  }
  seen
}

///|
test "a station's mark as a node: a glyph, a glyph in its colour, an emoji, a picture put up covering its square, fading in as it is decoded" {
  for m in [("", "glyph:laptop"), ("", "glyph:desktop:blue"), ("🚀", ""), ("🚀", "https://example.com/m.png")] {
    for size in [26.0, 46.0] {
      let made = mark_drawn(m.0, m.1, size)
      assert_true(made[made.length() - 1].length() > 0, msg="\{Repr(m)} at \{size}: drawn once decoded")
    }
  }
}

///|
/// A GIF 2 by 1 of two frames, 100 ms each (ui's gif_test's).
fn two_frames_gif() -> Bytes {
  Bytes::from_array([
    b'G', b'I', b'F', b'8', b'9', b'a', b'\x02', b'\x00', b'\x01', b'\x00', b'\x80', b'\x00', b'\x00', b'\xFF', b'\x00',
    b'\x00', b'\x00', b'\x00', b'\xFF', b'\x21', b'\xF9', b'\x04', b'\x00', b'\x0A', b'\x00', b'\x00', b'\x00', b'\x2C',
    b'\x00', b'\x00', b'\x00', b'\x00', b'\x02', b'\x00', b'\x01', b'\x00', b'\x00', b'\x02', b'\x02', b'\x04', b'\x0A',
    b'\x00', b'\x21', b'\xF9', b'\x04', b'\x00', b'\x0A', b'\x00', b'\x00', b'\x00', b'\x2C', b'\x00', b'\x00', b'\x00',
    b'\x00', b'\x02', b'\x00', b'\x01', b'\x00', b'\x00', b'\x02', b'\x02', b'\x4C', b'\x0A', b'\x00', b'\x3B',
  ])
}

///|
/// The pictures a moving GIF mark draws (its frames' keys, by the drawlist) at clock frames from its decode, its bytes
/// come after the Tester began and its frames decoded late: as a node.
fn gif_mark_frames() -> Array[String] {
  let url = "https://example.com/m.gif"
  let images = [(url, 2, 1), (url + "#0", 2, 1), (url + "#1", 2, 1)]
  let t = @ui.Tester::new(fn(_c) {  }, images~, finish=false, w=200.0, h=200.0)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.lines_up(Is(Some(Start))) |> ignore
      station_mark_node(b, fn() { "🚀" }, fn() { url }, 46.0, fn() { theme().p.text }, fn() { 1 })
    })
    |> ignore
  })
  // (its bytes come late: handed over after the Tester began, a GIF that moves)
  @ui.add_image(url, two_frames_gif())
  t.draw()
  let shown = fn() {
    t.drawlist().split("\n").filter(fn(l) { l.has_prefix("image ") }).map(fn(l) { l.to_owned() }).join(" | ")
  }
  let out = [shown()]
  // (its frames decoded late: each finished as asked, on clock frames)
  let t0 = t.time()
  for dt in [16.0, 40.0, 90.0, 110.0, 190.0, 210.0, 290.0, 310.0] {
    for p in t.pending() {
      t.finish(1, p.1)
    }
    t.frame_at(t0 + dt)
    out.push("\{dt}: " + shown())
  }
  out
}

///|
test "a mark's picture that is a GIF moving as a node: its frames in turn across two of their ends and round again, decoded late, on frames of the clock alone" {
  let made = gif_mark_frames()
  // (it moves: both its frames among what is drawn)
  let all = made.join(" ")
  assert_true(all.contains("m.gif#0") && all.contains("m.gif#1"), msg=all)
}

///|
test "a thing's tile as a node: its initial on its colour, in its corner" {
  let t = @ui.Tester::new(fn(_c) {  }, w=200.0, h=200.0)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.lines_up(Is(Some(Start))).gap(Is(8.0)) |> ignore
      tile_avatar_node(b, fn() { "github.com/acme/web-app" }, fn() { "web-app" }, fn() { "" }, 34.0, corner=small_corner)
      tile_avatar_node(b, fn() { "github.com/acme/notes" }, fn() { "notes" }, fn() { "" }, 20.0)
    })
    |> ignore
  })
  t.draw()
  assert_true(marks_drawn(t).length() > 0)
  assert_eq(t.audit(), [])
}
