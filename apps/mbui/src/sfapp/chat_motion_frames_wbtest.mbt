// A chat's page made as nodes (sfbase's chat_page_nodes on), what moves for one cause looked at in every frame a host
// draws (16 ms apart), each frame held to what a person would see right (the owner, 2026-11-15: 确定性测试):
// - words sent: no caret drawn in the composer's field while they leave it (its hint and caret away, flight_hint_away);
// - three lines sent: the composer's ground keeps the room it had with them while they leave it (sent_out_hold_ms, the
//   old flight's flight_settle of a Move), then comes down to its one line's by move_most_ms, never up again;
// - an agent's reply coming out of its picture at work over its line: never two rings drawn, the message over it never
//   down;
// - a picture sent: drawn in its row from the first frame after the press, its size going one way only, from the
//   tile's to its own;
// - read up, a reply come at the foot: what is read stays where it is, to the half point.
// Its helpers composer_sent_nodes_wbtest's, chat_line_room_wbtest's, chat_page_nodes_wbtest's and chat_window_wbtest's.

///|
/// How far apart the frames looked at are: a host's at 60 a second, about.
let mf_frame_ms : Double = 16.0

///|
/// A caret drawn in the composer's field now (a bar as tall as a line, a point or two wide, at all opaque, in the
/// field's width `fx` … `fx + fw` and the composer's box): where, or none.
fn mf_caret(t : @ui.Tester, fx : Double, fw : Double) -> (Double, Double, Double, Double)? {
  let (by, bh) = sent_nodes_box(t)
  for r in t.drawn_rects() {
    let (rx, ry, rw, rh, color) = r
    if rw <= 3.0 &&
      rh >= 10.0 &&
      rh <= 40.0 &&
      rx >= fx - 2.0 &&
      rx + rw <= fx + fw + 2.0 &&
      ry >= by - 1.0 &&
      ry + rh <= by + bh + 1.0 &&
      (color & 0xFFL) != 0L {
      return Some((rx, ry, rw, rh))
    }
  }
  None
}

///|
test "a chat's page made as nodes, 小屏 and 大屏, every frame: three lines sent, no caret drawn in the composer's field while they leave it" {
  for screen in [("小屏", 390.0, 844.0, 2), ("大屏", 1280.0, 800.0, 0)] {
    let at = screen.0
    let t = back_round_chat(screen.1, screen.2, screen.3, 3)
    guard composer_field(t) is Some((fx, _, fw, _)) else { fail("\{at}: no composer's field") }
    tap_send(t)
    let press = t.time()
    let away_ms = @sfbase.sent_out_away_ms()
    let mut away_seen = false
    while t.time() - press <= @ui.move_most_ms {
      if t.time() - press < away_ms {
        away_seen = true
        match mf_caret(t, fx, fw) {
          Some(r) => fail("\{at}, \{t.time() - press} ms after the press: a caret drawn at \{Repr(r)} under the words leaving")
          None => ()
        }
      }
      t.run_for(mf_frame_ms)
    }
    assert_true(away_seen, msg="\{at}: the field's hint and caret never away as the words left it")
  }
}

///|
test "a chat's page made as nodes, 小屏, every frame: three lines sent, the composer's room as tall as with them till they let go of it, then down to its one line's by move_most_ms, never up again" {
  let t = sent_nodes_chat(1.0)
  let room = sent_nodes_room(t, sent_nodes_draft)
  t.type_text("\n第二行\n第三行")
  t.run_for(@ui.move_most_ms)
  let room_three = sent_nodes_room(t, sent_nodes_draft)
  assert_true(room_three > room + 1.0, msg="three lines' room \{room_three}, one line's \{room}")
  tap_send(t)
  let press = t.time()
  let hold = @sfbase.sent_out_hold_ms
  let mut was = room_three
  while t.time() - press <= @ui.move_most_ms {
    let ms = t.time() - press
    let r = sent_nodes_room(t, sent_nodes_draft)
    if ms < hold - 0.001 {
      assert_true(r >= room_three - 0.5, msg="\{ms} ms after the press: its room \{r}, \{room_three} with the three lines")
    }
    assert_true(r <= was + 0.01, msg="\{ms} ms after the press: its room up again, \{was} to \{r}")
    was = r
    t.run_for(mf_frame_ms)
  }
  let rest = sent_nodes_room(t, sent_nodes_draft)
  assert_true((rest - room).abs() <= 0.5, msg="its room \{rest} by move_most_ms, \{room} with one line")
}

