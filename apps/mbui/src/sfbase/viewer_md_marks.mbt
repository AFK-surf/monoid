// Picking and marking a Markdown file read in the viewer's reader (@sf.reader_node). Its words are picked as any of the
// window's are (@ui.words_picked on the stage); each of the reader's blocks says which it is (@sf.reader_block_key), so
// what is picked is found in the file's own text (the reader's Book: its blocks' starts), down to the lines it is on.
// What is picked is copied, quoted into the chat's draft, or kept as a note marked on the words (@sf.reader_marks),
// listed beside the reader or behind a count at its foot (doc_notes_node.mbt). As a PDF's (viewer_pdf_marks.mbt), a note
// is a quote in the chat's draft from the moment it is made (role `file`, with `mark`: this file and where in it), saying
// the file, its lines and the heading they are under, the words and what is said of them; the draft is all there is of
// it, so it is there again when the file is opened again, and gone when the draft lets it go or sends it.

///|
/// A note on the words: a quote of the chat's draft (`id`, the draft's) of them: the blocks they are in, where in the
/// file they start (an offset of its text), their lines, the heading they are under, the words and what is said of them.
#derive(Eq)
pub(all) struct MdMark {
  id : String
  blocks : (Int, Int)
  at : Int
  lines : (Int, Int)
  section : String
  text : String
  comment : String
}

///|
/// What is marked in one viewer's Markdown file.
pub(all) struct MdMarks {
  /// the note being written (its quote's id; "" none)
  writing : @signals.Signal[String]
  note : @ui.Field
  /// what reaches the chat's draft the notes are in: the stage's, said as it is made
  mut src : Source?
  /// whether the reader's phone bars show, and to show or take them away (ReaderMarks' bars: none till it is made)
  mut bars_on : () -> Bool
  mut bars_set : (Bool) -> Unit
}

///|
fn MdMarks::new() -> MdMarks {
  { writing: @signals.signal(""), note: @ui.Field::new(), src: None, bars_on: fn() { false }, bars_set: fn(_) {  } }
}

///|
/// How many notes a message can carry: as many quotes as the station takes.
let md_marks_most : Int = 20

///|
/// The ground a kept note's words are marked on, and the one being written's.
let md_mark_ground : Int64 = 0xF5C518FFL

///|
let md_mark_kept : Double = 0.32

///|
let md_mark_open : Double = 0.55

///|
/// How many of a line's first or last characters are looked for in the file to find where it is: as many as the first
/// says, else fewer.
fn md_probe_chars() -> Array[Int] {
  [8, 4, 2]
}

///|
/// Where line `line`'s first characters (its last: `last`) are in `text` from `from` up to `to`, and how long what was
/// found is; as many of them as are found of md_probe_chars, none where none are.
fn md_probe(text : String, line : String, last : Bool, from : Int, to : Int) -> (Int, Int)? {
  for n in md_probe_chars() {
    let probe = md_chars(line, n, last)
    match md_find(text, probe, from, to) {
      Some(at) => return Some((at, probe.length()))
      None => ()
    }
  }
  None
}

///|
fn md_max(a : Int, b : Int) -> Int {
  if a > b {
    a
  } else {
    b
  }
}

///|
fn md_min(a : Int, b : Int) -> Int {
  if a < b {
    a
  } else {
    b
  }
}

///|
/// Where `probe` is in `text` from `from` up to `to` (code units), none where it is not.
fn md_find(text : String, probe : String, from : Int, to : Int) -> Int? {
  let n = probe.length()
  guard n > 0 else { return None }
  let mut i = md_max(0, from)
  let end = md_min(to, text.length()) - n
  while i <= end {
    let mut j = 0
    while j < n && text.unsafe_get(i + j) == probe.unsafe_get(j) {
      j += 1
    }
    if j == n {
      return Some(i)
    }
    i += 1
  }
  None
}

