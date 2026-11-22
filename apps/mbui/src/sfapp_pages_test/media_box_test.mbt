// A message's pictures in one box whatever they are doing: waiting, shown, flying in from the composer (sfpages
// message_files.mbt, sfbase flight.mbt; the web's imageBox.ts, madeChat.ts landsAt).

///|
/// A strip far wider than tall (a 2000 × 40 screenshot of a line): in the chat 360 × 7.2, thinner than 16, so in a
/// box 16 thick, letterboxed.
fn strip(name : String) -> Attachment {
  {
    name,
    path: "uploads/fx/" + name,
    size: 4096.0,
    width: 2000.0,
    height: 40.0,
    thumbhash: "",
    owner: "s-c1",
    upload: "",
    duration: 0.0,
    frames: 0,
    held: false,
  }
}

///|
test "a strip too thin for its box takes its own share of it, centred; any other picture all of its box" {
  assert_eq(@sfpages.image_box(strip("line.png"), @sfpages.image_least), (360.0, 16.0, true))
  let (sw, sh) = @sfpages.picture_share(strip("line.png"), @sfpages.image_least)
  assert_true((sw - 1.0).abs() < 1.0e-9 && (sh - 0.45).abs() < 1.0e-9)
  let photo = { ..strip("photo.jpg"), width: 3024.0, height: 4032.0 }
  assert_eq(@sfpages.picture_share(photo, @sfpages.image_least), (1.0, 1.0))
}

///|
test "tall chat images have a wider cropped preview while short ones keep their size" {
  let tall = { ..strip("tall.png"), width: 400.0, height: 2000.0 }
  let box = fn(a : Attachment) {
    @sfpages.image_box(a, @sfpages.image_least, min_side=@sfpages.image_min_side)
  }
  assert_eq(box(tall), (160.0, 300.0, false))
  assert_eq(box({ ..tall, width: 1170.0, height: 2532.0 }), (160.0, 300.0, false))
  assert_eq(box({ ..tall, width: 800.0, height: 1200.0 }), (200.0, 300.0, false))
  assert_eq(box({ ..tall, width: 16.0, height: 100.0 }), (16.0, 100.0, false))
  // Old attachments can have only a ThumbHash. Its header here says a 1:7 portrait.
  assert_eq(box({ ..tall, width: 0.0, height: 0.0, thumbhash: "AAAAAQA=" }), (160.0, 300.0, false))
  assert_eq(box({ ..tall, width: 0.0, height: 0.0 }), (240.0, 160.0, false))
  // Video boxes have their own sizing and keep the whole still.
  assert_eq(@sfpages.image_box(tall, @sfpages.video_least), (96.0, 300.0, true))
  assert_eq(@sfpages.picture_share(tall, @sfpages.image_least, min_side=@sfpages.image_min_side), (1.0, 1.0))
}

///|
test "wide chat images have a taller cropped preview while narrow ones keep their size" {
  let wide = { ..strip("wide.png"), width: 2000.0, height: 400.0 }
  let box = fn(a : Attachment) {
    @sfpages.image_box(a, @sfpages.image_least, min_side=@sfpages.image_min_side)
  }
  assert_eq(box(wide), (360.0, 160.0, false))
  assert_eq(box(strip("line.png")), (360.0, 160.0, false))
  assert_eq(box({ ..wide, width: 1600.0, height: 900.0 }), (360.0, 203.0, false))
  assert_eq(box({ ..wide, width: 200.0, height: 4.0 }), (200.0, 16.0, true))
  // Its ThumbHash's header here says a 7:1 landscape.
  assert_eq(box({ ..wide, width: 0.0, height: 0.0, thumbhash: "AAAAAYA=" }), (360.0, 160.0, false))
  assert_eq(@sfpages.picture_share(wide, @sfpages.image_least, min_side=@sfpages.image_min_side), (1.0, 1.0))
}

