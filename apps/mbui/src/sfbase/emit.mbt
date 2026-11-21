// An agent's message coming out of its activity's avatar (still.fail apps/android chat/screens/ChatMotion.kt; web
// useEmissions), one at a time: the activity folds to its avatar (Fold), the avatar glides to where the message goes
// (Float), the message comes out of it as it is there (Spit), and the avatar glides on to where the activity now is,
// which unfolds again (Return). One way from its activity and back, no hop (the user, 2026-10-31: 「整个头像运动需要流
// 畅且符合逻辑，并且不要有突变」, then 「不要跳跃了」): each glide sets out from rest where the one before left the
// avatar and comes to rest where it goes, so it never jumps, stops dead or starts at speed. Until its turn a message
// waits out of the list. With motion reduced, each pose at once. Messages no one watches just appear: arriving while
// the page is not in front or the reader has scrolled up, and all still waiting when that happens. Only drawn: the
// message is laid out (and tapped) where it is from the frame it comes into the list; the flying avatar is a picture
// over the list.

///|
#derive(Eq, Debug)
pub(all) enum Pose {
  Fold
  Float
  Spit
  Return
}

///|
/// By its name, as tests count frames by a turn's pose: what `derive(Show)` wrote.
pub impl Show for Pose with output(self, logger) {
  logger.write_string(
    match self {
      Fold => "Fold"
      Float => "Float"
      Spit => "Spit"
      Return => "Return"
    },
  )
}

///|
pub fn Pose::ms(self : Pose) -> Double {
  match self {
    Fold => 110.0
    Float => 220.0
    Spit => 380.0
    Return => 320.0
  }
}

///|
/// What is left of a message's coming out once it shows in the list (it comes out as the avatar lands: Spit), to the
/// avatar home again (Return).
pub let emit_out_ms : Double = Spit.ms() + Return.ms()

///|
/// The same agent's next message, waiting as one comes out: the avatar glides on to it from the one before, not
/// going home first (how long).
pub let emit_drop_ms : Double = 280.0

///|
/// A message's turn: its seq and agent, its pose and how far through it (`clock`, 0 to 1, said as the pose sets out,
/// from where the pose before was declared to end); `from`, on from the same agent's message before it (where its
/// avatar is), dropping on without going home.
pub(all) struct Turn {
  seq : Double
  agent : String
  pose : Pose
  from : (Double, Double)?
  clock : @motion.Anim
  /// how long its clock is (ms)
  span : Double
  /// its way stretched as it goes (a Float waiting for words sent to land, emit_step): how far it was, how fast it went
  /// on and how fast it ends, over its clock (0 to 1: emit_clock); None: the clock itself
  warp : (Double, Double, Double)?
}

///|
/// A chat's messages coming out of avatars.
pub(all) struct Emits {
  decided : Map[String, Bool]
  done : Map[String, Bool]
  /// waiting: seq, agent, its activity's folding (from when it began waiting)
  queue : Array[(Double, String, @motion.Anim)]
  mut current : Turn?
  /// where the flying avatar was last sent, for which message; where it last let one out
  mut aimed : (Double, Double)?
  mut aimed_at : Double
  mut landed : (Double, Double)?
  /// where the flying avatar's activity's avatar was last drawn: where it goes home to (Return)
  mut home : (Double, Double)?
  /// whether what comes in is watched (the page in front, the reader at its end), as last drawn
  mut watched : Bool
  /// the agent whose avatar the flying copy shows as (its activity's own hidden), "" none
  mut copied : String
  /// the flight as last worked out: how far through its pose, from where (y) to where (y), for the motion log
  mut trace : (Double, Double, Double)
  /// what it is said to move by (Ctx::moving): its turns, each pose's end known as it starts
  mover : @ui.Mover
  /// a message's coming in held for words sent from here on their way (emit_step): till their declared landing (-1:
  /// none)
  mut held_until : Double
  /// the first row of what was sent from here not in the chat yet (the outbox's, under the messages), as last built
  /// ("" none): a message coming in comes in over it
  mut out_key : String
  /// the chat's messages as last taken (emit_take), each decided: the same version again holds none new
  mut taken : Array[Message]
  /// the chat's messages' keys as last taken by key (emit_take_keyed): the same order again holds none new
  mut taken_keys : Array[String]
  /// each message out of an avatar coming out (its seq's): its words' way in, 0 to 1 over emit_out_ms_most from the
  /// avatar landing on it (emit_out)
  out_at : Map[String, @motion.Anim]
  /// how many times it changed, as a signal (Emits::changed): what reads it (a message's row, an activity's:
  /// Emits::read) is built again as it does, kept or not (mbui's kept_nodes.mbt)
  said : @signals.Signal[Int]
}

///|
/// It changed (a message come to wait, a pose on to the next, one let go, where it flies from or lands): what read it
/// is told.
pub fn Emits::changed(self : Emits) -> Unit {
  self.said.set(self.said.untracked() + 1)
}

///|
/// What is built from it reads it so (its fields read as they are): built again as it changes.
pub fn Emits::read(self : Emits) -> Unit {
  self.said.get() |> ignore
}

///|
pub let emits : Map[String, Emits] = Map([])

///|
pub fn emits_of(key : String) -> Emits {
  match emits.get(key) {
    Some(e) => e
    None => {
      let e = {
        decided: {},
        done: {},
        queue: [],
        current: None,
        aimed: None,
        aimed_at: -1.0,
        landed: None,
        home: None,
        watched: false,
        copied: "",
        trace: (0.0, 0.0, 0.0),
        mover: @ui.Mover::new(),
        held_until: -1.0,
        out_key: "",
        taken: [],
        taken_keys: [],
        out_at: {},
        said: @signals.signal(0),
      }
      emits[key] = e
      e
    }
  }
}

