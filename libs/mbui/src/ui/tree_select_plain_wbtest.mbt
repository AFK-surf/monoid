// Plain `View::words` selection (`View::words_selectable`) inside `words_picked`: opted-in plain text supports mouse
// I-beam hover, drag/double-click/triple-click selection, highlight rects, ⌘C copy, centered layout, virtualized
// `scrolls_window` persistence without mount-time signal bindings, `as_ground` dialog surfaces (mouse + touch long
// press), and interactive control exclusion inside selectable containers.

///|
fn plain_picked_tester(
  selectable : Bool,
  platform? : Int = 0,
  centered? : Bool = false,
  in_ground? : Bool = false,
  text? : String = "Eligibility check failed",
) -> Tester {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform~)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.box(fn(page) {
      page.padding(Is((20.0, 40.0, 20.0, 20.0))).lines_up(Is(Some(Start))) |> ignore
      words_picked(page)
      let make = fn(holder : @view.View) {
        if selectable {
          holder.words_selectable() |> ignore
        }
        holder.box(fn(n) {
          n
          .width(Is(Some(300.0)))
          .words(
            Is(text),
            ink=0x333333FFL,
            look={ size: 15.0, weight: 400, line: 22.0, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 },
          )
          .words_centered(Is(centered))
          |> ignore
        })
        |> ignore
      }
      if in_ground {
        page.box(fn(d) {
          d
          .padding(Is((16.0, 16.0, 16.0, 16.0)))
          .presses(Is(true))
          .on_press(fn() {  })
          .cursor(Is(Some(Arrow)))
          .as_ground()
          |> ignore
          make(d)
        })
        |> ignore
      } else {
        make(page)
      }
    })
    |> ignore
  })
  t.draw()
  t.drawn_now()
  t
}

///|
test "plain View::words without words_selectable stays non-selectable and keeps Arrow cursor" {
  let t = plain_picked_tester(false)
  t.move_to(40.0, 51.0)
  t.frame()
  assert_eq(t.cursor(), Arrow)
  let next = dragged_at(t, 21.0, 51.0, 320.0, 51.0, t.time(), true)
  t.frame_at(next)
  assert_eq(t.ctx().selected_text(), "")
  assert_eq(picked_drawn(t).length(), 0)
}

///|
test "opted-in plain View::words: mouse hover shows IBeam, drag selects and highlights, Cmd+C copies, double/triple click pick word and paragraph, press elsewhere clears" {
  let t = plain_picked_tester(true)
  // Hover over plain words shows IBeam; hover over empty space below shows Arrow.
  t.move_to(40.0, 51.0)
  t.frame()
  assert_eq(t.cursor(), IBeam)
  t.move_to(350.0, 250.0)
  t.frame()
  assert_eq(t.cursor(), Arrow)
  // Drag across words: selects text, draws highlight rect, and Cmd+C copies it.
  let next = dragged_at(t, 21.0, 51.0, 320.0, 51.0, t.time(), true)
  t.frame_at(next)
  assert_eq(t.ctx().selected_text(), "Eligibility check failed")
  assert_true(picked_drawn(t).length() > 0, msg="selection highlight drawn")
  t.key(key_copy)
  t.frame()
  assert_eq(t.clipboard(), "Eligibility check failed")
  // Double-click picks one word; triple-click picks the whole paragraph.
  let t0 = t.time() + double_click_ms * 2.0
  let click_gap = double_click_ms / 4.0
  t.frame_at(t0)
  t.press_at(35.0, 51.0)
  t.release(35.0, 51.0)
  t.frame_at(t0 + click_gap)
  t.press_at(35.0, 51.0)
  t.release(35.0, 51.0)
  t.frame()
  assert_eq(t.ctx().selected_text(), "Eligibility")
  t.press_at(35.0, 51.0)
  t.release(35.0, 51.0)
  t.frame()
  assert_eq(t.ctx().selected_text(), "Eligibility check failed")
  // Click elsewhere clears selection and highlight.
  let clear_at = t.time() + double_click_ms * 2.0
  let after = dragged_at(t, 350.0, 250.0, 350.0, 250.0, clear_at, true)
  t.frame_at(after)
  assert_eq(t.ctx().selected_text(), "")
  assert_eq(picked_drawn(t).length(), 0)
}