///|
/// The line of `text` (from 1) offset `at` is on.
fn md_line_at(text : String, at : Int) -> Int {
  let mut n = 1
  let end = md_min(at, text.length())
  for i in 0..<end {
    if text.unsafe_get(i).to_int() == 10 {
      n += 1
    }
  }
  n
}

///|
/// The first `n` characters of `s`, or its last.
fn md_chars(s : String, n : Int, last : Bool) -> String {
  let cs = s.to_array()
  if cs.length() <= n {
    s
  } else if last {
    String::from_array(cs[cs.length() - n:])
  } else {
    String::from_array(cs[:n])
  }
}

///|
/// Where words picked across blocks `from` to `to` of a file's text are in it: their start (an offset) and the lines they
/// begin and end on. The first picked line is looked for by its first characters in those blocks' text, the last by its
/// last characters after it: fewer of them where more are not found (the reader shows words without the marks round
/// them in the file: `**新的**` as 新的); where none are, the blocks' own edge stands for it.
pub fn md_place_of(text : String, starts : Array[Int], from : Int, to : Int, words : String) -> (Int, Int, Int) {
  guard starts.length() > 0 else { return (0, 1, 1) }
  let k0 = md_max(0, md_min(from, starts.length() - 1))
  let k1 = md_max(k0, md_min(to, starts.length() - 1))
  let a = starts[k0]
  let b = if k1 + 1 < starts.length() { starts[k1 + 1] } else { text.length() }
  let lines = words.split("\n").map(fn(l) { l.trim(chars=" \t\r").to_owned() }).filter(fn(l) { l != "" }).collect()
  let first = match lines.get(0) {
    Some(l) => md_probe(text, l, false, a, b).map(fn(f) { f.0 }).unwrap_or(a)
    None => a
  }
  let last = match lines.last() {
    Some(l) =>
      match md_probe(text, l, true, first, b) {
        Some((at, n)) => at + n - 1
        None => md_max(first, b - 1)
      }
    None => md_max(first, b - 1)
  }
  (first, md_line_at(text, first), md_line_at(text, last))
}

///|
/// The heading offset `at` of the file is under (a chapter of the reader's: levels 1 to 3), "" before the first.
fn md_section_at(book : @sf.Book, at : Int) -> String {
  let mut said = ""
  for ch in book.chapters {
    let (title, k, off) = ch
    let start = (if k >= 0 && k < book.starts.length() { book.starts[k] } else { 0 }) + off
    if start <= at {
      said = title
    }
  }
  said
}

///|
/// The book the viewer's reader has read of its file, once it has.
fn Viewer::md_book(self : Viewer) -> @sf.Book? {
  @sf.reading_for(self.read_key()).book.untracked()
}

///|
/// What is picked in the reader's words, once the pointer has let it go: what @ui says of it and the blocks it is in
/// (the first and the last); none where it is not wholly the reader's.
fn Viewer::md_picked(self : Viewer) -> (@ui.WordsPicked, Int, Int)? {
  ignore(self)
  guard @ui.picked_now() is Some(p) && p.strays == 0 && p.of.length() > 0 && p.text.trim(chars=" \n\t") != "" else {
    return None
  }
  let mut lo = -1
  let mut hi = -1
  for of in p.of {
    guard @sf.reader_block_of(of) is Some(k) else { return None }
    if lo < 0 || k < lo {
      lo = k
    }
    if k > hi {
      hi = k
    }
  }
  Some((p, lo, hi))
}

///|
/// Where words picked in blocks `from` to `to` are, as a note of them keeps it: their start, their lines, their heading.
fn Viewer::md_where(self : Viewer, from : Int, to : Int, words : String) -> (Int, (Int, Int), String) {
  match self.md_book() {
    Some(b) => {
      let (at, l0, l1) = md_place_of(b.text, b.starts, from, to, words)
      (at, (l0, l1), md_section_at(b, at))
    }
    None => (0, (1, 1), "")
  }
}

