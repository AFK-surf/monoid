// Made by client/core-ts/test/real-size-app.test.ts (REAL_SIZE_WRITE=1): what the core sends `agentRates` as `rates`
// happens (real-size-asked.ts CAUSES), each message the ops applied to what it holds, in order.
///|
fn init {
  let asked =
    #|{"topic":"agentRates","scope":"ws"}
  let messages =
    #|[[{"path":["rows",0,"rate"],"set":"≈ 30 token/s"},{"path":["rows",1,"rate"],"set":"≈ 29 token/s"},{"path":["rows",2,"rate"],"set":"≈ 28 token/s"},{"path":["rows",3,"rate"],"set":"≈ 27 token/s"},{"path":["rows",4,"rate"],"set":"≈ 26 token/s"},{"path":["rows",5,"rate"],"set":"≈ 25 token/s"},{"path":["rows",6,"rate"],"set":"≈ 24 token/s"},{"path":["rows",7,"rate"],"set":"≈ 23 token/s"},{"path":["rows",8,"rate"],"set":"≈ 22 token/s"},{"path":["rows",9,"rate"],"set":"≈ 21 token/s"},{"path":["rows",10,"rate"],"set":"≈ 20 token/s"},{"path":["rows",11,"rate"],"set":"≈ 19 token/s"},{"path":["rows",12,"rate"],"set":"≈ 18 token/s"},{"path":["rows",13,"rate"],"set":"≈ 17 token/s"},{"path":["rows",14,"rate"],"set":"≈ 16 token/s"},{"path":["rows",15,"rate"],"set":"≈ 15 token/s"},{"path":["rows",16,"rate"],"set":"≈ 14 token/s"},{"path":["rows",17,"rate"],"set":"≈ 13 token/s"},{"path":["rows",18,"rate"],"set":"≈ 12 token/s"},{"path":["rows",19,"rate"],"set":"≈ 11 token/s"},{"path":["total"],"set":"≈ 410 token/s"}]]
  put_changes(asked, "rates", messages)
}
