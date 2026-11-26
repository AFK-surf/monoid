// Adversarial tests for Wave 1 Module 3:
// - OptimisticChoice[S, T] queue-free single-slot version-gated optimistic helper:
//   * Single persistent subscription across consecutive submits
//   * Scope switch A -> B isolation (stale A topic seq=900 & late A ack dropped; B low seq 1,2 accepted)
//   * In-place core restart: (a) no input, (b) click during restart window in both arrival orders
//     (first-frame-before-ack and ack-before-first-frame): RPC sent once, never rolls back to 10, ends pending=false
//   * Stale snapshot filtering: (102, 30) -> (104, 60) -> (103, 20) -> (0, 10) stays at 60
//   * Legacy unversioned core fallback (no seq -> shows merged 60 immediately, pending=false)
//   * FIFO 10 -> 20 -> 10 (both acks before topics) with zero rollback
//   * FIFO 10 -> 20 -> 30 + external write back to 20 at higher seq
//   * Unmount mid-flight (20, 30 -> unmount -> ack 20 -> pending=false)
//   * Late failure B + success C + external D, both topic->then and then->topic orders, current failure rollback
// - Real progress_node controllable async RPC & progressSeq handoff
// - settings/home.mbt set_pref_with req_seq guard against stale failure

///|
fn make_opt_test_core(
  topics : Map[String, @signals.Signal[@settings.Read]],
  gens : Map[String, Ref[(Int, Bool)]],
  calls : Array[(String, Json, (Result[Json, Json]) -> Unit)],
) -> @settings.Core {
  let base = @sfbase.settings_core(@sffixture.fixture("settings"), rig_workspace)
  let key_of = fn(name : String, params : Map[String, Json]) -> String {
    match params.get("scope") {
      Some(String(s)) => name + ":" + s
      _ => name
    }
  }
  {
    ..base,
    topic: fn(name, params) {
      let k = key_of(name, params)
      let sig = match topics.get(k) {
        Some(s) => s
        None => {
          let s = @signals.signal(@settings.Read::{ value: None, error: None, version: 0 })
          topics[k] = s
          s
        }
      }
      @signals.computed(fn(_) { sig.get() })
    },
    generation: fn(name, params) {
      let k = key_of(name, params)
      match gens.get(k) {
        Some(r) => r.val
        None => (1, true)
      }
    },
    call: fn(name, params, done) { calls.push((name, params, done)) },
    say: fn(_) { () },
  }
}

///|
fn settings_json(minutes : Double, strength : String, seq : Int64?) -> Json {
  let pairs : Array[(String, Json)] = [
    ("progressMinutes", Json::number(minutes)),
    ("progressStrength", Json::string(strength)),
  ]
  match seq {
    Some(s) => pairs.push(("progressSeq", Json::number(s.to_double())))
    None => ()
  }
  obj(pairs)
}

///|
test "OptimisticChoice: persistent sub, scope switch A->B isolation, stale snapshot filter, legacy fallback, FIFO, failure, unmount" {
  let topics : Map[String, @signals.Signal[@settings.Read]] = Map([])
  let gens : Map[String, Ref[(Int, Bool)]] = Map([])
  let calls : Array[(String, Json, (Result[Json, Json]) -> Unit)] = []
  let ver = Ref(1)
  let push_topic = fn(ws : String, mins : Double, seq : Int64?, gen : Int, fresh : Bool) {
    let k = "settings:" + ws
    gens[k] = Ref((gen, fresh))
    ver.val += 1
    let rd : @settings.Read = { value: Some(settings_json(mins, "require", seq)), error: None, version: ver.val }
    match topics.get(k) {
      Some(s) => s.set(rd)
      None => topics[k] = @signals.signal(rd)
    }
  }
  push_topic("A", 10.0, Some(100L), 1, true)
  push_topic("B", 10.0, Some(1L), 1, true)
  let core = make_opt_test_core(topics, gens, calls)
  let scope = @signals.signal("A")
  let mounted = @signals.signal(true)
  let helper : Ref[OptimisticChoice[String, Double]?] = Ref(None)
  let t = @ui.Tester::new(fn(_c) {  }, w=320.0, h=120.0, dark=false, platform=0)
  @ui.set_view_app(fn(root) {
    root.show(fn() { mounted.get() }, at_once=true, fn(host) {
      let h = OptimisticChoice::new(
        host,
        core,
        fn() { scope.get() },
        "settings",
        fn(ws) { { "scope": str(ws) } },
        fn(v) {
          match number(v, "progressMinutes") {
            0.0 => 10.0
            n => n
          }
        },
        fn(v) { opt_seq(v, "progressSeq") },
      )
      helper.val = Some(h)
      host.box(fn(b) { b.words(By(fn() { h.get().to_int().to_string() })) |> ignore }) |> ignore
    })
  })
  t.draw()
  let h = helper.val.unwrap()
  assert_eq(h.get(), 10.0)
  assert_true(!h.is_pending())

  // 1. FIFO 10 -> 20 -> 10 (both acks before topics): stays at 10 with zero rollback.
  let cbs1 : Array[(Bool, Int64?) -> Unit] = []
  h.submit(20.0, fn(_, f) { cbs1.push(f) })
  assert_eq(h.get(), 20.0)
  h.submit(10.0, fn(_, f) { cbs1.push(f) })
  assert_eq(h.get(), 10.0)
  assert_eq(cbs1.length(), 2)
  (cbs1[0])(true, Some(101L))
  (cbs1[1])(true, Some(102L))
  assert_eq(h.get(), 10.0)
  assert_true(h.is_pending())
  push_topic("A", 20.0, Some(101L), 1, true)
  t.draw()
  assert_eq(h.get(), 10.0, msg="intermediate topic 101 must not roll back latest intent 10")
  push_topic("A", 10.0, Some(102L), 1, true)
  t.draw()
  assert_eq(h.get(), 10.0)
  assert_true(!h.is_pending(), msg="handoff at seq 102 must clear pending")

  // 2. Stale snapshot filtering after ack 102: (102, 30) -> (104, 60) -> (103, 20) -> (0, 10) stays at 60.
  push_topic("A", 30.0, Some(102L), 1, true)
  t.draw()
  assert_eq(h.get(), 30.0)
  push_topic("A", 60.0, Some(104L), 1, true)
  t.draw()
  assert_eq(h.get(), 60.0)
  push_topic("A", 20.0, Some(103L), 1, true)
  t.draw()
  assert_eq(h.get(), 60.0, msg="stale seq 103 < 104 must be discarded")
  push_topic("A", 10.0, Some(0L), 1, true)
  t.draw()
  assert_eq(h.get(), 60.0, msg="stale seq 0 < 104 must be discarded")

  // 3. FIFO 10 -> 20 -> 30 + external higher-seq write back to 20.
  let cbs2 : Array[(Bool, Int64?) -> Unit] = []
  h.submit(20.0, fn(_, f) { cbs2.push(f) })
  h.submit(30.0, fn(_, f) { cbs2.push(f) })
  assert_eq(h.get(), 30.0)
  // B (20) fails late; C (30) succeeds; topic->then order.
  (cbs2[0])(false, None)
  assert_eq(h.get(), 30.0, msg="stale failure of 20 must not clear 30")
  push_topic("A", 30.0, Some(106L), 1, true)
  t.draw()
  (cbs2[1])(true, Some(106L))
  assert_eq(h.get(), 30.0)
  assert_true(!h.is_pending())
  push_topic("A", 20.0, Some(107L), 1, true)
  t.draw()
  assert_eq(h.get(), 20.0, msg="external higher seq 107 writing 20 must take over immediately")

  // 4. Current failure rolls back cleanly to authority.
  let cbs_fail : Array[(Bool, Int64?) -> Unit] = []
  h.submit(60.0, fn(_, f) { cbs_fail.push(f) })
  assert_eq(h.get(), 60.0)
  (cbs_fail[0])(false, None)
  assert_eq(h.get(), 20.0, msg="current failure must roll back to 20")
  assert_true(!h.is_pending())

  // 4b. Versioned core 64 alternating submits with deferred ACKs must keep unversioned_queue empty (0 growth).
  let cbs_v64 : Array[(Bool, Int64?) -> Unit] = []
  for step in 0..<64 {
    let want = if step % 2 == 0 { 30.0 } else { 20.0 }
    h.submit(want, fn(_, f) { cbs_v64.push(f) })
    push_topic("A", want, Some(108L + step.to_int64()), 1, true)
    t.draw()
  }
  assert_eq(h.unversioned_queue.val.length(), 0, msg="versioned core must never grow unversioned_queue")
  (cbs_v64[63])(true, Some(171L))
  assert_true(!h.is_pending())

  // 5. Scope switch A -> B: A's queued topic (seq=900) and late ack must not pollute B; B's low seq (2) works.
  let cbs_a : Array[(Bool, Int64?) -> Unit] = []
  h.submit(30.0, fn(_, f) { cbs_a.push(f) })
  scope.set("B")
  t.draw()
  assert_eq(h.get(), 10.0)
  assert_true(!h.is_pending())
  // Late A ack & direct stale A topic event
  (cbs_a[0])(true, Some(900L))
  h.on_topic("A", 60.0, Some(900L), true, 1, true)
  assert_eq(h.get(), 10.0, msg="A's seq=900 must not pollute B")
  push_topic("B", 20.0, Some(2L), 1, true)
  t.draw()
  assert_eq(h.get(), 20.0, msg="B's low seq 2 must display normally")

  // 5b. Same-batch scope switch B -> A followed immediately by submit BEFORE watcher runs:
  // must sync scope immediately, NOT swallow click, and pass live scope "A" to send.
  push_topic("A", 10.0, Some(108L), 1, true)
  scope.set("A")
  let sent_scopes : Array[String] = []
  h.submit(20.0, fn(sc, _f) { sent_scopes.push(sc) })
  assert_eq(sent_scopes, ["A"], msg="same-batch scope switch + submit must send to live scope A")
  assert_eq(h.get(), 20.0)
  t.draw()
  scope.set("B")
  t.draw()

  // 6. Legacy unversioned core fallback: seq=None clears last_accepted_seq; A->B->A holds non-sticky in-flight slot
  //    so second A is never swallowed, and any unversioned topic(None) or ack(None) immediately clears pending == false.
  push_topic("B", 20.0, None, 1, true)
  t.draw()
  let cbs_leg : Array[(Bool, Int64?) -> Unit] = []
  h.submit(30.0, fn(_, f) { cbs_leg.push(f) })
  assert_eq(h.get(), 30.0)
  assert_true(h.is_pending(), msg="unversioned in-flight RPC holds non-sticky slot until topic/ack")
  h.submit(20.0, fn(_, f) { cbs_leg.push(f) })
  assert_eq(cbs_leg.length(), 2, msg="unversioned A->B->A must NOT swallow second A")
  assert_eq(h.get(), 20.0)
  // External unversioned topic 60 immediately overrides and clears slot (never sticky!)
  push_topic("B", 60.0, None, 1, true)
  t.draw()
  assert_eq(h.get(), 60.0)
  assert_true(!h.is_pending(), msg="unversioned topic(None) must clear slot immediately")
  (cbs_leg[0])(true, None)
  (cbs_leg[1])(true, None)
  assert_eq(h.get(), 60.0)
  assert_true(!h.is_pending())
  // Re-versioned low seq=1 after seq=None must be accepted (last_accepted_seq was reset).
  push_topic("B", 5.0, Some(1L), 1, true)
  t.draw()
  assert_eq(h.get(), 5.0, msg="seq=1 after seq=None draft drop must be accepted")

  // 7. Unmount mid-flight clears pending and ignores late callbacks.
  push_topic("B", 10.0, Some(5L), 1, true)
  t.draw()
  let cbs_u : Array[(Bool, Int64?) -> Unit] = []
  h.submit(20.0, fn(_, f) { cbs_u.push(f) })
  h.submit(30.0, fn(_, f) { cbs_u.push(f) })
  mounted.set(false)
  t.draw()
  assert_true(!h.is_pending(), msg="unmount must clear optimistic slot")
  (cbs_u[0])(true, Some(6L))
  (cbs_u[1])(true, Some(7L))
  assert_true(!h.is_pending())
}

