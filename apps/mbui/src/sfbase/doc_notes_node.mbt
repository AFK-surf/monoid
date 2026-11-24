// The notes kept on a document in the viewer, listed: at the stage's side where it is wide enough (a column of cards
// beside the pages, as a word processor's comments stand), else behind a count at its foot that opens them in a sheet
// (a panel: a sheet from the foot on a phone), so the pages keep their width to read. What a note is of, where it is
// and how it is opened, taken off or sent are the document's (DocNotes): this knows nothing of a PDF's pages, so
// another kind of document kept in the viewer lists its notes the same way.

///|
/// One note as it is listed: where it is (`place`: a page), what it is of (`excerpt`: the words picked, or what an
/// area is), what was said of it ("" nothing yet).
#derive(Eq)
pub(all) struct DocNote {
  id : String
  place : String
  excerpt : String
  comment : String
}

///|
/// A document's notes and what can be done with them: `notes` and `current` are read as signals (the note being
/// written or opened, "" none); `open` brings a note into sight and opens it to be written; `remove` takes it off;
/// `send` puts all of them into the chat's draft; `clear` takes all of them off.
pub(all) struct DocNotes {
  notes : () -> Array[DocNote]
  current : () -> String
  open : (String) -> Unit
  remove : (String) -> Unit
  send : () -> Unit
  clear : () -> Unit
}

///|
/// How wide the column of notes is at the stage's side.
pub let doc_notes_side_w : Double = 300.0

///|
/// How wide the stage is at least for the notes to stand at its side, the pages narrowed for them.
pub let doc_notes_side_least : Double = 900.0

///|
/// The room the column takes from the pages: its width and the gaps round it.
pub let doc_notes_side_room : Double = 324.0

///|
/// Whether the notes stand at the side of a stage `width` wide: there are some and there is room.
pub fn doc_notes_side(width : Double, count : Int) -> Bool {
  count > 0 && width >= doc_notes_side_least
}

///|
/// The notes as rows in `v`: where each is, what it is of (two lines at most) and what was said of it; a press on
/// one opens it (`opened` first, a sheet closing), its bin takes it off. The one open stands out.
pub fn doc_notes_list_node(v : @view.View, of : DocNotes, opened : () -> Unit) -> Unit {
  v.gap(Is(6.0)) |> ignore
  v.each(of.notes, fn(n) { n.id }, fn(row, n) {
    row.row(Is(true)).lines_up(Is(Some(Start))).gap(Is(2.0)) |> ignore
    @sf.action_box_node(
      row,
      fn() { n.get().place + " " + n.get().excerpt },
      fn(_) {
        // (the sheet let go of first: going, it gives the focus back to what opened it, unless the note has it)
        opened()
        (of.open)(n.get().id)
      },
      fn(b) {
        b
        .grow(Is(1.0))
        .basis(Is(Some(0.0)))
        .shrink(Is(1.0))
        .radius(Is(@sf.row_corner))
        .padding(Is((10.0, 8.0, 6.0, 8.0)))
        .gap(Is(4.0))
        .ground(By(fn() { if (of.current)() == n.get().id { @sf.alpha(0xF5C518FFL, 0.22) } else { 0L } }))
        |> ignore
        @sf.hover_ground_node(b)
        doc_note_line(b, fn() { n.get().place }, 12.0, 600, 1, fn() { @sf.theme().p.muted })
        doc_note_line(b, fn() { n.get().excerpt }, 13.0, 400, 2, fn() { @sf.theme().p.muted })
        doc_note_line(
          b,
          fn() { if n.get().comment == "" { pv("android-chat.pdf.note.empty") } else { n.get().comment } },
          14.0,
          500,
          4,
          fn() { if n.get().comment == "" { @sf.theme().p.muted } else { @sf.theme().p.text } },
        )
      },
    )
    |> ignore
    note_key_node(row, "trash", 16.0, 0L, @sf.theme().p.muted, pv("android-chat.annotate.remove"), fn() {
      (of.remove)(n.get().id)
    })
  },
  at_once=true,
  )
}

///|
/// A line of a note's row: its words `size` big, `weight` heavy, `lines` at most, in `ink`.
fn doc_note_line(b : @view.View, words : () -> String, size : Double, weight : Int, lines : Int, ink : () -> Int64) -> Unit {
  b.box(fn(t) {
    t
    .words(By(words))
    .words_look(Is({
      size,
      weight,
      line: @ui.tree_theme().text_line * size,
      wrap: true,
      tracking: @view.letters_own,
      balance: false,
      max_lines: lines,
    }))
    .ink(By(ink))
    .allow_ellipsis(Is(true))
    |> ignore
  })
  |> ignore
}

///|
/// The notes at the side of `parent` (the stage) while `shown()`: a column `doc_notes_side_w` wide, `top()` under the
/// stage's top and clear of its foot by `foot()`; its head says how many, its rows scroll, its foot clears or sends
/// them all.
pub fn doc_notes_side_node(parent : @view.View, of : DocNotes, shown : () -> Bool, top : () -> Double, foot : () -> Double) -> Unit {
  parent.show(shown, fn(l) {
    l.over(Is(true)).row(Is(true)).padding(By(fn() { (0.0, top(), 12.0, foot()) })) |> ignore
    l.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
    l.box(fn(p) {
      p
      .width(Is(Some(doc_notes_side_w)))
      .radius(Is(14.0))
      .ground(By(fn() { @sf.panel_ground() }))
      .edge(By(fn() { (@sf.control_edge_w, @sf.theme().p.line) }))
      .shadow(By(fn() { @sf.glass_control_shadow() }))
      .padding(Is((8.0, 12.0, 8.0, 10.0)))
      .gap(Is(8.0))
      |> ignore
      doc_note_line(p, fn() { pv_fill("android-chat.pdf.notes.count", [("n", "\{(of.notes)().length()}")]) }, 15.0, 600, 1, fn() {
        @sf.theme().p.text
      })
      p.box(fn(s) {
        s.grow(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
        s.scrolls(@view.Scroll::new(), fn(c) { doc_notes_list_node(c, of, fn() {  }) }) |> ignore
      })
      |> ignore
      doc_notes_foot_keys(p, of, fn() {  })
    })
    |> ignore
  })
}

///|
/// 全部清除 and 发送 N 条标注 in a row in `v`, each then `after()` (a sheet closing).
fn doc_notes_foot_keys(v : @view.View, of : DocNotes, after : () -> Unit) -> Unit {
  v.box(fn(r) {
    r.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(8.0)) |> ignore
    @sf.button_node(r, fn() { pv("android-chat.pdf.marks.clear") }, fn() {
      (of.clear)()
      after()
    })
    |> ignore
    r.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
    @sf.button_node(
      r,
      fn() { pv_fill("android-chat.pdf.marks.send", [("n", "\{(of.notes)().length()}")]) },
      fn() {
        (of.send)()
        after()
      },
      tone=Primary,
    )
    |> ignore
  })
  |> ignore
}

///|
/// The notes in a panel of their own (a sheet from the foot on a phone): their rows, and at its foot 全部清除 and 发送;
/// a press on a row opens that note on the page, the panel closed.
pub fn doc_notes_sheet(of : DocNotes) -> Unit {
  @sf.panel_nodes(
    pv("android-chat.pdf.notes.title"),
    fn(v, close) { doc_notes_list_node(v, of, close) },
    from=Unanchored,
    foot=fn(v, close) { doc_notes_foot_keys(v, of, close) },
  )
}
