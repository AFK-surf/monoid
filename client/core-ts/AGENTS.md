# Working on the client core (for agents)

The core is every client's logic: the app on every platform runs it in Hermes (`apps/mbui/engine`, Apple's
`apps/mbui/src/host/apple_core.mm`), the web in a tab's worker (`src/hosts/web.ts`). The UIs send it named calls,
hold subscriptions to its topics and draw what it pushes; they never reach a station or the cloud themselves. Its
design rules (the user, 2026-10-03):

1. **Everything async is Effect**: calls, subscriptions, links, sockets, sync are fibers in scopes (`src/runtime.ts`);
   cancelling is interrupting; timers are the Clock's (a TestClock in tests), never `setTimeout`. `Host`
   (`src/host.ts`, declared in `src/host-of.ts`, made in `src/hosts/`) is what differs per platform, every operation an Effect.
2. **Pushed, never polled**: a station's `/events`, the cloud's `/v1/events`. Only a measure shown on screen (a link's
   speed, "waited 3 s") is sampled, while it is looked at.
3. **Cache first**: each signed-in account has its SQLite database (`src/data.ts`, `src/db/`), one writer, schema
   versioned and migrated. A topic is read from it by a query, never from the network.
4. **One sync owns all traffic** (`src/sync/scheduler.ts`, `src/station/sync.ts`, `src/sync/cloud.ts`): it keeps
   everything current by itself whatever is shown; what a UI shows or `client.focus` only raises priority. A
   subscription never starts a request. (Exceptions, read only while shown: a station's usage, its archived chats; a
   chat its station's lists do not have, its thread or its session, read as it is opened so that it shows or says it
   is not there, never waits for good.)
5. **An action does not wait for the network**: it takes effect in the core at once (the outbox, a pending chat, the
   overlays of renames, pins, archives, kept in the database across restarts), `doing` tracks it, a failure rolls it
   back and says why. Something made here meets the station's by its exact `clientKey`, never by a guess.
