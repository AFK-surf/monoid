// Made by client/core-ts/test/real-size-app.test.ts (REAL_SIZE_WRITE=1): what the core sends `chatSubchats q` whole on a
// workspace of real size.
///|
fn init {
  let asked =
    #|{"topic":"chatSubchats","station":"ws/maple","session":"k-maple-0","q":"迁移"}
  let value =
    #|{"items":[{"station":"ws/maple","session":"k-maple-40","title":"Review #5231：归档策略的默认值","stateText":"已完成","stateLead":"done","foundText":"已按 迁移 方案完成子会话回归验证","foundMarks":[{"from":3,"to":5}]}],"words":["迁移"],"reading":false}
  put(asked, value)
}
