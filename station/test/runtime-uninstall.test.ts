// A runtime removed from the station's machine the way it was installed (runtimes.ts `howToUninstallSoon`), the
// software page's 卸载 (updates.ts `uninstall`) and its route (`POST /updates/uninstall`), with fake npm and brew
// commands and a fake Claude Code install in temporary directories: nothing real is removed.
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { describe, test } from "node:test";
import { setTimeout as sleep } from "node:timers/promises";
import type { Request } from "../src/api/request.ts";
import { routes } from "../src/api/routes/updates.ts";
import { ConfigFile } from "../src/ops/config.ts";
import { WINDOWS } from "../src/platform/index.ts";
import { tr } from "../src/ops/i18n.ts";
import { type Env, type Found, Unable, findCommandSoon, howToUninstallSoon, runLines } from "../src/updates/runtimes.ts";
import { Updates, type UpdatesOptions } from "../src/updates/updates.ts";
import type { RuntimeKind } from "../src/agents/runtime.ts";
import { exe, script } from "./accounts-fakes.ts";

delete process.env.STILLFAIL_CONFIG;

const temp = () => realpathSync(mkdtempSync(join(tmpdir(), "stillfail-uninstall-")));
const found = (real: string): Found => ({ onPath: "/nowhere/bin/x", real });
const say = (h: unknown) => (h as Unable).say("zh");
/// Looks every 20 ms until `f` holds (a real process runs the removal; nothing tells of its end but the page's line).
async function until(f: () => boolean, signal: AbortSignal) {
  while (!f()) await sleep(20, undefined, { signal });
}
/// An executable shell script at `path` (unix: the flows below run only there).
function sh(path: string, text: string) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, text);
  chmodSync(path, 0o755);
}

