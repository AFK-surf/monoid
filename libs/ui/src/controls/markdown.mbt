// Markdown as still.fail's messages show it (the Android app's
// ui/Markdown.kt, from the web phone's Prose.tsx and the message's
// `.markdown` in styles/conversation.css.ts): the body's size on lines 1.65
// high; headings in bold (h1-h4 at the body's size, 14 above and 6 below);
// lists with their markers in a 20 indent, wrapped lines hanging under the
// words (discs, then circles, then squares; numbers right-aligned 5 from
// the words), tasks' boxes; quotes beside a 2 bar of line_strong in the
// web's muted; code blocks on the code ground, 12 round, their language and
// a copy button on a row of their own above the code (a finger has no
// hover); inline code in the code face at 0.9 in its own colour, no box;
// emphasis (*…*) upright in muted ink rather than slanted (primary text ink
// inside muted blocks, unchanged inside semantic-ink notices; inline code and
// links keep their own colour upright); links in blue (a web address alone in
// code is one too); rules. A link to
// another chat is a reference to it: `@` a little
// lighter, then its words, in the accent. With `files`, a message's files
// its text names (the core's `placed`) are drawn where it names them: a
// paragraph of only a link to one, or its images, as the files themselves;
// a table's cell of only its images, them side by side.
// With `screens`, its links to a station's screens (and 共享调试) are their
// cards alone in a paragraph, their titles bare within a sentence.
//
// Spacing is the web's: each block keeps the margins `.markdown` gives it
// (a paragraph none above and 8 below, ui.css.ts; a heading 14 and 6; a
// list, a code block, a table, a quote 8 below), and two blocks next to each
// other are as far apart as the larger of the margins between them; the
// first's top and the last's bottom are the message's own.

///|
/// What a paragraph keeps below it (ui.css.ts `.markdown p`: margin 0 0 8px), on every screen.
let paragraph_after : Double = 8.0

///|
/// The core's `markdown` as the live client asks it (sfapp.use_core_markdown): words without a tree of their own (a
/// file's, a history's) read by the same core as a chat's messages. Nothing here reads Markdown or TeX.
pub let markdown_read : Ref[((String, (Json?) -> Unit) -> Unit)?] = Ref(None)

///|
/// A run without a core (the Tester's, the screenshots' app): the real core's answers to its pure calls, kept
/// (src/sfkept: `markdown`, `code.ink`, `reader.*`), answered at once; None for a call that is not one of those. Bound
/// once by such a run, never reset.
pub let kept_call : Ref[((String, Json, Bytes?) -> Result[(Json, Bytes?), Json]?)?] = Ref(None)

///|
/// Whether a person's words may hold more than one run, or one set otherwise than plain, as the core reads them
/// (refLinks.ts draftWords: an address, a composer's mark, a link to a chat; the few of Markdown's marks it reads: a
/// pair of `*`, `_`, `~` or backticks, a line begun `- ` or `* `): words with none of these are their own one run,
/// asked of none. Never false where the core would say more (it may be true where the core says one plain run).
pub fn words_may_link(text : String) -> Bool {
  if text.contains("://") || text.contains("@[") || text.contains("](") {
    return true
  }
  let mut stars = 0
  let mut lows = 0
  let mut waves = 0
  let mut ticks = 0
  // (a line so far only blanks; then its `-` or `*`, an item's mark if a blank follows)
  let mut starts = true
  let mut marked = false
  for c in text {
    if marked && c == ' ' {
      return true
    }
    marked = starts && (c == '-' || c == '*')
    starts = c == '\n' || (starts && c == ' ')
    match c {
      '*' => stars += 1
      '_' => lows += 1
      '~' => waves += 1
      '`' => ticks += 1
      _ => ()
    }
  }
  stars > 1 || lows > 1 || waves > 1 || ticks > 1
}

///|
/// A person's `text` in the runs the real core reads it in (`ref.words`: refLinks.ts draftWords), kept (`kept_call`),
/// if it was: for a run without a core, whose messages have no `words` of their own.
pub fn kept_words(text : String) -> Json? {
  guard words_may_link(text) else { return None }
  match kept_call.val {
    Some(kept) =>
      match kept("ref.words", { "text": Json::string(text) }, None) {
        Some(Ok((Object(m), _))) => m.get("runs")
        _ => None
      }
    None => None
  }
}

