///|
test "json_same matches MoonBit Json::op_equal including shared subtrees, repr, -0.0 and NaN" {
  let shared_block : Json = { "kind": "code", "lines": ["a", "b", "c"] }
  let a : Json = { "id": 1, "blocks": [shared_block, { "text": "hi" }] }
  let b : Json = { "id": 1.0, "blocks": [shared_block, { "text": "hi" }] }
  let c : Json = { "id": 1, "blocks": [shared_block, { "text": "bye" }] }
  assert_true(json_same(a, a))
  assert_true(json_same(a, b))
  assert_false(json_same(a, c))
  let parsed_num = @json.parse("{\"n\":1}")
  let made_num : Json = { "n": 1.0 }
  assert_true(json_same(parsed_num, made_num))
  let neg_zero : Json = { "z": -0.0 }
  let pos_zero : Json = { "z": 0.0 }
  assert_true(json_same(neg_zero, pos_zero))
  // NaN != NaN even when the exact same Json::number instance is shared in two different objects
  let nan = Json::number(0.0 / 0.0)
  let o1 : Json = { "x": nan }
  let o2 : Json = { "x": nan }
  assert_false(o1 == o2)
  assert_false(json_same(o1, o2))
  assert_false(json_same(nan, nan))
  assert_false(json_same({ "a": 1 }, { "a": 1, "b": 2 }))
  assert_false(json_same([1, 2], [1, 2, 3]))
}
