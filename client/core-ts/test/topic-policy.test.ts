import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { parseTopic, TOPICS, type TopicName } from "../src/protocol.ts";
import { ASKED_BY_WORDS, KEPT_PER_CLIENT } from "../src/store.ts";
import {
  evaluateTopicPolicy,
  isKnownTopic,
  KEPT_MOST_BEFORE_VIEWS,
  LASTING_KEPT,
  sanitizeKeptValue,
  TOPIC_NAMES,
  TOPIC_POLICY,
  topicsWhere,
} from "../src/topic-policy.ts";

const EXPECTED_SENSITIVE = [
  "accounts",
  "admin",
  "adminItem",
  "adminList",
  "adminOverview",
  "adminRelays",
  "devices",
  "joinable",
  "lock",
  "lockDraft",
  "lockPrompts",
  "loginSessions",
  "machineLogin",
  "machineLoginScreen",
  "machineLogins",
  "memberships",
  "rigs",
  "slackTokens",
  "vaultItems",
  "vaultUses",
  "vaults",
];

const EXPECTED_LASTING = [
  "archive",
  "changelog",
  "chats",
  "connects",
  "longJobs",
  "profiles",
  "screens",
  "stationNet",
  "stationUpdates",
  "stations",
  "terminals",
  "usage",
  "workspace",
];

const EXPECTED_HOME_LASTING = ["changelog", "chats", "longJobs"];

const EXPECTED_VIEWS_KEPT: Record<string, number> = {
  agentCard: 16,
  agentRates: 4,
  chatJobs: 16,
  chatOutline: 8,
  chatRow: 32,
  connect: 16,
  connectCandidates: 8,
  drivePlace: 24,
  fonts: 4,
  otherPresets: 8,
  pick: 12,
  presets: 8,
  profile: 16,
  profilesOverview: 4,
  project: 16,
  projects: 8,
  railCard: 16,
  releases: 4,
  station: 16,
  tags: 8,
};

const EXPECTED_B2B_POLICY_GATED = [
  "chatFeedback",
  "fonts",
  "jobLog",
  "otherPresets",
  "presets",
  "profilesOverview",
  "releases",
];

