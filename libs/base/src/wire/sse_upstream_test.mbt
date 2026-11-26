// Upstream WPT `eventsource/format-*.htm` official parsing vectors for `@wire.Sse`.
//
// Intentional subset alignment with `client/core-ts/src/sse.ts` (enforced byte-for-byte by
// `scripts/mb-base-sse.ts --check`):
// - CR (0x0D) bytes are stripped before line splitting (LF and CRLF work identically; bare CR alone
//   is not treated as a line break, unlike full WHATWG SSE).
// - Only `data:`, `event:`, and `id:` fields are interpreted (`retry:`, `:` comments, unknown fields,
//   and colon-less lines like bare `data` are ignored).
// - `event:` and `id:` values are JS-trimmed (`String.prototype.trim`) and `id:` does not reject NUL;
//   an `id:`-only block with no `data:` emits `{ name: "", data: "", id: Some(id) }` for log cursors,
//   and `id` is not persisted across subsequent blocks without `id:`.
// - UTF-8 BOM (EF BB BF) is stripped at the head of each block (`ignore_bom=true`, matching
//   `new TextDecoder().decode(block)`).

///|
fn wpt_feed(raw : Bytes) -> Array[(String, String, String?)] raise @wire.TooLong {
  let s = @wire.Sse::new()
  s.feed(raw).map(e => (e.name, e.data, e.id))
}

///|
fn wpt_feed_step(raw : Bytes, step : Int) -> Array[(String, String, String?)] raise @wire.TooLong {
  let s = @wire.Sse::new()
  let out : Array[(String, String, String?)] = []
  let mut i = 0
  while i < raw.length() {
    let end = if i + step < raw.length() { i + step } else { raw.length() }
    for ev in s.feed(raw[i:end].to_owned()) {
      out.push((ev.name, ev.data, ev.id))
    }
    i = end
  }
  out
}

///|
fn assert_wpt(raw : Bytes, want : Array[(String, String, String?)]) -> Unit raise {
  assert_eq(wpt_feed(raw), want)
  assert_eq(wpt_feed_step(raw, 1), want)
  assert_eq(wpt_feed_step(raw, 3), want)
}

///|
test "wpt eventsource: format-bom and format-bom-2 (single and double UTF-8 BOM)" {
  // format-bom.htm: single UTF-8 BOM before first event is stripped
  assert_wpt(
    b"\xef\xbb\xbfdata:1\n\ndata:2\n\ndata:3\n\n",
    [("message", "1", None), ("message", "2", None), ("message", "3", None)],
  )
  // format-bom-2.htm: double UTF-8 BOM -> first BOM stripped, second BOM remains in field name
  // so first line becomes "\uFEFFdata:1" (ignored), subsequent blocks still parse
  assert_wpt(
    b"\xef\xbb\xbf\xef\xbb\xbfdata:1\n\ndata:2\n\ndata:3\n\n",
    [("message", "2", None), ("message", "3", None)],
  )
}

///|
test "wpt eventsource: format-comments (leading colon comments, long comments, mixed with data)" {
  let long_comment = Bytes::make(2050, b'x')
  let buf = Buffer()
  buf.write_bytesview(b"data:1\n:")
  buf.write_bytesview(long_comment)
  buf.write_bytesview(b"\n:comment\ndata:2\n\n:comment only\n\ndata:3\n\n")
  assert_wpt(
    buf.to_bytes(),
    [("message", "1\n2", None), ("message", "3", None)],
  )
}

///|
test "wpt eventsource: format-data-before-final-empty-line (unterminated trailing block not dispatched)" {
  assert_wpt(
    b"retry:1000\ndata:test1\n\nid:test\ndata:test2",
    [("message", "test1", None)],
  )
}

///|
test "wpt eventsource: format-field-data (multi-line data, empty data, colon in value)" {
  assert_wpt(
    b"data:\n\ndata\ndata\n\ndata:test\n\ndata: a:b:c\n\n",
    [("message", "", None), ("message", "test", None), ("message", "a:b:c", None)],
  )
  // Multiple data lines joined with LF; empty data: lines preserve blank lines
  assert_wpt(
    b"data: first\ndata:\ndata: third\n\n",
    [("message", "first\n\nthird", None)],
  )
}

