// Digits all one width (Ctx::text and Ctx::rich `tabular`, TextStyle's, the theme's): asked of the host as
// style_tabular.

///|
/// Whether `text` was shaped in a font with digits all one width, and whether in one without.
fn shaped_tabular(text : String) -> (Bool, Bool) {
  let mut tab = false
  let mut own = false
  for f in text_cache.fonts {
    if f.map.contains(text) {
      if (f.style & @hostapi.style_tabular) != 0 {
        tab = true
      } else {
        own = true
      }
    }
  }
  (tab, own)
}

///|
test "a number said to be tabular is shaped with digits all one width, words not said so as the font has them" {
  let on = Ref(true)
  let t = Tester::new(
    fn(c) {
      c.with_theme({ ..Theme::light(), tabular: false }, fn() {
        c.column(fn() {
          c.text("45%", tabular=on.val) |> ignore
          c.text("12 MB", style=text_style(size=Sm, tabular=true)) |> ignore
          c.text("v1.2") |> ignore
        })
        |> ignore
      })
    },
    w=300.0,
    h=200.0,
  )
  assert_eq(shaped_tabular("45%"), (true, false))
  assert_eq(shaped_tabular("12 MB"), (true, false))
  assert_eq(shaped_tabular("v1.2"), (false, true))
  // said otherwise: laid out again, as the font has them
  on.val = false
  t.frame()
  assert_eq(shaped_tabular("45%"), (true, true))
}

///|
test "default Theme::light and Theme::dark enable tabular digits while explicit opt-out and user words keep font figures" {
  assert_true(Theme::light().tabular)
  assert_true(Theme::dark().tabular)
  assert_true(Theme::narrow_light().tabular)
  assert_true(Theme::narrow_dark().tabular)
  let _ = Tester::new(
    fn(c) {
      c.column(fn() {
        c.text("3 of 12") |> ignore
        c.rich([span("Uploading "), span("42%", bold=true)]) |> ignore
        c.rich([span("I wrote 7 lines")], words=true) |> ignore
        c.text("v2.0", tabular=false) |> ignore
        // (no digit: shaped as it is either way, in the font the rest of the words without one are; the code face's
        // digits are all one width as they are)
        c.text("Done") |> ignore
        c.rich([span("1:03", mono=true)]) |> ignore
      })
      |> ignore
    },
    w=300.0,
    h=200.0,
  )
  assert_eq(shaped_tabular("3 of 12"), (true, false))
  assert_eq(shaped_tabular("42%"), (true, false))
  assert_eq(shaped_tabular("Uploading "), (false, true))
  assert_eq(shaped_tabular("I wrote 7 lines"), (false, true))
  assert_eq(shaped_tabular("v2.0"), (false, true))
  assert_eq(shaped_tabular("Done"), (false, true))
  assert_eq(shaped_tabular("1:03"), (false, true))
}

///|
test "a style's tabular is kept through then, a later one saying otherwise over it" {
  let s = text_style(size=Sm, tabular=true)
  assert_eq(s.then(text_style(weight=Semibold)).base.tabular, Some(true))
  assert_eq(s.then(text_style(tabular=false)).base.tabular, Some(false))
}

