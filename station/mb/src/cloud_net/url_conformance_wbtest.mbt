// WHATWG / WPT URL conformance tests for station/mb/src/cloud_net/url.mbt (`parse_url`).
// Contract note: `parse_url` parses absolute URLs with no base (matching Node `new URL(raw)`).

///|
test "conformance: WHATWG default port stripping for all special schemes" {
  url_case("http://example.com:80/", Some(["http://example.com/", "http://example.com", "/", "", ""]))
  url_case("http://example.com:8080/", Some(["http://example.com:8080/", "http://example.com:8080", "/", "", ""]))
  url_case("https://example.com:443/a", Some(["https://example.com/a", "https://example.com", "/a", "", ""]))
  url_case("https://example.com:8443/a", Some(["https://example.com:8443/a", "https://example.com:8443", "/a", "", ""]))
  url_case("ws://example.com:80/s", Some(["ws://example.com/s", "ws://example.com", "/s", "", ""]))
  url_case("ws://example.com:443/s", Some(["ws://example.com:443/s", "ws://example.com:443", "/s", "", ""]))
  url_case("wss://example.com:443/s", Some(["wss://example.com/s", "wss://example.com", "/s", "", ""]))
  url_case("wss://example.com:80/s", Some(["wss://example.com:80/s", "wss://example.com:80", "/s", "", ""]))
  url_case("ftp://example.com:21/dir", Some(["ftp://example.com/dir", "ftp://example.com", "/dir", "", ""]))
  url_case("ftp://example.com:2121/dir", Some(["ftp://example.com:2121/dir", "ftp://example.com:2121", "/dir", "", ""]))
  // Leading zeros in port are normalized; port 0 is valid; port 65535 is max; 65536 is invalid
  url_case("http://example.com:0080/", Some(["http://example.com/", "http://example.com", "/", "", ""]))
  url_case("http://example.com:0/", Some(["http://example.com:0/", "http://example.com:0", "/", "", ""]))
  url_case("http://example.com:65535/", Some(["http://example.com:65535/", "http://example.com:65535", "/", "", ""]))
  url_case("http://example.com:65536/", None)
}

///|
test "conformance: WHATWG IPv4 and IPv6 host normalization and rejection" {
  // IPv4 decimal, hex, octal, shorthand
  url_case("http://0x7f000001/", Some(["http://127.0.0.1/", "http://127.0.0.1", "/", "", ""]))
  url_case("http://0177.0.0.1/", Some(["http://127.0.0.1/", "http://127.0.0.1", "/", "", ""]))
  url_case("http://127.0.1/", Some(["http://127.0.0.1/", "http://127.0.0.1", "/", "", ""]))
  url_case("http://2130706433/", Some(["http://127.0.0.1/", "http://127.0.0.1", "/", "", ""]))
  url_case("http://127.0.0.1./", Some(["http://127.0.0.1/", "http://127.0.0.1", "/", "", ""]))
  // IPv6 compression: longest run of >=2 zeros compressed, leftmost on tie
  url_case("http://[0:0:0:0:0:0:0:0]/", Some(["http://[::]/", "http://[::]", "/", "", ""]))
  url_case("http://[0:0:0:0:0:0:0:1]/", Some(["http://[::1]/", "http://[::1]", "/", "", ""]))
  url_case("http://[1:0:0:2:0:0:3:4]/", Some(["http://[1::2:0:0:3:4]/", "http://[1::2:0:0:3:4]", "/", "", ""]))
  url_case("http://[1:0:2:0:0:3:4:5]/", Some(["http://[1:0:2::3:4:5]/", "http://[1:0:2::3:4:5]", "/", "", ""]))
  url_case("http://[1:0:2:3:4:5:6:7]/", Some(["http://[1:0:2:3:4:5:6:7]/", "http://[1:0:2:3:4:5:6:7]", "/", "", ""]))
  url_case("http://[FE80:0000:0000:0000:0202:B3FF:FE1E:8329]/", Some(["http://[fe80::202:b3ff:fe1e:8329]/", "http://[fe80::202:b3ff:fe1e:8329]", "/", "", ""]))
  url_case("http://[::ffff:127.0.0.1]:8080/x", Some(["http://[::ffff:7f00:1]:8080/x", "http://[::ffff:7f00:1]:8080", "/x", "", ""]))
  // Invalid IPv6
  url_case("http://[::1::2]/", None)
  url_case("http://[1:2:3:4:5:6:7]/", None)
  url_case("http://[1:2:3:4:5:6:7:8:9]/", None)
  url_case("http://[gggg::1]/", None)
  url_case("http://[::1/", None)
  url_case("http://[::ffff:999.0.0.1]/", None)
}

///|
test "conformance: WHATWG userinfo, dot segments, percent-encoding, and invalid URLs" {
  // Userinfo with special chars & empty password/username
  url_case("https://user@example.com/", Some(["https://user@example.com/", "https://example.com", "/", "", ""]))
  url_case("https://:pass@example.com/", Some(["https://:pass@example.com/", "https://example.com", "/", "", ""]))
  url_case("https://a:b@c@example.com/", Some(["https://a:b%40c@example.com/", "https://example.com", "/", "", ""]))
  url_case("https://u n:p@example.com/", Some(["https://u%20n:p@example.com/", "https://example.com", "/", "", ""]))
  // Dot segments including %2e variants and trailing dot segments
  url_case("https://example.com/a/b/c/./../../g", Some(["https://example.com/a/g", "https://example.com", "/a/g", "", ""]))
  url_case("https://example.com/a/b/..", Some(["https://example.com/a/", "https://example.com", "/a/", "", ""]))
  url_case("https://example.com/a/b/.", Some(["https://example.com/a/b/", "https://example.com", "/a/b/", "", ""]))
  url_case("https://example.com/../../../a", Some(["https://example.com/a", "https://example.com", "/a", "", ""]))
  url_case("https://example.com/%2e/%2E%2e/a", Some(["https://example.com/a", "https://example.com", "/a", "", ""]))
  // Special vs non-special query percent-encoding (single quote encoded in special query, not non-special)
  url_case("https://example.com/?a='b'", Some(["https://example.com/?a=%27b%27", "https://example.com", "/", "?a=%27b%27", ""]))
  url_case("foo://example.com/?a='b'", Some(["foo://example.com/?a='b'", "null", "/", "?a='b'", ""]))
  // Invalid URLs rejected
  for bad in [
    "",
    "   ",
    "/relative/path",
    "//scheme-relative.example/a",
    "?only-query",
    "#only-hash",
    "1http://example.com/",
    "http://exa[mple.com/",
    "http://example.com:abc/",
    "http://example.com:-1/",
    "http://user@:80/",
    "://missing-scheme.com/",
  ] {
    url_case(bad, None)
  }
}
