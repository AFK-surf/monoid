// 密钥, one page in every frame and the same on every width (the user, 2026-10-26: 「这个页面需要整体重新设计，现在乱得
// 一批」: its state a card of its own, the longest approval a heading, a paragraph and three cards of their own, each on
// an edge of its own, what it keeps under the fold), and 全部密钥 under it. What has to come first (security mode, this
// device signing, this device set up, the recovery words written down): a card alone on either, with the way on. Set
// up, 密钥 is what waits on the viewer and how the library stands, not what it keeps (「密钥管理不需要入口做这么浅，因为
// 平时不会手动操作，顶多就是类似 1p，进去看一眼复制一下」): the requests waiting on the viewer first (each one's card, as
// in its chat); a vault waiting to be keyed anew, a card under its name (vault_waits); a row to 全部密钥; how its
// secrets are kept, a row each on one list card, each what it is with how it stands under it (encrypted or not, and
// unlocked here a while; those still in plain text from before; the longest an approval lasts, picked through the
// presenters; the devices holding its key); deleting the vault in red at its foot,
// asked first; the stations that refused it. 全部密钥 is what it keeps, a section a kind (the profiles' accounts as the
// profiles list them, then each vault's secrets), each a row to its page, and 添加 at its head. Made of the library's
// page parts (@sf.section, group, link_row, page_card), laid out by the page's width. Adding, a
// secret's editor and the recovery words typed are the presenters' (vault_dialogs.mbt). Both are made once as nodes of
// the window's tree (vault_node, vault_items_node), their requests their chats' cards (the settings'
// vault_request_node).

///|
/// 密钥 (VaultSettings, VaultScreen) made once as nodes in node `v` (page_node, as vault_items_node is): as the core's
/// `vaults` says where the viewer stands, what has to come first (vault_first_keys), else the library (its blocks by
/// their keys: vault_library_keys), each block bound to what it shows.
pub fn vault_node(
  v : @view.View,
  core : Core,
  here : () -> Here,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
  tips? : @sf.TipLayer,
) -> Unit {
  let ws = fn() { here().workspace }
  let view = fn() { (core.topic)("vaults", { "workspace": str(ws()) }).get() }
  // (what the library's blocks show of it: each vault but how many items it keeps, which changes with every one added
  // and none of them shows; worked out once for each change of it, read by all that shows it)
  let shown = @signals.computed(fn(_) { vault_shown(view().value) })
  // (its blocks' keys, worked out once for each change of what it reads: what holds the page's list reads them alone)
  let keys = @signals.computed(fn(_) {
    match vault_first_keys(ws(), view().value) {
      Some(keys) => keys
      None => vault_library_keys(shown.get())
    }
  })
  // (its vaults kept by id once, as the library shows them and as the core says them: a block reads its own vault
  // by its key, told only as that one changes: View::keyed_by)
  let vaults_by = v.keyed_by(fn() { items(shown.get(), "vaults") }, vault_id)
  let named_by = vault_named_by(v, view)
  @sf.page_node(
    v,
    fn() { @sf.t("web-pages.vault.title") },
    on_back~,
    frame~,
    said?,
    width?,
    tips?,
    lead=fn() { @sf.t("web-pages.vault.lead") },
    fn() { keys.get() },
    fn(b, key) {
      if vault_first_node(b, core, here, view, named_by, key, fn(s, quiet, sample) {
          let sample_by = s.keyed_by(fn() { items(sample, "vaults") }, vault_id)
          s.each(fn() { vault_library_keys(sample) }, fn(k) { k }, fn(sb, k) {
            vault_library_block(sb, quiet, here, fn() { sample }, sample_by, k.untracked())
          })
        }) {
        return
      }
      vault_library_block(b, core, here, fn() { shown.get() }, vaults_by, key)
    },
  )
}

///|
/// The core's `vaults` as 密钥's library shows it (`v`): each vault without how many items it keeps (asked of the core
/// again as 删除此库 is pressed: vault_delete_ask's).
fn vault_shown(v : Json?) -> Json? {
  match v {
    Some(Object(m)) => {
      let out = Map::from_iter(m.iter())
      match m.get("vaults") {
        Some(Array(a)) =>
          out["vaults"] = Json::array(
            a.map(fn(x) {
              match x {
                Object(r) => {
                  let r2 = Map::from_iter(r.iter())
                  r2.remove("items")
                  Json::object(r2)
                }
                other => other
              }
            }),
          )
        _ => ()
      }
      Some(Json::object(out))
    }
    other => other
  }
}

///|
/// Whether a vault row is a shared workspace vault.
fn vault_is_workspace(rv : Json?) -> Bool {
  text(rv, "scope") == "workspace"
}

///|
/// Whether the viewer can manage a vault (its owner or a workspace admin on a workspace vault).
fn vault_can_manage(rv : Json?) -> Bool {
  flag(rv, "manages") || flag(rv, "mine")
}

///|
/// Member subs of a vault row (`VaultRow.members` is `Array[{ sub, name }]` in core-ts; also accepts plain strings).
fn vault_member_subs(rv : Json?) -> Array[String] {
  items(rv, "members").filter_map(fn(x) {
    match x {
      String(s) if s != "" => Some(s)
      Object(_) => {
        let s = text(Some(x), "sub")
        if s != "" { Some(s) } else { None }
      }
      _ => None
    }
  })
}

///|
/// The library's blocks (Library) by their keys, as the core's `vaults` (`v`) says it: the requests waiting on the
/// viewer ("requests", each one's card, as in its chat); none yet, a card to make one ("none"); a vault this device has
/// no key to ("no-key/<vault>"), one waiting to be keyed anew ("waits/<vault>"), each a section under its name; a row
/// to 全部密钥 on a card of its own ("all"); a workspace vault creation card ("workspace-create") or workspace vault
/// section ("workspace-vault/<vault>"); how personal secrets are kept, on another ("kept"); deleting manageable vaults
/// in red ("delete"); the stations that refused it ("refused/<n>").
fn vault_library_keys(v : Json?) -> Array[String] {
  let plain = flag(v, "plain")
  let vaults = items(v, "vaults")
  let out : Array[String] = []
  if items(v, "requests").length() > 0 {
    out.push("requests")
  }
  if !plain && vaults.length() == 0 {
    out.push("none")
  }
  // this device holding no key to one of them: how to get one
  for row in vaults {
    if !plain && !flag(Some(row), "keyed") {
      out.push("no-key/" + text(Some(row), "id"))
    }
  }
  // one waiting to be keyed anew: on which station, and that it is read meanwhile, not changed
  for row in vaults {
    if text(Some(row), "waits") != "" {
      out.push("waits/" + text(Some(row), "id"))
    }
  }
  // what it keeps (the profiles' accounts, the vaults' secrets), a page of its own on a card of its own; then workspace
  // vault creation or settings; then how personal secrets are kept, on another
  out.push("all")
  if !plain && flag(v, "canCreateWorkspace") {
    out.push("workspace-create")
  }
  for row in vaults {
    if !plain && vault_is_workspace(Some(row)) {
      out.push("workspace-vault/" + text(Some(row), "id"))
    }
  }
  out.push("kept")
  // deleting a manageable vault, in red at the page's foot, asked first (what goes with it said)
  if !plain && vaults.iter().any(fn(x) { vault_can_manage(Some(x)) }) {
    out.push("delete")
  }
  // the stations that refused the library: not in security mode, or too old for it
  for i, _ in items(v, "refused") {
    out.push("refused/" + i.to_string())
  }
  out
}

