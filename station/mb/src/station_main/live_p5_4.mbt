// The live parts of P5-4 in the station's process (station/src/main.ts' layers: VaultLive, StationDrive and
// DriveTransfersLive, Helper, Grants, HelperFolders and ScreenRegistry, Browser and BrowserLive, AdbLive, DevicesLive,
// TerminalsLive, LoginsLive), each made on the bus (live_bus.mbt) and saying what it adds to the station's parts. What
// the other parts ask of them (the admin API's routes, the agents' side) is asked by name through `ui_ask`.

///|
/// The parts made, in their order, `ui_ask` answering what each answers. On a station that only runs tasks (`rig`)
/// only the devices it reaches for the stations and the commands they run with a secret (rig/main.ts gives a rig no
/// vault, browser, drive, terminals or logins).
pub async fn start_live_p5_4(bus : LiveBus, rig? : Bool = false) -> Unit {
  let host = bus.host
  let cloud = P54Cloud::new()
  p54_cloud_refresh(bus, cloud) catch {
    _ => ()
  }
  ignore((bus.cloud_listen.val)(_ => ignore(host.rt.fork_quiet(name="p5-4 cloud", async fn() {
    p54_cloud_refresh(bus, cloud) catch {
      _ => ()
    }
  }))))
  let threads = @store_threads.Store::new(bus.db, wall_ms().to_double()) catch {
    e => {
      err_write("station: the chats' store is not had for the vault (\{e})\n")
      return
    }
  }
  let asks : Array[async (String, Json) -> Json?] = []
  let screens = p54_screens_start(bus)
  if rig {
    match (try { Ok(p54_devices_start(bus, threads, cloud, screens)) } catch { e => Err(e) }) {
      Ok(d) => asks.push(async fn(op, a) { p54_devices_ask(d, op, a) })
      Err(e) => err_write("station: the devices are not made (\{e})\n")
    }
    // (rig/main.ts: no vault, but what another station runs here with a secret one of its chats holds)
    p54_rig_incoming(bus, cloud, threads)
    p54_ui_ask_chain(bus, asks)
    return
  }
  asks.push(async fn(op, a) { screens.ask(op, a) })
  p54_screen_tools(bus, screens) catch {
    e => err_write("station: the screen tools are not made (\{e})\n")
  }
  let vault = match (try { Ok(p54_vault_start(bus, cloud, threads)) } catch { e => Err(e) }) {
    Ok(v) => {
      asks.push(async fn(op, a) { p54_vault_ask(v, op, a) })
      Some(v)
    }
    Err(e) => {
      err_write("station: the vault is not made (\{e})\n")
      None
    }
  }
  let browser = match (try { Ok(p54_browser_start(bus, screens, vault)) } catch { e => Err(e) }) {
    Ok(b) => {
      asks.push(async fn(op, a) { p54_browser_ask(b, op, a) })
      Some(b)
    }
    Err(e) => {
      err_write("station: the browser is not made (\{e})\n")
      None
    }
  }
  let drive = p54_drive_start(bus, screens)
  asks.push(async fn(op, a) { p54_drive_ask(drive, bus, op, a) })
  match (try { Ok(p54_devices_start(bus, threads, cloud, screens)) } catch { e => Err(e) }) {
    Ok(d) => asks.push(async fn(op, a) { p54_devices_ask(d, op, a) })
    Err(e) => err_write("station: the phones and devices are not made (\{e})\n")
  }
  match (try { Ok(p54_terminals_start(bus)) } catch { e => Err(e) }) {
    Ok(terms) => asks.push(async fn(op, a) { p54_terminals_ask(terms, op, a) })
    Err(e) => err_write("station: the terminals are not made (\{e})\n")
  }
  // A login's page opened in the station's own browser for a person to finish there (logins/pages.ts).
  let pages = browser.map(b => {
    let station = b.browsers.station
    @terminals_logins.LoginPages::new(
      {
        available: () => station.available(),
        open_tab: async fn(key, _options) { station.open_user_tab(key) },
        has_tab: id => station.has_tab(id),
        close_tab: id => ignore(bus.host.rt.fork_quiet(name="login page", async fn() { station.close_tab(id) catch { _ => () } })),
        tab_url: Some(id => station.tab_url(id)),
      },
      changed => ignore(screens.hub.on_change(changed)),
      (said, about) => err_write("login pages: \{said} \{@jsjson.stringify(about)}\n"),
    )
  })
  match (try { Ok(p54_logins_start(bus, threads, pages, cloud)) } catch { e => Err(e) }) {
    Ok(l) => asks.push(async fn(op, a) { p54_logins_ask(l, op, a) })
    Err(e) => err_write("station: the logins are not made (\{e})\n")
  }
  p54_ui_ask_chain(bus, asks)
  p54_test_door(bus)
}

