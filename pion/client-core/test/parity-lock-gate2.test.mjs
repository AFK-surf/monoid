// Gate #2 (P0-10) Differential Parity & Adversarial Test Suite (`parity-lock-gate2.test.mjs`):
//   1. Cross-verifies Pion `sync::valid_key_id` against real Node `shared/lock.ts validKeyId`
//      on valid NIST P-256 points, off-curve points (y+1), point at infinity (0,0), x>=p, y>=p,
//      Ed25519 valid/invalid keys, overlong (>200) keys, and strict unpadded canonical base64url.
//   2. Exercises real on-disk `node:sqlite` persistence + `ClientCore` adversarial Gate #2 suite:
//      - Genesis root pinning & anti-hijack (validly signed chain under G_evil != G rejected)
//      - Prefix rollback defense ([e0] replay rejected; high-water seq=2, head=hash(e2) preserved)
//      - Restart persistence across a brand-new `ClientCore` instance on the same SQLite DB
//      - Legitimate higher-weight competing fork switch under same genesis G (displaced branch in aside)
//      - Cross-workspace lock isolation (Gate #9: zero leakage on `lock.status` and `lock` topic)
//
// Compiles a temporary native Pion driver in `os.tmpdir()` (zero edits to `parity_cli`) and
// cleans up all temporary artifacts in `after()`.

import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { generateKeyPairSync } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";

import { validKeyId as tsValidKeyId } from "../../../shared/lock.ts";
import { fromB64url as hermesFromB64url } from "../../../client/core-ts/src/vault/crypto.ts";
import { p256 as nobleP256 } from "../../../client/core-ts/node_modules/@noble/curves/nist.js";
import { AccountDb } from "../../../client/core-ts/src/db/account.ts";
import { Runner } from "../../../client/core-ts/src/runtime.ts";
import { TestTime } from "../../../client/core-ts/src/testing.ts";

// Mirror `client/core-ts/src/vault/lock-check.ts:33-37` + `@noble/curves` P-256 point check
function hermesValidKeyId(id) {
  if (typeof id !== "string" || id.length > 200) return false;
  if (id.startsWith("ed25519:")) return /^[0-9a-f]{64}$/.test(id.slice(8));
  if (id.startsWith("p256:")) {
    const pt = hermesFromB64url(id.slice(5));
    if (pt === null || pt.length !== 65 || pt[0] !== 4) return false;
    try {
      nobleP256.Point.fromBytes(pt);
      return true;
    } catch {
      return false;
    }
  }
  return false;
}

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

