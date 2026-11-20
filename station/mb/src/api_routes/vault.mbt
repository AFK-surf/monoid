// The vaults this station holds (routes/vault.ts: vaults, items and boxes, each write checked against the lock pinned
// in the asker's workspace and the version it follows, told to the members' streams) and what agents asked of them
// (routes/vault-requests.ts: requests decided, the plain library of a workspace without security mode).

///|
fn refuse(
  status : Int32,
  code : String,
  error : String,
  more~ : Array[(String, JV)] = [],
) -> Answer {
  json(
    status,
    stringify(jobj([("error", js(error)), ("code", js(code))] + more)),
  )
}

///|
fn needs_lock() -> Answer {
  refuse(
    409, "vault_needs_lock", "the vault needs the workspace's security mode (its lock) pinned on this station",
  )
}

///|
/// The lock the asker's workspace's vault goes by (None: none): its lock in force in security mode, else its members'
/// own (vault/module.ts `lock`, given who asks: known by it from then on).
async fn Admin::vault_lock(self : Admin, r : Request) -> JV? {
  let l = self.backend.ask("vault.lock", [r.who("workspace").unwrap_or(jundef), r.viewer])
  if nullish(l) {
    None
  } else {
    Some(l)
  }
}

///|
fn sees_vault(vault : JV, r : Request) -> Bool {
  vault.get("ws").unwrap_or(jundef) == r.who("workspace").unwrap_or(jundef) &&
  jitems(vault.get("members")).contains(r.who("sub").unwrap_or(jundef))
}

///|
fn members_to(vault : JV) -> JV {
  jobj([
    ("workspace", vault.get("ws").unwrap_or(jundef)),
    ("subs", vault.get("members").unwrap_or(jundef)),
  ]).filter_undef()
}

///|
async fn Admin::vault_tell(
  self : Admin,
  event : String,
  data : JV,
  of : String,
  to : JV,
) -> Unit {
  if self.setup.has("events") {
    self.backend.tell("events.tell", [js(event), data, js(of), to])
  }
}

///|
/// Whether an older station's writes are still being handed over (the vault's part's `beforeWrite`).
async fn Admin::vault_waiting(self : Admin) -> Bool {
  if !self.setup.has("vault.beforeWrite") {
    return false
  }
  let waiting = self.backend.ask("vault.beforeWrite", [])
  if waiting is Bool(false) {
    return true
  }
  if is_undef(waiting) {
    return false
  }
  !is_truthy(Some(waiting)) ||
  self.backend.ask("vault.beforeWrite", []) is Bool(false)
}

///|
fn handover() -> Answer {
  refuse(
    503, "vault_handover", "the previous station has not finished handing over",
  )
}

///|
fn int_of(v : JV?) -> Double? {
  match v {
    Some(Num(n)) if is_safe_integer(n) => Some(n)
    _ => None
  }
}

///|
/// The lock's devices by id: a Map as the TypeScript's lock gives it (`{"$map": [[id, device]...]}`), or the plain
/// object `{id: device}` of the MoonBit station's (cloud_lock vault_lock.mbt `personal_vault_lock`).
fn lock_devices(l : JV) -> Array[JV] {
  match l.get("devices") {
    Some(Obj(entries) as m) =>
      match m.get("$map") {
        Some(Arr(_)) =>
          jitems(m.get("$map")).map(p => jitems(Some(p)).get(0).unwrap_or(jundef))
        _ => entries.map(p => js(p.0))
      }
    _ => []
  }
}

///|
/// The lock's members' roles as `(sub, role)` pairs, supporting both plain object `{sub: {role}}` and Map `$map`.
fn lock_member_roles(l : JV) -> Array[(String, String)] {
  let role_of = (v : JV) => match v {
    Str(r) if r != "" => r
    Obj(_) =>
      match v.get("role") {
        Some(Str(r)) if r != "" => r
        _ => "member"
      }
    _ => "member"
  }
  let out = []
  match l.get("members") {
    Some(Obj(entries) as m) =>
      match m.get("$map") {
        Some(Arr(pairs)) =>
          for p in pairs {
            let ps = jitems(Some(p))
            if ps.get(0) is Some(Str(sub)) {
              out.push((sub, role_of(ps.get(1).unwrap_or(jundef))))
            }
          }
        _ =>
          for e in entries {
            out.push((e.0, role_of(e.1)))
          }
      }
    _ => ()
  }
  out
}

