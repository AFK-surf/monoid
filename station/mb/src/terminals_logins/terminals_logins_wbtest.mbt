// The parts' own rules, as station/test/terminals.test.ts and station/test/logins.test.ts hold the TypeScript's (and
// station/test/mb-terminals-logins.test.ts holds both to each other on the same cases).

///|
fn obj(s : String) -> J {
  parse(s) catch {
    _ => J::Null
  }
}

///|
test "what a view asks is checked" {
  assert_eq(asked(Some(obj("{\"cols\":0,\"rows\":24}"))) is None, true)
  assert_eq(asked(Some(obj("{\"cols\":80,\"rows\":9999}"))) is None, true)
  assert_eq(stringify(asked(Some(obj("{\"cols\":80,\"rows\":24}"))).unwrap().to_json()), "{\"cols\":80,\"rows\":24,\"control\":true,\"taken\":false}")
  assert_eq(
    stringify(asked(Some(obj("{\"cols\":80,\"rows\":24,\"control\":false,\"taken\":true,\"cwd\":\"/a\",\"chat\":\"\"}"))).unwrap().to_json()),
    "{\"cols\":80,\"rows\":24,\"control\":false,\"taken\":true,\"cwd\":\"/a\"}",
  )
  assert_eq(size_of(utf8_of("nope")), None)
  assert_eq(size_of(utf8_of("{\"cols\":10,\"rows\":5}")), Some((10, 5)))
  assert_eq(control_of(utf8_of("nope")) is None, true)
  assert_eq(stringify(control_of(utf8_of("{\"control\":false}")).unwrap().to_json()), "{\"control\":false,\"taken\":false}")
  assert_eq(
    stringify(control_of(utf8_of("{\"control\":true,\"taken\":true,\"cols\":120,\"rows\":40}")).unwrap().to_json()),
    "{\"control\":true,\"taken\":true,\"cols\":120,\"rows\":40}",
  )
}

///|
test "only what is past the screen is given" {
  assert_eq(past_screen({ at: 0.0, bytes: b"abc" }, 3.0), None)
  assert_eq(past_screen({ at: 0.0, bytes: b"abcdef" }, 3.0), Some(b"def"))
  assert_eq(past_screen({ at: 5.0, bytes: b"xy" }, 3.0), Some(b"xy"))
}

///|
test "a runner's lines: contiguous output put together in a read, a line not JSON passed over (it ends no run)" {
  let lines = RunnerLines::new()
  let out = (at : Int, s : String) => "{\"op\":\"out\",\"stream\":\"out\",\"at\":\{at},\"data\":\"\{base64_of(utf8_of(s))}\"}\n"
  let told = lines.read(utf8_of(out(0, "ab") + out(2, "cd") + "nope\n" + out(4, "e") + out(9, "f") + "{\"op\":\"exit\",\"code\":0}\n" + out(10, "g").unsafe_substring(start=0, end=5)))
  let shown = told.map(m => match m {
    Output(at, b) => "out \{at} \{utf8_text(b)}"
    Line(j) => stringify(j)
  })
  assert_eq(shown, ["out 0 abcde", "out 9 f", "{\"op\":\"exit\",\"code\":0}"])
  // the rest of a line comes with the next read
  let rest = lines.read(utf8_of(out(10, "g").unsafe_substring(start=5, end=out(10, "g").length())))
  assert_eq(rest.length(), 1)
}

///|
test "base64 as Buffer has it; UTF-8 kept across chunks" {
  assert_eq(base64_of(b"hello"), "aGVsbG8=")
  assert_eq(from_base64("aGVsbG8="), b"hello")
  assert_eq(from_base64("aGV sbG8"), b"hello")
  assert_eq(from_base64("-_8"), b"\xfb\xff")
  let d = Utf8Decoder::new()
  let all = utf8_of("中🎉")
  assert_eq(d.write(all[0:2].to_bytes()), "")
  assert_eq(d.write(all[2:5].to_bytes()), "中")
  assert_eq(d.write(all[5:].to_bytes()), "🎉")
}

///|
test "git's credential helpers left out" {
  let env : Env = { "GIT_CONFIG_COUNT": "2" }
  keychain_out_of_git(env)
  assert_eq(env.get("GIT_CONFIG_KEY_2"), Some("credential.helper"))
  assert_eq(env.get("GIT_CONFIG_VALUE_2"), Some(""))
  assert_eq(env.get("GIT_CONFIG_COUNT"), Some("3"))
  let none : Env = {}
  keychain_out_of_git(none)
  assert_eq(none.get("GIT_CONFIG_COUNT"), Some("1"))
}

