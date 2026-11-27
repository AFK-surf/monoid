#!/usr/bin/env node
// Cold-start smoke test: real `client/core-ts` Node Core (empty data directory,
// emitting real `{ id: 0, auth }` first handshake + `accounts: []`) wired to the
// real `apps/mbui` app tree (`@sfapp.app_tree` + `@sfapp.wire_core_client`).
// Fails if the app reports any fatal error or stays stuck on `Starting` instead
// of reaching `Sign in` (`SignedOut`) within the deadline.
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const mbuiDir = resolve(scriptDir, "..");
const repoRoot = resolve(mbuiDir, "..", "..");
const timeoutMs = Number(process.env.COLD_START_TIMEOUT_MS || "5000");

function buildHarness() {
  const prebuilt = process.env.MBUI_COLD_START_JS;
  if (prebuilt) return resolve(prebuilt);
  const t0 = performance.now();
  execFileSync(
    "bash",
    ["-c", '. scripts/env.sh && moon build --target js --release src/sfcoldstart'],
    { cwd: mbuiDir, stdio: "inherit" },
  );
  const elapsed = Math.round(performance.now() - t0);
  console.log(`cold-start-smoke: built sfcoldstart (js) in ${elapsed} ms`);
  return resolve(mbuiDir, "_build/js/release/build/stillfail/sfcoldstart/sfcoldstart.js");
}

const harnessPath = buildHarness();
const mbui = await import(pathToFileURL(harnessPath).href);
const { start } = await import(pathToFileURL(resolve(repoRoot, "client/core-ts/src/hosts/node.ts")).href);

const dataDir = mkdtempSync(join(tmpdir(), "mbui-cold-start-"));
let core;
let timer;

try {
  let authHandshake = null;
  let accountsSubId = null;
  let accountsValue = null;
  let fatalMsg = null;
  const seenKinds = [];
  const tStart = performance.now();

  let resolveDone;
  let rejectDone;
  const done = new Promise((resolve, reject) => {
    resolveDone = resolve;
    rejectDone = reject;
  });

  let clientId = 0;

  function flushOutbox() {
    const out = JSON.parse(mbui.cold_start_take_outbox());
    for (const raw of out) {
      try {
        const parsed = JSON.parse(raw);
        if (
          (parsed.subscribe === "accounts" || parsed.subscribe?.topic === "accounts") &&
          typeof parsed.id === "number"
        ) {
          accountsSubId = parsed.id;
        }
      } catch {}
      core.receive(clientId, raw);
    }
  }

  core = start(
    dataDir,
    "http://127.0.0.1:1",
    (_cid, json) => {
    let parsed = null;
    try {
      parsed = JSON.parse(json);
    } catch {}
    if (parsed) {
      if (parsed.fatal) {
        fatalMsg = String(parsed.fatal);
        seenKinds.push(`fatal:${fatalMsg}`);
      } else if (parsed.id === 0 && parsed.auth && typeof parsed.auth === "object") {
        authHandshake = parsed.auth;
        seenKinds.push(`auth(conn=${parsed.auth.conn},global=${parsed.auth.global},agg=${parsed.auth.aggregate})`);
      } else if (accountsSubId !== null && parsed.id === accountsSubId && "value" in parsed) {
        accountsValue = parsed.value;
        seenKinds.push(`accounts(len=${Array.isArray(parsed.value) ? parsed.value.length : typeof parsed.value})`);
      } else {
        seenKinds.push(`id=${parsed.id}`);
      }
    }

    mbui.cold_start_receive(json);
    flushOutbox();
    mbui.cold_start_frame();

    const fatal = mbui.cold_start_fatal();
    if (fatal || fatalMsg) {
      rejectDone(new Error(`cold-start fatal error: ${fatal || fatalMsg}`));
      return;
    }

    const state = mbui.cold_start_state();
    const journal = mbui.cold_start_journal();
    if (authHandshake && Array.isArray(accountsValue) && state === "SignedOut" && journal === "Sign in") {
      resolveDone({
        state,
        journal,
        elapsedMs: Math.round(performance.now() - tStart),
        authHandshake,
        accountsCount: accountsValue.length,
        seenKinds,
      });
    }
  },
    undefined,
    { hostWire: true },
  );

  // Mount frame 0 first so `app_tree` subscribes to `accounts` before the
  // production Core delivers `{ id: 0, auth }` (matching real cold-start order).
  mbui.cold_start_init();
  const initState = mbui.cold_start_state();
  const initJournal = mbui.cold_start_journal();
  if (initState !== "Starting" || initJournal !== "Starting") {
    throw new Error(`expected initial state Starting/Starting before Core handshake, got ${initState}/${initJournal}`);
  }

  clientId = core.connect();
  flushOutbox();
  if (accountsSubId === null) {
    throw new Error("expected apps/mbui frame 0 to subscribe to `accounts`");
  }

  timer = setTimeout(() => {
    const state = mbui.cold_start_state();
    const journal = mbui.cold_start_journal();
    const fatal = mbui.cold_start_fatal();
    rejectDone(
      new Error(
        `cold-start timed out after ${timeoutMs} ms: stuck in state=${state} journal=${journal} fatal=${fatal || "none"} ` +
          `authHandshake=${Boolean(authHandshake)} accountsReceived=${Array.isArray(accountsValue)} messages=[${seenKinds.join(", ")}]`,
      ),
    );
  }, timeoutMs);

  const result = await done;
  console.log(
    `cold-start-smoke: PASS (${result.elapsedMs} ms) state=${result.state} journal="${result.journal}" ` +
      `accounts=${result.accountsCount} auth={conn:${result.authHandshake.conn},global:${result.authHandshake.global},aggregate:${result.authHandshake.aggregate}} ` +
      `messages=[${result.seenKinds.join(", ")}]`,
  );
} finally {
  clearTimeout(timer);
  if (core) await core.close().catch(() => {});
  rmSync(dataDir, { recursive: true, force: true });
}
