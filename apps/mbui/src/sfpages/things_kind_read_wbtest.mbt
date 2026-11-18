///|
test "things_kind_read: another kind there at once, read again in the change as it was; a thing come or gone of one kind its way, the last one too" {
  let was : Ref[Set[String]] = Ref(Set([]))
  let other = Ref(false)
  let read = fn(keys : Array[String], kind : String) {
    things_kind_read(was, other, keys, kind) |> ignore
    other.val
  }
  let rows = fn(kind : String, names : Array[String]) {
    let out = ["head"]
    if names.is_empty() {
      out.push("none")
    }
    for n in names {
      out.push("thing/" + kind + "/" + n)
    }
    out.push("foot")
    out
  }
  assert_eq(read(rows("links", ["a", "b"]), "links"), false)
  // (another kind: another list, there at once, however often the change reads its keys)
  assert_eq(read(rows("files", ["x"]), "files"), true)
  assert_eq(read(rows("files", ["x"]), "files"), true)
  // (one thing come of the same kind: its way)
  assert_eq(read(rows("files", ["x", "y"]), "files"), false)
  assert_eq(read(rows("files", ["x", "y"]), "files"), false)
  // (one gone, then the last one: each its way, none found in its place)
  assert_eq(read(rows("files", ["y"]), "files"), false)
  assert_eq(read(rows("files", []), "files"), false)
  // (another kind with nothing in it: another list still)
  assert_eq(read(rows("links", []), "links"), true)
  // (back to a kind with things: another list)
  assert_eq(read(rows("files", ["z"]), "files"), true)
}

///|
/// A picture's or a video's tile of the chat's things (media_tile_node), `w` × `h`, of the picture `file` says, the
/// station's thumbnail of it `thumb` ("" none yet), pictures of `images` known to the host.
fn things_tile_tester(file : Json, w : Double, h : Double, thumb : String, images : Array[(String, Int, Int)]) -> @ui.Tester {
  let src : Source = { ..files_src(), file: fn(_, _, _) { thumb } }
  let r : ChatRef = { station: "st", session: "ag", title: "", station_name: "" }
  let t = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() {
        @ui.old_views_here(c)
        @sf.presented(c)
      })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let line = root.box(fn(v) { v.row(Is(true)) |> ignore })
      media_tile_node(line, src, r, 1.0, { "seq": 1.0, "file": file }, w, h, fn(_) {  })
      @sf.presented_nodes(root)
    },
    w=300.0,
    h=300.0,
    images~,
  )
  t.run_for(@ui.move_most_ms)
  t
}

///|
test "the chat's things: a phone's long screenshot's tile shows its top in its own proportions, never stretched down" {
  let file : Json = { "name": "long.png", "path": "/w/uploads/long.png", "owner": "ag", "width": 1140.0, "height": 2616.0 }
  let t = things_tile_tester(file, 100.0, 100.0, "long-thumb.png", [("long-thumb.png", 360, 826)])
  let pic = t.drawn_images()
  assert_eq(pic.length(), 1, msg="\{Repr(pic)}")
  let p = pic[0]
  // (as big as its tile, all of it across, its top: as much of it down as its tile is tall for as wide)
  assert_true((p[2] - 100.0).abs() < 0.01 && (p[3] - 100.0).abs() < 0.01, msg="\{Repr(p)}")
  assert_true(p[5].abs() < 0.001 && p[6] > 0.999, msg="\{Repr(p)}")
  assert_true((p[7] - 1140.0 / 2616.0).abs() < 0.01, msg="\{Repr(p)}")
}

///|
test "the chat's things: a picture sent before sizes were kept is as wide for as tall as its ThumbHash says, and long by it" {
  // (5 wide for 7 high, as its header says: pixels_test's)
  let hash = "1QcSHQRnh493V4dIh4eXh1h4kJUI"
  let file : Json = { "name": "old.png", "path": "/w/uploads/old.png", "owner": "ag", "thumbhash": Json::string(hash) }
  assert_eq(media_aspect({ "file": file }), 5.0 / 7.0)
  // (a tile wider than that for its height: covering it from its top, its likeness and its picture alike)
  let t = things_tile_tester(file, 100.0, 100.0, "old-thumb.png", [("old-thumb.png", 250, 350)])
  let p = t.drawn_images()[0]
  assert_true((p[3] - 100.0).abs() < 0.01 && p[5].abs() < 0.001, msg="\{Repr(p)}")
  assert_true((p[7] - 5.0 / 7.0).abs() < 0.01, msg="\{Repr(p)}")
}

///|
test "the chat's things: a picture sent from here shows the picture it was picked as, the station not asked for it" {
  let file : Json = { "name": "mine.png", "path": "/w/uploads/mine.png", "owner": "ag", "width": 400.0, "height": 300.0 }
  @sfbase.sent_picture_kept(@sfbase.sent_key("st", "/w/uploads/mine.png"), "picked/mine.png")
  // (the station's thumbnail of it not there yet: none asked for, the picture picked shown)
  let t = things_tile_tester(file, 100.0, 100.0, "", [("picked/mine.png", 400, 300)])
  assert_eq(t.drawn_images().length(), 1)
  assert_true(t.image_loads().iter().any(fn(l) { l.0 == "picked/mine.png" }), msg="\{Repr(t.image_loads())}")
}
