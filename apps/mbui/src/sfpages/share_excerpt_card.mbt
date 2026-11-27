// International Typographic Style selected-text share card and stage preview (ported from Comma AFK-surf/Cue#5786).
// Renders a 420pt poster (1260px wide at 3x Retina via @ui.take_picture) with faded surrounding context, crisp
// selected body text, dynamic type sizing, single-card / multi-card pagination (up to 9 cards), product lockup, and
// a scannable dotted vector QR plate.

///|
/// Fixed poster palette: light neutral paper and near-black ink, theme-independent as an exported image has no theme.
let ex_paper : Int64 = 0xF5F5F5FFL

///|
let ex_ink : Int64 = 0x1A1B1EFFL

///|
let ex_ink_secondary : Int64 = 0x4A4C50FFL

///|
let ex_meta : Int64 = 0x7F8286FFL

///|
let ex_plate : Int64 = 0xFFFFFFFFL

///|
let ex_plate_line : Int64 = 0x1A1B1E14L

///|
/// Poster logical width (420pt -> 1260px at 3x Retina scale).
let ex_card_w : Double = 420.0

///|
let ex_card_min_h : Double = 540.0

///|
let ex_margin : Double = 38.0

///|
let ex_qr_side : Double = 72.0

///|
let ex_qr_plate_pad : Double = 9.0

///|
let ex_qr_mark_side : Double = 14.0

///|
let ex_shot_prefix : String = "share-excerpt/shot"

// ── selection-share registry (wired from chat_quote_node to sfdesk/context_menu) ──

///|
/// Active chat pages able to describe their current text selection: `(canonical_share_keys, single_message_actions)`.
/// `canonical_share_keys` uses `"m:" + m.ts` for delivered messages (matching `message_share_of` even when a
/// locally-sent row's list key is `"o:..."`) and falls back to the row key for unsent messages.
// kept across runs: cleared by excerpt_share_reset and each view's on-dispose hook
let excerpt_resolvers : Map[Int, () -> (Array[String], (() -> Unit, () -> Unit)?)?] = Map([])

///|
// kept across runs: monotonically incremented handle id, reset in excerpt_share_reset
let excerpt_resolver_seq : Ref[Int] = Ref(0)

///|
/// Registers a chat list's selection resolver `(canonical_share_keys, single_message_actions)` for the lifetime of `v`.
fn excerpt_share_register(v : @view.View, resolve : () -> (Array[String], (() -> Unit, () -> Unit)?)?) -> Unit {
  excerpt_resolver_seq.val += 1
  let id = excerpt_resolver_seq.val
  excerpt_resolvers[id] = resolve
  v.owns(fn() { excerpt_resolvers.remove(id) }) |> ignore
}

///|
/// Returns `(canonical_share_keys, single_message_actions)` for the currently active chat selection, if any.
/// Called by `sfdesk/context_menu.mbt` to verify the right-clicked message is part of the selected text.
pub fn excerpt_share_for_picked() -> (Array[String], (() -> Unit, () -> Unit)?)? {
  let mut found : (Array[String], (() -> Unit, () -> Unit)?)? = None
  excerpt_resolvers.each(fn(_, f) {
    if found is None {
      found = f()
    }
  })
  found
}

///|
/// Window id of the currently open desktop right-click context menu (`None` when closed), so only that window's
/// floating selection pill hides while its menu is showing. Kept in `sfpages` (beside `excerpt_resolvers`) rather than
/// `sfbase` so `sfbase`'s public ABI stays unchanged.
// kept across runs: reset to None by excerpt_share_reset
pub let context_menu_window : @signals.Signal[Int?] = @signals.signal(None, same=fn(a, b) { a == b })

///|
/// Resets module state between test runs (called from `pages.mbt` `reset()`).
pub fn excerpt_share_reset() -> Unit {
  excerpt_resolvers.clear()
  excerpt_resolver_seq.val = 0
  context_menu_window.set(None)
}

// ── product branding helpers ───────────────────────────────────────────────

///|
fn ex_product_host() -> String {
  if @sf.product() == "monoid" {
    "monoid.build"
  } else {
    "still.fail"
  }
}

///|
fn ex_product_url() -> String {
  "https://" + ex_product_host()
}

///|
fn ex_product_file_prefix() -> String {
  if @sf.product() == "monoid" {
    "monoid-share"
  } else {
    "stillfail-share"
  }
}