///|
test "the last lines of what a command said" {
  assert_eq(last_lines("  a  \n\n b \n"), "a\n b")
  assert_eq(last_lines("1\n2\n3\n4\n5\n6\n7\n8"), "3\n4\n5\n6\n7\n8")
}

///|
test "a callback's state and the forms it comes in" {
  assert_eq(form_get("?a=1&state=x%20y+z", "state"), Some("x y z"))
  assert_eq(form_get("state=%zz", "state"), Some("%zz"))
  assert_eq(form_get("a=1", "state"), None)
  assert_eq(state_of({ method_: "GET", path: "/cb?state=s1", headers: [], body: None }), Some("s1"))
  assert_eq(state_of({ method_: "POST", path: "/?state=q", headers: [], body: Some(base64_of(b"code=1&state=f")) }), Some("f"))
  assert_eq(state_of({ method_: "POST", path: "/?state=q", headers: [], body: Some(base64_of(b"code=1")) }), Some("q"))
  assert_eq(encode_uri_component("a b/中"), "a%20b%2F%E4%B8%AD")
}

///|
test "what the agent reads of a screen: the page and the code hidden, the cursor's line marked" {
  let login = obj("{\"id\":\"a1\",\"code\":\"AB12-CD34\"}")
  let screen : Screen = {
    rows: ["", "copy your code: AB12-CD34", "open https://github.com/login/device now   ", "", ""],
    wrapped: [false, false, false, false, false],
    cursor: (0, 3),
    echo: true,
    live: true,
  }
  assert_eq(screen_for(Some(screen), login), "copy your code: <code>\nopen <link> now\n▏")
  assert_eq(screen_for(None, login), "")
}

///|
test "a Slack card's page: a device code's, a page to paste from; none for a loopback or once ended" {
  let device = obj(
    "{\"state\":\"code\",\"step\":\"device\",\"url\":\"https://github.com/login/device\",\"code\":\"AB12-CD34\"}",
  )
  assert_eq(
    stringify(slack_page(device).unwrap()),
    "{\"url\":\"https://github.com/login/device\",\"domain\":\"github.com\",\"code\":\"AB12-CD34\",\"paste\":false}",
  )
  let paste = obj("{\"state\":\"browser\",\"step\":\"open\",\"paste\":true,\"url\":\"https://x.example/p\"}")
  assert_eq(stringify(slack_page(paste).unwrap()), "{\"url\":\"https://x.example/p\",\"domain\":\"x.example\",\"paste\":true}")
  assert_eq(slack_page(obj("{\"state\":\"browser\",\"step\":\"loopback\",\"url\":\"https://x.example/p\"}")) is None, true)
  assert_eq(slack_page(obj("{\"state\":\"code\",\"step\":\"device\",\"url\":\"https://x.example/p\",\"endedAt\":1}")) is None, true)
  assert_eq(
    stringify(limited(obj("{\"id\":\"a\",\"url\":\"u\",\"code\":\"c\",\"callback\":{},\"error\":\"e\",\"state\":\"s\"}"))),
    "{\"id\":\"a\",\"state\":\"s\"}",
  )
}

///|
test "a channel's beta feature" {
  assert_eq(channel_from(Some(obj("{\"updateChannel\":\" beta \"}")), None), "beta")
  assert_eq(channel_from(Some(obj("{\"updateChannel\":\"nightly\"}")), Some("beta")), "beta")
  assert_eq(channel_from(None, None), "stable")
  assert_eq(feature_on_channel(Some("beta"), true, "beta"), true)
  assert_eq(feature_on_channel(Some("beta"), true, "stable"), false)
}

///|
/// A runner of the test's: what it was sent, and what it says.
priv struct TestRunner {
  sent : Array[String]
  lines : Array[(Said) -> Unit]
}

