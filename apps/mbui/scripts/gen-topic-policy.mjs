// Writes apps/mbui/src/sfbase/topic_policy_gen.mbt directly from the core's
// client/core-ts/src/topic-policy.ts (no regex parsing of TS source).
// `--check` fails when the generated file differs from the source of truth.
import { readFileSync, realpathSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { STATION_PARTS, TOPICS } from "../../../client/core-ts/src/protocol.ts";
import {
  DEVICE_GLOBAL_TOPICS,
  KEPT_MOST_BEFORE_VIEWS,
  KEPT_PER_CLIENT,
  LASTING_KEPT,
  TOPIC_POLICY,
} from "../../../client/core-ts/src/topic-policy.ts";

const out = fileURLToPath(new URL("../src/sfbase/topic_policy_gen.mbt", import.meta.url));
const q = (s) => JSON.stringify(s);
const isPositiveInt = (v) => typeof v === "number" && Number.isInteger(v) && v > 0;
const isNonNegativeInt = (v) => typeof v === "number" && Number.isInteger(v) && v >= 0;

function validateBasePolicy(label, p, spec) {
  if (!p || typeof p !== "object") {
    throw new Error(`${label}: policy entry must be an object`);
  }
  if (p.retention !== "sensitive" && p.retention !== "live" && p.retention !== "delta" && p.retention !== "swr") {
    throw new Error(`${label}: unsupported retention ${JSON.stringify(p.retention)}`);
  }
  if (p.homeLasting === true && p.lasting !== true) {
    throw new Error(`${label}: homeLasting requires lasting: true`);
  }
  if (p.lasting === true && p.showKept === true) {
    throw new Error(`${label}: lasting and showKept cannot both be true`);
  }
  if (p.retention === "sensitive" || p.retention === "live") {
    if (
      p.lasting === true ||
      p.homeLasting === true ||
      p.showKept === true ||
      p.keep !== undefined ||
      p.keepBeforeViews !== undefined
    ) {
      throw new Error(`${label}: ${p.retention} topic cannot set lasting/homeLasting/showKept/keep/keepBeforeViews`);
    }
    return { kind: p.retention };
  }
  if (p.retention === "delta") {
    if (p.lasting === true || p.showKept === true) {
      throw new Error(`${label}: delta topic cannot set lasting or showKept`);
    }
    if (!isPositiveInt(p.keep)) {
      throw new Error(`${label}: delta topic requires positive integer keep`);
    }
    if (p.keepBeforeViews !== undefined && !isNonNegativeInt(p.keepBeforeViews)) {
      throw new Error(`${label}: keepBeforeViews must be a non-negative integer`);
    }
    return { kind: "delta", keep: p.keep, keepBefore: p.keepBeforeViews ?? p.keep };
  }
  // p.retention === "swr"
  if (p.lasting === true) {
    if (p.keep !== undefined || p.keepBeforeViews !== undefined) {
      throw new Error(`${label}: lasting topic uses LASTING_KEPT and cannot set keep/keepBeforeViews`);
    }
    if (spec && Object.hasOwn(spec, "query")) {
      throw new Error(`${label}: lasting topic must not declare a 'query' param in TOPICS`);
    }
    return { kind: "lasting", homeLasting: p.homeLasting === true };
  }
  if (p.showKept === true) {
    if (!isPositiveInt(p.keep)) {
      throw new Error(`${label}: showKept requires positive integer keep`);
    }
    if (p.keepBeforeViews !== undefined) {
      throw new Error(`${label}: showKept topic cannot set keepBeforeViews`);
    }
    if (spec && Object.hasOwn(spec, "query")) {
      throw new Error(`${label}: showKept topic must not declare a 'query' param in TOPICS`);
    }
    return { kind: "showKept", keep: p.keep };
  }
  throw new Error(`${label}: swr topic must set either lasting: true or showKept: true`);
}

function exprForKeep(info) {
  switch (info.kind) {
    case "sensitive":
    case "live":
      return "0";
    case "delta":
      return info.keep === info.keepBefore
        ? `${info.keep}`
        : `if views { ${info.keep} } else { ${info.keepBefore} }`;
    case "lasting":
      return "if topic_policy_typed(params) { 0 } else { topic_policy_last_most }";
    case "showKept":
      return `if views && !topic_policy_typed(params) { ${info.keep} } else { 0 }`;
  }
}

function exprForBool(info, field) {
  if (field === "sensitive") return info.kind === "sensitive" ? "true" : "false";
  if (field === "lasting") return info.kind === "lasting" ? "true" : "false";
  if (field === "homeLasting") return info.kind === "lasting" && info.homeLasting ? "true" : "false";
  if (field === "showKept") return info.kind === "showKept" ? "true" : "false";
  return "false";
}

function emitByParamMatch(key, baseExpr, branches) {
  const groups = new Map();
  for (const [val, expr] of branches) {
    if (expr === baseExpr) continue;
    let list = groups.get(expr);
    if (!list) groups.set(expr, (list = []));
    list.push(val);
  }
  if (groups.size === 0) return baseExpr;
  const lines = [`match topic_policy_param_str(params, ${q(key)}) {`];
  for (const [expr, vals] of groups) {
    lines.push(`        ${vals.map((v) => `Some(${q(v)})`).join(" | ")} => ${expr}`);
  }
  lines.push(`        _ => ${baseExpr}`);
  lines.push("      }");
  return lines.join("\n");
}

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
  deviceGlobal = topics === TOPICS ? DEVICE_GLOBAL_TOPICS : [],
  stationParts = topics === TOPICS ? STATION_PARTS : null,
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

  const sensitiveTopics = [];
  const lastingTopics = [];
  const homeLastingTopics = [];
  const deltaTopics = [];
  const showKeptTopics = [];
  const byParamTopics = [];

  for (const name of protocolKeys) {
    const p = policy[name];
    const spec = topics[name];
    const baseInfo = validateBasePolicy(`TOPIC_POLICY.${name}`, p, spec);

    if (p.byParam !== undefined) {
      if (
        !p.byParam ||
        typeof p.byParam !== "object" ||
        typeof p.byParam.key !== "string" ||
        p.byParam.key.length === 0 ||
        !p.byParam.values ||
        typeof p.byParam.values !== "object" ||
        Array.isArray(p.byParam.values)
      ) {
        throw new Error(`TOPIC_POLICY.${name}: byParam must have non-empty string key and object values`);
      }
      if (!spec || !Object.hasOwn(spec, p.byParam.key)) {
        throw new Error(
          `TOPIC_POLICY.${name}: byParam key ${q(p.byParam.key)} is not declared in TOPICS.${name}`,
        );
      }
      const valueEntries = Object.entries(p.byParam.values);
      if (valueEntries.length === 0) {
        throw new Error(`TOPIC_POLICY.${name}: byParam.values must not be empty`);
      }
      if (name === "stationPart" && p.byParam.key === "part" && Array.isArray(stationParts)) {
        const partSet = new Set(stationParts);
        const valueKeys = valueEntries.map(([v]) => v);
        const valueSet = new Set(valueKeys);
        const missingParts = stationParts.filter((sp) => !valueSet.has(sp));
        const extraParts = valueKeys.filter((vk) => !partSet.has(vk));
        if (missingParts.length > 0 || extraParts.length > 0) {
          throw new Error(
            `TOPIC_POLICY.stationPart.byParam.values do not match STATION_PARTS: missing=[${missingParts.join(", ")}] extra=[${extraParts.join(", ")}]`,
          );
        }
      }
      const parsedBranches = [];
      for (const [val, override] of valueEntries) {
        if (!override || typeof override !== "object") {
          throw new Error(`TOPIC_POLICY.${name}.byParam[${q(val)}]: override must be an object`);
        }
        const merged = { ...p, ...override };
        delete merged.byParam;
        const branchInfo = validateBasePolicy(`TOPIC_POLICY.${name}.byParam[${q(val)}]`, merged, spec);
        parsedBranches.push([val, branchInfo]);
      }
      byParamTopics.push({ name, key: p.byParam.key, baseInfo, branches: parsedBranches });
      continue;
    }

    if (baseInfo.kind === "sensitive") {
      sensitiveTopics.push(name);
    } else if (baseInfo.kind === "delta") {
      deltaTopics.push([name, baseInfo.keep, baseInfo.keepBefore]);
    } else if (baseInfo.kind === "lasting") {
      lastingTopics.push(name);
      if (baseInfo.homeLasting) homeLastingTopics.push(name);
    } else if (baseInfo.kind === "showKept") {
      showKeptTopics.push([name, baseInfo.keep]);
    }
  }

  const formatOrPatterns = (names) => `    ${names.map(q).join("\n    | ")}`;
  const knownArms = protocolKeys.map((n) => `    ${q(n)} => true`).join("\n");

  const buildBoolArms = (staticList, field) => {
    const arms = [];
    if (staticList.length > 0) {
      arms.push(`${formatOrPatterns(staticList)} => true`);
    }
    for (const bp of byParamTopics) {
      const baseExpr = exprForBool(bp.baseInfo, field);
      const branchExprs = bp.branches.map(([val, info]) => [val, exprForBool(info, field)]);
      const emitted = emitByParamMatch(bp.key, baseExpr, branchExprs);
      if (emitted !== "false") {
        arms.push(`    ${q(bp.name)} =>\n      ${emitted}`);
      }
    }
    return arms.join("\n");
  };

  const keepArms = [];
  for (const [name, keep, keepBefore] of deltaTopics) {
    keepArms.push(
      keep === keepBefore
        ? `    ${q(name)} => ${keep}`
        : `    ${q(name)} => if views { ${keep} } else { ${keepBefore} }`,
    );
  }
  if (lastingTopics.length > 0) {
    keepArms.push(
      `    ${lastingTopics.map(q).join("\n    | ")} =>\n      if topic_policy_typed(params) {\n        0\n      } else {\n        topic_policy_last_most\n      }`,
    );
  }
  for (const [name, keep] of showKeptTopics) {
    keepArms.push(`    ${q(name)} => if views && !topic_policy_typed(params) { ${keep} } else { 0 }`);
  }
  for (const bp of byParamTopics) {
    const baseExpr = exprForKeep(bp.baseInfo);
    const branchExprs = bp.branches.map(([val, info]) => [val, exprForKeep(info)]);
    const emitted = emitByParamMatch(bp.key, baseExpr, branchExprs);
    if (emitted !== "0") {
      keepArms.push(`    ${q(bp.name)} =>\n      ${emitted}`);
    }
  }

  const sensitiveArms = buildBoolArms(sensitiveTopics, "sensitive");
  const lastingArms = buildBoolArms(lastingTopics, "lasting");
  const homeLastingArms = buildBoolArms(homeLastingTopics, "homeLasting");
  const showKeptArms = buildBoolArms(showKeptTopics.map(([n]) => n), "showKept");
  const deviceGlobalList = Array.isArray(deviceGlobal) ? deviceGlobal : [];
  for (const dg of deviceGlobalList) {
    if (!protocolSet.has(dg)) {
      throw new Error(`DEVICE_GLOBAL_TOPICS contains unknown topic ${q(dg)}`);
    }
  }
  const deviceGlobalArms = deviceGlobalList.length > 0 ? `${formatOrPatterns(deviceGlobalList)} => true` : "";

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
    '#warnings("-unused_value") // used by byParam topic branches',
    "fn topic_policy_param_str(params : Json, key : String) -> String? {",
    "  match params {",
    "    Object(p) =>",
    "      match p.get(key) {",
    "        Some(String(s)) => Some(s)",
    "        _ => None",
    "      }",
    "    _ => None",
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
    "/// Whether `name` is a device-global or transport-only topic exempt from `(account, workspace)` `authGen`.",
    "pub fn topic_policy_device_global(name : String) -> Bool {",
    "  match name {",
    ...(deviceGlobalArms ? [deviceGlobalArms] : []),
    "    _ => false",
    "  }",
    "}",
    "",
    "///|",
    "/// Whether `(name, params)` is an unconditional `sensitive` topic (never kept, shown stale, or reused across auth boundaries).",
    "pub fn topic_policy_sensitive(name : String, params : Json) -> Bool {",
    "  match name {",
    ...(sensitiveArms ? [sensitiveArms] : []),
    "    _ => false",
    "  }",
    "}",
    "",
    "///|",
    "/// Whether `(name, params)` is a bar/rail opening list kept in `last_said`.",
    "pub fn topic_policy_lasting(name : String, params : Json) -> Bool {",
    "  if topic_policy_sensitive(name, params) || topic_policy_typed(params) {",
    "    return false",
    "  }",
    "  match name {",
    ...(lastingArms ? [lastingArms] : []),
    "    _ => false",
    "  }",
    "}",
    "",
    "///|",
    "/// Whether `(name, params)` is one of Home's own `lasting` lists (`MBUI_HOME_SAME`).",
    "pub fn topic_policy_home_lasting(name : String, params : Json) -> Bool {",
    "  if topic_policy_sensitive(name, params) {",
    "    return false",
    "  }",
    "  match name {",
    ...(homeLastingArms ? [homeLastingArms] : []),
    "    _ => false",
    "  }",
    "}",
    "",
    "///|",
    "/// How many values of `(name, params)` the core's client keeps as they are let go of (`views` = `MBUI_SWR_VIEWS`).",
    "pub fn topic_policy_keep(name : String, params : Json, views : Bool) -> Int {",
    "  if topic_policy_sensitive(name, params) {",
    "    return 0",
    "  }",
    "  match name {",
    ...keepArms,
    "    _ => 0",
    "  }",
    "}",
    "",
    "///|",
    "/// Whether `(name, params)` shows its kept value immediately before the core answers (`views` = `MBUI_SWR_VIEWS`).",
    "pub fn topic_policy_show_kept(name : String, params : Json, views : Bool) -> Bool {",
    "  if topic_policy_sensitive(name, params) || !views || topic_policy_typed(params) {",
    "    return false",
    "  }",
    "  match name {",
    ...(showKeptArms ? [showKeptArms] : []),
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
