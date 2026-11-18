// What failed a turn, from what any runtime said of it (agents/runtime.ts `failureOf`): the account, the provider
// refusing it, a limit, the provider out of room, the network, the conversation's size, else the model. (Claude Code's
// own are told apart by the MoonBit program: station/mb/src/claude/frames_test.mbt.)
import assert from "node:assert/strict";
import { test } from "node:test";
import { failureOf } from "../src/agents/runtime.ts";

test("a failure is told apart by what it means to people", () => {
  assert.equal(failureOf("401 Unauthorized"), "auth");
  // A 403 is the account's where it says so, where the request comes from where it says that (a region, the CDN's page
  // for a blocked address); else it is not known why, and not guessed (2026-11-02: "unexpected status 403 Forbidden:").
  assert.equal(failureOf("unexpected status 403 Forbidden: "), "denied");
  assert.equal(failureOf("unexpected status 403 Forbidden: Unknown error, url: https://chatgpt.com/backend-api/codex/responses, cf-ray: 9a1"), "denied");
  assert.equal(failureOf("unexpected status 403 Forbidden: <html><head><title>Attention Required! | Cloudflare</title>"), "blocked");
  assert.equal(failureOf("unexpected status 403 Forbidden: Workspace is not authorized in this region."), "refused");
  assert.equal(failureOf("403: OAuth token does not meet scope requirement"), "auth");
  assert.equal(failureOf('{"error":{"code":"unsupported_country_region_territory"}}'), "refused");
  assert.equal(failureOf("429 Too Many Requests"), "rate_limit");
  // An API key's prepaid credits run out (a 400, no limit named): another account may have room, so it is a limit.
  assert.equal(failureOf("400 Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits."), "rate_limit");
  assert.equal(failureOf("the model is overloaded"), "overloaded");
  assert.equal(failureOf("stream disconnected before completion: error sending request"), "network");
  assert.equal(failureOf("request failed: ECONNRESET"), "network");
  assert.equal(failureOf("prompt is too long: 210000 tokens > 200000 maximum"), "context");
  assert.equal(failureOf("this model's maximum context length is 128000 tokens"), "context");
  assert.equal(failureOf("the model failed"), "model");
});
