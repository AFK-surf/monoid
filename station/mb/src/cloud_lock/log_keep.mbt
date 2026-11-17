// What a station keeps of one log (station/src/cloud/log-keep.ts): every entry the rules take after a parent it keeps,
// the active chain the rules' fork choice gives of them, the rest kept aside, at most ASIDE_MOST. Pure.

///|
/// The most entries a log keeps off its active chain.
pub let aside_most : Int = 256

///|
/// A log as kept: its active chain from the genesis, and the entries off it, in the order they were kept.
pub(all) struct Kept {
  entries : Array[Json]
  aside : Array[Json]
}

///|
/// Why an entry brought is not on the active chain after it was taken (log-keep.ts `OffChain`).
pub(all) struct OffChain {
  why : String
  refusal : String?
  winner : String?
  step : String?
  under : String?
  hash : String
  seq : Double
  kept : Bool
}

///|
/// As the TypeScript says it (its keys in its order).
pub fn OffChain::to_json(self : OffChain) -> Json {
  let m : Map[String, Json] = Map([("why", jstr(self.why))])
  if self.refusal is Some(r) {
    m["refusal"] = jstr(r)
  }
  if self.winner is Some(w) {
    m["winner"] = jstr(w)
  }
  if self.step is Some(s) {
    m["step"] = jstr(s)
  }
  if self.under is Some(u) {
    m["under"] = jstr(u)
  }
  m["hash"] = jstr(self.hash)
  m["seq"] = jnum(self.seq)
  m["kept"] = Json::boolean(self.kept)
  Json::object(m)
}

///|
pub(all) struct Took {
  kept : Kept
  /// Entries brought kept now that were not before.
  taken : Int
  /// Each entry brought (once) that is not on the active chain now, and why.
  off : Array[OffChain]
  /// Whether the active chain's head is another now.
  moved : Bool
  /// Whether anything kept changed.
  changed : Bool
}

///|
/// What a log's rules say for keeping (log-keep.ts `LogRules`).
pub(all) struct LogRules {
  chain : (Array[Json]) -> Chain raise Failure
  pre : ((Json) -> String?)?
  now : ((String, Json, (String) -> Json?) -> String?)?
}

///|
/// Raises why the first of `entries` has no hash (as `hashOf` throws on it in the TypeScript).
pub fn hashable(entries : Array[Json]) -> Unit raise Failure {
  for e in entries {
    entry_hash(e) |> ignore
  }
}

///|
fn refused_off(e : Json, why : String) -> OffChain {
  { why: "refused", refusal: Some(why), winner: None, step: None, under: None, hash: hash_of(e), seq: seq_of(e), kept: false }
}

///|
/// `was` with `brought` taken (log-keep.ts `keep`). Raises only where the rules find no chain of what was kept.
pub fn keep(was : Kept, brought : Array[Json], rules : LogRules) -> Took raise Failure {
  hashable(brought)
  let kept : Map[String, Json] = Map([])
  for e in was.entries {
    kept[hash_of(e)] = e
  }
  for e in was.aside {
    kept[hash_of(e)] = e
  }
  let before : Map[String, Unit] = Map([])
  for e in was.entries {
    before[hash_of(e)] = ()
  }
  let why : Map[String, OffChain] = Map([])
  let seen : Map[String, Unit] = Map([])
  let candidates : Array[Json] = []
  for e in brought {
    let h = hash_of(e)
    if kept.contains(h) || seen.contains(h) {
      continue
    }
    seen[h] = ()
    let pre = match rules.pre {
      Some(f) => f(e)
      None => None
    }
    match pre {
      Some(p) => why[h] = refused_off(e, p)
      None => candidates.push(e)
    }
  }
  let mut accepted = candidates
  if rules.now is Some(now) {
    let ok : Map[String, Json] = Map([])
    let sorted = candidates.copy()
    stable_sort(sorted, (a, b) => seq_of(a).compare(seq_of(b)))
    for c in sorted {
      if prev_of(c) is Some(p) && (kept.contains(p) || ok.contains(p)) {
        let find = (x : String) => match kept.get(x) {
          Some(e) => Some(e)
          None => ok.get(x)
        }
        match now(p, c, find) {
          Some(refused) => {
            why[hash_of(c)] = refused_off(c, refused)
            continue
          }
          None => ()
        }
      }
      ok[hash_of(c)] = c
    }
    accepted = candidates.filter(c => !why.contains(hash_of(c)))
  }
  let brought_aside = brought.iter().any(e => !before.contains(hash_of(e)) && kept.contains(hash_of(e)))
  if accepted.length() == 0 && !brought_aside {
    return { kept: was, taken: 0, off: off_of(brought, why, before), moved: false, changed: false }
  }
  settle(was, accepted, rules, brought, why)
}