///|
test "OptimisticChoice: in-place core restart (a) idle takeover and (b) click during restart window before & after notify in both arrival orders" {
  // Cover both click timings (before_notify=true/false) x both arrival orders (0=first-frame then ack, 1=ack then first-frame).
  for before_notify in [true, false] {
    for order in [0, 1] {
      let topics : Map[String, @signals.Signal[@settings.Read]] = Map([])
      let gens : Map[String, Ref[(Int, Bool)]] = Map([])
      let calls : Array[(String, Json, (Result[Json, Json]) -> Unit)] = []
      let ver = Ref(1)
      let set_topic = fn(mins : Double, seq : Int64?, gen : Int, fresh : Bool) {
        gens["settings:ws1"] = Ref((gen, fresh))
        ver.val += 1
        let rd : @settings.Read = { value: Some(settings_json(mins, "require", seq)), error: None, version: ver.val }
        match topics.get("settings:ws1") {
          Some(s) => s.set(rd)
          None => topics["settings:ws1"] = @signals.signal(rd)
        }
      }
      set_topic(10.0, Some(104L), 1, true)
      let core = make_opt_test_core(topics, gens, calls)
      let helper : Ref[OptimisticChoice[String, Double]?] = Ref(None)
      let t = @ui.Tester::new(fn(_c) {  }, w=320.0, h=120.0, dark=false, platform=0)
      @ui.set_view_app(fn(root) {
        root.box(fn(host) {
          let h = OptimisticChoice::new(
            host,
            core,
            fn() { "ws1" },
            "settings",
            fn(ws) { { "scope": str(ws) } },
            fn(v) {
              match number(v, "progressMinutes") {
                0.0 => 10.0
                n => n
              }
            },
            fn(v) { opt_seq(v, "progressSeq") },
          )
          helper.val = Some(h)
        })
        |> ignore
      })
      t.draw()
      let h = helper.val.unwrap()
      assert_eq(h.get(), 10.0)

      // (a) Core restarts in place with cached value retained (gen=2, fresh=false): no blank flash; old ack ignored; new gen seq 1->2 takes over.
      let old_cb : Ref[((Bool, Int64?) -> Unit)?] = Ref(None)
      h.submit(20.0, fn(_, f) { old_cb.val = Some(f) })
      set_topic(10.0, Some(104L), 2, false)
      t.draw()
      (old_cb.val.unwrap())(true, Some(105L))
      set_topic(10.0, Some(1L), 2, true)
      t.draw()
      assert_eq(h.get(), 10.0)
      set_topic(20.0, Some(2L), 2, true)
      t.draw()
      assert_eq(h.get(), 20.0)

      // (b) Restart to gen=3 (fresh=false retaining 10(104)): user clicks 30 either BEFORE or AFTER subscription notifies.
      set_topic(10.0, Some(104L), 2, true)
      t.draw()
      assert_eq(h.get(), 10.0)
      if before_notify {
        gens["settings:ws1"] = Ref((3, false))
      } else {
        set_topic(10.0, Some(104L), 3, false)
        t.draw()
      }
      let rpc_cbs : Array[(Bool, Int64?) -> Unit] = []
      h.submit(30.0, fn(_, f) { rpc_cbs.push(f) })
      assert_eq(rpc_cbs.length(), 1, msg="before=\{before_notify} order=\{order}: RPC must be sent exactly once")
      assert_eq(h.get(), 30.0, msg="before=\{before_notify} order=\{order}: must immediately show 30")
      assert_true(h.is_pending())
      if order == 0 {
        set_topic(10.0, Some(1L), 3, true)
        t.draw()
        assert_eq(h.get(), 30.0, msg="before=\{before_notify} order=0: first fresh frame 10(1) must NEVER roll back 30")
        (rpc_cbs[0])(true, Some(2L))
        assert_eq(h.get(), 30.0, msg="before=\{before_notify} order=0: after ack(2) must still show 30")
        assert_true(h.is_pending())
      } else {
        (rpc_cbs[0])(true, Some(2L))
        assert_eq(h.get(), 30.0, msg="before=\{before_notify} order=1: after ack(2) must show 30")
        set_topic(10.0, Some(1L), 3, true)
        t.draw()
        assert_eq(h.get(), 30.0, msg="before=\{before_notify} order=1: first fresh frame 10(1) must NEVER roll back 30")
        assert_true(h.is_pending())
      }
      set_topic(30.0, Some(2L), 3, true)
      t.draw()
      assert_eq(h.get(), 30.0)
      assert_true(!h.is_pending(), msg="before=\{before_notify} order=\{order}: snapshot 30(2) must finish handoff")
    }
  }
}

