// A text file read as a book (zdrive's reader in still.fail's look): one
// column that scrolls, never pages. A plain-text novel hard-wrapped at a fixed width is joined back into its paragraphs,
// its chapters found and words found in it by the page's core (viewer_host.mbt read_book, search_book); Markdown is
// never reflowed, and is drawn as a chat's is (markdown.mbt). Where it was left is kept (viewer_file.mbt place,
// keep_place) and opened at.
//
// What it reads and where it is (Reading) is kept here; what draws it is nodes of the window's tree (reader_node.mbt).
// On 大屏 and 中屏: over the window, on its paper, the bar every file opened has
// (viewer_bar.mbt) on the paper and in its ink: back by name, the file's name, its chapter, how far read and its size,
// and 目录 · 搜索 · 排版 · 下载. The bar goes as the text is read on down and comes back as it is read back up, or as the
// pointer comes to the window's top. The text is one column as wide as a line reads well (34 of its size for a plain
// text, 48 for a Markdown document, and the margins), its tables out past it to the window's edge where they are wide
// (reader_sides' bleed), from 40 under the bar; a hairline along the foot says how far through it is. A panel docks at the right
// under the bar, 320 wide, on the paper with a line before it, the text kept clear of it: the contents (the chapters
// numbered, the one being read marked; finding in the whole text), the search (each place found, in a line of its
// text), the layout (the day's paper, the size, the lines, the margins, the face, the indent: nodes of the window's
// tree laid over the reader where the panel docks, reader_layout_node.mbt). ⌘F finds, ← → go from chapter to chapter,
// Esc closes what is open over the text (else goes back).
//
// On 小屏 it reads with the same column and state (reader_node's), its own bars over it.

///|
/// A paper: its ground, its ink, what is quieter, the raised ground of what floats over it, its
/// line, its accent, whether it is dark.
pub(all) struct ReaderPaper {
  ground : Int64
  ink : Int64
  muted : Int64
  raised : Int64
  line : Int64
  accent : Int64
  dark : Bool
}

///|
/// The paper shown: night while the app is dark, by day the light paper chosen (white until one
/// is).
pub fn reader_paper(chosen : String) -> ReaderPaper {
  if theme().dark {
    paper_by_key("night")
  } else {
    paper_by_key(day_paper_key(chosen))
  }
}

///|
/// The light paper a choice comes to: white until one of the three is picked.
fn day_paper_key(chosen : String) -> String {
  if chosen == "green" || chosen == "grey" {
    chosen
  } else {
    "white"
  }
}

///|
/// A paper by its key (PAPER, PAPER_BG): white the phone's warm page, 护眼 its green as a tint of it (13%), 浅灰 its ink
/// as one (8% over #FBFAF7), night its dark page (its ink #ECECED at 88%).
fn paper_by_key(key : String) -> ReaderPaper {
  match key {
    "night" => {
      let ground = paper_night_ground
      {
        ground,
        ink: mix(paper_night_ink, paper_night_ink_share, ground),
        muted: paper_night_muted,
        raised: paper_night_raised,
        line: paper_night_line,
        accent: paper_night_accent,
        dark: true,
      }
    }
    "green" =>
      {
        ground: mix(paper_green, paper_green_share, paper_white_ground),
        ink: paper_green_ink,
        muted: paper_light_muted,
        raised: mix(paper_green, paper_green_raised_share, paper_light_raised),
        line: paper_light_line,
        accent: paper_green,
        dark: false,
      }
    "grey" =>
      {
        ground: mix(paper_light_ink, paper_grey_share, paper_grey_base),
        ink: paper_light_ink,
        muted: paper_light_muted,
        raised: paper_light_raised,
        line: paper_light_line,
        accent: paper_light_accent,
        dark: false,
      }
    _ =>
      {
        ground: paper_white_ground,
        ink: paper_light_ink,
        muted: paper_light_muted,
        raised: paper_light_raised,
        line: paper_light_line,
        accent: paper_light_accent,
        dark: false,
      }
  }
}

///|
/// The bar's colours on the paper (-ink, -muted, -line); its buttons lit as the
/// page's are (the paper is night while the app is dark, a day's paper while it is light: reader_paper).
fn paper_viewer_ink(p : ReaderPaper) -> ViewerInk {
  let page = theme().p
  { ground: p.ground, ink: p.ink, muted: p.muted, line: p.line, hover: page.hover, chosen: page.selected }
}

///|
/// Where a reader is: a page of its own (the whole window's, a drive's), a tab beside a chat over the whole window or
/// in a window of its own, or a tab in the chat's panel (its column wider there: doc_column_ems, the panel bounding
/// it already).
#derive(Eq)
pub(all) enum ReaderHost {
  OwnPage
  Tab
  PanelTab
}

///|
/// A reader's panel: the contents, the search, the layout.
#derive(Eq)
pub(all) enum ReaderPanel {
  NoPanel
  Contents
  Find
  Layout
}