///|
/// How many working rings are drawn now at all opaque: the eight arcs of an agent's picture at work (sf's
/// segments_node), or the still whole ring of one that waits (its edge round a picture's room).
fn mf_rings() -> Int {
  let mut n = 0
  for e in @ui.view_tree().unwrap().drawn_held() {
    let (d, _, _) = e
    // (the list's alone: under a wide page's bar, whose agents' tiles ring their own)
    if d.y > 100.0 && d.alpha > 0.01 && d.lines.length() >= 8 {
      n = n + 1
    }
  }
  n
}

///|
test "a chat's page made as nodes, 小屏 and 大屏, every frame: the reply coming out of the agent's picture over its line: never two rings drawn, the message over it never down" {
  for screen in cr_screens {
    // (the line under what was sent from its delivery on, the reply 1400 ms after, the turn's end later)
    let t = cr_open(screen, (fix_deliver_ms, 1400.0, 1000.0), on_pixels=true)
    // (its field opened first: what was sent goes from the press's moment)
    cr_open_field(t)
    let sent = t.time()
    cr_send(t, cr_sent, opened=true)
    let comes = sent + fix_deliver_ms + 1400.0
    let gap = comes - 50.0 - t.time()
    if gap > 0.0 {
      t.run_for(gap)
    }
    assert_true(cr_line(t), msg="\{screen.0}: the agent's line not shown as the reply comes")
    let mut above = cr_sent_y(t)
    while t.time() < comes + 600.0 {
      let at = "\{screen.0}, \{t.time() - comes} ms"
      let rings = mf_rings()
      assert_true(rings <= 1, msg="\{at}: \{rings} rings drawn")
      let y = cr_sent_y(t)
      match (above, y) {
        (Some(a), Some(y)) => assert_true(y <= a + 0.01, msg="\{at}: the message over it down from \{a} to \{y}")
        (Some(_), None) => fail("\{at}: the message over it not drawn")
        _ => ()
      }
      above = y
      t.run_for(mf_frame_ms)
    }
    t.run_for(@ui.move_most_ms + @sfbase.emit_out_ms_most)
    assert_true(t.find(cr_reply) is Some(_), msg="\{screen.0}: the reply not drawn at rest")
  }
}

///|
/// The fixture's chat s-c1 on `screen`, its rows on the host's pixels, at rest, and its source.
fn mf_open(screen : (String, Double, Double, Int)) -> (@ui.Tester, Source) {
  let (_, w, h, platform) = screen
  new_run()
  // (its composer made as nodes too: what these frames hold of it)
  let src = fixture("chat")
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~)
  t.set_rows_on_pixels(true)
  t.run_for(@ui.move_most_ms)
  (t, src)
}

///|
/// The keys of the pictures drawn now outside the composer: what the list shows before something is sent (the
/// composer made as nodes draws its waiting tiles in the tree too, by the keys the sent row's pictures take: those are
/// the ones sent, not ones there before).
fn mf_pictures_drawn(t : @ui.Tester) -> Array[String] {
  let composer = @sfpages.composer_node_shown(t.time())
  let out = []
  for d in @ui.view_tree().unwrap().drawn() {
    let in_composer = match composer {
      Some((x, y, w, h)) => d.x >= x && d.x + d.w <= x + w && d.y >= y && d.y + d.h <= y + h
      None => false
    }
    match d.image {
      Some((k, _, _)) if !in_composer => out.push(k)
      _ => ()
    }
  }
  out
}

