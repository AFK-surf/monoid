// 密钥's dialogs, the library's
// (open_dialog_nodes; 添加's a pick): what 添加 offers, an item written (a new one, or one opened, changed or deleted), the recovery words
// typed in.

///|
/// 添加 (AddKinds): which kind is added, picked beside what opened it (`from`: the page's 添加; a sheet on Small): a
/// subscription or a model's key (a profile: the Profile list), a Slack account signed in to (`vault_oauth`), or a
/// secret of a kind (its editor, the kind fixed, which says it is kept in the clear where the library is not locked);
/// each its mark, its name and what it is.
pub fn vault_add(core : Core, here : Here, from~ : @sf.Beside) -> Unit {
  let ws = here.workspace
  let v = (core.topic)("vaults", { "workspace": str(ws) }).get().value
  let all_vaults = items(v, "vaults")
  let plain = flag(v, "plain")
  let keyed_personal = all_vaults.filter(fn(x) { (flag(Some(x), "keyed") || plain) && !vault_is_workspace(Some(x)) })
  let keyed_workspace = all_vaults.filter(fn(x) { (flag(Some(x), "keyed") || plain) && vault_is_workspace(Some(x)) })
  let keyed_vaults = keyed_personal + keyed_workspace
  let mine = all_vaults.iter().find_first(fn(x) { flag(Some(x), "mine") && !vault_is_workspace(Some(x)) })
  let kinds = ["profile"]
  // (a service signed in to as the person: its token kept as one typed in would be, where one is)
  let into = match mine {
    Some(m) => text(Some(m), "id")
    None =>
      match keyed_vaults.get(0) {
        Some(kv) => text(Some(kv), "id")
        None => if plain { "plain" } else { "" }
      }
  }
  if into != "" {
    kinds.push("slack")
  }
  if keyed_vaults.length() > 0 {
    kinds.append(vault_kinds)
  }
  let targets = keyed_vaults.map(fn(x) { (text(Some(x), "id"), text(Some(x), "name")) })
  let choices = kinds.map(fn(k) {
    match k {
      "slack" =>
        @sf.choice(
          k,
          @sf.t("web-pages.vault.addKind.slack"),
          note=@sf.t("web-pages.vault.addKind.slackDetail"),
          mark=Drawn("slack"),
        )
      _ =>
        @sf.choice(
          k,
          @sf.t("web-pages.vault.addKind." + k),
          note=@sf.t("web-pages.vault.addKind." + k + "Detail"),
          icon=if k == "profile" { "quota" } else { @settings.kind_icon(k) },
        )
    }
  })
  @sf.pick("", choices, "", fn(k) {
    if k == "profile" {
      (core.push)(Profiles(""))
    } else if k == "slack" {
      vault_oauth(core, ws, into, "slack")
    } else {
      match targets.get(0) {
        Some((vid, _)) => vault_editor_dialog(core, ws, vid, None, kind=k, plain~, kinds=false, targets~)
        None => ()
      }
    }
  }, from~, along=End)
}

///|
/// 添加 › Slack 账号: the person signs in on the service's page (`Core`'s vault_oauth, the host's browser), their
/// token kept in `vault` as the vault's rows then show it; a toast says it is kept, or why not (nothing for one given
/// up, nor where the web's own page finishes it and says so).
fn vault_oauth(core : Core, ws : String, vault : String, provider : String) -> Unit {
  (core.vault_oauth)(ws, vault, provider, "", fn(r) {
    match r {
      Ok("") | Err("cancelled") => ()
      Ok(name) => (core.say)(@sf.t("web-pages.vault.oauth.added", args=[("name", name)]))
      Err("") => (core.say)(@sf.t("web-pages.vault.oauth.failed"))
      Err(why) => (core.say)(why)
    }
  })
}

///|
/// Active vault editor dialogs `(ws, get_vault, clear_and_close)` so auth/vault boundaries can
/// immediately wipe plaintext inputs and close open editors for the affected scope.
// kept across runs: vault_dialogs_reset empties it
let active_vault_editors : Map[Int, (String, () -> String, () -> Unit)] = Map([])

///|
// kept across runs: monotonic id counter; vault_dialogs_reset zeroes it
let next_vault_editor_id : Ref[Int] = Ref(0)

///|
fn vault_dialogs_reset() -> Unit {
  active_vault_editors.clear()
  next_vault_editor_id.val = 0
}

///|
fn clear_vault_editors_for(ws : String, vault : String) -> Unit {
  let to_close : Array[(Int, () -> Unit)] = []
  for id, entry in active_vault_editors {
    let (ews, get_vault, close_fn) = entry
    let matches = if ws == "" && vault == "" {
      true
    } else if ews != ws {
      false
    } else {
      let ev = @signals.untracked(get_vault)
      vault == "" || ev == "" || ev == vault
    }
    if matches {
      to_close.push((id, close_fn))
    }
  }
  for item in to_close {
    active_vault_editors.remove(item.0)
    (item.1)()
  }
}

