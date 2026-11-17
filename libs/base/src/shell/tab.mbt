// One tab at a time: on a page, every tab of one origin shares one storage (the device's key, `idb.*`), so a program
// whose core runs in two tabs at once runs it twice on the same key and the same data: the relay passes what comes to
// the key to the tab that connected last, the other dialling again and again, and each tab numbers what it writes on
// its own. A program asks for a tab's claim under a name of its own (`claim_tab`) and runs its core only while told
// `Held`; a tab told `Busy` or `Yielded` shows the person a way to use it here (`TabClaim::take_over`), and the tab
// that held it is told `Yielded` and lets its core go. What it does then (stop its core, or load the page again) is
// the program's.
//
// On a page the claim is a Web Lock of that name (`navigator.locks`) and a take over is asked on a BroadcastChannel of
// the same name (shell_js.mbt); natively a process keeps its own directory and nothing contends: a claim is `Held` at
// once (shell_native.mbt).

///|
/// What a tab's claim is now, as it is told each change of it (`claim_tab`'s `on_state`).
#derive(Debug, Eq)
pub(all) enum TabState {
  /// This tab holds the claim: its program may run its core.
  Held
  /// Another tab of this browser held it already as this one asked.
  Busy
  /// This tab held it and let it go, another tab having taken it over.
  Yielded
}

///|
/// A tab's claim under a name, as asked (`claim_tab`).
pub struct TabClaim {
  priv take : () -> Unit
  priv let_go : () -> Unit
}

///|
/// Asks for this tab's claim under `name` (a program's own, the same in each of its tabs). `on_state` is told what the
/// claim is and each time that changes, never the same twice in a row and nothing after `TabClaim::release`. Where
/// nothing contends (natively, a page without Web Locks or a BroadcastChannel) it is told `Held` at once, before this
/// returns; on a page that has both, once the browser answers, `Held` or `Busy`.
pub fn claim_tab(name : String, on_state : (TabState) -> Unit) -> TabClaim {
  tab_claim(name, on_state)
}

///|
/// Takes the claim over (the person chose to use this tab, being told `Busy` or `Yielded`): the tab that holds it is
/// told `Yielded` and lets it go, and this one is told `Held` as it has it. Nothing while it is held here, or asked
/// already and not had yet; nothing after `TabClaim::release`.
pub fn TabClaim::take_over(self : TabClaim) -> Unit {
  (self.take)()
}

///|
/// Lets the claim go for good (the tab closes, or its program is done with it): held, the next tab that asks has it,
/// none told `Yielded`; asked and not had yet, the ask is given up. Nothing is told after it; again, nothing.
pub fn TabClaim::release(self : TabClaim) -> Unit {
  (self.let_go)()
}
