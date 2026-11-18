// An archived row's station picture and its action share a column, including while a picture is decoded or replaced.

///|
test "an archived row draws its station mark only when it is available and aligns it with restore" {
  @sfbase.reset()
  @sf.set_words(@sfbase.fill)
  let picture = @signals.signal("")
  let emoji = @signals.signal("")
  let was = @sf.picture_of.val
  @sf.picture_of.val = fn(_, _) { picture.get() }
  defer { @sf.picture_of.val = was }
  let item = fn() -> Json {
    {
      "station": "ws/st", "session": "session", "title": "Archived row", "last": "Last message", "place": "Example station",
      "stationIcon": "https://example.test/station.png", "stationEmoji": Json::string(emoji.get()),
    }
  }
  let t = @ui.Tester::new(fn(c) { @sf.begin(c) |> ignore }, w=320.0, h=200.0, platform=0, pointing=Mouse, images=[("picture-a", 64, 64), ("picture-b", 64, 64)], finish=false)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(@sf.ui_theme_now)
    let popup = root.box(fn(v) { v.over(Is(true)) |> ignore })
    let tips = @sf.TipLayer::new(fn() { Some(popup) })
    archive_row_side_node(root, @sfbase.sample_source, tips, item, fn() { false }, Side, fn() { 0 })
  })
  t.draw()
  assert_eq(t.drawn_images().length(), 0)
  picture.set("picture-a")
  t.frame()
  assert_eq(t.drawn_images().length(), 0)
  guard t.pending() is [(_, id), ..] else { fail("the picture was not asked for") }
  t.finish(1, id)
  t.frame()
  guard t.drawn_images() is [image, ..] else { fail("the decoded picture is not drawn") }
  assert_true(image[8] > 0.99)
  assert_eq(t.audit(), [])
  let column = image[0] + image[2] / 2.0
  let (x, y, w, h) = t.get(Link, label="Archived row").rect
  t.move_to(x + w / 2.0, y + h / 2.0)
  t.run_for(@sf.dur_ms)
  let (x, _, w, _) = t.get(Button, label=@sf.t("web-pages.archive.restoreNamed", args=[("title", "Archived row")])).rect
  assert_true((x + w / 2.0 - column).abs() < 0.5, msg="restore \{x + w / 2.0}, picture \{column}")
  t.move_to(0.0, 199.0)
  picture.set("picture-b")
  t.frame()
  assert_eq(t.drawn_images().length(), 0, msg="the old picture is still drawn")
  guard t.pending() is [(_, id), ..] else { fail("the replacement picture was not asked for") }
  t.finish(1, id, ok=false)
  t.frame()
  assert_eq(t.drawn_images().length(), 0)
  emoji.set("🌿")
  t.frame()
  guard t.rect_of("🌿") is Some(mark) else { fail("the fallback emoji is not drawn") }
  assert_true((mark.0 + mark.2 / 2.0 - column).abs() < 0.5)
  assert_eq(t.audit(), [])
}
