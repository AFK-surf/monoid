// What sfbase keeps of pictures for a run is bounded: chats' pictures by their bytes (chat_images.mbt), the viewer's
// frames kept for thumbnails and its whole pictures (viewer.mbt), mermaid's charts (viz_mermaid.mbt). What is let go
// of has its image let go of too, never one something still shows, and is asked for again as it is shown again.

///|
/// A run of its own: no image handed over, nothing open over the pages.
fn bounds_run() -> Unit {
  @ui.Tester::new(fn(_c) {  }, w=200.0, h=100.0) |> ignore
  file_viewer_reset()
  viz_pages_reset()
}

///|
/// A picture of `n` bytes.
fn bounds_bytes(n : Int) -> Bytes {
  Bytes::make(n, b'\x01')
}

///|
/// A chat's image `name` of `station` (kept by session `key`).
fn bounds_attachment(name : String) -> Attachment {
  {
    name,
    path: "/w/" + name,
    size: 10.0,
    width: 10.0,
    height: 10.0,
    thumbhash: "",
    owner: "",
    upload: "",
    duration: 0.0,
    frames: 0,
    held: false,
  }
}

///|
test "chats' pictures beyond their budget: the least lately asked for let go of, image and all, and asked of the core again as it is shown again" {
  bounds_run()
  let images = ChatImages::new(budget=100)
  let asked : Map[String, Int] = Map([])
  let done : Map[String, (Result[(Json, Bytes?), Json]) -> Unit] = Map([])
  let get = fn(id : String) {
    images.get("st", id, "mem:ci/" + id, fn(_, d) {
      asked[id] = asked.get(id).unwrap_or(0) + 1
      done[id] = d
    })
  }
  get("a") |> ignore
  (done["a"])(Ok(({}, Some(bounds_bytes(40)))))
  get("b") |> ignore
  (done["b"])(Ok(({}, Some(bounds_bytes(40)))))
  assert_true(@ui.has_image("mem:ci/a") && @ui.has_image("mem:ci/b"))
  // (a shown again: b is now the least lately asked for)
  assert_eq(get("a"), "mem:ci/a")
  get("c") |> ignore
  (done["c"])(Ok(({}, Some(bounds_bytes(40)))))
  assert_false(@ui.has_image("mem:ci/b"), msg="the least lately asked for let go of")
  assert_true(@ui.has_image("mem:ci/a") && @ui.has_image("mem:ci/c"))
  assert_true(images.keys.get("b") is None)
  assert_eq(images.total.val, 80)
  // (shown again: asked of the core again, and here again as it answers)
  assert_eq(get("b"), "")
  assert_eq(asked["b"], 2)
  (done["b"])(Ok(({}, Some(bounds_bytes(40)))))
  assert_eq(get("b"), "mem:ci/b")
  assert_true(@ui.has_image("mem:ci/b"))
  assert_false(@ui.has_image("mem:ci/a"), msg="a, now the least lately asked for, let go of")
  assert_eq(images.total.val, 80)
}

///|
test "a chat's picture a node shows is never let go of for the budget, however long ago it was asked for" {
  bounds_run()
  let images = ChatImages::new(budget=100)
  let done : Map[String, (Result[(Json, Bytes?), Json]) -> Unit] = Map([])
  let get = fn(id : String) { images.get("st", id, "mem:ci/" + id, fn(_, d) { done[id] = d }) }
  get("a") |> ignore
  (done["a"])(Ok(({}, Some(bounds_bytes(40)))))
  let stop = @signals.effect(fn() { images.held_told("a") |> ignore })
  get("b") |> ignore
  (done["b"])(Ok(({}, Some(bounds_bytes(40)))))
  get("c") |> ignore
  (done["c"])(Ok(({}, Some(bounds_bytes(40)))))
  assert_true(@ui.has_image("mem:ci/a"), msg="read by a node: kept")
  assert_false(@ui.has_image("mem:ci/b"))
  stop()
}

