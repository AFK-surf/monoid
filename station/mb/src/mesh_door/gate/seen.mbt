// The members' devices that came to this station with a credential, by workspace (station/src/mesh/seen-devices.ts):
// kept, those of the last SEEN_SECS, SEEN_MOST at most, written by what the program is given whenever they change.

///|
pub let seen_secs : Int64 = 31L * 86400L

///|
let again_secs : Int64 = 3600L

///|
pub let seen_most : Int = 4096

///|
pub(all) struct Seen {
  workspace : String
  sub : String
  email : String
  role : String?
  device : String
  base : String?
  kind : String?
  label : String?
  first_seen : Int64
  last_seen : Int64
}

///|
pub fn Seen::to_json(self : Seen) -> Json {
  let opt = (v : String?) => match v { Some(s) => Json::string(s); None => Json::null() }
  let m : Map[String, Json] = {
    "workspace": Json::string(self.workspace),
    "sub": Json::string(self.sub),
    "email": Json::string(self.email),
    "device": Json::string(self.device),
    "base": opt(self.base),
    "kind": opt(self.kind),
    "label": opt(self.label),
    "first_seen": Json::number(self.first_seen.to_double()),
    "last_seen": Json::number(self.last_seen.to_double()),
  }
  match self.role {
    Some(r) if r != "" => m["role"] = Json::string(r)
    _ => ()
  }
  Json::object(m)
}

///|
pub fn Seen::from_json(j : Json) -> Seen? {
  guard j is { "device": String(device), "sub": String(sub), "workspace": String(workspace), .. } else { return None }
  let s = (k : String) => match j { Object(m) => match m.get(k) { Some(String(v)) => Some(v); _ => None }; _ => None }
  let n = (k : String) => match j { Object(m) => match m.get(k) { Some(Number(v, ..)) => v.to_int64(); _ => 0L }; _ => 0L }
  Some({
    workspace,
    sub,
    email: s("email").unwrap_or(""),
    role: s("role"),
    device,
    base: s("base"),
    kind: s("kind"),
    label: s("label"),
    first_seen: n("first_seen"),
    last_seen: n("last_seen"),
  })
}

///|
pub struct SeenDevices {
  rows : Map[String, Seen]
  /// Where what is kept goes as it changes (a file the program writes off its thread).
  write : (String) -> Unit
}

///|
fn seen_key(workspace : String, sub : String, device : String) -> String {
  "\{workspace}\u{0}\{sub}\u{0}\{device}"
}

///|
/// What was kept (`kept`, the file's text, None: nothing), written by `write` from now on.
pub fn SeenDevices::new(kept : String?, write : (String) -> Unit) -> SeenDevices {
  let rows = Map([])
  if kept is Some(text) {
    match (try { @json.parse(text) } catch { _ => Json::null() }) {
      Array(a) =>
        for r in a {
          if Seen::from_json(r) is Some(s) {
            rows[seen_key(s.workspace, s.sub, s.device)] = s
          }
        }
      _ => ()
    }
  }
  { rows, write }
}

///|
/// The first `n` UTF-16 units of `s`, as `slice(0, n)`.
fn first_units(s : String, n : Int) -> String {
  if s.length() <= n {
    s
  } else {
    s.clamped_view(end=n).to_owned()
  }
}

///|
/// A device came with a credential (`at`: unix seconds): kept, or its last use moved on. `said`: what it says of itself
/// in its hello (its lock proof's `kind` and `label`), its base key from its lock proof.
pub fn SeenDevices::saw(
  self : SeenDevices,
  at : Int64,
  workspace : String,
  sub : String,
  email : String,
  device : String,
  base : String?,
  said : Json,
  role? : String,
) -> Unit {
  let kind = match said { { "kind": String(k), .. } if k == "app" || k == "web" => Some(k); _ => None }
  let label = match said { { "label": String(l), .. } => Some(first_units(l, 120)); _ => None }
  let k = seen_key(workspace, sub, device)
  let was = self.rows.get(k)
  let next_role = match role {
    Some(r) if r != "" => Some(r)
    _ => was.bind(w => w.role)
  }
  let next : Seen = {
    workspace,
    sub,
    email,
    role: next_role,
    device,
    base: either(base, was.bind(w => w.base)),
    kind: either(kind, was.bind(w => w.kind)),
    label: either(label, was.bind(w => w.label)),
    first_seen: was.map(w => w.first_seen).unwrap_or(at),
    last_seen: at,
  }
  if was is Some(w) &&
    at - w.last_seen < again_secs &&
    w.base == next.base &&
    w.kind == next.kind &&
    w.label == next.label &&
    w.email == next.email &&
    w.role == next.role {
    return
  }
  self.rows.remove(k)
  self.rows[k] = next
  let gone = []
  for key, r in self.rows {
    if r.last_seen < at - seen_secs {
      gone.push(key)
    }
  }
  for key in gone {
    self.rows.remove(key)
  }
  let over = self.rows.length() - seen_most
  if over > 0 {
    let oldest = []
    for key, _ in self.rows {
      if oldest.length() >= over {
        break
      }
      oldest.push(key)
    }
    for key in oldest {
      self.rows.remove(key)
    }
  }
  (self.write)(self.all_json().stringify())
}

///|
pub fn SeenDevices::all_json(self : SeenDevices) -> Json {
  let out = []
  for _, r in self.rows {
    out.push(r.to_json())
  }
  Json::array(out)
}

///|
/// Those of workspace `ws` seen in the last SEEN_SECS before `at`: everyone's for its owners and admins (`manages`),
/// else `sub`'s own; each person's latest first.
pub fn SeenDevices::of(self : SeenDevices, ws : String, at : Int64, sub : String, manages : Bool) -> Array[Seen] {
  let picked = []
  for _, r in self.rows {
    if r.workspace == ws && r.last_seen >= at - seen_secs && (manages || r.sub == sub) {
      picked.push(r)
    }
  }
  let fixed = FixedArray::from_array(picked)
  fixed.stable_sort_by((a, b) => match js_compare(a.sub, b.sub) {
    0 => (b.last_seen - a.last_seen).to_int()
    c => c
  })
  fixed.iter().collect()
}

///|
fn[T] either(a : T?, b : T?) -> T? {
  match a {
    Some(_) => a
    None => b
  }
}

///|
/// JavaScript's order of two strings: by their UTF-16 code units, one at a time (MoonBit's own goes by length first).
pub fn js_compare(a : String, b : String) -> Int {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    let x = a.code_unit_at(i)
    let y = b.code_unit_at(i)
    if x != y {
      return if x < y { -1 } else { 1 }
    }
  }
  a.length() - b.length()
}
