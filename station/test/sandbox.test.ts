// Sandboxes as targets of station_task (src/agents/sandbox.ts): what is the same every run. config.json's `sandboxes`,
// effective Colab sandboxes, profile filtering, how a task's command is made, and what station_list says of one.
// Running a task there, against a stand-in ssh of real processes, is the side run's (side/sandbox.test.ts).
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, test } from "node:test";
import {
  BRIDGE,
  COLAB,
  DEFAULT_COLAB_SANDBOXES,
  allColabAccounts,
  checkSandboxes,
  colabAccountsFor,
  colabPool,
  effectiveSandboxes,
  parseRemoteSandbox,
  sandboxCommand,
  sandboxDescribed,
  sandboxOf,
  sandboxesOf,
} from "../src/agents/sandbox.ts";
import { sandboxName } from "../src/agents/sandbox-name.ts";
import { COLAB_AUTH_FILE } from "../src/accounts/colab.ts";
import type { Profile } from "../src/sessions/config.ts";

/// The bridge specs a command made by sandboxCommand runs, in order.
function specs(command: string): any[] {
  const words = [...command.matchAll(/'((?:[^']|'\\'')*)'/g)].map((m) => m[1]!.replaceAll(`'\\''`, "'"));
  const out: any[] = [];
  for (let i = 0; i < words.length; i++) if (words[i] === BRIDGE && words[i + 1] === "host") out.push(JSON.parse(words[i + 2]!));
  return out;
}

function makeProfile(overrides: Partial<Profile> & { id: string; home: string }): Profile {
  return {
    name: overrides.id,
    runtimes: [],
    models: [],
    named: [],
    backgroundOnMessage: true,
    enabled: true,
    service: "colab",
    access: { kind: "service", service: "colab" },
    ...overrides,
  };
}

