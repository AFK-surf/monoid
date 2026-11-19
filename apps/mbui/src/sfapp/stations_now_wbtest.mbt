///|
test "wide: the rail's 用量 place, the pointer resting on it, offers 分享卡片, which copies its picture" {
  let calls : Array[Made] = []
  let t = wide_tester(calls)
  let place = t.query(Button, label="用量").unwrap()
  let (x, y, w, h) = place.rect
  t.move_to(x + w / 2.0, y + h / 2.0)
  t.run_for(@sfpages.hover_open_ms * 2.0)
  // the card to share, opened from it: the picture, 复制图片 under it
  t.click(Button, label="分享卡片")
  t.run_for(@motion.presence_in_ms)
  assert_true(t.find("用 1 个 Claude 订阅账号消耗了") is Some(_), msg="what leads the picture's number")
  assert_true(t.find("一生万物，万物归一") is Some(_))
  assert_eq(t.corner_faults(), [])
  t.click(Button, label="复制图片")
  t.frame()
  // the picture on the clipboard, as a PNG three pixels a point (as sharp from this window's two)
  match t.clipboard_png() {
    Some(png) =>
      match png_size(png) {
        Some((pw, ph)) => {
          assert_true(pw == 1080 && ph > 600, msg="\{Repr((pw, ph))}")
          assert_eq(t.clipboard_label(), "still.fail")
        }
        None => fail("not a PNG")
      }
    None => fail("no picture copied")
  }
}

///|
test "the card to share is one picture, in a dialog as on a phone: what leads the first's share over the rings, the share beside them, today over the last 7 days, each day a bar, the chats at work, still.fail's line, each part in the same place" {
  // (windows with the room for all of it: the stage draws it its own size; each its own app, the card opened
  // as it starts)
  let desk_src = fixture_app("share-card")
  let desk = @ui.Tester::new(fn(c) { view(c, desk_src) }, tree=app_tree(desk_src), w=1440.0, h=1000.0, platform=0)
  share_card_laid(desk)
  // (read whole before the next is made: a Tester read after another was made reads the other's frame, tester_own.mbt)
  let at_desk = picture_parts(desk)
  let phone_src = fixture_app("share-card")
  let phone = @ui.Tester::new(fn(c) { view(c, phone_src) }, tree=app_tree(phone_src), w=430.0, h=932.0, platform=2)
  share_card_laid(phone)
  // 「分享图片不应该分电脑和手机」: each part as far from what leads the share in either
  let at_phone = picture_parts(phone)
  assert_eq(at_desk.map(fn(p) { p.0 }), picture_part_words)
  assert_eq(at_desk, at_phone)
}

///|
test "the card to share in a short window, in a 360 phone's sheet: all of it seen, drawn smaller; what is copied or kept the same picture, as large, wherever it is shared from" {
  let shared = fn(w : Double, h : Double, platform : Int) -> (Int, Int) raise {
    let src = fixture_app("share-card")
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~)
    t.run_for(@motion.presence_in_ms)
    assert_eq(t.squeeze_faults(), [])
    let png = if platform == 2 {
      t.click(Button, label="保存到相册")
      t.run_for(@motion.presence_in_ms)
      t.kept()[0].2
    } else {
      t.click(Button, label="复制图片")
      t.frame()
      t.clipboard_png().unwrap()
    }
    png_size(png).unwrap()
  }
  let (w0, h0) = shared(1440.0, 1000.0, 0)
  assert_eq(w0, 1080)
  for at in [(1280.0, 800.0, 0), (1280.0, 640.0, 0), (360.0, 740.0, 2)] {
    // (the whole picture, not the part of it a scroll shows; drawn apart, not as the window shows it)
    let got = shared(at.0, at.1, at.2)
    assert_true(got == (w0, h0), msg="\{Repr((at, got, w0, h0))}")
  }
}

///|
test "the card to share's looks: each chosen under it draws the picture in it at once, all of it, nothing cut short, and is what is handed out; the choice kept the device's" {
  for at in [(1440.0, 1000.0, 0), (390.0, 844.0, 2)] {
    let src = fixture_app("share-card")
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=at.0, h=at.1, platform=at.2)
    t.run_for(@motion.presence_in_ms)
    // the night's, none kept: its rings' lead
    assert_true(picture_says(t, "用 6 个 Claude 订阅账号消耗了"))
    // each its own picture, saying what serves it (「信息甚至都不用一样」): what each says that another does not, and
    // what it leaves out
    for look in [
      ("大字报", "2.1 亿", "OpenCode Go 订阅"),
      ("小票", "5 个", "9 个对话正在运行"),
      ("终端", "still.fail fetch", "10/20"),
      ("夜色", "用 6 个 Claude 订阅账号消耗了", "5 个"),
    ] {
      t.click(Button, label=look.0)
      t.run_for(@motion.presence_in_ms)
      assert_true(picture_says(t, look.1), msg="\{Repr((at, look))}")
      assert_true(!picture_says(t, look.2), msg="\{Repr((at, look))}")
      assert_eq(t.squeeze_faults(), [])
      assert_eq(t.corner_faults(), [])
      assert_eq(t.contrast_faults(), [])
      let png = if at.2 == 2 {
        t.click(Button, label="保存到相册")
        t.run_for(@motion.presence_in_ms)
        t.kept()[t.kept().length() - 1].2
      } else {
        t.click(Button, label="复制图片")
        t.frame()
        t.clipboard_png().unwrap()
      }
      assert_true(png_size(png) is Some((1080, _)), msg="\{Repr((at, look))}")
    }
    // (kept: the prefs say the last chosen)
    assert_eq(@sfbase.text(src.topic("prefs", Map([])).get().value, "shareLook"), "night")
  }
}

