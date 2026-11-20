// What the agents spent from one time until another, added up by day in the asker's time zone and by chat, person,
// account and model, as the usage page and a Comma connect read it: from the quarters the database keeps as each call
// is written (store/usage-15m.ts `usage15mQuery`, the same statement; test/reference/store.ts `usageGroups`).

///|
let i64_top : Int64 = 9223372036854775807L

///|
/// An i64 as a statement's integer, exactly (the shell reads it as JSON).
fn i64_json(n : Int64) -> Json {
  Json::number(n.to_double(), repr=n.to_string())
}

///|
fn floor_div(n : Int64, d : Int64) -> Int64 {
  if n >= 0L {
    n / d
  } else {
    -1L - (-1L - n) / d
  }
}

///|
fn table_installed(db : @sql.Db, name : String) -> Bool raise {
  one(db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [Json::string(name)]) is Some(_)
}

///|
/// Whose usage a read is of (rows.ts InWorkspace): a workspace, and whether it is the home one (`home !== false`).
priv struct Viewer {
  workspace : String
  home : Bool
}

///|
fn viewer_of(v : Json?) -> Viewer? {
  match v {
    None | Some(Null) => None
    Some(v) =>
      Some({
        workspace: match v.value("workspace") {
          Some(String(w)) => w
          Some(w) => js_text(w)
          None => "undefined"
        },
        home: v.value("home") != Some(Json::boolean(false)),
      })
  }
}

///|
/// store/usage.ts `usageGroupOf`, of a row as a statement gives it.
fn group_of(r : Map[String, Json]) -> Group {
  let num = (k : String) => match field(r, k) { Number(n, ..) => n; _ => 0.0 }
  {
    day: match field(r, "day") { String(d) => d; _ => "" },
    session: field(r, "session"),
    thread: field(r, "thread"),
    person: field(r, "person"),
    profile: field(r, "profile"),
    runtime: field(r, "runtime"),
    model: field(r, "model"),
    fast: !(field(r, "fast") is (Null | Number(0.0, ..))),
    calls: num("calls"),
    input: num("input"),
    cache_read: num("cache_read"),
    cache_write: num("cache_write"),
    cache_write_long: num("cache_write_long"),
    output: num("output"),
  }
}

///|
/// The first whole quarter from `n` (ms) on.
fn ceil_div(n : Int64, d : Int64) -> Int64 {
  let q = n / d
  if n % d != 0L && n > 0L {
    q + 1L
  } else {
    q
  }
}

///|
/// usage-15m.ts QUARTER_MS.
let quarter_ms : Int64 = 900_000L

