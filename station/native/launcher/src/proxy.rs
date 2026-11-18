//! An entrance the launcher keeps for a port it cannot hand to Node (Windows: Node cannot listen on a socket handed
//! down): the launcher holds the listening socket for good and carries each connection to the Node that serves it now.
//!
//! Which Node that is the lifecycle says (`serve`): the one that said it serves on that port, which a Node says only once
//! it has taken over (its agents' door opens after the previous one has handed its sessions over), so a connection never
//! reaches a Node that has not. A connection that comes while none serves (a handover's moment between the old Node
//! leaving and the new one taking over, a restart) waits for one, at most `wait`, then is closed. One already carried
//! stays with the Node it went to until either end closes it: nothing is moved or replayed.
//!
//! On Windows a launcher hands its listening sockets to the release's launcher that takes its place (run_windows.rs
//! `renew`): `hand` makes a copy for that process (WSADuplicateSocket), `taken` opens it there, and `stop` closes this
//! one's, which then takes no more connections; those it carries already go on to their end (`carrying`).

use std::io::{Read, Write};
use std::mem::ManuallyDrop;
use std::net::{Shutdown, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use crate::log;

/// Where connections go now: the port of the Node serving, on 127.0.0.1; none while none does.
type Target = Arc<(Mutex<Option<u16>>, Condvar)>;

pub struct Entrance {
    target: Target,
    /// The listening socket's own handle, for `hand` and `stop` (Windows).
    #[cfg_attr(unix, allow(dead_code))]
    socket: u64,
    /// Closed (`stop`): the thread taking connections ends as its accept fails, and lets the socket be.
    stopped: Arc<AtomicBool>,
    /// The connections carried now, to their end.
    carrying: Arc<AtomicUsize>,
}

impl Entrance {
    /// Carries what comes to `listener` (`name` for what is said of it), from now on.
    pub fn open(name: &'static str, listener: TcpListener, wait: Duration) -> Entrance {
        let target: Target = Arc::new((Mutex::new(None), Condvar::new()));
        let (stopped, carrying) = (Arc::new(AtomicBool::new(false)), Arc::new(AtomicUsize::new(0)));
        #[cfg(windows)]
        let socket = std::os::windows::io::AsRawSocket::as_raw_socket(&listener) as u64;
        #[cfg(unix)]
        let socket = std::os::fd::AsRawFd::as_raw_fd(&listener) as u64;
        // (closed by `stop` alone, where it is closed at all: the thread never closes it under a copy handed on)
        let listener = ManuallyDrop::new(listener);
        let (theirs, ended, counted) = (target.clone(), stopped.clone(), carrying.clone());
        std::thread::spawn(move || {
            for client in listener.incoming() {
                match client {
                    Ok(client) => {
                        let target = theirs.clone();
                        let counted = counted.clone();
                        counted.fetch_add(1, Ordering::SeqCst);
                        std::thread::spawn(move || {
                            carry(name, client, &target, wait);
                            counted.fetch_sub(1, Ordering::SeqCst);
                        });
                    }
                    Err(_) if ended.load(Ordering::SeqCst) => return,
                    Err(error) => log::warn(&format!("{name}: a connection not taken: {error}")),
                }
            }
        });
        Entrance { target, socket, stopped, carrying }
    }

    /// How many connections it carries now.
    pub fn carrying(&self) -> usize {
        self.carrying.load(Ordering::SeqCst)
    }

    /// A copy of the listening socket for process `pid` (the launcher taking this one's place), as `taken` opens it
    /// there: WSAPROTOCOL_INFOW's bytes.
    #[cfg(windows)]
    pub fn hand(&self, pid: u32) -> std::io::Result<Vec<u8>> {
        use windows_sys::Win32::Networking::WinSock::{WSADuplicateSocketW, WSAGetLastError, WSAPROTOCOL_INFOW};
        // SAFETY: a socket of ours, the info written whole into a value of its own.
        unsafe {
            let mut info: WSAPROTOCOL_INFOW = std::mem::zeroed();
            if WSADuplicateSocketW(self.socket as usize, pid, &mut info) != 0 {
                return Err(std::io::Error::from_raw_os_error(WSAGetLastError()));
            }
            Ok(std::slice::from_raw_parts((&info as *const WSAPROTOCOL_INFOW).cast::<u8>(), size_of::<WSAPROTOCOL_INFOW>()).to_vec())
        }
    }

    /// The listening socket a launcher before this one handed (`hand`), opened here and carried as `open` does.
    #[cfg(windows)]
    pub fn taken(name: &'static str, info: &[u8], wait: Duration) -> std::io::Result<Entrance> {
        use std::os::windows::io::FromRawSocket;
        use windows_sys::Win32::Networking::WinSock::{
            FROM_PROTOCOL_INFO, INVALID_SOCKET, WSA_FLAG_NO_HANDLE_INHERIT, WSA_FLAG_OVERLAPPED, WSADATA, WSAGetLastError, WSAPROTOCOL_INFOW,
            WSASocketW, WSAStartup,
        };
        if info.len() != size_of::<WSAPROTOCOL_INFOW>() {
            return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, format!("{name}: a socket's info of {} bytes", info.len())));
        }
        // SAFETY: the info copied into a value of its own type; Winsock started (counted) before the socket is made.
        unsafe {
            let mut data: WSADATA = std::mem::zeroed();
            WSAStartup(0x0202, &mut data);
            let mut given: WSAPROTOCOL_INFOW = std::mem::zeroed();
            std::ptr::copy_nonoverlapping(info.as_ptr(), (&mut given as *mut WSAPROTOCOL_INFOW).cast::<u8>(), info.len());
            let socket = WSASocketW(FROM_PROTOCOL_INFO, FROM_PROTOCOL_INFO, FROM_PROTOCOL_INFO, &given, 0, WSA_FLAG_OVERLAPPED | WSA_FLAG_NO_HANDLE_INHERIT);
            if socket == INVALID_SOCKET {
                return Err(std::io::Error::from_raw_os_error(WSAGetLastError()));
            }
            Ok(Entrance::open(name, TcpListener::from_raw_socket(socket as u64), wait))
        }
    }

    /// Takes no more connections: its listening socket closed here (a copy handed on goes on listening).
    #[cfg(windows)]
    pub fn stop(&self) {
        use windows_sys::Win32::Networking::WinSock::closesocket;
        if !self.stopped.swap(true, Ordering::SeqCst) {
            // SAFETY: our own socket, closed once (the thread taking connections leaves it to this).
            unsafe { closesocket(self.socket as usize) };
        }
    }

    /// New connections go to `port` (a Node's, on 127.0.0.1) from now on; none: they wait.
    pub fn serve(&self, port: Option<u16>) {
        let (lock, changed) = &*self.target;
        *lock.lock().unwrap_or_else(|e| e.into_inner()) = port;
        changed.notify_all();
    }
}

