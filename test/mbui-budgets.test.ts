import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { BUDGETS, type Budget, describe, judge, parseBudget, raised, raiseLetBy, SCENE_FILES } from "../scripts/mbui-budgets.ts";

const root = join(import.meta.dirname, "..");
const budget = (name: string): Budget => BUDGETS.find((b) => b.name === name)!;
const known = budget("real_size_known");
const change = budget("real_size_change_known");
const bindings = budget("real_size_bindings_known");
const chat = budget("chat_nodes_open_budget");

/** A table written as the tests write it, its rows' bars given. */
const table = (b: Budget, rows: [string, number[]][]): string =>
  `// a table\n///|\nlet ${b.name} : Map[String, …] = {\n${rows
    .map(([k, v]) => `  // (why, before it)\n  "${k}": ${v.length === 1 ? v[0] : `(${v.join(", ")})`},`)
    .join("\n")}\n}\n\n///|\nlet other : Map[String, Int] = { "x": 1 }\n`;

/** What the change from `before` to `after` raises, the scene's files changed or not. */
const raisedBy = (b: Budget, before: [string, number[]][], after: [string, number[]][], scene = false) =>
  judge(() => ({ before: table(b, before), after: table(b, after) }), scene ? [b.path, SCENE_FILES[0]!] : [b.path]).map(describe);

