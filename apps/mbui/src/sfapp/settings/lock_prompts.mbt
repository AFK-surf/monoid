// A new device showing this one's code (pairSheet; the core's `lockPrompts`, views/pair.ts):
// put up over whichever page is open, in any workspace of the person's, once (the library's panel: what is put up
// after it stands over it), until it is done or turned away. Nothing here approves it, only the code typed on the new device; turned away (拒绝),
// it is denied (`lockPrompt.deny`) and its code is worth nothing; closed by hand (a tap beside it, back), it is no
// longer shown (`lockPrompt.hide`) and its code still holds: read by then, it is typed on the new device next.

///|
/// The asks put up here (a device and the code it was shown, `ask_of`), then turned away or closed: not put up again while the core
/// has yet to drop them. The same device asking again (a new code) is put up again: it was not until the app started
/// again (2026-10-23, 弹窗不弹). What the core dropped is forgotten here too.
let prompts_closed : Array[String] = []

///|
fn ask_of(r : Json) -> String {
  text(Some(r), "device") + " " + text(Some(r), "code")
}

///|
fn lock_prompts_reset() -> Unit {
  prompts_closed.clear()
}

///|
/// The oldest device waiting on this one's code, put up in a sheet when nothing else is (`free`: no sheet of the
/// app's up): done as what it reads changes, over the pages (sfapp's signed_in_prompts).
pub fn lock_prompts(core : Core, free : Bool) -> Unit {
  let prompts = (core.topic)("lockPrompts", Map([])).get().value
  let pairing = items(prompts, "pairing")
  if prompts is Some(_) {
    prompts_closed.retain(fn(d) { pairing.iter().any(fn(r) { ask_of(r) == d }) })
  }
  let waiting = pairing.iter().find_first(fn(r) { !prompts_closed.contains(ask_of(r)) })
  match waiting {
    Some(r) if free && !@sf.presenting() => pair_sheet(core, r)
    _ => ()
  }
}

