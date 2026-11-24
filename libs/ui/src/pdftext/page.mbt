// The words on a PDF's pages and where each glyph lies, as fractions of the page as it is shown (its crop box, turned as
// it says), so they lie over the picture the host draws of it at any size. Text drawn invisible counts: it is what a
// scanned page's recognised words are.

///|
/// One glyph: what it says ("" where the file does not say) and its box on the page, from its top left, 0 to 1.
pub struct Glyph {
  text : String
  x0 : Double
  y0 : Double
  x1 : Double
  y1 : Double
  /// which line of the page it is on
  line : Int
}

///|
/// A page's glyphs in the order the file draws them.
pub struct PageText {
  glyphs : Array[Glyph]
  /// how far across the page's lines reach, for lines that wrap
  right : Double
}

///|
/// A PDF read for its words.
pub struct Doc {
  priv objects : Objects
  priv page_dicts : Array[PageDict]
  priv fonts : Map[Int, Font]
  priv texts : Map[Int, PageText]
}

///|
priv struct PageDict {
  dict : Map[String, Obj]
  resources : Obj
  box_ : (Double, Double, Double, Double)
  rotate : Int
}

///|
/// The most glyphs read of one page.
const MOST_GLYPHS : Int = 200000

///|
/// The most operators run for one page.
const MOST_OPS : Int = 4000000

///|
/// How deep forms may draw forms.
const MOST_FORMS : Int = 8

///|
/// The most pages read.
const MOST_PAGES : Int = 100000

///|
/// The PDF in `data`; None where it cannot be read for words (damaged, encrypted, too big).
pub fn Doc::open(data : Bytes) -> Doc? {
  guard Objects::scan(data) is Some(o) else { return None }
  let pages : Array[PageDict] = []
  guard o.dict(Some(o.root)) is Some(root) else { return None }
  o.walk_pages(root.get("Pages"), Null, None, None, 0, pages, Set([]))
  if pages.is_empty() {
    return None
  }
  Some({ objects: o, page_dicts: pages, fonts: Map([]), texts: Map([]) })
}

///|
/// How many pages it was found to have.
pub fn Doc::pages(self : Doc) -> Int {
  self.page_dicts.length()
}

///|
fn Objects::walk_pages(
  self : Objects,
  node : Obj?,
  resources : Obj,
  media : Array[Double]?,
  crop : Array[Double]?,
  rotate : Int,
  out : Array[PageDict],
  seen : Set[Int],
) -> Unit {
  guard node is Some(n) else { return }
  match n {
    Link(id) => {
      if seen.contains(id) {
        return
      }
      seen.add(id)
    }
    _ => ()
  }
  guard self.get(n) is Dict(d) else { return }
  if out.length() >= MOST_PAGES || seen.length() > MOST_PAGES * 2 {
    return
  }
  let res = match d.get("Resources") {
    Some(r) => r
    None => resources
  }
  let box_of = fn(key : String, had : Array[Double]?) {
    let a = self.nums(d.get(key))
    if a.length() == 4 {
      Some(a)
    } else {
      had
    }
  }
  let m = box_of("MediaBox", media)
  let c = box_of("CropBox", crop)
  let r = match self.of(d.get("Rotate")) {
    Num(v) => ((v.to_int() % 360) + 360) % 360
    _ => rotate
  }
  match self.of(d.get("Kids")) {
    List(kids) =>
      for k in kids {
        self.walk_pages(Some(k), res, m, c, r, out, seen)
      }
    _ => {
      let mb = normal_box(m.unwrap_or([0.0, 0.0, 612.0, 792.0]))
      let shown = match c {
        Some(a) => {
          let cb = normal_box(a)
          let cut = (dmax(cb.0, mb.0), dmax(cb.1, mb.1), dmin(cb.2, mb.2), dmin(cb.3, mb.3))
          if cut.2 > cut.0 && cut.3 > cut.1 {
            cut
          } else {
            mb
          }
        }
        None => mb
      }
      out.push({ dict: d, resources: res, box_: shown, rotate: r })
    }
  }
}

