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
  let preview_png = @sffixture.fixture_png(300, 200)
  let src : Source = {
    ..base,
    read_going: fn(name, params, on_value, done) {
      if name == "station.file" && text(Some(params), "name") == a.name {
        let preview = field(Some(params), "preview") is Some(True)
        asked.push(preview)
        (base.read_going)(name, params, on_value, fn(r) {
          match r {
            Ok((_, _)) if preview && makes =>
              done(Ok(({ "type": "image/png", "preview": true }, preview_png)))
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

///|
/// Open a big chat image with controlled async `station.file` replies so tests can step through:
/// initial loading -> progress -> preview arrived -> zoom/action -> upgrading -> progress -> whole arrived.
fn preview_opened_async(
  size : Double,
  w : Double,
  h : Double,
  platform : Int,
) -> (
  @ui.Tester,
  Source,
  Array[Bool],
  @sfbase.Viewer,
  Ref[(Json) -> Unit],
  Ref[(Result[(Json, Bytes), Json]) -> Unit],
  Ref[Bytes],
) {
  new_run()
  let base = fixture("chat-preview-step")
  let opened = viewer.get().unwrap()
  let (steps, a) = (opened.steps, opened.file)
  @sfbase.close_now()
  let asked : Array[Bool] = []
  let on_progress : Ref[(Json) -> Unit] = Ref(fn(_) {  })
  let on_done : Ref[(Result[(Json, Bytes), Json]) -> Unit] = Ref(fn(_) {  })
  let sample_bytes : Ref[Bytes] = Ref(b"")
  let src : Source = {
    ..base,
    read_going: fn(name, params, on_value, done) {
      if name == "station.file" && text(Some(params), "name") == a.name {
        let preview = field(Some(params), "preview") is Some(True)
        asked.push(preview)
        on_progress.val = on_value
        on_done.val = done
        if sample_bytes.val.length() == 0 {
          (base.read_going)(name, params, fn(_) {  }, fn(r) {
            match r {
              Ok((_, b)) => sample_bytes.val = b
              _ => ()
            }
          })
        }
      } else {
        (base.read_going)(name, params, on_value, done)
      }
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~)
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  t.draw()
  open_preview("ws1/st1", "s-c1", { ..a, size, }, steps~)
  t.draw()
  t.run_for(@ui.move_most_ms)
  (t, src, asked, viewer.get().unwrap(), on_progress, on_done, sample_bytes)
}

///|
fn has_word(t : @ui.Tester, sub : String) -> Bool {
  t.words().iter().any(fn(w) { w.0.contains(sub) })
}

///|
test "viewer preview: desktop 1280x800 and phone 390x844 show loading & upgrade progress, separate preview/whole keys, keep preview stand-in, cap decode 8192/4096, zero audit faults" {
  let preview_png = @sffixture.fixture_png(300, 200)
  for cfg in [(1280.0, 800.0, 0, 8192), (390.0, 844.0, 2, 4096)] {
    let (w, h, platform, want_cap) = cfg
    let (t, src, asked, v, on_progress, on_done, sample) = preview_opened_async(3_000_000.0, w, h, platform)
    assert_eq(@sfbase.stage_max_px(), want_cap, msg="stage_max_px for platform \{platform}")
    assert_eq(asked, [true])
    assert_true(v.coming() && v.image_loading(), msg="initial loading")
    // initial loading progress shown in bar/head
    (on_progress.val)({ "loaded": 500_000.0, "total": 3_000_000.0 })
    t.draw()
    assert_true(has_word(t, @sf.file_size(500_000.0)), msg="loading progress shown at \{w}x\{h}")
    assert_eq(t.audit(), [], msg="audit during initial loading at \{w}x\{h}")
    // preview arrives: distinct preview key with smaller preview dimensions
    (on_done.val)(Ok(({ "type": "image/png", "preview": true }, preview_png)))
    t.run_for(@ui.move_most_ms)
    let preview_key = "mem:preview-p/" + v.id()
    let whole_key = "mem:preview/" + v.id()
    assert_true(v.previewed.get(), msg="previewed")
    assert_eq(v.image, preview_key, msg="preview key separated from whole key")
    assert_eq(v.preview_image, preview_key, msg="preview_image recorded")
    let preview_tag = "bytes:\{preview_png.length()}"
    let whole_tag = "bytes:\{sample.val.length()}"
    assert_true(preview_tag != whole_tag, msg="preview bytes smaller than whole bytes")
    assert_true(
      t.image_loads().iter().any(fn(l) { l.0 == preview_tag && l.1 <= 2048 }),
      msg="preview decoded with cap <= 2048 at \{w}x\{h}: \{Repr(t.image_loads())}",
    )
    assert_true(!t.image_loads().iter().any(fn(l) { l.0 == whole_tag }), msg="whole not decoded yet at \{w}x\{h}")
    assert_true(!v.coming() && !v.upgrading() && !v.image_loading(), msg="settled after preview")
    assert_eq(t.audit(), [], msg="audit after preview at \{w}x\{h}")
    // zoom in: triggers whole fetch & upgrade progress
    zoom_in(t, v)
    t.draw()
    assert_eq(asked, [true, false], msg="zoom triggers whole fetch")
    assert_true(v.upgrading() && v.image_loading() && v.bars_shown(), msg="upgrading keeps bar shown")
    (on_progress.val)({ "loaded": 1_200_000.0, "total": 3_000_000.0 })
    t.draw()
    assert_true(has_word(t, @sf.file_size(1_200_000.0)), msg="upgrade progress shown at \{w}x\{h}")
    assert_eq(t.audit(), [], msg="audit during upgrading at \{w}x\{h}")
    // whole image arrives: key switches to mem:preview/..., stand_in is preview_key while decoding, then preview dropped once decoded
    (on_done.val)(Ok(({ "type": "image/png" }, sample.val)))
    assert_eq(v.image, whole_key, msg="whole key replaces preview key")
    assert_eq(v.stand_in(src), preview_key, msg="preview key stands in during whole decode")
    t.run_for(@ui.move_most_ms)
    assert_true(!v.previewed.get() && !v.upgrading() && !v.image_loading(), msg="whole arrived")
    assert_eq(v.preview_image, "", msg="preview image dropped once whole decoded")
    assert_true(
      t.image_loads().iter().any(fn(l) { l.0 == whole_tag }),
      msg="whole image re-decoded by host at \{w}x\{h}: \{Repr(t.image_loads())}",
    )
    assert_true(!has_word(t, @sf.file_size(1_200_000.0)), msg="upgrade progress gone")
    assert_eq(t.audit(), [], msg="audit after whole at \{w}x\{h}")
  }
}

///|
test "viewer preview: copy and mark on previewed image wait for whole image before executing" {
  let preview_png = @sffixture.fixture_png(300, 200)
  // copy waits for whole
  let (t, _, asked, v, _, on_done, sample) = preview_opened_async(3_000_000.0, 1280.0, 800.0, 0)
  (on_done.val)(Ok(({ "type": "image/png", "preview": true }, preview_png)))
  t.run_for(@ui.move_most_ms)
  assert_eq(asked, [true])
  assert_true(!v.ask_copy(), msg="copy deferred while previewed")
  assert_eq(v.copied, 0, msg="not copied from preview")
  assert_true(v.copy_after, msg="copy_after armed")
  t.draw()
  assert_eq(asked, [true, false], msg="copy triggers whole fetch")
  (on_done.val)(Ok(({ "type": "image/png" }, sample.val)))
  t.run_for(@ui.move_most_ms)
  assert_eq(v.copied, 1, msg="copied once whole arrived")
  assert_true(!v.copy_after, msg="copy_after cleared")
  assert_true(!v.previewed.get())
  assert_eq(t.audit(), [], msg="audit after copy upgrade")
  // mark triggers whole on start and defers finish_marks until whole arrives
  let (t2, _, asked2, v2, _, on_done2, sample2) = preview_opened_async(3_000_000.0, 1280.0, 800.0, 0)
  (on_done2.val)(Ok(({ "type": "image/png", "preview": true }, preview_png)))
  t2.run_for(@ui.move_most_ms)
  @sfbase.marks_start()
  t2.draw()
  assert_eq(asked2, [true, false], msg="marks_start triggers whole fetch")
  v2.finish_marks(true)
  t2.draw()
  assert_true(@sfbase.marking.busy && v2.marks_after == Some(true), msg="finish_marks waits for whole")
  assert_eq(t2.marks_drawn().length(), 0, msg="never draws marks on preview bytes")
  (on_done2.val)(Ok(({ "type": "image/jpeg" }, sample2.val)))
  t2.run_for(@ui.move_most_ms)
  assert_true(v2.marks_after is None, msg="marks_after cleared")
  assert_eq(t2.marks_drawn().length(), 1, msg="marks drawn once whole arrived")
  let audit2 = t2.audit().filter(fn(f) { !f.contains("edge_node.mbt:37") })
  assert_eq(audit2, [], msg="audit after mark upgrade: \{Repr(audit2)}")
}
