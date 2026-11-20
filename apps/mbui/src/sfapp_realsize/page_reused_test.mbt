// The pages made by the library's page_node whose blocks are taken again as they leave what shows (its `reused`):
// 已归档's days and chats (sfpages archive_node.mbt) and 账号's accounts (sfpages profiles_list.mbt), opened on the
// workspace of real size in a phone's window and scrolled down through them: how many nodes the window's tree makes
// meanwhile, and that each block drawn shows the key it is taken for.

///|
/// Screen `mode` on the workspace of real size in a phone's window, scrolled down `turns` turns of the wheel from its
/// top: the nodes made meanwhile, and the words drawn in the window then.
fn page_reused_scrolled(mode : String, turns : Int) -> (Int, Array[String]) {
  let c = @sfrealsize.RealSizeChanging::new()
  let t = @sfapptest.screen_in(mode, ("phone", 360.0, 740.0, 2, ""), "zh", source=Some(fn(base) { c.source(base) }), moves_held=false)
  t.run_for(@ui.move_most_ms)
  t.tree_frames_from_now()
  for _ in 0..<turns {
    t.wheel(180.0, 420.0, 120.0)
    t.run_for(@ui.move_most_ms)
  }
  let made = t.tree_frames().fold(init=0, fn(n, f) { n + f.made })
  let seen = t.words().filter(fn(w) { w.5 > 0.0 && w.2 >= 0.0 && w.2 < 740.0 }).map(fn(w) { w.0 })
  (made, seen)
}

///|
test "小屏: 已归档 on a workspace of real size scrolled down, its days' and chats' blocks taken by those that come" {
  let (made, seen) = page_reused_scrolled("archived", 40)
  println("archived: 40 turns of the wheel: \{made} nodes made; shows \{seen.length()} words")
  assert_true(seen.length() > 5, msg=seen.join("|"))
  assert_true(made < 400, msg="made \{made} scrolling 已归档")
}

///|
test "小屏: 账号 on a workspace of real size scrolled down, its accounts' blocks taken by those that come" {
  let (made, seen) = page_reused_scrolled("place-profiles", 20)
  println("place-profiles: 20 turns of the wheel: \{made} nodes made; shows \{seen.length()} words")
  assert_true(seen.length() > 5, msg=seen.join("|"))
  assert_true(made < 700, msg="made \{made} scrolling 账号")
}