///|
fn normal_box(a : Array[Double]) -> (Double, Double, Double, Double) {
  (dmin(a[0], a[2]), dmin(a[1], a[3]), dmax(a[0], a[2]), dmax(a[1], a[3]))
}

///|
fn dmin(a : Double, b : Double) -> Double {
  if a < b {
    a
  } else {
    b
  }
}

///|
fn dmax(a : Double, b : Double) -> Double {
  if a > b {
    a
  } else {
    b
  }
}

///|
/// A matrix `[a b c d e f]`.
priv struct Mat {
  a : Double
  b : Double
  c : Double
  d : Double
  e : Double
  f : Double
}

///|
let identity : Mat = { a: 1.0, b: 0.0, c: 0.0, d: 1.0, e: 0.0, f: 0.0 }

///|
/// `self` applied first, then `o`.
fn Mat::then(self : Mat, o : Mat) -> Mat {
  {
    a: self.a * o.a + self.b * o.c,
    b: self.a * o.b + self.b * o.d,
    c: self.c * o.a + self.d * o.c,
    d: self.c * o.b + self.d * o.d,
    e: self.e * o.a + self.f * o.c + o.e,
    f: self.e * o.b + self.f * o.d + o.f,
  }
}

///|
fn Mat::point(self : Mat, x : Double, y : Double) -> (Double, Double) {
  (x * self.a + y * self.c + self.e, x * self.b + y * self.d + self.f)
}

///|
fn mat_of(a : Array[Double]) -> Mat? {
  if a.length() == 6 {
    Some({ a: a[0], b: a[1], c: a[2], d: a[3], e: a[4], f: a[5] })
  } else {
    None
  }
}

///|
priv struct Gs {
  ctm : Mat
  font : Font?
  size : Double
  char_space : Double
  word_space : Double
  horizontal : Double
  leading : Double
  rise : Double
}

///|
/// A page being read.
priv struct Reader {
  doc : Doc
  out : Array[Glyph]
  mut ops : Int
  box_ : (Double, Double, Double, Double)
  rotate : Int
}

///|
/// A point of the page's default space as a fraction of the page as shown.
fn Reader::on_page(self : Reader, x : Double, y : Double) -> (Double, Double) {
  let (x0, y0, x1, y1) = self.box_
  let w = x1 - x0
  let h = y1 - y0
  match self.rotate {
    90 => ((y - y0) / h, (x - x0) / w)
    180 => ((x1 - x) / w, (y - y0) / h)
    270 => ((y1 - y) / h, (x1 - x) / w)
    _ => ((x - x0) / w, (y1 - y) / h)
  }
}

///|
/// What page `i` says; none where it is past the end.
pub fn Doc::page(self : Doc, i : Int) -> PageText {
  match self.texts.get(i) {
    Some(t) => t
    None => {
      let t = self.read_page(i)
      self.texts[i] = t
      t
    }
  }
}

///|
fn Doc::read_page(self : Doc, i : Int) -> PageText {
  guard i >= 0 && i < self.page_dicts.length() else { return { glyphs: [], right: 0.0 } }
  let p = self.page_dicts[i]
  let o = self.objects
  o.decoded = 0
  let r : Reader = { doc: self, out: [], ops: 0, box_: p.box_, rotate: p.rotate }
  let parts : Array[Bytes] = []
  match o.of(p.dict.get("Contents")) {
    Stream(_, _, _) as s =>
      match o.stream_bytes(s) {
        Some(x) => parts.push(x)
        None => ()
      }
    List(a) =>
      for x in a {
        match o.stream_bytes(o.get(x)) {
          Some(y) => parts.push(y)
          None => ()
        }
      }
    _ => ()
  }
  // (a page's content streams are one: an operator may end in the next)
  let whole = Buffer(capacity=parts.fold(init=0, fn(n, x) { n + x.length() + 1 }))
  for x in parts {
    whole.write_bytes(x)
    whole.write_byte(b'\n')
  }
  let gs : Gs = {
    ctm: identity,
    font: None,
    size: 0.0,
    char_space: 0.0,
    word_space: 0.0,
    horizontal: 1.0,
    leading: 0.0,
    rise: 0.0,
  }
  r.run(whole.to_bytes(), o.of(Some(p.resources)), gs, 0)
  placed(r.out)
}

