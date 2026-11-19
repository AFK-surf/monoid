//! Filesystem, key-value storage, text streaming, and subprocess operations (`storage.*`, `fs.*`, `text.*`,
//! `proc.run`).

use std::path::PathBuf;
use std::sync::Mutex;
use std::sync::atomic::Ordering;

use serde_json::{Value, json};

use crate::{Answer, Done, Inner, err, id_of, str_of};

/// A file being read a part at a time (`text.open`).
pub(crate) struct TextReader {
    source: Box<dyn std::io::Read + Send>,
    /// Read and not given yet.
    held: Vec<u8>,
    lines: bool,
    done: bool,
}

/// How much of a file a part holds at most, past a line's end (counter.ts CHUNK).
const TEXT_PART: usize = 8 << 20;

impl TextReader {
    fn fill(&mut self, want: usize) {
        while !self.done && self.held.len() < want {
            let mut buf = vec![0u8; (want - self.held.len()).max(64 << 10)];
            match self.source.read(&mut buf) {
                Ok(0) | Err(_) => self.done = true,
                Ok(n) => self.held.extend_from_slice(&buf[..n]),
            }
        }
    }

    fn next(&mut self) -> Option<String> {
        self.fill(TEXT_PART);
        if self.lines {
            // (a part ends at the last line end in its window, else at the first after it, as counter.ts `partsOf`)
            let window = self.held.len().min(TEXT_PART);
            let cut = match self.held[..window].iter().rposition(|&b| b == b'\n') {
                Some(i) => i,
                None => loop {
                    if let Some(i) = self.held.iter().position(|&b| b == b'\n') {
                        break i;
                    }
                    if self.done {
                        return None;
                    }
                    let more = self.held.len() + TEXT_PART;
                    self.fill(more);
                },
            };
            let part: Vec<u8> = self.held.drain(..=cut).collect();
            return Some(String::from_utf8_lossy(&part).into_owned());
        }
        if self.held.is_empty() {
            return None;
        }
        // (a piece ends where a character does, but at the end)
        let mut end = self.held.len().min(TEXT_PART);
        if end < self.held.len() || !self.done {
            let mut back = 0;
            while back < 3 && end > back && (self.held[end - 1 - back] & 0xc0) == 0x80 {
                back += 1;
            }
            if end > back && self.held[end - 1 - back] >= 0xc0 {
                let lead = self.held[end - 1 - back];
                let len = if lead >= 0xf0 { 4 } else if lead >= 0xe0 { 3 } else { 2 };
                if back + 1 < len {
                    end -= back + 1;
                }
            }
        }
        if end == 0 {
            end = self.held.len();
        }
        let piece: Vec<u8> = self.held.drain(..end).collect();
        Some(String::from_utf8_lossy(&piece).into_owned())
    }
}

/// `path` made absolute and its `.` and `..` taken out by their names alone, as Node's path.resolve does.
fn lexical(path: &std::path::Path) -> PathBuf {
    use std::path::Component;
    let mut out = PathBuf::new();
    for c in path.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            c => out.push(c),
        }
    }
    out
}

/// A link's target without Windows' `\\?\` (as libuv's readlink gives it).
fn plain(target: PathBuf) -> PathBuf {
    let s = target.to_string_lossy().into_owned();
    if let Some(rest) = s.strip_prefix(r"\\?\UNC\") {
        PathBuf::from(format!(r"\\{rest}"))
    } else if let Some(rest) = s.strip_prefix(r"\\?\") {
        PathBuf::from(rest)
    } else {
        target
    }
}

/// Node's realpathSync (lib/fs.js, its JavaScript one): the path resolved, then each part from the root looked at
/// (lstat) and a link replaced by its target resolved against the parts before it, again from the root.
fn node_realpath(path: &str) -> std::io::Result<String> {
    use std::path::Component;
    let mut path = lexical(&std::path::absolute(path)?);
    let mut links = 0;
    'again: loop {
        let parts: Vec<Component> = path.components().collect();
        let mut done = PathBuf::new();
        for (i, part) in parts.iter().enumerate() {
            if !matches!(part, Component::Normal(_)) {
                done.push(part);
                continue;
            }
            let next = done.join(part);
            if std::fs::symlink_metadata(&next)?.file_type().is_symlink() {
                links += 1;
                if links > 256 {
                    return Err(std::io::Error::other("too many links"));
                }
                let mut resolved = lexical(&done.join(plain(std::fs::read_link(&next)?)));
                for rest in &parts[i + 1..] {
                    resolved.push(rest);
                }
                path = resolved;
                continue 'again;
            }
            done = next;
        }
        return Ok(done.to_string_lossy().into_owned());
    }
}

