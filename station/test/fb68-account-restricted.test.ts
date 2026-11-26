// FB-68: an account restricted by its provider (e.g. Anthropic Verification Portal) keeps answering 200 OK on
// `/v1/models` and `/api/oauth/usage` with 0% utilization. A turn hitting that error must immediately mark the profile
// blocked across background quota rounds, propagate to the host (and other borrowers), notify workspace managers once,
// fail over to a healthy profile without retrying on the restricted one, and never be re-selected by repick or new chats.
// As defense-in-depth, repick after a failed turn also moves off the failing profile when another healthy one exists.
import assert from "node:assert/strict";
import { test } from "node:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { Accounts, type AccountsDeps, type LoginLost } from "../src/accounts/index.ts";
import { checkConfig } from "../src/accounts/check.ts";
import type { ProfileCheck, ProfileQuota } from "../src/accounts/profiles.ts";
import { blocked as quotaBlocked } from "../src/accounts/quota.ts";
import { Notifier, ProfileLoginCooldown } from "../src/cloud/notify.ts";
import { Cloud } from "../src/cloud/state.ts";
import { ConfigFile } from "../src/ops/config.ts";
import { setStationLang } from "../src/ops/i18n.ts";
import { Store } from "../src/store/store.ts";
import { temp } from "./accounts-fakes.ts";
import { Rig, message, settle, testClock } from "./hub-fakes.ts";

const RESTRICTED_MSG =
  "API Error: Your account can't receive replies from Claude right now. You can find the next step in the Anthropic Verification Portal";

const okQuota = (at: number, usedPercent = 0): ProfileQuota => ({
  state: "ok",
  windows: [{ label: "5 小时", usedPercent, resetsAt: null }],
  detail: null,
  checkedAt: at,
});

function accountsRig(o: {
  data?: string;
  store?: Store;
  profiles: unknown[];
  check?: AccountsDeps["check"];
  quota?: AccountsDeps["quota"];
  shared?: AccountsDeps["shared"];
}) {
  const data = o.data ?? temp("fb68");
  writeFileSync(join(data, "config.json"), JSON.stringify({ profiles: o.profiles, connects: [] }));
  const config = new ConfigFile(data);
  config.check = checkConfig;
  const lost: LoginLost[] = [];
  const back: string[] = [];
  let recheck: ((id: string, force?: boolean, reason?: string) => Promise<unknown>) | undefined;
  const store = o.store ?? Store.open(":memory:", null);
  const accounts = new Accounts({
    data,
    store,
    config,
    machine: null,
    checkOnStart: false,
    check: o.check ?? (async () => ({ state: "ok", detail: "fake", models: [], checkedAt: 0 })),
    quota: o.quota ?? (async () => okQuota(0)),
    resetQuota: null,
    discover: async () => ({ state: "unsupported", detail: "", model: null, provider: null, models: [], fingerprint: "" }) as any,
    hub: { accounts: { setHealth: () => {}, healthOf: () => ({}), setRecheck: (f) => { recheck = f; } } },
    shared: o.shared,
    loginLost: (l) => lost.push(l),
    loginBack: (id) => back.push(id),
  });
  accounts.start();
  return {
    data,
    store,
    accounts,
    lost,
    back,
    recheck: (id: string, force = false, reason?: string) => recheck!(id, force, reason),
    close: () => accounts.close(),
  };
}

const lent = (id: string) => ({
  id,
  name: id,
  runtime: "claude",
  home: `homes/${id}`,
  access: { kind: "subscription" },
  share: { borrowed: true, host: "host-a", id: `share-${id}` },
});

test("FB-68: quota.blocked recognizes Anthropic Verification Portal refusal wording", () => {
  assert.equal(quotaBlocked(RESTRICTED_MSG), true);
  assert.equal(quotaBlocked("Your account cannot receive replies right now"), true);
});