///|
/// usage-15m.ts `usage15mQuery`: the calls from `from` until `to` (ms; `to` i64's top: with no end) by day `offset`
/// minutes east of UTC and by session, chat, person, account, runtime and model: the whole quarters from usage_15m, the
/// calls themselves where a quarter is not wholly in the span or in one local day. None for an empty span.
fn usage_15m_query(from : Int64, to : Int64, offset : Int64, viewer : Viewer?) -> (String, Array[Json])? {
  if from >= to {
    return None
  }
  let args : Array[Json] = []
  let bind = (value : Json) => {
    args.push(value)
    "?\{args.length()}"
  }
  let off = bind(i64_json(offset))
  let scope = match viewer {
    None => "1"
    Some(v) =>
      if v.home {
        "c.scope IN (\{bind(Json::string(v.workspace))}, '')"
      } else {
        "c.scope = \{bind(Json::string(v.workspace))}"
      }
  }
  let index = if viewer is None { " INDEXED BY usage_15m_quarter" } else { "" }
  let open = to == i64_top
  let first = ceil_div(from, quarter_ms)
  let last = if open { floor_div(i64_top, quarter_ms) + 1L } else { floor_div(to, quarter_ms) }
  let raw = (pairs : String, low : String, high : String) => {
    "SELECT strftime('%Y-%m-%d', (u.at + \{off} * 60000) / 1000.0, 'unixepoch') AS day,\n" +
    "      u.session, COALESCE(u.thread, 0) AS thread, COALESCE(u.person, '') AS person, COALESCE(u.profile, '') AS profile, u.runtime,\n" +
    "      COALESCE(u.model, '') AS model, CASE WHEN u.fast != 0 THEN 1 ELSE 0 END AS fast, u.calls, u.input, u.cache_read, u.cache_write,\n" +
    "      u.cache_write_long, u.output\n" +
    "    FROM (\{pairs}) e CROSS JOIN usage u INDEXED BY usage_session ON u.session = e.session AND u.at >= \{low} AND u.at < \{high}\n" +
    "    WHERE u.rollup_counted = 1"
  }
  let parts : Array[String] = []
  let straddles = if offset * 60_000L % quarter_ms == 0L {
    None
  } else {
    Some(
      "(((c.quarter * 900000 + \{off} * 60000) % 86400000 + 86400000) % 86400000 > 85500000)",
    )
  }
  if first < last {
    let lo = bind(i64_json(first))
    let hi = bind(i64_json(last))
    parts.push(
      "SELECT strftime('%Y-%m-%d', c.quarter * 900 + \{off} * 60, 'unixepoch') AS day, c.session, c.thread, c.person,\n" +
      "      c.profile, c.runtime, c.model, c.fast, c.calls, c.input, c.cache_read, c.cache_write, c.cache_write_long, c.output\n" +
      "      FROM usage_15m c\{index} WHERE \{scope} AND c.quarter >= \{lo} AND c.quarter < \{hi}" +
      (match straddles {
        None => ""
        Some(st) => " AND NOT \{st}"
      }),
    )
    if straddles is Some(st) {
      parts.push(
        raw(
          "SELECT DISTINCT c.session, c.quarter FROM usage_15m c\{index}\n        WHERE \{scope} AND c.quarter >= \{lo} AND c.quarter < \{hi} AND \{st}",
          "e.quarter * 900000",
          "(e.quarter + 1) * 900000",
        ),
      )
    }
  }
  let edge = (quarter : Int64, low : Int64, high : Int64) => {
    if low >= high {
      return
    }
    parts.push(
      raw(
        "SELECT DISTINCT c.session FROM usage_15m c\{index} WHERE \{scope} AND c.quarter = \{bind(i64_json(quarter))}",
        bind(i64_json(low)),
        bind(i64_json(high)),
      ),
    )
  }
  if first > last {
    edge(last, from, to)
  } else {
    edge(first - 1L, from, first * quarter_ms)
    if !open {
      edge(last, last * quarter_ms, to)
    }
  }
  if parts.length() == 0 {
    return None
  }
  let sql = "WITH parts AS (\{parts.join("\n  UNION ALL\n  ")})\n" +
    "  SELECT day, session, NULLIF(thread, 0) AS thread, NULLIF(person, '') AS person, NULLIF(profile, '') AS profile, runtime,\n" +
    "    NULLIF(model, '') AS model, fast, SUM(calls) AS calls, SUM(input) AS input, SUM(cache_read) AS cache_read,\n" +
    "    SUM(cache_write) AS cache_write, SUM(cache_write_long) AS cache_write_long, SUM(output) AS output\n" +
    "  FROM parts GROUP BY day, session, thread, person, profile, runtime, model, fast\n" +
    "  ORDER BY day, session, thread, person, profile, runtime, model, fast"
  Some((sql, args))
}

///|
/// usage-15m.ts `usage15mQuery` for every workspace.
pub fn usage_15m_query_all(from : Int64, to : Int64, offset : Int64) -> (String, Array[Json])? {
  usage_15m_query(from, to, offset, None)
}

///|
/// store/usage.ts `usageGroups` for a viewer (read/store.ts `usageGroups`).
fn usage_groups(db : @sql.Db, from : Int64, to : Int64, offset : Int64, viewer : Viewer?) -> Array[Group] raise {
  match usage_15m_query(from, to, offset, viewer) {
    None => []
    Some((sql, args)) => db.all(sql, args).map(group_of)
  }
}

///|
fn utf8_order(a : String, b : String) -> Int {
  by_bytes(a, b)
}
