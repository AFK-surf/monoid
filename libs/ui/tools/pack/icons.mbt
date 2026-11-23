// Single-source cross-platform icon pipeline and placeholder icon generator.

///|
fn clamp_byte(v : Double) -> Byte {
  let n = (v + 0.5).to_int()
  if n <= 0 {
    b'\x00'
  } else if n >= 255 {
    b'\xff'
  } else {
    n.to_byte()
  }
}

///|
/// Generate a clean rounded-square diagonal-gradient placeholder icon in pure MoonBit.
pub fn make_placeholder_icon(size : Int) -> @png.Picture {
  let buf = FixedArray::make(size * size * 4, b'\x00')
  let s = size.to_double()
  let pad = s * 0.08
  let radius = s * 0.22
  let min_x = pad
  let max_x = s - pad
  let min_y = pad
  let max_y = s - pad
  let cx = s * 0.5
  let cy = s * 0.5
  let inner_r = s * 0.19
  let inner_w = s * 0.055
  for y in 0..<size {
    let py = y.to_double() + 0.5
    for x in 0..<size {
      let px = x.to_double() + 0.5
      // Signed distance to rounded rectangle
      let qx = if px < min_x + radius {
        (min_x + radius) - px
      } else if px > max_x - radius {
        px - (max_x - radius)
      } else {
        0.0
      }
      let qy = if py < min_y + radius {
        (min_y + radius) - py
      } else if py > max_y - radius {
        py - (max_y - radius)
      } else {
        0.0
      }
      let corner_dist = (qx * qx + qy * qy).sqrt()
      let box_dx = if px < min_x { min_x - px } else if px > max_x { px - max_x } else { 0.0 }
      let box_dy = if py < min_y { min_y - py } else if py > max_y { py - max_y } else { 0.0 }
      let sdf = if qx > 0.0 && qy > 0.0 {
        corner_dist - radius
      } else if box_dx > 0.0 || box_dy > 0.0 {
        if box_dx > box_dy { box_dx } else { box_dy }
      } else {
        let dl = px - min_x
        let dr = max_x - px
        let dt = py - min_y
        let db = max_y - py
        let m1 = if dl < dr { dl } else { dr }
        let m2 = if dt < db { dt } else { db }
        -(if m1 < m2 { m1 } else { m2 })
      }
      let alpha = if sdf <= -0.5 {
        1.0
      } else if sdf >= 0.5 {
        0.0
      } else {
        0.5 - sdf
      }
      if alpha > 0.0 {
        // Diagonal warm-coral to deep-indigo gradient
        let t = ((px / s) * 0.65 + (py / s) * 0.35)
        let mut r = 232.0 * (1.0 - t) + 56.0 * t
        let mut g = 104.0 * (1.0 - t) + 84.0 * t
        let mut b = 62.0 * (1.0 - t) + 196.0 * t
        // Subtle crisp white ring in center
        let d_ring = ((px - cx) * (px - cx) + (py - cy) * (py - cy)).sqrt() - inner_r
        let ring_cov = 0.5 - (d_ring.abs() - inner_w * 0.5)
        if ring_cov > 0.0 {
          let k = if ring_cov > 1.0 { 1.0 } else { ring_cov }
          r = r * (1.0 - k) + 255.0 * k
          g = g * (1.0 - k) + 255.0 * k
          b = b * (1.0 - k) + 255.0 * k
        }
        let off = (y * size + x) * 4
        buf[off] = clamp_byte(r)
        buf[off + 1] = clamp_byte(g)
        buf[off + 2] = clamp_byte(b)
        buf[off + 3] = clamp_byte(alpha * 255.0)
      }
    }
  }
  @png.Picture::new(size, size, Bytes::from_array(buf[:]))
}

///|
fn write_file_bytes(path : String, data : Bytes) -> Result[Unit, String] {
  let dir = @sys.dirname(path)
  if dir != "" {
    @sys.makedirs(dir)
  }
  if @sys.write_bytes(path, data) {
    Ok(())
  } else {
    Err("failed to write \{path}")
  }
}

///|
fn write_file_text(path : String, text : String) -> Result[Unit, String] {
  let dir = @sys.dirname(path)
  if dir != "" {
    @sys.makedirs(dir)
  }
  if @sys.write_text(path, text) {
    Ok(())
  } else {
    Err("failed to write \{path}")
  }
}

///|
pub fn render_ios_iconset_json(has_dark : Bool) -> String {
  let sb = StringBuilder()
  sb.write_string("{\n")
  sb.write_string("  \"images\": [\n")
  sb.write_string("    {\n")
  sb.write_string("      \"filename\": \"icon.png\",\n")
  sb.write_string("      \"idiom\": \"universal\",\n")
  sb.write_string("      \"platform\": \"ios\",\n")
  sb.write_string("      \"size\": \"1024x1024\"\n")
  if has_dark {
    sb.write_string("    },\n")
    sb.write_string("    {\n")
    sb.write_string("      \"appearances\": [\n")
    sb.write_string("        {\n")
    sb.write_string("          \"appearance\": \"luminosity\",\n")
    sb.write_string("          \"value\": \"dark\"\n")
    sb.write_string("        }\n")
    sb.write_string("      ],\n")
    sb.write_string("      \"filename\": \"icon-dark.png\",\n")
    sb.write_string("      \"idiom\": \"universal\",\n")
    sb.write_string("      \"platform\": \"ios\",\n")
    sb.write_string("      \"size\": \"1024x1024\"\n")
    sb.write_string("    }\n")
  } else {
    sb.write_string("    }\n")
  }
  sb.write_string("  ],\n")
  sb.write_string("  \"info\": {\n")
  sb.write_string("    \"author\": \"mbui\",\n")
  sb.write_string("    \"version\": 1\n")
  sb.write_string("  }\n")
  sb.write_string("}\n")
  sb.to_string()
}