describe("how each runtime is removed", () => {
  test("npm's from the prefix the station's copy is in, by that Node's npm", async () => {
    const dir = temp();
    script(join(dir, "npm"), "#!/bin/sh\n");
    const env: Env = { PATH: dir };
    const npm = exe(join(dir, "npm"));
    assert.deepEqual(await howToUninstallSoon("codex", found("/Users/a/.nvm/versions/node/v24/lib/node_modules/@openai/codex/bin/codex.js"), env), {
      program: npm, args: ["uninstall", "-g", "@openai/codex", "--prefix", "/Users/a/.nvm/versions/node/v24"],
    });
    assert.deepEqual(await howToUninstallSoon("pi", found("/Users/a/node/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"), env), {
      program: npm, args: ["uninstall", "-g", "@earendil-works/pi-coding-agent", "--prefix", "/Users/a/node"],
    });
    // Linked from a directory beside another Node's npm: its own Node's npm removes it, from its own prefix.
    const node = join(dir, "node/v24.3.0");
    mkdirSync(join(node, "bin"), { recursive: true });
    writeFileSync(join(node, "bin/npm"), "");
    assert.deepEqual(await howToUninstallSoon("claude", { onPath: join(dir, "claude"), real: join(node, "lib/node_modules/@anthropic-ai/claude-code/cli.js") }, env), {
      program: join(node, "bin/npm"), args: ["uninstall", "-g", "@anthropic-ai/claude-code", "--prefix", node],
    });
    // Not in a global prefix (a project's node_modules): not this station's to remove, said with where it is.
    const local = await howToUninstallSoon("codex", found("/project/node_modules/@openai/codex/bin/codex.js"), env);
    assert.ok(local instanceof Unable && say(local).includes("/project/node_modules"));
  });

  test("Homebrew's by brew, the cask or formula its path names", async () => {
    const dir = temp();
    script(join(dir, "brew"), "#!/bin/sh\n");
    const env: Env = { PATH: dir };
    const brew = exe(join(dir, "brew"));
    assert.deepEqual(await howToUninstallSoon("claude", found("/opt/homebrew/Caskroom/claude-code/2.1.284/claude"), env), { program: brew, args: ["uninstall", "--cask", "claude-code"] });
    assert.deepEqual(await howToUninstallSoon("claude", found("/opt/homebrew/Caskroom/claude-code@latest/2.1.300/claude"), env), { program: brew, args: ["uninstall", "--cask", "claude-code@latest"] });
    assert.deepEqual(await howToUninstallSoon("codex", found("/opt/homebrew/Caskroom/codex/0.46.0/codex-aarch64-apple-darwin"), env), { program: brew, args: ["uninstall", "--cask", "codex"] });
    assert.deepEqual(await howToUninstallSoon("codex", found("/opt/homebrew/Cellar/codex/0.46.0/bin/codex"), env), { program: brew, args: ["uninstall", "codex"] });
    assert.deepEqual(await howToUninstallSoon("claude", found("/usr/local/Cellar/claude-code/2.1.284/bin/claude"), env), { program: brew, args: ["uninstall", "claude-code"] });
    // No brew where the station looks: said so, not guessed.
    const none = await howToUninstallSoon("codex", found("/opt/homebrew/Cellar/codex/0.46.0/bin/codex"), { PATH: "/nowhere" });
    assert.ok(none instanceof Unable);
    assert.equal(none.key, "station.updates.noBrew");
  });

  test("Claude Code's own installer's: its builds and the links into them go, its settings and chats stay", { skip: WINDOWS && "its installer links the command only on macOS and Linux" }, async () => {
    const home = temp();
    const versions = join(home, ".local/share/claude/versions");
    const bin = join(home, ".local/bin");
    sh(join(versions, "2.1.4"), "#!/bin/sh\necho '2.1.4 (Claude Code)'\n");
    sh(join(versions, "2.1.3"), "#!/bin/sh\necho '2.1.3 (Claude Code)'\n");
    mkdirSync(bin, { recursive: true });
    symlinkSync(join(versions, "2.1.4"), join(bin, "claude"));
    // Another link on PATH to the installer's link (a person's own /usr/local/bin/claude, say).
    const other = join(home, "other");
    mkdirSync(other);
    symlinkSync(join(bin, "claude"), join(other, "claude"));
    // What it keeps of the person's: never touched.
    mkdirSync(join(home, ".claude"), { recursive: true });
    writeFileSync(join(home, ".claude/settings.json"), "{}");
    writeFileSync(join(home, ".claude.json"), "{}");
    sh(join(bin, "unrelated"), "#!/bin/sh\n");
    const env: Env = { PATH: `${other}:/usr/bin:/bin`, HOME: home };
    const claude = (await findCommandSoon("claude", env))!;
    assert.equal(claude.onPath, join(other, "claude"));
    const how = await howToUninstallSoon("claude", claude, env);
    assert.ok(!(how instanceof Unable));
    assert.equal(how.program, process.execPath);
    assert.deepEqual(how.args.slice(2), [versions, join(other, "claude"), join(bin, "claude")]);
    const [ok, said] = await runLines(how.program, how.args, env, 20_000);
    assert.equal(ok, true, said);
    assert.deepEqual([existsSync(versions), existsSync(join(bin, "claude")), existsSync(join(other, "claude"))], [false, false, false]);
    assert.deepEqual([existsSync(join(home, ".claude/settings.json")), existsSync(join(home, ".claude.json")), existsSync(join(bin, "unrelated"))], [true, true, true]);
    assert.equal(await findCommandSoon("claude", env), null);
  });

  test("Vite+'s by the vp its command is a shim of; Devin's installer's by itself, its data kept", { skip: WINDOWS && "vp's shim there is vp.exe beside it (windows.ts shimUninstall)" }, async () => {
    const dir = temp();
    sh(join(dir, "vp"), "#!/bin/sh\n");
    symlinkSync(join(dir, "vp"), join(dir, "codex"));
    assert.deepEqual(await howToUninstallSoon("codex", { onPath: join(dir, "codex"), real: join(dir, "vp") }, { PATH: dir }), { program: join(dir, "vp"), args: ["uninstall", "-g", "@openai/codex"] });
    assert.deepEqual(await howToUninstallSoon("devin", found("/Users/a/.local/share/devin/cli/_versions/3000.11.92/devin"), { PATH: dir }), { program: "/nowhere/bin/x", args: ["uninstall", "--force"] });
  });

  test("winget's by winget, npm's .cmd from its prefix", { skip: !WINDOWS && "Windows' package managers" }, async () => {
    const dir = temp();
    script(join(dir, "winget"), "#!/bin/sh\n");
    const how = await howToUninstallSoon("claude", found("C:\\Users\\a\\AppData\\Local\\Microsoft\\WinGet\\Packages\\Anthropic.ClaudeCode_Microsoft.Winget.Source_8wekyb3d8bbwe\\claude.exe"), { PATH: dir });
    assert.deepEqual((how as { args: string[] }).args.slice(0, 3), ["uninstall", "--id", "Anthropic.ClaudeCode"]);
  });

  test("what has no way to be removed from here says how to remove it on the machine", async () => {
    const env: Env = { PATH: "/nowhere" };
    const cases: [RuntimeKind, string, string, string][] = [
      ["agy", "/Users/a/.local/bin/agy", "station.updates.uninstallAgy", "请在这台机器上删掉 /Users/a/.local/bin/agy"],
      ["hermes", "/Users/a/.local/bin/hermes", "station.updates.uninstallHermes", "请在这台机器上按 Hermes 的说明卸载"],
      ["pi", "/Users/a/.pi/agent/managed/pi", "station.updates.uninstallPi", "curl -fsSL https://pi.dev/install.sh | sh"],
      ["codex", "/Users/a/.codex/packages/standalone/releases/0.1.0-aarch64-apple-darwin/bin/codex", "station.updates.uninstallCodexStandalone", "~/.codex/packages/standalone"],
      ["codex", "/usr/local/bin/codex", "station.updates.uninstallElsewhere", "按当初的安装方式卸载"],
      ["devin", "/opt/homebrew/bin/devin", "station.updates.uninstallElsewhere", "/opt/homebrew/bin/devin"],
      ["claude", "/opt/claude/bin/claude", "station.updates.uninstallElsewhere", "/opt/claude/bin/claude"],
    ];
    for (const [kind, real, key, words] of cases) {
      const how = await howToUninstallSoon(kind, found(real), env);
      assert.ok(how instanceof Unable, `${kind} at ${real}`);
      assert.equal(how.key, key, real);
      assert.ok(say(how).includes(words), say(how));
    }
  });
});

