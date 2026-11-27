// The way in as nodes of the window's tree (way_in's, way_in_page's and their parts' made-once form): a page of the way
// in, its picture's foot a little over the page's middle whatever is under it; its title, what it says, its buttons
// (the ink's pill across a touch screen's page, 300 on a desktop's; a spinner's room opening before their words at
// work, their words changed going to their place; a press's ripple), what it says of signing in under its button
// opening and closing with its room, and what it says last.

///|
/// A page of the way in in `parent` (way_in_page's): its picture (`art`, a drawable) over what `body` says and offers,
/// all of it down the middle of the page, 30 in from its sides; the picture as wide as a button at most and never past
/// the page's sides, its foot 0.42 of the way down the page and 12 more (as the old one's room above it puts it) or,
/// where that leaves no room above it, 52 down. What `body` is given: a column 12 apart, its things in its middle, no
/// wider than a tablet's button. `middle`: the picture and what `body` holds together in the middle of the page's
/// height instead, as much room over the picture as under what `body` holds (a page of a picture and one button, a
/// desktop's sign-in: its picture's foot at 0.42 leaves them well over the middle). The page's node.
#callsite(autofill(loc))
pub fn way_in_page_node(
  parent : @view.View,
  art : () -> String,
  body : (@view.View) -> Unit,
  middle? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(page) {
    page
    .width_share(Is(1.0))
    .height_share(Is(1.0))
    .padding(Is((sign_in_side_w, 0.0, sign_in_side_w, 0.0)))
    .gap(Is(@ui.Space::px(S3)))
    .lines_up(Is(Some(Middle)))
    |> ignore
    // (where the old one's room above its picture was: nothing tall, the page's gap after it, the picture's foot where
    // the page's share and that gap put it, or as low as its top and its own height do where that is lower)
    // (`middle`: the room left shared alike over the picture and under the column, in place of the picture's share)
    page.box(fn(g) { (if middle { g.grow(Is(1.0)) } else { g.height(Is(Some(0.0))) }) |> ignore }) |> ignore
    page.box(fn(head) {
      head
      .width_share(Is(1.0))
      .min_height_share(Is(if middle { None } else { Some(way_in_picture_foot) }))
      .padding(Is((0.0, way_in_page_top, 0.0, 0.0)))
      .lines_up(Is(Some(Middle)))
      |> ignore
      head.box(fn(s) { s.grow(Is(1.0)) |> ignore }) |> ignore
      // (as wide as the page's column at most and a button's: the picture as wide as that, as tall as it is drawn so)
      head.box(fn(room) {
        room.width_share(Is(1.0)).max_width(Is(Some(sign_in_picture_w))) |> ignore
        room.box(fn(p) {
          p
          .width_share(Is(1.0))
          .aspect(By(fn() { way_in_art_aspect(art()) }))
          .picture(By(fn() { drawable_vector(art()) }))
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
    page.box(fn(col) {
      col
      .width_share(Is(1.0))
      .max_width(Is(Some(sign_in_touch_w)))
      .gap(Is(@ui.Space::px(S3)))
      .lines_up(Is(Some(Middle)))
      // (`middle`: what `body` holds leaves the room under it itself, as much as is over the picture)
      .padding(Is((0.0, 0.0, 0.0, if middle { 0.0 } else { way_in_page_top })))
      |> ignore
      body(col)
    })
    |> ignore
    if middle {
      // (as much under the column as over the picture, and as much again as the picture leaves blank over what it
      // draws, so what is seen has the same room over it as under it: that blank as tall as the picture's is, as
      // wide as the picture is laid out)
      page.box(fn(g) {
        g.width_share(Is(1.0)).grow(Is(1.0)).lines_up(Is(Some(Middle))) |> ignore
        g.box(fn(blank) {
          blank
          .width_share(Is(1.0))
          .max_width(Is(Some(sign_in_picture_w)))
          .aspect(By(fn() { 1.0 / way_in_art_blank(art()) }))
          |> ignore
        })
        |> ignore
      })
      |> ignore
    }
  })
}

///|
/// How tall the blank over what drawable `name` draws is for how wide the drawable is (its paths' highest point, their
/// lines' width aside; next to nothing where it draws from its top or there is none so named).
fn way_in_art_blank(name : String) -> Double {
  guard drawables.val.get(name) is Some(d) && d.w > 0.0 else { return 1.0e-6 }
  let mut top = d.h
  for l in d.layers {
    for sub in l.outlines(1.0, 1.0) {
      let pts = sub.0
      let mut j = 1
      while j < pts.length() {
        if pts[j] < top {
          top = pts[j]
        }
        j += 2
      }
    }
  }
  if top > 0.0 { top / d.w } else { 1.0e-6 }
}

///|
/// How wide drawable `name` is for how tall (1: none so named, drawn square).
fn way_in_art_aspect(name : String) -> Double {
  match drawables.val.get(name) {
    Some(d) if d.h > 0.0 => d.w / d.h
    _ => 1.0
  }
}

///|
/// The words of a way-in page's part, as `size`, `weight` and `line` say in the window's theme (None: the size's own
/// line; the font's: none said, the font's own, as an old view's text sets it), wrapping or not.
fn way_in_words(size : @ui.TextSize, weight : Int, line : @ui.Leading?, wrap : Bool) -> @view.WordsLook {
  let th = @ui.tree_theme()
  let (px, own) = th.text_size(size)
  let line = match line {
    None => own
    Some(l) => th.leading(l).unwrap_or(0.0)
  }
  { size: px, weight, line, wrap, tracking: @view.letters_own, balance: false, max_lines: 0 }
}

///|
/// A way-in page's title in `body` (way_in_title's): 10 under what is above it, 28, bold, in the ink, in its middle,
/// as wide as the page's column. The node.
#callsite(autofill(loc))
pub fn way_in_title_node(body : @view.View, title : () -> String, loc~ : SourceLoc) -> @view.View {
  body.box(made_for=loc, fn(b) {
    b.width_share(Is(1.0)).padding(Is((0.0, @ui.Space::px(S2_5), 0.0, 0.0))) |> ignore
    b.box(fn(w) {
      w
      .width_share(Is(1.0))
      .words(By(title), look=way_in_words(sign_in_title_size, 700, Some(Font), true))
      .words_centered(Is(true))
      .ink(By(fn() { @ui.tree_theme().color(Fg) }))
      |> ignore
    })
    |> ignore
  })
}

///|
/// What a way-in page says under its title in `body` (way_in_note's): the body's size, muted, in its middle. The node.
#callsite(autofill(loc))
pub fn way_in_note_node(body : @view.View, note : () -> String, loc~ : SourceLoc) -> @view.View {
  body.box(made_for=loc, fn(w) {
    w
    .width_share(Is(1.0))
    .words(By(note), look=way_in_words(Body, 400, None, true))
    .words_centered(Is(true))
    .ink(By(fn() { @ui.tree_theme().color(Muted) }))
    |> ignore
  })
}

///|
/// A way-in page's button in `body` (way_in_button's): 50 high, a pill across a touch screen's page (420 at most), 300
/// on a desktop's; `solid` the ink's, the one thing to do, a step towards the page under the pointer or pressed, else
/// the quiet ground of the words' colour, a step darker so; `busy` while what it does is under way: a spinner's room
/// opening before its words (a Move, as a button's), the spinner turning in it, not pressed. A press's ripple from
/// where it went down, the pill sinking under it. Its words changed, they go to their new place (moves_for, by
/// its words). `press` done as it is pressed. Read out a button. The node.
#callsite(autofill(loc))
pub fn way_in_button_node(
  body : @view.View,
  label : () -> String,
  press : () -> Unit,
  solid? : Bool = true,
  busy? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> @view.View {
  let bare = native_input() is Mouse
  let rippled : Ref[PressLook?] = Ref(None)
  let hold = ripple_hold(rippled, fn() { !busy() })
  @headless.button(made_for=loc, body, label, fn(_) { press() }, disabled=busy, hold~, fn(v, b) {
    v.focus_ring_theme() |> ignore
    let theme = fn() { @ui.tree_theme() }
    let lit = fn() { b.hovered() || b.pressed() }
    let ground = fn() {
      let t = theme()
      match (solid, lit()) {
        (true, false) => t.color(Fg)
        (true, true) => t.color(Over(Fg, A(Bg, O15)))
        (false, false) => t.color(Tint)
        (false, true) => t.color(TintStrong)
      }
    }
    let ink = fn() { theme().color(if solid { Bg } else { Fg }) }
    let turning = @motion.NodeWay::new(if @signals.untracked(busy) { 1.0 } else { 0.0 })
    let open = @motion.NodeWay::new(if @signals.untracked(busy) { 1.0 } else { 0.0 })
    v.reacts(busy, fn(on) {
      turning.go_ms(v, if on { 1.0 } else { 0.0 }, dur_ms)
      open.go(v, if on { 1.0 } else { 0.0 }, button_reshape)
    })
    v
    .row(Is(true))
    .width_share(Is(1.0))
    .max_width(Is(Some(if bare { sign_in_desk_w } else { sign_in_touch_w })))
    // (50 high at least, taller where its words take two lines: at a large size of words a long label, 「Create my own
    // workspace instead」 at 1.3, is wider than the pill and goes on to a second line in it, never past its end)
    .min_height(Is(Some(sign_in_button_h)))
    .padding(Is((sign_in_button_padx, sign_in_button_pady, sign_in_button_padx, sign_in_button_pady)))
    // (a pill: as round as one line's height, as the old one's radius=Full and its press's ripple (press_look below);
    // grown to two lines, its corners keep that round, never rounder than its words' corners leave room for)
    .radius(Is(sign_in_button_h / 2.0))
    .lines_up(Is(Some(Middle)))
    .ground(By(ground))
    |> ignore
    // (what it holds in its middle: the old one's justify=JCenter)
    v.box(fn(s) { s.grow(Is(1.0)) |> ignore }) |> ignore
    v.show(fn() { busy() || open.shown(v) > 0.0 }, fn(room) {
      spin_room_node(room, fn() { sign_in_spin_gap }, fn() { open.shown(v) })
      // (in the library's palette's ink and accent, as the old one's spinner is: way_in_button's p.bg, p.text)
      let spun_ink = fn() {
        let p = library_theme().p
        if solid {
          p.bg
        } else {
          p.text
        }
      }
      spinner_shown_node(
        room,
        fn() { alpha(spun_ink(), 0.3) },
        fn() { if solid { spun_ink() } else { library_theme().p.accent } },
        fn() { turning.shown(v) },
        fn() { open.shown(v) },
        At(0.0, 0.5),
      )
      |> ignore
    })
    // (giving way in the row where it is wider than the pill's room, its lines in their middle)
    let words = v.box(fn(w) {
      // (its look as the theme has it as it is made, as button_node's words' is)
      let look = @signals.untracked(fn() { way_in_words(Title, 600, Some(Font), true) })
      w
      .shrink(Is(1.0))
      .min_width(Is(Some(0.0)))
      .words(By(label), look~)
      .words_centered(Is(true))
      .ink(By(ink))
      |> ignore
    })
    v.box(fn(s) { s.grow(Is(1.0)) |> ignore }) |> ignore
    // (a press's ripple from where it went down, the pill sinking under it: SignIn.kt's clip(CircleShape).clickable)
    // (handed it by the headless button's hold: ripple_hold)
    rippled.val = Some(press_look(v, Is(sign_in_button_h / 2.0), fn() { true }))
    // (its words changed, 登录或注册 to 正在登录: gone to their new place, not at once)
    @motion.moves_for(v, label, spec=button_reshape).moves_with(words)
  })
}

///|
/// The way into an app, signed out, in `parent` (way_in's): its picture (`art`), what it is (`title`, `note`), its button
/// (`label`; `busy` while it is under way), what to know of it (`foot`), and what there is to say of signing in under
/// the button (`said`: what it waits on, or why it failed, in the red), coming and going with its room (its words kept as
/// it closes). Keyboard and mouse's the picture, the button and what is said of it alone, the picture and the button in
/// the middle of the page's height (way_in_page_node's `middle`); a touch screen's all of it.
/// `press` done as its button is pressed. The page's node.
#callsite(autofill(loc))
pub fn way_in_node(
  parent : @view.View,
  art : () -> String,
  title : () -> String,
  note : () -> String,
  label : () -> String,
  foot : () -> String,
  press : () -> Unit,
  busy? : () -> Bool = fn() { false },
  said? : () -> (String, Bool) = fn() { ("", false) },
  loc~ : SourceLoc,
) -> @view.View {
  let bare = native_input() is Mouse
  way_in_page_node(loc~, parent, art, middle=bare, fn(col) {
    if !bare {
      way_in_title_node(col, title) |> ignore
      way_in_note_node(col, note) |> ignore
    }
    col.box(fn(g) { g.height(Is(Some(@ui.Space::px(S1_5)))) |> ignore }) |> ignore
    way_in_button_node(col, label, press, busy~) |> ignore
    // (the page's middle held, a keyboard and mouse's: what is said under the button opens in the room the page leaves
    // under it, as tall with the column's gap as the room over the picture, so the picture and the button stay where
    // they are as a line of it opens and closes; taller than that room, it takes what it needs)
    let col = if bare {
      col.box(fn(under) {
        under
        .width_share(Is(1.0))
        .min_height(Is(Some(way_in_page_top - @ui.Space::px(S3))))
        .lines_up(Is(Some(Middle)))
        |> ignore
      })
    } else {
      col
    }
    // (what was last said, kept as its room closes under it)
    let kept = @signals.signal(@signals.untracked(said), same=fn(a, b) { a == b })
    col.reacts(said, fn(s) {
      if s.0 != "" {
        kept.set(s)
      }
    })
    let room = @motion.reveal_node(col, fn() { said().0 != "" }, fn(r) {
      r.box(fn(w) {
        w
        .width_share(Is(1.0))
        .words(By(fn() { kept.get().0 }), look=way_in_words(Meta, 400, None, true))
        .words_centered(Is(true))
        .ink(By(fn() { @ui.tree_theme().color(if kept.get().1 { Danger } else { Muted }) }))
        |> ignore
      })
      |> ignore
    })
    // (as wide as the page's column, as the old one's room: what it holds in its middle, cut at its sides)
    room.width_share(Is(1.0)) |> ignore
    if !bare {
      col.box(fn(f) {
        f.words(By(foot), look=way_in_words(Meta, 400, Some(Font), false)).ink(By(fn() { @ui.tree_theme().color(Muted) })) |> ignore
      })
      |> ignore
    }
  })
}

///|
/// The library's theme (theme's: its palette), where a part calls the window's tree's its `theme`.
fn library_theme() -> Theme {
  theme()
}
