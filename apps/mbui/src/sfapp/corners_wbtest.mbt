// The corner rule (mbui's Tester::corner_faults; mbui's ui/corners.mbt: what
// lies in a rounded container's corner as far from both its edges and concentric with it, the corners of both the
// ladder's) on every screen sffix opens, in the narrowest window of each layout and a wide desktop's, in both of the
// app's languages, over the Tester's own text (the faults a screen has its own, the same on every machine). Each keeps
// to the bar corners_everywhere_known says (the faults it still has): one more fails, and one less until the bar is
// lowered there. A screen not listed has none. scripts/corners.sh shows the same screens in a Mac's text, as
// pictures, what breaks the rule outlined. The same frame of each screen in squeeze_windows is held to its squeeze bar
// too (squeeze_wbtest.mbt), and in Chinese to the contrast rule in the light theme (contrast_wbtest.mbt): a screen is
// opened once for all. (The screens' own tests, screens_wbtest.mbt, hold the phone's screens in the Mac's text to
// corners_known.)

///|
/// The windows: the narrowest of each layout (squeeze_windows: a phone's, a finger's Medium, a desktop's Medium, a
/// tablet's Large) and a wide desktop's (Large, its dialogs and pages at their widest); the desktop's on a Mac (its
/// window's corners 16: what lies in them follows them) and on Windows 11 (8: too square to follow, so standing as
/// alone, as in a square window) (test_window_corner).
let corner_windows : Array[(String, Double, Double, Int, String)] = [
  ("phone", 360.0, 740.0, 2, ""),
  ("touch", 600.0, 900.0, 2, "medium"),
  ("desk", 600.0, 760.0, 0, ""),
  ("desk-win", 600.0, 760.0, 3, ""),
  ("tablet", 840.0, 900.0, 2, "expanded"),
  ("wide", 1280.0, 800.0, 0, ""),
  ("wide-win", 1280.0, 800.0, 3, ""),
]

///|
/// The screens: every mode sffix opens (fixture.mbt open_fixture_mode, settings/fixture.mbt fixture_page). The other
/// failure reasons on the player's page are checked against player-failed separately below.
let corner_modes : Array[String] = fixture_corner_modes()