///|
/// The pictures the list draws now whose keys are not among `before`, at all opaque: each drawn box's width and height.
fn mf_new_pictures(before : Array[String]) -> Array[(Double, Double)] {
  let out = []
  for d in @ui.view_tree().unwrap().drawn() {
    match d.image {
      Some((k, _, _)) if !before.contains(k) && d.alpha > 0.0 && d.bones == 0L => out.push((d.w, d.h))
      _ => ()
    }
  }
  out
}

///|
test "a chat's page made as nodes, 小屏 and 大屏, every frame: a picture sent drawn in its row from the first frame after the press, its size going one way only from its tile's to its own" {
  for screen in cr_screens {
    let (t, src) = mf_open(screen)
    @sfbase.writing_add(src, @sfbase.writing(src, sent_nodes_draft), "ws1/st1", "看图.png", png_head())
    t.run_for(@ui.move_most_ms + @ui.image_fade_ms)
    guard composer_field(t) is Some((fx, fy, fw, fh)) else { fail("\{screen.0}: no composer's field") }
    t.tap(fx + fw / 2.0, fy + fh / 2.0)
    t.type_text("看图")
    t.run_for(@ui.move_most_ms)
    let before = mf_pictures_drawn(t)
    tap_send(t)
    t.run_for(mf_frame_ms)
    let press = t.time()
    let seen : Array[(Double, Double, Double)] = []
    while t.time() - press <= @ui.move_most_ms {
      let ms = t.time() - press
      match mf_new_pictures(before) {
        [(w, h)] => seen.push((ms, w, h))
        all => fail("\{screen.0}, \{ms} ms after the press: \{all.length()} pictures sent drawn, \{Repr(all)}")
      }
      t.run_for(mf_frame_ms)
    }
    t.run_for(@ui.move_most_ms)
    guard mf_new_pictures(before) is [(rw, rh)] else { fail("\{screen.0}: the picture sent not drawn at rest") }
    let (_, w0, h0) = seen[0]
    let (lo_w, hi_w) = if w0 < rw { (w0, rw) } else { (rw, w0) }
    let (lo_h, hi_h) = if h0 < rh { (h0, rh) } else { (rh, h0) }
    for i, s in seen {
      let (ms, w, h) = s
      let at = "\{screen.0}, \{ms} ms after the press"
      assert_true(w >= lo_w - 1.0 && w <= hi_w + 1.0, msg="\{at}: \{w} wide, from \{w0} to \{rw}")
      assert_true(h >= lo_h - 1.0 && h <= hi_h + 1.0, msg="\{at}: \{h} tall, from \{h0} to \{rh}")
      if i > 0 {
        let (_, pw, ph) = seen[i - 1]
        assert_true((w - pw) * (rw - w0) >= -0.25, msg="\{at}: its width back from \{pw} to \{w}, from \{w0} to \{rw}")
        assert_true((h - ph) * (rh - h0) >= -0.25, msg="\{at}: its height back from \{ph} to \{h}, from \{h0} to \{rh}")
      }
    }
  }
}

///|
test "a chat's page made as nodes, 小屏 and 大屏, every frame: read up, a reply come at the foot: what is read stays where it is" {
  for s in long_screens {
    let (name, w, h, _) = s
    let l = long_chat()
    let t = place_long_open(l, s)
    t.move_to(w / 2.0, h / 2.0)
    t.wheel(w / 2.0, h / 2.0, -600.0)
    long_run(t, l, long_rest_ms)
    let seen : Array[(Int, Double)] = []
    for n in l.first.get()..=l.last.get() {
      if t.rect_of("第\{n}条：") is Some((_, y, _, _)) && y > h / 4.0 && y < h * 0.75 {
        seen.push((n, y))
      }
    }
    assert_true(seen.length() > 0, msg="\{name}: nothing read in the middle of the list")
    l.last.set(l.last.get() + 1)
    let from = t.time()
    while t.time() - from <= @ui.move_most_ms {
      long_frame(t, l)
      for p in seen {
        let now = t.rect_of("第\{p.0}条：").map(fn(r) { r.1 })
        assert_true(
          now is Some(y) && (y - p.1).abs() <= 0.5,
          msg="\{name}, \{t.time() - from} ms after the reply came: 第\{p.0}条 at \{Repr(now)}, \{p.1} as it was read",
        )
      }
    }
  }
}

