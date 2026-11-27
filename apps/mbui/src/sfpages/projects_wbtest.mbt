// Line A unit & UI tests for PR 3 Chat Classification System:
// - Grouped chats decode & collision-free keys (named project literally "已固定" vs pinned)
// - held_order preserving ChatDay group metadata
// - Cold-start 3-state gate (list_opens waiting for prefs + base "all" + grouped query)
// - Validation matching station/src/store/rows.ts:129-134
// - ProjectListChain pagination, staleCursor recovery, park/wake release & single-chain restore
// - ProjectDetailChain multi-page note+refs assembly (1,800 CJK + 15 refs) + infoRevision mismatch detection
// - Wire payload checks: presetId, proposal entryN+accept->accepted, project_update_info changed-fields-only
// - Settings Projects & Project Detail UI audit (`t.audit()` 0 warnings)

///|
fn proj_test_source(
  read : (String, Map[String, Json]) -> Json?,
  call? : (String, Json, (Result[Json, Json]) -> Unit) -> Unit = fn(_, _, done) { done(Ok(Json::object({}))) },
) -> Source {
  let base = @sffixture.fixture("home")
  {
    ..base,
    topic_read: fn(name, params) {
      match read(name, params) {
        Some(v) => { value: Some(v), error: None, version: 1 }
        None => { value: None, error: None, version: 0 }
      }
    },
    call,
  }
}

///|
test "grouped chats decode, collision-free '已固定' project key, and held_order metadata preservation" {
  @sfbase.projects_reset()
  let raw : Json = {
    "stations": [{ "station": "ws/s1", "state": "online" }],
    "leading": "agents",
    "projects": true,
    "projectsWritable": true,
    "days": [],
    "groups": [
      {
        "key": "pinned",
        "kind": "pinned",
        "label": "已固定",
        "chatCount": 1,
        "runningCount": 1,
        "askingCount": 0,
        "unreadCount": 0,
        "items": [
          {
            "id": "c-pin",
            "session": "c-pin",
            "title": "Pinned chat",
            "station": "ws/s1",
            "stationName": "S1",
            "pinned": true,
            "project": "monoid",
            "projectLocked": true,
            "tags": ["ios"],
          },
        ],
      },
      {
        "key": "project:已固定",
        "kind": "project",
        "label": "已固定",
        "project": "已固定",
        "chatCount": 5,
        "runningCount": 0,
        "alertCount": 1,
        "askingCount": 2,
        "unreadCount": 1,
        "items": [
          {
            "id": "c-proj",
            "session": "c-proj",
            "title": "Project literally named 已固定",
            "station": "ws/s1",
            "stationName": "S1",
            "project": "已固定",
            "tags": ["ui-review", "board"],
          },
        ],
      },
      {
        "key": "unclassified",
        "kind": "unclassified",
        "label": "未归类",
        "chatCount": 1,
        "runningCount": 0,
        "alertCount": 0,
        "askingCount": 0,
        "unreadCount": 0,
        "items": [
          {
            "id": "c-cross",
            "session": "c-cross",
            "title": "Unclassified chat",
            "station": "ws/s1",
            "stationName": "S1",
            "project": "",
          },
        ],
      },
    ],
  }
  let view = @sfbase.chats_view_made(raw)
  assert_true(view.projects)
  assert_true(view.projects_writable)
  assert_true(view.grouped)
  assert_eq(view.days.length(), 3)
  assert_eq(view.days[0].key, "pinned")
  assert_eq(view.days[1].key, "project:已固定")
  assert_eq(view.days[1].chat_count, 5)
  assert_eq(view.days[1].alert_count, 1)
  assert_eq(view.days[1].asking_count, 2)
  assert_eq(view.days[2].items[0].project, Some(""))
  let lines = day_keys(view.days)
  assert_true(lines.contains("h/pinned"))
  assert_true(lines.contains("h/project:已固定"))
  assert_true(lines.contains("h/unclassified"))
  let held = @sfbase.held_order("test-grp-key", view.days, true)
  assert_eq(held.length(), 3)
  assert_eq(held[1].key, "project:已固定")
  assert_eq(held[1].chat_count, 5)
  assert_eq(held[1].alert_count, 1)
  assert_eq(held[1].asking_count, 2)
}

///|
test "client validation matches station rows.ts rules (80/48/3, trim, dedup, forbidden chars)" {
  @sf.set_words(@sfbase.fill)
  assert_true(@sfbase.validate_project_name("   ") is Err(_))
  assert_true(@sfbase.validate_project_name("a,b") is Err(_))
  assert_true(@sfbase.validate_project_name("a\nb") is Err(_))
  assert_eq(@sfbase.validate_project_name("  monoid  "), Ok("monoid"))
  let ok80 = "a".repeat(80)
  let bad81 = "a".repeat(81)
  assert_eq(@sfbase.validate_project_name(ok80), Ok(ok80))
  assert_true(@sfbase.validate_project_name(bad81) is Err(_))

  let ok48 = "t".repeat(48)
  let bad49 = "t".repeat(49)
  assert_eq(@sfbase.validate_tag_name(ok48), Ok(ok48))
  assert_true(@sfbase.validate_tag_name(bad49) is Err(_))
  assert_true(@sfbase.validate_tag_name("bad,tag") is Err(_))

  assert_eq(@sfbase.normalize_tags([" ios ", "ios", "", "ui-review", "board"]), Ok(["ios", "ui-review", "board"]))
  assert_true(@sfbase.normalize_tags(["a", "b", "c", "d"]) is Err(_))
}

///|
test "cold-start 3-state gate waits for prefs + base all + grouped query before ready" {
  @sfbase.projects_reset()
  let has_prefs : Ref[Bool] = Ref(false)
  let has_base : Ref[Bool] = Ref(false)
  let has_grouped : Ref[Bool] = Ref(false)
  let read = fn(name : String, params : Map[String, Json]) -> Json? {
    if name == "prefs" {
      if has_prefs.val { Some({ "listGroups": { "ws1": "project" } }) } else { None }
    } else if name == "chats" {
      if params.get("groupBy") == Some(Json::string("project")) {
        if has_grouped.val { Some({ "projects": true, "groups": [] }) } else { None }
      } else if has_base.val {
        Some({ "projects": true, "projectsWritable": true, "days": [] })
      } else {
        None
      }
    } else {
      None
    }
  }
  let src = proj_test_source(read)
  let ask = fn(name : String, params : Map[String, Json]) -> @sfbase.TopicState {
    match read(name, params) {
      Some(v) => { value: Some(v), error: None, version: 1, waiting: false }
      None => { value: None, error: None, version: 0, waiting: true }
    }
  }
  assert_false(@sfbase.list_opens(src, "ws1", ask))
  has_prefs.val = true
  assert_false(@sfbase.list_opens(src, "ws1", ask))
  has_base.val = true
  assert_true(@sfbase.projects_cap(src, "ws1") == On)
  assert_eq(@sfbase.list_group_by(src, "ws1"), "project")
  assert_false(@sfbase.list_opens(src, "ws1", ask))
  has_grouped.val = true
  assert_true(@sfbase.list_opens(src, "ws1", ask))
}

///|
test "ProjectDetailChain assembles 1800-CJK note + 15 refs across transition page and detects infoRevision mismatch" {
  @sfbase.projects_reset()
  let chunk1 = "汉".repeat(900)
  let chunk2 = "字".repeat(900)
  let refs1 : Array[Json] = Array::makei(7, fn(i) { Json::string("https://example.com/r" + i.to_string()) })
  let refs2 : Array[Json] = Array::makei(8, fn(i) { Json::string("https://example.com/r" + (i + 7).to_string()) })
  let rev2 : Ref[String] = Ref("revAAAAAAAAAAAA1")
  let src = proj_test_source(fn(name, params) {
    guard name == "project" else { return None }
    let cur = match params.get("cursor") {
      Some(String(c)) => c
      _ => ""
    }
    if cur == "" {
      let j : Json = {
        "name": "monoid",
        "note": Json::string(chunk1),
        "updatedAt": 500.0,
        "infoRevision": "revAAAAAAAAAAAA1",
        "chatCount": 10.0,
        "nextCursor": "n:900",
      }
      Some(j)
    } else if cur == "n:900" {
      let j : Json = {
        "name": "monoid",
        "note": Json::string(chunk2),
        "refs": Json::array(refs1),
        "updatedAt": 500.0,
        "infoRevision": Json::string(rev2.val),
        "chatCount": 10.0,
        "nextCursor": "r:7",
      }
      Some(j)
    } else {
      let j : Json = {
        "name": "monoid",
        "refs": Json::array(refs2),
        "updatedAt": 500.0,
        "infoRevision": Json::string(rev2.val),
        "chatCount": 10.0,
      }
      Some(j)
    }
  })
  let chain = @sfbase.ProjectDetailChain::new("ws1", "monoid")
  let d1 = chain.read(src)
  assert_false(d1.complete)
  chain.sync(src)
  let d2 = chain.read(src)
  assert_false(d2.complete)
  chain.sync(src)
  let d3 = chain.read(src)
  assert_true(d3.complete)
  assert_true(d3.editable)
  assert_eq(d3.note.length(), 1800)
  assert_eq(d3.note, chunk1 + chunk2)
  assert_eq(d3.refs.length(), 15)
  assert_eq(d3.refs[0], "https://example.com/r0")
  assert_eq(d3.refs[14], "https://example.com/r14")

  rev2.val = "revBBBBBBBBBBBB2"
  let d_mismatch = chain.read(src)
  assert_false(d_mismatch.complete)
  chain.sync(src)
  chain.release()
}

