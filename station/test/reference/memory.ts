// The TypeScript reads the station answered before its reader moved to the MoonBit program, kept for the tests
// to compare the program with: GET /memory and `skill_read` are the readers' (mb/src/readops `memory`).
//
// The agents' memory, for the pages to show (GET /memory; the agents write it): the global one, and the shared skills
// (projects' memories among them). admin/mod.rs's route over agent_home.rs `agent_home_paths` and `list_skills`. A
// workspace the station joined has its own: <agent home>/workspaces/<ws>.
import { lstatSync, readFileSync, readdirSync, readlinkSync } from "node:fs";
import { joinPath } from "../../src/ops/paths.ts";
import type { Json } from "./store.ts";

/// The skills the station brings (and FEEDBACK_SKILL): rewritten at every start, so not
/// edited on the pages.
const BUILTIN = ["stillfail-chats", "stillfail-jobs", "stillfail-show", "stillfail-viz", "stillfail-browser", "stillfail-login", "stillfail-vault", "stillfail-cron", "stillfail-github-ci", "stillfail-retire", "stillfail-move", "stillfail-leading", "stillfail-projects", "stillfail-feedback"];
/// What a project memory's description starts with.
const PROJECT_PREFIX = "项目记忆：";

/// Path::join as Rust has it: an absolute path replaces, nothing is normalised.
export const joined = joinPath;

/// std::fs::read_to_string: the file as UTF-8, none when it does not read or is not UTF-8.
const STRICT = new TextDecoder("utf-8", { fatal: true });
function readText(path: string): string | null {
  try {
    return STRICT.decode(readFileSync(path));
  } catch {
    return null;
  }
}

export function readJson(path: string): Json {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return {};
  }
}

/// config.rs: the agents' home, `agentHome` in config.json under the data directory (default `agent`).
export function agentHome(raw: Json, dataDir: string): string {
  return joined(dataDir, typeof raw?.agentHome === "string" ? raw.agentHome : "agent");
}

/// What a skill's sharing is (share/index.ts): shared from here (config.json `sharedSkills`), a copy of another
/// front: a SKILL.md's frontmatter field (`key: value`), if it has one.
function front(text: string, key: string): string | null {
  if (!text.startsWith("---\n")) return null;
  const body = text.slice(4);
  const end = body.indexOf("\n---");
  if (end < 0) return null;
  for (const raw of body.slice(0, end).split("\n")) {
    const line = raw.endsWith("\r") ? raw.slice(0, -1) : raw;
    if (line.startsWith(`${key}:`)) return line.slice(key.length + 1).trim().replace(/^"+|"+$/g, "");
  }
  return null;
}

/// Rust's String order (bytes of UTF-8).
const byBytes = (a: string, b: string) => Buffer.compare(Buffer.from(a), Buffer.from(b));

const HEX64 = /^[0-9a-f]{64}$/;
type Rec = { hash: string; at: number; by: string; prev: string[] };

function recOf(raw: Json): Rec | null {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return null;
  const { hash, at, by, prev } = raw;
  if (typeof hash !== "string" || typeof at !== "number" || !Number.isSafeInteger(at) || at <= 0) return null;
  if (typeof by !== "string" || by === "" || !Array.isArray(prev)) return null;
  return { hash, at, by, prev: prev.filter((p): p is string => typeof p === "string" && HEX64.test(p)) };
}

function newerRec(a: Rec, b: Rec): boolean {
  return a.at !== b.at ? a.at > b.at : a.by !== b.by ? a.by > b.by : byBytes(a.hash, b.hash) > 0;
}

function stationName(cloud: Json, ws: string | undefined, station: string): string {
  if (ws !== undefined && Array.isArray(cloud?.joined)) {
    const j = cloud.joined.find((x: Json) => x?.workspace === ws);
    if (j) {
      const p = Array.isArray(j.peers) ? j.peers.find((x: Json) => x?.id === station) : undefined;
      if (typeof p?.name === "string" && p.name.trim() !== "") return p.name.trim();
      if (station === cloud?.station && typeof j.name === "string" && j.name.trim() !== "") return j.name.trim();
    }
  }
  const p = Array.isArray(cloud?.peers) ? cloud.peers.find((x: Json) => x?.id === station) : undefined;
  if (typeof p?.name === "string" && p.name.trim() !== "") return p.name.trim();
  if (station === cloud?.station && typeof cloud?.name === "string" && cloud.name.trim() !== "") return cloud.name.trim();
  return station.slice(0, 8);
}

function prevBlob(dataDir: string, rec: Rec | null): string | null {
  const h = rec?.prev[0];
  return h ? readText(joined(dataDir, `share/memory/blobs/${h}`)) : null;
}

