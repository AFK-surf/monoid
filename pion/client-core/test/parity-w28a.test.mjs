// W28a Differential Parity & Contract Verification Suite (`parity-w28a.test.mjs`):
//   1. `store::list_workspace_stations_merged` + all views (`project_stations`, `project_models`,
//      `project_profiles`, `project_settings`, `project_station_updates`, `project_workspace_marks`,
//      and `protocol` `stations.list`): fresh device empty `station` table + live overview merge
//      + strict cross-workspace isolation (Gate #9).
//   2. `SafeModeView` `lock_corrupt`: non-degrading locked state, explicit recovery actions,
//      zero 「个人锁」 leakage, and `TOPIC_SHAPES.lock` conformance.
//   3. `auth.complete` `{query}`: 1:1 differential parity with `client/core-ts/src/accounts.ts`
//      (`parseQuery` / `decodeComponent`), `error` + `error_description`, CSRF `state` check,
//      one-shot consumption, and zero PKCE `verifier` leakage to UI.
//   4. `chat` topic `{station, session, compact}` + `moved` multi-hop transparent resolution &
//      cycle detection (`views::project_chat_by_params` + `protocol::Slice1Router`).
//   5. `project_status`, `project_lock_prompts`, `project_notices`, `project_notify`, `project_doing`
//      verified directly against `client/core-ts/src/conform.ts` + `TOPIC_SHAPES`.
//
// Compiles a temporary native Pion driver in `os.tmpdir()` (zero edits to `parity_cli`) and
// cleans up all temporary artifacts in `after()`.

import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";

import { decodeComponent as tsDecodeComponent, parseQuery as tsParseQuery } from "../../../client/core-ts/src/accounts.ts";
import { conform } from "../../../client/core-ts/src/conform.ts";
import { AccountDb } from "../../../client/core-ts/src/db/account.ts";
import { Runner } from "../../../client/core-ts/src/runtime.ts";
import { TOPIC_SHAPES } from "../../../client/core-ts/src/shapes/schema.ts";
import { TestTime } from "../../../client/core-ts/src/testing.ts";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "../../..");
const clientCoreRoot = path.join(repoRoot, "pion/client-core");
const pioncBin = process.env.PIONC || path.join(os.homedir(), ".pion/bin/pionc");

function makeNodeSql(dbPath = ":memory:") {
  const db = new DatabaseSync(dbPath);
  const stmts = new Map();
  const stmt = (sql) => {
    let s = stmts.get(sql);
    if (!s) {
      s = db.prepare(sql);
      stmts.set(sql, s);
    }
    return s;
  };
  return {
    raw: db,
    exec(sql) {
      db.exec(sql);
    },
    run(sql, params = []) {
      const r = stmt(sql).run(...params);
      return Number(r.changes ?? 0);
    },
    all(sql, params = []) {
      const s = stmt(sql);
      s.setReturnArrays(true);
      return s.all(...params);
    },
    close() {
      stmts.clear();
      db.close();
    },
  };
}

function makeDummyDerive() {
  return {
    tone: () => null,
    asks: () => false,
    state: () => "idle",
    watched: () => false,
  };
}

