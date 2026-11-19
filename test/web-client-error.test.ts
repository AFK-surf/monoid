import assert from "node:assert/strict";
import test from "node:test";
import { ErrorGate, errorSummary, isNoise, thrownText } from "../web/src/mbui/client-error.ts";

test("an error's summary leaves out addresses' queries, fragments and its stack", () => {
  assert.equal(
    errorSummary("TypeError: failed https://app.example/o/1/chat?token=secret#frag and http://x.example/a?b=c\n    at f (https://app.example/mbui/app.js:1:2)"),
    "TypeError: failed https://app.example/o/1/chat and http://x.example/a",
  );
  assert.equal([...errorSummary("x".repeat(500))].length, 300);
  assert.equal(errorSummary("  \n  at stack"), "");
});

test("the same error goes once a minute, and only the latest 64 are kept", () => {
  const gate = new ErrorGate();
  assert.equal(gate.pass("web_error", "Error: boom", 0), "Error: boom");
  assert.equal(gate.pass("web_error", "Error: boom", 59_999), null);
  assert.equal(gate.pass("core_fault", "Error: boom", 1), "Error: boom");
  assert.equal(gate.pass("web_error", "Error: boom", 60_000), "Error: boom");
  // (an address's query differing is the same error)
  assert.equal(gate.pass("web_error", "Error: at https://a.example/?q=1", 0), "Error: at https://a.example/");
  assert.equal(gate.pass("web_error", "Error: at https://a.example/?q=2", 1), null);
  assert.equal(gate.pass("web_error", "", 0), null);
  for (let i = 0; i < 200; i++) gate.pass("web_error", `Error: ${i}`, 0);
  assert.equal(gate.size, 64);
});

test("what was thrown is said as name and message, and the browser's noise is told apart", () => {
  assert.equal(thrownText(new TypeError("bad")), "TypeError: bad");
  assert.equal(thrownText("plain"), "plain");
  assert.equal(thrownText(undefined), "");
  assert.equal(isNoise("ResizeObserver loop completed with undelivered notifications."), true);
  assert.equal(isNoise("Script error."), true);
  assert.equal(isNoise("TypeError: bad"), false);
});