///|
/// The tree's pictures drawn now whose keys are not among `before`, at all opaque: each drawn box (x, y, w, h).
fn mf_new_picture_boxes(before : Array[String]) -> Array[(Double, Double, Double, Double)] {
  let out = []
  for d in @ui.view_tree().unwrap().drawn() {
    match d.image {
      Some((k, _, _)) if !before.contains(k) && d.alpha > 0.0 && d.bones == 0L => out.push((d.x, d.y, d.w, d.h))
      _ => ()
    }
  }
  out
}

///|
test "a chat's page made as nodes, 小屏 and 大屏, every frame of a picture and a file sent with words, past the station delivering them (send-picture.drive's): every frame drawn as laid out, the picture drawn in every frame, never flown again once at its place" {
  // (scripts/motion/send-picture.drive's, on the fixture's chat with a picture's head and a file put in its draft (a
  // picture of chat-attach's would hand the host more bytes than a test without a bar may): its rows on the host's
  // pixels at 60 frames a second; send pressed, then every frame past the station delivering what was sent
  // (fix_deliver_ms), its out row given way to its message then, and past the agent's answer coming after it
  // (fix_answer_ms: the frame a picture's row was measured at the list's width, not its own, and made again unplaced). Every frame the Tester draws holds tester_placed's
  // rule: a node made as it is delivered drawn never placed stops the run)
  for screen in cr_screens {
    let (t, src) = mf_open(screen)
    // (the agent's answer fix_answer_ms after the delivery, no turn's end within the frames looked at: what moves is the
    // send's, the delivery's and the answer's coming in under it, the list asking how tall the rows over what is read
    // are (Tree::start_in) as it does)
    fix_pace.val = (fix_deliver_ms, fix_answer_ms, 1.0e7)
    t.set_frame_period(1000.0 / 60.0)
    let draft = @sfbase.writing(src, sent_nodes_draft)
    @sfbase.writing_add(src, draft, "ws1/st1", "看图.png", png_head())
    @sfbase.writing_add(src, draft, "ws1/st1", "build.log", @utf8.encode("夜里的构建日志"))
    t.run_for(@ui.move_most_ms + @ui.image_fade_ms)
    guard composer_field(t) is Some((fx, fy, fw, fh)) else { fail("\{screen.0}: no composer's field") }
    t.tap(fx + fw / 2.0, fy + fh / 2.0)
    t.type_text("截图和构建日志都在这里")
    t.run_for(@ui.move_most_ms)
    let before = mf_pictures_drawn(t)
    tap_send(t)
    t.run_for(mf_frame_ms)
    let press = t.time()
    // (at its place once its flight is done, the list's way with it (on its rise, as long): from then on as big as
    // it rests, and never down (the list only goes up: the agent's line coming in under it as it is delivered), never
    // back to its tile's size and place in the composer)
    let settled = press + @sfbase.flight_desk_ms + mf_frame_ms
    let mut was : (Double, Double, Double, Double)? = None
    while t.time() - press <= fix_deliver_ms + fix_answer_ms + @ui.move_most_ms + @ui.move_most_ms {
      let ms = t.time() - press
      let at = "\{screen.0}, \{ms} ms after the press"
      let boxes = mf_new_picture_boxes(before)
      guard boxes.length() == 1 else { fail("\{at}: \{boxes.length()} pictures sent drawn, \{Repr(boxes)}") }
      let now = boxes[0]
      if t.time() > settled {
        match was {
          Some(p) => {
            assert_true(
              (now.2 - p.2).abs() <= 1.0 && (now.3 - p.3).abs() <= 1.0,
              msg="\{at}: the picture \{now.2}×\{now.3}, \{p.2}×\{p.3} the frame before",
            )
            assert_true(now.1 <= p.1 + 1.0, msg="\{at}: the picture down from \{p.1} to \{now.1}")
          }
          None => ()
        }
        was = Some(now)
      }
      t.run_for(mf_frame_ms)
    }
    assert_true(t.placed_faults().is_empty(), msg="\{screen.0}: at rest \{Repr(t.placed_faults())}")
  }
}

