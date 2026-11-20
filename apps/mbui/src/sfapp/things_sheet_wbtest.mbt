// The chat's things on 小屏 (open_things): a sheet whose body is nodes (@sfpages.things_node), held to what its old
// body (things_body, gone 2026-11-15 as the tab beside the chat was made of nodes too) drew in the host's sheet of the
// same panel, kept as it was then: where each of their words is drawn, the kinds' choice pressed where it is drawn, and
// 在对话中查看 closing it.

///|
/// A chat of the made-up core's, open on a phone.
fn things_chat() -> (@ui.Tester, Source, ChatRef) {
  new_run()
  let src = fixture("chat")
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(@ui.move_most_ms)
  (t, src, r)
}

///|
/// The words drawn in the window's lower `share` (where a sheet that tall is): each, where it is (to half a point) and how
/// big, in the order of where they are.
fn words_below(t : @ui.Tester, share : Double) -> Array[(String, Double, Double, Double, Double)] {
  let half = fn(x : Double) { (x * 2.0).round() / 2.0 }
  let top = 844.0 * (1.0 - share)
  let out = t.words().filter(fn(w) { w.2 >= top && w.5 > 0.0 }).map(fn(w) { (w.0, half(w.1), half(w.2), half(w.3), half(w.4)) })
  out.sort_by(fn(a, b) { if a.2 != b.2 { a.2.compare(b.2) } else if a.1 != b.1 { a.1.compare(b.1) } else { a.0.compare(b.0) } })
  out
}

///|
/// How much of the window the things' sheet takes (open_things's `tall`).
let things_share : Double = 0.8

///|
/// The things' sheet opened by `open` on `kind`: the words it shows; then its 文件 pressed where it is drawn, the words it
/// shows then; closed by Escape and gone.
fn things_seen(t : @ui.Tester, r : ChatRef, open : () -> Unit) -> (Array[(String, Double, Double, Double, Double)], Array[(String, Double, Double, Double, Double)]) raise {
  @sfpages.things_choose(r, "media")
  open()
  t.run_for(sheet_way_ms(t))
  let first = words_below(t, things_share)
  t.tap_text("文件 2")
  t.run_for(@ui.move_most_ms)
  let files = words_below(t, things_share)
  t.key(@ui.key_escape)
  t.run_for(sheet_way_ms(t))
  assert_false(@sf.presenting(), msg="closed")
  (first, files)
}

