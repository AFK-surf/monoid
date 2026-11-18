//! Public transit control carries identities for this search/path only. Decode
//! limits apply before allocation; neither addresses nor a roster are included.
use crate::{identity::Binding, routing::{Frame, Message, Node, MAX_HOPS}};
use serde::{Deserialize, Serialize, de::{self, SeqAccess, Visitor}};
use std::fmt;

pub const MAX_CONTROL: usize = 4096;
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Control {
    pub frame: Frame,
    pub leaf: Option<[u8;32]>,
    pub attachment: Option<crate::leaf::Attachment>,
    #[serde(deserialize_with = "read_proofs")]
    pub proofs: Vec<Binding>,
}
fn read_proofs<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Vec<Binding>, D::Error> {
    struct Proofs;
    impl<'de> Visitor<'de> for Proofs {
        type Value = Vec<Binding>;
        fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result { f.write_str("at most nine path identities") }
        fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Self::Value, A::Error> {
            if seq.size_hint().is_some_and(|n| n > MAX_HOPS + 1) { return Err(de::Error::custom("too many path proofs")); }
            let mut out = Vec::new();
            while let Some(proof) = seq.next_element()? {
                if out.len() == MAX_HOPS + 1 { return Err(de::Error::custom("too many path proofs")); }
                out.push(proof);
            }
            Ok(out)
        }
    }
    d.deserialize_seq(Proofs)
}
impl Control {
    /// Build exactly the proofs named by the frame. A private directory is only
    /// queried for these keys, never serialized into a public control message.
    pub fn build(frame: Frame, receiver: Node, mut lookup: impl FnMut(&Node) -> Option<Binding>) -> Result<Self, &'static str> {
        let mut control = Self { frame, proofs: Vec::new(), leaf: None, attachment: None };
        let (nodes, _) = control.identities(receiver)?;
        for node in nodes {
            let proof = lookup(&node).ok_or("missing path identity")?;
            if proof.endpoint != node { return Err("path identity lookup mismatch"); }
            control.proofs.push(proof);
        }
        Ok(control)
    }
    pub fn encode(&self) -> Result<Vec<u8>, &'static str> {
        if self.proofs.len() > MAX_HOPS + 1 { return Err("too many path proofs"); }
        let bytes = postcard::to_allocvec(self).map_err(|_| "invalid path control")?;
        if bytes.len() > MAX_CONTROL { return Err("invalid path control length"); }
        Ok(bytes)
    }
    pub fn decode(bytes: &[u8]) -> Result<Self, &'static str> {
        if bytes.is_empty() || bytes.len() > MAX_CONTROL { return Err("invalid path control length"); }
        let (value, rest) = postcard::take_from_bytes(bytes).map_err(|_| "invalid path control")?;
        if !rest.is_empty() { return Err("trailing path control bytes"); }
        Ok(value)
    }
    /// Return the complete proof order and sender position. A discovery prefix
    /// appends its destination so that the last forwarder is checked as transit.
    /// It is not a claimed complete route: only Offer establishes one.
    pub fn identities(&self, receiver: Node) -> Result<(Vec<Node>, usize), &'static str> {
        match &self.frame.message {
            Message::Discover { path, target, .. } => {
                if path.is_empty() || path.len() > MAX_HOPS || path.contains(target) || path.contains(&receiver) {
                    return Err("invalid discovery prefix");
                }
                let mut identities = path.clone();
                identities.push(*target);
                Ok((identities, path.len() - 1))
            }
            Message::Offer { path, cursor, .. } | Message::Broken { path, cursor } => {
                let at = *cursor as usize;
                if path.len() < 2 || path.len() > MAX_HOPS + 1 { return Err("invalid reverse control path"); }
                if path.get(at) != Some(&receiver) || at + 1 >= path.len() {
                    return Err("invalid reverse control cursor");
                }
                Ok((path.clone(), at + 1))
            }
            Message::Data { .. } | Message::Probe { .. } => Err("data cannot allocate path identities"),
        }
    }
    pub fn verify(&self, receiver: Node, neighbor: Node, generations: &std::collections::BTreeMap<Node,u64>) -> Result<(), &'static str> {
        let (path, previous) = self.identities(receiver)?;
        crate::path_identity::verify(self.frame.scope, &path, &self.proofs, previous, neighbor, generations)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use iroh::SecretKey;
    fn discovery() -> (Control, Node) {
        let proofs: Vec<_> = (1..=3).map(|i| Binding::sign(&SecretKey::from([i;32]),[9;32],crate::policy::TransitPolicy::empty().digest(),1,i==2)).collect();
        let receiver = *SecretKey::from([4;32]).public().as_bytes();
        (Control { leaf: None, attachment: None, frame: Frame { scope:[9;32], message:Message::Discover { request:1, target:proofs[2].endpoint, path:proofs[..2].iter().map(|p|p.endpoint).collect() } }, proofs },receiver)
    }
    #[test]
    fn discovery_proves_destination_without_revealing_other_members() {
        let (control, receiver) = discovery();
        let bytes = postcard::to_allocvec(&control).unwrap();
        let decoded = Control::decode(&bytes).unwrap();
        decoded.verify(receiver,control.proofs[1].neighbor,&Default::default()).unwrap();
        assert!(decoded.verify(receiver,control.proofs[0].neighbor,&Default::default()).is_err());
        assert!(decoded.verify(control.proofs[0].endpoint,control.proofs[1].neighbor,&Default::default()).is_err());
        let mut missing = control.clone(); missing.proofs.pop();
        assert!(missing.verify(receiver,control.proofs[1].neighbor,&Default::default()).is_err());
        let mut trailing = bytes; trailing.push(0);
        assert!(Control::decode(&trailing).is_err());
    }
    #[test]
    fn encoding_requests_only_the_path_keys_and_requires_every_proof() {
        let (control, receiver) = discovery();
        let mut requested = Vec::new();
        let rebuilt = Control::build(control.frame.clone(), receiver, |node| {
            requested.push(*node);
            control.proofs.iter().find(|proof| proof.endpoint == *node).cloned()
        }).unwrap();
        assert_eq!(requested, control.proofs.iter().map(|proof| proof.endpoint).collect::<Vec<_>>());
        assert_eq!(rebuilt.encode().unwrap(), control.encode().unwrap());
        assert!(Control::build(control.frame.clone(),receiver, |_| None).is_err());
        let mut leaf = control.clone();
        leaf.proofs[1] = Binding::sign(&SecretKey::from([2;32]),[9;32],crate::policy::TransitPolicy::empty().digest(),1,false);
        assert!(leaf.verify(receiver,leaf.proofs[1].neighbor,&Default::default()).is_err(), "the last discovery prefix node is still a middle hop");
    }
    #[test]
    fn offer_cursor_and_resource_bounds_are_checked_before_admission() {
        let (mut control, _) = discovery();
        let path: Vec<_> = control.proofs.iter().map(|p|p.endpoint).collect();
        control.frame.message = Message::Offer { request:1, path:path.clone(), cursor:1 };
        control.verify(path[1],control.proofs[2].neighbor,&Default::default()).unwrap();
        assert!(control.verify(path[0],control.proofs[2].neighbor,&Default::default()).is_err());
        control.proofs = vec![control.proofs[0].clone();MAX_HOPS+2];
        assert!(Control::decode(&postcard::to_allocvec(&control).unwrap()).is_err());
        assert!(Control::decode(&vec![0;MAX_CONTROL+1]).is_err());
        control.frame.message = Message::Data { path, cursor:1, packet:vec![1] };
        assert!(control.identities([0;32]).is_err());
    }
}
