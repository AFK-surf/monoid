// What of these parts needs no world, as station/test/adb-*.test.ts and devices.test.ts hold the TypeScript to.

///|
using @jsjson {type JValue as J}

///|
fn s(t : String) -> J {
  @session_chats.js(t)
}

///|
/// An adb packet: its command, its two arguments, its payload, its checks as adb writes them.
fn packet(command : UInt, id : UInt, payload : Bytes) -> Bytes {
  let buf = @buffer.new()
  let le = (v : UInt) => {
    buf.write_byte((v & 0xff).to_byte())
    buf.write_byte(((v >> 8) & 0xff).to_byte())
    buf.write_byte(((v >> 16) & 0xff).to_byte())
    buf.write_byte(((v >> 24) & 0xff).to_byte())
  }
  le(command)
  le(id)
  le(0)
  le(payload.length().reinterpret_as_uint())
  le(0)
  le(command.lnot())
  buf.write_bytes(payload)
  buf.to_bytes()
}

///|
fn take_all(pkg : String, chunks : Array[Bytes]) -> Array[Bool] {
  let heard = []
  let a = @adb_devices.AdbActivity::new(pkg, f => heard.push(f))
  for c in chunks {
    a.take(c)
  }
  heard
}

///|
test "a service an agent opens is use; the station's own upkeep is not" {
  let open = 0x4e45504fU
  let wrte = 0x45545257U
  let clse = 0x45534c43U
  let mine = packet(open, 1, @utf8.encode("shell:ls /sdcard\u{0}"))
  inspect(take_all("fail.still", [mine]), content="[true]")
  // (split anywhere, a byte at a time)
  let bytes = mine + packet(wrte, 1, b"x") + packet(clse, 1, b"")
  let one = Array::makei(bytes.length(), i => Bytes::makei(1, _ => bytes[i]))
  inspect(take_all("fail.still", one), content="[true, false, true]")
  let keep = packet(
    open,
    2,
    @utf8.encode(
      "shell:\{@adb_devices.keep_lending} cmd deviceidle whitelist +fail.still\u{0}",
    ),
  )
  inspect(take_all("fail.still", [keep, packet(wrte, 2, b"y")]), content="[]")
  inspect(take_all("", [keep]), content="[true]")
  let display = packet(
    open,
    3,
    @utf8.encode("shell,v2,raw:\{@adb_devices.display_mark} wm size"),
  )
  inspect(take_all("p", [display]), content="[]")
  inspect(
    take_all("p", [
      packet(open, 4, @utf8.encode("localabstract:scrcpy_0a1b2c3d")),
    ]),
    content="[]",
  )
  inspect(
    take_all("p", [
      packet(open, 4, @utf8.encode("localabstract:scrcpy_0a1b2c3")),
    ]),
    content="[true]",
  )
  // (a command of more than one line is no maintenance)
  inspect(
    take_all("p", [
      packet(open, 5, @utf8.encode("shell:\{@adb_devices.display_mark}\nls")),
    ]),
    content="[true]",
  )
  // STLS: the rest is not read.
  inspect(take_all("p", [packet(0x534c5453U, 0, b""), mine]), content="[]")
}

///|
test "a refusal as adb's client reads it" {
  inspect(@adb_devices.failure("no"), content="FAIL0002no")
  inspect(@adb_devices.failure("手机"), content="FAIL0006手机")
}

///|
test "what scrcpy and wm say" {
  inspect(
    @session_chats.stringify(
      @adb_devices.display_of(
        "[server] INFO: New display: 1080x2400/420 (id=2)\n",
      ),
    ),
    content="{\"width\":1080,\"height\":2400,\"density\":420,\"id\":2}",
  )
  inspect(
    @session_chats.stringify(
      @adb_devices.display_of("New display: 1x/2 (id=3)"),
    ),
    content="null",
  )
  inspect(
    @adb_devices.density_of("Physical density: 420\nOverride density: 360\n"),
    content="360",
  )
  inspect(@adb_devices.density_of(""), content="0")
  inspect(
    @adb_devices.size_of("Physical size: 1080x2400\nOverride size: 720x1600"),
    content="(720, 1600)",
  )
  let list = "RootTask id=7723 bounds=[0,0][1140,2616] displayId=13 userId=0\n configuration={1.0 ?? displayId=13}\nRootTask id=7720 displayId=0 userId=0\nStack id=7721 x displayId=13"
  inspect(@adb_devices.root_tasks_on(list, 13), content="[7723, 7721]")
  inspect(@adb_devices.root_tasks_on(list, 0), content="[7720]")
}

///|
test "what a phone says of itself, and a package" {
  inspect(@adb_devices.text(Some(s("Pixel\u{7}\n 9")), 80), content="Pixel 9")
  inspect(@adb_devices.text(Some(s("abcdef")), 3), content="abc")
  inspect(@adb_devices.text(Some(@session_chats.jn(1.0)), 3), content="")
  inspect(@adb_devices.is_package("fail.still_app"), content="true")
  inspect(@adb_devices.is_package("a;rm"), content="false")
  inspect(
    @adb_devices.lang_of_core(
      @session_chats.jo([("StillFail-Lang", s("en-US"))]),
    ),
    content="en",
  )
  inspect(@adb_devices.lang_of_core(@session_chats.jo([])), content="zh")
  let port = @adb_devices.usual_port("u1/" + "ab".repeat(32))
  assert_true(port >= 37000 && port < 38000)
}

