// The theme the window's tree's nodes are drawn in (tree_theme): the one the frame picks for the window's width, read
// so in the first frame drawn at another width, what read it told; where the app tells its tree none, the one it sets
// as it builds (Ctx::set_theme), taken in the frame that sets it, the first one too, never a frame late
// (view_told_as_built).

///|
test "a node drawn in the tree's theme: the wide one's, then in the first frame at a narrow width the narrow one's" {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=200.0)
  t.check_looks(false)
  let wide = { ..Theme::light(), focus: 0x112233FFL }
  let narrow = { ..Theme::light(), focus: 0x445566FFL }
  let id : Ref[@view.NodeId?] = Ref(None)
  set_view_app(fn(root) {
    root.box(fn(n) {
      id.val = Some(n.id())
      n.width(Is(Some(40.0))).height(Is(Some(40.0))).ground(By(fn() { tree_theme().focus })) |> ignore
    })
    |> ignore
  })
  t.ctx().set_theme(wide, narrow~, narrow_below=300.0)
  t.draw()
  let tree = view_app.val.unwrap()
  assert_eq(tree.drawn_of(id.val.unwrap()).unwrap().ground, 0x112233FFL, msg="wide")
  t.resize(250.0, 200.0)
  assert_eq(tree.drawn_of(id.val.unwrap()).unwrap().ground, 0x445566FFL, msg="the first frame at the narrow width")
}

///|
test "words set as the tree's theme says: in the first frame at a narrow width, as big and as tall a line as the narrow one's, laid out and drawn so; wrapped where they no longer fit" {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=200.0)
  t.check_looks(false)
  let base = Theme::light()
  let wide = { ..base, text: { ..base.text, meta: (12.0, 16.0) } }
  let narrow = { ..base, text: { ..base.text, meta: (24.0, 30.0) } }
  let id : Ref[@view.NodeId?] = Ref(None)
  set_view_app(fn(root) {
    root.box(fn(n) {
      id.val = Some(n.id())
      n
      .width(Is(Some(120.0)))
      .words(Is("ab cd ef gh ij"))
      .words_look(By(fn() {
        let (size, line) = tree_theme().text_size(Meta)
        { size, weight: 400, line, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 }
      }))
      |> ignore
    })
    |> ignore
  })
  t.ctx().set_theme(wide, narrow~, narrow_below=300.0)
  t.draw()
  let tree = view_app.val.unwrap()
  let d = tree.drawn_of(id.val.unwrap()).unwrap()
  assert_eq((d.words_look.size, d.h), (12.0, 16.0), msg="wide: one line of its")
  t.resize(250.0, 200.0)
  let d = tree.drawn_of(id.val.unwrap()).unwrap()
  assert_eq(d.words_look.size, 24.0, msg="narrow: its size")
  assert_true(d.h >= 60.0, msg="narrow: its lines, wrapped (\{d.h})")
}

///|
/// still.fail's ranges for what follows a corner (Theme::corner_fit).
let built_fit : CornerFit = { least: 6.0, most: 34.0, near: 4.0, far: 16.0 }

///|
/// A window 400 by 200, its corner 16, whose old frame sets the theme `theme` gives as each build runs (counted in
/// `builds`) and whose tree tells none: a box 14 in following the window's corner 9 in (concentric there 2, squarer
/// than still.fail's ranges let it be: alone, 9, where they hold), grounded in the theme's focus colour (its binding's
/// runs counted in `grounds`), and the words "12345" (digits set 0.5 em wider all one width). The box's node and the
/// words'.
fn built_theme_tester(
  theme : () -> Theme,
  builds : Ref[Int],
  grounds : Ref[Int],
) -> (Tester, Ref[@view.View?], Ref[@view.View?]) {
  let boxed : Ref[@view.View?] = Ref(None)
  let said : Ref[@view.View?] = Ref(None)
  let look : @view.WordsLook = {
    size: 15.0,
    weight: 400,
    line: 22.0,
    wrap: false,
    tracking: @view.letters_own,
    balance: false,
    max_lines: 0,
  }
  let t = Tester::new(
    fn(c) {
      builds.val = builds.val + 1
      c.set_theme(theme())
    },
    w=400.0,
    h=200.0,
    window_corner=16.0,
    begun=fn() { fake.val.unwrap().tabular = 0.5 },
    tree=fn(root) {
      // (the words as wide as they are set, not as the window)
      root.lines_up(Is(Some(Start))) |> ignore
      root.box(fn(n) {
        boxed.val = Some(n)
        n
        .over(Is(true))
        .offset(Is((14.0, 14.0)))
        .width(Is(Some(60.0)))
        .height(Is(Some(40.0)))
        .radius(corner_of(Follow(Window, 14.0, 9.0)))
        .ground(
          By(fn() {
            grounds.val = grounds.val + 1
            tree_theme().focus
          }),
        )
        |> ignore
      })
      |> ignore
      root.box(fn(n) {
        said.val = Some(n)
        n.offset(Is((14.0, 100.0))).words(Is("12345"), ink=0x333333FFL, look~) |> ignore
      })
      |> ignore
    },
  )
  (t, boxed, said)
}

