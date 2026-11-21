// Station dual-track parity gate: changes to `station/src/` production TypeScript must also update `station/mb/`,
// or state why no MoonBit counterpart change is needed in a commit message trailer on a line of its own:
//   Station-parity: <why>
//
//   node scripts/station-parity.ts HEAD index <msg-file>   what is staged against HEAD (.githooks/commit-msg)
//   node scripts/station-parity.ts <base>..<head>          a range's commits (scripts/check.sh push and full); A...B is
//                                                          against where B left A (their merge base)
//   node scripts/station-parity.ts <base> <head>
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

/**
 * Node-only bridge / runtime glue files in `station/src/` that have no counterpart in `station/mb/`.
 * Keep this list minimal: `station/src/main.ts`, `station/src/cli.ts`, and all business modules are NOT exempt.
 */
export const NODE_ONLY_FILES: ReadonlySet<string> = new Set([
  // Effect Clock / Fibers wrapper (Node Effect runtime only)
  "station/src/ops/fibers.ts",
  // Node bridge spawning MoonBit reader child processes
  "station/src/read/mb-reader.ts",
  // Node bridge managing `--sessions` child processes
  "station/src/agents/mb-program.ts",
  // Node-side HostedProcess bridge
  "station/src/agents/mb-agents.ts",
  // Node-side actor RPC bridge (guarded by station/test/mb-station-contracts.test.ts)
  "station/src/sessions/mb-actor.ts",
  // Node-side `#live` bridge
  "station/src/sessions/mb-live.ts",
  // Node-side `#jobs` bridge
  "station/src/jobs/mb-jobs.ts",
  // Node-side `#remote` bridge
  "station/src/jobs/mb-remote.ts",
  // Node N-API mesh addon bridge
  "station/src/mesh/native.ts",
]);

/** Whether `path` is a non-exempt production TypeScript file under `station/src/`. */
export function isStationProdTs(path: string): boolean {
  if (!/^station\/src\/.*\.ts$/.test(path)) return false;
  if (path.endsWith(".test.ts")) return false;
  return !NODE_ONLY_FILES.has(path);
}

/** Placeholder reasons that explain nothing and are rejected in `Station-parity:`. */
const PLACEHOLDER_REASONS: ReadonlySet<string> = new Set([
  "none",
  "n/a",
  "na",
  "ok",
  "wip",
  "todo",
  "tbd",
  "skip",
  "later",
  "pass",
]);

/** Whether `messages` contains a standalone `Station-parity: <non-placeholder why>` trailer line. */
export function hasParityTrailer(messages: string): boolean {
  for (const m of messages.matchAll(/^Station-parity:[ \t]*(.*)$/gm)) {
    const why = m[1]!.trim();
    if (why.length >= 6 && !PLACEHOLDER_REASONS.has(why.toLowerCase())) return true;
  }
  return false;
}

export interface ParityResult {
  ok: boolean;
  prodTs: string[];
  hasMb: boolean;
  hasTrailer: boolean;
}

/** Check whether a set of changed paths and commit messages satisfies the dual-track parity rule. */
export function checkStationParity(changed: readonly string[], messages: string): ParityResult {
  const prodTs = changed.filter(isStationProdTs);
  if (prodTs.length === 0) return { ok: true, prodTs: [], hasMb: false, hasTrailer: false };
  const hasMb = changed.some((p) => p.startsWith("station/mb/"));
  if (hasMb) return { ok: true, prodTs, hasMb: true, hasTrailer: false };
  const hasTrailer = hasParityTrailer(messages);
  return { ok: hasTrailer, prodTs, hasMb: false, hasTrailer };
}

const git = (args: string[]): string => execFileSync("git", args, { encoding: "utf8", maxBuffer: 256 << 20 });
const gitMaybe = (args: string[]): string | undefined => {
  try {
    return execFileSync("git", args, { encoding: "utf8", maxBuffer: 256 << 20, stdio: ["ignore", "pipe", "ignore"] });
  } catch {
    return undefined;
  }
};

/** base, head (`index`: what is staged) and the messages, from the command's arguments. */
function plan(argv: string[]): { base: string; head: string; messages: string } {
  const [a, b, c] = argv;
  if (!a) throw new Error("usage: node scripts/station-parity.ts <base>..<head> | <base> <head> | HEAD index <msg-file>");
  if (b === "index") return { base: a, head: "index", messages: c ? readFileSync(c, "utf8") : "" };
  if (b) return { base: a, head: b, messages: git(["log", "--format=%B", `${a}..${b}`]) };
  const three = a.indexOf("...");
  if (three >= 0) {
    const [l, r] = [a.slice(0, three) || "HEAD", a.slice(three + 3) || "HEAD"];
    const base = git(["merge-base", l, r]).trim();
    return { base, head: r, messages: git(["log", "--format=%B", `${base}..${r}`]) };
  }
  const two = a.indexOf("..");
  if (two < 0) throw new Error(`not a range: ${a}`);
  return { base: a.slice(0, two) || "HEAD", head: a.slice(two + 2) || "HEAD", messages: git(["log", "--format=%B", a]) };
}

function changedFiles(base: string, head: string): string[] {
  if (head === "index") {
    const hasBase = gitMaybe(["rev-parse", "-q", "--verify", base]) !== undefined;
    const raw = hasBase ? git(["diff", "--cached", "--name-only", base]) : git(["diff", "--cached", "--name-only"]);
    return raw.split("\n").filter(Boolean);
  }
  return git(["diff", "--name-only", base, head]).split("\n").filter(Boolean);
}

if (import.meta.main) {
  process.chdir(git(["rev-parse", "--show-toplevel"]).trim());
  let p: ReturnType<typeof plan>;
  try {
    p = plan(process.argv.slice(2));
  } catch (e) {
    console.error(`station parity: ${(e as Error).message}`);
    process.exit(2);
  }
  if (p.head !== "index" && gitMaybe(["cat-file", "-e", `${p.base}:scripts/station-parity.ts`]) === undefined) {
    console.log(`station dual-track parity: ${p.base} is from before scripts/station-parity.ts; not checked`);
    process.exit(0);
  }
  const changed = changedFiles(p.base, p.head);
  const res = checkStationParity(changed, p.messages);
  if (res.ok) {
    if (res.hasTrailer) {
      console.error(`station dual-track parity: station/src/ changed without station/mb/, explained by Station-parity trailer:\n${res.prodTs.map((f) => `  ${f}`).join("\n")}`);
    }
    process.exit(0);
  }
  console.error(`station dual-track parity: station/src/ production files changed without any station/mb/ update:
${res.prodTs.map((f) => `  ${f}`).join("\n")}

Sync the corresponding MoonBit station code under station/mb/ in the same change, or explain why no MoonBit
update is needed on a standalone line in the commit message:
  Station-parity: <why>
(for example: \`Station-parity: node-only (...)\` or \`Station-parity: already in station/mb (...)\`).`);
  process.exit(1);
}