/// station's (its link into <data>/share/<id>/skill, from the station state.json says), or neither (null).
function sharing(dataDir: string, raw: Json, dir: string, name: string): Json {
  const hosted = raw?.sharedSkills?.[name];
  if (typeof hosted === "string" || typeof hosted?.id === "string") {
    const station = readJson(joined(dataDir, "mesh/cloud.json"))?.station ?? "";
    let conflicts: string[] = [];
    try {
      conflicts = readdirSync(joined(dir, name)).filter((n) => /^SKILL\.conflict-.*\.md$/.test(n));
    } catch {}
    const id = typeof hosted === "string" ? hosted : hosted.id;
    // Which stations have it, which may and do not and why, and why it is not being shared now (share/index.ts Hosted).
    const state = readJson(joined(dataDir, "share/state.json"))?.hosted?.[id] ?? {};
    const missing = typeof state.missing === "object" && state.missing !== null ? state.missing : {};
    const users = Object.entries(typeof state.told === "object" && state.told !== null ? state.told : {}).flatMap(([s, v]) => (typeof v === "number" && v >= 0 && !(s in missing) ? [s] : []));
    return {
      id, role: "host", host: station, allow: Array.isArray(hosted?.allow) ? hosted.allow : null, conflicts, users,
      missing: Object.entries(missing).flatMap(([s, why]) => (typeof why === "string" ? [{ station: s, why }] : [])),
      ...(typeof state.unread === "string" ? { unread: state.unread } : {}),
    };
  }
  try {
    const path = joined(dir, name);
    if (!lstatSync(path).isSymbolicLink()) return null;
    const m = /\/share\/(sh-[0-9a-z]+)\/skill$/.exec(readlinkSync(path));
    const had = m ? readJson(joined(dataDir, "share/state.json"))?.borrowed?.[m[1]!] : undefined;
    return had ? { id: m![1], role: "user", host: had.host ?? "", allow: Array.isArray(had.allow) ? had.allow : null, conflicts: [] } : null;
  } catch {
    return null;
  }
}

/// A skill's other files, the topics its SKILL.md points to (`design.md`…): each Markdown file beside it but the edits
/// kept from an older copy (SKILL.conflict-*.md), by name.
function skillFiles(dir: string): Json[] {
  let names: string[];
  try {
    names = readdirSync(dir);
  } catch {
    return [];
  }
  return names
    .filter((n) => n.endsWith(".md") && n !== "SKILL.md" && !/^SKILL\.conflict-/.test(n))
    .sort(byBytes)
    .flatMap((name) => {
      const text = readText(joined(dir, name));
      return text === null ? [] : [{ name, text }];
    });
}

/// `shares`: whether its skills may be shared with other stations (the home workspace's only).
function listSkills(home: string, dataDir: string, raw: Json, cloud: Json, ws: string | undefined, keptFiles: Json, shares = true): Json[] {
  const dir = joined(home, "skills");
  let names: string[];
  try {
    names = readdirSync(dir);
  } catch {
    return [];
  }
  const skills = names.flatMap((name) => {
    const text = readText(joined(joined(dir, name), "SKILL.md"));
    if (text === null) return [];
    const description = front(text, "description") ?? "";
    const builtin = BUILTIN.includes(name);
    const files = skillFiles(joined(dir, name));
    const skillRec = builtin ? null : recOf(keptFiles?.[`skills/${name}/SKILL.md`]);
    let latest = skillRec;
    if (!builtin) {
      for (const f of files) {
        const fRec = recOf(keptFiles?.[`skills/${name}/${f.name}`]);
        if (fRec && (!latest || newerRec(fRec, latest))) latest = fRec;
      }
    }
    const prev = prevBlob(dataDir, skillRec);
    return [{
      name,
      description,
      project: description.startsWith(PROJECT_PREFIX),
      builtin,
      text,
      files,
      share: builtin || !shares ? null : sharing(dataDir, raw, dir, name),
      ...(latest ? { at: latest.at, by: stationName(cloud, ws, latest.by), ...(prev !== null ? { prev } : {}) } : {}),
    }];
  });
  return skills.sort((a, b) => Number(a.builtin) - Number(b.builtin) || Number(!a.project) - Number(!b.project) || byBytes(a.name, b.name));
}

/// GET /memory: the home workspace's, or with `ws` the one of that joined workspace (none yet: empty).
export function memory(dataDir: string, ws?: string): Json {
  const raw = readJson(joined(dataDir, "config.json"));
  if (ws !== undefined && !/^[0-9A-Za-z_-]{1,128}$/.test(ws)) throw new Error("not a workspace id");
  const cloud = readJson(joined(dataDir, "mesh/cloud.json"));
  const wsId = ws ?? (typeof cloud?.workspace === "string" ? cloud.workspace : "");
  const keptFiles = wsId !== "" && /^[0-9A-Za-z_-]{1,128}$/.test(wsId) ? readJson(joined(dataDir, `share/memory/${wsId}.json`))?.files ?? {} : {};
  const home = ws === undefined ? agentHome(raw, dataDir) : joined(joined(agentHome(raw, dataDir), "workspaces"), ws);
  const path = joined(home, "MEMORY.md");
  const globalRec = recOf(keptFiles?.["MEMORY.md"]);
  const globalPrev = prevBlob(dataDir, globalRec);
  return {
    global: {
      path,
      text: readText(path) ?? "",
      ...(globalRec ? { at: globalRec.at, by: stationName(cloud, ws, globalRec.by), ...(globalPrev !== null ? { prev: globalPrev } : {}) } : {}),
    },
    skills: listSkills(home, dataDir, raw, cloud, ws, keptFiles, ws === undefined),
  };
}

/// The agents' home of the station whose data is in `dataDir`: their shared memory and skills.
export function agentHomeOf(dataDir: string): string {
  return agentHome(readJson(joined(dataDir, "config.json")), dataDir);
}
