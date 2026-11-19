// A new Slack app's look in the new connect's dialog as its fixture puts it up over the whole app (src/sfpages
// slack_app.mbt; a connect's page's fold: src/sfpages connects_wbtest.mbt): the app's step, its icon and colour sent
// with the rest. On a phone's width with a finger.

///|
fn init {
  // The 1024×1024 JPEG preview handed to the host once icon_well_node draws it at full size.
  @ui.host_image_bytes_known([("src/sfapp_pages_test/slack_app_look_test.mbt", 86954)])
}

///|
/// A page of the settings' fixture (`mode` as MBUI_FIXTURE has it) at a phone's width with a finger, its calls kept in
/// `calls` and answered.
fn look_tester(route : @settings.Route, calls : Array[Made], mode? : String = "settings") -> @ui.Tester {
  new_run()
  if mode != "settings" {
    @settings.fixture_page(mode) |> ignore
  }
  let base = fixture(mode)
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      calls.push({ name, params, bytes: None, done })
      (base.call)(name, params, done)
    },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.add_pixels("https://app.still.fail/avatars/backend.webp", 2, 2, FixedArray::make(16, b'\xFF'))
  t.draw()
  app.nav.push(Settings)
  app.nav.push(Setting(route))
  t.draw()
  t.run_for(@ui.move_most_ms)
  t
}

///|
test "a new Slack app's look in the new connect's dialog, at a phone's width: it starts as the first buddy, its icon and colour put in the flow" {
  let calls : Array[Made] = []
  let t = look_tester(@settings.Route::Connects(""), calls, mode="settings-new-connect-app")
  for _ in 0..<3 {
    t.draw()
  }
  assert_true(@sf.presenting())
  assert_true(t.query(Button, label="后端接口").unwrap().selected == Some(true))
  let edits = calls.filter(fn(m) { m.name == "connect.flow.edit" }).map(fn(m) { field(Some(m.params), "input") })
  assert_true(edits.iter().any(fn(i) { text(field(i, "settings"), "backgroundColor") == "#B582EB" }), msg=edits.map(fn(e) { Repr(e).to_string() }).join(" | "))
  t.click(Button, label="Gemini")
  for _ in 0..<3 {
    t.draw()
  }
  assert_true(
    t.drawlist_images().iter().any(fn(i) { i.1.has_prefix("mem:desk-slack-icon/") }),
    msg="picked maker icon should be shown in the icon well",
  )
  assert_true(
    t.drawn_images().iter().any(fn(r) { r[2] >= 120.0 && r[3] >= 120.0 }),
    msg="icon well image collapsed instead of filling the 128×128 well",
  )
}