///|
/// How the box (its ground, its radius) and the words (how wide) are drawn now.
fn built_theme_drawn(boxed : Ref[@view.View?], said : Ref[@view.View?]) -> (Int64, Double, Double) {
  let tree = view_app.val.unwrap()
  let b = tree.drawn_of(boxed.val.unwrap().id()).unwrap()
  let w = tree.drawn_of(said.val.unwrap().id()).unwrap()
  (b.ground, b.radius, w.w)
}

///|
test "the theme the app sets as it builds its first frame: its tree drawn in it in that frame, its colour, its corner's ranges and its digits, none a frame late" {
  let first = { ..Theme::light(), tabular: true, focus: 0x112233FFL, corner_fit: Some(built_fit) }
  let (t, boxed, said) = built_theme_tester(fn() { first }, Ref(0), Ref(0))
  // (the first frame alone drawn: nothing it drew owed another)
  let frames = t.frames
  let (ground, radius, wide) = built_theme_drawn(boxed, said)
  let style = view_words_style()
  // (as drawn by frames after it)
  t.draw()
  let later = built_theme_drawn(boxed, said)
  // (as wide as words drawn so from the start, the app telling its tree the theme as it makes it)
  let t2 = Tester::new(fn(_c) {  }, w=400.0, h=200.0)
  t2.tabular_wider(0.5)
  let fresh : Ref[@view.View?] = Ref(None)
  set_view_app(fn(root) {
    set_tree_theme(fn() { first })
    root.lines_up(Is(Some(Start))) |> ignore
    root.box(fn(n) {
      fresh.val = Some(n)
      n
      .offset(Is((14.0, 100.0)))
      .words(Is("12345"), ink=0x333333FFL, look={
        size: 15.0,
        weight: 400,
        line: 22.0,
        wrap: false,
        tracking: @view.letters_own,
        balance: false,
        max_lines: 0,
      })
      |> ignore
    })
    |> ignore
  })
  t2.draw()
  let fresh_w = view_app.val.unwrap().drawn_of(fresh.val.unwrap().id()).unwrap().w
  assert_eq(frames, 1, msg="one frame drawn as the tester began")
  assert_eq(style, @hostapi.style_tabular, msg="its words' digits all one width in the first frame")
  assert_eq((ground, radius, wide), (0x112233FFL, 9.0, fresh_w), msg="the first frame in the theme set")
  assert_eq(later, (ground, radius, wide), msg="the frames after as the first")
}

///|
test "a theme the app makes anew each build, the same as the last: nothing that reads the tree's theme worked out again, its words not measured again" {
  let builds = Ref(0)
  let grounds = Ref(0)
  let again = @signals.signal(0, same=fn(a, b) { a == b })
  let (t, _, said) = built_theme_tester(
    fn() {
      // (what the old frame reads: built again as it changes)
      again.get() |> ignore
      { ..Theme::light(), tabular: true }
    },
    builds,
    grounds,
  )
  let builds0 = builds.val
  let grounds0 = grounds.val
  let words0 = said.val.unwrap().words_redone()
  for i in 1..=3 {
    again.set(i)
    t.draw()
  }
  assert_true(builds.val > builds0, msg="the old frame built again: \{builds0} then \{builds.val}")
  assert_eq(grounds.val, grounds0, msg="the ground's binding not run again")
  assert_eq(said.val.unwrap().words_redone(), words0, msg="the words not measured again")
}

///|
test "the theme the app switches as it builds: its tree drawn in the new one in the first frame after, its colour and its digits, not a frame late" {
  let dark = @signals.signal(false, same=fn(a, b) { a == b })
  let light = { ..Theme::light(), tabular: false, focus: 0x112233FFL }
  let night = { ..Theme::dark(), tabular: true, focus: 0x445566FFL }
  let (t, boxed, said) = built_theme_tester(fn() { if dark.get() { night } else { light } }, Ref(0), Ref(0))
  let (ground0, _, narrow) = built_theme_drawn(boxed, said)
  let seen : Array[(Int64, Double)] = []
  t.each_frame(
    Some(fn() {
      let (ground, _, w) = built_theme_drawn(boxed, said)
      seen.push((ground, w))
    }),
  )
  dark.set(true)
  t.draw()
  t.each_frame(None)
  assert_true(seen.length() > 0, msg="a frame drawn")
  let (ground, wide) = seen[0]
  assert_eq(ground, 0x445566FFL, msg="the first frame after in the dark theme's colour: \{Repr(seen)}")
  assert_true(wide > narrow, msg="the first frame after with its digits all one width: \{narrow} then \{Repr(seen)}")
  assert_true(seen.iter().all(fn(s) { s == (ground, wide) }), msg="each frame after as the first: \{Repr(seen)}")
  assert_eq(ground0, 0x112233FFL, msg="light at first")
}
