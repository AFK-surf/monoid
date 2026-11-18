// A picture or a video waiting in the composer (the old composer's picture_tile) as a node of the window's tree, made
// once: 56 square, as round as what waits in the composer is (composer_inner), cut to that; its picture whatever the
// caller draws in it; while it goes up the ink's veil over it with a ring filling as far as it has gone (turning till
// that is said); failed, edged red with ↻ on the veil, a press there trying again; a video's solid play mark in its
// middle otherwise.

///|
/// The tile in `parent`: `picture` draws its picture in the node given (cover, as big as the tile); `going()`: whether
/// it goes up now, `part()` how far (None till that is said); `failed()`: whether it failed going up, `again` what a
/// press on ↻ does; `video`: a video's still; `rim`: its hairline drawn round it (none where it stands off a card's
/// corner by a gap the corner rule keeps for nothing grounded: the board's draft card). The node.
#callsite(autofill(loc))
pub fn waiting_tile_node(
  parent : @view.View,
  picture : (@view.View) -> Unit,
  going : () -> Bool,
  part : () -> Double?,
  failed : () -> Bool,
  again : () -> Unit,
  again_label : () -> String,
  video? : () -> Bool = fn() { false },
  rim? : Bool = true,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(tile) {
    tile
    .width(Is(Some(waiting_tile_side)))
    .height(Is(Some(waiting_tile_side)))
    .min_width(Is(Some(waiting_tile_side)))
    .radius(By(fn() { composer_inner() }))
    .clips(Is(true))
    // (its rim, drawn over all it holds, its veils too: a hairline so a light picture stands off a light composer and a
    // dark one off a dark one (the line, as a message's picture's: sfpages' image_frame_rimmed), where `rim` says;
    // failed, edged red)
    .edge(
      By(fn() {
        if failed() {
          (waiting_failed_edge, @ui.tree_theme().color(Danger))
        } else if rim {
          (1.0, theme().p.line)
        } else {
          (0.0, 0L)
        }
      }),
    )
    |> ignore
    tile.box(fn(p) {
      p.grow(Is(1.0)) |> ignore
      picture(p)
    })
    |> ignore
    // going up: the veil, the ring filling as it goes
    tile.show(going, at_once=true, fn(veil) {
      waiting_veil(veil)
      progress_spinner_node(veil, part, size=theme().round.glyph) |> ignore
    })
    // failed: ↻ on the veil, a press there trying again
    tile.show(failed, at_once=true, fn(veil) {
      waiting_veil(veil)
      icon_button_node(veil, "refresh", again_label, again, icon_size=waiting_retry_icon, ink=fn() { waiting_on_veil }, grounded=false)
      |> ignore
    })
    // a video's still: its play mark, while it neither goes up nor failed
    tile.show(fn() { video() && !going() && !failed() }, at_once=true, fn(mark) {
      mark.over(Is(true)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
      icon_node(mark, "play-mark", waiting_play_side, Is(waiting_on_veil)) |> ignore
    })
  })
}

///|
/// The veil over a tile going up or failed: over all of it, the ink's veil, what it says in its middle (its style's
/// align and justify: style_node sets how a node lines up what it holds whatever its style says, so a lines_up said
/// before it was undone, the ring drawn in the tile's top left corner).
fn waiting_veil(v : @view.View) -> Unit {
  v.over(Is(true)) |> ignore
  style_node(v, fn() { waiting_tile_veil })
}

///|
/// A tile's side (composerThumb: 56); its ↻ (18) and a video's play mark (24), white on the veil.
pub let waiting_tile_side : Double = 56.0

///|
let waiting_retry_icon : Double = 18.0

///|
let waiting_play_side : Double = 24.0

///|
let waiting_on_veil : Int64 = 0xFFFFFFFFL

///|
/// How wide a failed tile's red edge is (B2).
let waiting_failed_edge : Double = 2.0

///|
// kept across runs: a value (no field of it changes)
let waiting_tile_veil : @ui.Style = @ui.css("bg=Veil align=ACenter justify=JCenter")
