// Exhaustive tests for `chat_entry_policy` and regression tests for:
// - Bug A: `Feedback` bypassing send-flight barrier staging when arriving mid-flight.
// - Bug B: `CacheCold` / `Archived` / `Feedback` missing predecessor-change rekeying.

///|
fn policy_test_feedback_json() -> Json {
  Json::object({
    "reports": Json::array([
      Json::object({
        "id": Json::string("fb-1"),
        "number": Json::number(42.0),
        "latestId": Json::string("rep-1"),
        "dismissed": Json::boolean(false),
        "replies": Json::array([
          Json::object({
            "id": Json::string("rep-1"),
            "from": Json::string("team"),
            "text": Json::string("已修复"),
          }),
        ]),
      }),
    ]),
  })
}

///|
test "chat_entry_policy covers all 14 Entry variants accurately" {
  let msg_mine : Message = { ..chat_body_none, mine: true, said: true }
  let msg_other : Message = { ..chat_body_none, mine: false, said: false }
  let ag_started : Agent = { ..@sfbase.agent_of({}), key: "a1", started: true }
  let ag_idle : Agent = { ..@sfbase.agent_of({}), key: "a2", started: false }
  let sent_else : Elsewhere = @sfbase.elsewhere_of({})

  // Structural non-list items
  for e in [Entry::Top, Entry::Foot] {
    let p = chat_entry_policy(e)
    assert_eq(p.stage.lane, @motion.StageLane::Structural)
    assert_eq(p.stage.during_barrier, @motion.StageDuringBarrier::Keep)
    assert_false(p.in_list)
    assert_false(p.stage.live_removable)
    assert_false(p.stage.rekey_on_prev_change)
    assert_true(p.follow_role is ChatFollowRole::Ignore)
    assert_true(p.live_role is ChatLiveRole::LiveNever)
  }

  // Older
  let p_older = chat_entry_policy(Entry::Older(""))
  assert_eq(p_older.stage.lane, @motion.StageLane::Structural)
  assert_true(p_older.in_list)
  assert_false(p_older.stage.hold_as_anchor)
  assert_false(p_older.stage.live_removable)
  assert_true(p_older.follow_role is ChatFollowRole::CapAtTop)

  // Empty, Line, Newer
  for e in [Entry::Empty, Entry::Line, Entry::Newer] {
    let p = chat_entry_policy(e)
    assert_eq(p.stage.lane, @motion.StageLane::Structural)
    assert_true(p.in_list)
    assert_true(p.stage.hold_as_anchor)
    assert_false(p.stage.live_removable)
    assert_true(p.live_role is ChatLiveRole::LiveNever)
  }
  assert_true(chat_entry_policy(Entry::Newer).follow_role is ChatFollowRole::Ignore)
  assert_true(chat_entry_policy(Entry::Line).follow_role is ChatFollowRole::CapAtTop)

  // Content: Said, Sent, Out
  let p_mine = chat_entry_policy(Entry::Said(msg_mine))
  assert_eq(p_mine.stage.lane, @motion.StageLane::Content)
  assert_true(p_mine.comes)
  assert_true(p_mine.follow_role is ChatFollowRole::ToFoot)
  assert_true(p_mine.live_role is ChatLiveRole::LiveWhenSaid)
  assert_true(p_mine.stage.live_removable)

  let p_other = chat_entry_policy(Entry::Said(msg_other))
  assert_false(p_other.comes)
  assert_true(p_other.follow_role is ChatFollowRole::CapAtTop)

  let p_sent = chat_entry_policy(Entry::Sent(sent_else))
  assert_eq(p_sent.stage.lane, @motion.StageLane::Content)
  assert_false(p_sent.comes)
  assert_true(p_sent.live_role is ChatLiveRole::LiveNever)

  let p_out = chat_entry_policy(Entry::Out(chat_body_no_out))
  assert_eq(p_out.stage.lane, @motion.StageLane::Content)
  assert_true(p_out.comes)
  assert_true(p_out.follow_role is ChatFollowRole::ToFoot)
  assert_true(p_out.live_role is ChatLiveRole::LiveAlways)

  // Activity: Working
  let p_w1 = chat_entry_policy(Entry::Working(ag_started))
  assert_eq(p_w1.stage.lane, @motion.StageLane::Activity)
  assert_eq(p_w1.stage.during_barrier, @motion.StageDuringBarrier::CoMoveWithBarrier)
  assert_false(p_w1.stage.rekey_on_prev_change)
  assert_true(p_w1.is_tail_slot)
  assert_true(p_w1.comes)
  assert_true(p_w1.leaves_room)
  assert_true(p_w1.follow_role is ChatFollowRole::Ignore)
  assert_true(p_w1.live_role is ChatLiveRole::LiveWhenStarted)
  assert_false(chat_entry_policy(Entry::Working(ag_idle)).comes)

  // Trailers: State, CacheCold, Archived, Feedback
  for
    e in [
      Entry::State("ok", "", ""),
      Entry::CacheCold("s1", "cold", "", false),
      Entry::Archived,
      Entry::Feedback,
    ] {
    let p = chat_entry_policy(e)
    assert_eq(p.stage.lane, @motion.StageLane::Trailer)
    assert_eq(p.stage.during_barrier, @motion.StageDuringBarrier::DeferUntilBarriers)
    assert_true(p.stage.rekey_on_prev_change)
    assert_true(p.stage.hold_as_anchor)
    assert_true(p.stage.live_removable)
    assert_true(p.is_tail_slot)
    assert_true(p.comes)
    assert_true(p.follow_role is ChatFollowRole::Ignore)
    assert_true(p.live_role is ChatLiveRole::LiveAlways)
    assert_false(p.leaves_room)
  }
  assert_true(chat_entry_policy(Entry::State("", "", "")).hide_on_online_send)
  assert_true(chat_entry_policy(Entry::CacheCold("", "", "", false)).hide_on_online_send)
  assert_true(chat_entry_policy(Entry::Archived).hide_on_online_send)
  assert_false(chat_entry_policy(Entry::Feedback).hide_on_online_send)

  // Key-based helpers align bidirectionally with policy table across all 14 Entry variants
  let all_entries : Array[Entry] = [
    Entry::Top,
    Entry::Older(""),
    Entry::Empty,
    Entry::Line,
    Entry::Said(msg_mine),
    Entry::Sent(sent_else),
    Entry::Newer,
    Entry::Out(chat_body_no_out),
    Entry::State("ok", "", ""),
    Entry::Working(ag_started),
    Entry::CacheCold("s1", "cold", "", false),
    Entry::Archived,
    Entry::Feedback,
    Entry::Foot,
  ]
  for e in all_entries {
    let p = chat_entry_policy(e)
    let id = e.id()
    assert_eq(p.stage.rekey_on_prev_change, chat_key_rekeys_on_prev_change(id))
    assert_eq(p.stage.live_removable, chat_key_live_removable(id))
    assert_eq(p.stage.hold_as_anchor, chat_key_hold_as_anchor(id))
  }
  assert_false(chat_key_live_removable("wait"))
}

