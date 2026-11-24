// Picking and marking a PDF where it is shown. The host draws each page as a picture; what the page says and where comes
// from reading the file (@pdftext), so words are picked over the picture: dragged with a mouse, held and slid with a
// finger (a finger that just moves scrolls). A drag that starts off the words frames an area instead, for a figure or a
// scanned page. What is picked is copied, quoted into the chat's draft, or kept as a note on the page. A note is a quote
// in the chat's draft from the moment it is made (role `pdf`, with `mark`: this file and where on its pages), and the
// draft is all there is of it: the pages mark the draft's quotes of this file and list them, what is said of one is its
// comment there, one taken off the draft (or sent) is gone from the pages too. The core keeps the draft on the device,
// so the notes are there again when the file is opened again, or the app is.

///|
/// What is picked: words from a page's glyph to another's (not that glyph), or an area of one page, as fractions of it.
#derive(Eq, Debug)
pub(all) enum PdfPicked {
  Words(Int, Int, Int, Int)
  Area(Int, Double, Double, Double, Double)
}

///|
/// A note on the page: a quote of the chat's draft (`id`, the draft's) of what it marks, its words and what is said of it.
#derive(Eq)
pub(all) struct PdfMark {
  id : String
  what : PdfPicked
  text : String
  comment : String
}

///|
/// What is picked and marked in one viewer's PDF.
pub(all) struct PdfMarks {
  /// the file read for its words, once a press first asks (None: it cannot be, areas alone then)
  mut doc : @pdftext.Doc?
  mut read : Bool
  picked : @signals.Signal[PdfPicked?]
  /// the pointer has let what is picked go: what can be done with it shows
  settled : @signals.Signal[Bool]
  /// the note being written (its quote's id; "" none)
  writing : @signals.Signal[String]
  note : @ui.Field
  /// what reaches the chat's draft the notes are in: the stage's, said as it is made
  mut src : Source?
  /// where the words being picked began: a page and a glyph
  mut words_from : (Int, Int)?
  /// where the area being framed began: a page and a point of it
  mut area_from : (Int, Double, Double)?
  /// a finger's hold picked the word it began on
  mut held : Bool
  /// brings page `page` into sight, `v` (a fraction of it) down it near the stage's top: the stage's, said as it is made
  mut locate : (Int, Double) -> Unit
}

///|
fn PdfMarks::new() -> PdfMarks {
  {
    doc: None,
    read: false,
    picked: @signals.signal(None),
    settled: @signals.signal(false),
    writing: @signals.signal(""),
    note: @ui.Field::new(),
    src: None,
    words_from: None,
    area_from: None,
    held: false,
    locate: fn(_, _) {  },
  }
}

///|
/// How many notes a message can carry: as many quotes as the station takes.
let pdf_marks_most : Int = 20

///|
/// How near a line a press may be and still pick its words, as a share of the page.
let pdf_words_reach : Double = 0.012

///|
/// How small an area is no area, as a share of the page each way.
let pdf_area_least : Double = 0.012

///|
/// How near the stage's top or foot a drag scrolls it, and how fast at the edge (points a ms).
let pdf_edge_room : Double = 48.0

///|
let pdf_edge_speed : Double = 0.9

///|
/// The file read for its words, as a press first asks; none where it cannot be, or its pages are not the ones the host
/// draws (the words would lie on the wrong page).
fn Viewer::pdf_doc(self : Viewer) -> @pdftext.Doc? {
  let m = self.pdf_marks
  if !m.read {
    m.read = true
    match (self.bytes.untracked(), self.pdf) {
      (Some(b), Some(p)) =>
        match @pdftext.Doc::open(b) {
          Some(d) if d.pages() == p.pages => m.doc = Some(d)
          _ => ()
        }
      _ => ()
    }
  }
  m.doc
}

///|
/// The boundary between glyphs nearest (`u`, `v`) of page `p`.
pub fn pdf_end(p : @pdftext.PageText, u : Double, v : Double) -> Int {
  match p.nearest(u, v) {
    Some(k) => {
      let g = p.glyphs[k]
      if u > (g.x0 + g.x1) / 2.0 {
        k + 1
      } else {
        k
      }
    }
    None => 0
  }
}

