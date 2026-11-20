// What the admin's console shows of a cloud in use, made up and the same each run (dev.ts SEED=console): people, a
// company's workspace with an owner not signed in yet, stations, one in two workspaces, a machine that only runs tasks,
// codes, bug reports with logs and replies both ways, relays with their load, a way into one, tokens not used yet, the
// probes, and what the operators changed. Written straight into the Directory's tables (test/worker.ts seedConsole)
// and the relays' samples (RelayLoad seedLoad); a table a cloud from before has not is passed over, so the same seed
// shows a console from before beside this one.

type Sql = { exec(query: string, ...bindings: unknown[]): unknown };

const DAY = 86_400;
const station = (n: number) => `${"5e".repeat(28)}${String(n).padStart(8, "0")}`;
/** The ids the console's routes take (a report's: 26 of Crockford's base 32). */
export const SEED_IDS = { acme: "01JD3ACME00000000000000001", lab: "01JD3LAB000000000000000002", growth: "01JD3GROWTH000000000000003", star: "01JD3STAR00000000000000004" };
const ID = SEED_IDS;
const fb = (n: number) => `01JD3FB${String(n).padStart(19, "0")}`;

export const SEED_RELAYS = { own: "http://127.0.0.1:3340", hk: "https://hk.relay.example", entry: "https://bj.relay.example:8443" };

/** Runs each statement on its own: one a cloud from before has no table for is passed over. */
function run(sql: Sql, query: string, ...bindings: unknown[]): void {
  try {
    sql.exec(query, ...bindings);
  } catch {
    // (a table or a column this cloud has not yet)
  }
}

