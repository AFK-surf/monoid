//! Zstd compression/decompression, directory-sync blob packing, transcript segmenting/checking, and tar archive
//! dispatch (`zstd.*`, `pack.*`, `tar.*`).

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};

use crate::fs_ops::{own_file, read_up_to};
use crate::{Answer, Done, Handle, Inner, err, id_of, str_of, tar};

/// A zstd stream being taken apart, a piece at a time as the core is given them: libzstd's streaming decoder (frames
/// one after another, a piece cut anywhere), and whether what it took so far ended a frame.
pub(crate) struct Unzstd {
    decoder: zstd::stream::raw::Decoder<'static>,
    pub(crate) whole: bool,
}

impl Unzstd {
    pub(crate) fn new() -> Result<Unzstd, String> {
        Ok(Unzstd { decoder: zstd::stream::raw::Decoder::new().map_err(err)?, whole: true })
    }

    /// `input` taken apart: all it makes, nothing held back.
    pub(crate) fn take(&mut self, input: &[u8]) -> Result<Vec<u8>, String> {
        use zstd::stream::raw::{InBuffer, Operation, OutBuffer};
        let mut out = Vec::new();
        let mut src = InBuffer::around(input);
        let mut buf = vec![0u8; 128 * 1024];
        loop {
            let mut dst = OutBuffer::around(&mut buf[..]);
            let hint = self.decoder.run(&mut src, &mut dst).map_err(err)?;
            let made = dst.pos();
            out.extend_from_slice(&buf[..made]);
            // (0: a frame ended and all of it is out; said only of what took something, an empty piece says nothing)
            if made > 0 || src.pos() > 0 {
                self.whole = hint == 0;
            }
            if src.pos() >= input.len() && made < buf.len() {
                return Ok(out);
            }
        }
    }
}

/// `zstd.pack`'s work: the pieces read, their ids checked, packed into `out`.
fn pack_pieces(ids: &Mutex<HashMap<String, (sha1::Sha1, u64)>>, out: &std::path::Path, level: i32, pieces: &[Value]) -> Result<Value, String> {
    use sha1::Digest;
    use std::io::{Read, Seek, SeekFrom, Write};
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let mut z = zstd::stream::write::Encoder::new(options.open(out).map_err(err)?, level).map_err(err)?;
    let mut raw = 0u64;
    let changed = |i: usize| Ok(json!({ "changed": i }));
    for (i, p) in pieces.iter().enumerate() {
        let (Some(path), Some(offset), Some(length), Some(size), Some(id)) = (p[0].as_str(), p[1].as_u64(), p[2].as_u64(), p[3].as_u64(), p[4].as_str()) else {
            return Err("bad piece".into());
        };
        let data = if p[5].as_bool().unwrap_or(false) {
            // (a link's target as Node's readlink gives it, its id that of its text)
            let Ok(target) = std::fs::read_link(path) else { return changed(i) };
            let bytes = target.to_string_lossy().into_owned().into_bytes();
            let mut h = sha1::Sha1::new();
            h.update(format!("blob {}\0", bytes.len()).as_bytes());
            h.update(&bytes);
            if offset != 0 || bytes.len() as u64 != length || hex::encode(h.finalize()) != id {
                return changed(i);
            }
            bytes
        } else {
            let mut data = vec![0u8; length as usize];
            // Still the regular file it was listed as, of the size it was: never through a link put in its place (the
            // file itself opened without following one where the system can), nor grown, whose first bytes alone
            // would hash as they did.
            let still = std::fs::symlink_metadata(path).is_ok_and(|m| m.is_file() && m.len() == size);
            let read = still && {
                let mut o = std::fs::OpenOptions::new();
                o.read(true);
                #[cfg(unix)]
                std::os::unix::fs::OpenOptionsExt::custom_flags(&mut o, libc::O_NOFOLLOW | libc::O_NONBLOCK);
                o.open(path)
                    .and_then(|mut f| {
                        let m = f.metadata()?;
                        if !m.is_file() || m.len() != size {
                            return Ok(false);
                        }
                        f.seek(SeekFrom::Start(offset))?;
                        f.read_exact(&mut data)?;
                        Ok(true)
                    })
                    .unwrap_or(false)
            };
            if !read {
                return changed(i);
            }
            let mut ids = ids.lock().unwrap();
            // In order: from its start a new id, on from where it was; a piece read again (a request packed anew) or
            // after its id was checked already is not counted twice.
            match ids.get_mut(path) {
                Some((h, next)) if *next == offset => {
                    h.update(&data);
                    *next += length;
                }
                Some((_, next)) if offset > *next => return changed(i),
                Some(_) => {}
                None if offset == 0 => {
                    let mut h = sha1::Sha1::new();
                    h.update(format!("blob {size}\0").as_bytes());
                    h.update(&data);
                    ids.insert(path.to_string(), (h, length));
                }
                None => {}
            }
            if ids.get(path).is_some_and(|(_, next)| *next == size) {
                let (h, _) = ids.remove(path).expect("there");
                if hex::encode(h.finalize()) != id {
                    return changed(i);
                }
            }
            data
        };
        raw += data.len() as u64;
        z.write_all(&data).map_err(err)?;
    }
    let mut file = z.finish().map_err(err)?;
    file.flush().map_err(err)?;
    let packed = file.metadata().map_err(err)?.len();
    Ok(json!({ "raw": raw, "packed": packed }))
}