///|
test "interactive controls inside a words_selectable container stay non-selectable, keep button cursor, and fire on_press" {
  for hand_over in [true, false] {
    let clicks = Ref(0)
    let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=0)
    t.check_looks(false)
    let look : @view.WordsLook = {
      size: 15.0,
      weight: 400,
      line: 22.0,
      wrap: true,
      tracking: @view.letters_own,
      balance: false,
      max_lines: 0,
    }
    set_view_app(fn(root) {
      root.tree.hand_over_presses(hand_over)
      root.box(fn(page) {
        page.padding(Is((20.0, 20.0, 20.0, 20.0))).gap(Is(8.0)).lines_up(Is(Some(Start))) |> ignore
        words_picked(page)
        page.words_selectable() |> ignore
        page.box(fn(n) { n.width(Is(Some(300.0))).words(Is("above"), ink=0x333333FFL, look~) |> ignore }) |> ignore
        page.box(fn(btn) {
          btn
          .padding(Is((10.0, 6.0, 10.0, 6.0)))
          .presses(Is(true))
          .on_press(fn() { clicks.val += 1 })
          .says(Is(Some(@view.said(Button, label="Retry"))))
          |> ignore
          btn.box(fn(lbl) { lbl.words(Is("Retry"), ink=0x333333FFL, look~) |> ignore }) |> ignore
        })
        |> ignore
        page.box(fn(n) { n.width(Is(Some(300.0))).words(Is("below"), ink=0x333333FFL, look~) |> ignore }) |> ignore
      })
      |> ignore
    })
    t.draw()
    t.drawn_now()
    let btn_rect = t.get(Button, label="Retry").rect
    let (bx, by) = (btn_rect.0 + btn_rect.2 / 2.0, btn_rect.1 + btn_rect.3 / 2.0)
    // Hover over button keeps Hand (or Arrow when hand_over_presses is false), never IBeam.
    t.move_to(bx, by)
    t.frame()
    assert_eq(t.cursor(), if hand_over { Hand } else { Arrow }, msg="hand_over=\{hand_over}")
    // Drag starting on button and releasing outside does not select its label or click it.
    let next = dragged_at(t, btn_rect.0 + 4.0, by, btn_rect.0 + btn_rect.2 + 40.0, by, t.time(), true)
    t.frame_at(next)
    assert_eq(t.ctx().selected_text(), "", msg="button label not selected")
    assert_eq(clicks.val, 0, msg="drag off button did not click")
    // Tap on button still clicks it.
    t.tap(bx, by)
    t.frame()
    assert_eq(clicks.val, 1, msg="button clicked")
    // Drag across above -> button -> below skips the button label.
    let top_rect = t.rect_of("above").unwrap()
    let bot_rect = t.rect_of("below").unwrap()
    t.drag(
      top_rect.0 + 1.0,
      top_rect.1 + top_rect.3 / 2.0,
      bot_rect.0 + bot_rect.2 + 20.0,
      bot_rect.1 + bot_rect.3 / 2.0,
    )
    t.release(bot_rect.0 + bot_rect.2 + 20.0, bot_rect.1 + bot_rect.3 / 2.0)
    t.frame()
    assert_eq(t.ctx().selected_text(), "above\nbelow", msg="skips button label: \{t.ctx().selected_text()}")
  }
}

