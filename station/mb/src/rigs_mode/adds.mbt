// Which rigs a workspace in security mode has (rigs/adds.ts; a station that only runs tasks, 2026-11-10). There the
// control plane's word that a machine is one of the workspace's rigs counts for nothing (it could name its own machine,
// to be sent the workspace's code and secrets as tasks): a rig is taken once its person, who compared its code, signed
// for it (rig-form.ts `AddBody`), with a key the workspace's lock knows as that member's own: a device of theirs that
// signs in the lock, or a device on their own lock where they are bound to it. No entry of the workspace's lock says it,
// so a station or an app from before rigs reads the lock as it did. The rig keeps what was signed and shows it to a
// station that asks (`rig.proof`); each station checks it against the lock it pinned.

///|
let adds_schema : String = "CREATE TABLE IF NOT EXISTS rig_adds (\n  ws TEXT NOT NULL,\n  rig TEXT NOT NULL,\n  body TEXT NOT NULL,\n  PRIMARY KEY (ws, rig)\n);"

///|
/// Why what was signed does not take `rig` into the workspace whose lock is `lock`, or None. `person_keys`: the keys on
/// a person's own lock, by its genesis, as this station has heard it.
pub fn add_refusal(
  crypto : @cloud_lock.Crypto,
  signed : Json?,
  ws : String,
  rig : Json,
  lock : @lock.LockState,
  person_keys : (String, String) -> Array[String],
  now : Double,
) -> String? {
  if !well_formed("add", signed) {
    return Some("not a rig's add")
  }
  let b = get(signed, "body")
  let r = Some(rig)
  if str_at(b, "ws") != Some(ws) || str_at(b, "rig") != str_at(r, "id") {
    return Some("signed for another rig or workspace")
  }
  if str_at(b, "sub") != str_at(r, "owner") {
    return Some("not signed by the person this rig is said to be of")
  }
  let sub = str_at(b, "sub").unwrap_or("")
  match lock.members.get(sub) {
    Some(m) if @cloud_lock.rank(m.role) >= @cloud_lock.rank("member") => ()
    _ => return Some("its person is no member who adds rigs here")
  }
  let key = str_at(get(signed, "sig"), "key").unwrap_or("")
  let own = match @cloud_lock.signer(lock, key, Some(now)) {
    Some(by) => by.sub == sub && by.own && !by.passkey
    None => false
  }
  let bound = lock.persons.get(sub)
  if !own && !(bound is Some(g) && person_keys(g, sub).contains(key)) {
    return Some("signed by a key the workspace's lock does not know as that member's own")
  }
  if signature_holds(crypto, "add", signed) {
    None
  } else {
    Some("the signature does not hold")
  }
}

///|
pub struct RigAdds {
  priv db : @sql.Db
  priv cloud : @cloud_lock.Cloud
  priv chain : (String) -> Array[Json]?
  priv now : () -> Double
  priv crypto : @cloud_lock.Crypto
  /// What was last made of each one kept, by the lock it was checked against (its head).
  priv checked : Map[String, (String, Bool)]
}

///|
/// `chain`: a person's own lock as this station has heard it, by its genesis (mesh/person-chains.ts). `now`: seconds.
pub fn RigAdds::new(
  db : @sql.Db,
  cloud : @cloud_lock.Cloud,
  chain : (String) -> Array[Json]?,
  now : () -> Double,
  crypto : @cloud_lock.Crypto,
) -> RigAdds raise {
  db.exec(adds_schema)
  { db, cloud, chain, now, crypto, checked: Map([]) }
}

///|
fn RigAdds::keys(self : RigAdds, genesis : String, sub : String) -> Array[String] {
  guard (self.chain)(genesis) is Some(chain) else { return [] }
  try @cloud_lock.person_fold(self.crypto, chain, sub).devices.values().map(d => d.key).collect() catch {
    _ => []
  }
}

///|
/// The lock a workspace is in security mode by here, its home one by none.
fn RigAdds::lock_of(self : RigAdds, ws : String) -> @lock.LockState? {
  let at = if self.cloud.home() == Some(ws) { None } else { Some(ws) }
  match self.cloud.locked(ws=at) {
    Some({ state: Some(s), .. }) => Some(s)
    _ => None
  }
}

///|
pub fn RigAdds::get(self : RigAdds, ws : String, rig : String) -> Json? {
  let rows = self.db.all("SELECT body FROM rig_adds WHERE ws = ? AND rig = ?", [jstr(ws), jstr(rig)]) catch {
    _ => []
  }
  match rows.get(0) {
    Some(row) =>
      match row.get("body") {
        Some(String(text)) => parse(text)
        _ => None
      }
    None => None
  }
}

///|
/// Why `signed` is not taken for `rig` in `ws` now, or None: kept, the rig one of the workspace's from now on.
pub fn RigAdds::take(self : RigAdds, ws : String, rig : Json, signed : Json?) -> String? raise {
  guard self.lock_of(ws) is Some(lock) else {
    return Some("this workspace is not in security mode here: its rigs are the control plane's to say")
  }
  match add_refusal(self.crypto, signed, ws, rig, lock, (g, sub) => self.keys(g, sub), (self.now)()) {
    Some(why) => return Some(why)
    None => ()
  }
  let id = str_at(Some(rig), "id").unwrap_or("")
  let _ = self.db.run(
    "INSERT INTO rig_adds (ws, rig, body) VALUES (?, ?, ?) ON CONFLICT (ws, rig) DO UPDATE SET body = excluded.body",
    [jstr(ws), jstr(id), jstr(stringify(signed.unwrap_or(Json::null())))],
  )
  self.checked.remove("\{ws}\u0000\{id}")
  self.cloud.rigs_changed()
  None
}

///|
/// Whether `rig` is one of `ws`'s by what its person signed, as the lock stands now (a member taken out of the lock, or
/// their device, takes their rigs with them).
pub fn RigAdds::holds(self : RigAdds, ws : String, rig : Json) -> Bool {
  guard self.lock_of(ws) is Some(lock) else { return false }
  let r = Some(rig)
  let id = str_at(r, "id").unwrap_or("")
  let owner = str_at(r, "owner").unwrap_or("")
  // (a station the lock's owners signed in, made one that only runs tasks since: the workspace's as it was)
  if lock.stations.contains(id) {
    return true
  }
  let key = "\{ws}\u0000\{id}"
  // (a person's own lock moving on is heard as the workspace's does: bound there, its head is what admits them; a state
  // in force where the chain moved says its word, cloud/lock.ts `stateWord`; its head's hash, as the chain gone by
  // moves to another branch of the same length too, cloud/log-keep.ts)
  let own = match lock.persons.get(owner) {
    None => None
    Some(g) => (self.chain)(g)
  }
  let tail = match own {
    None => ""
    Some(c) if c.length() == 0 => ""
    Some(c) => {
      let h = @cloud_lock.entry_hash(c[c.length() - 1]) catch { _ => "" }
      "\{c.length()}:\{h}"
    }
  }
  let at = if self.cloud.home() == Some(ws) { None } else { Some(ws) }
  let head = "\{self.cloud.state_word(at)}\u0000\{owner}\u0000\{tail}"
  if self.checked.get(key) is Some((h, holds)) && h == head {
    return holds
  }
  let signed = self.get(ws, id)
  let holds = signed is Some(_) &&
    add_refusal(self.crypto, signed, ws, rig, lock, (g, sub) => self.keys(g, sub), (self.now)()) is None
  self.checked[key] = (head, holds)
  holds
}
