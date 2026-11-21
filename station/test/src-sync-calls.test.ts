// The station's main thread waits on nothing (station/AGENTS.md), read from the code of src/ as it is: `scripts/check.sh`
// refuses only what a change adds, so what moved off the thread could come back with a line it does not see (a file
// renamed, a call put back in a move). Every file of src/ but those that run in no station (the command line, the
// update's own process and Codex's repair it runs) is read here; what the main thread still waits on is said by file
// below, a list that only shrinks.
import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const posix = (path: string) => path.replaceAll("\\", "/");

/// Not the station's process: the command line (`stillfail-station …` with no station of its own on the thread), and
/// the update's (`stillfail-station update`, the delta applier and Codex's repair it alone runs).
const APART = new Set(["src/cli.ts", "src/updates/command.ts", "src/updates/codex-repair.ts"]);

/// The files whose synchronous calls of node:fs or node:zlib stand from before the rule, unmarked: what each does
/// before the station serves or at one step that must not be split (a lock's file written whole, the process's entry,
/// config.json's own reading, run/'s marks of a hub or a rig starting and stopping, the platforms' lookups for what
/// runs before the station serves). Each one taken off the list once its last such call moves off the thread.
const STANDING = [
  "src/cloud/key.ts", "src/cloud/presence.ts", "src/cloud/state.ts", "src/main.ts", "src/ops/config.ts", "src/ops/files.ts",
  "src/ops/json-file.ts", "src/platform/processes.ts", "src/platform/unix.ts", "src/platform/windows.ts", "src/rig/main.ts",
  "src/sessions/agents.ts",
];

/// The synchronous file and compression calls, by name (as scripts/check.sh's step names them).
const SYNC_NAMES = new Set(
  ("access appendFile chmod chown close copyFile cp exists fchmod fchown fdatasync fstat fsync ftruncate futimes lchown link " +
    "lstat lutimes mkdir mkdtemp open opendir read readdir readFile readlink readv realpath rename rm rmdir stat statfs symlink " +
    "truncate unlink utimes write writeFile writev gzip gunzip deflate deflateRaw inflate inflateRaw unzip brotliCompress " +
    "brotliDecompress zstdCompress zstdDecompress").split(" ").map((n) => `${n}Sync`),
);
const PROCESS_SYNC = new Set(["execSync", "execFileSync", "spawnSync"]);

/// `text` with its comments and the text of its strings blanked, each line where it was: what is left is code, a
/// template's `${…}` too. The text of a string is not a call: a script another process runs (places.ts's DIR_JS and
/// COPY_JS, shell-path.ts's CODE) calls what it will on its own thread.
function codeOf(text: string): string {
  const out = text.split("");
  const blank = (from: number, to: number) => {
    for (let k = from; k < to; k++) if (out[k] !== "\n") out[k] = " ";
  };
  // What is open: a template's text, or the code of a `${…}` in one with the braces opened within it.
  const open: ({ text: true } | { text: false; depth: number })[] = [];
  let last = ""; // the last character of code that is not a space, for a `/` that begins a regular expression
  let word = ""; // and the word it ends, if any
  let i = 0;
  while (i < text.length) {
    const top = open.at(-1);
    if (top?.text) {
      const c = text[i];
      if (c === "\\") {
        blank(i, i + 2);
        i += 2;
      } else if (c === "`") {
        open.pop();
        last = "`";
        word = "";
        i++;
      } else if (c === "$" && text[i + 1] === "{") {
        open.push({ text: false, depth: 0 });
        last = "{";
        word = "";
        i += 2;
      } else {
        blank(i, i + 1);
        i++;
      }
      continue;
    }
    const c = text[i]!;
    if (c === "/" && text[i + 1] === "/") {
      const end = text.indexOf("\n", i);
      blank(i, end === -1 ? text.length : end);
      i = end === -1 ? text.length : end;
    } else if (c === "/" && text[i + 1] === "*") {
      const end = text.indexOf("*/", i + 2);
      blank(i, end === -1 ? text.length : end + 2);
      i = end === -1 ? text.length : end + 2;
    } else if (c === "'" || c === '"') {
      let j = i + 1;
      while (j < text.length && text[j] !== c && text[j] !== "\n") j += text[j] === "\\" ? 2 : 1;
      blank(i + 1, j);
      i = j + 1;
      last = c;
      word = "";
    } else if (c === "`") {
      open.push({ text: true });
      i++;
    } else if (c === "/" && (last === "" || "(,=:[!&|?{};+-*%<>~^".includes(last) || ["return", "typeof", "case", "of", "in", "void", "yield", "await"].includes(word))) {
      // A regular expression: to its closing `/`, a class's `/` aside.
      let j = i + 1;
      let inClass = false;
      while (j < text.length && text[j] !== "\n" && (inClass || text[j] !== "/")) {
        if (text[j] === "\\") j++;
        else if (text[j] === "[") inClass = true;
        else if (text[j] === "]") inClass = false;
        j++;
      }
      blank(i + 1, j);
      i = j + 1;
      last = "/";
      word = "";
    } else {
      if (top !== undefined && !top.text) {
        if (c === "{") top.depth++;
        else if (c === "}") {
          if (top.depth === 0) {
            open.pop();
            i++;
            continue;
          }
          top.depth--;
        }
      }
      // (TypeScript's `!` after a value, as in `a[0]! / 2`, leaves it a value)
      const asserted = c === "!" && /[\w$)\]]/.test(last) && text[i + 1] !== "=";
      if (!/\s/.test(c) && !asserted) {
        word = /[\w$]/.test(c) ? (/[\w$]/.test(last) ? word + c : c) : "";
        last = c;
      }
      i++;
    }
  }
  return out.join("");
}

