///|
/// A machine of a few files (`files`), each its own real path.
fn world_of(files : Array[String]) -> LinkWorld {
  { sep: "/", is_file: p => files.contains(p), realpath: p => if files.contains(p) { Some(p) } else { None } }
}

///|
test "links found as local-links.ts finds them: inline, images, references, autolinks, none in code" {
  let text = "[a](x.md) ![i](<sp ace.png> \"t\") `[c](no.md)`\n\n```\n[f](no.md)\n```\n[r][d] [s]\n\n[d]: /tmp/r.txt\n[s]: <q.md>\n<file:///tmp/z.txt> [esc](a\\(b\\).md)"
  let found = links(text).map(f => (f.inline, f.destination))
  assert_eq(found, [
    (true, "x.md"),
    (true, "sp ace.png"),
    (false, "/tmp/r.txt"),
    // (`[r][d]`'s label read again at `[d]`, as local-links.ts reads it)
    (false, "/tmp/r.txt"),
    (false, "q.md"),
    (false, "file:///tmp/z.txt"),
    (true, "a(b).md"),
  ])
}

///|
test "a post's local links made into its attachments, its refusals in local.rs's words" {
  let w = world_of(["/w/films/a b.mp4", "/w/report.pdf", "/tmp/x/report.pdf", "/Users/u/code.rs"])
  let (text, paths) = prepare_local_links(w, "see [film](films/a%20b.mp4) and [web](https://e.com)", [], "/w")
  assert_eq(text, "see [film](a%20b%2Emp4) and [web](https://e.com)")
  assert_eq(paths, ["/w/films/a b.mp4"])
  let (kept, _) = prepare_local_links(w, "[r](report.pdf)", ["/w/report.pdf"], "/w")
  assert_eq(kept, "[r](report.pdf)")
  let (code, _) = prepare_local_links(w, "[c](/Users/u/code.rs:12:3)", [], "/w")
  assert_eq(code, "[c](code%2Ers)")
  let refused = (t : String, ps : Array[String]) => {
    try {
      ignore(prepare_local_links(w, t, ps, "/w"))
      ""
    } catch {
      LinkRefused(why) => why
    }
  }
  assert_eq(
    refused("[m](films/none.mp4)", []),
    "local file link films/none.mp4 names no file in the workspace (/w) nor one of the message's files; give its absolute path or attach it with files, use a full URL (https://…), or write it as code",
  )
  assert_eq(
    refused("[m](/tmp/none.txt)", []),
    "local file link does not name a readable file: /tmp/none.txt; correct the path or write it as code instead of a link",
  )
  assert_eq(
    refused("[r][d]\n\n[d]: /w/report.pdf", []),
    "local file link /w/report.pdf must use inline Markdown: [label](path); it will be attached automatically",
  )
  assert_eq(refused("[r](/tmp/x/report.pdf)", ["/w/report.pdf"]), "attachments have the same name: report.pdf; rename the files before posting")
  assert_eq(refused("[bad](file://elsewhere/w/report.pdf)", []), "invalid local file link: file://elsewhere/w/report.pdf; use an absolute path in files")
}
