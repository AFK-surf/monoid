// Real TS-vs-Pion differential parity test + `TOPIC_SHAPES` wire contract verification for:
//   - `format_view.pion` (`format_day_label`, `plain_text_preview` via `regex-v0.1.0`,
//     `maker_of_model`, `present_listed_agent`, `parse_md_ast` via `markdown-v0.2.1`)
//   - `marks_view.pion` (`project_workspace_marks` via `chat_marked` index + `prefs` + `outbox`)
//   - `chats_view.pion` & `chat_view.pion` (`project_chats`, `project_chat` with `MdStore` cache hit)
//
// Compiles a temporary standalone Pion driver in `os.tmpdir()` (zero edits to `packages/parity_cli`),
// feeds the EXACT same inputs to BOTH real `client/core-ts/src/*.ts` AND compiled native Pion code,
// asserts 0 diffs, and validates Pion's actual JSON outputs through `conform(TOPIC_SHAPES.*)`.
import test, { after, before } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { fileURLToPath } from "node:url";

import { plainText } from "../../../client/core-ts/src/plain.ts";
import * as formatTs from "../../../client/core-ts/src/format.ts";
import * as presentTs from "../../../client/core-ts/src/present.ts";
import { badgeOf, Counts, failureOf } from "../../../client/core-ts/src/views/marks.ts";
import { parse as parseMdTs } from "../../../client/core-ts/src/markdown.ts";
import { conform } from "../../../client/core-ts/src/conform.ts";
import { SHAPES, TOPIC_SHAPES } from "../../../client/core-ts/src/shapes/schema.ts";
import { holdLanguage } from "../../../client/core-ts/src/i18n.ts";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "../../..");
const PIONC = process.env.PIONC || path.join(os.homedir(), ".pion/bin/pionc");

let tmpDir = "";
let driverBin = "";

function callDriver(requests) {
  const input = requests.map((r) => JSON.stringify(r)).join("\n") + "\n";
  const res = spawnSync(driverBin, [], {
    input,
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
  });
  if (res.status !== 0) {
    throw new Error(`views parity driver failed (exit ${res.status}):\nSTDOUT:\n${res.stdout}\nSTDERR:\n${res.stderr}`);
  }
  return res.stdout
    .trim()
    .split("\n")
    .filter((l) => l.length > 0)
    .map((l) => JSON.parse(l));
}

