// A count as a mark of its own (数字角标) as a node of the window's tree, made once: what waits somewhere, said by how
// many. Two looks: a mark (`Mark`) hung on what it counts, the tone's solid ground and its ink on it, 16 high and round
// (as wide as its figures, 16 at the least), its figures part of it at the size they are said whatever the system's size
// of words (mark_words_node), so it never outgrows its 16; with no count a dot 8 across (what waits, not how many).
// And a count in a line (`Inline`) beside a title, the tone's tint and its ink, a capsule as tall as its words at the
// system's size of words, growing with them. Past `max` it says `max+` (99+).

///|
/// How a count is drawn: a mark hung on what it counts (`Mark`, 16 high whatever the size of words; a dot without a
/// count), or a capsule in a line of words (`Inline`, growing with them).
#derive(Eq, Debug)
pub(all) enum CountLook {
  Mark
  Inline
}

///|
/// The count's tone: `CountRed` (what waits on someone: the danger's red) or `CountAccent` (the accent's; a mark with
/// figures the primary ink's, since small white figures on the accent fall short of 4.5:1).
#derive(Eq, Debug)
pub(all) enum CountTone {
  CountRed
  CountAccent
}

///|
/// What a count `n` says, past `max` (none: no end) `max+`.
pub fn count_words(n : Int, max? : Int) -> String {
  match max {
    Some(m) if n > m => m.to_string() + "+"
    _ => n.to_string()
  }
}

///|
/// A count in `parent` as `look` draws it in `tone`: `count` how many now (none, a `Mark`: a dot 8 across), past `max`
/// said `max+`. The node.
#callsite(autofill(loc))
pub fn count_badge_node(
  parent : @view.View,
  count? : () -> Int,
  look? : CountLook = Mark,
  tone? : CountTone = CountRed,
  max? : Int,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(b) {
    match (look, count) {
      (Mark, None) => style_node(b, fn() { count_dot_look(tone) })
      (Mark, Some(n)) => {
        style_node(b, fn() { count_mark_look(tone) })
        mark_words_node(b, fn() { count_words(n(), max?) }, fn() { count_mark_words(tone) }) |> ignore
      }
      (Inline, _) => {
        let n = count.unwrap_or(fn() { 0 })
        style_node(b, fn() { count_inline_look(tone) })
        words_node(b, fn() { count_words(n(), max?) }, fn() { count_inline_words(tone) }) |> ignore
      }
    }
  })
}

///|
fn count_dot_look(tone : CountTone) -> @ui.Style {
  match tone {
    CountRed => count_dot_danger
    CountAccent => count_dot_accent
  }
}

///|
fn count_mark_look(tone : CountTone) -> @ui.Style {
  match tone {
    CountRed => count_mark_danger
    CountAccent => count_mark_accent
  }
}

///|
fn count_mark_words(tone : CountTone) -> @ui.TextStyle {
  match tone {
    CountRed => count_mark_words_danger
    CountAccent => count_mark_words_accent
  }
}

///|
fn count_inline_look(tone : CountTone) -> @ui.Style {
  match tone {
    CountRed => count_inline_danger
    CountAccent => count_inline_accent
  }
}

///|
fn count_inline_words(tone : CountTone) -> @ui.TextStyle {
  match tone {
    CountRed => count_inline_words_danger
    CountAccent => count_inline_words_accent
  }
}

///|
/// A mark with no count: a dot 8 across, the tone's.
// kept across runs: a value (no field of it changes)
let count_dot_danger : @ui.Style = @ui.css("w=S2 h=S2 radius=Full bg=Danger")

///|
// kept across runs: a value (no field of it changes)
let count_dot_accent : @ui.Style = @ui.css("w=S2 h=S2 radius=Full bg=Accent")

///|
/// A mark's count: 16 high and round, as wide as its figures and 4 in at either end, 16 at the least, its figures in
/// its middle.
// kept across runs: a value (no field of it changes)
let count_mark_danger : @ui.Style = @ui.css("row h=S4 min_w=S4 px=S1 radius=Full bg=Danger align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let count_mark_accent : @ui.Style = @ui.css("row h=S4 min_w=S4 px=S1 radius=Full bg=Primary align=ACenter justify=JCenter")

///|
/// A mark's figures: the caption's size, semibold, the tone's ink on it.
// kept across runs: a value (no field of it changes)
let count_mark_words_danger : @ui.TextStyle = @ui.text_style(size=Caption, weight=Semibold, color=OnDanger, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let count_mark_words_accent : @ui.TextStyle = @ui.text_style(size=Caption, weight=Semibold, color=OnPrimary, wrap=false)

///|
/// A count in a line: the tone's tint, round, 6 in at either end, as tall as its words.
// kept across runs: a value (no field of it changes)
let count_inline_danger : @ui.Style = @ui.css("px=S1_5 radius=Full bg=DangerBg")

///|
// kept across runs: a value (no field of it changes)
let count_inline_accent : @ui.Style = @ui.css("px=S1_5 radius=Full bg=AccentBg")

///|
/// A count in a line's words: Meta, medium, the tone's ink.
// kept across runs: a value (no field of it changes)
let count_inline_words_danger : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, weight=Medium, color=Danger, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let count_inline_words_accent : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, weight=Medium, color=AccentText, wrap=false)
