// A skill's card in memory_doc.mbt: what kind it is and when it is read, aligned with the card's padding.

///|
test "a skill's card: what kind it is and when it is read, its words the card's (24) in" {
  let t = settings_tester("memory-doc:ws1/st1#发布流程")
  let (hx, _, _, _) = t.rect_of("项目记忆 · 读取时机").unwrap()
  let (wx, _, _, _) = t.rect_of("发布新版本时").unwrap()
  // (the card 12 from the page's side, its words card_pad (24) in: both at 36)
  let at = 12.0 + @sf.card_pad
  assert_true((hx - at).abs() < 0.5, msg="head at \{hx}")
  assert_true((wx - at).abs() < 0.5, msg="when at \{wx}")
}
