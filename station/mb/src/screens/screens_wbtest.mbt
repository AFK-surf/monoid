// The plain parts of src/screens and src/helper as the TypeScript says them (test/mb-screens.test.ts holds every part
// to it on the same worlds; these are what a change here is first checked against, without the harness).

///|
fn opts(codecs : Array[Codec], peek? : Bool = false) -> ViewOptions {
  ViewOptions::new(1920.0, 1080.0, codecs, peek~)
}

///|
test "a source's codec: the first of its own the view takes, a preview's JPEG where both have it" {
  let name = (c : Codec?) => c.map(x => x.name())
  assert_eq(name(codec_for(opts([H264, Jpeg]), [H265, H264, Jpeg])), Some("h264"))
  assert_eq(name(codec_for(opts([H264, Jpeg], peek=true), [H265, H264, Jpeg])), Some("jpeg"))
  assert_eq(name(codec_for(opts([H264], peek=true), [Jpeg])), None)
}

///|
test "a part of the screen checked: within it, at least a fiftieth, the whole none, four places" {
  let r = (x : Double, y : Double, w : Double, h : Double) => jo([("x", jn(x)), ("y", jn(y)), ("w", jn(w)), ("h", jn(h))])
  let said = (v : J) => region_of(Some(v)).map(x => stringify(x.to_j()))
  assert_eq(said(r(0.1, 0.2, 0.3, 0.4)), Some("{\"x\":0.1,\"y\":0.2,\"w\":0.3,\"h\":0.4}"))
  assert_eq(said(r(-1.0, 2.0, 0.001, 5.0)), Some("{\"x\":0,\"y\":0,\"w\":0.02,\"h\":1}"))
  assert_eq(said(r(0.0, 0.0, 0.99, 0.985)), None)
  assert_eq(said(r(0.123456789, 0.5, 0.3, 0.3)), Some("{\"x\":0.1235,\"y\":0.5,\"w\":0.3,\"h\":0.3}"))
  assert_eq(said(Null), None)
}

///|
test "Math.round as JavaScript's: halves towards +∞" {
  assert_eq(js_round(2.5), 3.0)
  assert_eq(js_round(-2.5), -2.0)
  assert_eq(js_round(0.5), 1.0)
  assert_eq(js_round(-0.4), -0.0)
}

///|
test "Number() of words as JavaScript reads them" {
  assert_eq(js_number(" 42 "), 42.0)
  assert_eq(js_number(""), 0.0)
  assert_eq(js_number("0x1f"), 31.0)
  assert_eq(js_number("1e3"), 1000.0)
  assert_eq(js_number("-.5"), -0.5)
  assert_true(js_number("12px").is_nan())
  assert_true(js_number("1e").is_nan())
}

///|
test "a clip within its bounds; windows as a helper said them, checked" {
  assert_true(clip_fits(ClipText("hi")))
  assert_false(clip_fits(ClipText("")))
  assert_false(clip_fits(ClipPng(b"")))
  let ws = windows_of(
    Some(
      ja([
        jo([("id", jn(1.0)), ("app", js("Finder")), ("title", js("t"))]),
        jo([("id", jn(1.5))]),
        jo([("id", jn(-1.0))]),
        Null,
        jo([("id", jn(7.0)), ("app", jn(3.0))]),
      ]),
    ),
  )
  assert_eq(ws.map(w => (w.id, w.app, w.title)), [(1.0, "Finder", "t"), (7.0, "", "")])
}

///|
test "a person's tab's key" {
  assert_true(is_user_tab_id("u_0123456789ab"))
  assert_false(is_user_tab_id("u_0123456789aB"))
  assert_false(is_user_tab_id("u_0123456789abc"))
}