///|
test "ProjectListChain staleCursor recovery and release generation bump" {
  @sfbase.projects_reset()
  let stale : Ref[Bool] = Ref(false)
  let src = proj_test_source(fn(name, params) {
    guard name == "projects" else { return None }
    let cur = match params.get("cursor") {
      Some(String(c)) => c
      _ => ""
    }
    if cur == "" {
      let j : Json = {
        "items": [{ "name": "alpha", "chatCount": 3.0 }],
        "total": 2.0,
        "nextCursor": "p2",
      }
      Some(j)
    } else if stale.val {
      let j : Json = { "items": [], "staleCursor": true }
      Some(j)
    } else {
      let j : Json = { "items": [{ "name": "beta", "chatCount": 1.0 }], "total": 2.0 }
      Some(j)
    }
  })
  let chain = @sfbase.ProjectListChain::new("ws1")
  let s1 = chain.read(src)
  assert_eq(s1.items.length(), 1)
  assert_true(s1.has_more)
  chain.load_more(src)
  let s2 = chain.read(src)
  assert_eq(s2.items.length(), 2)
  assert_false(s2.has_more)
  // Trigger staleCursor -> resets cleanly to page 1 and bumps generation via sync()
  let gen_before = chain.generation()
  stale.val = true
  let s3 = chain.read(src)
  assert_true(s3.loading)
  chain.sync(src)
  assert_true(chain.generation() > gen_before)
  stale.val = false
  let s4 = chain.read(src)
  assert_eq(s4.items.length(), 1)
  assert_eq(s4.items[0].name, "alpha")
  chain.release()
}

///|
test "wire payloads: presetId, proposal entryN+accept->accepted, project_update_info changed-fields-only" {
  @sfbase.projects_reset()
  let calls : Array[(String, Json)] = []
  let src = proj_test_source(
    fn(_, _) { None },
    call=fn(name, body, done) {
      calls.push((name, body))
      if name == "proposal.resolve" {
        let ok : Json = { "ok": true, "alreadyResolved": true, "status": "accepted", "resolvedProject": "monoid" }
        done(Ok(ok))
      } else {
        let ok : Json = { "ok": true, "synced": true }
        done(Ok(ok))
      }
    },
  )
  let preset_ok = Ref(false)
  @sfbase.preset_set_project(src, "ws1", "p-123", Some("monoid"), on_done=fn(r) { preset_ok.val = r.ok && r.synced })
  assert_true(preset_ok.val)
  assert_eq(calls[0].0, "preset.setProject")
  assert_eq(text(Some(calls[0].1), "presetId"), "p-123")
  assert_eq(text(Some(calls[0].1), "project"), "monoid")

  let prop_status = Ref("")
  let prop_already = Ref(false)
  @sfbase.proposal_resolve(src, "ws1/s1", 42.0, 7.0, "accept", name=Some("monoid"), on_done=fn(r) {
    prop_status.val = r.status
    prop_already.val = r.already_resolved
  })
  assert_eq(prop_status.val, "accepted")
  assert_true(prop_already.val)
  assert_false(@sfbase.proposal_is_pending("ws1/s1", 42.0, 7.0))
  assert_eq(calls[1].0, "proposal.resolve")
  assert_eq(number(Some(calls[1].1), "entryN"), 7.0)
  assert_eq(text(Some(calls[1].1), "action"), "accept")

  @sfbase.project_update_info(src, "ws1", "monoid", note=Some("updated note"))
  assert_eq(calls[2].0, "project.updateInfo")
  assert_eq(text(Some(calls[2].1), "note"), "updated note")
  assert_true(field(Some(calls[2].1), "refs") is None)
}

///|
test "settings Projects and Project detail UI audit across widths and en locale" {
  for cfg in [(390.0, 2, "zh"), (1024.0, 0, "zh"), (390.0, 2, "en-US")] {
    let (w, platform, loc) = cfg
    let t = setting_tester(
      Projects,
      w,
      platform~,
      ready=fn() { @sffixture.fx_projects_on.val = true },
      env=[("MBUI_LOCALE", loc)],
    )
    let warns = t.audit()
    assert_eq(warns.length(), 0, msg="Projects audit failed at w=\{w} loc=\{loc}: " + warns.join("; "))
    assert_true(t.find("monoid") is Some(_), msg="Projects list should render monoid at w=\{w} loc=\{loc}")

    let td = setting_tester(
      Project("monoid"),
      w,
      platform~,
      ready=fn() { @sffixture.fx_projects_on.val = true },
      env=[("MBUI_LOCALE", loc)],
    )
    let dwarns = td.audit()
    assert_eq(dwarns.length(), 0, msg="Project detail audit failed at w=\{w} loc=\{loc}: " + dwarns.join("; "))
  }
  @sf.set_language(None)
}

///|
test "R1 regressions: ProjectDetailChain cursor-fork A->B 1800 CJK, list fork, real wire fields, rapid tag toggle, nested proposal, settings_list v_stations" {
  @sfbase.reset()
  reset()
  @sf.set_words(@sfbase.fill)

  // 1. ProjectDetailChain cursor-fork: A has n:1732; B (1800 CJK) has n:1066. Both B pages arrive -> drops n:1732, reads n:1066, assembles full 1800 chars!
  let cjk1066 = String::make(1066, '中')
  let cjk734 = String::make(734, '文')
  let rev_b = "rev-b-1800"
  let pages : Map[String, Json] = Map([])
  // Seed A: page 0 -> n:1732, page n:1732 -> done
  pages[""] = Json::object({ "name": "monoid", "note": "ascii-part", "refs": Json::array([]), "infoRevision": "rev-a", "nextCursor": "n:1732" })
  pages["n:1732"] = Json::object({ "name": "monoid", "note": "tail-a", "refs": Json::array([]), "infoRevision": "rev-a" })
  let calls : Array[(String, Json)] = []
  let src = proj_test_source(
    fn(name, params) {
      if name == "project" {
        pages.get(text(Some(Json::object(params)), "cursor"))
      } else if name == "projects" {
        pages.get("list:" + text(Some(Json::object(params)), "cursor"))
      } else if name == "tags" {
        pages.get("tags:" + text(Some(Json::object(params)), "cursor"))
      } else {
        None
      }
    },
    call=fn(name, body, done) {
      calls.push((name, body))
      if name == "proposal.resolve" {
        // Authoritative nested proposal without resolvedProject -> must stay None (NOT Some(""))
        done(Ok(Json::object({ "proposal": Json::object({ "status": "dismissed" }), "alreadyResolved": Json::boolean(true) })))
      } else if name == "project.rename" {
        // Real peer status without `ok` boolean: offline with empty error MUST be treated as failed
        done(Ok(Json::object({
          "peers": Json::array([
            Json::object({ "station": "ws1/s1", "name": "Willow", "status": "ok" }),
            Json::object({ "station": "ws1/s2", "name": "Cedar", "status": "offline", "error": "" }),
          ]),
        })))
      } else {
        done(Ok(Json::object({ "ok": Json::boolean(true) })))
      }
    },
  )
  let dchain = @sfbase.ProjectDetailChain::new("ws1", "monoid")
  let d1 = dchain.read(src)
  assert_false(d1.complete) // advances to n:1732 via sync()
  dchain.sync(src)
  let d2 = dchain.read(src)
  assert_true(d2.complete)
  assert_true(d2.editable)
  assert_eq(d2.note, "ascii-parttail-a")
  // Now B arrives in a batch on both page 0 (nextCursor: n:1066) and stale page n:1732 (same rev_b, shifted tail!)
  pages[""] = Json::object({ "name": "monoid", "note": cjk1066, "refs": Json::array([]), "infoRevision": rev_b, "nextCursor": "n:1066" })
  pages["n:1732"] = Json::object({ "name": "monoid", "note": "WRONG_SHIFTED", "refs": Json::array([]), "infoRevision": rev_b })
  pages["n:1066"] = Json::object({ "name": "monoid", "note": cjk734, "refs": Json::array([]), "infoRevision": rev_b })
  // First read detects cursor link mismatch (n:1066 != n:1732), complete MUST be false!
  let d3 = dchain.read(src)
  assert_false(d3.complete)
  dchain.sync(src)
  // Next read reads page 0 + n:1066 cleanly -> complete == true with full 1800 CJK chars!
  let d4 = dchain.read(src)
  assert_true(d4.complete)
  assert_eq(d4.note.length(), 1800)
  assert_eq(d4.note, cjk1066 + cjk734)

  // 2. Real wire field decoding (`tags[].name`, `projects[].latestActiveAt`/`hasInfo`, `peers[].status`) + list cursor fork without staleCursor
  pages["list:"] = Json::object({
    "items": Json::array([Json::object({ "name": "alpha", "chatCount": 4.0, "latestActiveAt": 999.0, "hasInfo": Json::boolean(true) })]),
    "total": 2.0,
    "nextCursor": "s:snap1:1",
  })
  pages["list:s:snap1:1"] = Json::object({
    "items": Json::array([Json::object({ "name": "beta", "chatCount": 2.0, "latestActiveAt": 500.0, "hasInfo": Json::boolean(false) })]),
    "total": 2.0,
  })
  pages["tags:"] = Json::object({
    "items": Json::array([Json::object({ "name": "ui-review", "chatCount": 7.0, "latestActiveAt": 888.0 })]),
    "total": 1.0,
  })
  let pchain = @sfbase.ProjectListChain::new("ws1")
  let p1 = pchain.read(src)
  assert_eq(p1.items.length(), 1)
  assert_eq(p1.items[0].last_active_at, 999.0)
  assert_true(p1.items[0].has_note)
  pchain.load_more(src)
  let p2 = pchain.read(src)
  assert_eq(p2.items.length(), 2)
  // Page 0 reorders to snap2 without staleCursor -> fork detected, old snap1 suffix dropped, has_more preserved!
  pages["list:"] = Json::object({
    "items": Json::array([Json::object({ "name": "gamma", "chatCount": 9.0, "latestActiveAt": 1200.0, "hasInfo": Json::boolean(true) })]),
    "total": 2.0,
    "nextCursor": "s:snap2:1",
  })
  let p3 = pchain.read(src)
  assert_eq(p3.items.length(), 1)
  assert_eq(p3.items[0].name, "gamma")
  assert_true(p3.has_more)
  pchain.sync(src)

  let tchain = @sfbase.TagListChain::new("ws1")
  let ts = tchain.read(src)
  assert_eq(ts.items.length(), 1)
  assert_eq(ts.items[0].tag, "ui-review")

  // 3. Peer status decoding: offline with empty error => ok == false
  let rename_res : Ref[@sfbase.ProjectMutationResult?] = Ref(None)
  @sfbase.project_rename(src, "ws1", "alpha", "alpha2", on_done=fn(r) { rename_res.val = Some(r) })
  match rename_res.val {
    Some(r) => {
      assert_eq(r.peers.length(), 2)
      assert_true(r.peers[0].ok)
      assert_false(r.peers[1].ok)
      assert_eq(r.peers[1].name, "Cedar")
      assert_eq(r.peers[1].status, "offline")
    }
    None => fail("expected rename result")
  }

  // 4. Rapid tag toggle A then B before push settles to [A, B]
  let hold_callbacks : Array[(Result[Json, Json]) -> Unit] = []
  let queued_calls : Array[Json] = []
  let src_q = proj_test_source(
    fn(_, _) { None },
    call=fn(_, body, done) {
      queued_calls.push(body)
      hold_callbacks.push(done)
    },
  )
  @sfbase.chat_toggle_tag(src_q, "ws1/s1", 9.0, [], "tagA")
  @sfbase.chat_toggle_tag(src_q, "ws1/s1", 9.0, [], "tagB")
  assert_eq(queued_calls.length(), 1) // serialized: first in flight
  hold_callbacks[0](Ok(Json::object({ "ok": Json::boolean(true) })))
  assert_eq(queued_calls.length(), 2)
  let second_tags = items(Some(queued_calls[1]), "tags").map(fn(x) { match x { String(s) => s; _ => "" } })
  assert_eq(second_tags, ["tagA", "tagB"])
  hold_callbacks[1](Ok(Json::object({ "ok": Json::boolean(true) })))

  // 5. Nested proposal without resolvedProject stays None (even when mark_cross=true); reassign rejects ""
  let prop_res : Ref[@sfbase.ProposalResolveResult?] = Ref(None)
  @sfbase.proposal_resolve(src, "ws1/s1", 9.0, 1.0, "dismiss", mark_cross=true, on_done=fn(r) { prop_res.val = Some(r) })
  match prop_res.val {
    Some(r) => {
      assert_true(r.ok)
      assert_eq(r.status, "dismissed")
      assert_eq(r.resolved_project, None)
    }
    None => fail("expected proposal result")
  }
  let bad_reassign : Ref[@sfbase.ProposalResolveResult?] = Ref(None)
  @sfbase.proposal_resolve(src, "ws1/s1", 9.0, 2.0, "reassign", target=Some(""), on_done=fn(r) { bad_reassign.val = Some(r) })
  match bad_reassign.val {
    Some(r) => assert_false(r.ok)
    None => fail("expected bad reassign error")
  }
}

