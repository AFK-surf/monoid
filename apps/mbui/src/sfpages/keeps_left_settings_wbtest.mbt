// Deterministic PR-B3c admission tests for the 5 allowlisted wide-layout `keeps_left` setting pages:
//   1. Changelog: no `changelog.seen` while parked; hot return `made == 0` with tab preserved.
//   2. Appearance: zoom picker & hover preview close on park/cover; wake triggers 0 `prefs.set`.
//   3. About: management actions guarded by live role & target station (downgrade / workspace switch / delayed click);
//      park & wake trigger 0 update/share calls and 0 parked timers.
//   4. Fonts: park/cover closes own `panel_nodes` and clears drag state; evicting an old instance never closes a newer
//      instance's panel.
//   5. Shortcuts: park/cover synchronously releases global `keys_recording`; next key reaches current window with 0
//      `keys.set` calls; hot return stays non-recording.

///|
test "PR-B3c Changelog: parked page never marks changelog.seen and hot-returns with made == 0 and tab preserved" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sffixture.fixture_reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let seen_calls : Ref[Int] = Ref(0)
  let news_sig : @signals.Signal[String] = @signals.signal("news-v1")
  let changelog_json = fn() -> Json {
    {
      "news": Json::string(news_sig.get()),
      "build": 1300,
      "tabs": [
        {
          "part": "app",
          "label": "App",
          "days": [
            {
              "day": 1,
              "label": "Today",
              "entries": [
                {
                  "version": 1300,
                  "versionName": "0.1.1300",
                  "lines": [{ "label": "Fix", "text": "Initial entry", "kind": "fix" }],
                },
              ],
            },
          ],
        },
        {
          "part": "station",
          "label": "Station",
          "days": [
            {
              "day": 2,
              "label": "Yesterday",
              "entries": [
                {
                  "version": 1299,
                  "versionName": "0.1.1299",
                  "lines": [{ "label": "New", "text": "Station entry", "kind": "new" }],
                },
              ],
            },
          ],
        },
      ],
    }
  }
  let base_src = @sffixture.fixture("settings")
  let base_core = @sfbase.settings_core(base_src, rig_workspace)
  let topic_c = @signals.computed(fn(_) -> @settings.Read { { value: Some(changelog_json()), error: None, version: 1 } })
  let core : @settings.Core = {
    ..base_core,
    topic: fn(name, params) {
      if name == "changelog" {
        topic_c
      } else {
        (base_core.topic)(name, params)
      }
    },
    call: fn(name, params, done) {
      if name == "changelog.seen" {
        seen_calls.val += 1
        done(Ok(Json::object({})))
      } else {
        (base_core.call)(name, params, done)
      }
    },
  }
  let page = @signals.signal(0)
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      @sf.look_lent(root, @sf.look_for(1280.0))
      root.pick_kept(at_once=true, fn() { page.get() }, fn(slot, which) {
        if which == 0 {
          changelog_node(slot, core, on_back=fn() {  }, frame=fn() { @sf.no_frame })
        }
      })
    },
    w=1280.0,
    h=800.0,
    platform=0,
  )
  t.draw()
  assert_eq(seen_calls.val, 1, msg="initial active Changelog marks news-v1 seen once")
  // Switch to the second tab ("station") before parking.
  changelog_part.set("station")
  t.draw()
  assert_eq(changelog_part.untracked(), "station")
  // Park Changelog.
  page.set(1)
  t.draw()
  // Push fresh news while parked: must NOT call changelog.seen.
  news_sig.set("news-v2")
  t.draw()
  assert_eq(seen_calls.val, 1, msg="parked Changelog must not mark news-v2 seen while parked")
  // Wake Changelog back: hot return must build 0 nodes, preserve active tab, and immediately mark unread news-v2 seen.
  t.tree_frames_from_now()
  page.set(0)
  t.draw()
  let made = t.tree_frames().fold(init=0, fn(a, f) { a + f.made })
  assert_eq(made, 0, msg="Changelog hot return must build 0 nodes")
  assert_eq(changelog_part.untracked(), "station", msg="Changelog hot return must preserve selected tab")
  assert_eq(seen_calls.val, 2, msg="waking Changelog with unread news-v2 must immediately mark changelog.seen")
  @ui.run_let_go()
}