///|
/// A text being read: how it comes (how much so far), then the book and where it starts; where the reader is (a block
/// and how far down it the top of the screen is, a share of it), a phone's bars, a panel, the search, a jump on its way
/// (what its block marks for its list to bring: reader_jump), where it was last kept; a desktop's bar on its scroll.
/// What its nodes read are signals (reader_node.mbt); what it keeps only for its handlers plain fields.
pub(all) struct Reading {
  key : String
  /// the file as last given (where it was left is asked of it, and kept with it)
  mut file : ViewerFile?
  mut asked : Bool
  got : @signals.Signal[Got?]
  failed : @signals.Signal[String?]
  book : @signals.Signal[Book?]
  /// opened where it was left (or not waited on any longer: reader_place_ms): the column shown from then
  started : @signals.Signal[Bool]
  /// where the top of the screen is: a block, and how far down it (a share of its height)
  place : @signals.Signal[(Int, Double)]
  /// a phone's bars shown
  chrome : @signals.Signal[Bool]
  panel : @signals.Signal[ReaderPanel]
  query : @signals.Signal[String]
  /// what the search is typed into (its editor's Field: given the focus as the search's panel opens)
  search : @ui.Field
  /// what was looked for last, and the places it was found
  searched : @signals.Signal[String]
  matches : @signals.Signal[Array[TextMatch]]
  hit : @signals.Signal[Int]
  /// a jump: its block, the offset in it, whether a little before it shows too (reader_jump_lead): where its block
  /// marks what its list brings (View::sought)
  jump : @signals.Signal[(Int, Int, Bool)?]
  /// what asks the column's list to bring a block (ListPlace: a jump, where it was left)
  list : @view.ListPlace[Int]
  /// what asks the contents' list to bring a chapter, as they open (at the chapter read)
  contents : @view.ListPlace[Int]
  mut kept : Int
  /// the moves of the place (each a wait of its own till it is kept), the move last kept
  mut moves : Int
  mut kept_moves : Int
  /// where a jump put it (its block, how far into it by the text) and where the list stood as it came there (the first
  /// block in sight, how far down it; a block below 0, not yet told); a block below 0, none: the place it says till the
  /// list is moved off where it came (reader_jump)
  mut jumped : (Int, Double, Int, Double)
  /// where along the whole a phone's track is dragged (below 0: not)
  draft : @signals.Signal[Double]
  /// a desktop's bar, gone as the text is read on down (where the list stood when it was last seen: `seen`)
  bar_hidden : @signals.Signal[Bool]
  /// taller than two screens (what shows could scroll further than its own height): told with what is in sight
  long : @signals.Signal[Bool]
  /// further than reader_end_away from its end, told with what is in sight
  away : @signals.Signal[Bool]
  /// the moment the column's list was first in sight (none yet: +inf): what floats over it stands as found till then
  mut sight_from : Double
  mut seen : (Int, Double)
}

///|
/// The texts being read, by their key (kept while their page is open: reader_let_go).
// kept across runs: put back by readings_reset (viewer_reset), as a run begins (run_begin)
let readings : Map[String, Reading] = Map([])

///|
/// The text read as `key` (a new one the first time).
pub fn reading_for(key : String) -> Reading {
  match readings.get(key) {
    Some(r) => r
    None => {
      let r : Reading = {
        key,
        file: None,
        asked: false,
        got: @signals.signal(None),
        failed: @signals.signal(None),
        book: @signals.signal(None),
        started: @signals.signal(false),
        place: @signals.signal((0, 0.0)),
        chrome: @signals.signal(false),
        panel: @signals.signal(NoPanel),
        query: @signals.signal(""),
        search: @ui.Field::new(),
        searched: @signals.signal(""),
        matches: @signals.signal([]),
        hit: @signals.signal(-1),
        jump: @signals.signal(None),
        list: @view.ListPlace::new(),
        contents: @view.ListPlace::new(),
        kept: -1,
        moves: 0,
        kept_moves: 0,
        jumped: (-1, 0.0, -1, 0.0),
        draft: @signals.signal(-1.0),
        bar_hidden: @signals.signal(false),
        long: @signals.signal(false),
        away: @signals.signal(false),
        sight_from: @double.infinity,
        seen: (0, 0.0),
      }
      readings[key] = r
      panels_told.set(panels_told.untracked() + 1)
      r
    }
  }
}

///|
/// The page reading `key` left: where it was, kept (its file's keep_place), and what it read let go.
pub fn reader_let_go(key : String) -> Unit {
  match readings.get(key) {
    Some(r) => {
      match r.book.untracked() {
        Some(book) => reader_keep(r, book)
        None => ()
      }
      // (its layout's panel let go with it)
      reader_panel_set(r, NoPanel)
      readings.remove(key)
      panels_told.set(panels_told.untracked() + 1)
    }
    None => ()
  }
}

///|
/// Every text read let go of (the app begun again).
fn readings_reset() -> Unit {
  readings.clear()
  layout_open.set(None)
}

///|
/// Which panel the text read as `key` has open, followed: for a tab's tools that open them (reader_panel_toggle).
pub fn reader_panel_of(key : String) -> ReaderPanel {
  panels_told.get() |> ignore
  match readings.get(key) {
    Some(r) => r.panel.get()
    None => NoPanel
  }
}

///|
/// Reading `r` scrolled to its end, at a cause: clears any held jump so `on_sight` records the end.
fn reader_to_end(r : Reading) -> Unit {
  r.jumped = (-1, 0.0, -1, 0.0)
  r.list.to_end()
}

///|
/// The text read as `key` in a tab (reader_node's `beside`): `panel` opened from the tab's tools, or closed again by
/// the same tool (or the layout's own close), at the press's moment; the search's field given the keys as it opens. The
/// layout's is the tab's own (its stage lays it, reader_layout_docked), never the window's: layout_open is not told.
pub fn reader_panel_toggle(key : String, panel : ReaderPanel) -> Unit {
  let r = reading_for(key)
  if r.panel.untracked() == panel {
    r.panel.set(NoPanel)
    r.search.let_go()
    return
  }
  r.panel.set(panel)
  if panel == Find {
    r.search.focus()
  }
}

///|
/// The text whose layout's panel is open (its reading's key; None, none): what the window's tree lays it out by
/// (reader_layout_nodes), told as a reader's panel is opened or closed (reader_panel_set).
// kept across runs: put back by readings_reset (viewer_reset), as a run begins (run_begin)
let layout_open : @signals.Signal[String?] = @signals.signal(None)

///|
/// Told as a text is first read or let go (reading_for, reader_let_go): what shows which panel is open from outside
/// the reader (a tab's tools beside a chat, its stage's layout: reader_panel_of) follows which readings there are.
// kept across runs: only a count
let panels_told : @signals.Signal[Int] = @signals.signal(0)

///|
/// Reading `r`'s panel made `panel` (where it is the layout, what the window's tree lays out told so; its layout's
/// panel closed, told that), at a cause: as a tool opens it, Escape or its close closes it, or what opens a reader at
/// a panel (sffix's reader-layout) does.
pub fn reader_panel_set(r : Reading, panel : ReaderPanel) -> Unit {
  r.panel.set(panel)
  let open = layout_open.untracked()
  if panel == Layout {
    if open != Some(r.key) {
      layout_open.set(Some(r.key))
    }
  } else if open == Some(r.key) {
    layout_open.set(None)
  }
}