/// File names hold only letters, digits, `-` and `_`; the rest is %XX (as the Rust core had them).
pub(crate) fn storage_path(dir: &std::path::Path, key: &str) -> PathBuf {
    let mut name = String::new();
    for byte in key.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' => name.push(byte as char),
            _ => name.push_str(&format!("%{byte:02X}")),
        }
    }
    dir.join(name)
}

/// A file to write a kept value in (`storage.set`: the partial one, renamed over the value once written). On Unix
/// its user's alone whatever the process's umask (0600, less what the umask takes of that): a value kept is a
/// device's key among others, and was readable by whomever the umask let (0644 under most), unless the program had
/// set the whole process's umask for it. What a crash left there is taken away first and the file made only if none
/// is there, so its mode is the one it is made with (none is set after: a filesystem may refuse that, where writing
/// did not fail before) and nothing is written through a link left in its place. One shell writes its values one
/// at a time (the disk thread). Two processes writing one key at once, which no program does, each write a file of
/// their own, and one of them fails (here, or at its rename), where their bytes went into one file before.
fn create_private(path: &std::path::Path) -> std::io::Result<std::fs::File> {
    #[cfg(unix)]
    {
        match std::fs::remove_file(path) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(e),
            _ => {}
        }
        let mut options = std::fs::OpenOptions::new();
        std::os::unix::fs::OpenOptionsExt::mode(options.write(true).create_new(true), 0o600);
        options.open(path)
    }
    #[cfg(not(unix))]
    {
        std::fs::File::create(path)
    }
}

/// `fs.scan` of one path.
fn scan_one(path: &str, follow: bool, hash: bool, most: u64) -> Result<Value, String> {
    let Ok(m) = (if follow { std::fs::metadata(path) } else { std::fs::symlink_metadata(path) }) else { return Ok(Value::Null) };
    let kind = if m.file_type().is_symlink() { "link" } else if m.is_file() { "file" } else if m.is_dir() { "dir" } else { "other" };
    #[cfg(unix)]
    let (mode, dev) = {
        use std::os::unix::fs::MetadataExt;
        (m.mode(), m.dev())
    };
    #[cfg(not(unix))]
    let (mode, dev) = (if m.permissions().readonly() { 0o444 } else { 0o666 }, 0u64);
    let mut v = json!({ "kind": kind, "size": m.len(), "mode": mode, "dev": dev });
    if hash && kind == "link" {
        let target = std::fs::read_link(path).map_err(err)?;
        v["link"] = json!(target.to_string_lossy());
    } else if hash && kind == "file" && m.len() <= most {
        use sha1::Digest;
        use std::io::Read;
        let mut file = std::fs::File::open(path).map_err(err)?;
        let size = m.len();
        let mut h = sha1::Sha1::new();
        h.update(format!("blob {size}\0").as_bytes());
        let (mut buf, mut read) = (vec![0u8; 1 << 20], 0u64);
        loop {
            let n = file.read(&mut buf).map_err(err)?;
            if n == 0 {
                break;
            }
            read += n as u64;
            h.update(&buf[..n]);
        }
        if read != size {
            return Err(format!("{path} changed while it was read"));
        }
        v["hash"] = json!(hex::encode(h.finalize()));
    }
    Ok(v)
}

/// A file of the program's own made anew where it writes what no one else is to read: 0600.
pub(crate) fn own_file(path: &std::path::Path) -> Result<std::fs::File, String> {
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let file = options.open(path).map_err(err)?;
    // (made before, with other bits: as archive.ts's chmod)
    #[cfg(unix)]
    file.set_permissions(std::os::unix::fs::PermissionsExt::from_mode(0o600)).map_err(err)?;
    Ok(file)
}