///|
test "Real progress_node: controllable async RPC, zero rollback across rapid clicks, progressSeq handoff" {
  let topics : Map[String, @signals.Signal[@settings.Read]] = Map([])
  let gens : Map[String, Ref[(Int, Bool)]] = Map([])
  let calls : Array[(String, Json, (Result[Json, Json]) -> Unit)] = []
  let ver = Ref(1)
  let push_settings = fn(mins : Double, strength : String, seq : Int64) {
    gens["settings:ws1"] = Ref((1, true))
    ver.val += 1
    let rd : @settings.Read = { value: Some(settings_json(mins, strength, Some(seq))), error: None, version: ver.val }
    match topics.get("settings:ws1") {
      Some(s) => s.set(rd)
      None => topics["settings:ws1"] = @signals.signal(rd)
    }
  }
  push_settings(10.0, "require", 1L)
  let core = make_opt_test_core(topics, gens, calls)
  let show_page = @signals.signal(true)
  let here_val : Here = { workspace: "ws1", name: "WS", sub: "u1", email: "u@e", person: "U", picture: "" }
  let t = @ui.Tester::new(
    @ui.old_views_here,
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      @sf.presented_nodes(root)
    },
    w=390.0,
    h=700.0,
    platform=0,
    pointing=Mouse,
    native=Mouse,
  )
  @sf.set_words(@sfbase.fill)
  @ui.set_view_app(
    fn(root) {
      root.show(fn() { show_page.get() }, at_once=true, fn(host) {
        progress_node(host, core, fn() { here_val }, on_back=fn() { () }, frame=fn() { { back: None, top: 0.0, foot: 0.0, named: false } }, width=fn() { 390.0 })
      })
    },
    theme=@sf.ui_theme_now,
  )
  t.draw()
  assert_true(t.find(@sf.t("web-pages.progress.requireNote")) is Some(_))
  let step_ms = 16.0
  let two_steps_ms = 32.0
  let r20 = t.get(Radio, label="20").rect
  let r30 = t.get(Radio, label="30").rect
  let minute_pill_cx = fn() -> Double {
    let lifted = @ui.tree_theme().lifted
    let rs = t.drawn_rects().filter(fn(r) { r.4 == lifted && (r.1 - r30.1).abs() < 8.0 && r.2 > 20.0 && r.2 < 100.0 })
    if rs.length() > 0 { rs[0].0 + rs[0].2 / 2.0 } else { -1.0 }
  }
  // Rapid clicks: 20 -> 30 -> remind while core hasn't answered yet.
  t.tap_text("20")
  t.run_for(step_ms)
  t.tap_text("30")
  t.run_for(step_ms)
  t.tap_text(@sf.t("web-pages.progress.remind"))
  t.run_for(step_ms)
  assert_eq(calls.length(), 3, msg="3 clicks must issue 3 RPCs immediately")
  assert_eq(t.get(Radio, label="30").check, Some(On), msg="minute 30 must be selected optimistically")
  assert_true(t.find(@sf.t("web-pages.progress.remindNote")) is Some(_), msg="optimistic note must switch to remindNote immediately")
  assert_eq(t.drawn_glass().length(), 0, msg="embedded progress_node taps must keep 0 glass")
  t.run_for(@ui.move_most_ms)
  let r20_cx = r20.0 + r20.2 / 2.0
  let r30_cx = r30.0 + r30.2 / 2.0
  let cx_at_30 = minute_pill_cx()
  assert_true((cx_at_30 - r30_cx).abs() < 3.0, msg="minute capsule must settle on 30, got \{cx_at_30} vs \{r30_cx}")
  // Deliver intermediate RPC ack & topic 20(2): minute 30 selected state AND capsule center must NOT roll back to 20 or fly toward 60!
  (calls[0].2)(Ok(obj([("ok", Json::boolean(true)), ("seq", Json::number(2.0))])))
  push_settings(20.0, "require", 2L)
  for _ in 0..<4 {
    t.run_for(step_ms)
    assert_eq(t.get(Radio, label="30").check, Some(On), msg="intermediate seq=2 must NOT flip selection back to 20")
    let cx = minute_pill_cx()
    assert_true(cx > 0.0, msg="minute capsule must be found on screen")
    assert_true(cx >= r20_cx - 2.0 && cx <= r30_cx + 2.0, msg="capsule must stay bounded between 20 and 30 (never fly toward 60): \{cx} not in [\{r20_cx - 2.0}, \{r30_cx + 2.0}]")
    assert_true((cx - cx_at_30).abs() < 2.0, msg="intermediate seq=2 must NOT slide back from 30 (\{cx_at_30}), got \{cx}")
    assert_true((cx - r20_cx).abs() > 10.0, msg="capsule must NOT roll back toward 20")
    assert_true(t.find(@sf.t("web-pages.progress.remindNote")) is Some(_), msg="intermediate seq=2 must not roll back remindNote")
  }
  (calls[1].2)(Ok(obj([("ok", Json::boolean(true)), ("seq", Json::number(3.0))])))
  (calls[2].2)(Ok(obj([("ok", Json::boolean(true)), ("seq", Json::number(4.0))])))
  push_settings(30.0, "remind", 4L)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.get(Radio, label="30").check, Some(On))
  let cx_final = minute_pill_cx()
  assert_true((cx_final - r30_cx).abs() < 2.0, msg="final capsule must settle on 30 (\{r30_cx}), got \{cx_final}")
  assert_true(t.find(@sf.t("web-pages.progress.remindNote")) is Some(_))
  assert_eq(t.drawn_glass().length(), 0)
  t.assert_idle()

  // Leave page mid-flight (20 -> 30 -> unmount -> final 30(6) lands -> reopen -> late stale 20(5) ack & topic arrive AFTER reopen)
  let before_leave = calls.length()
  t.tap_text("20")
  t.run_for(step_ms)
  t.tap_text("30")
  t.run_for(step_ms)
  assert_eq(calls.length() - before_leave, 2, msg="20 and 30 must each issue 1 RPC")
  assert_eq(number(Some(calls[before_leave + 1].1), "minutes"), 30.0, msg="second RPC payload must carry minutes=30")
  show_page.set(false)
  t.draw()
  // Final 30(6) lands before reopen
  (calls[before_leave + 1].2)(Ok(obj([("ok", Json::boolean(true)), ("seq", Json::number(6.0))])))
  push_settings(30.0, "remind", 6L)
  // Reopen fresh progress_node -> reflects 30 cleanly
  show_page.set(true)
  t.draw()
  // Late stale 20 ack (from unmounted page) and stale topic 20(5) arrive AFTER reopen -> must NOT roll back 30!
  (calls[before_leave].2)(Ok(obj([("ok", Json::boolean(true)), ("seq", Json::number(5.0))])))
  push_settings(20.0, "remind", 5L)
  t.run_for(two_steps_ms)
  assert_eq(t.get(Radio, label="30").check, Some(On), msg="reopened progress_node must stay on 30 despite late 20(5) after reopen")
  assert_eq(t.drawn_glass().length(), 0)
  t.assert_idle()

  // Legacy unversioned core (no progressSeq) on real progress_node:
  let push_unversioned = fn(mins : Double, strength : String) {
    gens["settings:ws1"] = Ref((1, true))
    ver.val += 1
    let rd : @settings.Read = { value: Some(settings_json(mins, strength, None)), error: None, version: ver.val }
    match topics.get("settings:ws1") {
      Some(s) => s.set(rd)
      None => topics["settings:ws1"] = @signals.signal(rd)
    }
  }
  // Interleaving A: authority 20 -> click 30 -> ack(ok=true, None) before topic -> stays 30 ->
  // click 20 (NOT swallowed!) -> late topic(30, None) does NOT drop 20 -> ack(20, None) + topic(20, None) -> lands on 20.
  push_unversioned(20.0, "remind")
  t.draw()
  assert_eq(t.get(Radio, label="20").check, Some(On))
  let before_leg_a = calls.length()
  t.tap_text("30")
  t.run_for(step_ms)
  assert_eq(calls.length() - before_leg_a, 1)
  assert_eq(t.get(Radio, label="30").check, Some(On))
  (calls[before_leg_a].2)(Ok(obj([("ok", Json::boolean(true))])))
  t.draw()
  assert_eq(t.get(Radio, label="30").check, Some(On), msg="unversioned ack(ok=true, None) before topic must stay on 30")
  t.tap_text("20")
  t.run_for(step_ms)
  assert_eq(calls.length() - before_leg_a, 2, msg="unversioned Interleaving A: second click 20 must NOT be swallowed")
  assert_eq(number(Some(calls[before_leg_a].1), "minutes"), 30.0)
  assert_eq(number(Some(calls[before_leg_a + 1].1), "minutes"), 20.0)
  assert_eq(t.get(Radio, label="20").check, Some(On))
  push_unversioned(30.0, "remind")
  t.draw()
  assert_eq(t.get(Radio, label="20").check, Some(On), msg="unversioned Interleaving A: late topic(30, None) must NOT overwrite in-flight 20")
  (calls[before_leg_a + 1].2)(Ok(obj([("ok", Json::boolean(true))])))
  push_unversioned(20.0, "remind")
  t.run_for(@ui.move_most_ms)
  assert_eq(t.get(Radio, label="20").check, Some(On))

  // Interleaving B: authority 20 -> click 30 -> unrelated topic(20, None) mid-flight -> stays 30 ->
  // click 20 (NOT swallowed!) -> issues [30, 20] -> lands on 20; then ok=false rolls back & external topic(60) takes over immediately.
  let before_leg_b = calls.length()
  t.tap_text("30")
  t.run_for(step_ms)
  assert_eq(t.get(Radio, label="30").check, Some(On))
  push_unversioned(20.0, "remind")
  t.draw()
  assert_eq(t.get(Radio, label="30").check, Some(On), msg="unversioned Interleaving B: unrelated topic(20, None) mid-flight must NOT roll back 30")
  t.tap_text("20")
  t.run_for(step_ms)
  assert_eq(calls.length() - before_leg_b, 2, msg="unversioned Interleaving B: second click 20 must NOT be swallowed")
  assert_eq(number(Some(calls[before_leg_b].1), "minutes"), 30.0)
  assert_eq(number(Some(calls[before_leg_b + 1].1), "minutes"), 20.0)
  (calls[before_leg_b].2)(Ok(obj([("ok", Json::boolean(true))])))
  (calls[before_leg_b + 1].2)(Ok(obj([("ok", Json::boolean(true))])))
  push_unversioned(20.0, "remind")
  t.run_for(@ui.move_most_ms)
  assert_eq(t.get(Radio, label="20").check, Some(On))

  // Interleaving B-FIFO: same sequence with separate FIFO echoes [30, 20] delivered in order.
  let before_leg_b_fifo = calls.length()
  t.tap_text("30")
  t.run_for(step_ms)
  assert_eq(t.get(Radio, label="30").check, Some(On))
  push_unversioned(20.0, "remind")
  t.draw()
  assert_eq(t.get(Radio, label="30").check, Some(On))
  t.tap_text("20")
  t.run_for(step_ms)
  assert_eq(calls.length() - before_leg_b_fifo, 2)
  (calls[before_leg_b_fifo].2)(Ok(obj([("ok", Json::boolean(true))])))
  push_unversioned(30.0, "remind")
  t.draw()
  assert_eq(t.get(Radio, label="20").check, Some(On), msg="unversioned Interleaving B-FIFO: echo 30 must NOT roll back in-flight 20")
  (calls[before_leg_b_fifo + 1].2)(Ok(obj([("ok", Json::boolean(true))])))
  push_unversioned(20.0, "remind")
  t.run_for(@ui.move_most_ms)
  assert_eq(t.get(Radio, label="20").check, Some(On))

  // Interleaving C (unversioned burst): 20 -> click 30 -> click 20 -> ack1(None) -> topic1(30, None) (must stay 20!) ->
  // click 30 (must send 3rd RPC, total [30, 20, 30]) -> ack2(None) + topic2(20, None) (must stay 30!) ->
  // ack3(None) + topic3(30, None) -> settles on 30.
  let before_leg_c = calls.length()
  t.tap_text("30")
  t.run_for(step_ms)
  t.tap_text("20")
  t.run_for(step_ms)
  assert_eq(calls.length() - before_leg_c, 2)
  assert_eq(t.get(Radio, label="20").check, Some(On))
  (calls[before_leg_c].2)(Ok(obj([("ok", Json::boolean(true))])))
  push_unversioned(30.0, "remind")
  t.draw()
  assert_eq(t.get(Radio, label="20").check, Some(On), msg="unversioned burst: topic1(30, None) must NOT overwrite in-flight 20")
  t.tap_text("30")
  t.run_for(step_ms)
  assert_eq(calls.length() - before_leg_c, 3, msg="unversioned burst: 3rd click 30 must NOT be swallowed")
  assert_eq(number(Some(calls[before_leg_c].1), "minutes"), 30.0)
  assert_eq(number(Some(calls[before_leg_c + 1].1), "minutes"), 20.0)
  assert_eq(number(Some(calls[before_leg_c + 2].1), "minutes"), 30.0)
  assert_eq(t.get(Radio, label="30").check, Some(On))
  (calls[before_leg_c + 1].2)(Ok(obj([("ok", Json::boolean(true))])))
  push_unversioned(20.0, "remind")
  t.draw()
  assert_eq(t.get(Radio, label="30").check, Some(On), msg="unversioned burst: topic2(20, None) must NOT overwrite in-flight 30")
  (calls[before_leg_c + 2].2)(Ok(obj([("ok", Json::boolean(true))])))
  push_unversioned(30.0, "remind")
  t.run_for(@ui.move_most_ms)
  assert_eq(t.get(Radio, label="30").check, Some(On), msg="unversioned burst must settle on 30")
  // Reset back to 20 before Interleaving D, rollback & external takeover checks
  push_unversioned(20.0, "remind")
  t.draw()
  assert_eq(t.get(Radio, label="20").check, Some(On))

  // Interleaving D (unversioned late ack must NOT clobber newer external write back to 20):
  // 20 -> click 30 (1 RPC) -> topic(30, None) confirms 30 -> another device writes back topic(20, None) ->
  // late ack(ok=true, None) arrives -> must stay on 20 (NOT overwrite back to 30) and total calls == 1.
  let before_leg_d = calls.length()
  t.tap_text("30")
  t.run_for(step_ms)
  assert_eq(calls.length() - before_leg_d, 1)
  assert_eq(number(Some(calls[before_leg_d].1), "minutes"), 30.0)
  assert_eq(t.get(Radio, label="30").check, Some(On))
  push_unversioned(30.0, "remind")
  t.draw()
  push_unversioned(20.0, "remind")
  t.draw()
  (calls[before_leg_d].2)(Ok(obj([("ok", Json::boolean(true))])))
  t.run_for(@ui.move_most_ms)
  assert_eq(t.get(Radio, label="20").check, Some(On), msg="unversioned late ack must NOT clobber newer external topic(20, None)")
  assert_eq(calls.length() - before_leg_d, 1, msg="Interleaving D must have issued only 1 RPC")
  t.assert_idle()

  // Interleaving E (unversioned duplicate-value burst 30 -> 20 -> 30, then 4th click 20):
  // 20 -> click 30, 20, 30 before any reply -> ack1 + topic1(30) -> ack2 + topic2(20) (must STAY 30!) ->
  // click 20 (issues 4th RPC, total [30, 20, 30, 20]) -> ack3 + topic3(30) -> ack4 + topic4(20) -> settles on 20.
  let before_leg_e = calls.length()
  t.tap_text("30")
  t.run_for(step_ms)
  t.tap_text("20")
  t.run_for(step_ms)
  t.tap_text("30")
  t.run_for(step_ms)
  assert_eq(calls.length() - before_leg_e, 3)
  assert_eq(t.get(Radio, label="30").check, Some(On))
  (calls[before_leg_e].2)(Ok(obj([("ok", Json::boolean(true))])))
  push_unversioned(30.0, "remind")
  t.draw()
  (calls[before_leg_e + 1].2)(Ok(obj([("ok", Json::boolean(true))])))
  push_unversioned(20.0, "remind")
  t.draw()
  assert_eq(t.get(Radio, label="30").check, Some(On), msg="Interleaving E: topic2(20) must NOT clear in-flight 3rd click 30")
  t.tap_text("20")
  t.run_for(step_ms)
  assert_eq(calls.length() - before_leg_e, 4, msg="Interleaving E: 4th click 20 must NOT be swallowed")
  assert_eq(number(Some(calls[before_leg_e].1), "minutes"), 30.0)
  assert_eq(number(Some(calls[before_leg_e + 1].1), "minutes"), 20.0)
  assert_eq(number(Some(calls[before_leg_e + 2].1), "minutes"), 30.0)
  assert_eq(number(Some(calls[before_leg_e + 3].1), "minutes"), 20.0)
  assert_eq(t.get(Radio, label="20").check, Some(On))
  (calls[before_leg_e + 2].2)(Ok(obj([("ok", Json::boolean(true))])))
  push_unversioned(30.0, "remind")
  t.draw()
  assert_eq(t.get(Radio, label="20").check, Some(On), msg="Interleaving E: topic3(30) must NOT overwrite in-flight 4th click 20")
  (calls[before_leg_e + 3].2)(Ok(obj([("ok", Json::boolean(true))])))
  push_unversioned(20.0, "remind")
  t.run_for(@ui.move_most_ms)
  assert_eq(t.get(Radio, label="20").check, Some(On), msg="Interleaving E must settle on 20")
  t.assert_idle()

  // Interleaving F (unversioned 50ms coalesced snapshot prefix consumption):
  // 20 -> click 30, 60, 10 -> deliver first 2 ACKs -> push single coalesced topic(60, None) (must STAY 10!) ->
  // 4th click 60 (total 4 RPCs [30, 60, 10, 60]) -> deliver remaining ACKs + topic(10, None) + topic(60, None) -> settles on 60.
  let before_leg_f = calls.length()
  t.tap_text("30")
  t.draw()
  t.tap_text("60")
  t.draw()
  t.tap_text("10")
  t.draw()
  assert_eq(calls.length() - before_leg_f, 3)
  assert_eq(t.get(Radio, label="10").check, Some(On))
  (calls[before_leg_f].2)(Ok(obj([("ok", Json::boolean(true))])))
  (calls[before_leg_f + 1].2)(Ok(obj([("ok", Json::boolean(true))])))
  // Coalesced topic skips 30 and delivers 60 directly -> must consume prefix [30, 60] and keep in-flight 10!
  push_unversioned(60.0, "remind")
  t.draw()
  assert_eq(t.get(Radio, label="10").check, Some(On), msg="Interleaving F: coalesced topic(60, None) must NOT overwrite in-flight 10")
  t.tap_text("60")
  t.run_for(step_ms)
  assert_eq(calls.length() - before_leg_f, 4, msg="Interleaving F: 4th click 60 must NOT be swallowed")
  assert_eq(number(Some(calls[before_leg_f].1), "minutes"), 30.0)
  assert_eq(number(Some(calls[before_leg_f + 1].1), "minutes"), 60.0)
  assert_eq(number(Some(calls[before_leg_f + 2].1), "minutes"), 10.0)
  assert_eq(number(Some(calls[before_leg_f + 3].1), "minutes"), 60.0)
  (calls[before_leg_f + 2].2)(Ok(obj([("ok", Json::boolean(true))])))
  push_unversioned(10.0, "remind")
  t.draw()
  assert_eq(t.get(Radio, label="60").check, Some(On), msg="Interleaving F: topic(10, None) must NOT overwrite in-flight 60")
  (calls[before_leg_f + 3].2)(Ok(obj([("ok", Json::boolean(true))])))
  push_unversioned(60.0, "remind")
  t.run_for(@ui.move_most_ms)
  assert_eq(t.get(Radio, label="60").check, Some(On), msg="Interleaving F must settle on 60")
  t.assert_idle()

  // Interleaving G (strength-only snapshot on shared settings topic):
  // (a) Before first minutes echo: 20 -> click 30, 20 -> unrelated strength-only topic(20, "require") must NOT consume
  //     the queue or clear slot -> ack1 + topic(30, "require") -> click 30 issues 3rd RPC -> settles on 30.
  push_unversioned(20.0, "remind")
  t.draw()
  let before_leg_g1 = calls.length()
  t.tap_text("30")
  t.draw()
  t.tap_text("20")
  t.draw()
  assert_eq(calls.length() - before_leg_g1, 2)
  push_unversioned(20.0, "require")
  t.draw()
  (calls[before_leg_g1].2)(Ok(obj([("ok", Json::boolean(true))])))
  push_unversioned(30.0, "require")
  t.draw()
  assert_eq(t.get(Radio, label="20").check, Some(On), msg="Interleaving G1: strength-only 20 before echo must not break 30 echo")
  t.tap_text("30")
  t.draw()
  assert_eq(calls.length() - before_leg_g1, 3, msg="Interleaving G1: 3rd click 30 must NOT be swallowed")
  for i in (before_leg_g1 + 1)..<calls.length() {
    (calls[i].2)(Ok(obj([("ok", Json::boolean(true))])))
    push_unversioned(number(Some(calls[i].1), "minutes"), "require")
    t.draw()
  }
  t.run_for(2.0 * @ui.move_most_ms)
  assert_eq(t.get(Radio, label="30").check, Some(On), msg="Interleaving G1 must settle on 30")
  t.assert_idle()

  // (b) After coalesced minutes echo: 20 -> click 30, 60, 10 -> ack1, ack2 -> coalesced topic(60, "remind") ->
  //     unrelated strength-only topic(60, "require") (minutes unchanged at 60) must NOT clear in-flight 10 ->
  //     click 60 issues 4th RPC -> settles on 60.
  push_unversioned(20.0, "remind")
  t.draw()
  let before_leg_g2 = calls.length()
  t.tap_text("30")
  t.draw()
  t.tap_text("60")
  t.draw()
  t.tap_text("10")
  t.draw()
  assert_eq(calls.length() - before_leg_g2, 3)
  (calls[before_leg_g2].2)(Ok(obj([("ok", Json::boolean(true))])))
  (calls[before_leg_g2 + 1].2)(Ok(obj([("ok", Json::boolean(true))])))
  push_unversioned(60.0, "remind")
  t.draw()
  assert_eq(t.get(Radio, label="10").check, Some(On))
  push_unversioned(60.0, "require")
  t.draw()
  assert_eq(t.get(Radio, label="10").check, Some(On), msg="Interleaving G2: strength-only 60 after coalesced echo must NOT clear in-flight 10")
  t.tap_text("60")
  t.draw()
  assert_eq(calls.length() - before_leg_g2, 4, msg="Interleaving G2: 4th click 60 must NOT be swallowed")
  for i in (before_leg_g2 + 2)..<calls.length() {
    (calls[i].2)(Ok(obj([("ok", Json::boolean(true))])))
    push_unversioned(number(Some(calls[i].1), "minutes"), "require")
    t.draw()
  }
  t.run_for(2.0 * @ui.move_most_ms)
  assert_eq(t.get(Radio, label="60").check, Some(On), msg="Interleaving G2 must settle on 60")
  t.assert_idle()

  // Reset back to 20 before ok=false rollback & external 60 takeover checks
  push_unversioned(20.0, "remind")
  t.draw()
  assert_eq(t.get(Radio, label="20").check, Some(On))

  // Unversioned ok=false rollback to authority 20
  let before_leg_err = calls.length()
  t.tap_text("30")
  t.run_for(step_ms)
  assert_eq(t.get(Radio, label="30").check, Some(On))
  (calls[before_leg_err].2)(Err(obj([("message", str("fail"))])))
  t.run_for(@ui.move_most_ms)
  assert_eq(t.get(Radio, label="20").check, Some(On), msg="unversioned ok=false must roll back to authority 20")

  // External unversioned topic 60 arrives -> immediately shows 60
  push_unversioned(60.0, "remind")
  t.draw()
  assert_eq(t.get(Radio, label="60").check, Some(On), msg="unversioned external topic 60 must take over immediately")
  t.run_for(@ui.move_most_ms)
  t.assert_idle()
}

