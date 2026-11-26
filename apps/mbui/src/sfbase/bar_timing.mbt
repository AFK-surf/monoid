// How long a switch between places on the bottom bar or left rail takes (still.fail's Android app's BarTiming.kt
// -> `bar_switch`): the host is told as a place's page is put on the stack in place of another's (go_place /
// rail_go_told), and as the frame that first built it is over. The times are the host's (src/stillfail:
// Android's BarTiming.java, logcat StillfailTiming and PostHog); nothing here reads a clock, and under a Tester
// nothing is told unless a test sets `bar_timing`.

///|
/// What the host is told of a switch: a place's page put on the stack (the place left, "" from none; the place), and
/// built (the place).
pub(all) struct BarTiming {
  placed : (String, String) -> Unit
  built : (String) -> Unit
}

///|
/// The host's, set once as the app starts (src/stillfail main); None under a Tester (reset), unless its test sets one.
pub let bar_timing : Ref[BarTiming?] = Ref(None)

///|
/// The place switched to whose page is to be told built, until the frame that built it is over.
pub let bar_timed : Ref[String?] = Ref(None)

///|
/// Told each time a place is put on the stack to be told built (bar_placed): what a page made once reacts to
/// (bar_built_node / bar_built_wide_node), back to the chats too, where no switch of the bar's is said.
// kept across runs: only counted on, what reads it reacting to its change, never to its value
pub let bar_timed_said : @signals.Signal[Int] = @signals.signal(0)

///|
/// Monotonic generation for `bar_timed`, incremented on each `bar_placed` so stale `after_drawn_frame` callbacks from
/// an earlier switch can never clear or fire a newer switch.
// kept across runs: monotonic generation counter, never compared to a fixed value
let bar_timed_gen : Ref[Int] = Ref(0)

///|
/// The target stack-top entry serial for the pending wide-frame switch (None for Small-screen switches).
let bar_timed_target_serial : Ref[Int?] = Ref(None)

///|
/// Reset bar timing globals between test runs (called from `sfbase`'s `reset`).
pub fn bar_timing_reset() -> Unit {
  bar_timing.val = None
  bar_timed.val = None
  bar_timed_target_serial.val = None
}

///|
/// Return a known literal place name for telemetry, or None for overlays (`"attention"`) and any dynamic/unknown ID.
/// Chat list filter views (`"mine"`, `"watching"`, `"hidden"`) normalize to `"chats"` so filter switches inside the
/// chats list do not emit synthetic 0 ms `bar_switch` samples.
pub fn bar_place_literal(place : String) -> String? {
  match place {
    "chats" | "mine" | "watching" | "hidden" => Some("chats")
    "archive" => Some("archive")
    "board" => Some("board")
    "files" => Some("files")
    "remote" => Some("remote")
    "stations" => Some("stations")
    "profiles" => Some("profiles")
    "connects" => Some("connects")
    "usage" => Some("usage")
    "vault" => Some("vault")
    "settings" => Some("settings")
    _ => None
  }
}

///|
/// A place's page put on the stack in place of `from`'s ("" none), from the bar or back to the chats (AppState.place).
pub fn bar_placed(from : String, place : String) -> Unit {
  match bar_timing.val {
    Some(t) => {
      (t.placed)(from, place)
      bar_timed_gen.val += 1
      bar_timed.val = Some(place)
      bar_timed_target_serial.val = None
      bar_timed_said.set(bar_timed_said.untracked() + 1)
    }
    None => ()
  }
}

///|
/// Wide-frame (Large / Medium) rail switch start: sanitizes `from` and `to` to literal place names only, skips
/// overlays (`"attention"`) and same-place clicks, and records optional `target_serial` so only the intended stack-top
/// entry satisfies `built`.
pub fn bar_placed_wide(from : String, to : String, target_serial? : Int) -> Unit {
  guard bar_place_literal(to) is Some(to_lit) else { return }
  let from_lit = bar_place_literal(from).unwrap_or("")
  if from_lit == to_lit {
    return
  }
  bar_placed(from_lit, to_lit)
  bar_timed_target_serial.val = target_serial
}

///|
/// Whether presented page `page` matches a timed wide-frame switch to literal place `place` (does not inspect
/// `app.nav.pages()`, relying on entry-serial identity in `bar_built_wide_node` so `page_wait` holds never mis-match).
fn bar_wide_matches(place : String, page : Page) -> Bool {
  match place {
    "chats" | "mine" | "watching" | "hidden" => page is (Chat(_) | NewChat | Home)
    "archive" => page is (Archived | Chat(_))
    "settings" => page is (Settings | Setting(_))
    "files" => page is (Files | Drive(_))
    "board" => page is Home
    p => page == Place(p)
  }
}

///|
/// Wide-frame (Large / Medium) completion hook: fires `bar_timing.built(place)` after the frame that actually presents
/// the target place's stack-top entry (`shown_serial == top_stay().0`, and `shown_serial == target_serial` when set,
/// respecting `page_wait` holds). If a non-matching stack-top entry presents instead (interrupted by Cmd+K,
/// back/forward, or another chat opened), cancels `bar_timed`.
pub fn bar_built_wide_node(v : @view.View, shown_entry : () -> (Int, Page)?) -> Unit {
  v.reacts(
    fn() { (shown_entry(), app.nav.top_stay(), bar_timed_said.get()) },
    fn(cur) {
      let (shown, (top_serial, _), _) = cur
      match (bar_timing.val, bar_timed.val, shown) {
        (Some(t), Some(p), Some((shown_serial, shown_page))) =>
          if shown_serial == top_serial {
            let target_ok = match bar_timed_target_serial.val {
              Some(ts) => shown_serial == ts
              None => true
            }
            if target_ok && bar_wide_matches(p, shown_page) {
              let gen = bar_timed_gen.val
              @ui.after_drawn_frame(fn() {
                if bar_timed_gen.val == gen && bar_timed.val == Some(p) {
                  bar_timed.val = None
                  bar_timed_target_serial.val = None
                  (t.built)(p)
                }
              })
            } else {
              bar_timed.val = None
              bar_timed_target_serial.val = None
            }
          }
        _ => ()
      }
    },
  )
}
