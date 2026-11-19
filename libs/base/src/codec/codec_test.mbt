// Base64 and Base64URL against RFC 4648 §10's vectors and node's Buffer, each decoder's forms taken and refused;
// hex both ways in both cases; CRC-32 against its check value and taken a piece at a time. On both targets.

///|
let rfc4648 : Array[(Bytes, String)] = [
  (b"", ""),
  (b"f", "Zg=="),
  (b"fo", "Zm8="),
  (b"foo", "Zm9v"),
  (b"foob", "Zm9vYg=="),
  (b"fooba", "Zm9vYmE="),
  (b"foobar", "Zm9vYmFy"),
]

///|
test "base64 writes RFC 4648's vectors, and every decoder reads them back" {
  for one in rfc4648 {
    let (data, text) = one
    assert_eq(@codec.base64_encode(data), text)
    assert_eq(@codec.base64_decode(text), Some(data))
    assert_eq(@codec.base64_decode_strict(text), Some(data))
    // No `+` or `/` in these: the URL-safe form is the same text without its padding, read padded or not.
    let bare = text.trim_end(chars="=").to_owned()
    assert_eq(@codec.base64url_encode(data), bare)
    assert_eq(@codec.base64url_decode(bare), Some(data))
    assert_eq(@codec.base64url_decode(text), Some(data))
    assert_eq(@codec.base64_decode(bare), Some(data))
  }
}

///|
test "the two alphabets differ at 62 and 63, as node's Buffer writes them" {
  assert_eq(@codec.base64_encode(b"\xfb\xff\xbf"), "+/+/")
  assert_eq(@codec.base64url_encode(b"\xfb\xff\xbf"), "-_-_")
  assert_eq(@codec.base64_encode(b"\xfb\xff"), "+/8=")
  assert_eq(@codec.base64url_encode(b"\xfb\xff"), "-_8")
  assert_eq(@codec.base64url_encode(b"\xfb"), "-w")
  assert_eq(@codec.base64_decode("+/+/"), Some(b"\xfb\xff\xbf"))
  assert_eq(@codec.base64_decode("-_-_"), Some(b"\xfb\xff\xbf"))
  assert_eq(@codec.base64_decode("-_8"), Some(b"\xfb\xff"))
  assert_eq(@codec.base64_decode_strict("+/8="), Some(b"\xfb\xff"))
  assert_eq(@codec.base64_decode_strict("-_8="), None)
  assert_eq(@codec.base64url_decode("-_8"), Some(b"\xfb\xff"))
  assert_eq(@codec.base64url_decode("+/8="), None)
}

///|
test "every byte value and length round-trips through each form" {
  let all = Bytes::makei(256, i => i.to_byte())
  for n in 0..=256 {
    let data = all[0:n]
    let want = Some(data.to_owned())
    assert_eq(@codec.base64_decode(@codec.base64_encode(data)), want)
    assert_eq(@codec.base64_decode_strict(@codec.base64_encode(data)), want)
    assert_eq(@codec.base64url_decode(@codec.base64url_encode(data)), want)
    assert_eq(@codec.base64_decode(@codec.base64url_encode(data)), want)
    assert_eq(@codec.hex_decode(@codec.hex_encode(data)), want)
    assert_eq(@codec.hex_decode(@codec.hex_encode_upper(data)), want)
  }
}

///|
test "the lenient decoder leaves ASCII space out and takes padding or none" {
  assert_eq(@codec.base64_decode(" Zm9v\r\nYmFy\t"), Some(b"foobar"))
  assert_eq(@codec.base64_decode("Zm9vYg"), Some(b"foob"))
  assert_eq(@codec.base64_decode("Zm9vYg =\n="), Some(b"foob"))
  // Bits past the last byte are not looked at (`Zh` is `f` with a bit set past it), as node reads them.
  assert_eq(@codec.base64_decode("Zh"), Some(b"f"))
}

