// Made by client/core-ts/test/real-size-app.test.ts (REAL_SIZE_WRITE=1): what the core sends `tags` as `archived`
// happens (real-size-asked.ts CAUSES), each message the ops applied to what it holds, in order.
///|
fn init {
  let asked =
    #|{"topic":"tags","scope":"ws"}
  let messages =
    #|[[{"path":["items"],"key":["name"],"put":{"name":"feat","chatCount":2}},{"path":["items"],"key":["name"],"move":"docs","before":"feat"}]]
  put_changes(asked, "archived", messages)
}
