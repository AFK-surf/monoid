// Stop unilateral drift in the legacy TypeScript station (`station/src/`) while cutting over to the pure-Pion station
// (`pion/station-main/`). Every behavioral change to `station/src/*.ts` (outside legacy reader shims, V8-only heap
// monitoring, pure 100% renames, deletions, and tests) must ship its matching `pion/station-main/` `.pion`/`.c`/`.h`
// change in the same PR.
//
// Strictly Node-runtime-only fixes (V8, Node API, emergency rollback, or pure Node-test-harness hooks) may opt out
// with an explicit, auditable trailer in the commit message's trailer block:
//   Node-Station-Only: <specific reason explaining why there is no pion/station-main counterpart>
//
// Both staged-commit checks (`.githooks/commit-msg`) and incremental push checks (`scripts/check.sh push`) widen their
// comparison base to `merge-base(<tip>, origin/main)` when `origin/main` exists, matching PR-level CI semantics so
// multi-commit PRs (follow-up review fixes, `--amend`, separate pion/station commits, or merges from `origin/main`)
// are never falsely blocked.
//
// Usage (matches scripts/mbui-budgets.ts):
//   node scripts/station-pion-sync.ts HEAD index <msg-file>   staged changes against PR base (.githooks/commit-msg)
//   node scripts/station-pion-sync.ts <base>..<head>          commit range (scripts/check.sh push and full); A...B
//                                                             checks against merge-base(A, B)
//   node scripts/station-pion-sync.ts <base> <head>
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const STATION_SRC_TS = /^station\/src\/.*\.ts$/;
const STATION_SRC_EXEMPT: readonly RegExp[] = [
  /^station\/src\/read\//,
  /^station\/src\/ops\/heap\.ts$/,
  /\.test\.ts$/,
];
const PION_STATION_SOURCE = /^pion\/station-main\/.*\.(pion|c|h)$/;

const VAGUE_PREFIX = /^(todo|wip|later|skip|none|n\/a|na|temp|temporary|fix|fixme|follow[- ]?up|sync\s+later|will\s+sync)\b/i;
const SCISSORS_LINE = /^# -+ >8 -+$/;
const TRAILER_LINE = /^[A-Za-z0-9-]+:[ \t]*.*$/;
const CHERRY_PICK_LINE = /^\(cherry picked from commit [0-9a-f]+\)$/;
const NODE_ONLY_TRAILER = /^Node-Station-Only:[ \t]+(.*)$/;

export function requiresPionSync(path: string): boolean {
  if (!STATION_SRC_TS.test(path)) return false;
  return !STATION_SRC_EXEMPT.some((re) => re.test(path));
}

export function isPionStationSource(path: string): boolean {
  return PION_STATION_SOURCE.test(path);
}

/** Extract `Node-Station-Only:` trailer values strictly from a commit message's final trailer paragraph. */
export function nodeOnlyReasonsInMessage(message: string): string[] {
  const rawLines = message.split(/\r?\n/);
  const cut = rawLines.findIndex((l) => SCISSORS_LINE.test(l));
  const lines = (cut >= 0 ? rawLines.slice(0, cut) : rawLines).filter((l) => !l.startsWith("#"));
  let end = lines.length;
  while (end > 0 && lines[end - 1]!.trim() === "") end--;
  if (end === 0) return [];
  let start = end;
  while (start > 0 && lines[start - 1]!.trim() !== "") start--;
  const paragraph = lines.slice(start, end);
  // Every line in the final paragraph must be a git trailer, folded continuation line,
  // or a `git cherry-pick -x` provenance line (ignoring pure prose paragraphs or quoted lines).
  let seenTrailer = false;
  for (const line of paragraph) {
    if (TRAILER_LINE.test(line)) {
      seenTrailer = true;
    } else if (CHERRY_PICK_LINE.test(line)) {
      continue;
    } else if (/^[ \t]+\S/.test(line) && seenTrailer) {
      continue;
    } else {
      return [];
    }
  }
  if (!seenTrailer) return [];
  const out: string[] = [];
  for (const line of paragraph) {
    const m = NODE_ONLY_TRAILER.exec(line);
    if (m) out.push(m[1]!.trim());
  }
  return out;
}

