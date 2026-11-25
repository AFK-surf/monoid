// Made by client/core-ts/test/real-size-app.test.ts (REAL_SIZE_WRITE=1): what the core sends `projects` whole on a
// workspace of real size.
///|
fn init {
  let asked =
    #|{"topic":"projects","scope":"ws"}
  let value =
    #|{"items":[{"name":"monoid","chatCount":7,"runningCount":1,"latestActiveAt":1791277140000,"hasInfo":true},{"name":"invar","chatCount":3,"runningCount":0,"latestActiveAt":1791272220000,"hasInfo":true},{"name":"farview","chatCount":2,"runningCount":0,"latestActiveAt":1791226380000,"hasInfo":false},{"name":"board","chatCount":2,"runningCount":0,"latestActiveAt":1791225600000,"hasInfo":false},{"name":"cue","chatCount":1,"runningCount":0,"latestActiveAt":1791127200000,"hasInfo":false}],"total":5,"unclassifiedCount":397,"crossCount":8}
  put(asked, value)
}
