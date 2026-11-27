// What the pages work out of the core's topics, worked out once: alien-signals' computed (mbui/signals, its
//), following the core's changes from the core on. Each subscription's changes are a signal the core
// client sets as the core's message for it comes, and as it ends (src/core client.mbt Sub.changes); a topic read
// (Source.topic) reads it, so what a computed reads of a topic it follows, wherever it reads it (in a computed it reads
// in turn too). A page reads a field or two of a topic as it is; what it makes of the whole of it (a chat's messages,
// the chats' list, a folder's entries, an agent's history, a job's output) is a computed here (Kept, Derived), worked
// out again only as what it read changed, and then from what it made last: the core's deltas keep what they do not
// touch (the same JSON), and what is made of that is kept as it was made (a chat's messages, the chats' rows: one row
// changed, one row made). Kept while something follows it (the frames' watch that read it as the window was last built,
// a part kept as it was drawn, a computed of it): one nothing follows is let go as another is made.

///|
/// Computeds kept by a key each (a chat's view by its chat, a folder's entries by its folder) and by the source read:
/// each a computed made of the getter its first read from that source gave (given what it made last, none the first
/// time), read as a computed is (worked out again only as what it read changed), let go of (Computed::dispose) once
/// nothing follows it, as another is made. By the source too: a page's source ends with the page, and a history opened
/// again read the one before it, ended, so it waited in its bones for ever.
pub struct Kept[T] {
  priv kept : SourceKept[T]
}

///|
pub fn[T] Kept::new() -> Kept[T] {
  { kept: { kept: {}, listed: false } }
}

///|
/// What `getter` makes for `key` from `src` (given what it made last): worked out the first time, and again only once
/// what it read changed since; what reads it told only where that comes out another value than before (`==`, or
/// `same` where given: @signals.computed).
pub fn[T : Eq] Kept::read(self : Kept[T], src : Source, key : String, getter : (T?) -> T, same? : (T, T) -> Bool) -> T {
  self.kept.read(src, key, getter, same=same.unwrap_or(@signals.same_value))
}

///|
/// Kept::read whose value is the same as the last only as `same` says (@signals.computed_by).
pub fn[T] Kept::read_by(self : Kept[T], src : Source, key : String, getter : (T?) -> T, same~ : (T, T) -> Bool) -> T {
  self.kept.read(src, key, getter, same~)
}

///|
/// How many are kept in all the Kepts (`made`), and how many were left as those nothing followed were last let go.
priv struct KeptCount {
  mut made : Int
  mut left : Int
}

///|
// kept across runs: back to 0 by kept_reset
let kept_count : KeptCount = { made: 0, left: 0 }

///|
/// Fewer kept than this, none let go as another is made.
// kept across runs: a value
let kept_sweep_least : Int = 64

///|
/// How many Kepts' reads are under way (a getter reading another Kept): none let go meanwhile.
// kept across runs: back to 0 as each read ends
let kept_working : Ref[Int] = Ref(0)

///|
/// What was made last for `key`, if it is kept: not worked out again, nothing it reads asked for.
pub fn[T] Kept::peek(self : Kept[T], key : String) -> T? {
  self.kept.peek(key)
}

///|
/// What a new one made does with a Kept that kept anything, and what reset does.
priv struct KeptList {
  sweep : () -> Unit
  clear : () -> Unit
  forget_source : (Source, Bool) -> Unit
  forget_matching : (Source, (String) -> Bool) -> Unit
}

///|
// kept across runs: the Kepts themselves, each listed once; what they keep let go of by kept_reset
let kept_lists : Array[KeptList] = []

///|
fn init {
  // a run anew (a Tester begun: another test's) lets go of everything, whatever the source it reads
  @ui.on_reset(kept_reset)
}

///|
/// Everything worked out let go (the app's reset, a run anew).
fn kept_reset() -> Unit {
  for l in kept_lists {
    (l.clear)()
  }
  kept_working.val = 0
  kept_count.made = 0
  kept_count.left = 0
}

///|
/// A derived value belongs to both its parameters and the source that produced it. Sources may share a wire topic
/// while giving it different projections, or one view's source may end while another still reads the same topic.
priv struct SourceKept[T] {
  kept : Map[String, Array[SourceKeptOne[T]]]
  mut listed : Bool
}

///|
priv struct SourceKeptOne[T] {
  source : Source
  value : @signals.Computed[T]
}

