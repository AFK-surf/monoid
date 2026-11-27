// The `beta` features the station runs (client/core-ts/src/features.ts `station: true`): on where the station is updated
// on the test channel (updates/versions.ts `channelOf`), off on a stable one, never a switch; said in its overview
// (`features`), which is all a device goes by, whatever the device's own channel. What a feature's code runs on the
// station decides by `stationFeature`, so a stable station runs none of it, however it is asked (a device, an agent).
import { Effect, Layer } from "effect";
import { FEATURES, type FeatureId, type FeatureSpec, stationFeatureIds } from "../../client/core-ts/src/features.ts";
import { Parts, Paths, StationConfig } from "./services.ts";
import { channelOf } from "./updates/versions.ts";

/// Whether the station's `beta` feature `id` is on a station updated on `channel`.
export function featureOnChannel(id: FeatureId, channel: string, registry: Record<string, FeatureSpec> = FEATURES): boolean {
  const spec = registry[id];
  return spec !== undefined && spec.stage === "beta" && spec.station === true && channel === "beta";
}

/// Whether the station's `beta` feature `id` is on here (`raw`: config.json, `app`: the station's app directory).
export function stationFeature(id: FeatureId, raw: unknown, app: string, registry: Record<string, FeatureSpec> = FEATURES): boolean {
  return featureOnChannel(id, channelOf(raw, app), registry);
}

/// What the overview's `features` says of features graduated since, for apps from before that still decide by it:
/// moving to another station, on every channel since 2026-11-21 (apps from before offer 迁移 only where it is said).
/// Goes 7 days after the apps that read `move.offered` instead ship.
export const GRADUATED_SAID = ["stationMove"] as const;

/// Those on here, as the overview's `features` says them.
export function stationFeatures(raw: unknown, app: string, registry: Record<string, FeatureSpec> = FEATURES): string[] {
  return [...stationFeatureIds(registry).filter((id) => stationFeature(id as FeatureId, raw, app, registry)), ...GRADUATED_SAID];
}

export const FeaturesLive = Layer.effectDiscard(
  Effect.gen(function* () {
    const parts = yield* Parts;
    const config = yield* StationConfig;
    const { app } = yield* Paths;
    parts.overview("features", () => stationFeatures(config.raw(), app), () => "s");
  }),
);
