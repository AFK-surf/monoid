// GitHub Copilot driver: one `copilot --acp --stdio` per session (the CLI's own ACP server, like dsh's and Pi's).
// The station speaks ACP to it (acp.ts): sessions, tools, permissions, live steps and the kept transcript are the
// same as any ACP runtime. The CLI is installed by the station's updater (`@github/copilot`).
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { AcpDriver, AcpSession, KeptTranscript, type AcpStart } from "./acp.ts";
import type { Events } from "./own-process.ts";
import { expandRoute, profileEnv, profileModel } from "./profiles.ts";
import { cleanEnv, failureOf, type FailureReason, type OpenOptions } from "./runtime.ts";

type Json = any;

/// Where Copilot keeps a profile (COPILOT_HOME): its session state, its login (headless: settings.json's
/// storeTokenPlaintext), its instructions file.
export const copilotHome = (home: string) => join(home, "copilot");

/// Inherited variables that would let a session use another account, another Copilot home or another provider than its
/// profile's.
const SCRUBBED = [
  "COPILOT_HOME",
  "COPILOT_GITHUB_TOKEN",
  "GH_TOKEN",
  "GITHUB_TOKEN",
  "COPILOT_PROVIDERS_CONFIG",
  "COPILOT_PROVIDER_BASE_URL",
  "COPILOT_PROVIDER_API_KEY",
  "COPILOT_PROVIDER_TYPE",
];

/// The station's instructions as Copilot is given them, with how its MCP tools are named there: the SDK prefixes a
/// server's tools with the server's name (`stillfail-chat_post`), not the `mcp__stillfail__…` another runtime uses.
export const copilotRules = (instructions: string) =>
  `${instructions}${instructions === "" ? "" : "\n\n"}The station's tools (chat_post, chat_state and the others named in these instructions) are MCP tools named stillfail-<tool>: stillfail-chat_post and so on. Call one by that name without listing the server's tools first.`;

/// The profile's GitHub token, when it has one (a fine-grained PAT or an OAuth token: gho_, ghu_, github_pat_).
/// None lets the CLI use the machine's own `copilot login` (development); a station that wants no ambient identity sets one.
export function copilotToken(profile: OpenOptions["profile"]): string | undefined {
  const access = profile.access as { key?: unknown } | undefined;
  const key = typeof access?.key === "string" ? access.key.trim() : "";
  if (key !== "" && key !== "none" && /^(gho_|ghu_|github_pat_)/.test(key)) return key;
  const env = (profile.env as Record<string, unknown> | undefined)?.COPILOT_GITHUB_TOKEN;
  if (typeof env === "string" && env.trim() !== "") return env.trim();
  // The token a sign-in kept (accounts/copilot.ts): a gho_/ghu_ token from GitHub's device grant.
  try {
    const kept = readFileSync(join(copilotHome(profile.home), "github-token"), "utf8").trim();
    if (kept !== "") return kept;
  } catch {}
  return undefined;
}

/// The CLI's own tools, removed from every session: the station gives its agent only the MCP server it passes in
/// session/new, as the other runtimes do. The CLI has no wildcard for MCP tools, so every built-in is excluded.
const BUILTIN_TOOLS = ["bash", "powershell", "list_bash", "list_powershell", "read_bash", "read_powershell", "stop_bash", "stop_powershell", "write_bash", "write_powershell", "apply_patch", "create", "edit", "view", "list_agents", "read_agent", "task", "write_agent", "ask_user", "glob", "grep", "rg", "skill", "web_fetch"].join(",");

export class CopilotDriver extends AcpDriver<CopilotSession> {
  constructor(options: { data: string }) {
    super(options.data);
  }

  runtime(): "copilot" {
    return "copilot";
  }