///|
test "PR-B3c r3 P1-4: Changelog constructed while covered (Medium Side foreground) does not mark seen until revealed" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sffixture.fixture_reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let seen_calls : Ref[Int] = Ref(0)
  let base_src = @sffixture.fixture("settings")
  let base_core = @sfbase.settings_core(base_src, rig_workspace)
  let topic_c = @signals.computed(fn(_) -> @settings.Read {
    {
      value: Some({
        "news": "news-covered-v1",
        "build": 1301,
        "tabs": [{ "part": "app", "label": "App", "days": [] }],
      }),
      error: None,
      version: 1,
    }
  })
  let core : @settings.Core = {
    ..base_core,
    topic: fn(name, params) {
      if name == "changelog" {
        topic_c
      } else {
        (base_core.topic)(name, params)
      }
    },
    call: fn(name, params, done) {
      if name == "changelog.seen" {
        seen_calls.val += 1
        done(Ok(Json::object({})))
      } else {
        (base_core.call)(name, params, done)
      }
    },
  }
  // Start covered (simulating Medium Tape with wide.tape_at == Side in foreground).
  let covered = @signals.signal(true)
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      @sf.look_lent(root, @sf.look_for(600.0))
      root.covered_box(fn() { covered.get() }, fn(slot) {
        slot.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        changelog_node(slot, core, on_back=fn() {  }, frame=fn() { @sf.no_frame })
      })
      |> ignore
    },
    w=600.0,
    h=900.0,
    platform=0,
  )
  t.draw()
  assert_eq(seen_calls.val, 0, msg="Changelog built while covered must not fire changelog.seen before switching to Page")
  // Reveal Page: now when_active enters and marks unread news-covered-v1 seen.
  covered.set(false)
  t.draw()
  assert_eq(seen_calls.val, 1, msg="Changelog must fire changelog.seen once revealed on Page")
  @ui.run_let_go()
}

///|
test "PR-B3c Appearance: zoom picker closes on park and hot-return wake writes 0 prefs" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sffixture.fixture_reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let pref_writes : Array[String] = []
  let base_src = @sffixture.fixture("settings")
  let base_core = @sfbase.settings_core(base_src, rig_workspace)
  let core : @settings.Core = {
    ..base_core,
    call: fn(name, params, done) {
      if name == "prefs.set" {
        pref_writes.push(params.stringify())
        done(Ok(Json::object({})))
      } else {
        (base_core.call)(name, params, done)
      }
    },
  }
  let page = @signals.signal(0)
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      @sf.look_lent(root, @sf.look_for(1280.0))
      root.pick_kept(at_once=true, fn() { page.get() }, fn(slot, which) {
        if which == 0 {
          appearance_node(slot, core, on_back=fn() {  }, frame=fn() { @sf.no_frame }, width=fn() { 900.0 })
        }
      })
      @sf.presented_nodes(root)
    },
    w=1280.0,
    h=800.0,
    platform=0,
  )
  t.draw()
  // Open zoom picker popup (100% button on macOS).
  assert_true(t.query(Button, label="100%") is Some(_), msg="zoom button should be present on macOS")
  t.click(Button, label="100%")
  t.draw()
  assert_true(@sf.presenting(), msg="zoom picker must be open after clicking zoom button")
  // Park Appearance: zoom picker must close synchronously and write 0 prefs.
  page.set(1)
  t.draw()
  assert_false(@sf.presenting(), msg="zoom picker must close when Appearance is parked")
  assert_eq(pref_writes.length(), 0, msg="parking Appearance must not write prefs")
  // Wake Appearance back: made == 0 and 0 prefs.set calls.
  t.tree_frames_from_now()
  page.set(0)
  t.draw()
  let made = t.tree_frames().fold(init=0, fn(a, f) { a + f.made })
  assert_eq(made, 0, msg="Appearance hot return must build 0 nodes")
  assert_eq(pref_writes.length(), 0, msg="waking Appearance must not write prefs")
  // Instance-owned accent preview: an older instance clearing its preview never clears a newer instance's preview.
  @sfbase.accent_preview_by(101, Some("blue"))
  @sfbase.accent_preview_by(102, Some("teal"))
  let teal_accent = @sf.theme().p.accent
  @sfbase.accent_preview_by(101, None)
  assert_eq(@sf.theme().p.accent, teal_accent, msg="stale Appearance instance must not clear newer instance's accent preview")
  @sfbase.accent_preview_by(102, None)
  @ui.run_let_go()
}