///|
test "小屏: the chat's things, a sheet whose body is nodes: each of its words where the host's sheet of its old body has it; 文件 pressed where it is drawn: its files, where the old one's are" {
  let (t, src, r) = things_chat()
  let (first, files) = things_seen(t, r, fn() { open_things(src, r, 7.0) })
  assert_true(first.iter().any(fn(w) { w.0 == "媒体 4" }), msg="the kinds' choice")
  debug_inspect(first, content=(
    
    #|[
    #|  ("等 林 决定", 16, 197.5, 65, 18),
    #|  ("图片、文件和链接", 24, 198, 128, 24),
    #|  ("先不换", 63, 236.5, 293, 22),
    #|  ("媒体 4", 46, 251.5, 45, 21),
    #|  ("文件 2", 130.5, 251.5, 45, 21),
    #|  ("链接 2", 215, 251.5, 45, 21),
    #|  ("PR 4", 307, 251.5, 30, 21),
    #|  ("这次只改列表，截图下次再说", 63, 258.5, 293, 18),
    #|  ("一起换", 63, 290.5, 293, 22),
    #|  ("筛选", 40, 295, 310, 22),
    #|  ("把首页和聊天页的截图都更新", 63, 312.5, 293, 18),
    #|  ("今天", 24, 348, 30, 22),
    #|  ("忽略", 16, 351.5, 26, 18),
    #|  ("19:20 · Claude", 24, 384, 91, 18),
    #|  ("列表高度改前改后", 123, 384, 104, 18),
    #|  ("Willow 上 codex 的登录已失效：请在设置里重新登录", 39, 395.5, 312, 22),
    #|  ("Claude", 41, 446.5, 39, 18),
    #|  ("15 分钟前", 86, 446.5, 54, 18),
    #|  ("推送截图前要先登录 gh。", 16, 471.5, 358, 23),
    #|  ("在 Willow 上登录 gh", 34, 525, 322, 18),
    #|  ("等你在浏览器里登录", 34, 545, 117, 18),
    #|  ("17:05 · Claude", 24, 554, 91, 18),
    #|  ("录了一段滑动", 123, 554, 78, 18),
    #|  ("Claude", 41, 604, 39, 18),
    #|  ("5 分钟前", 86, 604, 48, 18),
    #|  ("做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。", 16, 629, 358, 46),
    #|  ("0:12", 61, 680, 24, 16),
    #|  ("昨天", 24, 730, 30, 22),
    #|  ("22:40 · Ana", 24, 766, 71.5, 18),
    #|  ("发消息", 53, 797.5, 276, 25),
    #|]
  ))
  assert_true(files.iter().any(fn(w) { w.0 == "build.log" }), msg="its files")
  assert_false(files.iter().any(fn(w) { w.0 == "列表高度改前改后" }), msg="its pictures' words gone")
  debug_inspect(files, content=(
    
    #|[
    #|  ("等 林 决定", 16, 197.5, 65, 18),
    #|  ("图片、文件和链接", 24, 198, 128, 24),
    #|  ("先不换", 63, 236.5, 293, 22),
    #|  ("媒体 4", 46, 251.5, 45, 21),
    #|  ("文件 2", 130.5, 251.5, 45, 21),
    #|  ("链接 2", 215, 251.5, 45, 21),
    #|  ("PR 4", 307, 251.5, 30, 21),
    #|  ("这次只改列表，截图下次再说", 63, 258.5, 293, 18),
    #|  ("一起换", 63, 290.5, 293, 22),
    #|  ("筛选", 40, 295, 310, 22),
    #|  ("把首页和聊天页的截图都更新", 63, 312.5, 293, 18),
    #|  ("build.log", 58, 344, 67.5, 22),
    #|  ("忽略", 16, 351.5, 26, 18),
    #|  ("18 KB · Claude · 1 小时前", 58, 368, 162.5, 18),
    #|  ("Willow 上 codex 的登录已失效：请在设置里重新登录", 39, 395.5, 312, 22),
    #|  ("性能报告.pdf", 58, 404, 90, 22),
    #|  ("1.0 MB · Claude · 2 小时前", 58, 428, 169, 18),
    #|  ("Claude", 41, 446.5, 39, 18),
    #|  ("15 分钟前", 86, 446.5, 54, 18),
    #|  ("推送截图前要先登录 gh。", 16, 471.5, 358, 23),
    #|  ("在 Willow 上登录 gh", 34, 525, 322, 18),
    #|  ("等你在浏览器里登录", 34, 545, 117, 18),
    #|  ("Claude", 41, 604, 39, 18),
    #|  ("5 分钟前", 86, 604, 48, 18),
    #|  ("做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。", 16, 629, 358, 46),
    #|  ("发消息", 53, 797.5, 276, 25),
    #|]
  ))
}

///|
test "小屏: the chat's things whose body is nodes: a file's 在对话中查看 closes the sheet, the chat at its message; the field finds among its kind's" {
  let (t, src, r) = things_chat()
  @sfpages.things_choose(r, "files")
  open_things(src, r, 7.0)
  t.run_for(sheet_way_ms(t))
  assert_true(t.find("性能报告.pdf") is Some(_), msg="its files")
  // (the field: what is typed finds among them)
  t.tap_text(@sf.t("web-main.things.find"))
  t.type_text("build")
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("build.log") is Some(_), msg="found")
  assert_true(t.find("性能报告.pdf") is None, msg="the rest not")
  let shows = t.all(Button, label=@sf.t("web-main.things.show")).filter(fn(s) { s.rect.1 >= 844.0 * (1.0 - things_share) })
  assert_true(shows.length() > 0, msg="在对话中查看 on its row")
  let (x, y, w, h) = shows[0].rect
  t.tap(x + w / 2.0, y + h / 2.0)
  t.run_for(sheet_way_ms(t))
  assert_false(@sf.presenting(), msg="closed")
}

