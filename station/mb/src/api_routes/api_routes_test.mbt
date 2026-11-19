// What the routes stand on, as JavaScript has it: the patterns, values, numbers, paths, words and decodings the
// TypeScript routes used (station/test/mb-api-routes.test.ts holds the routes themselves to them).

///|
test "patterns match as JavaScript's" {
  let r = @api_routes.re("^\\/*sessions\\/+([^/]+)(?:\\/+([^/]+))?(?:\\/.*)?$")
  assert_eq(
    r.exec("//sessions//s1/files/x"),
    Some([Some("//sessions//s1/files/x"), Some("s1"), Some("files")]),
  )
  assert_eq(
    r.exec("/sessions/s1"),
    Some([Some("/sessions/s1"), Some("s1"), None]),
  )
  let t = @api_routes.re(
    "^\\/*threads\\/+([^/]+)(?:\\/+(?!(?:entries|relay)(?:\\/|$))([^/]+)(?:\\/.*)?|\\/*)$",
  )
  assert_true(t.matches("/threads/7/what"))
  assert_false(t.matches("/threads/7/entries"))
  assert_false(t.matches("/threads/7/relay/x"))
  assert_true(t.matches("/threads/7/relays"))
  assert_true(@api_routes.re("^https?:\\/\\/", flags="i").matches("HTTPS://x"))
  assert_true(@api_routes.re("^[A-Za-z0-9_-]{8,64}$").matches("abcdefgh"))
  assert_false(@api_routes.re("^[A-Za-z0-9_-]{8,64}$").matches("abcdefg"))
  assert_true(@api_routes.re("^[+-]?\\d{1,19}$").matches("-12"))
  assert_eq(
    @api_routes.re("\\r?\\n").replace_all("a\r\nb\nc", _ => "|"),
    "a|b|c",
  )
  assert_eq(@api_routes.re("[\\s,]+").replace_all("a, b\tc", _ => ";"), "a;b;c")
}

///|
test "values as JSON.stringify writes them, keys in JavaScript's order" {
  let o = @api_routes.jobj([
    ("b", @api_routes.jint(1)),
    ("2", @api_routes.js("x")),
    ("a", @api_routes.JV::Null),
    ("1", @api_routes.jbool(true)),
  ])
  assert_eq(
    @api_routes.stringify(o),
    "{\"1\":true,\"2\":\"x\",\"b\":1,\"a\":null}",
  )
  let parsed = @api_routes.parse("{\"z\":1,\"10\":2,\"z\":3}")
  assert_eq(@api_routes.stringify(parsed), "{\"10\":2,\"z\":3}")
  assert_eq(@api_routes.stringify(@api_routes.jnum(1.5e21)), "1.5e+21")
  assert_eq(
    @api_routes.stringify(@api_routes.js("\u{1}\"\\é")),
    "\"\\u0001\\\"\\\\é\"",
  )
  assert_eq(
    @api_routes.js_string(
      Some(
        @api_routes.jarr([
          @api_routes.jint(1),
          @api_routes.JV::Null,
          @api_routes.js("a"),
        ]),
      ),
    ),
    "1,,a",
  )
  assert_eq(
    @api_routes.text_of(Some(@api_routes.jobj([("a", @api_routes.jint(1))]))),
    "{\"a\":1}",
  )
}

///|
test "numbers as Number() reads them" {
  assert_eq(@api_routes.js_number(" 12 "), 12.0)
  assert_eq(@api_routes.js_number(""), 0.0)
  assert_eq(@api_routes.js_number("0x1f"), 31.0)
  assert_eq(@api_routes.js_number(".5"), 0.5)
  assert_eq(@api_routes.js_number("5."), 5.0)
  assert_eq(@api_routes.js_number("-1e3"), -1000.0)
  assert_true(@api_routes.js_number("1e").is_nan())
  assert_true(@api_routes.js_number("abc").is_nan())
  assert_true(@api_routes.js_number("Infinity").is_inf())
  assert_true(@api_routes.is_safe_integer(9007199254740991.0))
  assert_false(@api_routes.is_safe_integer(9007199254740992.0))
}

