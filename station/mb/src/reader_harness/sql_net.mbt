// Line-delimited JSON harness (`--builder harness-sql-net`) for station/test/mb-sql-net-libs-conformance.test.ts:
// exercises `station/mb/src/sql` (direct SQLite C FFI via `sql.c`) and `libs/base/src/net` (`@net.Socket`,
// `@net.Listener`, `@net.pipe_duplex` over real loopback TCP sockets via `@host`) against real Node `node:sqlite`
// and `node:net`.

///|
fn sn_at(ask : Json, k : String) -> Json? {
  match ask {
    Object(m) => m.get(k)
    _ => None
  }
}

///|
fn sn_str(ask : Json, k : String) -> String {
  match sn_at(ask, k) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
fn sn_int(ask : Json, k : String, def : Int) -> Int {
  match sn_at(ask, k) {
    Some(Number(n, ..)) => n.to_int()
    _ => def
  }
}

///|
fn sn_bool(ask : Json, k : String) -> Bool {
  sn_at(ask, k) is Some(True)
}

///|
fn sn_params(ask : Json, k : String) -> Array[Json] {
  match sn_at(ask, k) {
    Some(Array(xs)) => xs
    _ => []
  }
}

///|
fn sn_row_json(row : Map[String, Json]) -> Json {
  Json::object(row)
}

///|
async fn harness_sql_net(host : @host.Host) -> Unit {
  @effect.scoped(scope => {
    let dbs : Map[Int, @sql.Db] = Map([])
    let mut next_db = 0
    let listeners : Map[Int, (@net.Listener[@host.Conn], Ref[Int], Array[String])] = Map([])
    let mut next_listener = 0

    fn get_db(ask : Json) -> @sql.Db raise Failure {
      let id = sn_int(ask, "handle", -1)
      match dbs.get(id) {
        Some(db) => db
        None => fail("no db handle \{id}")
      }
    }

    while host.line() is Some(line) {
      if line == "" {
        continue
      }
      let ask = @json.parse(line) catch { _ => Json::null() }
      let id = sn_at(ask, "id").unwrap_or(Json::null())
      let op = sn_str(ask, "op")
      let reply : Result[Json, String] = try {
        match op {
          // ── station/mb/src/sql ──
          "sql.create" => {
            let db = @sql.Db::create(host, sn_str(ask, "path"), wait=sn_int(ask, "wait", 5000))
            next_db += 1
            dbs[next_db] = db
            Ok({ "handle": Json::number(next_db.to_double()) })
          }
          "sql.attach" => {
            let db = @sql.Db::attach(host, sn_str(ask, "path"), wait=sn_int(ask, "wait", 5000))
            next_db += 1
            dbs[next_db] = db
            Ok({ "handle": Json::number(next_db.to_double()) })
          }
          "sql.close" => {
            let hid = sn_int(ask, "handle", -1)
            if dbs.get(hid) is Some(db) {
              db.close()
              dbs.remove(hid)
            }
            Ok(Json::boolean(true))
          }
          "sql.exec" => {
            let db = get_db(ask)
            db.exec(sn_str(ask, "sql"))
            Ok(Json::boolean(true))
          }
          "sql.run" => {
            let db = get_db(ask)
            let changes = db.run(sn_str(ask, "sql"), sn_params(ask, "params"))
            Ok({ "changes": Json::number(changes.to_double()) })
          }
          "sql.all" => {
            let db = get_db(ask)
            let rows = db.all(sn_str(ask, "sql"), sn_params(ask, "params"))
            Ok({ "rows": Json::array(rows.map(sn_row_json)) })
          }
          "sql.first" => {
            let db = get_db(ask)
            let row = db.first(sn_str(ask, "sql"), sn_params(ask, "params"))
            Ok({ "row": match row { Some(r) => sn_row_json(r); None => Json::null() } })
          }
          "sql.write" => {
            let db = get_db(ask)
            let steps = sn_params(ask, "steps")
            let changes_list : Array[Json] = []
            db.write(() => {
              for step in steps {
                match sn_str(step, "op") {
                  "exec" => db.exec(sn_str(step, "sql"))
                  "run" => {
                    let c = db.run(sn_str(step, "sql"), sn_params(step, "params"))
                    changes_list.push(Json::number(c.to_double()))
                  }
                  "fail" => raise @wire.ShellError(sn_str(step, "message"))
                  other => raise @wire.ShellError("unknown step \{other}")
                }
              }
            })
            Ok({ "changes": Json::array(changes_list) })
          }
          "sql.bind_special" => {
            let db = get_db(ask)
            let kind = sn_str(ask, "kind")
            let sql = sn_str(ask, "sql")
            let val : Json = match kind {
              "nan" => Json::number(0.0 / 0.0)
              "pos_inf" => Json::number(1.0 / 0.0)
              "neg_inf" => Json::number(-1.0 / 0.0)
              "neg_zero" => Json::number(-0.0)
              "neg_zero_repr" => Json::number(-0.0, repr="-0.0")
              "int64_max" => Json::number(9223372036854775807.0, repr="9223372036854775807")
              "int64_min" => Json::number(-9223372036854775808.0, repr="-9223372036854775808")
              "over_safe" => Json::number(9007199254740993.0, repr="9007199254740993")
              "under_safe" => Json::number(-9007199254740993.0, repr="-9007199254740993")
              "nul_text" => Json::string("alpha\u{0}beta\u{0}gamma")
              "empty_blob" => Json::array([])
              "large_blob" => {
                let sz = sn_int(ask, "size", 65536)
                Json::array(Array::makei(sz, i => Json::number(((i * 37 + 11) & 0xff).to_double())))
              }
              _ => Json::null()
            }
            let c = db.run(sql, [val])
            Ok({ "changes": Json::number(c.to_double()) })
          }
          "sql.known_tx" => {
            let db = get_db(ask)
            let calls = Ref(0)
            let out_a = db.known("k", () => {
              calls.val += 1
              Json::number(calls.val.to_double())
            })
            let out_b = db.known("k", () => {
              calls.val += 1
              Json::number(calls.val.to_double())
            })
            let tx_vals : Array[Json] = []
            db.write(() => {
              tx_vals.push(db.known("k", () => {
                calls.val += 1
                Json::number(calls.val.to_double())
              }))
              tx_vals.push(db.known("k", () => {
                calls.val += 1
                Json::number(calls.val.to_double())
              }))
              ignore(db.run("CREATE TABLE IF NOT EXISTS _known_tmp (x INTEGER)", []))
              tx_vals.push(db.known("k", () => {
                calls.val += 1
                Json::number(calls.val.to_double())
              }))
            })
            Ok({ "outside": Json::array([out_a, out_b]), "inside": Json::array(tx_vals) })
          }
          "sql.meta" => {
            let db = get_db(ask)
            let kind = sn_str(ask, "kind")
            let name = sn_str(ask, "name")
            Ok({
              "schema_version": db.schema_version(),
              "has_schema": Json::boolean(db.has_schema(kind, name)),
              "master_sql": match db.sqlite_master_sql(kind, name) {
                Some(s) => Json::string(s)
                None => Json::null()
              },
            })
          }
          "sql.is_busy" =>
            Ok(Json::boolean(@sql.busy(@wire.ShellError(sn_str(ask, "message")))))
          // ── libs/base/src/net over real TCP (@host) ──
          "net.connect_half_close" => {
            let port = sn_int(ask, "port", 0)
            let send_bytes = @codec.hex_decode(sn_str(ask, "send_hex")).unwrap_or(b"")
            let wait_eof_first = sn_bool(ask, "wait_eof_first")
            let conn = host.tcp_open(port)
            let s = conn.socket
            let buf = @buffer.new()
            if wait_eof_first {
              while s.read() is Some(chunk) {
                buf.write_bytes(chunk)
              }
              let closed_after_eof = s.is_closed()
              if send_bytes.length() > 0 {
                s.write(send_bytes)
              }
              s.end_write()
              let closed_after_end = s.is_closed()
              Ok({
                "received_hex": Json::string(@codec.hex_encode(buf.to_bytes())),
                "closed_after_eof": Json::boolean(closed_after_eof),
                "closed_after_end": Json::boolean(closed_after_end),
              })
            } else {
              if send_bytes.length() > 0 {
                s.write(send_bytes)
              }
              s.end_write()
              let closed_after_end = s.is_closed()
              while s.read() is Some(chunk) {
                buf.write_bytes(chunk)
              }
              let closed_after_eof = s.is_closed()
              Ok({
                "received_hex": Json::string(@codec.hex_encode(buf.to_bytes())),
                "closed_after_end": Json::boolean(closed_after_end),
                "closed_after_eof": Json::boolean(closed_after_eof),
              })
            }
          }
          "net.connect_expect_error" => {
            let port = sn_int(ask, "port", 0)
            let conn = host.tcp_open(port)
            conn.socket.destroy()
            Ok({ "connected": Json::boolean(true) })
          }
          "net.connect_read_rst" => {
            let port = sn_int(ask, "port", 0)
            let conn = host.tcp_open(port)
            let s = conn.socket
            let buf = @buffer.new()
            let err_msg = try {
              // Signal the peer that connect succeeded so RST happens deterministically during read
              s.write(b"!")
              while s.read() is Some(chunk) {
                buf.write_bytes(chunk)
              }
              None
            } catch {
              e => Some("\{e}")
            }
            let closed = s.is_closed()
            s.destroy()
            Ok({
              "received_hex": Json::string(@codec.hex_encode(buf.to_bytes())),
              "error": match err_msg { Some(m) => Json::string(m); None => Json::null() },
              "closed": Json::boolean(closed),
            })
          }
          "net.pipe_proxy_start" => {
            let target_port = sn_int(ask, "target_port", 0)
            let listening = host.tcp_listen_local(0)
            let listener = host.listener_of(listening.id, retry_ms=20)
            let accepted = Ref(0)
            let errors : Array[String] = []
            next_listener += 1
            let lid = next_listener
            listeners[lid] = (listener, accepted, errors)
            ignore(
              scope.fork_daemon(
                "net-pipe-proxy",
                async fn() {
                  listener.serve(
                    scope,
                    async fn(client) {
                      accepted.val += 1
                      let upstream = host.tcp_open(target_port) catch {
                        e => {
                          client.socket.destroy()
                          raise e
                        }
                      }
                      @net.pipe_duplex(client.socket, upstream.socket)
                    },
                    on_error=e => errors.push("\{e}"),
                  )
                },
                on_error=e => errors.push("\{e}"),
              ),
            )
            Ok({
              "listener_id": Json::number(lid.to_double()),
              "port": Json::number(listening.port.to_double()),
            })
          }
          "net.listen_stop" => {
            let lid = sn_int(ask, "listener_id", -1)
            match listeners.get(lid) {
              Some((listener, accepted, errors)) => {
                listener.close()
                listeners.remove(lid)
                Ok({
                  "accepted": Json::number(accepted.val.to_double()),
                  "errors": Json::array(errors.map(x => Json::string(x))),
                })
              }
              None => Err("no listener \{lid}")
            }
          }
          other => Err("unknown op \{other}")
        }
      } catch {
        e => Err("\{e}")
      }
      match reply {
        Ok(v) => host.say(Json::object({ "id": id, "ok": v }).stringify())
        Err(m) => host.say(Json::object({ "id": id, "error": Json::string(m) }).stringify())
      }
    }
    for _, db in dbs {
      db.close()
    }
    for _, entry in listeners {
      entry.0.close()
    }
  }) catch {
    _ => ()
  }
}
