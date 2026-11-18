// The library's workspaces' list and a vendor's marks (workspace_row_node.mbt), each beside its states, what can be
// pressed answering as it does in the app.

///|
/// Their stories, after the others.
fn stories_u17() -> Array[Story] {
  [
    {
      key: "workspace-row",
      group: "列表",
      name: "工作区条目 WorkspaceRow",
      file: "workspace_row_node.mbt",
      api: [
        ("workspace_row_node.mbt", "workspace_row_node"),
        ("workspace_row_node.mbt", "workspace_card_node"),
        ("workspace_row_node.mbt", "workspace_label_node"),
        ("workspace_row_node.mbt", "workspace_mark_node"),
        ("workspace_row_node.mbt", "invitation_line_node"),
      ],
      play: None,
      about: "切换工作区的列表：当前工作区在卡片上、打勾；其他工作区一行一个，前面是它的标记（没有就用名字首字母），后面是它待处理的数；邀请一行一个，带加入和忽略：文案折成多行时按钮对齐第一行，窄到放不下时整组折到文案下面。卡片上的行与其他行的标记和文字落在同一条线上。",
      cases: [
        (
          "当前、其他与操作",
          fn(card) {
            let in_use = kept("Acme")
            let row = fn(parent : @view.View, name : String, emoji : String, sub : String) {
              @sf.workspace_row_node(
                parent,
                fn() { name },
                fn() { sub },
                fn() { in_use.set(name) },
                lead=fn(l) { @sf.workspace_mark_node(l, fn() { emoji }, fn() { "" }, fn() { name }) },
              )
            }
            @sf.workspace_label_node(card, fn() { "当前" })
            @sf.workspace_card_node(card, fn(c) {
              @sf.workspace_row_node(
                c,
                fn() { in_use.get() },
                fn() { "zuozijian@cue.surf" },
                fn() {  },
                checked=true,
                lead=fn(l) { @sf.workspace_mark_node(l, fn() { "" }, fn() { "" }, fn() { in_use.get() }) },
                on_card=true,
              )
            })
            @sf.workspace_label_node(card, fn() { "其他" })
            row(card, "Globex", "🚀", "")
            row(card, "Initech Research Lab", "", "admin@initech.example")
            @sf.workspace_row_node(card, fn() { "登录其他账号" }, fn() { "用另一个账号的工作区" }, icon="log-in", fn() {  })
            @sf.workspace_row_node(card, fn() { "新建 workspace" }, fn() { "" }, icon="plus", fn() {  })
          },
        ),
        (
          "邀请（加入时转圈）",
          fn(card) {
            let joining = kept(false)
            let answered = kept("")
            @sf.workspace_label_node(card, fn() { "邀请" })
            @sf.invitation_line_node(
              card,
              fn() { "左子健 邀请你加入 Acme" },
              fn() { "zuozijian@cue.surf" },
              fn() { joining.set(!joining.get()) },
              fn() { answered.set("已忽略") },
              joining=fn() { joining.get() },
              ignoring=fn() { false },
            )
            @sf.words_node(card, fn() { answered.get() }, fn() { story_fact_words }) |> ignore
          },
        ),
        (
          "邀请（文案多行：按钮对齐首行，放不下折到下面）",
          fn(card) {
            @sf.workspace_label_node(card, fn() { "邀请" })
            @sf.invitation_line_node(
              card,
              fn() { "左子健 邀请你加入 Initech Research Lab 的工作区，一起处理还没合并的修复和本周的发布计划" },
              fn() { "zuozijian@cue.surf" },
              fn() {  },
              fn() {  },
              joining=fn() { false },
              ignoring=fn() { false },
            )
          },
        ),
      ],
    },
    {
      key: "provider-mark",
      group: "标记",
      name: "供应商标记 ProviderMark",
      file: "workspace_row_node.mbt",
      api: [("workspace_row_node.mbt", "provider_mark_node"), ("workspace_row_node.mbt", "provider_badge_node")],
      play: None,
      about: "账号的供应商标记：随它的运行时、接入方式和自带标记变化重做；本机登录的卡片上，标记放在卡片左上角的中性底上，小块圆角与卡片圆角同心。",
      cases: [
        (
          "标记（按一下换供应商）",
          fn(card) {
            let at = kept(0)
            let all = [("claude", "subscription", ""), ("codex", "subscription", ""), ("claude", "api-provider", "kimi"), ("claude", "opencode-go", "")]
            side_by_side(card, fn(r) {
              for size in [16.0, 18.0, 24.0] {
                @sf.provider_mark_node(r, fn() { all[at.get() % all.length()] }, size)
              }
              @sf.button_node(r, fn() { "换一个" }, fn() { at.set(at.get() + 1) }) |> ignore
            })
          },
        ),
        (
          "卡片角上的标记",
          fn(card) {
            for rt in [("claude", "Claude Code"), ("codex", "Codex")] {
              // (a card of the ladder's, its words 24 in, as a machine's login offered is: new_profile.mbt's)
              card.box(fn(c) {
                @sf.style_node(c, fn() { story_offer_card })
                c.box(fn(h) {
                  @sf.style_node(h, fn() { story_offer_head })
                  @sf.provider_badge_node(h, rt.0, "subscription", 18.0)
                  @sf.words_node(h, fn() { rt.1 }, fn() { story_fact_words }) |> ignore
                })
                |> ignore
              })
              |> ignore
            }
          },
        ),
      ],
    },
  ]
}

///|
/// A card of the ladder's, its words card_pad in (a machine's login offered: new_profile.mbt's ap_offer).
// kept across runs: a value (no field of it changes)
let story_offer_card : @ui.Style = @ui.css("w=Full radius=Xl3 bg=Card").then(@ui.style(p=@sf.room_of(@sf.card_pad)))

///|
// kept across runs: a value (no field of it changes)
let story_offer_head : @ui.Style = @ui.css("row w=Full gap=S3 align=AStart")