///|
/// Words between two boundaries, in the order they are read; None where they are the same.
pub fn pdf_span(pa : Int, a : Int, pb : Int, b : Int) -> PdfPicked? {
  if pa == pb && a == b {
    None
  } else if pa < pb || (pa == pb && a < b) {
    Some(Words(pa, a, pb, b))
  } else {
    Some(Words(pb, b, pa, a))
  }
}

///|
/// What `what` says, page after page.
pub fn pdf_words_of(doc : @pdftext.Doc?, what : PdfPicked) -> String {
  guard doc is Some(d) else { return "" }
  match what {
    Words(pa, a, pb, b) => {
      let parts : Array[String] = []
      for j in pa..=pb {
        let p = d.page(j)
        let from = if j == pa { a } else { 0 }
        let to = if j == pb { b } else { p.glyphs.length() }
        let s = p.words(from, to)
        if s != "" {
          parts.push(s)
        }
      }
      parts.join("\n")
    }
    Area(j, x0, y0, x1, y1) => {
      let p = d.page(j)
      let inside : Array[Int] = []
      for k, g in p.glyphs {
        let cx = (g.x0 + g.x1) / 2.0
        let cy = (g.y0 + g.y1) / 2.0
        if cx >= x0 && cx <= x1 && cy >= y0 && cy <= y1 {
          inside.push(k)
        }
      }
      // (runs of glyphs next to each other in reading order, each said as the page says it)
      let parts : Array[String] = []
      let mut k = 0
      while k < inside.length() {
        let from = inside[k]
        let mut to = from + 1
        k += 1
        while k < inside.length() && inside[k] == to {
          to += 1
          k += 1
        }
        let s = p.words(from, to)
        if s != "" {
          parts.push(s)
        }
      }
      parts.join("\n")
    }
  }
}

///|
/// The boxes `what` lies in on page `i`, as fractions of it.
pub fn pdf_rects_of(doc : @pdftext.Doc?, what : PdfPicked, i : Int) -> Array[(Double, Double, Double, Double)] {
  match what {
    Area(j, x0, y0, x1, y1) => if j == i { [(x0, y0, x1, y1)] } else { [] }
    Words(pa, a, pb, b) => {
      guard doc is Some(d) && i >= pa && i <= pb else { return [] }
      let p = d.page(i)
      p.rects(if i == pa { a } else { 0 }, if i == pb { b } else { p.glyphs.length() })
    }
  }
}

///|
/// The page `what` ends on.
fn pdf_last_page(what : PdfPicked) -> Int {
  match what {
    Words(_, _, pb, _) => pb
    Area(j, _, _, _, _) => j
  }
}

///|
/// A quote of `what`: whose (the file and the page), what it says, what was said of it.
pub fn pdf_quote(name : String, what : PdfPicked, words : String, comment : String) -> (String, String, String) {
  let pct = fn(v : Double) { "\{(v * 100.0).round().to_int()}" }
  match what {
    Words(pa, _, pb, _) => {
      let whose = if pa == pb {
        pv_fill("android-chat.pdf.quote.page", [("name", name), ("page", "\{pa + 1}")])
      } else {
        pv_fill("android-chat.pdf.quote.pages", [("name", name), ("from", "\{pa + 1}"), ("to", "\{pb + 1}")])
      }
      (whose, words, comment)
    }
    Area(j, x0, y0, x1, y1) => {
      let where_ = pv_fill("android-chat.pdf.quote.area", [
        ("x", pct(x0)),
        ("y", pct(y0)),
        ("w", pct(x1 - x0)),
        ("h", pct(y1 - y0)),
      ])
      (
        pv_fill("android-chat.pdf.quote.page", [("name", name), ("page", "\{j + 1}")]),
        if words == "" { where_ } else { where_ + "\n" + words },
        comment,
      )
    }
  }
}

///|
/// What is picked let go of.
fn PdfMarks::let_go(self : PdfMarks) -> Unit {
  self.picked.set(None)
  self.settled.set(false)
  self.words_from = None
  self.area_from = None
  self.held = false
}

