---
name: stillfail-move
description: Move chats, accounts, jobs and connects to another still.fail station of the workspace one item at a time, or a whole station (迁移聊天/迁走整台 station), and back, with station_move. Read before plan, move or back.
---

# Move to another station with station_move

A move is made of items, each of one module, each moved and moved back on its own while both stations keep working:

- `accounts`: one account's login (`share:<id>`, `key:<hash>`, `own:<id>@<station>`). A shared one stays usable here
  (this station borrows it). One that is not shared, or cannot be (Grok, Cursor, Devin, Antigravity, Kimi sign-ins), is
  gone from here: the chats here that run on it are **stopped** (held, nothing lost: what is said to them waits) until
  they move too or the account comes back. This machine's own login (`machine:`) never moves: sign in there with the
  login tool.
- `chats`: one chat, by its session key (those sharing a still.fail chat go together). It needs its accounts there.
  Moving it pauses it for seconds: its turn is waited for, it is held, its files and rows go, the other station shows
  it, its Slack or Feishu threads are re-pointed there. Nothing is posted in the chat or its threads; its agent is told
  once there, as its next turn starts. A failure before the switch leaves it working here as before.
- `jobs`: one job or service a chat had running. Stopped as its chat is held, started there once the chat is there
  (moving one chat moves its jobs right after). A job runs on one station at a time.
- `connects`: one Slack or Feishu connect, once the chats that came through it are there. A Comma or single-session
  connect goes first: its chats here stop, and each goes on there as it moves.
- `repos`: a repository a chat's git worktree hangs on (cloned there, what no remote has sent along); a chat with such
  a worktree needs it there first.
- `vault`: an owner's secrets kept here (the station's copies of them). Granted secrets are asked again there.
- `settings`: config.json's choices (sandboxes, agentEnv, archiving and the like); back, the other's are put back.

The agents' memory and skills, and each person's presets, are the same on every station of the workspace already:
nothing of them moves.

An item can also arrive stopped where what it needs is not there yet (`arriveStopped`, or moving back: what needs an
item comes back first, stopped, then the item), and goes on as that arrives.

How to go about it:

1. `plan {to}`: a summary, the same size however many chats the station has: each module's counts (here, there,
   moving, stopped, failed, cannot), what cannot move grouped by why (a count and a few examples each), what moving an
   item alone would stop here, what is lent there and what is stopped here (grouped by what it waits for). A module's
   items a page at a time: `plan {to, module, limit}` (at most 200; `more` names the last, give it as `after` for the
   next page); one item: `plan {to, module, item}`. `room` says the chats' files in bytes (as far as measured: a
   plan read starts measuring what changed) and what is free there. A whole move that would not leave that station
   20 GB (or a tenth of its disk) free is refused before anything moves, counting only what it lacks (a room it has
   already is not sent again); so is each chat. Tell the person what you found before moving anything big.
2. One chat (try an unimportant one first on real stations): `move {to, module: "chats", item: "<session key>"}`. An
   account it needs that is not there yet is named in the answer: move it first (`withNeeds: true` does it in order).
3. A batch: one `move` per item, or `withNeeds`. A whole station: `move {to, all: true}` posts a card in this chat that
   an owner or admin confirms in the still.fail app; then every item moves in order, those that cannot are listed with
   why, and it stops at the first failure and says which. Connects and logins go last by their needs.
4. `status {to}` says where each stands, as `plan` does (a summary; a module's items a page at a time).
5. `station: <another station>` has that station do any of these with its own items (`all` excepted: ask from a
   chat there). `wait: false` refuses a chat that is in a turn rather than waiting for it.
6. `back {to: <the station it is on>, module, item}` moves it back here; an item something there still needs is
   refused, naming it: move that back first, or ask with `all`.
7. `stop` stops the move under way: nothing further of it starts; a chat whose files are still going stays here and
   goes on, one already gone completes there. What came of it is said as it ends.

A station moved whole is still in the workspace afterwards: taking it out is the person's own step in the app.
