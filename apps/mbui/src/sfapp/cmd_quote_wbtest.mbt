// Experimental feature: 按住 ⌘/Ctrl 点击引用文本 (cmdQuote).
// While enabled and ⌘ (Ctrl on Windows/Linux) is held, hovering over message text highlights and underlines the
// sentence under the pointer with a hand cursor, and clicking it quotes that sentence directly into the composer.

///|
fn cmd_quote_rect_counts(t : @ui.Tester) -> (Int, Int) {
  let accent = @sf.theme().p.accent
  let tint = (accent & 0xFFFFFF00L) | 0x26L
  let line = (accent & 0xFFFFFF00L) | 0xE6L
  let mut tints = 0
  let mut lines = 0
  for r in t.drawn_rects() {
    if r.4 == tint {
      tints = tints + 1
    } else if r.4 == line {
      lines = lines + 1
    }
  }
  (tints, lines)
}

///|
test "cmdQuote: off by default does not highlight or quote; turning it on draws tint+underline with hand cursor, quotes on click, deduplicates, and clears on release" {
  let (t, src) = exp_at("chat", 1280.0, 800.0, platform=0)
  let draft = "ws1/st1:s-c1"
  let para = "高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？"
  guard t.rect_of(para) is Some((rx, ry, _, _)) else {
    fail("no target message drawn: " + t.words().map(fn(x) { x.0 }).join("|"))
  }
  let (px, py) = (rx + 30.0, ry + 8.0)

  // Off by default: Cmd+hover draws no highlight/underline and Cmd+click adds no quote.
  t.hold_mods(@ui.mod_cmd)
  t.move_to(px, py)
  t.run_for(cmd_quote_step_ms)
  assert_eq(cmd_quote_rect_counts(t), (0, 0), msg="off by default: no highlight or underline drawn")
  t.press_at(px, py)
  t.release(px, py)
  t.run_for(cmd_quote_step_ms)
  assert_eq(@sfbase.writing(src, draft).quotes.get().length(), 0, msg="off by default: no quote added")

  // Turn on experimental switch cmdQuote.
  t.hold_mods(0)
  exp_set(t, src, ["cmdQuote"], true)
  assert_true(@sfbase.cmd_quote_feature.get(), msg="cmdQuote signal on")

  // Hold Cmd and hover over the first sentence: actually paints tint + underline rects and sets Hand cursor.
  t.hold_mods(@ui.mod_cmd)
  t.move_to(px, py)
  t.run_for(cmd_quote_step_ms)
  let (tints, lines) = cmd_quote_rect_counts(t)
  assert_true(tints >= 1 && lines >= 1, msg="highlight tint (\{tints}) and underline (\{lines}) painted on Cmd+hover")
  assert_eq(t.cursor(), @view.Cursor::Hand, msg="hand cursor while Cmd-hovering sentence")

  // Releasing Cmd while still hovering over the sentence clears highlight+underline and restores IBeam cursor.
  t.hold_mods(0)
  t.run_for(cmd_quote_step_ms)
  assert_eq(cmd_quote_rect_counts(t), (0, 0), msg="releasing Cmd clears highlight and underline")
  assert_eq(t.cursor(), @view.Cursor::IBeam, msg="releasing Cmd restores IBeam cursor")

  // Hold Cmd again and click: adds that exact sentence as a quote in the composer.
  t.hold_mods(@ui.mod_cmd)
  t.run_for(cmd_quote_step_ms)
  t.press_at(px, py)
  t.release(px, py)
  t.run_for(@ui.move_most_ms)
  let quotes = @sfbase.writing(src, draft).quotes.get()
  assert_eq(quotes.length(), 1, msg="one quote added on Cmd+click")
  assert_eq(text(Some(quotes[0]), "text"), "高度先按 90 估", msg="quoted the hovered clause up to the comma")

  // Rapid second Cmd+click on the same sentence deduplicates.
  guard t.rect_of(para) is Some((rx2, ry2, _, _)) else {
    fail("target message disappeared after quote")
  }
  t.move_to(rx2 + 30.0, ry2 + 8.0)
  t.press_at(rx2 + 30.0, ry2 + 8.0)
  t.release(rx2 + 30.0, ry2 + 8.0)
  t.run_for(cmd_quote_step_ms)
  assert_eq(@sfbase.writing(src, draft).quotes.get().length(), 1, msg="duplicate Cmd+click deduplicated")
  t.hold_mods(0)
  t.run_for(cmd_quote_step_ms)
  assert_eq(cmd_quote_rect_counts(t), (0, 0), msg="final Cmd release clears highlight")
}

