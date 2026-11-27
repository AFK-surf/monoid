// The words chosen between over a picture to share (分享图上的分组切换) as nodes of the window's tree, made once: the
// sets of looks of the card to share, 部分打码 | 完全打码 over the subscriptions' picture. Words in a line in the
// middle on the share's night, the one shown the white and a little bolder, another the white under the hand, the
// rest the white thinned. What they are to the hand, the keyboard and a screen reader is mbui's tab list's
// (@headless.radio_group, kind Tab: Tab stops at the one shown, ← → step along them choosing each); here their look.

///|
/// Shared text look for a single share tab item on the stage night scrim.
#callsite(autofill(loc))
fn share_tab_words_node(item : @view.View, words : () -> String, it : @headless.RadioItem, loc~ : SourceLoc) -> Unit {
  item.box(made_for=loc, fn(n) {
    let look = fn() {
      if it.chosen() {
        share_tabs_name_on
      } else if it.hovered() || it.focus_shown() {
        share_tabs_name_lit
      } else {
        share_tabs_name
      }
    }
    n
    .words(By(words))
    .words_look(By(fn() { @ui.style_words(look()) }))
    .ink(By(fn() { @ui.style_ink(look()) }))
    |> ignore
  })
  |> ignore
}

///|
/// The words of `keys` in `parent`, a tab list called `label`, `name(key)` each one's words (read out its name), the
/// one shown `chosen()`; a press or an arrow key on another tells `choose` its key. The node.
#callsite(autofill(loc))
pub fn[K : Eq] share_tabs_node(
  parent : @view.View,
  label : () -> String,
  keys : Array[K],
  name : (K) -> String,
  chosen : () -> K,
  choose : (K) -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  @headless.radio_group(made_for=loc, parent, label, chosen, choose, kind=Tab, fn(row, rg) {
    style_node(row, fn() { share_tabs_row })
    for key in keys {
      let words = fn() { name(key) }
      rg.item(row, fn() { key }, words, fn(item, it) {
        style_node(item, fn() { share_tabs_item })
        share_tab_words_node(item, words, it)
      })
      |> ignore
    }
  })
}

///|
/// Dynamic tab words in `parent`: reactive `(key, title)` entries centered when narrower than the stage and
/// horizontally scrollable when wider, sharing `share_tabs_node`'s exact look and keyboard/a11y behavior.
#callsite(autofill(loc))
pub fn share_tabs_each_node(
  parent : @view.View,
  label : () -> String,
  items : () -> Array[(String, String)],
  chosen : () -> String,
  choose : (String) -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(host) {
    style_node(host, fn() { share_tabs_scroll_host })
    host.box(fn(sc) {
      sc.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      sc.scrolls(@view.Scroll::across(), slop=@ui.touch_slop(), fn(inner) {
        @headless.radio_group(inner, label, chosen, choose, kind=Tab, fn(row, rg) {
          style_node(row, fn() { share_tabs_scroll_row })
          row.each(at_once=true, items, fn(e) { e.0 }, fn(slot, entry) {
            slot.shrink(Is(0.0)) |> ignore
            let words = fn() { entry.get().1 }
            rg.item(slot, fn() { entry.get().0 }, words, fn(item, it) {
              // Inside a horizontal `scrolls` container (`bounds_input=true`), each tab needs at least `theme().items.least`
              // height (44pt on touch, 36pt on mouse) so its press target is never clipped vertically.
              style_node(item, fn() { share_tabs_scroll_item.then(row_least_h()) })
              share_tab_words_node(item, words, it)
            })
            |> ignore
          })
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
}

///|
/// The words in a line in the middle, 16 apart.
// kept across runs: a value (no field of it changes)
let share_tabs_row : @ui.Style = @ui.css("row gap=S4 justify=JCenter w=Full")

///|
/// Host centering the scrollable share tab row when narrower than the stage.
// kept across runs: a value (no field of it changes)
let share_tabs_scroll_host : @ui.Style = @ui.css("row justify=JCenter w=Full")

///|
/// Scrollable tab words row: intrinsic width so its host centers it when narrow and scrolls it when wide.
// kept across runs: a value (no field of it changes)
let share_tabs_scroll_row : @ui.Style = @ui.css("row gap=S4")

///|
/// Each scrollable tab's words, vertically centered inside its `row_least_h()` press room.
// kept across runs: a value (no field of it changes)
let share_tabs_scroll_item : @ui.Style = @ui.css("justify=JCenter align=ACenter")

///|
/// Each one's words, with room round them to be pressed.
// kept across runs: a value (no field of it changes)
let share_tabs_item : @ui.Style = @ui.css("py=S1")

///|
/// Their words: the white thinned, small.
// kept across runs: a value (no field of it changes)
let share_tabs_name : @ui.TextStyle = @ui.text_style(size=Sm, color=Data(share_dim), wrap=false)

///|
/// The one shown: the white, a little bolder.
// kept across runs: a value (no field of it changes)
let share_tabs_name_on : @ui.TextStyle = share_tabs_name.then(@ui.text_style(color=Data(share_ink), weight=Medium))

///|
/// Another under the hand: the white, as it rests otherwise (the hand changes its ink alone).
// kept across runs: a value (no field of it changes)
let share_tabs_name_lit : @ui.TextStyle = share_tabs_name.then(@ui.text_style(color=Data(share_ink)))
