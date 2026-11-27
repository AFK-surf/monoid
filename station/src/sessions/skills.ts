// Skills available to a session or runtime, for composer `/` autocomplete and explicit `/<skill>` invocation delivery.
// Every filesystem read here is async and bounded so the station's main thread never blocks.
import { lstat, open, readdir, realpath, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, join, relative, sep } from "node:path";
import { geminiDir } from "../agents/agy.ts";
import { CLAUDE_DISABLED_SKILLS } from "../agents/claude.ts";
import { copilotHome } from "../agents/copilot.ts";
import { cursorHome } from "../agents/cursor.ts";
import { devinHome } from "../agents/devin.ts";
import { grokHome } from "../agents/grok.ts";
import { hermesHome } from "../agents/hermes.ts";
import { isMachine } from "../agents/profiles.ts";
import { runtimeKind, type Profile, type RuntimeKind } from "../agents/runtime.ts";
import { BUILTIN_SKILLS, FEEDBACK_SKILL, MOVE_SKILL, SKILL_HOMES, agentHomePaths, siteSkills, workspaceAgentHomePath } from "./agent-home.ts";
import { allowedIn } from "./config.ts";
import { presetCopyOf, type PresetDir } from "./presets.ts";
import type { Hub } from "./hub.ts";

export type SkillSource = "session" | "agent" | "workspace" | "project" | "builtin";

export type ListedSkill = {
  name: string;
  description: string;
  source: SkillSource;
  /// For a `session` skill, what people know its folder by: the chat's preset, else its project, else the folder's
  /// name. Absent where none is known (the app then says 工作目录).
  place?: string;
};

export type ResolvedSkill = ListedSkill & {
  path: string;
};

export type ListedSkills = {
  runtime: RuntimeKind | null;
  skills: ListedSkill[];
};

const SOURCE_RANK: Record<SkillSource, number> = {
  session: 0,
  agent: 1,
  workspace: 2,
  project: 3,
  builtin: 4,
};

const BUILTIN_SET = new Set<string>([...BUILTIN_SKILLS, FEEDBACK_SKILL, MOVE_SKILL]);
const PROJECT_MEMORY_PREFIX = "项目记忆：";
const FRONTMATTER_BYTES = 4096;
const CONFIG_BYTES = 64 * 1024;
const MAX_SKILLS = 250;
const MAX_COMMAND_DEPTH = 4;
const MAX_DESCRIPTION_CHARS = 200;
const MAX_INVOCATIONS = 5;

export type ParsedFrontmatter = {
  name?: string;
  description?: string;
  disableSlashCommand?: boolean;
  userInvocable?: boolean;
};

/// Parses YAML frontmatter from the head of a `SKILL.md` or command `.md` file.
/// Supports single-line quoted/unquoted values and YAML folded/literal block scalars (`>`, `>-`, `|`, `|-`).
export function parseSkillFrontmatter(text: string): { frontmatter: ParsedFrontmatter; body: string } {
  const clean = text.startsWith("\uFEFF") ? text.slice(1) : text;
  const match = /^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/.exec(clean);
  if (match === null) return { frontmatter: {}, body: clean };
  const raw = match[1]!;
  const body = clean.slice(match[0].length);
  const lines = raw.split(/\r?\n/);
  const fm: ParsedFrontmatter = {};
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!;
    if (line.trim() === "" || /^\s*#/.test(line)) continue;
    const kv = /^([A-Za-z0-9_-]+)\s*:\s*(.*)$/.exec(line);
    if (kv === null) continue;
    const key = kv[1]!.toLowerCase();
    let val = kv[2]!.trim();
    if (val === ">" || val === ">-" || val === ">+" || val === "|" || val === "|-" || val === "|+") {
      const folded = val.startsWith(">");
      const block: string[] = [];
      let baseIndent = -1;
      while (i + 1 < lines.length) {
        const next = lines[i + 1]!;
        if (next.trim() === "") {
          block.push("");
          i++;
          continue;
        }
        const indent = next.length - next.trimStart().length;
        if (indent === 0) break;
        if (baseIndent < 0) baseIndent = indent;
        block.push(next.slice(Math.min(indent, baseIndent)));
        i++;
      }
      val = folded ? block.map((l) => l.trim()).filter(Boolean).join(" ") : block.join("\n").trim();
    } else if (val === "") {
      // Indented continuation scalar without explicit block marker.
      const cont: string[] = [];
      while (i + 1 < lines.length) {
        const next = lines[i + 1]!;
        if (next.trim() === "" || next.length === next.trimStart().length) break;
        cont.push(next.trim());
        i++;
      }
      val = cont.join(" ");
    } else {
      val = unquoteYaml(val);
    }
    if (key === "name" && val !== "") fm.name = val;
    else if (key === "description" && val !== "") fm.description = val;
    else if (key === "disable-slash-command" || key === "disable_slash_command" || key === "disableslashcommand") {
      fm.disableSlashCommand = val.toLowerCase() === "true";
    } else if (key === "user-invocable" || key === "user_invocable" || key === "userinvocable") {
      fm.userInvocable = val.toLowerCase() !== "false";
    }
  }
  return { frontmatter: fm, body };
}