///|
/// Generate web icons (`favicon.ico`, `icon-192.png`, `icon-512.png`) into `web_dir`.
pub fn generate_web_icons(src : @png.Picture, web_dir : String) -> Result[Array[String], String] {
  let written : Array[String] = []
  let fav_path = @sys.join(web_dir, "favicon.ico")
  let fav_ico = @png.encode_ico([src.resize(16, 16), src.resize(32, 32), src.resize(48, 48)])
  match write_file_bytes(fav_path, fav_ico) {
    Ok(_) => written.push(fav_path)
    Err(e) => return Err(e)
  }
  let p192 = @sys.join(web_dir, "icon-192.png")
  match write_file_bytes(p192, @png.encode_png(src.resize(192, 192))) {
    Ok(_) => written.push(p192)
    Err(e) => return Err(e)
  }
  let p512 = @sys.join(web_dir, "icon-512.png")
  match write_file_bytes(p512, @png.encode_png(src.resize(512, 512))) {
    Ok(_) => written.push(p512)
    Err(e) => return Err(e)
  }
  Ok(written)
}

///|
/// Generate icons for `platform` (`all|mac|win|linux|android|ios|web`) from the manifest's `icon`
/// (and optional `iconDark`) into `out_dir`.
pub fn generate_icons(
  m : Manifest,
  manifest_dir : String,
  out_dir : String,
  platform : String,
) -> Result[Array[String], String] {
  if platform != "all" &&
    platform != "mac" &&
    platform != "win" &&
    platform != "linux" &&
    platform != "android" &&
    platform != "ios" &&
    platform != "web" {
    return Err("unknown --platform '\{platform}' (expected all|mac|win|linux|android|ios|web)")
  }
  if m.icon == "" {
    return Err("manifest has no 'icon' field")
  }
  let icon_path = @sys.join(manifest_dir, m.icon)
  let src = match @png.read(icon_path) {
    Ok(p) => p
    Err(e) => return Err("icon: \{e}")
  }
  let dark_opt : @png.Picture? = if m.icon_dark != "" {
    let dark_path = @sys.join(manifest_dir, m.icon_dark)
    match @png.read(dark_path) {
      Ok(p) => Some(p)
      Err(e) => return Err("iconDark: \{e}")
    }
  } else {
    None
  }
  let written : Array[String] = []
  let want = fn(p : String) -> Bool { platform == "all" || platform == p }

  if want("mac") {
    let dest = @sys.join(out_dir, "mac/AppIcon.icns")
    match write_file_bytes(dest, @png.encode_icns(src)) {
      Ok(_) => written.push(dest)
      Err(e) => return Err(e)
    }
  }

  if want("win") {
    let dest = @sys.join(out_dir, "win/app.ico")
    let dims = [16, 24, 32, 48, 64, 128, 256]
    let pics = dims.map(fn(sz) { src.resize(sz, sz) })
    match write_file_bytes(dest, @png.encode_ico(pics)) {
      Ok(_) => written.push(dest)
      Err(e) => return Err(e)
    }
  }

  if want("linux") {
    let dest = @sys.join(out_dir, "linux/icon-512.png")
    match write_file_bytes(dest, @png.encode_png(src.resize(512, 512))) {
      Ok(_) => written.push(dest)
      Err(e) => return Err(e)
    }
  }

  if want("ios") {
    let set_dir = @sys.join(out_dir, "ios/Assets.xcassets/AppIcon.appiconset")
    let main_png = @sys.join(set_dir, "icon.png")
    match write_file_bytes(main_png, @png.encode_png(src.resize(1024, 1024))) {
      Ok(_) => written.push(main_png)
      Err(e) => return Err(e)
    }
    let has_dark = match dark_opt {
      Some(dp) => {
        let dark_png = @sys.join(set_dir, "icon-dark.png")
        match write_file_bytes(dark_png, @png.encode_png(dp.resize(1024, 1024))) {
          Ok(_) => written.push(dark_png)
          Err(e) => return Err(e)
        }
        true
      }
      None => false
    }
    let contents = @sys.join(set_dir, "Contents.json")
    match write_file_text(contents, render_ios_iconset_json(has_dark)) {
      Ok(_) => written.push(contents)
      Err(e) => return Err(e)
    }
  }

  if want("android") {
    let buckets : Array[(String, Int)] = [
      ("mdpi", 48),
      ("hdpi", 72),
      ("xhdpi", 96),
      ("xxhdpi", 144),
      ("xxxhdpi", 192),
    ]
    for b in buckets {
      let dest = @sys.join(out_dir, "android/res/mipmap-\{b.0}/ic_launcher.png")
      match write_file_bytes(dest, @png.encode_png(src.resize(b.1, b.1))) {
        Ok(_) => written.push(dest)
        Err(e) => return Err(e)
      }
    }
  }

  if want("web") {
    match generate_web_icons(src, @sys.join(out_dir, "web")) {
      Ok(files) =>
        for f in files {
          written.push(f)
        }
      Err(e) => return Err(e)
    }
  }

  Ok(written)
}