///|
/// The file read, once: its bytes here already, or read whole (at most reader_most, how much
/// has come told as it comes); decoded here, then read by the page's core as a reader shows it (read_book).
fn reader_load(r : Reading, file : ViewerFile, markdown : Bool) -> Unit {
  r.file = Some(file)
  if r.asked {
    return
  }
  r.asked = true
  match file.bytes {
    Some(b) => reader_build(r, file, b, markdown)
    None =>
      (file.read)(reader_most, fn(got) { r.got.set(Some(got)) }, fn(res) {
        match res {
          Ok(b) => reader_build(r, file, b, markdown)
          Err(e) => r.failed.set(Some(e))
        }
      })
  }
}

///|
/// The bytes come: decoded here (a file bigger than reader_most: its front, a character cut at its end no sign it is
/// not UTF-8), then read by the core.
fn reader_build(r : Reading, file : ViewerFile, bytes : Bytes, markdown : Bool) -> Unit {
  let cut = file.size > reader_most.to_double()
  let (decoded, encoding) = @hostapi.decode_text(bytes, truncated=cut)
  (viewer_host().read_book)(decoded, markdown, fn(res) {
    match res {
      Ok(read) => r.book.set(Some(book_of(file.name, read, encoding, cut, markdown)))
      Err(e) => r.failed.set(Some(e))
    }
  })
}

///|
/// Whether a text is a Markdown file's, by its name.
pub fn reads_as_markdown(name : String) -> Bool {
  let lower = name.to_lower()
  lower.has_suffix(".md") || lower.has_suffix(".markdown")
}

///|
/// Opened at `place` (where it was left on this device: its share, when the file has changed length since; none, from
/// its start), at a cause: the column shown from then, its list asked to bring the block it is in, the place at the
/// top of what shows (reader_start_node: as the book is ready and where it was left is said, or not waited on any
/// longer).
pub fn reader_open_at(r : Reading, book : Book, place : PlaceNow) -> Unit {
  if r.started.untracked() {
    return
  }
  match place {
    LeftAt(at, of) => {
      let length = book.length.to_double()
      let goes = if of > 0.0 && of != length { at / of * length } else { at }
      let start = dmin(goes, length).to_int()
      if start > 0 {
        let (k, off) = book.at(start)
        // (where it was left held as it was said till the list is moved off it, as a jump's is (reader_held_place):
        // its share the same however much of the column what covers its top takes)
        let within = if book.chunks[k].length() > 0 {
          off.to_double() / book.chunks[k].length().to_double()
        } else {
          0.0
        }
        r.jumped = (k, within, -1, 0.0)
        r.place.set((k, within))
        r.jump.set(Some((k, off, false)))
        r.list.bring_sought(k)
      }
    }
    NeverLeft | NotKnown => ()
  }
  r.started.set(true)
}

///|
/// Where it was left, kept with its file (the offset of the text, of its length): as the reader holds still, and as it
/// is left; told only where it is not where it was last kept (left where it last held still, nothing is told again).
fn reader_keep(r : Reading, book : Book) -> Unit {
  let (chunk, within) = r.place.untracked()
  let off = book.offset_of(chunk, within)
  if off == r.kept {
    return
  }
  r.kept = off
  r.kept_moves = r.moves
  match r.file {
    Some(f) => (f.keep_place)(off.to_double(), book.length.to_double())
    None => ()
  }
}

///|
/// How far through the whole text the place `at` is (a block and how far down it).
pub fn reader_fraction(book : Book, at : (Int, Double)) -> Double {
  if book.length <= 0 {
    return 0.0
  }
  dmin(1.0, dmax(0.0, book.offset_of(at.0, at.1).to_double() / book.length.to_double()))
}

///|
/// The chapter the place `at` (the top of the screen) is in (-1 before the first).
pub fn reader_chapter(book : Book, at : (Int, Double)) -> Int {
  let (chunk, within) = at
  let off = if chunk < book.chunks.length() {
    (book.chunks[chunk].length().to_double() * within).round().to_int()
  } else {
    0
  }
  let mut found = -1
  for i, ch in book.chapters {
    let (_, k, o) = ch
    if k < chunk || (k == chunk && o <= off) {
      found = i
    }
  }
  found
}

///|
/// The top of the screen to block `chunk`, `offset` into it, at a cause: what the block marks there brought by its
/// list (View::sought, ListPlace::bring_sought). `lead`, a place found (the search's): a little before it showing too
/// (reader_jump_lead); a chapter gone to is at the top itself, so it is the chapter read from then (reader_chapter).
pub fn reader_jump(r : Reading, chunk : Int, offset : Int, lead? : Bool = false) -> Unit {
  r.jump.set(Some((chunk, offset, true)))
  // (the place where it goes, by the text: what the list shows there is taken for it (reader_held_place) till it is
  // moved off, so the chapter gone to is the one read, whatever its block's lines are)
  let within = match r.book.untracked() {
    Some(b) if chunk >= 0 && chunk < b.chunks.length() && b.chunks[chunk].length() > 0 =>
      offset.to_double() / b.chunks[chunk].length().to_double()
    _ => 0.0
  }
  r.jumped = (chunk, within, -1, 0.0)
  r.place.set((chunk, within))
  r.list.bring_sought(chunk, under=if lead && offset > 0 { reader_jump_lead } else { 0.0 })
}

///|
/// The place the list shows (its first block in sight `first`, `into` it, `within` its share of it by height), as a
/// jump said it while the list stands where the jump left it (reader_jump's `jumped`), else as it shows.
fn reader_held_place(r : Reading, first : Int, into : Double, within : Double) -> (Int, Double) {
  let (jk, jw, at_first, at_into) = r.jumped
  if jk < 0 {
    (first, within)
  } else if r.list.asking() {
    // (told before the layout that does it, at the input that asked it: where it was, not where it goes)
    (jk, jw)
  } else if at_first < 0 {
    // (what is in sight first told once the layout did it: where it left the list, its block at the top, or the
    // list's end where the text ends before it can be)
    r.jumped = (jk, jw, first, into)
    (jk, jw)
  } else if first == at_first && (into - at_into).abs() < 0.5 {
    (jk, jw)
  } else {
    // (moved off it)
    r.jumped = (-1, 0.0, -1, 0.0)
    (first, within)
  }
}

