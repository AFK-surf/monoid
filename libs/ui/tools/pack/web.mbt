// Web target: HTML & PWA manifest generation and web.sh bundle orchestration.

///|
fn escape_html(s : String) -> String {
  let sb = StringBuilder()
  for c in s {
    match c {
      '&' => sb.write_string("&amp;")
      '<' => sb.write_string("&lt;")
      '>' => sb.write_string("&gt;")
      '"' => sb.write_string("&quot;")
      '\'' => sb.write_string("&#39;")
      _ => sb.write_char(c)
    }
  }
  sb.to_string()
}

///|
/// Generate a clean production `index.html` from the manifest, with theme-color,
/// icons, optional PWA manifest, custom head injection, and WebGL 2 fallback UI.
pub fn render_web_html(m : Manifest, has_icons : Bool) -> String {
  let title = escape_html(if m.web.title != "" { m.web.title } else { m.name })
  let bg_light = if m.web.theme_color_light != "" { m.web.theme_color_light } else { "#F5F5F7" }
  let bg_dark = if m.web.theme_color_dark != "" { m.web.theme_color_dark } else { "#1F2023" }
  let sb = StringBuilder()
  sb.write_string("<!doctype html>\n")
  sb.write_string("<html lang=\"en\">\n")
  sb.write_string("<head>\n")
  sb.write_string("<meta charset=\"utf-8\">\n")
  sb.write_string("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, viewport-fit=cover\">\n")
  if m.web.theme_color_light != "" {
    sb.write_string(
      "<meta name=\"theme-color\" media=\"(prefers-color-scheme: light)\" content=\"\{escape_html(m.web.theme_color_light)}\">\n",
    )
  }
  if m.web.theme_color_dark != "" {
    sb.write_string(
      "<meta name=\"theme-color\" media=\"(prefers-color-scheme: dark)\" content=\"\{escape_html(m.web.theme_color_dark)}\">\n",
    )
  }
  if m.web.theme_color_light == "" && m.web.theme_color_dark == "" {
    sb.write_string("<meta name=\"theme-color\" content=\"\">\n")
  }
  sb.write_string("<title>\{title}</title>\n")
  if has_icons {
    sb.write_string("<link rel=\"icon\" href=\"favicon.ico\">\n")
    sb.write_string("<link rel=\"apple-touch-icon\" href=\"icon-192.png\">\n")
  }
  if m.web.pwa {
    sb.write_string("<link rel=\"manifest\" href=\"manifest.webmanifest\">\n")
  }
  if m.web.head != "" {
    sb.write_string(m.web.head)
    if !m.web.head.has_suffix("\n") {
      sb.write_string("\n")
    }
  }
  sb.write_string("<style>\n")
  sb.write_string(
    "  html, body { margin: 0; height: 100%; overflow: hidden; background: \{escape_html(bg_light)}; overscroll-behavior: none; -webkit-tap-highlight-color: transparent; }\n",
  )
  sb.write_string(
    "  @media (prefers-color-scheme: dark) { html, body { background: \{escape_html(bg_dark)}; } }\n",
  )
  sb.write_string(
    "  #c { position: fixed; inset: 0; width: 100%; height: 100%; touch-action: none; display: block; user-select: none; -webkit-user-select: none; -webkit-touch-callout: none; }\n",
  )
  sb.write_string(
    "  #ime { position: fixed; left: 0; top: 0; width: 2px; height: 20px; opacity: 0; padding: 0; border: 0; resize: none; overflow: hidden; font-size: 16px; caret-color: transparent; color: transparent; background: transparent; outline: none; }\n",
  )
  sb.write_string(
    "  #nogl { --ground: #F5F3EF; --card: #FFFFFF; --ink: #24272B; --muted: #565B62; --line: #322D2424; --primary: #24272B; --on-primary: #FFFFFF; position: fixed; inset: 0; z-index: 1; overflow: auto; display: flex; box-sizing: border-box; padding: 24px 16px; background: var(--ground); color: var(--ink); font: 400 14px/20px system-ui, -apple-system, sans-serif; }\n",
  )
  sb.write_string(
    "  @media (prefers-color-scheme: dark) { #nogl { --ground: #1F2023; --card: #26272B; --ink: #E9E9EA; --muted: #A8AAAE; --line: #E9E9EA19; --primary: #ECEDED; --on-primary: #1F2023; } }\n",
  )
  sb.write_string("  #nogl[hidden] { display: none; }\n")
  sb.write_string(
    "  #nogl .card { margin: auto; width: 100%; max-width: 440px; padding: 24px; background: var(--card); border-radius: 20px; box-shadow: 0 0 0 1px var(--line); }\n",
  )
  sb.write_string("  #nogl h1 { margin: 0 0 8px; font-size: 18px; line-height: 26px; font-weight: 600; }\n")
  sb.write_string("  #nogl p { margin: 0 0 16px; color: var(--muted); }\n")
  sb.write_string(
    "  #nogl button { font: inherit; font-weight: 500; cursor: pointer; border: 0; border-radius: 999px; height: 32px; padding: 0 16px; background: var(--primary); color: var(--on-primary); }\n",
  )
  sb.write_string("</style>\n")
  sb.write_string("</head>\n")
  sb.write_string("<body>\n")
  sb.write_string("<canvas id=\"c\"></canvas>\n")
  sb.write_string("<textarea id=\"ime\" autocapitalize=\"off\" autocomplete=\"off\" spellcheck=\"false\"></textarea>\n")
  sb.write_string("<div id=\"nogl\" hidden>\n")
  sb.write_string("  <main class=\"card\">\n")
  sb.write_string("    <h1 id=\"nogl-h\">WebGL 2 required</h1>\n")
  sb.write_string("    <p id=\"nogl-lead\">Please enable hardware acceleration in your browser settings and reload.</p>\n")
  sb.write_string("    <button type=\"button\" id=\"nogl-retry\">Retry</button>\n")
  sb.write_string("  </main>\n")
  sb.write_string("</div>\n")
  sb.write_string("<script>\n")
  sb.write_string("(function () {\n")
  sb.write_string("  var ok = !!globalThis.__mbrender;\n")
  sb.write_string("  if (!ok) {\n")
  sb.write_string("    try {\n")
  sb.write_string("      var gl = document.createElement('canvas').getContext('webgl2');\n")
  sb.write_string("      if (gl) { ok = true; var lose = gl.getExtension('WEBGL_lose_context'); if (lose) lose.loseContext(); }\n")
  sb.write_string("    } catch (e) {}\n")
  sb.write_string("  }\n")
  sb.write_string("  if (ok) {\n")
  sb.write_string("    ['host.js', 'app.js'].forEach(function (src) {\n")
  sb.write_string("      var s = document.createElement('script'); s.src = src; s.async = false; document.body.appendChild(s);\n")
  sb.write_string("    });\n")
  sb.write_string("    return;\n")
  sb.write_string("  }\n")
  sb.write_string("  document.getElementById('c').style.display = 'none';\n")
  sb.write_string("  document.getElementById('ime').style.display = 'none';\n")
  sb.write_string("  var nogl = document.getElementById('nogl');\n")
  sb.write_string("  document.getElementById('nogl-retry').addEventListener('click', function () { location.reload(); });\n")
  sb.write_string("  nogl.hidden = false;\n")
  sb.write_string("})();\n")
  sb.write_string("</script>\n")
  sb.write_string("</body>\n")
  sb.write_string("</html>\n")
  sb.to_string()
}

