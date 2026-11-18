// A terminal's monospace cell grid as a node of the window's tree (ui's terminal_grid): reads compact dirty-row
// binary frames from `@hostapi.Terminal::frame`, keeps an incremental per-row cell cache so untouched rows are never
// decoded or rebuilt, places every character and block element on exact `(col * cell_w, row * line_h)` coordinates,
// draws geometric box-drawing/block characters (`U+2500..U+259F`) with zero inter-cell gaps, renders SGR underline
// styles (`single`, `double`, `curly`, `dotted`, `dashed`), strikethrough, overline, selection bands, cursor styles
// (`bar`, `block`, `underline`, `hollow`), IME preedit overlay, and an auto-fading scrollback thumb.

///|
priv struct TermCell {
  col : Int
  width : Int
  sflags : Int
  fg : Int64
  bg : Int64
  ul : Int64
  text : String
  cp : Int // single codepoint when 1 char, else -1
}

///|
priv struct TermBgRun {
  col : Int
  span : Int
  color : Int64
}

///|
priv struct TermRow {
  mut sel_start : Int
  mut sel_end : Int
  cells : Array[TermCell]
  bg_runs : Array[TermBgRun]
  mut text : String
}

///|
fn TermRow::empty() -> TermRow {
  { sel_start: 0xffff, sel_end: 0xffff, cells: [], bg_runs: [], text: "" }
}

///|
priv struct TreeTerminal {
  term : () -> @hostapi.Terminal?
  rev : () -> Int
  size : () -> Double
  line_h : () -> Double
  pad : () -> (Double, Double)
  focused : () -> Bool
  composing : () -> String
  default_fg : Int64
  default_bg : Int64
  cursor_color : Int64
  selection_bg : Int64
  on_cursor : (Double, Double, Double) -> Unit
  mut last_rev : Int
  mut cols : Int
  mut rows_n : Int
  mut cursor_x : Int
  mut cursor_y : Int
  mut cursor_style : Int
  mut cursor_flags : Int
  mut modes : Int
  mut eff_fg : Int64
  mut eff_bg : Int64
  mut eff_cur : Int64
  mut sb_total : Int
  mut sb_offset : Int
  mut sb_len : Int
  mut sb_changed_at : Double
  rows : Array[TermRow]
}

///|
// kept across runs: emptied as a run begins (view_forget); each let go with its node (tree_terminal_gone)
let tree_terminals : Map[@view.NodeId, TreeTerminal] = Map([])

///|
// kept across runs: only counts
let tree_terminals_rev : Ref[Int] = Ref(0)

///|
// kept across runs: emptied as a run begins (view_forget), and when text_cache.generation advances
let term_glyph_cache_gen : Ref[Int] = Ref(-1)

///|
// kept across runs: emptied as a run begins (view_forget), and when text_cache.generation advances
let term_glyph_cache : Map[String, Int] = Map([])

///|
fn term_glyph_key(grapheme : String, size : Double, weight : Int, style : Int) -> Int {
  let gen = text_cache.generation
  if term_glyph_cache_gen.val != gen || term_glyph_cache.length() > 4096 {
    term_glyph_cache_gen.val = gen
    term_glyph_cache.clear()
  }
  let qsize = (size * 100.0).round().to_int()
  let cache_key = "\{qsize}:\{weight}:\{style}:\{grapheme}"
  match term_glyph_cache.get(cache_key) {
    Some(k) => k
    None => {
      let k = h_text_key(grapheme, size, weight, style)
      term_glyph_cache[cache_key] = k
      k
    }
  }
}

///|
// kept across runs: emptied as a run begins (view_forget), and when text_cache.generation advances
let term_metrics_cache_gen : Ref[Int] = Ref(-1)

///|
// kept across runs: emptied as a run begins (view_forget), and when text_cache.generation advances
let term_metrics_cache : Map[Int, (Double, Double, Double)] = Map([])

///|
/// Monospace cell width, ascent and descent for `size` points.
pub fn terminal_grid_metrics(size : Double) -> (Double, Double, Double) {
  let gen = text_cache.generation
  if term_metrics_cache_gen.val != gen || term_metrics_cache.length() > 64 {
    term_metrics_cache_gen.val = gen
    term_metrics_cache.clear()
  }
  let qsize = (size * 100.0).round().to_int()
  match term_metrics_cache.get(qsize) {
    Some(m) => m
    None => {
      let cw = text_advance("M", size~, style=@hostapi.style_mono)
      let (asc, desc, _) = font_metrics(size, 400, style=@hostapi.style_mono)
      let m = (if cw > 1.0 { cw } else { (size * 0.6).max(4.0) }, asc, desc)
      term_metrics_cache[qsize] = m
      m
    }
  }
}

///|
fn term_u16(b : Bytes, at : Int) -> Int {
  b[at].to_int() | (b[at + 1].to_int() << 8)
}

///|
fn term_u32(b : Bytes, at : Int) -> Int {
  b[at].to_int() |
  (b[at + 1].to_int() << 8) |
  (b[at + 2].to_int() << 16) |
  ((b[at + 3].to_int() & 0x7f) << 24)
}

///|
fn term_rgb(b : Bytes, at : Int) -> Int64 {
  ((b[at].to_int64() & 0xffL) << 24) |
  ((b[at + 1].to_int64() & 0xffL) << 16) |
  ((b[at + 2].to_int64() & 0xffL) << 8) |
  0xffL
}

