// A page opening waits as well for the pictures it shows that the device holds (sfbase's pictures_in,
// Source.picture_waits; 2026-11-16: a face came a frame after the words, from its initial to the picture): a page whose face the core gives at once
// but takes its host a while to decode comes on top with that face, never on its initial a frame or more before.

///|
fn init {
  // (the faces' bytes, a small picture each, handed to the host for their decodes)
  @ui.host_image_bytes_known([("src/sfapp/page_pictures_wbtest.mbt", 128336)])
}

///|
/// The key a face at `url` is put up as (core_pictures').
fn face_key(url : String) -> String {
  "mem:picture/\{@ui.stable_hash(url)}/\{url.length()}"
}

///|
/// A window (`wide`: 1280 × 800, else 390 × 844) at rest over the fixture's `mode`, the core giving every face's bytes
/// and its host decoding the one at `face` `decode_ms` after it is asked; `page` opened, and from the press each
/// display's frame till it is at rest: the moments (after the press) `words` and the face were first drawn. `waits`:
/// whether a page opening waits for pictures (Source.picture_waits), as the app has it; without, as before. `net_ms`:
/// the face not on the device, its bytes brought by the network that long after the press (none as it is asked kept),
/// else on the device, given at once.
fn face_open(
  wide : Bool,
  waits : Bool,
  decode_ms : Double,
  mode : String,
  page : Page,
  words : String,
  face : String,
  net_ms? : Double,
) -> (Double?, Double?) {
  new_run()
  let bytes = fixture_file_png("face.png")
  let other = fixture_file_png("before.png")
  // (the face's asking that waits on the network, answered at net_ms)
  let fetching : Ref[((Bytes?) -> Unit)?] = Ref(None)
  let faces = core_pictures_waited(
    fn(url, done) {
      match (url == face, net_ms) {
        (true, Some(_)) => fetching.val = Some(done)
        (true, None) => done(Some(bytes))
        _ => done(Some(other))
      }
    },
    fn(url, done) {
      match (url == face, net_ms) {
        (true, Some(_)) => done(Some(b""))
        (true, None) => done(Some(bytes))
        _ => done(Some(other))
      }
    },
  )
  let src : Source = {
    ..round_trip_again(fixture(mode), 0.0),
    reads_ahead: fn() { true },
    gates_opens: fn() { true },
    picture: fn(url, stint) {
      let key = (faces.shown)(url, stint)
      @sfbase.picture_gated(key)
      key
    },
    picture_waits: fn(url) { waits && (faces.waits)(url) },
  }
  let (w, h) = if wide { (1280.0, 800.0) } else { (390.0, 844.0) }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~)
  t.decode_bytes_after(bytes, decode_ms)
  t.draw()
  t.run_for(@ui.move_most_ms * 2.0)
  let start = t.time()
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfbase.open_page(page) })
  let words_at : Ref[Double?] = Ref(None)
  let face_at : Ref[Double?] = Ref(None)
  let till = start + @cmp.maximum(@cmp.minimum(decode_ms, page_local_ms), net_ms.unwrap_or(0.0)) + @ui.move_most_ms * 2.0
  while t.time() < till {
    t.run_for(@ui.frame_period_default)
    match (net_ms, fetching.val) {
      (Some(ms), Some(done)) if t.time() - start >= ms => {
        fetching.val = None
        @ui.view_tree().unwrap().event(t.time(), fn() { done(Some(bytes)) })
      }
      _ => ()
    }
    if words_at.val is None && t.words().iter().any(fn(x) { x.0 == words && x.5 > 0.01 && x.1 < w }) {
      words_at.val = Some(t.time() - start)
    }
    if face_at.val is None && t.drawlist_images().iter().any(fn(i) { i.1 == face_key(face) }) {
      face_at.val = Some(t.time() - start)
    }
  }
  (words_at.val, face_at.val)
}

///|
test "a chat opened whose person's face the device holds but decodes 50 ms late: it comes on top with the face, by the frame its words first show; before, its words a frame or more ahead of the face; one never decoded, page_local_ms after the press; one not on the device, at once as before" {
  let faults : Array[String] = []
  for wide in [false, true] {
    let at = if wide { "大屏" } else { "小屏" }
    let chat = fn(waits, ms) {
      face_open(wide, waits, ms, "chat-compose", Chat(layer_chat), layer_chat_words, @sffixture.ana_face)
    }
    let (words, face) = chat(true, 50.0)
    match (words, face) {
      // (drawn by the frame its words first show in, or before: on 小屏 the page slides in, the face with it)
      (Some(w), Some(f)) if f <= w && w >= 50.0 => ()
      _ => faults.push("\{at}: its words first drawn at \{Repr(words)}, the face at \{Repr(face)} (ms after the press)")
    }
    let (words, face) = chat(false, 50.0)
    match (words, face) {
      (Some(w), Some(f)) if w < f => ()
      _ => faults.push("\{at}, not waited for: its words first drawn at \{Repr(words)}, the face at \{Repr(face)}")
    }
    // (one never decoded: waited for page_local_ms at most, then the page as it is)
    let (words, face) = chat(true, 600000.0)
    match (words, face) {
      (Some(w), None) if w >= page_local_ms && w < page_local_ms + @ui.move_most_ms => ()
      _ => faults.push("\{at}, never decoded: its words first drawn at \{Repr(words)}, the face at \{Repr(face)}")
    }
    // (one not on the device, the network bringing it 300 ms later: never waited for, the face as it comes)
    let (words, face) = face_open(
      wide,
      true,
      50.0,
      "chat-compose",
      Chat(layer_chat),
      layer_chat_words,
      @sffixture.ana_face,
      net_ms=300.0,
    )
    let (unheld, _) = chat(false, 50.0)
    match (words, face, unheld) {
      (Some(w), Some(f), Some(u)) if w == u && f >= 300.0 => ()
      _ => faults.push("\{at}, not on the device: its words first drawn at \{Repr(words)} (\{Repr(unheld)} not waited for), the face at \{Repr(face)}")
    }
  }
  assert_eq(faults, [])
}
