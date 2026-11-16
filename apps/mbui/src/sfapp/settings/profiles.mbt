// Profiles, the model accounts the agents run on: what is left here of their old views, a kind of account's mark (its
// list and pages are made once as nodes: sfpages' profiles_list.mbt, accounts.mbt).

///|
/// Whether the narrow `Profiles` page shows the overview tab (`true`) or the default accounts list (`false`).
pub let profiles_narrow_overview : @signals.Signal[Bool] = @signals.signal(false, same=fn(a, b) { a == b })

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