///|
/// A run of glyphs drawn together on one line, and the box it lies in.
priv struct Run {
  from : Int
  to : Int
  x0 : Double
  y0 : Double
  x1 : Double
  y1 : Double
}

///|
/// Glyphs in the order they are read, each with its line said. A file may draw a page's parts in any order (a heading
/// after the words under it, a footer first), and picking runs through glyphs in this order.
fn placed(raw : Array[Glyph]) -> PageText {
  let order : Array[Run] = []
  read_order(runs_of(raw), order, 0)
  let sorted : Array[Glyph] = []
  for r in order {
    for k in r.from..<r.to {
      sorted.push(raw[k])
    }
  }
  let out : Array[Glyph] = []
  let mut line = 0
  let mut top = 0.0
  let mut foot = 0.0
  let mut was_x = 0.0
  let mut right = 0.0
  for k, g in sorted {
    let mid = (g.y0 + g.y1) / 2.0
    if k > 0 {
      let tall = dmax(g.y1 - g.y0, foot - top)
      // (off the line it was on, or back across it by more than a line's height)
      if mid < top || mid > foot || g.x0 < was_x - 2.0 * tall {
        line += 1
        top = g.y0
        foot = g.y1
      } else {
        top = dmin(top, g.y0)
        foot = dmax(foot, g.y1)
      }
    } else {
      top = g.y0
      foot = g.y1
    }
    was_x = g.x1
    right = dmax(right, g.x1)
    out.push({ ..g, line, })
  }
  { glyphs: out, right }
}

///|
/// The runs of glyphs next to each other on a line, as drawn.
fn runs_of(raw : Array[Glyph]) -> Array[Run] {
  let out : Array[Run] = []
  let mut k = 0
  while k < raw.length() {
    let from = k
    let mut x0 = raw[k].x0
    let mut y0 = raw[k].y0
    let mut x1 = raw[k].x1
    let mut y1 = raw[k].y1
    k += 1
    while k < raw.length() {
      let g = raw[k]
      let mid = (g.y0 + g.y1) / 2.0
      let tall = y1 - y0
      if mid < y0 || mid > y1 || g.x0 < x1 - tall || g.x0 > x1 + 2.0 * tall {
        break
      }
      x0 = dmin(x0, g.x0)
      y0 = dmin(y0, g.y0)
      x1 = dmax(x1, g.x1)
      y1 = dmax(y1, g.y1)
      k += 1
    }
    out.push({ from, to: k, x0, y0, x1, y1 })
  }
  out
}

///|
/// How narrow a gap down the page may be and still part two columns.
let column_gap : Double = 0.012

///|
/// How wide a column's lines reach at least, as a share of the page: a table's cells are narrower, and read across.
let column_line : Double = 0.15

///|
/// How deep a page's parts may be cut.
const MOST_CUTS : Int = 24

///|
/// `runs` into `out` in reading order: cut into columns where a clear gap runs down all of them, else into blocks where
/// a gap wider than the lines' own runs across them, each part read the same way; what cannot be cut, top to bottom.
fn read_order(runs : Array[Run], out : Array[Run], depth : Int) -> Unit {
  if runs.length() <= 1 || depth >= MOST_CUTS {
    top_down(runs, out)
    return
  }
  match column_cut(runs) {
    Some((left, right)) => {
      read_order(left, out, depth + 1)
      read_order(right, out, depth + 1)
    }
    None => {
      let blocks = block_cut(runs)
      if blocks.length() <= 1 {
        top_down(runs, out)
      } else {
        for b in blocks {
          read_order(b, out, depth + 1)
        }
      }
    }
  }
}