6. **Changes are by key**: a view makes its topic's value again whole as anything it read changes; the store keeps
   what equals the last value as the same objects (`src/collections.ts` `share`), sends a keyed subscriber insert,
   patch, drop and move ops of its keyed lists (`diffKeyed`), and shapes again only items that are not the objects that
   went out (`src/output.ts`). In each of these steps an item that is the object it was costs one comparison of two
   references (or a lookup by the object) and nothing else; the rest is walked only for what is not the same. An item
   a view keeps and hands again is so too where it is not the object the store holds (the store kept the one of
   before, or put one together of both): `share` remembers what a value, a keyed list and each of its items was kept
   as (a topic's own `kept`), so a list a view keeps the items of is a keyed list (`SPECS`). What that still walks for
   one change is counted (`test/view-work.test.ts`).
7. **Workspaces are isolated** from each other.

File readers share both kept bytes and outstanding ranges of the same version (the owner, 2026-11-18).
A new consumer uses the core's station file reads. Test it alongside a save with the wire held mid-part,
counting requested intervals in both orders and after either reader leaves (test/downloads.test.ts).

## What a topic sends is bounded

The app parses every message of the core on its frame thread: on the owner's phone a `stations` of 463 KB took 25–86 ms
each time it came. So what a topic sends is bounded (the user, 2026-11-10): `test/topic-bytes.test.ts` measures every
way the app asks each topic on a workspace of real size (`test/real-size.ts`), a value sent whole at most 32 KB, a
message as something changes at most 4 KB. A list's item carries what its row shows; a page of one thing asks that
thing's own topic; a field one page needs is not added to a list every page holds; a new topic is placed in the test's
tables. A page's topic carries what the page draws; what shows only after a press is asked at the press, answered at
once from the device's data, and what it opens appears whole once that is there (the user, 2026-11-11): a chat list's
row and its menu (`chatRow`), a new chat's model control closed and its panel (`pick`). The test's `OVER` tables only
fall. A topic the app lets go of keeping its value (`keep`) and asks again (`have`) is sent `same`, or what changed from what it kept (store.ts `#first`), held to the change's bar too (`OVER_AGAIN`).
Every way of asking has a change measured, a cause of `test/real-size-asked.ts` `CAUSES` that changes what it shows as
the sync is told it, or is in the test's `STILL` with why its value does not change while shown, and `STILL` only
falls; what each cause sends is written for the app's sweep as the ops a device applies (`test/real-size-app.test.ts`,
`apps/mbui/src/sfrealsize/c_*.mbt`). What goes out is what the topic's shape declares, the rest dropped
(`src/conform.ts`), while the core's own readers read its whole value (`store.value`): a field the core reads and
no UI does stays out of the shape (a chat's agents' models,
which `src/choose.ts` reads of `views.agent`). A part a view shapes once for every topic that holds it (views.ts
`asShaped`) goes out as each topic's own shape says there (a station's overview to its page as `StationOverview`,
conform.ts `reshaped`); where one shape is sent by several topics and only some pages read a field, the others get a
shape of their own (`ListedProfile`, `StationProfile` beside `Profile`). The fixture fills every list and map a
weighed topic's shape declares: one left empty is listed in the test's `EMPTY` with why (an error or a state the
workspace is not in, a thing it has none of), and `EMPTY` only falls; a topic is left unweighed (`NOT_MEASURED`) only
with the bound that keeps it small named (a cap's constant, a fixed set of fields). A picture goes in no topic's
value: the value names it by a token and its bytes come beside a call's answer (a link's card's and a file's peek's:
`src/peek-pictures.ts`; a chat's: `station.file`).

## What answering reads follows what it sends

What answering a way of asking reads of the database follows what it sends, not how much the device holds (the owner,
2026-11-12: 「不应该这么无休止地扣细节」「这应该从架构设计和测试层面解决」, after two days of slow topics found one at a
time by hand). `test/topic-work.test.ts` counts, in the database's own calls, the bytes of text every way of `ASKED`
reads on a core started anew (and asked again), and each interaction the app sends (a start, a switch of workspace, a
chat opened, a place of the bar) to its first screen and to rest: at most twice what it sends or 8 KB, and with the
workspace's chats, messages, profiles, people or stations three times (real-size.ts `Size`, a worker thread a size), its
reading growing no faster than what it sends. Those over now are in its `OVER_READ`, `OVER_READ_AGAIN` and `GROWS` (by
what each reads, at its size: a ratio would rise as a fixed part of the reading goes), which only fall; a failure prints
the statements that read most. What the sync writes is held the same way: each cause of `CAUSES`, in turn on one rig
of each setting, from its run to the core at rest, alone (a core started anew, nothing asked) and held (everything the
app asks held), reads at most twice what it writes (text bound to statements that write) and sends, or 8 KB, growing
no faster; `OVER_WRITE` and `GROWS_WRITE` there, which only fall. A new cause is measured by being in `CAUSES`.
A page of the settings opened first in a run, Home shown (the owner, 2026-11-16: 「设置页面第一次点进去会卡挺久」), is
held the same way by `test/cold-open.test.ts`: it decorates and reads no station's whole overview (what each page reads
of one is a column of `station_part`, schema.ts PART_COLUMNS) and runs as many statements with five times the chats'
logs; what each chat keeps (`cache.usage`) is read of counts triggers keep (`log_bytes`, schema.ts ensureLogBytes),
never summed of the rows, and so are the files kept (`part_bytes`, drive-kept.ts ensurePartBytes, never `part`), and
that call, which changes nothing, lets the first values of the page it is asked with go first (store.ts `turn`); a call
that changes something never waits so (rule 5).
A chat opened first in a run is held there too, as a page that waits on writes it need not do is slow: up to its first
values it writes nothing (what showing notes, a tree of Markdown read or shown, a log opened, is pending in `Data` and
written in one transaction after them, data.ts `flushMd` at store.ts `turn`, and as the core closes), reads its replies'
trees in one statement (`MdStore.preload`), and runs as many statements with five times the chats. Its replies read
ahead (md-ahead.ts) are read afresh by nothing as it opens.
What the views, the store and what goes out walk in memory is held the same way (`test/view-work.test.ts`): work.ts
`walked` counts reads tracked, values made again, `share`'s and `equal`'s walks, keyed lists' diffs and the items put
together, copied and fitted as they go out, each to the topic made or sent then, past the items found the same objects
(`same`, one comparison an item of what is shown: printed, not held); each cause, held, walks no more with
what is shown three times as large (the lists' windows, the chat's messages, a `limit`, `lines`, `days`) nor with three
times the chats. Those that do are in its `OVER_SHOWN` and `OVER_CHATS` as pairs (a cause, a counter that grows), which
only fall as a set; by how much one grows is printed, not held (a field more in a row moves what it counts).
What the sync makes of an event of a chat is held on the sync's own path (`test/rows-changed.test.ts`): a station's
rows are made through a memo on its link (`src/station/rows-made.ts` `RowsMemo`: a row whose parts are the objects they
were is the row made before, frozen) and written as the list was last written (`src/db/account.ts` `#chatsHeld`: a row's
object and place, never its JSON), so one change of one chat makes and serialises 1-2 rows and reads no more chats'
JSON than it serialises, the same with three times the chats, and what is stored is what a core started anew makes of
the same records. Of a station that makes its list (`link.shared`, every one since build 7143) a change is by key end to
end: `#remake` names its rows (an id, a thread's, none; whole only for the list or the marks read whole, whose rows
they are, the words), each made alone (rows-made.ts `rowShared`, the viewer's own of the marks kept as sets and maps,
`OwnHeld`) and written by its key at a place of its own (`sharedPlace`, ties by id; a place alone changed, as a list
held in the places of before takes these once, is that row's place written alone, account.ts `#placeChatRow`), so it
looks at no other row: every `glanced` counter stays 0 there but the marks' lists of threads the older path reads
(kept, hidden, muted, suggested, dismissed), walked where a scoped read or what was said puts its own in them, in the
test's `SHARED_MARKS_WALKED` (they go with that path); the older path's (rowsMade) are in its `OLDER_GLANCED`. Both
only fall. `CAUSES` tell a change of one item of a station's list by its key, as the sync takes the station's event
(real-size-asked.ts `listTold`: a chat's row put at its place or dropped, a thread put, a session's summary put), a list
written whole only as the rig is first given it; one told otherwise, as so it would send otherwise, is in its `UNTOLD`.

## The chat table is read by what a view shows

A view never reads a station's chats whole (2026-11-12): every read of the `chat` table is a declaration in
`src/db/chat-reads.ts` (its statement, its bound: one row by a key, the first rows of an order, counts SQLite makes of
columns; the keys it is told by, and those a written row tells, before and after), read through `Data.chatFound` and
`chatCounted`, the records of what it finds taken from the cache by their keys. Its bound holds for the work SQLite does,
not only for what it returns: `test/chat-plans.test.ts` holds every declaration's plan to it (`one`: found by its key
through an index, no walk of a station's rows; `first`: walked in an index's order, so its LIMIT stops the walk;
`count`: of covering indexes alone), on a database as the core opens one (it never runs ANALYZE), and its `OVER_PLAN`
only falls; an index a read needs is made at every open (schema.ts ensureChatColumns). A read is run again only as it
is told (Data keeps each answer by its keys' revisions, #chatRows), and told only by a write that can change it: a
station's read says what of a row its answer reads (`by`: whether the row is in it, its order, what it counts), so an
agent's state changing tells the window nothing, the row reaching the list by its own key (`$chat-row`, the records a
read found by `$chat-record`); `test/chat-told.test.ts` holds every declaration to it (a write that changes an answer
told it, and what a view reads is what the statement gives), and its `TOLD_SAME` (told, the answer the same) only
falls. A read's name is its own. The chat list is a window over the index
(views.ts `#window`), what is overlaid here (local.ts `overlaid`) read apart by its keys. A new read is a declaration
there; `scripts/whole-lists.ts` refuses a whole list read, and its `WHOLE` says where one still is and what takes it away.
A column a read needs is derived as the record is written (SQLite's of its JSON, schema.ts `CHAT_COLUMNS`, held to the
JS's rule by list-rows.test.ts; the core's, `state` and `watched`, Derive: one algorithm each), and for rows an older core wrote (their `made` not `CHAT_MADE`) at the next open: every host opens its
database alone (`locking_mode EXCLUSIVE`), so nothing an older core wrote is read before that.