///|
/// Where lines `lines` are, as a list of notes says it.
fn md_lines_label(lines : (Int, Int)) -> String {
  if lines.0 == lines.1 {
    pv_fill("android-chat.md.note.line", [("line", "\{lines.0}")])
  } else {
    pv_fill("android-chat.md.note.lines", [("from", "\{lines.0}"), ("to", "\{lines.1}")])
  }
}

///|
/// A quote of lines `lines` (under heading `section`) of file `name`: whose (the file, its lines, its heading), what it
/// says, what was said of it.
pub fn md_quote(
  name : String,
  lines : (Int, Int),
  section : String,
  words : String,
  comment : String,
) -> (String, String, String) {
  let whose = if lines.0 == lines.1 {
    pv_fill("android-chat.md.quote.line", [("name", name), ("line", "\{lines.0}")])
  } else {
    pv_fill("android-chat.md.quote.lines", [("name", name), ("from", "\{lines.0}"), ("to", "\{lines.1}")])
  }
  (if section == "" { whose } else { whose + " · " + section }, words, comment)
}

///|
/// Quotes put into the chat's draft, each as said of a file shown in the viewer; a viewer over the whole window closes
/// back to the chat.
fn Viewer::md_give(self : Viewer, quotes : Array[(String, String, String)]) -> Unit {
  let key = self.draft_key()
  guard key != "" && !quotes.is_empty() else { return }
  draft_give(key, Marked(self.file.name, b"", quotes, "file"))
  if !self.beside {
    self.shut_tree()
  }
}

///|
/// What `p` says is picked (in blocks `from` to `to`) quoted into the draft at once, and let go.
fn Viewer::md_quote_picked(self : Viewer, p : @ui.WordsPicked, from : Int, to : Int) -> Unit {
  let words = p.text.trim(chars=" \n\t").to_owned()
  let (_, lines, section) = self.md_where(from, to, words)
  @ui.picked_let_go()
  self.md_give([md_quote(self.file.name, lines, section, words, "")])
}

///|
/// Where a note of words in blocks `blocks`, starting at `at`, on lines `lines`, under heading `section` is, as its
/// quote's `mark` keeps it after the file's (md_note_of reads it back).
pub fn md_mark_of(blocks : (Int, Int), at : Int, lines : (Int, Int), section : String) -> String {
  "\{blocks.0},\{blocks.1},\{at},\{lines.0},\{lines.1}\n\{section}"
}

///|
/// What a note's `mark` (from code unit `from`) says of where it is (md_mark_of): its blocks, start, lines and heading;
/// none where it says nothing that can be (another's, or damaged).
pub fn md_where_of(mark : String, from? : Int = 0) -> ((Int, Int), Int, (Int, Int), String)? {
  let mut end = from
  while end < mark.length() && mark.unsafe_get(end).to_int() != 10 {
    end += 1
  }
  guard end < mark.length() && pdf_mark_ints(mark, from, until=end) is Some(n) && n.length() == 5 && n[0] <= n[1] else {
    return None
  }
  Some(((n[0], n[1]), n[2], (n[3], n[4]), mark[end + 1:].to_owned()))
}

///|
/// Who this viewer's file is among the draft's notes: what starts each of its notes' `mark`.
fn Viewer::md_mark_whose(self : Viewer) -> String {
  "md:\{self.file.path}|\{self.file.name}|\{self.file.size}\n"
}

///|
/// The chat's draft the notes are in; none where the viewer is of no chat, or before its stage is made.
fn Viewer::md_draft(self : Viewer) -> (Source, Writing)? {
  let key = self.draft_key()
  match self.md_marks.src {
    Some(src) if key != "" => Some((src, writing(src, key)))
    _ => None
  }
}

