// A new chat (still.fail web/src/NewChat.tsx and NewChat.css.ts, web/src/mobile/NewChat.tsx and NewChat.css.ts;
// apps/android NewChat.kt; its frequent combinations in the model's panel, model_triple.mbt): say what to do, having
// picked where it runs (the station) and on what (the model, its runtime, how hard it thinks, who runs it), as the
// core keeps them (the `newChat` topic; `newChat.pick`, `pick.set`, `pick.save`). One page in every frame, laid out by
// its own width as the web lays out its two:
// - narrow (under @sf.page_narrow_most), as the web's mobile page: the scene (the picture, what to do and where, what
//   keeps it from starting, the machine's own sessions) over all that is left, scrolled when it does not fit; at its
//   foot what is wrong for now, the choices in glass capsules (the station, the model: each through the presenters),
//   the composer where a chat has it;
// - wide, as the web's desktop page: a column 720 wide at most, the scene and the composer in the middle of the pane,
//   the composer roomy with the choices in the row under its words (the station's chooser, the model control:
//   model_triple.mbt), what differs by the station and its picks under it, moving nothing over it.
// The composer is the pages' (composer.mbt), its draft the workspace's new chat's (`new:<workspace>`), whichever
// station it is to run on: its files wait, and go up to that one as the first message is taken to go
// (`composer.take {station}`), the message waiting for them. The first message
// makes the chat (`newChat.create`, made once a page, anew when the picks changed: useEnsureChat) and goes to it
// (`chat.send` by its key); the page becomes the chat in place, its first words carried where they were typed till
// their row is in the chat's list (flight.mbt), what is written meanwhile going on into the chat's draft
// (`composer.carry`); over the chat its scene and what is under it fade where they are
// . The frame says what is over it and under it, and what it does as the page
// becomes the chat (NewChatFrame).

///|
/// What the page keeps of its own: which of its picks is asked open as it is next drawn (a fixture's: new_chat_ask).
priv struct NewChatPage {
  mut asked : String
  mut send_seq : Int
}

///|
/// What a new chat's draft begins with, its workspace's id after it: one of its own in each workspace.
pub let new_chat_drafts : String = "new:"

///|
let new_chat_state : NewChatPage = { asked: "", send_seq: 0 }

///|
fn new_chat_reset() -> Unit {
  new_chat_state.asked = ""
  new_chat_asked_seq.set(0)
}

///|
/// How many times one of the page's picks was asked open (new_chat_ask's): what is made already told by it, a page on
/// screen opening it then as one made after it does.
// kept across runs: put back by new_chat_reset
let new_chat_asked_seq : @signals.Signal[Int] = @signals.signal(0)

///|
/// One of the page's picks opened as it is next drawn narrow, as though its capsule were pressed: "station" where it
/// runs, "model" what it runs on (a fixture's screen of it).
pub fn new_chat_ask(what : String) -> Unit {
  new_chat_state.asked = what
  new_chat_asked_seq.set(new_chat_asked_seq.untracked() + 1)
}

///|
/// Workspace `ws`'s new chat as the core is asked it (`newChat`: where it starts, what it runs on, the stations it
/// can): one ask wherever it is read.
pub fn new_chat_asked(ws : String) -> Map[String, Json] {
  { "scope": Json::string(ws) }
}

///|
/// What workspace `ws`'s new chat opens on, asked of `ask` (sfbase's opens_answered): its view, or why it has none.
/// While it is not, the page shows its stations as read (in their bones).
pub fn new_chat_opens(ws : String, ask : (String, Map[String, Json]) -> @sfbase.TopicState) -> Bool {
  @sfbase.opens_answered(ask("newChat", new_chat_asked(ws)))
}

///|
/// A station's name as the page says it: "this machine" for one not named.
fn new_station_words(station : Json?) -> String {
  match text(station, "name") {
    "" => @sf.t("web-main.newChat.thisMachine")
    n => n
  }
}

// ── narrow: the web's mobile page ─────────────────────────────────────────

///|
/// Where a new chat starts and what it runs on, made up, for what shows while they are read (in their bones).
fn new_sample_station() -> Json {
  { "station": "sample", "name": Json::string(@sf.sample_words(4)) }
}

///|
fn new_sample_view() -> Json {
  {
    "runtime": "claude",
    "model": "sample",
    "pick": {
      "value": { "runtime": "claude", "model": "sample" },
      "valueOption": { "name": Json::string(@sf.sample_words(6)) },
      "efforts": ["low"],
    },
  }
}

///|
/// Whether `what` was asked open (new_chat_ask), let go of as it is.
fn take_asked(what : String) -> Bool {
  if new_chat_state.asked != what {
    return false
  }
  new_chat_state.asked = ""
  true
}

