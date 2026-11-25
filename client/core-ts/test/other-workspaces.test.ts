// With `otherWorkspaces` off (设置 › 关于 › 同步所有 workspace), the device links only the stations of the workspaces
// its UIs show (sync.ts `#linksWorkspace`): one switched away from is let go, one switched to linked again, and turning
// the setting back on links every workspace's stations whatever is shown.
import assert from "node:assert/strict";
import { test } from "node:test";
import { call } from "./helpers.ts";
import { base, started } from "./station-fixture.ts";

const S = "ws/st";

test("with otherWorkspaces off, a workspace's stations are linked only while it is in view", async () => {
  const s = await started(base());
  const ui = s.core.connect();
  const open = () => s.streams.filter((x) => !x.closed).length;
  try {
    call(s.core, ui, 1, "client.focus", { visible: true, focused: true, workspace: "ws" });
    await s.host.time.pass(500, 10);
    assert.ok(s.core.inner.stations.link(S), "linked while every workspace is followed");
    assert.equal(open(), 1);

    // Off while ws is in view: ws stays linked, its stream as it was.
    call(s.core, ui, 2, "prefs.set", { otherWorkspaces: "off" });
    await s.host.time.pass(500, 10);
    const before = s.streams.length;
    assert.ok(s.core.inner.stations.link(S), "the workspace in view stays linked");
    assert.equal(open(), 1);

    // Another workspace in view: ws's station is let go and its stream closed.
    call(s.core, ui, 3, "client.focus", { visible: true, focused: true, workspace: "other-ws" });
    await s.host.time.pass(500, 10);
    assert.equal(s.core.inner.stations.link(S), undefined, "a workspace not in view is not linked");
    assert.equal(open(), 0, "its stream is closed");

    // A chat focused there changes nothing (the same workspace still in view).
    call(s.core, ui, 4, "client.focus", { visible: true, focused: true, workspace: "other-ws" });
    await s.host.time.pass(500, 10);
    assert.equal(s.core.inner.stations.link(S), undefined);

    // Back to ws: linked again with a stream of its own.
    call(s.core, ui, 5, "client.focus", { visible: true, focused: true, workspace: "ws" });
    await s.host.time.pass(500, 10);
    assert.ok(s.core.inner.stations.link(S), "linked again once switched to");
    assert.equal(open(), 1);
    assert.ok(s.streams.length > before, "a stream opened anew");

    // On again while another workspace is in view: every workspace's stations linked.
    call(s.core, ui, 6, "client.focus", { visible: true, focused: true, workspace: "other-ws" });
    await s.host.time.pass(500, 10);
    assert.equal(s.core.inner.stations.link(S), undefined);
    call(s.core, ui, 7, "prefs.set", { otherWorkspaces: null });
    await s.host.time.pass(500, 10);
    assert.ok(s.core.inner.stations.link(S), "linked again once every workspace is followed");
  } finally {
    s.core.close();
  }
});

test("with otherWorkspaces off and no UI saying yet, the workspace last open is linked", async () => {
  const s = await started(base());
  const ui = s.core.connect();
  try {
    call(s.core, ui, 1, "prefs.set", { otherWorkspaces: "off", workspace: "other-ws" });
    await s.host.time.pass(500, 10);
    assert.equal(s.core.inner.stations.link(S), undefined, "not the workspace last open");
    call(s.core, ui, 2, "prefs.set", { workspace: "ws" });
    call(s.core, ui, 3, "client.focus", { visible: false, focused: false, workspace: "ws" });
    await s.host.time.pass(500, 10);
    assert.ok(s.core.inner.stations.link(S), "the workspace a UI says, shown or not");
  } finally {
    s.core.close();
  }
});