/// A station whose machine has Grok Build from npm in its own Node's prefix (its npm there removes it when `removes`,
/// else does nothing and ends well), and the Antigravity CLI's command.
function world(removes: boolean, more: Partial<UpdatesOptions> = {}) {
  const dir = temp();
  const node = join(dir, "node");
  const pkg = join(node, "lib/node_modules/@xai-official/grok");
  sh(join(pkg, "bin/grok"), "#!/bin/sh\necho 'grok 1.0.62 (1474f9cb)'\n");
  mkdirSync(join(node, "bin"), { recursive: true });
  symlinkSync("../lib/node_modules/@xai-official/grok/bin/grok", join(node, "bin/grok"));
  const asked = join(dir, "npm-asked");
  sh(join(node, "bin/npm"), `#!/bin/sh
echo "$*" >> "${asked}"
${removes ? `if [ "$1" = uninstall ]; then rm -rf "${pkg}" "${node}/bin/grok"; echo "removed 1 package"; fi` : ""}
exit 0
`);
  sh(join(dir, "bin/agy"), "#!/bin/sh\necho 'agy 1.0.0'\n");
  const app = join(dir, "app");
  mkdirSync(app, { recursive: true });
  writeFileSync(join(app, "BUILD"), "1300");
  const updates = new Updates({
    app, data: dir, config: new ConfigFile(dir), origin: () => "http://127.0.0.1:1", registry: "http://127.0.0.1:1", devinManifest: "http://127.0.0.1:1",
    env: { PATH: `${join(node, "bin")}:${join(dir, "bin")}:/usr/bin:/bin`, HOME: dir }, ...more,
  });
  return { updates, node, asked };
}

