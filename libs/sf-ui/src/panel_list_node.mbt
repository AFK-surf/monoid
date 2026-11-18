// What scrolls in itself in a panel whose body is nodes (panel_nodes), its head and foot standing where they are: a long
// list (panel_list's, an old view's Ctx::list in a panel) and a box kept to a height (an old view's Ctx::capped), as
// nodes of the window's tree on the tree's own scrolling (View::scrolls_window, View::scrolls), laid out one way: as
// tall as what they hold where there is the room, giving way where what holds them is short of it, never telling the
// panel how tall to be (one whose body is as tall as what it holds up to its share says so itself: panel_nodes' `hugs`).

///|
/// How far before its top and its foot a panel's list fades out, at most, where it goes on past them (as capped_node's,
/// mbui's scroll_soft_most).
let panel_list_fade : Double = 24.0

///|
/// A long list in a panel's body in `parent` (panel_list's): the blocks `keys` names, each made by `row` in a node of its
/// own (given its key: what it binds read from what the key names, so a row stays as what it shows changes) only while
/// it shows, as tall as it was last measured meanwhile (`est` where it never was), scrolling up and down in itself as a
/// page's list does on its platform (Scroll::list), its bar along its right, faded out towards an end it goes on past
/// (as far as it does, at most panel_list_fade: as capped_node's, so a panel shows there is more past what it cuts;
/// a page's own list is not, Scroll::list). It reaches out across the room the panel
/// leaves its rows (rows_out: what scrolls cuts what it holds to itself), its rows' words that much further in, so a
/// row's ground reaches the panel's sides as it does outside a list. As tall as its rows laid end to end where there is
/// the room, giving way where there is not; `fills`: the room the panel gives it, whatever it holds (one gone about in,
/// a folder after another, each holding more or less: not a list growing and shrinking at each step); `most`: no taller
/// than that. `place`: what asks it to show a row (ListPlace: one brought to its middle as it opens). `stick_end`: made at
/// its end and kept there as what it holds grows or more comes while it is there, not once scrolled off it; followed
/// again once scrolled back to it (panel_list's `stick_end`, an old list's). Its node (what scrolls).
#callsite(autofill(loc))
pub fn[K : Hash + Eq] panel_list_node(
  parent : @view.View,
  keys : () -> Array[K],
  row : (@view.View, K) -> Unit,
  est~ : Double,
  fills? : Bool = false,
  most? : () -> Double,
  place? : @view.ListPlace[K],
  stick_end? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  let at = panel_in_of(parent)
  let look = look_node(parent)
  let out = at.rows_out
  parent.box(made_for=loc, fn(room) {
    room.margin(Is((-out, 0.0, -out, 0.0))) |> ignore
    if fills {
      room.grow(Is(1.0)).basis(Is(Some(0.0))) |> ignore
    }
    match most {
      Some(m) => room.max_height(By(fn() { Some(m()) })) |> ignore
      None => ()
    }
    // (its keys as last read, and whether their last change put another set in their place (a folder gone into,
    // another's rows): there at once, not each of its rows closing and the other's opening: pg_blocks_read)
    let was : Ref[Set[K]] = Ref(Set([]))
    let other = Ref(false)
    let read = fn() { pg_blocks_read(was, other, keys()) }
    let scroll = @view.Scroll::list()
    room.scrolls_window(
      scroll,
      read,
      fn(b, k) {
        // (its rows laid out as the panel's are, their words further in by as far as it reaches out)
        panel_in_lend(b, look, at.words + out, sides=at.sides - out, small=at.small, clear=at.clear, listed=true)
        row(b, k)
      },
      est~,
      slop=@ui.touch_slop(),
      bar=@ui.tree_scroll_bar(),
      place?,
      // (its end followed, where it sticks there: none of its rows holding what shows where it is as more comes)
      follows=fn() { stick_end },
      holds=fn(_) { !stick_end },
      // (a row come or gone by data makes its way, the list's (View::comes); another list in its place at once)
      comes=fn(_) { !other.val },
      goes=fn(_) { !other.val },
    )
    |> ignore
    // (towards its top and its foot where it goes on past them, as drawn: a fling's moment too; bound once it scrolls,
    // how far it can go read as its layout says it from then)
    room.fades(By(fn() {
      let at = scroll.drawn(room.tree)
      let reach = scroll.reach()
      (0.0, dclamp(at, 0.0, panel_list_fade), 0.0, dclamp(reach - at, 0.0, panel_list_fade))
    }))
    |> ignore
  })
}

///|
/// A box in `parent` (an old view's Ctx::capped) no taller than `most`, what `body` makes in it (all of it, made once)
/// scrolling up and down in it where it is taller, faded towards an end it goes on past, its bar along its right; as
/// tall as what it holds where that is less, and shorter still where what holds it is short of room. Its node.
#callsite(autofill(loc))
pub fn capped_node(
  parent : @view.View,
  most : () -> Double,
  body : (@view.View) -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(b) {
    b.max_height(By(fn() { Some(most()) })) |> ignore
    b.scrolls(@view.Scroll::new(), slop=@ui.touch_slop(), bar=@ui.tree_scroll_bar(), body) |> ignore
  })
}
