// The real bridge runs these hooks and sends these bytes under a PTY on all three systems.
import { spawn } from "node:child_process";
import { writeFile } from "node:fs/promises";

export async function run(settings, session, dump, mcp) {
  process.stdin.setRawMode(true);
  async function hook(event, fields = {}) {
    const { command, args } = settings.hooks[event].at(-1).hooks[0];
    const proc = spawn(command, args, { stdio: ["pipe", "ignore", "inherit"] });
    const ended = new Promise((resolve, reject) => {
      proc.on("error", reject);
      proc.on("close", code => code === 0 ? resolve() : reject(new Error("hook exit " + code)));
    });
    proc.stdin.end(JSON.stringify({ session_id: session, hook_event_name: event, ...fields }));
    await ended;
  }
  await hook("SessionStart", { source: "startup" });
  const tools = spawn(mcp.command, mcp.args, { stdio: ["pipe", "pipe", "inherit"] });
  tools.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" }) + "\n");
  tools.stdout.resume();
  process.stdin.setEncoding("utf8");
  let buf = "";
  for await (const chunk of process.stdin) {
    if (chunk === "\x02") {
      await hook("Stop");
      continue;
    }
    buf += chunk;
    if (!buf.endsWith("\x1b[201~\r")) continue;
    const text = buf.slice("\x1b[200~".length, -"\x1b[201~\r".length);
    buf = "";
    await hook("UserPromptSubmit", { prompt: text });
    await writeFile(dump + ".prompt", text);
    if (text.includes("hold this turn")) continue;
    if (text === "/compact") await hook("PostCompact");
    else if (text.includes("rate limited")) await hook("StopFailure", { error: "rate_limit", error_details: "429 rate limit exceeded" });
    else await hook("Stop");
  }
}
