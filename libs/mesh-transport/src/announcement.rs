//! Signed address records shared with admitted scope members, never an admission
//! grant on their own. Revisions are persisted by the owner before publication.
use crate::{identity::Binding, routing::Scope};
use iroh::{EndpointAddr, EndpointId, SecretKey, TransportAddr};
use serde::{Deserialize, Serialize};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
const DOMAIN: &str = "mesh-announcement/v1\0";
const LIMIT: usize = 16 * 1024;
const MAX_SAFE: u64 = 9_007_199_254_740_991;
pub const MAX_UNDERLAY_ADDRS: usize = 8;

/// Whether `ip` falls in RFC 2544 benchmarking space (`198.18.0.0/15`, including IPv4-mapped IPv6),
/// which local proxy TUN adapters commonly assign for fake-IP routing and which collides across hosts.
pub fn is_benchmarking_ip(ip: IpAddr) -> bool {
    match ip.to_canonical() {
        IpAddr::V4(v4) => {
            let [a, b, _, _] = v4.octets();
            a == 198 && (b & 0xfe) == 18
        }
        IpAddr::V6(_) => false,
    }
}

fn ipv4_tier(ip: Ipv4Addr) -> u8 {
    let [a, b, _, _] = ip.octets();
    if ip.is_link_local() || ip.is_loopback() || ip.is_unspecified() {
        return 5;
    }
    if ip.is_private() || (a == 100 && (b & 0xc0) == 64) {
        return 3;
    }
    if ip.is_multicast() || ip.is_broadcast() || ip.is_documentation() || a == 0 || (a == 198 && (b & 0xfe) == 18) {
        return 4;
    }
    1
}

fn ipv6_tier(ip: Ipv6Addr) -> u8 {
    let s = ip.segments();
    if (s[0] & 0xffc0) == 0xfe80 || ip.is_loopback() || ip.is_unspecified() {
        return 5;
    }
    if (s[0] & 0xfe00) == 0xfc00 || ip.is_multicast() {
        return 4;
    }
    2
}

fn underlay_tier(addr: &TransportAddr) -> u8 {
    match addr {
        TransportAddr::Relay(_) => 0,
        TransportAddr::Ip(sock) => match sock.ip() {
            IpAddr::V4(ip) => ipv4_tier(ip),
            IpAddr::V6(ip) => ipv6_tier(ip),
        },
        _ => 5,
    }
}

fn underlay_key(addr: &TransportAddr) -> String {
    match addr {
        TransportAddr::Relay(url) => url.to_string(),
        TransportAddr::Ip(sock) => sock.to_string(),
        _ => String::new(),
    }
}

