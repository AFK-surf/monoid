//! A session's workspace put away (station/src/sessions/archive.ts `packWorkspaceIf`, `restoreWorkspace`,
//! `emptyWorkspace`, `workspaceFile`, which ask station/mb src/packed, which asks these: `tar.pack`, `tar.unpack`,
//! `tar.file`): a GNU tar as the tar crate wrote it for the Rust station (station/test/archive-rs), zstd level 3 with its
//! checksum, written and read here a block at a time, none of it through the program or the station's heap. What the
//! TypeScript it replaced did is station/test/reference/workspace-archive.ts, which station/test/mb-packed.test.ts holds
//! these to both ways, as station/test/cold-compat.test.ts holds them to the Rust station's.

use crate::err;
use crate::fs_ops::{own_file, read_up_to};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

const BLOCK: usize = 512;

/// Its path said with what failed of it.
fn at(path: &Path, e: impl std::fmt::Display) -> String {
    format!("{}: {e}", path.display())
}

// ── zstd ──

/// The zstd frames of the file at `path` walked by their headers (RFC 8878: frame header, block headers, checksum;
/// skippable frames passed over), failing unless each is there whole, nothing after the last: a cut archive is never
/// read as one that ends there. Microseconds: only the headers are read.
pub(crate) fn whole_frames(path: &Path) -> Result<(), String> {
    let mut file = fs::File::open(path).map_err(|e| at(path, e))?;
    let size = file.metadata().map_err(err)?.len();
    let cut = || format!("{}: incomplete zstd frame", path.display());
    let mut bytes = |at: u64, buf: &mut [u8]| -> Result<(), String> {
        if at + buf.len() as u64 > size {
            return Err(cut());
        }
        file.seek(SeekFrom::Start(at)).map_err(err)?;
        file.read_exact(buf).map_err(|_| cut())
    };
    if size == 0 {
        return Err(format!("{}: no zstd frame", path.display()));
    }
    let mut at = 0u64;
    while at < size {
        let mut word = [0u8; 4];
        bytes(at, &mut word)?;
        let magic = u32::from_le_bytes(word);
        if magic & 0xffff_fff0 == 0x184d_2a50 {
            bytes(at + 4, &mut word)?;
            at += 8 + u32::from_le_bytes(word) as u64;
            if at > size {
                return Err(cut());
            }
            continue;
        }
        if magic != 0xfd2f_b528 {
            return Err(format!("{}: not a zstd frame", path.display()));
        }
        let mut one = [0u8; 1];
        bytes(at + 4, &mut one)?;
        let descriptor = one[0];
        let size_flag = descriptor >> 6;
        let single = (descriptor >> 5) & 1;
        let checksummed = (descriptor >> 2) & 1;
        let dictionary = [0u64, 1, 2, 4][(descriptor & 3) as usize];
        let content = if size_flag == 0 { single as u64 } else { [0u64, 2, 4, 8][size_flag as usize] };
        at += 5 + if single == 1 { 0 } else { 1 } + dictionary + content;
        loop {
            let mut head = [0u8; 3];
            bytes(at, &mut head)?;
            let block = head[0] as u32 | (head[1] as u32) << 8 | (head[2] as u32) << 16;
            let kind = (block >> 1) & 3;
            if kind == 3 {
                return Err(format!("{}: reserved zstd block type", path.display()));
            }
            at += 3 + if kind == 1 { 1 } else { (block >> 3) as u64 };
            if block & 1 == 1 {
                break;
            }
        }
        if checksummed == 1 {
            at += 4;
        }
        if at > size {
            return Err(cut());
        }
    }
    Ok(())
}

/// What the archive at `path` holds, as it comes: its frames whole first, each checksum verified as it ends.
fn unzstd(path: &Path) -> Result<zstd::stream::read::Decoder<'static, io::BufReader<fs::File>>, String> {
    whole_frames(path)?;
    let file = fs::File::open(path).map_err(|e| at(path, e))?;
    zstd::stream::read::Decoder::new(file).map_err(err)
}

/// Everything left of `from` read (the end of the zstd stream and its checksum).
fn drain(from: &mut impl Read) -> Result<(), String> {
    io::copy(from, &mut io::sink()).map(|_| ()).map_err(err)
}

// ── numbers in headers ──

/// A number into a header field: octal, zero-padded, NUL-ended; past what that holds, GNU's base-256.
fn number_into(h: &mut [u8], at: usize, len: usize, value: u64) {
    let octal = format!("{value:o}");
    if octal.len() <= len - 1 {
        h[at..at + len - 1].copy_from_slice(format!("{octal:0>width$}", width = len - 1).as_bytes());
        h[at + len - 1] = 0;
        return;
    }
    let mut rest = value;
    for i in (1..len).rev() {
        h[at + i] = (rest & 0xff) as u8;
        rest >>= 8;
    }
    h[at] = 0x80;
}

/// A field's number: octal (spaces and NULs around it), or base-256 when its first byte's high bit is set.
fn number_from(field: &[u8]) -> Result<u64, String> {
    if field[0] & 0x80 != 0 {
        let mut n = (field[0] & 0x7f) as u64;
        for &b in &field[1..] {
            n = n.checked_mul(256).and_then(|n| n.checked_add(b as u64)).ok_or("numeric field too large")?;
        }
        return Ok(n);
    }
    let text = String::from_utf8_lossy(nul_ended(field));
    let text = text.trim();
    if text.is_empty() {
        return Ok(0);
    }
    if !text.bytes().all(|b| (b'0'..=b'7').contains(&b)) {
        return Err(format!("numeric field was not a number: {text}"));
    }
    u64::from_str_radix(text, 8).map_err(|_| format!("numeric field was not a number: {text}"))
}