const DRIVER_MAIN_PION = `// Temporary native Pion driver for parity-w28a.test.mjs
import "base_codec"
import "effect"
import "protocol"
import "shell"
import "sql"
import "store"
import "views"

fn j_str(j : base_codec::Json, k : String) -> String {
  match base_codec::json_get(j, k) {
    Some(base_codec::Json::Str(s)) => s
    _ => ""
  }
}

fn j_bool(j : base_codec::Json, k : String) -> Bool {
  match base_codec::json_get(j, k) {
    Some(base_codec::Json::Bool(b)) => b
    _ => false
  }
}

fn make_rpc_sql(world : World) -> sql::Sql {
  let rt = effect::Runtime::new()
  let sh = shell::Shell::stood_in(
    rt,
    fn(_id : Int64, _op : String, _args : base_codec::Json, _bytes : Option[Bytes]) -> Unit {},
    fn(op : String, args : base_codec::Json) -> shell::AskResult {
      let req = base_codec::json_obj([
        ("sqlReq", base_codec::json_obj([("op", base_codec::json_str(op)), ("args", args)])),
      ])
      io_println(world, base_codec::json_stringify(req))
      match io_read_line(world) {
        None => shell::AskResult::Err(shell::ShellError::{ message: "host eof" })
        Some(line) => {
          match base_codec::json_parse(line) {
            base_codec::JsonParseResult::Err(e) => shell::AskResult::Err(shell::ShellError::{ message: "bad host reply: " + e })
            base_codec::JsonParseResult::Ok(j) => {
              match base_codec::json_get(j, "err") {
                Some(base_codec::Json::Str(es)) => shell::AskResult::Err(shell::ShellError::{ message: es })
                _ => {
                  match base_codec::json_get(j, "ok") {
                    Some(v) => shell::AskResult::Ok(v)
                    None => shell::AskResult::Ok(base_codec::json_null())
                  }
                }
              }
            }
          }
        }
      }
    },
    fn(n : Int) -> Bytes { Bytes::new(n) },
  )
  match sql::Sql::open(sh, "w28a.db") {
    sql::SqlResult::Ok(d) => d
    sql::SqlResult::Err(e) => panic("open failed: " + e.to_string())
  }
}

fn op_stations_merged(world : World, args : base_codec::Json) -> base_codec::Json {
  let db = make_rpc_sql(world)
  let ws = j_str(args, "workspace")
  let merged = match store::list_workspace_stations_merged(db, ws) {
    sql::SqlResult::Ok(rs) => rs
    sql::SqlResult::Err(e) => return base_codec::json_obj([("error", base_codec::json_str(e.to_string()))])
  }
  let merged_arr : Array[base_codec::Json] = []
  for i in 0..<merged.length() {
    let r = merged[i]
    let doc = match base_codec::json_parse(r.json) {
      base_codec::JsonParseResult::Ok(j) => j
      base_codec::JsonParseResult::Err(_) => base_codec::json_null()
    }
    merged_arr.push(base_codec::json_obj([
      ("address", base_codec::json_str(r.address)),
      ("doc", doc),
    ]))
  }
  let stations_view = match views::project_stations(db, ws) {
    sql::SqlResult::Ok(v) => v
    sql::SqlResult::Err(e) => return base_codec::json_obj([("error", base_codec::json_str(e.to_string()))])
  }
  let models_view = match views::project_models(db, ws, []) {
    sql::SqlResult::Ok(v) => v
    sql::SqlResult::Err(e) => return base_codec::json_obj([("error", base_codec::json_str(e.to_string()))])
  }
  let profiles_view = match views::project_profiles(db, ws) {
    sql::SqlResult::Ok(v) => v
    sql::SqlResult::Err(e) => return base_codec::json_obj([("error", base_codec::json_str(e.to_string()))])
  }
  let settings_view = match views::project_settings(db, ws) {
    sql::SqlResult::Ok(v) => v
    sql::SqlResult::Err(e) => return base_codec::json_obj([("error", base_codec::json_str(e.to_string()))])
  }
  let updates_view = match views::project_station_updates(db, ws, 1700000000000L) {
    sql::SqlResult::Ok(v) => v
    sql::SqlResult::Err(e) => return base_codec::json_obj([("error", base_codec::json_str(e.to_string()))])
  }
  let marks_view = match views::project_workspace_marks(db, "alice@example.com") {
    sql::SqlResult::Ok(v) => v
    sql::SqlResult::Err(e) => return base_codec::json_obj([("error", base_codec::json_str(e.to_string()))])
  }
  let router = protocol::Slice1Router::new(db, store::MdStore::new(db, ws + "/st-a"), workspace=ws)
  let proto_stations = match router.handle(protocol::CoreRequest::Call(1L, "stations.list", base_codec::json_obj([("workspace", base_codec::json_str(ws))]), None)) {
    Some(protocol::CoreEvent::Ok(_, v, _)) => v
    _ => base_codec::json_null()
  }
  base_codec::json_obj([
    ("merged", base_codec::json_arr(merged_arr)),
    ("stationsView", stations_view),
    ("modelsView", models_view),
    ("profilesView", profiles_view),
    ("settingsView", settings_view),
    ("updatesView", updates_view),
    ("marksView", marks_view),
    ("protoStations", proto_stations),
  ])
}

fn op_safe_mode_corrupt(world : World, args : base_codec::Json) -> base_codec::Json {
  let db = make_rpc_sql(world)
  let kind = match base_codec::json_get(args, "deviceKind") {
    Some(base_codec::Json::Str(s)) => s
    _ => "app"
  }
  let inp = views::SafeModeInput::{
    available: true,
    viewer_sub: "u-owner",
    viewer_role: "owner",
    device_id: "dev-owner-1",
    device_kind: kind,
    device_sign_key: Some("ed25519:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
    personal_standing: "member",
    signer_unsaid: false,
    no_device_answered: false,
    rebound_admins: [],
    station_names: Map::new(),
    online_stations: Map::new(),
    pending: views::LockPendingQueue::new(),
  }
  let sm = views::project_safe_mode(None, inp, lock_corrupt=true)
  let vaults = match views::project_vaults(db, "ws-1", sm, true, true) {
    sql::SqlResult::Ok(v) => v
    sql::SqlResult::Err(e) => base_codec::json_obj([("error", base_codec::json_str(e.to_string()))])
  }
  base_codec::json_obj([
    ("safeMode", sm.to_json()),
    ("vaults", vaults),
  ])
}

fn op_auth_query(args : base_codec::Json) -> base_codec::Json {
  let q = j_str(args, "query")
  let decoded = views::decode_query_component(j_str(args, "component"))
  let pairs = views::parse_oauth_query(q)
  let pairs_j : Array[base_codec::Json] = []
  for i in 0..<pairs.length() {
    pairs_j.push(base_codec::json_arr([
      base_codec::json_str(pairs[i].0),
      base_codec::json_str(pairs[i].1),
    ]))
  }
  let m = views::LoginFlowMachine::new()
  let expected_state = j_str(args, "expectedState")
  let verifier = j_str(args, "verifier")
  let return_to = j_str(args, "returnTo")
  if expected_state.length() > 0 {
    let _ = m.begin_oauth("https://cloud.still.fail", expected_state, verifier, "http://127.0.0.1:4321/cb", return_to, "Mac")
  }
  let out = m.complete_oauth_query(q)
  base_codec::json_obj([
    ("decodedComponent", base_codec::json_str(decoded)),
    ("pairs", base_codec::json_arr(pairs_j)),
    ("outcome", base_codec::json_obj([
      ("ok", base_codec::json_bool(out.ok)),
      ("code", base_codec::json_str(out.code)),
      ("verifier", base_codec::json_str(out.verifier)),
      ("redirectUri", base_codec::json_str(out.redirect_uri)),
      ("returnTo", base_codec::json_str(out.return_to)),
      ("errorCode", base_codec::json_str(out.error_code)),
      ("recoveryHint", base_codec::json_str(out.recovery_hint)),
    ])),
    ("uiJson", out.to_ui_json()),
    ("machineJson", m.to_json()),
  ])
}

fn op_chat_moved_compact(world : World, args : base_codec::Json) -> base_codec::Json {
  let db = make_rpc_sql(world)
  let station = j_str(args, "station")
  let session = j_str(args, "session")
  let compact = j_bool(args, "compact")
  let view_j = match views::project_chat_by_params(
    db,
    station,
    None,
    Some(session),
    compact,
    "alice@example.com",
    1700000060000L,
  ) {
    sql::SqlResult::Ok(v) => v
    sql::SqlResult::Err(e) => return base_codec::json_obj([("error", base_codec::json_str(e.to_string()))])
  }
  let router = protocol::Slice1Router::new(db, store::MdStore::new(db, station), workspace="ws-1")
  let proto_j = match router.handle(protocol::CoreRequest::Call(
    9L,
    "chat.open",
    base_codec::json_obj([
      ("station", base_codec::json_str(station)),
      ("session", base_codec::json_str(session)),
      ("compact", base_codec::json_bool(compact)),
    ]),
    None,
  )) {
    Some(protocol::CoreEvent::Ok(_, v, _)) => v
    Some(protocol::CoreEvent::Err(_, err)) => base_codec::json_obj([("error", base_codec::json_str(err.code + ": " + err.message))])
    _ => base_codec::json_null()
  }
  base_codec::json_obj([
    ("chatView", view_j),
    ("protoChatOpen", proto_j),
  ])
}

fn op_runtime_topics(world : World, _args : base_codec::Json) -> base_codec::Json {
  let db = make_rpc_sql(world)
  let now_ms = 1700000010000L
  let status_v = views::project_status(
    [
      views::StatusWaitEntry::{ place: Some("Studio"), what: "读取对话", connecting: false, since_ms: now_ms - 4500L, bytes: 12288L },
      views::StatusWaitEntry::{ place: Some("Studio"), what: "连接中", connecting: true, since_ms: now_ms - 3200L, bytes: 0L },
    ],
    [
      views::StatusDownSocket::{ since_ms: now_ms - 5000L, retry_at_ms: now_ms + 3000L, message: "network offline", tries: 2 },
    ],
    [
      views::StatusDbNote::{ kind: "full", detail: None },
    ],
    24576L,
    2000L,
    now_ms,
  )
  let lock_prompts_v = views::project_lock_prompts(
    [
      views::LockPairingPromptInput::{
        device: "dev-new-1",
        name: "Alice",
        email: "alice@example.com",
        kind: "app",
        label: "iPhone 16",
        code: "123456",
        device_text: "iPhone 16 · still.fail",
        device_code: Some("ABC-123"),
        build: Some("0.1.11200"),
        will_sign: Some(true),
        handover_vaults: [
          base_codec::json_obj([
            ("id", base_codec::json_str("v-1")),
            ("name", base_codec::json_str("Personal")),
            ("scope", base_codec::json_str("personal")),
            ("items", base_codec::json_int(4)),
            ("workspace", base_codec::json_str("ws-1")),
            ("workspaceName", base_codec::json_str("WS One")),
          ]),
        ],
        role_text: None,
        workspaces: [
          base_codec::json_obj([
            ("id", base_codec::json_str("ws-1")),
            ("name", base_codec::json_str("WS One")),
          ]),
        ],
        created_at: now_ms - 1000L,
        until: now_ms + 60000L,
        until_text: "14:05 前有效",
      },
    ],
    [
      views::VaultKeyAskInput::{
        workspace: "ws-1",
        workspace_name: "WS One",
        vault: "v-1",
        vault_name: "Personal",
        device: "dev-ask-1",
        device_text: "MacBook Pro · still.fail",
        device_code: Some("XYZ-789"),
        owner_name: Some("Alice"),
        owner_email: Some("alice@example.com"),
        is_own_device: Some(true),
        vault_scope: Some("personal"),
        vault_items: Some(4),
        safe_mode: Some(true),
        at: 1700000005L,
        at_text: "1 分钟前",
        dismissed: false,
      },
    ],
    now_ms,
  )
  let n1 = views::NoticeItemInput::{
    id: "n1",
    kind: "wait",
    station: "ws-1/st-a",
    workspace: "ws-1",
    station_id: "st-a",
    session: "s-1",
    thread: Some(10),
    seq: Some(3),
    title: "Deploy PR",
    body: "Please confirm staging deploy",
    tag: "ws-1/st-a/s-1",
    url: "/o/ws-1/st-a/s-1?message=3",
    at: now_ms - 2000L,
  }
  let n2 = views::NoticeItemInput::{
    id: "n2",
    kind: "failed",
    station: "ws-2/st-x",
    workspace: "ws-2",
    station_id: "st-x",
    session: "s-2",
    thread: Some(20),
    seq: Some(5),
    title: "Muted WS",
    body: "Should be muted in notify",
    tag: "ws-2/st-x/s-2",
    url: "/o/ws-2/st-x/s-2?message=5",
    at: now_ms - 1000L,
  }
  let sb50 = StringBuilder::new()
  for _i in 0..<50 {
    sb50.write_string("汉")
  }
  let sb150 = StringBuilder::new()
  for _i in 0..<150 {
    sb150.write_string("汉")
  }
  let n_cjk50 = views::NoticeItemInput::{
    id: "n-cjk50",
    kind: "message",
    station: "ws-1/st-a",
    workspace: "ws-1",
    station_id: "st-a",
    session: "s-cjk50",
    thread: Some(11),
    seq: Some(1),
    title: "CJK 50",
    body: sb50.to_string(),
    tag: "ws-1/st-a/s-cjk50",
    url: "/o/ws-1/st-a/s-cjk50",
    at: now_ms - 500L,
  }
  let n_cjk150 = views::NoticeItemInput::{
    id: "n-cjk150",
    kind: "message",
    station: "ws-1/st-a",
    workspace: "ws-1",
    station_id: "st-a",
    session: "s-cjk150",
    thread: Some(12),
    seq: Some(2),
    title: "CJK 150",
    body: sb150.to_string(),
    tag: "ws-1/st-a/s-cjk150",
    url: "/o/ws-1/st-a/s-cjk150",
    at: now_ms - 400L,
  }
  let notices_cjk = views::project_notices([n_cjk50, n_cjk150], Some("ws-1"))
  let notices_all = views::project_notices([n2, n1], None)
  let notices_ws1 = views::project_notices([n2, n1], Some("ws-1"))
  let notify_v = match views::project_notify(
    db,
    views::NotifyStateInput::{
      on: true,
      asked: true,
      push: true,
      kinds: views::NotifyKindsInput::{ wait: true, failed: true, done: "away", message: true, billed: false },
      preview: true,
      muted: ["ws-2"],
      permission: "granted",
      in_front: false,
    },
    [n1, n2],
  ) {
    sql::SqlResult::Ok(v) => v
    sql::SqlResult::Err(e) => base_codec::json_obj([("error", base_codec::json_str(e.to_string()))])
  }
  let doing_v = views::project_doing([
    views::DoingItemInput::{
      call: "chat.archive",
      params: [("station", "ws-1/st-a"), ("session", "s-1")],
      since: now_ms - 500L,
      stage: "running",
      error: None,
      note: None,
    },
  ])
  base_codec::json_obj([
    ("status", status_v),
    ("lockPrompts", lock_prompts_v),
    ("noticesAll", notices_all),
    ("noticesWs1", notices_ws1),
    ("noticesCjk", notices_cjk),
    ("notify", notify_v),
    ("doing", doing_v),
  ])
}

fn main(world : World) -> Unit {
  while true {
    match io_read_line(world) {
      None => break
      Some(line) => {
        if line.length() == 0 { continue }
        match base_codec::json_parse(line) {
          base_codec::JsonParseResult::Err(e) => {
            io_println(world, base_codec::json_stringify(base_codec::json_obj([("err", base_codec::json_str(e))])))
          }
          base_codec::JsonParseResult::Ok(req) => {
            let op = j_str(req, "op")
            let args = match base_codec::json_get(req, "args") {
              Some(a) => a
              None => base_codec::json_obj([])
            }
            let res = if op == "stationsMerged" {
              op_stations_merged(world, args)
            } else if op == "safeModeCorrupt" {
              op_safe_mode_corrupt(world, args)
            } else if op == "authQuery" {
              op_auth_query(args)
            } else if op == "chatMovedCompact" {
              op_chat_moved_compact(world, args)
            } else if op == "runtimeTopics" {
              op_runtime_topics(world, args)
            } else {
              base_codec::json_obj([("err", base_codec::json_str("unknown op: " + op))])
            }
            io_println(world, base_codec::json_stringify(base_codec::json_obj([("ok", res)])))
          }
        }
      }
    }
  }
}
`;

