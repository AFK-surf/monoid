// What the sharing works out by itself, on the values the station gives: these say the rules each piece keeps.

///|
fn parse(s : String) -> Json {
  js_parse(s) catch {
    _ => Json::null()
  }
}

///|
test "a profile's login files, by its runtime and how it signs in" {
  assert_eq(sign_in_files(parse("{\"runtime\":\"claude\",\"access\":{\"kind\":\"subscription\"}}"), "/"), [".credentials.json", ".claude.json"])
  assert_eq(sign_in_files(parse("{\"access\":{\"kind\":\"subscription\"}}"), "/"), [])
  assert_eq(sign_in_files(parse("{\"access\":{\"kind\":\"service\",\"service\":\"colab\"}}"), "/"), ["colab-auth.json"])
  assert_eq(sign_in_files(parse("{\"access\":{\"kind\":\"service\",\"service\":\"fake-gpu\"}}"), "/"), [])
  assert_eq(sign_in_files(parse("{\"runtime\":\"codex\",\"access\":{\"kind\":\"subscription\"}}"), "/"), ["auth.json"])
  assert_eq(sign_in_files(parse("{\"runtime\":\"devin\",\"access\":{\"kind\":\"subscription\"}}"), "/"), [
    "devin/data/devin/credentials.toml", "devin/account.json",
  ])
  assert_eq(sign_in_files(parse("{\"runtime\":\"agy\",\"access\":{\"kind\":\"subscription\"}}"), "\\"), [
    "agy\\.gemini\\antigravity-cli\\antigravity-oauth-token", "agy\\account.json",
  ])
  assert_eq(sign_in_files(parse("{\"access\":{\"kind\":\"opencode-go\",\"login\":true}}"), "/"), ["opencode-console.json"])
  assert_eq(sign_in_files(parse("{\"access\":{\"kind\":\"api-provider\",\"provider\":\"kimi-code\",\"login\":true}}"), "/"), [
    "kimi-code.json", "kimi-code.token",
  ])
  assert_eq(sign_in_files(parse("{\"access\":{\"kind\":\"api-provider\",\"key\":\"k\"}}"), "/"), [])
}

///|
test "what goes to another station of a profile: its key only where it is one" {
  assert_eq(
    js_stringify(portable(parse("{\"id\":\"x\",\"home\":\"h\",\"name\":\"n\",\"access\":{\"kind\":\"subscription\",\"key\":\"s\"},\"enabled\":false,\"model\":null}"))),
    "{\"name\":\"n\",\"access\":{\"kind\":\"subscription\"},\"model\":null,\"enabled\":false}",
  )
  assert_eq(
    js_stringify(portable(parse("{\"access\":{\"kind\":\"api-provider\",\"key\":\"s\"}}"))),
    "{\"access\":{\"kind\":\"api-provider\",\"key\":\"s\"}}",
  )
  assert_eq(
    js_stringify(portable(parse("{\"name\":\"n\",\"maxConcurrentSessions\":4,\"newAccountProtection\":true}"))),
    "{\"name\":\"n\",\"maxConcurrentSessions\":4,\"newAccountProtection\":true}",
  )
}

///|
test "what is not shared, said why" {
  assert_eq(share_refusal(parse("{\"share\":{\"borrowed\":true}}")), Some("this profile is another station's"))
  assert_eq(
    share_refusal(parse("{\"runtime\":\"grok\",\"access\":{\"kind\":\"subscription\"}}")),
    Some("a SuperGrok subscription cannot be shared with other stations yet"),
  )
  assert_eq(
    share_refusal(parse("{\"access\":{\"provider\":\"kimi-code\",\"login\":true}}")),
    Some("a Kimi Code sign-in cannot be shared with other stations yet"),
  )
  assert_eq(share_refusal(parse("{\"runtime\":\"claude\",\"access\":{\"kind\":\"subscription\"}}")), None)
}

