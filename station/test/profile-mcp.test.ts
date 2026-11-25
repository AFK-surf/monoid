// A profile's own MCP servers (src/agents/profile-mcp.ts): edited by PUT /profiles/:id (their masked values kept, the
// station's name refused), read masked by the overview, carried where the profile moves or is shared (portable), and
// put in each runtime's shapes. The drivers' tests (claude, codex, copilot) hold what each gives its sessions.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Accounts as AccountManager, checkConfig } from "../src/accounts/index.ts";
import { claudeServers, codexServers, copilotServers, edited, mcpView, profileMcp, reserved } from "../src/agents/profile-mcp.ts";
import { maskValue } from "../src/ops/agent-env.ts";
import { ConfigFile } from "../src/ops/config.ts";
import { portable } from "../src/share/index.ts";
import { Store } from "../src/store/store.ts";
import { testClock } from "./hub-fakes.ts";

const ado = { type: "stdio" as const, command: "npx", args: ["-y", "@azure-devops/mcp", "org"], env: { ADO_TOKEN: "ado-secret-token" } };
const remote = { type: "http" as const, url: "https://mcp.example.test/mcp", headers: { Authorization: "Bearer remote-secret-key" } };

test("an edit sets and removes the servers it names, keeps the others, and keeps a masked value as it was", () => {
  const before = edited(undefined, { ado, remote });
  assert.deepEqual(before, { ado, remote });
  // The page sends back what it was shown: masked values stay the secrets they were; a new one replaces.
  const shown = mcpView(before);
  const again = edited(before, { ado: { command: "npx", args: ["x"], env: shown.find((s) => s.name === "ado").env } });
  assert.deepEqual(again, { ado: { type: "stdio", command: "npx", args: ["x"], env: { ADO_TOKEN: "ado-secret-token" } }, remote });
  assert.deepEqual(edited(again, { ado: { command: "npx", env: { ADO_TOKEN: "new" } } })!.ado.env, { ADO_TOKEN: "new" });
  assert.deepEqual(edited(again, { remote: null }), { ado: again!.ado });
  assert.equal(edited(again, { ado: null, remote: null }), undefined, "none left: none written");
  assert.equal(edited(again, null), undefined);
  assert.deepEqual(edited(again, undefined), again, "not named: kept");
  assert.deepEqual(edited(undefined, { off: { command: "x", enabled: false } }), { off: { type: "stdio", command: "x", enabled: false } });
});