///|
/// How long the reader holds still before where it is is kept (not on every pixel).
pub let reader_still_ms : Double = 800.0

///|
/// How long a phone's bars take to go (a tap on the text; they come in 140).
pub let reader_bars_ms : Double = 240.0

///|
/// The search goes this long after the last thing typed.
pub let reader_search_ms : Double = 250.0

///|
/// Where it was left on this device is waited on this long at most (no wait for a station).
pub let reader_place_ms : Double = 1000.0

///|
/// `query` looked for in the text (searchBook): the places it is, kept as long as it is still what was asked.
fn reader_search(r : Reading, book : Book, query : String) -> Unit {
  r.searched.set(query)
  r.hit.set(-1)
  (viewer_host().search_book)(book.id, query, fn(found) {
    if r.searched.untracked() == query {
      r.matches.set(
        found.map(fn(at) {
          let (k, o) = book.at(at)
          { chunk: k, start: o, length: query.length() }
        }),
      )
    }
  })
}

///|
/// A block's text as drawn: its paragraphs indented (Markdown: as long as its source, its share of it at its share of
/// the height).
fn reader_drawn_len(book : Book, k : Int, indent : Bool) -> Int {
  if book.markdown {
    book.chunks[k].length()
  } else {
    render_chunk(book.chunks[k], book.starts[k], book.heads, indent).length()
  }
}

///|
fn reader_drawn_offset(book : Book, k : Int, raw : Int, indent : Bool) -> Int {
  if book.markdown {
    raw
  } else {
    render_offset(book.chunks[k], book.starts[k], book.heads, raw, indent)
  }
}


///|
/// Runs with the places found's grounds put on (each one's drawn range).
fn reader_marked(
  runs : Array[@ui.Run],
  drawn : (Int) -> Int,
  marks : Array[TextMatch],
  now : TextMatch?,
  mark : Int64,
  mark_now : Int64,
) -> Array[@ui.Run] {
  // each drawn character's ground
  let ranges : Array[(Int, Int, Int64)] = marks.map(fn(m) {
    let hue = match now {
      Some(x) if x == m => mark_now
      _ => mark
    }
    (drawn(m.start), drawn(m.start + m.length), hue)
  })
  let out = []
  let mut at = 0
  for run in runs {
    let len = run.text.length()
    // cut where a range starts or ends inside it
    let cuts = [0, len]
    for g in ranges {
      if g.0 > at && g.0 < at + len {
        cuts.push(g.0 - at)
      }
      if g.1 > at && g.1 < at + len {
        cuts.push(g.1 - at)
      }
    }
    cuts.sort()
    for i in 0..<(cuts.length() - 1) {
      let a = cuts[i]
      let b = cuts[i + 1]
      if b <= a {
        continue
      }
      let mut bg = run.bg
      for g in ranges {
        if at + a >= g.0 && at + a < g.1 {
          bg = g.2
        }
      }
      out.push({ ..run, text: run.text.clamped_view(start=a, end=b).to_owned(), bg })
    }
    at += len
  }
  out
}

///|
/// A block's heading lines (where the core says the text's headings start) in 600 and a fifth larger, as drawn
/// (render_chunk's text: `runs`, one run of it).
fn reader_headings(runs : Array[@ui.Run], raw : String, start : Int, heads : Map[Int, Bool], indent : Bool) -> Array[@ui.Run] {
  // each heading's drawn range
  let ranges : Array[(Int, Int)] = []
  let n = raw.length()
  let mut index = 0
  while index < n {
    let newline = tx_nl(raw, index)
    let end = if newline < 0 { n } else { newline }
    if heads.contains(start + index) {
      let lead = tx_lead(raw, index, end)
      let from = render_offset(raw, start, heads, index + lead, indent)
      let to = render_offset(raw, start, heads, end, indent)
      if to > from {
        ranges.push((from, to))
      }
    }
    if newline < 0 {
      break
    }
    index = newline + 1
  }
  if ranges.length() == 0 {
    return runs
  }
  let out = []
  let mut at = 0
  for run in runs {
    let len = run.text.length()
    let cuts = [0, len]
    for g in ranges {
      if g.0 > at && g.0 < at + len {
        cuts.push(g.0 - at)
      }
      if g.1 > at && g.1 < at + len {
        cuts.push(g.1 - at)
      }
    }
    cuts.sort()
    for i in 0..<(cuts.length() - 1) {
      let a = cuts[i]
      let b = cuts[i + 1]
      if b <= a {
        continue
      }
      let heading = ranges.iter().any(fn(g) { at + a >= g.0 && at + a < g.1 })
      let text = run.text.clamped_view(start=a, end=b).to_owned()
      out.push(if heading { { ..run, text, weight: reader_heading_weight, scale: reader_heading_scale } } else { { ..run, text } })
    }
    at += len
  }
  out
}

///|
/// Where a place found is, in a line (Find's snippet): a little before it, it in the accent, a little after.
pub fn reader_snippet(chunk : String, m : TextMatch, accent : Int64) -> Array[@ui.Run] {
  let n = chunk.length()
  let from = if m.start - reader_snippet_before < 0 { 0 } else { m.start - reader_snippet_before }
  let end = if m.start + m.length < n { m.start + m.length } else { n }
  let to = if m.start + m.length + reader_snippet_after < n { m.start + m.length + reader_snippet_after } else { n }
  let clean = fn(s : String) { s.replace_all(old="\n", new=" ").replace_all(old="\u{3000}", new=" ") }
  [
    @ui.plain((if from > 0 { "…" } else { "" }) + clean(tx_sub(chunk, from, m.start))),
    @ui.span(clean(tx_sub(chunk, m.start, end)), weight=reader_heading_weight, color=accent),
    @ui.plain(clean(tx_sub(chunk, end, to)) + (if to < n { "…" } else { "" })),
  ]
}

///|
/// Words joined with `between`, the empty ones left out.
fn joined(words : Array[String], between : String) -> String {
  words.filter(fn(w) { w != "" }).join(between)
}

