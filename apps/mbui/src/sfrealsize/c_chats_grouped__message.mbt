// Made by client/core-ts/test/real-size-app.test.ts (REAL_SIZE_WRITE=1): what the core sends `chats grouped` as `message`
// happens (real-size-asked.ts CAUSES), each message the ops applied to what it holds, in order.
///|
fn init {
  let asked =
    #|{"topic":"chats","scope":"ws","mine":false,"groupBy":"project"}
  let messages =
    #|[[{"path":["groups"],"key":["key"],"patch":"project:monoid","ops":[{"path":["items"],"key":["station","id"],"patch":["ws/maple","k-maple-0"],"ops":[{"path":["last","preview"],"set":"好的，我先跑一遍测试再合。"},{"path":["last","seq"],"set":301}]},{"path":["latestActiveAt"],"set":1791277200650}]}]]
  put_changes(asked, "message", messages)
}
