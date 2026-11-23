// What is picked of the window's tree's words copied with its shape (tree_copied.mbt): as HTML beside its words.

///|
test "picked words copied as HTML: a heading, a paragraph, a list with code in it, a code block; plain paragraphs alone none" {
  let a : @view.NodeId = { at: 1, gen: 0 }
  let b : @view.NodeId = { at: 2, gen: 0 }
  let c : @view.NodeId = { at: 3, gen: 0 }
  let part = fn(shape : WordsShape?, runs : Array[@text.Run]) -> CopiedPart {
    let sb = StringBuilder()
    for r in runs {
      sb.write_string(r.text)
    }
    let text = sb.to_string()
    { shape, runs, text, a: 0, b: text.length() }
  }
  let html = copied_html([
    part(Some(Heading(2)), [@text.span("Status")]),
    part(None, [@text.span("Working on a Mac:")]),
    part(Some(Item(1, 0, a)), [@text.span("logs in "), @text.span("/var/log", code=true)]),
    part(Some(Item(2, 1, b)), [@text.span("nested & first")]),
    part(Some(Item(1, 0, c)), [@text.span("off by "), @text.span("default", weight=700)]),
    part(Some(Code(a)), [@text.span("x = 1", mono=true)]),
    part(Some(Code(a)), [@text.span("y < 2", mono=true)]),
    part(None, [@text.span("See "), @text.span("docs", link="https://example.com/?a=1&b=2"), @text.span(".")]),
  ])
  assert_eq(
    html,
    "<h2>Status</h2><p>Working on a Mac:</p>" +
    "<ul><li>logs in <code>/var/log</code><ol><li>nested &amp; first</li></ol></li><li>off by <strong>default</strong></li></ul>" +
    "<pre><code>x = 1\ny &lt; 2</code></pre>" +
    "<p>See <a href=\"https://example.com/?a=1&amp;b=2\">docs</a>.</p>",
  )
  // (what is picked of a paragraph: its runs' pieces from `a` to `b`)
  let p = part(None, [@text.span("one "), @text.span("two", code=true), @text.span(" three")])
  assert_eq(copied_html([{ ..p, a: 2, b: 6 }]), "<p>e <code>tw</code></p>")
  // (paragraphs of words alone: no HTML, their words are all of it)
  assert_eq(copied_html([part(None, [@text.span("just")]), part(None, [@text.span("words")])]), "")
}

///|
test "dragged over a heading and a list's items with code in them, ⌘C puts their words and their HTML on the clipboard" {
  let t = Tester::new(
    fn(_) {  },
    tree=fn(root) {
      root.box(fn(page) {
        page.width(Is(Some(360.0))).padding(Is((16.0, 16.0, 16.0, 16.0))).gap(Is(6.0)) |> ignore
        words_picked(page)
        page.box(fn(h) {
          words_shaped(h, fn() { Heading(2) }) |> ignore
          h.words_runs(Is([@text.span("Status", weight=700)])) |> ignore
        })
        |> ignore
        page.box(fn(n) { n.words_runs(Is([@text.span("Working on a Mac:")])) |> ignore }) |> ignore
        for k in 0..<2 {
          page.box(fn(row) {
            words_shaped(row, fn() { Item(1, 0, row.id()) }) |> ignore
            row.box(fn(n) {
              n.words_runs(
                Is(if k == 0 { [@text.span("logs in "), @text.span("/var/log", code=true)] } else { [@text.span("off by default")] }),
              )
              |> ignore
            })
            |> ignore
          })
          |> ignore
        }
      })
      |> ignore
    },
    w=400.0,
    h=300.0,
    platform=0,
  )
  t.run_for(move_most_ms)
  let at = fn(s : String) {
    match t.words().iter().find_first(fn(w) { w.0 == s }) {
      Some(w) => w
      None => @halt.saying("\{s} not drawn: \{Repr(t.words())}")
    }
  }
  let first = at("Status")
  let last = at("off by default")
  t.drag(first.1 + 1.0, first.2 + first.4 / 2.0, last.1 + last.3 - 1.0, last.2 + last.4 / 2.0)
  t.run_for(move_most_ms)
  t.key(key_copy)
  assert_eq(t.clipboard(), "Status\nWorking on a Mac:\nlogs in /var/log\noff by default")
  assert_eq(
    t.clipboard_html(),
    "<h2>Status</h2><p>Working on a Mac:</p><ul><li>logs in <code>/var/log</code></li><li>off by default</li></ul>",
  )
}