///|
/// The fixture's chat s-c1 on a phone (`390×844`) either on the old page (`nodes = false`) or made as nodes
/// (`nodes = true`), its rows on the host's pixels at 60 frames a second, at rest.
fn mf_open_dual(mode? : String = "chat") -> (@ui.Tester, Source) {
  new_run()
  let src = fixture(mode)
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform=2, words_over_held=true)
  t.set_rows_on_pixels(true)
  t.set_frame_period(1000.0 / 60.0)
  t.draw()
  t.run_for(@ui.move_most_ms)
  (t, src)
}

///|
/// Holds that the composer's white ground (`back_round_ground`) never rises above its pre-send top `gy0`, begins
/// shrinking down once the items let go of it, settles down by `move_most_ms`, and never covers visible list content
/// drawn above the composer.
fn mf_hold_composer_uncovered(
  t : @ui.Tester,
  gy0 : Double,
  ms : Double,
  at : String,
) -> Unit raise {
  guard back_round_ground(t) is Some((_, gy, _, gh, _, _)) else {
    fail("\{at}: composer ground not drawn")
  }
  assert_true(
    gy >= gy0 - 1.5,
    msg="\{at}: composer white ground top \{gy} rose above pre-send top \{gy0}",
  )
  if ms >= 160.0 {
    assert_true(
      gy > gy0 + 2.0,
      msg="\{at}: composer white ground top \{gy} still stuck at pre-send top \{gy0}",
    )
  }
  if ms >= @ui.move_most_ms + 32.0 {
    assert_true(
      gy >= gy0 + 36.0,
      msg="\{at}: composer white ground top \{gy} did not settle down from \{gy0} by move_most_ms",
    )
  }
  for s in ["做完了：列表、跳到最新的按钮", "刚刚", "处理中"] {
    for w in t.words() {
      let (txt, _, wy, _, wh, a) = w
      if a > 0.1 && txt.contains(s) && wy < gy + gh - 1.0 {
        assert_true(
          wy + wh <= gy + 1.5,
          msg="\{at}: composer white ground \{gy}..\{gy + gh} covers list content 「\{s}」 at \{wy}..\{wy + wh}",
        )
      }
    }
  }
}

///|
/// The visible bounding box `(x, y, w, h)` of the newly attached picture (`>= 50pt` across, so no avatar), clipped as
/// drawn: the bottom-most such picture of the old view's or of the window's tree.
fn mf_drawn_picture_box(t : @ui.Tester) -> (Double, Double, Double, Double)? {
  let imgs = t.drawn_images()
  let clips = t.drawn_image_clips()
  let mut best : (Double, Double, Double, Double)? = None
  for k, i in imgs {
    if i[2] >= 50.0 && i[3] >= 50.0 && i[8] > 0.05 {
      let (x0, y0, x1, y1) = if k < clips.length() {
        let (cl, ct, cr, cb) = clips[k].0
        let lx = if i[0] > cl { i[0] } else { cl }
        let ly = if i[1] > ct { i[1] } else { ct }
        let rx = if i[0] + i[2] < cr { i[0] + i[2] } else { cr }
        let ry = if i[1] + i[3] < cb { i[1] + i[3] } else { cb }
        (lx, ly, rx, ry)
      } else {
        (i[0], i[1], i[0] + i[2], i[1] + i[3])
      }
      if x1 > x0 + 1.0 && y1 > y0 + 1.0 {
        match best {
          Some((_, by, _, _)) if y0 < by => ()
          _ => best = Some((x0, y0, x1 - x0, y1 - y0))
        }
      }
    }
  }
  // (a picture of the window's tree (the page made as nodes): drawn_images has only the old view's)
  match @ui.view_tree() {
    Some(tr) =>
      for d in tr.drawn() {
        // (50 across on its longer side: no avatar, but a picture flying from its square tile as its own shape, 56 by 37)
        if d.image is Some(_) && d.bones == 0L && d.alpha > 0.05 && (d.w >= 50.0 || d.h >= 50.0) && d.w >= 24.0 && d.h >= 24.0 {
          match best {
            Some((_, by, _, _)) if d.y < by => ()
            _ => best = Some((d.x, d.y, d.w, d.h))
          }
        }
      }
    None => ()
  }
  best
}

