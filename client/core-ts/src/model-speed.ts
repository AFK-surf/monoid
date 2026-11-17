// A chat's speed. `fast` remains the wire field older clients know; an explicit speed takes precedence.
import { key } from "./shapes/model.ts";

export type ModelSpeed = "standard" | "fast" | "ultrafast";

export const modelSpeed = (v: unknown): ModelSpeed | null =>
  v === "standard" || v === "fast" || v === "ultrafast" ? v : null;

export function chosenSpeed(v: { speed?: unknown; fast?: unknown } | null | undefined): ModelSpeed | null {
  return modelSpeed(v?.speed) ?? (v?.fast === true ? "fast" : v?.fast === false ? "standard" : null);
}

// OpenAI's supported Ultrafast models (https://learn.chatgpt.com/docs/agent-configuration/speed).
export function ultrafastModel(model: unknown): boolean {
  return typeof model === "string" && ["gpt-6-astra", "gpt-6.1-sol"].includes(key(model));
}

/// Omit the new field on records made by clients that only knew the Fast switch.
export function speedFields(v: { speed?: unknown } | null | undefined): { speed?: ModelSpeed } {
  const speed = modelSpeed(v?.speed);
  return speed === null ? {} : { speed };
}