///|
/// This file's notes, as the chat's draft has them now (followed as it changes): its quotes whose `mark` is of this
/// file and says where; at most md_marks_most.
pub fn Viewer::md_notes(self : Viewer) -> Array[MdMark] {
  guard self.md_draft() is Some((_, w)) else { return [] }
  let whose = self.md_mark_whose()
  let out : Array[MdMark] = []
  for q in w.quotes.get() {
    let mark = text(Some(q), "mark")
    guard text(Some(q), "role") == "file" && mark.has_prefix(whose) && out.length() < md_marks_most else { continue }
    match md_where_of(mark, from=whose.length()) {
      Some((blocks, at, lines, section)) =>
        out.push({
          id: text(Some(q), "id"),
          blocks,
          at,
          lines,
          section,
          text: text(Some(q), "text"),
          comment: text(Some(q), "comment"),
        })
      None => ()
    }
  }
  out
}

///|
/// What `p` says is picked (in blocks `from` to `to`) kept as a note on the words: a quote in the chat's draft at once,
/// its words to be written; let go.
fn Viewer::md_mark_picked(self : Viewer, p : @ui.WordsPicked, from : Int, to : Int) -> Unit {
  let m = self.md_marks
  guard self.md_draft() is Some((src, w)) && @signals.untracked(fn() { self.md_notes() }).length() < md_marks_most else {
    return
  }
  self.md_note_done()
  let words = p.text.trim(chars=" \n\t").to_owned()
  let (at, lines, section) = self.md_where(from, to, words)
  let (whose, said, _) = md_quote(self.file.name, lines, section, words, "")
  let mark = self.md_mark_whose() + md_mark_of((from, to), at, lines, section)
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
  // (the note's card at the reader's foot, its bars taken away so it is clear of them)
  (m.bars_set)(false)
  m.note.set("")
  m.writing.set(id)
  m.note.focus()
}

///|
/// The note being written, done: what it says its quote's comment in the draft.
fn Viewer::md_note_done(self : Viewer) -> Unit {
  let m = self.md_marks
  let id = m.writing.untracked()
  guard id != "" else { return }
  let said = m.note.take().trim(chars=" \n\t").to_owned()
  match self.md_draft() {
    Some((src, w)) if @signals.untracked(fn() { self.md_notes() }).iter().any(fn(x) { x.id == id && x.comment != said }) =>
      writing_comment(src, w, id, said)
    _ => ()
  }
  m.writing.set("")
  m.note.let_go()
}

///|
/// Note `id` taken off the words: its quote out of the draft (the one being written closed with it).
fn Viewer::md_note_drop(self : Viewer, id : String) -> Unit {
  let m = self.md_marks
  if m.writing.untracked() == id {
    m.note.set("")
    m.writing.set("")
    m.note.let_go()
  }
  match self.md_draft() {
    Some((src, w)) => writing_unquote(src, w, id)
    None => ()
  }
}

///|
/// Note `id` opened: its words brought into sight and opened to be written, what was said of it in the field.
fn Viewer::md_note_open(self : Viewer, id : String) -> Unit {
  let m = self.md_marks
  guard @signals.untracked(fn() { self.md_notes() }).iter().find_first(fn(x) { x.id == id }) is Some(x) else { return }
  self.md_note_done()
  match self.md_book() {
    Some(b) => {
      let (chunk, within) = b.at(x.at)
      @sf.reader_jump(@sf.reading_for(self.read_key()), chunk, within, lead=true)
    }
    None => ()
  }
  (m.bars_set)(false)
  m.note.set(x.comment)
  m.writing.set(id)
  m.note.focus()
}

///|
/// A tap on the reader's text: the note being written finished (taken: the reader's bars left as they are); else not
/// taken.
fn Viewer::md_tapped(self : Viewer) -> Bool {
  guard self.md_marks.writing.untracked() != "" else { return false }
  self.md_note_done()
  true
}

///|
/// Every note of this file off the words and out of the draft.
fn Viewer::md_marks_cleared(self : Viewer) -> Unit {
  for x in @signals.untracked(fn() { self.md_notes() }) {
    self.md_note_drop(x.id)
  }
}

///|
/// The notes are in the draft already: what is being written kept, and back to the chat to send them with what is
/// written there (a viewer over the whole window closed; one beside the chat, its composer there).
fn Viewer::md_marks_sent(self : Viewer) -> Unit {
  self.md_note_done()
  match self.md_draft() {
    Some((_, w)) => w.field.focus()
    None => ()
  }
  if !self.beside {
    self.shut_tree()
  }
}