///|
test "Real new_profile_form_node: protocol A -> B -> A does not swallow second A and hands off cleanly by rev" {
  let topics : Map[String, @signals.Signal[@settings.Read]] = Map([])
  let gens : Map[String, Ref[(Int, Bool)]] = Map([])
  let calls : Array[(String, Json, (Result[Json, Json]) -> Unit)] = []
  let ver = Ref(1)
  let flow_json = fn(protocol : String, rev : Int) -> Json {
    obj([
      ("step", str("connect")),
      ("method", str("key")),
      ("showEndpoint", Json::boolean(false)),
      ("showKey", Json::boolean(false)),
      ("pending", Json::boolean(false)),
      ("canSubmit", Json::boolean(false)),
      ("protocol", str(protocol)),
      ("rev", Json::number(rev.to_double())),
      (
        "protocols",
        Json::array([
          obj([("id", str("responses")), ("label", str("Responses"))]),
          obj([("id", str("chat_completions")), ("label", str("Chat"))]),
        ]),
      ),
    ])
  }
  let flow_key = "profileFlow"
  let push_flow = fn(protocol : String, rev : Int) {
    gens[flow_key] = Ref((1, true))
    ver.val += 1
    let rd : @settings.Read = { value: Some(flow_json(protocol, rev)), error: None, version: ver.val }
    match topics.get(flow_key) {
      Some(s) => s.set(rd)
      None => topics[flow_key] = @signals.signal(rd)
    }
  }
  push_flow("responses", 1)
  let core = make_opt_test_core(topics, gens, calls)
  let np = @settings.new_profile_opened(core, "ws1/st1", None)
  let t = @ui.Tester::new(
    @ui.old_views_here,
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      @sf.presented_nodes(root)
    },
    w=390.0,
    h=500.0,
    platform=0,
    pointing=Mouse,
    native=Mouse,
  )
  @sf.set_words(@sfbase.fill)
  @ui.set_view_app(
    fn(root) {
      let d = fn() {
        let (name, params) = new_profile_flow_ask("ws1/st1", np.form)
        (core.topic)(name, params).get().value
      }
      new_profile_form_node(root, core, "ws1/st1", np, d, fn(_) { () })
    },
    theme=@sf.ui_theme_now,
  )
  t.draw()
  assert_eq(t.get(Radio, label="Responses").check, Some(On))
  // Rapid protocol A(Responses) -> B(Chat) -> A(Responses) before core replies
  t.tap_text("Chat")
  t.draw()
  assert_eq(t.get(Radio, label="Chat").check, Some(On), msg="protocol must switch optimistically to Chat")
  t.tap_text("Responses")
  t.draw()
  assert_eq(t.get(Radio, label="Responses").check, Some(On), msg="second click back to Responses must NOT be swallowed")
  let edit_calls = calls.filter(fn(c) { c.0 == "profile.flow.edit" })
  assert_eq(edit_calls.length(), 2, msg="A -> B -> A must issue exactly 2 profile.flow.edit RPCs")
  // Ack rev=2 (Chat) and intermediate topic rev=2 (Chat) must NOT roll back Responses
  (edit_calls[0].2)(Ok(obj([("rev", Json::number(2.0))])))
  push_flow("chat_completions", 2)
  t.draw()
  assert_eq(t.get(Radio, label="Responses").check, Some(On), msg="intermediate rev=2 (Chat) must NOT roll back Responses")
  // Ack rev=3 (Responses) and final topic rev=3 (Responses) -> clean handoff
  (edit_calls[1].2)(Ok(obj([("rev", Json::number(3.0))])))
  push_flow("responses", 3)
  t.run_for(@ui.move_most_ms)
  assert_eq(t.get(Radio, label="Responses").check, Some(On))
  assert_eq(t.drawn_glass().length(), 0)
  t.assert_idle()
}