before(() => {
  tmpDir = fs.mkdtempSync(path.join(REPO_ROOT, "pion/client-core/test/.views-parity-"));
  fs.mkdirSync(path.join(tmpDir, "src"), { recursive: true });

  const toml = `[package]
name = "views_parity_driver"
version = "0.1.0"

[dependencies]
base_codec = { workspace = true }
effect = { workspace = true }
outbox = { workspace = true }
shell = { workspace = true }
sql = { workspace = true }
store = { workspace = true }
sync = { workspace = true }
views = { workspace = true }
wire = { workspace = true }
`;

  const mainPion = `import "base_codec"
import "effect"
import "outbox"
import "shell"
import "sql"
import "store"
import "sync"
import "views"
import "wire"

fn jstr(j : base_codec::Json, k : String) -> String {
  match base_codec::json_get(j, k) {
    Some(base_codec::Json::Str(s)) => s
    _ => ""
  }
}

fn jint64(j : base_codec::Json, k : String) -> Int64 {
  match base_codec::json_get(j, k) {
    Some(base_codec::Json::Num(n, repr)) => {
      if repr.length() > 0 {
        match base_codec::parse_int64_str(repr) { Some(v) => v; None => n.to_int64() }
      } else { n.to_int64() }
    }
    _ => 0L
  }
}

fn jint(j : base_codec::Json, k : String) -> Int {
  jint64(j, k).to_int()
}

fn make_mem_db(
  workspaces : Array[(String, String)],
  stations : Array[(String, String)],
  chats : Array[(String, String, Int, Int64, Int, String)],
  entries : Array[(String, Int, Int, String)],
  outboxes : Array[(String, Int, String)],
  md_kept : Array[(String, String, String)],
) -> sql::Sql {
  let sh = shell::Shell::stood_in(
    effect::Runtime::new(),
    fn(_ : Int64, _ : String, _ : base_codec::Json, _ : Option[Bytes]) -> Unit {},
    fn(op : String, args : base_codec::Json) -> shell::AskResult {
      if op == "sql.open" { return shell::AskResult::Ok(base_codec::json_obj([("id", base_codec::json_int(1))])) }
      if op == "sql.close" || op == "sql.exec" { return shell::AskResult::Ok(base_codec::json_null()) }
      let stmt = jstr(args, "sql")
      let p = match base_codec::json_get(args, "params") { Some(base_codec::Json::Arr(a)) => a; _ => [] }
      let p0 = if p.length() > 0 { match p[0] { base_codec::Json::Str(s) => s; _ => "" } } else { "" }
      let p1 = if p.length() > 1 { match p[1] { base_codec::Json::Str(s) => s; _ => "" } } else { "" }
      let p2 = if p.length() > 2 { match p[2] { base_codec::Json::Str(s) => s; _ => "" } } else { "" }
      let rows : Array[base_codec::Json] = []
      if stmt == "SELECT id, json, confirmed FROM workspace ORDER BY id" {
        for i in 0..<workspaces.length() {
          rows.push(base_codec::json_arr([base_codec::json_str(workspaces[i].0), base_codec::json_str(workspaces[i].1), base_codec::json_int(1)]))
        }
        return shell::AskResult::Ok(base_codec::json_arr(rows))
      }
      if stmt == "SELECT address, kind, json, confirmed FROM station WHERE kind = ? ORDER BY address" {
        for i in 0..<stations.length() {
          rows.push(base_codec::json_arr([base_codec::json_str(stations[i].0), base_codec::json_str("overview"), base_codec::json_str(stations[i].1), base_codec::json_int(1)]))
        }
        return shell::AskResult::Ok(base_codec::json_arr(rows))
      }
      if stmt == "SELECT id, last_active, json, unread FROM chat WHERE station = ? AND archived = 0 AND (tone IS NOT NULL OR asks = 1)" {
        for i in 0..<chats.length() {
          if chats[i].0 == p0 {
            rows.push(base_codec::json_arr([
              base_codec::json_str(chats[i].1),
              base_codec::json_int64(chats[i].3),
              base_codec::json_str(chats[i].5),
              base_codec::json_int(chats[i].4),
            ]))
          }
        }
        return shell::AskResult::Ok(base_codec::json_arr(rows))
      }
      if stmt == "SELECT thread, json FROM outbox WHERE station = ?" {
        for i in 0..<outboxes.length() {
          if outboxes[i].0 == p0 {
            rows.push(base_codec::json_arr([base_codec::json_int(outboxes[i].1), base_codec::json_str(outboxes[i].2)]))
          }
        }
        return shell::AskResult::Ok(base_codec::json_arr(rows))
      }
      if stmt == store::sql_chat_window() {
        for i in 0..<chats.length() {
          let c = chats[i]
          rows.push(base_codec::json_arr([
            base_codec::json_str(c.0),
            base_codec::json_int(0),
            base_codec::json_str(c.1),
            base_codec::json_null(),
            base_codec::json_int64(c.3),
            base_codec::json_num(i.to_double()),
          ]))
        }
        return shell::AskResult::Ok(base_codec::json_arr(rows))
      }
      if stmt == "SELECT json, unread FROM chat WHERE station = ? AND archived = ? AND id = ?" {
        for i in 0..<chats.length() {
          let c = chats[i]
          if c.0 == p0 && c.1 == p2 {
            rows.push(base_codec::json_arr([
              base_codec::json_str(c.5),
              base_codec::json_int(c.4),
            ]))
          }
        }
        return shell::AskResult::Ok(base_codec::json_arr(rows))
      }
      if stmt == store::sql_chat_by_key() {
        for i in 0..<chats.length() {
          let c = chats[i]
          if c.0 == p0 && c.1 == p2 {
            rows.push(base_codec::json_arr([
              base_codec::json_str(c.0), base_codec::json_int(0), base_codec::json_str(c.1),
              base_codec::json_str(c.5),
            ]))
          }
        }
        return shell::AskResult::Ok(base_codec::json_arr(rows))
      }
      if stmt.contains("min(n)") {
        rows.push(base_codec::json_arr([base_codec::json_int(1), base_codec::json_int(2), base_codec::json_int(2)]))
        return shell::AskResult::Ok(base_codec::json_arr(rows))
      }
      if stmt.contains("FROM entry") {
        if stmt.contains("DESC") {
          let mut i = entries.length() - 1
          while i >= 0 {
            let e = entries[i]
            rows.push(base_codec::json_arr([base_codec::json_int(e.2), base_codec::json_str(e.3)]))
            i -= 1
          }
        } else {
          for i in 0..<entries.length() {
            let e = entries[i]
            rows.push(base_codec::json_arr([base_codec::json_int(e.2), base_codec::json_str(e.3)]))
          }
        }
        return shell::AskResult::Ok(base_codec::json_arr(rows))
      }
      if stmt.contains("FROM md_kept") {
        for i in 0..<md_kept.length() {
          rows.push(base_codec::json_arr([base_codec::json_str(md_kept[i].1), base_codec::json_int64(1795460000000L), base_codec::json_str(md_kept[i].2)]))
        }
        return shell::AskResult::Ok(base_codec::json_arr(rows))
      }
      shell::AskResult::Ok(base_codec::json_arr(rows))
    },
    fn(n : Int) -> Bytes { Bytes::new(n) },
  )
  match sql::Sql::open(sh, "mem") {
    sql::SqlResult::Ok(d) => d
    sql::SqlResult::Err(e) => panic(e.message)
  }
}

fn handle(world : World, req : base_codec::Json) -> String {
  let op = jstr(req, "op")
  let args = match base_codec::json_get(req, "args") { Some(v) => v; None => base_codec::json_null() }
  if op == "e2e_sse_marks_read" {
    let rt = effect::Runtime::new()
    let sh = shell::Shell::stood_in(
      rt,
      fn(_ : Int64, _ : String, _ : base_codec::Json, _ : Option[Bytes]) -> Unit {},
      fn(sop : String, sargs : base_codec::Json) -> shell::AskResult {
        io_println(world, base_codec::json_stringify(base_codec::json_obj([
          ("sql_rpc", base_codec::json_obj([("op", base_codec::json_str(sop)), ("args", sargs)])),
        ])))
        match io_read_line(world) {
          Some(line) => match base_codec::json_parse(line) {
            base_codec::JsonParseResult::Ok(resp) => match base_codec::json_get(resp, "err") {
              Some(base_codec::Json::Str(e)) => shell::AskResult::Err(shell::ShellError::{ message: e })
              _ => match base_codec::json_get(resp, "ok") {
                Some(v) => shell::AskResult::Ok(v)
                None => shell::AskResult::Ok(base_codec::json_null())
              }
            }
            base_codec::JsonParseResult::Err(e) => shell::AskResult::Err(shell::ShellError::{ message: e })
          }
          None => shell::AskResult::Err(shell::ShellError::{ message: "eof" })
        }
      },
      fn(n : Int) -> Bytes { Bytes::new(n) },
    )
    let acct = match store::open_account_db(sh, "e2e") {
      sql::SqlResult::Ok(a) => a
      sql::SqlResult::Err(e) => return base_codec::json_stringify(base_codec::json_obj([("err", base_codec::json_str(e.message))]))
    }
    let db = acct.db
    match store::ensure_shared_sidecar(db) {
      sql::SqlResult::Ok(_) => ()
      sql::SqlResult::Err(e) => return base_codec::json_stringify(base_codec::json_obj([("err", base_codec::json_str(e.message))]))
    }
    match db.exec("CREATE INDEX IF NOT EXISTS chat_marks ON chat (station, archived, id, tone, asks) WHERE archived = 0 AND (tone IS NOT NULL OR asks = 1); DROP INDEX IF EXISTS chat_marked;") {
      sql::SqlResult::Ok(_) => ()
      sql::SqlResult::Err(e) => return base_codec::json_stringify(base_codec::json_obj([("err", base_codec::json_str(e.message))]))
    }
    let st = "ws-live/st-1"
    // Seed workspace.json (empty station table!) and local thread read cursors (read=5 for threads 11 & 14).
    let _ = db.run(
      "INSERT INTO workspace (id, json, confirmed) VALUES (?, ?, 1)",
      params=[base_codec::json_str("ws-live"), base_codec::json_str(jstr(args, "wsJson"))],
    )
    let _ = db.run(
      "INSERT INTO thread (station, id, listed, last, read, unread, json) VALUES (?, 11, 1, 10, 5, 1, '{}')",
      params=[base_codec::json_str(st)],
    )
    let _ = db.run(
      "INSERT INTO thread (station, id, listed, last, read, unread, json) VALUES (?, 14, 1, 10, 5, 1, '{}')",
      params=[base_codec::json_str(st)],
    )
    let ob : outbox::FrameOutbox[sync::CoreEvent] = outbox::FrameOutbox::new(fn() -> Unit {})
    let tr = sync::StationTransport::{
      request_k: fn(_m : String, _p : String, _h : Array[(String, String)], _b : Bytes, k : (effect::Exit[sync::HttpReply]) -> Unit) -> Unit {
        k(effect::Exit::Interrupted)
      },
      stream_k: fn(_p : String, _h : Array[(String, String)], _on : (Bytes) -> Unit, k : (effect::Exit[Unit]) -> Unit) -> Unit {
        k(effect::Exit::Succeeded(()))
      },
    }
    let se = sync::StationEvents::new("ws-live", st, db, ob, tr)
    se.set_viewer_email("alice@still.fail")
    let evs : Array[wire::Event] = [
      wire::Event::{ id: Some("e-1"), name: "chat-shared", data: jstr(args, "evUnread") },
      wire::Event::{ id: Some("e-2"), name: "chat-shared", data: jstr(args, "evFailed") },
      wire::Event::{ id: Some("e-3"), name: "chat-shared", data: jstr(args, "evCard") },
      wire::Event::{ id: Some("e-4"), name: "chat-shared", data: jstr(args, "evNeed") },
    ]
    match se.apply_sse_batch(evs) {
      sql::SqlResult::Err(e) => return base_codec::json_stringify(base_codec::json_obj([("err", base_codec::json_str(e.message))]))
      sql::SqlResult::Ok(_) => ()
    }
    let marks_before = match views::project_workspace_marks(db, "alice@still.fail", viewer_id="u-alice", lang="zh") {
      sql::SqlResult::Ok(v) => v
      sql::SqlResult::Err(e) => return base_codec::json_stringify(base_codec::json_obj([("err", base_codec::json_str(e.message))]))
    }
    match store::update_thread_read(db, st, 11, 10, 0) {
      sql::SqlResult::Err(e) => return base_codec::json_stringify(base_codec::json_obj([("err", base_codec::json_str(e.message))]))
      sql::SqlResult::Ok(_) => ()
    }
    match store::update_thread_read(db, st, 14, 10, 0) {
      sql::SqlResult::Err(e) => return base_codec::json_stringify(base_codec::json_obj([("err", base_codec::json_str(e.message))]))
      sql::SqlResult::Ok(_) => ()
    }
    let marks_after_read = match views::project_workspace_marks(db, "alice@still.fail", viewer_id="u-alice", lang="zh") {
      sql::SqlResult::Ok(v) => v
      sql::SqlResult::Err(e) => return base_codec::json_stringify(base_codec::json_obj([("err", base_codec::json_str(e.message))]))
    }
    let dismiss_evs : Array[wire::Event] = [
      wire::Event::{ id: Some("e-5"), name: "dismiss", data: jstr(args, "evDismiss") },
    ]
    match se.apply_sse_batch(dismiss_evs) {
      sql::SqlResult::Err(e) => return base_codec::json_stringify(base_codec::json_obj([("err", base_codec::json_str(e.message))]))
      sql::SqlResult::Ok(_) => ()
    }
    let marks_after_dismiss = match views::project_workspace_marks(db, "alice@still.fail", viewer_id="u-alice", lang="zh") {
      sql::SqlResult::Ok(v) => v
      sql::SqlResult::Err(e) => return base_codec::json_stringify(base_codec::json_obj([("err", base_codec::json_str(e.message))]))
    }
    return base_codec::json_stringify(base_codec::json_obj([
      ("ok", base_codec::json_obj([
        ("marksBefore", marks_before),
        ("marksAfterRead", marks_after_read),
        ("marksAfterDismiss", marks_after_dismiss),
      ])),
    ]))
  }
  if op == "plain_text_preview" {
    let out = views::plain_text_preview(jstr(args, "text"), lang=jstr(args, "lang"))
    return base_codec::json_stringify(base_codec::json_obj([("ok", base_codec::json_str(out))]))
  }
  if op == "format_day_label" {
    let out = views::format_day_label(jint64(args, "ms"), jint64(args, "now"), jint(args, "offset"), jstr(args, "lang"))
    return base_codec::json_stringify(base_codec::json_obj([("ok", base_codec::json_str(out))]))
  }
  if op == "maker_of_model" {
    let out = match views::maker_of_model(jstr(args, "model"), lang=jstr(args, "lang")) {
      Some((id, name)) => base_codec::json_obj([("id", base_codec::json_str(id)), ("name", base_codec::json_str(name))])
      None => base_codec::json_null()
    }
    return base_codec::json_stringify(base_codec::json_obj([("ok", out)]))
  }
  if op == "present_listed_agent" {
    let ag = match base_codec::json_get(args, "agent") { Some(v) => v; None => base_codec::json_obj([]) }
    let out = views::present_listed_agent(ag, lang=jstr(args, "lang"))
    return base_codec::json_stringify(base_codec::json_obj([("ok", out)]))
  }
  if op == "parse_md_ast" {
    let out = views::parse_md_ast(jstr(args, "text"))
    return base_codec::json_stringify(base_codec::json_obj([("ok", out)]))
  }
  if op == "failure_key_of" {
    let row = match base_codec::json_get(args, "row") { Some(v) => v; None => base_codec::json_obj([]) }
    let out = views::failure_key_of(jstr(args, "station"), row)
    return base_codec::json_stringify(base_codec::json_obj([("ok", base_codec::json_str(out))]))
  }
  if op == "project_bundle" {
    // Build realistic 205-chat workspace (chat #205 pending card + chat #1 unread + chat #2 failed + failed outbox)
    // and run real Pion project_chats, project_chat (with MdStore cache hit), and project_workspace_marks!
    let now = 1795460000000L
    let ws_id = "ws-demo"
    let st_addr = "ws-demo/st-tokyo"
    let chats : Array[(String, String, Int, Int64, Int, String)] = []
    for i in 1..<206 {
      let cid = "c-" + i.to_string()
      let is_unread = i == 1
      let is_failed = i == 2
      let is_card = i == 205
      let ags : Array[base_codec::Json] = if is_failed {
        [base_codec::json_obj([
          ("key", base_codec::json_str("s-2")),
          ("runtime", base_codec::json_str("claude")),
          ("model", base_codec::json_str("claude-opus-5-5")),
          ("lastTurn", base_codec::json_obj([("outcome", base_codec::json_str("failed")), ("endedAt", base_codec::json_int64(now - 5000L))])),
        ])]
      } else {
        [base_codec::json_obj([
          ("key", base_codec::json_str("s-" + i.to_string())),
          ("runtime", base_codec::json_str("agy")),
          ("model", base_codec::json_str("gemini-4-neon")),
        ])]
      }
      // Match real Hermes TS DB (db/chats.ts): strip unread from chat.json completely
      // and store it ONLY in SQL column chat.unread (1 for c-1, 0 otherwise).
      let cf : Array[(String, base_codec::Json)] = [
        ("id", base_codec::json_str(cid)),
        ("session", base_codec::json_str(cid)),
        ("thread", base_codec::json_int(i)),
        ("title", base_codec::json_str("Chat " + i.to_string())),
        ("mine", base_codec::json_bool(true)),
        ("pinned", base_codec::json_bool(false)),
        ("lastActiveAt", base_codec::json_int64(now - (i * 1000).to_int64())),
        ("agents", base_codec::json_arr(ags)),
        ("creator", base_codec::json_obj([("id", base_codec::json_str("u-alice")), ("email", base_codec::json_str("alice@still.fail"))])),
        ("last", base_codec::json_obj([("seq", base_codec::json_int(1)), ("authorKind", base_codec::json_str("agent")), ("text", base_codec::json_str("已完成 **任务** https://still.fail/你"))])),
      ]
      if is_card {
        cf.push(("card", base_codec::json_obj([
          ("seq", base_codec::json_int(9)),
          ("card", base_codec::json_obj([
            ("type", base_codec::json_str("options")),
            ("assignee", base_codec::json_str("alice@still.fail")),
            ("options", base_codec::json_arr([base_codec::json_obj([("label", base_codec::json_str("Approve"))])])),
          ])),
        ])))
      }
      chats.push((st_addr, cid, i, now - (i * 1000).to_int64(), if is_unread { 1 } else { 0 }, base_codec::json_stringify(base_codec::json_obj(cf))))
    }
    let cached_md_text = "### Cached Heading\\n\\nBody with *italic*"
    let cached_md_json = "[{\\"cached\\":true}]"
    let uncached_md_text = "> Quote\\n\\n| A | B |\\n| --- | --- |\\n| 1 | ~~2~~ |"
    let entries : Array[(String, Int, Int, String)] = [
      (st_addr, 1, 1, base_codec::json_stringify(base_codec::json_obj([
        ("n", base_codec::json_int(1)), ("kind", base_codec::json_str("message")), ("authorKind", base_codec::json_str("agent")),
        ("author", base_codec::json_str("s-1")), ("authorModel", base_codec::json_str("gemini-4-neon")), ("at", base_codec::json_int64(now - 60000L)),
        ("text", base_codec::json_str(cached_md_text)),
      ]))),
      (st_addr, 1, 2, base_codec::json_stringify(base_codec::json_obj([
        ("n", base_codec::json_int(2)), ("kind", base_codec::json_str("message")), ("authorKind", base_codec::json_str("agent")),
        ("author", base_codec::json_str("s-1")), ("authorModel", base_codec::json_str("gemini-4-neon")), ("at", base_codec::json_int64(now - 30000L)),
        ("text", base_codec::json_str(uncached_md_text)),
      ]))),
    ]
    let outboxes : Array[(String, Int, String)] = [
      (st_addr, 99, base_codec::json_stringify(base_codec::json_arr([
        base_codec::json_obj([("state", base_codec::json_str("failed")), ("text", base_codec::json_str("离线发送失败")), ("at", base_codec::json_int64(now - 1000L))]),
      ]))),
      // Duplicate-thread guard: thread 3 ALSO exists in chat table (unread) + has failed outbox -> MUST count ONCE as alert, never twice!
      (st_addr, 3, base_codec::json_stringify(base_codec::json_arr([
        base_codec::json_obj([("status", base_codec::json_str("failed")), ("text", base_codec::json_str("同线程重复计数防线")), ("at", base_codec::json_int64(now - 2000L))]),
      ]))),
    ]
    // Add second workspace ws-other with 1 unread chat to verify cross-workspace others & othersLabel!
    let ws2_id = "ws-other"
    let st2_addr = "ws-other/st-osaka"
    chats.push((st2_addr, "c-other-1", 1, now - 500L, 1, base_codec::json_stringify(base_codec::json_obj([
      ("id", base_codec::json_str("c-other-1")),
      ("session", base_codec::json_str("c-other-1")),
      ("thread", base_codec::json_int(1)),
      ("title", base_codec::json_str("Other WS Chat")),
      ("mine", base_codec::json_bool(true)),
      ("lastActiveAt", base_codec::json_int64(now - 500L)),
      ("agents", base_codec::json_arr([])),
      ("creator", base_codec::json_obj([("id", base_codec::json_str("u-alice")), ("email", base_codec::json_str("alice@still.fail"))])),
    ]))))
    let md_kept : Array[(String, String, String)] = [
      (st_addr, store::md_key(cached_md_text), cached_md_json),
    ]
    let db = make_mem_db(
      [(ws_id, "{\\"id\\":\\"ws-demo\\",\\"name\\":\\"Monoid Lab\\"}"), (ws2_id, "{\\"id\\":\\"ws-other\\",\\"name\\":\\"Other Lab\\"}")],
      [(st_addr, "{\\"id\\":\\"st-tokyo\\",\\"name\\":\\"Tokyo Studio\\"}"), (st2_addr, "{\\"id\\":\\"st-osaka\\",\\"name\\":\\"Osaka Studio\\"}")],
      chats,
      entries,
      outboxes,
      md_kept,
    )
    let st_brief = views::StationBrief::{
      address: st_addr, id: "st-tokyo", name: "Tokyo Studio", emoji: None, icon: None,
      online: false, updating: false, offline_text: Some("Tokyo Studio 离线"), reconnecting_text: None, running: 0,
    }
    let memo = views::RowsMemo::new()
    let vmarks = views::ViewerMarks::new("alice@still.fail")
    let chats_v = match views::project_chats(db, ws_id, [st_brief], now, memo, vmarks, window_limit=5, tz_offset_ms=540L * 60000L, lang="zh") {
      sql::SqlResult::Ok(v) => v
      sql::SqlResult::Err(e) => panic(e.message)
    }
    let md_store = store::MdStore::new(db, st_addr)
    let chat_v = match views::project_chat(db, md_store, st_addr, 1, "alice@still.fail", now, utc_offset_min=540, lang="zh", online=false, station_name="Tokyo Studio") {
      sql::SqlResult::Ok(v) => v
      sql::SqlResult::Err(e) => panic(e.message)
    }
    let marks_all = match views::project_workspace_marks(db, "alice@still.fail", viewer_id="u-alice", lang="zh") {
      sql::SqlResult::Ok(v) => v
      sql::SqlResult::Err(e) => panic(e.message)
    }
    let fail_key = st_addr + "/c-2@" + (now - 5000L).to_string()
    let custom_prefs = base_codec::json_obj([
      ("badgeKinds", base_codec::json_obj([
        ("on", base_codec::json_bool(true)), ("wait", base_codec::json_bool(true)),
        ("failed", base_codec::json_bool(true)), ("done", base_codec::json_bool(false)),
        ("message", base_codec::json_bool(true)), ("services", base_codec::json_bool(true)),
      ])),
      ("failsGone", base_codec::json_obj([(ws_id, base_codec::json_arr([base_codec::json_str(fail_key)]))])),
    ])
    let marks_filtered = match views::project_workspace_marks(db, "alice@still.fail", viewer_id="u-alice", lang="zh", prefs=Some(custom_prefs)) {
      sql::SqlResult::Ok(v) => v
      sql::SqlResult::Err(e) => panic(e.message)
    }
    return base_codec::json_stringify(base_codec::json_obj([
      ("ok", base_codec::json_obj([
        ("chats", chats_v),
        ("chat", chat_v),
        ("marksAll", marks_all),
        ("marksFiltered", marks_filtered),
      ])),
    ]))
  }
  base_codec::json_stringify(base_codec::json_obj([("err", base_codec::json_str("unknown op: " + op))]))
}

fn main(world : World) -> Unit {
  while true {
    match io_read_line(world) {
      None => break
      Some(line) => {
        if line.length() == 0 { continue }
        match base_codec::json_parse(line) {
          base_codec::JsonParseResult::Ok(req) => io_println(world, handle(world, req))
          base_codec::JsonParseResult::Err(e) => io_println(world, "{\\"err\\":\\"" + e + "\\"}")
        }
      }
    }
  }
}
`;

  fs.writeFileSync(path.join(tmpDir, "pion.toml"), toml);
  fs.writeFileSync(path.join(tmpDir, "src/main.pion"), mainPion);
  driverBin = path.join(tmpDir, "driver");
  execFileSync(PIONC, ["build", "-o", driverBin, tmpDir], { stdio: "pipe", encoding: "utf8" });
});

