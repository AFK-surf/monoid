// The app asks the core for only the chat data its page uses, while other topics keep their own parameters.

///|
test "a chat asks the core for a compact view" {
  let params : Map[String, Json] = { "station": "w/s", "session": "k" }
  let chat = core_topic_params("chat", params)
  assert_eq(chat.get("compact"), Some(Json::boolean(true)))
  assert_eq(chat.get("session"), Some(Json::string("k")))
  assert_true(params.get("compact") is None)
  assert_eq(core_topic_params("chatJobs", params).get("compact"), Some(Json::boolean(true)))
  assert_eq(core_topic_params("history", params).get("compact"), None)
}

///|
test "Source::owned_by auto-parks on deep park, faults on parked Raw read, and non-Chat leave/wake has 0 faults" {
  let prev_stop = @view.faults_stop.val
  let prev_told = @view.fault_told.val
  let faults : Array[String] = []
  @view.faults_stop.val = false
  @view.fault_told.val = Some(fn(said) { faults.push(said) })
  let val = @signals.signal(Json::string("v1"))
  let base : Source = {
    ..made_source(),
    topic_read: fn(_name, _params) { { value: Some(val.get()), error: None, version: 1 } },
  }
  let active_tab = @signals.signal(0)
  let owned_ref : Ref[Source?] = Ref(None)
  let seen : Ref[String] = Ref("")
  let t = @ui.Tester::tree(
    fn(root) {
      root.pick_kept(at_once=true, fn() { active_tab.get() }, fn(page, k) {
        if k == 0 {
          let owned = base.owned_by(page)
          owned_ref.val = Some(owned)
          page.reacts(fn() { owned.topic("status", {}).get().value }, fn(v) {
            seen.val = match v {
              Some(String(s)) => s
              _ => ""
            }
          })
        }
      })
    },
    keeps_sources=true,
  )
  t.draw()
  let owned = owned_ref.val.unwrap()
  assert_eq(seen.val, "v1")
  assert_eq(owned.prefetch("status", {}).value, Some(Json::string("v1")))
  assert_eq(faults, [], msg="active read should produce 0 faults")
  // Deep-parking a non-Chat page via pick_kept produces 0 faults on the leave frame.
  active_tab.set(1)
  t.draw()
  assert_eq(faults, [], msg="non-Chat page leaving/parking frame must produce 0 faults")
  // Raw read while parked triggers @view.fault_told instead of silently returning None.
  let parked_res = owned.prefetch("status", {})
  assert_true(parked_res.value is None)
  assert_true(
    faults.any(fn(s) { s.contains("parked-source-raw-read: status") }),
    msg="expected parked-source-raw-read fault, got: \{Repr(faults)}",
  )
  faults.clear()
  // Even when another active Graph watcher holds the same topic, a parked Raw read via `topic().get()`
  // must NOT bypass the parked guard via the watched-topic cache shortcut.
  let watch = @signals.watch(fn() {  })
  let active_watcher = owned.topic("status2", {})
  watch.read(fn() { active_watcher.get() }) |> ignore
  let parked_topic_res = owned.topic("status2", {}).get()
  assert_true(parked_topic_res.value is None)
  assert_true(
    faults.any(fn(s) { s.contains("parked-source-raw-read: status2") }),
    msg="parked Raw topic().get() must fault even with active watched holder, got: \{Repr(faults)}",
  )
  watch.stop()
  faults.clear()
  // Waking restores owner in pre-order before descendants re-read: 0 faults, fresh value seen.
  val.set(Json::string("v2"))
  active_tab.set(0)
  t.draw()
  assert_eq(faults, [], msg="waking parked page must produce 0 faults")
  assert_eq(seen.val, "v2")
  assert_eq(owned.prefetch("status", {}).value, Some(Json::string("v2")))
  // Chat path: owned_by_parkable(auto_park=false) does not auto-park on pick_kept rest,
  // and manual park returns None without faulting (so Chat failure callbacks like composer stay safe).
  let chat_tab = @signals.signal(0)
  let chat_owned_ref : Ref[Source?] = Ref(None)
  let chat_park_ref : Ref[((Bool) -> Unit)?] = Ref(None)
  let t2 = @ui.Tester::tree(
    fn(root) {
      root.pick_kept(at_once=true, fn() { chat_tab.get() }, fn(page, k) {
        if k == 0 {
          let (co, park) = base.owned_by_parkable(page, auto_park=false)
          chat_owned_ref.val = Some(co)
          chat_park_ref.val = Some(park)
        }
      })
    },
    keeps_sources=true,
  )
  t2.draw()
  chat_tab.set(1)
  t2.draw()
  assert_eq(chat_owned_ref.val.unwrap().prefetch("chat", {}).value, Some(Json::string("v2")))
  assert_eq(faults, [], msg="auto_park=false must not auto-park on pick_kept rest")
  (chat_park_ref.val.unwrap())(true)
  assert_true(chat_owned_ref.val.unwrap().prefetch("chat", {}).value is None)
  assert_eq(faults, [], msg="manual auto_park=false park must return None without faulting")
  @view.faults_stop.val = prev_stop
  @view.fault_told.val = prev_told
  @ui.run_let_go()
}

