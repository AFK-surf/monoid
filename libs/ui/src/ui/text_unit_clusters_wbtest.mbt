// unit_clusters fast path and lazy Shaped::breaks: ASCII/CJK strings skip UAX #29 / joining / bidi scans,
// single-line layout and multi-run rich_prep skip per-run UAX #14 line-break scans, and results stay identical.

///|
test "unit_clusters matches UAX #29, non-joining, and LTR-only guarantees" {
  let simple_cases = [
    "hello world 123 !@#",
    "中文测试段落，包含标点（全角）和 English 123",
    "日本語ひらがなカタカナ漢字",
    "한국어 음절 테스트",
    "line1\nline2\tindented",
    "Claude Code · Opus 5.5 · 3 分钟前",
    "“引号”——省略号…•条目 × 2 ± 1° ¥100 €50 37℃ 10‰",
    "延迟 145ms → 125ms ← ↑ ↓ ≤ 16ms ≥ 0ms ≠ 1 ≈ 99% −5 ∞ ✓ ✗",
    "┌── root ├── child └── leaf │ ═══ ║",
    "café naïve résumé «français» ¿hola? x² + y³ = ½",
    "\u{00A5}\u{00A7}\u{00AB}\u{00B0}\u{00B1}\u{00B2}\u{00B3}\u{00B7}\u{00B9}\u{00BB}\u{00BF}\u{00D7}\u{00F7}",
    "\u{2013}\u{2014}\u{2018}\u{2019}\u{201A}\u{201B}\u{201C}\u{201D}",
    "\u{2022}\u{2026}\u{2030}\u{2032}\u{2033}\u{20AC}\u{2103}",
  ]
  for s in simple_cases {
    assert_true(unit_clusters(s), msg="expected simple: \{s}")
    let g = @text.graphemes(s)
    assert_eq(g.length(), s.length() + 1, msg="grapheme count mismatch: \{s}")
    for i in 0..<=s.length() {
      assert_eq(g[i], i, msg="grapheme boundary \{i} mismatch: \{s}")
    }
    assert_true(@text.bidi_mixed(s) is None, msg="unexpected bidi: \{s}")
    for i in 0..<s.length() {
      assert_false(joining(s, i), msg="unexpected joining at \{i}: \{s}")
    }
  }
  let added_cps = [
    0x00A5, 0x00A7, 0x00AB, 0x00B0, 0x00B1, 0x00B2, 0x00B3, 0x00B7, 0x00B9, 0x00BB, 0x00BC, 0x00BD, 0x00BE, 0x00BF,
    0x00C0, 0x00D6, 0x00D7, 0x00D8, 0x00E9, 0x00F6, 0x00F7, 0x00F8, 0x00FF, 0x2013, 0x2014, 0x2018, 0x2019, 0x201A,
    0x201B, 0x201C, 0x201D, 0x2022, 0x2026, 0x2030, 0x2032, 0x2033, 0x20AC, 0x2103, 0x2190, 0x2191, 0x2192, 0x2193,
    0x2212, 0x221E, 0x2248, 0x2260, 0x2264, 0x2265, 0x2500, 0x2502, 0x2514, 0x251C, 0x2550, 0x257F, 0x2713, 0x2717,
  ]
  for cp in added_cps {
    let s = Int::unsafe_to_char(cp).to_string()
    assert_true(unit_clusters(s), msg="expected unit_clusters for U+\{cp}")
    let g = @text.graphemes(s)
    assert_eq(g, [0, 1], msg="expected single grapheme for U+\{cp}")
    assert_true(@text.bidi_mixed(s) is None, msg="unexpected bidi for U+\{cp}")
    assert_false(joining(s, 0), msg="unexpected joining for U+\{cp}")
  }
  for cp in 0..<0x3000 {
    let s = Int::unsafe_to_char(cp).to_string()
    if unit_clusters(s) {
      assert_eq(@text.graphemes(s), [0, 1], msg="expected single grapheme for U+\{cp}")
      assert_eq(@text.graphemes(s + s), [0, 1, 2], msg="expected unjoined pair for U+\{cp}")
      assert_true(@text.bidi_mixed(s) is None, msg="unexpected bidi for U+\{cp}")
      assert_false(joining(s, 0), msg="unexpected joining for U+\{cp}")
    }
  }
  let complex_cases = [
    "a\r\nb",
    "e\u{0301}",
    "が\u{3099}",
    "🎉 emoji",
    "שלום עולם",
    "مرحبا",
    "ไทย",
    "हिन्दी",
    "a\u{200C}b",
    "a\u{200D}b",
    "a\u{200E}b",
    "a\u{200F}b",
    "a\u{202E}b",
    "a\u{2066}b",
    "©",
    "®",
    "™",
    "\u{2194}",
  ]
  for s in complex_cases {
    assert_false(unit_clusters(s), msg="expected non-simple: \{s}")
  }
}

