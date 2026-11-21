// A card's first action can align with its words without changing the room in a later button, an icon button, or a
// button at the other end of the card.

///|
fn wide_node_tester(w : Double, h : Double, body : (@view.View) -> Unit) -> @ui.Tester {
  let t = @ui.Tester::new(fn(c) { begin(c) |> ignore }, w~, h~)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.lines_up(Is(None)) |> ignore
    look_lent(root, Wide)
    body(root)
  })
  t.draw()
  t
}

///|
test "card foot alignment leaves other buttons' room alone" {
  let t = wide_node_tester(800.0, 600.0, fn(v) {
    v.box(fn(r) {
      r.row(Is(true)) |> ignore
      button_node(r, fn() { "普通按钮" }, fn() {  }) |> ignore
    })
    |> ignore
    page_card_node(v, footed=true, fn(c) {
      words_node(c, fn() { "卡片的字" }, fn() { desk_words }) |> ignore
      card_foot_node(c, fn(f) {
        button_node(f, fn() { "图标按钮" }, fn() {  }, icon="log-in") |> ignore
        button_node(f, fn() { "后续按钮" }, fn() {  }) |> ignore
      })
    })
    page_card_node(v, footed=true, fn(c) {
      words_node(c, fn() { "卡片的另一行字" }, fn() { desk_words }) |> ignore
      card_foot_node(c, at_end=true, fn(f) { button_node(f, fn() { "末尾按钮" }, fn() {  }) |> ignore })
    })
    v.box(fn(r) {
      r.row(Is(true)) |> ignore
      button_node(r, fn() { "另一按钮" }, fn() {  }) |> ignore
    })
    |> ignore
  })
  let (ordinary_x, _, _, _) = t.rect_of("普通按钮").unwrap()
  let (later_x, _, _, _) = t.rect_of("后续按钮").unwrap()
  let (end_x, _, _, _) = t.rect_of("末尾按钮").unwrap()
  let (after_x, _, _, _) = t.rect_of("另一按钮").unwrap()
  let ordinary_in = ordinary_x - t.get(Button, label="普通按钮").rect.0
  let later_in = later_x - t.get(Button, label="后续按钮").rect.0
  let end_in = end_x - t.get(Button, label="末尾按钮").rect.0
  let after_in = after_x - t.get(Button, label="另一按钮").rect.0
  assert_true((later_in - ordinary_in).abs() < 0.01, msg="later \{later_in}, ordinary \{ordinary_in}")
  assert_true((end_in - ordinary_in).abs() < 0.01, msg="end \{end_in}, ordinary \{ordinary_in}")
  assert_true((after_in - ordinary_in).abs() < 0.01, msg="after \{after_in}, ordinary \{ordinary_in}")
}

///|
test "a wrapping card foot keeps its first action at the bottom left" {
  let t = wide_node_tester(220.0, 400.0, fn(v) {
    page_card_node(v, footed=true, fn(c) {
      words_node(c, fn() { "卡片的字" }, fn() { desk_words }) |> ignore
      ask_buttons_node(c, fn(f) {
        button_node(f, fn() { "主要操作" }, fn() {  }, tone=Primary, card_words=true) |> ignore
        button_node(f, fn() { "较长的次要操作一" }, fn() {  }, tone=Ghost, card_words=true) |> ignore
        button_node(f, fn() { "较长的次要操作二" }, fn() {  }, tone=Ghost, card_words=true) |> ignore
      })
      |> ignore
    })
  })
  let (title_x, _, _, _) = t.rect_of("卡片的字").unwrap()
  let (primary_x, primary_y, _, _) = t.rect_of("主要操作").unwrap()
  let (_, last_y, _, _) = t.rect_of("较长的次要操作二").unwrap()
  assert_true((primary_x - title_x).abs() < 0.01)
  assert_true(primary_y > last_y, msg="primary \{primary_y}, last \{last_y}")
}
