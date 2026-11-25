// The agents' home: one MEMORY.md and one skills/ directory used by every
// profile of every runtime. It lives in the data dir, not the repository, since it holds team-specific memory. A
// workspace the station joined has its own, beside it (`workspaceAgentHome`). A session is
// given its workspace's, not through the profile's home (a profile serves every workspace): the memory with its
// instructions, the skills linked where it runs (`sessionSkills`). The station's own skills are written into each at
// start. Their text is src/skills/*.md (with the scripts some bring in src/skills/<name>/), read from there when running from source and from dist/skills/ (copied there by
// the build) when bundled.
import { link as hardLink, lstat, mkdir, open, readFile, readdir, readlink, realpath, rename, rm, stat, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { RUNTIME_KINDS } from "../agents/runtime.ts";
import { link } from "../ops/links.ts";
import { log } from "../ops/log.ts";
import { within } from "../ops/paths.ts";
import { sharedTranscripts, transcriptDir } from "../read/transcript.ts";
import type { Runtime } from "./config.ts";

export const agentHomePaths = (agentHome: string): [string, string] => [join(agentHome, "MEMORY.md"), join(agentHome, "skills")];

/// Where the agent home of workspace `ws` is, nothing looked at on the disk: the home workspace's (`home`; null outside
/// any, when there is no telling) is the agent home itself, a joined one's workspaces/<ws> in it, which may not be made
/// yet (`workspaceAgentHome` makes it). A session is given its workspace's; the station shares the home workspace's
/// skills only (share/index.ts).
export function workspaceAgentHomePath(agentHome: string, ws: string | null, home: string | null): string {
  if (ws === null || home === null || ws === home) return agentHome;
  if (!/^[0-9A-Za-z_-]{1,128}$/.test(ws)) throw new Error(`not a workspace id: ${JSON.stringify(ws)}`);
  return join(agentHome, "workspaces", ws);
}

/// The joined workspaces' agent homes being made, by path: two asking at once wait for one making.
const making = new Map<string, Promise<void>>();

/// The agent home of workspace `ws` (`workspaceAgentHomePath`), a joined one's made when it is missing: its MEMORY.md and
/// skills/, the station's own skills in it as the home workspace has them. Off the station's thread.
export async function workspaceAgentHome(agentHome: string, ws: string | null, home: string | null): Promise<string> {
  const dir = workspaceAgentHomePath(agentHome, ws, home);
  if (dir === agentHome) return dir;
  let made = making.get(dir);
  if (made === undefined) {
    made = makeAgentHome(agentHome, dir).finally(() => making.delete(dir));
    making.set(dir, made);
  }
  await made;
  return dir;
}

async function makeAgentHome(agentHome: string, dir: string): Promise<void> {
  const [memory, skills] = agentHomePaths(dir);
  // (skills/ there without MEMORY.md: made by something that only links into it, share/index.ts, before this did)
  const [hasSkills, hasMemory] = await Promise.all([there(skills), there(memory)]);
  if (hasSkills && hasMemory) return;
  await mkdir(skills, { recursive: true });
  const shared = agentHomePaths(agentHome)[1];
  await writeBuiltinSkills(dir, await there(join(shared, FEEDBACK_SKILL)), siteSkills(), await there(join(shared, MOVE_SKILL)));
  // (not over one written meanwhile: the memory brought here by another station)
  if (!hasMemory) await writeFile(memory, "# still.fail memory\n", { flag: "wx" }).catch((error: NodeJS.ErrnoException) => { if (error.code !== "EEXIST") throw error; });
}

/// The agent home and those of the workspaces the station joined (made so far).
export async function agentHomes(agentHome: string): Promise<string[]> {
  const joined: string[] = [];
  for (const ws of await entries(join(agentHome, "workspaces"))) if (await realDir(join(agentHome, "workspaces", ws))) joined.push(join(agentHome, "workspaces", ws));
  return [agentHome, ...joined];
}

/// The skills the station brings, by directory name: about its own tools, so they are rewritten at every start and
/// change with the station (the team's own skills sit beside them).
export const BUILTIN_SKILLS = ["stillfail-chats", "stillfail-jobs", "stillfail-show", "stillfail-viz", "stillfail-browser", "stillfail-login", "stillfail-vault", "stillfail-cron", "stillfail-github-ci", "stillfail-move", "stillfail-leading", "stillfail-projects"];
/// Skills the station brought before and brings no longer: stillfail-retire (its tool, station_retire, is switched
/// off and hidden; station_move took its place). A copy left untouched (its SKILL.md alone) is taken away at every
/// start, one someone added to stays; the names stay among the station's own for the shared memory (share/memory.ts
/// `BUILTIN`), so a copy left on a station from before is never synced to the others as a team skill.
export const RETIRED_SKILLS = ["stillfail-retire"];
/// When to offer a bug report to the still.fail team: only from a station on the stable channel, beside the
/// `feedback_send` tool; gone from one on the test channel (the team's own).
export const FEEDBACK_SKILL = "stillfail-feedback";

/// Where the skills' text is.
const skillsSource = (): URL => (import.meta.url.endsWith(".ts") ? new URL("../../assets/skills/", import.meta.url) : new URL("./skills/", import.meta.url));

/// A built-in skill as the station has it: its SKILL.md and the files it brings beside it (scripts it runs, from
/// src/skills/<name>/: none for most). Read once a process: they change only with the station.
const builtins = new Map<string, Promise<{ text: string; files: [string, Buffer][] }>>();
function builtinSkill(name: string): Promise<{ text: string; files: [string, Buffer][] }> {
  let held = builtins.get(name);
  if (held === undefined) {
    held = (async () => {
      const text = await readFile(new URL(`${name}.md`, skillsSource()), "utf8");
      const dir = new URL(`${name}/`, skillsSource());
      const names = await readdir(dir).catch(() => [] as string[]);
      const files = await Promise.all(names.map(async (file): Promise<[string, Buffer]> => [file, await readFile(new URL(file, dir))]));
      return { text, files };
    })();
    // (one that did not read is read again next time)
    held.catch(() => builtins.delete(name));
    builtins.set(name, held);
  }
  return held;
}

/// Whether a directory holds nothing but the SKILL.md the station wrote.
async function onlySkill(dir: string): Promise<boolean> {
  try {
    return (await lstat(dir)).isDirectory() && (await readdir(dir)).every((e) => e === "SKILL.md");
  } catch {
    return false;
  }
}

/// The skills of the deployment the station runs in (`STILLFAIL_SITE_SKILLS`: a directory of them, each `<name>/SKILL.md`
/// and what it brings), when it names one: a machine that runs the station as part of itself (a Monoid Machine) tells
/// its agents about itself this way. None by default.
export const siteSkills = (env: NodeJS.ProcessEnv = process.env): string | null => env.STILLFAIL_SITE_SKILLS || null;

/// The skill of moving to another station: only where moving is on (a `beta` feature of the station's, features.ts).
export const MOVE_SKILL = "stillfail-move";

/// Writes the station's own skills into the shared skills directory; `feedback`: the stillfail-feedback skill too
/// (else it is taken away, unless someone added to it); `site`: the deployment's skills linked beside them
/// (`linkSiteSkills`); `move`: stillfail-move too (else it is taken away so, as stillfail-feedback is). The retired
/// skills (`RETIRED_SKILLS`) are taken away so, always.
export async function writeBuiltinSkills(agentHome: string, feedback: boolean, site: string | null = siteSkills(), move = true): Promise<void> {
  const [, skills] = agentHomePaths(agentHome);
  if (site !== null) await linkSiteSkills(skills, site);
  if (!feedback && (await onlySkill(join(skills, FEEDBACK_SKILL)))) await rm(join(skills, FEEDBACK_SKILL), { recursive: true, force: true });
  if (!move && (await onlySkill(join(skills, MOVE_SKILL)))) await rm(join(skills, MOVE_SKILL), { recursive: true, force: true });
  for (const name of RETIRED_SKILLS) if (await onlySkill(join(skills, name))) await rm(join(skills, name), { recursive: true, force: true });
  for (const name of [...BUILTIN_SKILLS.filter((n) => move || n !== MOVE_SKILL), ...(feedback ? [FEEDBACK_SKILL] : [])]) {
    const { text, files } = await builtinSkill(name);
    const dir = join(skills, name);
    await mkdir(dir, { recursive: true });
    const path = join(dir, "SKILL.md");
    const now = await readFile(path, "utf8").catch(() => null);
    if (now !== text) await writeFile(path, text);
    for (const [file, body] of files) {
      const at = join(dir, file);
      const had = await readFile(at).catch(() => null);
      if (had === null || !had.equals(body)) await writeFile(at, body, { mode: 0o755 });
    }
  }
}

/// Links each of the deployment's skills (the entries of directory `site`) into `skills`, an agent home's, where they
/// change with the deployment: not copied, as the station's own are, since the deployment may write them after the
/// station started (the facts of the machine it runs on) and keeps them read-only. One is linked whether its SKILL.md is
/// there yet or not (a session takes only the skills that have one, `sessionSkills`); a link to one gone from `site` is
/// taken away; a skill of the same name the team has is left as it is, and said once.
export async function linkSiteSkills(skills: string, site: string): Promise<void> {
  const names = (await entries(site)).filter((name) => !name.startsWith("."));
  await mkdir(skills, { recursive: true });
  for (const entry of await entries(skills)) if (!names.includes(entry) && (await linksInto(join(skills, entry), site))) await rm(join(skills, entry), { force: true });
  for (const name of names) {
    const [at, target] = [join(skills, name), join(site, name)];
    if (await linksTo(at, target)) continue;
    if ((await lstat(at).catch(() => null)) !== null) {
      if (!leftAlone.has(at)) log.warn("agent_home", "a team's skill has the name of one the deployment brings: the team's kept", { skill: name, path: at });
      leftAlone.add(at);
      continue;
    }
    await link(target, at, { junction: true });
  }
}

export type ProfileHome = { id: string; runtimes: Runtime[]; home: string };

/// The paths already said to be left alone: said once, not at each look.
const leftAlone = new Set<string>();

/// Whether `path` is a link to `target`, however either is spelled (one may be a link to the other).
async function linksTo(path: string, target: string): Promise<boolean> {
  try {
    return (await lstat(path)).isSymbolicLink() && ((await readlink(path)) === target || (await realpath(path)) === (await realpath(target)));
  } catch {
    return false;
  }
}

/// Whether `path` is a link to something in directory `dir` (one of its skills, gone or not), however either is spelled.
async function linksInto(path: string, dir: string): Promise<boolean> {
  try {
    if (!(await lstat(path)).isSymbolicLink()) return false;
    if (dirname(await readlink(path)) === dir) return true;
    return dirname(await realpath(path)) === (await realpath(dir));
  } catch {
    return false;
  }
}

/// Takes away what stations before this one linked into every profile home: the home workspace's memory and skills,
/// under the names its runtimes load by themselves (CLAUDE.md/AGENTS.md, skills/, Grok Build's and Hermes' own). A
/// profile serves every workspace the station is in, so its home holds no workspace's: a joined workspace's sessions
/// were given the home workspace's memory and skills that way. A session has its own workspace's instead: its memory
/// with its instructions (agents/instructions.ts), its skills where it runs (`sessionSkills`). Anything else is left.
export async function unlinkAgentHome(agentHome: string, profiles: ProfileHome[]): Promise<void> {
  const [memory, skills] = agentHomePaths(agentHome);
  for (const { home } of profiles) {
    for (const name of ["CLAUDE.md", "AGENTS.md", join("grok", "AGENTS.md")]) {
      if (await linksTo(join(home, name), memory)) await rm(join(home, name), { force: true });
    }
    for (const dir of ["skills", join("hermes", "skills"), join("grok", "skills")]) {
      const path = join(home, dir);
      // (not recursive: a junction's target is not to go with it)
      if (await linksTo(path, skills)) await rm(path, { force: true });
      else for (const entry of await entries(path)) if (await linksInto(join(path, entry), skills)) await rm(join(path, entry), { force: true });
    }
  }
}

/// Where the runtimes find skills in the directory they run in: Claude Code's project skills, Codex's (the Agent
/// Skills standard's) repository ones.
export const SKILL_HOMES = [join(".claude", "skills"), join(".agents", "skills")];

/// Links the skills of a session's workspace (`skills`, its agent home's) into the directory it runs in (`workspace`),
/// where its runtime loads them as its own (SKILL_HOMES), as a preset's folders' are (presets.ts `keepCopy`); a link to
/// one gone is taken away. One of the same name there already (a preset's) is left. Off the station's thread: each
/// session's process opened looked at every skill's file and link there, waiting on the disk.
export async function sessionSkills(workspace: string, skills: string): Promise<void> {
  const names: string[] = [];
  for (const name of await entries(skills)) if (await there(join(skills, name, "SKILL.md"))) names.push(name);
  for (const home of SKILL_HOMES) {
    const dir = join(workspace, home);
    for (const entry of await entries(dir)) if (!names.includes(entry) && (await linksInto(join(dir, entry), skills))) await rm(join(dir, entry), { force: true });
    if (names.length === 0) continue;
    await mkdir(dir, { recursive: true });
    for (const name of names) {
      const at = join(dir, name);
      if (!(await there(at)) && (await lstat(at).catch(() => null)) === null) await link(join(skills, name), at, { junction: true });
    }
  }
}

const entries = (dir: string): Promise<string[]> => readdir(dir).catch(() => []);
const there = (path: string): Promise<boolean> => stat(path).then(() => true, () => false);
const realDir = (path: string): Promise<boolean> => lstat(path).then((s) => s.isDirectory(), () => false);
const canonical = (path: string): Promise<string> => realpath(path).catch(() => path);

/// One place for each runtime's transcripts (read/transcript.ts `sharedTranscripts`), shared by every home the station
/// keeps: a session is the station's, not an account's, so any account can take it on (another, when one's quota is
/// used up) with all it had, and its history is found there whatever the config says now (a profile's home changed, or
/// the profile gone, while a runtime still wrote in the home it started in). Each profile home's transcript directory
/// (`transcriptDir`) is a link there. One that is a real directory (a runtime made it before it was linked) puts what it
/// holds there too and gives way to the link (`share`); so does one in a home under the data directory's homes/ that no
/// profile names any more. A home outside the data directory whose runtime keeps its transcripts there is the person's
/// own: left alone, with a warning (the profile then keeps its own, read there). Off the station's thread: a home's
/// transcripts gathered read whole files to compare them.
export async function linkTranscripts(dataDir: string, profiles: ProfileHome[]): Promise<void> {
  const data = await canonical(dataDir);
  for (const { id, runtimes, home } of profiles) {
    await mkdir(home, { recursive: true });
    const inData = within(await canonical(home), data);
    for (const runtime of runtimes) await share(join(home, transcriptDir(runtime)), sharedTranscripts(dataDir, runtime), inData, id);
  }
  const named = new Set(await Promise.all(profiles.map((p) => canonical(p.home))));
  const homes = join(dataDir, "homes");
  for (const name of await entries(homes)) {
    const home = join(homes, name);
    if (named.has(await canonical(home)) || !(await realDir(home))) continue;
    for (const runtime of RUNTIME_KINDS) {
      const dir = join(home, transcriptDir(runtime));
      if (!(await realDir(dir))) continue;
      // Codex keeps its rollouts by date, in directories; Claude Code's own sessions/ in a home of its holds files only.
      if (runtime === "codex" && !(await someDir(dir))) continue;
      await share(dir, sharedTranscripts(dataDir, runtime), true, name);
    }
  }
}

async function someDir(dir: string): Promise<boolean> {
  for (const e of await entries(dir)) if (await realDir(join(dir, e))) return true;
  return false;
}

/// Makes transcript directory `dir` (of the home of profile `of`) a link to the shared place `shared`. A real directory
/// there, when it `gathers` (it is in the data directory), puts everything it holds in the shared place as well, the
/// same files, and is moved aside for the link while its runtime may still be writing there; then what was written
/// meanwhile is gathered too, and what is aside goes, unless some of it could not be put there. Otherwise it is left.
async function share(dir: string, shared: string, gathers: boolean, of: string): Promise<void> {
  await mkdir(shared, { recursive: true });
  await mkdir(dirname(dir), { recursive: true });
  // A runtime writing there in the moment it is moved aside makes it again: gathered again.
  for (let tries = 0; tries < 3; tries++) {
    const meta = await lstat(dir).catch(() => null);
    if (meta === null) {
      if (await linkDir(shared, dir)) return;
      continue;
    }
    if (await linksTo(dir, shared)) return;
    if (!gathers || !meta.isDirectory()) {
      if (!leftAlone.has(dir)) log.warn("agent_home", "a profile's transcripts are not in the shared place", { profile: of, path: dir });
      leftAlone.add(dir);
      return;
    }
    await gather(dir, shared);
    let aside = `${dir}.unshared`;
    for (let n = 2; (await lstat(aside).catch(() => null)) !== null; n++) aside = `${dir}.unshared-${n}`;
    try {
      await rename(dir, aside);
    } catch (error) {
      // In use where a directory in use cannot be moved (Windows): as it was, its files in the shared place as well.
      log.warn("agent_home", "a home's transcripts not moved to the shared place", { profile: of, path: dir, error: (error as Error).message });
      return;
    }
    let made: boolean;
    try {
      made = await linkDir(shared, dir);
    } catch (error) {
      await rename(aside, dir);
      throw error;
    }
    const left = await gather(aside, shared);
    if (left.length === 0) await rm(aside, { recursive: true, force: true });
    else log.warn("agent_home", "transcripts kept aside: the shared place has others of the same names", { profile: of, path: aside, files: left.length, first: left[0] });
    if (made) {
      log.info("agent_home", "a home's transcripts moved to the shared place", { profile: of, path: dir });
      return;
    }
  }
}

/// `path` made a link to directory `target` (a junction where links are refused); false when something is there first.
async function linkDir(target: string, path: string): Promise<boolean> {
  try {
    return (await link(target, path, { junction: true })) !== "refused";
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "EEXIST") return false;
    throw error;
  }
}