///|
/// A fixture's mode's 添加 put up from the page's own (MBUI_FIXTURE=settings-vault-add), as it is drawn.
pub let fx_vault_add_up : Ref[Bool] = Ref(false)

///|
/// An item written (Editor): a new one (`editing` None; its kind picked unless `kinds` is false and `kind` says it), or
/// one opened changed (its row and what it holds); its name and fields, whether agents may ask for it (then how it is
/// given, where to, under which variable, its longest grant); `vault.putItem`, the dialog staying while it is saved
/// (refused, why under it); 删除 for one there, asked first. `plain`: the library is not locked, said first.
pub fn vault_editor_dialog(
  core : Core,
  ws : String,
  vault : String,
  editing : (Json, Json)?,
  kind? : String = "",
  plain? : Bool = false,
  kinds? : Bool = true,
  targets? : Array[(String, String)] = [],
  revoked? : @signals.Signal[Bool],
  on_clear_handle? : (() -> Unit) -> Unit = fn(_) {  },
  can_pop? : () -> Bool = fn() { true },
  on_gone? : () -> Unit = fn() {  },
) -> Unit {
  let was = match editing {
    Some((_, p)) => Some(p)
    None => None
  }
  let row = match editing {
    Some((r, _)) => Some(r)
    None => None
  }
  let start_target = targets.search_by(fn(t) { t.0 == vault }).unwrap_or(0)
  let target_idx : @signals.Signal[Int] = @signals.signal(start_target)
  let target_vault = fn() {
    if was is None && targets.length() > 1 {
      targets.get(target_idx.get()).map(fn(t) { t.0 }).unwrap_or(vault)
    } else {
      vault
    }
  }
  let start_kind = match was {
    Some(p) => text(Some(p), "kind")
    None => kind
  }
  let chosen_kind : @signals.Signal[Int] = @signals.signal(vault_item_kinds.search(start_kind).unwrap_or(0))
  let k = fn() { vault_item_kinds[chosen_kind.get()] }
  let agent : @signals.Signal[Bool] = @signals.signal(flag(row, "listed"))
  let mode : @signals.Signal[String] = @signals.signal(
    match strings(row, "modes").iter().find_first(fn(m) { m == "proxy" || m == "env" }) {
      Some(m) => m
      None => "proxy"
    },
  )
  let lasts : @signals.Signal[Int] = @signals.signal(vault_lasts.search(text(row, "lasts")).unwrap_or(0))
  let error : @signals.Signal[String] = @signals.signal("")
  let saving : @signals.Signal[Bool] = @signals.signal(false)
  let file : @signals.Signal[(String, String)] = @signals.signal(
    (text(field(was, "fields"), "content"), text(field(was, "fields"), "filename")),
  )
  // its fields, each with what it holds already as it opens
  let fields : Map[String, @ui.Field] = Map([])
  for part in ["name", "about", "value", "private_key", "public_key", "username", "password", "totp", "hosts", "env"] {
    let value = match part {
      "name" => text(was, "name")
      "about" => text(was, "notes")
      "hosts" => join(strings(row, "hosts"), ", ")
      "env" => text(row, "env")
      _ => text(field(was, "fields"), part)
    }
    fields[part] = @ui.Field::new(text=value)
  }
  let of = fn(part : String) { fields.get(part).unwrap_or(@ui.Field::new()) }
  // the fields' words as they are now (what 保存 writes and what it waits for): a file's picked, a sign-in's cookies as
  // they were kept, never typed or shown here
  let words = fn() -> Map[String, String] {
    let out : Map[String, String] = Map([])
    for part, f in fields {
      out[part] = f.text()
    }
    let (content, name) = file.get()
    out["content"] = content
    out["filename"] = name
    out["cookies"] = text(field(was, "fields"), "cookies")
    out
  }
  let input = fn(b : @view.View, part : String, label : () -> String, placeholder : () -> String) {
    vd_input_node(b, of(part), part, label, placeholder)
  }
  let said = fn(key : String) { fn() { @sf.t(key) } }
  let closed : @signals.Signal[Bool] = @signals.signal(false)
  let is_revoked = fn() {
    closed.get() ||
    (match revoked {
      Some(r) => r.get()
      None => false
    })
  }
  let mark_revoked = fn() {
    closed.set(true)
    match revoked {
      Some(r) => r.set(true)
      None => ()
    }
  }
  let clear_fields = fn() {
    for _, f in fields {
      f.set("")
    }
    file.set(("", ""))
  }
  on_clear_handle(clear_fields)
  let title = match was {
    None => @sf.t("web-pages.vault.editor.new")
    Some(p) => text(Some(p), "name")
  }
  open_dialog_nodes(
    title,
    fn(v, shut) {
      let editor_id = next_vault_editor_id.val
      next_vault_editor_id.val = editor_id + 1
      active_vault_editors[editor_id] = (
        ws,
        target_vault,
        fn() {
          mark_revoked()
          clear_fields()
          shut()
        },
      )
      v.owns(fn() { active_vault_editors.remove(editor_id) }) |> ignore
      if plain {
        @sf.words_node(v, said("web-pages.vault.risk.editor"), fn() { vt_warn_lines }) |> ignore
      }
      if was is None && kinds {
        v.box(fn(s) {
          @sf.segmented_node(s, fn() { vault_kinds.map(fn(x) { @sf.t("web-pages.vault.kind." + x) }) }, fn() { chosen_kind.get() }, fn(i) {
            chosen_kind.set(i)
          })
        })
        |> ignore
      }
      if was is None && targets.length() > 1 {
        @sf.field_node(v, said("web-pages.vault.editor.saveTo"), fn(f) {
          f.box(fn(s) {
            @sf.segmented_node(s, fn() { targets.map(fn(t) { t.1 }) }, fn() { target_idx.get() }, fn(i) {
              target_idx.set(i)
            })
          })
          |> ignore
        })
      }
      input(v, "name", said("web-pages.vault.editor.name"), fn() {
        @sf.t(if k() == "file" { "web-pages.vault.editor.fileNamePlaceholder" } else { "web-pages.vault.editor.namePlaceholder" })
      })
      // a new one's: what it is for and how it is used (agents are shown it with its name, so never a secret in it);
      // one there already has its own, on its page (vault_about_dialog)
      if was is None {
        input(v, "about", said("web-pages.vault.editor.about"), said("web-pages.vault.editor.aboutPlaceholder"))
      }
      v.pick(fn() { if k() == "token" || k() == "ssh_key" || k() == "browser" || k() == "file" { k() } else { "login" } }, fn(p, what) {
        match what {
          "token" => vd_input_node(p, of("value"), "value", said("web-pages.vault.editor.value"), fn() { "ghp_…" }, secret=true)
          "ssh_key" => {
            vd_input_node(p, of("private_key"), "private_key", said("web-pages.vault.editor.privateKey"), fn() { "-----BEGIN OPENSSH PRIVATE KEY-----" }, area=true)
            input(p, "public_key", said("web-pages.vault.editor.publicKey"), fn() { "ssh-ed25519 AAAA…" })
          }
          // a sign-in: its cookies as they were kept, never typed or shown here
          "browser" => ()
          "file" =>
            @sf.field_node(p, said("web-pages.vault.editor.file"), fn(f) {
              // (the button the same before and after: what was picked comes in beside it, the row no higher)
              f.box(fn(r) {
                @sf.style_node(r, fn() { vd_file })
                @sf.button_node(r, said("web-pages.vault.editor.pickFile"), fn() {
                  pick_vault_file(core, fn(content, name) {
                    guard !@signals.untracked(is_revoked) else { return }
                    file.set((content, name))
                  })
                })
                |> ignore
                r.show(fn() { file.get().0 != "" }, fn(n) {
                  n.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
                  @sf.words_node(n, fn() {
                    let (content, name) = file.get()
                    (if name != "" { name } else { @sf.t("web-pages.vault.kind.file") }) + " · " + file_size(content)
                  }, fn() { vd_file_name })
                  |> ignore
                })
              })
              |> ignore
            })
          _ => {
            input(p, "username", said("web-pages.vault.editor.username"), fn() { "name@example.com" })
            vd_input_node(p, of("password"), "password", said("web-pages.vault.editor.password"), fn() { "" }, secret=true)
            vd_input_node(p, of("totp"), "totp", said("web-pages.vault.editor.totp"), fn() { "" }, secret=true)
          }
        }
      })
      // how agents may ask for it (agentBox)
      v.box(fn(a) {
        @sf.style_node(a, fn() { vd_agent })
        @sf.switch_row_node(a, said("web-pages.vault.editor.agent"), fn() { agent.get() }, fn(on) { agent.set(on) }, note=said(
            "web-pages.vault.editor.agentNote",
          ), in_words=true)
        a.show(fn() { agent.get() }, fn(o) {
          @sf.field_node(o, said("web-pages.vault.editor.how"), fn(f) {
            f.pick(fn() { k() == "ssh_key" || k() == "file" || k() == "browser" }, fn(p, one_way) {
              if one_way {
                @sf.words_node(p, fn() { mode_name(if k() == "file" { "file" } else if k() == "browser" { "browser" } else { "ssh" }) }, fn() {
                  @sf.card_body
                })
                |> ignore
              } else {
                p.box(fn(s) {
                  @sf.segmented_node(s, fn() { [mode_name("proxy"), mode_name("env")] }, fn() { if mode.get() == "env" { 1 } else { 0 } }, fn(i) {
                    mode.set(if i == 1 { "env" } else { "proxy" })
                  })
                })
                |> ignore
              }
            })
          })
          @sf.words_node(o, fn() {
            @sf.t(
              if k() == "ssh_key" {
                "web-pages.vault.editor.sshNote"
              } else if k() == "file" {
                "web-pages.vault.editor.fileNote"
              } else if k() == "browser" {
                "web-pages.vault.editor.browserNote"
              } else if mode.get() == "proxy" {
                "web-pages.vault.editor.proxyNote"
              } else {
                "web-pages.vault.editor.envNote"
              },
            )
          }, fn() { @sf.list_note })
          |> ignore
          o.show(fn() { (k() != "ssh_key" && k() != "file" && mode.get() == "proxy") || k() == "browser" }, fn(h) {
            vd_input_node(h, of("hosts"), "hosts", said("web-pages.vault.editor.hosts"), said("web-pages.vault.editor.hostsPlaceholder"), bad=fn() {
              let w = words()
              if w.get("hosts").unwrap_or("") != "" && vault_hosts(w).length() == 0 {
                @sf.t("web-pages.vault.editor.hostsNeeded")
              } else {
                ""
              }
            })
          })
          o.show(fn() { k() != "ssh_key" && k() != "browser" }, fn(e) {
            input(e, "env", said("web-pages.vault.editor.env"), fn() {
              @sf.t(if k() == "file" { "web-pages.vault.editor.fileEnvPlaceholder" } else { "web-pages.vault.editor.envPlaceholder" })
            })
          })
          @sf.field_node(o, said("web-pages.vault.editor.lasts"), fn(f) {
            f.box(fn(s) {
              @sf.segmented_node(s, fn() { vault_lasts.map(lasts_choice) }, fn() { lasts.get() }, fn(i) { lasts.set(i) })
            })
            |> ignore
          })
          @sf.words_node(o, said("web-pages.vault.editor.lastsNote"), fn() { @sf.list_note }) |> ignore
        })
      })
      |> ignore
      v.show(fn() { error.get() != "" }, fn(e) { @sf.words_node(e, fn() { error.get() }, fn() { @sf.list_note_bad }) |> ignore })
    },
    fn(v, shut) {
      let dismiss_editor = fn() {
        mark_revoked()
        clear_fields()
        shut()
      }
      match row {
        Some(r) => {
          let on = [("workspace", ws), ("vault", vault)]
          @sf.button_node(
            v,
            said("common.delete"),
            fn() {
              guard !@signals.untracked(is_revoked) else { return }
              confirm(
                @sf.t("web-pages.vault.deleteTitle", args=[("name", text(was, "name"))]),
                @sf.t("web-pages.vault.deleteBody"),
                @sf.t("common.delete"),
                danger=true,
                fn() {
                  guard !@signals.untracked(is_revoked) else { return }
                  dismiss_editor()
                  vault_act(core, ws, "deleteItem", [("vault", str(vault)), ("item", str(text(Some(r), "id")))], @sf.t("web-pages.vault.deleteWhat"), done=@sf.t(
                      "web-pages.vault.deleted",
                    ), then=fn(_) {
                    if can_pop() {
                      (core.pop)()
                    }
                  })
                },
              )
            },
            tone=GhostDanger,
            busy=fn() { is_doing(core, ["vault.deleteItem"], on) },
            disabled=is_revoked,
          )
          |> ignore
        }
        None => ()
      }
      @sf.foot_spacer_node(v)
      @sf.button_node(
        v,
        said("common.cancel"),
        fn() {
          v.focus_let_go()
          dismiss_editor()
        },
        tone=Ghost,
      )
      |> ignore
      @sf.button_node(
        v,
        said("common.save"),
        fn() {
          guard !@signals.untracked(is_revoked) else { return }
          saving.set(true)
          error.set("")
          v.focus_let_go()
          vault_act(
            core,
            ws,
            "putItem",
            vault_put_params(@signals.untracked(target_vault), row, was, k(), words(), agent.get(), mode.get(), vault_lasts[lasts.get()]),
            @sf.t("web-pages.vault.saveWhat"),
            done=@sf.t("web-pages.vault.saved"),
            then=fn(_) {
              saving.set(false)
              dismiss_editor()
            },
            failed=fn(err) {
              saving.set(false)
              // written elsewhere first: the vault was read again; what is here was written over that, so it goes
              if text(Some(err), "code") == "vault_conflict" {
                dismiss_editor()
              } else {
                error.set(vault_said(err).unwrap_or(""))
              }
            },
          )
        },
        tone=Primary,
        busy=fn() { saving.get() },
        disabled=fn() { is_revoked() || vault_problem(k(), words(), agent.get(), mode.get()) != "" },
      )
      |> ignore
    },
    on_gone=fn() {
      mark_revoked()
      clear_fields()
      on_gone()
    },
  )
}