///|
test "table copy: TSV with empty cells and multiline escaping, single cell unescaped, HTML merges cross-slice table and closes around prose" {
  let part = fn(shape : WordsShape?, runs : Array[@text.Run]) -> CopiedPart {
    let sb = StringBuilder()
    for r in runs {
      sb.write_string(r.text)
    }
    let text = sb.to_string()
    { shape, runs, text, a: 0, b: text.length() }
  }
  // HTML: prose -> 2-row table with empty col 1 in head and inline code in body -> prose
  let html = copied_html([
    part(None, [@text.span("Before")]),
    part(Some(Cell(7, 0, 0, true)), [@text.span("Name")]),
    part(Some(Cell(7, 0, 2, true)), [@text.span("Note")]),
    part(Some(Cell(7, 1, 0, false)), [@text.span("foo", code=true)]),
    part(Some(Cell(7, 1, 1, false)), [@text.span("bar", weight=700)]),
    part(Some(Cell(7, 1, 2, false)), [@text.span("a\nb")]),
    part(None, [@text.span("After")]),
  ])
  assert_eq(
    html,
    "<p>Before</p><table><tr><th>Name</th><th></th><th>Note</th></tr><tr><td><code>foo</code></td><td><strong>bar</strong></td><td>a<br>b</td></tr></table><p>After</p>",
  )
  // End-to-end Tester: cross-slice table + prose + empty cell + multiline cell + off-screen formatting retention
  let show_row0 = @signals.signal(true)
  let t = Tester::new(
    fn(_) {  },
    tree=fn(root) {
      root.box(fn(page) {
        page.width(Is(Some(360.0))).gap(Is(4.0)) |> ignore
        words_picked(page)
        page.box(fn(n) { n.words_runs(Is([@text.span("Intro")])) |> ignore }) |> ignore
        // Table slice 0 (row 0, head, with col 1 empty)
        page.show(at_once=true, fn() { show_row0.get() }, fn(slot) {
          slot.box(fn(r0) {
            r0.row(Is(true)).gap(Is(8.0)) |> ignore
            r0.box(fn(c0) {
              words_shaped(c0, fn() { Cell(99, 0, 0, true) }) |> ignore
              c0.words_runs(Is([@text.span("H0", weight=700)])) |> ignore
            })
            |> ignore
            r0.box(fn(c2) {
              words_shaped(c2, fn() { Cell(99, 0, 2, true) }) |> ignore
              c2.words_runs(Is([@text.span("H2")])) |> ignore
            })
            |> ignore
          })
          |> ignore
        })
        |> ignore
        // Table slice 1 (row 1, same table_id 99, with multiline cell and inline code)
        page.box(fn(r1) {
          r1.row(Is(true)).gap(Is(8.0)) |> ignore
          r1.box(fn(c0) {
            words_shaped(c0, fn() { Cell(99, 1, 0, false) }) |> ignore
            c0.words_runs(Is([@text.span("line1\nline2")])) |> ignore
          })
          |> ignore
          r1.box(fn(c1) {
            words_shaped(c1, fn() { Cell(99, 1, 1, false) }) |> ignore
            c1.words_runs(Is([@text.span("val", code=true)])) |> ignore
          })
          |> ignore
        })
        |> ignore
        page.box(fn(n) { n.words_runs(Is([@text.span("Outro")])) |> ignore }) |> ignore
      })
      |> ignore
    },
    w=400.0,
    h=300.0,
    platform=0,
  )
  t.run_for(move_most_ms)
  let at = fn(s : String) {
    match t.words().iter().find_first(fn(w) { w.0 == s }) {
      Some(w) => w
      None => @halt.saying("\{s} not drawn: \{Repr(t.words())}")
    }
  }
  // 1. Single multiline cell selected: unescaped plain text
  let multi = at("line1\nline2")
  t.drag(multi.1 + 1.0, multi.2 + 4.0, multi.1 + multi.3 - 1.0, multi.2 + multi.4 - 4.0)
  t.run_for(move_most_ms)
  t.key(key_copy)
  assert_eq(t.clipboard(), "line1\nline2")
  // 2. Full drag Intro -> table -> Outro
  let intro = at("Intro")
  let outro = at("Outro")
  t.drag(intro.1 + 1.0, intro.2 + intro.4 / 2.0, outro.1 + outro.3 - 1.0, outro.2 + outro.4 / 2.0)
  t.run_for(move_most_ms)
  // Unmount slice 0 to verify off-screen cell retains shape & runs on copy
  show_row0.set(false)
  t.run_for(move_most_ms)
  t.key(key_copy)
  assert_eq(t.clipboard(), "Intro\nH0\t\tH2\n\"line1\nline2\"\tval\nOutro")
  assert_eq(
    t.clipboard_html(),
    "<p>Intro</p><table><tr><th><strong>H0</strong></th><th></th><th>H2</th></tr><tr><td>line1<br>line2</td><td><code>val</code></td></tr></table><p>Outro</p>",
  )
}

