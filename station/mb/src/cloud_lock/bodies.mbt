// The bodies of one workspace's statements this station keeps, by their hash (station/src/cloud/lock-bodies.ts),
// `mesh/locks/<ws>.bodies.json`, each taken only where an entry kept commits to it under the workspace's tag.

///|
/// The longest body taken, in its canonical form.
pub let body_most : Int = 16 * 1024

///|
/// A body not taken, by its hash where it has one, and why.
pub(all) struct BodyRefused {
  hash : String?
  why : String
}

///|
pub fn BodyRefused::to_json(self : BodyRefused) -> Json {
  jobj([("hash", opt_str_json(self.hash)), ("why", jstr(self.why))])
}

///|
pub struct LockBodies {
  priv disk : Disk?
  priv path : String?
  priv mut bodies : Map[String, Json]?
  /// Counts each body taken: what is made of them is made again.
  mut version : Int
}

///|
pub fn LockBodies::new(disk : Disk?, path : String?) -> LockBodies {
  { disk, path, bodies: None, version: 0 }
}

///|
fn LockBodies::read(self : LockBodies) -> Map[String, Json] {
  if self.bodies is Some(b) {
    return b
  }
  let out : Map[String, Json] = Map([])
  match (self.disk, self.path) {
    (Some(disk), Some(path)) =>
      match disk.read(path) {
        Some(text) =>
          match parse(text) {
            Some(raw) =>
              match get(raw, "bodies") {
                Some(Array(bs)) =>
                  for b in bs {
                    if body_hash(b) is Some(h) {
                      out[h] = b
                    }
                  }
                _ => ()
              }
            None => ()
          }
        None => ()
      }
    _ => ()
  }
  self.bodies = Some(out)
  out
}

///|
/// Every body kept, by its hash.
pub fn LockBodies::all(self : LockBodies) -> Map[String, Json] {
  self.read()
}

///|
pub fn LockBodies::has(self : LockBodies, h : String) -> Bool {
  self.read().contains(h)
}

///|
/// `bodies` taken where the rules find an entry kept that commits to each under the tag of workspace `ws`; each one
/// not, and why. Written once for all taken.
pub fn LockBodies::take(self : LockBodies, c : Crypto, ws : String, bodies : Array[Json], commits : (String) -> Array[Commit]) -> (Int, Array[BodyRefused]) {
  let kept = self.read()
  let refused = []
  let mut taken = 0
  for b in bodies {
    let text = match (try Ok(canonical(b)) catch { e => Err(e) }) {
      Ok(t) => t
      Err(_) => {
        refused.push({ hash: None, why: "a body is {ws, kind, …, salt}" })
        continue
      }
    }
    if text.length() > body_most {
      refused.push({ hash: None, why: "a body this long is no statement" })
      continue
    }
    let h = match body_hash(b) {
      Some(h) => h
      None => {
        refused.push({ hash: None, why: "a body is {ws, kind, …, salt}" })
        continue
      }
    }
    if kept.contains(h) {
      continue
    }
    match body_refusal(c, ws, b, commits(h)) {
      Some(why) => {
        refused.push({ hash: Some(h), why })
        continue
      }
      None => ()
    }
    kept[h] = parse(text).unwrap_or(b)
    taken += 1
  }
  if taken > 0 {
    self.version += 1
    match (self.disk, self.path) {
      (Some(disk), Some(path)) => {
        let text = stringify(jobj([("bodies", jarr(kept.values().collect()))]))
        disk.write(path, text) catch {
          _ => ()
        }
      }
      _ => ()
    }
  }
  (taken, refused)
}
