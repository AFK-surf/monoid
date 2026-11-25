///|
fn cmd_pick_at(text : String, needle : String) -> String {
  guard text.find(needle) is Some(off) else { @halt.saying("no \{needle} in \{text}") }
  let (a, b) = cmd_pick_sentence(text, off)
  text.exact_view(start=a, end=b).to_owned()
}

///|
test "cmd pick stops at commas without taking them" {
  let zh = "高度先按 90 估，量过一次就记住。深色模式我一起看。"
  assert_eq(cmd_pick_at(zh, "90"), "高度先按 90 估")
  assert_eq(cmd_pick_at(zh, "量过"), "量过一次就记住。")
  assert_eq(cmd_pick_at(zh, "深色"), "深色模式我一起看。")
  let en = "First, we build it. Then we ship."
  assert_eq(cmd_pick_at(en, "First"), "First")
  assert_eq(cmd_pick_at(en, "build"), "we build it.")
  assert_eq(cmd_pick_at(en, "ship"), "Then we ship.")
}

///|
test "cmd pick keeps commas inside numbers and lists" {
  assert_eq(cmd_pick_at("It costs 1,000 dollars. Done.", "costs"), "It costs 1,000 dollars.")
  assert_eq(cmd_pick_at("Pick a,b or c.", "or"), "Pick a,b or c.")
  assert_eq(cmd_pick_at("Ends with a comma,", "Ends"), "Ends with a comma")
}