/// As much as `source` gives up to `buf`'s length (less only at its end).
pub(crate) fn read_up_to(source: &mut dyn std::io::Read, buf: &mut [u8]) -> std::io::Result<usize> {
    let mut got = 0;
    while got < buf.len() {
        match source.read(&mut buf[got..]) {
            Ok(0) => break,
            Ok(n) => got += n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    Ok(got)
}

impl Inner {
    pub(crate) async fn run_fs_async(&self, op: &str, a: &Value, bytes: Option<Vec<u8>>) -> Done {
        match op {
            // `bytes` written into the file at `path` (station/mb src/reader remote.mbt): at `offset` (none: appended),
            // made where it is not (`exclusive`: refused where it is), never through a link (`nofollow`), cut to what
            // ends there with `truncate`, synced to the disk with `sync`; a regular file only. How long it is then.
            "fs.put" => {
                let path = PathBuf::from(str_of(a, "path")?);
                let input = bytes.unwrap_or_default();
                let offset = a.get("offset").and_then(Value::as_u64);
                let flag = |k: &str| a.get(k).and_then(Value::as_bool).unwrap_or(false);
                let (exclusive, nofollow, truncate, sync) = (flag("exclusive"), flag("nofollow"), flag("truncate"), flag("sync"));
                let mode = a.get("mode").and_then(Value::as_u64).unwrap_or(0o666) as u32;
                let size = tokio::task::spawn_blocking(move || -> Result<u64, String> {
                    use std::io::{Seek, SeekFrom, Write};
                    let mut o = std::fs::OpenOptions::new();
                    o.write(true);
                    if exclusive { o.create_new(true); } else { o.create(true); }
                    #[cfg(unix)]
                    {
                        use std::os::unix::fs::OpenOptionsExt;
                        o.mode(mode);
                        if nofollow { o.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK); }
                    }
                    #[cfg(not(unix))]
                    let _ = (mode, nofollow);
                    let mut file = o.open(&path).map_err(err)?;
                    if !file.metadata().map_err(err)?.is_file() {
                        return Err("only regular files can be transferred".into());
                    }
                    let at = match offset { Some(at) => at, None => file.seek(SeekFrom::End(0)).map_err(err)? };
                    file.seek(SeekFrom::Start(at)).map_err(err)?;
                    file.write_all(&input).map_err(err)?;
                    let end = at + input.len() as u64;
                    if truncate { file.set_len(end).map_err(err)?; }
                    if sync { file.sync_all().map_err(err)?; }
                    Ok(file.metadata().map_err(err)?.len())
                })
                .await
                .map_err(err)??;
                Ok(Answer::json(json!({ "size": size })))
            }
            "storage.get" => {
                let path = storage_path(&self.dir, str_of(a, "key")?);
                self.disk(move || match std::fs::read(&path) {
                    Ok(bytes) => Ok(Answer::bytes(json!({}), bytes)),
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Answer::json(json!({ "none": true }))),
                    Err(e) => Err(err(e)),
                })
                .await
            }
            "storage.set" => {
                let path = storage_path(&self.dir, str_of(a, "key")?);
                let value = bytes.unwrap_or_default();
                self.disk(move || {
                    // Written aside and renamed over: a crash leaves the old value or the new one, never half.
                    // Synced through the handle it was written with: Windows syncs only a handle that may write (one
                    // opened again to read, as this did, failed every storage.set there).
                    let partial = path.with_extension("partial");
                    let mut file = create_private(&partial).map_err(err)?;
                    std::io::Write::write_all(&mut file, &value).and_then(|()| file.sync_all()).map_err(err)?;
                    drop(file);
                    std::fs::rename(&partial, &path).map_err(err)?;
                    Ok(Answer::json(json!({})))
                })
                .await
            }
            "storage.delete" => {
                let path = storage_path(&self.dir, str_of(a, "key")?);
                self.disk(move || match std::fs::remove_file(&path) {
                    Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(err(e)),
                    _ => Ok(Answer::json(json!({}))),
                })
                .await
            }
            other => Err(format!("no operation {other}")),
        }
    }

    pub(crate) fn run_fs_sync(&self, op: &str, a: &Value) -> Result<Option<Value>, String> {
        // The file a key's value is kept in, for what reads it there itself (a face's file: client/core-ts
        // font-files.ts); null while none is kept.
        if op == "storage.path" {
            let path = storage_path(&self.dir, str_of(a, "key")?);
            return Ok(Some(if path.is_file() { json!(path.to_string_lossy()) } else { Value::Null }));
        }
        // A path's kind as stat (links followed) says it: "file", "dir" or "other"; null when it cannot be (none there,
        // no right): what the station's programs ask of the filesystem (station/mb src/locate), as Node's statSync does.
        // With `lstat`, the path itself as lstat says it (a link "link", not followed).
        if op == "fs.stat" {
            let path = str_of(a, "path")?;
            let lstat = a.get("lstat").and_then(Value::as_bool).unwrap_or(false);
            return Ok(Some(match if lstat { std::fs::symlink_metadata(path) } else { std::fs::metadata(path) } {
                Ok(m) if m.file_type().is_symlink() => json!("link"),
                Ok(m) if m.is_file() => json!("file"),
                Ok(m) if m.is_dir() => json!("dir"),
                Ok(_) => json!("other"),
                Err(_) => Value::Null,
            }));
        }
        // A directory's names, with their kinds as the directory says them (`types`: [name, "file" | "dir" | "link" |
        // "other"], links not followed), in Node's readdirSync's order (libuv sorts them by their bytes, but on Windows);
        // null when it cannot be read.
        // `disk`: in the order the file system gives them (Node's opendirSync, Rust's read_dir), an entry that does not
        // read ending the list rather than failing it (station/src/read/machine.ts `readDir`).
        if op == "fs.readdir" {
            let Ok(entries) = std::fs::read_dir(str_of(a, "path")?) else { return Ok(Some(Value::Null)) };
            let disk = a.get("disk").and_then(Value::as_bool).unwrap_or(false);
            let mut out: Vec<(String, &str)> = Vec::new();
            for entry in entries {
                let Ok(entry) = entry else {
                    if disk {
                        break;
                    }
                    return Ok(Some(Value::Null));
                };
                let kind = match entry.file_type() {
                    Ok(t) if t.is_symlink() => "link",
                    Ok(t) if t.is_dir() => "dir",
                    Ok(t) if t.is_file() => "file",
                    _ => "other",
                };
                out.push((entry.file_name().to_string_lossy().into_owned(), kind));
            }
            if !cfg!(windows) && !disk {
                out.sort_by(|x, y| x.0.as_bytes().cmp(y.0.as_bytes()));
            }
            let types = a.get("types").and_then(Value::as_bool).unwrap_or(false);
            return Ok(Some(Value::Array(out.into_iter().map(|(name, kind)| if types { json!([name, kind]) } else { json!(name) }).collect())));
        }
        // A path with its links resolved as Node's realpathSync resolves them (each part looked at, a link's target put in
        // its place; the parts' names as given, not as the disk spells them); null when a part is not there.
        if op == "fs.realpath" {
            return Ok(Some(node_realpath(str_of(a, "path")?).map_or(Value::Null, |p| json!(p))));
        }
        // A file's text: `strict` as a TextDecoder with `fatal` reads it (a leading byte order mark dropped, none when it
        // is not UTF-8), else as Node's readFileSync(path, "utf8") does (what is not UTF-8 replaced); null when it does
        // not read.
        // A transcript read a part at a time (station/src/usage/counter.ts `readFrom`, search/sources.ts `mentions`): the
        // file as long as it was when opened, or its `.zst` (every frame, the seek table passed over) when the file is
        // not there. Each `text.next` is the next part, decoded as Buffer.toString("utf8") does: `lines` whole lines of
        // at most about 8 MB (a last line without its end left out, as readFrom leaves it), else every byte, in pieces
        // cut where a character ends. Null at the end; `text.close` lets it go.
        if op == "text.open" {
            let path = PathBuf::from(str_of(a, "path")?);
            let lines = a.get("lines").and_then(Value::as_bool).unwrap_or(false);
            let packed = PathBuf::from(format!("{}.zst", path.display()));
            let source: Box<dyn std::io::Read + Send> = match std::fs::File::open(&path) {
                Ok(file) => {
                    let size = file.metadata().map(|m| m.len()).unwrap_or(0);
                    Box::new(std::io::Read::take(file, size))
                }
                Err(_) => match std::fs::File::open(&packed) {
                    Ok(file) => match zstd::stream::read::Decoder::new(file) {
                        Ok(d) => Box::new(d),
                        Err(_) => return Ok(Some(Value::Null)),
                    },
                    Err(_) => return Ok(Some(Value::Null)),
                },
            };
            let id = self.next.fetch_add(1, Ordering::Relaxed);
            self.texts.lock().map_err(|_| "the readers are gone".to_string())?.insert(id, TextReader { source, held: Vec::new(), lines, done: false });
            return Ok(Some(json!({ "id": id })));
        }
        if op == "text.next" {
            let id = id_of(a)?;
            let mut texts = self.texts.lock().map_err(|_| "the readers are gone".to_string())?;
            let reader = texts.get_mut(&id).ok_or_else(|| format!("no reader {id}"))?;
            return Ok(Some(reader.next().map_or(Value::Null, Value::String)));
        }
        if op == "text.close" {
            self.texts.lock().map_err(|_| "the readers are gone".to_string())?.remove(&id_of(a)?);
            return Ok(Some(Value::Null));
        }
        // A path's size and when it was last written (ms, none before 1970), links followed, as Node's statSync with
        // `bigint` says them; null when it cannot be.
        if op == "fs.meta" {
            let Ok(meta) = std::fs::metadata(str_of(a, "path")?) else { return Ok(Some(Value::Null)) };
            let since = meta.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok());
            let modified = since.map(|d| d.as_millis() as u64);
            // `mtime`: as Node's statSync (no `bigint`) says `mtimeMs`, its fraction of a millisecond kept.
            let mtime = since.map(|d| d.as_secs() as f64 * 1e3 + d.subsec_nanos() as f64 / 1e6);
            return Ok(Some(json!({ "size": meta.len(), "mtimeMs": modified, "mtime": mtime, "dir": meta.is_dir() })));
        }
        // The end of a file, at most `bytes` of it (up to its size when opened), decoded as TextDecoder("utf-8") does
        // (what is not UTF-8 replaced, a leading byte order mark dropped); null when it does not open.
        if op == "fs.tail" {
            use std::io::{Read, Seek, SeekFrom};
            let Ok(mut file) = std::fs::File::open(str_of(a, "path")?) else { return Ok(Some(Value::Null)) };
            let most = a.get("bytes").and_then(Value::as_u64).unwrap_or(64 * 1024);
            let size = file.metadata().map(|m| m.len()).unwrap_or(most);
            let from = size.saturating_sub(most);
            let mut bytes = Vec::new();
            if file.seek(SeekFrom::Start(from)).is_ok() {
                let _ = file.take(size - from).read_to_end(&mut bytes);
            }
            let body = bytes.strip_prefix(b"\xef\xbb\xbf").unwrap_or(&bytes);
            return Ok(Some(json!(String::from_utf8_lossy(body))));
        }
        // Bytes of a file as hex, from byte `from` (0), `length` of them where it says (to its end where not), or with
        // `zstd` what the zstd frames there hold (station/mb src/history's transcripts read a piece at a time, a put-away
        // one a frame at a time); with `exact`, a file that ends before `length` is a failure. Null when it does not open.
        if op == "fs.bytes" {
            use std::io::{Read, Seek, SeekFrom};
            let Ok(mut file) = std::fs::File::open(str_of(a, "path")?) else { return Ok(Some(Value::Null)) };
            let from = a.get("from").and_then(Value::as_u64).unwrap_or(0);
            let length = a.get("length").and_then(Value::as_u64);
            let mut bytes = Vec::new();
            file.seek(SeekFrom::Start(from)).map_err(err)?;
            match length {
                Some(n) => file.take(n).read_to_end(&mut bytes),
                None => file.read_to_end(&mut bytes),
            }
            .map_err(err)?;
            if a.get("exact").and_then(Value::as_bool).unwrap_or(false) && length.is_some_and(|n| (bytes.len() as u64) < n) {
                return Err("a put-away transcript ended early".into());
            }
            if a.get("zstd").and_then(Value::as_bool).unwrap_or(false) {
                bytes = zstd::decode_all(bytes.as_slice()).map_err(err)?;
            }
            return Ok(Some(json!(hex::encode(bytes))));
        }
        // A program run to its end, as Node's execFileSync runs one (station/src/read/sessions.ts `inRepositories`: `git
        // ls-files`): `command` with `args`, nothing on its stdin and its stderr let go, its stdout decoded as
        // Buffer.toString("utf8") does; null where it did not end well: not started, ended by a signal or with a code
        // not 0, still running after `timeoutMs` (killed then), or writing more than `maxBytes`.
        if op == "proc.run" {
            use std::io::Read;
            use std::process::{Command, Stdio};
            let args: Vec<String> = a.get("args").and_then(Value::as_array).map(|v| v.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
            let timeout = std::time::Duration::from_millis(a.get("timeoutMs").and_then(Value::as_u64).unwrap_or(5000));
            let most = a.get("maxBytes").and_then(Value::as_u64).unwrap_or(1 << 20) as usize;
            // `env`: variables set besides the station's; `hex`: its stdout as hex (bytes, not words: `git cat-file`);
            // `code`: {code, out} for any end it came to (`git check-ignore`'s 1 says something), null still where it did not.
            let mut command = Command::new(str_of(a, "command")?);
            command.args(&args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
            if let Some(env) = a.get("env").and_then(Value::as_object) {
                for (k, v) in env {
                    if let Some(v) = v.as_str() { command.env(k, v); }
                }
            }
            let Ok(mut child) = command.spawn() else {
                return Ok(Some(Value::Null));
            };
            let mut stdout = child.stdout.take().expect("piped");
            let reading = std::thread::spawn(move || {
                let mut out = Vec::new();
                let over = (&mut stdout).take(most as u64 + 1).read_to_end(&mut out).is_err() || out.len() > most;
                (out, over)
            });
            let started = std::time::Instant::now();
            let status = loop {
                match child.try_wait() {
                    Ok(Some(status)) => break Some(status),
                    Ok(None) if started.elapsed() < timeout => std::thread::sleep(std::time::Duration::from_millis(2)),
                    _ => {
                        let _ = child.kill();
                        let _ = child.wait();
                        break None;
                    }
                }
            };
            let (out, over) = reading.join().unwrap_or((Vec::new(), true));
            let said = |out: &[u8]| if a.get("hex").and_then(Value::as_bool).unwrap_or(false) { json!(hex::encode(out)) } else { json!(String::from_utf8_lossy(out)) };
            if a.get("code").and_then(Value::as_bool).unwrap_or(false) {
                return Ok(Some(match status.and_then(|s| s.code()) {
                    Some(code) if !over => json!({ "code": code, "out": said(&out) }),
                    _ => Value::Null,
                }));
            }
            return Ok(Some(match status {
                Some(s) if s.success() && !over => said(&out),
                _ => Value::Null,
            }));
        }
        // What a link points to, as Node's readlinkSync gives it; null when the path is no link or cannot be read.
        if op == "fs.readlink" {
            return Ok(Some(std::fs::read_link(str_of(a, "path")?).map_or(Value::Null, |p| json!(p.to_string_lossy()))));
        }
        // A file from byte `from` to its end, decoded as Buffer.toString("utf8") does (what is not UTF-8 replaced, a byte
        // order mark kept); null when it does not open.
        if op == "fs.from" {
            use std::io::{Read, Seek, SeekFrom};
            let Ok(mut file) = std::fs::File::open(str_of(a, "path")?) else { return Ok(Some(Value::Null)) };
            let from = a.get("from").and_then(Value::as_u64).unwrap_or(0);
            let mut bytes = Vec::new();
            if file.seek(SeekFrom::Start(from)).is_err() || file.read_to_end(&mut bytes).is_err() {
                return Ok(Some(Value::Null));
            }
            return Ok(Some(json!(String::from_utf8_lossy(&bytes))));
        }
        // A file's lines as Rust's BufRead::lines with map_while(Result::ok) reads them (station/src/read/machine.ts
        // `lines`): without their "\n" or "\r\n", each decoded strictly with a leading byte order mark dropped, ending at
        // the first that is not UTF-8 or at a read that fails; at most `limit`. A line longer than `max` bytes (its "\n"
        // counted) is read as "". None when the file does not open: an empty list.
        if op == "fs.lines" {
            use std::io::Read;
            let Ok(mut file) = std::fs::File::open(str_of(a, "path")?) else { return Ok(Some(json!([]))) };
            let limit = a.get("limit").and_then(Value::as_u64).map_or(usize::MAX, |n| n as usize);
            let max = a.get("max").and_then(Value::as_u64).map_or(usize::MAX, |n| n as usize);
            let mut out: Vec<Value> = Vec::new();
            let mut pending: Vec<u8> = Vec::new();
            let mut over = false;
            // Whether more are wanted.
            let take = |line: &[u8], over: &mut bool, out: &mut Vec<Value>| -> bool {
                if *over {
                    *over = false;
                    out.push(json!(""));
                    return out.len() < limit;
                }
                let mut line = line;
                if line.last() == Some(&b'\n') {
                    line = &line[..line.len() - 1];
                }
                if line.last() == Some(&b'\r') {
                    line = &line[..line.len() - 1];
                }
                let body = line.strip_prefix(b"\xef\xbb\xbf").unwrap_or(line);
                match std::str::from_utf8(body) {
                    Ok(text) => out.push(json!(text)),
                    Err(_) => return false,
                }
                out.len() < limit
            };
            let mut chunk = vec![0u8; 1 << 16];
            loop {
                let n = match file.read(&mut chunk) {
                    Ok(n) => n,
                    Err(_) => return Ok(Some(Value::Array(out))),
                };
                if n == 0 {
                    break;
                }
                let mut start = 0;
                let keep = |part: &[u8], pending: &mut Vec<u8>, over: &mut bool| {
                    if *over {
                        return;
                    }
                    if pending.len() + part.len() > max {
                        *over = true;
                        pending.clear();
                    } else {
                        pending.extend_from_slice(part);
                    }
                };
                while let Some(nl) = chunk[start..n].iter().position(|&b| b == b'\n').map(|i| start + i) {
                    keep(&chunk[start..=nl], &mut pending, &mut over);
                    let line = std::mem::take(&mut pending);
                    start = nl + 1;
                    if !take(&line, &mut over, &mut out) {
                        return Ok(Some(Value::Array(out)));
                    }
                }
                if start < n {
                    keep(&chunk[start..n], &mut pending, &mut over);
                }
            }
            if !pending.is_empty() || over {
                take(&pending, &mut over, &mut out);
            }
            return Ok(Some(Value::Array(out)));
        }
        // What the station's programs write (station/mb src/replica, as station/src/replica/export.ts writes): `text`
        // as a whole file at `path`, zstd's frame of it with `zstd` (level 3, as Node's zstdCompressSync), written beside
        // it, synced and renamed into place, its folders made; the SHA-256 of the bytes written and how many.
        if op == "fs.write" {
            use sha2::Digest;
            use std::io::Write;
            let path = PathBuf::from(str_of(a, "path")?);
            let text = str_of(a, "text")?.as_bytes();
            let bytes = if a.get("zstd").and_then(Value::as_bool).unwrap_or(false) { zstd::encode_all(text, 3).map_err(err)? } else { text.to_vec() };
            if let Some(dir) = path.parent() {
                std::fs::create_dir_all(dir).map_err(err)?;
            }
            let mut random = [0u8; 4];
            getrandom::fill(&mut random).map_err(err)?;
            let tmp = PathBuf::from(format!("{}.{}.{}.tmp", path.display(), std::process::id(), hex::encode(random)));
            let written = (|| {
                let mut file = std::fs::File::create(&tmp)?;
                file.write_all(&bytes)?;
                file.sync_all()
            })();
            if let Err(e) = written.and_then(|_| std::fs::rename(&tmp, &path)) {
                let _ = std::fs::remove_file(&tmp);
                return Err(err(e));
            }
            return Ok(Some(json!({ "sha256": hex::encode(sha2::Sha256::digest(&bytes)), "size": bytes.len() })));
        }
        // A file's SHA-256 (hex), read a MiB at a time; null when it does not open.
        if op == "fs.hash" {
            use sha2::Digest;
            use std::io::Read;
            let Ok(mut file) = std::fs::File::open(str_of(a, "path")?) else { return Ok(Some(Value::Null)) };
            let mut hash = sha2::Sha256::new();
            let mut buf = vec![0u8; 1 << 20];
            loop {
                let n = file.read(&mut buf).map_err(err)?;
                if n == 0 {
                    break;
                }
                hash.update(&buf[..n]);
            }
            return Ok(Some(json!(hex::encode(hash.finalize()))));
        }
        // What lstat says of `path` (links not followed), as Node's lstat gives it (station/mb src/reader/dirsync.mbt): its
        // kind, size, mode, inode, and mtime and ctime in ms (seconds and nanoseconds as Node joins them); null when
        // nothing is there.
        if op == "fs.lstat" {
            let Ok(m) = std::fs::symlink_metadata(str_of(a, "path")?) else { return Ok(Some(Value::Null)) };
            let kind = if m.file_type().is_symlink() { "link" } else if m.is_file() { "file" } else if m.is_dir() { "dir" } else { "other" };
            #[cfg(unix)]
            let (mode, ino, mtime, ctime) = {
                use std::os::unix::fs::MetadataExt;
                let ms = |s: i64, ns: i64| s as f64 * 1e3 + ns as f64 / 1e6;
                (m.mode(), m.ino(), ms(m.mtime(), m.mtime_nsec()), ms(m.ctime(), m.ctime_nsec()))
            };
            #[cfg(not(unix))]
            let (mode, ino, mtime, ctime) = {
                let ms = |t: std::io::Result<std::time::SystemTime>| t.ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map_or(0.0, |d| d.as_secs_f64() * 1e3);
                (if m.permissions().readonly() { 0o444 } else { 0o666 }, 0u64, ms(m.modified()), ms(m.modified()))
            };
            return Ok(Some(json!({ "kind": kind, "size": m.len(), "mode": mode, "ino": ino, "mtimeMs": mtime, "ctimeMs": ctime })));
        }
        // A symbolic link at `path` naming `target`.
        if op == "fs.symlink" {
            let (target, path) = (str_of(a, "target")?, str_of(a, "path")?);
            #[cfg(unix)]
            std::os::unix::fs::symlink(target, path).map_err(err)?;
            #[cfg(windows)]
            std::os::windows::fs::symlink_file(target, path).map_err(err)?;
            return Ok(Some(Value::Null));
        }
        // The permission bits of `path` set to `mode` (chmodSync); nothing where the system has none.
        if op == "fs.chmod" {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let mode = a.get("mode").and_then(Value::as_u64).ok_or("mode is required")? as u32;
                std::fs::set_permissions(str_of(a, "path")?, std::fs::Permissions::from_mode(mode)).map_err(err)?;
            }
            return Ok(Some(Value::Null));
        }
        // A hard link `to` of `from`: false when `to` is there already (EEXIST), true when made.
        if op == "fs.link" {
            return match std::fs::hard_link(str_of(a, "from")?, str_of(a, "to")?) {
                Ok(()) => Ok(Some(json!(true))),
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => Ok(Some(json!(false))),
                Err(e) => Err(err(e)),
            };
        }
        // A file's content id as Git has it (sha1 of "blob <size>\0" and its bytes), read a MiB at a time; `size` is what
        // it is to be, refused when it reads otherwise (changed while read). Null when it does not open.
        if op == "fs.gitblob" {
            use sha1::Digest;
            use std::io::Read;
            let Ok(mut file) = std::fs::File::open(str_of(a, "path")?) else { return Ok(Some(Value::Null)) };
            let size = a.get("size").and_then(Value::as_u64).ok_or("size is required")?;
            let mut hash = sha1::Sha1::new();
            hash.update(format!("blob {size}\0").as_bytes());
            let (mut buf, mut read) = (vec![0u8; 1 << 20], 0u64);
            loop {
                let n = file.read(&mut buf).map_err(err)?;
                if n == 0 {
                    break;
                }
                read += n as u64;
                hash.update(&buf[..n]);
            }
            if read != size {
                return Err(format!("{} changed while it was read", str_of(a, "path")?));
            }
            return Ok(Some(json!(hex::encode(hash.finalize()))));
        }
        // What lstat says of each of `paths` (`follow`: stat, a link followed), 8 at a time, in their order: null where
        // nothing is there, else {kind, size, mode, dev} (dev 0 where the system has none: Windows, where a folder
        // mounted in another is a link, not followed). With `hash`, a file's Git blob id too (`hash`, of one of `most`
        // bytes at most), a link's target (`link`): what a directory sync lists of the files it sends
        // (station/mb src/reader/dirsync.mbt `scan`). A file that reads otherwise than its size, or a link that does
        // not read, fails it.
        if op == "fs.scan" {
            let paths: Vec<String> = a.get("paths").and_then(Value::as_array).map(|v| v.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
            let follow = a.get("follow").and_then(Value::as_bool).unwrap_or(false);
            let hash = a.get("hash").and_then(Value::as_bool).unwrap_or(false);
            let most = a.get("most").and_then(Value::as_u64).unwrap_or(u64::MAX);
            let next = std::sync::atomic::AtomicUsize::new(0);
            let mut out: Vec<Option<Result<Value, String>>> = (0..paths.len()).map(|_| None).collect();
            let slots: Vec<Mutex<&mut Option<Result<Value, String>>>> = out.iter_mut().map(Mutex::new).collect();
            std::thread::scope(|s| {
                for _ in 0..paths.len().min(8) {
                    s.spawn(|| loop {
                        let i = next.fetch_add(1, Ordering::Relaxed);
                        if i >= paths.len() {
                            break;
                        }
                        **slots[i].lock().unwrap() = Some(scan_one(&paths[i], follow, hash, most));
                    });
                }
            });
            drop(slots);
            let mut values = Vec::with_capacity(out.len());
            for v in out {
                values.push(v.unwrap_or(Ok(Value::Null))?);
            }
            return Ok(Some(Value::Array(values)));
        }
        // A folder and those it is in, made where they are not (mkdirSync's `recursive`).
        if op == "fs.mkdir" {
            std::fs::create_dir_all(str_of(a, "path")?).map_err(err)?;
            return Ok(Some(Value::Null));
        }
        // What is at `path` let go, a folder with all it holds with `recursive`; nothing there is no failure (rmSync's
        // `force`).
        if op == "fs.remove" {
            let path = PathBuf::from(str_of(a, "path")?);
            let recursive = a.get("recursive").and_then(Value::as_bool).unwrap_or(false);
            let gone = match std::fs::symlink_metadata(&path) {
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(e) => Err(e),
                Ok(m) if m.is_dir() && recursive => std::fs::remove_dir_all(&path),
                Ok(m) if m.is_dir() => std::fs::remove_dir(&path),
                Ok(_) => std::fs::remove_file(&path),
            };
            return gone.map(|_| Some(Value::Null)).map_err(err);
        }
        if op == "fs.rename" {
            std::fs::rename(str_of(a, "from")?, str_of(a, "to")?).map_err(err)?;
            return Ok(Some(Value::Null));
        }
        if op == "fs.copy" {
            std::fs::copy(str_of(a, "from")?, str_of(a, "to")?).map_err(err)?;
            return Ok(Some(Value::Null));
        }
        if op == "fs.read" {
            let Ok(mut bytes) = std::fs::read(str_of(a, "path")?) else { return Ok(Some(Value::Null)) };
            // `zstd`: a file that is zstd's frames, read as what they hold (a copy's batch: station/mb src/replica).
            if a.get("zstd").and_then(Value::as_bool).unwrap_or(false) {
                bytes = zstd::decode_all(bytes.as_slice()).map_err(err)?;
            }
            if a.get("strict").and_then(Value::as_bool).unwrap_or(false) {
                let body = bytes.strip_prefix(b"\xef\xbb\xbf").unwrap_or(&bytes);
                return Ok(Some(std::str::from_utf8(body).map_or(Value::Null, |s| json!(s))));
            }
            return Ok(Some(json!(String::from_utf8_lossy(&bytes))));
        }
        Ok(None)
    }
}
