///|
/// What `f` was refused with, or None.
fn refusal(f : () -> Unit raise FeishuError) -> String? {
  f() catch {
    e => return Some(error_words(e))
  }
  None
}

///|
fn data_frame(headers : Array[(String, String)], payload : Bytes) -> Frame {
  {
    seq_id: Big::of(5UL),
    log_id: Big::of(0UL),
    service: -1L,
    meth: method_data,
    headers,
    payload_encoding: None,
    payload_type: None,
    payload: Some(payload),
    log_id_new: None,
  }
}

///|
test "a frame encodes as the TypeScript's and reads back" {
  let f = data_frame([("type", "event")], b"{}")
  let bytes = encode(f)
  assert_eq(
    @codec.hex_encode(bytes),
    "0805100018ffffffffffffffffff0120012a0d0a047479706512056576656e7442027b7d",
  )
  let back = decode(bytes)
  assert_eq(back.service, -1L)
  assert_eq(back.meth, method_data)
  assert_eq(back.headers, [("type", "event")])
  assert_eq(back.payload, Some(b"{}"))
}

///|
test "bytes cut short are refused" {
  assert_true(refusal(() => ignore(decode(bytes_of_hex("2a05")))) is Some(_))
}

///|
test "a whole number keeps its low 64 bits, as BigInt.asUintN(64, …) does" {
  assert_eq(wrap64(0.0), 0L)
  assert_eq(wrap64(-7.0), -7L)
  assert_eq(wrap64(8.0), 8L)
  // 2^63 is -2^63 as an Int64's bits; 2^64 and past are their remainder
  assert_eq(wrap64(9223372036854775808.0), -9223372036854775808L)
  assert_eq(wrap64(18446744073709551616.0), 0L)
  assert_eq(wrap64(18446744073709551616.0 + 4096.0), 4096L)
  assert_eq(wrap64(-9223372036854775808.0), -9223372036854775808L)
  assert_eq(wrap64(-18446744073709551616.0 + 4096.0), 4096L)
  assert_eq(wrap64(1.0e30), 5076964154930102272L)
}

///|
test "parts come together once all are in, in their order" {
  let parts = Parts::new()
  let part = (seq : String, b : Bytes) => data_frame(
    [("type", "event"), ("message_id", "m"), ("sum", "2"), ("seq", seq)],
    b,
  )
  assert_eq(parts.add(part("1", b"cd"), 0L), None)
  assert_eq(parts.add(part("0", b"ab"), 1L), Some(b"abcd"))
  assert_eq(parts.open_count(), 0)
  // one never finished goes once old
  assert_eq(parts.add(part("0", b"ab"), 10L), None)
  parts.drop(5L)
  assert_eq(parts.open_count(), 1)
  parts.drop(11L)
  assert_eq(parts.open_count(), 0)
  // a frame not in parts is its payload
  assert_eq(parts.add(data_frame([("type", "event")], b"x"), 0L), Some(b"x"))
}

///|
test "a count of parts no array can have is refused as JavaScript refuses it" {
  let parts = Parts::new()
  let odd = data_frame([("type", "event"), ("sum", "1.5")], b"")
  assert_eq(
    refusal(() => ignore(parts.add(odd, 0L))),
    Some("Invalid array length"),
  )
}

///|
test "a ping with a service no BigInt can be is refused as JavaScript refuses it" {
  assert_eq(
    refusal(() => ignore(ping_frame(1.5))),
    Some(
      "The number 1.5 cannot be converted to a BigInt because it is not an integer",
    ),
  )
  let ping = decode(ping_frame(-7.0))
  assert_eq(ping.service, -7L)
  assert_eq(ping.meth, method_control)
  assert_eq(ping.headers, [("type", "ping")])
}