///|
/// Generate `manifest.webmanifest` JSON when `web.pwa` is true.
pub fn render_web_manifest(m : Manifest, has_icons : Bool) -> String {
  let theme = if m.web.theme_color_light != "" { m.web.theme_color_light } else { "#F5F5F7" }
  let title = if m.web.title != "" { m.web.title } else { m.name }
  let kvs : Array[(String, @rjson.Value)] = [
    ("name", Str(title)),
    ("short_name", Str(m.name)),
    ("start_url", Str(".")),
    ("display", Str("standalone")),
    ("background_color", Str(theme)),
    ("theme_color", Str(theme)),
  ]
  if has_icons {
    let icons : Array[@rjson.Value] = [
      Obj([
        ("src", Str("icon-192.png")),
        ("sizes", Str("192x192")),
        ("type", Str("image/png")),
      ]),
      Obj([
        ("src", Str("icon-512.png")),
        ("sizes", Str("512x512")),
        ("type", Str("image/png")),
      ]),
    ]
    kvs.push(("icons", Arr(icons)))
  }
  @rjson.dumps(Obj(kvs), indent=2, ensure_ascii=false) + "\n"
}

///|
fn collect_web_compressible(dir : String, out : Array[String]) -> Unit {
  let entries = @sys.list_dir(dir)
  entries.sort_by(fn(a, b) { @rjson.str_cmp(a, b) })
  for entry in entries {
    let p = @sys.join(dir, entry)
    if @sys.is_dir(p) {
      collect_web_compressible(p, out)
    } else if @sys.is_file(p) &&
      (entry.has_suffix(".js") || entry.has_suffix(".html") || entry.has_suffix(".wasm")) {
      out.push(p)
    }
  }
}

