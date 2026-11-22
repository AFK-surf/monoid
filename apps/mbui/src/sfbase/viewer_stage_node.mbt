// What a viewer's stage shows of a file that is not a picture of its own, a film or a song, nor a widget (Viewer's
// content, as it is told: its kind, its bytes, 源码), as nodes of the window's tree, made once: words read as they come
// (a part at a time, read on as their end comes near), words in the reader (@sf.reader_node), a PDF's pages, a page of
// HTML (a native page of its own), a table, code and text. Each long one is a page's list (View::scrolls_window: a
// block made only while it shows), code's rows scrolled across as one (Scroll::beside). Its words are picked with the
// pointer (@ui.words_picked); a tap on what holds them shows or hides the viewer's bars (Viewer::toggle). Laid out by
// the stage's width (`width`: the window's, or a tab's beside a chat), as the web's are under 640 and over it.

///|
/// What a viewer's stage shows (viewer_stage_node's), as it is told.
#derive(Eq)
priv enum StageShows {
  StageNone
  /// what has come of words read as they come, of a kind
  StageFlow(PKind)
  /// words read in the reader, Markdown or not
  StageReads(Bool)
  StagePdf
  StageHtml
  /// a table, its cells cut at tabs (else commas)
  StageCsv(Bool)
  /// code or words as they are, of a kind
  StageLines(PKind)
}

///|
/// What viewer `vw`'s stage shows now (Viewer::content's choice): what has come of it as it comes; read whole, its
/// kind's (源码 as code: Viewer::set_source).
fn Viewer::stage_shows(self : Viewer) -> StageShows {
  let v = self
  v.source_told.get() |> ignore
  v.flow_told.get() |> ignore
  let kind = v.shown_kind()
  if v.flowing() {
    match (v.flow, kind) {
      (Some(_), Some(k)) => StageFlow(k)
      _ => StageNone
    }
  } else {
    match (kind, v.bytes.get()) {
      (_, Some(_)) if vf_reads(v) => StageReads(kind == Some(KMarkdown))
      (Some(KPdf), Some(_)) => StagePdf
      (Some(KHtml), Some(_)) if !v.source => StageHtml
      (Some(KCsv), Some(_)) if !v.source => StageCsv(@sf.lower(v.name).has_suffix(".tsv"))
      (Some(k), Some(_)) => StageLines(k)
      _ => StageNone
    }
  }
}

///|
/// What viewer `vw` shows of a file read whole or as it comes in node `n` (all of its room, `width()` wide): as
/// StageShows says, made again as that changes. Its words picked with the pointer, a mouse's drag or a finger's hold;
/// where its bar floats, a tap on what holds them (not the reader's, not a page's own) shows or hides it.
pub fn viewer_stage_node(n : @view.View, src : Source, vw : Viewer, width : () -> Double, panel? : Bool = false) -> Unit {
  n.over(Is(true)) |> ignore
  @ui.words_picked(n)
  n.pick(fn() { vw.stage_shows() }, fn(p, shows) {
    p.over(Is(true)) |> ignore
    // (a ground where its bar floats (小屏), under what it shows: a tap on it or on the words over it, the bars come
    // and go; else taking no press, a mouse's press on the words picking them; under them, never round them, so what
    // scrolls takes the wheel and the hand whatever it says) and what it shows over it, the node given back
    let taps = fn() -> @view.View {
      p.box(fn(g) {
        g
        .over(Is(true))
        .presses(By(fn() { @sf.viewer_bar_floats(width()) }))
        .on_press(fn() { vw.toggle() })
        .cursor(Is(Some(Arrow)))
        .as_ground()
        |> ignore
      })
      |> ignore
      p.box(fn(q) { q.over(Is(true)) |> ignore })
    }
    match shows {
      StageNone => ()
      StageFlow(kind) => {
        let q = taps()
        match vw.flow {
          Some(f) => flow_stage_node(q, src, vw, f, kind, width)
          None => ()
        }
      }
      StageReads(markdown) =>
        match vw.bytes.untracked() {
          Some(b) => {
            let file = @sf.blob_file(b, vw.file.name, vw.file.size, mime=vw.mime, save=fn() { vw.save_tree() })
            @sf.reader_node(
              p,
              vw.read_key(),
              file,
              markdown~,
              back_label=fn() { vw.desk_back(src) },
              on_back=fn() { vw.shut_tree() },
              host=if !vw.beside {
                @sf.ReaderHost::OwnPage
              } else if panel {
                @sf.ReaderHost::PanelTab
              } else {
                @sf.ReaderHost::Tab
              },
              width~,
              move_beside=if vw.beside {
                None
              } else {
                Some((fn() { beside_offered(vw.file.path, vw.file.name) }, fn() { vw.move_beside(src) }))
              },
            )
            |> ignore
          }
          None => ()
        }
      StagePdf => {
        pdf_stage_node(taps(), vw, width)
      }
      StageHtml => html_stage_node(p, vw, width)
      StageCsv(tab) => {
        csv_stage_node(taps(), vw, tab, width)
      }
      StageLines(kind) => {
        text_stage_node(taps(), vw, kind, width)
      }
    }
  }, at_once=true)
}