///|
/// A field of an item being written (vault_editor_dialog's) in `b`: its label, its line (or lines: `area`; a secret's
/// dotted), `field` what it holds; what is wrong under it (`bad`, as it says now), or, for its about, that agents are
/// shown it (so no secret goes in it).
fn vd_input_node(
  b : @view.View,
  field : @ui.Field,
  part : String,
  label : () -> String,
  placeholder : () -> String,
  secret? : Bool = false,
  area? : Bool = false,
  bad? : () -> String = fn() { "" },
) -> Unit {
  let hint = fn() { if part == "about" { @sf.t("web-pages.vault.editor.aboutNote") } else { "" } }
  @sf.field_node(b, label, hint~, error=bad, fn(f) {
    if area {
      @sf.textarea_node(f, field, rows=if part == "about" { 3 } else { 5 }, placeholder_by=placeholder, label=@signals.untracked(label)) |> ignore
    } else {
      @sf.input_node(f, field, placeholder_by=placeholder, secret~, label=@signals.untracked(label)) |> ignore
    }
  })
}

///|
/// An item's about written on its own (说明, from its page): what it is for and how it is used, the rest of the item as
/// it was (`plain`: what it holds, opened; `row`: how agents may ask for it), written as the editor's 保存 writes it
/// (`vault.putItem`), the dialog staying while it is saved (refused, why under it).
pub fn vault_about_dialog(
  core : Core,
  ws : String,
  vault : String,
  row : Json,
  plain : Json,
  revoked? : @signals.Signal[Bool],
  on_clear_handle? : (() -> Unit) -> Unit = fn(_) {  },
  on_gone? : () -> Unit = fn() {  },
) -> Unit {
  let was = Some(plain)
  let rv = Some(row)
  let typed = @ui.Field::new(text=text(was, "notes"))
  on_clear_handle(fn() { typed.set("") })
  let saving : @signals.Signal[Bool] = @signals.signal(false)
  let error : @signals.Signal[String] = @signals.signal("")
  let closed : @signals.Signal[Bool] = @signals.signal(false)
  let is_revoked = fn() {
    closed.get() ||
    (match revoked {
      Some(r) => r.get()
      None => false
    })
  }
  let mark_revoked = fn() {
    closed.set(true)
    match revoked {
      Some(r) => r.set(true)
      None => ()
    }
  }
  let save = fn(shut : () -> Unit) {
    guard !@signals.untracked(is_revoked) else { return }
    let k = text(was, "kind")
    // (what it holds and how agents get it, as the editor would have them: only its about changed)
    let words : Map[String, String] = Map([])
    words["name"] = text(was, "name")
    match field(was, "fields") {
      Some(Object(fs)) =>
        for f, v in fs {
          match v {
            String(s) => words[f] = s
            _ => ()
          }
        }
      _ => ()
    }
    words["hosts"] = join(strings(rv, "hosts"), " ")
    words["env"] = text(rv, "env")
    words["about"] = typed.text()
    let mode = if strings(rv, "modes").contains("env") { "env" } else { "proxy" }
    let lasts = if text(rv, "lasts") == "" { "default" } else { text(rv, "lasts") }
    saving.set(true)
    error.set("")
    vault_act(
      core,
      ws,
      "putItem",
      vault_put_params(vault, rv, was, k, words, flag(rv, "listed"), mode, lasts),
      @sf.t("web-pages.vault.saveWhat"),
      done=@sf.t("web-pages.vault.saved"),
      then=fn(_) {
        saving.set(false)
        shut()
      },
      failed=fn(err) {
        saving.set(false)
        error.set(vault_said(err).unwrap_or(""))
      },
    )
  }
  open_dialog_nodes(
    @sf.t("web-pages.vault.editor.about"),
    fn(v, shut) {
      let editor_id = next_vault_editor_id.val
      next_vault_editor_id.val = editor_id + 1
      active_vault_editors[editor_id] = (
        ws,
        fn() { vault },
        fn() {
          mark_revoked()
          typed.set("")
          shut()
        },
      )
      v.owns(fn() { active_vault_editors.remove(editor_id) }) |> ignore
      @sf.field_node(
        v,
        fn() { @sf.t("web-pages.vault.editor.about") },
        hint=fn() { @sf.t("web-pages.vault.editor.aboutNote") },
        error=fn() { error.get() },
        fn(b) {
          @sf.textarea_node(b, typed, rows=3, placeholder=@sf.t("web-pages.vault.editor.aboutPlaceholder"), label=@sf.t("web-pages.vault.editor.about")) |> ignore
        },
      )
    },
    fn(v, shut) {
      let dismiss_about = fn() {
        mark_revoked()
        typed.set("")
        shut()
      }
      @sf.foot_spacer_node(v)
      @sf.button_node(
        v,
        fn() { @sf.t("common.cancel") },
        fn() {
          v.focus_let_go()
          dismiss_about()
        },
        tone=Ghost,
      )
      |> ignore
      @sf.button_node(
        v,
        fn() { @sf.t("common.save") },
        fn() {
          guard !@signals.untracked(is_revoked) else { return }
          v.focus_let_go()
          save(dismiss_about)
        },
        tone=Primary,
        busy=fn() { saving.get() },
        disabled=is_revoked,
      )
      |> ignore
    },
    on_gone=fn() {
      mark_revoked()
      typed.set("")
      on_gone()
    },
  )
}

