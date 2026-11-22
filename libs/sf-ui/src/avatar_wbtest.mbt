///|
test "a person's colour as Android's avatarColor picks it: Java's hashCode of their id lowered, floorMod" {
  // "a": 97, the second
  assert_eq(avatar_color("a"), 0x248753FFL)
  assert_eq(avatar_color("A"), avatar_color("a"))
  // Java's int wraps to -2147483648 here: floorMod 6 is 4, the fifth
  assert_eq(avatar_color("polygenelubricants"), 0x32818DFFL)
}

///|
test "a picture picked as one's own: made a square face_picture_px across whatever its shape, a JPEG as a data URL" {
  for side in [(8, 4), (3, 9), (5, 5)] {
    let (w, h) = side
    let url = face_picture(w, h, FixedArray::make(w * h * 4, b'\xFF'))
    let head = "data:image/jpeg;base64,"
    assert_true(url.has_prefix(head), msg="\{Repr(side)}")
    let jpeg = @codec.from_base64(url.unsafe_substring(start=head.length(), end=url.length()))
    assert_eq(@pixels.image_size(jpeg), Some((face_picture_px, face_picture_px)), msg="\{Repr(side)}")
  }
}

///|
test "a name's initial: its first letter upper case, ? for none" {
  assert_eq(initial("  lin"), "L")
  assert_eq(initial("林"), "林")
  assert_eq(initial(" "), "?")
}
