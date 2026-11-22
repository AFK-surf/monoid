// FB-44: an allowance used up moved a session onto a borrowed profile whose OAuth login was revoked, and the chat
// stopped on "OAuth token revoked". Each profile a turn is refused on is rechecked (passed over from then on) and the
// turn goes on on the next the pool gives, over as many revoked ones as there are, whether the turn was refused or its
// process could not open; with none left it stops once, saying so; and the pool picks none of them again.
import assert from "node:assert/strict";
import { test } from "node:test";
import { ProfileLoginOver, RenewRefused } from "../src/accounts/console.ts";
import { Rig, message, settle } from "./hub-fakes.ts";

type Said = { state: string; used: number };

/// A pool of `ids` (Claude profiles) whose health a test sets, and its rechecks: `marks[id]` what a recheck of `id`
/// finds (its state), `then[id]` what it makes usable after (the next one's allowance read, as a round would).
function pool(r: Rig, ids: string[], said: Record<string, Said>) {
  r.edit((raw) => {
    raw.profiles = raw.profiles.filter((p: any) => p.runtime !== "claude");
    for (const id of ids) raw.profiles.push({ id, runtime: "claude", home: `homes/${id}`, name: id });
  });
  r.hub.accounts.setHealth((id) => {
    const s = said[id] ?? { state: "ok", used: 0 };
    return { check: { state: s.state, detail: "", models: null, checkedAt: 0 }, quota: { state: "ok", windows: [{ label: "5 小时", usedPercent: s.used, resetsAt: null }], detail: null, checkedAt: 0 } };
  });
}

for (const how of ["refused in its turn", "refused as its process opens"] as const) {
  test(`FB-44: a turn goes on over two revoked borrowed profiles to a healthy one (${how})`, async () => {
    const r = new Rig();
    try {
      const said: Record<string, Said> = {
        a: { state: "ok", used: 0 },
        "sh-revoked-1": { state: "ok", used: 100 },
        "sh-revoked-2": { state: "ok", used: 100 },
        healthy: { state: "ok", used: 100 },
      };
      pool(r, ["a", "sh-revoked-1", "sh-revoked-2", "healthy"], said);
      const rechecked: [string, boolean][] = [];
      // (what a recheck finds: the revoked one over, and the next one's allowance read meanwhile)
      const next: Record<string, string> = { "sh-revoked-1": "sh-revoked-2", "sh-revoked-2": "healthy" };
      r.hub.accounts.setRecheck(async (id, force) => {
        rechecked.push([id, force === true]);
        if (id.startsWith("sh-revoked")) said[id]!.state = "login";
        const after = next[id];
        if (after) said[after]!.used = 0;
      });
      if (how === "refused as its process opens") {
        const open = r.claude.open.bind(r.claude);
        r.claude.open = async (options, events) => {
          if (options.profile.id === "sh-revoked-2") throw new ProfileLoginOver("sh-revoked-2", "Claude sign-in expired; sign in again");
          return open(options, events);
        };
      }
      const m = message();
      await r.accept(m);
      await settle();
      const first = r.claude.last();
      const key = first.options.route;
      assert.equal(first.options.profile.id, "a");
      // a's allowance used up: the pool has only sh-revoked-1 that can run it.
      said.a!.used = 100;
      said["sh-revoked-1"]!.used = 0;
      first.end({ kind: "failed", reason: "rate_limit", message: "You've hit your limit · resets 5pm" });
      await settle();
      const onRevoked1 = r.claude.last();
      assert.equal(onRevoked1.options.profile.id, "sh-revoked-1");
      onRevoked1.end({ kind: "failed", reason: "auth", message: "OAuth token revoked" });
      await settle();
      if (how === "refused in its turn") {
        const onRevoked2 = r.claude.last();
        assert.equal(onRevoked2.options.profile.id, "sh-revoked-2");
        onRevoked2.end({ kind: "failed", reason: "auth", message: "OAuth token revoked" });
        await settle();
      }
      const onHealthy = r.claude.last();
      assert.equal(onHealthy.options.profile.id, "healthy", "the turn goes on on the healthy profile");
      assert.deepEqual(rechecked, [["sh-revoked-1", false], ["sh-revoked-2", false]], "each revoked profile rechecked once, as it was refused");
      await r.call(key, "chat_post", { to: `C1/${m.threadTs}`, text: "done", kind: "all_done", done: "Finished on the healthy profile." });
      onHealthy.complete();
      await settle();
      assert.equal(r.session(key).profile, "healthy");
      assert.ok(!r.chat.texts().some((t) => t.includes("OAuth token revoked")), "no authentication failure said in the chat");
      // From then on the pool picks the healthy one, for a new chat and for a session picked again.
      r.hub.accounts.repick(key);
      assert.equal(r.session(key).profile, "healthy", "repick keeps away from the revoked profiles");
      const other = message();
      await r.accept(other);
      await settle();
      assert.equal(r.claude.last().options.profile.id, "healthy", "a new chat starts on the healthy profile");
    } finally {
      await r.close();
    }
  });
}

