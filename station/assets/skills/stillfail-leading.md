---
name: stillfail-leading
description: Lead other chats or subagents toward one goal (chat_create for me, a domain split among chats): keep a goal ledger, set what counts as done before handing work out, check their claims before passing them on, report by the goal. Read it before you hand out such work and before you tell people what came back.
---

# Leading chats and subagents

What a leader gives that the chats it leads cannot is judgement: it holds the goal and its person's rules, checks what
comes back, and decides. Passing their reports on, tidied into tables, makes it a blind merger of weekly reports: one
"did you check?" from its person shows conclusions that were wrong, and directions the work set out with that nobody
took up.

## 1. A goal ledger, which every report is written from
At the start write `ledger.md` in your workspace, and keep it as you hand work out, take results and decide:
- **The goal and its measure**: what your person wants, by the measure it started from (a hang count on real devices,
  not a proxy that is easier to measure). Changing the measure says why, and the first one is looked at again.
- **Their rules**, in their words.
- **The directions**: one line each: not started / under way (by whom) / done (its evidence: a PR, a test, the measure
  moved) / dropped (who decided, why).
- **Decisions**: what you decided and why; what you turned down of what a chat said.
After each round, read it again: was a direction you began with pushed out by small finds that came up meanwhile? Put
it back, or tell your person why not.

## 2. Handing work out: what counts as done first, the scope yours
A first message (chat_create `text`, a subagent's brief) says:
- Which direction of the ledger it is, why, and your person's rules that bear on it, in their words.
- **What counts as done**: a test that fails before the change and passes after; the invariant to hold; the measure.
- **The evidence to bring**: each conclusion with its file:line, the path of the raw output, the test's name;
  conclusions apart from their evidence.
- That dropping a part, finding no gain, finding it cannot be done, needing a person, or changing what people see is a
  **proposal** with its grounds, for you to decide: it neither narrows the work itself nor asks a person.

## 3. Checking before you pass anything on
Each conclusion you tell people says whether you checked it, and how.
- **Check yourself**, in the code or the data: a negative conclusion (drop it, no gain, cannot be done); anything
  against your person's rules; anything that would ask them or make them wait; any "must", "only" or "impossible".
  These are the ones most often wrong, and the dearest when they are.
- **Sample** the positive ones: does the diff change what it says; did the test fail before; is the number on the
  ledger's measure, against a baseline of the same toolchain.
- **A large judgement on the design**: a fresh agent checks it, given the code and the question, never the conclusion.
- Found wrong: written in the ledger, and sent back saying why it is wrong and what to do, not "have another look".
- **Archive finished sub-chats**: once a led sub-chat (`chat_create for: "me"`) finishes and its result is accepted or dropped with no further back-and-forth needed, archive it with `chat_archive` so the leader's sub-chats list stays focused on active work.

## 4. What you tell your person, in four parts
1. Progress by the goal, direction by direction of the ledger, those not started included.
2. What you decided, and why.
3. What of the chats' reports you turned down.
4. What they need to decide.
A list of PRs and their percentages goes last in a line, or nowhere; a chat's table is never pasted as it came.