///|
test "where a person's view is, for an agent to name it" {
  let v : ViewShown = {
    id: "v1",
    name: "A",
    control: true,
    at: 0.0,
    device: Some("0123456789abcdef"),
    self_: None,
    client: Some("still.fail for Mac"),
    app: None,
    agent: false,
  }
  assert_eq(view_on(v, 29999.0), "still.fail for Mac, device 0123456789ab, opened just now")
  assert_eq(view_on(v, 30000.0), "still.fail for Mac, device 0123456789ab, opened 1 min ago")
  assert_eq(view_on({ ..v, client: None, device: None }, 30.0 * 60000.0), "an app that does not say its name, opened 30 min ago")
  assert_eq(view_on(v, 5.0 * 3600000.0), "still.fail for Mac, device 0123456789ab, opened 5 h ago")
}

///|
test "an address shown only where it is not too long" {
  assert_eq(address_shown(Some("https://a")), Some("https://a"))
  assert_eq(address_shown(Some("")), None)
  assert_eq(address_shown(None), None)
}

///|
test "agent-desktop's envelope, and a tree as text" {
  assert_eq(stringify(envelope("{\"ok\":true}", 0.0)), "{\"ok\":true}")
  assert_eq(
    stringify(envelope("", @double.not_a_number)),
    "{\"ok\":false,\"error\":{\"code\":\"INTERNAL\",\"message\":\"agent-desktop printed no answer (exit status NaN)\"}}",
  )
  let tree = parse(
    "{\"ref_id\":\"s1:e1\",\"role\":\"window\",\"name\":\"Main\",\"children\":[{\"role\":\"group\",\"children\":[{\"ref_id\":\"s1:e2\",\"role\":\"button\",\"name\":\" Save \",\"states\":[\"disabled\"]},{\"role\":\"text\",\"name\":\"Main\"},{\"role\":\"field\",\"name\":\"N\",\"value\":42},{\"ref_id\":\"e9\",\"role\":\"list\",\"children_count\":12}]}]}",
  )
  assert_eq(
    tree_text(tree),
    "e1 window \"Main\"\n  e2 button \"Save\" [disabled]\n  field \"N\" = \"42\"\n  e9 list (12 inside)",
  )
}

///|
test "the helper's wire: a message's head, a clip's" {
  assert_eq(helper_message(7, payload=b"\x00\x01"), b"\x07\x00\x00\x00\x02\x00\x01")
  assert_eq(helper_clip(ClipText("a"), flags=Some(1)), b"\x01\x01a")
  assert_eq(helper_clip(ClipPng(b"\x89")), b"\x02\x89")
}

///|
test "a Mac's input: clicks counted, modifiers held, keys by their place" {
  let m = MacInput::new()
  let down = Pointer(kind="down", x=0.1, y=0.1, buttons=1, delta=None)
  let up = Pointer(kind="up", x=0.1, y=0.1, buttons=0, delta=None)
  assert_eq(stringify(ja(m.ops(down, 0.0))), "[{\"op\":\"mouse\",\"type\":\"down\",\"x\":0.1,\"y\":0.1,\"button\":0,\"buttons\":1,\"clicks\":1,\"flags\":0}]")
  ignore(m.ops(up, 10.0))
  assert_eq(stringify(ja(m.ops(down, 300.0))), "[{\"op\":\"mouse\",\"type\":\"down\",\"x\":0.1,\"y\":0.1,\"button\":0,\"buttons\":1,\"clicks\":2,\"flags\":0}]")
  ignore(m.ops(Key(kind="down", key="Shift", code="ShiftLeft", mods=8), 400.0))
  assert_eq(stringify(ja(m.ops(Key(kind="down", key="ArrowLeft", code="ArrowLeft", mods=0), 401.0))), "[{\"op\":\"key\",\"keycode\":123,\"down\":true,\"flags\":10616832}]")
  assert_eq(stringify(ja(m.release())), "[{\"op\":\"mouse\",\"type\":\"up\",\"x\":0.1,\"y\":0.1,\"button\":0,\"buttons\":0,\"clicks\":1,\"flags\":131072},{\"op\":\"key\",\"keycode\":56,\"down\":false,\"flags\":0}]")
  assert_eq(stringify(ja(m.ops(Key(kind="down", key="é", code="Unknown", mods=0), 0.0))), "[{\"op\":\"text\",\"text\":\"é\"}]")
}

