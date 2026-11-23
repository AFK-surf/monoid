// A stream (stream.mbt: a picture the host decodes frame by frame) as a node of the window's tree (ui's stream), in
// place of an old view's Ctx::stream. Drawn where the tree draws the node, each frame it is drawn, as big, fitted to it
// as said, at its opacity, in its clip and corners, under what the tree draws after it: the picture the stream shows
// that frame (the last frame its host said decoded, latched as the frame began), nothing until one is. Drawn anew each
// time it is drawn, as a picture is (no row it is in kept and drawn again as kept, nor a list drawn whole as one), so
// that each frame draws the frame shown then. What becomes of each frame handed over is the stream's to say, as ever
// (Stream::new's `shown`, once that frame is painted: drawn or let go). Let go with its node (View::owns): closed then,
// unless what holds it closes it itself (`closes` false: it is only no longer drawn there). Drawn by the app's canvas,
// or, while its `layer` says so, by its system video layer where it has one (Stream::new's `layer`, as Ctx::stream's
// `layer`): an H.264 frame of it shown, stretched to its node, not round, not faded, not in a shot, its hole where the
// tree draws the node, what the tree draws after it over it and what of that takes a finger its covers, as a native
// node's (tree_native.mbt).

///|
/// A stream of the window's tree's: the stream, how its picture is fitted to its node, whether its node closes it.
priv struct TreeStream {
  stream : Stream
  fit : Fit
  closes : Bool
  layer : () -> Bool
}

///|
/// The streams of the window's tree, by the node each is drawn in.
// kept across runs: emptied as a run begins (view_forget); each let go with its node (tree_stream_gone)
let tree_streams : Map[@view.NodeId, TreeStream] = Map([])

///|
/// How many times a stream was put in tree_streams or taken out: what view_draws reads besides a node's content (as
/// tree_natives_rev).
// kept across runs: only counts
let tree_streams_rev : Ref[Int] = Ref(0)

///|
/// Stream `s` drawn in a box of `parent`'s, as big as the box is said to be (by default the room its holder leaves it),
/// its picture fitted to it as `fit` says (FitFill: stretched; FitCover, FitContain as an image's), its corners its own
/// (View::radius). Let go with the node: the stream closed, unless not `closes` (what holds it closes it). On its system
/// video layer where it may be while `layer` says so, as each frame draws it (read as it is drawn, not followed). One
/// stream in one node: given to another while one draws it, a fault. The box made.
#callsite(autofill(loc))
pub fn stream(
  parent : @view.View,
  s : Stream,
  fit? : Fit = FitFill,
  closes? : Bool = true,
  layer? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(b) {
    let id = b.id()
    let tree = b.tree
    // (given to another node still drawn, a fault; one no longer drawn (put by till its change is committed whole as
    // what flies from it is, Tree::departs; leaving; laid out nowhere) hands it over: no longer its, not closed, so
    // that its letting go later closes nothing of this one's)
    // (said in the window its tree is drawn in, whichever window is in place as it is made: in_tree_window)
    in_tree_window(tree, fn() {
      let root = tree.root().id()
      let gone : Array[@view.NodeId] = []
      let mut live_dup = false
      for o, e in tree_streams {
        if o != id && physical_equal(e.stream, s) {
          if tree.holds(root, o) && !tree.leaving(o) && !tree.laid_out_nowhere(o) {
            live_dup = true
          } else {
            gone.push(o)
          }
        }
      }
      for o in gone {
        tree_streams.remove(o)
        tree_streams_rev.val = tree_streams_rev.val + 1
      }
      if live_dup {
        b.fault("stream: one stream given to two nodes of the tree's: a stream is drawn in one place")
      }
      tree_streams_rev.val = tree_streams_rev.val + 1
      tree_streams[id] = { stream: s, fit, closes, layer }
    })
    b.owns(fn() { in_tree_window(tree, fn() { tree_stream_gone(id) }) }) |> ignore
  })
}

///|
/// Stream node `id` let go: its stream closed, or, closed by what holds it, only no longer drawn there.
fn tree_stream_gone(id : @view.NodeId) -> Unit {
  guard tree_streams.get(id) is Some(ts) else { return }
  tree_streams.remove(id)
  tree_streams_rev.val = tree_streams_rev.val + 1
  if ts.closes {
    ts.stream.close()
  }
}

///|
/// Stream node `id`'s `ts` drawn this frame at (`x`, `y`), `w` × `h` where it is drawn, its corners `radius` round, as
/// opaque as `a`: on its system video layer where it may be there (its hole, as a native node's: paint_tree_native),
/// else the picture its stream shows, fitted as it says, as Ctx::paint_stream places an old view's; nothing until one
/// shows.
fn Ctx::paint_tree_stream(
  self : Ctx,
  id : @view.NodeId,
  ts : TreeStream,
  x : Double,
  y : Double,
  w : Double,
  h : Double,
  radius : Double,
  a : Double,
) -> Unit {
  let s = ts.stream
  // (on its layer as Ctx::stream puts an old view's there: an H.264 frame of it shown, stretched, square, whole; a shot
  // shows the picture, drawn here)
  match s.view {
    Some(v) if !shooting.val &&
      s.h264 &&
      ts.fit is FitFill &&
      radius == 0.0 &&
      a >= 1.0 &&
      !s.closed &&
      s.at is Some(_) &&
      (ts.layer)() => {
      let radii = FixedArray::from_array([0.0, 0.0, 0.0, 0.0])
      if v.paint_in(self, x, y, w, h, None, radii) {
        v.island = Some(id)
        v.hits_before = tree_hits_passed.val
      }
      return
    }
    _ => ()
  }
  let (pw, ph) = match s.size {
    Some((pw, ph)) if !s.closed && s.id != 0 && pw > 0 && ph > 0 => (pw.to_double(), ph.to_double())
    _ => return
  }
  if w <= 0.0 || h <= 0.0 {
    return
  }
  let (x, y, w, h, u0, v0, du, dv) = match ts.fit {
    FitFill => (x, y, w, h, 0.0, 0.0, 1.0, 1.0)
    FitCover | FitCoverAt(_) | FitCoverFrom(_, _) => {
      let k = dmax(w / pw, h / ph)
      let du = w / k / pw
      let dv = h / k / ph
      let (across, down) = ts.fit.cover_from()
      (x, y, w, h, (1.0 - du) * across, (1.0 - dv) * down, du, dv)
    }
    FitContain => {
      let k = dmin(w / pw, h / ph)
      let cw = pw * k
      let ch = ph * k
      (x + (w - cw) / 2.0, y + (h - ch) / 2.0, cw, ch, 0.0, 0.0, 1.0, 1.0)
    }
  }
  self.push_inst(x, y, w, h, radius, 4.0, 0.0, 0.0, 0xFFFFFFFFL, a, u0, v0, du, dv)
  self.inst[(self.ninst - 1) * inst_size + 20] = (@hostapi.stream_tex_base + s.id).to_double()
}