///|
/// The recovery words typed in (Recover): this device keyed into the person's vaults again (`vault.recover`); how many
/// typed of 24 at the foot.
pub fn vault_recover_dialog(core : Core, ws : String) -> Unit {
  let typed = @ui.Field::new()
  let busy : @signals.Signal[Bool] = @signals.signal(false)
  let error : @signals.Signal[String] = @signals.signal("")
  let count_of = fn() { typed.text().replace_all(old="\n", new=" ").split(" ").filter(fn(w) { w != "" }).count() }
  open_dialog_nodes(
    @sf.t("web-pages.vault.recover"),
    description=@sf.t("web-pages.vault.recoverLead"),
    fn(v, _) {
      @sf.textarea_node(v, typed, rows=4, label=@sf.t("web-pages.vault.recover")) |> ignore
      v.show(fn() { error.get() != "" }, fn(e) { @sf.words_node(e, fn() { error.get() }, fn() { @sf.list_note_bad }) |> ignore })
    },
    fn(v, shut) {
      @sf.words_node(v, fn() { "\{count_of()} / 24" }, fn() { @sf.list_note }) |> ignore
      @sf.foot_spacer_node(v)
      @sf.button_node(
        v,
        fn() { @sf.t("common.cancel") },
        fn() {
          v.focus_let_go()
          shut()
        },
        tone=Ghost,
      )
      |> ignore
      // (its button's words short beside the count and 取消 on a phone: the dialog's title says what it is)
      @sf.button_node(
        v,
        fn() { @sf.t("web-pages.vault.recoverGo") },
        fn() {
          busy.set(true)
          error.set("")
          let words = typed.text().trim(chars=" \n").to_lower().to_owned()
          (core.call)("vault.recover", obj([("workspace", str(ws)), ("words", str(words))]), fn(r) {
            busy.set(false)
            match r {
              Ok(got) => {
                let n = count(Some(got), "recovered")
                (core.say)(
                  if n > 0 {
                    @sf.t("web-pages.vault.recovered", args=[("n", n.to_string())])
                  } else {
                    @sf.t("web-pages.vault.recoveredNone")
                  },
                )
                if n > 0 {
                  shut()
                }
              }
              Err(e) => error.set(vault_said(e).unwrap_or(""))
            }
          })
        },
        tone=Primary,
        busy=fn() { busy.get() },
        disabled=fn() { count_of() != 24 },
      )
      |> ignore
    },
  )
}

