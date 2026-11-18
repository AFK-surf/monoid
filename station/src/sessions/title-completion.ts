// A text-only completion for a keyed DeepSeek Harness profile whose provider speaks chat completions. It uses the
// profile's own endpoint and key, and never gives the provider tools.
import { DSH_KEY, dshRoute, expandRoute, profileEnv } from "../agents/profiles.ts";
import type { RunOn } from "./accounts.ts";
import { profileFetch } from "../ops/agent-env.ts";

export type TitleCompletion = { endpoint: string; key: string; model: string; headers: Record<string, string> };

export function titleCompletion(profile: RunOn, model: string | null, session: string): TitleCompletion | null {
  if (!profile.runtimes.includes("dsh")) return null;
  const route = dshRoute(profile);
  if (!route || (route.kind === "pi" && route.api !== "openai-completions")) return null;
  const chosen = model ? (profile.spelling(model) ?? model) : profile.model ?? (route.kind === "deepseek" ? "deepseek-v4-flash" : undefined);
  if (!chosen) return null;
  const env = profileEnv(profile, "dsh");
  const key = route.kind === "deepseek" ? env.DEEPSEEK_API_KEY : env[DSH_KEY];
  const base = route.kind === "deepseek" ? "https://api.deepseek.com" : route.baseURL;
  let url: URL;
  try { url = new URL(base); } catch { return null; }
  const local = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  if (!(url.protocol === "https:" || (url.protocol === "http:" && local)) || url.username || url.password || url.search || url.hash) return null;
  const headers = route.kind === "pi" ? expandRoute(route.headers ?? {}, session) : {};
  return { endpoint: `${url.href.replace(/\/+$/, "")}/chat/completions`, key: key === "none" ? "" : key ?? "", model: chosen, headers };
}

export async function completeTitle(config: TitleCompletion, instructions: string, input: string, signal: AbortSignal): Promise<string> {
  try {
    return await completeText(config, { system: instructions, prompt: input, maxTokens: 128 }, signal);
  } catch (e) {
    throw new Error(e instanceof CompletionError ? `title completion ${e.problem}` : (e as Error).message);
  }
}

/// Why a text completion did not come: the provider refused or failed (`failed`), answered more than ANSWER_MOST
/// (`too large`), or with no text (`missing`: none, or tool calls).
export class CompletionError extends Error {
  readonly problem: "failed" | "too large" | "missing";
  readonly status: number | null;
  constructor(problem: "failed" | "too large" | "missing", status: number | null = null) {
    super(`text completion ${problem}${status === null ? "" : ` (${status})`}`);
    this.problem = problem;
    this.status = status;
  }
}

/// The most of a provider's answer read, in bytes.
export const ANSWER_MOST = 256_000;

/// A bounded text completion with the profile's endpoint and key (`titleCompletion`'s): a system text and a prompt in,
/// the answer's text out, `maxTokens` at most, never tools. `fetcher`: how it goes out (the profile's proxy; a test's).
export async function completeText(
  config: TitleCompletion,
  ask: { system?: string | null; prompt: string; maxTokens: number },
  signal: AbortSignal,
  fetcher: typeof profileFetch = profileFetch,
): Promise<string> {
  const headers: Record<string, string> = { ...config.headers, "content-type": "application/json" };
  if (config.key !== "") headers.authorization = `Bearer ${config.key}`;
  const messages = [...(ask.system ? [{ role: "system", content: ask.system }] : []), { role: "user", content: ask.prompt }];
  const body = JSON.stringify({ model: config.model, stream: false, max_tokens: ask.maxTokens, messages });
  const response = await fetcher(config.endpoint, { method: "POST", headers, body, redirect: "manual", signal });
  if (!response.ok) throw new CompletionError("failed", response.status);
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of response.body ?? []) {
    size += chunk.length;
    if (size > ANSWER_MOST) throw new CompletionError("too large");
    chunks.push(Buffer.from(chunk));
  }
  let answer: any;
  try {
    answer = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new CompletionError("missing");
  }
  const text = answer?.choices?.[0]?.message?.content;
  if (typeof text !== "string" || answer?.choices?.[0]?.message?.tool_calls?.length) throw new CompletionError("missing");
  return text;
}
