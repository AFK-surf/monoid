///|
fn url_case(raw : String, want : Array[String]?) -> Unit raise {
  let got = match parse_url(raw) {
    Some(u) => Some([u.href(), u.origin(), u.path, u.search(), u.hash()])
    None => None
  }
  if got != want {
    fail("\{repr(raw)}: \{repr(got)} != \{repr(want)}")
  }
}