///|
fn[T] SourceKept::read(self : SourceKept[T], source : Source, key : String, getter : (T?) -> T, same~ : (T, T) -> Bool) -> T {
  let entries = match self.kept.get(key) {
    Some(entries) => entries
    None => {
      let entries = []
      self.kept[key] = entries
      entries
    }
  }
  let one = match entries.search_by(fn(entry) { physical_equal(entry.source, source) }) {
    Some(i) => {
      let found = entries[i]
      if i != entries.length() - 1 {
        entries.remove(i) |> ignore
        entries.push(found)
      }
      found
    }
    None => {
      // (those nothing follows let go once there are twice as many as were left the last time, so making n costs O(n) in
      // all; where no getter is working one out, whose own is not followed yet)
      if kept_working.val == 0 && kept_count.made >= 2 * kept_count.left &&
        kept_count.made >= kept_sweep_least {
        for l in kept_lists {
          (l.sweep)()
        }
        kept_count.left = kept_count.made
      }
      let made = { source, value: @signals.computed_by(getter, same~) }
      entries.push(made)
      kept_count.made += 1
      if !self.listed {
        self.listed = true
        kept_lists.push({
          sweep: fn() { self.sweep() },
          clear: fn() { self.clear() },
          forget_source: fn(src, kept) { self.forget_source(src, kept~) },
          forget_matching: fn(src, matches) { self.forget_matching(src, matches) },
        })
      }
      made
    }
  }
  kept_working.val += 1
  let v = one.value.get()
  kept_working.val -= 1
  v
}

///|
/// The last value read for these parameters, without acquiring another topic.
fn[T] SourceKept::peek(self : SourceKept[T], key : String) -> T? {
  match self.kept.get(key) {
    Some(entries) if entries.length() > 0 => entries[entries.length() - 1].value.peek()
    _ => None
  }
}

///|
/// The value last read from this particular source, without acquiring a topic or changing the last-read order.
fn[T] SourceKept::peek_from(self : SourceKept[T], source : Source, key : String) -> T? {
  match self.kept.get(key) {
    Some(entries) =>
      match entries.iter().find_first(fn(entry) { physical_equal(entry.source, source) }) {
        Some(entry) => entry.value.peek()
        None => None
      }
    None => None
  }
}

///|
/// Forget just one source's value. A graph still following it keeps its dependencies until that graph lets it go.
fn[T] SourceKept::forget_from(self : SourceKept[T], source : Source, key : String) -> Unit {
  match self.kept.get(key) {
    Some(entries) =>
      match entries.search_by(fn(entry) { physical_equal(entry.source, source) }) {
        Some(i) => {
          let entry = entries[i]
          if !entry.value.watched() { entry.value.dispose() }
          entries.remove(i) |> ignore
          kept_count.made -= 1
          if entries.length() == 0 { self.kept.remove(key) |> ignore }
        }
        None => ()
      }
    None => ()
  }
}

///|
/// What source `source` read that nothing follows let go of, whatever its key (a page's source put by at rest:
/// kept_forget_source): one read untracked holds what it read (a topic's subscription) till it is let go. `kept`: what
/// it read let go of alone, each kept with its value (a page put by at rest, taken back: worked out anew from what it
/// was, as a getter given its last value keeps it till what it reads answers again).
fn[T] SourceKept::forget_source(self : SourceKept[T], source : Source, kept? : Bool = false) -> Unit {
  if kept {
    for _, entries in self.kept {
      for e in entries {
        if physical_equal(e.source, source) && !e.value.watched() {
          e.value.dispose()
        }
      }
    }
    return
  }
  let keys : Array[String] = []
  for key, entries in self.kept {
    if entries.iter().any(fn(e) { physical_equal(e.source, source) && !e.value.watched() }) {
      keys.push(key)
    }
  }
  for key in keys {
    match self.kept.get(key) {
      Some(entries) => {
        let rest = entries.filter(fn(e) {
          if physical_equal(e.source, source) && !e.value.watched() {
            e.value.dispose()
            kept_count.made -= 1
            false
          } else {
            true
          }
        })
        if rest.is_empty() {
          self.kept.remove(key) |> ignore
        } else {
          self.kept[key] = rest
        }
      }
      None => ()
    }
  }
}

///|
/// Disposes and removes derived `Kept` entries of `source` whose key satisfies `matches` (auth/vault boundary).
fn[T] SourceKept::forget_matching(self : SourceKept[T], source : Source, matches : (String) -> Bool) -> Unit {
  let keys : Array[String] = []
  for key, entries in self.kept {
    if matches(key) && entries.iter().any(fn(e) { physical_equal(e.source, source) }) {
      keys.push(key)
    }
  }
  for key in keys {
    match self.kept.get(key) {
      Some(entries) => {
        let rest = entries.filter(fn(e) {
          if physical_equal(e.source, source) {
            e.value.dispose()
            kept_count.made -= 1
            false
          } else {
            true
          }
        })
        if rest.is_empty() {
          self.kept.remove(key) |> ignore
        } else {
          self.kept[key] = rest
        }
      }
      None => ()
    }
  }
}

