# Working on the station (for agents)

## Its shape

- Processes: the launcher (`native/launcher`, Rust) keeps the pid, the data directory's lock and the ports, and on an
  update starts the next Node before letting the old one go; each agent process runs under a runner
  (`native/runner`), so a turn goes on while the station restarts or crashes and the next one takes it up
  (`src/agents/runner.ts`; `adopt` in `src/agents/process.ts`). The station's iroh endpoint is kept by the MoonBit
  front (`mb/src/front/mesh.mbt`), which the launcher starts and keeps across Node's handovers
  (`native/launcher/src/front.rs`), for each Node in turn (`src/mesh/front.ts`, its streams carried by the shell and
  none of their bytes by the program); where none runs (Windows, a checkout without the program) Node binds it itself
  with its addon (`native/mesh`), which keeps the image codecs and the rest as before. A device's requests of the
  routes in `src/mesh/served.ts` (the reads a device makes, `/batch`, `/changed`, its marks, names and a message in
  words and quotes) the front hands the MoonBit program that answers them itself (station/mb's reader `--serve`), not
  Node, which only tells it who each connection's member is and the floor a core is too old under there, takes what it wrote (`changes`, `said`: Node's store
  tells, the hub delivers) and keeps a message's idempotency slot and timestamp (`claim`); and `GET /events`, which
  Node's events make and give it a piece at a time, each told several streams given once (`relay`), and which it
  compresses and writes. The native
  parts are prebuilt by their sources (`scripts/native.ts`): even a comment changed in one makes every machine and
  CI build it again, so touch them only for what they do.
- What still.fail draws outside the app (the Helper's windows, `native/helper`) is in still.fail's design (the
  colours of `web/ui/src/palette.ts`, its corners, capsule buttons, the s. mark), never the system's default controls
  (the user, 2026-10-28).
- `src/main.ts` is the composition root: every part is a Layer made there and given what it needs
  (`src/services.ts`); nothing registers itself, there is no global state. Async work is Effect 4: fibers in their
  part's scope, `Schedule` for backoff, streams for what is pushed. Pure computation stays plain functions.
- The mesh's wire and door know nothing of still.fail's admission or routes (the user, 2026-11-14: another program is
  to be served by them with its own admission and handler): `src/mesh/wire.ts` is lines and requests on a stream,
  `src/mesh/door.ts` the control stream's hello and renewals, then a request a stream. Who is let in (credentials,
  locks, what closes a connection later) and what a request is answered are `src/mesh/serve.ts`'s, given to the door
  as its `Admit`. So with what is under them: `src/mesh/endpoint.ts` is the endpoint as the addon gives it and the
  addon's loading from where its caller says (where the station's is, `STILLFAIL_MESH_NATIVE`, and what else it
  offers are `src/mesh/native.ts`'s), `src/mesh/accept.ts` the taking of an endpoint's connections, each served by
  what it is given (`src/mesh/mesh.ts` gives the station's protocols) and closed the moment serving it ends, with
  code 0: so what serves a connection ends only once what it wrote has had its time to arrive and the close it means
  is made (the door keeps a refused hello's connection until it is closed: by its own close, the refusal's code and
  reason, `REFUSED_CLOSE_MS` after it was refused, where nothing closed it before). `scripts/mesh-base.ts` (a step of
  `scripts/check.sh`) refuses an import of anything else of the station's, a type's too, in them and in what they
  stand on, and still.fail's name in their code: what one of them needs is given it as a parameter.
- The main thread waits on nothing: every device's request and every agent's tool call waits behind it, and a call of
  microseconds took seconds on a station short of memory. No new synchronous call of node:fs, child_process or zlib
  there (fs/promises, execFile): `scripts/check.sh` refuses one a change adds unless its line says why with `sync:`
  (read before the station serves; one step that must not be split), outside a worker's file, the readers' (`src/read/`
  but for what the main thread runs of it), `src/cli.ts`, and the update's own process (`src/updates/command.ts` and
  the delta applier it runs, `src/updates/delta.ts`). Those from before this rule stand until they are moved; the
  line that says the main thread was held (`src/main.ts`) names, by caller, those that still take time.
  `test/main-thread-waits.test.ts` counts what a day's scenarios make it wait on; a change may lower the counts, never
  raise them.
