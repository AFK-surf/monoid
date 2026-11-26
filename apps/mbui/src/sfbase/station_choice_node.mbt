// Which station something is done on, at the start of a line saying where (a folder's way, what a repository is cloned
// into): the station's mark and its name; where there are others to choose from, a chevron after them, and pressed, the
// presenters' pick of them beside it, each by its mark (station_choice; a sheet from the foot on 小屏), the one it is
// on checked. With none other, only what it is: nothing to press.

///|
/// A station to choose (station_choice_node): its address, its name, its mark (its emoji, its icon: station_mark_node's).
#derive(Eq)
pub(all) struct StationChoice {
  station : String
  name : String
  emoji : String
  icon : String
}

///|
/// The station `chosen()` of `stations()` in `parent`: its mark (station_mark_at_node's) and its name, 13 and
/// medium, as high as a row is at least (a press's room); where there is more than one, a chevron down after them, and
/// pressed (as a crumb of a way is: lit under the hand, its corner the theme's Md), the presenters' pick of them titled
/// `title` beside it, the one chosen checked: one chosen, `choose` given its address. Read out a button named `label` given the station's name; with one alone, words.
/// `round`: round as its height, as a foot's buttons are beside it (in a panel's foot, its corner concentric with the
/// panel's as theirs is). `chooser`: a chooser in a row of them beside a model's control (a new chat's composer's,
/// model_triple_node's `small`): as high, as far in, its parts as far apart and as round as that one; its mark in its
/// words' ink, its words that row's; as wide as its mark, its name (cut short past glass_chooser_station_most) and its
/// chevron need, never giving way to what is beside it.
#callsite(autofill(loc))
pub fn station_choice_node(
  parent : @view.View,
  stations : () -> Array[StationChoice],
  chosen : () -> String,
  choose : (String) -> Unit,
  title~ : String,
  label~ : (String) -> String,
  round? : Bool = false,
  chooser? : Bool = false,
  loc~ : SourceLoc,
) -> Unit {
  let now = fn() -> StationChoice {
    let all = stations()
    match all.iter().find_first(fn(s) { s.station == chosen() }) {
      Some(s) => s
      None => all.get(0).unwrap_or({ station: chosen(), name: chosen(), emoji: "", icon: "" })
    }
  }
  let several = fn() { stations().length() > 1 }
  let opener = @sf.Opener::new()
  // (a disclosure where there are others to choose, its menu what it opens; else what it is, nothing to press:
  // button_while_node)
  @sf.button_while_node(
    parent,
    several,
    fn() { label(now().name) },
    fn(b) {
      let at = @signals.untracked(chosen)
      let choices = @signals.untracked(stations).map(fn(s) { station_choice(s.station, s.name, s.emoji, s.icon) })
      @sf.pick(title, choices, at, fn(id) { if id != at { choose(id) } }, from=Node(b), search=false)
      opener.mark()
    },
    open=fn() { opener.open() },
    in_row=true,
    fn(b, pressed) {
      @sf.style_node(
        b,
        fn() {
          if chooser {
            station_choice_chooser
          } else if round {
            station_choice_round
          } else {
            station_choice_box
          }
        },
        in_row=true,
      )
      if chooser {
        // (as wide as what it holds: the model's control beside it leaves out its parts first; a finger reaches it from
        // round it, as that one, press_reach)
        b.shrink(Is(0.0)) |> ignore
      } else {
        // (shrinking to its words' least where the line is short: its name cut short, its mark and chevron whole)
        b.shrink(Is(1.0)).min_width(Is(Some(0.0))).min_height(By(fn() { Some(if round { @sf.button_height() } else { @sf.theme().items.least }) })) |> ignore
      }
      if pressed {
        @sf.hover_ground_node(b)
      }
      let ink = fn() { if chooser { @sf.theme().p.text } else { @sf.theme().p.muted } }
      // (its mark a small label's, as its pick's rows have it: station_mark_at_node)
      station_mark_at_node(b, fn() { now().station }, fn() { now().emoji }, fn() { now().icon }, Chip, words=ink)
      let name = @sf.words_node(b, fn() { now().name }, fn() {
        if chooser {
          station_choice_chooser_words
        } else {
          station_choice_words
        }
      })
      name.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      if chooser {
        @sf.style_node(name, fn() { station_choice_name_most })
      }
      if pressed {
        @sf.icon_node(b, "chevron-down", station_choice_chevron, By(fn() { @sf.theme().p.muted })) |> ignore
      }
    },
    loc~,
  )
}

///|
/// Its chevron (12), a way's crumbs' size (its mark a small label's: station_mark_at_node).
let station_choice_chevron : Double = 12.0

///|
/// A way's crumb's room round it (4 by 2, full capsule), 5 between its parts.
// kept across runs: a value (no field of it changes)
let station_choice_box : @ui.Style = @ui.css("row px=S1 py=S0_5 gap=S1_25 align=ACenter radius=Full")

///|
/// The same, round as its height (station_choice_node's `round`), as far in at its ends as its corner leaves its mark.
// kept across runs: a value (no field of it changes)
let station_choice_round : @ui.Style = @ui.css("row px=S2 py=S0_5 gap=S1_25 align=ACenter radius=Full")

///|
/// A chooser's (station_choice_node's `chooser`): a new chat's composer's control in its row (28 high, 8 in, its parts 6
/// apart, full capsule), as model_triple_node's `small` beside it is.
// kept across runs: a value (no field of it changes)
let station_choice_chooser : @ui.Style = @ui.css("row h=S7 px=S2 gap=S1_5 align=ACenter radius=Full")

///|
// kept across runs: a value (no field of it changes)
let station_choice_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Fg, wrap=false, w=Cut)

///|
/// A chooser's words: the composer's row's (Meta, as the model's beside it).
// kept across runs: a value (no field of it changes)
let station_choice_chooser_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Fg, wrap=false, w=Cut)

///|
/// A chooser's name cut short past the composer's station's most (mChooser's max-width).
// kept across runs: a value (no field of it changes)
let station_choice_name_most : @ui.Style = @ui.style(max_w=@sf.glass_chooser_station_most)
