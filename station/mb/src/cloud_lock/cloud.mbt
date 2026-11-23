// The state in memory (station/src/cloud/state.ts `Cloud`): cloud.json, the workspace's lock and the joined
// workspaces' (pinned, turned off, named to pin), the bodies and person logs a moved workspace's state is made of, and
// that state as made last; each change written through and told. A pinned lock is let go or replaced only by its own
// `disable`, `resetLock` on this machine, or a joined workspace's taking over as home (`succeed`): never by what the
// control plane says (`leftJoined` keeps it).

///|
/// A pinned lock as kept: its active chain, the entries off it, and the chain's state (none: its file is broken,
/// nobody is admitted).
pub(all) struct KeptLock {
  entries : Array[Json]
  aside : Array[Json]
  state : @lock.LockState?
}

///|
/// A lock in force, or what a moved workspace's state says (`waiting`: this station has not what it is made of yet).
pub(all) struct Locked {
  state : @lock.LockState?
  waiting : Bool
}

///|
/// What taking entries of a lock did (state.ts `LockTook`).
pub(all) struct LockTook {
  taken : Int
  off : Array[OffChain]
  refusal : String?
}

///|
/// Whom a body is given: every one, or those of these hashes.
pub(all) enum Given {
  All
  Only(Array[String])
}

///|
priv struct InForce {
  lock : KeptLock
  ver : String
  from : Double
  until : Double
  on : String
  out : Locked
  needs : Array[String]
  word : String
  root_in : Bool
}

///|
pub struct Cloud {
  data : String
  priv disk : Disk
  crypto : Crypto
  /// This station's clock, unix seconds (`nowSecs`).
  now : () -> Double
  mut state : CloudState?
  mut peers_current : Bool
  mut reached : Bool
  rosters_said : Int
  mut lock : KeptLock?
  priv joined_locks : Map[String, KeptLock?]
  plane_lock_seq : Double?
  plane_lock_seqs : Map[String, Double?]
  plane_lock_hashes : Map[String, String]
  plane_parted : Map[String, String]
  /// Which of a locked workspace's rigs its person signed for (rigs/adds.ts sets it).
  mut rig_vouched : (String, Json) -> Bool
  /// The plane's chain of a joined workspace that moved, offered (moved-pin.ts), by workspace.
  moved_offered : Map[String, Array[Json]]
  priv mut plane_peers : Array[Json]?
  priv mut plane_gateways : Json?
  priv listeners : Array[(Int, (CloudState?) -> Unit)]
  priv mut next : Int
  priv lock_bodies : Map[String, LockBodies]
  priv in_force : Map[String, InForce]
  priv told_words : Map[String, String]
  priv mut persons_ver : Int
  priv mut persons : PersonChains?
  priv outs : Map[String, (String, Map[String, Array[String]])]
  priv off_logs : Map[String, Kept?]
  priv mut written : String?
}

///|
/// The state of a station's data directory `data` (state.ts `new Cloud`), on `host`'s shell, by the clock `now`.
pub fn Cloud::new(host : @host.Host, data : String, crypto : Crypto, now : () -> Double) -> Cloud raise Failure {
  let disk : Disk = { host, }
  (try Ok(move_former_host(disk, data)) catch { e => Err(e) }) |> ignore
  let state = read_state(disk, data)
  let c : Cloud = {
    data,
    disk,
    crypto,
    now,
    state,
    peers_current: false,
    reached: false,
    rosters_said: 0,
    lock: None,
    joined_locks: Map([]),
    plane_lock_seq: None,
    plane_lock_seqs: Map([]),
    plane_lock_hashes: Map([]),
    plane_parted: Map([]),
    rig_vouched: (_, _) => false,
    moved_offered: Map([]),
    plane_peers: None,
    plane_gateways: None,
    listeners: [],
    next: 0,
    lock_bodies: Map([]),
    in_force: Map([]),
    told_words: Map([]),
    persons_ver: 0,
    persons: None,
    outs: Map([]),
    off_logs: Map([]),
    written: None,
  }
  c.peers_current = c.state is Some(_) && !c.removed()
  c.lock = read_lock(disk, crypto, data, None)
  c
}

///|
/// The person logs of this Cloud (state.ts `personChainsOf`), made on first use.
pub fn Cloud::person_chains(self : Cloud) -> PersonChains {
  match self.persons {
    Some(p) => p
    None => {
      let p = PersonChains::new(self.crypto, Some(self.disk), Some(join([mesh_dir(self.data), "person-chains.json"])))
      self.persons = Some(p)
      self.heard_persons(p)
      p
    }
  }
}

///|
/// The pinned lock of `ws` as its file has it (state.ts `readLock`): none without one; a file that holds no lock is
/// a lock that admits nobody.
pub fn read_lock(disk : Disk, c : Crypto, data : String, ws : String?) -> KeptLock? {
  let path = match ws {
    None => lock_path(data)
    Some(w) => joined_lock_path(data, w)
  }
  guard disk.read(path) is Some(text) else { return None }
  let read = try {
    guard parse(text) is Some(raw) else { raise Failed("not JSON") }
    let entries = match get(raw, "entries") {
      Some(Array(xs)) => xs.map(as_entry)
      _ => []
    }
    if entries.iter().any(e => e is None) {
      raise Failed("an entry is malformed")
    }
    let entries = entries.map(e => e.unwrap())
    let aside = match get(raw, "aside") {
      Some(Array(xs)) => xs.filter_map(as_entry)
      _ => []
    }
    (entries, aside, fold(c, entries, None))
  } catch {
    _ => return Some({ entries: [], aside: [], state: None })
  }
  let (entries, aside, state) = read
  if aside.length() == 0 {
    return Some({ entries, aside: [], state: Some(state) })
  }
  let rechosen = try {
    let t = rechoose({ entries, aside }, lock_rules(c, state, None, Map([])))
    let same = t.kept.entries.length() == entries.length() &&
      t.kept.entries.iter().zip(entries.iter()).all(p => hash_of(p.0) == hash_of(p.1))
    Some({ entries: t.kept.entries, aside: t.kept.aside, state: Some(if same { state } else { fold(c, t.kept.entries, None) }) })
  } catch {
    _ => None
  }
  match rechosen {
    Some(k) => Some(k)
    None => Some({ entries, aside: [], state: Some(state) })
  }
}

