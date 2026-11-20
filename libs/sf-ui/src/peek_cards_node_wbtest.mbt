// The cards a link's hover card holds and a link's card in an agent's words (peek_cards_node.mbt), each alone in a
// hover card's room (a 320 card's panel padding and words' inset): a web page's tile, a pull request's card (its
// state, its facts, its address copied and saying so till copied_ms is over), a file's head, lines, entries and foot,
// a chat's head, where it is and the message a link names, a link's capsule (pressed, quieter once gone); every rule
// of the audit holding in each but what these looks were drawn with before they were the library's (peek_carried).

///|
/// A Tester of what `make` makes in a hover card's room (`wide`, 308 as a card 320 wide has it, its words 10 in), 40 in,
/// 40 down, a mouse's.
fn peek_rig(make : (@view.View) -> Unit, wide? : Double = 308.0) -> @ui.Tester {
  set_words(fn(key, _) { key })
  let t = @ui.Tester::new(fn(_c) {  }, w=480.0, h=640.0, native=Mouse, pointing=Mouse)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(col) {
      col.padding(Is((40.0, 40.0, 0.0, 40.0))) |> ignore
      col.box(fn(card) {
        let p = @ui.Space::px(S2_5)
        card.width(Is(Some(wide))).padding(Is((p, p, p, p))).gap(Is(@ui.Space::px(S2))) |> ignore
        make(card)
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// What `t.audit()` finds of these cards but what their looks had as the app's pages drew them, before they were
/// moved here unchanged (each the app's screens' bars count, corners_wbtest's): a state's pill 6 in at its glyph's
/// side and 8 at its end; the marked line's ground meeting the lines beside it, its number's room at its edge; a link
/// card's mark in the middle of its capsule, not on its title's line.
fn peek_faults(t : @ui.Tester) -> Array[String] {
  t
  .audit()
  .filter(fn(f) {
    !(
      (f.has_prefix("rule 4: what 「state.") && f.contains("6 in from its left, 8 from its right")) ||
      f.contains("「2   println(1)」") ||
      (f.has_prefix("first line: a box in 「Willow 的屏幕") && f.contains("236×52"))
    )
  })
}

///|
test "a page's tile: its title over where it goes, its address to copy saying so a while once copied" {
  let copied : Map[String, Double] = Map([])
  let t = peek_rig(fn(card) {
    card.box(fn(b) {
      style_node(b, fn() { peek_card_part })
      peek_page_tile_node(
        b,
        fn() { "一个网页的标题" },
        fn() { "example.com/a/page" },
        fn() { "" },
        fn() { false },
        fn() { "" },
        fn(f) { peek_copy_node(f, fn() { "https://example.com/a/page" }, "common.link.copy", copied) },
      )
    })
    |> ignore
  })
  assert_true(t.find("一个网页的标题") is Some(_))
  assert_true(t.find("example.com/a/page") is Some(_))
  assert_eq(peek_faults(t), [])
  t.click(@ui.Role::Button, label="common.link.copy")
  t.run_for(copied_ms / 2.0)
  assert_true(t.find("common.copied") is Some(_), msg="copied")
  assert_true(copied.contains("https://example.com/a/page"))
  t.run_for(copied_ms)
  assert_true(t.find("common.link.copy") is Some(_), msg="said so no more once copied_ms is over")
}

///|
/// The smallest ground drawn round `r` (x, y, w, h) in `t`'s last frame, as drawn_rects has it.
fn peek_ground_round(t : @ui.Tester, r : (Double, Double, Double, Double)) -> (Double, Double, Double, Double)? {
  let mut best : (Double, Double, Double, Double)? = None
  for d in t.drawn_rects() {
    if d.0 <= r.0 && d.0 + d.2 >= r.0 + r.2 && d.1 <= r.1 && d.1 + d.3 >= r.1 + r.3 {
      match best {
        Some(b) if b.2 <= d.2 => ()
        _ => best = Some((d.0, d.1, d.2, d.3))
      }
    }
  }
  best
}

///|
test "a page's tile with its picture: the picture in the card's top corners, the thumb at its title's first line" {
  for k in [(1.0, 308.0), (1.3, 308.0), (1.0, 260.0)] {
    let (scale, wide) = k
    for title in ["一个网页的标题", "一个网页的标题很长很长，长到在卡片里要折成两行才放得下它的全部文字"] {
      let t = peek_rig(fn(card) {
        card.box(fn(b) {
          style_node(b, fn() { peek_card_part })
          peek_page_tile_node(b, fn() { title }, fn() { "example.com/a/page" }, fn() { "" }, fn() { false }, fn() {
            "mem:peek-picture"
          }, fn(f) { peek_copy_node(f, fn() { "https://example.com/a/page" }, "common.link.copy", Map([])) })
        })
        |> ignore
      }, wide~)
      t.set_font_scale(scale)
      t.draw()
      let said = "\{scale} \{wide} \{title}"
      assert_eq(peek_faults(t), [], msg=said)
      let rects = t.drawn_rects()
      // (the rig's card: 40 in, `wide` across, its words 10 in; the picture's ground out past them as far as the card's
      // corner has it, as far from its top as from its sides, 16:9)
      let across = wide - 20.0 - 2.0 * peek_thumb_out
      let picture = rects.filter(fn(d) { (d.2 - across).abs() < 0.01 && (d.3 - across / peek_picture_aspect).abs() < 0.5 })
      assert_eq(picture.length(), 1, msg=said)
      let (px, py, pw, ph, _) = picture[0]
      let side = px - 40.0
      assert_eq(side, 10.0 + peek_thumb_out, msg=said)
      assert_eq(py - 40.0, side, msg=said)
      assert_eq(40.0 + wide - (px + pw), side, msg=said)
      // (the thumb under it beside the title's first line: its top at the title's, its start at the picture's)
      let thumb = rects.filter(fn(d) { d.2 == d.3 && d.2 >= 30.0 && d.1 > py + ph })
      assert_eq(thumb.length(), 1, msg=said)
      let words = t.rect_of("一个网页的标题").unwrap()
      assert_true((thumb[0].1 - words.1).abs() < 0.5, msg="\{said}: thumb \{thumb[0].1}, title \{words.1}")
      assert_eq(thumb[0].0, px, msg=said)
    }
  }
}

///|
test "a pull request's card: its state's pill, where it is, its title and its facts; its state as it changes" {
  let state = @signals.signal("open")
  let t = peek_rig(fn(card) {
    peek_change_node(
      card,
      true,
      fn() { state.get() },
      fn() { "state." + state.get() },
      fn() { "AFK-surf/monoid #7279" },
      fn() { "5 分钟前" },
      fn() { "修好站点的几处问题" },
      fn() { [Person("zuozijian", ""), Size(12, 3), Chip("4 个文件"), Checks("passed", "检查通过")] },
      fn(_) {  },
    )
  })
  for w in ["state.open", "AFK-surf/monoid #7279", "5 分钟前", "修好站点的几处问题", "zuozijian", "+12", "\u{2212}3", "4 个文件", "检查通过"] {
    assert_true(t.find(w) is Some(_), msg=w)
  }
  assert_eq(peek_faults(t), [])
  // (its checks' pill, no glyph: its words as far in from both its ends)
  let w = t.rect_of("检查通过").unwrap()
  let pill = peek_ground_round(t, w).unwrap()
  let ends = (w.0 - pill.0, pill.0 + pill.2 - (w.0 + w.2))
  assert_true((ends.0 - 8.0).abs() < 0.5 && (ends.1 - 8.0).abs() < 0.5, msg="checks' pill: \{ends.0} and \{ends.1} in")
  state.set("merged")
  t.draw()
  assert_true(t.find("state.merged") is Some(_))
  assert_true(t.find("state.open") is None)
  assert_eq(peek_faults(t), [])
}

///|
test "a file's card: its head, its lines (the one named marked), a directory's entries, its foot" {
  let t = peek_rig(fn(card) {
    peek_rich_node(card, fn(rich) {
      peek_file_head_node(rich, fn() { "main.mbt:2" }, fn() { false }, fn() { "~/src/main.mbt" }, fn() { "刚刚" })
      rich.box(fn(b) {
        peek_file_lines_node(b, fn() { 1 }, fn() { ["fn main {", "  println(1)", "}"] }, fn() { Some(2) }, fn() { [] })
      })
      |> ignore
      rich.box(fn(b) { peek_file_entries_node(b, fn() { ["src/", "moon.mod", "README.md"] }) }) |> ignore
      peek_file_foot_node(rich, fn() { "1 KB" }, fn(_) {  })
    })
  })
  for w in ["main.mbt:2", "~/src/main.mbt", "刚刚", "fn main {", "  println(1)", "src", "moon.mod", "README.md", "1 KB"] {
    assert_true(t.find(w) is Some(_), msg=w)
  }
  assert_eq(peek_faults(t), [])
}

///|
test "a chat's card: its head, where it is, the message a link names; a note where there is none" {
  let found = @signals.signal(true)
  let t = peek_rig(fn(card) {
    card.pick(fn() { found.get() }, fn(b, yes) {
      style_node(b, fn() { peek_card_part })
      if yes {
        peek_rich_node(b, fn(rich) {
          peek_chat_head_node(rich, fn() { "首页的列表改成按天分组" }, ago=fn() { "5 分钟前" })
          peek_chat_where_node(rich, fn() { true }, fn() { true }, fn() { "🌳" }, fn() { "" }, fn() { "Willow 的工作站" })
          rich.box(fn(q) { peek_message_node(q, fn() { "林小满 · 5 分钟前" }, fn() { "列表按天分组做好了" }) })
          |> ignore
        })
      } else {
        peek_note_node(b, fn() { "这个对话已经不在了" })
      }
    })
  })
  for w in ["首页的列表改成按天分组", "5 分钟前", "Willow 的工作站", "林小满 · 5 分钟前", "列表按天分组做好了"] {
    assert_true(t.find(w) is Some(_), msg=w)
  }
  assert_eq(peek_faults(t), [])
  found.set(false)
  t.run_for(peek_test_left_ms)
  assert_true(t.find("这个对话已经不在了") is Some(_))
  assert_true(t.find("首页的列表改成按天分组") is None)
  assert_eq(peek_faults(t), [])
}

///|
test "a link's card in an agent's words: its title over its line, pressed where it leads, quieter once gone" {
  let pressed = Ref(0)
  let gone = @signals.signal(false)
  let t = peek_rig(fn(card) {
    link_card_node(card, fn() { Some("monitor") }, fn() { "Willow 的屏幕" }, fn() { "1920×1080" }, fn() { gone.get() }, fn() {
      pressed.val += 1
    })
  })
  assert_true(t.find("Willow 的屏幕") is Some(_))
  assert_true(t.find("1920×1080") is Some(_))
  assert_eq(peek_faults(t), [])
  t.click(@ui.Role::Link, label="Willow 的屏幕")
  assert_eq(pressed.val, 1)
  // (its title drawn in another ink, nothing else of it changed: the draw list told apart)
  let before = t.drawlist()
  gone.set(true)
  t.draw()
  assert_true(t.drawlist() != before, msg="quieter once gone")
  assert_true(t.find("Willow 的屏幕") is Some(_))
  assert_eq(peek_faults(t), [])
}

///|
/// Longer than what a pick showed takes to leave: the card as it is once that has gone.
let peek_test_left_ms : Double = 1000.0

///|
/// The heads a card's `ago` stands at the end of, each in `card`: a chat's (after its title), a file's (after its
/// name), a pull request's meta (after where it is), each of them saying `long` before `ago`.
fn peek_ago_heads(card : @view.View, long : String, ago : String) -> Unit {
  peek_chat_head_node(card, fn() { long }, ago=fn() { ago })
  peek_file_head_node(card, fn() { long }, fn() { false }, fn() { "~/src/main.mbt" }, fn() { ago })
  peek_change_node(card, true, fn() { "open" }, fn() { "state.open" }, fn() { long }, fn() { ago }, fn() { "标题" }, fn() {
    []
  }, fn(_) {  })
}

///|
/// How wide each of the words `t` lays out that `ago` says are how long ago is, each checked to end inside a rig's card
/// `wide` across (its words 10 in).
fn peek_agos_inside(t : @ui.Tester, wide : Double, ago : (String) -> Bool) -> Array[Double] {
  let words = t.words().filter(fn(x) { x.5 > 0.0 })
  let agos = words.filter(fn(x) { ago(x.0) })
  for x in agos {
    guard x.1 >= 50.0 - 0.01 && x.1 + x.3 <= 40.0 + wide - 10.0 + 0.01 else {
      @halt.saying("「\{x.0}」 laid out from \{x.1} to \{x.1 + x.3}, past the card: \{Repr(words)}")
    }
  }
  agos.map(fn(x) { x.3 })
}

///|
test "a narrow card's head: how long ago kept whole at its end, what is before it given way first" {
  let long = "AFK-surf/monoid-a-repository-with-a-long-name #7279"
  let is_ago = fn(s : String) { s == "3 分钟前" }
  let room = peek_rig(fn(card) { peek_ago_heads(card, "标题", "3 分钟前") })
  let whole = peek_agos_inside(room, 308.0, is_ago)
  assert_eq(whole.length(), 3)
  let t = peek_rig(fn(card) { peek_ago_heads(card, long, "3 分钟前") }, wide=200.0)
  let agos = peek_agos_inside(t, 200.0, is_ago)
  assert_eq(agos, whole)
  assert_eq(peek_faults(t), [])
}

///|
test "a card's head whose how long ago is longer than its line: cut short inside the card" {
  let ago = "三年零四个月又十七天之前的某一个下午快要下班的时候"
  let t = peek_rig(fn(card) { peek_ago_heads(card, "标题", ago) }, wide=200.0)
  let agos = peek_agos_inside(t, 200.0, fn(s) { s == ago })
  assert_eq(agos.length(), 3)
  assert_eq(peek_faults(t), [])
}
