// Integration tests for PR-B3c:
// - Wide-layout `keeps_left` explicit allowlist & sensitive-page zero-residue gate
// - Per-kind quotas (`chat <= 3`, `setting <= 3`, total `<= 6`) without mutual eviction
// - Auth boundary / logout / workspace switch clearing `kept_left`
// - Narrow-layout `keeps_left` unchanged (chat-only)

///|
fn b3c_open_wide(w : Double, h : Double, platform : Int) -> (@ui.Tester, Source, String, Array[ChatRef]) {
  let src_ref : Ref[Source?] = Ref(None)
  let made = fn() {
    match src_ref.val {
      Some(s) => s
      None => {
        reset()
        let s = @sffixture.fixture("home")
        open_fixture_over("home", s)
        src_ref.val = Some(s)
        s
      }
    }
  }
  let t = @ui.Tester::new(
    fn(x) { view(x, made()) },
    tree=fn(root) { app_tree(made())(root) },
    w~,
    h~,
    platform~,
    corners_held=false,
    words_over_held=false,
    env=[("MBUI_LOCALE", "zh")],
  )
  t.motion_unjudged(true)
  t.run_for(@ui.move_most_ms)
  let src = made()
  let ws = @signals.untracked(fn() { workspace_in_view(src).0.unwrap().id })
  let chats : Array[ChatRef] = []
  match @signals.untracked(fn() { chats_of(src, ws, "all").0 }) {
    Some(list) =>
      for day in list.days {
        for item in day.items {
          if chats.length() < 4 {
            chats.push({
              station: item.station,
              session: item.session,
              title: item.title,
              station_name: item.station_name,
            })
          }
        }
      }
    None => ()
  }
  (t, src, ws, chats)
}

///|
test "PR-B3c sensitive settings zero-residue: leaving sensitive/non-allowlisted routes never parks them" {
  let (t, _src, _ws, chats) = b3c_open_wide(1280.0, 800.0, 0)
  let tree = @ui.view_tree().unwrap()
  let sensitive_pages : Array[(String, Page)] = [
    ("Security", Setting(Security)),
    ("SecurityOpen", Setting(SecurityOpen)),
    ("Vault", Setting(Vault)),
    ("VaultItems", Setting(VaultItems)),
    ("VaultItem", Setting(VaultItem("v1", "i1"))),
    ("AdbShare", Setting(AdbShare("ws1/st1"))),
    ("Permissions", Setting(Permissions)),
    ("ProfileAccount", Setting(ProfileAccount("k1"))),
    ("NewProfile", Setting(NewProfile("ws1/st1"))),
    ("McpServers", Setting(McpServers)),
    ("Workspace", Setting(Workspace)),
    ("Connect", Setting(Connect("ws1/st1", "c1"))),
    ("Memory", Setting(Memory("ws1/st1"))),
    ("MemoryDoc", Setting(MemoryDoc("ws1/st1", "", 0))),
    ("AutoPolicy", Setting(AutoPolicy("ws1/st1"))),
    ("LocalStation", Setting(LocalStation)),
    ("Files", Files),
  ]
  for pair in sensitive_pages {
    let (label, page) = pair
    @ui.view_tree().unwrap().event(t.time(), fn() { nav_over_home([page]) })
    t.run_for(@ui.move_most_ms)
    let serial = @signals.untracked(fn() { app.nav.top_stay().0 })
    t.tree_frames_from_now()
    @ui.view_tree().unwrap().event(t.time(), fn() { nav_over_home([Chat(chats[0])]) })
    t.run_for(@ui.move_most_ms)
    let let_go = t.tree_frames().fold(init=0, fn(a, f) { a + f.let_go })
    assert_false(
      @signals.untracked(fn() { app.nav.is_kept_left(serial) }),
      msg="sensitive/non-allowlisted route \{label} must NEVER be parked in kept_left",
    )
    assert_true(let_go > 0, msg="leaving \{label} must dispose its nodes (let_go > 0)")
    assert_eq(tree.due_count(), t.subtree_timeline_count(tree.root()), msg="0 parked timers after leaving \{label}")
  }
  // Land on a calm allowlisted page and verify 0 parked timers and 0 unreclaimed retired parked entries.
  @ui.view_tree().unwrap().event(t.time(), fn() { nav_over_home([Setting(Appearance)]) })
  t.run_for(kept_glide_over_ms)
  assert_eq(tree.due_count(), t.subtree_timeline_count(tree.root()), msg="0 parked timers after sensitive sweep")
  assert_eq(tree.parked_retired_count(), 0, msg="0 unreclaimed retired parked entries after sensitive sweep")
  @ui.run_let_go()
}