///|
test "Windows' input: a wheel in its units, modifiers pressed round a key" {
  let w = WinInput::new()
  assert_eq(stringify(ja(w.ops(Wheel(x=0.5, y=0.5, dx=30.0, dy=-250.0)))), "[{\"op\":\"wheel\",\"x\":0.5,\"y\":0.5,\"dx\":36,\"dy\":300}]")
  assert_eq(w.ops(Wheel(x=0.5, y=0.5, dx=0.4, dy=0.0)).length(), 0)
  assert_eq(
    stringify(ja(w.ops(Key(kind="down", key="c", code="KeyC", mods=2)))),
    "[{\"op\":\"key\",\"scan\":29,\"ext\":false,\"vk\":0,\"down\":true},{\"op\":\"key\",\"scan\":46,\"ext\":false,\"vk\":0,\"down\":true},{\"op\":\"key\",\"scan\":29,\"ext\":false,\"vk\":0,\"down\":false}]",
  )
}

///|
test "a simulator's input: a finger from the edge, its shortcuts, text typed or pasted" {
  let s = SimInput::new()
  assert_eq(stringify(ja(s.ops(Pointer(kind="down", x=0.5, y=0.99, buttons=1, delta=None)))), "[{\"op\":\"touch\",\"type\":\"begin\",\"x\":0.5,\"y\":0.99,\"edge\":3}]")
  assert_eq(stringify(ja(s.ops(Key(kind="down", key="h", code="KeyH", mods=12)))), "[{\"op\":\"button\",\"name\":\"home\"}]")
  assert_eq(stringify(ja(s.ops(Text("日本")))), "[{\"op\":\"paste\",\"text\":\"日本\"}]")
  assert_eq(s.ops(Text("A")).length(), 4)
}

///|
test "scrcpy's control messages and its H.264" {
  let a = AndroidInput::new()
  let size = (1080.0, 2400.0)
  let m = a.messages(Pointer(kind="down", x=0.5, y=1.0, buttons=1, delta=None), size)
  assert_eq(b64(m[0]), "AgD//////////gAAAhwAAAlfBDgJYP//AAAAAAAAAAA=")
  assert_eq(a.messages(Text("hi"), size), [b"\x01\x00\x00\x00\x02hi"])
  let nals = nals_of(b"\x00\x00\x00\x01\x67\x42\x00\x1e\x00\x00\x01\x68\x01\x00\x00\x01\x65\x09")
  assert_eq(nals.map(n => Bytes::from_array(n.to_array())), [b"\x67\x42\x00\x1e", b"\x68\x01", b"\x65\x09"])
  assert_eq(avcc_config_of(nals), Some(b"\x01\x42\x00\x1e\xff\xe1\x00\x04\x67\x42\x00\x1e\x01\x00\x02\x68\x01"))
  assert_eq(avcc_of(nals), b"\x00\x00\x00\x02\x65\x09")
  assert_eq(side_of(ViewOptions::new(640.0, 480.0, [H264])), 1280)
  assert_eq(side_of(ViewOptions::new(333.7, 101.0, [H264], peek=true)), 328)
  assert_eq(bitrate_of(1081), 7000000)
}

///|
test "what adb says: its devices, a display's panels, its size; an emulator's start" {
  assert_eq(devices_of("emulator-5554\tdevice x\nR5\toffline\n 1.2.3.4:5555 device"), ["emulator-5554", "1.2.3.4:5555"])
  assert_false(shown_device("adb-R._adb-tls-connect._tcp"))
  assert_false(shown_device("127.0.0.1:40001"))
  let panels = panels_of(
    "mBaseDisplayInfo=DisplayInfo{real 1080 x 2400, roundedCorners RoundedCorners{[RoundedCorner{position=TopLeft, radius=108}]}}",
  )
  assert_eq(panels.map(p => (p.width, p.height, p.corners)), [(1080.0, 2400.0, [0.1, 0.0, 0.0, 0.0])])
  assert_eq(size_of("Physical size: 1080x2400\nOverride size: 720x1600"), (720.0, 1600.0))
  assert_eq(size_of("nothing"), (0.0, 0.0))
  assert_eq(parse_int_hex("001A"), 26.0)
  assert_eq(parse_int_hex("0x1fz"), 31.0)
  assert_true(parse_int_hex("zz").is_nan())
}

