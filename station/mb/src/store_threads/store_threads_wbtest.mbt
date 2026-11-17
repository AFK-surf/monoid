///|
test "a card restated keeps its keys where they were, integer-like ones first, as JavaScript's spread does" {
  let card = @jsjson.parse("{\"type\":\"text\",\"adb\":{\"reason\":\"r\",\"outcome\":1},\"10\":true}")
  let out = with_outcome(Some(card), "adb", @jsjson.parse("{\"status\":\"granted\"}"))
  inspect(stringify(out), content="{\"10\":true,\"type\":\"text\",\"adb\":{\"reason\":\"r\",\"outcome\":{\"status\":\"granted\"}}}")
  inspect(stringify(with_outcome(None, "vault", Num(2.0))), content="{\"vault\":{\"outcome\":2}}")
  inspect(stringify(with_outcome(Some(Null), "rig", Null)), content="{\"rig\":{\"outcome\":null}}")
}

///|
test "keys by their UTF-8 bytes, as rows.ts byBytes orders a BTreeMap's" {
  let by = (a : String, b : String) => utf8_compare(@jsjson.units(a), @jsjson.units(b))
  inspect(by("a", "b") < 0, content="true")
  inspect(by("Z", "a") < 0, content="true")
  // U+FF21 sorts before U+1F600 in UTF-16 order the other way round; by bytes it is first
  inspect(by("\u{FF21}", "\u{1F600}") < 0, content="true")
  inspect(by("ab", "a") > 0, content="true")
}

///|
test "values joined as JavaScript joins them" {
  inspect(js_text(Json::number(3.0)), content="3")
  inspect(js_text(Json::number(1.5)), content="1.5")
  inspect(js_text(Json::null()), content="")
  inspect(js_text(Json::string("x")), content="x")
}

///|
test "a sort that keeps ties in their order" {
  let xs = [(1, "a"), (0, "b"), (1, "c"), (0, "d")]
  inspect(stable_sort(xs, (a, b) => a.0 - b.0).map(x => x.1), content="[b, d, a, c]")
}

///|
test "an index or table gone, by SQLite's words" {
  inspect(missing_object("no such index: decision_checks_session", ["index"], ["decision_checks_session"]), content="true")
  inspect(missing_object("no such table: main.legacy_decision_time", ["table"], ["legacy_decision_time"]), content="true")
  inspect(missing_object("no such table: legacy_decision_time_x", ["table"], ["legacy_decision_time"]), content="false")
}

///|
test "a choice said in the request's language" {
  inspect(chosen_words("en", "Stop"), content="Chose “Stop”")
  inspect(chosen_words("zh", "Stop"), content="用户选择了「Stop」")
}

///|
test "attachments and quotes kept as serde keeps them" {
  let a = attachment(@jsjson.parse("{\"size\":3,\"path\":\"/p\",\"name\":\"n\",\"x\":1,\"width\":null,\"frames\":2}"))
  inspect(stringify(a), content="{\"name\":\"n\",\"path\":\"/p\",\"size\":3,\"frames\":2}")
  inspect((try Some(attachment(@jsjson.parse("{\"name\":\"n\"}"))) catch { _ => None }) is None, content="true")
  let q = quote(@jsjson.parse("{\"comment\":\"c\",\"text\":\"t\",\"author\":\"a\",\"ts\":\"1\"}"))
  inspect(stringify(q), content="{\"author\":\"a\",\"text\":\"t\",\"comment\":\"c\",\"ts\":\"1\"}")
}
