// What is picked of the window's tree's words copied with its shape: beside its words (selected_words), as HTML
// (@hostapi.clipboard_set_html) for what pastes it with its lists, headings and code (a document, a mail, a page's
// editor, a translator reading the clipboard). A paragraph's shape is what the part that shows it says of it
// (words_shaped: a heading, a list's item, a code block, a quote; said of none, a paragraph); its pieces' (code,
// bold, slanted, struck, a link) are its runs'. Where nothing picked has a shape of either kind, the words alone go.

///|
/// What a paragraph of words is, as it is copied (words_shaped): a heading of its level; a list's item (how deep, from
/// 1; its number, 0 in a bulleted list; which item, so its paragraphs stay one); a code block's (which); a quote's
/// (which); a table cell (table id, absolute row, column, whether header).
#derive(Eq, Debug)
pub(all) enum WordsShape {
  Heading(Int)
  Item(Int, Int, @view.NodeId)
  Code(@view.NodeId)
  Quote(@view.NodeId)
  Cell(Int, Int, Int, Bool)
}

///|
/// What the words node `v` holds are, said for what is copied of them (words_shaped), the nearest that says it.
// kept across runs: what each node lends (View::lends), let go with it
let words_shapes : @view.Lent[() -> WordsShape] = @view.Lent::new()

///|
/// The words node `v` holds (its own and those of what it holds) are of `shape`, worked out as they are copied (a list
/// numbered or not as it is then): picked with the pointer and copied, they go as that in the HTML beside their words
/// (picked_html). `v`.
pub fn words_shaped(v : @view.View, shape : () -> WordsShape) -> @view.View {
  v.lends(words_shapes, shape)
}

///|
/// A paragraph picked, as it is copied: its shape (none: a paragraph), its runs (their words its words, else none),
/// its words and what of them is picked (from `a` until `b`).
priv struct CopiedPart {
  shape : WordsShape?
  runs : Array[@text.Run]
  text : String
  a : Int
  b : Int
}

///|
/// What is picked with the pointer of the window's tree's words as HTML (copied_html), each paragraph's shape what the
/// part showing it says (words_shaped) and its pieces its runs'; "" where none of it is shaped.
fn picked_html() -> String {
  guard picked_in_order() is Some((spans, _)) else { return "" }
  let parts : Array[CopiedPart] = []
  for e in spans {
    let (k, s) = e
    let v = match (view_app.val, picked_shown.get(k)) {
      (Some(tree), Some((id, _, _))) => tree.view_of(id)
      _ => None
    }
    let shape = match v {
      Some(v) =>
        match v.lent(words_shapes).map(fn(f) { f() }) {
          Some(sh) => Some(sh)
          None => s.shape
        }
      None => s.shape
    }
    let runs = match v {
      Some(v) => {
        let rs = v.runs_set_now().0
        if rs.is_empty() { s.runs } else { rs }
      }
      None => s.runs
    }
    parts.push({ shape, runs, text: s.text, a: s.a, b: s.b })
  }
  copied_html(parts)
}

///|
/// `s` as HTML's text: its marks escaped, its line ends (where `breaks`) as breaks.
fn html_text(s : String, breaks? : Bool = true) -> String {
  let sb = StringBuilder()
  for c in s {
    match c {
      '&' => sb.write_string("&amp;")
      '<' => sb.write_string("&lt;")
      '>' => sb.write_string("&gt;")
      '"' => sb.write_string("&quot;")
      '\n' if breaks => sb.write_string("<br>")
      _ => sb.write_char(c)
    }
  }
  sb.to_string()
}

///|
/// What of part `p` is picked as HTML within its block, and whether any of it is styled: each of its runs' pieces
/// picked in its run's style (code, bold but in a heading, which is bold itself, slanted, struck, a link); its words as
/// they are where its runs are not its words (none, or other words than those laid out).
fn copied_pieces(p : CopiedPart) -> (String, Bool) {
  let bold = !(p.shape is Some(Heading(_)))
  let mut total = 0
  for r in p.runs {
    total = total + r.text.length()
  }
  if p.runs.is_empty() || total != p.text.length() {
    return (html_text(p.text.clamped_view(start=p.a, end=p.b).to_owned()), false)
  }
  let sb = StringBuilder()
  let mut styled = false
  let mut off = 0
  for r in p.runs {
    let len = r.text.length()
    let from = if p.a > off { p.a } else { off }
    let upto = if p.b < off + len { p.b } else { off + len }
    if from < upto {
      let words = html_text(r.text.clamped_view(start=from - off, end=upto - off).to_owned())
      let opens = StringBuilder()
      let closes : Array[String] = []
      if r.link != "" {
        opens.write_string("<a href=\"" + html_text(r.link, breaks=false) + "\">")
        closes.push("</a>")
      }
      if r.code {
        opens.write_string("<code>")
        closes.push("</code>")
      }
      if bold && r.weight >= 600 {
        opens.write_string("<strong>")
        closes.push("</strong>")
      }
      if r.italic || r.emph {
        opens.write_string("<em>")
        closes.push("</em>")
      }
      if r.strike {
        opens.write_string("<s>")
        closes.push("</s>")
      }
      styled = styled || closes.length() > 0
      sb.write_string(opens.to_string())
      sb.write_string(words)
      closes.rev_each(fn(c) { sb.write_string(c) })
    }
    off = off + len
  }
  (sb.to_string(), styled)
}

