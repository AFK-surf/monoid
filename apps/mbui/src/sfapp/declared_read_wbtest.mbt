// What the workspace in view's first screen opens on is declared as the workspace comes to be in view (sfbase's
// opens_ahead_node: each shell's home_opens or frame_opens), asked of the core then and taken over by the readers
// that come to read it (sfbase's declare_topic). Held here on each screen, opened over the made-up core through the
// app's own client: once the first screen is at rest, none of it is left declared and read by no reader (a
// declaration of what that screen does not read: mended in its opens, never let be: the coordinator of the
// migration, 2026-11-12), and from the declaration through the reader taking it the core is told of no topic left
// and asked again (the same subscription all along).

///|
/// What the client sent the made-up core, `heard` (round_trip_again's), read for a topic let go of and asked again:
/// each such, by its topic.
fn asked_again(heard : Array[String]) -> Array[String] {
  let by_id : Map[Int, String] = Map([])
  let left : Map[String, Bool] = Map([])
  let again : Array[String] = []
  for h in heard {
    guard h.has_prefix("out ") else { continue }
    let j = @json.parse(h.exact_view(start=4).to_owned()) catch { _ => continue }
    guard j is Object(m) && m.get("id") is Some(Number(n, ..)) else { continue }
    let id = n.to_int()
    match (m.get("subscribe"), m.get("unsubscribe")) {
      (Some(t), _) => {
        let key = t.stringify()
        if left.contains(key) {
          again.push(key)
        }
        by_id[id] = key
      }
      (_, Some(_)) =>
        match by_id.get(id) {
          Some(key) => left[key] = true
          None => ()
        }
      _ => ()
    }
  }
  again
}

///|
test "what the first screen opens on, declared as its workspace comes in view: on 小屏, 中屏 and 大屏 all of it read once the screen is at rest, none of it let go of and asked again on the way" {
  let faults : Array[String] = []
  for s in switch_screens {
    let (name, w, h, platform) = s
    let heard : Array[String] = []
    let _ = switch_on(fn(_) { 60.0 }, heard, w, h, platform, 60.0)
    let unread = @sfbase.declared_unread()
    if unread.length() > 0 {
      faults.push("\{name}: declared and read by none at rest: " + unread.join(", "))
    }
    let again = asked_again(heard)
    if again.length() > 0 {
      faults.push("\{name}: let go of and asked again as it opened: " + again.join(", "))
    }
  }
  assert_eq(faults, [])
}

///|
test "what a run declared and no reader took is let go of as the next run begins: the core told, not left followed by nothing into it" {
  fresh_app()
  let base = fixture("home")
  let let_go : Array[String] = []
  let src : Source = {
    ..base,
    release: fn(name, params) {
      let_go.push(name + " " + Json::object(params).stringify())
      (base.release)(name, params)
    },
  }
  let params : Map[String, Json] = { "scope": Json::string("ws1") }
  @sfbase.declare_topic(src, "longJobs", params) |> ignore
  assert_eq(@sfbase.declared_unread().length(), 1)
  assert_eq(let_go, [])
  // the next run begins
  fresh_app()
  assert_eq(let_go, ["longJobs " + Json::object(params).stringify()])
  assert_eq(@sfbase.declared_unread(), [])
}

///|
test "a chat's page's reads declared as it comes on top: asked at that moment, the frames that build it asking nothing more till its view is answered (what that leads to its readers'), and all of them read once it is at rest, on 小屏 and 大屏" {
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  let faults : Array[String] = []
  for w in [390.0, 1280.0] {
    new_run()
    let base = fixture("home")
    // (each topic the app comes to follow, as it is first read of the made-up core; after the chat came on top, those
    // first read then; the chat's view not answered till `answered`)
    let seen : Map[String, Bool] = Map([])
    let after : Array[String] = []
    let opened = Ref(false)
    let answered = @signals.signal(true)
    let src : Source = {
      ..base,
      topic_read: fn(name, params) {
        let key = name + " " + Json::object(params).stringify()
        if !seen.contains(key) {
          seen[key] = true
          if opened.val {
            after.push(key)
          }
        }
        if name == "chat" && !answered.get() {
          return { value: None, error: None, version: 0 }
        }
        base.topic(name, params).get().snapshot()
      },
    }
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h=800.0, platform=0)
    t.run_for(@sf.local_ms)
    answered.set(false)
    @sfbase.open_chat(r)
    opened.val = true
    t.run_for(@sf.local_ms)
    if after.length() > 0 {
      faults.push("\{w}: asked as a frame built it, not declared: " + after.join(", "))
    }
    answered.set(true)
    t.run_for(@sf.local_ms)
    let unread = @sfbase.declared_unread()
    if unread.length() > 0 {
      faults.push("\{w}: declared and read by none at rest: " + unread.join(", "))
    }
  }
  assert_eq(faults, [])
}