/// Every zstd frame of the file at `path` as one stream, read whole: none at all, or one cut, fails.
fn unzstd_whole(path: &std::path::Path) -> Result<zstd::stream::read::Decoder<'static, std::io::BufReader<std::fs::File>>, String> {
    let file = std::fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    if file.metadata().map_err(err)?.len() == 0 {
        return Err(format!("{}: no zstd frame", path.display()));
    }
    zstd::stream::read::Decoder::new(file).map_err(err)
}

/// `zstd.segments`' work.
fn segment_into(path: &std::path::Path, unzstd: bool, out: &std::path::Path, segment: usize) -> Result<Value, String> {
    use std::io::Write;
    let mut source: Box<dyn std::io::Read> = if unzstd {
        Box::new(unzstd_whole(path)?)
    } else {
        Box::new(std::fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?)
    };
    let mut file = std::io::BufWriter::new(own_file(out)?);
    let mut z = zstd::bulk::Compressor::new(3).map_err(err)?;
    z.set_parameter(zstd::zstd_safe::CParameter::ChecksumFlag(true)).map_err(err)?;
    let mut frames: Vec<Value> = Vec::new();
    let mut frame = |raw: &[u8], file: &mut std::io::BufWriter<std::fs::File>| -> Result<(), String> {
        let bytes = z.compress(raw).map_err(err)?;
        file.write_all(&bytes).map_err(err)?;
        frames.push(json!([bytes.len(), raw.len()]));
        Ok(())
    };
    let mut held: Vec<u8> = Vec::with_capacity(segment + (1 << 20));
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = read_up_to(&mut *source, &mut buf).map_err(|e| format!("{}: {e}", path.display()))?;
        if n == 0 {
            break;
        }
        held.extend_from_slice(&buf[..n]);
        // (as zork's segment at a snapshot: what comes after its last line goes on in the next)
        while held.len() > segment {
            let cut = held[..segment].iter().rposition(|&b| b == b'\n').map_or(segment, |i| i + 1);
            frame(&held[..cut], &mut file)?;
            held.drain(..cut);
        }
    }
    frame(&held, &mut file)?;
    file.flush().map_err(err)?;
    Ok(json!({ "frames": frames }))
}

/// What `zstd.check` does with what the frames hold, a piece at a time.
struct Checked<'a> {
    hash: sha2::Sha256,
    size: u64,
    into: Option<std::io::BufWriter<std::fs::File>>,
    same: Option<(std::io::BufReader<std::fs::File>, Vec<u8>)>,
    path: &'a std::path::Path,
}

impl Checked<'_> {
    /// A piece taken: where the file it is compared with is not it, how ("shortened", "changed").
    fn take(&mut self, piece: &[u8]) -> Result<Option<&'static str>, String> {
        use sha2::Digest;
        use std::io::Write;
        self.hash.update(piece);
        self.size += piece.len() as u64;
        if let Some(into) = self.into.as_mut() {
            into.write_all(piece).map_err(err)?;
        }
        if let Some((file, mine)) = self.same.as_mut() {
            mine.resize(piece.len(), 0);
            let got = read_up_to(file, mine).map_err(err)?;
            if got < piece.len() {
                return Ok(Some("shortened"));
            }
            if mine.as_slice() != piece {
                return Ok(Some("changed"));
            }
        }
        Ok(None)
    }

    /// Everything of a zstd stream taken; how it differs, as `take`.
    fn drain(&mut self, mut from: impl std::io::Read) -> Result<Option<&'static str>, String> {
        let mut buf = vec![0u8; 256 * 1024];
        loop {
            let n = read_up_to(&mut from, &mut buf).map_err(|e| format!("{}: {e}", self.path.display()))?;
            if n == 0 {
                return Ok(None);
            }
            if let Some(differs) = self.take(&buf[..n])? {
                return Ok(Some(differs));
            }
        }
    }
}

