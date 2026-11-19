//! SQLite database operations (`sql.*` synchronous account/station databases and legacy `db.read` over `core.db`).

use std::path::PathBuf;
use std::sync::atomic::Ordering;

use serde_json::{Value, json};

use crate::{Answer, Done, Inner, err, id_of, str_of};

/// How long a statement on an account's database waits while another connection holds it.
pub(crate) const DB_WAIT: std::time::Duration = std::time::Duration::from_secs(5);

/// How long an account's database is waited for as it is opened: as long as a statement, but none in a window of the
/// app's own (MBUI_WINDOW: a run started beside the app's, which holds them all as long as it runs). That run keeps
/// them in memory at once (the core's data.ts), where it waited 5 s for each and every one before: its window showed
/// nothing for 15 s (2026-10-29 用户: 独立窗口要等很久才显示内容).
pub(crate) fn open_wait() -> std::time::Duration {
    if std::env::var_os("MBUI_WINDOW").is_some_and(|w| !w.is_empty()) {
        std::time::Duration::ZERO
    } else {
        DB_WAIT
    }
}

/// The connection to `core.db`, opened on first use.
pub(crate) struct DbHandle {
    pub(crate) path: PathBuf,
    pub(crate) conn: Option<rusqlite::Connection>,
}

fn open_db(handle: &mut DbHandle) -> Result<&mut rusqlite::Connection, String> {
    if handle.conn.is_none() {
        let conn = rusqlite::Connection::open(&handle.path).map_err(err)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA synchronous = NORMAL;
             CREATE TABLE IF NOT EXISTS records (tbl TEXT NOT NULL, key TEXT NOT NULL, value BLOB NOT NULL, PRIMARY KEY (tbl, key)) WITHOUT ROWID;",
        )
        .map_err(err)?;
        handle.conn = Some(conn);
    }
    Ok(handle.conn.as_mut().expect("opened above"))
}

/// A statement's parameters as SQLite takes them: numbers (whole ones as integers), text, null; bytes as an array.
fn sql_params(a: &Value) -> Vec<rusqlite::types::Value> {
    use rusqlite::types::Value as V;
    a.get("params")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .map(|v| match v {
                    Value::Null => V::Null,
                    Value::Bool(b) => V::Integer(i64::from(*b)),
                    Value::Number(n) => n.as_i64().map(V::Integer).unwrap_or_else(|| V::Real(n.as_f64().unwrap_or(0.0))),
                    Value::String(s) => V::Text(s.clone()),
                    Value::Array(bytes) => V::Blob(bytes.iter().map(|b| b.as_u64().unwrap_or(0) as u8).collect()),
                    Value::Object(_) => V::Text(v.to_string()),
                })
                .collect()
        })
        .unwrap_or_default()
}

impl Inner {
    pub(crate) async fn db_read(&self, a: &Value) -> Done {
        let (table, from, to) = (str_of(a, "table")?.to_string(), str_of(a, "from")?.to_string(), str_of(a, "to")?.to_string());
        let db = self.db.clone();
        self.disk(move || {
            let mut guard = db.lock().map_err(|_| "the database is gone".to_string())?;
            let conn = open_db(&mut guard)?;
            let mut query = conn.prepare_cached("SELECT key, value FROM records WHERE tbl = ?1 AND key >= ?2 AND key < ?3 ORDER BY key").map_err(err)?;
            let rows = query
                .query_map(rusqlite::params![table, from, to], |row| Ok((row.get::<_, String>(0)?, row.get::<_, Vec<u8>>(1)?)))
                .map_err(err)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(err)?;
            let keys: Vec<&String> = rows.iter().map(|(k, _)| k).collect();
            let sizes: Vec<usize> = rows.iter().map(|(_, v)| v.len()).collect();
            let json = json!({ "keys": keys, "sizes": sizes });
            Ok(Answer::bytes(json, rows.iter().flat_map(|(_, v)| v.iter().copied()).collect()))
        })
        .await
    }