///|
/// `lang`'s screens in the windows selected by `start` and `stride`, each against its corner and squeeze bars, and
/// (`press_room`, Chinese) a press's room and the light theme's contrast too, on the same screen opened once. (Apart, a
/// sweep each, Chinese's screens were opened twice: of a sweep's 1939 screens, opening them was some seven tenths of
/// its time, the checks the rest, none of them long (27 ms each at the median, 0.3 s the longest), 2026-11-05.) (In two
/// halves of the windows, a run each: one run a language was 150-165 s of one core on main and 253-277 s on a slow runner,
/// app corners 289 and 292 s of its 5 minutes on feat/history-turn-time 43714223337 and mbui-player-node 43717281884,
/// 2026-11-15, two of the runner's four cores idle.)
fn corners_check(lang : String, start : Int, stride? : Int = 2, press_room~ : Bool = false) -> Unit raise {
  let wrong : Array[String] = []
  let gaps : Array[String] = []
  let moves : Array[String] = []
  let rooms : Array[String] = []
  let heights : Array[String] = []
  let first_lines : Array[String] = []
  let line_starts : Array[String] = []
  for k, win in corner_windows {
    if k % stride != start {
      continue
    }
    let squeezed = squeeze_windows.contains(win.0)
    for mode in corner_modes {
      let at = "\{win.0}-\{lang} \{mode}"
      let t = screen_in(mode, win, lang)
      if press_room {
        // (a press's room, at rest and with what shows only under the hand shown: rooms_known_wbtest.mbt; and the
        // contrast's, in the light theme, once: contrast_wbtest.mbt)
        for f in t.room_faults() {
          rooms.push("\{at}: \{f}")
        }
        for f in t.hover_only_faults() {
          rooms.push("\{at}: \{f}")
        }
        match contrast_wrong("\{win.0}-light \{mode}", t.contrast_faults()) {
          Some(w) => wrong.push(w)
          None => ()
        }
      }
      let faults = t.corner_faults()
      for f in t.gap_faults() {
        gaps.push("\{at}: \{f}")
      }
      // (the squeeze's on the screen at rest, before what shows only under the hand is shown)
      let squeeze = if squeezed { squeeze_wrong(at, t.squeeze_faults()) } else { None }
      // and what it shows only under the hand (Ctx::lit_shown, hand_shown: a row's 归档), all of it at once, each fault
      // once
      for f in t.lit_all_faults() {
        if !faults.contains(f) {
          faults.push(f)
        }
      }
      // and with every thing the hand lights lit at once, and all it shows shown: none another size, none moved, no
      // words otherwise (the hand changes a thing's ground and ink alone: Tester::hand_moves)
      for f in t.hand_moves() {
        moves.push("\{at}: \{f}")
      }
      let known = corners_everywhere_known.get(at).unwrap_or(0)
      if faults.length() != known {
        wrong.push(
          "\{at}: \{faults.length()} corners break the rule, \{known} known (" +
          (if faults.length() < known {
            "fewer: its bar comes down in corners_known_wbtest.mbt"
          } else {
            "more than its bar: stand it where it is concentric, or round its container by the ladder's"
          }) +
          ")\n  " +
          faults.join("\n  "),
        )
      }
      if squeeze is Some(w) {
        wrong.push(w)
      }
      // (what is pressed side by side another height than the rest of its row, mbui's Tester::height_faults, against
      // its bar)
      let tall = t.height_faults()
      let bar = corners_heights_known.get(at).unwrap_or(0)
      if tall.length() != bar {
        heights.push(
          "\{at}: \{tall.length()} pressed things another height than their row, \{bar} known (" +
          (if tall.length() < bar {
            "fewer: its bar comes down in corners_known_wbtest.mbt"
          } else {
            "more than its bar: what is pressed side by side is one height, a button's (@sf.button_height)"
          }) +
          ")\n  " +
          tall.join("\n  "),
        )
      }
      // (a mark beside a block of several lines off its first line, mbui's Tester::first_line_faults, against its bar)
      let off_line = t.first_line_faults()
      let line_bar = corners_first_line_known.get(at).unwrap_or(0)
      if off_line.length() != line_bar {
        first_lines.push(
          "\{at}: \{off_line.length()} marks off the first line beside them, \{line_bar} known (" +
          (if off_line.length() < line_bar {
            "fewer: its bar comes down in corners_known_wbtest.mbt"
          } else {
            "more than its bar: beside several lines an icon, a mark or a chevron sits on the first, never centred on them"
          }) +
          ")\n  " +
          off_line.join("\n  "),
        )
      }
      // (a line under a marked line starting between its mark and its words, mbui's Tester::line_start_faults, against
      // its bar)
      let between = t.line_start_faults()
      let start_bar = corners_line_start_known.get(at).unwrap_or(0)
      if between.length() != start_bar {
        line_starts.push(
          "\{at}: \{between.length()} lines starting between the mark and the words over them, \{start_bar} known (" +
          (if between.length() < start_bar {
            "fewer: its bar comes down in corners_known_wbtest.mbt"
          } else {
            "more than its bar: a line under a mark and its words starts where the mark does or where the words do"
          }) +
          ")\n  " +
          between.join("\n  "),
        )
      }
      // (words a box with its height said does not hold, mbui's Tester::fixed_outgrown, against its bar)
      match outgrown_wrong(at, t.fixed_outgrown(), corners_outgrown_known, "corners_known_wbtest.mbt") {
        Some(w) => wrong.push(w)
        None => ()
      }
    }
  }
  let windows = "\{start}/\{stride}"
  if press_room {
    match rooms_wrong(windows, rooms) {
      Some(w) => wrong.push(w)
      None => ()
    }
  }
  wrong.append(heights)
  wrong.append(first_lines)
  wrong.append(line_starts)
  match gaps_wrong("\{lang} \{windows}", gaps) {
    Some(w) => wrong.push(w)
    None => ()
  }
  if moves.length() > 0 {
    wrong.push(
      "\{moves.length()} things the hand changes the size or place of, or the words' look (its hot style another than " +
      "its rest one's ink: say it as the rest one's .then(@ui.text_style(color=…)); what shows under it kept to the " +
      "room of what it is in):\n  " +
      moves.join("\n  "),
    )
  }
  if wrong.length() > 0 {
    fail(wrong.join("\n"))
  }
}