///|
pub fn seq_s(seq : Double) -> String {
  seq.to_int64().to_string()
}

///|
/// Whether an agent's message comes in with no avatar to come out of, its words a glyph at a time: its row
/// opens where it is, what it holds not grown in.
pub fn emit_words_only(e : Emits, seq : Double) -> Bool {
  e.read()
  e.decided.get(seq_s(seq)) == Some(false) && e.out_at.contains(seq_s(seq))
}

///|
/// Whether the message comes (or came) out of an avatar: it never rises in as others do.
pub fn emit_goes(e : Emits, seq : Double) -> Bool {
  e.read()
  e.decided.get(seq_s(seq)) == Some(true)
}

///|
/// Waiting its turn: not in the list yet. From when its avatar sets out for it (Float) it is, not drawn till it comes
/// out (emit_awaited): laid out where it comes in, the rows round it making room for it as the avatar goes there, and
/// the avatar going where it is, not where it is guessed to come (the user, 2026-10-29: 「你头像跳完瞬移就不是突变？」).
pub fn emit_held(e : Emits, seq : Double) -> Bool {
  e.read()
  let k = seq_s(seq)
  if e.decided.get(k) != Some(true) || e.done.contains(k) {
    return false
  }
  match e.current {
    Some(t) if t.seq == seq && t.pose != Fold => false
    _ => true
  }
}

///|
/// In the list where it comes in, its avatar on its way to it (Float): not drawn yet.
pub fn emit_awaited(e : Emits, seq : Double) -> Bool {
  e.read()
  match e.current {
    Some(t) => t.seq == seq && t.pose == Float
    None => false
  }
}

///|
pub fn emit_emitting(e : Emits, seq : Double) -> Bool {
  e.read()
  match e.current {
    Some(t) => t.seq == seq && t.pose == Spit
    None => false
  }
}

///|
/// An agent's activity folded to its avatar: from when its first message begins waiting until its last is out.
pub fn emit_folded(e : Emits, agent : String) -> Bool {
  e.read()
  match e.current {
    Some(t) if t.agent == agent => return true
    _ => ()
  }
  e.queue.iter().any(fn(q) { q.1 == agent })
}

///|
/// Agents whose activity must stay while their messages come out: till the last of them leaves its avatar (Float), its
/// room opening in the list as the activity's closes, on the list's one way.
pub fn emit_keeps(e : Emits) -> Map[String, Bool] {
  e.read()
  let out : Map[String, Bool] = Map([])
  for q in e.queue {
    out[q.1] = true
  }
  match e.current {
    Some(t) if t.pose == Fold => out[t.agent] = true
    _ => ()
  }
  out
}

///|
/// Everything waiting or coming out shows at once, where it is.
pub fn emit_release(e : Emits) -> Unit {
  if e.queue.length() > 0 || e.current is Some(_) || e.copied != "" {
    e.changed()
  }
  for q in e.queue {
    e.done[seq_s(q.0)] = true
  }
  match e.current {
    Some(t) => e.done[seq_s(t.seq)] = true
    None => ()
  }
  e.queue.clear()
  e.current = None
  e.copied = ""
}

///|
/// How long a pose takes (Float on from the message before: only the drop).
pub fn pose_ms(pose : Pose, from : (Double, Double)?) -> Double {
  match pose {
    Float => if from is Some(_) { emit_drop_ms } else { Float.ms() }
    _ => pose.ms()
  }
}

///|
/// One glyph arriving, shared by an agent's message and its activity. `turn` is when its place in reading order
/// would come; its own little variation, fade and rise are the same in either place.
pub fn glyph_in(ms : Double, turn : Double, index : Int, salt : Int) -> @ui.GlyphLook {
  @motion.glyph_in(ms, turn, index, salt)
}

///|
/// One glyph giving way to its successor in the next activity. It fades away before its successor rises and fades in,
/// so the two do not overlap. `turn` is a gentle reading-order bias; each place varies its timing and its rise.
pub fn glyph_change(ms : Double, turn : Double, index : Int, salt : Int, incoming : Bool) -> @ui.GlyphLook {
  @motion.glyph_change(ms, turn, index, salt, incoming)
}

///|
/// A message's words coming out: how long a line's reading takes, the most all that shows of it takes (its lines' share
/// then shorter), a line's height for that (points), how far before or after its turn each glyph may be, how long each
/// takes, and how far each rises.
let emit_line_ms : Double = 120.0

///|
/// One visible line's reading and the last glyph's arrival, including its variation.
pub let glyph_line_ms : Double = emit_line_ms

///|
pub let glyph_line_in_ms : Double = emit_line_ms + emit_glyph_jitter / 2.0 + emit_glyph_ms

///|
/// The span over which the glyphs in an activity begin changing.
pub let glyph_change_line_ms : Double = emit_line_ms

///|
/// The last visible glyph's change, including the largest variation in its speed.
pub let glyph_change_in_ms : Double = glyph_change_line_ms + emit_glyph_ms * 1.2

///|
let emit_screen_ms : Double = 500.0

///|
let emit_glyph_jitter : Double = 50.0

///|
let emit_glyph_ms : Double = 220.0

///|
/// The head's sliding out (ms); how long it all takes at most.
pub let emit_head_ms : Double = 260.0

///|
pub let emit_out_ms_most : Double = emit_screen_ms + emit_line_ms + emit_glyph_jitter / 2.0 + emit_glyph_ms

///|
/// How far a message's head slides out of the avatar (points).
pub let emit_out_slide : Double = 10.0
