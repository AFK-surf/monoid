import assert from "node:assert/strict";
import { createServer } from "node:http";
import { test } from "node:test";
import { copilotDoor, copilotDoorToken } from "../src/share/copilot-door.ts";

test("only the bound Copilot session reaches the host; revoked shares fail before forwarding", async (t) => {
  let asks = 0;
  const route = copilotDoor((session, profile) => session === "chat:key" && profile === "p" ? "secret" : undefined, async () => {
    asks++;
    throw new Error("revoked");
  });
  const server = createServer((req, res) => void route.request(req, res));
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(() => new Promise<void>((resolve) => server.close(() => resolve())));
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  const call = (key: string, id: string, token: string) => fetch(`http://127.0.0.1:${address.port}/copilot-api/${key}/${id}/models`, {
    headers: { authorization: `Bearer ${token}` },
  });
  const token = copilotDoorToken("secret", "p");
  assert.equal((await call("chat%3Aother", "p", token)).status, 403);
  assert.equal((await call("chat%3Akey", "other", token)).status, 403);
  assert.equal((await call("chat%3Akey", "p", "secret")).status, 403);
  assert.equal(asks, 0);
  assert.equal((await call("chat%3Akey", "p", token)).status, 503);
  assert.equal(asks, 1);
});

test("a rejected model request renews the credential and replays the same body once", async (t) => {
  const calls: Array<[string | undefined, string]> = [];
  const upstream = createServer(async (req, res) => {
    let body = "";
    for await (const chunk of req) body += chunk;
    calls.push([req.headers.authorization, body]);
    res.writeHead(calls.length === 1 ? 401 : 200).end("model response");
  });
  const listen = async (server: typeof upstream) => {
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    t.after(() => new Promise<void>((resolve) => server.close(() => resolve())));
    const address = server.address();
    assert.ok(address && typeof address !== "string");
    return `http://127.0.0.1:${address.port}`;
  };
  const api = await listen(upstream);
  const rejected: Array<string | undefined> = [];
  const route = copilotDoor(() => "secret", async (_id, refused) => {
    rejected.push(refused);
    return { api, token: refused ? "second" : "first", expiresAt: 1e15 };
  }, (await import("node:http")).request);
  const url = await listen(createServer((req, res) => void route.request(req, res)));
  const result = await fetch(url + "/copilot-api/s/p/responses", {
    method: "POST", headers: { authorization: `Bearer ${copilotDoorToken("secret", "p")}` }, body: "prompt",
  });
  assert.equal(await result.text(), "model response");
  assert.deepEqual(calls, [["Bearer first", "prompt"], ["Bearer second", "prompt"]]);
  assert.deepEqual(rejected, [undefined, "first"]);
});
