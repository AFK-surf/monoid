import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { parseTopic, TOPICS, type TopicName } from "../src/protocol.ts";
import { ASKED_BY_WORDS, KEPT_PER_CLIENT } from "../src/store.ts";
import {
  evaluateTopicPolicy,
  isKnownTopic,
  KEPT_MOST_BEFORE_VIEWS,
  LASTING_KEPT,
  TOPIC_NAMES,
  TOPIC_POLICY,
  topicsWhere,
} from "../src/topic-policy.ts";

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
  "vaults",
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
  pick: 12,
  profile: 16,
  project: 16,
  projects: 8,
  railCard: 16,
  station: 16,
  stationPart: 24,
  tags: 8,
};

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

    assert.deepEqual([...ASKED_BY_WORDS].sort(), ["chatSearch", "chatSubchats", "search"]);
    assert.deepEqual([...topicsWhere((p) => p.lazyWhenIdle === true)].sort(), ["profilesOverview"]);
    assert.deepEqual(
      [...topicsWhere((p) => p.unseen === true)].sort(),
      ["downloads", "driveTransfers", "notify", "workspaceMarks"],
    );
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
});