///|
test "settings/home.mbt set_pref_with: stale failure does not clear newer pref choice" {
  @settings.reset()
  let cbs : Array[(Result[Json, Json]) -> Unit] = []
  let call = fn(_name : String, _params : Json, done : (Result[Json, Json]) -> Unit) { cbs.push(done) }
  @settings.set_pref_with(call, fn(_) { () }, "appearance", "light")
  @settings.set_pref_with(call, fn(_) { () }, "appearance", "dark")
  assert_eq(cbs.length(), 2)
  // First write fails late -> must NOT erase "dark".
  (cbs[0])(Err(obj([("message", str("net"))])))
  assert_eq(@settings.pref_from(None, "appearance"), "dark", msg="stale failure must not clear newer pref")
  @settings.reset()
}

///|
test "OptimisticChoice: versioned -> unversioned downgrade during core restart window" {
  let topics : Map[String, @signals.Signal[@settings.Read]] = Map([])
  let gens : Map[String, Ref[(Int, Bool)]] = Map([])
  let calls : Array[(String, Json, (Result[Json, Json]) -> Unit)] = []
  let ver = Ref(1)
  let push_topic = fn(ws : String, mins : Double, seq : Int64?, gen : Int, fresh : Bool) {
    let k = "settings:" + ws
    gens[k] = Ref((gen, fresh))
    ver.val += 1
    let rd : @settings.Read = { value: Some(settings_json(mins, "require", seq)), error: None, version: ver.val }
    match topics.get(k) {
      Some(s) => s.set(rd)
      None => topics[k] = @signals.signal(rd)
    }
  }
  push_topic("A", 10.0, Some(100L), 1, true)
  let core = make_opt_test_core(topics, gens, calls)
  let helper : Ref[OptimisticChoice[String, Double]?] = Ref(None)
  let t = @ui.Tester::new(fn(_c) {  }, w=320.0, h=120.0, dark=false, platform=0)
  @ui.set_view_app(fn(root) {
    root.box(fn(host) {
      let h = OptimisticChoice::new(
        host,
        core,
        fn() { "A" },
        "settings",
        fn(ws) { { "scope": str(ws) } },
        fn(v) {
          match number(v, "progressMinutes") {
            0.0 => 10.0
            n => n
          }
        },
        fn(v) { opt_seq(v, "progressSeq") },
      )
      helper.val = Some(h)
      host.box(fn(b) { b.words(By(fn() { h.get().to_int().to_string() })) |> ignore }) |> ignore
    })
    |> ignore
  })
  t.draw()
  let h = helper.val.unwrap()
  // Restart to gen=2 (fresh=false) before capability of new core is known:
  push_topic("A", 10.0, Some(100L), 2, false)
  t.draw()
  let cbs : Array[(Bool, Int64?) -> Unit] = []
  h.submit(30.0, fn(_, cb) { cbs.push(cb) })
  // First fresh frame of gen=2 is unversioned (seq=None) at baseline 10.0 -> must NOT drop in-flight 30.0!
  push_topic("A", 10.0, None, 2, true)
  t.draw()
  assert_eq(h.get(), 30.0, msg="restart downgrade first frame 10(None) must NOT clear in-flight 30")
  h.submit(10.0, fn(_, cb) { cbs.push(cb) })
  for cb in cbs {
    cb(true, None)
  }
  let final_val = if cbs.length() == 2 { 10.0 } else { 30.0 }
  push_topic("A", final_val, None, 2, true)
  t.draw()
  assert_true(cbs.length() == 2 && h.get() == 10.0, msg="downgrade RPCs=\{cbs.length()}, final=\{h.get()}")
}