///|
/// The workspace lock's rules for keeping, of the lock whose chain's state is `s` (state.ts `lockRules`).
fn lock_rules(c : Crypto, s : @lock.LockState, now : Double?, states : Map[String, @lock.LockState]) -> LogRules {
  states[s.head] = s
  {
    chain: all => lock_chain(c, all, s.genesis),
    pre: Some(e => if ws_of(e) != s.ws { Some("an entry of another workspace's lock") } else { None }),
    now: match now {
      None => None
      Some(t) =>
        Some((parent, e, find) => {
          guard state_at(c, parent, find, states) is Some(at) else { return None }
          match (try Ok(apply(c, at, e, Some(t))) catch { e => Err(e) }) {
            Ok(_) => None
            Err(err) => Some(err.message())
          }
        })
    },
  }
}

///|
/// The lock's state after the entry of hash `h`, from the nearest state made along its parents (state.ts `stateAt`).
fn state_at(c : Crypto, h : String, find : (String) -> Json?, states : Map[String, @lock.LockState]) -> @lock.LockState? {
  let path = []
  let mut at : String? = Some(h)
  while at is Some(x) && !states.contains(x) {
    match find(x) {
      None => return None
      Some(e) => {
        path.push(e)
        at = prev_of(e)
      }
    }
  }
  let mut s : @lock.LockState? = match at {
    None => None
    Some(x) => states.get(x)
  }
  path.rev_in_place()
  for e in path {
    let next = try {
      match s {
        None => genesis(c, e)
        Some(p) => apply(c, p, e, None)
      }
    } catch {
      _ => return None
    }
    s = Some(next)
    states[hash_of(e)] = next
  }
  s
}

///|
/// A lock turned off here with `brought` taken into what was kept of it (state.ts `onAgain`).
priv enum Again {
  Back(Kept, @lock.LockState, Int)
  KeptBeside
  NotAgain
}

///|
fn on_again(c : Crypto, off : OffRecord, g : String, brought : Array[Json], now : Double) -> Again {
  guard off.logs.get(g) is Some(was) else { return NotAgain }
  let r = try {
    let t = keep(was, brought, lock_rules(c, fold(c, was.entries, None), Some(now), Map([])))
    let state = fold(c, t.kept.entries, None)
    if !state.disabled {
      Back(t.kept, state, t.taken)
    } else if t.changed {
      off.logs[g] = t.kept
      KeptBeside
    } else {
      NotAgain
    }
  } catch {
    _ => NotAgain
  }
  r
}

///|
/// What is kept of a lock, as a word that changes when any of it does.
fn kept_text(l : KeptLock?) -> String {
  match l {
    None => "null"
    Some(k) => stringify(jarr([jarr(k.entries), jarr(k.aside)]))
  }
}

///|
fn same_kept(a : KeptLock?, b : KeptLock?) -> Bool {
  kept_text(a) == kept_text(b) &&
  (match a {
    Some(x) => x.state is None
    None => false
  }) ==
  (match b {
    Some(x) => x.state is None
    None => false
  })
}

///|
/// The state read again from its file; told when it changed, or anyway (`tell`).
pub fn Cloud::reload(self : Cloud, tell? : Bool = false) -> Unit {
  let next = try Ok(read_state(self.disk, self.data)) catch { e => Err(e) }
  guard next is Ok(next) else { return }
  self.written = None
  let text = (s : CloudState?) => match s {
    Some(x) => stringify(x.to_json())
    None => "null"
  }
  if tell || text(next) != text(self.state) {
    self.state = next
    self.tell()
  }
}

///|
/// lock.json read again (another process changed it: `lock reset`).
pub fn Cloud::reload_lock(self : Cloud) -> Unit {
  let next = read_lock(self.disk, self.crypto, self.data, None)
  if same_kept(next, self.lock) {
    return
  }
  self.lock = next
  self.refilter()
}

///|
/// The joined workspaces' locks read again from their files; told when one did.
pub fn Cloud::reload_joined(self : Cloud) -> Unit {
  let changed = self.joined_locks
    .iter()
    .filter(p => !same_kept(read_lock(self.disk, self.crypto, self.data, Some(p.0)), p.1))
    .map(p => p.0)
    .collect()
  if changed.length() == 0 {
    return
  }
  for ws in changed {
    self.joined_locks.remove(ws)
  }
  self.tell()
}

///|
fn Cloud::is_home(self : Cloud, ws : String?) -> Bool {
  match ws {
    None => true
    Some(w) =>
      match self.state {
        Some(s) => s.get("workspace") is Some(String(x)) && x == w
        None => false
      }
  }
}

///|
fn Cloud::lock_of(self : Cloud, ws : String?) -> KeptLock? {
  if self.is_home(ws) {
    return self.lock
  }
  let w = ws.unwrap()
  match self.joined_locks.get(w) {
    Some(l) => l
    None => {
      let l = read_lock(self.disk, self.crypto, self.data, Some(w))
      self.joined_locks[w] = l
      l
    }
  }
}

///|
fn disabled(l : KeptLock) -> Bool {
  match l.state {
    Some(s) => s.disabled
    None => false
  }
}

///|
fn moved_root(l : KeptLock?) -> String? {
  match l {
    Some(k) =>
      match k.state {
        Some(s) if !s.disabled => s.moved
        _ => None
      }
    None => None
  }
}

///|
/// The lock in force in `ws` (the home one when none): none when none is pinned or it was turned off; where its chain
/// moved, the state its people's logs and the bodies say (state.ts `locked`).
pub fn Cloud::locked(self : Cloud, ws? : String? = None) -> Locked? {
  guard self.lock_of(ws) is Some(l) else { return None }
  if disabled(l) {
    return None
  }
  match l.state.bind(s => s.moved) {
    None => Some({ state: l.state, waiting: false })
    Some(root) => {
      let f = self.force_of(ws, l, root)
      if f.on == "off" {
        None
      } else {
        Some(f.out)
      }
    }
  }
}

///|
/// What says which stations are the workspace's (state.ts `rosterOf`).
pub fn Cloud::roster_of(self : Cloud, ws? : String? = None) -> Locked? {
  match self.locked(ws~) {
    Some(l) if l.waiting => self.chain(ws~)
    l => l
  }
}

///|
pub fn Cloud::waiting(self : Cloud, ws? : String? = None) -> Bool {
  match self.locked(ws~) {
    Some(l) => l.waiting
    None => false
  }
}

///|
/// The workspace lock's own chain pinned in `ws` (state.ts `chain`).
pub fn Cloud::chain(self : Cloud, ws? : String? = None) -> Locked? {
  guard self.lock_of(ws) is Some(l) else { return None }
  if disabled(l) {
    return None
  }
  Some({ state: l.state, waiting: false })
}

///|
/// The pinned lock of `ws` as kept (its active chain and what is off it): none where none is pinned or it is off.
pub fn Cloud::kept_lock(self : Cloud, ws? : String? = None) -> KeptLock? {
  match self.lock_of(ws) {
    Some(l) if !disabled(l) => Some(l)
    _ => None
  }
}