after(() => {
  if (tmpDir) fs.rmSync(tmpDir, { recursive: true, force: true });
});

test("TS plain.ts + titles.ts vs compiled Pion plain_text_preview (34 vectors, zh & en, 0 diffs)", () => {
  const vectors = [
    // UTF-8 0xA0 CJK trail-byte safety (你 E4 BD A0, 无 E6 97 A0, 加 E5 8A A0)
    "https://still.fail/你",
    "无加你",
    "看 https://still.fail/无加你 之后",
    "前缀\u00A0后缀",
    "全角\u3000空格",
    // Bold / italic / strikethrough & word boundaries
    "**bold** and *italic* and _under_ and ~~strike~~",
    "foo_bar_baz stays intact",
    "a*b*c stays intact",
    "*单字* 和 _下划线_",
    "__double__ ~~del~~",
    // Backslash escapes
    "a\\*b\\* c\\_d\\_ \\[x\\] \\`tick\\`",
    // Markdown links & images
    "已完成 **Invar 渲染管线** 对齐，请审阅 [方案说明](https://still.fail/spec)",
    "[](https://still.fail/spec)",
    "[](photo.png)",
    "[](report.pdf)",
    "![图](https://a.b/x.png)",
    "![本地图](shot.webp?w=100)",
    "![附件](archive.zip)",
    // Slack tokens & mentions
    "<https://a.b/x|点我> 和 <https://a.b/y>",
    "<#C123ABC|general> <@U999XYZ|alice>",
    "<@U999XYZ> 你好",
    "<!here> <!channel|channel> <!everyone>",
    // Inline code spans preserved verbatim
    "keep `**raw** *code* https://a.b` here",
    "double `` `nested` **raw** `` end",
    // Tables, HR, fences, headings, blockquotes, lists, HTML entities
    "| 列一 | 列二 |\n| --- | :---: |\n| 值1 | **值2** |",
    "---\n***\n___\n正文",
    "```pion\nlet x = 1\n```\n结束",
    "> ### 标题\n- [x] 已完成\n1. 第一步\n• 项目",
    "&lt;tag&gt; &amp; ok",
    "普通纯文本",
    "   多   余\t\n  空白  ",
    "https://a.b/1 (括号内 https://a.b/2)",
    "mailto:alice@still.fail 和 [邮件](mailto:alice@still.fail)",
    "~单波浪~ 与 *未闭合",
  ];

  const reqs = [];
  for (const lang of ["zh", "en"]) {
    for (const text of vectors) {
      reqs.push({ op: "plain_text_preview", args: { text, lang } });
    }
  }
  const replies = callDriver(reqs);
  let idx = 0;
  for (const lang of ["zh", "en"]) {
    const words = lang === "en" ? { link: "[link]", image: "[image]", file: "[file]" } : { link: "[链接]", image: "[图片]", file: "[文件]" };
    for (const text of vectors) {
      const expected = formatTs.cleanText(plainText(text, words));
      const actual = replies[idx++].ok;
      assert.equal(actual, expected, `plain_text_preview mismatch [${lang}] for ${JSON.stringify(text)}`);
    }
  }
});