export function nodeOnlyReasons(messages: readonly string[]): string[] {
  const out: string[] = [];
  for (const msg of messages) {
    out.push(...nodeOnlyReasonsInMessage(msg));
  }
  return out;
}

export function reasonRefused(reason: string): string | undefined {
  if (reason.length < 12) {
    return `Node-Station-Only reason is too short ("${reason}"); state specifically why this change is strictly Node-runtime-only.`;
  }
  if (VAGUE_PREFIX.test(reason)) {
    return `Node-Station-Only reason "${reason}" is not specific enough; sync pion/station-main/ in the same PR instead of deferring.`;
  }
  return undefined;
}

/** Parse `git diff --name-status --diff-filter=ACMR -M -z` output, skipping pure 100% renames (`R100`). */
export function parseChangedPaths(nulOutput: string): string[] {
  const tokens = nulOutput.split("\0");
  const out: string[] = [];
  let i = 0;
  while (i < tokens.length) {
    const status = tokens[i++];
    if (!status) break;
    if (status.startsWith("R") || status.startsWith("C")) {
      const _oldPath = tokens[i++];
      const newPath = tokens[i++];
      if (!newPath) break;
      // Pure 100% rename with zero content change needs no Pion sync.
      if (status === "R100") continue;
      out.push(newPath);
    } else {
      const path = tokens[i++];
      if (!path) break;
      out.push(path);
    }
  }
  return out;
}

export interface SyncVerdict {
  ok: boolean;
  /** station/src files that require a matching pion/station-main change. */
  requiring: string[];
  /** Whether pion/station-main source files were also modified. */
  hasPionSync: boolean;
  /** Valid Node-Station-Only exemption reason, if used. */
  exemptedBy?: string;
  /** Refused Node-Station-Only trailer diagnostics, if any. */
  refusedReasons: string[];
}

export function judge(changedNonDeleted: readonly string[], messages: readonly string[]): SyncVerdict {
  const requiring = changedNonDeleted.filter(requiresPionSync);
  const hasPionSync = changedNonDeleted.some(isPionStationSource);
  if (requiring.length === 0 || hasPionSync) {
    return { ok: true, requiring, hasPionSync, refusedReasons: [] };
  }
  const reasons = nodeOnlyReasons(messages);
  const refusedReasons: string[] = [];
  for (const r of reasons) {
    const err = reasonRefused(r);
    if (err) refusedReasons.push(err);
    else return { ok: true, requiring, hasPionSync: false, exemptedBy: r, refusedReasons: [] };
  }
  return { ok: false, requiring, hasPionSync: false, refusedReasons };
}

const git = (args: string[]): string => execFileSync("git", args, { encoding: "utf8", maxBuffer: 256 << 20 });
const gitMaybe = (args: string[]): string | undefined => {
  try {
    return execFileSync("git", args, { encoding: "utf8", maxBuffer: 256 << 20, stdio: ["ignore", "pipe", "ignore"] });
  } catch {
    return undefined;
  }
};

function logMessages(from: string, to: string): string[] {
  const raw = gitMaybe(["log", "--format=%B%x1e", `${from}..${to}`]);
  if (!raw) return [];
  return raw.split("\x1e").map((s) => s.trim()).filter(Boolean);
}

/** Widen `base` to `merge-base(tip, origin/main)` when `origin/main` exists and its merge-base is an ancestor of `base`. */
function widenBaseToOriginMain(base: string, tip: string): string {
  if (gitMaybe(["rev-parse", "-q", "--verify", "refs/remotes/origin/main"]) === undefined) return base;
  const mb = gitMaybe(["merge-base", tip, "origin/main"])?.trim();
  if (!mb) return base;
  if (gitMaybe(["merge-base", "--is-ancestor", mb, base]) !== undefined) return mb;
  return base;
}

