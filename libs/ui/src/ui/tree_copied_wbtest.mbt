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
