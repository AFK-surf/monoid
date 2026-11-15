# The copies of a station's conversations (for agents)

Losing one machine does not lose a workspace's conversations (the user, 2026-11-09). What must survive of a station's
chats (their threads, entries and letters, their sessions, turns and each viewer's marks, and the files attached to
them) is copied, a workspace at a time, to the stations that keep it, and a new
station takes it back in place of a lost one. Transcripts, usage, accounts and working directories are the machine's
own and are not copied: a chat taken back goes on afresh, as one moved to another account does (a station retired,
below, sends them along).

- One export, off the main thread: the MoonBit program's (`station/mb/src/replica`, started by `runner.ts`
  `exportThread`); a restore the same (`restore.ts` `takeBackSoon`). There is no export or restore in TypeScript to
  fall back to: the program writes and reads what the TypeScript of before does, line for line, so either takes up the
  other's state and copies. That TypeScript is the tests' only (`station/test/reference/replica-export.ts`,
  `replica-restore.ts` `takeBack`, `replica-format.ts`; `station/test/mb-replica.test.ts` holds them to each other; the
  tests' own stations run it, `replica-work.ts` `InlineRunner`): `src/replica/` keeps only what the station itself
  says and reads of a copy (`export.ts` what the export is told, `format.ts` a head and the names). It reads
  stillfail.db only: immutable batches (`format.ts`), a generation of them per workspace, `head.json` written last.
  What changed is found by what the tables already give (the rowid of what is only added to, an index, the store's
  own changes told to it, a digest of what was written in its own `export.db`), never by a trigger or a statement on
  the main thread's write path (`replica-export-bounded.test.ts` counts them).
- The stations that keep them keep the batches and files as opaque files (`places.ts`): two other stations of the same
  workspace (the two whose rendezvous hash with it is highest, `peers.ts keepers`, worked out in each station from its
  roster). Nothing about it is set by anyone, and the app shows it as one row (the user, 2026-11-10: 「按最简单的交互方式
  做」; a folder of one's own was taken out). There is no follower database and no merging: only a
  restorer reads inside a batch (`restore.ts`), into a station with no chats of its own (or one a station was retired
  into, below), before its store opens.
- A pass and the exporter's state (`export.db`) are one transaction, committed after the head that names its batches.
  A batch holds at most BATCH_BYTES; folds and restores go through SQLite on disk and stream files, so their heap
  does not grow with the copy (`replica-heap-bounded.test.ts` runs them in a 24 MB worker heap).
- What a place holds is kept (`places.ts Known`) and only the new batch and head are sent; its listing is asked only
  as the station starts, on hello, after a failure and on handover. While a keeper is not reached the next station in
  the rendezvous order holds the copy meanwhile (`replica-stations.test.ts` counts the requests).
- A restore's three steps (rows, files, `formerly`) are each safe to run again; its outcome stays (`restore.ts outcomeFile`)
  for the settings after the restart. What it brought is let go only once its files are placed (or its rows never went
  in): rows in and files not, the next start places them. It folds the batches on disk first and puts each row that is left
  in once, so the store's triggers see each final row once: restored from the batches as written or from the
  generation folded whole, every table of the database is the same (`replica-export.test.ts`). It is refused early, and again before the restart, on a station that has a chat
  of its own, but for a retired station's.
- A workspace's batches hold only its own chats; a station that leaves a workspace deletes what it kept of it. A
  copy no longer a station's to keep goes only once those that should keep it say they hold as much.
- A station rolled back (a backup put back) finds a place holding more than it has (`places.ts behind`): it begins a
  new generation and the place keeps both; nothing is merged or dropped.
- A station retired from a workspace (`retire.ts`; the user, 2026-11-13: 「搬家主要考虑的场景是要废弃掉一个 station」,
  「要允许用户选择目标迁移 station」) hands all its chats there to the station a person picked, which may have chats of
  its own: what is hard to move is left to what already makes it, never rewritten by hand (「避免脚本乱改改错」). The app
  shows first what it would move (`GET /retire/preview`, found by the same functions the retirement uses). Each
  session's room whole (an archived one's packed workspace with it; `footprint.ts roomOf`, a session whose directory is
  not the station's own counted and left) and its agents' transcripts go by their bytes to the same places under the
  other's data directory, only under `sessions/` and `transcripts*/` (`carry.ts`: the MoonBit program's, `--builder
  replica-carry`, `station/mb/src/replica/carry.mbt`, a process each, a cancel killing it; built for every system a
  station runs on, so no worker thread to fall back to; the worker's from before is `station/test/carry-reference.ts`,
  which `station/test/mb-replica-carry.test.ts` holds it to): a checkout's files as git
  lists them (`rebuildable` stays behind, decided from the listings the walk reads: by its name anywhere, one known by
  what is in it only outside a checkout and within 3 levels of the room's top, as git ignores it inside one; carry.mbt
  `rebuilt_by_name`, `rebuilt_of_any_name`, held to footprint.ts's by `station/test/mb-replica-carry.test.ts` on the same
  trees), its own `.git` as files, a repository in it gone into; a linked worktree is
  made again there by git (its remote fetched and pruned first, a bundle of the commits no remote has, `git worktree add`
  and `repair`; one that cannot be keeps its bundle beside it; not begun where that station has no git). A station has
  a million files: nothing of them is one object on a main thread or in one message (a list a session on disk, an
  index of the lists, `retire.lacking` a bounded batch of hashes at a time; `replica-retire.test.ts` counts them). Every
  file is checked by its hash as it is written there, and put in place linked to what was sent, no byte copied
  (`carry.mbt` `put_file`; one linked already, the same bytes at another path, is copied: two paths never share a
  file; 2026-11-14, Node's clone copied the bytes on APFS and filled a station's disk). The
  copy is put in beside the other's chats by the same restore (its `merge`, the reference's `build`: each thread an
  id there, a platform's thread both followed the one there with its own log, a still.fail chat of the same ts given
  the next free one, the connects' ids and the sessions' `ws` as there), after which that station is this one too
  (`formerly`), each moved chat's agent told once (`moved_notes`); what it tells the retired station goes to that one
  itself (mesh/bus.ts `askItself`, as a request naming it would come back to itself). The chats stop (sessions/hub.ts
  `quiet`, every chat of the workspace, the home one's too, and their jobs; for good once done, across restarts) only
  for what changed since the first sending; what their platforms say meanwhile is kept and goes there as each
  connect moved there (connects/workspace.ts `moveAll`; a Comma connect's, which no station routes to another, is refused unkept, as
  `Retiring`). Retired from its home workspace, its accounts move there before the connects (share/index.ts
  `moveProfile`; one that cannot is said, `accountsLeft`); the connects move last, the chats then out of sight here
  (`retiredWs`); the app then takes the station out. Each side says what it does and where it stands (`retire.begin`,
  `.take`, `.took`, `.failed`, `.accounts`, `.drop`), no polling; a copy the other could not put in, or whose restore never said how
  it went after two starts, is tried again only as a person asks; a cancel answers at once, is refused once the other
  took the chats, and one made while the other is not reached before it was asked to take them is told it once it is
  up. Build output, and the browser's sign-ins stay behind. The jobs the chats had running are started again on the
  other once it took them, each once, as after a restart (`#startJobs`; one whose directory was not the station's own
  is not), their agents told at once; the agent home's own files (memory, presets, people's skills) go along and are
  merged there, nothing of the other's overwritten (`agent-carry.ts`).