describe("removing a runtime from the software page", { skip: WINDOWS && "fake commands are shell scripts" }, () => {
  test("it goes the way it was installed, says 正在卸载 meanwhile, and is read again", async (t) => {
    let turns = 1;
    const changed: [string, boolean, boolean][] = [];
    const { updates, node, asked } = world(true, { runningOn: (kind) => (kind === "grok" ? turns : 0), runtimeChanged: (k, i, r) => changed.push([k, i, r]) });
    t.after(() => updates.close());
    await updates.check(false);
    const grok = () => updates.get("zh").find((v) => v.id === "grok")!;
    assert.deepEqual([grok().installed, grok().uninstallable, grok().version], [true, true, "1.0.62"]);
    assert.equal(updates.get("zh").find((v) => v.id === "station")!.uninstallable, false);
    // A turn running on it: refused, saying to wait for it.
    await assert.rejects(updates.uninstall("grok", "zh"), { message: "Grok Build 上还有对话正在回复，等这些回复结束后再卸载" });
    assert.equal(existsSync(asked), false, "nothing run");
    turns = 0;
    await updates.uninstall("grok", "zh");
    assert.deepEqual([grok().state, grok().progress], ["updating", "正在卸载"]);
    await assert.rejects(updates.uninstall("grok", "zh"), { message: "Grok Build 正在安装、更新或卸载，等它结束后再卸载" });
    await assert.rejects(updates.update("grok", "zh"), { message: "Grok Build 正在更新" });
    await until(() => grok().state !== "updating", t.signal);
    assert.deepEqual([grok().installed, grok().uninstallable, grok().state, grok().message], [false, false, "idle", undefined]);
    assert.equal(readFileSync(asked, "utf8"), `uninstall -g @xai-official/grok --prefix ${node}\n`);
    assert.deepEqual(changed, [["grok", false, false]]);
    // Gone: nothing more to remove.
    await assert.rejects(updates.uninstall("grok", "zh"), { message: "这台 Station 上没有安装 Grok Build" });
  });

  test("still found after its command ended well: failed, saying where", async (t) => {
    const changed: [string, boolean, boolean][] = [];
    const { updates, node } = world(false, { runtimeChanged: (k, i, r) => changed.push([k, i, r]) });
    t.after(() => updates.close());
    await updates.check(false);
    const grok = () => updates.get("zh").find((v) => v.id === "grok")!;
    await updates.uninstall("grok", "zh");
    await until(() => grok().state !== "updating", t.signal);
    assert.deepEqual([grok().installed, grok().state], [true, "failed"]);
    assert.equal(grok().message, `npm 已结束，但 station 仍能在 ${join(node, "bin/grok")} 找到 Grok Build：这台机器上可能还有另一份安装，请在这台机器上按那份的装法卸载`);
    assert.deepEqual(changed, [["grok", true, false]]);
  });

  test("refused where it cannot be removed from here, saying how; and for what is not a runtime", async (t) => {
    const { updates } = world(true);
    t.after(() => updates.close());
    await updates.check(false);
    const agy = updates.get("zh").find((v) => v.id === "agy")!;
    assert.deepEqual([agy.installed, agy.uninstallable], [true, false]);
    await assert.rejects(updates.uninstall("agy", "zh"), (e: Error) => e.message.includes("Antigravity CLI 没有官方卸载命令"));
    await assert.rejects(updates.uninstall("codex", "zh"), { message: "这台 Station 上没有安装 Codex" });
    await assert.rejects(updates.uninstall("station", "zh"), { message: "不存在 station" });
  });
});

describe("POST /updates/uninstall", () => {
  function rig(updates: Updates | null) {
    const table = routes({ updates });
    return async (body: unknown, role: string) => {
      const r: Request = {
        method: "POST", path: "/updates/uninstall", query: [], headers: {}, lang: "zh", body: Buffer.from(JSON.stringify(body)),
        viewer: { sub: "s", email: "m@x.com", name: "M", role, workspace: "ws", device: "d" },
      };
      const route = table.find((x) => x.method === "POST" && x.pattern.test("/updates/uninstall"))!;
      const a = await route.handle(r, []);
      return [a.status, JSON.parse(String(a.body))] as const;
    };
  }

  test("only a workspace's owner or admin may remove a runtime, as with updating one", async (t) => {
    const dir = temp();
    const app = join(dir, "app");
    mkdirSync(app, { recursive: true });
    writeFileSync(join(app, "BUILD"), "1300");
    const updates = new Updates({ app, data: dir, config: new ConfigFile(dir), origin: () => "http://127.0.0.1:1", registry: "http://127.0.0.1:1", devinManifest: "http://127.0.0.1:1", env: { PATH: "/nowhere" } });
    t.after(() => updates.close());
    const ask = rig(updates);
    assert.deepEqual(await ask({ id: "claude" }, "member"), [403, { error: "只有 workspace 的 owner 或管理员能更新 station 和它的运行时" }]);
    assert.deepEqual(await ask({ id: "claude" }, "admin"), [400, { error: "这台 Station 上没有安装 Claude Code" }]);
    assert.deepEqual(await ask({ id: "station" }, "owner"), [400, { error: "不存在 station" }]);
    // A station with nothing to update (a part not made) has nothing to remove either.
    assert.deepEqual(await rig(null)({ id: "claude" }, "owner"), [404, { error: tr("zh", "station.admin.updatesUnavailable") }]);
  });
});