class W28aDriverClient {
  constructor(binPath) {
    this.proc = spawn(binPath, [], { stdio: ["pipe", "pipe", "inherit"] });
    this.buf = "";
    this.queue = [];
    this.activeSql = null;
    this.proc.stdout.setEncoding("utf8");
    this.proc.stdout.on("data", (chunk) => {
      this.buf += chunk;
      let nl;
      while ((nl = this.buf.indexOf("\n")) >= 0) {
        const line = this.buf.slice(0, nl).trim();
        this.buf = this.buf.slice(nl + 1);
        if (!line) continue;
        const msg = JSON.parse(line);
        if ("sqlReq" in msg) {
          this.handleSqlReq(msg.sqlReq);
          continue;
        }
        const pending = this.queue.shift();
        if (pending) pending.resolve(msg);
      }
    });
    this.proc.on("exit", (code) => {
      while (this.queue.length > 0) {
        this.queue.shift().reject(new Error(`w28a driver exited with code ${code}`));
      }
    });
  }

  handleSqlReq({ op, args }) {
    const reply = (obj) => this.proc.stdin.write(`${JSON.stringify(obj)}\n`);
    try {
      if (op === "sql.open") return reply({ ok: { id: 1 } });
      if (op === "sql.close") return reply({ ok: null });
      const sql = args?.sql ?? "";
      const params = Array.isArray(args?.params) ? args.params : [];
      if (op === "sql.exec") {
        this.activeSql.exec(sql);
        return reply({ ok: null });
      }
      if (op === "sql.run") return reply({ ok: this.activeSql.run(sql, params) });
      if (op === "sql.all") return reply({ ok: this.activeSql.all(sql, params) });
      return reply({ err: `unsupported sql op: ${op}` });
    } catch (e) {
      return reply({ err: String(e?.message ?? e) });
    }
  }