///|
test "each decoder refuses what is not its form" {
  // Anything outside the alphabets, padding before the end or more or less of it than makes four, a lone digit.
  for text in ["Zm9v!", "Zm9v\u{e9}", "Zg==Zg==", "Zg=", "Zg===", "Zm8==", "Z", "Zm9vY", "Zm9vY===", "="] {
    assert_eq(@codec.base64_decode(text), None)
    assert_eq(@codec.base64_decode_strict(text), None)
    assert_eq(@codec.base64url_decode(text), None)
  }
  // The strict reader: no padding left out, no space, no bits past the last byte, no URL-safe digit.
  for text in ["Zg", "Zm8", "Zm9v Yg==", "Zm9v\nYmFy", "Zh==", "Zm9=", "Zm9vYm-y"] {
    assert_eq(@codec.base64_decode_strict(text), None)
  }
  // The URL-safe reader: no space, no `+` or `/`.
  assert_eq(@codec.base64url_decode("Zm9v Ymfy"), None)
  assert_eq(@codec.base64url_decode("Zm9vYm+y"), None)
  assert_eq(@codec.base64url_decode("Zm9vYm/y"), None)
}

///|
test "hex writes either case and reads both, refusing odd lengths and other characters" {
  assert_eq(@codec.hex_encode(b""), "")
  assert_eq(@codec.hex_encode(b"\x00\x01\x7f\x80\xab\xff"), "00017f80abff")
  assert_eq(@codec.hex_encode_upper(b"\x00\x01\x7f\x80\xab\xff"), "00017F80ABFF")
  assert_eq(@codec.hex_decode("00017f80ABff"), Some(b"\x00\x01\x7f\x80\xab\xff"))
  assert_eq(@codec.hex_decode(""), Some(b""))
  assert_eq(@codec.hex_decode("abc"), None)
  assert_eq(@codec.hex_decode("0g"), None)
  assert_eq(@codec.hex_decode("0x00"), None)
  assert_eq(@codec.hex_decode(" 00"), None)
  assert_eq(@codec.hex_encode(b"\xde\xad\xbe\xef"), @hash.hex_encode(b"\xde\xad\xbe\xef"))
}

///|
test "hex_digit is a digit's worth in either case, and nothing else's" {
  assert_eq(@codec.hex_digit('0'.to_int()), Some(0))
  assert_eq(@codec.hex_digit('9'.to_int()), Some(9))
  assert_eq(@codec.hex_digit('a'.to_int()), Some(10))
  assert_eq(@codec.hex_digit('F'.to_int()), Some(15))
  for c in ['/', ':', '@', 'G', '`', 'g', ' '] {
    assert_eq(@codec.hex_digit(c.to_int()), None)
  }
  assert_eq(@codec.hex_digit(-1), None)
  assert_eq(@codec.hex_digit(0x660), None)
}

///|
test "crc32 gives the IEEE check values" {
  assert_eq(@codec.crc32(b""), 0U)
  assert_eq(@codec.crc32(b"123456789"), 0xCBF43926U)
  assert_eq(@codec.crc32(b"The quick brown fox jumps over the lazy dog"), 0x414FA339U)
  assert_eq(@codec.crc32(b"a"), 0xE8B7BE43U)
}

///|
test "crc32 taken a piece at a time is crc32 taken at once, whatever the pieces" {
  let data = Bytes::makei(1000, i => (i * 7 + 3).to_byte())
  let whole = @codec.crc32(data)
  for cut in [0, 1, 3, 499, 999, 1000] {
    assert_eq(@codec.crc32_update(@codec.crc32(data[0:cut]), data[cut:]), whole)
  }
  let mut crc = 0U
  for i in 0..<data.length() {
    crc = @codec.crc32_update(crc, data[i:i + 1])
  }
  assert_eq(crc, whole)
  assert_eq(@codec.crc32_update(whole, b""), whole)
}

///|
test "base64_decode_loose matches Node Buffer.from base64/base64url leniency" {
  assert_eq(@codec.base64_decode_loose("SGVsbG8="), b"Hello")
  assert_eq(@codec.base64_decode_loose("SGVs!bG8?==ignored"), b"Hello")
  assert_eq(@codec.base64_decode_loose("-_8="), b"\xfb\xff")
  assert_eq(@codec.base64_decode_loose("A"), b"")
  assert_eq(@codec.base64_decode_loose("SGVsbG8A"), b"Hello\x00")
  assert_eq(@codec.base64_decode_loose("SGVsbA"), b"Hell")
  assert_eq(@codec.base64_decode_loose("SGVsb"), b"Hel")
  // lone surrogates are ignored without aborting on native or js
  let lone = String::from_array(['S', 'G', 'V', 's', Int::unsafe_to_char(0xD800), 'b', 'G', '8', '='])
  assert_eq(@codec.base64_decode_loose(lone), b"Hello")
}
