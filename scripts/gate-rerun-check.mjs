#!/usr/bin/env node
// A branch's run attempted again (GitHub's "Re-run jobs") goes through its gate (pipeline.yml) only where every job
// that failed or was cancelled in the attempts before it failed for GitHub's or the network's sake: a check that failed
// and passes on the same commit let something uncontrolled in, and is found and taken out, never rerun green (the root
// AGENTS.md). Let through, a job of an attempt before:
//   - that never ran what it is for: no runner took it, it has no steps, or what failed of it is only the job's setting
//     up (its runner's own steps, the checkout, the caches and artifacts, the toolchains: INFRA_STEP);
//   - cancelled with its whole run (a push after it, by hand, a dead runner's queue given up), before a job's time;
//   - whose step failed with GitHub's or the network's failure in its log (INFRA_LOG), and nothing a check says when it
//     fails (CHECK_FAILED) or a limit reached.
// Never one that ran its time out: 285 s or more (a job's 5 minutes, less what its runner takes to cut it), or a limit
// said in its log (scripts/with-timeout.sh's, the job's own). What cannot be read (a log gone) is not let through.
// The attempts' jobs are read from GitHub's API (GH_TOKEN, actions: read), or, for the tests, from
// GATE_RERUN_FIXTURE_DIR: attempt-<n>.json ({ run: { conclusion }, jobs: [...] }, the API's shapes) and
// logs/<job id>.txt.
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

/** Seconds a job may run before it counts as having run its time out (a job's 5 minutes, less the runner's cutting). */
export const RAN_OUT_S = 285;
/** The steps that only set a job up: the runner's own, the checkout, the caches and artifacts, the toolchains. */
export const INFRA_STEP =
  /^(Set up job|Complete job|Post |Checkout|Run actions\/(checkout|cache|upload-artifact|download-artifact|setup-node)|Run \.\/\.github\/actions\/(node|setup|apt|msvc|mbui-moonbit))/;
/** GitHub's or the network's failure, as a log says it. */
export const INFRA_LOG = [
  /\b50[234] (Bad Gateway|Service Unavailable|Gateway Time-?out)\b/i,
  /\bHTTP\/[0-9.]+ 50[234]\b|\bstatus(?: code)?:? 50[234]\b|\breturned 50[234]\b/i,
  /Runner lost communication|lost communication with the server/i,
  /TLS handshake timeout/i,
  /\b(ETIMEDOUT|ECONNRESET|ECONNREFUSED|EAI_AGAIN|socket hang up)\b.*\b(github\.com|githubusercontent\.com|results-receiver|nuget\.org|nodejs\.org)\b/,
  /\b(github\.com|githubusercontent\.com|results-receiver|nuget\.org|nodejs\.org)\b.*\b(ETIMEDOUT|ECONNRESET|ECONNREFUSED|EAI_AGAIN|socket hang up)\b/,
];
/** The runner shut down under the job: GitHub's, but only before the job's time (after it, the job ran out). */
const SHUTDOWN = /The runner has received a shutdown signal/i;
/** What a check says when it fails, and a limit reached: never GitHub's. */
export const CHECK_FAILED = [
  /\btest\b.*\bfailed\b/i,
  /\bFAILED\b/,
  /^✖ /m,
  /^not ok \d/m,
  /AssertionError|ERR_ASSERTION/,
  /\berror(\[E\d+\]|: could not compile| TS\d+)/,
  /\bexit(ed)?( with)?( code)?:? 124\b/i,
  /\bnot done after\b/,
  /exceeded the maximum execution time/i,
];

const seconds = (j) => (j.started_at && j.completed_at ? (Date.parse(j.completed_at) - Date.parse(j.started_at)) / 1000 : 0);
const BAD = new Set(["failure", "timed_out", "cancelled"]);

/** Strips each log line's timestamp (`2026-11-17T09:20:19.1234567Z `), which GitHub writes before it. */
const lines = (log) => log.replace(/^\d{4}-\d\d-\d\dT[0-9:.]+Z /gm, "");

/**
 * Why a job of an attempt before is let through ({ ok: true, why }) or not ({ ok: false, why }).
 * @param job the API's job; @param run the attempt's run ({ conclusion }); @param log reads the job's log (null: gone).
 */