test("FB-44: repick and new chats never pick a profile whose login is over", async () => {
  const r = new Rig();
  try {
    const said: Record<string, Said> = { "sh-revoked-1": { state: "login", used: 0 }, "sh-revoked-2": { state: "login", used: 0 }, healthy: { state: "ok", used: 60 } };
    pool(r, ["sh-revoked-1", "sh-revoked-2", "healthy"], said);
    for (let i = 0; i < 3; i++) {
      await r.accept(message());
      await settle();
      const s = r.claude.last();
      assert.equal(s.options.profile.id, "healthy");
      r.store.setSessionProfile(s.options.route, "sh-revoked-1", false, null);
      r.hub.accounts.repick(s.options.route);
      assert.equal(r.session(s.options.route).profile, "healthy");
    }
  } finally {
    await r.close();
  }
});

test("FB-44: with every profile's login over, the turn stops once, saying so, and goes round no more", async () => {
  const r = new Rig();
  try {
    const said: Record<string, Said> = { r1: { state: "ok", used: 0 }, r2: { state: "ok", used: 100 }, r3: { state: "ok", used: 100 } };
    pool(r, ["r1", "r2", "r3"], said);
    const rechecked: string[] = [];
    const next: Record<string, string> = { r1: "r2", r2: "r3" };
    r.hub.accounts.setRecheck(async (id) => {
      rechecked.push(id);
      said[id]!.state = "login";
      const after = next[id];
      if (after) said[after]!.used = 0;
    });
    const m = message();
    await r.accept(m);
    await settle();
    for (const id of ["r1", "r2", "r3"]) {
      const s = r.claude.last();
      assert.equal(s.options.profile.id, id);
      s.end({ kind: "failed", reason: "auth", message: "OAuth token revoked" });
      await settle();
    }
    assert.equal(r.claude.count(), 3, "no process opened after the last profile was refused");
    assert.deepEqual(rechecked, ["r1", "r2", "r3"]);
    const said1 = r.chat.texts().filter((t) => t.includes("OAuth token revoked"));
    assert.equal(said1.length, 1, "the failure said once");
  } finally {
    await r.close();
  }
});

test("FB-44: refused again on the same profile after a retry, it is rechecked as over (force)", async () => {
  const r = new Rig();
  try {
    const said: Record<string, Said> = { a: { state: "ok", used: 0 } };
    pool(r, ["a"], said);
    const rechecked: [string, boolean][] = [];
    // (a check that still says ok: the provider lists models for a revoked token)
    r.hub.accounts.setRecheck(async (id, force) => {
      rechecked.push([id, force === true]);
      if (force) said[id]!.state = "login";
    });
    await r.accept(message());
    await settle();
    r.claude.last().end({ kind: "failed", reason: "auth", message: "OAuth token revoked" });
    await settle();
    assert.equal(r.claude.count(), 2, "tried once more on it while its check said ok");
    r.claude.last().end({ kind: "failed", reason: "auth", message: "OAuth token revoked" });
    await settle();
    assert.equal(r.claude.count(), 2, "no third process");
    assert.deepEqual(rechecked, [["a", false], ["a", true]]);
    assert.equal(said.a!.state, "login");
  } finally {
    await r.close();
  }
});

for (const when of ["its first turn", "a move off a spent profile"] as const) {
  test(`FB-44: a local profile whose login cannot be renewed as its process opens is rechecked and left (${when})`, async () => {
    const r = new Rig();
    try {
      const ids = when === "its first turn" ? ["local-revoked", "healthy"] : ["a", "local-revoked", "healthy"];
      const said: Record<string, Said> = { a: { state: "ok", used: 0 }, "local-revoked": { state: "ok", used: when === "its first turn" ? 0 : 100 }, healthy: { state: "ok", used: 100 } };
      pool(r, ids, said);
      const rechecked: string[] = [];
      r.hub.accounts.setRecheck(async (id) => {
        rechecked.push(id);
        if (id === "local-revoked") {
          said[id]!.state = "login";
          said.healthy!.used = 0;
        }
      });
      // (a local login, not a borrowed one: its renewal refused as the driver opens it)
      const open = r.claude.open.bind(r.claude);
      r.claude.open = async (options, events) => {
        if (options.profile.id === "local-revoked") throw new RenewRefused(400, "Claude sign-in renewal was refused (400); sign in again");
        return open(options, events);
      };
      const m = message();
      await r.accept(m);
      await settle();
      if (when === "a move off a spent profile") {
        const first = r.claude.last();
        assert.equal(first.options.profile.id, "a");
        said.a!.used = 100;
        said["local-revoked"]!.used = 0;
        first.end({ kind: "failed", reason: "rate_limit", message: "You've hit your limit · resets 5pm" });
        await settle();
      }
      const on = r.claude.last();
      assert.equal(on.options.profile.id, "healthy", "it opens on the healthy profile");
      assert.deepEqual(rechecked, ["local-revoked"], "the profile whose login is over is the one rechecked, not the one before it");
      assert.equal(said["local-revoked"]!.state, "login");
      const key = on.options.route;
      await r.call(key, "chat_post", { to: `C1/${m.threadTs}`, text: "done", kind: "all_done", done: "Finished on the healthy profile." });
      on.complete();
      await settle();
      assert.equal(r.session(key).profile, "healthy");
    } finally {
      await r.close();
    }
  });
}