fn checksum(h: &[u8; BLOCK]) -> u64 {
    h.iter().enumerate().map(|(i, &b)| if (148..156).contains(&i) { 32 } else { b as u64 }).sum()
}

fn nul_ended(b: &[u8]) -> &[u8] {
    b.iter().position(|&x| x == 0).map_or(b, |n| &b[..n])
}

// ── writing ──

struct Meta {
    mode: u64,
    uid: u64,
    gid: u64,
    mtime: u64,
    size: u64,
}

/// Header::new_gnu with its metadata (HeaderMode::Complete) and checksum.
fn gnu_header(name: &[u8], kind: u8, meta: &Meta, link: Option<&[u8]>, device: Option<(u64, u64)>) -> [u8; BLOCK] {
    let mut h = [0u8; BLOCK];
    let n = name.len().min(100);
    h[..n].copy_from_slice(&name[..n]);
    number_into(&mut h, 100, 8, meta.mode);
    number_into(&mut h, 108, 8, meta.uid);
    number_into(&mut h, 116, 8, meta.gid);
    number_into(&mut h, 124, 12, meta.size);
    number_into(&mut h, 136, 12, meta.mtime);
    h[156] = kind;
    if let Some(link) = link {
        let n = link.len().min(100);
        h[157..157 + n].copy_from_slice(&link[..n]);
    }
    h[257..263].copy_from_slice(b"ustar ");
    h[263..265].copy_from_slice(b" \0");
    if let Some((major, minor)) = device {
        number_into(&mut h, 329, 8, major);
        number_into(&mut h, 337, 8, minor);
    }
    h[148..156].fill(b' ');
    let sum = checksum(&h);
    number_into(&mut h, 148, 8, sum);
    h
}

fn padding(size: u64) -> usize {
    (BLOCK - (size % BLOCK as u64) as usize) % BLOCK
}

/// prepare_header: a GNU long name ('L') or long link name ('K') entry, for what does not fit 100 bytes.
fn long_entry(out: &mut dyn Write, kind: u8, value: &[u8]) -> io::Result<()> {
    let mut data = value.to_vec();
    data.push(0);
    let meta = Meta { mode: 0o644, uid: 0, gid: 0, mtime: 0, size: data.len() as u64 };
    out.write_all(&gnu_header(b"././@LongLink", kind, &meta, None, None))?;
    out.write_all(&data)?;
    out.write_all(&[0u8; BLOCK][..padding(data.len() as u64)])
}

/// The first 100 bytes of a name, cut back to whole UTF-8 characters (set_truncated_path_for_gnu_header).
fn truncated(name: &[u8]) -> &[u8] {
    let mut end = name.len().min(100);
    while end > 0 && end < name.len() && name[end] & 0xc0 == 0x80 {
        end -= 1;
    }
    &name[..end]
}

#[cfg(unix)]
fn name_bytes(name: &std::ffi::OsStr) -> Vec<u8> {
    std::os::unix::ffi::OsStrExt::as_bytes(name).to_vec()
}
#[cfg(not(unix))]
fn name_bytes(name: &std::ffi::OsStr) -> Vec<u8> {
    name.to_string_lossy().into_owned().into_bytes()
}

/// The modification time in nanoseconds, as Node's `lstat(…, {bigint: true}).mtimeNs`.
fn mtime_ns(meta: &fs::Metadata) -> i128 {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        meta.mtime() as i128 * 1_000_000_000 + meta.mtime_nsec() as i128
    }
    #[cfg(not(unix))]
    {
        match meta.modified().map(|t| t.duration_since(std::time::UNIX_EPOCH)) {
            Ok(Ok(d)) => d.as_nanos() as i128,
            Ok(Err(before)) => -(before.duration().as_nanos() as i128),
            Err(_) => 0,
        }
    }
}

/// Mode, owner and modification time as the tar crate's HeaderMode::Complete takes them (Node's lstat on Windows,
/// which has no modes: 0o666, or 0o444 where read-only, with the kind's bits).
fn meta_of(meta: &fs::Metadata, size: u64) -> Meta {
    let mtime = (mtime_ns(meta).div_euclid(1_000_000_000)).max(0) as u64;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Meta { mode: meta.mode() as u64, uid: meta.uid() as u64, gid: meta.gid() as u64, mtime, size }
    }
    #[cfg(not(unix))]
    {
        let kind = if meta.file_type().is_symlink() { 0o120000 } else if meta.is_dir() { 0o040000 } else { 0o100000 };
        let bits = if meta.permissions().readonly() { 0o444 } else { 0o666 };
        Meta { mode: kind | bits, uid: 0, gid: 0, mtime, size }
    }
}

