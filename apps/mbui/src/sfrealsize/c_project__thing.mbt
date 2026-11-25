// Made by client/core-ts/test/real-size-app.test.ts (REAL_SIZE_WRITE=1): what the core sends `project` as `thing`
// happens (real-size-asked.ts CAUSES), each message the ops applied to what it holds, in order.
///|
fn init {
  let asked =
    #|{"topic":"project","scope":"ws","name":"monoid"}
  let messages =
    #|[[{"path":["latestActiveAt"],"set":1791277200650}]]
  put_changes(asked, "thing", messages)
}
