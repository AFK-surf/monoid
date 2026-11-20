// What the station holds of the secrets agents use (station/src/vault/keeper.ts, keeper): for each request still waiting,
// the private half of the box its secret is to be sealed to; for each grant, the opened secret, until it is used up, runs
// out or its chat is archived. Only in memory: nothing here is written to disk or logged, and a handover carries it to
// the next process (`carried`, `carry`). Whether a grant may be taken is decided here, from the grant itself: who
// signed it (a member of the vault, by a device in the lock), that it answers the request as asked, and that it stays
// within what the item allows. The same answers and words as keeper.ts.

///|
/// The longest a grant may last by its scope (seconds), with a minute's slack for the clocks of phone and station.
fn lasts_of(scope : String) -> Double? {
  match scope {
    "once" | "hour" => Some(3600.0)
    "chat" => Some(30.0 * 86400.0)
    _ => None
  }
}

///|
let slack : Double = 60.0

///|
/// A grant held: the request as granted, the grant, its secret opened (`{kind, name, fields}`), how often it was used
/// and, for one that lasts while it is used (idle), until when.
pub(all) struct Held {
  mut request : Json
  mut grant : Json
  mut secret : Json
  mut uses : Double
  mut until : Double?
}

///|
/// A held grant as keeper.ts writes it (`carried`, what `kept` saves).
pub fn Held::to_json(self : Held) -> Json {
  let m : Map[String, Json] = {
    "request": self.request,
    "grant": self.grant,
    "secret": self.secret,
    "uses": Json::number(self.uses),
  }
  if self.until is Some(u) {
    m["until"] = Json::number(u)
  }
  Json::object(m)
}

///|
/// A held grant from its JSON (a handover's, or one kept across a restart); None for what is not one.
pub fn Held::from_json(j : Json) -> Held? {
  guard j is Object(o) else { return None }
  guard o.get("request") is Some(request) && o.get("grant") is Some(grant) else { return None }
  Some({
    request,
    grant,
    secret: o.get("secret").unwrap_or(Json::null()),
    uses: match o.get("uses") {
      Some(Number(n, ..)) => n
      _ => 0.0
    },
    until: match o.get("until") {
      Some(Number(n, ..)) => Some(n)
      _ => None
    },
  })
}

///|
/// What a durable store answers of a grant's record now (keeper.ts `kept.current`): gone (removed or replaced by
/// another connection), as it is, or nothing known.
pub(all) enum Current {
  Gone
  Is(Double, Double?)
  Unknown
}

///|
/// What a durable store answers to an idle grant's renewal (`kept.renew`): refused, renewed until then, or nothing known.
pub(all) enum Renewed {
  NotRenewed
  RenewedTo(Double)
  RenewUnknown
}

///|
/// Where grants are kept across restarts (keeper.ts `KeeperDeps.kept`): each grant taken or used saved, each gone
/// forgotten, and the conditional writes another station's use can race with.
pub(all) struct Kept {
  save : (Held) -> Unit
  forget : (Held) -> Unit
  spend_once : (Held) -> Bool?
  spend_again : (Held) -> Bool?
  renew : (Held, Double) -> Renewed
  current : (Held) -> Current
  expire : (Held, Double) -> Bool?
}

///|
/// What a keeper is told of: whether a session's chat is over, and where its grants are kept (None: nowhere).
pub(all) struct KeeperDeps {
  ended : (String) -> Bool
  kept : Kept?
}

///|
pub fn KeeperDeps::none() -> KeeperDeps {
  { ended: _ => false, kept: None }
}

///|
/// The secrets held in memory: `now` in unix seconds, `after(ms, f)` a timer (its result calls it off).
pub struct Keeper {
  priv c : Crypto
  priv now : () -> Double
  priv after : (Double, () -> Unit) -> () -> Unit
  priv d : KeeperDeps
  priv boxes : Map[String, Bytes]
  priv held : Map[String, Held]
  priv held_by_session : Map[String, Map[String, Unit]]
  priv held_order : Map[String, Int]
  priv mut next_order : Int
  priv timers : Map[String, () -> Unit]
}

