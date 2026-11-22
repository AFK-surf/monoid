// Native whitebox tests for vault_service: ULIDs, ISO timestamps, site normalization, placeholder substitution,
// CONNECT target parsing, output scrubbing, variable/request ids, typed fields, sign-in state, DER encoding,
// and vault request/state matching.

///|
test "a ULID: its time in Crockford's digits, its randomness each byte mod 32" {
  assert_eq(ulid(0.0, Bytes::make(16, b'\x00')), "00000000000000000000000000")
  assert_eq(ulid(1800000000000.0, Bytes::make(16, b'\x21')), "01MCC5RM001111111111111111")
}

///|
test "a time as toISOString writes it" {
  assert_eq(iso_ms(0.0), "1970-01-01T00:00:00.000Z")
  assert_eq(iso_ms(1800000000123.0), "2027-01-15T08:00:00.123Z")
  assert_eq(iso(951782400.0), "2000-02-29T00:00:00.000Z")
}

///|
test "a site as asked" {
  assert_eq(site_of("https://www.GitHub.com/login?x=1"), "github.com")
  assert_eq(site_of("github.com:443"), "github.com")
  assert_eq(site_of("WWW.example.org."), "example.org")
  assert_eq(site_of("  x.y  "), "x.y")
}

///|
test "a placeholder swapped, inside Basic too" {
  assert_eq(swap("Bearer stillfail-secret:r_X", "stillfail-secret:r_X", "v"), "Bearer v")
  assert_eq(
    swap("Basic " + @vault_crypto.b64(utf8_of("u:stillfail-secret:r_X")), "stillfail-secret:r_X", "pw"),
    "Basic " + @vault_crypto.b64(utf8_of("u:pw")),
  )
  assert_eq(swap("none", "stillfail-secret:r_X", "v"), "none")
}

///|
test "a CONNECT's target" {
  assert_eq(target_of("api.github.com:443"), Some(("api.github.com", 443)))
  assert_eq(target_of("[::1]:8443"), Some(("::1", 8443)))
  assert_eq(target_of("nohost"), None)
  assert_eq(target_of(":443"), None)
}

///|
test "a value hidden in what a command says, also across its pieces" {
  assert_eq(scrub("token=ghp_abc123.", ["ghp_abc123"]), "token=[已隐藏].")
  let s = Scrubber::new(["ghp_abc123"])
  let a = s.push(utf8_of("x ghp_ab"))
  let b = s.push(utf8_of("c123 y"))
  let c = s.end()
  assert_eq(utf8_text(concat(concat(a, b), c)), "x [已隐藏] y")
  // (the short ones are not hidden: under 4 bytes)
  assert_eq(scrub("ab ab", ["ab"]), "ab ab")
}

///|
test "a name a variable may have, an id a command is sent under" {
  assert_true(var_name("GH_TOKEN"))
  assert_false(var_name("1X"))
  assert_true(away_id("x_" + "0123456789ABCDEFGHJKMNPQRS"))
  assert_false(away_id("x_1"))
  assert_true(splits_dotdot("a\\..\\b"))
  assert_false(splits_dotdot("a/b"))
}

///|
test "what is typed in on a card" {
  assert_eq(typed_fields("token", Some(obj([("value", js(" "))]))), None)
  assert_true(typed_fields("login", Some(obj([("username", js("u")), ("password", js("p"))]))) is Some(_))
  assert_eq(typed_fields("token", Some(obj([("value", ji(1))]))), None)
}

///|
test "a sign-in's state as kept" {
  let (cookies, passkeys) = state_of("[{\"name\":\"a\"}]")
  assert_eq(cookies.length(), 1)
  assert_eq(passkeys.length(), 0)
  let (c2, p2) = state_of("{\"cookies\":[],\"passkeys\":[{\"credentialId\":\"x\",\"rpId\":\"y\",\"privateKey\":\"z\"},{}]}")
  assert_eq(c2.length(), 0)
  assert_eq(p2.length(), 1)
  assert_eq(state_of("not json").0.length(), 0)
}

///|
test "a number as toString(36) writes it, a name in DER" {
  assert_eq(base36(0.0), "0")
  assert_eq(base36(1800000000000.0), "mywpiww0")
  assert_eq(@vault_crypto.hex(der_length(5)), "05")
  assert_eq(@vault_crypto.hex(der_length(300)), "82012c")
  assert_eq(@vault_crypto.hex(oid("2.5.29.17")), "0603551d11")
}

///|
test "timeout validation enforces kind, whole minutes, and 1m..30d bounds" {
  assert_false(timeout_bad(obj([("kind", js("idle")), ("seconds", jn(60.0))])))
  assert_false(timeout_bad(obj([("kind", js("fixed")), ("seconds", jn(30.0 * 86400.0))])))
  assert_true(timeout_bad(obj([("kind", js("forever")), ("seconds", jn(60.0))])))
  assert_true(timeout_bad(obj([("kind", js("idle")), ("seconds", jn(30.0))])))
  assert_true(timeout_bad(obj([("kind", js("idle")), ("seconds", jn(90.0))])))
  assert_true(timeout_bad(obj([("kind", js("fixed")), ("seconds", jn(30.0 * 86400.0 + 60.0))])))
}