///|
/// The library's block `key` (vault_library_keys') in `b`, as `v` (the core's `vaults`) says it now.
fn vault_library_block(
  b : @view.View,
  core : Core,
  here : () -> Here,
  v : () -> Json?,
  vaults : @signals.KeyedList[String, Json],
  key : String,
) -> Unit {
  let ws = fn() { here().workspace }
  let vault_of = fn(id : String) { fn() { vaults.get(id) } }
  match key {
    "requests" => {
      let requests = fn() { items(v(), "requests") }
      // (how many beside its title: sec_section's, 待批准 · 1 narrow, the accent's count beside it wide)
      @sf.count_section_node(b, fn() { @sf.t("web-pages.vault.requests") }, fn() { requests().length() }, fn(s) {
        s.box(fn(l) {
          @sf.style_node(l, fn() { vt_requests })
          // (by id once: each card reads its own request, told only as that one changes)
          let by_id = l.keyed_by(requests, fn(r) { text(Some(r), "id") })
          l.each(fn() { by_id.keys() }, fn(id) { id }, fn(card, id) {
            let id = id.untracked()
            let row = fn() { by_id.get(id) }
            vault_request_node(card, core, ws, row)
          })
        })
        |> ignore
      })
    }
    "none" =>
      @sf.page_card_node(b, footed=true, fn(k) {
        @sf.card_lines_node(k, fn() { @sf.t("web-pages.vault.none") })
        @sf.card_foot_node(k, fn(f) {
          @sf.button_node(
            f,
            fn() { @sf.t("web-pages.vault.setUp") },
            fn() {
              @settings.act(core, @sf.t("web-pages.vault.createWhat"), "vault.create", obj([("workspace", str(@signals.untracked(ws))), ("name", str(@sf.t("web-pages.vault.personal")))]))
            },
            tone=Primary,
            busy=fn() { is_doing(core, ["vault.create"], [("workspace", ws())]) },
            card_words=true,
          )
          |> ignore
        })
      })
    "all" =>
      // what it keeps (the profiles' accounts, the vaults' secrets), a page of its own
      @sf.group_node(b, fn(g) { @sf.link_row_node(g, fn() { @sf.t("web-pages.vault.all") }, fn() { (core.push)(VaultItems) }) })
    "workspace-create" =>
      @sf.page_card_node(b, footed=true, fn(k) {
        @sf.card_lines_node(
          k,
          fn() { @sf.t("web-pages.vault.workspaceVault") },
          note=fn() { @sf.t("web-pages.vault.workspaceCreateNote") },
        )
        @sf.card_foot_node(k, fn(f) {
          @sf.button_node(
            f,
            fn() { @sf.t("web-pages.vault.workspaceCreate") },
            fn() {
              @settings.act(
                core,
                @sf.t("web-pages.vault.workspaceCreateWhat"),
                "vault.create",
                obj([
                  ("workspace", str(@signals.untracked(ws))),
                  ("name", str(@sf.t("web-pages.vault.workspaceVault"))),
                  ("scope", str("workspace")),
                ]),
                done=@sf.t("web-pages.vault.workspaceCreated"),
              )
            },
            tone=Primary,
            busy=fn() { is_doing(core, ["vault.create"], [("workspace", ws())]) },
            card_words=true,
          )
          |> ignore
        })
      })
    "kept" => vault_kept_node(b, core, here, v)
    "delete" =>
      @sf.group_node(b, fn(g) {
        let manageable = fn() { items(v(), "vaults").filter(fn(x) { vault_can_manage(Some(x)) }) }
        g.each(fn() { manageable().map(fn(r) { text(Some(r), "id") }) }, fn(id) { id }, fn(row, id) {
          vault_delete_row_node(row, core, ws, vault_of(id.untracked()), fn() { manageable().length() > 1 })
        })
      })
    k if k.has_prefix("workspace-vault/") => vault_workspace_node(b, core, here, vault_of(k.exact_view(start=16).to_owned()))
    k if k.has_prefix("no-key/") => vault_no_key_node(b, core, ws, vault_of(k.exact_view(start=7).to_owned()))
    k if k.has_prefix("waits/") => vault_waits_node(b, vault_of(k.exact_view(start=6).to_owned()))
    k if k.has_prefix("refused/") => {
      let at = k.exact_view(start=8).to_owned()
      @sf.page_note_node(b, fn() {
        let rv = items(v(), "refused").mapi(fn(i, r) { (i.to_string(), r) }).iter().find_first(fn(x) { x.0 == at }).map(fn(x) { x.1 })
        let name = match text(rv, "name") {
          "" => text(rv, "station")
          n => n
        }
        @sf.t(if text(rv, "code") == "vault_needs_lock" { "android-settings.vault.refusedLock" } else { "android-settings.vault.refusedOld" }, args=[
          ("name", name),
        ])
      })
    }
    _ => ()
  }
}

///|
/// A shared workspace vault section under its name: shared members row (opens member management dialog),
/// authorized devices row, and default longest approval row (when the viewer can manage the vault).
fn vault_workspace_node(b : @view.View, core : Core, here : () -> Here, rv : () -> Json?) -> Unit {
  let ws = fn() { here().workspace }
  @sf.section_node(b, fn() { text(rv(), "name") }, fn(s) {
    @sf.group_node(s, fn(g) {
      @sf.link_row_node(
        g,
        fn() { @sf.t("web-pages.vault.members.title") },
        fn() { vault_members_dialog(core, @signals.untracked(here), @signals.untracked(rv)) },
        note=fn() {
          let n = vault_member_subs(rv()).length()
          @sf.t("web-pages.vault.members.count", args=[("n", n.to_string())])
        },
      )
      vault_devices_row_node(g, core, here, rv, fn() { false })
      g.show(fn() { vault_can_manage(rv()) }, fn(l) {
        vault_lasts_row_node(l, core, ws, rv)
      })
    })
  })
}

///|
/// What a request waiting on the viewer asks (vault_request's Asked), from its row in the core's `vaults`.
fn vault_request_asked(rv : Json?) -> Asked {
  let save = field(rv, "save")
  {
    name: match opt_text(rv, "itemName") {
      Some(n) => n
      None => text(rv, "item")
    },
    reason: text(rv, "reason"),
    timeout_kind: text(rv, "timeoutKind"),
    timeout_seconds: count(rv, "timeoutSeconds"),
    approved_timeout_kind: "",
    approved_timeout_seconds: 0,
    mode: text(rv, "mode"),
    command: text(rv, "command"),
    how_text: text(rv, "howText"),
    save_kind: text(save, "kind"),
    save_vault_name: text(save, "vaultName"),
    save_shared: flag(save, "shared"),
    save_targets: [],
    username: text(save, "username"),
    filename: text(save, "filename"),
    typed: flag(save, "typed"),
    oauth: text(save, "oauth"),
    station: "",
    describe: field(rv, "describe") is Some(_),
    new_name: text(field(rv, "describe"), "name"),
    new_about: text(field(rv, "describe"), "about"),
    was_about: text(field(rv, "describe"), "wasAbout"),
    remove: flag(rv, "remove"),
    browse: field(rv, "browse") is Some(_),
    browse_hint: text(field(rv, "browse"), "workspace"),
    browse_workspaces: {
      let n = count(rv, "browseWorkspaces")
      if n > 0 { n } else { count(field(rv, "browse"), "workspaces") }
    },
    browse_items: {
      let n = count(rv, "browseItems")
      if n > 0 { n } else { count(field(rv, "browse"), "items") }
    },
    cross_workspace: text(field(rv, "cross"), "workspace"),
    cross_workspace_name: text(field(rv, "cross"), "workspaceName"),
    cross_vault_name: text(field(rv, "cross"), "vaultName"),
  }
}

///|
/// A request waiting on the viewer (`row`, as the core lists it now) in `card`: its card, as in its chat (the settings'
/// vault_request_node), and a way to its chat after its buttons where it has one.
fn vault_request_node(card : @view.View, core : Core, ws : () -> String, row : () -> Json?) -> Unit {
  let asked = @signals.computed(fn(_) { vault_request_asked(row()) })
  @settings.vault_request_node(card, core, ws, fn() { text(row(), "id") }, fn() { asked.get() }, extra=fn(f) {
    f.show(fn() { text(row(), "station") != "" }, fn(s) {
      @sf.button_node(
        s,
        fn() { @sf.t("web-pages.vault.openChat") },
        fn() {
          let rv = @signals.untracked(row)
          (core.open_chat)(@signals.untracked(ws) + "/" + text(rv, "station"), text(rv, "session"), "")
        },
        tone=Ghost,
      )
      |> ignore
    })
  })
}