- Time is the Clock's (a `TestClock` in tests): `Date.now`, `new Date()`, `setTimeout`, `setInterval` only in
  `src/ops/fibers.ts` (`wall`, for what is shared with other programs: mtimes, expiries, deadlines to processes).
  `scripts/check.sh` refuses them elsewhere.

## Its data

- Everything lasting is one SQLite file, `stillfail.db` (`src/store/store.ts`, schema in `src/store/schema.ts`): one
  write connection on the main thread; reads in reader threads (`src/read/pool.ts`: what is told as it changes and
  what devices ask each on a line of its own) or the MoonBit program (`mb/`) for the reads moved to it: every read a
  device asks (`src/read/pool.ts` MOVED, HISTORY), the station's reader thread answering only its checkpoint and a
  card's queued pages (`src/read/worker.ts`). A move to the program is compared with the reads as a reader thread
  answered them before (`test/reference-worker.ts`, given a test's Readers by `test/reference.ts`) on the same data. At a handover
  the next process opens it while the one serving writes: every connection waits its turn (a busy timeout), and a
  transaction that writes begins `BEGIN IMMEDIATE` (`scripts/check.sh` refuses what a change adds otherwise).
- A read answers by an index and a limit, never by going through all a station has (a station keeps months of chats):
  the `*-bounded.test.ts` tests count the rows a read fetches; a new read gets one. Old data a new index needs is
  built in the background (`src/read/*-builder.ts`), its batches taking one shared permit and yielding to writes
  (`src/store/backfill.ts`); until it is built, the read is bounded some other way, never a scan.
- A session can take part in thousands of threads (a chat that posts each release to Slack starts one each time):
  what its agent is told, its turns, its tools and the archive look at its recent ones (store `recentSessionThreads`,
  readers' `recentThreadRows`), never a loop over `sessionThreads`, which is for what must see every one (a share, an
  archive's changes). `test/many-threads-bounded.test.ts` holds it.
- A thread is a log: entries are appended, an edit is an entry of its own, nothing is deleted (a Slack delete is
  ignored); readers merge. The schema migrates forward only.
- What changes is told: the store's change, then `GET /events` (`src/api/events.ts`) to devices. A device never polls.
- Nothing in a workspace is hidden from its members: there is no permission system (the user, 2026-10-25). Every
  chat, a private one too, is open to every member and every agent of the workspace. The station is its server and
  the agents run as one system user, reading its database and every session's directory, so what is hidden from one
  person or one chat would not stay hidden without encryption. Do not propose or build visibility by person or by
  chat; a report of seeing another's private chat is answered that it is meant, and changing it is the owner's to
  decide. Only workspaces are kept apart from each other.
- What must survive of the chats is copied off the machine by an export off the main thread, as opaque batches, to two
  other stations of the workspace; a new station takes a lost one's back before its store
  opens (`src/replica/`, its AGENTS.md). It adds nothing to the main thread's writes: no trigger, no statement.
- What a station has moves to another of the workspace an item at a time while both work (a chat, an account, a job, a
  connect), each moved back the same way, a scheduler ordering them by their needs (`src/move/`, its AGENTS.md; the
  owner, 2026-11-14): a whole station is every item moved.

## Agents

- One actor per session: every change to its state, runtime events, deliveries and what its tools say, goes through its
  serial queue. Input is a prompt when idle, a steer during a turn, else queued. The actors run in the MoonBit program
  (`mb/src/reader/actors.mbt`, `actor_run.mbt`; reader `--sessions`, one program with the agents' output, `src/agents/mb-program.ts`), the hub holding a shell of each
  (`src/sessions/mb-actor.ts`) that answers what the program asks of the station (the store, the drivers, the chats,
  the words, all shared with `src/sessions/actor.ts`) and reads at once what it last told of each. What of the store
  it reads and writes most (its turns, running, its session's row) it does itself on the station's database
  (`mb/src/reader/actor_store.mbt`, store.ts's statements), telling Node's store what changed; a store in memory is
  asked through Node, so the hub's tests keep theirs in a file (`test/hub-fakes.ts`). The program is built for every
  system a station runs on, so there is no actor in TypeScript to fall back to. A test's `settle()` waits for the
  program too (`actorsBusy`).
- The background jobs (`src/jobs/jobs.ts`) run in that program too, as the pseudo-actor `#jobs` of the hub's (their
  own where no hub gives one: a rig's, a test's): a start's checks, the queue for other stations' tasks and the screen
  (`mb/src/admit`, its tests there), an end told and a service started again, a stop, a restart's taking up
  (`mb/src/reader/jobs.mbt`). Node keeps what is the machine's, which the program asks for: a command started in a
  group of its own and followed to its end, a signal, a log, the memory's pressure, the store.
- The remote tasks (station_task across stations) run there too, as the pseudo-actor `#remote`
  (`mb/src/reader/remote*.mbt`): what other stations ask of this one, the mirrors and their sweep, following tasks
  started from here. Node (`src/jobs/remote.ts`) keeps the mesh bus, the file bytes (written and read at the path the
  program names), the directory sync's sending side and the pieces it unpacks (`src/jobs/dirsync.ts`; a mirror's
  manifest, plan and its application are the program's, `mb/src/reader/dirsync.mbt`), protected folders and the load.
- Runtimes are drivers behind one seam (`src/agents/runtime.ts`): Claude Code a `claude -p` process per session;
  Codex one app-server per account, a thread per session, whose per-session settings go in `thread/start`'s config,
  never the process's environment; the others in `src/agents/`. A driver owns its child's stdin. Claude Code's output
  is read by the MoonBit program (`src/agents/mb-agents.ts`, `mb/src/reader/agents.mbt`, its frames `mb/src/claude`)
  where it is built, off the station's thread: Node starts and ends the processes and is told the events, each line
  acknowledged to its runner once Node took them; a handover holds its reading first (`freeze`, hub.ts `handOver`).
  A Codex app-server's output is read there too, its lines given Node whole but for its diffs (`turn/diff/updated`,
  of which the station keeps nothing). One program for every driver and the actors, running while one of them uses it.
  `test/claude-here.test.ts` and `test/codex-here.test.ts` run the drivers' tests with it read here, as where the
  program is not.
- Their tools are the station's MCP endpoint (`src/tools/`, HTTP on 127.0.0.1, a bearer token per session). What they
  read of how to work is `src/agents/instructions.ts` and the skills in `src/skills/`. A change to the instructions, a
  tool's parameters or its rules adds a note at the end of `src/agents/migrations.ts` (the next number, a sentence),
  told once to sessions that began before it.
- A runtime's way with its list of tools is its own, answered per session (`src/sessions/agents.ts` `LISTINGS`): Claude
  Code defers MCP tools, so only what every turn calls (chat_post, chat_state) is marked loaded (左子健, 2026-11-14).
- A tool's declaration is paid for in every session's context by the runtimes that load the list whole, and Codex
  gives its model no parameter description of a schema over 5,000 bytes (0.169.0, measured 2026-11-14): a description
  says what the tool does and when, the details are its skill's in `src/skills/`, which it names (the user,
  2026-11-14). `test/tools-weight.test.ts` holds the ceilings; raising one needs its reason said in the change.
- A subagent never speaks in a chat (the user, 2026-11-14: 「subagent 不应该能自己发消息」): the tools a session speaks
  by (`src/tools/mcp.ts` `SPEAKS`, and slack_api where its method writes) are its own agent's, which its instructions
  tell it. The endpoint cannot tell a subagent's call from its parent's (one token a session), so each driver keeps
  its runtime's subagents from them: Claude Code's by a PreToolUse hook (`src/agents/subagent-hook.mjs`; what that
  does not hold is said at `SILENT_SUBAGENTS` in `src/agents/claude.ts`); no other runtime's are held yet. A new tool
  is sorted in `test/speaks.test.ts`; the tools that only put a card before a person or report to the still.fail team
  are open to subagents until the owner decides.
- What the still.fail team replies on a bug report never reaches an agent by itself (the user, 2026-11-10: it would be
  outside words in someone's session): still.fail cloud gives the replies only to the chat's workspace's members' apps
  (`client/core-ts/src/feedback-replies.ts`), no station reads or holds them, and an agent sees one only as a person
  quotes it into what they send. An agent may answer with `feedback_reply` when the person asks it to.
- An agent's own answer is never forwarded: it posts with `chat_post` and ends each turn with a state (`all_done`,
  `need_human`, `waiting`); a turn ended without one is asked again, and so is one where a post with no state
  came after its `all_done` or `need_human` (it said it goes on: `goesOn`, 2026-11-15, a chat shown done that worked on
  for 78 minutes).

## The agents' memory

- A workspace's MEMORY.md and team skills are one for all its stations (the user, 2026-11-14: 「直接全局共享，跟 station
  相关的直接说明是哪个 station」): `src/share/memory.ts` keeps each file's recent versions and brings the stations level,
  merging two versions made apart from the one both came from (`src/share/memory-merge.ts`, as `git merge-file`, both
  kept where both changed). What is one machine's says which station it is of; the agents' instructions say so. No
  CRDT library (it grows, and every station would have to compact it together). With no version both came from (each
  station's memory of before) MEMORY.md's lines, and a file both kept on since it was copied, are put together each
  line once; skills of one name and nothing alike are kept apart as `<name>-<station>` (the user, 2026-11-14).
  Two versions of one history whose common version a station does not keep (and the other could not give) keep
  every line of both: a merge never drops what either had. `test/memory-sync-random.test.ts` holds it over random
  worlds (`MEMORY_RANDOM_SEEDS` for more; it fails on 0.1.9133's code), `test/memory-sync-upgrade.test.ts` that what
  0.1.9133 to 0.1.9168 left (a skill kept apart twice, a station's own file moved) is mended (`#mend`).
- Every session reads MEMORY.md and a project's skill whole, so neither may grow into a log: past `MEMORY_MOST`,
  `SKILL_MOST` or a line past `LINE_MOST` (`src/agents/instructions.ts` `overgrown`), the memory a session is told ends
  with which files to condense (2026-11-15: skills/stillfail/SKILL.md had reached 165 KB of status notes). What a merge
  kept twice is the agents' to tidy; the instructions say so.

## How a workspace's devices reach its stations (its ways)

- A workspace's own relays and the ways its devices do not take are its stations' (`src/mesh/ways.ts`; the root
  AGENTS.md, The cloud is the account system): one record a workspace, the newest kept, brought level between its
  stations, read by devices (`GET /ways`) and told changed (`ways`). An agent adds a relay with the `relays` tool and
  nobody approves it (the user, 2026-11-11: 「要手动加太不 ai native 了」): a relay carries only end-to-end encrypted
  packets and one that is slow is not taken, so an approval would guard nothing; the tool adds one only once this
  station reached it as a relay, and who added it is kept and shown.

## A station's name and icon

- A station's name and mark (an emoji, a glyph, a picture's address) are its own (`src/mesh/station-marks.ts`; the
  user, 2026-11-14: 「谁看都存在 station 上」, one for every workspace it is in, changed only while it is up): set on it by an
  owner or admin (`PUT /station-mark`), a copy of each kept by the other stations of its workspaces and brought level
  between them, read by devices (`GET /station-marks`) and told changed (`stationMarks`). One with no record yet is as
  still.fail cloud lists it; the device writes the cloud too while apps from before read only that list. A picture
  itself stays in the cloud's store of pictures, the record keeping its address. A station that only runs tasks keeps
  none (it asks and answers nothing new); its name stays the cloud's.

## Presets and starred models

- A person's presets and the models they starred are the same on all their devices and every station of the
  workspace (the user, 2026-11-14: 「预设和模型收藏会在整个 workspace 同步」), carried by that person's own devices: a
  device reads each station's (`GET /presets/kept`, `GET /stars`), keeps the newer of each record by the one rule
  both sides keep (`client/core-ts/src/preset-records.ts`: `rev` counts the changes, a deletion is a record), and
  brings a station what it lacks (`PUT /presets/kept`, `PUT /stars`). The stations never bring them level with each
  other, nothing of them goes to the cloud, and a station never rewrites a record a device brought (two stations given
  one keep the same bytes). A station changes a record itself only for an app from before (POST, PUT, DELETE
  /presets), which is listed only those made on it (`home`).
- It keeps so many deletions of each owner's (those of nobody said one owner of their own), by the rule a device keeps
  them by (`preset-records.ts` `goneKept`): a PUT whose deletion would be dropped as it is written changes nothing and
  tells nothing (`Presets.carry`), so nothing goes round. A deletion of nobody said is given in everyone's GET
  /presets/kept: its maker's device takes it as its own.
- Agents see every preset a station keeps, whoever's (chat_create `preset`); people see their own by default and
  others' after a press (`GET /presets/others`). That is a default filter, not a permission (Its data, above).

## A station's mode: whole, or only tasks (a rig)

- A station is whole, or it only runs tasks (只执行任务; `rig` in the code: `src/rig/`; the user, 2026-11-04 and
  2026-11-10): no agents, no chats kept in sight, no device served, only what the workspace's stations send it. One
  release and one list: it is added as either (`enroll --rig <the hash of its person's own lock>`) and changed in the
  app, never reinstalled. The app is not linked to one that only runs tasks: the stations say how it is (`src/rigs/`).
- A station is its owner's, the member who added it, whatever its mode, and only they change its mode, either way
  (the user, 2026-11-10): being a workspace's owner or admin is neither needed nor enough. Whole again only where
  they manage the workspace, as a member adds no whole station. One whose adder is no member (they left, or the
  operator enrolled it) the workspace's owner may make one that only runs tasks, and it is theirs then. The control
  plane holds this (`cloud/src/directory.ts` `setStationMode`): the machine does not know who added it.
- One that only runs tasks is its person's (its owner). A chat uses it only by a statement that person's own lock
  signed (`client/core-ts/src/rig-form.ts`: a grant with its timeout, idle or fixed, as a vault's secret; a grant
  taken back; 免批准, which opens it to every chat of the workspace), and the machine checks the signature itself against
  the lock it pinned: the cloud or a station that says otherwise lets no chat in. In security mode a station takes it
  only once that person signed for it (`src/rigs/adds.ts`), or the lock already lists it as a station. Where the
  workspace's chain moved the rig pins it by its enrollment's hash as before and waits for its state: meanwhile it
  answers a station what its person signed for it (`rig.added`, `rig.proof`; `src/mesh/peer.ts` `heardWaiting`), and a
  station that took it gives it the logs and bodies as it gives a station its list names (`Cloud.givenTo`,
  `src/mesh/person-sync.ts`), which it checks against the chain it pinned (2026-11-14, `test/rig-moved.test.ts`).
- What a machine is changes only when two agree, neither alone: what was asked of the machine over a way the control
  plane has no part in (whole to tasks: a member's device that reached it, `POST /mode`, with their lock to pin, kept
  as theirs; tasks to whole: its person's signature, `rig.full`), kept there for an hour, and the control plane
  listing it so, as that same person's (`src/cloud/presence.ts`). A whole station ends its agents, connects and jobs
  before it is one that only runs tasks (`src/sessions/agents.ts`); its chats stay in its database, out of sight until
  it is whole again. Whole again is its person's to say where they manage the workspace: an admin cannot open
  someone's machine to every chat.
- It asks nothing of a station: it only tells (`RIG_TELLS` and `task.changed`, `src/mesh/peer.ts`). What it serves is
  behind a grant unless `UNGATED` (`src/rig/module.ts`) lists it, which is for reading back and stopping what a chat
  already ran there; a new method is not added to it to make something work.

## A lock kept here

- **Pinning and replacement**: A lock this station pinned (home or joined workspace) is released or replaced only by the
  lock's own `disable` entry or a local CLI command on this machine (`stillfail lock reset [--workspace ID]`,
  `enroll --join --lock`), never by the control plane's frames or an unauthenticated mesh request. Each other way let
  in a device the lock never named, until 2026-11-12: a workspace left out of a frame and named again unlocked, or made
  the home one (`src/cloud/state.ts` `leftJoined`, `src/cloud/presence.ts` `took`), and an ask over the mesh, where who
  manages the station may be the plane's word (`src/cli.ts` `nameJoinedLock`).
- **Active chain and fork choice**: Every lock (home, joined workspace, or personal log) follows the rules' active chain
  (`src/cloud/log-keep.ts`, forks kept in `aside` up to `ASIDE_MOST`). It switches branches only for entries accepted by
  another keeper (another station of the lock, or a device with `keep`); fresh entries from a device or the control
  plane must extend the current head.
- **Moved workspaces (`moved {root}`)**:
  - When a workspace chain ends in `moved {root}`, `Cloud.locked` (`src/cloud/lock.ts` `state4Moved`, `roster4Moved`)
    computes the state in force from the moved chain, members' personal logs, and statement bodies (`src/cloud/lock-bodies.ts`),
    while `Cloud.chain` reads the raw chain. The control plane's `locked` never says whether such a workspace is on: a
    station that pinned the chain goes by the state in force (`leftOut`), and so does `enroll --join` (`src/cli.ts`
    `joinWorkspace`).
  - Statement bodies are accepted only when committed by a kept log entry (`bodyRefusal`) and served only within their
    workspace to stations/devices named by the state (`Cloud.givenTo`), or—for a removed device—only the removal chain
    that took it out (`toldOut`). A device reads logs and bodies by their heads (the lead, 2026-11-15; GET /lock/heads,
    POST /lock/given), each only where the whole reads give it; the whole reads stay for cores from before.
  - Devices not in the state receive no logs/bodies and get a `left` refusal (`leftOf`) listing only the app devices
    that can approve them (up to 16) plus `apps` (whether the person has any app device in the list). Before a chain
    moves, `GET /lock/logs` gives a device it lets in the logs it binds its members by (`Cloud.logsOf`), so the owner's
    device that hands it over drops no member's device.
  - A joined station without a prior pin never pins a moved chain from the control plane's word alone: it pins only once
    logs and bodies from a workspace station produce a state that names this station's key (`src/mesh/moved-pin.ts`).
    No wider than before a move (the lead, 2026-11-14): a station pinning no lock of a workspace is unprotected and lets
    in whoever the plane's credentials say, so its first pin is the plane's word either way (trust on first use); its
    home, enrolled by its token alone, pins only what its owner's device brings (POST /lock with the logs and bodies,
    `pinBrought`: their state must let that device in as an owner's and name this station); one enrolled with a lock's
    hash only a chain holding it.
  - After a move the root's person is a member like any other (rules/AGENTS.md `~root`; the lead, 2026-11-14): which of
    their logs is theirs is the state's to say (`src/mesh/serve.ts` `ownChainsOf`), and the root's log is never let go
    as a person's oldest (`CHAINS_A_PERSON`, `src/mesh/person-chains.ts`).
- **Device builds and version floors (`src/api/moved-from.ts`)**:
  - Each station records the latest build seen per device (`src/mesh/device-builds.ts`) and serves `builds`, `heads`,
    `carried`, `bind`, and `rootout` in `GET /lock`: what a core hands a workspace over by (the user, 2026-11-14: 无感迁移,
    no date, no switch, nobody told to update), nothing of a device the asker's lock does not name.
  - Clients below the applicable floor for a moved workspace (`MOVED_FROM_BUILD`, `LOGS_ANY_FROM_BUILD` when logs exceed
    `LOGS_BEFORE`, or `ROOT_OUT_FROM_BUILD` when the genesis person is removed from `~root`) receive `426` (`movedTooOld`
    / `movedFloor`) so their app prompts them to update.
- **What holds it**: `test/lock-moved-model.test.ts` (the state in force, to the model), `test/lock-left-out.test.ts` (a
  refusal's `left`), `test/lock-moved-joined.test.ts`, `test/lock-moved-pin.test.ts`, `test/device-builds.test.ts`,
  `test/lock-heads.test.ts`, `test/lock-root-out.test.ts`.

## Screens

- One person's view drives a screen at a time, any number look (pengxiao, 2026-11-12: 「控制独占，查看不限」):
  `src/screens/hub.ts` `drive` decides it as a view opens. Its person asking (控制, 接管: the view's `taken`) takes
  it, and every other person's view that drives it, their own on another device too, only looks from then on, told
  who took it; a view's own reopen (its link went, a resize) never takes it. An agent's view is not one of them: its
  input waits while a person drives (`src/tools/computer.ts`). Each side is told it in a notice (「独占这块应该需要有提示」).

## Terminals

- A member's terminal on the station (`src/terminals/`; the user, 2026-11-14) is a runner's (`--pty`, its id
  `term-…`, its meta in `<data>/run/terminals/`), taken up by the next station as an agent's is; what takes up agents'
  runners leaves those (`isTerminalRunner`). Every member but a read-only one opens one and types (one at a time, 接管
  as a screen's); a read-only member looks. A workspace sees only its own. A view is given the runner's screen first
  (libghostty-vt's, native/runner `screen`), then only the output past it. Not on a station that only runs tasks yet
  (it serves no device): that is a step of its own.

## Devices (设备)

- A device is what agents use that runs no station (the user, 2026-11-10): attached to a station (on its USB, in its
  network, a serial port: `src/devices/`, `connect.ts` reaches it) or a member's phone lent by its app (`src/adb/`).
  One list (`device_list`), one way to ask (`device_use`), each its person's. A chat gets a port of 127.0.0.1 on its
  own station that only its processes connect to (`src/adb/door.ts`'s gate), carried over the mesh to the device's station
  (`src/mesh/peer-http.ts`, a tunnel's `device`).
- On a whole station a device is every chat's, with no grant: the station is every chat's, so none would guard it. One
  that needs its owner's approval is attached to a station that only runs tasks, by that station's owner, as they sign
  it (`client/core-ts/src/rig-form.ts` `DeviceBody`), kept and checked by the rig itself (`src/rig/grants.ts`), granted alone or with the
  rig, or 免批准 on it.

## Sandboxes

- Heavy work goes to a sandbox as a target of station_task (`src/agents/sandbox.ts`; 左子健, 2026-11-13): config.json's
  `sandboxes`, each an l4es front door, listed by station_list beside the stations; the station takes each task as its
  own job and runs it in the chat's sandbox there through `src/agents/sandbox-bridge.mjs`. Nothing is installed in a
  sandbox and no agent runs in one: a station there would be there only for resources and access, which this needs
  neither of (「不应该让 sandbox 里装 station」). Not a device, no tool and nothing in the app adds one: the station's
  config says them (「直接写 station 配置就好吧」). Sessions running in sandboxes (the `sandbox` setting) went with it.

## Tests

- `pnpm exec tsgo --noEmit` types; one test file is `node ../scripts/native.ts run mesh runner archive-rs reader --
  node --import ./test/setup-env.mjs --test test/<file>.test.ts` (`pnpm test` is every file). Agents in tests are
  fakes on the test's clock; real processes, signals and sockets are the side run's (`side/`).
- CI runs `test/` on Linux, in slices (`scripts/check.sh`, station-tests): a test passes there as on a Mac, or
  skips itself saying what it lacks. A test with the vault on a database in a file gives it through
  `test/vault-no-reader.ts`, unless the use index's reader is what it tests: the reader is a process of its own, and
  writes when it will.
- A test waits for what the station set going with `settle()` (`test/hub-fakes.ts`): turns of the loop with no file
  request out, since the station reads off its main thread and how many turns the disk takes is the machine's. A count
  of turns of a test's own before it looks is that race again. What may never come (a line, a close) is taken with
  `given()` beside it: there by then, or the test fails saying so, not at the runner's limit.
- The lock's world tests (`test/lock-world-sim.ts`, run by `test/lock-world-1.test.ts` to `-3`) pass when exactly what
  `KNOWN_SEEDS` and `KNOWN_TOLD` say fails on the product (2026-11-12): anything else failing fails them, and a known
  failure that holds now must be taken out of the table, which only shrinks. The fork-choice models' runners
  (`test/lock-fork-choice.test.ts`, `test/lock-roster.test.ts`, `test/lock-roster4.test.ts`) print what they measure
  and assert only the models' soundness; their envs (`LOCK_FORK_*`, `LOCK_ROSTER_*`, `LOCK_ROSTER4_*`) give the full
  counts.