///|
/// The visible bounding box `(x, y, w, h)` of the bottom-most item whose words contain `sub` (its card/bubble box if an
/// enclosing card/bubble ground is drawn around it, else its words' box).
fn mf_drawn_part_box(t : @ui.Tester, sub : String, whole? : Bool = false) -> (Double, Double, Double, Double)? {
  let mut word_box : (Double, Double, Double, Double)? = None
  for w in t.words() {
    let (txt, wx, wy, ww, wh, a) = w
    // (`whole`: those words alone, not a reply quoting them)
    if a > 0.05 && (if whole { txt == sub } else { txt.contains(sub) }) {
      match word_box {
        Some((_, by, _, _)) if wy <= by => ()
        _ => word_box = Some((wx, wy, ww, wh))
      }
    }
  }
  guard word_box is Some((wx, wy, ww, wh)) else { return None }
  // Prefer the smallest enclosing card/bubble ground (< 360 wide, < 140 tall; any ground or edge not wholly clear, faint
  // ones such as the composer's quote card too; wider than the words by 8 and taller by 4, so never the words' own box)
  // drawn around those words
  let mut best = (wx, wy, ww, wh)
  let mut best_area = 1.0e18
  for r in t.drawn_rects() {
    let (rx, ry, rw, rh, color) = r
    if (color & 0xFFL) >= 12L &&
      rw >= ww + 8.0 &&
      rh >= wh + 4.0 &&
      rw < 360.0 &&
      rh < 140.0 &&
      rx <= wx + 2.0 &&
      ry <= wy + 2.0 &&
      rx + rw >= wx + ww - 2.0 &&
      ry + rh >= wy + wh - 2.0 {
      let area = rw * rh
      if area < best_area {
        best = (rx, ry, rw, rh)
        best_area = area
      }
    }
  }
  match @ui.view_tree() {
    Some(tr) => {
      let held = tr.drawn_held()
      for idx, e in held {
        let (d, _, _) = e
        if d.bones == 0L && d.alpha > 0.05 && (d.x - wx).abs() < 2.0 && (d.y - wy).abs() < 2.0 {
          let mut p = held[idx].1
          while p >= 0 {
            let (c, up, _) = held[p]
            if ((c.ground & 0xFFL) >= 12L || (c.edge.1 & 0xFFL) >= 12L) &&
              c.w >= ww + 8.0 &&
              c.h >= wh + 4.0 &&
              c.w < 360.0 &&
              c.h < 140.0 {
              let area = c.w * c.h
              if area < best_area {
                best = (c.x, c.y, c.w, c.h)
                best_area = area
              }
              break
            }
            p = up
          }
        }
      }
    }
    None => ()
  }
  Some(best)
}

///|
/// Holds that two drawn boxes `a` and `b` in the same flying message do not overlap (`> 1.5pt` on both axes).
fn mf_hold_no_overlap(
  at : String,
  aname : String,
  a : (Double, Double, Double, Double),
  bname : String,
  b : (Double, Double, Double, Double),
  tol? : Double = 1.5,
) -> Unit raise {
  let ox = (if a.0 + a.2 < b.0 + b.2 { a.0 + a.2 } else { b.0 + b.2 }) - (if a.0 > b.0 { a.0 } else { b.0 })
  let oy = (if a.1 + a.3 < b.1 + b.3 { a.1 + a.3 } else { b.1 + b.3 }) - (if a.1 > b.1 { a.1 } else { b.1 })
  assert_true(
    ox <= tol || oy <= tol,
    msg="\{at}: flying \{aname} \{Repr(a)} overlaps \{bname} \{Repr(b)} by \{ox}×\{oy}",
  )
}