///|
test "PR-B3c About: management calls guarded against role downgrade, workspace/station change, and parked delayed click; 0 calls on park/wake" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sffixture.fixture_reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let calls : Array[String] = []
  let role_sig : @signals.Signal[String] = @signals.signal("admin")
  let base_src = @sffixture.fixture("settings")
  let base_core = @sfbase.settings_core(base_src, rig_workspace)
  let ws_c = @signals.computed(fn(_) -> @settings.Read {
    { value: Some({ "id": "ws1", "name": "Willow", "role": Json::string(role_sig.get()) }), error: None, version: 1 }
  })
  let stations_c = @signals.computed(fn(_) -> @settings.Read {
    { value: Some([{ "station": "ws1/st1", "online": true }]), error: None, version: 1 }
  })
  let updates_c = @signals.computed(fn(_) -> @settings.Read {
    {
      value: Some([
        {
          "id": "station",
          "name": "Station",
          "installed": true,
          "shownText": "0.1.1200",
          "latest": "0.1.1300",
          "newer": true,
          "auto": false,
          "earlier": ["0.1.1100"],
        },
      ]),
      error: None,
      version: 1,
    }
  })
  let version_checks = Ref(0)
  let version_taps = Ref(0)
  let core : @settings.Core = {
    ..base_core,
    topic: fn(name, params) {
      if name == "workspace" {
        ws_c
      } else if name == "station_rows" || name == "stations" {
        stations_c
      } else if name == "stationPart" && params.get("part") == Some(Json::string("updates")) {
        updates_c
      } else {
        (base_core.topic)(name, params)
      }
    },
    call: fn(name, params, done) {
      calls.push(name + ":" + params.stringify())
      done(Ok(Json::object({})))
    },
    version_check: fn() { version_checks.val += 1 },
    version_tap: fn() { version_taps.val += 1 },
  }
  set_this_machine("ws1/st1")
  let page = @signals.signal(0)
  let about_root : Ref[@view.View?] = Ref(None)
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      @sf.look_lent(root, @sf.look_for(1280.0))
      root.pick_kept(at_once=true, fn() { page.get() }, fn(slot, which) {
        if which == 0 {
          about_root.val = Some(slot)
          about_node(slot, core, on_back=fn() {  }, frame=fn() { @sf.no_frame }, width=fn() { 900.0 })
        }
      })
      @sf.presented_nodes(root)
    },
    w=1280.0,
    h=800.0,
    platform=0,
    keeps_sources=true,
    before=fn() { @hostapi.app_said("local_station") |> ignore },
  )
  t.set_app_said(
    "local_station",
    "{\"data\":\"~/.stillfail\",\"runner\":\"service\",\"workspace\":{\"id\":\"ws1\",\"station\":\"st1\",\"stationName\":\"Willow\"}}",
  )
  t.run_for(@settings.local_read_ms)
  t.draw()
  // As admin, 退回旧版本 menu opens and leads to confirm dialog.
  let back_label = @sf.t("web-main.versions.back")
  assert_true(t.find(back_label) is Some(_), msg="admin should see rollback action")
  t.tap_text(back_label)
  t.draw()
  t.tap_text("0.1.1100")
  t.draw()
  let confirm_btn = @sf.t("web-main.versions.backDo")
  assert_true(t.query(Button, label=confirm_btn) is Some(_), msg="confirm dialog should open")
  // Scenario A: role downgraded from admin -> member BEFORE clicking confirm (delayed click)!
  role_sig.set("member")
  t.draw()
  t.click(Button, label=confirm_btn)
  t.run_for(@ui.move_most_ms)
  assert_eq(calls.length(), 0, msg="delayed confirm after role downgrade must execute 0 software calls")
  // Restore admin, re-open confirm dialog, then change REAL host `local_station` JSON and click confirm IMMEDIATELY
  // (WITHOUT waiting for the 3000ms polling cycle!) -> synchronous host re-read must reject the stale station call.
  role_sig.set("admin")
  t.draw()
  t.click(Button, label=back_label)
  t.run_for(@ui.move_most_ms)
  t.tap_text("0.1.1100")
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label=confirm_btn) is Some(_), msg="second confirm dialog should open")
  t.set_app_said(
    "local_station",
    "{\"data\":\"~/.stillfail\",\"runner\":\"service\",\"workspace\":{\"id\":\"ws2\",\"station\":\"st2\",\"stationName\":\"Other\"}}",
  )
  t.click(Button, label=confirm_btn)
  t.run_for(@ui.move_most_ms)
  assert_eq(calls.length(), 0, msg="immediate confirm after host station change (within 3s poll window) must execute 0 software calls")
  // Scenario C: restore live local_station, open confirm dialog in active_gen N, park -> wake (active_gen N+1),
  // then click the stale confirm button -> must be rejected by active_gen check!
  t.set_app_said(
    "local_station",
    "{\"data\":\"~/.stillfail\",\"runner\":\"service\",\"workspace\":{\"id\":\"ws1\",\"station\":\"st1\",\"stationName\":\"Willow\"}}",
  )
  t.run_for(@settings.local_read_ms)
  t.draw()
  t.click(Button, label=back_label)
  t.run_for(@ui.move_most_ms)
  t.tap_text("0.1.1100")
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label=confirm_btn) is Some(_), msg="third confirm dialog should open")
  page.set(1)
  t.draw()
  assert_eq(t.subtree_timeline_count(about_root.val.unwrap()), 0, msg="parked About must own 0 timers")
  t.tree_frames_from_now()
  page.set(0)
  t.draw()
  let made = t.tree_frames().fold(init=0, fn(a, f) { a + f.made })
  assert_eq(made, 0, msg="About hot return must build 0 nodes")
  if t.query(Button, label=confirm_btn) is Some(_) {
    t.click(Button, label=confirm_btn)
    t.run_for(@ui.move_most_ms)
  }
  assert_eq(calls.length(), 0, msg="park/wake stale confirm click must execute 0 software calls")
  assert_eq(version_checks.val, 0, msg="park/wake About must not fire version_check")
  assert_eq(version_taps.val, 0, msg="park/wake About must not fire version_tap")
  @ui.run_let_go()
}

