// The station's browser (browser/service.ts `Browser`: the one Chrome in <data>/browser with each chat's own context
// in it, its tabs among the station's screens) and its part (browser/module.ts `BrowserLive`: each chat's Farview
// where config.json names it, a chat's way to its browser on the agents' door, the `farview` streams, a chat's going
// with its chat, the `browser` tool). The door's way is a WebSocket of the agents' (ws://127.0.0.1:<door>/browser/
// <session>), passed to Chrome's DevTools through the gate of the chat's context: its handshake and frames are here
// (RFC 6455), DevTools' side the shell's (`ws.open`).

///|
/// A WebSocket's accept key for the client's `key`.
fn p54_ws_accept(key : String) -> String {
  @drive.base64(@hash.sha1(@utf8.encode(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")))
}

///|
/// A frame from this end (never masked): its opcode and payload.
fn p54_ws_frame(opcode : Int, payload : Bytes) -> Bytes {
  let out = @buffer.new()
  out.write_byte((0x80 | opcode).to_byte())
  let n = payload.length()
  if n < 126 {
    out.write_byte(n.to_byte())
  } else if n < 65536 {
    out.write_byte(b'\x7e')
    out.write_byte((n >> 8).to_byte())
    out.write_byte(n.to_byte())
  } else {
    out.write_byte(b'\x7f')
    let big = n.to_uint64()
    for i in 0..<8 {
      out.write_byte((big >> (8 * (7 - i))).to_byte())
    }
  }
  out.write_bytes(payload)
  out.to_bytes()
}

///|
/// The frames read so far from a client's bytes (masked as a client's are), what is left over kept for the next read;
/// a message in fragments put together.
priv struct P54WsReader {
  mut carry : Bytes
  pieces : @buffer.Buffer
  mut first_op : Int
}

///|
/// The messages whole in `more`: (opcode, payload); a close is opcode 8.
fn P54WsReader::read(self : P54WsReader, more : Bytes) -> Array[(Int, Bytes)] {
  let all = @buffer.new()
  all.write_bytes(self.carry)
  all.write_bytes(more)
  let b = all.to_bytes()
  let out = []
  let mut at = 0
  while at + 2 <= b.length() {
    let fin = (b[at].to_int() & 0x80) != 0
    let op = b[at].to_int() & 0x0f
    let masked = (b[at + 1].to_int() & 0x80) != 0
    let mut len = (b[at + 1].to_int() & 0x7f).to_int64()
    let mut head = 2
    if len == 126L {
      if at + 4 > b.length() {
        break
      }
      len = ((b[at + 2].to_int() << 8) | b[at + 3].to_int()).to_int64()
      head = 4
    } else if len == 127L {
      if at + 10 > b.length() {
        break
      }
      let mut l = 0L
      for i in 0..<8 {
        l = (l << 8) | b[at + 2 + i].to_int64()
      }
      len = l
      head = 10
    }
    let mask_at = at + head
    if masked {
      head += 4
    }
    let n = len.to_int()
    if at + head + n > b.length() {
      break
    }
    let payload = Bytes::makei(n, i => {
      let x = b[at + head + i]
      if masked {
        x ^ b[mask_at + i % 4]
      } else {
        x
      }
    })
    at += head + n
    if op >= 8 {
      out.push((op, payload))
      continue
    }
    if op != 0 {
      self.first_op = op
      self.pieces.reset()
    }
    self.pieces.write_bytes(payload)
    if fin {
      out.push((self.first_op, self.pieces.to_bytes()))
      self.pieces.reset()
    }
  }
  self.carry = b[at:].to_owned()
  out
}

///|
/// An Upgrade on the browser's route: the handshake answered on the connection, then both ways through the gate until
/// either side ends; None as it wrote its answer itself.
async fn p54_browser_upgrade(host : @host.Host, browsers : @browser.Browsers, r : Request, conn : Json) -> Reply? {
  let upgrade = r.header("upgrade").map(u => u.to_lower())
  if upgrade != Some("websocket") {
    let (status, type_, body) = @browser.door_request_answer()
    return Some({ status, headers: [("content-type", type_)], body: @utf8.encode(body) })
  }
  guard r.header("sec-websocket-key") is Some(key) else { return Some(plain(400, "no Sec-WebSocket-Key")) }
  let (ws, gate_parts) = match @browser.door_upgrade(browsers.door(), r.target) {
    Refused(status, why) => return Some(plain(status, why))
    Through(ws, g) => (ws, g)
  }
  let (opened, _) = host.shell("ws.open", { "url": Json::string(ws), "headers": Json::array([]) }) catch {
    e => return Some(plain(503, "the station's browser does not answer: \{p54_message(e)}"))
  }
  let up_id = opt_field(Some(opened), "id").unwrap_or(Json::null())
  let head = "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-accept: \{p54_ws_accept(key)}\r\n\r\n"
  if !write_on(host, conn, @utf8.encode(head)) {
    return None
  }
  let client_open = Ref(true)
  let up_open = Ref(true)
  let writes : @effect.Queue[Bytes] = @effect.Queue::unbounded()
  let client : @browser.WsEnd = {
    send_text: t => ignore(writes.try_offer(p54_ws_frame(1, @utf8.encode(t)))),
    send_raw: (b, binary) => ignore(writes.try_offer(p54_ws_frame(if binary { 2 } else { 1 }, b))),
    is_open: () => client_open.val,
    connecting: () => false,
    close: () => {
      if client_open.val {
        ignore(writes.try_offer(p54_ws_frame(8, b"")))
      }
      client_open.val = false
    },
    terminate: () => client_open.val = false,
  }
  let upstream : @browser.WsEnd = {
    send_text: t => ignore(
      host.rt.fork_quiet(name="devtools send", async fn() {
        ignore(host.shell("ws.send", { "id": up_id, "text": Json::string(t) })) catch {
          _ => ()
        }
      }),
    ),
    send_raw: (b, _) => ignore(
      host.rt.fork_quiet(name="devtools send", async fn() {
        ignore(host.shell("ws.send", { "id": up_id, "text": Json::string(@utf8.decode_lossy(b)) })) catch {
          _ => ()
        }
      }),
    ),
    is_open: () => up_open.val,
    connecting: () => false,
    close: () => {
      if up_open.val {
        up_open.val = false
        ignore(
          host.rt.fork_quiet(name="devtools close", async fn() {
            ignore(host.shell("ws.close", { "id": up_id })) catch {
              _ => ()
            }
          }),
        )
      }
    },
    terminate: () => up_open.val = false,
  }
  let p = @browser.pass(client, upstream, @browser.Gate::new(gate_parts))
  // (what goes to the client, in its order)
  fork_bg(host, "browser door out", async fn() {
    while true {
      let b = writes.take()
      if !write_on(host, conn, b) {
        client_open.val = false
        p.end()
        return
      }
    }
  })
  // (what Chrome says)
  fork_bg(host, "browser door in", async fn() {
    while up_open.val {
      let (frame, _) = host.shell("ws.next", { "id": up_id }) catch { _ => break }
      match jtext(frame, "text") {
        Some(t) => p.from_chrome(@utf8.encode(t), false)
        None => break
      }
    }
    up_open.val = false
    p.end()
  })
  // (what the agent's client says, on the door's connection)
  let reader : P54WsReader = { carry: b"", pieces: @buffer.new(), first_op: 1 }
  while client_open.val {
    guard (host.tcp_read(conn) catch { _ => None }) is Some(bytes) else { break }
    for m in reader.read(bytes) {
      match m.0 {
        8 => {
          client_open.val = false
          break
        }
        9 => ignore(writes.try_offer(p54_ws_frame(10, m.1)))
        10 => ()
        op => p.from_client(m.1, op == 2)
      }
    }
  }
  client_open.val = false
  p.end()
  None
}

///|
/// The browsers' screens as the station's (screens' `ScreenSource` and `ScreenView` from the browser's own).
fn p54_browser_source(s : @browser.ScreenSource) -> @screens.ScreenSource {
  let open = async fn(o : @screens.ViewOptions) -> @screens.ScreenView {
    let v = (s.open)({
      codecs: o.codecs.map(c => c.name()),
      max_width: o.max_width,
      max_height: o.max_height,
      peek: o.peek,
      fit: o.fit.map(f => (f.width, f.height, f.scale)),
      passkeys: o.passkeys,
    })
    let next = async fn() -> @screens.Frame? {
      match (v.next)() {
        Some(f) =>
          Some({
            config: match f.config {
              Some((codec, w, h)) =>
                match @screens.codec_of(codec) {
                  Some(c) => Some({ codec: c, width: w, height: h, description: None, region: None })
                  None => None
                }
              None => None
            },
            key: f.key,
            ts: f.ts,
            data: f.data,
          })
        None => None
      }
    }
    let base = @screens.ScreenView::bare(next, v.keyframe, async fn(i) { (v.input)(i.to_j()) }, v.close)
    {
      ..base,
      bounds: Some((w, h, _) => (v.bounds)(w, h)),
      set_clipboard: Some(async fn(clip, paste) {
        match clip {
          ClipText(t) => (v.set_clipboard)({ type_: "text", text: t }, paste)
          ClipPng(_) => ()
        }
      }),
      watch_clipboard: Some(f => (v.watch_clipboard)(c => f(ClipText(c.text)))),
      watch_child: Some(v.watch_child),
    }
  }
  let base = @screens.ScreenSource::bare(s.id, BrowserKind, s.title, s.size, open)
  {
    ..base,
    clipboard: Some(s.clipboard),
    peek: (s.peek)(),
    farview: s.farview,
    opened_by: Some(s.opened_by),
    user_tab: s.user_tab,
    sleeping: Some(s.sleeping),
    site: Some(s.site),
    address: Some(s.address),
    open_url: s.open_url,
    reload: s.reload,
    back: s.back,
    forward: s.forward,
    sleep: s.sleep,
    discard: s.discard,
  }
}

///|
/// Where a Chrome may be here (platform `browsers`), best first, those there.
fn p54_browsers_here() -> Array[String] {
  let home = homedir()
  let places = match platform() {
    "darwin" => {
      let apps = (name : String, binary : String) => [
        "/Applications/\{name}.app/Contents/MacOS/\{binary}",
        path([home, "Applications", "\{name}.app", "Contents", "MacOS", binary]),
      ]
      apps("Google Chrome", "Google Chrome") + apps("Chromium", "Chromium") + apps("Microsoft Edge", "Microsoft Edge")
    }
    "win32" => {
      let roots = ["ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA"].filter_map(env_get)
      let under = (rel : Array[String]) => roots.map(r => path([r] + rel))
      under(["Google", "Chrome", "Application", "chrome.exe"]) +
      under(["Chromium", "Application", "chrome.exe"]) +
      under(["Microsoft", "Edge", "Application", "msedge.exe"])
    }
    _ => {
      let on_path = (name : String) => {
        let dirs = env_get("PATH").unwrap_or("").split(":").map(d => d.to_owned()).to_array()
        dirs.map(d => path([d, name]))
      }
      on_path("google-chrome-stable") +
      on_path("google-chrome") +
      ["/opt/google/chrome/chrome"] +
      on_path("chromium") +
      on_path("chromium-browser") +
      on_path("microsoft-edge-stable") +
      on_path("microsoft-edge")
    }
  }
  places.filter(p => (try { Ok(@drive.stat(p)) } catch { e => Err(e) }) is Ok(st) && st.file)
}

///|
/// The machine's processes as the Chrome and Farview hosts ask them (browser `MachineProcs`).
fn p54_browser_procs(host : @host.Host) -> @browser.MachineProcs {
  {
    start_lasting: (program, args, cwd, env) => {
      let ended : Ref[String?] = Ref(None)
      let child = p54_spawn(host, program, args, env~, cwd~, stdin_piped=false, group=true, close=(code, signal) => ended.val = Some(
        match (code, signal) {
          (_, Some(s)) => s
          (Some(c), _) => "exit \{c}"
          _ => "ended"
        },
      )) catch {
        e => {
          let why = p54_message(e)
          return { pid: None, ended: () => Some(why) }
        }
      }
      { pid: Some(child.proc.pid), ended: () => ended.val }
    },
    // (ms since the epoch as the system says it: `ps -o lstart=` is in the machine's own time zone)
    start_time_of: async fn(pid) { start_time_of(pid) },
    group_alive: pgid => pid_alive(pgid),
    end_group: async fn(pgid, ms) {
      ignore(kill(pgid, "SIGTERM", group=true))
      let mut waited = 0.0
      while waited < ms && pid_alive(pgid) {
        @effect.sleep(100) // timer: a deadline for a group to end before it is killed
        waited += 100.0
      }
      if pid_alive(pgid) {
        ignore(kill(pgid, "SIGKILL", group=true))
      }
    },
    signal_group: (pgid, signal) => ignore(kill(pgid, signal, group=true)),
    browsers: p54_browsers_here,
    browsers_soon: async fn() { p54_browsers_here() },
    has_display: () => platform() != "linux" || env_get("DISPLAY") is Some(_) || env_get("WAYLAND_DISPLAY") is Some(_),
  }
}

///|
priv struct P54Browser {
  browsers : @browser.Browsers
  farview : @browser.FarviewTabs
}

///|
/// The browser and its part made (service.ts, module.ts), its tabs among the screens.
async fn p54_browser_start(bus : LiveBus, screens : P54Screens, vault : P54Vault?) -> P54Browser {
  let host = bus.host
  let clock = @browser.host_clock(host, wall_ms().to_double())
  let files = @browser.host_files(host)
  let log = @browser.host_log()
  let machine = @browser.host_machine(host, clock, p54_browser_procs(host))
  let dir = path([bus.data, "browser"])
  let station_screens : @browser.Screens = {
    add: s => screens.hub.add(p54_browser_source(s)),
    changed: Some(() => screens.hub.changed()),
    set_browser: Some(b => screens.hub.set_browser(b.map(x => ({ available: x.available, open_user_tab: x.open_user_tab } : @screens.ScreenBrowser)))),
  }
  let browsers = @browser.browser_service({
    dir,
    chrome: @browser.chrome_host(dir, machine, files, clock, log),
    screens: Some(station_screens),
    clock,
    idle_ms: None,
    user_tab_idle_ms: None,
    context_owner: None,
    used_tab: None,
    files,
    log,
    uuid: () => @drive.random_uuid(),
    random_hex: n => @drive.hex(@drive.random_bytes((n + 1) / 2)),
    pid: @drive.pid(),
  })
  let release_target = "\{platform()}-\{arch()}"
  let native_cache = match platform() {
    "darwin" => path([homedir(), "Library", "Caches", "stillfail-native"])
    _ => env_get("XDG_CACHE_HOME").map(c => path([c, "stillfail-native"])).unwrap_or(path([homedir(), ".cache", "stillfail-native"]))
  }
  let env_map : Map[String, String] = Map([])
  for kv in env_all() {
    env_map[kv.0] = kv.1
  }
  let farview = @browser.FarviewTabs::new({
    dir: path([dir, "farview"]),
    config: () => @browser.farview_config(Some(to_jv((bus.config_raw.val)())), release_target, @browser.farview_releases(), native_cache),
    screens: Some(station_screens),
    fetch: async fn(url) {
      let r = host.fetch(url) catch { _ => return None }
      if r.status >= 200 && r.status < 300 {
        Some(r.body)
      } else {
        None
      }
    },
    sources: name => @browser.farview_sources(name, env_map),
    machine,
    files,
    net: @browser.host_net(host, clock),
    release_io: @browser.host_release_io(host),
    log,
    env: env_all(),
  })
  let door_url = () => bus.parts.door_url()
  let hold = @browser.BrowserAgentHold::new(
    {
      driving_people: id => screens.hub.driving_people(id),
      has_taken_view: id => screens.hub.has_taken_view(id),
      yield_to_agent: (id, by) => screens.hub.yield_to_agent(id, by),
      join_agent: (id, by) => screens.hub.join(id, @screens.Watcher::new(by, true, _ => (), agent=true)),
    },
    session => {
      let mut title = ""
      let home = bus.store.call("sessionHomeThread", [Json::string(session)]) catch { _ => Json::null() }
      if opt_field(Some(home), "thread") is Some(t) { title = jtext(t, "title").unwrap_or("").trim().to_owned() }
      if title == "" {
        let recent = bus.store.call("recentSessionThreads", [Json::string(session), Json::number(1.0)]) catch { _ => Json::null() }
        match opt_field(Some(recent), "threads") {
          Some(Array(ts)) if ts.length() > 0 =>
            title = opt_text(opt_field(Some(ts[0]), "thread"), "title").unwrap_or("").trim().to_owned()
          _ => ()
        }
      }
      if title == "" {
        title = match bus_session_row_opt(bus, session) {
          Some(row) => jtext(row, "title").unwrap_or("").trim().to_owned()
          None => ""
        }
      }
      "agent: \{if title != "" { title } else { session }}"
    },
    clock,
  )
  browsers.on_agent_act((session, target, m) => hold.act(session, target, m))
  browsers.on_stopped(session => hold.release_session(session))
  ignore(
    bus.store.subscribe(change => match change {
      { "type": "session", "key": String(k), .. } =>
        match bus_session_row_opt(bus, k) {
          Some({ "running": True, .. }) => ()
          _ => hold.release_session(k)
        }
      { "type": "sessionRemoved", "key": String(k), .. } => hold.release_session(k)
      _ => ()
    }),
  )
  @browser.browser_live(
    {
      door: _ => bus.parts.door({ prefix: @browser.browser_prefix, request: async fn(r, conn) { p54_browser_upgrade(host, browsers, r, conn) } }),
      streams: answer => bus.parts.streams("farview", async fn(asked) {
        let read_only = opt_text(opt_field(Some(asked), "viewer"), "role") == Some("viewer")
        let said = answer(read_only, to_jv(opt_field(Some(asked), "head").unwrap_or(Json::null())))
        let stream = p54_member_stream(host, p54_stream_handle(asked))
        match said {
          Refuse(status, error) => {
            (stream.write)(p54_head_line(status, "application/json"))
            (stream.write)(p54_error_body(error))
            (stream.finish)()
          }
          Carry(port) => {
            let c = p54_tcp_open(host, port) catch {
              e => {
                (stream.write)(p54_head_line(503, "application/json"))
                (stream.write)(p54_error_body("the tab's host does not answer: \{p54_message(e)}"))
                (stream.finish)()
                return
              }
            }
            (stream.write)(p54_head_line(200, "application/x-farview"))
            let carry = p54_bytes_of(opt_field(Some(asked), "carry"))
            if carry.length() > 0 {
              c.write(carry)
            }
            ignore(
              host.rt.fork_daemon("farview up", on_error=_ => (), async fn() {
                // (a stream the device reset fails its read: the end of it as much as its end is)
                try {
                  while (stream.read)() is Some(b) {
                    c.write(b) catch {
                      _ => break
                    }
                  }
                } catch {
                  _ => ()
                }
                c.close()
              }),
            )
            while c.read() is Some(b) {
              (stream.write)(b) catch {
                _ => break
              }
            }
            c.close()
            (stream.finish)() catch {
              _ => ()
            }
          }
        }
      }) catch {
        _ => err_write("station: the farview streams are answered twice\n")
      },
      session_ended: f => bus.parts.session_ended(f),
      tools: tools => bus.parts.tools(
        tools.map(t => {
          let declared = of_jv(t.declaration)
          ({
            name: jtext(declared, "name").unwrap_or("browser"),
            declared,
            call: async fn(args, context) {
              match (try { Ok((t.run)(p54_session(context), to_jv(args))) } catch { e => Err(e) }) {
                Ok(text) => tool_answer(text)
                Err(e) => tool_answer(@browser.message_of(e), error=true)
              }
            },
          } : PartTool)
        }),
      ),
      door_url,
    },
    browsers,
    farview,
    clock,
  )
  p54_browser_tabs_ref.val = session => browsers.tabs(session).map(t => (t.id, t.url))
  // The vault told of the chats' sign-ins as the browser takes them out, starts afresh, uses or takes up a context.
  match vault {
    Some(v) => {
      let secrets = v.vault.secrets
      browsers.on_taken_out((session, request, cookies, workspace) => secrets.renewed(session, request, cookies, workspace?) catch {
        _ => ()
      })
      browsers.on_fresh(session => secrets.sign_in_again(session) catch { _ => () })
      browsers.on_used((session, host_) => secrets.browser_used(session, host_))
      browsers.on_resumed(session => secrets.passkeys_again(session) catch { _ => () })
    }
    None => ()
  }
  { browsers, farview }
}

///|
/// What the vault and the routes ask of the browser by name (`browser.<call>`).
async fn p54_browser_ask(b : P54Browser, op : String, a : Json) -> Json? {
  let s = (i : Int) => call_arg_text(a, i)
  let d = call_arg(a, 1)
  let answer : Json = match op {
    "browser.cookies" => Json::string(b.browsers.cookies(s(0), opt_strs(call_arg(a, 1)), opt_true(call_arg(a, 2))))
    "browser.signIn" => {
      b.browsers.sign_in(
        s(0),
        opt_text(d, "request").unwrap_or(""),
        opt_text(d, "workspace"),
        opt_strs(opt_field(d, "sites")),
        opt_text(d, "cookies").unwrap_or(""),
        opt_num(opt_field(d, "until")).unwrap_or(0.0),
      )
      Json::null()
    }
    "browser.passkeysIn" => {
      b.browsers.passkeys_in(s(0), opt_strs(opt_field(d, "sites")), opt_text(d, "cookies").unwrap_or(""))
      Json::null()
    }
    "browser.extendSignIn" => {
      b.browsers.extend_sign_in(s(0), s(1), opt_num(call_arg(a, 2)).unwrap_or(0.0))
      Json::null()
    }
    "browser.passkeysAgain" => {
      b.browsers.passkeys_again()
      Json::null()
    }
    "browser.tabs" => Json::array(b.browsers.tabs_j(s(0)).map(of_jv))
    "browser.status" => of_jv(b.browsers.status(s(0)).to_j())
    "browser.look" => {
      let form = b.browsers.form(s(0), s(1))
      let got = (form.look)()
      (form.close)()
      of_jv(got.to_j())
    }
    "browser.drive" => {
      let form = b.browsers.form(s(0), s(1))
      let values = call_arg(a, 3)
      let got = @browser.drive(
        form,
        s(2),
        { username: opt_text(values, "username"), password: opt_text(values, "password"), code: opt_text(values, "code") },
        opt_strs(call_arg(a, 4)),
        async fn(ms) { @effect.sleep(ms.to_int()) },
      )
      (form.close)()
      of_jv(got.to_j())
    }
    "browser.closeOf" => {
      b.browsers.close_of(s(0))
      Json::null()
    }
    _ => return None
  }
  Some(answer)
}

///|
/// A stream's head line (mesh/wire.ts `writeLine`): its status and type.
fn p54_head_line(status : Int, type_ : String) -> Bytes {
  let head : Json = { "status": Json::number(status.to_double()), "headers": { "content-type": Json::string(type_) } }
  @utf8.encode(head.stringify() + "\n")
}

///|
fn p54_error_body(error : String) -> Bytes {
  let body : Json = { "error": Json::string(error) }
  @utf8.encode(body.stringify())
}