## A chat on another station now

A chat handed to another station of its workspace (station/src/replica/handover.ts) is shown once, where it is, and
goes on there with nothing said (`src/views/moved.ts` says how). Where it went is kept by the station it left and its
session (account.ts `putMoved`, table `moved`) and read by `Data.chatNow`; a row of a station that said its chat went
is never written (account.ts `#movedAway`), nor one the station it went to says came from it (its session's `from`,
`#came`), so every read of `chat` sees one row a chat and no read filters. One session key on two stations with
neither said is two chats (a platform thread's key is its connect's, each station's own: the lead, 2026-11-14).
What names a chat on the station it left (a call's params, a link, a page's topic, a draft) is aimed through
`chatNow` where it is read, never by rewriting what the UI holds: a page open on it keeps its topics and its thread id,
each shown of its copy there (core/routing.ts `#movedTo`, one place for every topic a chat's page holds).
`#came` is one rule whichever of the row and its summary's `from` comes first (`#summaryCame`), and takes the chat
by its thread there once its row names it. A log held of a station that said its chat went is never asked of that
station (its catch-up as a stream comes back aimed by `chatNow`: it would answer 404); and being told a chat is on a
station (the one it left saying so, a `409 moved`, its row there come from another, it back) lets go of what was kept
of it there as not there and reads again what a page holds of it (station/sync.ts `chatHere`).

## What is shared is never written

Unchanged things being the same object is what makes rule 6 work, so a value read from the database
(`Data.shared()`), stored or computed in the store, sent out (`src/output.ts`) or kept in a cache is read-only from
the moment it is made. A function writes only on objects it made this time: copy at the level it changes
(`{ ...m, by: { ...m.by, here: true } }`, `[...a].sort()`), put back what did not change. Tests and the web's
development build deep-freeze shared values (`src/util.ts` `sharedValue`); `scripts/writes.ts` refuses writes on
parameters in the files that make views.

## What is made of a record is kept beside it

What the core makes of one record and of what else its key says is kept beside that record, by one mechanism
(`src/db/kept.ts`, 2026-11-12: the owner's 「从架构设计和测试层面解决」, after it had been written by hand three times):
a declaration in its `KEPT` says the table, the record it is made of, whether it is made as a reader first reads it
(`read`: then at every write of its record, so a write costs by what was shown) or at every write (`written`), and how
it is made (`making`); the views register its maker (Data.makes). Triggers drop a value as its record changes, whoever
writes it; a hit reads no record. `test/kept.test.ts` holds every declaration to that on the workspace of real size, and a
new one is an entry of its `HOW`. So a maker reads nothing outside its record that its key does not say (each
declaration's own test varies its surroundings: list-rows.test.ts, profile-rows.test.ts), and a change to how one is
made raises its `making` (their digests say so). What a kept row cannot hold is the reader's as it reads: a chat list's
what is changing or asked here (`src/views/local.ts`), a message that did not go (`#unsentRow`), a chat opened from
another; the accounts' list's merge across stations and its refills.

## A person's presets and starred models

- They are the person's, carried by their own devices (the user, 2026-11-14): the device keeps its records of each
  workspace (`src/presets-kept.ts`, `presetRecords`; the stars in `choice` `ws:<ws>:liked`), every topic reads those,
  and `src/views/presets.ts` brings each station what it lacks by the one rule (`src/preset-records.ts`, shared with
  the station; never a second copy of it). A change is made here at once and carried as a link opens, as a station
  tells `presets` or `stars`, and as it is made: never on a timer, and a station is brought only what is strictly newer
  than what it said; what one station had newer goes on to the others reached then. A stream that comes back resumed
  is told again the `presets` and `stars` it missed (the station logs them), so it is asked only what the device owes
  that station (`owed`, `owedStars` beside the records: a station passed by while not reached, a carry that failed)
  or where it has never read them of it (`met`, `metStars`: a core updated to this whose stream is restored from the
  cursor its last one kept reads each station once), nothing otherwise (`also`'s `resumed`); a whole read carries as
  a link opens.
- Deletions are kept as a station keeps them, so many of each owner's (`preset-records.ts` `goneKept`, `GONE_KEPT`):
  the device trims what it holds by that rule as it keeps, never bringing one a station would drop (with a bound of
  the workspace's that went round for good, 2026-11-14). A deletion of nobody said (an app from before's, of a preset
  of before not made by who deleted it) is taken only where the device holds that preset as its own, as its own
  deletion one change more (`presets-kept.ts` `ownerless`).
- A station from before (GET /presets/kept answers `no route`) is never PUT to, read and written the old way, and a
  chat on it is opened by the preset's id where it lists it; everywhere else by `presetCopy` of what the device holds.
- People see their own presets; others' only at a press (`otherPresets`, read as shown, kept in memory but for the one
  picked; its `reading` waits for a station `OTHERS_WAIT_MS` at most, so one slow or hung holds the press no longer,
  what it says later joining the list while it is held). Someone else's is looked at, opened with and copied (`preset.copy`), never changed from here.

## A lock held here

- **Active chain and fork choice**: A lock's chain (`lock` record for a workspace, or a person's pinned chain in
  `src/personal-lock.ts`) is written only through `src/views/lock.ts` `hold` and `src/personal-lock.ts` `#heard`/`#pin`
  using the rules' fork choice (`src/lock-keep.ts`). Never append an entry whose `prev` does not match the head hash, and
  keep forks up to `ASIDE_MOST`.
- **Signing and retries**: Sign one entry at a time in that lock's turn (`Lock.append`, `#append`). Entries that lost
  their place are re-signed only under `lock-keep.ts` `againOf` (at most `AGAIN_MOST` times, and for a personal lock only
  when the seed is already in hand). If a user-requested entry cannot be re-signed, surface it as a failed pending entry
  (`#letBe`), never silently drop it.
- **No background prompts for sealed secrets**: Background work (incoming lock updates, retries, background writers)
  must never read a value sealed for user presence or prompt the user; only an explicit user action on this device reads
  a sealed secret once, and background rekeying waits until the key is next unsealed (`src/views/vault.ts`). Why
  (2026-11-13): `rekeyGone` read the box key each time the lock came, on a device nobody was using.
- **Station acceptance vs. cloud**: The cloud taking an entry never counts as acceptance. An entry not yet taken or
  refused by a named station within the call's wait is kept in `src/lock-pending.ts` (never on the chain itself), shown
  as pending, and delivered when a station is next read (`deliver`), never on a timer. The cloud is sent an entry only
  after a station takes it (except when a lock names no stations at all, or a personal lock is begun anew: 2026-11-13,
  a lock whose one station retired could never be changed again).
- **Moved workspaces (`moved {root}`)**:
  - Once a workspace chain holds `moved {root}`, the state in force is computed by `rules` (`state4_moved` in
    `src/lock-moved.ts`, read via `src/views/lock.ts` `stateOf`) from the moved chain plus members' personal logs
    (`lockLogs`) and statement bodies (`lockBodies`, synced by head hashes via `GET /lock/heads` and `POST /lock/given`).
    Nothing is ever signed on the moved chain itself (`Lock.append` returns `lock_moved`). Whether a workspace is in
    safe mode is views/lock.ts `safeMode`, by the lock held (`lockSafe`), the cloud's `locked` only where none is held
    (2026-11-14).
  - Workspace changes after a move are statements in the acting person's own log (`src/lock-statements.ts`, `sayMoved`),
    which ask the person each time (the owner, 2026-11-13: a phone taken while unlocked, its screen lock not known, then
    changes no list, approves no web page and cannot undo its own removal). Before asking, the rules work out what it
    would do: whoever it would take out besides is said again first (removing someone takes nobody else out), and one
    that would not do what it means is refused. The body goes only to the stations its list names, on that
    workspace's address, never to the cloud nor a station of another workspace.
  - Off and on again are the root's person's alone, on the log that binds them (`lock_root_only`, naming them and the
    way out, `stillfail lock reset`). Turning a moved workspace off asks twice (the lead, 2026-11-13: the person's own
    secrets opened first, then `off` signed; one ask for both needs the host to open two sealed values under one
    prompt, not built).
  - Web sessions in a moved workspace require at least one app device on that person's log (`web` statement approved face
    to face by their own app device; if they have no app device, return `lock_needs_app` / `needsAppIn`). A member with
    only a web page holds nothing back and is told nothing before the move (the owner, 2026-11-13: 「开了安全模式那就需要
    app」): their page is carried until its `exp`.
  - When admitting a newcomer (`member {sub, email, lock, role}`), never trust the cloud view's role alone: use the role
    noted when adding them on this device (`notedRole`, defaulting to `member`), capped by the cloud view's role. So
    someone added as an admin on one device and approved from another comes in a member; an owner makes them an admin
    by changing their role.
  - Before removing a device or member, level vaults from reachable stations (`levelVaults`, `takeBefore`) so valid
    versions written before removal are preserved before rekeying, taken only where they check by the state just before
    that removal, no wider than a chain's (the lead, 2026-11-14: a moved workspace does for people what an unmoved one
    does). A removal said there reads no box key; a vault keyed for someone taken out waits and is keyed anew by its
    owner's device as its key is next unsealed for something the person does.
  - What people are told: a change asked from a device on no log of theirs answers in the words of one not trusted
    (`core-misc.lock.notSigner`, views/lock.ts `notTrustedHere`), one of another member's app devices says it is
    theirs alone (`core-misc.lock.othersDevice`). A device refused where the chain moved asks that station again at its
    link's own retry: nobody is to open the app or press because of a move (the lead, 2026-11-14).
  - A person's own lock is begun anew (`lock.restartOwn`, 我的其它设备都不在了) or one begun elsewhere taken as theirs
    (`lock.forgetOwn`) only by their press, offered once none of their devices answered (`restartText`) or the lock was
    `replaced` (`forgetText`): never by itself, which would tell their devices left elsewhere it was `replaced`.
    While a workspace still binds them by the lock of before, this device asks nobody and says who takes them out and
    adds them again (views/lock.ts `reboundIn`, by the refusal's `left.apps`: a station names every log of theirs it
    keeps in `person`, the one of before too after they are taken out).
  - A station the chain named as it moved, or seen keeping it since (`lockServes`' `pinned`), that keeps none now was
    reset on its machine (`stillfail lock reset`): never brought the lock again by a read (`bringMoved`), only by an
    owner's 保护 (`stationMoved`). Every station the state in force names keeping none lets the lock go here, and an
    owner's device drops the cloud's copy (DELETE), which a genesis turned on anew meets again too (`lock_exists`).
- **Seamless handover (`handOver`, 无感迁移)**:
  - `handOver` (`src/lock-handover.ts`, `src/views/lock.ts`) runs automatically from `HAND_OVER_FROM` once all stations named
    by the chain advertise the required capabilities (`bodies`, `logs`, `builds`, `carried`, `bind`, plus `heads` for
    large workspaces above `LOGS_BEFORE`) and this device is at least at `MOVED_FROM_BUILD` (`LOGS_ANY_FROM_BUILD` for
    large workspaces). It says nothing in anyone's log and asks nobody (the lead, 2026-11-14); `lock.handOver` answers
    `unknown_call` unless chains are handed over by themselves or the host says `handOverByTests` (never the
    environment nor a preference); a `moved` that lost its place is never signed again (`#lost`). Builds between this
    code's and `MOVED_FROM_BUILD` move nothing (the lead, 2026-11-14); a workspace of any size is handed over (the lead,
    2026-11-15).
  - Who hands over (the user, 2026-11-14, 「都按推荐」): the person who turned safe mode on (`genesisPerson`); another
    owner's device only once that person has not in 14 days from the later of `HAND_OVER_FROM` and the genesis, or is
    no owner on the chain any more (`mayHandOver`). To people it is 安全模式的升级 (the owner, 2026-11-14), never a
    handover; its pending row is 完成安全模式的升级.
  - **Do not bring a wait for people's devices back**: never block handover on offline or older member app devices. Any
    app device below the floor is simply told to update (`movedTooOld`) when it next talks to a station, and rejoins
    without re-approval once updated. Why (the user, 2026-11-14): his own unused phone held his workspace back seven
    days with nothing saying why (「用户要是有个设备离线不用了要等 7 天？」).
  - After the move a person's devices the chain named and their log does not are put on that log by their other
    device; a member the chain bound to no log is bound by `bind` riding the next thing they do on their own lock, in
    its one ask (views/lock.ts `bindsFor`; the lead, 2026-11-14: nothing more asked, nobody else involved), and one with
    no log has it begun on such an act (personal-lock.ts `seedFor`); their own new app asks them, never owners and
    admins.
  - After a move, the genesis (`root`) person is an ordinary member (`~root` in `rules/AGENTS.md`): once every station
    the state names serves `rootout` (views/lock.ts `rootOutServed`), another owner can remove and re-admit them like
    any other member. Their new app begins its lock anew and brings the pinned chain to the stations again only for a
    reason that changed since one took it (`#bringPinned`; 2026-11-14: each read and refusal brought it, 878 POSTs in
    91 s).
- **Known, not built for**: a station of another workspace from before build 8799 keeps a stale copy of the person's
  log once they say a statement; a root log holding statements of a half-done handover of builds 9040-9054 that the
  chain has since contradicted is held back silently (the lead, 2026-11-14); a workspace already moved that grows past
  `LOGS_BEFORE` logs while one of its stations is from before is read wrong there by a core from before (the lead,
  2026-11-15).
- **What holds it**: `test/lock-moved-state.test.ts` (the state, to the model), `test/lock-statements-made.test.ts` (the
  bodies and the take-over), `test/lock-handover.test.ts` and `test/lock-handover-model.test.ts` (the hand-over, on the
  station's own code and to the model's `m8`), `test/lock-left-out.test.ts` (a device left out, and the asks counted),
  `test/lock-pair-modes-faults.test.ts` (approved face to face in every way there, its trusted devices failing as real
  ones do: answered within a call's 40 s, in wherever one signed it in) and `test/lock-state-invariants.test.ts` (the
  page confirmed exactly where the station lets it in, every state with a way out, and the vaults' page standing as it
  does).

## The base stands apart

The device's mesh (`src/mesh.ts`: its iroh endpoints, the ways to a peer and the choice among them, links, the streams'
framing) and what runs a client (the host, the runtime, errors, words, traces, wakes, the scheduler, the reader of an
event stream, `src/sse.ts`) are the core's
base: another program is built on it without still.fail's business (the owner, 2026-11-14), so a base file imports
only base files and packages, as types too. `scripts/base.ts` holds it: its `BASE` names the files, and the set is
closed: nothing of it reaches, through any number of imports, a file that is not of it (its `STILL` is empty and stays
so). The base says its own words with nothing else loaded (`src/lang.ts`: the two files beside it, `src/lang.zh.json`
and `src/lang.en.json`, the script's `WORDS`: every key a base file says, of no program, the peer "the server"), and
a program gives its own in their place (`words`). still.fail's are its catalog's, where each of those keys is written
as still.fail says it, in a part named by more of the key (`client/i18n/catalog/zh/core-misc.wake.json`): a change to
what still.fail says goes there, and to the base's file only what any program would say. What is still.fail's is given
to it, never imported by it nor named in it: what the core does with the mesh (`src/station/mesh-wire.ts`, its
`MeshEnv` and a `CredentialSource`: a station's requests on its links, the cloud's credentials and the lock's claim,
a lock's refusals, what an app's endpoint takes; its `STATION_MESH`: a station's protocol, what its hello says after
the credential, its peers looked up, the key its stations' addresses are kept under), the catalog, whole, over the
base's own words, and the product's name (`src/i18n.ts`, the one file outside the base that imports `src/lang.ts`: what
says a word imports it, and so does, itself or through what it imports, every file that loads a base file which says
one, so that nothing of still.fail's is run with the base's words: `src/host.ts`, `src/lock.ts` and
`src/hosts/node-iroh.ts` import it for that alone), the UIs' messages and the header that asks a request twice
(`src/host.ts` `Host` and `HEDGE`; the base's
`src/host-of.ts` of them, whose `BaseHost` is all the mesh and the traces ask of a host: `src/mesh.ts`,
`src/trace.ts` and what `src/wake.ts` and `src/error.ts` do for them take that, while `WakingHost` there wraps a
program's whole host, `HostOf`, which is still.fail's, and is its user's choice), its traces' names, what its host is
called where no entry said, and its APIs' paths as a span shows them (`src/route.ts`), where its addon is
(`src/hosts/node-iroh.ts`). A mesh made without `STATION_MESH` (another program's) dials the protocol it names,
says its own hello, looks nothing up and, where it says so, goes through relays alone; what its peer answered the
hello is on the link whole (`Link.admitted`). The script refuses still.fail's name in a base file as well, but where
its `NAMED` lets it be (each text whole, as often as it says), which only falls; `src/lang.ts` imported past
`src/i18n.ts`, however spelt, by a file here, of `apps/mbui/core` or of `web/src`; and any code file git tracks in the
repository (the station's too; TypeScript's and JavaScript's) that loads `src/lang.ts`, or a base file that loads it
(by a static import, an `import("…")` or a `require("…")` of a string), without `src/i18n.ts` among its own static
imports' files, but `test/base-words.test.ts` (its `ALONE`), which holds the base's words alone and then, with the
catalog given, every key of theirs to the catalog's text. So `src/i18n.ts` has run once the load that brought such a
file is over, and a word asked for after that is still.fail's. Not held, so not to be written: a word said as a file
is loaded (its top-level code) where the file reaches `src/i18n.ts` only through a file still being loaded (an import
cycle); a base file loaded by an `import(…)` or `require(…)` of what is no string, or by a name only a bundler or a
tsconfig resolves (but `@core/`, `@stillfail/`); a file git does not track.

## Contracts made from here

- `src/ops.ts` `PARAMS` declares each operation's parameters; `scripts/operations.ts` writes the UIs' bindings from
  it. `src/shapes/schema.ts` declares what every topic gives; `scripts/shapes.ts` writes the clients' types and the
  app's `said` paths. Both are checked in and `--check`ed: change the source and run the script, never edit the output.
- Hermes 0.81 runs it: no `toSorted` and the like, no `Intl` outside `src/hosts/` (names are ordered by the host's
  `collate`). `scripts/hermes-bundle.ts` bundles it; a change that runs only in Node is not done.
- Tests: `pnpm test`, one file `node ../../scripts/native.ts run mesh -- node --test test/<file>.test.ts`; networks
  are simulated on the test's clock (`test/sim-iroh.ts`, seeds in `test/sim-seeds.ts`, `SIM_SEED=` runs one).
