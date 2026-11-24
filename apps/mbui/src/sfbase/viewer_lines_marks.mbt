// Picking and marking code or plain text shown in the viewer (lines_stage_node: StageLines, StageFlow, and Markdown's
// 源码). Its words are picked as any of the window's are (@ui.words_picked on the stage); each 60-line row says which
// row it is (@ui.picked_of with `code-row:<i`), so what is picked maps back to exact 1-based line numbers in the file.
// What is picked is copied, quoted into the chat's draft, or kept as a note marked on the lines (View::runs_marks),
// listed beside the code or behind a count at its foot (doc_notes_node.mbt). As a PDF's (viewer_pdf_marks.mbt) and a
// Markdown file's (viewer_md_marks.mbt), a note is a quote in the chat's draft from the moment it is made (role `file`,
// with `mark`: `lines:<path>|<name>|<size>\n<from>,<to>`), so it comes back when the file is opened again and goes when
// the draft lets it go or sends it.

///|
/// A note on lines of a code or text file: a quote of the chat's draft (`id`, the draft's), its 1-based line range, the
/// words picked and what was said of them.
#derive(Eq)
pub(all) struct LinesMark {
  id : String
  lines : (Int, Int)
  text : String
  comment : String
}

///|
/// What is marked in one viewer's code or text file.
pub(all) struct LinesMarks {
  /// the note being written (its quote's id; "" none)
  writing : @signals.Signal[String]
  note : @ui.Field
  /// what reaches the chat's draft the notes are in: the stage's, said as it is made
  mut src : Source?
  /// brings 1-based line `line` into sight near the stage's top: the stage's, said as it is made
  mut locate : (Int) -> Unit
  /// line count and line text of the file currently shown in lines_stage_node
  mut count : () -> Int
  mut line_at : (Int) -> String
}

///|
fn LinesMarks::new() -> LinesMarks {
  {
    writing: @signals.signal(""),
    note: @ui.Field::new(),
    src: None,
    locate: fn(_) {  },
    count: fn() { 0 },
    line_at: fn(_) { "" },
  }
}

///|
/// The `picked_of` owner key for 60-line row `i` in `lines_stage_node`.
fn lines_row_key(i : Int) -> String {
  "code-row:\{i}"
}

///|
/// Which 60-line row `key` names (`lines_row_key`); none where it is another's.
fn lines_row_of(key : String) -> Int? {
  let prefix = "code-row:"
  guard key.has_prefix(prefix) else { return None }
  match pdf_mark_ints(key, prefix.length()) {
    Some([i]) => Some(i)
    _ => None
  }
}

///|
/// Which 0-based line of the file code unit `at` of 60-line row `row`'s words is on (its lines joined by "\n", as
/// lines_stage_node shows them; a line's "\n" is its own), and whether `at` is that "\n" (the line's end).
fn lines_line_at(count : Int, line : (Int) -> String, row : Int, at : Int) -> (Int, Bool) {
  let from = md_max(0, row * lines_per_row)
  let to = md_min(count, from + lines_per_row)
  let mut start = 0
  for k in from..<to {
    let end = start + line(k).length()
    if at < end || k == to - 1 {
      return (k, false)
    }
    if at == end {
      return (k, true)
    }
    start = end + 1
  }
  (md_max(0, md_min(from, count - 1)), false)
}

///|
/// Exact 1-based `(line_start, line_end)` of what is picked: from code unit `first_at` of 60-line row `first_row`'s
/// words to code unit `last_at` (its end) of row `last_row`'s, in a file of `count` lines (`line(k)` is 0-based line
/// `k`). A pick begun on a line's "\n" begins on the next; one ended just past it ends on that line.
pub fn lines_span_of(
  count : Int,
  line : (Int) -> String,
  first_row : Int,
  first_at : Int,
  last_row : Int,
  last_at : Int,
) -> (Int, Int) {
  guard count > 0 else { return (1, 1) }
  let (l1, _) = lines_line_at(count, line, last_row, md_max(0, last_at - 1))
  let (k0, at_end) = lines_line_at(count, line, first_row, first_at)
  let l0 = if at_end && k0 < l1 { k0 + 1 } else { k0 }
  (md_min(l0, l1) + 1, l1 + 1)
}

///|
/// Where a line note's lines are, as its quote's `mark` keeps them after the file's prefix.
pub fn lines_mark_of(lines : (Int, Int)) -> String {
  "\{lines.0},\{lines.1}"
}