///|
/// Quotes put into the chat's draft, each as said of a PDF; a viewer over the whole window closes back to the chat.
fn Viewer::pdf_give(self : Viewer, quotes : Array[(String, String, String)]) -> Unit {
  let key = self.draft_key()
  guard key != "" && !quotes.is_empty() else { return }
  draft_give(key, Marked(self.file.name, b"", quotes, "pdf"))
  if !self.beside {
    self.shut_tree()
  }
}

///|
/// What is picked quoted into the draft at once.
fn Viewer::pdf_quote_picked(self : Viewer) -> Unit {
  let m = self.pdf_marks
  guard m.picked.untracked() is Some(what) else { return }
  let q = pdf_quote(self.file.name, what, pdf_words_of(m.doc, what), "")
  m.let_go()
  self.pdf_give([q])
}

///|
/// Where `what` is, as a note's quote keeps it (`mark`): `w:` and the words' two ends, or `a:` and the area's page and
/// corners (in hundred-thousandths of the page).
pub fn pdf_mark_of(what : PdfPicked) -> String {
  let at = fn(v : Double) { (v * pdf_mark_units).round().to_int() }
  match what {
    Words(pa, a, pb, b) => "w:\{pa},\{a},\{pb},\{b}"
    Area(j, x0, y0, x1, y1) => "a:\{j},\{at(x0)},\{at(y0)},\{at(x1)},\{at(y1)}"
  }
}

///|
let pdf_mark_units : Double = 100000.0

///|
/// The whole numbers `s` says apart by commas from code unit `from` on (up to `until`, -1 its end); none where any is
/// not one (empty, a sign, too long).
fn pdf_mark_ints(s : String, from : Int, until? : Int = -1) -> Array[Int]? {
  let out : Array[Int] = []
  let mut n = 0
  let mut digits = 0
  for i in from..<(if until < 0 { s.length() } else { until }) {
    let c = s.unsafe_get(i).to_int()
    if c == 44 {
      guard digits > 0 else { return None }
      out.push(n)
      n = 0
      digits = 0
    } else if c >= 48 && c <= 57 && digits < 9 {
      n = n * 10 + (c - 48)
      digits += 1
    } else {
      return None
    }
  }
  guard digits > 0 else { return None }
  out.push(n)
  Some(out)
}

///|
/// What a note's `mark` (from code unit `from`) says it marks (pdf_mark_of); none where it says nothing that can be
/// (another's, or damaged).
pub fn pdf_what_of(mark : String, from? : Int = 0) -> PdfPicked? {
  guard mark.length() > from + 2 else { return None }
  let kind = mark.unsafe_get(from).to_int()
  guard mark.unsafe_get(from + 1).to_int() == 58 && pdf_mark_ints(mark, from + 2) is Some(n) else { return None }
  let share = fn(v : Int) { v.to_double() / pdf_mark_units }
  if kind == 119 && n.length() == 4 {
    Some(Words(n[0], n[1], n[2], n[3]))
  } else if kind == 97 && n.length() == 5 && n[1:].iter().all(fn(v) { v.to_double() <= pdf_mark_units }) {
    Some(Area(n[0], share(n[1]), share(n[2]), share(n[3]), share(n[4])))
  } else {
    None
  }
}

///|
/// Who this viewer's file is among the draft's notes: what starts each of its notes' `mark`.
fn Viewer::pdf_mark_whose(self : Viewer) -> String {
  "pdf:\{self.file.path}|\{self.file.name}|\{self.file.size}\n"
}

///|
/// The chat's draft the notes are in; none where the viewer is of no chat, or before its stage is made.
fn Viewer::pdf_draft(self : Viewer) -> (Source, Writing)? {
  let key = self.draft_key()
  match self.pdf_marks.src {
    Some(src) if key != "" => Some((src, writing(src, key)))
    _ => None
  }
}

///|
/// This file's notes, as the chat's draft has them now (followed as it changes): its quotes whose `mark` is of this
/// file and says where; at most pdf_marks_most.
pub fn Viewer::pdf_notes(self : Viewer) -> Array[PdfMark] {
  guard self.pdf_draft() is Some((_, w)) else { return [] }
  let whose = self.pdf_mark_whose()
  let out : Array[PdfMark] = []
  for q in w.quotes.get() {
    let mark = text(Some(q), "mark")
    guard text(Some(q), "role") == "pdf" && mark.has_prefix(whose) && out.length() < pdf_marks_most else { continue }
    match pdf_what_of(mark, from=whose.length()) {
      Some(what) => out.push({ id: text(Some(q), "id"), what, text: text(Some(q), "text"), comment: text(Some(q), "comment") })
      None => ()
    }
  }
  out
}