///|
test "R2 regressions: cached detail non-editable until live, rapid tag remove with early 200, pane_list_query parity" {
  @sfbase.reset()
  reset()
  @sf.set_words(@sfbase.fill)

  // 1. Astra P1-1: cached detail (version = -2 / kept) displays read-only (complete=true) but editable=false until live (version>=0) arrives
  let ver : Ref[Int] = Ref(-2)
  let base = @sffixture.fixture("home")
  let src_cached : Source = {
    ..base,
    topic_read: fn(name, _params) {
      if name == "project" {
        let j : Json = {
          "name": "monoid",
          "note": "cached note",
          "refs": ["AFK-surf/monoid"],
          "infoRevision": "rev-cached-1",
          "chatCount": 5.0,
        }
        { value: Some(j), error: None, version: ver.val }
      } else {
        { value: None, error: None, version: 0 }
      }
    },
  }
  let cchain = @sfbase.ProjectDetailChain::new("ws1", "monoid")
  let dc = cchain.read(src_cached)
  assert_true(dc.complete)
  assert_false(dc.editable)
  assert_eq(dc.note, "cached note")
  // Now live answer arrives (version = 1) -> editable unlocks!
  ver.val = 1
  let dl = cchain.read(src_cached)
  assert_true(dl.complete)
  assert_true(dl.editable)

  // 2. Astra P1-3: chat_remove_tag removing A then B when first 200 returns BEFORE ChatView.tags updates -> sends [B] then []
  let sent_tags : Array[Array[String]] = []
  let src_tags = proj_test_source(
    fn(_, _) { None },
    call=fn(_name, body, done) {
      let arr = items(Some(body), "tags").map(fn(x) { match x { String(s) => s; _ => "" } })
      sent_tags.push(arr)
      // Immediate 200 before live ChatView.tags updates!
      done(Ok(Json::object({ "ok": Json::boolean(true) })))
    },
  )
  // Both calls pass stale current_tags = ["tagA", "tagB"] (simulating live view not pushed yet)
  @sfbase.chat_remove_tag(src_tags, "ws1/s1", 42.0, ["tagA", "tagB"], "tagA")
  @sfbase.chat_remove_tag(src_tags, "ws1/s1", 42.0, ["tagA", "tagB"], "tagB")
  assert_eq(sent_tags.length(), 2)
  assert_eq(sent_tags[0], ["tagB"])
  assert_eq(sent_tags[1], [])
  // Once authoritative live view pushes [], reconcile clears desired state cleanly
  @sfbase.classify_reconcile_tags("ws1/s1", 42.0, [])

  // 3. Opus P1-2: pane_list_query falls back to time grouping ("") when single-project filter is active
  @sfbase.set_project_filter("ws1", Named("monoid"))
  let src_on = proj_test_source(fn(name, _params) {
    if name == "chats" {
      Some(Json::object({ "projects": Json::boolean(true), "days": Json::array([]) }))
    } else if name == "prefs" {
      Some(Json::object({ "listGroups": Json::object({ "ws1": Json::string("project") }) }))
    } else {
      None
    }
  })
  let pq = @sfbase.pane_list_query(src_on, "ws1", "all")
  assert_eq(pq.group_by, "")
  assert_true(pq.project == Named("monoid"))
  assert_true(@sfbase.active_list_query(src_on, "ws1") == pq)
}

///|
test "R3 regressions: kept tail no-thrash, late intermediate tag push preserves desired, real Client retry sends fresh request" {
  @sfbase.reset()
  reset()
  @sf.set_words(@sfbase.fill)

  // 1. Astra P1-1: page 0 is live rev B (nextCursor="n:10"), tail "n:10" replays cached rev A (version=-2) -> NO Reset thrash, stays editable=false until live rev B arrives!
  let tail_ver : Ref[Int] = Ref(-2)
  let tail_rev : Ref[String] = Ref("rev-A")
  let tail_note : Ref[String] = Ref("old-tail")
  let tick : @signals.Signal[Int] = @signals.signal(0)
  let base = @sffixture.fixture("home")
  let src_tail : Source = {
    ..base,
    topic_read: fn(name, params) {
      tick.get() |> ignore
      guard name == "project" else { return { value: None, error: None, version: 0 } }
      let cur = text(Some(Json::object(params)), "cursor")
      if cur == "" {
        let j : Json = {
          "name": "monoid",
          "note": "new-head-",
          "refs": [],
          "infoRevision": "rev-B",
          "chatCount": 3.0,
          "nextCursor": "n:10",
        }
        { value: Some(j), error: None, version: 1 }
      } else {
        let j : Json = {
          "name": "monoid",
          "note": Json::string(tail_note.val),
          "refs": ["AFK-surf/monoid"],
          "infoRevision": Json::string(tail_rev.val),
          "chatCount": 3.0,
        }
        { value: Some(j), error: None, version: tail_ver.val }
      }
    },
  }
  let dchain = @sfbase.ProjectDetailChain::new("ws1", "monoid")
  let t = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      dchain.bind(root, src_tail)
      root.box(fn(b) {
        @sf.words_node(b, fn() { if dchain.read(src_tail).editable { "EDITABLE" } else { "READONLY" } }, fn() { proj_row_name })
        |> ignore
      })
      |> ignore
    },
    w=400.0,
    h=200.0,
    platform=0,
    scale=2.0,
  )
  t.run_for(@ui.move_most_ms)
  let gen_while_kept = dchain.generation()
  let d_kept = dchain.read(src_tail)
  assert_false(d_kept.editable)
  // Running again while tail is still kept MUST NOT reset/bump generation!
  t.run_for(@ui.move_most_ms)
  assert_eq(dchain.generation(), gen_while_kept)
  // Now live rev B arrives on tail -> unlocks editable cleanly without any reset
  tail_ver.val = 1
  tail_rev.val = "rev-B"
  tail_note.val = "new-tail"
  tick.set(1)
  t.run_for(@ui.move_most_ms)
  assert_eq(dchain.generation(), gen_while_kept)
  let d_live = dchain.read(src_tail)
  assert_true(d_live.complete)
  assert_true(d_live.editable)
  assert_eq(d_live.note, "new-head-new-tail")

  // 2. Astra P1-2: [] -> click A (200) -> click B (200) -> late intermediate push [A] -> click C => sends [A, B, C] (never drops B!)
  let sent_tags : Array[Array[String]] = []
  let src_tags = proj_test_source(
    fn(_, _) { None },
    call=fn(_name, body, done) {
      let arr = items(Some(body), "tags").map(fn(x) { match x { String(s) => s; _ => "" } })
      sent_tags.push(arr)
      done(Ok(Json::object({ "ok": Json::boolean(true) })))
    },
  )
  @sfbase.chat_toggle_tag(src_tags, "ws1/s1", 77.0, [], "A")
  @sfbase.chat_toggle_tag(src_tags, "ws1/s1", 77.0, [], "B")
  // Late intermediate push [A] arrives while desired is [A, B]
  @sfbase.classify_reconcile_tags("ws1/s1", 77.0, ["A"])
  // User clicks C while live view only shows [A]
  @sfbase.chat_toggle_tag(src_tags, "ws1/s1", 77.0, ["A"], "C")
  assert_eq(sent_tags.length(), 3)
  assert_eq(sent_tags[0], ["A"])
  assert_eq(sent_tags[1], ["A", "B"])
  assert_eq(sent_tags[2], ["A", "B", "C"])

  // 3. Astra P2-1: real Client::refresh_topic sends a new outbound subscribe request on retry after error and recovers!
  let outbound : Array[String] = []
  let client = @core.Client::new(fn(msg) { outbound.push(msg) })
  let sub = client.subscribe("projects", params={ "scope": Json::string("ws1") })
  assert_eq(outbound.length(), 1)
  // Core replies with an error on sub.id
  client.receive(
    Json::object({
      "id": Json::number(sub.id.to_double()),
      "error": Json::object({ "message": Json::string("temporary outage") }),
    }).stringify(),
  )
  |> ignore
  assert_true(sub.error is Some(_))
  let src_retry : Source = {
    ..base,
    refresh: fn(name, params) { client.refresh_topic(name, params~) },
  }
  let pchain = @sfbase.ProjectListChain::new("ws1")
  pchain.retry(src_retry)
  // refresh_topic sent unsubscribe + a brand-new subscribe request and cleared sub.error!
  assert_true(outbound.length() >= 3)
  assert_true(sub.error is None)
  // New answer arrives on the refreshed sub.id -> recovers cleanly
  client.receive(
    Json::object({
      "id": Json::number(sub.id.to_double()),
      "value": Json::object({
        "items": Json::array([Json::object({ "name": Json::string("monoid"), "chatCount": Json::number(4.0) })]),
        "total": Json::number(1.0),
      }),
    }).stringify(),
  )
  |> ignore
  assert_true(sub.value is Some(_))
  assert_true(sub.error is None)
}

