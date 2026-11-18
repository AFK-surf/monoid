// A station's machine as a list shows it (station_net_node.mbt): a figure in its level's ink, the network line in both
// looks (its speeds under the rest where the line has not the room; a made-up one while none is read), and a card of
// the list (its mark and chevron on its first line, what is said of it from where its name starts, pressed open).

///|
/// A window with keyboard and mouse holding what `make` makes in a box `w` wide, what its round trip is called said
/// as the app's Chinese says it.
fn net_case(make : (@view.View) -> Unit, w? : Double = 360.0) -> @ui.Tester {
  presenters_reset()
  set_words(fn(key, args) {
    match key {
      "android-settings.stations.rtt" => "当前延迟 "
      "web-pages.stations.latency" => "当前延迟 " + args.get(0).map(fn(a) { a.1 }).unwrap_or("")
      _ => key
    }
  })
  let t = @ui.Tester::new(fn(_c) {  }, w=600.0, h=400.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.width(Is(Some(w))) |> ignore
      make(b)
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// A connection as the core says it: relayed, some packets lost, its round trip running high.
let net_said : Json = Json::object({
  "path": "中继",
  "loss": { "text": "3%", "level": "amber" },
  "rtt": { "text": "420 ms", "level": "red" },
  "up": "1.2 KB/s",
  "down": "36 KB/s",
})

///|
test "a figure's ink is its level's: the warning's for amber, the danger's for red, the words' else" {
  let base = @ui.text_style(size=Meta, color=Fg)
  assert_eq(level_figure_style("ok", base).base.color, base.base.color)
  assert_eq(level_figure_style("amber", base).base.color, Some(WarnInk))
  assert_eq(level_figure_style("red", base).base.color, Some(Danger))
}

///|
test "a card's network line: how it goes and its figures on the left, ↑ and ↓ on the right of one line" {
  let t = net_case(fn(b) { station_net_line_node(b, fn() { Some(net_said) }) })
  for w in ["中继", "3%", "420 ms", "↑", "1.2 KB/s", "↓", "36 KB/s"] {
    assert_true(t.rect_of(w) is Some(_), msg=w)
  }
  let (px, py, _, ph) = t.rect_of("中继").unwrap()
  let (ux, uy, _, uh) = t.rect_of("↑").unwrap()
  assert_true(ux > px, msg="↑ right of how it goes")
  assert_eq(py + ph / 2.0, uy + uh / 2.0)
  assert_eq(t.audit(), [])
}

///|
test "a network line short of room puts its speeds under the rest, the figures whole, in either look" {
  for each in [(Card, "Card"), (Peek, "Peek"), (Page, "Page")] {
    let (look, name) = each
    let t = net_case(fn(b) { station_net_line_node(b, fn() { Some(net_said) }, look~) }, w=170.0)
    let (_, py, _, ph) = t.rect_of("中继").unwrap()
    let (_, uy, _, _) = t.rect_of("↑").unwrap()
    assert_true(uy >= py + ph, msg="\{name}: ↑ at \{uy}, the path's line ends at \{py + ph}")
    assert_true(t.rect_of("420 ms") is Some(_), msg=name)
    assert_true(t.rect_of("36 KB/s") is Some(_), msg=name)
  }
}

///|
test "a network line not read yet is the made-up one, as tall as a real one" {
  let real = net_case(fn(b) { station_net_line_node(b, fn() { Some(net_said) }, look=Peek) })
  let (_, _, _, rh) = real.rect_of("中继").unwrap()
  let t = net_case(fn(b) { station_net_line_node(b, fn() { None }, look=Peek) })
  let (_, _, _, sh) = t.rect_of("直连").unwrap()
  assert_eq(rh, sh)
  assert_true(t.rect_of("0 ms") is Some(_))
  assert_true(t.rect_of("0.0 KB/s") is Some(_))
}

///|
test "a machine's card: its mark and chevron on its name's line, what is said of it from where its name starts, pressed open" {
  let pressed = @signals.signal(0)
  let t = net_case(fn(b) {
    summary_mark_card_node(
      b,
      fn(m) { icon_node(m, "server", summary_mark_side, By(fn() { theme().p.text })) |> ignore },
      fn() { "studio" },
      fn() { "3 个会话在跑 · 2 个任务排队，还有一个很长的说明，要折到第二行才放得下" },
      fn() { pressed.set(pressed.get() + 1) },
      tag=fn() { "本机" },
    )
  })
  let (nx, ny, _, nh) = t.rect_of("studio").unwrap()
  let (sx, sy, _, _) = t.rect_of("3 个会话在跑 · 2 个任务排队，还有一个很长的说明，要折到第二行才放得下").unwrap()
  assert_eq(sx, nx)
  assert_true(sy >= ny + nh)
  assert_true(t.rect_of("本机") is Some(_))
  t.tap(nx + 2.0, ny + nh / 2.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(pressed.get(), 1)
  assert_eq(t.audit(), [])
}
