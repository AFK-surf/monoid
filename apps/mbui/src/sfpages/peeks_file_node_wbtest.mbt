// What a file's card holds as nodes (peeks_file_node.mbt's file_card_node) set beside the old view's (peeks.mbt
// file_card) in the same room, as the same reading of the file says: the words where they were and the rectangles
// drawn the same, in each state it shows (a text's lines, the one named marked, before and after the core says their
// colours; a picture; a directory's entries; a file that is no text; why not, refused; its bones while it is read; its
// path copied, and as it stops saying so; its words at 1.3).

///|
/// What a card stands in: a hover card's width, a little under the window's top, what it holds as far in
/// as a hover card holds it.
// kept across runs: a value (no field of it changes)
let pf_frame : @ui.Style = @ui.css("pt=S4").then(@ui.style(w=@sf.hover_card_w))

///|
// kept across runs: a value (no field of it changes)
let pf_inner : @ui.Style = @ui.css("w=Full p=S2_5 gap=S2")

///|
/// The station and the session that name the file.
// kept across runs: a value
let pf_station : String = "ws1/st1"

///|
// kept across runs: a value
let pf_session : String = "s-c1"

///|
/// How the core says a file's colours in a case: not asked of one (none here), asked and not yet said, said at once.
#derive(Eq)
priv enum PfInk {
  NoCore
  Asked
  Said
}

///|
/// What each piece of the fixture's code is, as the test's core says it: all of each line of it a function's colour.
fn pf_ink(code : String) -> String {
  "i" + code.length().to_string()
}

///|
/// The test's core, bound as the run's first frame is built (a Tester's start forgets what was bound before it), as
/// `ink` says.
fn pf_core(ink : PfInk) -> Unit {
  if @sf.ink_read.val is None && ink != NoCore {
    pf_asked.val = 0
    @sf.ink_read.val = Some(fn(code, _, done) {
      pf_asked.val += 1
      if ink == Said {
        done(Some(pf_ink(code)))
      }
    })
  }
}

///|
/// How many times the test's core was asked a file's colours, since it was bound.
// kept across runs: counted from where pf_core binds the core
let pf_asked : Ref[Int] = Ref(0)

///|
/// The source the card reads, the file as `read` says it (the `filePeek` topic's value and error); the pictures it
/// names counted as they are asked (pf_pictures), kept in `held` till the test answers them where it is given; the
/// rest the fixture's.
fn pf_src(read : () -> (Json?, Json?), held? : Array[(String, Json, (Result[(Json, Bytes), Json]) -> Unit)]) -> Source {
  @sfbase.reset()
  @sf.set_words(@sfbase.fill)
  pf_pictures.val = 0
  let made = @sffixture.fixture("rich-chat")
  {
    ..made,
    read_bytes: fn(name, params, done) {
      if name == "file.peek.picture" {
        pf_pictures.val += 1
      }
      match held {
        Some(h) => h.push((name, params, done))
        None => (made.read_bytes)(name, params, done)
      }
    },
    topic_read: fn(name, params) {
      if name == "filePeek" {
        let (value, error) = read()
        { value, error, version: if value is None && error is None { 0 } else { 1 } }
      } else {
        made.topic(name, params).get().snapshot()
      }
    },
  }
}

///|
/// How many times the source made last was asked a file's picture.
// kept across runs: counted from where pf_src makes the source
let pf_pictures : Ref[Int] = Ref(0)

///|
/// The params the card is read by.
fn pf_params(path : String, line : Int?) -> Map[String, Json] {
  file_peek_params(pf_station, pf_session, path, line)
}

///|
/// The nodes' card (file_card_node) of `path` at `line`, read as `read` says, colours as `ink` says.
fn pf_new(
  path : String,
  line : Int?,
  read : () -> (Json?, Json?),
  ink : PfInk,
  scale? : Double = 1.0,
  held? : Array[(String, Json, (Result[(Json, Bytes), Json]) -> Unit)],
) -> @ui.Tester {
  let src = pf_src(read, held?)
  let t = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      pf_core(ink)
      root.box(fn(f) {
        @sf.style_node(f, fn() { pf_frame })
        f.box(fn(inner) {
          @sf.style_node(inner, fn() { pf_inner })
          let read = @sfbase.hold(src, "pf-node", "filePeek", pf_params(path, line))
          file_card_node(inner, src, pf_station, pf_session, path, line, read)
        })
        |> ignore
      })
      |> ignore
    },
    w=400.0,
    h=720.0,
    native=Mouse,
    pointing=Mouse,
  )
  if scale != 1.0 {
    t.set_font_scale(scale)
  }
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// The fixture's files the core reads, by what they are.
fn pf_dir() -> Json {
  {
    "kind": "dir",
    "path": "/Users/lin/shop/src/list/",
    "name": "list",
    "count": 5,
    "entries": ["place.mbt", "rows.mbt", "moon.pkg", "tests/", "README.md"],
    "time": { "mtime": { "at": 0, "ago": "5 分钟前", "full": "10/26 11:00", "until": "", "past": true } },
  }
}

///|
fn pf_binary() -> Json {
  {
    "kind": "binary",
    "path": "/Users/lin/shop/build/app.wasm",
    "name": "app.wasm",
    "size": 1234567,
    "time": { "mtime": { "at": 0, "ago": "1 小时前", "full": "10/26 10:00", "until": "", "past": true } },
  }
}

