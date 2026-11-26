// The app's presets (sf/motion.mbt, Presets: each kind's few, every motion one of them), the web's at the same place:
// its ease-out, what comes into and goes from a list, the spring what makes way moves by, a shape, the list's glide,
// the most a motion waits for what is here already, a control answering the hand, what is woken, the breath, copied.
// Those the framework makes are mbui's, named there and in the table (kit's pop_in, dialog_in, switch_ms,
// progress_ms, media's; @motion's springs; ui's pages pushed); motion as data is mbui's (@motion, Ctx::move_state:
// the web's moveState). What moves (a shape, the composer to another page, a state moved) is a Move as long as its
// way is far (@ui.move_ms, @motion.moved), never a length of its own.
//
// Every motion is set off by its cause, never found by comparing frames (the user, 2026-10-25: 「我感觉现在有不少动
// 效 bug 是因为用了类似 css 的"过渡"效果，而没有准确地去控制什么时候应该去哪，而是直接检测差值」): a difference
// cannot know why it happened, so a resize, a dragged sidebar or a keyboard would move what only typing should.

///|
/// What comes into a message list (ENTER, ENTER_FROM): 220 ms on the ease-out, up from 6 below as it fades in.
pub let enter_ms : Double = 220.0

///|
pub let enter_rise : Double = 6.0

///|
/// What goes from a list (LEAVE): a copy where it was, shrinking to 0.9 as it
/// fades over 200 ms on CSS's ease-out (`leave`).
pub let leave_ms : Double = 200.0

///|
pub let leave_scale : Double = 0.9

///|
// kept across runs: a value (no field of it changes)
pub let leave : @motion.Trans = @motion.trans(fade=0.0, scale=leave_scale, spec=@motion.tween(leave_ms, ease=Leave))

///|
/// What is put in the composer to go with the message, a file's card, a picture's tile, a quote's card (Chat.css.ts
/// fileCard, composerQuote; Jobs.css.ts composerThumb: enterUpKeyframes): up from 6 below as it fades in, over 180 ms
/// on the ease-out.
// kept across runs: a value (no field of it changes)
pub let waiting_in : @motion.Trans = @motion.trans(fade=0.0, dy=enter_rise, spec=@motion.tween(180.0, ease=Out))

///|
/// The composer's hint, gone at once as words sent leave its field, back once they are out of it (madeChat.css.ts:
/// the placeholder's colour over 200 ms on cubic-bezier(.2, .8, .2, 1), the arrival's curve).
pub let hint_back_ms : Double = 200.0

///|
/// The most a motion, or a page moved to, waits for what is here already (LOCAL_MS): the core's answer from what it
/// holds, a picture decoded. Never for the network.
pub let local_ms : Double = 100.0

///|
/// A control answering the hand (--dur, global.css.ts): pointed at, pressed, a switch turned, over this long on the
/// ease-out.
pub let dur_ms : Double = 140.0

///|
/// The most a popover grown from beside what opened it (pop_in about FromBeside: a menu, a panel, a pick, a hover card,
/// what is offered) stands off where it is laid out at its farthest edge, in points (View::scale's max_shift). A tall
/// one (600 to 750 high) gone above its anchor grows from its foot, so at 0.97 its top row would come 18 to 22.5 below
/// where it lands on its first frame, over half a 36-high row; kept within 8, its whole way in and out narrowed alike.
/// One whose farthest edge from where it grows (its width or its height, whichever is more) is 266 or less stays
/// within it at 0.97, drawn as big as pop_in says; a wider one (a panel 360 wide) is kept within it as a tall one is.
let pop_max_shift : Double = 8.0

///|
/// Popover enter transition for node `v`: single-layer liquid glass fades together with its content (`glass_pop_in`),
/// while `MBUI_GLASS=solid` falls back to `pop_in` (`ground_first=true`) to preserve solid occlusion.
fn pop_in_for(v : @view.View) -> @motion.Trans {
  if v.glass_solid() { @motion.pop_in } else { @motion.glass_pop_in }
}

///|
/// Popover exit transition for node `v`: single-layer liquid glass fades together on `InOut` (`glass_pop_out`),
/// while `MBUI_GLASS=solid` falls back to `pop_out` (`Leave`, `ground_first=true`).
fn pop_out_for(v : @view.View) -> @motion.Trans {
  if v.glass_solid() { @motion.pop_out } else { @motion.glass_pop_out }
}

///|
/// Exit ease matching `pop_out_for(v)` (`Leave` under `MBUI_GLASS=solid`, `InOut` on liquid glass).
fn pop_out_ease_for(v : @view.View) -> @ui.Ease {
  if v.glass_solid() { Leave } else { InOut }
}

///|
/// What says a thing was copied (a check for the copy button, 已复制) shows this long (parts.tsx CopyButton: 1.6 s).
pub let copied_ms : Double = 1600.0

///|
/// What is woken by the hand over a picture or a film (the viewer's bars, the player's controls) comes in over this
/// long, and fades as it rests over `sleep_ms`, on the ease-out (FilePreview.css.ts floating, viewer/media.css.ts: 120,
/// 320): kit's media controls' own.
pub let wake_ms : Double = @player.media_wake_ms

///|
pub let sleep_ms : Double = @player.media_sleep_ms

///|
/// One breath of what waits (waiting.css.ts breathe): 1.4 s, from whole to `low` and back on
/// CSS's ease-in-out each way.
pub let breath_ms : Double = 1400.0

///|
/// How clear a thing coming or going is drawn at `scale` of its size: not at all at half of it or less, wholly at its
/// size, as a list's row coming or going is (@ui.row_gone_at, the user, 2026-10-31: 缩到 50% 左右的时候就变成完全看不见).
/// A fade of its own goes on top of this.
pub fn seen_at(scale : Double) -> Double {
  if scale <= @ui.row_gone_at {
    0.0
  } else if scale >= 1.0 {
    1.0
  } else {
    (scale - @ui.row_gone_at) / (1.0 - @ui.row_gone_at)
  }
}

