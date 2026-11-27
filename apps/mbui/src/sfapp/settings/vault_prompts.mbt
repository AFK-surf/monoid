// A member's device whose person pressed 申请授权 for a vault this device holds the key to (the core's `lockPrompts`
// topic's `asks`, views/vault.ts `vaultAsks`: the topic every page has open and every recorded run asks, so no topic
// of its own; the lock's own prompts are lock_prompts.mbt): put up over whichever page is open, in any workspace of
// the person's, once, until given the key here (授权: `vault.addDevice {vault, device}`, this device's key unsealed,
// the person asked once) or put away (稍后, a tap beside it: `vault.hidePrompt {vault, device, at}`, put up again
// once that device asks for that vault again with a later timestamp). Given the key on another device, it goes by itself.

///|
/// Full-precision ask timestamp (`Double`, avoiding 32-bit `Int` narrowing on timestamps past 2038).
fn key_ask_at(rv : Json?) -> Double {
  match field(rv, "at") {
    Some(Number(n, ..)) => n
    _ => 0.0
  }
}

///|
/// The asks put up here (a device, a vault and when it asked, `key_ask_of`), then put away: not put up again while the
/// core has yet to drop them. The same device asking again (dated later) is put up again. What the core dropped is
/// forgotten here too.
let key_asks_closed : Array[String] = []

