// Exhaustive declarative row policy table for the chat message list (`chat_body_node` & `chat_body_keyed`):
// every `Entry` variant must be handled explicitly with no wildcard arm so adding a new row kind forces
// declaring its staging, follow, live-cause, and anchor rules in one place.

///|
/// How a newly arrived row affects foot-following scroll placement (`chat_body_node`'s `newest`).
priv enum ChatFollowRole {
  Ignore
  ToFoot
  CapAtTop
}

///|
/// How a newly arrived row at the list tail is judged as a live motion cause (`chat_live_causes`).
priv enum ChatLiveRole {
  LiveNever
  LiveAlways
  LiveWhenSaid
  LiveWhenStarted
}

///|
/// Complete declarative policy for one chat list `Entry`.
priv struct ChatEntryPolicy {
  stage : @motion.StagePolicy
  in_list : Bool
  hide_on_online_send : Bool
  is_tail_slot : Bool
  comes : Bool
  follow_role : ChatFollowRole
  live_role : ChatLiveRole
  leaves_room : Bool
}

///|
/// Exhaustive policy lookup for every `Entry` variant (no `_ =>` wildcard allowed).
fn chat_entry_policy(e : Entry) -> ChatEntryPolicy {
  match e {
    Top =>
      {
        stage: {
          lane: Structural,
          during_barrier: Keep,
          rekey_on_prev_change: false,
          hold_as_anchor: true,
          live_removable: false,
        },
        in_list: false,
        hide_on_online_send: false,
        is_tail_slot: false,
        comes: false,
        follow_role: Ignore,
        live_role: LiveNever,
        leaves_room: false,
      }
    Foot =>
      {
        stage: {
          lane: Structural,
          during_barrier: Keep,
          rekey_on_prev_change: false,
          hold_as_anchor: true,
          live_removable: false,
        },
        in_list: false,
        hide_on_online_send: false,
        is_tail_slot: false,
        comes: false,
        follow_role: Ignore,
        live_role: LiveNever,
        leaves_room: false,
      }
    Older(_) =>
      {
        stage: {
          lane: Structural,
          during_barrier: Keep,
          rekey_on_prev_change: false,
          hold_as_anchor: false,
          live_removable: false,
        },
        in_list: true,
        hide_on_online_send: false,
        is_tail_slot: false,
        comes: false,
        follow_role: CapAtTop,
        live_role: LiveNever,
        leaves_room: false,
      }
    @sfbase.Entry::Empty =>
      {
        stage: {
          lane: Structural,
          during_barrier: Keep,
          rekey_on_prev_change: false,
          hold_as_anchor: true,
          live_removable: false,
        },
        in_list: true,
        hide_on_online_send: false,
        is_tail_slot: false,
        comes: false,
        follow_role: CapAtTop,
        live_role: LiveNever,
        leaves_room: false,
      }
    Line =>
      {
        stage: {
          lane: Structural,
          during_barrier: Keep,
          rekey_on_prev_change: false,
          hold_as_anchor: true,
          live_removable: false,
        },
        in_list: true,
        hide_on_online_send: false,
        is_tail_slot: false,
        comes: false,
        follow_role: CapAtTop,
        live_role: LiveNever,
        leaves_room: false,
      }
    Newer =>
      {
        stage: {
          lane: Structural,
          during_barrier: Keep,
          rekey_on_prev_change: false,
          hold_as_anchor: true,
          live_removable: false,
        },
        in_list: true,
        hide_on_online_send: false,
        is_tail_slot: false,
        comes: false,
        follow_role: Ignore,
        live_role: LiveNever,
        leaves_room: false,
      }
    Said(m) =>
      {
        stage: {
          lane: Content,
          during_barrier: Keep,
          rekey_on_prev_change: false,
          hold_as_anchor: true,
          live_removable: true,
        },
        in_list: true,
        hide_on_online_send: false,
        is_tail_slot: false,
        comes: m.said,
        follow_role: if m.mine { ToFoot } else { CapAtTop },
        live_role: LiveWhenSaid,
        leaves_room: false,
      }
    Sent(_) =>
      {
        stage: {
          lane: Content,
          during_barrier: Keep,
          rekey_on_prev_change: false,
          hold_as_anchor: true,
          live_removable: true,
        },
        in_list: true,
        hide_on_online_send: false,
        is_tail_slot: false,
        comes: false,
        follow_role: CapAtTop,
        live_role: LiveNever,
        leaves_room: false,
      }
    Out(_) =>
      {
        stage: {
          lane: Content,
          during_barrier: Keep,
          rekey_on_prev_change: false,
          hold_as_anchor: true,
          live_removable: true,
        },
        in_list: true,
        hide_on_online_send: false,
        is_tail_slot: false,
        comes: true,
        follow_role: ToFoot,
        live_role: LiveAlways,
        leaves_room: false,
      }
    Working(a) =>
      {
        stage: {
          lane: Activity,
          during_barrier: CoMoveWithBarrier,
          rekey_on_prev_change: false,
          hold_as_anchor: true,
          live_removable: true,
        },
        in_list: true,
        hide_on_online_send: false,
        is_tail_slot: true,
        comes: a.started,
        follow_role: Ignore,
        live_role: LiveWhenStarted,
        leaves_room: true,
      }
    State(_, _, _) =>
      {
        stage: {
          lane: Trailer,
          during_barrier: DeferUntilBarriers,
          rekey_on_prev_change: true,
          hold_as_anchor: true,
          live_removable: true,
        },
        in_list: true,
        hide_on_online_send: true,
        is_tail_slot: true,
        comes: true,
        follow_role: Ignore,
        live_role: LiveAlways,
        leaves_room: false,
      }
    CacheCold(_, _, _, _) =>
      {
        stage: {
          lane: Trailer,
          during_barrier: DeferUntilBarriers,
          rekey_on_prev_change: true,
          hold_as_anchor: true,
          live_removable: true,
        },
        in_list: true,
        hide_on_online_send: true,
        is_tail_slot: true,
        comes: true,
        follow_role: Ignore,
        live_role: LiveAlways,
        leaves_room: false,
      }
    Archived =>
      {
        stage: {
          lane: Trailer,
          during_barrier: DeferUntilBarriers,
          rekey_on_prev_change: true,
          hold_as_anchor: true,
          live_removable: true,
        },
        in_list: true,
        hide_on_online_send: true,
        is_tail_slot: true,
        comes: true,
        follow_role: Ignore,
        live_role: LiveAlways,
        leaves_room: false,
      }
    Feedback =>
      {
        stage: {
          lane: Trailer,
          during_barrier: DeferUntilBarriers,
          rekey_on_prev_change: true,
          hold_as_anchor: true,
          live_removable: true,
        },
        in_list: true,
        hide_on_online_send: false,
        is_tail_slot: true,
        comes: true,
        follow_role: Ignore,
        live_role: LiveAlways,
        leaves_room: false,
      }
  }
}