///|
/// Workspace vault member management dialog: admins can toggle workspace members (self disabled) and save via
/// `vault.setMembers` (showing a key-rotation notice whenever any existing member is unchecked); non-admins see a
/// read-only list of current shared members.
pub fn vault_members_dialog(core : Core, here : Here, rv : Json?) -> Unit {
  let ws = here.workspace
  let my_sub = here.sub
  let vault_id = text(rv, "id")
  let initial = vault_member_subs(rv)
  let can_manage = vault_can_manage(rv)
  let ws_members = fn() {
    items((core.topic)("workspace", { "workspace": str(ws) }).get().value, "members")
  }
  let selected : @signals.Signal[Array[String]] = @signals.signal(initial.copy())
  let saving : @signals.Signal[Bool] = @signals.signal(false)
  let error : @signals.Signal[String] = @signals.signal("")
  let changed = fn() {
    let cur = selected.get()
    if cur.length() != initial.length() {
      return true
    }
    for i = 0; i < cur.length(); i = i + 1 {
      if !initial.contains(cur[i]) {
        return true
      }
    }
    false
  }
  let has_removed = fn() {
    let cur = selected.get()
    for i = 0; i < initial.length(); i = i + 1 {
      if !cur.contains(initial[i]) {
        return true
      }
    }
    false
  }
  open_dialog_nodes(
    @sf.t("web-pages.vault.members.dialogTitle"),
    fn(v, _) {
      if can_manage {
        @sf.group_node(v, fn(g) {
          g.each(ws_members, fn(m) { text(Some(m), "sub") }, fn(row, m) {
            let mv = fn() { Some(m.get()) }
            let sub = fn() { text(mv(), "sub") }
            let is_me = fn() { my_sub != "" && sub() == my_sub }
            let title = fn() {
              let n = text(mv(), "name")
              if n != "" { n } else { text(mv(), "email") }
            }
            let note = fn() {
              if is_me() {
                @sf.t("web-pages.vault.members.you")
              } else {
                text(mv(), "email")
              }
            }
            @sf.switch_row_node(
              row,
              title,
              fn() { selected.get().contains(sub()) },
              fn(on) {
                let id = @signals.untracked(sub)
                let cur = selected.untracked()
                if on {
                  if !cur.contains(id) {
                    let next = cur.copy()
                    next.push(id)
                    selected.set(next)
                  }
                } else if cur.contains(id) {
                  selected.set(cur.filter(fn(x) { x != id }))
                }
              },
              note~,
              disabled=fn() { is_me() || saving.get() },
            )
          })
        })
        v.show(has_removed, fn(s) {
          @sf.words_node(s, fn() { @sf.t("web-pages.vault.members.rekeyNote") }, fn() { vd_note }) |> ignore
        })
        v.show(fn() { error.get() != "" }, fn(e) {
          @sf.words_node(e, fn() { error.get() }, fn() { vd_note_bad }) |> ignore
        })
      } else {
        let shown = fn() {
          let from_ws = ws_members().filter(fn(m) { initial.contains(text(Some(m), "sub")) })
          if from_ws.length() > 0 {
            from_ws
          } else {
            items(rv, "members")
          }
        }
        @sf.group_node(v, fn(g) {
          g.each(shown, fn(m) { text(Some(m), "sub") }, fn(row, m) {
            let mv = fn() { Some(m.get()) }
            let title = fn() {
              let n = text(mv(), "name")
              if n != "" {
                n
              } else {
                let e = text(mv(), "email")
                if e != "" { e } else { text(mv(), "sub") }
              }
            }
            @sf.link_row_node(row, title, fn() {  }, note=fn() { text(mv(), "email") }, goes=false)
          })
        })
      }
    },
    fn(v, shut) {
      @sf.foot_spacer_node(v)
      if can_manage {
        @sf.button_node(
          v,
          fn() { @sf.t("common.cancel") },
          fn() { shut() },
          tone=Ghost,
          disabled=fn() { saving.get() },
        )
        |> ignore
        @sf.button_node(
          v,
          fn() { @sf.t("common.save") },
          fn() {
            saving.set(true)
            error.set("")
            vault_act(
              core,
              ws,
              "setMembers",
              [("vault", str(vault_id)), ("members", Json::array(selected.untracked().map(str)))],
              @sf.t("web-pages.vault.members.saveWhat"),
              done=@sf.t("web-pages.vault.members.saved"),
              then=fn(_) {
                saving.set(false)
                shut()
              },
              failed=fn(err) {
                saving.set(false)
                error.set(vault_said(err).unwrap_or(""))
              },
            )
          },
          tone=Primary,
          busy=fn() { saving.get() },
          disabled=fn() { !changed() || saving.get() },
        )
        |> ignore
      } else {
        @sf.button_node(v, fn() { @sf.t("common.close") }, fn() { shut() }, tone=Primary) |> ignore
      }
    },
  )
}