///|
/// The chain chosen again among all `was` keeps (log-keep.ts `rechoose`).
pub fn rechoose(was : Kept, rules : LogRules) -> Took raise Failure {
  settle(was, [], rules, [], Map([]))
}

///|
fn settle(was : Kept, accepted : Array[Json], rules : LogRules, brought : Array[Json], why : Map[String, OffChain]) -> Took raise Failure {
  let all = was.entries + was.aside + accepted
  let r = (rules.chain)(all)
  let active = r.at.map(i => all[i])
  let on : Map[String, Unit] = Map([])
  for h in r.hashes {
    on[h] = ()
  }
  let off_by : Map[String, Off] = Map([])
  for o in r.off {
    off_by[hash_of(all[o.at])] = o
  }
  let aside = (e : Json) => match off_by.get(hash_of(e)) {
    Some(o) => o.why == "beaten" || o.why == "below"
    None => false
  }
  let old = was.aside.filter(aside) + was.entries.filter(e => !on.contains(hash_of(e)) && aside(e))
  let mut room = aside_most - old.length()
  let fresh : Array[Json] = []
  let sorted = accepted.copy()
  stable_sort(sorted, (a, b) => seq_of(a).compare(seq_of(b)))
  for e in sorted {
    if on.contains(hash_of(e)) || !aside(e) {
      continue
    }
    if room > 0 {
      fresh.push(e)
      room -= 1
    }
  }
  let mut side = old + fresh
  if side.length() > aside_most {
    side = side[side.length() - aside_most:].to_owned()
  }
  let kept_now : Map[String, Unit] = Map([])
  for h, _ in on {
    kept_now[h] = ()
  }
  let by_seq = side.copy()
  stable_sort(by_seq, (a, b) => seq_of(a).compare(seq_of(b)))
  for e in by_seq {
    if prev_of(e) is Some(p) && kept_now.contains(p) {
      kept_now[hash_of(e)] = ()
    }
  }
  side = side.filter(e => kept_now.contains(hash_of(e)))
  let kept : Kept = { entries: active, aside: side }
  for e in brought {
    let h = hash_of(e)
    if on.contains(h) || why.contains(h) {
      continue
    }
    match off_by.get(h) {
      Some(o) =>
        why[h] = {
          why: o.why,
          refusal: o.refusal,
          winner: o.winner,
          step: o.step,
          under: o.under,
          hash: h,
          seq: seq_of(e),
          kept: kept_now.contains(h),
        }
      None => ()
    }
  }
  let was0 : Map[String, Unit] = Map([])
  for e in was.entries {
    was0[hash_of(e)] = ()
  }
  for e in was.aside {
    was0[hash_of(e)] = ()
  }
  let taken = accepted.filter(e => kept_now.contains(hash_of(e))).length()
  let head = (es : Array[Json]) => match es.last() {
    Some(e) => hash_of(e)
    None => ""
  }
  let moved = head(active) != head(was.entries)
  let same = (a : Array[Json], b : Array[Json]) => {
    if a.length() != b.length() {
      return false
    }
    for i in 0..<a.length() {
      if hash_of(a[i]) != hash_of(b[i]) {
        return false
      }
    }
    true
  }
  let changed = taken > 0 ||
    !same(active, was.entries) ||
    side.length() != was.aside.length() ||
    side.iter().any(e => !was0.contains(hash_of(e)))
  { kept, taken, off: off_of(brought, why, on), moved, changed }
}

///|
/// Each entry brought (once) not on the chain `on`, with why.
fn off_of(brought : Array[Json], why : Map[String, OffChain], on : Map[String, Unit]) -> Array[OffChain] {
  let out = []
  let seen : Map[String, Unit] = Map([])
  for e in brought {
    let h = hash_of(e)
    if on.contains(h) || seen.contains(h) {
      continue
    }
    seen[h] = ()
    if why.get(h) is Some(w) {
      out.push(w)
    }
  }
  out
}