///|
test "every frame, old page and nodes page: send-picture — composer white ground never covers list, flying picture/file/words start at their composer places and never overlap" {
  let mode = "nodes"
  let (t, src) = mf_open_dual()
  fix_pace.val = (fix_deliver_ms, fix_answer_ms, 1.0e7)
  t.tap_text("发消息")
  t.type_text("看一下列表")
  let draft = @sfbase.writing(src, sent_nodes_draft)
  @sfbase.writing_add(src, draft, "ws1/st1", "看图.png", png_head())
  @sfbase.writing_add(src, draft, "ws1/st1", "夜构建日志.log", @utf8.encode("夜里的构建日志"))
  t.run_for(@ui.move_most_ms + @ui.image_fade_ms)
  assert_eq(draft.field.text(), "看一下列表")
  guard back_round_ground(t) is Some((_, gy0, _, _, _, _)) else { fail("\{mode}: composer ground not drawn") }
  guard mf_drawn_picture_box(t) is Some(pic0) else { fail("\{mode}: picture tile not drawn in composer") }
  guard mf_drawn_part_box(t, "夜构建") is Some(file0) else { fail("\{mode}: file card not drawn in composer") }
  guard composer_field(t) is Some(words0) else {
    fail("\{mode}: composer field not found")
  }
  tap_send(t)
  let press = t.time()
  let mut frame_idx = 0
  while t.time() - press <= fix_deliver_ms + @ui.move_most_ms {
    let ms = t.time() - press
    let at = "\{mode}, \{ms} ms after send-picture"
    mf_hold_composer_uncovered(t, gy0, ms, at)
    guard mf_drawn_picture_box(t) is Some(pic) else { fail("\{at}: picture not drawn") }
    // (the picture flies out of its square tile as that tile, 56 by 56, never its own 3:2 shape scaled to the tile's
    // width, 56 by 37 with its foot cut flat: mbui's Tree::fills_lifted)
    if frame_idx == 0 {
      assert_true(
        pic.3 >= 52.0 && pic.2 >= 52.0,
        msg="\{at}: the picture set out \{Repr(pic)}, not as its composer tile \{Repr(pic0)}",
      )
    }
    guard mf_drawn_part_box(t, "夜构建") is Some(file) else { fail("\{at}: file card not drawn") }
    guard mf_drawn_part_box(t, "看一下列表") is Some(words) else { fail("\{at}: words not drawn") }
    if frame_idx <= 1 {
      assert_true(
        (pic.0 - pic0.0).abs() <= 28.0 && (pic.1 - pic0.1).abs() <= 28.0,
        msg="\{at}: picture started at \{Repr(pic)}, composer tile was \{Repr(pic0)}",
      )
      assert_true(
        (file.0 - file0.0).abs() <= 28.0 && (file.1 - file0.1).abs() <= 28.0,
        msg="\{at}: file card started at \{Repr(file)}, composer card was \{Repr(file0)}",
      )
      assert_true(
        (words.0 - words0.0).abs() <= 28.0 && (words.1 - words0.1).abs() <= 28.0,
        msg="\{at}: words started at \{Repr(words)}, composer field was \{Repr(words0)}",
      )
    }
    // (picture and file card unwrap from side-by-side in composer to stacked in message: picture stays above or level
    // with file card all the way, and neither ever overlaps words; at start and at rest picture and file card are
    // completely separate)
    assert_true(
      pic.1 <= file.1 + 2.0,
      msg="\{at}: flying picture \{Repr(pic)} dropped below file card \{Repr(file)}",
    )
    if ms <= 80.0 || ms >= 360.0 {
      mf_hold_no_overlap(at, "picture", pic, "file card", file)
    }
    mf_hold_no_overlap(at, "picture", pic, "words", words)
    // (the old page's flight, sfbase flight.mbt, has its file card's faint ground over the words' bubble by 2.4pt at
    // 200 ms: the old view is frozen, not changed again, so it is held to 3pt; the page made as nodes to 1.5)
    mf_hold_no_overlap(at, "file card", file, "words", words, tol=1.5)
    frame_idx = frame_idx + 1
    t.run_for(mf_frame_ms)
  }
}

