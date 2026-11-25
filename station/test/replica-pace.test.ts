// Backups leave the station at one shared rate (replica/pace.ts): slices go when the rate allows, callers share it,
// 0 lets everything through, and `backup.uploadMbps` is read, checked and kept across a settings change.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { test } from "node:test";
import { S3Client } from "../src/replica/s3.ts";
import { ADJUST_MS, BASE_MS, BURST_MS, DOWN, FLOOR, Pace, SLICE, TARGET_MS, UP, bytesPerSecond } from "../src/replica/pace.ts";
import { DEFAULT_UPLOAD_MBPS, applyBackupUpdate, checkBackupConfig, readBackupConfig } from "../src/replica/backup-config.ts";

/// A clock that only moves when a wait asks it to, each wait recorded.
function fakeClock() {
  let at = 1_000_000;
  const waits: number[] = [];
  return {
    waits,
    now: () => at,
    sleep: async (ms: number) => {
      waits.push(ms);
      at += ms;
    },
    get at() {
      return at;
    },
  };
}

async function drain(bytes: AsyncIterable<Buffer>): Promise<number[]> {
  const sizes: number[] = [];
  for await (const piece of bytes) sizes.push(piece.length);
  return sizes;
}

test("pace: bytes go in slices at the rate, after one burst", async () => {
  const clock = fakeClock();
  const rate = 1_000_000; // bytes a second
  const pace = new Pace({ now: clock.now, sleep: clock.sleep, rate: () => rate });
  const start = clock.at;
  const total = 4 * 1024 * 1024 + 123;
  async function* one() {
    yield Buffer.alloc(total);
  }
  const sizes = await drain(pace.paced(one()));
  assert.ok(sizes.every((n) => n <= SLICE), "no piece larger than a slice");
  assert.equal(sizes.reduce((a, b) => a + b, 0), total);
  const took = clock.at - start;
  const expected = (total * 1000) / rate - BURST_MS;
  assert.ok(Math.abs(took - expected) < 1, `took ${took} ms, expected ${expected}`);
  assert.ok(clock.waits.every((w) => w <= (SLICE * 1000) / rate + 1e-6), "no wait longer than one slice's time");
});

test("pace: callers share one rate, and 0 does not pace", async () => {
  // Two callers asking at the same moment (the clock stands still while they wait).
  const waits: number[] = [];
  let rate = 500_000;
  const pace = new Pace({ now: () => 0, sleep: async (ms) => { waits.push(ms); }, rate: () => rate });
  await Promise.all([pace.take(1_000_000), pace.take(1_000_000)]);
  // Both at the one rate: the second waits behind the first.
  assert.deepEqual(waits, [2000 - BURST_MS, 4000 - BURST_MS]);

  rate = 0;
  assert.equal(pace.on, false);
  await pace.take(10_000_000);
  assert.equal(waits.length, 2);
});

test("pace: an idle pace lets only a burst through at once", async () => {
  const clock = fakeClock();
  const pace = new Pace({ now: clock.now, sleep: clock.sleep, rate: () => 1000 });
  await pace.take(250); // within the burst
  assert.deepEqual(clock.waits, []);
  await clock.sleep(60_000); // a long idle does not bank more than the burst
  clock.waits.length = 0;
  await pace.take(1250);
  assert.deepEqual(clock.waits, [1000]);
});

test("pace: under its ceiling it gives way by the delay the line queues, and comes back as it goes", () => {
  const ceiling = 1_000_000;
  let at = 0;
  let rtts = [{ key: "keeper", ms: 40 }, { key: "other", ms: 120 }];
  const pace = new Pace({ now: () => at, sleep: async () => {}, rate: () => ceiling, rtts: () => rtts });
  // First heard at their base: it starts at a quarter of the ceiling and climbs.
  assert.equal(pace.rate(ceiling, at), ceiling / 4 + ceiling * UP);
  at += ADJUST_MS / 2;
  assert.equal(pace.rate(ceiling, at), ceiling / 4 + ceiling * UP, "worked out again only each ADJUST_MS");
  let rate = 0;
  for (let i = 0; i < 100; i++) rate = pace.rate(ceiling, (at += ADJUST_MS));
  assert.equal(rate, ceiling, "no delay: up to the ceiling, never past it");
  // One connection's round trip grows past its base by more than the target (its uplink queued): down each time.
  rtts = [{ key: "keeper", ms: 40 + TARGET_MS + 200 }, { key: "other", ms: 120 }];
  assert.equal(pace.rate(ceiling, (at += ADJUST_MS)), ceiling * DOWN);
  for (let i = 0; i < 100; i++) rate = pace.rate(ceiling, (at += ADJUST_MS));
  assert.equal(rate, FLOOR, "it keeps going, at its floor");
  // Half the target over: it climbs at half the step.
  rtts = [{ key: "keeper", ms: 40 + TARGET_MS / 2 }, { key: "other", ms: 120 }];
  assert.equal(pace.rate(ceiling, (at += ADJUST_MS)), FLOOR + (ceiling * UP) / 2);
  // A smaller ceiling holds it at once.
  assert.equal(pace.rate(10_000, at), 10_000);
});