///|
test "corners and squeeze, a press's room and the light theme's contrast: every screen in the windows 1 and 5, in Chinese" {
  corners_check("zh", 0, stride=4, press_room=true)
}

///|
test "corners and squeeze, a press's room and the light theme's contrast: every screen in the windows 3 and 7, in Chinese" {
  corners_check("zh", 2, stride=4, press_room=true)
}

///|
test "corners and squeeze, a press's room and the light theme's contrast: every screen in the windows 2, 4 and 6, in Chinese" {
  corners_check("zh", 1, press_room=true)
}

///|
test "corners and squeeze: every screen in the windows 1, 3, 5 and 7 keeps the corner rule and fits, in English" {
  corners_check("en", 0)
}

///|
test "corners and squeeze: every screen in the windows 2, 4 and 6 keeps the corner rule and fits, in English" {
  corners_check("en", 1)
}

///|
/// A fault's node numbers differ when a player card has no button. The boxes and what they hold must still match.
fn gap_without_nodes(s : String) -> String {
  let mut rest = s
  let mut out = ""
  while rest.find(", node ") is Some(i) {
    let after = rest.exact_view(start=i + 7)
    guard after.find(")") is Some(j) else { return out + rest }
    out = out + rest.exact_view(end=i).to_owned() + ")"
    rest = after.exact_view(start=j + 1).to_owned()
  }
  out + rest
}

///|
test "each player failure reason fits without adding a spacing or corner fault" {
  for win in corner_windows {
    for lang in ["zh", "en"] {
      // The player's existing header has a known gap fault on a small screen. These are states of that same page,
      // so compare their actual faults with it rather than counting that same fault once per message.
      // (and its corners with it: the player-failed screen's own, known to corners_everywhere_known, the rail's on the
      // tape)
      let failed = screen_in("player-failed", win, lang)
      let baseline = failed.gap_faults().map(gap_without_nodes)
      let corners = failed.corner_faults().map(gap_without_nodes)
      let lit = failed.lit_all_faults().map(gap_without_nodes)
      for mode in ["player-damaged", "player-unplayable", "player-unsupported"] {
        let t = screen_in(mode, win, lang)
        let at = "\{win.0}-\{lang} \{mode}"
        assert_eq(t.gap_faults().map(gap_without_nodes), baseline, msg=at)
        assert_eq(t.corner_faults().map(gap_without_nodes), corners, msg=at)
        assert_eq(t.lit_all_faults().map(gap_without_nodes), lit, msg=at)
        if squeeze_windows.contains(win.0) {
          assert_true(t.squeeze_faults().is_empty(), msg=at)
        }
      }
    }
  }
}

///|
/// What is wrong of `faults`, the words a box with its height said does not hold on screen `at` (mbui's
/// Tester::fixed_outgrown), against its bar in `known` (kept in `file`): none where they are as many as it says; else
/// how many, the bar, and each.
fn outgrown_wrong(at : String, faults : Array[String], known : Map[String, Int], file : String) -> String? {
  let bar = known.get(at).unwrap_or(0)
  if faults.length() == bar {
    return None
  }
  Some(
    "\{at}: \{faults.length()} words a box with its height said does not hold, \{bar} known (" +
    (if faults.length() < bar {
      "fewer: its bar comes down in \{file}"
    } else {
      "more than its bar: the box grown by its words (a least, min_h, or its height worked out of their line at " +
      "the system's size of words)"
    }) +
    ")\n  " +
    faults.join("\n  "),
  )
}
