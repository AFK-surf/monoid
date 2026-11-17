// Each person's own lock this station has heard (station/src/mesh/person-chains.ts): every entry the rules take
// after a parent it keeps, the active chain the fork choice gives of them, the rest kept aside; the workspaces each
// was heard in; a few chains a person at most, never one a workspace's state is made of. Kept on disk
// (`mesh/person-chains.json`), written as it changes.

///|
/// At most this many chains of one person: the oldest go.
pub let chains_a_person : Int = 4

///|
/// At most this many entries in a chain.
pub let chain_most : Int = 1024

///|
/// What a station answers a chain at odds with the one kept.
pub let at_odds : String = "this device brought a lock at odds with the one its person has here"

///|
/// Whose a chain is: its entries name the person's lock (`person:<sub>`).
pub fn sub_of(chain : Array[Json]) -> String? {
  match chain.get(0) {
    Some(e) =>
      match text_at(e, "ws") {
        Some(ws) if ws.has_prefix("person:") => Some(ws.unsafe_substring(start=7, end=ws.length()))
        _ => None
      }
    None => None
  }
}

///|
fn person_rules(c : Crypto, genesis : String, ws : String) -> LogRules {
  {
    chain: all => person_chain(c, all, genesis),
    pre: Some(e => if ws_of(e) != ws { Some("an entry of another lock") } else { None }),
    now: None,
  }
}

///|
/// What taking a person's entries did (person-chains.ts `PersonTook`).
pub(all) struct PersonTook {
  chain : Array[Json]
  taken : Int
  off : Array[OffChain]
  on : Bool
}

///|
pub struct PersonChains {
  priv crypto : Crypto
  /// Each log's active chain, by its genesis, in the order kept (a Map's: the latest set last).
  priv kept : Map[String, Array[Json]]
  priv aside : Map[String, Array[Json]]
  priv heard : Map[String, Array[String]]
  priv disk : Disk?
  priv path : String?
  priv told : Array[(Int, (String) -> Unit)]
  priv changed : Array[(Int, (String) -> Unit)]
  priv mut next : Int
  /// The logs a workspace's state is made of where its chain moved (Cloud's `needs`), which count as heard there.
  mut needs : (String) -> Array[String]
}

///|
/// What is kept, read from `path` where there is one (person-chains.ts `new PersonChains`).
pub fn PersonChains::new(crypto : Crypto, disk : Disk?, path : String?) -> PersonChains {
  let self : PersonChains = {
    crypto,
    kept: Map([]),
    aside: Map([]),
    heard: Map([]),
    disk,
    path,
    told: [],
    changed: [],
    next: 0,
    needs: _ => [],
  }
  match (disk, path) {
    (Some(d), Some(p)) =>
      match d.read(p).bind(parse) {
        Some(read) => {
          // (written before the workspaces were kept: the chains alone)
          let chains = match get(read, "chains") {
            Some(Object(_) as c) => Some(c)
            _ => Some(read)
          }
          for kv in entries_of_obj(chains) {
            if kv.1 is Array(chain) {
              self.kept[kv.0] = chain
            }
          }
          for kv in entries_of_obj(get(read, "heard")) {
            if kv.1 is Array(ws) {
              let out = []
              for w in ws {
                if w is String(s) && !out.contains(s) {
                  out.push(s)
                }
              }
              self.heard[kv.0] = out
            }
          }
          for kv in entries_of_obj(get(read, "aside")) {
            let genesis = kv.0
            guard self.kept.get(genesis) is Some(chain) else { continue }
            let entries = match kv.1 {
              Array(xs) => xs.filter_map(as_entry)
              _ => []
            }
            if entries.length() == 0 {
              continue
            }
            let rules = person_rules(crypto, genesis, ws_of(chain[0]))
            match (try Ok(rechoose({ entries: chain, aside: entries }, rules)) catch { e => Err(e) }) {
              Ok(t) => {
                self.kept[genesis] = t.kept.entries
                if t.kept.aside.length() > 0 {
                  self.aside[genesis] = t.kept.aside
                }
              }
              Err(_) => ()
            }
          }
        }
        None => ()
      }
    _ => ()
  }
  self
}

