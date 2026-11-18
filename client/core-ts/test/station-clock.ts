// The stations' clock in a core's tests that run the station's own code (station/src/ops/fibers.ts `wall`): one mock
// for a test file, whichever worlds it builds, each telling it the core's clock as it starts (`stationClock`).
import { mock } from "node:test";
import { wall } from "../../../station/src/ops/fibers.ts";

let clock = () => 0;
mock.method(wall, "now", () => clock());

export const stationClock = (now: () => number): void => {
  clock = now;
};