///|
test "View::words_tabular overrides the tree theme's tabular setting in measurement and shaping" {
  // Under Theme::light() (tabular: true), Some(false) disables style_tabular in both measure and paint.
  let t = Tester::new(fn(_c) {  }, w=300.0, h=200.0)
  t.tabular_wider(0.5)
  set_view_app(fn(root) {
    set_tree_theme(fn() { Theme::light() })
    root.box(fn(col) {
      col.lines_up(Is(Some(Start))) |> ignore
      col.box(fn(v) {
        v.words(Is("tab-default 1234")).words_look(Is(@view.WordsLook::of(12.0, wrap=false))) |> ignore
      })
      |> ignore
      col.box(fn(v) {
        v
        .words(Is("tab-off 1234"))
        .words_look(Is(@view.WordsLook::of(12.0, wrap=false)))
        .words_tabular(Is(Some(false)))
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  assert_eq(shaped_tabular("tab-default 1234"), (true, false))
  assert_eq(shaped_tabular("tab-off 1234"), (false, true))
  let w_default = match t.rect_of("tab-default 1234") {
    Some((_, _, w, _)) => w
    None => fail("missing tab-default 1234")
  }
  let w_off = match t.rect_of("tab-off 1234") {
    Some((_, _, w, _)) => w
    None => fail("missing tab-off 1234")
  }
  // 4 extra chars ("default" vs "off") = +24pt, plus 4 tabular digits (+0.5 * 12 = +6pt each = +24pt) => +48pt
  assert_true((w_default - w_off - 48.0).abs() < 0.5, msg="default=\{w_default}, off=\{w_off}")

  // Under tabular: false theme, Some(true) enables style_tabular in both measure and paint.
  let t2 = Tester::new(fn(_c) {  }, w=300.0, h=200.0)
  t2.tabular_wider(0.5)
  set_view_app(fn(root) {
    set_tree_theme(fn() { { ..Theme::light(), tabular: false } })
    root.box(fn(col) {
      col.lines_up(Is(Some(Start))) |> ignore
      col.box(fn(v) {
        v.words(Is("nontab-default 5678")).words_look(Is(@view.WordsLook::of(12.0, wrap=false))) |> ignore
      })
      |> ignore
      col.box(fn(v) {
        v
        .words(Is("nontab-on 5678"))
        .words_look(Is(@view.WordsLook::of(12.0, wrap=false)))
        .words_tabular(Is(Some(true)))
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t2.draw()
  assert_eq(shaped_tabular("nontab-default 5678"), (false, true))
  assert_eq(shaped_tabular("nontab-on 5678"), (true, false))
  let w_nontab_default = match t2.rect_of("nontab-default 5678") {
    Some((_, _, w, _)) => w
    None => fail("missing nontab-default 5678")
  }
  let w_nontab_on = match t2.rect_of("nontab-on 5678") {
    Some((_, _, w, _)) => w
    None => fail("missing nontab-on 5678")
  }
  // "nontab-default 5678" (19 chars * 6 = 114pt) vs "nontab-on 5678" (14 chars * 6 + 4*6 = 108pt)
  assert_true(
    (w_nontab_on - (14.0 * 6.0 + 4.0 * 6.0)).abs() < 0.5,
    msg="nontab_on=\{w_nontab_on}, nontab_default=\{w_nontab_default}",
  )
}

///|
test "ellipsized and lines_cut preserve style_tabular when truncation drops trailing digits" {
  let _ = Tester::new(fn(_c) {  }, w=300.0, h=200.0)
  // 1. One-line ellipsized: original has trailing digits, truncated prefix has no digits.
  let with_digits = "fix-win-hover PR #123"
  let lay = fn(s : String, keep_tabular : Bool) {
    layout_text(s, 12.0, 400, 1.0e9, false, line=18.0, style=@hostapi.style_tabular, keep_tabular~)
  }
  let full = lay(with_digits, false)
  // Width 84pt fits "fix-win-hover" (13 chars * 6 = 78pt) + "…" (6pt) = 84pt, dropping " PR #123".
  let cut = ellipsized(with_digits, full, 84.0, lay)
  assert_true(!has_digit(cut.text) && cut.text.has_suffix("…"), msg="unexpected cut: \{cut.text}")
  assert_eq(shaped_tabular(cut.text), (true, false))

  // Original has no digits: truncated prefix stays non-tabular (distinct prefix to avoid cache key overlap).
  let no_digits = "fix-mac-hover-plain-text"
  let full_no = lay(no_digits, false)
  let cut_no = ellipsized(no_digits, full_no, 84.0, lay)
  assert_true(!has_digit(cut_no.text) && cut_no.text.has_suffix("…"), msg="unexpected cut_no: \{cut_no.text}")
  assert_eq(shaped_tabular(cut_no.text), (false, true))

  // 2. Multi-line lines_cut (max_lines=1): original has trailing digits, truncated prefix has no digits.
  let multi_digits = "alpha-beta-gamma PR #456"
  let tl_multi = layout_words(
    multi_digits,
    12.0,
    400,
    102.0,
    true,
    balance=false,
    line=18.0,
    spacing=0.0,
    style=@hostapi.style_tabular,
    max_lines=1,
  )
  assert_true(!has_digit(tl_multi.text) && tl_multi.text.has_suffix("…"), msg="unexpected multi: \{tl_multi.text}")
  assert_eq(shaped_tabular(tl_multi.text), (true, false))

  let multi_no_digits = "delta-epsilon-zeta eta theta"
  let tl_multi_no = layout_words(
    multi_no_digits,
    12.0,
    400,
    102.0,
    true,
    balance=false,
    line=18.0,
    spacing=0.0,
    style=@hostapi.style_tabular,
    max_lines=1,
  )
  assert_true(
    !has_digit(tl_multi_no.text) && tl_multi_no.text.has_suffix("…"),
    msg="unexpected multi_no: \{tl_multi_no.text}",
  )
  assert_eq(shaped_tabular(tl_multi_no.text), (false, true))
}
