// A view's pace (mesh/screen-pace.ts): which frames may go, and the bit rate its source
// is asked for, from the acknowledgements alone, on a clock the test moves.
import assert from "node:assert/strict";
import { test } from "node:test";
import { CUT, DOWN, DOWNSIZE_MS, FPS_CHOICES, FrameLatency, HOLD_MS, KEY_QUEUE_MS, LAN_RATE, LIGHT_CUT, LoopStall, DOWNSIZE_SHARE, LOW_BOUNDS, MAX_RATE, MAX_UNACKED, MIN_RATE, NEAR_RATE, Pacer, QUEUE_MS, USED, START_RATE, START_UNACKED, START_UP, Sizer, UPSIZE_MS, UP, UP_AFTER_MS, UP_EVERY_MS, UP_FAST, MOVING_SHARPEN_MS, MOVING_SHARPEN_UP, STILL_MS, Sharpener, ownRate, queueMs, rateCeiling, startRate, RTT_WINDOW_MS, VIEWER_HOLD_LIMIT_MS } from "../src/mesh/screen-pace.ts";

function paced() {
  let now = 0;
  const pacer = new Pacer(() => now);
  let ts = 0;
  return {
    pacer,
    at: (ms: number) => void (now = ms),
    /// Frames sent while the pacer lets them (at most `n`), each `bytes` long: their timestamps.
    send(n: number, bytes = 10_000): number[] {
      const sent: number[] = [];
      for (let i = 0; i < n && pacer.may(); i++) {
        ts += 1000;
        pacer.sent(ts, bytes);
        sent.push(ts);
      }
      return sent;
    },
  };
}

/// Frames offered each 16 ms for `ms` over a link that decodes each `trip` ms after it went: how many went.
function over(trip: number, ms: number): number {
  const p = paced();
  const due: { at: number; ts: number }[] = [];
  let went = 0;
  for (let t = 0; t < ms; t++) {
    p.at(t);
    while (due.length > 0 && due[0]!.at <= t) p.pacer.acked(due.shift()!.ts);
    if (t % 16 === 0) for (const ts of p.send(1)) (went++, due.push({ at: t + trip, ts }));
  }
  return went;
}

test("a far link carries as many frames as a near one: they go while the oldest waits no longer than the round trip", () => {
  const near = over(20, 2000);
  const far = over(150, 2000);
  assert.ok(near >= 120, `near: ${near}`);
  assert.ok(far >= near - 12, `far: ${far} of ${near}`);
  // Two before the round trip is known, then as many as the link holds.
  const p = paced();
  assert.equal(p.send(10).length, START_UNACKED);
});

test("the pictures waiting in front of the link say so, without holding or lowering anything", () => {
  const p = paced();
  // None on the way, or the round trip not known: nothing waits.
  assert.equal(p.pacer.backlogged(), false);
  p.send(1);
  p.at(20);
  p.pacer.acked(1000);
  p.send(2);
  p.at(20 + 20 + QUEUE_MS);
  assert.equal(p.pacer.backlogged(), false, "the round trip and the queue a view lets build");
  p.at(20 + 20 + QUEUE_MS + 1);
  assert.equal(p.pacer.backlogged(), true);
  // Asking changed nothing of the pace (the rate, what may go): the same as before it was asked.
  const rate = p.pacer.rate();
  assert.equal(p.pacer.rate(), rate);
  // Acknowledged: the queue gone.
  p.pacer.acked(3000);
  assert.equal(p.pacer.backlogged(), false);
});

test("a queue building stops the frames until an acknowledgement", () => {
  const p = paced();
  p.send(1);
  p.at(20);
  p.pacer.acked(1000);
  assert.equal(p.pacer.rtt(), 20);
  p.send(3);
  assert.equal(p.pacer.unacked, 3);
  // The oldest has waited the round trip and QUEUE_MS: none more.
  p.at(20 + 20 + QUEUE_MS);
  assert.equal(p.pacer.may(), true);
  p.at(20 + 20 + QUEUE_MS + 1);
  assert.equal(p.pacer.may(), false);
  p.pacer.acked(4000);
  assert.equal(p.pacer.may(), true);
  // A far link's round trip varies more: half of it, where that is more than QUEUE_MS.
  assert.equal(queueMs(20), QUEUE_MS);
  assert.equal(queueMs(150), 75);
});

