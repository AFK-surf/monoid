// adb/activity.ts: adb's unencrypted transport (the phone's own adb session) observed without keeping its contents.
// A station's adb server holds one connection while many commands run over it. A connection or its CNXN is not use:
// OPEN starts a service; WRTE/OKAY on that service show a long-running one still in use. The two services the station
// opens itself to keep lending enabled are excluded. An older phone's STLS makes the rest unread, so stop observing.

///|
let a_open : UInt = 0x4e45504f

///|
let a_wrte : UInt = 0x45545257

///|
let a_okay : UInt = 0x59414b4f

///|
let a_clse : UInt = 0x45534c43

///|
let a_stls : UInt = 0x534c5453

///|
let a_header : Int = 24

///|
let max_payload : UInt = 16U * 1024U * 1024U

///|
let max_service : UInt = 8192U

///|
/// Our own maintenance marked, so the same command run by an agent still counts as use.
pub let keep_lending : String = "STILLFAIL_ADB_KEEP=1"

///|
/// adbd's plain port the app falls back to off Wi-Fi (link `keep_tcp`), and what the station asks of it first.
pub let tcp_port : Int = 5555

///|
pub let keep_tcp_command : String = "\{keep_lending} sh -c 'cat /proc/sys/kernel/random/boot_id; getprop service.adb.tcp.port'"

///|
/// A command of the station's about the chat's display (displays), marked so.
pub let display_mark : String = "\{keep_lending} STILLFAIL_ADB_DISPLAY=1"

///|
fn display_command(command : String) -> Bool {
  command.has_prefix("\{display_mark} ")
}

///|
pub struct AdbActivity {
  pkg : String
  used : (Bool) -> Unit
  header : FixedArray[Byte]
  active : Set[UInt]
  mut header_bytes : Int
  mut remaining : UInt
  mut service : FixedArray[Byte]?
  mut service_bytes : Int
  mut service_id : UInt
  mut unread : Bool
}

///|
pub fn AdbActivity::new(pkg : String, used : (Bool) -> Unit) -> AdbActivity {
  {
    pkg,
    used,
    header: FixedArray::make(a_header, b'\x00'),
    active: Set::new(),
    header_bytes: 0,
    remaining: 0,
    service: None,
    service_bytes: 0,
    service_id: 0,
    unread: false,
  }
}

///|
fn u32le(b : FixedArray[Byte], at : Int) -> UInt {
  b[at].to_uint() |
  (b[at + 1].to_uint() << 8) |
  (b[at + 2].to_uint() << 16) |
  (b[at + 3].to_uint() << 24)
}

///|
/// The bytes sent by this grant's adb server. They are passed through unchanged by the caller.
pub fn AdbActivity::take(self : AdbActivity, bytes : BytesView) -> Unit {
  let mut at = 0
  while at < bytes.length() && !self.unread {
    if self.remaining > 0 {
      let left = bytes.length() - at
      let n = @cmp.minimum(self.remaining.reinterpret_as_int(), left)
      match self.service {
        Some(s) => {
          for i in 0..<n {
            s[self.service_bytes + i] = bytes[at + i]
          }
          self.service_bytes += n
        }
        None => ()
      }
      self.remaining -= n.reinterpret_as_uint()
      at += n
      if self.remaining == 0 {
        self.opened()
      }
      continue
    }
    let n = @cmp.minimum(a_header - self.header_bytes, bytes.length() - at)
    for i in 0..<n {
      self.header[self.header_bytes + i] = bytes[at + i]
    }
    self.header_bytes += n
    at += n
    if self.header_bytes < a_header {
      continue
    }
    self.header_bytes = 0
    let command = u32le(self.header, 0)
    let id = u32le(self.header, 4)
    let size = u32le(self.header, 12)
    if u32le(self.header, 20) != command.lnot() ||
      size > max_payload ||
      command == a_stls {
      self.unread = true
      continue
    }
    self.remaining = size
    if command == a_open {
      self.service_id = id
      self.service_bytes = 0
      if size <= max_service {
        self.service = Some(
          FixedArray::make(size.reinterpret_as_int(), b'\x00'),
        )
      } else {
        // An unusually long service cannot be either of our two maintenance commands.
        self.active.add(id)
        (self.used)(true)
      }
      if size == 0 {
        self.opened()
      }
    } else if self.active.contains(id) {
      if command == a_clse {
        self.active.remove(id)
        (self.used)(true)
      } else if command == a_wrte || command == a_okay {
        (self.used)(false)
      }
    }
  }
}

///|
/// `buffer.toString("utf8")`: UTF-8, what does not decode as U+FFFD.
pub fn utf8_lossy(b : BytesView) -> String {
  @utf8.decode_lossy(b)
}

///|
fn AdbActivity::opened(self : AdbActivity) -> Unit {
  guard self.service is Some(s) else { return }
  let bytes = Bytes::makei(s.length(), i => s[i])
  let mut service = utf8_lossy(bytes)
  // (`.replace(/\0+$/, "")`)
  while service.has_suffix("\u{0}") {
    service = js_slice(service, 0, b=service.length() - 1)
  }
  self.service = None
  let command : String? = if service.has_prefix("shell") {
    let rest = js_slice(service, 5)
    if rest.has_prefix(":") {
      Some(js_slice(rest, 1))
    } else if rest.has_prefix(",") {
      match rest.find(":") {
        Some(c) => Some(js_slice(rest, c + 1))
        None => None
      }
    } else {
      None
    }
  } else {
    None
  }
  // (`(.*)$` reads no line's end)
  let command = match command {
    Some(c) if c
      .iter()
      .any(ch => {
        ch == '\n' || ch == '\r' || ch == '\u{2028}' || ch == '\u{2029}'
      }) => None
    c => c
  }
  let pkg = self.pkg
  let said = (c : String) => command is Some(x) && x == c
  let ours = (
      pkg != "" &&
      (
        said(
          "\{keep_lending} pm grant \{pkg} android.permission.WRITE_SECURE_SETTINGS",
        ) ||
        said("\{keep_lending} cmd deviceidle whitelist +\{pkg}")
      )
    ) ||
    said(keep_tcp_command) ||
    service == "tcpip:\{tcp_port}" ||
    // The chat's display (displays): what holds it up and what the station asks of it, and its pictures' socket.
    (command is Some(c) && display_command(c)) ||
    scrcpy_socket(service)
  if ours {
    return
  }
  self.active.add(self.service_id)
  (self.used)(true)
}

///|
/// `/^localabstract:scrcpy_[0-9a-f]{8}$/`.
fn scrcpy_socket(service : String) -> Bool {
  let head = "localabstract:scrcpy_"
  guard service.has_prefix(head) && service.length() == head.length() + 8 else {
    return false
  }
  js_slice(service, head.length())
  .iter()
  .all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
}