///|
test "versioned: latest authority after coalesced return to baseline and late ACK" {
  let topics : Map[String, @signals.Signal[@settings.Read]] = Map([])
  let gens : Map[String, Ref[(Int, Bool)]] = Map([])
  let calls : Array[(String, Json, (Result[Json, Json]) -> Unit)] = []
  let ver = Ref(1)
  let push_settings = fn(mins : Double, strength : String, seq : Int64) {
    gens["settings:ws1"] = Ref((1, true))
    ver.val += 1
    let rd : @settings.Read = { value: Some(settings_json(mins, strength, Some(seq))), error: None, version: ver.val }
    match topics.get("settings:ws1") {
      Some(s) => s.set(rd)
      None => topics["settings:ws1"] = @signals.signal(rd)
    }
  }
  let ok_seq = fn(s : Int64) -> Json { obj([("ok", Json::boolean(true)), ("seq", Json::number(s.to_double()))]) }
  push_settings(20.0, "remind", 1L)
  let core = make_opt_test_core(topics, gens, calls)
  let show_page = @signals.signal(true)
  let here_val : Here = { workspace: "ws1", name: "WS", sub: "u1", email: "u@e", person: "U", picture: "" }
  let t = @ui.Tester::new(
    @ui.old_views_here,
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      @sf.presented_nodes(root)
    },
    w=390.0,
    h=700.0,
    platform=0,
    pointing=Mouse,
    native=Mouse,
  )
  @sf.set_words(@sfbase.fill)
  @ui.set_view_app(
    fn(root) {
      root.show(fn() { show_page.get() }, at_once=true, fn(host) {
        progress_node(host, core, fn() { here_val }, on_back=fn() { () }, frame=fn() { { back: None, top: 0.0, foot: 0.0, named: false } }, width=fn() { 390.0 })
      })
    },
    theme=@sf.ui_theme_now,
  )
  t.draw()
  t.tap_text("30")
  t.draw()
  t.tap_text("20")
  t.draw()
  assert_eq(calls.length(), 2)
  (calls[0].2)(Ok(ok_seq(2L)))
  // Both local writes have taken effect. Their one coalesced settings publication is back at 20 (seq=3).
  push_settings(20.0, "require", 3L)
  t.draw()
  // A newer write on another device changes the published minutes to 30 (seq=4).
  push_settings(30.0, "require", 4L)
  t.draw()
  (calls[1].2)(Ok(ok_seq(3L)))
  t.run_for(2.0 * @ui.move_most_ms)
  let twenty = t.get(Radio, label="20").check == Some(On)
  assert_true(!twenty && t.get(Radio, label="30").check == Some(On), msg="last authoritative minutes=30 (seq=4), selected 20=\{twenty}")
  t.assert_idle()

  // 3-tap burst external overwrite: 20(seq=4) -> tap 30 -> tap 20 -> tap 30 -> ack1(5), ack2(6) ->
  // coalesced push(30, seq=7) -> external push(20, seq=8) -> late ack3(seq=7) -> converges to 20.
  push_settings(20.0, "remind", 4L)
  t.draw()
  let before_3tap = calls.length()
  t.tap_text("30")
  t.draw()
  t.tap_text("20")
  t.draw()
  t.tap_text("30")
  t.draw()
  assert_eq(calls.length() - before_3tap, 3)
  (calls[before_3tap].2)(Ok(ok_seq(5L)))
  (calls[before_3tap + 1].2)(Ok(ok_seq(6L)))
  push_settings(30.0, "remind", 7L)
  t.draw()
  push_settings(20.0, "remind", 8L)
  t.draw()
  (calls[before_3tap + 2].2)(Ok(ok_seq(7L)))
  t.run_for(2.0 * @ui.move_most_ms)
  assert_eq(t.get(Radio, label="20").check, Some(On), msg="3-tap coalesced push(30, seq=7) + external push(20, seq=8) + late ack3(7) must converge to 20")
  t.assert_idle()
}

///|
test "versioned: acknowledgements during restart stop queue growth before first topic" {
  let topics : Map[String, @signals.Signal[@settings.Read]] = Map([])
  let gens : Map[String, Ref[(Int, Bool)]] = Map([])
  let calls : Array[(String, Json, (Result[Json, Json]) -> Unit)] = []
  let ver = Ref(1)
  let push_topic = fn(ws : String, mins : Double, seq : Int64?, gen : Int, fresh : Bool) {
    let k = "settings:" + ws
    gens[k] = Ref((gen, fresh))
    ver.val += 1
    let rd : @settings.Read = { value: Some(settings_json(mins, "require", seq)), error: None, version: ver.val }
    match topics.get(k) {
      Some(s) => s.set(rd)
      None => topics[k] = @signals.signal(rd)
    }
  }
  push_topic("A", 10.0, Some(100L), 1, true)
  let core = make_opt_test_core(topics, gens, calls)
  let helper : Ref[OptimisticChoice[String, Double]?] = Ref(None)
  let t = @ui.Tester::new(fn(_c) {  }, w=320.0, h=120.0, dark=false, platform=0)
  @ui.set_view_app(fn(root) {
    root.box(fn(host) {
      let h = OptimisticChoice::new(
        host,
        core,
        fn() { "A" },
        "settings",
        fn(ws) { { "scope": str(ws) } },
        fn(v) {
          match number(v, "progressMinutes") {
            0.0 => 10.0
            n => n
          }
        },
        fn(v) { opt_seq(v, "progressSeq") },
      )
      helper.val = Some(h)
      host.box(fn(b) { b.words(By(fn() { h.get().to_int().to_string() })) |> ignore }) |> ignore
    })
    |> ignore
  })
  t.draw()
  let h = helper.val.unwrap()
  // Restart to gen=2 (fresh=false) before capability of new core is known:
  push_topic("A", 10.0, Some(100L), 2, false)
  t.draw()
  for i in 0..<64 {
    let want = if i % 2 == 0 { 30.0 } else { 20.0 }
    h.submit(want, fn(_, cb) { cb(true, Some(1L + i.to_int64())) })
  }
  assert_eq(h.unversioned_queue.val.length(), 0, msg="versioned ACKs establish the new generation before its first topic")
}

///|
test "unversioned: click again after newest legacy ACK before settings publication" {
  let topics : Map[String, @signals.Signal[@settings.Read]] = Map([])
  let gens : Map[String, Ref[(Int, Bool)]] = Map([])
  let calls : Array[(String, Json, (Result[Json, Json]) -> Unit)] = []
  let ver = Ref(1)
  let push_unversioned = fn(mins : Double, strength : String) {
    gens["settings:ws1"] = Ref((1, true))
    ver.val += 1
    let rd : @settings.Read = { value: Some(settings_json(mins, strength, None)), error: None, version: ver.val }
    match topics.get("settings:ws1") {
      Some(s) => s.set(rd)
      None => topics["settings:ws1"] = @signals.signal(rd)
    }
  }
  push_unversioned(20.0, "remind")
  let core = make_opt_test_core(topics, gens, calls)
  let show_page = @signals.signal(true)
  let here_val : Here = { workspace: "ws1", name: "WS", sub: "u1", email: "u@e", person: "U", picture: "" }
  let t = @ui.Tester::new(
    @ui.old_views_here,
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      @sf.presented_nodes(root)
    },
    w=390.0,
    h=700.0,
    platform=0,
    pointing=Mouse,
    native=Mouse,
  )
  @sf.set_words(@sfbase.fill)
  @ui.set_view_app(
    fn(root) {
      root.show(fn() { show_page.get() }, at_once=true, fn(host) {
        progress_node(host, core, fn() { here_val }, on_back=fn() { () }, frame=fn() { { back: None, top: 0.0, foot: 0.0, named: false } }, width=fn() { 390.0 })
      })
    },
    theme=@sf.ui_theme_now,
  )
  t.draw()
  t.tap_text("30")
  t.draw()
  t.tap_text("60")
  t.draw()
  assert_eq(calls.length(), 2)
  (calls[0].2)(Ok(obj([("ok", Json::boolean(true))])))
  push_unversioned(30.0, "remind")
  t.draw()
  assert_eq(t.get(Radio, label="60").check, Some(On))
  (calls[1].2)(Ok(obj([("ok", Json::boolean(true))])))
  t.draw()
  let reverted_to_30 = t.get(Radio, label="30").check == Some(On)
  t.tap_text("30")
  t.draw()
  push_unversioned(60.0, "remind")
  t.draw()
  if calls.length() == 3 {
    assert_eq(number(Some(calls[2].1), "minutes"), 30.0)
    (calls[2].2)(Ok(obj([("ok", Json::boolean(true))])))
    push_unversioned(30.0, "remind")
  }
  t.run_for(2.0 * @ui.move_most_ms)
  let final_60 = t.get(Radio, label="60").check == Some(On)
  assert_true(!reverted_to_30 && calls.length() == 3 && !final_60, msg="reverted to 30 at second ACK=\{reverted_to_30}, RPCs=\{calls.length()}, final 60=\{final_60}")
}

