// The library's step circle (step_circle_node.mbt): on its words' first line, its number never outgrowing its circle
// at the system's words set large, and the pin pressed as a button by its name.

///|
test "a step's circle on its title's first line, its number held in it at the system's words set to 1.3" {
  let t = u5_case(scale=1.3, fn(root) {
    root.box(fn(r) {
      r.row(Is(true)).width(Is(Some(260.0))).gap(Is(12.0)).lines_up(Is(Some(Start))) |> ignore
      step_circle_node(r, fn() { "12" }, first_line=Ui) |> ignore
      words_node(r, fn() { "复制令牌 再回到这里 粘贴在下面的框里 然后按添加" }, fn() { u5_words_wrap })
      .shrink(Is(1.0))
      .min_width(Is(Some(0.0)))
      |> ignore
    })
    |> ignore
  })
  assert_eq(t.fixed_outgrown(), [])
  let (_, _, ny, _, nh, _) = t.words().filter(fn(w) { w.0 == "12" })[0]
  let (_, _, wy, _, wh, _) = t.words().filter(fn(w) { w.0.has_prefix("复制令牌") })[0]
  let line = wh / 2.0
  // (two lines or more of words: the circle's number across the first's middle)
  assert_true(wh > nh * 1.5, msg="\{wh} \{nh}")
  assert_true((ny + nh / 2.0 - (wy + line / 2.0)).abs() <= line / 2.0, msg="\{ny} \{nh} \{wy} \{wh}")
}

///|
test "a mark's pin: a button by its name, pressed once a press" {
  let pressed = Ref(0)
  let t = u5_case(fn(root) {
    step_circle_button_node(root, fn() { "3" }, fn() { "标注 3" }, fn(_) { pressed.val += 1 }) |> ignore
  })
  t.click(Button, label="标注 3")
  t.draw()
  assert_eq(pressed.val, 1)
  assert_eq(t.fixed_outgrown(), [])
}
