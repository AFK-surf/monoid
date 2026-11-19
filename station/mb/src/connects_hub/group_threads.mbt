// What a group connect has heard of its anchor (`im/2`; group/threads.ts), kept in <data>/group-threads.json so that a
// station started again neither hands its agents a message twice nor loses one said meanwhile: for each connect, each
// space's place (`aseq`, the anchor's number of the last event of it taken: what `POST /sync` goes on from), this
// device's own count there and its last event's id (`dseq`, `prev`: what its next event is signed after), and each
// stream's last message taken (`last`, by its key: the space's id for its lobby, `<space>/<topic>` for a topic). A
// space first heard of with events in it has its place kept as it is: what was said before the station was in it is
// history (chat_history), not a request.
//
// A file of `im/1`'s (a stream's `since` and each conversation's last message number) names nothing `im/2` has: it is
// read as nothing heard yet, every space then first heard of.
//
// Written off the station's thread, one write at a time, the newest state each time (a burst of messages is one write
// or two).

///|
/// A space's place, as kept.
pub(all) struct SpaceKept {
  aseq : Double
  dseq : Double
  prev : String
}

///|
/// `typeof v === "number" && Number.isSafeInteger(v) && v >= 0 ? v : 0`.
fn whole_of(v : J?) -> Double {
  match v {
    Some(Num(d)) if d.floor() == d && d >= 0.0 && d <= 9007199254740991.0 => d + 0.0
    _ => 0.0
  }
}

///|
pub struct GroupThreads {
  path : String
  /// Each connect's `{v: 2, spaces: {id: {aseq, dseq, prev}}, last: {stream: n}}`, as written.
  priv mut kept : J
  priv writing : Turns
  priv mut dirty : Bool
  priv fs : Fs
  priv log : Log
}

///|
/// What the file kept, read once before the station serves (one that does not read starts empty, said in the log
/// unless it is not there; an `im/1` connect's read as nothing).
pub async fn GroupThreads::open(path : String, fs : Fs, log : Log) -> GroupThreads {
  let kept : Array[(String, J)] = []
  try {
    let v = parse_js((fs.read_text)(path))
    if v is Obj(_) {
      for e in entries_of(Some(v)) {
        let of = Some(e.1)
        // (im/1's: nothing of it is im/2's)
        if !(at(of, "v") is Some(Num(two)) && two == 2.0) || !(at(of, "spaces") is Some(Obj(_) | Arr(_))) {
          continue
        }
        let spaces = entries_of(at(of, "spaces")).map(s => {
          let k = Some(s.1)
          (
            s.0,
            jo([
              ("aseq", jn(whole_of(at(k, "aseq")))),
              ("dseq", jn(whole_of(at(k, "dseq")))),
              ("prev", js(str_of(at(k, "prev")).unwrap_or(""))),
            ]),
          )
        })
        let last = match at(of, "last") {
          Some(Obj(_) | Arr(_)) as l => entries_of(l).map(x => (x.0, jn(whole_of(Some(x.1)))))
          _ => []
        }
        kept.push((e.0, jo([("v", ji(2)), ("spaces", from_entries(spaces)), ("last", from_entries(last))])))
      }
    }
  } catch {
    e => if !not_there(e) { log.warn("group", "group threads file unreadable; starting empty", jo([("error", js(thrown_message(e)))])) }
  }
  { path, kept: from_entries(kept), writing: Turns::new(), dirty: false, fs, log }
}

///|
fn GroupThreads::of(self : GroupThreads, connect : String) -> J {
  match at(Some(self.kept), connect) {
    Some(of) => of
    None => {
      let of = jo([("v", ji(2)), ("spaces", jo([])), ("last", jo([]))])
      self.kept = set_field(self.kept, connect, of)
      of
    }
  }
}

///|
fn kept_of(s : J?) -> SpaceKept? {
  match s {
    Some(Obj(_)) => Some({ aseq: num_of(at(s, "aseq")).unwrap_or(0.0), dseq: num_of(at(s, "dseq")).unwrap_or(0.0), prev: str_of(at(s, "prev")).unwrap_or("") })
    _ => None
  }
}

///|
fn space_j(s : SpaceKept) -> J {
  jo([("aseq", jn(s.aseq)), ("dseq", jn(s.dseq)), ("prev", js(s.prev))])
}

///|
/// The spaces heard of, by id, in their order: where each goes on from.
pub fn GroupThreads::spaces(self : GroupThreads, connect : String) -> Array[(String, SpaceKept)] {
  entries_of(at(at(Some(self.kept), connect), "spaces")).filter_map(e => kept_of(Some(e.1)).map(k => (e.0, k)))
}