///|
/// What a line note's `mark` (from code unit `from`) says of its 1-based line range (`lines_mark_of`); none where it
/// says nothing that can be (another's, or damaged).
pub fn lines_where_of(mark : String, from? : Int = 0) -> (Int, Int)? {
  match pdf_mark_ints(mark, from) {
    Some([l0, l1]) if l0 >= 1 && l0 <= l1 => Some((l0, l1))
    _ => None
  }
}

///|
/// Who this viewer's file is among the draft's line notes: what starts each of its notes' `mark`.
fn Viewer::lines_mark_whose(self : Viewer) -> String {
  "lines:\{self.file.path}|\{self.file.name}|\{self.file.size}\n"
}

///|
/// The chat's draft the notes are in; none where the viewer is of no chat, or before its stage is made.
fn Viewer::lines_draft(self : Viewer) -> (Source, Writing)? {
  let key = self.draft_key()
  match self.lines_marks.src {
    Some(src) if key != "" => Some((src, writing(src, key)))
    _ => None
  }
}

///|
/// What is picked in the code/text stage's words, once the pointer has let it go: what @ui says of it and the first and
/// last 60-line row indices it spans; none where it is not wholly this stage's lines.
fn Viewer::lines_picked(self : Viewer) -> (@ui.WordsPicked, Int, Int)? {
  ignore(self)
  guard @ui.picked_now() is Some(p) && p.strays == 0 && p.of.length() > 0 && p.text.trim(chars=" \n\t") != "" else {
    return None
  }
  let mut lo = -1
  let mut hi = -1
  for of in p.of {
    guard lines_row_of(of) is Some(i) else { return None }
    if lo < 0 || i < lo {
      lo = i
    }
    if i > hi {
      hi = i
    }
  }
  Some((p, lo, hi))
}

///|
/// This file's line notes, as the chat's draft has them now (followed as it changes): its quotes whose `mark` is of
/// this file's lines; at most md_marks_most.
pub fn Viewer::lines_notes(self : Viewer) -> Array[LinesMark] {
  guard self.lines_draft() is Some((_, w)) else { return [] }
  let whose = self.lines_mark_whose()
  let out : Array[LinesMark] = []
  for q in w.quotes.get() {
    let mark = text(Some(q), "mark")
    guard text(Some(q), "role") == "file" && mark.has_prefix(whose) && out.length() < md_marks_most else { continue }
    match lines_where_of(mark, from=whose.length()) {
      Some(lines) =>
        out.push({
          id: text(Some(q), "id"),
          lines,
          text: text(Some(q), "text"),
          comment: text(Some(q), "comment"),
        })
      None => ()
    }
  }
  out
}

///|
/// What `p` says is picked (in rows `from_row`..=`to_row`) quoted into the draft at once with its 1-based line range,
/// and let go.
fn Viewer::lines_quote_picked(self : Viewer, p : @ui.WordsPicked, from_row : Int, to_row : Int) -> Unit {
  let words = p.text.trim(chars="\r\n").to_owned()
  let lines = lines_span_of((self.lines_marks.count)(), self.lines_marks.line_at, from_row, p.first_at, to_row, p.last_at)
  @ui.picked_let_go()
  self.md_give([md_quote(self.file.name, lines, "", words, "")])
}

///|
/// What `p` says is picked (in rows `from_row`..=`to_row`) kept as a note on its lines: a quote in the chat's draft at
/// once, its comment field focused; selection let go.
fn Viewer::lines_mark_picked(self : Viewer, p : @ui.WordsPicked, from_row : Int, to_row : Int) -> Unit {
  let m = self.lines_marks
  guard self.lines_draft() is Some((src, w)) && @signals.untracked(fn() { self.lines_notes() }).length() < md_marks_most else {
    return
  }
  self.lines_note_done()
  let words = p.text.trim(chars="\r\n").to_owned()
  let lines = lines_span_of((m.count)(), m.line_at, from_row, p.first_at, to_row, p.last_at)
  let (whose, said, _) = md_quote(self.file.name, lines, "", words, "")
  let mark = self.lines_mark_whose() + lines_mark_of(lines)
  writing_quote(src, w, {
    "author": Json::string(whose),
    "text": Json::string(said),
    "comment": Json::string(""),
    "role": Json::string("file"),
    "mark": Json::string(mark),
  })
  // (its comment line asks the composer for the focus; here the note's own field has it)
  writing_focused(src, w)
  let id = match @signals.untracked(fn() { w.quotes.get() }).iter().filter(fn(q) { text(Some(q), "mark") == mark }).last() {
    Some(q) => text(Some(q), "id")
    None => ""
  }
  @ui.picked_let_go()
  m.note.set("")
  m.writing.set(id)
  m.note.focus()
}