///|
fn Cloud::id_of(self : Cloud, ws : String?) -> String {
  if self.is_home(ws) {
    match self.state {
      Some(s) => s.text("workspace")
      None => ""
    }
  } else {
    ws.unwrap()
  }
}

///|
/// The bodies of `ws`'s statements kept here (state.ts `bodies`).
pub fn Cloud::bodies(self : Cloud, ws : String?) -> LockBodies {
  let id = self.id_of(ws)
  match self.lock_bodies.get(id) {
    Some(b) => b
    None => {
      let b = LockBodies::new(Some(self.disk), if id == "" { None } else { Some(bodies_path(self.data, id)) })
      self.lock_bodies[id] = b
      b
    }
  }
}

///|
/// Bodies of `ws`'s statements given by a device or a station of it (state.ts `takeBodies`).
pub fn Cloud::take_bodies(self : Cloud, ws : String?, bodies : Array[Json]) -> (Int, Array[BodyRefused]) {
  if self.lock_of(ws) is None {
    return (0, bodies.map(_ => { hash: None, why: "it names no workspace this keeper keeps" }))
  }
  let chains = self.person_chains()
  let t = self.bodies(ws).take(self.crypto, self.id_of(ws), bodies, h => chains.commits_to(h))
  if t.0 > 0 {
    self.force_changed()
  }
  t
}

///|
/// Whether `ws`'s chain moved and its state in force has the root's person out of `~root` (state.ts `rootOut`).
pub fn Cloud::root_out(self : Cloud, ws : String?) -> Bool {
  let l = self.lock_of(ws)
  guard moved_root(l) is Some(root) else { return false }
  let f = self.force_of(ws, l.unwrap(), root)
  (f.on == "on" || f.on == "off") && !f.root_in
}

///|
/// The person logs `ws`'s state is made of where its chain moved (state.ts `needs`).
pub fn Cloud::needs(self : Cloud, ws : String?) -> Array[String] {
  let l = self.lock_of(ws)
  guard moved_root(l) is Some(root) else { return [] }
  self.force_of(ws, l.unwrap(), root).needs
}

///|
/// What `ws`'s list says, on or off (state.ts `list`).
pub fn Cloud::list(self : Cloud, ws : String?) -> Locked? {
  guard self.chain(ws~) is Some(c) else { return None }
  guard c.state.bind(s => s.moved) is Some(root) else { return Some(c) }
  Some(self.force_of(ws, self.lock_of(ws).unwrap(), root).out)
}

///|
/// The bodies of `ws` station or device `key` is given (state.ts `givenTo`).
pub fn Cloud::given_to(self : Cloud, ws : String?, key : String) -> Given {
  guard self.list(ws) is Some(li) && li.state is Some(st) && !li.waiting else { return Only([]) }
  if st.stations.contains(key) || st.devices.contains(key) || st.devices.values().any(d => d.sign_key == Some(key)) {
    return All
  }
  let ws_id = self.id_of(ws)
  if self.rig_in(ws_id) is None &&
    self.rigs_named(ws_id).iter().any(r => text_at(r, "id") == Some(key) && (self.rig_vouched)(ws_id, r)) {
    return All
  }
  let l = self.lock_of(ws).unwrap()
  guard l.state.bind(s => s.moved) is Some(root) else { return Only([]) }
  Only(self.out_of(ws, l, root).get(key).unwrap_or([]))
}

///|
fn subject_of(b : Json?) -> String? {
  let txt = (k : String) => match field(b, k) {
    Some(String(s)) => s
    Some(v) => stringify(v)
    None => "undefined"
  }
  match field(b, "kind") {
    Some(String("member.remove")) => Some("m|" + txt("sub"))
    Some(String("station.remove")) => Some("s|" + txt("key"))
    _ => None
  }
}

///|
fn push_unique(xs : Array[String], x : String) -> Unit {
  if !xs.contains(x) {
    xs.push(x)
  }
}

///|
/// Whom each removal in force in `ws` took out (by key), and what each is given (state.ts `outOf`).
fn Cloud::out_of(self : Cloud, ws : String?, l : KeptLock, root : String) -> Map[String, Array[String]] {
  let id = self.id_of(ws)
  let f = self.force_of(ws, l, root)
  let word = "\{f.word}:\{self.bodies(ws).version}:\{self.persons_ver}"
  if self.outs.get(id) is Some((w, out)) && w == word {
    return out
  }
  let out : Map[String, Array[String]] = Map([])
  let chains = self.person_chains().every().map(p => p.1)
  let kept = self.bodies(ws).all()
  let bodies = kept.values().collect()
  let in_force = []
  for x in roster4_moved(self.crypto, id, l.entries, chains, bodies).in_force {
    push_unique(in_force, x.1)
  }
  let subjects : Map[String, Array[String]] = Map([])
  for h in in_force {
    if subject_of(kept.get(h)) is Some(subject) {
      match subjects.get(subject) {
        Some(xs) => xs.push(h)
        None => subjects[subject] = [h]
      }
    }
  }
  let st = f.out.state.unwrap()
  let named : Map[String, Unit] = Map([])
  for k, _ in st.stations {
    named[k] = ()
  }
  for _, d in st.devices {
    named[d.id] = ()
    if d.sign_key is Some(k) {
      named[k] = ()
    }
  }
  for subject, removals in subjects {
    let r = roster4_moved(self.crypto, id, l.entries, chains, bodies, without=removals)
    let told = kept.iter().filter(p => subject_of(Some(p.1)) == Some(subject)).map(p => p.0).collect()
    let keys = r.stations.copy()
    for m in r.members {
      if m.keys is Some(ks) {
        keys.append(ks)
      }
    }
    for x in r.carried_keys {
      keys.push(x.0)
    }
    for k in keys {
      if named.contains(k) {
        continue
      }
      let given = out.get(k).unwrap_or([])
      for h in told {
        let mut p : String? = Some(h)
        let mut n = 0
        while p is Some(x) && n < 10000 {
          guard kept.get(x) is Some(q) else { break }
          push_unique(given, x)
          p = text_at(q, "prev")
          n += 1
        }
      }
      out[k] = given
    }
  }
  self.outs[id] = (word, out)
  out
}

///|
/// The person logs a device of `ws` is given to work out its state itself (state.ts `logsOf`).
pub fn Cloud::logs_of(self : Cloud, ws : String?) -> Array[String] {
  guard self.lock_of(ws) is Some(l) && l.state is Some(st) else { return [] }
  let needed = self.needs(ws)
  if needed.length() > 0 {
    return needed
  }
  let id = self.id_of(ws)
  let bound = st.persons.values().collect()
  self
  .person_chains()
  .every()
  .filter(p => {
    if bound.contains(p.0) {
      return true
    }
    let t = ws_tag(id, p.0)
    p.1.iter().any(e => kind_of(e) == "ws" && field(body_of(e), "t") == Some(Json::string(t)))
  })
  .map(p => p.0)
}

