// What the keyboard sends a terminal (a key catcher's: @ui.key_catcher_node), as a terminal program reads it: the bytes
// xterm sends, as text. Words typed go as they are; a key as it goes down (its letting go sends nothing): Enter a carriage
// return, Backspace DEL, the arrows `ESC [ A` (`ESC O A` where the program asked for the application cursor keys,
// `keys`), with Shift, Alt or Ctrl held xterm's `ESC [ 1 ; m A`; Ctrl with a letter its control character, Alt before
// a character ESC. ⌘ with a key is this device's (its shortcuts), not the terminal's.

///|
/// What key `k` sends the terminal; "" for nothing (a key let go, a shortcut of ⌘).
fn terminal_keys_of(k : @ui.KeyIn, keys : Bool) -> String {
  match k {
    Text(words) => words
    Key(down=false, ..) => ""
    Key(key~, code~, mods~, ..) => {
      if (mods & @ui.key_in_meta) != 0 {
        return ""
      }
      let shift = (mods & @ui.key_in_shift) != 0
      let alt = (mods & @ui.key_in_alt) != 0
      let ctrl = (mods & @ui.key_in_ctrl) != 0
      // (xterm's modifier number: 1 + Shift 1, Alt 2, Ctrl 4)
      let m = 1 + (if shift { 1 } else { 0 }) + (if alt { 2 } else { 0 }) + (if ctrl { 4 } else { 0 })
      let esc = "\u{1b}"
      let cursor = fn(c : String) {
        if m > 1 {
          esc + "[1;" + m.to_string() + c
        } else if keys {
          esc + "O" + c
        } else {
          esc + "[" + c
        }
      }
      let tilde = fn(n : String) { if m > 1 { esc + "[" + n + ";" + m.to_string() + "~" } else { esc + "[" + n + "~" } }
      let alt_of = fn(s : String) { if alt { esc + s } else { s } }
      let ss3 = fn(c : String) { if m > 1 { esc + "[1;" + m.to_string() + c } else { esc + "O" + c } }
      match code {
        "ArrowUp" => cursor("A")
        "ArrowDown" => cursor("B")
        "ArrowRight" => cursor("C")
        "ArrowLeft" => cursor("D")
        "Home" => cursor("H")
        "End" => cursor("F")
        "Delete" => tilde("3")
        "PageUp" => tilde("5")
        "PageDown" => tilde("6")
        // (F1-F4 as SS3, F5-F12 as their numbers, xterm's)
        "F1" => ss3("P")
        "F2" => ss3("Q")
        "F3" => ss3("R")
        "F4" => ss3("S")
        "F5" => tilde("15")
        "F6" => tilde("17")
        "F7" => tilde("18")
        "F8" => tilde("19")
        "F9" => tilde("20")
        "F10" => tilde("21")
        "F11" => tilde("23")
        "F12" => tilde("24")
        "Enter" => alt_of("\r")
        "Backspace" => alt_of(if ctrl { "\u{08}" } else { "\u{7f}" })
        "Tab" => if shift { esc + "[Z" } else { alt_of("\t") }
        "Escape" => alt_of(esc)
        "Space" => alt_of(if ctrl { "\u{00}" } else { " " })
        _ => {
          guard key.length() == 1 else { return "" }
          let ch = key.to_array()[0]
          if ctrl {
            let lower = if ch >= 'A' && ch <= 'Z' { ch.to_int() + 32 } else { ch.to_int() }
            let c = if lower >= 'a'.to_int() && lower <= 'z'.to_int() {
              lower - 'a'.to_int() + 1
            } else {
              match ch {
                '@' | '2' => 0
                '[' | '3' => 27
                '\\' | '4' => 28
                ']' | '5' => 29
                '^' | '6' => 30
                '_' | '-' | '7' => 31
                '/' => 31
                '8' | '?' => 127
                _ => -1
              }
            }
            if c < 0 {
              ""
            } else {
              alt_of(c.unsafe_to_char().to_string())
            }
          } else {
            // (Alt with a character: ESC before it, as a terminal's Meta)
            alt_of(key)
          }
        }
      }
    }
  }
}