///|
/// The words drawn now in the picture, seen (not the looks' small pictures under it: each stands for itself, its words
/// not read out).
fn picture_words(t : @ui.Tester) -> Array[(String, Double, Double, Double, Double, Double)] {
  t.words_said().filter(fn(w) { w.5 > 0.5 })
}

///|
/// Whether the picture says `s` (in words of its own, or a part of them).
fn picture_says(t : @ui.Tester, s : String) -> Bool {
  picture_words(t).iter().any(fn(w) { w.0.contains(s) })
}

///|
/// The words of the picture whose places say how it is laid out (each said alone, not a part of a line of several).
// kept across runs: a table, never written
let picture_part_words : Array[String] = [
  "10月26日 04:12", "2.1 亿", "token，折合 $1,420", "今天", "12 个", "近 7 天", "57 个", "$1,911", "10/20", "10/26", "平均每个对话 5.2 个",
  "一生万物，万物归一",
]

///|
/// Where each of picture_part_words is in the picture `t` shows, from what leads its share (用 6 个 Claude 订阅账号消耗了),
/// as it is laid out (where it is drawn, as large as the picture is drawn: picture_drawn_k), rounded to the point.
fn picture_parts(t : @ui.Tester) -> Array[(String, Int, Int)] {
  let words = picture_words(t)
  let k = picture_drawn_k(t)
  let lead = words.filter(fn(w) { w.0 == "用 6 个 Claude 订阅账号消耗了" })
  if lead.length() != 1 {
    return []
  }
  let (lx, ly) = (lead[0].1, lead[0].2)
  let parts = []
  for s in picture_part_words {
    // (in the picture: under its head, as wide as it is; 今天 is the chats' heading too)
    for w in words {
      if w.0 == s && w.1 > lx - 40.0 && w.1 < lx + 360.0 && w.2 > ly - 40.0 {
        parts.push((s, ((w.1 - lx) / k).round().to_int(), ((w.2 - ly) / k).round().to_int()))
        break
      }
    }
  }
  parts
}

///|
test "the card to share on a phone: the picture as wide as its sheet lets it, nothing cut short; 保存到相册 keeps the picture in the photo album" {
  let src = fixture_app("share-card")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  share_card_laid(t)
  // a phone keeps pictures in its photo album: the picture kept there, a PNG three pixels a point, said once it is
  assert_true(t.query(Button, label="复制图片") is None)
  t.click(Button, label="保存到相册")
  t.run_for(@motion.presence_in_ms)
  assert_eq(t.kept_ways().map(fn(k) { (k.0, Show::to_string(k.1)) }), [("still.fail.png", "Photos")])
  match png_size(t.kept()[0].2) {
    Some((pw, ph)) => assert_true(pw == 1080 && ph > 900, msg="\{Repr((pw, ph))}")
    None => fail("not a PNG")
  }
  assert_true(t.find("已保存到相册") is Some(_))
}

///|
test "the card to share in a 千恋＊万花 look, kept on a phone: the whole card, as tall as it is laid out, not its tile in the looks' strip" {
  // (the picture kept is drawn as box 0, as each look's tile in the strip is: the look's whole card is kept, not its
  // picture alone in a tile's ground, 2026-11-03 用户「保存至相册，存下来之后只有蓝色背景，啥都没有」)
  let src = fixture_app("share-card-senren-ledger")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(@motion.presence_in_ms)
  t.click(Button, label="保存到相册")
  t.run_for(@motion.presence_in_ms)
  match png_size(t.kept()[0].2) {
    // (a tile's is 360 by 480: 1080 by 1440; the ledger's card is taller, its every day's row under its picture)
    Some((pw, ph)) => assert_true(pw == 1080 && ph > 2000, msg="\{Repr((pw, ph))}")
    None => fail("not a PNG")
  }
}