///|
pub fn Keeper::new(c : Crypto, now : () -> Double, after : (Double, () -> Unit) -> () -> Unit, d? : KeeperDeps = KeeperDeps::none()) -> Keeper {
  {
    c,
    now,
    after,
    d,
    boxes: Map([]),
    held: Map([]),
    held_by_session: Map([]),
    held_order: Map([]),
    next_order: 0,
    timers: Map([]),
  }
}

// ── JSON as JS reads it ───────────────────────────────────────────────────────────────────────────────────────────

///|
fn get(v : Json?, k : String) -> Json? {
  match v {
    Some(Object(m)) => m.get(k)
    _ => None
  }
}

///|
fn str(v : Json?) -> String? {
  match v {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
/// `a === b` of two values read off records (objects and arrays are never the same here).
fn same(a : Json?, b : Json?) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(Null), Some(Null)) => true
    (Some(True), Some(True)) => true
    (Some(False), Some(False)) => true
    (Some(Number(x, ..)), Some(Number(y, ..))) => x == y
    (Some(String(x)), Some(String(y))) => x == y
    _ => false
  }
}

///|
/// Whether a value is truthy as JS has it.
fn truthy(v : Json?) -> Bool {
  @jsjson.json_truthy(v)
}

///|
/// `Number.isSafeInteger(v)`.
fn safe_int(v : Json?) -> Bool {
  v is Some(Number(n, ..)) && @jsjson.is_safe_integer(n)
}

///|
fn number(v : Json?) -> Double? {
  match v {
    Some(Number(n, ..)) => Some(n)
    _ => None
  }
}

///|
/// JS's `String(v)`, as a template says a value.
pub fn js_string(v : Json?) -> String {
  @jsjson.json_js_str(v)
}

///|
/// `xs.includes(x)` of an array read off a record.
fn includes(xs : Json?, x : Json?) -> Bool {
  match xs {
    Some(Array(a)) => a.iter().any(y => same(Some(y), x))
    _ => false
  }
}

///|
/// The record with `k` set to `v` (in its place where it is there, as a spread with it after would).
fn with_field(o : Json, k : String, v : Json) -> Json {
  let m : Map[String, Json] = Map([])
  if o is Object(src) {
    for kk, vv in src {
      m[kk] = vv
    }
  }
  m[k] = v
  Json::object(m)
}

///|
fn lower_host(host : String) -> String {
  let b = StringBuilder()
  for i in 0..<host.length() {
    let c = host.code_unit_at(i).to_int()
    // (the Kelvin sign is the one character outside ASCII that JS lowers into it)
    let l = if c >= 65 && c <= 90 { c + 32 } else if c == 0x212a { 107 } else { c }
    b.write_char(l.unsafe_to_char())
  }
  let s = b.to_string()
  if s.has_suffix(".") {
    s.unsafe_substring(start=0, end=s.length() - 1)
  } else {
    s
  }
}

///|
/// Whether `host` is one of `patterns`: the same name, or under a `*.` pattern's domain (not the domain itself).
pub fn host_allowed(host : String, patterns : Array[String]) -> Bool {
  let h = lower_host(host)
  patterns.iter().any(p => if p.has_prefix("*.") {
    let tail = p.unsafe_substring(start=1, end=p.length())
    h.has_suffix(tail) && h.length() > p.length() - 1
  } else {
    h == p
  })
}

///|
fn string_array(v : Json?) -> Array[String] {
  let out : Array[String] = []
  if v is Some(Array(xs)) {
    for x in xs {
      if x is String(s) {
        out.push(s)
      }
    }
  }
  out
}