///|
test "a viewer's whole picture given to a chat's picture: let go of for the budget only once no viewer shows it" {
  bounds_run()
  let images = ChatImages::new(budget=100)
  let key = "mem:preview/st/k//w/a.png"
  @ui.add_image(key, bounds_bytes(60))
  images.whole("a", key, size=60)
  assert_eq(whole_given.get(key), Some(1))
  let v = new_viewer("st", "k", bounds_attachment("a.png"), None, NoSteps)
  v.image = key
  viewer.set(Some(v))
  images.whole("b", "mem:ci/b", size=60)
  assert_true(images.keys.get("a") is None)
  assert_true(@ui.has_image(key), msg="the open viewer shows it")
  assert_true(whole_given.get(key) is None)
  // (the viewer closed: let go of with it, nothing else showing it)
  close_now()
  assert_false(@ui.has_image(key))
  assert_eq(v.image, "")
}

///|
test "a viewer let go of lets its whole picture go, unless a chat's picture was given it or another viewer shows it" {
  bounds_run()
  let images = ChatImages::new()
  let a = bounds_attachment("a.png")
  let key = "mem:preview/st/k//w/a.png"
  // (another viewer, a tab's, showing the same picture)
  let one = new_viewer("st", "k", a, None, NoSteps)
  let other = new_viewer("st", "k", a, None, NoSteps)
  @ui.add_image(key, bounds_bytes(10))
  one.image = key
  other.image = key
  pv_leaving.set(Some(other))
  one.let_go()
  assert_true(@ui.has_image(key), msg="another viewer shows it")
  // (given to a chat's picture: kept for it)
  images.whole("a", key, size=10)
  pv_leaving.set(None)
  other.let_go()
  assert_true(@ui.has_image(key), msg="a chat's picture shows it")
  images.clear()
  assert_true(whole_given.get(key) is None)
  // (nothing else showing it: let go of)
  other.image = key
  other.let_go()
  assert_false(@ui.has_image(key))
}

///|
test "a thumbnail's frame kept in place of another: the one before let go of once no viewer flies with it" {
  bounds_run()
  let v = new_viewer("st", "k", bounds_attachment("v.mp4"), None, NoSteps)
  let id = v.id()
  @ui.add_image("mem:pv-frame/1/v.mp4", bounds_bytes(10))
  pv_frame_keep(id, "mem:pv-frame/1/v.mp4", 1000.0)
  // (opened from it: what it leaves with)
  v.leaving_pic = "mem:pv-frame/1/v.mp4"
  viewer.set(Some(v))
  // (closed at a later place: its frame there none yet, the one before kept while a viewer holds it)
  pv_frame_keep(id, "", 2000.0)
  assert_true(@ui.has_image("mem:pv-frame/1/v.mp4"))
  @ui.add_image("mem:pv-frame/2/v.mp4", bounds_bytes(10))
  pv_frame_keep(id, "mem:pv-frame/2/v.mp4", 2000.0)
  assert_eq(pv_frames.get(id), Some(("mem:pv-frame/2/v.mp4", 2000.0)))
  assert_true(@ui.has_image("mem:pv-frame/1/v.mp4"))
  // (gone back into its thumbnail: let go of)
  viewer.set(None)
  pv_leaving.set(Some(v))
  v.leaving_pic = "mem:pv-frame/2/v.mp4"
  leaving_done()
  assert_false(@ui.has_image("mem:pv-frame/1/v.mp4"))
  assert_true(@ui.has_image("mem:pv-frame/2/v.mp4"), msg="its thumbnail's frame kept")
}

///|
test "thumbnails' frames beyond 64: the least lately kept let go of, its thumbnail told to show its still" {
  bounds_run()
  let told = Ref(0)
  let stop = @signals.effect(fn() {
    pv_frame_track("t0")
    told.val += 1
  })
  for i in 0..<65 {
    let key = "mem:pv-frame/\{i}/v.mp4"
    @ui.add_image(key, bounds_bytes(10))
    pv_frame_keep("t\{i}", key, 1000.0)
  }
  assert_eq(pv_frames.length(), 64)
  assert_true(pv_frames.get("t0") is None)
  assert_false(@ui.has_image("mem:pv-frame/0/v.mp4"))
  assert_true(@ui.has_image("mem:pv-frame/64/v.mp4"))
  assert_eq(told.val, 3, msg="told as it was kept and as it was let go of")
  stop()
}