///|
/// Top to bottom, what shares a line left to right. By each run's line first (its middle, to a quarter of a line), so
/// the order is a total one whatever the runs are.
fn top_down(runs : Array[Run], out : Array[Run]) -> Unit {
  let talls = runs.map(fn(r) { r.y1 - r.y0 })
  talls.sort()
  let unit = if talls.is_empty() { 0.01 } else { dmax(talls[talls.length() / 2] * 0.5, 0.0005) }
  let sorted = runs.copy()
  sorted.sort_by(fn(a, b) {
    let la = ((a.y0 + a.y1) / 2.0 / unit).floor()
    let lb = ((b.y0 + b.y1) / 2.0 / unit).floor()
    if la != lb {
      la.compare(lb)
    } else {
      a.x0.compare(b.x0)
    }
  })
  out.append(sorted)
}

///|
/// The widest gap running down all of `runs`, parting two columns of real lines.
fn column_cut(runs : Array[Run]) -> (Array[Run], Array[Run])? {
  let by_x = runs.copy()
  by_x.sort_by(fn(a, b) { a.x0.compare(b.x0) })
  let mut reach = by_x[0].x1
  let mut best = -1.0
  let mut at = -1.0
  for k in 1..<by_x.length() {
    let gap = by_x[k].x0 - reach
    if gap > best {
      best = gap
      at = reach + gap / 2.0
    }
    reach = dmax(reach, by_x[k].x1)
  }
  if best < column_gap {
    return None
  }
  let left = runs.filter(fn(r) { r.x1 <= at })
  let right = runs.filter(fn(r) { r.x0 >= at })
  if left.length() < 3 || right.length() < 3 || wide_part(left) < column_line || wide_part(right) < column_line {
    return None
  }
  Some((left, right))
}

///|
/// How wide the lines of a part reach, the widest of them.
fn wide_part(runs : Array[Run]) -> Double {
  let mut most = 0.0
  for r in runs {
    most = dmax(most, r.x1 - r.x0)
  }
  most
}

///|
/// `runs` parted where a gap across them is wider than their lines are tall.
fn block_cut(runs : Array[Run]) -> Array[Array[Run]] {
  let by_y = runs.copy()
  by_y.sort_by(fn(a, b) { a.y0.compare(b.y0) })
  let talls = runs.map(fn(r) { r.y1 - r.y0 })
  talls.sort()
  let tall = talls[talls.length() / 2]
  let out : Array[Array[Run]] = []
  let mut now = [by_y[0]]
  let mut foot = by_y[0].y1
  for k in 1..<by_y.length() {
    let r = by_y[k]
    if r.y0 - foot > tall * 0.6 {
      out.push(now)
      now = []
    }
    now.push(r)
    foot = dmax(foot, r.y1)
  }
  out.push(now)
  out
}

///|
fn Reader::font_named(self : Reader, res : Obj, name : String) -> Font? {
  let o = self.doc.objects
  guard res is Dict(rd) else { return None }
  guard o.dict(rd.get("Font")) is Some(fonts) else { return None }
  guard fonts.get(name) is Some(f) else { return None }
  match f {
    Link(id) =>
      match self.doc.fonts.get(id) {
        Some(made) => Some(made)
        None =>
          match o.dict(Some(f)) {
            Some(d) => {
              let made = o.font(d)
              self.doc.fonts[id] = made
              Some(made)
            }
            None => None
          }
      }
    _ =>
      match o.dict(Some(f)) {
        Some(d) => Some(o.font(d))
        None => None
      }
  }
}