///|
/// The card to share as `t` shows it: laid out the one way.
fn share_card_laid(t : @ui.Tester) -> Unit raise {
  // (the card come in and the edge of the column it is in shown, the longer of the two: what is seen at rest)
  t.run_for(if @sf.edge_bar_ms > @motion.presence_in_ms { @sf.edge_bar_ms } else { @motion.presence_in_ms })
  let word = fn(s : String) { picture_words(t).filter(fn(w) { w.0 == s }) }
  // the first kind's said round its first model's tokens, read down: what leads it over the rings and the tokens, the
  // tokens large, the model and what they would cost under them; each other kind a line of its own, its ring's key: its
  // name, its accounts; each other model a line, its tokens and cost at the line's end (2026-10-30 用户「按模型分开写
  // token 和钱」: no kind's models added up)
  let lead = word("用 6 个 Claude 订阅账号消耗了")
  let share = word("2.1 亿")
  let of = word("token，折合 $1,420")
  assert_true(lead.length() == 1 && share.length() == 1 && of.length() == 1 && share[0].4 > of[0].4 * 2.0, msg="\{Repr((lead, share, of))}")
  assert_true(
    lead[0].2 < share[0].2 && of[0].2 > share[0].2 && of[0].1 == share[0].1 && lead[0].1 < share[0].1,
    msg="\{Repr((lead, share, of))}",
  )
  let kinds = ["ChatGPT 订阅", "OpenCode Go 订阅"].map(fn(k) { word(k) })
  let accounts = word("2 个账号")
  assert_true(kinds.iter().all(fn(k) { k.length() == 1 }) && accounts.length() == 2, msg="\{Repr((kinds, accounts))}")
  for i, k in kinds {
    // (on its line: its accounts after its name)
    assert_true(accounts[i].1 > k[0].1 + k[0].3 && (accounts[i].2 - k[0].2).abs() < 2.0, msg="\{Repr((k, accounts))}")
  }
  let models = [("Sonnet 5.5", "3800 万 · $171"), ("GPT-5.5 Codex", "4700 万 · $262"), ("Kimi K2", "800 万 · $32.40"), ("GLM-4.6", "300 万 · $12.70")].map(fn(m) {
    (word(m.0), word(m.1))
  })
  for m in models {
    let (name, used) = m
    assert_true(name.length() == 1 && used.length() == 1, msg="\{Repr(m)}")
    // (on its line, past where the kinds' names start: its tokens and cost at the end, the ends one under another)
    assert_true(used[0].1 > name[0].1 + name[0].3 && (used[0].2 - name[0].2).abs() < 2.0 && name[0].1 == kinds[0][0].1, msg="\{Repr(m)}")
    assert_true((used[0].1 + used[0].3 - (models[0].1[0].1 + models[0].1[0].3)).abs() < 0.5, msg="\{Repr((m, models[0]))}")
  }
  // each model under its kind: Sonnet under the first's tokens, GPT-5.5 Codex under ChatGPT, Kimi K2 under OpenCode
  assert_true(models[0].0[0].2 > of[0].2 && models[0].0[0].2 < kinds[0][0].2 && kinds[0][0].2 < models[1].0[0].2, msg="\{Repr(models)}")
  assert_true(models[1].0[0].2 < kinds[1][0].2 && kinds[1][0].2 < models[2].0[0].2 && models[2].0[0].2 < models[3].0[0].2, msg="\{Repr(models)}")
  // today over the last 7 days (under the share: 今天 is the chats' heading too); each day's date under its bar
  let today = word("今天").filter(fn(w) { w.2 > share[0].2 })
  let week = word("近 7 天")
  assert_true(today.length() == 1 && week.length() == 1, msg="\{Repr((today, week))}")
  assert_true(today[0].1 == week[0].1 && today[0].2 < week[0].2, msg="\{Repr((today, week))}")
  assert_true(word("12 个").length() == 1 && word("57 个").length() == 1 && word("$1,911").length() == 1)
  let days = ["10/20", "10/26"].map(fn(d) { word(d) })
  assert_true(days.iter().all(fn(d) { d.length() == 1 }) && days[0][0].1 < days[1][0].1, msg="\{Repr(days)}")
  // the chats at work now, the tasks run across devices, and still.fail's line
  assert_true(picture_says(t, "9 个对话正在运行") && picture_says(t, "今天用了 3 台设备"))
  assert_true(picture_says(t, "近 7 天 agent 跨设备执行了 312 个任务") && picture_says(t, "平均每个对话 5.2 个"))
  // the picture all in its sheet or dialog, over its button
  let line = word("一生万物，万物归一")
  let button = match t.query(Button, label="保存到相册") {
    Some(b) => b
    None => t.query(Button, label="复制图片").unwrap()
  }
  // (the picture drawn smaller where its sheet is short, its words laid out as large: over the button as it is drawn,
  // the button in its sheet or dialog)
  let (_, dy, _, dh) = t.get(@ui.Role::Dialog).rect
  assert_true(line.length() == 1 && button.rect.1 + button.rect.3 <= dy + dh + 0.5, msg="\{Repr((line, button.rect))}")
  // another kind's line and the chats at work's each on one line (as tall as each other, both Meta's)
  match (t.rect_of("OpenCode Go 订阅"), t.rect_of("9 个对话正在运行")) {
    (Some((_, _, _, oh)), Some((_, _, _, ch))) => assert_true(oh == ch, msg="\{Repr((oh, ch))}")
    _ => fail("no other kind's line, or no chats at work")
  }
  // what it says on a line of its own, the more of it under it: neither broken onto two
  let tasks = word("近 7 天 agent 跨设备执行了 312 个任务")
  let more = word("平均每个对话 5.2 个")
  assert_true(tasks.length() == 1 && more.length() == 1 && tasks[0].4 == more[0].4 && more[0].2 > tasks[0].2, msg="\{Repr((tasks, more))}")
  assert_true(picture_says(t, "一生万物，万物归一"))
  assert_eq(t.squeeze_faults(), [])
  assert_eq(t.corner_faults(), [])
  assert_eq(t.contrast_faults(), [])
}