///|
/// `text`'s tree as the real core read it, kept (`kept_call`), if it was: for a made-up chat's message to carry, as a
/// station's carries its own (`md`).
pub fn kept_md(text : String) -> Json? {
  kept_tree(text)
}

///|
/// `text`'s tree as the real core read it, kept (`kept_call`), if it was.
fn kept_tree(text : String) -> Json? {
  match kept_call.val {
    Some(kept) =>
      match kept("markdown", { "text": Json::string(text) }, None) {
        Some(Ok((Object(m), _))) => m.get("md")
        _ => None
      }
    None => None
  }
}

///|
let markdown_asked : Map[String, Bool] = Map([])

///|
fn init {
  @ui.on_reset(fn() {
    parsed.clear(); parsed_order.clear(); parsed_cost.clear(); parsed_used.val = 0
    core_parsed.clear(); markdown_asked.clear(); markdown_read.val = None
  })
}

///|
let parsed : Map[String, Array[MdBlock]] = Map([])

///|
/// The texts parsed lately, oldest first; the drawing data counts toward the budget too.
let parsed_order : Array[String] = []

///|
let core_parsed : Map[String, Bool] = Map([])

///|
let parsed_most : Int = 4096

///|
let parsed_cost : Map[String, Int] = Map([])

///|
let parsed_used : Ref[Int] = Ref(0)

///|
let parsed_budget : Int = 4000000

///|
/// About how much `j` weighs held (blocks_of's budget: about as long as it is written), worked out where it lies,
/// nothing written out for it.
fn json_cost(j : Json) -> Int {
  match j {
    Null | True | False => 4
    Number(_, ..) => 8
    String(s) => s.length() + 2
    Array(xs) => {
      let mut n = 2
      for x in xs {
        n = n + json_cost(x)
      }
      n
    }
    Object(m) => {
      let mut n = 2
      for k, v in m {
        n = n + k.length() + 4 + json_cost(v)
      }
      n
    }
  }
}

///|
fn blocks_of(text : String, tree : Json?) -> Array[MdBlock] {
  if parsed.get(text) is Some(b) && (core_parsed.contains(text) || (!(tree is Some(Array(_))) && markdown_read.val is None)) { return b }
  let b = match tree {
    Some(Array(nodes)) => core_blocks(nodes,text)
    // a live client's words wait for its core
    _ if markdown_read.val is Some(_) => []
    _ =>
      match kept_tree(text) {
        Some(Array(nodes)) => core_blocks(nodes,text)
        // (no core and nothing kept: the words as they are)
        _ => [Paragraph([Text(text)])]
      }
  }
  let cost = text.length() + (match tree { Some(j) => json_cost(j); None => 0 })
  let old_cost = parsed_cost.get(text).unwrap_or(0)
  parsed_used.val -= old_cost
  // One unusually large visible message can stand alone; it never pins all the older drawings beside it.
  while parsed_order.length() > 0 && (parsed_order.length() >= parsed_most || parsed_used.val + cost > parsed_budget) {
    let old = parsed_order[0]
    parsed_order.remove(0) |> ignore
    if old != text { parsed_used.val -= parsed_cost.get(old).unwrap_or(0) }
    parsed.remove(old); parsed_cost.remove(old); core_parsed.remove(old); markdown_asked.remove(old)
    // (what follows its answer gone with it, where nothing of the window's tree reads it now: md_let_go)
    md_forgotten(old)
  }
  if !parsed.contains(text) { parsed_order.push(text) }
  parsed[text] = b
  parsed_cost[text] = cost
  parsed_used.val += cost
  if tree is Some(Array(_)) { core_parsed[text] = true }
  b
}

///|
/// A file a message names by its path, as its chip's link carries it: the path and the line it points at (path_of_link
/// reads it back); no address anything opens.
pub fn path_link(path : String, line : Int?) -> String {
  path_scheme +
  (match line {
    Some(n) => n.to_string()
    None => ""
  }) +
  ":" +
  path
}

///|
/// The path and the line a file's chip's link (path_link) carries; None for any other link.
pub fn path_of_link(href : String) -> (String, Int?)? {
  guard href.has_prefix(path_scheme) else { return None }
  let rest = href.exact_view(start=path_scheme.length()).to_owned()
  guard rest.find(":") is Some(i) else { return None }
  let mut line : Int? = None
  for ch in rest.exact_view(end=i) {
    guard ch >= '0' && ch <= '9' else { return None }
    line = Some(line.unwrap_or(0) * 10 + (ch.to_int() - '0'.to_int()))
  }
  Some((rest.exact_view(start=i + 1).to_owned(), line))
}