///|
/// A space's place; None for one not heard of yet.
pub fn GroupThreads::space(self : GroupThreads, connect : String, space : String) -> SpaceKept? {
  kept_of(at(at(at(Some(self.kept), connect), "spaces"), space))
}

///|
fn GroupThreads::put(self : GroupThreads, connect : String, of : J) -> Unit {
  self.kept = set_field(self.kept, connect, of)
}

///|
/// A space's events taken up to `aseq` (a message of `stream` among them, where it is one).
pub fn GroupThreads::took(self : GroupThreads, connect : String, space : String, aseq : Double, stream? : String? = None) -> Unit {
  let mut of = self.of(connect)
  let spaces = at(Some(of), "spaces").unwrap_or(jo([]))
  let s = kept_of(at(Some(spaces), space)).unwrap_or({ aseq: 0.0, dseq: 0.0, prev: "" })
  let mut changed = false
  let mut next = s
  if aseq > s.aseq {
    next = { ..s, aseq, }
    changed = true
  }
  of = set_field(of, "spaces", set_field(spaces, space, space_j(next)))
  match stream {
    Some(k) => {
      let last = at(Some(of), "last").unwrap_or(jo([]))
      if num_of(at(Some(last), k)).unwrap_or(0.0) < aseq {
        of = set_field(of, "last", set_field(last, k, jn(aseq)))
        changed = true
      }
    }
    None => ()
  }
  self.put(connect, of)
  if changed {
    self.save()
  }
}

///|
/// The last message taken of a stream (0: none).
pub fn GroupThreads::last(self : GroupThreads, connect : String, stream : String) -> Double {
  num_of(at(at(at(Some(self.kept), connect), "last"), stream)).unwrap_or(0.0)
}

///|
/// This device said its `dseq`-th event in the space, of id `prev` ("" where it is not known: one the anchor counts
/// and this station kept nothing of).
pub fn GroupThreads::said(self : GroupThreads, connect : String, space : String, dseq : Double, prev : String) -> Unit {
  let of = self.of(connect)
  let spaces = at(Some(of), "spaces").unwrap_or(jo([]))
  let s = kept_of(at(Some(spaces), space)).unwrap_or({ aseq: 0.0, dseq: 0.0, prev: "" })
  self.put(connect, set_field(of, "spaces", set_field(spaces, space, space_j(s))))
  if dseq < s.dseq || (dseq == s.dseq && (prev == "" || prev == s.prev)) {
    return
  }
  // (a count the anchor said, of an event kept nowhere here: its id not known, the one after it says none)
  let next_prev = if prev != "" || dseq > s.dseq { prev } else { s.prev }
  let of = self.of(connect)
  self.put(connect, set_field(of, "spaces", set_field(spaces, space, space_j({ aseq: s.aseq, dseq, prev: next_prev }))))
  self.save()
}

///|
/// A space the connect is no longer in: its place and its streams'.
pub fn GroupThreads::forget(self : GroupThreads, connect : String, space : String) -> Unit {
  guard at(Some(self.kept), connect) is Some(of) else { return }
  guard at(at(Some(of), "spaces"), space) is Some(_) else { return }
  let spaces = without(at(Some(of), "spaces").unwrap_or(jo([])), [space])
  let last = at(Some(of), "last").unwrap_or(jo([]))
  let gone = fields_of(Some(last)).map(f => f.0).filter(k => k == space || k.has_prefix("\{space}/"))
  self.put(connect, set_field(set_field(of, "spaces", spaces), "last", without(last, gone)))
  self.save()
}

///|
/// A connect removed, or bound anew as another member: what it heard goes.
pub fn GroupThreads::drop(self : GroupThreads, connect : String) -> Unit {
  if at(Some(self.kept), connect) is None {
    return
  }
  self.kept = without(self.kept, [connect])
  self.save()
}

///|
fn GroupThreads::save(self : GroupThreads) -> Unit {
  if self.dirty {
    return
  }
  self.dirty = true
  self.writing.run_soon(async fn() {
    self.dirty = false
    try {
      write_beside(self.fs, self.path, js_stringify(self.kept))
    } catch {
      e => self.log.warn("group", "group threads not kept", jo([("error", js(thrown_message(e)))]))
    }
  })
}

///|
/// Once what was changed is on the disk.
pub async fn GroupThreads::flushed(self : GroupThreads) -> Unit {
  self.writing.settled()
}

///|
/// What it keeps now, as it would write it.
pub fn GroupThreads::kept(self : GroupThreads) -> J {
  js_ordered(self.kept)
}
