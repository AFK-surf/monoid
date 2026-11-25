// Made by client/core-ts/test/real-size-app.test.ts (REAL_SIZE_WRITE=1): what the core sends `projects` as `archived`
// happens (real-size-asked.ts CAUSES), each message the ops applied to what it holds, in order.
///|
fn init {
  let asked =
    #|{"topic":"projects","scope":"ws"}
  let messages =
    #|[[{"path":["items"],"key":["name"],"patch":"invar","ops":[{"path":["chatCount"],"set":2},{"path":["latestActiveAt"],"set":1791227160000}]}]]
  put_changes(asked, "archived", messages)
}