///|
fn term_rebuild_row_Derived(row : TermRow, cols : Int, eff_fg : Int64, eff_bg : Int64) -> Unit {
  row.bg_runs.clear()
  let mut run_col = -1
  let mut run_end = -1
  let mut run_color = 0L
  for cell in row.cells {
    let inverse = (cell.sflags & 16) != 0
    let has_fg = (cell.sflags & 2048) != 0
    let has_bg = (cell.sflags & 4096) != 0
    let bg_opt : Int64? = if inverse {
      Some(if has_fg { cell.fg } else { eff_fg })
    } else if has_bg {
      Some(cell.bg)
    } else {
      None
    }
    match bg_opt {
      Some(c) if c != eff_bg =>
        if run_col >= 0 && cell.col == run_end && run_color == c {
          run_end = cell.col + cell.width
        } else {
          if run_col >= 0 {
            row.bg_runs.push({ col: run_col, span: run_end - run_col, color: run_color })
          }
          run_col = cell.col
          run_end = cell.col + cell.width
          run_color = c
        }
      _ => ()
    }
  }
  if run_col >= 0 {
    row.bg_runs.push({ col: run_col, span: run_end - run_col, color: run_color })
  }
  // Build visible string for Tester::find / accessibility lookup
  if row.cells.is_empty() {
    row.text = ""
  } else {
    let buf = StringBuilder()
    let mut cur_col = 0
    for cell in row.cells {
      if (cell.sflags & 32) != 0 {
        continue
      }
      while cur_col < cell.col && cur_col < cols {
        buf.write_char(' ')
        cur_col += 1
      }
      if cell.text == "" {
        buf.write_char(' ')
      } else {
        buf.write_string(cell.text)
      }
      cur_col = cell.col + cell.width
    }
    row.text = buf.to_string()
  }
}

///|
fn TreeTerminal::sync_frame(self : TreeTerminal, force_full : Bool) -> Unit {
  let cur_rev = @signals.untracked(self.rev)
  if !force_full && cur_rev == self.last_rev && !self.rows.is_empty() {
    return
  }
  let was_initial = self.last_rev < 0
  self.last_rev = cur_rev
  guard @signals.untracked(self.term) is Some(tm) else {
    self.rows.clear()
    self.cols = 0
    self.rows_n = 0
    return
  }
  let mut b = tm.frame(full=force_full || self.rows.is_empty())
  if b.length() < 42 || b[0].to_int() != 1 {
    return
  }
  let mut dirty = b[1].to_int()
  let mut cols = term_u16(b, 2)
  let mut rows_n = term_u16(b, 4)
  if (cols != self.cols || rows_n != self.rows_n || self.rows.length() != rows_n) && dirty != 2 {
    b = tm.frame(full=true)
    if b.length() < 42 || b[0].to_int() != 1 {
      return
    }
    dirty = b[1].to_int()
    cols = term_u16(b, 2)
    rows_n = term_u16(b, 4)
  }
  self.cols = cols
  self.rows_n = rows_n
  self.cursor_x = term_u16(b, 6)
  self.cursor_y = term_u16(b, 8)
  self.cursor_style = b[10].to_int()
  let cflags = b[11].to_int()
  self.cursor_flags = cflags
  self.modes = term_u16(b, 12)
  let next_fg = if (cflags & 16) != 0 { term_rgb(b, 14) } else { self.default_fg }
  let next_bg = if (cflags & 32) != 0 { term_rgb(b, 17) } else { self.default_bg }
  let palette_changed = next_fg != self.eff_fg || next_bg != self.eff_bg
  self.eff_fg = next_fg
  self.eff_bg = next_bg
  self.eff_cur = if (cflags & 8) != 0 { term_rgb(b, 20) } else { self.cursor_color }

  let next_total = term_u32(b, 24)
  let next_offset = term_u32(b, 28)
  let next_len = term_u32(b, 32)
  if !was_initial && (next_offset != self.sb_offset || next_total != self.sb_total) {
    self.sb_changed_at = view_moment()
  }
  self.sb_total = next_total
  self.sb_offset = next_offset
  self.sb_len = next_len

  let row_count = term_u16(b, 36)
  if dirty == 2 || self.rows.length() != rows_n {
    self.rows.clear()
    for _ in 0..<rows_n {
      self.rows.push(TermRow::empty())
    }
  }
  if dirty != 0 {
    let mut off = 42
    let nbytes = b.length()
    for _ in 0..<row_count {
      if off + 8 > nbytes {
        break
      }
      let vy = term_u16(b, off)
      let sel_start = term_u16(b, off + 2)
      let sel_end = term_u16(b, off + 4)
      let cell_count = term_u16(b, off + 6)
      off += 8
      let cells : Array[TermCell] = Array(capacity=cell_count)
      for _ in 0..<cell_count {
        if off + 6 > nbytes {
          off = nbytes
          break
        }
        let col = term_u16(b, off)
        let width = b[off + 2].to_int()
        let ulen = b[off + 3].to_int()
        let sflags = term_u16(b, off + 4)
        off += 6
        let fg = if (sflags & 2048) != 0 && off + 3 <= nbytes {
          let c = term_rgb(b, off)
          off += 3
          c
        } else {
          0L
        }
        let bg = if (sflags & 4096) != 0 && off + 3 <= nbytes {
          let c = term_rgb(b, off)
          off += 3
          c
        } else {
          0L
        }
        let ul = if (sflags & 8192) != 0 && off + 3 <= nbytes {
          let c = term_rgb(b, off)
          off += 3
          c
        } else {
          0L
        }
        let text = if ulen > 0 && off + ulen <= nbytes {
          let s = @utf8.decode_lossy(b[off:off + ulen])
          off += ulen
          s
        } else {
          if ulen > 0 {
            off = (off + ulen).min(nbytes)
          }
          ""
        }
        let cp = if text.length() == 1 {
          text.unsafe_get(0).to_int()
        } else if text.length() == 2 {
          let cs = text.to_array()
          if cs.length() == 1 { cs[0].to_int() } else { -1 }
        } else {
          -1
        }
        cells.push({ col, width: if width == 2 { 2 } else { 1 }, sflags, fg, bg, ul, text, cp })
      }
      if vy >= 0 && vy < self.rows.length() {
        let r = self.rows[vy]
        r.sel_start = sel_start
        r.sel_end = sel_end
        r.cells.clear()
        for cell in cells {
          r.cells.push(cell)
        }
        term_rebuild_row_Derived(r, cols, self.eff_fg, self.eff_bg)
      }
    }
  } else if palette_changed {
    for r in self.rows {
      term_rebuild_row_Derived(r, cols, self.eff_fg, self.eff_bg)
    }
  }
}