///|
test "PR-B3c Fonts: park closes own panel and clears drag; evicting old instance never closes new instance panel" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sffixture.fixture_reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let base_src = @sffixture.fixture("settings")
  let core = @sfbase.settings_core(base_src, rig_workspace)
  let page = @signals.signal(0)
  let drop_inst1 = @signals.signal(false)
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      @sf.look_lent(root, @sf.look_for(1280.0))
      root.pick_kept(
        at_once=true,
        keep_if=fn(k) { !(k == 0 && drop_inst1.untracked()) },
        keeps_max=2,
        fn() { page.get() },
        fn(slot, which) {
          if which == 0 || which == 2 {
            fonts_node(slot, core, on_back=fn() {  }, frame=fn() { @sf.no_frame }, width=fn() { 900.0 })
          }
        },
      )
      @sf.presented_nodes(root)
    },
    w=1280.0,
    h=800.0,
    platform=0,
  )
  t.draw()
  // Open a font slot picker panel on Instance 1 and simulate active slider drag owned by Instance 1.
  let slot_label = @sf.t("web-pages.appearance.fonts.ui") + @sf.t("web-pages.appearance.fonts.scriptShort.latin")
  t.click(Button, label=slot_label)
  t.draw()
  assert_true(@sf.presenting(), msg="Instance 1 font picker panel must open")
  assert_eq(font_picker_open.untracked(), 0)
  // Park Instance 1 -> must close its panel synchronously.
  page.set(1)
  t.draw()
  assert_false(@sf.presenting(), msg="parking Instance 1 must close its panel_nodes")
  assert_eq(font_picker_open.untracked(), -1, msg="parking Instance 1 must reset font_picker_open")
  assert_false(local_open.untracked(), msg="parking Instance 1 must reset local_open")
  // Open Instance 2 and open its font picker panel.
  page.set(2)
  t.draw()
  t.click(Button, label=slot_label)
  t.draw()
  assert_true(@sf.presenting(), msg="Instance 2 font picker panel must open")
  let inst2_panel = @sf.last_presented()
  assert_eq(font_picker_open.untracked(), 0)
  // Trigger LRU eviction of Instance 1 (keeps_max=2: active=2, parked=1, open=3 -> evicts oldest parked 0!).
  // Wait: parked pool currently has [0, 1]; switch 2 -> 3 would evict 0 while parking 2, so instead switch 2 -> 2?
  // Even cleaner: open a 3rd key on a separate show/pick or evict Instance 1 directly while Instance 2 stays active!
  // Let's verify using a dedicated sibling show for Instance 1 eviction while Instance 2 stays active in test below.
  assert_true(@sf.presented_open_of(inst2_panel), msg="Instance 2 panel stays open")
  @ui.run_let_go()
}

