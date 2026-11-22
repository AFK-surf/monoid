// Generic request-card answered-in-place and outcome-line nodes (shared by vault/rig/phone/sign-in/login cards).

///|
/// A card's answer at its foot in `v` (answered_in_place's, as nodes): `answer` while `ended()` is None; once it is
/// Some((granted, words)), `answer` fades out (answered_fade_ms, not pressed) and the outcome line (dot + words) fades
/// in over its room after it.
#callsite(autofill(loc))
pub fn answered_in_place_node(
  v : @view.View,
  ended : () -> (Bool, Array[@ui.Run])?,
  answer : (@view.View) -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  let gone = fn() { ended() is Some(_) }
  let first = @signals.untracked(gone)
  let was = @motion.NodeWay::new(if first { 0.0 } else { 1.0 })
  let now = @motion.NodeWay::new(if first { 1.0 } else { 0.0 })
  v.box(made_for=loc, fn(whole) {
    style_node(whole, fn() { answered_whole })
    whole.reacts(gone, fn(g) {
      if g {
        was.go_ms(whole, 0.0, answered_fade_ms, ease=Leave)
        now.go(whole, 1.0, @motion.tween(answered_fade_ms, ease=Out, delay=answered_fade_ms))
      } else {
        now.put(0.0)
        was.put(1.0)
      }
    })
    whole.box(fn(a) {
      style_node(a, fn() { answered_room })
      a.alpha(By(fn() { was.shown(a) })).presses(By(fn() { !gone() })) |> ignore
      answer(a)
    })
    |> ignore
    // (over the answer's room, the whole of it)
    whole.box(fn(o) {
      o.over(Is(true)).alpha(By(fn() { now.shown(o) })) |> ignore
      o.box(fn(r) {
        style_node(r, fn() { answered_over })
        r.box(fn(d) {
          style_node(d, fn() {
            match ended() {
              Some((true, _)) => ask_dot_on
              _ => ask_dot
            }
          })
        })
        |> ignore
        r.box(fn(w) {
          w
          .words_runs(By(fn() { ended().map(fn(e) { e.1 }).unwrap_or([]) }))
          .words_look(By(fn() { @ui.style_words(ask_ended_words) }))
          .ink(By(fn() { @ui.style_ink(ask_ended_words) }))
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// A request's outcome line in `v` (ask_outcome's, as nodes), as they say it now: a dot (green while `granted`) and its
/// `words`; the dot in the middle of the words' first line, under the message's picture as wide as it where the
/// message's head is `inline`, else out in the margin where the picture is, the words at the row's start. `history`:
/// pressed, the card read again (given what it opens from).
#callsite(autofill(loc))
pub fn ask_outcome_node(
  v : @view.View,
  granted : () -> Bool,
  words : () -> Array[@ui.Run],
  inline : () -> Bool,
  history? : ((@view.View) -> Unit)? = None,
  loc~ : SourceLoc,
) -> Unit {
  let th = ui_theme()
  let line = th.leading(ask_ended_leading).unwrap_or(th.text_size(ask_ended_size).1)
  v.box(made_for=loc, fn(o) {
    style_node(o, fn() { ask_ended })
    o.box(fn(w) {
      style_node(w, fn() {
        let base = if inline() { ask_ended_past } else { ask_ended_at }
        if history is Some(_) {
          base.then(ask_ended_start)
        } else {
          base
        }
      })
      match history {
        Some(open) => ask_history_trigger_node(w, words, fn() { ask_ended_words }, line, open) |> ignore
        None =>
          w.box(fn(t) {
            t
            .words_runs(By(words))
            .words_look(By(fn() { @ui.style_words(ask_ended_words) }))
            .ink(By(fn() { @ui.style_ink(ask_ended_words) }))
            |> ignore
          })
          |> ignore
      }
    })
    |> ignore
    // (over the line, the whole of it: the dot's room)
    o.box(fn(l) {
      l.over(Is(true)) |> ignore
      l.box(fn(d) {
        style_node(d, fn() {
          (if inline() { ask_dot_line } else { ask_dot_line_out }).then(@ui.style(h=Fixed(node_sp(d, line))))
        })
        d.box(fn(x) { style_node(x, fn() { if granted() { ask_dot_on } else { ask_dot } }) }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// How long a card's answer takes to fade out as it is answered, and how it went to fade in after it.
pub let answered_fade_ms : Double = 200.0

///|
/// How it ended: a dot and its words, a little under what is over it.
// kept across runs: a value (no field of it changes)
pub let ask_ended : @ui.Style = @ui.css("w=Full mt=S0_5")

///|
/// Its words inline: past the message's picture, where its name is (the app's message.mbt msg_head_inline).
// kept across runs: a value (no field of it changes)
pub let ask_ended_past : @ui.Style = @ui.style(w=Full, pl=message_head_in)

///|
/// Its words with the picture out in the margin: at the row's start, as the name is.
// kept across runs: a value (no field of it changes)
pub let ask_ended_at : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
pub let ask_ended_start : @ui.Style = @ui.css("align=AStart")

///|
/// Where the dot stands: as wide as the message's picture (18) and under it, the dot in its middle; as high as a line
/// of the words, the theme's (ask_outcome_node).
// kept across runs: a value (no field of it changes)
pub let ask_dot_line : @ui.Style = @ui.css("row w=S4_5 align=ACenter justify=JCenter")

///|
/// The same out in the margin, where the picture is then (message_avatar_out).
// kept across runs: a value (no field of it changes)
pub let ask_dot_line_out : @ui.Style = ask_dot_line.then(@ui.style(ml=message_avatar_out))

///|
/// A card's answer's room at its foot (answered_in_place_node): the card's width, what is in it as far apart as in the
/// card (ask_card_node's 14).
// kept across runs: a value (no field of it changes)
pub let answered_room : @ui.Style = @ui.css("w=Full gap=S3_5")

///|
/// What holds a card's answer and how it went over it (answered_in_place_node): the card's width.
// kept across runs: a value (no field of it changes)
pub let answered_whole : @ui.Style = @ui.css("w=Full")

///|
/// How it went over a card's answer's room: its dot and its words on a line in the middle of the room's height.
// kept across runs: a value (no field of it changes)
pub let answered_over : @ui.Style = @ui.css("row w=Full h=Full gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
pub let ask_ended_words : @ui.TextStyle = @ui.text_style(size=ask_ended_size, leading=ask_ended_leading, color=Muted)

///|
/// Its words' size and line (ask_ended_words), the line the dot beside them stands in the middle of.
// kept across runs: a value (no field of it changes)
pub let ask_ended_size : @ui.TextSize = Meta

///|
// kept across runs: a value (no field of it changes)
pub let ask_ended_leading : @ui.Leading = L5

///|
/// Its dot, 6 round: green once granted, else quiet.
// kept across runs: a value (no field of it changes)
pub let ask_dot : @ui.Style = @ui.css("w=S1_5 h=S1_5 radius=Full bg=Subtle")

///|
// kept across runs: a value (no field of it changes)
pub let ask_dot_on : @ui.Style = @ui.css("w=S1_5 h=S1_5 radius=Full bg=Positive")
