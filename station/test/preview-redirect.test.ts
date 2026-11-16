import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import http from "node:http";
import { syncBuiltinESMExports } from "node:module";
import { Readable } from "node:stream";
import { test, type TestContext } from "node:test";
import { proxyPreview, type Asker } from "../src/jobs/preview.ts";

/// The service's HTTP answer, without a real socket or another process deciding when it comes.
function redirects(t: TestContext, asker: Asker) {
  let location = "";
  const request = t.mock.method(http, "request", (() => {
    const answer = Object.assign(Readable.from([]), { statusCode: 302, rawHeaders: ["Location", location] });
    const asked = Object.assign(new EventEmitter(), {
      end() { queueMicrotask(() => asked.emit("response", answer)); return asked; },
    });
    return asked as unknown as http.ClientRequest;
  }) as typeof http.request);
  syncBuiltinESMExports();
  t.after(() => { request.mock.restore(); syncBuiltinESMExports(); });
  return async (value: string) => {
    location = value;
    const response = await proxyPreview("GET", [], null, 3000, "/old/page", "en", asker);
    for await (const _ of response.body) { /* consume the service's response */ }
    assert.equal(response.status, 302);
    return response.headers.find(([name]) => name === "location")?.[1];
  };
}

for (const asker of ["preview", "peer"] as const) {
  test(`${asker}: a redirect to another authority keeps its complete address`, async (t) => {
    const redirect = redirects(t, asker);
    for (const value of [
      "http://localhost:30001/login",
      "https://127.0.0.1:30001/login",
      "http://[::1]:30001/login",
      "http://localhost:3000@example.test/login",
      "https://example.test/login",
      "/new?x=1",
      "../login",
    ]) assert.equal(await redirect(value), value);
  });

  test(`${asker}: a redirect to this service keeps its path, query and fragment`, async (t) => {
    const redirect = redirects(t, asker);
    for (const origin of ["http://localhost:3000", "https://127.0.0.1:3000", "http://[::1]:3000"]) {
      for (const [suffix, want] of [["/new?x=1#part", "/new?x=1#part"], ["", "/"], ["?x=1", "/?x=1"], ["#part", "/#part"]]) {
        assert.equal(await redirect(origin + suffix), want);
      }
    }
  });
}