/// The names a file takes from node:fs, node:zlib and node:child_process (their promises' aside): what it calls each by
/// (`{ a, b as c }`), and the names it calls the module by (`* as fs`, `fs`).
function imported(text: string): { named: Map<string, string>; modules: Set<string> } {
  const named = new Map<string, string>(), modules = new Set<string>();
  for (const [, clause] of text.matchAll(/\bimport\s+(?!type\s)([^;]*?)\s+from\s+["'](?:node:)?(?:fs|zlib|child_process)["']/g)) {
    const braces = /\{([^}]*)\}/.exec(clause!);
    for (const part of braces?.[1]!.split(",") ?? []) {
      const [name, as] = part.trim().replace(/^type\s+/, "").split(/\s+as\s+/);
      if (name) named.set(as ?? name, name);
    }
    const outside = clause!.replace(/\{[^}]*\}/, "").replace(/,/g, " ").trim();
    for (const m of outside.matchAll(/(?:\*\s+as\s+)?([\w$]+)/g)) modules.add(m[1]!);
  }
  return { named, modules };
}

type Found = { file: string; line: number; text: string; code: string; marked: boolean };

let read: Promise<{ file: string; text: string; lines: Found[] }[]> | undefined;
/// Every file of the station's process, read once for the tests below.
const sources = () => (read ??= readSources());

async function readSources(): Promise<{ file: string; text: string; lines: Found[] }[]> {
  const files = (await readdir(join(ROOT, "src"), { recursive: true }))
    .filter((file) => file.endsWith(".ts") && !file.endsWith(".d.ts")).map((file) => posix(join("src", file))).sort();
  assert.ok(files.length > 200, "src/ is read");
  return Promise.all(files.filter((file) => !APART.has(file)).map(async (file) => {
    const text = await readFile(join(ROOT, file), "utf8");
    const blanked = codeOf(text);
    // Read as it is written: a string or a regular expression taken for something else would blank the code after it
    // (and its calls with it), and leave its brackets unbalanced.
    const opened = { "(": 0, "[": 0, "{": 0 } as Record<string, number>;
    for (const c of blanked) if (c in opened) opened[c]!++; else if (c === ")") opened["("]!--; else if (c === "]") opened["["]!--; else if (c === "}") opened["{"]!--;
    assert.deepEqual(opened, { "(": 0, "[": 0, "{": 0 }, `${file} read as code with its brackets balanced`);
    const code = blanked.split("\n");
    const lines = text.split("\n").map((line, at) => ({ file, line: at + 1, text: line, code: code[at]!, marked: line.includes("sync:") }));
    return { file, text, lines };
  }));
}

const at = (f: Found) => `${f.file}:${f.line} ${f.text.trim()}`;

test("what is left of a file as code: its comments and its strings' text blanked, a template's code kept", () => {
  const code = codeOf([
    "const a = readFileSync(p); // statSync(q)",
    "/* rmSync(r)",
    "   */ const s = \"writeFileSync(x)\" + 'mkdirSync(y)';",
    "const t = `fs.realpathSync(p) ${statSync(q) + `${lstatSync(r)}`} done`;",
    "const r = /readSync\\(/.test(s) ? x[0]! / 2 : openSync(z) / 3;",
  ].join("\n")).split("\n");
  assert.equal(code.length, 5, "each line where it was");
  assert.match(code[0]!, /readFileSync\(p\);\s*$/);
  assert.doesNotMatch(code[1]! + code[2]!, /rmSync|writeFileSync|mkdirSync/);
  assert.doesNotMatch(code[3]!, /realpathSync/, "a template's text");
  assert.match(code[3]!, /statSync\(q\)/, "the code of its ${…}");
  assert.match(code[3]!, /lstatSync\(r\)/, "and of one within it");
  assert.doesNotMatch(code[3]!, /done/, "the text after it");
  assert.doesNotMatch(code[4]!, /readSync/, "a regular expression");
  assert.match(code[4]!, /x\[0\]! \/ 2 : openSync\(z\) \/ 3;/, "a division is code, after a value TypeScript says is there too");
});

