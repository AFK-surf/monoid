# Client core sync, moved chats, and base isolation (for agents)

## Topic work, sync writes, and in-memory walks

- `client/core-ts/test/topic-work.test.ts` measures DB text bytes read for every query in `ASKED` (cold and re-asked) and every app interaction (start, workspace switch, chat open, bar place) to first screen and rest: at most 2x sent bytes or 8 KB, growing no faster than sent bytes at 3x workspace scale (`client/core-ts/test/real-size.ts` `Size`). `OVER_READ`, `OVER_READ_AGAIN`, and `GROWS` only fall.
- Every sync cause in `CAUSES` (alone and with all app topics held) reads at most 2x what it writes and sends, or 8 KB, growing no faster at 3x scale (`OVER_WRITE` and `GROWS_WRITE` only fall). Add every new sync cause to `CAUSES`.
- `client/core-ts/test/view-work.test.ts` (`work.ts` `walked`) counts tracked reads, recomputations, `share`/`equal` walks, keyed diffs, and output shaping per cause past reference-identical items (`same`). Work must not grow at 3x shown window size or 3x total chats (`OVER_SHOWN` and `OVER_CHATS` only shrink as sets).

## Sync row construction (`client/core-ts/test/rows-changed.test.ts`)

- Build station rows through the link memo (`client/core-ts/src/station/rows-made.ts` `RowsMemo`, returning frozen previous rows when inputs match by reference) and write against `#chatsHeld` (`client/core-ts/src/db/chats.ts`, holding row object and place, not JSON). One single-chat event builds and serializes 1-2 rows, reads no extra chat JSON, stays constant at 3x chats, and matches a cold rebuild.
- Every station (`OLDEST_STATION = 7143`) serves shared lists (`GET /chats?shared=1`), viewer-only marks (`GET /chats?marks=1&own=1`), and incremental shared deltas (`POST /changed/shared`). Keep updates keyed end to end: `#remake` targets specific rows (`rowShared` / `reprojectChatRow`, viewer marks in `OwnHeld`) and writes each row at its own `sharedPlace` (`#placeChatRow` when only place changes). Persist only the minimal sidecar (`shared_sidecar`: digest/said/named/quoted_only/local_admin, never raw rows/`mineOf`/`answeredBy`), per-station identity/lang/build metadata (`shared_meta`), and keyed viewer marks (`shared_mark`) committed in the same SQLite transaction as the affected `chat` row(s) so cold-start diffs re-project only changed rows by index. All `glanced` counters stay 0 on single-chat changes.
- `CAUSES` emit keyed list events (`client/core-ts/test/real-size-asked.ts` `listTold`). Whole-list writes happen only at initial fixture load (`UNTOLD` lists exceptions).
- Core rule 4 (`topics.ts` `start` / `#raise`): subscribing to a topic never opens an independent network channel; it only raises the priority of the existing station sync lane (`Priority.focused`). While a station is `catching` before `/threads` has tallied (`link.catching && !link.catching.tallied`), `prioritizeOpenedThread` schedules the opened thread's summary and bounded continuation pages on that same lane (deduplicated per catching epoch and thread) without altering the opening window or `unreadLine`.

## A chat on another station now

- A chat handed to another workspace station (`station/src/replica/handover.ts`) appears once at its current station and continues seamlessly (`client/core-ts/src/views/moved.ts`).
- Record moves by origin station and session (`account.ts` `putMoved`, table `moved`) and resolve via `Data.chatNow`. Never write a row from a station that moved the chat away (`#movedAway`) or a row whose target session names `from` (`#came`, `#summaryCame` handles either arrival order), so `chat` queries see one row per chat without filtering. The same session key on two stations with no move recorded remains two separate chats.
- Route calls, links, open page topics, and drafts through `chatNow` where read (`client/core-ts/src/core/routing.ts` `#movedTo`) instead of rewriting UI state. Never ask the old station for log catch-up (it returns 404). When notified a chat lives on a station (`409 moved`, move notice, or return), clear cached not-there state and re-read open topics (`client/core-ts/src/station/sync.ts` `chatHere`).

## The base stands apart

- The device mesh (`client/core-ts/src/mesh.ts`) and client runtime (host, runtime, errors, words, traces, wakes, scheduler, `client/core-ts/src/sse.ts`) form a program-agnostic base. Base files import only base files and packages (including types).
- `client/core-ts/scripts/base.ts` enforces closure on `BASE` (`STILL` stays empty) and blocks still.fail's name in base files outside `NAMED` (which only falls).
- Base strings live in `client/core-ts/src/lang.ts` (`lang.zh.json`, `lang.en.json`, `WORDS`, calling the peer "the server"). still.fail overrides them from `client/i18n/catalog/` through `client/core-ts/src/i18n.ts`, the sole non-base importer of `lang.ts`. Edit still.fail copy in `client/i18n/catalog/`, and base files only for generic phrasing.
- Pass still.fail specifics into the base rather than importing them:
  - Mesh behavior via `client/core-ts/src/station/mesh-wire.ts` (`MeshEnv`, `CredentialSource`, `STATION_MESH`). Without `STATION_MESH`, a mesh dials its own protocol/hello and exposes `Link.admitted`.
  - Host extensions via `client/core-ts/src/host.ts` (`Host`, `HEDGE`) over `client/core-ts/src/host-of.ts` (`BaseHost`, `WakingHost`, `HostOf`).
  - Trace/API naming via `client/core-ts/src/route.ts` and addon path via `client/core-ts/src/hosts/node-iroh.ts`.
- Any tracked JS/TS file loading `lang.ts` or a base file that loads it must statically import `client/core-ts/src/i18n.ts` (directly or transitively, as `client/core-ts/src/host.ts`, `client/core-ts/src/lock.ts`, and `client/core-ts/src/hosts/node-iroh.ts` do), except `client/core-ts/test/base-words.test.ts` (`ALONE`). Do not call base words at top level inside an import cycle before `i18n.ts` executes, and do not bypass detection with non-literal dynamic imports or untracked files.