export async function judge(job, run, log) {
  const took = Math.round(seconds(job));
  if (!job.runner_name) return { ok: true, why: "no runner took it" };
  if (job.conclusion === "timed_out" || took >= RAN_OUT_S) return { ok: false, why: `ran its time out (${took} s)` };
  const steps = job.steps ?? [];
  if (steps.length === 0) return { ok: true, why: "it ran no step" };
  const failed = steps.filter((s) => BAD.has(s.conclusion));
  const own = failed.filter((s) => !INFRA_STEP.test(s.name));
  if (own.length === 0) return { ok: true, why: failed.length ? `only its setting up failed (${failed.map((s) => s.name).join(", ")})` : "none of its steps failed" };
  const names = own.map((s) => s.name).join(", ");
  if (job.conclusion === "cancelled" && run.conclusion === "cancelled") {
    return { ok: true, why: `cancelled with its run after ${took} s (in ${names})` };
  }
  const text = await log();
  if (text == null) return { ok: false, why: `${names} failed, and its log cannot be read to say why` };
  const said = lines(text);
  const check = CHECK_FAILED.find((p) => p.test(said));
  if (check) {
    const at = said.split("\n").find((l) => check.test(l))?.trim().slice(0, 160);
    return { ok: false, why: `${names} failed: ${at ?? check}` };
  }
  const infra = [...INFRA_LOG, SHUTDOWN].find((p) => p.test(said));
  if (infra) {
    const at = said.split("\n").find((l) => infra.test(l))?.trim().slice(0, 160);
    return { ok: true, why: `${names} failed for GitHub's or the network's sake: ${at}` };
  }
  return { ok: false, why: `${names} failed, and its log says nothing of GitHub's or the network's` };
}

/** Where the attempts are read from: GitHub's API, or a test's directory. */
export function source(env = process.env) {
  if (env.GATE_RERUN_FIXTURE_DIR) {
    const dir = env.GATE_RERUN_FIXTURE_DIR;
    return {
      attempt: async (n) => JSON.parse(await readFile(join(dir, `attempt-${n}.json`), "utf8")),
      log: async (id) => readFile(join(dir, "logs", `${id}.txt`), "utf8").catch(() => null),
    };
  }
  const api = env.GITHUB_API_URL || "https://api.github.com";
  const token = env.GH_TOKEN || env.GITHUB_TOKEN;
  const repo = env.GITHUB_REPOSITORY;
  const id = env.GITHUB_RUN_ID;
  if (!token || !repo || !id) throw new Error("GH_TOKEN, GITHUB_REPOSITORY and GITHUB_RUN_ID are needed");
  const get = async (path, accept = "application/vnd.github+json") => {
    // (timer: a timeout, the job's own 2 minutes being what it has)
    const res = await fetch(`${api}${path}`, { headers: { authorization: `Bearer ${token}`, accept, "x-github-api-version": "2022-11-28" }, signal: AbortSignal.timeout(30_000) });
    if (!res.ok) throw new Error(`GET ${path}: ${res.status}`);
    return res;
  };
  return {
    attempt: async (n) => {
      const run = await (await get(`/repos/${repo}/actions/runs/${id}/attempts/${n}`)).json();
      const jobs = [];
      for (let page = 1; ; page++) {
        const got = await (await get(`/repos/${repo}/actions/runs/${id}/attempts/${n}/jobs?per_page=100&page=${page}`)).json();
        jobs.push(...got.jobs);
        if (got.jobs.length < 100 || jobs.length >= got.total_count) break;
      }
      return { run, jobs };
    },
    log: async (job) => get(`/repos/${repo}/actions/jobs/${job}/logs`, "application/vnd.github+json").then((r) => r.text(), () => null),
  };
}

/** Every attempt before this one judged; prints each job let through or not; whether all were. */
export async function check(env = process.env, out = console) {
  const attempt = Number(env.GITHUB_RUN_ATTEMPT || "1");
  if (!(attempt > 1)) return true;
  const from = source(env);
  const refused = [];
  for (let n = 1; n < attempt; n++) {
    const { run, jobs } = await from.attempt(n);
    for (const job of jobs) {
      // (the gate itself failed for the jobs it waits on: those are judged)
      if (!BAD.has(job.conclusion) || job.name === "gate") continue;
      const v = await judge(job, run, () => from.log(job.id));
      out.log(`attempt ${n}: ${job.name}: ${v.ok ? "let through" : "NOT let through"}: ${v.why}`);
      if (!v.ok) refused.push(`attempt ${n}: ${job.name}: ${v.why}`);
    }
  }
  if (refused.length === 0) return true;
  out.log(
    `::error::This run is attempt ${attempt}, and an attempt before it failed for what the change does, not for GitHub's or the network's sake:\n` +
      refused.map((r) => `  ${r}`).join("\n") +
      "\nA check that failed, or ran its time out, is never rerun green: find what let it fail, fix it in a new commit and push that (the root AGENTS.md).",
  );
  return false;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  check().then(
    (ok) => process.exit(ok ? 0 : 1),
    (e) => {
      console.log(`::error::the attempts before this one could not be read: ${e.message}`);
      process.exit(1);
    },
  );
}