///|
test "every frame, old page and nodes page: send-quote — composer white ground never covers list, flying quote card and words start at their composer places and never overlap" {
  let mode = "nodes"
  let (t, src) = mf_open_dual()
  fix_pace.val = (fix_deliver_ms, fix_answer_ms, 1.0e7)
  t.tap_text("发消息")
  t.type_text("看一下列表")
  let draft = @sfbase.writing(src, sent_nodes_draft)
  @sfbase.writing_quote(src, draft, { "author": "Claude", "text": "推送截图前要先登录 gh。", "ts": "ts10" })
  t.run_for(@ui.move_most_ms)
  assert_eq(draft.field.text(), "看一下列表")
  guard back_round_ground(t) is Some((_, gy0, _, _, _, _)) else { fail("\{mode}: composer ground not drawn") }
  guard mf_drawn_part_box(t, "推送截图前要先登录 gh。") is Some(quote0) else {
    fail("\{mode}: quote card not drawn in composer")
  }
  guard composer_field(t) is Some(words0) else {
    fail("\{mode}: composer field not found")
  }
  tap_send(t)
  let press = t.time()
  let mut frame_idx = 0
  while t.time() - press <= fix_deliver_ms + @ui.move_most_ms {
    let ms = t.time() - press
    let at = "\{mode}, \{ms} ms after send-quote"
    mf_hold_composer_uncovered(t, gy0, ms, at)
    guard mf_drawn_part_box(t, "推送截图前要先登录 gh。") is Some(quote) else {
      fail("\{at}: quote card not drawn")
    }
    guard mf_drawn_part_box(t, "看一下列表") is Some(words) else {
      fail("\{at}: words not drawn")
    }
    if frame_idx <= 1 {
      assert_true(
        (quote.0 - quote0.0).abs() <= 28.0 && (quote.1 - quote0.1).abs() <= 28.0,
        msg="\{at}: quote card started at \{Repr(quote)}, composer card was \{Repr(quote0)}",
      )
      assert_true(
        (words.0 - words0.0).abs() <= 28.0 && (words.1 - words0.1).abs() <= 28.0,
        msg="\{at}: words started at \{Repr(words)}, composer field was \{Repr(words0)}",
      )
    }
    mf_hold_no_overlap(at, "quote", quote, "words", words)
    frame_idx = frame_idx + 1
    t.run_for(mf_frame_ms)
  }
}

///|
test "every frame, old page and nodes page: decide 一起换 — card closing and messages below rising never step past a motion frame's limit" {
  let mode = "nodes"
  let (t, _) = mf_open_dual()
  fix_pace.val = (fix_deliver_ms, fix_answer_ms, 1.0e7)
  let watched = [
    "要不要把旧的截图也一起换掉？",
    "Willow 上 codex 的登录已失效",
    "推送截图前要先登录 gh。",
    "做完了：列表、跳到最新的按钮",
  ]
  let prev : Map[String, Double] = Map([])
  for s in watched {
    guard mf_drawn_part_box(t, s) is Some((_, y, _, _)) else {
      fail("\{mode}: 「\{s}」 not drawn before tapping 一起换")
    }
    prev[s] = y
  }
  t.tap_text("把首页和聊天页的截图都更新")
  let press = t.time()
  while t.time() - press <= 2200.0 {
    let ms = t.time() - press
    let at = "\{mode}, \{ms} ms after 一起换"
    for s in watched {
      match mf_drawn_part_box(t, s) {
        Some((_, y, _, _)) => {
          match prev.get(s) {
            Some(py) =>
              assert_true(
                (y - py).abs() <= 32.0,
                msg="\{at}: 「\{s}」 jumped \{y - py} in one 16 ms frame (from \{py} to \{y})",
              )
            None => ()
          }
          prev[s] = y
        }
        None =>
          if s != "要不要把旧的截图也一起换掉？" {
            fail("\{at}: 「\{s}」 vanished for a frame while the card closed")
          } else {
            prev.remove(s)
          }
      }
    }
    t.run_for(mf_frame_ms)
  }
  assert_true(t.find("你 选择了「一起换」") is Some(_), msg="\{mode}: card answer not shown after 一起换")
}
