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
- Every job says `timeout-minutes`, 5 at most, except the limits listed in `scripts/ci-timeouts.py`'s `LONGER`.
  Those allow 10 minutes, except `prebuild.yml`'s `build` job, which allows 15. Cold Windows shell builds take around
  540 seconds and can exceed 10 minutes with setup and packaging. Other jobs that need longer are made faster,
  never finished over several pushes or reruns: a branch's
  mbui-check run cut before its programs were all built keeps none of the units it compiled (test.sh's
  `MBUI_BUILT_MARK`), and main's store keeps what its runs used for three hours. Minutes are whole (the runner cut a
  step's 3.8 at 3): a step that
  must end some seconds before its job, for the caches saved after it, runs under `scripts/with-timeout.sh`
  `@$((JOB_END - 35))` (by what follows it: mbui-check's 25, its app build's 35 on a branch and 25 on main, its replay build's 65 on main and 45 on a branch), JOB_END written by the
  job's first step, less its 5 s of setting up (preview's ios 8). The units' stores of GitHub's Linux images are keyed by
  their compiler (`IMG`, `cc` and 12 hex digits of clang, its `--version` and the C standard headers it preprocesses,
  not `linux-libc-dev`'s version, which moves weekly with the kernel), its Mac's
  by its `ImageVersion`: two compilers in turn kept only the last run's units in one, and four `ubuntu-24.04` images
  of one clang and libc, each its own store, left a push's image's units hours behind main's.
- Use GitHub's standard `ubuntu-24.04` runners for Linux CI; do not use paid runners. The pipeline plans only
  missing native parts. `natives-build` builds each non-Apple target on its own VM, with its own checkout and Cargo
  target. Main publishes the archives by source key. A branch stages them in company R2 and uploads one receipt
  artifact per target for the rest of that run. `natives` combines the status for the pipeline and Windows preview.
  `natives-win-reader` and `natives-harness` take their static shell from that run when it changed.
  The Linux reader jobs use 8 MB C units with one `moonbit_init` unit, and keep compiled units in the Actions cache.
  Branch readers and the tests' harness use -O0, and main's shipped readers retain optimization. Each Rust check
  shard uses its own GitHub runner and Cargo target. `plan.sh` selects Rust checks when their inputs changed.
- Keep the Apple native jobs and Xcode or simulator tasks on their existing Mac pools. A branch's `check-mac`
  runs on GitHub's `macos-26` (main's too with `vars.MINI1 = 'off'`). A branch plans `natives-mac` only when a
  job uses those parts, and `natives-mac-reader` only for `check-mac` and `mac-build`. Android release builds
  and `station-update` use Mini1; Mac app and station release signing use GitHub's `macos-26`.
- A job that needs another job's output says that job's result in its `if:` (`contains(fromJSON('["success","skipped"]'),
  needs.natives.result)`): one cut at its `timeout-minutes` is `cancelled`, not `failure`, and the run is not
  cancelled, so `!cancelled() && !failure()` alone ran nine jobs without the readers (main 44466921858).
- A check that failed and passed on the same commit is never rerun green (the root AGENTS.md): a branch's `gate`, in a
  run attempted again, fails unless every job that failed or was cancelled before failed for GitHub's or the network's
  sake (`scripts/gate-rerun-check.mjs`). The gate also allows a job stopped only by `native.ts`'s exact missing-prebuild
  diagnostic, with no other failure: its build or test never started. Supplying the artifact lets that work start.
  Do not rerun an old commit's main pipeline: it deploys that commit's beta over
  the newer one.
