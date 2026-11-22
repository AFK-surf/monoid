///|
test "a lost frame does not hold the replacement or count as delivered" {
  let now = Ref(0.0)
  let p = Pacer::new(() => now.val)
  p.sent(1.0, 100.0)
  p.sent(2.0, 100.0)
  assert_false(p.may())
  p.lost()
  assert_true(p.may())
  p.acked(2.0)
  assert_eq(p.rtt(), None)
  assert_eq(p.through_rate(), 0.0)
  p.sent(3.0, 100.0, key=true)
  now.val = 10.0
  p.acked(3.0)
  assert_eq(p.rtt(), Some(10.0))
}