///|
test "R4 regressions: live A->B tail no-reset, external member tag update + late echo, partial overwrite with half-loaded C preserves Y" {
  @sfbase.reset()
  reset()
  @sf.set_words(@sfbase.fill)

  // 1. Astra P1-3: complete 2-page live rev A (both version >= 0) -> page 0 updates to live rev B (same nextCursor)
  //    while tail is still live rev A -> ZERO Reset / ZERO generation bump, stays editable=false -> tail rev B arrives -> unlocks once!
  let head_rev : Ref[String] = Ref("rev-A")
  let head_note : Ref[String] = Ref("head-A-")
  let tail_rev : Ref[String] = Ref("rev-A")
  let tail_note : Ref[String] = Ref("tail-A")
  let tick : @signals.Signal[Int] = @signals.signal(0)
  let base = @sffixture.fixture("home")
  let src_ab : Source = {
    ..base,
    topic_read: fn(name, params) {
      tick.get() |> ignore
      guard name == "project" else { return { value: None, error: None, version: 0 } }
      let cur = text(Some(Json::object(params)), "cursor")
      if cur == "" {
        let j : Json = {
          "name": "monoid",
          "note": Json::string(head_note.val),
          "refs": [],
          "infoRevision": Json::string(head_rev.val),
          "chatCount": 4.0,
          "nextCursor": "n:10",
        }
        { value: Some(j), error: None, version: 2 }
      } else {
        let j : Json = {
          "name": "monoid",
          "note": Json::string(tail_note.val),
          "refs": ["X"],
          "infoRevision": Json::string(tail_rev.val),
          "chatCount": 4.0,
        }
        { value: Some(j), error: None, version: 2 }
      }
    },
  }
  let ab_chain = @sfbase.ProjectDetailChain::new("ws1", "monoid")
  let t_ab = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      ab_chain.bind(root, src_ab)
      root.box(fn(b) {
        @sf.words_node(b, fn() { if ab_chain.read(src_ab).editable { "EDITABLE" } else { "READONLY" } }, fn() { proj_row_name })
        |> ignore
      })
      |> ignore
    },
    w=400.0,
    h=200.0,
    platform=0,
    scale=2.0,
  )
  t_ab.run_for(@ui.move_most_ms)
  assert_true(ab_chain.read(src_ab).editable)
  assert_eq(ab_chain.read(src_ab).note, "head-A-tail-A")
  let gen_a = ab_chain.generation()
  // Deliver rev B page 0 (same nextCursor "n:10") while tail is still live rev A (version=2)
  head_rev.val = "rev-B"
  head_note.val = "head-B-"
  tick.set(1)
  t_ab.run_for(@ui.move_most_ms)
  assert_eq(ab_chain.generation(), gen_a)
  assert_false(ab_chain.read(src_ab).complete)
  assert_false(ab_chain.read(src_ab).editable)
  // Deliver rev B tail -> unlocks cleanly with zero reset!
  tail_rev.val = "rev-B"
  tail_note.val = "tail-B"
  tick.set(2)
  t_ab.run_for(@ui.move_most_ms)
  assert_eq(ab_chain.generation(), gen_a)
  assert_true(ab_chain.read(src_ab).editable)
  assert_eq(ab_chain.read(src_ab).note, "head-B-tail-B")

  // 2. Astra P1-2: both (a) late intermediate echo [A] preserves [A, B] -> +C sends [A, B, C],
  //    AND (b) external member adds B after our +A (live view is [A, B]) -> +C sends [A, B, C]!
  let sent_tags : Array[Array[String]] = []
  let src_tags = proj_test_source(
    fn(_, _) { None },
    call=fn(_name, body, done) {
      let arr = items(Some(body), "tags").map(fn(x) { match x { String(s) => s; _ => "" } })
      sent_tags.push(arr)
      done(Ok(Json::object({ "ok": Json::boolean(true) })))
    },
  )
  // (a) Late echo [A] after +A, +B
  @sfbase.chat_toggle_tag(src_tags, "ws1/s1", 88.0, [], "A")
  @sfbase.chat_toggle_tag(src_tags, "ws1/s1", 88.0, [], "B")
  @sfbase.classify_reconcile_tags("ws1/s1", 88.0, ["A"])
  @sfbase.chat_toggle_tag(src_tags, "ws1/s1", 88.0, ["A"], "C")
  assert_eq(sent_tags[2], ["A", "B", "C"])
  // (b) External member adds B after our +A (sent_sets only has [["A"]]; live view arrives with ["A", "B"])
  sent_tags.clear()
  @sfbase.chat_toggle_tag(src_tags, "ws1/s1", 89.0, [], "A")
  @sfbase.classify_reconcile_tags("ws1/s1", 89.0, ["A", "B"])
  @sfbase.chat_toggle_tag(src_tags, "ws1/s1", 89.0, ["A", "B"], "C")
  assert_eq(sent_tags.length(), 2)
  assert_eq(sent_tags[0], ["A"])
  assert_eq(sent_tags[1], ["A", "B", "C"])
  // (c) Astra R5 P1: add A -> leave chat -> another member deletes A -> reopen chat (live []) -> click C -> sends ["C"]!
  sent_tags.clear()
  let v1 = @sfbase.classify_enter_chat("ws1/s1", 90.0)
  @sfbase.chat_toggle_tag(src_tags, "ws1/s1", 90.0, [], "A")
  assert_eq(sent_tags[0], ["A"])
  @sfbase.classify_leave_chat("ws1/s1", 90.0, v1)
  // Another member deletes A while away; chat reopens with fresh live []
  let v2 = @sfbase.classify_enter_chat("ws1/s1", 90.0)
  @sfbase.classify_reconcile_tags("ws1/s1", 90.0, [])
  @sfbase.chat_toggle_tag(src_tags, "ws1/s1", 90.0, [], "C")
  assert_eq(sent_tags.length(), 2)
  assert_eq(sent_tags[1], ["C"])
  @sfbase.classify_leave_chat("ws1/s1", 90.0, v2)
  // (d) Even when +A is still in-flight while leaving, finishes 200 away, and reopen gets fresh live [] -> +C sends ["C"]!
  sent_tags.clear()
  let inflight_cb : Ref[((Result[Json, Json]) -> Unit)?] = Ref(None)
  let src_tags_async = proj_test_source(
    fn(_, _) { None },
    call=fn(_name, body, done) {
      let arr = items(Some(body), "tags").map(fn(x) { match x { String(s) => s; _ => "" } })
      sent_tags.push(arr)
      inflight_cb.val = Some(done)
    },
  )
  let v3 = @sfbase.classify_enter_chat("ws1/s1", 91.0)
  @sfbase.chat_toggle_tag(src_tags_async, "ws1/s1", 91.0, [], "A")
  @sfbase.classify_leave_chat("ws1/s1", 91.0, v3)
  match inflight_cb.val {
    Some(cb) => cb(Ok(Json::object({ "ok": Json::boolean(true) })))
    None => ()
  }
  let v4 = @sfbase.classify_enter_chat("ws1/s1", 91.0)
  @sfbase.classify_reconcile_tags("ws1/s1", 91.0, [])
  @sfbase.chat_toggle_tag(src_tags_async, "ws1/s1", 91.0, [], "C")
  assert_eq(sent_tags.length(), 2)
  assert_eq(sent_tags[1], ["C"])
  @sfbase.classify_leave_chat("ws1/s1", 91.0, v4)
  // (e) Astra R6 P1: +A in-flight -> leave -> reopen with live ["A"] while A still in-flight -> click B ->
  //     A returns 200 -> B returns 200 -> before B's view push arrives, click C -> sends ["A", "B", "C"]!
  sent_tags.clear()
  let async_cbs : Array[(Result[Json, Json]) -> Unit] = []
  let src_tags_seq = proj_test_source(
    fn(_, _) { None },
    call=fn(_name, body, done) {
      let arr = items(Some(body), "tags").map(fn(x) { match x { String(s) => s; _ => "" } })
      sent_tags.push(arr)
      async_cbs.push(done)
    },
  )
  let v5 = @sfbase.classify_enter_chat("ws1/s1", 92.0)
  @sfbase.chat_toggle_tag(src_tags_seq, "ws1/s1", 92.0, [], "A")
  @sfbase.classify_leave_chat("ws1/s1", 92.0, v5)
  let v6 = @sfbase.classify_enter_chat("ws1/s1", 92.0)
  // Chat reopened with live ["A"] while A's RPC is still in-flight; user clicks B
  @sfbase.chat_toggle_tag(src_tags_seq, "ws1/s1", 92.0, ["A"], "B")
  // A returns 200 (drains B), then B returns 200
  async_cbs[0](Ok(Json::object({ "ok": Json::boolean(true) })))
  async_cbs[1](Ok(Json::object({ "ok": Json::boolean(true) })))
  // Before B's view push arrives (live is still ["A"]), user clicks C
  @sfbase.chat_toggle_tag(src_tags_seq, "ws1/s1", 92.0, ["A"], "C")
  assert_eq(sent_tags.length(), 3)
  assert_eq(sent_tags[0], ["A"])
  assert_eq(sent_tags[1], ["A", "B"])
  assert_eq(sent_tags[2], ["A", "B", "C"])
  @sfbase.classify_leave_chat("ws1/s1", 92.0, v6)

  // 3. Astra P1-1: local refs [X], remote adds Y -> overwrite note returns Ok while rev C is half-loaded ->
  //    complete live rev C ([X, Y]) arrives -> user adds Z and saves -> sends [X, Y, Z]!
  let p_tick : @signals.Signal[Int] = @signals.signal(0)
  let p_head_rev : Ref[String] = Ref("rev-1")
  let p_head_note : Ref[String] = Ref("note-1")
  let p_tail_rev : Ref[String] = Ref("rev-1")
  let p_tail_refs : Ref[Array[Json]] = Ref([Json::string("X")])
  let p_calls : Array[Json] = []
  let t_det = setting_tester(
    Project("monoid"),
    900.0,
    over=fn(s) {
      {
        ..s,
        topic_read: fn(name, params) {
          let v = p_tick.get() + 1
          if name == "chats" {
            let j : Json = { "projects": true, "projectsWritable": true, "days": [] }
            { value: Some(j), error: None, version: v }
          } else if name == "project" {
            let cur = text(Some(Json::object(params)), "cursor")
            if cur == "" {
              let j : Json = {
                "name": "monoid",
                "note": Json::string(p_head_note.val),
                "refs": [],
                "infoRevision": Json::string(p_head_rev.val),
                "chatCount": 2.0,
                "nextCursor": "r:0",
              }
              { value: Some(j), error: None, version: v }
            } else {
              let j : Json = {
                "name": "monoid",
                "refs": Json::array(p_tail_refs.val),
                "infoRevision": Json::string(p_tail_rev.val),
                "chatCount": 2.0,
              }
              { value: Some(j), error: None, version: v }
            }
          } else {
            (s.topic_read)(name, params)
          }
        },
        call: fn(name, body, done) {
          if name == "project.updateInfo" {
            p_calls.push(body)
            // Simulate rev C page 0 arriving BEFORE tail page C when the overwrite callback returns!
            if p_calls.length() == 1 {
              p_head_rev.val = "rev-C"
              p_head_note.val = "note-1!"
              p_tick.set(p_tick.untracked() + 1)
            }
            done(Ok(Json::object({ "ok": Json::boolean(true) })))
          } else {
            (s.call)(name, body, done)
          }
        },
      }
    },
    ready=fn() { @sffixture.fx_projects_on.val = true },
  )
  t_det.run_for(@ui.move_most_ms)
  // Edit note locally ("note-1" -> "note-1!")
  match t_det.find("记录背景、范围、规范或目标…") {
    Some(p) => {
      t_det.tap(p.0, p.1)
      t_det.type_text("!")
      t_det.run_for(@ui.move_most_ms)
    }
    None => fail("expected note field, got: " + t_det.words().map(fn(w) { w.0 }).join(" | "))
  }
  // Remote adds ref Y (rev-2) -> conflict bar appears!
  p_head_rev.val = "rev-2"
  p_tail_rev.val = "rev-2"
  p_tail_refs.val = [Json::string("X"), Json::string("Y")]
  p_tick.set(p_tick.untracked() + 1)
  t_det.run_for(@ui.move_most_ms)
  // Click "覆盖保存" -> sends ONLY note, callback runs while rev-C is half-loaded (tail still rev-2)
  match t_det.find("覆盖保存") {
    Some(p) => {
      t_det.tap(p.0, p.1)
      t_det.run_for(@ui.move_most_ms)
    }
    None => fail("expected overwrite button")
  }
  assert_eq(p_calls.length(), 1)
  assert_true(field(Some(p_calls[0]), "refs") is None)
  // Now tail page of rev-C arrives with [X, Y] -> reacts syncs base_rev=rev-C and refs_draft=[X, Y]!
  p_tail_rev.val = "rev-C"
  p_tick.set(p_tick.untracked() + 1)
  t_det.run_for(@ui.move_most_ms)
  assert_true(t_det.find("Y") is Some(_))
  // User adds Z and clicks normal 保存 -> must send [X, Y, Z] (preserving Y)!
  match t_det.find("如文档链接、仓库或目录路径") {
    Some(p) => {
      t_det.tap(p.0, p.1)
      t_det.type_text("Z")
      t_det.run_for(@ui.move_most_ms)
    }
    None => fail("expected ref input")
  }
  match t_det.find("添加") {
    Some(p) => {
      t_det.tap(p.0, p.1)
      t_det.run_for(@ui.move_most_ms)
    }
    None => fail("expected add button")
  }
  match t_det.find("保存") {
    Some(p) => {
      t_det.tap(p.0, p.1)
      t_det.run_for(@ui.move_most_ms)
    }
    None => fail("expected save button")
  }
  assert_eq(p_calls.length(), 2)
  let saved_refs = items(Some(p_calls[1]), "refs").map(fn(x) { match x { String(s) => s; _ => "" } })
  assert_eq(saved_refs, ["X", "Y", "Z"])
}

