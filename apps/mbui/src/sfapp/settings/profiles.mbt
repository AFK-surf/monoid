// Profiles, the model accounts the agents run on: what is left here of their old views, a kind of account's mark (its
// list and pages are made once as nodes: sfpages' profiles_list.mbt, accounts.mbt).

///|
/// Whether the bottom bar's `Place("profiles")` shows 概览 (`true`) or the accounts' list (`false`): its own, so a
/// `Setting(Profiles(""))` pushed and popped over it never changes what it shows.
pub let profiles_place_overview : @signals.Signal[Bool] = @signals.signal(false, same=fn(a, b) { a == b })

///|
/// Whether a pushed `Setting(Profiles(""))` (and 中屏's and 大屏's) shows 概览 (`true`) or the accounts' list (`false`).
pub let profiles_narrow_overview : @signals.Signal[Bool] = @signals.signal(false, same=fn(a, b) { a == b })

///|
/// How 概览 is switched to from the accounts' list, of workspace `ws` (`go` switches it): as the settings' core of the
/// source in use says it (sfbase's settings_core_of), once the overview's pools are answered, the list shown meanwhile
/// (switch_answered); at once where none said it.
// kept across runs: what the source in use says of it
pub let overview_switch : Ref[(String, () -> Unit) -> Unit] = Ref(fn(_, go) { go() })

///|
/// A kind of account's mark, before its section's title, and before an account's row of 全部密钥:
/// its vendor's for a subscription, a key for keys.
pub fn group_mark(c : @ui.Ctx, group : String) -> Unit {
  match group {
    "key" => @sf.icon(c, "key", size=16.0, color=@sf.theme().p.text) |> ignore
    // signed in to an account: its provider's
    "kimi" => @sf.provider_logo(c, "claude", "api-provider", 16.0, "kimi")
    "opencode" => @sf.provider_logo(c, "claude", "opencode-go", 16.0, "")
    // a subscription: its vendor's, by the runtime it is (ChatGPT's Codex; SuperGrok's xAI, Cursor's, Devin's)
    "chatgpt" => @sf.provider_logo(c, "codex", "subscription", 16.0, "")
    "" => @sf.provider_logo(c, "claude", "subscription", 16.0, "")
    g => @sf.provider_logo(c, g, "subscription", 16.0, "")
  }
}