///|
test "where a profile serves" {
  let copy = parse("{\"share\":{\"borrowed\":true,\"workspaces\":[\"a\"]}}")
  assert_true(allowed_in(copy, Some("a"), Some("a")))
  assert_false(allowed_in(copy, Some("b"), Some("a")))
  assert_true(allowed_in(copy, None, Some("a")))
  assert_false(allowed_in(parse("{\"share\":{\"borrowed\":true,\"workspaces\":[\"b\"]}}"), None, Some("a")))
  assert_false(allowed_in(parse("{\"withheld\":[\"j\"]}"), Some("j"), Some("h")))
  assert_true(allowed_in(parse("{\"withheld\":[\"h\"]}"), Some("h"), Some("h")))
}

///|
test "the memory's paths, records and directories followed" {
  assert_true(memory_path(Some(jstr("MEMORY.md"))))
  assert_true(memory_path(Some(jstr("skills/a/SKILL.md"))))
  assert_false(memory_path(Some(jstr("skills/stillfail-jobs/SKILL.md"))))
  assert_false(memory_path(Some(jstr("skills/a"))))
  assert_false(memory_path(Some(jstr("skills/a/.git/x"))))
  assert_false(memory_path(Some(jstr("skills/con/x"))))
  assert_false(memory_path(Some(jnum(5.0))))
  let h = "a".repeat(64)
  let r = parse("{\"origin\":true,\"mode\":420,\"size\":1,\"prev\":[],\"by\":\"\{h}\",\"at\":1,\"hash\":\"\{h}\"}")
  assert_eq(
    rec_of_peer(Some(r)).map(js_stringify),
    Some("{\"hash\":\"\{h}\",\"at\":1,\"by\":\"\{h}\",\"prev\":[],\"size\":1,\"mode\":420,\"origin\":true}"),
  )
  assert_eq(rec_of_peer(Some(parse("{\"hash\":\"\",\"at\":1.5,\"by\":\"\{h}\",\"prev\":[],\"size\":0,\"mode\":420}"))), None)
  assert_eq(rec_of_peer(Some(parse("{\"hash\":\"\",\"at\":1,\"by\":\"\{h}\",\"prev\":[],\"size\":0,\"mode\":384}"))), None)
  assert_true(memory_followed("skills"))
  assert_true(memory_followed("workspaces/W1/skills/a"))
  assert_false(memory_followed("workspaces/a b"))
  assert_false(memory_followed("skills/stillfail-jobs"))
  assert_false(memory_followed("repo"))
}

///|
test "a skill kept apart says whose it is" {
  let kept = aside_skill(@utf8.encode("---\nname: deploy\ndescription: Deploys\n---\nbody\n"), "deploy-mini", "mini")
  assert_eq(@utf8.decode_lossy(kept), "---\nname: deploy-mini\ndescription: [mini] Deploys\n---\nbody\n")
  let bare = aside_skill(@utf8.encode("text\n"), "a-b", "b")
  assert_eq(
    @utf8.decode_lossy(bare),
    "---\nname: a-b\ndescription: [b] b's own, kept apart from another station's skill of the same name\n---\n\ntext\n",
  )
}

///|
test "a chat's link, read as a still.fail link names it" {
  assert_eq(link_parts("https://app.still.fail/o/W1/st/c%201?x"), Some(("W1", "st", "c 1")))
  assert_eq(link_parts("https://x/o/W1/st"), None)
  assert_eq(decode_uri_component("%E4%B8%AD"), "中")
  let bad = try {
    ignore(decode_uri_component("%E4%B8"))
    false
  } catch {
    _ => true
  }
  assert_true(bad)
}

