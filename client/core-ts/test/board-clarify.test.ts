// The board's 先理清 (`board.clarify`): a 待派发 draft's words asked of its station, answered as subtasks, and a station
// from before the route answered in words that say to update it.
import assert from "node:assert/strict";
import { test } from "node:test";
import { request } from "../src/ops.ts";
import { answers, call } from "./helpers.ts";
import { started, stationReplies, status } from "./station-fixture.ts";

type J = Record<string, any>;

test("board.clarify posts the draft's words to its station and changes nothing", () => {
  const r = request("board.clarify", { station: "ws/st", words: "加导出" })!;
  assert.deepEqual([r.method, r.path, r.body, r.effect, r.fallback], ["POST", "/board/clarify", { words: "加导出" }, { kind: "none" }, null]);
  assert.ok(r.oldStation && r.oldStation.length > 0);
});

for (const old of [false, true]) {
  test(old ? "a station from before board.clarify is answered with words to update it" : "board.clarify answers the station's tasks", async () => {
    const asked: unknown[] = [];
    const { host, core } = await started(undefined, 0, undefined, (s) => stationReplies(s.host, (req) => {
      if (!req.url.endsWith("/admin/api/board/clarify")) return undefined;
      asked.push(JSON.parse(new TextDecoder().decode(req.body!)));
      return old ? status(404, { error: "no route POST /board/clarify" }) : { tasks: [{ text: "加导出" }, { text: "补测试", after: [0] }] };
    }));
    try {
      const ui = core.connect();
      await host.settle();
      host.takeEmitted();
      call(core, ui, 9, "board.clarify", { station: "ws/st", words: "加导出，顺便补测试" });
      await host.settle();
      const said = answers(host.takeEmitted(), 9) as J;
      assert.deepEqual(asked, [{ words: "加导出，顺便补测试" }]);
      if (old) {
        assert.ok("error" in said);
        assert.match(JSON.stringify(said.error), /(太旧|too old)/);
      } else {
        assert.deepEqual(said.ok, { tasks: [{ text: "加导出" }, { text: "补测试", after: [0] }] });
      }
    } finally {
      core.close();
    }
  });
}
