// Made by client/core-ts/test/real-size-app.test.ts (REAL_SIZE_WRITE=1): what the core sends `workspaceMarks` as `card`
// happens (real-size-asked.ts CAUSES), each message the ops applied to what it holds, in order.
///|
fn init {
  let asked =
    #|{"topic":"workspaceMarks"}
  let messages =
    #|[[{"path":["workspaces","ws","items"],"key":["station","thread","session"],"move":["ws/maple",2006,"k-maple-6"],"before":["ws/maple",1001,"k-maple-0"]},{"path":["workspaces","ws","items"],"key":["station","thread","session"],"patch":["ws/maple",2006,"k-maple-6"],"ops":[{"path":["at"],"set":1791277200650},{"path":["kind"],"set":"wait"},{"path":["seq"],"set":47},{"path":["what"],"set":"需要你决定：周六上午 9 点做生产库迁移可以吗？"}]},{"path":["workspaces","ws","label"],"set":"86 个待你处理 · 37 个有新消息"},{"path":["workspaces","ws","unread"],"set":37},{"path":["workspaces","ws","wait"],"set":86},{"path":["workspaces","ws-friends","othersLabel"],"set":"其他 workspace：86 个待你处理 · 37 个有新消息"},{"path":["workspaces","ws-labs","othersLabel"],"set":"其他 workspace：86 个待你处理 · 37 个有新消息"}]]
  put_changes(asked, "card", messages)
}