///|
/// What is picked kept as a note on the page: a quote in the chat's draft at once, its words to be written.
fn Viewer::pdf_mark_picked(self : Viewer) -> Unit {
  let m = self.pdf_marks
  guard m.picked.untracked() is Some(what) &&
    self.pdf_draft() is Some((src, w)) &&
    @signals.untracked(fn() { self.pdf_notes() }).length() < pdf_marks_most else {
    return
  }
  self.pdf_note_done()
  let words = pdf_words_of(m.doc, what)
  let (whose, said, _) = pdf_quote(self.file.name, what, words, "")
  let mark = self.pdf_mark_whose() + pdf_mark_of(what)
  writing_quote(src, w, {
    "author": Json::string(whose),
    "text": Json::string(said),
    "comment": Json::string(""),
    "role": Json::string("pdf"),
    "mark": Json::string(mark),
  })
  // (its comment line asks the composer for the focus; here the note's own field has it)
  writing_focused(src, w)
  let id = match @signals.untracked(fn() { w.quotes.get() }).iter().filter(fn(q) { text(Some(q), "mark") == mark }).last() {
    Some(q) => text(Some(q), "id")
    None => ""
  }
  m.let_go()
  m.note.set("")
  m.writing.set(id)
  m.note.focus()
}

///|
/// The note being written, done: what it says its quote's comment in the draft.
fn Viewer::pdf_note_done(self : Viewer) -> Unit {
  let m = self.pdf_marks
  let id = m.writing.untracked()
  guard id != "" else { return }
  let said = m.note.take().trim(chars=" \n\t").to_owned()
  match self.pdf_draft() {
    Some((src, w)) if @signals.untracked(fn() { self.pdf_notes() }).iter().any(fn(x) { x.id == id && x.comment != said }) =>
      writing_comment(src, w, id, said)
    _ => ()
  }
  m.writing.set("")
  m.note.let_go()
}

///|
/// Note `id` taken off the page: its quote out of the draft (the one being written closed with it).
fn Viewer::pdf_note_drop(self : Viewer, id : String) -> Unit {
  let m = self.pdf_marks
  if m.writing.untracked() == id {
    m.note.set("")
    m.writing.set("")
    m.note.let_go()
  }
  match self.pdf_draft() {
    Some((src, w)) => writing_unquote(src, w, id)
    None => ()
  }
}

///|
/// Every note of this file off the page and out of the draft.
fn Viewer::pdf_marks_cleared(self : Viewer) -> Unit {
  for x in @signals.untracked(fn() { self.pdf_notes() }) {
    self.pdf_note_drop(x.id)
  }
}

///|
/// The notes are in the draft already: what is being written kept, and back to the chat to send them with what is
/// written there (a viewer over the whole window closed; one beside the chat, its composer there).
fn Viewer::pdf_marks_sent(self : Viewer) -> Unit {
  self.pdf_note_done()
  match self.pdf_draft() {
    Some((_, w)) => w.field.focus()
    None => ()
  }
  if !self.beside {
    self.shut_tree()
  }
}

///|
/// A key on the PDF's stage: copy copies what is picked, Escape lets it go or finishes the note being written. Whether
/// it did anything.
fn Viewer::pdf_key(self : Viewer, code : Int, mods : Int) -> Bool {
  let m = self.pdf_marks
  if code == @ui.key_code_copy {
    guard m.picked.untracked() is Some(what) else { return false }
    let words = pdf_words_of(m.doc, what)
    guard words != "" else { return false }
    copy_out(words, said=pv("android-chat.annotate.copied"))
    return true
  }
  if code == @ui.key_escape && mods == 0 {
    if m.writing.untracked() != "" {
      self.pdf_note_done()
      return true
    }
    if m.picked.untracked() is Some(_) {
      m.let_go()
      return true
    }
  }
  false
}