// ── wide: the web's desktop page ──────────────────────────────────────────

///|
/// What follows a new chat's first message sent from either page (new_send's, new_chat_node's), its row `row` of `rk`
/// in the list from now: the page becomes chat `r` (by its key `key`, made for it where `make`), what carries its words
/// said first (`carries`), its scene leaving from here (`leaves`: as the page that sent it draws that, said before the
/// chat's page mounts), the frame told (`sent`); what the core does, in order: the
/// words taken, the chat made, what is written meanwhile on into its draft; then the message sent into it, once both
/// are. The chat not made: the page the new chat again, its scene back (`back`), what was taken back in its composer,
/// saying why; the message not taken in: back in the chat's composer.
fn new_send_go(
  src : Source,
  sent : (ChatRef) -> Unit,
  v : Json?,
  station : String,
  key : String,
  make : Bool,
  d : Writing,
  rk : String,
  row : String,
  r : ChatRef,
  carries : () -> Unit,
  leaves : () -> Unit,
  back : () -> Unit,
) -> Unit {
  let fresh = @sfbase.fresh
  let draft = station + ":" + key
  let sig = @sfbase.picked_sig(v)
  @view.transition(fn() {
    fresh.starting.set(true)
    fresh.sending.set(true)
    fresh.sent.set(true)
    fresh.made.set(key)
    fresh.made_sig.set(sig)
    carries()
    // the page becomes the chat, in place, now: the scene leaving over it from here (new_chat_left), with the words
    // (all of what the chat's page reads as it mounts — its scene, its composer's room and place, its foot, its fly_after —
    // said before `became` mounts it)
    fresh.scene.set(v)
    leaves()
    fresh.became.set(Some(r))
  })
  @sfbase.writing_starting(src, d, true)
  // what the core does, in order: the words taken, the chat made, what is written meanwhile on into its draft; then
  // the message sent into it, once both are
  let taken : Ref[Json?] = Ref(None)
  let made = Ref(!make)
  let sending = Ref(true)
  let toasted = Ref(false)
  let navigated = Ref(false)
  new_chat_state.send_seq += 1
  let send_seq = new_chat_state.send_seq
  let toast_once = fn(msg : String) {
    if !toasted.val && msg != "" {
      toasted.val = true
      toast_later(msg)
    }
  }
  // (this send still the page's: the new chat not begun anew since, nor this one sent again under its key; what the
  // core answers late of one that is not touches nothing of what the page is now)
  let ours = fn() { fresh.made.get() == key && new_chat_state.send_seq == send_seq }
  // (not sent after all: its row gone from the list, its words back in the chat's composer, saying why, unless
  // something is written there by now: then said so, as send_in_chat's)
  let not_sent = fn(why : String) {
    @ui.haptic(Reject)
    sending.val = false
    if ours() {
      fresh.starting.set(false)
    }
    sent_refuse(rk, row)
    @sfbase.flight_carry_gone(draft)
    @sfbase.writing_starting(src, d, false)
    let kept_taken = d.taken
    d.taken = None
    // (what was taken went with the words into the chat's draft: composer.carry; nothing taken, nothing to put back)
    if why != "" {
      let chat_w = @sfbase.writing(src, draft)
      if chat_w.taken is None && kept_taken is Some(_) {
        chat_w.taken = kept_taken
      }
      @sfbase.writing_back_or_said(src, chat_w, @sf.t("web-main.draft.notSent", args=[("error", why)]))
    }
  }
  let return_to_new_chat = fn(clear_made : Bool) {
    let had_cursor = @ui.field_has_focus()
    let here = ours() && app.nav.top() is @sfbase.Page::Chat(top) && top == r
    if ours() {
      if clear_made {
        fresh.made.set("")
      }
      fresh.starting.set(false)
      fresh.became.set(None)
    }
    if here {
      // (the cursor in the chat's composer, as it was taken over from the new chat's (`became`): back with the
      // words in the new chat's, its keyboard as it was; the chat's composer made as nodes is a field of its own,
      // its cursor let go with its page, so asked for there: composer_take_focus; `had_cursor`)
      if had_cursor {
        composer_take_focus()
      }
      back()
      app.nav.become(NewChat)
    }
  }
  let send = fn() {
    match taken.val {
      Some(t) if made.val && sending.val => {
        sending.val = false
        send_taken(src, station, ToSession(key), t, fn(said) {
          match said {
            // (not taken into the chat's outbox: back in its composer, as send_in_chat's)
            SentRefused(why) => not_sent(why)
            // (in the outbox, which says it did not go yet and sends it once the station is reached: its words
            // back in the composer too were sent twice, 2026-11-16)
            SentKept(why) => {
              @ui.haptic(Reject)
              if ours() {
                fresh.starting.set(false)
              }
              @sfbase.flight_carry_gone(draft)
              @sfbase.writing_starting(src, d, false)
              @sfbase.sent_local_gone(rk, row)
              // (never put back: what it took of the draft, its files' bytes, let go of as one taken)
              @sfbase.writing_committed(d)
              toast_once(@sf.t("web-main.draft.notSent", args=[("error", why)]))
            }
            SentTaken => {
              if ours() {
                fresh.starting.set(false)
              }
              @sfbase.writing_starting(src, d, false)
              @sfbase.writing_committed(d)
            }
          }
        })
      }
      _ => ()
    }
  }
  let take_err : Ref[String] = Ref("")
  let take_failed = Ref(false)
  writing_take(
    src,
    d,
    station~,
    on_error=fn(err) { take_err.val = err },
    fn(t) {
      match t {
        Some(_) => {
          taken.val = t
          send()
        }
        // (nothing taken: writing_take already restored local draft in `d`; return to NewChat so the
        // restored draft stays visible instead of stranding the user on an empty Chat page)
        None => {
          take_failed.val = true
          if sending.val {
            not_sent("")
            if navigated.val {
              @sfbase.writing_carry(src, draft, d.key)
              // Keep `fresh.made` intact (if `!make` or `newChat.create` succeeds, retrying Send reuses
              // the created chat; if `newChat.create` later fails, its Err branch clears `fresh.made`).
              return_to_new_chat(false)
            } else if ours() {
              if make {
                fresh.made.set("")
              }
              fresh.starting.set(false)
              fresh.became.set(None)
              back()
            }
            if take_err.val != "" {
              toast_once(@sf.t("web-main.draft.notSent", args=[("error", take_err.val)]))
            }
          }
        }
      }
    },
  )
  // If `composer.take` already failed synchronously before we started `newChat.create` or navigated,
  // stay on NewChat with the restored draft without creating an orphan chat.
  if take_failed.val {
    return
  }
  if make {
    (src.call)("newChat.create", { "station": Json::string(station), "key": Json::string(key) }, fn(res) {
      match res {
        Ok(_) => {
          made.val = true
          send()
        }
        Err(e) => {
          // not made: what is written meanwhile back in the new chat's draft, and what was taken with it (unless
          // something is written there by now: then said so); the page the new chat again, its scene back, only
          // while it is still the chat it became: a page come on top since, or a new chat begun anew, is left as it
          // is (Nav::become changes whatever is on top)
          sending.val = false
          sent_refuse(rk, row)
          @sfbase.flight_carry_gone(draft)
          @sfbase.writing_carry(src, draft, d.key)
          @sfbase.writing_starting(src, d, false)
          let why = @sf.t("web-main.draft.notSent", args=[("error", text(Some(e), "message"))])
          return_to_new_chat(true)
          if take_failed.val {
            // `composer.take` already failed and restored `d` locally (and toasted if it had an error).
            toast_once(why)
          } else {
            // (what was taken comes back with what is written meanwhile: composer.carry; keep d.taken for local fallback)
            @sfbase.writing_back_or_said(src, d, why)
          }
        }
      }
    })
  }
  // what is written meanwhile goes on in the chat's draft
  @sfbase.writing_carry(src, d.key, draft)
  navigated.val = true
  @view.transition(fn() {
    new_chat_reset()
    sent(r)
    app.nav.become(@sfbase.Page::Chat(r))
  })
}


