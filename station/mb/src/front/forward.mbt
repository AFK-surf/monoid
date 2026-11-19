// The station's entrances in MoonBit (station/AGENTS.md: the entrance moves to station/mb's program, what it does not
// answer itself carried to Node). So far: a listening socket served by carrying each connection, byte for byte both
// ways, to a port of this machine (`forward`), as the Windows launcher's entrance does for Node (native/launcher's
// proxy.rs): the shell carries its bytes (`tcp.pipe`), none of them through this program.

///|
/// A socket of the shell's (`tcp.*`).
struct Conn {
  host : @host.Host
  id : Json
}

///|
async fn Conn::close(self : Conn) -> Unit {
  self.host.tcp_close(self.id)
}

///|
/// A listening socket: its id at the shell and its port.
pub struct Listening {
  id : Json
  port : Int
}

///|
/// A socket to serve: `fd` one handed down to this process (a launcher's), else one bound here on 127.0.0.1 at `port`
/// (0: any free one).
pub async fn listen(host : @host.Host, fd? : Int, port? : Int = 0) -> Listening {
  let l = match fd {
    Some(fd) => host.tcp_listen_fd(fd)
    None => host.tcp_listen_local(port)
  }
  { id: l.id, port: l.port }
}

///|
/// Each connection to `listening` carried to 127.0.0.1:`to`, both ways, each half ended as its side ends it; one whose
/// other end cannot be reached is closed. Runs till the listening socket fails.
pub async fn forward(host : @host.Host, listening : Listening, to : Int) -> Unit {
  while true {
    let client = host.accept(listening.id)
    ignore(
      host.rt.fork_daemon("forward", on_error=e => @host.note("forward: a connection failed: \{message(e)}"), () => {
        let opened = try { Ok(host.tcp_open(to)) } catch { e => Err(e) }
        guard opened is Ok(server) else {
          @host.note("forward: 127.0.0.1:\{to} not reached: \{match opened { Err(e) => message(e); _ => "no socket" }}")
          client.socket.destroy()
          return
        }
        // (carried by the shell itself, both ways: nothing of it passes through this program)
        host.tcp_pipe(client.id, server.id)
      }),
    )
  }
}

///|
fn message(e : Error) -> String {
  match e {
    @wire.ShellError(m) => m
    e => e.to_string()
  }
}