///|
test "unversioned: third ACK after two FIFO echoes must not swallow a fourth tap" {
  let topics : Map[String, @signals.Signal[@settings.Read]] = Map([])
  let gens : Map[String, Ref[(Int, Bool)]] = Map([])
  let calls : Array[(String, Json, (Result[Json, Json]) -> Unit)] = []
  let ver = Ref(1)
  let push_unversioned = fn(mins : Double, strength : String) {
    gens["settings:ws1"] = Ref((1, true))
    ver.val += 1
    let rd : @settings.Read = { value: Some(settings_json(mins, strength, None)), error: None, version: ver.val }
    match topics.get("settings:ws1") {
      Some(s) => s.set(rd)
      None => topics["settings:ws1"] = @signals.signal(rd)
    }
  }
  push_unversioned(20.0, "remind")
  let core = make_opt_test_core(topics, gens, calls)
  let show_page = @signals.signal(true)
  let here_val : Here = { workspace: "ws1", name: "WS", sub: "u1", email: "u@e", person: "U", picture: "" }
  let t = @ui.Tester::new(
    @ui.old_views_here,
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      @sf.presented_nodes(root)
    },
    w=390.0,
    h=700.0,
    platform=0,
    pointing=Mouse,
    native=Mouse,
  )
  @sf.set_words(@sfbase.fill)
  @ui.set_view_app(
    fn(root) {
      root.show(fn() { show_page.get() }, at_once=true, fn(host) {
        progress_node(host, core, fn() { here_val }, on_back=fn() { () }, frame=fn() { { back: None, top: 0.0, foot: 0.0, named: false } }, width=fn() { 390.0 })
      })
    },
    theme=@sf.ui_theme_now,
  )
  t.draw()
  for label in ["30", "20", "30"] {
    t.tap_text(label)
    t.draw()
  }
  assert_eq(calls.length(), 3)
  let ok = obj([("ok", Json::boolean(true))])
  (calls[0].2)(Ok(ok))
  (calls[1].2)(Ok(ok))
  push_unversioned(30.0, "remind")
  t.draw()
  push_unversioned(20.0, "remind")
  t.draw()
  (calls[2].2)(Ok(ok))
  t.draw()
  let premature_20 = t.get(Radio, label="20").check == Some(On)
  t.tap_text("20")
  t.draw()
  push_unversioned(30.0, "remind")
  t.draw()
  if calls.length() == 4 {
    assert_eq(number(Some(calls[3].1), "minutes"), 20.0)
    (calls[3].2)(Ok(ok))
    push_unversioned(20.0, "remind")
  }
  t.run_for(2.0 * @ui.move_most_ms)
  let final_30 = t.get(Radio, label="30").check == Some(On)
  assert_true(!premature_20 && calls.length() == 4 && !final_30, msg="selected 20 at ACK3=\{premature_20}, calls=\{calls.length()}, final 30=\{final_30}")
}

///|
test "versioned: coalesced external write matching earlier click remains authoritative" {
  let topics : Map[String, @signals.Signal[@settings.Read]] = Map([])
  let gens : Map[String, Ref[(Int, Bool)]] = Map([])
  let calls : Array[(String, Json, (Result[Json, Json]) -> Unit)] = []
  let ver = Ref(1)
  let push_settings = fn(mins : Double, strength : String, seq : Int64) {
    gens["settings:ws1"] = Ref((1, true))
    ver.val += 1
    let rd : @settings.Read = { value: Some(settings_json(mins, strength, Some(seq))), error: None, version: ver.val }
    match topics.get("settings:ws1") {
      Some(s) => s.set(rd)
      None => topics["settings:ws1"] = @signals.signal(rd)
    }
  }
  let ok_seq = fn(s : Int64) -> Json { obj([("ok", Json::boolean(true)), ("seq", Json::number(s.to_double()))]) }
  push_settings(20.0, "remind", 1L)
  let core = make_opt_test_core(topics, gens, calls)
  let show_page = @signals.signal(true)
  let here_val : Here = { workspace: "ws1", name: "WS", sub: "u1", email: "u@e", person: "U", picture: "" }
  let t = @ui.Tester::new(
    @ui.old_views_here,
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      @sf.presented_nodes(root)
    },
    w=390.0,
    h=700.0,
    platform=0,
    pointing=Mouse,
    native=Mouse,
  )
  @sf.set_words(@sfbase.fill)
  @ui.set_view_app(
    fn(root) {
      root.show(fn() { show_page.get() }, at_once=true, fn(host) {
        progress_node(host, core, fn() { here_val }, on_back=fn() { () }, frame=fn() { { back: None, top: 0.0, foot: 0.0, named: false } }, width=fn() { 390.0 })
      })
    },
    theme=@sf.ui_theme_now,
  )
  t.draw()
  let stored = Ref(20.0)
  t.tap_text("30")
  t.draw()
  t.tap_text("60")
  t.draw()
  assert_eq(calls.length(), 2)
  stored.val = number(Some(calls[0].1), "minutes")
  (calls[0].2)(Ok(ok_seq(2L)))
  stored.val = number(Some(calls[1].1), "minutes")
  assert_eq(stored.val, 60.0)
  // A remote writer sets 30 (seq=4) before the one coalesced settings publication, then late ack2(seq=3) arrives.
  stored.val = 30.0
  push_settings(stored.val, "remind", 4L)
  t.draw()
  (calls[1].2)(Ok(ok_seq(3L)))
  t.run_for(2.0 * @ui.move_most_ms)
  let final_60 = t.get(Radio, label="60").check == Some(On)
  assert_true(t.get(Radio, label="30").check == Some(On), msg="core minutes=\{stored.val} (seq=4), final 60=\{final_60}")
  t.assert_idle()
}

///|
test "unversioned: a late settings push preserves the next explicit choice" {
  let topics : Map[String, @signals.Signal[@settings.Read]] = Map([])
  let gens : Map[String, Ref[(Int, Bool)]] = Map([])
  let calls : Array[(String, Json, (Result[Json, Json]) -> Unit)] = []
  let ver = Ref(1)
  let push_unversioned = fn(mins : Double, strength : String) {
    gens["settings:ws1"] = Ref((1, true))
    ver.val += 1
    let rd : @settings.Read = { value: Some(settings_json(mins, strength, None)), error: None, version: ver.val }
    match topics.get("settings:ws1") {
      Some(s) => s.set(rd)
      None => topics["settings:ws1"] = @signals.signal(rd)
    }
  }
  push_unversioned(20.0, "remind")
  let core = make_opt_test_core(topics, gens, calls)
  let show_page = @signals.signal(true)
  let here_val : Here = { workspace: "ws1", name: "WS", sub: "u1", email: "u@e", person: "U", picture: "" }
  let t = @ui.Tester::new(
    @ui.old_views_here,
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      @sf.presented_nodes(root)
    },
    w=390.0,
    h=700.0,
    platform=0,
    pointing=Mouse,
    native=Mouse,
  )
  @sf.set_words(@sfbase.fill)
  @ui.set_view_app(
    fn(root) {
      root.show(fn() { show_page.get() }, at_once=true, fn(host) {
        progress_node(host, core, fn() { here_val }, on_back=fn() { () }, frame=fn() { { back: None, top: 0.0, foot: 0.0, named: false } }, width=fn() { 390.0 })
      })
    },
    theme=@sf.ui_theme_now,
  )
  t.draw()
  t.tap_text("30")
  t.draw()
  let ok = obj([("ok", Json::boolean(true))])
  assert_eq(calls.length(), 1)
  (calls[0].2)(Ok(ok))
  let step_ms = 16.0
  for _ in 0..<16 {
    t.run_for(step_ms)
    assert_eq(t.get(Radio, label="30").check, Some(On), msg="delayed topic >250ms must never roll back to 20")
  }
  t.tap_text("20")
  t.draw()
  push_unversioned(30.0, "remind")
  t.draw()
  if calls.length() == 2 {
    assert_eq(number(Some(calls[1].1), "minutes"), 20.0)
    (calls[1].2)(Ok(ok))
    push_unversioned(20.0, "remind")
  }
  t.run_for(2.0 * @ui.move_most_ms)
  t.assert_idle()
  let final_30 = t.get(Radio, label="30").check == Some(On)
  assert_true(calls.length() == 2 && !final_30 && t.get(Radio, label="20").check == Some(On), msg="calls=\{calls.length()}, final 30=\{final_30}")
}

///|
test "unversioned: a strength-only publication after both ACKs preserves the next minute click" {
  let topics : Map[String, @signals.Signal[@settings.Read]] = Map([])
  let gens : Map[String, Ref[(Int, Bool)]] = Map([])
  let calls : Array[(String, Json, (Result[Json, Json]) -> Unit)] = []
  let ver = Ref(1)
  let push_unversioned = fn(mins : Double, strength : String) {
    gens["settings:ws1"] = Ref((1, true))
    ver.val += 1
    let rd : @settings.Read = { value: Some(settings_json(mins, strength, None)), error: None, version: ver.val }
    match topics.get("settings:ws1") {
      Some(s) => s.set(rd)
      None => topics["settings:ws1"] = @signals.signal(rd)
    }
  }
  push_unversioned(20.0, "remind")
  let core = make_opt_test_core(topics, gens, calls)
  let show_page = @signals.signal(true)
  let here_val : Here = { workspace: "ws1", name: "WS", sub: "u1", email: "u@e", person: "U", picture: "" }
  let t = @ui.Tester::new(
    @ui.old_views_here,
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      @sf.presented_nodes(root)
    },
    w=390.0,
    h=700.0,
    platform=0,
    pointing=Mouse,
    native=Mouse,
  )
  @sf.set_words(@sfbase.fill)
  @ui.set_view_app(
    fn(root) {
      root.show(fn() { show_page.get() }, at_once=true, fn(host) {
        progress_node(host, core, fn() { here_val }, on_back=fn() { () }, frame=fn() { { back: None, top: 0.0, foot: 0.0, named: false } }, width=fn() { 390.0 })
      })
    },
    theme=@sf.ui_theme_now,
  )
  t.draw()
  t.tap_text("30")
  t.draw()
  t.tap_text("20")
  t.draw()
  assert_eq(calls.length(), 2)
  let ok = obj([("ok", Json::boolean(true))])
  (calls[0].2)(Ok(ok))
  (calls[1].2)(Ok(ok))
  // Deliver the already queued strength-only publication, then the minute echoes in write order.
  push_unversioned(20.0, "require")
  t.draw()
  push_unversioned(30.0, "require")
  t.draw()
  let bounced = t.get(Radio, label="30").check == Some(On)
  t.tap_text("30")
  t.draw()
  push_unversioned(20.0, "require")
  t.draw()
  if calls.length() == 3 {
    assert_eq(number(Some(calls[2].1), "minutes"), 30.0)
    (calls[2].2)(Ok(ok))
    push_unversioned(30.0, "require")
  }
  t.run_for(2.0 * @ui.move_most_ms)
  t.assert_idle()
  let final_20 = t.get(Radio, label="20").check == Some(On)
  assert_true(!bounced && calls.length() == 3 && !final_20, msg="bounced to 30=\{bounced}, RPCs=\{calls.length()}, final 20=\{final_20}")
}