///|
test "the 用量 page: 分享卡片 beside its days once something was spent (no pointer to rest on 用量's card), opening the card to share" {
  let t = place_tester("usage")
  assert_eq(@sf.presenting(), false)
  t.click(Button, label="分享卡片")
  t.frame()
  assert_eq(@sf.presenting(), true)
}


///|
/// Where a stage's parts are: its dialog and what it is read out as, the picture (its line's words and how large they
/// are drawn), the first look and 关闭 and the stage's own button (复制图片, 保存到相册 on a phone).
fn stage_said(t : @ui.Tester) -> String {
  let dialog = t.query(Dialog).map(fn(s) { (s.label, tenth4(s.rect)) })
  let line = picture_words(t).filter(fn(w) { w.0 == "一生万物，万物归一" }).map(fn(w) { tenth4((w.1, w.2, w.3, w.4)) })
  let b = fn(label : String) { t.query(Button, label~).map(fn(s) { tenth4(s.rect) }) }
  "dialog \{@ui.some_text(dialog.map(fn(d) { "(\{d.0}, \{@ui.rect_text(d.1)})" }))} line \{@ui.list_text(line.map(@ui.rect_text))} look \{@ui.some_text(b("夜色").map(@ui.rect_text))} close \{@ui.some_text(b("关闭").map(@ui.rect_text))} copy \{@ui.some_text(b("复制图片").map(@ui.rect_text))} save \{@ui.some_text(b("保存到相册").map(@ui.rect_text))} squeeze \{t.squeeze_faults().length()}"
}

///|
/// What a stage paints, as drawn on the last frame: the window's night (an instance over all of it in stage_scrim's
/// colour: its alpha) and the picture's ground (the largest instance in share_ground's colour: where it is drawn, as
/// large as it is drawn after its look).
fn stage_ink(t : @ui.Tester, w : Double, h : Double) -> String {
  let near = fn(a : Array[Double], c : Int64) {
    let ch = fn(shift : Int) { ((c >> shift) & 0xFFL).to_double() / 255.0 }
    (a[8] - ch(24)).abs() < 0.01 && (a[9] - ch(16)).abs() < 0.01 && (a[10] - ch(8)).abs() < 0.01
  }
  let drawn = t.drawn_instances()
  let night = drawn
    .filter(fn(a) { a[5] == 0.0 && a[0] <= 0.5 && a[1] <= 0.5 && a[2] >= w - 0.5 && a[3] >= h - 0.5 && near(a, @sf.stage_scrim) })
    .map(fn(a) { (a[11] * 100.0).round() / 100.0 })
  let mut ground : (Double, Double, Double, Double)? = None
  for a in drawn {
    if a[5] == 0.0 && near(a, @sf.share_ground) && a[11] > 0.5 {
      match ground {
        Some(g) if g.2 * g.3 >= a[2] * a[3] => ()
        _ => ground = Some((a[0], a[1], a[2], a[3]))
      }
    }
  }
  // (its words as drawn (glyphs, kind 1, seen, the stage's): how many lie whole in the picture and how low the lowest
  // reaches; and how many reach out of it down into what is under it, over the looks; the names of the sets they are in
  // not of it)
  let looks_top = t.query(Button, label="夜色").map(fn(s) { s.rect.1 }).unwrap_or(h)
  let sets = t.all(Tab).map(fn(s) { s.rect })
  let in_sets = fn(a : Array[Double]) {
    sets.iter().any(fn(r) { a[0] + a[2] > r.0 && a[0] < r.0 + r.2 && a[1] + a[3] > r.1 - 0.5 && a[1] < r.1 + r.3 + 0.5 })
  }
  // (the stage's own: drawn after its night, not the page's under it, which the night dims and the picture covers)
  let mut after_night = drawn.length()
  for i, a in drawn {
    if a[5] == 0.0 && a[0] <= 0.5 && a[1] <= 0.5 && a[2] >= w - 0.5 && a[3] >= h - 0.5 && near(a, @sf.stage_scrim) {
      after_night = i + 1
    }
  }
  let glyphs : Array[Array[Double]] = []
  for i, a in drawn {
    if i >= after_night && a[5] == 1.0 && a[11] > 0.0 {
      glyphs.push(a)
    }
  }
  let words = match ground {
    Some((gx, gy, gw, gh)) => {
      let inside = glyphs.filter(fn(a) { a[0] >= gx - 0.5 && a[0] + a[2] <= gx + gw + 0.5 && a[1] >= gy - 0.5 && a[1] + a[3] <= gy + gh + 0.5 })
      let lowest = inside.iter().fold(init=0.0, fn(m, a) { dmax(m, a[1] + a[3]) })
      let out = glyphs.filter(fn(a) { a[0] >= gx && a[0] < gx + gw && a[1] + a[3] > gy + gh + 0.5 && a[1] < looks_top && !in_sets(a) })
      "words in \{inside.length()} lowest \{(lowest * 10.0).round() / 10.0} out under \{out.length()}"
    }
    None => "words none"
  }
  "night \{@ui.list_text(night)} picture \{@ui.some_text(ground.map(tenth4).map(@ui.rect_text))} \{words}"
}

