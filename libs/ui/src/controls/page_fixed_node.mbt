// A page container whose wide layout keeps its header fixed at the top and hosts a non-scrolling flex column below
// (so a `data_table_node` inside shrinks and scrolls within its own card), while its narrow layout delegates directly
// to `narrow_page_node` (preserving full-page scroll and back-bar/top-edge behavior on small viewports).

///|
/// Builder scope for `page_fixed_node`: keeps every public function within the 8-argument library limit while
/// sharing header metadata across `Wide` and `Narrow` layouts.
pub struct PageFixedScope {
  priv mut said_fn : ((PageSaid) -> Unit)?
  priv mut lead_fn : () -> String
  priv mut about_fn : () -> String
  priv mut actions_fn : ((@view.View) -> Unit)?
  priv mut tips_layer : TipLayer?
  priv mut wide_body_fn : ((@view.View) -> Unit)?
  priv mut narrow_blocks_fn : (() -> Array[String])?
  priv mut narrow_block_fn : ((@view.View, String) -> Unit)?
  priv mut narrow_reused_fn : ((String) -> Int?)?
  priv mut narrow_make_reused_fn : ((@view.View, Int, () -> String) -> Unit)?
}

///|
/// Reports page metadata (`PageSaid`) to the enclosing frame bar.
pub fn PageFixedScope::said(self : PageFixedScope, f : (PageSaid) -> Unit) -> Unit {
  self.said_fn = Some(f)
}

///|
/// Optional subtitle under the page title.
pub fn PageFixedScope::lead(self : PageFixedScope, f : () -> String) -> Unit {
  self.lead_fn = f
}

///|
/// Optional info-mark tooltip text beside the wide title.
pub fn PageFixedScope::about(self : PageFixedScope, f : () -> String) -> Unit {
  self.about_fn = f
}

///|
/// Optional trailing header actions.
pub fn PageFixedScope::actions(self : PageFixedScope, f : (@view.View) -> Unit) -> Unit {
  self.actions_fn = Some(f)
}

///|
/// Shared tip layer from the enclosing frame.
pub fn PageFixedScope::tips(self : PageFixedScope, t : TipLayer) -> Unit {
  self.tips_layer = Some(t)
}

///|
/// Non-scrolling flex column rendered under the fixed wide header (`grow(1.0).min_height(Some(0.0))`).
pub fn PageFixedScope::wide_body(self : PageFixedScope, make : (@view.View) -> Unit) -> Unit {
  self.wide_body_fn = Some(make)
}

///|
/// Narrow-layout scrollable blocks, delegated directly to `narrow_page_node`.
pub fn PageFixedScope::narrow_blocks(
  self : PageFixedScope,
  blocks : () -> Array[String],
  block : (@view.View, String) -> Unit,
  reused? : (String) -> Int?,
  make_reused? : (@view.View, Int, () -> String) -> Unit,
) -> Unit {
  self.narrow_blocks_fn = Some(blocks)
  self.narrow_block_fn = Some(block)
  self.narrow_reused_fn = reused
  self.narrow_make_reused_fn = make_reused
}

///|
/// A fixed-header wide page container that falls back to `narrow_page_node` on narrow viewports.
/// - `Wide`: whole page does not scroll; lends `max_width` via `lane_most_lent` so header, controls, table card,
///   and bottom bar align cleanly; top `frame().top` + `wide_head_node` stay fixed while `wide_body` fills the rest.
/// - `Narrow`: delegates directly to `narrow_page_node` (reusing back bar, `head_back_holds`, `pushed_narrow_lent`,
///   `back_bar_lent`, and `top_scroll_edge_node`).
#callsite(autofill(loc))
pub fn page_fixed_node(
  v : @view.View,
  title : () -> String,
  build : (PageFixedScope) -> Unit,
  on_back~ : () -> Unit,
  frame? : () -> PageFrame = fn() { no_frame },
  width? : () -> Double,
  max_width? : Double = desk_lane_most,
  loc~ : SourceLoc,
) -> Unit {
  let s : PageFixedScope = {
    said_fn: None,
    lead_fn: fn() { "" },
    about_fn: fn() { "" },
    actions_fn: None,
    tips_layer: None,
    wide_body_fn: None,
    narrow_blocks_fn: None,
    narrow_block_fn: None,
    narrow_reused_fn: None,
    narrow_make_reused_fn: None,
  }
  build(s)
  let lead = s.lead_fn
  let about = s.about_fn
  match s.said_fn {
    Some(f) => v.reacts(fn() { { title: title(), about: about(), back: "" } }, f)
    None => ()
  }
  v.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
  let look = match width {
    Some(w) => fn() { look_for(w()) }
    None => fn() { Narrow }
  }
  let own_scroll = @view.Scroll::list()
  let tips_at : Ref[@view.View?] = Ref(None)
  let own_tips = s.tips_layer is None
  let tips = match s.tips_layer {
    Some(t) => t
    None => TipLayer::new(fn() { tips_at.val })
  }
  v.pick(look, fn(p, l) {
    p.grow(Is(1.0)).min_height(Is(Some(0.0))).lends(part_at, { look: l, section: false, list: false, card: false }) |> ignore
    match l {
      Narrow => {
        let nb = s.narrow_blocks_fn.unwrap_or(fn() { [] })
        let nb_make = s.narrow_block_fn.unwrap_or(fn(_, _) {  })
        narrow_page_node(
          loc~,
          p,
          title,
          nb,
          nb_make,
          on_back,
          frame,
          lead,
          s.actions_fn,
          own_scroll,
          None,
          None,
          fn() { "" },
          s.narrow_reused_fn,
          s.narrow_make_reused_fn,
        )
      }
      Wide => {
        p.lends(lane_most_lent, max_width) |> ignore
        // Fixed top inset (status bar / frame top)
        p.show(fn() { frame().top > 0.0 }, at_once=true, fn(top) {
          top.height(By(fn() { Some(frame().top) })).shrink(Is(0.0)) |> ignore
        })
        // Fixed wide header (reuses `wide_head_node` and `WideLead` when `frame().named`)
        p.pick(
          fn() {
            if !frame().named {
              2
            } else if lead() != "" {
              1
            } else {
              0
            }
          },
          fn(hw, mode) {
            hw.shrink(Is(0.0)) |> ignore
            if mode == 2 {
              lane_node(loc~, hw, fn(col) { wide_head_node(loc~, col, title, on_back, frame, lead, s.actions_fn, about, tips) })
            } else if mode == 1 {
              lane_node(loc~, hw, fn(col) {
                col.padding(Is((head_in(col), 0.0, head_in(col), desk_head_foot))) |> ignore
                words_node(col, lead, fn() { desk_muted }) |> ignore
              })
            }
          },
        )
        // Non-scrolling flex column body
        match s.wide_body_fn {
          Some(make_body) =>
            lane_grow_node(loc~, p, fn(col) {
              col.box(made_for=loc, fn(room) {
                room
                .grow(Is(1.0))
                .shrink(Is(1.0))
                .min_height(Is(Some(0.0)))
                .padding(By(fn() {
                  let foot = if in_pane_node(col) { page_foot(col) } else { fixed_page_foot }
                  (desk_column_in, desk_first_top, desk_column_in, foot + frame().foot)
                }))
                |> ignore
                make_body(room)
              })
              |> ignore
            })
          None => ()
        }
      }
    }
  })
  if own_tips {
    v.show(fn() { about() != "" }, fn(t) {
      t.over(Is(true)) |> ignore
      tips_at.val = Some(t)
    })
  }
}

///|
let fixed_page_foot : Double = 16.0
