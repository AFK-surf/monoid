// Video thumbnail rounded-corner tests (no black rim from background under rounded corners) and shared flight_photo
// attachment helper.

///|
/// A photo the station keeps for chat s-c1, its size sent with it.
fn flight_photo() -> Attachment {
  {
    name: "photo.jpg",
    path: "uploads/fx/photo.jpg",
    size: 4096.0,
    width: 1200.0,
    height: 900.0,
    thumbhash: "",
    owner: "s-c1",
    upload: "",
    duration: 0.0,
    frames: 0,
    held: false,
  }
}

///|
/// The share of a white, opaque video frame's partly covered corner that would come from a black box under it. A
/// rounded edge is covered once; drawing another rounded black edge under it leaves black in those same pixels.
fn video_corner_black(t : @ui.Tester) -> Double raise {
  let insts = t.drawn_instances()
  let pictures = insts.mapi(fn(k, a) { (k, a) }).filter(fn(p) {
    let a = p.1
    a[5] == 4.0 && a[11] > 0.99 && a[24] > 1.0 && a[2] > 100.0
  })
  assert_eq(pictures.length(), 1, msg="rounded video pictures: \{Repr(pictures)}")
  let (index, picture) = pictures[0]
  let (x, y, right, foot) = (picture[16], picture[17], picture[18], picture[19])
  let frame = picture.copy()
  frame[0] = x
  frame[1] = y
  frame[2] = right - x
  frame[3] = foot - y
  frame[4] = 0.0
  let blacks = insts.mapi(fn(k, a) { (k, a) }).filter(fn(p) {
    let (k, a) = p
    k < index && a[5] == 0.0 && a[8] == 0.0 && a[9] == 0.0 && a[10] == 0.0 && a[11] > 0.0 &&
    (a[0] - x).abs() < 0.1 && (a[1] - y).abs() < 0.1 &&
    (a[0] + a[2] - right).abs() < 0.1 && (a[1] + a[3] - foot).abs() < 0.1
  })
  let scale = 2.0
  let side = picture[24] * 1.25
  let n = (side * scale).ceil().to_int()
  let mut partial = 0
  let mut black = 0.0
  for ix in 0..<n {
    for iy in 0..<n {
      let px = x + (ix.to_double() + 0.5) / scale
      let py = y + (iy.to_double() + 0.5) / scale
      let image = corner_cover(picture, px, py, scale)
      // Only where the picture covers the frame as much as it can: a letterbox's black outside the picture is wanted.
      if image > 0.0 && image < 1.0 && (image - corner_cover(frame, px, py, scale)).abs() < 0.000001 {
        partial += 1
        for (_, a) in blacks {
          black = dmax(black, corner_cover(a, px, py, scale) * a[11] * (1.0 - image))
        }
      }
    }
  }
  assert_true(partial > 0, msg="no partially covered corner pixels")
  black
}

///|
test "a video's fully shown poster leaves no black in its light rounded corners" {
  let t = video_in_chat()
  assert_eq(video_corner_black(t), 0.0)
}

///|
test "a letterboxed video's light picture has no black rim where it meets its rounded frame" {
  new_run()
  let src : Source = { ..fixture("chat"), poster: fn(_, _, _) { "wide-still" } }
  let a : Attachment = {
    name: "wide.mp4", path: "uploads/fx/wide.mp4", size: 4096.0, width: 360.0, height: 95.0,
    thumbhash: "", owner: "s-c1", upload: "", duration: 0.0, frames: 0, held: false,
  }
  let t = @ui.Tester::new(
    fn(c) { @sf.begin(c) |> ignore },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      root.box(fn(col) {
        col.width(Is(Some(300.0))) |> ignore
        @sfpages.message_files_of_node(col, src, tips, "ws1/st1", "s-c1", chat_view_made(Json::object({})), fn() { [a] }, false)
      })
      |> ignore
    },
    w=390.0,
    h=844.0,
    images=[("wide-still", 360, 95)],
  )
  t.draw()
  t.run_for(@ui.image_fade_ms)
  assert_eq(video_corner_black(t), 0.0)
}