///|
test "lazy Shaped::breaks: nowrap and multi-run rich_prep skip per-run line_breaks, wrap computes and caches" {
  let _ = Tester::new(fn(_) {  }, w=300.0, h=300.0)
  // 1. Single-line nowrap text leaves s.brk empty even for CJK + ASCII and \r\n.
  let nowrap = "单行标题 Single Line 123"
  let tl0 = layout_text(nowrap, 14.0, 400, 120.0, false)
  assert_true(tl0.shaped.brk.is_empty())
  assert_eq(tl0.line_start.length(), 1)
  // \r\n splits into two lines without needing s.brk.
  let crlf = "first\r\nsecond"
  let tl_crlf = layout_text(crlf, 14.0, 400, 200.0, false)
  assert_true(tl_crlf.shaped.brk.is_empty())
  assert_eq(tl_crlf.line_start.length(), 2)
  // 2. Wrapping text computes s.brk lazily and reuses the cached array.
  let tl1 = layout_text(nowrap, 14.0, 400, 60.0, true)
  assert_eq(tl1.shaped.brk.length(), tl1.shaped.starts.length())
  assert_true(tl1.line_start.length() > 1)
  let brk_first = tl1.shaped.brk
  let tl2 = layout_text(nowrap, 14.0, 400, 40.0, true)
  assert_true(physical_equal(tl2.shaped.brk, brk_first))
  // 3. Multi-run rich_prep defers UAX #14 breaks until rich_lines actually overflows a line.
  let run_a = "多段富文本前缀 "
  let run_b = "加粗关键词"
  let run_c = " 以及后续长内容需要折行测试"
  let r : Rich = {
    runs: [plain(run_a), bold(run_b), plain(run_c)],
    size: 14.0,
    weight: 400,
    color: 0xFF000000L,
    line: 0.0,
    trim: false,
    wrap: true,
    link_color: 0xFF0000FFL,
    pressed_bg: 0L,
    code_color: 0xFF333333L,
    code_bg: 0xFFEEEEEEL,
    code_scale: 0.9,
    spacing: 0.0,
    base: 0,
    select: false,
    max_lines: 0,
    faces: 0,
    shaped_in: 0,
    cjk_override: None,
    code_cjk_override: None,
  }
  let prep = rich_prep(r)
  assert_true(prep.brk.is_empty())
  assert_true(shape(run_a, 14.0, 400).brk.is_empty())
  assert_true(shape(run_b, 14.0, 700).brk.is_empty())
  assert_true(shape(run_c, 14.0, 400).brk.is_empty())
  // Wide layout fits on one line: prep.brk remains empty.
  let lay_wide = rich_lines(r, prep, 1000.0)
  assert_eq(lay_wide.line_start.length(), 1)
  assert_true(prep.brk.is_empty())
  // Narrow layout overflows: prep.brk is computed on demand and matches eager breaks bit-for-bit.
  let lay = rich_lines(r, prep, 80.0)
  assert_true(lay.line_start.length() > 1)
  assert_eq(prep.brk.length(), prep.starts.length())
  let eager_prep = rich_prep(r)
  ignore(eager_prep.breaks())
  let eager_lay = rich_lines(r, eager_prep, 80.0)
  assert_eq(lay.line_start, eager_lay.line_start)
  assert_eq(lay.line_end, eager_lay.line_end)
  assert_eq(lay.line_w, eager_lay.line_w)
  assert_eq(lay.xs, eager_lay.xs)
  assert_eq(lay.line_y, eager_lay.line_y)
  assert_eq(lay.line_h, eager_lay.line_h)
  assert_eq(lay.w, eager_lay.w)
  assert_eq(lay.h, eager_lay.h)
}