///|
test "strings by their code points and JavaScript's white space" {
  assert_eq(@api_routes.chars("a😀bc", 2), "a😀")
  assert_eq(@api_routes.code_points("a😀b"), 3)
  assert_eq(@api_routes.trim_js("\u{feff} x\u{3000}"), "x")
  assert_true(@api_routes.js_compare("B", "a") < 0)
  assert_true(@api_routes.js_compare("ab", "abc") < 0)
}

///|
test "a request's path and query decoded as admin/mod.rs does" {
  assert_eq(@api_routes.percent_decode("a%20b+c%zz"), "a b c%zz")
  assert_eq(@api_routes.segment("a+b%2Fc"), "a+b/c")
  assert_eq(@api_routes.query_pairs("a=1&&b&c=%E4%BD%A0"), [
    ("a", "1"),
    ("b", ""),
    ("c", "你"),
  ])
  assert_eq(@api_routes.decode_uri_component("v%201"), Some("v 1"))
  assert_eq(@api_routes.decode_uri_component("%E0%A4%A"), None)
  assert_eq(@api_routes.decode_uri_component("%C0%80"), None)
  assert_eq(@api_routes.encode_uri_component("a b/é!"), "a%20b%2F%C3%A9!")
}

///|
test "paths as the station checks them" {
  assert_eq(@api_routes.clean("a/../b/./c//"), "/b/c")
  assert_true(@api_routes.inside("/a/b", "/a"))
  assert_false(@api_routes.inside("/a", "/a"))
  assert_false(@api_routes.within("/ab", "/a"))
  assert_eq(@api_routes.file_name("/a/b/"), Some("b"))
  assert_eq(@api_routes.file_name("/a/.."), None)
  assert_eq(@api_routes.join(["/data", "uploads", "../x"]), "/data/x")
  assert_eq(@api_routes.dirname("/a/b/c"), "/a/b")
  assert_eq(@api_routes.dirname("a"), ".")
  assert_true(@api_routes.portable_name("web"))
  assert_false(@api_routes.portable_name("CON.txt"))
  assert_false(@api_routes.portable_name("a."))
}

///|
test "the words filled, a plural chosen, still.fail's name another product's" {
  let zh = @api_routes.parse(
    "{\"k\":\"在 {where} 有 {n} 个\",\"p\":{\"one\":\"一个\",\"other\":\"{n} 个\"},\"b\":\"still.fail 和 app.still.fail\"}",
  )
  let en = @api_routes.parse("{\"k\":\"{n} at {where}\"}")
  let w = @api_routes.Words::new(zh, en, product="monoid")
  assert_eq(w.tr("en", "k", args=[("where", "home"), ("n", "2")]), "2 at home")
  assert_eq(w.tr("en", "p", args=[("n", " 1 ")]), "一个")
  assert_eq(w.tr("zh", "p", args=[("n", "3")]), "3 个")
  assert_eq(w.tr("zh", "missing"), "missing")
  assert_eq(w.tr("zh", "b"), "monoid 和 app.still.fail")
  assert_eq(w.tr("zh", "k", args=[("where", "x")]), "在 x 有 {n} 个")
}

///|
test "the routes' own small rules" {
  assert_eq(@api_routes.connect_slug("My Bot!! 2"), "my-bot-2")
  assert_eq(@api_routes.connect_slug("###"), "slack")
  assert_eq(@api_routes.connect_slug("飞书", fallback="feishu"), "feishu")
  assert_eq(@api_routes.iso_seconds(1700000000123.0), "2023-11-14T22:13:20")
  assert_eq(@api_routes.iso_seconds(0.0), "1970-01-01T00:00:00")
  assert_eq(
    @api_routes.client_runtimes([
      ("Stillfail-Runtimes", "claude, codex,BAD,claude"),
    ]),
    ["claude", "codex"],
  )
  assert_eq(@api_routes.client_runtimes([]).length(), 6)
  assert_eq(
    @api_routes.preview_target("/preview/3000/a?b"),
    Some((3000, "/a?b")),
  )
  assert_eq(@api_routes.preview_target("/preview/70000"), None)
  assert_true(@api_routes.read_only_may("PUT", "/threads/7/read"))
  assert_false(@api_routes.read_only_may("PUT", "/threads/7/title"))
  assert_true(@api_routes.read_only_may("POST", "/changed/chats"))
  assert_eq(@api_routes.lang_of("zh-CN"), "zh")
  assert_eq(@api_routes.lang_of("fr"), "en")
}