/// `zstd.check`'s work.
fn check_frames(path: &std::path::Path, frames: Option<&[(u64, u64, u64)]>, into: Option<&std::path::Path>, same: Option<&std::path::Path>) -> Result<Value, String> {
    use sha2::Digest;
    use std::io::{Read, Seek, SeekFrom};
    let mut checked = Checked {
        hash: sha2::Sha256::new(),
        size: 0,
        into: into.map(own_file).transpose()?.map(std::io::BufWriter::new),
        same: same.map(|p| std::fs::File::open(p).map(|f| (std::io::BufReader::new(f), Vec::new()))).transpose().map_err(err)?,
        path,
    };
    let differs = match frames {
        None => checked.drain(unzstd_whole(path)?)?,
        Some(frames) => {
            let mut file = std::fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
            let mut differs = None;
            for &(at, packed, size) in frames {
                file.seek(SeekFrom::Start(at)).map_err(err)?;
                let before = checked.size;
                // (each frame alone, as a reader of a page decompresses it: one that ends early is cut, one with bytes
                // after its end is not one frame)
                let mut decoder = zstd::stream::read::Decoder::new((&mut file).take(packed)).map_err(err)?.single_frame();
                differs = checked.drain(&mut decoder)?;
                if differs.is_some() {
                    break;
                }
                let rest = decoder.finish();
                if !rest.buffer().is_empty() || rest.get_ref().limit() != 0 {
                    return Err("a put-away transcript frame has trailing bytes".into());
                }
                if checked.size - before != size {
                    return Err("a put-away transcript frame has the wrong size".into());
                }
            }
            differs
        }
    };
    if let Some(differs) = differs {
        return Ok(json!({ "differs": differs }));
    }
    if let Some((file, mine)) = checked.same.as_mut() {
        mine.resize(1, 0);
        if read_up_to(file, mine).map_err(err)? != 0 {
            return Ok(json!({ "differs": "changed" }));
        }
    }
    if let Some(into) = checked.into.take() {
        let file = into.into_inner().map_err(err)?;
        file.sync_all().map_err(err)?;
    }
    Ok(json!({ "size": checked.size, "sha256": hex::encode(checked.hash.finalize()) }))
}

