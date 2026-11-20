// The side panel opened and shut beside a chat's page made as nodes on 大屏, its column laid out anew across
// chat_narrow_w as the panel sets off (sfdesk's side_narrower): someone's message's head and picture going across
// between out in the margin and over the head's start with the column, never a step of their own in the frame the
// column sets off (sfpages' message_inline_by; 2026-11-17: its name and time 25 across in that frame, each way).

///|
/// Where the frames a host draws (60 a second, check_looks(false), its rows on the device's pixels) of the side panel
/// opened beside the chat, words sent, and the panel shut put the agent's name over its last words (「做完了…」), and
/// those words: each frame's (moment, the name's x, the words' x), where both are seen.
fn panel_way_heads() -> Array[(Double, Double, Double)] {
  new_run()
  @sfbase.hold_chat_page_nodes(Some(true))
  let src = fixture_app("chat", chat_nodes=true)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0, words_over_held=false)
  t.check_looks(false)
  t.set_rows_on_pixels(true)
  t.set_frame_period(1000.0 / 60.0)
  let body = "做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。"
  let out : Array[(Double, Double, Double)] = []
  t.drive(
    "timeout 20000\nuntil 发消息\nwait 600\ntap icon:panel-open\nwait 1200\ntap 发消息\nwait 500\ntype 面板开着也发一条\nwait 600\ntap icon:arrow-up\nwait 2200\ntap icon:panel-close\nwait 1500\nexit\n",
    each=fn(t) {
      let words = t.words()
      match words.iter().find_first(fn(w) { w.0 == body && w.5 > 0.5 }) {
        Some(b) => {
          // (its message's name: the 「Claude」 nearest over its words)
          let mut name : (Double, Double)? = None
          for w in words {
            if w.0 == "Claude" && w.5 > 0.5 && w.2 < b.2 && b.2 - w.2 < 60.0 {
              match name {
                Some((_, y)) if y >= w.2 => ()
                _ => name = Some((w.1, w.2))
              }
            }
          }
          match name {
            Some((x, _)) => out.push((t.time(), x, b.1))
            None => ()
          }
        }
        None => ()
      }
    },
  )
  |> ignore
  out
}

///|
/// How far apart a head's step and its words' step may be in one frame on the column's way: the head goes as far more
/// as it is drawn further in past the picture (message_head_in, 25) over the frames of the panel's way, never in one.
let panel_head_step_most : Double = 8.0

///|
test "大屏: the side panel opened and shut, someone's message's name goes with its words, never a step of its own as the column is laid out anew" {
  if @ui.test_at_a_rate() {
    return
  }
  let heads = panel_way_heads()
  assert_true(heads.length() > 200, msg="frames with the message seen: \{heads.length()}")
  let steps = []
  for i in 1..<heads.length() {
    let (at, nx, bx) = heads[i]
    let (_, nx0, bx0) = heads[i - 1]
    let off = (nx - nx0) - (bx - bx0)
    if off.abs() > panel_head_step_most {
      steps.push("@\{at.round()}: name \{nx0} → \{nx}, words \{bx0} → \{bx}")
    }
  }
  assert_eq(steps, [])
  // (and where it rests, as wide as the column is laid out once each way is over: inline beside the panel, the name in
  // past the picture, 25 more than its words; out in the margin with it shut, at its words' start)
  let (_, nx, bx) = heads[heads.length() - 1]
  assert_true((nx - bx).abs() < 0.5, msg="at rest, the panel shut: name at \{nx}, words at \{bx}")
}
