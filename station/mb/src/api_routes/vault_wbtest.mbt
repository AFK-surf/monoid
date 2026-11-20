// The vault's routes against parts a test gives: the lock's devices as the MoonBit station writes them (a plain
// object) and as the TypeScript's Map, and the snapshots the store gives (`{value, body}`) written over.

///|
/// `f` run to its end on a runtime of its own (it waits on nothing outside).
fn[X] vault_ran(f : async () -> X) -> X {
  let rt = @effect.Runtime::new()
  let fiber = rt.fork(f)
  ignore(rt.run_ready())
  match fiber.poll() {
    Some(Succeeded(v)) => v
    _ => abort("it did not end")
  }
}

///|
priv struct VaultParts {
  answers : Map[String, (Array[JV]) -> JV]
  calls : Array[(String, Array[JV])]
}

///|
fn VaultParts::admin(self : VaultParts) -> Admin {
  Admin::new(
    Backend::new(async fn(name, args) {
      self.calls.push((name, args))
      match self.answers.get(name) {
        Some(f) => f(args)
        None => Null
      }
    }),
    Setup::new(Words::new(Obj([]), Obj([])), "0.0.0", [], false, None, b"", "zh", [
      "events", "vault.beforeWrite", "vault.boxed",
    ]),
  )
}

///|
fn VaultParts::args_of(self : VaultParts, name : String) -> Array[JV] {
  for c in self.calls {
    if c.0 == name {
      return c.1
    }
  }
  abort("\{name} was not asked")
}

///|
fn vault_parts(lock : JV, answers : Array[(String, (Array[JV]) -> JV)]) -> VaultParts {
  let m : Map[String, (Array[JV]) -> JV] = {}
  m["vault.lock"] = _ => lock
  for a in answers {
    m[a.0] = a.1
  }
  { answers: m, calls: [] }
}

///|
fn vault_ask(
  a : Admin,
  verb : String,
  path : String,
  query : Array[(String, String)],
  body : JV?,
) -> (Int32, JV) {
  let r = Request::new(
    verb,
    path,
    query,
    None,
    [],
    match body {
      Some(b) => utf8(stringify(b))
      None => b""
    },
    jobj([("workspace", js("w1")), ("sub", js("u1")), ("email", js("u1@x")), ("name", js(""))]),
    "en",
  )
  let answer = vault_ran(async fn() { a.handle(r) })
  (answer.status, parse(answer.text()) catch { _ => Null })
}

///|
let vault_lock_plain : JV = jobj([
  ("ws", js("w1")),
  ("devices", jobj([("d1", jobj([("id", js("d1")), ("sub", js("u1"))]))])),
])

///|
let vault_v1 : JV = jobj([("id", js("v1")), ("ws", js("w1")), ("members", jstrs(["u1"])), ("seq", jint(0))])

///|
fn snapshot(value : JV, body : String) -> JV {
  jobj([("value", value), ("body", js(body))])
}

///|
test "the boxes of the lock's devices, its devices a plain object or a Map" {
  let cert = jobj([("ws", js("w1")), ("device", js("d1")), ("at", jint(1))])
  let plain = vault_parts(vault_lock_plain, [("vaults.boxesFor", _ => jarr([cert]))])
  let (status, body) = vault_ask(plain.admin(), "GET", "/vault/boxes", [], None)
  assert_eq(status, 200)
  assert_eq(stringify(jarr(plain.args_of("vaults.boxesFor"))), "[\"w1\",[\"d1\"]]")
  assert_eq(stringify(body), "{\"boxes\":[{\"ws\":\"w1\",\"device\":\"d1\",\"at\":1}]}")
  let mapped = vault_parts(
    jobj([
      ("ws", js("w1")),
      ("devices", jobj([("$map", jarr([jarr([js("d1"), jobj([("sub", js("u1"))])])]))])),
    ]),
    [("vaults.boxesFor", _ => jarr([cert]))],
  )
  let (status, _) = vault_ask(mapped.admin(), "GET", "/vault/boxes", [], None)
  assert_eq(status, 200)
  assert_eq(stringify(jarr(mapped.args_of("vaults.boxesFor"))), "[\"w1\",[\"d1\"]]")
}