///|
/// Every page a gate opens by (sfbase's page_reads, route_reads; sfdesk's place_reads), each route of the settings'.
fn gated_pages() -> Array[Page] {
  let r : ChatRef = { station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" }
  let routes : Array[@settings.Route] = [
    Home, Me, Appearance, Experimental, Fonts, Workspace, Security, SecurityOpen, Vault, Stations, Station("ws1/st1"), Profiles(""),
    Profiles("ws1/st1"), Profile("ws1/st1", "p1"), Connects(""), Connects("ws1/st1"), Connect("ws1/st1", "c1"), Memories,
    Memory("ws1/st1"), MemoryDoc("ws1/st1", "", 0), Usage, Archive, AdbShare("ws1/st1"), NewProfile("ws1/st1"),
    ProfileAccount("k1"), VaultItems, VaultItem("v1", "i1"), AutoDecisions, AutoCompletion, AutoPolicy("ws1/st1"),
    BarSettings, KeptFiles, KeptChat("ws1/st1", 1), Changelog, About, Shortcuts, LocalStation, Notifications,
    Permissions, Archiving, StationArchiving("ws1/st1"), Backup, StationBackup("ws1/st1"), StationMove("ws1/st1"), UsagePrices(7),
  ]
  [
    Chat(r),
    NewChat,
    Settings,
    Archived,
    Files,
    Drive({ station: "ws1/st1", root: None, path: "" }),
    Drive({ station: "ws1/st1", root: Some(@sffixture.fix_docs), path: "" }),
    DriveRead({ station: "ws1/st1", root: Some(@sffixture.fix_docs), path: "a.md" }),
    Service("ws1/st1", "j-web"),
    PreviewFile("ws1/st1", "s-c1", "work/s-c1/release.html", "release.html"),
    Place("stations"),
    Place("profiles"),
    Place("connects"),
    Place("usage"),
    Place("archive"),
    ..routes.map(fn(r) { Page::Setting(r) }),
  ]
}

///|
test "every page opened where what opens waits for what it shows: all its gate asks read once it is at rest, the gate told then, on 小屏, 中屏 and 大屏" {
  // (a sweep of what each page reads at rest, as the screens' sweeps are: at the default rate alone; what a page's
  // opening does frame by frame is its own tests')
  if @ui.test_at_a_rate() {
    return
  }
  @ui.host_image_bytes_known([("src/sfapp/declared_read_wbtest.mbt", 10862)])
  let faults : Array[String] = []
  for s in switch_screens {
    let (name, w, h, platform) = s
    for i, page in gated_pages() {
      new_run()
      let base = fixture("home")
      // (what the made-up core has no value for answered as the core does before it holds any: null)
      let src : Source = {
        ..base,
        gates_opens: fn() { true },
        topic_read: fn(n, ps) {
          let s = base.topic(n, ps).get().snapshot()
          if s.value is None && s.error is None {
            { ..s, value: Some(Json::null()) }
          } else {
            s
          }
        },
      }
      let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~)
      t.run_for(@sf.local_ms)
      @sfbase.open_page(page)
      t.run_for(@sf.local_ms)
      t.run_for(@sf.local_ms)
      let unread = @sfbase.declared_unread()
      if unread.length() > 0 {
        faults.push("\{name} #\{i}: declared and read by none at rest: " + unread.join(", "))
      }
      let told = match @sfbase.workspace_in_view(src).0 {
        Some(ws) =>
          if name == "小屏" {
            page_opens_by(src, ws, page, @sfbase.read_now(src))
          } else {
            @sfdesk.pane_opens(src, ws.id, page, @sfbase.read_now(src))
          }
        None => false
      }
      if !told {
        let untold : Array[String] = []
        let ask = fn(n : String, ps : Map[String, Json]) {
          let st = @sfbase.read_now(src)(n, ps)
          if !@sfbase.open_told(st) {
            untold.push(n + " " + Json::object(ps).stringify())
          }
          st
        }
        match @sfbase.workspace_in_view(src).0 {
          Some(ws) => if name == "小屏" { page_opens_by(src, ws, page, ask) |> ignore } else { @sfdesk.pane_opens(src, ws.id, page, ask) |> ignore }
          None => ()
        }
        faults.push("\{name} #\{i}: its gate not told at rest: " + untold.join(", "))
      }
    }
  }
  assert_eq(faults, [])
}
