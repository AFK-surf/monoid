import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { runInNewContext } from "node:vm";
import { socketScript } from "../cloud/src/previewSocket.ts";

type On = { open(protocol: string): void; close(code: number, reason: string, failed: boolean): void };
type Sent = ["send", string | number[]] | ["close", number, string];

async function page(native: boolean) {
  const calls: Sent[] = [];
  const started = Promise.withResolvers<void>();
  const closed = Promise.withResolvers<void>();
  let on!: On;
  const send = (data: string | Uint8Array) => { calls.push(["send", typeof data === "string" ? data : [...data]]); };
  const close = (code: number, reason: string) => { calls.push(["close", code, reason]); closed.resolve(); };
  const sandbox = {
    URL, EventTarget, Event, MessageEvent, CloseEvent, DOMException, Blob, ArrayBuffer, Uint8Array,
    crypto, btoa, atob, location: new URL("https://service.example/page"), navigator: { language: "en" },
    WebSocket, addEventListener() {},
    // Only sockets are under test; the native page's separate body and annotation bridges are already installed.
    __stillfailBodies: true, __stillfailMarks: true, __stillfailLang: "en",
    link: (_path: string, _protocols: string[], callbacks: On) => {
      on = callbacks;
      started.resolve();
      return { send, close };
    },
    StillFailPreviewNative: {
      open(id: string) {
        on = {
          open: (protocol) => context.__stillfailSocketEvent(id, "open", protocol),
          close: (code, reason, failed) => context.__stillfailSocketEvent(id, "close", code, reason, failed),
        };
        started.resolve();
      },
      send: (_id: string, text: string) => send(text),
      sendBinary: (_id: string, bytes: string) => send(new Uint8Array(Buffer.from(bytes, "base64"))),
      close: (_id: string, code: number, reason: string) => close(code, reason),
    },
  };
  const context = Object.assign(sandbox, {
    window: sandbox, self: sandbox, top: sandbox,
    __stillfailSocketEvent: null as unknown as (id: string, kind: string, ...args: unknown[]) => void,
  });
  const script = native
    ? await readFile(new URL("../apps/mbui/assets/preview/page.js", import.meta.url), "utf8")
    : socketScript("globalThis.link");
  runInNewContext(script, context);
  const socket = new context.WebSocket("wss://service.example/socket");
  await started.promise;
  return { socket, on, calls, closed: closed.promise };
}

for (const native of [false, true]) {
  const host = native ? "native page" : "web page";
  test(`${host}: close follows every accepted text and binary message`, async () => {
    const h = await page(native);
    h.on.open("");
    h.socket.send("save");
    h.socket.send(new Uint8Array([1, 2, 3]));
    h.socket.send("saved");
    h.socket.close(1000, "done");
    h.socket.close(1001, "ignored");
    h.socket.send("too late");
    assert.equal(h.socket.readyState, WebSocket.CLOSING);
    assert.deepEqual(h.calls, [], "accepted messages precede the close frame");
    await h.closed;
    assert.deepEqual(h.calls, [["send", "save"], ["send", [1, 2, 3]], ["send", "saved"], ["close", 1000, "done"]]);
  });

  test(`${host}: close waits for a Blob already being read`, async () => {
    const h = await page(native);
    const reading = Promise.withResolvers<void>();
    const bytes = Promise.withResolvers<ArrayBuffer>();
    class HeldBlob extends Blob {
      override arrayBuffer(): Promise<ArrayBuffer> { reading.resolve(); return bytes.promise; }
    }
    h.on.open("");
    h.socket.send(new HeldBlob());
    await reading.promise;
    h.socket.send("after blob");
    h.socket.close(1000, "done");
    assert.deepEqual(h.calls, []);
    bytes.resolve(new Uint8Array([4, 5]).buffer);
    await h.closed;
    assert.deepEqual(h.calls, [["send", [4, 5]], ["send", "after blob"], ["close", 1000, "done"]]);
  });

  test(`${host}: closing while connecting still cancels the connection`, async () => {
    const h = await page(native);
    assert.throws(() => h.socket.send("not open"), { name: "InvalidStateError" });
    h.socket.close(1000, "cancel");
    h.on.open("late");
    await h.closed;
    assert.equal(h.socket.readyState, WebSocket.CLOSING);
    assert.deepEqual(h.calls, [["close", 1000, "cancel"]]);
  });

  test(`${host}: a peer close during a Blob read cancels the queued work`, async () => {
    const h = await page(native);
    const reading = Promise.withResolvers<void>();
    const bytes = Promise.withResolvers<ArrayBuffer>();
    class HeldBlob extends Blob {
      override arrayBuffer(): Promise<ArrayBuffer> { reading.resolve(); return bytes.promise; }
    }
    h.on.open("");
    h.socket.send(new HeldBlob());
    await reading.promise;
    h.socket.send("after blob");
    h.socket.close();
    h.on.close(1006, "lost", true);
    bytes.resolve(new Uint8Array([4, 5]).buffer);
    // The peer has already closed; wait for this socket's accepted work to finish discarding its bytes.
    await (h.socket as WebSocket & { _sending: Promise<void> })._sending;
    assert.equal(h.socket.readyState, WebSocket.CLOSED);
    assert.deepEqual(h.calls, []);
  });

  test(`${host}: a failed Blob read does not prevent the requested close`, async () => {
    const h = await page(native);
    const reading = Promise.withResolvers<void>();
    const bytes = Promise.withResolvers<ArrayBuffer>();
    class HeldBlob extends Blob {
      override arrayBuffer(): Promise<ArrayBuffer> { reading.resolve(); return bytes.promise; }
    }
    h.on.open("");
    h.socket.send(new HeldBlob());
    await reading.promise;
    h.socket.close(1000, "done");
    bytes.reject(new Error("file no longer readable"));
    await h.closed;
    assert.deepEqual(h.calls, [["close", 1000, "done"]]);
  });
}