///|
/// The ⌘ of this machine's shortcuts (⌘ on a Mac, Ctrl elsewhere).
fn desk_mod() -> Int {
  if @ui.keys_system() == 0 {
    @ui.mod_cmd
  } else {
    @ui.mod_ctrl
  }
}

///|
/// The page's own colours, as a sheet over it is drawn on (the web's --m-* in a phone's sheet).
fn sheet_paper() -> ReaderPaper {
  let th = theme()
  { ground: th.p.canvas, ink: th.p.text, muted: th.p.muted, raised: th.p.raised, line: th.p.line, accent: th.p.accent, dark: th.dark }
}

///|
/// A phone's bars: their coming (140 ms; going reader_bars_ms), the step they take as they fade (6); the top one 8
/// under the page's top bar, 720 wide at most, 12 in from the sides; the foot one 12 over its foot, 560 at most; what
/// was found 56 lower while the top bar shows; the text 28 under the page's top and 72 over its foot.
let narrow_bars_in_ms : Double = 140.0

///|
let narrow_bars_step : Double = 6.0

///|
let narrow_bar_off : Double = 8.0

///|
let narrow_foot_off : Double = 12.0

///|
let narrow_bar_side : Double = 24.0

///|
let narrow_top_most : Double = 720.0

///|
let narrow_foot_most : Double = 560.0

///|
let narrow_found_down : Double = 56.0

///|
let narrow_reader_top : Double = 28.0

///|
let narrow_reader_foot : Double = 72.0

///|
/// The foot's room (the ladder's inset: what lies in its corners as far from both edges, concentric with it, round by
/// the next step), its tools 4 apart, a tool's ground the ink at 7% while on.
let narrow_foot_in : Double = corner_inset

///|
let narrow_tools_gap : Double = 4.0

///|
let narrow_tool_on : Double = 0.07

///|
/// The sheets' share of the page: the contents and the search 72%, the layout half.
let narrow_sheet_tall : Double = 0.72

///|
let narrow_sheet_half : Double = 0.5

///|
// kept across runs: a value (no field of it changes)
let narrow_bar_row : @ui.Style = @ui.css("row w=Full justify=JCenter")

///|
/// The top bar (top): 48 high, 6 in, a capsule (its round keys in the middle of its ends, 6 in, concentric with it:
/// 外圆角 = 距离 + 半高); its ends at least 64 (minmax(64px, auto)).
// kept across runs: a value (no field of it changes)
let narrow_top_box : @ui.Style = @ui.css("row h=S12 px=S1_5 align=ACenter radius=Full")

///|
// kept across runs: a value (no field of it changes)
let narrow_top_end : @ui.Style = @ui.css("row min_w=S16 align=ACenter")

///|
/// The way back (back): 36 high, at least as wide, 4 before the chevron and 10 after; 搜索 (topButton) 36 across; both
/// round, in the middle of the bar's capsule ends concentric with them.
// kept across runs: a value (no field of it changes)
let narrow_back_box : @ui.Style = @ui.css("row min_w=S9 h=S9 pl=S1 pr=S2_5 align=ACenter radius=Full hovered{bg=Tint}")

///|
/// 搜索's and 下载's side (narrow_top_button's S9), keys_gap apart.
let narrow_key_side : Double = 36.0

///|
// kept across runs: a value (no field of it changes)
let narrow_top_button : @ui.Style = @ui.css((
  #|w=S9 h=S9 align=ACenter justify=JCenter radius=Full hovered{bg=Tint} selected{bg=Tint}
))

///|
/// The name over its chapter and how far (title): the name in the page's ui size, 600; under it its caption, quiet.
// kept across runs: a value (no field of it changes)
let narrow_title_box : @ui.Style = @ui.style(w=grow, align=ACenter, clip=true)

///|
// kept across runs: a value (no field of it changes)
let narrow_title_words : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, wrap=false, narrow=@ui.text_patch(size=Lg))

///|
// kept across runs: a value (no field of it changes)
let narrow_title_small : @ui.TextStyle = @ui.text_style(size=Caption, wrap=false, narrow=@ui.text_patch(size=Xs))

///|
/// The foot (bottom): a card of the ladder's, what it holds the ladder's inset in (its chips in its corners concentric
/// with it), 8 between its rows; at its foot the page's.
// kept across runs: a value (no field of it changes)
let narrow_foot_place : @ui.Style = @ui.css("w=Full h=Full justify=JEnd")

///|
// kept across runs: a value (no field of it changes)
let narrow_foot_box : @ui.Style = @ui.css("gap=S2 radius=Xl3").then(@ui.style(p=room(narrow_foot_in)))

///|
/// The chapter's row (chapterRow): 上一章, its name, 下一章, 10 apart; in the foot's top corners (narrow_chip_past).
// kept across runs: a value (no field of it changes)
let narrow_chapter_row : @ui.Style = @ui.css("row w=Full gap=S2_5 align=ACenter").then(
  @ui.style(px=room(narrow_chip_past), pt=room(narrow_chip_past)),
)

///|
/// How far past the foot's padding its chapter's chips (30 high capsules) stand in its top corners: concentric with
/// its corner (a card's: capsule_in), what is at its foot (squarer buttons) the ladder's inset in, round by its next step.
let narrow_chip_past : Double = dmax(0.0, @ui.capsule_in(card_corner, 30.0) - corner_inset)

///|
// kept across runs: a value (no field of it changes)
let narrow_chapter_words : @ui.TextStyle = @ui.text_style(size=Meta, wrap=false, narrow=@ui.text_patch(size=Sm))

///|
/// The track and how far (trackRow): the track 28 high, 7 in from its ends; how far 40 wide, 10 apart.
// kept across runs: a value (no field of it changes)
let narrow_track_row : @ui.Style = @ui.css("row w=Full gap=S2_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let narrow_track_box : @ui.Style = @ui.style(w=grow, h=S7, px=S1_5, justify=JCenter)

///|
// kept across runs: a value (no field of it changes)
let narrow_percent_box : @ui.Style = @ui.css("w=S10 align=AEnd")

///|
// kept across runs: a value (no field of it changes)
let narrow_percent_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Semibold, wrap=false, narrow=@ui.text_patch(size=Sm))