/// A source at 60 frames a second over a link that carries `capacity()` bits a second (each frame decoded once it is
/// through, after `base` ms more), each frame as large as the rate the pacer asks makes it: the pacer's rate each ms.
function bottleneck(capacity: (t: number) => number, ms: number, base = 10, start: number | null = null, own = ownRate(1920, 1080)) {
  let now = 0;
  const pacer = new Pacer(() => now, start);
  pacer.ceiling(own);
  const due: { at: number; ts: number }[] = [];
  let free = 0;
  let ts = 0;
  const rates: number[] = [];
  for (let t = 0; t < ms; t++) {
    now = t;
    while (due.length > 0 && due[0]!.at <= t) pacer.acked(due.shift()!.ts);
    if (t % 16 === 0 && pacer.may()) {
      const bytes = Math.round(pacer.rate()! / 60 / 8);
      ts += 1000;
      pacer.sent(ts, bytes);
      free = Math.max(free, t) + (bytes * 8 * 1000) / capacity(t);
      due.push({ at: Math.ceil(free) + base, ts });
    }
    rates.push(pacer.rate()!);
  }
  return rates;
}

test("the bit rate: down towards what went through once frames stay held back, never below CUT at a time; up again a step at a time", () => {
  const own = ownRate(1920, 1080);
  // A link that carries 5 Mbit/s for 4 s, then 100.
  const rates = bottleneck((t) => (t < 4000 ? 5_000_000 : 100_000_000), 20_000);
  const low = Math.min(...rates.slice(0, 4000));
  assert.ok(low < 5_000_000, `lowered to under the link: ${low}`);
  assert.ok(low >= 5_000_000 * DOWN * 0.5, `about what went through: ${low}`);
  // Each cut takes it to no less than CUT of it.
  for (let t = 1; t < rates.length; t++) assert.ok(rates[t]! >= rates[t - 1]! * CUT - 1, `at ${t}: ${rates[t - 1]} to ${rates[t]}`);
  // The link wide again: up by UP each UP_EVERY_MS once nothing queued for UP_AFTER_MS, to its own.
  assert.equal(rates.at(-1), own);
  const rising = rates.slice(4000).findIndex((r, i, a) => i > 0 && r > a[i - 1]!);
  assert.ok(rising >= 0 && rising <= UP_AFTER_MS + 2 * UP_EVERY_MS, `up again after ${rising} ms`);
});

test("lowered, the rate climbs back by UP, and by UP_FAST once nothing was held back for UP_FAST_AFTER_MS", () => {
  const top = rateCeiling(1920, 1080);
  // A link that carries 5 Mbit/s for 4 s, then 100.
  const rates = bottleneck((t) => (t < 4000 ? 5_000_000 : 100_000_000), 20_000, 10, null, top);
  const steps = rates.slice(4000).flatMap((r, i, a) => (i > 0 && r > a[i - 1]! ? [{ at: 4000 + i, by: r / a[i - 1]! }] : []));
  const by = (k: number) => (s: { by: number }) => Math.abs(s.by - k) < 1e-9;
  assert.ok(by(UP)(steps[0]!), `first by UP: ${JSON.stringify(steps)}`);
  const fast = steps.findIndex(by(UP_FAST));
  assert.ok(fast > 0 && steps.slice(fast, -1).every(by(UP_FAST)), `then by UP_FAST: ${JSON.stringify(steps)}`);
  // From about the link's 5 Mbit/s to 33 in under 5 s (by UP alone: 11 steps, 5.5 s).
  assert.ok(steps.at(-1)!.at - steps[0]!.at < 5000, `at the top soon: ${JSON.stringify(steps)}`);
  assert.equal(rates.at(-1), top);
});