// ── the run picker ────────────────────────────────────────────────────────

///|
/// The column wide (newChatInner: 720 at most, 32 in from the pane's sides), the scene's width (ILLUS_SIZE: 320;
/// narrow 230), a mark and a chevron in a choice.
let new_column_w : Double = 720.0

///|
let new_column_in : Double = 32.0

///|
let new_scene_w : Double = 320.0

///|
let new_scene_narrow_w : Double = 230.0

///|
let new_mark : Double = 14.0

///|
let new_chevron : Double = 12.0

///|
/// A glass choice's corner (a capsule 30 high).
let glass_chooser_corner : Double = 15.0

///|
/// The heading narrow (h2: 6 over it).
// kept across runs: a value (no field of it changes)
let new_heading_box : @ui.Style = @ui.css("w=Full pt=S1_5")

///|
/// What keeps it from starting narrow (mNewProblem: 6 over it).
// kept across runs: a value (no field of it changes)
let new_problem_box : @ui.Style = @ui.css("w=Full pt=S1_5")

///|
/// What is on the band over the composer: what is wrong for now, the choices.
// kept across runs: a value (no field of it changes)
let new_over : @ui.Style = @ui.css("w=Full align=ACenter")

///|
/// The choices narrow (mChoosers: 6 apart, 6 over the composer, 2 in).
// kept across runs: a value (no field of it changes)
let new_choosers_row : @ui.Style = @ui.css("row w=Full px=S0_5 pb=S1_5 gap=S1_5 align=ACenter")