///|
/// Whether a removed raw key (already absent from the list) represents a live removal per `chat_entry_policy`.
fn chat_key_live_removable(raw_k : String) -> Bool {
  match raw_k {
    "line" => chat_entry_policy(Entry::Line).stage.live_removable
    "older" => chat_entry_policy(Entry::Older("")).stage.live_removable
    "newer" => chat_entry_policy(Entry::Newer).stage.live_removable
    "empty" => chat_entry_policy(Entry::Empty).stage.live_removable
    "top" => chat_entry_policy(Entry::Top).stage.live_removable
    "foot" => chat_entry_policy(Entry::Foot).stage.live_removable
    "wait" => false
    _ => true
  }
}

///|
/// Whether raw key `raw_k` may be held as a reading anchor per `chat_entry_policy`.
fn chat_key_hold_as_anchor(raw_k : String) -> Bool {
  match raw_k {
    "older" => chat_entry_policy(Entry::Older("")).stage.hold_as_anchor
    _ => true
  }
}

///|
/// Whether raw key `raw_k` rekeys on predecessor change per `chat_entry_policy` (pure key predicate for
/// `ListStage::new` so initial/non-staged ingests never deserialize history rows).
fn chat_key_rekeys_on_prev_change(raw_k : String) -> Bool {
  match raw_k {
    "state" => chat_entry_policy(Entry::State("", "", "")).stage.rekey_on_prev_change
    "cache_cold" => chat_entry_policy(Entry::CacheCold("", "", "", false)).stage.rekey_on_prev_change
    "archived" => chat_entry_policy(Entry::Archived).stage.rekey_on_prev_change
    "feedback" => chat_entry_policy(Entry::Feedback).stage.rekey_on_prev_change
    _ => false
  }
}