///|
fn TreeTerminal::visible_text(self : TreeTerminal) -> String {
  self.sync_frame(false)
  let lines : Array[String] = []
  for r in self.rows {
    if r.text != "" {
      lines.push(r.text)
    }
  }
  lines.join("\n")
}

///|
/// Pixel-crisp geometric rendering for Unicode Box Drawing (`U+2500..U+257F`) and Block Elements (`U+2580..U+259F`).
/// Returns `true` if drawn geometrically so font glyph fallback is skipped.
fn Ctx::paint_term_box_or_block(
  self : Ctx,
  cp : Int,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  color : Int64,
  alpha : Double,
) -> Bool {
  if cp < 0x2500 || cp > 0x259f {
    return false
  }
  // Block Elements U+2580..U+259F
  if cp >= 0x2580 {
    match cp {
      0x2580 => { self.emit_rect(x, y, w, h * 0.5, 0.0, color, 0.0, 0L, alpha); return true }
      0x2581..=0x2588 => {
        let frac = (cp - 0x2580).to_double() / 8.0
        let bh = h * frac
        self.emit_rect(x, y + h - bh, w, bh, 0.0, color, 0.0, 0L, alpha)
        return true
      }
      0x2589..=0x258f => {
        let frac = (8 - (cp - 0x2588)).to_double() / 8.0
        self.emit_rect(x, y, w * frac, h, 0.0, color, 0.0, 0L, alpha)
        return true
      }
      0x2590 => { self.emit_rect(x + w * 0.5, y, w * 0.5, h, 0.0, color, 0.0, 0L, alpha); return true }
      0x2591 => { self.emit_rect(x, y, w, h, 0.0, color, 0.0, 0L, alpha * 0.25); return true }
      0x2592 => { self.emit_rect(x, y, w, h, 0.0, color, 0.0, 0L, alpha * 0.50); return true }
      0x2593 => { self.emit_rect(x, y, w, h, 0.0, color, 0.0, 0L, alpha * 0.75); return true }
      0x2594 => { self.emit_rect(x, y, w, h / 8.0, 0.0, color, 0.0, 0L, alpha); return true }
      0x2595 => { self.emit_rect(x + w * 7.0 / 8.0, y, w / 8.0, h, 0.0, color, 0.0, 0L, alpha); return true }
      0x2596..=0x259f => {
        // Quadrant blocks (bits: UL=1, UR=2, LL=4, LR=8)
        let mask = match cp {
          0x2596 => 4
          0x2597 => 8
          0x2598 => 1
          0x2599 => 1 | 4 | 8
          0x259a => 1 | 8
          0x259b => 1 | 2 | 4
          0x259c => 1 | 2 | 8
          0x259d => 2
          0x259e => 2 | 4
          _ => 2 | 4 | 8
        }
        let hw = w * 0.5
        let hh = h * 0.5
        if (mask & 1) != 0 { self.emit_rect(x, y, hw, hh, 0.0, color, 0.0, 0L, alpha) }
        if (mask & 2) != 0 { self.emit_rect(x + hw, y, w - hw, hh, 0.0, color, 0.0, 0L, alpha) }
        if (mask & 4) != 0 { self.emit_rect(x, y + hh, hw, h - hh, 0.0, color, 0.0, 0L, alpha) }
        if (mask & 8) != 0 { self.emit_rect(x + hw, y + hh, w - hw, h - hh, 0.0, color, 0.0, 0L, alpha) }
        return true
      }
      _ => return false
    }
  }

  // Box Drawing U+2500..U+257F: (left, right, up, down) where 0=none, 1=light, 2=heavy, 3=double
  let (l, r, u, d) : (Int, Int, Int, Int) = match cp {
    0x2500 | 0x2504 | 0x2508 | 0x254c => (1, 1, 0, 0)
    0x2501 | 0x2505 | 0x2509 | 0x254d => (2, 2, 0, 0)
    0x2502 | 0x2506 | 0x250a | 0x254e => (0, 0, 1, 1)
    0x2503 | 0x2507 | 0x250b | 0x254f => (0, 0, 2, 2)
    0x250c | 0x256d => (0, 1, 0, 1)
    0x250f => (0, 2, 0, 2)
    0x2510 | 0x256e => (1, 0, 0, 1)
    0x2513 => (2, 0, 0, 2)
    0x2514 | 0x2570 => (0, 1, 1, 0)
    0x2517 => (0, 2, 2, 0)
    0x2518 | 0x256f => (1, 0, 1, 0)
    0x251b => (2, 0, 2, 0)
    0x251c => (0, 1, 1, 1)
    0x2523 => (0, 2, 2, 2)
    0x2524 => (1, 0, 1, 1)
    0x252b => (2, 0, 2, 2)
    0x252c => (1, 1, 0, 1)
    0x2533 => (2, 2, 0, 2)
    0x2534 => (1, 1, 1, 0)
    0x253b => (2, 2, 2, 0)
    0x253c => (1, 1, 1, 1)
    0x254b => (2, 2, 2, 2)
    0x2550 => (3, 3, 0, 0)
    0x2551 => (0, 0, 3, 3)
    0x2552 => (0, 3, 0, 1)
    0x2553 => (0, 1, 0, 3)
    0x2554 => (0, 3, 0, 3)
    0x2555 => (3, 0, 0, 1)
    0x2556 => (1, 0, 0, 3)
    0x2557 => (3, 0, 0, 3)
    0x2558 => (0, 3, 1, 0)
    0x2559 => (0, 1, 3, 0)
    0x255a => (0, 3, 3, 0)
    0x255b => (3, 0, 1, 0)
    0x255c => (1, 0, 3, 0)
    0x255d => (3, 0, 3, 0)
    0x255e => (0, 3, 1, 1)
    0x255f => (0, 1, 3, 3)
    0x2560 => (0, 3, 3, 3)
    0x2561 => (3, 0, 1, 1)
    0x2562 => (1, 0, 3, 3)
    0x2563 => (3, 0, 3, 3)
    0x2564 => (3, 3, 0, 1)
    0x2565 => (1, 1, 0, 3)
    0x2566 => (3, 3, 0, 3)
    0x2567 => (3, 3, 1, 0)
    0x2568 => (1, 1, 3, 0)
    0x2569 => (3, 3, 3, 0)
    0x256a => (3, 3, 1, 1)
    0x256b => (1, 1, 3, 3)
    0x256c => (3, 3, 3, 3)
    0x2574 => (1, 0, 0, 0)
    0x2575 => (0, 0, 1, 0)
    0x2576 => (0, 1, 0, 0)
    0x2577 => (0, 0, 0, 1)
    0x2578 => (2, 0, 0, 0)
    0x2579 => (0, 0, 2, 0)
    0x257a => (0, 2, 0, 0)
    0x257b => (0, 0, 0, 2)
    _ => (0, 0, 0, 0)
  }
  if l == 0 && r == 0 && u == 0 && d == 0 {
    return false
  }
  let lw = 1.0
  let hw = 2.0
  let cx = x + w * 0.5
  let cy = y + h * 0.5
  let gap = 1.5
  let hseg = fn(x0 : Double, x1 : Double, st : Int) {
    if x1 <= x0 {
      return
    }
    if st == 3 {
      self.emit_rect(x0, cy - gap - lw * 0.5, x1 - x0, lw, 0.0, color, 0.0, 0L, alpha)
      self.emit_rect(x0, cy + gap - lw * 0.5, x1 - x0, lw, 0.0, color, 0.0, 0L, alpha)
    } else {
      let th = if st == 2 { hw } else { lw }
      self.emit_rect(x0, cy - th * 0.5, x1 - x0, th, 0.0, color, 0.0, 0L, alpha)
    }
  }
  let vseg = fn(y0 : Double, y1 : Double, st : Int) {
    if y1 <= y0 {
      return
    }
    if st == 3 {
      self.emit_rect(cx - gap - lw * 0.5, y0, lw, y1 - y0, 0.0, color, 0.0, 0L, alpha)
      self.emit_rect(cx + gap - lw * 0.5, y0, lw, y1 - y0, 0.0, color, 0.0, 0L, alpha)
    } else {
      let th = if st == 2 { hw } else { lw }
      self.emit_rect(cx - th * 0.5, y0, th, y1 - y0, 0.0, color, 0.0, 0L, alpha)
    }
  }
  if l == r && l != 0 && u == 0 && d == 0 {
    hseg(x, x + w, l)
    return true
  }
  if u == d && u != 0 && l == 0 && r == 0 {
    vseg(y, y + h, u)
    return true
  }
  let pad_x = if u != 0 || d != 0 { lw * 0.5 } else { 0.0 }
  let pad_y = if l != 0 || r != 0 { lw * 0.5 } else { 0.0 }
  if l != 0 { hseg(x, cx + pad_x, l) }
  if r != 0 { hseg(cx - pad_x, x + w, r) }
  if u != 0 { vseg(y, cy + pad_y, u) }
  if d != 0 { vseg(cy - pad_y, y + h, d) }
  true
}

