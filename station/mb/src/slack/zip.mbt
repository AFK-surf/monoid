// zip.ts: a file Slack Connect will not take, put in a zip archive of its own so it can be shared there all the same.
//
// In a channel shared with another organization Slack refuses installers and executables (`.apk`, `.exe`, …) with
// `slack_connect_blocked_file_type`, and only once their bytes were uploaded and the share is completed. A zip of the
// one file is taken: its entry stored as it is (method 0), its CRC-32 (IEEE 802.3, as zlib's) computed here, the
// archive byte for byte the one zip.ts `zipOne` makes (no clock: the same file makes the same archive).

///|
/// What Slack Connect refuses to share, by the name's last extension (any case): installers and executables.
let connect_blocked_exts : Array[String] = [
  "apk", "aab", "exe", "msi", "bat", "cmd", "com", "scr", "dmg", "pkg",
]

///|
/// zip.ts `connectBlocked`: whether Slack Connect would refuse a file of this name.
pub fn connect_blocked(name : String) -> Bool {
  match name.rev_find(".") {
    Some(dot) if dot > 0 =>
      connect_blocked_exts.contains(
        name.clamped_view(start=dot + 1).to_owned().to_lower(),
      )
    _ => false
  }
}

///|
/// The name a file goes by inside its archive: its own, without any folder.
fn zip_entry_name(name : String) -> String {
  let slash = name.rev_find("/").unwrap_or(-1)
  let back = name.rev_find("\\").unwrap_or(-1)
  let from = (if slash > back { slash } else { back }) + 1
  let s = name.clamped_view(start=from).to_owned()
  if s == "" {
    "file"
  } else {
    s
  }
}

///|
/// The CRC-32 of `bytes` (the one gzip's trailer and zip's headers carry).
pub fn crc32(bytes : Bytes) -> UInt {
  @codec.crc32(bytes[:])
}

///|
fn zip_u16(buf : @buffer.Buffer, v : Int) -> Unit {
  buf.write_byte((v & 0xff).to_byte())
  buf.write_byte(((v >> 8) & 0xff).to_byte())
}

///|
fn zip_u32(buf : @buffer.Buffer, v : UInt) -> Unit {
  buf.write_byte((v & 0xffU).reinterpret_as_int().to_byte())
  buf.write_byte(((v >> 8) & 0xffU).reinterpret_as_int().to_byte())
  buf.write_byte(((v >> 16) & 0xffU).reinterpret_as_int().to_byte())
  buf.write_byte(((v >> 24) & 0xffU).reinterpret_as_int().to_byte())
}

///|
/// zip.ts `zipOne`: a zip archive of one file, `name` its entry, its bytes stored. Over 4 GiB is not one.
pub fn zip_one(name : String, bytes : Bytes) -> Bytes raise {
  if bytes.length().to_int64() > 0xfffffffeL {
    raise fail_("\{name}: too large to put in a zip archive")
  }
  let crc = crc32(bytes)
  let path = @utf8.encode(zip_entry_name(name))
  let plen = path.length()
  let size = bytes.length().reinterpret_as_uint()
  let buf = @buffer.Buffer(size_hint=bytes.length() + 98 + plen * 2)
  // Local file header (30 bytes and the name)
  zip_u32(buf, 0x04034b50U)
  zip_u16(buf, 20) // version needed: 2.0
  zip_u16(buf, 0x0800) // the name is UTF-8
  zip_u16(buf, 0) // stored
  zip_u16(buf, 0) // time: 00:00:00
  zip_u16(buf, 0x21) // date: 1980-01-01
  zip_u32(buf, crc)
  zip_u32(buf, size)
  zip_u32(buf, size)
  zip_u16(buf, plen)
  zip_u16(buf, 0)
  buf.write_bytes(path)
  buf.write_bytes(bytes)
  // The central directory's one entry (46 and the name)
  zip_u32(buf, 0x02014b50U)
  zip_u16(buf, 20) // made by: 2.0
  zip_u16(buf, 20)
  zip_u16(buf, 0x0800)
  zip_u16(buf, 0)
  zip_u16(buf, 0)
  zip_u16(buf, 0x21)
  zip_u32(buf, crc)
  zip_u32(buf, size)
  zip_u32(buf, size)
  zip_u16(buf, plen)
  for _ in 0..<16 {
    buf.write_byte(b'\x00') // extra, comment, disk, attributes, its local header at 0
  }
  buf.write_bytes(path)
  // Its end (22)
  zip_u32(buf, 0x06054b50U)
  zip_u16(buf, 0)
  zip_u16(buf, 0)
  zip_u16(buf, 1)
  zip_u16(buf, 1)
  zip_u32(buf, (46 + plen).reinterpret_as_uint())
  zip_u32(buf, (30 + plen).reinterpret_as_uint() + size)
  zip_u16(buf, 0)
  buf.to_bytes()
}
