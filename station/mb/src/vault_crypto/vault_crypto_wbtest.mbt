// What is worked out here without the shell: the codecs as Node's, the rules of a scope, hosts and values, the plain
// library's checks, a schema read as schema-install.ts reads it, and the keeper's grants held, used, renewed, run out
// and handed over on a clock of the test's.

///|
test "hex, base64 and JSON as Node writes and reads them" {
  inspect(hex(b"\x00\xff\x10"), content="00ff10")
  inspect(unhex("00FFzz10"), content="b\"\\x00\\xff\"")
  inspect(unhex("abc"), content="b\"\\xab\"")
  inspect(b64url(b"\xfb\xff\xbf"), content="-_-_")
  inspect(b64(b"ab"), content="YWI=")
  inspect(unb64("QU JD=QUJD"), content="b\"ABC\"")
  inspect(unb64("+/-_"), content="b\"\\xfb\\xff\\xbf\"")
  inspect(unb64("QUJDR"), content="b\"ABC\"")
  inspect(unb64("QU=JD"), content="b\"A\"")
  inspect(stringify({ "b": 1, "a": [1.5, true, Json::null()], "s": "\u{2028}\"\u{1}名" }), content="{\"b\":1,\"a\":[1.5,true,null],\"s\":\"\u{2028}\\\"\\u0001名\"}")
  inspect(js_number(1.0e21), content="1e+21")
  inspect(js_number(-0.0), content="0")
  let lone = parse_js("\"a\\ud800b\"")
  inspect(stringify(lone), content="\"a\\ud800b\"")
}

///|
test "how long a grant may last, and the hosts it is for" {
  inspect(allows(None, Some(Json::string("chat"))), content="true")
  inspect(allows(Some(Json::string("hour")), Some(Json::string("chat"))), content="false")
  inspect(allows(Some(Json::string("week")), Some(Json::string("once"))), content="false")
  inspect(allows(Some(Json::null()), Some(Json::string("once"))), content="true")
  inspect(host_allowed("API.GitHub.com.", ["api.github.com"]), content="true")
  inspect(host_allowed("example.com", ["*.example.com"]), content="false")
  inspect(host_allowed("a.example.com", ["*.example.com"]), content="true")
  inspect(host_allowed("\u{212a}ey.com", ["key.com"]), content="true")
  inspect(value_of({ "kind": "login", "fields": { "username": "u", "password": "p" } }), content=(
    #|Some(p)
  ))
  inspect(value_of({ "kind": "token", "fields": { "value": "" } }), content="None")
  inspect(account_of({ "kind": "login", "fields": { "username": "u" } }), content=(
    #|Some(u)
  ))
  inspect(key_context("w", "v", 3L), content="stillfail-vault-key/1\u{0}w\u{0}v\u{0}3")
}

///|
test "the plain library's checks" {
  let item : Json = {
    "ws": "w",
    "id": "i_01HZZZZZZZZZZZZZZZZZZZZZZZ",
    "owner": "a@x.com",
    "version": 0,
    "kind": "file",
    "name": "kubeconfig",
    "fields": { "content": "AAAA", "filename": "config" },
    "notes": "",
    "listing": { "name": "kubeconfig", "kind": "file", "modes": ["file"], "hosts": [] },
    "at": 1000,
  }
  inspect(plain_ok(None, item, "a@x.com"), content="None")
  inspect(plain_ok(None, item, "b@x.com"), content=(
    #|Some(an item is its owner's own)
  ))
  inspect(file_ok({ "content": "AAA" }), content=(
    #|Some(a file's content is its bytes in base64)
  ))
  inspect(file_ok({ "content": "AAAA", "filename": "../x" }), content=(
    #|Some(a file's name is a name, not a path)
  ))
  inspect(plain_ok(None, with_field(item, "name", Json::string("\u{3000}")), "a@x.com"), content=(
    #|Some(an item has a name)
  ))
  inspect(plain_ok(Some(with_field(item, "deleted", Json::boolean(true))), item, "a@x.com"), content=(
    #|Some(the item is deleted)
  ))
}

///|
test "a schema read as schema-install.ts reads it" {
  let schema =
    #|CREATE TABLE IF NOT EXISTS t (a TEXT); -- a comment; with a semicolon
    #|create trigger if not exists t_t AFTER INSERT ON t BEGIN UPDATE t SET a = a; END;
    #|INSERT OR IGNORE INTO   t (a) VALUES ('x');
  inspect(statements_of(schema), content=(
    #|[CREATE TABLE IF NOT EXISTS t (a TEXT), INSERT OR IGNORE INTO t (a) VALUES ('x')]
  ))
  inspect(named(schema), content=(
    #|[t, t_t]
  ))
  inspect(reads_from("select 1 from t where a = 'x'", "t"), content="true")
  inspect(reads_from("SELECT 1 FROM tt", "t"), content="false")
  let refused = try {
    account("x", "DROP TRIGGER IF EXISTS old; CREATE TABLE IF NOT EXISTS y (a)", [])
    "none"
  } catch {
    e => e.to_string()
  }
  inspect(refused, content="the vault's schema x holds a statement installSchema cannot tell is done: DROP TRIGGER IF EXISTS old (vault/schema-install.ts)")
}

///|
/// A keeper on a clock and timers of the test's, with no shell (no box is opened: the plain library's grants).
fn test_keeper(now : Ref[Double], timers : Array[(Double, () -> Unit)]) -> Keeper {
  let c : Crypto = { ask: (op, _) => Err("no shell here: \{op}") }
  Keeper::new(c, () => now.val, (ms, f) => {
    timers.push((now.val * 1000.0 + ms, f))
    () => ()
  })
}

