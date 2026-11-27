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

///|
test "PR-B3c r2 P1-1: sensitive root tab Place(vault) never enters root shelf or kept_left while non-sensitive root tab hot-returns" {
  let (t, _src, _ws, _chats) = b3c_open_wide(1280.0, 800.0, 0)
  // Place sensitive Place("vault") at the stack root (depth == 1), then switch root tab via nav_root_kept to Place("usage"):
  // Place("vault") must dispose with 0 residue in both root shelf and kept_left.
  @ui.view_tree().unwrap().event(t.time(), fn() { app.nav.replace_above(0, [Place("vault")]) })
  t.run_for(@ui.move_most_ms)
  assert_eq(@signals.untracked(fn() { app.nav.depth() }), 1)
  let vault_serial = @signals.untracked(fn() { app.nav.top_stay().0 })
  t.tree_frames_from_now()
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfbase.nav_root_kept(Place("usage")) })
  t.run_for(@ui.move_most_ms)
  let vault_let_go = t.tree_frames().fold(init=0, fn(a, f) { a + f.let_go })
  assert_true(
    @signals.untracked(fn() { app.nav.shelved(Place("vault")) }) is None,
    msg="Place(vault) must never enter root shelf",
  )
  assert_false(
    @signals.untracked(fn() { app.nav.is_kept_left(vault_serial) }),
    msg="Place(vault) must never enter kept_left",
  )
  assert_true(vault_let_go > 0, msg="leaving Place(vault) must dispose its nodes immediately")
  // Normal non-sensitive root tab (Place("usage")) enters root shelf when leaving to Place("stations") and hot-returns with same serial.
  let usage_serial1 = @signals.untracked(fn() { app.nav.top_stay().0 })
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfbase.nav_root_kept(Place("stations")) })
  t.run_for(@ui.move_most_ms)
  assert_eq(
    @signals.untracked(fn() { app.nav.shelved(Place("usage")) }),
    Some(usage_serial1),
    msg="non-sensitive root tab Place(usage) must be parked on root shelf",
  )
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfbase.nav_root_kept(Place("usage")) })
  t.run_for(@ui.move_most_ms)
  let usage_serial2 = @signals.untracked(fn() { app.nav.top_stay().0 })
  assert_eq(usage_serial2, usage_serial1, msg="non-sensitive root tab Place(usage) must keep hot return via root shelf")
  // Re-opening Place("vault") must construct a brand-new entry (proving it was never shelved).
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfbase.nav_root_kept(Place("vault")) })
  t.run_for(@ui.move_most_ms)
  let vault_serial2 = @signals.untracked(fn() { app.nav.top_stay().0 })
  assert_true(vault_serial2 != vault_serial, msg="Place(vault) must not hot-return from root shelf")
  @ui.run_let_go()
}

