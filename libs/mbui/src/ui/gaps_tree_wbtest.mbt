// The spacing rules held of the window's tree's nodes too (gaps.mbt, Ctx::with_tree_nodes), as of an old view's: a
// page made as nodes broke them unseen till 2026-11-14 (a terminal's 只看/控制 right on its card). Rule 9: blocks that
// show their edges never meet each other, nor words or a drawing, whatever boxes lay them out.

///|
/// A page of the tree, 400 wide, its ground white, 16 in, `gap` between what it lays out down it: a row holding a
/// control's track (160×36, its own ground) and, under it, a card (its own dark ground) 120 high; `split`: the track
/// in a row of its own and the card in a box of its own, as a page's list lays its blocks, else both the page's.
fn tree_page(gap : Double, split? : Bool = true) -> Tester {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=400.0, platform=0)
  set_view_app(fn(root) {
    root.box(fn(page) {
      page.width(Is(Some(400.0))).height(Is(Some(400.0))).pad(Is(16.0)).ground(Is(0xFFFFFFFFL)).gap(Is(gap)) |> ignore
      let track = fn(v : @view.View) {
        v.box(fn(k) {
          k.width(Is(Some(160.0))).height(Is(Some(36.0))).ground(Is(0xEEEEEEFFL)).radius(Is(18.0)) |> ignore
        })
        |> ignore
      }
      let card = fn(v : @view.View) {
        v.box(fn(k) { k.height(Is(Some(120.0))).ground(Is(0x16171AFFL)).radius(Is(12.0)) |> ignore }) |> ignore
      }
      if split {
        page.box(fn(r) {
          r.row(Is(true)) |> ignore
          track(r)
        })
        |> ignore
        page.box(fn(b) { card(b) }) |> ignore
      } else {
        track(page)
        card(page)
      }
    })
    |> ignore
  })
  t.draw()
  t
}

///|
fn tree_rule(t : Tester, rule : String) -> Array[String] {
  t.gap_faults().filter(fn(f) { f.has_prefix(rule + ":") })
}

///|
test "spacing on the window's tree: a control's track right on the card under it, each in a box of its own, said (rule 9); 12 apart, nothing" {
  let meet = tree_rule(tree_page(0.0), "rule 9")
  let apart = tree_rule(tree_page(12.0), "rule 9")
  assert_eq((meet.length(), apart), (1, []), msg=meet.join("\n"))
}

///|
test "spacing on the window's tree: the same two in one box, rule 3's (not said again by rule 9); and 7 apart, off the scale, rule 6's" {
  let t = tree_page(0.0, split=false)
  let (three, nine) = (tree_rule(t, "rule 3"), tree_rule(t, "rule 9"))
  let six = tree_rule(tree_page(7.0, split=false), "rule 6")
  assert_eq((three.length(), nine, six.length()), (1, [], 1), msg=(three + six).join("\n"))
}

///|
/// A message as the old view laid it (#6285): its words, a file's card (its ground in a box with none round it) and a
/// line under it, `gap` apart down one column.
fn old_message(gap : Double) -> Tester {
  Tester::new(
    fn(c) {
      c.box(w=Px(360.0), pad=16.0, bg=0xFFFFFFFFL, gap~, fn() {
        c.text("words of the message") |> ignore
        c.box(fn() { c.box(w=Px(240.0), h=Px(56.0), radius=12.0, bg=0xEEEEEEFFL, fn() {  }) |> ignore }) |> ignore
        c.text("you chose it") |> ignore
      })
      |> ignore
    },
    w=400.0,
    h=300.0,
  )
}

///|
test "spacing: a message's words right on a file's card over and under it, the card in a box with no ground, said twice (rule 9); 8 apart, nothing" {
  let meet = old_message(0.0)
  meet.frame()
  let said = tree_rule(meet, "rule 9")
  let apart = old_message(8.0)
  apart.frame()
  assert_eq((said.length(), tree_rule(apart, "rule 9")), (2, []), msg=said.join("\n"))
}