function unquoteYaml(raw: string): string {
  if (raw.length >= 2 && raw.startsWith('"') && raw.endsWith('"')) {
    return raw.slice(1, -1).replace(/\\(["\\ntr])/g, (_, c: string) => (c === "n" ? " " : c === "t" ? " " : c === "r" ? "" : c));
  }
  if (raw.length >= 2 && raw.startsWith("'") && raw.endsWith("'")) {
    return raw.slice(1, -1).replace(/''/g, "'");
  }
  return raw;
}

function compactDescription(raw: string): string {
  const one = raw.replace(/\s+/g, " ").trim();
  const chars = Array.from(one);
  return chars.length > MAX_DESCRIPTION_CHARS ? `${chars.slice(0, MAX_DESCRIPTION_CHARS - 1).join("").trimEnd()}…` : one;
}

function fallbackDescription(body: string): string {
  for (const rawLine of body.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (line === "") continue;
    const stripped = line.replace(/^#+\s*/, "").trim();
    if (stripped !== "") return compactDescription(stripped);
  }
  return "";
}

async function readHead(path: string, limit = FRONTMATTER_BYTES): Promise<string | null> {
  let fh;
  try {
    fh = await open(path, "r");
    const buf = Buffer.alloc(limit);
    const { bytesRead } = await fh.read(buf, 0, limit, 0);
    return buf.subarray(0, bytesRead).toString("utf8");
  } catch {
    return null;
  } finally {
    await fh?.close().catch(() => {});
  }
}

async function listDir(dir: string): Promise<string[]> {
  return readdir(dir).catch(() => [] as string[]);
}

async function canonical(path: string): Promise<string> {
  return realpath(path).catch(() => path);
}

function isInside(path: string, root: string | null): boolean {
  if (root === null) return false;
  return path === root || path.startsWith(root.endsWith(sep) ? root : root + sep);
}

type Collector = {
  byKey: Map<string, ResolvedSkill>;
  disabled: ReadonlySet<string>;
};

function addSkill(c: Collector, skill: ResolvedSkill): void {
  const name = skill.name.trim();
  if (name === "" || /[\s/\\]/.test(name)) return;
  if (c.disabled.has(name) || c.disabled.has(name.toLowerCase())) return;
  const key = name.toLowerCase();
  const existing = c.byKey.get(key);
  if (existing !== undefined) {
    if (SOURCE_RANK[skill.source] < SOURCE_RANK[existing.source]) {
      c.byKey.set(key, { ...skill, name });
    }
    return;
  }
  if (c.byKey.size >= MAX_SKILLS) return;
  c.byKey.set(key, { ...skill, name });
}

async function scanSkillDir(
  c: Collector,
  dir: string,
  source: SkillSource,
  opts?: {
    skipInside?: (string | null)[];
    classify?: (entryName: string, description: string, realDir: string) => SkillSource;
    overrideNames?: Map<string, string>;
  },
): Promise<void> {
  const entries = (await listDir(dir)).sort();
  for (const entry of entries) {
    if (c.byKey.size >= MAX_SKILLS) break;
    if (entry.startsWith(".")) continue;
    const itemDir = join(dir, entry);
    const skillMd = join(itemDir, "SKILL.md");
    const st = await stat(skillMd).catch(() => null);
    if (!st?.isFile()) continue;
    const realDir = await canonical(itemDir);
    if (opts?.skipInside?.some((root) => isInside(realDir, root))) continue;
    const head = await readHead(skillMd);
    if (head === null) continue;
    const { frontmatter, body } = parseSkillFrontmatter(head);
    if (frontmatter.disableSlashCommand === true || frontmatter.userInvocable === false) continue;
    const name = opts?.overrideNames?.get(entry) ?? frontmatter.name ?? entry;
    const description = compactDescription(frontmatter.description ?? fallbackDescription(body));
    const actualSource = opts?.classify ? opts.classify(entry, description, realDir) : source;
    addSkill(c, { name, description, source: actualSource, path: await canonical(skillMd) });
  }
}

async function scanClaudeCommands(c: Collector, root: string, source: SkillSource): Promise<void> {
  const visited = new Set<string>();
  const walk = async (dir: string, depth: number): Promise<void> => {
    if (depth > MAX_COMMAND_DEPTH || c.byKey.size >= MAX_SKILLS) return;
    const real = await canonical(dir);
    if (visited.has(real)) return;
    visited.add(real);
    const entries = (await listDir(dir)).sort();
    for (const entry of entries) {
      if (c.byKey.size >= MAX_SKILLS) break;
      if (entry.startsWith(".")) continue;
      const full = join(dir, entry);
      const st = await lstat(full).catch(() => null);
      if (st === null) continue;
      const resolved = st.isSymbolicLink() ? await stat(full).catch(() => null) : st;
      if (resolved === null) continue;
      if (resolved.isDirectory()) {
        await walk(full, depth + 1);
        continue;
      }
      if (!resolved.isFile() || !entry.toLowerCase().endsWith(".md")) continue;
      const rel = relative(root, full).replace(/\\/g, "/");
      const fallbackName = rel.slice(0, -3).split("/").filter(Boolean).join(":");
      if (fallbackName === "") continue;
      const head = await readHead(full);
      if (head === null) continue;
      const { frontmatter, body } = parseSkillFrontmatter(head);
      if (frontmatter.disableSlashCommand === true || frontmatter.userInvocable === false) continue;
      const name = frontmatter.name ?? fallbackName;
      const description = compactDescription(frontmatter.description ?? fallbackDescription(body));
      addSkill(c, { name, description, source, path: await canonical(full) });
    }
  };
  await walk(root, 0);
}

async function scanAgyPlugins(c: Collector, gemini: string): Promise<void> {
  const pluginsRoot = join(gemini, "config", "plugins");
  const pluginDirs = (await listDir(pluginsRoot)).sort();
  if (pluginDirs.length === 0) return;
  let pluginConfig: Record<string, { enabled?: unknown }> = {};
  const cfgRaw = await readHead(join(gemini, "config", "config.json"), CONFIG_BYTES);
  if (cfgRaw !== null) {
    try {
      const parsed = JSON.parse(cfgRaw);
      if (parsed && typeof parsed === "object" && parsed.plugins && typeof parsed.plugins === "object") {
        pluginConfig = parsed.plugins as Record<string, { enabled?: unknown }>;
      }
    } catch {}
  }
  for (const dir of pluginDirs) {
    if (c.byKey.size >= MAX_SKILLS) break;
    if (dir.startsWith(".")) continue;
    if (pluginConfig[dir]?.enabled === false) continue;
    const pluginPath = join(pluginsRoot, dir);
    const metaRaw = await readHead(join(pluginPath, "plugin.json"), 16 * 1024);
    if (metaRaw !== null) {
      try {
        if (JSON.parse(metaRaw)?.disabled === true) continue;
      } catch {}
    }
    await scanSkillDir(c, join(pluginPath, "skills"), "agent");
  }
}

export type CollectSkillsOptions = {
  runtime: RuntimeKind | null;
  profile?: Profile | null;
  /// Fallback profile homes allowed in the same workspace (used for Antigravity builtin skills when the chosen profile
  /// has not materialized `antigravity-cli/builtin/skills` yet).
  fallbackAgyHomes?: readonly string[];
  cwd?: string | null;
  workspaceSkillsDir?: string | null;
  presetDirs?: readonly PresetDir[];
  siteSkillsDir?: string | null;
  homeDir?: string;
};

/// Collects all slash-invocable skills visible to a runtime/session, ordered by priority:
/// `session` (cwd / preset dirs) -> `agent` (attached runtime's own skills/commands/plugins/builtins) -> `workspace` -> `project` -> `builtin`.
export async function collectSkills(opts: CollectSkillsOptions): Promise<ResolvedSkill[]> {
  const runtime = opts.runtime;
  const disabled = runtime === "claude" ? CLAUDE_DISABLED_SKILLS : new Set<string>();
  const c: Collector = { byKey: new Map(), disabled };
  const sharedRoot = opts.workspaceSkillsDir ? await canonical(opts.workspaceSkillsDir) : null;
  const siteRoot = opts.siteSkillsDir !== undefined
    ? (opts.siteSkillsDir ? await canonical(opts.siteSkillsDir) : null)
    : (() => {
        const s = siteSkills();
        return s === null ? null : canonical(s);
      })();
  const resolvedSiteRoot = await siteRoot;
  const skipShared = [sharedRoot, resolvedSiteRoot];
  const userHome = opts.homeDir ?? homedir();

  // 1. Session-local skills (cwd and/or preset local folders), skipping symlinks that point to shared workspace skills
  // so those get classified accurately under workspace/project/builtin in step 3.
  if (runtime !== "pi") {
    if (opts.cwd) {
      const cwd = opts.cwd;
      if (runtime === "agy") {
        await scanSkillDir(c, join(cwd, ".agent", "skills"), "session", { skipInside: skipShared });
        await scanSkillDir(c, join(cwd, ".agents", "skills"), "session", { skipInside: skipShared });
      } else if (runtime === "claude") {
        await scanSkillDir(c, join(cwd, ".claude", "skills"), "session", { skipInside: skipShared });
        await scanClaudeCommands(c, join(cwd, ".claude", "commands"), "session");
        await scanSkillDir(c, join(cwd, ".agents", "skills"), "session", { skipInside: skipShared });
      } else if (runtime === "copilot") {
        await scanSkillDir(c, join(cwd, ".github", "skills"), "session", { skipInside: skipShared });
        await scanSkillDir(c, join(cwd, ".agents", "skills"), "session", { skipInside: skipShared });
      } else if (runtime === "cursor") {
        await scanSkillDir(c, join(cwd, ".cursor", "skills"), "session", { skipInside: skipShared });
        await scanSkillDir(c, join(cwd, ".agents", "skills"), "session", { skipInside: skipShared });
      } else if (runtime === "devin") {
        await scanSkillDir(c, join(cwd, ".devin", "skills"), "session", { skipInside: skipShared });
        await scanSkillDir(c, join(cwd, ".agents", "skills"), "session", { skipInside: skipShared });
      } else {
        await scanSkillDir(c, join(cwd, ".agents", "skills"), "session", { skipInside: skipShared });
      }
    }
    if (opts.presetDirs && opts.presetDirs.length > 0) {
      const linked = new Set<string>();
      for (const d of opts.presetDirs) {
        if (d.elsewhere !== undefined || d.path === "") continue;
        for (const home of SKILL_HOMES) {
          const dir = join(d.path, home);
          const entries = (await listDir(dir)).sort();
          const overrides = new Map<string, string>();
          for (const n of entries) {
            if (n.startsWith(".")) continue;
            if (!(await stat(join(dir, n, "SKILL.md")).then((s) => s.isFile(), () => false))) continue;
            const chosen = linked.has(n) ? `${basename(d.path)}-${n}` : n;
            if (linked.has(chosen)) continue;
            linked.add(chosen);
            if (chosen !== n) overrides.set(n, chosen);
          }
          await scanSkillDir(c, dir, "session", { skipInside: skipShared, overrideNames: overrides });
        }
      }
    }
  }

  // 2. Runtime-specific agent skills from the attached runtime's profile home.
  const profileHome = opts.profile?.home ?? null;
  if (runtime === "agy") {
    const primaryGemini = profileHome ? geminiDir(profileHome) : null;
    if (primaryGemini !== null) {
      await scanSkillDir(c, join(primaryGemini, "config", "skills"), "agent", { skipInside: skipShared });
      await scanAgyPlugins(c, primaryGemini);
    }
    const builtinCandidates = [
      ...(primaryGemini !== null ? [join(primaryGemini, "antigravity-cli", "builtin", "skills")] : []),
      ...(opts.fallbackAgyHomes ?? []).map((h) => join(geminiDir(h), "antigravity-cli", "builtin", "skills")),
    ];
    for (const dir of new Set(builtinCandidates)) {
      const entries = await listDir(dir);
      if (entries.length === 0) continue;
      await scanSkillDir(c, dir, "agent", { skipInside: skipShared });
      break;
    }
  } else if (runtime === "claude" && opts.profile) {
    const claudeHome = isMachine(opts.profile) ? join(userHome, ".claude") : opts.profile.home;
    await scanSkillDir(c, join(claudeHome, "skills"), "agent", { skipInside: skipShared });
    await scanClaudeCommands(c, join(claudeHome, "commands"), "agent");
  } else if (runtime === "codex" && profileHome !== null) {
    await scanSkillDir(c, join(profileHome, "skills"), "agent", { skipInside: skipShared });
    await scanSkillDir(c, join(profileHome, "skills", ".system"), "agent", { skipInside: skipShared });
  } else if (runtime === "copilot" && profileHome !== null) {
    await scanSkillDir(c, join(copilotHome(profileHome), "skills"), "agent", { skipInside: skipShared });
  } else if (runtime === "cursor" && profileHome !== null) {
    await scanSkillDir(c, join(cursorHome(profileHome), "skills"), "agent", { skipInside: skipShared });
  } else if (runtime === "grok" && profileHome !== null) {
    await scanSkillDir(c, join(grokHome(profileHome), "skills"), "agent", { skipInside: skipShared });
  } else if (runtime === "devin" && profileHome !== null) {
    await scanSkillDir(c, join(devinHome(profileHome), "skills"), "agent", { skipInside: skipShared });
  } else if (runtime === "hermes" && profileHome !== null) {
    await scanSkillDir(c, join(hermesHome(profileHome), "skills"), "agent", { skipInside: skipShared });
  } else if (runtime === "dsh" && profileHome !== null) {
    await scanSkillDir(c, join(profileHome, "agents", "skills"), "agent", { skipInside: skipShared });
  }

  // 3. Shared workspace, project memory, and station built-in skills.
  if (opts.workspaceSkillsDir) {
    await scanSkillDir(c, opts.workspaceSkillsDir, "workspace", {
      classify: (entryName, description, realDir) => {
        if (BUILTIN_SET.has(entryName) || isInside(realDir, resolvedSiteRoot)) return "builtin";
        if (description.startsWith(PROJECT_MEMORY_PREFIX)) return "project";
        return "workspace";
      },
    });
  }

  return [...c.byKey.values()].sort(
    (a, b) => SOURCE_RANK[a.source] - SOURCE_RANK[b.source] || a.name.toLowerCase().localeCompare(b.name.toLowerCase()),
  );
}

/// Skills as `chat.skills` answers them: `place` named on the session ones.
export const toListed = (skills: readonly ResolvedSkill[], place: string): ListedSkill[] =>
  skills.map(({ name, description, source }) => ({ name, description, source, ...(source === "session" && place !== "" ? { place } : {}) }));

function pickProfileFor(hub: Hub, ws: string | null, runtime: RuntimeKind | null, profileId?: string | null): { profile: Profile | null; fallbackAgyHomes: string[] } {
  const config = hub.config();
  const home = hub.workspaces()[0] ?? null;
  const allowed = config.profiles.filter((p) => p.enabled !== false && allowedIn(p, ws, home));
  const fallbackAgyHomes = runtime === "agy" ? allowed.filter((p) => p.runtimes.includes("agy")).map((p) => p.home) : [];
  if (profileId) {
    const exact = config.profiles.find((p) => p.id === profileId && allowedIn(p, ws, home));
    if (exact !== undefined) return { profile: exact, fallbackAgyHomes };
  }
  if (runtime === null) return { profile: null, fallbackAgyHomes };
  const first = allowed.find((p) => p.runtimes.includes(runtime)) ?? null;
  return { profile: first, fallbackAgyHomes };
}

/// Skills available for an existing session `key`, following its attached runtime, profile, workspace, and preset copy.
export async function skillsForSession(hub: Hub, key: string): Promise<ListedSkills & { resolved: ResolvedSkill[] }> {
  const row = hub.store.getSession(key);
  if (!row) return { runtime: null, skills: [], resolved: [] };
  const runtime = runtimeKind(row.runtime) ?? null;
  const ws = hub.wsOf(key);
  const home = hub.workspaces()[0] ?? null;
  const { profile, fallbackAgyHomes } = pickProfileFor(hub, ws, runtime, row.profile ?? null);
  const cwd = row.cwd ?? row.workspace;
  const workspaceSkillsDir = row.cwd ? null : agentHomePaths(workspaceAgentHomePath(hub.config().agentHome, ws, home))[1];
  // If a preset copy exists on a session that hasn't linked skills into `.agent/skills` yet, its folders are already
  // linked into `.agents/skills` / `.claude/skills`, and `presetCopyOf` covers any unlinked dirs safely.
  const presetCopy = row.cwd ? null : await presetCopyOf(row.workspace).catch(() => null);
  const resolved = await collectSkills({
    runtime,
    profile,
    fallbackAgyHomes,
    cwd,
    workspaceSkillsDir,
    presetDirs: presetCopy?.dirs,
  });
  const place = presetCopy?.name || hub.store.recentSessionThreads(key, 1).threads[0]?.thread.project || (row.cwd ? basename(row.cwd) : "");
  return { runtime, skills: toListed(resolved, place), resolved };
}

/// Skills available for a new chat before a session exists, based on selected runtime, optional preset, and workspace.
export async function skillsForRuntime(
  hub: Hub,
  ws: string | null,
  opts: { runtime?: string | null; preset?: string | null; profile?: string | null },
): Promise<ListedSkills> {
  const runtime = opts.runtime ? (runtimeKind(opts.runtime) ?? null) : null;
  const home = hub.workspaces()[0] ?? null;
  const { profile, fallbackAgyHomes } = pickProfileFor(hub, ws, runtime, opts.profile ?? null);
  const workspaceSkillsDir = agentHomePaths(workspaceAgentHomePath(hub.config().agentHome, ws, home))[1];
  const preset = opts.preset ? await hub.presets.get(ws, opts.preset).catch(() => null) : null;
  const resolved = await collectSkills({
    runtime,
    profile,
    fallbackAgyHomes,
    workspaceSkillsDir,
    presetDirs: preset?.dirs,
  });
  return { runtime, skills: toListed(resolved, preset?.name ?? "") };
}

/// Extracts explicit `/<skill>` tokens written by a person, ignoring fenced code blocks, paths (`a/b`), and URLs.
export function extractSlashInvocations(text: string): string[] {
  if (!text.includes("/")) return [];
  const withoutFences = text.replace(/```[\s\S]*?```/g, " ");
  const out: string[] = [];
  const seen = new Set<string>();
  const re = /(?:^|\s)\/([A-Za-z0-9][A-Za-z0-9_.:-]{0,63})(?=$|\s|[.,!?;:，。！？；：)）\]】」』"'`])/g;
  for (const m of withoutFences.matchAll(re)) {
    const raw = m[1]!;
    const key = raw.toLowerCase();
    if (!seen.has(key)) {
      seen.add(key);
      out.push(key);
    }
  }
  return out;
}

const escapeXmlAttr = (s: string) => s.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

/// Formats `<skill-invocation>` hints for human messages that explicitly invoked one or more resolved skills.
/// Returns `""` when no resolved skill was invoked.
export function formatSkillInvocations(texts: readonly string[], resolved: readonly ResolvedSkill[]): string {
  if (resolved.length === 0) return "";
  const byKey = new Map<string, ResolvedSkill>();
  for (const s of resolved) byKey.set(s.name.toLowerCase(), s);
  const matched: ResolvedSkill[] = [];
  const seen = new Set<string>();
  for (const t of texts) {
    for (const token of extractSlashInvocations(t)) {
      if (seen.has(token)) continue;
      const skill = byKey.get(token);
      if (skill === undefined) continue;
      seen.add(token);
      matched.push(skill);
      if (matched.length >= MAX_INVOCATIONS) break;
    }
    if (matched.length >= MAX_INVOCATIONS) break;
  }
  if (matched.length === 0) return "";
  return matched
    .map(
      (s) =>
        `<skill-invocation name="${escapeXmlAttr(s.name)}" path="${escapeXmlAttr(s.path)}">\nThe user explicitly invoked /${s.name}. Read ${s.path} and follow its instructions for this request.\n</skill-invocation>`,
    )
    .join("\n");
}
