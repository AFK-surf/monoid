// A new chat while it is made, and as it becomes its chat (NewChat.kt, the web's NewChat.tsx useEnsureChat and
// madeChat.ts): what both frames' new chat pages and the composer that sends its first message keep of it.

///|
/// What the page keeps while it is a new chat, and as it becomes its chat.
pub(all) struct FreshChat {
  /// the chat made for the first message (its key), and what was picked when it was made: picked anew, it is made
  /// anew (until a message went to it)
  made : @signals.Signal[String]
  made_sig : @signals.Signal[String]
  sent : @signals.Signal[Bool]
  /// a message on its way (the create and the send)
  starting : @signals.Signal[Bool]
  /// its first words sent from the page (its scene leaving from then; back again as the page is the new chat again,
  /// the chat not made: new_sending)
  sending : @signals.Signal[Bool]
  /// the chat it became (its scene leaving over it: new_leave)
  became : @signals.Signal[ChatRef?]
  /// the scene's look as it left: the view it showed; in the wide frame, how tall its composer's place was (what the
  /// scene leaving keeps clear, so nothing of it moves)
  scene : @signals.Signal[Json?]
  room : @signals.Signal[Double]
  /// narrow, how tall its foot was (the band, the choices, the composer): what of the scene leaving is not seen, as it
  /// was not
  foot : @signals.Signal[Double]
}

///|
/// Its composer's place as its first words were sent, in the window (x, y, w, h; none where it was not laid out):
/// where the chat's composer it became comes from (kept off FreshChat so its struct layout stays stable).
// kept across runs: cleared on fresh_reset and as composer_node takes it
pub let fresh_composer_at : @signals.Signal[(Double, Double, Double, Double)?] = @signals.signal(None)

///|
/// Extra height (was - one) of the narrow new-chat composer as its first words were sent (multi-line / attachments /
/// quotes), handed off to the chat's composer so frame 0 keeps continuous height before collapsing smoothly.
// kept across runs: cleared on fresh_reset and as composer_node takes it
pub let fresh_composer_over : @signals.Signal[Double] = @signals.signal(0.0, same=fn(a, b) { a == b })

///|
/// Retained extra height of the narrow new-chat composer during its leaving choreography (cleared only on fresh_reset,
/// never consumed by chat_composer_node), so over_it capsules and notices offset upward and never drop into the
/// multi-line chat composer when the new-chat draft clears.
// kept across runs: cleared on fresh_reset
pub let fresh_over_held : @signals.Signal[Double] = @signals.signal(0.0, same=fn(a, b) { a == b })

///|
/// Wide-layout sidebar switch handoff box (NewChat <-> Chat): recorded on departure, consumed by the arriving
/// composer_node, and cleared when leaving to a non-chat page (composer_page_left).
// kept across runs: cleared on composer_page_left and as composer_node takes it
pub let composer_handoff_at : @signals.Signal[(Double, Double, Double, Double)?] = @signals.signal(None)

///|
/// How long after they were sent its first words set out from where they were typed: 窄排法, as the scene's foot fades
/// first; 宽排法, none (became_starts / fresh_choreo_start).
// kept across runs: cleared on fresh_reset and set by became_starts / fresh_choreo_start
pub let fresh_fly_after : @signals.Signal[Double] = @signals.signal(0.0, same=fn(a, b) { a == b })