///|
test "Bug A regression: Feedback arriving mid-flight is held until send lands" {
  @sfbase.reset()
  reset()
  let src = body_src("chat")
  guard body_read(src) is Some((v0, read0)) else { fail("no view") }
  let view = @signals.signal(v0)
  let entries = @signals.signal(read0)
  let fb_sig : @signals.Signal[Json?] = @signals.signal(None)
  let fb_held = @signals.computed(fn(_) { fb_sig.get() })
  let made_keys : Array[String] = []
  let views : Map[String, @view.View] = Map([])
  @sf.set_words(@sfbase.fill)
  absolute_times.set(false)
  let t = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      let here : MessageNodeHere = {
        station: body_ref.station,
        session: body_ref.session,
        view: fn() { view.get() },
        width: fn() { 900.0 },
        tips,
        stint: fn() { 0 },
        jump: None,
        picture: None,
      }
      root.box(fn(f) {
        f.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        chat_body_node(
          f,
          src,
          here,
          fn() { entries.get() },
          sending=fn() { @sfbase.sending_now(body_ref.station + "\u{1}" + body_ref.session) },
          core=Some(@sfbase.settings_core(src, body_ws)),
          foot=fn() { body_foot(view.get()) },
          made=fn(k, p) {
            made_keys.push(k)
            body_view_holds(views, k, p)
          },
          feedback_held=fb_held,
        )
        |> ignore
      })
      |> ignore
      @sf.presented_nodes(root)
    },
    w=900.0,
    h=760.0,
    platform=0,
    scale=2.0,
  )
  t.set_rows_on_pixels(true)
  t.run_for(@ui.move_most_ms)

  // Start a flying local send from the composer
  let chat_key = body_ref.station + "\u{1}" + body_ref.session
  let _ = @sfbase.sent_local(
    chat_key,
    Some(v0),
    "hello flight",
    [],
    from=Some({ words: Some((120.0, 680.0)), words_room: None, quote_ids: [], parts: [], delay: 0.0 }),
    now=(src.now)(),
  )
  let mid_flight_ms = @sfbase.flight_desk_ms / 4.0
  t.run_for(mid_flight_ms)

  // Mid-flight (well before flight_desk_ms): chatFeedback arrives
  fb_sig.set(Some(policy_test_feedback_json()))
  t.run_for(mid_flight_ms)
  let mid_has_feedback = views.keys().iter().any(fn(k) {
    (k == "feedback" || k.has_prefix("feedback:")) && views[k].alive() && !views[k].shown_nowhere()
  })
  assert_false(mid_has_feedback)

  // After flight lands, feedback is released automatically
  t.run_for(@sfbase.flight_desk_ms + @ui.move_most_ms)
  let end_has_feedback = views.keys().iter().any(fn(k) {
    (k == "feedback" || k.has_prefix("feedback:")) && views[k].alive() && !views[k].shown_nowhere()
  })
  assert_true(end_has_feedback)
}

