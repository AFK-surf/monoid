// A quote's card in a message as nodes (quote_card_node) where what holds it has its words picked with the mouse (a
// message's list: @ui.words_picked): dragged over from the words before it to the words after it, what is picked.

///|
/// A page 360 wide whose words are picked with the mouse (@ui.words_picked): words in pieces, a quote's card leading
/// to its message, words in pieces; dragged over from the first's start to the last's end. What is picked then (what
/// ⌘C copies), and the quote's words as its card says them.
fn quote_dragged_over() -> (String, String) raise {
  let tr = @ui.Tester::new(
    fn(c) { begin(c) |> ignore },
    tree=fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      let tips = TipLayer::new(fn() { Some(root) })
      root.box(fn(page) {
        page.width(Is(Some(360.0))).padding(Is((16.0, 40.0, 16.0, 0.0))) |> ignore
        @ui.words_picked(page)
        page.box(fn(n) { n.words_runs(Is([@ui.span("正文在前")])) |> ignore }) |> ignore
        quote_card_node(
          page,
          tips,
          fn() { "Ana" },
          fn() { "先把签名核对一遍" },
          fn() { "person" },
          fn() { "" },
          fn() { true },
          fn() {  },
        )
        |> ignore
        page.box(fn(n) { n.words_runs(Is([@ui.span("正文在后")])) |> ignore }) |> ignore
      })
      |> ignore
    },
    w=400.0,
    h=300.0,
    platform=0,
  )
  tr.run_for(@ui.move_most_ms)
  let open_mark = match @ui.view_tree() {
    Some(tree) => tree.drawn().iter().any(fn(d) { tree.drawn_name(d.id) == "/icon/quote-open/" })
    None => false
  }
  assert_true(open_mark, msg="the quote starts with an opening mark")
  let at = fn(s : String) {
    match tr.words().iter().find_first(fn(w) { w.0 == s }) {
      Some(w) => w
      None => @halt.saying("\{s} not drawn: \{Repr(tr.words())}")
    }
  }
  let first = at("正文在前")
  let last = at("正文在后")
  tr.drag(first.1 + 1.0, first.2 + first.4 / 2.0, last.1 + last.3 - 1.0, last.2 + last.4 / 2.0)
  tr.run_for(@ui.move_most_ms)
  (tr.ctx().selected_text(), t("web-main.quote.author", args=[("author", "Ana")]) + "先把签名核对一遍")
}

///|
test "dragged over from the words before a quote's card to the words after it, what is picked holds those two alone, as the old card's words were none of what is picked" {
  let (picked, quoted) = quote_dragged_over()
  // (the card lends a picker that picks none: mbui's ui keeps the words of what is so lent out of what is picked)
  assert_eq(picked, "正文在前\n正文在后", msg=quoted)
}

///|
test "quote_pin: 1.0x keeps exact 16pt; 2.0x stays clean with zero fixed_outgrown or squeeze_faults" {
  let mut pin_v : @view.View? = None
  let tr = @ui.Tester::new(
    fn(c) { begin(c) |> ignore },
    tree=fn(root) {
      @ui.set_tree_theme(ui_theme_now)
      let tips = TipLayer::new(fn() { Some(root) })
      root.box(fn(page) {
        page.width(Is(Some(360.0))).padding(Is((16.0, 40.0, 16.0, 0.0))).gap(Is(8.0)) |> ignore
        quote_card_node(
          page,
          tips,
          fn() { "Ana" },
          fn() { "先把签名核对一遍" },
          fn() { "person" },
          fn() { "1" },
          fn() { true },
          fn() {  },
        )
        |> ignore
        page.box(fn(mark) {
          pin_v = Some(mark)
          style_node(mark, fn() { quote_pin })
          mark_words_node(mark, fn() { "1" }, fn() { quote_pin_words }) |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    w=400.0,
    h=300.0,
    platform=0,
  )
  tr.draw()
  let pin_h = match @ui.view_tree().unwrap().drawn().iter().find_first(fn(d) { d.id == pin_v.unwrap().id() }) {
    Some(d) => d.h
    None => 0.0
  }
  assert_eq(pin_h, @ui.Space::S4.px(), msg="1.0x pin height")
  assert_eq(tr.fixed_outgrown(), [], msg="1.0x fixed_outgrown")
  assert_eq(tr.squeeze_faults(), [], msg="1.0x squeeze_faults")
  tr.set_font_scale(2.0)
  tr.draw()
  assert_eq(tr.fixed_outgrown(), [], msg="2.0x fixed_outgrown")
  assert_eq(tr.squeeze_faults(), [], msg="2.0x squeeze_faults")
}