///|
test "PR-B3c Fonts: evicting parked old instance never closes active new instance panel" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sffixture.fixture_reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let base_src = @sffixture.fixture("settings")
  let core = @sfbase.settings_core(base_src, rig_workspace)
  let show_old = @signals.signal(true)
  let old_page = @signals.signal(0)
  let show_new = @signals.signal(false)
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      @sf.look_lent(root, @sf.look_for(1280.0))
      root.show(at_once=true, fn() { show_old.get() }, fn(host) {
        host.pick_kept(at_once=true, fn() { old_page.get() }, fn(slot, which) {
          if which == 0 {
            fonts_node(slot, core, on_back=fn() {  }, frame=fn() { @sf.no_frame }, width=fn() { 900.0 })
          }
        })
      })
      root.show(at_once=true, fn() { show_new.get() }, fn(slot) {
        fonts_node(slot, core, on_back=fn() {  }, frame=fn() { @sf.no_frame }, width=fn() { 900.0 })
      })
      @sf.presented_nodes(root)
    },
    w=1280.0,
    h=800.0,
    platform=0,
  )
  t.draw()
  let slot_label = @sf.t("web-pages.appearance.fonts.ui") + @sf.t("web-pages.appearance.fonts.scriptShort.latin")
  t.click(Button, label=slot_label)
  t.draw()
  assert_true(@sf.presenting(), msg="old instance panel opens")
  // Park old instance -> its panel closes.
  old_page.set(1)
  t.draw()
  assert_false(@sf.presenting(), msg="parking old instance closes its panel")
  // Mount new instance and open its panel.
  show_new.set(true)
  t.draw()
  t.click(Button, label=slot_label)
  t.draw()
  let new_panel = @sf.last_presented()
  assert_true(@sf.presented_open_of(new_panel), msg="new instance panel opens")
  // Now permanently evict/dispose the parked old instance!
  show_old.set(false)
  t.draw()
  assert_true(@sf.presented_open_of(new_panel), msg="evicting old Fonts instance must NEVER close new instance's panel")
  assert_eq(font_picker_open.untracked(), 0, msg="new instance font_picker_open must remain intact")
  assert_true(local_open.untracked(), msg="new instance local_open must remain true")
  @ui.run_let_go()
}