///|
test "PR-B3c quotas and boundaries: chat<=3 and setting<=3 do not evict each other, authGen bump clears pool, narrow stays chat-only" {
  let (t, src, _ws, chats) = b3c_open_wide(1280.0, 800.0, 0)
  assert_true(chats.length() >= 4, msg="fixture must provide at least 4 chats")
  // Open and park 3 chats (C0, C1, C2).
  let chat_serials : Array[Int] = []
  for i in 0..<3 {
    @ui.view_tree().unwrap().event(t.time(), fn() { nav_over_home([Chat(chats[i])]) })
    t.run_for(@ui.move_most_ms)
    chat_serials.push(@signals.untracked(fn() { app.nav.top_stay().0 }))
  }
  // Open and park 3 allowlisted settings (Changelog, Appearance, About); switching away from C2 parks C2 too.
  let setting_pages : Array[Page] = [
    Setting(Changelog),
    Setting(Appearance),
    Setting(About),
    Setting(Fonts),
  ]
  let setting_serials : Array[Int] = []
  for i in 0..<3 {
    @ui.view_tree().unwrap().event(t.time(), fn() { nav_over_home([setting_pages[i]]) })
    t.run_for(@ui.move_most_ms)
    setting_serials.push(@signals.untracked(fn() { app.nav.top_stay().0 }))
  }
  // Switch to Fonts (4th setting): parks About -> now 3 chats (C0,C1,C2) + 3 settings (Changelog,Appearance,About) = 6 parked!
  @ui.view_tree().unwrap().event(t.time(), fn() { nav_over_home([setting_pages[3]]) })
  t.run_for(@ui.move_most_ms)
  let fonts_serial = @signals.untracked(fn() { app.nav.top_stay().0 })
  for i in 0..<3 {
    assert_true(@signals.untracked(fn() { app.nav.is_kept_left(chat_serials[i]) }), msg="chat \{i} kept alongside 3 settings")
    assert_true(@signals.untracked(fn() { app.nav.is_kept_left(setting_serials[i]) }), msg="setting \{i} kept alongside 3 chats")
  }
  // Leave Fonts to C3 (4th chat): parking Fonts (4th setting) evicts oldest setting (Changelog), keeping all 3 chats intact!
  @ui.view_tree().unwrap().event(t.time(), fn() { nav_over_home([Chat(chats[3])]) })
  t.run_for(@ui.move_most_ms)
  assert_false(@signals.untracked(fn() { app.nav.is_kept_left(setting_serials[0]) }), msg="oldest setting evicted at setting cap 3")
  assert_true(@signals.untracked(fn() { app.nav.is_kept_left(setting_serials[1]) }), msg="2nd setting kept")
  assert_true(@signals.untracked(fn() { app.nav.is_kept_left(setting_serials[2]) }), msg="3rd setting kept")
  assert_true(@signals.untracked(fn() { app.nav.is_kept_left(fonts_serial) }), msg="4th setting parked")
  for i in 0..<3 {
    assert_true(@signals.untracked(fn() { app.nav.is_kept_left(chat_serials[i]) }), msg="chat \{i} unaffected by setting eviction")
  }
  // Key changes across authGen bump and bump empties parked pool completely.
  let key_before = @sfbase.wide_page_left_key(src, Setting(About))
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfbase.kept_left_auth_gen_bump() })
  t.run_for(@ui.move_most_ms)
  let key_after = @sfbase.wide_page_left_key(src, Setting(About))
  assert_true(key_before != key_after, msg="wide setting key must change across authGen bump")
  assert_false(@signals.untracked(fn() { app.nav.is_kept_left(chat_serials[0]) }), msg="authGen bump empties chats")
  assert_false(@signals.untracked(fn() { app.nav.is_kept_left(fonts_serial) }), msg="authGen bump empties settings")
  @ui.run_let_go()
  // Narrow screen (Small 390x844, platform=2) keeps chat_page_left_key unchanged: settings never park.
  let (tn, _src_n, _ws_n, chats_n) = b3c_open_wide(390.0, 844.0, 2)
  @ui.view_tree().unwrap().event(tn.time(), fn() { nav_over_home([Setting(About)]) })
  tn.run_for(@ui.move_most_ms)
  let narrow_about_serial = @signals.untracked(fn() { app.nav.top_stay().0 })
  @ui.view_tree().unwrap().event(tn.time(), fn() { nav_over_home([Chat(chats_n[0])]) })
  tn.run_for(@ui.move_most_ms)
  assert_false(
    @signals.untracked(fn() { app.nav.is_kept_left(narrow_about_serial) }),
    msg="narrow shell must keep chat_page_left_key unchanged (settings never park)",
  )
  @ui.run_let_go()
}
