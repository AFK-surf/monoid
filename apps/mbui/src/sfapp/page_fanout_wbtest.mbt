// A page tells what shows only what changed of what it shows (the user, 2026-11-15: 「明显错的，它目前快也要改」): on the
// workspace of real size (real_size_wbtest.mbt's), each change the core sends a page's own topic is given to it as a
// device takes it, and the window's tree's bindings the frame that takes it runs are counted. A station's page reads its
// station whole: a change of what none of it shows (an account's quota on it, its 归档's line, a check of its software)
// runs none of them, and one of its machine's figures only the dial it changes (sfpages station_node.mbt's
// station_narrowed, sf quota_node.mbt's dials_node). 账号's 概览 works out what it lists once of the accounts: a quota
// that leaves its pools as they were runs none, and accounts going down run only what they bring (its 需处理 rows, each
// made, and the pools' pills whose counts they change: profiles_overview.mbt).

///|
/// The bindings the frame that takes each change of way `way` runs on screen `mode` in window `win`, by cause.
fn page_fanout_of(mode : String, win : (String, Double, Double, Int, String), way : String) -> Map[String, Int] {
  let (_, rows) = real_size_screen(mode, win, fn(name) { name == way })
  let out : Map[String, Int] = Map([])
  for r in rows {
    out[r.0] = r.1.6
  }
  out
}

///|
test "a station's page: a change of the station none of it shows runs none of its bindings, its machine's figures only the dial they change" {
  for at in [("settings-station", real_size_windows[0]), ("settings-station", real_size_windows[1]), ("place-stations", real_size_windows[1])] {
    let (mode, win) = at
    let ran = page_fanout_of(mode, win, "station")
    // (every cause the core's rig has for a station: real-size-asked.ts)
    for cause in ["updating", "session", "quota", "off", "machine", "login", "decided", "archiving"] {
      let n = ran.get("station/" + cause).unwrap_or(0)
      assert_eq(n, 0, msg="\{win.0} \{mode} station/\{cause}: ran \{n} bindings, none of it shown")
    }
    // (the machine's first meter changes: its dial's own bindings, none of the others' or of the head)
    let host = ran.get("station/host").unwrap_or(0)
    assert_true(host > 0 && host <= 20, msg="\{win.0} \{mode} station/host: ran \{host} bindings, the one dial's at most 20")
  }
}

///|
test "账号's 概览: a quota leaving its pools as they were runs none of its bindings, accounts going down only what they bring" {
  let ran = page_fanout_of("place-profiles", real_size_windows[1], "profiles")
  let quota = ran.get("profiles/quota").unwrap_or(0)
  assert_eq(quota, 0, msg="profiles/quota: ran \{quota} bindings, nothing it shows changed")
  // (its 需处理 rows come, each made with its bindings, ~6 a row, and the pills whose counts change: none of the rest)
  let down = ran.get("profiles/down").unwrap_or(0)
  assert_true(down <= 160, msg="profiles/down: ran \{down} bindings, over the rows it brings (160)")
}