///|
/// The statements of `ws` on the active chain of a log kept here whose body is not kept (state.ts `lacking`).
pub fn Cloud::lacking(self : Cloud, ws : String?) -> Array[String] {
  if self.lock_of(ws) is None {
    return []
  }
  let id = self.id_of(ws)
  let bodies = self.bodies(ws)
  let out = []
  for p in self.person_chains().every() {
    let t = ws_tag(id, p.0)
    for e in p.1 {
      let b = body_of(e)
      if kind_of(e) == "ws" && field(b, "t") == Some(Json::string(t)) && field(b, "h") is Some(String(h)) && !bodies.has(h) {
        push_unique(out, h)
      }
    }
  }
  out
}

///|
/// A word that changes whenever the state in force in `ws` does where its chain moved (state.ts `forceWord`).
pub fn Cloud::force_word(self : Cloud, ws : String?) -> String {
  let l = self.lock_of(ws)
  guard moved_root(l) is Some(root) else { return "" }
  self.force_of(ws, l.unwrap(), root).word
}

///|
/// The word a state was made with: a moved workspace's in force, else its chain's head (lock.ts `stateWord`).
pub fn Cloud::state_word(self : Cloud, ws : String?) -> String {
  let w = self.force_word(ws)
  if w != "" {
    return w
  }
  match self.lock_of(ws) {
    Some({ state: Some(s), .. }) => s.head
    _ => ""
  }
}

///|
fn Cloud::heard_persons(self : Cloud, chains : PersonChains) -> Unit {
  chains.needs = ws => self.needs(if self.is_home(Some(ws)) { None } else { Some(ws) })
  chains.watch(_ => {
    self.persons_ver += 1
    self.force_changed()
  })
  |> ignore
}

///|
fn Cloud::force_changed(self : Cloud) -> Unit {
  let mut told = false
  let mut home = false
  let locks : Array[(String?, KeptLock?)] = [(None, self.lock)]
  for ws, l in self.joined_locks {
    locks.push((Some(ws), l))
  }
  for p in locks {
    guard moved_root(p.1) is Some(root) else { continue }
    let id = self.id_of(p.0)
    let f = self.force_of(p.0, p.1.unwrap(), root)
    let word = "\{f.on}:\{f.word}"
    if self.told_words.get(id) == Some(word) {
      continue
    }
    self.told_words[id] = word
    told = true
    if p.0 is None {
      home = true
    }
  }
  if home {
    self.refilter()
  } else if told {
    self.tell()
  }
}

///|
/// Number(x) as JavaScript says it, of what may be in an entry's body.
fn js_number(v : Json?) -> Double {
  match v {
    None => @double.not_a_number
    Some(Null) => 0.0
    Some(True) => 1.0
    Some(False) => 0.0
    Some(Number(n, ..)) => n
    Some(String(s)) => @jsjson.js_number(s)
    Some(Array([])) => 0.0
    Some(Array([x])) =>
      match x {
        Number(_) | String(_) => js_number(Some(x))
        Null => 0.0
        _ => @double.not_a_number
      }
    _ => @double.not_a_number
  }
}

///|
/// Code-unit order, as JavaScript's `<` and default sort order strings.
pub fn js_compare(a : String, b : String) -> Int {
  @jsjson.js_compare(a, b)
}

///|
fn sorted_texts(xs : Array[String]) -> Array[String] {
  let out = xs.copy()
  stable_sort(out, js_compare)
  out
}

///|
fn Cloud::force_of(self : Cloud, ws : String?, l : KeptLock, root : String) -> InForce {
  let id = self.id_of(ws)
  let now = (self.now)()
  let bodies = self.bodies(ws)
  let ver = "\{self.persons_ver}:\{bodies.version}"
  if self.in_force.get(id) is Some(was) &&
    physical_equal(was.lock, l) &&
    was.ver == ver &&
    now >= was.from &&
    now < was.until {
    return was
  }
  let logs = self.person_chains().every()
  let kept = bodies.all().values().collect()
  let s = state4_moved(self.crypto, id, l.entries, logs.map(p => p.1), kept, now)
  let out : Locked = if s.on == "on" || s.on == "off" {
    { state: Some(s.lock), waiting: false }
  } else {
    { state: Some(state4(self.crypto, id, root, [], [], now).lock), waiting: true }
  }
  let st = out.state.unwrap()
  let members = sorted_texts(st.members.keys().collect()).map(k => {
    let m = st.members.get(k).unwrap()
    jarr([jstr(k), jobj([("sub", jstr(m.sub)), ("email", jstr(m.email)), ("role", jstr(m.role))])])
  })
  let persons = sorted_texts(st.persons.keys().collect()).map(k => jarr([jstr(k), jstr(st.persons.get(k).unwrap())]))
  let word_of = jobj([
    ("on", jstr(s.on)),
    ("origins", jstrs(st.origins)),
    ("rp_id", jstr(st.rp_id)),
    ("cloud_keys", st.cloud_keys),
    ("members", jarr(members)),
    ("persons", jarr(persons)),
    ("devices", jstrs(sorted_texts(st.devices.keys().collect()))),
    ("stations", jstrs(sorted_texts(st.stations.keys().collect()))),
  ])
  let word = sha256_hex(canonical(word_of) catch { _ => "" })
  let needs = [root]
  for _, g in s.lock.persons {
    push_unique(needs, g)
  }
  let mut from = @double.neg_infinity
  let mut until = @double.infinity
  for p in logs {
    let t = ws_tag(id, p.0)
    for e in p.1 {
      if kind_of(e) == "ws" && field(body_of(e), "t") == Some(Json::string(t)) {
        push_unique(needs, p.0)
      }
      if kind_of(e) != "web" {
        continue
      }
      for x in [js_number(get(e, "at")) - web_skew, js_number(field(body_of(e), "exp"))] {
        if x.is_nan() || x.is_inf() {
          continue
        }
        if x <= now {
          from = if x > from { x } else { from }
        } else {
          until = if x < until { x } else { until }
        }
      }
    }
  }
  match l.state {
    Some(cs) =>
      for _, d in cs.devices {
        guard d.kind == "web" && d.exp is Some(exp) else { continue }
        if exp <= now {
          from = if exp > from { exp } else { from }
        } else {
          until = if exp < until { exp } else { until }
        }
      }
    None => ()
  }
  let f : InForce = { lock: l, ver, from, until, on: s.on, out, needs, word, root_in: s.root_in }
  self.in_force[id] = f
  f
}

