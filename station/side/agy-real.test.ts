// End-to-end check against the real Antigravity CLI (`agy acp`), pointed at a local 127.0.0.1 Gemini + MCP server so no
// account or allowance is touched (`pnpm test:side`, skipped where `agy` is not installed):
// - shared and symlinked preset skills (`.agents/skills/<name>` outside `cwd`, which `agy` 1.5.9's `pinnedEvalSymlinks`
//   skips) reach the real CLI's `<skills>` block in `systemInstruction` without adding shared directories to
//   `Active Workspaces`;
// - `--gemini-dir/config/hooks.json` stays active on a shared profile home even when an instructions-less session opens
//   concurrently on the same profile (`STILLFAIL_REPO_RULES=0` silences only that session's hook process), while the
//   station session fires `PostToolUse` + `PostInvocation` on `read_file` and injects `.claude/CLAUDE.md` + `CLAUDE.md`.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import http from "node:http";
import { homedir, tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { after, test } from "node:test";
import { AgyDriver } from "../src/agents/agy.ts";
import type { RuntimeEvent } from "../src/agents/runtime.ts";

function findAgy(): string | null {
  const dirs = [
    ...(process.env.PATH ?? "").split(delimiter),
    join(homedir(), ".local", "bin"),
    "/opt/homebrew/bin",
    "/usr/local/bin",
  ];
  for (const d of dirs) {
    if (!d) continue;
    const candidate = join(d, process.platform === "win32" ? "agy.exe" : "agy");
    if (!existsSync(candidate)) continue;
    try {
      execFileSync(candidate, ["--version"], { stdio: "ignore", timeout: 5000 });
      return candidate;
    } catch {}
  }
  return null;
}

const agyBin = findAgy();
const root = mkdtempSync(join(tmpdir(), "agy-real-side-"));
after(() => rmSync(root, { recursive: true, force: true }));

test(
  "real Antigravity CLI loads materialized workspace & preset skills, injects CLAUDE.md rules, and isolates concurrent instructions-less sessions on the same profile",
  { skip: agyBin === null && "no agy here", timeout: 60_000 },
  async () => {
    const wsRaw = join(root, "ws");
    const termWsRaw = join(root, "term-ws");
    mkdirSync(wsRaw, { recursive: true });
    mkdirSync(termWsRaw, { recursive: true });
    const ws = realpathSync(wsRaw);
    const termWs = realpathSync(termWsRaw);

    const shared = join(root, "shared-skills");
    const preset = join(root, "preset-skills");
    mkdirSync(join(shared, "team-skill", "scripts"), { recursive: true });
    writeFileSync(join(shared, "team-skill", "SKILL.md"), "---\nname: team-skill\ndescription: Shared workspace skill ALPHA_SKILL_MARKER\n---\n# Team\n");
    writeFileSync(join(shared, "team-skill", "scripts", "run.sh"), "#!/bin/sh\necho ok\n");
    mkdirSync(join(preset, "deploy"), { recursive: true });
    writeFileSync(join(preset, "deploy", "SKILL.md"), "---\nname: deploy\ndescription: Preset symlink skill BETA_SKILL_MARKER\n---\n# Deploy\n");
    mkdirSync(join(ws, ".agents", "skills"), { recursive: true });
    symlinkSync(join(preset, "deploy"), join(ws, ".agents", "skills", "deploy"), "dir");

    const makeRepo = (base: string) => {
      const ccRepo = join(base, "cc-only");
      mkdirSync(join(ccRepo, ".git"), { recursive: true });
      mkdirSync(join(ccRepo, ".claude"), { recursive: true });
      mkdirSync(join(ccRepo, "web", "src"), { recursive: true });
      writeFileSync(join(ccRepo, ".claude", "CLAUDE.md"), "ROOT_DOTCLAUDE_FALCON");
      writeFileSync(join(ccRepo, "web", "CLAUDE.md"), "WEB_CLAUDE_SWIFT");
      const file = join(ccRepo, "web", "src", "page.tsx");
      writeFileSync(file, "export const ok = true;\n");
      return file;
    };
    const pageFile = makeRepo(ws);
    const termPageFile = makeRepo(termWs);

    const mainReqs: any[] = [];
    const termReqs: any[] = [];
    const server = http.createServer(async (req, res) => {
      let body = "";
      for await (const chunk of req) body += chunk;
      const url = req.url ?? "";
      if (url.startsWith("/mcp")) {
        const rpc = body ? JSON.parse(body) : {};
        res.writeHead(200, { "Content-Type": "application/json" });
        if (rpc.method === "initialize") {
          res.end(JSON.stringify({ jsonrpc: "2.0", id: rpc.id, result: { protocolVersion: "2024-11-05", capabilities: { tools: {} }, serverInfo: { name: "stillfail", version: "0.1.0" } } }));
        } else if (rpc.method === "tools/list") {
          res.end(JSON.stringify({ jsonrpc: "2.0", id: rpc.id, result: { tools: [] } }));
        } else {
          res.end(JSON.stringify({ jsonrpc: "2.0", id: rpc.id ?? null, result: {} }));
        }
        return;
      }
      if (!url.includes("streamGenerateContent")) {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end("{}");
        return;
      }
      const parsed = JSON.parse(body);
      const isAux = url.includes("flash-lite");
      const isStation = JSON.stringify(parsed.systemInstruction ?? {}).includes("STATION_APPENDED_INSTRUCTIONS_MARKER");
      const bucket = isStation ? mainReqs : termReqs;
      let parts: any[];
      if (isAux) {
        parts = [{ text: "Side test" }];
      } else if (bucket.length === 0) {
        bucket.push(parsed);
        parts = [{ functionCall: { name: "read_file", args: { Path: isStation ? pageFile : termPageFile } } }];
      } else {
        bucket.push(parsed);
        parts = [{ text: "All done." }];
      }
      res.writeHead(200, { "Content-Type": "text/event-stream" });
      res.end(
        `data: ${JSON.stringify({
          candidates: [{ content: { role: "model", parts }, finishReason: "STOP" }],
          usageMetadata: { promptTokenCount: 100, candidatesTokenCount: 10, totalTokenCount: 110 },
        })}\n\n`,
      );
    });
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
    const port = (server.address() as { port: number }).port;

    const sharedProfile = {
      id: "ag-real",
      runtime: "agy" as const,
      home: join(root, "home"),
      access: { kind: "api-provider", provider: "google", key: "fake-local-key" },
      env: { GOOGLE_GEMINI_BASE_URL: `http://127.0.0.1:${port}` },
    };
    const driver = new AgyDriver({ data: join(root, "data"), command: agyBin! });
    const events: RuntimeEvent[] = [];
    const termEvents: RuntimeEvent[] = [];
    const waitTurn = async (ev: RuntimeEvent[]) => {
      const deadline = Date.now() + 30_000;
      while (!ev.some((e) => e.type === "turnEnded")) {
        if (Date.now() > deadline) throw new Error(`timed out waiting for turnEnded; events=${JSON.stringify(ev)}`);
        await new Promise((r) => setTimeout(r, 25));
      }
      assert.deepEqual(ev.find((e) => e.type === "turnEnded"), { type: "turnEnded", outcome: { kind: "completed" } });
    };
    try {
      const session = await driver.open(
        {
          key: "side-agy-real",
          profile: sharedProfile,
          cwd: ws,
          skills: shared,
          instructions: "STATION_APPENDED_INSTRUCTIONS_MARKER",
          mcpToken: "tok",
          mcpUrl: `http://127.0.0.1:${port}/mcp`,
          route: "side",
        },
        (e) => events.push(e),
      );
      const termSession = await driver.open(
        {
          key: "side-agy-term",
          profile: sharedProfile,
          cwd: termWs,
          instructions: "",
          mcpToken: "tok",
          mcpUrl: `http://127.0.0.1:${port}/mcp`,
          route: "side-term",
        },
        (e) => termEvents.push(e),
      );
      try {
        // Run the instructions-less session first on the same profile home, then the station session: neither breaks the other.
        await termSession.prompt("Read cc-only/web/src/page.tsx");
        await waitTurn(termEvents);

        await session.prompt("Read cc-only/web/src/page.tsx");
        await waitTurn(events);
      } finally {
        await termSession.dispose();
        await session.dispose();
      }
    } finally {
      await driver.shutdown();
      await new Promise<void>((r) => server.close(() => r()));
    }

    assert.equal(termReqs.length, 2);
    assert.equal(JSON.stringify(termReqs[1].contents ?? []).includes("ROOT_DOTCLAUDE_FALCON"), false, "instructions-less session stays silent");

    assert.equal(mainReqs.length, 2);
    const sys = JSON.stringify(mainReqs[0].systemInstruction ?? {});
    assert.match(sys, /ALPHA_SKILL_MARKER/);
    assert.match(sys, /BETA_SKILL_MARKER/);
    assert.match(sys, /STATION_APPENDED_INSTRUCTIONS_MARKER/);
    assert.equal(sys.includes(shared), false, "shared skills dir is not added to Active Workspaces");
    assert.equal(sys.includes(preset), false, "preset skills dir is not added to Active Workspaces");

    const secondContents = JSON.stringify(mainReqs[1].contents ?? []);
    assert.match(secondContents, /cc-only\/\.claude\/CLAUDE\.md[\s\S]*ROOT_DOTCLAUDE_FALCON/);
    assert.match(secondContents, /cc-only\/web\/CLAUDE\.md[\s\S]*WEB_CLAUDE_SWIFT/);
  },
);