test("FB-68: a local restricted subscription stays blocked across background quota rounds, persists, and recovers on explicit check/quota", async () => {
  const statusPushed: string[] = [];
  const data = temp("fb68-local");
  const dbPath = join(data, "stillfail.db");
  const store1 = Store.open(dbPath, null);
  const r = accountsRig({
    data,
    store: store1,
    profiles: [{ id: "diana", name: "diana@garvi.art", runtime: "claude", home: "homes/diana", access: { kind: "subscription" } }],
    shared: { status: async () => ({ check: null, quota: null }), view: () => null, statusUpdated: (id) => statusPushed.push(id) },
  });
  try {
    await r.accounts.check("diana");
    await r.accounts.refreshQuota("diana");
    assert.equal(r.accounts.health("diana").quota?.state, "ok");

    await r.recheck("diana", false, RESTRICTED_MSG);
    assert.equal(r.accounts.health("diana").quota?.state, "blocked");
    assert.equal(r.accounts.health("diana").quota?.restricted, true);
    assert.equal(r.lost.length, 1);
    assert.equal(r.lost[0]!.restricted, true);
    assert.equal(r.lost[0]!.station, null);
    assert.deepEqual(statusPushed, ["diana"]);

    // Background quota refresh and check must NOT resurrect the restricted account even though `/api/oauth/usage` answers ok.
    await r.accounts.refreshQuota("diana");
    await r.accounts.check("diana");
    assert.equal(r.accounts.health("diana").quota?.state, "blocked");
    assert.equal(r.lost.length, 1, "managers are not spammed on repeat checks");

    // Repeated restriction reports stay idempotent.
    await r.recheck("diana", false, RESTRICTED_MSG);
    assert.equal(r.lost.length, 1);
    assert.deepEqual(statusPushed, ["diana"]);
  } finally {
    await r.close();
  }

  // Persists across station restart.
  const store2 = Store.open(dbPath, null);
  const r2 = accountsRig({
    data,
    store: store2,
    profiles: [{ id: "diana", name: "diana@garvi.art", runtime: "claude", home: "homes/diana", access: { kind: "subscription" } }],
    shared: { status: async () => ({ check: null, quota: null }), view: () => null, statusUpdated: (id) => statusPushed.push(id) },
  });
  try {
    assert.equal(r2.accounts.health("diana").quota?.state, "blocked");
    assert.equal(r2.accounts.health("diana").quota?.restricted, true);
    await r2.accounts.refreshQuota("diana");
    assert.equal(r2.accounts.health("diana").quota?.state, "blocked", "still blocked after restart + routine quota round");

    // Explicit user quota refresh after verifying in the portal clears the restriction and notifies borrowers.
    await r2.accounts.askedQuota("diana");
    assert.equal(r2.accounts.health("diana").quota?.state, "ok");
    assert.equal(r2.back.includes("diana"), true);
    assert.deepEqual(statusPushed, ["diana", "diana"]);
  } finally {
    await r2.close();
  }
});

test("FB-68: a borrowed profile reports restriction to its upgraded host, propagates to other borrowers, and avoids duplicate alerts", async () => {
  const hostPushed: string[] = [];
  const host = accountsRig({
    profiles: [{ id: "diana", name: "diana@garvi.art", runtime: "claude", home: "homes/diana", access: { kind: "subscription" } }],
    shared: { status: async () => ({ check: null, quota: null }), view: () => null, statusUpdated: (id) => hostPushed.push(id) },
  });
  const borrowerA = accountsRig({
    profiles: [lent("sh-diana")],
    shared: {
      status: async (_p, recheck, restricted) => {
        const h = await host.accounts.lentHealth("diana", recheck === true, restricted);
        return { check: h.check ?? null, quota: h.quota ?? null };
      },
      view: () => null,
      hostName: () => "AFK-东京服务器",
    },
  });
  const borrowerB = accountsRig({
    profiles: [lent("sh-diana")],
    shared: {
      status: async (_p, recheck, restricted) => {
        const h = await host.accounts.lentHealth("diana", recheck === true, restricted);
        return { check: h.check ?? null, quota: h.quota ?? null };
      },
      view: () => null,
      hostName: () => "AFK-东京服务器",
    },
  });
  try {
    await host.accounts.check("diana");
    await host.accounts.refreshQuota("diana");
    await borrowerA.accounts.check("sh-diana");
    await borrowerB.accounts.check("sh-diana");
    assert.equal(borrowerA.accounts.health("sh-diana").quota?.state, "ok");
    assert.equal(borrowerB.accounts.health("sh-diana").quota?.state, "ok");

    // Borrower A hits the Anthropic Verification Portal error -> host blocks it and alerts managers once.
    await borrowerA.recheck("sh-diana", false, RESTRICTED_MSG);
    assert.equal(host.accounts.health("diana").quota?.state, "blocked");
    assert.equal(borrowerA.accounts.health("sh-diana").quota?.state, "blocked");
    assert.equal(host.lost.length, 1);
    assert.equal(host.lost[0]!.restricted, true);
    assert.equal(borrowerA.lost.length, 0, "upgraded host already notified its workspace managers");
    assert.deepEqual(hostPushed, ["diana"], "host triggers share version bump for other borrowers");

    // Borrower B receives the share.changed update and immediately blocks the account too.
    await borrowerB.accounts.sharedChanged("sh-diana", false);
    assert.equal(borrowerB.accounts.health("sh-diana").quota?.state, "blocked");

    // Clicking refresh on a borrower while host is still blocked cannot bypass the host-side block.
    await borrowerA.accounts.askedQuota("sh-diana");
    assert.equal(borrowerA.accounts.health("sh-diana").quota?.state, "blocked");

    // Admin verifies in portal and clicks Check on host -> host recovers and pushes to borrowers.
    await host.accounts.askedCheck("diana");
    assert.equal(host.accounts.health("diana").quota?.state, "ok");
    assert.deepEqual(hostPushed, ["diana", "diana"]);
    await borrowerA.accounts.sharedChanged("sh-diana", false);
    await borrowerB.accounts.sharedChanged("sh-diana", false);
    assert.equal(borrowerA.accounts.health("sh-diana").quota?.state, "ok");
    assert.equal(borrowerB.accounts.health("sh-diana").quota?.state, "ok");
  } finally {
    await borrowerA.close();
    await borrowerB.close();
    await host.close();
  }
});

