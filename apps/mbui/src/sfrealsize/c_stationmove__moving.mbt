// Made by client/core-ts/test/real-size-app.test.ts (REAL_SIZE_WRITE=1): what the core sends `stationMove` as `moving`
// happens (real-size-asked.ts CAUSES), each message the ops applied to what it holds, in order.
///|
fn init {
  let asked =
    #|{"topic":"stationMove","station":"ws/maple","to":"willow","module":""}
  let messages =
    #|[[{"path":["count"],"set":"42 / 273"},{"path":["modules"],"key":["id"],"patch":"chats","ops":[{"path":["count"],"set":"31 / 240"},{"path":["done"],"set":31}]},{"path":["moving","item"],"set":"k-maple-31"},{"path":["moving","line"],"set":"聊天 · 把 chat 的图片缩略图改成 thumbhash · 104 MB / 412 MB"},{"path":["moving","progress","done"],"set":109051904},{"path":["moving","progress","text"],"set":"104 MB / 412 MB"},{"path":["note"],"set":"2 项失败 · 3 项已停 · 迁移中 · 聊天「把 chat 的图片缩略图改成 thumbhash」"}]]
  put_changes(asked, "moving", messages)
}
