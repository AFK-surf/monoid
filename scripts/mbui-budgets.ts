// The mbui app's budgets only fall: what a screen's opening on a workspace of real size, a change given to it, and the
// chat's page opening may make, let go, lay out, measure and bind, each a bar of a table in a test
// (apps/mbui/AGENTS.md: What is checked). A test holds what runs to its bar, never the bar to what it was; a bar raised
// to let a regression through is what this refuses. A bar falls, or goes with its row; a new row comes only with the
// screen or the change it is of (apps/mbui/src/sfapp/fixture_open.mbt, client/core-ts/test/real-size.ts). Anything
// else raised says why in its commit message, a line of its own: `Budget-raise: <why>` (something new shown, or what an
// old view built uncounted now made as nodes and counted).
//   node scripts/mbui-budgets.ts HEAD index <msg-file>   what is staged against HEAD (.githooks/commit-msg)
//   node scripts/mbui-budgets.ts <base>..<head>          a range's commits (scripts/check.sh push and full); A...B is
//                                                        against where B left A (their merge base)
//   node scripts/mbui-budgets.ts <base> <head>
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

export interface Budget {
  /** The test file it is in. */
  path: string;
  /** Former paths before this table moved to another package (read from `base` when `path` is new). */
  former?: readonly string[];
  /** The top-level `let` holding it (a Map from a key to its bars). */
  name: string;
  /** What each bar of a row counts, in order: one name for a row of one number. */
  slots: readonly string[];
  /** A key that is not there is held to 0 (it adds no row of its own as its screen or change comes). */
  absentIsZero: boolean;
  /** Its keys are screens or changes of the real-size sweep: a new one comes with the scene it is of. */
  scenes: boolean;
}

export const BUDGETS: readonly Budget[] = [
  {
    path: "apps/mbui/src/sfapp_realsize/real_size_known_test.mbt",
    former: ["apps/mbui/src/sfapp/real_size_known_wbtest.mbt"],
    name: "real_size_known",
    slots: ["made", "laid_out", "measured"],
    absentIsZero: false,
    scenes: true,
  },
  {
    path: "apps/mbui/src/sfapp_realsize/real_size_change_known_test.mbt",
    former: ["apps/mbui/src/sfapp/real_size_change_known_wbtest.mbt"],
    name: "real_size_change_known",
    slots: ["made", "let_go", "laid_out", "measured", "old_built", "old_laid_out"],
    absentIsZero: false,
    scenes: true,
  },
  {
    path: "apps/mbui/src/sfapp_realsize/real_size_bindings_known_test.mbt",
    former: ["apps/mbui/src/sfapp/real_size_bindings_known_wbtest.mbt"],
    name: "real_size_bindings_known",
    slots: ["bindings"],
    absentIsZero: true,
    scenes: false,
  },
  {
    path: "apps/mbui/src/sfapp_realsize/chat_nodes_open_budget_test.mbt",
    former: ["apps/mbui/src/sfapp/chat_nodes_open_budget_wbtest.mbt"],
    name: "chat_nodes_open_budget",
    slots: ["made", "let_go", "laid", "measured", "bindings"],
    absentIsZero: false,
    scenes: false,
  },
];

/** What makes a new screen or change of the real-size sweep: a new row of `scenes` comes with one of these changed. */
export const SCENE_FILES: readonly string[] = ["apps/mbui/src/sfapp/fixture_open.mbt", "client/core-ts/test/real-size.ts"];

export type Rows = Map<string, number[]>;