  call(op, args = {}, { sql = null } = {}) {
    this.activeSql = sql;
    return new Promise((resolve, reject) => {
      this.queue.push({
        resolve: (resp) => {
          this.activeSql = null;
          if ("err" in resp) reject(new Error(resp.err));
          else resolve(resp.ok);
        },
        reject: (err) => {
          this.activeSql = null;
          reject(err);
        },
      });
      this.proc.stdin.write(`${JSON.stringify({ op, args })}\n`);
    });
  }

  close() {
    this.proc.stdin.end();
    this.proc.kill();
  }
}

let tmpDir = null;
let driverBin = null;
let rpc = null;

before(() => {
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pion-w28a-driver-"));
  const srcDir = path.join(tmpDir, "src");
  fs.mkdirSync(srcDir, { recursive: true });
  const baseDir = path.join(repoRoot, "pion/base/packages");
  const rulesDir = path.join(repoRoot, "pion/rules/packages");
  const ccPkgs = path.join(clientCoreRoot, "packages");
  const toml = `[package]
name = "w28a_driver"
version = "0.1.0"

[workspace]
members = ["."]

[workspace.dependencies]
base64 = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "base64-v0.1.0", subdir = "packages/base64" }
effect = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "effect-v0.1.0", subdir = "packages/effect" }
crypto = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "crypto-v0.4.1", subdir = "packages/crypto" }
flate = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "flate-v0.1.0", subdir = "packages/flate" }
url = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "url-v0.1.0", subdir = "packages/url" }
time = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "time-v0.1.0", subdir = "packages/time" }
http1 = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "http1-v0.1.0", subdir = "packages/http1" }
json5 = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "json5-v0.1.0", subdir = "packages/json5" }
markdown = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "markdown-v0.3.0", subdir = "packages/markdown" }
regex = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "regex-v0.1.0", subdir = "packages/regex" }
base_codec = { path = "${baseDir}/base_codec" }
wire = { path = "${baseDir}/wire" }
shell = { path = "${baseDir}/shell" }
sql = { path = "${baseDir}/sql" }
mesh = { path = "${baseDir}/mesh" }
form = { path = "${rulesDir}/form" }
fork = { path = "${rulesDir}/fork" }
history = { path = "${rulesDir}/history" }
role = { path = "${rulesDir}/role" }
lock = { path = "${rulesDir}/lock" }
vault = { path = "${rulesDir}/vault" }
outbox = { path = "${ccPkgs}/outbox" }
store = { path = "${ccPkgs}/store" }
protocol = { path = "${ccPkgs}/protocol" }
core_abi = { path = "${ccPkgs}/core_abi" }
views = { path = "${ccPkgs}/views" }
sync = { path = "${ccPkgs}/sync" }

[dependencies]
base_codec = { workspace = true }
effect = { workspace = true }
protocol = { workspace = true }
shell = { workspace = true }
sql = { workspace = true }
store = { workspace = true }
views = { workspace = true }
`;
  fs.writeFileSync(path.join(tmpDir, "pion.toml"), toml, "utf8");
  fs.copyFileSync(path.join(clientCoreRoot, "pion.lock"), path.join(tmpDir, "pion.lock"));
  fs.writeFileSync(path.join(srcDir, "main.pion"), DRIVER_MAIN_PION, "utf8");

  driverBin = path.join(tmpDir, "w28a_driver");
  execFileSync(pioncBin, ["build", "-o", driverBin, tmpDir], {
    cwd: repoRoot,
    stdio: "inherit",
  });
  rpc = new W28aDriverClient(driverBin);
});