///|
test "opted-in plain View::words inside an as_ground surface (dialog/panel): mouse hover IBeam + drag select, and finger long-press selects word with text menu" {
  // Desktop mouse inside ground_node.
  let t = plain_picked_tester(true, platform=0, in_ground=true)
  // Ground padding (23, 43) stays Arrow; text inside (40, 67) shows IBeam.
  t.move_to(23.0, 43.0)
  t.frame()
  assert_eq(t.cursor(), Arrow)
  let r = t.rect_of("Eligibility check failed").unwrap()
  let mid_y = r.1 + r.3 / 2.0
  t.move_to(r.0 + 10.0, mid_y)
  t.frame()
  assert_eq(t.cursor(), IBeam)
  let next = dragged_at(t, r.0 + 1.0, mid_y, r.0 + r.2 + 20.0, mid_y, t.time(), true)
  t.frame_at(next)
  assert_eq(t.ctx().selected_text(), "Eligibility check failed")
  assert_true(picked_drawn(t).length() > 0)
  // Touch finger long-press inside ground_node.
  let tf = plain_picked_tester(true, platform=2, in_ground=true, text="hello wide world")
  let rf = tf.rect_of("hello wide world").unwrap()
  let fx = rf.0 + 60.0
  let fy = rf.1 + rf.3 / 2.0
  tf.press_at(fx, fy)
  assert_eq(tf.ctx().selected_text(), "")
  tf.run_for(long_press_ms)
  assert_eq(tf.ctx().selected_text(), "wide")
  tf.release(fx, fy)
  tf.draw()
  assert_true(tf.text_menu().0)
  tf.tap(360.0, 260.0)
  tf.draw()
  assert_eq(tf.ctx().selected_text(), "")
}

///|
test "centered plain View::words: dragged from first glyph to fifth selects exact four characters aligned with glyphs" {
  let t = plain_picked_tester(true, centered=true, text="hello wide world")
  let glyphs = t.drawn_instances().filter(fn(a) { a[5] == 1.0 }).map(fn(a) { (a[0], a[1], a[2], a[3]) })
  glyphs.sort_by(fn(a, b) { a.0.compare(b.0) })
  assert_true(glyphs[0].0 > 40.0, msg="centered: \{Repr(glyphs[0])}")
  let (x0, to) = (glyphs[0].0 + 0.5, glyphs[4].0 + 0.5)
  let next = dragged_at(t, x0, 51.0, x0 + (to - x0) * 6.0 / 5.0, 51.0, t.time(), true)
  t.frame_at(next)
  let drawn = picked_drawn(t)
  assert_eq(t.ctx().selected_text(), "hell")
  assert_eq(drawn.length(), 1)
  assert_true((drawn[0].0 - glyphs[0].0).abs() < 2.0, msg="highlight aligns with glyphs: \{Repr(drawn)} \{Repr(glyphs[0])}")
}

///|
test "virtualized scrolls_window with opted-in plain View::words retains selection highlight after scrolling away and back, and clears cleanly" {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0)
  t.check_looks(false)
  let s = @view.Scroll::list()
  let keys = @signals.signal(Array::makei(40, fn(i) { i }))
  set_view_app(fn(root) {
    root.box(fn(page) {
      page.height(Is(Some(200.0))).width(Is(Some(300.0))) |> ignore
      words_picked(page)
      page.words_selectable() |> ignore
      page.scrolls_window(s, fn() { keys.get() }, est=22.0, fn(b, i) {
        b.box(fn(n) {
          n
          .words(
            Is("第 \{i} 行 plain"),
            ink=0x333333FFL,
            look={ size: 15.0, weight: 400, line: 22.0, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 },
          )
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.drawn_now()
  let next = dragged_at(t, 1.0, 11.0, 1.0 + 299.0 * 6.0 / 5.0, 11.0 + 26.0 * 6.0 / 5.0, t.time(), true)
  t.frame_at(next)
  let said = t.ctx().selected_text()
  assert_true(said.contains("第 0 行 plain") && said.contains("第 1 行 plain"), msg="\{said}")
  let drawn = picked_drawn(t)
  assert_true(drawn.length() >= 2, msg="drawn picked: \{Repr(drawn)}")
  t.wheel(150.0, 100.0, 600.0)
  t.run_for(move_most_ms)
  assert_eq(picked_drawn(t).length(), 0)
  t.wheel(150.0, 100.0, -600.0)
  t.run_for(move_most_ms)
  assert_eq(t.ctx().selected_text(), said)
  assert_eq(picked_drawn(t), drawn)
  // Clicking outside clears the highlight on the recreated plain nodes.
  let clear_at = t.time() + double_click_ms * 2.0
  let after = dragged_at(t, 360.0, 260.0, 360.0, 260.0, clear_at, true)
  t.frame_at(after)
  assert_eq(t.ctx().selected_text(), "")
  assert_eq(picked_drawn(t).length(), 0)
}