const DRIVER_MAIN_PION = `// Temporary native Pion driver for parity-lock-gate2.test.mjs
import "base_codec"
import "effect"
import "form"
import "lock"
import "shell"
import "sql"
import "sync"

fn j_str(j : base_codec::Json, k : String) -> String {
  match base_codec::json_get(j, k) {
    Some(base_codec::Json::Str(s)) => s
    _ => ""
  }
}

fn make_seed(tag : Int) -> Bytes {
  let b = Bytes::new(32)
  for i in 0..<32 {
    b[i] = ((tag + i * 11) & 0xFF) as Byte
  }
  b
}

fn hex64(ch : String) -> String {
  let sb = StringBuilder::new()
  for _i in 0..<64 {
    sb.write_string(ch)
  }
  sb.to_string()
}

fn dummy_transport() -> sync::StationTransport {
  sync::StationTransport::{
    request_k: fn(_m : String, _p : String, _h : Array[(String, String)], _b : Bytes, k : (effect::Exit[sync::HttpReply]) -> Unit) -> Unit {
      k(effect::Exit::Failed(effect::EffectError::Custom("offline")))
    },
    stream_k: fn(_p : String, _h : Array[(String, String)], _on : (Bytes) -> Unit, k : (effect::Exit[Unit]) -> Unit) -> Unit {
      k(effect::Exit::Failed(effect::EffectError::Custom("offline")))
    },
  }
}

fn has_lock_rejected(evs : Array[sync::CoreEvent], ws : String) -> Bool {
  for i in 0..<evs.length() {
    match evs[i] {
      sync::CoreEvent::LockRejected(w, _) => if w == ws { return true }
      _ => ()
    }
  }
  false
}

fn has_lock_updated(evs : Array[sync::CoreEvent]) -> Bool {
  for i in 0..<evs.length() {
    match evs[i] {
      sync::CoreEvent::LockUpdated(_, _, _, _) => return true
      _ => ()
    }
  }
  false
}

fn run_gate2_scenario(world : World) -> base_codec::Json {
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
        Some(line) =>
        match base_codec::json_parse(line) {
          base_codec::JsonParseResult::Ok(resp) =>
          match base_codec::json_get(resp, "err") {
            Some(base_codec::Json::Str(e)) => shell::AskResult::Err(shell::ShellError::{ message: e })
            _ =>
            match base_codec::json_get(resp, "ok") {
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
  let db = match sql::Sql::open(sh, "gate2-db") {
    sql::SqlResult::Ok(d) => d
    sql::SqlResult::Err(e) => return base_codec::json_obj([("error", base_codec::json_str(e.to_string()))])
  }

  let core = sync::ClientCore::new("ws-gate2", "st1", rt, db, dummy_transport(), fn() -> Unit {})
  let alice_seed = make_seed(31)
  let bob_seed = make_seed(32)
  let evil_seed = make_seed(33)
  let alice_key = sync::ed25519_key_id(alice_seed)
  let bob_key = sync::ed25519_key_id(bob_seed)
  let evil_key = sync::ed25519_key_id(evil_seed)
  let c = sync::native_lock_crypto()

  let e0 = match sync::sign_lock_entry(
    alice_seed,
    form::Json::Obj([
      ("v", form::Json::Num(1.0)),
      ("ws", form::Json::Str("ws-gate2")),
      ("seq", form::Json::Num(0.0)),
      ("prev", form::Json::Null),
      ("at", form::Json::Num(1790000000.0)),
      ("kind", form::Json::Str("genesis")),
      (
        "body",
        form::Json::Obj([
          ("owner", form::Json::Str("alice")),
          ("origins", form::Json::Arr([form::Json::Str("https://app.still.fail")])),
          ("rp_id", form::Json::Str("still.fail")),
          ("cloud_keys", form::Json::Obj([("keys", form::Json::Arr([]))])),
          (
            "members",
            form::Json::Arr([
              form::Json::Obj([("sub", form::Json::Str("alice")), ("email", form::Json::Str("alice@example.com")), ("role", form::Json::Str("owner"))]),
              form::Json::Obj([("sub", form::Json::Str("bob")), ("email", form::Json::Str("bob@example.com")), ("role", form::Json::Str("admin"))]),
            ]),
          ),
          (
            "devices",
            form::Json::Arr([
              form::Json::Obj([("id", form::Json::Str(hex64("1"))), ("sub", form::Json::Str("alice")), ("kind", form::Json::Str("app")), ("label", form::Json::Str("Alice")), ("sign_key", form::Json::Str(alice_key))]),
              form::Json::Obj([("id", form::Json::Str(hex64("2"))), ("sub", form::Json::Str("bob")), ("kind", form::Json::Str("app")), ("label", form::Json::Str("Bob")), ("sign_key", form::Json::Str(bob_key))]),
            ]),
          ),
          ("passkeys", form::Json::Arr([])),
          ("stations", form::Json::Arr([])),
          ("gateways", form::Json::Arr([])),
        ]),
      ),
    ]),
  ) { Ok(e) => e; Err(m) => return base_codec::json_obj([("error", base_codec::json_str(m))]) }
  let root_g = match lock::entry_hash(e0, c) { Ok(h) => h; Err(_) => "" }

  let e1 = match sync::sign_lock_entry(
    bob_seed,
    form::Json::Obj([
      ("v", form::Json::Num(1.0)),
      ("ws", form::Json::Str("ws-gate2")),
      ("seq", form::Json::Num(1.0)),
      ("prev", form::Json::Str(root_g)),
      ("at", form::Json::Num(1790000010.0)),
      ("kind", form::Json::Str("member")),
      ("body", form::Json::Obj([("sub", form::Json::Str("carol")), ("email", form::Json::Str("carol@example.com")), ("role", form::Json::Str("member"))])),
    ]),
  ) { Ok(e) => e; Err(m) => return base_codec::json_obj([("error", base_codec::json_str(m))]) }
  let h1 = match lock::entry_hash(e1, c) { Ok(h) => h; Err(_) => "" }

  let e2 = match sync::sign_lock_entry(
    bob_seed,
    form::Json::Obj([
      ("v", form::Json::Num(1.0)),
      ("ws", form::Json::Str("ws-gate2")),
      ("seq", form::Json::Num(2.0)),
      ("prev", form::Json::Str(h1)),
      ("at", form::Json::Num(1790000020.0)),
      ("kind", form::Json::Str("member")),
      ("body", form::Json::Obj([("sub", form::Json::Str("erin")), ("email", form::Json::Str("erin@example.com")), ("role", form::Json::Str("member"))])),
    ]),
  ) { Ok(e) => e; Err(m) => return base_codec::json_obj([("error", base_codec::json_str(m))]) }
  let h2 = match lock::entry_hash(e2, c) { Ok(h) => h; Err(_) => "" }

  core.pin_lock_root(root_g)
  let init_ok = match core.apply_lock_chain([e0, e1, e2], root_g) { Ok(_) => true; Err(_) => false }
  let _ = core.drain_frame()

  // Evil self-signed chain under G_evil != G
  let e0_evil = match sync::sign_lock_entry(
    evil_seed,
    form::Json::Obj([
      ("v", form::Json::Num(1.0)),
      ("ws", form::Json::Str("ws-gate2")),
      ("seq", form::Json::Num(0.0)),
      ("prev", form::Json::Null),
      ("at", form::Json::Num(1790000005.0)),
      ("kind", form::Json::Str("genesis")),
      (
        "body",
        form::Json::Obj([
          ("owner", form::Json::Str("evil")),
          ("origins", form::Json::Arr([form::Json::Str("https://app.still.fail")])),
          ("rp_id", form::Json::Str("still.fail")),
          ("cloud_keys", form::Json::Obj([("keys", form::Json::Arr([]))])),
          ("members", form::Json::Arr([form::Json::Obj([("sub", form::Json::Str("evil")), ("email", form::Json::Str("evil@evil.test")), ("role", form::Json::Str("owner"))])])),
          ("devices", form::Json::Arr([form::Json::Obj([("id", form::Json::Str(hex64("9"))), ("sub", form::Json::Str("evil")), ("kind", form::Json::Str("app")), ("label", form::Json::Str("Evil")), ("sign_key", form::Json::Str(evil_key))])])),
          ("passkeys", form::Json::Arr([])),
          ("stations", form::Json::Arr([])),
          ("gateways", form::Json::Arr([])),
        ]),
      ),
    ]),
  ) { Ok(e) => e; Err(m) => return base_codec::json_obj([("error", base_codec::json_str(m))]) }
  let root_evil = match lock::entry_hash(e0_evil, c) { Ok(h) => h; Err(_) => "" }

  let hijack_rejected = match core.apply_lock_chain([e0_evil], root_evil) { Ok(_) => false; Err(_) => true }
  let hijack_event = has_lock_rejected(core.drain_frame(), "ws-gate2")
  let after_hijack = core.lock_status_json()

  // Attack 1b: Spoofed root (claims root = G) with longer validly self-signed foreign chain [e0_evil..e3_evil]
  let e1_evil = match sync::sign_lock_entry(
    evil_seed,
    form::Json::Obj([
      ("v", form::Json::Num(1.0)),
      ("ws", form::Json::Str("ws-gate2")),
      ("seq", form::Json::Num(1.0)),
      ("prev", form::Json::Str(root_evil)),
      ("at", form::Json::Num(1790000006.0)),
      ("kind", form::Json::Str("member")),
      ("body", form::Json::Obj([("sub", form::Json::Str("evil1")), ("email", form::Json::Str("e1@evil.test")), ("role", form::Json::Str("member"))])),
    ]),
  ) { Ok(e) => e; Err(m) => return base_codec::json_obj([("error", base_codec::json_str(m))]) }
  let h1_evil = match lock::entry_hash(e1_evil, c) { Ok(h) => h; Err(_) => "" }
  let e2_evil = match sync::sign_lock_entry(
    evil_seed,
    form::Json::Obj([
      ("v", form::Json::Num(1.0)),
      ("ws", form::Json::Str("ws-gate2")),
      ("seq", form::Json::Num(2.0)),
      ("prev", form::Json::Str(h1_evil)),
      ("at", form::Json::Num(1790000007.0)),
      ("kind", form::Json::Str("member")),
      ("body", form::Json::Obj([("sub", form::Json::Str("evil2")), ("email", form::Json::Str("e2@evil.test")), ("role", form::Json::Str("member"))])),
    ]),
  ) { Ok(e) => e; Err(m) => return base_codec::json_obj([("error", base_codec::json_str(m))]) }
  let h2_evil = match lock::entry_hash(e2_evil, c) { Ok(h) => h; Err(_) => "" }
  let e3_evil = match sync::sign_lock_entry(
    evil_seed,
    form::Json::Obj([
      ("v", form::Json::Num(1.0)),
      ("ws", form::Json::Str("ws-gate2")),
      ("seq", form::Json::Num(3.0)),
      ("prev", form::Json::Str(h2_evil)),
      ("at", form::Json::Num(1790000008.0)),
      ("kind", form::Json::Str("member")),
      ("body", form::Json::Obj([("sub", form::Json::Str("evil3")), ("email", form::Json::Str("e3@evil.test")), ("role", form::Json::Str("member"))])),
    ]),
  ) { Ok(e) => e; Err(m) => return base_codec::json_obj([("error", base_codec::json_str(m))]) }

  let spoof_rejected = match core.apply_lock_chain([e0_evil, e1_evil, e2_evil, e3_evil], root_g) { Ok(_) => false; Err(_) => true }
  let spoof_evs = core.drain_frame()
  let spoof_event_rejected = has_lock_rejected(spoof_evs, "ws-gate2")
  let spoof_event_updated = has_lock_updated(spoof_evs)
  let after_spoof = core.lock_status_json()

  // Prefix rollback [e0]
  let rollback_rejected = match core.apply_lock_chain([e0], root_g) { Ok(_) => false; Err(_) => true }
  let rollback_event = has_lock_rejected(core.drain_frame(), "ws-gate2")
  let after_rollback = core.lock_status_json()

  // P2: Duplicate delivery of current high-water head [e2] -> Ok, zero events
  let dup_head_ok = match core.apply_lock_chain([e2], root_g) { Ok(_) => true; Err(_) => false }
  let dup_head_evs = core.drain_frame().length()

  // Restart ClientCore on the SAME real SQLite DB
  let core2 = sync::ClientCore::new("ws-gate2", "st1", rt, db, dummy_transport(), fn() -> Unit {})
  let restored_root = match core2.pinned_lock_root() { Some(r) => r; None => "" }
  let restored_status = core2.lock_status_json()
  let hijack_after_restart_rejected = match core2.apply_lock_chain([e0_evil], root_evil) { Ok(_) => false; Err(_) => true }

  // Legitimate higher-weight competing fork under same G (Alice owner beats Bob admin at seq=1)
  let e1_alice = match sync::sign_lock_entry(
    alice_seed,
    form::Json::Obj([
      ("v", form::Json::Num(1.0)),
      ("ws", form::Json::Str("ws-gate2")),
      ("seq", form::Json::Num(1.0)),
      ("prev", form::Json::Str(root_g)),
      ("at", form::Json::Num(1790000030.0)),
      ("kind", form::Json::Str("member")),
      ("body", form::Json::Obj([("sub", form::Json::Str("dave")), ("email", form::Json::Str("dave@example.com")), ("role", form::Json::Str("member"))])),
    ]),
  ) { Ok(e) => e; Err(m) => return base_codec::json_obj([("error", base_codec::json_str(m))]) }
  let h1_alice = match lock::entry_hash(e1_alice, c) { Ok(h) => h; Err(_) => "" }

  let fork_ok = match core2.apply_lock_chain([e1_alice], root_g) { Ok(_) => true; Err(_) => false }
  let fork_head = match core2.current_lock() { Some(st) => st.head; None => "" }
  let fork_has_dave = match core2.current_lock() { Some(st) => st.members.contains("dave"); None => false }
  let fork_has_carol = match core2.current_lock() { Some(st) => st.members.contains("carol"); None => false }
  let aside_count = core2.lock_kept_aside().length()

  // Cross-workspace isolation (Gate #9)
  let other_status = core2.lock_status_json(workspace=Some("ws-other"))
  let other_topic_raw = match core2.handle_wire("{\\"id\\":99,\\"subscribe\\":{\\"topic\\":\\"lock\\",\\"workspace\\":\\"ws-other\\"}}") {
    Some((txt, _)) => txt
    None => ""
  }

  base_codec::json_obj([
    ("initOk", base_codec::json_bool(init_ok)),
    ("rootG", base_codec::json_str(root_g)),
    ("h2", base_codec::json_str(h2)),
    ("h1Alice", base_codec::json_str(h1_alice)),
    ("hijackRejected", base_codec::json_bool(hijack_rejected)),
    ("hijackEvent", base_codec::json_bool(hijack_event)),
    ("afterHijack", after_hijack),
    ("spoofRejected", base_codec::json_bool(spoof_rejected)),
    ("spoofEventRejected", base_codec::json_bool(spoof_event_rejected)),
    ("spoofEventUpdated", base_codec::json_bool(spoof_event_updated)),
    ("afterSpoof", after_spoof),
    ("rollbackRejected", base_codec::json_bool(rollback_rejected)),
    ("rollbackEvent", base_codec::json_bool(rollback_event)),
    ("afterRollback", after_rollback),
    ("dupHeadOk", base_codec::json_bool(dup_head_ok)),
    ("dupHeadEvs", base_codec::json_int(dup_head_evs)),
    ("e0", sync::form_to_codec(e0)),
    ("e1", sync::form_to_codec(e1)),
    ("e2", sync::form_to_codec(e2)),
    ("e0Evil", sync::form_to_codec(e0_evil)),
    ("rootEvil", base_codec::json_str(root_evil)),
    ("restoredRoot", base_codec::json_str(restored_root)),
    ("restoredStatus", restored_status),
    ("hijackAfterRestartRejected", base_codec::json_bool(hijack_after_restart_rejected)),
    ("forkOk", base_codec::json_bool(fork_ok)),
    ("forkHead", base_codec::json_str(fork_head)),
    ("forkHasDave", base_codec::json_bool(fork_has_dave)),
    ("forkHasCarol", base_codec::json_bool(fork_has_carol)),
    ("asideCount", base_codec::json_int(aside_count)),
    ("otherStatus", other_status),
    ("otherTopicRaw", base_codec::json_str(other_topic_raw)),
  ])
}

fn run_restore_and_attack(world : World, args : base_codec::Json) -> base_codec::Json {
  let rt = effect::Runtime::new()
  let sh = shell::Shell::stood_in(
    rt,
    fn(_id : Int64, _op : String, _args : base_codec::Json, _bytes : Option[Bytes]) -> Unit {},
    fn(op : String, a : base_codec::Json) -> shell::AskResult {
      let req = base_codec::json_obj([
        ("sqlReq", base_codec::json_obj([("op", base_codec::json_str(op)), ("args", a)])),
      ])
      io_println(world, base_codec::json_stringify(req))
      match io_read_line(world) {
        Some(line) =>
        match base_codec::json_parse(line) {
          base_codec::JsonParseResult::Ok(resp) =>
          match base_codec::json_get(resp, "err") {
            Some(base_codec::Json::Str(e)) => shell::AskResult::Err(shell::ShellError::{ message: e })
            _ =>
            match base_codec::json_get(resp, "ok") {
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
  let db = match sql::Sql::open(sh, "gate2-restore-db") {
    sql::SqlResult::Ok(d) => d
    sql::SqlResult::Err(e) => return base_codec::json_obj([("error", base_codec::json_str(e.to_string()))])
  }
  let ws = j_str(args, "ws")
  let root_evil = j_str(args, "rootEvil")
  let evil_entry = match base_codec::json_get(args, "e0Evil") {
    Some(j) => sync::codec_to_form(j)
    None => form::Json::Null
  }
  let core = sync::ClientCore::new(ws, "st1", rt, db, dummy_transport(), fn() -> Unit {})
  let init_evs = core.drain_frame()
  let init_rejected = has_lock_rejected(init_evs, ws)
  let attack_rejected = match core.apply_lock_chain([evil_entry], root_evil) { Ok(_) => false; Err(_) => true }
  let attack_evs = core.drain_frame()
  let attack_event = has_lock_rejected(attack_evs, ws)
  let status = core.lock_status_json()
  let pinned = match core.pinned_lock_root() { Some(r) => r; None => "" }
  base_codec::json_obj([
    ("corrupt", base_codec::json_bool(core.is_lock_corrupt())),
    ("initRejected", base_codec::json_bool(init_rejected)),
    ("attackRejected", base_codec::json_bool(attack_rejected)),
    ("attackEvent", base_codec::json_bool(attack_event)),
    ("pinned", base_codec::json_str(pinned)),
    ("status", status),
  ])
}

fn main(world : World) -> Unit {
  while true {
    match io_read_line(world) {
      None => break
      Some(line) => {
        if line.length() == 0 {
          continue
        }
        let req = match base_codec::json_parse(line) {
          base_codec::JsonParseResult::Ok(j) => j
          base_codec::JsonParseResult::Err(e) => {
            io_println(world, base_codec::json_stringify(base_codec::json_obj([("err", base_codec::json_str(e))])))
            continue
          }
        }
        let op = j_str(req, "op")
        let args = match base_codec::json_get(req, "args") {
          Some(a) => a
          None => base_codec::json_obj([])
        }
        if op == "validKeyId" {
          let id = j_str(args, "id")
          io_println(world, base_codec::json_stringify(base_codec::json_obj([("ok", base_codec::json_bool(sync::valid_key_id(id)))])))
        } else if op == "gate2Scenario" {
          let res = run_gate2_scenario(world)
          io_println(world, base_codec::json_stringify(base_codec::json_obj([("ok", res)])))
        } else if op == "restoreAndAttack" {
          let res = run_restore_and_attack(world, args)
          io_println(world, base_codec::json_stringify(base_codec::json_obj([("ok", res)])))
        } else {
          io_println(world, base_codec::json_stringify(base_codec::json_obj([("err", base_codec::json_str("unknown op: " + op))])))
        }
      }
    }
  }
}
`;