    /// An account's database: opened, a statement run, its rows, closed, its file removed.
    pub(crate) fn sql(&self, op: &str, a: &Value) -> Result<Value, String> {
        let mut sqls = self.sqls.lock().map_err(|_| "the databases are gone".to_string())?;
        match op {
            "sql.open" => {
                let name = str_of(a, "name")?;
                let (path, conn) = if name == ":memory:" {
                    (None, rusqlite::Connection::open_in_memory().map_err(err)?)
                } else {
                    if name.contains('/') || name.contains('\\') || name.starts_with('.') {
                        return Err(format!("not a database name: {name}"));
                    }
                    let dir = self.dir.join("databases");
                    std::fs::create_dir_all(&dir).map_err(err)?;
                    let path = dir.join(format!("{name}.db"));
                    (Some(path.clone()), rusqlite::Connection::open(&path).map_err(err)?)
                };
                conn.busy_timeout(self.open_wait).map_err(err)?;
                conn.set_prepared_statement_cache_capacity(256);
                // One process at a time: another one finds it busy.
                conn.execute_batch("PRAGMA locking_mode = EXCLUSIVE; PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;").map_err(err)?;
                conn.busy_timeout(DB_WAIT).map_err(err)?;
                let id = self.next.fetch_add(1, Ordering::Relaxed);
                sqls.insert(id, (path, conn));
                Ok(json!({ "id": id }))
            }
            // A database another process keeps (the station's, by its path) and writes as well: never made here (but with
            // `create`), never held for this process alone, waited for `wait` ms when it is busy.
            "sql.attach" => {
                let path = PathBuf::from(str_of(a, "path")?);
                let wait = a.get("wait").and_then(Value::as_u64).unwrap_or(0);
                let mut flags = rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX | rusqlite::OpenFlags::SQLITE_OPEN_URI;
                // `create`: one of the program's own, made where it is not (station/mb src/replica's export.db).
                if a.get("create").and_then(Value::as_bool).unwrap_or(false) {
                    flags |= rusqlite::OpenFlags::SQLITE_OPEN_CREATE;
                }
                let conn = rusqlite::Connection::open_with_flags(&path, flags).map_err(err)?;
                conn.busy_timeout(std::time::Duration::from_millis(wait)).map_err(err)?;
                conn.set_prepared_statement_cache_capacity(256);
                conn.execute_batch("PRAGMA synchronous = NORMAL;").map_err(err)?;
                let id = self.next.fetch_add(1, Ordering::Relaxed);
                sqls.insert(id, (None, conn));
                Ok(json!({ "id": id }))
            }
            "sql.delete" => {
                let name = str_of(a, "name")?;
                let path = self.dir.join("databases").join(format!("{name}.db"));
                sqls.retain(|_, (p, _)| p.as_ref() != Some(&path));
                for end in ["", "-wal", "-shm", "-journal"] {
                    let file = PathBuf::from(format!("{}{end}", path.display()));
                    match std::fs::remove_file(&file) {
                        Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(err(e)),
                        _ => {}
                    }
                }
                Ok(Value::Null)
            }
            _ => {
                let id = id_of(a)?;
                if op == "sql.close" {
                    sqls.remove(&id);
                    return Ok(Value::Null);
                }
                let (_, conn) = sqls.get(&id).ok_or_else(|| format!("no database {id}"))?;
                // Whether a transaction is open on it (node:sqlite's `isTransaction`: station/src/vault/schema-install.ts).
                if op == "sql.inTransaction" {
                    return Ok(json!(!conn.is_autocommit()));
                }
                let sql = str_of(a, "sql")?;
                match op {
                    "sql.exec" => {
                        conn.execute_batch(sql).map_err(err)?;
                        Ok(Value::Null)
                    }
                    "sql.run" => {
                        let mut statement = conn.prepare_cached(sql).map_err(err)?;
                        let n = statement.execute(rusqlite::params_from_iter(sql_params(a))).map_err(err)?;
                        Ok(json!(n))
                    }
                    "sql.all" => {
                        let mut statement = conn.prepare_cached(sql).map_err(err)?;
                        let columns = statement.column_count();
                        // `named`: the columns' names beside the rows ({columns, rows}), as the station's reads give them.
                        let names: Option<Vec<String>> = a.get("named").and_then(Value::as_bool).unwrap_or(false)
                            .then(|| statement.column_names().into_iter().map(String::from).collect());
                        let mut rows = statement.query(rusqlite::params_from_iter(sql_params(a))).map_err(err)?;
                        let mut out = Vec::new();
                        while let Some(row) = rows.next().map_err(err)? {
                            let mut values = Vec::with_capacity(columns);
                            for i in 0..columns {
                                values.push(match row.get_ref(i).map_err(err)? {
                                    rusqlite::types::ValueRef::Null => Value::Null,
                                    rusqlite::types::ValueRef::Integer(v) => json!(v),
                                    rusqlite::types::ValueRef::Real(v) => json!(v),
                                    rusqlite::types::ValueRef::Text(v) => Value::String(String::from_utf8_lossy(v).into_owned()),
                                    rusqlite::types::ValueRef::Blob(v) => Value::Array(v.iter().map(|b| json!(b)).collect()),
                                });
                            }
                            out.push(Value::Array(values));
                        }
                        Ok(match names {
                            Some(columns) => json!({ "columns": columns, "rows": out }),
                            None => Value::Array(out),
                        })
                    }
                    _ => Err(format!("no operation {op}")),
                }
            }
        }
    }
}