///|
test "Bug B regression: State, CacheCold, Archived, and Feedback rekey on predecessor change" {
  @sfbase.reset()
  reset()
  let src = body_src("chat")
  guard body_read(src) is Some((v0, read0)) else { fail("no view") }

  // Build entries with State, CacheCold, Archived at the tail plus Feedback via feedback_held
  let base_entries = read0.filter(fn(e) { !(e is Foot) })
  let init_entries = base_entries.copy()
  init_entries.push(Entry::State("ok", "", ""))
  init_entries.push(Entry::CacheCold("s1", "cold", "", false))
  init_entries.push(Entry::Archived)
  init_entries.push(Entry::Foot)

  let view = @signals.signal(v0)
  let entries = @signals.signal(init_entries)
  let fb_sig : @signals.Signal[Json?] = @signals.signal(Some(policy_test_feedback_json()))
  let fb_held = @signals.computed(fn(_) { fb_sig.get() })
  let list_ref : Ref[ChatBodyList?] = Ref(None)
  let made_keys : Array[String] = []
  @sf.set_words(@sfbase.fill)
  absolute_times.set(false)
  let t = @ui.Tester::new(
    fn(c) {
      @sf.begin(c) |> ignore
      c.with_theme(@sf.ui_theme(), fn() { @ui.old_views_here(c) })
    },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      let tips = @sf.TipLayer::new(fn() { Some(root) })
      let here : MessageNodeHere = {
        station: body_ref.station,
        session: body_ref.session,
        view: fn() { view.get() },
        width: fn() { 900.0 },
        tips,
        stint: fn() { 0 },
        jump: None,
        picture: None,
      }
      root.box(fn(f) {
        f.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        chat_body_node(
          f,
          src,
          here,
          fn() { entries.get() },
          sending=fn() { @sfbase.sending_now(body_ref.station + "\u{1}" + body_ref.session) },
          core=Some(@sfbase.settings_core(src, body_ws)),
          foot=fn() { body_foot(view.get()) },
          made=fn(k, _) { made_keys.push(k) },
          read=fn(_, _, l, _, _) { list_ref.val = Some(l) },
          feedback_held=fb_held,
        )
        |> ignore
      })
      |> ignore
      @sf.presented_nodes(root)
    },
    w=900.0,
    h=760.0,
    platform=0,
    scale=2.0,
  )
  t.set_rows_on_pixels(true)
  t.run_for(@ui.move_most_ms)

  // Insert a new message before all four trailers
  let extra_msg : Message = { ..chat_body_none, ts: "999999.000", seq: 9999.0, mine: true, text: "新来一条消息", said: true }
  let next_entries = base_entries.copy()
  next_entries.push(Entry::Said(extra_msg))
  next_entries.push(Entry::State("ok", "", ""))
  next_entries.push(Entry::CacheCold("s1", "cold", "", false))
  next_entries.push(Entry::Archived)
  next_entries.push(Entry::Foot)
  entries.set(next_entries)
  t.run_for(@ui.move_most_ms)

  guard list_ref.val is Some(bl) else { fail("no ChatBodyList") }
  let ks = @signals.untracked(bl.keys)
  assert_true(ks.contains("state:1"))
  assert_true(ks.contains("cache_cold:1"))
  assert_true(ks.contains("archived:1"))
  assert_true(ks.contains("feedback:1"))
  // Aliased keys resolve both row and slices properly
  for ak in ["state:1", "cache_cold:1", "archived:1", "feedback:1"] {
    assert_true(@signals.untracked(fn() { (bl.row)(ak) }) is Some(_))
    assert_eq(@signals.untracked(fn() { (bl.slices)(ak) }), 1)
  }
}
