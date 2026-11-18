// A chat's big image opened whole-window: its station's preview read first (`station.file` with `preview`), the image
// itself read in its place only as it is zoomed into or asked for (to share, save or install); one of preview_small or
// less, and one a station from before answers with the image itself, read as they were.

///|
/// The step fixture's first picture opened, said to be `size` bytes; its station answering a preview where it is asked
/// for one and `makes` says so (else the image itself, as a station from before). What each `station.file` of it asked
/// (whether with `preview`), in turn, and the viewer.
fn preview_opened(size : Double, makes : Bool) -> (@ui.Tester, Array[Bool], @sfbase.Viewer) {
  new_run()
  let base = fixture("chat-preview-step")
  let opened = viewer.get().unwrap()
  let (steps, a) = (opened.steps, opened.file)
  @sfbase.close_now()
  let asked : Array[Bool] = []
  let src : Source = {
    ..base,
    read_going: fn(name, params, on_value, done) {
      if name == "station.file" && text(Some(params), "name") == a.name {
        let preview = field(Some(params), "preview") is Some(True)
        asked.push(preview)
        (base.read_going)(name, params, on_value, fn(r) {
          match r {
            Ok((_, b)) if preview && makes =>
              done(Ok(({ "type": "image/jpeg", "preview": true }, b)))
            _ => done(r)
          }
        })
      } else {
        (base.read_going)(name, params, on_value, done)
      }
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0)
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  t.draw()
  open_preview("ws1/st1", "s-c1", { ..a, size, }, steps~)
  t.draw()
  t.run_for(@ui.move_most_ms)
  (t, asked, viewer.get().unwrap())
}

///|
/// Zoomed in twice its fitted size round the stage's middle, at once.
fn zoom_in(t : @ui.Tester, v : @sfbase.Viewer) -> Unit {
  v.zoom.zoom_to(v.zoom.fit() * 2.0, v.zoom.bw / 2.0, v.zoom.bh / 2.0, false, at=t.time())
  t.draw()
}

///|
test "viewer preview: a big image opens as its station's preview; zoomed into, the image itself read in its place, once" {
  let (t, asked, v) = preview_opened(3_000_000.0, true)
  assert_eq(asked, [true])
  assert_true(v.previewed.get())
  assert_true(v.bytes.get() is Some(_))
  // fitted and still past the longest move: nothing more read
  t.run_for(@ui.move_most_ms)
  assert_eq(asked, [true])
  zoom_in(t, v)
  t.run_for(@ui.move_most_ms)
  assert_eq(asked, [true, false])
  assert_true(!v.previewed.get())
  assert_true(v.bytes.get() is Some(_))
  // zoomed out and in again: the image itself is here, read no more
  v.zoom.fit_now(at=t.time())
  t.draw()
  zoom_in(t, v)
  t.run_for(@ui.move_most_ms)
  assert_eq(asked, [true, false])
}

///|
test "viewer preview: shared while a preview shows, the image itself read first (never the preview handed on)" {
  let (t, asked, v) = preview_opened(3_000_000.0, true)
  assert_eq(asked, [true])
  v.ask_share()
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_eq(asked, [true, false])
  assert_true(!v.previewed.get())
}

///|
test "viewer preview: an image of preview_small or less, read as it was: no preview asked" {
  let (_, asked, v) = preview_opened(@sfbase.preview_small, true)
  assert_eq(asked, [false])
  assert_true(!v.previewed.get())
}

///|
test "viewer preview: a station from before answers with the image itself: shown as it is, zoomed into, read no more" {
  let (t, asked, v) = preview_opened(3_000_000.0, false)
  assert_eq(asked, [true])
  assert_true(!v.previewed.get())
  zoom_in(t, v)
  t.run_for(@ui.move_most_ms)
  assert_eq(asked, [true])
}