///|
/// Multi-track choreography for the node-based NewChat -> Chat transition: staggered bar, choices/under, scene, and
/// message flight delay (single source of truth via `track_delay("flight")`).
pub fn fresh_transition(wide : Bool) -> @motion.Choreography {
  if wide {
    @motion.Choreography::new([
      { name: "scene_out", forward: @motion.tween(new_leave_ms, ease=Leave), backward: @motion.tween(new_leave_ms, ease=Out) },
      { name: "under_out", forward: @motion.tween(110.0, ease=Leave), backward: @motion.tween(100.0, ease=Out) },
      { name: "flight", forward: @motion.tween(flight_desk_ms, ease=Flight, delay=0.0), backward: @motion.Spec::Snap(0.0) },
    ])
  } else {
    @motion.Choreography::new([
      { name: "bar_out", forward: @motion.tween(110.0, ease=Leave), backward: @motion.tween(110.0, ease=Out) },
      { name: "bar_in", forward: @motion.tween(140.0, ease=Out, delay=40.0), backward: @motion.tween(100.0, ease=Out) },
      { name: "choices_out", forward: @motion.tween(100.0, ease=Leave), backward: @motion.tween(100.0, ease=Out) },
      { name: "scene_out", forward: @motion.tween(new_leave_ms, ease=Leave), backward: @motion.tween(new_leave_ms, ease=Out) },
      { name: "flight", forward: @motion.tween(flight_desk_ms, ease=Flight, delay=40.0), backward: @motion.Spec::Snap(0.0) },
    ])
  }
}

///|
/// Active choreography for the node-based NewChat -> Chat transition.
// kept across runs: stopped and reset by fresh_reset
pub let fresh_choreo : Ref[@motion.Choreography] = Ref(fresh_transition(false))

///|
/// Generation signal bumped whenever `fresh_choreo` is replaced, started, reversed, or reset, so bindings reading
/// `fresh_progress` / `fresh_active` automatically re-subscribe to the active Choreography's tracks.
// kept across runs: bumped by fresh_reset / fresh_choreo_start / fresh_choreo_reverse
let fresh_choreo_gen : @signals.Signal[Int] = @signals.signal(0, same=fn(a, b) { a == b })

///|
/// Start the node-based NewChat -> Chat choreography from cause moment `at` for `wide` (宽排法) or narrow (窄排法),
/// publishing the flight track's delay as `fresh_fly_after`.
pub fn fresh_choreo_start(wide : Bool, at : Double) -> Unit {
  fresh_choreo.val.stop()
  let ch = fresh_transition(wide)
  ch.start(at)
  fresh_choreo.val = ch
  fresh_fly_after.set(if chat_page_nodes.untracked() { ch.track_delay("flight") } else { new_fade_ms })
  fresh_choreo_gen.set(fresh_choreo_gen.untracked() + 1)
}

///|
/// Reverse the active NewChat -> Chat choreography from cause moment `at` (e.g. when `newChat.create` fails).
pub fn fresh_choreo_reverse(at : Double) -> Unit {
  fresh_choreo.val.reverse(at)
  fresh_choreo_gen.set(fresh_choreo_gen.untracked() + 1)
}

///|
/// Reactive progress (0.0 .. 1.0) of track `name` on the active NewChat -> Chat choreography.
pub fn fresh_progress(n : @view.View, name : String) -> Double {
  fresh_choreo_gen.get() |> ignore
  fresh_choreo.val.progress(n, name)
}

///|
/// Whether the active NewChat -> Chat choreography is currently running at `n`'s logic moment.
pub fn fresh_active(n : @view.View) -> Bool {
  fresh_choreo_gen.get() |> ignore
  fresh_choreo.val.active(n)
}

///|
pub let fresh : FreshChat = {
  made: @signals.signal("", same=fn(a, b) { a == b }),
  made_sig: @signals.signal("", same=fn(a, b) { a == b }),
  sent: @signals.signal(false, same=fn(a, b) { a == b }),
  starting: @signals.signal(false, same=fn(a, b) { a == b }),
  sending: @signals.signal(false, same=fn(a, b) { a == b }),
  became: @signals.signal(None),
  scene: @signals.signal(None),
  room: @signals.signal(0.0, same=fn(a, b) { a == b }),
  foot: @signals.signal(0.0, same=fn(a, b) { a == b }),
}