///|
test "table copy: subsequent rows with empty leading column preserve column alignment in both TSV and HTML" {
  let part = fn(shape : WordsShape?, runs : Array[@text.Run]) -> CopiedPart {
    let sb = StringBuilder()
    for r in runs {
      sb.write_string(r.text)
    }
    let text = sb.to_string()
    { shape, runs, text, a: 0, b: text.length() }
  }
  let html = copied_html([
    part(Some(Cell(11, 0, 0, true)), [@text.span("A")]),
    part(Some(Cell(11, 0, 1, true)), [@text.span("B")]),
    part(Some(Cell(11, 1, 1, false)), [@text.span("only-col1")]),
    part(Some(Cell(11, 2, 2, false)), [@text.span("only-col2")]),
  ])
  assert_eq(
    html,
    "<table><tr><th>A</th><th>B</th></tr><tr><td></td><td>only-col1</td></tr><tr><td></td><td></td><td>only-col2</td></tr></table>",
  )
  // End-to-end Tester: row 0 has col 0 & col 1, row 1 has empty col 0 and text only in col 1
  let t = Tester::new(
    fn(_) {  },
    tree=fn(root) {
      root.box(fn(page) {
        page.width(Is(Some(360.0))).gap(Is(4.0)) |> ignore
        words_picked(page)
        page.box(fn(r0) {
          r0.row(Is(true)).gap(Is(8.0)) |> ignore
          r0.box(fn(c0) {
            words_shaped(c0, fn() { Cell(12, 0, 0, true) }) |> ignore
            c0.width(Is(Some(100.0))).words_runs(Is([@text.span("Col0")])) |> ignore
          })
          |> ignore
          r0.box(fn(c1) {
            words_shaped(c1, fn() { Cell(12, 0, 1, true) }) |> ignore
            c1.width(Is(Some(100.0))).words_runs(Is([@text.span("Col1")])) |> ignore
          })
          |> ignore
        })
        |> ignore
        page.box(fn(r1) {
          r1.row(Is(true)).gap(Is(8.0)) |> ignore
          // col 0 is empty (no words_runs)
          r1.box(fn(c0) { c0.width(Is(Some(100.0))) |> ignore }) |> ignore
          r1.box(fn(c1) {
            words_shaped(c1, fn() { Cell(12, 1, 1, false) }) |> ignore
            c1.width(Is(Some(100.0))).words_runs(Is([@text.span("RightVal")])) |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    w=400.0,
    h=200.0,
    platform=0,
  )
  t.run_for(move_most_ms)
  let at = fn(s : String) {
    match t.words().iter().find_first(fn(w) { w.0 == s }) {
      Some(w) => w
      None => @halt.saying("\{s} not drawn: \{Repr(t.words())}")
    }
  }
  let c0 = at("Col0")
  let rv = at("RightVal")
  t.drag(c0.1 + 1.0, c0.2 + c0.4 / 2.0, rv.1 + rv.3 - 1.0, rv.2 + rv.4 / 2.0)
  t.run_for(move_most_ms)
  t.key(key_copy)
  assert_eq(t.clipboard(), "Col0\tCol1\n\tRightVal")
  assert_eq(t.clipboard_html(), "<table><tr><th>Col0</th><th>Col1</th></tr><tr><td></td><td>RightVal</td></tr></table>")
}