///|
/// `ui_ask` answered by the first of `asks` that answers, else by what answered before.
fn p54_ui_ask_chain(bus : LiveBus, asks : Array[async (String, Json) -> Json?]) -> Unit {
  let before = bus.ui_ask.val
  bus.ui_ask.val = async fn(op, a) {
    for ask in asks {
      if ask(op, a) is Some(answer) { return answer }
    }
    before(op, a)
  }
}

///|
/// A test's way to what the parts answer by name (`STILLFAIL_TEST_UI_ASK`, its bearer): POST /ui-ask/ `{op, args}` on
/// the agents' door, answered `{answer}` or `{error, kind}`; and `p54.routes`, the parts' routes of the admin API.
/// Nothing is put there without that variable, which only station/test/mb-live-p5-4.test.ts gives.
fn p54_test_door(bus : LiveBus) -> Unit {
  guard env_get("STILLFAIL_TEST_UI_ASK") is Some(token) && token != "" else { return }
  // (the admin API's callbacks, P5-1's, stood in for where none is: the uploads' place a staged file is given)
  if !bus.peer_handlers.contains("$admin.called") {
    bus.on_peer("$admin.called", async fn(_, _, params, _) {
      let name = opt_str(opt_field(Some(params), "args").bind(x => match x { Array(a) => a.get(0); _ => None })).unwrap_or("file")
      let dir = path([bus.data, "uploads", "staged"])
      @drive.mkdir(dir, true)
      ({ "safe": Json::string(name), "path": Json::string(path([dir, name])) }, None)
    })
  }
  bus.parts.door({
    prefix: "ui-ask",
    request: async fn(r, _) {
      if r.header("authorization") != Some("Bearer \{token}") {
        return Some(plain(401, ""))
      }
      let asked = (try { Ok(@json.parse(@utf8.decode_lossy(r.body))) } catch { e => Err(e) }).unwrap_or(Json::null())
      let op = jtext(asked, "op").unwrap_or("")
      let args = opt_field(Some(asked), "args").unwrap_or(Json::array([]))
      if op == "p54.route" {
        // (a part's route of the admin API as the admin API answers it: its method, path, viewer and body)
        let meth = call_arg_text(args, 0)
        let at = call_arg_text(args, 1)
        for rt in bus.parts.all_routes(Json::null()) {
          if rt.meth == meth && (try { Ok(@api_routes.re(rt.path).matches(at)) } catch { e => Err(e) }) is Ok(true) {
            let answered = (rt.answer)({ "path": Json::string(at), "viewer": call_arg(args, 2).unwrap_or(Json::null()), "body": Json::string(call_arg_text(args, 3)) })
            return Some(json_reply(200, { "answer": answered }))
          }
        }
        return Some(json_reply(404, { "error": Json::string("no route \{meth} \{at}") }))
      }
      if op == "p54.routes" {
        let routes = bus.parts.all_routes(Json::null()).map(rt => Json::string("\{rt.meth} \{rt.path}"))
        return Some(json_reply(200, { "answer": Json::array(routes) }))
      }
      match (try { Ok((bus.ui_ask.val)(op, args)) } catch { e => Err(e) }) {
        Ok(answer) => Some(json_reply(200, { "answer": answer }))
        Err(P54Refused(kind, said)) => Some(json_reply(500, { "error": said, "kind": Json::string(kind) }))
        Err(e) => Some(json_reply(500, { "error": Json::string(p54_message(e)), "kind": Json::string("Error") }))
      }
    },
  })
}