///|
test "a date as the station reads one: ISO's, and ps's" {
  assert_eq(date_parse_utc("1970-01-02T00:00:00Z"), 86400000.0)
  assert_eq(date_parse_utc("2026-11-06T08:34:52.120+01:00"), date_parse_utc("2026-11-06T07:34:52.120Z"))
  assert_eq(date_parse_utc("Fri Nov  6 16:34:52 2026"), date_parse_utc("2026-11-06T16:34:52Z"))
  assert_true(date_parse_utc("not a date").is_nan())
}

///|
test "a simulator's runtime, its turn, its apps' log lines, its apps in order" {
  assert_eq(runtime_name("com.apple.CoreSimulator.SimRuntime.iOS-26-2"), "iOS 26.2")
  assert_eq(runtime_name("com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4"), "iOS 27.2")
  assert_eq(runtime_name("com.apple.CoreSimulator.SimRuntime.xrOS-2-0"), "visionOS 2.0")
  assert_eq(runtime_name("plain"), "plain")
  assert_eq(turn_of("Device Name: primary-1\nUI Orientation: Landscape Left \n", "primary-1"), 1)
  assert_eq(log_of("{\"eventMessage\":\"hi\",\"processImagePath\":\"/a/App\"}"), Some(("", "", "App", "hi")))
  assert_eq(log_of("Filtering"), None)
  let apps = apps_of(
    parse("{\"b\":{\"ApplicationType\":\"User\",\"CFBundleName\":\"Zed\"},\"a\":{\"ApplicationType\":\"User\",\"CFBundleName\":\"alpha\"},\"s\":{\"ApplicationType\":\"System\"}}"),
    "UIKitApplication:b[1]",
  )
  assert_eq(apps.map(a => a.id), ["b", "a"])
  assert_true(locale_compare("apple", "Apple") < 0)
  assert_true(locale_compare("alpha", "Zed") < 0)
}

///|
test "a Windows display's scale and resolution as stillfail-screen says them, checked" {
  assert_eq(scale_of(Some(parse("{\"percent\":150,\"recommended\":125,\"steps\":[100,150]}"))).map(x => x.steps), Some([100.0, 150.0]))
  assert_true(scale_of(Some(parse("{\"percent\":150,\"recommended\":125,\"steps\":[99]}"))) is None)
  assert_eq(resolution_of(Some(parse("{\"width\":1920,\"height\":1080,\"modes\":[{\"width\":1280,\"height\":720}]}"))).map(r => r.modes), Some([(1280.0, 720.0)]))
}

///|
test "logind's session, the helper's grants, the Local Network list's name" {
  assert_eq(graphical_session("2", 1000, "User=1000\nType=x11\nClass=user\nActive=yes\nRemote=no\nDisplay=:0").map(s => s.display), Some(Some(":0")))
  assert_true(graphical_session("2", 1000, "User=1001\nType=x11\nClass=user") is None)
  assert_eq(grant_state(parse("{\"capture\":true,\"files\":{\"documents\":\"denied\"}}"), "capture"), "granted")
  assert_eq(grant_state(parse("{\"capture\":true,\"files\":{\"documents\":\"denied\"}}"), "documents"), "denied")
  assert_eq(grant_state(parse("{}"), "control"), "unknown")
  assert_eq(local_network_name("/Applications/still.fail.app/Contents/MacOS/node"), "still.fail")
  assert_eq(local_network_name("/usr/bin/node"), "stillfail-station")
}

