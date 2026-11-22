// A quota card drawn twice: the first aligns the button's edge to the card's words; the second uses the real card foot
// so the button's words align instead, while the button itself follows the card's corner.

///|
/// The edge-aligned example deliberately leaves the button off the card's bottom-left corner. No other faults belong
/// in the picture, including on the surrounding white panels or on the text-aligned example.
pub fn alignment_corner_faults_ok(faults : Array[String]) -> Bool {
  faults.length() == 1 &&
  faults[0].contains("「Try again」") &&
  faults[0].contains("bottom left") &&
  faults[0].contains("Quota check failed")
}

///|
fn alignment_example(parent : @view.View, width : Double, text_aligned : Bool) -> Unit {
  parent.box(fn(box) {
    box.width(Is(Some(width))) |> ignore
    @sf.page_card_node(box, footed=true, layered=true, fn(card) {
      @sf.card_lines_node(
        card,
        fn() { "Quota check failed" },
        words=fn() { "Request timed out." },
        note=fn() { "Check your connection and try again." },
      )
      if text_aligned {
        @sf.card_foot_node(card, fn(f) {
          @sf.button_node(f, fn() { "Try again" }, fn() { }, tone=Primary, card_words=true) |> ignore
        })
      } else {
        card.box(fn(f) {
          @sf.style_node(f, fn() { @sf.ask_foot })
          @sf.button_node(f, fn() { "Try again" }, fn() { }, tone=Primary) |> ignore
        })
        |> ignore
      }
    })
  })
  |> ignore
}

///|
// A fine dashed reference ends exactly at the text's start, just to its left, so it does not cover the letters.
fn alignment_guide(parent : @view.View, text_aligned : Bool) -> Unit {
  let anchor = @sf.corner_inset + @sf.card_pad
  let guide_width = 0.8
  let colour : Int64 = if text_aligned { 0x2863E9A6L } else { 0xF0502CA6L }
  for i in 0..<28 {
    @figure.panel_node(parent, anchor - guide_width, 74.0 + i.to_double() * 4.0, guide_width, 2.0, colour, 0.0, fn(_) { })
  }
}

///|
fn alignment_panel(parent : @view.View, x : Double, text_aligned : Bool) -> Unit {
  let w = 418.0
  let card_width = w - 2.0 * @sf.corner_inset
  let dot = @ui.capsule_in(@sf.pane_corner, 10.0)
  let mark = if text_aligned { blue } else { red }
  @figure.panel_node(parent, x, 128.0, w, 282.0, white, @sf.pane_corner, fn(panel) {
    @figure.panel_node(panel, dot, dot, 10.0, 10.0, mark, 5.0, fn(_) { })
    @figure.words_node(panel, dot + 20.0, dot - 5.625, if text_aligned { "Text aligned" } else { "Edge aligned" }, 17.0, ink, weight=650)
    panel.box(fn(v) {
      v.over(Is(true), edges=(Some(@sf.corner_inset), Some(54.0), None, None)).width(Is(Some(card_width))) |> ignore
      alignment_example(v, card_width, text_aligned)
    })
    |> ignore
    alignment_guide(panel, text_aligned)
    @figure.words_node(panel, @sf.corner_inset + @sf.card_pad, 210.0, if text_aligned { "The words line up." } else { "The edge lines up." }, 15.0, ink, weight=650)
    @figure.words_node(panel, @sf.corner_inset + @sf.card_pad, 235.0, if text_aligned { "The button follows the card's corner." } else { "The label starts further in." }, 12.0, muted)
  })
}

///|
/// A 960 × 540 comparison of aligning a button's edge or its words to the words above it.
pub fn alignment_figure(root : @view.View) -> Unit {
  @ui.set_tree_theme(@sf.ui_theme_now)
  @figure.canvas_node(root, 960.0, 540.0, paper, fn(canvas) {
    @figure.words_node(canvas, 50.0, 19.0, "Same card. Different alignment.", 34.0, ink, weight=680)
    @figure.words_node(canvas, 50.0, 65.0, "The button's edge and its text have different starting points.", 14.0, muted)
    @figure.panel_node(canvas, 826.0, 31.0, 10.0, 10.0, ink, 3.0, fn(_) { })
    @figure.words_node(canvas, 844.0, 24.0, "still.fail", 18.0, ink, weight=650)
    alignment_panel(canvas, 50.0, false)
    alignment_panel(canvas, 492.0, true)
    @figure.words_node(canvas, 50.0, 449.0, "Button padding shifts its label.", 20.0, ink, weight=650)
    @figure.words_node(canvas, 50.0, 480.0, "Align the words while the button follows the card's corner.", 14.0, muted)
  })
}
