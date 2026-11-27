// A link's card and a file's peek whose values name pictures (their tokens: the bytes come beside a call's answer,
// @sfbase.link_picture, file_peek_picture) show whole from the first frame they show, never first without the pictures
// and then with them: the pictures asked as the value is read, before the card opens; where they are not here as it
// opens, the card shows as it does while its topic is read till they are.

///|
/// The made-up station's cards (fixture_link_preview, fixture_file_peek) with their pictures' calls kept in `asked`, to
/// be answered when the test says (peek_pictures_answer), as the core answers them from outside.
fn peek_pictures_source(asked : Array[(String, Json, (Result[(Json, Bytes), Json]) -> Unit)]) -> Source {
  let made = @sfbase.made_source()
  {
    ..made,
    topic_read: fn(name, params) {
      let p = Some(Json::object(params))
      match name {
        "linkPreview" => { value: Some(@sffixture.fixture_link_preview(text(p, "url"))), error: None, version: 1 }
        "filePeek" => { value: Some(@sffixture.fixture_file_peek(text(p, "path"))), error: None, version: 1 }
        _ => made.topic(name, params).get().snapshot()
      }
    },
    read_bytes: fn(name, params, done) { asked.push((name, params, done)) },
  }
}

///|
/// What was asked of the pictures, answered now as the made-up core has them.
fn peek_pictures_answer(asked : Array[(String, Json, (Result[(Json, Bytes), Json]) -> Unit)]) -> Unit {
  let now = asked.copy()
  asked.clear()
  for a in now {
    (a.2)(@sffixture.fixture_peek_picture(a.0, a.1).unwrap_or(Err({ "code": "unknown_call", "message": "" })))
  }
  @ui.came_from_outside()
}

///|
/// A window `w` wide (窄排法 at 390, 宽排法 at 1280) with a link 截图 drawn and `card` attached to its node.
fn peek_pictures_tester(w : Double, card : (@view.View) -> Unit) -> @ui.Tester {
  @sfbase.reset()
  let t = @ui.Tester::new(fn(c) { @sf.begin(c) |> ignore }, w~, h=800.0, native=Mouse, pointing=Mouse)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(@sf.ui_theme_now)
    root.box(fn(col) {
      col.pad(Is(40.0)) |> ignore
      col.box(fn(link) {
        link
        .width(Is(Some(120.0)))
        .height(Is(Some(32.0)))
        .on_press(fn() {  })
        .says(Is(Some(@view.said(Button, label="截图"))))
        |> ignore
        card(link)
      })
      |> ignore
    })
    |> ignore
  })
  t
}

///|
/// The pointer rested on the link, frame by frame till its card has opened and come to rest, the pictures answered
/// after frame `answer_at`: in each frame, where the words `title` are laid out (None: not shown) and the sizes of the
/// images built.
fn peek_pictures_frames(
  t : @ui.Tester,
  asked : Array[(String, Json, (Result[(Json, Bytes), Json]) -> Unit)],
  title : String,
  answer_at : Int,
) -> Array[((Double, Double, Double, Double)?, Array[(Double, Double)])] {
  t.draw()
  let (x, y, w, h) = t.get(@ui.Role::Button, label="截图").rect
  t.move_to(x + w / 2.0, y + h / 2.0)
  let seen = []
  let frames = ((hover_open_ms + @ui.move_most_ms) / @ui.first_frame_ms).to_int() + answer_at + 4
  for i in 0..<frames {
    t.frame()
    if i == answer_at {
      peek_pictures_answer(asked)
    }
    let imgs = match @ui.view_tree() {
      Some(tree) => tree.drawn().filter(fn(d) { d.image is Some(_) }).map(fn(d) { (d.w, d.h) })
      None => []
    }
    seen.push((t.rect_of(title), imgs))
  }
  seen
}