///|
test "a new terminal: its screen first, then only what came after it; one typing, the others looking" {
  let rt = @effect.Runtime::new()
  let runners : Array[TestRunner] = []
  let changes = Ref(0)
  let n = Ref(0)
  let terminals = Terminals::new({
    home: "/home/a",
    chat_dir: chat => if chat == "c1" { Some("/work/c1") } else { None },
    new_id: () => {
      n.val += 1
      "term-\{n.val}"
    },
    changed: _ => changes.val += 1,
    meta: None,
    gone: _ => (),
    offered: None,
    now: () => 0.0,
    spawn: f => rt.fork(f) |> ignore,
    log: (_, _) => (),
    start: async fn(_, _, _, _) {
      let r : TestRunner = { sent: [], lines: [] }
      runners.push(r)
      TerminalLink::new({
        write: line => r.sent.push(line),
        end: () => (),
        on_line: f => r.lines.push(f),
        on_close: _ => (),
      })
    },
  })
  let written : Array[Bytes] = []
  let inbox : @effect.Queue[Bytes?] = @effect.Queue::unbounded()
  let stream : Stream = {
    read: async fn() { inbox.take() },
    write: async fn(b) { written.push(b) },
    finish: async fn() { () },
  }
  let head = obj("{\"method\":\"POST\",\"path\":\"/admin/api/terminals/new/view\",\"terminal\":{\"cols\":80,\"rows\":24,\"chat\":\"c1\"}}")
  rt.fork(async fn() {
    terminals.answer(stream, b"", head, { name: "ann", email: "ann@x", role: "member", workspace: "w1", device: "d" })
  })
  |> ignore
  rt.advance(0)
  let r = runners[0]
  let say = (s : String) => for f in r.lines {
    f(Line(obj(s)))
  }
  say("{\"op\":\"out\",\"stream\":\"out\",\"at\":0,\"data\":\"\{base64_of(b"hello ")}\"}")
  say("{\"op\":\"out\",\"stream\":\"out\",\"at\":6,\"data\":\"\{base64_of(b"world")}\"}")
  say("{\"op\":\"screen\",\"at\":6,\"data\":\"\{base64_of(b"[screen]")}\"}")
  say("{\"op\":\"out\",\"stream\":\"out\",\"at\":11,\"data\":\"\{base64_of(b"!")}\"}")
  rt.advance(0)
  // the head, then the frames: its state (it types), the screen, and only what came past it
  let all = @buffer.new()
  for w in written {
    all.write_bytes(w)
  }
  let text = utf8_text(all.to_bytes())
  assert_eq(text.has_prefix("{\"status\":200,\"headers\":{\"content-type\":\"application/x-stillfail-terminal\"}}\n"), true)
  assert_eq(text.contains("[screen]"), true)
  assert_eq(text.contains("hello"), false)
  assert_eq(text.contains("world"), true)
  let listed = stringify(terminals.list("w1"))
  assert_eq(listed, "[{\"id\":\"term-1\",\"by\":\"ann\",\"at\":0,\"cwd\":\"/work/c1\",\"byEmail\":\"ann@x\",\"chat\":\"c1\",\"typing\":\"ann\",\"looking\":[]}]")
  assert_eq(r.sent.contains("{\"op\":\"resize\",\"cols\":80,\"rows\":24}\n"), true)
  // typed into, then the stream ends: the view goes, the terminal stays
  inbox.try_offer(Some(frame(KIND_INPUT, b"ls\r"))) |> ignore
  inbox.try_offer(None) |> ignore
  rt.advance(0)
  assert_eq(r.sent.contains("{\"op\":\"write\",\"data\":\"\{base64_of(b"ls\r")}\"}\n"), true)
  assert_eq(stringify(terminals.list("w1")), "[{\"id\":\"term-1\",\"by\":\"ann\",\"at\":0,\"cwd\":\"/work/c1\",\"byEmail\":\"ann@x\",\"chat\":\"c1\",\"typing\":null,\"looking\":[]}]")
  assert_eq(terminals.end("term-1", "bob", "w2"), false)
  assert_eq(terminals.end("term-1", "bob", "w1"), true)
  assert_eq(r.sent.contains("{\"op\":\"signal\",\"signal\":\"KILL\",\"group\":true}\n"), true)
}

