//! The shell's lines on stderr, shaped like the station's others there (station/native/launcher/src/log.rs): an
//! RFC 3339 time, the level, what happened. In the station's front its stderr is `stillfail.log`, which the launcher,
//! Node and the front all write: a line with no time read as hours of them to anything that looked by time (2026-11-16,
//! a watchdog's agent counted 6,000 failed handshakes in six minutes where 640 were), and written in pieces it came out
//! inside another process's line. So each is one write, time first.

use std::io::Write;
use std::time::{SystemTime, UNIX_EPOCH};

/// One line, `INFO` and what happened (its part first, `mesh: …`).
pub(crate) fn info(text: &str) {
    let ms = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64);
    let line = format!("{}  INFO {text}\n", iso(ms));
    let _ = std::io::stderr().lock().write_all(line.as_bytes());
}

/// `ms` since the epoch as UTC, to the millisecond.
pub(crate) fn iso(ms: u64) -> String {
    let (days, rest) = ((ms / 86_400_000) as i64, ms % 86_400_000);
    // Civil date from days since 1970-01-01 (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    let (h, m, s, milli) = (rest / 3_600_000, rest / 60_000 % 60, rest / 1000 % 60, rest % 1000);
    format!("{year:04}-{month:02}-{day:02}T{h:02}:{m:02}:{s:02}.{milli:03}Z")
}

#[cfg(test)]
mod tests {
    #[test]
    fn times_read_as_utc() {
        assert_eq!(super::iso(0), "1970-01-01T00:00:00.000Z");
        assert_eq!(super::iso(1_790_000_000_123), "2026-09-21T14:13:20.123Z");
        assert_eq!(super::iso(951_782_400_000), "2000-02-29T00:00:00.000Z");
    }
}