///|
test "plain and encrypted vault listings filter deleted/epoch and match by id or name in order" {
  let plain_items = [
    obj([("id", js("i_1")), ("owner", js("a@x.com")), ("listing", obj([("name", js("GitHub Token")), ("modes", jstrs(["proxy"]))]))]),
    obj([("id", js("i_2")), ("owner", js("a@x.com")), ("deleted", jb(true)), ("listing", obj([("name", js("Deleted"))]))]),
    obj([("id", js("i_3")), ("owner", js("a@x.com"))]),
    obj([("id", js("i_4")), ("owner", js("a@x.com")), ("listing", obj([("name", js("i_1"))]))]),
  ]
  let listed = plain_listings(plain_items)
  assert_eq(listed.length(), 2)
  assert_eq(listed[0].vault, @vault_crypto.plain_id)
  assert_eq(listed[0].item, "i_1")
  // Case-insensitive match by name or id, preserving list order on collision
  assert_eq(first_match(listed, "github token").map(l => l.item), Some("i_1"))
  assert_eq(first_match(listed, "i_1").map(l => l.item), Some("i_1"))
  assert_true(first_match(listed, "missing") is None)
  let lock = Lock::of_json(
    obj([
      ("ws", js("w1")),
      ("genesis", js("g1")),
      ("members", obj([("sub_a", obj([("email", js("a@x.com")), ("role", js("owner"))]))])),
      ("devices", obj([])),
    ]),
  )
  let vault = obj([("id", js("v1")), ("owner", js("sub_a")), ("epoch", ji(2)), ("members", jstrs(["sub_a", "sub_b"]))])
  assert_eq(members_of(vault), ["sub_a", "sub_b"])
  let v_items = [
    obj([("id", js("vi_old")), ("epoch", ji(1)), ("listing", obj([("name", js("Old"))]))]),
    obj([("id", js("vi_cur")), ("epoch", ji(2)), ("listing", obj([("name", js("Cur"))]))]),
    obj([("id", js("vi_del")), ("epoch", ji(2)), ("deleted", jb(true)), ("listing", obj([("name", js("Del"))]))]),
  ]
  let v_listed = vault_listings(lock, vault, v_items)
  assert_eq(v_listed.length(), 1)
  assert_eq(v_listed[0].item, "vi_cur")
  assert_eq(v_listed[0].owner, Some("a@x.com"))
}

///|
test "hosted modes, oauth services, and delivery labels" {
  assert_true(hosted("proxy"))
  assert_true(hosted("browser"))
  assert_false(hosted("env"))
  assert_false(hosted("file"))
  assert_false(hosted("ssh"))
  assert_eq(oauth_of("slack"), Some(("Slack", ["slack.com"])))
  assert_eq(oauth_of("unknown"), None)
  assert_eq(kind_words("token"), "Token")
  assert_eq(kind_words("browser"), "登录态")
  assert_eq(scope_words("once").0, "仅本次")
  assert_true(how_words("proxy", ["api.github.com"]).contains("api.github.com"))
}

///|
test "cross-workspace SQL schemas and queries are valid and indexed" {
  assert_true(pending_schema.contains("vault_pending_owner_v4"))
  assert_true(pending_schema.contains("vault_pending_owner_v4_owner"))
  assert_true(use_schema.contains("vault_cross_use_lookup"))
  assert_true(use_schema.contains("vault_cross_use_owner"))
  assert_true(requests_schema.contains("vault_cross_listings"))
  assert_true(requests_schema.contains("vault_cross_listings_session"))
  assert_true(pending_cross_own.contains("vault_pending_owner_v4"))
  assert_true(cross_uses_sql.contains("vault_cross_use_lookup"))
}

///|
test "cross_to_listed preserves stored owner email for multi-person isolation" {
  let e : Json = {
    "sourceWs": "wA",
    "sourceWsName": "Work A",
    "vault": "vA",
    "vaultName": "Personal A",
    "item": "iA",
    "owner": "alice@x.com",
    "listing": { "name": "GitHub A", "kind": "token", "modes": ["proxy"], "hosts": ["api.github.com"] },
  }
  let listed = cross_to_listed(e, "bob@x.com")
  assert_eq(listed.owner, Some("alice@x.com"))
  assert_eq(listed.cross, Some(("wA", "Work A", "Personal A")))
}

///|
test "declared tools include cross-workspace secret_list parameters" {
  assert_true(tools_declared.contains("\"secret_list\""))
  assert_true(tools_declared.contains("\"other_workspaces\""))
  assert_true(tools_declared.contains("\"workspace\""))
}