///|
test "window_text -> window_page is pure, preserves owner, and child-process screen window tri-state Waiting/Matched/Denied" {
  reset()
  accounts_subs_sync(["acct-a", "acct-b"])
  workspace_owner_set("ws-1", "acct-a")
  let page = Page::Screen({ station: "ws-1/st-1", screen: "browser:win-1", title: "Win", until_gone: false })
  let encoded = window_text(page).unwrap()
  assert_true(encoded.contains("\"owner\":\"acct-a\""), msg="window_text must serialize creation owner")
  // Pure parser: calling window_page does not mutate startup_window_owner.
  assert_true(window_page(encoded) == Some(page))
  assert_true(startup_window_owner.val is None, msg="window_page must be pure with no global side effects")
  assert_eq(window_page_owner_of(encoded), Some("acct-a"))
  // Simulate child-process cold start: accounts_subs_sync has acct-a, but NO workspaces snapshot yet -> Waiting!
  reset()
  accounts_subs_sync(["acct-a"])
  set_startup_window_owner(window_page_owner_of(encoded))
  assert_true(window_here_owner_state(0, "ws-1/st-1", screen="browser:win-1") == Waiting, msg="child-process window must Wait before workspaces snapshot, never fallback to subs[0]")
  assert_false(window_here_owner_matches(0, "ws-1/st-1", screen="browser:win-1"))
  // Offline cached workspaces snapshot (loaded=false, non-blocked) carrying ws-1 -> acct-a:
  // aligned with Core recomputeOwners() so offline/503 mesh remains usable (Matched, not stuck Waiting).
  let snap_offline : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(false),
    }),
  ])
  workspace_owners_sync_json(Some(snap_offline))
  assert_true(workspace_owners_synced(), msg="first valid workspaces snapshot marks workspace_owners_synced")
  assert_eq(workspace_explicit_owner_of("ws-1"), Some("acct-a"), msg="offline cached ws-1 must resolve to acct-a")
  assert_false(workspace_is_pending("ws-1"), msg="Owned ws-1 must not also be Pending (strict 3-state mutual exclusion)")
  assert_true(window_here_owner_state(0, "ws-1/st-1", screen="browser:win-1") == Matched, msg="offline cached snapshot must Match for mesh continuity")
  // Complete workspaces snapshot arrives (loaded=true) containing ws-1 -> acct-a: stays Matched!
  let snap_a : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(true),
    }),
  ])
  workspace_owners_sync_json(Some(snap_a))
  assert_true(window_here_owner_state(0, "ws-1/st-1", screen="browser:win-1") == Matched, msg="child-process window must Match once snapshot confirms ws-1 -> acct-a")
  assert_true(window_here_owner_matches(0, "ws-1/st-1", screen="browser:win-1"))
  // Workspace switches to acct-b -> Denied!
  workspace_owner_set("ws-1", "acct-b")
  assert_true(window_here_owner_state(0, "ws-1/st-1") == Denied, msg="child-process window must be Denied on owner mismatch")
  // First complete snapshot arrives WITHOUT ws-1 -> Denied!
  reset()
  accounts_subs_sync(["acct-a"])
  set_startup_window_owner(Some("acct-a"))
  let snap_empty : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([]),
      "loaded": Json::boolean(true),
    }),
  ])
  workspace_owners_sync_json(Some(snap_empty))
  assert_true(window_here_owner_state(0, "ws-1/st-1") == Denied, msg="complete snapshot missing ws-1 must Deny child-process window")
  // Missing owner field in MBUI_WINDOW payload -> Denied!
  let no_owner = "{\"screen\":{\"station\":\"ws-1/st-1\",\"screen\":\"browser:win-1\",\"title\":\"Win\"}}"
  assert_eq(window_page_owner_of(no_owner), Some(""))
  set_startup_window_owner(window_page_owner_of(no_owner))
  assert_true(window_here_owner_state(0, "ws-1/st-1") == Denied, msg="missing owner must Deny child-process window")
  // In-process secondary window transient opening owner is bound to exact (station, screen, owner, claimed_wid)
  // with NO empty-screen wildcard, single-wid claim, and explicit workspace ownership (no first-account fallback).
  reset()
  accounts_subs_sync(["acct-a"])
  workspace_owner_set("ws-1", "acct-a")
  windows_here_opening_owner.val = Some(("ws-1/st-1", "browser:win-1", "acct-a", None))
  assert_true(window_here_owner_state(1, "ws-1/st-1", screen="") == Denied, msg="empty screen must never match opening owner")
  assert_true(window_here_owner_state(1, "ws-1/st-1", screen="browser:win-1") == Matched, msg="first unregistered wid with matching station+screen must Match and claim")
  assert_true(window_here_owner_state(1, "ws-1/st-1", screen="browser:win-1") == Matched, msg="same claimed wid must continue to Match")
  assert_true(window_here_owner_state(2, "ws-1/st-1", screen="browser:win-1") == Denied, msg="second unregistered wid with same station+screen must be Denied after claim")
  assert_true(window_here_owner_state(1, "ws-1/st-1", screen="browser:win-2") == Denied, msg="different screen on same station during opening must be Denied")
  assert_true(window_here_owner_state(2, "ws-2/st-2", screen="browser:win-1") == Denied, msg="different station during opening must be Denied")
  windows_here_opening_owner.val = Some(("ws-1/st-1", "browser:win-1", "", None))
  assert_true(window_here_owner_state(1, "ws-1/st-1", screen="browser:win-1") == Denied, msg="empty opening owner must be Denied")
  // Before complete snapshot (!workspace_owners_synced), unmapped workspace for wid > 0 waits (never Matched);
  // after complete snapshot, missing explicit workspace owner is Denied even if fallback account matches.
  windows_here_opening_owner.val = Some(("ws-unmapped/st-1", "browser:win-1", "acct-a", None))
  assert_true(window_here_owner_state(1, "ws-unmapped/st-1", screen="browser:win-1") == Waiting, msg="unmapped workspace before first snapshot must Wait, never Match")
  workspace_owners_sync_json(Some(snap_a))
  assert_true(window_here_owner_state(1, "ws-unmapped/st-1", screen="browser:win-1") == Denied, msg="missing explicit workspace owner after snapshot must be Denied even if fallback account matches")
  windows_here_opening_owner.val = None
  // Unknown secondary window id (`wid > 0`) -> Denied!
  assert_true(window_here_owner_state(999, "ws-1/st-1", screen="browser:win-1") == Denied, msg="unknown secondary window id must be Denied")
  // Multi-account offline cache priority: higher-priority A (loaded=false, cached ws-1) + lower-priority B (loaded=true, ws-1):
  // A owns ws-1 via offline cache (aligned with Core recomputeOwners), so B must NOT hijack ws-1 (B is Denied, A is Matched).
  reset()
  accounts_subs_sync(["acct-a", "acct-b"])
  set_startup_window_owner(Some("acct-b"))
  let snap_partial : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(false),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(true),
    }),
  ])
  workspace_owners_sync_json(Some(snap_partial))
  assert_eq(workspace_explicit_owner_of("ws-1"), Some("acct-a"), msg="higher-priority A offline cache must own ws-1, never hijacked by B")
  assert_false(workspace_is_pending("ws-1"))
  assert_true(window_here_owner_state(0, "ws-1/st-1", screen="browser:win-1") == Denied, msg="lower-priority B must be Denied when higher-priority A owns ws-1")
  let snap_full : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(true),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(true),
    }),
  ])
  workspace_owners_sync_json(Some(snap_full))
  assert_true(workspace_owners_synced(), msg="all accounts loaded must mark workspace_owners_synced true")
  assert_eq(workspace_explicit_owner_of("ws-1"), Some("acct-a"), msg="higher-priority A must own shared ws-1")
  assert_true(window_here_owner_state(0, "ws-1/st-1", screen="browser:win-1") == Denied, msg="child-process window for B must become Denied once A owns ws-1")
  set_startup_window_owner(Some("acct-a"))
  assert_true(window_here_owner_state(0, "ws-1/st-1", screen="browser:win-1") == Matched, msg="child-process window for A must become Matched once A owns ws-1")
  // Post-sync revocation while secondary account B is still loaded=false:
  // A (loaded=true, lost ws-1) MUST be immediately Denied while B (loaded=false, cached ws-1) stays Waiting!
  let snap_a_lost_b_pending : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([]),
      "loaded": Json::boolean(true),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(false),
    }),
  ])
  workspace_owners_sync_json(Some(snap_a_lost_b_pending))
  assert_eq(workspace_explicit_owner_of("ws-1"), None, msg="A lost ws-1 must clear explicit owner even while B is loaded=false")
  set_startup_window_owner(Some("acct-a"))
  assert_true(window_here_owner_state(0, "ws-1/st-1", screen="browser:win-1") == Denied, msg="loaded A that lost ws-1 must be immediately Denied")
  set_startup_window_owner(Some("acct-b"))
  assert_true(window_here_owner_state(0, "ws-1/st-1", screen="browser:win-1") == Waiting, msg="unloaded B with cached ws-1 must stay Waiting")
  // Astra P1-1: repeating identical or unrelated-field snapshots while B is still loaded=false must stay idempotently Pending!
  workspace_owners_sync_json(Some(snap_a_lost_b_pending))
  let snap_a_lost_b_pending_inv : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([]),
      "invitations": Json::array([Json::object({ "id": Json::string("inv-1") })]),
      "loaded": Json::boolean(true),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(false),
    }),
  ])
  workspace_owners_sync_json(Some(snap_a_lost_b_pending_inv))
  assert_eq(workspace_explicit_owner_of("ws-1"), None, msg="repeated snapshots while B is loaded=false must keep explicit owner None")
  assert_true(workspace_is_pending("ws-1"), msg="repeated snapshots while B is loaded=false must keep ws-1 Pending")
  assert_true(window_here_owner_state(0, "ws-1/st-1", screen="browser:win-1") == Waiting, msg="B window must remain Waiting across repeated pending snapshots")
  // Astra P1-2: cold start [A(loaded=false, []), B(loaded=false, [ws-1])] must keep ws-1 Pending and B Waiting!
  reset()
  accounts_subs_sync(["acct-a", "acct-b"])
  set_startup_window_owner(Some("acct-b"))
  let snap_both_unloaded : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([]),
      "loaded": Json::boolean(false),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(false),
    }),
  ])
  workspace_owners_sync_json(Some(snap_both_unloaded))
  assert_eq(workspace_explicit_owner_of("ws-1"), None, msg="both-unloaded cold start with empty A cache must not let B claim ws-1")
  assert_true(workspace_is_pending("ws-1"), msg="both-unloaded cold start must keep ws-1 Pending")
  assert_true(window_here_owner_state(0, "ws-1/st-1", screen="browser:win-1") == Waiting, msg="B window must stay Waiting on both-unloaded cold start")
  // Once B finishes loading with ws-1: A stays Denied, B transitions to Matched!
  let snap_b_loaded : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([]),
      "loaded": Json::boolean(true),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(true),
    }),
  ])
  workspace_owners_sync_json(Some(snap_b_loaded))
  assert_eq(workspace_explicit_owner_of("ws-1"), Some("acct-b"))
  set_startup_window_owner(Some("acct-a"))
  assert_true(window_here_owner_state(0, "ws-1/st-1", screen="browser:win-1") == Denied, msg="A must remain Denied after B loads ws-1")
  set_startup_window_owner(Some("acct-b"))
  assert_true(window_here_owner_state(0, "ws-1/st-1", screen="browser:win-1") == Matched, msg="B must transition to Matched after loading ws-1")
  // Astra P1-2: earlier unloaded account A with EMPTY cache ([]) + later loaded account B with ws-1:
  // B must NOT hijack ws-1 until A finishes loading; once A loads without ws-1, B transitions to Matched.
  reset()
  accounts_subs_sync(["acct-a", "acct-b"])
  set_startup_window_owner(Some("acct-b"))
  let snap_earlier_empty : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([]),
      "loaded": Json::boolean(false),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(true),
    }),
  ])
  workspace_owners_sync_json(Some(snap_earlier_empty))
  assert_eq(workspace_explicit_owner_of("ws-1"), None, msg="earlier unloaded A with empty cache must prevent B from claiming ws-1")
  assert_eq(workspace_owner_of("ws-1"), "\u{3}pending", msg="ws-1 under earlier_unloaded must report pending sentinel")
  assert_true(window_here_owner_state(0, "ws-1/st-1", screen="browser:win-1") == Waiting, msg="B child-process window must Wait while earlier A is unloaded")
  workspace_owners_sync_json(Some(snap_b_loaded))
  assert_eq(workspace_explicit_owner_of("ws-1"), Some("acct-b"))
  assert_true(window_here_owner_state(0, "ws-1/st-1", screen="browser:win-1") == Matched, msg="B must Match once earlier A finishes loading without ws-1")
  // Astra P2: signed-out account (absent from accounts) while ws-1 is Pending -> Denied (not Waiting)!
  reset()
  accounts_subs_sync(["acct-a", "acct-b"])
  workspace_owners_sync_json(Some(snap_earlier_empty))
  set_startup_window_owner(Some("acct-signed-out"))
  assert_true(window_here_owner_state(0, "ws-1/st-1", screen="browser:win-1") == Denied, msg="signed-out account must be Denied even while ws-1 is pending")
  set_startup_window_owner(Some("acct-b"))
  assert_true(window_here_owner_state(0, "ws-1/st-1", screen="browser:win-1") == Waiting, msg="loaded member B must remain Waiting while earlier A is unloaded-empty")
  // Opus P1 (first account 503 does not disrupt later account C or A's own cached workspace):
  reset()
  accounts_subs_sync(["acct-a", "acct-c"])
  let snap_ac_ok : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-a") })]),
      "loaded": Json::boolean(true),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-c") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-c") })]),
      "loaded": Json::boolean(true),
    }),
  ])
  workspace_owners_sync_json(Some(snap_ac_ok))
  let revokes_ac = Ref(0)
  let base_listeners_ac = workspace_owner_change_listeners.length()
  on_workspace_owner_change(fn(ws, _old, _new) {
    if ws == "ws-a" || ws == "ws-c" {
      revokes_ac.val += 1
    }
  })
  // A hits 503 with cached ws-a (or even empty cache []) -> C keeps ws-c with 0 revocations, A keeps ws-a with 0 revocations!
  let snap_a_503_cached : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-a") })]),
      "loaded": Json::boolean(false),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-c") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-c") })]),
      "loaded": Json::boolean(true),
    }),
  ])
  workspace_owners_sync_json(Some(snap_a_503_cached))
  assert_eq(workspace_explicit_owner_of("ws-a"), Some("acct-a"), msg="A 503 with cached ws-a must keep Owned(A)")
  assert_eq(workspace_explicit_owner_of("ws-c"), Some("acct-c"), msg="later account C must keep Owned(C) when A hits 503")
  assert_false(workspace_is_pending("ws-a"))
  assert_false(workspace_is_pending("ws-c"))
  assert_eq(revokes_ac.val, 0, msg="0 revocations when A hits 503 with cached ws-a")
  let snap_a_503_empty : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([]),
      "loaded": Json::boolean(false),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-c") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-c") })]),
      "loaded": Json::boolean(true),
    }),
  ])
  workspace_owners_sync_json(Some(snap_a_503_empty))
  assert_eq(workspace_explicit_owner_of("ws-c"), Some("acct-c"), msg="confirmed owner C must keep Owned(C) even when earlier A has empty cache on 503")
  assert_false(workspace_is_pending("ws-c"))
  while workspace_owner_change_listeners.length() > base_listeners_ac {
    workspace_owner_change_listeners.pop() |> ignore
  }
  // Astra P1-1: blocked (NOT_BETA) account with loaded=false and workspaces=[] MUST immediately revoke!
  reset()
  accounts_subs_sync(["acct-a"])
  workspace_owners_sync_json(Some(snap_a))
  let snap_blocked : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([]),
      "loaded": Json::boolean(false),
      "blocked": Json::string("not beta"),
    }),
  ])
  workspace_owners_sync_json(Some(snap_blocked))
  assert_true(workspace_is_revoked("ws-1"), msg="blocked account must immediately revoke ws-1")
  assert_eq(workspace_explicit_owner_of("ws-1"), None)
  assert_false(workspace_is_pending("ws-1"))
  set_startup_window_owner(Some("acct-a"))
  assert_true(window_here_owner_state(0, "ws-1/st-1", screen="browser:win-1") == Denied, msg="blocked account window must be Denied")
  // Opus P2: [A(loaded=true, ws-1), B(loaded=false, ws-1)] (A precedes B) -> A owns ws-1 with 0 revocations and !pending!
  reset()
  accounts_subs_sync(["acct-a", "acct-b"])
  workspace_owners_sync_json(Some(snap_full))
  let revokes = Ref(0)
  let base_listeners = workspace_owner_change_listeners.length()
  on_workspace_owner_change(fn(ws, _old, _new) {
    if ws == "ws-1" {
      revokes.val += 1
    }
  })
  let snap_a_first_b_unloaded : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(true),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "loaded": Json::boolean(false),
    }),
  ])
  workspace_owners_sync_json(Some(snap_a_first_b_unloaded))
  assert_eq(workspace_explicit_owner_of("ws-1"), Some("acct-a"), msg="higher-priority loaded A must keep ws-1 when lower-priority B is unloaded")
  assert_false(workspace_is_pending("ws-1"), msg="confirmed ws-1 owned by higher-priority A must not be pending")
  assert_eq(revokes.val, 0, msg="0 owner-change revocations when higher-priority A keeps ws-1")
  while workspace_owner_change_listeners.length() > base_listeners {
    workspace_owner_change_listeners.pop() |> ignore
  }
  // r13 Core authoritative ownedWorkspaces: identical account snapshots split cleanly by ownedWorkspaces!
  // (a) Multi-account [A(loaded=false, []), B(loaded=false, [ws-1])] with ownedWorkspaces=[] -> Pending/Waiting!
  reset()
  accounts_subs_sync(["acct-a", "acct-b"])
  set_startup_window_owner(Some("acct-b"))
  let core_multi_unowned : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([]),
      "ownedWorkspaces": Json::array([]),
      "loaded": Json::boolean(false),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "ownedWorkspaces": Json::array([]),
      "loaded": Json::boolean(false),
    }),
  ])
  workspace_owners_sync_json(Some(core_multi_unowned))
  assert_eq(workspace_explicit_owner_of("ws-1"), None, msg="Core ownedWorkspaces=[] must keep ws-1 unowned")
  assert_true(workspace_is_pending("ws-1"), msg="Core ownedWorkspaces=[] must keep ws-1 Pending")
  assert_true(window_here_owner_state(0, "ws-1/st-1", screen="browser:win-1") == Waiting, msg="B must Wait when Core ownedWorkspaces=[]")
  // (b) Exact same offline accounts, Core confirms B.ownedWorkspaces=["ws-1"] (still loaded=false!) -> immediately Owned(B)/Matched!
  let core_multi_owned_b : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-a") }),
      "workspaces": Json::array([]),
      "ownedWorkspaces": Json::array([]),
      "loaded": Json::boolean(false),
    }),
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "ownedWorkspaces": Json::array([Json::string("ws-1")]),
      "loaded": Json::boolean(false),
    }),
  ])
  workspace_owners_sync_json(Some(core_multi_owned_b))
  assert_eq(workspace_explicit_owner_of("ws-1"), Some("acct-b"), msg="Core B.ownedWorkspaces=[ws-1] must promote Owned(B) even while offline")
  assert_false(workspace_is_pending("ws-1"))
  assert_true(window_here_owner_state(0, "ws-1/st-1", screen="browser:win-1") == Matched, msg="B must Match offline once Core confirms ownedWorkspaces")
  // (c) Single-account [B(loaded=false, [ws-1])] with ownedWorkspaces=[] -> STILL Pending/Waiting even as first account!
  reset()
  accounts_subs_sync(["acct-b"])
  set_startup_window_owner(Some("acct-b"))
  let core_single_unowned : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "ownedWorkspaces": Json::array([]),
      "loaded": Json::boolean(false),
    }),
  ])
  workspace_owners_sync_json(Some(core_single_unowned))
  assert_eq(workspace_explicit_owner_of("ws-1"), None, msg="single account with Core ownedWorkspaces=[] must stay unowned")
  assert_true(workspace_is_pending("ws-1"), msg="single account with Core ownedWorkspaces=[] must stay Pending")
  assert_true(window_here_owner_state(0, "ws-1/st-1", screen="browser:win-1") == Waiting, msg="single account B must Wait when Core ownedWorkspaces=[]")
  // (d) Same single account, Core recovers ownedWorkspaces=["ws-1"] (still loaded=false) -> immediately Owned(B)/Matched!
  let core_single_owned : Json = Json::array([
    Json::object({
      "account": Json::object({ "sub": Json::string("acct-b") }),
      "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
      "ownedWorkspaces": Json::array([Json::string("ws-1")]),
      "loaded": Json::boolean(false),
    }),
  ])
  workspace_owners_sync_json(Some(core_single_owned))
  assert_eq(workspace_explicit_owner_of("ws-1"), Some("acct-b"))
  assert_false(workspace_is_pending("ws-1"))
  assert_true(window_here_owner_state(0, "ws-1/st-1", screen="browser:win-1") == Matched, msg="single account B must Match offline once Core confirms ownedWorkspaces")
  // r14 two-pass order independence & two-step explicit_loss preservation:
  // (1) [B(loaded=false, ownedWorkspaces=["ws-1"]), A(loaded=true, workspaces=[], ownedWorkspaces=[])] (B precedes A)
  //     after A owned ws-1: A is immediately revoked, ws-1 enters Pending (explicit_loss), B Waits until loaded=true!
  reset()
  accounts_subs_sync(["acct-b", "acct-a"])
  workspace_owners_sync_json(
    Some(
      Json::array([
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-b") }),
          "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
          "ownedWorkspaces": Json::array([]),
          "loaded": Json::boolean(true),
        }),
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-a") }),
          "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
          "ownedWorkspaces": Json::array([Json::string("ws-1")]),
          "loaded": Json::boolean(true),
        }),
      ]),
    ),
  )
  assert_eq(workspace_explicit_owner_of("ws-1"), Some("acct-a"))
  workspace_owners_sync_json(
    Some(
      Json::array([
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-b") }),
          "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
          "ownedWorkspaces": Json::array([Json::string("ws-1")]),
          "loaded": Json::boolean(false),
        }),
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-a") }),
          "workspaces": Json::array([]),
          "ownedWorkspaces": Json::array([]),
          "loaded": Json::boolean(true),
        }),
      ]),
    ),
  )
  assert_eq(workspace_explicit_owner_of("ws-1"), None, msg="B preceding A must still detect A's explicit loss in 2-pass sync")
  assert_true(workspace_is_pending("ws-1"))
  set_startup_window_owner(Some("acct-a"))
  assert_true(window_here_owner_state(0, "ws-1/st-1", screen="browser:win-1") == Denied)
  set_startup_window_owner(Some("acct-b"))
  assert_true(window_here_owner_state(0, "ws-1/st-1", screen="browser:win-1") == Waiting, msg="B must Wait until loaded=true after A's loss")
  // (2) Two-step transition: A(Owned) -> Step 1 (A lost, both ownedWorkspaces=[]) -> Step 2 (B still loaded=false, ownedWorkspaces=["ws-1"]):
  //     explicit_loss MUST survive Step 1 -> Step 2 so B stays Waiting until Step 3 (B loaded=true)!
  reset()
  accounts_subs_sync(["acct-a", "acct-b"])
  workspace_owners_sync_json(
    Some(
      Json::array([
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-a") }),
          "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
          "ownedWorkspaces": Json::array([Json::string("ws-1")]),
          "loaded": Json::boolean(true),
        }),
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-b") }),
          "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
          "ownedWorkspaces": Json::array([]),
          "loaded": Json::boolean(true),
        }),
      ]),
    ),
  )
  // Step 1: A loses ws-1, Core hasn't assigned B yet (both ownedWorkspaces=[])
  workspace_owners_sync_json(
    Some(
      Json::array([
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-a") }),
          "workspaces": Json::array([]),
          "ownedWorkspaces": Json::array([]),
          "loaded": Json::boolean(true),
        }),
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-b") }),
          "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
          "ownedWorkspaces": Json::array([]),
          "loaded": Json::boolean(false),
        }),
      ]),
    ),
  )
  assert_eq(workspace_explicit_owner_of("ws-1"), None)
  assert_true(workspace_is_pending("ws-1"))
  // Step 2: Core offline-assigns ws-1 to B, but B is STILL loaded=false -> explicit_loss MUST keep ws-1 Pending!
  workspace_owners_sync_json(
    Some(
      Json::array([
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-a") }),
          "workspaces": Json::array([]),
          "ownedWorkspaces": Json::array([]),
          "loaded": Json::boolean(true),
        }),
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-b") }),
          "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
          "ownedWorkspaces": Json::array([Json::string("ws-1")]),
          "loaded": Json::boolean(false),
        }),
      ]),
    ),
  )
  assert_eq(workspace_explicit_owner_of("ws-1"), None, msg="explicit_loss must survive Step 1 -> Step 2 while B is still loaded=false")
  assert_true(workspace_is_pending("ws-1"))
  set_startup_window_owner(Some("acct-b"))
  assert_true(window_here_owner_state(0, "ws-1/st-1", screen="browser:win-1") == Waiting)
  // Step 3: B finishes /v1/me (loaded=true, ownedWorkspaces=["ws-1"]) -> Owned(B)/Matched!
  workspace_owners_sync_json(
    Some(
      Json::array([
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-a") }),
          "workspaces": Json::array([]),
          "ownedWorkspaces": Json::array([]),
          "loaded": Json::boolean(true),
        }),
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-b") }),
          "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
          "ownedWorkspaces": Json::array([Json::string("ws-1")]),
          "loaded": Json::boolean(true),
        }),
      ]),
    ),
  )
  assert_eq(workspace_explicit_owner_of("ws-1"), Some("acct-b"))
  assert_false(workspace_is_pending("ws-1"))
  assert_true(window_here_owner_state(0, "ws-1/st-1", screen="browser:win-1") == Matched)
  // r15 (1a) Sign-out notification order ①: accounts_subs_sync(["acct-b"]) arrives BEFORE workspaces snapshot!
  reset()
  accounts_subs_sync(["acct-a", "acct-b"])
  workspace_owners_sync_json(
    Some(
      Json::array([
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-a") }),
          "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
          "ownedWorkspaces": Json::array([Json::string("ws-1")]),
          "loaded": Json::boolean(true),
        }),
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-b") }),
          "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
          "ownedWorkspaces": Json::array([]),
          "loaded": Json::boolean(true),
        }),
      ]),
    ),
  )
  accounts_subs_sync(["acct-b"])
  assert_true(workspace_is_pending("ws-1"), msg="accounts_subs_sync removal must preserve explicit_loss pending")
  workspace_owners_sync_json(
    Some(
      Json::array([
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-b") }),
          "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
          "ownedWorkspaces": Json::array([Json::string("ws-1")]),
          "loaded": Json::boolean(false),
        }),
      ]),
    ),
  )
  assert_eq(workspace_explicit_owner_of("ws-1"), None, msg="order 1: offline B must wait after A signed out")
  assert_true(workspace_is_pending("ws-1"))
  set_startup_window_owner(Some("acct-b"))
  assert_true(window_here_owner_state(0, "ws-1/st-1", screen="browser:win-1") == Waiting)
  // r15 (1b) Sign-out notification order ②: workspaces snapshot (without A) arrives BEFORE accounts_subs_sync!
  reset()
  accounts_subs_sync(["acct-a", "acct-b"])
  workspace_owners_sync_json(
    Some(
      Json::array([
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-a") }),
          "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
          "ownedWorkspaces": Json::array([Json::string("ws-1")]),
          "loaded": Json::boolean(true),
        }),
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-b") }),
          "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
          "ownedWorkspaces": Json::array([]),
          "loaded": Json::boolean(true),
        }),
      ]),
    ),
  )
  workspace_owners_sync_json(
    Some(
      Json::array([
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-b") }),
          "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
          "ownedWorkspaces": Json::array([Json::string("ws-1")]),
          "loaded": Json::boolean(false),
        }),
      ]),
    ),
  )
  accounts_subs_sync(["acct-b"])
  assert_eq(workspace_explicit_owner_of("ws-1"), None, msg="order 2: offline B must wait after A signed out")
  assert_true(workspace_is_pending("ws-1"))
  set_startup_window_owner(Some("acct-b"))
  assert_true(window_here_owner_state(0, "ws-1/st-1", screen="browser:win-1") == Waiting)
  // r15 (2) A is STILL a loaded member of ws-1, and Core legitimately re-elects higher-priority offline B:
  // NOT an explicit loss -> immediately Owned(B)/Matched for offline mesh!
  reset()
  accounts_subs_sync(["acct-b", "acct-a"])
  workspace_owners_sync_json(
    Some(
      Json::array([
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-b") }),
          "workspaces": Json::array([]),
          "ownedWorkspaces": Json::array([]),
          "loaded": Json::boolean(false),
        }),
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-a") }),
          "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
          "ownedWorkspaces": Json::array([Json::string("ws-1")]),
          "loaded": Json::boolean(true),
        }),
      ]),
    ),
  )
  assert_eq(workspace_explicit_owner_of("ws-1"), Some("acct-a"))
  workspace_owners_sync_json(
    Some(
      Json::array([
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-b") }),
          "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
          "ownedWorkspaces": Json::array([Json::string("ws-1")]),
          "loaded": Json::boolean(false),
        }),
        Json::object({
          "account": Json::object({ "sub": Json::string("acct-a") }),
          "workspaces": Json::array([Json::object({ "id": Json::string("ws-1") })]),
          "ownedWorkspaces": Json::array([]),
          "loaded": Json::boolean(true),
        }),
      ]),
    ),
  )
  assert_eq(workspace_explicit_owner_of("ws-1"), Some("acct-b"), msg="legitimate re-election while A is still loaded member must immediately promote Owned(B)")
  assert_false(workspace_is_pending("ws-1"))
  set_startup_window_owner(Some("acct-b"))
  assert_true(window_here_owner_state(0, "ws-1/st-1", screen="browser:win-1") == Matched)
  reset()
}