/// Builder::append_dir_all(".", dir) with follow_symlinks(false), then finish: `./` for the directory itself, then
/// everything under it as `a/b` (directories before what is in them, each directory's names taken in reverse byte
/// order, as the TypeScript walked them), links as links, special files as headers.
fn write_tree(dir: &Path, out: &mut impl Write) -> Result<(), String> {
    let mut stack: Vec<(PathBuf, Vec<u8>)> = vec![(dir.to_path_buf(), Vec::new())];
    let mut buf = vec![0u8; 256 * 1024];
    while let Some((path, rel)) = stack.pop() {
        let meta = fs::symlink_metadata(&path).map_err(|e| at(&path, e))?;
        let name: &[u8] = if rel.is_empty() { b"./" } else { &rel };
        let head = |out: &mut dyn Write, kind: u8, size: u64, link: Option<&[u8]>, device: Option<(u64, u64)>| -> Result<(), String> {
            if name.len() > 100 {
                long_entry(out, b'L', name).map_err(err)?;
            }
            let link = match link {
                Some(l) if l.len() > 100 => {
                    long_entry(out, b'K', l).map_err(err)?;
                    Some(truncated(l))
                }
                other => other,
            };
            let shown = if name.len() > 100 { truncated(name) } else { name };
            out.write_all(&gnu_header(shown, kind, &meta_of(&meta, size), link, device)).map_err(err)
        };
        let kind = meta.file_type();
        if kind.is_dir() {
            let mut names = Vec::new();
            for entry in fs::read_dir(&path).map_err(|e| at(&path, e))? {
                names.push(entry.map_err(|e| at(&path, e))?.file_name());
            }
            names.sort_by_key(|n| name_bytes(n));
            for child in names {
                let mut r = rel.clone();
                if !r.is_empty() {
                    r.push(b'/');
                }
                r.extend_from_slice(&name_bytes(&child));
                stack.push((path.join(&child), r));
            }
            head(out, b'5', 0, None, None)?;
        } else if kind.is_symlink() {
            let target = fs::read_link(&path).map_err(|e| at(&path, e))?;
            head(out, b'2', 0, Some(&name_bytes(target.as_os_str())), None)?;
        } else if kind.is_file() {
            let size = meta.len();
            head(out, b'0', size, None, None)?;
            let mut file = fs::File::open(&path).map_err(|e| at(&path, e))?.take(size);
            let mut sent = 0u64;
            loop {
                let n = read_up_to(&mut file, &mut buf).map_err(|e| at(&path, e))?;
                if n == 0 {
                    break;
                }
                sent += n as u64;
                out.write_all(&buf[..n]).map_err(err)?;
            }
            if sent != size {
                return Err(format!("{} changed while archiving", path.display()));
            }
            out.write_all(&[0u8; BLOCK][..padding(size)]).map_err(err)?;
        } else {
            #[cfg(unix)]
            {
                use std::os::unix::fs::{FileTypeExt, MetadataExt};
                if kind.is_socket() {
                    return Err(format!("{}: socket can not be archived", path.display()));
                }
                let code = if kind.is_fifo() {
                    b'6'
                } else if kind.is_char_device() {
                    b'3'
                } else if kind.is_block_device() {
                    b'4'
                } else {
                    return Err(format!("{} has unknown file type", path.display()));
                };
                let dev = meta.rdev();
                let major = ((dev >> 32) & 0xffff_f000) | ((dev >> 8) & 0x0000_0fff);
                let minor = ((dev >> 12) & 0xffff_ff00) | (dev & 0x0000_00ff);
                head(out, code, 0, None, Some((major, minor)))?;
            }
            #[cfg(not(unix))]
            return Err(format!("{} has unknown file type", path.display()));
        }
    }
    out.write_all(&[0u8; 2 * BLOCK]).map_err(err)
}

/// Every path under `dir` with its size and modification time, links not followed.
fn snapshot(dir: &Path) -> Result<BTreeMap<PathBuf, (u64, i128)>, String> {
    let mut out = BTreeMap::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in fs::read_dir(&dir).map_err(|e| at(&dir, e))? {
            let path = entry.map_err(|e| at(&dir, e))?.path();
            let meta = fs::symlink_metadata(&path).map_err(|e| at(&path, e))?;
            out.insert(path.clone(), (meta.len(), mtime_ns(&meta)));
            if meta.is_dir() {
                stack.push(path);
            }
        }
    }
    Ok(out)
}

/// `tar.pack`'s work: the tree at `dir` into `out` (made anew, 0600, on disk), read back whole, and the tree found as
/// it was before it was read.
pub(crate) fn pack(dir: &Path, out: &Path) -> Result<Value, String> {
    let before = snapshot(dir)?;
    let mut encoder = zstd::stream::write::Encoder::new(own_file(out)?, 3).map_err(err)?;
    encoder.include_checksum(true).map_err(err)?;
    let mut writer = io::BufWriter::with_capacity(1 << 20, encoder);
    write_tree(dir, &mut writer)?;
    let encoder = writer.into_inner().map_err(|e| err(e.error()))?;
    encoder.finish().map_err(err)?.sync_all().map_err(err)?;
    // Every entry read, to the end of the zstd stream and its checksum, before any original is touched.
    let mut check = unzstd(out)?;
    let mut entries = Entries::new(&mut check);
    while entries.next()?.is_some() {
        entries.skip()?;
    }
    drain(&mut check)?;
    if snapshot(dir)? != before {
        return Err("workspace changed while archiving; originals kept".into());
    }
    Ok(json!({}))
}

// ── reading ──

#[derive(Clone, Copy, PartialEq)]
enum Kind {
    File,
    Dir,
    Symlink,
    Hardlink,
    Char,
    Block,
    Fifo,
    Other,
}

struct Entry {
    /// The path's components ("." left out), and whether it began with "/".
    parts: Vec<Vec<u8>>,
    absolute: bool,
    kind: Kind,
    mode: u64,
    mtime: u64,
    size: u64,
    link: Option<Vec<u8>>,
}