///|
test "a wide picture fills its taller chat preview without stretching, its start shown" {
  new_run()
  let a = { ..strip("wide.png"), width: 2000.0, height: 400.0 }
  let src : Source = { ..fixture("chat"), file: fn(_, _, _) { "wide" } }
  let t = @ui.Tester::new(
    fn(c) { @sf.begin(c) |> ignore },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      @sfpages.message_files_of_node(root, src, tips, "ws1/st1", "s-c1", chat_view_made(Json::object({})), fn() { [a] }, false)
    },
    w=390.0,
    h=600.0,
    images=[("wide", 2000, 400)],
  )
  t.draw()
  t.run_for(@sfpages.reveal_ms)
  let images = t.drawn_images()
  // At 360 × 160, the first 360 points of the 800-point-wide picture are shown (its start, not its middle: a strip
  // cut from a page is as often bare in its middle).
  assert_true(images.iter().any(fn(i) {
    (i[2] - 360.0).abs() < 0.5 && (i[3] - 160.0).abs() < 0.5 &&
    (i[4] - 0.0).abs() < 0.001 && (i[5] - 0.0).abs() < 0.001 &&
    (i[6] - 0.45).abs() < 0.001 && (i[7] - 1.0).abs() < 0.001
  }), msg="\{Repr(images)}")
}

///|
test "a tall picture fills its wider chat preview without stretching" {
  new_run()
  let a = { ..strip("tall.png"), width: 400.0, height: 2000.0 }
  let src : Source = { ..fixture("chat"), file: fn(_, _, _) { "tall" } }
  let t = @ui.Tester::new(
    fn(c) { @sf.begin(c) |> ignore },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      @sfpages.message_files_of_node(root, src, tips, "ws1/st1", "s-c1", chat_view_made(Json::object({})), fn() { [a] }, false)
    },
    w=390.0,
    h=600.0,
    images=[("tall", 400, 2000)],
  )
  t.draw()
  t.run_for(@sfpages.reveal_ms)
  let images = t.drawn_images()
  // At 160 × 300, the first 300 points of the 800-point-tall picture are shown.
  assert_true(images.iter().any(fn(i) {
    (i[2] - 160.0).abs() < 0.5 && (i[3] - 300.0).abs() < 0.5 &&
    (i[4] - 0.0).abs() < 0.001 && (i[5] - 0.0).abs() < 0.001 &&
    (i[6] - 1.0).abs() < 0.001 && (i[7] - 0.375).abs() < 0.001
  }), msg="\{Repr(images)}")
  t.tap(80.0, 150.0)
  assert_true(viewer.get() is Some(_))
  let file = viewer.get().unwrap().file
  assert_eq((file.name, file.width, file.height), ("tall.png", 400.0, 2000.0))
}

///|
test "a letterboxed strip waiting to load: what it waits on is its share of its box, not the whole box" {
  new_run()
  // (a picture the station never answers: waited on the whole run)
  let src : Source = { ..fixture("chat"), file: fn(_, _, _) { "never/line.png" } }
  let m = message_of({
    "seq": 3,
    "ts": "3",
    "authorKind": "person",
    "author": "Mia",
    "text": "",
    "attachments": [attachment_json({ ..strip("line.png"), width: 200.0, height: 4.0 }, "s-c1")],
  })
  let t = @ui.Tester::new(
    fn(c) { @sf.begin(c) |> ignore },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      let here : @sfpages.MessageNodeHere = {
        station: "ws1/st1",
        session: "s-c1",
        view: fn() { chat_view_made(Json::object({})) },
        width: fn() { 760.0 },
        tips,
        stint: fn() { 0 },
        jump: None,
        picture: None,
      }
      @sfpages.message_row_node(root, src, here, fn() { m })
    },
    w=760.0,
    h=600.0,
  )
  t.draw()
  let ground = t.drawn_rects().filter(fn(r) { (r.2 - 200.0).abs() < 0.5 })
  // its own proportions (200 : 4), 200 × 4 in the middle of its 200 × 16
  assert_true(ground.iter().any(fn(r) { (r.3 - 4.0).abs() < 0.5 }), msg="\{Repr(ground)}")
  assert_false(ground.iter().any(fn(r) { (r.3 - 16.0).abs() < 0.5 }), msg="\{Repr(ground)}")
}