///|
fn lock_member_role(l : JV, sub : String) -> String? {
  for p in lock_member_roles(l) {
    if p.0 == sub {
      return Some(p.1)
    }
  }
  None
}

///|
fn admit_who(r : Request) -> JV {
  let device = r.who("lockDevice")
  jobj([
    ("sub", r.who("sub").unwrap_or(jundef)),
    ("endpoint", r.who("device").unwrap_or(jundef)),
    ("base", field_of(device, "base").unwrap_or(jundef)),
    ("proof", field_of(device, "proof").unwrap_or(jundef)),
  ]).filter_undef()
}

///|
fn Admin::vault_routes(self : Admin) -> Array[Route] {
  if !self.setup.has("vault") {
    return []
  }
  let v = async fn(call : String, args : Array[JV]) -> JV {
    self.backend.ask("vaults." + call, args)
  }
  let crypto = async fn(call : String, args : Array[JV]) -> JV {
    self.backend.ask("vault/crypto." + call, args)
  }
  let tag = (kind : String) => {
    js("stillfail-vault\{if kind == "vault" { "" } else { "-" + kind }}/1")
  }
  let deleted_write = async fn(e : Error) -> Bool {
    is_truthy(
      Some(self.backend.ask("vault/store.isDeletedVaultWrite", [error_json(e)])),
    )
  }
  [
    route("GET", "^\\/vault\\/vaults$", async fn(r, _) {
      guard self.vault_lock(r) is Some(l) else { return needs_lock() }
      let all = jitems(
        Some(
          v("memberVaults", [
            l.get("ws").unwrap_or(jundef),
            r.who("sub").unwrap_or(jundef),
          ]),
        ),
      )
      ok(jobj([("vaults", jarr(all.filter(x => sees_vault(x, r))))]))
    }),
    route("POST", "^\\/vault\\/vaults\\/latest$", async fn(r, _) {
      guard self.vault_lock(r) is Some(l) else { return needs_lock() }
      let held = field_of(body_json(r), "held")
      guard held is Some(Arr(held)) && held.length() <= 256 else {
        return refuse(400, "vault_invalid", "held is a list of vault versions")
      }
      let latest = []
      for h in held {
        if !(h is Obj(_)) ||
          !(h.get("id") is Some(Str(_))) ||
          h.get("ws").unwrap_or(jundef) != r.who("workspace").unwrap_or(jundef) ||
          !(h.get("members") is Some(Arr(_))) ||
          !jitems(h.get("members")).contains(r.who("sub").unwrap_or(jundef)) {
          continue
        }
        if !is_truthy(Some(crypto("signedOk", [h, tag("vault")]))) {
          continue
        }
        let signer = crypto("signerOf", [
          l,
          field_of(h.get("sig"), "key").unwrap_or(jundef),
        ])
        let signer_sub = field_of(Some(signer), "sub").unwrap_or(jundef)
        if nullish(signer_sub) {
          continue
        }
        let is_ws = h.get("scope") == Some(Str("workspace"))
        let signer_admin = match signer_sub {
          Str(sub) =>
            match lock_member_role(l, sub) {
              Some("owner") | Some("admin") => true
              _ => false
            }
          _ => false
        }
        if signer_sub != h.get("owner").unwrap_or(jundef) &&
          !(is_ws && signer_admin) {
          continue
        }
        let found = v("vault", [
          l.get("ws").unwrap_or(jundef),
          h.get("id").unwrap(),
        ])
        if !(found is Null) &&
          (found.get("owner").unwrap_or(jundef) ==
            h.get("owner").unwrap_or(jundef) ||
            (is_ws && found.get("scope") == Some(Str("workspace")))) {
          latest.push(found)
        }
      }
      ok(jobj([("vaults", jarr(latest))]))
    }),
    route("PUT", "^\\/vault\\/vaults$", async fn(r, _) {
      if self.vault_waiting() {
        return handover()
      }
      guard self.vault_lock(r) is Some(l) else { return needs_lock() }
      let ws = l.get("ws").unwrap_or(jundef)
      guard body_json(r) is Some(Obj(_) as next) &&
        next.get("id") is Some(Str(_)) else {
        return refuse(400, "vault_invalid", "a vault, as JSON")
      }
      if next.get("ws").unwrap_or(jundef) !=
        r.who("workspace").unwrap_or(jundef) {
        return refuse(400, "vault_invalid", "a vault of another workspace")
      }
      let copy = r.param("copy") == Some("1")
      let id = next.get("id").unwrap()
      for attempt in 0..<3 {
        let held = v("vaultSnapshot", [ws, id])
        let prev = if nullish(held) {
          JV::Null
        } else {
          match held.get("value") {
            Some(p) if !nullish(p) => p
            _ => Null
          }
        }
        if attempt > 0 && !(prev is Null) && !sees_vault(prev, r) {
          return refuse(
            404, "vault_unknown", "no such vault here, or not one of yours",
          )
        }
        // A copy of a sibling is kept only if every station chooses it over the one currently held.
        let mut sibling = false
        let seq = int_of(next.get("seq"))
        let prev_seq = jnumber(prev.get("seq")).unwrap_or(@double.not_a_number)
        match seq {
          Some(s) if copy && !(prev is Null) && s <= prev_seq => {
            if s < prev_seq ||
              !is_truthy(Some(crypto("vaultSupersedes", [next, prev]))) {
              return ok(jobj([("vault", prev)]))
            }
            sibling = true
          }
          _ => ()
        }
        match seq {
          Some(s) if !copy => {
            let follows = if prev is Null { 0.0 } else { prev_seq + 1.0 }
            if s != follows {
              return refuse(
                409,
                "vault_conflict",
                "seq \{num_text(follows)} is the one that follows",
                more=[("vault", prev)],
              )
            }
          }
          _ => ()
        }
        let why = if sibling {
          let w = crypto("vaultOk", [l, Null, next, jbool(true)])
          if nullish(w) {
            let next_scope = next.get("scope").unwrap_or(Null)
            let prev_scope = prev.get("scope").unwrap_or(Null)
            if next_scope != prev_scope {
              js("a vault's scope does not change")
            } else if next.get("owner").unwrap_or(jundef) !=
              prev.get("owner").unwrap_or(jundef) {
              let signer = crypto("signerOf", [
                l,
                field_of(next.get("sig"), "key").unwrap_or(jundef),
              ])
              let takeover = next_scope == Str("workspace") &&
                prev_scope == Str("workspace") &&
                field_of(Some(signer), "sub").unwrap_or(jundef) ==
                next.get("owner").unwrap_or(jundef)
              if takeover {
                Null
              } else {
                js("a vault's owner does not change")
              }
            } else {
              Null
            }
          } else {
            w
          }
        } else {
          crypto("vaultOk", [l, prev, next, jbool(copy)])
        }
        if !(why is Null) {
          return refuse(400, "vault_invalid", js_string(Some(why)))
        }
        let body = if nullish(held) {
          JV::Null
        } else {
          held.get("body").unwrap_or(Null)
        }
        let put = is_truthy(
          Some(v("putVaultIf", [next, if nullish(body) { Null } else { body }])),
        ) catch {
          e => if deleted_write(e) { false } else { raise e }
        }
        if !put {
          continue
        }
        self.vault_tell(
          "vault",
          next,
          "vault\u{0}\{js_string(Some(id))}",
          members_to(next),
        )
        let now = jitems(next.get("members"))
        let gone = jitems(prev.get("members")).filter(m => !now.contains(m))
        if gone.length() > 0 {
          self.vault_tell(
            "vault-gone",
            jobj([("id", id), ("vault", next)]),
            "vault-gone\u{0}\{js_string(Some(id))}",
            jobj([
              ("workspace", next.get("ws").unwrap_or(jundef)),
              ("subs", jarr(gone)),
            ]).filter_undef(),
          )
        }
        return ok(jobj([("vault", next)]))
      }
      let current = v("vault", [ws, id])
      if current is Null || !sees_vault(current, r) {
        return refuse(
          404, "vault_unknown", "no such vault here, or not one of yours",
        )
      }
      refuse(
        409,
        "vault_conflict",
        "the vault changed while it was being written",
        more=[("vault", current)],
      )
    }),
    route("GET", "^\\/vault\\/items$", async fn(r, _) {
      guard self.vault_lock(r) is Some(l) else { return needs_lock() }
      let ws = l.get("ws").unwrap_or(jundef)
      // One vault's (`vault=`), or those of every vault the member is in.
      let of = r.param("vault")
      let candidates = match of {
        None =>
          jitems(Some(v("memberVaults", [ws, r.who("sub").unwrap_or(jundef)])))
        Some(o) => {
          let one = v("vault", [ws, js(o)])
          if one is Null {
            []
          } else {
            [one]
          }
        }
      }
      let seen = candidates.filter(x => {
        sees_vault(x, r) &&
        (match of {
          None => true
          Some(o) => x.get("id") == Some(js(o))
        })
      })
      if of is Some(_) && seen.length() == 0 {
        return refuse(
          404, "vault_unknown", "no such vault here, or not one of yours",
        )
      }
      let items = []
      for x in seen {
        for
          item in jitems(Some(v("items", [ws, x.get("id").unwrap_or(jundef)]))) {
          items.push(item)
        }
      }
      ok(jobj([("items", jarr(items))]))
    }),
    route("PUT", "^\\/vault\\/items$", async fn(r, _) {
      if self.vault_waiting() {
        return handover()
      }
      guard self.vault_lock(r) is Some(l) else { return needs_lock() }
      let ws = l.get("ws").unwrap_or(jundef)
      guard body_json(r) is Some(Obj(_) as next) &&
        next.get("vault") is Some(Str(_)) &&
        next.get("id") is Some(Str(_)) else {
        return refuse(400, "vault_invalid", "an item, as JSON")
      }
      let copy = r.param("copy") == Some("1")
      for _ in 0..<3 {
        let held_vault = v("vaultSnapshot", [ws, next.get("vault").unwrap()])
        let vault = if nullish(held_vault) {
          JV::Null
        } else {
          match held_vault.get("value") {
            Some(p) if !nullish(p) => p
            _ => Null
          }
        }
        if vault is Null || !sees_vault(vault, r) {
          return refuse(
            404, "vault_unknown", "no such vault here, or not one of yours",
          )
        }
        if is_truthy(vault.get("deleted")) {
          return refuse(404, "vault_unknown", "that vault was deleted")
        }
        let held = v("itemSnapshot", [
          ws,
          vault.get("id").unwrap_or(jundef),
          next.get("id").unwrap(),
        ])
        let prev = if nullish(held) {
          JV::Null
        } else {
          match held.get("value") {
            Some(p) if !nullish(p) => p
            _ => Null
          }
        }
        let mut sibling = false
        let version = int_of(next.get("version"))
        let prev_version = jnumber(prev.get("version")).unwrap_or(
          @double.not_a_number,
        )
        match version {
          Some(n) if copy && !(prev is Null) && n <= prev_version => {
            if n < prev_version ||
              !is_truthy(Some(crypto("itemSupersedes", [next, prev]))) {
              return ok(jobj([("item", prev)]))
            }
            sibling = true
          }
          _ => ()
        }
        match version {
          Some(n) if !copy => {
            let follows = if prev is Null { 0.0 } else { prev_version + 1.0 }
            if n != follows {
              return refuse(
                409,
                "vault_conflict",
                "version \{num_text(follows)} is the one that follows",
                more=[("item", prev)],
              )
            }
          }
          _ => ()
        }
        let why = crypto("itemOk", [
          l,
          vault,
          if sibling {
            Null
          } else {
            prev
          },
          next,
          jbool(copy),
        ])
        if !(why is Null) {
          return refuse(400, "vault_invalid", js_string(Some(why)))
        }
        let item_body = if nullish(held) {
          JV::Null
        } else {
          held.get("body").unwrap_or(Null)
        }
        let put = is_truthy(
          Some(
            v("putItemIf", [
              next,
              held_vault.get("body").unwrap_or(jundef),
              if nullish(item_body) {
                Null
              } else {
                item_body
              },
            ]),
          ),
        ) catch {
          e => if deleted_write(e) { false } else { raise e }
        }
        if !put {
          continue
        }
        self.vault_tell(
          "vault-item",
          next,
          "vault-item\u{0}\{js_string(vault.get("id"))}\u{0}\{js_string(next.get("id"))}",
          members_to(vault),
        )
        return ok(jobj([("item", next)]))
      }
      refuse(
        409, "vault_conflict", "the vault or item changed while it was being written",
      )
    }),
    route("GET", "^\\/vault\\/boxes$", async fn(r, _) {
      guard self.vault_lock(r) is Some(l) else { return needs_lock() }
      let ws = l.get("ws").unwrap_or(jundef)
      // Only those of devices still in the lock.
      let devices = lock_devices(l)
      let boxes = if devices.length() <= 32 {
        jitems(Some(v("boxesFor", [ws, jarr(devices)])))
      } else {
        jitems(Some(v("boxes", [ws])))
      }
      let kept = []
      for c in boxes {
        if crypto("certOk", [l, c]) is Null {
          kept.push(c)
        }
      }
      if l.get("genesis") == Some(Str("")) {
        let member_roles = lock_member_roles(l)
        let roles_fields = member_roles.map(p => (p.0, js(p.1)))
        let member_subs : Map[String, Unit] = Map([])
        for p in member_roles {
          member_subs[p.0] = ()
        }
        let chains_fields = []
        let raw_chains = self.backend.ask("vault.personalChains", [ws])
        if raw_chains is Obj(entries) {
          for e in entries {
            if member_subs.contains(e.0) {
              chains_fields.push((e.0, e.1))
            }
          }
        }
        return ok(
          jobj([
            ("boxes", jarr(kept)),
            ("chains", jobj(chains_fields)),
            ("roles", jobj(roles_fields)),
          ]),
        )
      }
      ok(jobj([("boxes", jarr(kept))]))
    }),
    route("PUT", "^\\/vault\\/boxes$", async fn(r, _) {
      if self.vault_waiting() {
        return handover()
      }
      guard self.vault_lock(r) is Some(l) else { return needs_lock() }
      let ws = l.get("ws").unwrap_or(jundef)
      let cert = body_json(r).unwrap_or(jundef)
      let why = crypto("certOk", [l, cert])
      if !(why is Null) {
        return refuse(400, "vault_invalid", js_string(Some(why)))
      }
      // Published by the device itself, as the lock admits it.
      let device = try {
        let admitted = self.backend.ask("cloud/lock.admit", [
          l,
          admit_who(r),
          jint(0),
        ])
        field_of(field_of(Some(admitted), "device"), "id").unwrap_or(jundef)
      } catch {
        _ => Null
      }
      if device != cert.get("device").unwrap_or(jundef) {
        return refuse(
          403, "vault_not_device", "a device publishes its own box certificate",
        )
      }
      let boxed = async fn(c : JV) -> Bool {
        self.setup.has("vault.boxed") &&
        self.backend.ask("vault.boxed", [l, c]) is Bool(false)
      }
      for _ in 0..<3 {
        let held = v("boxSnapshot", [ws, cert.get("device").unwrap_or(jundef)])
        let had = if nullish(held) {
          JV::Null
        } else {
          match held.get("value") {
            Some(p) if !nullish(p) => p
            _ => Null
          }
        }
        // An older one than held changes nothing, including when it was replaced during this write.
        if !(had is Null) &&
          jnumber(had.get("at")).unwrap_or(@double.not_a_number) >
          jnumber(cert.get("at")).unwrap_or(@double.not_a_number) {
          if had.get("ws").unwrap_or(jundef) == ws &&
            had.get("device").unwrap_or(jundef) ==
            cert.get("device").unwrap_or(jundef) &&
            crypto("certOk", [l, had]) is Null &&
            boxed(had) {
            return refuse(
              503, "vault_busy", "the box certificate or a pending request changed while it was being reboxed",
            )
          }
          return ok(jobj([("box", had)]))
        }
        let box_body = if nullish(held) {
          JV::Null
        } else {
          held.get("body").unwrap_or(Null)
        }
        if !is_truthy(
            Some(
              v("putBoxIf", [
                cert,
                if nullish(box_body) {
                  Null
                } else {
                  box_body
                },
              ]),
            ),
          ) {
          continue
        }
        self.vault_tell(
          "vault-box",
          cert,
          "vault-box\u{0}\{js_string(cert.get("device"))}",
          jobj([("workspace", cert.get("ws").unwrap_or(jundef))]).filter_undef(),
        )
        if boxed(cert) {
          return refuse(
            503, "vault_busy", "the box certificate or a pending request changed while it was being reboxed",
          )
        }
        return ok(jobj([("box", cert)]))
      }
      refuse(
        503, "vault_busy", "the box certificate changed while it was being written",
      )
    }),
  ]
}