/// Archive::entries: each entry named by the GNU long name or pax path before it, else its name (with the ustar
/// prefix for a ustar header); headers' checksums checked; the archive ends at a zero block. An entry's body not
/// read is skipped when the next is asked for.
struct Entries<R: Read> {
    from: R,
    /// What is left unread of the entry given last: its body, then its padding.
    body: u64,
    pad: u64,
}

impl<R: Read> Entries<R> {
    fn new(from: R) -> Self {
        Entries { from, body: 0, pad: 0 }
    }

    fn skip_bytes(&mut self, mut n: u64) -> Result<(), String> {
        let mut buf = [0u8; 8192];
        while n > 0 {
            let want = n.min(buf.len() as u64) as usize;
            let got = read_up_to(&mut self.from, &mut buf[..want]).map_err(err)?;
            if got == 0 {
                return Err("unexpected end of archive".into());
            }
            n -= got as u64;
        }
        Ok(())
    }

    /// The rest of the entry given last passed over.
    fn skip(&mut self) -> Result<(), String> {
        let n = self.body + self.pad;
        self.body = 0;
        self.pad = 0;
        self.skip_bytes(n)
    }

    /// The entry given last's body into `out`.
    fn body_into(&mut self, out: &mut impl Write) -> Result<(), String> {
        let mut buf = vec![0u8; 256 * 1024];
        while self.body > 0 {
            let want = self.body.min(buf.len() as u64) as usize;
            let got = read_up_to(&mut self.from, &mut buf[..want]).map_err(err)?;
            if got == 0 {
                return Err("unexpected end of archive".into());
            }
            out.write_all(&buf[..got]).map_err(err)?;
            self.body -= got as u64;
        }
        Ok(())
    }

    /// A meta entry's data whole (a long name, pax records).
    fn data(&mut self, size: u64) -> Result<Vec<u8>, String> {
        let mut out = Vec::new();
        (&mut self.from).take(size).read_to_end(&mut out).map_err(err)?;
        if (out.len() as u64) < size {
            return Err("unexpected end of archive".into());
        }
        self.skip_bytes(padding(size) as u64)?;
        Ok(out)
    }

    fn next(&mut self) -> Result<Option<Entry>, String> {
        let (body, pad) = (self.body, self.pad);
        self.body = 0;
        self.pad = 0;
        self.skip_bytes(body + pad)?;
        let mut long_name: Option<Vec<u8>> = None;
        let mut long_link: Option<Vec<u8>> = None;
        let mut pax: Option<BTreeMap<Vec<u8>, Vec<u8>>> = None;
        loop {
            let mut h = [0u8; BLOCK];
            let got = read_up_to(&mut self.from, &mut h).map_err(err)?;
            if got == 0 || (got == BLOCK && h.iter().all(|&b| b == 0)) {
                return Ok(None);
            }
            if got < BLOCK {
                return Err("unexpected end of archive".into());
            }
            if number_from(&h[148..156])? != checksum(&h) {
                return Err("archive header checksum mismatch".into());
            }
            let kind = h[156];
            let mut size = number_from(&h[124..136])?;
            if let Some(given) = pax.as_ref().and_then(|p| p.get(b"size".as_slice()))
                && !matches!(kind, b'x' | b'g' | b'L' | b'K')
            {
                let text = String::from_utf8_lossy(given);
                size = text.trim().parse().map_err(|_| format!("pax size was not a number: {text}"))?;
            }
            match kind {
                b'L' => {
                    long_name = Some(nul_ended(&self.data(size)?).to_vec());
                    continue;
                }
                b'K' => {
                    long_link = Some(nul_ended(&self.data(size)?).to_vec());
                    continue;
                }
                b'x' => {
                    pax = Some(pax_records(&self.data(size)?));
                    continue;
                }
                b'g' => {
                    self.data(size)?;
                    continue;
                }
                _ => {}
            }
            let prefix: &[u8] = if &h[257..263] == b"ustar\0" { nul_ended(&h[345..500]) } else { b"" };
            let name = nul_ended(&h[0..100]);
            let mut pax = pax.take().unwrap_or_default();
            let raw = long_name.take().or_else(|| pax.remove(b"path".as_slice())).unwrap_or_else(|| {
                if prefix.is_empty() { name.to_vec() } else { [prefix, b"/", name].concat() }
            });
            let link = long_link.take().or_else(|| pax.remove(b"linkpath".as_slice())).unwrap_or_else(|| nul_ended(&h[157..257]).to_vec());
            let kind = match kind {
                b'0' | 0 | b'7' => Kind::File,
                b'5' => Kind::Dir,
                b'2' => Kind::Symlink,
                b'1' => Kind::Hardlink,
                b'3' => Kind::Char,
                b'4' => Kind::Block,
                b'6' => Kind::Fifo,
                _ => Kind::Other,
            };
            self.body = size;
            self.pad = padding(size) as u64;
            return Ok(Some(Entry {
                parts: raw.split(|&b| b == b'/').filter(|p| !p.is_empty() && *p != b".").map(<[u8]>::to_vec).collect(),
                absolute: raw.first() == Some(&b'/'),
                kind,
                mode: number_from(&h[100..108])?,
                mtime: number_from(&h[136..148])?,
                size,
                link: matches!(kind, Kind::Symlink | Kind::Hardlink).then_some(link),
            }));
        }
    }
}