class Gate2DriverClient {
  constructor(binPath) {
    this.proc = spawn(binPath, [], { stdio: ["pipe", "pipe", "pipe"] });
    this.buf = "";
    this.queue = [];
    this.stderr = "";
    this.activeSql = null;
    this.proc.stderr.on("data", (d) => {
      this.stderr += d.toString("utf8");
    });
    this.proc.stdout.on("data", (chunk) => {
      this.buf += chunk.toString("utf8");
      let nl;
      while ((nl = this.buf.indexOf("\n")) >= 0) {
        const line = this.buf.slice(0, nl);
        this.buf = this.buf.slice(nl + 1);
        const msg = JSON.parse(line);
        if ("sqlReq" in msg) {
          this.#handleSqlReq(msg.sqlReq);
          continue;
        }
        const waiter = this.queue.shift();
        if (waiter) waiter.resolve(msg);
      }
    });
    this.proc.on("exit", (code) => {
      while (this.queue.length > 0) {
        this.queue.shift().reject(new Error(`gate2 driver exited ${code}: ${this.stderr}`));
      }
    });
  }

  #handleSqlReq({ op, args }) {
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
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "pion-gate2-driver-"));
  const srcDir = path.join(tmpDir, "src");
  fs.mkdirSync(srcDir, { recursive: true });
  const baseDir = path.join(repoRoot, "pion/base/packages");
  const rulesDir = path.join(repoRoot, "pion/rules/packages");
  const ccPkgs = path.join(clientCoreRoot, "packages");
  const toml = `[package]
name = "gate2_driver"
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
form = { workspace = true }
lock = { workspace = true }
shell = { workspace = true }
sql = { workspace = true }
sync = { workspace = true }
`;
  fs.writeFileSync(path.join(tmpDir, "pion.toml"), toml, "utf8");
  fs.copyFileSync(path.join(clientCoreRoot, "pion.lock"), path.join(tmpDir, "pion.lock"));
  fs.writeFileSync(path.join(srcDir, "main.pion"), DRIVER_MAIN_PION, "utf8");

  driverBin = path.join(tmpDir, "gate2_driver");
  execFileSync(pioncBin, ["build", "-o", driverBin, tmpDir], {
    cwd: repoRoot,
    stdio: "inherit",
  });
  rpc = new Gate2DriverClient(driverBin);
});