///|
test "a plain library's grant: held, used once, run out, handed over" {
  let now = Ref(1000.0)
  let timers = []
  let k = test_keeper(now, timers)
  let request : Json = { "id": "r1", "ws": "w", "vault": "plain", "item": "i", "session": "s1", "mode": "proxy", "status": "pending" }
  let d : Json = { "scope": "once", "hosts": ["api.github.com"], "listing": { "modes": ["proxy"], "hosts": ["api.github.com"] }, "lasts": Json::null() }
  let secret : Json = { "kind": "token", "name": "T", "fields": { "value": "v" } }
  inspect(k.hold(request, with_field(d, "scope", Json::string("week")), secret), content=(
    #|Some(scope is once, hour or chat)
  ))
  inspect(k.hold(request, with_field(d, "hosts", Json::array([])), secret), content=(
    #|Some(given through the proxy, it names its hosts)
  ))
  inspect(k.hold(request, d, secret), content="None")
  inspect(k.holds("s1"), content="true")
  inspect(k.usable("s2", "r1").map(_ => ()), content=(
    #|Err(this grant is another session's)
  ))
  inspect(k.spend("r1"), content="true")
  inspect(k.spend("r1"), content="false")
  inspect(k.usable("s1", "r1").map(_ => ()), content=(
    #|Err(this grant was for one use and is used: ask again)
  ))
  inspect(k.active("s1", "r1"), content="true")
  // handed over: the next keeper holds it as it was, used
  let next = test_keeper(now, [])
  next.carry(k.carried())
  inspect(next.usable("s1", "r1").map(_ => ()), content=(
    #|Err(this grant was for one use and is used: ask again)
  ))
  // an idle grant renewed by its use, then run out on the clock
  let idle = with_field(with_field(request, "id", Json::string("r2")), "timeout", { "kind": "idle", "seconds": 600 })
  inspect(k.hold(idle, with_field(with_field(d, "scope", Json::string("hour")), "timeout", { "kind": "idle", "seconds": 600 }), secret), content="None")
  now.val = 1500.0
  k.renew("s1", "r2")
  now.val = 1700.0
  inspect(k.usable("s1", "r2").map(h => h.until), content="Ok(Some(2100))")
  now.val = 2100.0
  inspect(k.usable("s1", "r2").map(_ => ()), content=(
    #|Err(this grant ran out: ask again)
  ))
  inspect(k.has_grant("r2"), content="false")
  k.end("s1")
  inspect(k.holds("s1"), content="false")
}

///|
test "a snapshot as the routes read it: its value and its body by name, null where none is held" {
  let v : Json = { "id": "v1", "seq": 0 }
  inspect(stringify(snapshot_json(Some((v, "b1")))), content="{\"value\":{\"id\":\"v1\",\"seq\":0},\"body\":\"b1\"}")
  inspect(stringify(snapshot_json(None)), content="null")
}

///|
test "tag_browse constant and prepare_accept_cross rejects mismatched sourceWs, non-owner, and invalid signature" {
  inspect(tag_browse, content="stillfail-vault-browse/1")
  let now = Ref::new(1000.0)
  let timers : Array[(Double, () -> Unit)] = []
  let k = test_keeper(now, timers)
  let lock : Json = {
    "ws": "wB",
    "members": { "alice": { "email": "alice@x.com", "role": "owner" } },
    "devices": { "d1": { "id": "d1", "sub": "alice", "sign_key": "ed25519:00" } },
  }
  let entry : Json = {
    "sourceWs": "wA",
    "sourceWsName": "Work A",
    "vault": "vA",
    "vaultName": "Personal A",
    "vaultLasts": "hour",
    "item": "iA",
    "listing": { "name": "GitHub A", "kind": "token", "modes": ["proxy"], "hosts": ["api.github.com"] },
  }
  let request : Json = {
    "id": "r_cross1",
    "ws": "wB",
    "vault": "vA",
    "item": "iA",
    "session": "s1",
    "mode": "proxy",
    "status": "pending",
    "cross": { "workspace": "wA", "workspaceName": "Work A" },
  }
  // Mismatched sourceWs is rejected before signature check
  let lv = lock_view(lock)
  let bad_ws : Json = {
    "v": 1,
    "ws": "wB",
    "sourceWs": "wOTHER",
    "request": "r_cross1",
    "vault": "vA",
    "item": "iA",
    "mode": "proxy",
    "hosts": ["api.github.com"],
    "scope": "once",
    "exp": 1600,
    "secret": "x",
    "at": 1000,
    "sig": { "key": "ed25519:00", "alg": "Ed25519", "sig": "00" },
  }
  match k.prepare_accept_cross(lv, entry, request, bad_ws, "alice") {
    Refusal(why) => assert_true(why.contains("source workspace") || why.contains("match"))
    Ready(_) => abort("expected mismatched sourceWs to fail")
  }
  // Scope exceeding vaultLasts is rejected
  let bad_scope = with_field(with_field(bad_ws, "sourceWs", Json::string("wA")), "scope", Json::string("chat"))
  match k.prepare_accept_cross(lv, entry, request, bad_scope, "alice") {
    Refusal(why) => assert_true(why.contains("at most") || why.contains("signature") || why.contains("scope"))
    Ready(_) => abort("expected bad scope or sig to fail")
  }
}