///|
/// The parts picked as HTML, in their order: headings each of their level; a list's items in lists (nested by how deep
/// each is, numbered or not as its number says), an item's paragraphs one item; a code block's lines one block of
/// code (its words as they are); a quote's paragraphs one quote; the rest paragraphs. "" where none has a shape and
/// none of their pieces a style: their words say all of it.
fn copied_html(parts : Array[CopiedPart]) -> String {
  let out = StringBuilder()
  let mut shaped = false
  // (the lists open, outermost first: whether numbered; the item open in the innermost, which one)
  let lists : Array[Bool] = []
  let mut item : @view.NodeId? = None
  let mut code : @view.NodeId? = None
  let mut quote : @view.NodeId? = None
  let mut table : (Int, Int, Int, String)? = None
  let close_code = fn() {
    if code is Some(_) {
      out.write_string("</code></pre>")
    }
    code = None
  }
  let close_quote = fn() {
    if quote is Some(_) {
      out.write_string("</blockquote>")
    }
    quote = None
  }
  let close_table = fn() {
    match table {
      Some((_, _, _, tag)) => {
        out.write_string("</\{tag}></tr></table>")
        table = None
      }
      None => ()
    }
  }
  let close_lists = fn(depth : Int) {
    while lists.length() > depth {
      out.write_string("</li>")
      out.write_string(if lists.pop().unwrap_or(false) { "</ol>" } else { "</ul>" })
    }
    if lists.length() < 1 {
      item = None
    }
  }
  for p in parts {
    let (pieces, styled) = copied_pieces(p)
    shaped = shaped || styled || p.shape is Some(_)
    match p.shape {
      Some(Item(depth, number, id)) => {
        close_code()
        close_quote()
        close_table()
        let depth = if depth < 1 { 1 } else { depth }
        if lists.length() > depth {
          close_lists(depth)
        }
        if lists.length() == depth && item == Some(id) {
          // (another paragraph of the same item)
          out.write_string("<br>")
        } else {
          if lists.length() == depth {
            out.write_string("</li>")
            // (a numbered list after a bulleted one at the same depth, or the other way: a list of its own)
            if lists[depth - 1] != (number > 0) {
              out.write_string(if lists.pop().unwrap_or(false) { "</ol>" } else { "</ul>" })
            }
          }
          while lists.length() < depth {
            let numbered = number > 0
            out.write_string(
              if numbered {
                if number > 1 && lists.length() == depth - 1 {
                  "<ol start=\"\{number}\">"
                } else {
                  "<ol>"
                }
              } else {
                "<ul>"
              },
            )
            lists.push(numbered)
            if lists.length() < depth {
              out.write_string("<li>")
            }
          }
          out.write_string("<li>")
          item = Some(id)
        }
        out.write_string(pieces)
      }
      Some(Code(id)) => {
        close_lists(0)
        close_quote()
        close_table()
        if code == Some(id) {
          out.write_string("\n")
        } else {
          close_code()
          out.write_string("<pre><code>")
          code = Some(id)
        }
        out.write_string(html_text(p.text.clamped_view(start=p.a, end=p.b).to_owned(), breaks=false))
      }
      Some(Quote(id)) => {
        close_lists(0)
        close_code()
        close_table()
        if quote != Some(id) {
          close_quote()
          out.write_string("<blockquote>")
          quote = Some(id)
        }
        out.write_string("<p>" + pieces + "</p>")
      }
      Some(Heading(level)) => {
        close_lists(0)
        close_code()
        close_quote()
        close_table()
        let n = if level < 1 { 1 } else if level > 6 { 6 } else { level }
        out.write_string("<h\{n}>" + pieces + "</h\{n}>")
      }
      Some(Cell(tid, row, col, head)) => {
        close_lists(0)
        close_code()
        close_quote()
        let tag = if head { "th" } else { "td" }
        match table {
          Some((otid, orow, ocol, otag)) if otid == tid && row >= orow =>
            if row == orow && col == ocol {
              out.write_string("<br>" + pieces)
            } else if row == orow && col > ocol {
              out.write_string("</\{otag}>")
              for _ in (ocol + 1)..<col {
                out.write_string("<\{tag}></\{tag}>")
              }
              out.write_string("<\{tag}>" + pieces)
              table = Some((tid, row, col, tag))
            } else {
              out.write_string("</\{otag}></tr><tr>")
              for _ in 0..<col {
                out.write_string("<\{tag}></\{tag}>")
              }
              out.write_string("<\{tag}>" + pieces)
              table = Some((tid, row, col, tag))
            }
          _ => {
            close_table()
            out.write_string("<table><tr><\{tag}>" + pieces)
            table = Some((tid, row, col, tag))
          }
        }
      }
      None => {
        close_lists(0)
        close_code()
        close_quote()
        close_table()
        out.write_string("<p>" + pieces + "</p>")
      }
    }
  }
  close_lists(0)
  close_code()
  close_quote()
  close_table()
  if shaped {
    out.to_string()
  } else {
    ""
  }
}
