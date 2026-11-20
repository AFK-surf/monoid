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
        to_jv({
          "message": Json::string(p55_said_of(e)),
          "method": Json::string(m),
          "code": Json::string(code),
          "details": match details {
            Some(d) => of_jv(d)
            None => Json::null()
          },
        }),
      )
    @slack.SlackWords(key, words) => @api_routes.Thrown("SlackWords", to_jv({ "message": Json::string(words), "key": Json::string(key) }))
    @replica_coord.Thrown(_, _) => @api_routes.Thrown("mesh/bus.Refused", to_jv({ "message": Json::string(p55_said_of(e)) }))
    e => @api_routes.Thrown("Error", to_jv({ "message": Json::string(p55_said_of(e)) }))
  }
}

///|
/// A `{"$bytes": base64}` argument's bytes.
fn bytes_arg(v : Json) -> Bytes {
  @api_routes.bytes_of(to_jv(v)).unwrap_or(b"")
}

///|
/// An error as `slackError` is handed it (`{"$error": what the route caught}`), as Slack's surface threw it.
fn slack_error_of(v : Json) -> Error {
  let e = jfield(v, "$error")
  match (jtext(e, "code"), jtext(e, "key")) {
    (Some(code), _) =>
      @slack.SlackApiError(jtext_or_empty(e, "method"), code, match jfield(e, "details") {
        Null => None
        d => Some(to_jv(d))
      })
    (None, Some(key)) => @slack.SlackWords(key, jtext_or_empty(e, "message"))
    _ => BusError(jtext_or_empty(e, "message"))
  }
}

///|
/// A JSON argument as one may be absent (`{"$undef": 1}`, null): None.
fn given(v : Json) -> @jsjson.JValue? {
  match v {
    Null => None
    Object(m) if m.contains("$undef") => None
    v => Some(to_jv(v))
  }
}