///|
/// The value a grant's secret is used as: a token's value, a login's password, an SSH key's private key, a file's
/// content (its bytes in base64), a sign-in's cookies.
pub fn value_of(secret : Json) -> String? {
  let f = get(Some(secret), "fields")
  let kind = get(Some(secret), "kind")
  let name = match kind {
    Some(String("ssh_key")) => "private_key"
    Some(String("login")) => "password"
    Some(String("file")) => "content"
    Some(String("browser")) => "cookies"
    _ => "value"
  }
  match get(f, name) {
    Some(String(v)) if v != "" => Some(v)
    _ => None
  }
}

///|
/// A login's account (not secret: its card shows it), given to commands beside the password; None for any other kind.
pub fn account_of(secret : Json) -> String? {
  guard get(Some(secret), "kind") is Some(String("login")) else { return None }
  match get(get(Some(secret), "fields"), "username") {
    Some(String(u)) if u != "" => Some(u)
    _ => None
  }
}

// ── the keeper ───────────────────────────────────────────────────────────────────────────────────────────────────

///|
fn exp_of(h : Held) -> Double {
  match get(Some(h.grant), "exp") {
    Some(Number(n, ..)) => n
    _ => @double.not_a_number
  }
}

///|
fn deadline(h : Held) -> Double {
  match h.until {
    Some(u) => u
    None => exp_of(h)
  }
}

///|
fn request_id(h : Held) -> String {
  str(get(Some(h.request), "id")).unwrap_or("undefined")
}

///|
fn session_of(h : Held) -> String {
  str(get(Some(h.request), "session")).unwrap_or("undefined")
}

///|
fn scope_of(h : Held) -> Json? {
  get(Some(h.grant), "scope")
}

///|
fn is_once(h : Held) -> Bool {
  scope_of(h) is Some(String("once"))
}

///|
fn Keeper::save(self : Keeper, h : Held) -> Unit {
  if self.d.kept is Some(k) {
    (k.save)(h)
  }
}

///|
fn Keeper::hold_(self : Keeper, h : Held) -> Unit {
  self.put(h)
  self.schedule(h)
  self.save(h)
}

///|
/// A replacement keeps its place among those held, including when it moves to another session.
fn Keeper::put(self : Keeper, h : Held) -> Unit {
  let id = request_id(h)
  let previous = self.held.get(id)
  let session = session_of(h)
  if previous is None {
    self.held_order[id] = self.next_order
    self.next_order += 1
  }
  self.held[id] = h
  if previous is Some(p) && session_of(p) == session {
    return
  }
  if previous is Some(p) {
    self.remove_from_session(session_of(p), id)
  }
  match self.held_by_session.get(session) {
    None => self.held_by_session[session] = Map([(id, ())])
    Some(ids) =>
      if previous is None {
        ids[id] = ()
      } else {
        let order = self.held_order.get(id).unwrap_or(0)
        let sorted : Map[String, Unit] = Map([])
        let mut inserted = false
        for other, _ in ids {
          if !inserted && self.held_order.get(other).unwrap_or(0) > order {
            sorted[id] = ()
            inserted = true
          }
          sorted[other] = ()
        }
        if !inserted {
          sorted[id] = ()
        }
        self.held_by_session[session] = sorted
      }
  }
}

///|
fn Keeper::remove_from_session(self : Keeper, session : String, id : String) -> Unit {
  guard self.held_by_session.get(session) is Some(ids) else { return }
  ids.remove(id)
  if ids.is_empty() {
    self.held_by_session.remove(session)
  }
}

///|
fn Keeper::schedule(self : Keeper, h : Held, delay? : Double) -> Unit {
  let id = request_id(h)
  if self.timers.get(id) is Some(old) {
    old()
  }
  let ms = match delay {
    Some(d) => d
    None => {
      let left = (deadline(h) - (self.now)()) * 1000.0
      if left > 0.0 {
        left
      } else {
        0.0
      }
    }
  }
  let timer = (self.after)(ms, () => {
    guard self.held.get(id) is Some(current) else { return }
    if !self.refresh(current) {
      return
    }
    if deadline(current) <= (self.now)() {
      ignore(self.expire(current))
    } else {
      self.schedule(current)
    }
  })
  self.timers[id] = timer
}