/// pax records ("<length> <key>=<value>\n") by key.
fn pax_records(data: &[u8]) -> BTreeMap<Vec<u8>, Vec<u8>> {
    let mut out = BTreeMap::new();
    let mut rest = data;
    while !rest.is_empty() {
        let Some(space) = rest.iter().position(|&b| b == b' ') else { break };
        let Some(len) = std::str::from_utf8(&rest[..space]).ok().and_then(|s| s.trim().parse::<usize>().ok()) else { break };
        if len <= space + 1 || len > rest.len() {
            break;
        }
        let record = &rest[space + 1..len - 1];
        rest = &rest[len..];
        if let Some(eq) = record.iter().position(|&b| b == b'=') {
            out.insert(record[..eq].to_vec(), record[eq + 1..].to_vec());
        }
    }
    out
}

#[cfg(unix)]
fn os(part: &[u8]) -> std::ffi::OsString {
    use std::os::unix::ffi::OsStrExt;
    std::ffi::OsStr::from_bytes(part).to_os_string()
}
#[cfg(not(unix))]
fn os(part: &[u8]) -> std::ffi::OsString {
    String::from_utf8_lossy(part).into_owned().into()
}

fn joined(dest: &Path, parts: &[Vec<u8>]) -> PathBuf {
    let mut path = dest.to_path_buf();
    for p in parts {
        path.push(os(p));
    }
    path
}

/// A file's or directory's mode set: on Windows, which has none, read-only where its owner may not write (as Node's
/// chmod there).
fn set_mode(path: &Path, mode: u64) -> Result<(), String> {
    #[cfg(unix)]
    let permissions = std::os::unix::fs::PermissionsExt::from_mode((mode & 0o7777) as u32);
    #[cfg(not(unix))]
    let permissions = {
        let mut p = fs::metadata(path).map_err(|e| at(path, e))?.permissions();
        p.set_readonly(mode & 0o200 == 0);
        p
    };
    fs::set_permissions(path, permissions).map_err(|e| at(path, e))
}

/// `make` done at `path`, what was there first removed where it was already.
fn replace<T>(path: &Path, make: impl Fn() -> io::Result<T>) -> Result<T, String> {
    match make() {
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
            fs::remove_file(path).map_err(|e| at(path, e))?;
            make().map_err(|e| at(path, e))
        }
        other => other.map_err(|e| at(path, e)),
    }
}

/// A link at `path` to `target`; false where the machine refused it (Windows without the privilege: what stands in
/// for it is made once the tree is at its final path, archive.ts `restoreWorkspace`).
fn symlink(target: &[u8], path: &Path) -> Result<bool, String> {
    #[cfg(unix)]
    {
        replace(path, || std::os::unix::fs::symlink(os(target), path))?;
        Ok(true)
    }
    #[cfg(windows)]
    {
        let target = os(target);
        // (as Node's symlink with no type: a directory's where its target is one)
        let dir = path.parent().map(|p| p.join(&target)).is_some_and(|t| t.is_dir());
        let make = || if dir { std::os::windows::fs::symlink_dir(&target, path) } else { std::os::windows::fs::symlink_file(&target, path) };
        let made = match make() {
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                fs::remove_file(path).map_err(|e| at(path, e))?;
                make()
            }
            other => other,
        };
        match made {
            Ok(()) => Ok(true),
            // (ERROR_PRIVILEGE_NOT_HELD: Node's EPERM, platform/windows.ts `linkRefused`)
            Err(e) if e.raw_os_error() == Some(1314) || e.kind() == io::ErrorKind::PermissionDenied => Ok(false),
            Err(e) => Err(at(path, e)),
        }
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = (target, path);
        Ok(false)
    }
}

