// A secret's page, one in every frame (设置 › 密钥 › it; web/src/cloud/VaultItem.tsx, Vault.css.ts; the narrow app's
// mobile/Vault.tsx VaultItemScreen), laid out by its width, as a profile's is: what it is and where it
// is kept; in a library not locked, that it is not encrypted and the way to lock it; its content masked until shown
// (each field's eye opens it, `vault.open`, and shows that field), copied; how agents may use it; when they did, each
// use leading to its chat. 编辑 opens it first, then its editor (the presenters'). What it says is the core's
// (vault-words.ts); what it held goes as its page is left (the settings package's opened item).

///|
/// The field whose eye opened the item, shown as it opens ("" none), by item: while it opens so, 编辑 and 说明 do not
/// turn.
// kept across runs: said by the fields' eyes; vault_item_reset empties it
let vi_reveal : @sf.LiveMap[String, String] = @sf.LiveMap::new()

///|
/// The fields shown in the clear, by item and field.
// kept across runs: said by the fields' eyes; vault_item_reset empties it
let vi_shown : @sf.LiveMap[String, Bool] = @sf.LiveMap::new()

///|
fn vault_item_reset() -> Unit {
  vi_reveal.clear()
  vi_shown.clear()
}

///|
/// A secret's page (VaultItemPage, VaultItemScreen) made once as nodes in node `v` (page_node, as vault_node is), item
/// `item` of vault `vault`, as the core's `vaults`, `vaultItems` and `vaultUses` say them now: its own head (its kind's
/// mark, its name, what it is and where it is kept; 说明 and 编辑 at its end, each opening it first, turning while it
/// opens so), then its blocks (vault_item_keys); while they are read, made-up ones in their bones.
pub fn vault_item_node(
  v : @view.View,
  core : Core,
  here : () -> Here,
  vault : String,
  item : String,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
  tips? : @sf.TipLayer,
) -> Unit {
  let ws = fn() { here().workspace }
  let view = fn() { (core.topic)("vaults", { "workspace": str(ws()) }).get().value }
  let list = fn() { (core.topic)("vaultItems", { "workspace": str(ws()), "vault": str(vault) }).get().value }
  let uses = fn() { (core.topic)("vaultUses", { "workspace": str(ws()), "vault": str(vault), "item": str(item) }).get().value }
  // (its vault as its page shows it: not how many items it keeps, which changes with each one added; worked out once for
  // each change of the library, read by all that shows it)
  let vault_now = @signals.computed(fn(_) {
    items(vault_shown(view()), "vaults").iter().find_first(fn(x) { text(Some(x), "id") == vault })
  })
  let vv = fn() { vault_now.get() }
  let plain_now = @signals.computed(fn(_) { flag(view(), "plain") })
  let rv = fn() { items(list(), "items").iter().find_first(fn(x) { text(Some(x), "id") == item }) }
  let plain = fn() { plain_now.get() }
  // (its blocks' keys, worked out once for each change of what it reads: what holds the page's list reads them alone)
  let keys = @signals.computed(fn(_) {
    if view() is None || list() is None {
      ["waiting"]
    } else if vv() is None || rv() is None {
      ["empty"]
    } else {
      vault_item_keys(rv(), plain())
    }
  })
  let open = fn(then : (Json) -> Unit) { @settings.open_item(core, @signals.untracked(ws), item, then) }
  // 编辑 and 说明: opened first (its content is what is edited; the rest of it is written as it was by 说明)
  let opened_then = fn(f : (Json, Json) -> Unit) {
    let r = @signals.untracked(rv)
    match (r, @settings.opened_plain(item)) {
      (Some(r), Some(p)) => f(r, p)
      (Some(r), None) => open(fn(p) { f(r, p) })
      _ => ()
    }
  }
  let edit = fn() { opened_then(fn(r, p) { vault_editor_dialog(core, @signals.untracked(ws), vault, Some((r, p)), plain=@signals.untracked(plain)) }) }
  let about = fn() { opened_then(fn(r, p) { vault_about_dialog(core, @signals.untracked(ws), vault, r, p) }) }
  let editing_busy = fn() { @settings.item_opening(item) && vi_reveal.get(item) is None }
  // (说明 beside 编辑, at its head's end: back's line where its head is under back; wide each with its words)
  let actions = fn(a : @view.View) {
    a.show(fn() { rv() is Some(_) }, fn(s) {
      @sf.head_actions_node(
        s,
        [("file-text", fn() { @sf.t("web-pages.vault.aboutEdit") }, about), ("edit", fn() { @sf.t("common.edit") }, edit)],
        busy=editing_busy,
      )
    })
  }
  let sub = fn() { join([text(rv(), "kindText"), @sf.t("web-pages.vault.storedOn", args=[("station", text(vv(), "stationName"))])], " · ") }
  @sf.page_node(
    v,
    fn() { if rv() is Some(_) { text(rv(), "name") } else { @sf.t("web-pages.vault.title") } },
    on_back~,
    frame~,
    said?,
    width?,
    tips?,
    actions~,
    head=fn(h) {
      @sf.own_head_node(
        h,
        fn(m, side) {
          m.pick(fn() { @settings.kind_icon(text(rv(), "kind")) }, fn(i, icon) {
            @sf.icon_node(i, icon, if side <= 32.0 { vi_mark_small } else { vi_mark_glyph }, By(fn() { @sf.theme().p.text })) |> ignore
          })
        },
        fn() { if rv() is Some(_) { text(rv(), "name") } else { @sf.t("web-pages.vault.title") } },
        renames=fn() { false },
        lines=fn() { if rv() is Some(_) { [sub()] } else { [] } },
        actions~,
      )
    },
    fn() { keys.get() },
    fn(b, key) {
      match key {
        "waiting" =>
          @sf.waiting_node(b, fn(s) {
            let sample = Some(item_sample())
            s.each(fn() { vault_item_keys(sample, false) }, fn(k) { k }, fn(sb, k) {
              item_block_node(sb, core.quiet(), ws, "sample", fn() { None }, fn() { sample }, fn() { Some({ "uses": Json::array(uses_sample()) }) }, open, k.untracked())
            })
          })
        "empty" => @sf.page_note_node(b, fn() { @sf.t("web-pages.vault.empty") })
        k => item_block_node(b, core, ws, item, vv, rv, uses, open, k)
      }
    },
  )
}