///|
/// A bar of the tree, 400 wide, 44 high, its own ground: a row of words `title_in` in from its start (its row's
/// padding), and at its end a button's room (32, no ground at rest) `end_in` from its end, its icon (16) in its middle.
fn tree_bar(title_in : Double, end_in : Double) -> Tester {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=100.0, platform=0)
  set_view_app(fn(root) {
    root.box(fn(bar) {
      bar.width(Is(Some(400.0))).height(Is(Some(44.0))).row(Is(true)).ground(Is(0xFFFFFFFFL)).lines_up(Is(Some(Middle)))
      .padding(Is((4.0, 0.0, end_in, 0.0)))
      |> ignore
      bar.box(fn(r) {
        r.grow(Is(1.0)).row(Is(true)).padding(Is((title_in - 4.0, 0.0, 0.0, 0.0))) |> ignore
        r.box(fn(w) { w.words(Is("A title")) |> ignore }) |> ignore
      })
      |> ignore
      bar.box(fn(k) {
        k.width(Is(Some(32.0))).height(Is(Some(32.0))).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
        k.box(fn(i) {
          i
          .width(Is(Some(16.0)))
          .height(Is(Some(16.0)))
          .shapes(Is([@paint.shape_of([([0.0, 0.0, 16.0, 0.0, 16.0, 16.0, 0.0, 16.0], true)], fill=0x000000FFL)]))
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "spacing on the window's tree: a bar's title and its last button's icon as far in, the button's room nearer its end, nothing (rule 4); the icon nearer, said" {
  // (title 20 in; the button's room 6 from the end, its icon 14: said; 12 from it, its icon 20: what is seen as far in)
  let near = tree_rule(tree_bar(20.0, 6.0), "rule 4")
  let even = tree_rule(tree_bar(20.0, 12.0), "rule 4")
  assert_eq((near.length(), even), (1, []), msg=near.join("\n"))
}

///|
/// A 16 by 16 mark of the window's tree (its own drawing, told by tree_marks_at, not by the node's shapes).
fn panel_mark(v : @view.View) -> Unit {
  v.box(fn(i) {
    i
    .width(Is(Some(16.0)))
    .height(Is(Some(16.0)))
    .shapes(Is([@paint.shape_of([([0.0, 0.0, 16.0, 0.0, 16.0, 16.0, 0.0, 16.0], true)], fill=0x000000FFL)]))
    |> ignore
  })
  |> ignore
}

///|
/// A panel of the tree, 320 wide, 24 round, 6 in: `above` laid first in it, then two rows 44 high, 18 round, that light
/// up under the hand, 10 in to what they hold (a mark first where `marked`, 12 before the words), then `below`.
fn list_panel(
  marked : Bool,
  above : (@view.View) -> Unit,
  below : (@view.View) -> Unit,
) -> Tester {
  let t = Tester::new(
    fn(c) { c.with_theme({ ..Theme::light(), lit_apart: 2.0, lit_reach: 6.0 }, fn() {  }) },
    w=400.0,
    h=400.0,
    corners_held=false,
    tree=fn(root) {
      root.box(fn(panel) {
        panel
        .width(Is(Some(320.0)))
        .padding(Is((6.0, 6.0, 6.0, 6.0)))
        .gap(Is(2.0))
        .ground(Is(0xFFFFFFFFL))
        .radius(Is(24.0))
        |> ignore
        above(panel)
        for i in 0..<2 {
          panel.box(fn(row) {
            row
            .width(Is(Some(308.0)))
            .height(Is(Some(44.0)))
            .radius(Is(18.0))
            .row(Is(true))
            .lines_up(Is(Some(Middle)))
            .gap(Is(12.0))
            .padding(Is((10.0, 0.0, 10.0, 0.0)))
            .on_press(fn() {  })
            .says(Is(Some(@view.said(Button, label="row \{i}"))))
            .ground(By(fn() { if row.pointed() || row.pressed() { 0xEEEEEEFFL } else { 0L } }))
            |> ignore
            if marked {
              panel_mark(row)
            }
            row.box(fn(w) { w.words(Is("row \{i}")) |> ignore }) |> ignore
          })
          |> ignore
        }
        below(panel)
      })
      |> ignore
    },
  )
  t.draw()
  t
}

///|
/// Words `x` in from the panel's left (its padding 6 and a box's), as a section's heading stands.
fn panel_words_at(x : Double, words : String) -> (@view.View) -> Unit {
  fn(v) {
    v.box(fn(b) {
      b.padding(Is((x - 6.0, 0.0, 0.0, 0.0))) |> ignore
      b.box(fn(w) { w.words(Is(words)) |> ignore }) |> ignore
    })
    |> ignore
  }
}

///|
/// A mark `x` in from the panel's left, on a line of its own.
fn panel_mark_at(x : Double) -> (@view.View) -> Unit {
  fn(v) {
    v.box(fn(b) {
      b.padding(Is((x - 6.0, 0.0, 0.0, 0.0))) |> ignore
      panel_mark(b)
    })
    |> ignore
  }
}

///|
test "spacing on the window's tree: rows' marks set their words' line (rule 8), a heading and a mark as far in say nothing; 10 in, said" {
  // (the rows' marks 16 in (6 + 10), their words 44)
  let even = tree_rule(list_panel(true, panel_words_at(16.0, "a heading"), panel_mark_at(16.0)), "rule 8")
  let heading = tree_rule(list_panel(true, panel_words_at(10.0, "a heading"), panel_mark_at(16.0)), "rule 8")
  let mark = tree_rule(list_panel(true, panel_words_at(16.0, "a heading"), panel_mark_at(10.0)), "rule 8")
  assert_eq((even, heading.length(), mark.length()), ([], 1, 1), msg=(heading + mark).join("\n"))
}

///|
/// A block as wide as the rows and as far in, 18 round, its own ground at rest (a row opened in place to its body):
/// `inner` in to its words, and words 20 further in under them.
fn panel_opened_row(inner : Double) -> (@view.View) -> Unit {
  fn(v) {
    v.box(fn(b) {
      b
      .width(Is(Some(308.0)))
      .radius(Is(18.0))
      .ground(Is(0xE4E4E8FFL))
      .padding(Is((inner, 10.0, inner, 10.0)))
      .gap(Is(4.0))
      |> ignore
      b.box(fn(w) { w.words(Is("opened words")) |> ignore }) |> ignore
      b.box(fn(d) {
        d.padding(Is((20.0, 0.0, 0.0, 0.0))) |> ignore
        d.box(fn(w) { w.words(Is("its body")) |> ignore }) |> ignore
      })
      |> ignore
    })
    |> ignore
  }
}

///|
/// A tag 80 by 24, 8 round, its own ground, at the panel's left (6 in).
fn panel_tag(v : @view.View) -> Unit {
  v.box(fn(b) { b.width(Is(Some(80.0))).height(Is(Some(24.0))).radius(Is(8.0)).ground(Is(0xE4E4E8FFL)) |> ignore })
  |> ignore
}

///|
test "spacing on the window's tree: a row opened in place with a ground at rest is the rows' (rule 8), what it holds on their words' line; 4 in, said; a tag at the edge, said" {
  // (the rows' words 16 in (6 + 10); the opened row 6 in as they are, its words 16 and 36 in)
  let none = fn(_v : @view.View) {  }
  let even = tree_rule(list_panel(false, none, panel_opened_row(10.0)), "rule 8")
  let short = tree_rule(list_panel(false, none, panel_opened_row(4.0)), "rule 8")
  let tag = tree_rule(list_panel(false, panel_tag, panel_opened_row(10.0)), "rule 8")
  assert_eq(
    (even, short.length(), short.all(fn(f) { f.contains("stands 10 ") }), tag.length()),
    ([], 1, true, 1),
    msg=(short + tag).join("\n"),
  )
}
