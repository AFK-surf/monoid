// Cards, rows and what parts them.
//
// A card is 12 round and keeps 6 round what it holds, so a row or a button in its corner is 6 round, concentric with
// it. A row is one line high by its size (28, 36, 48) and grows by its words: where they take several lines, its icon
// before them and what ends it (a time, a tag, a switch) stay on its first line, in a box as tall as that line and
// centred in it, never on the middle of the row; a second line starts where the first line's words do.
//
// A column of parts some of which may be hidden (`divided_column`) draws a line only after a part that shows and
// before the next that does: hiding any of them, the first, the last, or one between, leaves no line doubled and none
// hanging at either end; what hides makes its way out as a structure of mbui's does, and the line before it with it.

///|
/// A card in `parent`: the panel's ground, 12 round, its edge a hairline, keeping `inset` round what `make` puts in it
/// (6: a row's or a button's corner in it is 6 round). The node.
#callsite(autofill(loc))
pub fn card(
  parent : @view.View,
  make : (@view.View) -> Unit,
  inset? : Space = card_inset,
  gap? : Space = S0,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(c) {
    c
    .radius(Is(card_radius))
    .padding(Is(pad_all(inset)))
    .gap(Is(gap.pt()))
    .ground(By(fn() { palette().panel }))
    .edge(By(fn() { (1.0, palette().hairline) }))
    |> ignore
    make(c)
  })
}

///|
/// A card's heading and the words under it, as far in as its rows' words. The node.
#callsite(autofill(loc))
pub fn card_head(
  parent : @view.View,
  title : () -> String,
  note? : () -> String,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(h) {
    h.padding(Is(pad(S8, S8, S8, S8))).gap(Is(S2.pt())) |> ignore
    text_node(h, title, Heading, fn() { palette().ink }, weight=weight_medium, wrap=true) |> ignore
    match note {
      Some(n) => text_node(h, n, Body, fn() { palette().muted }, wrap=true) |> ignore
      None => ()
    }
  })
}

///|
/// How tall a row of one line is.
#derive(Eq, Debug)
pub(all) enum RowSize {
  /// 28: a dense list, a menu's
  RowSm
  /// 36: a list on a desktop's page
  RowMd
  /// 48: a list for a finger
  RowLg
}

///|
/// How tall a row of one line is.
pub fn RowSize::height(self : RowSize) -> Double {
  match self {
    RowSm => 28.0
    RowMd => 36.0
    RowLg => 48.0
  }
}

///|
/// A row in `parent` (in a card: as wide as it less its inset): its `title` (what a control says), its `note` under
/// it where it says something (a caption, quieter, wrapped), an icon before them (`leading`), and what ends it
/// (`trailing`: a meta's words, a tag, a control) made in a box as tall as the title's first line. `press`: what
/// pressing the whole row does (a button then, lit under the hand), None for a row that is only read. The node.
#callsite(autofill(loc))
pub fn list_row(
  parent : @view.View,
  title : () -> String,
  note? : () -> String,
  leading? : Icon,
  trailing? : (@view.View) -> Unit,
  size? : RowSize = RowMd,
  press? : () -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  let look = fn(r : @view.View, lit : () -> Double) {
    let line = Ui.line_height()
    let vpad = (size.height() - line) / 2.0
    let gap = if size == RowSm { S6 } else { S8 }
    r
    .row(Is(true))
    .lines_up(Is(Some(Start)))
    .gap(Is(gap.pt()))
    .radius(Is(control_radius))
    .padding(Is((S8.pt(), vpad, S8.pt(), vpad)))
    .min_height(Is(Some(size.height())))
    |> ignore
    if press is Some(_) {
      r.ground(By(fn() { alpha(palette().hover, lit()) })) |> ignore
    }
    match leading {
      Some(i) =>
        // (a box as tall as the first line, the icon in its middle)
        r.box(fn(m) {
          m
          .height(Is(Some(line)))
          .shrink(Is(0.0))
          .row(Is(true))
          .lines_up(Is(Some(Middle)))
          .lies_along(Is(Middle))
          |> ignore
          icon_node(m, i, Ui.icon_size(), fn() { palette().muted }) |> ignore
        })
        |> ignore
      None => ()
    }
    r.box(fn(t) {
      t.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).gap(Is(S2.pt())) |> ignore
      text_node(t, title, Ui, fn() { palette().ink }, weight=weight_medium, wrap=true) |> ignore
      match note {
        Some(n) => text_node(t, n, Caption, fn() { palette().muted }, wrap=true) |> ignore
        None => ()
      }
    })
    |> ignore
    match trailing {
      Some(make) =>
        r.box(fn(e) {
          e
          .height(Is(Some(line)))
          .shrink(Is(0.0))
          .row(Is(true))
          .gap(Is(S6.pt()))
          .lines_up(Is(Some(Middle)))
          |> ignore
          make(e)
        })
        |> ignore
      None => ()
    }
  }
  match press {
    Some(p) =>
      @headless.button(made_for=loc, parent, title, fn(_) { p() }, fn(r, b) {
        let lit = @motion.eased_on(r, fn() { b.hovered() || b.pressed() }, @motion.tween_to(duration=lit_ms, ease=ease_answer))
        r.focus_ring(By(fn() { Some((focus_ring_w, 0.0, palette().focus)) })) |> ignore
        look(r, fn() { lit.shown(r) })
      })
    None => parent.box(made_for=loc, fn(r) { look(r, fn() { 0.0 }) })
  }
}

