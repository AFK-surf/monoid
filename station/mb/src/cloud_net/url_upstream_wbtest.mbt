// Upstream WPT url/resources/urltestdata.json (commit c9fcb443701f254bfea4a3372fdd580a64d1cace, BSD-3-Clause)
// regression tests for station/mb/src/cloud_net/url.mbt.
// Full 562 base=null corpus is also cross-checked live against Node new URL() in station/test/mb-upstream-corpora.test.ts.

///|
test "upstream WPT URL: opaque path trailing space encoding before ? and #" {
  url_case("non-special:opaque  ?hi", Some(["non-special:opaque %20?hi", "null", "opaque %20", "?hi", ""]))
  url_case("non-special:opaque  #hi", Some(["non-special:opaque %20#hi", "null", "opaque %20", "", "#hi"]))
  url_case("non-special:opaque \t\t  \t#hi", Some(["non-special:opaque  %20#hi", "null", "opaque  %20", "", "#hi"]))
}

///|
test "upstream WPT URL: reject U+FFFD / invalid UTF-8 in domain and empty host with colon" {
  url_case("https://\u{FFFD}", None)
  url_case("https://%EF%BF%BD", None)
  url_case("https://\u{FFFD}y", None)
  url_case("https://\u{FFFF}y", None)
  url_case("ftp://example.com%80/", None)
  url_case("ftp://example.com%A0/", None)
  url_case("https://example.com%80/", None)
  url_case("https://example.com%A0/", None)
  url_case("sc://:/", None)
}

///|
test "upstream WPT URL: blob origin inherits inner http/https origin" {
  url_case("blob:https://example.com:443/", Some(["blob:https://example.com:443/", "https://example.com", "https://example.com:443/", "", ""]))
  url_case("blob:http://example.org:88/", Some(["blob:http://example.org:88/", "http://example.org:88", "http://example.org:88/", "", ""]))
  url_case("blob:ftp://example.org/", Some(["blob:ftp://example.org/", "null", "ftp://example.org/", "", ""]))
}
