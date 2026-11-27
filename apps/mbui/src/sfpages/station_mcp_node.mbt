// Settings → MCP tab (`mcp_servers_page_node`, parallel to `memories_node` in memory.mbt):
// manages station-hosted third-party MCP servers across all stations in the workspace,
// using native compound rows (@sf.row_box_node) with status-tinted transport icons, status dots,
// cross-station sharing badges, enable switches, and a full edit/manage dialog.

///|
// kept across runs: a value (no field of it changes)
let st_mcp_status_wrap : @ui.Style = @ui.css("row align=ACenter gap=S1_5")

///|
// kept across runs: a value (no field of it changes)
let st_mcp_status : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let st_mcp_status_err : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Danger, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let st_mcp_err : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=Danger, w=Full)

///|
// kept across runs: a value (no field of it changes)
let st_mcp_dialog_switches : @ui.Style = @ui.css("w=Full gap=S2_5 pt=S1")

///|
// kept across runs: a value (no field of it changes)
let st_mcp_dialog_foot_spacer : @ui.Style = @ui.style(w=@sf.grow)

///|
// kept across runs: a value (no field of it changes)
let st_mcp_dialog_fields : @ui.Style = @ui.css("w=Full gap=S4")

///|
fn mcp_transport_icon(transport : String) -> String {
  match transport {
    "http" => "link"
    "sse" => "plug"
    _ => "terminal"
  }
}

///|
fn mcp_dot_state(srv : Json?) -> String {
  match text(srv, "status") {
    "ready" => "live"
    "connecting" | "reconnecting" => "busy"
    "failed" => "fail"
    _ => "off"
  }
}

///|
fn mcp_tile_icon_color(status : String) -> Int64 {
  match status {
    "ready" => @ui.tree_theme().color(Positive)
    "failed" => @ui.tree_theme().color(Danger)
    "connecting" | "reconnecting" => @ui.tree_theme().color(Warn)
    _ => @sf.theme().p.muted
  }
}

///|
fn mcp_transport_label(transport : String) -> String {
  match transport {
    "http" => @sf.t("web-pages.stations.mcpTypeHttp")
    "sse" => @sf.t("web-pages.stations.mcpTypeSse")
    _ => @sf.t("web-pages.stations.mcpTypeStdio")
  }
}

///|
fn mcp_status_text(srv : Json?) -> String {
  match text(srv, "status") {
    "ready" => @sf.t("web-pages.stations.mcpStatusReady", args=[("tools", count(srv, "toolCount").to_string())])
    "connecting" => @sf.t("web-pages.stations.mcpStatusConnecting")
    "reconnecting" => @sf.t("web-pages.stations.mcpStatusReconnecting")
    "disabled" => @sf.t("web-pages.stations.mcpStatusDisabled")
    "failed" => @sf.t("web-pages.stations.mcpStatusFailed")
    _ => @sf.t("web-pages.stations.mcpStatusStopped")
  }
}

///|
fn mcp_target_text(srv : Json?) -> String {
  let transport = text(srv, "transport")
  if transport == "http" || transport == "sse" {
    return text(srv, "url")
  }
  let cmd = text(srv, "command")
  let args = items(srv, "args").filter_map(fn(a) {
    match a {
      String(s) => Some(s)
      _ => None
    }
  })
  if args.length() == 0 {
    cmd
  } else {
    cmd + " " + join(args, " ")
  }
}

///|
fn mcp_map_to_lines(m : Json?, sep : String) -> String {
  match m {
    Some(Object(entries)) => {
      let keys : Array[String] = []
      entries.each(fn(k, _) { keys.push(k) })
      keys.sort()
      let lines : Array[String] = []
      for k in keys {
        match entries.get(k) {
          Some(String(v)) => lines.push(k + sep + v)
          _ => ()
        }
      }
      join(lines, "\n")
    }
    _ => ""
  }
}