///|
/// What a finger held on a file's row (`name`) of the things' sheet opened by `open` does, as it is held, let go and
/// its menu closed: what it is felt as (the haptics, from the hold on), where the row is drawn lit (the theme's Hover,
/// to half a point) while it is held and while its menu is open once let go, whether its menu opened, and the sheet
/// stepped back under it: where the row's words were drawn at rest, where they are drawn then and what of the sheet's
/// scrim is drawn over them.
fn things_held_seen(t : @ui.Tester, r : ChatRef, name : String, open : () -> Unit) -> (Array[@ui.Haptic], Array[(Double, Double, Double, Double)], Array[(Double, Double, Double, Double)], Bool, (Double, Array[(Double, Double)], Array[(Double, Double, Double, Double)])) raise {
  @sfpages.things_choose(r, "files")
  open()
  t.run_for(sheet_way_ms(t))
  let at = t.words().filter(fn(w) { w.0 == name && w.2 >= 844.0 * (1.0 - things_share) })
  guard at is [(_, x, y, w, h, _), ..] else { fail("\{name}: not drawn") }
  let (px, py) = (x + w / 2.0, y + h / 2.0)
  let half = fn(v : Double) { (v * 2.0).round() / 2.0 }
  let lit = fn() {
    let hover = @ui.tree_theme().color(Hover)
    t
    .drawn_rects()
    .filter(fn(b) { b.4 == hover && b.0 <= px && px <= b.0 + b.2 && b.1 <= py && py <= b.1 + b.3 })
    .map(fn(b) { (half(b.0), half(b.1), half(b.2), half(b.3)) })
  }
  let felt = t.haptics().length()
  t.press_at(px, py)
  t.run_for(@ui.long_press_ms + @ui.move_most_ms)
  let held = lit()
  t.release(px, py)
  t.run_for(@ui.move_most_ms)
  let menu_lit = lit()
  // (its menu's 在对话中查看 in words: the row's own is its icon alone)
  let menu = t.words().iter().any(fn(w) { w.0 == @sf.t("web-main.things.show") && w.5 > 0.0 })
  let haptics = t.haptics()[felt:].to_owned()
  // (the sheet under the menu: pushed back, its row's words where they are then, and dimmed, the scrim drawn over them)
  let pushed = t.words().filter(fn(w) { w.0 == name }).map(fn(w) { (half(w.1), half(w.2)) })
  let dimmed = match pushed {
    [(wx, wy), ..] =>
      t
      .drawn_rects()
      .filter(fn(b) { b.4 == @sf.sheet_scrim && b.0 <= wx && wx <= b.0 + b.2 && b.1 <= wy && wy <= b.1 + b.3 })
      .map(fn(b) { (half(b.0), half(b.1), half(b.2), half(b.3)) })
    [] => []
  }
  // (its menu closed, then the sheet)
  t.key(@ui.key_escape)
  t.run_for(sheet_way_ms(t))
  t.key(@ui.key_escape)
  t.run_for(sheet_way_ms(t))
  assert_false(@sf.presenting(), msg="closed")
  (haptics, held, menu_lit, menu, (half(y), pushed, dimmed))
}

///|
test "小屏: the chat's things whose body is nodes: a file's row held by a finger is felt, lit and its menu opened as the old body's is, held and with its menu open, the sheet behind it pushed back and dimmed" {
  let (t, src, r) = things_chat()
  let now = things_held_seen(t, r, "build.log", fn() { open_things(src, r, 7.0) })
  assert_true(now.3, msg="its menu opened")
  // (the sheet behind it pushed back and dimmed: its row up from where it was, the scrim over it)
  assert_true(now.4.1.length() > 0 && now.4.1[0].1 < now.4.0, msg="pushed back: \{Repr(now.4)}")
  assert_true(now.4.2.length() > 1, msg="dimmed over itself: \{Repr(now.4)}")
  // (felt, lit while held and while its menu is open, pushed back and dimmed: as the old body's was)
  debug_inspect(now, content=(
    
    #|(
    #|  [LongPress],
    #|  [],
    #|  [],
    #|  true,
    #|  (344, [(58, 199)], [(0, 0, 390, 844), (0, 24, 390, 717)]),
    #|)
  ))
}

///|
/// The first frames drawn here (grab_first's pictures, `mem:pv-first/…`), each where it is drawn (to half a point).
fn things_firsts_drawn(t : @ui.Tester) -> Array[(String, Double, Double, Double, Double)] {
  let half = fn(v : Double) { (v * 2.0).round() / 2.0 }
  t
  .drawn_instances()
  .filter_map(fn(i) {
    let k = if i[5] == 4.0 && i[11] > 0.0 { t.image_src(i[20].to_int()) } else { "" }
    if k.has_prefix("mem:pv-first/") {
      Some((k, half(i[0]), half(i[1]), half(i[2]), half(i[3])))
    } else {
      None
    }
  })
}

///|
/// The things' sheet opened by `open` on its pictures and videos where the station made no still of its video: the
/// grabs of a frame its players were asked (by view: `control N 21 …`), then, the first answered with `frame`, the
/// first frames drawn; closed.
fn things_first_seen(t : @ui.Tester, r : ChatRef, frame : Bytes, open : () -> Unit) -> (Int, Array[(String, Double, Double, Double, Double)]) raise {
  @sfbase.pv_first.clear()
  @sfpages.things_choose(r, "media")
  let before = t.views().length()
  open()
  t.run_for(sheet_way_ms(t))
  let grabs = t
    .views()[before:]
    .to_owned()
    .filter_map(fn(l) {
      match l.split(" ").map(fn(p) { p.to_owned() }).to_array() {
        ["control", view, "21", ..] => Some(view)
        _ => None
      }
    })
  guard grabs is [view, ..] else { fail("no frame asked of a player: \{Repr(t.views())}") }
  assert_true(t.view_said("{\"still\":{\"view\":\{view}},\"b\":\"\{hex_bytes(frame)}\"}"), msg="answered")
  t.run_for(@ui.move_most_ms)
  let drawn = things_firsts_drawn(t)
  t.key(@ui.key_escape)
  t.run_for(sheet_way_ms(t))
  assert_false(@sf.presenting(), msg="closed")
  (grabs.length(), drawn)
}