test("a late acknowledgement alone lowers nothing: a still or idle screen's frames, held back by none", () => {
  let now = 0;
  const pacer = new Pacer(() => now);
  const own = ownRate(1920, 1080);
  pacer.ceiling(own);
  let ts = 1000;
  pacer.sent(ts, 10_000);
  now = 20;
  pacer.acked(ts);
  // A frame now and then (a sharper picture of a still screen, a cursor's blink), each large and a while on the way.
  for (let i = 0; i < 20; i++) {
    now += 1000;
    assert.equal(pacer.may(), true);
    pacer.sent((ts += 1000), 300_000);
    now += 400;
    pacer.acked(ts);
  }
  assert.equal(pacer.rate(), own);
  // A frame held a round trip (a packet lost and sent again) while the next waits: not slower either.
  pacer.sent((ts += 1000), 10_000);
  now += pacer.rtt()! + queueMs(pacer.rtt()!) + 1;
  assert.equal(pacer.may(), false);
  pacer.acked(ts);
  assert.equal(pacer.rate(), own);
});

test("a view starting at START_RATE goes up by START_UP a step until a queue first builds, then by UP", () => {
  let now = 0;
  const pacer = new Pacer(() => now, START_RATE);
  pacer.ceiling(ownRate(1920, 1080));
  assert.equal(pacer.rate(), START_RATE);
  let ts = 0;
  const frame = (trip: number) => {
    ts += 1000;
    pacer.sent(ts, 10_000);
    now += trip;
    pacer.acked(ts);
  };
  frame(20);
  assert.equal(pacer.rate(), START_RATE * START_UP, "the first round trip: up at once");
  now += UP_EVERY_MS;
  frame(20);
  assert.equal(pacer.rate(), Math.min(ownRate(1920, 1080), START_RATE * START_UP * START_UP));
  // Smaller than the own: as the picture's size has it.
  const small = new Pacer(() => now, START_RATE);
  small.ceiling(ownRate(640, 360));
  assert.equal(small.rate(), 1_000_000);
});

test("a picture's size sets the most it is asked; none before it is known", () => {
  const p = paced();
  assert.equal(p.pacer.rate(), null);
  p.pacer.ceiling(ownRate(1280, 720));
  assert.equal(p.pacer.rate(), Math.max(1_000_000, 1280 * 720 * 3));
  p.pacer.ceiling(ownRate(640, 360));
  assert.equal(p.pacer.rate(), 1_000_000);
});

test("the picture made smaller while the link carries a quarter of its own rate and the source uses it; back once the smaller one's own goes through", () => {
  let now = 0;
  const sizer = new Sizer(() => now, { maxWidth: 1920, maxHeight: 1080 });
  const big = { width: 1920, height: 1080 }, small = { width: 1280, height: 720 };
  const low = ownRate(1920, 1080) * DOWNSIZE_SHARE - 1;
  // Low, but the screen changes little (a tenth of it used): not made smaller.
  for (; now <= DOWNSIZE_MS * 2; now += 100) assert.equal(sizer.step(low, low / 10, big), null);
  // Low and used: smaller once it stays so for DOWNSIZE_MS.
  let asked = null;
  for (const start = now; now <= start + DOWNSIZE_MS && asked === null; now += 100) asked = sizer.step(low, low, big);
  assert.deepEqual(asked, LOW_BOUNDS);
  assert.equal(sizer.low, true);
  // The small one's own goes through for UPSIZE_MS: its own size again.
  asked = null;
  for (const start = now; now <= start + UPSIZE_MS + 100 && asked === null; now += 100) asked = sizer.step(ownRate(1280, 720), ownRate(1280, 720), small);
  assert.deepEqual(asked, { maxWidth: 1920, maxHeight: 1080 });
  // 原画 and 2K are never made smaller.
  for (const quality of ["original", "qhd"] as const) {
    const whole = new Sizer(() => now, { maxWidth: 7680, maxHeight: 4320 }, quality);
    for (let i = 0; i < 100; i++, now += 100) assert.equal(whole.step(low, low, big), null, quality);
  }
  // 高清 is, as 自动 is.
  const hd = new Sizer(() => now, { maxWidth: 7680, maxHeight: 4320 }, "hd");
  let made: unknown = null;
  for (let i = 0; i < 100 && made === null; i++, now += 100) made = hd.step(low, low, big);
  assert.deepEqual(made, { maxWidth: 1280, maxHeight: 720 });
  // A view asked no larger than the small bounds is never made smaller.
  const phone = new Sizer(() => now, { maxWidth: 1280, maxHeight: 720 });
  for (let i = 0; i < 100; i++, now += 100) assert.equal(phone.step(MIN_RATE, MIN_RATE, small), null);
});

