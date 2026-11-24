// Picking and marking a PDF where it is shown. The host draws each page as a picture; what the page says and where comes
// from reading the file (@pdftext), so words are picked over the picture: dragged with a mouse, held and slid with a
// finger (a finger that just moves scrolls). A drag that starts off the words frames an area instead, for a figure or a
// scanned page. What is picked is copied, quoted into the chat's draft, or kept as a note on the page; the notes go into
// the draft together, each a quote that says the file, the page, the words and what was said of them.

///|
/// What is picked: words from a page's glyph to another's (not that glyph), or an area of one page, as fractions of it.
#derive(Eq, Debug)
pub(all) enum PdfPicked {
  Words(Int, Int, Int, Int)
  Area(Int, Double, Double, Double, Double)
}

///|
/// A note kept on the page, until it goes into the draft.
pub(all) struct PdfMark {
  id : Int
  what : PdfPicked
  text : String
  mut comment : String
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
  marks : Array[PdfMark]
  /// told as `marks` changes
  told : @signals.Signal[Int]
  /// the note being written (-1 none)
  writing : @signals.Signal[Int]
  note : @ui.Field
  mut next : Int
  /// where the words being picked began: a page and a glyph
  mut words_from : (Int, Int)?
  /// where the area being framed began: a page and a point of it
  mut area_from : (Int, Double, Double)?
  /// a finger's hold picked the word it began on
  mut held : Bool
}

///|
fn PdfMarks::new() -> PdfMarks {
  {
    doc: None,
    read: false,
    picked: @signals.signal(None),
    settled: @signals.signal(false),
    marks: [],
    told: @signals.signal(0),
    writing: @signals.signal(-1),
    note: @ui.Field::new(),
    next: 1,
    words_from: None,
    area_from: None,
    held: false,
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
/// What is picked kept as a note on the page, its words to be written.
fn Viewer::pdf_mark_picked(self : Viewer) -> Unit {
  let m = self.pdf_marks
  guard m.picked.untracked() is Some(what) && m.marks.length() < pdf_marks_most else { return }
  let id = m.next
  m.next += 1
  m.marks.push({ id, what, text: pdf_words_of(m.doc, what), comment: "" })
  m.let_go()
  m.told.set(m.told.untracked() + 1)
  m.note.set("")
  m.writing.set(id)
  m.note.focus()
}

///|
/// The note being written, done: what it says kept.
fn Viewer::pdf_note_done(self : Viewer) -> Unit {
  let m = self.pdf_marks
  let id = m.writing.untracked()
  guard id >= 0 else { return }
  let said = m.note.take().trim(chars=" \n\t").to_owned()
  for x in m.marks {
    if x.id == id {
      x.comment = said
    }
  }
  m.writing.set(-1)
  m.note.let_go()
  m.told.set(m.told.untracked() + 1)
}

///|
/// The note being written taken off the page.
fn Viewer::pdf_note_removed(self : Viewer) -> Unit {
  let m = self.pdf_marks
  let id = m.writing.untracked()
  guard id >= 0 else { return }
  match m.marks.search_by(fn(x) { x.id == id }) {
    Some(k) => m.marks.remove(k) |> ignore
    None => ()
  }
  m.note.set("")
  m.writing.set(-1)
  m.note.let_go()
  m.told.set(m.told.untracked() + 1)
}

///|
/// Every note off the page.
fn Viewer::pdf_marks_cleared(self : Viewer) -> Unit {
  let m = self.pdf_marks
  m.marks.clear()
  m.note.set("")
  m.writing.set(-1)
  m.note.let_go()
  m.told.set(m.told.untracked() + 1)
}

///|
/// Every note into the draft, as one quote each.
fn Viewer::pdf_marks_sent(self : Viewer) -> Unit {
  self.pdf_note_done()
  let m = self.pdf_marks
  let quotes = m.marks.map(fn(x) { pdf_quote(self.file.name, x.what, x.text, x.comment) })
  m.marks.clear()
  m.told.set(m.told.untracked() + 1)
  self.pdf_give(quotes)
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
    if m.writing.untracked() >= 0 {
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
/// Boxes in `b` over a page `page_w()` wide and `tall()` high, each at `rects()`'s place, in `color`.
fn pdf_rects_node(
  b : @view.View,
  rects : () -> Array[(Double, Double, Double, Double)],
  color : () -> Int64,
  page_w : () -> Double,
  tall : () -> Double,
) -> Unit {
  b.over(Is(true)).presses(Is(false)) |> ignore
  b.pick(rects, fn(p, now) {
    p.over(Is(true)).presses(Is(false)) |> ignore
    for r in now {
      let (x0, y0, x1, y1) = r
      p.box(fn(q) {
        q
        .over(Is(true))
        .presses(Is(false))
        .offset(By(fn() { (x0 * page_w(), y0 * tall()) }))
        .width(By(fn() { Some((x1 - x0) * page_w()) }))
        .height(By(fn() { Some((y1 - y0) * tall()) }))
        .ground(By(color))
        |> ignore
      })
      |> ignore
    }
  })
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
        m.told.get() |> ignore
        let out = []
        for x in m.marks {
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
        } else if m.writing.untracked() >= 0 {
          vw.pdf_note_done()
        } else if bars() {
          vw.toggle()
        }
      },
      hold=(
        @ui.long_press_ms,
        fn(d) {
          let (j, u, v) = spot(d.ox, d.oy)
          match vw.pdf_doc() {
            Some(doc) if doc.page(j).readable() =>
              match doc.page(j).nearest(u, v) {
                Some(k) => {
                  let (a, e) = doc.page(j).word_at(k)
                  m.words_from = Some((j, a))
                  m.area_from = None
                  m.held = true
                  m.settled.set(false)
                  m.picked.set(pdf_span(j, a, j, e))
                  @ui.haptic(KeyboardTap)
                }
                None => ()
              }
            _ => ()
          }
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
          if m.marks.length() < pdf_marks_most {
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
          .beside(o.id(), side=Top, offset=8.0, piece=fn(w, h) { Some((x0 * w, y0 * h, (x1 - x0) * w, (y1 - y0) * h)) })
          |> ignore
          @sf.pick_bar_node(bar, items) |> ignore
        })
        |> ignore
      },
    )
    // (the note being written, under where it lies on its last page)
    host.pick(
      fn() {
        let id = m.writing.get()
        m.told.get() |> ignore
        match m.marks.search_by(fn(x) { x.id == id }) {
          Some(k) if pdf_last_page(m.marks[k].what) == i => Some(id)
          _ => None
        }
      },
      fn(holds, id) {
        guard id is Some(n) else { return }
        guard m.marks.search_by(fn(x) { x.id == n }) is Some(k) else { return }
        let rects = pdf_rects_of(m.doc, m.marks[k].what, i)
        guard rects.last() is Some((x0, y0, x1, y1)) else { return }
        holds.box(fn(card) {
          card
          .beside(o.id(), side=Bottom, offset=8.0, piece=fn(w, h) { Some((x0 * w, y0 * h, (x1 - x0) * w, (y1 - y0) * h)) })
          .width(Is(Some(pdf_note_w)))
          .radius(Is(note_box_corner))
          .ground(Is(note_ground))
          .padding(Is((6.0, 6.0, 6.0, 6.0)))
          .row(Is(true))
          .lines_up(Is(Some(End)))
          .gap(Is(4.0))
          |> ignore
          note_key_node(card, "trash", 17.0, 0L, note_muted, pv("android-chat.annotate.remove"), fn() {
            vw.pdf_note_removed()
          })
          card.box(fn(f) {
            f
            .grow(Is(1.0))
            .basis(Is(Some(0.0)))
            .shrink(Is(1.0))
            .padding(Is((8.0, 7.0, 8.0, 7.0)))
            .min_height(Is(Some(36.0)))
            .row(Is(true))
            .lines_up(Is(Some(Middle)))
            |> ignore
            @ui.field(
              f,
              m.note,
              placeholder=pv("android-chat.annotate.write"),
              font_size=16.0,
              line=21.0,
              max_lines=6,
              color=note_ink,
              placeholder_color=note_subtle,
              caret_color=note_accent,
              enter_sends=false,
            )
            .grow(Is(1.0))
            |> ignore
          })
          |> ignore
          note_key_node(card, "check", 18.0, note_ink, note_bg, pv("android-chat.annotate.done"), fn() {
            vw.pdf_note_done()
          })
        })
        |> ignore
      },
    )
  })
  |> ignore
}

