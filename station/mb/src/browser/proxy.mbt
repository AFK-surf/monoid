// A chat's way to the station's browser (src/browser/proxy.ts, "A chat's own environment"): a WebSocket on the
// agents' door, ws://127.0.0.1:<door>/browser/<the session's key, base64url>, to the DevTools of the station's one
// Chrome through a gate (gate.mbt) that lets the session reach only its chat's own browser context: its tabs, its
// cookies. Nothing asked on it brings the browser in front of what the person at the machine is doing. The address
// stays when Chrome is started again or another station process takes the door. The door's HTTP and WebSockets are the
// station's (parts.ts' door): what is said here is what it answers and passes.

///|
pub let browser_prefix : String = "browser"

///|
/// The largest message passed either way (a screenshot of a large page is big).
pub let browser_max_message : Int = 256 * 1024 * 1024

///|
/// How long the browser's DevTools are given to take the connection (Chrome's time: the machine's clock).
pub let door_open_ms : Double = 10_000.0

///|
/// Where `session` reaches the browser, after the door's origin (`http://127.0.0.1:<port>`).
pub fn session_path(session : String) -> String {
  "/\{browser_prefix}/\{base64url(utf8(session))}"
}

///|
fn base64url_char(c : Char) -> Bool {
  is_ascii_alpha(c) || is_ascii_digit(c) || c == '_' || c == '-'
}

///|
/// The session a door path names; None when it names none
/// (`/^\/browser\/([A-Za-z0-9_-]+)\/?(?:\?.*)?$/`).
pub fn session_of_path(url : String) -> String? {
  let head = "/browser/"
  if !url.has_prefix(head) {
    return None
  }
  let n = url.length()
  let mut i = head.length()
  while i < n && base64url_char(Int::unsafe_to_char(url.unsafe_charcode_at(i))) {
    i += 1
  }
  if i == head.length() {
    return None
  }
  let key = slice(url, head.length(), b=i)
  let mut j = i
  if j < n && url.unsafe_charcode_at(j) == '/'.to_int() {
    j += 1
  }
  if j < n {
    if url.unsafe_charcode_at(j) != '?'.to_int() {
      return None
    }
    // (`.` matches no line's end)
    for k in (j + 1)..<n {
      let c = url.unsafe_charcode_at(k)
      if c == 0x0a || c == 0x0d || c == 0x2028 || c == 0x2029 {
        return None
      }
    }
  }
  let session = from_utf8(from_base64url(key))
  if session != "" && session_path(session) == "/\{browser_prefix}/\{key}" {
    Some(session)
  } else {
    None
  }
}

///|
/// What the door asks of the browsers (browsers.mbt `Browsers`): for a session, the browser's DevTools (started if
/// it is not running) and its chat's context there.
pub(all) struct DoorBrowsers {
  open : async (String) -> (String, GateParts)
}

///|
/// One end of a WebSocket the door passes between (the agent's client, Chrome's DevTools).
pub(all) struct WsEnd {
  /// A text message sent.
  send_text : (String) -> Unit
  /// A message sent as it came (`binary` as it was).
  send_raw : (Bytes, Bool) -> Unit
  /// Whether it is open (`readyState === OPEN`); `connecting`: still opening.
  is_open : () -> Bool
  connecting : () -> Bool
  close : () -> Unit
  terminate : () -> Unit
}

///|
/// The answer the door gives a plain request on the browser's route.
pub fn door_request_answer() -> (Int, String, String) {
  (
    400, "text/plain; charset=utf-8", "The station's browser is a WebSocket here: give this address to chrome-devtools-mcp --wsEndpoint or Playwright's connectOverCDP.",
  )
}

///|
/// How an Upgrade on the browser's route goes: refused (a status and words), or passed to Chrome's DevTools at `ws`
/// through a gate of the chat's context.
pub(all) enum DoorUpgrade {
  Refused(Int, String)
  Through(String, GateParts)
}

///|
/// The door's Upgrade for `url`: the session it names, the browser opened for it (started where it is not running).
pub async fn door_upgrade(browser : DoorBrowsers, url : String) -> DoorUpgrade {
  guard session_of_path(url) is Some(session) else {
    return Refused(404, "the station's browser is /browser/<session>, as the browser tool gives it")
  }
  let (ws, gate) = (browser.open)(session) catch {
    e => return Refused(503, "the station's browser could not be started: \{message_of(e)}")
  }
  Through(ws, gate)
}

///|
/// Both ways through `gate`, until either side ends: what the station's door does with each message of either end
/// (`from_client`, `from_chrome`), and `end` as either closes or fails.
pub struct Pass {
  priv client : WsEnd
  priv upstream : WsEnd
  priv gate : Gate
}

///|
pub fn pass(client : WsEnd, upstream : WsEnd, gate : Gate) -> Pass {
  { client, upstream, gate }
}

///|
fn Pass::up(self : Pass, texts : Array[String]) -> Unit {
  if (self.upstream.is_open)() {
    for t in texts {
      (self.upstream.send_text)(t)
    }
  }
}

///|
fn Pass::down(self : Pass, texts : Array[String]) -> Unit {
  if (self.client.is_open)() {
    for t in texts {
      (self.client.send_text)(t)
    }
  }
}

///|
/// A message of the agent's client: DevTools speaks text; anything else is not let through.
pub fn Pass::from_client(self : Pass, data : Bytes, binary : Bool) -> Unit {
  if binary {
    return
  }
  let passed = self.gate.from_client(from_utf8(data))
  self.up(passed.up)
  self.down(passed.down)
}

///|
/// A message of Chrome's.
pub fn Pass::from_chrome(self : Pass, data : Bytes, binary : Bool) -> Unit {
  if !binary {
    let t = from_utf8(data)
    if self.gate.wants(t) {
      let passed = self.gate.from_chrome(t)
      self.up(passed.up)
      self.down(passed.down)
      return
    }
  }
  if (self.client.is_open)() {
    (self.client.send_raw)(data, binary)
  }
}

///|
/// Either side closed or failed: both ended.
pub fn Pass::end(self : Pass) -> Unit {
  for ws in [self.client, self.upstream] {
    if (ws.is_open)() {
      (ws.close)()
    } else if (ws.connecting)() {
      (ws.terminate)()
    }
  }
}