describe("sandboxes", () => {
  test("config.json's sandboxes: a name, a front door with {name} where each sandbox's name goes, a size of its operator's", () => {
    const raw = { sandboxes: [{ name: "l4es-large", target: "{name}.team@l4es.afk.surf", size: "large" }, { name: "l4es", target: "{name}.team@l4es.afk.surf", identity: "/k" }] };
    checkSandboxes(raw);
    assert.deepEqual(sandboxesOf(raw), raw.sandboxes);
    assert.deepEqual(sandboxesOf({}), []);
    assert.throws(() => checkSandboxes({ sandboxes: {} }), /a list/);
    assert.throws(() => checkSandboxes({ sandboxes: [{ name: "x", target: "dev@l4es.afk.surf" }] }), /front door/);
    assert.throws(() => checkSandboxes({ sandboxes: [{ name: "x", target: "{name}.t@h", size: "Large 2" }] }), /size/);
    assert.throws(() => checkSandboxes({ sandboxes: [{ name: "x", target: "{name}.t@h", identity: "k" }] }), /identity/);
    assert.throws(() => checkSandboxes({ sandboxes: [{ name: "a b", target: "{name}.t@h" }] }), /name/);
    assert.throws(() => checkSandboxes({ sandboxes: [{ name: "x", target: "{name}.t@h" }, { name: "X", target: "{name}.u@h" }] }), /named twice/);
    // One not well formed is left out where the file has it anyway.
    assert.deepEqual(sandboxesOf({ sandboxes: [{ name: "x", target: "nope" }, { name: "y", target: "{name}.t@h" }] }).map((s) => s.name), ["y"]);
  });

  test("each chat has a sandbox of its own there, its name one the front door takes", () => {
    const d = { name: "l4es", target: "{name}.team@host" };
    assert.notEqual(sandboxOf(d, "s1"), sandboxOf(d, "s2"));
    assert.equal(sandboxOf(d, "s1"), sandboxName("l4es|s1"));
    assert.match(sandboxOf(d, "s1"), /^[a-z][a-z0-9-]{0,30}$/);
  });

  test("a task's command makes its sandbox of the size, copies its directory there and runs it; then brings back what it names", () => {
    const d = { name: "l4es", target: "{name}.team@host", size: "large" };
    const name = sandboxOf(d, "s1");
    const [run, back, ...rest] = specs(sandboxCommand("/data", d, { sandbox: "l4es", session: "s1", back: ["out", "logs/a.txt"] }, "make test", "/data/remote/w/src", [4750], "/data/jobs/exit/j.lost", "node"));
    assert.equal(rest.length, 0);
    assert.equal(run.ssh.at(-1), `${name}.team@host`);
    assert.deepEqual(run.create.slice(-4), ["create", name, "--size", "large"]);
    assert.equal(run.create.at(-5), "_.team@host");
    assert.ok(run.ssh.includes("BatchMode=yes") && run.ssh.includes("/data/run/sandbox/id_ed25519"));
    assert.deepEqual(run.root, { path: "/data" });
    assert.deepEqual(run.sync, [{ path: "/data/remote/w/src", mode: "whole", back: false, dir: true }]);
    assert.deepEqual([run.program, run.args, run.cwd, run.ports, run.lostFile], ["/bin/sh", ["-c", "make test"], "/data/remote/w/src", [4750], "/data/jobs/exit/j.lost"]);
    // What it brings back, after: nothing pushed, file or directory.
    assert.equal(back.program, undefined);
    assert.deepEqual(back.sync.map((e: any) => [e.path, e.push, e.dir]), [["/data/remote/w/src/out", false, false], ["/data/remote/w/src/logs/a.txt", false, false]]);
    // Nothing to bring back: the one bridge alone; no create without a size (its first connection makes one); a key given.
    const plain = specs(sandboxCommand("/data", { name: "l4es", target: "{name}.team@host", identity: "/keys/l4es" }, { sandbox: "l4es", session: "s1", back: [] }, "true", "/w", [], "/l", "node"));
    assert.equal(plain.length, 1);
    assert.equal(plain[0].create, undefined);
    assert.ok(plain[0].ssh.includes("/keys/l4es"));
  });

  test("station_list says a sandbox takes tasks and synced directories, and has no chats of its own", () => {
    const said = sandboxDescribed({ name: "l4es", target: "{name}.team@host", size: "large" }) as any;
    assert.equal(said.kind, "sandbox");
    assert.equal(said.size, "large");
    assert.equal(said.tasks, true);
    assert.equal(said.sync, 1);
    assert.equal(said.chats, false);
  });

  test("effectiveSandboxes exposes default Colab sandboxes iff colabAccountCount > 0 and no explicit colab entry exists, without overwriting l4es", () => {
    // 0 accounts: no default Colab sandboxes
    assert.deepEqual(effectiveSandboxes({}, 0), []);
    // >=1 accounts, no explicit colab: appends colab-g4, colab-l4, colab-t4
    assert.deepEqual(effectiveSandboxes({}, 2), [...DEFAULT_COLAB_SANDBOXES]);
    // Explicit kind: "colab" entry: does NOT append defaults
    const explicit = { sandboxes: [{ name: "my-a100", kind: "colab", gpu: "A100" }] };
    assert.deepEqual(effectiveSandboxes(explicit, 2), [{ name: "my-a100", kind: "colab", gpu: "A100" }]);
    // Same-name l4es (case-insensitive) is NOT overwritten
    const withCollision = { sandboxes: [{ name: "COLAB-G4", target: "{name}.t@h" }] };
    assert.deepEqual(
      effectiveSandboxes(withCollision, 1).map((s) => [s.name, s.kind ?? "l4es"]),
      [["COLAB-G4", "l4es"], ["colab-l4", "colab"], ["colab-t4", "colab"]],
    );
  });

  test("colabAccountsFor filters disabled, withheld, and missing auth files; allColabAccounts keeps them for reap", () => {
    const dir = mkdtempSync(join(tmpdir(), "colab-accts-"));
    try {
      const mk = (id: string, writeAuth = true) => {
        const home = join(dir, id);
        mkdirSync(home, { recursive: true });
        if (writeAuth) writeFileSync(join(home, COLAB_AUTH_FILE), "{}");
        return home;
      };
      const profiles: Profile[] = [
        makeProfile({ id: "c-ok", home: mk("c-ok") }),
        makeProfile({ id: "c-disabled", home: mk("c-disabled"), enabled: false }),
        makeProfile({ id: "c-withheld", home: mk("c-withheld"), withheld: ["ws-joined"] }),
        makeProfile({ id: "c-no-auth", home: mk("c-no-auth", false) }),
        makeProfile({ id: "other", home: mk("other"), service: undefined, access: { kind: "subscription" } }),
      ];
      // Home workspace: c-ok and c-withheld (home ignores withheld), sorted by id
      assert.deepEqual(colabAccountsFor(profiles, "ws-home", "ws-home").map((a) => a.id), ["c-ok", "c-withheld"]);
      // Joined workspace: c-withheld filtered out
      assert.deepEqual(colabAccountsFor(profiles, "ws-joined", "ws-home").map((a) => a.id), ["c-ok"]);
      // allColabAccounts: keeps disabled and withheld (for reap), still skips missing auth file
      assert.deepEqual(allColabAccounts(profiles).map((a) => a.id), ["c-disabled", "c-ok", "c-withheld"]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("Colab sandboxDescribed and sandboxCommand include accounts, workspace, and run spec", () => {
    const raw = { sandboxes: [{ name: "colab-g4", kind: "colab", gpu: "G4" }, { name: "l4es", target: "{name}.t@h" }] };
    checkSandboxes(raw);
    assert.deepEqual(sandboxesOf(raw), raw.sandboxes);
    assert.throws(() => checkSandboxes({ sandboxes: [{ name: "x", kind: "colab", gpu: "RTX5090" }] }), /gpu is one of Colab's/);
    assert.throws(() => checkSandboxes({ sandboxes: [{ name: "x", kind: "aws", target: "{name}.t@h" }] }), /kind is "colab"/);

    const d = sandboxesOf(raw)[0]!;
    const described = sandboxDescribed(d, { accounts: 2, host: "studio" }) as any;
    assert.equal(described.kind, "sandbox");
    assert.equal(described.sandboxKind, "colab");
    assert.equal(described.gpu, "G4");
    assert.equal(described.accounts, 2);
    assert.equal(described.host, "studio");
    assert.equal(described.tasks, true);
    assert.equal(described.chats, false);

    const accounts = [{ id: "p1", authFile: "/data/homes/p1/colab-auth.json" }];
    const command = sandboxCommand(
      "/data",
      d,
      { sandbox: "colab-g4", session: "s1", back: ["out"], workspace: "ws-1" },
      "render",
      "/data/remote/w/src",
      [4750],
      "/data/jobs/exit/j.lost",
      "node",
      accounts,
    );
    const words = [...command.matchAll(/'((?:[^']|'\\'')*)'/g)].map((m) => m[1]!.replaceAll(`'\\''`, "'"));
    assert.deepEqual(words.slice(0, 3), ["node", COLAB, "run"]);
    const o = JSON.parse(words[3]!);
    assert.deepEqual(
      [o.pool, o.gpu, o.chat, o.command, o.cwd, o.ports, o.lostFile, o.back, o.bridge, o.accounts],
      [colabPool("/data"), "G4", "s1", "render", "/data/remote/w/src", [4750], "/data/jobs/exit/j.lost", ["out"], BRIDGE, accounts],
    );
  });

  test("parseRemoteSandbox distinguishes sandbox:<hostId>:<name> from local sandbox:<name>", () => {
    assert.deepEqual(parseRemoteSandbox("sandbox:abc123:colab-g4"), { hostId: "abc123", name: "colab-g4" });
    assert.equal(parseRemoteSandbox("sandbox:colab-g4"), null);
    assert.equal(parseRemoteSandbox("sandbox::colab-g4"), null);
    assert.equal(parseRemoteSandbox("sandbox:abc:"), null);
    assert.equal(parseRemoteSandbox("sandbox:abc:a:b"), null);
    assert.equal(parseRemoteSandbox("abc123"), null);
  });
});