///|
fn ex_file_name(date_label : String, page_index : Int, page_count : Int) -> String {
  let stamp = date_label.replace_all(old=".", new="")
  let base = if stamp != "" { ex_product_file_prefix() + "-" + stamp } else { ex_product_file_prefix() }
  if page_count > 1 {
    let n = page_index + 1
    let pad = if n < 10 { "0" + n.to_string() } else { n.to_string() }
    base + "-" + pad + ".png"
  } else {
    base + ".png"
  }
}

///|
fn ex_pad2(n : Int) -> String {
  if n < 10 {
    "0" + n.to_string()
  } else {
    n.to_string()
  }
}

///|
fn ex_imin(a : Int, b : Int) -> Int {
  if a < b { a } else { b }
}

///|
fn ex_iclamp(v : Int, lo : Int, hi : Int) -> Int {
  if v < lo { lo } else if v > hi { hi } else { v }
}

// ── dynamic typography & eased RGBA fade runs ──────────────────────────────

///|
fn ex_body_metrics(selected : String) -> (Double, Double, Double) {
  let u = measure_excerpt_units(selected)
  if u <= 16.0 {
    (22.0, 35.0, 14.0)
  } else if u <= 48.0 {
    (20.0, 33.0, 14.0)
  } else if u <= 120.0 {
    (18.5, 31.5, 13.0)
  } else if u <= 320.0 {
    (17.0, 29.5, 12.0)
  } else {
    (15.5, 27.0, 11.0)
  }
}

///|
fn ex_ease_in_out(t : Double) -> Double {
  let c = if t < 0.0 { 0.0 } else if t > 1.0 { 1.0 } else { t }
  if c < 0.5 {
    4.0 * c * c * c
  } else {
    let u = -2.0 * c + 2.0
    1.0 - u * u * u / 2.0
  }
}

///|
fn ex_rgba(r : Int, g : Int, b : Int, alpha : Double) -> Int64 {
  let a = (alpha * 255.0).round().to_int()
  let ac = if a < 0 { 0 } else if a > 255 { 255 } else { a }
  (r.to_int64() << 24) | (g.to_int64() << 16) | (b.to_int64() << 8) | ac.to_int64()
}

///|
fn ex_is_grapheme_extender(c : Char) -> Bool {
  let code = c.to_int()
  code == 0x200D || // ZWJ
  code == 0xFE0E ||
  code == 0xFE0F || // variation selectors
  code == 0x20E3 || // combining enclosing keycap
  (code >= 0x1F3FB && code <= 0x1F3FF) || // emoji skin tone modifiers
  (code >= 0x0300 && code <= 0x036F) || // combining diacritical marks
  (code >= 0x1AB0 && code <= 0x1AFF) ||
  (code >= 0x1DC0 && code <= 0x1DFF) ||
  (code >= 0x20D0 && code <= 0x20FF) ||
  (code >= 0xFE20 && code <= 0xFE2F)
}

///|
fn ex_is_regional_indicator(c : Char) -> Bool {
  let code = c.to_int()
  code >= 0x1F1E6 && code <= 0x1F1FF
}

///|
/// Tokenizes `text` into atomic chunks (keeping Latin words, flag pairs, and ZWJ/combining emoji clusters whole so
/// wrapping and color-band transitions never split mid-word or mid-grapheme).
fn ex_fade_tokens(text : String) -> Array[String] {
  let cs = text.to_array()
  let tokens : Array[String] = []
  let mut i = 0
  while i < cs.length() {
    let c = cs[i]
    if excerpt_is_latin_word(c) {
      let start = i
      while i < cs.length() && (excerpt_is_latin_word(cs[i]) || ex_is_grapheme_extender(cs[i])) {
        i += 1
      }
      tokens.push(String::from_array(cs[start:i].to_owned()))
    } else if ex_is_regional_indicator(c) && i + 1 < cs.length() && ex_is_regional_indicator(cs[i + 1]) {
      tokens.push(String::from_array(cs[i:i + 2].to_owned()))
      i += 2
    } else {
      let start = i
      i += 1
      while i < cs.length() && ex_is_grapheme_extender(cs[i]) {
        if cs[i].to_int() == 0x200D && i + 1 < cs.length() {
          // Consume ZWJ plus the joined following scalar value.
          i += 2
        } else {
          i += 1
        }
      }
      tokens.push(String::from_array(cs[start:i].to_owned()))
    }
  }
  tokens
}