///|
/// The note being written, done: what it says becomes its quote's comment in the draft.
fn Viewer::lines_note_done(self : Viewer) -> Unit {
  let m = self.lines_marks
  let id = m.writing.untracked()
  guard id != "" else { return }
  let said = m.note.take().trim(chars=" \n\t").to_owned()
  match self.lines_draft() {
    Some((src, w)) if @signals.untracked(fn() { self.lines_notes() }).iter().any(fn(x) { x.id == id && x.comment != said }) =>
      writing_comment(src, w, id, said)
    _ => ()
  }
  m.writing.set("")
  m.note.let_go()
}

///|
/// Note `id` taken off the lines: its quote out of the draft (the one being written closed with it).
fn Viewer::lines_note_drop(self : Viewer, id : String) -> Unit {
  let m = self.lines_marks
  if m.writing.untracked() == id {
    m.note.set("")
    m.writing.set("")
    m.note.let_go()
  }
  match self.lines_draft() {
    Some((src, w)) => writing_unquote(src, w, id)
    None => ()
  }
}

///|
/// Note `id` opened: its first line scrolled into sight and opened to be written, what was said of it in the field.
fn Viewer::lines_note_open(self : Viewer, id : String) -> Unit {
  let m = self.lines_marks
  guard @signals.untracked(fn() { self.lines_notes() }).iter().find_first(fn(x) { x.id == id }) is Some(x) else { return }
  self.lines_note_done()
  (m.locate)(x.lines.0)
  m.note.set(x.comment)
  m.writing.set(id)
  m.note.focus()
}

///|
/// A tap on the stage ground while a note is being written: finish the note instead of toggling the viewer's bars.
fn Viewer::lines_tapped(self : Viewer) -> Bool {
  guard self.lines_marks.writing.untracked() != "" else { return false }
  self.lines_note_done()
  true
}

///|
/// Every line note of this file off the lines and out of the draft.
fn Viewer::lines_marks_cleared(self : Viewer) -> Unit {
  for x in @signals.untracked(fn() { self.lines_notes() }) {
    self.lines_note_drop(x.id)
  }
}

///|
/// The notes are in the draft already: save the one being written and return focus to the chat composer.
fn Viewer::lines_marks_sent(self : Viewer) -> Unit {
  self.lines_note_done()
  match self.lines_draft() {
    Some((_, w)) => w.field.focus()
    None => ()
  }
  if !self.beside {
    self.shut_tree()
  }
}

///|
/// Escape key in the code/text viewer: release active selection, else finish the note being written.
fn Viewer::lines_key(self : Viewer, code : Int, mods : Int) -> Bool {
  guard code == @ui.key_escape && mods == 0 else { return false }
  if @signals.untracked(fn() { self.lines_picked() }) is Some(_) {
    @ui.picked_let_go()
    return true
  }
  if self.lines_marks.writing.untracked() != "" {
    self.lines_note_done()
    return true
  }
  false
}

///|
/// Highlight marks (`View::runs_marks`) for 60-line row covering 0-based lines `from..<to`.
pub fn Viewer::lines_row_marks(
  self : Viewer,
  from : Int,
  to : Int,
  line : (Int) -> String,
) -> Array[@view.RunsMark] {
  let notes = self.lines_notes()
  if notes.is_empty() || from >= to {
    return []
  }
  let open = self.lines_marks.writing.get()
  let mut any = false
  for x in notes {
    if x.lines.0 <= to && x.lines.1 >= from + 1 {
      any = true
      break
    }
  }
  if !any {
    return []
  }
  // Compute code-unit start offset of each line in this row's joined text.
  let starts : Array[Int] = []
  let ends : Array[Int] = []
  let mut off = 0
  for k in from..<to {
    if k > from {
      off += 1
    }
    let s = line(k)
    starts.push(off)
    off += s.length()
    ends.push(off)
  }
  let out : Array[@view.RunsMark] = []
  for x in notes {
    if x.lines.0 <= to && x.lines.1 >= from + 1 {
      let lo = md_max(from, x.lines.0 - 1) - from
      let hi = md_min(to - 1, x.lines.1 - 1) - from
      let a = starts[lo]
      let b = ends[hi]
      if b > a {
        // (light: a ground faint enough that code's own colours keep 4.5:1 on it, its orange the least: 0.24 left it
        // 4.43:1; dark: any yellow under code's mid-tone colours takes them under 4.5:1, so a line under them instead)
        let mark : @view.RunsMark = if @sf.theme().dark {
          let line_w = if x.id == open { 2.5 } else { 1.5 }
          { from: a, to: b, ground: 0L, line: md_mark_ground, line_w, round: 0.0, starts: true, ends: true }
        } else {
          let ground = @sf.alpha(md_mark_ground, if x.id == open { 0.16 } else { 0.1 })
          { from: a, to: b, ground, line: 0L, line_w: 0.0, round: 3.0, starts: x.lines.0 >= from + 1, ends: x.lines.1 <= to }
        }
        out.push(mark)
      }
    }
  }
  out
}

