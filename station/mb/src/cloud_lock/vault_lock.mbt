// The lock a workspace's vault goes by where the workspace is not in security mode (cloud/vault-lock.ts
// `personalVaultLock`): its members' own locks, the person logs kept here, as one lock with no chain of its own
// (`genesis` ""), as the vault reads a lock (`{ws, genesis, members: {sub: {sub, email, role}}, devices: {id: {id, sub,
// kind, label, sign_key?, own}}, signKeys: {id: [...]}}`). Where a person keeps more than one log here, the one their
// vaults are signed by is theirs, then the one their newest box certificate checks against, then the newest.

///|
priv struct VaultLog {
  genesis : String
  at : Double
  devices : Array[@lock.PersonDevice]
}

///|
fn vault_log_device_json(sub : String, d : @lock.PersonDevice) -> Json {
  let m : Map[String, Json] = {
    "id": jstr(d.id),
    "sub": jstr(sub),
    "kind": jstr("app"),
    "label": jstr(d.label),
    "own": Json::boolean(true),
  }
  match d.sign_key {
    Some(k) => m["sign_key"] = jstr(k)
    None => ()
  }
  Json::object(m)
}

///|
/// The lock of one person's log alone: what a box certificate of theirs is checked by.
fn vault_log_lock(ws : String, sub : String, l : VaultLog) -> Json {
  let devices : Map[String, Json] = Map([])
  let keys : Map[String, Json] = Map([])
  for d in l.devices {
    devices[d.id] = vault_log_device_json(sub, d)
    keys[d.id] = jstrs(d.sign_keys)
  }
  {
    "ws": jstr(ws),
    "genesis": jstr(""),
    "members": Json::object(Map([(sub, jobj([("sub", jstr(sub)), ("email", jstr("")), ("role", jstr("member"))]))])),
    "devices": Json::object(devices),
    "signKeys": Json::object(keys),
  }
}

///|
fn vault_log_chosen(
  ws : String,
  sub : String,
  logs : Array[VaultLog],
  vaults : Array[Json],
  boxes : Array[Json],
  cert_ok : (Json, Json) -> Bool,
) -> VaultLog {
  if logs.length() == 1 {
    return logs[0]
  }
  for v in vaults {
    if text_at(v, "owner") != Some(sub) || get(v, "deleted") is Some(True) {
      continue
    }
    let key = match get(v, "sig") {
      Some(sig) => text_at(sig, "key")
      None => None
    }
    guard key is Some(k) else { continue }
    for l in logs {
      if l.devices.iter().any(d => d.sign_keys.contains(k) || d.sign_key == Some(k)) {
        return l
      }
    }
  }
  let certs = boxes.copy()
  stable_sort(certs, (a, b) => {
    let x = num_at(a, "at").unwrap_or(0.0)
    let y = num_at(b, "at").unwrap_or(0.0)
    if x > y {
      -1
    } else if x < y {
      1
    } else {
      0
    }
  })
  for cert in certs {
    let device = text_at(cert, "device").unwrap_or("")
    for l in logs {
      if l.devices.iter().any(d => d.id == device) && cert_ok(vault_log_lock(ws, sub, l), cert) {
        return l
      }
    }
  }
  let sorted = logs.copy()
  stable_sort(sorted, (a, b) => if a.at < b.at { -1 } else if a.at > b.at { 1 } else { 0 })
  sorted[sorted.length() - 1]
}

