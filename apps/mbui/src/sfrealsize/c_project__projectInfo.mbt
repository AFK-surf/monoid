// Made by client/core-ts/test/real-size-app.test.ts (REAL_SIZE_WRITE=1): what the core sends `project` as `projectInfo`
// happens (real-size-asked.ts CAUSES), each message the ops applied to what it holds, in order.
///|
fn init {
  let asked =
    #|{"topic":"project","scope":"ws","name":"monoid"}
  let messages =
    #|[[{"path":["infoRevision"],"set":"24f1e700b0da04f8"},{"path":["note"],"set":"still.fail client core, station and classification"}]]
  put_changes(asked, "projectInfo", messages)
}