///|
test "小屏: the chat's things whose body is nodes: a video the station made no still of shows its first frame drawn here, as the old body's tile does: a frame asked of a player of it, shown where the old one's is once the host answers" {
  let (t, base, r) = things_chat()
  let src : Source = { ..base, poster: fn(_, _, _) { "!" } }
  let frame = fixture_file_png("演示录屏.mp4")
  let now = things_first_seen(t, r, frame, fn() { open_things(src, r, 7.0) })
  assert_true(now.0 > 0 && now.1.length() > 0, msg="its first frame: \{Repr(now)}")
  debug_inspect(now, content=(
    
    #|(
    #|  1,
    #|  [("mem:pv-first/5789003989113648266/31/演示录屏.mp4", 24, 578, 242, 136)],
    #|)
  ))
}

///|
/// The chat's things open on a phone used with a mouse (an iPad's, a narrow window's): what shows a link's card. Its
/// pictures (`link.preview.picture`) as `pictures` has them by the link's address and which, its type PNG.
fn things_chat_mouse(previews? : Map[String, Json] = {}, pictures? : Map[String, Bytes] = {}) -> (@ui.Tester, Source, ChatRef) {
  new_run()
  let base = fixture("chat")
  // (a link's card as `previews` has it by its address, where it has one: the made-up core's otherwise)
  let src : Source = {
    ..base,
    topic_read: fn(name, params) {
      let got = base.topic(name, params).get().snapshot()
      match previews.get(text(Some(Json::object(params)), "url")) {
        Some(v) if name == "linkPreview" => { ..got, value: Some(v) }
        _ => got
      }
    },
    read_bytes: fn(name, params, done) {
      match pictures.get(text(Some(params), "url") + "\u{1}" + text(Some(params), "which")) {
        Some(b) if name == "link.preview.picture" => done(Ok(({ "type": "image/png" }, b)))
        _ => (base.read_bytes)(name, params, done)
      }
    },
  }
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  open_chat(r)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2, pointing=Mouse)
  t.run_for(@ui.move_most_ms)
  (t, src, r)
}

///|
/// The things' sheet opened by `open` on `kind`, the pointer rested on its first row (`name`): the words its card
/// shows (those drawn then and not before, each where it is, to half a point, in the order of where they are); then
/// the pointer gone off it: whether the card went with it.
fn things_peek_seen(t : @ui.Tester, r : ChatRef, kind : String, name : String, open : () -> Unit) -> (Array[(String, Double, Double, Double, Double)], Bool) raise {
  @sfpages.things_choose(r, kind)
  open()
  t.run_for(sheet_way_ms(t))
  let before = words_below(t, 1.0)
  let at = t.words().filter(fn(w) { w.0 == name && w.2 >= 844.0 * (1.0 - things_share) })
  guard at is [(_, x, y, w, h, _), ..] else { fail("\{name}: not drawn: \{Repr(before)}") }
  t.move_to(x + w / 2.0, y + h / 2.0)
  t.run_for(@sfpages.hover_open_ms + @ui.move_most_ms)
  let card = words_below(t, 1.0).filter(fn(w) { !before.contains(w) })
  // (off the row, onto the sheet's head: gone)
  t.move_to(x + w / 2.0, 844.0 * (1.0 - things_share))
  t.run_for(@sfpages.hover_close_ms + @ui.move_most_ms)
  let gone = words_below(t, 1.0).filter(fn(w) { !before.contains(w) }).length() == 0
  t.key(@ui.key_escape)
  t.run_for(sheet_way_ms(t))
  assert_false(@sf.presenting(), msg="closed")
  (card, gone)
}

///|
test "小屏 with a mouse: the chat's things whose body is nodes: a link's row and a pull request's pointed at show its card (web_peek_node: the library's hover card, 8 in from the window's edges), each of its words, and it goes as the pointer leaves" {
  let (t, src, r) = things_chat_mouse()
  let seen = []
  for k in [("links", "列表滚动的性能数据"), ("pulls", "首页列表按天分组")] {
    let (kind, name) = k
    let now = things_peek_seen(t, r, kind, name, fn() { open_things(src, r, 7.0) })
    assert_true(now.0.length() > 0 && now.1, msg="\{kind}: its card, gone after: \{Repr(now)}")
    seen.push(now)
  }
  debug_inspect(seen, content=(
    
    #|[
    #|  (
    #|    [
    #|      ("列表滚动的性能数据", 68, 352, 208, 22),
    #|      ("Example · example.com/bench/list", 68, 375, 208, 18),
    #|      ("复制链接", 218, 403, 52, 20),
    #|    ],
    #|    true,
    #|  ),
    #|  (
    #|    [
    #|      ("已合并", 44, 411, 39, 18),
    #|      ("acme/shop #128", 99, 411, 91, 18),
    #|      ("3 小时前", 314, 411, 52, 18),
    #|      ("首页列表按天分组", 24, 438, 120, 22),
    #|      ("lin", 48, 469, 19.5, 18),
    #|      ("+120", 81.5, 469, 26, 18),
    #|      ("−8", 113.5, 469, 13, 18),
    #|      ("4 个文件", 146.5, 469, 52, 18),
    #|      ("复制链接", 308, 496, 52, 20),
    #|      ("检查通过 9", 30, 497, 65, 18),
    #|    ],
    #|    true,
    #|  ),
    #|]
  ))
}