test("frame latency: capture to drawn (the acknowledgement less half the round trip) and capture to sent, as medians, once a second", () => {
  let now = 10_000;
  const latency = new FrameLatency(() => now);
  // Captured at 9 990 ms, sent at 10 000 ms, acknowledged at 10 060 with a 40 ms round trip: drawn at about 10 040.
  latency.sent(9_990_000);
  now = 10_060;
  latency.acked(9_990_000, 40);
  assert.deepEqual(latency.take(), { frame: 50, before: 10 });
  // Said once a second at most.
  latency.sent(10_050_000);
  now = 10_100;
  latency.acked(10_050_000, 40);
  assert.equal(latency.take(), null);
  now = 11_100;
  assert.deepEqual(latency.take(), { frame: 50, before: 10 }, "the median of the two");
  // A timestamp not on this clock (10 s off) is not counted.
  latency.sent(1_000);
  now = 12_200;
  latency.acked(1_000, 40);
  assert.equal(latency.take(), null);
});

test("the most a view is asked at: × 16 a pixel (自动, 高清), × 20 (2K, 原画), 流畅 × 6, more over 60 frames a second, at most MAX_RATE", () => {
  assert.equal(MAX_RATE, 100_000_000);
  assert.equal(rateCeiling(1920, 1080), 1920 * 1080 * 16);
  assert.equal(rateCeiling(1920, 1080, "hd"), 1920 * 1080 * 16);
  assert.equal(rateCeiling(1920, 1080, "original"), 1920 * 1080 * 20);
  assert.equal(rateCeiling(1920, 1080, "smooth"), 1920 * 1080 * 6);
  assert.equal(rateCeiling(2560, 1440, "qhd"), 73_728_000, "2K at 60: 73.7 Mbit/s");
  assert.equal(rateCeiling(2560, 1440, "qhd", 60), 73_728_000);
  assert.equal(rateCeiling(2560, 1440, "qhd", 30), 73_728_000, "fewer frames, the same");
  assert.equal(rateCeiling(1920, 1080, "hd", 90), 1920 * 1080 * 16 * 1.25);
  assert.equal(rateCeiling(1920, 1080, "hd", 120), 1920 * 1080 * 16 * 1.5);
  assert.equal(rateCeiling(2560, 1440, "qhd", 90), 92_160_000);
  assert.equal(rateCeiling(2560, 1440, "qhd", 120), MAX_RATE, "2K at 120: 110.6, at most MAX_RATE");
  assert.equal(rateCeiling(3840, 2160), MAX_RATE);
  assert.equal(rateCeiling(3840, 2160, "smooth"), 3840 * 2160 * 6);
  assert.equal(rateCeiling(3840, 2160, "original"), MAX_RATE);
  // A small picture's own (at least 1 Mbit/s) is never lowered.
  assert.equal(rateCeiling(200, 100, "original"), 1_000_000);
  assert.equal(rateCeiling(200, 100, "original", 120), 1_000_000);
});

/// A pacer whose round trip is known (10 ms), its rate at `rate` and no higher, frames of `bytes` sent each 16 ms and
/// acknowledged 10 ms on for a second and a half: then one of `key` bytes, as a key frame or not, never acknowledged.
/// Its rate each ms after that one went.
function burst(rate: number, bytes: number, key: number, keyed = true) {
  let now = 0;
  const pacer = new Pacer(() => now, rate);
  pacer.ceiling(rate);
  let ts = 0;
  const due: { at: number; ts: number }[] = [];
  for (; now < 1500; now++) {
    while (due.length > 0 && due[0]!.at <= now) pacer.acked(due.shift()!.ts);
    if (now % 16 === 0 && pacer.may()) {
      ts += 1000;
      pacer.sent(ts, bytes);
      due.push({ at: now + 10, ts });
    }
  }
  for (; due.length > 0; now++) pacer.acked(due.shift()!.ts);
  pacer.sent(ts + 1000, key, keyed);
  const rates: number[] = [];
  for (const start = now; now < start + 1000; now++) {
    pacer.may();
    rates.push(pacer.rate()!);
  }
  return { rates, pacer, at: () => now, set: (ms: number) => void (now = ms) };
}

