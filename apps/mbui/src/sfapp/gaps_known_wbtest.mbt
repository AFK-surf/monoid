// The spacing rules (mbui's Tester::gap_faults, gaps.mbt: 1 what lights up apart, 2 neighbours of a kind equally
// apart, 3 blocks never at 0 or over each other, 4 what a box with a ground holds in from its edges and as far from
// both sides, 5 a column's blocks on one edge, 6 neighbours a step of the spacing scale apart, 7 a row that lights up
// across what holds it the theme's lit_reach in from its edges, 8 the other words on a list card aligned with its rows)
// on the same screens and windows
// the corner rule is held on (corners_wbtest.mbt, each screen opened once for both). Each rule's faults, all screens
// in a language, in each half of the windows (corners_check), keep to the bar here: one more fails, and one less until the bar comes down to it.
// Every fault is printed (`at: rule n: …`) when a count is off its bar.

///|
/// The faults each rule still has, in each language: they only fall (rule 4's two more with files-add-folder swept, its
/// files' bar a phone's and a tablet's as the drive's other screens have it; seven fewer with a chat shared as a
/// picture under the bar a file opened has, no more a pill of its own holding a button; eight fewer with a settings
/// page opened on the tape the one in use, whole in the window; one with a memory page's bar the frame's; rule 5's last with an agent's
/// picture in its line on the messages' pictures' edge; rule 4's four more with 共享调试's lent states swept, the
/// settings' bar they share with settings-adb; eight fewer with every row one least height, 36 with keyboard and mouse,
/// a sidebar's rows no more 32 high, and words at a capsule's end held by their box, not as a mark by their middle; one
/// more with newchat-lend swept, a phone's new chat's bar newchat has too; one more with settings-profiles-monthly swept,
/// a phone's profiles' bar settings-profiles has too; one more with player-failed swept, the player's bar its
/// other screens have; eight fewer in each with a diff's line as far in at its end as its mark at its start, and the
/// way to allow banners as far in from both its ends, Medium's tape's panels measured where they stand; 56 fewer with
/// the navigation bar's ends equally inset, including the newly swept 共享调试 grants pages; six fewer with the files'
/// page starting in its list, the columns' rows no longer at the page's edge on those screens; rule 5's one more in each
/// with a request for the phone waiting swept, chat-phone-lacks on the tablet: its card and a login's above it short of
/// the others' edge, as a request card stood on main, unswept; 2026-11-14, the rules measuring the window's tree's nodes
/// and the old views it holds: rule 4's 89 more, mostly a wide chat's head (its title 12 in, its faces 6 from its end),
/// a command's box (12, 8) and the player's bar; rule 8's two, an outline's 8 found 6 in where its rows' words are 15;
/// rule 9's four, a message's words right on its file's card, none since #6285; 2026-11-15, the rules seeing the
/// tree's words and drawings, not their boxes alone (the words laid out as drawn, Ctx::with_tree_nodes `facts`), and
/// rule 4 leaving what is seen as far in from both sides: rule 4 13 and 15 fewer (the player's bar, a command's box
/// now 8 all round), rule 8 eight more, newly seen: a small panel's title 16 in over rows whose marks are 22 in
/// (选择运行的 station, 标签页; its group labels' line, so moved with them or not at all)); the same day, each language's
/// windows in two halves, a run each (corners_check): rule 4's 84 Chinese 4 and 80, its 86 English 5 and 81, the two
/// wide windows' chats' heads in the second half); 2026-11-16, rule 4's one fewer in each first half: a table's head
/// (its stage of nodes) a row scrolled across with its rows, its ground and its cells as far in as theirs; 2026-11-17,
/// rule 4's one fewer in each half: 文件 and a station's drive made once as nodes, its folder 12 in from its frame's sides; chat-remote swept
/// (a chat whose 远程's menu its bar opens): rule 4's one more in each, its wide chat's head as every wide chat's (its
/// title 12 in, its faces 6 from its end); 2026-11-18, chat-info-bare swept (the chat's sheet with nothing in its thread,
/// its station's screen an agent drives): rule 4's one more in each, its wide chat's head as every wide chat's;
/// 2026-11-19, the chat's page made as nodes on the test channel: rule 5's last, gone with the old chat's page, and
/// rule 8's one fewer in each half of the first windows and the wide ones (a small panel's rows' icons taken as
/// where their words stand, the panel's own rows lit at rest not counted among its words). The
/// Chinese odd windows run in two groups to fit the CI time limit.
/// Their counts add up to the earlier counts for all odd windows. 2026-11-19, rule 8 counting the tree's marks among
/// the rows' words (Ctx::tree_draws) and taking a row with a ground at rest as wide and as far in as the rows (the one
/// chosen, one opened in place) for one of them, its words held to their line: one fewer in zh 0/4, zh 1/2 and both
/// English halves. 2026-11-21, rule 4 taking a bar's end in the window's round corner as that corner has it (its last
/// button concentric with it, or a capsule past its curve) and asking only where what is seen spans the box (not a
/// loading chat's half row): the wide chats' heads, 80 fewer in each 1/2. The same day, small-panel titles, labels,
/// notes and icon columns aligned to text_in (S4=16, panel_row_icon AStart), find_bar_node using symmetric capsule px +
/// field_in, and screen-keys tile_box padded S1: all 45 entries now 0.
let gaps_known : Map[String, Int] = {
  "zh 0/4 rule 1": 0,
  "zh 0/4 rule 2": 0,
  "zh 0/4 rule 3": 0,
  "zh 0/4 rule 4": 0,
  "zh 0/4 rule 5": 0,
  "zh 0/4 rule 6": 0,
  "zh 0/4 rule 7": 0,
  "zh 0/4 rule 8": 0,
  "zh 0/4 rule 9": 0,
  "zh 2/4 rule 1": 0,
  "zh 2/4 rule 2": 0,
  "zh 2/4 rule 3": 0,
  "zh 2/4 rule 4": 0,
  "zh 2/4 rule 5": 0,
  "zh 2/4 rule 6": 0,
  "zh 2/4 rule 7": 0,
  "zh 2/4 rule 8": 0,
  "zh 2/4 rule 9": 0,
  "zh 1/2 rule 1": 0,
  "zh 1/2 rule 2": 0,
  "zh 1/2 rule 3": 0,
  "zh 1/2 rule 4": 0,
  "zh 1/2 rule 5": 0,
  "zh 1/2 rule 6": 0,
  "zh 1/2 rule 7": 0,
  "zh 1/2 rule 8": 0,
  "zh 1/2 rule 9": 0,
  "en 0/2 rule 1": 0,
  "en 0/2 rule 2": 0,
  "en 0/2 rule 3": 0,
  "en 0/2 rule 4": 0,
  "en 0/2 rule 5": 0,
  "en 0/2 rule 6": 0,
  "en 0/2 rule 7": 0,
  "en 0/2 rule 8": 0,
  "en 0/2 rule 9": 0,
  "en 1/2 rule 1": 0,
  "en 1/2 rule 2": 0,
  "en 1/2 rule 3": 0,
  "en 1/2 rule 4": 0,
  "en 1/2 rule 5": 0,
  "en 1/2 rule 6": 0,
  "en 1/2 rule 7": 0,
  "en 1/2 rule 8": 0,
  "en 1/2 rule 9": 0,
}