///|
test "collapsed project keeps active chat visible and detail rename uses native top dialog" {
  @sfbase.reset()
  reset()
  @sf.set_words(@sfbase.fill)

  // 1. Project detail top 项目名称 row opens native rename dialog (no dangling bottom inline form)
  let td = setting_tester(
    Project("monoid"),
    390.0,
    platform=2,
    ready=fn() { @sffixture.fx_projects_on.val = true },
  )
  td.run_for(@ui.move_most_ms)
  assert_true(td.find("项目名称") is Some(_))
  assert_true(td.find("重命名") is None)
  let name_row = td.find("项目名称").unwrap()
  td.tap(name_row.0, name_row.1)
  td.run_for(@ui.move_most_ms)
  assert_true(td.find("重命名项目") is Some(_))
  assert_eq(td.audit(), [])

  // 2. Collapsed project keeps active chat visible while hiding non-active sibling chats
  @sfbase.reset()
  reset()
  @sffixture.fixture_reset()
  @sf.set_words(@sfbase.fill)
  @sffixture.fx_projects_on.val = true
  @sffixture.fx_set_list_group("ws1", "project")
  let src_grp = @sffixture.fixture("projects-grouped")
  app.nav.push(Chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }))
  @sfbase.set_group_collapsed(src_grp, "ws1", "project:monoid", true)
  let t_side = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      let frame : ListsNodeFrame = {
        top: fn() { 0.0 },
        under: fn() { 0.0 },
        foot: fn() { 0.0 },
        ground: fn() { @sf.theme().p.bg },
        before: fn(_, _) { [] },
        after: fn(_, _) { [] },
        others: [],
        shown: fn() { 0 },
        at: Side,
        watched: fn() { true },
        section_rows: fn() { (2, 2) },
        section_chrome_suppress: fn() { false },
      }
      root.box(fn(col) {
        col.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        chats_lists_node(col, src_grp, fn() { Some(rig_workspace) }, frame, tips, fn() { 0 })
      })
      |> ignore
      @sf.presented_nodes(root)
    },
    w=280.0,
    h=700.0,
    platform=0,
    scale=2.0,
  )
  t_side.run_for(@ui.move_most_ms)
  assert_true(t_side.find("monoid") is Some(_))
  assert_true(t_side.find("整理发布清单") is Some(_), msg="active chat must remain visible when its project group is collapsed")
  assert_true(t_side.find("和 Ana 一起看新版的引导页") is None, msg="non-active sibling chat must stay hidden when collapsed")
  assert_false(listed.val.iter().any(fn(it) { it.title == "和 Ana 一起看新版的引导页" }), msg="listed.val must omit hidden siblings when collapsed")
  // Expanding and re-collapsing (pure collapse toggle without revision/open_chat change) must refresh `listed.val`!
  @sfbase.set_group_collapsed(src_grp, "ws1", "project:monoid", false)
  t_side.run_for(@ui.move_most_ms)
  assert_true(listed.val.iter().any(fn(it) { it.title == "和 Ana 一起看新版的引导页" }), msg="expanding group must include siblings in listed.val")
  @sfbase.set_group_collapsed(src_grp, "ws1", "project:monoid", true)
  t_side.run_for(@ui.move_most_ms)
  assert_false(listed.val.iter().any(fn(it) { it.title == "和 Ana 一起看新版的引导页" }), msg="re-collapsing group must immediately drop hidden siblings from listed.val")
  assert_eq(t_side.audit(), [])
  // 3. Another chat opened in its place (as a row pressed on 中屏/大屏 replaces it, no page sliding) lets the kept row
  // go as a row gone does (its line closing over a motion), not at once
  app.nav.replace(Chat({ station: "ws1/st1", session: "s-other", title: "别的对话", station_name: "Willow" }))
  t_side.run_for(@ui.frame_period_default)
  assert_true(t_side.find("整理发布清单") is Some(_), msg="the kept row must still be making its way out a frame after another chat opens")
  t_side.run_for(@ui.move_most_ms)
  assert_true(t_side.find("整理发布清单") is None, msg="the kept row is gone once its motion is over")
  @sffixture.fx_projects_reset()
}