///|
/// What an item's page holds (`rv`, in a library not locked where `plain`), by its blocks' keys: a library not
/// locked said so ("risk"), what it is for where it says ("about"), its content ("content"), how agents may use it
/// ("use"), when they used it ("uses").
fn vault_item_keys(rv : Json?, plain : Bool) -> Array[String] {
  let out : Array[String] = []
  if plain {
    out.push("risk")
  }
  if text(rv, "about") != "" {
    out.push("about")
  }
  out + ["content", "use", "uses"]
}

///|
/// An item's block `key` (vault_item_keys') in `b`, item `item` (`rv`, in vault `vv`, its uses `uses`, each as it is
/// now); its content opened by `open`.
fn item_block_node(
  b : @view.View,
  core : Core,
  ws : () -> String,
  item : String,
  vv : () -> Json?,
  rv : () -> Json?,
  uses : () -> Json?,
  open : ((Json) -> Unit) -> Unit,
  key : String,
) -> Unit {
  // (a section under its title: narrow on a card of the page's, wide as it is, on the page's ground)
  let section = fn(title : String, body : (@view.View) -> Unit) {
    @sf.section_node(b, fn() { @sf.t(title) }, fn(s) { @sf.narrow_card_node(s, body) })
  }
  match key {
    // in a library not locked: that it is not encrypted, the way to lock it
    "risk" =>
      @sf.page_card_node(b, footed=true, fn(k) {
        @sf.words_node(k, fn() { @sf.t("web-pages.vault.risk.title") }, fn() { vi_risk_title }) |> ignore
        @sf.words_node(k, fn() { @sf.t("web-pages.vault.risk.body", args=[("station", text(vv(), "stationName"))]) }, fn() { desk_muted }) |> ignore
        @sf.card_foot_node(k, fn(f) {
          @sf.button_node(f, fn() { @sf.t("web-pages.vault.lib.turnOn") }, fn() { (core.push)(Security) }, tone=Primary, card_words=true) |> ignore
        })
      })
    // what it is for and how it is used (agents are shown it with its name; 说明 at the head writes it)
    "about" => section("web-pages.vault.editor.about", fn(k) { @sf.words_node(k, fn() { text(rv(), "about") }, fn() { vi_fact_value }) |> ignore })
    // its content: each field's eye where its value is, before it is opened as after
    "content" =>
      section("web-pages.vault.content", fn(k) {
        k.box(fn(fs) {
          @sf.style_node(fs, fn() { vi_fields })
          fs.pick(fn() { @settings.opened_plain(item) is Some(_) }, fn(p, is_open) {
            if is_open {
              // (by key once: each field's row reads its own field, told only as that one changes)
              let by_key = p.keyed_by(fn() { @settings.opened_fields(item) }, fn(f) { text(Some(f), "key") })
              p.each(fn() { by_key.keys() }, fn(k) { k }, fn(row, fk) {
                let fk = fk.untracked()
                let fv = fn() { by_key.get(fk) }
                secret_field_node(row, item + "/" + fk, fv)
              })
            } else {
              let by_key = p.keyed_by(fn() { items(rv(), "shut") }, fn(f) { text(Some(f), "key") })
              p.each(fn() { by_key.keys() }, fn(k) { k }, fn(row, fk) {
                let fk = fk.untracked()
                let fv = fn() { by_key.get(fk) }
                shut_field_node(row, item, fk, fv, open)
              })
            }
          })
        })
        |> ignore
      })
    // how agents may use it: what each is in a column of its terms, how it stands beside it on the same line
    "use" =>
      section("web-pages.vault.forAgents", fn(sec) {
        sec.pick(fn() { flag(rv(), "listed") }, fn(p, listed) {
          if !listed {
            @sf.words_node(p, fn() { @sf.t("web-pages.vault.notForAgents") }, fn() { desk_muted }) |> ignore
            return
          }
          p.box(fn(fs) {
            @sf.style_node(fs, fn() { vi_facts })
            // (its terms' column 96 wide, or as wide as the widest of them in this language at the system's size of
            // words: words of a length known, whole)
            let term_w = fn() {
              let (px, _) = @ui.tree_theme().text_size(Meta)
              let size = @sf.node_sp(fs, px)
              vi_terms.fold(init=vi_term_w, fn(m, w) { dmax(m, @ui.text_advance(@sf.t(w), size~).ceil()) })
            }
            let fact = fn(at : @view.View, term : String, value : (@view.View) -> Unit) {
              at.box(fn(r) {
                @sf.style_node(r, fn() { vi_fact })
                // (its term on the baseline of how it stands' first line: a Meta line beside a Ui one)
                r.lines_up_baseline(Is(true)) |> ignore
                r.box(fn(t) {
                  t.width(By(fn() { Some(term_w()) })).shrink(Is(0.0)) |> ignore
                  @sf.words_node(t, fn() { @sf.t(term) }, fn() { vi_term }) |> ignore
                })
                |> ignore
                // (how it stands, on as many lines as it takes in the room its term leaves it)
                r.box(fn(w) {
                  w.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
                  value(w)
                })
                |> ignore
              })
              |> ignore
            }
            fact(fs, "web-pages.vault.how", fn(r) { @sf.words_node(r, fn() { text(rv(), "howText") }, fn() { vi_fact_value }) |> ignore })
            fs.show(fn() { text(rv(), "env") != "" }, fn(e) {
              fact(e, "web-pages.vault.editor.env", fn(r) { @sf.mono_words_node(r, fn() { text(rv(), "env") }, vi_fact_value) })
            })
            fact(fs, "web-pages.vault.editor.lasts", fn(r) { @sf.words_node(r, fn() { text(rv(), "lastsText") }, fn() { vi_fact_value }) |> ignore })
          })
          |> ignore
        })
      })
    // when agents used it
    "uses" =>
      section("web-pages.vault.uses.title", fn(k) {
        k.pick(
          fn() {
            match uses() {
              None => 0
              Some(_) if items(uses(), "uses").length() == 0 => 1
              Some(_) => 2
            }
          },
          fn(p, what) {
            match what {
              0 => @sf.waiting_node(p, fn(w) { item_uses_node(w, core.quiet(), ws, fn() { uses_sample() }) })
              1 => @sf.words_node(p, fn() { @sf.t("web-pages.vault.uses.none") }, fn() { desk_muted }) |> ignore
              _ => item_uses_node(p, core, ws, fn() { items(uses(), "uses") })
            }
          },
        )
      })
    _ => ()
  }
}