///|
fn Ctx::paint_term_underline(
  self : Ctx,
  style : Int,
  x : Double,
  y : Double,
  w : Double,
  line_h : Double,
  color : Int64,
  alpha : Double,
) -> Unit {
  let uy = y + line_h - 2.0
  match style {
    1 => self.emit_rect(x, uy, w, 1.0, 0.0, color, 0.0, 0L, alpha)
    2 => {
      self.emit_rect(x, uy - 2.0, w, 1.0, 0.0, color, 0.0, 0L, alpha)
      self.emit_rect(x, uy, w, 1.0, 0.0, color, 0.0, 0L, alpha)
    }
    3 => {
      // Curly wave approximated with clean stepped 2px micro-segments
      let mut px = x
      let mut up = false
      while px < x + w - 0.5 {
        let sw = (x + w - px).min(2.0)
        self.emit_rect(px, if up { uy - 1.2 } else { uy + 0.3 }, sw, 1.1, 0.0, color, 0.0, 0L, alpha)
        px += 2.0
        up = !up
      }
    }
    4 => {
      let mut px = x
      while px < x + w - 0.5 {
        let sw = (x + w - px).min(1.5)
        self.emit_rect(px, uy, sw, 1.0, 0.0, color, 0.0, 0L, alpha)
        px += 3.0
      }
    }
    5 => {
      let mut px = x
      while px < x + w - 0.5 {
        let sw = (x + w - px).min(3.5)
        self.emit_rect(px, uy, sw, 1.0, 0.0, color, 0.0, 0L, alpha)
        px += 5.5
      }
    }
    _ => ()
  }
}

