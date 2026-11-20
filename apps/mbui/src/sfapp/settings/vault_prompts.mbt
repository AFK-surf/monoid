// A member's device set up without the key to a vault of the person's own, waiting on this one for it (the core's
// `lockPrompts` topic's `asks`, views/vault.ts `vaultAsks`: the topic every page has open and every recorded run asks, so no
// topic of its own; the lock's own prompts are lock_prompts.mbt): put up over whichever page is open, in any
// workspace of the person's, once, until given the key here (授权: `vault.addDevice {vault, device}`, this device's key
// unsealed, the person asked once) or put away (稍后, a tap beside it: `vault.hidePrompt {device}`, put up again once that
// device asks again: a certificate dated later). Given the key on another device, it goes by itself.

///|
/// The asks put up here (a device, a vault and when it asked, `key_ask_of`), then put away: not put up again while the
/// core has yet to drop them. The same device asking again (dated later) is put up again. What the core dropped is
/// forgotten here too.
let key_asks_closed : Array[String] = []

///|
fn key_ask_of(r : Json) -> String {
  text(Some(r), "workspace") + " " + text(Some(r), "vault") + " " + text(Some(r), "device") + " " + count(Some(r), "at").to_string()
}

///|
fn vault_prompts_reset() -> Unit {
  key_asks_closed.clear()
}

///|
/// The latest device waiting on this one for a key, put up in a sheet when nothing else is (`free`: no sheet of the
/// app's up): done as what it reads changes, over the pages (sfapp's signed_in_prompts).
pub fn vault_prompts(core : Core, free : Bool) -> Unit {
  let prompts = (core.topic)("lockPrompts", Map([])).get().value
  let asks = items(prompts, "asks")
  if prompts is Some(_) {
    key_asks_closed.retain(fn(d) { asks.iter().any(fn(r) { key_ask_of(r) == d }) })
  }
  let waiting = asks.iter().find_first(fn(r) { !key_asks_closed.contains(key_ask_of(r)) })
  match waiting {
    Some(r) if free && !@sf.presenting() => key_ask_sheet(core, r)
    _ => ()
  }
}