/// `tar.unpack`'s work: Archive::unpack with preserve_permissions: entries with `..` skipped, a leading `/` dropped,
/// nothing written through a link out of `dest`; directories made last, deepest first, with their modes; files with
/// their modes and modification times. With `prefix`, only the files and directories under that first name. The
/// links refused, by their path and target.
pub(crate) fn unpack(path: &Path, dest: &Path, prefix: Option<&str>) -> Result<Value, String> {
    let mut stream = unzstd(path)?;
    let root = fs::canonicalize(dest).map_err(|e| at(dest, e))?;
    let inside = |dir: &Path| -> Result<(), String> {
        let real = fs::canonicalize(dir).map_err(|e| at(dir, e))?;
        if !real.starts_with(&root) {
            return Err(format!("trying to unpack outside of destination path: {}", root.display()));
        }
        Ok(())
    };
    let mut dirs: Vec<(PathBuf, Vec<u8>, u64)> = Vec::new();
    let mut refused: Vec<Value> = Vec::new();
    let mut links: Vec<(PathBuf, Vec<u8>)> = Vec::new();
    let mut entries = Entries::new(&mut stream);
    while let Some(entry) = entries.next()? {
        if let Some(prefix) = prefix
            && (entry.absolute || entry.parts.first().map(Vec::as_slice) != Some(prefix.as_bytes()) || !matches!(entry.kind, Kind::File | Kind::Dir))
        {
            continue;
        }
        if entry.parts.is_empty() || entry.parts.iter().any(|p| p == b"..") {
            continue;
        }
        let path = joined(dest, &entry.parts);
        let key = entry.parts.join(&b'/');
        if entry.kind == Kind::Dir {
            dirs.push((path, key, entry.mode));
            continue;
        }
        if entry.kind == Kind::Other {
            continue;
        }
        let parent = path.parent().unwrap_or(dest);
        fs::create_dir_all(parent).map_err(|e| at(parent, e))?;
        inside(parent)?;
        match entry.kind {
            Kind::File => {
                let mut file = replace(&path, || {
                    let mut options = fs::OpenOptions::new();
                    options.write(true).create_new(true);
                    #[cfg(unix)]
                    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
                    options.open(&path)
                })?;
                let mut writer = io::BufWriter::with_capacity(256 * 1024, &mut file);
                entries.body_into(&mut writer)?;
                writer.flush().map_err(|e| at(&path, e))?;
                drop(writer);
                let when = std::time::UNIX_EPOCH + std::time::Duration::from_secs(if entry.mtime == 0 { 1 } else { entry.mtime });
                file.set_times(fs::FileTimes::new().set_accessed(when).set_modified(when)).map_err(|e| at(&path, e))?;
                drop(file);
                set_mode(&path, entry.mode)?;
            }
            Kind::Symlink => {
                let link = entry.link.as_deref().unwrap_or_default().to_vec();
                // (On Windows a link is a file's or a directory's, by what it leads to: made once every directory of
                // the archive is, a link to one written after it (the walk's reverse order: `z -> a`) or to an empty
                // one is a directory's. Until then nothing is there to be written through: a later entry under its
                // path makes a directory there, and the link is refused as the path is taken.)
                if cfg!(windows) {
                    links.push((path, link));
                } else if !symlink(&link, &path)? {
                    refused.push(json!([path.to_string_lossy(), String::from_utf8_lossy(&link)]));
                }
            }
            Kind::Hardlink => {
                let link = entry.link.as_deref().unwrap_or_default();
                let target: Vec<Vec<u8>> = link.split(|&b| b == b'/').filter(|p| !p.is_empty() && *p != b".").map(<[u8]>::to_vec).collect();
                if target.iter().any(|p| p == b"..") {
                    return Err(format!("hard link outside of destination path: {}", String::from_utf8_lossy(link)));
                }
                let from = joined(dest, &target);
                inside(from.parent().unwrap_or(dest))?;
                replace(&path, || fs::hard_link(&from, &path))?;
            }
            Kind::Fifo => {
                #[cfg(unix)]
                {
                    let c = std::ffi::CString::new(std::os::unix::ffi::OsStrExt::as_bytes(path.as_os_str())).map_err(err)?;
                    replace(&path, || {
                        // SAFETY: `c` is a NUL-ended path that lives through the call.
                        if unsafe { libc::mkfifo(c.as_ptr(), (entry.mode & 0o7777) as libc::mode_t) } == 0 { Ok(()) } else { Err(io::Error::last_os_error()) }
                    })?;
                    // (its mode as given, not as the umask leaves it: as `mkfifo -m`)
                    set_mode(&path, entry.mode)?;
                }
                #[cfg(not(unix))]
                return Err(format!("cannot unpack a named pipe: {}", String::from_utf8_lossy(&key)));
            }
            _ => return Err(format!("cannot unpack a device file: {}", String::from_utf8_lossy(&key))),
        }
    }
    // (the rest of the stream, to the end of its zstd frame and its checksum)
    drop(entries);
    drain(&mut stream)?;
    dirs.sort_by(|a, b| b.1.cmp(&a.1));
    // Every directory there first, then the links held back (Windows'), then the directories' modes: a read-only one
    // written into no more after.
    for (path, key, _) in &dirs {
        match fs::symlink_metadata(path) {
            Ok(there) if !there.is_dir() => {
                return Err(format!("{} is not a directory in the archive's tree", String::from_utf8_lossy(key)));
            }
            Ok(_) => {}
            Err(_) => {
                let parent = path.parent().unwrap_or(dest);
                fs::create_dir_all(parent).map_err(|e| at(parent, e))?;
                inside(parent)?;
                fs::create_dir(path).map_err(|e| at(path, e))?;
            }
        }
    }
    for (path, link) in links {
        inside(path.parent().unwrap_or(dest))?;
        if !symlink(&link, &path)? {
            refused.push(json!([path.to_string_lossy(), String::from_utf8_lossy(&link)]));
        }
    }
    for (path, _, mode) in &dirs {
        set_mode(path, *mode)?;
    }
    Ok(json!({ "refused": refused }))
}