///|
fn Ctx::paint_tree_terminal(
  self : Ctx,
  _id : @view.NodeId,
  tt : TreeTerminal,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  s : Double,
  alpha : Double,
  laid~ : (Double, Double),
) -> Unit {
  if w <= 0.0 || h <= 0.0 || alpha <= 0.0 {
    return
  }
  // Track reactive inputs so only paint runs when terminal output, font size, focus or IME preedit changes
  let _ = (tt.rev)()
  let font_size = (tt.size)()
  let line_h = (tt.line_h)()
  let (pad_x, pad_y) = (tt.pad)()
  let is_focused = (tt.focused)()
  let composing = (tt.composing)()
  tt.sync_frame(false)

  let (cell_w, asc, desc) = terminal_grid_metrics(font_size)
  let baseline = asc + (line_h - asc - desc) * 0.5
  let (ux, uy) = laid
  let ox = ux + pad_x
  let oy = uy + pad_y
  let sc = self.scale
  let zoom = words_zoom.val

  let (outer, outer_r, outer_s) = clip_at(clip_top())
  let (was_owner, was_tree) = (inst_owners.painting, inst_owners.tree_painting)
  inst_owners.painting = -1
  inst_owners.tree_painting = None
  let i0 = self.ninst
  push_unclipped()

  // Terminal default background (covers OSC 11 overrides too)
  if tt.eff_bg != tt.default_bg {
    self.emit_rect(ux, uy, w, h, 0.0, tt.eff_bg, 0.0, 0L, alpha)
  }

  let cur_vis = (tt.cursor_flags & 1) != 0 && composing == ""
  let cur_block_focused = cur_vis && is_focused && tt.cursor_style == 1

  // Pass 1: Row cell backgrounds and selection bands
  let max_rows = tt.rows.length()
  for vy in 0..<max_rows {
    let ry = oy + vy.to_double() * line_h
    if ry >= uy + h || ry + line_h <= uy {
      continue
    }
    let row = tt.rows[vy]
    for run in row.bg_runs {
      let rx = ox + run.col.to_double() * cell_w
      let rw = run.span.to_double() * cell_w
      self.emit_rect(rx, ry, rw, line_h, 0.0, run.color, 0.0, 0L, alpha)
    }
    if row.sel_start != 0xffff && row.sel_end >= row.sel_start && row.sel_start < tt.cols {
      let sx0 = row.sel_start.clamp(min=0, max=tt.cols - 1)
      let sx1 = row.sel_end.clamp(min=sx0, max=tt.cols - 1)
      let rx = ox + sx0.to_double() * cell_w
      let rw = (sx1 - sx0 + 1).to_double() * cell_w
      self.emit_rect(rx, ry, rw, line_h, 2.0, tt.selection_bg, 0.0, 0L, alpha)
    }
  }

  // Focused block cursor sits beneath its cell's foreground glyph (drawn in cursor's inverse ground)
  let cur_span = if (tt.cursor_flags & 4) != 0 { 2.0 } else { 1.0 }
  let cur_px = ox + tt.cursor_x.to_double() * cell_w
  let cur_py = oy + tt.cursor_y.to_double() * line_h
  if cur_vis && tt.cursor_y >= 0 && tt.cursor_y < max_rows {
    let cw = cur_span * cell_w
    if !is_focused || tt.cursor_style == 3 {
      // Hollow block cursor when unfocused or requested
      self.emit_rect(cur_px, cur_py, cw, line_h, 1.0, 0L, 1.2, tt.eff_cur, alpha * 0.85)
    } else if tt.cursor_style == 0 {
      // Beam / bar cursor
      self.emit_rect(cur_px, cur_py + 1.0, 2.0, (line_h - 2.0).max(2.0), 1.0, tt.eff_cur, 0.0, 0L, alpha)
    } else if tt.cursor_style == 2 {
      // Underline cursor
      self.emit_rect(cur_px, cur_py + line_h - 2.5, cw, 2.0, 0.5, tt.eff_cur, 0.0, 0L, alpha)
    } else {
      // Solid block cursor
      self.emit_rect(cur_px, cur_py, cw, line_h, 1.0, tt.eff_cur, 0.0, 0L, alpha * 0.9)
    }
  }

  // Report cursor window coordinates to OS IME candidate window anchor
  let win_cur_x = x + (cur_px - ux) * s
  let win_cur_y = y + (cur_py - uy) * s
  (tt.on_cursor)(win_cur_x, win_cur_y, line_h * s)

  // Pass 2: Glyphs, box-drawing/blocks, and line decorations
  for vy in 0..<max_rows {
    let ry = oy + vy.to_double() * line_h
    if ry >= uy + h || ry + line_h <= uy {
      continue
    }
    let row = tt.rows[vy]
    for cell in row.cells {
      let sflags = cell.sflags
      if (sflags & 32) != 0 {
        continue // invisible
      }
      let inverse = (sflags & 16) != 0
      let has_fg = (sflags & 2048) != 0
      let has_bg = (sflags & 4096) != 0
      let has_ul = (sflags & 8192) != 0
      let under_block_cur = cur_block_focused &&
        vy == tt.cursor_y &&
        cell.col >= tt.cursor_x &&
        cell.col < tt.cursor_x + cur_span.to_int()
      let fg = if under_block_cur {
        tt.eff_bg
      } else if inverse {
        if has_bg { cell.bg } else { tt.eff_bg }
      } else if has_fg {
        cell.fg
      } else {
        tt.eff_fg
      }
      let cell_alpha = if (sflags & 4) != 0 { alpha * 0.62 } else { alpha }
      let cx = ox + cell.col.to_double() * cell_w
      let cw = cell.width.to_double() * cell_w

      if cell.text != "" {
        if !self.paint_term_box_or_block(cell.cp, cx, ry, cw, line_h, fg, cell_alpha) {
          let bold = (sflags & 1) != 0
          let italic = (sflags & 2) != 0
          let weight = if bold { 700 } else { 400 }
          let style = @hostapi.style_mono | (if italic { @hostapi.style_italic } else { 0 })
          let raw_key = term_glyph_key(cell.text, font_size * zoom, weight, style)
          if raw_key >= 0 {
            // (a wide cell's glyph centred in it by its picture at the cell's own phase, then drawn at the phase of
            // where it is centred to: its quad on the column of that phase, glyph_x)
            let g0 = glyph(glyph_sub(raw_key, cx, sc, zoom), sc / zoom)
            let slot_dx = if cell.width == 2 && g0.gw > 0.0 {
              let natural = g0.ox / zoom + g0.gw / zoom
              if natural < cw - 1.0 { (cw - g0.gw / zoom) * 0.5 - g0.ox / zoom } else { 0.0 }
            } else {
              0.0
            }
            let g = if slot_dx == 0.0 { g0 } else { glyph(glyph_sub(raw_key, cx + slot_dx, sc, zoom), sc / zoom) }
            if g.gw > 0.0 {
              let (gw, gh) = (g.gw / zoom, g.gh / zoom)
              let gx = glyph_x(cx + slot_dx, g.ox / zoom, sc, z=zoom)
              let gy = glyph_row(oy, vy.to_double() * line_h + baseline, g.oy / zoom, sc)
              glyph_pushing.val = true
              self.push_inst(
                gx,
                gy,
                gw,
                gh,
                0.0,
                if g.color { 3.0 } else { 1.0 },
                0.0,
                0.0,
                if g.color { 0xFFFFFFFFL } else { fg },
                cell_alpha,
                g.u,
                g.v,
                g.gw * (sc / zoom),
                g.gh * (sc / zoom),
              )
              glyph_pushing.val = false
            }
          }
        }
      }

      // Underline (bits 8..10), strikethrough (bit 6 = 64), overline (bit 7 = 128)
      let ul_style = (sflags >> 8) & 7
      if ul_style != 0 {
        let ul_col = if has_ul { cell.ul } else { fg }
        self.paint_term_underline(ul_style, cx, ry, cw, line_h, ul_col, cell_alpha)
      }
      if (sflags & 64) != 0 {
        self.emit_rect(cx, ry + line_h * 0.52, cw, 1.0, 0.0, fg, 0.0, 0L, cell_alpha)
      }
      if (sflags & 128) != 0 {
        self.emit_rect(cx, ry + 1.0, cw, 1.0, 0.0, fg, 0.0, 0L, cell_alpha)
      }
    }
  }

  // Pass 3: IME preedit (composing) overlay anchored directly at the cursor cell
  if composing != "" && tt.cursor_y >= 0 && tt.cursor_y < max_rows {
    let comp_chars = composing.to_array()
    let mut span_cells = 0
    for ch in comp_chars {
      span_cells += fake_char_width(ch)
    }
    let comp_w = (span_cells.max(1)).to_double() * cell_w
    self.emit_rect(cur_px, cur_py, comp_w, line_h, 2.0, 0x252830F8L, 0.0, 0L, alpha)
    self.emit_rect(cur_px, cur_py + line_h - 2.0, comp_w, 1.5, 0.0, tt.eff_cur, 0.0, 0L, alpha)
    let mut col_off = 0
    for ch in comp_chars {
      let s_ch = ch.to_string()
      let raw_key = term_glyph_key(s_ch, font_size * zoom, 400, @hostapi.style_mono)
      if raw_key >= 0 {
        let px = cur_px + col_off.to_double() * cell_w
        let key = glyph_sub(raw_key, px, sc, zoom)
        let g = glyph(key, sc / zoom)
        if g.gw > 0.0 {
          let gx = glyph_x(px, g.ox / zoom, sc, z=zoom)
          let gy = glyph_row(oy, tt.cursor_y.to_double() * line_h + baseline, g.oy / zoom, sc)
          glyph_pushing.val = true
          self.push_inst(
            gx,
            gy,
            g.gw / zoom,
            g.gh / zoom,
            0.0,
            if g.color { 3.0 } else { 1.0 },
            0.0,
            0.0,
            if g.color { 0xFFFFFFFFL } else { tt.eff_fg },
            alpha,
            g.u,
            g.v,
            g.gw * (sc / zoom),
            g.gh * (sc / zoom),
          )
          glyph_pushing.val = false
        }
      }
      col_off += fake_char_width(ch)
    }
    self.emit_rect(cur_px + comp_w, cur_py + 2.0, 1.8, (line_h - 4.0).max(2.0), 0.9, tt.eff_cur, 0.0, 0L, alpha)
  }

  // Pass 4: Scrollback thumb along the right edge when history exists (`sb_total > sb_len`)
  if tt.sb_total > tt.sb_len && tt.sb_len > 0 && h > 16.0 {
    let at_bottom = (tt.modes & @hostapi.term_mode_viewport_active) != 0
    let age = view_moment() - tt.sb_changed_at
    let thumb_alpha = if !at_bottom {
      0.52
    } else if age >= 0.0 && age < 600.0 {
      // (shown as it is till its fade sets out: a frame asked for then, none before)
      self.wake_at_time(tt.sb_changed_at + 600.0, later=true)
      0.42
    } else if age >= 600.0 && age < 900.0 {
      // (fading by the clock: a frame each frame till it is gone, and one at its end)
      frame_clock.val.get() |> ignore
      self.motion_read = true
      self.wake_at_time(tt.sb_changed_at + 900.0, later=true)
      0.42 * ((900.0 - age) / 300.0).clamp(min=0.0, max=1.0)
    } else {
      0.0
    }
    if thumb_alpha > 0.01 {
      let track_h = (h - 8.0).max(8.0)
      let ratio = tt.sb_len.to_double() / tt.sb_total.to_double()
      let thumb_h = (track_h * ratio).clamp(min=24.0, max=track_h)
      let max_off = (tt.sb_total - tt.sb_len).max(1).to_double()
      let frac = (tt.sb_offset.to_double() / max_off).clamp(min=0.0, max=1.0)
      let thumb_y = uy + 4.0 + (track_h - thumb_h) * frac
      self.emit_rect(ux + w - 5.5, thumb_y, 3.5, thumb_h, 1.75, 0xFFFFFFFCL, 0.0, 0L, alpha * thumb_alpha)
    }
  }

  pop_clip()
  inst_owners.painting = was_owner
  inst_owners.tree_painting = was_tree
  self.transform_insts(i0, self.ninst, ux, uy, s, s, x - ux, y - uy, outer, outer_r, outer_s)
}

