// Where the links a station gives people to its session pages go (sessions/page.ts): the product's own origin, the
// same on every station of a workspace, never its test channel's (FB-81).
import assert from "node:assert/strict";
import { test } from "node:test";
import { pageOrigin, sessionPage } from "../src/sessions/page.ts";

test("a session page's origin is the product's own, never its test channel's, whichever host the station enrolled at", () => {
  assert.equal(pageOrigin("https://app.still.fail"), "https://app.still.fail");
  assert.equal(pageOrigin("https://app.youdid.wtf"), "https://app.still.fail");
  assert.equal(pageOrigin("https://app.monoid.build"), "https://app.monoid.build");
  assert.equal(pageOrigin("https://app.monoid.zone"), "https://app.monoid.build");
  // a cloud of one's own keeps its origin, whatever a lock says
  assert.equal(pageOrigin("https://cloud.example.com"), "https://cloud.example.com");
  assert.equal(pageOrigin("https://cloud.example.com", ["https://app.still.fail"]), "https://cloud.example.com");
});

test("the stations of a workspace in safe mode link its pages on the origin its lock says, wherever each is enrolled", () => {
  // the FB-81 workspace: stations enrolled at still.fail's host and monoid's, each on either channel
  const enrolled = ["https://app.still.fail", "https://app.youdid.wtf", "https://app.monoid.build", "https://app.monoid.zone"];
  for (const origins of [["https://app.still.fail"], ["https://app.youdid.wtf"]]) {
    assert.deepEqual(enrolled.map((o) => pageOrigin(o, origins)), enrolled.map(() => "https://app.still.fail"), JSON.stringify(origins));
  }
  assert.deepEqual(enrolled.map((o) => pageOrigin(o, ["https://app.monoid.build/"])), enrolled.map(() => "https://app.monoid.build"));
  // origins of no product the cloud answers are passed over for the next, else the station's own
  assert.equal(pageOrigin("https://app.monoid.build", ["http://localhost:8787", "https://app.still.fail"]), "https://app.still.fail");
  assert.equal(pageOrigin("https://app.monoid.zone", ["http://localhost:8787"]), "https://app.monoid.build");
  assert.equal(pageOrigin("https://app.youdid.wtf", []), "https://app.still.fail");
});

test("a session page's link", () => {
  const at = { origin: pageOrigin("https://app.youdid.wtf"), workspace: "w1", station: "s1" };
  assert.equal(sessionPage(at, "w2", "chat:c/1"), "https://app.still.fail/o/w2/s1/chat%3Ac%2F1");
});
