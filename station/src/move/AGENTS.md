# Moving to another station (for agents)

A migration between two stations of a workspace is a set of independent modules and a scheduler that only orders them
(左子健, 2026-11-14: 「每个模块独立迁移，有依赖的模块显式给出依赖，要求先迁依赖项，模块内部带进度迁移，可回滚」). Both stations
keep working throughout; a whole station is every item moved, its connects and logins last by their needs; moving back
is the way back. It replaces the whole-station switch of `station/src/replica/retire.ts` (its first real use, 2026-11-14:
chats paused 18 minutes, a half-moved state, no way back), whose start stays switched off.

- One seam (`module.ts`): a module plans its items (each naming what it needs, only of the modules it declares; why it
  cannot move, in words that say what to do), moves one, moves one back, says where each stands. Each item's state is
  its module's, durable, so either side started again goes on or undoes. The scheduler (`scheduler.ts`) never does a
  module's work: it orders by the items' needs (one whose need is not there is refused naming it; `withNeeds` moves
  those first, but not one whose leaving would stop other items here: both refused, naming what it would stop; a need
  usable there though it is not, `usableThere`, is neither waited for nor taken along), moves back in the reverse order
  (refused while something there needs it, naming that), and tells what
  changed. No polling.
- When an item moves away, every item here that needs it and cannot have it here any more is stopped first (a state of
  its own, `stopped.log`, held again as the station starts), never left to fail (左子健, 2026-11-14: 「依赖项被迁走就停掉啊」):
  "needs" is "usable on this station" (an account moved away that this station borrows stops nothing, `usableHere`). A
  stopped chat is held as one being handed over is: no turn, its jobs stopped and kept, what is said to it kept in its
  logs and delivered once where it ends up; nothing posted, its agent not woken. It goes on as what it waits for comes
  back, or as it moves itself. The plan says what a move would stop (`wouldStop`), by the turn's own predicate
  (scheduler `#stoppable`: only an item whose module has `stop`; a routed connect goes on, its threads routed).
