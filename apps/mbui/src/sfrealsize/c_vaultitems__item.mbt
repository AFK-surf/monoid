// Made by client/core-ts/test/real-size-app.test.ts (REAL_SIZE_WRITE=1): what the core sends `vaultItems` as `item`
// happens (real-size-asked.ts CAUSES), each message the ops applied to what it holds, in order.
///|
fn init {
  let asked =
    #|{"topic":"vaultItems","workspace":"ws-friends","vault":"v_01JAAAAAAAAAAAAAAAAAAAAAAA"}
  let messages =
    #|[[{"path":["items"],"key":["id"],"put":{"id":"i_01JAAAAAAAAAAAAAAAAAAAAA36","version":1,"at":1791277200,"name":"1Password Connect · 备用","kind":"login","listed":true,"modes":["proxy","env"],"hosts":["api.github.com","github.com","uploads.github.com"],"env":"_PASSWORD_CONNECT_TOKEN","lasts":"once","kindText":"登录","agentText":"允许 agent 申请 · 代理 · 环境变量 · api.github.com · github.com · uploads.github.com","lineText":"代理 · api.github.com · github.com · uploads.github.com · 环境变量 _PASSWORD_CONNECT_TOKEN","howText":"代理 · 限 api.github.com, github.com, uploads.github.com、环境变量","lastsText":"仅一次","shut":[{"key":"username","label":"用户名","value":"••••••••••","secret":false,"mono":false},{"key":"password","label":"密码","value":"••••••••••••","secret":true,"mono":true}]},"before":"i_01JAAAAAAAAAAAAAAAAAAAAA04"}]]
  put_changes(asked, "item", messages)
}