///|
/// A stage come in and settled: its way in over, and what moves after it (the picture drawn smaller as the room it is
/// given is known) at rest.
fn stage_settled(t : @ui.Tester) -> Unit {
  t.run_for(@motion.presence_in_ms)
  t.run_for(@ui.move_most_ms)
}

///|
/// Whether a stage is drawn by the window's tree: a dialog said there titled 分享卡片.
fn stage_drawn() -> Bool {
  tree_said(Dialog, "分享卡片") is Some(_)
}

///|
test "stage, 大屏 keyboard and mouse in a tall and a short window, touch in a tablet's and a phone's: the picture, its looks and buttons, where each is, drawn by the window's tree: as main has it" {
  let out = []
  let drawn = []
  for at in [(1440.0, 1000.0, 0), (1280.0, 640.0, 0), (840.0, 1100.0, 1), (390.0, 844.0, 2)] {
    let src = fixture_app("share-card")
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=at.0, h=at.1, platform=at.2)
    stage_settled(t)
    out.push("(\{at.0}, \{at.1}, \{at.2}): \{stage_said(t)}")
    drawn.push(stage_drawn())
  }
  // (as main has it, 435d3ba8, its buttons 0.2 wider since a small icon's strokes are (sf/icons.mbt stroke_k); the looks each their picture drawn small, 2026-11-02; 34 of them since 千恋＊万花's: their
  // strip as wide as the picture is laid out, from its start, scrolled, the stage as wide; in sets since, their names
  // over the strip: the stage a line taller where the window has the room, 840 by 1100; its line where it is drawn,
  // as large, since the picture is made as nodes: its old body's words were said where they were laid out)
  assert_eq(out, [
    "(1440, 1000, 0): dialog Some((分享卡片, (540, 24, 360, 952))) line [(577.1, 699.8, 285.8, 19.2)] look Some((540, 795.2, 78, 124.8)) close Some((635.6, 940, 58, 36)) copy Some((701.6, 940, 102.7, 36)) save None squeeze 0",
    "(1280, 640, 0): dialog Some((分享卡片, (460, 24, 360, 592))) line [(568.8, 360.5, 142.3, 9.6)] look Some((460, 435.2, 78, 124.8)) close Some((555.6, 580, 58, 36)) copy Some((621.6, 580, 102.7, 36)) save None squeeze 0",
    "(840, 1100, 1): dialog Some((分享卡片, (240, 41.2, 360, 1017.6))) line [(264, 778.8, 312, 21)] look Some((240, 878, 78, 124.8)) close Some((321.8, 1022.8, 62, 36)) copy None save Some((391.8, 1022.8, 126.4, 36)) squeeze 0",
    "(390, 844, 2): dialog Some((分享卡片, (24, 24, 342, 796))) line [(83.2, 552.7, 223.7, 15.1)] look Some((15, 639.2, 78, 124.8)) close Some((96.8, 784, 62, 36)) copy None save Some((166.8, 784, 126.4, 36)) squeeze 0",
  ])
  assert_eq(drawn, [true, true, true, true])
}

