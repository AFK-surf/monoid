// What the last update brought and what the update wants of the person (changelog.mbt's) as nodes of the window's
// tree, made once at the top of a chats' list: the cards the old frame drew there, laid out as it laid them out, what
// they say bound to the core's `changelog` topic and the update's state as they change.

///|
/// The news card in `parent`, while there is news: the build it is now and its first changes, a
/// press opens the changelog; its × (its tip in `tips`) lets it go at once and tells the core.
pub fn changelog_news_node(parent : @view.View, src : Source, tips : @sf.TipLayer) -> Unit {
  let news = fn() { news_of(src) }
  let lines = fn() {
    let out : Array[String] = []
    for e in items(news(), "entries") {
      for l in items(Some(e), "text") {
        match l {
          String(s) => out.push(s)
          _ => ()
        }
      }
    }
    out
  }
  // PageParts.kt ChangelogNews: clickable, cut to the card's corners, read out as the old frame's box was (all it says)
  @sf.news_card_node(
    parent,
    "sparks",
    fn() { news_title_now(news()) },
    fn() {
      let said = [news_title_now(news())]
      said.append(lines()[:@cmp.minimum(news_lines_most, lines().length())].to_owned())
      if lines().length() > news_lines_most {
        said.push(@sf.t("android-settings.changelog.more", args=[("n", (lines().length() - news_lines_most).to_string())]))
      }
      said.join(" ")
    },
    fn() { open_page(Setting(@settings.Route::Changelog)) },
    fn(words) {
      for i in 0..<news_lines_most {
        words.show(fn() { i < lines().length() }, fn(l) {
          @sf.words_node(l, fn() { lines().get(i).unwrap_or("") }, fn() { @sf.news_card_line }) |> ignore
        })
      }
      words.show(fn() { lines().length() > news_lines_most }, fn(l) {
        @sf.words_node(
          l,
          fn() { @sf.t("android-settings.changelog.more", args=[("n", (lines().length() - news_lines_most).to_string())]) },
          fn() { @sf.news_card_line },
        )
        |> ignore
      })
    },
    // let go: gone at once, the core told
    close=(tips, fn() { @sf.t("android-settings.changelog.dismiss") }, fn() {
      news_gone.set(@signals.untracked(news))
      (src.call)("changelog.seen", Json::object({}), @sfbase.answer_unread)
    }),
  )
  |> ignore
}

///|
/// The news's title: the build it brought, where it says one.
fn news_title_now(news : Json?) -> String {
  match @sfbase.opt_text(news, "build") {
    Some(b) => @sf.t("android-settings.changelog.updatedTo", args=[("build", b)])
    None => @sf.t("android-settings.changelog.updated")
  }
}

///|
/// The update's card in `parent`: 允许安装更新 and why; a press does it (@sfbase.update_go). No ×: it
/// goes once given (what holds it shows it while update_card_shown).
pub fn update_card_node(parent : @view.View, src : Source) -> Unit {
  @sf.news_card_node(
    parent,
    "download",
    fn() { @sf.t("android-misc.updates.allow") },
    fn() { @sf.t("android-misc.updates.allow") },
    fn() { @sfbase.update_go(src) },
    fn(words) {
      @sf.words_node(words, fn() { @sf.t("android-misc.updates.allowWhy", args=[("app", "still.fail")]) }, fn() {
        @sf.news_card_note
      })
      |> ignore
    },
  )
  |> ignore
}

