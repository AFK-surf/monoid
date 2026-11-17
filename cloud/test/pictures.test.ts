import assert from "node:assert/strict";
import test from "node:test";
import { PICTURE_BYTES, servePicture } from "../src/pictures.ts";

// GET /v1/pictures: Slack's pictures for the app in a browser (src/pictures.ts).

const SLACK = "https://avatars.slack-edge.com/2026-09-27/1_ab_72.jpg";
const asked = (url: string) => new Request(`https://app.still.fail/v1/pictures?url=${encodeURIComponent(url)}`);
const answering = (status: number, type: string, body: Uint8Array) => {
  const fetched: string[] = [];
  const get = async (url: string) => {
    fetched.push(url);
    return new Response(body, { status, headers: { "content-type": type } });
  };
  return { fetched, get };
};

test("a Slack picture is answered as it is, kept a day", async () => {
  const slack = answering(200, "image/jpeg", new Uint8Array([1, 2, 3]));
  const r = await servePicture(asked(SLACK), slack.get);
  assert.equal(r.status, 200);
  assert.deepEqual([...new Uint8Array(await r.arrayBuffer())], [1, 2, 3]);
  assert.equal(r.headers.get("content-type"), "image/jpeg");
  assert.equal(r.headers.get("cache-control"), "public, max-age=86400");
  assert.equal(r.headers.get("x-content-type-options"), "nosniff");
  assert.deepEqual(slack.fetched, [SLACK]);
});

test("no address but Slack's is fetched", async () => {
  for (const url of ["https://example.com/a.png", "http://avatars.slack-edge.com/a.jpg", "https://slack-edge.com.example.com/a.jpg", "https://169.254.169.254/", ""]) {
    const any = answering(200, "image/png", new Uint8Array([1]));
    assert.equal((await servePicture(asked(url), any.get)).status, 400, url);
    assert.deepEqual(any.fetched, []);
  }
});

test("what is not a picture, an SVG or one too large is not answered", async () => {
  assert.equal((await servePicture(asked(SLACK), answering(200, "text/html", new Uint8Array([1])).get)).status, 404);
  assert.equal((await servePicture(asked(SLACK), answering(200, "image/svg+xml", new Uint8Array([1])).get)).status, 404);
  assert.equal((await servePicture(asked(SLACK), answering(302, "image/png", new Uint8Array([])).get)).status, 404);
  assert.equal((await servePicture(asked(SLACK), answering(200, "image/png", new Uint8Array(PICTURE_BYTES + 1)).get)).status, 413);
  assert.equal((await servePicture(asked(SLACK), async () => { throw new Error("down"); })).status, 502);
});

test("a streamed picture is stopped at the limit without reading the rest", async () => {
  for (const declared of [undefined, "1", String(PICTURE_BYTES + 1)]) {
    let reads = 0;
    let cancelled = false;
    const body = new ReadableStream<Uint8Array>({
      pull(controller) {
        reads++;
        if (reads === 1) controller.enqueue(new Uint8Array(PICTURE_BYTES));
        else if (reads === 2) controller.enqueue(new Uint8Array([1]));
        else controller.error(new Error("the rest of the oversized picture must not be read"));
      },
      cancel() {
        cancelled = true;
        // Cleanup failing on an already broken connection must not hide the size rejection.
        if (declared !== undefined) throw new Error("connection closed");
      },
    }, { highWaterMark: 0 });
    const headers = new Headers({ "content-type": "image/png" });
    if (declared !== undefined) headers.set("content-length", declared);
    const response = await servePicture(asked(SLACK), async () => new Response(body, { headers }));
    assert.equal(response.status, 413);
    assert.deepEqual(await response.json(), { error: "too_large" });
    assert.equal(reads, declared === String(PICTURE_BYTES + 1) ? 0 : 2);
    assert.equal(cancelled, true);
    assert.equal(body.locked, false);
  }
});

test("a picture exactly at the limit keeps every streamed byte in order", async () => {
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(new Uint8Array(PICTURE_BYTES - 1).fill(7));
      controller.enqueue(new Uint8Array([9]));
      controller.close();
    },
  });
  const response = await servePicture(asked(SLACK), async () => new Response(body, { headers: { "content-type": "image/png" } }));
  assert.equal(response.status, 200);
  const bytes = new Uint8Array(await response.arrayBuffer());
  assert.equal(bytes.length, PICTURE_BYTES);
  assert.equal(bytes.subarray(0, -1).every((byte) => byte === 7), true);
  assert.equal(bytes.at(-1), 9);
});

test("a picture whose connection breaks while reading answers unreachable and releases the reader", async () => {
  let reads = 0;
  const body = new ReadableStream<Uint8Array>({
    pull(controller) {
      if (reads++ === 0) controller.enqueue(new Uint8Array([1, 2, 3]));
      else controller.error(new Error("upstream connection lost"));
    },
  }, { highWaterMark: 0 });
  const response = await servePicture(asked(SLACK), async () => new Response(body, { headers: { "content-type": "image/png" } }));
  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), { error: "unreachable" });
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.equal(body.locked, false);
});

test("many small picture chunks keep their bytes across buffer growth", async () => {
  let sent = 0;
  const count = 4097, size = 17;
  const body = new ReadableStream<Uint8Array>({
    pull(controller) {
      if (sent === count) controller.close();
      else controller.enqueue(new Uint8Array(size).fill(sent++ % 251));
    },
  }, { highWaterMark: 0 });
  const response = await servePicture(asked(SLACK), async () => new Response(body, { headers: { "content-type": "image/png" } }));
  assert.equal(response.status, 200);
  const bytes = new Uint8Array(await response.arrayBuffer());
  assert.equal(bytes.length, count * size);
  assert.equal(bytes.every((byte, i) => byte === Math.floor(i / size) % 251), true);
});
