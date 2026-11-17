// GitHub Actions run previews, as station/src/links/actions-run.ts.

///|
fn actions_target(path : String) -> (String, String, String?)? {
  let ps = split(if ends(path, "/") { slice(path, 0, path.length() - 1) } else { path }, "/")
  guard ps.length() == 6 || ps.length() == 8 else { return None }
  let named = (s : String) => s != "" && s.iter().all(c => is_word_unit(c.to_int()) || c == '-' || c == '.')
  guard ps[0] == "" && named(ps[1]) && named(ps[2]) && ps[3] == "actions" && ps[4] == "runs" && all_digits(ps[5]) else { return None }
  let attempt = if ps.length() == 8 {
    guard ps[6] == "attempts" && all_digits(ps[7]) else { return None }
    Some(ps[7])
  } else { None }
  Some((ps[1] + "/" + ps[2], ps[5], attempt))
}

///|
fn job_group(job : Json) -> String {
  match text(job, "status") {
    "in_progress" => "running"
    "completed" =>
      match text(job, "conclusion") {
        "success" => "passed"
        "neutral" | "cancelled" | "skipped" as state => state
        _ => "failed"
      }
    _ => "queued"
  }
}

///|
async fn actions_preview(io : LinkIo, href : String, repository : String, id : String, attempt : String?) -> Json {
  let base = "repos/" + repository + "/actions/runs/" + id
  let run = (io.github_api)(match attempt { Some(n) => base + "/attempts/" + n; None => base })
  let out : Map[String, Json] = {
    "kind": jstr("github_actions_run"), "url": jstr(href), "repository": jstr(repository),
    "number": field_or_null(run, "run_number"), "title": jstr(text(run, "display_title")),
    "workflow": jstr(text(run, "name")), "branch": jstr(text(run, "head_branch")), "commit": jstr(slice(text(run, "head_sha"), 0, 7)),
    "state": jstr(if text(run, "conclusion") != "" { text(run, "conclusion") } else { text(run, "status") }),
    "startedAt": when_of(field(run, "run_started_at")),
  }
  if text(run, "status") == "completed" { out["finishedAt"] = when_of(field(run, "updated_at")) }
  let number = attempt.unwrap_or(js_text_or_empty(field(run, "run_attempt")))
  try {
    let counts : Map[String, Int] = Map([])
    let failed : Array[Json] = []
    let active : Array[Json] = []
    let seen : Map[String, Bool] = Map([])
    for page = 1; ; page = page + 1 {
      let result = (io.github_api)(base + "/attempts/" + number + "/jobs?per_page=100&page=" + page.to_string())
      guard field(result, "jobs") is Some(Array(jobs)) else { raise HostError("missing jobs") }
      for j in jobs {
        let key = js_text_or_empty(field(j, "id"))
        if seen.contains(key) { continue }
        seen[key] = true
        let g = job_group(j)
        counts[g] = counts.get(g).unwrap_or(0) + 1
        if g == "failed" && failed.length() < 2 { failed.push(j) }
        if g == "running" && active.length() < 2 { active.push(j) }
      }
      if jobs.length() < 100 || (page * 100).to_double() >= num(field(result, "total_count")).unwrap_or(0.0) { break }
    }
    let selected : Array[Json] = []
    for j in failed + active {
      if selected.length() == 2 { break }
      let status = job_group(j)
      let mut step = ""
      let mut link = "https://github.com/" + repository + "/actions/runs/" + id + "/job/" + js_text_or_empty(field(j, "id"))
      if field(j, "steps") is Some(Array(steps)) {
        for s in steps {
          if job_group(s) == status {
            step = text(s, "name")
            if num(field(s, "number")) is Some(n) && n > 0.0 { link += "#step:" + js_number(n) + ":1" }
            break
          }
        }
      }
      selected.push(obj([("name", jstr(text(j, "name"))), ("step", jstr(step)), ("url", jstr(link))]))
    }
    let totals : Map[String, Json] = Map([])
    for group, n in counts { totals[group] = jint(n) }
    out["counts"] = Json::object(totals)
    out["jobs"] = Json::array(selected)
  } catch { _ => () }
  Json::object(out)
}
