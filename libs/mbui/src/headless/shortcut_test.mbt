// A shortcut in the system's own words (@headless.format_stroke, stroke_caps, format_chord, platform_stroke): a Mac's
// keys and Windows' or Linux's, each in its own order and names, from one stroke as the keymap binds it.

///|
/// The stroke of character `c` with `mods` held (ui's key codes: a character 1000 and its code).
fn ch(c : Char, mods? : Int = 0) -> @view.Stroke {
  { code: 1000 + c.to_int(), mods }
}

///|
/// The stroke of key `code` with `mods` held.
fn key(code : Int, mods? : Int = 0) -> @view.Stroke {
  { code, mods }
}

///|
/// Held: Shift 1, Control 2, Alt (Option) 4, Command (Win) 8.
let shift : Int = 1

///|
let ctrl : Int = 2

///|
let alt : Int = 4

///|
let cmd : Int = 8

///|
test "a key alone: its capital, a letter as on its keycap; a sign as it is" {
  assert_eq(
    (
      @headless.format_stroke(ch('k'), apple=true),
      @headless.format_stroke(ch('k'), apple=false),
      @headless.format_stroke(ch('/'), apple=true),
      @headless.format_stroke(ch('/'), apple=false),
      @headless.format_stroke(ch('K'), apple=false),
    ),
    ("K", "K", "/", "/", "K"),
  )
}

///|
test "⌘K on a Mac's keys; elsewhere Ctrl+K, Command taken as Control by platform_stroke and Win read as it is" {
  let s = ch('k', mods=cmd)
  assert_eq(
    (
      @headless.format_stroke(s, apple=true),
      @headless.format_stroke(@headless.platform_stroke(s, apple=false), apple=false),
      @headless.format_stroke(s, apple=false),
      @headless.platform_stroke(s, apple=true) == s,
      @headless.format_stroke(ch('k', mods=ctrl), apple=true),
    ),
    ("⌘K", "Ctrl+K", "Win+K", true, "⌃K"),
  )
}

///|
test "all four held: ⌃⌥⇧⌘ in Apple's order; Ctrl, Alt, Shift in Windows' order, Command kept as Win where Control is held" {
  let all = ch('p', mods=shift | ctrl | alt | cmd)
  let three = ch('p', mods=shift | alt | cmd)
  assert_eq(
    (
      @headless.format_stroke(all, apple=true),
      @headless.stroke_caps(all, apple=true),
      @headless.format_stroke(three, apple=true),
      @headless.format_stroke(@headless.platform_stroke(three, apple=false), apple=false),
      @headless.format_stroke(@headless.platform_stroke(all, apple=false), apple=false),
      @headless.stroke_caps(three, apple=false),
    ),
    (
      "⌃⌥⇧⌘P",
      ["⌃", "⌥", "⇧", "⌘", "P"],
      "⌥⇧⌘P",
      "Ctrl+Alt+Shift+P",
      "Ctrl+Alt+Shift+Win+P",
      ["Alt", "Shift", "Win", "P"],
    ),
  )
}

///|
test "named keys: each system's glyph or word, arrows the same on both" {
  let codes = [1, 2, 3, 4, 5, 6, 7, 8, 9, 15, 16, 17, 18, 1032]
  assert_eq(
    (
      codes.map(fn(c) { @headless.format_stroke(key(c), apple=true) }),
      codes.map(fn(c) { @headless.format_stroke(key(c), apple=false) }),
    ),
    (
      ["⌫", "⌦", "←", "→", "↑", "↓", "↩", "↖", "↘", "⇞", "⇟", "⎋", "⇥", "Space"],
      [
        "Backspace", "Delete", "←", "→", "↑", "↓", "Enter", "Home", "End", "PgUp", "PgDn", "Esc", "Tab", "Space",
      ],
    ),
  )
}

///|
test "named keys held with modifiers: ⇧⇥, ⌘↩, ⌘ Space set apart; Shift+Tab, Ctrl+Enter, Ctrl+Space" {
  assert_eq(
    (
      @headless.format_stroke(key(18, mods=shift), apple=true),
      @headless.format_stroke(key(7, mods=cmd), apple=true),
      @headless.format_stroke(key(1032, mods=cmd), apple=true),
      @headless.format_stroke(key(18, mods=shift), apple=false),
      @headless.format_stroke(@headless.platform_stroke(key(7, mods=cmd), apple=false), apple=false),
      @headless.format_stroke(key(1032, mods=ctrl), apple=false),
      @headless.format_stroke(key(1, mods=alt), apple=true),
      @headless.format_stroke(key(1, mods=alt), apple=false),
    ),
    ("⇧⇥", "⌘↩", "⌘ Space", "Shift+Tab", "Ctrl+Enter", "Ctrl+Space", "⌥⌫", "Alt+Backspace"),
  )
}

///|
test "keys one after another: G then I; ⌘K then ←, Ctrl+K ← elsewhere; none, nothing" {
  let go = [ch('g'), ch('i')]
  let move_ = [ch('k', mods=cmd), key(3)]
  assert_eq(
    (
      @headless.format_chord(go, apple=true),
      @headless.format_chord(go, apple=false),
      @headless.format_chord(move_, apple=true),
      @headless.format_chord(move_.map(fn(s) { @headless.platform_stroke(s, apple=false) }), apple=false),
      @headless.format_chord([], apple=true),
    ),
    ("G I", "G I", "⌘K ←", "Ctrl+K ←", ""),
  )
}

///|
test "a key with no name is said as its code, never left out" {
  assert_eq(
    (
      @headless.format_stroke(key(12), apple=true),
      @headless.format_stroke(key(12, mods=ctrl), apple=false),
    ),
    ("#12", "Ctrl+#12"),
  )
}