test("one large picture after a dark or still scene (little went through) lowers the rate by LIGHT_CUT first, not to what went through; held on, by it", () => {
  assert.equal(CUT, 0.65);
  assert.equal(LIGHT_CUT, 0.8);
  // 3 kB a frame at 60 a second (1.4 Mbit/s) of 20: a dark scene, then a scene cut held back.
  const dark = burst(20_000_000, 3_000, 1_000_000);
  const steps = [...new Set(dark.rates)];
  // Held for the round trip, the queue and a key frame's more (65 ms), then HOLD_MS: LIGHT_CUT of it, not 50% or what
  // went through (1.4 × DOWN).
  assert.equal(steps[0], 20_000_000);
  assert.equal(steps[1], 20_000_000 * LIGHT_CUT);
  const first = dark.rates.indexOf(steps[1]!);
  assert.equal(first, 10 + QUEUE_MS + KEY_QUEUE_MS + 1 + HOLD_MS, `the first lowering at ${first} ms`);
  // Held still a round trip and HOLD_MS on: the link is too slow, down by CUT (what went through is less).
  assert.equal(steps[2], 20_000_000 * LIGHT_CUT * CUT);
  assert.equal(dark.rates.indexOf(steps[2]!) - first, 10 + HOLD_MS);
  // A link that carried as much as it went at (what went through USED of the rate or more): down to it, as before.
  const full = burst(20_000_000, Math.round(20_000_000 / 60 / 8), 1_000_000);
  const fullSteps = [...new Set(full.rates)];
  assert.ok(full.pacer.through() >= 20_000_000 * USED * 0.5, `through ${full.pacer.through()}`);
  assert.ok(Math.abs(fullSteps[1]! - Math.max(20_000_000 * CUT, 20_000_000 * DOWN)) < 20_000_000 * 0.05, `down to about what went through: ${fullSteps[1]}`);
});

test("a key frame on the way may wait KEY_QUEUE_MS more before a queue is taken to build", () => {
  const p = paced();
  p.send(1);
  p.at(20);
  p.pacer.acked(1000);
  assert.equal(p.pacer.rtt(), 20);
  // A key frame and a moving one after it.
  p.pacer.sent(2000, 500_000, true);
  p.pacer.sent(3000, 10_000);
  p.at(20 + 20 + QUEUE_MS + KEY_QUEUE_MS);
  assert.equal(p.pacer.backlogged(), false);
  assert.equal(p.pacer.free(), true);
  assert.equal(p.pacer.may(), true);
  p.at(20 + 20 + QUEUE_MS + KEY_QUEUE_MS + 1);
  assert.equal(p.pacer.backlogged(), true);
  assert.equal(p.pacer.free(), false);
  assert.equal(p.pacer.may(), false);
  // Its acknowledgement late by as much lowers nothing, nor holds anything up.
  const rate = p.pacer.rate();
  p.pacer.acked(3000);
  assert.equal(p.pacer.rate(), rate);
  assert.equal(p.pacer.may(), true);
  // No key frame: QUEUE_MS alone.
  p.pacer.sent(4000, 10_000);
  p.pacer.sent(5000, 10_000);
  const at = 20 + 20 + QUEUE_MS + KEY_QUEUE_MS + 1;
  p.at(at + 20 + QUEUE_MS + 1);
  assert.equal(p.pacer.backlogged(), true);
});

test("free says what may says, and holds nothing back", () => {
  const b = burst(20_000_000, 3_000, 1_000_000);
  const rate = b.pacer.rate();
  b.set(b.at() + 5_000);
  for (let i = 0; i < 50; i++) assert.equal(b.pacer.free(), false);
  assert.equal(b.pacer.rate(), rate, "free asked again and again lowers nothing");
});