- An item may go, either way, to where something it needs is not usable: it arrives there stopped, waiting for that,
  and goes on as it arrives (the owner's rule both ways, 2026-11-14). The stopped set is each station's own: the one an
  item arrives at keeps it (a hand-over's `stoppedFor`, scheduler `noteStopped`), and is told as what it waits for
  comes (`move.arrived`). Forward goes needs-first unless asked `arriveStopped`; back, what needs an item there comes
  first, arriving stopped, then the item. Modules may need each other (chats and connects do); items may not: a chain
  of items needing each other round is refused, named.
- The modules: `accounts` (needs none: a login, by the share, key or own profile it is known by across the workspace
  now; this machine's own never. A chat needs the login it runs on now; this machine's own logins it only ran on before
  or lists are no need of it (handover.ts `pastLeft`; the owner, 2026-11-16: 「只是以前用过、又迁不走的登录不再卡住聊天」):
  it goes on the login it runs on, its plan item saying what it leaves (`leaves`), and there it is as one whose account
  is missing for those (told `nowhere` at `handover.begin`: not offered them, their runtime sessions not taken up);
  what was theirs stays here, found again as it comes back. A past login that can go stays a need. One that can be shared (`shareRefusal`), taken only because what moves needs it, is
  lent, not moved (the owner, 2026-11-15: its host never leaves, so nothing of it is stranded on a station that dies or
  leaves the workspace): shared with the station it goes to (with the two alone where it was not shared; that one added
  where it is shared with others), told to it directly and answered once its copy is there (share/index.ts `lendTo`,
  `share.borrow`), before what needs it goes; kept as lent for those items (`accounts-lent.log`), and for every item a
  later turn takes there that needs it (scheduler `lentFor`), and taken back by this station alone when the last of them
  is here again (a move back, a failure, an arrival by any route) and the other says nothing there runs on it
  (`move.uses`: a chat it began on it too, as a connect moved there begins them; the drill, 2026-11-15, took it back
  from under five), asked again at each turn's end while it does or does not answer (one lent in the turn under way for
  what did not go is taken back unanswered); the other told then or once it is heard from. The station it is lent to tells it, once and kept until told, as its last chat on it
  ends there (handed away, archived, moved to another login, deleted: `move.unused`), and a chat arriving from there
  has it looked at again (`lookAt`); either takes it back where nothing of this station's it was lent for is there.
  A start mends what a station from before kept: the chats handed to where it is lent that run on it are added; the plan and the page say it is here and usable there (`lentTo`), a turn what it lent
  (`lent`). Asked for by name, or in a whole move, its host moves (share/index.ts `moveProfile`), after what needs it:
  one not shared, shared as it moves with the two stations alone, that share undone as it comes home by any route
  unless a person opened it to another station meanwhile (`accounts-shared.json`). One that cannot be shared
  (SuperGrok, Cursor, Devin, a Kimi sign-in) moves as it is, gone from here, what needs it stopped first.
  What each was known by is kept as it moves away (`accounts-known.json`); one that is no profile here and the other
  does not have either is no item and no need of anything: its chats go as chats whose account is missing. There once
  the other hosts it: one it only borrows is here, this station's still, and usable there, `usableThere`; one this
  station only borrows from a third station is neither's (the real run, 2026-11-16: a whole move failed on two logins
  a third station hosts): no item where the other borrows it too, what needs it going as it is; one the other lacks
  cannot go, said so, what needs it refused or arriving stopped there, going on as the third shares it there too (the
  logins changed, move/station.ts `loginsChanged`)), `chats` (needs accounts, connects, repos, vault: one chat by
  `station/src/replica/handover.ts`, its files a mirror by difference: the station it goes to says what it has in
  place, what differs is sent, what the lists no longer name is removed there, in its room alone), `jobs` (needs
  chats: started there once its chat is there; one chat moved by the tool or the app moves its jobs right after, and
  moved back takes them back first, so a job never runs on two stations; a job back while its chat is there is kept
  here stopped, and starts as its chat comes), `connects` (needs chats: a Slack or Feishu connect once the chats that came through it are
  there; a Comma or single-session connect's chats need it instead, so it goes first, stopping them here, and each goes
  on there as it moves: the connect arrives knowing which of its chats are still to come (`connect.take`'s
  `awaiting`) and keeps what its platform says, in order, until they are all there, never a new session for one on its
  way, connects/workspace.ts `arrived`; from the moment the other is asked to take it, what this station's socket still
  gives waits for the answer and goes to the holder, handled only there (`handing`: the two sockets overlap a few ms,
  and Slack gives an event to any one of an app's sockets); its move is kept on disk until either side's answer is
  heard (`connects-moving` in the data directory's `replica`), so a station stopped between, or one that heard no answer, asks the other whether
  it holds it as it starts and as it is heard from (`settleMoving`, `connect.holds`): one of them holds it, never both), `repos` (a canonical clone a chat's linked worktree hangs on, by its remote: cloned there, what
  no remote has fetched from a bundle; back, removed there only where this move made it; the chat's move only adds
  its worktree, `rebuildGits` `clone: false`), `vault` (an owner's plain items and the vaults they own, rows sent as
  they are; back, the other lets go of what this move put there) and `settings` (config.json's settings that are a person's choice,
  settings.ts `SETTINGS`: what the other has already is never overwritten, the owner's 「不好搬但有其它办法规避的部分直接规避，
  避免脚本乱改改错」: one it lacks it takes, a map the keys it lacks, another value of its own it keeps and the item
  cannot move; back takes out exactly what was added). These three copy, so what moved is still usable here
  (`usableHere`): moving one stops nothing. What each moved is kept across a start (`kept.ts`). Grants do not move: a vault's is sealed to this station's
  keeper and kept in its memory, a plain one is taken up as a station starts; the owner approves again there.
- The agents' memory and team skills, and people's presets and starred models, are no module: they are the same on
  every station of a workspace already (station/AGENTS.md, The agents' memory; Presets and starred models), so nothing
  of them moves (the lead, 2026-11-14: what need not be moved is not). What memory.ts keeps on its machine (a skill past
  its size, a file only its owner reads) stays there, as it does for every station.
- What the app shows is `GET /move?to=` (routes.ts: the modules in order with their needs, done of total, how many cannot move (`cannot`), a page of
  items each, and `last`, the workspace's last turn and what came of it, kept in `last.json`), told changed as `move`
  on the event stream (a burst told once in 500 ms, live.ts). A turn under way reads as moving until its end is told
  (the item it is at, scheduler `current`). While a turn toward the station the page is read for runs, the page is
  answered from the turn's own plan (scheduler `held`: each module's items in order, each one's place, counts kept as
  items end), only the page's rows asked where they stand now: a read during a turn reads no page of the station's chats
  and asks nothing of the other (station/AGENTS.md: a read answers by an index and a limit); station_move plan and status
  take the same plan, every item asked where it stands, and answer a summary of it, a module's items a page at a time or
  one item (tools/move.ts `summaryOf`, `pageOf`): never every item, as an answer is one line of mesh/peer.ts
  `MAX_MESSAGE` and a station has thousands of chats. At rest, and from the read the turn's end prompts, planned anew.
- A plan never guesses what the other station has: a question of it not answered (`move.accounts`,
  `move.chats.live`, `move.repo.have`, `move.setting.values`) makes what it asks of unable to go this turn, said so
  (ask again), logged with what it failed with; with no station named it asks nothing. What needs an item that cannot go
  is refused in that item's own words, nothing of it tried. In a turn, a station found gone (its connection gone and
  dialed anew in vain, or no answer in time) is asked nothing more till the turn ends: every later step fails at once,
  in the station's words. A request whose connection the other station's own process closed as it stopped or handed
  over to its next (mesh/peer.ts `PeerStopped`, by the close's reason `STOPPING`) is no sign of that: each such request
  is asked again once on a connection dialed anew, whatever the turn asked before (drill 7h: an ask in a hand-over's
  window was told the station could not be reached). Whether the process that stopped took it is not known, so every
  move request's handler takes a repeat as the same (by its ids, versions, what is there already; a page of rows by its
  `page`); chat-handover-moves.test.ts meets every request of a turn so, half taken with their answers lost. What a move says to people is the catalog's (`station.move.*`), naming things as people
  call them, never by id.
- No request of a move waits on work that grows with a chat or a repository (the real run, 2026-11-16: a chat of 70k
  files placed in 50 s, past an answer's 30 s, mesh/peer.ts ANSWER_MS, and could never move): such work is a told step
  (`told.ts`): a hand-over's placing and pruning, a chat's hand-over back (`move.back`), a bundle's fetch and a clone's
  removal (`move.repo.bundle`, `move.repo.drop`), station_move's move or move back asked of another station
  (`move.tool`, tools/move.ts `answer`); a clone already answers at once and tells its end (`move.repo.made`),
  a hand-over's drop is answered as it is marked and taken out by that station itself (replica/AGENTS.md). The station
  asked starts it and answers `under`, tells how it goes every `TOLD_EVERY_MS` (`move.told`) and its end until
  answered; the asker waits with no clock on its length, asks it again after `TOLD_SILENT_MS` of silence or as the
  other is heard from after one, and only that ask failing fails it (a station found gone, above); a stopped turn lets
  go of the step it waits on at once (handover.ts `abandon`, told.ts `letGo`), the other taking out what it put once
  the step ends there. Each step can run
  again: a process that did not know it starts it on that ask. `chat-handover-steps.test.ts` holds every request a move
  asks to its time, with all the work there held ten minutes, and fails on one it does not know: a new request is put
  in its table with what bounds it.
- People move with `POST /move` and `POST /move/back` (owners and admins; 202, the scheduler's
  turn going on; one turn at a time, an agent's and a person's alike: a second while one runs is 409). No card there:
  the press in the app is the confirmation.
- Moving is a `beta` feature of the station's (`features.ts` `stationMoveOn`): on on a station updated on the test
  channel, off on a stable one, nothing said over it (a drill's stations are on the test channel: e2e-local.sh), offered
  in the overview (`features`, and `move.offered` for apps from before) where it is on; off, `station_move` is no
  agent's tool and no instructions name stillfail-move. Off, every turn is refused before anything is held (the
  scheduler asks `refusal` first: here, then `move.open` there, one that refuses it being from before and off, one not reached said to be out of reach), and a
  station that is off takes no `handover.begin` and sends nothing back; `GET /move` still answers. A turn waits in `refusal`
  until the station process before this one is gone (a launcher's hand-over between processes: one process at a time
  acts on a move, replica/handover.ts `previous`), and so does every `move.*` and `handover.*` request answered here;
  past `PREVIOUS_LIMIT_MS` (ops/previous.ts, on the station's clock) each is refused in words, ask again in a moment
  (`station.move.previousStill`), the process before named once in the log. The station itself goes on waiting.
- A message a device wrote under its idempotency key (api/admin.ts `once`) goes with its chat: what was kept of it is
  sent with `handover.show` and kept there under the thread's id there, so the device's retry there is answered as
  here, not posted again (`keptSends`, `keepSends`).
- A chat's files go twice (`station/src/replica/handover.ts`): first while it works, then held only for what changed
  since, the station it goes to keeping what the first placed (`placed.txt`), so its pause does not grow with its room.
  It goes only where what it adds there leaves the floor free (handover.ts `floorOf`: the larger of 20 GiB and a tenth
  of that disk): what that station lacks of it (sending.ts `adds`, asked before anything is sent, and only where its whole size might not fit), never its whole
  size, as a room left there before (a retirement's, the same paths) takes what arrives in its place (the real run,
  2026-11-15: 110 chats moved to Office-Host-2 and its free bytes did not fall). Refused in numbers before it is held.
- What a move would send of each chat is known before it starts (`sizes.ts`): sized by the gathering's own walk in its
  the MoonBit program (carry.ts `sizesSoon`, carry.mbt `carry_sizes`: the same walk, so the same files, bounded a session, said at least past it), kept a line a session
  (`sizes.log`) against the session as it was (chats.ts `stampOf`: its last activity, archived or not, its last job and
  where that stands); a plan read at rest starts one pass over those whose stamp changed and looks at no other room
  (none while a turn runs here: what it reads then waits for a plan at rest; a chat that left needs no size). A whole
  move waits for that pass, asks the other what it has where each chat would go (`move.sizes`, sized there the same
  way) and its disk (`move.open`), and is refused before anything is held where what it adds would leave less than the
  floor (`roomForAll`); one that answers neither is refused by no sum, each chat checked as it goes.
- A turn holds the station's self-update from its first item to its end, and the station taking a request or a chat
  holds it while it does (`station/src/updates/holds.ts`). A turn cut by a stop is kept as `last` saying so (`turn.json`); as
  the station starts, and as a station is heard from again, what waits for an item that is here goes on
  (`settleStopped`). `POST /move/stop` and station_move `stop` stop a turn: nothing further starts, a chat not yet
  gone gives up and goes on here, one gone completes. `all` goes through every chat a page at a time.
- `station_move` (`station/src/tools/move.ts`, skill `station/src/skills/stillfail-move.md`) is the scheduler's face: one chat or item
  needs no card (it pauses seconds and moving it back undoes it); `all` is confirmed once on a card by an owner or admin
  in the app (`MoveAsks`, the card choice `move`).