///|
/// A string shown from text matrix `tm`; the matrix after it.
fn Reader::show(self : Reader, s : Bytes, gs : Gs, tm : Mat) -> Mat {
  guard gs.font is Some(font) else { return tm }
  let mut now = tm
  let mut i = 0
  while i < s.length() {
    let (code, n) = font.code_at(s, i)
    i += imax(n, 1)
    let w = font.advance(code)
    if self.out.length() < MOST_GLYPHS {
      let trm = { a: gs.size * gs.horizontal, b: 0.0, c: 0.0, d: gs.size, e: 0.0, f: gs.rise }
        .then(now)
        .then(gs.ctm)
      let corners = [
        trm.point(0.0, font.descent),
        trm.point(w, font.descent),
        trm.point(0.0, font.ascent),
        trm.point(w, font.ascent),
      ]
      let mut x0 = 1.0e18
      let mut y0 = 1.0e18
      let mut x1 = -1.0e18
      let mut y1 = -1.0e18
      for c in corners {
        let (u, v) = self.on_page(c.0, c.1)
        x0 = dmin(x0, u)
        y0 = dmin(y0, v)
        x1 = dmax(x1, u)
        y1 = dmax(y1, v)
      }
      // (what lies off the page, or has no size, cannot be pressed)
      if x1 > 0.0 && y1 > 0.0 && x0 < 1.0 && y0 < 1.0 && y1 > y0 && x0 == x0 && y0 == y0 {
        self.out.push({ text: plain_text(font.text_of(code)), x0, y0, x1, y1, line: 0 })
      }
    }
    let space = if n == 1 && code == 32 { gs.word_space } else { 0.0 }
    let tx = (w * gs.size + gs.char_space + space) * gs.horizontal
    now = { ..identity, e: tx }.then(now)
  }
  now
}

///|
fn num_at(args : Array[Obj], k : Int) -> Double {
  if k >= 0 && k < args.length() && args[k] is Num(n) {
    n
  } else {
    0.0
  }
}

///|
/// Content stream `data` run with resources `res`, from graphics state `start`.
fn Reader::run(self : Reader, data : Bytes, res : Obj, start : Gs, depth : Int) -> Unit {
  let lex = Lex::new(data, 0, data.length(), links=false)
  let mut gs = start
  let stack : Array[Gs] = []
  let mut tm = identity
  let mut line = identity
  let args : Array[Obj] = []
  let next_line = fn(x : Double, y : Double) {
    line = { ..identity, e: x, f: y }.then(line)
    tm = line
  }
  while self.ops < MOST_OPS {
    guard lex.next() is Some(t) else { break }
    guard t is Op(op) else {
      args.push(t)
      if args.length() > 4096 {
        args.clear()
      }
      continue
    }
    self.ops += 1
    let n = args.length()
    match op {
      "q" => if stack.length() < 512 { stack.push(gs) }
      "Q" =>
        match stack.pop() {
          Some(g) => gs = g
          None => ()
        }
      "cm" =>
        if n >= 6 {
          let m = { a: num_at(args, n - 6), b: num_at(args, n - 5), c: num_at(args, n - 4), d: num_at(args, n - 3), e: num_at(args, n - 2), f: num_at(args, n - 1) }
          gs = { ..gs, ctm: m.then(gs.ctm) }
        }
      "BT" => {
        tm = identity
        line = identity
      }
      "Tf" =>
        if n >= 2 && args[n - 2] is Name(f) {
          gs = { ..gs, font: self.font_named(res, f), size: num_at(args, n - 1) }
        }
      "Tc" => gs = { ..gs, char_space: num_at(args, n - 1) }
      "Tw" => gs = { ..gs, word_space: num_at(args, n - 1) }
      "Tz" => gs = { ..gs, horizontal: num_at(args, n - 1) / 100.0 }
      "TL" => gs = { ..gs, leading: num_at(args, n - 1) }
      "Ts" => gs = { ..gs, rise: num_at(args, n - 1) }
      "Td" => next_line(num_at(args, n - 2), num_at(args, n - 1))
      "TD" => {
        gs = { ..gs, leading: -num_at(args, n - 1) }
        next_line(num_at(args, n - 2), num_at(args, n - 1))
      }
      "Tm" =>
        if n >= 6 {
          line = { a: num_at(args, n - 6), b: num_at(args, n - 5), c: num_at(args, n - 4), d: num_at(args, n - 3), e: num_at(args, n - 2), f: num_at(args, n - 1) }
          tm = line
        }
      "T*" => next_line(0.0, -gs.leading)
      "Tj" => if n >= 1 && args[n - 1] is Str(s) { tm = self.show(s, gs, tm) }
      "'" => {
        next_line(0.0, -gs.leading)
        if n >= 1 && args[n - 1] is Str(s) {
          tm = self.show(s, gs, tm)
        }
      }
      "\"" => {
        gs = { ..gs, word_space: num_at(args, n - 3), char_space: num_at(args, n - 2) }
        next_line(0.0, -gs.leading)
        if n >= 1 && args[n - 1] is Str(s) {
          tm = self.show(s, gs, tm)
        }
      }
      "TJ" =>
        if n >= 1 && args[n - 1] is List(items) {
          for it in items {
            match it {
              Str(s) => tm = self.show(s, gs, tm)
              Num(v) => {
                let tx = -v / 1000.0 * gs.size * gs.horizontal
                tm = { ..identity, e: tx }.then(tm)
              }
              _ => ()
            }
          }
        }
      "Do" =>
        if n >= 1 && args[n - 1] is Name(x) && depth < MOST_FORMS {
          self.form(res, x, gs, depth)
        }
      "BI" => skip_inline_image(lex)
      _ => ()
    }
    args.clear()
  }
}

