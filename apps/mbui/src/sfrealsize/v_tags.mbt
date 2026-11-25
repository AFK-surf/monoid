// Made by client/core-ts/test/real-size-app.test.ts (REAL_SIZE_WRITE=1): what the core sends `tags` whole on a
// workspace of real size.
///|
fn init {
  let asked =
    #|{"topic":"tags","scope":"ws"}
  let value =
    #|{"items":[{"name":"bug","chatCount":8},{"name":"feat","chatCount":3},{"name":"docs","chatCount":2},{"name":"perf","chatCount":2}],"total":4}
  put(asked, value)
}
