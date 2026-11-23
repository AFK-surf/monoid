// What the MoonBit station (station/mb/src/station_main, `stillfail-reader run`) must wire for it to do all the
// TypeScript does, read from both sources as they are: a release runs it alone again only once these hold
// (station/AGENTS.md). Its packages' tests (`mb-*.test.ts`) hold each package to the TypeScript through a harness of
// their own, which never goes through station_main; these hold station_main to what those packages and the TypeScript
// ask of it:
//
// - every call a package makes of the station's parts by name (`backend.ask("store.getSession", …)`, `w.call(…)`,
//   `self.w.part(…)`) is a name a dispatcher of the program answers (station_main, the stores' `call`, the hub's
//   `hub_call`, the shell's ops, a package's own host_io);
// - every route of the admin API the TypeScript serves (`src/**`: `{ method, pattern }`, `route(method, pattern)`) is
//   one the program serves (api_routes' table, station_main's parts' routes, or a part's own matcher named below);
// - every command and flag of `main.js` (`src/main.ts`, the launcher's channel `src/ops/launcher.ts`) is the program's
//   (`station_main/entry.mbt`, `run.mbt`, `cli.mbt`), and every `STILLFAIL_*` the TypeScript reads, the program reads.
//
// Every check must pass: nothing is let off as known to be missing. What a check passes over is `NOT_REACHED` (an
// asker the program never makes, each with what shows it), itself checked to be so.
import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const station = fileURLToPath(new URL("..", import.meta.url));
const mb = join(station, "mb", "src");
const repo = join(station, "..");

/// Calls a package makes that the program never reaches: each with a check that it is so.
const NOT_REACHED: { name: string; why: string; holds: () => boolean }[] = [];