///|
/// How wide the card a note is written in is.
let pdf_note_w : Double = 320.0

///|
fn pdf_share(v : Double) -> Double {
  dmax(0.0, dmin(1.0, v))
}

///|
/// The notes kept on the pages, said at the stage's foot: all of them into the chat's draft, or off the pages. Where the
/// viewer has no chat to put them in, none are made.
fn pdf_marks_bar_node(parent : @view.View, vw : Viewer) -> Unit {
  let m = vw.pdf_marks
  let any = fn() {
    m.told.get() |> ignore
    m.marks.length() > 0
  }
  parent.show(any, fn(l) {
    // (nothing of its own to press but its keys: the pages under it keep the rest)
    l.over(Is(true)).lines_up(Is(Some(Middle))) |> ignore
    l.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
    l.box(fn(r) {
      r
      .row(Is(true))
      .lines_up(Is(Some(Middle)))
      .gap(Is(8.0))
      .padding(Is((0.0, 0.0, 0.0, 16.0)))
      |> ignore
      @sf.button_node(r, fn() { pv("android-chat.pdf.marks.clear") }, fn() { vw.pdf_marks_cleared() }) |> ignore
      @sf.button_node(
        r,
        fn() {
          m.told.get() |> ignore
          pv_fill("android-chat.pdf.marks.send", [("n", "\{m.marks.length()}")])
        },
        fn() { vw.pdf_marks_sent() },
        tone=Primary,
      )
      |> ignore
    })
    |> ignore
  })
}