///|
/// How the library keeps its secrets (vault_kept's), a row each on one list card in `b`, as `v`
/// says it now: encrypted,
/// or in plain text on the station (the way to security mode at its end), unlocked here a while (locked again at once
/// from its end); those still in plain text from before (encrypted from its end); the longest an approval of the
/// viewer's secrets lasts where a secret says none (its choices, each with what it means, through the presenters); the
/// devices holding each vault's key (given to new ones from its end). A row that does something does it pressed,
/// saying what at its end (vault_do_row_node); what is not as it should be said in amber.
fn vault_kept_node(b : @view.View, core : Core, here : () -> Here, v : () -> Json?) -> Unit {
  let ws = fn() { here().workspace }
  let plain = fn() { flag(v(), "plain") }
  let vaults = fn() { items(v(), "vaults") }
  // (which of its rows show, as `v` says now: plain; or sealed, opened, those left in plain text)
  let how = fn() {
    if plain() {
      0
    } else if vaults().iter().any(fn(x) { flag(Some(x), "open") }) {
      1
    } else {
      2
    }
  }
  @sf.group_node(b, fn(g) {
    g.pick(how, fn(p, h) {
      match h {
        0 =>
          vault_do_row_node(p, fn() { @sf.t("web-pages.vault.lib.plain") }, fn() { @sf.t("web-pages.vault.lib.plainWhy") }, fn() {
            @sf.t("web-pages.vault.lib.turnOn")
          }, fn() { false }, lacks=true, fn() { (core.push)(Security) })
        1 =>
          vault_do_row_node(p, fn() { @sf.t("web-pages.vault.lib.sealed") }, fn() { @sf.t("web-pages.vault.opened") }, fn() {
            @sf.t("web-pages.vault.lockNow")
          }, fn() { is_doing(core, ["vault.lock"], [("workspace", ws())]) }, fn() {
            vault_act(core, @signals.untracked(ws), "lock", [], @sf.t("web-pages.vault.lockNow"))
          })
        _ =>
          @sf.link_row_node(p, fn() { @sf.t("web-pages.vault.lib.sealed") }, fn() {  }, note=fn() { @sf.t("web-pages.vault.lib.sealedWhy") }, goes=false)
      }
    })
    g.show(fn() { !plain() && number(v(), "plainLeft").to_int() > 0 }, fn(m) {
      vault_do_row_node(
        m,
        fn() { @sf.t("web-pages.vault.migrate.title", args=[("n", number(v(), "plainLeft").to_int().to_string())]) },
        fn() { @sf.t("android-settings.vault.migrate.body") },
        fn() { @sf.t("web-pages.vault.migrate.go") },
        fn() { is_doing(core, ["vault.migrate"], [("workspace", ws())]) },
        lacks=true,
        fn() {
          @settings.act(core, @sf.t("web-pages.vault.migrate.what"), "vault.migrate", obj([("workspace", str(@signals.untracked(ws)))]), done=@sf.t(
            "android-settings.vault.migrate.done",
          ))
        },
      )
    })
    let personal = fn() { vaults().filter(fn(x) { !vault_is_workspace(Some(x)) }) }
    let mine = fn() { personal().iter().find_first(fn(r) { flag(Some(r), "mine") }) }
    g.show(fn() { mine() is Some(_) }, fn(l) { vault_lasts_row_node(l, core, ws, mine) })
    // (by id once: each device's row reads its own vault, told only as that one changes)
    let by_id = g.keyed_by(personal, fn(r) { text(Some(r), "id") })
    g.each(fn() { if plain() { [] } else { by_id.keys() } }, fn(id) { id }, fn(row, id) {
      let id = id.untracked()
      vault_devices_row_node(row, core, here, fn() { by_id.get(id) }, fn() {
        personal().length() > 1
      })
    })
  })
}

///|
/// A row that does one thing (vault_do_row's, as a node) in `g`: its `title`, how it stands under it (`note`, in amber
/// where it `lacks`), what it does in the link's ink at its end (`action`), turning while it is done (`busy`: not done
/// again then); pressed anywhere, `press`.
fn vault_do_row_node(
  g : @view.View,
  title : () -> String,
  note : () -> String,
  action : () -> String,
  busy : () -> Bool,
  lacks? : Bool = false,
  press : () -> Unit,
) -> Unit {
  @sf.link_row_node(
    g,
    title,
    fn() { if !busy() { press() } },
    note~,
    lacks~,
    value=action,
    value_lit=true,
    chevron=false,
    tail=fn(t) { t.show(busy, fn(s) { @sf.spinner_node(s, size=doing_mark_inline) |> ignore }) },
  )
}

///|
/// The longest a grant of the viewer's secrets lasts where a secret says none (Lasts, DefaultLasts), their own vault
/// `mine` as it is now, in `g`: the one now under it; pressed, the library's choices beside it, each with what it means.
fn vault_lasts_row_node(g : @view.View, core : Core, ws : () -> String, mine : () -> Json?) -> Unit {
  let id = fn() { text(mine(), "id") }
  let now = fn() {
    match vault_scopes.search(text(mine(), "lasts")) {
      Some(_) => text(mine(), "lasts")
      None => "chat"
    }
  }
  let on = fn() { [("workspace", ws()), ("vault", id())] }
  @sf.link_row_opens_node(
    g,
    fn() { @sf.t("web-pages.vault.lasts.title") },
    fn(row) {
      let (was, vault) = @signals.untracked(fn() { (now(), id()) })
      @sf.pick(
        @sf.t("web-pages.vault.lasts.title"),
        vault_scopes.map(fn(s) { @sf.choice(s, @sf.t("web-pages.vault.lasts." + s), note=@sf.t("web-pages.vault.lasts." + s + "Detail")) }),
        was,
        fn(picked) {
          if picked != was {
            vault_act(core, @signals.untracked(ws), "setLasts", [("vault", str(vault)), ("lasts", str(picked))], @sf.t("web-pages.vault.lasts.what"))
          }
        },
        from=Node(row),
      )
    },
    note=fn() { @sf.t("web-pages.vault.lasts." + now()) },
    tail=fn(t) { doing_mark_node(t, fn() { is_doing(core, ["vault.setLasts"], on()) }, fn() { failed_of(core, ["vault.setLasts"], on()) }) },
  )
}

///|
/// The devices holding a vault's key (`rv`, as it is now; its name where there are more than one, `many`) in `row`:
/// opens the per-device authorization dialog (`vault_devices_dialog`) instead of blindly authorizing all pending devices.
fn vault_devices_row_node(row : @view.View, core : Core, here : () -> Here, rv : () -> Json?, many : () -> Bool) -> Unit {
  let id = fn() { text(rv(), "id") }
  let title = fn() { if many() { text(rv(), "name") } else { @sf.t("android-settings.vault.devices") } }
  let missing = fn() { count(rv(), "missing") }
  row.pick(
    fn() { missing() > 0 },
    fn(p, has_missing) {
      @sf.link_row_node(
        p,
        title,
        fn() { vault_devices_dialog(core, @signals.untracked(here), @signals.untracked(id)) },
        note=fn() {
          if has_missing {
            @sf.t("web-pages.vault.missing", args=[("n", missing().to_string())])
          } else {
            @sf.t("web-pages.vault.devicesHold", args=[("n", count(rv(), "devices").to_string())])
          }
        },
        lacks=has_missing,
        goes=true,
      )
    },
  )
}

///|
/// Deleting a vault of the viewer's own (`rv`, as it is now; its name after where there are more than one, `many`) in
/// `row`, in red: asked first, saying what goes with it.
fn vault_delete_row_node(row : @view.View, core : Core, ws : () -> String, rv : () -> Json?, many : () -> Bool) -> Unit {
  let on = fn() { [("workspace", ws()), ("vault", text(rv(), "id"))] }
  @sf.link_row_node(
    row,
    fn() {
      if many() {
        @sf.t("web-pages.vault.deleteNamed", args=[("name", text(rv(), "name"))])
      } else {
        @sf.t("web-pages.vault.deleteVault")
      }
    },
    fn() {
      if !is_doing(core, ["vault.delete"], @signals.untracked(on)) {
        // (as the core says it now, how many items it keeps with it)
        let w = @signals.untracked(ws)
        let id = text(@signals.untracked(rv), "id")
        let whole = items((core.topic)("vaults", { "workspace": str(w) }).untracked().value, "vaults").iter().find_first(fn(r) {
          text(Some(r), "id") == id
        })
        vault_delete_ask(core, w, whole)
      }
    },
    danger=true,
    chevron=false,
    tail=fn(t) { doing_mark_node(t, fn() { is_doing(core, ["vault.delete"], on()) }, fn() { failed_of(core, ["vault.delete"], on()) }) },
  )
}