///|
/// Emits `@ui.Run` spans for `text` whose alpha eases smoothly from `from_alpha` to `to_alpha`
/// across up to 10 stepped color bands, never splitting a Latin word.
fn ex_push_faded_runs(
  out : Array[@ui.Run],
  text : String,
  r : Int,
  g : Int,
  b : Int,
  from_alpha : Double,
  to_alpha : Double,
) -> Unit {
  if text.is_empty() {
    return
  }
  let tokens = ex_fade_tokens(text)
  let total = tokens.length()
  if total == 0 {
    return
  }
  let steps = if total < 10 { total } else { 10 }
  let mut cur_step = -1
  let buf = StringBuilder()
  let flush = fn(step_idx : Int) {
    if buf.is_empty() {
      return
    }
    let t = if steps <= 1 { 0.5 } else { step_idx.to_double() / (steps - 1).to_double() }
    let a = from_alpha + (to_alpha - from_alpha) * ex_ease_in_out(t)
    out.push(@ui.span(buf.to_string(), color=ex_rgba(r, g, b, a)))
    buf.reset()
  }
  for idx in 0..<total {
    let s = idx * steps / total
    if s != cur_step && cur_step >= 0 {
      flush(cur_step)
    }
    cur_step = s
    buf.write_string(tokens[idx])
  }
  if cur_step >= 0 {
    flush(cur_step)
  }
}

///|
/// Splits a passage into paragraphs on `\n\n` while keeping single `\n` breaks inside a paragraph.
fn ex_split_paragraphs(text : String) -> Array[String] {
  let cs = text.to_array()
  let out : Array[String] = []
  let cur = StringBuilder()
  let mut i = 0
  while i < cs.length() {
    if cs[i] == '\n' && i + 1 < cs.length() && cs[i + 1] == '\n' {
      let s = cur.to_string()
      if s != "" {
        out.push(s)
      }
      cur.reset()
      while i < cs.length() && cs[i] == '\n' {
        i += 1
      }
      continue
    }
    cur.write_char(cs[i])
    i += 1
  }
  let last = cur.to_string()
  if last != "" {
    out.push(last)
  }
  out
}