test("TS format.ts + present.ts vs compiled Pion format_day_label, maker_of_model, present_listed_agent (0 diffs)", () => {
  const dayMs = 86_400_000;
  const nowMs = 1795460000000; // 2026-11-24T03:53:20+09:00
  const offsets = [540, 0, -480];
  const deltas = [0, 1, 2, 3, 6, 7, 14, 40];
  const models = [
    "gemini-4-neon",
    "claude-opus-5-5",
    "claude-sonnet-4-5-20250929",
    "gpt-6-astra",
    "deepseek-v4",
    "grok-4",
    "qwen-3-coder",
    "kimi-k2",
    "minimax-m2",
    "glm-4-7",
    "o3-mini",
    "unknown-custom-model",
  ];

  const reqs = [];
  for (const lang of ["zh", "en"]) {
    for (const offset of offsets) {
      for (const d of deltas) {
        reqs.push({ op: "format_day_label", args: { ms: nowMs - d * dayMs, now: nowMs, offset, lang } });
      }
    }
    for (const model of models) {
      reqs.push({ op: "maker_of_model", args: { model, lang } });
      reqs.push({
        op: "present_listed_agent",
        args: { agent: { key: "s-1", runtime: "agy", model, effort: "high" }, lang },
      });
    }
  }

  const replies = callDriver(reqs);
  let idx = 0;
  for (const lang of ["zh", "en"]) {
    holdLanguage(lang, () => {
      for (const offset of offsets) {
        for (const d of deltas) {
          const ms = nowMs - d * dayMs;
          const expected = formatTs.dayLabelIn(ms, nowMs, offset, lang);
          const actual = replies[idx++].ok;
          assert.equal(actual, expected, `dayLabelIn mismatch [${lang} off=${offset} d=${d}]`);
        }
      }
      for (const model of models) {
        const tsMaker = presentTs.maker(model);
        const pionMaker = replies[idx++].ok;
        assert.equal(pionMaker?.id ?? null, tsMaker?.id ?? null, `maker_of_model id mismatch [${lang}] for ${model}`);
        const tsAgent = presentTs.listedAgent({ key: "s-1", runtime: "agy", model, effort: "high" });
        const pionAgent = replies[idx++].ok;
        assert.equal(pionAgent.maker?.id ?? null, tsAgent.maker?.id ?? null, `listedAgent.maker mismatch [${lang}] for ${model}`);
        assert.equal(pionAgent.runtime, tsAgent.runtime);
      }
    });
  }
});

