// The films' drives (scripts/motion: 大屏 1280×800's six, 小屏 390×844's six) and the two stills, each run twice the
// way the film runs it (the fixture's mode as sffilmscene opens it, a host's Tester: check_looks(false), its rows on
// the device's pixels, 60 frames a second), once on the old page and once on the page made as nodes, what each frame
// draws taken down and the two set side by side: the words (where each is drawn, how wide), the pictures (each paired
// with the other side's nearest, however many each draws: where, how big, how round and how opaque as much of it as is
// seen), the grounds with round corners (a card's, a bubble's, a choice's), the dark ground over the window (a viewer's,
// a picture held up's: where and how opaque), the rings of lines (the agent's at work), the composer's box, the round
// buttons over the list (跳到最新, 对话目录, the bell) and whether each shows, all as the frame's instances draw it. Held: every
// frame both draw at rest (a wait's end, the last) the same to a point and a half, what shows the same, but what the
// page as nodes mends of the old (pa_known, each said why); the page as nodes never drawn where all goes for one frame
// and back the next (a change set out a frame late). On the way, every frame held too: what differs past pa_way_tol
// fails but where pa_way_known says it, a row each, by drive, moments, what and how far, its cause in the code said (the
// two pages' ways set out at other frames or on other curves, the old's steps the page as nodes mends); a row that lets
// nothing pass fails as well, so the table says what is, never more.

///|
/// One frame taken down: its moment (ms since the drive began), each word drawn (text, x, y, w), each picture drawn
/// (x, y, w, h), the composer's box (x, y, w, h), and the round buttons showing (label, x, y, w, h).
struct PaFrame {
  at : Double
  words : Array[(String, Double, Double, Double)]
  pictures : Array[(Double, Double, Double, Double)]
  /// each word as opaque as it is drawn (text, x, y, alpha) and each picture, in pictures' order
  alphas : Array[(String, Double, Double, Double)]
  picture_alphas : Array[Double]
  /// how round each picture's corners are cut where it shows (its clip's, a node's own), in pictures' order
  picture_corners : Array[Double]
  /// where the host's own views show through (a player's, a native page's: Tester::holes)
  holes : Array[(Double, Double, Double, Double)]
  composer : (Double, Double, Double, Double)?
  floats : Array[(String, Double, Double, Double, Double)]
  /// each ground with round corners drawn (a card, a bubble, a quote's, a choice's: x, y, w, h, its corner, how opaque
  /// its ground is drawn), an old view's rectangles and the window's tree's alike
  grounds : Array[(Double, Double, Double, Double, Double, Double)]
  /// the dark ground over most of the window (a viewer's, a picture held up's: x, y, w, h, how opaque), the last drawn
  scrim : (Double, Double, Double, Double, Double)?
  /// each ring or spinner of lines drawn (Ctx::lines, View::lines: the agent's ring at work, the spokes; x, y, w, h,
  /// how many pieces, how opaque the most opaque of them)
  rings : Array[(Double, Double, Double, Double, Double, Double)]
}

///|
/// How opaque a colour RRGGBBAA's own alpha says it is.
fn pa_alpha_of(color : Int64) -> Double {
  (color & 0xFFL).to_double() / 255.0
}

///|
/// Whether a colour RRGGBBAA is dark (a viewer's ground, a scrim), whatever its alpha.
fn pa_dark(color : Int64) -> Bool {
  ((color >> 24) & 0xFFL) <= 0x50L && ((color >> 16) & 0xFFL) <= 0x50L && ((color >> 8) & 0xFFL) <= 0x50L
}

///|
/// How opaque the viewer's dark ground over all of the window is drawn from where what is under it counts as hidden
/// (PaFrame's scrim says how opaque it is on each side, held on its own: pa_diff).
let pa_cover_at : Double = 0.6

///|
/// The frame's instances as they lie over each other (Tester::drawn_cut, in the order drawn: the old view's and the
/// window's tree's alike, as the host draws them): what hides what is drawn before it where it lies (an opaque fill,
/// drawn_rects' 0.9 opaque at least; a dark ground over all of the window pa_cover_at opaque, a viewer's; glass: the bar
/// a list runs under), as the part of it seen (its box cut to its clip), by its place in that order; and the place in it
/// of each picture (drawn_images' order), each rectangle (drawn_rects') and each piece of a line (drawn_lines').
struct PaInst {
  covers : Array[(Int, Double, Double, Double, Double)]
  images : Array[Int]
  rects : Array[Int]
  lines : Array[Int]
}

///|
fn pa_inst(t : @ui.Tester, w : Double, h : Double) -> PaInst {
  let fills = t.drawn_rects()
  let covers = []
  let images = []
  let rects = []
  let lines = []
  for k, c in t.drawn_cut() {
    let (kind, x, y, cw, ch, cut) = c
    let seen = (x.max(cut.0), y.max(cut.1), (x + cw).min(cut.2), (y + ch).min(cut.3))
    match kind {
      0 => {
        let i = rects.length()
        rects.push(k)
        let color = fills.get(i).map(fn(f) { f.4 }).unwrap_or(0L)
        let a = pa_alpha_of(color)
        let whole = seen.0 <= 0.5 && seen.1 <= 0.5 && seen.2 >= w - 0.5 && seen.3 >= h - 0.5
        if a >= 0.9 || (whole && pa_dark(color) && a >= pa_cover_at) {
          covers.push((k, seen.0, seen.1, seen.2, seen.3))
        }
      }
      4 => images.push(k)
      5 | 6 => covers.push((k, seen.0, seen.1, seen.2, seen.3))
      10 => lines.push(k)
      _ => ()
    }
  }
  { covers, images, rects, lines }
}

///|
/// Whether instance `k` is hidden at (`px`, `py`) by what is drawn after it (PaInst's covers).
fn pa_hidden(p : PaInst, k : Int, px : Double, py : Double) -> Bool {
  k >= 0 && p.covers.iter().any(fn(c) { c.0 > k && px >= c.1 && px <= c.3 && py >= c.2 && py <= c.4 })
}

///|
/// Each picture a frame draws as much of it as is seen (PaFrame's pictures, picture_alphas, picture_corners): its
/// instance cut by what clips it (a frame's round corners, a list's edge) and the rounded clip outside that, how round
/// it is where what shows has its corners, how opaque; none hidden where its middle is by what is drawn after it (a bar
/// over the list, the composer's ground, a viewer's), none smaller than 16 × 16 (a face is one) or all but clear.
fn pa_pictures(
  t : @ui.Tester,
  inst : PaInst,
  w : Double,
  h : Double,
) -> (Array[(Double, Double, Double, Double)], Array[Double], Array[Double]) {
  let pictures = []
  let alphas = []
  let corners = []
  let clips = t.drawn_image_clips()
  let rounds = t.drawn_image_rounds()
  let none4 = (0.0, 0.0, 0.0, 0.0)
  let far = (-1.0e9, -1.0e9, 1.0e9, 1.0e9)
  for k, i in t.drawn_images() {
    let (box, clip_r) = clips.get(k).unwrap_or((far, none4))
    let (own_r, outer, outer_r) = rounds.get(k).unwrap_or((none4, far, none4))
    let outer = if outer_r == none4 { far } else { outer }
    // (and by the window: what lies past its edges is seen by no one)
    let x0 = i[0].max(box.0).max(outer.0).max(0.0)
    let y0 = i[1].max(box.1).max(outer.1).max(0.0)
    let x1 = (i[0] + i[2]).min(box.2).min(outer.2).min(w)
    let y1 = (i[1] + i[3]).min(box.3).min(outer.3).min(h)
    guard i[8] > 0.05 &&
      x1 - x0 >= 16.0 &&
      y1 - y0 >= 16.0 &&
      !pa_hidden(inst, inst.images.get(k).unwrap_or(-1), (x0 + x1) / 2.0, (y0 + y1) / 2.0) else {
      continue
    }
    // (how round what shows of it is at its corners: each corner of its own box, its clip and the clip outside that
    // which lies where what shows has its corner (within a point), the roundest of them; a clip far round it rounds
    // none of it)
    let round_at = fn(r : (Double, Double, Double, Double), b : (Double, Double, Double, Double)) {
      let near = fn(a : Double, v : Double) { (a - v).abs() <= 1.0 }
      let mut m = 0.0
      if near(b.0, x0) && near(b.1, y0) {
        m = m.max(r.0)
      }
      if near(b.2, x1) && near(b.1, y0) {
        m = m.max(r.1)
      }
      if near(b.2, x1) && near(b.3, y1) {
        m = m.max(r.2)
      }
      if near(b.0, x0) && near(b.3, y1) {
        m = m.max(r.3)
      }
      m
    }
    pictures.push((x0, y0, x1 - x0, y1 - y0))
    alphas.push(i[8])
    corners.push(
      round_at(own_r, (i[0], i[1], i[0] + i[2], i[1] + i[3]))
      .max(round_at(clip_r, box))
      .max(round_at(outer_r, outer))
      .min((x1 - x0).min(y1 - y0) / 2.0),
    )
  }
  (pictures, alphas, corners)
}

///|
/// The grounds with round corners a frame draws (PaFrame's grounds), as much of each as its clip leaves: none over most
/// of the window (the page's own, a scrim: PaFrame's scrim), none smaller than a chip (40 × 24), all but clear or hidden
/// where its middle is by what is drawn after it.
fn pa_grounds(t : @ui.Tester, inst : PaInst, w : Double, h : Double) -> Array[(Double, Double, Double, Double, Double, Double)] {
  let out : Array[(Double, Double, Double, Double, Double, Double)] = []
  let cut = t.drawn_cut()
  for i, r in t.drawn_rect_corners() {
    let (x, y, gw, gh, color, cs) = r
    let k = inst.rects.get(i).unwrap_or(-1)
    let (x0, y0, x1, y1) = match cut.get(k) {
      Some((_, _, _, _, _, c)) => (x.max(c.0), y.max(c.1), (x + gw).min(c.2), (y + gh).min(c.3))
      None => (x, y, x + gw, y + gh)
    }
    // (and by the window)
    let (x0, y0, x1, y1) = (x0.max(0.0), y0.max(0.0), x1.min(w), y1.min(h))
    let (gw, gh) = (x1 - x0, y1 - y0)
    // (how round, no rounder than half its least side: a pill's said as round as can be is that)
    let rad = cs.0.max(cs.1).max(cs.2).max(cs.3).min(gw.min(gh) / 2.0)
    let a = pa_alpha_of(color)
    if gw >= 40.0 &&
      gh >= 24.0 &&
      rad >= 4.0 &&
      a >= 0.02 &&
      !(gw >= w * 0.6 && gh >= h * 0.6) &&
      x1 > 0.0 &&
      x0 < w &&
      y1 > 0.0 &&
      y0 < h &&
      !pa_hidden(inst, k, (x0 + x1) / 2.0, (y0 + y1) / 2.0) {
      out.push((x0, y0, gw, gh, rad, a))
    }
  }
  out
}

///|
/// The dark ground over most of the window a frame draws last (PaFrame's scrim: x, y, w, h, how opaque).
fn pa_scrim(t : @ui.Tester, w : Double, h : Double) -> (Double, Double, Double, Double, Double)? {
  let mut out : (Double, Double, Double, Double, Double)? = None
  for r in t.drawn_rects() {
    let (x, y, gw, gh, color) = r
    let a = pa_alpha_of(color)
    if gw >= w * 0.6 && gh >= h * 0.6 && a > 0.01 && pa_dark(color) {
      out = Some((x, y, gw, gh, a))
    }
  }
  out
}

///|
/// The rings and spinners of lines a frame draws (PaFrame's rings): its pieces of lines (Tester::drawn_lines) gathered
/// by where they lie (each within 30 points of the first of its ring), each ring's box, how many pieces and the most
/// opaque of them; none all but clear or hidden by what is drawn after it.
fn pa_rings(t : @ui.Tester, inst : PaInst) -> Array[(Double, Double, Double, Double, Double, Double)] {
  // (x0, y0, x1, y1, pieces, most opaque, the first piece's middle)
  let gs : Array[(Double, Double, Double, Double, Double, Double, Double, Double)] = []
  for j, l in t.drawn_lines() {
    let (x0, y0, x1, y1, lw, color) = l
    let a = pa_alpha_of(color)
    let (mx, my) = ((x0 + x1) / 2.0, (y0 + y1) / 2.0)
    guard a > 0.02 && !pa_hidden(inst, inst.lines.get(j).unwrap_or(-1), mx, my) else { continue }
    let (lx, ly, hx, hy) = (x0.min(x1) - lw / 2.0, y0.min(y1) - lw / 2.0, x0.max(x1) + lw / 2.0, y0.max(y1) + lw / 2.0)
    match gs.search_by(fn(g) { (g.6 - mx).abs() <= 30.0 && (g.7 - my).abs() <= 30.0 }) {
      Some(i) => {
        let g = gs[i]
        gs[i] = (g.0.min(lx), g.1.min(ly), g.2.max(hx), g.3.max(hy), g.4 + 1.0, g.5.max(a), g.6, g.7)
      }
      None => gs.push((lx, ly, hx, hy, 1.0, a, mx, my))
    }
  }
  gs.map(fn(g) { (g.0, g.1, g.2 - g.0, g.3 - g.1, g.4, g.5) })
}

///|
/// The round buttons' names, as a screen reader is told them.
fn pa_float_names() -> Array[String] {
  [
    @sf.t("web-main.chat.toLatest"),
    @sf.t("web-main.outline.back"),
    @sf.t("web-main.outline.title"),
    @sf.t("web-main.chat.asks.go"),
  ]
}

///|
/// What the frame drawn now shows (see PaFrame), `start` the drive's first moment: all of it as the frame's instances
/// draw it (the old view's and the window's tree's alike), but the words, as each is drawn (Tester::words).
fn pa_take(
  t : @ui.Tester,
  start : Double,
  w : Double,
  h : Double,
  kept : Ref[((Double, Double, Double, Double), @view.NodeId, Double, Double)?],
) -> PaFrame {
  let inst = pa_inst(t, w, h)
  let (pictures, picture_alphas, picture_corners) = pa_pictures(t, inst, w, h)
  let grounds = pa_grounds(t, inst, w, h)
  let scrim = pa_scrim(t, w, h)
  let rings = pa_rings(t, inst)
  // (a picture opened big, the viewer's dark ground drawn over all the window pa_cover_at opaque at least: the words
  // under it are not taken, each page drawing or leaving them as it will (the old list's rows under its bar), how
  // opaque that ground is held of its own (the scrim), so only what is drawn after it is taken down)
  match pa_covered(w, h) {
    Some((words, alphas)) =>
      return {
        at: t.time() - start,
        words,
        pictures,
        alphas,
        picture_alphas,
        picture_corners,
        holes: t.holes(),
        composer: None,
        floats: [],
        grounds,
        scrim,
        rings,
      }
    None => ()
  }
  let words = []
  let alphas = []
  // (each word as it is seen: one none of whose glyphs shows (each hidden by what is drawn after it, a bar over the
  // list, the composer's ground, cut away by its clip: Tester::glyphs_seen) is not taken, on either side)
  let seen = t.glyphs_seen()
  for wd in t.words() {
    let (txt, x, y, ww, wh, a) = wd
    let shows = seen.iter().any(fn(g) {
      let (gx, gy) = ((g.0 + g.2) / 2.0, (g.1 + g.3) / 2.0)
      gx >= x - 1.0 && gx <= x + ww + 1.0 && gy >= y - 1.0 && gy <= y + wh.max(24.0) + 1.0
    })
    if a > 0.05 && txt != "" && x + ww > 0.0 && x < w && y < h && y > -40.0 && shows {
      // (a block of several lines one word, its breaks said so on one line)
      let txt = txt.replace_all(old="\n", new="⏎")
      words.push((txt, x, y, ww))
      alphas.push((txt, x, y, a))
    }
  }
  let names = pa_float_names()
  let floats = []
  // (each as a screen reader is told it, where it is and how big: what takes the press round it is the old view's 32
  // and the tree's 44, so two are held by their middles (pa_diff); one not laid out yet (none of a box) is not drawn)
  for s in t.semantics() {
    if !s.hidden && names.contains(s.label) {
      let (x, y, fw, fh) = s.rect
      if fw > 0.0 && fh > 0.0 {
        floats.push((s.label, x, y, fw, fh))
      }
    }
  }
  {
    at: t.time() - start,
    words,
    pictures,
    alphas,
    picture_alphas,
    picture_corners,
    holes: t.holes(),
    composer: pa_composer(t, kept),
    floats,
    grounds,
    scrim,
    rings,
  }
}

///|
/// The composer's box as the frame drew it. Where the old view builds it, as measured (`composer/content`); an old view
/// hosted in a node of the window's tree (the page as nodes: its composer an island in the list's foot) is built only as
/// it is asked, and carried by what holds it meanwhile (小屏's page pushed in, moved by its node's offset), so what was
/// measured is where it was built: moved by as much as the island it is in has been drawn moved since (`kept`: what was
/// measured, the island's node and where it was drawn then), never read where it last was built.
fn pa_composer(t : @ui.Tester, kept : Ref[((Double, Double, Double, Double), @view.NodeId, Double, Double)?]) -> (
  Double,
  Double,
  Double,
  Double,
)? {
  // (made as nodes: where the tree draws its box, with what its ground holds over it as words leave it)
  match @sfpages.composer_node_ground(t.time()) {
    Some(b) => return Some(b)
    None => ()
  }
  guard @motion.measured_rect(t.ctx(), "composer/content") is Some(m) else { return None }
  let (mx, my, mw, mh) = m
  guard @ui.view_tree() is Some(tr) else { return Some(m) }
  let drawn = tr.drawn()
  match kept.val {
    Some((km, id, ix, iy)) if km == m =>
      match drawn.search_by(fn(d) { d.id == id }) {
        Some(i) => return Some((mx + drawn[i].x - ix, my + drawn[i].y - iy, mw, mh))
        None => ()
      }
    _ => ()
  }
  // (built in this frame: the island it lies in, the smallest hosted node round it, and where that is drawn)
  let mut best : (@view.NodeId, Double, Double)? = None
  let mut area = 1.0e18
  for d in drawn {
    if d.hosted && d.x <= mx + 0.5 && d.y <= my + 0.5 && d.x + d.w >= mx + mw - 0.5 && d.y + d.h >= my + mh - 0.5 &&
      d.w * d.h < area {
      area = d.w * d.h
      best = Some((d.id, d.x, d.y))
    }
  }
  kept.val = best.map(fn(b) { (m, b.0, b.1, b.2) })
  Some(m)
}

///|
/// The words the window's tree draws after the viewer's ground, where a picture is open in it and its dark ground is
/// over all of the window `w` × `h`, pa_cover_at opaque at least: each (text, x, y, w) and how opaque (text, x, y,
/// alpha), as pa_take takes them; none where nothing so covers the window. The same on both sides.
fn pa_covered(w : Double, h : Double) -> (Array[(String, Double, Double, Double)], Array[(String, Double, Double, Double)])? {
  guard @sfbase.viewer.get() is Some(_) else { return None }
  guard @ui.view_tree() is Some(tr) else { return None }
  let drawn = tr.drawn()
  let mut from = -1
  for i, d in drawn {
    if d.x <= 0.5 && d.y <= 0.5 && d.x + d.w >= w - 0.5 && d.y + d.h >= h - 0.5 &&
      d.alpha * pa_alpha_of(d.ground) >= pa_cover_at &&
      pa_dark(d.ground) {
      from = i
    }
  }
  guard from >= 0 else { return None }
  let words = []
  let alphas = []
  for i in (from + 1)..<drawn.length() {
    let d = drawn[i]
    if d.alpha > 0.05 && d.words != "" && d.x + d.w > 0.0 && d.x < w && d.y < h && d.y > -40.0 {
      let txt = d.words.replace_all(old="\n", new="⏎")
      words.push((txt, d.x, d.y, d.w))
      alphas.push((txt, d.x, d.y, d.alpha))
    }
  }
  Some((words, alphas))
}

///|
/// `script` driven over fixture mode `mode`'s app on the old page or as nodes, `w` × `h` playing `platform`: each frame
/// taken down, and what the drive logged that failed.
fn pa_run(
  mode : String,
  nodes : Bool,
  w : Double,
  h : Double,
  platform : Int,
  script : String,
) -> (Array[PaFrame], Array[String]) {
  new_run()
  // (made as nodes: the page, its composer and the new chat, 试用新对话页)
  if nodes {
    @sfbase.chat_page_nodes.set(true)
  }
  let src = @sffixture.fixture(mode)
  open_fixture_over(mode, src)
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~, words_over_held=false)
  t.check_looks(false)
  t.set_rows_on_pixels(true)
  t.set_frame_period(1000.0 / 60.0)
  let start = t.time()
  let frames = []
  let kept = Ref(None)
  let logs = t.drive(script, each=fn(t) { frames.push(pa_take(t, start, w, h, kept)) })
  (frames, logs.filter(fn(l) { l.has_prefix("DRIVE FAIL") || l.has_prefix("DRIVE fail") }))
}

///|
/// How far apart two words may be drawn and still be taken for one (|dx| + |dy|): a word drawn several times (Claude,
/// 刚刚, 一起换) is each matched with the nearest of the same words on the other side, never with one a screen away
/// because the first of them has just gone off the top on one side and not yet on the other.
let pa_pair_far : Double = 120.0

///|
/// Each word of `a` matched with `b`'s of the same words, nearest first (pa_pair_far at most); those matched with none,
/// each side's, said with where they are.
fn pa_pairs(
  a : Array[(String, Double, Double, Double)],
  b : Array[(String, Double, Double, Double)],
) -> (
  Array[((String, Double, Double, Double), (String, Double, Double, Double))],
  Array[(String, String)],
  Array[(String, String)],
) {
  let by_a : Map[String, Array[(String, Double, Double, Double)]] = Map([])
  let by_b : Map[String, Array[(String, Double, Double, Double)]] = Map([])
  for x in a {
    match by_a.get(x.0) {
      Some(l) => l.push(x)
      None => by_a[x.0] = [x]
    }
  }
  for x in b {
    match by_b.get(x.0) {
      Some(l) => l.push(x)
      None => by_b[x.0] = [x]
    }
  }
  let pairs = []
  let only_a = []
  let only_b = []
  for k, la in by_a {
    let lb = by_b.get(k).unwrap_or([])
    let (ps, oa, ob) = pa_nearest(la, lb, fn(x) { (x.1, x.2) })
    for p in ps {
      pairs.push(p)
    }
    for x in oa {
      only_a.push((k, "「\{k}」@\{x.1.to_int()},\{x.2.to_int()}"))
    }
    for x in ob {
      only_b.push((k, "「\{k}」@\{x.1.to_int()},\{x.2.to_int()}"))
    }
  }
  for k, lb in by_b {
    if !by_a.contains(k) {
      for x in lb {
        only_b.push((k, "「\{k}」@\{x.1.to_int()},\{x.2.to_int()}"))
      }
    }
  }
  (pairs, only_a, only_b)
}

///|
/// `a` and `b` (things of one name) matched nearest first by where `at` says each is, none further apart than
/// pa_pair_far; what is matched with none, each side's.
fn[T] pa_nearest(
  a : Array[T],
  b : Array[T],
  at : (T) -> (Double, Double),
  far? : Double = pa_pair_far,
) -> (Array[(T, T)], Array[T], Array[T]) {
  let all : Array[(Double, Int, Int)] = []
  for i, x in a {
    for j, y in b {
      let (ax, ay) = at(x)
      let (bx, by) = at(y)
      let d = (ax - bx).abs() + (ay - by).abs()
      if d <= far {
        all.push((d, i, j))
      }
    }
  }
  all.sort_by(fn(p, q) {
    if p.0 != q.0 {
      p.0.compare(q.0)
    } else if p.1 != q.1 {
      p.1.compare(q.1)
    } else {
      p.2.compare(q.2)
    }
  })
  let used_a = Array::make(a.length(), false)
  let used_b = Array::make(b.length(), false)
  let pairs = []
  for e in all {
    let (_, i, j) = e
    if !used_a[i] && !used_b[j] {
      used_a[i] = true
      used_b[j] = true
      pairs.push((a[i], b[j]))
    }
  }
  let oa = []
  let ob = []
  for i, x in a {
    if !used_a[i] {
      oa.push(x)
    }
  }
  for j, y in b {
    if !used_b[j] {
      ob.push(y)
    }
  }
  (pairs, oa, ob)
}

///|
/// How far apart two pictures may be drawn and still be taken for one (|dx| + |dy| of their middles): one flying to the
/// viewer or back is held to the other side's wherever it is drawn, never let go as two alone.
let pa_picture_far : Double = 2400.0

///|
/// How much a ring's box may differ for how it turns: drawn as its pieces lie, an old view's (its pieces' own box) and
/// a node's (the node's box, the stroke within it) differ by its stroke at most.
let pa_ring_slack : Double = 4.0

///|
/// Four numbers rounded to tenths, for a line read by a person.
fn pa_box(x : Double, y : Double, w : Double, h : Double) -> String {
  let r = fn(v : Double) { (v * 10.0).round() / 10.0 }
  "(\{r(x)}, \{r(y)}, \{r(w)}, \{r(h)})"
}

///|
/// One thing that differs between an old frame and a nodes frame: what it is (`key`: a word by its words, one side's
/// word alone by its words, the composer, the pictures, a round button by its name), said for a person (`line`), and
/// by how much across, down and in width the page as nodes draws it off the old's (`dx`, `dy`, `dw`; none of them for
/// what one side alone draws).
struct PaDiff {
  key : String
  line : String
  dx : Double
  dy : Double
  dw : Double
}

///|
/// A difference no number says (what one side alone draws, how many pictures).
fn pa_alone(key : String, line : String) -> PaDiff {
  { key, line, dx: 1.0e9, dy: 1.0e9, dw: 1.0e9 }
}

///|
/// What differs between old frame `o` and nodes frame `n` past `tol` points: one each.
fn pa_diff(o : PaFrame, n : PaFrame, tol : Double, rings? : Bool = true) -> Array[PaDiff] {
  let out : Array[PaDiff] = []
  // (the words: each matched by its text, nearest first; one side's alone said by its words)
  let (pairs, only_o, only_n) = pa_pairs(o.words, n.words)
  for p in pairs {
    let (a, b) = p
    if (a.1 - b.1).abs() > tol || (a.2 - b.2).abs() > tol || (a.3 - b.3).abs() > tol {
      out.push({
        key: "words 「\{a.0}」",
        line: "words 「\{a.0}」 old \{pa_box(a.1, a.2, a.3, 0.0)} nodes \{pa_box(b.1, b.2, b.3, 0.0)} (dx \{b.1 - a.1}, dy \{b.2 - a.2}, dw \{b.3 - a.3})",
        dx: b.1 - a.1,
        dy: b.2 - a.2,
        dw: b.3 - a.3,
      })
    }
  }
  for w in only_o {
    out.push(pa_alone("old alone 「\{w.0}」", "words old alone: \{w.1}"))
  }
  for w in only_n {
    out.push(pa_alone("nodes alone 「\{w.0}」", "words nodes alone: \{w.1}"))
  }
  // (the composer's box)
  match (o.composer, n.composer) {
    (Some(a), Some(b)) =>
      if (a.0 - b.0).abs() > tol || (a.1 - b.1).abs() > tol || (a.2 - b.2).abs() > tol || (a.3 - b.3).abs() > tol {
        out.push({
          key: "composer",
          line: "composer old \{pa_box(a.0, a.1, a.2, a.3)} nodes \{pa_box(b.0, b.1, b.2, b.3)}",
          dx: b.0 - a.0,
          dy: b.1 - a.1,
          dw: (b.2 - a.2).abs().max((b.3 - a.3).abs()),
        })
      }
    (None, None) => ()
    _ => out.push(pa_alone("composer", "composer old \{Repr(o.composer)} nodes \{Repr(n.composer)}"))
  }
  // (the pictures: each of one side matched with the nearest of the other's by its middle, however many each draws,
  // and each pair held every frame by where it is, how big and how opaque; one side's alone said with where it is)
  let pics = fn(f : PaFrame) {
    Array::makei(f.pictures.length(), fn(i) {
      let p = f.pictures[i]
      (p.0, p.1, p.2, p.3, f.picture_alphas.get(i).unwrap_or(1.0), f.picture_corners.get(i).unwrap_or(0.0))
    })
  }
  let a_tol = if tol < 1.0 { 0.01 } else { pa_alpha_tol }
  let (ppairs, po_alone, pn_alone) = pa_nearest(
    pics(o),
    pics(n),
    fn(p) { (p.0 + p.2 / 2.0, p.1 + p.3 / 2.0) },
    far=pa_picture_far,
  )
  for pp in ppairs {
    let (a, b) = pp
    if (a.0 - b.0).abs() > tol || (a.1 - b.1).abs() > tol || (a.2 - b.2).abs() > tol || (a.3 - b.3).abs() > tol ||
      (a.5 - b.5).abs() > tol.max(1.0) {
      out.push({
        key: "picture",
        line: "picture old \{pa_box(a.0, a.1, a.2, a.3)} r \{pa_r(a.5)} nodes \{pa_box(b.0, b.1, b.2, b.3)} r \{pa_r(b.5)}",
        dx: b.0 - a.0,
        dy: b.1 - a.1,
        dw: (b.2 - a.2).abs().max((b.3 - a.3).abs()).max((a.5 - b.5).abs()),
      })
    }
    if (a.4 - b.4).abs() > a_tol {
      out.push({
        key: "picture alpha",
        line: "picture alpha old \{pa_r(a.4)} nodes \{pa_r(b.4)} at \{pa_box(b.0, b.1, b.2, b.3)}",
        dx: 0.0,
        dy: 0.0,
        dw: b.4 - a.4,
      })
    }
  }
  for a in po_alone {
    out.push(pa_alone("picture old alone", "picture old alone \{pa_box(a.0, a.1, a.2, a.3)} alpha \{pa_r(a.4)}"))
  }
  for b in pn_alone {
    out.push(pa_alone("picture nodes alone", "picture nodes alone \{pa_box(b.0, b.1, b.2, b.3)} alpha \{pa_r(b.4)}"))
  }
  // (the grounds with round corners (a card's, a bubble's, a quote's, a choice's), matched the same way, held by where
  // each is, how big, how round and how opaque; one side's alone said with where it is)
  let (gpairs, go_alone, gn_alone) = pa_nearest(o.grounds, n.grounds, fn(g) { (g.0 + g.2 / 2.0, g.1 + g.3 / 2.0) })
  for gp in gpairs {
    let (a, b) = gp
    if (a.0 - b.0).abs() > tol || (a.1 - b.1).abs() > tol || (a.2 - b.2).abs() > tol || (a.3 - b.3).abs() > tol ||
      (a.4 - b.4).abs() > tol.max(1.0) {
      out.push({
        key: "ground",
        line: "ground old \{pa_box(a.0, a.1, a.2, a.3)} r \{pa_r(a.4)} nodes \{pa_box(b.0, b.1, b.2, b.3)} r \{pa_r(b.4)}",
        dx: b.0 - a.0,
        dy: b.1 - a.1,
        dw: (b.2 - a.2).abs().max((b.3 - a.3).abs()).max((b.4 - a.4).abs()),
      })
    }
    if (a.5 - b.5).abs() > a_tol * a.5.max(b.5).max(0.07) {
      out.push({
        key: "ground alpha",
        line: "ground alpha old \{pa_r(a.5 * 100.0)}% nodes \{pa_r(b.5 * 100.0)}% at \{pa_box(b.0, b.1, b.2, b.3)}",
        dx: 0.0,
        dy: 0.0,
        dw: b.5 - a.5,
      })
    }
  }
  for a in go_alone {
    if a.5 >= 0.04 {
      out.push(pa_alone("ground old alone", "ground old alone \{pa_box(a.0, a.1, a.2, a.3)} r \{pa_r(a.4)} alpha \{pa_r(a.5 * 100.0)}%"))
    }
  }
  for b in gn_alone {
    if b.5 >= 0.04 {
      out.push(pa_alone("ground nodes alone", "ground nodes alone \{pa_box(b.0, b.1, b.2, b.3)} r \{pa_r(b.4)} alpha \{pa_r(b.5 * 100.0)}%"))
    }
  }
  // (the dark ground over the window: where it lies (all of it, a desk's side bar too) and how opaque, as it comes and
  // goes)
  match (o.scrim, n.scrim) {
    (Some(a), Some(b)) => {
      if (a.0 - b.0).abs() > tol || (a.1 - b.1).abs() > tol || (a.2 - b.2).abs() > tol || (a.3 - b.3).abs() > tol {
        out.push({
          key: "scrim",
          line: "scrim old \{pa_box(a.0, a.1, a.2, a.3)} nodes \{pa_box(b.0, b.1, b.2, b.3)}",
          dx: b.0 - a.0,
          dy: b.1 - a.1,
          dw: (b.2 - a.2).abs().max((b.3 - a.3).abs()),
        })
      }
      if (a.4 - b.4).abs() > a_tol {
        out.push({ key: "scrim alpha", line: "scrim alpha old \{pa_r(a.4)} nodes \{pa_r(b.4)}", dx: 0.0, dy: 0.0, dw: b.4 - a.4 })
      }
    }
    (Some(a), None) =>
      if a.4 > 0.05 {
        out.push(pa_alone("scrim old alone", "scrim old alone \{pa_box(a.0, a.1, a.2, a.3)} alpha \{pa_r(a.4)}"))
      }
    (None, Some(b)) =>
      if b.4 > 0.05 {
        out.push(pa_alone("scrim nodes alone", "scrim nodes alone \{pa_box(b.0, b.1, b.2, b.3)} alpha \{pa_r(b.4)}"))
      }
    (None, None) => ()
  }
  // (the rings of lines (the agent's at work, the spokes): matched the same way, held by their middles and how big (a
  // ring turning is drawn as its pieces lie, its box a little more or less round as it turns: pa_ring_slack) and how
  // opaque; one side's alone said with where it is. Not between two frames of a side: a ring turns as it stands)
  if rings {
    let (rpairs, ro_alone, rn_alone) = pa_nearest(o.rings, n.rings, fn(r) { (r.0 + r.2 / 2.0, r.1 + r.3 / 2.0) })
    for rp in rpairs {
      let (a, b) = rp
      let (dx, dy) = (b.0 + b.2 / 2.0 - a.0 - a.2 / 2.0, b.1 + b.3 / 2.0 - a.1 - a.3 / 2.0)
      let dw = (b.2 - a.2).abs().max((b.3 - a.3).abs())
      let rt = tol.max(pa_ring_slack)
      if dx.abs() > rt || dy.abs() > rt || dw > rt {
        out.push({ key: "ring", line: "ring old \{pa_box(a.0, a.1, a.2, a.3)} nodes \{pa_box(b.0, b.1, b.2, b.3)}", dx, dy, dw })
      }
      if (a.5 - b.5).abs() > a_tol {
        out.push({
          key: "ring alpha",
          line: "ring alpha old \{pa_r(a.5)} nodes \{pa_r(b.5)} at \{pa_box(b.0, b.1, b.2, b.3)}",
          dx: 0.0,
          dy: 0.0,
          dw: b.5 - a.5,
        })
      }
    }
    for a in ro_alone {
      if a.5 > 0.05 {
        out.push(pa_alone("ring old alone", "ring old alone \{pa_box(a.0, a.1, a.2, a.3)} pieces \{a.4} alpha \{pa_r(a.5)}"))
      }
    }
    for b in rn_alone {
      if b.5 > 0.05 {
        out.push(pa_alone("ring nodes alone", "ring nodes alone \{pa_box(b.0, b.1, b.2, b.3)} pieces \{b.4} alpha \{pa_r(b.5)}"))
      }
    }
  }
  // (how opaque each word and each picture is drawn: by pa_alpha_tol on the way, a hundredth at rest (and as what moves
  // is told apart from what stands); each word matched as its place is, nearest first)
  let (apairs, _, _) = pa_pairs(o.alphas, n.alphas)
  for p in apairs {
    let (a, b) = p
    if (a.3 - b.3).abs() > a_tol {
      out.push({
        key: "alpha 「\{a.0}」",
        line: "alpha 「\{a.0}」 old \{pa_r(a.3)} nodes \{pa_r(b.3)} at (\{pa_r(b.1)}, \{pa_r(b.2)})",
        dx: 0.0,
        dy: 0.0,
        dw: b.3 - a.3,
      })
    }
  }
  // (where the host's own views show through: as many, each where it is)
  if o.holes.length() != n.holes.length() {
    out.push(
      pa_alone(
        "holes",
        "holes old \{o.holes.map(fn(p) { pa_box(p.0, p.1, p.2, p.3) }).join(" ")} nodes \{n.holes.map(fn(p) { pa_box(p.0, p.1, p.2, p.3) }).join(" ")}",
      ),
    )
  } else {
    for i, a in o.holes {
      let b = n.holes[i]
      if (a.0 - b.0).abs() > tol || (a.1 - b.1).abs() > tol || (a.2 - b.2).abs() > tol || (a.3 - b.3).abs() > tol {
        out.push({
          key: "hole \{i}",
          line: "hole \{i} old \{pa_box(a.0, a.1, a.2, a.3)} nodes \{pa_box(b.0, b.1, b.2, b.3)}",
          dx: b.0 - a.0,
          dy: b.1 - a.1,
          dw: (b.2 - a.2).abs().max((b.3 - a.3).abs()),
        })
      }
    }
  }
  // (the round buttons: those of one name matched nearest first by their middles (the rail and the round button of
  // 对话目录 both so named), held by their middles; one side's alone said)
  let mid = fn(f : (String, Double, Double, Double, Double)) { (f.1 + f.3 / 2.0, f.2 + f.4 / 2.0) }
  for name in pa_float_names() {
    let fo = o.floats.filter(fn(f) { f.0 == name })
    let fnn = n.floats.filter(fn(f) { f.0 == name })
    let (ps, oo, on) = pa_nearest(fo, fnn, mid)
    for p in ps {
      let (a, b) = p
      let (ax, ay) = mid(a)
      let (bx, by) = mid(b)
      if (ax - bx).abs() > tol || (ay - by).abs() > tol {
        out.push({
          key: "button \{name}",
          line: "button 「\{name}」 old \{pa_box(a.1, a.2, a.3, a.4)} nodes \{pa_box(b.1, b.2, b.3, b.4)}",
          dx: bx - ax,
          dy: by - ay,
          dw: 0.0,
        })
      }
    }
    for a in oo {
      out.push(pa_alone("button \{name} old alone", "button 「\{name}」 old alone \{pa_box(a.1, a.2, a.3, a.4)}"))
    }
    for b in on {
      out.push(pa_alone("button \{name} nodes alone", "button 「\{name}」 nodes alone \{pa_box(b.1, b.2, b.3, b.4)}"))
    }
  }
  out
}

///|
/// How far apart two frames on their way may be (their moments the same): a way's own frame, both drawn at 60.
let pa_way_tol : Double = 6.0

///|
/// How far apart in how opaque two words or pictures may be drawn on the way (both drawn at 60, their fades on curves
/// of their own a frame apart at most).
let pa_alpha_tol : Double = 0.15

///|
/// How far apart the frames at rest at the end may be.
let pa_rest_tol : Double = 1.5

///|
/// Whether frame `f` draws what frame `g` drew where it drew it (each word, picture, the composer and the round buttons
/// within a quarter of a point): nothing of it moving between them.
fn pa_still(f : PaFrame, g : PaFrame) -> Bool {
  pa_diff(f, g, 0.25, rings=false).is_empty()
}

///|
/// How many frames on end each side of a drive must have drawn the same for the frame to be one at rest (a wait's end,
/// all of its ways over): a fifth of a second.
let pa_still_frames : Int = 12

///|
/// The one-frame steps in `frames` (one side's run): a word, the composer or a round button that moved and came back
/// the next frame (a frame drawn where all goes, then where it was: what a change set out late shows), one line each.
fn pa_spikes(frames : Array[PaFrame]) -> Array[String] {
  let out = []
  for i in 1..<(frames.length() - 1) {
    let (a, b, c) = (frames[i - 1], frames[i], frames[i + 1])
    // (words drawn once in each frame alone: a word drawn several times is not told apart frame to frame)
    let ys = fn(f : PaFrame) -> Map[String, Double] {
      let m : Map[String, Double] = Map([])
      let twice : Map[String, Bool] = Map([])
      for w in f.words {
        if m.contains(w.0) {
          twice[w.0] = true
        } else {
          m[w.0] = w.2
        }
      }
      for k, _ in twice {
        m.remove(k)
      }
      match f.composer {
        Some(cb) => m["(composer)"] = cb.1
        None => ()
      }
      m
    }
    let (ya, yb, yc) = (ys(a), ys(b), ys(c))
    for k, y1 in yb {
      match (ya.get(k), yc.get(k)) {
        (Some(y0), Some(y2)) =>
          if (y1 - y0).abs() > 6.0 && (y2 - y0).abs() < 1.5 && (y2 - y1).abs() > 6.0 {
            out.push("「\{k}」 \{y0} → \{y1} → \{y2} @\{b.at.round()}ms")
          }
        _ => ()
      }
    }
  }
  out
}

///|
/// What is known to differ at rest, by drive, each said with why: the bell to what waits to be decided shown while a
/// card waiting lies under the chat's bar, which the old list counted in sight (its ListInfo's first row is under the
/// bar; the page as nodes holds what the bar covers out: `top_covered`), the new page's mend; the letter of a row's
/// picture the old list draws under the chat's bar (at -2, the bar over it), what the bar covers being the bar's as
/// nodes; the time under one's words the old page shows in the frame the station takes them, as nodes seen once its
/// room holds it whole as what was under them leaves (msg_part_leave_ms), so a frame at rest on both sides before it
/// comes (pa_why_working, pa_why_timein); a picture held to quote it (pa_why_lift); the line of a file picked in a vault's
/// card, the tree's words as wide as the row they fill, the old's as wide as they are; a video's length the old page
/// still draws at the foot after its viewer shut (pa_why_old_capsule).
let pa_known : Array[(String, String)] = [
  ("chat-uploading-files", "button @asks.go nodes alone"),
  ("send-quote-picture", "button @asks.go nodes alone"),
  ("desk-panel-picture-quote", "button @asks.go nodes alone"),
  ("viewer-video", "button @asks.go nodes alone"),
  // (an agent's line gone, the old page goes on drawing its ring where the line was: chat_rows' work_ring is drawn in a
  // layer of its own, which the face's fading (`copied`, `leaving`) does not reach; as nodes the ring is the face's,
  // gone with the line)
  ("desk-send-text-and-multiline", "ring old alone"),
  ("desk-notice-card-viewer", "ring old alone"),
  ("scrolled-reply", "ring old alone"),
  ("send-long", "ring old alone"),
  // (a picture held up for its menu: the composer's placeholder as nodes, under the menu's sheet, is read as seen by
  // Tester::glyphs_seen though no frame of the film shows it over the sheet (picture-lift-both-27b594a3b5.mp4 at 5.5 s);
  // the old page builds no composer under the sheet. What the glyphs' reading takes for seen here is not run down yet)
  ("send-quote-picture", "nodes alone 「发消息」"),
  ("picture-lift", "nodes alone 「发消息」"),
  // (a picture held up for its menu, its menu one line shorter since the menus drop a line where a choice is not offered
  // (menu_clean_items, message_files' file_options, 2026-11-16): the old page, kept clear of the sheet as laid out (sf's
  // lift_over), stands 4 lower, its message's last line 对比图… seen over the picture's top as the menu is up and after; as
  // nodes kept clear as drawn grown, that line under the scrim's top)
  ("send-quote-picture", "old alone 「对比图和构建日志附在下面。」"),
  ("picture-lift", "old alone 「对比图和构建日志附在下面。」"),
  // (a message's menu up over the composer, its words' field had the cursor: the menu made as nodes keeps that cursor
  // for it to give back as it goes (Field::parked, View::layer_focus), so the composer made as nodes stays the box it
  // was, its placeholder away, as the old composer does while parked (composer_box's lost_long, never while parked);
  // the old page's menu keeps none, the old composer not parked, its placeholder 发消息 drawn under the menu till the
  // cursor comes back)
  ("send-quote-video", "old alone 「发消息」"),
  // (the new chat's scene centred in the pane's column on both, the same glyphs: the old page's words drawn from the
  // column's start, as nodes from the start of the scene's own box: pa_why_newchat_scene)
  ("wide-newchat", "old alone 「想让 agent 做什么？」"),
  ("wide-newchat", "old alone 「描述要做的事。它会在 Willow 上使用所选模型新建会话。」"),
  ("wide-newchat", "nodes alone 「想让 agent 做什么？」"),
  ("wide-newchat", "nodes alone 「描述要做的事。它会在 Willow 上使用所选模型新建会话。」"),
]

///|
/// What is known to differ at rest by no more than so much each way (drive, key, dx, dy, dw, why): a picture held up for
/// its menu kept clear of the sheet by lift_clear as it is drawn, grown (View::over_scrim, ui's tree_over_scrim_clear);
/// the old page keeps its box as laid out that far clear and grows it after (sf's lift_over), its foot 3.8 points lower.
let pa_rest_off_known : Array[(String, String, Double, Double, Double, String)] = [
  ("picture-lift", "picture", 0.5, 4.5, 0.5, "held up: kept clear of the sheet as drawn grown (nodes) or as laid out (old)"),
  ("send-quote-picture", "picture", 0.5, 4.5, 0.5, "held up: kept clear of the sheet as drawn grown (nodes) or as laid out (old)"),
]

///|
/// Frames at rest on both sides known to differ whole, by drive and moments, each with why: as the second words sent
/// while the agent is at work on the first are taken, the old page lets its agent's line go (the first's answer come)
/// though it is at work on them still, its rows down by that line till their answer floats out; as nodes the line stays
/// while the agent works on any of them (chat_body_node's ChatTurnsOut: its line out with the answer to its last turn).
let pa_rest_known : Array[(String, Double, Double, String)] = [
  ("send-over-line", 3700.0, 5100.0, "the agent's line kept while it works on the second words as nodes; the old page's let go as the first's answer came"),
]

///|
/// Whether what differs by `key` in drive `name` is known (pa_known).
fn pa_is_known(name : String, key : String) -> Bool {
  pa_known.iter().any(fn(k) { k.0 == name && key == k.1.replace(old="@asks.go", new=@sf.t("web-main.chat.asks.go")) })
}

///|
/// A stretch of frames on end one thing differed on the way (pa_compare's): from, to, how many, the most each way
/// (dx, dy, dw by size, their sign kept), and its first frame's line.
struct PaStretch {
  from : Double
  mut to : Double
  mut frames : Int
  mut dx : Double
  mut dy : Double
  mut dw : Double
  first : String
}

///|
/// `e` at moment `at` put in `l`, the stretches of one thing: the last one gone on where `at` is within 50 ms of its end.
fn pa_stretch_add(l : Array[PaStretch], e : PaDiff, at : Double) -> Unit {
  let more = fn(a : Double, b : Double) { if b.abs() > a.abs() { b } else { a } }
  match l.last() {
    Some(st) if at - st.to <= 50.0 => {
      st.to = at
      st.frames += 1
      st.dx = more(st.dx, e.dx)
      st.dy = more(st.dy, e.dy)
      st.dw = more(st.dw, e.dw)
    }
    _ => l.push({ from: at, to: at, frames: 1, dx: e.dx, dy: e.dy, dw: e.dw, first: e.line })
  }
}

///|
/// A number to a tenth, for a person.
fn pa_r(v : Double) -> String {
  if v.abs() >= 1.0e8 {
    "-"
  } else {
    ((v * 10.0).round() / 10.0).to_string()
  }
}

///|
/// What one row of pa_way_known lets pass: one thing by its key (a word by its words, a word one side alone draws, the
/// composer, a picture, a round button: PaDiff's key), off by `most` at most each way (one side's alone, by
/// pa_alone_any); or the list's rows (`Rows`): any word drawn as wide and as far across as the old has it, off down by
/// `most` at most, the list's way on one side ahead of the other's.
enum PaWhat {
  Key(String)
  Rows
}

///|
/// What a row lets pass, for a person.
fn pa_what_text(w : PaWhat) -> String {
  match w {
    Key(k) => k
    Rows => "the list's rows"
  }
}

///|
/// What a row of pa_way_known lets pass of one side's alone (what has no number).
let pa_alone_any : Double = 1.0e9

///|
/// One difference known on the way, in drive `drive` from `from` to `to` ms (its frames' moments): what (`what`) and by
/// how much at most each way, apart (`dx` across, `dy` down, `dw` in size or how opaque: an axis it does not name held
/// to pa_way_tol), and why: the cause in the code, each page's own way.
struct PaWay {
  drive : String
  what : PaWhat
  from : Double
  to : Double
  dx : Double
  dy : Double
  dw : Double
  why : String
}

///|
/// The row of pa_way_known that lets `e` pass in drive `name` at moment `at`, if any.
fn pa_way_row(name : String, e : PaDiff, at : Double) -> Int? {
  for r, row in pa_way_known {
    guard row.drive == name && at >= row.from - 0.5 && at <= row.to + 0.5 else { continue }
    let ok = match row.what {
      Key(k) =>
        k.replace(old="@asks.go", new=@sf.t("web-main.chat.asks.go")).replace(
          old="@outline",
          new=@sf.t("web-main.outline.title"),
        ) ==
        e.key &&
        e.dx.abs() <= row.dx.max(pa_way_tol) &&
        e.dy.abs() <= row.dy.max(pa_way_tol) &&
        e.dw.abs() <= row.dw.max(pa_way_tol)
      Rows =>
        e.key.has_prefix("words ") && e.dx.abs() <= pa_way_tol && e.dw.abs() <= pa_way_tol && e.dy.abs() <= row.dy
    }
    if ok {
      return Some(r)
    }
  }
  None
}

///|
/// Words sent set out in the press's frame as nodes (the composer's sent_out, the list's change at the cause, the words
/// flying from the field: View::shared); the old page sets them out a frame later, measured, and keeps the composer's
/// ground as it was sent_out_hold_ms (its flight_lets_go, about 170 ms): the list's rows, the composer's box, the rail of
/// 对话目录 over it, what flies and the rows coming in or going out at the list's top go each its own phase till both
/// rest where the other does.
let pa_why_send : String = "words sent: set out in the press's frame as nodes; the old page a frame later, its composer's ground held sent_out_hold_ms"

///|
let pa_why_working : String = "the agent's 处理中 line and the time under one's words: as nodes a pick, what leaves fading where it is and what comes seen once its room holds it whole (msg_part_leave_ms), its room on the list's way; the old page swaps them in one frame"

///|
let pa_why_spit : String = "the answer's words as they are spat out, from their first glyph out (none of them drawn before): the old page draws what is out so far as words of their own, so its whole line is no old word till all of it is out; as nodes the line is one, revealed glyph by glyph"

///|
let pa_why_float : String = "the answer's head line (Claude, its time) as the agent's picture sets out (Float): as nodes laid out where it rests from that frame; the old page's a frame later, from beside the picture"

///|
let pa_why_panel_first : String = "the side panel set off and come to rest: as nodes the column laid out at the narrower end from the cause's frame (column_laid, column_sets_off) and its words moved across with the page; the old page takes the width a frame later (page_way, its laid_w)"

///|
let pa_why_panel_mine : String = "words at the column's right and middle on the side panel's way (one's own, a notice's pill, their time): as nodes going with the edge and the middle drawn (chat_body_node's KMine by - 2·across, KNotice by/2 - across); the old list_shift steps them to where they go in its first frame (181 pt, 90 pt)"

///|
let pa_why_room_way : String = "the composer's room under it going where the page goes from the frame the side panel sets off, on both pages (composer_foot_in, the user 2026-11-17: 「很 q 弹的垃圾」), no more held at the narrower end to go on by itself once the page is there: the rows over it go up with it as the panel closes, the old page's on the old list's way and the page made as nodes' on its own, so what crosses the bar's edge then crosses it a frame apart, and the panel's switch's tip under the still pointer comes as the page made as nodes is at rest, a frame before the old page's way ends"

///|
let pa_why_tip : String = "the panel's switch under the still pointer after its press: as nodes the bar's switch is a node whose tip comes up under the hand (the library's tip); the old bar shows none after a press"

///|
let pa_why_card : String = "a decision card answered: as nodes the answer comes into the list in the press's frame and the card's 忽略 and choices fade by pick(leave=…) as its room closes on the list's way; the old page closes it in its own Changed frame"

///|
let pa_why_island : String = "the frame words are sent in: as nodes the composer is an old view in the list's foot, built again only in the next frame, so that frame still draws its words under their flight, set out from the very place (its files' tiles and quotes' cards not drawn that frame: composer's sent_gone_now); the old page builds it at once, its flight a frame later"

///|
let pa_why_bell : String = "the bell to what waits to be decided: as nodes shown by what the list has in sight where the cause leaves it (ListPlace::on_sight: never a frame on its way, list_sight.mbt), so as the card is sent off the screen; the old page by the frame it draws, once the card has slid under the bar"

///|
let pa_why_wheel : String = "a wheel's notch: the old list moves the notch's whole in that frame; as nodes the notch eases from its frame, the rows and the round buttons a frame or two apart, both at rest where the other is"

///|
let pa_why_viewer : String = "a picture opened in the viewer and shut: as nodes View::shared's flight and what is drawn under the viewer's ground as it comes and goes; the old page's own curve"

///|
let pa_why_menu : String = "the menu over words picked (引用 复制 全选): the old popover and the tree's come and go each on its own fade"

///|
let pa_why_lines : String = "a line typed more: as nodes the list goes with the composer's ground from the frame it grows (foot_resizes); the old page a frame later"

///|
let pa_why_newchat : String = "a new chat becoming its chat: as nodes its scene kept on one node while it fades over new_leave_ms and its first words set out after fresh's fly_after on sent_flight (distance-scaled); the old page carries them on its fixed-length flight"

///|
let pa_why_newchat_scene : String = "the new chat's scene, centred in the pane's column on both pages, the same glyphs where they show: the old page's words drawn from the column's start, its centred words' box as wide as the column; as nodes from the start of the scene's own box, as wide as what it holds, centred in the column"

///|
let pa_why_newchat_nodes : String = "the new chat made as nodes with its composer (new_chat_node): its composer there and its placeholder drawn in the frame the page comes, the old a frame later; opened in the press's frame, its choices over it drawn with its ground's top on its own way, the old page's a frame later; become its chat, its composer away at once and the chat's own at rest under it (in place, narrow) or flown from where the new chat's stood (wide: fresh_composer_at, from its box after the words' flight, fresh_fly_after), as a chat's composer made as nodes lets go at once of what it held as what was in it flies from where it stood (SentFrom, View::flies_in), a picture sent alone too; the old page's held as tall as it was for sent_out_hold_ms and the chat's at its foot at once"

///|
let pa_why_read : String = "the list scrolled a little up while the agent answers: what is read held where it shows on both, what comes and goes under it on each page's own way (the list's read_from as nodes, the old list's anchor)"

///|
let pa_why_timein : String = "the time under one's words: as nodes seen from their landing over enter_ms (message_words_node's landed, as asked: never while they fly); the old page's comes in as the flight settles (flight_settled, along the way across)"

///|
let pa_why_lift : String = "a picture held to quote it: its lift (the picture's own, track B's) drawn as each page draws it"

///|
let pa_why_quote_flight : String = "a quote sent with its own picture: as nodes its card flies from where it stood in the composer at its own width, from the height it stood at there to its own, and its picture from its 56 square in it (View::flies_in, sent_part_flight: the words' flight), the old flight on its own curves and a frame later; the old page holds the composer's box as tall as the card till they let go, as nodes laid out at its line at once under its ground held (sent_out_hold_ms); the video's length seen as it lands (message_video_node's marks)"

///|
/// An agent's line gone, the old page goes on drawing its ring where the line was for as long as its ring's layer is
/// drawn (chat_rows' work_ring in a layer of its own, which the face's fading does not reach); as nodes the ring is the
/// face's, gone with the line.
let pa_why_old_ring : String = "an agent's line gone: the old page's ring left drawn where it was (its own layer); as nodes gone with its face"

///|
/// Why the chat's composer made as nodes (sfpages composer_node) moves otherwise than the old page's old view,
/// by its way and not by what it comes to: opened from a capsule or let go to one, laid out as the box or the capsule in
/// the change that does it, drawn from the shape it had (its ground_drawn and its parts' offset, composer_shape_ms), the
/// old page's measured a frame later; a line more, a quote or a file put in or taken out, its height on its way
/// (View::resizes) with the list over it on its column's one way, the old page's measured where it goes at once and its
/// list on the old composer's own curve; words sent, laid out at its one line at once under its ground held as tall as
/// it was (sent_out_hold_ms), the row sent taking the room it gives back (composer_sent_nodes_wbtest), the old page
/// holding its box as tall till they let go; the side panel's way, its foot's room declared as the column sets off,
/// on the page's way (@motion.moved()) with the rows over it, the old page on its own (composer_foot_in); its placeholder by those
/// shapes and the rows a chat's first frame lays out over its foot as made, each where its own page has them then.
let pa_why_composer_way : String = "the chat's composer made as nodes: opened and let go laid out at once and drawn from the shape it had, a line more or what waits put in or taken out on its way (View::resizes) with the list over it, words sent laid out at one line under its ground held, the side panel's room on the page's way; the old page's old view measured where it goes a frame later, its list on its own curve"

///|
let pa_why_float_frame : String = "the round buttons over the list's foot (跳到最新, 对话目录, the way to what waits on a decision): as nodes shown in the frame the list leaves its foot, at once (their foot's show); the old page's built a frame later"

///|
let pa_why_side_switch : String = "the side panel's switch in the chat's bar as nodes going along the row as the panel opens or shuts (View::show's along_row, its room with the panel's way from that cause), the tip over it and 详情 there from its frame; the old bar swaps it a frame or two later"

///|
/// What differs on the way past pa_way_tol, known, each row's cause said (pa_compare fails on any other, and on a row
/// that lets nothing pass): each by its drive, its moments (a frame either side of what was seen) and how far at most.
let pa_way_known : Array[PaWay] = [

  { drive: "desk-right-panel-toggle", what: Key("composer"), from: 617.0, to: 833.0, dx: 40.2, dy: 8.1, dw: 80.3, why: pa_why_composer_way },
  { drive: "desk-right-panel-toggle", what: Key("words 「先不换」"), from: 5350.0, to: 5350.0, dx: 0.7, dy: 8.0, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-right-panel-toggle", what: Key("words 「一起换」"), from: 5350.0, to: 5567.0, dx: 0.7, dy: 8.2, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-right-panel-toggle", what: Key("words 「把首页和聊天页的截图都更新」"), from: 5350.0, to: 5567.0, dx: 0.7, dy: 8.2, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-right-panel-toggle", what: Key("words 「忽略」"), from: 5350.0, to: 5567.0, dx: 0.7, dy: 8.2, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-right-panel-toggle", what: Key("ground"), from: 683.0, to: 700.0, dx: 2.9, dy: 8.2, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-right-panel-toggle", what: Key("words 「面板开着也发一条」"), from: 5383.0, to: 5567.0, dx: 12.7, dy: 8.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-right-panel-toggle", what: Key("words 「刚刚」"), from: 5383.0, to: 5567.0, dx: 12.7, dy: 8.1, dw: 1.2, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("composer"), from: 1150.0, to: 1250.0, dx: 0.1, dy: 60.1, dw: 60.2, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("composer"), from: 4800.0, to: 4900.0, dx: 0.1, dy: 60.6, dw: 60.2, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「Claude」"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「Claude」"), from: 4783.0, to: 5000.0, dx: 0.1, dy: 66.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「5 分钟前」"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「5 分钟前」"), from: 4800.0, to: 5000.0, dx: 0.1, dy: 66.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 4800.0, to: 5000.0, dx: 0.1, dy: 66.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「15 分钟前」"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「15 分钟前」"), from: 4783.0, to: 5000.0, dx: 0.1, dy: 66.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「推送截图前要先登录 gh。」"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「推送截图前要先登录 gh。」"), from: 4783.0, to: 5000.0, dx: 0.1, dy: 66.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「在 Willow 上登录 gh」"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「在 Willow 上登录 gh」"), from: 4800.0, to: 5000.0, dx: 0.1, dy: 66.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「等你在浏览器里登录」"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「等你在浏览器里登录」"), from: 4783.0, to: 5000.0, dx: 0.1, dy: 66.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 4800.0, to: 5000.0, dx: 0.1, dy: 66.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「30 分钟前」"), from: 1167.0, to: 1183.0, dx: 0.1, dy: 20.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「30 分钟前」"), from: 4900.0, to: 5000.0, dx: 0.1, dy: 29.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 1167.0, to: 1250.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 4833.0, to: 5000.0, dx: 0.1, dy: 58.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「等 林 决定」"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「等 林 决定」"), from: 4783.0, to: 5000.0, dx: 0.1, dy: 66.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「先不换」"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「先不换」"), from: 4783.0, to: 5000.0, dx: 0.1, dy: 66.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「这次只改列表，截图下次再说」"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「这次只改列表，截图下次再说」"), from: 4800.0, to: 5000.0, dx: 0.1, dy: 66.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「一起换」"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「一起换」"), from: 4800.0, to: 5000.0, dx: 0.1, dy: 66.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「把首页和聊天页的截图都更新」"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「把首页和聊天页的截图都更新」"), from: 4800.0, to: 5000.0, dx: 0.1, dy: 66.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「忽略」"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「忽略」"), from: 4800.0, to: 5000.0, dx: 0.1, dy: 66.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("ground"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("ground"), from: 3583.0, to: 3700.0, dx: 67.1, dy: 0.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("ground"), from: 4800.0, to: 5000.0, dx: 0.1, dy: 66.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("button 对话目录"), from: 1167.0, to: 1300.0, dx: 0.1, dy: 12.0, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("button 对话目录"), from: 4783.0, to: 4967.0, dx: 0.1, dy: 33.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("picture nodes alone"), from: 1183.0, to: 1200.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("old alone 「Claude」"), from: 1200.0, to: 1217.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("old alone 「Claude」"), from: 4817.0, to: 4833.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("old alone 「30 分钟前」"), from: 1200.0, to: 1233.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("picture"), from: 1217.0, to: 1350.0, dx: 19.9, dy: 29.8, dw: 36.4, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("nodes alone 「Claude」"), from: 1250.0, to: 1283.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("nodes alone 「Claude」"), from: 4867.0, to: 4883.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 1267.0, to: 1350.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("nodes alone 「构建日志」"), from: 2367.0, to: 2367.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("nodes alone 「.log」"), from: 2367.0, to: 2367.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("nodes alone 「2 KB」"), from: 2367.0, to: 2367.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("ground alpha"), from: 2383.0, to: 2433.0, dx: 0.1, dy: 0.1, dw: 0.2, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("alpha 「构建日志」"), from: 2383.0, to: 2417.0, dx: 0.1, dy: 0.1, dw: 0.8, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("alpha 「.log」"), from: 2383.0, to: 2417.0, dx: 0.1, dy: 0.1, dw: 0.8, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("alpha 「2 KB」"), from: 2383.0, to: 2417.0, dx: 0.1, dy: 0.1, dw: 0.8, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「.log」"), from: 3567.0, to: 3717.0, dx: 67.2, dy: 0.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「2 KB」"), from: 3567.0, to: 3717.0, dx: 67.2, dy: 0.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("words 「构建日志」"), from: 3583.0, to: 3717.0, dx: 67.2, dy: 0.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("nodes alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 4783.0, to: 4817.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("nodes alone 「30 分钟前」"), from: 4800.0, to: 4883.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("composer"), from: 1150.0, to: 1250.0, dx: 0.1, dy: 60.1, dw: 60.2, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("composer"), from: 3583.0, to: 3583.0, dx: 0.1, dy: 66.1, dw: 66.1, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("words 「Claude」"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("words 「5 分钟前」"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("words 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("words 「15 分钟前」"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("words 「推送截图前要先登录 gh。」"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("words 「在 Willow 上登录 gh」"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("words 「等你在浏览器里登录」"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("words 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("words 「30 分钟前」"), from: 1167.0, to: 1183.0, dx: 0.1, dy: 20.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("words 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 1167.0, to: 1250.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("words 「等 林 决定」"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("words 「先不换」"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("words 「这次只改列表，截图下次再说」"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("words 「一起换」"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("words 「把首页和聊天页的截图都更新」"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("words 「忽略」"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("ground"), from: 1167.0, to: 1350.0, dx: 0.1, dy: 23.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("button 对话目录"), from: 1167.0, to: 1300.0, dx: 0.1, dy: 12.0, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("picture nodes alone"), from: 1183.0, to: 1200.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("old alone 「Claude」"), from: 1200.0, to: 1217.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("old alone 「30 分钟前」"), from: 1200.0, to: 1233.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("picture"), from: 1217.0, to: 1350.0, dx: 19.9, dy: 29.8, dw: 36.4, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("nodes alone 「Claude」"), from: 1250.0, to: 1283.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 1267.0, to: 1350.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("nodes alone 「构建日志」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("nodes alone 「.log」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("nodes alone 「2 KB」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("ground alpha"), from: 2083.0, to: 2133.0, dx: 0.1, dy: 0.1, dw: 0.2, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("alpha 「构建日志」"), from: 2083.0, to: 2117.0, dx: 0.1, dy: 0.1, dw: 0.8, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("alpha 「.log」"), from: 2083.0, to: 2117.0, dx: 0.1, dy: 0.1, dw: 0.8, why: pa_why_composer_way },
  { drive: "desk-send-picture-and-file", what: Key("alpha 「2 KB」"), from: 2083.0, to: 2117.0, dx: 0.1, dy: 0.1, dw: 0.8, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("words 「Claude」"), from: 1450.0, to: 1650.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("words 「5 分钟前」"), from: 1450.0, to: 1650.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("words 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 1450.0, to: 1650.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("words 「15 分钟前」"), from: 1450.0, to: 1650.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("words 「推送截图前要先登录 gh。」"), from: 1450.0, to: 1650.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("words 「在 Willow 上登录 gh」"), from: 1450.0, to: 1650.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("words 「等你在浏览器里登录」"), from: 1450.0, to: 1650.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("words 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 1450.0, to: 1650.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("words 「30 分钟前」"), from: 1450.0, to: 1483.0, dx: 0.1, dy: 22.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("words 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 1450.0, to: 1533.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("words 「等 林 决定」"), from: 1450.0, to: 1650.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("words 「先不换」"), from: 1450.0, to: 1650.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("words 「这次只改列表，截图下次再说」"), from: 1450.0, to: 1650.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("words 「一起换」"), from: 1450.0, to: 1650.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("words 「把首页和聊天页的截图都更新」"), from: 1450.0, to: 1650.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("words 「忽略」"), from: 1450.0, to: 1650.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("composer"), from: 1450.0, to: 1567.0, dx: 0.1, dy: 63.6, dw: 63.9, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("composer"), from: 2683.0, to: 2683.0, dx: 0.1, dy: 70.1, dw: 70.1, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("ground"), from: 1450.0, to: 1783.0, dx: 214.9, dy: 29.8, dw: 426.9, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("ground"), from: 2917.0, to: 2917.0, dx: 276.7, dy: 44.6, dw: 455.9, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("button 对话目录"), from: 1467.0, to: 1600.0, dx: 0.1, dy: 12.8, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("nodes alone 「添加说明（可选）」"), from: 1483.0, to: 1600.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("ground nodes alone"), from: 1483.0, to: 1517.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("old alone 「Claude」"), from: 1500.0, to: 1500.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("old alone 「30 分钟前」"), from: 1500.0, to: 1517.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("nodes alone 「Claude：先登录 gh。」"), from: 1500.0, to: 1567.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 1550.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("nodes alone 「Claude」"), from: 1550.0, to: 1567.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("words 「Claude：先登录 gh。」"), from: 1583.0, to: 1667.0, dx: 0.1, dy: 20.7, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("words 「Claude：先登录 gh。」"), from: 2733.0, to: 2733.0, dx: 6.4, dy: 0.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("words 「Claude：先登录 gh。」"), from: 2833.0, to: 2833.0, dx: 89.4, dy: 7.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("words 「添加说明（可选）」"), from: 1617.0, to: 1667.0, dx: 0.1, dy: 13.0, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("nodes alone 「发消息」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("words 「这一步写进文档」"), from: 2733.0, to: 2733.0, dx: 6.4, dy: 0.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-wide", what: Key("words 「这一步写进文档」"), from: 2833.0, to: 2833.0, dx: 89.4, dy: 7.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-send-text-and-multiline", what: Key("composer"), from: 4217.0, to: 4367.0, dx: 0.1, dy: 37.1, dw: 37.1, why: pa_why_composer_way },
  { drive: "desk-send-text-and-multiline", what: Key("composer"), from: 4967.0, to: 4967.0, dx: 0.1, dy: 44.1, dw: 44.1, why: pa_why_composer_way },
  { drive: "desk-send-text-and-multiline", what: Key("words 「发消息」"), from: 4967.0, to: 5183.0, dx: 0.2, dy: 44.2, dw: 0.2, why: pa_why_composer_way },
  { drive: "desk-send-text-and-multiline", what: Key("old alone 「忽略」"), from: 4967.0, to: 5200.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-send-text-and-multiline", what: Key("old alone 「忽略」"), from: 5267.0, to: 5267.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-notice-card-viewer", what: Key("words 「Claude」"), from: 3333.0, to: 3333.0, dx: 0.1, dy: 46.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「Claude」"), from: 3333.0, to: 3333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「刚刚」"), from: 3333.0, to: 3333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「好，按「一起换」来。」"), from: 3333.0, to: 3333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「一起换」"), from: 3333.0, to: 3333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「5 分钟前」"), from: 3333.0, to: 3333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 3333.0, to: 3333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「15 分钟前」"), from: 3333.0, to: 3333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「推送截图前要先登录 gh。」"), from: 3333.0, to: 3333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「在 Willow 上登录 gh」"), from: 3333.0, to: 3333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「等你在浏览器里登录」"), from: 3333.0, to: 3333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 3333.0, to: 3333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「30 分钟前」"), from: 3333.0, to: 3333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 3333.0, to: 3333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-notice-card-viewer", what: Key("nodes alone 「在 Willow 上登录 gh」"), from: 3333.0, to: 3333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-notice-card-viewer", what: Key("nodes alone 「你 选择了「一起换」」"), from: 3333.0, to: 3333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-notice-card-viewer", what: Key("nodes alone 「发送到」"), from: 3333.0, to: 3333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send", what: Key("composer"), from: 683.0, to: 683.0, dx: 0.1, dy: 43.1, dw: 42.9, why: pa_why_composer_way },
  { drive: "send-lines", what: Key("old alone 「发消息」"), from: 2167.0, to: 2200.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-lines", what: Key("composer"), from: 683.0, to: 683.0, dx: 0.1, dy: 43.1, dw: 42.9, why: pa_why_composer_way },
  { drive: "send-lines", what: Key("composer"), from: 1233.0, to: 1383.0, dx: 0.1, dy: 41.4, dw: 41.8, why: pa_why_composer_way },
  { drive: "send-lines", what: Key("composer"), from: 1983.0, to: 1983.0, dx: 0.1, dy: 49.4, dw: 49.6, why: pa_why_composer_way },
  { drive: "send-lines", what: Key("words 「发消息」"), from: 1983.0, to: 2150.0, dx: 0.1, dy: 49.4, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-picture", what: Key("old alone 「发消息」"), from: 1517.0, to: 1667.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-picture", what: Key("composer"), from: 1517.0, to: 1517.0, dx: 0.1, dy: 108.6, dw: 108.9, why: pa_why_composer_way },
  { drive: "send-quote", what: Key("composer"), from: 1783.0, to: 1950.0, dx: 0.1, dy: 107.2, dw: 107.4, why: pa_why_composer_way },
  { drive: "send-quote", what: Key("composer"), from: 3000.0, to: 3000.0, dx: 0.1, dy: 71.9, dw: 72.1, why: pa_why_composer_way },
  { drive: "send-quote", what: Key("nodes alone 「添加说明（可选）」"), from: 1850.0, to: 1883.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote", what: Key("ground"), from: 1850.0, to: 2000.0, dx: 92.4, dy: 20.8, dw: 182.0, why: pa_why_composer_way },
  { drive: "send-quote", what: Key("ground"), from: 3200.0, to: 3200.0, dx: 28.5, dy: 11.7, dw: 131.2, why: pa_why_composer_way },
  { drive: "send-quote", what: Key("words 「Claude：先」"), from: 1883.0, to: 1967.0, dx: 0.1, dy: 34.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote", what: Key("words 「Claude：先」"), from: 3117.0, to: 3117.0, dx: 7.6, dy: 2.0, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote", what: Key("words 「Claude：先」"), from: 3200.0, to: 3200.0, dx: 27.3, dy: 12.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote", what: Key("words 「添加说明（可选）」"), from: 1933.0, to: 1967.0, dx: 0.1, dy: 13.3, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote", what: Key("nodes alone 「发消息」"), from: 2083.0, to: 2083.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote", what: Key("words 「这一步写进文档」"), from: 3117.0, to: 3117.0, dx: 7.6, dy: 2.0, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote", what: Key("words 「这一步写进文档」"), from: 3200.0, to: 3200.0, dx: 27.3, dy: 12.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "answer", what: Key("composer"), from: 683.0, to: 683.0, dx: 0.1, dy: 43.1, dw: 42.9, why: pa_why_composer_way },
  { drive: "wide-newchat", what: Key("composer"), from: 617.0, to: 617.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-newchat", what: Key("composer"), from: 2750.0, to: 2883.0, dx: 42.1, dy: 212.1, dw: 84.1, why: pa_why_newchat_nodes },
  { drive: "wide-newchat", what: Key("old alone 「想让 agent 做什么？」"), from: 633.0, to: 2733.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat_scene },
  { drive: "wide-newchat", what: Key("nodes alone 「想让 agent 做什么？」"), from: 633.0, to: 2883.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat_scene },
  { drive: "wide-newchat", what: Key("old alone 「描述要做的事。它会在 Willow 上使用所选模型新建会话。」"), from: 633.0, to: 2733.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat_scene },
  { drive: "wide-newchat", what: Key("nodes alone 「描述要做的事。它会在 Willow 上使用所选模型新建会话。」"), from: 633.0, to: 2883.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat_scene },
  { drive: "wide-newchat", what: Key("nodes alone 「做任何事」"), from: 617.0, to: 617.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat_nodes },
  { drive: "wide-newchat", what: Key("words 「发消息」"), from: 2767.0, to: 2867.0, dx: 61.6, dy: 7.4, dw: 207.0, why: pa_why_newchat_nodes },
  { drive: "wide-newchat", what: Key("old alone 「预设」"), from: 633.0, to: 700.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-newchat", what: Key("old alone 「预设」"), from: 2767.0, to: 2817.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-newchat", what: Key("old alone 「Willow」"), from: 633.0, to: 700.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-newchat", what: Key("old alone 「Willow」"), from: 2767.0, to: 2817.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-newchat", what: Key("old alone 「Opus 5.5」"), from: 633.0, to: 700.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-newchat", what: Key("old alone 「Opus 5.5」"), from: 2767.0, to: 2817.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-newchat", what: Key("old alone 「·」"), from: 633.0, to: 717.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-newchat", what: Key("old alone 「·」"), from: 2767.0, to: 2817.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-newchat", what: Key("old alone 「高」"), from: 633.0, to: 700.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-newchat", what: Key("old alone 「高」"), from: 2767.0, to: 2817.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-newchat", what: Key("old alone 「自动分配」"), from: 633.0, to: 700.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-newchat", what: Key("old alone 「自动分配」"), from: 2767.0, to: 2817.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-newchat", what: Key("nodes alone 「预设」"), from: 633.0, to: 700.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-newchat", what: Key("nodes alone 「Willow」"), from: 633.0, to: 700.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-newchat", what: Key("nodes alone 「Opus 5.5」"), from: 633.0, to: 700.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-newchat", what: Key("nodes alone 「·」"), from: 633.0, to: 717.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-newchat", what: Key("nodes alone 「高」"), from: 633.0, to: 700.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-newchat", what: Key("nodes alone 「自动分配」"), from: 633.0, to: 700.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-newchat", what: Key("words 「·」"), from: 700.0, to: 833.0, dx: 13.8, dy: 107.8, dw: 0.1, why: pa_why_composer_way },
  { drive: "wide-newchat", what: Key("words 「预设」"), from: 717.0, to: 833.0, dx: 16.4, dy: 82.4, dw: 0.1, why: pa_why_composer_way },
  { drive: "wide-newchat", what: Key("words 「Willow」"), from: 717.0, to: 833.0, dx: 16.4, dy: 82.4, dw: 0.1, why: pa_why_composer_way },
  { drive: "wide-newchat", what: Key("words 「Opus 5.5」"), from: 717.0, to: 833.0, dx: 16.4, dy: 82.4, dw: 0.1, why: pa_why_composer_way },
  { drive: "wide-newchat", what: Key("words 「高」"), from: 717.0, to: 833.0, dx: 16.4, dy: 82.4, dw: 0.1, why: pa_why_composer_way },
  { drive: "wide-newchat", what: Key("words 「自动分配」"), from: 717.0, to: 833.0, dx: 16.4, dy: 82.4, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-newchat-picture", what: Key("composer"), from: 1517.0, to: 1617.0, dx: 0.1, dy: 108.9, dw: 108.9, why: pa_why_newchat_nodes },
  { drive: "send-newchat-picture", what: Key("old alone 「新对话」"), from: 1517.0, to: 1517.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat_nodes },
  { drive: "send-newchat-picture", what: Key("old alone 「取消」"), from: 1517.0, to: 1517.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat_nodes },
  { drive: "send-newchat-picture", what: Key("nodes alone 「新对话」"), from: 1517.0, to: 1517.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat_nodes },
  { drive: "send-newchat-picture", what: Key("nodes alone 「照着这张截图把第二屏改一下」"), from: 1517.0, to: 1517.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat_nodes },
  { drive: "send-newchat-picture", what: Key("composer"), from: 1633.0, to: 1650.0, dx: 0.1, dy: 42.8, dw: 42.9, why: pa_why_composer_way },
  { drive: "newchat-send", what: Key("nodes alone 「做任何事」"), from: 250.0, to: 250.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat_nodes },
  { drive: "newchat-send", what: Key("composer"), from: 1217.0, to: 1217.0, dx: 0.1, dy: 42.8, dw: 42.9, why: pa_why_newchat_nodes },
  { drive: "newchat-send", what: Key("words 「做任何事」"), from: 1217.0, to: 1217.0, dx: 29.1, dy: 40.5, dw: 66.1, why: pa_why_newchat_nodes },
  { drive: "newchat-send", what: Key("words 「预设」"), from: 1267.0, to: 1283.0, dx: 0.1, dy: 6.5, dw: 0.1, why: pa_why_newchat_nodes },
  { drive: "newchat-send", what: Key("words 「Willow」"), from: 1267.0, to: 1283.0, dx: 0.1, dy: 6.5, dw: 0.1, why: pa_why_newchat_nodes },
  { drive: "newchat-send", what: Key("words 「Opus 5.5」"), from: 1267.0, to: 1283.0, dx: 0.1, dy: 6.5, dw: 0.1, why: pa_why_newchat_nodes },
  { drive: "newchat-send", what: Key("words 「·」"), from: 1267.0, to: 1283.0, dx: 0.1, dy: 6.5, dw: 0.1, why: pa_why_newchat_nodes },
  { drive: "newchat-send", what: Key("words 「高」"), from: 1267.0, to: 1283.0, dx: 0.1, dy: 6.5, dw: 0.1, why: pa_why_newchat_nodes },
  { drive: "send-newchat-picture", what: Key("words 「发消息」"), from: 1533.0, to: 1667.0, dx: 29.1, dy: 40.2, dw: 66.1, why: pa_why_composer_way },
  { drive: "send-newchat-picture", what: Key("nodes alone 「发消息」"), from: 1683.0, to: 1783.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-lines-wide", what: Key("composer"), from: 1167.0, to: 1317.0, dx: 0.1, dy: 37.1, dw: 37.1, why: pa_why_composer_way },
  { drive: "send-lines-wide", what: Key("composer"), from: 1917.0, to: 1917.0, dx: 0.1, dy: 44.1, dw: 44.1, why: pa_why_composer_way },
  { drive: "send-lines-wide", what: Key("nodes alone 「Claude」"), from: 1283.0, to: 1283.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-lines-wide", what: Key("words 「发消息」"), from: 1917.0, to: 2133.0, dx: 0.2, dy: 44.2, dw: 0.2, why: pa_why_composer_way },
  { drive: "wide-side-panel", what: Key("composer"), from: 617.0, to: 833.0, dx: 40.2, dy: 8.1, dw: 80.3, why: pa_why_composer_way },
  { drive: "wide-side-panel", what: Key("composer"), from: 2450.0, to: 2667.0, dx: 40.2, dy: 8.1, dw: 80.3, why: pa_why_composer_way },
  { drive: "wide-side-panel", what: Key("words 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 1633.0, to: 1917.0, dx: 2.0, dy: 12.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "wide-side-panel", what: Key("words 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 3467.0, to: 3750.0, dx: 2.0, dy: 12.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "wide-side-panel", what: Key("words 「等 林 决定」"), from: 1633.0, to: 1917.0, dx: 2.0, dy: 12.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "wide-side-panel", what: Key("words 「等 林 决定」"), from: 3467.0, to: 3750.0, dx: 2.0, dy: 12.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "wide-side-panel", what: Key("words 「先不换」"), from: 1633.0, to: 1917.0, dx: 2.0, dy: 12.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "wide-side-panel", what: Key("words 「先不换」"), from: 3467.0, to: 3750.0, dx: 2.0, dy: 12.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "wide-side-panel", what: Key("words 「这次只改列表，截图下次再说」"), from: 1633.0, to: 1917.0, dx: 2.0, dy: 12.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "wide-side-panel", what: Key("words 「这次只改列表，截图下次再说」"), from: 3467.0, to: 3750.0, dx: 2.0, dy: 12.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "wide-side-panel", what: Key("words 「一起换」"), from: 1633.0, to: 1917.0, dx: 2.0, dy: 12.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "wide-side-panel", what: Key("words 「一起换」"), from: 3467.0, to: 3750.0, dx: 2.0, dy: 12.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "wide-side-panel", what: Key("words 「把首页和聊天页的截图都更新」"), from: 1633.0, to: 1917.0, dx: 2.0, dy: 12.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "wide-side-panel", what: Key("words 「把首页和聊天页的截图都更新」"), from: 3467.0, to: 3750.0, dx: 2.0, dy: 12.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "wide-side-panel", what: Key("words 「忽略」"), from: 1633.0, to: 1917.0, dx: 2.0, dy: 12.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "wide-side-panel", what: Key("words 「忽略」"), from: 3467.0, to: 3750.0, dx: 2.0, dy: 12.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "wide-side-panel", what: Key("ground"), from: 683.0, to: 700.0, dx: 2.9, dy: 8.2, dw: 0.1, why: pa_why_composer_way },
  { drive: "wide-side-panel", what: Key("ground"), from: 1633.0, to: 1917.0, dx: 32.0, dy: 12.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "wide-side-panel", what: Key("ground"), from: 2517.0, to: 2533.0, dx: 2.9, dy: 8.2, dw: 0.1, why: pa_why_composer_way },
  { drive: "wide-side-panel", what: Key("ground"), from: 3467.0, to: 3750.0, dx: 32.0, dy: 12.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "wide-side-panel", what: Key("words 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 1633.0, to: 1917.0, dx: 32.0, dy: 10.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "wide-side-panel", what: Key("words 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 3467.0, to: 3750.0, dx: 32.0, dy: 10.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-long", what: Key("old alone 「发消息」"), from: 2100.0, to: 2100.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-long", what: Key("composer"), from: 683.0, to: 683.0, dx: 0.1, dy: 43.1, dw: 42.9, why: pa_why_composer_way },
  { drive: "send-long", what: Key("composer"), from: 1217.0, to: 1300.0, dx: 0.1, dy: 23.1, dw: 23.2, why: pa_why_composer_way },
  { drive: "send-long", what: Key("composer"), from: 1917.0, to: 1917.0, dx: 0.1, dy: 24.6, dw: 24.9, why: pa_why_composer_way },
  { drive: "send-long", what: Key("words 「发消息」"), from: 1917.0, to: 2050.0, dx: 0.1, dy: 24.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-over-line", what: Key("old alone 「发消息」"), from: 3117.0, to: 3133.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-over-line", what: Key("composer"), from: 683.0, to: 683.0, dx: 0.1, dy: 43.1, dw: 42.9, why: pa_why_composer_way },
  { drive: "send-over-line", what: Key("composer"), from: 2650.0, to: 2733.0, dx: 0.1, dy: 23.1, dw: 23.2, why: pa_why_composer_way },
  { drive: "send-over-line", what: Key("composer"), from: 2950.0, to: 2950.0, dx: 0.1, dy: 24.6, dw: 24.9, why: pa_why_composer_way },
  { drive: "send-over-line", what: Key("words 「发消息」"), from: 2950.0, to: 3100.0, dx: 0.1, dy: 24.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-picture-only", what: Key("old alone 「发消息」"), from: 2550.0, to: 2700.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-picture-only", what: Key("composer"), from: 2550.0, to: 2550.0, dx: 0.1, dy: 175.7, dw: 176.0, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("words 「Claude」"), from: 1633.0, to: 1633.0, dx: 0.1, dy: 20.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「Claude」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「Claude」"), from: 6117.0, to: 6117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「5 分钟前」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「15 分钟前」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「推送截图前要先登录 gh。」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「在 Willow 上登录 gh」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「等你在浏览器里登录」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「30 分钟前」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「等 林 决定」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「先不换」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「这次只改列表，截图下次再说」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「一起换」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「把首页和聊天页的截图都更新」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「忽略」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「还有深色模式也看一下」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「40 分钟前」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("nodes alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("nodes alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 6117.0, to: 6117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("nodes alone 「先不换」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("nodes alone 「一起换」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("nodes alone 「把首页和聊天页的截图都更新」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("nodes alone 「忽略」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("nodes alone 「40 分钟前」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("nodes alone 「1 小时前」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("nodes alone 「发送到」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("nodes alone 「发送到」"), from: 5517.0, to: 5533.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("nodes alone 「星火#发布」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("nodes alone 「发布清单 第三项已经核对完：安装包签名正确。」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("nodes alone 「Claude：其余的行按估计的高度占位，滚到时再量真实高度」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("nodes alone 「这里的高度是怎么估的？」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("composer"), from: 5200.0, to: 5383.0, dx: 0.1, dy: 106.9, dw: 107.3, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("composer"), from: 6117.0, to: 6117.0, dx: 0.1, dy: 133.9, dw: 134.1, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("words 「发消息」"), from: 5217.0, to: 5267.0, dx: 29.1, dy: 40.5, dw: 66.1, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("nodes alone 「发消息」"), from: 5250.0, to: 5250.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「添加说明（可选）」"), from: 5283.0, to: 5283.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「18 KB」"), from: 5283.0, to: 5283.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("nodes alone 「添加说明（可选）」"), from: 5217.0, to: 5383.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("button 跳到最新"), from: 5217.0, to: 5417.0, dx: 0.1, dy: 66.3, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("button 对话目录"), from: 5217.0, to: 5417.0, dx: 0.1, dy: 66.3, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("button 跳转到待决策的消息"), from: 5217.0, to: 5417.0, dx: 0.1, dy: 66.3, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「Claude：compare.png」"), from: 5250.0, to: 5350.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「发消息」"), from: 5283.0, to: 5300.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「build」"), from: 5267.0, to: 5333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「.log」"), from: 5267.0, to: 5333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("picture nodes alone"), from: 5283.0, to: 5283.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("ground old alone"), from: 5267.0, to: 5300.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("picture"), from: 5283.0, to: 5433.0, dx: 107.5, dy: 80.6, dw: 36.4, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("ground"), from: 5283.0, to: 5450.0, dx: 117.9, dy: 69.0, dw: 232.4, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「1 小时前」"), from: 5300.0, to: 5317.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「1 小时前」"), from: 6117.0, to: 6117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("nodes alone 「18 KB」"), from: 5317.0, to: 5433.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("words 「添加说明（可选）」"), from: 5400.0, to: 5433.0, dx: 0.1, dy: 14.4, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("nodes alone 「发消息」"), from: 5517.0, to: 5533.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「改好后的样子：」"), from: 6117.0, to: 6117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「对比图和构建日志附在下面。」"), from: 6117.0, to: 6117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「18 KB」"), from: 6117.0, to: 6117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("old alone 「发送到」"), from: 6117.0, to: 6117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("nodes alone 「等 林 决定」"), from: 6117.0, to: 6117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("button 跳转到待决策的消息 old alone"), from: 6117.0, to: 6133.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "scrolled-reply", what: Key("composer"), from: 683.0, to: 683.0, dx: 0.1, dy: 43.1, dw: 42.9, why: pa_why_composer_way },
  { drive: "scrolled-reply", what: Key("nodes alone 「Claude」"), from: 3167.0, to: 3167.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "scrolled-reply", what: Key("nodes alone 「30 分钟前」"), from: 3167.0, to: 3167.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "scrolled-reply-near", what: Key("composer"), from: 683.0, to: 683.0, dx: 0.1, dy: 43.1, dw: 42.9, why: pa_why_composer_way },
  { drive: "answer-leave", what: Key("composer"), from: 683.0, to: 683.0, dx: 0.1, dy: 43.1, dw: 42.9, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("composer"), from: 617.0, to: 833.0, dx: 40.2, dy: 8.1, dw: 80.3, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("composer"), from: 2667.0, to: 2783.0, dx: 0.1, dy: 63.6, dw: 63.9, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("composer"), from: 3700.0, to: 3800.0, dx: 0.1, dy: 60.1, dw: 60.2, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("composer"), from: 4600.0, to: 4600.0, dx: 0.1, dy: 136.1, dw: 136.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「Claude」"), from: 2667.0, to: 2867.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「Claude」"), from: 3717.0, to: 3767.0, dx: 0.1, dy: 11.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「30 分钟前」"), from: 2667.0, to: 2783.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「30 分钟前」"), from: 3733.0, to: 3733.0, dx: 0.1, dy: 11.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 2667.0, to: 2867.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 3717.0, to: 3767.0, dx: 0.1, dy: 11.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「等 林 决定」"), from: 2667.0, to: 2867.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「等 林 决定」"), from: 3717.0, to: 3767.0, dx: 0.1, dy: 11.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「先不换」"), from: 2667.0, to: 2867.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「先不换」"), from: 3717.0, to: 3767.0, dx: 0.1, dy: 11.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「这次只改列表，截图下次再说」"), from: 2667.0, to: 2867.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「这次只改列表，截图下次再说」"), from: 3717.0, to: 3767.0, dx: 0.1, dy: 11.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「一起换」"), from: 2667.0, to: 2867.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「一起换」"), from: 3717.0, to: 3767.0, dx: 0.1, dy: 11.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「把首页和聊天页的截图都更新」"), from: 2667.0, to: 2867.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「把首页和聊天页的截图都更新」"), from: 3717.0, to: 3767.0, dx: 0.1, dy: 11.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「忽略」"), from: 2667.0, to: 2867.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「忽略」"), from: 3717.0, to: 3767.0, dx: 0.1, dy: 11.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("ground"), from: 683.0, to: 700.0, dx: 2.9, dy: 8.2, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("ground"), from: 2667.0, to: 2983.0, dx: 158.3, dy: 29.8, dw: 313.7, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("ground"), from: 3717.0, to: 3833.0, dx: 0.1, dy: 20.1, dw: 29.2, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("ground"), from: 4817.0, to: 4817.0, dx: 132.3, dy: 41.2, dw: 281.9, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「40 分钟前」"), from: 2667.0, to: 2667.0, dx: 0.1, dy: 6.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「5 分钟前」"), from: 2667.0, to: 2867.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「5 分钟前」"), from: 3717.0, to: 3767.0, dx: 0.1, dy: 11.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 2667.0, to: 2867.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 3717.0, to: 3767.0, dx: 0.1, dy: 11.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「15 分钟前」"), from: 2667.0, to: 2867.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「15 分钟前」"), from: 3717.0, to: 3767.0, dx: 0.1, dy: 11.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「推送截图前要先登录 gh。」"), from: 2667.0, to: 2867.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「推送截图前要先登录 gh。」"), from: 3717.0, to: 3767.0, dx: 0.1, dy: 11.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「在 Willow 上登录 gh」"), from: 2667.0, to: 2867.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「在 Willow 上登录 gh」"), from: 3717.0, to: 3767.0, dx: 0.1, dy: 11.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「等你在浏览器里登录」"), from: 2667.0, to: 2867.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「等你在浏览器里登录」"), from: 3717.0, to: 3767.0, dx: 0.1, dy: 11.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 2667.0, to: 2867.0, dx: 0.1, dy: 25.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 3717.0, to: 3767.0, dx: 0.1, dy: 11.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("old alone 「40 分钟前」"), from: 2683.0, to: 2717.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("nodes alone 「添加说明（可选）」"), from: 2700.0, to: 2817.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("ground nodes alone"), from: 2700.0, to: 2733.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("nodes alone 「Claude：先登录 gh。」"), from: 2717.0, to: 2750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("nodes alone 「Claude：先登录 gh。」"), from: 4783.0, to: 4783.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「Claude：先登录 gh。」"), from: 2767.0, to: 2883.0, dx: 0.1, dy: 31.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「Claude：先登录 gh。」"), from: 3750.0, to: 3833.0, dx: 0.1, dy: 37.3, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「Claude：先登录 gh。」"), from: 4667.0, to: 4667.0, dx: 6.8, dy: 0.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("old alone 「Claude」"), from: 2800.0, to: 2883.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("old alone 「Claude」"), from: 3750.0, to: 3750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("old alone 「30 分钟前」"), from: 2800.0, to: 2883.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("old alone 「30 分钟前」"), from: 3750.0, to: 3750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「添加说明（可选）」"), from: 2833.0, to: 2883.0, dx: 0.1, dy: 13.0, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「添加说明（可选）」"), from: 3717.0, to: 3833.0, dx: 0.1, dy: 60.5, dw: 0.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("nodes alone 「发消息」"), from: 2967.0, to: 2967.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("old alone 「Claude：先登录 gh。」"), from: 4783.0, to: 4783.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("nodes alone 「Claude」"), from: 3717.0, to: 3717.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("nodes alone 「30 分钟前」"), from: 3717.0, to: 3717.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("picture nodes alone"), from: 3717.0, to: 3733.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 3733.0, to: 3733.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 3850.0, to: 3850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("nodes alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 3750.0, to: 3750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("picture"), from: 3750.0, to: 3817.0, dx: 20.3, dy: 35.3, dw: 37.2, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("old alone 「等 林 决定」"), from: 3783.0, to: 3783.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("nodes alone 「等 林 决定」"), from: 3833.0, to: 3833.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("words 「Claude」"), from: 1633.0, to: 1633.0, dx: 0.1, dy: 20.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "viewer", what: Key("old alone 「Claude」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("old alone 「5 分钟前」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("old alone 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("old alone 「15 分钟前」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("old alone 「推送截图前要先登录 gh。」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("old alone 「在 Willow 上登录 gh」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("old alone 「等你在浏览器里登录」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("old alone 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("old alone 「30 分钟前」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("old alone 「等 林 决定」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("old alone 「先不换」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("old alone 「这次只改列表，截图下次再说」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("old alone 「一起换」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("old alone 「把首页和聊天页的截图都更新」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("old alone 「忽略」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("old alone 「还有深色模式也看一下」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("old alone 「40 分钟前」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("nodes alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("nodes alone 「先不换」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("nodes alone 「一起换」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("nodes alone 「把首页和聊天页的截图都更新」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("nodes alone 「忽略」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("nodes alone 「40 分钟前」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("nodes alone 「1 小时前」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("nodes alone 「发送到」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("nodes alone 「星火#发布」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("nodes alone 「发布清单 第三项已经核对完：安装包签名正确。」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("nodes alone 「Claude：其余的行按估计的高度占位，滚到时再量真实高度」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer", what: Key("nodes alone 「这里的高度是怎么估的？」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("words 「Claude」"), from: 1633.0, to: 1633.0, dx: 0.1, dy: 20.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("old alone 「Claude」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("old alone 「5 分钟前」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("old alone 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("old alone 「15 分钟前」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("old alone 「推送截图前要先登录 gh。」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("old alone 「在 Willow 上登录 gh」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("old alone 「等你在浏览器里登录」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("old alone 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("old alone 「30 分钟前」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("old alone 「等 林 决定」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("old alone 「先不换」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("old alone 「这次只改列表，截图下次再说」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("old alone 「一起换」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("old alone 「把首页和聊天页的截图都更新」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("old alone 「忽略」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("old alone 「还有深色模式也看一下」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("old alone 「40 分钟前」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("nodes alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("nodes alone 「先不换」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("nodes alone 「一起换」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("nodes alone 「把首页和聊天页的截图都更新」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("nodes alone 「忽略」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("nodes alone 「40 分钟前」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("nodes alone 「1 小时前」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("nodes alone 「发送到」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("nodes alone 「星火#发布」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("nodes alone 「发布清单 第三项已经核对完：安装包签名正确。」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("nodes alone 「Claude：其余的行按估计的高度占位，滚到时再量真实高度」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "viewer-open", what: Key("nodes alone 「这里的高度是怎么估的？」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("words 「Claude」"), from: 1633.0, to: 1633.0, dx: 0.1, dy: 20.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("old alone 「Claude」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("old alone 「5 分钟前」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("old alone 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("old alone 「15 分钟前」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("old alone 「推送截图前要先登录 gh。」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("old alone 「在 Willow 上登录 gh」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("old alone 「等你在浏览器里登录」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("old alone 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("old alone 「30 分钟前」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("old alone 「等 林 决定」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("old alone 「先不换」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("old alone 「这次只改列表，截图下次再说」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("old alone 「一起换」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("old alone 「把首页和聊天页的截图都更新」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("old alone 「忽略」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("old alone 「还有深色模式也看一下」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("old alone 「40 分钟前」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("nodes alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("nodes alone 「先不换」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("nodes alone 「一起换」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("nodes alone 「把首页和聊天页的截图都更新」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("nodes alone 「忽略」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("nodes alone 「40 分钟前」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("nodes alone 「1 小时前」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("nodes alone 「发送到」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("nodes alone 「星火#发布」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("nodes alone 「发布清单 第三项已经核对完：安装包签名正确。」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("nodes alone 「Claude：其余的行按估计的高度占位，滚到时再量真实高度」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "picture-lift", what: Key("nodes alone 「这里的高度是怎么估的？」"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-images", what: Key("words 「Claude」"), from: 417.0, to: 417.0, dx: 0.1, dy: 46.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "wide-images", what: Key("old alone 「Claude」"), from: 417.0, to: 417.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-images", what: Key("old alone 「5 分钟前」"), from: 417.0, to: 417.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-images", what: Key("old alone 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 417.0, to: 417.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-images", what: Key("old alone 「15 分钟前」"), from: 417.0, to: 417.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-images", what: Key("old alone 「推送截图前要先登录 gh。」"), from: 417.0, to: 417.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-images", what: Key("old alone 「在 Willow 上登录 gh」"), from: 417.0, to: 417.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-images", what: Key("old alone 「等你在浏览器里登录」"), from: 417.0, to: 417.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-images", what: Key("old alone 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 417.0, to: 417.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-images", what: Key("old alone 「30 分钟前」"), from: 417.0, to: 417.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-images", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 417.0, to: 417.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-images", what: Key("old alone 「等 林 决定」"), from: 417.0, to: 417.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-images", what: Key("old alone 「先不换」"), from: 417.0, to: 417.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-images", what: Key("old alone 「这次只改列表，截图下次再说」"), from: 417.0, to: 417.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-images", what: Key("old alone 「一起换」"), from: 417.0, to: 417.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-images", what: Key("old alone 「把首页和聊天页的截图都更新」"), from: 417.0, to: 417.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-images", what: Key("old alone 「忽略」"), from: 417.0, to: 417.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-images", what: Key("nodes alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 417.0, to: 417.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-images", what: Key("nodes alone 「等 林 决定」"), from: 417.0, to: 417.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-images", what: Key("nodes alone 「先不换」"), from: 417.0, to: 417.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-images", what: Key("nodes alone 「这次只改列表，截图下次再说」"), from: 417.0, to: 417.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "wide-images", what: Key("nodes alone 「忽略」"), from: 417.0, to: 417.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("nodes alone 「添加说明（可选）」"), from: 1033.0, to: 1267.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("nodes alone 「发消息」"), from: 1350.0, to: 1367.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("words 「Claude」"), from: 1050.0, to: 1317.0, dx: 0.1, dy: 49.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("words 「1 分钟前」"), from: 1050.0, to: 1317.0, dx: 0.1, dy: 49.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("words 「打好的发布包在这里，下载下来装一下看看。」"), from: 1050.0, to: 1317.0, dx: 0.1, dy: 49.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("words 「发布包」"), from: 1050.0, to: 1317.0, dx: 0.1, dy: 49.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("words 「.zip」"), from: 1050.0, to: 1317.0, dx: 0.1, dy: 49.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("words 「50.0 MB」"), from: 1050.0, to: 1317.0, dx: 0.1, dy: 49.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("words 「0:13」"), from: 1050.0, to: 1317.0, dx: 0.1, dy: 49.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("words 「5 分钟前」"), from: 1050.0, to: 1317.0, dx: 0.1, dy: 49.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("words 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 1050.0, to: 1317.0, dx: 0.1, dy: 49.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("words 「15 分钟前」"), from: 1050.0, to: 1083.0, dx: 0.1, dy: 41.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("words 「推送截图前要先登录 gh。」"), from: 1050.0, to: 1233.0, dx: 0.1, dy: 49.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("words 「在 Willow 上登录 gh」"), from: 1050.0, to: 1317.0, dx: 0.1, dy: 49.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("words 「等你在浏览器里登录」"), from: 1050.0, to: 1317.0, dx: 0.1, dy: 49.6, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("composer"), from: 1050.0, to: 1217.0, dx: 0.1, dy: 105.6, dw: 105.7, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("composer"), from: 1950.0, to: 1950.0, dx: 0.1, dy: 132.1, dw: 132.1, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("picture"), from: 1050.0, to: 1367.0, dx: 247.0, dy: 62.2, dw: 36.4, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("ground"), from: 1050.0, to: 1400.0, dx: 302.3, dy: 55.2, dw: 600.6, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("ground"), from: 2167.0, to: 2167.0, dx: 124.8, dy: 42.9, dw: 275.2, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("button 跳转到待决策的消息"), from: 1050.0, to: 1317.0, dx: 0.1, dy: 49.7, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("ground nodes alone"), from: 1067.0, to: 1100.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("button 对话目录"), from: 1067.0, to: 1267.0, dx: 0.1, dy: 24.9, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("old alone 「Claude」"), from: 1100.0, to: 1217.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("old alone 「15 分钟前」"), from: 1100.0, to: 1133.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("nodes alone 「Claude」"), from: 1100.0, to: 1150.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("picture nodes alone"), from: 1100.0, to: 1117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("old alone 「推送截图前要先登录 gh。」"), from: 1133.0, to: 1133.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("old alone 「推送截图前要先登录 gh。」"), from: 1250.0, to: 1350.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("nodes alone 「Claude：演示录屏.mp4」"), from: 1150.0, to: 1183.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("words 「Claude：演示录屏.mp4」"), from: 1200.0, to: 1317.0, dx: 0.1, dy: 39.0, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("words 「Claude：演示录屏.mp4」"), from: 2017.0, to: 2017.0, dx: 6.4, dy: 0.1, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("words 「Claude：演示录屏.mp4」"), from: 2133.0, to: 2133.0, dx: 93.3, dy: 22.2, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("nodes alone 「推送截图前要先登录 gh。」"), from: 1200.0, to: 1200.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("words 「添加说明（可选）」"), from: 1283.0, to: 1317.0, dx: 0.1, dy: 11.8, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("old alone 「在 Willow 上登录 gh」"), from: 1950.0, to: 2100.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("old alone 「在 Willow 上登录 gh」"), from: 2167.0, to: 2167.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("old alone 「等你在浏览器里登录」"), from: 1950.0, to: 2200.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("button 跳转到待决策的消息 old alone"), from: 1950.0, to: 1950.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("button 跳转到待决策的消息 nodes alone"), from: 1950.0, to: 1950.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-video", what: Key("ground old alone"), from: 2133.0, to: 2133.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-right-panel-toggle", what: Key("button @outline old alone"), from: 617.0, to: 617.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_panel_first },
  { drive: "desk-right-panel-toggle", what: Key("words 「30 分钟前」"), from: 617.0, to: 717.0, dx: 25.2, dy: 11.3, dw: 0.2, why: pa_why_panel_first },
  { drive: "desk-right-panel-toggle", what: Key("words 「Claude」"), from: 617.0, to: 717.0, dx: 25.2, dy: 11.3, dw: 0.2, why: pa_why_panel_first },
  { drive: "desk-right-panel-toggle", what: Key("words 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 617.0, to: 617.0, dx: 0.2, dy: 0.2, dw: 181.2, why: pa_why_panel_first },
  { drive: "desk-right-panel-toggle", what: Key("words 「忽略」"), from: 617.0, to: 717.0, dx: 3.6, dy: 7.3, dw: 181.2, why: pa_why_panel_first },
  { drive: "desk-right-panel-toggle", what: Key("words 「推送截图前要先登录 gh。」"), from: 617.0, to: 617.0, dx: 0.2, dy: 0.2, dw: 181.2, why: pa_why_panel_first },
  { drive: "desk-right-panel-toggle", what: Key("words 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 617.0, to: 717.0, dx: 3.6, dy: 7.3, dw: 181.2, why: pa_why_panel_first },
  { drive: "desk-right-panel-toggle", what: Key("ground"), from: 633.0, to: 817.0, dx: 90.7, dy: 7.3, dw: 0.2, why: pa_why_panel_first },
  { drive: "desk-right-panel-toggle", what: Key("words 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 633.0, to: 817.0, dx: 90.7, dy: 5.0, dw: 0.2, why: pa_why_panel_mine },
  { drive: "desk-right-panel-toggle", what: Rows, from: 667.0, to: 717.0, dx: pa_way_tol, dy: 7.3, dw: pa_way_tol, why: pa_why_panel_mine },
  { drive: "desk-right-panel-toggle", what: Key("nodes alone 「40 分钟前」"), from: 700.0, to: 717.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_panel_mine },
  { drive: "desk-right-panel-toggle", what: Key("words 「40 分钟前」"), from: 733.0, to: 850.0, dx: 54.2, dy: 5.7, dw: 0.2, why: pa_why_panel_mine },
  { drive: "desk-right-panel-toggle", what: Key("ground nodes alone"), from: 1217.0, to: 1317.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_tip },
  { drive: "desk-right-panel-toggle", what: Key("nodes alone 「Esc」"), from: 1233.0, to: 1333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_tip },
  { drive: "desk-right-panel-toggle", what: Key("nodes alone 「收起侧栏」"), from: 1233.0, to: 1333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_tip },
  { drive: "desk-right-panel-toggle", what: Key("nodes alone 「面板开着也发一条」"), from: 2967.0, to: 2967.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-right-panel-toggle", what: Key("words 「面板开着也发一条」"), from: 3033.0, to: 3150.0, dx: 105.0, dy: 13.9, dw: 0.2, why: pa_why_send },
  { drive: "desk-right-panel-toggle", what: Key("old alone 「发消息」"), from: 3150.0, to: 3200.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-right-panel-toggle", what: Key("nodes alone 「面板开着也发一条」"), from: 3167.0, to: 3267.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-right-panel-toggle", what: Key("old alone 「面板开着也发一条」"), from: 3167.0, to: 3267.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-right-panel-toggle", what: Key("nodes alone 「40 分钟前」"), from: 3183.0, to: 3183.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-right-panel-toggle", what: Key("ground"), from: 3200.0, to: 3467.0, dx: 53.3, dy: 56.1, dw: 0.2, why: pa_why_send },
  { drive: "desk-right-panel-toggle", what: Key("ground nodes alone"), from: 3183.0, to: 3267.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-right-panel-toggle", what: Rows, from: 3200.0, to: 3217.0, dx: pa_way_tol, dy: 7.2, dw: pa_way_tol, why: pa_why_send },
  { drive: "desk-right-panel-toggle", what: Key("ground old alone"), from: 3233.0, to: 3267.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-right-panel-toggle", what: Key("words 「面板开着也发一条」"), from: 3283.0, to: 3467.0, dx: 53.1, dy: 56.0, dw: 0.2, why: pa_why_send },
  { drive: "desk-right-panel-toggle", what: Key("old alone 「Claude」"), from: 3317.0, to: 3317.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-right-panel-toggle", what: Key("nodes alone 「30 分钟前」"), from: 3450.0, to: 3500.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-right-panel-toggle", what: Key("nodes alone 「Claude」"), from: 3450.0, to: 3500.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-right-panel-toggle", what: Key("ring old alone"), from: 3667.0, to: 3717.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "desk-right-panel-toggle", what: Key("old alone 「0s」"), from: 3683.0, to: 3717.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-right-panel-toggle", what: Key("alpha 「0s」"), from: 3733.0, to: 3800.0, dx: 0.2, dy: 0.2, dw: 0.8, why: pa_why_working },
  { drive: "desk-right-panel-toggle", what: Key("nodes alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 3733.0, to: 3733.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-right-panel-toggle", what: Key("old alone 「Claude」"), from: 3733.0, to: 3733.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-right-panel-toggle", what: Key("ring"), from: 3733.0, to: 3750.0, dx: 5.1, dy: 1.3, dw: 10.0, why: pa_why_working },
  { drive: "desk-right-panel-toggle", what: Key("ring alpha"), from: 3733.0, to: 3800.0, dx: 0.2, dy: 0.2, dw: 1.0, why: pa_why_working },
  { drive: "desk-right-panel-toggle", what: Key("words 「0s」"), from: 3733.0, to: 3800.0, dx: 30.1, dy: 3.1, dw: 5.1, why: pa_why_working },
  { drive: "desk-right-panel-toggle", what: Key("old alone 「30 分钟前」"), from: 3750.0, to: 3750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-right-panel-toggle", what: Key("nodes alone 「处理中」"), from: 3783.0, to: 3783.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-right-panel-toggle", what: Key("old alone 「等 林 决定」"), from: 3783.0, to: 3783.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-right-panel-toggle", what: Key("alpha 「处理中」"), from: 3800.0, to: 3800.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_working },
  { drive: "desk-right-panel-toggle", what: Key("words 「0s」"), from: 5083.0, to: 5100.0, dx: 36.2, dy: 0.2, dw: 3.0, why: pa_why_working },
  { drive: "desk-right-panel-toggle", what: Key("words 「处理中」"), from: 5083.0, to: 5083.0, dx: 0.2, dy: 0.2, dw: 17.0, why: pa_why_working },
  { drive: "desk-right-panel-toggle", what: Key("nodes alone 「处理中」"), from: 5100.0, to: 5150.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-right-panel-toggle", what: Key("nodes alone 「0s」"), from: 5117.0, to: 5150.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-right-panel-toggle", what: Key("old alone 「处理中」"), from: 5167.0, to: 5167.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-right-panel-toggle", what: Key("button @outline nodes alone"), from: 5183.0, to: 5183.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_panel_first },
  { drive: "desk-right-panel-toggle", what: Key("nodes alone 「刚刚」"), from: 5200.0, to: 5250.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_panel_mine },
  { drive: "desk-right-panel-toggle", what: Key("words 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 5183.0, to: 5183.0, dx: 0.2, dy: 0.2, dw: 181.2, why: pa_why_panel_first },
  { drive: "desk-right-panel-toggle", what: Key("words 「忽略」"), from: 5183.0, to: 5333.0, dx: 7.9, dy: 13.8, dw: 181.2, why: pa_why_panel_first },
  { drive: "desk-right-panel-toggle", what: Key("words 「推送截图前要先登录 gh。」"), from: 5183.0, to: 5183.0, dx: 0.2, dy: 0.2, dw: 181.2, why: pa_why_panel_first },
  { drive: "desk-right-panel-toggle", what: Key("words 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 5183.0, to: 5183.0, dx: 0.2, dy: 0.2, dw: 181.2, why: pa_why_panel_first },
  { drive: "desk-right-panel-toggle", what: Key("ground"), from: 5200.0, to: 5417.0, dx: 125.7, dy: 14.1, dw: 82.2, why: pa_why_spit },
  { drive: "desk-right-panel-toggle", what: Key("ground nodes alone"), from: 5200.0, to: 5217.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_spit },
  { drive: "desk-right-panel-toggle", what: Key("nodes alone 「面板开着也发一条」"), from: 5200.0, to: 5233.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_panel_mine },
  { drive: "desk-right-panel-toggle", what: Key("ring"), from: 5200.0, to: 5200.0, dx: 1.5, dy: 0.4, dw: 7.1, why: pa_why_spit },
  { drive: "desk-right-panel-toggle", what: Key("words 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 5200.0, to: 5383.0, dx: 81.5, dy: 14.1, dw: 0.2, why: pa_why_panel_mine },
  { drive: "desk-right-panel-toggle", what: Key("nodes alone 「等 林 决定」"), from: 5217.0, to: 5217.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_spit },
  { drive: "desk-right-panel-toggle", what: Key("old alone 「面板开着也发一条」"), from: 5217.0, to: 5233.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_panel_mine },
  { drive: "desk-right-panel-toggle", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 5217.0, to: 5217.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_panel_mine },
  { drive: "desk-right-panel-toggle", what: Rows, from: 5233.0, to: 5333.0, dx: pa_way_tol, dy: 13.8, dw: pa_way_tol, why: pa_why_panel_mine },
  { drive: "desk-right-panel-toggle", what: Key("ring old alone"), from: 5250.0, to: 6300.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "desk-right-panel-toggle", what: Key("words 「面板开着也发一条」"), from: 5250.0, to: 5417.0, dx: 114.0, dy: 7.6, dw: 0.2, why: pa_why_panel_mine },
  { drive: "desk-right-panel-toggle", what: Key("old alone 「先不换」"), from: 5267.0, to: 5267.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_spit },
  { drive: "desk-right-panel-toggle", what: Key("old alone 「等 林 决定」"), from: 5267.0, to: 5283.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_spit },
  { drive: "desk-right-panel-toggle", what: Key("nodes alone 「先不换」"), from: 5300.0, to: 5300.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_spit },
  { drive: "desk-right-panel-toggle", what: Key("nodes alone 「先不换」"), from: 5283.0, to: 5283.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_room_way },
  { drive: "desk-right-panel-toggle", what: Key("nodes alone 「这次只改列表，截图下次再说」"), from: 5350.0, to: 5367.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_room_way },
  { drive: "desk-right-panel-toggle", what: Key("old alone 「这次只改列表，截图下次再说」"), from: 5300.0, to: 5317.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_spit },
  { drive: "desk-right-panel-toggle", what: Key("words 「刚刚」"), from: 5267.0, to: 5417.0, dx: 91.5, dy: 7.6, dw: 8.2, why: pa_why_panel_mine },
  { drive: "desk-right-panel-toggle", what: Key("old alone 「Claude」"), from: 5667.0, to: 5667.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_float },
  { drive: "desk-right-panel-toggle", what: Key("alpha 「Claude」"), from: 5683.0, to: 5700.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_send },
  { drive: "desk-right-panel-toggle", what: Key("alpha 「刚刚」"), from: 5683.0, to: 5700.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_timein },
  { drive: "desk-right-panel-toggle", what: Key("nodes alone 「收到：「面板开着也发一条」。我先看一下，有结果再告诉你。」"), from: 5683.0, to: 5800.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_spit },
  { drive: "desk-right-panel-toggle", what: Key("words 「Claude」"), from: 5683.0, to: 5683.0, dx: 7.0, dy: 0.2, dw: 0.2, why: pa_why_float },
  { drive: "desk-right-panel-toggle", what: Key("words 「刚刚」"), from: 5683.0, to: 5683.0, dx: 7.0, dy: 0.2, dw: 0.2, why: pa_why_float },
  { drive: "desk-right-panel-toggle", what: Key("words 「Claude」"), from: 650.0, to: 750.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-right-panel-toggle", what: Key("words 「30 分钟前」"), from: 650.0, to: 750.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-right-panel-toggle", what: Key("words 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 650.0, to: 750.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-right-panel-toggle", what: Key("words 「等 林 决定」"), from: 650.0, to: 750.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-right-panel-toggle", what: Key("words 「先不换」"), from: 650.0, to: 750.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-right-panel-toggle", what: Key("words 「先不换」"), from: 5217.0, to: 5217.0, dx: 4.4, dy: 7.6, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-right-panel-toggle", what: Key("words 「这次只改列表，截图下次再说」"), from: 650.0, to: 750.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-right-panel-toggle", what: Key("words 「这次只改列表，截图下次再说」"), from: 5217.0, to: 5283.0, dx: 7.9, dy: 16.8, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-right-panel-toggle", what: Key("words 「一起换」"), from: 650.0, to: 750.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-right-panel-toggle", what: Key("words 「一起换」"), from: 5217.0, to: 5283.0, dx: 7.9, dy: 16.8, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-right-panel-toggle", what: Key("words 「把首页和聊天页的截图都更新」"), from: 650.0, to: 750.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-right-panel-toggle", what: Key("words 「把首页和聊天页的截图都更新」"), from: 5217.0, to: 5283.0, dx: 7.9, dy: 16.8, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-right-panel-toggle", what: Key("words 「忽略」"), from: 650.0, to: 750.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-right-panel-toggle", what: Key("words 「忽略」"), from: 5267.0, to: 5283.0, dx: 2.6, dy: 16.8, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-right-panel-toggle", what: Key("ground"), from: 650.0, to: 717.0, dx: 56.0, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-right-panel-toggle", what: Key("ground"), from: 5267.0, to: 5283.0, dx: 40.5, dy: 16.8, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-right-panel-toggle", what: Key("words 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 667.0, to: 717.0, dx: 68.2, dy: 9.0, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-right-panel-toggle", what: Key("nodes alone 「40 分钟前」"), from: 683.0, to: 683.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_room_way },
  { drive: "desk-right-panel-toggle", what: Key("words 「40 分钟前」"), from: 733.0, to: 750.0, dx: 54.2, dy: 8.7, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-right-panel-toggle", what: Key("old alone 「详情」"), from: 1233.0, to: 1233.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_tip },
  { drive: "desk-right-panel-toggle", what: Key("composer"), from: 5183.0, to: 5417.0, dx: 46.1, dy: 8.2, dw: 92.0, why: pa_why_room_way },
  { drive: "desk-right-panel-toggle", what: Key("words 「面板开着也发一条」"), from: 5267.0, to: 5317.0, dx: 83.2, dy: 8.3, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-right-panel-toggle", what: Key("words 「刚刚」"), from: 5267.0, to: 5317.0, dx: 83.2, dy: 8.3, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-right-panel-toggle", what: Key("nodes alone 「这次只改列表，截图下次再说」"), from: 5333.0, to: 5333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_room_way },
  { drive: "desk-right-panel-toggle", what: Key("words 「5 分钟前」"), from: 633.0, to: 717.0, dx: 19.5, dy: 4.5, dw: 0.2, why: pa_why_send },
  { drive: "desk-right-panel-toggle", what: Key("words 「5 分钟前」"), from: 5200.0, to: 5250.0, dx: 28.7, dy: 6.9, dw: 0.2, why: pa_why_send },
  { drive: "desk-right-panel-toggle", what: Key("words 「15 分钟前」"), from: 633.0, to: 717.0, dx: 19.5, dy: 7.0, dw: 0.2, why: pa_why_send },
  { drive: "desk-right-panel-toggle", what: Key("words 「15 分钟前」"), from: 5200.0, to: 5250.0, dx: 28.7, dy: 8.4, dw: 0.2, why: pa_why_send },
  { drive: "desk-right-panel-toggle", what: Key("words 「Claude」"), from: 5200.0, to: 5250.0, dx: 28.7, dy: 8.4, dw: 0.2, why: pa_why_send },
  { drive: "desk-right-panel-toggle", what: Key("nodes alone 「刚刚」"), from: 3067.0, to: 3583.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "desk-right-panel-toggle", what: Key("ground alpha"), from: 3283.0, to: 3283.0, dx: 0.2, dy: 0.2, dw: 0.2, why: pa_why_send },
  { drive: "desk-right-panel-toggle", what: Key("words 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 5250.0, to: 5250.0, dx: 7.9, dy: 6.9, dw: 0.2, why: pa_why_send },
  { drive: "desk-right-panel-toggle", what: Key("words 「推送截图前要先登录 gh。」"), from: 5250.0, to: 5250.0, dx: 7.9, dy: 8.4, dw: 0.2, why: pa_why_send },
  { drive: "desk-right-panel-toggle", what: Key("words 「在 Willow 上登录 gh」"), from: 5250.0, to: 5250.0, dx: 7.9, dy: 8.4, dw: 0.2, why: pa_why_send },
  { drive: "desk-right-panel-toggle", what: Key("words 「等你在浏览器里登录」"), from: 5250.0, to: 5250.0, dx: 7.9, dy: 8.4, dw: 0.2, why: pa_why_send },
  { drive: "desk-right-panel-toggle", what: Key("words 「等 林 决定」"), from: 5250.0, to: 5250.0, dx: 7.9, dy: 11.9, dw: 0.2, why: pa_why_send },
  { drive: "desk-right-panel-toggle", what: Key("words 「先不换」"), from: 5250.0, to: 5250.0, dx: 7.9, dy: 11.9, dw: 0.2, why: pa_why_send },
  { drive: "desk-send-picture-and-file", what: Key("button @asks.go nodes alone"), from: 3583.0, to: 4400.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-send-picture-and-file", what: Key("nodes alone 「截图和日志都在这里」"), from: 3583.0, to: 3583.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_island },
  { drive: "desk-send-picture-and-file", what: Key("words 「2 KB」"), from: 3583.0, to: 3600.0, dx: 2.2, dy: 2.2, dw: 94.2, why: pa_why_send },
  { drive: "desk-send-picture-and-file", what: Key("button @outline"), from: 3600.0, to: 3983.0, dx: 0.2, dy: 33.2, dw: 0.2, why: pa_why_send },
  { drive: "desk-send-picture-and-file", what: Key("composer"), from: 3600.0, to: 3750.0, dx: 0.2, dy: 66.2, dw: 66.2, why: pa_why_send },
  { drive: "desk-send-picture-and-file", what: Key("ground"), from: 3600.0, to: 4183.0, dx: 123.2, dy: 84.8, dw: 88.2, why: pa_why_bell },
  { drive: "desk-send-picture-and-file", what: Key("picture"), from: 3600.0, to: 4183.0, dx: 170.0, dy: 151.0, dw: 97.4, why: pa_why_bell },
  { drive: "desk-send-picture-and-file", what: Key("nodes alone 「2 KB」"), from: 3617.0, to: 4000.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-picture-and-file", what: Key("words 「截图和日志都在这里」"), from: 3633.0, to: 3733.0, dx: 91.1, dy: 7.6, dw: 0.2, why: pa_why_send },
  { drive: "desk-send-picture-and-file", what: Key("words 「.log」"), from: 3650.0, to: 3733.0, dx: 81.4, dy: 11.7, dw: 0.2, why: pa_why_send },
  { drive: "desk-send-picture-and-file", what: Key("words 「构建日志」"), from: 3650.0, to: 3733.0, dx: 81.4, dy: 11.7, dw: 0.2, why: pa_why_send },
  { drive: "desk-send-picture-and-file", what: Key("nodes alone 「.log」"), from: 3750.0, to: 4000.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-picture-and-file", what: Key("nodes alone 「截图和日志都在这里」"), from: 3750.0, to: 3983.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-picture-and-file", what: Key("nodes alone 「构建日志」"), from: 3750.0, to: 4000.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-picture-and-file", what: Key("nodes alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 3750.0, to: 3783.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-send-picture-and-file", what: Key("old alone 「.log」"), from: 3750.0, to: 4000.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-picture-and-file", what: Key("old alone 「截图和日志都在这里」"), from: 3750.0, to: 3983.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-picture-and-file", what: Key("old alone 「构建日志」"), from: 3750.0, to: 4000.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-picture-and-file", what: Rows, from: 3750.0, to: 4117.0, dx: pa_way_tol, dy: 33.2, dw: pa_way_tol, why: pa_why_send },
  { drive: "desk-send-picture-and-file", what: Key("ground nodes alone"), from: 3750.0, to: 4000.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-send-picture-and-file", what: Key("ground old alone"), from: 3767.0, to: 4000.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-send-picture-and-file", what: Key("old alone 「Claude」"), from: 3767.0, to: 3783.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-send-picture-and-file", what: Key("old alone 「发消息」"), from: 3767.0, to: 3867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-send-picture-and-file", what: Key("old alone 「等 林 决定」"), from: 3783.0, to: 3850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-picture-and-file", what: Key("nodes alone 「等 林 决定」"), from: 3817.0, to: 3817.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-send-picture-and-file", what: Key("old alone 「2 KB」"), from: 3817.0, to: 4000.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-picture-and-file", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 3817.0, to: 3817.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-picture-and-file", what: Key("old alone 「先不换」"), from: 3833.0, to: 3833.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-picture-and-file", what: Key("old alone 「这次只改列表，截图下次再说」"), from: 3850.0, to: 3867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-picture-and-file", what: Key("old alone 「一起换」"), from: 3883.0, to: 3900.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-send-picture-and-file", what: Key("old alone 「把首页和聊天页的截图都更新」"), from: 3900.0, to: 3933.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-send-picture-and-file", what: Key("old alone 「忽略」"), from: 3983.0, to: 4067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-send-picture-and-file", what: Key("words 「截图和日志都在这里」"), from: 4000.0, to: 4167.0, dx: 57.9, dy: 54.4, dw: 0.2, why: pa_why_send },
  { drive: "desk-send-picture-and-file", what: Key("words 「.log」"), from: 4017.0, to: 4183.0, dx: 43.0, dy: 65.3, dw: 0.2, why: pa_why_send },
  { drive: "desk-send-picture-and-file", what: Key("words 「2 KB」"), from: 4017.0, to: 4183.0, dx: 43.0, dy: 65.3, dw: 0.2, why: pa_why_send },
  { drive: "desk-send-picture-and-file", what: Key("words 「构建日志」"), from: 4017.0, to: 4183.0, dx: 43.0, dy: 65.3, dw: 0.2, why: pa_why_send },
  { drive: "desk-send-picture-and-file", what: Key("ring old alone"), from: 4283.0, to: 4333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "desk-send-picture-and-file", what: Key("old alone 「0s」"), from: 4300.0, to: 4333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-send-picture-and-file", what: Key("old alone 「忽略」"), from: 4300.0, to: 4350.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-picture-and-file", what: Key("alpha 「0s」"), from: 4350.0, to: 4417.0, dx: 0.2, dy: 0.2, dw: 0.8, why: pa_why_working },
  { drive: "desk-send-picture-and-file", what: Key("ring"), from: 4350.0, to: 4367.0, dx: 5.1, dy: 0.7, dw: 10.0, why: pa_why_bell },
  { drive: "desk-send-picture-and-file", what: Key("ring alpha"), from: 4350.0, to: 4417.0, dx: 0.2, dy: 0.2, dw: 1.0, why: pa_why_bell },
  { drive: "desk-send-picture-and-file", what: Key("words 「0s」"), from: 4350.0, to: 4417.0, dx: 30.1, dy: 3.6, dw: 5.1, why: pa_why_working },
  { drive: "desk-send-picture-and-file", what: Key("ground old alone"), from: 4400.0, to: 4400.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-send-picture-and-file", what: Key("nodes alone 「处理中」"), from: 4400.0, to: 4400.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-send-picture-and-file", what: Key("old alone 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 4400.0, to: 4400.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-send-picture-and-file", what: Key("alpha 「处理中」"), from: 4417.0, to: 4417.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_working },
  { drive: "desk-send-picture-and-file", what: Key("words 「0s」"), from: 5700.0, to: 5717.0, dx: 36.2, dy: 0.2, dw: 3.0, why: pa_why_working },
  { drive: "desk-send-picture-and-file", what: Key("words 「处理中」"), from: 5700.0, to: 5700.0, dx: 0.2, dy: 0.2, dw: 17.0, why: pa_why_working },
  { drive: "desk-send-picture-and-file", what: Key("nodes alone 「处理中」"), from: 5717.0, to: 5767.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-send-picture-and-file", what: Key("nodes alone 「0s」"), from: 5733.0, to: 5767.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-send-picture-and-file", what: Key("old alone 「处理中」"), from: 5783.0, to: 5783.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-send-picture-and-file", what: Key("ground alpha"), from: 3750.0, to: 3767.0, dx: 0.2, dy: 0.2, dw: 0.3, why: pa_why_send },
  { drive: "desk-send-picture-and-file", what: Key("nodes alone 「刚刚」"), from: 4117.0, to: 4283.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "send-quote-wide", what: Key("old alone 「引用」"), from: 1433.0, to: 1433.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_menu },
  { drive: "send-quote-wide", what: Key("nodes alone 「这一步写进文档」"), from: 2683.0, to: 2700.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-wide", what: Key("old alone 「添加说明（可选）」"), from: 2683.0, to: 2700.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-wide", what: Key("button @outline"), from: 2700.0, to: 3083.0, dx: 0.2, dy: 35.2, dw: 0.2, why: pa_why_send },
  { drive: "send-quote-wide", what: Key("composer"), from: 2700.0, to: 2850.0, dx: 0.2, dy: 70.2, dw: 70.2, why: pa_why_send },
  { drive: "send-quote-wide", what: Key("ground nodes alone"), from: 2700.0, to: 3017.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-wide", what: Key("ground old alone"), from: 2700.0, to: 3017.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-wide", what: Key("ring old alone"), from: 2700.0, to: 2950.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "send-quote-wide", what: Key("words 「Claude：先登录 gh。」"), from: 2750.0, to: 2833.0, dx: 88.0, dy: 8.1, dw: 0.2, why: pa_why_send },
  { drive: "send-quote-wide", what: Key("words 「这一步写进文档」"), from: 2750.0, to: 2833.0, dx: 88.0, dy: 8.1, dw: 0.2, why: pa_why_send },
  { drive: "send-quote-wide", what: Key("nodes alone 「Claude：先登录 gh。」"), from: 2850.0, to: 3067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-wide", what: Key("nodes alone 「这一步写进文档」"), from: 2850.0, to: 3067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-wide", what: Key("nodes alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 2850.0, to: 2883.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-wide", what: Key("old alone 「Claude：先登录 gh。」"), from: 2850.0, to: 3067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-wide", what: Key("old alone 「这一步写进文档」"), from: 2850.0, to: 3067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-wide", what: Key("ground"), from: 2867.0, to: 3250.0, dx: 276.2, dy: 78.6, dw: 553.8, why: pa_why_send },
  { drive: "send-quote-wide", what: Key("ground alpha"), from: 2867.0, to: 2917.0, dx: 0.2, dy: 0.2, dw: 1.1, why: pa_why_send },
  { drive: "send-quote-wide", what: Key("old alone 「Claude」"), from: 2867.0, to: 2883.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-wide", what: Rows, from: 2883.0, to: 3133.0, dx: pa_way_tol, dy: 16.2, dw: pa_way_tol, why: pa_why_send },
  { drive: "send-quote-wide", what: Key("nodes alone 「等 林 决定」"), from: 2950.0, to: 2950.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-wide", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 2950.0, to: 2950.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-wide", what: Key("nodes alone 「处理中」"), from: 2967.0, to: 2983.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-wide", what: Key("ring"), from: 2967.0, to: 3117.0, dx: 5.4, dy: 11.2, dw: 10.5, why: pa_why_send },
  { drive: "send-quote-wide", what: Key("ring alpha"), from: 2967.0, to: 3067.0, dx: 0.2, dy: 0.2, dw: 1.1, why: pa_why_send },
  { drive: "send-quote-wide", what: Key("old alone 「先不换」"), from: 2983.0, to: 3000.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-wide", what: Key("old alone 「等 林 决定」"), from: 2983.0, to: 3017.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-wide", what: Key("alpha 「处理中」"), from: 3000.0, to: 3067.0, dx: 0.2, dy: 0.2, dw: 0.7, why: pa_why_working },
  { drive: "send-quote-wide", what: Key("words 「处理中」"), from: 3000.0, to: 3117.0, dx: 7.7, dy: 13.5, dw: 9.5, why: pa_why_working },
  { drive: "send-quote-wide", what: Key("ground alpha"), from: 3033.0, to: 3133.0, dx: 0.2, dy: 0.2, dw: 0.7, why: pa_why_send },
  { drive: "send-quote-wide", what: Key("old alone 「这次只改列表，截图下次再说」"), from: 3033.0, to: 3067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-wide", what: Key("words 「Claude：先登录 gh。」"), from: 3083.0, to: 3250.0, dx: 67.4, dy: 51.8, dw: 0.2, why: pa_why_send },
  { drive: "send-quote-wide", what: Key("words 「这一步写进文档」"), from: 3083.0, to: 3250.0, dx: 67.4, dy: 51.8, dw: 0.2, why: pa_why_send },
  { drive: "send-quote-wide", what: Key("old alone 「刚刚」"), from: 3117.0, to: 3200.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "desk-send-text-and-multiline", what: Key("nodes alone 「发布前再看一眼签名」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("words 「发布前再看一眼签名」"), from: 1900.0, to: 2000.0, dx: 91.1, dy: 6.9, dw: 0.2, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("nodes alone 「发布前再看一眼签名」"), from: 2017.0, to: 2233.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("old alone 「发布前再看一眼签名」"), from: 2017.0, to: 2233.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("old alone 「发消息」"), from: 2033.0, to: 2117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("ground"), from: 2050.0, to: 2417.0, dx: 68.8, dy: 50.4, dw: 0.2, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Rows, from: 2050.0, to: 2300.0, dx: pa_way_tol, dy: 15.7, dw: pa_way_tol, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("ground nodes alone"), from: 2067.0, to: 2233.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("old alone 「30 分钟前」"), from: 2117.0, to: 2117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("old alone 「Claude」"), from: 2117.0, to: 2267.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("nodes alone 「Claude」"), from: 2133.0, to: 2150.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("ground old alone"), from: 2150.0, to: 2233.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 2167.0, to: 2183.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("nodes alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 2200.0, to: 2250.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("words 「发布前再看一眼签名」"), from: 2250.0, to: 2417.0, dx: 68.6, dy: 50.5, dw: 0.2, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("old alone 「等 林 决定」"), from: 2300.0, to: 2383.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("ring old alone"), from: 2550.0, to: 2600.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "desk-send-text-and-multiline", what: Key("old alone 「0s」"), from: 2567.0, to: 2600.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-send-text-and-multiline", what: Key("alpha 「0s」"), from: 2617.0, to: 2683.0, dx: 0.2, dy: 0.2, dw: 0.8, why: pa_why_working },
  { drive: "desk-send-text-and-multiline", what: Key("ring"), from: 2617.0, to: 2633.0, dx: 5.1, dy: 1.2, dw: 10.0, why: pa_why_working },
  { drive: "desk-send-text-and-multiline", what: Key("ring alpha"), from: 2617.0, to: 2683.0, dx: 0.2, dy: 0.2, dw: 1.0, why: pa_why_working },
  { drive: "desk-send-text-and-multiline", what: Key("words 「0s」"), from: 2617.0, to: 2683.0, dx: 30.1, dy: 3.1, dw: 5.1, why: pa_why_working },
  { drive: "desk-send-text-and-multiline", what: Key("old alone 「先不换」"), from: 2650.0, to: 2650.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-send-text-and-multiline", what: Key("old alone 「等 林 决定」"), from: 2650.0, to: 2650.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-send-text-and-multiline", what: Key("nodes alone 「处理中」"), from: 2667.0, to: 2667.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-send-text-and-multiline", what: Key("alpha 「处理中」"), from: 2683.0, to: 2683.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_working },
  { drive: "desk-send-text-and-multiline", what: Key("words 「0s」"), from: 3967.0, to: 3983.0, dx: 36.2, dy: 0.2, dw: 3.0, why: pa_why_working },
  { drive: "desk-send-text-and-multiline", what: Key("words 「处理中」"), from: 3967.0, to: 3967.0, dx: 0.2, dy: 0.2, dw: 17.0, why: pa_why_working },
  { drive: "desk-send-text-and-multiline", what: Key("nodes alone 「处理中」"), from: 3983.0, to: 4033.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-send-text-and-multiline", what: Key("nodes alone 「0s」"), from: 4000.0, to: 4033.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-send-text-and-multiline", what: Key("old alone 「处理中」"), from: 4050.0, to: 4050.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-send-text-and-multiline", what: Key("ring old alone"), from: 4133.0, to: 5183.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "desk-send-text-and-multiline", what: Key("old alone 「Claude」"), from: 4550.0, to: 4550.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_float },
  { drive: "desk-send-text-and-multiline", what: Key("alpha 「Claude」"), from: 4567.0, to: 4583.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("alpha 「刚刚」"), from: 4567.0, to: 4583.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_timein },
  { drive: "desk-send-text-and-multiline", what: Key("nodes alone 「收到：「发布前再看一眼签名」。我先看一下，有结果再告诉你。」"), from: 4567.0, to: 4683.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_spit },
  { drive: "desk-send-text-and-multiline", what: Key("words 「Claude」"), from: 4567.0, to: 4567.0, dx: 7.0, dy: 0.2, dw: 0.2, why: pa_why_float },
  { drive: "desk-send-text-and-multiline", what: Key("words 「刚刚」"), from: 4567.0, to: 4567.0, dx: 7.0, dy: 0.2, dw: 0.2, why: pa_why_float },
  { drive: "desk-send-text-and-multiline", what: Key("button @asks.go nodes alone"), from: 4967.0, to: 5400.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-send-text-and-multiline", what: Key("nodes alone 「先看一下签名⏎再看发布说明⏎最后核对版本号」"), from: 4967.0, to: 4967.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("button @outline"), from: 4983.0, to: 5317.0, dx: 0.2, dy: 22.2, dw: 0.2, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("composer"), from: 4983.0, to: 5133.0, dx: 0.2, dy: 44.2, dw: 44.2, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("old alone 「先看一下签名⏎再看发布说明⏎最后核对版本号」"), from: 4983.0, to: 5667.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("words 「先看一下签名⏎再看发布说明⏎最后核对版本号」"), from: 5017.0, to: 5117.0, dx: 95.2, dy: 6.9, dw: 0.2, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("nodes alone 「先看一下签名⏎再看发布说明⏎最后核对版本号」"), from: 5133.0, to: 5367.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("ground"), from: 5167.0, to: 5533.0, dx: 60.7, dy: 43.1, dw: 0.2, why: pa_why_bell },
  { drive: "desk-send-text-and-multiline", what: Key("words 「刚刚」"), from: 5167.0, to: 5417.0, dx: 9.7, dy: 15.7, dw: 9.7, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Rows, from: 5167.0, to: 5417.0, dx: pa_way_tol, dy: 15.7, dw: pa_way_tol, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("ground nodes alone"), from: 5183.0, to: 5367.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-send-text-and-multiline", what: Key("old alone 「发消息」"), from: 5200.0, to: 5267.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-send-text-and-multiline", what: Key("ground old alone"), from: 5267.0, to: 5400.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-send-text-and-multiline", what: Key("old alone 「忽略」"), from: 5283.0, to: 5333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-send-text-and-multiline", what: Key("old alone 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 5333.0, to: 5383.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-send-text-and-multiline", what: Key("words 「先看一下签名⏎再看发布说明⏎最后核对版本号」"), from: 5383.0, to: 5533.0, dx: 60.5, dy: 43.2, dw: 0.2, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("ring old alone"), from: 5667.0, to: 5717.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "desk-send-text-and-multiline", what: Key("old alone 「0s」"), from: 5683.0, to: 5717.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-send-text-and-multiline", what: Key("alpha 「0s」"), from: 5733.0, to: 5800.0, dx: 0.2, dy: 0.2, dw: 0.8, why: pa_why_working },
  { drive: "desk-send-text-and-multiline", what: Key("ring"), from: 5733.0, to: 5750.0, dx: 5.1, dy: 0.7, dw: 10.0, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("ring alpha"), from: 5733.0, to: 5800.0, dx: 0.2, dy: 0.2, dw: 1.0, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("words 「0s」"), from: 5733.0, to: 5800.0, dx: 30.1, dy: 3.6, dw: 5.1, why: pa_why_working },
  { drive: "desk-send-text-and-multiline", what: Key("nodes alone 「处理中」"), from: 5783.0, to: 5783.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("alpha 「处理中」"), from: 5800.0, to: 5800.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_working },
  { drive: "desk-send-text-and-multiline", what: Key("old alone 「15 分钟前」"), from: 5850.0, to: 5850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("old alone 「Claude」"), from: 5867.0, to: 5883.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("words 「0s」"), from: 7083.0, to: 7100.0, dx: 36.2, dy: 0.2, dw: 3.0, why: pa_why_working },
  { drive: "desk-send-text-and-multiline", what: Key("words 「处理中」"), from: 7083.0, to: 7083.0, dx: 0.2, dy: 0.2, dw: 17.0, why: pa_why_working },
  { drive: "desk-send-text-and-multiline", what: Key("nodes alone 「处理中」"), from: 7100.0, to: 7150.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-send-text-and-multiline", what: Key("nodes alone 「0s」"), from: 7117.0, to: 7150.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-send-text-and-multiline", what: Key("old alone 「处理中」"), from: 7167.0, to: 7167.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-send-text-and-multiline", what: Key("nodes alone 「刚刚」"), from: 1950.0, to: 2550.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "desk-send-text-and-multiline", what: Key("nodes alone 「刚刚」"), from: 5067.0, to: 5667.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "desk-send-text-and-multiline", what: Key("ground nodes alone"), from: 4267.0, to: 4300.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("words 「发布前再看一眼签名」"), from: 4150.0, to: 4450.0, dx: 0.2, dy: 22.2, dw: 0.2, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("words 「刚刚」"), from: 4150.0, to: 4450.0, dx: 0.2, dy: 22.2, dw: 0.2, why: pa_why_timein },
  { drive: "desk-send-text-and-multiline", what: Key("words 「Claude」"), from: 4150.0, to: 4450.0, dx: 0.2, dy: 22.2, dw: 0.2, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("words 「5 分钟前」"), from: 4150.0, to: 4450.0, dx: 0.2, dy: 22.2, dw: 0.2, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("words 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 4150.0, to: 4450.0, dx: 0.2, dy: 22.2, dw: 0.2, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("words 「15 分钟前」"), from: 4150.0, to: 4450.0, dx: 0.2, dy: 22.2, dw: 0.2, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("words 「推送截图前要先登录 gh。」"), from: 4150.0, to: 4450.0, dx: 0.2, dy: 22.2, dw: 0.2, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("words 「在 Willow 上登录 gh」"), from: 4150.0, to: 4450.0, dx: 0.2, dy: 22.2, dw: 0.2, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("words 「等你在浏览器里登录」"), from: 4150.0, to: 4450.0, dx: 0.2, dy: 22.2, dw: 0.2, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("words 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 4150.0, to: 4450.0, dx: 0.2, dy: 22.2, dw: 0.2, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("words 「一起换」"), from: 4150.0, to: 4250.0, dx: 0.2, dy: 21.7, dw: 0.2, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("words 「把首页和聊天页的截图都更新」"), from: 4150.0, to: 4300.0, dx: 0.2, dy: 22.2, dw: 0.2, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("words 「忽略」"), from: 4150.0, to: 4450.0, dx: 0.2, dy: 22.2, dw: 0.2, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("nodes alone 「这次只改列表，截图下次再说」"), from: 4150.0, to: 4217.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("ground"), from: 4150.0, to: 4450.0, dx: 0.2, dy: 22.2, dw: 21.7, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("nodes alone 「一起换」"), from: 4267.0, to: 4300.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-send-text-and-multiline", what: Key("nodes alone 「把首页和聊天页的截图都更新」"), from: 4317.0, to: 4367.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-notice-card-viewer", what: Key("ground"), from: 833.0, to: 950.0, dx: 15.6, dy: 20.7, dw: 61.9, why: pa_why_card },
  { drive: "desk-notice-card-viewer", what: Key("ring old alone"), from: 833.0, to: 883.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "desk-notice-card-viewer", what: Key("words 「一起换」"), from: 833.0, to: 967.0, dx: 16.5, dy: 16.6, dw: 139.3, why: pa_why_card },
  { drive: "desk-notice-card-viewer", what: Key("words 「把首页和聊天页的截图都更新」"), from: 833.0, to: 850.0, dx: 9.4, dy: 16.8, dw: 79.5, why: pa_why_card },
  { drive: "desk-notice-card-viewer", what: Rows, from: 833.0, to: 950.0, dx: pa_way_tol, dy: 20.7, dw: pa_way_tol, why: pa_why_card },
  { drive: "desk-notice-card-viewer", what: Key("alpha 「一起换」"), from: 850.0, to: 933.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_card },
  { drive: "desk-notice-card-viewer", what: Key("alpha 「把首页和聊天页的截图都更新」"), from: 850.0, to: 850.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_card },
  { drive: "desk-notice-card-viewer", what: Key("alpha 「等 林 决定」"), from: 850.0, to: 867.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_card },
  { drive: "desk-notice-card-viewer", what: Key("ground alpha"), from: 850.0, to: 933.0, dx: 0.2, dy: 0.2, dw: 0.2, why: pa_why_card },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「0s」"), from: 850.0, to: 883.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-notice-card-viewer", what: Key("nodes alone 「把首页和聊天页的截图都更新」"), from: 867.0, to: 867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「一起换」"), from: 883.0, to: 883.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「先不换」"), from: 883.0, to: 883.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「把首页和聊天页的截图都更新」"), from: 883.0, to: 883.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「等 林 决定」"), from: 883.0, to: 883.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「这次只改列表，截图下次再说」"), from: 883.0, to: 883.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "desk-notice-card-viewer", what: Key("alpha 「0s」"), from: 900.0, to: 967.0, dx: 0.2, dy: 0.2, dw: 0.7, why: pa_why_working },
  { drive: "desk-notice-card-viewer", what: Key("nodes alone 「一起换」"), from: 900.0, to: 900.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "desk-notice-card-viewer", what: Key("nodes alone 「你 选择了「一起换」」"), from: 900.0, to: 1067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "desk-notice-card-viewer", what: Key("nodes alone 「刚刚」"), from: 900.0, to: 900.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-notice-card-viewer", what: Key("ring"), from: 900.0, to: 917.0, dx: 4.9, dy: 1.2, dw: 9.5, why: pa_why_working },
  { drive: "desk-notice-card-viewer", what: Key("ring alpha"), from: 900.0, to: 983.0, dx: 0.2, dy: 0.2, dw: 1.0, why: pa_why_working },
  { drive: "desk-notice-card-viewer", what: Key("words 「0s」"), from: 900.0, to: 967.0, dx: 28.5, dy: 2.7, dw: 4.9, why: pa_why_working },
  { drive: "desk-notice-card-viewer", what: Key("alpha 「刚刚」"), from: 917.0, to: 933.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_timein },
  { drive: "desk-notice-card-viewer", what: Key("words 「刚刚」"), from: 917.0, to: 950.0, dx: 6.6, dy: 11.4, dw: 6.6, why: pa_why_working },
  { drive: "desk-notice-card-viewer", what: Key("nodes alone 「处理中」"), from: 933.0, to: 950.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "desk-notice-card-viewer", what: Key("alpha 「处理中」"), from: 967.0, to: 983.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_working },
  { drive: "desk-notice-card-viewer", what: Key("alpha 「你 选择了「一起换」」"), from: 1083.0, to: 1200.0, dx: 0.2, dy: 0.2, dw: 1.1, why: pa_why_card },
  { drive: "desk-notice-card-viewer", what: Key("words 「0s」"), from: 2233.0, to: 2250.0, dx: 36.2, dy: 0.2, dw: 3.0, why: pa_why_working },
  { drive: "desk-notice-card-viewer", what: Key("words 「处理中」"), from: 2233.0, to: 2233.0, dx: 0.2, dy: 0.2, dw: 17.0, why: pa_why_working },
  { drive: "desk-notice-card-viewer", what: Key("nodes alone 「处理中」"), from: 2250.0, to: 2300.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-notice-card-viewer", what: Key("nodes alone 「0s」"), from: 2267.0, to: 2300.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「处理中」"), from: 2317.0, to: 2317.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-notice-card-viewer", what: Key("ring old alone"), from: 2400.0, to: 3350.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「Claude」"), from: 2817.0, to: 2817.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_float },
  { drive: "desk-notice-card-viewer", what: Key("alpha 「Claude」"), from: 2833.0, to: 2850.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_send },
  { drive: "desk-notice-card-viewer", what: Key("alpha 「刚刚」"), from: 2833.0, to: 2850.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_timein },
  { drive: "desk-notice-card-viewer", what: Key("nodes alone 「好，按「一起换」来。」"), from: 2833.0, to: 2933.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_spit },
  { drive: "desk-notice-card-viewer", what: Key("words 「Claude」"), from: 2833.0, to: 2833.0, dx: 7.0, dy: 0.2, dw: 0.2, why: pa_why_float },
  { drive: "desk-notice-card-viewer", what: Key("words 「刚刚」"), from: 2833.0, to: 2833.0, dx: 7.0, dy: 0.2, dw: 0.2, why: pa_why_float },
  { drive: "desk-notice-card-viewer", what: Key("button @outline nodes alone"), from: 3333.0, to: 3333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("button 跳到最新 nodes alone"), from: 3333.0, to: 3333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「你 选择了「一起换」」"), from: 3333.0, to: 3333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "desk-notice-card-viewer", what: Key("nodes alone 「.log」"), from: 3450.0, to: 3450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("nodes alone 「build」"), from: 3450.0, to: 3450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("nodes alone 「发送到」"), from: 3450.0, to: 3450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("nodes alone 「对比图和构建日志附在下面。」"), from: 3450.0, to: 3450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「1 小时前」"), from: 3450.0, to: 3450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「15 分钟前」"), from: 3450.0, to: 3450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「30 分钟前」"), from: 3450.0, to: 3450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「40 分钟前」"), from: 3450.0, to: 3450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「Claude」"), from: 3450.0, to: 3450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「Claude：其余的行按估计的高度占位，滚到时再量真实高度」"), from: 3450.0, to: 3450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 3450.0, to: 3450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「一起换」"), from: 3450.0, to: 3450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「你 选择了「一起换」」"), from: 3450.0, to: 3450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「发布清单 第三项已经核对完：安装包签名正确。」"), from: 3450.0, to: 3450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「发送到」"), from: 3450.0, to: 3450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「在 Willow 上登录 gh」"), from: 3450.0, to: 3450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「推送截图前要先登录 gh。」"), from: 3450.0, to: 3450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「星火#发布」"), from: 3450.0, to: 3450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「等你在浏览器里登录」"), from: 3450.0, to: 3450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「还有深色模式也看一下」"), from: 3450.0, to: 3450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「这里的高度是怎么估的？」"), from: 3450.0, to: 3450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 3450.0, to: 3450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Rows, from: 3450.0, to: 3450.0, dx: pa_way_tol, dy: 46.7, dw: pa_way_tol, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("button @asks.go nodes alone"), from: 3567.0, to: 3567.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-notice-card-viewer", what: Key("nodes alone 「.log」"), from: 3567.0, to: 3567.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("nodes alone 「build」"), from: 3567.0, to: 3567.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("nodes alone 「对比图和构建日志附在下面。」"), from: 3567.0, to: 3567.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「.log」"), from: 3567.0, to: 3567.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「1 小时前」"), from: 3567.0, to: 3567.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「18 KB」"), from: 3567.0, to: 3567.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「30 分钟前」"), from: 3567.0, to: 3567.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「40 分钟前」"), from: 3567.0, to: 3567.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「Claude」"), from: 3567.0, to: 3567.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「Claude：其余的行按估计的高度占位，滚到时再量真实高度」"), from: 3567.0, to: 3567.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「build」"), from: 3567.0, to: 3567.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「发布清单 第三项已经核对完：安装包签名正确。」"), from: 3567.0, to: 3567.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「发送到」"), from: 3567.0, to: 3567.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「对比图和构建日志附在下面。」"), from: 3567.0, to: 3567.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「星火#发布」"), from: 3567.0, to: 3567.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「还有深色模式也看一下」"), from: 3567.0, to: 3567.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「这里的高度是怎么估的？」"), from: 3567.0, to: 3567.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 3567.0, to: 3567.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "desk-notice-card-viewer", what: Key("old alone 「忽略」"), from: 850.0, to: 850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-notice-card-viewer", what: Key("words 「忽略」"), from: 867.0, to: 867.0, dx: 0.2, dy: 34.0, dw: 0.2, why: pa_why_send },
  { drive: "desk-notice-card-viewer", what: Key("words 「一起换」"), from: 2417.0, to: 2700.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_send },
  { drive: "desk-notice-card-viewer", what: Key("words 「刚刚」"), from: 2417.0, to: 2700.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_timein },
  { drive: "desk-notice-card-viewer", what: Key("words 「Claude」"), from: 2417.0, to: 2700.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_send },
  { drive: "desk-notice-card-viewer", what: Key("words 「5 分钟前」"), from: 2417.0, to: 2700.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_send },
  { drive: "desk-notice-card-viewer", what: Key("words 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 2417.0, to: 2700.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_send },
  { drive: "desk-notice-card-viewer", what: Key("words 「15 分钟前」"), from: 2417.0, to: 2700.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_send },
  { drive: "desk-notice-card-viewer", what: Key("words 「推送截图前要先登录 gh。」"), from: 2417.0, to: 2700.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_send },
  { drive: "desk-notice-card-viewer", what: Key("words 「在 Willow 上登录 gh」"), from: 2417.0, to: 2700.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_send },
  { drive: "desk-notice-card-viewer", what: Key("words 「等你在浏览器里登录」"), from: 2417.0, to: 2700.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_send },
  { drive: "desk-notice-card-viewer", what: Key("words 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 2417.0, to: 2700.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_send },
  { drive: "desk-notice-card-viewer", what: Key("words 「30 分钟前」"), from: 2417.0, to: 2700.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_send },
  { drive: "desk-notice-card-viewer", what: Key("words 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 2417.0, to: 2700.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_send },
  { drive: "desk-notice-card-viewer", what: Key("words 「你 选择了「一起换」」"), from: 2417.0, to: 2700.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_send },
  { drive: "desk-notice-card-viewer", what: Key("ground"), from: 2417.0, to: 2700.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_send },
  { drive: "send", what: Key("nodes alone 「发布前再看一眼签名」"), from: 1917.0, to: 1917.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send", what: Key("words 「发布前再看一眼签名」"), from: 2033.0, to: 2300.0, dx: 24.7, dy: 28.3, dw: 0.2, why: pa_why_send },
  { drive: "send", what: Key("ground nodes alone"), from: 2083.0, to: 2083.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send", what: Key("nodes alone 「还有深色模式也看一下」"), from: 2083.0, to: 2083.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send", what: Key("ground"), from: 2100.0, to: 2300.0, dx: 24.6, dy: 28.6, dw: 0.2, why: pa_why_send },
  { drive: "send", what: Key("old alone 「发消息」"), from: 2100.0, to: 2117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send", what: Rows, from: 2100.0, to: 2250.0, dx: pa_way_tol, dy: 23.7, dw: pa_way_tol, why: pa_why_send },
  { drive: "send", what: Key("nodes alone 「40 分钟前」"), from: 2150.0, to: 2183.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send", what: Key("nodes alone 「30 分钟前」"), from: 2317.0, to: 2317.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send", what: Key("nodes alone 「Claude」"), from: 2317.0, to: 2333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send", what: Key("ring old alone"), from: 2617.0, to: 2667.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "send", what: Key("old alone 「0s」"), from: 2633.0, to: 2667.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send", what: Key("alpha 「0s」"), from: 2683.0, to: 2750.0, dx: 0.2, dy: 0.2, dw: 0.8, why: pa_why_working },
  { drive: "send", what: Key("ring"), from: 2683.0, to: 2700.0, dx: 5.1, dy: 1.3, dw: 10.0, why: pa_why_working },
  { drive: "send", what: Key("ring alpha"), from: 2683.0, to: 2750.0, dx: 0.2, dy: 0.2, dw: 1.0, why: pa_why_working },
  { drive: "send", what: Key("words 「0s」"), from: 2683.0, to: 2750.0, dx: 31.4, dy: 3.1, dw: 5.5, why: pa_why_working },
  { drive: "send", what: Key("nodes alone 「处理中」"), from: 2733.0, to: 2733.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send", what: Key("alpha 「处理中」"), from: 2750.0, to: 2750.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_working },
  { drive: "send", what: Key("old alone 「30 分钟前」"), from: 2750.0, to: 2750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send", what: Key("old alone 「Claude」"), from: 2750.0, to: 2750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send", what: Key("words 「0s」"), from: 4033.0, to: 4050.0, dx: 39.2, dy: 0.2, dw: 2.8, why: pa_why_working },
  { drive: "send", what: Key("words 「处理中」"), from: 4033.0, to: 4033.0, dx: 0.2, dy: 0.2, dw: 18.2, why: pa_why_working },
  { drive: "send", what: Key("nodes alone 「处理中」"), from: 4050.0, to: 4100.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send", what: Key("nodes alone 「0s」"), from: 4067.0, to: 4100.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send", what: Key("old alone 「处理中」"), from: 4117.0, to: 4117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send", what: Key("ring old alone"), from: 4200.0, to: 4433.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "send", what: Key("nodes alone 「等 林 决定」"), from: 4267.0, to: 4317.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_spit },
  { drive: "send", what: Key("nodes alone 「刚刚」"), from: 2017.0, to: 2450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "send", what: Key("nodes alone 「发消息」"), from: 2133.0, to: 2150.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send", what: Key("words 「发布前再看一眼签名」"), from: 4217.0, to: 4433.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_send },
  { drive: "send", what: Key("words 「刚刚」"), from: 4217.0, to: 4433.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_timein },
  { drive: "send", what: Key("words 「Claude」"), from: 4217.0, to: 4433.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_send },
  { drive: "send", what: Key("words 「5 分钟前」"), from: 4217.0, to: 4433.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_send },
  { drive: "send", what: Key("words 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 4217.0, to: 4433.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_send },
  { drive: "send", what: Key("words 「15 分钟前」"), from: 4217.0, to: 4433.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_send },
  { drive: "send", what: Key("words 「推送截图前要先登录 gh。」"), from: 4217.0, to: 4433.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_send },
  { drive: "send", what: Key("words 「在 Willow 上登录 gh」"), from: 4217.0, to: 4433.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_send },
  { drive: "send", what: Key("words 「等你在浏览器里登录」"), from: 4217.0, to: 4433.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_send },
  { drive: "send", what: Key("words 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 4217.0, to: 4433.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_send },
  { drive: "send", what: Key("words 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 4217.0, to: 4317.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_send },
  { drive: "send", what: Key("words 「等 林 决定」"), from: 4217.0, to: 4250.0, dx: 0.2, dy: 24.2, dw: 0.2, why: pa_why_send },
  { drive: "send", what: Key("words 「等 林 决定」"), from: 4333.0, to: 4433.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_send },
  { drive: "send", what: Key("words 「先不换」"), from: 4217.0, to: 4433.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_send },
  { drive: "send", what: Key("words 「这次只改列表，截图下次再说」"), from: 4217.0, to: 4433.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_send },
  { drive: "send", what: Key("words 「一起换」"), from: 4217.0, to: 4433.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_send },
  { drive: "send", what: Key("words 「把首页和聊天页的截图都更新」"), from: 4217.0, to: 4433.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_send },
  { drive: "send", what: Key("words 「忽略」"), from: 4217.0, to: 4433.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_send },
  { drive: "send", what: Key("ground"), from: 4217.0, to: 4433.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_send },
  { drive: "send", what: Key("nodes alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 4333.0, to: 4433.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-lines", what: Key("nodes alone 「40 分钟前」"), from: 1350.0, to: 1350.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_lines },
  { drive: "send-lines", what: Key("nodes alone 「先看一下签名⏎再看发布说明⏎最后核对版本号」"), from: 1983.0, to: 1983.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-lines", what: Key("composer"), from: 2000.0, to: 2117.0, dx: 0.2, dy: 49.5, dw: 49.7, why: pa_why_send },
  { drive: "send-lines", what: Key("old alone 「先看一下签名⏎再看发布说明⏎最后核对版本号」"), from: 2000.0, to: 2517.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-lines", what: Key("words 「先看一下签名⏎再看发布说明⏎最后核对版本号」"), from: 2100.0, to: 2367.0, dx: 28.4, dy: 28.3, dw: 0.2, why: pa_why_send },
  { drive: "send-lines", what: Key("ground"), from: 2167.0, to: 2367.0, dx: 28.3, dy: 28.6, dw: 0.2, why: pa_why_send },
  { drive: "send-lines", what: Rows, from: 2167.0, to: 2317.0, dx: pa_way_tol, dy: 23.7, dw: pa_way_tol, why: pa_why_send },
  { drive: "send-lines", what: Key("nodes alone 「30 分钟前」"), from: 2200.0, to: 2333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-lines", what: Key("nodes alone 「Claude」"), from: 2200.0, to: 2333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-lines", what: Key("old alone 「30 分钟前」"), from: 2250.0, to: 2250.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-lines", what: Key("old alone 「Claude」"), from: 2250.0, to: 2250.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-lines", what: Key("ring old alone"), from: 2683.0, to: 2733.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "send-lines", what: Key("old alone 「0s」"), from: 2700.0, to: 2733.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send-lines", what: Key("alpha 「0s」"), from: 2750.0, to: 2817.0, dx: 0.2, dy: 0.2, dw: 0.8, why: pa_why_working },
  { drive: "send-lines", what: Key("ring"), from: 2750.0, to: 2767.0, dx: 5.1, dy: 1.3, dw: 10.0, why: pa_why_working },
  { drive: "send-lines", what: Key("ring alpha"), from: 2750.0, to: 2817.0, dx: 0.2, dy: 0.2, dw: 1.0, why: pa_why_working },
  { drive: "send-lines", what: Key("words 「0s」"), from: 2750.0, to: 2817.0, dx: 31.4, dy: 3.1, dw: 5.5, why: pa_why_working },
  { drive: "send-lines", what: Key("nodes alone 「处理中」"), from: 2800.0, to: 2800.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send-lines", what: Key("alpha 「处理中」"), from: 2817.0, to: 2817.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_working },
  { drive: "send-lines", what: Key("nodes alone 「等 林 决定」"), from: 2817.0, to: 2817.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send-lines", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 2817.0, to: 2817.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send-lines", what: Key("nodes alone 「刚刚」"), from: 2083.0, to: 2517.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "send-lines", what: Key("words 「发消息」"), from: 2183.0, to: 2217.0, dx: 0.2, dy: 34.5, dw: 0.2, why: pa_why_send },
  { drive: "send-picture", what: Key("nodes alone 「截图和构建日志都在这里，帮我看看第二屏」"), from: 1517.0, to: 1517.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_island },
  { drive: "send-picture", what: Key("words 「18 KB」"), from: 1517.0, to: 1533.0, dx: 2.2, dy: 2.4, dw: 104.7, why: pa_why_send },
  { drive: "send-picture", what: Key("button @asks.go nodes alone"), from: 1533.0, to: 2267.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "send-picture", what: Key("composer"), from: 1533.0, to: 1650.0, dx: 0.2, dy: 108.7, dw: 109.0, why: pa_why_send },
  { drive: "send-picture", what: Key("ground"), from: 1533.0, to: 1950.0, dx: 19.0, dy: 100.5, dw: 98.7, why: pa_why_island },
  { drive: "send-picture", what: Key("picture"), from: 1533.0, to: 1967.0, dx: 0.2, dy: 80.1, dw: 36.3, why: pa_why_island },
  { drive: "send-picture", what: Key("words 「.log」"), from: 1650.0, to: 1950.0, dx: 18.9, dy: 55.5, dw: 0.2, why: pa_why_send },
  { drive: "send-picture", what: Key("words 「18 KB」"), from: 1650.0, to: 1950.0, dx: 18.9, dy: 55.5, dw: 0.2, why: pa_why_send },
  { drive: "send-picture", what: Key("words 「build」"), from: 1650.0, to: 1950.0, dx: 18.9, dy: 55.5, dw: 0.2, why: pa_why_send },
  { drive: "send-picture", what: Key("words 「截图和构建日志都在这里，帮我看看第二屏」"), from: 1650.0, to: 1950.0, dx: 6.4, dy: 56.7, dw: 0.2, why: pa_why_send },
  { drive: "send-picture", what: Key("old alone 「发消息」"), from: 1683.0, to: 1733.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "send-picture", what: Rows, from: 1683.0, to: 1917.0, dx: pa_way_tol, dy: 79.7, dw: pa_way_tol, why: pa_why_send },
  { drive: "send-picture", what: Key("old alone 「30 分钟前」"), from: 1700.0, to: 1700.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "send-picture", what: Key("old alone 「Claude」"), from: 1700.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-picture", what: Key("nodes alone 「30 分钟前」"), from: 1717.0, to: 1733.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-picture", what: Key("nodes alone 「Claude」"), from: 1717.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-picture", what: Key("ground alpha"), from: 1733.0, to: 1783.0, dx: 0.2, dy: 0.2, dw: 0.3, why: pa_why_bell },
  { drive: "send-picture", what: Key("ground nodes alone"), from: 1733.0, to: 1800.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "send-picture", what: Key("ground old alone"), from: 1733.0, to: 1767.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "send-picture", what: Key("nodes alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 1733.0, to: 1767.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-picture", what: Key("nodes alone 「等 林 决定」"), from: 1750.0, to: 1783.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-picture", what: Key("nodes alone 「一起换」"), from: 1783.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-picture", what: Key("nodes alone 「先不换」"), from: 1783.0, to: 1800.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-picture", what: Key("nodes alone 「把首页和聊天页的截图都更新」"), from: 1800.0, to: 1883.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "send-picture", what: Key("nodes alone 「这次只改列表，截图下次再说」"), from: 1817.0, to: 1817.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-picture", what: Key("old alone 「一起换」"), from: 1817.0, to: 1817.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "send-picture", what: Key("old alone 「把首页和聊天页的截图都更新」"), from: 1833.0, to: 1833.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "send-picture", what: Key("nodes alone 「忽略」"), from: 1850.0, to: 1867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "send-picture", what: Key("old alone 「忽略」"), from: 1883.0, to: 1900.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "send-picture", what: Key("old alone 「忽略」"), from: 2217.0, to: 2233.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-picture", what: Key("ring old alone"), from: 2217.0, to: 2267.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "send-picture", what: Key("old alone 「0s」"), from: 2233.0, to: 2267.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send-picture", what: Key("alpha 「0s」"), from: 2283.0, to: 2350.0, dx: 0.2, dy: 0.2, dw: 0.8, why: pa_why_working },
  { drive: "send-picture", what: Key("ring"), from: 2283.0, to: 2300.0, dx: 5.1, dy: 1.3, dw: 10.0, why: pa_why_bell },
  { drive: "send-picture", what: Key("ring alpha"), from: 2283.0, to: 2350.0, dx: 0.2, dy: 0.2, dw: 1.0, why: pa_why_bell },
  { drive: "send-picture", what: Key("words 「0s」"), from: 2283.0, to: 2350.0, dx: 31.4, dy: 3.1, dw: 5.5, why: pa_why_working },
  { drive: "send-picture", what: Key("nodes alone 「处理中」"), from: 2333.0, to: 2333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send-picture", what: Key("alpha 「处理中」"), from: 2350.0, to: 2350.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_working },
  { drive: "send-picture", what: Key("nodes alone 「刚刚」"), from: 2050.0, to: 2050.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "send-quote", what: Key("ground nodes alone"), from: 1367.0, to: 1367.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_menu },
  { drive: "send-quote", what: Key("nodes alone 「全选」"), from: 1367.0, to: 1367.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_menu },
  { drive: "send-quote", what: Key("nodes alone 「复制」"), from: 1367.0, to: 1367.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_menu },
  { drive: "send-quote", what: Key("nodes alone 「引用」"), from: 1367.0, to: 1367.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_menu },
  { drive: "send-quote", what: Key("old alone 「15 分钟前」"), from: 1367.0, to: 1367.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_menu },
  { drive: "send-quote", what: Key("old alone 「Claude」"), from: 1367.0, to: 1367.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_menu },
  { drive: "send-quote", what: Key("old alone 「全选」"), from: 1767.0, to: 1767.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_menu },
  { drive: "send-quote", what: Key("old alone 「复制」"), from: 1767.0, to: 1767.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_menu },
  { drive: "send-quote", what: Key("old alone 「引用」"), from: 1767.0, to: 1767.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_menu },
  { drive: "send-quote", what: Key("ground"), from: 1817.0, to: 1917.0, dx: 0.2, dy: 25.7, dw: 0.2, why: pa_why_send },
  { drive: "send-quote", what: Key("ground old alone"), from: 1817.0, to: 1833.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote", what: Key("old alone 「还有深色模式也看一下」"), from: 1817.0, to: 1833.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote", what: Rows, from: 1817.0, to: 1917.0, dx: pa_way_tol, dy: 25.7, dw: pa_way_tol, why: pa_why_send },
  { drive: "send-quote", what: Key("old alone 「40 分钟前」"), from: 1867.0, to: 1867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote", what: Key("nodes alone 「这一步写进文档」"), from: 3000.0, to: 3017.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote", what: Key("old alone 「添加说明（可选）」"), from: 3000.0, to: 3017.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote", what: Key("composer"), from: 3017.0, to: 3133.0, dx: 0.2, dy: 72.0, dw: 72.2, why: pa_why_send },
  { drive: "send-quote", what: Key("ground"), from: 3017.0, to: 3383.0, dx: 27.7, dy: 25.9, dw: 225.2, why: pa_why_working },
  { drive: "send-quote", what: Key("ground alpha"), from: 3017.0, to: 3333.0, dx: 0.2, dy: 0.2, dw: 1.1, why: pa_why_working },
  { drive: "send-quote", what: Key("ring old alone"), from: 3017.0, to: 3267.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "send-quote", what: Key("words 「Claude：先」"), from: 3133.0, to: 3383.0, dx: 26.5, dy: 26.3, dw: 0.2, why: pa_why_send },
  { drive: "send-quote", what: Key("words 「这一步写进文档」"), from: 3133.0, to: 3383.0, dx: 26.5, dy: 26.3, dw: 0.2, why: pa_why_send },
  { drive: "send-quote", what: Key("nodes alone 「30 分钟前」"), from: 3167.0, to: 3300.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send-quote", what: Key("nodes alone 「Claude」"), from: 3183.0, to: 3300.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send-quote", what: Rows, from: 3183.0, to: 3333.0, dx: pa_way_tol, dy: 22.2, dw: pa_way_tol, why: pa_why_send },
  { drive: "send-quote", what: Key("old alone 「30 分钟前」"), from: 3217.0, to: 3233.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send-quote", what: Key("old alone 「Claude」"), from: 3217.0, to: 3233.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send-quote", what: Key("old alone 「处理中」"), from: 3267.0, to: 3267.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send-quote", what: Key("alpha 「处理中」"), from: 3283.0, to: 3383.0, dx: 0.2, dy: 0.2, dw: 1.1, why: pa_why_working },
  { drive: "send-quote", what: Key("ring"), from: 3283.0, to: 3317.0, dx: 5.4, dy: 10.5, dw: 10.5, why: pa_why_working },
  { drive: "send-quote", what: Key("ring alpha"), from: 3283.0, to: 3383.0, dx: 0.2, dy: 0.2, dw: 1.1, why: pa_why_working },
  { drive: "send-quote", what: Key("words 「处理中」"), from: 3283.0, to: 3350.0, dx: 12.7, dy: 6.6, dw: 17.0, why: pa_why_working },
  { drive: "send-quote", what: Key("old alone 「刚刚」"), from: 3333.0, to: 3517.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "decide", what: Key("nodes alone 「你 选择了「一起换」」"), from: 883.0, to: 1150.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "decide", what: Key("old alone 「一起换」"), from: 883.0, to: 967.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "decide", what: Key("old alone 「先不换」"), from: 883.0, to: 967.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "decide", what: Key("old alone 「忽略」"), from: 883.0, to: 950.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "decide", what: Key("old alone 「把首页和聊天页的截图都更新」"), from: 883.0, to: 967.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "decide", what: Key("old alone 「等 林 决定」"), from: 883.0, to: 967.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "decide", what: Key("old alone 「这次只改列表，截图下次再说」"), from: 883.0, to: 967.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "decide", what: Key("ground"), from: 900.0, to: 1067.0, dx: 1.0, dy: 36.7, dw: 71.9, why: pa_why_card },
  { drive: "decide", what: Key("words 「一起换」"), from: 900.0, to: 1033.0, dx: 16.7, dy: 21.6, dw: 103.1, why: pa_why_card },
  { drive: "decide", what: Key("words 「忽略」"), from: 900.0, to: 933.0, dx: 0.2, dy: 37.5, dw: 125.9, why: pa_why_card },
  { drive: "decide", what: Key("words 「把首页和聊天页的截图都更新」"), from: 900.0, to: 933.0, dx: 16.7, dy: 29.3, dw: 103.1, why: pa_why_card },
  { drive: "decide", what: Rows, from: 900.0, to: 1067.0, dx: pa_way_tol, dy: 36.7, dw: pa_way_tol, why: pa_why_card },
  { drive: "decide", what: Key("alpha 「一起换」"), from: 917.0, to: 1050.0, dx: 0.2, dy: 0.2, dw: 0.8, why: pa_why_card },
  { drive: "decide", what: Key("alpha 「先不换」"), from: 917.0, to: 933.0, dx: 0.2, dy: 0.2, dw: 0.6, why: pa_why_card },
  { drive: "decide", what: Key("alpha 「忽略」"), from: 917.0, to: 933.0, dx: 0.2, dy: 0.2, dw: 0.6, why: pa_why_card },
  { drive: "decide", what: Key("alpha 「把首页和聊天页的截图都更新」"), from: 917.0, to: 933.0, dx: 0.2, dy: 0.2, dw: 0.8, why: pa_why_card },
  { drive: "decide", what: Key("alpha 「等 林 决定」"), from: 917.0, to: 933.0, dx: 0.2, dy: 0.2, dw: 0.8, why: pa_why_card },
  { drive: "decide", what: Key("alpha 「这次只改列表，截图下次再说」"), from: 917.0, to: 933.0, dx: 0.2, dy: 0.2, dw: 0.6, why: pa_why_card },
  { drive: "decide", what: Key("ground alpha"), from: 917.0, to: 1050.0, dx: 0.2, dy: 0.2, dw: 0.2, why: pa_why_card },
  { drive: "decide", what: Key("ring old alone"), from: 917.0, to: 950.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "decide", what: Key("ground old alone"), from: 933.0, to: 933.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "decide", what: Key("old alone 「0s」"), from: 933.0, to: 950.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "decide", what: Key("alpha 「0s」"), from: 967.0, to: 1017.0, dx: 0.2, dy: 0.2, dw: 0.6, why: pa_why_working },
  { drive: "decide", what: Key("nodes alone 「一起换」"), from: 967.0, to: 983.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "decide", what: Key("nodes alone 「刚刚」"), from: 967.0, to: 983.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "decide", what: Key("ring"), from: 967.0, to: 983.0, dx: 4.9, dy: 3.3, dw: 9.5, why: pa_why_card },
  { drive: "decide", what: Key("ring alpha"), from: 967.0, to: 1050.0, dx: 0.2, dy: 0.2, dw: 1.0, why: pa_why_card },
  { drive: "decide", what: Key("words 「0s」"), from: 967.0, to: 1050.0, dx: 29.7, dy: 0.6, dw: 5.2, why: pa_why_working },
  { drive: "decide", what: Key("alpha 「刚刚」"), from: 1000.0, to: 1050.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_timein },
  { drive: "decide", what: Key("ground nodes alone"), from: 1000.0, to: 1000.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "decide", what: Key("nodes alone 「处理中」"), from: 1000.0, to: 1033.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "decide", what: Key("alpha 「处理中」"), from: 1050.0, to: 1050.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_working },
  { drive: "decide", what: Key("alpha 「你 选择了「一起换」」"), from: 1167.0, to: 1283.0, dx: 0.2, dy: 0.2, dw: 1.1, why: pa_why_card },
  { drive: "decide", what: Key("alpha 「0s」"), from: 2300.0, to: 2333.0, dx: 0.2, dy: 0.2, dw: 0.6, why: pa_why_working },
  { drive: "decide", what: Key("alpha 「处理中」"), from: 2300.0, to: 2317.0, dx: 0.2, dy: 0.2, dw: 0.6, why: pa_why_working },
  { drive: "decide", what: Key("words 「0s」"), from: 2317.0, to: 2333.0, dx: 39.2, dy: 0.2, dw: 2.8, why: pa_why_working },
  { drive: "decide", what: Key("words 「处理中」"), from: 2317.0, to: 2317.0, dx: 0.2, dy: 0.2, dw: 18.2, why: pa_why_working },
  { drive: "decide", what: Key("nodes alone 「处理中」"), from: 2333.0, to: 2367.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "decide", what: Key("nodes alone 「0s」"), from: 2350.0, to: 2367.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "decide", what: Key("old alone 「处理中」"), from: 2400.0, to: 2400.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "decide", what: Key("ring old alone"), from: 2467.0, to: 3533.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "decide", what: Key("nodes alone 「刚刚」"), from: 2900.0, to: 2917.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_spit },
  { drive: "decide", what: Key("nodes alone 「好，按「一起换」来。」"), from: 2900.0, to: 3033.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_spit },
  { drive: "decide", what: Key("words 「Claude」"), from: 2900.0, to: 2917.0, dx: 9.3, dy: 0.2, dw: 0.2, why: pa_why_float },
  { drive: "decide", what: Key("words 「一起换」"), from: 2517.0, to: 2750.0, dx: 0.2, dy: 18.7, dw: 0.2, why: pa_why_card },
  { drive: "decide", what: Key("words 「刚刚」"), from: 2517.0, to: 2750.0, dx: 0.2, dy: 18.7, dw: 0.2, why: pa_why_timein },
  { drive: "decide", what: Key("words 「Claude」"), from: 2517.0, to: 2750.0, dx: 0.2, dy: 18.7, dw: 0.2, why: pa_why_card },
  { drive: "decide", what: Key("words 「5 分钟前」"), from: 2517.0, to: 2750.0, dx: 0.2, dy: 18.7, dw: 0.2, why: pa_why_card },
  { drive: "decide", what: Key("words 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 2517.0, to: 2750.0, dx: 0.2, dy: 18.7, dw: 0.2, why: pa_why_card },
  { drive: "decide", what: Key("words 「15 分钟前」"), from: 2517.0, to: 2750.0, dx: 0.2, dy: 18.7, dw: 0.2, why: pa_why_card },
  { drive: "decide", what: Key("words 「推送截图前要先登录 gh。」"), from: 2517.0, to: 2750.0, dx: 0.2, dy: 18.7, dw: 0.2, why: pa_why_card },
  { drive: "decide", what: Key("words 「在 Willow 上登录 gh」"), from: 2517.0, to: 2750.0, dx: 0.2, dy: 18.7, dw: 0.2, why: pa_why_card },
  { drive: "decide", what: Key("words 「等你在浏览器里登录」"), from: 2517.0, to: 2750.0, dx: 0.2, dy: 18.7, dw: 0.2, why: pa_why_card },
  { drive: "decide", what: Key("words 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 2517.0, to: 2750.0, dx: 0.2, dy: 18.7, dw: 0.2, why: pa_why_card },
  { drive: "decide", what: Key("words 「30 分钟前」"), from: 2517.0, to: 2750.0, dx: 0.2, dy: 18.7, dw: 0.2, why: pa_why_card },
  { drive: "decide", what: Key("words 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 2517.0, to: 2750.0, dx: 0.2, dy: 18.7, dw: 0.2, why: pa_why_card },
  { drive: "decide", what: Key("words 「你 选择了「一起换」」"), from: 2517.0, to: 2750.0, dx: 0.2, dy: 18.7, dw: 0.2, why: pa_why_card },
  { drive: "decide", what: Key("words 「还有深色模式也看一下」"), from: 2517.0, to: 2750.0, dx: 0.2, dy: 18.7, dw: 0.2, why: pa_why_card },
  { drive: "decide", what: Key("words 「40 分钟前」"), from: 2517.0, to: 2750.0, dx: 0.2, dy: 18.7, dw: 0.2, why: pa_why_card },
  { drive: "decide", what: Key("ground"), from: 2517.0, to: 2750.0, dx: 0.2, dy: 18.7, dw: 0.2, why: pa_why_card },
  { drive: "answer", what: Key("nodes alone 「看一下列表的高度」"), from: 1917.0, to: 1917.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "answer", what: Key("words 「看一下列表的高度」"), from: 2033.0, to: 2300.0, dx: 26.6, dy: 28.3, dw: 0.2, why: pa_why_send },
  { drive: "answer", what: Key("ground nodes alone"), from: 2083.0, to: 2083.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "answer", what: Key("nodes alone 「还有深色模式也看一下」"), from: 2083.0, to: 2083.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "answer", what: Key("ground"), from: 2100.0, to: 2300.0, dx: 26.7, dy: 28.6, dw: 0.2, why: pa_why_send },
  { drive: "answer", what: Key("old alone 「发消息」"), from: 2100.0, to: 2117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "answer", what: Rows, from: 2100.0, to: 2250.0, dx: pa_way_tol, dy: 23.7, dw: pa_way_tol, why: pa_why_send },
  { drive: "answer", what: Key("nodes alone 「40 分钟前」"), from: 2150.0, to: 2183.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "answer", what: Key("nodes alone 「30 分钟前」"), from: 2317.0, to: 2317.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "answer", what: Key("nodes alone 「Claude」"), from: 2317.0, to: 2333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "answer", what: Key("ring old alone"), from: 2617.0, to: 2667.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "answer", what: Key("old alone 「0s」"), from: 2633.0, to: 2667.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "answer", what: Key("alpha 「0s」"), from: 2683.0, to: 2750.0, dx: 0.2, dy: 0.2, dw: 0.8, why: pa_why_working },
  { drive: "answer", what: Key("ring"), from: 2683.0, to: 2700.0, dx: 5.1, dy: 1.3, dw: 10.0, why: pa_why_working },
  { drive: "answer", what: Key("ring alpha"), from: 2683.0, to: 2750.0, dx: 0.2, dy: 0.2, dw: 1.0, why: pa_why_working },
  { drive: "answer", what: Key("words 「0s」"), from: 2683.0, to: 2750.0, dx: 31.4, dy: 3.1, dw: 5.5, why: pa_why_working },
  { drive: "answer", what: Key("nodes alone 「处理中」"), from: 2733.0, to: 2733.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "answer", what: Key("alpha 「处理中」"), from: 2750.0, to: 2750.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_working },
  { drive: "answer", what: Key("old alone 「30 分钟前」"), from: 2750.0, to: 2750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "answer", what: Key("old alone 「Claude」"), from: 2750.0, to: 2750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "answer", what: Key("words 「0s」"), from: 4033.0, to: 4050.0, dx: 39.2, dy: 0.2, dw: 2.8, why: pa_why_working },
  { drive: "answer", what: Key("words 「处理中」"), from: 4033.0, to: 4033.0, dx: 0.2, dy: 0.2, dw: 18.2, why: pa_why_working },
  { drive: "answer", what: Key("nodes alone 「处理中」"), from: 4050.0, to: 4100.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "answer", what: Key("nodes alone 「0s」"), from: 4067.0, to: 4100.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "answer", what: Key("old alone 「处理中」"), from: 4117.0, to: 4117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "answer", what: Key("ring old alone"), from: 4200.0, to: 5250.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "answer", what: Key("nodes alone 「等 林 决定」"), from: 4267.0, to: 4317.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_spit },
  { drive: "answer", what: Key("old alone 「Claude」"), from: 4617.0, to: 4617.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_float },
  { drive: "answer", what: Key("alpha 「Claude」"), from: 4633.0, to: 4650.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_send },
  { drive: "answer", what: Key("nodes alone 「刚刚」"), from: 4633.0, to: 4633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_float },
  { drive: "answer", what: Key("nodes alone 「收到：「看一下列表的高度」。我先看一下，有结果再告诉你。」"), from: 4633.0, to: 4750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_spit },
  { drive: "answer", what: Key("words 「Claude」"), from: 4633.0, to: 4633.0, dx: 7.0, dy: 0.2, dw: 0.2, why: pa_why_float },
  { drive: "answer", what: Key("alpha 「刚刚」"), from: 4650.0, to: 4650.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_timein },
  { drive: "answer", what: Key("nodes alone 「刚刚」"), from: 2017.0, to: 2450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "answer", what: Key("nodes alone 「发消息」"), from: 2133.0, to: 2150.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "answer", what: Key("words 「看一下列表的高度」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer", what: Key("words 「刚刚」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_timein },
  { drive: "answer", what: Key("words 「Claude」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer", what: Key("words 「5 分钟前」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer", what: Key("words 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer", what: Key("words 「15 分钟前」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer", what: Key("words 「推送截图前要先登录 gh。」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer", what: Key("words 「在 Willow 上登录 gh」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer", what: Key("words 「等你在浏览器里登录」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer", what: Key("words 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer", what: Key("words 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 4217.0, to: 4317.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer", what: Key("words 「等 林 决定」"), from: 4217.0, to: 4250.0, dx: 0.2, dy: 24.2, dw: 0.2, why: pa_why_working },
  { drive: "answer", what: Key("words 「等 林 决定」"), from: 4333.0, to: 4433.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer", what: Key("words 「等 林 决定」"), from: 4533.0, to: 4533.0, dx: 0.2, dy: 6.7, dw: 0.2, why: pa_why_working },
  { drive: "answer", what: Key("words 「先不换」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer", what: Key("words 「这次只改列表，截图下次再说」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer", what: Key("words 「一起换」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer", what: Key("words 「把首页和聊天页的截图都更新」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer", what: Key("words 「忽略」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer", what: Key("ground"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer", what: Key("nodes alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 4333.0, to: 4533.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "answer", what: Key("old alone 「等 林 决定」"), from: 4450.0, to: 4517.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "wide-newchat", what: Key("old alone 「做任何事」"), from: 2750.0, to: 2750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat },
  { drive: "wide-newchat", what: Key("old alone 「想让 agent 做什么？」"), from: 2750.0, to: 2883.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat },
  { drive: "wide-newchat", what: Key("old alone 「描述要做的事。它会在 Willow 上使用所选模型新建会话。」"), from: 2750.0, to: 2883.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat },
  { drive: "wide-newchat", what: Key("words 「把发布说明写一下」"), from: 2767.0, to: 3117.0, dx: 73.2, dy: 13.1, dw: 576.2, why: pa_why_newchat },
  { drive: "wide-newchat", what: Key("ground"), from: 2933.0, to: 3117.0, dx: 73.2, dy: 13.2, dw: 0.2, why: pa_why_newchat },
  { drive: "wide-newchat", what: Key("ring old alone"), from: 3450.0, to: 3500.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "wide-newchat", what: Key("old alone 「0s」"), from: 3467.0, to: 3500.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat },
  { drive: "wide-newchat", what: Key("alpha 「0s」"), from: 3517.0, to: 3583.0, dx: 0.2, dy: 0.2, dw: 0.8, why: pa_why_newchat },
  { drive: "wide-newchat", what: Key("ring"), from: 3517.0, to: 3533.0, dx: 5.1, dy: 1.2, dw: 10.0, why: pa_why_newchat },
  { drive: "wide-newchat", what: Key("ring alpha"), from: 3517.0, to: 3583.0, dx: 0.2, dy: 0.2, dw: 1.0, why: pa_why_newchat },
  { drive: "wide-newchat", what: Key("words 「0s」"), from: 3517.0, to: 3583.0, dx: 30.1, dy: 3.1, dw: 5.1, why: pa_why_newchat },
  { drive: "wide-newchat", what: Key("alpha 「处理中」"), from: 3567.0, to: 3583.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_newchat },
  { drive: "wide-newchat", what: Key("words 「0s」"), from: 4867.0, to: 4883.0, dx: 36.2, dy: 0.2, dw: 3.0, why: pa_why_newchat },
  { drive: "wide-newchat", what: Key("words 「处理中」"), from: 4867.0, to: 4867.0, dx: 0.2, dy: 0.2, dw: 17.0, why: pa_why_newchat },
  { drive: "wide-newchat", what: Key("nodes alone 「处理中」"), from: 4883.0, to: 4933.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat },
  { drive: "wide-newchat", what: Key("nodes alone 「0s」"), from: 4900.0, to: 4933.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat },
  { drive: "wide-newchat", what: Key("old alone 「处理中」"), from: 4950.0, to: 4950.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat },
  { drive: "wide-newchat", what: Key("ring old alone"), from: 5033.0, to: 5767.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "wide-newchat", what: Key("old alone 「Claude」"), from: 5450.0, to: 5450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat },
  { drive: "wide-newchat", what: Key("alpha 「Claude」"), from: 5467.0, to: 5483.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_newchat },
  { drive: "wide-newchat", what: Key("alpha 「刚刚」"), from: 5467.0, to: 5483.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_timein },
  { drive: "wide-newchat", what: Key("nodes alone 「收到：「把发布说明写一下」。我先看一下，有结果再告诉你。」"), from: 5467.0, to: 5583.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat },
  { drive: "wide-newchat", what: Key("words 「Claude」"), from: 5467.0, to: 5467.0, dx: 7.0, dy: 0.2, dw: 0.2, why: pa_why_newchat },
  { drive: "wide-newchat", what: Key("words 「刚刚」"), from: 5467.0, to: 5467.0, dx: 7.0, dy: 0.2, dw: 0.2, why: pa_why_newchat },
  { drive: "wide-newchat", what: Key("nodes alone 「发消息」"), from: 2883.0, to: 2933.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "wide-newchat", what: Key("words 「发消息」"), from: 2767.0, to: 2867.0, dx: 3.9, dy: 8.7, dw: 80.8, why: pa_why_send },
  { drive: "wide-newchat", what: Key("nodes alone 「刚刚」"), from: 2850.0, to: 2983.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "wide-newchat", what: Key("nodes alone 「刚刚」"), from: 3067.0, to: 3283.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "wide-newchat", what: Key("ground"), from: 5050.0, to: 5333.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_send },
  { drive: "wide-newchat", what: Key("words 「把发布说明写一下」"), from: 5050.0, to: 5333.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_send },
  { drive: "wide-newchat", what: Key("words 「刚刚」"), from: 5050.0, to: 5333.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_timein },
  { drive: "newchat-send", what: Key("words 「把发布说明写一下」"), from: 2467.0, to: 2767.0, dx: 104.5, dy: 14.9, dw: 222.2, why: pa_why_newchat },
  { drive: "newchat-send", what: Key("ground"), from: 2733.0, to: 2933.0, dx: 54.7, dy: 52.3, dw: 0.2, why: pa_why_newchat },
  { drive: "newchat-send", what: Key("old alone 「Opus 5.5」"), from: 2450.0, to: 2517.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat },
  { drive: "newchat-send", what: Key("old alone 「Willow」"), from: 2450.0, to: 2517.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat },
  { drive: "newchat-send", what: Key("old alone 「·」"), from: 2450.0, to: 2517.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat },
  { drive: "newchat-send", what: Key("old alone 「做任何事」"), from: 2450.0, to: 2450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat },
  { drive: "newchat-send", what: Key("old alone 「预设」"), from: 2450.0, to: 2517.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat },
  { drive: "newchat-send", what: Key("old alone 「高」"), from: 2450.0, to: 2517.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat },
  { drive: "newchat-send", what: Key("words 「把发布说明写一下」"), from: 2783.0, to: 2933.0, dx: 54.6, dy: 52.2, dw: 0.2, why: pa_why_newchat },
  { drive: "newchat-send", what: Key("ring old alone"), from: 3150.0, to: 3200.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "newchat-send", what: Key("old alone 「0s」"), from: 3167.0, to: 3200.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat },
  { drive: "newchat-send", what: Key("alpha 「0s」"), from: 3217.0, to: 3283.0, dx: 0.2, dy: 0.2, dw: 0.8, why: pa_why_newchat },
  { drive: "newchat-send", what: Key("ring"), from: 3217.0, to: 3233.0, dx: 5.1, dy: 1.3, dw: 10.0, why: pa_why_newchat },
  { drive: "newchat-send", what: Key("ring alpha"), from: 3217.0, to: 3283.0, dx: 0.2, dy: 0.2, dw: 1.0, why: pa_why_newchat },
  { drive: "newchat-send", what: Key("words 「0s」"), from: 3217.0, to: 3283.0, dx: 31.4, dy: 3.1, dw: 5.5, why: pa_why_newchat },
  { drive: "newchat-send", what: Key("alpha 「处理中」"), from: 3267.0, to: 3283.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_newchat },
  { drive: "newchat-send", what: Key("nodes alone 「刚刚」"), from: 2633.0, to: 3067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "newchat-send", what: Key("ground alpha"), from: 2733.0, to: 2767.0, dx: 0.2, dy: 0.2, dw: 0.2, why: pa_why_send },
  { drive: "newchat-send", what: Key("nodes alone 「发消息」"), from: 2767.0, to: 2783.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-newchat-picture", what: Key("old alone 「Opus 5.5」"), from: 1517.0, to: 1583.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat },
  { drive: "send-newchat-picture", what: Key("old alone 「Willow」"), from: 1517.0, to: 1583.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat },
  { drive: "send-newchat-picture", what: Key("old alone 「·」"), from: 1517.0, to: 1583.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat },
  { drive: "send-newchat-picture", what: Key("old alone 「做任何事」"), from: 1517.0, to: 1517.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat },
  { drive: "send-newchat-picture", what: Key("old alone 「预设」"), from: 1517.0, to: 1583.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat },
  { drive: "send-newchat-picture", what: Key("old alone 「高」"), from: 1517.0, to: 1583.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat },
  { drive: "send-newchat-picture", what: Key("picture"), from: 1533.0, to: 2050.0, dx: 0.2, dy: 140.5, dw: 182.0, why: pa_why_newchat },
  { drive: "send-newchat-picture", what: Key("words 「照着这张截图把第二屏改一下」"), from: 1533.0, to: 2000.0, dx: 84.4, dy: 56.4, dw: 147.2, why: pa_why_newchat },
  { drive: "send-newchat-picture", what: Key("nodes alone 「发消息」"), from: 1800.0, to: 1883.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat },
  { drive: "send-newchat-picture", what: Key("ground"), from: 1800.0, to: 2000.0, dx: 58.0, dy: 56.6, dw: 0.2, why: pa_why_newchat },
  { drive: "send-newchat-picture", what: Key("ground alpha"), from: 1800.0, to: 1900.0, dx: 0.2, dy: 0.2, dw: 0.2, why: pa_why_newchat },
  { drive: "send-newchat-picture", what: Key("ring old alone"), from: 2217.0, to: 2267.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "send-newchat-picture", what: Key("old alone 「0s」"), from: 2233.0, to: 2267.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat },
  { drive: "send-newchat-picture", what: Key("alpha 「0s」"), from: 2283.0, to: 2350.0, dx: 0.2, dy: 0.2, dw: 0.8, why: pa_why_newchat },
  { drive: "send-newchat-picture", what: Key("ring"), from: 2283.0, to: 2300.0, dx: 5.1, dy: 1.3, dw: 10.0, why: pa_why_newchat },
  { drive: "send-newchat-picture", what: Key("ring alpha"), from: 2283.0, to: 2350.0, dx: 0.2, dy: 0.2, dw: 1.0, why: pa_why_newchat },
  { drive: "send-newchat-picture", what: Key("words 「0s」"), from: 2283.0, to: 2350.0, dx: 31.4, dy: 3.1, dw: 5.5, why: pa_why_newchat },
  { drive: "send-newchat-picture", what: Key("alpha 「处理中」"), from: 2333.0, to: 2350.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_newchat },
  { drive: "send-newchat-picture", what: Key("words 「0s」"), from: 3633.0, to: 3650.0, dx: 39.2, dy: 0.2, dw: 2.8, why: pa_why_newchat },
  { drive: "send-newchat-picture", what: Key("words 「处理中」"), from: 3633.0, to: 3633.0, dx: 0.2, dy: 0.2, dw: 18.2, why: pa_why_newchat },
  { drive: "send-newchat-picture", what: Key("nodes alone 「处理中」"), from: 3650.0, to: 3700.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat },
  { drive: "send-newchat-picture", what: Key("nodes alone 「0s」"), from: 3667.0, to: 3700.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat },
  { drive: "send-newchat-picture", what: Key("old alone 「处理中」"), from: 3717.0, to: 3717.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_newchat },
  { drive: "send-newchat-picture", what: Key("ring old alone"), from: 3800.0, to: 4033.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "send-newchat-picture", what: Key("ground"), from: 3817.0, to: 4033.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_send },
  { drive: "send-newchat-picture", what: Key("nodes alone 「刚刚」"), from: 2133.0, to: 2133.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "send-newchat-picture", what: Key("words 「照着这张截图把第二屏改一下」"), from: 3817.0, to: 4033.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_send },
  { drive: "send-newchat-picture", what: Key("words 「刚刚」"), from: 3817.0, to: 4033.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_timein },
  { drive: "send-newchat-picture", what: Key("picture"), from: 3817.0, to: 4033.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_send },
  { drive: "wide-send", what: Key("nodes alone 「发布前再看一眼签名」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "wide-send", what: Key("words 「发布前再看一眼签名」"), from: 1900.0, to: 2000.0, dx: 91.1, dy: 6.9, dw: 0.2, why: pa_why_send },
  { drive: "wide-send", what: Key("nodes alone 「发布前再看一眼签名」"), from: 2017.0, to: 2233.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "wide-send", what: Key("old alone 「发布前再看一眼签名」"), from: 2017.0, to: 2233.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "wide-send", what: Key("old alone 「发消息」"), from: 2033.0, to: 2117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "wide-send", what: Key("ground"), from: 2050.0, to: 2417.0, dx: 68.8, dy: 50.4, dw: 0.2, why: pa_why_send },
  { drive: "wide-send", what: Rows, from: 2050.0, to: 2300.0, dx: pa_way_tol, dy: 15.7, dw: pa_way_tol, why: pa_why_send },
  { drive: "wide-send", what: Key("ground nodes alone"), from: 2067.0, to: 2233.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "wide-send", what: Key("old alone 「30 分钟前」"), from: 2117.0, to: 2117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "wide-send", what: Key("old alone 「Claude」"), from: 2117.0, to: 2267.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "wide-send", what: Key("nodes alone 「Claude」"), from: 2133.0, to: 2150.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "wide-send", what: Key("ground old alone"), from: 2150.0, to: 2233.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "wide-send", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 2167.0, to: 2183.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "wide-send", what: Key("nodes alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 2200.0, to: 2250.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "wide-send", what: Key("words 「发布前再看一眼签名」"), from: 2250.0, to: 2417.0, dx: 68.6, dy: 50.5, dw: 0.2, why: pa_why_send },
  { drive: "wide-send", what: Key("old alone 「等 林 决定」"), from: 2300.0, to: 2383.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "wide-send", what: Key("ring old alone"), from: 2550.0, to: 2600.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "wide-send", what: Key("old alone 「0s」"), from: 2567.0, to: 2600.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "wide-send", what: Key("alpha 「0s」"), from: 2617.0, to: 2683.0, dx: 0.2, dy: 0.2, dw: 0.8, why: pa_why_working },
  { drive: "wide-send", what: Key("ring"), from: 2617.0, to: 2633.0, dx: 5.1, dy: 1.2, dw: 10.0, why: pa_why_working },
  { drive: "wide-send", what: Key("ring alpha"), from: 2617.0, to: 2683.0, dx: 0.2, dy: 0.2, dw: 1.0, why: pa_why_working },
  { drive: "wide-send", what: Key("words 「0s」"), from: 2617.0, to: 2683.0, dx: 30.1, dy: 3.1, dw: 5.1, why: pa_why_working },
  { drive: "wide-send", what: Key("old alone 「先不换」"), from: 2650.0, to: 2650.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "wide-send", what: Key("old alone 「等 林 决定」"), from: 2650.0, to: 2650.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "wide-send", what: Key("nodes alone 「处理中」"), from: 2667.0, to: 2667.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "wide-send", what: Key("alpha 「处理中」"), from: 2683.0, to: 2683.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_working },
  { drive: "wide-send", what: Key("words 「0s」"), from: 3967.0, to: 3983.0, dx: 36.2, dy: 0.2, dw: 3.0, why: pa_why_working },
  { drive: "wide-send", what: Key("words 「处理中」"), from: 3967.0, to: 3967.0, dx: 0.2, dy: 0.2, dw: 17.0, why: pa_why_working },
  { drive: "wide-send", what: Key("nodes alone 「处理中」"), from: 3983.0, to: 4033.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "wide-send", what: Key("nodes alone 「0s」"), from: 4000.0, to: 4033.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "wide-send", what: Key("old alone 「处理中」"), from: 4050.0, to: 4050.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "wide-send", what: Key("ring old alone"), from: 4133.0, to: 4367.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "wide-send", what: Key("nodes alone 「刚刚」"), from: 1950.0, to: 2550.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "wide-send", what: Key("words 「发布前再看一眼签名」"), from: 4150.0, to: 4367.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_send },
  { drive: "wide-send", what: Key("words 「刚刚」"), from: 4150.0, to: 4367.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_timein },
  { drive: "wide-send", what: Key("words 「Claude」"), from: 4150.0, to: 4367.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_send },
  { drive: "wide-send", what: Key("words 「5 分钟前」"), from: 4150.0, to: 4367.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_send },
  { drive: "wide-send", what: Key("words 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 4150.0, to: 4367.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_send },
  { drive: "wide-send", what: Key("words 「15 分钟前」"), from: 4150.0, to: 4367.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_send },
  { drive: "wide-send", what: Key("words 「推送截图前要先登录 gh。」"), from: 4150.0, to: 4367.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_send },
  { drive: "wide-send", what: Key("words 「在 Willow 上登录 gh」"), from: 4150.0, to: 4367.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_send },
  { drive: "wide-send", what: Key("words 「等你在浏览器里登录」"), from: 4150.0, to: 4367.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_send },
  { drive: "wide-send", what: Key("words 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 4150.0, to: 4367.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_send },
  { drive: "wide-send", what: Key("words 「一起换」"), from: 4150.0, to: 4367.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_send },
  { drive: "wide-send", what: Key("words 「把首页和聊天页的截图都更新」"), from: 4150.0, to: 4367.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_send },
  { drive: "wide-send", what: Key("words 「忽略」"), from: 4150.0, to: 4367.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_send },
  { drive: "wide-send", what: Key("nodes alone 「这次只改列表，截图下次再说」"), from: 4150.0, to: 4250.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "wide-send", what: Key("ground"), from: 4150.0, to: 4367.0, dx: 0.2, dy: 24.7, dw: 23.1, why: pa_why_send },
  { drive: "send-lines-wide", what: Key("nodes alone 「先看一下签名⏎再看发布说明⏎最后核对版本号」"), from: 1917.0, to: 1917.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-lines-wide", what: Key("button @outline"), from: 1933.0, to: 2267.0, dx: 0.2, dy: 22.2, dw: 0.2, why: pa_why_send },
  { drive: "send-lines-wide", what: Key("composer"), from: 1933.0, to: 2083.0, dx: 0.2, dy: 44.2, dw: 44.2, why: pa_why_send },
  { drive: "send-lines-wide", what: Key("old alone 「先看一下签名⏎再看发布说明⏎最后核对版本号」"), from: 1933.0, to: 2617.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-lines-wide", what: Key("words 「先看一下签名⏎再看发布说明⏎最后核对版本号」"), from: 1967.0, to: 2067.0, dx: 95.2, dy: 6.9, dw: 0.2, why: pa_why_send },
  { drive: "send-lines-wide", what: Key("nodes alone 「先看一下签名⏎再看发布说明⏎最后核对版本号」"), from: 2083.0, to: 2317.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-lines-wide", what: Key("nodes alone 「Claude」"), from: 2100.0, to: 2117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-lines-wide", what: Key("ground"), from: 2117.0, to: 2483.0, dx: 60.7, dy: 43.1, dw: 0.2, why: pa_why_send },
  { drive: "send-lines-wide", what: Rows, from: 2117.0, to: 2367.0, dx: pa_way_tol, dy: 15.7, dw: pa_way_tol, why: pa_why_send },
  { drive: "send-lines-wide", what: Key("ground nodes alone"), from: 2133.0, to: 2317.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-lines-wide", what: Key("old alone 「发消息」"), from: 2150.0, to: 2217.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-lines-wide", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 2150.0, to: 2250.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-lines-wide", what: Key("nodes alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 2183.0, to: 2183.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-lines-wide", what: Key("old alone 「Claude」"), from: 2183.0, to: 2183.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-lines-wide", what: Key("old alone 「等 林 决定」"), from: 2200.0, to: 2200.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-lines-wide", what: Key("ground old alone"), from: 2217.0, to: 2317.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-lines-wide", what: Key("nodes alone 「等 林 决定」"), from: 2217.0, to: 2250.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-lines-wide", what: Key("old alone 「先不换」"), from: 2317.0, to: 2383.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-lines-wide", what: Key("words 「先看一下签名⏎再看发布说明⏎最后核对版本号」"), from: 2333.0, to: 2483.0, dx: 60.5, dy: 43.2, dw: 0.2, why: pa_why_send },
  { drive: "send-lines-wide", what: Key("old alone 「等 林 决定」"), from: 2350.0, to: 2433.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-lines-wide", what: Key("ring old alone"), from: 2617.0, to: 2667.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "send-lines-wide", what: Key("old alone 「0s」"), from: 2633.0, to: 2667.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send-lines-wide", what: Key("old alone 「这次只改列表，截图下次再说」"), from: 2650.0, to: 2650.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send-lines-wide", what: Key("alpha 「0s」"), from: 2683.0, to: 2750.0, dx: 0.2, dy: 0.2, dw: 0.8, why: pa_why_working },
  { drive: "send-lines-wide", what: Key("ring"), from: 2683.0, to: 2700.0, dx: 5.1, dy: 0.7, dw: 10.0, why: pa_why_working },
  { drive: "send-lines-wide", what: Key("ring alpha"), from: 2683.0, to: 2750.0, dx: 0.2, dy: 0.2, dw: 1.0, why: pa_why_working },
  { drive: "send-lines-wide", what: Key("words 「0s」"), from: 2683.0, to: 2750.0, dx: 30.1, dy: 3.6, dw: 5.1, why: pa_why_working },
  { drive: "send-lines-wide", what: Key("nodes alone 「处理中」"), from: 2733.0, to: 2733.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send-lines-wide", what: Key("alpha 「处理中」"), from: 2750.0, to: 2750.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_working },
  { drive: "send-lines-wide", what: Key("ground old alone"), from: 2750.0, to: 2750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send-lines-wide", what: Key("old alone 「一起换」"), from: 2750.0, to: 2767.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send-lines-wide", what: Key("nodes alone 「刚刚」"), from: 2017.0, to: 2617.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "wide-side-panel", what: Key("button @outline old alone"), from: 617.0, to: 617.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("words 「30 分钟前」"), from: 617.0, to: 717.0, dx: 25.2, dy: 11.3, dw: 0.2, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("words 「Claude」"), from: 617.0, to: 717.0, dx: 25.2, dy: 11.3, dw: 0.2, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("words 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 617.0, to: 617.0, dx: 0.2, dy: 0.2, dw: 181.2, why: pa_why_panel_first },
  { drive: "wide-side-panel", what: Key("words 「忽略」"), from: 617.0, to: 717.0, dx: 3.6, dy: 7.3, dw: 181.2, why: pa_why_panel_first },
  { drive: "wide-side-panel", what: Key("words 「推送截图前要先登录 gh。」"), from: 617.0, to: 617.0, dx: 0.2, dy: 0.2, dw: 181.2, why: pa_why_panel_first },
  { drive: "wide-side-panel", what: Key("words 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 617.0, to: 717.0, dx: 3.6, dy: 7.3, dw: 181.2, why: pa_why_panel_first },
  { drive: "wide-side-panel", what: Key("ground"), from: 633.0, to: 817.0, dx: 90.7, dy: 7.3, dw: 0.2, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("words 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 633.0, to: 817.0, dx: 90.7, dy: 5.0, dw: 0.2, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Rows, from: 667.0, to: 717.0, dx: pa_way_tol, dy: 7.3, dw: pa_way_tol, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("nodes alone 「40 分钟前」"), from: 700.0, to: 717.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("words 「40 分钟前」"), from: 733.0, to: 850.0, dx: 54.2, dy: 5.7, dw: 0.2, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("ground nodes alone"), from: 1217.0, to: 1317.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("nodes alone 「Esc」"), from: 1233.0, to: 1333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("nodes alone 「收起侧栏」"), from: 1233.0, to: 1333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("button @outline nodes alone"), from: 1533.0, to: 1533.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("words 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 1533.0, to: 1533.0, dx: 0.2, dy: 0.2, dw: 181.2, why: pa_why_panel_first },
  { drive: "wide-side-panel", what: Key("words 「忽略」"), from: 1533.0, to: 1533.0, dx: 0.2, dy: 0.2, dw: 181.2, why: pa_why_panel_first },
  { drive: "wide-side-panel", what: Key("words 「推送截图前要先登录 gh。」"), from: 1533.0, to: 1533.0, dx: 0.2, dy: 0.2, dw: 181.2, why: pa_why_panel_first },
  { drive: "wide-side-panel", what: Key("words 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 1533.0, to: 1533.0, dx: 0.2, dy: 0.2, dw: 181.2, why: pa_why_panel_first },
  { drive: "wide-side-panel", what: Key("ground"), from: 1550.0, to: 1733.0, dx: 81.5, dy: 3.5, dw: 0.2, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("nodes alone 「40 分钟前」"), from: 1550.0, to: 1583.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("old alone 「40 分钟前」"), from: 1550.0, to: 1617.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("words 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 1550.0, to: 1733.0, dx: 81.5, dy: 3.5, dw: 0.2, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("old alone 「还有深色模式也看一下」"), from: 1567.0, to: 1583.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("button @outline old alone"), from: 2450.0, to: 2450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("words 「30 分钟前」"), from: 2450.0, to: 2550.0, dx: 25.2, dy: 11.3, dw: 0.2, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("words 「Claude」"), from: 2450.0, to: 2550.0, dx: 25.2, dy: 11.3, dw: 0.2, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("words 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 2450.0, to: 2450.0, dx: 0.2, dy: 0.2, dw: 181.2, why: pa_why_panel_first },
  { drive: "wide-side-panel", what: Key("words 「忽略」"), from: 2450.0, to: 2550.0, dx: 3.6, dy: 7.3, dw: 181.2, why: pa_why_panel_first },
  { drive: "wide-side-panel", what: Key("words 「推送截图前要先登录 gh。」"), from: 2450.0, to: 2450.0, dx: 0.2, dy: 0.2, dw: 181.2, why: pa_why_panel_first },
  { drive: "wide-side-panel", what: Key("words 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 2450.0, to: 2550.0, dx: 3.6, dy: 7.3, dw: 181.2, why: pa_why_panel_first },
  { drive: "wide-side-panel", what: Key("ground"), from: 2467.0, to: 2650.0, dx: 95.7, dy: 7.3, dw: 0.7, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("words 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 2467.0, to: 2650.0, dx: 90.7, dy: 5.0, dw: 0.2, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Rows, from: 2500.0, to: 2550.0, dx: pa_way_tol, dy: 7.3, dw: pa_way_tol, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("ground nodes alone"), from: 2533.0, to: 2683.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("nodes alone 「40 分钟前」"), from: 2533.0, to: 2550.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("words 「40 分钟前」"), from: 2567.0, to: 2683.0, dx: 54.2, dy: 5.7, dw: 0.2, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("nodes alone 「Esc」"), from: 2667.0, to: 2700.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("nodes alone 「收起侧栏」"), from: 2667.0, to: 2700.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("alpha 「收起侧栏」"), from: 2717.0, to: 2733.0, dx: 0.2, dy: 0.2, dw: 0.6, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("button @outline nodes alone"), from: 3367.0, to: 3367.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("words 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 3367.0, to: 3367.0, dx: 0.2, dy: 0.2, dw: 181.2, why: pa_why_panel_first },
  { drive: "wide-side-panel", what: Key("words 「忽略」"), from: 3367.0, to: 3367.0, dx: 0.2, dy: 0.2, dw: 181.2, why: pa_why_panel_first },
  { drive: "wide-side-panel", what: Key("words 「推送截图前要先登录 gh。」"), from: 3367.0, to: 3367.0, dx: 0.2, dy: 0.2, dw: 181.2, why: pa_why_panel_first },
  { drive: "wide-side-panel", what: Key("words 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 3367.0, to: 3367.0, dx: 0.2, dy: 0.2, dw: 181.2, why: pa_why_panel_first },
  { drive: "wide-side-panel", what: Key("ground"), from: 3383.0, to: 3567.0, dx: 81.5, dy: 3.5, dw: 0.2, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("nodes alone 「40 分钟前」"), from: 3383.0, to: 3417.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("old alone 「40 分钟前」"), from: 3383.0, to: 3450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("words 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 3383.0, to: 3567.0, dx: 81.5, dy: 3.5, dw: 0.2, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("old alone 「还有深色模式也看一下」"), from: 3400.0, to: 3417.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_panel_mine },
  { drive: "wide-side-panel", what: Key("words 「Claude」"), from: 650.0, to: 750.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「Claude」"), from: 2483.0, to: 2583.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「30 分钟前」"), from: 650.0, to: 750.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「30 分钟前」"), from: 2483.0, to: 2583.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 650.0, to: 750.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 1583.0, to: 1617.0, dx: 3.8, dy: 9.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 2483.0, to: 2583.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 3417.0, to: 3450.0, dx: 3.8, dy: 9.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「等 林 决定」"), from: 650.0, to: 750.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「等 林 决定」"), from: 1583.0, to: 1617.0, dx: 3.8, dy: 9.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「等 林 决定」"), from: 2483.0, to: 2583.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「等 林 决定」"), from: 3417.0, to: 3450.0, dx: 3.8, dy: 9.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「先不换」"), from: 650.0, to: 750.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「先不换」"), from: 1583.0, to: 1617.0, dx: 3.8, dy: 9.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「先不换」"), from: 2483.0, to: 2583.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「先不换」"), from: 3417.0, to: 3450.0, dx: 3.8, dy: 9.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「这次只改列表，截图下次再说」"), from: 650.0, to: 750.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「这次只改列表，截图下次再说」"), from: 1583.0, to: 1617.0, dx: 3.8, dy: 9.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「这次只改列表，截图下次再说」"), from: 2483.0, to: 2583.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「这次只改列表，截图下次再说」"), from: 3417.0, to: 3450.0, dx: 3.8, dy: 9.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「一起换」"), from: 650.0, to: 750.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「一起换」"), from: 1583.0, to: 1617.0, dx: 3.8, dy: 9.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「一起换」"), from: 2483.0, to: 2583.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「一起换」"), from: 3417.0, to: 3450.0, dx: 3.8, dy: 9.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「把首页和聊天页的截图都更新」"), from: 650.0, to: 750.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「把首页和聊天页的截图都更新」"), from: 1583.0, to: 1617.0, dx: 3.8, dy: 9.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「把首页和聊天页的截图都更新」"), from: 2483.0, to: 2583.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「把首页和聊天页的截图都更新」"), from: 3417.0, to: 3450.0, dx: 3.8, dy: 9.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「忽略」"), from: 650.0, to: 750.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「忽略」"), from: 1583.0, to: 1617.0, dx: 3.8, dy: 9.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「忽略」"), from: 2483.0, to: 2583.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「忽略」"), from: 3417.0, to: 3450.0, dx: 3.8, dy: 9.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("ground"), from: 650.0, to: 717.0, dx: 56.0, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("ground"), from: 1583.0, to: 1617.0, dx: 50.4, dy: 9.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("ground"), from: 2483.0, to: 2550.0, dx: 56.0, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("ground"), from: 3417.0, to: 3450.0, dx: 50.4, dy: 9.3, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 667.0, to: 717.0, dx: 68.2, dy: 9.0, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 1600.0, to: 1617.0, dx: 50.4, dy: 7.5, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 2500.0, to: 2550.0, dx: 68.2, dy: 9.0, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 3433.0, to: 3450.0, dx: 50.4, dy: 7.5, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("nodes alone 「40 分钟前」"), from: 683.0, to: 683.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("nodes alone 「40 分钟前」"), from: 2517.0, to: 2517.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「40 分钟前」"), from: 733.0, to: 750.0, dx: 54.2, dy: 8.7, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("words 「40 分钟前」"), from: 2567.0, to: 2583.0, dx: 54.2, dy: 8.7, dw: 0.2, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("old alone 「详情」"), from: 1233.0, to: 1233.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_tip },
  { drive: "wide-side-panel", what: Key("composer"), from: 1533.0, to: 1767.0, dx: 46.1, dy: 8.2, dw: 92.0, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("composer"), from: 3367.0, to: 3600.0, dx: 46.1, dy: 8.2, dw: 92.0, why: pa_why_room_way },
  { drive: "wide-side-panel", what: Key("alpha 「Esc」"), from: 2717.0, to: 2733.0, dx: 0.2, dy: 0.2, dw: 0.6, why: pa_why_tip },
  { drive: "wide-side-panel", what: Key("words 「5 分钟前」"), from: 633.0, to: 717.0, dx: 19.5, dy: 4.5, dw: 0.2, why: pa_why_send },
  { drive: "wide-side-panel", what: Key("words 「5 分钟前」"), from: 1550.0, to: 1667.0, dx: 28.7, dy: 4.0, dw: 0.2, why: pa_why_send },
  { drive: "wide-side-panel", what: Key("words 「5 分钟前」"), from: 2467.0, to: 2550.0, dx: 19.5, dy: 4.5, dw: 0.2, why: pa_why_send },
  { drive: "wide-side-panel", what: Key("words 「5 分钟前」"), from: 3383.0, to: 3500.0, dx: 28.7, dy: 4.0, dw: 0.2, why: pa_why_send },
  { drive: "wide-side-panel", what: Key("words 「15 分钟前」"), from: 633.0, to: 717.0, dx: 19.5, dy: 7.0, dw: 0.2, why: pa_why_send },
  { drive: "wide-side-panel", what: Key("words 「15 分钟前」"), from: 1550.0, to: 1667.0, dx: 28.7, dy: 6.0, dw: 0.2, why: pa_why_send },
  { drive: "wide-side-panel", what: Key("words 「15 分钟前」"), from: 2467.0, to: 2550.0, dx: 19.5, dy: 7.0, dw: 0.2, why: pa_why_send },
  { drive: "wide-side-panel", what: Key("words 「15 分钟前」"), from: 3383.0, to: 3500.0, dx: 28.7, dy: 6.0, dw: 0.2, why: pa_why_send },
  { drive: "wide-side-panel", what: Key("words 「Claude」"), from: 1550.0, to: 1667.0, dx: 28.7, dy: 9.3, dw: 0.2, why: pa_why_send },
  { drive: "wide-side-panel", what: Key("words 「Claude」"), from: 3383.0, to: 3500.0, dx: 28.7, dy: 9.3, dw: 0.2, why: pa_why_send },
  { drive: "wide-side-panel", what: Key("words 「30 分钟前」"), from: 1550.0, to: 1667.0, dx: 28.7, dy: 9.3, dw: 0.2, why: pa_why_send },
  { drive: "wide-side-panel", what: Key("words 「30 分钟前」"), from: 3383.0, to: 3500.0, dx: 28.7, dy: 9.3, dw: 0.2, why: pa_why_send },
  { drive: "send-long", what: Key("nodes alone 「帮我看一下登录按钮在深色模式下的颜色是不是不对，还有注册页输入框的边框也要再核对一遍」"), from: 1917.0, to: 1917.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-long", what: Key("composer"), from: 1933.0, to: 2033.0, dx: 0.2, dy: 24.7, dw: 25.0, why: pa_why_send },
  { drive: "send-long", what: Key("old alone 「帮我看一下登录按钮在深色模式下的颜色是不是不对，还有注册页输入框的边框也要再核对一遍」"), from: 1933.0, to: 2350.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-long", what: Key("ground"), from: 2067.0, to: 2300.0, dx: 0.9, dy: 41.2, dw: 0.2, why: pa_why_send },
  { drive: "send-long", what: Rows, from: 2067.0, to: 2300.0, dx: pa_way_tol, dy: 41.2, dw: pa_way_tol, why: pa_why_send },
  { drive: "send-long", what: Key("nodes alone 「40 分钟前」"), from: 2083.0, to: 2117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-long", what: Key("ground alpha"), from: 2117.0, to: 2150.0, dx: 0.2, dy: 0.2, dw: 0.2, why: pa_why_send },
  { drive: "send-long", what: Key("nodes alone 「30 分钟前」"), from: 2150.0, to: 2183.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-long", what: Key("nodes alone 「Claude」"), from: 2150.0, to: 2183.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-long", what: Key("old alone 「30 分钟前」"), from: 2217.0, to: 2267.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-long", what: Key("old alone 「Claude」"), from: 2217.0, to: 2267.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-long", what: Key("ring old alone"), from: 2617.0, to: 2667.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "send-long", what: Key("old alone 「0s」"), from: 2633.0, to: 2667.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send-long", what: Key("alpha 「0s」"), from: 2683.0, to: 2750.0, dx: 0.2, dy: 0.2, dw: 0.8, why: pa_why_working },
  { drive: "send-long", what: Key("ring"), from: 2683.0, to: 2700.0, dx: 5.1, dy: 1.3, dw: 10.0, why: pa_why_working },
  { drive: "send-long", what: Key("ring alpha"), from: 2683.0, to: 2750.0, dx: 0.2, dy: 0.2, dw: 1.0, why: pa_why_working },
  { drive: "send-long", what: Key("words 「0s」"), from: 2683.0, to: 2750.0, dx: 31.4, dy: 3.1, dw: 5.5, why: pa_why_working },
  { drive: "send-long", what: Key("nodes alone 「处理中」"), from: 2733.0, to: 2733.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send-long", what: Key("alpha 「处理中」"), from: 2750.0, to: 2750.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_working },
  { drive: "send-long", what: Key("nodes alone 「刚刚」"), from: 2017.0, to: 2350.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "send-long", what: Key("nodes alone 「发消息」"), from: 2117.0, to: 2150.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("nodes alone 「看一下列表的高度」"), from: 1517.0, to: 1517.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("words 「看一下列表的高度」"), from: 1633.0, to: 1900.0, dx: 26.6, dy: 28.3, dw: 0.2, why: pa_why_send },
  { drive: "send-over-line", what: Key("ground nodes alone"), from: 1683.0, to: 1683.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("nodes alone 「还有深色模式也看一下」"), from: 1683.0, to: 1683.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("ground"), from: 1700.0, to: 1900.0, dx: 26.7, dy: 28.6, dw: 0.2, why: pa_why_send },
  { drive: "send-over-line", what: Key("old alone 「发消息」"), from: 1700.0, to: 1717.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Rows, from: 1700.0, to: 1850.0, dx: pa_way_tol, dy: 23.7, dw: pa_way_tol, why: pa_why_send },
  { drive: "send-over-line", what: Key("nodes alone 「40 分钟前」"), from: 1750.0, to: 1783.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("nodes alone 「30 分钟前」"), from: 1917.0, to: 1917.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("nodes alone 「Claude」"), from: 1917.0, to: 1933.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("ring old alone"), from: 2217.0, to: 2267.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "send-over-line", what: Key("old alone 「0s」"), from: 2233.0, to: 2267.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send-over-line", what: Key("alpha 「0s」"), from: 2283.0, to: 2350.0, dx: 0.2, dy: 0.2, dw: 0.8, why: pa_why_working },
  { drive: "send-over-line", what: Key("ring"), from: 2283.0, to: 2300.0, dx: 5.1, dy: 1.3, dw: 10.0, why: pa_why_working },
  { drive: "send-over-line", what: Key("ring alpha"), from: 2283.0, to: 2350.0, dx: 0.2, dy: 0.2, dw: 1.0, why: pa_why_working },
  { drive: "send-over-line", what: Key("words 「0s」"), from: 2283.0, to: 2350.0, dx: 31.4, dy: 3.1, dw: 5.5, why: pa_why_working },
  { drive: "send-over-line", what: Key("nodes alone 「处理中」"), from: 2333.0, to: 2333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send-over-line", what: Key("alpha 「处理中」"), from: 2350.0, to: 2350.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_working },
  { drive: "send-over-line", what: Key("old alone 「30 分钟前」"), from: 2350.0, to: 2350.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send-over-line", what: Key("old alone 「Claude」"), from: 2350.0, to: 2350.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send-over-line", what: Key("nodes alone 「顺便看看深色模式下面的图标是不是也要一起换掉，还有按钮和输入框的颜色也一起对一下」"), from: 2950.0, to: 2950.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("old alone 「刚刚」"), from: 2950.0, to: 2950.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_float },
  { drive: "send-over-line", what: Key("composer"), from: 2967.0, to: 3067.0, dx: 0.2, dy: 24.7, dw: 25.0, why: pa_why_send },
  { drive: "send-over-line", what: Key("old alone 「顺便看看深色模式下面的图标是不是也要一起换掉，还有按钮和输入框的颜色也一起对一下」"), from: 2967.0, to: 3383.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("words 「顺便看看深色模式下面的图标是不是也要一起换掉，还有按钮和输入框的颜色也一起对一下」"), from: 2967.0, to: 5200.0, dx: 0.9, dy: 69.0, dw: 15.2, why: pa_why_send },
  { drive: "send-over-line", what: Key("nodes alone 「等 林 决定」"), from: 3100.0, to: 3100.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("ground"), from: 3117.0, to: 5467.0, dx: 9.2, dy: 104.5, dw: 86.2, why: pa_why_send },
  { drive: "send-over-line", what: Key("ring"), from: 3117.0, to: 3783.0, dx: 0.2, dy: 24.7, dw: 0.2, why: pa_why_send },
  { drive: "send-over-line", what: Key("words 「0s」"), from: 3117.0, to: 3650.0, dx: 39.2, dy: 24.7, dw: 2.8, why: pa_why_working },
  { drive: "send-over-line", what: Key("words 「Claude」"), from: 3117.0, to: 5467.0, dx: 8.1, dy: 84.7, dw: 15.4, why: pa_why_send },
  { drive: "send-over-line", what: Key("words 「处理中」"), from: 3117.0, to: 3717.0, dx: 0.2, dy: 24.7, dw: 39.2, why: pa_why_working },
  { drive: "send-over-line", what: Rows, from: 3117.0, to: 5467.0, dx: pa_way_tol, dy: 84.7, dw: pa_way_tol, why: pa_why_send },
  { drive: "send-over-line", what: Key("ground alpha"), from: 3150.0, to: 3183.0, dx: 0.2, dy: 0.2, dw: 0.2, why: pa_why_send },
  { drive: "send-over-line", what: Key("nodes alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 3150.0, to: 3183.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("old alone 「等 林 决定」"), from: 3150.0, to: 3783.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("ring nodes alone"), from: 3183.0, to: 3200.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("old alone 「先不换」"), from: 3250.0, to: 3283.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("nodes alone 「先不换」"), from: 3300.0, to: 3883.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("old alone 「这次只改列表，截图下次再说」"), from: 3350.0, to: 3917.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("nodes alone 「刚刚」"), from: 3617.0, to: 3817.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_float },
  { drive: "send-over-line", what: Key("alpha 「0s」"), from: 3650.0, to: 3650.0, dx: 0.2, dy: 0.2, dw: 0.8, why: pa_why_working },
  { drive: "send-over-line", what: Key("nodes alone 「处理中」"), from: 3650.0, to: 4300.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send-over-line", what: Key("words 「刚刚」"), from: 3650.0, to: 5467.0, dx: 25.6, dy: 103.9, dw: 13.6, why: pa_why_working },
  { drive: "send-over-line", what: Key("nodes alone 「0s」"), from: 3667.0, to: 4300.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send-over-line", what: Key("alpha 「处理中」"), from: 3717.0, to: 3717.0, dx: 0.2, dy: 0.2, dw: 1.1, why: pa_why_working },
  { drive: "send-over-line", what: Key("button @asks.go nodes alone"), from: 3800.0, to: 5183.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "send-over-line", what: Key("ring old alone"), from: 3800.0, to: 4900.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "send-over-line", what: Key("old alone 「一起换」"), from: 3950.0, to: 5067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("old alone 「把首页和聊天页的截图都更新」"), from: 3817.0, to: 5100.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("alpha 「刚刚」"), from: 4050.0, to: 4250.0, dx: 0.2, dy: 0.2, dw: 1.1, why: pa_why_timein },
  { drive: "send-over-line", what: Key("old alone 「忽略」"), from: 4017.0, to: 4200.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("ground alpha"), from: 3800.0, to: 5083.0, dx: 0.2, dy: 0.2, dw: 1.1, why: pa_why_send },
  { drive: "send-over-line", what: Key("ground nodes alone"), from: 4133.0, to: 5050.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("ground old alone"), from: 3683.0, to: 5150.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("nodes alone 「Claude」"), from: 3850.0, to: 5067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("old alone 「Claude」"), from: 3850.0, to: 5117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("old alone 「忽略」"), from: 4217.0, to: 5150.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("alpha 「Claude」"), from: 4233.0, to: 4250.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_send },
  { drive: "send-over-line", what: Key("nodes alone 「刚刚」"), from: 4233.0, to: 4233.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("nodes alone 「收到：「看一下列表的高度」。我先看一下，有结果再告诉你。」"), from: 4233.0, to: 4350.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_spit },
  { drive: "send-over-line", what: Key("old alone 「刚刚」"), from: 5050.0, to: 5117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send-over-line", what: Key("old alone 「收到：「顺便看看深色模式下面的图标是不是也要一起换掉，还有按钮和输入框的颜色也一起对一下」。我先看一下，有结果再告诉你。」"), from: 5050.0, to: 5117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_spit },
  { drive: "send-over-line", what: Key("old alone 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 5067.0, to: 5083.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("alpha 「Claude」"), from: 5133.0, to: 5200.0, dx: 0.2, dy: 0.2, dw: 0.8, why: pa_why_send },
  { drive: "send-over-line", what: Key("alpha 「刚刚」"), from: 5133.0, to: 5217.0, dx: 0.2, dy: 0.2, dw: 1.0, why: pa_why_timein },
  { drive: "send-over-line", what: Key("nodes alone 「收到：「顺便看看深色模式下面的图标是不是也要一起换掉，还有按钮和输入框的颜色也一起对一下」。我先看一下，有结果再告诉你。」"), from: 5133.0, to: 5183.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("nodes alone 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 5167.0, to: 5183.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("alpha 「收到：「顺便看看深色模式下面的图标是不是也要一起换掉，还有按钮和输入框的颜色也一起对一下」。我先看一下，有结果再告诉你。」"), from: 5200.0, to: 5217.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_spit },
  { drive: "send-over-line", what: Key("words 「收到：「顺便看看深色模式下面的图标是不是也要一起换掉，还有按钮和输入框的颜色也一起对一下」。我先看一下，有结果再告诉你。」"), from: 5200.0, to: 5267.0, dx: 0.2, dy: 5.4, dw: 40.2, why: pa_why_spit },
  { drive: "send-over-line", what: Key("old alone 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 5217.0, to: 5467.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("nodes alone 「刚刚」"), from: 1617.0, to: 2050.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "send-over-line", what: Key("nodes alone 「刚刚」"), from: 3050.0, to: 3383.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "send-over-line", what: Key("nodes alone 「发消息」"), from: 1733.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("nodes alone 「发消息」"), from: 3150.0, to: 3150.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("old alone 「一起换」"), from: 3717.0, to: 3883.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("old alone 「先不换」"), from: 3817.0, to: 3850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-picture-only", what: Key("nodes alone 「截图和构建日志都在这里，帮我看看第二屏」"), from: 2550.0, to: 2550.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-picture-only", what: Key("old alone 「.png」"), from: 2550.0, to: 2567.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-picture-only", what: Key("old alone 「393 KB」"), from: 2550.0, to: 2567.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-picture-only", what: Key("old alone 「compare」"), from: 2550.0, to: 2567.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-picture-only", what: Key("words 「18 KB」"), from: 2550.0, to: 2967.0, dx: 27.1, dy: 45.8, dw: 104.7, why: pa_why_send },
  { drive: "send-picture-only", what: Key("button @asks.go nodes alone"), from: 2567.0, to: 3300.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "send-picture-only", what: Key("composer"), from: 2567.0, to: 2683.0, dx: 0.2, dy: 175.8, dw: 176.1, why: pa_why_send },
  { drive: "send-picture-only", what: Key("ground"), from: 2567.0, to: 2967.0, dx: 37.8, dy: 60.7, dw: 98.7, why: pa_why_send },
  { drive: "send-picture-only", what: Key("ground old alone"), from: 2567.0, to: 2567.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-picture-only", what: Key("picture"), from: 2583.0, to: 2983.0, dx: 0.2, dy: 62.5, dw: 77.3, why: pa_why_send },
  { drive: "send-picture-only", what: Key("words 「.log」"), from: 2667.0, to: 2967.0, dx: 27.1, dy: 45.8, dw: 0.2, why: pa_why_send },
  { drive: "send-picture-only", what: Key("words 「build」"), from: 2667.0, to: 2967.0, dx: 27.1, dy: 45.8, dw: 0.2, why: pa_why_send },
  { drive: "send-picture-only", what: Key("words 「截图和构建日志都在这里，帮我看看第二屏」"), from: 2700.0, to: 2967.0, dx: 6.4, dy: 47.0, dw: 0.2, why: pa_why_send },
  { drive: "send-picture-only", what: Key("old alone 「发消息」"), from: 2717.0, to: 2750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-picture-only", what: Rows, from: 2717.0, to: 2933.0, dx: pa_way_tol, dy: 60.7, dw: pa_way_tol, why: pa_why_send },
  { drive: "send-picture-only", what: Key("nodes alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 2733.0, to: 2767.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-picture-only", what: Key("nodes alone 「先不换」"), from: 2750.0, to: 2817.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-picture-only", what: Key("nodes alone 「这次只改列表，截图下次再说」"), from: 2767.0, to: 2833.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-picture-only", what: Key("ground nodes alone"), from: 2783.0, to: 2817.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-picture-only", what: Key("nodes alone 「等 林 决定」"), from: 2783.0, to: 2783.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-picture-only", what: Key("nodes alone 「一起换」"), from: 2800.0, to: 2867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-picture-only", what: Key("nodes alone 「把首页和聊天页的截图都更新」"), from: 2817.0, to: 2900.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-picture-only", what: Key("old alone 「把首页和聊天页的截图都更新」"), from: 2850.0, to: 2850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-picture-only", what: Key("nodes alone 「忽略」"), from: 2867.0, to: 2883.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-picture-only", what: Key("old alone 「忽略」"), from: 2900.0, to: 2917.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-picture-only", what: Key("old alone 「忽略」"), from: 3250.0, to: 3267.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-picture-only", what: Key("ring old alone"), from: 3250.0, to: 3300.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "send-picture-only", what: Key("old alone 「0s」"), from: 3267.0, to: 3300.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send-picture-only", what: Key("alpha 「0s」"), from: 3317.0, to: 3383.0, dx: 0.2, dy: 0.2, dw: 0.8, why: pa_why_working },
  { drive: "send-picture-only", what: Key("ring"), from: 3317.0, to: 3333.0, dx: 5.1, dy: 1.3, dw: 10.0, why: pa_why_bell },
  { drive: "send-picture-only", what: Key("ring alpha"), from: 3317.0, to: 3383.0, dx: 0.2, dy: 0.2, dw: 1.0, why: pa_why_bell },
  { drive: "send-picture-only", what: Key("words 「0s」"), from: 3317.0, to: 3383.0, dx: 31.4, dy: 3.1, dw: 5.5, why: pa_why_working },
  { drive: "send-picture-only", what: Key("nodes alone 「处理中」"), from: 3367.0, to: 3367.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send-picture-only", what: Key("alpha 「处理中」"), from: 3383.0, to: 3383.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_working },
  { drive: "send-picture-only", what: Key("ground alpha"), from: 2717.0, to: 2717.0, dx: 0.2, dy: 0.2, dw: 0.3, why: pa_why_send },
  { drive: "send-picture-only", what: Key("ground nodes alone"), from: 2717.0, to: 2717.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-picture-only", what: Key("nodes alone 「刚刚」"), from: 3083.0, to: 3083.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "send-quote-picture", what: Key("nodes alone 「1 小时前」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「40 分钟前」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「Claude：其余的行按估计的高度占位，滚到时再量真实高度」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「发布清单 第三项已经核对完：安装包签名正确。」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「发送到」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「对比图和构建日志附在下面。」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「星火#发布」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「等 林 决定」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「这里的高度是怎么估的？」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「.log」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「1 小时前」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「15 分钟前」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「18 KB」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「30 分钟前」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「40 分钟前」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「Claude」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「Claude：其余的行按估计的高度占位，滚到时再量真实高度」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「build」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「一起换」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「先不换」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「发布清单 第三项已经核对完：安装包签名正确。」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「发送到」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「忽略」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「把首页和聊天页的截图都更新」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「推送截图前要先登录 gh。」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「星火#发布」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「等 林 决定」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「还有深色模式也看一下」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「这次只改列表，截图下次再说」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「这里的高度是怎么估的？」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Rows, from: 1750.0, to: 1750.0, dx: pa_way_tol, dy: 20.7, dw: pa_way_tol, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("button @asks.go"), from: 1767.0, to: 1850.0, dx: 0.2, dy: 23.0, dw: 0.2, why: pa_why_bell },
  { drive: "send-quote-picture", what: Key("nodes alone 「1 小时前」"), from: 1867.0, to: 1867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「Claude：其余的行按估计的高度占位，滚到时再量真实高度」"), from: 1867.0, to: 1867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「发布清单 第三项已经核对完：安装包签名正确。」"), from: 1867.0, to: 1867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「发送到」"), from: 1867.0, to: 1867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「对比图和构建日志附在下面。」"), from: 1867.0, to: 1867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「星火#发布」"), from: 1867.0, to: 1867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「.log」"), from: 1867.0, to: 1867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「1 小时前」"), from: 1867.0, to: 1867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「18 KB」"), from: 1867.0, to: 1867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「30 分钟前」"), from: 1867.0, to: 1867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「40 分钟前」"), from: 1867.0, to: 1867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「Claude」"), from: 1867.0, to: 1867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_float },
  { drive: "send-quote-picture", what: Key("old alone 「Claude：其余的行按估计的高度占位，滚到时再量真实高度」"), from: 1867.0, to: 1867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「build」"), from: 1867.0, to: 1867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「先不换」"), from: 1867.0, to: 1867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「发布清单 第三项已经核对完：安装包签名正确。」"), from: 1867.0, to: 1867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「发送到」"), from: 1867.0, to: 1867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「对比图和构建日志附在下面。」"), from: 1867.0, to: 1867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「星火#发布」"), from: 1867.0, to: 1867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「等 林 决定」"), from: 1867.0, to: 1867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「还有深色模式也看一下」"), from: 1867.0, to: 1867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「这里的高度是怎么估的？」"), from: 1867.0, to: 1867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 1867.0, to: 1867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Rows, from: 1867.0, to: 1867.0, dx: pa_way_tol, dy: 20.7, dw: pa_way_tol, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「发消息」"), from: 4383.0, to: 5217.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_lift },
  { drive: "send-quote-picture", what: Key("nodes alone 「18 KB」"), from: 5450.0, to: 5450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_lift },
  { drive: "send-quote-picture", what: Key("button @outline old alone"), from: 6117.0, to: 6283.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("button 跳到最新 old alone"), from: 6117.0, to: 6283.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「添加说明（可选）」"), from: 6117.0, to: 6300.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("composer"), from: 6133.0, to: 6250.0, dx: 0.2, dy: 134.0, dw: 134.2, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("ground alpha"), from: 6133.0, to: 6617.0, dx: 0.2, dy: 0.2, dw: 1.1, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("ground nodes alone"), from: 6133.0, to: 6550.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「15 分钟前」"), from: 6133.0, to: 6550.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「5 分钟前」"), from: 6133.0, to: 6550.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「Claude」"), from: 6133.0, to: 6367.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 6133.0, to: 6550.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「一起换」"), from: 6133.0, to: 6550.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 6133.0, to: 6550.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「先不换」"), from: 6133.0, to: 6417.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「在 Willow 上登录 gh」"), from: 6133.0, to: 6550.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「忽略」"), from: 6133.0, to: 6550.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「把首页和聊天页的截图都更新」"), from: 6133.0, to: 6533.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「推送截图前要先登录 gh。」"), from: 6133.0, to: 6550.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「等 林 决定」"), from: 6133.0, to: 6367.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「等你在浏览器里登录」"), from: 6133.0, to: 6550.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「这次只改列表，截图下次再说」"), from: 6133.0, to: 6483.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 6133.0, to: 6350.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「1 小时前」"), from: 6133.0, to: 6333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「18 KB」"), from: 6133.0, to: 6300.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「Claude」"), from: 6133.0, to: 6600.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「对比图和构建日志附在下面。」"), from: 6133.0, to: 6183.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「改好后的样子：」"), from: 6133.0, to: 6133.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("picture"), from: 6133.0, to: 7100.0, dx: 1.1, dy: 212.5, dw: 34.4, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("picture old alone"), from: 6133.0, to: 6233.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("button @asks.go old alone"), from: 6150.0, to: 6383.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "send-quote-picture", what: Key("ground old alone"), from: 6150.0, to: 6683.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「.log」"), from: 6150.0, to: 6300.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「Claude：其余的行按估计的高度占位，滚到时再量真实高度」"), from: 6150.0, to: 6400.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「build」"), from: 6150.0, to: 6300.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「发布清单 第三项已经核对完：安装包签名正确。」"), from: 6167.0, to: 6333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「发送到」"), from: 6167.0, to: 6350.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「星火#发布」"), from: 6167.0, to: 6350.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Rows, from: 6167.0, to: 7100.0, dx: pa_way_tol, dy: 119.2, dw: pa_way_tol, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「30 分钟前」"), from: 6183.0, to: 6517.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「这里的高度是怎么估的？」"), from: 6183.0, to: 6400.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("ground"), from: 6200.0, to: 7100.0, dx: 180.2, dy: 109.9, dw: 180.2, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「40 分钟前」"), from: 6200.0, to: 6450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「等 林 决定」"), from: 6200.0, to: 6600.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「还有深色模式也看一下」"), from: 6200.0, to: 6433.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 6217.0, to: 6567.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「先不换」"), from: 6233.0, to: 6667.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「一起换」"), from: 6250.0, to: 6550.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「这次只改列表，截图下次再说」"), from: 6250.0, to: 6767.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「忽略」"), from: 6283.0, to: 6550.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「把首页和聊天页的截图都更新」"), from: 6283.0, to: 6833.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「推送截图前要先登录 gh。」"), from: 6283.0, to: 6550.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「15 分钟前」"), from: 6317.0, to: 6550.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 6317.0, to: 6550.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「在 Willow 上登录 gh」"), from: 6350.0, to: 6550.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「等你在浏览器里登录」"), from: 6350.0, to: 6550.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「Claude：compare.png」"), from: 6367.0, to: 6550.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「Claude：compare.png」"), from: 6367.0, to: 6550.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「5 分钟前」"), from: 6383.0, to: 6550.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 6400.0, to: 6550.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「Claude」"), from: 6483.0, to: 6600.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「一起换」"), from: 6717.0, to: 6783.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("ring old alone"), from: 6817.0, to: 6867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "send-quote-picture", what: Key("button @asks.go nodes alone"), from: 6833.0, to: 7633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "send-quote-picture", what: Key("old alone 「0s」"), from: 6833.0, to: 6867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send-quote-picture", what: Key("nodes alone 「把首页和聊天页的截图都更新」"), from: 6867.0, to: 6933.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("old alone 「一起换」"), from: 6867.0, to: 6950.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("alpha 「0s」"), from: 6883.0, to: 6950.0, dx: 0.2, dy: 0.2, dw: 0.8, why: pa_why_working },
  { drive: "send-quote-picture", what: Key("ring"), from: 6883.0, to: 7100.0, dx: 5.1, dy: 26.0, dw: 10.0, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("ring alpha"), from: 6883.0, to: 6950.0, dx: 0.2, dy: 0.2, dw: 1.0, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("words 「0s」"), from: 6883.0, to: 7100.0, dx: 31.4, dy: 24.2, dw: 5.5, why: pa_why_working },
  { drive: "send-quote-picture", what: Key("old alone 「忽略」"), from: 6917.0, to: 7050.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("nodes alone 「处理中」"), from: 6933.0, to: 6933.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("alpha 「处理中」"), from: 6950.0, to: 6950.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_working },
  { drive: "send-quote-picture", what: Key("old alone 「把首页和聊天页的截图都更新」"), from: 6950.0, to: 7133.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-picture", what: Key("button 跳到最新 nodes alone"), from: 6117.0, to: 6267.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_quote_flight },
  { drive: "send-quote-picture", what: Key("button @outline nodes alone"), from: 6117.0, to: 6267.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_quote_flight },
  { drive: "send-quote-picture", what: Key("button 跳转到待决策的消息 nodes alone"), from: 6117.0, to: 6117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_quote_flight },
  { drive: "send-quote-picture", what: Key("button 跳转到待决策的消息"), from: 6133.0, to: 6267.0, dx: 0.2, dy: 114.0, dw: 0.2, why: pa_why_quote_flight },
  { drive: "send-quote-picture", what: Key("old alone 「刚刚」"), from: 6517.0, to: 6517.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "send-quote-picture", what: Key("old alone 「刚刚」"), from: 6617.0, to: 6633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "scrolled-reply", what: Key("nodes alone 「看一下列表的高度」"), from: 1917.0, to: 1917.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("words 「看一下列表的高度」"), from: 2033.0, to: 2300.0, dx: 26.6, dy: 28.3, dw: 0.2, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("ground nodes alone"), from: 2083.0, to: 2083.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("nodes alone 「还有深色模式也看一下」"), from: 2083.0, to: 2083.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("ground"), from: 2100.0, to: 2300.0, dx: 26.7, dy: 28.6, dw: 0.2, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("old alone 「发消息」"), from: 2100.0, to: 2117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply", what: Rows, from: 2100.0, to: 2250.0, dx: pa_way_tol, dy: 23.7, dw: pa_way_tol, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("nodes alone 「40 分钟前」"), from: 2150.0, to: 2183.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("nodes alone 「30 分钟前」"), from: 2317.0, to: 2317.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("nodes alone 「Claude」"), from: 2317.0, to: 2333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("ring old alone"), from: 2617.0, to: 2667.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "scrolled-reply", what: Key("old alone 「0s」"), from: 2633.0, to: 2667.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("alpha 「0s」"), from: 2683.0, to: 2750.0, dx: 0.2, dy: 0.2, dw: 0.8, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("ring"), from: 2683.0, to: 2700.0, dx: 5.1, dy: 1.3, dw: 10.0, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("ring alpha"), from: 2683.0, to: 2750.0, dx: 0.2, dy: 0.2, dw: 1.0, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("words 「0s」"), from: 2683.0, to: 2750.0, dx: 31.4, dy: 3.1, dw: 5.5, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("nodes alone 「处理中」"), from: 2733.0, to: 2733.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("alpha 「处理中」"), from: 2750.0, to: 2750.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("old alone 「30 分钟前」"), from: 2750.0, to: 2750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("old alone 「Claude」"), from: 2750.0, to: 2750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply", what: Rows, from: 3183.0, to: 3550.0, dx: pa_way_tol, dy: 7.2, dw: pa_way_tol, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("old alone 「30 分钟前」"), from: 3233.0, to: 3233.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("old alone 「Claude」"), from: 3233.0, to: 3233.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("composer"), from: 3467.0, to: 3467.0, dx: 0.2, dy: 42.7, dw: 43.0, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("ground"), from: 3550.0, to: 3550.0, dx: 0.2, dy: 6.7, dw: 0.2, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("ring nodes alone"), from: 3567.0, to: 3567.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("ground nodes alone"), from: 3583.0, to: 3583.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("nodes alone 「Claude：其余的行按估计的高度占位，滚到时再量真实高度」"), from: 3583.0, to: 3583.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("nodes alone 「这里的高度是怎么估的？」"), from: 3583.0, to: 3583.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("nodes alone 「0s」"), from: 3600.0, to: 3617.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("nodes alone 「处理中」"), from: 3600.0, to: 3617.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("ring"), from: 3600.0, to: 3633.0, dx: 0.2, dy: 0.7, dw: 7.1, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("old alone 「0s」"), from: 3683.0, to: 3683.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("old alone 「处理中」"), from: 3683.0, to: 3683.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("nodes alone 「发消息」"), from: 3783.0, to: 3783.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("ring old alone"), from: 4017.0, to: 4067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "scrolled-reply", what: Key("old alone 「0s」"), from: 4050.0, to: 4050.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("old alone 「处理中」"), from: 4050.0, to: 4067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("nodes alone 「Claude」"), from: 4083.0, to: 4117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("nodes alone 「刚刚」"), from: 4083.0, to: 4117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply", what: Key("nodes alone 「刚刚」"), from: 2017.0, to: 2450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "scrolled-reply", what: Key("nodes alone 「发消息」"), from: 2133.0, to: 2150.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "scrolled-reply-near", what: Key("nodes alone 「看一下列表的高度」"), from: 1917.0, to: 1917.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("words 「看一下列表的高度」"), from: 2033.0, to: 2300.0, dx: 26.6, dy: 28.3, dw: 0.2, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("ground nodes alone"), from: 2083.0, to: 2083.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("nodes alone 「还有深色模式也看一下」"), from: 2083.0, to: 2083.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("ground"), from: 2100.0, to: 2300.0, dx: 26.7, dy: 28.6, dw: 0.2, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("old alone 「发消息」"), from: 2100.0, to: 2117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Rows, from: 2100.0, to: 2250.0, dx: pa_way_tol, dy: 23.7, dw: pa_way_tol, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("nodes alone 「40 分钟前」"), from: 2150.0, to: 2183.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("nodes alone 「30 分钟前」"), from: 2317.0, to: 2317.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("nodes alone 「Claude」"), from: 2317.0, to: 2333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("ring old alone"), from: 2617.0, to: 2667.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "scrolled-reply-near", what: Key("old alone 「0s」"), from: 2633.0, to: 2667.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("alpha 「0s」"), from: 2683.0, to: 2750.0, dx: 0.2, dy: 0.2, dw: 0.8, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("ring"), from: 2683.0, to: 2700.0, dx: 5.1, dy: 1.3, dw: 10.0, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("ring alpha"), from: 2683.0, to: 2750.0, dx: 0.2, dy: 0.2, dw: 1.0, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("words 「0s」"), from: 2683.0, to: 2750.0, dx: 31.4, dy: 3.1, dw: 5.5, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("nodes alone 「处理中」"), from: 2733.0, to: 2733.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("alpha 「处理中」"), from: 2750.0, to: 2750.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("old alone 「30 分钟前」"), from: 2750.0, to: 2750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("old alone 「Claude」"), from: 2750.0, to: 2750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("nodes alone 「30 分钟前」"), from: 3233.0, to: 3233.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("nodes alone 「Claude」"), from: 3233.0, to: 3233.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("old alone 「30 分钟前」"), from: 3400.0, to: 3400.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("old alone 「Claude」"), from: 3400.0, to: 3400.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("composer"), from: 3500.0, to: 3500.0, dx: 0.2, dy: 42.7, dw: 43.0, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("nodes alone 「发消息」"), from: 3817.0, to: 3817.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("old alone 「0s」"), from: 4017.0, to: 4050.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("old alone 「处理中」"), from: 4017.0, to: 4067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("ring old alone"), from: 4017.0, to: 4067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "scrolled-reply-near", what: Key("alpha 「刚刚」"), from: 4083.0, to: 4150.0, dx: 0.2, dy: 0.2, dw: 1.0, why: pa_why_timein },
  { drive: "scrolled-reply-near", what: Key("nodes alone 「Claude」"), from: 4083.0, to: 4117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("nodes alone 「刚刚」"), from: 4083.0, to: 4083.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("nodes alone 「收到：「看一下列表的高度」。我先看一下，有结果再告诉你。」"), from: 4083.0, to: 4083.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("words 「刚刚」"), from: 4083.0, to: 4150.0, dx: 20.6, dy: 2.2, dw: 10.0, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("alpha 「收到：「看一下列表的高度」。我先看一下，有结果再告诉你。」"), from: 4100.0, to: 4133.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("words 「收到：「看一下列表的高度」。我先看一下，有结果再告诉你。」"), from: 4100.0, to: 4200.0, dx: 0.2, dy: 9.5, dw: 104.6, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("alpha 「Claude」"), from: 4133.0, to: 4133.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_read },
  { drive: "scrolled-reply-near", what: Key("nodes alone 「刚刚」"), from: 2017.0, to: 2450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "scrolled-reply-near", what: Key("nodes alone 「发消息」"), from: 2133.0, to: 2150.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "answer-leave", what: Key("nodes alone 「看一下列表的高度」"), from: 1917.0, to: 1917.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "answer-leave", what: Key("words 「看一下列表的高度」"), from: 2033.0, to: 2300.0, dx: 26.6, dy: 28.3, dw: 0.2, why: pa_why_working },
  { drive: "answer-leave", what: Key("ground nodes alone"), from: 2083.0, to: 2083.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "answer-leave", what: Key("nodes alone 「还有深色模式也看一下」"), from: 2083.0, to: 2083.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "answer-leave", what: Key("ground"), from: 2100.0, to: 2300.0, dx: 26.7, dy: 28.6, dw: 0.2, why: pa_why_working },
  { drive: "answer-leave", what: Key("old alone 「发消息」"), from: 2100.0, to: 2117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "answer-leave", what: Rows, from: 2100.0, to: 2250.0, dx: pa_way_tol, dy: 23.7, dw: pa_way_tol, why: pa_why_working },
  { drive: "answer-leave", what: Key("nodes alone 「40 分钟前」"), from: 2150.0, to: 2183.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "answer-leave", what: Key("nodes alone 「30 分钟前」"), from: 2317.0, to: 2317.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "answer-leave", what: Key("nodes alone 「Claude」"), from: 2317.0, to: 2333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "answer-leave", what: Key("ring old alone"), from: 2617.0, to: 2667.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "answer-leave", what: Key("old alone 「0s」"), from: 2633.0, to: 2667.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "answer-leave", what: Key("alpha 「0s」"), from: 2683.0, to: 2750.0, dx: 0.2, dy: 0.2, dw: 0.8, why: pa_why_working },
  { drive: "answer-leave", what: Key("ring"), from: 2683.0, to: 2700.0, dx: 5.1, dy: 1.3, dw: 10.0, why: pa_why_working },
  { drive: "answer-leave", what: Key("ring alpha"), from: 2683.0, to: 2750.0, dx: 0.2, dy: 0.2, dw: 1.0, why: pa_why_working },
  { drive: "answer-leave", what: Key("words 「0s」"), from: 2683.0, to: 2750.0, dx: 31.4, dy: 3.1, dw: 5.5, why: pa_why_working },
  { drive: "answer-leave", what: Key("nodes alone 「处理中」"), from: 2733.0, to: 2733.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "answer-leave", what: Key("alpha 「处理中」"), from: 2750.0, to: 2750.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_working },
  { drive: "answer-leave", what: Key("old alone 「30 分钟前」"), from: 2750.0, to: 2750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "answer-leave", what: Key("old alone 「Claude」"), from: 2750.0, to: 2750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "answer-leave", what: Key("words 「0s」"), from: 4033.0, to: 4050.0, dx: 39.2, dy: 0.2, dw: 2.8, why: pa_why_working },
  { drive: "answer-leave", what: Key("words 「处理中」"), from: 4033.0, to: 4033.0, dx: 0.2, dy: 0.2, dw: 18.2, why: pa_why_working },
  { drive: "answer-leave", what: Key("nodes alone 「处理中」"), from: 4050.0, to: 4100.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "answer-leave", what: Key("nodes alone 「0s」"), from: 4067.0, to: 4100.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "answer-leave", what: Key("old alone 「处理中」"), from: 4117.0, to: 4117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "answer-leave", what: Key("ring old alone"), from: 4200.0, to: 5250.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "answer-leave", what: Key("nodes alone 「等 林 决定」"), from: 4267.0, to: 4317.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "answer-leave", what: Key("old alone 「Claude」"), from: 4617.0, to: 4617.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "answer-leave", what: Key("alpha 「Claude」"), from: 4633.0, to: 4650.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_working },
  { drive: "answer-leave", what: Key("nodes alone 「刚刚」"), from: 4633.0, to: 4633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "answer-leave", what: Key("nodes alone 「收到：「看一下列表的高度」。我先看一下，有结果再告诉你。」"), from: 4633.0, to: 4750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "answer-leave", what: Key("words 「Claude」"), from: 4633.0, to: 4633.0, dx: 7.0, dy: 0.2, dw: 0.2, why: pa_why_working },
  { drive: "answer-leave", what: Key("alpha 「刚刚」"), from: 4650.0, to: 4650.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_timein },
  { drive: "answer-leave", what: Key("nodes alone 「刚刚」"), from: 2017.0, to: 2450.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "answer-leave", what: Key("nodes alone 「发消息」"), from: 2133.0, to: 2150.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "answer-leave", what: Key("words 「看一下列表的高度」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer-leave", what: Key("words 「刚刚」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_timein },
  { drive: "answer-leave", what: Key("words 「Claude」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer-leave", what: Key("words 「5 分钟前」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer-leave", what: Key("words 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer-leave", what: Key("words 「15 分钟前」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer-leave", what: Key("words 「推送截图前要先登录 gh。」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer-leave", what: Key("words 「在 Willow 上登录 gh」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer-leave", what: Key("words 「等你在浏览器里登录」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer-leave", what: Key("words 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer-leave", what: Key("words 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 4217.0, to: 4317.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer-leave", what: Key("words 「等 林 决定」"), from: 4217.0, to: 4250.0, dx: 0.2, dy: 24.2, dw: 0.2, why: pa_why_working },
  { drive: "answer-leave", what: Key("words 「等 林 决定」"), from: 4333.0, to: 4433.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer-leave", what: Key("words 「等 林 决定」"), from: 4533.0, to: 4533.0, dx: 0.2, dy: 6.7, dw: 0.2, why: pa_why_working },
  { drive: "answer-leave", what: Key("words 「先不换」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer-leave", what: Key("words 「这次只改列表，截图下次再说」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer-leave", what: Key("words 「一起换」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer-leave", what: Key("words 「把首页和聊天页的截图都更新」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer-leave", what: Key("words 「忽略」"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer-leave", what: Key("ground"), from: 4217.0, to: 4533.0, dx: 0.2, dy: 36.2, dw: 0.2, why: pa_why_working },
  { drive: "answer-leave", what: Key("nodes alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 4333.0, to: 4533.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "answer-leave", what: Key("old alone 「等 林 决定」"), from: 4450.0, to: 4517.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "vault-card", what: Key("alpha 「不存」"), from: 883.0, to: 917.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_card },
  { drive: "vault-card", what: Key("alpha 「存入」"), from: 883.0, to: 917.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_card },
  { drive: "vault-card", what: Key("ground"), from: 883.0, to: 1017.0, dx: 39.3, dy: 43.7, dw: 158.5, why: pa_why_card },
  { drive: "vault-card", what: Key("ground alpha"), from: 883.0, to: 917.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_card },
  { drive: "vault-card", what: Key("nodes alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 883.0, to: 900.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-card", what: Key("old alone 「等 林 决定」"), from: 883.0, to: 900.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-card", what: Key("words 「存入密码 测试服务登录  demo-user」"), from: 883.0, to: 917.0, dx: 8.6, dy: 33.1, dw: 95.7, why: pa_why_card },
  { drive: "vault-card", what: Key("words 「把测试服务密码安全保存，方便以后登录」"), from: 883.0, to: 917.0, dx: 8.6, dy: 33.1, dw: 95.7, why: pa_why_card },
  { drive: "vault-card", what: Rows, from: 883.0, to: 1017.0, dx: pa_way_tol, dy: 20.2, dw: pa_way_tol, why: pa_why_card },
  { drive: "vault-card", what: Key("alpha 「存入密码 测试服务登录  demo-user」"), from: 900.0, to: 917.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_card },
  { drive: "vault-card", what: Key("alpha 「把测试服务密码安全保存，方便以后登录」"), from: 900.0, to: 917.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_card },
  { drive: "vault-card", what: Key("ground old alone"), from: 900.0, to: 933.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-card", what: Key("nodes alone 「等 林 决定」"), from: 917.0, to: 917.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-card", what: Key("old alone 「存入密码 测试服务登录  demo-user」"), from: 933.0, to: 933.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-card", what: Key("old alone 「把测试服务密码安全保存，方便以后登录」"), from: 933.0, to: 933.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-card", what: Key("nodes alone 「30 分钟前」"), from: 950.0, to: 1033.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-card", what: Key("nodes alone 「Claude」"), from: 950.0, to: 1033.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-card", what: Key("nodes alone 「未存入 测试服务登录」"), from: 950.0, to: 1117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-card", what: Key("old alone 「30 分钟前」"), from: 983.0, to: 983.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-card", what: Key("old alone 「Claude」"), from: 983.0, to: 983.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-card", what: Key("alpha 「未存入 测试服务登录」"), from: 1133.0, to: 1250.0, dx: 0.2, dy: 0.2, dw: 1.1, why: pa_why_card },
  { drive: "vault-card", what: Key("words 「存入」"), from: 900.0, to: 900.0, dx: 0.2, dy: 20.9, dw: 0.2, why: pa_why_card },
  { drive: "vault-card", what: Key("words 「不存」"), from: 900.0, to: 900.0, dx: 5.6, dy: 20.9, dw: 0.2, why: pa_why_card },
  { drive: "vault-card", what: Key("old alone 「存入」"), from: 917.0, to: 917.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-card", what: Key("old alone 「不存」"), from: 917.0, to: 917.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-decide", what: Key("alpha 「不存」"), from: 883.0, to: 917.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_card },
  { drive: "vault-decide", what: Key("alpha 「存入」"), from: 883.0, to: 917.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_card },
  { drive: "vault-decide", what: Key("ground"), from: 883.0, to: 1017.0, dx: 39.3, dy: 43.7, dw: 158.5, why: pa_why_card },
  { drive: "vault-decide", what: Key("ground alpha"), from: 883.0, to: 917.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_card },
  { drive: "vault-decide", what: Key("nodes alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 883.0, to: 900.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-decide", what: Key("old alone 「等 林 决定」"), from: 883.0, to: 900.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-decide", what: Key("words 「存入密码 测试服务登录  demo-user」"), from: 883.0, to: 917.0, dx: 8.6, dy: 33.1, dw: 95.7, why: pa_why_card },
  { drive: "vault-decide", what: Key("words 「把测试服务密码安全保存，方便以后登录」"), from: 883.0, to: 917.0, dx: 8.6, dy: 33.1, dw: 95.7, why: pa_why_card },
  { drive: "vault-decide", what: Rows, from: 883.0, to: 1017.0, dx: pa_way_tol, dy: 20.2, dw: pa_way_tol, why: pa_why_card },
  { drive: "vault-decide", what: Key("alpha 「存入密码 测试服务登录  demo-user」"), from: 900.0, to: 917.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_card },
  { drive: "vault-decide", what: Key("alpha 「把测试服务密码安全保存，方便以后登录」"), from: 900.0, to: 917.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_card },
  { drive: "vault-decide", what: Key("ground old alone"), from: 900.0, to: 933.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-decide", what: Key("nodes alone 「等 林 决定」"), from: 917.0, to: 917.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-decide", what: Key("old alone 「存入密码 测试服务登录  demo-user」"), from: 933.0, to: 933.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-decide", what: Key("old alone 「把测试服务密码安全保存，方便以后登录」"), from: 933.0, to: 933.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-decide", what: Key("nodes alone 「30 分钟前」"), from: 950.0, to: 1033.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-decide", what: Key("nodes alone 「Claude」"), from: 950.0, to: 1033.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-decide", what: Key("nodes alone 「未存入 测试服务登录」"), from: 950.0, to: 1117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-decide", what: Key("old alone 「30 分钟前」"), from: 983.0, to: 983.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-decide", what: Key("old alone 「Claude」"), from: 983.0, to: 983.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-decide", what: Key("alpha 「未存入 测试服务登录」"), from: 1133.0, to: 1250.0, dx: 0.2, dy: 0.2, dw: 1.1, why: pa_why_card },
  { drive: "vault-decide", what: Key("words 「存入」"), from: 900.0, to: 900.0, dx: 0.2, dy: 20.9, dw: 0.2, why: pa_why_card },
  { drive: "vault-decide", what: Key("words 「不存」"), from: 900.0, to: 900.0, dx: 5.6, dy: 20.9, dw: 0.2, why: pa_why_card },
  { drive: "vault-decide", what: Key("old alone 「存入」"), from: 917.0, to: 917.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-decide", what: Key("old alone 「不存」"), from: 917.0, to: 917.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-file", what: Key("alpha 「存入」"), from: 867.0, to: 883.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_card },
  { drive: "vault-file", what: Key("ground alpha"), from: 867.0, to: 883.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_card },
  { drive: "vault-file", what: Key("nodes alone 「prod-kubeconfig.yaml · 5 KB」"), from: 867.0, to: 867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-file", what: Key("alpha 「prod-kubeconfig.yaml · 5 KB」"), from: 883.0, to: 917.0, dx: 0.2, dy: 0.2, dw: 0.8, why: pa_why_card },
  { drive: "vault-file", what: Key("old alone 「prod-kubeconfig.yaml · 5 KB」"), from: 1767.0, to: 1767.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-file", what: Key("alpha 「不存」"), from: 1783.0, to: 1817.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_card },
  { drive: "vault-file", what: Key("alpha 「存入」"), from: 1783.0, to: 1800.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_card },
  { drive: "vault-file", what: Key("alpha 「选择文件」"), from: 1783.0, to: 1817.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_card },
  { drive: "vault-file", what: Key("ground"), from: 1783.0, to: 1933.0, dx: 43.1, dy: 24.7, dw: 159.2, why: pa_why_card },
  { drive: "vault-file", what: Key("ground alpha"), from: 1783.0, to: 1817.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_card },
  { drive: "vault-file", what: Key("words 「存入文件 生产集群」"), from: 1783.0, to: 1817.0, dx: 8.6, dy: 40.0, dw: 109.1, why: pa_why_card },
  { drive: "vault-file", what: Rows, from: 1783.0, to: 1933.0, dx: pa_way_tol, dy: 24.2, dw: pa_way_tol, why: pa_why_card },
  { drive: "vault-file", what: Key("alpha 「存入文件 生产集群」"), from: 1800.0, to: 1817.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_card },
  { drive: "vault-file", what: Key("nodes alone 「先不换」"), from: 1800.0, to: 1800.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-file", what: Key("nodes alone 「等 林 决定」"), from: 1800.0, to: 1833.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-file", what: Key("ground old alone"), from: 1800.0, to: 1833.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-file", what: Key("nodes alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 1817.0, to: 1817.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-file", what: Key("old alone 「等 林 决定」"), from: 1817.0, to: 1817.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-file", what: Key("old alone 「存入文件 生产集群」"), from: 1833.0, to: 1833.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-file", what: Key("old alone 「选择文件」"), from: 1833.0, to: 1833.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-file", what: Key("nodes alone 「30 分钟前」"), from: 1850.0, to: 1950.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-file", what: Key("nodes alone 「Claude」"), from: 1850.0, to: 1950.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-file", what: Key("nodes alone 「已存入文件 生产集群」"), from: 1850.0, to: 2017.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-file", what: Key("old alone 「30 分钟前」"), from: 1900.0, to: 1900.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-file", what: Key("old alone 「Claude」"), from: 1900.0, to: 1900.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-file", what: Key("alpha 「已存入文件 生产集群」"), from: 2033.0, to: 2150.0, dx: 0.2, dy: 0.2, dw: 1.1, why: pa_why_card },
  { drive: "vault-file", what: Key("words 「选择文件」"), from: 1800.0, to: 1817.0, dx: 0.2, dy: 40.0, dw: 0.2, why: pa_why_card },
  { drive: "vault-file", what: Key("words 「存入」"), from: 1800.0, to: 1800.0, dx: 5.6, dy: 25.3, dw: 0.2, why: pa_why_card },
  { drive: "vault-file", what: Key("words 「不存」"), from: 1800.0, to: 1800.0, dx: 5.6, dy: 25.3, dw: 0.2, why: pa_why_card },
  { drive: "vault-file", what: Key("old alone 「不存」"), from: 1817.0, to: 1817.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-typed", what: Key("alpha 「存入」"), from: 1217.0, to: 1233.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_card },
  { drive: "vault-typed", what: Key("ground alpha"), from: 1217.0, to: 1233.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_card },
  { drive: "vault-typed", what: Key("alpha 「不存」"), from: 2133.0, to: 2167.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_card },
  { drive: "vault-typed", what: Key("alpha 「存入」"), from: 2133.0, to: 2150.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_card },
  { drive: "vault-typed", what: Key("alpha 「粘贴 Token」"), from: 2133.0, to: 2167.0, dx: 0.2, dy: 0.2, dw: 0.6, why: pa_why_card },
  { drive: "vault-typed", what: Key("ground"), from: 2133.0, to: 2283.0, dx: 43.1, dy: 64.6, dw: 112.4, why: pa_why_card },
  { drive: "vault-typed", what: Key("ground alpha"), from: 2133.0, to: 2167.0, dx: 0.2, dy: 0.2, dw: 0.7, why: pa_why_card },
  { drive: "vault-typed", what: Key("ground nodes alone"), from: 2133.0, to: 2133.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-typed", what: Key("old alone 「先不换」"), from: 2133.0, to: 2133.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-typed", what: Key("words 「存入Token OpenCode Go」"), from: 2133.0, to: 2167.0, dx: 8.6, dy: 42.3, dw: 109.1, why: pa_why_card },
  { drive: "vault-typed", what: Key("words 「粘贴 Token」"), from: 2133.0, to: 2167.0, dx: 8.6, dy: 42.3, dw: 109.1, why: pa_why_card },
  { drive: "vault-typed", what: Rows, from: 2133.0, to: 2283.0, dx: pa_way_tol, dy: 25.7, dw: pa_way_tol, why: pa_why_card },
  { drive: "vault-typed", what: Key("alpha 「存入Token OpenCode Go」"), from: 2150.0, to: 2167.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_card },
  { drive: "vault-typed", what: Key("nodes alone 「先不换」"), from: 2150.0, to: 2150.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-typed", what: Key("nodes alone 「等 林 决定」"), from: 2150.0, to: 2183.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-typed", what: Key("ground old alone"), from: 2150.0, to: 2183.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-typed", what: Key("nodes alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 2167.0, to: 2167.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-typed", what: Key("old alone 「等 林 决定」"), from: 2167.0, to: 2167.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-typed", what: Key("old alone 「粘贴 Token」"), from: 2183.0, to: 2183.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-typed", what: Key("nodes alone 「已存入Token OpenCode Go」"), from: 2200.0, to: 2367.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-typed", what: Key("nodes alone 「30 分钟前」"), from: 2217.0, to: 2300.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-typed", what: Key("nodes alone 「Claude」"), from: 2217.0, to: 2300.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-typed", what: Key("old alone 「30 分钟前」"), from: 2250.0, to: 2250.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-typed", what: Key("old alone 「Claude」"), from: 2250.0, to: 2250.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "vault-typed", what: Key("alpha 「已存入Token OpenCode Go」"), from: 2383.0, to: 2500.0, dx: 0.2, dy: 0.2, dw: 1.1, why: pa_why_card },
  { drive: "vault-typed", what: Key("words 「存入」"), from: 2150.0, to: 2150.0, dx: 5.6, dy: 26.6, dw: 0.2, why: pa_why_card },
  { drive: "vault-typed", what: Key("words 「不存」"), from: 2150.0, to: 2150.0, dx: 5.6, dy: 26.6, dw: 0.2, why: pa_why_card },
  { drive: "vault-typed", what: Key("old alone 「不存」"), from: 2167.0, to: 2167.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_card },
  { drive: "desk-panel-picture-quote", what: Key("button @outline old alone"), from: 617.0, to: 617.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_panel_mine },
  { drive: "desk-panel-picture-quote", what: Key("words 「30 分钟前」"), from: 617.0, to: 717.0, dx: 25.2, dy: 11.3, dw: 0.2, why: pa_why_panel_mine },
  { drive: "desk-panel-picture-quote", what: Key("words 「Claude」"), from: 617.0, to: 717.0, dx: 25.2, dy: 11.3, dw: 0.2, why: pa_why_panel_mine },
  { drive: "desk-panel-picture-quote", what: Key("words 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 617.0, to: 617.0, dx: 0.2, dy: 0.2, dw: 181.2, why: pa_why_panel_mine },
  { drive: "desk-panel-picture-quote", what: Key("words 「忽略」"), from: 617.0, to: 717.0, dx: 3.6, dy: 7.3, dw: 181.2, why: pa_why_panel_mine },
  { drive: "desk-panel-picture-quote", what: Key("words 「推送截图前要先登录 gh。」"), from: 617.0, to: 617.0, dx: 0.2, dy: 0.2, dw: 181.2, why: pa_why_panel_mine },
  { drive: "desk-panel-picture-quote", what: Key("words 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 617.0, to: 717.0, dx: 3.6, dy: 7.3, dw: 181.2, why: pa_why_panel_mine },
  { drive: "desk-panel-picture-quote", what: Key("ground"), from: 633.0, to: 817.0, dx: 90.7, dy: 7.3, dw: 0.2, why: pa_why_panel_mine },
  { drive: "desk-panel-picture-quote", what: Key("words 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 633.0, to: 817.0, dx: 90.7, dy: 5.0, dw: 0.2, why: pa_why_panel_mine },
  { drive: "desk-panel-picture-quote", what: Rows, from: 667.0, to: 717.0, dx: pa_way_tol, dy: 7.3, dw: pa_way_tol, why: pa_why_panel_mine },
  { drive: "desk-panel-picture-quote", what: Key("nodes alone 「40 分钟前」"), from: 700.0, to: 717.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_panel_mine },
  { drive: "desk-panel-picture-quote", what: Key("words 「40 分钟前」"), from: 733.0, to: 850.0, dx: 54.2, dy: 5.7, dw: 0.2, why: pa_why_panel_mine },
  { drive: "desk-panel-picture-quote", what: Key("ground nodes alone"), from: 1217.0, to: 1317.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_tip },
  { drive: "desk-panel-picture-quote", what: Key("nodes alone 「Esc」"), from: 1233.0, to: 1333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_tip },
  { drive: "desk-panel-picture-quote", what: Key("nodes alone 「收起侧栏」"), from: 1233.0, to: 1333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_tip },
  { drive: "desk-panel-picture-quote", what: Key("old alone 「引用」"), from: 2650.0, to: 2650.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_menu },
  { drive: "desk-panel-picture-quote", what: Key("button @asks.go nodes alone"), from: 4600.0, to: 6817.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-panel-picture-quote", what: Key("old alone 「添加说明（可选）」"), from: 4600.0, to: 4783.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-panel-picture-quote", what: Key("composer"), from: 4617.0, to: 4750.0, dx: 0.2, dy: 136.2, dw: 136.2, why: pa_why_send },
  { drive: "desk-panel-picture-quote", what: Key("ground nodes alone"), from: 4617.0, to: 4867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-panel-picture-quote", what: Key("ground old alone"), from: 4617.0, to: 4767.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-panel-picture-quote", what: Key("picture"), from: 4617.0, to: 5117.0, dx: 105.9, dy: 109.5, dw: 67.9, why: pa_why_bell },
  { drive: "desk-panel-picture-quote", what: Key("ring old alone"), from: 4617.0, to: 4867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "desk-panel-picture-quote", what: Key("words 「Claude：先登录 gh。」"), from: 4683.0, to: 4783.0, dx: 97.9, dy: 22.3, dw: 0.2, why: pa_why_send },
  { drive: "desk-panel-picture-quote", what: Key("ground"), from: 4783.0, to: 5117.0, dx: 131.7, dy: 98.0, dw: 345.4, why: pa_why_bell },
  { drive: "desk-panel-picture-quote", what: Key("ground alpha"), from: 4783.0, to: 5000.0, dx: 0.2, dy: 0.2, dw: 1.1, why: pa_why_bell },
  { drive: "desk-panel-picture-quote", what: Key("nodes alone 「Claude：先登录 gh。」"), from: 4800.0, to: 4917.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-panel-picture-quote", what: Key("old alone 「Claude：先登录 gh。」"), from: 4800.0, to: 4917.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "desk-panel-picture-quote", what: Rows, from: 4817.0, to: 4867.0, dx: pa_way_tol, dy: 13.2, dw: pa_way_tol, why: pa_why_send },
  { drive: "desk-panel-picture-quote", what: Key("nodes alone 「这次只改列表，截图下次再说」"), from: 4833.0, to: 4883.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-panel-picture-quote", what: Key("old alone 「先不换」"), from: 4833.0, to: 4833.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-panel-picture-quote", what: Key("old alone 「这次只改列表，截图下次再说」"), from: 4850.0, to: 4850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-panel-picture-quote", what: Key("nodes alone 「处理中」"), from: 4883.0, to: 4883.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-panel-picture-quote", what: Key("ring"), from: 4883.0, to: 4917.0, dx: 5.4, dy: 4.5, dw: 10.5, why: pa_why_bell },
  { drive: "desk-panel-picture-quote", what: Key("ring alpha"), from: 4883.0, to: 4983.0, dx: 0.2, dy: 0.2, dw: 1.1, why: pa_why_bell },
  { drive: "desk-panel-picture-quote", what: Key("alpha 「处理中」"), from: 4900.0, to: 4983.0, dx: 0.2, dy: 0.2, dw: 0.9, why: pa_why_working },
  { drive: "desk-panel-picture-quote", what: Key("words 「处理中」"), from: 4900.0, to: 4967.0, dx: 9.9, dy: 7.3, dw: 12.2, why: pa_why_working },
  { drive: "desk-panel-picture-quote", what: Key("nodes alone 「把首页和聊天页的截图都更新」"), from: 4917.0, to: 4917.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-panel-picture-quote", what: Key("words 「Claude：先登录 gh。」"), from: 4933.0, to: 5117.0, dx: 42.3, dy: 74.4, dw: 0.2, why: pa_why_send },
  { drive: "desk-panel-picture-quote", what: Key("old alone 「忽略」"), from: 5000.0, to: 5000.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-panel-picture-quote", what: Key("old alone 「把首页和聊天页的截图都更新」"), from: 5017.0, to: 5017.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-panel-picture-quote", what: Key("words 「0s」"), from: 6717.0, to: 6733.0, dx: 36.2, dy: 0.2, dw: 3.0, why: pa_why_working },
  { drive: "desk-panel-picture-quote", what: Key("words 「处理中」"), from: 6717.0, to: 6717.0, dx: 0.2, dy: 0.2, dw: 17.0, why: pa_why_working },
  { drive: "desk-panel-picture-quote", what: Key("nodes alone 「处理中」"), from: 6733.0, to: 6783.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-panel-picture-quote", what: Key("nodes alone 「0s」"), from: 6750.0, to: 6783.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-panel-picture-quote", what: Key("old alone 「处理中」"), from: 6800.0, to: 6800.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "desk-panel-picture-quote", what: Key("words 「Claude」"), from: 650.0, to: 750.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「30 分钟前」"), from: 650.0, to: 750.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 650.0, to: 750.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「等 林 决定」"), from: 650.0, to: 750.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「先不换」"), from: 650.0, to: 750.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「这次只改列表，截图下次再说」"), from: 650.0, to: 750.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「一起换」"), from: 650.0, to: 750.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「把首页和聊天页的截图都更新」"), from: 650.0, to: 750.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「忽略」"), from: 650.0, to: 750.0, dx: 4.2, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-panel-picture-quote", what: Key("ground"), from: 650.0, to: 717.0, dx: 56.0, dy: 11.3, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 667.0, to: 717.0, dx: 68.2, dy: 9.0, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-panel-picture-quote", what: Key("nodes alone 「40 分钟前」"), from: 683.0, to: 683.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_room_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「40 分钟前」"), from: 733.0, to: 750.0, dx: 54.2, dy: 8.7, dw: 0.2, why: pa_why_room_way },
  { drive: "desk-panel-picture-quote", what: Key("old alone 「详情」"), from: 1233.0, to: 1233.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_tip },
  { drive: "desk-panel-picture-quote", what: Key("words 「5 分钟前」"), from: 633.0, to: 717.0, dx: 19.5, dy: 4.5, dw: 0.2, why: pa_why_send },
  { drive: "desk-panel-picture-quote", what: Key("words 「15 分钟前」"), from: 633.0, to: 717.0, dx: 19.5, dy: 7.0, dw: 0.2, why: pa_why_send },
  { drive: "desk-panel-picture-quote", what: Key("old alone 「刚刚」"), from: 5033.0, to: 5117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "viewer", what: Key("nodes alone 「1 小时前」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("nodes alone 「40 分钟前」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("nodes alone 「Claude：其余的行按估计的高度占位，滚到时再量真实高度」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("nodes alone 「发布清单 第三项已经核对完：安装包签名正确。」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("nodes alone 「发送到」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("nodes alone 「对比图和构建日志附在下面。」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("nodes alone 「星火#发布」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("nodes alone 「等 林 决定」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("nodes alone 「这里的高度是怎么估的？」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("nodes alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「.log」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「1 小时前」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「15 分钟前」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「18 KB」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「30 分钟前」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「40 分钟前」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「Claude」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「Claude：其余的行按估计的高度占位，滚到时再量真实高度」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「build」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「一起换」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「先不换」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「发布清单 第三项已经核对完：安装包签名正确。」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「发送到」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「忽略」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「把首页和聊天页的截图都更新」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「推送截图前要先登录 gh。」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「星火#发布」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「等 林 决定」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「还有深色模式也看一下」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「这次只改列表，截图下次再说」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「这里的高度是怎么估的？」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Rows, from: 1850.0, to: 1850.0, dx: pa_way_tol, dy: 20.7, dw: pa_way_tol, why: pa_why_wheel },
  { drive: "viewer", what: Key("nodes alone 「1 小时前」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("nodes alone 「Claude：其余的行按估计的高度占位，滚到时再量真实高度」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("nodes alone 「发布清单 第三项已经核对完：安装包签名正确。」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("nodes alone 「发送到」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("nodes alone 「对比图和构建日志附在下面。」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("nodes alone 「星火#发布」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「.log」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「1 小时前」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「18 KB」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「30 分钟前」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「40 分钟前」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「Claude」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「Claude：其余的行按估计的高度占位，滚到时再量真实高度」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「build」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「先不换」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「发布清单 第三项已经核对完：安装包签名正确。」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「发送到」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「对比图和构建日志附在下面。」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「星火#发布」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「等 林 决定」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「还有深色模式也看一下」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「这里的高度是怎么估的？」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer", what: Rows, from: 2067.0, to: 2067.0, dx: pa_way_tol, dy: 20.7, dw: pa_way_tol, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("nodes alone 「1 小时前」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("nodes alone 「40 分钟前」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("nodes alone 「Claude：其余的行按估计的高度占位，滚到时再量真实高度」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("nodes alone 「发布清单 第三项已经核对完：安装包签名正确。」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("nodes alone 「发送到」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("nodes alone 「对比图和构建日志附在下面。」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("nodes alone 「星火#发布」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("nodes alone 「等 林 决定」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("nodes alone 「这里的高度是怎么估的？」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("nodes alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「.log」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「1 小时前」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「15 分钟前」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「18 KB」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「30 分钟前」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「40 分钟前」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「Claude」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「Claude：其余的行按估计的高度占位，滚到时再量真实高度」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「build」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「一起换」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「先不换」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「发布清单 第三项已经核对完：安装包签名正确。」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「发送到」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「忽略」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「把首页和聊天页的截图都更新」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「推送截图前要先登录 gh。」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「星火#发布」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「等 林 决定」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「还有深色模式也看一下」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「这次只改列表，截图下次再说」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「这里的高度是怎么估的？」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Rows, from: 1850.0, to: 1850.0, dx: pa_way_tol, dy: 20.7, dw: pa_way_tol, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("nodes alone 「1 小时前」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("nodes alone 「Claude：其余的行按估计的高度占位，滚到时再量真实高度」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("nodes alone 「发布清单 第三项已经核对完：安装包签名正确。」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("nodes alone 「发送到」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("nodes alone 「对比图和构建日志附在下面。」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("nodes alone 「星火#发布」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「.log」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「1 小时前」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「18 KB」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「30 分钟前」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「40 分钟前」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「Claude」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「Claude：其余的行按估计的高度占位，滚到时再量真实高度」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「build」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「先不换」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「发布清单 第三项已经核对完：安装包签名正确。」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「发送到」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「对比图和构建日志附在下面。」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「星火#发布」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「等 林 决定」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「还有深色模式也看一下」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「这里的高度是怎么估的？」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "viewer-open", what: Rows, from: 2067.0, to: 2067.0, dx: pa_way_tol, dy: 20.7, dw: pa_way_tol, why: pa_why_wheel },
  { drive: "viewer-video", what: Key("button @asks.go nodes alone"), from: 17.0, to: 633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "viewer-video", what: Key("old alone 「0:13」"), from: 650.0, to: 650.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_viewer },
  { drive: "viewer-video", what: Key("button @asks.go nodes alone"), from: 2183.0, to: 3700.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "viewer-video-medium", what: Key("old alone 「0:13」"), from: 1550.0, to: 1550.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_viewer },
  { drive: "picture-lift", what: Key("nodes alone 「1 小时前」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("nodes alone 「40 分钟前」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("nodes alone 「Claude：其余的行按估计的高度占位，滚到时再量真实高度」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("nodes alone 「发布清单 第三项已经核对完：安装包签名正确。」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("nodes alone 「发送到」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("nodes alone 「对比图和构建日志附在下面。」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("nodes alone 「星火#发布」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("nodes alone 「等 林 决定」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("nodes alone 「这里的高度是怎么估的？」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("nodes alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「.log」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「1 小时前」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「15 分钟前」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「18 KB」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「30 分钟前」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「40 分钟前」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「Claude」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「Claude：其余的行按估计的高度占位，滚到时再量真实高度」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「build」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「一起换」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「先不换」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「发布清单 第三项已经核对完：安装包签名正确。」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「发送到」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「忽略」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「把首页和聊天页的截图都更新」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「推送截图前要先登录 gh。」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「星火#发布」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「等 林 决定」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「还有深色模式也看一下」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「这次只改列表，截图下次再说」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「这里的高度是怎么估的？」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Rows, from: 1850.0, to: 1850.0, dx: pa_way_tol, dy: 20.7, dw: pa_way_tol, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("nodes alone 「1 小时前」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("nodes alone 「Claude：其余的行按估计的高度占位，滚到时再量真实高度」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("nodes alone 「发布清单 第三项已经核对完：安装包签名正确。」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("nodes alone 「发送到」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("nodes alone 「对比图和构建日志附在下面。」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("nodes alone 「星火#发布」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「.log」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「1 小时前」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「18 KB」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「30 分钟前」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「40 分钟前」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「Claude」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「Claude：其余的行按估计的高度占位，滚到时再量真实高度」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「build」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「先不换」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「发布清单 第三项已经核对完：安装包签名正确。」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「发送到」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「对比图和构建日志附在下面。」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  // (6667: the menu's sheet of the window's tree goes from the frame of the press that closes it, the host's a frame on)
  { drive: "picture-lift", what: Key("old alone 「星火#发布」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「等 林 决定」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「还有深色模式也看一下」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「这里的高度是怎么估的？」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 2067.0, to: 2067.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "picture-lift", what: Rows, from: 2067.0, to: 2067.0, dx: pa_way_tol, dy: 20.7, dw: pa_way_tol, why: pa_why_wheel },
  { drive: "picture-lift", what: Key("nodes alone 「发消息」"), from: 4583.0, to: 6617.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_lift },
  { drive: "wide-images", what: Key("button @outline nodes alone"), from: 417.0, to: 417.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("button 跳到最新 nodes alone"), from: 417.0, to: 417.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("button @asks.go nodes alone"), from: 633.0, to: 633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "wide-images", what: Key("nodes alone 「.log」"), from: 633.0, to: 633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("nodes alone 「build」"), from: 633.0, to: 633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("nodes alone 「对比图和构建日志附在下面。」"), from: 633.0, to: 633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("nodes alone 「这次只改列表，截图下次再说」"), from: 633.0, to: 633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「1 小时前」"), from: 633.0, to: 633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「30 分钟前」"), from: 633.0, to: 633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「40 分钟前」"), from: 633.0, to: 633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「Claude」"), from: 633.0, to: 633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「Claude：其余的行按估计的高度占位，滚到时再量真实高度」"), from: 633.0, to: 633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「Willow 上 codex 的登录已失效：请在设置里重新登录」"), from: 633.0, to: 633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「一起换」"), from: 633.0, to: 633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「先不换」"), from: 633.0, to: 633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「发布清单 第三项已经核对完：安装包签名正确。」"), from: 633.0, to: 633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「发送到」"), from: 633.0, to: 633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「忽略」"), from: 633.0, to: 633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「把首页和聊天页的截图都更新」"), from: 633.0, to: 633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「星火#发布」"), from: 633.0, to: 633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「等 林 决定」"), from: 633.0, to: 633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「等你在浏览器里登录」"), from: 633.0, to: 633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「还有深色模式也看一下」"), from: 633.0, to: 633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「这次只改列表，截图下次再说」"), from: 633.0, to: 633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「这里的高度是怎么估的？」"), from: 633.0, to: 633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「高度先按 90 估，量过一次就记住。深色模式我一起看。要不要把旧的截图也一起换掉？」"), from: 633.0, to: 633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Rows, from: 633.0, to: 633.0, dx: pa_way_tol, dy: 46.7, dw: pa_way_tol, why: pa_why_wheel },
  { drive: "wide-images", what: Key("nodes alone 「.log」"), from: 850.0, to: 850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("nodes alone 「build」"), from: 850.0, to: 850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("nodes alone 「对比图和构建日志附在下面。」"), from: 850.0, to: 850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「.log」"), from: 850.0, to: 850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「1 小时前」"), from: 850.0, to: 850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「18 KB」"), from: 850.0, to: 850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「30 分钟前」"), from: 850.0, to: 850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「40 分钟前」"), from: 850.0, to: 850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「Claude」"), from: 850.0, to: 850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「Claude：其余的行按估计的高度占位，滚到时再量真实高度」"), from: 850.0, to: 850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「build」"), from: 850.0, to: 850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「发布清单 第三项已经核对完：安装包签名正确。」"), from: 850.0, to: 850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「发送到」"), from: 850.0, to: 850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「对比图和构建日志附在下面。」"), from: 850.0, to: 850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「星火#发布」"), from: 850.0, to: 850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「还有深色模式也看一下」"), from: 850.0, to: 850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「这次只改列表，截图下次再说」"), from: 850.0, to: 850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "wide-images", what: Key("old alone 「这里的高度是怎么估的？」"), from: 850.0, to: 850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_wheel },
  { drive: "send-quote-video", what: Key("button @outline old alone"), from: 617.0, to: 617.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-video", what: Key("button @asks.go old alone"), from: 617.0, to: 617.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "send-quote-video", what: Key("ground nodes alone"), from: 633.0, to: 633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-quote-video", what: Key("ground alpha"), from: 650.0, to: 650.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_menu },
  { drive: "send-quote-video", what: Key("nodes alone 「复制消息链接」"), from: 650.0, to: 650.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_menu },
  { drive: "send-quote-video", what: Key("nodes alone 「多选」"), from: 650.0, to: 650.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_menu },
  { drive: "send-quote-video", what: Key("picture old alone"), from: 650.0, to: 650.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_menu },
  { drive: "send-quote-video", what: Key("nodes alone 「下载」"), from: 650.0, to: 650.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_menu },
  { drive: "send-quote-video", what: Key("nodes alone 「加载」"), from: 650.0, to: 650.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_menu },
  { drive: "send-quote-video", what: Key("nodes alone 「在侧边打开」"), from: 650.0, to: 650.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_menu },
  { drive: "send-quote-video", what: Key("nodes alone 「引用」"), from: 650.0, to: 650.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_menu },
  { drive: "send-quote-video", what: Key("alpha 「复制消息链接」"), from: 667.0, to: 667.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_menu },
  { drive: "send-quote-video", what: Key("alpha 「多选」"), from: 667.0, to: 667.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_menu },
  { drive: "send-quote-video", what: Key("alpha 「下载」"), from: 667.0, to: 667.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_menu },
  { drive: "send-quote-video", what: Key("alpha 「加载」"), from: 667.0, to: 667.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_menu },
  { drive: "send-quote-video", what: Key("alpha 「在侧边打开」"), from: 667.0, to: 667.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_menu },
  { drive: "send-quote-video", what: Key("alpha 「引用」"), from: 667.0, to: 667.0, dx: 0.2, dy: 0.2, dw: 0.5, why: pa_why_menu },
  { drive: "send-quote-video", what: Key("old alone 「添加说明（可选）」"), from: 1950.0, to: 2133.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_quote_flight },
  { drive: "send-quote-video", what: Key("button @outline"), from: 1967.0, to: 2350.0, dx: 0.2, dy: 66.2, dw: 0.2, why: pa_why_send },
  { drive: "send-quote-video", what: Key("button @asks.go nodes alone"), from: 1967.0, to: 2133.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "send-quote-video", what: Key("button @asks.go old alone"), from: 1967.0, to: 2133.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "send-quote-video", what: Key("composer"), from: 1967.0, to: 2100.0, dx: 0.2, dy: 132.2, dw: 132.2, why: pa_why_quote_flight },
  { drive: "send-quote-video", what: Key("ground nodes alone"), from: 1967.0, to: 2117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_quote_flight },
  { drive: "send-quote-video", what: Key("ground old alone"), from: 1967.0, to: 2117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_quote_flight },
  { drive: "send-quote-video", what: Key("picture"), from: 1967.0, to: 2467.0, dx: 121.7, dy: 102.2, dw: 112.1, why: pa_why_quote_flight },
  { drive: "send-quote-video", what: Key("words 「Claude：演示录屏.mp4」"), from: 2033.0, to: 2133.0, dx: 92.3, dy: 23.2, dw: 0.2, why: pa_why_quote_flight },
  { drive: "send-quote-video", what: Key("ground"), from: 2117.0, to: 2467.0, dx: 124.2, dy: 101.8, dw: 337.3, why: pa_why_quote_flight },
  { drive: "send-quote-video", what: Key("old alone 「在 Willow 上登录 gh」"), from: 2117.0, to: 2117.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_quote_flight },
  { drive: "send-quote-video", what: Rows, from: 2117.0, to: 2217.0, dx: pa_way_tol, dy: 14.2, dw: pa_way_tol, why: pa_why_send },
  { drive: "send-quote-video", what: Key("ground alpha"), from: 2133.0, to: 2350.0, dx: 0.2, dy: 0.2, dw: 1.1, why: pa_why_quote_flight },
  { drive: "send-quote-video", what: Key("button @asks.go"), from: 2150.0, to: 2400.0, dx: 0.2, dy: 115.9, dw: 0.2, why: pa_why_bell },
  { drive: "send-quote-video", what: Key("nodes alone 「Claude：演示录屏.mp4」"), from: 2150.0, to: 2267.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_quote_flight },
  { drive: "send-quote-video", what: Key("old alone 「Claude：演示录屏.mp4」"), from: 2150.0, to: 2267.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_quote_flight },
  { drive: "send-quote-video", what: Key("nodes alone 「Claude」"), from: 2267.0, to: 2267.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_quote_flight },
  { drive: "send-quote-video", what: Key("old alone 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 2283.0, to: 2283.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_quote_flight },
  { drive: "send-quote-video", what: Key("words 「Claude：演示录屏.mp4」"), from: 2283.0, to: 2467.0, dx: 39.9, dy: 77.7, dw: 0.2, why: pa_why_quote_flight },
  { drive: "send-quote-video", what: Key("nodes alone 「做完了：列表、跳到最新的按钮、加载更早的消息都好了，截图也换了。」"), from: 2317.0, to: 2317.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_quote_flight },
  { drive: "send-quote-video", what: Key("old alone 「Claude」"), from: 2333.0, to: 2333.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_quote_flight },
  { drive: "send-quote-video", what: Key("nodes alone 「0:13」"), from: 2483.0, to: 2583.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_quote_flight },
  { drive: "send-quote-video", what: Key("alpha 「0:13」"), from: 2600.0, to: 2633.0, dx: 0.2, dy: 0.2, dw: 0.8, why: pa_why_send },
  { drive: "send-quote-video", what: Key("ring old alone"), from: 2650.0, to: 2700.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_old_ring },
  { drive: "send-quote-video", what: Key("old alone 「0s」"), from: 2667.0, to: 2700.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_working },
  { drive: "send-quote-video", what: Key("alpha 「0s」"), from: 2717.0, to: 2783.0, dx: 0.2, dy: 0.2, dw: 0.8, why: pa_why_working },
  { drive: "send-quote-video", what: Key("ring"), from: 2717.0, to: 2733.0, dx: 5.1, dy: 1.2, dw: 10.0, why: pa_why_send },
  { drive: "send-quote-video", what: Key("ring alpha"), from: 2717.0, to: 2783.0, dx: 0.2, dy: 0.2, dw: 1.0, why: pa_why_send },
  { drive: "send-quote-video", what: Key("words 「0s」"), from: 2717.0, to: 2783.0, dx: 30.1, dy: 3.1, dw: 5.1, why: pa_why_working },
  { drive: "send-quote-video", what: Key("nodes alone 「Claude」"), from: 2750.0, to: 2750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "send-quote-video", what: Key("nodes alone 「处理中」"), from: 2767.0, to: 2767.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "send-quote-video", what: Key("alpha 「处理中」"), from: 2783.0, to: 2783.0, dx: 0.2, dy: 0.2, dw: 0.4, why: pa_why_working },
  { drive: "send-quote-video", what: Key("old alone 「打好的发布包在这里，下载下来装一下看看。」"), from: 2850.0, to: 2867.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "send-quote-video", what: Key("old alone 「刚刚」"), from: 2400.0, to: 2467.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_timein },
  { drive: "chat-uploading-files", what: Key("button @asks.go nodes alone"), from: 17.0, to: 1517.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_bell },
  { drive: "desk-composer-attachments-toggle", what: Key("picture nodes alone"), from: 3583.0, to: 3717.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("nodes alone 「构建日志」"), from: 4800.0, to: 4850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("nodes alone 「.log」"), from: 4800.0, to: 4850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("nodes alone 「2 KB」"), from: 4800.0, to: 4850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("ground nodes alone"), from: 4800.0, to: 4800.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "desk-composer-attachments-toggle", what: Key("nodes alone 「发消息」"), from: 4850.0, to: 4900.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-picture", what: Key("words 「发消息」"), from: 1517.0, to: 1550.0, dx: 5.9, dy: 7.9, dw: 66.1, why: pa_why_composer_way },
  { drive: "send-quote", what: Key("old alone 「发消息」"), from: 1767.0, to: 1767.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote", what: Key("composer"), from: 1767.0, to: 1767.0, dx: 0.1, dy: 43.1, dw: 42.9, why: pa_why_composer_way },
  { drive: "send-quote", what: Rows, from: 1783.0, to: 1950.0, dx: pa_way_tol, dy: 42.6, dw: pa_way_tol, why: pa_why_composer_way },
  { drive: "send-quote", what: Key("old alone 「还有深色模式也看一下」"), from: 1783.0, to: 1800.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote", what: Key("ground"), from: 1783.0, to: 1900.0, dx: 92.4, dy: 44.3, dw: 182.0, why: pa_why_composer_way },
  { drive: "send-quote", what: Key("ground old alone"), from: 1783.0, to: 1800.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote", what: Key("nodes alone 「添加说明（可选）」"), from: 1800.0, to: 1833.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote", what: Key("ground nodes alone"), from: 1817.0, to: 1833.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote", what: Key("old alone 「40 分钟前」"), from: 1833.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote", what: Key("nodes alone 「Claude：先」"), from: 1833.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote", what: Key("words 「Claude：先」"), from: 1867.0, to: 1867.0, dx: 0.1, dy: 45.4, dw: 0.1, why: pa_why_composer_way },
  { drive: "send-over-line", what: Key("old alone 「一起换」"), from: 3617.0, to: 3700.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("ground alpha"), from: 3617.0, to: 3783.0, dx: 0.1, dy: 0.1, dw: 1.0, why: pa_why_send },
  { drive: "send-over-line", what: Key("ground old alone"), from: 3617.0, to: 3667.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("nodes alone 「这次只改列表，截图下次再说」"), from: 3833.0, to: 3833.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-over-line", what: Key("nodes alone 「一起换」"), from: 3900.0, to: 3933.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_send },
  { drive: "send-picture-only", what: Key("words 「发消息」"), from: 2550.0, to: 2583.0, dx: 5.9, dy: 7.9, dw: 66.1, why: pa_why_composer_way },
  { drive: "desk-panel-picture-quote", what: Key("words 「Claude：先登录 gh。」"), from: 3700.0, to: 3733.0, dx: 0.1, dy: 12.0, dw: 0.1, why: pa_why_composer_way },
  { drive: "send", what: Key("words 「发消息」"), from: 683.0, to: 683.0, dx: 0.1, dy: 0.3, dw: 66.2, why: pa_why_composer_way },
  { drive: "send-lines", what: Key("words 「发消息」"), from: 683.0, to: 683.0, dx: 0.1, dy: 0.3, dw: 66.2, why: pa_why_composer_way },
  { drive: "send-picture", what: Key("old alone 「发消息」"), from: 1817.0, to: 1817.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "answer", what: Key("words 「发消息」"), from: 683.0, to: 683.0, dx: 0.1, dy: 0.3, dw: 66.2, why: pa_why_composer_way },
  { drive: "send-long", what: Key("words 「发消息」"), from: 683.0, to: 683.0, dx: 0.1, dy: 0.3, dw: 66.2, why: pa_why_composer_way },
  { drive: "send-over-line", what: Key("words 「发消息」"), from: 683.0, to: 683.0, dx: 0.1, dy: 0.3, dw: 66.2, why: pa_why_composer_way },
  { drive: "send-picture-only", what: Key("old alone 「发消息」"), from: 2850.0, to: 2850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_composer_way },
  { drive: "send-quote-picture", what: Key("button 跳到最新 nodes alone"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_float_frame },
  { drive: "send-quote-picture", what: Key("button 对话目录 nodes alone"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_float_frame },
  { drive: "send-quote-picture", what: Key("button 跳转到待决策的消息 nodes alone"), from: 1750.0, to: 1750.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_float_frame },
  { drive: "scrolled-reply", what: Key("words 「发消息」"), from: 683.0, to: 683.0, dx: 0.1, dy: 0.3, dw: 66.2, why: pa_why_composer_way },
  { drive: "scrolled-reply", what: Key("button 跳到最新 nodes alone"), from: 3467.0, to: 3467.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_float_frame },
  { drive: "scrolled-reply", what: Key("button 对话目录 nodes alone"), from: 3467.0, to: 3467.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_float_frame },
  { drive: "scrolled-reply-near", what: Key("words 「发消息」"), from: 683.0, to: 683.0, dx: 0.1, dy: 0.3, dw: 66.2, why: pa_why_composer_way },
  { drive: "answer-leave", what: Key("words 「发消息」"), from: 683.0, to: 683.0, dx: 0.1, dy: 0.3, dw: 66.2, why: pa_why_composer_way },
  { drive: "viewer", what: Key("button 跳到最新 nodes alone"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_float_frame },
  { drive: "viewer", what: Key("button 对话目录 nodes alone"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_float_frame },
  { drive: "viewer", what: Key("button 跳转到待决策的消息 nodes alone"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_float_frame },
  { drive: "viewer-open", what: Key("button 跳到最新 nodes alone"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_float_frame },
  { drive: "viewer-open", what: Key("button 对话目录 nodes alone"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_float_frame },
  { drive: "viewer-open", what: Key("button 跳转到待决策的消息 nodes alone"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_float_frame },
  { drive: "picture-lift", what: Key("button 跳到最新 nodes alone"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_float_frame },
  { drive: "picture-lift", what: Key("button 对话目录 nodes alone"), from: 1633.0, to: 1633.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_float_frame },
  { drive: "picture-lift", what: Key("button 跳转到待决策的消息 nodes alone"), from: 1850.0, to: 1850.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_float_frame },
  { drive: "desk-right-panel-toggle", what: Key("nodes alone 「详情」"), from: 1283.0, to: 1283.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_side_switch },
  { drive: "desk-right-panel-toggle", what: Key("alpha 「收起侧栏」"), from: 1300.0, to: 1317.0, dx: 0.1, dy: 0.1, dw: 0.5, why: pa_why_side_switch },
  { drive: "desk-right-panel-toggle", what: Key("alpha 「Esc」"), from: 1300.0, to: 1317.0, dx: 0.1, dy: 0.1, dw: 0.5, why: pa_why_side_switch },
  { drive: "wide-side-panel", what: Key("nodes alone 「详情」"), from: 1283.0, to: 1283.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_side_switch },
  { drive: "wide-side-panel", what: Key("nodes alone 「详情」"), from: 2717.0, to: 2717.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_side_switch },
  { drive: "wide-side-panel", what: Key("alpha 「收起侧栏」"), from: 1300.0, to: 1317.0, dx: 0.1, dy: 0.1, dw: 0.5, why: pa_why_side_switch },
  { drive: "wide-side-panel", what: Key("alpha 「收起侧栏」"), from: 2750.0, to: 2750.0, dx: 0.1, dy: 0.1, dw: 0.3, why: pa_why_side_switch },
  { drive: "wide-side-panel", what: Key("alpha 「Esc」"), from: 1300.0, to: 1317.0, dx: 0.1, dy: 0.1, dw: 0.5, why: pa_why_side_switch },
  { drive: "wide-side-panel", what: Key("alpha 「Esc」"), from: 2750.0, to: 2750.0, dx: 0.1, dy: 0.1, dw: 0.3, why: pa_why_side_switch },
  { drive: "wide-side-panel", what: Key("old alone 「详情」"), from: 2667.0, to: 2667.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_side_switch },
  { drive: "wide-side-panel", what: Key("ground nodes alone"), from: 2700.0, to: 2700.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_side_switch },
  { drive: "wide-side-panel", what: Key("nodes alone 「收起侧栏」"), from: 2717.0, to: 2717.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_side_switch },
  { drive: "wide-side-panel", what: Key("nodes alone 「Esc」"), from: 2717.0, to: 2717.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_side_switch },
  { drive: "desk-panel-picture-quote", what: Key("nodes alone 「详情」"), from: 1283.0, to: 1283.0, dx: pa_alone_any, dy: pa_alone_any, dw: pa_alone_any, why: pa_why_side_switch },
  { drive: "desk-panel-picture-quote", what: Key("alpha 「收起侧栏」"), from: 1300.0, to: 1317.0, dx: 0.1, dy: 0.1, dw: 0.5, why: pa_why_side_switch },
  { drive: "desk-panel-picture-quote", what: Key("alpha 「Esc」"), from: 1300.0, to: 1317.0, dx: 0.1, dy: 0.1, dw: 0.5, why: pa_why_side_switch },
]

///|
/// `script` run over `mode` both ways, `w` × `h` playing `platform`, named `name`: what fails, printed with what known
/// let pass; none, or why it fails. What fails: a drive that did not pass; a frame on the way that differs past
/// pa_way_tol where no row of pa_way_known says it, and a row of this drive's that let nothing pass; a frame at rest on
/// both sides (pa_still_frames still, a wait's end and the last) that differs past pa_rest_tol in where anything is or in
/// what shows (pa_known aside); a frame of the page as nodes drawn where all goes for one frame and back the next
/// (pa_spikes).
fn pa_compare(
  name : String,
  mode : String,
  w : Double,
  h : Double,
  platform : Int,
  script : String,
) -> String? {
  let (old, old_failed) = pa_run(mode, false, w, h, platform, script)
  let (nodes, nodes_failed) = pa_run(mode, true, w, h, platform, script)
  let fails = []
  let notes = []
  for l in old_failed {
    fails.push("old drive: \{l}")
  }
  for l in nodes_failed {
    fails.push("nodes drive: \{l}")
  }
  let n = if old.length() < nodes.length() { old.length() } else { nodes.length() }
  // (on the way: what differs past pa_way_tol and no row of pa_way_known says, failing, each thing's stretches once;
  // what a row says, counted against it)
  let seen : Map[String, Array[PaStretch]] = Map([])
  let order : Array[String] = []
  let used : Map[Int, Int] = Map([])
  // (at rest: each frame both sides drew still for pa_still_frames, the last such of each stretch, and the last frame)
  let mut still_o = 0
  let mut still_n = 0
  let rest_at : Array[Int] = []
  for i in 0..<n {
    let (o, d) = (old[i], nodes[i])
    if (o.at - d.at).abs() > 0.5 {
      fails.push("frame \{i}: old at \{o.at}, nodes at \{d.at}: the two runs part here")
      break
    }
    still_o = if i > 0 && pa_still(old[i - 1], o) { still_o + 1 } else { 0 }
    still_n = if i > 0 && pa_still(nodes[i - 1], d) { still_n + 1 } else { 0 }
    let at_rest = still_o >= pa_still_frames && still_n >= pa_still_frames
    let next_rest = i + 1 < n && pa_still(old[i], old[i + 1]) && pa_still(nodes[i], nodes[i + 1])
    if at_rest && (!next_rest || i == n - 1) {
      rest_at.push(i)
    }
    for e in pa_diff(o, d, pa_way_tol) {
      match pa_way_row(name, e, o.at) {
        Some(r) => used[r] = used.get(r).unwrap_or(0) + 1
        None => {
          if !seen.contains(e.key) {
            seen[e.key] = []
            order.push(e.key)
          }
          pa_stretch_add(seen[e.key], e, o.at)
        }
      }
    }
  }
  for k in order {
    for st in seen[k] {
      fails.push(
        "WAY \{k} \{st.frames} frames @\{st.from.round()}..\{st.to.round()}ms, most dx \{pa_r(st.dx)} dy \{pa_r(st.dy)} dw \{pa_r(st.dw)}, first: \{st.first}",
      )
    }
  }
  // (each row of pa_way_known of this drive what it let pass, or failing where it let nothing: a row left over)
  for r, row in pa_way_known {
    if row.drive == name {
      match used.get(r) {
        Some(c) => notes.push("WAY known (\{c} frames): \{pa_what_text(row.what)} @\{row.from}..\{row.to}ms ≤ dx \{row.dx} dy \{row.dy} dw \{row.dw}: \{row.why}")
        None => fails.push("WAY known row left over (nothing it lets pass): \{pa_what_text(row.what)} @\{row.from}..\{row.to}ms")
      }
    }
  }
  for i in rest_at {
    // (a stretch at rest on both sides known to differ whole, its cause said: pa_rest_known)
    match pa_rest_known.search_by(fn(k) { k.0 == name && old[i].at >= k.1 - 0.5 && old[i].at <= k.2 + 0.5 }) {
      Some(r) => {
        notes.push("REST @\{old[i].at.round()}ms (known: \{pa_rest_known[r].3})")
        continue
      }
      None => ()
    }
    for e in pa_diff(old[i], nodes[i], pa_rest_tol) {
      if pa_is_known(name, e.key) {
        notes.push("REST @\{old[i].at.round()}ms (known, the new page's mend): \{e.line}")
      } else if pa_rest_off_known.iter().any(fn(k) {
          k.0 == name && k.1 == e.key && e.dx.abs() <= k.2 && e.dy.abs() <= k.3 && e.dw.abs() <= k.4
        }) {
        notes.push("REST @\{old[i].at.round()}ms (known, off within its row): \{e.line}")
      } else {
        fails.push("REST @\{old[i].at.round()}ms: \{e.line}")
      }
    }
  }
  for l in pa_spikes(nodes) {
    fails.push("SPIKE nodes \{l}")
  }
  println("PARITY \{name}: \{n} frames, \{rest_at.length()} at rest, \{fails.length()} failing, \{order.length()} differ on the way unknown")
  for l in fails {
    println("  \{name} FAIL \{l}")
  }
  for l in notes {
    println("  \{name} \{l}")
  }
  if fails.is_empty() {
    None
  } else {
    Some("\{name}: \{fails.length()} failing")
  }
}

///|
/// 大屏 and 小屏 as the films are drawn: width, height, platform.
let pa_desk : (Double, Double, Int) = (1280.0, 800.0, 0)

///|
let pa_phone : (Double, Double, Int) = (390.0, 844.0, 2)

///|
/// Each film's drive: its name, its fixture's mode, its screen, its script (scripts/motion's file of that name).
let pa_drives : Array[(String, String, (Double, Double, Int), String)] = [
  (
    "desk-right-panel-toggle",
    "chat",
    pa_desk,
    (
      #|timeout 20000
      #|until 发消息
      #|wait 600
      #|tap icon:panel-open
      #|wait 1200
      #|tap 发消息
      #|wait 500
      #|type 面板开着也发一条
      #|wait 600
      #|tap icon:arrow-up
      #|wait 2200
      #|tap icon:panel-close
      #|wait 1500
      #|exit
    ),
  ),
  (
    "desk-composer-attachments-toggle",
    "chat",
    pa_desk,
    (
      #|timeout 20000
      #|until 发消息
      #|wait 600
      #|tap 发消息
      #|wait 500
      #|picks 截图.png:160x120
      #|key cmd+u
      #|wait 1200
      #|picks 构建日志.log:2000
      #|key cmd+u
      #|wait 1200
      #|tap icon:close
      #|wait 1200
      #|tap icon:close
      #|wait 1500
      #|exit
    ),
  ),
  (
    "desk-send-picture-and-file",
    "chat",
    pa_desk,
    (
      #|timeout 20000
      #|until 发消息
      #|wait 600
      #|tap 发消息
      #|wait 500
      #|picks 截图.png:160x120
      #|key cmd+u
      #|wait 900
      #|picks 构建日志.log:2000
      #|key cmd+u
      #|wait 900
      #|type 截图和日志都在这里
      #|wait 600
      #|tap icon:arrow-up
      #|wait 2200
      #|exit
    ),
  ),
  (
    "send-quote-wide",
    "chat",
    pa_desk,
    (
      #|timeout 20000
      #|until 发消息
      #|wait 600
      #|dragon 120 0 400 推送截图前要先登录 gh。
      #|wait 400
      #|tap 引用
      #|wait 600
      #|type 这一步写进文档
      #|enter
      #|wait 600
      #|tap icon:arrow-up
      #|wait 1500
      #|exit
    ),
  ),
  (
    "desk-send-text-and-multiline",
    "chat",
    pa_desk,
    (
      #|timeout 20000
      #|until 发消息
      #|wait 600
      #|tap 发消息
      #|wait 500
      #|type 发布前再看一眼签名
      #|wait 700
      #|tap icon:arrow-up
      #|wait 1800
      #|tap 发消息
      #|wait 500
      #|type 先看一下签名
      #|key shift+enter
      #|type 再看发布说明
      #|key shift+enter
      #|type 最后核对版本号
      #|wait 700
      #|tap icon:arrow-up
      #|wait 2200
      #|exit
    ),
  ),
  (
    "desk-notice-card-viewer",
    "chat",
    pa_desk,
    (
      #|timeout 20000
      #|until =一起换
      #|wait 800
      #|tap =一起换
      #|wait 2500
      #|wheel -300
      #|wait 100
      #|wheel -300
      #|wait 100
      #|wheel -300
      #|wait 1600
      #|until img:compare.png
      #|tap img:compare.png
      #|wait 1500
      #|key esc
      #|wait 1500
      #|exit
    ),
  ),
  (
    "send",
    "chat",
    pa_phone,
    (
      #|timeout 20000
      #|until 发消息
      #|wait 600
      #|tap 发消息
      #|wait 500
      #|type 发布前再看一眼签名
      #|wait 700
      #|tap icon:arrow-up
      #|wait 2500
      #|exit
    ),
  ),
  (
    "send-lines",
    "chat",
    pa_phone,
    (
      #|timeout 20000
      #|until 发消息
      #|wait 600
      #|tap 发消息
      #|wait 500
      #|type 先看一下签名
      #|enter
      #|type 再看发布说明
      #|enter
      #|type 最后核对版本号
      #|wait 700
      #|tap icon:arrow-up
      #|wait 1500
      #|exit
    ),
  ),
  (
    "send-picture",
    "chat-attach-pic",
    pa_phone,
    (
      #|timeout 20000
      #|wait 1500
      #|tap icon:arrow-up
      #|wait 1800
      #|exit
    ),
  ),
  (
    "send-quote",
    "chat",
    pa_phone,
    (
      #|timeout 20000
      #|until 推送截图前要先登录 gh。
      #|wait 600
      #|hold 700 推送截图前要先登录 gh。
      #|wait 400
      #|tap 引用
      #|wait 600
      #|type 这一步写进文档
      #|wait 600
      #|tap icon:arrow-up
      #|wait 1500
      #|exit
    ),
  ),
  (
    "decide",
    "chat",
    pa_phone,
    (
      #|timeout 20000
      #|until =一起换
      #|wait 800
      #|tap =一起换
      #|wait 3000
      #|exit
    ),
  ),
  (
    "answer",
    "chat",
    pa_phone,
    (
      #|timeout 20000
      #|until 发消息
      #|wait 600
      #|tap 发消息
      #|wait 500
      #|type 看一下列表的高度
      #|wait 700
      #|tap icon:arrow-up
      #|wait 4500
      #|exit
    ),
  ),
  (
    "wide-newchat",
    "chat",
    pa_desk,
    (
      #|timeout 20000
      #|until 新建对话
      #|wait 600
      #|tap 新建对话
      #|wait 900
      #|until 做任何事
      #|wait 500
      #|type 把发布说明写一下
      #|wait 700
      #|tap icon:arrow-up
      #|wait 3000
      #|exit
    ),
  ),
  (
    "newchat-send",
    "newchat",
    pa_phone,
    (
      #|timeout 20000
      #|wait 1200
      #|tap 做任何事
      #|wait 500
      #|type 把发布说明写一下
      #|wait 700
      #|tap icon:arrow-up
      #|wait 2000
      #|exit
    ),
  ),
  (
    "send-newchat-picture",
    "newchat-attach",
    pa_phone,
    (
      #|timeout 20000
      #|wait 1500
      #|tap icon:arrow-up
      #|wait 2500
      #|exit
    ),
  ),
  (
    "wide-send",
    "chat",
    pa_desk,
    (
      #|timeout 20000
      #|until 发消息
      #|wait 600
      #|tap 发消息
      #|wait 500
      #|type 发布前再看一眼签名
      #|wait 700
      #|tap icon:arrow-up
      #|wait 2500
      #|exit
    ),
  ),
  (
    "send-lines-wide",
    "chat",
    pa_desk,
    (
      #|timeout 20000
      #|until 发消息
      #|wait 600
      #|tap 发消息
      #|wait 500
      #|type 先看一下签名
      #|key shift+enter
      #|type 再看发布说明
      #|key shift+enter
      #|type 最后核对版本号
      #|wait 700
      #|tap icon:arrow-up
      #|wait 1500
      #|exit
    ),
  ),
  (
    "attach-wide",
    "chat",
    pa_desk,
    (
      #|system {"size_class":{"width":"regular","height":"regular"}}
      #|timeout 20000
      #|until 发消息
      #|wait 800
      #|tap icon:plus
      #|wait 1500
      #|exit
    ),
  ),
  (
    "wide-side-panel",
    "chat",
    pa_desk,
    (
      #|timeout 20000
      #|until 发消息
      #|wait 600
      #|tap icon:panel-open
      #|wait 900
      #|tap icon:panel-close
      #|wait 900
      #|tap icon:panel-open
      #|wait 900
      #|tap icon:panel-close
      #|wait 900
      #|exit
    ),
  ),
  (
    "send-long",
    "chat",
    pa_phone,
    (
      #|timeout 20000
      #|until 发消息
      #|wait 600
      #|tap 发消息
      #|wait 500
      #|type 帮我看一下登录按钮在深色模式下的颜色是不是不对，还有注册页输入框的边框也要再核对一遍
      #|wait 700
      #|tap icon:arrow-up
      #|wait 1500
      #|exit
    ),
  ),
  (
    "send-over-line",
    "chat",
    pa_phone,
    (
      #|timeout 20000
      #|until 发消息
      #|wait 600
      #|tap 发消息
      #|wait 400
      #|type 看一下列表的高度
      #|wait 400
      #|tap icon:arrow-up
      #|wait 1100
      #|type 顺便看看深色模式下面的图标是不是也要一起换掉，还有按钮和输入框的颜色也一起对一下
      #|wait 300
      #|tap icon:arrow-up
      #|wait 2500
      #|exit
    ),
  ),
  (
    "send-picture-only",
    "chat-attach",
    pa_phone,
    (
      #|timeout 20000
      #|wait 1500
      #|tapxy 120 -150
      #|wait 400
      #|clear
      #|wait 600
      #|tap icon:arrow-up
      #|wait 1800
      #|exit
    ),
  ),
  (
    "send-quote-picture",
    "home",
    pa_phone,
    (
      #|timeout 20000
      #|until 整理发布清单
      #|wait 600
      #|tap 整理发布清单
      #|wait 1000
      #|wheel -300
      #|wait 100
      #|wheel -300
      #|wait 100
      #|wheel -300
      #|wait 1800
      #|until img:compare.png
      #|hold 1100 img:compare.png
      #|wait 400
      #|tap 引用
      #|wait 900
      #|tap icon:arrow-up
      #|wait 1500
      #|exit
    ),
  ),
  (
    "scrolled-reply",
    "chat",
    pa_phone,
    (
      #|timeout 20000
      #|until 发消息
      #|wait 600
      #|tap 发消息
      #|wait 500
      #|type 看一下列表的高度
      #|wait 700
      #|tap icon:arrow-up
      #|wait 1200
      #|drag 195 300 0 160 400
      #|wait 4500
      #|exit
    ),
  ),
  (
    "scrolled-reply-near",
    "chat",
    pa_phone,
    (
      #|timeout 20000
      #|until 发消息
      #|wait 600
      #|tap 发消息
      #|wait 500
      #|type 看一下列表的高度
      #|wait 700
      #|tap icon:arrow-up
      #|wait 1200
      #|drag 195 300 0 60 400
      #|wait 4500
      #|exit
    ),
  ),
  (
    "answer-leave",
    "chat",
    pa_phone,
    (
      #|timeout 20000
      #|until 发消息
      #|wait 600
      #|tap 发消息
      #|wait 500
      #|type 看一下列表的高度
      #|wait 700
      #|tap icon:arrow-up
      #|wait 9000
      #|exit
    ),
  ),
  (
    "vault-card",
    "chat-vault",
    pa_phone,
    (
      #|timeout 20000
      #|until =不存
      #|wait 800
      #|tap =不存
      #|until 未存入
      #|wait 1200
      #|exit
    ),
  ),
  (
    "vault-decide",
    "chat-vault",
    pa_phone,
    (
      #|timeout 20000
      #|until =不存
      #|wait 800
      #|tap =不存
      #|wait 2000
      #|exit
    ),
  ),
  (
    "vault-file",
    "chat-vault-file",
    pa_phone,
    (
      #|timeout 20000
      #|until 选择文件
      #|wait 800
      #|picks prod-kubeconfig.yaml:5321
      #|tap 选择文件
      #|wait 900
      #|tap =存入
      #|until 已存入
      #|wait 1200
      #|exit
    ),
  ),
  (
    "vault-typed",
    "chat-vault-typed",
    pa_phone,
    (
      #|timeout 20000
      #|until 粘贴 Token
      #|wait 800
      #|tap 粘贴 Token
      #|wait 300
      #|type sk-go-4f1e9a7c
      #|wait 900
      #|tap =存入
      #|until 已存入
      #|wait 1200
      #|exit
    ),
  ),
  (
    "desk-panel-picture-quote",
    "chat",
    pa_desk,
    (
      #|timeout 20000
      #|until 发消息
      #|wait 600
      #|tap icon:panel-open
      #|wait 1200
      #|dragon 120 0 400 推送截图前要先登录 gh。
      #|wait 400
      #|tap 引用
      #|wait 600
      #|tap 发消息
      #|wait 400
      #|picks 截图.png:160x120
      #|key cmd+u
      #|wait 900
      #|tap icon:arrow-up
      #|wait 2200
      #|exit
    ),
  ),
  // (the stills: 900×640, at rest after 1.5 s)
  ("chat-vault-file", "chat-vault-file", (900.0, 640.0, 0), "wait 1500\nexit\n"),
  ("chat-uploading-files", "chat-uploading-files", (900.0, 640.0, 0), "wait 1500\nexit\n"),
  // (track B's: the viewer flying from a message's picture or video and back, its player; a picture lifted for its
  // menu; pictures brought in as decoded; a video quoted and sent: taken in as that track merged, 2026-11-16)
  (
    "viewer",
    "home",
    pa_phone,
    (
      #|timeout 20000
      #|until 整理发布清单
      #|wait 600
      #|tap 整理发布清单
      #|wait 1000
      #|wheel -300
      #|wait 200
      #|wheel -300
      #|wait 200
      #|wheel -300
      #|wait 1800
      #|until img:compare.png
      #|tap img:compare.png
      #|wait 1000
      #|back
      #|wait 1000
      #|exit
    ),
  ),
  (
    "viewer-open",
    "home",
    pa_phone,
    (
      #|timeout 20000
      #|until 整理发布清单
      #|wait 600
      #|tap 整理发布清单
      #|wait 1000
      #|wheel -300
      #|wait 200
      #|wheel -300
      #|wait 200
      #|wheel -300
      #|wait 1800
      #|until img:compare.png
      #|tap img:compare.png
      #|wait 1500
      #|exit
    ),
  ),
  (
    "viewer-video",
    "chat-download",
    pa_phone,
    (
      #|timeout 20000
      #|until 0:13
      #|wait 600
      #|tap 0:13
      #|wait 1500
      #|back
      #|wait 1500
      #|exit
    ),
  ),
  (
    "viewer-video-medium",
    "chat-download",
    (690.0, 840.0, 2),
    (
      #|system {"size_class":{"width":"medium","height":"medium"}}
      #|timeout 20000
      #|until 新建对话
      #|wait 600
      #|tapxy -24 420
      #|wait 900
      #|until 0:13
      #|tap 0:13
      #|wait 1500
      #|back
      #|wait 1500
      #|exit
    ),
  ),
  (
    "picture-lift",
    "home",
    pa_phone,
    (
      #|timeout 20000
      #|until 整理发布清单
      #|wait 600
      #|tap 整理发布清单
      #|wait 1000
      #|wheel -300
      #|wait 200
      #|wheel -300
      #|wait 200
      #|wheel -300
      #|wait 1800
      #|until img:compare.png
      #|hold 1100 img:compare.png
      #|wait 1600
      #|back
      #|wait 1400
      #|exit
    ),
  ),
  (
    "wide-images",
    "chat",
    pa_desk,
    (
      #|timeout 20000
      #|until 发消息
      #|wait 400
      #|wheel -300
      #|wait 200
      #|wheel -300
      #|wait 200
      #|wheel -300
      #|wait 1800
      #|exit
    ),
  ),
  (
    "send-quote-video",
    "chat-download",
    pa_desk,
    (
      #|timeout 20000
      #|until 0:13
      #|wait 600
      #|rightclick 0:13
      #|wait 400
      #|tap 引用
      #|wait 900
      #|tap icon:arrow-up
      #|wait 1500
      #|exit
    ),
  ),
]

///|
/// Runs the drives from `from` to `to` (pa_drives' places): what differs.
fn pa_some(from : Int, to : Int) -> Unit raise {
  // (each frame of its own, 60 a second as the films are: at a rate it has nothing to add, mbui's AGENTS.md (Only
  // run_for's way gets the extra frames: a test that walks its own frames to judge motion returns at once))
  if @ui.test_at_a_rate() {
    return
  }
  let found = []
  for i in from..<to {
    let (name, mode, screen, script) = pa_drives[i]
    let (w, h, platform) = screen
    match pa_compare(name, mode, w, h, platform, script) {
      Some(s) => found.push(s)
      None => ()
    }
  }
  if !found.is_empty() {
    fail("old and nodes differ: \{found.join("; ")}")
  }
}

///|
test "parity desk-right-panel-toggle: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(0, 1)
}

///|
test "parity desk-composer-attachments-toggle: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(1, 2)
}

///|
test "parity desk-send-picture-and-file: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(2, 3)
}

///|
test "parity send-quote-wide: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(3, 4)
}

///|
test "parity desk-send-text-and-multiline: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(4, 5)
}

///|
test "parity desk-notice-card-viewer: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(5, 6)
}

///|
test "parity send: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(6, 7)
}

///|
test "parity send-lines: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(7, 8)
}

///|
test "parity send-picture: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(8, 9)
}

///|
test "parity send-quote: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(9, 10)
}

///|
test "parity decide: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(10, 11)
}

///|
test "parity answer: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(11, 12)
}

///|
test "parity chat-vault-file: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(31, 32)
}

///|
test "parity chat-uploading-files: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(32, 33)
}

///|
test "parity wide-newchat: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(12, 13)
}
///|
test "parity newchat-send: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(13, 14)
}
///|
test "parity send-newchat-picture: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(14, 15)
}
///|
test "parity wide-send: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(15, 16)
}
///|
test "parity send-lines-wide: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(16, 17)
}
///|
test "parity attach-wide: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(17, 18)
}
///|
test "parity wide-side-panel: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(18, 19)
}
///|
test "parity send-long: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(19, 20)
}
///|
test "parity send-over-line: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(20, 21)
}
///|
test "parity send-picture-only: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(21, 22)
}
///|
test "parity send-quote-picture: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(22, 23)
}
///|
test "parity scrolled-reply: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(23, 24)
}
///|
test "parity scrolled-reply-near: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(24, 25)
}
///|
test "parity answer-leave: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(25, 26)
}
///|
test "parity vault-card: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(26, 27)
}
///|
test "parity vault-decide: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(27, 28)
}
///|
test "parity vault-file: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(28, 29)
}
///|
test "parity vault-typed: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(29, 30)
}
///|
test "parity desk-panel-picture-quote: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(30, 31)
}

///|
test "parity viewer: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(33, 34)
}

///|
test "parity viewer-open: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(34, 35)
}

///|
test "parity viewer-video: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(35, 36)
}

///|
test "parity viewer-video-medium: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(36, 37)
}

///|
test "parity picture-lift: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(37, 38)
}

///|
test "parity wide-images: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(38, 39)
}

///|
test "parity send-quote-video: the old page and the page made as nodes, frame by frame and at rest" {
  pa_some(39, 40)
}

///|
/// The drives of scripts/motion taken here (pa_drives': the films' twelve, cards.drive as decide, and the chat page's
/// own of sending, the side panel, a new chat's first words, the answer and the vault's cards), by their files' names.
let pa_taken : Array[String] = [
  "desk-right-panel-toggle", "desk-composer-attachments-toggle", "desk-send-picture-and-file", "send-quote-wide",
  "desk-send-text-and-multiline", "desk-notice-card-viewer", "send", "send-lines", "send-picture", "send-quote", "cards",
  "answer", "wide-newchat", "newchat-send", "send-newchat-picture", "wide-send", "send-lines-wide", "attach-wide",
  "wide-side-panel", "send-long", "send-over-line", "send-picture-only", "send-quote-picture", "scrolled-reply",
  "scrolled-reply-near", "answer-leave", "vault-card", "vault-decide", "vault-file", "vault-typed", "viewer", "viewer-open",
  "viewer-video", "viewer-video-medium", "picture-lift", "wide-images", "send-quote-video",
]

///|
/// Every other drive of scripts/motion, not taken here, each with why (and what it drives, its head's first line).
let pa_not_taken : Array[(String, String)] = [
  ("about", "not the chat's page — 关于 and 更新日志 in a phone's window (sfdesk about.mbt, one page in every frame; the web's mobile/Settings.tsx"),
  ("archive", "not the chat's page — A row archived from its menu (Slack 里问的报销流程, over 把旧的截图都换成新的, a row with its own 归档): it goes, the"),
  ("archiving", "not the chat's page — 归档 then a station's own (sfdesk permissions.mbt, one page each in every frame): MBUI_FIXTURE=settings-archivin"),
  ("attach", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — ＋'s sheet opened, then closed by a tap on its scrim."),
  ("bar-hold", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — The bar's ball held still a moment by a finger: its lens of liquid glass over it, let go, the ball again."),
  ("bar", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — The bottom bar's motions over the made-up chats: 文件 tapped and the chats again (the ball's way, the notch's ic"),
  ("cc", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — A chat linked to Slack and Feishu on a computer (MBUI_FIXTURE=chat-cc MBUI_WIN=1280x800 MBUI_FILM_PLATFORM=0):"),
  ("composer-blur", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — A chat on a computer: its composer clicked (a box), then a click on the messages (let go: a capsule again a mo"),
  ("composer-focus-medium", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — Medium on an opened fold's inner screen (MBUI_WIN=690x840 MBUI_FILM_PLATFORM=2): the chat's page brought over,"),
  ("composer-picture", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — A chat on a computer: a picture picked into its composer with words in it: the box opens for it, the picture g"),
  ("composer-shape", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — A chat on a computer: words in its composer, a line and another started and one taken back: the box's ground g"),
  ("composer-window", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — A chat on a computer, words in its composer, the window made narrower, wider and shorter: the composer goes wi"),
  ("conflict", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — Words sent while the agent's answer to the first comes out of its avatar (emit.mbt): the second words' flight"),
  ("connect-steps", "not the chat's page — A new connect's wizard going a step on and back (sfpages new_connect.mbt nc_follow: the dialog's steps the cor"),
  ("connects-filter", "not the chat's page — The connects' filter (settings/connects.mbt band_filter): its button at the bar's end, then 我的 chosen."),
  ("connects", "not the chat's page — 连接 (sfpages connects.mbt, one page in every frame): MBUI_FIXTURE=settings-connects, a phone's window or a desk"),
  ("decisions-settings", "not the chat's page — 自动决策 in a phone's window (sfpages automatic_decisions.mbt, one page in every frame; the web's"),
  ("download", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — A chat's file downloaded by the core (MBUI_FIXTURE=chat-download, downloads_fixture.mbt): 发布包.zip opened from "),
  ("effort-meter", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — How hard it thinks picked along its meter (MBUI_FIXTURE=newchat-model opens the model's panel): far, near, and"),
  ("files-browse", "not the chat's page — The files' page browsed (DriveViews.tsx, Drive.tsx DriveRow, drive/browse.ts: the core's driveBrowse): MBUI_FI"),
  ("files-drag", "not the chat's page — Files dragged on the files' page (drag.ts, browse.ts effectOf, transfer.ts: the core's drive.moves): MBUI_FIXT"),
  ("files-edge", "not the chat's page — The files' columns' edge (DriveViews.tsx ColumnEdge: the library's edge, @sf.handle_drag, edge_look, edge_tip)"),
  ("files-nav", "not the chat's page — The files' sidebar and going somewhere (FilesNav.tsx, FilesGo.tsx: the core's stations {drive, here} and files"),
  ("files-pin", "not the chat's page — Add a favorite on the files' page: MBUI_FIXTURE=drive MBUI_WIN=1280x800. The sidebar action, the station chose"),
  ("files-tabs", "not the chat's page — The files' page's tabs (Files.tsx FilesShell, drive/tabs.ts: the core's filesTabs and files.tabs): MBUI_FIXTUR"),
  ("hand-feel", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — A finger's controls (mbui's press sink, the switch's and the segmented choice's lens): 关于's switch row held an"),
  ("home-news", "not the chat's page — Home over the made-up chats whose list changes (MBUI_FIXTURE=home-motion): a chat with news goes to the top, a"),
  ("lens", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — The bottom bar's ball held and slid across the places and back (a lens of liquid glass over them while it is h"),
  ("lift", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — A chat's row held by a finger (sfpages chat_row.mbt): it lifts a little as its time shows, all the way as its "),
  ("lists-phone", "not the chat's page — The chats' list on a phone (for the old and new side by side): a row held for its menu, let be; the filter's m"),
  ("lists-wide", "not the chat's page — The chats' list on a desktop's window (old and new side by side): a row pointed at, right clicked for its menu"),
  ("login-fill", "not the chat's page — A tab of a station's browser driven, its focus in github.com's password field (sfpages screen_fill.mbt):"),
  ("loupe", "track B (the viewer, a picture or a video flying to it, the player): taken in as that track is merged — The loupe: words typed in the composer, a long press on them slid along (Android's: the word there picked, wid"),
  ("marks-note-done", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — A mark's note done in the viewer (sfbase viewer_marks_node.mbt): a box drawn on a picture of the made-up chat,"),
  ("me", "not the chat's page — 账号 (sfpages account.mbt, one page in every frame): MBUI_FIXTURE=settings-me, a phone's window or a desktop's."),
  ("memory-tape-swipe-short", "not the chat's page — 一台 station 的记忆 over 记忆 on the tape (MBUI_FIXTURE=settings-memories MBUI_WIN=700x760): Willow's memory opened,"),
  ("memory-tape-swipe", "not the chat's page — 一台 station 的记忆 over 记忆 on the tape (MBUI_FIXTURE=settings-memories MBUI_WIN=700x760): Willow's memory opened,"),
  ("memory", "not the chat's page — 记忆 in a phone's window (sfpages memory.mbt, one page in every frame; the web's mobile/Memory.tsx): MBUI_FIXTUR"),
  ("menu", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — The home's filter menu in and out: its button, then 我参与的 chosen."),
  ("model-close-diagnostic", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — The panel stays visible at the start, then a frequent model is selected."),
  ("need-dismiss", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — What the chat needs, at its end, let go with 忽略 (chat_rows.mbt chat_state): the card goes as answered options "),
  ("network-closed", "not the chat's page — "),
  ("network-open", "not the chat's page — "),
  ("network-select", "not the chat's page — "),
  ("new-workspace", "not the chat's page — A new workspace from the workspaces' list (sfpages workspace.mbt), two accounts signed in: named, its account "),
  ("newchat-held", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — A new chat held while its stations are read (MBUI_FIXTURE=newchat-reading opens it so): what it shows meanwhil"),
  ("newchat-picks", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — A new chat's picks narrow: where it runs, then what it runs on, each through the presenters."),
  ("newchat-slow", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — A new chat opened from 令 while its stations are still being read (MBUI_FIXTURE=stations-slow: read 1.2 s after"),
  ("newchat", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — A new chat from 令 and its first words sent (newchat.mbt, flight.mbt carried): they stay where they were typed "),
  ("notify-workspaces", "not the chat's page — 通知 in a phone's window (sfpages notifications.mbt): MBUI_FIXTURE=settings-notify, scrolled down to its workspa"),
  ("phone-decide", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — An agent's request to debug the person's phone, at the chat's end (MBUI_FIXTURE=chat-phone), answered 允许 there"),
  ("preset-confirm", "not the chat's page — A confirm over the preset's dialog (sf presenters.mbt scrim_owner, recede_look): 删除 asks 删除预设？ over it, then"),
  ("preset-delete", "not the chat's page — A preset deleted from its dialog (sf presenters.mbt scrim_owner, pushed_look): 删除 asks 删除预设？ over it, and its"),
  ("preset-steps-wide", "not the chat's page — A new preset's dialog going in steps in the middle of a wide window (sf presenters.mbt panel_go): 添加目录, then"),
  ("preset-steps", "not the chat's page — A new preset's dialog going in steps (sf presenters.mbt panel_go): 添加目录, then 浏览文件夹, then back twice by the"),
  ("press", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — A row pressed a moment and let go (a tap held short of a long press): lit once the press is not the list's (10"),
  ("prices", "not the chat's page — 价目表 (sfpages usage.mbt, one page in every frame): MBUI_FIXTURE=settings-prices, a phone's window or a desktop'"),
  ("search-close", "not the chat's page — The search over Home opened and closed, nothing typed (the Android app's SearchMotionTest: search-open, then"),
  ("search-key-phone", "not the chat's page — The search on a phone: words typed, then the keyboard's search key (Enter): nothing opens, the field keeps its"),
  ("search-medium", "not the chat's page — The search in a Medium window's sidebar (MBUI_FIXTURE=home MBUI_FILM_PLATFORM=2 MBUI_WIN=800x880 MBUI_LOCALE=e"),
  ("search-phone", "not the chat's page — The search on a phone (old and new side by side): the field at the list's top, words typed, what they find."),
  ("search-small-desk", "not the chat's page — ⌘K in a phone-wide desktop window (Small), over a chat: the search's page, words typed, the keys choosing down"),
  ("search-wide", "not the chat's page — ⌘K on a desktop's window (old and new side by side): opened, words typed, the keys choosing down."),
  ("search", "not the chat's page — The search over Home (search.mbt; the Android app's SearchMotionTest): the list pulled down to its field, the "),
  ("security-open", "not the chat's page — 开启安全模式 (sfpages security.mbt, a page of its own in every frame): MBUI_FIXTURE=settings-security-open, a phone'"),
  ("security", "not the chat's page — 安全 (sfpages security.mbt, one page in every frame): MBUI_FIXTURE=settings-security, a phone's window or a desk"),
  ("seg-lens", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — 用量's days held by a finger (the segmented choice's thumb a lens of liquid glass over the options while held, o"),
  ("settings-motion", "not the chat's page — A settings page over the made-up workspace changing on its own (MBUI_FIXTURE=settings-workspace-motion,"),
  ("settings-still", "not the chat's page — A settings page as it opens (old and new side by side)."),
  ("sheet-stretch", "not the chat's page — A sheet drawn up past its top (mbui's kit sheet: it gives way, the further the more, and springs back as it is"),
  ("sheet", "not the chat's page — A settings sheet up and down on the sheet's spring, its scrim in and out: Station → Willow → '…' → 重命名, then"),
  ("sidebar-edge", "not the chat's page — The sidebar's edge (Rail.tsx SidebarEdge: the library's edge, @sf.handle_drag, edge_look, edge_tip):"),
  ("sidebar-fold", "not the chat's page — The wide frame's sidebar folded to the rail's bar and opened again, shown a while as the pointer comes on the "),
  ("sidebar-pin", "not the chat's page — The wide frame's sidebar switched between shown a while and pinned open with a chat open (Rail.tsx's rail"),
  ("sidebar", "not the chat's page — The wide frame's sidebar as the web's, for people to look at (a desktop's window): open; folded to the rail's "),
  ("station", "not the chat's page — A station's page (sfpages station_page.mbt, one page in every frame): MBUI_FIXTURE=settings-station, a phone's"),
  ("still", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — The page as it opens, held a moment (a fixture's state pictured as it is)."),
  ("switch-new-chat", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — A chat and a new chat switched by the sidebar on a computer (MBUI_WIN=1280x800): the composer goes between the"),
  ("switch-only", "not the chat's page — 关于's switch row (MBUI_FIXTURE=settings-about): its words held (nothing answers: the switch alone takes a press"),
  ("switch", "not the chat's page — A settings switch turned off and on again (the vault editor's 允许 agent 申请: its own, no core asked): the knob"),
  ("tape-back", "not the chat's page — Laid out Medium on an opened fold's inner screen upright (MBUI_WIN=690x840 MBUI_FILM_PLATFORM=2), a finger: th"),
  ("tape-composer", "not the chat's page — Laid out Medium on an opened fold's inner screen (MBUI_WIN=690x840 MBUI_FILM_PLATFORM=2): the page brought ove"),
  ("tape-corner", "not the chat's page — Laid out Medium on an opened fold's inner screen (MBUI_WIN=690x840 MBUI_FILM_PLATFORM=2): the page brought ove"),
  ("tape-edge", "not the chat's page — Laid out Medium on an opened fold's inner screen upright (MBUI_WIN=690x840 MBUI_FILM_PLATFORM=2), a finger: th"),
  ("tape-files", "not the chat's page — Laid out Medium on an opened fold's inner screen (MBUI_WIN=690x840 MBUI_FILM_PLATFORM=2): 文件 from the rail, th"),
  ("tape-images", "not the chat's page — Laid out Medium on an opened fold's inner screen (MBUI_WIN=690x840 MBUI_FILM_PLATFORM=2), the made-up chat bro"),
  ("tape-panel", "not the chat's page — Laid out Medium, a chat's side panel a panel of its own on the tape (sfdesk frame.mbt): MBUI_WIN=690x840"),
  ("tape-phone", "not the chat's page — Laid out Medium on a phone on its side (sfdesk frame.mbt's tape): MBUI_WIN=844x390 MBUI_FILM_PLATFORM=2, its s"),
  ("tape-stack", "not the chat's page — Laid out Medium on an opened fold's inner screen upright (MBUI_WIN=690x840 MBUI_FILM_PLATFORM=2), a finger: th"),
  ("tape-states", "not the chat's page — Laid out Medium on an opened fold's inner screen upright (MBUI_WIN=690x840 MBUI_FILM_PLATFORM=2), a finger: th"),
  ("tape-switch", "not the chat's page — A chat and a new chat switched on the tape (laid out Medium: MBUI_WIN=600x760 a Mac's): the chat opened by its"),
  ("tape", "not the chat's page — Laid out Medium, the wide frame's tape (sfdesk frame.mbt): MBUI_WIN=690x840 MBUI_FILM_PLATFORM=2, an opened fo"),
  ("theme-reveal", "not the chat's page — 外观's theme picked (MBUI_FIXTURE=settings-appearance): the new theme spreading from where it was picked over th"),
  ("things-info-hover", "not the chat's page — A chat's info's pull request pointed at: its card (MBUI_FIXTURE=chat MBUI_WIN=1280x800)."),
  ("things-info-menu", "not the chat's page — A chat's info's pull request right clicked: its menu (MBUI_FIXTURE=chat MBUI_WIN=1280x800)."),
  ("things-info-sheet", "not the chat's page — A chat's info sheet with its pull requests on a phone's window (MBUI_FIXTURE=chat-info: it opens at once)."),
  ("things-info", "not the chat's page — A chat's info with its pull requests (sfdesk chat_page.mbt chat_info, sfpages things.mbt): MBUI_FIXTURE=chat"),
  ("things-links", "not the chat's page — As things.drive, then its links."),
  ("things-pulls", "not the chat's page — As things.drive, then its pulls."),
  ("things-side-files", "not the chat's page — As things-side.drive, then its files."),
  ("things-side-hover", "not the chat's page — As things-side.drive: a row pointed at, then a tile, then a pull request right clicked (its menu)."),
  ("things-side-menu", "not the chat's page — As things-side.drive: a pull request right clicked, its menu (在对话中查看, 复制链接)."),
  ("things-side-pulls", "not the chat's page — As things-side.drive, then its pulls."),
  ("things-side-tile", "not the chat's page — As things-side.drive: a tile pointed at (a shade fainter)."),
  ("things-side", "not the chat's page — What was said in a chat besides words in its tab beside it (sfpages things.mbt): MBUI_FIXTURE=chat-things-side"),
  ("things", "not the chat's page — What was said in a chat besides words (sfpages things.mbt), opened from the chat's info: MBUI_FIXTURE=chat-inf"),
  ("touch-wide-hover", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — A tablet's wide frame, a finger: an agent's picture tapped (its card), then the bar's icon at the top right he"),
  ("touch-wide", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — A tablet's wide frame (an opened fold's inner screen: the system's size classes regular both ways), pointed at"),
  ("update-flow", "not the chat's page — 关于 as an update goes, in a phone's window (sfpages about.mbt, sfbase updates.mbt): MBUI_FIXTURE=settings-about"),
  ("usage-scrub", "not the chat's page — 用量's days slid across by a finger (sfpages usage.mbt usage_chart): MBUI_FIXTURE=settings-usage, a phone's wind"),
  ("usage", "not the chat's page — 用量 (sfpages usage.mbt, one page in every frame): MBUI_FIXTURE=settings-usage, a phone's window or a desktop's."),
  ("vault", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — 密钥 (sfpages vault.mbt, one page in every frame): MBUI_FIXTURE=settings-vault, a phone's window or a desktop's;"),
  ("wide-about", "not the chat's page — 关于 and 更新日志 on the desktop (sfdesk about.mbt; the web's pages/About.tsx, Changelog.tsx): MBUI_WIN=1280x800 ove"),
  ("wide-add-profile", "not the chat's page — Adding a profile on the desktop (sfdesk add_profile.mbt, the web's pages/AddProfile.tsx): MBUI_WIN=1280x800 ov"),
  ("wide-appearance", "not the chat's page — 外观 on the desktop (sfdesk appearance.mbt, font_setting.mbt; the web's pages/Appearance.tsx, FontSetting.tsx):"),
  ("wide-card", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — The wide frame: the made-up chat's card answered (decide.mbt): the options go, the answer comes in."),
  ("wide-connect", "not the chat's page — A connect's page on the desktop (sfpages connect.mbt, the web's pages/Connect.tsx): MBUI_WIN=1280x800 over the"),
  ("wide-decisions", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — 自动决策 on the desktop (sfpages automatic_decisions.mbt; the web's AutomaticDecisions.tsx): MBUI_WIN=1280x800 ove"),
  ("wide-download", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — The wide frame's: 发布包.zip opened from its card (MBUI_FIXTURE=chat-download; its stem and extension two words"),
  ("wide-gate", "not the chat's page — The wide frame of a device waiting to be confirmed in the workspace's lock (sfpages/security.mbt security_wait"),
  ("wide-hand", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — A control answering the hand on a computer (sf/motion.mbt, kind 7): MBUI_WIN=1280x800 over the made-up chat. ⌘"),
  ("wide-hover", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — The wide frame: the pointer resting on an agent's picture beside its message, then on its mark in the chat's b"),
  ("wide-jobs", "not the chat's page — The wide frame's 待处理 (the bell at the rail's top) with a service left up long (sfdesk/open_jobs.mbt, OpenJobs."),
  ("wide-memory-doc", "not the chat's page — A memory page on the desktop (sfpages memory_doc.mbt, the web's Memory.tsx MemoryDoc): MBUI_WIN=1280x800 over "),
  ("wide-memory", "not the chat's page — 记忆 on the desktop (sfpages memory.mbt; the web's Memory.tsx MemoryView): MBUI_WIN=1280x800 over the made-up ch"),
  ("wide-menus", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — The wide frame's right click, as the desktop app's (sfdesk/context_menu.mbt): a link's menu, an image's, the c"),
  ("wide-new-connect", "not the chat's page — A new connect on the desktop (sfpages new_connect.mbt, the web's pages/Connect.tsx NewConnectDialog): MBUI_WIN"),
  ("wide-new-workspace", "not the chat's page — A new workspace from the rail's ＋ (sfpages workspace.mbt), two accounts signed in: named, its account picked"),
  ("wide-newchat-model", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — The wide frame's new chat: where it runs, then what it runs on, each through the presenters (beside their cont"),
  ("wide-newws", "not the chat's page — The rail's ＋ over the workspaces, 新建 workspace chosen (sfdesk/new_workspace.mbt, workspace.tsx NewWorkspaceDia"),
  ("wide-permissions", "not the chat's page — 权限 and 关于 on the desktop (sfdesk permissions.mbt, about.mbt; the web's Permissions.tsx, About.tsx): MBUI_WIN=1"),
  ("wide-places", "not the chat's page — The rail's places on the desktop (sfdesk places.mbt, the web's cloud/workspace.tsx): MBUI_WIN=1280x800 over th"),
  ("wide-pop", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — What comes by its trigger on a computer (sf/motion.mbt, kind 2): a chat's row right-clicked, its menu growing "),
  ("wide-profile", "not the chat's page — A profile's page on the desktop (sfpages accounts.mbt, the web's Accounts.tsx): MBUI_WIN=1280x800 over the mad"),
  ("wide-publish", "not the chat's page — The chat's info open over the wide frame, 分享图片 pressed (sfdesk/publish.mbt, Publish.tsx PublishDialog)."),
  ("wide-relay", "not the chat's page — The wide frame's 接力到频道 from a chat's row (sfdesk/relay.mbt, Relay.tsx): the dialog's places, one picked."),
  ("wide-settings", "not the chat's page — 设置 on the desktop (sfdesk settings_frame.mbt, the web's cloud/settings.tsx): MBUI_WIN=1280x800 over the made-u"),
  ("wide-share", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — The chat's info open over the wide frame, 分享给其他 workspace pressed (sfdesk/share_dialog.mbt, ChatPage.tsx Share"),
  ("wide-slack-app", "not the chat's page — A Slack connect's app on its page on the desktop (sfpages slack_app.mbt, the web's pages/SlackApp.tsx): MBUI_W"),
  ("wide-station", "not the chat's page — A station's page on the desktop (sfpages station_page.mbt, the web's cloud/StationPage.tsx): MBUI_WIN=1280x800"),
  ("wide-switch", "not the chat's page — The wide frame: from the made-up chat to a new chat by the sidebar's 新建对话, and back by the chat's row"),
  ("wide-switcher", "not the chat's page — ⌘K (Switcher.tsx ChatSwitcher, sfdesk/switcher.mbt): MBUI_WIN=1280x800 over the made-up chat. Opened with noth"),
  ("wide-usage", "not the chat's page — 用量 on the desktop (sfpages usage.mbt, the web's Usage.tsx): MBUI_WIN=1280x800 over the made-up chat. 用量 from t"),
  ("wide-vault-item", "the chat page's own controls (a menu, a pick, a presenter, the bar, the composer at rest, a new chat's scene), no list nor flight compared here: their own tests hold them — A secret's page on the desktop (sfpages vault_item.mbt, the web's cloud/VaultItem.tsx): MBUI_WIN=1280x800 over"),
  ("workspace", "not the chat's page — The workspace's page (sfpages workspace_page.mbt, one page in every frame): MBUI_FIXTURE=settings-workspace, a"),
]

///|
/// How many drives scripts/motion has: a drive added there is taken here or said not to be, never left out unsaid.
let pa_motion_drives : Int = 182

///|
test "parity: every drive of scripts/motion taken or said not to be, once" {
  let all : Array[String] = []
  for n in pa_taken {
    assert_true(!all.contains(n), msg="\{n} twice")
    all.push(n)
  }
  for e in pa_not_taken {
    assert_true(!all.contains(e.0), msg="\{e.0} taken and not taken, or not taken twice")
    all.push(e.0)
  }
  assert_eq(all.length(), pa_motion_drives)
}
