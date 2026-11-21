// FB-44: a profile a runtime was refused on is rechecked and, its login over, kept signed out (`login`) until it signs
// in anew or an allowance read after says it works, a borrowed one's too where its host is from before and answers the
// `ok` it had; the managers are told once which profile to sign in again, never of one made and not signed in yet.
import assert from "node:assert/strict";
import { test } from "node:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { Accounts, type AccountsDeps, type LoginLost } from "../src/accounts/index.ts";
import { checkConfig } from "../src/accounts/check.ts";
import type { ProfileCheck, ProfileQuota } from "../src/accounts/profiles.ts";
import { ConfigFile } from "../src/ops/config.ts";
import { Store } from "../src/store/store.ts";
import { temp } from "./accounts-fakes.ts";
import { settle } from "./hub-fakes.ts";

const ok = (at: number): ProfileQuota => ({ state: "ok", windows: [{ label: "5 小时", usedPercent: 10, resetsAt: null }], detail: null, checkedAt: at });

function rig(o: { profiles: unknown[]; check?: AccountsDeps["check"]; quota?: AccountsDeps["quota"]; shared?: AccountsDeps["shared"] }) {
  const data = temp("fb44");
  writeFileSync(join(data, "config.json"), JSON.stringify({ profiles: o.profiles, connects: [] }));
  const config = new ConfigFile(data);
  config.check = checkConfig;
  const lost: LoginLost[] = [];
  const back: string[] = [];
  let recheck: ((id: string, force?: boolean) => Promise<unknown>) | undefined;
  const accounts = new Accounts({
    data,
    store: Store.open(":memory:", null),
    config,
    machine: null,
    checkOnStart: false,
    check: o.check ?? (async () => ({ state: "ok", detail: "fake", models: [], checkedAt: 0 })),
    quota: o.quota ?? null,
    resetQuota: null,
    discover: async () => ({ state: "unsupported", detail: "", model: null, provider: null, models: [], fingerprint: "" }) as any,
    hub: { accounts: { setHealth: () => {}, healthOf: () => ({}), setRecheck: (f) => { recheck = f; } } },
    shared: o.shared,
    loginLost: (l) => lost.push(l),
    loginBack: (id) => back.push(id),
  });
  accounts.start();
  return { accounts, lost, back, recheck: (id: string, force = false) => recheck!(id, force), close: () => accounts.close() };
}

const lent = (id: string) => ({ id, name: id, runtime: "claude", home: `homes/${id}`, access: { kind: "subscription" }, share: { borrowed: true, host: "host-a", id: `share-${id}` } });

test("FB-44: a borrowed profile whose host is from before stays signed out after a refusal until its host reads it again", async () => {
  // (a host of 0.1.10384: whatever it is asked, the check and allowance it had)
  let answer: { check: Partial<ProfileCheck>; quota: ProfileQuota } = { check: { state: "ok", detail: "", models: null, checkedAt: 1 }, quota: ok(1000) };
  const asked: boolean[] = [];
  const r = rig({
    profiles: [lent("sh-1")],
    shared: { status: async (_p, recheck) => { asked.push(recheck === true); return answer as any; }, view: () => null, hostName: () => "Host A" },
  });
  try {
    await r.accounts.check("sh-1");
    assert.equal(r.accounts.health("sh-1").check?.state, "ok");
    await r.recheck("sh-1");
    assert.equal(asked.at(-1), true, "its host asked to read it again");
    assert.equal(r.accounts.health("sh-1").check?.state, "login", "an answer of what it had is not taken for a reading");
    assert.equal(r.lost.length, 1, "the managers told once, the host from before not telling its own");
    assert.equal(r.lost[0]!.id, "sh-1");
    assert.equal(r.lost[0]!.station, "Host A");
    // The round's checks: the host still answers the `ok` it had.
    for (let i = 0; i < 3; i++) await r.accounts.check("sh-1");
    assert.equal(r.accounts.health("sh-1").check?.state, "login", "kept signed out through what an old host answers");
    assert.equal(r.lost.length, 1, "told no more");
    // Signed in again there: its host reads its allowance anew.
    answer = { check: { state: "ok", detail: "", models: null, checkedAt: 2 }, quota: ok(2000) };
    await r.accounts.check("sh-1");
    assert.equal(r.accounts.health("sh-1").check?.state, "ok", "good again once its host read it since");
    assert.equal(r.back.at(-1), "sh-1", "its cooldown cleared");
  } finally {
    await r.close();
  }
});