export function seedConsole(sql: Sql, now: number, admin: { sub: string; email: string }): void {
  const users: [string, string, string, number, number | null, string | null, number | null][] = [
    ["seed-bob", "bob@example.test", "Bob Lee", 40, 2, "code", 1],
    ["seed-wang", "wang@acme.cn", "王一凡", 21, 0.02, "granted", null],
    ["seed-chen", "chen@acme.cn", "陈晨", 20, 0.1, "invitation", 1],
    ["seed-mia", "mia@studio.io", "Mia Zhang", 9, 0.3, "code", null],
    ["seed-li", "li@lab.dev", "李雷", 3, 1, "invitation", null],
    ["seed-zoe", "zoe@gmail.com", "Zoe Ma", 1, null, null, null],
  ];
  for (const [sub, email, name, created, seen, admitted, beta] of users) {
    run(sql, "INSERT OR IGNORE INTO users (sub, email, name, picture, created_at, last_seen, admitted, beta) VALUES (?, ?, ?, '', ?, ?, ?, ?)",
      sub, email, name, now - created * DAY, seen === null ? null : now - Math.round(seen * DAY), admitted, beta);
  }
  run(sql, "INSERT OR IGNORE INTO pending (email, beta, may_create, added_by, added_at) VALUES ('newhire@acme.cn', 1, 0, ?, ?)", admin.sub, now - 2 * DAY);

  // A company's workspace (limits of its own), its CTO added and not signed in yet; a lab; one with no machine at all.
  run(sql, "INSERT INTO workspaces (id, name, created_by, created_at, max_members, max_stations) VALUES (?, 'Acme 研发', ?, ?, 20, 64)", ID.acme, admin.sub, now - 21 * DAY);
  run(sql, "INSERT INTO workspaces (id, name, created_by, created_at) VALUES (?, 'Mia 的实验室', 'seed-mia', ?)", ID.lab, now - 9 * DAY);
  run(sql, "INSERT INTO workspaces (id, name, created_by, created_at) VALUES (?, '增长', 'seed-bob', ?)", ID.growth, now - 30 * DAY);
  // A company's whose owner has not signed in yet: the admin puts its first station in.
  run(sql, "INSERT INTO workspaces (id, name, created_by, created_at, max_members, max_stations) VALUES (?, '星河科技', ?, ?, 50, 64)", ID.star, admin.sub, now - DAY);
  run(sql, "INSERT OR IGNORE INTO added (workspace, email, role, added_by, added_at) VALUES (?, 'ceo@xinghe.cn', 'owner', ?, ?)", ID.star, admin.sub, now - DAY);
  for (const [ws, sub, role, ago] of [[ID.acme, "seed-wang", "owner", 21], [ID.acme, "seed-chen", "member", 20], [ID.lab, "seed-mia", "owner", 9], [ID.lab, "seed-li", "member", 3], [ID.lab, "seed-chen", "member", 8], [ID.growth, "seed-bob", "owner", 30]] as const) {
    run(sql, "INSERT OR IGNORE INTO members (workspace, sub, role, added_at) VALUES (?, ?, ?, ?)", ws, sub, role, now - ago * DAY);
  }
  run(sql, "INSERT OR IGNORE INTO added (workspace, email, role, added_by, added_at) VALUES (?, 'cto@acme.cn', 'owner', ?, ?)", ID.acme, admin.sub, now - 2 * DAY);
  run(sql, "INSERT OR IGNORE INTO added (workspace, email, role, added_by, added_at) VALUES (?, 'ops@acme.cm', 'member', ?, ?)", ID.acme, admin.sub, now - DAY);
  run(sql, "INSERT INTO invitations (id, workspace, token_hash, role, email, created_by, expires_at) VALUES ('seed-inv-1', ?, 'seed-inv-hash-1', 'member', 'friend@gmail.com', 'seed-mia', ?)", ID.lab, now + 5 * DAY);

  // Stations: acme-build and acme-mac in both Acme and the lab (each one machine), the lab's own, and a rig in Acme and
  // in 增长 (one machine too).
  const machines: [number, number | null, string][] = [[1, 120, "0.1.9910"], [2, 3600, "0.1.9910"], [3, 9 * DAY, "0.1.9802"], [4, 600, "0.1.9911"]];
  for (const [n, seen, version] of machines) run(sql, "INSERT OR IGNORE INTO stations (id, last_seen, version) VALUES (?, ?, ?)", station(n), seen === null ? null : now - seen, version);
  const memberships: [string, number, string, number, string, number | null][] = [
    [ID.acme, 1, "acme-build", 20, "seed-wang", null],
    [ID.acme, 2, "acme-mac", 19, "seed-wang", null],
    [ID.lab, 1, "acme-build", 8, "seed-mia", null],
    [ID.lab, 3, "mbp", 9, "seed-mia", null],
    [ID.acme, 4, "ci-runner", 5, "seed-chen", 1],
    [ID.lab, 2, "acme-mac", 7, "seed-mia", null],
    [ID.growth, 4, "ci-runner", 4, "seed-bob", 1],
  ];
  for (const [ws, n, name, ago, by, rig] of memberships) {
    run(sql, "INSERT OR IGNORE INTO station_members (workspace, station, name, enrolled_at, enrolled_by, rig) VALUES (?, ?, ?, ?, ?, ?)", ws, station(n), name, now - ago * DAY, by, rig);
    // (a cloud from before rigs: the rig taken for a station there)
    if (rig !== null) run(sql, "INSERT OR IGNORE INTO station_members (workspace, station, name, enrolled_at, enrolled_by) VALUES (?, ?, ?, ?, ?)", ws, station(n), name, now - ago * DAY, by);
  }

  // Codes: two open, one used, one expired.
  const codes: [string, string, number, number, string | null, number | null][] = [
    ["ACME-2025-OPEN", "给 Acme 新同学", 1, 13, null, null],
    ["LAB2-INVT-MIAZ", "实验室扩招", 3, 4, null, null],
    ["USED-CODE-0001", "朋友", 12, 2, "seed-mia", 9],
    ["OLDX-CODE-0002", "展会", 40, -26, null, null],
  ];
  for (const [code, note, ago, left, usedBy, usedAgo] of codes) {
    run(sql, "INSERT OR IGNORE INTO invite_codes (code, note, created_by, created_at, expires_at, used_by, used_at, workspace) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      code, note, admin.sub, now - ago * DAY, now + left * DAY, usedBy, usedAgo === null ? null : now - usedAgo * DAY, usedBy === null ? null : ID.lab);
  }

  // Bug reports: one with thirty lines of logs and replies both ways, its reporter's the last word.
  const logs = Array.from({ length: 30 }, (_, i) => `2026-11-17T09:${String(12 + Math.floor(i / 6)).padStart(2, "0")}:${String((i * 7) % 60).padStart(2, "0")}Z ${i % 9 === 4 ? "ERROR" : "INFO "} chat_post ${i % 9 === 4 ? "502 from relay hk: upstream reset" : `sent seq=${4100 + i} bytes=${812 + i * 13}`}`).join("\n");
  const context = (session: string, ws: string) => JSON.stringify({ version: "0.1.9910", runtime: "claude", session, thread: `CHAT/1794.${session.slice(-1)}`, workspace: ws });
  const reports: [number, string, string, string, string, string | null, string | null, string | null, string | null, string | null, string, number, number][] = [
    [1, "安卓图标糊了", "启动页的图标在高分屏上发糊。", "android", "", null, null, "seed-zoe", null, null, "fixed", 20, 12],
    [2, "发送后消息消失", "## 步骤\n1. 在 Slack 线程里发一条\n2. 刷新页面\n\n## 结果\n消息不见了，过一会儿又出现。", "web", "Mia (Slack #lab)", station(1), ID.lab, null, context("chat:c-1", ID.lab), logs, "triaged", 2, 0.01],
    [3, "Slack 线程里 @ 不回", "在 #ops 线程里 @ 了 agent，没有任何回复，也没有「在 still.fail 中查看」的链接。", "slack", "李雷 (Slack #ops)", station(3), ID.lab, null, context("chat:c-3", ID.lab), null, "new", 0.2, 0.2],
    [4, "云端登录偶尔 502", "早上九点左右登录，连续两次 502，第三次才进去。", "cloud", "", null, null, "seed-chen", null, null, "new", 0.05, 0.05],
  ];
  for (const [n, title, body, area, reporter, st, ws, account, ctx, log, status, ago, updated] of reports) {
    run(sql, `INSERT OR IGNORE INTO feedback (id, number, key, channel, sender, station, workspace, account, title, body, area, reporter, context, logs, status, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      fb(n), n, `seed-${n}`, n === 2 ? "beta" : "stable", st ?? account ?? "seed", st, ws, account, title, body, area, reporter, ctx, log, status, now - Math.round(ago * DAY), now - Math.round(updated * DAY));
  }
  run(sql, "UPDATE feedback SET fixed_in = 9890 WHERE id = ?", fb(1));
  const replies: [string, number, string, string, string, number, number | null][] = [
    ["01JD3RE0000000000000000001", 2, "team", admin.email, "能发一下出错时的日志吗？另外是哪个浏览器？", 1.6, 1.5],
    ["01JD3RE0000000000000000002", 2, "reporter", "session:chat:c-1", "Chrome 131。日志已附在上面，刷新后稳定复现。", 0.01, null],
    ["01JD3RE0000000000000000003", 1, "team", "feedback-monitor", "已在 0.1.9890 修复，更新后再看看。", 12, 11.9],
  ];
  for (const [id, n, author, by, text, ago, delivered] of replies) {
    run(sql, "INSERT OR IGNORE INTO feedback_replies (id, feedback, author, by, text, created_at, delivered_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      id, fb(n), author, by, text, now - Math.round(ago * DAY), delivered === null ? null : now - Math.round(delivered * DAY));
  }

  // The relays: Hong Kong, put on by its token, and a way into it from Beijing; two tokens not used yet.
  run(sql, "INSERT OR IGNORE INTO relays (url, name, target, secret_hash, added_at, added_by) VALUES (?, '香港', NULL, 'seed-secret', ?, ?)", SEED_RELAYS.hk, now - 10 * DAY, `token:${admin.email}`);
  run(sql, "INSERT OR IGNORE INTO relays (url, name, target, secret_hash, added_at, added_by) VALUES (?, '北京入口', ?, NULL, ?, ?)", SEED_RELAYS.entry, SEED_RELAYS.hk, now - 6 * DAY, admin.email);
  run(sql, "INSERT OR IGNORE INTO relay_tokens (token_hash, name, url, target, made_by, expires_at) VALUES (?, '东京 2', NULL, NULL, ?, ?)", "a1b2c3d4e5f60718".padEnd(64, "0"), admin.email, now + 20 * 3600);
  run(sql, "INSERT OR IGNORE INTO relay_tokens (token_hash, name, url, target, made_by, expires_at) VALUES (?, '上海入口', NULL, ?, ?, ?)", "f0e1d2c3b4a59687".padEnd(64, "0"), SEED_RELAYS.hk, admin.email, now + 3 * 3600);

  // Admin API keys: one active & recently used, one active & never used / never expires, one revoked.
  const keys: [string, string, string, string, number, number | null, number | null, number | null][] = [
    ["ak_01JD3KEY00000000000000001", "日常运维 CLI", "sfa_9xKmP2qR", "seed-key-hash-1", 14, 76, 0.02, null],
    ["ak_01JD3KEY00000000000000002", "CI 发布脚本", "sfa_4tBnV8wL", "seed-key-hash-2", 5, null, null, null],
    ["ak_01JD3KEY00000000000000003", "旧笔记本临时密钥", "sfa_7hZpQ1mN", "seed-key-hash-3", 45, 45, 20, 10],
  ];
  for (const [id, name, prefix, hash, ago, left, usedAgo, revokedAgo] of keys) {
    run(sql, "INSERT OR IGNORE INTO admin_keys (id, name, prefix, key_hash, created_by, created_by_email, created_at, expires_at, last_used_at, revoked_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      id, name, prefix, hash, admin.sub, admin.email, now - ago * DAY, left === null ? null : now + left * DAY, usedAgo === null ? null : now - Math.round(usedAgo * DAY), revokedAgo === null ? null : now - revokedAgo * DAY);
  }

  // What the operators changed (a cloud from before keeps none).
  const audit: [number, string, string, string, string][] = [
    [0.004, admin.email, "feedback.reply", "FB-2", ""],
    [0.02, "feedback-monitor", "feedback.status", "FB-2", "triaged"],
    [0.15, admin.email, "key.create", "CI 发布脚本", "sfa_4tBnV8wL · never"],
    [0.3, admin.email, "relay.token", "上海入口", SEED_RELAYS.hk],
    [0.8, admin.email, "user.beta", "chen@acme.cn", "on"],
    [1, admin.email, "workspace.limits", "Acme 研发", "members=20"],
    [2, admin.email, "workspace.owners", "Acme 研发", "cto@acme.cn"],
    [2.1, admin.email, "pending.set", "newhire@acme.cn", "beta=on"],
    [3, "admin-token", "relay.put", "北京入口", SEED_RELAYS.entry],
    [4, admin.email, "code.create", "LAB2-INVT-MIAZ", "实验室扩招 · days=7"],
    [6, admin.email, "user.block", "spam@mailinator.com", "on"],
  ];
  audit.forEach(([ago, actor, action, target, detail], i) => {
    run(sql, "INSERT OR IGNORE INTO admin_audit (id, created_at, actor, action, target, detail) VALUES (?, ?, ?, ?, ?, ?)", `01JD3AU${String(i).padStart(19, "0")}`, now - Math.round(ago * DAY), actor, action, target, detail);
  });
}

/** A day of a relay's counters, a sample a minute: busy by day, quiet at night, what it dropped up for an hour. */
export function relaySamples(now: number, scale: number, seed: number): { at: number; load: Record<string, number> }[] {
  const out: { at: number; load: Record<string, number> }[] = [];
  let sent = 0, recv = 0, packets = 0, dropped = 0, accepts = 0, frames = 0;
  let x = seed;
  const random = () => ((x = (x * 16807) % 2147483647) / 2147483647);
  const start = now - DAY - 60;
  for (let at = start; at <= now; at += 60) {
    const hour = ((at % DAY) / 3600 + 8) % 24;
    const busy = 0.25 + 0.75 * Math.max(0, Math.sin(((hour - 7) / 16) * Math.PI));
    const rate = scale * busy * (0.8 + 0.4 * random());
    sent += Math.round(rate * 60);
    recv += Math.round(rate * 0.35 * 60);
    const p = Math.round(rate * 0.8);
    packets += p;
    // An hour in the afternoon where its queue overflowed.
    const spike = at > now - 6 * 3600 && at < now - 5 * 3600;
    dropped += Math.round(p * (spike ? 0.06 + 0.04 * random() : 0.002 + 0.004 * random()));
    frames += p;
    accepts += Math.round(busy * 3);
    const open = Math.round(20 + 50 * busy);
    out.push({ at, load: { sent, recv, frames, packets, dropped, accepts, disconnects: Math.max(0, accepts - open), rx: sent * 1.1, tx: recv * 1.1, load1: 0.2 + busy } });
  }
  return out;
}

/** What the probes found of each relay, as Globalping's lines say it. */
export function probeLines(relay: "own" | "hk"): Record<string, unknown>[] {
  const line = (network: string, country: string, city: string, rtt: number | null, loss: number) => ({
    probe_country: country, probe_region: "", probe_city: city, probe_asn: 4134, probe_network: network, ...(rtt === null ? {} : { rtt_avg: rtt, rtt_min: rtt * 0.8, rtt_max: rtt * 1.4 }), loss, status: "finished",
  });
  return relay === "hk"
    ? [line("China Mobile", "CN", "Guangzhou", 42, 0), line("China Mobile", "CN", "Beijing", 61, 0), line("Chinanet", "CN", "Shanghai", 38, 0), line("China Unicom", "CN", "Beijing", 55, 2), line("HKBN", "HK", "Hong Kong", 3, 0), line("Aliyun", "CN", "Hangzhou", 33, 0)]
    : [line("China Mobile", "CN", "Guangzhou", 196, 3), line("Chinanet", "CN", "Shanghai", 248, 12), line("China Unicom", "CN", "Beijing", null, 100), line("HKBN", "HK", "Hong Kong", 9, 0)];
}