/// Bounds a local endpoint's underlay addresses to `MAX_UNDERLAY_ADDRS`, stripping RFC 2544 benchmarking
/// IPs (`198.18.0.0/15`), while preserving smaller clean sets as-is and leaving non-underlay entries
/// untouched for validation to reject.
pub fn bounded_address(address: EndpointAddr) -> EndpointAddr {
    if address.addrs.iter().any(|a| !matches!(a, TransportAddr::Ip(_) | TransportAddr::Relay(_))) {
        return address;
    }
    let filtered: Vec<TransportAddr> = address
        .addrs
        .into_iter()
        .filter(|a| !matches!(a, TransportAddr::Ip(sock) if is_benchmarking_ip(sock.ip())))
        .collect();
    if filtered.len() <= MAX_UNDERLAY_ADDRS {
        return EndpointAddr::new(address.id).with_addrs(filtered);
    }
    let mut ranked: Vec<(u8, String, TransportAddr)> = filtered
        .into_iter()
        .map(|a| (underlay_tier(&a), underlay_key(&a), a))
        .collect();
    ranked.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
    ranked.truncate(MAX_UNDERLAY_ADDRS);
    EndpointAddr::new(address.id).with_addrs(ranked.into_iter().map(|(_, _, a)| a))
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Descriptor { pub binding: Binding, pub address: EndpointAddr }
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Announcement {
    pub scope: String,
    pub node: EndpointId,
    pub revision: u64,
    pub descriptor: Descriptor,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SignedAnnouncement { pub body: String, pub signature: String }
pub fn scope_text(scope: Scope) -> String { scope.iter().map(|b| format!("{b:02x}")).collect() }
impl SignedAnnouncement {
    pub fn sign(key: &SecretKey, scope: Scope, revision: u64, descriptor: Descriptor) -> Result<Self, String> {
        let value = Announcement { scope: scope_text(scope), node: key.public(), revision, descriptor };
        let body = serde_json::to_string(&value).map_err(|e| e.to_string())?;
        let signature = key.sign(format!("{DOMAIN}{body}").as_bytes()).to_string();
        let signed = Self { body, signature };
        signed.verify(scope, key.public(), 0)?;
        Ok(signed)
    }
    pub fn verify(&self, scope: Scope, node: EndpointId, minimum_generation: u64) -> Result<Announcement, String> {
        if self.body.len() > LIMIT || self.signature.len() != 128 || !self.signature.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err("invalid mesh announcement size or signature".into());
        }
        let mut bytes = [0; 64];
        for (i, byte) in bytes.iter_mut().enumerate() {
            *byte = u8::from_str_radix(&self.signature[i * 2..i * 2 + 2], 16).map_err(|_| "invalid signature")?;
        }
        node.verify(format!("{DOMAIN}{}", self.body).as_bytes(), &iroh_base::Signature::from_bytes(&bytes)).map_err(|_| "invalid announcement signature")?;
        let value: Announcement = serde_json::from_str(&self.body).map_err(|e| e.to_string())?;
        if value.scope != scope_text(scope) || value.node != node || value.revision == 0 || value.revision > MAX_SAFE {
            return Err("announcement scope, identity or revision mismatch".into());
        }
        let b = &value.descriptor.binding;
        b.verify(scope, minimum_generation)?;
        if b.endpoint != *node.as_bytes() || b.neighbor != *value.descriptor.address.id.as_bytes() || b.generation > MAX_SAFE {
            return Err("announcement binding mismatch".into());
        }
        if value.descriptor.address.addrs.len() > MAX_UNDERLAY_ADDRS || value.descriptor.address.addrs.iter().any(|a| !matches!(a, TransportAddr::Ip(_) | TransportAddr::Relay(_))) {
            return Err("announcement must name bounded underlay addresses".into());
        }
        Ok(value)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::neighbor_secret;
    #[test]
    fn verifies_the_node_signed_wire_fixture() {
        let signed: SignedAnnouncement = serde_json::from_str(include_str!("../tests/fixtures/announcement.json")).unwrap();
        let value = signed.verify([84; 32], SecretKey::from([83; 32]).public(), 3).unwrap();
        assert_eq!(value.revision, 7);
        assert_eq!(value.descriptor.address.addrs.len(), 1);
    }
    #[test]
    fn addresses_and_revisions_are_bound_to_the_scope_owner() {
        let key = SecretKey::from([83; 32]);
        let scope = [84; 32];
        let descriptor = Descriptor { binding: Binding::sign(&key, scope, crate::policy::TransitPolicy::empty().digest(), 3, true), address: EndpointAddr::new(neighbor_secret(&key, scope, crate::policy::TransitPolicy::empty().digest()).public()).with_ip_addr("127.0.0.1:1234".parse().unwrap()) };
        let record = SignedAnnouncement::sign(&key, scope, 7, descriptor.clone()).unwrap();
        assert_eq!(record.verify(scope, key.public(), 3).unwrap().revision, 7);
        assert!(record.verify(scope, key.public(), 4).is_err());
        assert!(record.verify([85; 32], key.public(), 0).is_err());
        assert!(record.verify(scope, SecretKey::from([86; 32]).public(), 0).is_err());
        let mut tampered = record.clone(); tampered.body = tampered.body.replace("1234", "1235");
        assert!(tampered.verify(scope, key.public(), 0).is_err());
        assert!(SignedAnnouncement::sign(&key, scope, 0, descriptor.clone()).is_err());
        assert!(SignedAnnouncement::sign(&key, scope, MAX_SAFE + 1, descriptor).is_err());
    }
    #[test]
    fn bounded_address_preserves_small_sets_unchanged() {
        let id = SecretKey::from([87; 32]).public();
        let addr = EndpointAddr::new(id).with_addrs([
            TransportAddr::Ip("127.0.0.1:1234".parse().unwrap()),
            TransportAddr::Ip("192.168.1.10:1234".parse().unwrap()),
            TransportAddr::Relay("https://relay-a.example".parse().unwrap()),
        ]);
        assert_eq!(bounded_address(addr.clone()), addr);
        let exact_eight = EndpointAddr::new(id).with_addrs((0..8).map(|i| {
            TransportAddr::Ip(format!("192.168.1.{}:1234", i + 1).parse().unwrap())
        }));
        assert_eq!(bounded_address(exact_eight.clone()), exact_eight);
    }
    #[test]
    fn bounded_address_prioritizes_relays_and_public_ips_above_limit() {
        let key = SecretKey::from([88; 32]);
        let scope = [89; 32];
        let neighbor = neighbor_secret(&key, scope, crate::policy::TransitPolicy::empty().digest()).public();
        let relay_a = TransportAddr::Relay("https://relay-a.example".parse().unwrap());
        let relay_b = TransportAddr::Relay("https://relay-b.example".parse().unwrap());
        let pub_v4_a = TransportAddr::Ip("1.2.3.4:4000".parse().unwrap());
        let pub_v4_b = TransportAddr::Ip("8.8.8.8:4000".parse().unwrap());
        let pub_v6_a = TransportAddr::Ip("[2001:4860:4860::8888]:4000".parse().unwrap());
        let pub_v6_b = TransportAddr::Ip("[2606:4700:4700::1111]:4000".parse().unwrap());
        let tailscale = TransportAddr::Ip("100.64.0.1:4000".parse().unwrap());
        let docker = TransportAddr::Ip("172.17.0.1:4000".parse().unwrap());
        let lan = TransportAddr::Ip("192.168.1.10:4000".parse().unwrap());
        let ula = TransportAddr::Ip("[fd00::1]:4000".parse().unwrap());
        let ll_v4 = TransportAddr::Ip("169.254.1.1:4000".parse().unwrap());
        let ll_v6 = TransportAddr::Ip("[fe80::1]:4000".parse().unwrap());
        let lo_v4 = TransportAddr::Ip("127.0.0.1:4000".parse().unwrap());
        let lo_v6 = TransportAddr::Ip("[::1]:4000".parse().unwrap());
        let raw = EndpointAddr::new(neighbor).with_addrs([
            lo_v6, lo_v4, ll_v6, ll_v4, ula, lan.clone(), docker.clone(), tailscale.clone(),
            pub_v6_b.clone(), pub_v6_a.clone(), pub_v4_b.clone(), pub_v4_a.clone(),
            relay_b.clone(), relay_a.clone(),
        ]);
        assert_eq!(raw.addrs.len(), 14);
        let bounded = bounded_address(raw);
        assert_eq!(bounded.addrs.len(), MAX_UNDERLAY_ADDRS);
        for expected in [&relay_a, &relay_b, &pub_v4_a, &pub_v4_b, &pub_v6_a, &pub_v6_b, &tailscale, &docker] {
            assert!(bounded.addrs.contains(expected), "missing expected address {expected:?}");
        }
        assert!(!bounded.addrs.contains(&lan));
        let descriptor = Descriptor {
            binding: Binding::sign(&key, scope, crate::policy::TransitPolicy::empty().digest(), 1, true),
            address: bounded,
        };
        let signed = SignedAnnouncement::sign(&key, scope, 1, descriptor).unwrap();
        assert_eq!(signed.verify(scope, key.public(), 1).unwrap().descriptor.address.addrs.len(), MAX_UNDERLAY_ADDRS);
    }
    #[test]
    fn bounded_address_does_not_strip_custom_transport() {
        let key = SecretKey::from([90; 32]);
        let scope = [91; 32];
        let neighbor = neighbor_secret(&key, scope, crate::policy::TransitPolicy::empty().digest()).public();
        let custom = TransportAddr::Custom(crate::transport::address(scope, crate::policy::TransitPolicy::empty().digest(), [1; 32]));
        let mut addrs: Vec<TransportAddr> = (0..9)
            .map(|i| TransportAddr::Ip(format!("192.168.1.{}:4000", i + 1).parse().unwrap()))
            .collect();
        addrs.push(custom.clone());
        let raw = EndpointAddr::new(neighbor).with_addrs(addrs);
        let kept = bounded_address(raw.clone());
        assert_eq!(kept, raw);
        assert!(kept.addrs.contains(&custom));
        let descriptor = Descriptor {
            binding: Binding::sign(&key, scope, crate::policy::TransitPolicy::empty().digest(), 1, true),
            address: kept,
        };
        assert!(SignedAnnouncement::sign(&key, scope, 1, descriptor).is_err());
    }
    #[test]
    fn benchmarking_ip_predicate_matches_rfc2544_and_mapped_v6_only() {
        for blocked in [
            "198.18.0.0",
            "198.18.0.1",
            "198.19.255.255",
            "::ffff:198.18.0.0",
            "::ffff:198.19.255.255",
        ] {
            assert!(is_benchmarking_ip(blocked.parse().unwrap()), "expected blocked: {blocked}");
        }
        for allowed in [
            "198.17.255.255",
            "198.20.0.0",
            "192.168.1.106",
            "10.0.0.1",
            "172.16.0.1",
            "100.64.0.1",
            "100.127.255.254",
            "127.0.0.1",
            "169.254.1.1",
            "1.1.1.1",
            "::1",
            "::ffff:192.168.1.100",
            "fe80::1",
            "fd00::1",
            "2001:4860:4860::8888",
        ] {
            assert!(!is_benchmarking_ip(allowed.parse().unwrap()), "expected allowed: {allowed}");
        }
    }
    #[test]
    fn bounded_address_strips_benchmarking_ips_in_small_and_large_sets() {
        let id = SecretKey::from([92; 32]).public();
        let lan = TransportAddr::Ip("192.168.1.100:58339".parse().unwrap());
        let tailscale = TransportAddr::Ip("100.64.0.2:58339".parse().unwrap());
        let relay = TransportAddr::Relay("https://relay-a.example".parse().unwrap());
        let fake_v4 = TransportAddr::Ip("198.18.0.0:58339".parse().unwrap());
        let fake_v6 = TransportAddr::Ip("[::ffff:198.19.0.1]:58339".parse().unwrap());

        let small = EndpointAddr::new(id).with_addrs([lan.clone(), fake_v4.clone(), fake_v6.clone(), relay.clone()]);
        let small_out = bounded_address(small);
        assert!(small_out.addrs.contains(&lan));
        assert!(small_out.addrs.contains(&relay));
        assert!(!small_out.addrs.contains(&fake_v4));
        assert!(!small_out.addrs.contains(&fake_v6));

        let mut large_addrs: Vec<TransportAddr> = (1..=7)
            .map(|i| TransportAddr::Ip(format!("192.168.1.{i}:58339").parse().unwrap()))
            .collect();
        large_addrs.push(tailscale.clone());
        large_addrs.push(fake_v4.clone());
        large_addrs.push(fake_v6.clone());
        let large_out = bounded_address(EndpointAddr::new(id).with_addrs(large_addrs));
        assert_eq!(large_out.addrs.len(), MAX_UNDERLAY_ADDRS);
        assert!(large_out.addrs.contains(&tailscale));
        assert!(!large_out.addrs.contains(&fake_v4));
        assert!(!large_out.addrs.contains(&fake_v6));
        assert_eq!(ipv4_tier("198.18.0.0".parse().unwrap()), 4);
    }
}