///|
test "project detail blocks rename while unsaved draft is dirty or info save is in flight" {
  @sfbase.reset()
  reset()
  @sf.set_words(@sfbase.fill)
  let held_save : Ref[((Result[Json, Json]) -> Unit)?] = Ref(None)
  let rename_calls : Ref[Int] = Ref(0)
  let detail_json : Json = {
    "name": "monoid",
    "note": "Initial note",
    "refs": ["https://github.com/AFK-surf/monoid"],
    "updatedAt": 1000.0,
    "infoRevision": "rev-1",
    "chatCount": 3.0,
  }
  let t = setting_tester(
    Project("monoid"),
    390.0,
    platform=2,
    over=fn(base_src) {
      {
        ..base_src,
        topic_read: fn(name, params) {
          if name == "project" {
            { value: Some(detail_json), error: None, version: 1 }
          } else if name == "chats" {
            { value: Some({ "projects": true, "projectsWritable": true, "days": [] }), error: None, version: 1 }
          } else {
            (base_src.topic_read)(name, params)
          }
        },
        call: fn(name, body, done) {
          if name == "project.updateInfo" {
            held_save.val = Some(done)
          } else if name == "project.rename" {
            rename_calls.val += 1
            done(Ok({ "ok": true }))
          } else {
            (base_src.call)(name, body, done)
          }
        },
      }
    },
    ready=fn() { @sffixture.fx_projects_on.val = true },
  )
  t.run_for(@ui.move_most_ms)
  // 1. Add a ref to make draft dirty -> tapping 项目名称 must toast instead of opening rename dialog
  let ref_in = t.find("如文档链接、仓库或目录路径").unwrap()
  t.tap(ref_in.0, ref_in.1)
  t.type_text("https://example.com/new")
  t.run_for(@ui.move_most_ms)
  let add_btn = t.find("添加").unwrap()
  t.tap(add_btn.0, add_btn.1)
  t.run_for(@ui.move_most_ms)
  let name_row = t.find("项目名称").unwrap()
  t.tap(name_row.0, name_row.1)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("重命名项目") is None, msg="dirty draft must not open rename dialog")
  assert_true(@sfbase.toast_words().contains("请先保存当前修改"), msg="dirty draft must toast save-first warning")
  // 2. Tap 保存 -> while save is in flight (`saving == true`), tapping 项目名称 must NOT open rename dialog
  let save_btn = t.find("保存").unwrap()
  t.tap(save_btn.0, save_btn.1)
  t.run_for(@ui.move_most_ms)
  assert_true(held_save.val is Some(_), msg="save request must be in flight")
  t.tap(name_row.0, name_row.1)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("重命名项目") is None, msg="in-flight save must block rename dialog")
  assert_eq(rename_calls.val, 0)
  // 3. Complete save -> now 项目名称 opens rename dialog cleanly
  match held_save.val {
    Some(done) => done(Ok({ "ok": true }))
    None => ()
  }
  t.run_for(@ui.move_most_ms)
  t.tap(name_row.0, name_row.1)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("重命名项目") is Some(_))
}

///|
test "PR2 W1: groups_collapsed_default XOR exception, prefs.groupCollapsed persistence, restart restore, rollback, and hooks" {
  @sfbase.projects_reset()
  let ws = "ws-w1"
  let saved : Map[String, String] = Map([])
  let prefs_tick : @signals.Signal[Int] = @signals.signal(0)
  let fail_next : Ref[Bool] = Ref(false)
  let sent : Array[Json] = []
  let src = proj_test_source(
    fn(name, _) {
      prefs_tick.get() |> ignore
      if name == "prefs" {
        let gc : Map[String, Json] = Map([])
        for k, v in saved {
          gc[k] = Json::string(v)
        }
        Some(Json::object({ "groupCollapsed": Json::object(gc) }))
      } else {
        None
      }
    },
    call=fn(name, body, done) {
      if name == "prefs.set" {
        sent.push(body)
        if fail_next.val {
          fail_next.val = false
          done(Err(Json::object({ "message": Json::string("disk full") })))
          return
        }
        match @sfbase.field(Some(body), "groupCollapsed") {
          Some(Object(m)) =>
            for k, v in m {
              match v {
                String(s) if s != "" => saved[k] = s
                Null | String("") => saved.remove(k)
                _ => ()
              }
            }
          _ => ()
        }
        prefs_tick.set(prefs_tick.untracked() + 1)
        done(Ok(Json::object({ "ok": Json::boolean(true) })))
      } else {
        done(Ok(Json::object({})))
      }
    },
  )
  assert_false(@sfbase.group_collapsed(src, ws, "project:monoid"))
  assert_false(@sfbase.all_groups_collapsed(src, ws, ["project:monoid", "project:farview"]))

  // Collapse all -> existing AND future (near_foot) groups are collapsed, and persisted to prefs.groupCollapsed!
  @sfbase.set_all_groups_collapsed(src, ws, true)
  assert_true(@sfbase.group_collapsed(src, ws, "project:monoid"))
  assert_true(@sfbase.group_collapsed(src, ws, "project:farview"))
  assert_true(@sfbase.group_collapsed(src, ws, "project:future_loaded"))
  assert_true(@sfbase.all_groups_collapsed(src, ws, ["project:monoid", "project:farview", "project:future_loaded"]))
  assert_eq(saved.get(ws), Some("{\"d\":true,\"x\":[]}"))

  // Toggling one group creates a single exception without affecting others and persists {"d":true,"x":["project:monoid"]}
  @sfbase.toggle_group_collapsed(src, ws, "project:monoid")
  assert_false(@sfbase.group_collapsed(src, ws, "project:monoid"))
  assert_true(@sfbase.group_collapsed(src, ws, "project:farview"))
  assert_true(@sfbase.group_collapsed(src, ws, "project:future_loaded"))
  assert_false(@sfbase.all_groups_collapsed(src, ws, ["project:monoid", "project:farview"]))
  assert_eq(saved.get(ws), Some("{\"d\":true,\"x\":[\"project:monoid\"]}"))

  // Cold-start restart simulation: clear all in-memory overrides -> state is immediately restored from prefs.groupCollapsed!
  @sfbase.projects_reset()
  assert_false(@sfbase.group_collapsed(src, ws, "project:monoid"))
  assert_true(@sfbase.group_collapsed(src, ws, "project:farview"))
  assert_true(@sfbase.group_collapsed(src, ws, "project:future_loaded"))

  // Failed prefs.set rolls back optimistic override cleanly
  fail_next.val = true
  @sfbase.toggle_group_collapsed(src, ws, "project:monoid")
  assert_false(@sfbase.group_collapsed(src, ws, "project:monoid"), msg="failed prefs.set must roll back collapse state")

  // Setting back to collapsed removes the exception
  @sfbase.set_group_collapsed(src, ws, "project:monoid", true)
  assert_true(@sfbase.all_groups_collapsed(src, ws, ["project:monoid", "project:farview"]))
  assert_eq(saved.get(ws), Some("{\"d\":true,\"x\":[]}"))

  // Expand all clears default and exceptions and deletes workspace entry from prefs (null patch)
  @sfbase.set_all_groups_collapsed(src, ws, false)
  assert_false(@sfbase.group_collapsed(src, ws, "project:monoid"))
  assert_false(@sfbase.group_collapsed(src, ws, "project:future_loaded"))
  assert_false(@sfbase.all_groups_collapsed(src, ws, ["project:monoid", "project:farview"]))
  assert_eq(saved.get(ws), None)

  // Cross-module grouped_collapse_hooks with ownership token isolation (Astra Minor 1)
  assert_false(@sfbase.has_grouped_collapse_hook(ws))
  let calls : Array[Bool] = []
  let tok1 = @sfbase.register_grouped_collapse_hook(
    ws,
    fn() { @sfbase.all_groups_collapsed(src, ws, ["project:monoid"]) },
    fn(col) {
      calls.push(col)
      @sfbase.set_all_groups_collapsed(src, ws, col)
    },
  )
  assert_true(@sfbase.has_grouped_collapse_hook(ws))
  assert_false(@sfbase.grouped_collapse_all_collapsed(src, ws))
  @sfbase.trigger_all_groups_collapse(src, ws, true)
  assert_eq(calls, [true])
  assert_true(@sfbase.grouped_collapse_all_collapsed(src, ws))
  // Newer lane registers tok2; older lane's teardown with tok1 must NOT remove tok2!
  let calls2 : Array[Bool] = []
  let tok2 = @sfbase.register_grouped_collapse_hook(
    ws,
    fn() { false },
    fn(col) { calls2.push(col) },
  )
  @sfbase.unregister_grouped_collapse_hook(ws, tok1)
  assert_true(@sfbase.has_grouped_collapse_hook(ws), msg="stale lane unregister must not wipe newer lane hook")
  @sfbase.trigger_all_groups_collapse(src, ws, true)
  assert_eq(calls2, [true])
  @sfbase.unregister_grouped_collapse_hook(ws, tok2)
  assert_false(@sfbase.has_grouped_collapse_hook(ws))

  // Clearing saved prefs + projects_reset restores default expanded state
  saved.clear()
  prefs_tick.set(prefs_tick.untracked() + 1)
  @sfbase.projects_reset()
  assert_false(@sfbase.group_collapsed(src, ws, "project:monoid"))
  assert_false(@sfbase.has_grouped_collapse_hook(ws))
}