///|
/// This file's line notes as the viewer lists them (doc_notes_node.mbt).
fn Viewer::lines_doc_notes(self : Viewer) -> DocNotes {
  let m = self.lines_marks
  {
    notes: fn() {
      self.lines_notes().map(fn(x) { { id: x.id, place: md_lines_label(x.lines), excerpt: x.text, comment: x.comment } })
    },
    current: fn() { m.writing.get() },
    field: m.note,
    done: fn() { self.lines_note_done() },
    open: fn(id) { self.lines_note_open(id) },
    remove: fn(id) { self.lines_note_drop(id) },
    send: fn() { self.lines_marks_sent() },
    clear: fn() { self.lines_marks_cleared() },
  }
}

///|
/// Over words picked in the code/text stage (`stage` holds `@ui.words_picked`), show 引用, 批注 (where the viewer has
/// a chat draft) and 复制 right beside where the selection ends.
fn lines_pick_bar_node(stage : @view.View, vw : Viewer) -> Unit {
  @ui.picked_bar(stage) |> ignore
  let host = match (@sf.window_tips().layer)() {
    Some(l) => l.box(fn(h) { h.over(Is(true)) |> ignore }).lives_with(stage)
    None => stage
  }
  host.pick(fn() { vw.lines_picked().map(fn(q) { q.0.made }) }, fn(holds, made) {
    guard made is Some(_) && @signals.untracked(fn() { vw.lines_picked() }) is Some((p, from_row, to_row)) else { return }
    guard @ui.view_tree().bind(fn(tree) { tree.view_of(p.ends_in) }) is Some(end) else { return }
    let items : Array[@sf.PickBarItem] = []
    if vw.draft_key() != "" {
      items.push({
        label: @sf.t("web-main.chat.quote"),
        icon: if p.ends_at_start { "quote-open" } else { "quote" },
        mark: false,
        press: fn() { vw.lines_quote_picked(p, from_row, to_row) },
      })
      if vw.lines_notes().length() < md_marks_most {
        items.push({
          label: pv("android-chat.pdf.mark"),
          icon: "edit",
          mark: false,
          press: fn() { vw.lines_mark_picked(p, from_row, to_row) },
        })
      }
    }
    items.push({
      label: @sf.t("common.copy"),
      icon: "copy",
      mark: false,
      press: fn() {
        copy_out(p.text, said=pv("android-chat.annotate.copied"))
        @ui.picked_let_go()
      },
    })
    holds.box(fn(b) {
      let gone = fn() {
        if @signals.untracked(@ui.picked_now) is Some(q) && q.made == p.made {
          @ui.picked_let_go()
        }
      }
      b.owns(end.owns_while(gone)) |> ignore
      end.on_reused(gone)
      @ui.keeps_picked(b).beside(p.ends_in, side=Top, offset=md_pick_bar_over, piece=@ui.picked_end_piece(p)) |> ignore
      @sf.pick_bar_node(b, items) |> ignore
    })
    |> ignore
  })
}

///|
/// Right-aligned line numbers `from + 1` .. `to` (padded to `digits` characters) for the code gutter.
pub fn lines_gutter_text(from : Int, to : Int, digits : Int) -> String {
  let sb = StringBuilder()
  for k in from..<to {
    if k > from {
      sb.write_char('\n')
    }
    let s = "\{k + 1}"
    let mut pad = digits - s.length()
    while pad > 0 {
      sb.write_char('\u2007')
      pad -= 1
    }
    sb.write_string(s)
  }
  sb.to_string()
}
