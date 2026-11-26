// Writes apps/mbui/src/sfbase/topic_policy_gen.mbt directly from the core's
// client/core-ts/src/topic-policy.ts (no regex parsing of TS source).
// `--check` fails when the generated file differs from the source of truth.
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { TOPICS } from "../../../client/core-ts/src/protocol.ts";
import {
  KEPT_MOST_BEFORE_VIEWS,
  KEPT_PER_CLIENT,
  LASTING_KEPT,
  TOPIC_POLICY,
} from "../../../client/core-ts/src/topic-policy.ts";

const out = fileURLToPath(new URL("../src/sfbase/topic_policy_gen.mbt", import.meta.url));
const q = (s) => JSON.stringify(s);

const protocolKeys = Object.keys(TOPICS);
const policyKeys = Object.keys(TOPIC_POLICY);
const protocolSet = new Set(protocolKeys);
const policySet = new Set(policyKeys);

const missingInPolicy = protocolKeys.filter((k) => !policySet.has(k));
const extraInPolicy = policyKeys.filter((k) => !protocolSet.has(k));
if (missingInPolicy.length > 0 || extraInPolicy.length > 0) {
  console.error(
    `TOPIC_POLICY keys do not match TOPICS: missing=[${missingInPolicy.join(", ")}] extra=[${extraInPolicy.join(", ")}]`,
  );
  process.exit(1);
}

const lastingTopics = [];
const homeLastingTopics = [];
const deltaTopics = [];
const showKeptTopics = [];

for (const name of protocolKeys) {
  const p = TOPIC_POLICY[name];
  if (p.lasting === true) lastingTopics.push(name);
  if (p.homeLasting === true) {
    if (p.lasting !== true) {
      console.error(`TOPIC_POLICY.${name}: homeLasting requires lasting: true`);
      process.exit(1);
    }
    homeLastingTopics.push(name);
  }
  if (p.retention === "delta") {
    const keep = p.keep ?? 0;
    const keepBefore = p.keepBeforeViews ?? keep;
    deltaTopics.push([name, keep, keepBefore]);
  }
  if (p.showKept === true) {
    if (typeof p.keep !== "number" || p.keep <= 0) {
      console.error(`TOPIC_POLICY.${name}: showKept requires positive keep`);
      process.exit(1);
    }
    showKeptTopics.push([name, p.keep]);
  }
}

const formatOrPatterns = (names) => `    ${names.map(q).join("\n    | ")}`;

const knownArms = protocolKeys.map((n) => `    ${q(n)} => true`).join("\n");
const deltaKeepArms = deltaTopics
  .map(([name, keep, keepBefore]) =>
    keep === keepBefore
      ? `    ${q(name)} => ${keep}`
      : `    ${q(name)} => if views { ${keep} } else { ${keepBefore} }`,
  )
  .join("\n");
const lastingKeepArm =
  lastingTopics.length > 0
    ? `    ${lastingTopics.map(q).join("\n    | ")} =>\n      if topic_policy_typed(params) {\n        0\n      } else {\n        topic_policy_last_most\n      }\n`
    : "";
const viewKeepArms = showKeptTopics
  .map(([name, keep]) => `    ${q(name)} => if views && !topic_policy_typed(params) { ${keep} } else { 0 }`)
  .join("\n");

const text = [
  "// Made by apps/mbui/scripts/gen-topic-policy.mjs from client/core-ts/src/topic-policy.ts: do not edit.",
  "",
  `let topic_policy_kept_per_client : Int = ${KEPT_PER_CLIENT}`,
  "",
  `let topic_policy_kept_most_before : Int = ${KEPT_MOST_BEFORE_VIEWS}`,
  "",
  `let topic_policy_last_most : Int = ${LASTING_KEPT}`,
  "",
  "///|",
  "fn topic_policy_typed(params : Json) -> Bool {",
  "  match params {",
  "    Object(p) =>",
  '      if p.contains("q") {',
  "        true",
  "      } else {",
  '        match p.get("query") {',
  "          Some(String(s)) => s.length() > 0",
  "          _ => false",
  "        }",
  "      }",
  "    _ => false",
  "  }",
  "}",
  "",
  "///|",
  `/// Whether topic \`name\` is one of the ${protocolKeys.length} protocol topics in \`client/core-ts/src/protocol.ts\`.`,
  "pub fn topic_policy_known(name : String, _params : Json) -> Bool {",
  "  match name {",
  knownArms,
  "    _ => false",
  "  }",
  "}",
  "",
  "///|",
  "/// Whether `(name, params)` is a bar/rail opening list kept in `last_said`.",
  "pub fn topic_policy_lasting(name : String, params : Json) -> Bool {",
  "  if topic_policy_typed(params) {",
  "    return false",
  "  }",
  "  match name {",
  `${formatOrPatterns(lastingTopics)} => true`,
  "    _ => false",
  "  }",
  "}",
  "",
  "///|",
  "/// Whether `(name, params)` is one of Home's own `lasting` lists (`MBUI_HOME_SAME`).",
  "pub fn topic_policy_home_lasting(name : String, _params : Json) -> Bool {",
  "  match name {",
  `${formatOrPatterns(homeLastingTopics)} => true`,
  "    _ => false",
  "  }",
  "}",
  "",
  "///|",
  "/// How many values of `(name, params)` the core's client keeps as they are let go of (`views` = `MBUI_SWR_VIEWS`).",
  "pub fn topic_policy_keep(name : String, params : Json, views : Bool) -> Int {",
  "  match name {",
  deltaKeepArms,
  lastingKeepArm.trimEnd(),
  viewKeepArms,
  "    _ => 0",
  "  }",
  "}",
  "",
  "///|",
  "/// Whether `(name, params)` shows its kept value immediately before the core answers (`views` = `MBUI_SWR_VIEWS`).",
  "pub fn topic_policy_show_kept(name : String, params : Json, views : Bool) -> Bool {",
  "  if !views || topic_policy_typed(params) {",
  "    return false",
  "  }",
  "  match name {",
  `${formatOrPatterns(showKeptTopics.map(([name]) => name))} => true`,
  "    _ => false",
  "  }",
  "}",
  "",
].join("\n");

if (process.argv.includes("--check")) {
  let was = "";
  try {
    was = readFileSync(out, "utf8");
  } catch {}
  if (was !== text) {
    console.error(
      `not what client/core-ts/src/topic-policy.ts makes: ${out} — run node apps/mbui/scripts/gen-topic-policy.mjs`,
    );
    process.exit(1);
  }
} else {
  writeFileSync(out, text);
}