///|
/// A column in `parent` of `parts`, each shown while its function says, `make` making it; a hairline between each two
/// that show, inset as far as the rows' words (`line_in`): drawn before a part only while some part before it shows,
/// so none is doubled where one between hides and none hangs at either end. The node.
#callsite(autofill(loc))
pub fn divided_column(
  parent : @view.View,
  parts : Array[(() -> Bool, (@view.View) -> Unit)],
  line_in? : Space = S8,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(col) {
    for i, part in parts {
      let (shows, make) = part
      let before = fn() {
        for j in 0..<i {
          if (parts[j].0)() {
            return true
          }
        }
        false
      }
      col.show(shows, fn(s) {
        s.show(before, fn(d) {
          d.padding(Is((line_in.pt(), S2.pt(), line_in.pt(), S2.pt()))) |> ignore
          d.box(fn(l) {
            l.height(Is(Some(1.0))).ground(By(fn() { palette().hairline })).drawn_as(Is(divider_name)) |> ignore
          })
          |> ignore
        })
        make(s)
      })
    }
  })
}

///|
/// What a line between two parts is called (`View::drawn_as`), as a scripted run or a test finds it (`icon:divider`).
pub let divider_name : String = "/icon/divider/"

///|
/// A meta in `parent`: quiet words with an icon before them, no ground and no edge (a time, a count, who did it). The
/// node.
#callsite(autofill(loc))
pub fn meta(parent : @view.View, text : () -> String, icon? : Icon, loc~ : SourceLoc) -> @view.View {
  parent.box(made_for=loc, fn(m) {
    m.row(Is(true)).gap(Is(S4.pt())).lines_up(Is(Some(Middle))).shrink(Is(0.0)) |> ignore
    match icon {
      Some(i) => icon_node(m, i, Caption.icon_size(), fn() { palette().faint }) |> ignore
      None => ()
    }
    text_node(m, text, Caption, fn() { palette().muted }) |> ignore
  })
}

///|
/// A tag in `parent`: its words on the accent's soft ground, a capsule 18 high (20 where `tall`). The node.
#callsite(autofill(loc))
pub fn tag(parent : @view.View, text : () -> String, tall? : Bool = false, loc~ : SourceLoc) -> @view.View {
  let h = if tall { 20.0 } else { 18.0 }
  parent.box(made_for=loc, fn(t) {
    t
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .height(Is(Some(h)))
    .shrink(Is(0.0))
    .radius(Is(h / 2.0))
    .padding(Is(pad(S6, S0, S6, S0)))
    .ground(By(fn() { palette().accent_soft }))
    |> ignore
    text_node(t, text, Caption, fn() { palette().accent_ink }, weight=weight_medium) |> ignore
  })
}