///|
/// Whether every frame showing `title` built `images` images, and from the first of them on it was laid out where it
/// is in the last (the card's box the same from the first frame it shows); and that some did.
fn peek_pictures_whole(seen : Array[((Double, Double, Double, Double)?, Array[(Double, Double)])], images : Int) -> String {
  let shown = seen.filter(fn(f) { f.0 is Some(_) })
  guard shown.last() is Some((Some(last), last_images)) else { return "never shown" }
  for i, f in shown {
    if f.1.length() != images {
      return "frame \{i} of those shown: \{f.1.length()} images, not \{images}"
    }
    guard f.0 is Some(r) else { return "frame \{i} of those shown: title missing" }
    // (hover_card_node pops in with a slight scale from ~0.96 -> 1.0 without reflowing layout)
    let same_place = (r.0 - last.0).abs() <= 6.0 &&
      (r.1 - last.1).abs() <= 6.0 &&
      (r.2 - last.2).abs() <= last.2 * 0.06 + 1.0 &&
      (r.3 - last.3).abs() <= last.3 * 0.06 + 1.0
    let same_images = f.1.length() == last_images.length() &&
      {
        let mut ok = true
        for j in 0..<f.1.length() {
          let (w, h) = f.1[j]
          let (lw, lh) = last_images[j]
          if (w - lw).abs() > lw * 0.06 + 1.0 || (h - lh).abs() > lh * 0.06 + 1.0 {
            ok = false
          }
        }
        ok
      }
    if !same_place || !same_images {
      return "frame \{i} of those shown: at \{Repr(f.0)}, images \{Repr(f.1)}; at rest at \{Repr(last)}, \{Repr(last_images)}"
    }
  }
  ""
}

///|
test "a link's card naming an icon and a picture shows whole from its first frame, 窄排法 and 宽排法: its pictures asked as it is read, before it opens" {
  for w in [390.0, 1280.0] {
    let asked = []
    let src = peek_pictures_source(asked)
    let t = peek_pictures_tester(w, fn(row) {
      web_peek_node(row, src, "ws1/st1", fn() { "https://example.com/bench/shot" }, fn() { "截图" })
    })
    // (answered a frame after the pointer came onto the link: before its card opens, as the core's memory answers)
    let seen = peek_pictures_frames(t, asked, "列表滚动截图", 1)
    let res = peek_pictures_whole(seen, 2)
    assert_eq(res, "", msg="width \{w}: \{res}")
  }
}

///|
test "a pictured link's hover shows its picture and title without clipping, before or after the picture arrives" {
  for w in [390.0, 250.0, 1280.0] {
    for late in [false, true] {
      let asked = []
      let src = peek_pictures_source(asked)
      let t = peek_pictures_tester(w, fn(row) {
        web_peek_node(row, src, "ws1/st1", fn() { "https://example.com/bench/shot" }, fn() { "截图" })
      })
      t.draw()
      let (x, y, rw, rh) = t.get(@ui.Role::Button, label="截图").rect
      t.move_to(x + rw / 2.0, y + rh / 2.0)
      t.frame()
      if !late { peek_pictures_answer(asked) }
      t.run_for(hover_open_ms + @ui.move_most_ms)
      if late { peek_pictures_answer(asked) }
      t.run_for(@motion.pop_ms)
      let images = t.drawn_images()
      let clips = t.drawn_image_clips()
      let mut picture = -1
      for i in 0..<images.length() {
        if images[i][2] > 40.0 { picture = i }
      }
      let sources = t.sources_of("列表滚动截图")
      let said = "width \{w}, late \{late}: \{sources}"
      assert_true(picture >= 0, msg=said)
      let image = images[picture]
      let clip = clips[picture].0
      let title = t.rect_of("列表滚动截图").unwrap()
      let at_picture = t.sources_at(image[0] + image[2] / 2.0, image[1] + image[3] / 2.0)
      assert_true(image[1] + image[3] <= clip.3 + 0.5, msg="picture clipped: \{said}; \{at_picture}")
      assert_true(title.1 + title.3 <= clip.3 + 0.5, msg="title clipped: \{said}")
      assert_true(image[0] >= 0.0 && image[0] + image[2] <= w, msg="picture outside window: \{said}")
      assert_eq(t.audit(), [], msg=said)
    }
  }
}