/// The parts a dispatcher answers whole, whatever the method (the conversations' world, live_p5_2_chats.mbt
/// `chats_answer`: `match part { "files" => … }`): a package's call of one is answered there.
const ANSWERED_WHOLE: { pkg: string; part: string; file: string; arm: RegExp }[] = [
  { pkg: "session_chats", part: "files", file: "live_p5_2_chats.mbt", arm: /^    "files" => \{$/m },
];

const read = (p: string) => readFileSync(p, "utf8");
const walk = (dir: string, keep: (p: string) => boolean): string[] =>
  readdirSync(dir).flatMap((n) => {
    const p = join(dir, n);
    return statSync(p).isDirectory() ? walk(p, keep) : keep(p) ? [p] : [];
  });
const mbt = (dir: string) => walk(dir, (p) => p.endsWith(".mbt") && !/_(wb)?test\.mbt$/.test(p));
let programText: string | null = null;
const programSource = () => (programText ??= mbt(join(mb, "station_main")).map(read).join("\n"));

// ── checks by name, judged together ──
type Result = { name: string; ok: boolean; why: string };
function judge(results: Result[]) {
  return results.filter((r) => !r.ok).map((r) => `${r.name}: ${r.why}`);
}

// ── the calls by name ──

/// What answers a call by name in the program: every literal its dispatchers match.
function answered(): Set<string> {
  const files = [
    ...mbt(join(mb, "station_main")),
    // (the stores' `call`, the hub's `hub_call`, the memory builder's ops, the front's asks)
    ...["store_sessions", "store_threads", "session_hub", "memory", "front"].flatMap((p) => mbt(join(mb, p))),
    // (a package's own world on the program: updates/host_io.mbt and the like)
    ...readdirSync(mb).flatMap((p) => {
      try {
        return readdirSync(join(mb, p)).filter((n) => /^host_io.*\.mbt$/.test(n)).map((n) => join(mb, p, n));
      } catch {
        return [];
      }
    }),
    // (the shell's ops, client/shell: `fs.*`, `text.*`, `fetch`)
    ...walk(join(repo, "client", "shell", "src"), (p) => p.endsWith(".rs")),
    // (the words a part says by key)
    join(repo, "client", "i18n", "catalog", "zh", "station.json"),
    join(repo, "client", "i18n", "catalog", "en", "station.json"),
  ];
  const out = new Set<string>();
  for (const f of files) for (const m of read(f).matchAll(/"([A-Za-z$#_][\w$#./:-]*)"/g)) out.add(m[1]!);
  return out;
}

/// The calls each package makes by name, where it makes them first (a package's harness, `harness*.mbt`, is its tests'
/// and is not read).
function asked(): Map<string, Map<string, string>> {
  const out = new Map<string, Map<string, string>>();
  // (station_main is what answers; reader's are Node's to answer, mb-*.ts; browser's are Chrome's, CDP)
  for (const pkg of readdirSync(mb).filter((p) => statSync(join(mb, p)).isDirectory() && !["station_main", "reader", "browser"].includes(p))) {
    const calls = new Map<string, string>();
    for (const f of mbt(join(mb, pkg)).filter((f) => !/\/harness[^/]*\.mbt$/.test(f))) {
      read(f).split("\n").forEach((line, i) => {
        if (/^\s*\/\//.test(line)) return;
        // (an Own's `tell` and `note` are its trace, agent_runtimes' own)
        for (const m of line.matchAll(/(?<!own)\.(?:ask|call|tell|part|op)\("([A-Za-z$#_][\w$#]*(?:\.[\w$#]+)*)"/g)) {
          if (!calls.has(m[1]!)) calls.set(m[1]!, `${relative(station, f)}:${i + 1}`);
        }
      });
    }
    if (calls.size > 0) out.set(pkg, calls);
  }
  return out;
}

/// Whether a name is answered: as it is, or by what is left of it once a dispatcher took its part's prefix
/// (`hub.allowanceReset` → `allowanceReset`, `drive.scoped` → `scoped`).
const wired = (name: string, literals: Set<string>) => {
  if (literals.has(name)) return true;
  const parts = name.split(".");
  for (let i = 1; i < parts.length; i++) if (literals.has(parts.slice(i).join("."))) return true;
  return false;
};

test("every call a package makes of the station's parts by name is answered in the program", () => {
  const literals = answered();
  const calls = asked();
  const results: Result[] = [];
  let counted = 0;
  for (const [pkg, names] of calls) {
    for (const [name, where] of names) {
      counted++;
      const check = `rpc ${pkg} ${name}`;
      const skipped = NOT_REACHED.find((n) => n.name === check);
      if (skipped !== undefined) continue;
      const whole = ANSWERED_WHOLE.find((w) => w.pkg === pkg && name.startsWith(`${w.part}.`) && w.arm.test(read(join(mb, "station_main", w.file))));
      results.push({ name: check, ok: whole !== undefined || wired(name, literals), why: `asked at ${where}, answered nowhere in station_main, the stores, the hub, the shell or a host_io` });
    }
  }
  // (what is passed over is so, and is still asked)
  for (const n of NOT_REACHED) {
    const [, pkg, name] = n.name.split(" ");
    assert.ok(calls.get(pkg!)?.has(name!), `${n.name} is not asked any more: take it out of NOT_REACHED`);
    assert.ok(n.holds(), `${n.name} is reached now (${n.why}): take it out of NOT_REACHED`);
  }
  for (const w of ANSWERED_WHOLE) assert.match(read(join(mb, "station_main", w.file)), w.arm, `${w.file} answers ${w.part} whole no more: take it out of ANSWERED_WHOLE`);
  assert.ok(counted > 300, `the calls read: ${counted} (fewer than ever: the scan has stopped finding them)`);
  const wrong = judge(results);
  assert.deepEqual(wrong, [], wrong.join("\n"));
});

// ── the admin API's routes ──

/// A route's pattern as both write it, made one: `\/` and `/`, `\/*` and `\/+` and `/`, a trailing `(?:\/.*)?`,
/// `\/?` or `\/*` before the end.
const canon = (method: string, pattern: string) =>
  `${method} ${pattern.replace(/\\\//g, "/").replace(/\/\*|\/\+/g, "/").replace(/\(\?:\/\.\*\)\?/g, "").replace(/\/\?\$$/, "$").replace(/\/\$$/, "$").replace(/^\^\/\//, "^/")}`;

/// The TypeScript's routes: `{ method: "GET", pattern: /…/ }` and `route("GET", /…/)` anywhere in src/.
function tsRoutes(): { routes: Map<string, string>; named: string[] } {
  const routes = new Map<string, string>();
  const named: string[] = [];
  for (const f of walk(join(station, "src"), (p) => p.endsWith(".ts"))) {
    const t = read(f);
    for (const m of t.matchAll(/(?:method:\s*"([A-Z]+)",\s*pattern:|route\(\s*"([A-Z]+)",)\s*(\/|[A-Za-z_]+)/g)) {
      const method = m[1] ?? m[2]!;
      if (m[3] !== "/") {
        named.push(`${method} ${m[3]} (${relative(station, f)})`);
        continue;
      }
      // (a regular expression's literal, to its closing slash: not one inside a class or escaped)
      let i = m.index! + m[0].length;
      let inClass = false;
      let source = "";
      for (; i < t.length; i++) {
        const c = t[i]!;
        if (c === "\\") {
          source += c + t[++i];
          continue;
        }
        if (inClass) {
          if (c === "]") inClass = false;
        } else if (c === "[") inClass = true;
        else if (c === "/") break;
        source += c;
      }
      routes.set(canon(method, source), relative(station, f));
    }
  }
  return { routes, named };
}

/// The program's: api_routes' `route("GET", "…")` and station_main's parts' `{ meth: "GET", path: "^…$" }`.
function mbRoutes(): Map<string, string> {
  const routes = new Map<string, string>();
  for (const f of mbt(mb).filter((f) => !/\/harness[^/]*\.mbt$/.test(f))) {
    const t = read(f);
    for (const m of t.matchAll(/route\(\s*"([A-Z]+)",\s*"((?:\\.|[^"\\])*)"/g)) routes.set(canon(m[1]!, m[2]!.replace(/\\\\/g, "\\")), relative(station, f));
    for (const m of t.matchAll(/meth:\s*"([A-Z]+)",\s*path:\s*"(\^(?:\\.|[^"\\])*)"/g)) routes.set(canon(m[1]!, m[2]!.replace(/\\\\/g, "\\")), relative(station, f));
  }
  return routes;
}

/// The TypeScript's routes the program answers by a matcher of a part's own rather than a pattern: where, and the
/// condition it is matched by there.
const MATCHED: Record<string, [string, RegExp]> = {
  "PUT ^/elevation$": ["rigs_mode/elevation.mbt", /meth == "PUT" && path == "\/elevation"/],
  "PUT ^/screen-service$": ["rigs_mode/screen_service.mbt", /meth == "PUT" && path == "\/screen-service"/],
  "POST ^/move$": ["move_coord/routes.mbt", /method_: "POST", matches: p => is_path\(p, "\/move"\)/],
  "POST ^/move/back$": ["move_coord/routes.mbt", /is_path\(p, "\/move\/back"\)/],
  "POST ^/move/stop$": ["move_coord/routes.mbt", /is_path\(p, "\/move\/stop"\)/],
  "GET ^/move$": ["move_coord/routes.mbt", /method_: "GET",\s*matches: p => is_path\(p, "\/move"\)/],
  "GET ^/rigs$": ["rigs_mode/rigs.mbt", /meth == "GET" && path == "\/rigs"/],
  "GET ^/rigs/([0-9a-f]{64})/log$": ["rigs_mode/rigs.mbt", /meth == "GET" && n == 4 && parts\[1\] == "rigs" && hex64\(parts\[2\]\) && parts\[3\] == "log"/],
  "POST ^/rigs/requests/([^/]+)/decide$": ["rigs_mode/rigs.mbt", /parts\[2\] == "requests" && parts\[3\] != "" && parts\[4\] == "decide"/],
  "POST ^/rigs/requests/([^/]+)/revoke$": ["rigs_mode/rigs.mbt", /parts\[2\] == "requests" && parts\[3\] != "" && parts\[4\] == "revoke"/],
  "POST ^/rigs/([0-9a-f]{64})/settings$": ["rigs_mode/rigs.mbt", /hex64\(parts\[2\]\) && \(parts\[3\] == "settings" \|\| parts\[3\] == "devices"\)/],
  "POST ^/rigs/([0-9a-f]{64})/devices$": ["rigs_mode/rigs.mbt", /hex64\(parts\[2\]\) && \(parts\[3\] == "settings" \|\| parts\[3\] == "devices"\)/],
  "POST ^/rigs/([0-9a-f]{64})/add$": ["rigs_mode/rigs.mbt", /hex64\(parts\[2\]\) && parts\[3\] == "add"/],
  "POST ^/rigs/([0-9a-f]{64})/full$": ["rigs_mode/rigs.mbt", /hex64\(parts\[2\]\) && parts\[3\] == "full"/],
  "POST ^/rigs/([0-9a-f]{64})/join$": ["rigs_mode/rigs.mbt", /hex64\(parts\[2\]\) && parts\[3\] == "join"/],
  "POST ^/mode$": ["rigs_mode/rigs.mbt", /meth == "POST" && path == "\/mode"/],
};

test("every route of the TypeScript's admin API is one the program serves", () => {
  const { routes: ts, named } = tsRoutes();
  const served = mbRoutes();
  assert.ok(ts.size > 200, `the TypeScript's routes read: ${ts.size}`);
  // (the two the TypeScript names by a constant or builds: each held as the program writes it)
  assert.deepEqual(named.map((n) => n.split(" (")[0]), ["POST new", "POST REPORT_PATH"], named.join("; "));
  assert.match(read(join(station, "src", "api", "admin.ts")), /pattern: new RegExp\(`\^\/screens\/\(\[\^\/\]\+\)\/\$\{path\}\$`\)/);
  assert.ok(served.has("POST ^/screens/([^/]+)/\\{path}$"), "the program's screens' actions, by the same pattern");
  const report = /export const REPORT_PATH = (\/.*\/);/.exec(read(join(station, "src", "feedback", "notice.ts")))?.[1];
  assert.ok(report !== undefined, "feedback/notice.ts REPORT_PATH");
  const results: Result[] = [];
  for (const [route, where] of ts) {
    const matched = MATCHED[route];
    const ok = served.has(route) || (matched !== undefined && matched[1].test(read(join(mb, matched[0]))));
    results.push({ name: `route ${route}`, ok, why: `${where} serves it; no route of the program's has this pattern${matched ? ` and ${matched[0]} no longer matches it so` : ""}` });
  }
  for (const route of Object.keys(MATCHED)) assert.ok(ts.has(route), `${route}: no route of the TypeScript's any more, take it out of MATCHED`);
  const wrong = judge(results);
  assert.deepEqual(wrong, [], wrong.join("\n"));
});

// ── the commands, flags and environment ──

test("every command and flag of main.js and the launcher's channel is the program's", () => {
  const main = read(join(station, "src", "main.ts"));
  const launcher = read(join(station, "src", "ops", "launcher.ts"));
  const entry = read(join(mb, "station_main", "entry.mbt"));
  const program = ["run.mbt", "cli.mbt", "entry.mbt"].map((f) => read(join(mb, "station_main", f))).join("\n");
  // (a `case` of commandMain's switch, or a command it takes before it: `run`)
  const commands = [...new Set([...main.matchAll(/^\s+case "([a-z-]+)":|\bcommand === "([a-z-]+)"/gm)].map((m) => (m[1] ?? m[2])!))];
  const theirs = /let station_commands : Array\[String\] = \[([^\]]*)\]/.exec(entry)?.[1] ?? "";
  const results: Result[] = [];
  assert.ok(commands.length >= 8, `main.ts's commands: ${commands.join(",")}`);
  for (const c of commands) results.push({ name: `command ${c}`, ok: theirs.includes(`"${c}"`), why: `main.ts runs \`${c}\`; entry.mbt station_commands has no "${c}"` });
  const flags = new Set([...`${main}\n${launcher}`.matchAll(/"(--[a-z][a-z0-9-]*)/g)].map((m) => m[1]!));
  assert.ok(flags.size >= 15, `the flags read: ${[...flags].join(",")}`);
  for (const f of flags) results.push({ name: `flag ${f}`, ok: program.includes(`"${f}"`), why: `main.ts or ops/launcher.ts reads ${f}; run.mbt, cli.mbt and entry.mbt never name it` });
  const wrong = judge(results);
  assert.deepEqual(wrong, [], wrong.join("\n"));
});

/// What the TypeScript reads that the program has no use for: each with why.
const ENV_NOT_THE_PROGRAMS: Record<string, string> = {
  STILLFAIL_MB_READER: "where Node finds the program, which is itself here",
  STILLFAIL_NODE: "the Node the launcher runs main.js with",
  STILLFAIL_TEST_TMP: "the TypeScript tests' temporary directory (test/setup-env.mjs)",
  STILLFAIL_ACTORS_TRACE: "a trace of Node's shells of the actors (sessions/mb-actor.ts), which the program has none of",
};

test("every STILLFAIL_* the TypeScript station reads, the program reads", () => {
  const read_ = (files: string[]) => new Set(files.flatMap((f) => [...read(f).matchAll(/\b(STILLFAIL_[A-Z0-9_]+)\b/g)].map((m) => m[1]!)));
  const ts = read_(walk(join(station, "src"), (p) => p.endsWith(".ts")));
  const theirs = read_(mbt(mb));
  const missing = [...ts].filter((v) => !theirs.has(v) && !(v in ENV_NOT_THE_PROGRAMS)).sort();
  assert.deepEqual(missing, [], `read by src/ and by no .mbt: ${missing.join(", ")}`);
  for (const v of Object.keys(ENV_NOT_THE_PROGRAMS)) assert.ok(ts.has(v) && !theirs.has(v), `${v}: take it out of ENV_NOT_THE_PROGRAMS`);
});

// ── the hooks that are no call by name: the bus's providers, what a handover carries, what the plane tells, what
// the event streams follow ──

/// station_main's own files, its harnesses' (a slice test's stand-ins) left out.
const programFiles = () => mbt(join(mb, "station_main")).filter((f) => !/\/harness[^/]*\.mbt$/.test(f));
const tsFiles = () => walk(join(station, "src"), (p) => p.endsWith(".ts") && !p.endsWith(".test.ts"));

/// The `LiveBus` fields that are `Ref`s no slice gives anew: each with why.
const BUS_REFS_GIVEN_WHOLE: Record<string, string> = {
  own_add: "LiveBus::new's own list of the data directory's paths, which every slice adds to through it",
  own_paths: "LiveBus::new's own list of the data directory's paths, read whole",
};

test("every Ref of the composition bus is given by a slice", () => {
  const bus = read(join(mb, "station_main", "live_bus.mbt"));
  const body = /pub\(all\) struct LiveBus \{([\s\S]*?)\n\}/.exec(bus)?.[1] ?? "";
  const refs = [...body.matchAll(/^\s+([a-z_]+) : Ref\[/gm)].map((m) => m[1]!);
  assert.ok(refs.length >= 30, `the bus's Refs read: ${refs.length}`);
  const program = programFiles().map(read).join("\n");
  const results: Result[] = refs.filter((r) => !(r in BUS_REFS_GIVEN_WHOLE)).map((r) => ({
    name: `bus ${r}`,
    ok: new RegExp(`\\.${r}\\.val = `).test(program),
    why: `live_bus.mbt's ${r} keeps LiveBus::new's stand-in: no slice says \`.${r}.val = …\``,
  }));
  for (const r of Object.keys(BUS_REFS_GIVEN_WHOLE)) assert.ok(refs.includes(r), `${r}: no Ref of the bus any more, take it out of BUS_REFS_GIVEN_WHOLE`);
  const wrong = judge(results);
  assert.deepEqual(wrong, [], wrong.join("\n"));
});

/// The literal first arguments of `<callee>("…",` in `files`, each with where it is first.
function firstArgs(files: string[], callee: RegExp): Map<string, string> {
  const out = new Map<string, string>();
  for (const f of files) {
    read(f).split("\n").forEach((line, i) => {
      if (/^\s*\/\//.test(line)) return;
      for (const m of line.matchAll(new RegExp(`${callee.source}\\(\\s*"([^"]+)",`, "g"))) {
        if (!out.has(m[1]!)) out.set(m[1]!, `${relative(station, f)}:${i + 1}`);
      }
    });
  }
  return out;
}

test("everything the TypeScript carries over a handover, the program carries", () => {
  const ts = firstArgs(tsFiles(), /\bparts\.carry/);
  const theirs = firstArgs(programFiles(), /\.carry/);
  assert.ok(ts.size >= 3, `the TypeScript's carried parts: ${[...ts.keys()].join(",")}`);
  const results: Result[] = [...ts].map(([key, where]) => ({ name: `carry ${key}`, ok: theirs.has(key), why: `${where} carries "${key}"; no \`.carry("${key}", …)\` in station_main` }));
  const wrong = judge(results);
  assert.deepEqual(wrong, [], wrong.join("\n"));
});

test("everything the control plane's presence tells the TypeScript, the program follows", () => {
  const ts = firstArgs(tsFiles(), /\b(?:plane|control)\.told/);
  const theirs = firstArgs(programFiles(), /\bcontrol\.told/);
  assert.ok(ts.size >= 2, `the kinds the TypeScript follows: ${[...ts.keys()].join(",")}`);
  const results: Result[] = [...ts].map(([kind, where]) => ({ name: `told ${kind}`, ok: theirs.has(kind), why: `${where} follows the plane's "${kind}"; no \`control.told("${kind}", …)\` in station_main` }));
  const wrong = judge(results);
  assert.deepEqual(wrong, [], wrong.join("\n"));
});

/// The arguments' names at the top level of each `events.follow(…)` call in `text` (`{ key: …, key(…) {…} }` in the
/// TypeScript, `key=…` in the program).
function followed(text: string, labelled: boolean): Set<string> {
  const out = new Set<string>();
  text = text.replace(/^\s*\/\/.*$/gm, "");
  for (const m of text.matchAll(/\bevents\.follow\(/g)) {
    let depth = 0;
    let i = m.index! + m[0].length;
    let word = "";
    let quoted: string | null = null;
    for (; i < text.length; i++) {
      const c = text[i]!;
      if (quoted !== null) {
        if (c === "\\") i++;
        else if (c === quoted) quoted = null;
        continue;
      }
      if (c === '"' || c === "'" || c === "`") quoted = c;
      else if ("({[".includes(c)) depth++;
      else if (")}]".includes(c)) {
        if (depth === 0) break;
        depth--;
      }
      const top = labelled ? depth === 0 : depth === 1;
      if (/[A-Za-z_]/.test(c)) word += c;
      else {
        if (top && word !== "" && (labelled ? c === "=" && text[i + 1] !== ">" && text[i + 1] !== "=" : c === ":" || c === "(")) out.add(word);
        word = "";
      }
    }
  }
  return out;
}

const snake = (s: string) => s.replace(/[A-Z]/g, (c) => `_${c.toLowerCase()}`);

test("every hook the TypeScript gives the event streams, the program gives them", () => {
  const ts = new Map<string, string>();
  for (const f of tsFiles()) for (const k of followed(read(f), false)) if (!ts.has(k)) ts.set(k, relative(station, f));
  const theirs = new Set<string>();
  for (const f of programFiles()) for (const k of followed(read(f), true)) theirs.add(k);
  assert.ok(ts.size >= 8, `the hooks the TypeScript gives: ${[...ts.keys()].join(",")}`);
  const results: Result[] = [...ts].map(([key, where]) => ({ name: `events.follow ${key}`, ok: theirs.has(snake(key)), why: `${where} gives events.follow ${key}; no events.follow(${snake(key)}=…) in station_main` }));
  const wrong = judge(results);
  assert.deepEqual(wrong, [], wrong.join("\n"));
});

// ── what one part of the program asks another by name ──

/// The call of each argument of `f(` at `open` (its index just past the paren) in `text`: the arguments' text, split at
/// the commas of its own level.
function argsAt(text: string, open: number): string[] {
  const out: string[] = [];
  let depth = 0;
  let start = open;
  let quoted = false;
  for (let i = open; i < text.length; i++) {
    const c = text[i]!;
    if (quoted) {
      if (c === "\\") i++;
      else if (c === '"') quoted = false;
      continue;
    }
    if (c === '"') quoted = true;
    else if (c === "(" || c === "[" || c === "{") depth++;
    else if (c === ")" || c === "]" || c === "}") {
      if (depth === 0) {
        out.push(text.slice(start, i));
        return out;
      }
      depth--;
    } else if (c === "," && depth === 0) {
      out.push(text.slice(start, i));
      start = i + 1;
    }
  }
  return out;
}

/// The names a dispatcher of `files` answers: every literal of a `match` arm (`"a" | "b" if … =>`), a P5-5 part's
/// `op("…"`, and the prefixes it takes the rest of a name by (`op.has_prefix("…")`, `prefix_op("…"`).
function dispatched(files: string[]): { arms: Set<string>; prefixes: string[] } {
  const arms = new Set<string>();
  const prefixes: string[] = [];
  for (const f of files) {
    const text = read(f);
    for (const line of text.split("\n")) {
      const arm = /^\s*("[^"\n]+"(?:\s*\|\s*"[^"\n]+")*)\s*(?:if\b.*)?=>/.exec(line);
      if (arm) for (const m of arm[1]!.matchAll(/"([^"]+)"/g)) arms.add(m[1]!);
    }
    for (const m of text.matchAll(/\.op\(\s*"([^"]+)"|\b(?:op|name|what) == "([^"]+)"/g)) arms.add((m[1] ?? m[2])!);
    for (const m of text.matchAll(/\b(?:op|name|what)\.has_prefix\("([^"]+)"\)|\.prefix_op\(\s*"([^"]+)"/g)) prefixes.push((m[1] ?? m[2])!);
  }
  return { arms, prefixes };
}

test("every method the hub asks of a session's actor is one the actors answer", () => {
  // (session_hub's `Hub::act(key, method, args?)`, told the sessions' program, which runs it: reader/actor_run.mbt
  // `Actors::called`; one it does not know raised there, in the program, long after the hub went on: `L10`'s
  // `evictThenCleanArchive`)
  const run = read(join(mb, "reader", "actor_run.mbt"));
  const called = /\nasync fn Actors::called\([\s\S]*?\n\}\n/.exec(run)?.[0] ?? "";
  assert.ok(called.length > 0, "reader/actor_run.mbt has no Actors::called");
  const { arms } = dispatched([]);
  for (const line of called.split("\n")) {
    const arm = /^    ("[^"\n]+"(?:\s*\|\s*"[^"\n]+")*)\s*(?:if\b.*)?=>/.exec(line);
    if (arm) for (const m of arm[1]!.matchAll(/"([^"]+)"/g)) arms.add(m[1]!);
  }
  assert.ok(arms.size >= 20, `the actors' methods read: ${[...arms].join(",")}`);
  const results: Result[] = [];
  for (const f of mbt(join(mb, "session_hub")).filter((f) => !/\/(?:hub_)?harness[^/]*\.mbt$/.test(f))) {
    const text = read(f);
    for (const m of text.matchAll(/\.act\(/g)) {
      const args = argsAt(text, m.index! + m[0].length);
      const where = `${relative(station, f)}:${text.slice(0, m.index).split("\n").length}`;
      // (its literals, a condition's own taken out: `if is_true(x, "refill") { "takeRefill" } else { "takeWait" }`)
      const methods = [...(args[1] ?? "").replace(/\w+\([^()]*\)/g, "").matchAll(/"([^"]+)"/g)].map((x) => x[1]!);
      results.push({ name: `act ${where}`, ok: methods.length > 0, why: `the method asked is no literal: ${args[1]}` });
      for (const method of methods) results.push({ name: `act ${method}`, ok: arms.has(method), why: `${where} asks a session's actor for "${method}", which reader/actor_run.mbt Actors::called does not answer` });
    }
  }
  assert.ok(results.length >= 20, `the hub's asks of its actors read: ${results.length}`);
  const wrong = judge(results);
  assert.deepEqual(wrong, [], wrong.join("\n"));
});

/// Where a slice answers what the others ask it on the bus (station_main/AGENTS.md: `hub_ask`, `jobs_ask`, `ui_ask`,
/// `coord_ask`), by its files.
const ASK_ANSWERED_IN: Record<string, RegExp> = {
  // (and a station that only runs tasks gives its own, live_p5_1_rigs.mbt)
  hub: /\/live_p5_2_[^/]*\.mbt$|\/live_p5_1_rigs\.mbt$/,
  jobs: /\/live_p5_3[^/]*\.mbt$/,
  ui: /\/live_p5_4[^/]*\.mbt$/,
  coord: /\/live_p5_5[^/]*\.mbt$/,
};

/// What a slice's dispatcher hands on whole, what it does not answer itself: each with what answers there and a check
/// that it is handed on.
const ASK_HANDED_ON: { slice: string; answers: () => string; why: string; holds: () => boolean }[] = [
  {
    slice: "hub",
    answers: () => /\npub async fn hub_call\([\s\S]*?\n\}\n/.exec(read(join(mb, "session_hub", "hub_call.mbt")))?.[0] ?? "",
    why: "P5-2's hub_bridge (live_p5_2_hubops.mbt) asks session_hub's hub_call what it does not answer",
    holds: () => /@session_hub\.hub_call\(hub, name, args\)/.test(read(join(mb, "station_main", "live_p5_2_hubops.mbt"))),
  },
];

/// Helpers that ask by the name of an `ask` they are given, not by the bus's: each with the slice it is given and a
/// check that it is so.
const ASKED_THROUGH: { file: string; fn: RegExp; slice: string; why: string; holds: () => boolean }[] = [
  {
    file: "live_bus.mbt",
    fn: /^async fn asked_\w+\(\s*ask : /,
    slice: "jobs",
    why: "Claude's logins (live_p5_2_drivers.mbt p52_claude_logins) are given the bus's jobs_ask",
    holds: () => /p52_claude_logins\(pump, host, \(op, arg\) => \(ctx\.bus\.jobs_ask\.val\)\(op, arg\)\)/.test(read(join(mb, "station_main", "live_p5_2_drivers.mbt"))),
  },
];

test("every name a slice asks of another on the bus is one that slice answers", () => {
  const files = programFiles();
  const answers = Object.fromEntries(Object.entries(ASK_ANSWERED_IN).map(([slice, re]) => [slice, dispatched(files.filter((f) => re.test(f)))]));
  for (const h of ASK_HANDED_ON) {
    assert.ok(h.holds(), `${h.slice}: ${h.why}, no longer so: take it out of ASK_HANDED_ON`);
    const text = h.answers();
    assert.ok(text.length > 0, `${h.slice}: what it is handed on to is not there`);
    for (const line of text.split("\n")) {
      const arm = /^\s*("[^"\n]+"(?:\s*\|\s*"[^"\n]+")*)\s*(?:if\b.*)?=>/.exec(line);
      if (arm) for (const m of arm[1]!.matchAll(/"([^"]+)"/g)) answers[h.slice]!.arms.add(m[1]!);
    }
  }
  // (a prefix handed on whole, `store.` to the stores: what is left of the name answered anywhere a call by name is)
  const anywhere = answered();
  const asks: { slice: string; op: string; where: string }[] = [];
  for (const f of files) {
    const text = read(f);
    const at = (i: number) => `${relative(station, f)}:${text.slice(0, i).split("\n").length}`;
    // (by the bus's Ref: `(bus.hub_ask.val)("op", …)`, `asked(bus.jobs_ask.val, "op", …)`)
    for (const m of text.matchAll(/\(\s*(?:[\w.()]+\.)?(hub|jobs|ui|coord)_ask\.val\s*\)\(\s*"([^"]*)"|\basked\(\s*(?:[\w.()]+\.)?(hub|jobs|ui|coord)_ask\.val\s*,\s*"([^"]*)"/g)) {
      asks.push({ slice: (m[1] ?? m[3])!, op: (m[2] ?? m[4])!, where: at(m.index!) });
    }
    // (by a name given it: `let jobs = bus.jobs_ask.val` … `asked(jobs, "op", …)`, `jobs("op", …)`)
    for (const alias of text.matchAll(/\blet (\w+) = (?:[\w.()]+\.)?(hub|jobs|ui|coord)_ask\.val\b/g)) {
      for (const m of text.matchAll(new RegExp(`\\basked\\(\\s*${alias[1]}\\s*,\\s*"([^"]*)"|(?<![\\w.])${alias[1]}\\(\\s*"([^"]*)"`, "g"))) {
        asks.push({ slice: alias[2]!, op: (m[1] ?? m[2])!, where: at(m.index!) });
      }
    }
  }
  for (const h of ASKED_THROUGH) {
    assert.ok(h.holds(), `${h.file}: ${h.why}, no longer so: take it out of ASKED_THROUGH`);
    const text = read(join(mb, "station_main", h.file));
    const fns = text.split("\n///|\n").filter((b) => h.fn.test(b.replace(/^(?:\/\/\/[^\n]*\n)*/, "")));
    assert.ok(fns.length > 0, `${h.file}: nothing of ${h.fn}`);
    for (const b of fns) for (const m of b.matchAll(/\bask\(\s*"([^"]*)"/g)) asks.push({ slice: h.slice, op: m[1]!, where: `${h.file} (${h.slice}_ask)` });
  }
  assert.ok(asks.length >= 60, `the asks of the bus read: ${asks.length}`);
  for (const s of Object.keys(ASK_ANSWERED_IN)) assert.ok(asks.some((a) => a.slice === s), `nothing asked of ${s}_ask: the reading is wrong`);
  const results: Result[] = asks.map(({ slice, op, where }) => {
    const { arms, prefixes } = answers[slice]!;
    // (a name made at the call, `"chat." + what`, `"device.\{op}"`: answered by a prefix its slice takes, or arms of it)
    const made = op.indexOf("\\{");
    const name = made >= 0 ? op.slice(0, made) : op;
    const open = made >= 0 || name.endsWith(".");
    const ok = open
      ? prefixes.some((p) => name.startsWith(p) || p.startsWith(name)) || [...arms].some((a) => a.startsWith(name))
      : arms.has(name) || prefixes.some((p) => name.startsWith(p) && (arms.has(name.slice(p.length)) || anywhere.has(name.slice(p.length))));
    return { name: `${slice}_ask ${op}`, ok, why: `${where} asks ${slice}_ask for "${op}", which no dispatcher of its slice answers` };
  });
  const wrong = judge(results);
  assert.deepEqual(wrong, [], wrong.join("\n"));
});

/// Bare `hub.act(...)` calls in `station_main` bypass `Hub::command` / `Hub::notify` cold-session wakeup.
/// Zero bare `hub.act(` calls are permitted anywhere in `station_main`.
test("station_main has no bare hub.act() calls bypassing cold-session wakeup", () => {
  const unexpected: string[] = [];
  for (const f of programFiles()) {
    const rel = relative(station, f);
    const text = read(f);
    for (const m of text.matchAll(/\.act\(/g)) {
      const lineStart = text.lastIndexOf("\n", m.index!) + 1;
      const lineEnd = text.indexOf("\n", m.index!);
      const line = text.slice(lineStart, lineEnd === -1 ? text.length : lineEnd);
      if (/^\s*\/\//.test(line) || /\bhold\.act\(/.test(line)) continue;
      const args = argsAt(text, m.index! + m[0].length);
      const method = /^\s*"([^"]+)"\s*$/.exec(args[1] ?? "")?.[1] ?? "<dynamic>";
      const lineNo = text.slice(0, m.index!).split("\n").length;
      unexpected.push(`${rel}:${lineNo} calls .act(..., "${method}") directly`);
    }
  }
  assert.deepEqual(unexpected, [], unexpected.join("\n"));
});

/// Prevent Wave 1 & Wave 2 style empty placeholder callbacks from creeping back into `station_main` slice wiring.
test("station_main slice wiring has no empty stub callbacks", () => {
  const unexpected: string[] = [];
  const sliceFiles = programFiles().filter((f) => !f.endsWith("/live_bus.mbt"));
  for (const f of sliceFiles) {
    const rel = relative(station, f);
    const lines = read(f).split("\n");
    lines.forEach((line, i) => {
      if (/^\s*\/\//.test(line)) return;
      if (/\b_connect\s*=>\s*\[\]/.test(line)) {
        unexpected.push(`${rel}:${i + 1} has empty connect placeholder callback \`_connect => []\``);
      }
      if (/\bon_close:\s*_\w*\s*=>\s*\(\)\s*=>\s*\(\)/.test(line)) {
        unexpected.push(`${rel}:${i + 1} has no-op unsubscribe callback \`on_close: _ => () => ()\``);
      }
      if ((rel.endsWith("live_p5_5_connects.mbt") || rel.endsWith("live_p5_5_platforms.mbt")) && /\bignore\(\s*(?:handler|cb|on_message|callback)\s*\)/.test(line)) {
        unexpected.push(`${rel}:${i + 1} drops connects callback with ignore(...)`);
      }
    });
  }
  assert.deepEqual(unexpected, [], unexpected.join("\n"));
});

/// Every MCP tool declared by the TypeScript station must be declared and wired in the MoonBit program,
/// and no `station_main` PartTool or PartRoute may contain a todo/not-implemented stub.
test("every TypeScript MCP tool is declared and wired in MoonBit without stub implementations", () => {
  const tsToolNames = new Set<string>();
  for (const f of tsFiles()) {
    const t = read(f);
    if (!f.includes("/tools/") && !f.endsWith("tools.ts") && !t.includes("parts.tools(")) continue;
    for (const m of t.matchAll(/^\s+name:\s*"([a-z][a-z0-9_]+)",\s*$/gm)) {
      const around = t.slice(m.index!, m.index! + 400);
      if (around.includes("description:") || around.includes("inputSchema:") || around.includes("parameters:")) {
        tsToolNames.add(m[1]!);
      }
    }
  }
  assert.ok(tsToolNames.size >= 30, `TypeScript MCP tools read: ${tsToolNames.size}`);
  const mbAllText = mbt(mb).filter((f) => !/\/harness[^/]*\.mbt$/.test(f)).map(read).join("\n");
  const missing = [...tsToolNames].filter((n) => !mbAllText.includes(`"${n}"`)).sort();
  assert.deepEqual(missing, [], `MCP tools in station/src/ missing from station/mb/src/: ${missing.join(", ")}`);

  const stubs: string[] = [];
  for (const f of programFiles()) {
    const rel = relative(station, f);
    read(f).split("\n").forEach((line, i) => {
      if (/^\s*\/\//.test(line)) return;
      if (/raise\s+Failure\(\s*"(?:todo|not implemented|stub)/i.test(line)) {
        stubs.push(`${rel}:${i + 1} contains stub Failure`);
      }
    });
  }
  assert.deepEqual(stubs, [], stubs.join("\n"));
});

/// Core real-process MoonBit parity suites (`mb-live-*.test.ts`) must never regress or silently vanish.
test("core live real-process parity suite list (mb-live-*.test.ts) does not regress", () => {
  const requiredLiveSuites = [
    "mb-live-accounts-handover.test.ts",
    "mb-live-canary-fixes.test.ts",
    "mb-live-comma-replica-parity.test.ts",
    "mb-live-connects-admin-parity.test.ts",
    "mb-live-devices-rigs-cards.test.ts",
    "mb-live-hooks-parity.test.ts",
    "mb-live-jobs-ops-parity.test.ts",
    "mb-live-locator.test.ts",
    "mb-live-mesh-remote-parity.test.ts",
    "mb-live-p5-1.test.ts",
    "mb-live-p5-2.test.ts",
    "mb-live-p5-3.test.ts",
    "mb-live-p5-4.test.ts",
    "mb-live-p5-5.test.ts",
    "mb-live-sessions-parity.test.ts",
    "mb-live-station.test.ts",
    "mb-live-vault-devices-parity.test.ts",
    "mb-live-vault-proxy-parity.test.ts",
  ];
  const testDir = join(station, "test");
  const present = new Set(readdirSync(testDir).filter((n) => /^mb-live-.*\.test\.ts$/.test(n)));
  assert.ok(present.size >= requiredLiveSuites.length, `mb-live-*.test.ts count regressed: ${present.size} < ${requiredLiveSuites.length}`);
  const missing = requiredLiveSuites.filter((name) => !present.has(name));
  assert.deepEqual(missing, [], `missing core live parity suites: ${missing.join(", ")}`);
  const emptySuites = requiredLiveSuites.filter((name) => !/\b(?:test|it)\s*\(/.test(read(join(testDir, name))));
  assert.deepEqual(emptySuites, [], `core live parity suites with no test cases: ${emptySuites.join(", ")}`);
});

// ── reader ↔ station_main & Node mb-actor.ts RPC contracts ──

/// Extract unique literal string matches with their first file:line occurrence.
function scanLiterals(files: string[], re: RegExp): Map<string, string> {
  const out = new Map<string, string>();
  for (const f of files) {
    const text = read(f);
    for (const m of text.matchAll(re)) {
      const name = m[1]!;
      if (!out.has(name)) {
        const line = text.slice(0, m.index!).split("\n").length;
        out.set(name, `${relative(station, f)}:${line}`);
      }
    }
  }
  return out;
}

/// Extract a single MoonBit function body starting at `header` through its closing `\n}` line.
function mbtFnBody(text: string, header: RegExp): string {
  const m = header.exec(text);
  assert.ok(m !== null, `function not found: ${header}`);
  const start = m.index!;
  const end = text.indexOf("\n}\n", start);
  return end < 0 ? text.slice(start) : text.slice(start, end + 3);
}

/// Extract `match` arm string literals from a MoonBit snippet.
function mbtMatchArms(snippet: string): Set<string> {
  const arms = new Set<string>();
  for (const line of snippet.split("\n")) {
    const arm = /^\s*("[^"\n]+"(?:\s*\|\s*"[^"\n]+")*)\s*(?:if\b.*)?=>/.exec(line);
    if (arm) for (const m of arm[1]!.matchAll(/"([^"]+)"/g)) arms.add(m[1]!);
  }
  return arms;
}

/// Extract `case "…":` string literals from a TypeScript snippet.
function tsSwitchCases(snippet: string): Set<string> {
  const out = new Set<string>();
  for (const m of snippet.matchAll(/\bcase\s+"([^"]+)"\s*:/g)) out.add(m[1]!);
  return out;
}

test("every RPC and tell that reader actors make is handled in station_main and Node mb-actor.ts", () => {
  const readerDir = join(mb, "reader");
  const actorFiles = [join(readerDir, "actor_base.mbt"), join(readerDir, "actor_run.mbt")];
  const actorsMbt = read(join(mb, "station_main", "live_p5_2_actors.mbt"));
  const ctxMbt = read(join(mb, "station_main", "live_p5_2_ctx.mbt"));
  const mainMbt = read(join(mb, "station_main", "live_p5_2_main.mbt"));
  const dispatchMbt = read(join(mb, "station_main", "live_dispatch.mbt"));
  const mbActorTs = read(join(station, "src", "sessions", "mb-actor.ts"));
  const actorTs = read(join(station, "src", "sessions", "actor.ts"));

  // 1. self.rpc(..., "node.<name>")
  const nodeRpcs = scanLiterals(actorFiles, /\bself\.rpc\(\s*[^,]+,\s*"node\.([^"]+)"/g);
  assert.ok(nodeRpcs.size >= 20, `reader node.* RPCs read: ${nodeRpcs.size} (expected >= 20)`);
  const mbAskedBody = mbtFnBody(actorsMbt, /\nasync fn MbActor::asked\(/);
  const mbNodeArms = mbtMatchArms(mbAskedBody);
  const tsAskedStart = mbActorTs.indexOf("async asked(");
  assert.ok(tsAskedStart >= 0, "mb-actor.ts has no async asked()");
  const tsAskedEnd = mbActorTs.indexOf("\n  #words(", tsAskedStart);
  assert.ok(tsAskedEnd > tsAskedStart, "mb-actor.ts has no #words() after asked()");
  const tsAskedCases = tsSwitchCases(mbActorTs.slice(tsAskedStart, tsAskedEnd));

  // 2. self.tell(..., "node.<name>" | "chat.<name>" | "log")
  const actorTells = scanLiterals(actorFiles, /\bself\.tell\(\s*[^,]+,\s*"([^"]+)"/g);
  assert.ok(actorTells.size >= 3, `reader actor tells read: ${actorTells.size} (expected >= 3)`);
  const mbToldBody = mbtFnBody(actorsMbt, /\nfn MbActor::told_\(/);
  const mbToldArms = mbtMatchArms(mbToldBody);
  const tsToldStart = mbActorTs.indexOf("told(f: string");
  assert.ok(tsToldStart >= 0, "mb-actor.ts has no told()");
  const tsToldCases = tsSwitchCases(mbActorTs.slice(tsToldStart, tsAskedStart));

  // 3. self.deps(..., "<name>")
  const depsCalls = scanLiterals(actorFiles, /\bself\.deps\(\s*[^,]+,\s*"([^"]+)"/g);
  assert.ok(depsCalls.size >= 15, `reader deps.* calls read: ${depsCalls.size} (expected >= 15)`);
  const mbDepsArms = mbtMatchArms(mbtFnBody(ctxMbt, /\nasync fn P52::deps\(/));
  const mbDepsExtra = mbtMatchArms(`${actorsMbt}\n${mainMbt}`);
  const tsDepsTypeStart = actorTs.indexOf("export type SessionDeps =");
  assert.ok(tsDepsTypeStart >= 0, "actor.ts has no SessionDeps");
  const tsDepsText = `${actorTs.slice(tsDepsTypeStart)}\n${mbActorTs}`;

  // 4. self.agent_do(..., "<name>")
  const agentCalls = scanLiterals(actorFiles, /\bself\.agent_do\(\s*[^,]+,\s*[^,]+,\s*"([^"]+)"/g);
  assert.ok(agentCalls.size >= 10, `reader agent.* calls read: ${agentCalls.size} (expected >= 10)`);
  const agentBlockStart = mbAskedBody.indexOf('if part == "agent"');
  assert.ok(agentBlockStart >= 0, "MbActor::asked has no agent dispatch block");
  const agentBlockEnd = mbAskedBody.indexOf('if f == "t"', agentBlockStart);
  const mbAgentArms = mbtMatchArms(mbAskedBody.slice(agentBlockStart, agentBlockEnd));
  const tsAgentsText = `${mbActorTs}\n${walk(join(station, "src", "agents"), (p) => p.endsWith(".ts") && !p.endsWith(".test.ts")).map(read).join("\n")}`;

  // 5. self.store(..., "<name>")
  const storeCalls = scanLiterals(actorFiles, /\bself\.store\(\s*[^,]+,\s*"([^"]+)"/g);
  assert.ok(storeCalls.size >= 20, `reader store.* calls read: ${storeCalls.size} (expected >= 20)`);
  const mbStoreLiterals = new Set<string>();
  for (const text of [
    actorsMbt,
    ctxMbt,
    dispatchMbt,
    read(join(readerDir, "actor_store.mbt")),
    ...mbt(join(mb, "store_sessions")).map(read),
    ...mbt(join(mb, "store_threads")).map(read),
  ]) {
    for (const m of text.matchAll(/"([A-Za-z_][A-Za-z0-9_]*)"/g)) mbStoreLiterals.add(m[1]!);
  }
  const tsStoreText = `${mbActorTs}\n${actorTs}\n${walk(join(station, "src", "store"), (p) => p.endsWith(".ts") && !p.endsWith(".test.ts")).map(read).join("\n")}`;

  const results: Result[] = [];
  for (const [name, where] of nodeRpcs) {
    results.push({
      name: `reader node.${name} (station_main)`,
      ok: mbNodeArms.has(name),
      why: `${where} calls self.rpc(..., "node.${name}"), unhandled in live_p5_2_actors.mbt MbActor::asked`,
    });
    results.push({
      name: `reader node.${name} (mb-actor.ts)`,
      ok: tsAskedCases.has(name),
      why: `${where} calls self.rpc(..., "node.${name}"), unhandled in station/src/sessions/mb-actor.ts asked()`,
    });
  }
  for (const [name, where] of actorTells) {
    results.push({
      name: `reader tell ${name} (station_main)`,
      ok: mbToldArms.has(name),
      why: `${where} calls self.tell(..., "${name}"), unhandled in live_p5_2_actors.mbt MbActor::told_`,
    });
    results.push({
      name: `reader tell ${name} (mb-actor.ts)`,
      ok: tsToldCases.has(name),
      why: `${where} calls self.tell(..., "${name}"), unhandled in station/src/sessions/mb-actor.ts told()`,
    });
  }
  for (const [name, where] of depsCalls) {
    results.push({
      name: `reader deps.${name} (station_main)`,
      ok: mbDepsArms.has(name) || mbDepsExtra.has(name),
      why: `${where} calls self.deps(..., "${name}"), unhandled in live_p5_2_ctx.mbt P52::deps`,
    });
    results.push({
      name: `reader deps.${name} (Node)`,
      ok: new RegExp(`\\b${name}\\??\\s*[(:]`).test(tsDepsText),
      why: `${where} calls self.deps(..., "${name}"), missing from SessionDeps / mb-actor.ts`,
    });
  }
  for (const [name, where] of agentCalls) {
    results.push({
      name: `reader agent.${name} (station_main)`,
      ok: mbAgentArms.has(name),
      why: `${where} calls self.agent_do(..., "${name}"), unhandled in live_p5_2_actors.mbt MbActor::asked agent block`,
    });
    results.push({
      name: `reader agent.${name} (Node)`,
      ok: tsAskedCases.has(name) || new RegExp(`\\b${name}\\??\\s*\\(`).test(tsAgentsText),
      why: `${where} calls self.agent_do(..., "${name}"), unhandled in mb-actor.ts or station/src/agents/`,
    });
  }
  for (const [name, where] of storeCalls) {
    results.push({
      name: `reader store.${name} (station_main)`,
      ok: mbStoreLiterals.has(name),
      why: `${where} calls self.store(..., "${name}"), missing in station_main / actor_store / store_sessions / store_threads`,
    });
    results.push({
      name: `reader store.${name} (Node)`,
      ok: new RegExp(`\\b${name}\\??\\s*\\(`).test(tsStoreText),
      why: `${where} calls self.store(..., "${name}"), missing in mb-actor.ts / station/src/store/`,
    });
  }

  const wrong = judge(results);
  assert.deepEqual(wrong, [], wrong.join("\n"));
});

test("every tell from reader #jobs, #live and #remote is handled in station_main", () => {
  const readerDir = join(mb, "reader");
  const results: Result[] = [];

  // #jobs
  const jobsTells = scanLiterals([join(readerDir, "jobs.mbt")], /\bself\.tell\(\s*[^,]+,\s*"([^"]+)"/g);
  assert.ok(jobsTells.size >= 2, `reader jobs tells read: ${jobsTells.size}`);
  const jobsArms = mbtMatchArms(mbtFnBody(read(join(mb, "station_main", "live_p5_3_jobs.mbt")), /\nfn P53Jobs::told\(/));
  for (const [name, where] of jobsTells) {
    results.push({
      name: `reader #jobs tell ${name}`,
      ok: jobsArms.has(name),
      why: `${where} tells "${name}", unhandled in live_p5_3_jobs.mbt P53Jobs::told`,
    });
  }

  // #live (mounted in live_p5_2_main.mbt mount_live → session_hub/live.mbt LiveShell::told_by_program)
  const liveTells = scanLiterals([join(readerDir, "live.mbt")], /\bself\.tell\(\s*[^,]+,\s*"([^"]+)"/g);
  assert.ok(liveTells.size >= 10, `reader live tells read: ${liveTells.size}`);
  const mainMbt = read(join(mb, "station_main", "live_p5_2_main.mbt"));
  assert.match(mainMbt, /p\.shells\["#live"\]\s*=\s*\([\s\S]*?live\.told_by_program/, "live_p5_2_main.mbt mount_live must wire live.told_by_program");
  const liveArms = mbtMatchArms(mbtFnBody(read(join(mb, "session_hub", "live.mbt")), /\npub fn LiveShell::told_by_program\(/));
  for (const [name, where] of liveTells) {
    results.push({
      name: `reader #live tell ${name}`,
      ok: liveArms.has(name),
      why: `${where} tells "${name}", unhandled in session_hub/live.mbt LiveShell::told_by_program`,
    });
  }

  // #remote
  const remoteFiles = readdirSync(readerDir).filter((n) => /^remote.*\.mbt$/.test(n)).map((n) => join(readerDir, n));
  const remoteTells = scanLiterals(remoteFiles, /\bself\.tell\(\s*[^,]+,\s*"([^"]+)"/g);
  assert.ok(remoteTells.size >= 4, `reader remote tells read: ${remoteTells.size}`);
  const remoteArms = mbtMatchArms(mbtFnBody(read(join(mb, "station_main", "live_p5_3_remote.mbt")), /\nfn P53Remote::told\(/));
  for (const [name, where] of remoteTells) {
    results.push({
      name: `reader #remote tell ${name}`,
      ok: remoteArms.has(name),
      why: `${where} tells "${name}", unhandled in live_p5_3_remote.mbt P53Remote::told`,
    });
  }

  const wrong = judge(results);
  assert.deepEqual(wrong, [], wrong.join("\n"));
});
