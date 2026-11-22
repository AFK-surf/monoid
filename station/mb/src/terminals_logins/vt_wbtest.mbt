// What @xterm/headless 6.0.0 makes of writes as login commands make them: each case's screen, cursor and answers as
// it gave them (station/test/mb-terminals-logins.test.ts holds the terminal to it on random writes too).

///|
fn vt_of(cols : Int, rows : Int, scrollback : Int, writes : Array[String]) -> (Array[String], Int, Int, Array[String]) {
  let vt = Vt::new(cols, rows, scrollback)
  let replies = []
  vt.on_data(d => replies.push(d))
  vt.osc(10, data => if data == "?" {
    replies.push("\u{1b}]10;rgb:0000/0000/0000\u{1b}\\")
    true
  } else {
    false
  })
  vt.osc(11, data => if data == "?" {
    replies.push("\u{1b}]11;rgb:ffff/ffff/ffff\u{1b}\\")
    true
  } else {
    false
  })
  for w in writes {
    vt.write(w)
  }
  (Array::makei(rows, i => vt.row(i)), vt.cursor_x(), vt.cursor_y(), replies)
}

///|
test "the terminal: a line and its end" {
  let (rows, x, y, replies) = vt_of(20, 4, 0, ["hello\u{d}\u{a}world"])
  assert_eq(rows, ["hello", "world", "", ""])
  assert_eq((x, y), (5, 1))
  assert_eq(replies, [])
}

///|
test "the terminal: LF keeps the column; CR goes back" {
  let (rows, x, y, replies) = vt_of(20, 4, 0, ["ab\u{a}cd\u{d}X"])
  assert_eq(rows, ["ab", "X cd", "", ""])
  assert_eq((x, y), (1, 1))
  assert_eq(replies, [])
}

///|
test "the terminal: a line past the width wraps; the cursor waits at the width" {
  let (rows, x, y, replies) = vt_of(10, 4, 0, ["0123456789", "a"])
  assert_eq(rows, ["0123456789", "a", "", ""])
  assert_eq((x, y), (1, 1))
  assert_eq(replies, [])
}

///|
test "the terminal: the width itself, then a line feed" {
  let (rows, x, y, replies) = vt_of(10, 4, 0, ["0123456789\u{d}\u{a}"])
  assert_eq(rows, ["0123456789", "", "", ""])
  assert_eq((x, y), (0, 1))
  assert_eq(replies, [])
}

///|
test "the terminal: scrolled off the top" {
  let (rows, x, y, replies) = vt_of(10, 3, 5, ["1\u{d}\u{a}2\u{d}\u{a}3\u{d}\u{a}4\u{d}\u{a}5"])
  assert_eq(rows, ["3", "4", "5"])
  assert_eq((x, y), (1, 2))
  assert_eq(replies, [])
}

///|
test "the terminal: no scrollback: lines dropped" {
  let (rows, x, y, replies) = vt_of(10, 2, 0, ["a\u{d}\u{a}b\u{d}\u{a}c\u{d}\u{a}d"])
  assert_eq(rows, ["c", "d"])
  assert_eq((x, y), (1, 1))
  assert_eq(replies, [])
}

///|
test "the terminal: a wide character takes two cells; one at the last cell wraps" {
  let (rows, x, y, replies) = vt_of(5, 3, 0, ["\u{4e2d}\u{6587}", "abc\u{4e2d}"])
  assert_eq(rows, ["\u{4e2d}\u{6587}a", "bc\u{4e2d}", ""])
  assert_eq((x, y), (4, 1))
  assert_eq(replies, [])
}

///|
test "the terminal: a combining mark joins the character before it" {
  let (rows, x, y, replies) = vt_of(10, 2, 0, ["e\u{301}x", "\u{301}"])
  assert_eq(rows, ["e\u{301}x\u{301}", ""])
  assert_eq((x, y), (2, 0))
  assert_eq(replies, [])
}

///|
test "the terminal: an emoji is one cell (Unicode 6)" {
  let (rows, x, y, replies) = vt_of(10, 2, 0, ["\u{1f389}\u{1f389}x"])
  assert_eq(rows, ["\u{1f389}\u{1f389}x", ""])
  assert_eq((x, y), (3, 0))
  assert_eq(replies, [])
}

