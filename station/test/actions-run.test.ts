import assert from "node:assert/strict";
import { test } from "node:test";
import { actionsRun, actionsRunOf } from "../src/links/actions-run.ts";

const url = new URL("https://github.com/o/r/actions/runs/12345678901?check_suite_focus=true");
const run = { run_number: 42, run_attempt: 2, name: "deploy", display_title: "Ship", status: "in_progress", conclusion: null,
  head_branch: "main", head_sha: "123456789", run_started_at: "2026-01-01T12:00:00Z", updated_at: "2026-01-01T12:06:00Z" };
const base = "repos/o/r/actions/runs/12345678901";

test("a run and a specific attempt are recognized, unrelated URLs are left alone", () => {
  assert.equal(actionsRunOf(url)?.id, "12345678901");
  assert.equal(actionsRunOf(new URL(url.origin + url.pathname + "/attempts/1/"))?.attempt, "1");
  for (const h of ["https://other.com/o/r/actions/runs/1", url.href.replace("12345678901", "123extra"), url.origin + url.pathname + "/job/2"]) {
    assert.equal(actionsRunOf(new URL(h)), null);
  }
});

test("all pages count, a failed step on the next page precedes the current running step", async () => {
  const jobs = Array.from({ length: 98 }, (_, id) => ({ id, status: "completed", conclusion: "success" }));
  const step = { name: "Package app", number: 3, conclusion: null, status: "in_progress" };
  const result = await actionsRun(url, actionsRunOf(url)!, async path => {
    if (path === base) return run;
    if (path === base + "/attempts/2/jobs?per_page=100&page=1") return { total_count: 101, jobs: [...jobs,
      { id: 98, status: "completed", conclusion: "skipped" }, { id: 99, name: "package", status: "in_progress", steps: [step] }] };
    assert.equal(path, base + "/attempts/2/jobs?per_page=100&page=2");
    return { total_count: 101, jobs: [{ id: 100, name: "build", status: "completed", conclusion: "failure",
      steps: [{ ...step, status: "completed", conclusion: "success" }, { ...step, name: "Sign", number: 4, status: "completed", conclusion: "failure" }] }] };
  });
  assert.deepEqual(result.counts, { passed: 98, skipped: 1, running: 1, failed: 1 });
  assert.deepEqual(result.jobs, [
    { name: "build", step: "Sign", url: url.origin + url.pathname + "/job/100#step:4:1" },
    { name: "package", step: "Package app", url: url.origin + url.pathname + "/job/99#step:3:1" },
  ]);
  assert.equal(result.state, "in_progress");
  assert.equal(result.finishedAt, undefined);
});

test("an ended attempt retains its result and elapsed interval if its jobs are unavailable", async () => {
  const attempt = new URL(url.origin + url.pathname + "/attempts/1");
  const result = await actionsRun(attempt, actionsRunOf(attempt)!, async path => {
    if (path === base + "/attempts/1") return { ...run, status: "completed", conclusion: "success", run_attempt: 1 };
    throw new Error("jobs unavailable");
  });
  assert.equal(result.state, "success");
  assert.equal(result.finishedAt! - result.startedAt, 360000);
  assert.equal(result.counts, undefined);
});
