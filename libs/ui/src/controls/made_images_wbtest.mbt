// The pictures made here from their keys (made_images.mbt) are let go of beyond a count, the least lately asked for
// first, and made again as they are asked for again.

///|
/// A run of its own: a window with nothing in it, no image handed over.
fn made_run() -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=0)
  t.check_looks(false)
  t.draw()
  t
}

///|
test "gradients made beyond 64 let go of the least lately asked for, which is made again as it is asked for" {
  made_run() |> ignore
  let first = gradient_key(100.0, 50.0, 90.0, 0x000000FFL, 0xFFFFFFFFL)
  let second = gradient_key(100.0, 50.0, 90.0, 0x000001FFL, 0xFFFFFFFFL)
  assert_true(@ui.has_image(first))
  // (the first asked for again: the second is now the least lately asked for)
  gradient_key(100.0, 50.0, 90.0, 0x000000FFL, 0xFFFFFFFFL) |> ignore
  let keys = [first, second]
  for i in 2..<65 {
    keys.push(gradient_key(100.0, 50.0, 90.0, (i.to_int64() << 8) | 0xFFL, 0xFFFFFFFFL))
  }
  assert_eq(gradients_made.at.length(), 64)
  assert_false(@ui.has_image(second), msg="the least lately asked for let go of")
  assert_true(@ui.has_image(first), msg="one asked for again kept")
  assert_true(keys[2:].iter().all(fn(k) { @ui.has_image(k) }))
  // (asked for again: made again under the same key)
  assert_eq(gradient_key(100.0, 50.0, 90.0, 0x000001FFL, 0xFFFFFFFFL), second)
  assert_true(@ui.has_image(second))
  assert_eq(gradients_made.at.length(), 64)
}

///|
test "pictures given inline beyond 128 let go of the least lately asked for, made again from their bytes as they are asked for" {
  made_run() |> ignore
  let url = fn(i : Int) { "data:image/png;base64," + @codec.base64(@utf8.encode("picture \{i}")) }
  let keys : Array[String] = []
  for i in 0..<129 {
    keys.push(data_image(url(i)))
  }
  assert_eq(data_images_made.at.length(), 128)
  assert_false(@ui.has_image(keys[0]), msg="the least lately asked for let go of")
  assert_true(keys[1:].iter().all(fn(k) { @ui.has_image(k) }))
  assert_eq(data_image(url(0)), keys[0])
  assert_true(@ui.has_image(keys[0]), msg="made again as it is asked for")
  assert_false(@ui.has_image(keys[1]))
}

///|
test "a run begins with none of the pictures made here kept, whatever the run before made" {
  made_run() |> ignore
  gradient_key(10.0, 10.0, 0.0, 0x000000FFL, 0xFFFFFFFFL) |> ignore
  data_image("data:image/png;base64,AAAA") |> ignore
  made_run() |> ignore
  assert_eq(gradients_made.at.length(), 0)
  assert_eq(data_images_made.at.length(), 0)
}
