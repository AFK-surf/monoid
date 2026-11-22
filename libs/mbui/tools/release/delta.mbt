// Pure MoonBit SFDELTA1 delta encoder compatible with `libs/mbui/src/host/update_delta.h`.

///|
fn push_u16_le(out : Array[Byte], v : Int) -> Unit {
  out.push((v & 0xFF).to_byte())
  out.push(((v >> 8) & 0xFF).to_byte())
}

///|
fn push_u32_le(out : Array[Byte], v : Int) -> Unit {
  out.push((v & 0xFF).to_byte())
  out.push(((v >> 8) & 0xFF).to_byte())
  out.push(((v >> 16) & 0xFF).to_byte())
  out.push(((v >> 24) & 0xFF).to_byte())
}

///|
fn push_u64_le(out : Array[Byte], v : UInt64) -> Unit {
  for k in 0..<8 {
    out.push(((v >> (8 * k)) & 0xFFUL).to_byte())
  }
}

///|
fn push_i64_le(out : Array[Byte], v : Int64) -> Unit {
  push_u64_le(out, v.reinterpret_as_uint64())
}

///|
fn hash4(data : Bytes, i : Int) -> Int {
  let v = data[i].to_uint() |
    (data[i + 1].to_uint() << 8) |
    (data[i + 2].to_uint() << 16) |
    (data[i + 3].to_uint() << 24)
  (((v * 2654435761U) >> 16) & 0xFFFFU).reinterpret_as_int()
}

///|
/// Generate an Endsley-layout uncompressed bsdiff stream (two's complement LE i64 x, y, z)
/// matching `libs/mbui/src/host/update_delta.h`'s `ud_patch_take`.
fn bsdiff_stream(old_blob : Bytes, new_blob : Bytes) -> Bytes {
  let old_n = old_blob.length()
  let new_n = new_blob.length()
  if new_n == 0 {
    return b""
  }
  let out : Array[Byte] = Array(capacity=new_n / 2 + 64)
  if old_n < 4 {
    push_i64_le(out, 0L)
    push_i64_le(out, new_n.to_int64())
    push_i64_le(out, 0L)
    for i in 0..<new_n {
      out.push(new_blob[i])
    }
    return Bytes::makei(out.length(), fn(i) { out[i] })
  }

  // Build 4-byte hash chains over old_blob
  let head = FixedArray::make(65536, -1)
  let prev = FixedArray::make(old_n, -1)
  for i in 0..<(old_n - 3) {
    let h = hash4(old_blob, i)
    prev[i] = head[h]
    head[h] = i
  }

  let search_best = fn(scan : Int) -> (Int, Int) {
    if scan + 4 > new_n {
      return (0, 0)
    }
    let h = hash4(new_blob, scan)
    let mut cand = head[h]
    let mut best_pos = 0
    let mut best_len = 0
    let mut steps = 0
    while cand >= 0 && steps < 32 {
      if old_blob[cand] == new_blob[scan] &&
        old_blob[cand + 1] == new_blob[scan + 1] &&
        old_blob[cand + 2] == new_blob[scan + 2] &&
        old_blob[cand + 3] == new_blob[scan + 3] {
        let mut l = 4
        let lim = if new_n - scan < old_n - cand {
          new_n - scan
        } else {
          old_n - cand
        }
        while l < lim && old_blob[cand + l] == new_blob[scan + l] {
          l += 1
        }
        if l > best_len {
          best_len = l
          best_pos = cand
          if l >= 128 {
            break
          }
        }
      }
      cand = prev[cand]
      steps += 1
    }
    (best_pos, best_len)
  }

  let mut scan = 0
  let mut len = 0
  let mut pos = 0
  let mut lastscan = 0
  let mut lastpos = 0
  let mut lastoffset = 0

  while scan < new_n {
    let mut oldscore = 0
    scan += len
    let mut scsc = scan
    while scan < new_n {
      let (p, l) = search_best(scan)
      pos = p
      len = l
      while scsc < scan + len {
        if scsc + lastoffset >= 0 &&
          scsc + lastoffset < old_n &&
          old_blob[scsc + lastoffset] == new_blob[scsc] {
          oldscore += 1
        }
        scsc += 1
      }
      if (len == oldscore && len != 0) || len > oldscore + 8 {
        break
      }
      if scan + lastoffset >= 0 &&
        scan + lastoffset < old_n &&
        old_blob[scan + lastoffset] == new_blob[scan] {
        oldscore -= 1
      }
      scan += 1
    }

    if len != oldscore || scan == new_n {
      // Extend forward from lastscan along lastpos
      let mut s = 0
      let mut sf = 0
      let mut lenf = 0
      let mut i = 0
      while lastscan + i < scan && lastpos + i < old_n {
        if old_blob[lastpos + i] == new_blob[lastscan + i] {
          s += 1
        }
        i += 1
        if s * 2 - i > sf * 2 - lenf {
          sf = s
          lenf = i
        }
      }

      // Extend backward from scan along pos
      let mut lenb = 0
      if scan < new_n {
        let mut sb = 0
        let mut s2 = 0
        let mut j = 1
        while scan >= lastscan + j && pos >= j {
          if old_blob[pos - j] == new_blob[scan - j] {
            s2 += 1
          }
          if s2 * 2 - j > sb * 2 - lenb {
            sb = s2
            lenb = j
          }
          j += 1
        }
      }

      // Resolve overlap between forward and backward extensions
      if lastscan + lenf > scan - lenb {
        let overlap = lastscan + lenf - (scan - lenb)
        let mut s3 = 0
        let mut ss = 0
        let mut lens = 0
        for k in 0..<overlap {
          if new_blob[lastscan + lenf - overlap + k] ==
            old_blob[lastpos + lenf - overlap + k] {
            s3 += 1
          }
          if new_blob[scan - lenb + k] == old_blob[pos - lenb + k] {
            s3 -= 1
          }
          if s3 > ss {
            ss = s3
            lens = k + 1
          }
        }
        lenf += lens - overlap
        lenb -= lens
      }

      let extra_len = scan - lenb - (lastscan + lenf)
      let z = (pos - lenb - (lastpos + lenf)).to_int64()
      push_i64_le(out, lenf.to_int64())
      push_i64_le(out, extra_len.to_int64())
      push_i64_le(out, z)

      // Diff bytes: new[lastscan + k] - old[lastpos + k] (mod 256)
      for k in 0..<lenf {
        let old_b = if lastpos + k >= 0 && lastpos + k < old_n {
          old_blob[lastpos + k].to_int()
        } else {
          0
        }
        out.push(((new_blob[lastscan + k].to_int() - old_b) & 0xFF).to_byte())
      }
      // Extra bytes: literal slice of new_blob
      for k in 0..<extra_len {
        out.push(new_blob[lastscan + lenf + k])
      }

      lastscan = scan - lenb
      lastpos = pos - lenb
      lastoffset = pos - scan
    }
  }
  Bytes::makei(out.length(), fn(i) { out[i] })
}