test("pace: a connection's base is its least round trip of the last BASE_MS, and none told is the ceiling alone", () => {
  let at = 0;
  let rtts: { key: string; ms: number }[] = [{ key: "k", ms: 30 }];
  const pace = new Pace({ now: () => at, sleep: async () => {}, rate: () => 1, rtts: () => rtts });
  assert.equal(pace.delay(at), 0);
  rtts = [{ key: "k", ms: 90 }];
  at += BASE_MS / 2;
  assert.equal(pace.delay(at), 60, "the last half's least still counts");
  at += BASE_MS / 2;
  assert.equal(pace.delay(at), 0, "a line that changed comes to its new base");
  rtts = [];
  assert.equal(pace.delay(at), null);
  const alone = new Pace({ now: () => 0, sleep: async () => {}, rate: () => 500 });
  assert.equal(alone.rate(500, 0), 500, "no other station connected: the ceiling, as before");
});

test("backup.uploadMbps: default, checked, kept", () => {
  assert.equal(bytesPerSecond(8), 1_000_000);
  assert.equal(bytesPerSecond(0), 0);
  assert.equal(readBackupConfig({}).uploadMbps, DEFAULT_UPLOAD_MBPS);
  assert.equal(readBackupConfig({ backup: { acceptOthers: false } }).uploadMbps, DEFAULT_UPLOAD_MBPS);
  assert.equal(readBackupConfig({ backup: { uploadMbps: 0 } }).uploadMbps, 0);
  assert.equal(readBackupConfig({ backup: { uploadMbps: 2.5 } }).uploadMbps, 2.5);
  assert.equal(readBackupConfig({ backup: { uploadMbps: -1 } }).uploadMbps, DEFAULT_UPLOAD_MBPS);
  assert.throws(() => checkBackupConfig({ uploadMbps: -1 }));
  assert.throws(() => checkBackupConfig({ uploadMbps: "fast" }));
  checkBackupConfig({ uploadMbps: 20 });

  // A change of other settings keeps the rate; a change of the rate is kept; the default is not written out.
  const kept = applyBackupUpdate({ backup: { uploadMbps: 20 } }, { acceptOthers: false }).backup;
  assert.equal(kept.uploadMbps, 20);
  assert.equal(applyBackupUpdate({}, { uploadMbps: 0 }).backup.uploadMbps, 0);
  assert.equal(applyBackupUpdate({}, { acceptOthers: true }).backup.uploadMbps, undefined);
  assert.throws(() => applyBackupUpdate({}, { uploadMbps: -3 }));
});

test("pace: an S3 PUT goes paced, whole, with its length and not chunked", async () => {
  const got: { length: string | undefined; chunked: string | undefined; bytes: Buffer }[] = [];
  const server = createServer((req, res) => {
    const parts: Buffer[] = [];
    req.on("data", (d: Buffer) => parts.push(d));
    req.on("end", () => {
      got.push({ length: req.headers["content-length"], chunked: req.headers["transfer-encoding"], bytes: Buffer.concat(parts) });
      res.end();
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  try {
    const port = (server.address() as { port: number }).port;
    const waits: number[] = [];
    const pace = new Pace({ now: () => 0, sleep: async (ms) => { waits.push(ms); }, rate: () => 1_000_000 });
    const client = new S3Client(
      {
        id: "t", name: "t", endpoint: `http://127.0.0.1:${port}`, region: "auto", bucket: "bkt", prefix: "p",
        forcePathStyle: true, accessKeyId: "ak", secretAccessKey: "sk", encryptionKey: "0".repeat(64), includeTranscripts: true,
      },
      { now: () => 0, pace },
    );
    const body = Buffer.alloc(SLICE * 5 + 7, 7);
    await client.putObject("k", body);
    assert.equal(got.length, 1);
    assert.equal(got[0]!.length, String(body.length));
    assert.equal(got[0]!.chunked, undefined);
    assert.ok(got[0]!.bytes.equals(body));
    assert.equal(waits.length, 6 - Math.floor((BURST_MS * 1_000_000) / 1000 / SLICE), "a wait for each slice past the burst");
  } finally {
    await new Promise<void>((r) => server.close(() => r()));
  }
});