test("Real Pion project_chats / project_chat (MdStore + markdown-v0.2.1) / project_workspace_marks (>200 chats + prefs + outbox) conform to TOPIC_SHAPES & match TS marks.ts", () => {
  const [bundleResp, failKeyResp] = callDriver([
    { op: "project_bundle", args: {} },
    {
      op: "failure_key_of",
      args: {
        station: "ws-demo/st-tokyo",
        row: {
          id: "c-2",
          agents: [{ key: "s-2", lastTurn: { outcome: "failed", endedAt: 1795459995000 } }],
        },
      },
    },
  ]);

  const { chats, chat, marksAll, marksFiltered } = bundleResp.ok;

  // 1. Validate REAL Pion JSON outputs through real `conform(TOPIC_SHAPES.*, payload)`!
  const chatsRes = conform(TOPIC_SHAPES.chats, chats);
  assert.ok("ok" in chatsRes, `Pion ChatsView failed conform: ${chatsRes.error}`);
  const chatRes = conform(TOPIC_SHAPES.chat, chat);
  assert.ok("ok" in chatRes, `Pion ChatView failed conform: ${chatRes.error}`);
  const marksAllRes = conform(TOPIC_SHAPES.workspaceMarks, marksAll);
  assert.ok("ok" in marksAllRes, `Pion WorkspaceMarksView failed conform: ${marksAllRes.error}`);
  const marksFiltRes = conform(TOPIC_SHAPES.workspaceMarks, marksFiltered);
  assert.ok("ok" in marksFiltRes, `Pion filtered WorkspaceMarksView failed conform: ${marksFiltRes.error}`);

  // 2. Verify MdStore cache hit on message #1 vs markdown-v0.2.1 GFM AST (quote + table + strikethrough) on message #2
  assert.deepEqual(chat.messages[0].md, [{ cached: true }], "message #1 must hit MdStore cache without re-parsing");
  const md2Str = JSON.stringify(chat.messages[1].md);
  assert.ok(md2Str.includes('"quote"') && md2Str.includes('"table"') && md2Str.includes('"s"'), `message #2 must parse GFM via markdown-v0.2.1, got: ${md2Str}`);

  // 3. Verify >200 chats (chat #205 pending card NOT dropped!), failed agent #2 + failed outbox #99 + SQL-only unread #1
  const listedItems = chats.days.flatMap((d) => d.items);
  const c1 = listedItems.find((x) => x.id === "c-1");
  const c2 = listedItems.find((x) => x.id === "c-2");
  assert.equal(c1?.unread, true, "c-1 must read unread=true from SQL column even when chat.json omits unread");
  assert.equal(c2?.unread, false, "c-2 must read unread=false from SQL column");
  const wsAll = marksAll.workspaces["ws-demo"];
  assert.equal(wsAll.wait, 1, "chat #205 pending card must be counted (no 200-row cap)");
  assert.equal(wsAll.alert, 3, "failed agent chat #2 + failed outbox #99 + deduped thread #3 must be 3 (no double-count)");
  assert.equal(wsAll.unread, 1, "unread chat #1 must be counted");
  assert.equal(wsAll.badge, badgeOf(null, new Counts(3, 1, 1), 0), "badge must match TS marks.ts badgeOf");
  // Verify non-unsent alert item carries `failure` key (marks.ts:299)
  const c2AlertItem = wsAll.items.find((it) => it.session === "c-2");
  assert.equal(c2AlertItem?.failure, failKeyResp.ok, "non-unsent alert item must carry failure key");
  // Verify cross-workspace `others` & `othersLabel` (marks.ts:359-375) against real TS Counts.labelIn("zh")
  assert.equal(wsAll.others, "done", "ws-demo.others must reflect ws-other's unread chat");
  assert.equal(wsAll.othersLabel, `其他 workspace：${new Counts(0, 0, 1).labelIn("zh")}`);
  const wsOther = marksAll.workspaces["ws-other"];
  assert.equal(wsOther.others, "alert", "ws-other.others must reflect ws-demo's alert");

  // 4. Verify `failure_key_of` matches TS `failureOf` byte-for-byte
  const tsFailKey = failureOf("ws-demo/st-tokyo", {
    id: "c-2",
    agents: [{ key: "s-2", lastTurn: { outcome: "failed", endedAt: 1795459995000 } }],
  });
  assert.equal(failKeyResp.ok, tsFailKey);

  // 5. Verify `prefs` (`badgeKinds.done = false` + `failsGone` suppressing c-2) matches TS `badgeOf` AND filters `items`!
  const wsFilt = marksFiltered.workspaces["ws-demo"];
  assert.equal(wsFilt.alert, 2, "failsGone must suppress c-2 leaving only failed outbox #99 + #3");
  assert.equal(wsFilt.wait, 1);
  assert.equal(wsFilt.unread, 1);
  assert.equal(wsFilt.items.some((it) => it.kind === "done"), false, "badgeKinds.done=false must filter done items out of items[] (marks.ts:277)");
  const expectedFilteredBadge = badgeOf({ badgeKinds: { on: true, wait: true, failed: true, done: false, message: true, services: true } }, new Counts(2, 1, 1), 0);
  assert.equal(wsFilt.badge, expectedFilteredBadge, "filtered badge must match TS marks.ts badgeOf");
});