///|
fn Keeper::forget(self : Keeper, id : String, persisted? : Bool = true) -> Unit {
  if self.timers.get(id) is Some(t) {
    t()
  }
  self.timers.remove(id)
  if self.held.get(id) is Some(h) {
    self.held.remove(id)
    self.remove_from_session(session_of(h), id)
    self.held_order.remove(id)
    if persisted && self.d.kept is Some(k) {
      (k.forget)(h)
    }
  }
}

///|
fn Keeper::refresh(self : Keeper, h : Held) -> Bool {
  let current = match self.d.kept {
    Some(k) => (k.current)(h)
    None => Unknown
  }
  match current {
    Gone => {
      // Another connection removed or replaced the durable grant: its newer record is not deleted.
      self.forget(request_id(h), persisted=false)
      false
    }
    Is(uses, until) => {
      if uses > h.uses {
        h.uses = uses
      }
      let previous = h.until
      h.until = until
      if h.until != previous {
        self.schedule(h)
      }
      true
    }
    Unknown => true
  }
}

///|
/// Expires only the version that is still due: another station may have renewed it after the last read.
fn Keeper::expire(self : Keeper, h : Held) -> Bool {
  let id = request_id(h)
  for _ in 0..<3 {
    let removed = match self.d.kept {
      Some(k) => (k.expire)(h, (self.now)())
      None => None
    }
    match removed {
      None => {
        self.forget(id)
        return true
      }
      Some(true) => {
        self.forget(id, persisted=false)
        return true
      }
      Some(false) => {
        if !self.refresh(h) {
          return true
        }
        if deadline(h) > (self.now)() {
          self.schedule(h)
          return false
        }
      }
    }
  }
  // the row kept, tried again later, where another writer keeps changing it
  self.schedule(h, delay=250.0)
  true
}

///|
/// A box for request `id`'s secret: its public half, to be sealed to; the private half stays here.
pub fn Keeper::open(self : Keeper, id : String) -> String raise Refused {
  let (pub_, sk) = new_box_pair(self.c)
  self.boxes[id] = sk
  pub_
}

///|
/// A grant checked and opened, not yet taken (`prepare_accept`): `take` takes it, or says why it no longer may.
pub(all) enum Prepared {
  Refusal(String)
  Ready(() -> String?)
}

///|
fn timeout_bad(t : Json?, scope : String) -> Bool {
  match t {
    Some(Object(_)) => {
      let kind = get(t, "kind")
      let seconds = get(t, "seconds")
      !(kind is Some(String("idle")) || kind is Some(String("fixed"))) ||
      !safe_int(seconds) ||
      number(seconds).unwrap() < 1.0 ||
      number(seconds).unwrap() > lasts_of(scope).unwrap_or(0.0) ||
      scope == "once"
    }
    _ => true
  }
}