///|
test "stage, 大屏 keyboard and mouse: the window made shorter and taller again while it shows (frames as the display draws them): the picture drawn smaller and back, its buttons under it in the window: as main has it" {
  let src = fixture_app("share-card")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  stage_settled(t)
  let out = ["800: \{stage_said(t)}"]
  let ink = ["800: \{stage_ink(t, 1280.0, 800.0)}"]
  for h in [560.0, 800.0] {
    t.resize(1280.0, h)
    for _ in 0..<30 {
      t.frame_at(t.next_frame_time())
    }
    out.push("\{h}: \{stage_said(t)}")
    ink.push("\{h}: \{stage_ink(t, 1280.0, h)}")
  }
  // (as main has it, 435d3ba8, its buttons 0.2 wider since a small icon's strokes are (sf/icons.mbt stroke_k); the looks each their picture drawn small, 2026-11-02; 34 of them since 千恋＊万花's: their
  // strip as wide as the picture is laid out, from its start, scrolled, the stage as wide; its line where it is drawn, as large,
  // since the picture is made as nodes: its old body's words were said where they were laid out)
  assert_eq(out, [
    "800: dialog Some((分享卡片, (460, 24, 360, 752))) line [(536.9, 511.3, 206.1, 13.9)] look Some((460, 595.2, 78, 124.8)) close Some((555.6, 740, 58, 36)) copy Some((621.6, 740, 102.7, 36)) save None squeeze 0",
    "560: dialog Some((分享卡片, (460, 24, 360, 512))) line [(584.8, 285.1, 110.4, 7.4)] look Some((460, 355.2, 78, 124.8)) close Some((555.6, 500, 58, 36)) copy Some((621.6, 500, 102.7, 36)) save None squeeze 0",
    "800: dialog Some((分享卡片, (460, 24, 360, 752))) line [(536.9, 511.3, 206.1, 13.9)] look Some((460, 595.2, 78, 124.8)) close Some((555.6, 740, 58, 36)) copy Some((621.6, 740, 102.7, 36)) save None squeeze 0",
  ])
  // (what it paints: its night over the window, the picture as large as it is drawn)
  // (as main has it, 435d3ba8, its buttons 0.2 wider since a small icon's strokes are (sf/icons.mbt stroke_k); the looks each their picture drawn small, 2026-11-02; the stage's own words alone since
  // the looks are in sets (main counted the page's under the picture too: 360 and 336, the stage's 327 both): the
  // picture a line smaller for the sets' names, all of its words in it)
  assert_eq(ink, [
    "800: night [0.92] picture Some((521.1, 24, 237.8, 517)) words in 327 lowest 521.1 out under 0",
    "560: night [0.92] picture Some((576.3, 24, 127.4, 277)) words in 327 lowest 290.3 out under 0",
    "800: night [0.92] picture Some((521.1, 24, 237.8, 517)) words in 327 lowest 521.1 out under 0",
  ])
}

///|
test "stage, 大屏 keyboard and mouse: closed by Escape, by back, by 关闭, by a press beside the picture, and a look chosen first: presenting no more, gone at once from what is read out; the look chosen drawn: as main has it" {
  let out = []
  for how in ["escape", "back", "close", "beside", "look"] {
    let src = fixture_app("share-card")
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
    t.run_for(@motion.presence_in_ms)
    match how {
      "escape" => t.key(@ui.key_escape)
      "back" => t.back() |> ignore
      "close" => {
        let (x, y, w, h) = t.get(Button, label="关闭").rect
        t.tap(x + w / 2.0, y + h / 2.0)
      }
      "beside" => t.tap(20.0, 400.0)
      _ => {
        let (x, y, w, h) = t.get(Button, label="大字报").rect
        t.tap(x + w / 2.0, y + h / 2.0)
      }
    }
    t.frame()
    let at_once = "presenting \{@sf.presenting()} dialog \{@ui.some_text(t.query(Dialog).map(fn(s) { s.label }))}"
    t.run_for(@motion.presence_in_ms)
    let selected = t.all(Button).filter(fn(s) { s.selected == Some(true) }).map(fn(s) { s.label })
    out.push("\{how}: at once {\{at_once}} after {presenting \{@sf.presenting()} dialog \{@ui.some_text(t.query(Dialog).map(fn(s) { s.label }))} selected \{@ui.list_text(selected)}}")
  }
  // (as main has it, 435d3ba8; the looks each their picture drawn small, 2026-11-02)
  assert_eq(out, [
  "escape: at once {presenting false dialog None} after {presenting false dialog None selected []}",
  "back: at once {presenting false dialog None} after {presenting false dialog None selected []}",
  "close: at once {presenting false dialog None} after {presenting false dialog None selected []}",
  "beside: at once {presenting false dialog None} after {presenting false dialog None selected []}",
  "look: at once {presenting true dialog Some(分享卡片)} after {presenting true dialog Some(分享卡片) selected [大字报]}",
  ])
}

///|
test "stage, 大屏 keyboard and mouse: the focus as it opens and after a Tab: as main has it" {
  let src = fixture_app("share-card")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
  t.run_for(@motion.presence_in_ms)
  let focused = fn() { t.focused().map(fn(s) { "\{s.role} \{s.label}" }) }
  let open = focused()
  t.key(@ui.key_tab)
  t.run_for(@motion.presence_in_ms)
  let tabbed = focused()
  // (nothing of it given the focus as it opens; a Tab to its first control, the sets' first: made as nodes, each a
  // control the keyboard reaches, where its old body's took no Tab)
  assert_eq(["open \{@ui.some_text(open)}", "tab \{@ui.some_text(tabbed)}"], ["open None", "tab Some(Tab still.fail)"])
}


