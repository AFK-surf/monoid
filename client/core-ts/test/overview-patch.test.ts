// Incremental top-level `overview-patch` events: in-flight RETOLD replay over GET /overview, single fallback GET when
// no base overview is held, overlay preservation, and selective profilePace refreshes.
import assert from "node:assert/strict";
import { test } from "node:test";
import { count, subscribe } from "./helpers.ts";
import { run } from "./run.ts";
import { base, overview, started } from "./station-fixture.ts";

const ST = "ws/st";

test("in-flight overview-patch events replay in order over GET /overview via RETOLD", async () => {
  const answers = base();
  const initialOverview = {
    ...overview,
    counts: { sessions: 5, running: 0, warm: 5 },
    profiles: [{ id: "p1", name: "alpha" }],
    disk: { freeBytes: 50_000, totalBytes: 100_000 },
    processes: [{ pgid: 7, runtime: "claude", rssMb: 100 }],
    interrupted: { count: 1 },
  };
  answers["GET /overview"] = initialOverview;
  const s = await started(answers);
  try {
    // Hold the next GET /overview during a fresh snapshot and deliver two patches while it is in flight.
    const release = s.host.hold("/admin/api/overview");
    s.core.inner.stations.snapshot(ST);
    await s.host.settle();

    s.push(
      "overview-patch",
      {
        set: {
          counts: { sessions: 5, running: 2, warm: 3 },
          processes: [{ pgid: 7, runtime: "claude", rssMb: 180 }],
          interrupted: { count: 3 },
        },
      },
      "abcdef.10",
    );
    s.push(
      "overview-patch",
      {
        set: {
          counts: { sessions: 5, running: 1, warm: 4 },
          processes: [{ pgid: 7, runtime: "claude", rssMb: 240 }],
          disk: null,
        },
        del: ["interrupted"],
      },
      "abcdef.11",
    );
    await s.host.settle();

    release();
    await s.host.settle();
    await run(s.core.inner.data.written);

    const got = s.core.inner.data.get({ topic: "overview", station: ST }) as Record<string, unknown>;
    const expected = {
      ...initialOverview,
      counts: { sessions: 5, running: 1, warm: 4 },
      processes: [{ pgid: 7, runtime: "claude", rssMb: 240 }],
      disk: null,
    };
    delete (expected as Record<string, unknown>).interrupted;
    assert.deepEqual(got, expected);
    assert.equal(Object.prototype.hasOwnProperty.call(got, "interrupted"), false);
  } finally {
    s.core.close();
  }
});

test("receiving consecutive overview-patch events with no base overview triggers only one fallback GET /overview", async () => {
  const answers = base();
  const baseOv = {
    ...overview,
    counts: { sessions: 2, running: 0, warm: 2 },
    profiles: [{ id: "p1", name: "alpha" }],
  };
  answers["GET /overview"] = baseOv;
  const s = await started(answers);
  try {
    // Drop the stored overview so the client has no local baseline.
    s.core.inner.data.of(ST)!.dropStationDoc(ST, "overview", null);
    assert.equal(s.core.inner.data.get({ topic: "overview", station: ST }), undefined);

    const before = count(s.host, "/admin/api/overview");
    const release = s.host.hold("/admin/api/overview");

    // Push three consecutive patches before the fallback GET /overview resolves.
    s.push("overview-patch", { set: { counts: { sessions: 2, running: 1, warm: 1 } } }, "abcdef.20");
    await s.host.settle();
    s.push("overview-patch", { set: { counts: { sessions: 2, running: 2, warm: 0 } } }, "abcdef.21");
    await s.host.settle();
    s.push("overview-patch", { set: { counts: { sessions: 3, running: 1, warm: 2 } } }, "abcdef.22");
    await s.host.settle();

    assert.equal(count(s.host, "/admin/api/overview") - before, 1, "consecutive patches without baseline trigger only a single GET /overview");

    release();
    await s.host.settle();
    await run(s.core.inner.data.written);

    const got = s.core.inner.data.get({ topic: "overview", station: ST }) as Record<string, any>;
    assert.deepEqual(got.counts, { sessions: 3, running: 1, warm: 2 });
    assert.deepEqual(got.profiles, baseOv.profiles);
  } finally {
    s.core.close();
  }
});

test("overview-patch merges onto raw overview without baking optimistic model overlays into SQLite", async () => {
  const answers = base();
  answers["GET /overview"] = {
    ...overview,
    counts: { sessions: 1, running: 0, warm: 1 },
    profiles: [{ id: "p1", name: "alpha", named: ["m1"], models: ["m1"] }],
  };
  const s = await started(answers);
  try {
    assert.equal(s.core.inner.data.beginModels(ST, "p1", ["m1", "m2"]), true);
    s.push("overview-patch", { set: { counts: { sessions: 1, running: 1, warm: 0 } } }, "abcdef.25");
    await s.host.settle();
    await run(s.core.inner.data.written);

    // Persisted raw overview updated counts without persisting optimistic modelsSaving/m2 overlay.
    const raw = s.core.inner.data.get({ topic: "overview", station: ST }) as Record<string, any>;
    assert.deepEqual(raw.counts, { sessions: 1, running: 1, warm: 0 });
    assert.deepEqual(raw.profiles[0].named, ["m1"]);
    assert.equal(raw.profiles[0].modelsSaving, undefined);

    // Shown overview still renders the live optimistic overlay on top of the patched counts.
    const shown = s.core.inner.data.shared({ topic: "overview", station: ST }) as Record<string, any>;
    assert.deepEqual(shown.counts, { sessions: 1, running: 1, warm: 0 });
    assert.deepEqual(shown.profiles[0].named, ["m1", "m2"]);
    assert.deepEqual(shown.profiles[0].modelsSaving, ["m2"]);
  } finally {
    s.core.close();
  }
});

test("overview-patch refreshes profilePace only when profiles are touched", async () => {
  const answers = base();
  answers["GET /profiles/pace"] = { nowAt: 1000, profiles: {} };
  const s = await started(answers);
  try {
    subscribe(s.core, 1, 1, { topic: "profilePace", station: ST });
    await s.host.settle();
    const paceReqs = () => s.host.requests.filter((r) => r.method === "GET" && r.url.includes("/admin/api/profiles/pace")).length;
    const before = paceReqs();

    // Counts-only patch must not trigger a profilePace refresh.
    s.push("overview-patch", { set: { counts: { sessions: 1, running: 1, warm: 0 } } }, "abcdef.30");
    await s.host.settle();
    assert.equal(paceReqs(), before, "counts-only overview-patch does not re-read /profiles/pace");

    // Patch touching profiles refreshes profilePace.
    s.push("overview-patch", { set: { profiles: [{ id: "p2", name: "beta" }] } }, "abcdef.31");
    await s.host.settle();
    assert.equal(paceReqs(), before + 1, "profiles overview-patch refreshes /profiles/pace");

    s.core.receive(1, { kind: "unsubscribe", id: 1, unsubscribe: true });
  } finally {
    s.core.close();
  }
});