///|
test "layout_text defers line_breaks until soft-wrap overflow and matches eager breaks bit-for-bit" {
  let _ = Tester::new(fn(_) {  }, w=400.0, h=300.0)
  // 1. wrap=true text that fits on one line (or only splits on hard newlines) leaves s.brk empty.
  let single = "单行自适应标题 Single Line Title 2026"
  let tl_fit = layout_text(single, 14.0, 400, 1000.0, true)
  assert_true(tl_fit.shaped.brk.is_empty())
  assert_eq(tl_fit.line_start.length(), 1)
  let hard_only = "第一行 short\n第二行 ok\r\n第三行 fine"
  let tl_hard = layout_text(hard_only, 14.0, 400, 1000.0, true)
  assert_true(tl_hard.shaped.brk.is_empty())
  assert_eq(tl_hard.line_start.length(), 3)
  // 2. When a previously unfitted Shaped overflows at a narrow width, s.brk is computed on demand and matches eager layout.
  let samples = [
    "Hello world! AV To Wa Yo, testing punctuation (parens) and trailing spaces   end.",
    "中文排版的「括号」与句号。逗号，不能出现在行首！English + 12345 混排测试。",
    "first line fits\nsecond line overflows with long words supercalifragilistic and 中文内容",
    "no-spaces-very-long-identifier-without-break-opportunities-until-hyphens",
    "a b c d e f g h i j k l m n o p",
  ]
  for idx, text in samples {
    for max_w in [45.0, 80.0, 140.0] {
      for indent in [0.0, 18.0] {
        // Fresh lazy run (clear shape cache so s.brk starts empty).
        clear_shapes()
        let lazy_tl = layout_text(text, 14.0, 400, max_w, true, indent~)
        // Fresh eager run (pre-populate s.brk before layout_text).
        clear_shapes()
        let eager_s = shape(text, 14.0, 400)
        ignore(eager_s.breaks(text))
        let eager_tl = layout_text(text, 14.0, 400, max_w, true, indent~)
        assert_eq(lazy_tl.line_start, eager_tl.line_start, msg="sample \{idx} w=\{max_w} indent=\{indent}: line_start")
        assert_eq(lazy_tl.line_end, eager_tl.line_end, msg="sample \{idx} w=\{max_w} indent=\{indent}: line_end")
        assert_eq(lazy_tl.line_w, eager_tl.line_w, msg="sample \{idx} w=\{max_w} indent=\{indent}: line_w")
        assert_eq(lazy_tl.xs, eager_tl.xs, msg="sample \{idx} w=\{max_w} indent=\{indent}: xs")
        assert_eq(lazy_tl.w, eager_tl.w, msg="sample \{idx} w=\{max_w} indent=\{indent}: w")
        assert_eq(lazy_tl.h, eager_tl.h, msg="sample \{idx} w=\{max_w} indent=\{indent}: h")
      }
    }
  }
}