///|
fn tree_terminal_gone(id : @view.NodeId) -> Unit {
  if tree_terminals.contains(id) {
    tree_terminals.remove(id)
    tree_terminals_rev.val = tree_terminals_rev.val + 1
  }
}

///|
/// Dedicated monospace grid node for a `@hostapi.Terminal`.
#callsite(autofill(loc))
pub fn terminal_grid(
  parent : @view.View,
  term : () -> @hostapi.Terminal?,
  rev : () -> Int,
  size : () -> Double,
  line_h : () -> Double,
  pad : () -> (Double, Double),
  focused : () -> Bool,
  composing : () -> String,
  default_fg? : Int64 = 0xD8D9DBFFL,
  default_bg? : Int64 = 0x16171AFFL,
  cursor_color? : Int64 = 0xE68A3EFFL,
  selection_bg? : Int64 = 0x3B82F666L,
  on_cursor? : (Double, Double, Double) -> Unit = fn(_, _, _) { () },
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(b) {
    let id = b.id()
    tree_terminals_rev.val = tree_terminals_rev.val + 1
    tree_terminals[id] = {
      term,
      rev,
      size,
      line_h,
      pad,
      focused,
      composing,
      default_fg,
      default_bg,
      cursor_color,
      selection_bg,
      on_cursor,
      last_rev: -1,
      cols: 0,
      rows_n: 0,
      cursor_x: 0,
      cursor_y: 0,
      cursor_style: 1,
      cursor_flags: 0,
      modes: 0,
      eff_fg: default_fg,
      eff_bg: default_bg,
      eff_cur: cursor_color,
      sb_total: 0,
      sb_offset: 0,
      sb_len: 0,
      sb_changed_at: -1.0e9,
      rows: [],
    }
    b.grow(Is(1.0)).min_height(Is(Some(0.0))).owns(fn() { tree_terminal_gone(id) }) |> ignore
  })
}

