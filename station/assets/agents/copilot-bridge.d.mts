// The functions of the bridge's (copilot-bridge.mjs) its tests read.
export function callOf(start: unknown): { name: string; args: unknown };
export function resultOf(complete: unknown): string;
export function countsOf(usage: unknown): { inputTokens: number; cacheReadTokens: number; cacheWriteTokens: number; outputTokens: number };
export function refusal(input: unknown, silent: { tools: readonly string[]; slackWrites: readonly string[] }): string | null;
export function ownConfig(dir: unknown): { servers: Record<string, unknown>; skills: string | null };