///|
fn PersonChains::on_head(self : PersonChains, genesis : String, entries : Array[Json]) -> (Array[Json], OffChain?) {
  let kept = self.kept.get(genesis).unwrap_or([])
  let known : Map[String, Unit] = Map([])
  for e in kept {
    known[hash_of(e)] = ()
  }
  for e in self.aside.get(genesis).unwrap_or([]) {
    known[hash_of(e)] = ()
  }
  let mut head : String? = match kept.last() {
    Some(e) => Some(hash_of(e))
    None => None
  }
  let line = []
  for e in entries {
    let h = hash_of(e)
    if known.contains(h) {
      line.push(e)
      continue
    }
    if prev_of(e) != head {
      return (line, Some({ why: "not on the head", refusal: None, winner: None, step: None, under: None, hash: h, seq: seq_of(e), kept: false }))
    }
    known[h] = ()
    line.push(e)
    head = Some(h)
  }
  (line, None)
}

///|
/// The chain to judge by, where the last entry brought is on it (person-chains.ts `newest`); raises a refusal where
/// it is not.
pub fn PersonChains::newest(self : PersonChains, genesis : String, sub : String, brought : Array[Json]) -> Array[Json] raise Failure {
  guard self.kept.get(genesis) is Some(had) else { return brought }
  guard entries_of(brought) is Some(entries) else { raise Refused(at_odds) }
  let (line, _) = self.on_head(genesis, entries)
  let t = keep({ entries: had, aside: self.aside.get(genesis).unwrap_or([]) }, line, person_rules(self.crypto, genesis, "person:\{sub}"))
  if !on_chain(t.kept.entries, entries) {
    raise Refused(at_odds)
  }
  t.kept.entries
}

///|
/// The chain the rules choose among what is kept and `brought`, nothing kept (person-chains.ts `chosen`).
pub fn PersonChains::chosen(self : PersonChains, genesis : String, sub : String, brought : Array[Json]) -> Array[Json] raise Failure {
  let (line, _) = self.on_head(genesis, entries_of(brought).unwrap_or([]))
  keep(
    { entries: self.kept.get(genesis).unwrap_or([]), aside: self.aside.get(genesis).unwrap_or([]) },
    line,
    person_rules(self.crypto, genesis, "person:\{sub}"),
  ).kept.entries
}

///|
/// `brought` taken, as heard in `ws` when said (person-chains.ts `take`); raises why where the rules find no chain.
pub fn PersonChains::take(self : PersonChains, genesis : String, sub : String, brought : Array[Json], ws? : String? = None, fork? : Bool = false) -> PersonTook raise Failure {
  let had = self.kept.get(genesis)
  let was : Kept = { entries: had.unwrap_or([]), aside: self.aside.get(genesis).unwrap_or([]) }
  let all = match entries_of(brought) {
    Some(es) => es
    None => brought.filter_map(as_entry)
  }
  let (line, stop) = if fork { (all, None) } else { self.on_head(genesis, all) }
  let t = keep(was, line, person_rules(self.crypto, genesis, "person:\{sub}"))
  let off = t.off.copy()
  if stop is Some(s) {
    off.push(s)
  }
  if t.kept.entries.length() == 0 {
    return { chain: had.unwrap_or([]), taken: 0, off, on: false }
  }
  self.store(genesis, t.kept, ws, t.changed, t.moved)
  { chain: t.kept.entries, taken: t.taken, off, on: on_chain(t.kept.entries, all) && all.length() == brought.length() }
}

///|
/// The chain gone by of the lock: none, none heard.
pub fn PersonChains::kept(self : PersonChains, genesis : String) -> Array[Json]? {
  self.kept.get(genesis)
}

///|
/// Every entry kept of the lock: its chain, then those off it.
pub fn PersonChains::all(self : PersonChains, genesis : String) -> Array[Json] {
  self.kept.get(genesis).unwrap_or([]) + self.aside.get(genesis).unwrap_or([])
}

///|
pub fn PersonChains::aside_of(self : PersonChains, genesis : String) -> Int {
  self.aside.get(genesis).map(a => a.length()).unwrap_or(0)
}

///|
/// Every chain kept of `sub`'s, by its genesis.
pub fn PersonChains::of(self : PersonChains, sub : String) -> Array[(String, Array[Json])] {
  self.kept.iter().filter(p => sub_of(p.1) == Some(sub)).collect()
}

///|
/// The chains heard in workspace `ws`, or that its state is made of, by their genesis.
pub fn PersonChains::heard_in(self : PersonChains, ws : String) -> Array[(String, Array[Json])] {
  let needed = (self.needs)(ws)
  self.kept
  .iter()
  .filter(p => self.heard.get(p.0).map(h => h.contains(ws)).unwrap_or(false) || needed.contains(p.0))
  .collect()
}

///|
/// Every log kept, its active chain, by its genesis.
pub fn PersonChains::every(self : PersonChains) -> Array[(String, Array[Json])] {
  self.kept.iter().collect()
}