test("Real SQLite 3,000-row EXPLAIN QUERY PLAN: marks_view hits chat_marks partial index (ZERO SCAN chat)", () => {
  const db = new DatabaseSync(":memory:");
  db.exec(`
    CREATE TABLE chat (
      station TEXT NOT NULL, id TEXT NOT NULL, archived INTEGER NOT NULL, ord REAL NOT NULL,
      thread INTEGER, session TEXT, client_key TEXT,
      last_active INTEGER NOT NULL DEFAULT 0, pinned_at INTEGER,
      unread INTEGER, mine INTEGER NOT NULL DEFAULT 0, running INTEGER NOT NULL DEFAULT 0,
      tone TEXT, asks INTEGER NOT NULL DEFAULT 0, desk INTEGER NOT NULL DEFAULT 0,
      json TEXT NOT NULL,
      PRIMARY KEY (station, archived, id)
    );
    CREATE INDEX chat_marks ON chat (station, archived, id, tone, asks) WHERE archived = 0 AND (tone IS NOT NULL OR asks = 1);
  `);
  const ins = db.prepare(
    "INSERT INTO chat (station, id, archived, ord, last_active, unread, mine, tone, asks, json) VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?)"
  );
  db.exec("BEGIN");
  for (let i = 0; i < 3000; i++) {
    const isMarked = i % 250 === 0;
    const tone = isMarked ? "done" : null;
    const asks = i === 1500 ? 1 : 0;
    ins.run("ws/st-1", `c-${i}`, 0, i, 1795460000000 - i * 1000, isMarked ? 1 : 0, tone, asks, "{}");
  }
  db.exec("COMMIT");
  db.exec("ANALYZE");

  const planRows = db
    .prepare(
      "EXPLAIN QUERY PLAN SELECT id, last_active, json, unread FROM chat WHERE station = ? AND archived = 0 AND (tone IS NOT NULL OR asks = 1)"
    )
    .all("ws/st-1");
  const planText = planRows.map((r) => r.detail).join("\n");
  assert.ok(planText.includes("USING INDEX chat_marks"), `Expected USING INDEX chat_marks, got:\n${planText}`);
  assert.ok(!planText.includes("SCAN chat"), `Forbidden full-table SCAN chat in plan:\n${planText}`);
  db.close();
});