///|
/// The path of a file on the agent's machine that a link names: a file's chip (path_link), a `file://` address, or a
/// path with no scheme (`docs/plan.md`, `/w/plan.md#L3`, its fragment left out). None for a web link, a link within the
/// page, or any other scheme.
pub fn local_path_of_link(href : String) -> String? {
  if path_of_link(href) is Some((path, _)) {
    return Some(path)
  }
  let u = href.trim(chars=" ").to_owned()
  let cut = fn(s : String) {
    let mut end = s.length()
    for i, ch in s {
      if ch == '#' || ch == '?' {
        end = i
        break
      }
    }
    s.exact_view(end~).to_owned()
  }
  if u.has_prefix("file://") {
    let rest = u.exact_view(start=7).to_owned()
    let rest = match rest.find("/") {
      Some(i) => rest.exact_view(start=i).to_owned()
      None => return None
    }
    let path = @codec.percent_decoded(cut(rest))
    // (`file:///C:/w/a.md`: Windows' drive, with no slash before it)
    let drive = path.length() > 2 && path.at(2).to_int() == 58
    return Some(if drive { path.exact_view(start=1).to_owned() } else { path })
  }
  if u == "" || u.has_prefix("#") || u.has_prefix("?") || u.has_prefix("//") || has_scheme(u) {
    return None
  }
  let path = @codec.percent_decoded(cut(u))
  if path == "" { None } else { Some(path) }
}

///|
/// Whether `u` starts with a URL's scheme (two letters or more, so that a Windows drive `C:` is no scheme).
fn has_scheme(u : String) -> Bool {
  guard u.find(":") is Some(i) && i >= 2 else { return false }
  for k, ch in u.exact_view(end=i) {
    let letter = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
    let more = (ch >= '0' && ch <= '9') || ch == '+' || ch == '-' || ch == '.'
    guard letter || (k > 0 && more) else { return false }
  }
  true
}

///|
let path_scheme : String = "stillfail-path:"

///|
/// A file's chip in words: its path as the core shortened it, and the line it points at, in the
/// code face at .88 of the words, on a quiet ground 6 round and 6 either side; the words' own colour, its link a file's
/// (path_link).
fn file_chip_run(path : String, line : Int?, shown : String, emph? : Bool = false) -> @ui.Run {
  let words = (if shown != "" { shown } else { path }) +
    (match line {
      Some(n) => ":" + n.to_string()
      None => ""
    })
  let t = theme()
  @ui.span(
    words,
    emph~,
    mono=true,
    scale=file_chip_scale,
    color=t.p.text,
    bg=alpha(t.p.muted, file_chip_share),
    ground=Some(file_chip_ground),
    link=path_link(path, line),
  )
}

///|
let file_chip_scale : Double = 0.88

///|
let file_chip_share : Double = 0.13

///|
/// Its ground, in ems of its words: 6 either side and 6 round at a body's 15 (.88 of it, 13.2), 20 high.
// kept across runs: a value (no field of it changes)
let file_chip_ground : @ui.Ground = { room: 6.0 / 13.2, height: 20.0 / 13.2, corner: 6.0 / 13.2, after: 0.0 }


///|
/// The file a link or an image names, by its name (the last part of its
/// path): `shot.png`, `/w/shot.png`, `file:///w/shot.png`.
pub fn file_name_of(url : String) -> String {
  let mut u = url.trim(chars=" ").to_owned()
  if u.has_prefix("file://") {
    u = u.exact_view(start=7).to_owned()
  }
  let u = @codec.percent_decoded(u)
  let mut i = u.length()
  while i > 0 && u.at(i - 1).to_int() != 47 {
    i = i - 1
  }
  u.exact_view(start=i).to_owned()
}


///|
/// Links to a station's screens and 共享调试 (is_card_link), as a chat draws
/// them: `card` one alone in a paragraph (its own words,
/// or None when it is bare); `title` the words a bare one within a sentence
/// reads as (it still leads where it did).
pub(all) struct Screens {
  card : (String, LinkTo, String?) -> Unit
  title : (String, LinkTo) -> String
}

///|
/// A file the message places (`files`): `draw` it on a line of its own; an image's width over its height and its
/// drawing in a box that wide (as tall as its proportion makes it), as a table's cell has it beside others
/// (None for any other file, named in a cell by its words).
pub(all) struct Placed {
  draw : () -> Unit
  image : (Double, (Double) -> Unit)?
}