after(() => {
  if (rpc) rpc.close();
  if (tmpDir && fs.existsSync(tmpDir)) fs.rmSync(tmpDir, { recursive: true, force: true });
});

function openInitDb() {
  const time = new TestTime();
  const sqlObj = makeNodeSql(":memory:");
  const acct = new AccountDb("sub-w28a", "w28a-init", sqlObj, new Runner(time.clock), makeDummyDerive());
  acct.commitNow();
  return sqlObj;
}

test("W28a #1: list_workspace_stations_merged fresh-device empty station table, live overview merge & Gate #9 isolation", async () => {
  const sqlObj = openInitDb();
  try {
    // Seed ws-1 and ws-10 (prefix collision trap!) in `workspace` table, with EMPTY `station` table first.
    sqlObj.run("INSERT OR REPLACE INTO workspace (id, json, confirmed) VALUES (?, ?, ?)", [
      "ws-1",
      JSON.stringify({
        id: "ws-1",
        name: "WS One",
        stations: [
          { id: "st-a", name: "Alpha", emoji: "🚀", online: false },
          { id: "st-b", name: "Beta", online: false },
        ],
      }),
      1000,
    ]);
    sqlObj.run("INSERT OR REPLACE INTO workspace (id, json, confirmed) VALUES (?, ?, ?)", [
      "ws-10",
      JSON.stringify({
        id: "ws-10",
        name: "WS Ten",
        stations: [{ id: "st-secret", name: "SecretStation", online: true }],
      }),
      1000,
    ]);

    // Case A: fresh device with empty `station` table -> all views still see ws-1's 2 stations and ZERO ws-10 leakage!
    const emptyRes = await rpc.call("stationsMerged", { workspace: "ws-1" }, { sql: sqlObj });
    assert.equal(emptyRes.error, undefined);
    assert.deepEqual(
      emptyRes.merged.map((s) => s.address),
      ["ws-1/st-a", "ws-1/st-b"],
    );
    assert.deepEqual(
      emptyRes.stationsView.map((s) => s.station),
      ["ws-1/st-a", "ws-1/st-b"],
    );
    assert.deepEqual(
      emptyRes.protoStations.stations.map((s) => s.address),
      ["ws-1/st-a", "ws-1/st-b"],
    );
    // Conform `stations` topic against real `TOPIC_SHAPES.stations`!
    const confStationsEmpty = conform(TOPIC_SHAPES.stations, emptyRes.stationsView);
    assert.ok("ok" in confStationsEmpty, `stations shape mismatch: ${confStationsEmpty.error}`);
    assert.ok(!JSON.stringify(emptyRes).includes("st-secret"), "Gate #9: zero ws-10 leakage into ws-1 views");

    // Case B: live `station(addr, "overview")` arrives for ws-1/st-b and ws-10/st-secret.
    sqlObj.run("INSERT OR REPLACE INTO station (address, kind, json, confirmed) VALUES (?, ?, ?, ?)", [
      "ws-1/st-b",
      "overview",
      JSON.stringify({
        id: "st-b",
        name: "Beta Live",
        online: true,
        version: "0.1.11234",
        profiles: [
          {
            id: "p1",
            name: "Claude Sub",
            email: "alice@example.com",
            runtime: "claude",
            access: { kind: "subscription", apiKey: "SECRET_SHOULD_STRIP" },
            enabled: true,
            models: ["claude-opus-5-5"],
          },
        ],
        software: { updatable: true, newer: true, version: "0.1.11200", latest: "0.1.11234", channel: "beta" },
        overview: { automaticDecisions: { settings: { completion: { enabled: true }, archiveReview: { enabled: true } } } },
      }),
      2000,
    ]);
    sqlObj.run("INSERT OR REPLACE INTO station (address, kind, json, confirmed) VALUES (?, ?, ?, ?)", [
      "ws-10/st-secret",
      "overview",
      JSON.stringify({
        id: "st-secret",
        name: "Secret Live",
        online: true,
        profiles: [{ id: "p-sec", name: "Secret", runtime: "codex", access: { kind: "subscription" }, enabled: true, models: ["gpt-secret"] }],
      }),
      2000,
    ]);

    const liveRes = await rpc.call("stationsMerged", { workspace: "ws-1" }, { sql: sqlObj });
    assert.equal(liveRes.error, undefined);
    assert.deepEqual(
      liveRes.stationsView.map((s) => s.station),
      ["ws-1/st-a", "ws-1/st-b"],
    );
    assert.equal(liveRes.stationsView[0].name, "Alpha");
    assert.equal(liveRes.stationsView[0].emoji, "🚀");
    assert.equal(liveRes.stationsView[1].name, "Beta Live");
    assert.equal(liveRes.stationsView[1].online, true);
    assert.equal(liveRes.modelsView.models.length, 1);
    assert.equal(liveRes.modelsView.models[0].id, "claude-opus-5-5");
    assert.equal(liveRes.profilesView.items.length, 1);
    assert.ok(!JSON.stringify(liveRes.profilesView).includes("SECRET_SHOULD_STRIP"), "profiles strip secrets");
    assert.equal(liveRes.settingsView.decisionsOn, 1);
    assert.equal(liveRes.updatesView.offered, 1);
    assert.ok(!JSON.stringify(liveRes.stationsView).includes("st-secret"), "Gate #9: stationsView isolated");
    assert.ok(!JSON.stringify(liveRes.modelsView).includes("gpt-secret"), "Gate #9: modelsView isolated");
    assert.ok(!JSON.stringify(liveRes.profilesView).includes("p-sec"), "Gate #9: profilesView isolated");
  } finally {
    sqlObj.close();
  }
});