///|
test "PR-B3c r2 P1-2: fail-closed on unconfirmed/revoked owner and same-workspace owner change refuses stale park" {
  let (t, src, ws, chats) = b3c_open_wide(1280.0, 800.0, 0)
  // Unconfirmed / pending / revoked owners must fail-closed (wide_page_left_key returns None).
  let prev_owner = @sfbase.workspace_owner_of(ws)
  let prev_principal = @sfbase.account_principal_sig.untracked()
  @sfbase.account_principal_sig.set("")
  @sfbase.workspace_owner_set(ws, "")
  assert_true(@sfbase.wide_page_left_key(src, Setting(About)) is None, msg="empty owner must fail-closed for setting")
  assert_true(@sfbase.wide_page_left_key(src, Chat(chats[0])) is None, msg="empty owner must fail-closed for chat")
  @sfbase.workspace_owner_set(ws, "\u{3}pending")
  assert_true(@sfbase.wide_page_left_key(src, Setting(About)) is None, msg="pending owner must fail-closed for setting")
  assert_true(@sfbase.wide_page_left_key(src, Chat(chats[0])) is None, msg="pending owner must fail-closed for chat")
  @sfbase.workspace_owner_set(ws, "\u{3}revoked")
  assert_true(@sfbase.wide_page_left_key(src, Setting(About)) is None, msg="revoked owner must fail-closed for setting")
  assert_true(@sfbase.wide_page_left_key(src, Chat(chats[0])) is None, msg="revoked owner must fail-closed for chat")
  // Same-workspace owner change (A): open About under owner-a, then switch owner to owner-b and leave in the same turn
  // before switch_by rebuilds -> creation-time identity guard MUST refuse parking the owner-a instance under owner-b.
  @sfbase.workspace_owner_set(ws, "owner-a")
  @ui.view_tree().unwrap().event(t.time(), fn() { nav_over_home([Setting(About)]) })
  t.run_for(@ui.move_most_ms)
  let about_serial = @signals.untracked(fn() { app.nav.top_stay().0 })
  @ui.view_tree().unwrap().event(t.time(), fn() {
    @sfbase.workspace_owner_set(ws, "owner-b")
    nav_over_home([Chat(chats[0])])
  })
  t.run_for(@ui.move_most_ms)
  assert_false(
    @signals.untracked(fn() { app.nav.is_kept_left(about_serial) }),
    msg="About instance created under owner-a must not park after workspace switches to owner-b",
  )
  // Same-workspace owner change (B): while About stays open and owner changes owner-b -> owner-c, switch_by tears down
  // the old owner-b subtree (let_go > 0) and rebuilds a fresh owner-c subtree.
  @ui.view_tree().unwrap().event(t.time(), fn() { nav_over_home([Setting(About)]) })
  t.run_for(@ui.move_most_ms)
  t.tree_frames_from_now()
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfbase.workspace_owner_set(ws, "owner-c") })
  t.run_for(@ui.move_most_ms)
  let rebuilt_let_go = t.tree_frames().fold(init=0, fn(a, f) { a + f.let_go })
  assert_true(rebuilt_let_go > 0, msg="switch_by must tear down old owner subtree when workspace owner changes")
  @sfbase.workspace_owner_set(ws, prev_owner)
  @sfbase.account_principal_sig.set(prev_principal)
  @ui.run_let_go()
}

///|
test "PR-B3c r2 P1-4: Medium Tape Side cover stops Shortcuts recording and suspends covered Page subtree" {
  let (t, _src, _ws, _chats) = b3c_open_wide(600.0, 900.0, 0)
  @ui.view_tree().unwrap().event(t.time(), fn() { nav_over_home([Setting(Shortcuts)]) })
  t.run_for(@ui.move_most_ms)
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfdesk.wide.tape_at.set(Page) })
  t.run_for(@ui.move_most_ms)
  // Click any shortcut keycap to enter recording mode (or verify recording stops on Side cover).
  if t.find("⌘K") is Some(_) {
    t.tap_text("⌘K")
    t.draw()
  } else {
    // Fallback: click the keyboard-search toggle button ("按键搜索") on Shortcuts page.
    let search_keys_label = @sf.t("web-main.shortcuts.searchKeys")
    assert_true(t.query(Button, label=search_keys_label) is Some(_), msg="Shortcuts searchKeys button must be present")
    t.click(Button, label=search_keys_label)
    t.draw()
  }
  assert_true(@settings.keys_recording.untracked() != "", msg="Shortcuts must enter recording mode on Medium Tape Page")
  // Switch Medium Tape to Side: Page is covered -> Shortcuts must stop recording synchronously!
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfdesk.wide.tape_at.set(Side) })
  t.run_for(@ui.move_most_ms)
  assert_eq(
    @settings.keys_recording.untracked(),
    "",
    msg="Medium Tape switching to Side must synchronously stop Shortcuts recording",
  )
  @ui.run_let_go()
}

