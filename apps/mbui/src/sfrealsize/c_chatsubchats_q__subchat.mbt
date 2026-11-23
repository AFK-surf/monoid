// Made by client/core-ts/test/real-size-app.test.ts (REAL_SIZE_WRITE=1): what the core sends `chatSubchats q` as `subchat`
// happens (real-size-asked.ts CAUSES), each message the ops applied to what it holds, in order.
///|
fn init {
  let asked =
    #|{"topic":"chatSubchats","station":"ws/maple","session":"k-maple-0","q":"迁移"}
  let messages =
    #|[[{"path":["items"],"key":["station","session"],"patch":["ws/maple","k-maple-40"],"ops":[{"path":["foundText"],"set":"已按 迁移 方案完成第 3 轮子会话回归"}]}]]
  put_changes(asked, "subchat", messages)
}
