// What each chat list last showed (chat_list.mbt's rows_given) is kept for the lists drawn lately only: each holds its
// chat's whole view, and a list let go of and drawn again is never said as one said before.

///|
test "chat lists' last givings beyond 16: the least lately drawn let go of; given again, said as never before" {
  @ui.Tester::new(fn(_c) {  }, w=200.0, h=100.0) |> ignore
  reset()
  let view = fn() { @sfbase.chat_view_made({ "title": Json::string(""), "messages": [] }) }
  let read : Array[@sfbase.Entry] = []
  let v0 = view()
  let said0 = rows_said("list0", v0, read)
  // (the same given again: said the same)
  assert_eq(rows_said("list0", v0, read), said0)
  let said : Array[Int] = [said0]
  for i in 1..<17 {
    said.push(rows_said("list\{i}", view(), read))
  }
  assert_eq(rows_given.length(), 16)
  assert_true(rows_given.get("list0") is None, msg="the least lately drawn let go of")
  // (drawn again with what it was given before: said as never before, its rows built anew)
  let again = rows_said("list0", v0, read)
  assert_false(said.contains(again))
  assert_eq(rows_given.length(), 16)
  assert_true(rows_given.get("list1") is None)
  // (a list given otherwise: said anew)
  assert_true(rows_said("list16", view(), read) != said[16])
  reset()
  assert_true(rows_given.is_empty())
}