///|
/// A control that cannot be pressed answering a press on it all the same (a control answering): shaken across and
/// back over `refused_ms`, `refused_reach` at most, dying away as it goes (refused_dx), so that a press that found it
/// disabled is told from one that missed it.
pub let refused_ms : Double = 260.0

///|
pub let refused_reach : Double = 3.5

///|
/// How far across a control refusing a press is drawn off its place `t` of the way through its shake (0 to 1): three
/// half swings dying away by the square of what is left, sin(3πt)·(1 − t)²·refused_reach; none at its start, none at
/// its end, nothing stepped between.
pub fn refused_dx(t : Double) -> Double {
  if t <= 0.0 || t >= 1.0 {
    return 0.0
  }
  let left = 1.0 - t
  @dmath.sin(t * 3.0 * @math.PI) * left * left * refused_reach
}

///|
/// Control `v` answering a press it does not take while `refuses()` (disabled, not at work: what it is to the hand, the
/// keyboard and a screen reader unchanged, its press never run): a finger or the pointer gone down on it where it is
/// drawn (no modal layer over it, nothing drawn over it there taking it) and let go there as a tap (not moved past the
/// slop), it still where it was (no column scrolled under the hand meanwhile), it is shaken across (refused_dx, set out
/// at the moment it was let go) where it is drawn alone, nothing laid out again for it; at rest, drawn exactly where it
/// is laid out, nothing asking a frame. A press that disables it (send, once it is sent) is none of its. Felt as a
/// refusal under a finger; under reduced motion, shaken at once (ShakeWay: nothing seen of it). Nothing of it is made till the first such press: before,
/// it only follows whether it refuses, and the window's presses and taps only while it does.
#callsite(autofill(loc))
pub fn refused_shake(v : @view.View, refuses : () -> Bool, loc~ : SourceLoc) -> Unit {
  // (where it was drawn as a press went down on it while it refused; none: the press is not one of its)
  let armed : Ref[(Double, Double)?] = Ref(None)
  let shake : Ref[@motion.ShakeWay?] = Ref(None)
  // (the window's presses and taps as last followed, untracked: what changed of them told apart)
  let seen = Ref(@signals.untracked(fn() { (v.window_downs(), v.window_taps()) }))
  let refused_was = Ref(@signals.untracked(refuses))
  // (the window's presses gone down and taps let go, followed while it refuses: a press going down arms it where it
  // lands on it, the tap that lets that press go shakes it; a press moved off as a drag is no tap, and the next press
  // going down arms it anew or not)
  v.reacts(
    fn() {
      if !refuses() {
        None
      } else {
        Some((v.window_downs(), v.window_taps()))
      }
    },
    at_start=false,
    fn(k) {
      guard k is Some((downs, taps)) else {
        armed.val = None
        refused_was.val = false
        return
      }
      let (downs_was, taps_was) = seen.val
      seen.val = (downs, taps)
      // (come to refuse: what the hand did before is none of its, the press that disabled it too)
      if !refused_was.val {
        refused_was.val = true
        return
      }
      if downs != downs_was {
        let (x, y) = v.window_down_point()
        armed.val = if refused_here(v, x, y) {
          let (rx, ry, _, _) = v.rect()
          Some((rx, ry))
        } else {
          None
        }
      }
      if taps == taps_was {
        return
      }
      guard armed.val is Some((rx, ry)) else { return }
      armed.val = None
      let (nx, ny, _, _) = v.rect()
      let slop = @ui.touch_slop()
      if (nx - rx).abs() > slop || (ny - ry).abs() > slop || !refused_here_now(v) {
        return
      }
      if @ui.pointing() is Finger {
        @ui.haptic(Reject)
      }
      let way = match shake.val {
        Some(w) => w
        None => {
          let w = @motion.ShakeWay::new(amplitude=refused_reach, duration_ms=refused_ms, cycles=1.5)
          shake.val = Some(w)
          w.shakes(v, loc~) |> ignore
          w
        }
      }
      way.shake(at=v.cause_at(), loc~)
    },
  )
}

///|
/// Whether a press at (x, y) of the window lands on control `v` while it takes none: within where it is drawn, under no
/// modal layer, and what takes the press there (it taking none) nothing drawn over it: what holds it (a card's press,
/// the column it scrolls in), what it is drawn over (the field it stands in), or nothing at all.
fn refused_here(v : @view.View, x : Double, y : Double) -> Bool {
  let (rx, ry, rw, rh) = v.rect()
  if x < rx || y < ry || x >= rx + rw || y >= ry + rh || !refused_here_now(v) {
    return false
  }
  match v.tree.target_at(x, y) {
    Pressed(id) | Dragged(id) => v.tree.holds(id, v.id()) || drawn_under(v.tree, id, v.id())
    Nothing => true
    Hosted(_) | TopRow(_) => false
  }
}

///|
/// Whether node `under` is drawn before node `over` in the scene, so that `over` lies over it where both are drawn (a
/// composer's field round its send): a press there landed on `over` to the eye, whatever takes it.
fn drawn_under(tree : @view.Tree, under : @view.NodeId, over : @view.NodeId) -> Bool {
  let mut seen_under = false
  for d in tree.drawn() {
    if d.id == under {
      seen_under = true
    } else if d.id == over {
      return seen_under
    }
  }
  false
}

///|
/// Whether control `v` is where a press could reach it now: shown, under no modal layer.
fn refused_here_now(v : @view.View) -> Bool {
  !v.shown_nowhere() && v.tree.allows(v.id())
}
