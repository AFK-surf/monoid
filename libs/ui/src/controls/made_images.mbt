// Pictures made here from what names them (a gradient's colours, a data URL's bytes), kept by the host as images under
// a key that says it all: made the first time they are asked for, the ones least lately asked for let go of beyond a
// count, so that a run that asks for many (a station's icons, every gradient's proportions a window was resized
// through) does not keep the bytes and decodes of all of them for its life. One let go of and asked for again is made
// again from its key (@ui.has_image says it is gone).

///|
/// The pictures one kind of them keeps, by key, and when each was last asked for (a count of askings, not a clock).
priv struct MadeImages {
  most : Int
  at : Map[String, Int]
  mut tick : Int
}

///|
fn MadeImages::new(most : Int) -> MadeImages {
  { most, at: {}, tick: 0 }
}

///|
/// `key` asked for now: `make` it where the host has no image of it (never made, or let go of), then the least lately
/// asked for of the others let go of while more than `most` are kept.
fn MadeImages::ask(self : MadeImages, key : String, make : () -> Unit) -> Unit {
  self.tick += 1
  self.at[key] = self.tick
  if !@ui.has_image(key) {
    make()
  }
  while self.at.length() > self.most {
    let mut oldest = ""
    let mut when = 0
    for k, t in self.at {
      if k != key && (oldest == "" || t < when) {
        oldest = k
        when = t
      }
    }
    guard oldest != "" else { break }
    self.at.remove(oldest)
    @ui.forget_image(oldest)
  }
}

///|
/// As at the start: none kept (a run's own: mbui's on_reset, which lets go of the images too).
fn MadeImages::clear(self : MadeImages) -> Unit {
  self.at.clear()
  self.tick = 0
}