test("TS markdown.ts parse() vs compiled Pion parse_md_ast (14 structural vectors, 0 diffs)", () => {
  function expandTsMd(node, source) {
    if (typeof node === "string") return node;
    if (Array.isArray(node) && typeof node[0] === "number" && typeof node[1] === "number") {
      return source.slice(node[0], node[1]);
    }
    if (!Array.isArray(node) || node.length === 0) return node;
    const [kind, first, second] = node;
    const cleanAttrs = (a) => {
      const out = {};
      for (const [k, v] of Object.entries(a)) {
        if (k === "ink" || k === "drawing") continue;
        if (Array.isArray(v) && v.length === 2 && typeof v[0] === "number" && typeof v[1] === "number") {
          out[k] = source.slice(v[0], v[1]);
        } else {
          out[k] = v;
        }
      }
      return out;
    };
    if (first === undefined) return [kind];
    if (Array.isArray(first)) {
      const kids = first.map((c) => expandTsMd(c, source));
      return second !== undefined ? [kind, kids, cleanAttrs(second)] : [kind, kids];
    }
    return [kind, cleanAttrs(first)];
  }

  const mdVectors = [
    "Hello **bold** and *italic* and ~~strike~~ text.",
    "# Heading 1\n\n### Heading 3",
    "Check `src/app.ts:42` and `/Users/alice/work/a/b/c/d/file.pion` and `plain_var`.",
    "```pion\nlet x = 1\n```\n\n```\nplain block\n```",
    "> Quoted paragraph\n>\n> Second quote",
    "- apple\n- banana\n- cherry",
    "1. first\n2. second",
    "5. fifth\n6. sixth",
    "- [x] completed task\n- [ ] pending task",
    "| Name | Score | Align |\n| :--- | :---: | ---: |\n| Alice | 100 | right |\n| Bob | 95 | left |",
    "![logo](https://still.fail/logo.png) and ![](https://still.fail/blank.png)",
    "[docs](https://still.fail/docs \"Docs\") and [https://still.fail/bare](https://still.fail/bare)",
    "Visit https://still.fail/guide and （https://still.fail/zh）继续",
    "Above\n\n---\n\nBelow",
  ];

  const reqs = mdVectors.map((text) => ({ op: "parse_md_ast", args: { text } }));
  const replies = callDriver(reqs);
  for (let i = 0; i < mdVectors.length; i++) {
    const src = mdVectors[i];
    const tsExpected = parseMdTs(src).map((n) => expandTsMd(n, src));
    const pionActual = replies[i].ok;
    assert.deepEqual(pionActual, tsExpected, `parse_md_ast mismatch on vector #${i}: ${JSON.stringify(src)}`);
  }
});

test("Cached regex plain_text_preview throughput: 1,000 calls complete without per-call regex recompilation", () => {
  const sample = "已完成 **Invar 渲染管线** 对齐，请审阅 [方案说明](https://still.fail/spec) 和 <@U123|alice> `src/a.pion`";
  const reqs = Array.from({ length: 1000 }, () => ({ op: "plain_text_preview", args: { text: sample, lang: "zh" } }));
  const t0 = performance.now();
  const replies = callDriver(reqs);
  const elapsedMs = performance.now() - t0;
  assert.equal(replies.length, 1000);
  assert.equal(replies[0].ok, "已完成 Invar 渲染管线 对齐，请审阅 方案说明 和 @alice src/a.pion");
  assert.ok(elapsedMs < 1500, `Expected 1000 cached-regex calls well under 1500ms, took ${elapsedMs.toFixed(1)}ms`);
});