///|
test "a picture file's peek shows whole from its first frame, 窄排法 and 宽排法: its picture asked as it is read, before it opens" {
  for w in [390.0, 1280.0] {
    let asked = []
    let src = peek_pictures_source(asked)
    let t = peek_pictures_tester(w, fn(row) { file_peek_test_node(row, src, "ws1/st1", "s-c1", "shots/list.png", None) })
    let seen = peek_pictures_frames(t, asked, "list.png", 1)
    assert_eq(peek_pictures_whole(seen, 1), "", msg="width \{w}")
    assert_true(asked.length() == 0, msg="width \{w}: asked once")
  }
}

///|
test "what a card shows waits for the pictures its value names: not here while one comes, here once each has come or failed, each asked once" {
  @sfbase.reset()
  let asked = []
  let src = peek_pictures_source(asked)
  let url = "https://example.com/bench/shot"
  let page = Some(@sffixture.fixture_link_preview(url))
  let peek = Some(@sffixture.fixture_file_peek("shots/list.png"))
  // (a picture of each kind coming: what shows them waits, as it does while their topic is read)
  assert_false(@sfbase.link_pictures_here(src, "ws1/st1", url, page))
  assert_eq(@sfbase.file_peek_picture(src, "ws1/st1", "s-c1", "shots/list.png", None, peek), "")
  assert_false(@sfbase.link_pictures_here(src, "ws1/st1", url, page), msg="still coming")
  assert_eq(asked.map(fn(a) { a.0 }), ["link.preview.picture", "link.preview.picture", "file.peek.picture"], msg="each asked once")
  peek_pictures_answer(asked)
  assert_true(@sfbase.link_pictures_here(src, "ws1/st1", url, page))
  let icon = @sfbase.link_picture(src, "ws1/st1", url, page, "icon")
  let image = @sfbase.link_picture(src, "ws1/st1", url, page, "image")
  assert_true(icon != "" && icon != "!" && image != "" && image != "!" && icon != image, msg="\{icon} \{image}")
  assert_eq(@sfbase.link_picture(src, "ws1/st1", url, page, "avatar"), "!", msg="none named")
  let shot = @sfbase.file_peek_picture(src, "ws1/st1", "s-c1", "shots/list.png", None, peek)
  assert_true(shot != "" && shot != "!", msg=shot)
  // (another picture named, by another token: asked anew)
  let other = page.map(fn(v) {
    match v {
      Object(m) => {
        let o = m.copy()
        o["image"] = Json::string("fix-image-2")
        Json::object(o)
      }
      _ => v
    }
  })
  assert_false(@sfbase.link_pictures_here(src, "ws1/st1", url, other))
  assert_eq(asked.length(), 1)
  peek_pictures_answer(asked)
  // (come: here again)
  assert_true(@sfbase.link_pictures_here(src, "ws1/st1", url, other))
  assert_eq(asked.length(), 0)
}

///|
test "a card's picture the core has none of shows the card without it, asked once" {
  let asked = []
  let src = peek_pictures_source(asked)
  // (a token the made-up core has no bytes of: its error)
  let v : Json = { "kind": "page", "url": "https://example.com/gone", "title": "没有图", "image": "fix-gone" }
  let src = {
    ..src,
    topic_read: fn(name, params) {
      if name == "linkPreview" {
        { value: Some(v), error: None, version: 1 }
      } else {
        (src.topic_read)(name, params)
      }
    },
  }
  let t = peek_pictures_tester(390.0, fn(row) {
    web_peek_node(row, src, "ws1/st1", fn() { "https://example.com/gone" }, fn() { "截图" })
  })
  let seen = peek_pictures_frames(t, asked, "没有图", 1)
  assert_eq(peek_pictures_whole(seen, 0), "")
  assert_eq(@sfbase.link_picture(src, "ws1/st1", "https://example.com/gone", Some(v), "image"), "!")
  assert_eq(asked.length(), 0)
}
