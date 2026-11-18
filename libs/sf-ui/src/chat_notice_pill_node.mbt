// What a chat's list says besides its messages, and the cards over a chats' list, as the library's parts (made once, as
// nodes of the window's tree), taken out of the pages that drew them by hand, each looking as it did there: the line
// with a rule each side and its words in the middle (未读 over the first message unread), the list's spinner while a
// page of it comes and its words where it could not be read or holds nothing; still.fail's notice in a chat as its pill
// (round on the neutral ground, a failure's red, open or closed as it is pressed, how many alike it folds, ×n, and what
// it ends in: a word that acts on it, after a dot); a time or a few words pressed to say them the other way; marking's
// colours (a swatch, and the palette of them to pick one: a radio group) and the news and the update's cards over a
// chats' list. What each is to the hand, the keyboard and a screen reader is mbui's headless part's (a button, a
// disclosure, a radio group); here only their look.

///|
/// A line across what holds it with a rule each side and `words` in the middle, in the accent (未读 over the first
/// message unread as the chat opened). The node.
#callsite(autofill(loc))
pub fn labeled_rule_node(parent : @view.View, words : () -> String, loc~ : SourceLoc) -> @view.View {
  parent.box(made_for=loc, fn(r) {
    style_node(r, fn() { labeled_rule_row })
    r.box(made_for=loc, fn(x) { style_node(x, fn() { labeled_rule_line }, in_row=true) }) |> ignore
    words_node(r, words, fn() { labeled_rule_words }) |> ignore
    r.box(made_for=loc, fn(x) { style_node(x, fn() { labeled_rule_line }, in_row=true) }) |> ignore
  })
}

///|
/// labeled_rule_node's line: across, its rules and words 10 apart, in its middle.
// kept across runs: a value (no field of it changes)
let labeled_rule_row : @ui.Style = @ui.css("row w=Full gap=S2_5 align=ACenter")

///|
/// Each rule: as wide as is left, 1 high, the accent at half.
// kept across runs: a value (no field of it changes)
let labeled_rule_line : @ui.Style = @ui.style(w=grow, h=SPx, bg=A(Accent, O50))

///|
/// Its words: small, a little heavy, in the accent's words' ink, on one line.
// kept across runs: a value (no field of it changes)
let labeled_rule_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=AccentText, wrap=false)

///|
/// A page of a list coming (the one before it where `older` says so, as it is now, else the one after it): a spinner
/// in the middle, the room round it the side's it comes on. The node.
#callsite(autofill(loc))
pub fn list_coming_node(parent : @view.View, older : () -> Bool, loc~ : SourceLoc) -> @view.View {
  parent.box(made_for=loc, fn(r) {
    style_node(r, fn() { if older() { list_older_row } else { list_newer_row } })
    spinner_node(r) |> ignore
  })
}

///|
/// What could not be read of a list in its place (the page before it): `words`, why, small and muted, wrapping, in
/// the middle. The node.
#callsite(autofill(loc))
pub fn list_failed_node(parent : @view.View, words : () -> String, loc~ : SourceLoc) -> @view.View {
  parent.box(made_for=loc, fn(r) {
    style_node(r, fn() { list_older_row })
    words_node(r, words, fn() { list_failed_words }) |> ignore
  })
}

///|
/// A list with nothing in it yet: `words`, muted, in the middle, with room over and under. The node.
#callsite(autofill(loc))
pub fn list_none_node(parent : @view.View, words : () -> String, loc~ : SourceLoc) -> @view.View {
  parent.box(made_for=loc, fn(r) {
    style_node(r, fn() { list_none_row })
    words_node(r, words, fn() { list_none_words }) |> ignore
  })
}

///|
/// The room of what comes before a list (4 over, 8 under), in its middle.
// kept across runs: a value (no field of it changes)
let list_older_row : @ui.Style = @ui.css("w=Full pt=S1 pb=S2 align=ACenter")

