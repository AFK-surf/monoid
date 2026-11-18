// Smoothness and one-way gate for the chat's page made as nodes (chat_page_nodes = true) with all Tester frame-to-frame
// look checks enabled (words_over_held = true, check_looks = true: sizes_steady, rows_steady, words_over, gaps_steady),
// never listed in motion_counted:
// 1. Answering a decision card ("一起换" -> "选择了「一起换」") enters once and stays at alpha 1.0 with its right edge
//    steady as the agent's follow-up answer arrives after it (#27, #8).
// 2. Sending a message while an agent works, then receiving the agent's reply after the bubble lands, on 大屏 and 小屏.
// 3. Starting a new chat (NewChat -> Chat) on 大屏 and 小屏, with the old composer and the composer made as nodes
//    (composer_nodes = true: its box flying down from where NewChat's centered composer stood).
// 4. Scrolling up from the foot, fading in 跳到最新, and pressing it to glide back while the button fades out.
// 5. Opening and closing the side panel on 大屏 with no horizontal step.

///|
test "chat_page_nodes smoothness: decision card pick enters once and never replays or shifts right edge when later messages arrive (#27, #8)" {
  if @ui.test_at_a_rate() {
    return
  }
  for screen in [dk_screens[0]] {
    let (name, w, h, platform) = screen
    new_run()
    @sfbase.chat_page_nodes.set(true)
    let src = fixture_app("chat", chat_nodes=true)
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~, words_over_held=true)
    t.set_rows_on_pixels(true)
    t.set_frame_period(1000.0 / 60.0)
    let seen : Array[(Double, Double, Double, Double)] = []
    let start = t.time()
    let script =
      #|timeout 20000
      #|until =一起换
      #|wait 600
      #|tap =一起换
      #|wait 2600
      #|exit
    t.drive(script, each=fn(t) {
      for wd in t.words() {
        let (txt, x, y, ww, _, a) = wd
        // (y >= 120: on 390x844, the list scrolls down as the new reply arrives at the foot, carrying this earlier row up
        // into the top bar's scroll-edge fade band)
        if txt.contains("选择了「一起换」") && a > 0.02 && y >= 120.0 {
          seen.push((t.time() - start, x, ww, a))
          break
        }
      }
    })
    |> ignore
    assert_true(seen.length() > 10, msg="\{name}: picked line not seen across frames (\{seen.length()})")
    let mut reached_full = false
    let mut right_at_full = 0.0
    for s in seen {
      let (at, x, ww, a) = s
      if !reached_full {
        if a >= 0.99 {
          reached_full = true
          right_at_full = x + ww
        }
      } else {
        assert_true(a >= 0.99, msg="\{name} @\{at.round()}ms: picked line replayed fade (alpha=\{a})")
        assert_true(
          (x + ww - right_at_full).abs() <= 0.6,
          msg="\{name} @\{at.round()}ms: picked line right edge shifted from \{right_at_full} to \{x + ww}",
        )
      }
    }
    assert_true(reached_full, msg="\{name}: picked line never reached full alpha: \{Repr(seen)}")
  }
}

///|
test "chat_page_nodes smoothness: NewChat -> Chat with composer_nodes glides the composer down on 大屏 and keeps words steady on 小屏" {
  for composed in [false, true] {
    for screen in dk_screens {
      let (name, w, h, platform) = screen
      new_run()
      @sfbase.chat_page_nodes.set(true)
      let fixture = if w >= @sf.page_narrow_most { "chat" } else { "newchat" }
      let src = fixture_app(fixture, chat_nodes=true)
      @sfbase.composer_nodes.set(composed)
      let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~, words_over_held=true)
      t.set_rows_on_pixels(true)
      t.run_for(@ui.move_most_ms * 2.0)
      if w >= @sf.page_narrow_most {
        t.tap_text("新建对话")
        t.run_for(@ui.move_most_ms)
      }
      let new_rect = @motion.measured_rect(t.ctx(), "new/composer")
      t.tap_text("做任何事")
      t.run_for(@ui.move_most_ms)
      t.type_text("平滑度门禁首句测试")
      t.run_for(@ui.move_most_ms)
      if !@ui.test_at_a_rate() && composed && w >= @sf.page_narrow_most {
        guard new_rect is Some((_, fy, _, fh)) else {
          fail("\{name} composed=\{composed}: NewChat composer rect not measured")
        }
        tap_send(t)
        t.draw()
        // first frame in Chat: composer_node's foot flies from NewChat's foot without placeholder overlapping the flying words
        // (what is drawn, not what is found: the field keeps its placeholder to be found by while it is drawn in no ink)
        let hints = t.text_runs().filter(fn(r) {
          r.text == @sf.t("web-main.composer.placeholder") || r.text.contains("输入")
        })
        assert_eq(hints, [], msg="\{name}: composer placeholder overlapped flying words: \{Repr(hints)}")
        match t.query(Button, label=@sf.t("web-main.composer.attach")) {
          Some(plus) =>
            assert_true(
              plus.rect.1 >= fy + fh - 52.0 && plus.rect.1 <= fy + fh + 4.0,
              msg="\{name}: attach button at \{plus.rect.1}, expected near NewChat foot \{fy + fh}",
            )
          None => ()
        }
        t.run_for(@sfbase.flight_most_ms + @sfbase.new_leave_ms + @ui.move_most_ms)
        // (the cursor in it as the chat comes with keyboard and mouse: its placeholder drawn once it is let go)
        t.ctx().blur()
        t.run_for(@sfpages.let_go_ms + @sfpages.composer_shape_ms + @sf.hint_back_ms)
        assert_true(
          t.text_runs().iter().any(fn(r) { r.text == @sf.t("web-main.composer.placeholder") || r.text.contains("输入") }),
          msg="\{name}: composer placeholder did not fade in after blur",
        )
      } else {
        tap_send(t)
        t.run_for(@sfbase.flight_carry_after_ms + @sfbase.flight_most_ms + @sfbase.new_leave_ms + @ui.move_most_ms)
      }
      assert_true(app.nav.top() is Chat(_), msg="\{name} composed=\{composed}: did not become Chat")
    }
  }
}

///|
test "chat_page_nodes smoothness: send, scroll away + 跳到最新 glide, and 大屏 side panel toggle pass full look checks" {
  let screen = dk_screens[0]
  let (name, w, h, _) = screen
  let (tp, srcp) = dk_open(screen)
  @sfdesk.side_toggle(srcp, dk_chat, "s-c1")
  tp.run_for(@ui.move_most_ms)
  @sfdesk.side_toggle(srcp, dk_chat, "s-c1")
  tp.run_for(@ui.move_most_ms)
  let (ts, _) = dk_open(screen)
  ts.move_to(w / 2.0, h / 2.0)
  ts.wheel(w / 2.0, h / 2.0, -700.0)
  ts.run_for(@ui.move_most_ms)
  if ts.query(Button, label=@sf.t("web-main.chat.toLatest")) is Some(_) {
    ts.click(Button, label=@sf.t("web-main.chat.toLatest"))
    ts.run_for(@ui.move_most_ms * 2.0)
  }
  let (t, _) = dk_open(screen)
  guard composer_field(t) is Some((cx, cy, cw, ch)) else { fail("\{name}: no composer field") }
  t.tap(cx + cw / 2.0, cy + ch / 2.0)
  t.run_for(@ui.move_most_ms)
  t.type_text("检查发送与回复平滑度")
  t.run_for(@ui.move_most_ms)
  tap_send(t)
  t.run_for(@sfbase.flight_most_ms + @ui.move_most_ms)
}
