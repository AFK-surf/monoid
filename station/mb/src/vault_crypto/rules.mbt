// Who may write which vault or item version, which box certificates count: rules/src/vault's, written once in MoonBit
// and proved there, which the station's TypeScript reads built to JS (station/src/vault/crypto.ts `certOk`, `vaultOk`,
// `itemOk`, `signerOf`, `browserListingOk`, `vaultSupersedes`, `itemSupersedes`) and this reads as it is. Here only
// what the bridge to it is: the lock as JSON, and the signatures checked by the shell.

///|
/// The lock as the vault reads it, as JSON: `{ws, members: [sub…], devices: {id: {sub, kind, sign_key?, own?}},
/// signKeys: {id: [key…]}}` (station/src/cloud/lock.ts `LockState`'s members, devices and signKeys).
pub fn lock_view(lock : Json) -> @vault.LockView {
  let members : Map[String, Unit] = Map([])
  let roles : Map[String, String] = Map([])
  let devices : Map[String, @vault.Device] = Map([])
  let sign_keys : Map[String, Array[String]] = Map([])
  let ws = match lock {
    { "ws": String(ws), .. } => ws
    _ => ""
  }
  match lock {
    { "members": Array(ms), .. } =>
      for m in ms {
        if m is String(s) {
          members[s] = ()
          roles[s] = "member"
        }
      }
    { "members": Object(ms), .. } =>
      for k, v in ms {
        members[k] = ()
        let role = match v {
          String(r) => r
          { "role": String(r), .. } => r
          _ => "member"
        }
        roles[k] = role
      }
    _ => ()
  }
  if lock is { "devices": Object(ds), .. } {
    for id, d in ds {
      let str = fn(k : String) -> String? {
        match d {
          Object(o) =>
            match o.get(k) {
              Some(String(s)) => Some(s)
              _ => None
            }
          _ => None
        }
      }
      devices[id] = {
        sub: str("sub").unwrap_or(""),
        kind: str("kind").unwrap_or(""),
        sign_key: str("sign_key"),
        own: d is Object(o) && o.get("own") is Some(True),
      }
    }
  }
  if lock is { "signKeys": Object(ks), .. } {
    for id, had in ks {
      let keys : Array[String] = []
      if had is Array(xs) {
        for x in xs {
          if x is String(s) {
            keys.push(s)
          }
        }
      }
      sign_keys[id] = keys
    }
  }
  { ws, members, roles, devices, sign_keys }
}

///|
/// The shell's signatures as the rules ask them (crypto.ts `rulesCrypto`): the tag, a NUL, the text's SHA-256.
priv struct RulesCrypto {
  c : Crypto
}

///|
impl @vault.Crypto for RulesCrypto with record_sig_valid(self, sig, tag, text) {
  let bytes = tagged(self.c, tag, text) catch { _ => return false }
  sig_over(self.c, Some(sig), bytes)
}

///|
/// The member and lock device whose app `sign_key` is `key`; None when no app device in the lock signs with it, or
/// the one that does is not its person's own.
pub fn signer_of(lock : @vault.LockView, key : String) -> (String, String)? {
  @vault.signer_of(lock, key)
}

///|
/// Why a box certificate is not a lock app device's for the workspace, or None when it is (`ever`: a vault's keys,
/// signed by any key that device has had).
pub fn cert_ok(c : Crypto, lock : @vault.LockView, cert : Json?, ever~ : Bool = false) -> String? {
  @vault.cert_ok(lock, cert, ever, RulesCrypto::{ c, })
}

///|
/// Why `next` may not follow `prev` (None: it is the vault's first version), or None when it may (`copy`: a later
/// version brought from another station).
pub fn vault_ok(c : Crypto, lock : @vault.LockView, prev : Json?, next : Json, copy~ : Bool = false) -> String? {
  @vault.vault_ok(lock, prev, next, copy, RulesCrypto::{ c, })
}

///|
/// Why `next` may not follow `prev` (None: the item's first version) in `vault`, or None when it may.
pub fn item_ok(c : Crypto, lock : @vault.LockView, vault : Json, prev : Json?, next : Json, copy~ : Bool = false) -> String? {
  @vault.item_ok(lock, vault, prev, next, copy, RulesCrypto::{ c, })
}

///|
fn strings(v : Json?) -> Array[String] {
  let out : Array[String] = []
  if v is Some(Array(xs)) {
    for x in xs {
      out.push(
        match x {
          String(s) => s
          _ => ""
        },
      )
    }
  }
  out
}

///|
/// Why a listing (`{kind, modes, hosts}`) is not one as a sign-in must be, or None.
pub fn browser_listing_ok(l : Json) -> String? {
  let kind = match l {
    { "kind": String(k), .. } => k
    _ => ""
  }
  let field = fn(k : String) -> Json? {
    match l {
      Object(o) => o.get(k)
      _ => None
    }
  }
  @vault.browser_listing_ok(kind, strings(field("modes")), strings(field("hosts")))
}

///|
fn supersedes_of(a : Json, b : Json, number : String) -> Bool {
  let n = fn(v : Json, k : String) -> Int64 {
    match v {
      Object(m) =>
        match m.get(k) {
          Some(Number(x, ..)) => x.to_int64()
          _ => 0L
        }
      _ => 0L
    }
  }
  let deleted = fn(v : Json) { v is Object(m) && m.get("deleted") is Some(True) }
  let text = try @form.canonical(a).compare(@form.canonical(b)) catch { _ => return false }
  @history.supersedes(n(a, number), deleted(a), n(a, "epoch"), n(b, number), deleted(b), n(b, "epoch"), text)
}

///|
/// Which of two versions of a vault every station and device keeps: whether `a` is kept over `b`.
pub fn vault_supersedes(a : Json, b : Json) -> Bool {
  supersedes_of(a, b, "seq")
}

///|
/// Whether item version `a` is kept over `b` (by its version).
pub fn item_supersedes(a : Json, b : Json) -> Bool {
  supersedes_of(a, b, "version")
}