test("W28a #2: SafeModeView lock_corrupt non-degrading locked state, recovery actions, Law C & zero personal-lock leak", async () => {
  const sqlObj = openInitDb();
  try {
    const res = await rpc.call("safeModeCorrupt", { deviceKind: "app" }, { sql: sqlObj });
    const sm = res.safeMode;
    assert.equal(sm.locked, true, "corrupt lock MUST NOT silently degrade to unlocked");
    assert.equal(sm.lockCorrupt, true, "lockCorrupt exposed");
    assert.equal(sm.recoveryAction, "resync_safe_mode", "explicit recoveryAction exposed");
    assert.equal(sm.signs, false, "signing disabled while corrupt");
    assert.equal(sm.me.confirmed, false, "unconfirmed while corrupt");
    assert.equal(sm.me.waiting, true, "waiting while corrupt");
    assert.ok(typeof sm.me.stateText === "string" && sm.me.stateText.length > 0, "actionable stateText");
    assert.equal(sm.me.confirmText, undefined, "lock_corrupt MUST NOT occupy confirmText slot");
    assert.equal(sm.me.restartText, undefined, "lock_corrupt MUST NOT occupy restartText (lock.restartOwn) slot");
    assert.equal(sm.me.restartNoteText, undefined, "lock_corrupt MUST NOT occupy restartNoteText slot");
    assert.ok(!JSON.stringify(res).includes("个人锁"), "Law A/B/C: zero 「个人锁」 leakage");
    assert.ok(!JSON.stringify(res).includes("共享调试"), "zero 「共享调试」 leakage");

    // Law C check with `project_vaults`: unconfirmed corrupt lock keeps `vaults.locked == true`, `canSign == false`, no dead stateText.
    assert.equal(res.vaults.locked, true);
    assert.equal(res.vaults.canSign, false);
    assert.equal(res.vaults.stateText, undefined);

    // Conform against real `TOPIC_SHAPES.lock` and assert post-conform fields explicitly!
    const confLock = conform(TOPIC_SHAPES.lock, sm);
    assert.ok("ok" in confLock, `LockView shape mismatch: ${confLock.error}`);
    const conformed = confLock.ok;
    assert.equal(conformed.locked, true, "conformed locked MUST stay true");
    assert.equal(conformed.me.confirmed, false, "conformed me.confirmed MUST stay false");
    assert.equal(conformed.me.waiting, true, "conformed me.waiting MUST stay true");
    assert.ok(typeof conformed.me.stateText === "string" && conformed.me.stateText.length > 0, "conformed me.stateText non-empty");
    assert.ok(!conformed.me.stateText.includes("个人锁"), "conformed me.stateText zero 「个人锁」");
    assert.equal(conformed.me.restartText, undefined, "conformed me.restartText MUST be undefined");
    assert.equal(conformed.me.confirmText, undefined, "conformed me.confirmText MUST be undefined");
  } finally {
    sqlObj.close();
  }
});