///|
fn mcp_parse_kv_lines(raw : String, sep : Char) -> Map[String, Json] {
  let out : Map[String, Json] = Map([])
  for part in raw.split("\n") {
    let line = part.trim(chars=" \t\r").to_owned()
    if line == "" || line.has_prefix("#") {
      continue
    }
    let sep_s = sep.to_string()
    match line.find(sep_s) {
      Some(idx) if idx > 0 => {
        let k = line[:idx].trim(chars=" \t").to_owned()
        let v = line[idx + 1:].trim(chars=" \t").to_owned()
        if k != "" {
          out[k] = str(v)
        }
      }
      _ => ()
    }
  }
  out
}

///|
fn mcp_parse_args_lines(raw : String) -> Array[Json] {
  let out : Array[Json] = []
  for part in raw.split("\n") {
    let line = part.trim(chars=" \t\r").to_owned()
    if line != "" {
      out.push(str(line))
    }
  }
  out
}

///|
/// Rebuilds a server entry JSON from its overview representation with `enabled` and `shared` set,
/// keeping masked `env`/`headers` intact so the station preserves stored secrets.
fn mcp_entry_with_flags(srv : Json?, enabled : Bool, shared : Bool) -> Json {
  let m : Map[String, Json] = Map([])
  let transport = text(srv, "transport")
  if transport == "http" || transport == "sse" {
    m["type"] = str(transport)
    m["url"] = str(text(srv, "url"))
    match field(srv, "headers") {
      Some(Object(h)) => m["headers"] = Json::object(h)
      _ => ()
    }
  } else {
    m["command"] = str(text(srv, "command"))
    let args = items(srv, "args")
    if args.length() > 0 {
      m["args"] = Json::array(args)
    }
    match field(srv, "env") {
      Some(Object(e)) => m["env"] = Json::object(e)
      _ => ()
    }
  }
  if !enabled {
    m["enabled"] = Json::boolean(false)
  }
  if shared {
    m["shared"] = Json::boolean(true)
  }
  Json::object(m)
}

///|
/// Settings → MCP tab (`McpServers` route), structured like `memories_node`:
/// lists each station in the workspace with its managed MCP servers, enable and cross-station sharing toggles,
/// reconnect/edit/delete actions, and an "Add MCP server" button for owners/admins.
pub fn mcp_servers_page_node(
  v : @view.View,
  core : Core,
  here : () -> @settings.Here,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
) -> Unit {
  let topic = fn() { @settings.stations_of(core, here()) }
  let stations = fn() {
    match topic().value {
      Some(Array(a)) => a
      _ => []
    }
  }
  let manager = fn() {
    let role = role_of(core, here())
    role == "owner" || role == "admin"
  }
  @sf.page_node(
    v,
    fn() { @sf.t("web-pages.stations.mcp") },
    on_back~,
    frame~,
    said?,
    width?,
    lead=fn() { @sf.t("web-pages.stations.mcpLead") },
    fn() { ["stations"] },
    fn(b, _) {
      b.each(stations, fn(st) { text(Some(st), "station") }, fn(slot, st) {
        let addr = @signals.untracked(fn() { text(Some(st.get()), "station") })
        let full = fn() { @settings.station_of(core, here(), addr) }
        let online = fn() { flag(Some(st.get()), "online") }
        let mcp_list = fn() { items(field(full(), "overview"), "mcpServers") }
        let title = fn() {
          let n = text(Some(st.get()), "name")
          if n != "" { n } else { addr }
        }
        mcp_station_card_node(slot, core, addr, title, mcp_list, manager, online)
      })
    },
  )
}