impl Inner {
    pub(crate) async fn run_zstd(&self, op: &str, a: &Value, bytes: Option<Vec<u8>>) -> Done {
        match op {
            // `bytes` compressed whole at `level` with a window of 2^`window` (station/mesh/compress.ts's: what a station's
            // program answers a device that asks for zstd), off the caller's thread.
            "zstd.compress" => {
                let level = a.get("level").and_then(Value::as_i64).unwrap_or(3) as i32;
                let window = a.get("window").and_then(Value::as_u64).unwrap_or(20) as u32;
                let input = bytes.unwrap_or_default();
                let out = tokio::task::spawn_blocking(move || -> Result<Vec<u8>, String> {
                    let mut z = zstd::bulk::Compressor::new(level).map_err(err)?;
                    z.set_parameter(zstd::zstd_safe::CParameter::WindowLog(window)).map_err(err)?;
                    z.compress(&input).map_err(err)
                })
                .await
                .map_err(err)??;
                Ok(Answer::bytes(json!({}), out))
            }
            // What the zstd frames in `bytes` (or in the file at `path`) hold, `most` bytes of it at most: more is refused,
            // unpacked no further. A sync's pieces as another station sent them (station/mb src/reader/dirsync.mbt
            // `put_blobs`), off the caller's thread.
            "zstd.unpack" => {
                let most = a.get("most").and_then(Value::as_u64).ok_or("most is required")?;
                let path = a.get("path").and_then(Value::as_str).map(PathBuf::from);
                let input = bytes.unwrap_or_default();
                let out = tokio::task::spawn_blocking(move || -> Result<Vec<u8>, String> {
                    use std::io::Read;
                    let packed = match path {
                        Some(path) => std::fs::read(path).map_err(err)?,
                        None => input,
                    };
                    let mut out = Vec::new();
                    zstd::stream::read::Decoder::new(packed.as_slice()).map_err(err)?.take(most + 1).read_to_end(&mut out).map_err(err)?;
                    if out.len() as u64 > most {
                        return Err(format!("more than {most} bytes unpacked"));
                    }
                    Ok(out)
                })
                .await
                .map_err(err)??;
                Ok(Answer::bytes(json!({}), out))
            }
            // A zstd stream made of what is given it piece by piece (`zstd.push`), each piece flushed: what an event stream
            // a station's program answers goes out as (station/mesh/compress.ts `compressedStream`), `level` and a window of
            // 2^`window` its.
            "zstd.stream" => {
                let level = a.get("level").and_then(Value::as_i64).unwrap_or(3) as i32;
                let window = a.get("window").and_then(Value::as_u64).unwrap_or(20) as u32;
                let mut e = zstd::stream::raw::Encoder::new(level).map_err(err)?;
                e.set_parameter(zstd::zstd_safe::CParameter::WindowLog(window)).map_err(err)?;
                Ok(Answer::json(json!({ "id": self.keep(Handle::Zstd(Arc::new(Mutex::new(e)))) })))
            }
            "zstd.open" => Ok(Answer::json(json!({ "id": self.keep(Handle::Unzstd(Arc::new(Mutex::new(Unzstd::new()?)))) }))),
            "zstd.push" => {
                if let Handle::Zstd(z) = self.handle(id_of(a)?)? {
                    use zstd::stream::raw::{InBuffer, Operation, OutBuffer};
                    let input = bytes.unwrap_or_default();
                    let finish = a.get("finish").and_then(Value::as_bool).unwrap_or(false);
                    let mut z = z.lock().unwrap();
                    let mut out = Vec::with_capacity(input.len() / 2 + 64);
                    let mut chunk = vec![0u8; 64 * 1024];
                    let mut inb = InBuffer::around(&input);
                    while inb.pos() < input.len() {
                        let mut o = OutBuffer::around(&mut chunk[..]);
                        z.run(&mut inb, &mut o).map_err(err)?;
                        let n = o.pos();
                        out.extend_from_slice(&chunk[..n]);
                    }
                    loop {
                        let mut o = OutBuffer::around(&mut chunk[..]);
                        let left = if finish {
                            z.finish(&mut o, true).map_err(err)?
                        } else {
                            z.flush(&mut o).map_err(err)?
                        };
                        let n = o.pos();
                        out.extend_from_slice(&chunk[..n]);
                        if left == 0 {
                            break;
                        }
                    }
                    return Ok(Answer::bytes(json!({}), out));
                }
                let Handle::Unzstd(z) = self.handle(id_of(a)?)? else { return Err("not a zstd stream".into()) };
                let input = bytes.unwrap_or_default();
                let mut z = z.lock().unwrap();
                let out = z.take(&input)?;
                Ok(Answer::bytes(json!({ "whole": z.whole }), out))
            }
            "pack.open" => Ok(Answer::json(json!({ "id": self.keep(Handle::Pack(Arc::new(Mutex::new(HashMap::new())))) }))),
            // Pieces of files packed into one zstd frame written to the file at `out` (its own, made anew), off the caller's
            // thread: what a directory sync sends in one request (station/mb src/reader/dirsync.mbt `send_blobs`), its
            // bytes never through the program. Each piece [path, offset, length, size, id, link]: `length` bytes of the
            // file from `offset` (`link`: the link's target, whole), each file's Git blob id worked out across the calls
            // of one `pack.open` as its pieces come in order and checked at its last. A piece that does not read as it
            // was listed (shorter, its id another, a link not there) stops it: {changed: its index}. Else {raw, packed}:
            // the bytes taken and the frame's.
            "zstd.pack" => {
                let Handle::Pack(ids) = self.handle(id_of(a)?)? else { return Err("not a pack".into()) };
                let out = PathBuf::from(str_of(a, "out")?);
                let level = a.get("level").and_then(Value::as_i64).unwrap_or(3) as i32;
                let pieces = a.get("pieces").and_then(Value::as_array).cloned().ok_or("pieces are required")?;
                let value = tokio::task::spawn_blocking(move || pack_pieces(&ids, &out, level, &pieces)).await.map_err(err)??;
                Ok(Answer::json(value))
            }
            // A transcript put away (station/mb src/packed, as station/test/reference/packed.ts reads it): the file at
            // `path` (with `unzstd`, what its zstd frames hold, each whole and checksummed) cut into frames of at most
            // `segment` bytes, each ending at the end of its last line within them (none there: at `segment`), and a frame
            // made only once more than `segment` came, so the last is never empty but where the file is; each compressed
            // at level 3 with its checksum (as the Rust station's archive.rs, Node's ZSTD_c_checksumFlag) and written to
            // `out` (made anew, 0600), off the caller's thread, none of its bytes through the program. {frames: [[packed,
            // size]…]}: the table after them is the program's to write.
            "zstd.segments" => {
                let path = PathBuf::from(str_of(a, "path")?);
                let out = PathBuf::from(str_of(a, "out")?);
                let unzstd = a.get("unzstd").and_then(Value::as_bool).unwrap_or(false);
                let segment = a.get("segment").and_then(Value::as_u64).filter(|n| *n > 0).ok_or("segment is required")? as usize;
                let value = tokio::task::spawn_blocking(move || segment_into(&path, unzstd, &out, segment)).await.map_err(err)??;
                Ok(Answer::json(value))
            }
            // The zstd frames of the file at `path` read through, off the caller's thread: each whole (a cut one fails, as
            // the Rust station's decoder's "incomplete frame") and its checksum verified; with `frames` ([[at, packed,
            // size]…], a put-away transcript's table), each on its own, holding `size` bytes. What they hold written to
            // `into` (made anew, 0600, on disk before this answers) where it says, compared byte for byte with the file
            // at `same` where it says ({differs: "shortened" | "changed"} where that file is not it, to its end). {size,
            // sha256} of what they hold.
            "zstd.check" => {
                let path = PathBuf::from(str_of(a, "path")?);
                let frames = match a.get("frames") {
                    Some(Value::Array(fs)) => Some(
                        fs.iter()
                            .map(|f| match (f[0].as_u64(), f[1].as_u64(), f[2].as_u64()) {
                                (Some(at), Some(packed), Some(size)) => Ok((at, packed, size)),
                                _ => Err("bad frame".to_string()),
                            })
                            .collect::<Result<Vec<_>, _>>()?,
                    ),
                    _ => None,
                };
                let into = a.get("into").and_then(Value::as_str).map(PathBuf::from);
                let same = a.get("same").and_then(Value::as_str).map(PathBuf::from);
                let value = tokio::task::spawn_blocking(move || check_frames(&path, frames.as_deref(), into.as_deref(), same.as_deref())).await.map_err(err)??;
                Ok(Answer::json(value))
            }
            // A workspace put away as a GNU tar in zstd (mod tar; station/mb src/packed for sessions/archive.ts), each off
            // the caller's thread, a block at a time. `tar.pack` {dir, out}: the tree at `dir` (no link followed) into
            // `out` (made anew, 0600, on disk), read back to its zstd checksum, and the tree found unchanged meanwhile.
            "tar.pack" => {
                let dir = PathBuf::from(str_of(a, "dir")?);
                let out = PathBuf::from(str_of(a, "out")?);
                let value = tokio::task::spawn_blocking(move || tar::pack(&dir, &out)).await.map_err(err)??;
                Ok(Answer::json(value))
            }
            // `tar.unpack` {path, dest, prefix?}: the archive at `path` made in `dest` (only what is under `prefix`, its
            // files and directories, where given), read to its zstd checksum; {refused: [[path, target]…]}, the links the
            // machine refused (Windows without the privilege).
            "tar.unpack" => {
                let path = PathBuf::from(str_of(a, "path")?);
                let dest = PathBuf::from(str_of(a, "dest")?);
                let prefix = a.get("prefix").and_then(Value::as_str).map(str::to_string);
                let value = tokio::task::spawn_blocking(move || tar::unpack(&path, &dest, prefix.as_deref())).await.map_err(err)??;
                Ok(Answer::json(value))
            }
            // `tar.file` {path, wanted, out}: the file named `wanted` (its path's components) in the archive at `path`
            // written to `out` (made anew, 0600) where it is there: {found, size}.
            "tar.file" => {
                let path = PathBuf::from(str_of(a, "path")?);
                let out = PathBuf::from(str_of(a, "out")?);
                let wanted = a
                    .get("wanted")
                    .and_then(Value::as_array)
                    .ok_or("wanted is required")?
                    .iter()
                    .map(|p| p.as_str().map(str::to_string).ok_or("wanted is a path's components"))
                    .collect::<Result<Vec<_>, _>>()?;
                let value = tokio::task::spawn_blocking(move || tar::file(&path, &wanted, &out)).await.map_err(err)??;
                Ok(Answer::json(value))
            }
            other => Err(format!("no operation {other}")),
        }
    }
}