///|
test "a look with files of its own (千恋＊万花's): handed out only once its pictures and its face are here, each had on its own, how far on the button; one not had, 下载失败，重试 asks it again" {
  let held : Array[(String, (Result[(Json, Bytes), Json]) -> Unit)] = []
  @sffixture.fixture_looks_held.val = Some(held)
  let src = fixture_app("share-card-senren-adv")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(@motion.presence_in_ms)
  // each asked on its own: the look's picture, its tile's small one, the face's two weights
  let asked = held.map(fn(h) { h.0 })
  for file in ["1/a1-murasame-adv.webp", "1/a1-murasame-adv.small.webp", "1/face-400.gz", "1/face-600.gz"] {
    assert_true(asked.contains(file), msg="\{Repr(asked)}")
  }
  // nothing to save while they come: the button says so, and does nothing
  assert_true(t.query(Button, label="保存到相册") is None)
  t.click(Button, label="正在下载")
  t.run_for(@motion.presence_in_ms)
  assert_eq(t.kept().length(), 0)
  // the picture here, the face not had: 下载失败，重试
  let answer = fn(file : String, r : Result[(Json, Bytes), Json]) {
    for h in held {
      if h.0 == file {
        (h.1)(r)
      }
    }
  }
  // (come together, as a device takes the core's messages come between two frames)
  @signals.start_batch()
  for file in asked {
    if file.has_suffix(".webp") {
      answer(file, @sffixture.fixture_looks_answer(file))
    }
  }
  answer("1/face-400.gz", Err({ "code": "fonts", "message": "下载到的文件不对" }))
  answer("1/face-600.gz", @sffixture.fixture_looks_answer("1/face-600.gz"))
  @signals.end_batch()
  t.run_for(@motion.presence_in_ms)
  assert_true(t.query(Button, label="保存到相册") is None)
  held.clear()
  t.click(Button, label="下载失败，重试")
  t.run_for(@motion.presence_in_ms)
  // only what failed asked again
  assert_eq(held.map(fn(h) { h.0 }), ["1/face-400.gz"])
  answer("1/face-400.gz", @sffixture.fixture_looks_answer("1/face-400.gz"))
  t.run_for(@motion.presence_in_ms)
  @sffixture.fixture_looks_held.val = None
  t.click(Button, label="保存到相册")
  t.run_for(@motion.presence_in_ms)
  match png_size(t.kept()[0].2) {
    Some((pw, _)) => assert_eq(pw, 1080)
    None => fail("not a PNG")
  }
}

///|
/// How large the picture `t` shows is drawn for how large it is laid out (@sf.share_w_most wide): its ground's width as
/// drawn (the largest instance in share_ground's colour) over that.
fn picture_drawn_k(t : @ui.Tester) -> Double {
  let ink = @sf.share_ground
  let ch = fn(shift : Int) { ((ink >> shift) & 0xFFL).to_double() / 255.0 }
  let mut widest = 0.0
  for a in t.drawn_instances() {
    let near = (a[8] - ch(24)).abs() < 0.01 && (a[9] - ch(16)).abs() < 0.01 && (a[10] - ch(8)).abs() < 0.01
    if a[5] == 0.0 && near && a[11] > 0.5 && a[2] > widest {
      widest = a[2]
    }
  }
  if widest > 0.0 {
    widest / @sf.share_w_most
  } else {
    1.0
  }
}

///|
/// How long after it starts share-card-motion's made-up view has made all its changes (fixture_fleet's steps: 2 s, then
/// one each 1.6 s), and a little more.
let share_motion_done_ms : Double = 6000.0

///|
test "the card to share follows what the view says as it changes, made once: its figures and today's bar bound, nothing made again; a model come its own line, made alone" {
  for look in ["夜色", "小票", "终端"] {
    let src = fixture_app("share-card-motion")
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=430.0, h=932.0, platform=2)
    t.run_for(@motion.presence_in_ms)
    if look != "夜色" {
      t.click(Button, label=look)
      t.run_for(@motion.presence_in_ms)
    }
    assert_true(picture_says(t, "2.1 亿"), msg=look)
    assert_true(!picture_says(t, "GPT-6 Astra"), msg=look)
    t.tree_frames_from_now()
    t.run_for(share_motion_done_ms)
    // (the figures as the view says them now: the first model's tokens, the week's and today's chats archived)
    assert_true(picture_says(t, "2.3 亿"), msg=look)
    assert_true(!picture_says(t, "2.1 亿"), msg=look)
    assert_true(picture_says(t, "GPT-6 Astra"), msg=look)
    // (what the view's changes made: the new model's line alone, in one frame; nothing let go)
    let frames = t.tree_frames()
    let making = frames.filter(fn(f) { f.made > 0 })
    assert_true(making.length() == 1 && making[0].made <= share_motion_model_nodes, msg="\{look} \{Repr(making)}")
    assert_true(frames.iter().all(fn(f) { f.let_go == 0 }), msg=look)
    assert_eq(t.corner_faults(), [])
  }
}

///|
/// The most nodes a model's line of the card is made of (its box, its dot or key, its words, what is between them).
let share_motion_model_nodes : Int = 6

