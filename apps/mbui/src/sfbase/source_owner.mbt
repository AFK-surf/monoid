// A source owned by a view keeps the topics it has read while that view remains alive. A view can explicitly leave
// a topic sooner; different views keep independent readers of the same core subscription.

///|
priv struct ViewSourceTopic {
  key : String
  reading : String
  state : @signals.Computed[TopicState]
  watch : @signals.Watch
}

///|
priv struct ViewSourceOwner {
  base : Source
  live : @signals.Signal[Bool]
  mut reading : TopicReadMode
  mut topics : Array[ViewSourceTopic]
  leaving : Map[String, Bool]
  // its view put by at rest (a page's entry kept left: Source::owned_by_parkable): what it holds of its untracked reads
  // let go of, and none read so till it is taken back
  mut parked : Bool
}

///|
fn view_source_forget(owner : ViewSourceOwner, name : String, params : Map[String, Json]) -> Unit {
  let key = (owner.base.topic_key)(name, params)
  let leaving = owner.topics.filter(fn(t) { t.key == key })
  owner.topics = owner.topics.filter(fn(t) { t.key != key })
  for t in leaving {
    t.watch.stop()
  }
}

///|
fn view_owner_follow(owner : ViewSourceOwner, name : String, params : Map[String, Json], mode : TopicReadMode) -> @signals.Computed[TopicState]? {
  // The lease has its own view cleanup; while being transferred it can move independently of this source's view.
  // Keep the call through the source so wrappers can still remap the topic and its parameters.
  if mode is Lease {
    return Some(scoped_topic(owner.base, name, params, independent=true))
  }
  if !owner.live.get() {
    return None
  }
  // A graph owns its own dependencies. Only an untracked read needs a separate watch belonging to the view.
  if mode is Graph {
    return Some(scoped_topic(owner.base, name, params))
  }
  // (put by at rest: an untracked read holds nothing and answers none, its view drawn by none of it)
  if owner.parked {
    return None
  }
  let key = (owner.base.topic_key)(name, params)
  let reading = exact_topic_key(name, params)
  // Equal wire identities may still have different source-side projections, so only reuse the same raw read's value.
  match owner.topics.iter().find_first(fn(t) { t.reading == reading }) {
    Some(topic) => return Some(topic.state)
    None => ()
  }
  // The owner's watch follows the underlying source, so it does not recursively acquire itself.
  let state = scoped_topic(owner.base, name, params)
  let watch = held_watch()
  owner.topics.push({ key, reading, state, watch })
  watch.read(fn() { state.get() }) |> ignore
  Some(state)
}

///|
/// A source whose reads belong to `view`. A topic is released when this view explicitly leaves it or is let go;
/// another view or graph reader may still hold the same core subscription.
pub fn Source::owned_by(src : Source, view : @view.View) -> Source {
  Source::owned_by_parkable(src, view).0
}

///|
/// Source::owned_by's, and what puts its view by at rest and takes it back (true, false: a page's entry kept left,
/// Nav::try_park_left, and put on again): put by, what its untracked reads hold is let go of (the core's subscription
/// held by none of it, its graph's reads at rest with its view) and none is read so till it is taken back.
pub fn Source::owned_by_parkable(src : Source, view : @view.View) -> (Source, (Bool) -> Unit) {
  let owner : ViewSourceOwner = {
    base: src,
    live: @signals.signal(view.alive()),
    reading: Raw,
    topics: [],
    leaving: {},
    parked: false,
  }
  // (the source made below: what it read untracked, kept by what is worked out of it, let go of as it is put by)
  let owned_ref : Ref[Source?] = { val: None }
  // (put by at rest once at least: only then is what it worked out let go of with it, below; a view never put by goes
  // as a source owned by a view always went)
  let ever_parked = Ref(false)
  let park = fn(on : Bool) {
    owner.parked = on
    if on {
      ever_parked.val = true
      let topics = owner.topics
      owner.topics = []
      for t in topics {
        t.watch.stop()
      }
      match owned_ref.val {
        // (what it worked out kept, each with its value, what that read let go of: worked out anew from it as it wakes)
        Some(owned) => kept_forget_source(owned, kept=true)
        None => ()
      }
    }
  }
  let owned : Source = {
    ..src,
    topic_alive: fn() { owner.live.get() && (src.topic_alive)() },
    topic_lease_own: Some(fn(stop) {
      let parent = match src.topic_lease_own { Some(own) => Some(own(stop)); None => None }
      let here = view.owns_while(stop)
      fn() {
        here()
        match parent { Some(unkeep) => unkeep(); None => () }
      }
    }),
    topic_scope: Some(fn(mode, read) {
      let was = owner.reading
      owner.reading = mode
      let value = read()
      owner.reading = was
      value
    }),
    topic_read: fn(name, params) {
      // Only this delegated read is part of the caller's graph. A callback it invokes may itself make a raw prefetch.
      let mode = owner.reading
      owner.reading = Raw
      let value = match view_owner_follow(owner, name, params, mode) {
        Some(state) => {
          let topic = state.get()
          { value: topic.value, error: topic.error, version: topic.version }
        }
        None => { value: None, error: None, version: 0 }
      }
      owner.reading = mode
      value
    },
    waits: fn(name, params) {
      let mode = owner.reading
      owner.reading = Raw
      let value = match view_owner_follow(owner, name, params, mode) {
        Some(state) => state.get().waiting
        None => false
      }
      owner.reading = mode
      value
    },
    leave: fn(name, params, reason) {
      let key = (src.topic_key)(name, params)
      let ended = Ref(false)
      let stop = fn() {
        if ended.val { return }
        ended.val = true
        match reason {
          Legacy => view_source_forget(owner, name, params)
          Owned(release) => release()
        }
      }
      // A legacy leave has no handle by which to recognize a recursive call. Owned capabilities have distinct
      // identities and can be cancelled independently even when they cover the same topic.
      let legacy = reason is Legacy
      if legacy && owner.leaving.contains(key) {
        stop()
        return
      }
      if legacy { owner.leaving[key] = true }
      // The base observes the leave, but is given only this owner's release capability.
      (src.leave)(name, params, Owned(stop))
      if legacy { owner.leaving.remove(key) }
      stop()
    },
  }
  owned_ref.val = Some(owned)
  if !view.alive() {
    return (owned, park)
  }
  view.owns(fn() {
    owner.live.set(false)
    let topics = owner.topics
    owner.topics = []
    for t in topics {
      t.watch.stop()
    }
    // (its shared topics' followers let go of with it, what still watches them or not (followed_forget_source); what
    // was worked out of what it read, nothing following it, let go of with it where it was ever put by:
    // kept_forget_source)
    match owned_ref.val {
      Some(owned) => {
        // (after the frame that draws it gone, never at once: a page's view let go between frames (a page popped by
        // home()) keeps what it followed asked till then, as a source let go does (source.mbt's), the frame after
        // letting go of all of it; after_drawn_frame, as after_frame runs at once between frames)
        @ui.after_drawn_frame(fn() { followed_forget_source(owned) })
        if ever_parked.val {
          kept_forget_source(owned)
        }
      }
      None => ()
    }
  }) |> ignore
  (owned, park)
}

