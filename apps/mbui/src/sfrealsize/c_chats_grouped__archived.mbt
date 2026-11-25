// Made by client/core-ts/test/real-size-app.test.ts (REAL_SIZE_WRITE=1): what the core sends `chats grouped` as `archived`
// happens (real-size-asked.ts CAUSES), each message the ops applied to what it holds, in order.
///|
fn init {
  let asked =
    #|{"topic":"chats","scope":"ws","mine":false,"groupBy":"project"}
  let messages =
    #|[[{"path":["groups"],"key":["key"],"drop":"project:invar"},{"path":["groups"],"key":["key"],"patch":"unclassified","ops":[{"path":["items"],"key":["station","id"],"put":{"id":"k-studio-2","session":"k-studio-2","thread":4002,"title":"Review #5231：归档策略的默认值","agents":[{"runtime":"claude","agentText":"Opus 5.5 · xhigh","maker":{"id":"anthropic"}}],"last":{"seq":42,"by":{"mine":false},"preview":"闪烁是因为第一帧拿不到缓存的列表，骨架和真实内容之间切了一次。改成先读设备上的缓存再决定画什么，录屏里已经看不到闪了。"},"unread":false,"station":"ws/studio","stationName":"Studio","stationEmoji":"🎛️","people":[{"id":"marco@acme.dev","email":"marco@acme.dev","shown":{"name":"Marco Rossi","picture":"https://avatars.slack-edge.com/2026-03-14/714204834_8f3c4a2b9d1e4f07c6a5_192.jpg","mine":false}}],"creator":{"id":"marco@acme.dev"},"peopleText":"Marco Rossi 发起","pinned":false,"swipeArchive":true,"stateText":"已完成","stateLead":"done","stateRest":""},"before":null}]},{"path":["more"],"set":394}]]
  put_changes(asked, "archived", messages)
}
