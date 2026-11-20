// The words chosen between over a picture to share (分享图上的分组切换) as nodes of the window's tree, made once: the
// sets of looks of the card to share, 部分打码 | 完全打码 over the subscriptions' picture. Words in a line in the
// middle on the share's night, the one shown the white and a little bolder, another the white under the hand, the
// rest the white thinned. What they are to the hand, the keyboard and a screen reader is mbui's tab list's
// (@headless.radio_group, kind Tab: Tab stops at the one shown, ← → step along them choosing each); here their look.

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
        item.box(fn(n) {
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
      })
      |> ignore
    }
  })
}

///|
/// The words in a line in the middle, 16 apart.
// kept across runs: a value (no field of it changes)
let share_tabs_row : @ui.Style = @ui.css("row gap=S4 justify=JCenter w=Full")

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