///|
/// The tools (tools: three to a row, 4 apart): a tool 50 high, its icon over its name 3 apart.
// kept across runs: a value (no field of it changes)
let narrow_tools : @ui.Style = @ui.css("row w=Full gap=S1")

///|
// kept across runs: a value (no field of it changes)
let narrow_tool_box : @ui.Style = @ui.style(h=Fixed(narrow_tool_h), gap=S0_5, align=ACenter, justify=JCenter)

///|
let narrow_tool_h : Double = 50.0

///|
// kept across runs: a value (no field of it changes)
let narrow_tool_words : @ui.TextStyle = @ui.text_style(size=Caption, wrap=false, narrow=@ui.text_patch(size=Xs))

///|
/// A heading's (1.2 of the text's size).
let reader_heading_weight : Int = 600

///|
let reader_heading_scale : Double = 1.2

///|
/// A jump to a place found shows this much before it.
let reader_jump_lead : Double = 120.0

///|
/// A block's height guessed before it is laid out: as many lines as 1000 characters take at this width.
let reader_est_chars : Double = 1000.0

///|
/// What was found on the paper: the accent at 18% (28% on night), the one gone to at 42% (55%).
let reader_mark_light : Double = 0.18

///|
let reader_mark_dark : Double = 0.28

///|
let reader_mark_now_light : Double = 0.42

///|
let reader_mark_now_dark : Double = 0.55

///|
/// A snippet: this much before what was found, and after it.
let reader_snippet_before : Int = 18

///|
let reader_snippet_after : Int = 40




///|
/// A text cut says so under it (12, quiet).
// kept across runs: a value (no field of it changes)
let reader_cut_row : @ui.Style = @ui.css("row w=Full pt=S8")

///|
// kept across runs: a value (no field of it changes)
let reader_cut_words : @ui.TextStyle = @ui.text_style(size=Meta)

///|
/// The column's room above the text (the bar's 45 and 40) and under it (72), on a desktop.
let desk_reader_top : Double = 85.0

///|
let desk_reader_foot : Double = 72.0

///|
/// The column's width for a plain text (a novel's prose): 34 of the text's size (34em), its margins either side.
let desk_column_ems : Double = 34.0

///|
/// The column's width for a Markdown document (headings, lists, code, tables: a document's measure, never narrower
/// over the whole window than in the panel beside a chat) and for any text in a tab in that panel (the panel bounding
/// it already): 48 of the text's size.
let doc_column_ems : Double = 48.0

///|
/// A wide column (the layout's 宽, ReaderStyle's "wide"): a plain text's 48 of its size, a document's 64.
let wide_text_ems : Double = 48.0

///|
let wide_doc_ems : Double = 64.0

///|
/// How many of its size a column is wide (`doc`: a Markdown document's, or any text's in the panel beside a chat) by
/// the layout's width (`width`): "standard" a novel's 34 or a document's 48, "wide" 48 or 64, "full" none (as wide as
/// the row is, less the margins and a panel docked beside the text).
fn reader_column_ems(doc : Bool, width : String) -> Double? {
  match width {
    "full" => None
    "wide" => Some(if doc { wide_doc_ems } else { wide_text_ems })
    _ => Some(if doc { doc_column_ems } else { desk_column_ems })
  }
}

///|
/// How far from its end a reader's list is before its scroll-to-bottom float shows (matches a chat's to_newest_away:
/// a corner of the screen).
let reader_end_away : Double = 120.0

///|
/// How far in from a tab's right edge its floating buttons' drawn circles sit (a chat's float_in = 6 sits inside the
/// composer column; a tab has no composer).
let beside_float_in : Double = 16.0

///|
/// How far up from a tab's bottom edge the scroll-to-bottom floating button's drawn circle sits (a chat's float_lift =
/// 12 sits over the composer).
let beside_float_lift : Double = 16.0

///|
/// How long a tab's scroll-to-bottom floating button fades in and out (matches a chat's float_ms).
let beside_float_ms : Double = 160.0

///|
/// The panel's width (PANEL).
pub let desk_panel_w : Double = 320.0

///|
/// A note on the paper: 30% down, 24 in, 12 between, 12 and quiet; its progress 180 wide.
let desk_note_down : Double = 0.3

