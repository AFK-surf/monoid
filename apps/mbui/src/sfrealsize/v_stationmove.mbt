// Made by client/core-ts/test/real-size-app.test.ts (REAL_SIZE_WRITE=1): what the core sends `stationMove` whole on a
// workspace of real size.
///|
fn init {
  let asked =
    #|{"topic":"stationMove","station":"ws/maple","to":"willow","module":""}
  let value =
    #|{"to":"willow","toName":"Willow","targets":[{"station":"willow","name":"Willow","free":"空闲 180 GB","why":""},{"station":"studio","name":"Studio","free":"空闲 220 GB","why":""},{"station":"cedar","name":"Cedar","free":"空闲 260 GB","why":""},{"station":"ash","name":"Ash","free":"","why":"离线：它上线后可选"}],"canMove":true,"moving":{"module":"chats","item":"k-maple-30","line":"聊天 · 压测 relay：1k 并发连接 · 64 MB / 412 MB","progress":{"done":67108864,"total":432013312,"text":"64 MB / 412 MB"},"stopping":false},"active":true,"title":"迁移到 Willow","count":"41 / 273","note":"2 项失败 · 3 项已停 · 迁移中 · 聊天「压测 relay：1k 并发连接」","allThere":false,"modules":[{"id":"accounts","needs":[],"done":3,"total":6,"count":"3 / 6","mark":"","markText":"","opens":false,"action":"","items":[],"more":false},{"id":"connects","needs":["chats"],"done":0,"total":4,"count":"0 / 4","mark":"","markText":"","opens":false,"action":"","items":[],"more":false},{"id":"repos","needs":[],"done":5,"total":12,"count":"5 / 12","mark":"","markText":"","opens":false,"action":"","items":[],"more":false},{"id":"vault","needs":[],"done":1,"total":2,"count":"1 / 2","mark":"","markText":"","opens":false,"action":"","items":[],"more":false},{"id":"settings","needs":[],"done":0,"total":1,"count":"0 / 1","mark":"","markText":"","opens":false,"action":"","items":[],"more":false},{"id":"chats","needs":["accounts","connects","repos","vault"],"done":30,"total":240,"count":"30 / 240","mark":"moving","markText":"迁移中","opens":true,"action":"","items":[],"more":false},{"id":"jobs","needs":["chats"],"done":2,"total":8,"count":"2 / 8","mark":"","markText":"","opens":false,"action":"","items":[],"more":false}],"nothing":""}
  put(asked, value)
}