///|
test "a device as it is attached" {
  inspect(
    @adb_devices.host_port("[::1]:5555"),
    content=(
      #|(::1, 5555)
    ),
  )
  inspect(
    @adb_devices.host_port("cam.local:554"),
    content=(
      #|(cam.local, 554)
    ),
  )
  let d = (kind : String, target : String) => {
    @session_chats.jo([
      ("id", s("0123456789abcdef")),
      ("name", s("cam")),
      ("kind", s(kind)),
      ("target", s(target)),
    ])
  }
  inspect(
    @adb_devices.device_refusal(d("tcp", "192.168.1.20:554")),
    content="None",
  )
  inspect(@adb_devices.device_refusal(d("tcp", "[fe80::1]:80")), content="None")
  inspect(
    @adb_devices.device_refusal(d("tcp", "nohost")),
    content=(
      #|Some(a tcp device's target is host:port)
    ),
  )
  inspect(
    @adb_devices.device_refusal(d("tcp", "h:99999")),
    content=(
      #|Some(a tcp device's port is 1 to 65535)
    ),
  )
  inspect(
    @adb_devices.device_refusal(d("usb", "a")),
    content=(
      #|Some(kind: adb, tcp or serial)
    ),
  )
  inspect(
    @adb_devices.device_refusal(d("serial", "ttyUSB0")),
    content=(
      #|Some(a serial device's target is its path (/dev/…) or COMn)
    ),
  )
  inspect(@adb_devices.device_refusal(d("serial", "COM3")), content="None")
  inspect(
    @adb_devices.device_refusal(d("adb", "a b")),
    content=(
      #|Some(target: what it is reached at, with no spaces)
    ),
  )
  inspect(
    @adb_devices.reached_at(
      @session_chats.jo([
        ("name", s("board")),
        ("kind", s("serial")),
        ("target", s("/dev/ttyUSB0")),
      ]),
      4000,
    ),
    content="board (serial /dev/ttyUSB0, 115200 baud, set raw there) is at 127.0.0.1:4000: its bytes both ways, e.g. `socat - TCP:127.0.0.1:4000` or a socket in a script. Only this chat's processes connect.",
  )
}

///|
test "what a grant tells its agent" {
  let r = @adb_devices.Req::new(
    @session_chats.jo([
      ("id", s("p1")),
      ("owner", s("pat@example.com")),
      ("status", s("granted")),
      ("scope", s("idle")),
      ("link", s("unpaired")),
    ]),
  )
  inspect(
    @adb_devices.said(r),
    content="Your request p1 to debug pat@example.com's phone was granted (until this chat has used it for nothing for an hour). Call phone_use again for how to reach it. pat@example.com's phone (your grant p1) is lent to this station, but pairing is still needed. A card under the phone request in the still.fail app on the phone shows its person how; you are told here when it connects. Do not send them to the phone's settings yourself.",
  )
  r.set("status", s("ended"))
  inspect(
    @adb_devices.said(r),
    content="Your grant p1 of pat@example.com's phone ended (ended): adb no longer reaches it.",
  )
  r.set("link", @session_chats.jn(3.0))
  inspect(
    @adb_devices.link_said(r),
    content="pat@example.com's phone (your grant p1): this station's adb holds it as 3.",
  )
}

///|
test "times as Date says them" {
  inspect(@adb_devices.iso_time(0.0), content="1970-01-01T00:00:00.000Z")
  inspect(
    @adb_devices.iso_time(1800000000123.0),
    content="2027-01-15T08:00:00.123Z",
  )
  inspect(
    @adb_devices.iso_time(951782400000.0),
    content="2000-02-29T00:00:00.000Z",
  )
}

///|
test "a chat's name" {
  inspect(
    @adb_devices.chat_title(
      @session_chats.jo([("surface", s("slack")), ("channel", s("C1"))]),
      Some("  <@U1> hi\n there"),
      None,
      "新对话",
      "私信",
    ),
    content=(
      #|hi
    ),
  )
  inspect(
    @adb_devices.chat_title(
      @session_chats.jo([("surface", s("ember"))]),
      Some("x"),
      None,
      "新对话",
      "私信",
    ),
    content="新对话",
  )
  inspect(
    @adb_devices.chat_title(
      @session_chats.jo([("surface", s("slack")), ("channel", s("D1"))]),
      None,
      None,
      "新对话",
      "私信",
    ),
    content="私信",
  )
}

///|
test "bytes in base64 and back" {
  for n in 0..<7 {
    let b = Bytes::makei(n, i => (i * 37 + 200).to_byte())
    assert_eq(@adb_devices.unb64(@adb_devices.b64(b)), b)
  }
  inspect(@adb_devices.b64(b"hi!?"), content="aGkhPw==")
}

///|
test "where adb is looked for" {
  let env = @session_chats.jo([("PATH", s("/a:/b")), ("HOME", s("/h"))])
  inspect(
    @adb_devices.adb_candidates(env, Some("/x/adb"), "adb", "/", ":"),
    content=(
      #|[/x/adb, /a/adb, /b/adb, /h/Library/Android/sdk/platform-tools/adb, /h/Android/Sdk/platform-tools/adb, /opt/homebrew/bin/adb, /usr/local/bin/adb, /usr/bin/adb]
    ),
  )
}