describe("topic-policy SSOT", () => {
  it("matches TOPICS bidirectionally across all 125 protocol topics", () => {
    const protocolKeys = Object.keys(TOPICS).sort();
    const policyKeys = Object.keys(TOPIC_POLICY).sort();
    assert.equal(protocolKeys.length, 125);
    assert.deepEqual(policyKeys, protocolKeys);
    assert.deepEqual([...TOPIC_NAMES].sort(), protocolKeys);
    for (const name of protocolKeys) {
      assert.equal(isKnownTopic(name), true);
    }
  });

  it("rejects prototype and unknown keys in parseTopic and topic-policy lookup", () => {
    for (const bad of ["toString", "constructor", "valueOf", "__proto__", "hasOwnProperty", "notATopic"]) {
      assert.equal(parseTopic({ topic: bad }), null, `parseTopic should reject ${bad}`);
      assert.equal(isKnownTopic(bad), false, `isKnownTopic should reject ${bad}`);
      const evaluated = evaluateTopicPolicy(bad, {});
      assert.equal(evaluated.retention, "live");
      assert.equal(evaluated.lasting, false);
      assert.equal(evaluated.homeLasting, false);
      assert.equal(evaluated.keep, 0);
      assert.equal(evaluated.keepBeforeViews, 0);
      assert.equal(evaluated.showKept, false);
    }
  });

  it("preserves exact PR-B2a store sets and capacities", () => {
    assert.equal(KEPT_PER_CLIENT, 96);
    assert.equal(KEPT_MOST_BEFORE_VIEWS, 64);
    assert.equal(LASTING_KEPT, 64);

    assert.deepEqual([...ASKED_BY_WORDS].sort(), ["chatSearch", "chatSubchats", "search", "stationSearch"]);
    assert.deepEqual([...topicsWhere((p) => p.lazyWhenIdle === true)].sort(), ["profilesOverview"]);
    assert.deepEqual(
      [...topicsWhere((p) => p.unseen === true)].sort(),
      ["downloads", "driveTransfers", "notify", "workspaceMarks"],
    );
  });

  it("enforces all 21 unconditional sensitive topics and stationPart byParam branches", () => {
    const sensitive = [...topicsWhere((p) => p.retention === "sensitive")].sort();
    assert.equal(sensitive.length, 21);
    assert.deepEqual(sensitive, EXPECTED_SENSITIVE);
    for (const name of EXPECTED_SENSITIVE) {
      for (const topicPolicy of [true, false]) {
        const ev = evaluateTopicPolicy(name, { workspace: "w1", scope: "w1" }, { topicPolicy });
        assert.equal(ev.retention, "sensitive", `${name} must be sensitive (topicPolicy=${topicPolicy})`);
        assert.equal(ev.sensitive, true);
        assert.equal(ev.keep, 0);
        assert.equal(ev.keepBeforeViews, 0);
        assert.equal(ev.lasting, false);
        assert.equal(ev.showKept, false);
      }
    }

    for (const part of ["machineLogins", "logins"]) {
      for (const topicPolicy of [true, false]) {
        const ev = evaluateTopicPolicy("stationPart", { scope: "w1", station: "w1/s1", part }, { topicPolicy });
        assert.equal(ev.retention, "sensitive");
        assert.equal(ev.sensitive, true);
        assert.equal(ev.keep, 0);
        assert.equal(ev.showKept, false);
      }
    }
    for (const part of ["archiving", "automaticDecisions", "unknownPart", ""]) {
      const ev = evaluateTopicPolicy("stationPart", { scope: "w1", station: "w1/s1", part });
      assert.equal(ev.retention, "live");
      assert.equal(ev.sensitive, false);
      assert.equal(ev.keep, 0);
      assert.equal(ev.showKept, false);
    }
    const missingPart = evaluateTopicPolicy("stationPart", { scope: "w1", station: "w1/s1" });
    assert.equal(missingPart.retention, "live");
    assert.equal(missingPart.keep, 0);
    assert.equal(missingPart.showKept, false);

    for (const part of ["profiles", "updates", "copies"]) {
      const ev = evaluateTopicPolicy("stationPart", { scope: "w1", station: "w1/s1", part });
      assert.equal(ev.retention, "swr");
      assert.equal(ev.sensitive, false);
      assert.equal(ev.keep, 24);
      assert.equal(ev.showKept, true);
    }
  });

  it("sanitizes profiles and station kept values without mutating originals", () => {
    const rawProfiles = {
      items: [{ key: "p1", name: "Claude" }],
      machineLogins: [{ station: "w1/s1", logins: [{ id: "ml1" }] }],
      manages: true,
    };
    const cleanProfiles = sanitizeKeptValue("profiles", rawProfiles) as Record<string, unknown>;
    assert.deepEqual(cleanProfiles, { items: [{ key: "p1", name: "Claude" }] });
    assert.equal("machineLogins" in cleanProfiles, false);
    assert.equal("manages" in cleanProfiles, false);
    assert.equal(rawProfiles.manages, true);

    const rawStation = {
      station: "w1/s1",
      name: "Box",
      overview: {
        counts: { running: 1 },
        machineLogins: [{ id: "ml1" }],
        logins: [{ id: "l1" }],
      },
    };
    const cleanStation = sanitizeKeptValue("station", rawStation) as Record<string, unknown>;
    assert.deepEqual(cleanStation, {
      station: "w1/s1",
      name: "Box",
      overview: { counts: { running: 1 } },
    });
    assert.equal("machineLogins" in (cleanStation.overview as Record<string, unknown>), false);
    assert.equal("logins" in (cleanStation.overview as Record<string, unknown>), false);
    assert.equal(rawStation.overview.machineLogins.length, 1);
  });

  it("preserves exact lasting, homeLasting, views_kept, and chat capacities", () => {
    const lasting = [...topicsWhere((p) => p.lasting === true)].sort();
    assert.deepEqual(lasting, EXPECTED_LASTING);

    const homeLasting = [...topicsWhere((p) => p.homeLasting === true)].sort();
    assert.deepEqual(homeLasting, EXPECTED_HOME_LASTING);

    const viewsKept: Record<string, number> = {};
    for (const name of TOPIC_NAMES) {
      const p = TOPIC_POLICY[name];
      if (p.showKept) viewsKept[name] = p.keep ?? 0;
    }
    assert.deepEqual(viewsKept, EXPECTED_VIEWS_KEPT);

    const chat = evaluateTopicPolicy("chat", { station: "w/s", session: "c-1" });
    assert.equal(chat.retention, "delta");
    assert.equal(chat.lasting, false);
    assert.equal(chat.showKept, false);
    assert.equal(chat.keep, 8);
    assert.equal(chat.keepBeforeViews, 4);

    // No lasting or showKept topic declares a `query` param in TOPICS (only `q` is used on cached lists).
    for (const name of [...EXPECTED_LASTING, ...Object.keys(EXPECTED_VIEWS_KEPT)] as TopicName[]) {
      assert.equal(Object.hasOwn(TOPICS[name], "query"), false, `${name} should not declare a query param`);
    }
  });

  it("evaluates (name, params) with q and query downgrade to live", () => {
    for (const name of EXPECTED_LASTING) {
      const plain = evaluateTopicPolicy(name, { scope: "w1" });
      assert.equal(plain.retention, "swr");
      assert.equal(plain.lasting, true);
      assert.equal(plain.keep, LASTING_KEPT);
      assert.equal(plain.keepBeforeViews, LASTING_KEPT);
      assert.equal(plain.showKept, false);

      const withQ = evaluateTopicPolicy(name, { scope: "w1", q: "needle" });
      assert.equal(withQ.retention, "live");
      assert.equal(withQ.lasting, false);
      assert.equal(withQ.keep, 0);
      assert.equal(withQ.keepBeforeViews, 0);
      assert.equal(withQ.showKept, false);

      const withEmptyQ = evaluateTopicPolicy(name, { scope: "w1", q: "" });
      assert.equal(withEmptyQ.lasting, false);
      assert.equal(withEmptyQ.keep, 0);

      const withQuery = evaluateTopicPolicy(name, { scope: "w1", query: "needle" });
      assert.equal(withQuery.retention, "live");
      assert.equal(withQuery.lasting, false);
      assert.equal(withQuery.keep, 0);

      const withEmptyQuery = evaluateTopicPolicy(name, { scope: "w1", query: "" });
      assert.equal(withEmptyQuery.lasting, true);
      assert.equal(withEmptyQuery.keep, LASTING_KEPT);
    }

    for (const [name, cap] of Object.entries(EXPECTED_VIEWS_KEPT)) {
      const plain = evaluateTopicPolicy(name as TopicName, { scope: "w1" });
      assert.equal(plain.retention, "swr");
      assert.equal(plain.lasting, false);
      assert.equal(plain.keep, cap);
      assert.equal(plain.keepBeforeViews, 0);
      assert.equal(plain.showKept, true);

      const withQ = evaluateTopicPolicy(name as TopicName, { scope: "w1", q: "abc" });
      assert.equal(withQ.retention, "live");
      assert.equal(withQ.keep, 0);
      assert.equal(withQ.showKept, false);

      const withQuery = evaluateTopicPolicy(name as TopicName, { scope: "w1", query: "abc" });
      assert.equal(withQuery.retention, "live");
      assert.equal(withQuery.keep, 0);
      assert.equal(withQuery.showKept, false);

      const withEmptyQuery = evaluateTopicPolicy(name as TopicName, { scope: "w1", query: "" });
      assert.equal(withEmptyQuery.keep, cap);
      assert.equal(withEmptyQuery.showKept, true);
    }
  });

  it("gates PR-B2b upgraded topics under MBUI_TOPIC_POLICY (on/off) while preserving lazyWhenIdle and delta rules", () => {
    const gated = [...topicsWhere((p) => p.topicPolicy === true)].sort();
    assert.deepEqual(gated, EXPECTED_B2B_POLICY_GATED);

    // When MBUI_TOPIC_POLICY is OFF, all 8 PR-B2b topics downgrade to live (keep=0, showKept=false, lasting=false).
    for (const name of EXPECTED_B2B_POLICY_GATED) {
      const off = evaluateTopicPolicy(name, { scope: "w1" }, { topicPolicy: false });
      assert.equal(off.retention, "live", `${name} must be live when topicPolicy=false`);
      assert.equal(off.sensitive, false);
      assert.equal(off.lasting, false);
      assert.equal(off.keep, 0);
      assert.equal(off.keepBeforeViews, 0);
      assert.equal(off.showKept, false);
    }
    // profilesOverview retains lazyWhenIdle=true in both switch states.
    assert.equal(evaluateTopicPolicy("profilesOverview", { scope: "w1" }, { topicPolicy: false }).lazyWhenIdle, true);
    assert.equal(evaluateTopicPolicy("profilesOverview", { scope: "w1" }, { topicPolicy: true }).lazyWhenIdle, true);

    // workspaces stays LIVE regardless of MBUI_TOPIC_POLICY (contains account/ownership metadata).
    for (const topicPolicy of [true, false]) {
      const ws = evaluateTopicPolicy("workspaces", {}, { topicPolicy });
      assert.equal(ws.retention, "live");
      assert.equal(ws.lasting, false);
      assert.equal(ws.keep, 0);
      assert.equal(ws.showKept, false);
    }

    for (const name of ["jobLog", "chatFeedback"] as const) {
      const ev = evaluateTopicPolicy(name, { station: "w1/s1", id: "j1" });
      assert.equal(ev.retention, "delta");
      assert.equal(ev.keep, 8);
      assert.equal(ev.showKept, false);
      assert.equal(ev.lasting, false);
    }

    for (const [name, cap] of [
      ["profilesOverview", 4],
      ["presets", 8],
      ["otherPresets", 8],
      ["releases", 4],
      ["fonts", 4],
    ] as const) {
      const ev = evaluateTopicPolicy(name, { scope: "w1" });
      assert.equal(ev.retention, "swr");
      assert.equal(ev.keep, cap);
      assert.equal(ev.showKept, true);
      assert.equal(ev.lasting, false);
    }
  });
});
