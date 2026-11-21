// A picture's preview returns to its thumbnail with the shape the thumbnail actually has across the landing handoff.

///|
fn assert_corners_handoff(t : @ui.Tester, scale : Double, label : String) -> Unit raise {
  let pictures = fn() { t.drawn_instances().filter(fn(p) { p[5] == 4.0 && p[2] > 40.0 && p[11] > 0.5 }) }
  let before = pictures()
  assert_eq(before.length(), 1, msg="\{label}: thumbnail")
  let (bx, by, bw, bh) = (before[0][0], before[0][1], before[0][2], before[0][3])
  t.tap(bx + bw / 2.0, by + bh / 2.0)
  let v = viewer.get().unwrap()
  t.run_for(@ui.move_most_ms)
  t.back()
  let end = v.tree_way_end.get()
  assert_true(end > 0.0, msg="\{label}: tree flight back set out")
  // The host may draw for a vsync just after the flight's end while its logic is still just before it. The flight
  // must have the same coverage as the thumbnail, as must the thumbnail on the following frame.
  t.frame_shown_at(end - 0.01, end + 0.01)
  let landing = pictures()
  assert_eq(landing.length(), 1, msg="\{label}: landing")
  t.frame_at(end + @ui.frame_period_default)
  let after = pictures()
  assert_eq(after.length(), 1, msg="\{label}: landed")
  let mut bad = 0
  let origins = [
    (bx, by),
    (bx + bw - 40.0, by),
    (bx + bw - 40.0, by + bh - 40.0),
    (bx, by + bh - 40.0),
  ]
  for origin in origins {
    for ix in 0..<130 {
      for iy in 0..<130 {
        let x = origin.0 + (ix.to_double() + 0.5) / scale
        let y = origin.1 + (iy.to_double() + 0.5) / scale
        let want = corner_cover(before[0], x, y, scale)
        if (corner_cover(landing[0], x, y, scale) - want).abs() > 0.5 ||
          (corner_cover(after[0], x, y, scale) - want).abs() > 0.5 {
          bad += 1
        }
      }
    }
  }
  assert_eq(bad, 0, msg="\{label}: pixels changing at a corner")
}

///|
test "a picture returning to its chat message thumbnail keeps its rounded corners through the handoff" {
  let scale = 3.25
  new_run()
  let a = flight_photo()
  @sfbase.sent_picture_kept(@sfbase.sent_key("ws1/st1", a.path), "sent-key")
  let src = fixture("chat")
  let t = @ui.Tester::new(
    fn(c) { @sf.begin(c) |> ignore },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      root.box(fn(v) {
        v.grow(Is(1.0)) |> ignore
        v.box(fn(col) {
          col.over(Is(true)).width(Is(Some(300.0))) |> ignore
          @sfpages.message_files_of_node(col, src, tips, "ws1/st1", "s-c1", chat_view_made(Json::object({})), fn() { [a] }, false)
        })
        |> ignore
        @sfbase.viewer_node(v, src, fn() { v.window() })
      })
      |> ignore
    },
    w=390.0,
    h=844.0,
    scale~,
    images=[("sent-key", 1200, 900), ("mem:preview/ws1/st1/s-c1/uploads/fx/photo.jpg", 1200, 900)],
  )
  t.draw()
  t.run_for(@ui.image_fade_ms)
  assert_corners_handoff(t, scale, "message_files_of_node")
}

///|
test "a picture returning to a shared thumbnail keeps all four unlike corners through the handoff" {
  let scale = 3.25
  for corners in [(40.0, 40.0, 40.0, 40.0), (40.0, 10.0, 30.0, 20.0)] {
    new_run()
    let a = flight_photo()
    @sfbase.sent_picture_kept(@sfbase.sent_key("ws1/st1", a.path), "sent-key")
    let src = fixture("chat")
    let thumb_id = "ws1/st1/s-c1/" + a.path
    let t = @ui.Tester::new(
      fn(c) { @sf.begin(c) |> ignore },
      tree=fn(root) {
        @ui.set_tree_theme(@sf.ui_theme_now)
        root.box(fn(v) {
          v.grow(Is(1.0)) |> ignore
          v.box(fn(thumb) {
            thumb
            .over(Is(true))
            .width(Is(Some(300.0)))
            .height(Is(Some(225.0)))
            .corners(Is(Some(corners)))
            .clips(Is(true))
            .image_contains(Is(true))
            .image_covers(Is(true))
            .shared(Is(thumb_id), @motion.flight_by(@motion.moved()), stays=true)
            .presses(Is(true))
            .on_press(fn() { open_preview("ws1/st1", "s-c1", a) })
            |> ignore
            thumb.box(fn(pic) {
              pic
              .width(Is(Some(300.0)))
              .height(Is(Some(225.0)))
              .image(Is(Some(("sent-key", "", 4096))))
              .image_covers(Is(true))
              |> ignore
            })
            |> ignore
          })
          |> ignore
          @sfbase.viewer_node(v, src, fn() { v.window() })
        })
        |> ignore
      },
      w=390.0,
      h=844.0,
      scale~,
      images=[("sent-key", 1200, 900), ("mem:preview/ws1/st1/s-c1/uploads/fx/photo.jpg", 1200, 900)],
    )
    t.draw()
    t.run_for(@ui.image_fade_ms)
    assert_corners_handoff(t, scale, "\{Repr(corners)}")
  }
}