///|
/// The card of the things' sheet's first row of `kind` (`name`) opened by `open`, the pointer onto it: what `seen`
/// sees of it (once it has had the time to open), then gone off it and the sheet closed.
fn things_card_seen(t : @ui.Tester, r : ChatRef, kind : String, name : String, open : () -> Unit, seen : (Double, Double) -> String) -> String raise {
  @sfpages.things_choose(r, kind)
  open()
  t.run_for(sheet_way_ms(t))
  let at = t.words().filter(fn(w) { w.0 == name && w.2 >= 844.0 * (1.0 - things_share) })
  guard at is [(_, x, y, w, h, _), ..] else { fail("\{name}: not drawn") }
  let (px, py) = (x + w / 2.0, y + h / 2.0)
  t.move_to(px, py)
  t.run_for(@sfpages.hover_open_ms + @ui.move_most_ms)
  let out = seen(px, py)
  t.move_to(px, 844.0 * (1.0 - things_share))
  t.run_for(@sfpages.hover_close_ms + @ui.move_most_ms)
  // (a card as tall as the window is still under the pointer: Escape shuts it first, then the sheet)
  for _ in 0..<2 {
    if @sf.presenting() {
      t.key(@ui.key_escape)
      t.run_for(sheet_way_ms(t))
    }
  }
  assert_false(@sf.presenting(), msg="closed")
  out
}

///|
/// Where each word drawn in the window is (to half a point), in the order of where they are: what a card shows, by
/// those drawn and not before.
fn things_words_drawn(t : @ui.Tester) -> Array[(String, Double, Double, Double, Double)] {
  words_below(t, 1.0).filter(fn(w) { w.2 >= 0.0 && w.2 < 844.0 })
}

///|
test "小屏 with a mouse: a link's card whose row is nodes waits for the hand to carry no press, as the old body's: none while a button is held down elsewhere and the pointer rests on its row; shown its time after it is let go" {
  let (t, src, r) = things_chat_mouse()
  let seen = fn(open : () -> Unit) -> (Bool, Bool) raise {
    @sfpages.things_choose(r, "links")
    open()
    t.run_for(sheet_way_ms(t))
    let at = t.words().filter(fn(w) { w.0 == "列表滚动的性能数据" && w.2 >= 844.0 * (1.0 - things_share) })
    guard at is [(_, x, y, w, h, _), ..] else { fail("the link's row: not drawn") }
    // (held down in the sheet's field, carried onto the row, rested there)
    let title = t.words().filter(fn(w) { w.0 == @sf.t("web-main.things.find") })
    guard title is [(_, tx, ty, tw, th, _), ..] else { fail("the sheet's field: not drawn") }
    t.press_at(tx + tw / 2.0, ty + th / 2.0)
    t.move_to(x + w / 2.0, y + h / 2.0)
    t.run_for(@sfpages.hover_open_ms + @ui.move_most_ms)
    let held = t.find(@sf.t("common.link.copy")) is Some(_)
    t.release(x + w / 2.0, y + h / 2.0)
    t.run_for(@sfpages.hover_open_ms + @ui.move_most_ms)
    let after = t.find(@sf.t("common.link.copy")) is Some(_)
    t.move_to(x + w / 2.0, 844.0 * (1.0 - things_share))
    t.run_for(@sfpages.hover_close_ms + @ui.move_most_ms)
    t.key(@ui.key_escape)
    t.run_for(sheet_way_ms(t))
    (held, after)
  }
  let now = seen(fn() { open_things(src, r, 7.0) })
  assert_eq(now, (false, true))
}

///|
/// A page's icon not square (the made-up still of 演示录屏.mp4, 16:9), as the core answers it (`link.preview.picture`):
/// what its card's square holds.
fn things_wide_icon() -> Bytes {
  fixture_file_png("演示录屏.mp4")
}

