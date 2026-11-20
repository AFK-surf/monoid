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

///|
test "own_name and author_kind_of normalize legacy names" {
  assert_eq(own_name(jstr("ember")), jstr("chat"))
  assert_eq(own_name(jstr("stillfail")), jstr("chat"))
  assert_eq(own_name(jstr("slack")), jstr("slack"))
  assert_eq(author_kind_of(jstr("agent")), "agent")
  assert_eq(author_kind_of(jstr("ember")), "station")
  assert_eq(author_kind_of(jstr("stillfail")), "station")
  assert_eq(author_kind_of(jstr("station")), "station")
  assert_eq(author_kind_of(jstr("user")), "person")
  assert_eq(author_kind_of(Json::null()), "person")
}

///|
test "letter_of and change_of_column validate stored metadata" {
  let l1 = letter_of(Some(@jsjson.parse("{\"way\":\"in\",\"title\":\"Chat A\",\"link\":\"https://x/1\"}")))
  assert_eq(l1.map(stringify), Some("{\"way\":\"in\",\"title\":\"Chat A\",\"link\":\"https://x/1\"}"))
  let l2 = letter_of_column(jstr("{\"way\":\"out\",\"title\":\"B\",\"link\":123}"))
  assert_eq(l2.map(stringify), Some("{\"way\":\"out\",\"title\":\"B\",\"link\":null}"))
  assert_true(letter_of_column(jstr("{\"way\":\"side\",\"title\":\"B\"}")) is None)
  assert_true(letter_of_column(jstr("not json")) is None)

  assert_true(change_of_column(jstr("{\"was\":{\"a\":1},\"now\":{\"a\":2}}")) is Some(_))
  assert_true(change_of_column(jstr("{\"was\":{}}")) is None)
  assert_true(change_of_column(Json::null()) is None)
}

///|
test "thread_of, session_thread_of, and membership_of map columns" {
  let row : Map[String, Json] = {
    "id": jint(7),
    "surface": jstr("chat"),
    "channel": jstr("CHAT"),
    "thread_ts": jstr("1.0"),
    "created_at": jint(100),
    "connect": jstr("c1"),
  }
  assert_eq(
    thread_of(row).stringify(),
    "{\"id\":7,\"surface\":\"chat\",\"channel\":\"CHAT\",\"threadTs\":\"1.0\",\"createdAt\":100}",
  )
  assert_eq(
    session_thread_of(row).stringify(),
    "{\"thread\":{\"id\":7,\"surface\":\"chat\",\"channel\":\"CHAT\",\"threadTs\":\"1.0\",\"createdAt\":100},\"connect\":\"c1\"}",
  )
  let mem : Map[String, Json] = {
    "thread": jint(7),
    "session": jstr("s1"),
    "connect": jstr("c1"),
    "joined_at": jint(200),
  }
  assert_eq(
    membership_of(mem).stringify(),
    "{\"thread\":7,\"session\":\"s1\",\"connect\":\"c1\",\"joinedAt\":200,\"leftAt\":null}",
  )
}

///|
test "message_of, letter_message_of, entry_of_row, and json_list" {
  assert_eq(json_list([], attachment), Json::null())
  let mrow : Map[String, Json] = {
    "thread": jint(1),
    "n": jint(2),
    "ts": Json::null(),
    "author_kind": jstr("ember"),
    "author": jstr("sys"),
    "text": Json::null(),
    "attachments": jstr("[{\"name\":\"a.png\",\"path\":\"/a.png\",\"size\":10}]"),
    "quotes": jstr("bad"),
    "created_at": jint(50),
    "letter": jstr("{\"way\":\"in\",\"title\":\"T\"}"),
  }
  let m = message_of(mrow)
  assert_eq(m, {
    "agentIdentity": null,
    "thread": 1,
    "n": 2,
    "ts": "",
    "authorKind": "station",
    "author": "sys",
    "text": "",
    "attachments": [{ "name": "a.png", "path": "/a.png", "size": 10 }],
    "quotes": [],
    "createdAt": 50,
    "letter": { "way": "in", "title": "T", "link": null },
  })
  let lm = letter_message_of({
    "thread": jint(1),
    "n": jint(3),
    "ts": jstr("t3"),
    "author_kind": jstr("agent"),
    "author": jstr("bot"),
    "text": jstr("hi"),
    "at": jint(60),
  })
  assert_eq(lm, {
    "agentIdentity": null,
    "thread": 1,
    "n": 3,
    "ts": "t3",
    "authorKind": "agent",
    "author": "bot",
    "text": "hi",
    "attachments": [],
    "quotes": [],
    "declared": null,
    "client": null,
    "createdAt": 60,
    "editedAt": null,
    "apart": true,
  })
  let erow : Map[String, Json] = {
    "thread": jint(1),
    "n": jint(4),
    "kind": jstr("edit"),
    "target": jint(2),
    "author_kind": jstr("person"),
    "author": jstr("u"),
    "text": jstr("edited"),
    "at": jint(70),
    "card": jstr("{\"type\":\"options\"}"),
  }
  let e = entry_of_row(erow)
  assert_eq(e, {
    "thread": 1,
    "n": 4,
    "kind": "edit",
    "target": 2,
    "authorKind": "person",
    "author": "u",
    "text": "edited",
    "attachments": [],
    "quotes": [],
    "runtime": null,
    "card": { "type": "options" },
    "at": 70,
  })
}