/// Frames offered every `every` ms (each acknowledged `trip` ms after it went) for `ms`, to a pacer asked `fps`: when
/// each went.
function capped(fps: number | undefined, every: number, ms: number, trip = 5): number[] {
  let now = 0;
  const pacer = new Pacer(() => now, null, fps);
  const due: { at: number; ts: number }[] = [];
  const went: number[] = [];
  let ts = 0;
  for (let t = 0; t < ms; t += 0.25) {
    now = t;
    while (due.length > 0 && due[0]!.at <= t) pacer.acked(due.shift()!.ts);
    if (t % every < 0.25 && pacer.may() && pacer.wait() === 0) {
      pacer.sent((ts += 1000), 10_000);
      went.push(t);
      due.push({ at: t + trip, ts });
    }
  }
  return went;
}

test("a 帧率 asked: no second carries more frames than it (and one), and a source at that rate keeps it", () => {
  for (const fps of FPS_CHOICES) {
    // A source faster than any asked (a 240 Hz display's).
    const went = capped(fps, 1000 / 240, 5000);
    for (let i = 0; i < went.length; i++) {
      const within = went.slice(i).filter((t) => t < went[i]! + 1000).length;
      assert.ok(within <= fps + 1, `${fps}: ${within} in the second from ${went[i]}`);
    }
    assert.ok(went.length >= fps * 5 * 0.95, `${fps}: ${went.length} in 5 s`);
  }
  // A source at the rate asked (still.fail Helper's capture asked it, its frames a little early or late): all of them.
  assert.ok(capped(60, 1000 / 60, 2000).length >= 119);
  // None asked (自动): as many as come.
  assert.equal(new Pacer(() => 0).wait(), 0);
  assert.ok(capped(undefined, 1000 / 240, 1000).length >= 239);
});

test("the station's loop standing still is left out of round trips and waits: frames held by it lower nothing", () => {
  // Frames each 16 ms over a near link (acknowledged 30 ms after they went), the station's loop standing still 128 ms
  // every 640 ms (nothing read meanwhile; then the pump asks before the acknowledgements are read): told, the rate stays
  // its own; not told, it is taken for the link.
  const run = (told: boolean) => {
    let now = 0;
    let stood = 0;
    const pacer = new Pacer(() => now, null, undefined, told ? () => stood : () => 0);
    pacer.ceiling(ownRate(1920, 1080));
    const due: { at: number; ts: number }[] = [];
    let ts = 0;
    for (let t = 0; t < 20_000; t++) {
      now = t;
      if (t % 640 >= 512) continue;
      if (t % 640 === 0 && t > 0) stood += 128;
      if (t % 16 === 0 && pacer.may()) {
        ts += 1000;
        pacer.sent(ts, 2_000);
        due.push({ at: t + 30, ts });
      }
      while (due.length > 0 && due[0]!.at <= t) pacer.acked(due.shift()!.ts);
    }
    return pacer.rate()!;
  };
  assert.equal(run(true), ownRate(1920, 1080));
  assert.ok(run(false) < ownRate(1920, 1080) / 2, `not told, taken for the link: ${run(false)}`);
});

test("LoopStall counts how long the loop stood still past its tick, the stand it is in now too", () => {
  let now = 0;
  const stall = new LoopStall(() => now);
  const used = stall.use();
  assert.equal(used.stalled(), 0);
  now = 100;
  assert.equal(used.stalled(), 90);
  used.done();
});

