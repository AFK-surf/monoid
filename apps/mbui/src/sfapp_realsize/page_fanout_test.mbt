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
  // (its 需处理 rows come, each made with its bindings, ~6 a row, and the pills whose counts change: none of the rest;
  // 156 of them the page's own. Raised 2026-11-17 from 160, the migration's coordinator's: the sidebar beside it made
  // as nodes (sfdesk places_side_node.mbt), the rows of the accounts gone down that it shows tell their state, their
  // red line, their allowance and 概览's 需处理 there too, 30 bindings, counted in the tree's now; a quota leaving its
  // pools as they were still runs none)
  let down = ran.get("profiles/down").unwrap_or(0)
  assert_true(down <= 190, msg="profiles/down: ran \{down} bindings, over the rows it brings (190)")
}

///|
test "全部密钥: a secret used runs the bindings of its own row alone, a vault's own row changed none, a secret added what it brings" {
  for at in [("settings-vault-items", real_size_windows[0]), ("settings-vault-items", real_size_windows[1]), ("settings-vault-editor", real_size_windows[1])] {
    let (mode, win) = at
    let items = page_fanout_of(mode, win, "vaultItems vault=v_01JAAAAAAAAAAAAAAAAAAAAAAA")
    // (its last use changed: that row's line, none of the other secrets' rows)
    let used = items.get("vaultItems vault=v_01JAAAAAAAAAAAAAAAAAAAAAAA/used").unwrap_or(0)
    assert_true(used <= 6, msg="\{win.0} \{mode} vaultItems/used: ran \{used} bindings, over its own row's (6)")
    // (a secret more: its row made, the pieces of the card it moves, the list's keys)
    let item = items.get("vaultItems vault=v_01JAAAAAAAAAAAAAAAAAAAAAAA/item").unwrap_or(0)
    assert_true(item <= 8, msg="\{win.0} \{mode} vaultItems/item: ran \{item} bindings, over what a row more brings (8)")
    // (the vault's own row in the library (how many it holds): no secret's row shows it)
    let vault = page_fanout_of(mode, win, "vaults").get("vaults/item").unwrap_or(0)
    assert_eq(vault, 0, msg="\{win.0} \{mode} vaults/item: ran \{vault} bindings, nothing it shows changed")
  }
}

///|
test "连接: a session more on one connect runs only that row's inline session count and a11y status bindings" {
  for win in real_size_windows {
    let ran = page_fanout_of("settings-connects", win, "connects").get("connects/session").unwrap_or(0)
    assert_eq(ran, 2, msg="\{win.0} settings-connects connects/session: ran \{ran} bindings, expected 2 (inline session count + a11y status label)")
  }
}

///|
test "更新日志: a build more out runs what it brings (its change's row, the days' cards it moves), not the tabs or the head" {
  for win in real_size_windows {
    let ran = page_fanout_of("settings-changelog", win, "changelog").get("changelog/release").unwrap_or(0)
    assert_true(ran <= 50, msg="\{win.0} settings-changelog changelog/release: ran \{ran} bindings, over what it brings (50)")
  }
}
