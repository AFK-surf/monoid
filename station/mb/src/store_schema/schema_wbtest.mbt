// What the store's opening works out besides its statements, held to what the TypeScript gives for the same input
// (station/src/store/schema.ts `headedFrom`, archive.ts `archivedEntry` and rows.ts `entryColumns`, usage-totals-source.ts's
// renaming).

///|
test "a letter's heading names its chat as headedFrom reads it" {
  let cases = [
    "来自 [chat](https://x/1)：\nbody", "From <https://y/2|other: one>:  \nb", "来自 [a](b)](c d)：", "From plain title:",
    "来自 [t](l)：hello", "x：y：  ", "[a](b)",
  ]
  inspect(
    cases.map(headed_from),
    content=(
      #|[(chat, Some(https://x/1)), (other: one, Some(https://y/2)), ([a](b)](c d), None), (plain title, None), ([t](l)：hello, None), (x：y, None), (a, Some(b))]
    ),
  )
}

///|
test "an archived entry's columns as entryColumns(archivedEntry(line)) writes them" {
  let line = (text : String) => Json::array(archived_columns(@jsjson.parse(text))).stringify()
  inspect(
    line(
      "{\"thread\":1,\"n\":2,\"kind\":\"message\",\"ts\":\"a\",\"authorKind\":\"stillfail\",\"author\":\"x\",\"attachments\":[{\"path\":\"/p\",\"name\":\"n\",\"size\":1,\"frames\":2,\"extra\":3}],\"quotes\":[{\"author\":\"a\",\"text\":\"t\",\"comment\":\"c\",\"role\":\"r\"}],\"options\":[{\"label\":\"A\"}],\"at\":5,\"letter\":\"{\\\"way\\\":\\\"in\\\",\\\"title\\\":\\\"q\\\",\\\"link\\\":7}\",\"change\":{\"was\":{},\"now\":{\"2\":1,\"b\":2,\"1\":0}}}",
    ),
    content=(
      #|[1,2,"message",null,"a","station","x",null,"[{\"name\":\"n\",\"path\":\"/p\",\"size\":1,\"frames\":2}]","[{\"author\":\"a\",\"text\":\"t\",\"comment\":\"c\",\"role\":\"r\"}]",null,null,null,null,"[{\"label\":\"A\"}]",null,5,null,"{\"way\":\"in\",\"title\":\"q\",\"link\":null}","{\"was\":{},\"now\":{\"1\":0,\"2\":1,\"b\":2}}"]
    ),
  )
  inspect(
    line(
      "{\"thread\":1,\"n\":3,\"kind\":\"edit\",\"target\":2,\"authorKind\":\"person\",\"author\":\"y\",\"text\":null,\"at\":6,\"agentIdentity\":{\"b\":1,\"a\":[1.5,null]},\"card\":{\"type\":\"x\"}}",
    ),
    content=(
      #|[1,3,"edit",2,null,"person","y",null,null,null,null,null,null,null,null,"{\"type\":\"x\"}",6,"{\"b\":1,\"a\":[1.5,null]}",null,null]
    ),
  )
  let refused = (text : String) => try {
    ignore(archived_columns(@jsjson.parse(text)))
    "taken"
  } catch {
    Refused(m) => m
    e => "\{e}"
  }
  inspect(refused("{\"kind\":\"x\",\"authorKind\":\"person\"}"), content="unknown entry kind x")
  inspect(refused("{\"kind\":\"message\",\"authorKind\":\"bot\"}"), content="unknown author kind bot")
  inspect(
    refused("{\"kind\":\"message\",\"authorKind\":\"person\",\"attachments\":[{\"name\":\"a\",\"path\":\"p\",\"size\":-1}]}"),
    content="attachment",
  )
}

///|
test "the per-call detail's names given the totals' source's, as /\\busage_detail(?=_|\\b)/g replaces them" {
  inspect(
    renamed_detail("usage_detail usage_detail_x (usage_detail.a) xusage_detail usage_details usage_detail", "s"),
    content="s s_x (s.a) xusage_detail usage_details s",
  )
}

///|
test "a path's directory as node:path's dirname" {
  inspect([dirname("/a/b/stillfail.db"), dirname("stillfail.db"), dirname("/stillfail.db"), dirname("/a/b/")], content=(
    #|[/a/b, ., /, /a]
  ))
}