///|
test "rich_lines defers line_breaks until overflow and matches eager breaks across chips, leads, mixed sizes, and empty trailing lines" {
  let _ = Tester::new(fn(_) {  }, w=400.0, h=300.0)
  let chip_ground : Ground = { room: 0.4, height: 1.4, corner: 0.3, after: 0.2 }
  let cases : Array[Array[Run]] = [
    [plain("单行富文本 "), bold("加粗"), plain(" 145ms → 125ms ≤ 16ms")],
    [plain("第一行 short\n第二行 "), bold("bold ok"), plain("\r\n第三行 fine\n")],
    [plain("中文排版「括号」与句号。"), bold("English + 12345"), plain(" 混排测试，折行时不能把逗号放行首！")],
    [plain("prefix "), span("chip_label", bg=0x22007AFFL, ground=Some(chip_ground)), plain(" suffix text that wraps across multiple lines")],
    [span("• ", ground=Some(leads)), plain("hanging list item with "), code("inline_code()"), plain(" and long trailing 中文内容")],
    [plain("normal "), span("big heading run", scale=1.5), plain("\n"), plain("back to normal\n")],
  ]
  for idx, runs in cases {
    let r : Rich = {
      runs,
      size: 14.0,
      weight: 400,
      color: 0xFF000000L,
      line: 0.0,
      trim: false,
      wrap: true,
      link_color: 0xFF0000FFL,
      pressed_bg: 0L,
      code_color: 0xFF333333L,
      code_bg: 0xFFEEEEEEL,
      code_scale: 0.9,
      spacing: 0.0,
      base: 0,
      select: false,
      max_lines: 0,
      faces: 0,
      shaped_in: 0,
      cjk_override: None,
      code_cjk_override: None,
    }
    // Non-overflowing wide layout must keep prep.brk empty.
    clear_shapes()
    rich_kept.clear()
    let p_wide = rich_prep(r)
    let lay_wide = rich_lines(r, p_wide, 2000.0)
    assert_true(p_wide.brk.is_empty(), msg="case \{idx}: wide layout should defer brk")
    let p_wide_eager = rich_prep(r)
    ignore(p_wide_eager.breaks())
    let lay_wide_eager = rich_lines(r, p_wide_eager, 2000.0)
    assert_eq(lay_wide.line_start, lay_wide_eager.line_start, msg="case \{idx} wide: line_start")
    assert_eq(lay_wide.line_end, lay_wide_eager.line_end, msg="case \{idx} wide: line_end")
    assert_eq(lay_wide.line_h, lay_wide_eager.line_h, msg="case \{idx} wide: line_h")
    assert_eq(lay_wide.w, lay_wide_eager.w, msg="case \{idx} wide: w")
    assert_eq(lay_wide.h, lay_wide_eager.h, msg="case \{idx} wide: h")
    // Overflowing widths must match eager breaks bit-for-bit.
    for max_w in [55.0, 95.0, 160.0] {
      clear_shapes()
      rich_kept.clear()
      let p_lazy = rich_prep(r)
      let lay_lazy = rich_lines(r, p_lazy, max_w)
      clear_shapes()
      rich_kept.clear()
      let p_eager = rich_prep(r)
      ignore(p_eager.breaks())
      let lay_eager = rich_lines(r, p_eager, max_w)
      assert_eq(lay_lazy.line_start, lay_eager.line_start, msg="case \{idx} w=\{max_w}: line_start")
      assert_eq(lay_lazy.line_end, lay_eager.line_end, msg="case \{idx} w=\{max_w}: line_end")
      assert_eq(lay_lazy.line_w, lay_eager.line_w, msg="case \{idx} w=\{max_w}: line_w")
      assert_eq(lay_lazy.xs, lay_eager.xs, msg="case \{idx} w=\{max_w}: xs")
      assert_eq(lay_lazy.line_y, lay_eager.line_y, msg="case \{idx} w=\{max_w}: line_y")
      assert_eq(lay_lazy.line_h, lay_eager.line_h, msg="case \{idx} w=\{max_w}: line_h")
      assert_eq(lay_lazy.line_base, lay_eager.line_base, msg="case \{idx} w=\{max_w}: line_base")
      assert_eq(lay_lazy.w, lay_eager.w, msg="case \{idx} w=\{max_w}: w")
      assert_eq(lay_lazy.h, lay_eager.h, msg="case \{idx} w=\{max_w}: h")
      // Independently verify line_y / line_h / line_base / h against per-cluster dmax reference.
      let mut ref_y = 0.0
      let mut ref_last_extra = p_lazy.extra
      let ref_last_line = lay_lazy.line_start.length() - 1
      for li in 0..<lay_lazy.line_start.length() {
        let s0 = lay_lazy.line_start[li]
        let e0 = lay_lazy.line_end[li]
        let mut la = p_lazy.base_asc
        let mut ld = p_lazy.base_desc
        let is_last = li == ref_last_line
        for c in s0..<e0 {
          let rk = p_lazy.run_of[c]
          la = dmax(la, p_lazy.run_lasc[rk])
          ld = dmax(ld, p_lazy.run_ldesc[rk])
          if is_last {
            ref_last_extra = dmax(ref_last_extra, p_lazy.run_extra[rk])
          }
        }
        assert_eq(lay_lazy.line_y[li], ref_y, msg="case \{idx} w=\{max_w} line \{li}: ref line_y")
        assert_eq(lay_lazy.line_h[li], la + ld, msg="case \{idx} w=\{max_w} line \{li}: ref line_h")
        assert_eq(lay_lazy.line_base[li], la, msg="case \{idx} w=\{max_w} line \{li}: ref line_base")
        ref_y = ref_y + la + ld
      }
      assert_eq(lay_lazy.h, ref_y + ref_last_extra, msg="case \{idx} w=\{max_w}: ref h")
    }
  }
  // Single-run rich_prep_one reuses the shared Shaped.brk cache across rich_kept evictions.
  clear_shapes()
  rich_kept.clear()
  let one_r : Rich = {
    runs: [plain("单段长文本复用 Shaped.brk 缓存避免 rich_kept 淘汰后重复做 UAX #14 分析")],
    size: 14.0,
    weight: 400,
    color: 0xFF000000L,
    line: 0.0,
    trim: false,
    wrap: true,
    link_color: 0xFF0000FFL,
    pressed_bg: 0L,
    code_color: 0xFF333333L,
    code_bg: 0xFFEEEEEEL,
    code_scale: 0.9,
    spacing: 0.0,
    base: 0,
    select: false,
    max_lines: 0,
    faces: 0,
    shaped_in: 0,
    cjk_override: None,
    code_cjk_override: None,
  }
  let p1 = rich_prep(one_r)
  ignore(rich_lines(one_r, p1, 80.0))
  assert_eq(p1.brk.length(), p1.starts.length())
  rich_kept.clear()
  let p2 = rich_prep(one_r)
  ignore(rich_lines(one_r, p2, 80.0))
  assert_true(physical_equal(p1.brk, p2.brk))
}