///|
/// Checks and opens a grant without changing the keeper; what it returns takes it once, provided the box is still
/// this request's and the grant has not expired.
pub fn Keeper::prepare_accept(self : Keeper, lock : @vault.LockView, vault : Json, item : Json, request : Json, grant : Json) -> Prepared {
  let g = Some(grant)
  let r = Some(request)
  guard grant is Object(_) && get(g, "v") is Some(Number(1.0, ..)) else { return Refusal("a grant is {v: 1, …}") }
  guard get(r, "status") is Some(String("pending")) else {
    return Refusal("the request is \{js_string(get(r, "status"))}")
  }
  if !same(get(g, "ws"), get(r, "ws")) || !same(get(g, "request"), get(r, "id")) || !same(get(g, "vault"), get(r, "vault")) ||
    !same(get(g, "item"), get(r, "item")) || !same(get(g, "mode"), get(r, "mode")) {
    return Refusal("the grant is not for this request as asked")
  }
  let listing = get(Some(item), "listing")
  if !same(get(Some(vault), "id"), get(r, "vault")) || !same(get(Some(item), "id"), get(r, "item")) ||
    truthy(get(Some(item), "deleted")) || listing is None {
    return Refusal("the item is not one agents may ask for")
  }
  if !includes(get(listing, "modes"), get(g, "mode")) {
    return Refusal("the item is not given by \{js_string(get(g, "mode"))}")
  }
  guard get(g, "scope") is Some(String(scope)) && lasts_of(scope) is Some(longest) else {
    return Refusal("scope is once, hour or chat")
  }
  if truthy(get(r, "timeout")) && scope != "once" && get(g, "timeout") is None {
    return Refusal("this request needs an approval with its timeout; update the app")
  }
  let t = get(g, "timeout")
  if t is Some(_) {
    if timeout_bad(t, scope) || !safe_int(get(g, "at")) ||
      !same(get(g, "exp"), Some(Json::number(number(get(g, "at")).unwrap() + number(get(t, "seconds")).unwrap()))) {
      return Refusal("invalid grant timeout")
    }
  }
  let lasts = match get(listing, "lasts") {
    None | Some(Null) => get(Some(vault), "lasts")
    l => l
  }
  if !allows(lasts, get(g, "scope")) {
    return Refusal("the item is granted for \{js_string(lasts)} at most")
  }
  let now = (self.now)()
  if !safe_int(get(g, "exp")) || number(get(g, "exp")).unwrap() <= now || number(get(g, "exp")).unwrap() > now + longest + slack {
    return Refusal("the grant's expiry is out of range for its scope")
  }
  let item_hosts = get(listing, "hosts")
  let hosts_ok = match get(g, "hosts") {
    Some(Array(hs)) =>
      hs.iter().all(h => match h {
        String(s) => includes(item_hosts, Some(h)) || (!s.has_prefix("*.") && host_allowed(s, string_array(item_hosts)))
        _ => false
      })
    _ => false
  }
  if !hosts_ok {
    return Refusal("the grant's hosts are not all the item's")
  }
  let no_hosts = get(g, "hosts") is Some(Array(hs)) && hs.is_empty()
  if get(g, "mode") is Some(String("proxy")) && no_hosts {
    return Refusal("a grant through the proxy names its hosts")
  }
  if get(g, "mode") is Some(String("browser")) && no_hosts {
    return Refusal("a sign-in's grant names its sites (an app from before sign-ins sends none: update it)")
  }
  let by = match get(get(g, "sig"), "key") {
    Some(String(key)) => signer_of(lock, key)
    _ => None
  }
  guard by is Some((sub, _)) && includes(get(Some(vault), "members"), Some(Json::string(sub))) else {
    return Refusal("a grant is signed by a vault member's device in the lock")
  }
  if !signed_ok(self.c, grant, tag_grant) {
    return Refusal("the grant's signature is invalid")
  }
  let id = str(get(r, "id")).unwrap_or("undefined")
  guard self.boxes.get(id) is Some(box) else {
    return Refusal("this station no longer holds the request's box (it restarted): ask again")
  }
  let secret = try {
    guard get(g, "secret") is Some(String(boxed)) else { raise Refused("no seal") }
    let ws = js_string(get(r, "ws"))
    parse_js(text_of_bytes(open_seal(self.c, box, boxed, grant_context(ws, id))))
  } catch {
    _ => return Refusal("the grant's secret does not open")
  }
  if !(secret is Object(_) || secret is Array(_)) || value_of(secret) is None {
    return Refusal("the grant's secret has no value to use")
  }
  Ready(() => {
    match self.boxes.get(id) {
      Some(b) if physical_equal(b, box) => ()
      _ => return Some("this station no longer holds the request's box (it restarted): ask again")
    }
    if number(get(g, "exp")).unwrap() <= (self.now)() {
      return Some("the grant's expiry is out of range for its scope")
    }
    self.boxes.remove(id)
    self.hold_({ request: with_field(request, "status", Json::string("granted")), grant, secret, uses: 0.0, until: None })
    None
  })
}