test("FB-68: against an older host that keeps answering ok with newer quota timestamps, a restricted borrowed profile stays blocked", async () => {
  let quotaAt = 1000;
  const r = accountsRig({
    profiles: [lent("sh-old")],
    shared: {
      // Simulates an older host ignoring `restricted` and advancing quota.checkedAt every round.
      status: async () => ({ check: { state: "ok", detail: "ok", models: null, checkedAt: quotaAt } as ProfileCheck, quota: okQuota(quotaAt) }),
      view: () => null,
      hostName: () => "AFK-东京服务器",
    },
  });
  try {
    await r.accounts.check("sh-old");
    assert.equal(r.accounts.health("sh-old").quota?.state, "ok");
    await r.recheck("sh-old", false, RESTRICTED_MSG);
    assert.equal(r.accounts.health("sh-old").quota?.state, "blocked");
    assert.equal(r.lost.length, 1, "borrower notifies managers when older host did not block it");
    assert.equal(r.lost[0]!.restricted, true);
    assert.equal(r.lost[0]!.station, "AFK-东京服务器");

    // Subsequent background rounds with newer host timestamps must NOT undo the local restriction.
    quotaAt = 5000;
    await r.accounts.refreshQuota("sh-old");
    assert.equal(r.accounts.health("sh-old").quota?.state, "blocked");
    quotaAt = 9000;
    await r.accounts.check("sh-old", "zh", false, true);
    assert.equal(r.accounts.health("sh-old").quota?.state, "blocked");
  } finally {
    await r.close();
  }
});

test("FB-68: a restricted profile fails over immediately on first refusal and is skipped by new chats and repick", async () => {
  const time = testClock();
  const r = new Rig({ clock: time.clock });
  try {
    r.edit((raw) => {
      raw.profiles = raw.profiles.filter((p: any) => p.runtime !== "claude");
      raw.profiles.push(
        { id: "sh-restricted", runtime: "claude", home: "homes/sh-restricted", name: "diana@garvi.art" },
        { id: "healthy", runtime: "claude", home: "homes/healthy", name: "healthy" },
      );
    });
    const healths: Record<string, any> = {
      "sh-restricted": { check: { state: "ok", detail: "", models: null, checkedAt: 0 }, quota: okQuota(0, 0) },
      healthy: { check: { state: "ok", detail: "", models: null, checkedAt: 0 }, quota: okQuota(0, 60) },
    };
    r.hub.accounts.setHealth((id) => healths[id] ?? {});
    const seenReasons: (string | undefined)[] = [];
    r.hub.accounts.setRecheck(async (id, _force, reason) => {
      seenReasons.push(reason);
      if (id === "sh-restricted" && reason?.includes("Verification Portal")) {
        healths[id] = {
          ...healths[id],
          quota: { state: "blocked", windows: [], detail: "Account restricted", checkedAt: 1, restricted: true },
        };
      }
    });

    const m = message();
    await r.accept(m);
    await settle();
    const first = r.claude.last();
    const key = first.options.route;
    assert.equal(first.options.profile.id, "sh-restricted", "0% used profile is initially picked");

    first.end({ kind: "failed", reason: "auth", message: RESTRICTED_MSG });
    await settle();

    assert.equal(seenReasons.length, 1);
    assert.equal(seenReasons[0], RESTRICTED_MSG, "actor passes failure message to recheck");
    assert.equal(r.claude.count(), 2, "moves directly to healthy without retrying on the restricted profile");
    const recovered = r.claude.last();
    assert.equal(recovered.options.profile.id, "healthy");
    await r.call(key, "chat_post", { to: `C1/${m.threadTs}`, text: "done", kind: "all_done", done: "Recovered on healthy profile." });
    recovered.complete();
    await settle();
    assert.ok(!r.chat.texts().some((t) => t.includes("Verification Portal")), "error does not leak to the chat when failover succeeds");

    // repick and new chats stay away from the blocked profile.
    r.store.setSessionProfile(key, "sh-restricted", false, null);
    r.hub.accounts.repick(key);
    assert.equal(r.session(key).profile, "healthy");

    await r.accept(message());
    await settle();
    assert.equal(r.claude.last().options.profile.id, "healthy");
  } finally {
    await r.close();
  }
});

