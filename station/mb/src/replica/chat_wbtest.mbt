///|
test "a chat's reading folds only the records that can be of its chat" {
  // (that chat's rows of the tables a chat is read from, every session, and every deletion: folded)
  for line in [
    "{\"r\":\"threads\",\"row\":{\"id\":7,\"title\":\"t\"}}",
    "{\"r\":\"threads\",\"row\":{\"title\":\"t\",\"id\":7}}",
    "{\"r\":\"entries\",\"row\":{\"thread\":7,\"n\":1}}",
    "{\"r\":\"entries\",\"row\":{\"n\":1,\"thread\":7}}",
    "{\"r\":\"thread_sessions\",\"row\":{\"thread\":7,\"session\":\"chat:a\"}}",
    "{\"r\":\"sessions\",\"row\":{\"key\":\"chat:a\"}}",
    "{\"del\":\"entries\",\"key\":{\"thread\":70,\"n\":1}}",
    "{\"gone\":\"thread\",\"id\":70}",
    "{\"gone\":\"session\",\"key\":\"chat:a\"}",
    // (a record written another way: folded, not taken for one of no use)
    "{\"row\":{\"id\":1},\"r\":\"turns\"}",
    "{\"r\":\"entr",
  ] {
    assert_true(chat_takes(line, "7"), msg=line)
  }
  // (other chats' rows, though their numbers begin or end as its does, or a text says its number; rows of other
  // tables, files and transcripts: not)
  for line in [
    "{\"r\":\"threads\",\"row\":{\"id\":70,\"title\":\"t\"}}",
    "{\"r\":\"threads\",\"row\":{\"id\":17}}",
    "{\"r\":\"threads\",\"row\":{\"id\":8,\"parent_id\":7}}",
    "{\"r\":\"entries\",\"row\":{\"thread\":70,\"n\":7}}",
    "{\"r\":\"entries\",\"row\":{\"thread\":7.5,\"n\":1}}",
    "{\"r\":\"entries\",\"row\":{\"thread\":8,\"text\":\"{\\\"thread\\\":7,\\\"n\\\":1}\"}}",
    "{\"r\":\"thread_sessions\",\"row\":{\"thread\":77,\"session\":\"chat:a\"}}",
    "{\"r\":\"letters\",\"row\":{\"thread\":7,\"n\":1}}",
    "{\"r\":\"turns\",\"row\":{\"id\":\"t\"}}",
    "{\"r\":\"runtime_sessions\",\"row\":{\"session_key\":\"chat:a\",\"id\":\"x\"}}",
    "{\"r\":\"reads\",\"row\":{\"viewer\":\"p@x\",\"thread\":7}}",
    "{\"file\":\"00\",\"size\":1,\"path\":\"/d/f\"}",
    "{\"tr\":\"/d/transcripts/a.jsonl\",\"chunks\":[]}",
    "{\"tr_del\":\"/d/transcripts/a.jsonl\"}",
  ] {
    assert_false(chat_takes(line, "7"), msg=line)
  }
  // (chat 70 asked: its rows, not chat 7's)
  assert_true(chat_takes("{\"r\":\"entries\",\"row\":{\"thread\":70,\"n\":7}}", "70"))
  assert_false(chat_takes("{\"r\":\"entries\",\"row\":{\"thread\":7,\"n\":70}}", "70"))
  // (a number as the export writes it)
  assert_eq(stringify(Num(7.0)), "7")
  assert_eq(stringify(Num(70.0)), "70")
}

///|
test "a text is cut at a character's end, within its bytes" {
  assert_eq(cut_to("short", 16), ("short", false))
  assert_eq(cut_to("abcdef", 4), ("abcd", true))
  // (three bytes a character: two fit in seven, never half of the third)
  let (cut, was) = cut_to("中文字符", 7)
  assert_eq(cut, "中文")
  assert_true(was)
  assert_true(utf8_length(cut) <= 7)
  // (four bytes a character, outside the BMP)
  let (emoji, _) = cut_to("😀😀😀", 9)
  assert_eq(emoji, "😀😀")
}