///|
/// When agents used an item (`uses`, as they are now) in `b`, each: its chat (opening it), how, when (on its chat's
/// line, at its end).
fn item_uses_node(b : @view.View, core : Core, ws : () -> String, uses : () -> Array[Json]) -> Unit {
  @sf.record_rows_node(b, fn(l) {
    l.each(fn() { uses().mapi(fn(i, _) { i }) }, fn(i) { i }, fn(row, i) {
      let uv = fn() { uses().get(i.get()) }
      let chat = fn() {
        match opt_text(uv(), "chatTitle") {
          Some(x) if x != "" => x
          _ => text(uv(), "session")
        }
      }
      @sf.record_row_node(
        row,
        fn(n) {
          n.pick(fn() { text(uv(), "station") != "" }, fn(p, goes) {
            p.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
            if goes {
              // (its chat's words in the words' ink, underlined under the hand, cut short beside what follows them)
              p.box(fn(l) {
                l.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
                @sf.presses_node(l, fn() {
                  let u = @signals.untracked(uv)
                  (core.open_chat)(@signals.untracked(ws) + "/" + text(u, "station"), text(u, "session"), @signals.untracked(chat))
                })
                l.says(By(fn() { Some(@view.said(Link, label=chat())) })) |> ignore
                l.box(fn(w) {
                  // (cut short where their line has not the room: styled_words' View::cuts)
                  w
                  .shrink(Is(1.0))
                  .min_width(Is(Some(0.0)))
                  .cuts(Is(true))
                  .allow_ellipsis(Is(true))
                  .words_runs(By(fn() { [@ui.span(chat(), underline=@sf.lit_node(l))] }), look=@ui.style_words(vi_chat))
                  .ink(By(fn() { @ui.style_ink(vi_chat) }))
                  |> ignore
                })
                |> ignore
              })
              |> ignore
            } else {
              @sf.words_node(p, chat, fn() { vi_chat }).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
            }
          })
          n.show(fn() { flag(uv(), "denied") }, fn(d) { @sf.pill_node(d, fn() { @sf.t("web-pages.vault.uses.denied") }, tone=Red) |> ignore })
        },
        fn(t) { @sf.record_how_node(t, fn() { text(uv(), "howText") }, fn() { opt_text(uv(), "command") is Some(_) }) },
        fn() {
          match text(field(uv(), "at"), "full") {
            "" => text(field(uv(), "at"), "ago")
            x => x
          }
        },
      )
    })
  })
}

