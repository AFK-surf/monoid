# Working on CI (for agents)

- `workflows/pipeline.yml` is the one for pushes: its plan (`scripts/plan.sh`) decides from the paths changed which
  checks run and, on main, what is deployed (the beta of each part); `scripts/plan-covers.ts` checks that every file a
  deployed part is built from deploys it. `contributions` runs forks' pull requests on GitHub's runners with no
  secrets; never give pipeline a fork's trigger.
- A pull request merges once its own checks passed (`gh pr merge --squash`), no queue before it. What a branch's
  pushes leave out, the mbui app's tests and mbui's own at 120, 60, 24 and 7 frames a second, runs on main after the
  merge (`workflows/mbui-check.yml`, `workflows/mbui-ci.yml`; the user, 2026-11-11 15:51 UTC: 「直接合，帧率在 main 上合并后
  跑」); a branch runs at 120, 60 and 24 only the test files it changed of sfapp and of the small packages (sfpages, settings,
  gallery, player, sfgraphic) (`rates-changed`; the user, 2026-11-14:
  「PR 上也跑改到文件的帧率检查」, after four pull requests' own changed tests went red at a rate on main). Red on main
  holds no one back and is mended forward by whoever brought it, never rolled back: the run's
  `rates-said` says what merged since the last run that went through, the likeliest first (`scripts/rates-said.sh`).
- Every job says `timeout-minutes`, 5 at most (`scripts/ci-timeouts.py`; only its `LONGER`, runs of the day's or by
  hand, 10). A job that needs longer is made faster, never finished over several pushes or reruns: a branch's
  mbui-check run cut before its programs were all built keeps none of the units it compiled (test.sh's
  `MBUI_BUILT_MARK`), and main's store keeps what its runs used for three hours. Minutes are whole (the runner cut a
  step's 3.8 at 3): a step that
  must end some seconds before its job, for the caches saved after it, runs under `scripts/with-timeout.sh`
  `@$((JOB_END - 35))` (by what follows it: mbui-check's 25, its app and replay builds' 35 and 65), JOB_END written by the
  job's first step, less its 5 s of setting up. The units' stores of GitHub's images are keyed by the
  image (`IMG`, its `ImageVersion`): two images in turn kept only the last run's units in one.
- No paid runners (GitHub's larger ones): horizontal Linux test slices (`check-station`, `check-core`, and `mbui-check`
  unless `vars.CI_1_MBUI == 'on'`) and small deploy jobs run on GitHub's standard elastic runners; non-Apple `natives`
  (any `ci-1` runner; a branch's Windows reader after it in `natives-win-reader`, each cold reader at -O2 a job's
  five minutes' worth when two shared the cores), `natives-main` and cross-platform `side` parts run on `ci-1` (`linux-ci`, `linux-quick`,
  a 16-core Linux machine; `vars.CI_1 = 'off'` falls back to `macos-ci`), unloading `Mini1`; `check` runs there only when
  the Rust it tests changed (`scripts/plan.sh`'s `check_rust`: ci-1's sccache keeps those builds short), otherwise on
  `ubuntu-24.04` with them left out (`STILLFAIL_SKIP_RUST_TESTS`), so a pull request's check needs no `ci-1` (with its
  line down every one queued until cancelled, 44383403135); a branch's `check-mac`
  runs on GitHub's `macos-26` (main's too with `vars.MINI1 = 'off'`), and a branch plans `natives-mac` only when a job
  of its uses the Apple parts (`check-mac`, `mac-build`, `desktop-build`), on `macos-26` too unless `mesh`,
  `shell-apple` or `reader` is missing (cold builds there took 228, 323 and 223 s before packing); the other Apple parts,
  Xcode/Simulator checks (`side-mac`, iOS/macOS builds), Android's release and main's `station-update` stay on `Mini1`
  (`macos-ci`, `quick`; `vars.MINI1 = 'off'` leaves `station-update` out), the
  Mac app's and the station's release signing on `macos-26` (`desktop`, `station`: their uploads over Mini1's home line
  were cut at five minutes, 2026-11-17), and
  a branch's `natives-mac-main` runs only with `vars.MINI1 = 'on'`. Runners on one
  self-hosted machine share its cores and queue bursts of multi-job workflows, so keep bursty multi-job PR builds and
  parallel real-time test slices on GitHub's separate VMs rather than stacking them on one host.
- A check that failed and passed on the same commit is never rerun green (the root AGENTS.md): a branch's `gate`, in a
  run attempted again, fails unless every job that failed or was cancelled before failed for GitHub's or the network's
  sake (`scripts/gate-rerun-check.mjs`). Do not rerun an old commit's main pipeline: it deploys that commit's beta over
  the newer one.
- An artifact uploaded for people to look at (pictures, logs, what moved) says `continue-on-error: true`: a runner's
  connection to GitHub's artifact service reset fails a check that had passed (main acb00686, 2026-11-01; #5157's
  `offscreen`, 2026-11-10). One a later job downloads does not: there the upload's failure is the job's, unless that
  job does without it (mbui-size's measures and what they measure: `record` carries the one before's for a measure
  missing). mbui-size downloads what it measures by `scripts/download-artifact.sh --optional`, not
  actions/download-artifact, which once ended 0 with half a zip on the disk (43955196994, 2026-11-16): a zip is
  checked by its size and digest, a cut one taken on by Range, and the directory is there only when it came whole.
- A release's deltas (`scripts/release-deltas.ts`: the `deltas-<part>` jobs, each waiting for its own part's build
  alone, `put_feed` in `scripts/release.sh`) never fail or hold back a release: what goes wrong is a warning and that
  delta is left out, the feed whole without it. Their time is bounded by `--deadline` inside the job's own 5 minutes;
  a part that needs more is made faster or gets fewer bases, not longer (10 bases: the owner, 2026-11-11).
- The Mac's beta never holds back the others' (`put` runs whatever `desktop` and its build, `desktop-build`, came to): its signing waits on Apple's
  notary service, which can take a job's five minutes (2026-11-12, four runs in a row). Nor does Windows' (`desktop-win`): a new MoonBit's cold
  build was cut at its five minutes run after run and held every part's beta back (the user, 2026-11-17). Nor do the
  station's and Android's (`station`, `android`): each hands `put` only what it finished, and one cut at its upload held
  the signed Mac and Windows betas back (main 44147606865, 2026-11-17). A failed or cancelled part leaves its feed as
  it was; it is main's red, and `done` waits for it, so the next run plans it again.
- The Android delta's deflater is part of the format: JZlib's version (`libs/mbui/android/jzlib`) and the level and settings
  `Delta.java` deflates with must be what every installed app carries, or what it makes no longer is the release's APK
  (each delta is checked by the Java applier before it is published, so such a change only stops Android's deltas).