///|
fn kept_forget_matching(src : Source, matches : (String) -> Bool) -> Unit {
  for l in kept_lists {
    (l.forget_matching)(src, matches)
  }
}

///|
/// What every Kept holds of source `src` that nothing follows let go of (SourceKept::forget_source): a page's source as
/// its page is put by at rest (Source::owned_by_parkable).
fn kept_forget_source(src : Source, kept? : Bool = false) -> Unit {
  for l in kept_lists {
    (l.forget_source)(src, kept)
  }
}

///|
/// Source `source`'s value for `key` let go of where nothing follows it (one still followed kept as it is).
fn[T] SourceKept::forget_unwatched_from(self : SourceKept[T], source : Source, key : String) -> Unit {
  match self.kept.get(key) {
    Some(entries) =>
      match entries.search_by(fn(entry) { physical_equal(entry.source, source) && !entry.value.watched() }) {
        Some(i) => {
          entries[i].value.dispose()
          entries.remove(i) |> ignore
          kept_count.made -= 1
          if entries.length() == 0 {
            self.kept.remove(key) |> ignore
          }
        }
        None => ()
      }
    None => ()
  }
}

///|
fn[T] SourceKept::forget(self : SourceKept[T], key : String) -> Unit {
  match self.kept.get(key) {
    Some(entries) => {
      for entry in entries {
        if !entry.value.watched() { entry.value.dispose() }
      }
      kept_count.made -= entries.length()
      self.kept.remove(key) |> ignore
    }
    None => ()
  }
}

///|
/// Those nothing follows let go: what the frames' watch read as the window was last built, or as this one is, is
/// followed by it till it reads anew without it (mbui/signals' Watch::read); a part kept as it was drawn, which reads it
/// no more each frame, holds it (mbui's Ctx::kept_part); a computed that read it, as long as it is itself kept.
fn[T] SourceKept::sweep(self : SourceKept[T]) -> Unit {
  let gone : Array[(String, SourceKeptOne[T])] = []
  for key, entries in self.kept {
    for entry in entries {
      if !entry.value.watched() {
        gone.push((key, entry))
      }
    }
  }
  for (key, entry) in gone {
    match self.kept.get(key) {
      Some(entries) =>
        match entries.search_by(fn(other) { physical_equal(other, entry) }) {
          Some(i) => {
            entry.value.dispose()
            entries.remove(i) |> ignore
            kept_count.made -= 1
            if entries.length() == 0 { self.kept.remove(key) |> ignore }
          }
          None => ()
        }
      None => ()
    }
  }
}

///|
fn[T] SourceKept::clear(self : SourceKept[T]) -> Unit {
  for _, entries in self.kept {
    for entry in entries {
      entry.value.dispose()
    }
  }
  self.kept.clear()
}

///|
/// What `work` makes of topic `name`'s value (Derived::read), by its source and params, worked out again as it changes.
pub struct Derived[T] {
  priv name : String
  priv work : (Json, T?) -> T
  priv kept : SourceKept[T?]
  /// whether what `work` made is what it made last: what reads it is told only where it is not (the topic changes in
  /// what `work` does not read, and it makes the same value again)
  priv same : (T?, T?) -> Bool
}

///|
/// What `work` makes of topic `name`, what reads it told only as that comes out another value (`==`).
pub fn[T : Eq] Derived::new(name : String, work : (Json, T?) -> T) -> Derived[T] {
  Derived::new_by(name, work, same=@signals.same_value)
}

///|
/// Derived::new told by the one object `work` made (@signals.same_ref): for a read made again from what it made last
/// (made_again), whose object stands for the version of the topic it was read from, where comparing it whole would
/// cost what reading it again saves.
pub fn[T] Derived::new_ref(name : String, work : (Json, T?) -> T) -> Derived[T] {
  Derived::new_by(name, work, same=@signals.same_ref)
}

///|
/// Derived::new whose value is the same as the last only as `same` says.
pub fn[T] Derived::new_by(name : String, work : (Json, T?) -> T, same~ : (T, T) -> Bool) -> Derived[T] {
  {
    name,
    work,
    kept: { kept: {}, listed: false },
    same: fn(a, b) {
      match (a, b) {
        (Some(x), Some(y)) => same(x, y)
        (None, None) => true
        _ => false
      }
    },
  }
}

///|
/// Topic `name` with `params` (Source.topic), and what `work` makes of its value: None while it has none. Its key
/// written once (topic_key), for the topic and for what is kept of it. What reads it follows the topic too (its
/// version, its error): what reads only what `work` made reads Derived::value.
pub fn[T] Derived::read(self : Derived[T], src : Source, params : Map[String, Json]) -> (T?, Topic) {
  self.read_said(src, params, topic_key(self.name, params))
}