- An artifact uploaded for people to look at (pictures, logs, what moved) says `continue-on-error: true`: a runner's
  connection to GitHub's artifact service reset fails a check that had passed (main acb00686, 2026-11-01; #5157's
  `offscreen`, 2026-11-10). One a later job downloads does not: there the upload's failure is the job's, unless that
  job is skipped without it (monoid's betas, `monoid-upload`'s outcome in the job's outputs) or does without it (mbui-size's measures and what they measure: `record` carries the one before's for a measure
  missing). mbui-size downloads what it measures by `scripts/download-artifact.sh --optional`, not
  actions/download-artifact, which once ended 0 with half a zip on the disk (43955196994, 2026-11-16): a zip is
  checked by its size and digest, a cut one taken on by Range, and the directory is there only when it came whole.
- A release's deltas (`scripts/release-deltas.ts`: the `deltas-<part>` jobs, each waiting for its own part's build
  alone, `put_feed` in `scripts/release.sh`) never fail or hold back a release: what goes wrong is a warning and that
  delta is left out, the feed whole without it. Their time is bounded by `--deadline` inside the job's own 5 minutes;
  a part that needs more is made faster, split (the station's, a job a platform: `--platform`, put's `--merge`) or gets
  fewer bases, not longer (10 bases: the owner, 2026-11-11). All `deltas-*` jobs (`deltas-android`, its `javac`
  `ubuntu-24.04`'s JDK, `deltas-desktop`, `deltas-desktop-win`, and the station's four platforms) run on `ubuntu-24.04`:
  fast R2 transfers keep them around 53–77 s, whereas running `deltas-station` on `ci-1` stalled 200–304 s downloading
  staged archives over Shanghai international egress.
- Stable (`workflows/stable.yml`) runs from main's head against the release's older checkout: a step that needs newer
  scripts takes them from `$GITHUB_SHA` (`git show`, a sparse checkout). Its station is built into a directory and
  staged; only `station-put` puts it, packages then `station.json` seconds apart, so a run cut before leaves the channel
  as it was. Its native parts come from `station-natives-*`, which build only what neither the release
  `native-artifacts` (20 of a part, hours of main's) nor the store (`natives/`: main's `natives-store`, after its natives
  jobs; readers kept 14 days, `scripts/release-prune.ts`) has.
- `desktop-build` waits for `natives-mac` alone (it uses only the Apple parts, not the Mac's reader, which
  `natives-mac-reader` builds beside it) and `desktop` for `desktop-build` alone, never for `natives`' slower Linux build
  nor the reader's. The release's upload jobs (`deltas-*`, `desktop`, `put`, `changelog`) take Node
  alone (`.github/actions/node`), no pnpm: `release-put.sh` and `changelog-put.sh` go through Cloudflare's API with the
  token (wrangler only without it). `release-prune` deletes old files after `put` in a job of its own, which neither
  `done` nor `station-update` waits for.
- The Mac's beta never holds back the others' (`put` runs whatever `desktop` and its build, `desktop-build`, came to): its signing waits on Apple's
  notary service, which can take a job's five minutes (2026-11-12, four runs in a row). Nor does Windows' (`desktop-win`): a new MoonBit's cold
  build was cut at its five minutes run after run and held every part's beta back (the user, 2026-11-17). Nor do the
  station's and Android's (`station`, `android`): each hands `put` only what it finished, and one cut at its upload held
  the signed Mac and Windows betas back (main 44147606865, 2026-11-17). A failed or cancelled part leaves its feed as
  it was; it is main's red, and `done` waits for it, so the next run plans it again.
- The Android delta's deflater is part of the format: JZlib's version (`libs/ui/android/jzlib`) and the level and settings
  `Delta.java` deflates with must be what every installed app carries, or what it makes no longer is the release's APK
  (each delta is checked by the Java applier before it is published, so such a change only stops Android's deltas).
- Keep `fetch-depth: 0` and a complete checkout on persistent `macos-ci` workspaces. A shallow job leaves
  `.git/shallow` and sends the next full-depth job through an expensive unshallow. Dedicated shallow pools
  (`quick` and `mbui-render`) use shallow checkouts. Quote `'0'` in GitHub Actions expressions because numeric
  `0` is falsy in `&&` and `||`.
