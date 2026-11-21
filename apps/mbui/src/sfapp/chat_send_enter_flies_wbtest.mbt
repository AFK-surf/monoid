// A chat's page made with its inside nodes (sfbase's chat_page_nodes on): words sent with Enter fly to their bubble
// from where they were typed, as words sent with the send button do (the user, 2026-11-17: 「chat 新架构大屏发消息没有
// 动效」: Enter sent as the composer's old view was built, where nothing batches what is set, and where the words stood
// was said after their row was in the list, its bubble made first and come in at its place; now where they stood is
// part of what is sent, sent_local's `from`, kept before the row is in the list). On 大屏 and 中屏, where Enter sends.

///|
let csef_words : String = "发布前再看一眼签名"

///|
/// Where the sent words are drawn a quarter of their way after they are sent with `send`, and where they rest (their
/// left edges: they go across first, from where they were typed at the field's start to the column's other side).
fn csef_way(screen : (String, Double, Double, Int), send : (@ui.Tester) -> Unit) -> (Double, Double) {
  let (name, w, h, platform) = screen
  new_run()
  let src = fixture("chat")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~)
  nav_rested(t)
  files_page_over(t, w, h)
  t.run_for(@ui.move_most_ms)
  guard composer_field(t) is Some((fx, fy, fw, fh)) else { @halt.saying("\{name}: no composer's field") }
  t.tap(fx + fw / 2.0, fy + fh / 2.0)
  t.type_text(csef_words)
  send(t)
  t.run_for(@sfbase.flight_desk_ms * 0.25)
  guard t.rect_of(csef_words) is Some((early, _, _, _)) else { @halt.saying("\{name}: the words not seen on their way") }
  t.run_for(@sfbase.flight_desk_ms * 2.0)
  guard t.rect_of(csef_words) is Some((rest_x, _, _, _)) else { @halt.saying("\{name}: the words not in the list") }
  (early, rest_x)
}

///|
test "words sent with Enter fly from the field as with the send button" {
  let screens : Array[(String, Double, Double, Int)] = [("大屏", 1280.0, 800.0, 0), ("中屏", 900.0, 760.0, 0)]
  for screen in screens {
    let (by_button, rest_b) = csef_way(screen, fn(t) { tap_send(t) })
    let (by_enter, rest_e) = csef_way(screen, fn(t) { t.key(@ui.key_code_enter) })
    let name = screen.0
    // (a quarter of the way: still well left of where they rest, flying across from the field, either way)
    assert_true(rest_b - by_button > 40.0, msg="\{name} button: at \{by_button}, resting at \{rest_b}")
    assert_true(rest_e - by_enter > 40.0, msg="\{name} Enter: at \{by_enter}, resting at \{rest_e}")
  }
}