/// `tar.file`'s work: the file at `wanted` (its path's components in the archive) written to `out` (made anew,
/// 0600) where the archive has one; the archive's frames found whole first.
pub(crate) fn file(path: &Path, wanted: &[String], out: &Path) -> Result<Value, String> {
    let mut stream = unzstd(path)?;
    let mut entries = Entries::new(&mut stream);
    while let Some(entry) = entries.next()? {
        if !entry.absolute
            && entry.kind == Kind::File
            && entry.parts.len() == wanted.len()
            && entry.parts.iter().zip(wanted).all(|(p, w)| p.as_slice() == w.as_bytes())
        {
            let mut file = io::BufWriter::new(own_file(out)?);
            entries.body_into(&mut file)?;
            file.flush().map_err(|e| at(out, e))?;
            return Ok(json!({ "found": true, "size": entry.size }));
        }
    }
    Ok(json!({ "found": false }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(what: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("sf-tar-{what}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// A tar of `blocks` (and its end) in zstd at `out`, as another program writes one.
    fn archive_of(out: &Path, blocks: &[Vec<u8>]) {
        let mut z = zstd::stream::write::Encoder::new(fs::File::create(out).unwrap(), 3).unwrap();
        z.include_checksum(true).unwrap();
        for b in blocks {
            z.write_all(b).unwrap();
        }
        z.write_all(&[0u8; 2 * BLOCK]).unwrap();
        z.finish().unwrap();
    }

    fn entry(name: &[u8], kind: u8, body: &[u8], link: Option<&[u8]>) -> Vec<u8> {
        let meta = Meta { mode: 0o644, uid: 0, gid: 0, mtime: 1_700_000_000, size: body.len() as u64 };
        let mut out = gnu_header(name, kind, &meta, link, None).to_vec();
        out.extend_from_slice(body);
        out.extend(std::iter::repeat_n(0u8, padding(body.len() as u64)));
        out
    }

    #[test]
    fn numbers_octal_and_base_256() {
        let mut h = [0u8; 12];
        number_into(&mut h, 0, 12, 0o755);
        assert_eq!(&h, b"00000000755\0");
        assert_eq!(number_from(&h).unwrap(), 0o755);
        number_into(&mut h, 0, 12, 1 << 40);
        assert_eq!(h[0], 0x80);
        assert_eq!(number_from(&h).unwrap(), 1 << 40);
        assert_eq!(number_from(b" 17 \0\0").unwrap(), 0o17);
        assert!(number_from(b"9\0").is_err());
        assert_eq!(truncated("名".repeat(40).as_bytes()).len(), 99);
    }

    #[cfg(unix)]
    #[test]
    fn a_tree_packed_comes_back_as_it_was() {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        let root = temp("round");
        let ws = root.join("ws");
        let deep = format!("{}/{}/{}.txt", "d".repeat(60), "e".repeat(60), "名".repeat(40));
        fs::create_dir_all(ws.join(&deep).parent().unwrap()).unwrap();
        fs::write(ws.join(&deep), "deep").unwrap();
        fs::write(ws.join("a"), "linked").unwrap();
        fs::hard_link(ws.join("a"), ws.join("b")).unwrap();
        std::os::unix::fs::symlink(format!("{}/target", "t".repeat(150)), ws.join("far")).unwrap();
        fs::create_dir_all(ws.join("ro/inner")).unwrap();
        fs::write(ws.join("ro/inner/f"), "x").unwrap();
        fs::set_permissions(ws.join("ro"), fs::Permissions::from_mode(0o500)).unwrap();
        let c = std::ffi::CString::new(ws.join("pipe").to_str().unwrap()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o640) }, 0);
        let out = root.join("w.tar.zst");
        pack(&ws, &out).unwrap();
        assert_eq!(fs::metadata(&out).unwrap().mode() & 0o777, 0o600);
        let dest = root.join("dest");
        fs::create_dir(&dest).unwrap();
        assert_eq!(unpack(&out, &dest, None).unwrap(), json!({ "refused": [] }));
        assert_eq!(fs::read_to_string(dest.join(&deep)).unwrap(), "deep");
        assert_eq!(fs::read_to_string(dest.join("b")).unwrap(), "linked");
        assert_eq!(fs::read_link(dest.join("far")).unwrap(), PathBuf::from(format!("{}/target", "t".repeat(150))));
        assert_eq!(fs::metadata(dest.join("ro")).unwrap().mode() & 0o7777, 0o500);
        assert_eq!(fs::read_to_string(dest.join("ro/inner/f")).unwrap(), "x");
        assert!(std::os::unix::fs::FileTypeExt::is_fifo(&fs::symlink_metadata(dest.join("pipe")).unwrap().file_type()));
        assert_eq!(fs::symlink_metadata(dest.join("pipe")).unwrap().mode() & 0o777, 0o640);
        // A file read out of it, by its path's components; a directory is none, nor what is not there.
        let wanted: Vec<String> = deep.split('/').map(str::to_string).collect();
        assert_eq!(file(&out, &wanted, &root.join("one")).unwrap(), json!({ "found": true, "size": 4 }));
        assert_eq!(fs::read_to_string(root.join("one")).unwrap(), "deep");
        assert_eq!(file(&out, &["ro".to_string()], &root.join("two")).unwrap(), json!({ "found": false }));
        assert!(!root.join("two").exists());
        for dir in [ws.join("ro"), dest.join("ro")] {
            fs::set_permissions(dir, fs::Permissions::from_mode(0o700)).unwrap();
        }
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn a_cut_or_padded_archive_is_never_read_as_whole() {
        let root = temp("cut");
        let whole = root.join("whole.zst");
        archive_of(&whole, &[entry(b"uploads/a.txt", b'0', &vec![b'a'; 5000], None)]);
        let bytes = fs::read(&whole).unwrap();
        let wanted = ["uploads".to_string(), "a.txt".to_string()];
        assert_eq!(file(&whole, &wanted, &root.join("got")).unwrap()["found"], json!(true));
        for (what, b) in [
            ("cut", bytes[..bytes.len() - 1].to_vec()),
            ("cut in its header", bytes[..6].to_vec()),
            ("bytes after", [bytes.clone(), b"xx".to_vec()].concat()),
            ("not zstd", b"broken archive".to_vec()),
            ("empty", Vec::new()),
        ] {
            let path = root.join(what);
            fs::write(&path, &b).unwrap();
            assert!(file(&path, &wanted, &root.join("got")).is_err(), "{what}");
            let dest = root.join(format!("{what}.dest"));
            fs::create_dir(&dest).unwrap();
            assert!(unpack(&path, &dest, None).is_err(), "{what}");
        }
        // A header whose checksum is wrong.
        let mut bad = entry(b"x", b'0', b"", None);
        bad[0] = b'y';
        let path = root.join("sum.zst");
        archive_of(&path, &[bad]);
        assert_eq!(unpack(&path, &root, None).unwrap_err(), "archive header checksum mismatch");
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn pax_ustar_prefixes_and_only_the_uploads() {
        let root = temp("pax");
        let path = root.join("a.zst");
        let record = |k: &str, v: &str| {
            let body = format!(" {k}={v}\n");
            let mut n = body.len() + 1;
            if format!("{n}{body}").len() != n {
                n += 1;
            }
            format!("{n}{body}")
        };
        let pax = format!("{}{}", record("path", "uploads/由 pax 命名.txt"), record("size", "3"));
        let mut ustar = entry(b"b.txt", b'0', b"bbb", None);
        ustar[257..263].copy_from_slice(b"ustar\0");
        ustar[263..265].copy_from_slice(b"00");
        ustar[345..352].copy_from_slice(b"uploads");
        ustar[148..156].fill(b' ');
        let sum = checksum(ustar[..BLOCK].try_into().unwrap());
        number_into(&mut ustar, 148, 8, sum);
        archive_of(&path, &[
            entry(b"./", b'5', b"", None),
            entry(b"pax", b'x', pax.as_bytes(), None),
            [gnu_header(b"ignored", b'0', &Meta { mode: 0o600, uid: 0, gid: 0, mtime: 0, size: 99 }, None, None).to_vec(), b"ccc".to_vec(), vec![0; BLOCK - 3]].concat(),
            ustar,
            entry(b"uploads/sub", b'5', b"", None),
            entry(b"src/main.rs", b'0', b"fn main", None),
            entry(b"uploads/link", b'2', b"", Some(b"../../etc")),
        ]);
        let dest = root.join("dest");
        fs::create_dir(&dest).unwrap();
        unpack(&path, &dest, Some("uploads")).unwrap();
        assert_eq!(fs::read_to_string(dest.join("uploads/由 pax 命名.txt")).unwrap(), "ccc");
        assert_eq!(fs::read_to_string(dest.join("uploads/b.txt")).unwrap(), "bbb");
        assert!(dest.join("uploads/sub").is_dir());
        assert!(!dest.join("src").exists() && fs::symlink_metadata(dest.join("uploads/link")).is_err());
        fs::remove_dir_all(&root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn nothing_is_written_outside_its_destination() {
        let root = temp("out");
        let dest = root.join("dest");
        fs::create_dir(&dest).unwrap();
        // `..` is passed over; a link made first leads out, and a file under it is refused.
        let up = root.join("up.zst");
        archive_of(&up, &[entry(b"../escaped", b'0', b"no", None), entry(b"/abs/ok", b'0', b"yes", None)]);
        unpack(&up, &dest, None).unwrap();
        assert!(!root.join("escaped").exists());
        assert_eq!(fs::read_to_string(dest.join("abs/ok")).unwrap(), "yes");
        let via = root.join("via.zst");
        archive_of(&via, &[entry(b"out", b'2', b"", Some(root.to_str().unwrap().as_bytes())), entry(b"out/escaped", b'0', b"no", None)]);
        assert!(unpack(&via, &dest, None).unwrap_err().starts_with("trying to unpack outside of destination path"));
        assert!(!root.join("escaped").exists());
        let hard = root.join("hard.zst");
        archive_of(&hard, &[entry(b"h", b'1', b"", Some(b"../x"))]);
        assert!(unpack(&hard, &dest, None).unwrap_err().starts_with("hard link outside of destination path"));
        let device = root.join("device.zst");
        archive_of(&device, &[entry(b"tty", b'3', b"", None)]);
        assert_eq!(unpack(&device, &dest, None).unwrap_err(), "cannot unpack a device file: tty");
        let clash = root.join("clash.zst");
        archive_of(&clash, &[entry(b"d", b'0', b"file", None), entry(b"d", b'5', b"", None)]);
        assert_eq!(unpack(&clash, &dest, None).unwrap_err(), "d is not a directory in the archive's tree");
        fs::remove_dir_all(&root).unwrap();
    }

    /// A link to a directory written before it (the walk's reverse order) or to an empty one is a directory's link on
    /// Windows, where the machine makes links at all.
    #[cfg(windows)]
    #[test]
    fn a_link_to_a_directory_after_it_is_a_directorys() {
        let root = temp("winlinks");
        let path = root.join("a.zst");
        archive_of(&path, &[
            entry(b"z_link", b'2', b"", Some(b"a_dir")),
            entry(b"to_empty", b'2', b"", Some(b"empty")),
            entry(b"a_dir/f.txt", b'0', b"in a", None),
            entry(b"a_dir", b'5', b"", None),
            entry(b"empty", b'5', b"", None),
        ]);
        let dest = root.join("dest");
        fs::create_dir(&dest).unwrap();
        let made = unpack(&path, &dest, None).unwrap();
        if made["refused"].as_array().unwrap().is_empty() {
            assert_eq!(fs::read_to_string(dest.join("z_link").join("f.txt")).unwrap(), "in a");
            assert!(fs::metadata(dest.join("to_empty")).unwrap().is_dir());
        } else {
            assert_eq!(made["refused"].as_array().unwrap().len(), 2);
        }
        fs::remove_dir_all(&root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn a_socket_or_a_change_while_packing_keeps_the_originals() {
        let root = temp("sock");
        let ws = root.join("ws");
        fs::create_dir(&ws).unwrap();
        let _listener = std::os::unix::net::UnixListener::bind(ws.join("s")).unwrap();
        let err = pack(&ws, &root.join("o.zst")).unwrap_err();
        assert!(err.ends_with("socket can not be archived"), "{err}");
        fs::remove_dir_all(&root).unwrap();
    }
}
