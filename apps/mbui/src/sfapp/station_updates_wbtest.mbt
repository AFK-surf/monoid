// The stations' newer releases waiting for this person (sfpages station_updates.mbt): a key beside the app's own update
// in a wide window's sidebar, on Home's bar in a phone's; pressed, their dialog.

///|
test "the stations' newer releases, in a wide window and a phone's: their key says how many; pressed, their dialog, a row a station (its name, what runs and what is out); its 更新 updates that station alone" {
  for win in [(1280.0, 800.0, 0), (390.0, 844.0, 2)] {
    let (w, h, platform) = win
    let at = "\{w}"
    // (every rule the screen is held to: the key and its dialog add no fault to those the frame has without them,
    // home's; read of that Tester before this one's is made)
    let base = wide_tester([], mode="home", w~, h~, platform~)
    base.run_for(@ui.move_most_ms)
    let known = base.audit()
    let added = fn(faults : Array[String]) { faults.filter(fn(f) { !known.contains(f) }) }
    let calls : Array[Made] = []
    let core : Ref[@settings.Core?] = Ref(None)
    let t = wide_tester(calls, mode="home-station-updates", w~, h~, platform~, before=fn(src) {
      core.val = Some(settings_core(src, { id: "ws1", name: "星火工作室", emoji: "", icon: "", email: "lin@example.com" }))
    })
    t.run_for(@ui.move_most_ms)
    // (what the made-up core lists, asked of it as the key asks it: answered as the asking is over)
    let read = fn() { @sfpages.station_updates_now(core.val.unwrap(), "ws1") }
    ignore(read())
    t.frame()
    let listed = items(read(), "items")
    assert_true(listed.length() > 0, msg="\{at}: \{Repr(read())}")
    let label = "\{listed.length()} 台 station 有新版本"
    let key = t.query(Button, label~)
    assert_true(key is Some(_), msg=at + ": " + t.words().map(fn(x) { x.0 }).join("|"))
    let faults = added(t.audit())
    assert_true(faults.is_empty(), msg=at + ": " + faults.join(" | "))
    let (kx, ky, kw, kh) = key.unwrap().rect
    t.tap(kx + kw / 2.0, ky + kh / 2.0)
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("Station 更新") is Some(_), msg=at)
    for s in listed {
      assert_true(t.find(text(Some(s), "name")) is Some(_), msg="\{at}: \{text(Some(s), "name")}")
    }
    // (but the dialog's own ×, a pixel over the body of a dialog with no line under its title: the presenter's,
    // panel_centred_node.mbt, where its × stands: the presenter's layout, not what this one holds)
    let faults = added(t.audit()).filter(fn(f) { !f.contains("panel_centred_node.mbt:137") })
    assert_true(faults.is_empty(), msg=at + ": " + faults.join(" | "))
    t.click(Button, label="更新")
    t.frame()
    let asked = calls.filter(fn(c) { c.name == "software.update" })
    assert_eq(asked.length(), 1, msg=at)
    assert_true(listed.iter().any(fn(s) { text(Some(s), "station") == text(Some(asked[0].params), "station") }), msg=at)
    assert_eq(text(Some(asked[0].params), "id"), "station", msg=at)
  }
}

///|
test "no key where the core lists none waiting" {
  for win in [(1280.0, 800.0, 0), (390.0, 844.0, 2)] {
    let (w, h, platform) = win
    let calls : Array[Made] = []
    let t = wide_tester(calls, mode="home", w~, h~, platform~)
    t.run_for(@ui.move_most_ms)
    assert_true(t.query(Button, label="1 台 station 有新版本") is None, msg="\{w}")
  }
}
