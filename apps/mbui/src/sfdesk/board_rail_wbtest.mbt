///|
test "看板 where nothing is said: after 对话, else after the first of the chats' lists, else first" {
  assert_eq(board_rail_default(["attention", "chats", "files"]), 2)
  // (我参与的 in 对话's place: under it, not over 待处理)
  assert_eq(board_rail_default(["attention", "mine", "profiles"]), 2)
  assert_eq(board_rail_default(["attention", "watching", "chats"]), 3)
  assert_eq(board_rail_default(["attention", "files"]), 0)
}