///|
/// An item made up, for what its page shows while it is read (item_blocks in its bones): two fields, how agents use
/// it, two uses.
fn item_sample() -> Json {
  let w = fn(n : Int) { Json::string(@sf.sample_words(n)) }
  {
    "listed": true,
    "howText": w(8),
    "lastsText": w(6),
    "shut": [{ "key": "a", "label": w(3), "value": w(12) }, { "key": "b", "label": w(4), "value": w(16) }],
  }
}

///|
fn uses_sample() -> Array[Json] {
  [10, 7].map(fn(n) {
    Json::object({
      "chatTitle": Json::string(@sf.sample_words(n)),
      "howText": Json::string(@sf.sample_words(14)),
      "at": { "full": Json::string(@sf.sample_words(5)) },
    })
  })
}

///|
/// A field of an item opened (Secret) in `row` (`fv`, as it is now; `key` its item's and its own): its name over its
/// value, masked until shown where it is secret (its eye), copied as it is (a secret's taken off the clipboard 30 s
/// later).
fn secret_field_node(row : @view.View, key : String, fv : () -> Json?) -> Unit {
  let secret = fn() { flag(fv(), "secret") }
  let shown = fn() { !secret() || vi_shown.get(key).unwrap_or(false) }
  @sf.secret_value_row_node(row, fn() { text(fv(), "label") }, fn() { text(fv(), "value") }, shown~, mono=fn() { flag(fv(), "mono") }, fn(l) {
    l.show(secret, fn(e) {
      @sf.secret_key_node(
        e,
        "eye",
        fn() { if shown() { @sf.t("web-pages.vault.hide") } else { @sf.t("web-pages.vault.show") } },
        fn() { vi_shown.set(key, !@signals.untracked(shown)) },
        icon_now=fn() { if shown() { "eye-off" } else { "eye" } },
      )
      |> ignore
    })
    @sf.secret_copy_node(l, fn() { text(fv(), "value") }, secret) |> ignore
  })
}