///|
test "小屏 with a mouse: a link's card whose row is nodes holds a page's icon not square in its square whole, as the old body's (FitContain): drawn where the old one's is, as big" {
  let page : Json = {
    "kind": "page",
    "url": "https://example.com/bench/list",
    "title": "列表滚动的性能数据",
    "site": "Example",
    "icon": "wide-icon",
  }
  let (t, src, r) = things_chat_mouse(previews={ "https://example.com/bench/list": page }, pictures={
    "https://example.com/bench/list\u{1}icon": things_wide_icon(),
  })
  // (its image's key, once its card asked it)
  let key = fn() { @sfbase.link_picture(src, r.station, "https://example.com/bench/list", Some(page), "icon") }
  let drawn = fn(_x : Double, _y : Double) { media_drawn(t, key()).map(fn(b) { "\{@ui.rect_text(b)}" }).join(" ") }
  let now = things_card_seen(t, r, "links", "列表滚动的性能数据", fn() { open_things(src, r, 7.0) }, drawn)
  assert_true(now != "", msg="its icon")
  debug_inspect(now, content=(
    #|"(30, 360.29999999999995, 20, 15)"
  ))
}

///|
/// An issue with more labels than a card as tall as the window holds (the test's).
let things_many_labels : Int = 120

///|
/// How far the wheel scrolls a card (points).
let things_card_wheel : Double = 300.0