after(() => {
  if (rpc) rpc.close();
  if (tmpDir && fs.existsSync(tmpDir)) fs.rmSync(tmpDir, { recursive: true, force: true });
});

test("Gate #2a: P-256 curve validation & strict base64url differential parity (Node shared/lock.ts vs Pion sync::valid_key_id)", async () => {
  // Generate a real NIST P-256 uncompressed public key (0x04 || x || y)
  const { publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwk = publicKey.export({ format: "jwk" });
  const xBuf = Buffer.from(jwk.x, "base64url");
  const yBuf = Buffer.from(jwk.y, "base64url");
  assert.equal(xBuf.length, 32);
  assert.equal(yBuf.length, 32);
  const validPt = Buffer.concat([Buffer.from([0x04]), xBuf, yBuf]);
  const validB64 = validPt.toString("base64url");

  // Off-curve point (y + 1 mod 256 on last byte)
  const offCurve = Buffer.from(validPt);
  offCurve[64] = (offCurve[64] + 1) & 0xff;

  // Point at infinity (0x04 || 0..0 || 0..0)
  const zeroPt = Buffer.alloc(65, 0);
  zeroPt[0] = 0x04;

  // x >= p (x = p) and y >= p (y = p)
  const pBuf = Buffer.from("ffffffff00000001000000000000000000000000ffffffffffffffffffffffff", "hex");
  const xGeP = Buffer.concat([Buffer.from([0x04]), pBuf, yBuf]);
  const yGeP = Buffer.concat([Buffer.from([0x04]), xBuf, pBuf]);

  // Non-zero unused trailing 2 bits on char 86 (65 bytes = 520 bits, 87 chars = 522 bits)
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  const lastIdx = alphabet.indexOf(validB64[validB64.length - 1]);
  assert.ok(lastIdx >= 0 && (lastIdx & 3) === 0, "canonical 65-byte base64url last char has 2 zero trailing bits");
  const nonZeroTailB64 = validB64.slice(0, -1) + alphabet[lastIdx | 1];

  // 1:1 parity across ALL vectors: Hermes (`fromB64url` + `@noble/curves`) === Pion (`sync::valid_key_id`) === expected (0 diffs!),
  // and Station (`shared/lock.ts validKeyId`) matches on all curve / Ed25519 / length / trailing-bit vectors!
  const allCases = [
    ["valid P-256 point", `p256:${validB64}`, true, true],
    ["P-256 non-zero unused trailing 2 bits (consensus parity)", `p256:${nonZeroTailB64}`, true, true],
    ["off-curve P-256 point (y+1)", `p256:${offCurve.toString("base64url")}`, false, false],
    ["P-256 point at infinity (0,0)", `p256:${zeroPt.toString("base64url")}`, false, false],
    ["P-256 x >= p", `p256:${xGeP.toString("base64url")}`, false, false],
    ["P-256 y >= p", `p256:${yGeP.toString("base64url")}`, false, false],
    ["valid Ed25519 lower hex", `ed25519:${"a".repeat(64)}`, true, true],
    ["invalid Ed25519 uppercase hex", `ed25519:${"A".repeat(64)}`, false, false],
    ["invalid Ed25519 short hex", "ed25519:deadbeef", false, false],
    ["overlong key id (>200 chars)", `p256:${validB64}${"a".repeat(120)}`, false, false],
    ["unknown prefix", `rsa:${validB64}`, false, false],
    // Strict base64url alphabet / no-padding vectors (Hermes `fromB64url` & Pion both reject!)
    ["padded base64url (=)", `p256:${validB64}=`, false, null],
    ["whitespace in base64url", `p256:${validB64.slice(0, 10)} ${validB64.slice(10)}`, false, null],
    ["standard base64 + char", `p256:${validB64.slice(0, 10)}+${validB64.slice(11)}`, false, null],
    ["standard base64 / char", `p256:${validB64.slice(0, 10)}/${validB64.slice(11)}`, false, null],
  ];

  for (const [label, id, expected, expectedNodeTs] of allCases) {
    const hermesRes = hermesValidKeyId(id);
    const pionRes = await rpc.call("validKeyId", { id });
    assert.equal(hermesRes, expected, `Hermes validKeyId mismatch for ${label}`);
    assert.equal(pionRes, expected, `Pion valid_key_id mismatch for ${label}`);
    assert.equal(pionRes, hermesRes, `Hermes vs Pion parity mismatch (0 diffs required) for ${label}`);
    if (expectedNodeTs !== null) {
      const tsRes = tsValidKeyId(id);
      assert.equal(tsRes, expectedNodeTs, `TS shared/lock.ts validKeyId mismatch for ${label}`);
      assert.equal(pionRes, tsRes, `TS Station vs Pion parity mismatch for ${label}`);
    }
  }
});

test("Gate #2b: Real node:sqlite genesis root pinning, anti-hijack, anti-rollback, restart persistence, fork switch, and workspace isolation", async () => {
  const dbPath = path.join(os.tmpdir(), `pion-gate2-sqlite-${process.pid}.db`);
  try {
    const time = new TestTime();
    {
      const initSql = makeNodeSql(dbPath);
      const initAcct = new AccountDb("sub-1", "gate2-init", initSql, new Runner(time.clock), makeDummyDerive());
      initAcct.commitNow();
      initAcct.close();
    }

    const sqlObj = makeNodeSql(dbPath);
    const res = await rpc.call("gate2Scenario", {}, { sql: sqlObj });
    assert.equal(res.error, undefined, `gate2Scenario error: ${res.error}`);
    assert.equal(res.initOk, true, "initial [e0, e1, e2] applied");

    // 1. Anti-hijack: self-signed chain under G_evil != G rejected
    assert.equal(res.hijackRejected, true, "hijack chain under G_evil MUST be rejected");
    assert.equal(res.hijackEvent, true, "LockRejected MUST be emitted on hijack");
    assert.equal(res.afterHijack.genesis, res.rootG, "genesis stays G after hijack");
    assert.equal(res.afterHijack.seq, 2, "seq stays 2 after hijack");
    assert.equal(res.afterHijack.head, res.h2, "head stays hash(e2) after hijack");

    // 1b. Spoofed root G carrying a longer validly self-signed foreign chain [e0_evil..e3_evil]
    assert.equal(res.spoofRejected, true, "spoofed root G with foreign chain MUST be rejected");
    assert.equal(res.spoofEventRejected, true, "LockRejected MUST be emitted on spoofed-root foreign chain");
    assert.equal(res.spoofEventUpdated, false, "LockUpdated MUST NOT be emitted on spoofed-root foreign chain");
    assert.equal(res.afterSpoof.genesis, res.rootG, "genesis stays G after spoofed-root foreign chain");
    assert.equal(res.afterSpoof.seq, 2, "seq stays 2 after spoofed-root foreign chain");
    assert.equal(res.afterSpoof.head, res.h2, "head stays hash(e2) after spoofed-root foreign chain");

    // 2. Anti-rollback: old prefix [e0] rejected; high-water preserved
    assert.equal(res.rollbackRejected, true, "prefix rollback [e0] MUST be rejected");
    assert.equal(res.rollbackEvent, true, "LockRejected MUST be emitted on rollback");
    assert.equal(res.afterRollback.seq, 2, "seq stays 2 after rollback attempt");
    assert.equal(res.afterRollback.head, res.h2, "head stays hash(e2) after rollback attempt");

    // 2b. P2: Duplicate high-water head [e2] returns Ok silently (0 events)
    assert.equal(res.dupHeadOk, true, "duplicate head [e2] returns Ok");
    assert.equal(res.dupHeadEvs, 0, "duplicate head [e2] emits neither LockRejected nor LockUpdated");

    // 3. Restart persistence across brand-new ClientCore on same SQLite DB
    assert.equal(res.restoredRoot, res.rootG, "pinned genesis G survived SQLite restart");
    assert.equal(res.restoredStatus.genesis, res.rootG, "restored lock status has genesis G");
    assert.equal(res.restoredStatus.seq, 2, "restored lock status has seq=2");
    assert.equal(res.restoredStatus.head, res.h2, "restored lock status has head=hash(e2)");
    assert.equal(res.hijackAfterRestartRejected, true, "G_evil STILL rejected after restart");

    // 4. Legitimate higher-weight competing fork under same G switches cleanly & keeps displaced branch in aside
    assert.equal(res.forkOk, true, "legitimate owner fork accepted");
    assert.equal(res.forkHead, res.h1Alice, "head switched to Alice owner fork");
    assert.equal(res.forkHasDave, true, "active state has winning member dave");
    assert.equal(res.forkHasCarol, false, "active state dropped beaten member carol");
    assert.equal(res.asideCount, 2, "displaced [e1, e2] retained in lock_kept_aside");

    // 4b. Pion -> Hermes migration: verify SQLite `workspace_pref(ws, 'lock')` 1:1 matches TS `views/lock.ts:1249`
    const prefRows = sqlObj.all("SELECT json FROM workspace_pref WHERE workspace = 'ws-gate2' AND key = 'lock'");
    assert.equal(prefRows.length, 1, "workspace_pref(ws-gate2, 'lock') persisted in SQLite");
    const persisted = JSON.parse(prefRows[0][0]);
    assert.equal(persisted.head.genesis, res.rootG, "TS format head.genesis === G");
    assert.equal(persisted.head.seq, 1, "TS format head.seq === 1 after fork switch");
    assert.equal(persisted.head.hash, res.h1Alice, "TS format head.hash === h1Alice");
    assert.ok(Array.isArray(persisted.entries) && persisted.entries.length === 2, "TS format entries length === 2");
    assert.ok(Array.isArray(persisted.aside) && persisted.aside.length === 2, "TS format aside length === 2");
    const legacyAccountDoc = sqlObj.all("SELECT 1 FROM account_doc WHERE name = 'lock:ws-gate2'");
    assert.equal(legacyAccountDoc.length, 0, "MUST NOT write lock state to account_doc");

    // 4c. Hermes -> Pion migration: write exact TS `views/lock.ts:1249` JSON into `workspace_pref('ws-gate2', 'lock')`
    //     with `seen: [...]`, restart Pion ClientCore, and verify G_evil is rejected & state stays G / seq=2!
    const tsWritten = {
      head: { seq: 2, hash: res.h2, genesis: res.rootG },
      entries: [res.e0, res.e1, res.e2],
      seen: [{ device: "dev-ts-1", at: 1790000099 }],
    };
    sqlObj.run("INSERT OR REPLACE INTO workspace_pref (workspace, key, json) VALUES (?, ?, ?)", [
      "ws-gate2",
      "lock",
      JSON.stringify(tsWritten),
    ]);
    const migRes = await rpc.call(
      "restoreAndAttack",
      { ws: "ws-gate2", rootEvil: res.rootEvil, e0Evil: res.e0Evil },
      { sql: sqlObj },
    );
    assert.equal(migRes.corrupt, false, "valid TS workspace_pref lock restored cleanly");
    assert.equal(migRes.pinned, res.rootG, "Hermes->Pion restored pinned G");
    assert.equal(migRes.status.genesis, res.rootG, "Hermes->Pion status genesis === G");
    assert.equal(migRes.status.seq, 2, "Hermes->Pion status seq === 2");
    assert.equal(migRes.status.head, res.h2, "Hermes->Pion status head === h2");
    assert.equal(migRes.attackRejected, true, "Hermes->Pion rejects G_evil after migration");
    assert.equal(migRes.attackEvent, true, "Hermes->Pion emits LockRejected on G_evil");

    // 4d. Corrupt persisted record MUST NOT degrade to TOFU!
    sqlObj.run("INSERT OR REPLACE INTO workspace_pref (workspace, key, json) VALUES (?, ?, ?)", [
      "ws-corrupt",
      "lock",
      "{corrupt",
    ]);
    const corRes = await rpc.call(
      "restoreAndAttack",
      { ws: "ws-corrupt", rootEvil: res.rootEvil, e0Evil: res.e0Evil },
      { sql: sqlObj },
    );
    assert.equal(corRes.corrupt, true, "corrupt workspace_pref flagged as corrupt");
    assert.equal(corRes.initRejected, true, "corrupt workspace_pref emits LockRejected on startup");
    assert.equal(corRes.attackRejected, true, "corrupt workspace_pref rejects G_evil (refuses TOFU reset)");
    assert.equal(corRes.attackEvent, true, "corrupt workspace_pref emits LockRejected on attack");

    // 4e. Valid TS unlocked workspace (`{"head": null, "entries": [], "seen": [...]}`) MUST NOT be treated as corrupt
    //     and MUST allow first-time lock enablement while preserving `seen`!
    const tsUnlocked = {
      head: null,
      entries: [],
      seen: [{ device: "dev-unlocked-1", at: 1790000011 }],
    };
    sqlObj.run("INSERT OR REPLACE INTO workspace_pref (workspace, key, json) VALUES (?, ?, ?)", [
      "ws-gate2",
      "lock",
      JSON.stringify(tsUnlocked),
    ]);
    const unlRes = await rpc.call(
      "restoreAndAttack",
      { ws: "ws-gate2", rootEvil: res.rootG, e0Evil: res.e0 },
      { sql: sqlObj },
    );
    assert.equal(unlRes.corrupt, false, "TS unlocked record head:null + entries:[] is NOT corrupt");
    assert.equal(unlRes.initRejected, false, "TS unlocked record emits no LockRejected on startup");
    assert.equal(unlRes.attackRejected, false, "TS unlocked workspace allows first-time lock enablement");
    assert.equal(unlRes.status.genesis, res.rootG, "first-time lock enabled cleanly with genesis G");
    const afterUnlockPref = JSON.parse(
      sqlObj.all("SELECT json FROM workspace_pref WHERE workspace = 'ws-gate2' AND key = 'lock'")[0][0],
    );
    assert.deepEqual(afterUnlockPref.seen, tsUnlocked.seen, "seen array preserved across unlocked -> locked transition");

    // 5. Workspace isolation (Gate #9): querying another workspace leaks nothing
    assert.equal(res.otherStatus.workspace, "ws-other");
    assert.equal(res.otherStatus.locked, false);
    assert.equal("genesis" in res.otherStatus, false, "cross-workspace lock.status must not leak genesis");
    assert.ok(res.otherTopicRaw.includes('"value"'), `cross-workspace lock topic must return a real value event, got: ${res.otherTopicRaw}`);
    assert.ok(!res.otherTopicRaw.includes('"error"'), `cross-workspace lock topic must not return an error, got: ${res.otherTopicRaw}`);
    assert.ok(!res.otherTopicRaw.includes(res.rootG), "cross-workspace lock topic must not leak genesis");
    assert.ok(!res.otherTopicRaw.includes("alice"), "cross-workspace lock topic must not leak members");

    sqlObj.close();
  } finally {
    for (const suffix of ["", "-wal", "-shm"]) {
      if (fs.existsSync(dbPath + suffix)) fs.unlinkSync(dbPath + suffix);
    }
  }
});