///|
/// A field of an item not opened yet (`fv`, as it is now) in `row`: its name over its value as the core masks it, its
/// eye (opening the item, `open`, this field then shown), a spinner in its place while it opens.
fn shut_field_node(row : @view.View, item : String, fk : String, fv : () -> Json?, open : ((Json) -> Unit) -> Unit) -> Unit {
  @sf.secret_value_row_node(row, fn() { text(fv(), "label") }, fn() { text(fv(), "value") }, mono=fn() { true }, one_line=true, fn(l) {
    l.pick(fn() { @settings.item_opening(item) }, fn(p, opening) {
      // (the spinner in the eye's room while it opens: the line no lower for it)
      p.width(Is(Some(@sf.secret_key_side))).height(Is(Some(@sf.secret_key_side))).lies_along(Is(Middle)).lines_up(Is(Some(Middle))) |> ignore
      if opening {
        @sf.spinner_node(p, size=pf_spin) |> ignore
      } else {
        @sf.secret_key_node(p, "eye", fn() { @sf.t("web-pages.vault.show") }, fn() {
          vi_reveal.set(item, fk)
          vi_shown.set(item + "/" + fk, true)
          open(fn(_) { vi_reveal.remove(item) })
        })
        |> ignore
      }
    })
  })
}

// ── styles ───────────────────────────────────────────────

///|
let vi_mark_glyph : Double = 24.0

///|
/// Its kind's mark where its head's mark is small (own_head's 32 tile, wide).
let vi_mark_small : Double = 18.0

///|
// kept across runs: a value (no field of it changes)
let vi_risk_title : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, weight=Semibold, color=WarnInk, w=Full)

///|
/// Its fields (fields: 14 apart; a field its name over its line, 4 apart).
// kept across runs: a value (no field of it changes)
let vi_fields : @ui.Style = @ui.css("w=Full gap=S3_5").then(@sf.card_foot_out)

///|
// kept across runs: a value (no field of it changes)
let vi_facts : @ui.Style = @ui.css("w=Full gap=S1")

///|
// kept across runs: a value (no field of it changes)
// (its term and how it stands on one baseline: View::lines_up_baseline, where it is made)
let vi_fact : @ui.Style = @ui.css("row w=Full gap=S3_5")

///|
/// Its terms' column at least (the web's 96).
let vi_term_w : Double = 96.0

///|
/// The terms of how agents may use it, whose widest sets its column.
// kept across runs: a value (no field of it changes)
let vi_terms : Array[String] = ["web-pages.vault.how", "web-pages.vault.editor.env", "web-pages.vault.editor.lasts"]

///|
// kept across runs: a value (no field of it changes)
let vi_term : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let vi_fact_value : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, color=Fg, w=@sf.grow)

///|
// kept across runs: a value (no field of it changes)
let vi_chat : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, color=Fg, wrap=false, w=Cut)