///|
/// A vault this device has no key to (VaultSection's; `rv`, as it is now), under its name, in `b`: that it has none,
/// how to get one; 申请授权 (`vault.ask`: this device's certificate published anew, so the owner's devices are prompted for
/// the key, or give it at once where one holds it unsealed) and the recovery words typed where they can give it one.
fn vault_no_key_node(b : @view.View, core : Core, ws : () -> String, rv : () -> Json?) -> Unit {
  let this_code = fn() { text((core.topic)("vaults", { "workspace": str(ws()) }).get().value, "thisDeviceCode") }
  @sf.section_node(b, fn() { text(rv(), "name") }, fn(s) {
    @sf.page_card_node(s, footed=true, fn(k) {
      @sf.card_lines_node(k, fn() { @sf.t("android-settings.vault.noKey") }, note=fn() { @sf.t("android-settings.vault.noKeyHow") })
      k.show(fn() { this_code() != "" }, fn(c) {
        @sf.style_node(c, fn() { vt_code_box })
        c
        .words_runs(
          By(fn() {
            [
              @ui.span(@sf.t("web-pages.vault.thisDeviceCodeLabel"), color=@sf.theme().p.muted),
              @ui.span(this_code(), mono=true, bold=true, color=@sf.theme().p.text),
              @ui.span(@sf.t("web-pages.vault.thisDeviceCodeHint"), color=@sf.theme().p.muted),
            ]
          }),
          look=@ui.style_words(@sf.meta.then(@sf.full_words)),
        )
        |> ignore
      })
      @sf.card_foot_node(k, fn(f) {
        @sf.button_node(
          f,
          fn() { @sf.t("web-pages.vault.ask") },
          fn() {
            @settings.act(core, @sf.t("web-pages.vault.askWhat"), "vault.ask", obj([("workspace", str(@signals.untracked(ws)))]), done=@sf.t(
              "web-pages.vault.asked",
            ))
          },
          tone=Primary,
          busy=fn() { is_doing(core, ["vault.ask"], [("workspace", ws())]) },
          card_words=true,
        )
        |> ignore
        f.show(fn() { flag(rv(), "recoverable") }, fn(r) {
          @sf.button_node(r, fn() { @sf.t("android-settings.vault.recover") }, fn() { vault_recover_dialog(core, @signals.untracked(ws)) }, tone=Ghost)
          |> ignore
        })
      })
    })
  })
}

///|
/// A vault waiting to be keyed anew (its row's `waits`: a device or member holding its key taken out of the lock;
/// `rv`, as it is now), under its name, in `b`: on which station its owner's device gives it new keys, and that until
/// then it is read and used, not changed. Nothing to press: the owner's device does it by itself.
fn vault_waits_node(b : @view.View, rv : () -> Json?) -> Unit {
  let note = fn() {
    let station = text(rv(), "waits")
    if vault_can_manage(rv()) {
      @sf.t("web-pages.vault.waits.mine", args=[("station", station)])
    } else {
      @sf.t("web-pages.vault.waits.theirs", args=[("owner", text(rv(), "ownerName")), ("station", station)])
    }
  }
  @sf.section_node(b, fn() { text(rv(), "name") }, fn(s) {
    @sf.page_card_node(s, fn(k) { @sf.card_lines_node(k, fn() { @sf.t("web-pages.vault.waits.title") }, note~) })
  })
}

///|
/// This device set up (`vault.setup`, which makes the person's own vault when they have none): the first time the
/// recovery words come back, to be written down.
fn vault_setup(core : Core, ws : String) -> Unit {
  vault_act(core, ws, "setup", [], @sf.t("android-settings.vault.turnOn"), then=fn(said) {
    if opt_text(Some(said), "words") is Some(words) {
      recovery_words[ws] = words.trim(chars=" \n").to_owned().split(" ").map(fn(w) { w.to_owned() }).filter(fn(w) { w != "" }).collect()
      recovery_words_changed()
    }
  })
}

///|
/// Asked before a vault of the viewer's own goes, saying what goes with it.
fn vault_delete_ask(core : Core, ws : String, rv : Json?) -> Unit {
  let id = text(rv, "id")
  let n = count(rv, "items")
  let body = if vault_is_workspace(rv) {
    if n > 0 {
      @sf.t("web-pages.vault.deleteWorkspaceBody", args=[("n", n.to_string())])
    } else {
      @sf.t("web-pages.vault.deleteWorkspaceEmpty")
    }
  } else if n > 0 {
    @sf.t("web-pages.vault.deleteVaultBody", args=[("n", n.to_string())])
  } else {
    @sf.t("web-pages.vault.deleteVaultEmpty")
  }
  confirm(
    @sf.t("web-pages.vault.deleteTitle", args=[("name", text(rv, "name"))]),
    body,
    @sf.t("common.delete"),
    danger=true,
    fn() { vault_act(core, ws, "delete", [("vault", str(id))], @sf.t("web-pages.vault.deleteWhat"), done=@sf.t("web-pages.vault.deleted")) },
  )
}

///|
/// A library made up (the core's `vaults`), for what its pages show while it is read: one vault, its items to read.
fn vaults_sample() -> Json {
  {
    "locked": true,
    "canSign": true,
    "setUp": true,
    "available": true,
    "vaults": [{ "id": "sample", "name": Json::string(@sf.sample_words(4)), "keyed": true }],
  }
}

///|
/// A vault's items made up, for what is shown while they are read: their names, kinds and lines as long as theirs.
fn vault_sample_items() -> Array[Map[String, Json]] {
  [(6, 14), (9, 11), (5, 16)].mapi(fn(i, n) {
    {
      "id": Json::string("sample" + i.to_string()),
      "name": Json::string(@sf.sample_words(n.0)),
      "kindText": Json::string(@sf.sample_words(2)),
      "lineText": Json::string(@sf.sample_words(n.1)),
      "agentText": Json::string(@sf.sample_words(n.1)),
    }
  })
}

///|
let vt_glyph : Double = 16.0

///|
/// (actions: a card's buttons at its foot, 8 apart, its words before them)
// kept across runs: a value (no field of it changes)
pub let vt_actions : @ui.Style = @ui.css("row w=Full gap=S2 pt=S1 align=ACenter")

///|
/// Full-width wrapper for the device verification code line on the no-key card.
// kept across runs: a value (no field of it changes)
let vt_code_box : @ui.Style = @ui.css("w=Full")

///|
/// 全部密钥's field: over its list, as wide as its card, 10 above it.
// kept across runs: a value (no field of it changes)
let vt_find : @ui.Style = @ui.css("w=Full pb=S2_5")

///|
/// (requests: each one's card, 10 apart as the page's cards, 10 over what follows: pagesCss.card)
// kept across runs: a value (no field of it changes)
let vt_requests : @ui.Style = @ui.css("w=Full gap=S2_5 pb=S2_5")

///|
/// An item agents are told of (listed): a green dot 6 round at its row's end (@sf.state_dot_node's, up).
let vt_listed_side : Double = 6.0

///|
/// The recovery words (Words): three to a row when room fits (two when large words outgrow three), 10 apart between
/// rows, 4 over; each its number (the code face 12, subtle, 24 wide at its end) 8 before it (the code face 15).
let vt_words_top : Double = 4.0

///|
let vt_words_row_gap : Double = 10.0

///|
// kept across runs: a value (no field of it changes)
let vt_word_number : @ui.Style = @ui.css("w=S6 align=AEnd")

