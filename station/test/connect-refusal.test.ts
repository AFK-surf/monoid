// A platform refusing a connect's socket in the handshake says why: Slack in its `handshake-msg` header, Comma in the
// answer's JSON body (a 409 naming the station of the workspace connected already). The connect's status carries those
// words, so its page says what to do next, not a bare status.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { CommaSurface } from "../src/comma/surface.ts";
import { CommaTasks } from "../src/comma/tasks.ts";
import { refusalWords } from "../src/connects/surface.ts";
import { Rig } from "./hub-fakes.ts";

test("why a socket was refused: the header first, then the JSON body's error or message, then its text on one line", () => {
  assert.equal(refusalWords("too many sockets", '{"error":"x"}'), "too many sockets");
  assert.equal(refusalWords("", '{"error":"connected already, as mini; disconnect it first"}'), "connected already, as mini; disconnect it first");
  assert.equal(refusalWords("", '{"message":"no"}'), "no");
  assert.equal(refusalWords("", "<html>\n  Bad gateway\n</html>"), "<html> Bad gateway </html>");
  assert.equal(refusalWords("", '{"other":1}'), '{"other":1}');
  assert.equal(refusalWords("", "  "), "");
  assert.equal(refusalWords("", "x".repeat(400)).length, 300);
});

test("a Comma connect refused with 409 shows Comma's words in its status", async () => {
  const why = "this still.fail workspace is connected to this Comma workspace already, as mini; disconnect that one in Comma's still.fail plugin first";
  const server = createServer((_req, res) => res.writeHead(404).end());
  server.on("upgrade", (_req, socket) => {
    const body = JSON.stringify({ error: why });
    socket.end(`HTTP/1.1 409 Conflict\r\ncontent-type: application/json\r\ncontent-length: ${Buffer.byteLength(body)}\r\nconnection: close\r\n\r\n${body}`);
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  const rig = new Rig();
  const dir = mkdtempSync(join(tmpdir(), "comma-refused-"));
  const surface = new CommaSurface({
    connect: "cm", server: base, token: "salix_conn_test123", name: "pc", tasks: new CommaTasks(join(dir, "tasks.json")),
    store: rig.store, models: () => [],
  });
  const refused = new Promise<string>((resolve) => {
    surface.onChange(() => {
      const error = surface.socket().lastError;
      if (error !== null) resolve(error);
    });
  });
  try {
    await surface.start(async () => {});
    assert.equal(await refused, `comma refused the connection: HTTP 409 ${why}`);
  } finally {
    await surface.stop();
    await rig.close();
    rmSync(dir, { recursive: true, force: true });
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});