///|
/// The sheet of a new device asking: whose it is and what, where it asks to be let in, the code
/// large, that it is shown only here, 拒绝. Gone by itself once that device is done or turned away elsewhere. What it
/// holds is nodes of the window's tree, made once as it opens (@sf.panel_nodes).
fn pair_sheet(core : Core, r : Json) -> Unit {
  let rv = Some(r)
  let device = text(rv, "device")
  // (put up once: closed by hand or by the core's drop alike, not again)
  prompts_closed.push(ask_of(r))
  let deny = fn() {
    act(core, tr("web-pages.security.denyDevice"), "lockPrompt.deny", obj([("device", str(device))]))
  }
  let hide = fn() {
    (core.call)("lockPrompt.hide", obj([("device", str(device))]), answer_unread)
  }
  let who = match text(rv, "name") {
    "" => text(rv, "email")
    n => n
  }
  // 拒绝 in the panel's foot: across a sheet's, at a dialog's end in its corner (panel_nodes')
  let foot = fn(v, close : () -> Unit) {
    @sf.button_node(v, fn() { tr("web-pages.security.pairDeny") }, fn() {
      close()
      deny()
    })
    |> ignore
  }
  @sf.panel_nodes(fill("web-pages.security.pairTitle", [("name", who)]), from=Unanchored, gone=hide, foot~, fn(v, close) {
    // done or turned away on another device: gone here too, as the core says so; asked in one more workspace
    // meanwhile, named too (what it shows bound to the ask as the core holds it now, as it was put up till then)
    let now = fn() { prompt_now(core, "pairing", fn(x) { text(Some(x), "device") == device }) }
    prompt_goes(v, now, close)
    let shown = fn() -> Json? {
      match now() {
        Some(Some(x)) => Some(x)
        _ => rv
      }
    }
    let places = fn() { items(shown(), "workspaces") }
    let handover = fn() { items(shown(), "handoverVaults") }
    let has_meta = fn() {
      let s = shown()
      text(s, "deviceCode") != "" || text(s, "build") != "" || (text(s, "email") != "" && text(s, "email") != text(s, "name"))
    }
    let has_grants = fn() { flag(shown(), "willSign") || !handover().is_empty() }
    v.box(fn(col) {
      @sf.style_node(col, fn() { pair_column })
      @sf.words_node(col, fn() { fill("web-pages.security.pairBody", [("device", text(shown(), "deviceText"))]) }, fn() { pair_body }) |> ignore
      // device verification code, client build, and requester email (when present)
      col.show(has_meta, fn(m) {
        @sf.style_node(m, fn() { pair_meta_box })
        m.show(fn() { text(shown(), "deviceCode") != "" }, fn(line) {
          @sf.style_node(line, fn() { pair_meta_line })
          line
          .words_runs(
            By(fn() {
              [
                @ui.span(tr("web-pages.security.pairDeviceCode"), color=@sf.theme().p.muted),
                @ui.span(text(shown(), "deviceCode"), mono=true, bold=true, color=@sf.theme().p.text),
              ]
            }),
            look=@ui.style_words(pair_body),
          )
          |> ignore
        })
        m.show(
          fn() {
            let s = shown()
            text(s, "build") != "" || (text(s, "email") != "" && text(s, "email") != text(s, "name"))
          },
          fn(line) {
            @sf.words_node(
              line,
              fn() {
                let s = shown()
                let parts : Array[String] = []
                let b = text(s, "build")
                if b != "" {
                  parts.push(fill("web-pages.security.pairBuild", [("build", b)]))
                }
                let email = text(s, "email")
                if email != "" && email != text(s, "name") {
                  parts.push(email)
                }
                parts.join(" · ")
              },
              fn() { pair_body },
            )
            |> ignore
          },
        )
      })
      // (asked into the person's own lock, no workspace's: said so)
      col.show(fn() { places().is_empty() }, fn(p) {
        @sf.words_node(p, fn() { tr("web-pages.security.pairPersonal") }, fn() { pair_places_head }) |> ignore
      })
      col.show(fn() { !places().is_empty() }, fn(p) {
        @sf.style_node(p, fn() { pair_places })
        @sf.words_node(p, fn() { tr("web-pages.security.promptFor") }, fn() { pair_places_head }) |> ignore
        p.each(places, fn(w) { text(Some(w), "id") }, fn(line, w) {
          let wv = fn() { Some(w.get()) }
          // its mark before its name, its letter where it has none
          @sf.style_node(line, fn() { pair_place_line })
          @sf.workspace_badge_node(line, fn() { text(wv(), "name") }, fn() { text(wv(), "emoji") }, fn() { text(wv(), "icon") }, pair_place_mark)
          @sf.words_node(line, fn() { text(wv(), "name") }, fn() { pair_place }) |> ignore
        })
        // (someone's first device in an upgraded workspace: the role approving lets them in as, the core's `roleText`,
        // from where 申请访问 and the workspaces' marks start)
        p.show(fn() { text(shown(), "roleText") != "" }, fn(r) {
          @sf.words_node(r, fn() { text(shown(), "roleText") }, fn() { pair_body }) |> ignore
        })
      })
      // explicit grant scope: signing capability and vaults whose keys will be handed over automatically
      col.show(has_grants, fn(g) {
        @sf.style_node(g, fn() { pair_places })
        @sf.words_node(g, fn() { tr("web-pages.security.pairGrantHead") }, fn() { pair_places_head }) |> ignore
        g.show(fn() { flag(shown(), "willSign") }, fn(s) {
          @sf.words_node(s, fn() { tr("web-pages.security.pairGrantSign") }, fn() { pair_grant_item }) |> ignore
        })
        g.each(handover, fn(v) { text(Some(v), "id") }, fn(row, v) {
          let vv = fn() { Some(v.get()) }
          @sf.words_node(
            row,
            fn() {
              let name = text(vv(), "name")
              let n = count(vv(), "items").to_string()
              let ws_name = text(vv(), "workspaceName")
              let multi_ws = places().length() > 1 && ws_name != ""
              let is_ws = text(vv(), "scope") == "workspace"
              match (is_ws, multi_ws) {
                (true, true) => fill("web-pages.security.pairGrantVaultWorkspaceIn", [("name", name), ("workspace", ws_name), ("n", n)])
                (true, false) => fill("web-pages.security.pairGrantVaultWorkspace", [("name", name), ("n", n)])
                (false, true) => fill("web-pages.security.pairGrantVaultPersonalIn", [("name", name), ("workspace", ws_name), ("n", n)])
                (false, false) => fill("web-pages.security.pairGrantVaultPersonal", [("name", name), ("n", n)])
              }
            },
            fn() { pair_grant_item },
          )
          |> ignore
        })
      })
      // the code, large, in the code face, in the middle
      col.box(fn(mid) {
        @sf.style_node(mid, fn() { centre_column })
        mid.box(fn(m) {
          m
          .words_runs(By(fn() { [@ui.span(spaced(text(shown(), "code")), mono=true)] }), look=pair_code_look)
          .ink(By(fn() { @sf.theme().p.text }))
          |> ignore
        })
        |> ignore
      })
      |> ignore
      // until when it holds (gone from here then)
      col.show(fn() { text(shown(), "untilText") != "" }, fn(u) {
        @sf.words_node(u, fn() { text(shown(), "untilText") }, fn() { pair_until }) |> ignore
      })
      @sf.words_node(col, fn() { tr("web-pages.security.pairNote") }, fn() { @sf.note.then(@sf.full_words) }) |> ignore
    })
    |> ignore
  })
}