///|
/// The credential keys that count in `ws`: its lock's once pinned, else the control plane's (state.ts `grantKeys`).
pub fn Cloud::grant_keys(self : Cloud, ws? : String? = None) -> Json? {
  match self.locked(ws~) {
    None => self.state.bind(s => s.get("grant_keys"))
    Some(l) =>
      match l.state {
        Some(s) => Some(s.cloud_keys)
        None => Some(Json::null())
      }
  }
}

///|
/// The lock hash joining `ws` said to pin (state.ts `pendingLock`).
pub fn Cloud::pending_lock(self : Cloud, ws : String) -> String? {
  match self.disk.read(joined_pending_path(self.data, ws)).bind(parse) {
    Some(raw) =>
      match get(raw, "hash") {
        Some(String(h)) if is_hex32(h) => Some(h)
        _ => None
      }
    None => None
  }
}

///|
/// A joined workspace the control plane no longer names: its lock kept, deciding again once it is named (state.ts
/// `leftJoined`). Only the plane's word: no pinned lock is let go by it.
pub fn Cloud::left_joined(self : Cloud, ws : String) -> Unit {
  self.plane_lock_seqs.remove(ws)
}

///|
/// A workspace it joined takes over as its home one (state.ts `succeed`): refused while the home one is locked and
/// that workspace's lock is not pinned here.
pub fn Cloud::succeed(self : Cloud, ws : String, demote_old_home? : Bool = false) -> Bool {
  if self.chain() is Some(_) && self.chain(ws=Some(ws)) is None {
    return false
  }
  let old_home = match self.state {
    Some(s) => s.text("workspace")
    None => ""
  }
  if demote_old_home && old_home != "" && old_home != ws {
    (try Ok(self.disk.mkdir(dirname(joined_lock_path(self.data, old_home)))) catch { e => Err(e) }) |> ignore
    for pair in [
      (lock_path(self.data), joined_lock_path(self.data, old_home)),
      (turned_off_path(lock_path(self.data)), turned_off_path(joined_lock_path(self.data, old_home))),
      (pending_lock_path(self.data), joined_pending_path(self.data, old_home)),
    ] {
      if self.disk.exists(pair.0) {
        (try Ok(self.disk.rename(pair.0, pair.1)) catch { e => Err(e) }) |> ignore
      } else {
        self.disk.remove(pair.1)
      }
    }
  }
  for pair in [
    (joined_lock_path(self.data, ws), lock_path(self.data)),
    (turned_off_path(joined_lock_path(self.data, ws)), turned_off_path(lock_path(self.data))),
    (joined_pending_path(self.data, ws), pending_lock_path(self.data)),
  ] {
    if self.disk.exists(pair.0) {
      (try Ok(self.disk.rename(pair.0, pair.1)) catch { e => Err(e) }) |> ignore
    } else {
      self.disk.remove(pair.1)
    }
  }
  self.lock = read_lock(self.disk, self.crypto, self.data, None)
  self.joined_locks.remove(ws)
  if demote_old_home && old_home != "" && old_home != ws {
    self.joined_locks.remove(old_home)
  }
  self.off_logs.clear()
  self.plane_lock_seqs.remove(ws)
  true
}

///|
/// What the control plane says of the roster and gateways (state.ts `setPlaneLists`).
pub fn Cloud::set_plane_lists(self : Cloud, peers : Array[Json], gateways : Json?) -> Unit {
  self.plane_peers = Some(peers)
  self.plane_gateways = gateways
}

///|
/// The roster and gateways as the lock lets them (state.ts `filtered`).
pub fn Cloud::filtered(self : Cloud, st : CloudState) -> (Array[Json], Json?) {
  let peers = match self.plane_peers {
    Some(p) => p
    None => st.array("peers")
  }
  let gateways = match self.plane_gateways {
    Some(g) => Some(g)
    None => st.get("gateway_keys")
  }
  guard self.roster_of() is Some(l) else { return (peers, gateways) }
  let has_station = (p : Json) => match (l.state, get(p, "id")) {
    (Some(s), Some(String(id))) => s.stations.contains(id)
    _ => false
  }
  let gw = match gateways {
    Some(Array(gs)) =>
      Some(
        jarr(
          gs.filter(g => match (l.state, g) {
            (Some(s), String(k)) => s.gateways.contains(k)
            _ => false
          }),
        ),
      )
    other => other
  }
  (peers.filter(has_station), gw)
}

///|
/// The stations the control plane lists in `ws` that the lock in force there leaves out (state.ts `unprotected`).
pub fn Cloud::unprotected(self : Cloud, ws? : String? = None) -> Array[Json] {
  guard self.roster_of(ws~) is Some({ state: Some(s), .. }) && self.state is Some(st) else { return [] }
  let listed = if self.is_home(ws) {
    self.plane_peers.unwrap_or([])
  } else {
    match st.joined().search_by(j => text_at(j, "workspace") == ws) {
      Some(i) => array_at(st.joined()[i], "peers").unwrap_or([])
      None => []
    }
  }
  let me = st.text("station")
  listed.filter(p => match get(p, "id") {
    Some(String(id)) => id != me && !s.stations.contains(id)
    _ => false
  })
}

///|
fn Cloud::refilter(self : Cloud) -> Unit {
  guard self.state is Some(_) else { return self.tell() }
  self.update(st => {
    let (peers, gateways) = self.filtered(st)
    st.fields["peers"] = jarr(peers)
    if gateways is Some(g) {
      st.fields["gateway_keys"] = g
    }
  })
}

///|
/// Pins a lock, or takes more of the pinned one (state.ts `takeLock`): how many entries were kept that were not;
/// raises why where none was.
pub fn Cloud::take_lock(self : Cloud, entries : Array[Json], ws? : String? = None, fork? : Bool = false) -> Int raise Failure {
  let t = self.keep_lock(entries, ws~, fork~)
  if t.refusal is Some(r) && t.taken == 0 {
    raise Failed(r)
  }
  t.taken
}