///|
/// Every `ws` entry kept that commits to the body of hash `h`, with its log from the genesis to it (`commitsTo`).
pub fn PersonChains::commits_to(self : PersonChains, h : String) -> Array[Commit] {
  let out = []
  for genesis, _ in self.kept {
    let all = self.all(genesis)
    let by : Map[String, Json] = Map([])
    for e in all {
      by[hash_of(e)] = e
    }
    for e in all {
      if kind_of(e) != "ws" || text_at(body_of(e).unwrap_or(Json::null()), "h") != Some(h) {
        continue
      }
      let chain = []
      let mut at : Json? = Some(e)
      while at is Some(x) && chain.length() <= chain_most {
        chain.push(x)
        at = match prev_of(x) {
          None => None
          Some(p) => by.get(p)
        }
      }
      chain.rev_in_place()
      if chain.length() > 0 && get(chain[0], "prev") is Some(Null) {
        out.push({ genesis, chain })
      }
    }
  }
  out
}

///|
/// Checked and let in on it (person-chains.ts `keep`).
pub fn PersonChains::keep(self : PersonChains, genesis : String, chain : Array[Json], ws? : String? = None, fork? : Bool = false) -> Unit {
  guard sub_of(chain) is Some(sub) else { return }
  (try Ok(self.take(genesis, sub, chain, ws~, fork~)) catch { e => Err(e) }) |> ignore
}

///|
fn PersonChains::store(self : PersonChains, genesis : String, kept : Kept, ws : String?, changed : Bool, moved : Bool) -> Unit {
  let heard = self.heard.get(genesis).unwrap_or([])
  let newly = match ws {
    Some(w) => !heard.contains(w)
    None => false
  }
  if !changed && !newly {
    return
  }
  if changed {
    self.kept.remove(genesis)
    self.kept[genesis] = kept.entries
    if kept.aside.length() > 0 {
      self.aside[genesis] = kept.aside
    } else {
      self.aside.remove(genesis)
    }
    let sub = sub_of(kept.entries)
    let needed = (g : String) => self.heard.get(g).unwrap_or([]).iter().any(w => (self.needs)(w).contains(g))
    let theirs = self.kept.iter().filter(p => sub_of(p.1) == sub && !needed(p.0)).map(p => p.0).collect()
    let drop = theirs.length() - chains_a_person
    for i in 0..<drop {
      let g = theirs[i]
      self.kept.remove(g)
      self.aside.remove(g)
      self.heard.remove(g)
    }
  }
  if newly {
    let h = self.heard.get(genesis).unwrap_or([])
    h.push(ws.unwrap())
    self.heard[genesis] = h
  }
  match (self.disk, self.path) {
    (Some(disk), Some(path)) => {
      let heard_out = self.heard.iter().filter(p => self.kept.contains(p.0)).map(p => (p.0, jstrs(p.1))).collect()
      let out : Array[(String, Json)] = [
        ("chains", Json::object(Map::from_array(self.kept.iter().map(p => (p.0, jarr(p.1))).collect()))),
        ("heard", Json::object(Map::from_array(heard_out))),
      ]
      if self.aside.length() > 0 {
        out.push(("aside", Json::object(Map::from_array(self.aside.iter().filter(p => self.kept.contains(p.0)).map(p => (p.0, jarr(p.1))).collect()))))
      }
      disk.write(path, stringify(jobj(out))) catch {
        _ => ()
      }
    }
    _ => ()
  }
  if moved {
    for f in self.told.copy() {
      (f.1)(genesis)
    }
  }
  for f in self.changed.copy() {
    (f.1)(genesis)
  }
}

///|
/// Told each time the chain gone by of a lock moves; returns what stops it.
pub fn PersonChains::listen(self : PersonChains, f : (String) -> Unit) -> () -> Unit {
  self.next += 1
  let id = self.next
  self.told.push((id, f))
  () => self.told.retain(x => x.0 != id)
}

///|
/// Told each time anything kept of a lock changes; returns what stops it.
pub fn PersonChains::watch(self : PersonChains, f : (String) -> Unit) -> () -> Unit {
  self.next += 1
  let id = self.next
  self.changed.push((id, f))
  () => self.changed.retain(x => x.0 != id)
}

///|
/// Whether the last of `brought` is on `chain`.
fn on_chain(chain : Array[Json], brought : Array[Json]) -> Bool {
  match brought.last() {
    None => true
    Some(last) => {
      let h = hash_of(last)
      chain.iter().any(e => hash_of(e) == h)
    }
  }
}