///|
/// The room of what comes after it (8 over, 4 under), in its middle.
// kept across runs: a value (no field of it changes)
let list_newer_row : @ui.Style = @ui.css("w=Full pt=S2 pb=S1 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let list_failed_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=true)

///|
/// A list with nothing in it: 32 over and under, in its middle.
// kept across runs: a value (no field of it changes)
let list_none_row : @ui.Style = @ui.css("w=Full py=S8 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let list_none_words : @ui.TextStyle = @ui.text_style(size=Ui, color=Muted)

///|
/// What a place holds none of (a list of files, of stations), in the middle of the room it is given: `words`, small
/// and muted, centred (empty_node's room), and under them what `more` puts there (a way to add some).
#callsite(autofill(loc))
pub fn empty_words_node(
  parent : @view.View,
  words : () -> String,
  more? : (@view.View) -> Unit = fn(_) {  },
  loc~ : SourceLoc,
) -> Unit {
  empty_node(loc~, parent, fn(e) {
    words_node(e, words, fn() { empty_words }) |> ignore
    more(e)
  })
}

///|
// kept across runs: a value (no field of it changes)
let empty_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, center=true)

///|
/// A few words pressed to say them the other way (a message's time: how long ago, or when), in `style`, on the node
/// of the button itself (no box of theirs in it): named by them, `press` done as it is pressed. While `shown` says not,
/// none of them (no room across but its gap's) and nothing to press or focus: the button disabled, which its own
/// bindings follow already (no structure and no binding more for it: a message's head has one each). The node (its
/// tip hung on it by its caller).
#callsite(autofill(loc))
pub fn words_button_node(
  parent : @view.View,
  words : () -> String,
  style : () -> @ui.TextStyle,
  press : () -> Unit,
  shown? : () -> Bool = fn() { true },
  loc~ : SourceLoc,
) -> @view.View {
  let said = fn() { if shown() { words() } else { "" } }
  @headless.button(made_for=loc, parent, said, fn(_) { press() }, disabled=fn() { !shown() }, fn(b, _) {
    focus_ring_node(b)
    styled_words(b, said, style) |> ignore
  })
}

///|
/// What still.fail says in a chat, as its pill: as wide as its words, round at its ends on the hover's ground (16 once
/// `open`; a failure's, `failed`, on the danger's), named `label`, a disclosure open while `open` says, `press` done as
/// it is pressed. On its line: what `words` puts in a room cut to it, giving way along the line to what follows; how
/// many alike it folds after them where `count` says more than one (×n, never cut short); what `end` puts at its end
/// (given the line and how tall what follows the words is held from their foot: notice_end_action_node's `strut`).
/// Open, under its line, what `detail` puts there while `detailed` says it has any. What follows the words is held to
/// the foot of their first line where `md_led` says they are Markdown (its line at the notice's leading, at the
/// system's size of words). The node.
#callsite(autofill(loc))
pub fn notice_pill_node(
  parent : @view.View,
  label : () -> String,
  open : () -> Bool,
  failed : () -> Bool,
  count : () -> Int,
  press : () -> Unit,
  words : (@view.View) -> Unit,
  md_led? : () -> Bool = fn() { false },
  end? : (@view.View, () -> Double) -> Unit = fn(_, _) {  },
  detailed? : () -> Bool = fn() { false },
  detail? : (@view.View) -> Unit = fn(_) {  },
  loc~ : SourceLoc,
) -> @view.View {
  let ink = fn() -> @ui.Color { if failed() { Danger } else { Fg } }
  // (saying whether it is open: pressed, it stays where it was pressed as it opens or closes, the framework's
  // press_stays)
  action_box_node(loc~, parent, label, expanded=open, fn(_) { press() }, fn(p) {
    // (at a chat's list's foot, what it opens to seen as it opens, the list following its foot, never left under the
    // composer: View::opens_in_sight)
    p.opens_in_sight() |> ignore
    style_node(p, fn() { notice_pill_of(failed(), open()) }, in_row=true)
    // (what it holds cut to its ground as that is drawn on its way: its words and what more there is never past it)
    p.clips(Is(true)) |> ignore
    p.box(made_for=loc, fn(line) {
      style_node(line, fn() { if open() { notice_pill_line_open } else { notice_pill_line } })
      line.box(made_for=loc, fn(room) {
        style_node(room, fn() { notice_pill_words_room }, in_row=true)
        // (giving way along the line to what it ends in, its words cut short in it: an old view's box's)
        room.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        words(room)
      })
      |> ignore
      // (what follows its words held to the foot of their first line)
      let strut = fn() {
        if md_led() {
          @ui.tree_theme().leading(notice_pill_leading).unwrap_or(0.0) * line.words_scale()
        } else {
          0.0
        }
      }
      // (how many it folds, after its words, never cut short with them)
      line.show(fn() { count() > 1 }, along_row=true, fn(n) {
        style_node(n, fn() { notice_pill_count_room.then(@ui.style(min_h=Fixed(strut()))) }, in_row=true)
        words_node(n, fn() { "×\{count()}" }, fn() { notice_pill_count_words.then(@ui.text_style(color=ink())) }) |> ignore
      })
      end(line, strut)
    })
    |> ignore
    // (what more there is of it: open only)
    // (closed, faded where it stood as the pill closes round it, out of the flow: pop_leave)
    p.show(fn() { open() && detailed() }, leave=leave_ms, pop_leave=true, fn(d) {
      style_node(d, fn() { notice_pill_detail_room })
      detail(d)
    })
  })
}

///|
/// A word at the end of a notice's pill that acts on it: " · " at 60% of the pill's ink, then `action`, underlined, in
/// it (a failure's, `failed`, the danger's), named so; not offered while it is under way (`busy`: fainter); `press`
/// done as it is pressed; held from the foot of the words before it by `strut`. The node.
#callsite(autofill(loc))
pub fn notice_end_action_node(
  parent : @view.View,
  action : () -> String,
  failed : () -> Bool,
  busy : () -> Bool,
  press : () -> Unit,
  strut? : () -> Double = fn() { 0.0 },
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(e) {
    style_node(e, fn() { notice_pill_end.then(@ui.style(min_h=Fixed(strut()))) }, in_row=true)
    e.box(made_for=loc, fn(d) {
      style_node(d, fn() { notice_pill_dot_room }, in_row=true)
      words_node(d, fn() { "·" }, fn() { if failed() { notice_pill_dot_failed } else { notice_pill_dot } }) |> ignore
    })
    |> ignore
    action_box_node(loc~, e, action, fn(_) { press() }, disabled=busy, fn(b) {
      b.box(made_for=loc, fn(w) {
        w
        .words_runs(By(fn() { [@ui.span(action(), underline=true)] }))
        .words_look(By(fn() { @ui.style_words(notice_pill_act_of(failed(), busy())) }))
        .ink(By(fn() { @ui.style_ink(notice_pill_act_of(failed(), busy())) }))
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
}

///|
/// A notice's words, closed and open: their size and their lines'.
// kept across runs: a value (never changed)
let notice_pill_size : @ui.TextSize = Meta

///|
// kept across runs: a value (never changed)
let notice_pill_leading : @ui.Leading = L7

///|
/// Its pill: as wide as its words, 6 by 14 in, round at its ends (16 once opened); the hover
/// ground, a failure's red ground.
fn notice_pill_of(failed : Bool, open : Bool) -> @ui.Style {
  match (failed, open) {
    (false, false) => notice_pill
    (false, true) => notice_pill_open
    (true, false) => notice_pill_failed
    (true, true) => notice_pill_failed_open
  }
}

///|
/// Its corner a size said, never `Full`, which is half of whatever height it is drawn at on its way and so swelled to a
/// blob as an open pill began to close: closed Xl4, more than half its height on one line, so held to round at its
/// ends; open Xl1_5.
// kept across runs: a value (no field of it changes)
let notice_pill : @ui.Style = @ui.css("max_w=Full px=S3_5 py=S1_5 radius=Xl4 bg=Hover")

///|
// kept across runs: a value (no field of it changes)
let notice_pill_open : @ui.Style = notice_pill.then(@ui.css("radius=Xl1_5"))

///|
// kept across runs: a value (no field of it changes)
let notice_pill_failed : @ui.Style = notice_pill.then(@ui.css("bg=Over(Bg, DangerBg)"))

///|
// kept across runs: a value (no field of it changes)
let notice_pill_failed_open : @ui.Style = notice_pill_open.then(@ui.css("bg=Over(Bg, DangerBg)"))

///|
/// Its words and what is done at their end: the words cut short before it, which keeps its room whole; once opened,
/// aligned with the first line of wrapped words.
// kept across runs: a value (no field of it changes)
let notice_pill_line : @ui.Style = @ui.css("row align=AEnd")

///|
/// Opened, its first line where it was closed: in the middle of the pill, which opens about its middle, so what was
/// pressed never moves across as it opens or closes (what more there is of it under it, from the pill's start).
// kept across runs: a value (no field of it changes)
let notice_pill_line_open : @ui.Style = @ui.css("row align=AStart justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let notice_pill_words_room : @ui.Style = @ui.css("clip")

///|
/// How many alike it folds (×n), after its words: kept whole as they are cut short.
// kept across runs: a value (no field of it changes)
let notice_pill_count_room : @ui.Style = @ui.css("pl=S1_5 justify=JEnd")

///|
/// ×n's words: of the notice's size and line, a little heavier, in its ink whole (its contrast on the pill's ground).
// kept across runs: a value (no field of it changes)
let notice_pill_count_words : @ui.TextStyle = @ui.text_style(
  size=notice_pill_size,
  leading=notice_pill_leading,
  weight=Medium,
  wrap=false,
)

///|
/// What more there is of it, open, under its line.
// kept across runs: a value (no field of it changes)
let notice_pill_detail_room : @ui.Style = @ui.css("w=Full pt=S1_5 gap=S1_5")

///|
// kept across runs: a value (no field of it changes)
let notice_pill_end : @ui.Style = @ui.css("row align=AEnd")

///|
/// The dot before its word: 6 each side, the pill's ink at 60%; the word, underlined; at 50% while under way.
// kept across runs: a value (no field of it changes)
let notice_pill_dot_room : @ui.Style = @ui.css("px=S1_5")

///|
// kept across runs: a value (no field of it changes)
let notice_pill_dot : @ui.TextStyle = @ui.text_style(size=Meta, leading=L7, color=A(Fg, O60), wrap=false)

///|
// kept across runs: a value (no field of it changes)
let notice_pill_dot_failed : @ui.TextStyle = notice_pill_dot.then(@ui.text_style(color=A(Danger, O60)))

///|
/// A word that acts at a notice's end, in its ink (`failed`: the danger's), at half while it is under way (`busy`).
fn notice_pill_act_of(failed : Bool, busy : Bool) -> @ui.TextStyle {
  match (failed, busy) {
    (false, false) => notice_pill_act
    (false, true) => notice_pill_act_busy
    (true, false) => notice_pill_act_failed
    (true, true) => notice_pill_act_failed_busy
  }
}

///|
// kept across runs: a value (no field of it changes)
let notice_pill_act : @ui.TextStyle = @ui.text_style(size=Meta, leading=L7, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let notice_pill_act_busy : @ui.TextStyle = notice_pill_act.then(@ui.text_style(color=A(Fg, O50)))

///|
// kept across runs: a value (no field of it changes)
let notice_pill_act_failed : @ui.TextStyle = notice_pill_act.then(@ui.text_style(color=Danger))

///|
// kept across runs: a value (no field of it changes)
let notice_pill_act_failed_busy : @ui.TextStyle = notice_pill_act.then(@ui.text_style(color=A(Danger, O50)))

///|
/// A colour's swatch in `parent`'s middle: a disc of `color` 16 across, ringed 1.5 inside its edge in white at 50% (the
/// ring the white over what is under it; the disc within it the colour), as wide room either side of it as is left.
#callsite(autofill(loc))
pub fn color_swatch_node(parent : @view.View, color : () -> Int64, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
  parent.box(made_for=loc, fn(ring) {
    ring
    .width(Is(Some(16.0)))
    .height(Is(Some(16.0)))
    .radius(Is(8.0))
    .padding(Is((1.5, 1.5, 1.5, 1.5)))
    .ground(Is(0xFFFFFF80L))
    |> ignore
    ring.box(made_for=loc, fn(d) { d.grow(Is(1.0)).radius(Is(6.5)).ground(By(color)) |> ignore }) |> ignore
  })
  |> ignore
  parent.box(made_for=loc, fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
}

///|
/// The colours to pick one of, in `row` (laid out by its caller, made the group itself: no box more), called `label`:
/// each of `colors` (its colour, its name) a swatch (color_swatch_node) on a 32 round, its ground white at 16% while it
/// is the one `chosen` says; `choose` told the colour picked (a press, an arrow key along them).
#callsite(autofill(loc))
pub fn color_swatches_node(
  row : @view.View,
  label : () -> String,
  colors : Array[(Int64, String)],
  chosen : () -> Int64,
  choose : (Int64) -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  @headless.radio_group(made_for=loc, row, label, chosen, choose, in_node=true, fn(r, rg) {
    for c in colors {
      let (color, name) = c
      rg.item(made_for=loc, r, fn() { color }, fn() { name }, fn(b, item) {
        b
        .width(Is(Some(32.0)))
        .height(Is(Some(32.0)))
        .radius(Is(16.0))
        .lines_up(Is(Some(Middle)))
        .ground(By(fn() { if item.chosen() { color_swatch_chosen } else { 0L } }))
        |> ignore
        focus_ring_node(b)
        color_swatch_node(b, fn() { color })
      })
      |> ignore
    }
  })
  |> ignore
}

///|
/// The ground of the colour picked, and of a tool in use, in the viewer's dark: white at 16%.
let color_swatch_chosen : Int64 = 0xFFFFFF29L

///|
/// A card over a chats' list (the news of the last update, what the update wants of the person), on the line of what
/// stands over the list (the theme's band_in from its sides): on the surface, round by a card's corner; pressed whole,
/// `press` done (read out as `label` says), its words rippled where it is pressed: `icon` and `title` over what `body`
/// puts under them. Where `close` is given (its tip's layer, its words, what it does), its × in its top right corner,
/// concentric with it, the words kept clear of it. The node.
#callsite(autofill(loc))
pub fn news_card_node(
  parent : @view.View,
  icon : String,
  title : () -> String,
  label : () -> String,
  press : () -> Unit,
  body : (@view.View) -> Unit,
  close? : (TipLayer, () -> String, () -> Unit),
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(room) {
    style_node(room, fn() { news_card_room.then(@ui.style(px=room_of(theme().chat_list.band_in))) })
    room.box(made_for=loc, fn(card) {
      style_node(card, fn() { news_card_ground })
      card.box(made_for=loc, fn(words) {
        style_node(words, fn() { if close is Some(_) { news_card_words_by_close } else { news_card_words } })
        rippled_node(loc~, words, press, 0.0, label)
        words.box(made_for=loc, fn(head) {
          style_node(head, fn() { news_card_head })
          icon_node(head, icon, 16.0, By(fn() { theme().p.text })) |> ignore
          words_node(head, title, fn() { news_card_title }) |> ignore
        })
        |> ignore
        body(words)
      })
      |> ignore
      match close {
        Some((tips, said, gone)) =>
          card.box(made_for=loc, fn(place) {
            style_node(place, fn() { news_card_close_place })
            place.over(Is(true)) |> ignore
            place.box(made_for=loc, fn(x) {
              style_node(x, fn() { news_card_close })
              rippled_node(loc~, x, gone, news_card_close_side / 2.0, said)
              icon_node(x, "close", 16.0, By(fn() { theme().p.muted })) |> ignore
              // (over it)
              tip_node(tips, x, said, side=Top) |> ignore
            })
            |> ignore
          })
          |> ignore
        None => ()
      }
    })
    |> ignore
  })
}

///|
/// A line of a news card (a change: 13 on 18, muted, one line).
// kept across runs: a value (no field of it changes)
pub let news_card_line : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, leading=L5, wrap=false, w=Full)

///|
/// What a news card says at length (why: its lines, whole, wrapping).
// kept across runs: a value (no field of it changes)
pub let news_card_note : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, leading=L5, w=Full)

///|
/// Its room in the list: 4 over it, 10 under.
// kept across runs: a value (no field of it changes)
let news_card_room : @ui.Style = @ui.css("w=Full pt=S1 pb=S2_5")

///|
/// The card, on the surface, round by a card's corner of the ladder's (card_corner: its × in its top right corner, 10
/// from both edges, concentric with it; the pages' radius=Xl3 was 2 short of it).
// kept across runs: a value (no field of it changes)
let news_card_ground : @ui.Style = @ui.css("w=Full bg=Surface clip").then(@ui.style(radius=rounded(card_corner)))

///|
/// What it says, 16 in (44 on the right where it has a ×), 12 over and under, its lines 2 apart.
// kept across runs: a value (no field of it changes)
let news_card_words_by_close : @ui.Style = @ui.css("w=Full pl=S4 pr=S11 pt=S3 pb=S3 gap=S0_5")

///|
// kept across runs: a value (no field of it changes)
let news_card_words : @ui.Style = @ui.css("w=Full px=S4 pt=S3 pb=S3 gap=S0_5")

///|
/// Its head: the icon and the title, 6 apart, 2 over the lines.
// kept across runs: a value (no field of it changes)
let news_card_head : @ui.Style = @ui.css("row pb=S0_5 gap=S1_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let news_card_title : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=Fg, wrap=false)

///|
/// Its ×: 32, round, as far from the card's top and right as makes it concentric with its corner (capsule_in: 10).
// kept across runs: a value (no field of it changes)
let news_card_close_place : @ui.Style = @ui.style(w=Full, p=room_of(@ui.capsule_in(card_corner, news_card_close_side)), align=AEnd)

///|
/// Its ×'s side (news_card_close's S8).
let news_card_close_side : Double = 32.0

///|
// kept across runs: a value (no field of it changes)
let news_card_close : @ui.Style = @ui.css("w=S8 h=S8 radius=Full align=ACenter justify=JCenter")