///|
/// Past an inline image, from its `BI` to after its `EI`.
fn skip_inline_image(lex : Lex) -> Unit {
  let at = find(lex.b, "ID", lex.i, lex.end)
  if at < 0 {
    lex.i = lex.end
    return
  }
  let mut k = at + 2
  while k + 1 < lex.end {
    if lex.b[k].to_int() == 69 &&
      lex.b[k + 1].to_int() == 73 &&
      is_space(lex.b[k - 1].to_int()) &&
      (k + 2 >= lex.end || is_space(lex.b[k + 2].to_int())) {
      lex.i = k + 2
      return
    }
    k += 1
  }
  lex.i = lex.end
}

///|
/// Form XObject `name` drawn.
fn Reader::form(self : Reader, res : Obj, name : String, gs : Gs, depth : Int) -> Unit {
  let o = self.doc.objects
  guard res is Dict(rd) else { return }
  guard o.dict(rd.get("XObject")) is Some(xs) else { return }
  let s = o.of(xs.get(name))
  guard s is Stream(d, _, _) else { return }
  guard o.name_of(d.get("Subtype")) == "Form" else { return }
  guard o.stream_bytes(s) is Some(data) else { return }
  let m = mat_of(o.nums(d.get("Matrix"))).unwrap_or(identity)
  let own = match o.of(d.get("Resources")) {
    Dict(_) as r => r
    _ => res
  }
  self.run(data, own, { ..gs, ctm: m.then(gs.ctm) }, depth + 1)
}

///|
/// Whether a page's words can be picked: it has glyphs and most say what they are.
pub fn PageText::readable(self : PageText) -> Bool {
  let n = self.glyphs.length()
  if n == 0 {
    return false
  }
  let mut known = 0
  for g in self.glyphs {
    if g.text != "" {
      known += 1
    }
  }
  known * 2 >= n
}

///|
/// The glyph at or nearest (`u`, `v`), a fraction of the page; None where the page has none.
pub fn PageText::nearest(self : PageText, u : Double, v : Double) -> Int? {
  let mut best = -1
  let mut best_far = 1.0e18
  for k, g in self.glyphs {
    let dx = if u < g.x0 {
      g.x0 - u
    } else if u > g.x1 {
      u - g.x1
    } else {
      0.0
    }
    let dy = if v < g.y0 {
      g.y0 - v
    } else if v > g.y1 {
      v - g.y1
    } else {
      0.0
    }
    // (the line it is on before how far along it)
    let far = dy * 1000.0 + dx
    if far < best_far {
      best_far = far
      best = k
    }
  }
  if best < 0 {
    None
  } else {
    Some(best)
  }
}

///|
/// Whether (`u`, `v`) is within `reach` of a glyph.
pub fn PageText::near(self : PageText, u : Double, v : Double, reach : Double) -> Bool {
  self.glyphs.iter().any(fn(g) { u >= g.x0 - reach && u <= g.x1 + reach && v >= g.y0 && v <= g.y1 })
}