///|
/// The over-7-day upgrade prompt card in `parent` (Small, Medium, and Large): first-line aligned icon and title,
/// platform-specific message (Desktop/Android feed, iOS TestFlight, Web refresh, or download fallback), optional
/// download progress bar while fetching, and a primary action button in the card's concentric foot corner.
pub fn stale_build_card_node(parent : @view.View, src : Source) -> Unit {
  let icon = fn() { if @sfbase.stale_build_kind() == "web" { "refresh" } else { "download" } }
  let body_text = fn() {
    match @sfbase.stale_build_kind() {
      "web" => @sf.t("web-main.staleBuild.web")
      "ios" => @sf.t("web-main.staleBuild.ios")
      "feed" =>
        match @sfbase.update_now() {
          Ready(_, ..) => @sf.t("web-main.staleBuild.ready")
          Allow(_) => @sf.t("web-main.staleBuild.allow")
          Coming(_, _) | Installing(_) => @sf.t("web-main.staleBuild.coming")
          _ => @sf.t("web-main.staleBuild.body")
        }
      _ => @sf.t("web-main.staleBuild.downloadBody")
    }
  }
  let button_label = fn() {
    match @sfbase.stale_build_kind() {
      "web" => @sf.t("web-main.staleBuild.reloadPage")
      "ios" => @sf.t("web-main.staleBuild.openTestFlight")
      "feed" =>
        match @sfbase.update_now() {
          Ready(_, ..) => @sf.t("desktop.update.restart")
          Allow(_) => @sf.t("android-misc.updates.allow")
          Coming(_, _) | Installing(_) => @sf.t("web-main.staleBuild.viewProgress")
          _ => @sf.t("web-main.staleBuild.updateNow")
        }
      _ => @sf.t("web-main.staleBuild.download")
    }
  }
  let progress_part = fn() -> Double? {
    match @sfbase.update_now() {
      Coming(_, part) => part
      _ => None
    }
  }
  parent.box(fn(room) {
    @sf.style_node(room, fn() { stale_build_card_room.then(@ui.style(px=@sf.room_of(@sf.theme().chat_list.band_in))) })
    @sf.ask_card_node(room, fn(card) {
      card.box(fn(head) {
        @sf.style_node(head, fn() { stale_build_head })
        @sf.first_line_node(head, Ui, leading=L5, fn(i) {
          i.pick(icon, fn(ic, name) { @sf.icon_node(ic, name, 16.0, By(fn() { @sf.theme().p.accent })) |> ignore })
        })
        |> ignore
        head.box(fn(words) {
          @sf.style_node(words, fn() { stale_build_words }, in_row=true)
          words.min_width(Is(Some(0.0))) |> ignore
          words.box(fn(t) {
            t
            .words_runs(By(fn() { [@ui.span(@sf.t("web-main.staleBuild.title"), weight=600, color=@sf.theme().p.text)] }))
            .words_look(By(fn() { @ui.style_words(@sf.ask_title) }))
            .ink(By(fn() { @ui.style_ink(@sf.ask_title) }))
            |> ignore
          })
          |> ignore
          @sf.words_node(words, body_text, fn() { @sf.ask_note }) |> ignore
        })
        |> ignore
      })
      |> ignore
      card.show(fn() { @sfbase.update_now() is (Coming(_, _) | Installing(_)) }, fn(p) {
        @sf.progress_node(p, progress_part, fn() { @ui.tree_theme().line }, fn() { @sf.theme().p.accent }) |> ignore
      })
      @sf.ask_buttons_node(card, fn(f) {
        @sf.button_node(
          f,
          button_label,
          fn() { @sfbase.stale_build_action(src) },
          tone=Primary,
          busy=fn() { @sfbase.stale_build_kind() == "feed" && @sfbase.update.checking.get() },
        )
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// Room around the over-7-day upgrade card in the chat list: matches `news_card_room`.
// kept across runs: a value (no field of it changes)
let stale_build_card_room : @ui.Style = @ui.css("w=Full pt=S1 pb=S2_5")

///|
/// First-line aligned icon beside the wrapping title and note.
// kept across runs: a value (no field of it changes)
let stale_build_head : @ui.Style = @ui.css("row w=Full gap=S1_5 align=AStart")

///|
/// Title and body column beside the icon, taking the remaining width of the card.
// kept across runs: a value (no field of it changes)
let stale_build_words : @ui.Style = @ui.css("gap=S1").then(@ui.style(w=@sf.grow))
