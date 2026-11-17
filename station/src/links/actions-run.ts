// A run's card uses the jobs of the same attempt as its heading. Only two jobs cross the mesh.
type Step = { name: string; number: number; status: string; conclusion: string | null };
type Job = { id: number; name: string; status: string; conclusion: string | null; steps?: Step[] };
type Run = {
  name: string; display_title: string; run_number: number; run_attempt: number; head_branch: string | null; head_sha: string;
  status: string; conclusion: string | null; run_started_at: string; updated_at: string;
};

export type RunPreview = {
  kind: "github_actions_run"; url: string; title: string; repository: string; number: number; state: string;
  workflow: string; branch: string; commit: string; startedAt: number; finishedAt?: number;
  counts?: Record<string, number>; jobs?: { name: string; step: string; url: string }[];
};

export function actionsRunOf(url: URL): { repository: string; id: string; attempt?: string } | null {
  if (!["https:", "http:"].includes(url.protocol) || url.hostname !== "github.com") return null;
  const m = /^\/([\w.-]+\/[\w.-]+)\/actions\/runs\/(\d+)(?:\/attempts\/(\d+))?\/?$/.exec(url.pathname);
  return m ? { repository: m[1]!, id: m[2]!, attempt: m[3] } : null;
}

function group(status: string, conclusion: string | null): string {
  if (status !== "completed") return status === "in_progress" ? "running" : "queued";
  switch (conclusion) {
    case "success": return "passed";
    case "neutral": case "skipped": case "cancelled": return conclusion;
    default: return "failed";
  }
}

export async function actionsRun(url: URL, target: NonNullable<ReturnType<typeof actionsRunOf>>,
  api: (path: string) => Promise<any>): Promise<RunPreview> {
  const { repository, id, attempt } = target;
  const base = `repos/${repository}/actions/runs/${id}`;
  const run: Run = await api(attempt ? `${base}/attempts/${attempt}` : base);
  const preview: RunPreview = {
    kind: "github_actions_run", url: url.href, repository, number: run.run_number,
    workflow: run.name, title: run.display_title, state: run.conclusion ?? run.status,
    branch: run.head_branch ?? "", commit: run.head_sha.slice(0, 7), startedAt: Date.parse(run.run_started_at),
    ...(run.status === "completed" ? { finishedAt: Date.parse(run.updated_at) } : {}),
  };
  const counts: Record<string, number> = {};
  const failed: Job[] = [], active: Job[] = [];
  const seen = new Set<number>();
  try {
    for (let page = 1; ; page++) {
      const result = await api(`${base}/attempts/${attempt ?? run.run_attempt}/jobs?per_page=100&page=${page}`);
      const jobs: Job[] = result.jobs;
      for (const job of jobs) {
        if (seen.has(job.id)) continue;
        seen.add(job.id);
        const state = group(job.status, job.conclusion);
        counts[state] = (counts[state] ?? 0) + 1;
        if (state === "failed" && failed.length < 2) failed.push(job);
        if (state === "running" && active.length < 2) active.push(job);
      }
      if (page * 100 >= result.total_count || jobs.length < 100) break;
    }
    preview.counts = counts;
    preview.jobs = failed.concat(active).slice(0, 2).map(job => {
      const step = job.steps?.find(s => job.status === "completed" ? group(s.status, s.conclusion) === "failed" : s.status === "in_progress");
      const link = `https://github.com/${repository}/actions/runs/${id}/job/${job.id}`;
      return { name: job.name, step: step?.name ?? "", url: step?.number ? `${link}#step:${step.number}:1` : link };
    });
  } catch {
    // The run itself can still be shown when the jobs request fails.
  }
  return preview;
}