///|
test "first frames beyond 64: the least lately asked for let go of, but not a picture a draft's file shows" {
  bounds_run()
  for i in 0..<65 {
    let key = "mem:pv-first/\{i}"
    @ui.add_image(key, bounds_bytes(10))
    pv_first["f\{i}"] = { view: None, picture: key }
    if i == 1 {
      writing_picture_put("d1", key)
    }
    pv_first_asked("f\{i}")
  }
  assert_eq(pv_first.length(), 64)
  assert_true(pv_first.get("f0") is None)
  assert_false(@ui.has_image("mem:pv-first/0"))
  pv_first["f65"] = { view: None, picture: "!" }
  pv_first_asked("f65")
  assert_true(pv_first.get("f1") is None)
  assert_true(@ui.has_image("mem:pv-first/1"), msg="a draft's file shows it")
  writings_reset()
}

///|
test "mermaid's charts beyond 64, or 16 MB of SVG: the least lately drawn let go of, picture and all" {
  bounds_run()
  for i in 0..<65 {
    mermaid_charts["c\{i}"] = ChartComing
    mermaid_touch("c\{i}")
    mermaid_chart_made("c\{i}", bounds_bytes(10), 10.0, 10.0)
    mermaid_trim("c\{i}")
  }
  assert_eq(mermaid_charts.length(), 64)
  assert_true(mermaid_charts.get("c0") is None)
  assert_false(@ui.has_image("mem:mermaid/c0"))
  assert_true(@ui.has_image("mem:mermaid/c1"))
  // (drawn again: kept as the latest)
  mermaid_touch("c1")
  mermaid_chart_made("big", bounds_bytes(16 * 1024 * 1024 - 100), 10.0, 10.0)
  mermaid_touch("big")
  mermaid_trim("big")
  assert_true(mermaid_charts.get("c2") is None)
  assert_true(mermaid_charts.get("c1") is Some(_))
  assert_true(mermaid_bytes.val <= 16 * 1024 * 1024)
  assert_true(mermaid_charts.get("big") is Some(_))
  viz_pages_reset()
  assert_eq(mermaid_bytes.val, 0)
  assert_true(mermaid_used.is_empty())
}

///|
test "a mermaid chart a node shows is never let go of for the bound; let go of once that node goes" {
  bounds_run()
  mermaid_given.val = true
  let src = made_source(call=fn(name, _, done) {
    if name == "mermaid.chart" {
      done(Ok({ "svg": "<svg xmlns=\"http://www.w3.org/2000/svg\"/>", "width": 10, "height": 10 }))
    } else {
      done(Err({ "code": "unknown_call", "message": name }))
    }
  })
  let on = @signals.signal(true)
  let t = @ui.Tester::new(
    fn(_c) {  },
    tree=fn(root) {
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      root.show(fn() { on.get() }, fn(b) {
        viz_mermaid_node(b, src, "st", fn() { "graph TD; A-->B" }, fn() { 0L }, tips)
      })
    },
    w=400.0,
    h=300.0,
  )
  t.run_for(@ui.move_most_ms)
  assert_eq(mermaid_shown.length(), 1)
  let key = mermaid_shown.keys().to_array()[0]
  assert_true(mermaid_charts.get(key) is Some(ChartMade(_, _, _, _)))
  // (64 charts more, each shown by a node too, drawn later than it: it is the least lately drawn)
  for i in 0..<64 {
    mermaid_charts["c\{i}"] = ChartComing
    mermaid_shown_by("", "c\{i}")
    mermaid_chart_made("c\{i}", bounds_bytes(10), 10.0, 10.0)
    mermaid_trim("c\{i}")
  }
  assert_eq(mermaid_charts.length(), 65)
  assert_true(mermaid_charts.get(key) is Some(ChartMade(_, _, _, _)), msg="shown by a node: kept")
  assert_true(@ui.has_image("mem:mermaid/" + key))
  // (its node gone: let go of then, more being kept than mermaid keeps)
  on.set(false)
  t.run_for(@ui.move_most_ms)
  assert_false(mermaid_shown.contains(key))
  assert_true(mermaid_charts.get(key) is None, msg="let go of as its node went")
  assert_false(@ui.has_image("mem:mermaid/" + key))
  assert_eq(mermaid_charts.length(), 64)
}