///|
/// 全部密钥 (VaultItems) made once as nodes in node `v` (page_node, as vault_node is): what the library keeps
/// (vault_all_node), 添加 at its head while it is there to be used; what has to come first, as on 密钥.
pub fn vault_items_node(
  v : @view.View,
  core : Core,
  here : () -> Here,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
  tips? : @sf.TipLayer,
) -> Unit {
  let ws = fn() { here().workspace }
  let view = fn() { (core.topic)("vaults", { "workspace": str(ws()) }).get() }
  // (what comes before the library, worked out once for each change of the vaults and told on only as it changes: a
  // vault's own row changed (an item more in it) runs none of what reads it)
  let first = @signals.computed(fn(_) { vault_first_keys(ws(), view().value) })
  // (its vaults kept by id once, for the names a web page shows: each its own vault, View::keyed_by)
  let named_by = vault_named_by(v, view)
  let usable = fn() { first.get() is None }
  let all = vault_all_of(core, ws, fn() { view().value })
  // (its blocks worked out once for each change of what they are of, told on only as one comes, goes or moves: a
  // secret used changes none)
  let blocks = @signals.computed(fn(_) {
    match first.get() {
      Some(keys) => keys
      None => vault_all_keys(all)
    }
  })
  @sf.page_node(
    v,
    fn() { @sf.t("web-pages.vault.all") },
    on_back~,
    frame~,
    said?,
    width?,
    tips?,
    actions=fn(a) {
      a.show(usable, fn(k) {
        let add = fn() {
          vault_add(core, @signals.untracked(here), from=Node(k))
        }
        @sf.page_action_node(k, "plus", fn() { @sf.t("web-pages.vault.add") }, add) |> ignore
        // (a fixture's mode's 添加, from this one, at the moment the page is made: laid out by then, so it stands beside
        // it as when it is pressed)
        if fx_vault_add_up.val {
          fx_vault_add_up.val = false
          k.laid_before_causes()
          k.at_moment(k.logic_at(), add) |> ignore
        }
      })
    },
    fn() { blocks.get() },
    fn(b, key) {
      if vault_first_node(b, core, here, view, named_by, key, fn(s, quiet, sample) {
          vault_all_node(s, quiet, ws, fn() { sample }, tips)
        }) {
        return
      }
      vault_all_block(b, core, ws, all, key)
    },
  )
}

///|
/// What 密钥 and 全部密钥 show before the library, by their keys, as the core's `vaults` (`v`) says where the viewer
/// stands: the recovery words to write down ("words"); waiting for the core ("waiting"); a web page's names
/// ("read-only", then "named/<vault>" each); what has to come first ("personal-lock": no safe mode, this device to be
/// approved by another trusted device of theirs; "not-signer": in safe mode; "off": not set up here, no vault of theirs
/// on anywhere), or, not
/// signing for another reason than its not being trusted (the core's `stateText`), this device verified once by a press
/// ("confirm-signer": its `confirmText`) or the members still syncing ("lock-waiting"). None where the library is there
/// to be used (in plain text on the station, or locked, signed and set up here).
fn vault_first_keys(ws : String, v : Json?) -> Array[String]? {
  // (the words as they are now: read, so that what reads this follows them as they come or go)
  recovery_words_turned.get() |> ignore
  match v {
    _ if recovery_words.get(ws) is Some(_) => Some(["words"])
    None => Some(["waiting"])
    Some(_) if flag(v, "plain") => None
    Some(_) if !flag(v, "available") => Some(["read-only"] + items(v, "vaults").map(fn(r) { "named/" + text(Some(r), "id") }))
    Some(_) if !flag(v, "canSign") && text(v, "confirmText") != "" => Some(["confirm-signer"])
    Some(_) if !flag(v, "canSign") && text(v, "stateText") != "" => Some(["lock-waiting"])
    // (no safe mode: this device to be approved by another trusted device of theirs, here on the page, the vault being
    // theirs whatever the workspace; in safe mode, 安全 is where a device is approved)
    Some(_) if !flag(v, "canSign") && !flag(v, "locked") => Some(["personal-lock"])
    Some(_) if !flag(v, "canSign") => Some(["not-signer"])
    // (not set up here while a vault of theirs is on already, on another device of theirs: the core sets this one up by
    // itself, or 申请授权 does, so the library shows, the vault under its name with no key here yet; 开启 only where
    // the person has none)
    Some(_) if !flag(v, "setUp") && items(v, "vaults").is_empty() => Some(["off"])
    Some(_) => None
  }
}

///|
/// The block `key` of what comes before the library (vault_first_keys) in node `b`, as `view` (the core's `vaults`)
/// says it now; while it is waited for, what the page holds (`shown`: its blocks for a library's view, by a core that
/// answers nothing) of a made-up library, in its bones. False where `key` is none of those.
fn vault_first_node(
  b : @view.View,
  core : Core,
  here : () -> Here,
  view : () -> @settings.Read,
  named : @signals.KeyedList[String, Json],
  key : String,
  shown : (@view.View, Core, Json?) -> Unit,
) -> Bool {
  let ws = fn() { here().workspace }
  match key {
    "words" => vault_words_node(b, ws)
    "waiting" =>
      @sf.waiting_node(b, fn(s) { shown(s, core.quiet(), Some(vaults_sample())) }, error=fn() {
        match view().error {
          Some(e) => error_text(e)
          None => ""
        }
      })
    "read-only" => @sf.page_note_node(b, fn() { @sf.t("android-settings.vault.readOnly") })
    "not-signer" => vault_gate_node(b, core, "web-pages.vault.notSigner", "web-pages.vault.notSignerWhy")
    "personal-lock" => vault_personal_node(b, core, here)
    "confirm-signer" => vault_confirm_node(b, core, ws, view)
    // (what it waits for, in the core's words, nothing to press: it comes by itself)
    "lock-waiting" =>
      @sf.page_card_node(b, fn(k) { @sf.card_lines_node(k, fn() { "" }, words=fn() { text(view().value, "stateText") }) })
    "off" => vault_off_node(b, core, ws)
    k if k.has_prefix("named/") => {
      let id = k.exact_view(start=6).to_owned()
      vault_named_node(b, core, ws, fn() { named.get(id) })
    }
    _ => return false
  }
  true
}

///|
/// This device off its person's own lock, the workspace in no safe mode (the core's `vaults` neither `locked` nor
/// `canSign`): approved here by another of their trusted devices (发送批准请求, the code it shows typed in), or, their
/// trusted devices set up again elsewhere, said to be theirs; as 共享调试 has it (@settings.personal_lock_node), its
/// words the vault's. The core's `adbShare` read only while this shows.
fn vault_personal_node(b : @view.View, core : Core, here : () -> Here) -> Unit {
  let adb = fn() { (core.topic)("adbShare", Map([])).get().value }
  @settings.personal_lock_node(
    b,
    core,
    fn() { @settings.personal_lock_step(adb(), here().sub) },
    outside_note=fn() { @sf.t("web-pages.vault.outsideNote") },
    restart_note=fn() { @sf.t("web-pages.vault.restartNote") },
  )
}

///|
/// What the vault waits for before anything else (Gate, ToSecurity): said on a card (`title`, `why`: their words'
/// keys), with the way there at its foot.
fn vault_gate_node(b : @view.View, core : Core, title : String, why : String) -> Unit {
  @sf.page_card_node(b, footed=true, fn(k) {
    @sf.card_lines_node(k, fn() { @sf.t(title) }, note=fn() { @sf.t(why) })
    @sf.card_foot_node(k, fn(f) {
      @sf.button_node(f, fn() { @sf.t("web-pages.vault.toSecurity") }, fn() { (core.push)(Security) }, tone=Primary, card_words=true)
      |> ignore
    })
  })
}

///|
/// This device to be verified once before it signs (the core's `stateText`: its signer not said on its person's own
/// lock), said on a card with 验证 (`confirmText`: `lock.confirmSigner`, the person asked once) at its foot, a ring on it
/// while that goes.
fn vault_confirm_node(b : @view.View, core : Core, ws : () -> String, view : () -> @settings.Read) -> Unit {
  let label = fn() { text(view().value, "confirmText") }
  @sf.page_card_node(b, footed=true, fn(k) {
    @sf.card_lines_node(k, fn() { "" }, words=fn() { text(view().value, "stateText") })
    @sf.card_foot_node(k, fn(f) {
      @sf.button_node(
        f,
        label,
        fn() { lock_call(core, @signals.untracked(ws), "confirmSigner", @signals.untracked(label), []) },
        tone=Primary,
        busy=fn() { is_doing(core, ["lock.confirmSigner"], [("workspace", ws())]) },
        card_words=true,
      )
      |> ignore
    })
  })
}

///|
/// Not set up on this device yet (Off): what it is, what agents do with it and how it is opened, a line each; 开启
/// (`vault.setup`) at its foot.
fn vault_off_node(b : @view.View, core : Core, ws : () -> String) -> Unit {
  @sf.page_card_node(b, footed=true, fn(k) {
    @sf.card_lines_node(
      k,
      fn() { @sf.t("android-settings.vault.offTitle") },
      words=fn() { @sf.t("android-settings.vault.offWhat") },
      note=fn() { @sf.t("android-settings.vault.offAgents") + "\n" + @sf.t("android-settings.vault.offUnlock") },
    )
    @sf.card_foot_node(k, fn(f) {
      @sf.button_node(
        f,
        fn() { @sf.t("android-settings.vault.turnOn") },
        fn() { vault_setup(core, @signals.untracked(ws)) },
        tone=Primary,
        busy=fn() { is_doing(core, ["vault.setup"], [("workspace", ws())]) },
        card_words=true,
      )
      |> ignore
    })
  })
}

