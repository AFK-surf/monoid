// A Claude TUI and its hooks under one station runner, as src/agents/claude-tui.mjs runs them under Node, line for line:
// `stillfail-reader <…>/claude-tui.mjs <node> <runner> <claude> <args…>` (the driver's: agent_drivers claude.mbt
// `TuiBridge`), its hooks `stillfail-reader <…>/claude-tui.mjs hook` and its tools `… mcp <url>`, the same program
// (`<node>`) where a release has no Node. Only lifecycle frames go to the runner's durable stdout (`init`,
// `compact_boundary`, `result`); the terminal's bytes are the PTY's (the runner's `--relay-pty`), and chat replies go
// through the session's usual MCP server. A bridge a station from before started under Node is taken up as it is
// (agent_drivers `tui_runner`): its lines are the same.

///|
/// The hooks the bridge adds to the session's settings, each its own command (`hook`).
let tui_hook_events : Array[String] = ["SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "PreCompact", "PostCompact"]

///|
/// The most a hook's line is read before its connection is dropped (claude-tui.mjs's 16 384).
let tui_line_most : Int = 16384

///|
/// How long the bridge waits for its startup hook and tools, or a submitted message's acknowledgement.
let tui_deadline_ms : Int = 30000

///|
/// Which of the bridge's parts `argv` runs (`hook`, `mcp` or `run`), by its first argument's name: the bridge's file
/// (`…/claude-tui.mjs`, as the driver and a station from before name it) or `claude-tui`.
pub fn claude_tui_of(argv : Array[String]) -> String? {
  guard argv.length() >= 2 else { None }
  let a = argv[1].replace_all(old="\\", new="/")
  guard a.has_suffix("/claude-tui.mjs") || a == "claude-tui.mjs" || a == "claude-tui" else { None }
  match argv.get(2) {
    Some("hook") => Some("hook")
    Some("mcp") => Some("mcp")
    _ => Some("run")
  }
}

///|
/// The shell's own files for the bridge's parts (its sockets and fetches keep nothing there).
pub fn claude_tui_shell() -> String {
  @nodepath.join(sep(), [tmpdir(), "stillfail-tui-shell"])
}

///|
/// Runs the bridge's part `which` (`claude_tui_of`); its exit code.
pub async fn run_claude_tui(host : @host.Host, which : String, argv : Array[String]) -> Int {
  match which {
    "hook" => tui_hook(host)
    "mcp" => tui_serve_mcp(host, argv.get(3).unwrap_or(""))
    _ => tui_run(host, argv[1], argv[2:].to_owned())
  }
}

///|
fn tui_digest(text : String) -> String {
  @accounts_pool.sha256_hex(text)
}

///|
/// A prompt as a person pasted it, its `<pasted_content>` wrapping taken off (the hook's regular expression).
fn tui_unpasted(prompt : String) -> String {
  let open = "<pasted_content id=\""
  let close = "\n</pasted_content>"
  guard prompt.has_prefix(open) && prompt.has_suffix(close) else { prompt }
  let rest = prompt[open.length():].to_owned()
  match rest.find("\">\n") {
    Some(at) if at > 0 && !rest[:at].to_owned().contains("\"") => {
      let body_from = open.length() + at + 3
      let body_to = prompt.length() - close.length()
      if body_to < body_from {
        prompt
      } else {
        prompt[body_from:body_to].to_owned()
      }
    }
    _ => prompt
  }
}

///|
/// `String(a || b || c || "Claude API error")` of a hook's fields.
fn tui_failure(h : Json) -> String {
  let truthy = (v : Json?) => match v {
    None | Some(Null) | Some(False) | Some(String("")) => None
    Some(Number(n, ..)) if n == 0.0 || n != n => None
    Some(v) => Some(js_string(v))
  }
  let said = match truthy(tui_field(h, "error_details")) {
    Some(t) => t
    None =>
      match truthy(tui_field(h, "last_assistant_message")) {
        Some(t) => t
        None => truthy(tui_field(h, "error")).unwrap_or("Claude API error")
      }
  }
  if said.length() > 1500 {
    said[:1500].to_owned()
  } else {
    said
  }
}

///|
fn tui_field(v : Json, k : String) -> Json? {
  match v {
    Object(o) => o.get(k)
    _ => None
  }
}

///|
/// The hook a Claude TUI runs at each lifecycle event: its session's own (not a subagent's) told the bridge, small.
async fn tui_hook(host : @host.Host) -> Int {
  let input = stdin_text(host)
  let h : Json = @json.parse(input) catch {
    e => {
      @host.note(e.to_string())
      return 1
    }
  }
  let agent = tui_field(h, "agent_id")
  let agent_set = match agent {
    None | Some(Null) | Some(False) | Some(String("")) => false
    Some(Number(n, ..)) => n != 0.0
    _ => true
  }
  let session = tui_field(h, "session_id")
  let ours = env_get("STILLFAIL_RUNTIME_SESSION_ID")
  if agent_set || session != ours.map(Json::string) {
    return 0
  }
  // Tool inputs, pasted messages and the last assistant response can be large. Never send them to the runner.
  let event : Map[String, Json] = {
    "key": match env_get("STILLFAIL_TUI_KEY") {
      Some(k) => Json::string(k)
      None => Json::null()
    },
    "event": tui_field(h, "hook_event_name").unwrap_or(Json::null()),
  }
  match event.get("event") {
    Some(String("UserPromptSubmit")) => {
      let prompt = match tui_field(h, "prompt") {
        None | Some(Null) => ""
        Some(v) => js_string(v)
      }
      event["prompt"] = Json::string(tui_digest(tui_unpasted(prompt)))
    }
    Some(String("StopFailure")) => event["error"] = Json::string(tui_failure(h))
    _ => ()
  }
  match (try { Ok(tui_notify(host, Json::object(event))) } catch { e => Err(e) }) {
    Ok(_) => 0
    Err(e) => {
      @host.note(e.to_string())
      1
    }
  }
}

///|
/// Tells the bridge a hook's event on its port; it answers `ok`.
async fn tui_notify(host : @host.Host, event : Json) -> Unit {
  let port = match env_get("STILLFAIL_TUI_PORT") {
    Some(p) => @string.parse_int(p) catch { _ => 0 }
    None => 0
  }
  let socket = host.tcp_open(port).socket
  socket.write(@utf8.encode(event.stringify() + "\n"))
  let answer = @buffer.Buffer()
  while true {
    match (socket.read() catch { _ => break }) {
      Some(b) if b.length() > 0 => answer.write_bytes(b)
      _ => break
    }
  }
  socket.destroy()
  if @utf8.decode_lossy(answer.to_bytes()).trim().to_owned() != "ok" {
    raise LiveError("Claude TUI bridge refused its hook")
  }
}

///|
/// The station's MCP is stateless HTTP JSON-RPC. Claude is given the same responses over stdio so the first paste can
/// wait until Claude itself has received the list, its per-tool loading hints with it.
async fn tui_serve_mcp(host : @host.Host, url : String) -> Int {
  // the calls under way, by their ids' JSON: the shell's fetch each is, to give it up
  let calls : Map[String, (Ref[Int64], Ref[Bool])] = Map([])
  let token = env_get("STILLFAIL_MCP_TOKEN").unwrap_or("")
  let abort = (call : (Ref[Int64], Ref[Bool])) => {
    call.1.val = true
    if call.0.val > 0L {
      ignore(host.shell_sync("fetch.cancel", { "id": Json::number(call.0.val.to_double()) })) catch {
        _ => ()
      }
    }
  }
  let running : Ref[Int] = Ref(0)
  let idle : @effect.Deferred[Unit] = @effect.Deferred::new()
  let forward = async fn(request : Json, line : String) {
    if tui_field(request, "method") == Some(Json::string("notifications/cancelled")) {
      match tui_field(request, "params") {
        Some(p) =>
          match tui_field(p, "requestId") {
            Some(r) => if calls.get(r.stringify()) is Some(c) { abort(c) }
            None => ()
          }
        None => ()
      }
    }
    let call = (Ref(0L), Ref(false))
    let expects_reply = request is Object(o) && o.contains("id")
    let id = tui_field(request, "id").unwrap_or(Json::null())
    if expects_reply {
      calls[id.stringify()] = call
    }
    let mut listed = false
    let attempt = try {
      let (answer, body) = host.shell(
        "fetch",
        {
          "url": Json::string(url),
          "method": Json::string("POST"),
          "headers": Json::array([
            Json::array([Json::string("content-type"), Json::string("application/json")]),
            Json::array([Json::string("authorization"), Json::string("Bearer " + token)]),
          ]),
        },
        bytes=@utf8.encode(line),
        called=i => call.0.val = i,
      )
      let status = match tui_field(answer, "status") {
        Some(Number(n, ..)) => n.to_int()
        _ => 0
      }
      // (as fetch's `redirect: "error"`: one sent elsewhere is no answer)
      if status < 200 || status >= 300 {
        raise LiveError("Station MCP returned HTTP \{status}")
      }
      if expects_reply {
        let text = match body {
          Some(b) => @utf8.decode_lossy(b)
          None => ""
        }
        let result = @json.parse(text)
        host.say(result.stringify())
        listed = tui_field(request, "method") == Some(Json::string("tools/list")) &&
          (match tui_field(result, "result") {
            Some(r) =>
              (tui_field(r, "tools") is Some(Array(_))) &&
              (match tui_field(r, "nextCursor") {
                None | Some(Null) | Some(False) | Some(String("")) => true
                _ => false
              })
            None => false
          })
      }
      Ok(())
    } catch {
      e => Err(e)
    }
    match attempt {
      Err(e) if !call.1.val && expects_reply =>
        host.say(
          (
            {
              "jsonrpc": "2.0",
              "id": id,
              "error": { "code": -32603, "message": Json::string(tui_error_message(e)) },
            } : Json
          ).stringify(),
        )
      _ => ()
    }
    if expects_reply {
      calls.remove(id.stringify())
    }
    if listed {
      tui_notify(host, {
        "key": match env_get("STILLFAIL_TUI_KEY") {
          Some(k) => Json::string(k)
          None => Json::null()
        },
        "event": "ToolsListed",
      })
    }
  }
  while host.line() is Some(line) {
    let request : Json = @json.parse(line) catch {
      e => {
        @host.note(e.to_string())
        continue
      }
    }
    running.val += 1
    ignore(
      host.rt.fork(name="a tool call through the TUI's bridge", async fn() {
        forward(request, line) catch {
          e => @host.note(tui_error_message(e))
        }
        running.val -= 1
        if running.val == 0 {
          ignore(idle.succeed(()))
        }
      }),
    )
  }
  // (stdin closed: every call under way given up)
  for c in calls.values().collect() {
    abort(c)
  }
  if running.val > 0 {
    idle.wait()
  }
  0
}

///|
/// An error's words as `error.message` says them.
fn tui_error_message(e : Error) -> String {
  match e {
    LiveError(s) => s
    @wire.ShellError(s) => s
    other => other.to_string()
  }
}

///|
/// What a person's text becomes in the terminal: only the driver's own compaction is a command; control bytes and
/// leading TUI shortcuts in a person's text never become keystrokes, a bracketed paste's terminator neither.
fn tui_literal(text : String) -> String {
  let t = text.replace_all(old="\r\n", new="\n")
  let out = StringBuilder()
  for c in t {
    let n = c.to_int()
    if (n >= 0 && n <= 8) || (n >= 0x0b && n <= 0x1f) || (n >= 0x7f && n <= 0x9f) {
      let hex = n.to_string(radix=16)
      out.write_string("\\u" + "0000"[:4 - hex.length()].to_owned() + hex)
    } else {
      out.write_char(c)
    }
  }
  out.to_string()
}

///|
/// The bridge: Claude's TUI started under the runner's PTY with its hooks and its tools, a station turn pasted into
/// it as its startup hook and tools say it is ready, its end told as Claude Code's `result`.
async fn tui_run(host : @host.Host, script : String, given : Array[String]) -> Int {
  guard given.length() >= 3 else {
    @host.note("claude-tui: <node> <runner> <claude> [args...]")
    return 1
  }
  let node = given[0]
  let runner = given[1]
  let claude = given[2]
  let args = given[3:].to_owned()
  let key = @drive.random_uuid()
  // its hooks added to the settings it was given, and Claude's permission prompt for the dangerous mode skipped
  match args.search("--settings") {
    Some(at) if at + 1 < args.length() => {
      let settings = match (try { Ok(@json.parse(args[at + 1])) } catch { e => Err(e) }) {
        Ok(Object(m)) => m.copy()
        _ => Map([])
      }
      let hooks = match settings.get("hooks") {
        Some(Object(h)) => h.copy()
        _ => Map([])
      }
      for event in tui_hook_events {
        let list = match hooks.get(event) {
          Some(Array(xs)) => xs.copy()
          _ => []
        }
        list.push({
          "hooks": [
            {
              "type": "command",
              "command": Json::string(node),
              "args": [Json::string(script), "hook"],
              "timeout": 10,
            },
          ],
        })
        hooks[event] = Json::array(list)
      }
      settings["hooks"] = Json::object(hooks)
      settings["skipDangerousModePermissionPrompt"] = Json::boolean(true)
      args[at + 1] = Json::object(settings).stringify()
    }
    _ => {
      @host.note("claude-tui: no --settings to add its hooks to")
      return 1
    }
  }
  // its tools over stdio, through this bridge (`mcp`)
  match args.search("--mcp-config") {
    Some(at) if at + 1 < args.length() => {
      let config = match (try { Ok(@json.parse(args[at + 1])) } catch { e => Err(e) }) {
        Ok(Object(m)) => m.copy()
        _ => Map([])
      }
      let servers = match config.get("mcpServers") {
        Some(Object(s)) => s.copy()
        _ => Map([])
      }
      let url = match servers.get("stillfail") {
        Some(Object(s)) =>
          match s.get("url") {
            Some(String(u)) => u
            _ => ""
          }
        _ => ""
      }
      servers["stillfail"] = {
        "type": "stdio",
        "command": Json::string(node),
        "args": [Json::string(script), "mcp", Json::string(url)],
      }
      config["mcpServers"] = Json::object(servers)
      args[at + 1] = Json::object(config).stringify()
    }
    _ => {
      @host.note("claude-tui: no --mcp-config to serve its tools by")
      return 1
    }
  }
  let terminal : Ref[Proc?] = Ref(None)
  let pending : Ref[String?] = Ref(None)
  let deadline : Ref[@effect.Fiber[Unit]?] = Ref(None)
  let tools_listed = Ref(false)
  let ready = Ref(false)
  let submitted = Ref(false)
  let expected_prompt : Ref[String?] = Ref(None)
  let compact = Ref(false)
  let closing = Ref(false)
  let frame = (v : Json) => host.say(v.stringify())
  let clear_deadline = () => {
    match deadline.val {
      Some(f) => f.interrupt()
      None => ()
    }
    deadline.val = None
  }
  let close = (error : String?) => {
    if !closing.val {
      closing.val = true
      clear_deadline()
      match error {
        Some(e) if e != "" => @host.note(e)
        _ => ()
      }
      if pending.val is Some(_) {
        let said = error.unwrap_or("")
        frame({ "type": "result", "is_error": Json::boolean(said != ""), "result": Json::string(said) })
        pending.val = None
      }
      // EOF kills the PTY's process group. An interrupt starts a fresh TUI on --resume for the next turn.
      match terminal.val {
        Some(t) => t.end_input()
        None => ()
      }
    }
  }
  let expect_hook = (reason : String) => {
    clear_deadline()
    deadline.val = Some(
      host.rt.fork(name="the TUI's deadline", async fn() {
        // timer: bound a missing startup or submission acknowledgment
        @effect.sleep(tui_deadline_ms)
        deadline.val = None
        close(Some(reason))
      }),
    )
  }
  let deliver = () => {
    match (pending.val, terminal.val) {
      (Some(p), Some(t)) if ready.val && tools_listed.val && !submitted.val && !closing.val => {
        let text = if compact.val {
          "/compact"
        } else {
          "<station_message>\n" + tui_literal(p) + "\n</station_message>"
        }
        expected_prompt.val = Some(tui_digest(text))
        ignore(t.write(@utf8.encode("\u{1b}[200~" + text + "\u{1b}[201~\r")))
        submitted.val = true
        expect_hook(
          "Claude TUI did not acknowledge the submitted message. Check the profile's interactive Claude setup and hooks.",
        )
      }
      _ => ()
    }
  }
  let on_hook = (h : Json) => {
    if closing.val {
      return
    }
    let event = match tui_field(h, "event") {
      Some(String(e)) => e
      _ => ""
    }
    // (a manually requested compaction finishes at its PostCompact: as a Stop)
    let mut ends = false
    match event {
      "ToolsListed" | "SessionStart" => {
        if event == "ToolsListed" {
          tools_listed.val = true
        } else {
          ready.val = true
        }
        if ready.val && tools_listed.val && !submitted.val {
          clear_deadline()
          deliver()
        }
      }
      "UserPromptSubmit" =>
        if submitted.val &&
          !compact.val &&
          expected_prompt.val is Some(want) &&
          tui_field(h, "prompt") == Some(Json::string(want)) {
          expected_prompt.val = None
          clear_deadline()
        }
      "PreCompact" => if compact.val { clear_deadline() }
      "PostCompact" => {
        frame({ "type": "system", "subtype": "compact_boundary" })
        if compact.val {
          ends = true
        }
      }
      "Stop" | "StopFailure" => ends = true
      _ => ()
    }
    if ends && pending.val is Some(_) && submitted.val {
      if event == "Stop" && !compact.val && expected_prompt.val is Some(_) {
        close(Some("Claude TUI ended before acknowledging the complete submitted message"))
      } else {
        clear_deadline()
        let failed = event == "StopFailure"
        frame({
          "type": "result",
          "is_error": Json::boolean(failed),
          "result": if failed {
            tui_field(h, "error").unwrap_or(Json::null())
          } else {
            Json::string("")
          },
        })
        pending.val = None
        submitted.val = false
        compact.val = false
      }
    }
  }
  // the hooks' own port, on this machine only: each a line with this bridge's key, answered `ok`
  let listened = host.tcp_listen_local(0) catch {
    e => {
      @host.note(tui_error_message(e))
      return 1
    }
  }
  let lid = listened.id
  let port = listened.port
  guard port > 0 else {
    @host.note("claude-tui: no port for its hooks")
    host.listen_close(lid)
    return 1
  }
  let accepting = host.rt.fork(name="the TUI's hooks", async fn() {
    while true {
      let conn = host.accept(lid) catch { _ => break }
      ignore(
        host.rt.fork_quiet(name="a TUI hook", async fn() {
          let socket = conn.socket
          let line = @buffer.Buffer()
          let mut took = false
          while true {
            match (socket.read() catch { _ => break }) {
              Some(b) if b.length() > 0 => {
                line.write_bytes(b)
                if line.length() > tui_line_most {
                  break
                }
                let text = @utf8.decode_lossy(line.to_bytes())
                if !text.contains("\n") {
                  continue
                }
                let event : Json = @json.parse(text) catch { _ => break }
                if tui_field(event, "key") != Some(Json::string(key)) {
                  break
                }
                on_hook(event)
                socket.write(b"ok\n") catch {
                  _ => ()
                }
                socket.end_write() catch {
                  _ => ()
                }
                took = true
                break
              }
              _ => break
            }
          }
          ignore(took)
          socket.destroy()
        }),
      )
    }
  })
  let env = env_all().filter(kv => kv.0 != "MCP_DISCOVERY_CACHE" && kv.0 != "STILLFAIL_TUI_KEY" && kv.0 != "STILLFAIL_TUI_PORT")
  env.push(("MCP_DISCOVERY_CACHE", "0"))
  env.push(("STILLFAIL_TUI_KEY", key))
  env.push(("STILLFAIL_TUI_PORT", port.to_string()))
  // The relay outlives a group signal to the bridge just long enough to see EOF and end its own PTY group.
  let child = spawn(host, runner, ["--relay-pty", claude, ..args], env~, stdin_piped=true, stdout=Piped, stderr=Piped, group=true) catch {
    SysError(e) => {
      close(Some(e))
      host.listen_close(lid)
      accepting.interrupt()
      return 0
    }
  }
  terminal.val = Some(child)
  let finished : @effect.Deferred[Unit] = @effect.Deferred::new()
  ignore(
    host.rt.fork(name="the TUI's terminal", async fn() {
      while true {
        match child.events.take() {
          Out(_) => () // (the terminal's bytes are the PTY's: read and let go)
          Err(b) => @host.note(@utf8.decode_lossy(b).trim_end(chars="\n").to_owned())
          Exit(code, signal) => {
            if !closing.val {
              let why = match (signal, code) {
                (Some(s), _) => s
                (None, Some(c)) => c.to_string()
                (None, None) => "null"
              }
              close(Some("Claude TUI exited (\{why})"))
            }
            ignore(finished.succeed(()))
            break
          }
        }
      }
    }),
  )
  ignore(
    host.rt.fork(name="the TUI's turns", async fn() {
      while host.line() is Some(line) {
        if closing.val {
          continue
        }
        let packet : Json = @json.parse(line) catch {
          e => {
            close(Some(e.to_string()))
            continue
          }
        }
        let kind = tui_field(packet, "type")
        if kind == Some(Json::string("user")) || kind == Some(Json::string("compact")) {
          if pending.val is Some(_) {
            close(Some("Claude TUI received overlapping turns"))
            continue
          }
          compact.val = kind == Some(Json::string("compact"))
          pending.val = Some(
            if compact.val {
              ""
            } else {
              match packet {
                { "message": { "content": [{ "text": String(t), .. }, ..], .. }, .. } => t
                _ => {
                  close(Some("TypeError: Cannot read properties of undefined (reading 'text')"))
                  continue
                }
              }
            },
          )
          frame({ "type": "system", "subtype": "init" })
          deliver()
        } else {
          let subtype = match tui_field(packet, "request") {
            Some(r) => tui_field(r, "subtype")
            None => None
          }
          if subtype == Some(Json::string("interrupt")) {
            close(None)
          } else if subtype == Some(Json::string("background_tasks")) && submitted.val {
            ignore(child.write(b"\x02"))
          }
        }
      }
      close(None)
    }),
  )
  expect_hook(
    "Claude TUI is waiting for its startup hook or station tools. Check the station connection and trust its sessions folder in Claude Code, or select Print in model settings.",
  )
  finished.wait()
  host.listen_close(lid)
  accepting.interrupt()
  0
}