///|
/// Derived::read, its key (topic_key of its name and `params`) worked out already: what reads the same params again
/// and again keeps both, written once (rows.mbt's chats_asked_said).
fn[T] Derived::read_said(self : Derived[T], src : Source, params : Map[String, Json], said : String) -> (T?, Topic) {
  let topic = src.topic_said(self.name, params, said).get().snapshot()
  (self.made(src, params, said), topic)
}

///|
/// What `work` makes of topic `name` with `params`, None while it has none: what reads it follows what was made alone,
/// told only as that comes out another value (`same`), never as the topic changes where `work` does not read. The
/// topic is followed by what is kept (its computed reads it), held as long as that is read. A card or a panel opened
/// as this is read waits for the topic as Source::topic says (@sf.OpenGate), as Derived::read does.
pub fn[T] Derived::value(self : Derived[T], src : Source, params : Map[String, Json]) -> T? {
  let said = topic_key(self.name, params)
  if @sf.open_gate_collecting() {
    src.topic_said(self.name, params, said).get() |> ignore
  }
  self.made(src, params, said)
}

///|
/// What is kept of topic `said` from `src`: worked out as it changes, from what was made last.
fn[T] Derived::made(self : Derived[T], src : Source, params : Map[String, Json], said : String) -> T? {
  self.kept.read(src, said, fn(was) {
    match src.topic_said(self.name, params, said).get().value {
      Some(v) =>
        Some(
          (self.work)(v, match was {
            Some(w) => w
            None => None
          }),
        )
      None => None
    }
  }, same=self.same)
}

///|
/// What was last made of topic `name` with `params`, if it is kept (Kept::peek): the topic not
/// asked for.
pub fn[T] Derived::kept(self : Derived[T], params : Map[String, Json]) -> T? {
  match self.kept.peek(topic_key(self.name, params)) {
    Some(v) => v
    None => None
  }
}

///|
/// What was last made for these parameters from `src`, without asking the source for the topic again.
pub fn[T] Derived::kept_from(self : Derived[T], src : Source, params : Map[String, Json]) -> T? {
  match self.kept.peek_from(src, topic_key(self.name, params)) {
    Some(v) => v
    None => None
  }
}

///|
/// What was made for these parameters from `src` let go of where nothing follows it (SourceKept::forget_from): one read
/// untracked holds what it read (the topic's subscription) till it is.
pub fn[T] Derived::forget_from(self : Derived[T], src : Source, params : Map[String, Json]) -> Unit {
  self.kept.forget_unwatched_from(src, topic_key(self.name, params))
}

///|
/// `jsons` made (`make`) each, from what was made of them last (`was`: each with the JSON it was made of): one that is
/// the same JSON as before (the core's deltas keep what they do not touch: src/core delta.mbt) taken as it was made;
/// only what changed is made anew. Looked for where the last one found was and on from there (what was between them
/// gone, or one moved on), then among those passed over (one moved back); by `key` once that has looked at twice as many
/// as there were (a page come before them, all of it new): a message come at the end, one changed, one gone are
/// matched where they stand, never a key made of each.
pub fn[T] made_again(
  jsons : Array[Json],
  was : Array[(Json, T)],
  key : (Json) -> String,
  make : (Json) -> T,
) -> Array[(Json, T)] {
  let n = was.length()
  let most = 2 * n + 16
  let mut looked = 0
  // where the next is looked for first: after the last found
  let mut at = 0
  // those passed over on the way to one found further on (gone, or wanted later: moved back)
  let passed : Array[Int] = []
  let by : Ref[Map[String, (Json, T)]?] = Ref(None)
  jsons.map(fn(j) {
    if looked < most {
      for q in at..<n {
        looked += 1
        if physical_equal(was[q].0, j) {
          for s in at..<q {
            passed.push(s)
          }
          at = q + 1
          return was[q]
        }
        if looked >= most {
          break
        }
      }
      for s in passed {
        looked += 1
        if physical_equal(was[s].0, j) {
          return was[s]
        }
      }
      if looked < most {
        return (j, make(j))
      }
    }
    // (too much looked at: by its key)
    let index = match by.val {
      Some(m) => m
      None => {
        let m : Map[String, (Json, T)] = Map([])
        for p in was {
          m[key(p.0)] = p
        }
        by.val = Some(m)
        m
      }
    }
    match index.get(key(j)) {
      Some((pj, t)) if physical_equal(pj, j) => (pj, t)
      _ => (j, make(j))
    }
  })
}