///|
test "the terminals' part: those of before taken up as their runners and meta say; listed and ended by members" {
  let rt = @effect.Runtime::new()
  let files : Map[String, String] = {
    "/data/run/terminals/term-a.json": "{\"by\":\"ann\",\"at\":5,\"cwd\":\"/w\",\"workspace\":\"w1\"}",
    "/data/run/terminals/term-c.json": "{\"by\":\"cy\"}",
    "/data/run/terminals/term-d.json": "{\"by\":\"dee\",\"at\":6,\"cwd\":\"/x\",\"workspace\":\"w2\",\"chat\":\"c1\"}",
  }
  let told : Array[String] = []
  let removed : Array[String] = []
  let started : Array[String] = []
  let wire = (_ : RunnerInfo) => {
    write: _ => (),
    end: () => (),
    on_line: _ => (),
    on_close: _ => (),
  }
  let io : TerminalsIo = {
    data: "/data",
    home: "/home/a",
    os: "darwin",
    shell: Some("/bin/zsh"),
    session_dir: _ => None,
    random_hex: () => "0123456789abcdef",
    offered: () => true,
    tell: (ws, v) => told.push(ws + " " + stringify(v)),
    mkdir: async fn(_) { () },
    write_file: async fn(path, t) { files[path] = t },
    remove: async fn(path) { removed.push(path) },
    read_file: async fn(path) {
      match files.get(path) {
        Some(t) => t
        None => raise Failure("ENOENT")
      }
    },
    start_runner: async fn(id, program, args, cwd, cols, rows) {
      started.push("\{id} \{program} \{args} \{cwd} \{cols}x\{rows}")
      { id, pty: Some(Bool(true)), cols: None, rows: None }
    },
    live_runners: async fn() {
      [
        { id: "term-a", pty: Some(Bool(true)), cols: Some(Num(120.0)), rows: Some(Num(40.0)) },
        { id: "agent-b", pty: Some(Bool(true)), cols: None, rows: None },
        { id: "term-c", pty: Some(Bool(true)), cols: None, rows: None },
        { id: "term-d", pty: Some(Bool(true)), cols: None, rows: None },
        { id: "term-e", pty: None, cols: None, rows: None },
        { id: "term-f", pty: Some(Bool(true)), cols: None, rows: None },
      ]
    },
    listening_soon: async fn(info) { info.id != "term-f" },
    wire,
    now: () => 7.0,
    spawn: f => rt.fork(f) |> ignore,
    log: (_, _) => (),
  }
  let part : Ref[TerminalsPart?] = Ref(None)
  rt.fork(async fn() { part.val = Some(TerminalsPart::start(io)) }) |> ignore
  rt.advance(0)
  let p = part.val.unwrap()
  assert_eq(
    p.listed("w1"),
    (200, "{\"terminals\":[{\"id\":\"term-a\",\"by\":\"ann\",\"at\":5,\"cwd\":\"/w\",\"typing\":null,\"looking\":[]}]}"),
  )
  assert_eq(
    p.listed("w2"),
    (200, "{\"terminals\":[{\"id\":\"term-d\",\"by\":\"dee\",\"at\":6,\"cwd\":\"/x\",\"chat\":\"c1\",\"typing\":null,\"looking\":[]}]}"),
  )
  let viewer = (role : String, ws : String) => { name: "", email: "bo@x", role, workspace: ws, device: "d" }
  assert_eq(p.end_asked("term-a", viewer("viewer", "w1")), (403, "{\"error\":\"a read-only member does not end a terminal\"}"))
  assert_eq(p.end_asked("%E4", viewer("member", "w1")), (404, "{\"error\":\"no such terminal\"}"))
  assert_eq(p.end_asked("term-d", viewer("member", "w1")), (404, "{\"error\":\"no such terminal\"}"))
  assert_eq(p.end_asked("term%2Da", viewer("member", "w1")), (200, "{}"))
  // a new one: its meta kept beside its runner, the person's shell started in its folder
  let stream : Stream = { read: async fn() { None }, write: async fn(_) { () }, finish: async fn() { () } }
  let head = obj("{\"method\":\"POST\",\"path\":\"/admin/api/terminals/new/view\",\"terminal\":{\"cols\":80,\"rows\":24}}")
  rt.fork(async fn() { p.terminals.answer(stream, b"", head, viewer("member", "w1")) }) |> ignore
  rt.advance(0)
  assert_eq(started, ["term-0123456789abcdef /bin/zsh [-l] /home/a 80x24"])
  assert_eq(
    files.get("/data/run/terminals/term-0123456789abcdef.json"),
    Some("{\"by\":\"bo@x\",\"at\":7,\"cwd\":\"/home/a\",\"byEmail\":\"bo@x\",\"workspace\":\"w1\"}"),
  )
  assert_eq(told.length() > 0, true)
  assert_eq(shell_of("windows", Some("/bin/zsh")), ("powershell.exe", ["-NoLogo"]))
  assert_eq(shell_of("linux", Some("")), ("/bin/sh", ["-l"]))
}

///|
test "shell OSC 7 and OSC 9;9 keep a terminal's folder, across chunks (terminals.ts oscCwd)" {
  assert_eq(osc_cwd("\u{1b}]7;file://mac.local/Users/ann/%E6%96%87%E6%A1%A3\u{07}$ "), (Some("/Users/ann/文档"), ""))
  assert_eq(osc_cwd("\u{1b}]9;9;\"C:\\Users\\ann\\proj\"\u{1b}\\PS> "), (Some("C:\\Users\\ann\\proj"), ""))
  let (cwd, tail) = osc_cwd("out\u{1b}]7;file:///Users/ann/wo")
  assert_eq(cwd, None)
  assert_eq(tail, "\u{1b}]7;file:///Users/ann/wo")
  assert_eq(osc_cwd(tail + "rk\u{07}$ "), (Some("/Users/ann/work"), ""))
  assert_eq(osc_cwd("\u{1b}]7;file:///C:/Users/ann\u{07}"), (Some("C:/Users/ann"), ""))
  assert_eq(osc_cwd("plain\u{1b}[31mred"), (None, ""))
  assert_eq(osc_cwd("x\u{1b}]9;"), (None, ""))
  assert_eq(osc_cwd("x\u{1b}]9;9"), (None, "\u{1b}]9;9"))
}