///|
test "PR-B3c r2 P1-5 & P2-A: exact AuthScope invalidation (Vault keeps pool, Workspace evicts only target, Global clears all) and Wide->Narrow->Wide resize" {
  let (t, src, ws, chats) = b3c_open_wide(1280.0, 800.0, 0)
  // Park one chat and one setting in `ws`.
  @ui.view_tree().unwrap().event(t.time(), fn() { nav_over_home([Chat(chats[0])]) })
  t.run_for(@ui.move_most_ms)
  let chat_serial = @signals.untracked(fn() { app.nav.top_stay().0 })
  @ui.view_tree().unwrap().event(t.time(), fn() { nav_over_home([Setting(About)]) })
  t.run_for(@ui.move_most_ms)
  let about_serial = @signals.untracked(fn() { app.nav.top_stay().0 })
  @ui.view_tree().unwrap().event(t.time(), fn() { nav_over_home([Setting(Appearance)]) })
  t.run_for(@ui.move_most_ms)
  assert_true(@signals.untracked(fn() { app.nav.is_kept_left(chat_serial) }), msg="chat parked")
  assert_true(@signals.untracked(fn() { app.nav.is_kept_left(about_serial) }), msg="about parked")
  // 1. Vault topic invalidation must NOT clear parked chats or settings.
  @ui.view_tree().unwrap().event(t.time(), fn() {
    @sfbase.invalidate_auth_scope(src, fn(topic, _params) { topic == "vault" })
  })
  t.run_for(@ui.move_most_ms)
  assert_true(@signals.untracked(fn() { app.nav.is_kept_left(chat_serial) }), msg="Vault invalidation must preserve parked chats")
  assert_true(@signals.untracked(fn() { app.nav.is_kept_left(about_serial) }), msg="Vault invalidation must preserve parked settings")
  // 2. Workspace invalidation for another workspace must NOT evict `ws`'s parked entries.
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfbase.kept_left_invalidate_workspace("other-ws") })
  t.run_for(@ui.move_most_ms)
  assert_true(@signals.untracked(fn() { app.nav.is_kept_left(chat_serial) }), msg="other-ws invalidation preserves ws chat")
  assert_true(@signals.untracked(fn() { app.nav.is_kept_left(about_serial) }), msg="other-ws invalidation preserves ws setting")
  // 3. Workspace invalidation for `ws` evicts `ws`'s parked entries.
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfbase.kept_left_invalidate_workspace(ws) })
  t.run_for(@ui.move_most_ms)
  assert_false(@signals.untracked(fn() { app.nav.is_kept_left(chat_serial) }), msg="ws invalidation evicts ws chat")
  assert_false(@signals.untracked(fn() { app.nav.is_kept_left(about_serial) }), msg="ws invalidation evicts ws setting")
  // 4. Wide -> Narrow -> Wide resize on the SAME Nav/window evicts non-Chat settings and resets limits.
  @ui.view_tree().unwrap().event(t.time(), fn() { nav_over_home([Setting(About)]) })
  t.run_for(@ui.move_most_ms)
  let about_before_resize = @signals.untracked(fn() { app.nav.top_stay().0 })
  @ui.view_tree().unwrap().event(t.time(), fn() { nav_over_home([Chat(chats[1])]) })
  t.run_for(@ui.move_most_ms)
  assert_true(@signals.untracked(fn() { app.nav.is_kept_left(about_before_resize) }), msg="About parked in Wide before resize")
  t.resize(390.0, 844.0)
  t.run_for(@ui.move_most_ms)
  assert_false(
    @signals.untracked(fn() { app.nav.is_kept_left(about_before_resize) }),
    msg="resizing Wide -> Narrow on same window must immediately evict parked non-Chat settings",
  )
  // While in Narrow, leaving a setting must not park it.
  @ui.view_tree().unwrap().event(t.time(), fn() { nav_over_home([Setting(Appearance)]) })
  t.run_for(@ui.move_most_ms)
  let narrow_app_serial = @signals.untracked(fn() { app.nav.top_stay().0 })
  @ui.view_tree().unwrap().event(t.time(), fn() { nav_over_home([Chat(chats[1])]) })
  t.run_for(@ui.move_most_ms)
  assert_false(
    @signals.untracked(fn() { app.nav.is_kept_left(narrow_app_serial) }),
    msg="leaving Setting after Wide->Narrow resize must not park it",
  )
  // Resizing back Narrow -> Wide restores wide parking.
  t.resize(1280.0, 800.0)
  t.run_for(@ui.move_most_ms)
  @ui.view_tree().unwrap().event(t.time(), fn() { nav_over_home([Setting(About)]) })
  t.run_for(@ui.move_most_ms)
  let about_after_wide = @signals.untracked(fn() { app.nav.top_stay().0 })
  @ui.view_tree().unwrap().event(t.time(), fn() { nav_over_home([Chat(chats[1])]) })
  t.run_for(@ui.move_most_ms)
  assert_true(
    @signals.untracked(fn() { app.nav.is_kept_left(about_after_wide) }),
    msg="resizing back Narrow -> Wide restores allowlisted setting parking",
  )
  // 5. Global invalidation clears everything.
  @ui.view_tree().unwrap().event(t.time(), fn() { @sfbase.kept_left_invalidate_global() })
  t.run_for(@ui.move_most_ms)
  assert_false(@signals.untracked(fn() { app.nav.is_kept_left(about_after_wide) }), msg="Global invalidation clears all parked entries")
  @ui.run_let_go()
}