///|
/// Takes `grant` for `request` (of `item` in `vault`, as the lock has it now); why not, or None when taken.
pub fn Keeper::accept(self : Keeper, lock : @vault.LockView, vault : Json, item : Json, request : Json, grant : Json) -> String? {
  match self.prepare_accept(lock, vault, item, request, grant) {
    Refusal(why) => Some(why)
    Ready(take) => take()
  }
}

///|
/// Holds an item of the plain library for `request`, as its owner decided: no seal and no signature, the secret read
/// from the station's own store; the same limits as a grant's otherwise. `d`: `{scope, hosts, listing: {modes, hosts},
/// lasts, timeout?}`.
pub fn Keeper::hold(self : Keeper, request : Json, d : Json, secret : Json) -> String? {
  let r = Some(request)
  let d_ = Some(d)
  guard get(r, "status") is Some(String("pending")) else {
    return Some("the request is \{js_string(get(r, "status"))}")
  }
  let scope = js_string(get(d_, "scope"))
  guard lasts_of(scope) is Some(longest) else { return Some("scope is once, hour or chat") }
  let timeout = get(d_, "timeout")
  if truthy(get(r, "timeout")) && scope != "once" && timeout is None {
    return Some("this request needs an approval with its timeout; update the app")
  }
  if !allows(get(d_, "lasts"), get(d_, "scope")) {
    return Some("the item is granted for \{js_string(get(d_, "lasts"))} at most")
  }
  if timeout is Some(_) && timeout_bad(timeout, scope) {
    return Some("invalid grant timeout")
  }
  let listing = get(d_, "listing")
  if !includes(get(listing, "modes"), get(r, "mode")) {
    return Some("the item is not given by \{js_string(get(r, "mode"))}")
  }
  let item_hosts = get(listing, "hosts")
  let hosts = match get(d_, "hosts") {
    Some(Array(hs)) => hs
    _ => []
  }
  if !hosts.iter().all(h => match h {
      String(s) => includes(item_hosts, Some(h)) || (!s.has_prefix("*.") && host_allowed(s, string_array(item_hosts)))
      _ => includes(item_hosts, Some(h))
    }) {
    return Some("the hosts are not all the item's")
  }
  if get(r, "mode") is Some(String("proxy")) && hosts.is_empty() {
    return Some("given through the proxy, it names its hosts")
  }
  if get(r, "mode") is Some(String("browser")) && hosts.is_empty() {
    return Some("a sign-in's grant names its sites")
  }
  if value_of(secret) is None {
    return Some("the item has no value to use")
  }
  let now = (self.now)()
  let seconds = match number(get(timeout, "seconds")) {
    Some(s) => s
    None => longest
  }
  let g : Map[String, Json] = { "v": Json::number(1.0) }
  let put = fn(k : String, v : Json?) {
    if v is Some(v) {
      g[k] = v
    }
  }
  put("ws", get(r, "ws"))
  put("request", get(r, "id"))
  put("vault", get(r, "vault"))
  put("item", get(r, "item"))
  put("mode", get(r, "mode"))
  put("hosts", get(d_, "hosts"))
  put("scope", get(d_, "scope"))
  g["exp"] = Json::number(now + seconds)
  if truthy(timeout) {
    put("timeout", timeout)
  }
  g["secret"] = Json::string("")
  g["at"] = Json::number(now)
  self.hold_({ request: with_field(request, "status", Json::string("granted")), grant: Json::object(g), secret, uses: 0.0, until: None })
  None
}