///|
/// Note `id` opened: brought into sight on its page and opened to be written, what was said of it in the field.
fn Viewer::pdf_note_open(self : Viewer, id : String) -> Unit {
  let m = self.pdf_marks
  guard @signals.untracked(fn() { self.pdf_notes() }).iter().find_first(fn(x) { x.id == id }) is Some(x) else { return }
  self.pdf_note_done()
  m.let_go()
  let (page, v) = match x.what {
    Words(pa, _, _, _) =>
      match pdf_rects_of(m.doc, x.what, pa).get(0) {
        Some((_, y0, _, _)) => (pa, y0)
        None => (pa, 0.0)
      }
    Area(j, _, y0, _, _) => (j, y0)
  }
  (m.locate)(page, v)
  m.note.set(x.comment)
  m.writing.set(id)
  m.note.focus()
}

///|
/// Where `what` is, as a list of notes says it: its page, or its pages.
fn pdf_place_label(what : PdfPicked) -> String {
  match what {
    Words(pa, _, pb, _) if pa != pb =>
      pv_fill("android-chat.pdf.note.pages", [("from", "\{pa + 1}"), ("to", "\{pb + 1}")])
    Words(pa, _, _, _) => pv_fill("android-chat.pdf.note.page", [("page", "\{pa + 1}")])
    Area(j, _, _, _, _) => pv_fill("android-chat.pdf.note.page", [("page", "\{j + 1}")])
  }
}

///|
/// What a note is of, as a list says it: its words, or that it is an area (and the words in it).
fn pdf_excerpt(x : PdfMark) -> String {
  match x.what {
    Area(_, _, _, _, _) =>
      if x.text == "" {
        pv("android-chat.pdf.note.area")
      } else {
        pv("android-chat.pdf.note.area") + " · " + x.text
      }
    _ => x.text
  }
}

///|
/// This PDF's notes as the viewer lists them (doc_notes_node.mbt).
fn Viewer::pdf_doc_notes(self : Viewer) -> DocNotes {
  let m = self.pdf_marks
  {
    notes: fn() {
      self.pdf_notes().map(fn(x) { { id: x.id, place: pdf_place_label(x.what), excerpt: pdf_excerpt(x), comment: x.comment } })
    },
    current: fn() { m.writing.get() },
    field: m.note,
    done: fn() { self.pdf_note_done() },
    open: fn(id) { self.pdf_note_open(id) },
    remove: fn(id) { self.pdf_note_drop(id) },
    send: fn() { self.pdf_marks_sent() },
    clear: fn() { self.pdf_marks_cleared() },
  }
}

///|
/// Boxes in `b` over a page `page_w()` wide and `tall()` high, each at `rects()`'s place, in `color`.
fn pdf_rects_node(
  b : @view.View,
  rects : () -> Array[(Double, Double, Double, Double)],
  color : () -> Int64,
  page_w : () -> Double,
  tall : () -> Double,
) -> Unit {
  b.over(Is(true)).presses(Is(false)) |> ignore
  // (one box a rect, by its place in the list: a drag moves the boxes it has, never makes them all again)
  b.each(
    fn() { rects().mapi(fn(k, r) { (k, r) }) },
    fn(x) { x.0 },
    fn(q, r) {
      q
      .over(Is(true))
      .presses(Is(false))
      .offset(By(fn() { (r.get().1.0 * page_w(), r.get().1.1 * tall()) }))
      .width(By(fn() { Some((r.get().1.2 - r.get().1.0) * page_w()) }))
      .height(By(fn() { Some((r.get().1.3 - r.get().1.1) * tall()) }))
      .ground(By(color))
      |> ignore
    },
    at_once=true,
  )
}

