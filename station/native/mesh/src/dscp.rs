//! The DSCP every iroh packet of the station is marked with (`STILLFAIL_MESH_DSCP`, docs/station-lan-firewall.md), for
//! a router that sends packets so marked their own way (a Monoid Machine's edge lets them past its proxy).

/// Marks every iroh socket of this process with `dscp` (`Options::dscp`) before an endpoint binds: its datagrams
/// (noq-udp, vendor/README.md) and its relays' connections (iroh's `set_relay_dscp`), the main endpoint's and the
/// keepers' (keep.rs) alike, as it is a property of the machine's network. None leaves them as they are. A value
/// outside 1..=63, or one on a system where it cannot be set, fails the bind: never a station silently unmarked.
pub(crate) fn apply(dscp: Option<u32>) -> Result<(), String> {
    let Some(dscp) = dscp else { return Ok(()) };
    let dscp = u8::try_from(dscp)
        .ok()
        .filter(|d| (1..=63).contains(d))
        .ok_or_else(|| format!("the DSCP to mark the mesh's packets with must be 1 to 63, not {dscp}"))?;
    if !cfg!(any(target_os = "linux", target_os = "android", target_os = "macos")) {
        return Err(format!("the mesh's packets cannot be marked with a DSCP ({dscp}) on this system"));
    }
    noq_udp::set_dscp(dscp);
    iroh::set_relay_dscp(dscp);
    Ok(())
}

#[cfg(all(test, any(target_os = "linux", target_os = "macos")))]
mod tests {
    use std::{
        mem,
        net::{IpAddr, Ipv4Addr, Ipv6Addr, UdpSocket},
        os::fd::AsRawFd,
        time::Duration,
    };

    use noq_udp::{EcnCodepoint, Transmit, UdpSocketState};

    use super::apply;

    /// A socket that is told the TOS byte (IPv4) or traffic class (IPv6) of each datagram it receives, whole.
    fn receiver(ip: IpAddr) -> UdpSocket {
        let socket = UdpSocket::bind((ip, 0)).unwrap(); // 127.0.0.1 or ::1
        // What fails the test, not one that waits: the datagram is on loopback before it is read.
        socket.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let on: libc::c_int = 1;
        let (level, name) = if ip.is_ipv4() {
            (libc::IPPROTO_IP, libc::IP_RECVTOS)
        } else {
            (libc::IPPROTO_IPV6, libc::IPV6_RECVTCLASS)
        };
        // SAFETY: one initialized c_int, its size said.
        let rc = unsafe {
            libc::setsockopt(socket.as_raw_fd(), level, name, (&on as *const libc::c_int).cast(), mem::size_of_val(&on) as libc::socklen_t)
        };
        assert_eq!(rc, 0, "{}", std::io::Error::last_os_error());
        socket
    }

    /// The whole TOS byte / traffic class the next datagram on `socket` came with.
    fn received_byte(socket: &UdpSocket) -> u8 {
        let mut buf = [0u8; 64];
        let mut ctrl = [0u64; 32];
        let mut iov = libc::iovec { iov_base: buf.as_mut_ptr().cast(), iov_len: buf.len() };
        // SAFETY: a zeroed msghdr is a valid empty one; it points at buffers that outlive the call.
        let mut hdr: libc::msghdr = unsafe { mem::zeroed() };
        hdr.msg_iov = &mut iov;
        hdr.msg_iovlen = 1;
        hdr.msg_control = ctrl.as_mut_ptr().cast();
        hdr.msg_controllen = mem::size_of_val(&ctrl) as _;
        // SAFETY: as above.
        let n = unsafe { libc::recvmsg(socket.as_raw_fd(), &mut hdr, 0) };
        assert!(n >= 0, "{}", std::io::Error::last_os_error());
        // SAFETY: walking the control messages the kernel wrote into `ctrl`, as CMSG_* say.
        unsafe {
            let mut cmsg = libc::CMSG_FIRSTHDR(&hdr);
            while !cmsg.is_null() {
                let data = libc::CMSG_DATA(cmsg);
                match ((*cmsg).cmsg_level, (*cmsg).cmsg_type) {
                    (libc::IPPROTO_IP, libc::IP_TOS) | (libc::IPPROTO_IP, libc::IP_RECVTOS) => return *data,
                    (libc::IPPROTO_IPV6, libc::IPV6_TCLASS) => return (data as *const libc::c_int).read_unaligned() as u8,
                    _ => {}
                }
                cmsg = libc::CMSG_NXTHDR(&hdr, cmsg);
            }
        }
        panic!("the datagram came with no TOS byte")
    }

    /// The byte a datagram sent by noq-udp with `dscp` (as `noq_udp::set_dscp` takes it) and ECT(0) arrives with.
    fn sent_with(ip: IpAddr, dscp: u8) -> u8 {
        let to = receiver(ip);
        let from = UdpSocket::bind((ip, 0)).unwrap(); // 127.0.0.1 or ::1
        let state = UdpSocketState::new((&from).into()).unwrap();
        let transmit = Transmit {
            destination: to.local_addr().unwrap(),
            ecn: Some(EcnCodepoint::Ect0),
            contents: b"marked?",
            segment_size: None,
            src_ip: None,
        };
        state.try_send_with_dscp((&from).into(), &transmit, dscp).unwrap();
        received_byte(&to)
    }

    /// The station's datagrams carry the DSCP above their ECN bits, the whole byte as it arrives (the cmsg each send
    /// carries is what sets it on Linux): IPv4 and IPv6.
    #[test]
    fn datagrams_arrive_marked_above_their_ecn() {
        for ip in [IpAddr::V4(Ipv4Addr::LOCALHOST), IpAddr::V6(Ipv6Addr::LOCALHOST)] {
            assert_eq!(sent_with(ip, 43), 43 << 2 | 0b10, "{ip}");
        }
    }

    /// With no DSCP the byte is the ECN bits alone, as noq-udp sent it before.
    #[test]
    fn unmarked_datagrams_carry_only_their_ecn() {
        for ip in [IpAddr::V4(Ipv4Addr::LOCALHOST), IpAddr::V6(Ipv6Addr::LOCALHOST)] {
            assert_eq!(sent_with(ip, 0), 0b10, "{ip}");
        }
    }

    /// A value outside 1..=63 is refused, before anything is marked.
    #[test]
    fn a_dscp_out_of_range_is_refused() {
        for bad in [0, 64, 255, 256, u32::MAX] {
            let err = apply(Some(bad)).unwrap_err();
            assert!(err.contains("1 to 63") && err.contains(&bad.to_string()), "{bad}: {err}");
        }
        assert_eq!(apply(None), Ok(()));
    }
}