///|
/// Workspace `ws`'s vault lock made of its members' own locks: `chains` the person logs kept (by genesis), `emails`
/// who is known to be a member here (by sub), `vaults` and `boxes` the vault's own records of the workspace, `cert_ok`
/// the vault's check of a box certificate against a lock as JSON.
pub fn personal_vault_lock(
  c : Crypto,
  ws : String,
  chains : Array[(String, Array[Json])],
  emails : Map[String, String],
  vaults : Array[Json],
  boxes : Array[Json],
  cert_ok : (Json, Json) -> Bool,
) -> Json {
  let logs : Map[String, Array[VaultLog]] = Map([])
  let order : Array[String] = []
  for p in chains {
    let (genesis, chain) = p
    guard sub_of(chain) is Some(sub) else { continue }
    let person = person_fold(c, chain, sub) catch { _ => continue }
    let at = match chain.last() {
      Some(e) => num_at(e, "at").unwrap_or(0.0)
      None => 0.0
    }
    let devices = person.devices.values().collect()
    match logs.get(sub) {
      Some(a) => a.push({ genesis, at, devices })
      None => {
        logs[sub] = [{ genesis, at, devices }]
        order.push(sub)
      }
    }
  }
  let members : Map[String, Json] = Map([])
  let name = (sub : String) => if !members.contains(sub) {
    members[sub] = jobj([("sub", jstr(sub)), ("email", jstr(emails.get(sub).unwrap_or(""))), ("role", jstr("member"))])
  }
  for sub, _ in emails {
    name(sub)
  }
  for v in vaults {
    if get(v, "deleted") is Some(True) {
      continue
    }
    match text_at(v, "owner") {
      Some(o) => name(o)
      None => ()
    }
    match array_at(v, "members") {
      Some(ms) => for m in ms { if m is String(s) { name(s) } }
      None => ()
    }
  }
  let devices : Map[String, Json] = Map([])
  let keys : Map[String, Json] = Map([])
  let persons : Map[String, Json] = Map([])
  for sub in order {
    let of = logs.get(sub).unwrap_or([])
    let mine = boxes.filter(b => of.iter().any(l => l.devices.iter().any(d => Some(d.id) == text_at(b, "device"))))
    let l = vault_log_chosen(ws, sub, of, vaults, mine, cert_ok)
    name(sub)
    persons[sub] = jstr(l.genesis)
    for d in l.devices {
      devices[d.id] = vault_log_device_json(sub, d)
      keys[d.id] = jstrs(d.sign_keys)
    }
  }
  {
    "ws": jstr(ws),
    "seq": jnum(0.0),
    "head": jstr(""),
    "genesis": jstr(""),
    "members": Json::object(members),
    "devices": Json::object(devices),
    "signKeys": Json::object(keys),
    "persons": Json::object(persons),
    "stations": Json::array([]),
    "disabled": Json::boolean(false),
  }
}

///|
/// The lock workspace `ws`'s vault goes by where it is not in security mode (state.ts `vaultLock`): None where it is
/// (the lock in force is the vault's, `locked`) or where this station is in no workspace.
pub fn Cloud::personal_vault_lock(
  self : Cloud,
  ws? : String? = None,
  emails : Map[String, String],
  vaults : Array[Json],
  boxes : Array[Json],
  cert_ok : (Json, Json) -> Bool,
) -> Json? {
  let at = match ws {
    Some(w) if Some(w) != self.home() => Some(w)
    _ => None
  }
  let id = match at {
    Some(w) => w
    None => self.home().unwrap_or("")
  }
  if id == "" || self.locked(ws=at) is Some(_) {
    return None
  }
  Some(personal_vault_lock(self.crypto, id, self.person_chains().every(), emails, vaults, boxes, cert_ok))
}

///|
/// Who a connection is by a vault's lock made of its members' own locks (lock.ts `admit` where `genesis` is ""): only a
/// person's own app device, proving its key for the workspace; raises a refusal why not.
pub fn admit_personal(c : Crypto, lock : Json, who : Who) -> (String, String, String?) raise Failure {
  let ws = text_at(lock, "ws").unwrap_or("")
  let id = match who.base {
    Some(base) => {
      guard who.proof is Some(proof) && c.endpoint_ok(ws, base, who.endpoint, proof) else {
        raise Refused("invalid lock device proof")
      }
      base
    }
    None => who.endpoint
  }
  let d = match get(lock, "devices") {
    Some(ds) => get(ds, id)
    None => None
  }
  guard d is Some(dev) && text_at(dev, "kind") == Some("app") && text_at(dev, "sub") == Some(who.sub) else {
    raise Refused("this device is not on your personal lock")
  }
  let role = match get(lock, "members") {
    Some(ms) => match get(ms, who.sub) { Some(m) => text_at(m, "role").unwrap_or("member"); None => "member" }
    None => "member"
  }
  (id, role, text_at(dev, "sign_key"))
}
