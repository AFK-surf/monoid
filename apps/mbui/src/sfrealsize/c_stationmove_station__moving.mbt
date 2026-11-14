// Made by client/core-ts/test/real-size-app.test.ts (REAL_SIZE_WRITE=1): what the core sends `stationMove station` as `moving`
// happens (real-size-asked.ts CAUSES), each message the ops applied to what it holds, in order.
///|
fn init {
  let asked =
    #|{"topic":"stationMove","station":"ws/maple","to":"","module":""}
  let messages =
    #|[[{"path":["active"],"set":true},{"path":["count"],"set":"1 / 273"},{"path":["modules"],"key":["id"],"patch":"chats","ops":[{"path":["count"],"set":"1 / 240"},{"path":["done"],"set":1}]}]]
  put_changes(asked, "moving", messages)
}