///|
test "小屏 with a mouse: a link's card whose row is nodes taller than the window scrolls in it, as the old body's did (in_room), in the library's hover card: its words where they are, then wheeled on, where they go" {
  let issue : Json = {
    "kind": "github_issue",
    "url": "https://github.com/acme/shop/pull/128",
    "repository": "acme/shop",
    "number": 128,
    "title": "首页列表按天分组",
    "state": "open",
    "author": { "login": "lin" },
    "labels": Json::array(Array::makei(things_many_labels, fn(i) { Json::string("label \{i}") })),
    "time": { "updatedAt": { "at": 0, "ago": "3 小时前", "full": "10/26 09:00", "until": "", "past": true } },
  }
  let (t, src, r) = things_chat_mouse(previews={ "https://github.com/acme/shop/pull/128": issue })
  let seen = fn(open : () -> Unit) -> String raise {
    things_card_seen(t, r, "pulls", "首页列表按天分组", open, fn(_, _) {
      let shown = things_words_drawn(t).filter(fn(w) { w.0.has_prefix("label ") })
      // (wheeled on over the card, at its middle: its first label's line, as the card has it)
      let (lx, ly) = match shown {
        [(_, x, y, w, h), ..] => (x + w / 2.0, y + h / 2.0)
        _ => (0.0, 0.0)
      }
      t.move_to(lx, ly)
      t.wheel(lx, ly, things_card_wheel)
      t.run_for(@ui.move_most_ms)
      let wheeled = things_words_drawn(t).filter(fn(w) { w.0.has_prefix("label ") })
      "\{@ui.list_text(shown.map(fn(w) { "(\{w.0}, \{w.1}, \{w.2}, \{w.3}, \{w.4})" }))}\n\{@ui.list_text(wheeled.map(fn(w) { "(\{w.0}, \{w.1}, \{w.2}, \{w.3}, \{w.4})" }))}"
    })
  }
  let now = seen(fn() { open_things(src, r, 7.0) })
  assert_true(now.contains("label 0"), msg="its card")
  debug_inspect(now, content=(
    #|"[(label 0, 81.5, 81, 45.5, 18), (label 1, 147, 81, 45.5, 18), (label 2, 212.5, 81, 45.5, 18), (label 3, 28, 109, 45.5, 18), (label 4, 93.5, 109, 45.5, 18), (label 5, 159, 109, 45.5, 18), (label 6, 224.5, 109, 45.5, 18), (label 7, 28, 137, 45.5, 18), (label 8, 93.5, 137, 45.5, 18), (label 9, 159, 137, 45.5, 18), (label 10, 224.5, 137, 52, 18), (label 11, 28, 165, 52, 18), (label 12, 100, 165, 52, 18), (label 13, 172, 165, 52, 18), (label 14, 28, 193, 52, 18), (label 15, 100, 193, 52, 18), (label 16, 172, 193, 52, 18), (label 17, 28, 221, 52, 18), (label 18, 100, 221, 52, 18), (label 19, 172, 221, 52, 18), (label 20, 28, 249, 52, 18), (label 21, 100, 249, 52, 18), (label 22, 172, 249, 52, 18), (label 23, 28, 277, 52, 18), (label 24, 100, 277, 52, 18), (label 25, 172, 277, 52, 18), (label 26, 28, 305, 52, 18), (label 27, 100, 305, 52, 18), (label 28, 172, 305, 52, 18), (label 29, 28, 333, 52, 18), (label 30, 100, 333, 52, 18), (label 31, 172, 333, 52, 18), (label 32, 28, 361, 52, 18), (label 33, 100, 361, 52, 18), (label 34, 172, 361, 52, 18), (label 35, 28, 389, 52, 18), (label 36, 100, 389, 52, 18), (label 37, 172, 389, 52, 18), (label 38, 28, 417, 52, 18), (label 39, 100, 417, 52, 18), (label 40, 172, 417, 52, 18), (label 41, 28, 445, 52, 18), (label 42, 100, 445, 52, 18), (label 43, 172, 445, 52, 18), (label 44, 28, 473, 52, 18), (label 45, 100, 473, 52, 18), (label 46, 172, 473, 52, 18), (label 47, 28, 501, 52, 18), (label 48, 100, 501, 52, 18), (label 49, 172, 501, 52, 18), (label 50, 28, 529, 52, 18), (label 51, 100, 529, 52, 18), (label 52, 172, 529, 52, 18), (label 53, 28, 557, 52, 18), (label 54, 100, 557, 52, 18), (label 55, 172, 557, 52, 18), (label 56, 28, 585, 52, 18), (label 57, 100, 585, 52, 18), (label 58, 172, 585, 52, 18), (label 59, 28, 613, 52, 18), (label 60, 100, 613, 52, 18), (label 61, 172, 613, 52, 18), (label 62, 28, 641, 52, 18), (label 63, 100, 641, 52, 18), (label 64, 172, 641, 52, 18), (label 65, 28, 669, 52, 18), (label 66, 100, 669, 52, 18), (label 67, 172, 669, 52, 18), (label 68, 28, 697, 52, 18), (label 69, 100, 697, 52, 18), (label 70, 172, 697, 52, 18), (label 71, 28, 725, 52, 18), (label 72, 100, 725, 52, 18), (label 73, 172, 725, 52, 18), (label 74, 28, 753, 52, 18), (label 75, 100, 753, 52, 18), (label 76, 172, 753, 52, 18), (label 77, 28, 781, 52, 18), (label 78, 100, 781, 52, 18), (label 79, 172, 781, 52, 18), (label 80, 28, 809, 52, 18), (label 81, 100, 809, 52, 18), (label 82, 172, 809, 52, 18), (label 83, 28, 837, 52, 18), (label 84, 100, 837, 52, 18), (label 85, 172, 837, 52, 18)]\n[(label 26, 28, 5, 52, 18), (label 27, 100, 5, 52, 18), (label 28, 172, 5, 52, 18), (label 29, 28, 33, 52, 18), (label 30, 100, 33, 52, 18), (label 31, 172, 33, 52, 18), (label 32, 28, 61, 52, 18), (label 33, 100, 61, 52, 18), (label 34, 172, 61, 52, 18), (label 35, 28, 89, 52, 18), (label 36, 100, 89, 52, 18), (label 37, 172, 89, 52, 18), (label 38, 28, 117, 52, 18), (label 39, 100, 117, 52, 18), (label 40, 172, 117, 52, 18), (label 41, 28, 145, 52, 18), (label 42, 100, 145, 52, 18), (label 43, 172, 145, 52, 18), (label 44, 28, 173, 52, 18), (label 45, 100, 173, 52, 18), (label 46, 172, 173, 52, 18), (label 47, 28, 201, 52, 18), (label 48, 100, 201, 52, 18), (label 49, 172, 201, 52, 18), (label 50, 28, 229, 52, 18), (label 51, 100, 229, 52, 18), (label 52, 172, 229, 52, 18), (label 53, 28, 257, 52, 18), (label 54, 100, 257, 52, 18), (label 55, 172, 257, 52, 18), (label 56, 28, 285, 52, 18), (label 57, 100, 285, 52, 18), (label 58, 172, 285, 52, 18), (label 59, 28, 313, 52, 18), (label 60, 100, 313, 52, 18), (label 61, 172, 313, 52, 18), (label 62, 28, 341, 52, 18), (label 63, 100, 341, 52, 18), (label 64, 172, 341, 52, 18), (label 65, 28, 369, 52, 18), (label 66, 100, 369, 52, 18), (label 67, 172, 369, 52, 18), (label 68, 28, 397, 52, 18), (label 69, 100, 397, 52, 18), (label 70, 172, 397, 52, 18), (label 71, 28, 425, 52, 18), (label 72, 100, 425, 52, 18), (label 73, 172, 425, 52, 18), (label 74, 28, 453, 52, 18), (label 75, 100, 453, 52, 18), (label 76, 172, 453, 52, 18), (label 77, 28, 481, 52, 18), (label 78, 100, 481, 52, 18), (label 79, 172, 481, 52, 18), (label 80, 28, 509, 52, 18), (label 81, 100, 509, 52, 18), (label 82, 172, 509, 52, 18), (label 83, 28, 537, 52, 18), (label 84, 100, 537, 52, 18), (label 85, 172, 537, 52, 18), (label 86, 28, 565, 52, 18), (label 87, 100, 565, 52, 18), (label 88, 172, 565, 52, 18), (label 89, 28, 593, 52, 18), (label 90, 100, 593, 52, 18), (label 91, 172, 593, 52, 18), (label 92, 28, 621, 52, 18), (label 93, 100, 621, 52, 18), (label 94, 172, 621, 52, 18), (label 95, 28, 649, 52, 18), (label 96, 100, 649, 52, 18), (label 97, 172, 649, 52, 18), (label 98, 28, 677, 52, 18), (label 99, 100, 677, 52, 18), (label 100, 172, 677, 58.5, 18), (label 101, 28, 705, 58.5, 18), (label 102, 106.5, 705, 58.5, 18), (label 103, 185, 705, 58.5, 18), (label 104, 28, 733, 58.5, 18), (label 105, 106.5, 733, 58.5, 18), (label 106, 185, 733, 58.5, 18), (label 107, 28, 761, 58.5, 18), (label 108, 106.5, 761, 58.5, 18), (label 109, 185, 761, 58.5, 18), (label 110, 28, 789, 58.5, 18), (label 111, 106.5, 789, 58.5, 18), (label 112, 185, 789, 58.5, 18), (label 113, 28, 817, 58.5, 18), (label 114, 106.5, 817, 58.5, 18), (label 115, 185, 817, 58.5, 18)]"
  ))
}