test("an edit is refused for the station's own name, a bad name, a server that is neither local nor remote", () => {
  for (const name of ["stillfail", "StillFail", "stillfail-x", "stillfail_x"]) {
    assert.ok(reserved(name));
    assert.throws(() => edited(undefined, { [name]: ado }), /the station's own/);
  }
  assert.ok(!reserved("still"));
  assert.throws(() => edited(undefined, { "a.b": ado }), /letters, digits/);
  assert.throws(() => edited(undefined, { a: { type: "stdio" } }), /command must be a string/);
  assert.throws(() => edited(undefined, { a: { type: "stdio", command: " " } }), /needs a command/);
  assert.throws(() => edited(undefined, { a: { type: "http", url: "ftp://x" } }), /http or https/);
  assert.throws(() => edited(undefined, { a: { type: "http", url: "nope" } }), /not a URL/);
  assert.throws(() => edited(undefined, { a: { type: "ws", url: "https://x" } }), /unknown server type/);
  assert.throws(() => edited(undefined, { a: { command: "x", env: { "1BAD": "v" } } }), /invalid name/);
  assert.throws(() => edited(undefined, { a: { command: "x", enabled: "no" } }), /enabled must be a boolean/);
  assert.throws(() => edited(undefined, []), /a map of servers/);
});

test("the pages read every value masked; sessions get those not turned off, in each runtime's shapes", () => {
  const view = mcpView({ remote, ado, off: { command: "x", enabled: false }, stillfail: remote, bad: { type: "stdio" } });
  assert.deepEqual(view.map((s) => [s.name, s.enabled]), [["ado", true], ["off", false], ["remote", true]], "sorted; one by the station's name or not a server left out");
  assert.deepEqual(view[0].env, { ADO_TOKEN: maskValue("ado-secret-token") });
  assert.deepEqual(view[2].headers, { Authorization: maskValue("Bearer remote-secret-key") });
  assert.ok(!JSON.stringify(view).includes("secret-"));

  const given = profileMcp({ mcp: { ado, remote, off: { command: "x", enabled: false }, old: { type: "sse", url: "https://sse.example.test/sse" } } });
  assert.deepEqual(Object.keys(given), ["ado", "remote", "old"]);

  const vars: Record<string, string> = {};
  const claude = claudeServers(given, vars);
  assert.ok(!JSON.stringify(claude).includes("secret-"), "Claude Code's config names variables, not values");
  const value = (ref: string) => vars[/^\$\{(\w+)\}$/.exec(ref)![1]!];
  assert.equal(value(claude.ado.env.ADO_TOKEN), "ado-secret-token");
  assert.equal(value(claude.remote.headers.Authorization), "Bearer remote-secret-key");
  assert.deepEqual(claude.old, { type: "sse", url: "https://sse.example.test/sse" });

  const codex = codexServers(given);
  assert.deepEqual(codex.skipped, ["old"]);
  assert.equal(codex.config["mcp_servers.ado.command"], "npx");
  assert.deepEqual(codex.config["mcp_servers.remote.http_headers"], remote.headers);

  assert.deepEqual(copilotServers({ ado }).ado, { ...ado, tools: ["*"] });
});

test("PUT /profiles/:id edits them, the overview reads them masked, a move or share carries them", async () => {
  const dir = mkdtempSync(join(tmpdir(), "mcp-acct-"));
  const time = testClock();
  writeFileSync(join(dir, "config.json"), JSON.stringify({ profiles: [{ id: "p1", name: "P", runtime: "claude", home: "homes/p1", access: { kind: "opencode-go", key: "k1" } }], connects: [] }));
  const store = Store.open(":memory:", null, time.clock);
  const config = new ConfigFile(dir);
  config.check = checkConfig;
  const accounts = new AccountManager({
    data: dir,
    store,
    config,
    clock: time.clock,
    machine: null,
    checkOnStart: false,
    check: async () => ({ state: "ok", detail: "ok", models: ["m"], checkedAt: time.clock.currentTimeMillisUnsafe() }),
    quota: null,
  });
  const viewer = { id: "u1", email: "owner@example.com", name: "Owner", role: "owner", home: true, workspace: "w1" } as any;
  const raw = () => config.raw().profiles.find((p: any) => p.id === "p1");
  try {
    await accounts.putProfile("p1", { mcp: { ado, remote } }, viewer);
    assert.deepEqual(raw().mcp, { ado, remote });
    const view = (accounts.profilesView(viewer).find((p: any) => p.id === "p1") as any).mcp;
    assert.deepEqual(view.map((s: any) => s.name), ["ado", "remote"]);
    assert.ok(!JSON.stringify(view).includes("secret-"));
    // Another edit of the profile keeps them; an edit of them keeps what it does not name.
    await accounts.putProfile("p1", { name: "Renamed" }, viewer);
    assert.deepEqual(raw().mcp, { ado, remote });
    await accounts.putProfile("p1", { mcp: { remote: null } }, viewer);
    assert.deepEqual(raw().mcp, { ado });
    await assert.rejects(accounts.putProfile("p1", { mcp: { stillfail: remote } }, viewer), /the station's own/);
    assert.deepEqual(raw().mcp, { ado }, "a refused edit changes nothing");
    assert.deepEqual(portable(raw()).mcp, { ado });
    await accounts.putProfile("p1", { mcp: { ado: null } }, viewer);
    assert.equal(raw().mcp, undefined);
  } finally {
    await accounts.close();
    store.close();
    rmSync(dir, { recursive: true, force: true });
  }
});