///|
test "an item written over the snapshots held: a first version, and a copy over one held" {
  let first = vault_parts(vault_lock_plain, [
    ("vaults.vaultSnapshot", _ => snapshot(vault_v1, "vb")),
    ("vaults.putItemIf", _ => jbool(true)),
  ])
  let item = jobj([("vault", js("v1")), ("id", js("i1")), ("version", jint(0))])
  let (status, body) = vault_ask(first.admin(), "PUT", "/vault/items", [], Some(item))
  assert_eq(status, 200)
  assert_eq(stringify(body), "{\"item\":{\"vault\":\"v1\",\"id\":\"i1\",\"version\":0}}")
  assert_eq(stringify(jarr(first.args_of("vaults.putItemIf"))), "[\{stringify(item)},\"vb\",null]")
  let copy = vault_parts(vault_lock_plain, [
    ("vaults.vaultSnapshot", _ => snapshot(vault_v1, "vb")),
    (
      "vaults.itemSnapshot",
      _ => snapshot(jobj([("vault", js("v1")), ("id", js("i1")), ("version", jint(1))]), "ib"),
    ),
    ("vaults.putItemIf", _ => jbool(true)),
  ])
  let newer = jobj([("vault", js("v1")), ("id", js("i1")), ("version", jint(2))])
  let (status, _) = vault_ask(copy.admin(), "PUT", "/vault/items", [("copy", "1")], Some(newer))
  assert_eq(status, 200)
  assert_eq(stringify(jarr(copy.args_of("vaults.putItemIf"))), "[\{stringify(newer)},\"vb\",\"ib\"]")
}

///|
test "a vault's next seq written over the one held" {
  let parts = vault_parts(vault_lock_plain, [
    ("vaults.vaultSnapshot", _ => snapshot(vault_v1, "b0")),
    ("vaults.putVaultIf", _ => jbool(true)),
  ])
  let next = jobj([("id", js("v1")), ("ws", js("w1")), ("members", jstrs(["u1"])), ("seq", jint(1))])
  let (status, body) = vault_ask(parts.admin(), "PUT", "/vault/vaults", [], Some(next))
  assert_eq(status, 200)
  assert_eq(stringify(body), "{\"vault\":\{stringify(next)}}")
  assert_eq(stringify(jarr(parts.args_of("vaults.putVaultIf"))), "[\{stringify(next)},\"b0\"]")
}

///|
test "a device's newer box certificate written over the one held" {
  let parts = vault_parts(vault_lock_plain, [
    ("cloud/lock.admit", _ => jobj([("device", jobj([("id", js("d1"))]))])),
    (
      "vaults.boxSnapshot",
      _ => snapshot(jobj([("ws", js("w1")), ("device", js("d1")), ("at", jint(1))]), "bb"),
    ),
    ("vaults.putBoxIf", _ => jbool(true)),
  ])
  let cert = jobj([("ws", js("w1")), ("device", js("d1")), ("at", jint(2))])
  let (status, body) = vault_ask(parts.admin(), "PUT", "/vault/boxes", [], Some(cert))
  assert_eq(status, 200)
  assert_eq(stringify(body), "{\"box\":\{stringify(cert)}}")
  assert_eq(stringify(jarr(parts.args_of("vaults.putBoxIf"))), "[\{stringify(cert)},\"bb\"]")
}

///|
test "GET /vault/boxes outside security mode returns personal chains and member roles" {
  let cert = jobj([("ws", js("w1")), ("device", js("d1")), ("at", jint(1))])
  let personal_lock = jobj([
    ("ws", js("w1")),
    ("genesis", js("")),
    (
      "members",
      jobj([
        ("u1", jobj([("sub", js("u1")), ("email", js("u1@x")), ("role", js("owner"))])),
        ("u2", jobj([("sub", js("u2")), ("email", js("u2@x")), ("role", js("admin"))])),
      ]),
    ),
    ("devices", jobj([("d1", jobj([("id", js("d1")), ("sub", js("u1"))]))])),
  ])
  let chains = jobj([
    ("u1", jarr([jobj([("seq", jint(0))])])),
    ("stranger", jarr([jobj([("seq", jint(0))])])),
  ])
  let parts = vault_parts(personal_lock, [
    ("vaults.boxesFor", _ => jarr([cert])),
    ("vault.personalChains", _ => chains),
  ])
  let (status, body) = vault_ask(parts.admin(), "GET", "/vault/boxes", [], None)
  assert_eq(status, 200)
  assert_eq(
    stringify(body),
    "{\"boxes\":[{\"ws\":\"w1\",\"device\":\"d1\",\"at\":1}],\"chains\":{\"u1\":[{\"seq\":0}]},\"roles\":{\"u1\":\"owner\",\"u2\":\"admin\"}}",
  )
}