///|
test "PNG pictures: deflated and read back, turned; a PDF's page and a mask's corners" {
  let p : Pixels = { width: 2, height: 1, data: [1, 2, 3, 4, 5, 6, 7, 8].map(x => x.to_byte()) |> FixedArray::from_array }
  let back = decode_png(encode_png(p))
  assert_eq((back.width, back.height), (2, 1))
  assert_eq(b64(Bytes::from_array(back.data)), b64(Bytes::from_array(p.data)))
  let t = turned(p, 1)
  assert_eq((t.width, t.height), (1, 2))
  assert_eq(b64(Bytes::from_array(t.data)), b64(b"\x01\x02\x03\x04\x05\x06\x07\x08"))
  assert_eq(page_size(b"/MediaBox [-10 -20 30 40] /Rotate 90"), Some((60.0, 40.0)))
  assert_eq(page_size(b"/MediaBox [0 0 0 40]"), None)
  assert_eq(inflate(deflate(b"hello, hello")), b"hello, hello")
  let path = "1 0 0 1 0 0 cm 10 0 m 90 0 l 95.5 0 100 4.5 100 10 c 100 90 l 100 95.5 95.5 100 90 100 c 10 100 l 4.5 100 0 95.5 0 90 c 0 10 l 0 4.5 4.5 0 10 0 c h f"
  let pdf = concat([latin1_bytes("%PDF\n/MediaBox [0 0 100 100]\nstream\n"), deflate(latin1_bytes(path)), b"\nendstream\n"])
  assert_eq(panel_of(pdf).map(x => x.corners.length()), Some(4))
  assert_true(panel_of(b"%PDF no box") is None)
}

///|
test "a case's displays: its capabilities', else its profile's" {
  let caps = parse(
    "{\"capabilities\":{\"displays\":[{\"displayType\":\"integrated\",\"hasDigitizer\":true,\"chromeIdentifier\":\"c\",\"width\":1170,\"height\":2532,\"scale\":3},{\"displayType\":\"external\"}]}}",
  )
  assert_eq(displays_of(caps, Null).map(d => (d.chrome, d.width, d.scale)), [("c", 1170.0, 3.0)])
  let old = parse("{\"capabilities\":{\"ScreenDimensionsCapability\":{\"main-screen-width\":750,\"main-screen-height\":1334}}}")
  assert_eq(displays_of(old, parse("{\"chromeIdentifier\":\"phone8\"}")).map(d => (d.chrome, d.scale)), [("phone8", 1.0)])
}

///|
test "the station's sources: added, gone only as the one added, watched" {
  let s = Screens::new()
  let told = []
  ignore(s.watch(list => told.push(list.length())))
  let a = ScreenSource::bare("a", DesktopKind, () => "A", () => (1.0, 1.0), async fn(_) { raise fail("no") })
  let a2 = { ..a, title: () => "A again" }
  let remove = s.add(a)
  ignore(s.add(a2))
  remove()
  assert_eq(s.list().map(x => (x.title)()), ["A again"])
  assert_eq(told, [1, 1])
}

///|
test "JavaScript's strings: cut by its units, trimmed by its white space" {
  assert_eq(units_len(slice_units("a😀b", 0, 2)), 2)
  assert_eq(slice_units("a😀b", 0, 3), "a😀")
  assert_eq(units_len("😀"), 2)
  assert_eq(points_len("😀a"), 2)
  assert_eq(trim_js("\u{a0} x \u{3000}"), "x")
  assert_eq(split_space(" a  b "), ["", "a", "b", ""])
}

///|
test "what a stream kept, in its pieces: looked at and taken across them" {
  let c = Carry::new()
  c.push(b"\x01\x00")
  c.push(b"")
  c.push(b"\x00\x00\x03ab")
  c.push(b"c\x02")
  assert_eq(c.length, 9)
  assert_eq(c.u32_at(1), 3L)
  assert_eq(c.take(5), b"\x01\x00\x00\x00\x03")
  assert_eq(c.take(3), b"abc")
  assert_eq(c.byte_at(0), b'\x02')
  assert_eq(c.length, 1)
}