test("the rate a view starts at by its link as it opens: a near direct way higher, a near relay a little, else START_RATE", () => {
  assert.equal(UP, 1.2);
  assert.equal(startRate(), START_RATE);
  assert.equal(startRate([]), START_RATE);
  const direct = (rttMs: number | null, o = {}) => ({ selected: true, relay: null, ip: "192.168.1.5:7000", rttMs, ...o });
  const relay = (rttMs: number | null, o = {}) => ({ selected: true, relay: "https://r1/", ip: null, rttMs, ...o });
  assert.equal(LAN_RATE, 25_000_000);
  assert.equal(NEAR_RATE, 12_000_000);
  assert.equal(startRate([direct(3)]), 25_000_000, "a LAN: 2K sharp at once");
  assert.equal(startRate([direct(12)]), 25_000_000);
  assert.equal(startRate([direct(30)]), 12_000_000, "a near direct way");
  assert.equal(startRate([direct(40)]), 12_000_000);
  assert.equal(startRate([direct(80)]), 4_000_000, "a far direct way");
  assert.equal(startRate([direct(null)]), 4_000_000, "a direct way not measured yet");
  assert.equal(startRate([direct(0)]), 4_000_000, "a round trip of nothing is none");
  assert.equal(startRate([direct(250)]), START_RATE, "across the world");
  assert.equal(startRate([relay(20)]), 4_000_000, "a near relay");
  assert.equal(startRate([relay(35)]), 4_000_000);
  assert.equal(startRate([relay(36)]), START_RATE, "a far relay");
  assert.equal(startRate([relay(null)]), START_RATE);
  assert.equal(startRate([direct(5, { ip: "" })]), 4_000_000, "no address: taken as a relay of that round trip");
  assert.equal(startRate([direct(50, { ip: "" })]), START_RATE);
  // the selected way, else the first direct one, else the first
  assert.equal(startRate([direct(5, { selected: false }), relay(200)]), START_RATE);
  assert.equal(startRate([relay(200, { selected: false }), direct(30, { selected: false })]), 12_000_000);
  assert.equal(startRate([relay(20, { selected: false }), relay(200, { selected: false })]), 4_000_000);
});

test("a still screen's picture sharper after STILL_MS; a moving one's key frame asked again once the rate doubled its key frame's", () => {
  assert.equal(STILL_MS, 250);
  const s = new Sharpener();
  s.sent(0, 1_500_000, true);
  assert.equal(s.left(100), UP_EVERY_MS - 100, "after a key frame (a step of sharpening): no sooner than the pace steps up");
  s.sent(0, 1_500_000);
  assert.equal(s.left(100), 150);
  assert.equal(s.due(200, 3_000_000), false, "not still yet");
  assert.equal(s.due(250, 3_000_000), true, "still for STILL_MS, the rate up");
  assert.equal(s.due(250, 1_600_000), false, "up by no more than SHARPER");
  // moving: a frame each 16 ms, none a key frame
  let now = 0;
  const moving = (rate: number) => {
    now += 16;
    s.sent(now, rate);
    return s.dueMoving(now, rate);
  };
  assert.equal(moving(2_900_000), false, "under MOVING_SHARPEN_UP");
  while (now < MOVING_SHARPEN_MS - 16) assert.equal(moving(3_000_000), false, `not before MOVING_SHARPEN_MS (${now})`);
  assert.equal(moving(3_000_000), true, "MOVING_SHARPEN_MS since the key frame, the rate doubled");
  assert.equal(moving(3_000_000), false, "asked once: not again for the frames before it comes");
  assert.equal(moving(6_000_000), false, "not again before MOVING_SHARPEN_MS more");
  now += MOVING_SHARPEN_MS;
  assert.equal(s.dueMoving(now, 6_000_000), true);
  // a key frame that came resets it
  s.sent(now + 1, 6_000_000, true);
  assert.equal(s.dueMoving(now + 1 + MOVING_SHARPEN_MS, 6_000_000 * MOVING_SHARPEN_UP - 1), false);
  assert.equal(s.dueMoving(now + 1 + MOVING_SHARPEN_MS, 6_000_000 * MOVING_SHARPEN_UP), true);
  // a source with no rate of its own (JPEG): never
  const jpeg = new Sharpener();
  jpeg.sent(0, null, true);
  assert.equal(jpeg.dueMoving(10_000, 9_000_000), false);
  assert.equal(jpeg.due(10_000, 9_000_000), false);
});