///|
/// A paragraph of only a link with a card: its
/// address, and its words unless it is bare.
fn screen_alone(xs : Array[MdInline]) -> (String, LinkTo, String?)? {
  let parts = xs.filter(fn(x) {
    match x {
      Text(t) => t.trim(chars=" \n\t").to_owned() != ""
      _ => true
    }
  })
  guard parts.length() == 1 else { return None }
  match parts[0] {
    // (a station's 共享调试 no card even alone: a link to its page, 2026-11-11, the card that lent the phone from the
    // chat gone)
    Link(href, c, to) if to.is_card() && to.card != "adb" => {
      let words = md_plain(c)
      Some((href, to, if to.bare { None } else { Some(words) }))
    }
    _ => None
  }
}

///|
/// The links with cards written bare among these words (Markdown.kt
/// bareScreens), which read as their titles; not within an image, nor a
/// link's own words.
fn bare_screens(xs : Array[MdInline], out : Array[(String, LinkTo)]) -> Unit {
  for x in xs {
    match x {
      Link(href, _, to) =>
        if to.is_card() && to.bare && !out.iter().any(fn(o) { o.0 == href }) {
          out.push((href, to))
        }
      Emph(c) | Strong(c) | Strike(c) => bare_screens(c, out)
      _ => ()
    }
  }
}

///|
/// The links to chats written bare among these words, as bare_screens finds those to screens.
fn bare_chats(xs : Array[MdInline], out : Array[String]) -> Unit {
  for x in xs {
    match x {
      Link(href, _, to) =>
        if to.chat && to.bare && !out.contains(href) {
          out.push(href)
        }
      Emph(c) | Strong(c) | Strike(c) => bare_chats(c, out)
      _ => ()
    }
  }
}

///|
/// The web's own tones where the message's parts use them, on every screen (as Markdown.kt's webMuted, webSubtle,
/// webLine).
fn web() -> Palette {
  if theme().dark {
    web_dark
  } else {
    web_light
  }
}

///|
/// The words of the first of `blocks` that has any, for a line of them (`markdown_node`'s `one_line`): a quote's or a
/// list's first item's, within; a code block's or a formula's source; a table's head row.
fn first_words(blocks : Array[MdBlock]) -> Array[MdInline] {
  for b in blocks {
    let xs : Array[MdInline] = match b {
      Paragraph(xs) | Heading(_, xs) => xs
      Quote(inner) => first_words(inner)
      List(l) => if l.items.is_empty() { [] } else { first_words(l.items[0].blocks) }
      CodeBlock(_, code, _) => [Code(code)]
      MathBlock(source, drawing) => [Formula(source, drawing)]
      // (its cells apart by a bar, as a table's row is in words: Md::piece)
      Table(t) => {
        let out : Array[MdInline] = []
        for i, cell in t.head {
          if i > 0 {
            out.push(Text(" | "))
          }
          out.append(cell)
        }
        out
      }
      Rule => []
    }
    if !xs.is_empty() {
      return xs
    }
  }
  []
}

///|
/// A paragraph's images' rows: at least this high while they fit, at most `image_row_most`.
let image_row_least : Double = 120.0

///|
let image_row_most : Double = 200.0

///|
/// Between a paragraph's images, across and down.
let image_row_gap : Double = 8.0

///|
/// A list's indent, where its markers are (20), and how far a number's dot stands from the item (5).
let md_marker_w : Double = 20.0

///|
let md_marker_gap : Double = 5.0

///|
/// A task's box's room, in words' size (Markdown.kt's Placeholder(25.sp, ..)).
let task_room : Double = 25.0

///|
fn is_web_address(s : String) -> Bool {
  (s.has_prefix("https://") || s.has_prefix("http://")) &&
  !s.contains(" ") &&
  s.length() > 8
}

///|
/// The ink emphasis (`*…*`) takes inside a block drawn in `block_ink`: muted on
/// body prose (`0L` or `text`), flipped to primary `text` inside muted blocks
/// (quotes, table headers, secondary history steps matching `muted`/`subtle`),
/// and `0L` (inheriting the block's colour; `emph` still copies as `<em>`) for
/// custom semantic inks such as red error notices.
fn emph_ink_for(block_ink : Int64) -> Int64 {
  let p = theme().p
  if block_ink == 0L || block_ink == p.text || block_ink == web().text {
    p.muted
  } else if block_ink == p.muted || block_ink == web().muted || block_ink == p.subtle || block_ink == web().subtle {
    p.text
  } else {
    0L
  }
}