///|
/// Whether a character is written without spaces between words.
fn is_wide(c : Char) -> Bool {
  let v = c.to_int()
  (v >= 0x2E80 && v <= 0x9FFF) || (v >= 0xAC00 && v <= 0xD7AF) || (v >= 0xF900 && v <= 0xFAFF) || (v >= 0xFF00 && v <= 0xFFEF)
}

///|
fn is_word_char(s : String) -> Bool {
  match s.iter().head() {
    Some(c) => {
      let v = c.to_int()
      (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || v == 95 || (v >= 0xC0 && v < 0x2000)
    }
    None => false
  }
}

///|
fn is_blank(s : String) -> Bool {
  s == "" || s.iter().all(fn(c) { c == ' ' || c == '\t' || c == '\n' || c == '\r' || c.to_int() == 0xA0 })
}

///|
/// The word round glyph `k`: its letters and digits together; a wide character is one by itself.
pub fn PageText::word_at(self : PageText, k : Int) -> (Int, Int) {
  let g = self.glyphs
  if k < 0 || k >= g.length() {
    return (0, 0)
  }
  if !is_word_char(g[k].text) {
    return (k, k + 1)
  }
  let mut a = k
  while a > 0 && g[a - 1].line == g[k].line && is_word_char(g[a - 1].text) {
    a -= 1
  }
  let mut b = k + 1
  while b < g.length() && g[b].line == g[k].line && is_word_char(g[b].text) {
    b += 1
  }
  (a, b)
}

///|
/// How wide a line is at least, as a share of the page, to be taken for one that wraps.
let wrap_least : Double = 0.4

///|
/// What glyphs `a` to `b` (not `b`) say: a space where a gap between words is drawn and not written, lines that wrap
/// joined, a line break between the others.
pub fn PageText::words(self : PageText, a : Int, b : Int) -> String {
  let g = self.glyphs
  let from = imax(a, 0)
  let to = imin(b, g.length())
  let out = StringBuilder()
  let mut last : Char? = None
  let say = fn(s : String) {
    out.write_string(s)
    for c in s {
      last = Some(c)
    }
  }
  for k in from..<to {
    let c = g[k]
    if k > from {
      let p = g[k - 1]
      let wide_join = match (last, c.text.iter().head()) {
        (Some(x), Some(y)) => is_wide(x) || is_wide(y)
        _ => false
      }
      if c.line != p.line {
        let tall = p.y1 - p.y0
        // (a line that wraps runs on to the edge of the text, and is a long one: short lines are lines of their own)
        let mut start = k - 1
        while start > 0 && g[start - 1].line == p.line {
          start -= 1
        }
        let next_to = c.y0 - p.y1 < tall && p.x1 >= self.right - 1.5 * tall && p.x1 - g[start].x0 >= wrap_least
        if !next_to {
          say("\n")
        } else if !wide_join && !(last is Some(' ')) {
          say(" ")
        }
      } else if !wide_join && !is_blank(p.text) && !is_blank(c.text) {
        if c.x0 - p.x1 > 0.18 * (c.y1 - c.y0) {
          say(" ")
        }
      }
    }
    say(c.text)
  }
  out.to_string().trim(chars=" \n\t\r").to_owned()
}

///|
/// The boxes glyphs `a` to `b` (not `b`) lie in, one a line.
pub fn PageText::rects(self : PageText, a : Int, b : Int) -> Array[(Double, Double, Double, Double)] {
  let g = self.glyphs
  let out : Array[(Double, Double, Double, Double)] = []
  let mut k = imax(a, 0)
  let to = imin(b, g.length())
  while k < to {
    let line = g[k].line
    let mut x0 = g[k].x0
    let mut y0 = g[k].y0
    let mut x1 = g[k].x1
    let mut y1 = g[k].y1
    k += 1
    while k < to && g[k].line == line {
      x0 = dmin(x0, g[k].x0)
      y0 = dmin(y0, g[k].y0)
      x1 = dmax(x1, g[k].x1)
      y1 = dmax(y1, g[k].y1)
      k += 1
    }
    out.push((x0, y0, x1, y1))
  }
  out
}