///|
/// A glass choice (mChooser): 30 high, 12 in, 6 between its parts, a capsule; as wide as what it holds needs, never cut
/// by its row (what is beside it gives way, or what of it may leave leaves: its press's ripple keeps to its shape
/// itself).
// kept across runs: a value (no field of it changes)
let glass_chooser_box : @ui.Style = @ui.style(row=true, h=@sf.glass_chooser_h, px=S3, gap=S1_5, align=ACenter, radius=Full)

///|
/// The glass capsule starting with a mark of a corner of its own (new_capsule's `marked`): in from its start by what
/// it is in from the top (the capsule's 15 less the mark's small corner, 7: 8), as the corner rule holds; 12 till
/// 2026-11-14, found on 中屏's Home after a workspace switch with a preset picked.
// kept across runs: a value (no field of it changes)
let glass_chooser_marked_box : @ui.Style = @ui.style(
  row=true,
  h=@sf.glass_chooser_h,
  pl=S2,
  pr=S3,
  gap=S1_5,
  align=ACenter,
  radius=Full,
)

///|
// kept across runs: a value (no field of it changes)
let new_capsule_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Fg, wrap=false, w=Cut)

///|
/// A station's name in its control: cut short past 128 (mChooser's max-width); where its row has not the room for it
/// and the model's control, left out whole, after all that control leaves out (its runtime, how hard it thinks).
// kept across runs: a value (no field of it changes)
let new_station_name : @ui.Style = @ui.style(max_w=@sf.glass_chooser_station_most)

///|
let new_drop_station_name : Int = triple_drop_effort + 1

///|
/// A control in the composer's row (Chooser: 28 high, 8 in, its parts 6 apart, the hover's ground).
// kept across runs: a value (no field of it changes)
let new_capsule_in_row : @ui.Style = @ui.css("row h=S7 px=S2 gap=S1_5 align=ACenter radius=Full hovered{bg=Hover}")

///|
/// Concentric inset for a 14pt circular avatar inside a 28pt capsule: (28 - 14) / 2 = 7.
let new_capsule_marked_in : Double = 7.0

///|
// kept across runs: a value (no field of it changes)
let new_capsule_in_row_marked : @ui.Style = new_capsule_in_row.then(@ui.style(pl=@sf.room_of(new_capsule_marked_in)))

///|
/// A page of a picture and a title alone (mNewNone): 30 in, 10 apart.
// kept across runs: a value (no field of it changes)
let new_alone_box : @ui.Style = @ui.css("w=Full px=S8 gap=S2_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let new_alone_title : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=Fg, center=true, w=Full)

///|
// kept across runs: a value (no field of it changes)
let new_title : @ui.TextStyle = @ui.text_style(size=Heading, weight=Semibold, color=Fg, center=true, w=Full)

///|
/// What it does (newChatSub: 13 on 20, muted, 8 under it).
// kept across runs: a value (no field of it changes)
let new_sub_box : @ui.Style = @ui.css("w=Full pb=S2")

///|
// kept across runs: a value (no field of it changes)
let new_sub : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=Muted, center=true, w=Full)

///|
/// What it waits for (newChatStatus), why its stations could not be read (fieldError).
// kept across runs: a value (no field of it changes)
let new_status : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=Muted, center=true, w=Full)

///|
// kept across runs: a value (no field of it changes)
let new_error : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, color=Danger, center=true, w=Full)

///|
/// The offer of the machine's sessions as the scene's last part narrow: 8 over it.
// kept across runs: a value (no field of it changes)
let new_offer_box : @ui.Style = @ui.css("w=Full pt=S2 align=ACenter")

///|
/// The offer wide, the last of what is under the composer (newChatOffer: in the middle).
// kept across runs: a value (no field of it changes)
let new_offer_under : @ui.Style = @ui.css("w=Full align=ACenter")

///|
/// spentNotice: the amber's 12% under 13's words, 8 by 12 in, the 常用 chips' corner (Xl: the web's rField, 12), 8 under
/// it. Lg, 8, the scale's next step down, drew the bar tighter than the chips right under it.
// kept across runs: a value (no field of it changes)
let new_notice_box : @ui.Style = @ui.css("px=S3 py=S2 mb=S2 radius=Xl bg=A(Warn,O10)")

///|
// kept across runs: a value (no field of it changes)
let new_notice_words : @ui.TextStyle = @ui.text_style(size=Ui, leading=L5, color=Fg, w=Full)