///|
test "dates as JavaScript writes and reads them" {
  assert_eq(iso_string(0.0), "1970-01-01T00:00:00.000Z")
  assert_eq(iso_string(1800000000000.0), "2027-01-15T08:00:00.000Z")
  assert_eq(date_parse("2026-11-17T05:00:00.123456Z"), 1794891600123.0)
  assert_eq(date_parse("2026-11-17T13:00:00+08:00"), 1794891600000.0)
  assert_eq(date_parse("2026-11-17"), 1794873600000.0)
  assert_true(date_parse("tomorrow") != date_parse("tomorrow"))
  assert_eq(agy_expiry_in("{\"token\":{\"expiry\":\"2026-11-17T05:00:00Z\"}}"), 1794891600000.0)
  assert_eq(agy_expiry_in("nope"), 0.0)
}

///|
test "JSON written as JavaScript writes it" {
  assert_eq(js_stringify(parse("{\"b\":1,\"2\":[1,2],\"a\":{},\"10\":null,\"01\":\"x\"}")), "{\"2\":[1,2],\"10\":null,\"b\":1,\"a\":{},\"01\":\"x\"}")
  assert_eq(js_stringify2(parse("{\"a\":[]}")), "{\n  \"a\": []\n}")
  assert_eq(hash_of(jstr("x")), sha_text("x"))
  assert_eq(hash_of(parse("{\"a\":1}")), sha_text("{\"a\":1}"))
  assert_eq(base64_of(b"hello"), "aGVsbG8=")
  assert_eq(base64_loose("aGVs bG8"), b"hello")
  let token = "e30." + base64_of(@utf8.encode("{\"exp\":10}")).replace_all(old="=", new="") + ".s"
  assert_eq(jwt_expiry(Some(jstr(token))), Some(10000.0))
  assert_eq(text_most(Some(jstr("  abc  ")), 2), "ab")
}

///|
test "a lent sign-in's file, its refresh token left out" {
  assert_eq(
    agy_lent_file(parse("{\"token\":{\"access_token\":\"a\",\"refresh_token\":\"r\"},\"email\":\"e@x\",\"auth_method\":null,\"stored\":{\"project_id\":\"p\",\"auth_method\":\"gcp\"}}")),
    "{\"project_id\":\"p\",\"auth_method\":\"gcp\",\"token\":{\"access_token\":\"a\"},\"id_token_email\":\"e@x\"}",
  )
}

///|
test "a chat's share as stored, and as it is now" {
  let row : Map[String, Json] = {
    "session": jstr("s"),
    "shared": jstr("[{\"workspace\":\"w\",\"name\":\"n\",\"used\":5},{\"workspace\":\"v\"},{\"name\":\"x\"}]"),
    "write": jnum(1.0),
    "by": jstr("p"),
    "at": jnum(3.0),
  }
  let share = to_chat_share(row)
  assert_eq(
    js_stringify(share),
    "{\"to\":[{\"workspace\":\"w\",\"name\":\"n\",\"used\":5},{\"workspace\":\"v\",\"name\":\"v\",\"used\":3}],\"write\":true,\"by\":\"p\",\"at\":3}",
  )
  assert_eq(live_share(share, xshare_idle_ms + 4.0).map(js_stringify), Some("{\"to\":[{\"workspace\":\"w\",\"name\":\"n\",\"used\":5}],\"write\":true,\"by\":\"p\",\"at\":3}"))
  assert_eq(live_share(share, xshare_idle_ms + 6.0), None)
}

///|
test "one at a time, each in its turn" {
  assert_true(strict_eq(None, None))
  assert_false(strict_eq(Some(jnull()), None))
  assert_true(strict_eq(Some(jnum(1.0)), Some(jnum(1.0))))
  assert_true(truthy(Some(jstr("x"))))
  assert_false(truthy(Some(jnum(0.0))))
  assert_eq(js_sorted(["b", "a", "B"]), ["B", "a", "b"])
  assert_eq(after_of(parse("{\"hash\":\"x\",\"prev\":[\"y\",\"x\"]}"), ["z"]), ["x", "z", "y"])
}