///|
/// A new chat begun: nothing made for it yet (useEnsureChat's, made once a page).
pub fn fresh_reset() -> Unit {
  fresh.made.set("")
  fresh.made_sig.set("")
  fresh.sent.set(false)
  fresh.starting.set(false)
  fresh.sending.set(false)
  fresh.became.set(None)
  fresh.scene.set(None)
  fresh.room.set(0.0)
  fresh.foot.set(0.0)
  fresh_composer_at.set(None)
  fresh_composer_over.set(0.0)
  fresh_over_held.set(0.0)
  fresh_fly_after.set(0.0)
  fresh_choreo.val.stop()
  fresh_choreo.val = fresh_transition(false)
  fresh_choreo_gen.set(fresh_choreo_gen.untracked() + 1)
  fresh_back.val = false
}

///|
/// Whether the new chat's page made as nodes is the new chat again in the change under way, its first words' chat not
/// made (new_chat_node's `back`): one made anew in it, its leaving over by then, comes back from gone (its scene over
/// new_leave_ms, what is by its composer over new_fade_ms, as the old page's do: leaving_back); one still leaving
/// comes back as it is (View::show's). Said till that change's frame is drawn.
// kept across runs: false as a new chat is begun (fresh_reset), and once the frame of the change that set it is drawn
pub let fresh_back : Ref[Bool] = Ref(false)

///|
/// A new chat's scene leaving as it becomes the chat, fading where it is; its choices fading where they are, sooner.
pub let new_leave_ms : Double = 140.0

///|
pub let new_fade_ms : Double = 80.0

///|
/// The new chat's scene fading (0 … 1), its choices fading (0 … 1).
pub fn new_leave(c : @ui.Ctx) -> @motion.Anim {
  @motion.anim(c, "new/leave", 1.0, global=true)
}

///|
pub fn new_fade(c : @ui.Ctx) -> @motion.Anim {
  @motion.anim(c, "new/fade", 1.0, global=true)
}

///|
/// The new chat's first words on their way to the chat it became (0 … 1), from fresh's `fly_after` after they were sent,
/// for flight_desk_ms: on the old list the flight it carries (flight_carried), on the list made as nodes (`chat_page_nodes`)
/// their row's flight from where they stood in the field (View::flies_in), each setting out as long after.
pub fn new_first_fly(c : @ui.Ctx) -> @motion.Anim {
  @motion.anim(c, "new/first-fly", 1.0, global=true)
}

///|
/// The new chat's first words sent, or the new chat left for a chat: its scene leaves, from now, and its choices fade
/// (on a phone as Android's LeaveFade), over the chat it became (new_chat_leaving_of): as the words go, not once the
/// core has made the chat and taken them in. 窄排法 (not `wide`) the words set out a little after, as the scene's foot
/// fades out of their way (flight_carry_after_ms), on either list: said once, here (fresh's `fly_after`), for what
/// flies them to read.
pub fn became_starts(c : @ui.Ctx, wide~ : Bool) -> Unit {
  let leave = new_leave(c)
  leave.snap(c, 0.0)
  leave.animate(c, 1.0, @motion.tween(new_leave_ms, ease=Leave))
  let fade = new_fade(c)
  fade.snap(c, 0.0)
  fade.animate(c, 1.0, @motion.tween(new_fade_ms, ease=Leave))
  let after = if wide { 0.0 } else { flight_carry_after_ms }
  fresh_fly_after.set(after)
  let fly = new_first_fly(c)
  fly.snap(c, 0.0)
  fly.animate(c, 1.0, @motion.tween(flight_desk_ms, ease=Flight, delay=after))
}

///|
/// The new chat's first words not sent after all (the chat not made, or the message refused): its scene and choices
/// back as they were, from where they had gone.
pub fn leaving_back() -> Unit {
  let c = @ui.current()
  new_leave(c).animate(c, 0.0, @motion.tween(new_leave_ms, ease=Out))
  new_fade(c).animate(c, 0.0, @motion.tween(new_fade_ms, ease=Out))
  new_first_fly(c).snap(c, 1.0)
}

///|
/// How far the new chat's scene and its choices have gone (0 … 1 each) while it is the new chat after its first words
/// were sent: the page the new chat again, the chat not made, they coming back from where they had got to (none
/// while it is the chat: the frame draws it leaving over the chat).
pub fn new_sending(c : @ui.Ctx) -> (Double, Double) {
  if fresh.sending.get() && fresh.became.get() is None {
    (new_leave(c).get(c), new_fade(c).get(c))
  } else {
    (0.0, 0.0)
  }
}