///|
/// Formats a device row's subtitle (`核对码 K7M-4PX · 林 · 3 分钟前`), omitting absent parts.
fn vd_device_meta(dv : Json?) -> String {
  let parts : Array[String] = []
  let code = text(dv, "deviceCode")
  if code != "" {
    parts.push(@sf.t("web-pages.vault.devicesDialog.codePrefix", args=[("code", code)]))
  }
  let owner = text(dv, "ownerName")
  if owner != "" {
    parts.push(owner)
  }
  let at = text(dv, "atText")
  if at != "" {
    parts.push(at)
  }
  parts.join(" · ")
}

///|
/// Per-vault devices detail dialog: reactively lists pending devices (each with its own single-device
/// `vault.addDevice` authorize button aligned to the first line) and authorized devices, with a graceful
/// fallback for older cores that omit device arrays.
pub fn vault_devices_dialog(core : Core, here : Here, vault_id : String) -> Unit {
  let ws = here.workspace
  let rv = fn() {
    items((core.topic)("vaults", { "workspace": str(ws) }).get().value, "vaults")
    .iter()
    .find_first(fn(r) { text(Some(r), "id") == vault_id })
  }
  let initial_name = text(@signals.untracked(rv), "name")
  let title = if initial_name != "" {
    @sf.t("web-pages.vault.devicesDialog.title", args=[("name", initial_name)])
  } else {
    @sf.t("web-pages.vault.devicesDialog.titleFallback")
  }
  let pending = fn() { items(rv(), "pendingDevices") }
  let authorized = fn() { items(rv(), "authorizedDevices") }
  let can_give = fn() { vault_can_manage(rv()) && flag(rv(), "keyed") }
  open_dialog_nodes(
    title,
    fn(v, _) {
      v.show(fn() { !pending().is_empty() }, fn(sec) {
        @sf.style_node(sec, fn() { vd_dev_section })
        @sf.words_node(sec, fn() { @sf.t("web-pages.vault.devicesDialog.pendingTitle") }, fn() {
          @sf.meta.then(@sf.strong).then(@sf.full_words)
        })
        |> ignore
        @sf.words_node(sec, fn() { @sf.t("web-pages.vault.devicesDialog.pendingNote") }, fn() { @sf.pg_note }) |> ignore
        @sf.group_node(sec, fn(g) {
          g.each(pending, fn(d) { text(Some(d), "device") }, fn(row, d) {
            let dv = fn() { Some(d.get()) }
            let dev_id = @signals.untracked(fn() { text(dv(), "device") })
            let is_first = fn() { pending().get(0).map(fn(x) { text(Some(x), "device") }) == Some(dev_id) }
            let busy = fn() { is_doing(core, ["vault.addDevice"], [("workspace", ws), ("vault", vault_id), ("device", dev_id)]) }
            let press = fn() {
              vault_act(
                core,
                ws,
                "addDevice",
                [("vault", str(vault_id)), ("device", str(dev_id))],
                @sf.t("web-pages.vault.addDeviceWhat"),
                done=@sf.t("web-pages.vault.addedDevice"),
              )
            }
            @sf.link_row_node(
              row,
              fn() { text(dv(), "deviceText") },
              fn() {  },
              note=fn() { vd_device_meta(dv()) },
              goes=false,
              chevron=false,
              control=fn(c) {
                c.show(can_give, fn(btn) {
                  btn.pick(is_first, fn(p, first) {
                    if first {
                      @sf.row_corner_button_node(p, fn() { @sf.t("web-pages.vault.devicesDialog.authorize") }, press, busy~) |> ignore
                    } else {
                      @sf.row_end_button_node(p, fn() { @sf.t("web-pages.vault.devicesDialog.authorize") }, press, busy~) |> ignore
                    }
                  })
                })
              },
            )
          })
        })
      })
      v.show(fn() { !authorized().is_empty() }, fn(sec) {
        @sf.style_node(sec, fn() { vd_dev_section })
        @sf.words_node(sec, fn() { @sf.t("web-pages.vault.devicesDialog.authorizedTitle") }, fn() {
          @sf.meta.then(@sf.strong).then(@sf.full_words)
        })
        |> ignore
        @sf.group_node(sec, fn(g) {
          g.each(authorized, fn(d) { text(Some(d), "device") }, fn(row, d) {
            let dv = fn() { Some(d.get()) }
            let dev_title = fn() {
              let name = text(dv(), "deviceText")
              if flag(dv(), "current") {
                @sf.t("web-pages.vault.devicesDialog.current", args=[("device", name)])
              } else {
                name
              }
            }
            @sf.link_row_node(row, dev_title, fn() {  }, note=fn() { vd_device_meta(dv()) }, goes=false)
          })
        })
      })
      v.show(fn() { pending().is_empty() && authorized().is_empty() }, fn(fallback) {
        @sf.style_node(fallback, fn() { vd_dev_section })
        @sf.words_node(
          fallback,
          fn() { @sf.t("web-pages.vault.devicesHold", args=[("n", count(rv(), "devices").to_string())]) },
          fn() { @sf.pg_note },
        )
        |> ignore
        fallback.show(fn() { count(rv(), "missing") > 0 }, fn(m) {
          @sf.words_node(m, fn() { @sf.t("web-pages.vault.devicesDialog.legacyPendingNote") }, fn() { @sf.pg_note }) |> ignore
        })
      })
    },
    fn(v, shut) {
      @sf.foot_spacer_node(v)
      @sf.button_node(v, fn() { @sf.t("common.close") }, fn() { shut() }, tone=Primary) |> ignore
    },
  )
}

///|
/// Vertical stack for each section inside the vault devices dialog.
// kept across runs: a value (no field of it changes)
let vd_dev_section : @ui.Style = @ui.css("w=Full gap=S2")

///|
/// (a file: its name and size, then the button that picks another, 12 apart)
// kept across runs: a value (no field of it changes)
let vd_file : @ui.Style = @ui.css("row w=Full gap=S3 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let vd_file_name : @ui.TextStyle = @ui.text_style(size=Ui, leading=L5, color=Fg, wrap=false, w=Cut)

///|
/// (agentBox: the switch and what it opens, 10 apart, 4 over them)
// kept across runs: a value (no field of it changes)
let vd_agent : @ui.Style = @ui.css("w=Full gap=S2_5 pt=S1")

///|
/// (warn: the amber, the meta's size, in lines)
// kept across runs: a value (no field of it changes)
let vt_warn_lines : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=WarnInk, w=Full)

///|
// kept across runs: a value (no field of it changes)
let vd_note : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, w=Full)

///|
// kept across runs: a value (no field of it changes)
let vd_note_bad : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Danger, w=Full)