/** A table's rows, as `let <name> : Map[…] = { "key": (1, 2, 3), … }` writes them (comments and `///|` passed over). */
export function parseBudget(src: string, name: string, arity: number): Rows {
  const head = new RegExp(`^(?:pub |priv )?let ${name}\\s*:[^\\n]*?=\\s*\\{`, "m").exec(src);
  if (!head) throw new Error(`no \`let ${name} : Map[…] = {\``);
  const s = src;
  let i = head.index + head[0].length;
  const rows: Rows = new Map();
  const fail = (why: string): never => {
    const line = s.slice(0, i).split("\n").length;
    throw new Error(`${name}, line ${line}: ${why}`);
  };
  // Past spaces and comments.
  const gap = () => {
    for (;;) {
      while (i < s.length && /\s/.test(s[i]!)) i++;
      if (s.startsWith("//", i)) {
        const e = s.indexOf("\n", i);
        i = e < 0 ? s.length : e + 1;
      } else return;
    }
  };
  const str = (): string => {
    if (s[i] !== '"') fail("a key (a string) expected");
    i++;
    let out = "";
    for (;;) {
      const c = s[i];
      if (c === undefined || c === "\n") return fail("a string not closed");
      i++;
      if (c === '"') return out;
      if (c !== "\\") {
        out += c;
        continue;
      }
      const e = s[i++];
      if (e === "n") out += "\n";
      else if (e === "t") out += "\t";
      else if (e === "r") out += "\r";
      else if (e === "u" && s[i] === "{") {
        const end = s.indexOf("}", i);
        if (end < 0) fail("a \\u{…} not closed");
        out += String.fromCodePoint(parseInt(s.slice(i + 1, end), 16));
        i = end + 1;
      } else if (e === "\\" || e === '"' || e === "'") out += e;
      else fail(`an escape \\${e ?? ""} not read`);
    }
  };
  const num = (): number => {
    const m = /^-?\d[\d_]*/.exec(s.slice(i, i + 32));
    if (!m) return fail("a number expected");
    i += m[0].length;
    return Number(m[0].replaceAll("_", ""));
  };
  for (;;) {
    gap();
    if (s[i] === "}") break;
    const key = str();
    gap();
    if (s[i] !== ":") fail(`\`:\` expected after "${key}"`);
    i++;
    gap();
    const vals: number[] = [];
    if (s[i] === "(") {
      i++;
      for (;;) {
        gap();
        vals.push(num());
        gap();
        if (s[i] === ",") {
          i++;
          gap();
          if (s[i] === ")") {
            i++;
            break;
          }
          continue;
        }
        if (s[i] === ")") {
          i++;
          break;
        }
        fail(`\`,\` or \`)\` expected in "${key}"`);
      }
    } else vals.push(num());
    if (vals.length !== arity) fail(`"${key}" has ${vals.length} numbers, not ${arity}`);
    if (rows.has(key)) fail(`"${key}" twice`);
    rows.set(key, vals);
    gap();
    if (s[i] === ",") i++;
    else {
      gap();
      if (s[i] !== "}") fail(`\`,\` or \`}\` expected after "${key}"`);
    }
  }
  return rows;
}

export interface Raised {
  path: string;
  key: string;
  /** What was raised: a bar's name and its numbers before and after; none for a new row. */
  slot?: string;
  before?: number;
  after?: number;
  why: string;
}

/** What a table's change raises: a bar above what it was, a key held to 0 now above it, a new row not of a new scene. */
export function raised(budget: Budget, before: Rows, after: Rows, sceneChanged: boolean): Raised[] {
  const out: Raised[] = [];
  for (const [key, now] of after) {
    const was = before.get(key) ?? (budget.absentIsZero ? budget.slots.map(() => 0) : undefined);
    if (was === undefined) {
      if (budget.scenes && sceneChanged) continue;
      out.push({
        path: budget.path,
        key,
        why: budget.scenes
          ? `a new row with no new screen or change of the sweep (${SCENE_FILES.join(", ")} not changed)`
          : "a new row: its bars come with no screen of their own",
      });
      continue;
    }
    now.forEach((n, k) => {
      const w = was[k]!;
      if (n > w) out.push({ path: budget.path, key, slot: budget.slots[k]!, before: w, after: n, why: "raised" });
    });
  }
  return out;
}

/** What says nothing of why: a reason made of these words alone. */
const VAGUE = new Set([
  "update", "updated", "updates", "updating", "recount", "recounted", "recounts", "fix", "fixed", "fixes", "none", "raise",
  "raised", "raises", "bump", "bumped", "budget", "budgets", "bar", "bars", "count", "counts", "counted", "number",
  "numbers", "the", "a", "an", "of", "to", "n/a", "na", "tbd", "todo", "wip", "ok", "misc", "refresh", "rebaseline",
  "baseline", "new", "change", "changes", "changed", "again", "and", "test", "tests",
]);

/** The reasons a commit message gives, each `Budget-raise: <why>` a line of its own. */
export function raiseReasons(message: string): string[] {
  return [...message.matchAll(/^Budget-raise:(.*)$/gm)].map((m) => m[1]!.trim());
}

