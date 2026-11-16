// Station-side feature gating (client/core-ts/src/features.ts, updates/versions.ts `channelOf`): pure background
// station capabilities that have no per-device UI switch follow the station's own update channel (`beta` vs `stable`).
import { FEATURES, type FeatureId, type FeatureSpec } from "../../client/core-ts/src/features.ts";
import { channelOf } from "./updates/versions.ts";

/// Whether `beta`-gated feature `id` is active on this station (`raw`: config.json, `app`: the station's app directory).
export function stationFeature(
  id: FeatureId,
  raw: unknown,
  app: string,
  registry: Record<string, FeatureSpec> = FEATURES,
): boolean {
  const spec = registry[id];
  if (spec === undefined || spec.stage !== "beta") return false;
  return channelOf(raw, app) === "beta";
}

/// Whether moving to another station is offered and taken here (move/AGENTS.md): config.json's `move` where it says it
/// (`true` on a stable station too, as apps/mbui/e2e/move.ts sets it; `false` off on a beta one), else the `beta`
/// feature `stationMove` (on beta stations, off on stable ones).
export function stationMoveOn(raw: unknown, app: string): boolean {
  const move = (raw as { move?: unknown } | null | undefined)?.move;
  if (move === true) return true;
  if (move === false) return false;
  return stationFeature("stationMove", raw, app);
}
