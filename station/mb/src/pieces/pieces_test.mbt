// A stream's lines put together from the pieces they come in (pieces.mbt): a line across hundreds of pieces
// whole and once, where each line ends exactly, and only what a piece brings looked through.

///|
fn piece_bytes(n : Int, f : (Int) -> Byte) -> Bytes {
  Bytes::makei(n, f)
}

///|
test "a line of 34 MB in 544 pieces of 64 KB, then lines within one piece, each whole and where it ends" {
  let p = Pieces::new()
  let piece = 64 * 1024
  let count = 544
  let ends : Array[Int64] = []
  let lines : Array[Bytes] = []
  let mut at = 0L
  let take = (bytes : Bytes) => for line in p.lines(bytes) {
    at = at + (line.length() + 1).to_int64()
    ends.push(at)
    lines.push(line)
  }
  for k in 0..<count {
    take(piece_bytes(piece, i => (32 + (k * piece + i) % 90).to_byte()))
    assert_eq(lines.length(), 0)
  }
  // (its end, and two short lines and the start of a third in the same piece)
  take(b"tail\nab\n\ncd")
  assert_eq(lines.length(), 3)
  let big = lines[0]
  assert_eq(big.length(), count * piece + 4)
  for i in [0, 1, piece - 1, piece, piece + 1, count * piece - 1] {
    assert_eq(big[i], (32 + i % 90).to_byte())
  }
  assert_eq(big[count * piece:].to_bytes(), b"tail")
  assert_eq(lines[1], b"ab")
  assert_eq(lines[2], b"")
  assert_eq(ends, [(count * piece + 5).to_int64(), (count * piece + 8).to_int64(), (count * piece + 9).to_int64()])
  assert_eq(p.size, 2)
  take(b"e\n")
  assert_eq(lines[3], b"cde")
  assert_eq(p.parts.length(), 0)
  assert_eq(p.size, 0)
}

///|
test "a newline as a piece of its own, and a piece that is only a line's end" {
  let p = Pieces::new()
  assert_eq(p.lines(b"abc"), [])
  assert_eq(p.lines(b"\n"), [b"abc"])
  assert_eq(p.lines(b"\n\n"), [b"", b""])
  assert_eq(p.lines(b"x"), [])
  assert_eq(p.lines(b"y"), [])
  assert_eq(p.lines(b"z\nw"), [b"xyz"])
  assert_eq(p.size, 1)
}

///|
test "what a runner is given to write, as base64 of it and its tail" {
  for text in ["", "a", "ab", "abc", "abcd", "say:é中😀\n", "x\n"] {
    let bytes = @utf8.encode(text)
    for tail in [b"", b"\n"] {
      let out = @buffer.new()
      @pieces.base64_into(out, bytes, tail)
      let whole = @buffer.new()
      whole.write_bytes(bytes)
      whole.write_bytes(tail)
      assert_eq(@utf8.decode(out.to_bytes()), @base64.encode(whole.to_bytes()[:]))
    }
  }
}

///|
test "a runner's base64 past one piece of it is the same as written whole" {
  for n in [49151, 49152, 49153, 49154, 147457] {
    let bytes = Bytes::makei(n, i => (i * 7).to_byte())
    for tail in [b"", b"\n"] {
      let out = Buffer()
      @pieces.base64_into(out, bytes, tail)
      let whole = Buffer()
      whole.write_bytes(bytes)
      whole.write_bytes(tail)
      assert_eq(@utf8.decode(out.to_bytes()), @base64.encode(whole.to_bytes()[:]))
    }
  }
}

///|
test "what a stream ended without its newline is taken whole, once" {
  let p = Pieces::new()
  assert_eq(p.rest(), None)
  assert_eq(p.lines(b"first\nfatal: "), [b"first"])
  assert_eq(p.lines(b"no such"), [])
  assert_eq(p.lines(b" model"), [])
  assert_eq(p.rest(), Some(b"fatal: no such model"))
  assert_eq(p.rest(), None)
  // (nothing of it left to come before what follows)
  assert_eq(p.lines(b"next\n"), [b"next"])
  assert_eq(p.rest(), None)
}
