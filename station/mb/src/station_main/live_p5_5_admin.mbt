// What the admin API's routes (api_routes, P5-1's admin) ask of this slice's parts by name on `coord_ask`
// (api_routes/backend.mbt: `<part>.<method>`, its arguments as JSON): the updates' (station.mbt `updates_routes`), the
// copies' and a retirement's (`copies_routes`), every connect kind's (connects.mbt: `connectKinds.get`, a kind's
// `.entry` and `.reconnect`), Slack's own (kinds.mbt `slack_routes`: `slack/index.*`, `slack.apps.*`, `slack.connects`,
// `slack.chat`), Feishu's and Comma's (kinds2.mbt; their ops are made with their parts, live_p5_5_platforms.mbt). What
// a part refuses is thrown as the kind the routes look for (`@api_routes.Thrown`): `mesh/bus.Refused`,
// `SlackApiError`, `SlackWords`, else `Error`, its words kept.

///|
/// An error of this slice's parts as the admin API's routes take it (their `Thrown`, by the kind station/src throws).
fn p55_thrown_of(e : Error) -> Error {
  match e {
    @api_routes.Thrown(_, _) => e
    @slack.SlackApiError(m, code, details) =>
      @api_routes.Thrown(
        "SlackApiError",
        @jsjson.JV::of_json({
          "message": Json::string(p55_said_of(e)),
          "method": Json::string(m),
          "code": Json::string(code),
          "details": match details {
            Some(d) => to_core(d)
            None => Json::null()
          },
        }),
      )
    @slack.SlackWords(key, words) => @api_routes.Thrown("SlackWords", @jsjson.JV::of_json({ "message": Json::string(words), "key": Json::string(key) }))
    @replica_coord.Thrown(_, _) => @api_routes.Thrown("mesh/bus.Refused", @jsjson.JV::of_json({ "message": Json::string(p55_said_of(e)) }))
    e => @api_routes.Thrown("Error", @jsjson.JV::of_json({ "message": Json::string(p55_said_of(e)) }))
  }
}

///|
/// A `{"$bytes": base64}` argument's bytes.
fn bytes_arg(v : Json) -> Bytes {
  @api_routes.bytes_of(@jsjson.JV::of_json(v)).unwrap_or(b"")
}

///|
/// An error as `slackError` is handed it (`{"$error": what the route caught}`), as Slack's surface threw it.
fn slack_error_of(v : Json) -> Error {
  let e = p55_jfield(v, "$error")
  match (p55_jstr(e, "code"), p55_jstr(e, "key")) {
    (Some(code), _) =>
      @slack.SlackApiError(p55_jtext(e, "method"), code, match p55_jfield(e, "details") {
        Null => None
        d => Some(of_core(d))
      })
    (None, Some(key)) => @slack.SlackWords(key, p55_jtext(e, "message"))
    _ => BusError(p55_jtext(e, "message"))
  }
}

///|
fn arg_at(a : Array[Json], i : Int) -> Json {
  a.get(i).unwrap_or(Json::null())
}