///|
/// Restores this request's box and grant as they were if `run` fails (the database transaction around it rolled back,
/// and with it what `kept` wrote, so nothing is written again here).
pub fn[T] Keeper::rollback_on_error(self : Keeper, id : String, run : () -> T raise) -> T raise {
  let box = self.boxes.get(id)
  let held = self.held.get(id)
  let order = self.held_order.get(id)
  try run() catch {
    error => {
      let same_box = match (self.boxes.get(id), box) {
        (None, None) => true
        (Some(a), Some(b)) => physical_equal(a, b)
        _ => false
      }
      let same_held = match (self.held.get(id), held) {
        (None, None) => true
        (Some(a), Some(b)) => physical_equal(a, b)
        _ => false
      }
      if same_box && same_held {
        raise error
      }
      if self.timers.get(id) is Some(t) {
        t()
      }
      self.timers.remove(id)
      if self.held.get(id) is Some(current) {
        self.held.remove(id)
        self.remove_from_session(session_of(current), id)
        self.held_order.remove(id)
      }
      if held is Some(h) {
        self.held[id] = h
        self.held_order[id] = order.unwrap_or(0)
        let ids : Array[String] = []
        if self.held_by_session.get(session_of(h)) is Some(m) {
          for k, _ in m {
            ids.push(k)
          }
        }
        ids.push(id)
        ids.sort_by((a, b) => self.held_order.get(a).unwrap_or(0).compare(self.held_order.get(b).unwrap_or(0)))
        let set : Map[String, Unit] = Map([])
        for k in ids {
          set[k] = ()
        }
        self.held_by_session[session_of(h)] = set
        self.schedule(h)
      }
      match box {
        None => self.boxes.remove(id)
        Some(b) => self.boxes[id] = b
      }
      raise error
    }
  }
}

///|
/// A grant kept from before a restart, given back.
pub fn Keeper::restore(self : Keeper, h : Held) -> Unit {
  self.put(h)
  self.schedule(h)
}

///|
/// All it holds, for the next process (a handover): `{boxes: [[id, private half in base64]…], held: […]}`.
pub fn Keeper::carried(self : Keeper) -> Json {
  let boxes : Array[Json] = []
  for id, sk in self.boxes {
    boxes.push(Json::array([Json::string(id), Json::string(b64(sk))]))
  }
  let held : Array[Json] = []
  for _, h in self.held {
    held.push(h.to_json())
  }
  Json::object({ "boxes": Json::array(boxes), "held": Json::array(held) })
}

///|
/// What the process before held (`carried`), held here too: what runs out or ends with its chat goes as ever.
pub fn Keeper::carry(self : Keeper, c : Json) -> Unit {
  if get(Some(c), "boxes") is Some(Array(boxes)) {
    for pair in boxes {
      if pair is Array([String(id), String(sk), ..]) && !self.boxes.contains(id) {
        self.boxes[id] = unb64(sk)
      }
    }
  }
  if get(Some(c), "held") is Some(Array(held)) {
    for j in held {
      guard Held::from_json(j) is Some(h) else { continue }
      match self.held.get(request_id(h)) {
        None => self.restore(h)
        Some(current) => {
          let rq = fn(x : Held, k : String) { get(Some(x.request), k) }
          let gr = fn(x : Held, k : String) { get(Some(x.grant), k) }
          if same(rq(current, "ws"), rq(h, "ws")) && same(rq(current, "session"), rq(h, "session")) &&
            same(rq(current, "vault"), rq(h, "vault")) && same(rq(current, "item"), rq(h, "item")) &&
            is_once(current) && is_once(h) && same(gr(current, "mode"), gr(h, "mode")) &&
            same(gr(current, "at"), gr(h, "at")) && same(gr(current, "exp"), gr(h, "exp")) {
            // either process may have used the same one-use grant after the new one read it from disk
            if h.uses > current.uses {
              current.uses = h.uses
            }
          }
        }
      }
    }
  }
}

///|
/// The grant `id` as `session` may use it now; else why not.
pub fn Keeper::usable(self : Keeper, session : String, id : String) -> Result[Held, String] {
  guard self.held.get(id) is Some(h) else {
    return Err("no such grant here: secret_list shows the grants you hold (a restart of the station forgets them; ask again)")
  }
  if session_of(h) != session {
    return Err("this grant is another session's")
  }
  if !self.refresh(h) {
    return Err("this grant was ended or changed: ask again")
  }
  if deadline(h) <= (self.now)() {
    if self.expire(h) {
      return Err("this grant ran out: ask again")
    }
  }
  if (self.d.ended)(session) {
    self.forget(id)
    return Err("this grant ended with its chat (archived): ask again")
  }
  if is_once(h) && h.uses > 0.0 {
    return Err("this grant was for one use and is used: ask again")
  }
  Ok(h)
}