/// One connection to the Node serving (waiting, at most `wait`, for one to), both ways until either end is done.
fn carry(name: &str, client: TcpStream, target: &Target, wait: Duration) {
    let port = {
        let (lock, changed) = &**target;
        let until = Instant::now() + wait;
        let mut port = lock.lock().unwrap_or_else(|e| e.into_inner());
        while port.is_none() {
            let left = until.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break;
            }
            port = changed.wait_timeout(port, left).unwrap_or_else(|e| e.into_inner()).0;
        }
        *port
    };
    let Some(port) = port else {
        log::warn(&format!("{name}: no station serving within {} s; a connection closed", wait.as_secs_f32()));
        return;
    };
    let node = match TcpStream::connect(("127.0.0.1", port)) {
        Ok(node) => node,
        Err(error) => {
            log::warn(&format!("{name}: the station on port {port} not reached: {error}"));
            return;
        }
    };
    let _ = client.set_nodelay(true);
    let _ = node.set_nodelay(true);
    let (Ok(client_out), Ok(node_out)) = (client.try_clone(), node.try_clone()) else { return };
    let up = std::thread::spawn(move || pipe(client, node_out));
    pipe(node, client_out);
    let _ = up.join();
}

/// What `from` sends, to `to`, until `from` is done; then `to` is told nothing more comes.
fn pipe(mut from: TcpStream, mut to: TcpStream) {
    let mut buf = [0u8; 16 * 1024];
    loop {
        match from.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                if to.write_all(&buf[..n]).is_err() {
                    break;
                }
            }
        }
    }
    let _ = to.shutdown(Shutdown::Write);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{self, BufRead};

    /// A Node of the test's: answers each line with its name and the line.
    fn node(name: &'static str) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for conn in listener.incoming().flatten() {
                std::thread::spawn(move || {
                    let mut out = conn.try_clone().unwrap();
                    for line in io::BufReader::new(conn).lines().map_while(Result::ok) {
                        if writeln!(out, "{name}:{line}").is_err() {
                            return;
                        }
                    }
                });
            }
        });
        port
    }

    fn entrance(wait: Duration) -> (Entrance, u16) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        (Entrance::open("test", listener, wait), port)
    }

    /// A line through the entrance on `conn`, and what came back.
    fn ask(conn: &mut io::BufReader<TcpStream>, line: &str) -> String {
        writeln!(conn.get_mut(), "{line}").unwrap();
        let mut said = String::new();
        conn.read_line(&mut said).unwrap();
        said.trim_end().to_string()
    }

    fn connect(port: u16) -> io::BufReader<TcpStream> {
        let conn = TcpStream::connect(("127.0.0.1", port)).unwrap();
        conn.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        io::BufReader::new(conn)
    }

    #[test]
    fn a_connection_goes_to_the_node_serving_and_stays_with_it_when_another_takes_over() {
        let (entrance, port) = entrance(Duration::from_secs(10));
        entrance.serve(Some(node("old")));
        let mut first = connect(port);
        assert_eq!(ask(&mut first, "a"), "old:a");
        entrance.serve(Some(node("new")));
        // Carried before: still the old one's (nothing moved); new ones the new one's.
        assert_eq!(ask(&mut first, "b"), "old:b");
        let mut second = connect(port);
        assert_eq!(ask(&mut second, "c"), "new:c");
    }

    #[test]
    fn a_connection_while_none_serves_waits_for_the_one_that_takes_over() {
        let (entrance, port) = entrance(Duration::from_secs(10));
        let mut waiting = connect(port);
        writeln!(waiting.get_mut(), "early").unwrap();
        std::thread::sleep(Duration::from_millis(300));
        entrance.serve(Some(node("next")));
        let mut said = String::new();
        waiting.read_line(&mut said).unwrap();
        assert_eq!(said.trim_end(), "next:early");
    }

    #[test]
    fn a_connection_none_takes_up_in_time_is_closed() {
        let (_entrance, port) = entrance(Duration::from_millis(200));
        let mut conn = connect(port);
        let mut said = String::new();
        // Closed by the entrance: the end of what comes, nothing said.
        assert_eq!(conn.read_line(&mut said).unwrap(), 0);
    }
}
