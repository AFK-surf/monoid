// Made by client/core-ts/test/real-size-app.test.ts (REAL_SIZE_WRITE=1): what the core sends `boardDrafts` as `boardDraft`
// happens (real-size-asked.ts CAUSES), each message the ops applied to what it holds, in order.
///|
fn init {
  let asked =
    #|{"topic":"boardDrafts","scope":"ws"}
  let messages =
    #|[[{"path":["drafts",1,"title"],"set":"把 station 的日志轮转改成按天切（改）"}]]
  put_changes(asked, "boardDraft", messages)
}
