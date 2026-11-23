// A list card made of pieces, each a block of a page's list (group_node's card, narrow): a long list on a card made
// only as far as it shows (View::scrolls_window makes a block as it comes to show), where one card holding all of it
// is made whole in the frame it comes into view, as tall as it is where `est` was counted. The first piece is the
// card's top (its room over the rows, its top corners), the last its foot (its room under them, its foot corners, the
// room under the card), one alone the whole card, those between neither; what is on them the same as on group_node's.
// Laid out one under another they are that card, drawn the same.

///|
/// Which piece of a card a block of it is (card_piece_node): the whole card, its top, one between, its foot.
#derive(Eq, Debug)
pub(all) enum CardPiece {
  CardWhole
  CardTop
  CardBetween
  CardFoot
}

///|
/// The piece of a card the `i`th of `n` rows on it is (n at least 1).
pub fn card_piece_of(i : Int, n : Int) -> CardPiece {
  match (i == 0, i == n - 1) {
    (true, true) => CardWhole
    (true, false) => CardTop
    (false, true) => CardFoot
    (false, false) => CardBetween
  }
}

///|
/// A piece of a card (group_node's) as `piece` says it is now, `rows` made on it, made in `parent` (a block of a page's
/// list: page_block's room), as group_node lays out its three narrow forms: in a panel's body, the panel's card
/// (panel_card_group, its rows the ladder's inset in, `panel_card_in` from its sides); in a panel of its own (pane_lent),
/// a card's corner, the ladder's inset; else a list card (`list_pad` in, its corner), 10 under it. Its top and foot
/// rooms and corners only where it is the card's top or foot. It grows to what it is made in, as `parent` should to
/// its block (a page's block grows to its slot: page_node): where the page's list sets its slots on whole pixels
/// (Tree::set_rows_grid) each is whole pixels tall, and the grounds of pieces that meet meet there, with no seam. Wide,
/// its rows alone (a wide group's card is not one of pieces), or, `wide_card`, a piece of the wide page's card (a
/// section's, desk_card's: `card_pad` in, its corner Xl3, the section's foot under it), `wide_gap` over a piece that
/// is not its top (the rows' gap, part of the piece, so it goes with the row it is over); or, `wide_list`, a piece of
/// a wide list card of rows that light up (wide_group_node's list: `list_pad` in, concentric with its corner as
/// gaps.mbt's rule 7 holds them, each piece's row as far in from its top and foot, drawn as a list's rows, the
/// section's foot under it); or, `wide_group`, a piece of wide_group_node's list card as group_node lays it out (its
/// ends' rooms over the first row and under the last, the list's 2 between), drawn the same as that card whole, the
/// section's foot under it unless `wide_group_foot` is false (list_card_node's, standing in none); `wide_piece`: which
/// piece of the wide card it is, where the wide card is one and the narrow ones several (a heading's group each).
#callsite(autofill(loc))
pub fn card_piece_node(
  parent : @view.View,
  piece : () -> CardPiece,
  rows : (@view.View) -> Unit,
  wide_card? : Bool = false,
  wide_list? : Bool = false,
  wide_gap? : Double = 0.0,
  wide_group? : Bool = false,
  wide_group_foot? : Bool = true,
  wide_piece? : () -> CardPiece,
  loc~ : SourceLoc,
) -> Unit {
  let at = part_of(parent)
  // (wide, the piece it is of the wide card where that card holds more than the narrow one: a list cut into cards
  // narrow, one card wide)
  let piece = match wide_piece {
    Some(w) if at.look is Wide => w
    _ => piece
  }
  // (its rooms over and under what it holds, and the room under the card, each said by a node laid out in its turn down
  // what holds it: a piece that comes to be another as rows come or go round it (a row put under the card's only one:
  // its foot's rooms off it) changes height for that change's cause, on its way, its column's, as what comes does
  // (View::resizes), where the card and its room, grown to their block, make none of their own; what an answer tells at
  // first, a reused block, settles at once there (View::comes))
  let resizes = fn(v : @view.View) { v.reacts(piece, fn(_) { v.resizes() |> ignore }, at_start=false) }
  // (the room under the card, in `room` under it)
  let under = fn(room : @view.View, tall : () -> Double) {
    room.box(fn(e) {
      e.height(By(fn() { Some(tall()) })) |> ignore
      resizes(e)
    })
    |> ignore
  }
  // (what it holds, its rooms `over` and `under` it, in `card`: where its room over it changes, what it holds keeps to
  // its foot on that way (View::resizes `foot`), so its rows go down or up with that room as it goes, not at once)
  let held = fn(card : @view.View, over : () -> Double, under : () -> Double) {
    card.box(fn(k) {
      k.padding(By(fn() { (0.0, over(), 0.0, under()) })) |> ignore
      let was = Ref(@signals.untracked(piece))
      k.reacts(
        piece,
        fn(p) {
          let topped = (p is (CardWhole | CardTop)) != (was.val is (CardWhole | CardTop))
          was.val = p
          k.resizes(foot=topped) |> ignore
        },
        at_start=false,
      )
      rows(k)
    })
    |> ignore
  }
  let top = fn() { piece() is (CardWhole | CardTop) }
  let foot = fn() { piece() is (CardWhole | CardFoot) }
  // (top left, then round it)
  let corners = fn(r : Double) -> (Double, Double, Double, Double)? {
    let t = if top() { r } else { 0.0 }
    let f = if foot() { r } else { 0.0 }
    Some((t, t, f, f))
  }
  // (as tall as its round ends at least: a top or foot that holds no row, its room alone, shorter than its corners
  // would draw them squeezed to that, its edge straight)
  let least = fn(r : Double) -> Double? {
    match (top(), foot()) {
      (false, false) => None
      (true, true) => Some(r * 2.0)
      _ => Some(r)
    }
  }
  if parent.lent(panel_in_lent) is Some(p) && !p.small {
    parent.box(made_for=loc, fn(k) {
      style_node(k, fn() {
        panel_card_ground.then(@ui.style(px=room(corner_inset))).then(panel_card_out_node(k))
      })
      k.grow(Is(1.0)).min_height(By(fn() { least(card_corner) })).corners(By(fn() { corners(card_corner) })).lends(on_card_lent, true).lends(part_at, { ..at, list: at.look is Wide, card: false })
      |> ignore
      // (what lies on it concentric with the card's corner, its rows the ladder's inset in)
      corner_card_node(k, fn() { card_corner }, inset=fn() { corner_inset })
      held(k, fn() { if top() { corner_inset } else { 0.0 } }, fn() { if foot() { corner_inset } else { 0.0 } })
    })
    |> ignore
    return
  }
  if at.look is Wide && wide_list {
    let (pad, corner) = list_card_in(parent)
    parent.box(made_for=loc, fn(room) {
      room.grow(Is(1.0)) |> ignore
      room.box(fn(card) {
        card
        .grow(Is(1.0))
        // (each piece its own ground to rule 7: its one row `pad` in from its top and its foot too, so the rows of the
        // card stand twice that apart)
        .padding(Is((pad, pad, pad, pad)))
        .min_height(By(fn() { least(corner) }))
        .corners(By(fn() { corners(corner) }))
        .ground(By(fn() { @ui.tree_theme().color(Card) }))
        .clips(Is(true))
        .lends(part_at, { ..at, list: true, card: false })
        |> ignore
        corner_card_node(card, fn() { corner }, inset=fn() { pad })
        rows(card)
      })
      |> ignore
      under(room, fn() { if foot() { section_foot } else { 0.0 } })
    })
    |> ignore
    return
  }
  if at.look is Wide && wide_card {
    parent.box(made_for=loc, fn(room) {
      room.grow(Is(1.0)) |> ignore
      room.box(fn(card) {
        card
        .grow(Is(1.0))
        .padding(Is((card_pad, 0.0, card_pad, 0.0)))
        .corners(By(fn() { corners(@ui.tree_theme().corner(Xl3)) }))
        .ground(By(fn() { @ui.tree_theme().color(Card) }))
        .clips(Is(true))
        .lends(part_at, { ..at, list: false, card: true })
        |> ignore
        corner_card_node(card, fn() { @ui.tree_theme().corner(Xl3) }, inset=fn() { card_pad })
        held(card, fn() { if top() { card_pad } else { wide_gap } }, fn() { if foot() { card_pad } else { 0.0 } })
      })
      |> ignore
      under(room, fn() { if foot() { section_foot } else { 0.0 } })
    })
    |> ignore
    return
  }
  if at.look is Wide && wide_group {
    let (pad, corner) = list_card_in(parent)
    parent.box(made_for=loc, fn(room) {
      room.grow(Is(1.0)) |> ignore
      room.box(fn(card) {
        // (as wide_group_node's card: its rows `pad` in from its sides, its ends' rooms over its first and under its
        // last, the list's gap under each but the last, so that laid out one under another they are that card)
        let ends = if in_pane_node(card) { card_pad - wide_row_over } else { pad }
        card
        .grow(Is(1.0))
        .padding(Is((pad, 0.0, pad, 0.0)))
        .corners(By(fn() { corners(corner) }))
        .ground(By(fn() { @ui.tree_theme().color(Card) }))
        .lends(part_at, { ..at, list: true, card: false })
        |> ignore
        corner_card_node(card, fn() { corner }, inset=fn() { pad })
        held(card, fn() { if top() { ends } else { 0.0 } }, fn() { if foot() { ends } else { desk_list_gap } })
      })
      |> ignore
      // (none where the section's foot is under it, or none is said)
      if !at.section && wide_group_foot {
        under(room, fn() { if foot() { section_foot } else { 0.0 } })
      }
    })
    |> ignore
    return
  }
  if at.look is Wide {
    parent.box(made_for=loc, fn(k) { rows(k) }) |> ignore
    return
  }
  let (pad, corner) = if in_pane_node(parent) { (corner_inset, card_corner) } else { (list_pad, list_card_corner) }
  parent.box(made_for=loc, fn(room) {
    room.grow(Is(1.0)) |> ignore
    room.box(fn(card) {
      card
      .grow(Is(1.0))
      .padding(Is((pad, 0.0, pad, 0.0)))
      .min_height(By(fn() { least(corner) }))
      .corners(By(fn() { corners(corner) }))
      .ground(By(fn() { @ui.tree_theme().color(Card) }))
      .clips(Is(true))
      .lends(on_card_lent, true)
      |> ignore
      corner_card_node(card, fn() { corner }, inset=fn() { pad })
      held(card, fn() { if top() { pad } else { 0.0 } }, fn() { if foot() { pad } else { 0.0 } })
    })
    |> ignore
    under(room, fn() { if foot() { card_piece_under } else { 0.0 } })
  })
  |> ignore
}

///|
/// The room under a narrow list card (group_node's ListCard: 10).
let card_piece_under : Double = 10.0