///|
/// Pins a lock (its genesis first, of this workspace and not one turned off here: else raises why), or takes more of
/// the pinned one (state.ts `keepLock`).
pub fn Cloud::keep_lock(self : Cloud, entries : Array[Json], ws? : String? = None, fork? : Bool = false) -> LockTook raise Failure {
  let home = self.is_home(ws)
  let now = (self.now)()
  let current = self.lock_of(ws)
  let had = match current {
    Some({ state: Some(_), .. } as k) => Some(k)
    _ => None
  }
  if current is Some(_) && had is None {
    raise Failed("this station's lock.json is broken; run `stillfail lock reset` on it")
  }
  let workspace = if home { self.state.map(s => s.text("workspace")) } else { ws }
  let workspace = match (home, self.state) {
    (true, Some(s)) => if s.fields.contains("workspace") { workspace } else { None }
    (true, None) => None
    _ => workspace
  }
  let path = if home { lock_path(self.data) } else { joined_lock_path(self.data, ws.unwrap()) }
  let mut kept : Kept = match had {
    Some(h) => { entries: h.entries, aside: h.aside }
    None => { entries: [], aside: [] }
  }
  let mut state : @lock.LockState? = had.bind(h => h.state)
  let mut taken = 0
  let mut changed = false
  let mut rest = entries
  let mut off : Array[OffChain] = []
  if state is None {
    guard entries.get(0) is Some(e) else { return { taken: 0, off: [], refusal: None } }
    if workspace is Some(w) && ws_of(e) != w {
      raise Failed("the lock is another workspace's")
    }
    let was_off = read_off(self.disk, path)
    let g = entry_hash(e)
    let back = if fork && was_off.genesis.contains(g) { on_again(self.crypto, was_off, g, entries, now) } else { NotAgain }
    if back is KeptBeside {
      self.off_written(path, was_off)
    }
    if was_off.genesis.contains(g) && !(back is Back(_)) {
      raise Failed("this lock was turned off by its owner here; it is not taken again")
    }
    match back {
      Back(k, s, n) => {
        self.off_written(path, { genesis: was_off.genesis.filter(h => h != g), logs: was_off.logs })
        state = Some(s)
        kept = k
        taken = n
        rest = []
      }
      _ => {
        state = Some(fold(self.crypto, [e], Some(now)))
        kept = { entries: [e], aside: [] }
        taken = 1
        rest = entries[1:].to_owned()
      }
    }
    changed = true
  }
  let head = state.unwrap().head
  hashable(rest)
  let known : Map[String, Unit] = Map([])
  for e in kept.entries {
    known[hash_of(e)] = ()
  }
  for e in kept.aside {
    known[hash_of(e)] = ()
  }
  let fresh = []
  for e in rest {
    let h = hash_of(e)
    if !known.contains(h) {
      known[h] = ()
      fresh.push(e)
    }
  }
  let in_line = () => {
    for i, e in fresh {
      let want = if i == 0 { head } else { hash_of(fresh[i - 1]) }
      if prev_of(e) != Some(want) {
        return false
      }
    }
    true
  }
  if !fork || (kept.aside.length() == 0 && in_line()) {
    for e in fresh {
      let s = state.unwrap()
      if prev_of(e) != Some(s.head) {
        off = [{ why: "not on the head", refusal: None, winner: None, step: None, under: None, hash: hash_of(e), seq: seq_of(e), kept: false }]
        break
      }
      let next = try {
        if ws_of(e) != s.ws {
          raise Failed("an entry of another workspace's lock")
        }
        Ok(apply(self.crypto, s, e, Some(now)))
      } catch {
        err => Err(why_of(err))
      }
      match next {
        Ok(n) => {
          state = Some(n)
          kept = { entries: kept.entries + [e], aside: kept.aside }
          taken += 1
          changed = true
        }
        Err(why) => {
          off = [{ why: "refused", refusal: Some(why), winner: None, step: None, under: None, hash: hash_of(e), seq: seq_of(e), kept: false }]
          break
        }
      }
    }
  } else {
    let t = keep(kept, rest, lock_rules(self.crypto, state.unwrap(), Some(now), Map([])))
    if t.changed {
      changed = true
      taken += t.taken
      if t.moved || t.kept.entries.length() != kept.entries.length() {
        state = Some(fold(self.crypto, t.kept.entries, None))
      }
      kept = t.kept
    }
    off = t.off
  }
  let on : Map[String, Unit] = Map([])
  for e in kept.entries {
    on[hash_of(e)] = ()
  }
  let st = state.unwrap()
  let refusal = self.refusal_of(entries, on, off, st, now)
  if changed {
    let text = if kept.aside.length() > 0 {
      stringify_pretty(jobj([("entries", jarr(kept.entries)), ("aside", jarr(kept.aside))]))
    } else {
      stringify_pretty(jobj([("entries", jarr(kept.entries))]))
    }
    self.disk.mkdir(dirname(path))
    self.disk.write(path, text)
    let set = (l : KeptLock?) => if home { self.lock = l } else { self.joined_locks[ws.unwrap()] = l }
    set(Some({ entries: kept.entries, aside: kept.aside, state: Some(st) }))
    if st.disabled {
      let was_off = read_off(self.disk, path)
      let logs = was_off.logs
      logs[st.genesis] = kept
      self.off_written(path, { genesis: was_off.genesis.filter(h => h != st.genesis) + [st.genesis], logs })
      self.disk.remove(path)
      set(None)
    }
    if home {
      self.refilter()
    } else {
      self.tell()
    }
  }
  { taken, off, refusal }
}

///|
/// Why the first of `entries` not on the chain is not, as a station answered before it kept every branch (state.ts
/// `refusalOf`).
fn Cloud::refusal_of(self : Cloud, entries : Array[Json], on : Map[String, Unit], off : Array[OffChain], state : @lock.LockState, now : Double) -> String? {
  guard entries.search_by(x => !on.contains(hash_of(x))) is Some(i) else { return None }
  let e = entries[i]
  let o = match off.search_by(x => x.hash == hash_of(e)) {
    Some(j) => Some(off[j])
    None => None
  }
  if o is Some({ why: "refused", refusal, .. }) {
    return Some(refusal.unwrap_or(""))
  }
  match o {
    None => return Some(fork_words)
    Some(x) => if (x.why != "no parent" && x.why != "not on the head") || seq_of(e) <= state.seq { return Some(fork_words) }
  }
  match (try Ok(apply(self.crypto, state, e, Some(now))) catch { e => Err(e) }) {
    Err(err) => Some(err.message())
    Ok(_) => Some(fork_words)
  }
}

///|
/// The lock's entries after `seq` (all for -1) in `ws`: its active chain (state.ts `lockAfter`).
pub fn Cloud::lock_after(self : Cloud, seq : Double, ws? : String? = None) -> Array[Json] {
  match self.lock_of(ws) {
    Some(l) => l.entries.filter(e => seq_of(e) > seq)
    None => []
  }
}

///|
/// Every entry kept of the lock in `ws`: its active chain, then those off it (state.ts `lockKept`).
pub fn Cloud::lock_kept(self : Cloud, ws? : String? = None) -> Array[Json] {
  match self.lock_of(ws) {
    Some(l) => l.entries + l.aside
    None => []
  }
}

