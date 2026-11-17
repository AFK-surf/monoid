// Made by client/core-ts/test/real-size-app.test.ts (REAL_SIZE_WRITE=1): what the core sends `stationMove station` whole on a
// workspace of real size.
///|
fn init {
  let asked =
    #|{"topic":"stationMove","station":"ws/maple","to":"","module":""}
  let value =
    #|{"to":"","toName":"","targets":[{"station":"willow","name":"Willow","free":"空闲 180 GB","why":""},{"station":"studio","name":"Studio","free":"空闲 220 GB","why":""},{"station":"cedar","name":"Cedar","free":"空闲 260 GB","why":""},{"station":"ash","name":"Ash","free":"","why":"离线：它上线后可选"}],"canMove":true,"active":false,"title":"迁移到 Willow","count":"0 / 273","note":"","allThere":false,"modules":[{"id":"accounts","needs":[],"done":0,"total":6,"count":"0 / 6","mark":"","markText":"","opens":false,"action":"","items":[],"more":false},{"id":"connects","needs":["chats"],"done":0,"total":4,"count":"0 / 4","mark":"","markText":"","opens":false,"action":"","items":[],"more":false},{"id":"repos","needs":[],"done":0,"total":12,"count":"0 / 12","mark":"","markText":"","opens":false,"action":"","items":[],"more":false},{"id":"vault","needs":[],"done":0,"total":2,"count":"0 / 2","mark":"","markText":"","opens":false,"action":"","items":[],"more":false},{"id":"settings","needs":[],"done":0,"total":1,"count":"0 / 1","mark":"","markText":"","opens":false,"action":"","items":[],"more":false},{"id":"chats","needs":["accounts","connects","repos","vault"],"done":0,"total":240,"count":"0 / 240","mark":"","markText":"","opens":false,"action":"","items":[],"more":false},{"id":"jobs","needs":["chats"],"done":0,"total":8,"count":"0 / 8","mark":"","markText":"","opens":false,"action":"","items":[],"more":false}],"nothing":""}
  put(asked, value)
}