///|
/// The 24 recovery words, numbered, three to a row, for the person to copy out (Words): why, and that they are shown
/// this once (the core gives them the once); written down, the person says so at its foot.
fn vault_words_node(b : @view.View, ws : () -> String) -> Unit {
  let words = fn() {
    recovery_words_turned.get() |> ignore
    recovery_words.get(ws()).unwrap_or([])
  }
  @sf.page_card_node(b, footed=true, fn(k) {
    @sf.card_lines_node(
      k,
      fn() { @sf.t("android-settings.vault.wordsTitle") },
      words=fn() { @sf.t("android-settings.vault.wordsWhy") },
      note=fn() { @sf.t("android-settings.vault.wordsOnce") },
    )
    k.by_room(fn(all, given) {
      all.row(Is(true)).wraps(Is(Some(vt_words_row_gap))).padding(Is((0.0, vt_words_top, 0.0, 0.0))) |> ignore
      let cell_w = fn() {
        all.words_redone() |> ignore
        let room = given.width()
        let body_sz = @sf.node_sp(all, @ui.tree_theme().text_size(Body).0)
        let need = 24.0 + vt_word_gap + body_sz * 4.2
        let cols = if room >= 3.0 * need { 3 } else { 2 }
        (room / cols.to_double()).floor()
      }
      all.each(fn() { Array::makei(words().length(), fn(i) { i }) }, fn(i) { i }, fn(w, i) {
        w.row(Is(true)).gap(Is(vt_word_gap)).lines_up(Is(Some(End))).width(By(fn() { Some(cell_w()) })).shrink(Is(0.0)) |> ignore
        w.box(fn(n) {
          @sf.style_node(n, fn() { vt_word_number })
          @sf.mono_line_node(n, fn() { (i.get() + 1).to_string() }, Meta, fn() { @sf.theme().p.subtle })
        })
        |> ignore
        @sf.mono_line_node(w, fn() { words().get(i.get()).unwrap_or("") }, Body, fn() { @sf.theme().p.text })
      })
    })
    |> ignore
    @sf.card_foot_node(k, fn(f) {
      @sf.button_node(
        f,
        fn() { @sf.t("android-settings.vault.wordsDone") },
        fn() {
          recovery_words.remove(@signals.untracked(ws))
          recovery_words_changed()
        },
        tone=Primary,
        card_words=true,
      )
      |> ignore
    })
  })
}

///|
/// What 全部密钥's field looks for: words of a secret's row (its name, its kind, how it is given: its host, its
/// variable; where it was last used).
// kept across runs: what the page's field holds, the person's; vault_reset empties it
let vault_find : @ui.Field = @ui.Field::new()

///|
/// Whether 全部密钥's profiles' accounts are shown (folded at its foot till then).
// kept across runs: the person's; vault_reset folds them
let vault_accounts_open : @signals.Signal[Bool] = @signals.signal(false)

///|
fn vault_reset() -> Unit {
  vault_find.set("")
  vault_accounts_open.set(false)
}

///|
/// A row of 全部密钥: a vault's secret ("it/<vault>/<item>": its vault's id and name, the secret, whether there are
/// more vaults than one, whether it is keyed), or those of a vault it does not name ("hidden/<vault>": the first of
/// them, what is said of them, whether it is keyed). Of its vault only what the row shows: a change of the vault's
/// own row (how many it holds, an item added) changes no secret's row.
priv enum VaultRow {
  Secret(String, String, Json, Bool, Bool)
  Hidden(String, String, Bool)
}

///|
/// The same row: of the same JSON (the core's deltas keep what they do not touch: one comparison of two references, a
/// row whose JSON changed read whole), as said the same.
impl Eq for VaultRow with equal(a, b) {
  match (a, b) {
    (Secret(v, n, i, m, k), Secret(v2, n2, i2, m2, k2)) =>
      v == v2 && n == n2 && m == m2 && k == k2 && (physical_equal(i, i2) || i == i2)
    (Hidden(i, w, k), Hidden(i2, w2, k2)) => i == i2 && w == w2 && k == k2
    _ => false
  }
}

///|
/// 全部密钥 (LibraryItems), as a password manager's list (the user, 2026-10-26: a section a kind of one row each was
/// 「信息密度极低，找也找不到有意义的东西」), in node `b`, as the library's view (`view`) and each vault's items say them
/// now: a field to find one by any of its words; then every one on one list card, a row each: its mark (a secret's
/// kind), its name, and under it its kind and what is worth knowing of it (a secret's way to an agent and its last use,
/// the core's lineText), each leading to its page: each vault's secrets (a vault this device has no key to, the names
/// it is told, going nowhere), locked, a row of those it does not name; then the profiles' accounts on a card of their
/// own, folded under a row naming them (they are the profiles' pages' first: the user, 2026-10-26, 「订阅一般在
/// profiles 看过了」), open where what is looked for is among them.
fn vault_all_node(b : @view.View, core : Core, ws : () -> String, view : () -> Json?, tips : @sf.TipLayer?) -> Unit {
  ignore(tips)
  let all = vault_all_of(core, ws, view)
  b.box(fn(col) {
    vault_find_node(col)
    // (what is looked for another list, by what is typed: switched there at once, as the page's blocks are keyed by it,
    // vault_all_keys)
    col.switch_by(vault_found_by, fn(found, _) {
      // (each secret by its vault and id: one added or taken out comes and goes where it is)
      found.show(fn() { all.rows.get().length() > 0 }, fn(s) {
        @sf.group_node(s, fn(g) {
          g.each(fn() { all.rows.get() }, fn(r) { r.0 }, fn(row, r) { vault_row_node(row, core, ws, fn() { r.get().1 }) })
        })
      })
      // the accounts, folded under a row naming them (open where what is looked for is among them)
      found.show(fn() { all.accounts.get().length() > 0 }, fn(s) { vault_accounts_node(s, core, all) })
      found.pick(fn() { vault_all_said(all) }, fn(p, what) { vault_all_said_node(p, core, ws, what) })
    })
  })
  |> ignore
}

///|
/// What 全部密钥 lists, each worked out once for each change of what it reads (the library's view, each vault's
/// secrets, the profiles' accounts, what is looked for), read by all that shows it: its rows, each with its key, and
/// where each is among them; how many of them are named secrets; the accounts; how many the profiles keep in all;
/// whether a vault's secrets are still read.
priv struct VaultAll {
  rows : @signals.Computed[Array[(String, VaultRow)]]
  at : @signals.Computed[Map[String, Int]]
  named : @signals.Computed[Int]
  accounts : @signals.Computed[Array[(String, String, String, String, String, @settings.Route)]]
  kept_accounts : @signals.Computed[Int]
  reading : @signals.Computed[Bool]
}

