///|
/// A video's parts read by the host itself (Android's player past the app's GL thread, 2026-11-01: a 4K film stalled,
/// each 4 MB part waiting on the thread that draws it): the call the app's own reader makes, every part's offset and
/// length left to each read, streamed, with the size its folder says.
test "direct_part: the app's part call, its offset and length each read's own" {
  let p = drive_params("ws1/st1", "r", "a.mp4")
  drive_keep(p, "played", 5.0, 9000.0)
  p["offset"] = Json::number(4096.0)
  p["length"] = Json::number(1024.0)
  let said = @json.parse(direct_part("drive.read", p, 9000.0)) catch { _ => panic() }
  assert_eq(
    said,
    {
      "call": "drive.read",
      "params": {
        "station": "ws1/st1",
        "root": "r",
        "path": "a.mp4",
        "keep": "played",
        "mtime": 5.0,
        "size": 9000.0,
        "stream": true,
      },
      "size": 9000.0,
    },
  )
  // (the part's own params untouched: the app's reader goes on with them)
  assert_eq(p.get("offset"), Some(Json::number(4096.0)))
}

///|
/// A chat's video's first frame read by the host's own reader too, as the viewer's is (a phone, 2026-11-19: each part
/// through the app held a frame 75 ms, and those still coming as the player was let go were left unheld).
test "first_player: the host told the chat's part call, kept with the chat, each part's offset and length its own" {
  let t = @ui.Tester::new(fn(_) {  })
  let a = attachment_of({ "name": "clip.mp4", "path": "/up/clip.mp4", "size": 9000.0 })
  let n = first_player(made_source(), "ws1/st1", "s1", a)
  let said = t
    .views()
    .iter()
    .find_first(fn(l) { l.has_prefix("settings \{n.id()} ") })
    .map(fn(l) { l.exact_view(start=("settings \{n.id()} ").length()).to_owned() })
  let direct = @json.parse(said.unwrap_or("")) catch { _ => panic() }
  assert_eq(
    direct,
    {
      "call": "station.file.part",
      "params": {
        "station": "ws1/st1",
        "key": "s1",
        "name": "clip.mp4",
        "keep": true,
        "size": 9000.0,
        "stream": true,
      },
      "size": 9000.0,
    },
  )
  n.close()
}