///|
// kept across runs: a value (no field of it changes)
let desk_note_box : @ui.Style = @ui.css("w=Full px=S6 gap=S3 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let desk_note_words : @ui.TextStyle = @ui.text_style(size=Meta, center=true)


///|
let desk_load_w : Double = 180.0

///|
/// The hairline: the ink at 14% (the line's step: what is drawn with nothing in it, contrast.mbt), how far read in the
/// accent at 70%.
let desk_hairline_share : Double = 0.14

///|
let desk_hairline_fill : Double = 0.7

///|
let desk_none : Double = 0.0

///|
let desk_whole : Double = 1.0

///|
/// What floats over the paper: its raised ground at 72%.
let desk_glass_share : Double = 0.72

///|
/// The contents opened at the chapter read, these few under the top.
let desk_contents_lead : Int = 3

///|
/// A row of the panel (panelRow: 10 and 12 in, 13 on 20); a hit's two lines of 13 on 1.5.
pub let desk_row_h : Double = 40.0

///|
let desk_hit_h : Double = 60.0

///|
let desk_hits_most : Int = 200

///|
let desk_row_icon : Double = 16.0

///|
pub let desk_check_icon : Double = 14.0

///|
/// The field (findInput): 14 on 20, its edge the ink at 18%.
let desk_field_size : Double = 14.0

///|
let desk_field_line_h : Double = 20.0

///|
let desk_field_line : Double = 0.18

///|
let narrow_field_size : Double = 16.0

///|
let narrow_field_line_h : Double = 22.0

///|
/// The size's row on the ink at 6%; the lines' and the margins' steps.
let desk_size_ground : Double = 0.06

///|
let desk_lines_step : Double = 0.1

///|
let desk_margin_step : Double = 1.0

///|
/// The face's and the indent's choices on a desktop: each half of the panel's room (280, less the track's 4).
let desk_seg_item : Double = 138.0

///|
/// The width's three choices on a desktop: each a third of the panel's room (280, less the track's 4).
let desk_seg_third : Double = 92.0

///|
/// A swatch's edge: the ink at 14% (2 of the accent on the one).
let desk_swatch_line : Double = 0.14

///|
/// The papers' colours (PAPER, PAPER_BG).
let paper_white_ground : Int64 = 0xF5F3EFFFL

///|
let paper_light_ink : Int64 = 0x24272BFFL

///|
let paper_light_muted : Int64 = 0x62656BFFL

///|
let paper_light_line : Int64 = 0xE7E3DCFFL

///|
let paper_light_accent : Int64 = 0xCC5A34FFL

///|
let paper_light_raised : Int64 = 0xFFFFFFFFL

///|
let paper_green : Int64 = 0x2F8F5BFFL

///|
let paper_green_ink : Int64 = 0x24302AFFL

///|
let paper_green_share : Double = 0.13

///|
let paper_green_raised_share : Double = 0.06

///|
let paper_grey_base : Int64 = 0xFBFAF7FFL

///|
let paper_grey_share : Double = 0.08

///|
let paper_night_ground : Int64 = 0x1B1C1FFFL

///|
let paper_night_ink : Int64 = 0xECECEDFFL

///|
let paper_night_ink_share : Double = 0.88

///|
let paper_night_muted : Int64 = 0xA4A7ADFFL

///|
let paper_night_raised : Int64 = 0x2A2C31FFL

///|
let paper_night_line : Int64 = 0x34353AFFL

///|
let paper_night_accent : Int64 = 0xE8734FFFL

///|
// kept across runs: a value (no field of it changes)
pub let desk_grow : @ui.Style = @ui.style(w=grow)

///|
// kept across runs: a value (no field of it changes)
pub let desk_grow_clip : @ui.Style = @ui.style(w=grow, clip=true)

///|
// kept across runs: a value (no field of it changes)
pub let desk_grow_middle : @ui.Style = @ui.style(w=grow, align=ACenter)




///|
let desk_found_gap : Double = 10.0

///|
// kept across runs: a value (no field of it changes)
let desk_found_box : @ui.Style = @ui.css("row min_h=S10 pl=S3_5 pr=S1_25 py=S1 gap=S1 align=ACenter radius=Xl1_5")

///|
// kept across runs: a value (no field of it changes)
let desk_found_words : @ui.TextStyle = @ui.text_style(size=Meta, wrap=false, narrow=@ui.text_patch(size=Sm))


///|
// kept across runs: a value (no field of it changes)
let desk_hairline : @ui.Style = @ui.css("row w=Full h=S0_5")

///|
// kept across runs: a value (no field of it changes)
fn desk_panel_top() -> @ui.Style {
  @ui.style(w=Full, h=Fixed(viewer_bar_under()))
}

///|
// kept across runs: a value (no field of it changes)
pub let desk_panel_row : @ui.Style = @ui.style(row=true, w=Full, h=grow)

///|
// kept across runs: a value (no field of it changes)
pub let desk_panel_room : @ui.Style = @ui.style(w=grow, h=Full)

///|
// kept across runs: a value (no field of it changes)
pub let desk_panel_box : @ui.Style = @ui.style(w=Fixed(desk_panel_inner), h=Full)

///|
/// The panel within its line (1 of its 320).
let desk_panel_inner : Double = desk_panel_w - 1.0

///|
/// Its head (panelHead): 12 over and right, 6 under, 18 at its start; the title 16 in 600.
// kept across runs: a value (no field of it changes)
let desk_panel_head : @ui.Style = @ui.css("row w=Full pl=S4_5 pr=S3 pt=S3 pb=S1_5 gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
pub let desk_panel_title : @ui.TextStyle = @ui.text_style(size=Title, weight=Semibold, wrap=false)

///|
// kept across runs: a value (no field of it changes)
pub let desk_panel_note : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, narrow=@ui.text_patch(size=Sm))

///|
// kept across runs: a value (no field of it changes)
let desk_panel_note_box : @ui.Style = @ui.css("w=Full px=S5 pt=S1_5 pb=S2_5")

///|
/// Its list (panelList): 8 in, 2 over, 12 under; a row (panelRow) 12 and 10 in, the page's option's corner.
// kept across runs: a value (no field of it changes)
pub let desk_panel_list : @ui.Style = @ui.style(w=Full, h=grow, px=S2, pb=S3)

///|
// kept across runs: a value (no field of it changes)
let desk_panel_list_top : @ui.Style = @ui.css("w=Full px=S2 pt=S0_5")


///|
// kept across runs: a value (no field of it changes)
let desk_row_words : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, wrap=false, narrow=@ui.text_patch(size=Lg))

///|
// kept across runs: a value (no field of it changes)
let desk_row_now : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=AccentText, leading=L6, wrap=false, narrow=@ui.text_patch(size=Lg))

///|
/// A chapter's number (chapterLine: its own 28, 11 and quiet).
// kept across runs: a value (no field of it changes)
pub let desk_chapter_number : @ui.Style = @ui.style(w=Fixed(desk_chapter_n_w))

///|
let desk_chapter_n_w : Double = 24.0

///|
// kept across runs: a value (no field of it changes)
pub let desk_chapter_n_words : @ui.TextStyle = @ui.text_style(size=Caption, wrap=false, narrow=@ui.text_patch(size=Xs))

///|
/// The field: 16 in from the panel's sides, 6 over and 8 under; 38 high, a pill, 16 in.
// kept across runs: a value (no field of it changes)
let desk_find_place : @ui.Style = @ui.css("w=Full px=S4 pt=S1_5 pb=S2")

///|
// kept across runs: a value (no field of it changes)
let desk_find_field : @ui.Style = @ui.style(w=Full, min_h=Fixed(desk_field_h), px=S4, py=S1, justify=JCenter, radius=Full, border=B0_5)

///|
let desk_field_h : Double = 38.0

///|
// kept across runs: a value (no field of it changes)
let desk_hit_row : @ui.Style = @ui.css("w=Full px=S3 py=S2_5 radius=Xl hovered{bg=Tint}")