test("FB-44: a borrowed profile whose upgraded host says it signed out is signed out here, the host telling its own managers", async () => {
  const r = rig({
    profiles: [lent("sh-2")],
    shared: { status: async (_p, recheck) => (recheck ? { check: { state: "login", detail: "over", models: null, checkedAt: 2 }, quota: { ...ok(3000), state: "unavailable", signedOut: true } } : { check: { state: "ok", detail: "", models: null, checkedAt: 1 }, quota: ok(1000) }), view: () => null },
  });
  try {
    await r.accounts.check("sh-2");
    await r.recheck("sh-2");
    assert.equal(r.accounts.health("sh-2").check?.state, "login");
    assert.equal(r.lost.length, 0, "not told twice: its host tells");
  } finally {
    await r.close();
  }
});

test("FB-44: a borrowed profile its host said was over (LOGIN_OVER) is signed out at once", async () => {
  const r = rig({ profiles: [lent("sh-3")], shared: { status: async () => ({ check: { state: "ok", detail: "", models: null, checkedAt: 1 }, quota: ok(1000) }), view: () => null } });
  try {
    await r.accounts.check("sh-3");
    r.accounts.markLoginExpired("sh-3");
    assert.equal(r.accounts.health("sh-3").check?.state, "login");
    assert.equal(r.lost.length, 0);
    await r.accounts.check("sh-3");
    assert.equal(r.accounts.health("sh-3").check?.state, "login", "an old reading does not undo it");
  } finally {
    await r.close();
  }
});

test("FB-44: a local subscription whose check says ok but whose allowance refuses its login is over, the managers told", async () => {
  let refused = true;
  const r = rig({
    profiles: [{ id: "cc", name: "Claude A", runtime: "claude", home: "homes/cc", access: { kind: "subscription" } }],
    quota: async () => (refused ? { state: "unavailable", windows: [], detail: "expired", checkedAt: 0 } : ok(0)),
  });
  try {
    await r.accounts.check("cc");
    await r.recheck("cc");
    assert.equal(r.accounts.health("cc").check?.state, "login");
    assert.equal(r.lost.length, 1);
    assert.equal(r.lost[0]!.profile.name, "Claude A");
    assert.equal(r.lost[0]!.station, null, "this station's own");
    // A check that says ok alone does not undo it.
    await r.accounts.check("cc");
    assert.equal(r.accounts.health("cc").check?.state, "login");
    // Its allowance read again, and good.
    refused = false;
    await r.accounts.refreshQuota("cc");
    await settle();
    await r.accounts.check("cc");
    assert.equal(r.accounts.health("cc").check?.state, "ok");
  } finally {
    await r.close();
  }
});

test("FB-44: refused again after its recheck and a retry (force), it is over whatever its check says", async () => {
  const r = rig({ profiles: [{ id: "cc", runtime: "claude", home: "homes/cc", access: { kind: "subscription" } }], quota: async () => ok(0) });
  try {
    await r.accounts.check("cc");
    await r.recheck("cc");
    assert.equal(r.accounts.health("cc").check?.state, "ok", "its check and allowance say it works");
    await r.recheck("cc", true);
    assert.equal(r.accounts.health("cc").check?.state, "login");
    assert.equal(r.lost.length, 1);
  } finally {
    await r.close();
  }
});

test("FB-44: a profile made and never signed in is not told to the managers", async () => {
  const r = rig({
    profiles: [{ id: "fresh", runtime: "claude", home: "homes/fresh", access: { kind: "subscription" } }],
    check: async () => ({ state: "login", detail: "signed out", models: null, checkedAt: 0 }),
  });
  try {
    await r.accounts.check("fresh");
    assert.equal(r.accounts.health("fresh").check?.state, "login");
    assert.equal(r.lost.length, 0);
  } finally {
    await r.close();
  }
});

for (const force of [false, true]) {
  test(`FB-44: a borrowed profile never checked here, its old host's cached ok ignored, is over at a refusal (force: ${force})`, async () => {
    // (a host of 0.1.10384 that read its allowance in its own round: `recheck` not heard, what it had answered)
    let answer: { check: Partial<ProfileCheck>; quota: ProfileQuota } = { check: { state: "ok", detail: "", models: null, checkedAt: 1 }, quota: ok(1000) };
    const r = rig({ profiles: [lent("sh-1")], shared: { status: async () => answer as any, view: () => null, hostName: () => "Host A" } });
    try {
      await r.recheck("sh-1", force);
      assert.equal(r.accounts.health("sh-1").check?.state, "login", "an allowance its host had is not one read since the refusal");
      await r.accounts.check("sh-1");
      assert.equal(r.accounts.health("sh-1").check?.state, "login", "nor does that reading undo it later");
      assert.equal(r.lost.length, 1);
      answer = { check: { state: "ok", detail: "", models: null, checkedAt: 2 }, quota: ok(2000) };
      await r.accounts.check("sh-1");
      assert.equal(r.accounts.health("sh-1").check?.state, "ok", "good again once its host read it since");
    } finally {
      await r.close();
    }
  });
}
