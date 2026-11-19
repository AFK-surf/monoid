// What a film's thumbnail draws over its picture (its capsule: its length, how far it is brought), carried by its still
// as it flies: nodes of the viewer's own (viewer_tree.mbt's film_flight, @sf.video_capsule_node) made by what its chat
// registered last (Viewer::thumb_over), told as that changes (note_thumb's `over`, thumbs_said); none of the
// thumbnail's place read, so that the thumbnail moving alone makes it not again. A made-up chat registers the
// thumbnail: its film's length what a signal says, its place where another puts it.

///|
/// The viewer of 演示录屏.mp4 (1280 by 720) over a made-up chat whose thumbnail of it (`y` from the top) draws the
/// capsule of a film `ms` long over its picture, the viewer's node beside the chat, as the shells have it, 390 wide: the
/// thumbnail as big as the player draws its picture there (390 by 219.375), so that its flight moves it alone, as big
/// all the way. The display's frames 60 a second, said before it flies (its flight's frames the same at any
/// MBUI_TEST_FPS).
fn over_tester(ms : @signals.Signal[Double], y : @signals.Signal[Double]) -> @ui.Tester {
  new_run()
  let src : Source = { ..fixture("chat"), poster: fn(_, _, _) { "" } }
  let id = "ws1/st1/s-c1/uploads/fx/演示录屏.mp4"
  let t = @ui.Tester::new(
    fn(c) { @ui.old_views_here(c) },
    tree=fn(root) {
      root.box(fn(v) {
        v.grow(Is(1.0)) |> ignore
        @ui.old(v, fn(c) {
          // (what it draws over its picture said with it, the film's length as it is now)
          let duration = ms.get()
          c.box(style=@ui.style(w=Full, h=Full), fn() {
            c.box(style=@ui.style(h=Fixed(y.get())), fn() {  }) |> ignore
            let b = c.box(style=@ui.style(w=Fixed(390.0), h=Fixed(390.0 * 720.0 / 1280.0)), fn() {  })
            @sfbase.note_thumb(c, id, b, 12.0, picture="", over=Some({ duration, coming: None, corner: 12.0, seen: 1.0 }))
          })
          |> ignore
        })
        .over(Is(true))
        |> ignore
        @sfbase.viewer_node(v, src, fn() { v.window() })
      })
      |> ignore
    },
    w=390.0,
    h=844.0,
  )
  t.set_frame_period(1000.0 / 60.0)
  t.draw()
  t
}

///|
/// 演示录屏.mp4 opened over the made-up chat (as its thumbnail's press opens it).
fn over_open() -> Unit {
  let a : Attachment = {
    name: "演示录屏.mp4",
    path: "uploads/fx/演示录屏.mp4",
    size: 5242880.0,
    width: 1280.0,
    height: 720.0,
    thumbhash: "",
    owner: "s-c1",
    upload: "",
    duration: 0.0,
    frames: 0,
    held: false,
  }
  @sfbase.open_preview("ws1/st1", "s-c1", a)
}

///|
/// Where `word` is drawn now, seen (x, y, w, h), its alpha above nothing.
fn over_word(t : @ui.Tester, word : String) -> Array[(Double, Double, Double, Double)] {
  t.words().filter(fn(w) { w.0 == word && w.5 > 0.0 }).map(fn(w) { (w.1, w.2, w.3, w.4) })
}

///|
test "a film flying in (its still as big all the way), its thumbnail's capsule changed as it flies (between frames, the clock's alone): what its still carries says it from the next frame" {
  let ms = @signals.signal(5000.0)
  let y = @signals.signal(200.0)
  let t = over_tester(ms, y)
  over_open()
  t.draw()
  let v = viewer.get().unwrap()
  // (past the frames the test's steps build whole: the clock's own frames from here)
  t.frame_at(t.next_frame_time())
  assert_true(v.flies && !v.fly_back && v.fly.goes_at(t.ctx().moment()), msg="flying in")
  let was = @sf.clock(5000.0)
  let now = @sf.clock(10000.0)
  guard over_word(t, was) is [(_, _, w0, h0)] else { fail("its capsule over its still: \{Repr(t.words())}") }
  ms.set(10000.0)
  t.frame_at(t.next_frame_time())
  assert_true(v.flies && v.fly.goes_at(t.ctx().moment()), msg="still flying")
  assert_true(over_word(t, was).is_empty(), msg="its length gone")
  guard over_word(t, now) is [(_, _, w1, h1)] else { fail("its new length over its still: \{Repr(t.words())}") }
  assert_true(h1 == h0 && w1 > 0.0 && w0 > 0.0, msg="as high")
}

///|
/// A film flying in over the made-up chat, a frame of the clock's past its first (its capsule still seen: it goes by
/// halfway out), its thumbnail moved down 60 before it (`moved`) or not: where its capsule's length is drawn then.
fn over_moving(moved : Bool) -> (Double, Double, Double, Double) raise {
  let ms = @signals.signal(5000.0)
  let y = @signals.signal(200.0)
  let t = over_tester(ms, y)
  t.check_looks(false)
  over_open()
  t.draw()
  let v = viewer.get().unwrap()
  let word = @sf.clock(5000.0)
  t.frame_at(t.next_frame_time())
  guard over_word(t, word) is [_] else { fail("its capsule over its still: \{Repr(t.words())}") }
  if moved {
    y.set(260.0)
  }
  t.frame_at(t.next_frame_time())
  assert_true(v.flies && !v.fly_back && v.fly.goes_at(t.ctx().moment()), msg="still flying in")
  guard over_word(t, word) is [at] else { fail("its capsule over its still: \{Repr(t.words())}") }
  at
}

///|
test "a film flying in (its still as big all the way), its thumbnail moved alone as it flies (its capsule, its size the same): what its still carries moved with it" {
  let still = over_moving(false)
  let moved = over_moving(true)
  assert_true(moved.1 > still.1 + 1.0 && moved.2 == still.2 && moved.3 == still.3, msg="moved down with it, as big: \{Repr(moved)}, not moved \{Repr(still)}")
}