///|
/// What was kept of the lock of `ws` last turned off here, where none is pinned there now (state.ts `lockOff`).
pub fn Cloud::lock_off(self : Cloud, ws? : String? = None) -> Kept? {
  if self.lock_of(ws) is Some(_) {
    return None
  }
  let path = if self.is_home(ws) { lock_path(self.data) } else { joined_lock_path(self.data, ws.unwrap()) }
  match self.off_logs.get(path) {
    Some(k) => k
    None => {
      let off = read_off(self.disk, path)
      let k = match off.genesis.last() {
        Some(g) => off.logs.get(g)
        None => None
      }
      self.off_logs[path] = k
      k
    }
  }
}

///|
fn Cloud::off_written(self : Cloud, path : String, off : OffRecord) -> Unit raise Failure {
  write_off(self.disk, path, off)
  self.off_logs[path] = match off.genesis.last() {
    Some(g) => off.logs.get(g)
    None => None
  }
}

///|
/// Takes the lock away on this machine (`stillfail lock reset`): kept beside as lock.json.reset-<time>.
pub fn reset_lock(disk : Disk, data : String, now : Double) -> Bool {
  if !disk.exists(lock_path(data)) {
    return false
  }
  (try Ok(disk.rename(lock_path(data), "\{lock_path(data)}.reset-\{now.to_int64()}")) catch { e => Err(e) }) is Ok(_)
}

///|
/// Changes the state, writes it where that changed what was written, tells the listeners (state.ts `update`).
pub fn Cloud::update(self : Cloud, change : (CloudState) -> Unit) -> Unit {
  guard self.state is Some(s) else { return }
  change(s)
  let text = state_text(s)
  if Some(text) != self.written {
    (try Ok(self.disk.write(state_path(self.data), text)) catch { e => Err(e) }) |> ignore
    self.written = Some(text)
  }
  self.tell()
}

///|
/// The control plane it is enrolled in ("stillfail" or "comma").
pub fn Cloud::provider(self : Cloud) -> String {
  match self.state.bind(s => s.get("provider")) {
    Some(String("comma")) => "comma"
    _ => "stillfail"
  }
}

///|
pub fn Cloud::removed(self : Cloud) -> Bool {
  match self.state {
    Some(s) => s.fields.contains("removed_at")
    None => false
  }
}

///|
/// The workspace it was enrolled in first, where its station-wide settings are managed (state.ts `home`).
pub fn Cloud::home(self : Cloud) -> String? {
  match self.state {
    Some(s) if s.text("workspace") != "" && truthy(s.get("workspace")) && !self.removed() => Some(s.text("workspace"))
    _ => None
  }
}

///|
fn truthy(v : Json?) -> Bool {
  @jsjson.json_truthy(v)
}

///|
fn home_membership(s : CloudState) -> Json {
  let out : Map[String, Json] = Map([])
  for k in ["workspace", "workspace_name"] {
    if s.get(k) is Some(v) {
      out[k] = v
    }
  }
  if s.get("workspace_emoji") is Some(String(e)) && e != "" {
    out["workspace_emoji"] = jstr(e)
  }
  if s.get("workspace_icon") is Some(String(ic)) && ic != "" {
    out["workspace_icon"] = jstr(ic)
  }
  for k in ["name", "peers", "revocations"] {
    if s.get(k) is Some(v) {
      out[k] = v
    }
  }
  if s.get("rig") is Some(r) {
    out["rig"] = r
  }
  out["home"] = Json::boolean(true)
  Json::object(out)
}

///|
/// Whether this station is a rig in `ws`, and whose it is (state.ts `rigIn`).
pub fn Cloud::rig_in(self : Cloud, ws : String) -> Json? {
  guard self.state is Some(s) && truthy(s.get("workspace")) && !self.removed() else { return None }
  if ws == s.text("workspace") {
    return s.get("rig")
  }
  match s.joined().search_by(j => text_at(j, "workspace") == Some(ws)) {
    Some(i) => get(s.joined()[i], "rig")
    None => None
  }
}

///|
/// Whether this machine is in at least one workspace and every workspace it is in is tasks-only (state.ts `isRigOnly`).
pub fn Cloud::is_rig_only(self : Cloud) -> Bool {
  let all = self.memberships()
  all.length() > 0 && all.iter().all(m => get(m, "rig") is Some(_))
}

///|
/// The full (non-rig) workspaces this station is in (state.ts `fullMemberships`).
pub fn Cloud::full_memberships(self : Cloud) -> Array[Json] {
  self.memberships().filter(m => get(m, "rig") is None)
}

///|
/// The tasks-only (rig) workspaces this station is in (state.ts `rigMemberships`).
pub fn Cloud::rig_memberships(self : Cloud) -> Array[Json] {
  self.memberships().filter(m => get(m, "rig") is Some(_))
}

///|
fn Cloud::joined_membership(self : Cloud, j : Json, home : String) -> Json? {
  let ws = text_at(j, "workspace").unwrap_or("")
  if ws == home || self.left_out(ws) is Some(_) {
    return None
  }
  let peers = array_at(j, "peers").unwrap_or([])
  let peers = match self.roster_of(ws=Some(ws)) {
    None => peers
    Some(own) =>
      peers.filter(p => match (own.state, get(p, "id")) {
        (Some(s), Some(String(id))) => s.stations.contains(id)
        _ => false
      })
  }
  guard j is Object(m) else { return None }
  let out = m.copy()
  out["peers"] = jarr(peers)
  out["home"] = Json::boolean(false)
  Some(Json::object(out))
}

///|
/// Every workspace the station is in now, its home one first (state.ts `memberships`).
pub fn Cloud::memberships(self : Cloud) -> Array[Json] {
  guard self.state is Some(s) && truthy(s.get("workspace")) && !self.removed() else { return [] }
  let out = [home_membership(s)]
  for j in s.joined() {
    if self.joined_membership(j, s.text("workspace")) is Some(m) {
      out.push(m)
    }
  }
  out
}

///|
/// Why a workspace this station joined is none it takes members of now (state.ts `leftOut`).
pub fn Cloud::left_out(self : Cloud, ws : String) -> String? {
  guard self.state is Some(s) && truthy(s.get("workspace")) && !self.removed() && ws != s.text("workspace") else {
    return None
  }
  guard s.joined().search_by(x => text_at(x, "workspace") == Some(ws)) is Some(i) else { return None }
  let j = s.joined()[i]
  if self.locked(ws=Some(ws)) is Some(_) {
    return None
  }
  if self.pending_lock(ws) is Some(_) {
    return Some("pending")
  }
  if get(j, "locked") is Some(True) && self.chain(ws=Some(ws)) is None {
    return Some("unpinned")
  }
  let any_locked = self.locked() is Some(_) ||
    s.joined().iter().any(x => text_at(x, "workspace") != Some(ws) && self.locked(ws=text_at(x, "workspace")) is Some(_))
  if any_locked {
    Some("home")
  } else {
    None
  }
}

