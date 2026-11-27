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