///|
/// Whether a command already admitted may go on using its grant (a one-use one too), but not after it ran out or its
/// chat was archived.
pub fn Keeper::active(self : Keeper, session : String, id : String) -> Bool {
  guard self.held.get(id) is Some(h) && session_of(h) == session else { return false }
  if !self.refresh(h) {
    return false
  }
  if deadline(h) <= (self.now)() && self.expire(h) {
    return false
  }
  if (self.d.ended)(session) {
    self.forget(id)
    return false
  }
  true
}

///|
/// One use of grant `id` begins (a command run with it).
pub fn Keeper::spend(self : Keeper, id : String) -> Bool {
  guard self.held.get(id) is Some(h) else { return false }
  if is_once(h) && h.uses > 0.0 {
    return false
  }
  let previous = h.until
  let saved = match self.d.kept {
    Some(k) => if is_once(h) { (k.spend_once)(h) } else { (k.spend_again)(h) }
    None => None
  }
  // a conditional write can lose to another valid use: the grant is left here for a fresh check
  if saved is Some(false) {
    return false
  }
  h.uses += 1.0
  if !(saved is Some(true)) {
    self.save(h)
  }
  if h.until != previous {
    self.schedule(h)
  }
  true
}

///|
/// A use that went well keeps an idle grant on, provided it has not ended meanwhile.
pub fn Keeper::renew(self : Keeper, session : String, id : String) -> Unit {
  guard self.usable(session, id) is Ok(h) else { return }
  let timeout = get(Some(h.grant), "timeout")
  guard get(timeout, "kind") is Some(String("idle")) else { return }
  let until = (self.now)() + number(get(timeout, "seconds")).unwrap_or(@double.not_a_number)
  let saved = match self.d.kept {
    Some(k) => (k.renew)(h, until)
    None => RenewUnknown
  }
  match saved {
    NotRenewed => return
    RenewedTo(u) => h.until = Some(u)
    RenewUnknown => h.until = Some(until)
  }
  self.schedule(h)
  if saved is RenewUnknown {
    self.save(h)
  }
}

///|
/// A request decided otherwise (denied, expired): its box is dropped.
pub fn Keeper::drop(self : Keeper, id : String) -> Unit {
  self.boxes.remove(id)
  self.forget(id)
}

///|
/// A stale waiting box let go without ending a grant already taken for the request.
pub fn Keeper::discard_box(self : Keeper, id : String) -> Unit {
  self.boxes.remove(id)
}

///|
/// Whether `session` holds a grant here (used up or not).
pub fn Keeper::holds(self : Keeper, session : String) -> Bool {
  self.held_by_session.contains(session)
}

///|
/// Whether a grant was taken or restored for request `id`.
pub fn Keeper::has_grant(self : Keeper, id : String) -> Bool {
  self.held.contains(id)
}

///|
fn Keeper::ids_of(self : Keeper, session : String) -> Array[String] {
  let ids : Array[String] = []
  if self.held_by_session.get(session) is Some(m) {
    for k, _ in m {
      ids.push(k)
    }
  }
  ids
}

///|
/// `session`'s chat archived or gone: its grants end.
pub fn Keeper::end(self : Keeper, session : String) -> Unit {
  for id in self.ids_of(session) {
    self.forget(id)
  }
}

///|
/// The grants `session` holds that may still be used.
pub fn Keeper::held(self : Keeper, session : String) -> Array[Held] {
  let out : Array[Held] = []
  for id in self.ids_of(session) {
    if self.usable(session, id) is Ok(h) {
      out.push(h)
    }
  }
  out
}

///|
/// Whether request `id` still has its box here.
pub fn Keeper::waiting(self : Keeper, id : String) -> Bool {
  self.boxes.contains(id)
}
