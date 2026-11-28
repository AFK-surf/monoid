// Made by client/core-ts/test/real-size-app.test.ts (REAL_SIZE_WRITE=1): what the core sends `chatPeek` whole on a
// workspace of real size.
///|
fn init {
  let asked =
    #|{"topic":"chatPeek","station":"ws/maple","session":"k-maple-0"}
  let value =
    #|{"id":"k-maple-0","session":"k-maple-0","thread":2012,"title":"Opus 代码评审：列表行高首帧优化 PR #5244","agents":[{"runtime":"claude","agentText":"Claude Code · Opus 5.5"}],"last":{"seq":41,"by":{"mine":false},"preview":"结论 列表掉帧的根因是每一帧都在重新测量行高，已修复并补齐基准。"},"unread":false,"station":"ws/maple","stationName":"Maple","time":{"lastActiveAt":{"ago":"5 小时前","full":"10/6 04:00:00"}},"people":[{"id":"me@x.com","email":"me@x.com","shown":{"name":"左子健","mine":true}}],"decision":{"seq":41,"options":[{"label":"归档"}],"card":{"type":"options","options":[{"label":"归档"}],"vaultAsk":{"name":"stripe","reason":"测试调用","mode":"proxy","hosts":["api.stripe.com"],"saveTargets":[{"id":"personal","name":"个人"}]}}},"xshare":{"to":["ws-labs"],"write":false},"archived":true,"foundMarks":[{"from":0,"to":2}],"tags":["ui"]}
  put(asked, value)
}