///|
test "小屏 with a mouse: a link's card whose row is nodes, its address copied, says 已复制 as it is shown again within copied_ms, as the old body's (by the link); then 复制链接" {
  let (t, src, r) = things_chat_mouse()
  let seen = fn(open : () -> Unit) -> (Bool, Bool) raise {
    @sfpages.things_choose(r, "links")
    open()
    t.run_for(sheet_way_ms(t))
    let at = t.words().filter(fn(w) { w.0 == "列表滚动的性能数据" && w.2 >= 844.0 * (1.0 - things_share) })
    guard at is [(_, x, y, w, h, _), ..] else { fail("the link's row: not drawn") }
    let (px, py) = (x + w / 2.0, y + h / 2.0)
    t.move_to(px, py)
    t.run_for(@sfpages.hover_open_ms + @ui.move_most_ms)
    guard t.all(Button, label=@sf.t("common.link.copy")) is [b, ..] else { fail("its copy: not drawn") }
    let (bx, by, bw, bh) = b.rect
    t.move_to(bx + bw / 2.0, by + bh / 2.0)
    t.tap(bx + bw / 2.0, by + bh / 2.0)
    // (off the card and the row: gone; back on the row: shown again)
    t.move_to(px, 844.0 * (1.0 - things_share))
    t.run_for(@sfpages.hover_close_ms + @ui.move_most_ms)
    t.move_to(px, py)
    t.run_for(@sfpages.hover_open_ms + @ui.move_most_ms)
    let again = t.find(@sf.t("common.copied")) is Some(_)
    t.run_for(@sf.copied_ms)
    let after = t.find(@sf.t("common.link.copy")) is Some(_)
    t.move_to(px, 844.0 * (1.0 - things_share))
    t.run_for(@sfpages.hover_close_ms + @ui.move_most_ms)
    t.key(@ui.key_escape)
    t.run_for(sheet_way_ms(t))
    (again, after)
  }
  let now = seen(fn() { open_things(src, r, 7.0) })
  assert_eq(now, (true, true))
}

///|
test "小屏 with a mouse: a link's card in the chat's things (web_peek_node): the pointer over its ground is the arrow (@sf.ground_node)" {
  let (t, src, r) = things_chat_mouse()
  let seen = fn(_px : Double, _py : Double) {
    // (the card: the last group read out, drawn over all of the window, as wide as a card at least)
    match t.semantics().filter(fn(s) { s.role == Group && !s.hidden && s.rect.2 >= 200.0 }).last() {
      Some(c) => {
        let (x, y, w, h) = c.rect
        [(x + 3.0, y + h / 2.0), (x + w / 2.0, y + 3.0), (x + w / 2.0, y + h - 3.0), (x + w - 3.0, y + h / 2.0)]
        .map(fn(p) {
          t.move_to(p.0, p.1)
          t.run_for(@ui.move_most_ms)
          "\{t.cursor()}"
        })
        .join(" ") +
        " \{Repr(c.rect)}"
      }
      None => "none"
    }
  }
  let got = things_card_seen(t, r, "links", "列表滚动的性能数据", fn() { open_things(src, r, 7.0) }, seen)
  assert_true(got.has_prefix("Arrow Arrow Arrow Arrow "), msg=got)
}