///|
fn mcp_station_card_node(
  slot : @view.View,
  core : Core,
  address : String,
  title : () -> String,
  mcp_list : () -> Array[Json],
  manager : () -> Bool,
  online : () -> Bool,
) -> Unit {
  let saving = fn() { is_doing(core, ["mcpServers.save"], [("station", address)]) }
  let can_edit = fn() { manager() && online() }
  st_section_node(
    slot,
    title,
    count=fn() { mcp_list().length() },
    ends=(
      can_edit,
      fn(e) {
        @sf.button_node(
          e,
          fn() { @sf.t("web-pages.stations.mcpAdd") },
          fn() { open_mcp_server_dialog(core, address, None) },
          icon="plus",
          tone=Ghost,
          disabled=saving,
        )
        |> ignore
      },
    ),
    fn(sec) {
      sec.pick(fn() { mcp_list().length() == 0 }, fn(p, empty) {
        if empty {
          @sf.section_none_node(p, fn() { @sf.t("web-pages.stations.mcpEmpty") })
        } else {
          @sf.group_node(p, fn(g) {
            g.each(mcp_list, fn(s) { text(Some(s), "name") }, fn(row, s) {
              let sv = fn() { Some(s.get()) }
              let toggle_enabled = fn(next : Bool) {
                let cur = Some(@signals.untracked(fn() { s.get() }))
                let name = text(cur, "name")
                if name == "" {
                  return
                }
                let servers : Map[String, Json] = Map([])
                servers[name] = mcp_entry_with_flags(cur, next, flag(cur, "shared"))
                @settings.act(
                  core,
                  @sf.t("web-pages.stations.mcpToggleWhat"),
                  "mcpServers.save",
                  obj([("station", str(address)), ("servers", Json::object(servers))]),
                )
              }
              let toggle_shared = fn(next : Bool) {
                let cur = Some(@signals.untracked(fn() { s.get() }))
                let name = text(cur, "name")
                if name == "" {
                  return
                }
                let servers : Map[String, Json] = Map([])
                servers[name] = mcp_entry_with_flags(cur, flag(cur, "enabled"), next)
                @settings.act(
                  core,
                  @sf.t("web-pages.stations.mcpShareWhat"),
                  "mcpServers.save",
                  obj([("station", str(address)), ("servers", Json::object(servers))]),
                )
              }
              let open_edit = fn() {
                open_mcp_server_dialog(core, address, Some(@signals.untracked(fn() { s.get() })))
              }
              let delete_ask = fn() {
                let name = text(Some(@signals.untracked(fn() { s.get() })), "name")
                if name == "" {
                  return
                }
                @sf.confirm(
                  @sf.t("web-pages.stations.mcpDeleteTitle"),
                  @sf.t("web-pages.stations.mcpDeleteBody"),
                  @sf.t("web-pages.stations.mcpDelete"),
                  fn() {
                    let servers : Map[String, Json] = Map([])
                    servers[name] = Json::null()
                    @settings.act(
                      core,
                      @sf.t("web-pages.stations.mcpSave"),
                      "mcpServers.save",
                      obj([("station", str(address)), ("servers", Json::object(servers))]),
                      done=@sf.t("web-pages.stations.mcpDeleted"),
                    )
                  },
                  danger=true,
                  facts=[(@sf.t("common.confirmFact.mcp"), name)],
                )
              }
              row.on_menu(fn(m) {
                if !@signals.untracked(can_edit) {
                  return
                }
                let cur = Some(@signals.untracked(fn() { s.get() }))
                let name = text(cur, "name")
                if name == "" {
                  return
                }
                let is_shared = flag(cur, "shared")
                let is_enabled = flag(cur, "enabled")
                let items : Array[@sf.MenuItem?] = [
                  Some(@sf.menu_item_of(@sf.t("common.edit"), open_edit)),
                  Some(
                    @sf.menu_item_of(
                      @sf.t("web-pages.stations.mcpEnable"),
                      fn() { toggle_enabled(!is_enabled) },
                    ),
                  ),
                  Some(
                    @sf.menu_item_of(
                      @sf.t("web-pages.stations.mcpShared"),
                      fn() { toggle_shared(!is_shared) },
                    ),
                  ),
                  if is_enabled {
                    Some(
                      @sf.menu_item_of(@sf.t("web-pages.stations.mcpReload"), fn() {
                        @settings.act(
                          core,
                          @sf.t("web-pages.stations.mcpReloadWhat"),
                          "mcpServers.reload",
                          obj([("station", str(address)), ("name", str(name))]),
                          done=@sf.t("web-pages.stations.mcpReloaded"),
                        )
                      }),
                    )
                  } else {
                    None
                  },
                  Some(@sf.menu_item_of(@sf.t("web-pages.stations.mcpDelete"), delete_ask, danger=true)),
                ]
                @sf.menu(items, from=@sf.at_point(m.wx, m.wy))
              })
              |> ignore
              row.pick(can_edit, fn(rp, editable) {
                let body = fn(r : @sf.RowScope) {
                  r.lead(icon_line=true, fn(l) {
                    @sf.icon_node(
                      l,
                      mcp_transport_icon(@signals.untracked(fn() { text(sv(), "transport") })),
                      18.0,
                      By(fn() { mcp_tile_icon_color(text(sv(), "status")) }),
                      name_now=fn() { mcp_transport_icon(text(sv(), "transport")) },
                    )
                    |> ignore
                  })
                  r.title(
                    tone=RowStrong,
                    cut=true,
                    after=fn(a) {
                      a.show(fn() { flag(sv(), "shared") }, fn(sh) {
                        @sf.badge_node(sh, fn() { @sf.t("web-pages.stations.mcpSharedBadge") }, tone=Blue) |> ignore
                      })
                    },
                  )
                  r.note(
                    fn() { join([mcp_transport_label(text(sv(), "transport")), mcp_target_text(sv())], " · ") },
                    cut=true,
                  )
                  r.note(fn() { text(sv(), "error") }, tone=NoteBad)
                  r.tail(fn(t) {
                    t.box(fn(st) {
                      @sf.style_node(st, fn() { st_mcp_status_wrap })
                      @sf.state_dot_node(st, fn() { mcp_dot_state(sv()) })
                      st.pick(fn() { text(sv(), "status") == "failed" }, fn(sp, is_err) {
                        @sf.words_node(
                          sp,
                          fn() { mcp_status_text(sv()) },
                          fn() { if is_err { st_mcp_status_err } else { st_mcp_status } },
                        )
                        |> ignore
                      })
                    })
                    |> ignore
                  })
                  if editable {
                    r.chevron()
                  }
                }
                if editable {
                  @sf.row_box_node(rp, fn() { text(sv(), "name") }, press=open_edit, body)
                } else {
                  @sf.row_box_node(rp, fn() { text(sv(), "name") }, body)
                }
              })
            })
          })
        }
      })
    },
  )
}