test("W28a #3: auth.complete {query} 1:1 parity with core-ts accounts.ts, CSRF check & zero PKCE verifier leak", async () => {
  const queryVectors = [
    "?code=abc%2B123%2Fxyz&state=st+1",
    "??error=access_denied&error_description=User+denied+%E6%8E%88%E6%9D%83",
    "a=1&&b=&bare&bad=%2G%ZZ",
  ];
  for (const q of queryVectors) {
    const res = await rpc.call("authQuery", {
      query: q,
      component: "hello+world%21%E4%B8%AD%E6%96%87%2F%2B",
      expectedState: "",
      verifier: "",
      returnTo: "/",
    });
    assert.deepEqual(res.pairs, tsParseQuery(q), `parseQuery parity mismatch for ${q}`);
    assert.equal(res.decodedComponent, tsDecodeComponent("hello+world%21%E4%B8%AD%E6%96%87%2F%2B"));
  }

  // Error + untrusted phishing error_description: fixed message ONLY, NEVER reflect unverified error_description into UI!
  const errRes = await rpc.call("authQuery", {
    query: "?error=access_denied&error_description=PHISHING+Click+evil.example+%E9%92%93%E9%B1%BC",
    component: "",
    expectedState: "st-123",
    verifier: "pkce-secret-verifier-never-leak",
    returnTo: "/w/ws-1",
  });
  assert.equal(errRes.outcome.ok, false);
  assert.equal(errRes.outcome.errorCode, "login_failed");
  assert.ok(!errRes.outcome.recoveryHint.includes("PHISHING"), "unverified error_description must never enter recoveryHint");
  assert.ok(!JSON.stringify(errRes.uiJson).includes("PHISHING"), "unverified error_description must never enter to_ui_json()");
  assert.ok(!JSON.stringify(errRes.machineJson).includes("PHISHING"), "unverified error_description must never enter to_json()");
  assert.ok(!JSON.stringify(errRes.uiJson).includes("pkce-secret-verifier-never-leak"));
  assert.ok(!JSON.stringify(errRes.machineJson).includes("pkce-secret-verifier-never-leak"));

  // Explicit login_cancelled maps to login_cancelled with fixed message
  const cancelRes = await rpc.call("authQuery", {
    query: "?error=login_cancelled&error_description=PHISHING+cancel",
    component: "",
    expectedState: "st-cancel",
    verifier: "pkce-secret-verifier-cancel",
    returnTo: "/w/ws-1",
  });
  assert.equal(cancelRes.outcome.ok, false);
  assert.equal(cancelRes.outcome.errorCode, "login_cancelled");
  assert.ok(!JSON.stringify(cancelRes.uiJson).includes("PHISHING"));
  assert.ok(!JSON.stringify(cancelRes.machineJson).includes("PHISHING"));

  // CSRF state mismatch
  const csrfRes = await rpc.call("authQuery", {
    query: "?code=good-code&state=wrong-state",
    component: "",
    expectedState: "expected-state-42",
    verifier: "pkce-secret-verifier-csrf",
    returnTo: "/w/ws-1",
  });
  assert.equal(csrfRes.outcome.ok, false);
  assert.equal(csrfRes.outcome.errorCode, "login_state_mismatch");
  assert.ok(!JSON.stringify(csrfRes.uiJson).includes("pkce-secret-verifier-csrf"));

  // Happy path: returns internal (code, verifier, redirect_uri), sanitizes `/auth/*`, NEVER exposes verifier to UI!
  const okRes = await rpc.call("authQuery", {
    query: "?state=expected-state-99&code=code%2Fwith%2Bspecial%3Dchars",
    component: "",
    expectedState: "expected-state-99",
    verifier: "pkce-secret-verifier-999",
    returnTo: "/auth/done",
  });
  assert.equal(okRes.outcome.ok, true);
  assert.equal(okRes.outcome.code, "code/with+special=chars");
  assert.equal(okRes.outcome.verifier, "pkce-secret-verifier-999");
  assert.equal(okRes.outcome.redirectUri, "http://127.0.0.1:4321/cb");
  assert.equal(okRes.outcome.returnTo, "/");
  assert.equal(okRes.uiJson.ok, true);
  assert.equal(okRes.uiJson.returnTo, "/");
  assert.ok(!JSON.stringify(okRes.uiJson).includes("pkce-secret-verifier-999"), "UI JSON must never leak verifier");
  assert.ok(!JSON.stringify(okRes.uiJson).includes("code/with+special=chars"), "UI JSON must never leak code");
  assert.ok(!JSON.stringify(okRes.machineJson).includes("pkce-secret-verifier-999"), "Machine JSON must never leak verifier");
});

test("W28a #4: chat topic {station, session, compact} + multi-hop moved resolution & cycle detection", async () => {
  const sqlObj = openInitDb();
  try {
    // 2-hop moved chain: ws-1/st-a (thread 10) -> ws-1/st-b (thread 20) -> ws-1/st-c (thread 30)
    sqlObj.run(
      "INSERT OR REPLACE INTO moved (station, session, there_station, thread, there, at, came) VALUES (?, ?, ?, ?, ?, ?, ?)",
      ["ws-1/st-a", "sess-hop", "ws-1/st-b", 10, 20, 1000, 0],
    );
    sqlObj.run(
      "INSERT OR REPLACE INTO moved (station, session, there_station, thread, there, at, came) VALUES (?, ?, ?, ?, ?, ?, ?)",
      ["ws-1/st-b", "sess-hop", "ws-1/st-c", 20, 30, 2000, 0],
    );
    // Cycle trap: ws-1/st-x <-> ws-1/st-y
    sqlObj.run(
      "INSERT OR REPLACE INTO moved (station, session, there_station, thread, there, at, came) VALUES (?, ?, ?, ?, ?, ?, ?)",
      ["ws-1/st-x", "sess-cycle", "ws-1/st-y", 1, 2, 1000, 0],
    );
    sqlObj.run(
      "INSERT OR REPLACE INTO moved (station, session, there_station, thread, there, at, came) VALUES (?, ?, ?, ?, ?, ?, ?)",
      ["ws-1/st-y", "sess-cycle", "ws-1/st-x", 2, 1, 2000, 0],
    );

    // Seed destination chat, thread, and entry on ws-1/st-c thread 30 (with agent jobs!)
    const chatDoc = {
      id: "sess-hop",
      session: "sess-hop",
      thread: 30,
      title: "Moved Multi-Hop Chat",
      agents: [
        {
          key: "sess-hop",
          runtime: "claude",
          model: "claude-opus-5-5",
          status: "running",
          jobs: [{ id: "job-1", name: "build", state: "running" }],
        },
      ],
      people: [],
    };
    sqlObj.run(
      "INSERT OR REPLACE INTO chat (station, archived, id, thread, session, last_active, ord, json) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      ["ws-1/st-c", 0, "sess-hop", 30, "sess-hop", 1700000050000, 1.0, JSON.stringify(chatDoc)],
    );
    sqlObj.run(
      "INSERT OR REPLACE INTO thread (station, id, last, read, unread, sort_at, created_at, surface, json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      ["ws-1/st-c", 30, 1, 0, 1, 1700000050000, 1700000040000, "chat", JSON.stringify({ id: 30, title: "Moved Multi-Hop Chat" })],
    );
    sqlObj.run(
      "INSERT OR REPLACE INTO entry (station, thread, n, json) VALUES (?, ?, ?, ?)",
      [
        "ws-1/st-c",
        30,
        1,
        JSON.stringify({
          kind: "message",
          authorKind: "agent",
          author: "sess-hop",
          authorName: "Claude",
          text: "Hello from destination station C!",
          at: 1700000050000,
        }),
      ],
    );

    // Query origin ws-1/st-a with compact=false -> transparently resolves to ws-1/st-c, preserves jobs!
    const fullRes = await rpc.call("chatMovedCompact", { station: "ws-1/st-a", session: "sess-hop", compact: false }, { sql: sqlObj });
    assert.equal(fullRes.error, undefined);
    assert.equal(fullRes.chatView.title, "Moved Multi-Hop Chat");
    assert.equal(fullRes.chatView.messages.length, 1);
    assert.equal(fullRes.chatView.messages[0].text, "Hello from destination station C!");
    assert.equal(fullRes.chatView.thread.id, 10, "asHere preserves origin thread id");
    assert.equal(fullRes.chatView.agents[0].jobs.length, 1, "non-compact preserves agent jobs");
    assert.equal(fullRes.protoChatOpen.resolvedStation, "ws-1/st-c");
    assert.equal(fullRes.protoChatOpen.resolvedThread, 30);
    assert.equal(fullRes.protoChatOpen.thread, 10);

    // Query origin ws-1/st-a with compact=true -> clears agents[].jobs to [] and sets hasJobs: true!
    const compRes = await rpc.call("chatMovedCompact", { station: "ws-1/st-a", session: "sess-hop", compact: true }, { sql: sqlObj });
    assert.equal(compRes.error, undefined);
    assert.equal(compRes.chatView.messages.length, 1);
    assert.deepEqual(compRes.chatView.agents[0].jobs, []);
    assert.equal(compRes.chatView.agents[0].hasJobs, true);
    assert.equal(compRes.protoChatOpen.compact, true);

    // Cycle detection: must NOT hang, returns clean empty ChatView without throwing.
    const cycRes = await rpc.call("chatMovedCompact", { station: "ws-1/st-x", session: "sess-cycle", compact: true }, { sql: sqlObj });
    assert.equal(cycRes.error, undefined);
    assert.deepEqual(cycRes.chatView.messages, []);
  } finally {
    sqlObj.close();
  }
});