///|
test "the spacing sweep counts row and heading alignment faults" {
  let faults : Array[String] = []
  for rule in ["rule 1", "rule 2", "rule 3", "rule 4", "rule 5", "rule 6", "rule 7", "rule 8", "rule 9"] {
    for _ in 0..<gaps_known.get("zh 1/2 \{rule}").unwrap_or(0) {
      faults.push("example: \{rule}: known")
    }
  }
  assert_true(gaps_wrong("zh 1/2", faults) is None)
  faults.push("example: rule 8: a heading is not aligned with its rows")
  assert_true(gaps_wrong("zh 1/2", faults) is Some(_))
  faults.pop() |> ignore
  faults.push("example: rule 10: a new kind of spacing fault")
  assert_true(gaps_wrong("zh 1/2", faults) is Some(_))
}

///|
/// What is off its bar in `lang`'s faults `gaps` (each `at: rule n: …`), None where each rule keeps to it.
fn gaps_wrong(lang : String, gaps : Array[String]) -> String? {
  let counts : Map[String, Int] = Map([])
  let off : Array[String] = []
  // Take the rule from each fault, so adding a rule to gap_faults cannot silently leave it out of this sweep.
  for f in gaps {
    match f.find(": rule ") {
      Some(start) => {
        let rest = f.exact_view(start=start + 2).to_owned()
        match rest.find(": ") {
          Some(end) => {
            let key = "\{lang} " + rest.exact_view(end=end).to_owned()
            counts[key] = counts.get(key).unwrap_or(0) + 1
          }
          None => off.push("unrecognized spacing fault: \{f}")
        }
      }
      None => off.push("unrecognized spacing fault: \{f}")
    }
  }
  let keys : Array[String] = []
  for key, _ in gaps_known {
    if key.has_prefix("\{lang} rule ") {
      keys.push(key)
    }
  }
  for key, _ in counts {
    if !keys.contains(key) {
      keys.push(key)
    }
  }
  keys.sort()
  for key in keys {
    let have = counts.get(key).unwrap_or(0)
    let known = gaps_known.get(key).unwrap_or(0)
    if have != known {
      off.push(
        "\{key}: \{have} faults, \{known} known (" +
        (if have < known {
          "fewer: its bar comes down in gaps_known_wbtest.mbt"
        } else {
          "more than its bar: stand them apart (mbui's gaps.mbt says how)"
        }) +
        ")",
      )
    }
  }
  if off.is_empty() {
    return None
  }
  println(gaps.join("\n"))
  Some("the spacing rules off their bars:\n  " + off.join("\n  "))
}