///|
/// What the panel holds, 12 apart.
// kept across runs: a value (no field of it changes)
let pair_column : @ui.Style = @ui.css("w=Full gap=S3")

///|
/// Whose device it is and what.
// kept across runs: a value (no field of it changes)
let pair_body : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, w=Full)

///|
/// Lightweight tinted block for device verification code, client build, and requester email.
// kept across runs: a value (no field of it changes)
let pair_meta_box : @ui.Style = @ui.css("w=Full px=S3 py=S2 gap=S1 radius=Md bg=Tint")

///|
/// Full-width line holder inside the meta block.
// kept across runs: a value (no field of it changes)
let pair_meta_line : @ui.Style = @ui.css("w=Full")

///|
/// A granted capability or handed-over vault row under 批准后将授予.
// kept across runs: a value (no field of it changes)
let pair_grant_item : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Fg, w=Full)

///|
/// Where it asks to be let in: 申请访问 (13 muted), each workspace's name under it (16 semibold), 4 apart.
// kept across runs: a value (no field of it changes)
let pair_places : @ui.Style = @ui.css("w=Full gap=S1")

///|
// kept across runs: a value (no field of it changes)
let pair_places_head : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted)

///|
// kept across runs: a value (no field of it changes)
let pair_place : @ui.TextStyle = @ui.text_style(size=Title, weight=Semibold, color=Fg)

///|
/// A workspace asked into: its mark 8 before its name, as tall as its words.
// kept across runs: a value (no field of it changes)
let pair_place_line : @ui.Style = @ui.css("row gap=S2 align=ACenter")

///|
let pair_place_mark : Double = 20.0

///|
/// The code: 34 semibold in the code face, 44 a line, on one line (mono's, as it was said: size=34, weight=600, line=44).
// kept across runs: a value (no field of it changes)
let pair_code_look : @view.WordsLook = {
  size: 34.0,
  weight: 600,
  line: 44.0,
  wrap: false,
  tracking: @view.letters_own,
  balance: false,
  max_lines: 0,
}

///|
/// Until when the code holds, under it (13 muted, centred).
// kept across runs: a value (no field of it changes)
let pair_until : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, center=true, w=Full)

///|
/// A code's letters a little apart (letterSpacing 5): a thin space between each two.
fn spaced(code : String) -> String {
  let b = StringBuilder()
  let mut first = true
  for ch in code {
    if !first {
      b.write_char('\u{2009}')
    }
    b.write_char(ch)
    first = false
  }
  b.to_string()
}