/** Why a reason does not do (too short, or saying nothing): none when it does. */
export function reasonRefused(why: string): string | undefined {
  if (why.length < 12) return `\`Budget-raise: ${why}\` is too short: say what is shown or counted now that was not`;
  const words = why.toLowerCase().split(/[\s,.;:!?()]+/).filter(Boolean);
  if (words.every((w) => VAGUE.has(w))) return `\`Budget-raise: ${why}\` says nothing of why`;
  return undefined;
}

/** Whether the messages let a raise through: one reason that does; else why each given does not. */
export function raiseLetBy(messages: string): { ok: boolean; refused: string[] } {
  const reasons = raiseReasons(messages);
  const refused = reasons.map(reasonRefused).filter((r): r is string => r !== undefined);
  return { ok: reasons.length > refused.length, refused };
}

export function describe(r: Raised): string {
  return r.slot ? `${r.path}: "${r.key}" ${r.slot} ${r.before} -> ${r.after}` : `${r.path}: "${r.key}": ${r.why}`;
}

/** All a change raises of the budgets: each table changed read before and after. */
export function judge(read: (path: string) => { before: string | undefined; after: string | undefined }, changed: readonly string[]): Raised[] {
  const sceneChanged = SCENE_FILES.some((f) => changed.includes(f));
  const out: Raised[] = [];
  for (const b of BUDGETS) {
    if (!changed.includes(b.path)) continue;
    const cur = read(b.path);
    const after = cur.after;
    // (a table taken away raises nothing; one moved reads its previous path so a move still enforces every bar)
    if (after === undefined) continue;
    let before = cur.before;
    if (before === undefined && b.former) {
      for (const old of b.former) {
        const prev = read(old).before;
        if (prev !== undefined) {
          before = prev;
          break;
        }
      }
    }
    const was = before === undefined ? new Map() : parseBudget(before, b.name, b.slots.length);
    out.push(...raised(b, was, parseBudget(after, b.name, b.slots.length), sceneChanged));
  }
  return out;
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
  if (!a) throw new Error("usage: node scripts/mbui-budgets.ts <base>..<head> | <base> <head> | HEAD index <msg-file>");
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

if (import.meta.main) {
  process.chdir(git(["rev-parse", "--show-toplevel"]).trim());
  let p: ReturnType<typeof plan>;
  try {
    p = plan(process.argv.slice(2));
  } catch (e) {
    console.error(`mbui budgets: ${(e as Error).message}`);
    process.exit(2);
  }
  const { base, head, messages } = p;
  // (a range from before this check was there, main's first run after it came in: what merged before it said no reason
  // it was not asked for)
  if (head !== "index" && gitMaybe(["cat-file", "-e", `${base}:scripts/mbui-budgets.ts`]) === undefined) {
    console.log(`mbui budgets: ${base} is from before scripts/mbui-budgets.ts; not checked`);
    process.exit(0);
  }
  const changed = (head === "index" ? git(["diff", "--cached", "--name-only", base]) : git(["diff", "--name-only", base, head])).split("\n").filter(Boolean);
  let found: Raised[];
  try {
    found = judge(
      (path) => ({
        before: gitMaybe(["show", `${base}:${path}`]),
        after: gitMaybe(["show", head === "index" ? `:${path}` : `${head}:${path}`]),
      }),
      changed,
    );
  } catch (e) {
    console.error(`mbui budgets: ${(e as Error).message} (scripts/mbui-budgets.ts reads it)`);
    process.exit(2);
  }
  if (found.length === 0) process.exit(0);
  const { ok, refused } = raiseLetBy(messages);
  if (ok) {
    console.error(`mbui budgets raised, said why (Budget-raise):\n${found.map((r) => `  ${describe(r)}`).join("\n")}`);
    process.exit(0);
  }
  console.error(`the mbui app's budgets only fall, and this raises them:
${found.map((r) => `  ${describe(r)}`).join("\n")}
${refused.map((r) => `${r}\n`).join("")}
A bar is what a screen's opening or a change given to it made, let go, laid out, measured or bound, held to what it
was. More than before is most often work done again that need not be: find why first (what is made again, laid out
again or read anew; the test prints the lines of the most) and take it away, so the bar stays or falls. A new row comes
with the screen or the change it is of (${SCENE_FILES.join(", ")}).
Only where more is truly shown now, or an old view's build that went uncounted is now made as nodes and counted, say
why in the commit message, a line of its own:
  Budget-raise: <what is shown or counted now that was not>
and say it too in the comment over the table's row, as the rows before it do.`);
  process.exit(1);
}
