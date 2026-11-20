// One Linux desktop source (src/screens/linux-desktop.ts): select the current user's active X11 or Wayland session
// when it is asked for.

/// (none: the station's) and how a session's is found (default: logind's, linux_session.mbt).
pub(all) struct LinuxOptions {
  data : String
  changed : () -> Unit
  title : (() -> String)?
  env : Env?
  discover : (async (Env) -> Env)?
  native_binary : String?
  native_start : LinuxNativeStart?
}

///|
#derive(Eq)
priv enum Current {
  CurNative
  CurX11
  CurWayland
  CurFallback
}

///|
/// The Linux desktop (linux-desktop.ts `LinuxDesktop`).
pub struct LinuxDesktop {
  priv io : Io
  priv o : LinuxOptions
  priv tools : LinuxScreenTools
  priv native_ : LinuxNativeDesktop
  priv x11 : X11Desktop
  priv wayland : LinuxGstDesktop
  priv fallback : LinuxGstDesktop
  priv mut current : Current
  priv refreshing : Shared[Unit]
  priv mut looked : Double
}

///|
pub fn LinuxDesktop::new(io : Io, o : LinuxOptions) -> LinuxDesktop {
  let env = o.env.unwrap_or((io.os.env)()).copy()
  let tools = LinuxScreenTools::new(io, o.data)
  let native_ = LinuxNativeDesktop::new(io, { binary: o.native_binary, changed: o.changed, title: o.title, env: Some(env), start: o.native_start })
  let x11 = X11Desktop::new(io, { changed: o.changed, title: o.title, tools: Some(tools), env: Some(env), ffmpeg: None, xdotool: None, prepare_wait_ms: None })
  let wayland = LinuxGstDesktop::new(io, { changed: o.changed, env, mode: None, title: o.title, python: None, helper: None, consent_wait_ms: None })
  let fallback = LinuxGstDesktop::new(io, { changed: o.changed, env, mode: Some("x11"), title: o.title, python: None, helper: None, consent_wait_ms: None })
  let wayland_env = env.get("XDG_SESSION_TYPE").map(t => t.to_lower()) == Some("wayland") || env.truthy("WAYLAND_DISPLAY") is Some(_)
  {
    io,
    o,
    tools,
    native_,
    x11,
    wayland,
    fallback,
    current: if wayland_env { CurWayland } else { CurX11 },
    refreshing: Shared::new(),
    looked: 0.0,
  }
}

///|
pub fn LinuxDesktop::title(self : LinuxDesktop) -> String {
  match self.o.title {
    Some(f) => f()
    None => (self.io.os.hostname)()
  }
}

///|
pub fn LinuxDesktop::size(self : LinuxDesktop) -> (Double, Double) {
  match self.current {
    CurNative => self.native_.size()
    CurX11 => self.x11.size()
    CurWayland => self.wayland.size()
    CurFallback => self.fallback.size()
  }
}

///|
pub fn LinuxDesktop::access(self : LinuxDesktop) -> ScreenAccess {
  match self.current {
    CurNative => self.native_.access()
    CurX11 => self.x11.access()
    CurWayland => self.wayland.access()
    CurFallback => self.fallback.access()
  }
}

///|
pub async fn LinuxDesktop::refresh(self : LinuxDesktop, force? : Bool = false) -> Unit {
  if !force && self.io.clock.ms() - self.looked < 2000.0 {
    return
  }
  self.refreshing
  .start(self.io, async fn() {
    let r = try Ok({
      let base = self.o.env.unwrap_or((self.io.os.env)())
      let env = match self.o.discover {
        Some(f) => f(base)
        None => desktop_environment(self.io, base)
      }
      self.native_.set_env(env)
      self.x11.set_env(env)
      self.wayland.set_env(env)
      self.fallback.set_env(env)
      if self.o.native_binary is Some(_) {
        self.native_.refresh(force~)
      }
      let next = if self.native_.available() {
        CurNative
      } else if env.get("XDG_SESSION_TYPE").map(t => t.to_lower()) == Some("wayland") ||
        env.truthy("WAYLAND_DISPLAY") is Some(_) {
        CurWayland
      } else {
        self.x11.refresh(force~)
        // CentOS's standard repositories do not provide both X11 commands. Its installed desktop's GStreamer and
        // XTest libraries can capture and control the same session without adding system repositories.
        if self.x11.access().reason == Some("linuxTools") && !self.tools.can_prepare(env) {
          CurFallback
        } else {
          CurX11
        }
      }
      if next != self.current {
        self.current = next
        (self.o.changed)()
      }
      match next {
        CurWayland => self.wayland.refresh(force~)
        CurFallback => self.fallback.refresh(force~)
        CurNative | CurX11 => ()
      }
    }) catch {
      e => Err(e)
    }
    self.looked = self.io.clock.ms()
    match r {
      Ok(_) => ()
      Err(e) => raise e
    }
  })
  .wait()
}

///|
pub async fn LinuxDesktop::open(self : LinuxDesktop, options : ViewOptions) -> ScreenView {
  self.refresh(force=true)
  match self.current {
    CurNative => self.native_.open(options)
    CurX11 => self.x11.open(options)
    CurWayland => self.wayland.open(options)
    CurFallback => self.fallback.open(options)
  }
}

///|
pub async fn LinuxDesktop::close(self : LinuxDesktop) -> Unit {
  self.native_.close()
  ignore(
    @effect.all([
      async fn() { self.x11.close() },
      async fn() { self.wayland.close() },
      async fn() { self.fallback.close() },
    ]),
  )
}

///|
pub fn LinuxDesktop::source(self : LinuxDesktop) -> ScreenSource {
  {
    ..ScreenSource::bare("desktop", DesktopKind, () => self.title(), () => self.size(), async fn(o) { self.open(o) }),
    access: Some(() => self.access()),
  }
}
