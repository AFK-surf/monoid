// What the core hands the window's frames, in the same process: typed values, never JSON. The core, on a runtime of
// its own, `tell`s each change as it comes; the first after the frames last took asks for a frame (`wake`: mbui's
// `@ui.wake_frame`), however many follow before it; that frame takes them all at once as it begins (`take`, given to
// mbui's `@ui.on_frame_take`). What is told while a frame takes, or left for the next (`take`'s `most`), asks for the
// next frame. Nothing is polled: with nothing told, no frame is asked for.

///|
/// The changes of type `T` the core told the frames since they last took.
pub struct FrameOutbox[T] {
  priv mut queue : Array[T]
  priv wake : () -> Unit
  /// Whether a frame was asked for and has not taken yet.
  priv mut asked : Bool
  /// How many frames were asked for, and how many took: for measures and tests.
  priv mut wakes : Int
  priv mut takes : Int
}

///|
/// An outbox asking for a frame by `wake`.
pub fn[T] FrameOutbox::new(wake : () -> Unit) -> FrameOutbox[T] {
  { queue: [], wake, asked: false, wakes: 0, takes: 0 }
}

///|
fn[T] FrameOutbox::ask(self : FrameOutbox[T]) -> Unit {
  if self.asked {
    return
  }
  self.asked = true
  self.wakes += 1
  (self.wake)()
}

///|
/// A change for the frames: kept, a frame asked for if none is yet.
pub fn[T] FrameOutbox::tell(self : FrameOutbox[T], change : T) -> Unit {
  self.queue.push(change)
  self.ask()
}

///|
/// What was told since the frames last took, in order, the outbox left empty: `most` of it at most, the rest left for
/// the next frame, which is asked for.
pub fn[T] FrameOutbox::take(self : FrameOutbox[T], most? : Int) -> Array[T] {
  self.asked = false
  self.takes += 1
  match most {
    Some(m) if m < self.queue.length() => {
      let m = if m < 0 { 0 } else { m }
      let out = self.queue[:m].to_owned()
      self.queue = self.queue[m:].to_owned()
      self.ask()
      out
    }
    _ => {
      let out = self.queue
      self.queue = []
      out
    }
  }
}

///|
/// How many changes wait.
pub fn[T] FrameOutbox::waiting(self : FrameOutbox[T]) -> Int {
  self.queue.length()
}

///|
/// How many frames it asked for so far.
pub fn[T] FrameOutbox::wakes(self : FrameOutbox[T]) -> Int {
  self.wakes
}

///|
/// How many times the frames took so far.
pub fn[T] FrameOutbox::takes(self : FrameOutbox[T]) -> Int {
  self.takes
}
