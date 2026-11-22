// EventSource / SSE conformance tests for @wire.Sse.
// Contract note: libs/base/src/wire/sse.mbt is contractually locked byte-for-byte to
// client/core-ts/src/sse.ts (enforced by scripts/mb-base-sse.ts --check), plus the
// `TooLong` block-size bound. Specifically:
//   - CR (0x0D) bytes are stripped (LF and CRLF supported; bare CR-only is not a line break).
//   - UTF-8 BOM at the head of a block is ignored (`ignore_bom=true`, matching TextDecoder).
//   - Only `data:`, `event:`, `id:` fields are interpreted; `:` comments, `retry:`, and
//     colon-less field names are ignored; `id:` is JS-trimmed and does not reject NUL.
//   - A block with `id:` and no `data:` emits `{ name: "", data: "", id: Some(id) }`.

///|
fn ev_tuples(evs : Array[@wire.Event]) -> Array[(String, String, String?)] {
  evs.map(e => (e.name, e.data, e.id))
}

///|
fn assert_events(got : Array[@wire.Event], want : Array[(String, String, String?)]) -> Unit raise {
  assert_eq(ev_tuples(got), want)
}

///|
fn feed_all(raw : Bytes) -> Array[@wire.Event] raise @wire.TooLong {
  let sse = @wire.Sse::new()
  sse.feed(raw)
}

///|
fn feed_by_bytes(raw : Bytes, step : Int) -> Array[@wire.Event] raise @wire.TooLong {
  let sse = @wire.Sse::new()
  let out : Array[@wire.Event] = []
  let mut i = 0
  while i < raw.length() {
    let end = if i + step < raw.length() { i + step } else { raw.length() }
    for ev in sse.feed(raw[i:end].to_owned()) {
      out.push(ev)
    }
    i = end
  }
  out
}

///|
test "conformance: BOM stripping at stream and block head" {
  // UTF-8 BOM (EF BB BF) before first field is stripped so `data:` is recognized
  let raw = b"\xef\xbb\xbfdata: hello\n\n"
  let want : Array[(String, String, String?)] = [("message", "hello", None)]
  assert_events(feed_all(raw), want)
  // Byte-by-byte split across the 3 BOM bytes
  assert_events(feed_by_bytes(raw, 1), want)
  // BOM before event: line
  let raw2 = b"\xef\xbb\xbfevent: ping\ndata: ok\n\n"
  assert_events(feed_all(raw2), [("ping", "ok", None)])
}

///|
test "conformance: LF and CRLF mixed endings and single-byte split inside CRLF" {
  let raw = b"event: mix\r\ndata: line1\ndata: line2\r\n\r\ndata: second\n\r\n"
  let want : Array[(String, String, String?)] = [
    ("mix", "line1\nline2", None),
    ("message", "second", None),
  ]
  assert_events(feed_all(raw), want)
  // Split at every 1, 2, 3 bytes (hits right between \r and \n, and between the two \n's)
  for step in [1, 2, 3, 5] {
    assert_events(feed_by_bytes(raw, step), want)
  }
}

///|
test "conformance: multi-line data joining, empty data, and single leading space rule" {
  // At most ONE leading space after `data:` is removed; tabs and additional spaces are kept
  let raw = b"data:\ndata: \ndata:  two\ndata:\ttab\ndata:no-space\n\n"
  let want : Array[(String, String, String?)] = [
    ("message", "\n\n two\n\ttab\nno-space", None),
  ]
  assert_events(feed_all(raw), want)
  assert_events(feed_by_bytes(raw, 1), want)
  // Empty data: alone still dispatches an event with data == ""
  assert_events(feed_all(b"data:\n\n"), [("message", "", None)])
  assert_events(feed_all(b"data: \n\n"), [("message", "", None)])
}

///|
test "conformance: comments, unknown fields, retry, and colon-less lines ignored" {
  let raw = b": keepalive comment\n: another comment\nretry: 3000\nretry: abc\nfoo: bar\ndata\nevent\nid\n\n: comment before real\ndata: real\n\n"
  let want : Array[(String, String, String?)] = [("message", "real", None)]
  assert_events(feed_all(raw), want)
  assert_events(feed_by_bytes(raw, 1), want)
}

///|
test "conformance: event name, id trimming, repeated fields, and id-only blocks" {
  // Last event: and last id: in a block win; JS whitespace trimmed on event: and id:
  let raw = b"event: first\nevent:  second \t\nid: 1\nid:  42 \ndata: body\n\n"
  assert_events(feed_all(raw), [("second", "body", Some("42"))])
  // Blank event: sets name to ""
  assert_events(feed_all(b"event:\ndata: x\n\n"), [("", "x", None)])
  // id-only block (no data:) emits ("", "", Some(id)) per core-ts/src/sse.ts contract
  assert_events(feed_all(b"id: cursor-99\n\n"), [("", "", Some("cursor-99"))])
  // Blank blocks produce no events
  assert_events(feed_all(b"\n\n\n\n"), [])
}

///|
test "conformance: UTF-8 multi-byte characters split across arbitrary chunk boundaries" {
  // 2-byte (é), 3-byte (中), 4-byte (🚀) across field values
  let raw = @utf8.encode("event: café\nid: 编号-1\ndata: 你好 🚀\ndata: 世界\n\n")
  let want : Array[(String, String, String?)] = [
    ("café", "你好 🚀\n世界", Some("编号-1")),
  ]
  assert_events(feed_all(raw), want)
  for step in [1, 2, 3, 4, 7] {
    assert_events(feed_by_bytes(raw, step), want)
  }
  // Invalid UTF-8 bytes are decoded lossily to U+FFFD without crashing
  let bad = b"data: a\xff\xfeb\n\n"
  let evs = feed_all(bad)
  assert_eq(evs.length(), 1)
  assert_true(evs[0].data.contains("\u{FFFD}"))
}

///|
test "conformance: TooLong bound enforced across chunked feeds and sticky after failure" {
  let sse = @wire.Sse::new(most=16)
  // Exact bound: "data: 1234567890" is 16 bytes, followed by "\n\n" -> accepted
  assert_events(sse.feed(b"data: 1234567890\n\n"), [("message", "1234567890", None)])
  // Preceding valid event is delivered, then next feed raises TooLong for the oversized block
  let sse2 = @wire.Sse::new(most=10)
  let first = sse2.feed(b"data: ok\n\ndata: 12345678901234567890\n\n")
  assert_events(first, [("message", "ok", None)])
  let failed = try {
    let _ = sse2.feed(b"data: after\n\n")
    false
  } catch {
    @wire.TooLong(most=10) => true
    _ => false
  }
  assert_true(failed)
  // Once over, subsequent feeds keep raising TooLong
  let sticky = try {
    let _ = sse2.feed(b"")
    false
  } catch {
    @wire.TooLong(most=10) => true
    _ => false
  }
  assert_true(sticky)
}