///|
test "PR2 W1: grouped chat list curtain collapse/expand, disclosure header anchor, and collapse-all hook" {
  @sfbase.reset()
  reset()
  @sf.set_words(@sfbase.fill)
  let ws = "ws-curtain"
  let tick : @signals.Signal[Int] = @signals.signal(0)
  let extra_chat : Ref[Bool] = Ref(false)
  let grouped_json = fn() -> Json {
    let monoid_items : Array[Json] = [
      { "id": "c-m1", "session": "c-m1", "title": "Monoid Chat 1", "station": "ws/s1", "stationName": "S1", "project": "monoid" },
      { "id": "c-m2", "session": "c-m2", "title": "Monoid Chat 2", "station": "ws/s1", "stationName": "S1", "project": "monoid" },
    ]
    if extra_chat.val {
      monoid_items.push({ "id": "c-m3", "session": "c-m3", "title": "Monoid Chat 3", "station": "ws/s1", "stationName": "S1", "project": "monoid" })
    }
    {
      "stations": [{ "station": "ws/s1", "state": "online" }],
      "leading": "agents",
      "projects": true,
      "projectsWritable": true,
      "days": [],
      "groups": [
        {
          "key": "project:monoid",
          "kind": "project",
          "label": "monoid",
          "project": "monoid",
          "chatCount": Json::number(monoid_items.length().to_double()),
          "runningCount": 0.0,
          "alertCount": 0.0,
          "askingCount": 0.0,
          "unreadCount": 0.0,
          "dayBreaks": [
            { "at": 0.0, "label": "今天" },
            { "at": 1.0, "label": "昨天" },
          ],
          "items": Json::array(monoid_items),
        },
        {
          "key": "project:farview",
          "kind": "project",
          "label": "farview",
          "project": "farview",
          "chatCount": 2.0,
          "runningCount": 0.0,
          "alertCount": 0.0,
          "askingCount": 0.0,
          "unreadCount": 0.0,
          "items": [
            { "id": "c-f1", "session": "c-f1", "title": "Farview Chat 1", "station": "ws/s1", "stationName": "S1", "project": "farview" },
            { "id": "c-f2", "session": "c-f2", "title": "Farview Chat 2", "station": "ws/s1", "stationName": "S1", "project": "farview" },
          ],
        },
      ],
    }
  }
  let src = proj_test_source(fn(name, params) {
    tick.get() |> ignore
    if name == "prefs" {
      Some({ "listGroups": { "ws-curtain": "project" } })
    } else if name == "chats" {
      if params.get("groupBy") == Some(Json::string("project")) {
        Some(grouped_json())
      } else {
        Some({ "projects": true, "projectsWritable": true, "days": [] })
      }
    } else {
      None
    }
  })
  let ws_obj : Workspace = { id: ws, name: "Curtain WS", emoji: "", icon: "", email: "" }
  let t = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let tips = @sf.TipLayer::new(fn() { None })
      let frame : ListsNodeFrame = {
        top: fn() { 0.0 },
        under: fn() { 0.0 },
        foot: fn() { 0.0 },
        ground: fn() { @sf.theme().p.bg },
        before: fn(_, _) { [] },
        after: fn(_, _) { [] },
        others: [],
        shown: fn() { 0 },
        at: Side,
        watched: fn() { true },
        section_rows: fn() { (2, 2) },
        section_chrome_suppress: fn() { false },
      }
      root.box(fn(o) {
        o.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        chats_lists_node(o, src, fn() { Some(ws_obj) }, frame, tips, fn() { 0 })
      })
      |> ignore
    },
    w=320.0,
    h=500.0,
    platform=0,
    scale=2.0,
  )
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.has_grouped_collapse_hook(ws), msg="grouped pane must register collapse-all hook")
  assert_true(t.find("Monoid Chat 1") is Some(_))
  assert_true(t.find("今天") is Some(_), msg="expanded project group must show time sub-headings")
  assert_true(t.find("昨天") is Some(_))
  assert_true(t.find("Farview Chat 1") is Some(_))
  let warns0 = t.audit()
  assert_eq(warns0.length(), 0, msg="initial grouped list audit failed: " + warns0.join("; "))

  // 1. Tap monoid group header to collapse via CurtainPlan
  let mh = t.find("monoid").unwrap()
  t.tap(mh.0, mh.1)
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.group_collapsed(src, ws, "project:monoid"))
  assert_true(t.find("Monoid Chat 1") is None, msg="collapsed group rows must be hidden")
  assert_true(t.find("今天") is None, msg="collapsed group time sub-headings must be hidden")
  assert_true(t.find("昨天") is None)
  assert_true(t.find("Farview Chat 1") is Some(_), msg="other group rows stay visible")
  let mh_after = t.find("monoid").unwrap()
  assert_true((mh_after.1 - mh.1).abs() <= 1.0, msg="clicked group header must stay anchored")

  // 2. Background new chat arrives in collapsed group: must stay collapsed, no crash or stale curtain plan
  extra_chat.val = true
  tick.set(1)
  t.run_for(@ui.move_most_ms)
  assert_true(t.find("Monoid Chat 3") is None)

  // 3. Re-expand monoid group header -> all 3 rows appear cleanly
  let mh2 = t.find("monoid").unwrap()
  t.tap(mh2.0, mh2.1)
  t.run_for(@ui.move_most_ms)
  assert_false(@sfbase.group_collapsed(src, ws, "project:monoid"))
  assert_true(t.find("Monoid Chat 1") is Some(_))
  assert_true(t.find("Monoid Chat 3") is Some(_))

  // 4. Trigger collapse-all and expand-all via sfbase hook
  @sfbase.trigger_all_groups_collapse(src, ws, true)
  t.run_for(@ui.move_most_ms)
  assert_true(@sfbase.grouped_collapse_all_collapsed(src, ws))
  assert_true(t.find("Monoid Chat 1") is None)
  assert_true(t.find("Farview Chat 1") is None)
  @sfbase.trigger_all_groups_collapse(src, ws, false)
  t.run_for(@ui.move_most_ms)
  assert_false(@sfbase.grouped_collapse_all_collapsed(src, ws))
  assert_true(t.find("Monoid Chat 1") is Some(_))
  assert_true(t.find("Farview Chat 1") is Some(_))
  let warns_end = t.audit()
  assert_eq(warns_end.length(), 0, msg="post-curtain grouped list audit failed: " + warns_end.join("; "))
  @sffixture.fx_projects_reset()
  @sfbase.reset()
  reset()
}