///|
/// A Keycloak sign-in page's parts (station/test/logins.test.ts `KEYCLOAK_PAGE`): its 330 characters with
/// `Hq3Vt8Lm2Xw9Rz4` between them; 315 without; longer than the login terminal is wide with 750 more in its state.
let keycloak_head : String = "https://sso.acme-corp.example/realms/engineering/protocol/openid-connect/auth?client_id=acme-cli&redirect_uri=https%3A%2F%2Fsso.acme-corp.example%2Fcli%2Fdone&response_type=code&scope=openid+profile+email&state="

///|
let keycloak_tail : String = "Nc7Bp1Fy6Dj5Gk0Tsa&code_challenge=K7xQ2mZpL9vR4tY8wB3nC6hJ1fD5gS0aE2iU7oP4kM9&code_challenge_method=S256"

///|
fn keycloak(state : String) -> String {
  keycloak_head + state + keycloak_tail
}

///|
fn keycloak_longer() -> String {
  let b = StringBuilder::new()
  for _ in 0..<250 {
    b.write_string("Zq9")
  }
  keycloak(b.to_string() + "Hq3Vt8Lm2Xw9Rz4")
}

///|
/// A link broken by its program every `width` columns, each line indented.
fn broken_at(url : String, width : Int, indent : String) -> Array[String] {
  let lines = []
  let per = width - indent.length()
  let mut i = 0
  while i < url.length() {
    lines.push(indent + url.unsafe_substring(start=i, end=@cmp.minimum(url.length(), i + per)))
    i += per
  }
  lines
}

///|
test "what the agent reads of a screen: a long page wrapped by the terminal or broken by its program hidden whole, the cursor's line marked" {
  let login = obj("{\"id\":\"a1\"}")
  let line = "Visit " + keycloak_longer() + " to sign in."
  let rows = [
    line.unsafe_substring(start=0, end=COLS),
    line.unsafe_substring(start=COLS, end=line.length()),
    "",
    "Enter the code: ",
    "",
    "",
  ]
  let wrapped = [false, true, false, false, false, false]
  let at = (cursor : (Int, Int), wrapped : Array[Bool]) => screen_for(
    Some({ rows, wrapped, cursor, echo: true, live: true }),
    login,
  )
  assert_eq(at((16, 3), wrapped), "Visit <link> to sign in.\n\nEnter the code:▏")
  assert_eq(at((3, 1), wrapped), "Visit <link> to sign in.▏\n\nEnter the code:")
  assert_eq(at((3, 0), wrapped), "Visit <link> to sign in.▏\n\nEnter the code:")
  assert_eq(at((16, 3), []), "Visit <link> to sign in.\n\nEnter the code:▏")
  // Broken by its program at 80 columns: no part of the page left to read.
  for page in [keycloak("Hq3Vt8Lm2Xw9Rz4"), keycloak("")] {
    let at80 = ["Open this page in your browser:"]
    at80.push_iter(broken_at(page, 80, "  ").iter())
    at80.push_iter(["", "Enter the code: ", "", ""].iter())
    let screen = (cursor : (Int, Int)) => screen_for(
      Some({ rows: at80, wrapped: [], cursor, echo: true, live: true }),
      login,
    )
    assert_eq(screen((16, 7)), "Open this page in your browser:\n  <link>\n\nEnter the code:▏")
    assert_eq(screen((10, 3)), "Open this page in your browser:\n  <link>▏\n\nEnter the code:")
  }
  // At 200 columns, the line's end said after the link.
  let said = "Visit " + keycloak("Hq3Vt8Lm2Xw9Rz4") + " to sign in, then paste the code below."
  let at200 = [said.unsafe_substring(start=0, end=200), said.unsafe_substring(start=200, end=said.length()), "", "Enter the code: "]
  assert_eq(
    screen_for(Some({ rows: at200, wrapped: [false, false, false, false], cursor: (16, 3), echo: true, live: true }), login),
    "Visit <link> to sign in, then paste the code below.\n\nEnter the code:▏",
  )
}