///|
/// Pointer and touch gestures for a `terminal_grid`: SGR mouse reporting when mouse tracking is active (`Shift` forces
/// local selection), mouse click/double-click/triple-click/drag selection, and touch single-finger smooth/inertial
/// scrollback pan + long-press word selection + tap focus.
pub fn terminal_grid_gesture(
  grid : @view.View,
  term : () -> @hostapi.Terminal?,
  sync_modes : () -> Int,
  can_type : () -> Bool,
  cell_at : (Double, Double) -> (Int, Int),
  send_mouse : (Int, Int, Double, Double, Int) -> Unit,
  scroll_by_px : (Double, Int) -> Bool,
  stop_fling : () -> Unit,
  start_fling : (Double, Double) -> Unit,
  bump_drawn : () -> Unit,
  clear_selection : () -> Unit,
  focus_desktop : () -> Unit,
  focus_touch : () -> Unit,
) -> @view.View {
  let last_click_at : Ref[Double] = Ref(-1000.0)
  let last_click_cell : Ref[(Int, Int)] = Ref((-1, -1))
  let click_count : Ref[Int] = Ref(0)
  let drag_mode : Ref[Int] = Ref(0) // 0 none, 1 select, 2 pan_scroll, 3 mouse_sgr
  let sel_anchor : Ref[(Int, Int)] = Ref((0, 0))
  let pan_prev_y : Ref[Double] = Ref(0.0)
  let mouse_down_sent : Ref[Bool] = Ref(false)
  grid.gesture(
    touch_slop(),
    press=fn(d) {
      stop_fling()
      pan_prev_y.val = d.wy
      drag_mode.val = 0
      mouse_down_sent.val = false
      let modes = sync_modes()
      let mods = @hostapi.mods_held() & 15
      let shift = (mods & 1) != 0
      let is_mouse = pointing() is Mouse
      if (modes & @hostapi.term_mode_mouse_tracking) != 0 && !shift && @signals.untracked(can_type) {
        drag_mode.val = 3
        mouse_down_sent.val = true
        send_mouse(0, 1, d.x, d.y, mods)
        if is_mouse {
          focus_desktop()
        }
      } else if is_mouse {
        focus_desktop()
        let (col, row) = cell_at(d.x, d.y)
        if d.at - last_click_at.val <= 360.0 && last_click_cell.val == (col, row) {
          click_count.val = if click_count.val >= 3 { 1 } else { click_count.val + 1 }
        } else {
          click_count.val = 1
        }
        last_click_at.val = d.at
        last_click_cell.val = (col, row)
        sel_anchor.val = (col, row)
        match term() {
          Some(t) =>
            if click_count.val == 2 {
              t.select(2, col, row, col, row) |> ignore
              bump_drawn()
            } else if click_count.val == 3 {
              t.select(3, col, row, col, row) |> ignore
              bump_drawn()
            } else if (modes & @hostapi.term_mode_has_selection) != 0 {
              t.select(0, 0, 0, 0, 0) |> ignore
              bump_drawn()
            }
          None => ()
        }
      }
    },
    tap=fn(d) {
      if mouse_down_sent.val {
        mouse_down_sent.val = false
        send_mouse(1, 1, d.x, d.y, @hostapi.mods_held() & 15)
        focus_touch()
        return
      }
      if pointing() is Finger {
        let modes = sync_modes()
        if (modes & @hostapi.term_mode_has_selection) != 0 {
          clear_selection()
        } else {
          focus_touch()
        }
      }
    },
    hold=(
      380.0,
      fn(d) {
        if pointing() is Finger && !mouse_down_sent.val {
          let (col, row) = cell_at(d.x, d.y)
          sel_anchor.val = (col, row)
          drag_mode.val = 1
          match term() {
            Some(t) => {
              t.select(2, col, row, col, row) |> ignore
              haptic(LongPress)
              bump_drawn()
            }
            None => ()
          }
        }
      },
    ),
    drag=fn(d) {
      let modes = sync_modes()
      let mods = @hostapi.mods_held() & 15
      match d.kind {
        Down => {
          pan_prev_y.val = d.wy
          if drag_mode.val == 0 {
            if pointing() is Mouse {
              drag_mode.val = 1
              let (c0, r0) = sel_anchor.val
              let (c1, r1) = cell_at(d.x, d.y)
              match term() {
                Some(t) => {
                  t.select(1, c0, r0, c1, r1) |> ignore
                  bump_drawn()
                }
                None => ()
              }
            } else {
              drag_mode.val = 2
              // Finger moving down (d.wy > oy) scrolls up toward older lines (-dy)
              scroll_by_px(d.oy - d.y, modes) |> ignore
            }
          }
        }
        Moved =>
          if drag_mode.val == 3 {
            send_mouse(2, 1, d.x, d.y, mods)
          } else if drag_mode.val == 1 {
            let (c0, r0) = sel_anchor.val
            let (c1, r1) = cell_at(d.x, d.y)
            match term() {
              Some(t) => {
                t.select(1, c0, r0, c1, r1) |> ignore
                bump_drawn()
              }
              None => ()
            }
          } else if drag_mode.val == 2 {
            let dy_finger = d.wy - pan_prev_y.val
            pan_prev_y.val = d.wy
            scroll_by_px(-dy_finger, modes) |> ignore
          }
        Up => {
          if mouse_down_sent.val {
            mouse_down_sent.val = false
            send_mouse(1, 1, d.x, d.y, mods)
          } else if drag_mode.val == 2 {
            let vy0 = -d.vy()
            if vy0.abs() >= 0.12 {
              start_fling(d.at + 16.0, vy0)
            }
          }
          drag_mode.val = 0
        }
        Off => {
          if mouse_down_sent.val {
            mouse_down_sent.val = false
            send_mouse(1, 1, d.x, d.y, mods)
          }
          drag_mode.val = 0
        }
      }
    },
  )
}