///|
fn compress_web_assets(web_out : String, brotli : Bool) -> Unit {
  let files : Array[String] = []
  collect_web_compressible(web_out, files)
  if files.length() == 0 {
    return
  }
  let js_script = "const z=require('node:zlib'),fs=require('node:fs');const br=process.argv[1]==='1';for(const f of process.argv.slice(2)){const b=fs.readFileSync(f);fs.writeFileSync(f+'.gz',z.gzipSync(b,{level:9}));if(br){fs.writeFileSync(f+'.br',z.brotliCompressSync(b,{params:{[z.constants.BROTLI_PARAM_QUALITY]:11,[z.constants.BROTLI_PARAM_LGWIN]:24,[z.constants.BROTLI_PARAM_SIZE_HINT]:b.length}}));}}"
  let br_arg = if brotli { "1" } else { "0" }
  let kind = if brotli { "gz + br" } else { "gz" }
  let quoted_files = files.map(q).join(" ")
  say("compressing \{files.length()} web asset(s) (\{kind})...")
  ignore(sh("node -e " + q(js_script) + " " + q(br_arg) + " " + quoted_files, "compress web assets"))
}

///|
pub fn pack_web(
  m : Manifest,
  manifest_dir : String,
  mbui_dir : String,
  out_dir : String,
  opts : PackOptions,
) -> Unit {
  let web_out = @sys.join(out_dir, "web")
  let build_out = @sys.join(out_dir, ".build")
  @sys.makedirs(web_out)
  @sys.makedirs(build_out)

  run_hook("preBuild", m.hooks.pre_build, m, manifest_dir, mbui_dir, "web", web_out, web_out)

  let mod_dir = m.resolve_module_dir(manifest_dir)
  let pkg = m.entry_pkg()
  let mode = if opts.quick { "debug" } else { "release" }
  let web_sh = @sys.join(mbui_dir, "scripts/web.sh")
  let cmd = "MBUI_APP_MOD=" + q(mod_dir) +
    " MBUI_OUT=" + q(build_out) +
    " APP=" + q(pkg) +
    " MODE=" + q(mode) +
    " MBUI_QUICK=" + (if opts.quick { "1" } else { "0" }) +
    " MBUI_WEB_BROTLI=0" +
    " bash " + q(web_sh) + " bundle " + q(web_out)
  say("building web bundle (\{pkg}, \{mode})...")
  ignore(sh(cmd, "web.sh bundle"))

  // Copy icons if configured
  let mut has_icons = false
  if m.icon != "" {
    let icon_path = @sys.join(manifest_dir, m.icon)
    match @png.read(icon_path) {
      Ok(src) =>
        match generate_web_icons(src, web_out) {
          Ok(_) => has_icons = true
          Err(e) => die("web icons: \{e}")
        }
      Err(e) => die("icon: \{e}")
    }
  }

  // Write production index.html
  let html_path = @sys.join(web_out, "index.html")
  match write_file_text(html_path, render_web_html(m, has_icons)) {
    Ok(_) => ()
    Err(e) => die(e)
  }

  // Write PWA manifest if enabled
  if m.web.pwa {
    let mf_path = @sys.join(web_out, "manifest.webmanifest")
    match write_file_text(mf_path, render_web_manifest(m, has_icons)) {
      Ok(_) => ()
      Err(e) => die(e)
    }
  }

  // Copy resources into web_out
  for res in m.resources {
    let src_res = @sys.join(manifest_dir, res)
    if !@sys.exists(src_res) {
      die("resource not found: \{src_res}")
    }
    let dst_res = @sys.join(web_out, @sys.basename(res))
    ignore(sh("cp -R " + q(src_res) + " " + q(dst_res), "copy resource"))
  }

  run_hook("postStage", m.hooks.post_stage, m, manifest_dir, mbui_dir, "web", web_out, web_out)

  if !opts.quick && !opts.web_no_compress {
    compress_web_assets(web_out, m.web.brotli)
  }

  run_hook("postPack", m.hooks.post_pack, m, manifest_dir, mbui_dir, "web", web_out, web_out)

  say("web output ready at \{web_out}")
}
