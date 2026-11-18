// Made by client/core-ts/test/real-size-app.test.ts (REAL_SIZE_WRITE=1): what the core sends `lock` as `approved`
// happens (real-size-asked.ts CAUSES), each message the ops applied to what it holds, in order.
///|
fn init {
  let asked =
    #|{"topic":"lock","workspace":"ws"}
  let messages =
    #|[[{"path":["members",1,"groups"],"set":[{"appText":"其他","devices":[{"id":"dev-s2-tablet","kind":"app","label":"ios still.fail · Lina Park 的 iPad Pro","signs":true,"older":false,"mine":false,"renewSoon":false,"recent":false,"lastSeen":1791277200,"usedText":"一天内使用过","removable":false,"nameText":"ios still.fail · Lina Park 的 iPad Pro","fullText":"ios still.fail · Lina Park 的 iPad Pro","metaText":"一天内使用过 · 受信任"}]},{"appText":"macos still.fail 桌面版","devices":[{"id":"dev-s2-mac","kind":"app","label":"macos still.fail 桌面版 · Lina Park 的 MacBook Pro","signs":true,"older":false,"mine":false,"machine":"computer","renewSoon":false,"recent":false,"lastSeen":1791253443,"usedText":"一天内使用过","removable":false,"nameText":"Lina Park 的 MacBook Pro","fullText":"Lina Park 的 MacBook Pro · macos still.fail 桌面版","metaText":"macos still.fail 桌面版 · 一天内使用过 · 受信任"}]},{"appText":"still.fail Android","devices":[{"id":"dev-s2-phone","kind":"app","label":"still.fail Android · Lina Park 的 Pixel 8","signs":true,"older":false,"mine":false,"machine":"phone","renewSoon":false,"recent":false,"lastSeen":1791245524,"usedText":"一天内使用过","removable":false,"nameText":"Lina Park 的 Pixel 8","fullText":"Lina Park 的 Pixel 8 · still.fail Android","metaText":"still.fail Android · 一天内使用过 · 受信任"}]}]},{"path":["signers"],"set":25}]]
  put_changes(asked, "approved", messages)
}
