// A workspace's apps as its devices use them (apps/registry.ts): the list, one app's source (its current version, or
// one by `?rev=`), its versions, a version made current again (POST …/current), its documents read, written and
// deleted, and a completion its widget asks of the model of the chat it is shown in (POST …/llm: its profile's
// provider with its key, or one text-only turn of its Claude Code or Codex login; apps/completion.ts). Reads are every
// member's; writes are those of a member who may write (a read-only one is refused here as by the admin API). What
// changes is told on the event stream (`app`, `app-doc`) by the registry, to the app's workspace.
import { type Answer, type Request, error, ok, param, segment } from "../request.ts";
import type { Route } from "../admin.ts";
import { readOnly } from "../../mesh/credential.ts";
import { AppRefused, type Apps } from "../../apps/registry.ts";
import { CompletionError, type TitleCompletion, completeText } from "../../sessions/title-completion.ts";
import type { profileFetch } from "../../ops/agent-env.ts";
import { RuntimeTextError } from "../../sessions/text-runtime.ts";

/// The most of a widget's prompt and system text, in bytes; the tokens an answer takes by default and at most.
export const PROMPT_MOST = 32 * 1024;
export const SYSTEM_MOST = 8 * 1024;
export const TOKENS_DEFAULT = 512;
export const TOKENS_MOST = 4096;
/// A completion's answer waited for so long at most; so many at once a workspace.
export const LLM_WAIT_MS = 60_000;
export const LLM_AT_ONCE = 4;
/// A request's body so large at most (a document's JSON, a prompt, with room for its wrapping).
const BODY_MOST = 128 * 1024;

/// What a widget asks of the model.
export type AppAsk = { system: string | null; prompt: string; maxTokens: number };

/// The completion the chat of session `key` can make for a widget shown in it: its workspace and its profile's
/// endpoint (a keyed provider), or a text-only turn of the profile's own runtime (`runtime`, Claude Code or Codex:
/// `complete` runs it, ended once it answers or `signal` is aborted); or why it cannot (its words say what to do
/// next); null where there is no such session.
export type AppCompletion =
  | { ws: string; config: TitleCompletion }
  | { ws: string; runtime: "claude" | "codex"; complete(ask: AppAsk, signal: AbortSignal): Promise<string> }
  | { ws: string; refusal: string };

const RUNTIME_NAME = { claude: "Claude Code", codex: "Codex" } as const;

export type AppRouteDeps = {
  apps: Apps;
  completion(session: string): AppCompletion | null;
  /// How a completion goes out (the profile's proxy; a test's provider).
  fetcher?: typeof profileFetch;
  /// The deadline a completion is given (a test's, to end one at its moment).
  deadline?: () => AbortSignal;
};

const READ_ONLY = "a read-only member does not change an app: ask an owner or admin of the workspace to make you a member who may write";

function body(r: Request): Record<string, unknown> {
  if (r.body.length > BODY_MOST) throw new AppRefused(413, `the request is over ${BODY_MOST} bytes`);
  try {
    const v = JSON.parse(r.body.toString("utf8") || "{}");
    return v !== null && typeof v === "object" && !Array.isArray(v) ? v : {};
  } catch {
    throw new AppRefused(400, "the request's body is not JSON");
  }
}

const whole = (v: unknown): number | null => (typeof v === "number" && Number.isSafeInteger(v) ? v : null);