///|
fn key_ask_of(r : Json) -> String {
  text(Some(r), "workspace") + " " + text(Some(r), "vault") + " " + text(Some(r), "device") + " " + key_ask_at(Some(r)).to_string()
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
  let mut waiting : Json? = None
  for r in asks {
    if !key_asks_closed.contains(key_ask_of(r)) {
      waiting = Some(r)
      break
    }
  }
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
    (core.call)(
      "vault.hidePrompt",
      obj([("workspace", str(ws)), ("vault", str(vault)), ("device", str(device)), ("at", Json::number(key_ask_at(rv)))]),
      answer_unread,
    )
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
  @sf.panel_nodes(tr("web-pages.vault.promptTitle"), from=Unanchored, gone=hide, foot~, fn(v, close) {
    // given the key elsewhere, or put away there: gone here too, as the core says so
    prompt_goes(v, fn() { prompt_now(core, "asks", fn(x) { key_ask_of(x) == ask }) }, close)
    let safe_mode = match field(rv, "safeMode") {
      Some(False) => false
      _ => true
    }
    let device_text = text(rv, "deviceText")
    let dev_code = text(rv, "deviceCode")
    let owner_name = text(rv, "ownerName")
    let owner_email = text(rv, "ownerEmail")
    let owner_who = if owner_name != "" { owner_name } else { owner_email }
    let is_own = flag(rv, "isOwnDevice")
    // (a teammate's device asking for a workspace vault's key is never one of this person's trusted devices:
    // use ownerName -> ownerEmail -> generic non-self fallback, never falling back to promptBodyNoSafeMode)
    let body_key = if safe_mode {
      "web-pages.vault.promptBody"
    } else if !is_own && owner_who != "" {
      "web-pages.vault.promptBodyTheirs"
    } else if !is_own {
      "web-pages.vault.promptBodyTheirsUnknown"
    } else {
      "web-pages.vault.promptBodyNoSafeMode"
    }
    let at_text = text(rv, "atText")
    let has_info = device_text != "" || dev_code != "" || owner_who != "" || at_text != ""
    let has_items = field(rv, "vaultItems") is Some(Number(_))
    let item_count = count(rv, "vaultItems")
    let is_ws_vault = text(rv, "vaultScope") == "workspace"
    v.box(fn(col) {
      @sf.style_node(col, fn() { key_ask_column })
      // Prominent verification card at top of body: variable-length device name & verification code stand out clearly
      // for careful human inspection rather than wrapping inside the header title.
      if has_info {
        col.box(fn(info) {
          @sf.style_node(info, fn() { key_ask_info.then(@sf.panel_card_out_node(info)) })
          info.radius(Is(@sf.quiet_card_corner)) |> ignore
          if device_text != "" {
            info.box(fn(block) {
              @sf.style_node(block, fn() { key_ask_field })
              @sf.words_node(block, fn() { tr("web-pages.vault.promptDevice") }, fn() { key_ask_label }) |> ignore
              @sf.words_node(block, fn() { device_text }, fn() { key_ask_device }) |> ignore
            })
            |> ignore
          }
          if dev_code != "" {
            info.box(fn(block) {
              @sf.style_node(block, fn() { key_ask_field })
              @sf.words_node(block, fn() { tr("web-pages.vault.promptDeviceCode") }, fn() { key_ask_label }) |> ignore
              block.box(fn(code_line) {
                @sf.style_node(code_line, fn() { key_ask_line })
                code_line
                .words_runs(
                  By(fn() { [@ui.span(dev_code, mono=true, bold=true, color=@sf.theme().p.text)] }),
                  look=@ui.style_words(key_ask_code),
                )
                |> ignore
              })
              |> ignore
            })
            |> ignore
          }
          if owner_who != "" {
            let owner_text = fn() {
              let base = if is_own {
                fill("web-pages.vault.promptOwnerSelf", [("name", owner_who)])
              } else {
                owner_who
              }
              if owner_email != "" && owner_email != owner_who {
                base + " · " + owner_email
              } else {
                base
              }
            }
            info.box(fn(line) {
              @sf.style_node(line, fn() { key_ask_kv })
              line.wraps(Is(Some(2.0))) |> ignore
              @sf.words_node(line, fn() { tr("web-pages.vault.promptOwner") }, fn() { key_ask_kv_key }).shrink(Is(0.0)) |> ignore
              @sf.words_node(line, owner_text, fn() { key_ask_kv_val }).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
            })
            |> ignore
          }
          if at_text != "" {
            info.box(fn(line) {
              @sf.style_node(line, fn() { key_ask_kv })
              line.wraps(Is(Some(2.0))) |> ignore
              @sf.words_node(line, fn() { tr("web-pages.vault.promptAskedAt") }, fn() { key_ask_kv_key }).shrink(Is(0.0)) |> ignore
              @sf.words_node(line, fn() { at_text }, fn() { key_ask_kv_val }).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
            })
            |> ignore
          }
        })
        |> ignore
      }
      @sf.words_node(col, fn() { fill(body_key, [("vault", text(rv, "vaultName")), ("at", at_text), ("owner", owner_who)]) }, fn() {
        key_ask_body
      })
      |> ignore
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
/// Concentric quiet verification card (`bg=A(Fg,O5)`, `card_radius`, `panel_card_in` from panel edges)
/// highlighting the requesting device, verification code, owner, and request time.
// kept across runs: a value (no field of it changes)
let key_ask_info : @ui.Style = @ui.css("w=Full p=S4 gap=S2_5 bg=A(Fg,O5) clip")

///|
/// Stacked label + prominent value inside the verification block.
// kept across runs: a value (no field of it changes)
let key_ask_field : @ui.Style = @ui.css("w=Full gap=S0_5")

///|
/// Key-value row inside the info block (label + value separated by 8pt gap, wrapping cleanly).
// kept across runs: a value (no field of it changes)
let key_ask_kv : @ui.Style = @ui.css("row w=Full gap=S2 align=AFirstLine")

///|
// kept across runs: a value (no field of it changes)
let key_ask_kv_key : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted)

///|
// kept across runs: a value (no field of it changes)
let key_ask_kv_val : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg)

///|
/// Full-width line holder inside the info block so inline runs wrap cleanly.
// kept across runs: a value (no field of it changes)
let key_ask_line : @ui.Style = @ui.css("w=Full")

///|
/// The vault name and its scope/item-count summary, 4 apart.
// kept across runs: a value (no field of it changes)
let key_ask_scope : @ui.Style = @ui.css("w=Full gap=S1")

///|
/// Field caption label inside the verification block.
// kept across runs: a value (no field of it changes)
let key_ask_label : @ui.TextStyle = @ui.text_style(size=Caption, color=Muted, w=Full)

///|
/// Requesting device name highlighted prominently in the body so users read it carefully.
// kept across runs: a value (no field of it changes)
let key_ask_device : @ui.TextStyle = @ui.text_style(size=Title, weight=Semibold, color=Fg, w=Full)

///|
/// Verification code display style (large bold monospace with wide tracking).
// kept across runs: a value (no field of it changes)
let key_ask_code : @ui.TextStyle = @ui.text_style(size=Heading, weight=Bold, color=Fg, tracking=Wider, w=Full)

///|
/// Which device asks what (14 in the muted).
// kept across runs: a value (no field of it changes)
let key_ask_body : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, w=Full)

///|
/// The workspace and vault it asks the key to (16 semibold).
// kept across runs: a value (no field of it changes)
let key_ask_where : @ui.TextStyle = @ui.text_style(size=Title, weight=Semibold, color=Fg)