///|
/// What page `i` of viewer `vw`'s PDF answers to, over its picture in `page`: what is picked and the notes drawn on it,
/// a drag or a held finger picking, and what can be done with what is picked beside it. `tall_of` says how high each
/// page is laid out and `gap()` how far apart, so a drag goes on over the pages round it.
fn pdf_page_marks_node(
  page : @view.View,
  vw : Viewer,
  i : Int,
  count : Int,
  page_w : () -> Double,
  tall_of : (Int) -> Double,
  gap : () -> Double,
  bars : () -> Bool,
) -> Unit {
  let m = vw.pdf_marks
  let tall = fn() { tall_of(i) }
  page.box(fn(b) {
    pdf_rects_node(
      b,
      fn() {
        let out = []
        for x in vw.pdf_notes() {
          out.append(pdf_rects_of(m.doc, x.what, i))
        }
        out
      },
      fn() { @sf.alpha(0xF5C518FFL, 0.38) },
      page_w,
      tall,
    )
  })
  |> ignore
  // (the note open (written, or opened from the list) a step stronger over its own)
  page.box(fn(b) {
    pdf_rects_node(
      b,
      fn() {
        let id = m.writing.get()
        match vw.pdf_notes().iter().find_first(fn(x) { x.id == id }) {
          Some(x) => pdf_rects_of(m.doc, x.what, i)
          None => []
        }
      },
      fn() { @sf.alpha(0xF5A30FFFL, 0.36) },
      page_w,
      tall,
    )
  })
  |> ignore
  page.box(fn(b) {
    pdf_rects_node(
      b,
      fn() {
        match m.picked.get() {
          Some(what) => pdf_rects_of(m.doc, what, i)
          None => []
        }
      },
      fn() { @sf.alpha(@sf.theme().p.accent, 0.3) },
      page_w,
      tall,
    )
  })
  |> ignore
  page.box(fn(o) {
    // (where a point of this page's node lies: on this page, or past its top or foot on the pages round it)
    let spot = fn(x : Double, y : Double) -> (Int, Double, Double) {
      let mut j = i
      let mut at = y
      while at < 0.0 && j > 0 {
        j -= 1
        at += tall_of(j) + gap()
      }
      while at > tall_of(j) && j < count - 1 {
        at -= tall_of(j) + gap()
        j += 1
      }
      let w = page_w()
      let h = tall_of(j)
      (j, pdf_share(if w > 0.0 { x / w } else { 0.0 }), pdf_share(if h > 0.0 { at / h } else { 0.0 }))
    }
    let begin = fn(x : Double, y : Double) {
      m.settled.set(false)
      m.picked.set(None)
      let (j, u, v) = spot(x, y)
      match vw.pdf_doc() {
        Some(doc) if doc.page(j).readable() && doc.page(j).near(u, v, pdf_words_reach) => {
          m.words_from = Some((j, pdf_end(doc.page(j), u, v)))
          m.area_from = None
        }
        _ => {
          m.words_from = None
          m.area_from = Some((j, u, v))
        }
      }
    }
    let pick_to = fn(x : Double, y : Double) {
      match (m.words_from, m.area_from, m.doc) {
        (Some((pa, a)), _, Some(doc)) => {
          let (j, u, v) = spot(x, y)
          m.picked.set(pdf_span(pa, a, j, pdf_end(doc.page(j), u, v)))
        }
        (_, Some((pa, ua, va)), _) => {
          // (an area stays on the page it began on)
          let w = page_w()
          let h = tall_of(pa)
          let u = pdf_share(if w > 0.0 { x / w } else { 0.0 })
          let v = pdf_share(if h > 0.0 { y / h } else { 0.0 })
          m.picked.set(Some(Area(pa, dmin(ua, u), dmin(va, v), dmax(ua, u), dmax(va, v))))
        }
        _ => ()
      }
    }
    let edge = fn(wy : Double) {
      match o.scroll_holding() {
        Some(s) => {
          let (top, high) = match s.shown_by() {
            Some(v) => {
              let (_, y, _, h) = v.rect()
              (y, h)
            }
            None => (0.0, o.window_h())
          }
          let speed = if wy < top + pdf_edge_room {
            -pdf_edge_speed * dmin(1.0, (top + pdf_edge_room - wy) / pdf_edge_room)
          } else if wy > top + high - pdf_edge_room {
            pdf_edge_speed * dmin(1.0, (wy - (top + high - pdf_edge_room)) / pdf_edge_room)
          } else {
            0.0
          }
          s.edge_toward(speed)
        }
        None => ()
      }
    }
    let edge_off = fn() {
      match o.scroll_holding() {
        Some(s) => s.edge_toward(0.0)
        None => ()
      }
    }
    let finish = fn() {
      edge_off()
      m.held = false
      match m.picked.untracked() {
        Some(Area(_, x0, y0, x1, y1)) if x1 - x0 < pdf_area_least || y1 - y0 < pdf_area_least => m.let_go()
        Some(_) => m.settled.set(true)
        None => m.let_go()
      }
    }
    o
    .over(Is(true))
    .cursor(Is(Some(IBeam)))
    .gesture(
      @ui.touch_slop(),
      tap=fn(_) {
        if m.picked.untracked() is Some(_) {
          m.let_go()
        } else if m.writing.untracked() != "" {
          vw.pdf_note_done()
        } else if bars() {
          vw.toggle()
        }
      },
      hold=(
        @ui.long_press_ms,
        fn(d) {
          let (j, u, v) = spot(d.ox, d.oy)
          // (held on words: the word under it, the finger sliding on picking on from it; held off them (a figure, a
          // scanned page): an area from there, the finger sliding on framing it)
          let word = match vw.pdf_doc() {
            Some(doc) if doc.page(j).readable() && doc.page(j).near(u, v, pdf_words_reach) =>
              doc.page(j).nearest(u, v).map(fn(k) { (k, doc.page(j).word_at(k)) })
            _ => None
          }
          m.held = true
          m.settled.set(false)
          match word {
            Some((_, (a, e))) => {
              m.words_from = Some((j, a))
              m.area_from = None
              m.picked.set(pdf_span(j, a, j, e))
            }
            None => {
              m.words_from = None
              m.area_from = Some((j, u, v))
              m.picked.set(None)
            }
          }
          @ui.haptic(KeyboardTap)
        },
      ),
      drag=fn(d) {
        match d.kind {
          Down => {
            if !m.held {
              begin(d.ox, d.oy)
            }
            pick_to(d.x, d.y)
            edge(d.wy)
          }
          Moved => {
            pick_to(d.x, d.y)
            edge(d.wy)
          }
          Up => finish()
          Off => {
            edge_off()
            m.let_go()
          }
        }
      },
      // (a finger that moves before it is held scrolls the pages; a mouse picks from the press)
      held_first=@sf.drags_once_held,
    )
    |> ignore
    // (what can be done with what is picked, over where it ends; in the layer over the window, clear of the list)
    let host = match (@sf.window_tips().layer)() {
      Some(l) => l.box(fn(h) { h.over(Is(true)) |> ignore }).lives_with(o)
      None => o
    }
    host.pick(
      fn() {
        if m.settled.get() {
          match m.picked.get() {
            Some(what) if pdf_last_page(what) == i => Some(what)
            _ => None
          }
        } else {
          None
        }
      },
      fn(holds, what) {
        guard what is Some(w) else { return }
        let last = pdf_rects_of(m.doc, w, i)
        guard last.last() is Some((x0, y0, x1, y1)) else { return }
        let words = pdf_words_of(m.doc, w)
        let items : Array[@sf.PickBarItem] = []
        if vw.draft_key() != "" {
          items.push({
            label: @sf.t("web-main.chat.quote"),
            icon: "quote",
            mark: false,
            press: fn() { vw.pdf_quote_picked() },
          })
          if @signals.untracked(fn() { vw.pdf_notes() }).length() < pdf_marks_most {
            items.push({
              label: pv("android-chat.pdf.mark"),
              icon: "edit",
              mark: false,
              press: fn() { vw.pdf_mark_picked() },
            })
          }
        }
        if words != "" {
          items.push({
            label: @sf.t("common.copy"),
            icon: "copy",
            mark: false,
            press: fn() {
              copy_out(words, said=pv("android-chat.annotate.copied"))
              m.let_go()
            },
          })
        }
        guard !items.is_empty() else { return }
        holds.box(fn(bar) {
          bar
          .beside(o.id(), side=Top, offset=8.0, while_seen=true, piece=fn(w, h) {
            Some((x0 * w, y0 * h, (x1 - x0) * w, (y1 - y0) * h))
          })
          |> ignore
          @sf.pick_bar_node(bar, items) |> ignore
        })
        |> ignore
      },
    )
  })
  |> ignore
}

///|
fn pdf_share(v : Double) -> Double {
  dmax(0.0, dmin(1.0, v))
}