test("viewerWaitMs decouples client jitter hold from network congestion, caps at 100ms, rejects bogus waits, and decays after RTT_WINDOW_MS", () => {
  // 1. Legitimate client jitter hold (0..100ms) does not inflate net RTT or lower bitrate.
  let now = 0;
  const pacer = new Pacer(() => now);
  const own = ownRate(1920, 1080);
  pacer.ceiling(own);
  const due: { at: number; ts: number; wait: number }[] = [];
  let ts = 0;
  for (let t = 0; t < 4000; t++) {
    now = t;
    while (due.length > 0 && due[0]!.at <= t) {
      const d = due.shift()!;
      pacer.acked(d.ts, d.wait);
    }
    if (t % 16 === 0 && pacer.may()) {
      ts += 1000;
      pacer.sent(ts, 12_000);
      // 10ms pure network RTT + 70ms client jitter hold (<= VIEWER_HOLD_LIMIT_MS)
      const hold = t >= 200 ? 70 : 0;
      due.push({ at: t + 10 + hold, ts, wait: hold });
    }
  }
  assert.equal(pacer.rtt(), 10, "net RTT stays at pure network RTT");
  assert.equal(pacer.viewerWait(), 70);
  assert.equal(pacer.rate(), own, "legitimate viewer hold must not cut bitrate");

  // 2. Client hold > VIEWER_HOLD_LIMIT_MS (100ms) is capped so a stalled client still pauses may() and triggers backlogged().
  let now2 = 0;
  const cappedPacer = new Pacer(() => now2);
  cappedPacer.ceiling(own);
  cappedPacer.sent(1000, 10_000);
  now2 = 160;
  cappedPacer.acked(1000, 150); // totalTrip=160, wait=150 -> netTrip=10, viewerWait capped at 100
  assert.equal(cappedPacer.rtt(), 10);
  assert.equal(cappedPacer.viewerWait(), VIEWER_HOLD_LIMIT_MS);
  cappedPacer.sent(2000, 10_000);
  cappedPacer.sent(3000, 10_000);
  now2 = 160 + 10 + VIEWER_HOLD_LIMIT_MS + queueMs(10);
  assert.equal(cappedPacer.may(), true);
  assert.equal(cappedPacer.backlogged(), false);
  now2 += 1;
  assert.equal(cappedPacer.may(), false, "wait past rtt + VIEWER_HOLD_LIMIT_MS + queueMs pauses sending");
  assert.equal(cappedPacer.backlogged(), true);

  // 3. Untrusted viewerWaitMs (> totalTrip, negative, NaN, Infinity) is treated as 0.
  let now3 = 0;
  const untrusted = new Pacer(() => now3);
  for (const bogus of [50, -10, Number.NaN, Number.POSITIVE_INFINITY]) {
    untrusted.sent((ts += 1000), 10_000);
    now3 += 20;
    untrusted.acked(ts, bogus);
    assert.equal(untrusted.viewerWait(), 0, `bogus wait ${bogus} ignored`);
    assert.equal(untrusted.rtt(), 20);
  }

  // 4. Real network congestion while holding still lowers bitrate.
  let now4 = 0;
  const congested = new Pacer(() => now4);
  congested.ceiling(own);
  const due4: { at: number; ts: number; wait: number }[] = [];
  let ts4 = 0;
  for (let t = 0; t < 4000; t++) {
    now4 = t;
    while (due4.length > 0 && due4[0]!.at <= t) {
      const d = due4.shift()!;
      congested.acked(d.ts, d.wait);
    }
    if (t % 16 === 0 && congested.may()) {
      ts4 += 1000;
      congested.sent(ts4, 15_000);
      // After 200ms, network trip grows from 10ms to 180ms while client also holds 50ms.
      const net = t >= 200 ? 180 : 10;
      const hold = 50;
      due4.push({ at: t + net + hold, ts: ts4, wait: hold });
    }
  }
  assert.ok(congested.rate()! < own, `real network congestion must still cut bitrate (got ${congested.rate()})`);

  // 5. Returning to a clean link (wait=0) decays viewerWait() back to 0 after RTT_WINDOW_MS.
  let now5 = 0;
  const clean = new Pacer(() => now5);
  clean.sent(1000, 10_000);
  now5 = 70;
  clean.acked(1000, 60);
  assert.equal(clean.viewerWait(), 60);
  clean.sent(2000, 10_000);
  now5 = 70 + RTT_WINDOW_MS + 1;
  clean.acked(2000, 0);
  assert.equal(clean.viewerWait(), 0, "viewerWait returns to 0 once prior holds age out of RTT_WINDOW_MS");
});