///|
test "cmdQuote: on Windows/Linux (platform=3), Ctrl triggers highlight and click-to-quote" {
  let (t, src) = exp_at("chat", 1280.0, 800.0, platform=3)
  let draft = "ws1/st1:s-c1"
  exp_set(t, src, ["cmdQuote"], true)
  let para = "高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？"
  guard t.rect_of(para) is Some((rx, ry, _, _)) else {
    fail("no target message drawn")
  }
  let (px, py) = (rx + 30.0, ry + 8.0)
  t.hold_mods(@ui.mod_ctrl)
  t.move_to(px, py)
  t.run_for(cmd_quote_step_ms)
  let (tints, lines) = cmd_quote_rect_counts(t)
  assert_true(tints >= 1 && lines >= 1, msg="Ctrl+hover paints highlight (\{tints}) and underline (\{lines})")
  t.press_at(px, py)
  t.release(px, py)
  t.run_for(@ui.move_most_ms)
  let quotes = @sfbase.writing(src, draft).quotes.get()
  assert_eq(quotes.length(), 1, msg="Ctrl+click quotes hovered sentence")
  assert_eq(text(Some(quotes[0]), "text"), "高度先按 90 估")
}

///|
test "cmdQuote: manually selected text shows underline when Cmd is pressed (even with cursor away) and quotes on Cmd+click" {
  let (t, src) = exp_at("chat", 1280.0, 800.0, platform=0)
  let draft = "ws1/st1:s-c1"
  exp_set(t, src, ["cmdQuote"], true)
  let para = "高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？"
  guard t.rect_of(para) is Some((rx, ry, _, _)) else {
    fail("no target message drawn")
  }
  let y = ry + 8.0
  // Manually drag-select a custom substring without holding Cmd.
  t.press_at(rx + 20.0, y)
  t.move_to(rx + 120.0, y)
  t.release(rx + 120.0, y)
  t.run_for(cmd_quote_step_ms)
  // Move cursor away from the text.
  t.move_to(rx + 20.0, ry + 200.0)
  t.run_for(cmd_quote_step_ms)
  assert_eq(cmd_quote_rect_counts(t).1, 0, msg="no underline before pressing Cmd")

  // Press Cmd: manually selected text immediately shows the underline even though cursor is away.
  t.hold_mods(@ui.mod_cmd)
  t.run_for(cmd_quote_step_ms)
  assert_true(cmd_quote_rect_counts(t).1 >= 1, msg="manual selection shows underline when Cmd is pressed")

  // Release Cmd: underline disappears while selection remains.
  t.hold_mods(0)
  t.run_for(cmd_quote_step_ms)
  assert_eq(cmd_quote_rect_counts(t).1, 0, msg="releasing Cmd clears manual selection underline")

  // Press Cmd and click on the manually selected text: quotes the selected substring.
  t.hold_mods(@ui.mod_cmd)
  t.move_to(rx + 60.0, y)
  t.run_for(cmd_quote_step_ms)
  t.press_at(rx + 60.0, y)
  t.release(rx + 60.0, y)
  t.run_for(@ui.move_most_ms)
  let quotes = @sfbase.writing(src, draft).quotes.get()
  assert_eq(quotes.length(), 1, msg="Cmd+click on manual selection quotes it")
  assert_true(text(Some(quotes[0]), "text") != "", msg="quoted text is non-empty")
  assert_true(text(Some(quotes[0]), "text").length() < "高度先按 90 估，量过一次就记住。".length(), msg="quoted custom substring rather than full sentence")
}

///|
/// A frame or two past a pointer move or a modifier change, for what it shows to be drawn.
let cmd_quote_step_ms : Double = 50.0