///|
test "PR2 regressions: serial collapse persistence rollback, UTF-8 16KiB trim, and held_order unique sub-headings" {
  @sfbase.projects_reset()
  @sf.set_words(@sfbase.fill)
  let ws = "ws-collapse-race"
  let live_gc : Ref[Json?] = Ref(None)
  let prefs_tick : @signals.Signal[Int] = @signals.signal(0)
  let pending : Array[(Json, (Result[Json, Json]) -> Unit)] = []
  let src : Source = {
    ..@sffixture.fixture("home"),
    topic_read: fn(name, params) {
      if name == "prefs" {
        prefs_tick.get() |> ignore
        let gc = match live_gc.val {
          Some(v) => Json::object(Map::from_array([(ws, v)]))
          None => Json::object({})
        }
        { value: Some({ "groupCollapsed": gc }), error: None, version: prefs_tick.untracked() }
      } else {
        (@sffixture.fixture("home").topic_read)(name, params)
      }
    },
    call: fn(name, body, done) {
      if name == "prefs.set" {
        pending.push((body, done))
      } else {
        done(Ok({}))
      }
    },
  }

  // Case 1 (Astra M2): A and B both fail -> UI must return to authoritative live prefs (no stuck uncommitted override).
  @sfbase.toggle_group_collapsed(src, ws, "project:a")
  @sfbase.toggle_group_collapsed(src, ws, "project:b")
  assert_eq(pending.length(), 1, msg="serial persistence must keep at most 1 RPC in flight per workspace")
  assert_true(@sfbase.group_collapsed(src, ws, "project:a"))
  assert_true(@sfbase.group_collapsed(src, ws, "project:b"))
  let (_, done_a) = pending.remove(0)
  done_a(Err({ "message": "net-fail-a" }))
  // Queued latest intent (a+b) is now sent
  assert_eq(pending.length(), 1)
  let (_, done_b) = pending.remove(0)
  done_b(Err({ "message": "net-fail-b" }))
  assert_false(@sfbase.group_collapsed(src, ws, "project:a"), msg="both failing must roll back cleanly to live")
  assert_false(@sfbase.group_collapsed(src, ws, "project:b"))

  // Case 2 (Astra M2): A succeeds, then B fails -> UI rolls back to confirmed A and matches authoritative prefs.
  @sfbase.toggle_group_collapsed(src, ws, "project:a")
  @sfbase.toggle_group_collapsed(src, ws, "project:b")
  let (body_ok, done_ok) = pending.remove(0)
  live_gc.val = @sfbase.field(@sfbase.field(Some(body_ok), "groupCollapsed"), ws)
  prefs_tick.set(prefs_tick.untracked() + 1)
  done_ok(Ok({}))
  assert_eq(pending.length(), 1)
  let (_, done_fail) = pending.remove(0)
  done_fail(Err({ "message": "net-fail-b2" }))
  assert_true(@sfbase.group_collapsed(src, ws, "project:a"), msg="confirmed A must survive B failure")
  assert_false(@sfbase.group_collapsed(src, ws, "project:b"), msg="failed B must roll back")

  // Case 3 (Astra M4): Chinese project keys exceeding 16 KiB UTF-8 must be trimmed so serialized UTF-8 bytes <= 16384.
  @sfbase.projects_reset()
  live_gc.val = None
  prefs_tick.set(prefs_tick.untracked() + 1)
  pending.clear()
  let mut last_sent_bytes = 0
  let src_cjk : Source = {
    ..src,
    call: fn(name, body, done) {
      if name == "prefs.set" {
        match @sfbase.field(@sfbase.field(Some(body), "groupCollapsed"), ws) {
          Some(String(s)) => {
            let mut b = 0
            for c in s {
              let cp = c.to_int()
              b += if cp <= 0x7F { 1 } else if cp <= 0x7FF { 2 } else if cp <= 0xFFFF { 3 } else { 4 }
            }
            last_sent_bytes = b
            live_gc.val = Some(Json::string(s))
            prefs_tick.set(prefs_tick.untracked() + 1)
          }
          _ => ()
        }
      }
      done(Ok({}))
    },
  }
  for i in 0..<80 {
    let k = "project:" + "中".repeat(75) + "-" + i.to_string()
    @sfbase.set_group_collapsed(src_cjk, ws, k, true)
  }
  assert_true(last_sent_bytes > 0 && last_sent_bytes <= 16384, msg="UTF-8 payload exceeded 16384 bytes: \{last_sent_bytes}")

  // Case 4 (Astra M1): held_order keeps existing rows in their time sub-group while held (no duplicate sub/ keys)
  // and re-sorts cleanly once released.
  @sfbase.reset()
  let mk_item = fn(i : Int, title : String) -> ChatItem {
    { ..sample_chat(i), title, project: Some("monoid") }
  }
  let a = mk_item(1, "A")
  let b = mk_item(2, "B")
  let c = mk_item(3, "C")
  let d_before : Array[ChatDay] = [
    {
      key: "project:monoid",
      label: "monoid",
      group_kind: "project",
      group_project: Some("monoid"),
      chat_count: 3,
      running_count: 0,
      alert_count: 0,
      asking_count: 0,
      unread_count: 0,
      day_breaks: [(0, "今天"), (1, "昨天")],
      items: [a, b, c],
    },
  ]
  // Initial unheld display
  let _ = @sfbase.held_order("held-sub-key", d_before, false)
  // Background message moves C from 昨天 to 今天 while pointer holds the list
  let d_after : Array[ChatDay] = [
    {
      ..d_before[0],
      day_breaks: [(0, "今天"), (2, "昨天")],
      items: [c, a, b],
    },
  ]
  let while_held = @sfbase.held_order("held-sub-key", d_after, true)
  let keys_held = day_keys(while_held)
  let seen_k : Map[String, Bool] = Map([])
  for lk in keys_held {
    assert_false(seen_k.contains(lk), msg="duplicate virtual list key while held: \{lk}")
    seen_k[lk] = true
  }
  // Releasing hold moves C to top under 今天 with unique keys
  let released = @sfbase.held_order("held-sub-key", d_after, false)
  let keys_rel = day_keys(released)
  assert_eq(keys_rel, [
    "h/project:monoid",
    "sub/project:monoid\u{1}今天",
    "r/" + @sfbase.row_name(c),
    "r/" + @sfbase.row_name(a),
    "sub/project:monoid\u{1}昨天",
    "r/" + @sfbase.row_name(b),
  ])
  @sfbase.projects_reset()
  @sfbase.reset()
}

///|
test "grouped list load_more stays reachable when expanded group has >=8 rows and next page lands in collapsed group (Astra M3)" {
  @sfbase.projects_reset()
  @sfbase.reset()
  reset()
  @sf.set_words(@sfbase.fill)
  let ws = "ws-load-more-m3"
  let page = @signals.signal(1)
  let mk_chat = fn(id : String, title : String, proj : String) -> Json {
    { "id": Json::string(id), "session": Json::string(id), "title": Json::string(title), "station": "ws/s1", "stationName": "S1", "project": Json::string(proj) }
  }
  let a_items : Array[Json] = []
  for i in 0..<8 {
    a_items.push(mk_chat("c-a" + i.to_string(), "Alpha Chat " + i.to_string(), "alpha"))
  }
  let grouped_json = fn() -> Json {
    let p = page.get()
    let b_count = if p >= 3 { 120 } else if p >= 2 { 80 } else { 40 }
    let b_items : Array[Json] = []
    for i in 0..<b_count {
      b_items.push(mk_chat("c-b" + i.to_string(), "Beta Chat " + i.to_string(), "beta"))
    }
    let groups : Array[Json] = [
      {
        "key": "project:alpha",
        "kind": "project",
        "label": "alpha",
        "project": "alpha",
        "chatCount": 8.0,
        "runningCount": 0.0,
        "alertCount": 0.0,
        "askingCount": 0.0,
        "unreadCount": 0.0,
        "items": Json::array(a_items),
      },
      {
        "key": "project:beta",
        "kind": "project",
        "label": "beta",
        "project": "beta",
        "chatCount": Json::number(b_items.length().to_double()),
        "runningCount": 0.0,
        "alertCount": 0.0,
        "askingCount": 0.0,
        "unreadCount": 0.0,
        "items": Json::array(b_items),
      },
    ]
    if p >= 4 {
      groups.push({
        "key": "project:gamma",
        "kind": "project",
        "label": "gamma",
        "project": "gamma",
        "chatCount": 1.0,
        "runningCount": 0.0,
        "alertCount": 0.0,
        "askingCount": 0.0,
        "unreadCount": 0.0,
        "items": [mk_chat("c-g1", "Gamma Chat 1", "gamma")],
      })
    }
    let more_n = if p == 1 { 81.0 } else if p == 2 { 41.0 } else if p == 3 { 1.0 } else { 0.0 }
    {
      "stations": [{ "station": "ws/s1", "state": "online" }],
      "leading": "agents",
      "projects": true,
      "projectsWritable": true,
      "more": Json::number(more_n),
      "days": [],
      "groups": Json::array(groups),
    }
  }
  let base_src = proj_test_source(fn(name, params) {
    if name == "prefs" {
      Some({
        "listGroups": { "ws-load-more-m3": "project" },
        "groupCollapsed": { "ws-load-more-m3": "{\"d\":false,\"x\":[\"project:beta\"]}" },
      })
    } else if name == "chats" {
      if params.get("groupBy") == Some(Json::string("project")) {
        Some(grouped_json())
      } else {
        Some({ "projects": true, "projectsWritable": true, "days": [] })
      }
    } else {
      None
    }
  })
  let src : Source = {
    ..base_src,
    call: fn(cmd, _params, done) {
      if cmd == "chats.window" {
        page.set(page.untracked() + 1)
      }
      done(Ok({}))
    },
  }
  let ws_obj : Workspace = { id: ws, name: "LoadMore WS", emoji: "", icon: "", email: "" }
  let t = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let tips = @sf.TipLayer::new(fn() { None })
      let frame : ListsNodeFrame = {
        top: fn() { 0.0 },
        under: fn() { 0.0 },
        foot: fn() { 0.0 },
        ground: fn() { @sf.theme().p.bg },
        before: fn(_, _) { [] },
        after: fn(_, _) { [] },
        others: [],
        shown: fn() { 0 },
        at: Side,
        watched: fn() { true },
        section_rows: fn() { (2, 2) },
        section_chrome_suppress: fn() { false },
      }
      root.box(fn(o) {
        o.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        chats_lists_node(o, src, fn() { Some(ws_obj) }, frame, tips, fn() { 0 })
      })
      |> ignore
    },
    w=320.0,
    h=900.0,
    platform=0,
    scale=2.0,
  )
  t.run_for(@ui.move_most_ms)
  // Initial bottom reach auto-grows once into collapsed Beta (page 1 -> 2), leaving Alpha expanded (8 rows),
  // Beta collapsed, Gamma still unloaded, and more > 0: load_more MUST remain visible (not gated by vis_rows < 8)!
  let p_after_mount = page.untracked()
  assert_true(p_after_mount <= 2, msg="initial mount should not exhaust pages before user clicks load_more: p=\{p_after_mount}")
  assert_true(t.find("Alpha Chat 7") is Some(_))
  assert_true(t.find("Beta Chat 1") is None)
  assert_true(t.find("Gamma Chat 1") is None)
  let lm1 = t.query(Button, label=@sf.t("web-pages.projects.load_more"))
  assert_true(lm1 is Some(_), msg="load_more missing when alpha has 8 visible rows and beta is collapsed")
  // Click load_more -> next page adds chats strictly into collapsed Beta (visible rows stay 8), more > 0 -> load_more MUST stay!
  t.click(Button, label=@sf.t("web-pages.projects.load_more"))
  t.run_for(@ui.move_most_ms)
  assert_eq(page.untracked(), p_after_mount + 1)
  assert_true(t.find("Gamma Chat 1") is None)
  let lm2 = t.query(Button, label=@sf.t("web-pages.projects.load_more"))
  assert_true(lm2 is Some(_), msg="load_more disappeared after page landed solely in collapsed group beta")
  // Click load_more until group C (gamma) is reached -> more=0 hides load_more and Gamma Chat 1 is visible!
  while page.untracked() < 4 {
    t.click(Button, label=@sf.t("web-pages.projects.load_more"))
    t.run_for(@ui.move_most_ms)
  }
  assert_eq(page.untracked(), 4)
  assert_true(t.find("gamma") is Some(_), msg="group C (gamma) must become reachable")
  assert_true(t.find("Gamma Chat 1") is Some(_), msg="Gamma Chat 1 must become visible")
  assert_true(t.query(Button, label=@sf.t("web-pages.projects.load_more")) is None)
  @sfbase.projects_reset()
  @sfbase.reset()
  reset()
}