///|
/// What a Tester draws (head_drawn's), each place and size to a hundredth of a point: a bar of a card's bones is worked
/// out as a sum in one and a difference in the other, 6.600000000000001 and 6.6.
fn pf_drawn(t : @ui.Tester) -> String {
  let r = fn(x : Double) { (x * 100.0).round() / 100.0 }
  t.words().map(fn(w) { "\{w.0}@\{r(w.1)},\{r(w.2)} \{r(w.3)}x\{r(w.4)} a\{w.5}" }).join("\n") +
  "\n" +
  t.drawn_rects().map(fn(d) { "\{r(d.0)},\{r(d.1)} \{r(d.2)}x\{r(d.3)} \{d.4}" }).join("\n")
}

///|
/// What `t.audit()` says of the nodes' card, excluding known syntax-color contrast and marked-line spacing notes.
fn pf_audit(t : @ui.Tester) -> Array[String] {
  let all = t.audit()
  let known = all.filter(fn(f) { f.contains(":1, under 4.5") && f.contains("sfpages/peeks_file_node.mbt") })
  let marked = fn(f : String) {
    (f.has_prefix("rule 9: 「12 ") && f.has_suffix(" meet")) ||
    (f.has_prefix("rule 4: what 「12 ") && f.contains("stands 0 in from its left"))
  }
  all.filter(fn(f) { !known.contains(f) && !marked(f) })
}

///|
/// Each state, by name: the path, the line, what the core reads, how it says the colours.
fn pf_cases() -> Array[(String, String, Int?, (Json?, Json?), PfInk)] {
  let text = Some(@sffixture.fixture_file_peek("src/list/place.mbt"))
  [
    ("lines, no core to colour them", "src/list/place.mbt", Some(12), (text, None), NoCore),
    ("lines, colours asked", "src/list/place.mbt", Some(12), (text, None), Asked),
    ("lines, colours said", "src/list/place.mbt", Some(12), (text, None), Said),
    ("a picture", "shots/list.png", None, (Some(@sffixture.fixture_file_peek("shots/list.png")), None), Said),
    ("a directory", "src/list/", None, (Some(pf_dir()), None), Said),
    ("no text", "build/app.wasm", None, (Some(pf_binary()), None), Said),
    ("refused", "src/gone.mbt", None, (None, Some({ "message": "没有这个文件" })), Said),
    ("read", "src/list/place.mbt", Some(12), (None, None), Said),
  ]
}

///|
test "a file's card made once as nodes: lines marked and coloured as the core says, a picture, a directory, no text, refused, its bones" {
  for c in pf_cases() {
    let (name, path, line, read, ink) = c
    let t = pf_new(path, line, fn() { read }, ink)
    assert_true(pf_drawn(t).length() > 0, msg=name)
    let asks = if ink == NoCore || path != "src/list/place.mbt" || read.0 is None { 0 } else { 1 }
    assert_eq(pf_asked.val, asks, msg=name)
    assert_eq(pf_pictures.val, if name == "a picture" { 1 } else { 0 }, msg=name)
    assert_eq(pf_audit(t), [], msg=name)
  }
}

///|
test "a file's card's path copied says so copied_ms from the press, then asks to be copied again" {
  let read = (Some(@sffixture.fixture_file_peek("src/list/place.mbt")), None)
  let t = pf_new("src/list/place.mbt", Some(12), fn() { read }, NoCore)
  t.tap_text(@sf.t("web-main.preview.copyPath"))
  t.run_for(@ui.move_most_ms)
  assert_true(t.find(@sf.t("common.copied")) is Some(_))
  t.run_for(@sf.copied_ms)
  assert_true(t.find(@sf.t("web-main.preview.copyPath")) is Some(_))
  assert_eq(pf_audit(t), [])
}

///|
test "a file's card at the system's words set to 1.3: its lines, a directory" {
  for c in pf_cases() {
    let (name, path, line, read, ink) = c
    guard name == "lines, colours said" || name == "a directory" else { continue }
    let t = pf_new(path, line, fn() { read }, ink, scale=1.3)
    assert_eq(pf_audit(t), [], msg=name)
  }
}

///|
test "a file's card read while it shows: its bones, then the file in their place, coloured" {
  let text : (Json?, Json?) = (Some(@sffixture.fixture_file_peek("src/list/place.mbt")), None)
  let read : @signals.Signal[(Json?, Json?)] = @signals.signal((None, None))
  let t = pf_new("src/list/place.mbt", Some(12), fn() { read.get() }, Said)
  assert_true(t.find("place.mbt:12") is None)
  assert_eq(pf_asked.val, 0, msg="nothing asked of its bones")
  read.set(text)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("place.mbt:12") is Some(_))
  assert_eq(pf_asked.val, 1)
  assert_eq(pf_audit(t), [])
}

///|
test "a file's card's picture told as it comes: its bones till then, asked once as the file is read, then the picture" {
  let read : (Json?, Json?) = (Some(@sffixture.fixture_file_peek("shots/list.png")), None)
  let held = []
  let t = pf_new("shots/list.png", None, fn() { read }, Said, held~)
  assert_eq(held.map(fn(a) { a.0 }), ["file.peek.picture"], msg="asked once as it is read")
  assert_eq(pf_pictures.val, 1)
  let bones = pf_drawn(t)
  let now = held.copy()
  held.clear()
  for a in now {
    (a.2)(@sffixture.fixture_peek_picture(a.0, a.1).unwrap())
  }
  @ui.came_from_outside()
  t.run_for(@ui.move_most_ms)
  assert_true(pf_drawn(t) != bones)
  assert_eq(pf_pictures.val, 1, msg="asked no more")
  assert_eq(pf_audit(t), [])
}
