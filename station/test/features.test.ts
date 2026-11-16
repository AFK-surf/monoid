// The station's `beta` features (src/features.ts): on as the station is updated on the test channel (config.json's
// `updateChannel`, else the CHANNEL its installer wrote), off on stable; moving's own switch said over it either way.
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { stationFeature, stationMoveOn } from "../src/features.ts";

/// An app directory whose installer wrote `channel` (none: an install from before channels).
function app(channel: string | null): string {
  const dir = mkdtempSync(join(tmpdir(), "features-"));
  if (channel !== null) writeFileSync(join(dir, "CHANNEL"), channel);
  return dir;
}

test("a_beta_feature_follows_the_station_s_channel", () => {
  const beta = app("beta");
  const stable = app("stable");
  const before = app(null);
  assert.equal(stationFeature("terminal", {}, beta), true);
  assert.equal(stationFeature("stationMove", {}, beta), true);
  assert.equal(stationFeature("terminal", {}, stable), false);
  // an install from before channels is stable
  assert.equal(stationFeature("terminal", {}, before), false);
  // config.json's updateChannel said over what the installer wrote
  assert.equal(stationFeature("terminal", { updateChannel: "beta" }, stable), true);
  assert.equal(stationFeature("terminal", { updateChannel: "stable" }, beta), false);
  // what is no beta feature is never one here
  assert.equal(stationFeature("board", {}, beta), false);
  assert.equal(stationFeature("chatPage", { updateChannel: "beta" }, beta), false);
});

test("moving_is_on_on_beta_stations_and_where_config_says_so", () => {
  const beta = app("beta");
  const stable = app("stable");
  assert.equal(stationMoveOn({}, beta), true);
  assert.equal(stationMoveOn(null, beta), true);
  assert.equal(stationMoveOn({ move: false }, beta), false);
  assert.equal(stationMoveOn({}, stable), false);
  // apps/mbui/e2e/move.ts's stations, whatever their channel
  assert.equal(stationMoveOn({ move: true }, stable), true);
  assert.equal(stationMoveOn({ move: true, updateChannel: "stable" }, beta), true);
  assert.equal(stationMoveOn({ updateChannel: "beta" }, stable), true);
});