///|
/// The connect kinds' parts and Slack's own, on `coord_ask`.
fn P55::connect_kind_ops(self : P55, live : ConnectsLive) -> Unit {
  let bus = self.bus
  // A kind's part, by reference (`{"$ref": kind}`): its entry edited, its connects connected again.
  self.op("connectKinds.get", async fn(arg) {
    let kind = arg_str(jitems(arg), 0)
    if live.kinds.contains(kind) {
      { "$ref": Json::string(kind) }
    } else {
      Json::null()
    }
  })
  for kind in ["slack", "feishu", "comma", "group"] {
    self.op("\{kind}.entry", async fn(arg) {
      let a = jitems(arg)
      let (given_, had) = (arg_at(a, 0), arg_at(a, 1))
      match kind {
        "slack" => of_jv(@api_routes.slack_entry(to_jv(given_), to_jv(had)))
        "feishu" => of_jv(@api_routes.feishu_entry(to_jv(given_), to_jv(had)))
        "comma" => of_jv(@api_routes.comma_entry(to_jv(given_), to_jv(had)))
        _ => group_entry(given_, had)
      }
    })
    self.op("\{kind}.reconnect", async fn(arg) {
      guard live.kinds.get(kind) is Some(c) else { return Json::null() }
      c.reconcile()
      c.refresh_identity(arg_str(jitems(arg), 0)) catch {
        e => self.warn(kind, "who the bot is not read again", e)
      }
      Json::null()
    })
  }
  // Slack's: its connects as config.json has them, who a bot is read again, a connect's surface by reference.
  let slack = live.slack
  self.op("slack.connects", async fn(_arg) {
    Json::array(@slack.slack_connects(Some(to_jv((bus.config_raw.val)()))).map(c => of_jv(c.to_j())))
  })
  self.op("slack.refreshIdentity", async fn(arg) {
    slack.refresh_identity(arg_str(jitems(arg), 0))
    Json::null()
  })
  self.op("slack.chat", async fn(arg) {
    let id = arg_str(jitems(arg), 0)
    match slack.chats(id) {
      Some(_) => { "$ref": Json::string("slack.chat:\{id}") }
      None => Json::null()
    }
  })
  // The app API with a person's configuration tokens (slack/apps.ts `SlackApps`), its rotated tokens kept in config.json.
  let client = @slack.SlackClient::new(@slack.host_net(bus.host, @slack.Wall::new(wall_ms().to_double())), base=@slack.api_base(env_get("STILLFAIL_SLACK_API")))
  let (zh, en) = catalogs_json()
  let words = @replica_coord.station_words(to_jv(zh), to_jv(en))
  let lang = Ref((bus.lang.val)())
  let apps = @slack.SlackApps::new(
    client,
    () => @slack.config_tokens(Some(to_jv((bus.config_raw.val)()))),
    async fn(token) {
      ignore(
        (bus.config_update.val)(raw => {
          let kept = jitems(jfield(raw, "slackConfigTokens")).map(to_jv)
          match raw {
            Object(m) => {
              m["slackConfigTokens"] = Json::array(@slack.upsert_token(kept, token).map(of_jv))
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
    (level, part, said, fields) => slice_log(level, part, said, of_jv(fields)),
  )
  let slack_connect = (v : Json) => @slack.slack_connects(Some(to_jv({ "connects": [v] }))).get(0)
  self.prefix_op("slack/index.", async fn(name, arg) {
    let a = jitems(arg)
    let j = (i : Int) => given(arg_at(a, i))
    match name {
      "slack/index.madeApps" => Json::array(@slack.made_apps(j(0)).map(of_jv))
      "slack/index.configTokens" => Json::array(@slack.config_tokens(j(0)).map(of_jv))
      "slack/index.appIdOf" => Json::string(@slack.app_id_of(client, arg_str(a, 1)))
      "slack/index.slackError" => Json::string(@slack.slack_error(words, slack_error_of(arg_at(a, 0)), arg_str(a, 1)))
      "slack/index.withSocketMode" => of_jv(@slack.with_socket_mode(j(0), arg_at(a, 1) is True))
      "slack/index.applySettings" => of_jv(@slack.apply_settings(j(0), j(1)))
      "slack/index.slackManifest" => of_jv(@slack.slack_manifest(arg_str(a, 0), description=arg_opt_text(a, 1), redirect_url=arg_opt_text(a, 2)))
      "slack/index.slackAppLinks" => of_jv(@slack.slack_app_links(arg_str(a, 0), arg_opt_text(a, 1)))
      "slack/index.settingsOf" => of_jv(@slack.settings_of(j(0)))
      "slack/index.rotateConfigToken" => of_jv(@slack.rotate_config_token(client, arg_str(a, 1)))
      "slack/index.ownerOfConfigToken" =>
        match @slack.owner_of_config_token(client, arg_str(a, 1)) {
          Some(o) => of_jv(o)
          None => Json::null()
        }
      "slack/index.upsertToken" => Json::array(@slack.upsert_token(jitems(arg_at(a, 0)).map(to_jv), to_jv(arg_at(a, 1))).map(of_jv))
      "slack/index.shownIdentity" => {
        let i = arg_at(a, 0)
        {
          "team": jfield(i, "team"),
          "teamId": jfield(i, "teamId"),
          "url": jfield(i, "url"),
          "botUserId": jfield(i, "botUserId"),
          "botName": jfield(i, "botName"),
          "botImage": jfield(i, "botImage"),
        }
      }
      "slack/index.connectName" =>
        match slack_connect(arg_at(a, 0)) {
          Some(c) => Json::string(@slack.connect_name(c))
          None => Json::null()
        }
      "slack/index.createAppUrl" => Json::string(@slack.create_app_url(arg_str(a, 0)))
      _ => raise BusError("no such Slack function: \{name}")
    }
  })
  self.prefix_op("slack.apps.", async fn(name, arg) {
    let a = jitems(arg)
    match name {
      "slack.apps.configured" => Json::boolean(apps.configured(arg_str(a, 0)))
      "slack.apps.exportManifest" => of_jv(apps.export_manifest(arg_str(a, 0), arg_str(a, 1)))
      "slack.apps.editManifest" => {
        let f = arg_at(a, 2)
        Json::boolean(
          apps.edit_manifest(arg_str(a, 0), arg_str(a, 1), async fn(m) {
            match self.called(f, [of_jv(m)]) {
              Null => None
              Object(o) if o.contains("$undef") => None
              v => Some(to_jv(v))
            }
          }),
        )
      }
      "slack.apps.createApp" => of_jv(apps.create_app(arg_str(a, 0), arg_str(a, 1), to_jv(arg_at(a, 2))))
      "slack.apps.setIcon" => {
        apps.set_icon(arg_str(a, 0), arg_str(a, 1), bytes_arg(arg_at(a, 2)), arg_str(a, 3))
        Json::null()
      }
      "slack.apps.exchangeInstallCode" => {
        let (token, team) = apps.exchange_install_code(arg_str(a, 0), arg_str(a, 1), arg_str(a, 2), arg_str(a, 3))
        Json::array([Json::string(token), jopt(team)])
      }
      "slack.apps.verifyTokens" => {
        let (identity, errors) = apps.verify_tokens(arg_str(a, 0), arg_str(a, 1), arg_str(a, 2))
        Json::array([
          match identity {
            Some(i) => of_jv(i)
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
    of_jv((chat.call)(call, jitems(arg).map(to_jv)))
  })
}

///|
/// The updates' and the copies' parts as the admin API's routes ask them (station.mbt `updates_routes`,
/// `copies_routes`).
fn P55::admin_ops(self : P55, u : @updates.Updates) -> Unit {
  self.op("updates.get", async fn(arg) { of_jv(@jsjson.JValue::Arr(u.get(lang_arg(arg)))) })
  self.op("updates/versions.channelOfId", async fn(arg) { jopt(@updates.channel_of_id(arg_str(jitems(arg), 0))) })
  self.op("updates.setChannel", async fn(arg) {
    let a = jitems(arg)
    u.set_channel(arg_str(a, 0), arg_str(a, 1))
    Json::null()
  })
  self.op("updates.setAuto", async fn(arg) {
    let a = jitems(arg)
    u.set_auto(arg_at(a, 0) is True, arg_str(a, 1))
    Json::null()
  })
  self.op("updates.repairCodex", async fn(arg) {
    u.repair_codex(arg_str(jitems(arg), 0))
    Json::null()
  })
  self.op("updates.update", async fn(arg) {
    let a = jitems(arg)
    // (a third: the release the station goes back to)
    match arg_at(a, 2) {
      String(t) => u.update(arg_str(a, 0), arg_str(a, 1), to=t)
      _ => u.update(arg_str(a, 0), arg_str(a, 1))
    }
    Json::null()
  })
}

///|
fn P55::copies_ops(self : P55, copies : @replica_coord.Copies, retire : @replica_coord.Retire) -> Unit {
  self.op("retire.retire", async fn(arg) {
    let a = jitems(arg)
    retire.retire(arg_str(a, 0), arg_str(a, 1), arg_str(a, 2))
    Json::null()
  })
  self.op("retire.preview", async fn(arg) { of_jv(retire.preview(arg_str(jitems(arg), 0))) })
  self.op("retire.cancel", async fn(arg) {
    retire.cancel(arg_str(jitems(arg), 0))
    Json::null()
  })
  self.op("retire.again", async fn(arg) {
    retire.again(arg_str(jitems(arg), 0))
    Json::null()
  })
  self.op("copies.restore", async fn(arg) {
    let a = jitems(arg)
    copies.restore(arg_str(a, 0), arg_str(a, 1), arg_str(a, 2), jtext_or_empty(arg_at(a, 3), "station"))
    Json::null()
  })
}