test("a table read as the test writes it: comments, escapes, a trailing comma or none", () => {
  const src = `let real_size_known : Map[String, (Int, Int, Int)] = {\n  // "not": (9, 9, 9),\n  "phone \\"q\\" \\u{4e2d}": (1, 2_000, 3),\n  "wide x": (4,\n    5, 6) // a note\n}`;
  assert.deepEqual([...parseBudget(src, "real_size_known", 3)], [["phone \"q\" 中", [1, 2000, 3]], ["wide x", [4, 5, 6]]]);
  assert.throws(() => parseBudget(`let real_size_known : M = {\n  "a": (1, 2),\n}`, "real_size_known", 3), /2 numbers, not 3/);
  assert.throws(() => parseBudget(`let real_size_known : M = {\n  "a": (1, 2, 3),\n  "a": (1, 2, 3),\n}`, "real_size_known", 3), /twice/);
  assert.throws(() => parseBudget("let other : M = {}", "real_size_known", 3), /no `let real_size_known/);
});

test("bars that fall or stay, and rows taken away, raise nothing", () => {
  assert.deepEqual(raisedBy(known, [["phone home", [434, 499, 92]], ["phone gone", [1, 1, 1]]], [["phone home", [430, 499, 90]]]), []);
  assert.deepEqual(raisedBy(change, [["phone home lock/member", [0, 0, 0, 0, 0, 1]]], [["phone home lock/member", [0, 0, 0, 0, 0, 0]]]), []);
  assert.deepEqual(raisedBy(bindings, [["phone home chats/down", [27]], ["wide x", [3]]], [["phone home chats/down", [27]]]), []);
  assert.deepEqual(raisedBy(chat, [["phone cold", [757, 29, 830, 146, 776]]], [["phone cold", [757, 29, 830, 146, 776]]]), []);
  // (a key held to 0 come with 0: nothing raised)
  assert.deepEqual(raisedBy(bindings, [], [["wide new/thing", [0]]]), []);
});

test("any bar raised is named, with the slot and its numbers", () => {
  assert.deepEqual(raisedBy(known, [["phone home", [434, 499, 92]]], [["phone home", [434, 500, 92]]]), [
    `${known.path}: "phone home" laid_out 499 -> 500`,
  ]);
  assert.deepEqual(raisedBy(change, [["phone board chats/down", [5, 3, 12, 1, 0, 1]]], [["phone board chats/down", [5, 3, 12, 1, 0, 2]]]), [
    `${change.path}: "phone board chats/down" old_laid_out 1 -> 2`,
  ]);
  assert.deepEqual(raisedBy(chat, [["wide cold", [2443, 483, 3531, 557, 2634]]], [["wide cold", [2444, 483, 3531, 557, 2635]]]), [
    `${chat.path}: "wide cold" made 2443 -> 2444`,
    `${chat.path}: "wide cold" bindings 2634 -> 2635`,
  ]);
  // (a scene's files changed lets no bar of a row there was rise)
  assert.deepEqual(raisedBy(known, [["phone home", [1, 1, 1]]], [["phone home", [1, 1, 2]]], true), [`${known.path}: "phone home" measured 1 -> 2`]);
});

test("a key the bindings' table holds to 0 come above it is raised from 0", () => {
  assert.deepEqual(raisedBy(bindings, [["phone home chats/down", [27]]], [["phone home chats/down", [27]], ["phone home chats/new", [4]]]), [
    `${bindings.path}: "phone home chats/new" bindings 0 -> 4`,
  ]);
  // (a scene's files changed or not)
  assert.deepEqual(raisedBy(bindings, [], [["phone home chats/new", [4]]], true), [`${bindings.path}: "phone home chats/new" bindings 0 -> 4`]);
});

test("a new row comes with the screen or change it is of, and only in the sweep's tables", () => {
  assert.deepEqual(raisedBy(known, [], [["phone new-page", [10, 10, 1]]], true), []);
  assert.deepEqual(raisedBy(change, [], [["phone new-page chats/down", [1, 0, 2, 0, 0, 0]]], true), []);
  assert.match(raisedBy(known, [], [["phone new-page", [10, 10, 1]]])[0]!, /"phone new-page": a new row with no new screen or change/);
  assert.match(raisedBy(change, [], [["phone x chats/down", [1, 0, 2, 0, 0, 0]]])[0]!, /a new row with no new screen/);
  assert.match(raisedBy(chat, [], [["phone sideways", [1, 1, 1, 1, 1]]], true)[0]!, /"phone sideways": a new row/);
});

test("a table not changed is not read; one taken away raises nothing", () => {
  let read = 0;
  assert.deepEqual(judge(() => (read++, { before: "", after: "" }), ["apps/mbui/src/sfapp/other.mbt"]), []);
  assert.equal(read, 0);
  assert.deepEqual(judge(() => ({ before: table(known, [["a", [1, 1, 1]]]), after: undefined }), [known.path]), []);
});

test("a moved table reads its former path: identical or lowered bars pass, any raise fails", () => {
  const oldPath = known.former![0]!;
  const prev = table(known, [["phone home", [434, 499, 92]]]);
  const same = table(known, [["phone home", [434, 499, 92]]]);
  const higher = table(known, [["phone home", [434, 500, 92]]]);
  const readMoved = (afterSrc: string) => (path: string) =>
    path === known.path ? { before: undefined, after: afterSrc } : path === oldPath ? { before: prev, after: undefined } : { before: undefined, after: undefined };
  assert.deepEqual(judge(readMoved(same), [oldPath, known.path]), []);
  assert.deepEqual(judge(readMoved(higher), [oldPath, known.path]).map(describe), [`${known.path}: "phone home" laid_out 499 -> 500`]);
});

test("the four tables as they are read whole, each the same as itself", () => {
  for (const b of BUDGETS) {
    const src = readFileSync(join(root, b.path), "utf8");
    const rows = parseBudget(src, b.name, b.slots.length);
    assert.ok(rows.size > 0, `${b.path}: no rows read`);
    // (every row's key in the file, once: none read out of a comment or missed)
    const written = [...src.slice(src.indexOf(`let ${b.name} `)).split("\n}\n")[0]!.matchAll(/^\s*"((?:[^"\\]|\\.)*)"\s*:/gm)].length;
    assert.equal(rows.size, written, `${b.path}: ${rows.size} rows read, ${written} written`);
    for (const v of rows.values()) assert.ok(v.every((n) => Number.isInteger(n) && n >= 0));
    assert.deepEqual(raised(b, rows, rows, false), []);
    assert.deepEqual(judge(() => ({ before: src, after: src }), [b.path]), []);
  }
});

test("a raise is let through by a reason that says why, a line of its own", () => {
  const msg = (trailer: string) => `mbui: the wide sidebar as nodes\n\nWhy.\n\n${trailer}\nCo-Authored-By: Claude <noreply@anthropic.com>\n`;
  assert.deepEqual(raiseLetBy(msg("Budget-raise: wide sidebar migrated from Ctx to Tree nodes")), { ok: true, refused: [] });
  for (const vague of ["update", "Recount", "fix", "none", "raise", "  update the budgets  ", "raise the bars", "rebaseline counts"]) {
    const got = raiseLetBy(msg(`Budget-raise: ${vague}`));
    assert.equal(got.ok, false, vague);
    assert.equal(got.refused.length, 1, vague);
  }
  assert.match(raiseLetBy(msg("Budget-raise: more rows")).refused[0]!, /too short/);
  assert.match(raiseLetBy(msg("Budget-raise: update the budgets")).refused[0]!, /says nothing of why/);
  assert.deepEqual(raiseLetBy(msg("")), { ok: false, refused: [] });
  // (said within a line, not a line of its own: nothing)
  assert.equal(raiseLetBy("mbui: see Budget-raise: wide sidebar migrated from Ctx to Tree nodes").ok, false);
  // (one that does among several commits' messages)
  assert.equal(raiseLetBy(`${msg("Budget-raise: fix")}\n${msg("Budget-raise: 已归档 made as nodes, its old view's build now counted")}`).ok, true);
});
