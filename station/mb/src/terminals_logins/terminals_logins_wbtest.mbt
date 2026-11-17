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
    changed: () => changes.val += 1,
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
  assert_eq(listed, "[{\"id\":\"term-1\",\"by\":\"ann\",\"at\":0,\"cwd\":\"/work/c1\",\"chat\":\"c1\",\"typing\":\"ann\",\"looking\":[]}]")
  assert_eq(r.sent.contains("{\"op\":\"resize\",\"cols\":80,\"rows\":24}\n"), true)
  // typed into, then the stream ends: the view goes, the terminal stays
  inbox.try_offer(Some(frame(KIND_INPUT, b"ls\r"))) |> ignore
  inbox.try_offer(None) |> ignore
  rt.advance(0)
  assert_eq(r.sent.contains("{\"op\":\"write\",\"data\":\"\{base64_of(b"ls\r")}\"}\n"), true)
  assert_eq(stringify(terminals.list("w1")), "[{\"id\":\"term-1\",\"by\":\"ann\",\"at\":0,\"cwd\":\"/work/c1\",\"chat\":\"c1\",\"typing\":null,\"looking\":[]}]")
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
    Some("{\"by\":\"bo@x\",\"at\":7,\"cwd\":\"/home/a\",\"workspace\":\"w1\"}"),
  )
  assert_eq(told.length() > 0, true)
  assert_eq(shell_of("windows", Some("/bin/zsh")), ("powershell.exe", ["-NoLogo"]))
  assert_eq(shell_of("linux", Some("")), ("/bin/sh", ["-l"]))
}
