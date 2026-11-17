// A chat's speed. `fast` remains the wire field older clients know; an explicit speed takes precedence.
import { key } from "./shapes/model.ts";

export type ModelSpeed = "standard" | "fast" | "ultrafast";

export const modelSpeed = (v: unknown): ModelSpeed | null =>
  v === "standard" || v === "fast" || v === "ultrafast" ? v : null;

export function chosenSpeed(v: { speed?: unknown; fast?: unknown } | null | undefined): ModelSpeed | null {
  return modelSpeed(v?.speed) ?? (v?.fast === true ? "fast" : v?.fast === false ? "standard" : null);
}

// Compatibility for stations and cached account checks from before Codex reported model speed tiers.
const LEGACY_ULTRAFAST_MODELS = ["gpt-6-astra", "gpt-6.1-sol"];

export function ultrafastModel(model: unknown, reported: unknown): boolean {
  if (typeof model !== "string") return false;
  const models = Array.isArray(reported) ? reported : LEGACY_ULTRAFAST_MODELS;
  const wanted = key(model);
  return models.some((id) => typeof id === "string" && key(id) === wanted);
}

/// Omit the new field on records made by clients that only knew the Fast switch.
export function speedFields(v: { speed?: unknown } | null | undefined): { speed?: ModelSpeed } {
  const speed = modelSpeed(v?.speed);
  return speed === null ? {} : { speed };
}
