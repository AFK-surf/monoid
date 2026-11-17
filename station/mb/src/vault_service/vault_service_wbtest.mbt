// What of the vault's service is worked out without the station: the words of an id, a time, a site, a header and a
// command's output as station/src/vault writes them. The rest, with the TypeScript beside it, is
// station/test/mb-vault-service.test.ts's.

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