///|
test "the terminal: erase in line, display; trailing spaces kept where written" {
  let (rows, x, y, replies) = vt_of(10, 3, 0, ["abc   \u{d}\u{a}xyz\u{1b}[2D\u{1b}[K", "\u{1b}[1;2H\u{1b}[1K"])
  assert_eq(rows, ["  c   ", "x", ""])
  assert_eq((x, y), (1, 0))
  assert_eq(replies, [])
}

///|
test "the terminal: cursor moves clamp; CUP past the screen" {
  let (rows, x, y, replies) = vt_of(10, 4, 0, ["\u{1b}[99;99Hx\u{1b}[A\u{1b}[5DY\u{1b}[0;0HZ"])
  assert_eq(rows, ["Z", "", "    Y", "         x"])
  assert_eq((x, y), (1, 0))
  assert_eq(replies, [])
}

///|
test "the terminal: insert and delete characters and lines" {
  let (rows, x, y, replies) = vt_of(10, 4, 0, ["abcdef\u{1b}[1;3H\u{1b}[2@XY\u{1b}[1;1H\u{1b}[P", "\u{d}\u{a}line2\u{d}\u{a}line3\u{1b}[2;1H\u{1b}[L"])
  assert_eq(rows, ["bXYcdef", "", "line2", "line3"])
  assert_eq((x, y), (0, 1))
  assert_eq(replies, [])
}

///|
test "the terminal: a scroll region scrolls only itself" {
  let (rows, x, y, replies) = vt_of(10, 5, 0, ["1\u{d}\u{a}2\u{d}\u{a}3\u{d}\u{a}4\u{d}\u{a}5\u{1b}[2;4r\u{1b}[4;1H\u{a}\u{a}X"])
  assert_eq(rows, ["1", "4", "", "X", "5"])
  assert_eq((x, y), (1, 3))
  assert_eq(replies, [])
}

///|
test "the terminal: origin mode and the region" {
  let (rows, x, y, replies) = vt_of(10, 5, 0, ["\u{1b}[2;4r\u{1b}[?6h\u{1b}[1;1HA\u{1b}[9;1HB\u{1b}[?6l"])
  assert_eq(rows, ["", "A", "", "B", ""])
  assert_eq((x, y), (0, 0))
  assert_eq(replies, [])
}

///|
test "the terminal: save and restore the cursor" {
  let (rows, x, y, replies) = vt_of(10, 3, 0, ["ab\u{1b}7\u{d}\u{a}cd\u{1b}8X\u{1b}[s\u{1b}[3;1H\u{1b}[uY"])
  assert_eq(rows, ["abXY", "cd", ""])
  assert_eq((x, y), (4, 0))
  assert_eq(replies, [])
}

///|
test "the terminal: the alternate screen and back" {
  let (rows, x, y, replies) = vt_of(10, 3, 0, ["main\u{1b}[?1049h\u{1b}[Halt\u{1b}[?1049lZ"])
  assert_eq(rows, ["mainZ", "", ""])
  assert_eq((x, y), (5, 0))
  assert_eq(replies, [])
}

///|
test "the terminal: DEC graphics; SO and SI" {
  let (rows, x, y, replies) = vt_of(10, 2, 0, ["\u{1b}(0lqk\u{1b}(B lqk\u{1b})0\u{e}q\u{f}q"])
  assert_eq(rows, ["\u{250c}\u{2500}\u{2510} lqk\u{2500}q", ""])
  assert_eq((x, y), (9, 0))
  assert_eq(replies, [])
}

///|
test "the terminal: tabs, a tab stop set and cleared" {
  let (rows, x, y, replies) = vt_of(30, 2, 0, ["a\u{9}b\u{9}c\u{d}\u{1b}[5C\u{1b}H\u{1b}[0g\u{d}\u{9}1\u{1b}[3g\u{d}\u{9}2"])
  assert_eq(rows, ["a       1       c            2", ""])
  assert_eq((x, y), (30, 0))
  assert_eq(replies, [])
}

