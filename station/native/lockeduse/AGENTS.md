# Locked use (for agents)

Agents use a locked Mac's screen behind a guard. The station asks the Helper, the Helper asks the guard, the guard gives the SecurityAgent plugin one unlock. Package.swift names the parts.

- Never a lock-screen backdoor. The plugin allows an unlock only on a whole `yes` from the installed guard. It checks the guard's code, root-owned path, euid and binding. Every other result denies, and the screensaver rule goes on to the password.
- An unlock is one-shot and lasts seconds (`Unlock.armedFor`). Never add a "pending unlock?" query or a longer window. Codex's plugin approved an unlock long after its task ended because its plugin asked for state.
- Once the plugin takes an unlock, every path relocks: the end of a lease, a fault, local input, the Helper or guard gone, a late unlock (`Unlock.tick`). The cover goes only after the screen is checked locked against the session. Notifications are hints only, because any process of the user can post one.
- Relock only an unlock the guard gave out. Never lock a Mac its person unlocked (Codex locked unlocked Macs).
- The screensaver rule gets one more way, never one less. Refuse any rule that needs several parts (no `k-of-n`, or `k-of-n` > 1): "any one" would drop a second factor. Write `k-of-n = 1` when adding to a single rule: without it, "all of" locks the person out.
- Root tools (`stillfail-lockeduse`, pkg scripts) read no user-writable file, follow no link (`O_NOFOLLOW`, `lstat`), and never touch home folders. They check the rule before they delete its backup.
- Install, bind and uninstall change a Mac's security settings: only an administrator runs them, on that Mac. Agents never run them without the person's explicit go-ahead for each step.
- Known gaps: Universal Control is refused, and remapping drivers that repost device events can pass the tap. The lock-screen trigger (`Trigger.swift`) is not verified on a Mac yet.