///|
fn open_mcp_server_dialog(core : Core, address : String, editing : Json?) -> Unit {
  let is_edit = editing is Some(_)
  let init_transport = match editing {
    Some(_) => {
      let t = text(editing, "transport")
      if t == "http" || t == "sse" { t } else { "stdio" }
    }
    None => "stdio"
  }
  let transport = @signals.signal(init_transport)
  let enabled = @signals.signal(match editing { Some(_) => flag(editing, "enabled"); None => true })
  let shared = @signals.signal(match editing { Some(_) => flag(editing, "shared"); None => false })
  let err_msg : @signals.Signal[String] = @signals.signal("")

  let f_name = @ui.Field::new()
  let f_cmd = @ui.Field::new()
  let f_args = @ui.Field::new()
  let f_env = @ui.Field::new()
  let f_url = @ui.Field::new()
  let f_headers = @ui.Field::new()

  if is_edit {
    f_name.set(text(editing, "name"))
    f_cmd.set(text(editing, "command"))
    let args = items(editing, "args").filter_map(fn(a) {
      match a {
        String(s) => Some(s)
        _ => None
      }
    })
    f_args.set(join(args, "\n"))
    f_env.set(mcp_map_to_lines(field(editing, "env"), "="))
    f_url.set(text(editing, "url"))
    f_headers.set(mcp_map_to_lines(field(editing, "headers"), ": "))
  }

  let title = if is_edit { @sf.t("web-pages.stations.mcpEdit") } else { @sf.t("web-pages.stations.mcpAdd") }
  open_dialog_nodes(
    title,
    fn(v, _) {
      @sf.field_node(v, fn() { @sf.t("web-pages.stations.mcpName") }, fn(f) {
        @sf.input_node(
          f,
          f_name,
          placeholder=@sf.t("web-pages.stations.mcpNamePh"),
          label=@sf.t("web-pages.stations.mcpName"),
          disabled=fn() { is_edit },
        )
        |> ignore
      })
      @sf.field_node(v, fn() { @sf.t("web-pages.stations.mcpType") }, fn(f) {
        let types = ["stdio", "http", "sse"]
        f.box(fn(line) {
          line.row(Is(true)) |> ignore
          line.box(fn(slot) {
            @sf.segmented_node(
              slot,
              fn() {
                [
                  @sf.t("web-pages.stations.mcpTypeStdio"),
                  @sf.t("web-pages.stations.mcpTypeHttp"),
                  @sf.t("web-pages.stations.mcpTypeSse"),
                ]
              },
              fn() {
                match transport.get() {
                  "http" => 1
                  "sse" => 2
                  _ => 0
                }
              },
              fn(i) {
                transport.set(types.get(i).unwrap_or("stdio"))
                err_msg.set("")
              },
              said=@sf.t("web-pages.stations.mcpType"),
            )
          })
          |> ignore
        })
        |> ignore
      })
      v.pick(fn() { transport.get() == "stdio" }, fn(p, is_stdio) {
        @sf.style_node(p, fn() { st_mcp_dialog_fields })
        if is_stdio {
          @sf.field_node(p, fn() { @sf.t("web-pages.stations.mcpCommand") }, fn(f) {
            @sf.input_node(
              f,
              f_cmd,
              placeholder=@sf.t("web-pages.stations.mcpCommandPh"),
              label=@sf.t("web-pages.stations.mcpCommand"),
            )
            |> ignore
          })
          @sf.field_node(
            p,
            fn() { @sf.t("web-pages.stations.mcpArgs") },
            hint=fn() { @sf.t("web-pages.stations.mcpArgsHint") },
            fn(f) {
              @sf.textarea_node(
                f,
                f_args,
                rows=2,
                placeholder=@sf.t("web-pages.stations.mcpArgsPh"),
                label=@sf.t("web-pages.stations.mcpArgs"),
              )
              |> ignore
            },
          )
          @sf.field_node(
            p,
            fn() { @sf.t("web-pages.stations.mcpEnv") },
            hint=fn() { @sf.t("web-pages.stations.mcpEnvHint") },
            fn(f) {
              @sf.textarea_node(
                f,
                f_env,
                rows=2,
                placeholder=@sf.t("web-pages.stations.mcpEnvPh"),
                label=@sf.t("web-pages.stations.mcpEnv"),
              )
              |> ignore
            },
          )
        } else {
          @sf.field_node(p, fn() { @sf.t("web-pages.stations.mcpUrl") }, fn(f) {
            @sf.input_node(
              f,
              f_url,
              placeholder=@sf.t("web-pages.stations.mcpUrlPh"),
              label=@sf.t("web-pages.stations.mcpUrl"),
            )
            |> ignore
          })
          @sf.field_node(
            p,
            fn() { @sf.t("web-pages.stations.mcpHeaders") },
            hint=fn() { @sf.t("web-pages.stations.mcpHeadersHint") },
            fn(f) {
              @sf.textarea_node(
                f,
                f_headers,
                rows=2,
                placeholder=@sf.t("web-pages.stations.mcpHeadersPh"),
                label=@sf.t("web-pages.stations.mcpHeaders"),
              )
              |> ignore
            },
          )
        }
      })
      v.box(fn(sw) {
        @sf.style_node(sw, fn() { st_mcp_dialog_switches })
        @sf.switch_row_node(
          sw,
          fn() { @sf.t("web-pages.stations.mcpEnable") },
          fn() { enabled.get() },
          fn(next) { enabled.set(next) },
          in_words=true,
        )
        @sf.switch_row_node(
          sw,
          fn() { @sf.t("web-pages.stations.mcpShared") },
          fn() { shared.get() },
          fn(next) { shared.set(next) },
          note=fn() { @sf.t("web-pages.stations.mcpSharedHint") },
          in_words=true,
        )
      })
      |> ignore
      v.show(fn() { err_msg.get() != "" }, fn(e) {
        @sf.words_node(e, fn() { err_msg.get() }, fn() { st_mcp_err }) |> ignore
      })
    },
    fn(v, shut) {
      if is_edit {
        let edit_name = text(editing, "name")
        @sf.button_node(
          v,
          fn() { @sf.t("web-pages.stations.mcpDelete") },
          fn() {
            if edit_name == "" {
              return
            }
            @sf.confirm(
              @sf.t("web-pages.stations.mcpDeleteTitle"),
              @sf.t("web-pages.stations.mcpDeleteBody"),
              @sf.t("web-pages.stations.mcpDelete"),
              fn() {
                let servers : Map[String, Json] = Map([])
                servers[edit_name] = Json::null()
                @settings.act(
                  core,
                  @sf.t("web-pages.stations.mcpSave"),
                  "mcpServers.save",
                  obj([("station", str(address)), ("servers", Json::object(servers))]),
                  done=@sf.t("web-pages.stations.mcpDeleted"),
                )
                shut()
              },
              danger=true,
              facts=[(@sf.t("common.confirmFact.mcp"), edit_name)],
            )
          },
          tone=Danger,
        )
        |> ignore
        v.show(fn() { enabled.get() }, fn(rb) {
          @sf.button_node(
            rb,
            fn() { @sf.t("web-pages.stations.mcpReload") },
            fn() {
              if edit_name == "" {
                return
              }
              @settings.act(
                core,
                @sf.t("web-pages.stations.mcpReloadWhat"),
                "mcpServers.reload",
                obj([("station", str(address)), ("name", str(edit_name))]),
                done=@sf.t("web-pages.stations.mcpReloaded"),
              )
              shut()
            },
            tone=Ghost,
          )
          |> ignore
        })
        v.box(fn(sp) { @sf.style_node(sp, fn() { st_mcp_dialog_foot_spacer }) }) |> ignore
      }
      @sf.button_node(v, fn() { @sf.t("common.cancel") }, shut, tone=Ghost) |> ignore
      @sf.button_node(
        v,
        fn() { @sf.t("common.save") },
        fn() {
          let name = f_name.text().trim(chars=" \t\r\n").to_owned()
          if name == "" {
            err_msg.set(@sf.t("web-pages.stations.mcpNameRequired"))
            return
          }
          let t = transport.untracked()
          let entry : Map[String, Json] = Map([])
          if t == "http" || t == "sse" {
            let url = f_url.text().trim(chars=" \t\r\n").to_owned()
            if url == "" {
              err_msg.set(@sf.t("web-pages.stations.mcpUrlRequired"))
              return
            }
            entry["type"] = str(t)
            entry["url"] = str(url)
            let hdrs = mcp_parse_kv_lines(f_headers.text(), ':')
            if hdrs.length() > 0 {
              entry["headers"] = Json::object(hdrs)
            }
          } else {
            let cmd = f_cmd.text().trim(chars=" \t\r\n").to_owned()
            if cmd == "" {
              err_msg.set(@sf.t("web-pages.stations.mcpCommandRequired"))
              return
            }
            entry["command"] = str(cmd)
            let args = mcp_parse_args_lines(f_args.text())
            if args.length() > 0 {
              entry["args"] = Json::array(args)
            }
            let env = mcp_parse_kv_lines(f_env.text(), '=')
            if env.length() > 0 {
              entry["env"] = Json::object(env)
            }
          }
          if !enabled.untracked() {
            entry["enabled"] = Json::boolean(false)
          }
          if shared.untracked() {
            entry["shared"] = Json::boolean(true)
          }
          let servers : Map[String, Json] = Map([])
          servers[name] = Json::object(entry)
          @settings.act(
            core,
            @sf.t("web-pages.stations.mcpSave"),
            "mcpServers.save",
            obj([("station", str(address)), ("servers", Json::object(servers))]),
            done=@sf.t("web-pages.stations.mcpSaved"),
          )
          shut()
        },
        tone=Primary,
      )
      |> ignore
    },
  )
}
