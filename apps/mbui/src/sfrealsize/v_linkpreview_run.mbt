// Made by client/core-ts/test/real-size-app.test.ts (REAL_SIZE_WRITE=1): what the core sends `linkPreview run` whole on a
// workspace of real size.
///|
fn init {
  let asked =
    #|{"topic":"linkPreview","station":"ws/maple","url":"https://github.com/acme/app/actions/runs/44147606865"}
  let value =
    #|{"kind":"github_actions_run","url":"https://github.com/acme/app/actions/runs/44147606865","title":"Build and publish the desktop app","repository":"acme/app","number":23849,"state":"in_progress","workflow":"pipeline","branch":"main","commit":"bc074d6","startedAt":1791276540000,"elapsed":"11 分 0 秒","counts":{"passed":7,"running":16,"skipped":6},"jobs":[{"name":"desktop-win","step":"Build, pack and sign the beta Windows app","url":"https://github.com/acme/app/actions/runs/44147606865/job/123#step:2:1"},{"name":"check-linux","step":"Full check (ts)","url":"https://github.com/acme/app/actions/runs/44147606865/job/456#step:3:1"}]}
  put(asked, value)
}
