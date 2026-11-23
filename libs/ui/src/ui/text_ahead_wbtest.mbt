// What a frame hands its host to draw ahead (glyphs_ahead) as its tree is laid out: each glyph at the phase it is then
// painted at (laid_ahead), not phase 0 alone.

///|
/// A page of words as a chat's are laid out: plain words and runs of several styles, Han and Latin, wrapped, each in a
/// column at a whole number of points from the window's edge; at a size whose Han is no whole number of pixels wide at
/// any scale the test draws at, as most sizes are.
fn ahead_page(root : @view.View) -> Unit {
  root.box(fn(p) {
    p.width(Is(Some(360.0))).padding(Is((16.0, 16.0, 16.0, 16.0))) |> ignore
    p.box(fn(v) {
      v
      .width(Is(Some(328.0)))
      .words(
        Is("今天把渲染的预热改成排版之后立即派发，Latin words between them, 再看一下首帧。"),
        look={ ..@view.words_plain, size: 15.3, line: 22.0, wrap: true },
      )
      |> ignore
    })
    |> ignore
    p.box(fn(v) {
      v
      .width(Is(Some(328.0)))
      .words_runs(
        Is([
          @view.words_run("富文本里的"),
          @view.words_run("粗体段落", weight=700),
          @view.words_run(" and a code-ish run ", weight=500),
          @view.words_run("然后又回到正文，一直写到第二行以后才结束。"),
        ]),
        look={ ..@view.words_plain, size: 15.3, line: 22.0, wrap: true },
      )
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// The glyphs the frame placed (their keys with their phase), and how many of them were asked ahead at that phase, and
/// how many at phase 0.
fn ahead_hits(asked : Array[Int]) -> (Int, Int, Int) {
  let at : Map[Int, Bool] = Map([])
  for k in asked {
    at[k] = true
  }
  let mut placed = 0
  let mut hit = 0
  let mut first = 0
  for k, _ in text_cache.glyphs {
    placed = placed + 1
    if at.contains(k) {
      hit = hit + 1
    }
    if (k >> 26) == 0 {
      first = first + 1
    }
  }
  (placed, hit, first)
}

///|
test "glyphs laid out are asked ahead at the phase the frame paints them at" {
  for sc in [2.75, 3.0, 2.0] {
    let asked : Array[Int] = []
    fake_ahead.val = Some(asked)
    let t = Tester::new(fn(_c) {  }, w=400.0, h=400.0, scale=sc)
    // (Latin letters of widths of a real face's, none a whole number of pixels)
    t.latin_advances(
      FixedArray::makei(95, fn(i) { 0.45 + (i % 7).to_double() * 0.037 }),
      FixedArray::makei(95, fn(i) { 0.48 + (i % 5).to_double() * 0.041 }),
    )
    set_view_app(ahead_page)
    t.draw()
    fake_ahead.val = None
    let (placed, hit, first) = ahead_hits(asked)
    assert_true(placed > 60, msg="scale \{sc}: \{placed} placed")
    // (every glyph the frame painted was asked ahead at its own phase, before it was painted: the frame's first ask
    // is its tree's layout's)
    assert_eq(hit, placed, msg="scale \{sc}: \{hit} of \{placed} asked at their phase")
    // (where phase 0 alone was asked, most would have been drawn on the frame's thread)
    assert_true(first * 2 < placed, msg="scale \{sc}: \{first} of \{placed} at phase 0")
    // (each asked once)
    let seen : Map[Int, Bool] = Map([])
    for k in asked {
      assert_true(!seen.contains(k), msg="scale \{sc}: \{k} asked twice")
      seen[k] = true
    }
  }
}

///|
test "a glyph shaped and not laid out is asked at phase 0, once; one laid out is not asked again at phase 0" {
  let asked : Array[Int] = []
  fake_ahead.val = Some(asked)
  let _t = Tester::new(fn(_c) {  }, w=200.0, h=100.0, scale=2.75)
  // shaped alone: its glyphs at phase 0
  let s = shape("只量不排", 15.0, 400)
  glyphs_ahead()
  assert_eq(asked, s.keys.filter(fn(k) { k >= 0 }))
  // laid out: at the phases of its line, none of them again at phase 0 for having been shaped
  asked.clear()
  let tl = layout_text("排版之后 laid", 15.0, 400, 300.0, false)
  glyphs_ahead()
  fake_ahead.val = None
  let want = []
  for c, k in tl.shaped.keys {
    if k >= 0 {
      want.push(glyph_sub_at(k, tl.xs[c] + tl.shaped.pad, g().scale, 1.0))
    }
  }
  let seen : Map[Int, Bool] = Map([])
  let want = want.filter(fn(k) {
    let first = !seen.contains(k)
    seen[k] = true
    first
  })
  assert_eq(asked, want)
  assert_true(asked.iter().any(fn(k) { (k >> 26) != 0 }))
}

///|
test "between-frame event layout dispatches glyphs_ahead before next draw with zero duplicate on draw" {
  let asked : Array[Int] = []
  let show = @signals.signal(false)
  let t = Tester::new(fn(_c) {  }, w=400.0, h=400.0, scale=2.75)
  t.latin_advances(
    FixedArray::makei(95, fn(i) { 0.45 + (i % 7).to_double() * 0.037 }),
    FixedArray::makei(95, fn(i) { 0.48 + (i % 5).to_double() * 0.041 }),
  )
  set_view_app(fn(root) {
    root.laid_before_causes()
    root.box(fn(p) {
      p.width(Is(Some(360.0))).padding(Is((16.0, 16.0, 16.0, 16.0))) |> ignore
      p.show(
        fn() { show.get() },
        fn(v) {
          v
          .width(Is(Some(328.0)))
          .words(
            Is("帧间事件新增文本节点，在下一帧绘制之前就应该提前派发字形预热。"),
            look={ ..@view.words_plain, size: 15.3, line: 22.0, wrap: true },
          )
          |> ignore
        },
        at_once=true,
      )
      |> ignore
    })
    |> ignore
  })
  t.draw()
  fake_ahead.val = Some(asked)
  view_event(fn() { show.set(true) })
  let before_draw = asked.length()
  assert_true(before_draw > 15, msg="expected glyphs_ahead during between-frame event, got \{before_draw}")
  t.draw()
  fake_ahead.val = None
  let seen : Map[Int, Bool] = Map([])
  for k in asked {
    assert_true(!seen.contains(k), msg="duplicate (key, phase) dispatched across event + draw: \{k}")
    seen[k] = true
  }
  let (placed, hit, _) = ahead_hits(asked)
  assert_true(placed > 15)
  assert_eq(hit, placed, msg="\{hit} of \{placed} placed glyphs asked at their phase")
}

///|
test "heavy single-frame layout flushes glyphs_laid mid-layout without touching fresh and with zero duplicates" {
  let asked : Array[Int] = []
  let t = Tester::new(fn(_c) {  }, w=400.0, h=600.0, scale=2.75)
  t.latin_advances(
    FixedArray::makei(95, fn(i) { 0.45 + (i % 7).to_double() * 0.037 }),
    FixedArray::makei(95, fn(i) { 0.48 + (i % 5).to_double() * 0.041 }),
  )
  set_view_app(fn(_root) {  })
  t.draw()
  fake_ahead.val = Some(asked)
  // Pre-shape a second paragraph (as Flex width measurement does) before laying out the first paragraph.
  let long_b = "菜重芥姜海咸河淡鳞潜羽翔龙师火帝鸟官人皇始制文字乃服衣裳推位让国有虞陶唐"
  let shaped_b = shape(long_b, 15.3, 400)
  let fresh_before = text_cache.fresh.length()
  assert_true(fresh_before > 20)
  // > 48 distinct characters in one layout_text call triggers glyphs_laid_flush() mid-layout without draining fresh.
  let long_a = "天地玄黄宇宙洪荒日月盈昃辰宿列张寒来暑往秋收冬藏闰余成岁律吕调阳云腾致雨露结为霜金生丽水玉出昆冈剑号巨阙珠称夜光果珍李柰"
  let _ = layout_text(long_a, 15.3, 400, 328.0, true)
  let mid_count = asked.length()
  assert_true(
    mid_count >= glyphs_ahead_batch,
    msg="expected mid-layout flush >= \{glyphs_ahead_batch}, got \{mid_count}",
  )
  // text_cache.fresh must NOT have been drained by glyphs_laid_flush().
  assert_true(text_cache.fresh.length() >= fresh_before, msg="glyphs_laid_flush must not drain text_cache.fresh")
  // None of long_b's unique glyphs should have been prematurely dispatched at phase 0 before long_b is laid out.
  let asked_mid : Map[Int, Bool] = Map([])
  for k in asked {
    asked_mid[k & 0x03FFFFFF] = true
  }
  for k in shaped_b.keys {
    if k >= 0 {
      assert_false(asked_mid.contains(k), msg="shaped-only glyph \{k} must not be flushed before its layout")
    }
  }
  // Now lay out long_b (with overlapping chars from long_a too) and flush frame end with glyphs_ahead().
  let _ = layout_text("天地玄黄" + long_b, 15.3, 400, 328.0, true)
  glyphs_ahead()
  fake_ahead.val = None
  assert_true(asked.length() > mid_count, msg="expected remaining glyphs flushed after second layout")
  let seen : Map[Int, Bool] = Map([])
  for k in asked {
    assert_true(!seen.contains(k), msg="duplicate (key, phase) in single frame: \{k}")
    seen[k] = true
  }
}

///|
/// A page with non-integer-pixel padding, nested code blocks, blockquotes, and list items to verify
/// `measuring_origin_x` predicts exact subpixel phases at non-integer device scales.
fn ahead_non_int_dpi_page(root : @view.View) -> Unit {
  root.box(fn(p) {
    p.width(Is(Some(351.0))).padding(Is((16.0, 16.0, 16.0, 16.0))) |> ignore
    // 1. Padding 16pt plain text
    p.box(fn(v) {
      v
      .width(Is(Some(319.0)))
      .words(
        Is("非整数 DPI 下的正文段落，padding=16pt，验证首帧预热相位完全命中。"),
        look={ ..@view.words_plain, size: 15.3, line: 22.0, wrap: true },
      )
      |> ignore
    })
    |> ignore
    // 2. Nested code block: 16 + 14 = 30pt horizontal origin
    p.box(fn(code_box) {
      code_box.width(Is(Some(319.0))).padding(Is((14.0, 14.0, 14.0, 14.0))) |> ignore
      code_box.box(fn(v) {
        v
        .words_breaks(Is(true))
        .words_runs(
          Is([
            @text.span("fn ", mono=true, color=0xFFCF222EL),
            @text.span("render_code", mono=true, color=0xFF0550AEL),
            @text.span("(dpi: Double) {\n  let x = 30.0\n}", mono=true, color=0xFF1D1D1FL),
          ]),
          look={ ..@view.words_plain, size: 13.0, line: 19.0, wrap: false },
        )
        |> ignore
      })
      |> ignore
    })
    |> ignore
    // 3. Blockquote: Row(2pt bar + 10pt pad/gap) -> 16 + 2 + 10 = 28pt
    p.box(fn(bq) {
      bq.row(Is(true)).width(Is(Some(319.0))).gap(Is(10.0)) |> ignore
      bq.box(fn(bar) { bar.width(Is(Some(2.0))).height(Is(Some(20.0))) |> ignore }) |> ignore
      bq.box(fn(v) {
        v
        .width(Is(Some(307.0)))
        .words(
          Is("引用块里的文字在非整数缩放下同样应保持 100% 相位命中。"),
          look={ ..@view.words_plain, size: 14.5, line: 21.0, wrap: true },
        )
        |> ignore
      })
      |> ignore
    })
    |> ignore
    // 4. List item: Row(20pt marker + 8pt gap) -> 16 + 20 + 8 = 44pt
    p.box(fn(item) {
      item.row(Is(true)).width(Is(Some(319.0))).gap(Is(8.0)) |> ignore
      item.box(fn(marker) { marker.width(Is(Some(20.0))).height(Is(Some(20.0))) |> ignore }) |> ignore
      item.box(fn(v) {
        v
        .width(Is(Some(291.0)))
        .words_runs(
          Is([
            @view.words_run("列表项"),
            @view.words_run("加粗前缀 ", weight=700),
            @view.words_run("followed by body text at 44pt origin."),
          ]),
          look={ ..@view.words_plain, size: 15.0, line: 22.0, wrap: true },
        )
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
test "non-integer DPI first-frame layout hits 100% of painted subpixel glyph phases" {
  for sc in [3.6, 4.1, 2.625, 1.25, 2.75] {
    let asked : Array[Int] = []
    fake_ahead.val = Some(asked)
    let t = Tester::new(fn(_c) {  }, w=351.0, h=600.0, scale=sc)
    t.latin_advances(
      FixedArray::makei(95, fn(i) { 0.45 + (i % 7).to_double() * 0.037 }),
      FixedArray::makei(95, fn(i) { 0.48 + (i % 5).to_double() * 0.041 }),
    )
    set_view_app(ahead_non_int_dpi_page)
    t.draw()
    fake_ahead.val = None
    let (placed, hit, _) = ahead_hits(asked)
    assert_true(placed > 80, msg="scale \{sc}: expected > 80 placed glyphs, got \{placed}")
    assert_eq(hit, placed, msg="scale \{sc}: \{hit} of \{placed} glyphs hit predicted subpixel phase")
    let seen : Map[Int, Bool] = Map([])
    for k in asked {
      assert_true(!seen.contains(k), msg="scale \{sc}: duplicate (key, phase) dispatched: \{k}")
      seen[k] = true
    }
  }
}

///|
test "non-integer DPI between-frame nodes under placed ancestors hit 100% of painted subpixel phases" {
  for sc in [3.6, 4.1, 2.625, 1.25, 2.75] {
    let asked : Array[Int] = []
    let show = @signals.signal(false)
    let t = Tester::new(fn(_c) {  }, w=351.0, h=600.0, scale=sc)
    t.latin_advances(
      FixedArray::makei(95, fn(i) { 0.45 + (i % 7).to_double() * 0.037 }),
      FixedArray::makei(95, fn(i) { 0.48 + (i % 5).to_double() * 0.041 }),
    )
    set_view_app(fn(root) {
      root.laid_before_causes()
      root.box(fn(p) {
        p.width(Is(Some(351.0))).padding(Is((16.0, 16.0, 16.0, 16.0))) |> ignore
        // Placed outer container with padding 14pt
        p.box(fn(code_box) {
          code_box.width(Is(Some(319.0))).padding(Is((14.0, 14.0, 14.0, 14.0))) |> ignore
          code_box.show(
            fn() { show.get() },
            fn(v) {
              v
              .width(Is(Some(291.0)))
              .words(
                Is("帧间在已放置容器内新增代码与中文段落，验证 30pt 原点相位预测。"),
                look={ ..@view.words_plain, size: 15.3, line: 22.0, wrap: true },
              )
              |> ignore
            },
            at_once=true,
          )
          |> ignore
        })
        |> ignore
        // Placed Row with 20pt marker + 8pt gap
        p.box(fn(item) {
          item.row(Is(true)).width(Is(Some(319.0))).gap(Is(8.0)) |> ignore
          item.box(fn(marker) { marker.width(Is(Some(20.0))).height(Is(Some(20.0))) |> ignore }) |> ignore
          item.show(
            fn() { show.get() },
            fn(v) {
              v
              .width(Is(Some(291.0)))
              .words_runs(
                Is([
                  @view.words_run("新增行内"),
                  @view.words_run("高亮片段 ", weight=700),
                  @view.words_run("under placed row at 44pt."),
                ]),
                look={ ..@view.words_plain, size: 15.0, line: 22.0, wrap: true },
              )
              |> ignore
            },
            at_once=true,
          )
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    t.draw()
    fake_ahead.val = Some(asked)
    view_event(fn() { show.set(true) })
    let before_draw = asked.length()
    assert_true(before_draw > 20, msg="scale \{sc}: expected glyphs_ahead during event, got \{before_draw}")
    t.draw()
    fake_ahead.val = None
    let seen : Map[Int, Bool] = Map([])
    for k in asked {
      assert_true(!seen.contains(k), msg="scale \{sc}: duplicate (key, phase) across event + draw: \{k}")
      seen[k] = true
    }
    let (placed, hit, _) = ahead_hits(asked)
    assert_true(placed > 20, msg="scale \{sc}: expected > 20 placed glyphs, got \{placed}")
    assert_eq(hit, placed, msg="scale \{sc}: \{hit} of \{placed} glyphs hit predicted subpixel phase")
  }
}