function plan(argv: string[]): { base: string; head: string; messages: string[]; checkBaseline: boolean } {
  const [a, b, c] = argv;
  if (!a) throw new Error("usage: node scripts/station-pion-sync.ts <base>..<head> | <base> <head> | HEAD index <msg-file>");
  if (b === "index") {
    const currentMsg = c ? readFileSync(c, "utf8") : "";
    const mergeHead = gitMaybe(["rev-parse", "-q", "--verify", "MERGE_HEAD"])?.trim();
    if (mergeHead) {
      const priorBase = gitMaybe(["merge-base", "HEAD", mergeHead])?.trim() ?? a;
      return {
        base: mergeHead,
        head: "index",
        messages: [...logMessages(priorBase, "HEAD"), currentMsg],
        checkBaseline: false,
      };
    }
    const prBase = widenBaseToOriginMain(a, "HEAD");
    return {
      base: prBase,
      head: "index",
      messages: [...logMessages(prBase, "HEAD"), currentMsg],
      checkBaseline: false,
    };
  }
  let rawBase: string;
  let head: string;
  if (b) {
    rawBase = a;
    head = b;
  } else {
    const three = a.indexOf("...");
    if (three >= 0) {
      const [l, r] = [a.slice(0, three) || "HEAD", a.slice(three + 3) || "HEAD"];
      rawBase = git(["merge-base", l, r]).trim();
      head = r;
    } else {
      const two = a.indexOf("..");
      if (two < 0) throw new Error(`not a range: ${a}`);
      rawBase = a.slice(0, two) || "HEAD";
      head = a.slice(two + 2) || "HEAD";
    }
  }
  const base = widenBaseToOriginMain(rawBase, head);
  return { base, head, messages: logMessages(base, head), checkBaseline: true };
}

if (import.meta.main) {
  process.chdir(git(["rev-parse", "--show-toplevel"]).trim());
  let p: ReturnType<typeof plan>;
  try {
    p = plan(process.argv.slice(2));
  } catch (e) {
    console.error(`station pion sync: ${(e as Error).message}`);
    process.exit(2);
  }
  const { base, head, messages, checkBaseline } = p;
  if (checkBaseline && gitMaybe(["cat-file", "-e", `${base}:scripts/station-pion-sync.ts`]) === undefined) {
    console.log(`station pion sync: ${base} is from before scripts/station-pion-sync.ts; not checked`);
    process.exit(0);
  }
  const diffArgs =
    head === "index"
      ? ["diff", "--cached", "--name-status", "--diff-filter=ACMR", "-M", "-z", base]
      : ["diff", "--name-status", "--diff-filter=ACMR", "-M", "-z", base, head];
  const changed = parseChangedPaths(git(diffArgs));
  const verdict = judge(changed, messages);
  if (verdict.ok) {
    if (verdict.exemptedBy) {
      console.error(`station pion sync: exempted via Node-Station-Only (${verdict.exemptedBy})`);
    }
    process.exit(0);
  }
  console.error(`station/src/ changed without a matching pion/station-main/ source update:
${verdict.requiring.map((f) => `  ${f}`).join("\n")}
${verdict.refusedReasons.map((r) => `  ! ${r}\n`).join("")}
The station is actively cutting over to pure Pion (pion/station-main/). Do not land unilateral features or fixes in
station/src/: implement the matching change in pion/station-main/ (.pion/.c/.h) in the same PR.

If this change is strictly Node-runtime-only (for example a V8/Node API quirk, legacy reader wiring, or emergency
rollback with no Pion counterpart), add a trailer to the commit message's trailer block:
  Node-Station-Only: <specific reason>`);
  process.exit(1);
}
