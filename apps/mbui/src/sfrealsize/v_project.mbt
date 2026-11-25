// Made by client/core-ts/test/real-size-app.test.ts (REAL_SIZE_WRITE=1): what the core sends `project` whole on a
// workspace of real size.
///|
fn init {
  let asked =
    #|{"topic":"project","scope":"ws","name":"monoid"}
  let value =
    #|{"name":"monoid","note":"still.fail client core and station","refs":["github.com/AFK-surf/monoid"],"chatCount":7,"runningCount":1,"latestActiveAt":1791277140000,"hasInfo":true,"infoRevision":"536f5bcc769d8db8"}
  put(asked, value)
}