///|
fn Admin::vault_requests_routes(self : Admin) -> Array[Route] {
  if !self.setup.has("vault") {
    return []
  }
  let s = async fn(call : String, args : Array[JV]) -> JV {
    self.backend.ask("secrets." + call, args)
  }
  let p = async fn(call : String, args : Array[JV]) -> JV {
    self.backend.ask("secrets.plain." + call, args)
  }
  let shown = async fn(args : Array[JV]) -> JV {
    self.backend.ask("vault/plain.shown", args)
  }
  let owner = (r : Request) => @jscase.lower(r.email())
  let ws = (r : Request) => r.who("workspace").unwrap_or(jundef)
  let lock_or_null = async fn(r : Request) -> JV {
    match self.vault_lock(r) {
      Some(l) => l
      None => Null
    }
  }
  // A decision: taken, or why not.
  let decide = async fn(r : Request, f : async (JV) -> JV) -> Answer {
    guard body_json(r) is Some(Obj(_) | Arr(_) as o) else {
      return refuse(400, "vault_invalid", "a decision, as JSON")
    }
    let why = f(o)
    if why is Null {
      ok(jobj([("ok", jbool(true))]))
    } else {
      refuse(409, "vault_refused", js_string(Some(why)))
    }
  }
  let locked_decision = (call : String) => {
    async fn(r : Request, _m : Array[String?]) -> Answer {
      guard self.vault_lock(r) is Some(l) else { return needs_lock() }
      decide(r, async fn(o) {
        // (a refusal: who turns it down, by their credential's email, where no own lock of theirs is heard yet)
        let more = if call == "deny" { [r.who("email").unwrap_or(jundef)] } else { [] }
        s(call, [l, r.who("sub").unwrap_or(jundef), o] + more)
      })
    }
  }
  let plain_told = async fn(kept : JV) -> JV {
    match kept {
      Str(_) => kept
      _ => {
        let view = shown([kept])
        self.vault_tell(
          "vault-plain",
          view,
          "vault-plain\u{0}\{js_string(kept.get("id"))}",
          jobj([
            ("workspace", kept.get("ws").unwrap_or(jundef)),
            ("email", kept.get("owner").unwrap_or(jundef)),
          ]).filter_undef(),
        )
        Null
      }
    }
  }
  [
    route("GET", "^\\/vault\\/requests$", async fn(r, _) {
      let mut current = lock_or_null(r)
      while true {
        let before = current
        let aborted = () => {
          match r.signal {
            Some(sig) => sig.aborted
            None => false
          }
        }
        if aborted() {
          return refuse(503, "read_cancelled", "read cancelled")
        }
        ignore(s("preparePending", [ws(r), jbool(!(before is Null))]))
        if aborted() {
          return refuse(503, "read_cancelled", "read cancelled")
        }
        current = lock_or_null(r)
        if current == before {
          break
        }
        if current is Null {
          return refuse(
            409, "lock_changed", "the workspace's security mode changed while the requests were prepared; try again",
          )
        }
        // (its members' own locks, no security mode: nothing of this device's to admit again)
        if current.get("genesis") is Some(Str("")) {
          continue
        }
        let now = (self.wall_now() / 1000.0).floor()
        let admitted = try {
          ignore(
            self.backend.ask("cloud/lock.admit", [
              current,
              admit_who(r),
              jnum(now),
            ]),
          )
          true
        } catch {
          _ => false
        }
        if !admitted {
          return refuse(
            403, "lock_unconfirmed", "this device is no longer admitted to the workspace",
          )
        }
      }
      ok(jobj([("requests", s("pending", [ws(r), current, r.viewer]))]))
    }),
    route("POST", "^\\/vault\\/grants$", locked_decision("grant")),
    route("POST", "^\\/vault\\/denials$", locked_decision("deny")),
    // A secret an agent asked to keep, written into the viewer's vault by their app: `{request, vault}`.
    route("POST", "^\\/vault\\/saves$", locked_decision("saved")),
    route("POST", "^\\/vault\\/described$", locked_decision("described")),
    route("POST", "^\\/vault\\/removed$", locked_decision("removed")),
    route("GET", "^\\/vault\\/uses$", async fn(r, _) {
      let l = lock_or_null(r)
      ok(
        jobj([
          (
            "uses",
            s("uses", [ws(r), l, js(r.param("vault").unwrap_or("")), r.viewer]),
          ),
        ]),
      )
    }),
    route("GET", "^\\/vault\\/plain$", async fn(r, _) {
      let lasts = p("lasts", [ws(r), js(owner(r))])
      let items = jitems(Some(p("items", [ws(r), js(owner(r))])))
      let views = []
      for i, item in items {
        views.push(shown([item, jint(i), jarr(items)]))
      }
      let locked = !(lock_or_null(r) is Null)
      ok(
        jobj(
          [("items", jarr(views)), ("locked", jbool(locked))] +
          (if is_truthy(Some(lasts)) {
            [
              ("lasts", lasts.get("lasts").unwrap_or(jundef)),
              ("lastsAt", lasts.get("at").unwrap_or(jundef)),
            ]
          } else {
            []
          }),
        ).filter_undef(),
      )
    }),
    route("PUT", "^\\/vault\\/plain\\/lasts$", async fn(r, _) {
      let o = body_json(r)
      let why = p("setLasts", [
        ws(r),
        js(owner(r)),
        field_of(o, "lasts").unwrap_or(jundef),
        field_of(o, "at").unwrap_or(jundef),
      ])
      if why is Null {
        ok(jobj([("ok", jbool(true))]))
      } else {
        refuse(400, "vault_invalid", js_string(Some(why)))
      }
    }),
    route("GET", "^\\/vault\\/plain\\/item$", async fn(r, _) {
      let i = p("item", [ws(r), js(r.param("id").unwrap_or(""))])
      if i is Null ||
        i.get("owner") != Some(js(owner(r))) ||
        is_truthy(i.get("deleted")) {
        return refuse(404, "vault_unknown", "no such item here, or not yours")
      }
      ok(jobj([("item", i)]))
    }),
    route("PUT", "^\\/vault\\/plain$", async fn(r, _) {
      let w = ws(r)
      guard body_json(r) is Some(Obj(_) | Arr(_) as o) else {
        return refuse(400, "vault_invalid", "an item, as JSON")
      }
      let next = jset(jset(spread_of(Some(o)), "ws", w), "owner", js(owner(r))).filter_undef()
      // Security mode on, the plain library only empties.
      if !(lock_or_null(r) is Null) &&
        !(next.get("deleted") is Some(Bool(true))) {
        return refuse(
          409, "vault_locked", "security mode is on: secrets go into the vault, encrypted",
        )
      }
      let prev = p("item", [w, next.get("id").unwrap_or(jundef)])
      if !(prev is Null) &&
        prev.get("owner").unwrap_or(jundef) !=
        next.get("owner").unwrap_or(jundef) {
        return refuse(404, "vault_unknown", "no such item here, or not yours")
      }
      let follows = if prev is Null {
        0.0
      } else {
        jnumber(prev.get("version")).unwrap_or(@double.not_a_number) + 1.0
      }
      if next.get("version") != Some(jnum(follows)) {
        let item = if prev is Null { JV::Null } else { shown([prev]) }
        return refuse(
          409,
          "vault_conflict",
          "version \{num_text(follows)} is the one that follows",
          more=[("item", item)],
        )
      }
      let why = self.backend.ask("vault/plain.plainOk", [
        prev,
        next,
        js(owner(r)),
      ])
      if !(why is Null) {
        return refuse(400, "vault_invalid", js_string(Some(why)))
      }
      ignore(p("put", [next]))
      let kept = p("item", [w, next.get("id").unwrap_or(jundef)])
      let view = shown([kept])
      self.vault_tell(
        "vault-plain",
        view,
        "vault-plain\u{0}\{js_string(kept.get("id"))}",
        jobj([("workspace", w), ("email", kept.get("owner").unwrap_or(jundef))]).filter_undef(),
      )
      ok(jobj([("item", shown([kept]))]))
    }),
    route("POST", "^\\/vault\\/plain\\/grants$", async fn(r, _) {
      decide(r, async fn(o) {
        s("grantPlain", [ws(r), lock_or_null(r), js(r.email()), o])
      })
    }),
    route("POST", "^\\/vault\\/plain\\/denials$", async fn(r, _) {
      decide(r, async fn(o) { s("denyPlain", [ws(r), js(r.email()), o]) })
    }),
    route("POST", "^\\/vault\\/plain\\/described$", async fn(r, _) {
      decide(r, async fn(o) {
        plain_told(
          s("describedPlain", [ws(r), lock_or_null(r), js(r.email()), o]),
        )
      })
    }),
    route("POST", "^\\/vault\\/plain\\/removed$", async fn(r, _) {
      decide(r, async fn(o) {
        plain_told(s("removedPlain", [ws(r), js(r.email()), o]))
      })
    }),
    route("POST", "^\\/vault\\/plain\\/saves$", async fn(r, _) {
      decide(r, async fn(o) {
        plain_told(s("savedPlain", [ws(r), lock_or_null(r), js(r.email()), o]))
      })
    }),
  ]
}