///|
/// Whether key `k` asks to paste the device's clipboard into the terminal (`⌘V` on Mac, `Ctrl+Shift+V` elsewhere; plain
/// `Ctrl+V` stays the terminal's own literal-next `^V`).
fn terminal_paste_key(k : @ui.KeyIn) -> Bool {
  match k {
    Key(down=true, code="KeyV", mods~, ..) =>
      (mods & @ui.key_in_alt) == 0 &&
      ((mods & @ui.key_in_meta) != 0 || ((mods & @ui.key_in_ctrl) != 0 && (mods & @ui.key_in_shift) != 0))
    _ => false
  }
}

///|
/// Whether the program asked for bracketed paste (`?2004h`), as the host's lines say (`"paste":1` in their head).
fn terminal_bracketed_paste(said : String) -> Bool {
  let head = if said.length() > 140 { said.unsafe_substring(start=0, end=140) } else { said }
  head.contains("\"paste\":1")
}

///|
/// What pasting `words` sends the terminal: bracketed (`ESC [ 200 ~ … ESC [ 201 ~`, any bracketed-end inside `words`
/// stripped so pasted text cannot break out of the bracket) where `bracketed` holds, else `words` as they are.
fn terminal_pasted_of(words : String, bracketed : Bool) -> String {
  if words == "" {
    return ""
  }
  if bracketed {
    "\u{1b}[200~" + words.replace_all(old="\u{1b}[201~", new="") + "\u{1b}[201~"
  } else {
    words
  }
}

///|
/// Whether the program asked for the application cursor keys, as the host's lines say (`"keys":1` in their head,
/// @hostapi.Terminal::lines): read off the head alone, not the lines.
fn terminal_app_keys(said : String) -> Bool {
  let head = if said.length() > 120 { said.unsafe_substring(start=0, end=120) } else { said }
  head.contains("\"keys\":1")
}

///|
/// What is typed with the keys row's modifiers held (`mods`, key_in_*: ctrl, alt pressed on the row, for the next key):
/// a single character typed comes as its key with them (ctrl then c: Ctrl+C), a key with them added; more words take
/// the modifier on their first character and the rest as they are.
fn terminal_held(k : @ui.KeyIn, mods : Int) -> @ui.KeyIn {
  if mods == 0 {
    return k
  }
  match k {
    Text(words) if words.length() == 1 =>
      Key(down=true, key=words, code=if words == " " { "Space" } else { "" }, mods~)
    Text(words) if words.length() > 1 => {
      let cs = words.to_array()
      let first = cs[0].to_string()
      let rest = String::from_array(cs[1:].to_owned())
      let head = terminal_keys_of(
        Key(down=true, key=first, code=if first == " " { "Space" } else { "" }, mods~),
        false,
      )
      Text(head + rest)
    }
    Key(down~, key~, code~, mods=own) => Key(down~, key~, code~, mods=own | mods)
    other => other
  }
}

///|
/// The visible text of the terminal's screen (`said`, as the host gives it), trailing empty lines dropped, for copying.
fn terminal_plain_text(said : String) -> String {
  let parsed = @json.parse(said) catch { _ => return "" }
  let rows : Array[String] = []
  match parsed {
    Object(o) =>
      match o.get("lines") {
        Some(Array(lines)) =>
          for line in lines {
            let buf = StringBuilder()
            match line {
              Array(runs) =>
                for r in runs {
                  match r {
                    Array([String(t), ..]) => buf.write_string(t)
                    _ => ()
                  }
                }
              _ => ()
            }
            rows.push(buf.to_string())
          }
        _ => ()
      }
    _ => ()
  }
  while !rows.is_empty() && rows[rows.length() - 1].trim().is_empty() {
    rows.pop() |> ignore
  }
  rows.join("\n")
}