export function routes({ apps, completion, fetcher, deadline: within }: AppRouteDeps): Route[] {
  const running = new Map<string, number>();
  const answer = async (f: () => unknown | Promise<unknown>): Promise<Answer> => {
    try {
      return ok(await f());
    } catch (e) {
      if (e instanceof AppRefused) return error(e.status, e.message);
      return error(500, (e as Error).message);
    }
  };
  const writer = (r: Request) => {
    if (readOnly(r.viewer)) throw new AppRefused(403, READ_ONLY);
  };
  const by = (r: Request) => r.viewer.email || r.viewer.sub;
  const id = (raw: string) => segment(raw);

  return [
    { method: "GET", pattern: /^\/*apps$/, handle: async (r) => answer(() => ({ apps: apps.list(r.viewer.workspace) })) },
    {
      method: "GET",
      pattern: /^\/*apps\/+([^/]+)$/,
      handle: async (r, [raw]) =>
        answer(() => {
          const asked = param(r, "rev");
          const rev = asked === undefined || asked === "" ? null : Number(asked);
          if (rev !== null && !(Number.isSafeInteger(rev) && rev >= 1)) throw new AppRefused(400, "rev must be a version's number (1, 2, …): GET /apps/<id>/versions lists them");
          const { source, ...meta } = apps.get(r.viewer.workspace, id(raw!), rev);
          return { ...meta, source: meta.kind === "mbui" ? Buffer.from(source).toString("utf8") : Buffer.from(source).toString("base64") };
        }),
    },
    { method: "GET", pattern: /^\/*apps\/+([^/]+)\/+versions$/, handle: async (r, [raw]) => answer(() => apps.versions(r.viewer.workspace, id(raw!))) },
    {
      method: "POST",
      pattern: /^\/*apps\/+([^/]+)\/+current$/,
      handle: async (r, [raw]) =>
        answer(() => {
          writer(r);
          const i = body(r);
          const rev = whole(i.rev);
          if (rev === null) throw new AppRefused(400, "rev is required: the version to make current (GET /apps/<id>/versions lists them)");
          const m = apps.publish(r.viewer.workspace, { id: id(raw!), rev, by: by(r), force: i.force === true, note: typeof i.note === "string" ? i.note : undefined });
          return { id: m.id, rev: m.rev, current: m.current };
        }),
    },
    {
      method: "GET",
      pattern: /^\/*apps\/+([^/]+)\/+docs\/+([^/]+)$/,
      handle: async (r, [raw, coll]) => answer(() => ({ docs: apps.docs(r.viewer.workspace, id(raw!), segment(coll!)) })),
    },
    {
      method: "PUT",
      pattern: /^\/*apps\/+([^/]+)\/+docs\/+([^/]+)\/+([^/]+)$/,
      handle: async (r, [raw, coll, doc]) =>
        answer(() => {
          writer(r);
          const i = body(r);
          if (!("data" in i)) throw new AppRefused(400, "data is required: the document's JSON");
          const base = i.base === undefined || i.base === null ? null : whole(i.base);
          if (i.base !== undefined && i.base !== null && base === null) throw new AppRefused(400, "base must be the document's rev it was read at (0: new)");
          return apps.putDoc(r.viewer.workspace, { app: id(raw!), collection: segment(coll!), id: segment(doc!), data: i.data, by: by(r), base });
        }),
    },
    {
      method: "DELETE",
      pattern: /^\/*apps\/+([^/]+)\/+docs\/+([^/]+)\/+([^/]+)$/,
      handle: async (r, [raw, coll, doc]) =>
        answer(() => {
          writer(r);
          apps.deleteDoc(r.viewer.workspace, { app: id(raw!), collection: segment(coll!), id: segment(doc!) });
          return { deleted: true };
        }),
    },
    {
      method: "POST",
      pattern: /^\/*apps\/+([^/]+)\/+llm$/,
      handle: async (r, [raw]) =>
        answer(async () => {
          writer(r);
          const ws = r.viewer.workspace;
          const app = id(raw!);
          apps.meta(ws, app);
          const i = body(r);
          const session = typeof i.session === "string" ? i.session : "";
          if (session === "") throw new AppRefused(400, "session is required: the key of the chat the widget is shown in");
          const prompt = typeof i.prompt === "string" ? i.prompt : "";
          if (prompt.trim() === "") throw new AppRefused(400, "prompt is required");
          if (Buffer.byteLength(prompt) > PROMPT_MOST) throw new AppRefused(413, `prompt is over ${PROMPT_MOST} bytes: send less of it`);
          const system = typeof i.system === "string" && i.system !== "" ? i.system : null;
          if (system !== null && Buffer.byteLength(system) > SYSTEM_MOST) throw new AppRefused(413, `system is over ${SYSTEM_MOST} bytes: send less of it`);
          const asked = i.max_tokens === undefined || i.max_tokens === null ? TOKENS_DEFAULT : whole(i.max_tokens);
          if (asked === null || asked < 1) throw new AppRefused(400, "max_tokens must be a whole number ≥ 1");
          const c = completion(session);
          // (a chat of another workspace is not there for this member, as one that is not)
          if (c === null || c.ws !== ws) throw new AppRefused(404, `no chat ${session} in this workspace on this station: show the app in a chat of this workspace and ask from there`);
          if ("refusal" in c) throw new AppRefused(422, c.refusal);
          const now = running.get(ws) ?? 0;
          if (now >= LLM_AT_ONCE) throw new AppRefused(429, `${LLM_AT_ONCE} completions of this workspace's apps are under way: try again once one is answered`);
          running.set(ws, now + 1);
          // timer: a deadline on the provider's answer (the network's time); a runtime's turn is ended at it.
          const deadline = within ? within() : AbortSignal.timeout(LLM_WAIT_MS);
          const signal = r.signal ? AbortSignal.any([r.signal, deadline]) : deadline;
          try {
            const ask = { system, prompt, maxTokens: Math.min(asked, TOKENS_MOST) };
            const text = "config" in c ? await completeText(c.config, ask, signal, fetcher) : await c.complete(ask, signal);
            return { text };
          } catch (e) {
            if (deadline.aborted) throw new AppRefused(504, `the model did not answer in ${LLM_WAIT_MS / 1000} s: try again, or ask for a shorter answer`);
            if ("runtime" in c) throw runtimeRefusal(RUNTIME_NAME[c.runtime], e as Error);
            if (e instanceof CompletionError) {
              throw new AppRefused(502, e.problem === "failed" ? `the model's provider refused or failed${e.status === null ? "" : ` (${e.status})`}: check the chat's profile (its key, its quota), or try again later` : e.problem === "too large" ? "the model's answer was too large: ask for a shorter one (max_tokens)" : "the model gave no text: ask again, or for text only");
            }
            throw new AppRefused(502, `the model's provider was not reached (${(e as Error).message}): check the station's network, or try again later`);
          } finally {
            const left = (running.get(ws) ?? 1) - 1;
            if (left <= 0) running.delete(ws);
            else running.set(ws, left);
          }
        }),
    },
  ];
}

/// Why a text-only turn of the chat's Claude Code or Codex gave no text, and what to do.
function runtimeRefusal(name: string, e: Error): AppRefused {
  if (!(e instanceof RuntimeTextError)) {
    return new AppRefused(502, `${name} could not be started for the app (${e.message}): check that ${name} is installed and signed in on this station (the profile's settings), or try again later`);
  }
  const detail = e.detail === "" ? "" : ` (${e.detail})`;
  switch (e.problem) {
    case "failed": return new AppRefused(502, `${name} failed to answer${detail}: check the chat's profile (its sign-in, its quota), or try again later`);
    case "tool": return new AppRefused(502, "the model tried to use a tool, which an app's model has none of: ask it for text only");
    case "too large": return new AppRefused(502, "the model's answer was too large: ask for a shorter one");
    case "closed": return new AppRefused(502, `${name} ended before it answered${detail}: check that it is installed and signed in on this station, or try again`);
    case "aborted": return new AppRefused(502, "the completion was called off before it was answered: ask again");
  }
}
