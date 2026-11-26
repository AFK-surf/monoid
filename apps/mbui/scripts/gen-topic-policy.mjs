// Writes apps/mbui/src/sfbase/topic_policy_gen.mbt directly from the core's
// client/core-ts/src/topic-policy.ts (no regex parsing of TS source).
// `--check` fails when the generated file differs from the source of truth.
import { readFileSync, realpathSync, writeFileSync } from "node:fs";
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
const isPositiveInt = (v) => typeof v === "number" && Number.isInteger(v) && v > 0;
const isNonNegativeInt = (v) => typeof v === "number" && Number.isInteger(v) && v >= 0;

/**
 * Validates `policy` against `topics` and generates the MoonBit source for `topic_policy_gen.mbt`.
 * Fails fast (throws Error) on any key drift or unsupported policy combination so nothing is silently dropped.
 */
export function generateTopicPolicyMbt(
  topics = TOPICS,
  policy = TOPIC_POLICY,
  caps = {
    keptPerClient: KEPT_PER_CLIENT,
    keptMostBeforeViews: KEPT_MOST_BEFORE_VIEWS,
    lastingKept: LASTING_KEPT,
  },
) {
  const protocolKeys = Object.keys(topics);
  const policyKeys = Object.keys(policy);
  const protocolSet = new Set(protocolKeys);
  const policySet = new Set(policyKeys);

  const missingInPolicy = protocolKeys.filter((k) => !policySet.has(k));
  const extraInPolicy = policyKeys.filter((k) => !protocolSet.has(k));
  if (missingInPolicy.length > 0 || extraInPolicy.length > 0) {
    throw new Error(
      `TOPIC_POLICY keys do not match TOPICS: missing=[${missingInPolicy.join(", ")}] extra=[${extraInPolicy.join(", ")}]`,
    );
  }

  const lastingTopics = [];
  const homeLastingTopics = [];
  const deltaTopics = [];
  const showKeptTopics = [];

  for (const name of protocolKeys) {
    const p = policy[name];
    const spec = topics[name];
    if (!p || typeof p !== "object") {
      throw new Error(`TOPIC_POLICY.${name}: policy entry must be an object`);
    }
    if (p.byParam !== undefined) {
      throw new Error(
        `TOPIC_POLICY.${name}: byParam is not yet supported by gen-topic-policy.mjs; add per-param codegen before enabling`,
      );
    }
    if (p.retention !== "live" && p.retention !== "delta" && p.retention !== "swr") {
      throw new Error(`TOPIC_POLICY.${name}: unsupported retention ${JSON.stringify(p.retention)}`);
    }
    if (p.homeLasting === true && p.lasting !== true) {
      throw new Error(`TOPIC_POLICY.${name}: homeLasting requires lasting: true`);
    }
    if (p.lasting === true && p.showKept === true) {
      throw new Error(`TOPIC_POLICY.${name}: lasting and showKept cannot both be true`);
    }

    if (p.retention === "live") {
      if (
        p.lasting === true ||
        p.homeLasting === true ||
        p.showKept === true ||
        p.keep !== undefined ||
        p.keepBeforeViews !== undefined
      ) {
        throw new Error(`TOPIC_POLICY.${name}: live topic cannot set lasting/homeLasting/showKept/keep/keepBeforeViews`);
      }
      continue;
    }

    if (p.retention === "delta") {
      if (p.lasting === true || p.showKept === true) {
        throw new Error(`TOPIC_POLICY.${name}: delta topic cannot set lasting or showKept`);
      }
      if (!isPositiveInt(p.keep)) {
        throw new Error(`TOPIC_POLICY.${name}: delta topic requires positive integer keep`);
      }
      if (p.keepBeforeViews !== undefined && !isNonNegativeInt(p.keepBeforeViews)) {
        throw new Error(`TOPIC_POLICY.${name}: keepBeforeViews must be a non-negative integer`);
      }
      const keepBefore = p.keepBeforeViews ?? p.keep;
      deltaTopics.push([name, p.keep, keepBefore]);
      continue;
    }

    // p.retention === "swr"
    if (p.lasting === true) {
      if (p.keep !== undefined || p.keepBeforeViews !== undefined) {
        throw new Error(`TOPIC_POLICY.${name}: lasting topic uses LASTING_KEPT and cannot set keep/keepBeforeViews`);
      }
      if (spec && Object.hasOwn(spec, "query")) {
        throw new Error(`TOPIC_POLICY.${name}: lasting topic must not declare a 'query' param in TOPICS`);
      }
      lastingTopics.push(name);
      if (p.homeLasting === true) homeLastingTopics.push(name);
      continue;
    }

    if (p.showKept === true) {
      if (!isPositiveInt(p.keep)) {
        throw new Error(`TOPIC_POLICY.${name}: showKept requires positive integer keep`);
      }
      if (p.keepBeforeViews !== undefined) {
        throw new Error(`TOPIC_POLICY.${name}: showKept topic cannot set keepBeforeViews`);
      }
      if (spec && Object.hasOwn(spec, "query")) {
        throw new Error(`TOPIC_POLICY.${name}: showKept topic must not declare a 'query' param in TOPICS`);
      }
      showKeptTopics.push([name, p.keep]);
      continue;
    }

    throw new Error(`TOPIC_POLICY.${name}: swr topic must set either lasting: true or showKept: true`);
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

  return [
    "// Made by apps/mbui/scripts/gen-topic-policy.mjs from client/core-ts/src/topic-policy.ts: do not edit.",
    "",
    `let topic_policy_kept_per_client : Int = ${caps.keptPerClient}`,
    "",
    `let topic_policy_kept_most_before : Int = ${caps.keptMostBeforeViews}`,
    "",
    `let topic_policy_last_most : Int = ${caps.lastingKept}`,
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
    '#warnings("-unused_value") // verified by sfbase/topic_policy_wbtest.mbt',
    "fn topic_policy_known(name : String, _params : Json) -> Bool {",
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
}

function isMain() {
  if (!process.argv[1]) return false;
  try {
    return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

if (isMain()) {
  let text;
  try {
    text = generateTopicPolicyMbt();
  } catch (err) {
    console.error(err instanceof Error ? err.message : String(err));
    process.exit(1);
  }
  const outFlag = process.argv.indexOf("--out");
  const target = outFlag >= 0 && process.argv[outFlag + 1] ? process.argv[outFlag + 1] : out;
  if (process.argv.includes("--check")) {
    let was = "";
    try {
      was = readFileSync(target, "utf8");
    } catch {}
    if (was !== text) {
      console.error(
        `not what client/core-ts/src/topic-policy.ts makes: ${target} — run node apps/mbui/scripts/gen-topic-policy.mjs`,
      );
      process.exit(1);
    }
  } else {
    writeFileSync(target, text);
  }
}