///|
test "a first frame a node grabbed is never let go of for the bound while that node shows it; asked for again, kept the latest" {
  bounds_run()
  // (come to what it is before its node is made: its picture here)
  pv_first["draft/v"] = { view: None, picture: "mem:pv-first/v" }
  let on = @signals.signal(true)
  let shown : Ref[() -> String] = Ref(fn() { "" })
  let t = @ui.Tester::new(
    fn(_c) {  },
    tree=fn(root) {
      root.show(fn() { on.get() }, fn(b) { shown.val = bytes_first_frame_node(b, "draft/v", "v.mp4", b"file") })
    },
    w=400.0,
    h=300.0,
  )
  // (its picture handed over in the run: a Tester begins with none)
  @ui.add_image("mem:pv-first/v", bounds_bytes(10))
  t.run_for(@ui.move_most_ms)
  assert_eq(pv_first_shown.get("draft/v"), Some(1))
  assert_eq((shown.val)(), "mem:pv-first/v")
  for i in 0..<64 {
    pv_first["f\{i}"] = { view: None, picture: "!" }
    pv_first_asked("f\{i}")
  }
  assert_true(pv_first.get("draft/v") is Some(_), msg="shown by a node: kept")
  assert_true(@ui.has_image("mem:pv-first/v"))
  on.set(false)
  t.run_for(@ui.move_most_ms)
  assert_true(pv_first_shown.is_empty())
  pv_first["f64"] = { view: None, picture: "!" }
  pv_first_asked("f64")
  assert_true(pv_first.get("draft/v") is None, msg="let go of once no node shows it")
  assert_false(@ui.has_image("mem:pv-first/v"))
}

///|
/// A drive's image `name` on station `st`, as a folder lists it.
fn bounds_drive(name : String) -> DriveFile {
  { station: "st", root: "r", path: name, name, size: 10.0, mtime: 0.0, kind: "image", mime: "image/png" }
}

///|
test "a picture stepped from: its whole picture kept while the strip slides it out, let go of once it does not" {
  bounds_run()
  let files = [bounds_drive("a.png"), bounds_drive("b.png")]
  let src = made_source()
  let v = new_viewer("st", "", drive_attachment(files[0]), Some(files[0]), InFolder(files))
  let key = v.image_name()
  v.image = key
  v.zoom.boxed(400.0, 300.0, at=0.0)
  v.zoom.natural(10.0, 10.0, at=0.0)
  viewer.set(Some(v))
  let stepped = Ref(false)
  let t = @ui.Tester::new(
    fn(c) {
      if !stepped.val {
        stepped.val = true
        v.go(c, src, 1, 0.0)
      }
    },
    w=400.0,
    h=300.0,
  )
  // (its picture handed over in the run: a Tester begins with none)
  @ui.add_image(key, bounds_bytes(10))
  t.draw()
  assert_true(viewer.untracked() is Some(n) && n.file.path == "b.png", msg="stepped to the one after")
  assert_true(pv_strip.leaving.map(fn(l) { l.picture }) == Some(key))
  assert_true(@ui.has_image(key), msg="the strip slides it out")
  // (the viewer closed: the strip with it, and the picture stepped from let go of)
  close_now()
  assert_false(@ui.has_image(key))
  assert_true(pv_previews_gone.is_empty())
}

///|
test "a viewer read ahead beside the one shown, no longer beside it: let go of, its whole picture with it" {
  bounds_run()
  let src = made_source()
  let shown = new_viewer("st", "", drive_attachment(bounds_drive("a.png")), None, NoSteps)
  let far = new_viewer("st", "", drive_attachment(bounds_drive("z.png")), None, NoSteps)
  let key = far.image_name()
  @ui.add_image(key, bounds_bytes(10))
  far.image = key
  let kept : Map[String, Viewer] = Map([])
  kept[far.thumb_id()] = far
  shown.read_near(src, None, None, kept~)
  assert_true(kept.is_empty())
  assert_false(@ui.has_image(key), msg="let go of with its viewer")
}