  /// Every chat model this GitHub account may use: GitHub's Copilot model catalog, as the CLI sees it. The profile's
  /// check offers these, and a chat may pick any of them.
  async models(profile: OpenOptions["profile"]): Promise<string[]> {
    const token = copilotToken(profile);
    if (token === undefined) return [];
    const answer = await fetch("https://api.githubcopilot.com/models", {
      headers: { authorization: `Bearer ${token}`, "copilot-integration-id": "vscode-chat", accept: "application/json" },
    });
    if (!answer.ok) throw new Error(`GitHub Copilot models: ${answer.status}`);
    const body = (await answer.json().catch(() => null)) as Json;
    const data = Array.isArray(body?.data) ? body.data : [];
    return data
      .filter((m: Json) => m?.policy?.state === "enabled" && m?.capabilities?.type === "chat" && typeof m?.id === "string")
      .map((m: Json) => m.id as string);
  }

  protected session(options: OpenOptions, events: Events): CopilotSession {
    return new CopilotSession(this, events, options);
  }

  protected starting(options: OpenOptions, _probe: boolean): AcpStart {
    const home = copilotHome(options.profile.home);
    mkdirSync(home, { recursive: true });
    mkdirSync(join(home, "sessions"), { recursive: true });
    const instructionsDir = join(home, "instructions");
    mkdirSync(instructionsDir, { recursive: true });
    writeFileSync(join(instructionsDir, "stillfail.instructions.md"), copilotRules(options.instructions), { mode: 0o600 });

    const env: Record<string, string> = { ...cleanEnv(SCRUBBED), ...expandRoute(profileEnv(options.profile, "copilot"), options.route) };
    env.COPILOT_HOME = home;
    env.COPILOT_CUSTOM_INSTRUCTIONS_DIRS = instructionsDir;
    const token = copilotToken(options.profile);
    if (token !== undefined) env.COPILOT_GITHUB_TOKEN = token;

    const model = options.model ?? profileModel(options.profile);
    const args = ["--acp", "--stdio", "--no-auto-update", `--excluded-tools=${BUILTIN_TOOLS}`];
    if (model !== undefined && model !== "" && model !== "auto") args.push(`--model=${model}`);
    if (options.effort !== undefined && options.effort !== "") args.push(`--effort=${options.effort}`);
    return { command: "copilot", args, env };
  }

  /// The model was chosen when the CLI started; a later turn's model change is sent through ACP's config option (the
  /// CLI applies it to the session when it supports that, and otherwise keeps the one it has).
  protected async ready(_session: CopilotSession): Promise<void> {}
}

export class CopilotSession extends AcpSession {
  /// The models its `model` config option lists, for a change between turns.
  private models: string[] = [];

  constructor(driver: CopilotDriver, events: Events, options: OpenOptions) {
    super(driver, events, new KeptTranscript("copilot", join(copilotHome(options.profile.home), "sessions")));
    this.model = options.model ?? profileModel(options.profile) ?? null;
  }

  protected classify(text: string): FailureReason {
    return failureOf(text);
  }

  opened(result: Json) {
    super.opened(result);
    const model = (Array.isArray(result?.configOptions) ? result.configOptions : []).find((o: Json) => o?.id === "model");
    if (model === undefined) return;
    if (Array.isArray(model.options)) this.models = model.options.map((o: Json) => o?.value).filter((v: unknown): v is string => typeof v === "string");
    if (typeof model.currentValue === "string" && model.currentValue !== "" && this.model === null) this.model = model.currentValue;
  }

  protected kept() {
    return { models: this.models };
  }

  protected taken(snapshot: Json) {
    this.models = Array.isArray(snapshot.models) ? snapshot.models : [];
  }

  /// Another model between turns: ACP's config option is sent; a CLI that cannot change it keeps the one it started with.
  retune(options: OpenOptions): boolean {
    if (this.turn.closed || this.turn.busy || this.sessionId === "") return false;
    const model = options.model ?? profileModel(options.profile);
    if (model === undefined) return false;
    if (this.models.length > 0 && !this.models.includes(model)) return false;
    this.send("session/set_config_option", { sessionId: this.sessionId, configId: "model", value: model });
    this.model = model;
    return true;
  }
}