///|
/// How far down a document starts on viewer `vw`'s stage (Viewer::stage_top's): over the whole window, `under` under the
/// system's status bar; in a tab beside a chat, `own` under the tab's tools. As the status bar changes.
fn Viewer::stage_top_node(self : Viewer, under : Double, own : Double) -> Double {
  if self.beside {
    own
  } else {
    (@sf.viewer_host().room)().0 + under
  }
}

///|
/// How far the system's navigation bar reaches over a stage `w` wide's foot (viewer_foot's): none on 小屏.
fn stage_foot_room(w : Double) -> Double {
  if @sf.viewer_bar_floats(w) {
    0.0
  } else {
    (@sf.viewer_host().room)().1
  }
}

///|
/// A note in the middle of a stage in `parent` (Viewer::note's: 24 round it, what it holds 14 apart): `words` as they
/// change, in the body's size, muted, in the middle.
fn stage_note_node(parent : @view.View, words : () -> String) -> Unit {
  parent.box(fn(note) {
    note.over(Is(true)).padding(Is((24.0, 24.0, 24.0, 24.0))).gap(Is(14.0)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
    note.box(fn(w) {
      w
      .words(By(words))
      .words_look(By(fn() {
        let size = @sf.theme().t.body
        { size, weight: 400, line: @ui.tree_theme().text_line * size, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 }
      }))
      .words_centered(Is(true))
      .ink(By(fn() { @sf.theme().p.muted }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

// ── a PDF ──────────────────────────────────────────────────────────────

///|
/// A PDF's pages in `parent` (Viewer::pdf_stage's), drawn by the system each as it scrolls near (a page's list, a page
/// a block), as wide as the stage allows: as the web's, 76 down (under the bar), as wide as 1000 less 56 allows, 20
/// apart; under 640, 60 down, 12 round them and between them; on white, raised, a page not drawn yet its shape on the
/// neutral grey. One that cannot be opened, said so.
fn pdf_stage_node(parent : @view.View, vw : Viewer, width : () -> Double) -> Unit {
  let pdf = match vw.pdf {
    Some(p) => p
    None =>
      match vw.bytes.untracked() {
        Some(b) => {
          let p = @ui.Pdf::open(b)
          vw.pdf = Some(p)
          @ui.log("preview: \{vw.name}: a PDF of \{p.pages} pages")
          p
        }
        None => return
      }
  }
  if pdf.pages < 0 {
    stage_note_node(parent, fn() {
      pv_fill("android-chat.file.pdf.failed", [("error", if @ui.platform() >= 3 { @sf.t("android-chat.preview.noPdf") } else { "" })])
    })
    return
  }
  let small = fn() { width() <= @sf.viewer_small_w }
  let page_w = fn() {
    let w = width()
    if small() {
      w - 2.0 * pdf_small_in
    } else {
      desk_pdf_width(w)
    }
  }
  let gap = fn() { if small() { pdf_small_in } else { desk_pdf_gap } }
  let keys = Array::makei(pdf.pages, fn(i) { i })
  parent.scrolls_window(
    @view.Scroll::list(),
    fn() { keys },
    fn(row, i) {
      let (pw, ph) = pdf.sizes[i]
      let tall = fn() { if pw > 0.0 { page_w() * ph / pw } else { page_w() * pdf_page_share } }
      row
      .lines_up(Is(Some(Middle)))
      .height(By(fn() { Some(tall() + (if i < pdf.pages - 1 { gap() } else { 0.0 })) }))
      |> ignore
      row.box(fn(page) {
        page
        .width(By(fn() { Some(page_w()) }))
        .height(By(fn() { Some(tall()) }))
        .ground(Is(0xFFFFFFFFL))
        .shadow(Is((@sf.page_raised.sigma, @sf.page_raised.dy, @sf.page_raised.color)))
        |> ignore
        page.box(fn(img) {
          img
          .grow(Is(1.0))
          .ground(By(fn() { @sf.theme().p.neutral_bg }))
          .image(By(fn() { Some((pdf.page_src(i), "", (page_w() * img.pixel_scale()).ceil().to_int())) }))
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    est=pdf_est,
    slop=@ui.touch_slop(),
    bar=@ui.tree_scroll_bar(),
    head=fn(h) {
      h.height(By(fn() { Some(vw.stage_top_node(if small() { page_small_top } else { desk_page_top }, gap())) })) |> ignore
    },
    foot=fn(f) {
      f
      .height(By(fn() {
        Some(
          if vw.beside {
            gap()
          } else if small() {
            pdf_small_in
          } else {
            stage_foot_room(width()) + desk_pdf_foot
          },
        )
      }))
      |> ignore
    },
  )
  |> ignore
}

///|
/// A PDF's page of no size said, as tall for as wide (A4's).
let pdf_page_share : Double = 1.294

///|
/// How tall a PDF's page is guessed at before it is laid out.
let pdf_est : Double = 400.0

// ── a page ─────────────────────────────────────────────────────────────

///|
/// A page of HTML in `parent` (Viewer::text_stage's): its scripts run, in a page of its own that reaches nothing of the
/// app's (a native page, made once from the file's words), under the bar: 60 under the status bar, wider than 640 76;
/// where this host has no page, said so.
fn html_stage_node(parent : @view.View, vw : Viewer, width : () -> Double) -> Unit {
  let page = match vw.page {
    Some(p) => p
    None => {
      let words = stage_words(vw)
      let head = words.clamped_view(end=if words.length() < 2048 { words.length() } else { 2048 }).to_owned()
      let low = @sf.lower(head)
      let html = if low.contains("<!doctype") || low.contains("<html") {
        words
      } else {
        "<!doctype html><meta charset=utf-8><meta name=viewport content=\"width=device-width,initial-scale=1\"><body style=\"margin:0;padding:16px;font-family:system-ui,sans-serif\">" +
        words
      }
      let p = @ui.NativeView::page(html)
      vw.page = Some(p)
      p
    }
  }
  parent.box(fn(b) {
    b
    .over(Is(true))
    .padding(By(fn() {
      (0.0, vw.stage_top_node(if width() <= @sf.viewer_small_w { page_small_top } else { desk_page_top }, 0.0), 0.0, 0.0)
    }))
    |> ignore
    if page.here() {
      // (the viewer's: closed as it is let go, Viewer::let_go)
      @ui.native(b, page, kept=true).grow(Is(1.0)) |> ignore
    } else {
      stage_note_node(b, fn() { pv("android-chat.file.cantPreview") })
    }
  })
  |> ignore
}

///|
/// What viewer `vw`'s file says, decoded once (at most show_limit of it).
fn stage_words(vw : Viewer) -> String {
  match vw.text {
    Some(s) => s
    None => {
      let s = match vw.bytes.untracked() {
        Some(b) => @codec.utf8_text(b, show_limit)
        None => ""
      }
      vw.text = Some(s)
      s
    }
  }
}

// ── code and text ──────────────────────────────────────────────────────

///|
/// Code and words as they are in `parent` (Viewer::text_stage's): in the code face, code in the colours the core says
/// of its language (`code.ink`, the whole as one, then cut at its lines: up to highlight_limit), words and what is past
/// it as they are; a file shown only in part said so over them.
fn text_stage_node(parent : @view.View, vw : Viewer, kind : PKind, width : () -> Double) -> Unit {
  let words = stage_words(vw)
  let cut = match vw.bytes.untracked() {
    Some(b) if b.length() > show_limit => Some(pv_fill("android-chat.file.cut", [("size", @sf.file_size(show_limit.to_double()))]))
    _ => None
  }
  let lines = words.split("\n").map(fn(s) { s.to_owned() }).to_array()
  let (_, _, language) = preview_kind(vw.name)
  let lang = if kind == KMarkdown || kind == KCsv || kind == KText || words.length() > highlight_limit {
    ""
  } else {
    language
  }
  // (what the core says of its language, asked as it is made: plain till it says)
  let ink = if lang != "" {
    @sf.code_ink_node(parent, fn() { words }, fn() { lang })
  } else {
    fn() { Some(None) }
  }
  let colored = @signals.computed(fn(_) {
    match ink() {
      Some(Some(i)) => runs_by_line(@sf.ink_runs(words, i, @sf.theme().dark))
      _ => []
    }
  })
  let told = @signals.signal(0)
  lines_stage_node(parent, vw, kind, width, fn() { lines.length() }, fn(k) { lines[k] }, fn(k) { colored.get().get(k) }, fn() {
    cut
  }, told)
}

///|
/// Code and words in the code face in `parent` (Viewer::lines_stage's), `count()` lines (`line(k)`, coloured as
/// `colored(k)` says, else plain; what they read changes as `told` is), in rows of 60 lines, a row a block of a page's
/// list, so a long file lays out only what is in view; code's rows not wrapped, scrolled across as one, 32 in from
/// their sides; `cut()`: what it says over them of a file shown only in part, or of reading on that failed. As the
/// web's (fpCode 80 down, 32 in, 12 on 1.6; fpPlain 76 down, 32 in, 12 on 1.65; under 640, words 60 down, 16 in, 48
/// under). `near`: what reads more as its foot comes near, while it wants more (scrolls_window's `near_foot`).
fn lines_stage_node(
  parent : @view.View,
  vw : Viewer,
  kind : PKind,
  width : () -> Double,
  count : () -> Int,
  line : (Int) -> String,
  colored : (Int) -> Array[@ui.Run]?,
  cut : () -> String?,
  told : @signals.Signal[Int],
  near? : (Double, () -> Bool, () -> Unit),
) -> Unit {
  let code = kind != KText && kind != KCsv
  let small = fn() { width() <= @sf.viewer_small_w && !code }
  let side = fn() { if small() { plain_small_side } else { desk_text_side } }
  let height = if code { desk_code_line } else { desk_plain_line }
  // (code's rows scrolled across as one: each a scroll beside this one)
  let across = @view.Scroll::across()
  let rows = fn() {
    told.get() |> ignore
    let n = count()
    Array::makei((n + lines_per_row - 1) / lines_per_row, fn(i) { i })
  }
  parent.scrolls_window(
    @view.Scroll::list(),
    rows,
    fn(row, i) {
      let words = fn() -> Array[@ui.Run] {
        told.get() |> ignore
        let n = count()
        let from = i * lines_per_row
        let to = if from + lines_per_row < n { from + lines_per_row } else { n }
        let sb = StringBuilder()
        let runs : Array[@ui.Run] = []
        let mut inked = true
        for k in from..<to {
          if k > from {
            sb.write_char('\n')
            runs.push(@ui.span("\n", mono=true))
          }
          let words = line(k)
          sb.write_string(words)
          match colored(k) {
            Some(l) => runs.push_iter(l.iter())
            None => {
              inked = inked && words == ""
              runs.push(@ui.span(words, mono=true))
            }
          }
        }
        if inked {
          runs
        } else {
          [@ui.span(sb.to_string(), mono=true)]
        }
      }
      let look = fn(w : @view.View) {
        w
        .words_runs(By(words))
        .words_look(Is({
          size: desk_code_size,
          weight: 400,
          line: height,
          wrap: !code,
          tracking: @view.letters_own,
          balance: false,
          max_lines: 0,
        }))
        .ink(By(fn() { @sf.theme().p.text }))
        // (code unwrapped, each of its lines on its own: an old view's `breaks`)
        .words_breaks(Is(code))
        |> ignore
      }
      if code {
        // scrolled across, its rows as one (32 in from its sides)
        row.scrolls(across.beside(), fn(s) {
          s.padding(Is((desk_text_side, 0.0, desk_text_side, 0.0))) |> ignore
          s.box(look) |> ignore
        })
        |> ignore
      } else {
        row.padding(By(fn() { (side(), 0.0, side(), 0.0) })) |> ignore
        row.box(look) |> ignore
      }
    },
    est=lines_est,
    slop=@ui.touch_slop(),
    bar=@ui.tree_scroll_bar(),
    near_foot?=near,
    head=fn(h) {
      h.box(fn(top) {
        top.height(By(fn() { Some(vw.stage_top_node(if small() { page_small_top } else if code { 80.0 } else { desk_page_top }, beside_text_top)) }))
        |> ignore
      })
      |> ignore
      h.show(fn() { cut() is Some(_) }, fn(c) { cut_line_node(c, fn() { cut().unwrap_or("") }) })
    },
    foot=fn(f) { f.height(By(fn() { Some(if small() { plain_small_foot } else { desk_text_foot }) })) |> ignore },
  )
  |> ignore
}

///|
/// A block of code or words holds this many lines (lines_stage's 60), and is guessed this tall before it is laid out.
let lines_per_row : Int = 60

///|
let lines_est : Double = 400.0

///|
/// A file shown only in part in `parent` (cut_line's): the warning's words (`words`) on its tint, 20 in and 8 round.
fn cut_line_node(parent : @view.View, words : () -> String) -> Unit {
  parent.box(fn(b) {
    b.padding(Is((20.0, 8.0, 20.0, 8.0))).ground(Is(@sf.alpha(cut_warn, 0.14))) |> ignore
    b.box(fn(w) {
      w
      .words(By(words))
      .words_look(By(fn() {
        let size = @sf.theme().t.meta
        { size, weight: 400, line: @ui.tree_theme().text_line * size, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 }
      }))
      .ink(Is(cut_warn))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// The warning's colour (cut_line's).
let cut_warn : Int64 = 0xD9962BFFL

// ── as it comes ────────────────────────────────────────────────────────

///|
/// What has come of words read as they come in `parent` (Viewer::flow_stage's), as a file's words are
/// (lines_stage_node): its lines and the one begun, coloured where they are (code, a piece at a time: flow_ink_node);
/// the next part read as its end comes near (Viewer::read_on); why reading on failed over them.
fn flow_stage_node(parent : @view.View, src : Source, vw : Viewer, f : Flow, kind : PKind, width : () -> Double) -> Unit {
  let (_, _, language) = preview_kind(vw.name)
  let told = flow_ink_node(parent, f, if kind == KCode { language } else { "" })
  lines_stage_node(
    parent,
    vw,
    kind,
    width,
    fn() {
      f.parts.get() |> ignore
      f.lines.length() + (if f.tail != "" { 1 } else { 0 })
    },
    fn(k) { if k < f.lines.length() { f.lines[k] } else { f.tail } },
    fn(k) {
      match f.colored.get(k) {
        Some(Some(line)) => Some(line)
        _ => None
      }
    },
    fn() {
      match f.failed.get() {
        Some(e) => Some(@sf.t("web-main.preview.loadFailed", args=[("error", e)]))
        None => None
      }
    },
    told,
    near=(flow_near, fn() {
      f.parts.get() |> ignore
      !f.reading && !f.whole() && f.failed.get() is None
    }, fn() { vw.read_on(src) }),
  )
}

///|
/// How many of its heights from its foot a text shown as it comes reads on (flow_ahead's rows of 60 lines, about).
let flow_near : Double = 10.0

///|
/// Flow `f`'s pieces coloured in node `v` as the core says of the file's language `lang` (Flow::ink's: asked as they
/// come, each once, as `v` reacts; for the theme shown, coloured again as it changes): told as each is coloured (the
/// signal given back, which what reads the colours reads).
fn flow_ink_node(v : @view.View, f : Flow, lang : String) -> @signals.Signal[Int] {
  let told = @signals.signal(0)
  guard lang != "" else { return told }
  v.reacts(
    fn() {
      f.parts.get() |> ignore
      // (each piece not coloured yet: whether the core has said of it)
      let said = f.pieces.map(fn(p) {
        if p.done {
          2
        } else {
          match @sf.code_ink_told(p.words, lang) {
            Some(_) => 1
            None => 0
          }
        }
      })
      (@sf.theme().dark, said)
    },
    fn(now) {
      let dark = now.0
      if f.colored_dark != dark {
        f.colored_dark = dark
        for p in f.pieces {
          if p.done {
            // (its words again, to colour for this theme)
            p.words = f.lines[p.from:p.to].iter().collect().join("\n")
            p.done = false
          }
        }
      }
      let mut coloured = false
      for p in f.pieces {
        guard !p.done else { continue }
        match @signals.untracked(fn() { @sf.code_ink_told(p.words, lang) }) {
          // (asked: plain until the core says)
          None => @sf.code_ink_ask(p.words, lang)
          Some(ink) => {
            match ink {
              Some(ink) =>
                for k, line in runs_by_line(@sf.ink_runs(p.words, ink, dark)) {
                  if p.from + k < p.to {
                    f.colored[p.from + k] = Some(line)
                  }
                }
              None => ()
            }
            p.done = true
            p.words = ""
            coloured = true
          }
        }
      }
      if coloured {
        told.set(told.untracked() + 1)
      }
    },
  )
  told
}

// ── a table ────────────────────────────────────────────────────────────

///|
/// A table in `parent` (csv_table's): a row number, then its columns, each as wide as what it holds (by its characters:
/// 48 to 420, at the size its words are drawn at), the head on the canvas with a hairline under it, 68 down (under the
/// bar); its rows a page's list's blocks, table_rows of them at most, each as tall as its words' line and 8 over and
/// under it; a cell longer than its column cut short with an ellipsis; all of it scrolled across as one where it is
/// wider than the page (each row a scroll beside the head's: Scroll::beside); more, or a file shown only in part, said
/// under them.
fn csv_stage_node(parent : @view.View, vw : Viewer, tab : Bool, width : () -> Double) -> Unit {
  ignore(width)
  let words = stage_words(vw)
  let cut = match vw.bytes.untracked() {
    Some(b) => b.length() > show_limit
    None => false
  }
  let rows = @codec.parse_csv(words, if tab { '\t' } else { ',' }, table_rows + 1)
  guard rows.length() > 0 else { return }
  let head = rows[0]
  let body_n = if rows.length() - 1 > table_rows { table_rows } else { rows.length() - 1 }
  let more = rows.length() - 1 > table_rows
  // (each column's width at the page's 13, in points: as wide again as the words are drawn larger)
  let widths = head.mapi(fn(j, _) {
    let mut most = 0.0
    for r in 0..<(if rows.length() < 201 { rows.length() } else { 201 }) {
      match rows[r].get(j) {
        Some(cell) => {
          let mut w = 0.0
          for ch in cell {
            w = w + (if ch.to_int() < 0x2E80 { 8.4 } else { 15.0 })
          }
          most = dmax(most, dmin(w, 80.0 * 8.4))
        }
        None => ()
      }
    }
    dmax(48.0, dmin(420.0, most + 32.0))
  })
  let number = "\{body_n}".length().to_double() * 8.4 + 36.0
  // (as wide as said at the page's size of words, wider as the system's size of words draws them larger)
  let scaled = fn(v : @view.View, w : Double) { w * @sf.node_sp(v, desk_cell_size) / desk_cell_size }
  let look = fn(weight : Int) -> @view.WordsLook {
    { size: desk_cell_size, weight, line: -desk_cell_share, wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 }
  }
  let cells = fn(row : @view.View, of : Array[String], weight : Int) {
    row.each(fn() { Array::makei(head.length(), fn(j) { j }) }, fn(j) { j }, fn(c, j) {
      let j = j.untracked()
      c.width(By(fn() { Some(scaled(c, widths[j])) })).padding(Is((16.0, 8.0, 16.0, 8.0))) |> ignore
      c.box(fn(w) {
        w
        .words(Is(of.get(j).unwrap_or("")))
        .words_look(Is(look(weight)))
        .ink(By(fn() { @sf.theme().p.text }))
        // (longer than its column: cut short with an ellipsis, never a glyph cut in half)
        .cuts(Is(true))
        .min_width(Is(Some(0.0)))
        .allow_ellipsis(Is(true))
        |> ignore
      })
      |> ignore
    }, at_once=true)
  }
  // (its number and its cells, scrolled across with every other row: `row` a scroll beside the others)
  let line_of = fn(row : @view.View, across : @view.Scroll, number_of : String, of : Array[String], weight : Int, ground : Bool) {
    row.scrolls(across.beside(), fn(s) {
      s.box(fn(l) {
        l.row(Is(true)) |> ignore
        if ground {
          l.ground(By(fn() { @sf.theme().p.canvas })) |> ignore
        }
        l.box(fn(n) {
          n.width(By(fn() { Some(scaled(n, number)) })).padding(Is((20.0, 8.0, 16.0, 8.0))).lines_up(Is(Some(End))) |> ignore
          n.box(fn(w) {
            w
            .words(Is(number_of))
            .words_look(Is(look(400)))
            .ink(By(fn() { @sf.theme().p.muted }))
            |> ignore
          })
          |> ignore
        })
        |> ignore
        cells(l, of, weight)
      })
      |> ignore
    })
    |> ignore
  }
  let across = @view.Scroll::across()
  let keys = Array::makei(body_n, fn(i) { i })
  parent.scrolls_window(
    @view.Scroll::list(),
    fn() { keys },
    fn(row, i) { line_of(row, across, "\{i + 1}", rows[i + 1], 400, false) },
    est=csv_row_h,
    slop=@ui.touch_slop(),
    bar=@ui.tree_scroll_bar(),
    head=fn(h) {
      h.box(fn(top) { top.height(By(fn() { Some(vw.stage_top_node(desk_table_top, 0.0)) })) |> ignore }) |> ignore
      h.box(fn(row) {
        row.ground(By(fn() { @sf.theme().p.canvas })) |> ignore
        line_of(row, across, "", head, 600, true)
      })
      |> ignore
      h.box(fn(line) { line.height(Is(Some(1.0))).ground(By(fn() { @sf.theme().p.line })) |> ignore }) |> ignore
    },
    foot=fn(f) {
      if more || cut {
        cut_line_node(f, fn() { pv_fill("android-chat.file.cut.rows", [("n", "\{table_rows}")]) })
      }
      f.box(fn(g) { g.height(Is(Some(csv_foot))) |> ignore }) |> ignore
    },
  )
  |> ignore
}

///|
/// A table's row as it is guessed before it is laid out (its cell's line, 8 over it and under it), its words' line as
/// a share of their size (18 at 13), and what is under its last row.
let csv_row_h : Double = 34.0

///|
let desk_cell_share : Double = 18.0 / 13.0

///|
let csv_foot : Double = 48.0
