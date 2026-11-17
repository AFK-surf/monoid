// What the delivery of old threads' messages waits for (station/src/sessions/post-block-builder.ts): the post block
// index of each thread from the first message delivered on, built by the MoonBit builder (station/mb src/posts,
// `--builder post-blocks`), whose process the station starts, feeds and lets go idle. What is decided here: which
// threads a delivery waits on and from where, and whether what the builder has covered answers a waiter.

///|
/// The threads `messages` (`{thread, n}`) are of, each from its first message delivered: (thread, after), in the order
/// each thread came first.
pub fn post_block_threads(messages : Array[J]) -> Array[(J, Double)] {
  let out : Array[(J, Double)] = []
  for m in messages {
    let t = at(Some(m), "thread").unwrap_or(Null)
    let n = num_of(at(Some(m), "n")).unwrap_or(0.0)
    match out.search_by(x => jeq(x.0, t)) {
      Some(i) => out[i] = (t, @cmp.minimum(out[i].1, n))
      None => out.push((t, n))
    }
  }
  out
}

///|
/// Whether a waiter of a thread from `after` is answered by what the builder covered: all of it (`complete`), or from
/// a cursor no later than the message after it.
pub fn post_block_answered(complete : Bool, cursor : Double?, after : Double) -> Bool {
  if complete {
    return true
  }
  match cursor {
    None => false
    Some(c) => !(c > after + 1.0)
  }
}