/// Puts every file under `from` at the same place under `to` as well: the same file (a hard link, so a runtime that
/// goes on writing it by either path writes both), directories made as needed; through a link, what it links to. A
/// file of the same name already there that is not the same file stays, unless it is a copy of this one from before it
/// grew (a home copied while its runtime went on writing in the original): then this one takes its place. One that
/// holds all this one does and more is that copy further along: this one is in it. The files left out: where each went
/// on its own way.
async function gather(from: string, to: string, left: string[] = [], seen = new Set<string>()): Promise<string[]> {
  for (const name of await entries(from)) {
    const path = join(from, name);
    const there = join(to, name);
    try {
      const real = await realpath(path);
      const st = await stat(real);
      if (st.isDirectory()) {
        if (seen.has(real) || real === (await canonical(there))) continue;
        seen.add(real);
        await mkdir(there, { recursive: true });
        await gather(real, there, left, seen);
        continue;
      }
      const other = await stat(there).catch(() => null);
      if (!st.isFile()) left.push(path);
      else if (other === null) await hardLink(real, there);
      else if (other.dev === st.dev && other.ino === st.ino) continue;
      else if (st.size > other.size && (await begins(real, there, other.size))) {
        const next = `${there}.${process.pid}.sharing`;
        await rm(next, { force: true });
        await hardLink(real, next);
        await rename(next, there);
      } else if (!(other.size >= st.size && (await begins(there, real, st.size)))) left.push(path);
    } catch {
      left.push(path);
    }
  }
  return left;
}

/// Whether file `a` begins with the first `n` bytes of file `b`: read a piece at a time, off the station's thread
/// (a runtime's transcript runs to hundreds of MB).
async function begins(a: string, b: string, n: number): Promise<boolean> {
  const fa = await open(a, "r");
  try {
    const fb = await open(b, "r");
    try {
      const [ba, bb] = [Buffer.alloc(Math.min(1 << 20, Math.max(n, 1))), Buffer.alloc(Math.min(1 << 20, Math.max(n, 1)))];
      for (let at = 0; at < n; ) {
        const want = Math.min(ba.length, n - at);
        const [ra, rb] = await Promise.all([fa.read(ba, 0, want, at), fb.read(bb, 0, want, at)]);
        if (ra.bytesRead !== want || rb.bytesRead !== want || !ba.subarray(0, want).equals(bb.subarray(0, want))) return false;
        at += want;
      }
      return true;
    } finally {
      await fb.close().catch(() => {});
    }
  } finally {
    await fa.close().catch(() => {});
  }
}