///|
/// Inlines as runs, the styles they are within carried down. Emphasis (`*…*`)
/// draws upright in `emph_ink` (never slanted) while keeping `emph=true` so
/// copied HTML preserves `<em>`; inline code and links keep their own colours
/// upright.
fn runs_of(
  xs : Array[MdInline],
  out : Array[@ui.Run],
  bold : Bool,
  emph : Bool,
  strike : Bool,
  link : String,
  accent : Int64,
  emph_ink : Int64,
  titles : Map[String, String],
  paths : Bool,
) -> Unit {
  let emph_color = if emph && link == "" { emph_ink } else { 0L }
  for x in xs {
    match x {
      Text(s) => out.push(@ui.span(s, bold~, emph~, strike~, link~, color=emph_color))
      Formula(s, d) => {
        let drawing = math_inline(d)
        out.push(
          @ui.span(
            s,
            drawing~,
            code=drawing is None,
            bold~,
            emph~,
            strike~,
            link~,
            color=if drawing is Some(_) { emph_color } else { 0L },
          ),
        )
      }
      Code(s) =>
        out.push(
          @ui.span(
            s,
            code=true,
            bold~,
            emph~,
            strike~,
            link=if link == "" && is_web_address(s) { s } else { link },
          ),
        )
      // a file named by its path, in an agent's words and not within a link: its chip (Peeks.tsx FileRef), its card
      // over it (the message's on_link_shown); else its words as code
      FileRef(_, path, line, shown) if paths && link == "" => out.push(file_chip_run(path, line, shown, emph~))
      FileRef(s, _, _, _) => out.push(@ui.span(s, code=true, bold~, emph~, strike~, link~))
      Emph(c) => runs_of(c, out, bold, true, strike, link, accent, emph_ink, titles, paths)
      Strong(c) => runs_of(c, out, true, emph, strike, link, accent, emph_ink, titles, paths)
      Strike(c) => runs_of(c, out, bold, emph, true, link, accent, emph_ink, titles, paths)
      Link(href, c, to) if link == "" && to.chat => {
        // a reference to another chat: `@` and its title (a bare link's as the message says it), in the accent's
        // ink (the `@` not lighter: at 70% it was 2.5 to 1)
        let words = md_plain(c)
        let shown = match titles.get(href) {
          Some(title) if to.bare => title
          _ => words
        }
        out.push(@ui.span("@", bold~, emph~, strike~, link=href, color=accent))
        out.push(@ui.span(shown, bold~, emph~, strike~, link=href, color=accent))
      }
      // a bare link to a screen or a station's 共享调试: its title, leading where it does
      Link(href, _, to) if link == "" && titles.get(href) is Some(title) && to.bare =>
        out.push(@ui.span(title, bold~, emph~, strike~, link=href))
      Link(href, c, _) => runs_of(c, out, bold, emph, strike, href, accent, emph_ink, titles, paths)
      Image(src, alt) => {
        // its file's name, as read
        let words = if alt != "" { alt } else { file_name_of(src) }
        out.push(@ui.span(words, bold~, emph~, strike~, link=src))
      }
      HardBreak => out.push(@ui.span("\n", bold~, emph~, strike~, link~))
    }
  }
}

///|
/// A code block's copy key's height: a capsule.
let code_key_h : Double = 24.0

///|
let code_tray_icon : Double = 14.0

///|
let code_room_y : Double = 12.0

///|
/// A code block's lines and its language's size on a desktop's width (Prose.css.ts codePre: the meta size on 1.6;
/// codeLang: the caption's 11).
let code_line_wide : Double = 12.0 * 1.6

///|
let code_lang_wide : Double = 11.0

// ── tables ──────────────────────────────────────────────────────────────