test("FB-68: repick moves off a profile whose last turn failed even with an unrecognized error and 0% usage", async () => {
  const time = testClock();
  const r = new Rig({ clock: time.clock });
  try {
    r.edit((raw) => {
      raw.profiles = raw.profiles.filter((p: any) => p.runtime !== "claude");
      raw.profiles.push(
        { id: "broken-0pct", runtime: "claude", home: "homes/broken-0pct", name: "broken-0pct" },
        { id: "healthy-60pct", runtime: "claude", home: "homes/healthy-60pct", name: "healthy-60pct" },
      );
    });
    r.hub.accounts.setHealth((id) => ({
      check: { state: "ok", detail: "", models: null, checkedAt: 0 },
      quota: okQuota(0, id === "broken-0pct" ? 0 : 60),
    }));

    const m = message();
    await r.accept(m);
    await settle();
    const first = r.claude.last();
    const key = first.options.route;
    assert.equal(first.options.profile.id, "broken-0pct");

    // Turn fails with an unrecognized model error, leaving broken-0pct looking healthy at 0% usage.
    first.end({ kind: "failed", reason: "model", message: "API Error: unknown per-account failure" });
    await settle();
    assert.equal(r.session(key).profile, "broken-0pct");

    // repick must move off broken-0pct to healthy-60pct instead of picking broken-0pct again.
    r.hub.accounts.repick(key);
    assert.equal(r.session(key).profile, "healthy-60pct");
  } finally {
    await r.close();
  }
});

test("FB-68: notifyProfileLogin formats restricted accounts with restricted alert wording", () => {
  const cloud: any = Object.assign(Object.create(Cloud.prototype), {
    state: {
      origin: "https://app.still.fail",
      station: "st1",
      workspace: "ws1",
      workspace_name: "WS1",
      name: "AFK-东京服务器",
      peers: [],
      revocations: [],
      joined: [],
    },
    lock: null,
  });
  const sent: any[] = [];
  const notifier = new Notifier(
    Store.open(":memory:", null),
    {} as any,
    cloud,
    async (notices) => { sent.push(...notices); },
  );
  try {
    setStationLang("zh");
    const cooldown = new ProfileLoginCooldown();
    const count = notifier.notifyProfileLogin(
      {
        workspaces: ["ws1"],
        profileId: "diana",
        profile: "diana@garvi.art",
        runtimeTitle: "Claude Code",
        stationName: "AFK-东京服务器",
        at: 1000,
        restricted: true,
      },
      cooldown,
    );
    assert.equal(count, 1);
    // Repeated restricted events for the same account within cooldown produce zero extra alerts.
    assert.equal(
      notifier.notifyProfileLogin(
        {
          workspaces: ["ws1"],
          profileId: "diana",
          profile: "diana@garvi.art",
          runtimeTitle: "Claude Code",
          stationName: "AFK-东京服务器",
          at: 2000,
          restricted: true,
        },
        cooldown,
      ),
      0,
    );
    const queued = (notifier as any).waiting[0];
    assert.equal(queued.audience, "managers");
    assert.match(queued.text, /已被服务商限制/);
    assert.match(queued.text, /diana@garvi\.art/);
  } finally {
    notifier.close();
  }
});