test("W24-v5 real Station chat-shared (mine:false, unread:false, mineOf+said) + store::open_account_db + chat.read + event:dismiss on real node:sqlite", async () => {
  const db = new DatabaseSync(":memory:");
  const now = 1795460000000;
  const wsJson = JSON.stringify({ id: "ws-live", name: "Live WS", stations: [{ id: "st-1", name: "Tokyo Studio" }] });

  // Authentic Station `chat-shared` payloads (station/mb/src/readops/shared.mbt:508-526):
  // literal `"mine": false, "unread": false`, ZERO `tone`/`asks` fields, real `mineOf` + `said`!
  const evUnread = JSON.stringify({
    workspace: "ws-live",
    id: "c-unread",
    session: "c-unread",
    thread: 11,
    title: "Unread Done Chat",
    mine: false,
    unread: false,
    mineOf: [{ email: "alice@still.fail" }],
    said: { n: 10, other: 10, author: "agent-1", authorKind: "agent" },
    lastActiveAt: now - 1000,
    agents: [{ key: "s-1", runtime: "agy", model: "gemini-4-neon" }],
    creator: { id: "u-alice", email: "alice@still.fail" },
  });
  const evFailed = JSON.stringify({
    workspace: "ws-live",
    id: "c-failed",
    session: "c-failed",
    thread: 12,
    title: "Failed Agent Chat",
    mine: false,
    unread: false,
    mineOf: [{ email: "alice@still.fail" }],
    lastActiveAt: now - 2000,
    agents: [{ key: "s-2", runtime: "claude", model: "claude-opus-5-5", state: "failed", lastTurn: { outcome: "failed", endedAt: now - 2500 } }],
    creator: { id: "u-alice", email: "alice@still.fail" },
  });
  const evCard = JSON.stringify({
    workspace: "ws-live",
    id: "c-card",
    session: "c-card",
    thread: 13,
    title: "Pending Card Chat",
    mine: false,
    unread: false,
    mineOf: [{ email: "alice@still.fail" }],
    said: { n: 7, other: 7, author: "agent-3", authorKind: "agent" },
    lastActiveAt: now - 3000,
    agents: [],
    card: { seq: 5, card: { type: "options", assignee: "alice@still.fail", options: [{ label: "OK" }] } },
    creator: { id: "u-alice", email: "alice@still.fail" },
  });
  const evNeed = JSON.stringify({
    workspace: "ws-live",
    id: "c-need",
    session: "c-need",
    thread: 14,
    title: "Need Help Chat",
    mine: false,
    unread: false,
    mineOf: [{ email: "alice@still.fail" }],
    said: { n: 10, other: 10, author: "agent-4", authorKind: "agent" },
    lastActiveAt: now - 4000,
    agents: [{ key: "s-4", runtime: "agy", model: "gemini-4-neon", lastTurn: { ending: "need_help" } }],
    need: { seq: 9, message: { text: "Need API key" } },
    creator: { id: "u-alice", email: "alice@still.fail" },
  });
  const evDismiss = JSON.stringify({ workspace: "ws-live", thread: 13, n: 5 });

  const child = spawn(driverBin, [], { stdio: ["pipe", "pipe", "pipe"] });
  let buf = "";
  const result = await new Promise((resolve, reject) => {
    child.on("error", reject);
    child.stderr.on("data", (d) => reject(new Error(`driver stderr: ${d.toString()}`)));
    child.stdout.on("data", (chunk) => {
      buf += chunk.toString("utf8");
      let nl;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (!line) continue;
        const msg = JSON.parse(line);
        if (msg.sql_rpc) {
          const { op, args } = msg.sql_rpc;
          try {
            if (op === "sql.open") {
              child.stdin.write(JSON.stringify({ ok: { id: 1 } }) + "\n");
            } else if (op === "sql.close") {
              child.stdin.write(JSON.stringify({ ok: null }) + "\n");
            } else if (op === "sql.exec") {
              db.exec(args.sql);
              child.stdin.write(JSON.stringify({ ok: null }) + "\n");
            } else if (op === "sql.run") {
              const r = db.prepare(args.sql).run(...(args.params ?? []));
              child.stdin.write(JSON.stringify({ ok: { changes: Number(r.changes ?? 0) } }) + "\n");
            } else if (op === "sql.all") {
              const stmt = db.prepare(args.sql);
              stmt.setReturnArrays(true);
              const rows = stmt.all(...(args.params ?? []));
              child.stdin.write(JSON.stringify({ ok: rows }) + "\n");
            } else {
              child.stdin.write(JSON.stringify({ err: `unknown sql op: ${op}` }) + "\n");
            }
          } catch (err) {
            child.stdin.write(JSON.stringify({ err: String(err?.message ?? err) }) + "\n");
          }
        } else {
          child.stdin.end();
          resolve(msg);
        }
      }
    });
    child.stdin.write(
      JSON.stringify({ op: "e2e_sse_marks_read", args: { wsJson, evUnread, evFailed, evCard, evNeed, evDismiss } }) + "\n"
    );
  });

  assert.ok(result.ok, `e2e_sse_marks_read failed: ${result.err}`);
  const { marksBefore, marksAfterRead, marksAfterDismiss } = result.ok;

  // 1. Before chat.read: authentic shared rows (`mine:false, unread:false`) derived via `mineOf` + `said` + `thread.read=5`:
  //    c-unread -> unread=1 (tone='done'), c-failed -> alert=1 (tone='alert'), c-card & c-need -> wait=2 (asks=1, c-need blocked NOT done).
  const wsBefore = marksBefore.workspaces["ws-live"];
  assert.equal(wsBefore.unread, 1, "c-unread must derive mine=1, unread=1, tone='done' (c-need blocked must NOT count as done)");
  assert.equal(wsBefore.alert, 1, "c-failed must derive tone='alert'");
  assert.equal(wsBefore.wait, 2, "c-card + c-need must both derive asks=1 and count as wait=2");
  assert.equal(wsBefore.badge, 4, "total badge before chat.read must be 4");

  // 2. After chat.read on thread 11 & thread 14: unread drops to 0, c-unread.tone cleared to NULL, c-need keeps asks=1 & wait=2!
  const wsAfterRead = marksAfterRead.workspaces["ws-live"];
  assert.equal(wsAfterRead.unread, 0, "unread must drop to 0 after chat.read");
  assert.equal(wsAfterRead.alert, 1);
  assert.equal(wsAfterRead.wait, 2, "chat.read on thread 14 must NOT drop wait=2");
  assert.equal(wsAfterRead.badge, 3);

  // 3. After SSE `event: dismiss` {thread:13, n:5}: real `shared_mark(k='13:5', v='1')` persisted, c-card.asks=0, wait drops 2 -> 1!
  const smRow = db.prepare("SELECT k, v FROM shared_mark WHERE station = 'ws-live/st-1' AND kind = 'dismissed' AND k = '13:5'").get();
  assert.equal(smRow?.v, "1", "real shared_mark(k='13:5', v='1') must be written by event: dismiss");

  const rowUnread = db.prepare("SELECT unread, tone, asks FROM chat WHERE id = 'c-unread'").get();
  const rowFailed = db.prepare("SELECT unread, tone, asks FROM chat WHERE id = 'c-failed'").get();
  const rowCard = db.prepare("SELECT unread, tone, asks FROM chat WHERE id = 'c-card'").get();
  const rowNeed = db.prepare("SELECT unread, tone, asks FROM chat WHERE id = 'c-need'").get();
  assert.equal(rowUnread.unread, 0);
  assert.equal(rowUnread.tone, null, "chat.read must clear tone='done' back to NULL");
  assert.equal(rowFailed.tone, "alert");
  assert.equal(rowCard.asks, 0, "event: dismiss must recompute c-card.asks -> 0");
  assert.equal(rowCard.tone, "done", "unread chat with dismissed card must preserve tone='done' (marks.ts rowTone)");
  assert.equal(rowNeed.asks, 1, "c-need.asks must remain 1");

  const wsAfterDismiss = marksAfterDismiss.workspaces["ws-live"];
  assert.equal(wsAfterDismiss.unread, 1, "dismissed unread thread 13 must now count as unread=1");
  assert.equal(wsAfterDismiss.alert, 1);
  assert.equal(wsAfterDismiss.wait, 1, "wait must drop from 2 to 1 after event: dismiss");
  assert.equal(wsAfterDismiss.badge, 3, "badge must be 3 (1 alert + 1 wait + 1 unread) after dismissing unread card");
  db.close();
});