///|
/// A table's columns' widths and all of them together, its cells' extents `extents` (each row's, the head's first: how
/// narrow it may be, its width on one line, whether it is images that keep their width) in `avail` (Md::table's rule,
/// the one its frame and a node's table both lay out by): each at least 4em and its sides, as wide as its content
/// until the room is full, then sharing what is left by how much more each would take, none narrower than its words
/// on one line or 14em of them (`fit`: 4em, its words wrapping first, a picture's), whichever is less (its longest word
/// if wider; images their width).
fn table_widths(
  extents : Array[Array[(Double, Double, Bool)]],
  avail : Double,
  fit : Bool,
  sp : (Double) -> Double,
) -> (Array[Double], Double) {
  let cols = if extents.length() > 0 { extents[0].length() } else { 0 }
  let least = 4.0 * 13.0 + 24.0
  // In a picture, let words wrap into narrower columns first; only a table that still cannot fit is scaled down.
  let readable = (if fit { 4.0 } else { 14.0 }) * sp(13.0)
  let mins = Array::make(cols, least)
  let maxs = Array::make(cols, least)
  for row in extents {
    for k in 0..<cols {
      let (lo, hi, images) = row.get(k).unwrap_or((0.0, 0.0, false))
      // Rich text can break an otherwise unbroken word when a cell is too narrow. Images must keep their width.
      let floor = if fit && !images { dmin(hi, readable) } else { dmax(lo, dmin(hi, readable)) }
      let pad = table_cell_pad(k, cols)
      if floor + pad.0 + pad.1 > mins[k] {
        mins[k] = floor + pad.0 + pad.1
      }
      if hi + pad.0 + pad.1 > maxs[k] {
        maxs[k] = hi + pad.0 + pad.1
      }
    }
  }
  let mut sum_min = 0.0
  let mut sum_max = 0.0
  for k in 0..<cols {
    sum_min = sum_min + mins[k]
    sum_max = sum_max + maxs[k]
  }
  let widths = if sum_max <= avail {
    maxs
  } else if sum_min >= avail {
    mins
  } else {
    // (whole points, the last the rest: as wide together as the message, not a point past it to scroll)
    let ws = Array::makei(cols, fn(k) {
      (mins[k] + (maxs[k] - mins[k]) * (avail - sum_min) / (sum_max - sum_min)).round()
    })
    let mut before = 0.0
    for k in 0..<(cols - 1) {
      before = before + ws[k]
    }
    ws[cols - 1] = avail - before
    ws
  }
  let mut total = 0.0
  for x in widths {
    total = total + x
  }
  (widths, total)
}

///|
/// How far a table's cell's words are from its sides, and from its top and foot (12, 7: the web's `th`, `td`).
let table_cell_x : Double = 12.0

///|
let table_cell_y : Double = 7.0

///|
/// The room before and after the words of a table's column `k` of `cols`: table_cell_x, none before the first's (its
/// words where the message's are) or after the last's (its rules end at its words).
fn table_cell_pad(k : Int, cols : Int) -> (Double, Double) {
  (if k == 0 { 0.0 } else { table_cell_x }, if k == cols - 1 { 0.0 } else { table_cell_x })
}

///|
/// An image's width in a table's cell: as wide as 160 for a wide image, as tall as 240 for a tall one (Markdown.kt
/// CellImageRow), by its width over its height.
fn cell_image_width(r : Double) -> Double {
  dmin(160.0, 240.0 * r)
}

///|
/// The links in an agent's words (`tree`, the core's reading of `text`), each once, with what the core says each is to
/// (their `to`), for what is shown as a link is pointed at (a chat's card, a pull request's).
pub fn md_links_to(text : String, tree : Json?) -> Map[String, LinkTo] {
  let out : Map[String, LinkTo] = Map([])
  // (the core's tree walked to its links alone: nothing of it read as blocks, nothing kept, so what reads a chat's
  // links reads none of its messages' words)
  if tree is Some(Array(nodes)) {
    core_links(nodes, text, out)
    return out
  }
  fn inl(xs : Array[MdInline]) -> Unit {
    for x in xs {
      match x {
        Link(href, c, to) => {
          if !out.contains(href) {
            out[href] = to
          }
          inl(c)
        }
        Emph(c) | Strong(c) | Strike(c) => inl(c)
        _ => ()
      }
    }
  }
  fn blocks(bs : Array[MdBlock]) -> Unit {
    for b in bs {
      match b {
        Paragraph(xs) | Heading(_, xs) => inl(xs)
        Quote(inner) => blocks(inner)
        List(l) => for item in l.items { blocks(item.blocks) }
        Table(t) => {
          for cell in t.head {
            inl(cell)
          }
          for row in t.rows {
            for cell in row {
              inl(cell)
            }
          }
        }
        _ => ()
      }
    }
  }
  blocks(blocks_of(text, tree))
  out
}
