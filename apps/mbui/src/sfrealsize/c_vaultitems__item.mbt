// Made by client/core-ts/test/real-size-app.test.ts (REAL_SIZE_WRITE=1): what the core sends `vaultItems` as `item`
// happens (real-size-asked.ts CAUSES), each message the ops applied to what it holds, in order.
///|
fn init {
  let asked =
    #|{"topic":"vaultItems","workspace":"ws-friends","vault":"v_01JAAAAAAAAAAAAAAAAAAAAAAA"}
  let messages =
    #|[[{"path":["items"],"key":["id"],"put":{"id":"i_01JAAAAAAAAAAAAAAAAAAAAA36","version":1,"at":1791277200,"name":"Linear API key","kind":"token","listed":true,"modes":["proxy","env"],"hosts":["api.linear.app"],"env":"LINEAR_API_KEYTOKEN","lasts":"once","kindText":"Token","agentText":"允许 agent 申请 · 代理 · 环境变量 · api.linear.app","lineText":"代理 · api.linear.app · 环境变量 LINEAR_API_KEYTOKEN","howText":"代理 · 限 api.linear.app、环境变量","lastsText":"仅一次","shut":[{"key":"value","label":"值","value":"••••••••••••••••••••","secret":true,"mono":true}]},"before":"i_01JAAAAAAAAAAAAAAAAAAAAA07"}]]
  put_changes(asked, "item", messages)
}