///|
/// Collect all regular files under `dir` (skipping symlinks), returning sorted relative POSIX paths.
fn collect_rel_files(root : String) -> Array[String] {
  let out : Array[String] = []
  fn walk(rel : String) -> Unit {
    let full = if rel == "" { root } else { @sys.join(root, rel) }
    let names = @sys.list_dir(full)
    names.sort_by(fn(a, b) { @rjson.str_cmp(a, b) })
    for name in names {
      let child_rel = if rel == "" { name } else { rel + "/" + name }
      let child_full = @sys.join(root, child_rel)
      if @sys.is_link(child_full) {
        continue
      }
      if @sys.is_dir(child_full) {
        walk(child_rel)
      } else if @sys.is_file(child_full) {
        out.push(child_rel)
      }
    }
  }
  walk("")
  out.sort_by(fn(a, b) { @rjson.str_cmp(a, b) })
  out
}

///|
/// Encode an `SFDELTA1` delta from a list of `(rel_path, bytes)` old files to `new_bytes`.
fn encode_sfdelta1(
  old_files : Array[(String, Bytes)],
  new_bytes : Bytes,
) -> Result[Bytes, String] {
  if old_files.length() == 0 {
    return Err("old directory contains no regular files")
  }
  let mut old_total = 0
  for item in old_files {
    old_total += item.1.length()
  }
  let old_buf = FixedArray::make(old_total, b'\x00')
  let mut at = 0
  for item in old_files {
    let b = item.1
    for i in 0..<b.length() {
      old_buf[at + i] = b[i]
    }
    at += b.length()
  }
  let old_blob = Bytes::makei(old_total, fn(i) { old_buf[i] })
  let old_sha = sha256_bytes(old_blob)
  let patch = bsdiff_stream(old_blob, new_bytes)

  let out : Array[Byte] = Array(capacity=patch.length() / 2 + 256)
  // Magic: "SFDELTA1"
  for b in @utf8.encode("SFDELTA1") {
    out.push(b)
  }
  // n_files + file paths
  push_u32_le(out, old_files.length())
  for item in old_files {
    let p_bytes = @utf8.encode(item.0)
    if p_bytes.length() > 65535 {
      return Err("path too long for SFDELTA1: \{item.0}")
    }
    push_u16_le(out, p_bytes.length())
    for b in p_bytes {
      out.push(b)
    }
  }
  // n_inflate = 0
  push_u32_le(out, 0)
  // old_size + 32-byte SHA-256 of old_blob
  push_u64_le(out, old_total.to_uint64())
  for i in 0..<32 {
    out.push(old_sha[i])
  }
  // n_deflate = 0
  push_u32_le(out, 0)
  // made_size
  push_u64_le(out, new_bytes.length().to_uint64())

  // Chunks (<= 1 MiB raw each)
  let chunk_max = 1048576
  let mut offset = 0
  while offset < patch.length() {
    let rem = patch.length() - offset
    let raw_len = if rem > chunk_max { chunk_max } else { rem }
    let chunk = Bytes::makei(raw_len, fn(i) { patch[offset + i] })
    let packed = deflate_raw(chunk)
    push_u32_le(out, raw_len)
    push_u32_le(out, packed.length())
    for i in 0..<packed.length() {
      out.push(packed[i])
    }
    offset += raw_len
  }
  // End chunk: { 0, 0 }
  push_u32_le(out, 0)
  push_u32_le(out, 0)

  Ok(Bytes::makei(out.length(), fn(i) { out[i] }))
}