test("no file of the station's calls a process and waits on it (execSync, execFileSync, spawnSync)", async () => {
  const found: string[] = [];
  for (const { text, lines } of await sources()) {
    const { named } = imported(text);
    const local = [...named].filter(([, name]) => PROCESS_SYNC.has(name)).map(([as]) => as);
    for (const l of lines) {
      if (local.some((as) => new RegExp(`(?<![\\w$.])${as.replace("$", "\\$")}\\b`).test(l.code))) found.push(at(l));
      else if (/\.(?:execSync|execFileSync|spawnSync)\s*\(/.test(l.code)) found.push(at(l));
    }
  }
  assert.deepEqual(found, [], "a process waited on holds the main thread until it ends: execFile or spawn");
});

test("config.json is written off the main thread once the station serves (updateSoon)", async () => {
  // Its own definition, and `stillfail-station channel` with no station running (updates/channel.ts).
  const own = new Set(["src/ops/config.ts", "src/updates/channel.ts"]);
  const found: string[] = [];
  for (const { file, lines } of await sources()) {
    if (own.has(file)) continue;
    for (const l of lines) if (/(?:\b(?:config|settings)|\bConfigFile\([^)]*\))\??\.update\s*\(/.test(l.code)) found.push(at(l));
  }
  assert.deepEqual(found, []);
});

test("the platform's lookups on the main thread are asked only before the station serves, each where it is said", async () => {
  // Each `name` (not its `…Soon`) asked outside src/platform/: the files where it may be, so many times each, with
  // `sync:` on its line where it says why.
  const allowed: Record<string, { at: Record<string, number>; marked: boolean }> = {
    // Git's sh on Windows found on disk: what runs once the station serves asks posixShellSoon.
    posixShell: { at: {}, marked: false },
    findCommand: { at: { "src/adb/link.ts": 1 }, marked: true },
    browsers: { at: { "src/browser/chrome.ts": 1 }, marked: true },
    // stillfail-job written as Jobs is made.
    makeCommand: { at: { "src/jobs/jobs.ts": 1 }, marked: false },
  };
  const counted: Record<string, Record<string, number>> = {};
  const unmarked: string[] = [];
  for (const { file, lines } of await sources()) {
    if (file.startsWith("src/platform/")) continue;
    for (const l of lines) {
      for (const [, name] of l.code.matchAll(/\bplatform\??\.(posixShell|findCommand|browsers|makeCommand)\b(?!Soon)/g)) {
        (counted[name!] ??= {})[file] = ((counted[name!] ??= {})[file] ?? 0) + 1;
        if (allowed[name!]!.marked && !l.marked) unmarked.push(at(l));
      }
    }
  }
  for (const [name, { at: where }] of Object.entries(allowed)) assert.deepEqual(counted[name] ?? {}, where, `platform.${name}: use ${name}Soon`);
  assert.deepEqual(unmarked, [], "said why with sync:");
});

test("no synchronous call of node:fs or node:zlib on the main thread but those said why (sync:) and those standing", async () => {
  const found: string[] = [];
  const standing = new Map<string, number>();
  for (const { file, text, lines } of await sources()) {
    const { named, modules } = imported(text);
    const local = [...named].filter(([, name]) => SYNC_NAMES.has(name)).map(([as]) => as);
    for (const l of lines) {
      if (l.marked) continue;
      const bare = local.some((as) => new RegExp(`(?<![\\w$.])${as.replace("$", "\\$")}\\s*\\(`).test(l.code));
      // A module's by any name (fs.statSync), and what a module is given as (an `fs` passed in) by the call's name.
      const member = [...l.code.matchAll(/([\w$]+)\??\.([\w$]+Sync)(?:\.native)?\s*\(/g)].some(([, on, name]) => modules.has(on!) || SYNC_NAMES.has(name!));
      if (!bare && !member) continue;
      if (STANDING.includes(file)) standing.set(file, (standing.get(file) ?? 0) + 1);
      else found.push(at(l));
    }
  }
  assert.deepEqual(found, [], "off the thread (fs/promises, zlib's callbacks), or `sync:` and why on its line: read before the station serves, or one step that must not be split");
  assert.deepEqual(STANDING.filter((file) => !standing.has(file)), [], "none left standing in it: take it off STANDING");
});