///|
fn text_at(a : Array[Json], i : Int) -> String {
  match a.get(i) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
fn opt_text_at(a : Array[Json], i : Int) -> String? {
  match a.get(i) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
/// A JSON argument as one may be absent (`{"$undef": 1}`, null): None.
fn given(v : Json) -> @jsjson.JValue? {
  match v {
    Null => None
    Object(m) if m.contains("$undef") => None
    v => Some(of_core(v))
  }
}

///|
/// The connect kinds' parts and Slack's own, on `coord_ask`.
fn P55::connect_kind_ops(self : P55, live : ConnectsLive) -> Unit {
  let bus = self.bus
  // A kind's part, by reference (`{"$ref": kind}`): its entry edited, its connects connected again.
  self.op("connectKinds.get", async fn(arg) {
    let kind = text_at(core_items(arg), 0)
    if live.kinds.contains(kind) {
      { "$ref": Json::string(kind) }
    } else {
      Json::null()
    }
  })
  for kind in ["slack", "feishu", "comma", "group"] {
    self.op("\{kind}.entry", async fn(arg) {
      let a = core_items(arg)
      let (given_, had) = (arg_at(a, 0), arg_at(a, 1))
      match kind {
        "slack" => to_core_ar(@api_routes.slack_entry(@jsjson.JV::of_json(given_), @jsjson.JV::of_json(had)))
        "feishu" => to_core_ar(@api_routes.feishu_entry(@jsjson.JV::of_json(given_), @jsjson.JV::of_json(had)))
        "comma" => to_core_ar(@api_routes.comma_entry(@jsjson.JV::of_json(given_), @jsjson.JV::of_json(had)))
        _ => group_entry(given_, had)
      }
    })
    self.op("\{kind}.reconnect", async fn(arg) {
      guard live.kinds.get(kind) is Some(c) else { return Json::null() }
      c.reconcile()
      c.refresh_identity(text_at(core_items(arg), 0)) catch {
        e => self.warn(kind, "who the bot is not read again", e)
      }
      Json::null()
    })
  }
  // Slack's: its connects as config.json has them, who a bot is read again, a connect's surface by reference.
  let slack = live.slack
  self.op("slack.connects", async fn(_arg) {
    Json::array(@slack.slack_connects(Some(of_core((bus.config_raw.val)()))).map(c => to_core(c.to_j())))
  })
  self.op("slack.refreshIdentity", async fn(arg) {
    slack.refresh_identity(text_at(core_items(arg), 0))
    Json::null()
  })
  self.op("slack.chat", async fn(arg) {
    let id = text_at(core_items(arg), 0)
    match slack.chats(id) {
      Some(_) => { "$ref": Json::string("slack.chat:\{id}") }
      None => Json::null()
    }
  })
  // The app API with a person's configuration tokens (slack/apps.ts `SlackApps`), its rotated tokens kept in config.json.
  let client = @slack.SlackClient::new(@slack.host_net(bus.host, @slack.Wall::new(wall_ms().to_double())), base=@slack.api_base(env_get("STILLFAIL_SLACK_API")))
  let (zh, en) = catalogs_json()
  let words = @replica_coord.station_words(of_core(zh), of_core(en))
  let lang = Ref((bus.lang.val)())
  let apps = @slack.SlackApps::new(
    client,
    () => @slack.config_tokens(Some(of_core((bus.config_raw.val)()))),
    async fn(token) {
      ignore(
        (bus.config_update.val)(raw => {
          let kept = core_items(p55_jfield(raw, "slackConfigTokens")).map(of_core)
          match raw {
            Object(m) => {
              m["slackConfigTokens"] = Json::array(@slack.upsert_token(kept, token).map(to_core))
              Json::object(m)
            }
            other => other
          }
        }),
      ) catch {
        e => self.warn("slack", "slack configuration token not saved", e)
      }
    },
    words,
    lang,
    (level, part, said, fields) => slice_log(level, part, said, to_core(fields)),
  )
  let slack_connect = (v : Json) => @slack.slack_connects(Some(of_core({ "connects": [v] }))).get(0)
  self.prefix_op("slack/index.", async fn(name, arg) {
    let a = core_items(arg)
    let j = (i : Int) => given(arg_at(a, i))
    match name {
      "slack/index.madeApps" => Json::array(@slack.made_apps(j(0)).map(to_core))
      "slack/index.configTokens" => Json::array(@slack.config_tokens(j(0)).map(to_core))
      "slack/index.appIdOf" => Json::string(@slack.app_id_of(client, text_at(a, 1)))
      "slack/index.slackError" => Json::string(@slack.slack_error(words, slack_error_of(arg_at(a, 0)), text_at(a, 1)))
      "slack/index.withSocketMode" => to_core(@slack.with_socket_mode(j(0), arg_at(a, 1) is True))
      "slack/index.applySettings" => to_core(@slack.apply_settings(j(0), j(1)))
      "slack/index.slackManifest" => to_core(@slack.slack_manifest(text_at(a, 0), description=opt_text_at(a, 1), redirect_url=opt_text_at(a, 2)))
      "slack/index.slackAppLinks" => to_core(@slack.slack_app_links(text_at(a, 0), opt_text_at(a, 1)))
      "slack/index.settingsOf" => to_core(@slack.settings_of(j(0)))
      "slack/index.rotateConfigToken" => to_core(@slack.rotate_config_token(client, text_at(a, 1)))
      "slack/index.ownerOfConfigToken" =>
        match @slack.owner_of_config_token(client, text_at(a, 1)) {
          Some(o) => to_core(o)
          None => Json::null()
        }
      "slack/index.upsertToken" => Json::array(@slack.upsert_token(core_items(arg_at(a, 0)).map(of_core), of_core(arg_at(a, 1))).map(to_core))
      "slack/index.shownIdentity" => {
        let i = arg_at(a, 0)
        {
          "team": p55_jfield(i, "team"),
          "teamId": p55_jfield(i, "teamId"),
          "url": p55_jfield(i, "url"),
          "botUserId": p55_jfield(i, "botUserId"),
          "botName": p55_jfield(i, "botName"),
          "botImage": p55_jfield(i, "botImage"),
        }
      }
      "slack/index.connectName" =>
        match slack_connect(arg_at(a, 0)) {
          Some(c) => Json::string(@slack.connect_name(c))
          None => Json::null()
        }
      "slack/index.createAppUrl" => Json::string(@slack.create_app_url(text_at(a, 0)))
      _ => raise BusError("no such Slack function: \{name}")
    }
  })
  self.prefix_op("slack.apps.", async fn(name, arg) {
    let a = core_items(arg)
    match name {
      "slack.apps.configured" => Json::boolean(apps.configured(text_at(a, 0)))
      "slack.apps.exportManifest" => to_core(apps.export_manifest(text_at(a, 0), text_at(a, 1)))
      "slack.apps.editManifest" => {
        let f = arg_at(a, 2)
        Json::boolean(
          apps.edit_manifest(text_at(a, 0), text_at(a, 1), async fn(m) {
            match self.called(f, [to_core(m)]) {
              Null => None
              Object(o) if o.contains("$undef") => None
              v => Some(of_core(v))
            }
          }),
        )
      }
      "slack.apps.createApp" => to_core(apps.create_app(text_at(a, 0), text_at(a, 1), of_core(arg_at(a, 2))))
      "slack.apps.setIcon" => {
        apps.set_icon(text_at(a, 0), text_at(a, 1), bytes_arg(arg_at(a, 2)), text_at(a, 3))
        Json::null()
      }
      "slack.apps.exchangeInstallCode" => {
        let (token, team) = apps.exchange_install_code(text_at(a, 0), text_at(a, 1), text_at(a, 2), text_at(a, 3))
        Json::array([Json::string(token), p55_jopt(team)])
      }
      "slack.apps.verifyTokens" => {
        let (identity, errors) = apps.verify_tokens(text_at(a, 0), text_at(a, 1), text_at(a, 2))
        Json::array([
          match identity {
            Some(i) => to_core(i)
            None => Json::null()
          },
          Json::array(errors.map(Json::string(_))),
        ])
      }
      _ => raise BusError("no such call of the Slack apps: \{name}")
    }
  })
  // A Slack connect's surface asked of the Web API as its bot (`slack.chat:<id>.api`).
  self.prefix_op("slack.chat:", async fn(name, arg) {
    let rest = name.unsafe_substring(start=11, end=name.length())
    guard rest.rev_find(".") is Some(dot) else { raise BusError("no such call: \{name}") }
    let id = rest.unsafe_substring(start=0, end=dot)
    let call = rest.unsafe_substring(start=dot + 1, end=rest.length())
    guard slack.chats(id) is Some(chat) else { raise BusError("the Slack connect \{id} is not connected") }
    to_core((chat.call)(call, core_items(arg).map(of_core)))
  })
}

///|
fn to_core_ar(v : @api_routes.JV) -> Json {
  match v {
    Null => Json::null()
    Bool(b) => Json::boolean(b)
    Num(n) => Json::number(n)
    Str(s) => Json::string(s)
    Arr(xs) => Json::array(xs.map(to_core_ar))
    Obj(fs) => Json::object(Map::from_array(fs.map(kv => (kv.0, to_core_ar(kv.1)))))
  }
}

///|
/// The updates' and the copies' parts as the admin API's routes ask them (station.mbt `updates_routes`,
/// `copies_routes`).
fn P55::admin_ops(self : P55, u : @updates.Updates) -> Unit {
  self.op("updates.get", async fn(arg) { to_core(@jsjson.JValue::Arr(u.get(lang_arg(arg)))) })
  self.op("updates/versions.channelOfId", async fn(arg) { p55_jopt(@updates.channel_of_id(text_at(core_items(arg), 0))) })
  self.op("updates.setChannel", async fn(arg) {
    let a = core_items(arg)
    u.set_channel(text_at(a, 0), text_at(a, 1))
    Json::null()
  })
  self.op("updates.setAuto", async fn(arg) {
    let a = core_items(arg)
    u.set_auto(arg_at(a, 0) is True, text_at(a, 1))
    Json::null()
  })
  self.op("updates.repairCodex", async fn(arg) {
    u.repair_codex(text_at(core_items(arg), 0))
    Json::null()
  })
  self.op("updates.update", async fn(arg) {
    let a = core_items(arg)
    // (a third: the release the station goes back to)
    match arg_at(a, 2) {
      String(t) => u.update(text_at(a, 0), text_at(a, 1), to=t)
      _ => u.update(text_at(a, 0), text_at(a, 1))
    }
    Json::null()
  })
}

///|
fn P55::copies_ops(self : P55, copies : @replica_coord.Copies, retire : @replica_coord.Retire) -> Unit {
  self.op("retire.retire", async fn(arg) {
    let a = core_items(arg)
    retire.retire(text_at(a, 0), text_at(a, 1), text_at(a, 2))
    Json::null()
  })
  self.op("retire.preview", async fn(arg) { to_core(retire.preview(text_at(core_items(arg), 0))) })
  self.op("retire.cancel", async fn(arg) {
    retire.cancel(text_at(core_items(arg), 0))
    Json::null()
  })
  self.op("retire.again", async fn(arg) {
    retire.again(text_at(core_items(arg), 0))
    Json::null()
  })
  self.op("copies.restore", async fn(arg) {
    let a = core_items(arg)
    copies.restore(text_at(a, 0), text_at(a, 1), text_at(a, 2), p55_jtext(arg_at(a, 3), "station"))
    Json::null()
  })
}