///|
/// 全部密钥's lists (VaultAll) as the library's view (`view`) and each vault's items say them now.
fn vault_all_of(core : Core, ws : () -> String, view : () -> Json?) -> VaultAll {
  let find = fn() { vault_find.text().trim(chars=" ").to_lower() }
  let shows = fn(words : Array[String]) {
    let f = find()
    f == "" || words.iter().any(fn(w) { w.to_lower().contains(f) })
  }
  // (a row's line: what is said of it, those words that are not empty, a dot between)
  let said = fn(words : Array[String]) { words.filter(fn(w) { w != "" }).join(" · ") }
  let vaults = fn() { items(view(), "vaults") }
  let topic_of = fn(rv : Json?) { (core.topic)("vaultItems", { "workspace": str(ws()), "vault": str(text(rv, "id")) }).get() }
  // (each worked out once for each change of what it reads, read by all that shows it: the card's rows, whether there
  // are any, what is said in their place)
  let reading = @signals.computed(fn(_) { vaults().iter().any(fn(r) { topic_of(Some(r)).value is None }) })
  // each vault's secrets, by name (the core's order); those it does not name, a row
  let rows = @signals.computed(fn(_) {
    let plain = flag(view(), "plain")
    let many = vaults().length() > 1
    let out : Array[(String, VaultRow)] = []
    let unnamed : Array[(String, VaultRow)] = []
    for row in vaults() {
      let rv = Some(row)
      let listed = topic_of(rv).value
      if listed is None {
        continue
      }
      let list = items(listed, "items")
      let keyed = plain || flag(rv, "keyed")
      for it in list {
        let iv = Some(it)
        if has(iv, "name") && shows([text(iv, "name"), text(iv, "kindText"), text(iv, "lineText"), text(iv, "howText")]) {
          out.push(("it/" + text(rv, "id") + "/" + text(iv, "id"), Secret(text(rv, "id"), text(rv, "name"), it, many, keyed)))
        }
      }
      let hidden = list.filter(fn(x) { !has(Some(x), "name") })
      if hidden.length() > 0 {
        unnamed.push(
          (
            "hidden/" + text(rv, "id"),
            Hidden(text(Some(hidden[0]), "id"), @sf.t("web-pages.vault.hidden", args=[("n", hidden.length().to_string())]), keyed),
          ),
        )
      }
    }
    out + unnamed
  }, same=fn(a, b) { a == b })
  // (the secrets found by their names: not found, whatever a vault does not name)
  let named = @signals.computed(fn(_) { rows.get().iter().filter(fn(r) { r.1 is Secret(_, _, _, _, _) }).count() })
  // (the profiles' accounts in their groups, as the profiles list them)
  let groups = @signals.computed(
    fn(_) { profile_groups(items((core.topic)("profiles", { "scope": str(ws()) }).get().value, "items")) },
    same=fn(a, b) { a == b },
  )
  // the profiles' accounts, as the profiles list them: each its key, its title, what is said under it, its trouble, its
  // group, where it goes
  let accounts = @signals.computed(fn(_) {
    let out : Array[(String, String, String, String, String, @settings.Route)] = []
    for g in groups.get() {
      for e in g.1 {
        let ev = Some(e)
        let p = field(ev, "profile")
        // (a subscription by its account, a key by its name: the core's)
        let title = if text(ev, "title") == "" { text(p, "name") } else { text(ev, "title") }
        if shows([title, g.0, text(ev, "where")]) {
          out.push(
            (
              text(ev, "key"),
              title,
              said([g.0, text(ev, "where")]),
              if text(p, "checkTone") == "red" { text(p, "checkText") } else { "" },
              text(ev, "group"),
              Profile(text(ev, "station"), text(p, "id")),
            ),
          )
        }
      }
    }
    out
  }, same=fn(a, b) { a == b })
  let kept_accounts = @signals.computed(fn(_) {
    let mut n = 0
    for g in groups.get() {
      n += g.1.length()
    }
    n
  })
  let at = @signals.computed(fn(_) {
    let out : Map[String, Int] = Map([])
    for i, r in rows.get() {
      out[r.0] = i
    }
    out
  }, same=fn(a, b) { a == b })
  { rows, at, named, accounts, kept_accounts, reading }
}

///|
/// What 全部密钥's search is typed in (vault_find).
fn vault_find_node(b : @view.View) -> Unit {
  b.box(fn(f) {
    @sf.style_node(f, fn() { vt_find })
    @sf.input_node(f, vault_find, placeholder=@sf.t("web-pages.vault.find")) |> ignore
  })
  |> ignore
}

///|
/// The profiles' accounts on a card of their own (vault_all_node's), folded under a row naming them, open where what
/// is looked for is among them.
fn vault_accounts_node(s : @view.View, core : Core, all : VaultAll) -> Unit {
  let find = fn() { vault_find.text().trim(chars=" ").to_lower() }
  let open = fn() { vault_accounts_open.get() || find() != "" }
  @sf.group_node(s, fn(g) {
    // (its words where the names are, as those of the secrets' row of those it does not name)
    @sf.link_row_node(
      g,
      fn() { @sf.t("web-pages.vault.accounts") },
      fn() {
        if @signals.untracked(find) == "" {
          vault_accounts_open.set(!@signals.untracked(open))
        }
      },
      note=fn() { if open() { "" } else { all.accounts.get().map(fn(a) { a.1 }).join("、") } },
      folds=open,
      lead=LeadMade(fn(l) { l.width(Is(Some(vt_no_mark_w))) |> ignore }),
    )
    g.show(open, fn(o) {
      o.each(fn() { all.accounts.get() }, fn(a) { a.0 }, fn(row, a) {
        let av = fn() { a.get() }
        @sf.link_row_node(
          row,
          fn() { av().1 },
          fn() { (core.push)(@signals.untracked(av).5) },
          note=fn() { av().2 },
          trouble=fn() { av().3 },
          lead=LeadMade(fn(l) { l.pick(fn() { av().4 }, fn(m, group) { vt_group_mark_node(m, group) }) }),
        )
      })
    })
  })
}

///|
/// What 全部密钥 says under its rows now: nothing (0); its secrets still read (1); none found by what is looked for (2);
/// none at all (3).
fn vault_all_said(all : VaultAll) -> Int {
  let find = vault_find.text().trim(chars=" ").to_lower()
  if all.reading.get() {
    1
  } else if all.named.get() + all.accounts.get().length() == 0 && find != "" {
    2
  } else if all.rows.get().length() + all.kept_accounts.get() == 0 {
    3
  } else {
    0
  }
}

///|
/// What 全部密钥 says under its rows (vault_all_said's `what`), in `p`.
fn vault_all_said_node(p : @view.View, core : Core, ws : () -> String, what : Int) -> Unit {
  match what {
    // (a vault's secrets still read: rows' shapes under what is shown)
    1 =>
      @sf.waiting_node(p, fn(w) {
        @sf.group_node(w, fn(g) {
          for x in vault_sample_items() {
            vault_row_node(g, core.quiet(), ws, fn() { Secret("", "", Json::object(x), false, true) })
          }
        })
      }, note=fn() { { reading: true, text: @sf.t("common.reading"), failing: [] } })
    2 => @sf.page_note_node(p, fn() { @sf.t("web-pages.vault.noMatch", args=[("q", vault_find.text().trim(chars=" ").to_owned())]) })
    3 => @sf.page_note_node(p, fn() { @sf.t("web-pages.vault.empty") })
    _ => ()
  }
}

///|
/// 全部密钥's blocks on a page's list (a block is a row: its list card made a piece of it a row, as far as it shows):
/// its search, each of its rows by its key, the accounts' card, what it says under them. What is looked for is another
/// list, by what is typed: each block under the search keyed by it too (vault_found_by), so what a query typed or changed
/// finds is another set in the place of the ones before, there at once (page_node's pg_blocks_read), as 设置's search's
/// cards are (settings_list.mbt), never the card of the accounts closing on its way as its rows close on theirs in it
/// (#6647 left this one: vault_wbtest's 全部密钥 found by ssh, the card turned back in a frame). A secret added or taken
/// out under one query comes and goes where it is, as ever.
fn vault_all_keys(all : VaultAll) -> Array[String] {
  let by = vault_found_by()
  let out = ["find"]
  for r in all.rows.get() {
    out.push(r.0 + by)
  }
  if all.accounts.get().length() > 0 {
    out.push("accounts" + by)
  }
  if vault_all_said(all) != 0 {
    out.push("said" + by)
  }
  out
}

///|
/// What 全部密钥's blocks under its search are keyed by besides their own (vault_all_keys): what is looked for, "" where
/// nothing is.
fn vault_found_by() -> String {
  let q = vault_find.text().trim(chars=" ").to_lower()
  if q == "" {
    ""
  } else {
    "?" + q.to_owned()
  }
}

///|
/// A block's key of 全部密钥 (vault_all_keys') as it is of its own, what is looked for taken off it.
fn vault_block_own(key : String) -> String {
  match key.find("?") {
    Some(i) => key.unsafe_substring(start=0, end=i)
    None => key
  }
}