///|
/// Builds per-paragraph `@ui.Run` arrays combining faded `before_context`, crisp `selected_text`
/// (with trailing run-on fade when truncated or continued without after-context), and faded `after_context`.
fn ex_build_paragraph_runs(slice : ExcerptSlice) -> Array[Array[@ui.Run]] {
  // Muted context RGB (#A8ACB2) and ink RGB (#1A1B1E).
  let (cr, cg, cb) = (168, 172, 178)
  let (ir, ig, ib) = (26, 27, 30)

  let sel_text = if slice.truncated_end && !excerpt_ends_sentence(slice.selected_text) {
    slice.selected_text + "……"
  } else {
    slice.selected_text
  }
  let before_paras = if slice.before_context != "" { ex_split_paragraphs(slice.before_context) } else { [] }
  let sel_paras = ex_split_paragraphs(sel_text)
  let after_paras = if slice.after_context != "" { ex_split_paragraphs(slice.after_context) } else { [] }

  // Compute total visual units of before/after context for continuous cross-paragraph alpha ramps.
  let before_total = {
    let mut sum = 0.0
    for p in before_paras {
      sum += measure_excerpt_units(p)
    }
    if sum < 1.0 { 1.0 } else { sum }
  }
  let after_total = {
    let mut sum = 0.0
    for p in after_paras {
      sum += measure_excerpt_units(p)
    }
    if sum < 1.0 { 1.0 } else { sum }
  }

  let paras : Array[Array[@ui.Run]] = []
  let mut before_acc = 0.0
  // Leading pure-context paragraphs (all before_paras except the last when inline-joined).
  let inline_before = !before_paras.is_empty() && !sel_paras.is_empty() && slice.before_join != Paragraph
  let pure_before_n = if inline_before { before_paras.length() - 1 } else { before_paras.length() }
  for i in 0..<pure_before_n {
    let p = before_paras[i]
    let u = measure_excerpt_units(p)
    let a0 = 0.16 + 0.84 * (before_acc / before_total)
    before_acc += u
    let a1 = 0.16 + 0.84 * (before_acc / before_total)
    let runs : Array[@ui.Run] = []
    ex_push_faded_runs(runs, p, cr, cg, cb, a0, a1)
    paras.push(runs)
  }

  // Selected paragraphs (first may have inline before_context, last may have inline after_context or run-on fade).
  let inline_after = !after_paras.is_empty() && !sel_paras.is_empty() && slice.after_join != Paragraph
  let runs_on = (slice.continues_to_next || slice.truncated_end) &&
    after_paras.is_empty() &&
    measure_excerpt_units(sel_text) > 80.0
  for i in 0..<sel_paras.length() {
    let runs : Array[@ui.Run] = []
    if i == 0 && inline_before {
      let bp = before_paras[before_paras.length() - 1]
      let a0 = 0.16 + 0.84 * (before_acc / before_total)
      ex_push_faded_runs(runs, bp, cr, cg, cb, a0, 1.0)
      if slice.before_join == InlineSpace {
        runs.push(@ui.span(" ", color=ex_rgba(cr, cg, cb, 1.0)))
      }
    }
    let sp = sel_paras[i]
    if i == sel_paras.length() - 1 && runs_on {
      // Fade the trailing ~52 visual units of the final selected paragraph smoothly into the whitespace above the footer.
      let tokens = ex_fade_tokens(sp)
      let mut tail_units = 0.0
      let mut split_at = tokens.length()
      for k = tokens.length() - 1; k >= 0; k = k - 1 {
        let u = measure_excerpt_units(tokens[k])
        if tail_units + u > 52.0 && k < tokens.length() - 1 {
          break
        }
        tail_units += u
        split_at = k
      }
      if split_at > 0 {
        let solid_sb = StringBuilder()
        for k in 0..<split_at {
          solid_sb.write_string(tokens[k])
        }
        runs.push(@ui.span(solid_sb.to_string(), color=ex_ink))
      }
      let tail_sb = StringBuilder()
      for k in split_at..<tokens.length() {
        tail_sb.write_string(tokens[k])
      }
      ex_push_faded_runs(runs, tail_sb.to_string(), ir, ig, ib, 1.0, 0.24)
    } else {
      runs.push(@ui.span(sp, color=ex_ink))
    }
    if i == sel_paras.length() - 1 && inline_after {
      let ap = after_paras[0]
      let u = measure_excerpt_units(ap)
      let a1 = 1.0 - 0.92 * (u / after_total)
      if slice.after_join == InlineSpace {
        runs.push(@ui.span(" ", color=ex_rgba(cr, cg, cb, 1.0)))
      }
      ex_push_faded_runs(runs, ap, cr, cg, cb, 1.0, a1)
    }
    paras.push(runs)
  }

  // Trailing pure-context paragraphs.
  let after_start = if inline_after { 1 } else { 0 }
  let mut after_acc = if inline_after { measure_excerpt_units(after_paras[0]) } else { 0.0 }
  for i in after_start..<after_paras.length() {
    let p = after_paras[i]
    let u = measure_excerpt_units(p)
    let a0 = 1.0 - 0.92 * (after_acc / after_total)
    after_acc += u
    let a1 = 1.0 - 0.92 * (after_acc / after_total)
    let runs : Array[@ui.Run] = []
    ex_push_faded_runs(runs, p, cr, cg, cb, a0, a1)
    paras.push(runs)
  }
  paras
}

// ── Swiss share card view (used for both stage preview and 3x take_picture) ──