///|
/// Ports that do nothing but say what is there (`exists`) and where this module's files are (`code_dir`).
fn paths_io(code_dir : String, exists : (String) -> Bool) -> Io {
  {
    clock: { now: () => 0.0, after: (_, _) => () => (), micros: () => 0.0 },
    spawn: _ => (),
    procs: {
      spawn: (_, _, _, _) => {
        pid: () => None,
        write: (_, _) => (),
        end_input: _ => (),
        destroy_input: () => (),
        input_open: () => false,
        kill: _ => (),
        running: () => false,
      },
      exec: async fn(_, _, _) { raise fail("none") },
    },
    net: {
      connect: (_, _) => {
        write: _ => (),
        end: () => (),
        destroy: () => (),
        destroyed: () => true,
        pause: () => (),
        flow_again: () => (),
      },
    },
    fs: {
      read: async fn(_) { raise fail("none") },
      write: async fn(_, _, _) { () },
      access: async fn(_, _) { false },
      readdir: async fn(_) { [] },
      mkdir: async fn(_, _, _) { () },
      mkdtemp: async fn(p) { p },
      rename: async fn(_, _) { () },
      rm: async fn(_, _, _) { () },
      unlink: async fn(_) { () },
      stat: async fn(_) { raise fail("none") },
      lstat: async fn(_) { raise fail("none") },
      copy_tree: async fn(_, _) { () },
      read_at: async fn(_, _, _) { b"" },
      write_at: async fn(_, _, _) { () },
      create: async fn(_) { () },
      append: async fn(_, _) { () },
      exists_sync: exists,
      read_sync: _ => None,
      watch: (_, _, _) => raise FsFailed("none", "ENOSYS"),
    },
    log: { say: (_, _, _, _) => () },
    os: {
      hostname: () => "pc",
      tmpdir: () => "C:\\Temp",
      homedir: () => "C:\\Users\\me",
      arch: "x64",
      os: "windows",
      uid: None,
      exec_path: "C:\\node.exe",
      pid: 1,
      env: () => Env::new([]),
      runnable: (f, a, _) => { file: f, args: a, verbatim: false },
      runnable_soon: async fn(f, a, _) { { file: f, args: a, verbatim: false } },
      mounts_soon: async fn() { [] },
      code_dir,
      date_parse: date_parse_utc,
      cwd: "C:\\",
    },
    words: { tr: (_, k, _) => k, station_lang: () => "en" },
    random: n => Bytes::from_array(FixedArray::make(n, b'\x00')),
    random_int: (lo, _) => lo,
  }
}

///|
test "a path joined as its machine writes it: Windows' with its `..` taken back, POSIX's" {
  assert_eq(sep_of("C:\\repo"), "\\")
  assert_eq(sep_of("\\\\host\\share"), "\\")
  assert_eq(sep_of("repo\\x"), "\\")
  assert_eq(sep_of("/repo/x"), "/")
  assert_eq(pj(["C:\\repo\\station\\src\\screens", "..", "..", "native", "x.exe"]), "C:\\repo\\station\\native\\x.exe")
  assert_eq(pj(["", "/a", "b/../c"]), "/a/c")
}

///|
test "Windows' agent-desktop, stillfail-screen and scrcpy-server beside the station's code, or in the checkout" {
  let code = "C:\\repo\\station\\src\\screens"
  let checkout = "C:\\repo\\station\\native\\screen\\target\\release\\stillfail-screen.exe"
  let io = paths_io(code, p => p == "C:\\repo\\station\\src\\screens\\agent-desktop.exe" || p == checkout)
  assert_eq(ui_binary(io, Env::new([("STILLFAIL_AGENT_DESKTOP", "C:\\none-1.exe")])), Some("C:\\repo\\station\\src\\screens\\agent-desktop.exe"))
  assert_eq(screen_binary(io, Env::new([("STILLFAIL_SCREEN", "C:\\none-2.exe")])), Some(checkout))
  let beside = paths_io(code, p => p == "C:\\repo\\station\\src\\screens\\stillfail-screen.exe")
  assert_eq(screen_binary(beside, Env::new([("STILLFAIL_SCREEN", "C:\\none-3.exe")])), Some("C:\\repo\\station\\src\\screens\\stillfail-screen.exe"))
  let none = paths_io(code, _ => false)
  assert_eq(screen_binary(none, Env::new([("STILLFAIL_SCREEN", "C:\\none-4.exe")])), None)
  assert_eq(server_file(io), "C:\\repo\\station\\src\\screens\\scrcpy-server")
}