///|
/// 全部密钥's block `key` (vault_all_keys') in `b`: a row of its list card, the piece of the card it is where it is
/// among them now, as it is now (as it was last where its key is gone, while it goes).
fn vault_all_block(b : @view.View, core : Core, ws : () -> String, all : VaultAll, key : String) -> Unit {
  let key = vault_block_own(key)
  match key {
    "find" => vault_find_node(b)
    "accounts" => vault_accounts_node(b, core, all)
    "said" => b.pick(fn() { vault_all_said(all) }, fn(p, what) { vault_all_said_node(p, core, ws, what) })
    _ => {
      // (which piece of the card it is and its row, worked out once for each change of the list and told on only as
      // they change: a secret used, or one added, runs the bindings of the rows it changes, never every row's; as last,
      // once its key is gone)
      let held : @signals.Computed[(@sf.CardPiece, VaultRow)?] = @signals.computed(fn(last) {
        match all.at.get().get(key) {
          Some(i) => {
            let rows = all.rows.get()
            Some((@sf.card_piece_of(i, rows.length()), rows[i].1))
          }
          None =>
            match last {
              Some(l) => l
              None => None
            }
        }
      })
      guard @signals.untracked(fn() { held.get() }) is Some(_) else { return }
      let piece = @signals.computed(fn(_) {
        match held.get() {
          Some((p, _)) => p
          None => @sf.CardPiece::CardWhole
        }
      })
      let row = @signals.computed(fn(_) { held.get().unwrap().1 })
      // (as tall as its block, its piece of the card in it as tall: card_piece_node)
      b.grow(Is(1.0)) |> ignore
      @sf.card_piece_node(b, fn() { piece.get() }, wide_group=true, fn(card) {
        vault_row_node(card, core, ws, fn() { row.get() })
      })
    }
  }
}

///|
/// A row of 全部密钥 (`r`, as it is now) on its card: a secret (its kind's mark, its name, its kind, its vault where
/// there are more than one, how an agent gets it, when and where it was last used: the core's; pressed, its page where
/// it can be opened here), or those of a vault it does not name (its words where the names are; unlocked by opening one
/// of them, the vault's key kept a while, every name shown; one this device has no key to, said alone).
fn vault_row_node(row : @view.View, core : Core, ws : () -> String, r : () -> VaultRow) -> Unit {
  let how_now = fn() {
    match r() {
      Secret(_, _, _, _, keyed) => if keyed { 0 } else { 1 }
      Hidden(_, _, keyed) => if keyed { 2 } else { 3 }
    }
  }
  row.pick(how_now, fn(p, how) {
    match how {
      0 | 1 => {
        let parts = fn() {
          match r() {
            Secret(vault, vault_name, i, many, _) => (vault, vault_name, Some(i), many)
            _ => ("", "", None, false)
          }
        }
        let keyed = how == 0
        @sf.link_row_node(
          p,
          fn() { text(parts().2, "name") },
          fn() {
            let (vault, _, iv, _) = @signals.untracked(parts)
            (core.push)(VaultItem(vault, text(iv, "id")))
          },
          note=fn() {
            let (_, vault_name, iv, many) = parts()
            [text(iv, "kindText"), if many { vault_name } else { "" }, if keyed { text(iv, "lineText") } else { text(iv, "agentText") }]
            .filter(fn(w) { w != "" })
            .join(" · ")
          },
          lead=LeadMade(fn(l) {
            l.pick(fn() { @settings.kind_icon(text(parts().2, "kind")) }, fn(m, icon) {
              @sf.icon_node(m, icon, vt_glyph, By(fn() { @sf.theme().p.text })) |> ignore
            })
          }),
          goes=keyed,
        )
      }
      _ => {
        let words = fn() {
          match r() {
            Hidden(_, w, _) => w
            _ => ""
          }
        }
        let lead : @sf.RowLead = LeadMade(fn(l : @view.View) { l.width(Is(Some(vt_no_mark_w))) |> ignore })
        if how == 3 {
          @sf.link_row_node(p, words, fn() {  }, lead~, goes=false)
        } else {
          @sf.link_row_node(
            p,
            words,
            fn() {
              match @signals.untracked(r) {
                Hidden(first, _, _) =>
                  @settings.act(core, @sf.t("web-pages.vault.unlockWhat"), "vault.open", obj([("workspace", str(@signals.untracked(ws))), ("item", str(first))]))
                _ => ()
              }
            },
            value=fn() { @sf.t("web-pages.vault.unlock") },
            value_lit=true,
            chevron=false,
            lead~,
          )
        }
      }
    }
  })
}

///|
/// Where a row's mark would be, kept for one with none (w=S4): its words where the others' names are.
let vt_no_mark_w : Double = 16.0

///|
/// vt_word's room between a word's number and it (gap=S2).
let vt_word_gap : Double = 8.0

///|
/// A vault known by its items' names only (`rv`; VaultSection), a section under its name: a web page's, or one this
/// device has no key to (how to get one is 密钥's: vault_no_key_node); each item's name (locked, that it is), how agents
/// may ask for it under it, a green dot at its end where agents are told of it; while they are read the first time,
/// rows of made-up ones in their bones.
fn vault_named_node(b : @view.View, core : Core, ws : () -> String, rv : () -> Json?) -> Unit {
  let topic = fn() { (core.topic)("vaultItems", { "workspace": str(ws()), "vault": str(text(rv(), "id")) }).get() }
  let list = fn() { items(topic().value, "items") }
  @sf.section_node(b, fn() { text(rv(), "name") }, fn(s) {
    s.pick(
      fn() {
        if list().length() > 0 {
          0
        } else {
          match topic().value {
            Some(_) => 1
            None => if topic().error is Some(_) { 2 } else { 3 }
          }
        }
      },
      fn(p, what) {
        match what {
          0 => @sf.group_node(p, fn(g) { named_rows_node(g, list) })
          1 => @sf.page_note_node(p, fn() { @sf.t("android-settings.vault.empty") })
          2 => @sf.page_note_node(p, fn() { topic().error.map(error_text).unwrap_or("") }, bad=fn() { true })
          // (read the first time: rows' shapes where its card's rows will be)
          _ =>
            @sf.waiting_node(p, fn(w) {
              @sf.group_node(w, fn(g) { named_rows_node(g, fn() { vault_sample_items().map(Json::object) }) })
            })
        }
      },
    )
  })
}

///|
/// A vault's items known by their names only (`list`, as it is now), on a group's card `g`: each item's name (locked,
/// that it is), how agents may ask for it under it, a green dot at its end where agents are told of it.
fn named_rows_node(g : @view.View, list : () -> Array[Json]) -> Unit {
  g.each(list, vault_id, fn(row, x) {
    let iv = fn() { Some(x.get()) }
    @sf.link_row_node(
      row,
      fn() { opt_text(iv(), "name").unwrap_or(@sf.t("android-settings.vault.lockedItem")) },
      fn() {  },
      note=fn() { text(iv(), "agentText") },
      goes=false,
      tail=fn(e) { @sf.state_dot_node(e, fn() { "up" }, size=vt_listed_side) },
      tail_shown=fn() { flag(iv(), "listed") },
    )
  })
}

///|
/// What a profile's group is by (@settings.group_mark's) as a node: a key's, else its provider's, 16 across.
fn vt_group_mark_node(parent : @view.View, group : String) -> Unit {
  match group {
    "key" => @sf.icon_node(parent, "key", vt_glyph, By(fn() { @sf.theme().p.text })) |> ignore
    "service" => @sf.provider_logo_node(parent, "", "service", vt_glyph, "") |> ignore
    // signed in to an account: its provider's
    "kimi" => @sf.provider_logo_node(parent, "claude", "api-provider", vt_glyph, "kimi") |> ignore
    "opencode" => @sf.provider_logo_node(parent, "claude", "opencode-go", vt_glyph, "") |> ignore
    // a subscription: its vendor's, by the runtime it is (ChatGPT's Codex; SuperGrok's xAI, Cursor's, Devin's)
    "chatgpt" => @sf.provider_logo_node(parent, "codex", "subscription", vt_glyph, "") |> ignore
    "" => @sf.provider_logo_node(parent, "claude", "subscription", vt_glyph, "") |> ignore
    g => @sf.provider_logo_node(parent, g, "subscription", vt_glyph, "") |> ignore
  }
}

///|
/// A vault's key in the core's `vaults` (what its library and its names are kept by).
fn vault_id(r : Json) -> String {
  text(Some(r), "id")
}

///|
/// The vaults a web page names (one that keeps no keys: `available` false), kept by id once, each its own vault
/// (View::keyed_by); none where keys are kept, so a vault's own change there runs nothing of these.
fn vault_named_by(v : @view.View, view : () -> @settings.Read) -> @signals.KeyedList[String, Json] {
  let named = @signals.computed(fn(_) {
    let x = view().value
    if x is Some(_) && !flag(x, "available") {
      items(x, "vaults")
    } else {
      []
    }
  })
  v.keyed_by(fn() { named.get() }, vault_id)
}
