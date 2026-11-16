// Features not yet rolled out to everyone: either on the test channel alone (`beta`: enabled on beta, hidden on
// stable, never listed in 设置 › 实验性功能), or behind a per-device switch in 设置 › 实验性功能 (`experimental`: off by
// default on both channels; `betaOnly` shows its switch on the test channel alone). Once a feature graduates (or is
// dropped), delete its entry here and its branches in the code; scripts/features-check.ts refuses any drift or stray
// reference.

export type FeatureStage = "beta" | "experimental";

export interface FeatureSpec {
  readonly stage: FeatureStage;
  readonly betaOnly?: boolean;
}

export const FEATURES = {
  chatPage: { stage: "experimental" },
  farviewNative: { stage: "experimental" },
  board: { stage: "experimental" },
  terminal: { stage: "beta" },
  stationMove: { stage: "beta" },
} as const satisfies Record<string, FeatureSpec>;

export type FeatureId = keyof typeof FEATURES;

export const FEATURE_IDS = Object.keys(FEATURES) as FeatureId[];

function isObj(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

export function isExperimentalFeature(id: string): id is FeatureId {
  return Object.prototype.hasOwnProperty.call(FEATURES, id) && FEATURES[id as FeatureId].stage === "experimental";
}

/// Experimental switches turned on on this device (`prefs.experimental`), ignoring unknown or graduated ids and
/// preserving the earlier `prefs.chatPage === "nodes"` choice where `experimental.chatPage` has not been set.
export function experimentalOf(prefs: unknown, registry: Record<string, FeatureSpec> = FEATURES): Record<string, boolean> {
  const out: Record<string, boolean> = {};
  const raw = isObj(prefs) && isObj(prefs.experimental) ? prefs.experimental : null;
  if (raw !== null) {
    for (const key of Object.keys(raw)) {
      if (Object.prototype.hasOwnProperty.call(registry, key) && registry[key]!.stage === "experimental" && raw[key] === true) {
        out[key] = true;
      }
    }
  }
  if (
    Object.prototype.hasOwnProperty.call(registry, "chatPage") &&
    registry.chatPage!.stage === "experimental" &&
    (raw === null || !Object.prototype.hasOwnProperty.call(raw, "chatPage")) &&
    isObj(prefs) &&
    prefs.chatPage === "nodes"
  ) {
    out.chatPage = true;
  }
  return out;
}

/// Whether feature `id` is enabled on this device (`testChannel`: host.testChannel()).
export function featureEnabled(
  id: FeatureId,
  prefs: unknown,
  testChannel: boolean,
  registry: Record<string, FeatureSpec> = FEATURES,
): boolean {
  const spec = registry[id];
  if (spec === undefined) return false;
  if (spec.stage === "beta") return testChannel;
  if (spec.betaOnly === true && !testChannel) return false;
  return experimentalOf(prefs, registry)[id] === true;
}

/// Effective boolean state of every registered feature on this device.
export function featuresOf(
  prefs: unknown,
  testChannel: boolean,
  registry: Record<string, FeatureSpec> = FEATURES,
): Record<string, boolean> {
  const exp = experimentalOf(prefs, registry);
  const out: Record<string, boolean> = {};
  for (const id of Object.keys(registry)) {
    const spec = registry[id]!;
    out[id] = spec.stage === "beta" ? testChannel : (spec.betaOnly === true && !testChannel ? false : exp[id] === true);
  }
  return out;
}

/// Items visible in 设置 › 实验性功能 on this channel, in registry order (empty when none: the settings row hides).
export function experimentalItemsOf(
  prefs: unknown,
  testChannel: boolean,
  registry: Record<string, FeatureSpec> = FEATURES,
): { id: string; enabled: boolean }[] {
  const exp = experimentalOf(prefs, registry);
  const out: { id: string; enabled: boolean }[] = [];
  for (const id of Object.keys(registry)) {
    const spec = registry[id]!;
    if (spec.stage === "experimental" && (spec.betaOnly !== true || testChannel)) {
      out.push({ id, enabled: exp[id] === true });
    }
  }
  return out;
}