///|
// kept across runs: a value (no field of it changes)
let desk_hit_words : @ui.TextStyle = @ui.text_style(size=Ui, max_lines=2, narrow=@ui.text_patch(size=Lg))

///|
/// The layout (layout): 20 in, 4 over, 24 under; its blocks 10 apart, each its name over its control, 8 between.
// kept across runs: a value (no field of it changes)
let desk_layout_box : @ui.Style = @ui.css("w=Full px=S5 pt=S1 pb=S6 gap=S2_5")

///|
// kept across runs: a value (no field of it changes)
let desk_layout_block : @ui.Style = @ui.css("w=Full gap=S2")

///|
// kept across runs: a value (no field of it changes)
let desk_layout_label : @ui.TextStyle = @ui.text_style(size=Meta, wrap=false, narrow=@ui.text_patch(size=Sm))

///|
/// The papers (papers: five to a row, 8 apart): each a swatch 44 high, its corner the page's, its name under it.
// kept across runs: a value (no field of it changes)
let desk_papers : @ui.Style = @ui.css("row w=Full gap=S2")

///|
// kept across runs: a value (no field of it changes)
let desk_swatch_box : @ui.Style = @ui.css("gap=S1 align=ACenter")

///|
/// The layout's room (layout: 20 either side; the panel's 280 of its 320), its papers five to a row 8 apart, the face
/// and the indent side by side on a phone 14 apart (layoutPair), a choice's track 4 round its two.
let desk_layout_in : Double = 20.0

///|
let desk_layout_inner : Double = 280.0

///|
let desk_papers_gaps : Double = 32.0

///|
let desk_papers_row : Double = 5.0

///|
let desk_pair_gap : Double = 14.0

///|
let desk_seg_track : Double = 4.0

///|
// kept across runs: a value (no field of it changes)
let desk_layout_pair : @ui.Style = @ui.css("row w=Full gap=S3_5")

///|
// kept across runs: a value (no field of it changes)
let desk_layout_column : @ui.Style = @ui.css("w=Full gap=S2_5")

///|
// kept across runs: a value (no field of it changes)
let desk_layout_half : @ui.Style = @ui.css("gap=S2")

///|
// kept across runs: a value (no field of it changes)
let desk_swatch_off : @ui.Style = @ui.css("w=Full min_h=S11 py=S1 radius=Xl align=ACenter justify=JCenter border=B0_5")

///|
// kept across runs: a value (no field of it changes)
let desk_swatch_on : @ui.Style = desk_swatch_off.then(@ui.css("border=B2"))

///|
// kept across runs: a value (no field of it changes)
let desk_swatch_glyph : @ui.TextStyle = @ui.text_style(size=Title, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let desk_swatch_name : @ui.TextStyle = @ui.text_style(size=Caption, wrap=false, narrow=@ui.text_patch(size=Xs))

///|
/// The size's row (sizeRow): a block of the ladder's (its row corner), its keys 32 high the ladder's inset in all round,
/// round by its next step (Inner: 18 less 8, 10), so as high as they are and that twice.
// kept across runs: a value (no field of it changes)
let desk_size_row : @ui.Style = @ui.css("row w=Full align=ACenter radius=Xl2").then(
  @ui.style(min_h=Fixed(desk_size_row_h), px=room(corner_inset), py=room(corner_inset)),
)

///|
/// The size's row's height: its keys' 32 and the ladder's inset over and under them.
let desk_size_row_h : Double = 32.0 + 2.0 * corner_inset

///|
/// A size's key (sizeKey): its corner its row's next step in, concentric with the row's (desk_size_key_corner).
// kept across runs: a value (no field of it changes)
let desk_size_key_box : @ui.Style = @ui.css((
  #|min_h=S8 min_w=S11 px=S2_5 py=S1 align=ACenter justify=JCenter hovered{bg=Tint} disabled{opacity=O35}
))

///|
/// How round a size's key is: its row's corner less the ladder's inset it stands in from the row's ends (18 less 8,
/// 10), its tint under the hand concentric with the row's capsule end (said as radius=Inner, which a node of the
/// window's tree's style does not work out: square till 2026-11-12).
fn desk_size_key_corner() -> Double {
  @ui.concentric(@ui.tree_theme().corner(Xl2), corner_inset)
}

///|
// kept across runs: a value (no field of it changes)
let desk_size_key_words : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, wrap=false, narrow=@ui.text_patch(size=Lg))

///|
// kept across runs: a value (no field of it changes)
let desk_size_value : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, wrap=false, narrow=@ui.text_patch(size=Lg))

///|
/// A slider's row (sliderRow): its name 48 (as wide as the widest name where that is more), the line, its value 48,
/// 10 apart.
// kept across runs: a value (no field of it changes)
let desk_slider_box : @ui.Style = @ui.css("row w=Full gap=S2_5 align=ACenter")

///|
let desk_slider_label_w : Double = 48.0

///|
// kept across runs: a value (no field of it changes)
let desk_slider_value_box : @ui.Style = @ui.css("w=S12 align=AEnd")

///|
// kept across runs: a value (no field of it changes)
let desk_slider_value : @ui.TextStyle = @ui.text_style(size=Meta, weight=Semibold, wrap=false, narrow=@ui.text_patch(size=Sm))

///|
/// The reader's keys (reader_node's reader_keys), the keymap's own, never changed: where a text is read (`Reader`). ⌘F (Ctrl
/// elsewhere) finds and Escape closes what is open over the text, or it, with the cursor in a field too; ← → a chapter
/// back or on, not in a field.
pub fn reader_bindings() -> Array[@view.Binding] {
  let reading : @view.KeyWhen = In("Reader")
  let not_typing : @view.KeyWhen = All([In("Reader"), Not(In("Field"))])
  [
    { keys: [{ code: @ui.key_of_char('f'), mods: desk_mod() }], action: "reader.find", when: reading },
    { keys: [{ code: @ui.key_code_left, mods: 0 }], action: "reader.chapter_back", when: not_typing },
    { keys: [{ code: @ui.key_code_right, mods: 0 }], action: "reader.chapter_on", when: not_typing },
    { keys: [{ code: @ui.key_escape, mods: 0 }], action: "reader.escape", when: reading },
  ]
}