///|
fn named_rigs(s : CloudState, workspace : String) -> Array[Json] {
  if workspace == s.text("workspace") {
    return s.array("rigs")
  }
  match s.joined().search_by(j => text_at(j, "workspace") == Some(workspace)) {
    Some(i) => array_at(s.joined()[i], "rigs").unwrap_or([])
    None => []
  }
}

///|
/// The rigs of `workspace` this station sends work to (state.ts `rigs`).
pub fn Cloud::rigs(self : Cloud, workspace : String) -> Array[Json] {
  guard self.state is Some(s) && self.rig_in(workspace) is None && self.membership(workspace) is Some(_) else { return [] }
  let me = s.text("station")
  let mine = named_rigs(s, workspace).filter(r => text_at(r, "id") != Some(me))
  if self.locked(ws=Some(workspace)) is None {
    mine
  } else {
    mine.filter(r => (self.rig_vouched)(workspace, r))
  }
}

///|
/// The rigs of `workspace` as the control plane names them, signed for or not (state.ts `rigsNamed`).
pub fn Cloud::rigs_named(self : Cloud, workspace : String) -> Array[Json] {
  guard self.state is Some(s) && self.rig_in(workspace) is None && self.membership(workspace) is Some(_) else { return [] }
  let me = s.text("station")
  named_rigs(s, workspace).filter(r => text_at(r, "id") != Some(me))
}

///|
/// The workspace `id` is a rig of, of those this station is in (state.ts `rigOf`).
pub fn Cloud::rig_of(self : Cloud, id : String, workspace? : String? = None) -> (String, Json)? {
  for m in self.full_memberships() {
    let ws = text_at(m, "workspace").unwrap_or("")
    if workspace is Some(w) && w != ws {
      continue
    }
    match self.rigs(ws).search_by(r => text_at(r, "id") == Some(id)) {
      Some(i) => return Some((ws, self.rigs(ws)[i]))
      None => ()
    }
  }
  None
}

///|
/// The station in `workspace`, if it is in it now (state.ts `membership`).
pub fn Cloud::membership(self : Cloud, workspace : String) -> Json? {
  guard self.state is Some(s) && truthy(s.get("workspace")) && !self.removed() else { return None }
  if workspace == s.text("workspace") {
    return Some(home_membership(s))
  }
  match s.joined().search_by(j => text_at(j, "workspace") == Some(workspace)) {
    Some(i) => self.joined_membership(s.joined()[i], s.text("workspace"))
    None => None
  }
}

///|
/// A workspace's own relays and ways turned off as the control plane kept them (state.ts `waysSaid`).
pub fn Cloud::ways_said(self : Cloud, workspace : String) -> Json? {
  guard self.state is Some(s) else { return None }
  if workspace == s.text("workspace") {
    return s.get("ways")
  }
  match s.joined().search_by(j => text_at(j, "workspace") == Some(workspace)) {
    Some(i) => get(s.joined()[i], "ways")
    None => None
  }
}

///|
/// Whether `URL.canParse(u)` would say yes: an absolute URL, its scheme first.
fn can_parse_url(u : String) -> Bool {
  guard u.find(":") is Some(i) && i > 0 else { return false }
  let scheme = u.unsafe_substring(start=0, end=i)
  let first = scheme.unsafe_charcode_at(0)
  if !((first >= 0x41 && first <= 0x5a) || (first >= 0x61 && first <= 0x7a)) {
    return false
  }
  for c in scheme {
    if !(c.is_ascii_alphabetic() || c.is_ascii_digit() || c == '+' || c == '-' || c == '.') {
      return false
    }
  }
  let rest = u.unsafe_substring(start=i + 1, end=u.length())
  let special = ["http", "https", "ws", "wss", "ftp", "file"].contains(scheme.to_lower())
  if special && scheme.to_lower() != "file" {
    let host = rest.trim_start(chars="/").to_string()
    return host != "" && !host.has_prefix("?") && !host.has_prefix("#")
  }
  true
}

///|
/// still.fail's relays, ours first (state.ts `relays`).
pub fn Cloud::relays(self : Cloud) -> Array[String] {
  guard self.state is Some(s) else { return [] }
  let urls = s.array("relay_urls")
  let all = if urls.length() > 0 { urls } else { [s.get("relay_url").unwrap_or(Json::null())] }
  all.filter_map(u => match u {
    String(x) if can_parse_url(x) => Some(x)
    _ => None
  })
}

///|
/// The roster said last is no longer the socket's (state.ts `lapsed`).
pub fn Cloud::lapsed(self : Cloud) -> Unit {
  let current = !self.removed() && self.peers_current
  if !self.reached && current == self.peers_current {
    return
  }
  self.reached = false
  self.peers_current = current
  self.tell()
}

///|
/// A rig of a workspace signed for here: those who follow the rigs told (state.ts `rigsChanged`).
pub fn Cloud::rigs_changed(self : Cloud) -> Unit {
  self.tell()
}

///|
/// A lock to pin named on this machine since it started: those who follow the state told, so the control plane is
/// asked for it at once (state.ts `lockNamed`).
pub fn Cloud::lock_named(self : Cloud) -> Unit {
  self.tell()
}

///|
/// The plane brought `ws`'s chain, moved: kept as offered and those who follow the state told (state.ts `offerMoved`).
pub fn Cloud::offer_moved(self : Cloud, ws : String, entries : Array[Json]) -> Unit {
  self.moved_offered[ws] = entries
  self.tell()
}

///|
pub fn Cloud::listen(self : Cloud, f : (CloudState?) -> Unit) -> () -> Unit {
  self.next += 1
  let id = self.next
  self.listeners.push((id, f))
  () => self.listeners.retain(x => x.0 != id)
}

///|
fn Cloud::tell(self : Cloud) -> Unit {
  for f in self.listeners.copy() {
    (f.1)(self.state)
  }
}

///|
/// Which of a locked workspace's rigs its person signed for (rigs/adds.ts sets it).
pub fn Cloud::set_rig_vouched(self : Cloud, f : (String, Json) -> Bool) -> Unit {
  self.rig_vouched = f
}

///|
/// The disk this Cloud keeps its files on.
pub fn Cloud::disk(self : Cloud) -> Disk {
  self.disk
}