///|
test "completed two-click bursts returning to baseline retain bounded legacy history" {
  let topics : Map[String, @signals.Signal[@settings.Read]] = Map([])
  let gens : Map[String, Ref[(Int, Bool)]] = Map([])
  let calls : Array[(String, Json, (Result[Json, Json]) -> Unit)] = []
  let ver = Ref(1)
  let push_topic = fn(ws : String, mins : Double, seq : Int64?, gen : Int, fresh : Bool) {
    let k = "settings:" + ws
    gens[k] = Ref((gen, fresh))
    ver.val += 1
    let rd : @settings.Read = { value: Some(settings_json(mins, "require", seq)), error: None, version: ver.val }
    match topics.get(k) {
      Some(s) => s.set(rd)
      None => topics[k] = @signals.signal(rd)
    }
  }
  push_topic("A", 20.0, None, 1, true)
  push_topic("B", 20.0, None, 1, true)
  let core = make_opt_test_core(topics, gens, calls)
  let scope = @signals.signal("A")
  let mounted = @signals.signal(true)
  let helper : Ref[OptimisticChoice[String, Double]?] = Ref(None)
  let t = @ui.Tester::new(fn(_c) {  }, w=320.0, h=120.0, dark=false, platform=0)
  @ui.set_view_app(fn(root) {
    root.show(fn() { mounted.get() }, at_once=true, fn(host) {
      let h = OptimisticChoice::new(
        host,
        core,
        fn() { scope.get() },
        "settings",
        fn(ws) { { "scope": str(ws) } },
        fn(v) {
          match number(v, "progressMinutes") {
            0.0 => 10.0
            n => n
          }
        },
        fn(v) { opt_seq(v, "progressSeq") },
      )
      helper.val = Some(h)
      host.box(fn(b) { b.words(By(fn() { h.get().to_int().to_string() })) |> ignore }) |> ignore
    })
  })
  t.draw()
  let h = helper.val.unwrap()
  let sent = Ref(0)
  let pair = fn() {
    h.submit(30.0, fn(_, done) { sent.val += 1; done(true, None) })
    h.submit(20.0, fn(_, done) { sent.val += 1; done(true, None) })
    push_topic("A", 20.0, None, 1, true)
    t.draw()
  }
  for _ in 0..<32 { pair() }
  let after32 = h.unversioned_queue.val.length()
  for _ in 0..<32 { pair() }
  let after64 = h.unversioned_queue.val.length()
  assert_eq(sent.val, 128)
  assert_eq(h.get(), 20.0)
  assert_true(after64 <= after32 && after64 <= 2, msg="32 completed pairs=\{after32} entries, 64 pairs=\{after64}, pending=\{h.is_pending()}")
}

///|
test "legacy: click after both ACKs before the first FIFO echo" {
  let topics : Map[String, @signals.Signal[@settings.Read]] = Map([])
  let gens : Map[String, Ref[(Int, Bool)]] = Map([])
  let calls : Array[(String, Json, (Result[Json, Json]) -> Unit)] = []
  let ver = Ref(1)
  let push_unversioned = fn(mins : Double, strength : String) {
    gens["settings:ws1"] = Ref((1, true))
    ver.val += 1
    let rd : @settings.Read = { value: Some(settings_json(mins, strength, None)), error: None, version: ver.val }
    match topics.get("settings:ws1") {
      Some(s) => s.set(rd)
      None => topics["settings:ws1"] = @signals.signal(rd)
    }
  }
  push_unversioned(20.0, "remind")
  let core = make_opt_test_core(topics, gens, calls)
  let show_page = @signals.signal(true)
  let here_val : Here = { workspace: "ws1", name: "WS", sub: "u1", email: "u@e", person: "U", picture: "" }
  let t = @ui.Tester::new(
    @ui.old_views_here,
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      @sf.presented_nodes(root)
    },
    w=390.0,
    h=700.0,
    platform=0,
    pointing=Mouse,
    native=Mouse,
  )
  @sf.set_words(@sfbase.fill)
  @ui.set_view_app(
    fn(root) {
      root.show(fn() { show_page.get() }, at_once=true, fn(host) {
        progress_node(host, core, fn() { here_val }, on_back=fn() { () }, frame=fn() { { back: None, top: 0.0, foot: 0.0, named: false } }, width=fn() { 390.0 })
      })
    },
    theme=@sf.ui_theme_now,
  )
  t.draw()
  let ok = obj([("ok", Json::boolean(true))])
  for label in ["30", "20"] { t.tap_text(label); t.draw() }
  let acked = 2
  for i in 0..<acked { (calls[i].2)(Ok(ok)) }
  t.tap_text("60")
  t.draw()
  let before = calls.length()
  assert_eq(before, 3)
  push_unversioned(30.0, "remind")
  t.draw()
  let rolled_back = t.get(Radio, label="30").check == Some(On)
  t.tap_text("30")
  t.draw()
  let sent = calls.length()
  for i in 1..<sent {
    if i >= acked { (calls[i].2)(Ok(ok)) }
    push_unversioned(number(Some(calls[i].1), "minutes"), "remind")
    t.draw()
  }
  t.run_for(2.0 * @ui.move_most_ms)
  t.assert_idle()
  let final_30 = t.get(Radio, label="30").check == Some(On)
  assert_true(!rolled_back && sent == before + 1 && final_30, msg="rolled back to first echo=\{rolled_back}, RPCs=\{sent}, expected=\{before + 1}, final 30=\{final_30}")
}

///|
test "legacy: delayed first FIFO echo when 33 writes have been submitted" {
  let topics : Map[String, @signals.Signal[@settings.Read]] = Map([])
  let gens : Map[String, Ref[(Int, Bool)]] = Map([])
  let calls : Array[(String, Json, (Result[Json, Json]) -> Unit)] = []
  let ver = Ref(1)
  let push_unversioned = fn(mins : Double, strength : String) {
    gens["settings:ws1"] = Ref((1, true))
    ver.val += 1
    let rd : @settings.Read = { value: Some(settings_json(mins, strength, None)), error: None, version: ver.val }
    match topics.get("settings:ws1") {
      Some(s) => s.set(rd)
      None => topics["settings:ws1"] = @signals.signal(rd)
    }
  }
  push_unversioned(20.0, "remind")
  let core = make_opt_test_core(topics, gens, calls)
  let show_page = @signals.signal(true)
  let here_val : Here = { workspace: "ws1", name: "WS", sub: "u1", email: "u@e", person: "U", picture: "" }
  let t = @ui.Tester::new(
    @ui.old_views_here,
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      @sf.presented_nodes(root)
    },
    w=390.0,
    h=700.0,
    platform=0,
    pointing=Mouse,
    native=Mouse,
  )
  @sf.set_words(@sfbase.fill)
  @ui.set_view_app(
    fn(root) {
      root.show(fn() { show_page.get() }, at_once=true, fn(host) {
        progress_node(host, core, fn() { here_val }, on_back=fn() { () }, frame=fn() { { back: None, top: 0.0, foot: 0.0, named: false } }, width=fn() { 390.0 })
      })
    },
    theme=@sf.ui_theme_now,
  )
  t.draw()
  let ok = obj([("ok", Json::boolean(true))])
  t.tap_text("30")
  t.draw()
  for i in 0..<32 {
    t.tap_text(if i % 2 == 0 { "10" } else { "60" })
    t.draw()
  }
  let before = calls.length()
  assert_eq(before, 33)
  let acked = 1
  (calls[0].2)(Ok(ok))
  push_unversioned(30.0, "remind")
  t.draw()
  let rolled_back = t.get(Radio, label="30").check == Some(On)
  t.tap_text("30")
  t.draw()
  let sent = calls.length()
  for i in 1..<sent {
    if i >= acked { (calls[i].2)(Ok(ok)) }
    push_unversioned(number(Some(calls[i].1), "minutes"), "remind")
    t.draw()
  }
  t.run_for(2.0 * @ui.move_most_ms)
  t.assert_idle()
  let final_30 = t.get(Radio, label="30").check == Some(On)
  assert_true(!rolled_back && sent == before + 1 && final_30, msg="rolled back to first echo=\{rolled_back}, RPCs=\{sent}, expected=\{before + 1}, final 30=\{final_30}")
}