///|
/// The sheet of a device asking for a key: which device and which vault (its workspace named too), that giving it
/// unlocks here once; 稍后 and 授权 (primary) in its foot. Gone by itself once that device has the key (given here or elsewhere) or
/// asks no more. What it holds is nodes of the window's tree, made once as it opens (@sf.panel_nodes).
fn key_ask_sheet(core : Core, r : Json) -> Unit {
  let rv = Some(r)
  let ws = text(rv, "workspace")
  let vault = text(rv, "vault")
  let device = text(rv, "device")
  let ask = key_ask_of(r)
  // (put up once: closed by hand or by the core's drop alike, not again)
  key_asks_closed.push(ask)
  let on = [("workspace", ws), ("vault", vault), ("device", device)]
  let hide = fn() {
    (core.call)("vault.hidePrompt", obj([("workspace", str(ws)), ("device", str(device)), ("at", Json::number(count(rv, "at").to_double()))]), answer_unread)
  }
  let giving = fn() { is_doing(core, ["vault.addDevice"], on) }
  // 稍后 then 授权 in the panel's foot: side by side across a sheet's, at a dialog's end in its corner (panel_nodes')
  let foot = fn(v, close : () -> Unit) {
    @sf.button_node(
      v,
      fn() { tr("web-pages.vault.promptLater") },
      fn() {
        close()
        hide()
      },
      disabled=giving,
    )
    |> ignore
    @sf.button_node(
      v,
      fn() { tr("web-pages.vault.promptGive") },
      fn() {
        act(core, tr("web-pages.vault.addDeviceWhat"), "vault.addDevice", obj([("workspace", str(ws)), ("vault", str(vault)), ("device", str(device))]), done=tr("web-pages.vault.addedDevice"))
      },
      tone=Primary,
      busy=giving,
    )
    |> ignore
  }
  @sf.panel_nodes(fill("web-pages.vault.promptTitle", [("device", text(rv, "deviceText"))]), from=Unanchored, gone=hide, foot~, fn(v, close) {
    // given the key elsewhere, or put away there: gone here too, as the core says so
    prompt_goes(v, fn() { prompt_now(core, "asks", fn(x) { key_ask_of(x) == ask }) }, close)
    let safe_mode = match field(rv, "safeMode") {
      Some(False) => false
      _ => true
    }
    let body_key = if safe_mode { "web-pages.vault.promptBody" } else { "web-pages.vault.promptBodyNoSafeMode" }
    let dev_code = text(rv, "deviceCode")
    let owner_name = text(rv, "ownerName")
    let owner_email = text(rv, "ownerEmail")
    let is_own = flag(rv, "isOwnDevice")
    let at_text = text(rv, "atText")
    let has_info = dev_code != "" || owner_name != "" || at_text != ""
    let has_items = field(rv, "vaultItems") is Some(Number(_))
    let item_count = count(rv, "vaultItems")
    let is_ws_vault = text(rv, "vaultScope") == "workspace"
    v.box(fn(col) {
      @sf.style_node(col, fn() { key_ask_column })
      @sf.words_node(col, fn() { fill(body_key, [("vault", text(rv, "vaultName")), ("at", at_text)]) }, fn() {
        key_ask_body
      })
      |> ignore
      if has_info {
        col.box(fn(info) {
          @sf.style_node(info, fn() { key_ask_info })
          if dev_code != "" {
            info.box(fn(line) {
              @sf.style_node(line, fn() { key_ask_line })
              line
              .words_runs(
                By(fn() {
                  [
                    @ui.span(tr("web-pages.vault.promptDeviceCode") + "  ", color=@sf.theme().p.muted),
                    @ui.span(dev_code, mono=true, bold=true, color=@sf.theme().p.text),
                  ]
                }),
                look=@ui.style_words(key_ask_body),
              )
              |> ignore
            })
            |> ignore
          }
          if owner_name != "" {
            let owner_text = fn() {
              let base = if is_own {
                fill("web-pages.vault.promptOwnerSelf", [("name", owner_name)])
              } else {
                owner_name
              }
              if owner_email != "" && owner_email != owner_name {
                base + " · " + owner_email
              } else {
                base
              }
            }
            info.box(fn(line) {
              @sf.style_node(line, fn() { key_ask_line })
              line
              .words_runs(
                By(fn() {
                  [
                    @ui.span(tr("web-pages.vault.promptOwner") + "  ", color=@sf.theme().p.muted),
                    @ui.span(owner_text(), color=@sf.theme().p.text),
                  ]
                }),
                look=@ui.style_words(key_ask_body),
              )
              |> ignore
            })
            |> ignore
          }
          if at_text != "" {
            info.box(fn(line) {
              @sf.style_node(line, fn() { key_ask_line })
              line
              .words_runs(
                By(fn() {
                  [
                    @ui.span(tr("web-pages.vault.promptAskedAt") + "  ", color=@sf.theme().p.muted),
                    @ui.span(at_text, color=@sf.theme().p.text),
                  ]
                }),
                look=@ui.style_words(key_ask_body),
              )
              |> ignore
            })
            |> ignore
          }
        })
        |> ignore
      }
      col.box(fn(scope) {
        @sf.style_node(scope, fn() { key_ask_scope })
        @sf.words_node(scope, fn() { text(rv, "workspaceName") + " · " + text(rv, "vaultName") }, fn() { key_ask_where }) |> ignore
        @sf.words_node(
          scope,
          fn() {
            match (is_ws_vault, has_items) {
              (true, true) => fill("web-pages.vault.promptScopeWorkspaceItems", [("n", item_count.to_string())])
              (true, false) => tr("web-pages.vault.promptScopeWorkspace")
              (false, true) => fill("web-pages.vault.promptScopePersonalItems", [("n", item_count.to_string())])
              (false, false) => tr("web-pages.vault.promptScopePersonal")
            }
          },
          fn() { key_ask_body },
        )
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
}

///|
/// What the panel holds, 12 apart (pair_column's).
// kept across runs: a value (no field of it changes)
let key_ask_column : @ui.Style = @ui.css("w=Full gap=S3")

///|
/// Lightweight tinted block for device verification code, owner, and request time.
// kept across runs: a value (no field of it changes)
let key_ask_info : @ui.Style = @ui.css("w=Full px=S3 py=S2_5 gap=S1_5 radius=Md bg=Tint")

///|
/// Full-width line holder inside the info block so inline runs wrap cleanly.
// kept across runs: a value (no field of it changes)
let key_ask_line : @ui.Style = @ui.css("w=Full")

///|
/// The vault name and its scope/item-count summary, 4 apart.
// kept across runs: a value (no field of it changes)
let key_ask_scope : @ui.Style = @ui.css("w=Full gap=S1")

///|
/// Which device asks what (14 in the muted).
// kept across runs: a value (no field of it changes)
let key_ask_body : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, w=Full)

///|
/// The workspace and vault it asks the key to (16 semibold).
// kept across runs: a value (no field of it changes)
let key_ask_where : @ui.TextStyle = @ui.text_style(size=Title, weight=Semibold, color=Fg)