///|
/// What was picked, as one string: a pick changed makes the chat anew (until a message went to it).
pub fn picked_sig(v : Json?) -> String {
  text(field(v, "model"), "model") +
  "|" +
  text(v, "runtime") +
  "|" +
  text(v, "effort") +
  "|" +
  text(v, "profile") +
  "|" +
  (match field(v, "fast") {
    Some(True) => "fast"
    Some(False) => "standard"
    _ => ""
  })
}

///|
/// What is picked now (`v`, the newChat view): the chat made for it before is let go if it was made with other picks
/// and nothing was sent to it yet.
pub fn fresh_picked(v : Json?) -> Unit {
  if !fresh.sent.get() && !fresh.starting.get() && picked_sig(v) != fresh.made_sig.get() {
    fresh.made.set("")
  }
}

///|
/// Picks for a new chat in the workspace (`newChat.pick`, the core keeps them): each given changes only that.
pub fn pick_new(src : Source, ws : String, fill : Map[String, Json]) -> Unit {
  if src.read_only {
    toast_later(read_only_words)
    return
  }
  fill["scope"] = Json::string(ws)
  (src.call)("newChat.pick", Json::object(fill), fn(res) {
    match res {
      Err(e) => {
        toast_later(@sf.t("android-chat.pick.failed", args=[("error", text(Some(e), "message"))]))
      }
      _ => ()
    }
  })
}

///|
/// The view of the chat a new chat became (`r`), as it is till the core's is read: made with nothing in it but its
/// title (what the page was, 新对话, as the core calls it) and what was sent from here, never said to be empty, as the
/// core's first view of it has its first message in its outbox (views.ts pendingChat); kept for the chat so each frame
/// reads the same (None for any other chat).
pub fn fresh_view(r : ChatRef) -> (ChatView, Array[Entry])? {
  match fresh.became.get() {
    Some(b) if b == r =>
      match fresh_views.val {
        Some((k, v, list)) if k == r => Some((v, list))
        _ => {
          let v = chat_view_made({
            "title": Json::string(r.title),
            "pending": Json::boolean(true),
            "key": Json::string(r.session),
          })
          // (never empty: its first message is in it from the frame it was sent, sent_local)
          let list = entries_of(v).filter(fn(e) { !(e is Empty) })
          fresh_views.val = Some((r, v, list))
          Some((v, list))
        }
      }
    _ => None
  }
}

///|
// kept across runs: one chat's, made again for another (fresh_view)
let fresh_views : Ref[(ChatRef, ChatView, Array[Entry])?] = Ref(None)

///|
/// Whether chat `r` is the one a new chat just became, its scene still leaving over it (till the end declared as it
/// set out).
pub fn new_chat_leaving_of(c : @ui.Ctx, r : ChatRef) -> Bool {
  match fresh.became.get() {
    Some(b) => b == r && !new_leave(c).over(c)
    None => false
  }
}

///|
/// Whether `draft` (`station:session`) is the chat a new chat just became while its first words are still on their way
/// (`flight_carried` on the old list, or `new_first_fly` on the list made as nodes).
pub fn new_first_flying(c : @ui.Ctx, draft : String) -> Bool {
  flight_carried(draft) ||
  (match fresh.became.get() {
    Some(b) => b.station + ":" + b.session == draft && !new_first_fly(c).over(c)
    None => false
  })
}

///|
/// Whether chat `r` was just made from a new chat, its scene still leaving or its first words still carried: the
/// core's own, its first view not read yet, nothing breathing over it.
pub fn new_chat_made(c : @ui.Ctx, r : ChatRef) -> Bool {
  match fresh.became.get() {
    Some(b) if b == r => !new_leave(c).over(c) || new_first_flying(c, r.station + ":" + r.session)
    _ => false
  }
}