///|
test "POST /vault/vaults/latest and PUT /vault/vaults sibling support workspace vault admin signer and owner takeover" {
  let ws_lock = jobj([
    ("ws", js("w1")),
    (
      "members",
      jobj([
        ("u1", jobj([("sub", js("u1")), ("email", js("u1@x")), ("role", js("owner"))])),
        ("u2", jobj([("sub", js("u2")), ("email", js("u2@x")), ("role", js("admin"))])),
      ]),
    ),
    ("devices", jobj([("d1", jobj([("id", js("d1")), ("sub", js("u1"))]))])),
  ])
  let held = jobj([
    ("id", js("v1")),
    ("ws", js("w1")),
    ("owner", js("u1")),
    ("scope", js("workspace")),
    ("members", jstrs(["u1", "u2"])),
    ("seq", jint(0)),
    ("sig", jobj([("key", js("k2"))])),
  ])
  let current = jobj([
    ("id", js("v1")),
    ("ws", js("w1")),
    ("owner", js("u2")),
    ("scope", js("workspace")),
    ("members", jstrs(["u2"])),
    ("seq", jint(1)),
  ])
  let latest_parts = vault_parts(ws_lock, [
    ("vault/crypto.signedOk", _ => jbool(true)),
    ("vault/crypto.signerOf", _ => jobj([("sub", js("u2")), ("device", js("d2"))])),
    ("vaults.vault", _ => current),
  ])
  let (status, body) = vault_ask(latest_parts.admin(), "POST", "/vault/vaults/latest", [], Some(jobj([("held", jarr([held]))])))
  assert_eq(status, 200)
  assert_eq(stringify(body), "{\"vaults\":[\{stringify(current)}]}")

  // Sibling copy of workspace vault allows owner takeover by signer; rejects third-party owner or scope change.
  let sibling_parts = vault_parts(ws_lock, [
    ("vaults.vaultSnapshot", _ => snapshot(held, "b0")),
    ("vault/crypto.vaultSupersedes", _ => jbool(true)),
    ("vault/crypto.signerOf", _ => jobj([("sub", js("u2")), ("device", js("d2"))])),
    ("vaults.putVaultIf", _ => jbool(true)),
  ])
  let sibling_ws = jobj([
    ("id", js("v1")),
    ("ws", js("w1")),
    ("owner", js("u2")),
    ("scope", js("workspace")),
    ("members", jstrs(["u2"])),
    ("seq", jint(0)),
    ("sig", jobj([("key", js("k2"))])),
  ])
  let (s_ok, _) = vault_ask(sibling_parts.admin(), "PUT", "/vault/vaults", [("copy", "1")], Some(sibling_ws))
  assert_eq(s_ok, 200)

  let sibling_third_party = jobj([
    ("id", js("v1")),
    ("ws", js("w1")),
    ("owner", js("u3")),
    ("scope", js("workspace")),
    ("members", jstrs(["u2", "u3"])),
    ("seq", jint(0)),
    ("sig", jobj([("key", js("k2"))])),
  ])
  let (s_bad_owner, _) = vault_ask(sibling_parts.admin(), "PUT", "/vault/vaults", [("copy", "1")], Some(sibling_third_party))
  assert_eq(s_bad_owner, 400)

  let sibling_bad_scope = jobj([
    ("id", js("v1")),
    ("ws", js("w1")),
    ("owner", js("u1")),
    ("members", jstrs(["u1"])),
    ("seq", jint(0)),
  ])
  let (s_bad, _) = vault_ask(sibling_parts.admin(), "PUT", "/vault/vaults", [("copy", "1")], Some(sibling_bad_scope))
  assert_eq(s_bad, 400)
}