///|
/// The passages marked on block `k` of the reader: each line of the notes on it, on the ground of a kept note's or the
/// one being written's.
pub fn Viewer::md_lits(self : Viewer, k : Int) -> Array[(String, Int64)] {
  let open = self.md_marks.writing.get()
  let out : Array[(String, Int64)] = []
  for x in self.md_notes() {
    if x.blocks.0 <= k && k <= x.blocks.1 {
      let ground = @sf.alpha(md_mark_ground, if x.id == open { md_mark_open } else { md_mark_kept })
      for l in x.text.split("\n") {
        let line = l.trim(chars=" \t\r").to_owned()
        if line != "" {
          out.push((line, ground))
        }
      }
    }
  }
  out
}

///|
/// This file's notes as the viewer lists them (doc_notes_node.mbt).
fn Viewer::md_doc_notes(self : Viewer) -> DocNotes {
  let m = self.md_marks
  {
    notes: fn() {
      self
      .md_notes()
      .map(fn(x) {
        let place = md_lines_label(x.lines)
        { id: x.id, place: if x.section == "" { place } else { place + " · " + x.section }, excerpt: x.text, comment: x.comment }
      })
    },
    current: fn() { m.writing.get() },
    field: m.note,
    done: fn() { self.md_note_done() },
    open: fn(id) { self.md_note_open(id) },
    remove: fn(id) { self.md_note_drop(id) },
    send: fn() { self.md_marks_sent() },
    clear: fn() { self.md_marks_cleared() },
  }
}

///|
/// How far over where a pick ends its bar stands.
let md_pick_bar_over : Double = 12.0

///|
/// Over words picked in the reader that `stage` holds (its words picked with the pointer: @ui.words_picked), what can be
/// done with them beside where they end: 引用 and 批注 (where the viewer has a chat to put them in), 复制. A finger's pick
/// has this bar, not the system's text menu (@ui.picked_bar). In the layer over the window, clear of the reader's list.
fn md_pick_bar_node(stage : @view.View, vw : Viewer) -> Unit {
  @ui.picked_bar(stage) |> ignore
  let host = match (@sf.window_tips().layer)() {
    Some(l) => l.box(fn(h) { h.over(Is(true)) |> ignore }).lives_with(stage)
    None => stage
  }
  host.pick(fn() { vw.md_picked().map(fn(q) { q.0.made }) }, fn(holds, made) {
    guard made is Some(_) && @signals.untracked(fn() { vw.md_picked() }) is Some((p, from, to)) else { return }
    guard @ui.view_tree().bind(fn(tree) { tree.view_of(p.ends_in) }) is Some(end) else { return }
    let items : Array[@sf.PickBarItem] = []
    if vw.draft_key() != "" {
      items.push({
        label: @sf.t("web-main.chat.quote"),
        icon: if p.ends_at_start { "quote-open" } else { "quote" },
        mark: false,
        press: fn() { vw.md_quote_picked(p, from, to) },
      })
      if vw.md_notes().length() < md_marks_most {
        items.push({
          label: pv("android-chat.pdf.mark"),
          icon: "edit",
          mark: false,
          press: fn() { vw.md_mark_picked(p, from, to) },
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
      // (gone with the words it ends in: put by as the list moves on, or taken for another block's)
      let gone = fn() {
        if @signals.untracked(@ui.picked_now) is Some(q) && q.made == p.made {
          @ui.picked_let_go()
        }
      }
      b.owns(end.owns_while(gone)) |> ignore
      end.on_reused(gone)
      @ui.keeps_picked(b)
      .beside(p.ends_in, side=Top, offset=md_pick_bar_over, piece=@ui.picked_end_piece(p), while_seen=true)
      |> ignore
      @sf.pick_bar_node(b, items) |> ignore
    })
    |> ignore
  })
}