- A hand-over that fails after the chats stopped (the other could not put them in: its placing or its worktrees
  failed, a file sent is not there, its disk under `HEADROOM` free as it is asked, or its restore; or it was not
  reached for a minute after they stopped, `QUIET_UNREACHED_MS`, before it was asked to take them) puts them back to
  work by itself and rests at `sent`
  (the lead, 2026-11-14): the other keeps what it was sent and puts in nothing by itself (`retire.drop` `keep`), so
  the next hand-over sends only what changed. Never once the other said it took them, nor once it was asked to (it may
  be taking them: as a cancel, they wait for it). Neither station updates itself meanwhile (updates/holds.ts, retire.ts `#holdsNow`; 2026-11-14, a beta's update cut
  a real one's sending three times): the retired one while it sends, its chats stop and are handed over, until they
  were taken, it fell back or was called off, the one taking them from the take until it took them or could not, held
  again as either starts; never while resting (at `sent`, failed, the other's disk full or from before), nor while the
  other is not reached. A process that stops ends the run under way at once, as a cancel does (`close`).
- On the station that took them, the moved chats follow the retired station's accounts to the ids they have there
  (`retire.accounts`, told once the accounts moved: a shared one under the copy it borrowed, one whose id is another's
  there under the next free one; the keys of the chats taken kept, `tookDir`): their next turn takes up its
  runtime session, nothing said in the chat. What it tells them that wakes them (their jobs' words, the driver's) waits
  for that, or `ACCOUNTS_WAIT_MS`; the jobs start at once. The retired station's accounts moving away touch none of the
  chats it handed over (sessions/hub.ts `handedOver`), and each connect is on the other before what was kept of it goes
  there. Neither side asks the other of a share once one is the other too (mesh/bus.ts `cameHere`).
- An agent assists (`station_retire`, `retire-asks.ts`; the user, 2026-11-14: 「人应该只需要在关键节点点卡片来确认就行」):
  a person confirms its start and its hand-over, each a card counted only as chosen in the app by an owner or admin of
  the workspace (parts.ts `cardChoice`, checked by the route that closes it, never by the agent); it waits at `sent`
  for the second. The asking session is told each step (`#toDriver`), on the station the chats went to once its own
  moved. The panel in the app goes on from `sent` by itself, as before.
- Starting a retirement is switched off (左子健, 2026-11-14, after its first real use: 「我怀疑这个功能根本不能给用户用」):
  POST /retire and station_retire's start and hand_over are refused (module.ts `RETIRE_STARTS`), the rest as above; it is
  switched on again once the fixes have passed a drill.
- One chat is handed to another station while both are up (`handover.ts`; 左子健, 2026-11-14, superseding the
  decision of 2026-11-09 that left this out: a whole-station move is every chat handed over, then its connects and
  logins by their own moves, and the reverse hand-over is the way back). It is the `chats` module of a migration
  (`station/src/move/`, its AGENTS.md: independent modules, each item moved and moved back on its own, a scheduler that
  only orders them by their needs). Its state is a file a hand-over on each side (`handover/out/`, `handover/in/`):
  nothing of it is in the copies' export or the schema but `handed_over` (where each chat went, store `handOff`). The
  chat is held alone (sessions/hub.ts `holdChat`), its files gathered alone (carry.ts `gatherSoon`'s `keys`) and sent
  as a retirement's are (`sending.ts`), its rows sent a page at a time and put in through the other's store, hidden
  until shown (store/handover.ts, `comingWs`): each thread's log goes on past what that station has (n kept where it
  was this chat's own as it was left, else by ts), so a chat handed back appends what was said there. Each station's
  log keeps the numbers it has: an arriving entry the same at its number is skipped, one found by ts elsewhere is that
  one, one not found is numbered on, and nothing already there is renumbered; so where a copy there had entries of its
  own (the leftover of a retirement taken back, 2026-11-14) each station has every entry once and the two orders differ
  only in where those sit. Renumbering would rewrite a hidden copy's rows and all that hangs on their numbers for a
  divergence of one station (the owner's 「避免脚本乱改改错」). A chat of a key live where it would go (in sight there:
  one that went on there apart from it) is never merged into: the plan says it cannot move (`move.chats.live`) and
  `handover.begin` refuses it before anything is written. What it had yet to be handed goes with it and is marked
  handed here once it is shown there (store `deliveredThere`), so none of it is handed to its agent again as it comes back. Only once the
  other counted what it has does this one say it went; before, a failure undoes it there and the chat goes on here
  (`handover.drop`: after the placing under way, what it placed and the directories made for it, a linked worktree
  git made with its registration, branch and ref, the repository staying; what it put aside back; a newer hand-over
  of the chat drops an older one still coming first, so the older's drop, late, takes nothing of it; asked even of a
  station the turn found gone, owed until answered). The station it goes to drops it by itself where its own disk fails
  what it is sent (full, over quota, read-only: refused in numbers, never a stream reset: mesh/peer.ts `Incoming.held`),
  and where one still coming as it starts, or as its sender is heard from, no longer goes on there (`handover.still`);
  after, nothing is undone and the rest is told until it is answered. Its platform threads are re-pointed where their
  connect runs (connects/workspace.ts `route`, `connect.route`); what still comes here of it goes on there
  (`movedTo`). A device naming it here is answered where it went (409 with `moved`, `GET /moved`, `chat-moved`),
  only once that station showed it (store `goneTo`, then `shownThere`: told at `gone`, a device read it there before it
  was there to be read and kept 「对话不存在」, the drill of 2026-11-14): until then it is read here as it went, held,
  and what is taken here meanwhile goes after it (`caught`).
  Nothing is posted in it; its agent is told once (`moved_notes`).
- Not here, by the owner's decision (2026-11-09): reading a chat from a copy while its station is away, signed heads, a
  lock entry for a replacement.