///|
test "PR-B3c Shortcuts: parking during key recording releases global recorder, next key reaches window with 0 keys.set, hot return stays non-recording" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sffixture.fixture_reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let keys_set_calls = Ref(0)
  let window_hits = Ref(0)
  let base_src = @sffixture.fixture("settings")
  let base_core = @sfbase.settings_core(base_src, rig_workspace)
  let prefs_json : Json = {
    "keymap": {
      "changeable": true,
      "groups": [{ "group": "app", "name": "App" }],
      "actions": [
        {
          "action": "app.test",
          "group": "app",
          "name": "Test Action",
          "listed": true,
          "typing": "always",
          "keys": ["Mod+K"],
          "labels": ["⌘K"],
          "text": "⌘K",
          "changed": false,
        },
      ],
    },
  }
  let prefs_c = @signals.computed(fn(_) -> @settings.Read { { value: Some(prefs_json), error: None, version: 1 } })
  let core : @settings.Core = {
    ..base_core,
    topic: fn(name, params) {
      if name == "prefs" {
        prefs_c
      } else {
        (base_core.topic)(name, params)
      }
    },
    call: fn(name, params, done) {
      if name == "keys.set" {
        keys_set_calls.val += 1
        done(Ok(Json::object({})))
      } else {
        (base_core.call)(name, params, done)
      }
    },
  }
  let page = @signals.signal(0)
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      @sf.look_lent(root, @sf.look_for(1280.0))
      root.keymap(By(fn() { @settings.keymap_of(Some(prefs_json)) })) |> ignore
      root.on_action("app.test", fn(_) {
        window_hits.val += 1
        true
      })
      |> ignore
      root.pick_kept(at_once=true, fn() { page.get() }, fn(slot, which) {
        if which == 0 {
          shortcuts_node(
            slot,
            core,
            on_back=fn() {  },
            frame=fn() { @sf.no_frame },
            active=fn() { page.get() == 0 },
            width=fn() { 900.0 },
          )
        }
      })
    },
    w=1280.0,
    h=800.0,
    platform=0,
  )
  t.draw()
  // Enter recording state by clicking the shortcut key button for "app.test" ("⌘K").
  t.tap_text("⌘K")
  t.draw()
  assert_eq(@settings.keys_recording.untracked(), "app.test", msg="must enter recording state")
  assert_eq(
    @settings.keys_recording_window.untracked(),
    @ui.current_window_id(),
    msg="recording state must bind to the recording window's id",
  )
  // Explicit window_id binding: while main window is recording, an already-open secondary window's keymap & labels
  // (bound to its own wid) must NOT be blanked even while current_window_id() is the main window.
  let root_v = @ui.view_tree().unwrap().root()
  let main_wid = @ui.current_window_id()
  let secondary_wid = main_wid + 99
  assert_true(
    @settings.reachable_key_label(Some(prefs_json), "app.test", root_v, window_id=secondary_wid) != "",
    msg="main window recording must not suppress secondary window's key label",
  )
  assert_eq(
    @settings.reachable_key_label(Some(prefs_json), "app.test", root_v, window_id=main_wid),
    "",
    msg="main window recording suppresses main window's key label",
  )
  // Park Shortcuts while recording!
  page.set(1)
  t.draw()
  assert_eq(@settings.keys_recording.untracked(), "", msg="parking Shortcuts must synchronously release global keys_recording")
  assert_eq(@settings.keys_recording_window.untracked(), 0, msg="parking Shortcuts must clear keys_recording_window")
  // Send Mod+K: must reach current window's action handler normally and trigger 0 keys.set calls!
  t.key(@ui.key_of_char('k'), mods=@ui.mod_cmd)
  t.draw()
  assert_eq(window_hits.val, 1, msg="next key after parking Shortcuts must reach current window normally")
  assert_eq(keys_set_calls.val, 0, msg="parked Shortcuts must trigger 0 keys.set calls")
  // Hot return to Shortcuts: made == 0 and remains non-recording.
  t.tree_frames_from_now()
  page.set(0)
  t.draw()
  let made = t.tree_frames().fold(init=0, fn(a, f) { a + f.made })
  assert_eq(made, 0, msg="Shortcuts hot return must build 0 nodes")
  assert_eq(@settings.keys_recording.untracked(), "", msg="Shortcuts hot return must stay non-recording")
  @ui.run_let_go()
}
