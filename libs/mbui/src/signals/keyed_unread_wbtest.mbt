///|
test "keys read once each and never again are let go of as more are read, not only as it is next set" {
  let k : Keyed[Int] = keyed()
  k.set([1, 2])
  for i in 0..<5000 {
    k.has(i) |> ignore
  }
  assert_true(k.said.length() < 200, msg="\{k.said.length()} keys' signals kept")
  // (those in it, read, still say so)
  assert_true(k.has(1) && k.has(2) && !k.has(3))
}
