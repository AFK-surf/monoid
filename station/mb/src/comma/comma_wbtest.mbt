// What the comma parts work out alone, as the TypeScript they are written from works it out (station/test/mb-comma.test.ts
// holds them to it through the program; these are the cases worth keeping beside the code).

///|
test "day_key folds what is not of a date and pads short days" {
  assert_eq(day_key("2025-10-01"), "2025-10-01")
  assert_eq(day_key("2025-10-01T10:00"), "2025-10-01")
  assert_eq(day_key("2025"), "2025!!!!!!")
  assert_eq(day_key("ab+"), "~~+!!!!!!!")
}

///|
test "classify sorts a row's JSON by its day" {
  assert_eq(classify("{\"day\":\"2025-10-01\"}", false), (1, "2025-10-01"))
  assert_eq(classify("{\"day\":\"2025-10-01\"}", true), (4, "2025-10-01"))
  assert_eq(classify("{\"n\":1}", false), (2, ""))
  assert_eq(classify("{\"n\":1}", true), (5, ""))
  assert_eq(classify("5", false), (2, ""))
  assert_eq(classify("null", false), (3, ""))
  assert_eq(classify("{\"day\":5}", false), (3, ""))
  assert_eq(classify("{broken", false), (3, ""))
}

///|
test "iso_day says a moment's UTC day" {
  assert_eq(iso_day(0.0), "1970-01-01")
  assert_eq(iso_day(1700000000000.0), "2023-11-14")
  assert_eq(iso_day(951782400000.0), "2000-02-29")
  assert_eq(iso_day(-86400000.0), "1969-12-31")
}

///|
test "chat refs made and read" {
  assert_eq(chat_ref(12.0, None), "12")
  assert_eq(chat_ref(12.0, Some("st")), "12@st")
  assert_eq(chat_of("12@st"), Some((12.0, Some("st"))))
  assert_eq(chat_of("12"), Some((12.0, None)))
  assert_eq(chat_of("0"), None)
  assert_eq(chat_of("12@"), None)
  assert_eq(chat_of("x"), None)
  assert_eq(chat_of("5@a\nb"), None)
}

///|
test "a connect's line and its address" {
  assert_eq(comma_line("comma wss://c.example/x abcdefgh"), Some(("https://c.example", "abcdefgh")))
  assert_eq(comma_line("comma http://h:8080/ abcdefgh"), Some(("http://h:8080", "abcdefgh")))
  assert_eq(comma_line("comma https://h:443 abcdefgh"), Some(("https://h", "abcdefgh")))
  assert_eq(comma_line("comma ftp://h abcdefgh"), None)
  assert_eq(comma_line("comma https://h short"), None)
  assert_eq(
    connect_url("https://C.example//", "a b", Some("w 1"), "linux", "x64"),
    "wss://c.example/v1/connect?name=a+b&stillfail_workspace=w+1&os=linux&arch=x64",
  )
  assert_eq(connect_url("http://h:8080", "n", None, "darwin", "arm64"), "ws://h:8080/v1/connect?name=n&os=darwin&arch=arm64")
  assert_eq(connect_url("https://127.1", "n", None, "l", "x"), "wss://127.0.0.1/v1/connect?name=n&os=l&arch=x")
  assert_eq(mask_token("secret-1234"), "••••1234")
  assert_eq(mask_token("abc"), "••••")
  assert_eq(mask_token(""), "")
}

///|
test "base64 both ways, as node reads it" {
  let b = b"\x00\x01\x02hello\xff"
  assert_eq(base64(b), "AAECaGVsbG//")
  assert_eq(unbase64(base64(b)), b)
  assert_eq(unbase64("AA-_\nAA=="), b"\x00\x0f\xbf\x00")
}

///|
test "a connect's credentials, what makes its connection another" {
  let c : ScopedConnect = {
    connect: { id: "c", enabled: true, server: "https://s", token: "t", workspace: None },
    scope: Some("w"),
    scope_version: 2,
  }
  assert_eq(credentials(c), Some("[\"https://s\",\"t\",null,\"w\",2]"))
  assert_eq(credentials({ ..c, connect: { ..c.connect, token: "" } }), None)
}

///|
test "a Task's thread and a Message's ts" {
  assert_eq(thread_ts_of("task-1"), "2063246150.453823")
  assert_eq(seq_ts(12.0), "12.000000")
}

///|
test "rows as the indexes keep them" {
  let rows = stats_rows_of(
    {
      station: None,
      usage: @jsjson.parse(
        "{\"people\":{\"p\":{\"email\":\"a@x\"}},\"rows\":[{\"day\":\"2025-10-02\",\"session\":\"s\",\"person\":\"p\",\"runtime\":\"claude\",\"calls\":1},{\"day\":\"2025-09-01\",\"session\":\"old\",\"runtime\":\"x\"}]}",
      ),
      chats: [],
    },
    "2025-10-01",
  )
  assert_eq(rows.length(), 1)
  for _, row in rows {
    assert_eq(
      row.1,
      "{\"day\":\"2025-10-02\",\"session\":\"s\",\"thread\":null,\"person\":\"a@x\",\"personRef\":\"p\",\"account\":null,\"runtime\":\"claude\",\"model\":null,\"calls\":1,\"cost\":null}",
    )
  }
  let tasks = task_rows_of({
    station: Some("st"),
    usage: Null,
    chats: [
      @jsjson.parse(
        "{\"thread\":3,\"title\":\"T\",\"state\":\"need_human\",\"attention\":{\"kind\":\"need\",\"waitsFor\":[\" A@X \",\"a@x\",\"bad\"]},\"router\":true}",
      ),
    ],
  })
  assert_eq(
    tasks.get("3@st").map(r => r.1),
    Some(
      "{\"task\":\"3@st\",\"title\":\"T\",\"status\":\"needs_review\",\"surface\":\"unknown\",\"created_by\":null,\"created_at\":0,\"last_activity_at\":0,\"runtime\":null,\"model\":null,\"station\":\"st\",\"attention\":\"need\",\"waits_for\":[\"a@x\"],\"router\":true}",
    ),
  )
}

///|
test "a question card" {
  let card = @jsjson.parse("{\"type\":\"options\",\"options\":[{\"label\":\" a \"},{\"label\":\"b\",\"recommended\":true}]}")
  assert_eq(
    question_of(Some(card), "").map(stringify),
    Some(
      "{\"type\":\"question\",\"prompt\":\" a  / b\",\"choices\":[{\"id\":\"o1\",\"label\":\"a\"},{\"id\":\"o2\",\"label\":\"b\",\"recommended\":true}],\"multi_select\":false,\"allow_other\":true}",
    ),
  )
  assert_eq(question_of(Some(@jsjson.parse("{\"type\":\"text\"}")), "x") is None, true)
}