test("W28a #5: project_status, project_lock_prompts, project_notices, project_notify, project_doing conform to TOPIC_SHAPES", async () => {
  const sqlObj = openInitDb();
  try {
    sqlObj.run("INSERT OR REPLACE INTO workspace (id, json, confirmed) VALUES (?, ?, ?)", [
      "ws-1",
      JSON.stringify({ id: "ws-1", name: "WS One", emoji: "⚡" }),
      1000,
    ]);
    sqlObj.run("INSERT OR REPLACE INTO workspace (id, json, confirmed) VALUES (?, ?, ?)", [
      "ws-2",
      JSON.stringify({ id: "ws-2", name: "WS Two" }),
      1000,
    ]);

    const res = await rpc.call("runtimeTopics", {}, { sql: sqlObj });
    assert.equal(res.error, undefined);

    // 1. StatusView
    const confStatus = conform(TOPIC_SHAPES.status, res.status);
    assert.ok("ok" in confStatus, `StatusView shape mismatch: ${confStatus.error}`);
    assert.equal(res.status.state, "trouble");
    assert.ok(res.status.items.length >= 3);
    assert.ok(res.status.lines.length >= 2);

    // 2. LockPromptsView
    const confPrompts = conform(TOPIC_SHAPES.lockPrompts, res.lockPrompts);
    assert.ok("ok" in confPrompts, `LockPromptsView shape mismatch: ${confPrompts.error}`);
    assert.equal(res.lockPrompts.pairing.length, 1);
    assert.equal(res.lockPrompts.asks.length, 1);

    // 3. NoticesView (oldest first + workspace filter isolation)
    const confNotices = conform(TOPIC_SHAPES.notices, res.noticesAll);
    assert.ok("ok" in confNotices, `NoticesView shape mismatch: ${confNotices.error}`);
    assert.deepEqual(
      res.noticesAll.items.map((n) => n.id),
      ["n1", "n2"],
      "notices ordered oldest-first",
    );
    assert.deepEqual(
      res.noticesWs1.items.map((n) => n.id),
      ["n1"],
      "notices filtered by workspace (Gate #9)",
    );
    // 3b. UTF-8 multibyte CJK notice body truncation (50 CJK untouched; 150 CJK -> 139 CJK + "…", zero U+FFFD)
    const confNoticesCjk = conform(TOPIC_SHAPES.notices, res.noticesCjk);
    assert.ok("ok" in confNoticesCjk, `NoticesView CJK shape mismatch: ${confNoticesCjk.error}`);
    assert.equal(res.noticesCjk.items.length, 2);
    assert.equal(res.noticesCjk.items[0].body, "汉".repeat(50), "50 CJK chars (150 bytes) MUST NOT be truncated");
    assert.equal(res.noticesCjk.items[1].body, `${"汉".repeat(139)}…`, "150 CJK chars MUST truncate cleanly to 139 + ellipsis");
    assert.equal(Array.from(res.noticesCjk.items[1].body).length, 140);
    assert.ok(!res.noticesCjk.items[1].body.includes("\uFFFD"), "truncated UTF-8 MUST contain zero U+FFFD replacement chars");

    // 4. NotifyView (workspaces read from SQLite + muted workspace filtered out of `show`)
    const confNotify = conform(TOPIC_SHAPES.notify, res.notify);
    assert.ok("ok" in confNotify, `NotifyView shape mismatch: ${confNotify.error}`);
    assert.equal(res.notify.workspaces.length, 2);
    assert.equal(res.notify.workspaces[0].on, true);
    assert.equal(res.notify.workspaces[1].on, false);
    assert.deepEqual(
      res.notify.show.map((n) => n.id),
      ["n1"],
      "muted ws-2 notice filtered out of notify.show",
    );

    // 5. DoingView
    const confDoing = conform(TOPIC_SHAPES.doing, res.doing);
    assert.ok("ok" in confDoing, `DoingView shape mismatch: ${confDoing.error}`);
    assert.equal(res.doing.doing.length, 1);
    assert.equal(res.doing.doing[0].call, "chat.archive");
  } finally {
    sqlObj.close();
  }
});