///|
/// Renders one Swiss-style excerpt share card (`flat=false` rounded on stage, `flat=true` square-edged PNG).
fn excerpt_card_node(
  parent : @view.View,
  plan : () -> ExcerptPlan,
  page_idx : () -> Int,
  source_title : String,
  date_label : String,
  qr_shapes : Array[@ui.Shape],
  flat : Bool,
) -> Unit {
  let host = ex_product_host()
  let prod = @sf.product()
  let is_monoid = prod == "monoid"
  parent.box(fn(card) {
    card
    .width(Is(Some(ex_card_w)))
    .min_height(Is(Some(ex_card_min_h)))
    .padding(Is((ex_margin, ex_margin, ex_margin, ex_margin)))
    .ground(Is(ex_paper))
    |> ignore
    if !flat {
      card.radius(Is(@sf.row_corner)).clips(Is(true)) |> ignore
    }
    // The card is an exported poster image (its own Swiss paper, intentionally faded surrounding context, and QR plate).
    card.says(By(fn() { Some(@view.said(Image, label=@sf.t("web-main.chat.shareExcerpt.title"))) })) |> ignore
    // 1. Header: product host left, folio center (when multi-card), date right.
    card.box(fn(head) {
      head.row(Is(true)).fills_across(Is(true)).lines_up(Is(Some(Middle))).gap(Is(8.0)) |> ignore
      head.box(fn(l) {
        l
        .grow(Is(1.0))
        .basis(Is(Some(0.0)))
        .words(Is(host))
        .words_look(Is(@view.WordsLook::of(10.5, weight=500, line=14.0, wrap=false)))
        .ink(Is(ex_ink_secondary))
        |> ignore
      })
      |> ignore
      head.show(at_once=true, fn() { plan().cards.length() > 1 }, fn(mid) {
        mid
        .words(By(fn() {
          let p = plan()
          let idx = ex_imin(page_idx(), p.cards.length() - 1)
          ex_pad2(idx + 1) + " / " + ex_pad2(p.cards.length())
        }))
        .words_look(Is(@view.WordsLook::of(10.0, weight=600, line=14.0, wrap=false, tracking=Points(0.4))))
        .ink(Is(ex_ink))
        .words_tabular(Is(Some(true)))
        |> ignore
      })
      head.box(fn(r) {
        r
        .grow(Is(1.0))
        .basis(Is(Some(0.0)))
        .row(Is(true))
        .lies_along(Is(End))
        |> ignore
        if date_label != "" {
          r.box(fn(dt) {
            dt
            .words(Is(date_label))
            .words_look(Is(@view.WordsLook::of(10.0, weight=500, line=14.0, wrap=false, tracking=Points(0.4))))
            .ink(Is(ex_meta))
            .words_tabular(Is(Some(true)))
            |> ignore
          })
          |> ignore
        }
      })
      |> ignore
    })
    |> ignore

    // 2. Body: optically balanced between header and footer (grow spacer pushes footer cleanly down on short cards).
    card.box(fn(body_wrap) {
      let cur_slice = fn() -> (ExcerptPlan, ExcerptSlice) {
        let p = plan()
        let idx = ex_imin(page_idx(), p.cards.length() - 1)
        (p, p.cards[idx])
      }
      // Keep typography scale uniform across all cards of a paginated series (anchored to page 1).
      let sizing_text = fn() -> String {
        let (p, slice) = cur_slice()
        if p.cards.length() > 1 {
          p.cards[0].selected_text
        } else {
          slice.selected_text
        }
      }
      body_wrap
      .grow(Is(1.0))
      .fills_across(Is(true))
      .lies_along(Is(Middle))
      .padding(Is((0.0, 32.0, 0.0, 32.0)))
      |> ignore
      body_wrap.box(fn(body) {
        body
        .fills_across(Is(true))
        .gap(By(fn() { ex_body_metrics(sizing_text()).2 }))
        |> ignore
        let para_items = fn() -> Array[(Int, Array[@ui.Run])] {
          let (_, slice) = cur_slice()
          ex_build_paragraph_runs(slice).mapi(fn(i, runs) { (i, runs) })
        }
        let runs_look = { ..@view.runs_plain, words: true }
        body.each(at_once=true, para_items, fn(x) { x.0 }, fn(pnode, item) {
          pnode
          .fills_across(Is(true))
          .words_runs(By(fn() { item.get().1 }))
          .words_look(By(fn() {
            let (font_size, line_h, _) = ex_body_metrics(sizing_text())
            @view.WordsLook::of(font_size, weight=400, line=line_h, wrap=true)
          }))
          .runs_look(Is(runs_look))
          .ink(Is(ex_ink))
          |> ignore
        })
        let note_text = fn() -> String {
          let (p, slice) = cur_slice()
          if slice.continues_to_next {
            @sf.t("web-main.chat.shareExcerpt.continued", args=[("page", ex_pad2(slice.page_index + 2))])
          } else if slice.truncated_end {
            @sf.t("web-main.chat.shareExcerpt.truncated", args=[
              ("shown", format_excerpt_count(p.shown_chars)),
              ("total", format_excerpt_count(p.total_chars)),
            ])
          } else {
            ""
          }
        }
        body.show(at_once=true, fn() { note_text() != "" }, fn(n) {
          n
          .fills_across(Is(true))
          .padding(Is((0.0, 6.0, 0.0, 0.0)))
          .words(By(note_text))
          .words_look(Is(@view.WordsLook::of(10.5, weight=500, line=15.0, wrap=true)))
          .ink(Is(ex_meta))
          |> ignore
        })
      })
      |> ignore
    })
    |> ignore

    // 3. Footer on the same paper with no rule: the body's eased fade parts it.
    // Grouped into one footer box so `card` has uniform 0 gap across its 3 sections (head, body, footer).
    card.box(fn(footer) {
      footer.fills_across(Is(true)).gap(Is(14.0)) |> ignore
      let clean_title = source_title.trim(chars=" \n\t\r").to_owned()
      if clean_title != "" {
        footer.box(fn(t) {
          t
          .fills_across(Is(true))
          .words(Is(clean_title))
          .words_look(Is(@view.WordsLook::of(12.5, weight=500, line=18.0, wrap=true, balance=true, max_lines=2)))
          .allow_ellipsis(Is(true))
          .ink(Is(ex_ink))
          |> ignore
        })
        |> ignore
      }
      footer.box(fn(foot) {
        foot.row(Is(true)).fills_across(Is(true)).lines_up(Is(Some(End))).lies_along(Is(Between)).gap(Is(16.0)) |> ignore
        // Left: brand mark + product wordmark and short tagline aligned to the QR plate baseline.
        foot.box(fn(left) {
          left.gap(Is(6.0)) |> ignore
          // Brand lockup row (mark + product name).
          left.box(fn(brand) {
            brand.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(7.0)) |> ignore
            @sf.drawable_node(brand, "stillfail_mark", 18.0) |> ignore
            brand.box(fn(name) {
              let runs = if is_monoid {
                [@ui.span("monoid", weight=700, color=ex_ink)]
              } else {
                [@ui.span("still", weight=700, color=ex_ink), @ui.span(".", weight=700, color=@sf.share_receipt_orange), @ui.span("fail", weight=700, color=ex_ink)]
              }
              name
              .words_runs(Is(runs))
              .words_look(Is(@view.WordsLook::of(16.0, weight=700, line=20.0, wrap=false)))
              .ink(Is(ex_ink))
              |> ignore
            })
            |> ignore
          })
          |> ignore
          left.box(fn(tag) {
            tag
            .words(By(fn() { @sf.t("web-main.stations.shareTagline") }))
            .words_look(Is(@view.WordsLook::of(11.0, weight=400, line=15.0, wrap=false)))
            .ink(Is(ex_meta))
            |> ignore
          })
          |> ignore
        })
        |> ignore
        // Right: raised white plate with dotted vector QR code + centered mark + host label.
        foot.box(fn(plate) {
          plate
          .shrink(Is(0.0))
          .padding(Is((ex_qr_plate_pad, ex_qr_plate_pad, ex_qr_plate_pad, ex_qr_plate_pad)))
          .ground(Is(ex_plate))
          .edge(Is((0.5, ex_plate_line)))
          .radius(Is(@sf.small_corner))
          .lines_up(Is(Some(Middle)))
          .gap(Is(5.0))
          |> ignore
          plate.box(fn(qr_box) {
            qr_box
            .width(Is(Some(ex_qr_side)))
            .height(Is(Some(ex_qr_side)))
            .shapes(Is(qr_shapes))
            .lines_up(Is(Some(Middle)))
            .lies_along(Is(Middle))
            |> ignore
            @sf.drawable_node(qr_box, "stillfail_mark", ex_qr_mark_side) |> ignore
          })
          |> ignore
          plate.box(fn(lbl) {
            lbl
            .words(Is(host))
            .words_look(Is(@view.WordsLook::of(9.0, weight=600, line=12.0, wrap=false)))
            .ink(Is(ex_ink))
            |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

// ── stage preview, mode toggle, pager, copy/save actions ───────────────────

///|
/// Opens the selected-text share image stage preview for `payload`.
pub fn open_excerpt_share_payload(payload : ExcerptPayload) -> Unit {
  if payload.selected_text.trim(chars=" \n\t\r") == "" {
    return
  }
  let mode : @signals.Signal[ExcerptMode] = @signals.signal(Excerpt, same=fn(a, b) { a == b })
  let page_idx : @signals.Signal[Int] = @signals.signal(0, same=fn(a, b) { a == b })
  let copying : @signals.Signal[Bool] = @signals.signal(false, same=fn(a, b) { a == b })
  let copied : @signals.Signal[Bool] = @signals.signal(false, same=fn(a, b) { a == b })
  let saving : @signals.Signal[Bool] = @signals.signal(false, same=fn(a, b) { a == b })

  let qr_shapes = excerpt_qr_shapes(encode_excerpt_qr(ex_product_url()), ex_qr_side, ex_ink)
  let plan_excerpt = plan_excerpt_cards(payload, Excerpt)
  let plan_pages = if plan_excerpt.exceeds_single_limit { plan_excerpt_cards(payload, Pages) } else { plan_excerpt }
  let active_plan = fn() -> ExcerptPlan {
    match mode.get() {
      Excerpt => plan_excerpt
      Pages => plan_pages
    }
  }
  let step_page = fn(delta : Int) {
    let p = @signals.untracked(active_plan)
    if p.cards.length() <= 1 {
      return
    }
    let next = ex_iclamp(page_idx.untracked() + delta, 0, p.cards.length() - 1)
    if next != page_idx.untracked() {
      page_idx.set(next)
      copied.set(false)
    }
  }
  let shot_seq : Ref[Int] = Ref(0)
  let busy = fn() -> Bool { copying.get() || saving.get() }
  let take_one = fn(op : String, idx : Int, p : ExcerptPlan, done : (Bytes?) -> Unit) {
    let single_plan = fn() { p }
    let single_idx = fn() { idx }
    shot_seq.val += 1
    let key = ex_shot_prefix + "/" + op + "/" + idx.to_string() + "/" + shot_seq.val.to_string()
    @ui.take_picture(
      key,
      ex_card_w,
      fn(paper) { excerpt_card_node(paper, single_plan, single_idx, payload.source_title, payload.date_label, qr_shapes, true) },
      done,
      scale=share_scale,
    )
  }
  let do_save_one = fn(idx : Int) {
    if copying.untracked() || saving.untracked() {
      return
    }
    let p = @signals.untracked(active_plan)
    saving.set(true)
    take_one("save", idx, p, fn(png) {
      saving.set(false)
      match png {
        Some(bytes) => @sfbase.keep_bytes_now(ex_file_name(payload.date_label, idx, p.cards.length()), "image/png", bytes)
        None => @sfbase.toast_later(@sf.t(if @sf.picture_to_album() { "web-main.stations.saveToPhotosFailed" } else { "android-chat.file.saveFailed" }))
      }
    })
  }
  let do_save_all = fn() {
    if copying.untracked() || saving.untracked() {
      return
    }
    let p = @signals.untracked(active_plan)
    let total = p.cards.length()
    if total <= 1 {
      do_save_one(0)
      return
    }
    saving.set(true)
    let mut render_failed = false
    fn save_next(i : Int) {
      if i >= total {
        saving.set(false)
        if render_failed {
          @sfbase.toast_later(@sf.t(if @sf.picture_to_album() { "web-main.stations.saveToPhotosFailed" } else { "android-chat.file.saveFailed" }))
        }
        return
      }
      take_one("save-all", i, p, fn(png) {
        match png {
          Some(bytes) => @sfbase.keep_bytes_now(ex_file_name(payload.date_label, i, total), "image/png", bytes)
          None => render_failed = true
        }
        save_next(i + 1)
      })
    }
    save_next(0)
  }

  let above : ((@view.View) -> Unit)? = if plan_excerpt.exceeds_single_limit {
    Some(fn(v) {
      let capped_count = plan_pages.cards.length()
      v.box(fn(col) {
        col.fills_across(Is(true)).lines_up(Is(Some(Middle))).gap(Is(8.0)) |> ignore
        @sf.share_tabs_node(
          col,
          fn() { @sf.t("web-main.chat.shareExcerpt.mode") },
          [ExcerptMode::Excerpt, ExcerptMode::Pages],
          fn(m) {
            match m {
              Excerpt => @sf.t("web-main.chat.shareExcerpt.excerpt")
              Pages => @sf.t("web-main.chat.shareExcerpt.pages", args=[("count", capped_count.to_string())])
            }
          },
          fn() { mode.get() },
          fn(m) {
            mode.set(m)
            page_idx.set(0)
            copied.set(false)
          },
        )
        |> ignore
        // Compact pager bar when in multi-card mode (on_night buttons for guaranteed stage contrast).
        col.show(at_once=true, fn() { active_plan().cards.length() > 1 }, fn(pager) {
          pager.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(8.0)) |> ignore
          @sf.button_node(
            pager,
            fn() { "‹" },
            fn() { step_page(-1) },
            on_night=true,
            disabled=fn() { page_idx.get() <= 0 },
          )
          |> ignore
          pager.box(fn(ind) {
            ind
            .words(By(fn() {
              let p = active_plan()
              let cur = ex_imin(page_idx.get(), p.cards.length() - 1)
              ex_pad2(cur + 1) + " / " + ex_pad2(p.cards.length())
            }))
            .words_look(Is(@view.WordsLook::of(12.0, weight=500, line=16.0, wrap=false)))
            .ink(Is(@sf.share_ink))
            .words_tabular(Is(Some(true)))
            |> ignore
          })
          |> ignore
          @sf.button_node(
            pager,
            fn() { "›" },
            fn() { step_page(1) },
            on_night=true,
            disabled=fn() { page_idx.get() >= active_plan().cards.length() - 1 },
          )
          |> ignore
          @sf.button_node(
            pager,
            fn() { @sf.t("web-main.chat.shareExcerpt.savePage") },
            fn() { do_save_one(page_idx.untracked()) },
            icon="download",
            on_night=true,
            disabled=busy,
          )
          |> ignore
        })
        // Length summary notice on night.
        col.box(fn(notice) {
          notice
          .words(By(fn() {
            let p = active_plan()
            match p.mode {
              Excerpt =>
                @sf.t("web-main.chat.shareExcerpt.truncated", args=[
                  ("shown", format_excerpt_count(p.shown_chars)),
                  ("total", format_excerpt_count(p.total_chars)),
                ])
              Pages =>
                if p.was_truncated {
                  @sf.t("web-main.chat.shareExcerpt.pagesCapped", args=[
                    ("pages", p.cards.length().to_string()),
                    ("shown", format_excerpt_count(p.shown_chars)),
                    ("total", format_excerpt_count(p.total_chars)),
                  ])
                } else {
                  @sf.t("web-main.chat.shareExcerpt.pagesNotice", args=[
                    ("pages", p.cards.length().to_string()),
                    ("total", format_excerpt_count(p.total_chars)),
                  ])
                }
            }
          }))
          .words_look(Is(@view.WordsLook::of(11.5, weight=400, line=16.0, wrap=true)))
          .ink(Is(@sf.share_dim))
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
  } else {
    None
  }

  @sf.panel_nodes(
    @sf.t("web-main.chat.shareExcerpt.title"),
    fn(v, _) {
      v
      .on_key(fn(e) {
        if e.code == @ui.key_code_left {
          step_page(-1)
          true
        } else if e.code == @ui.key_code_right {
          step_page(1)
          true
        } else {
          false
        }
      })
      |> ignore
      excerpt_card_node(v, active_plan, fn() { page_idx.get() }, payload.source_title, payload.date_label, qr_shapes, false)
    },
    from=Unanchored,
    stage=true,
    w=ex_card_w,
    above?,
    live=fn() { (@sf.t("web-main.chat.shareExcerpt.title"), "", "") },
    foot=fn(f, _) {
      // Desktop / Web: Copy image + Save image (or Save all when paged).
      // Phone (iOS / Android): Save to Photos (or Save all) beside stage's Close button so 390pt @ 1.3x never overflows.
      if !@sf.picture_to_album() {
        @sf.button_node(
          f,
          fn() { @sf.t(if copied.get() { "common.copied" } else { "desktop.contextMenu.copyImage" }) },
          icon="copy",
          on_night=true,
          busy=fn() { copying.get() },
          disabled=busy,
          done=fn() { copied.get() },
          fn() {
            if copying.untracked() || saving.untracked() {
              return
            }
            let p = @signals.untracked(active_plan)
            let idx = ex_imin(page_idx.untracked(), p.cards.length() - 1)
            copying.set(true)
            take_one("copy", idx, p, fn(png) {
              copying.set(false)
              if picture_out_now(png, copy=true) {
                copied.set(true)
              }
            })
          },
        )
        |> ignore
      }
      // Primary action: Save image / Save to Photos (or Save all when paged).
      @sf.button_node(
        f,
        fn() {
          if active_plan().cards.length() > 1 {
            @sf.t("web-main.chat.shareExcerpt.saveAll")
          } else if @sf.picture_to_album() {
            @sf.t("web-main.stations.saveToPhotos")
          } else {
            @sf.t("web-main.chat.shareExcerpt.save")
          }
        },
        tone=Primary,
        icon="download",
        on_night=true,
        busy=fn() { saving.get() },
        disabled=busy,
        fn() {
          if @signals.untracked(active_plan).cards.length() > 1 {
            do_save_all()
          } else {
            do_save_one(page_idx.untracked())
          }
        },
      )
      |> ignore
    },
  )
}

///|
/// Extracts the selected passage and surrounding context from message `m` and opens the share card stage.
fn chat_excerpt_share_of(src : Source, here : MessageNodeHere, p : @ui.WordsPicked, m : Message, whole? : Bool = false) -> Unit {
  let raw = chat_picked_words(p, m, whole)
  let trimmed = raw.trim(chars=" \n\t\r").to_owned()
  if trimmed == "" {
    return
  }
  let paras = message_plain_paragraphs(m)
  let title = @signals.untracked(here.view).title
  let date_ms = {
    let now = (src.now)()
    if now >= 946684800000.0 {
      now
    } else {
      m.created_at
    }
  }
  let payload = build_excerpt_payload(
    paras,
    raw,
    p.first_before,
    whole,
    title,
    format_excerpt_date(date_ms, offset_min=@ui.utc_offset_min(date_ms)),
  )
  @ui.picked_let_go()
  open_excerpt_share_payload(payload)
}