///|
test "the terminal: the answers: device attributes, status, position, modes, status strings" {
  let (rows, x, y, replies) = vt_of(20, 4, 0, ["ab\u{1b}[c\u{1b}[>c\u{1b}[5n\u{1b}[6n\u{1b}[?6n\u{1b}[?2004$p\u{1b}[4$p\u{1b}P$qr\u{1b}\\\u{1b}P$qm\u{1b}\\"])
  assert_eq(rows, ["ab", "", "", ""])
  assert_eq((x, y), (2, 0))
  assert_eq(replies, ["\u{1b}[?1;2c", "\u{1b}[>0;276;0c", "\u{1b}[0n", "\u{1b}[1;3R", "\u{1b}[?1;3R", "\u{1b}[?2004;2$y", "\u{1b}[4;2$y", "\u{1b}P1$r1;4r\u{1b}\\", "\u{1b}P1$r0m\u{1b}\\"])
}

///|
test "the terminal: OSC colours asked: 10 and 11 answered, others not" {
  let (rows, x, y, replies) = vt_of(20, 2, 0, ["\u{1b}]10;?\u{7}\u{1b}]11;?\u{1b}\\\u{1b}]4;1;?\u{7}\u{1b}]0;title\u{7}x"])
  assert_eq(rows, ["x", ""])
  assert_eq((x, y), (1, 0))
  assert_eq(replies, ["\u{1b}]10;rgb:0000/0000/0000\u{1b}\\", "\u{1b}]11;rgb:ffff/ffff/ffff\u{1b}\\"])
}

///|
test "the terminal: insert mode" {
  let (rows, x, y, replies) = vt_of(10, 2, 0, ["abc\u{1b}[1;1H\u{1b}[4hXY\u{1b}[4lZ"])
  assert_eq(rows, ["XYZbc", ""])
  assert_eq((x, y), (3, 0))
  assert_eq(replies, [])
}

///|
test "the terminal: no autowrap: the last cell overwritten" {
  let (rows, x, y, replies) = vt_of(5, 2, 0, ["\u{1b}[?7labcdefg"])
  assert_eq(rows, ["abcdg", ""])
  assert_eq((x, y), (5, 0))
  assert_eq(replies, [])
}

///|
test "the terminal: protected cells kept by a selective erase" {
  let (rows, x, y, replies) = vt_of(10, 2, 0, ["\u{1b}[1\"qAB\u{1b}[0\"qCD\u{1b}[1;1H\u{1b}[?2K"])
  assert_eq(rows, ["AB", ""])
  assert_eq((x, y), (0, 0))
  assert_eq(replies, [])
}

///|
test "the terminal: a full reset" {
  let (rows, x, y, replies) = vt_of(10, 2, 0, ["junk\u{1b}[2;5r\u{1b}cok"])
  assert_eq(rows, ["ok", ""])
  assert_eq((x, y), (2, 0))
  assert_eq(replies, [])
}

///|
test "the terminal: repeat the character before" {
  let (rows, x, y, replies) = vt_of(10, 2, 0, ["a\u{1b}[3bx\u{1b}[2b"])
  assert_eq(rows, ["aaaaxxx", ""])
  assert_eq((x, y), (7, 0))
  assert_eq(replies, [])
}

///|
test "the terminal: DECALN fills with E" {
  let (rows, x, y, replies) = vt_of(4, 2, 0, ["\u{1b}#8"])
  assert_eq(rows, ["EEEE", "EEEE"])
  assert_eq((x, y), (0, 0))
  assert_eq(replies, [])
}

///|
test "the terminal: reverse index at the top scrolls down" {
  let (rows, x, y, replies) = vt_of(10, 3, 0, ["1\u{d}\u{a}2\u{d}\u{a}3\u{1b}[1;1H\u{1b}Mtop"])
  assert_eq(rows, ["top", "1", "2"])
  assert_eq((x, y), (3, 0))
  assert_eq(replies, [])
}

///|
test "the terminal: CAN cancels a sequence; DEL is ignored" {
  let (rows, x, y, replies) = vt_of(10, 2, 0, ["a\u{1b}[3\u{18}Kb\u{7f}c"])
  assert_eq(rows, ["aKbc", ""])
  assert_eq((x, y), (4, 0))
  assert_eq(replies, [])
}

///|
test "the terminal: a line longer than it is wide wraps, the row it goes on in marked" {
  let vt = Vt::new(10, 4, 0)
  vt.write("0123456789abc\r\nnext")
  assert_eq(Array::makei(4, i => vt.row(i)), ["0123456789", "abc", "next", ""])
  assert_eq(Array::makei(4, i => vt.row_wrapped(i)), [false, true, false, false])
  assert_eq(vt.row_wrapped(-1), false)
  assert_eq(vt.row_wrapped(4), false)
}