///|
test "wpt eventsource: format-field-event and format-field-event-empty" {
  // Custom event names, overridden event name in same block, reset to "message" in next block
  assert_wpt(
    b"event: test\ndata: x\n\ndata: y\n\n",
    [("test", "x", None), ("message", "y", None)],
  )
  // format-field-event-empty: empty event: sets name to "" (core-ts alignment)
  assert_wpt(
    b"event: \ndata: data\n\nevent:\ndata: data2\n\n",
    [("", "data", None), ("", "data2", None)],
  )
  // Space-only and tab-trimmed event names
  assert_wpt(
    b"event:  custom \t\ndata: v\n\n",
    [("custom", "v", None)],
  )
}

///|
test "wpt eventsource: format-field-id, id-2, id-3, id-null (core-ts subset contract)" {
  // id with data
  assert_wpt(
    b"id: 1\ndata: one\n\ndata: two\n\n",
    [("message", "one", Some("1")), ("message", "two", None)],
  )
  // id-only block emits ("", "", Some(id)) for cursor tracking
  assert_wpt(
    b"id: cursor-42\n\nid:\n\n",
    [("", "", Some("cursor-42")), ("", "", Some(""))],
  )
  // id with NUL byte: core-ts keeps NUL in trimmed id rather than rejecting
  assert_wpt(
    b"id: a\x00b\ndata: ok\n\n",
    [("message", "ok", Some("a\u{0000}b"))],
  )
}

///|
test "wpt eventsource: format-field-parsing, unknown, retry, retry-bogus, retry-empty" {
  // Unknown fields, case-sensitive field names (DATA:, Event:, ID:), retry variants are ignored
  let raw = b"DATA: upper\nEvent: cap\nID: 9\nretry: 500\nretry: 1000x\nretry:\nfoo: bar\n: ignored\ndata: kept\n\n"
  assert_wpt(raw, [("message", "kept", None)])
  // Field name with leading space is NOT a valid field
  assert_wpt(b" data: nope\ndata: yes\n\n", [("message", "yes", None)])
}

///|
test "wpt eventsource: format-leading-space (at most one U+0020 stripped after data:)" {
  assert_wpt(
    b"data:\t\ndata: \ndata:  \ndata:   abc\ndata:\tdef\n\n",
    [("message", "\t\n\n \n  abc\n\tdef", None)],
  )
}

///|
test "wpt eventsource: format-newlines (LF, CRLF, mixed endings, bare CR stripped per core-ts)" {
  // LF and CRLF produce identical blocks
  assert_wpt(
    b"data: test\r\n\r\ndata: test2\n\ndata: test3\r\n\n",
    [("message", "test", None), ("message", "test2", None), ("message", "test3", None)],
  )
  // Bare CR is stripped (intentional core-ts contract: JSON payloads escape CR)
  assert_wpt(
    b"data: a\rb\n\n",
    [("message", "ab", None)],
  )
}

///|
test "wpt eventsource: format-null-character and format-utf-8" {
  // NUL inside data value is preserved verbatim
  assert_wpt(
    b"data: a\x00b\n\n",
    [("message", "a\u{0000}b", None)],
  )
  // Multi-byte UTF-8 (BMP + astral planes + CJK + emoji) split at every 1-byte and 3-byte offset
  let utf8_stream = @utf8.encode(
    "event: \u{00E9}v\u{00E9}nement\nid: \u{4E2D}\u{6587}-1\ndata: ok \u{2026} \u{1F680}\ndata: \u{03B1}\u{03B2}\u{03B3}\n\n",
  )
  assert_wpt(
    utf8_stream,
    [("\u{00E9}v\u{00E9}nement", "ok \u{2026} \u{1F680}\n\u{03B1}\u{03B2}\u{03B3}", Some("\u{4E2D}\u{6587}-1"))],
  )
  // Invalid UTF-8 sequences decode lossily to U+FFFD without panicking
  let evs = wpt_feed(b"data: \x80\xc0\xfe\xff\n\n")
  assert_eq(evs.length(), 1)
  assert_true(evs[0].1.contains("\u{FFFD}"))
}