///|
test "the subscriptions' allowances and Profile's 概览's pool as pictures to share: each on the stage, saying what it shares, nothing cut short, handed out 1080 across" {
  for at in [(1440.0, 1000.0, 0), (390.0, 844.0, 2)] {
    for mode in [("share-accounts", "个订阅账号", "Claude 订阅"), ("share-pool", "Fable", "个账号可用")] {
      let src = fixture_app(mode.0)
      let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=at.0, h=at.1, platform=at.2)
      t.run_for(@motion.presence_in_ms)
      assert_true(picture_says(t, mode.1), msg="\{Repr((at, mode))}")
      assert_true(picture_says(t, mode.2), msg="\{Repr((at, mode))}")
      assert_true(picture_says(t, "一生万物，万物归一"), msg="\{Repr((at, mode))}")
      assert_eq(t.squeeze_faults(), [])
      assert_eq(t.corner_faults(), [])
      assert_eq(t.contrast_faults(), [])
      let png = if at.2 == 2 {
        t.click(Button, label="保存到相册")
        t.run_for(@motion.presence_in_ms)
        t.kept()[t.kept().length() - 1].2
      } else {
        t.click(Button, label="复制图片")
        t.frame()
        t.clipboard_png().unwrap()
      }
      // (three pixels a point: the pools' picture as wide as its charts side by side take, share_quota.mbt)
      let across = if mode.0 == "share-pool" { 2040 } else { 1080 }
      assert_true(png_size(png).map(fn(s) { s.0 }) == Some(across), msg="\{Repr((at, mode, png_size(png)))}")
    }
  }
}

///|
test "Profile overview shares charts or accounts from its header and charts directly from their own button" {
  for at in [(1280.0, 800.0, 0), (390.0, 844.0, 2)] {
    for (from_header, charts) in [(true, true), (true, false), (false, true)] {
      let src = fixture_app("place-profiles-sum-overview")
      let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=at.0, h=at.1, platform=at.2)
      t.run_for(@motion.presence_in_ms)
      if from_header {
        t.click(Button, label="分享")
        t.run_for(@motion.presence_in_ms)
        move_pick(t, if charts { "分享额度与恢复图" } else { "分享订阅额度" })
      } else {
        t.click(Button, label="分享额度与恢复图")
        t.run_for(@motion.presence_in_ms)
      }
      assert_true(picture_says(t, if charts { "个账号可用" } else { "个订阅账号" }))
      assert_eq(t.query(Tab, label="完全打码") is Some(_), !charts)
    }
  }
}

///|
test "Profile switching 账号 -> 概览 -> 账号 updates top bar share action on narrow place and medium tape" {
  for cfg in [(390.0, 844.0, 2, "place-profiles-sum-a"), (720.0, 844.0, 0, "settings-profiles-sum-a")] {
    let (w, h, platform, mode) = cfg
    let src = fixture_app(mode)
    @settings.profiles_narrow_overview.set(false)
    @settings.profiles_place_overview.set(false)
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~)
    t.run_for(@ui.move_most_ms)
    // 1. Initially on 账号: top bar button is 分享订阅额度, opens subscriptions picture directly
    t.click(Button, label="分享订阅额度")
    t.run_for(@motion.presence_in_ms)
    assert_true(picture_says(t, "个订阅账号"), msg="initial accounts share: \{mode}")
    t.click(Button, label="关闭")
    t.run_for(@motion.presence_in_ms)
    // 2. Switch to 概览: top bar button updates to 分享 menu -> 分享额度与恢复图
    t.click(Radio, label="概览")
    t.run_for(@ui.move_most_ms)
    t.click(Button, label="分享")
    t.run_for(@motion.presence_in_ms)
    move_pick(t, "分享额度与恢复图")
    assert_true(picture_says(t, "额度与恢复"), msg="overview pool share quota: \{mode}")
    assert_true(picture_says(t, "消耗速度"), msg="overview pool share pace: \{mode}")
    assert_true(picture_says(t, "个账号可用"), msg="overview pool share ready: \{mode}")
    assert_true(!picture_says(t, "输出速度"), msg="overview pool share hides interactive speed: \{mode}")
    t.click(Button, label="关闭")
    t.run_for(@motion.presence_in_ms)
    // 3. Switch back to 账号: top bar button returns to 分享订阅额度
    t.click(Radio, label="账号")
    t.run_for(@ui.move_most_ms)
    t.click(Button, label="分享订阅额度")
    t.run_for(@motion.presence_in_ms)
    assert_true(picture_says(t, "个订阅账号"), msg="returned accounts share: \{mode}")
  }
}

///|
test "the subscriptions' picture: 完全打码 over it keeps each name laid out as it is, dots drawn in its place; 部分打码 back to its email's first two letters" {
  let src = fixture_app("share-accounts")
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2)
  t.run_for(@motion.presence_in_ms)
  assert_true(picture_says(t, "af•••@proton.me"))
  assert_true(!picture_says(t, "afkdev1"))
  t.click(Tab, label="完全打码")
  t.run_for(@motion.presence_in_ms)
  // (the name itself kept, its line as long, drawn none: tiles in its place, @sf masked_words_box)
  assert_true(!picture_says(t, "afkdev1"))
  assert_true(!picture_says(t, "af•••"))
  assert_eq(t.squeeze_faults(), [])
  assert_eq(t.corner_faults(), [])
  t.click(Tab, label="部分打码")
  t.run_for(@motion.presence_in_ms)
  assert_true(picture_says(t, "af•••@proton.me"))
}
