//! Per-scope public transit admission. Direct neighbors are supplied by the
//! authenticated link layer. Other identities arrive only in bounded controls.
//! This module grants transport use, never workspace or application access.
use crate::{identity::Binding, path_control::Control, path_identity::Active, routing::{Frame, Message, Node, Scope, MAX_NODES}};
use std::collections::BTreeMap;

#[derive(Clone)]
pub struct Admission {
    own: Binding,
    direct: BTreeMap<Node, Binding>,
    active: Active,
}
impl Admission {
    pub fn new(own: Binding) -> Result<Self, &'static str> {
        own.verify(own.scope, 1)?;
        if !own.transit { return Err("public relay must allow transit"); }
        let scope = own.scope;
        Ok(Self { own, direct: BTreeMap::new(), active: Active::new(scope) })
    }
    pub fn scope(&self) -> Scope { self.own.scope }
    pub fn node(&self) -> Node { self.own.endpoint }
    /// Membership of this map proves only an authenticated adjacent transport.
    /// Its replacement is atomic and must follow the operator's relay policy.
    pub fn neighbors(&mut self, proofs: Vec<Binding>) -> Result<(), &'static str> {
        if proofs.len() > 32 { return Err("public neighbor capacity"); }
        let mut next = BTreeMap::new();
        let mut keys = std::collections::BTreeSet::from([self.own.neighbor]);
        for proof in proofs {
            proof.verify(self.scope(),1)?;
            if proof.policy != self.own.policy { return Err("public neighbor has another policy lane"); }
            if proof.endpoint == self.node() || !keys.insert(proof.neighbor) || next.insert(proof.endpoint,proof).is_some() {
                return Err("duplicate public neighbor identity");
            }
        }
        if self.active.proofs().filter(|p| !next.contains_key(&p.endpoint) && p.endpoint != self.node()).count() + next.len() + 1 > MAX_NODES {
            return Err("public identity capacity");
        }
        self.direct = next;
        Ok(())
    }
    pub fn roles(&self) -> BTreeMap<Node, bool> {
        let mut roles: BTreeMap<_,_> = self.active.proofs().map(|p|(p.endpoint,p.transit)).collect();
        roles.extend(self.direct.values().map(|p|(p.endpoint,p.transit)));
        roles.insert(self.node(),true);
        roles
    }
    fn proof(&self, node: &Node) -> Option<Binding> {
        if *node == self.node() { return Some(self.own.clone()); }
        self.direct.get(node).cloned().or_else(||self.active.proofs().find(|p|p.endpoint==*node).cloned())
    }
    pub fn outgoing(&self, frame: Frame, to: Node) -> Result<Control, &'static str> {
        if frame.scope != self.scope() || !self.direct.contains_key(&to) { return Err("unknown public neighbor"); }
        Control::build(frame,to,|node|self.proof(node))
    }
    pub fn control(&mut self, from: Node, control: Control, now: u64) -> Result<Frame, &'static str> {
        if control.frame.scope != self.scope() { return Err("wrong public scope"); }
        let neighbor = self.direct.get(&from).ok_or("unknown public neighbor")?.neighbor;
        let (path, previous) = control.identities(self.node())?;
        if path.get(previous) != Some(&from) { return Err("wrong public control sender"); }
        let mut combined = self.roles();
        for proof in &control.proofs {
            if proof.policy != self.own.policy { return Err("public path has another policy lane"); }
            if let Some(known) = self.direct.get(&proof.endpoint).or_else(|| (proof.endpoint == self.node()).then_some(&self.own)) {
                // A path cannot replace a live link's established identity.
                if known.generation != proof.generation || known.neighbor != proof.neighbor || known.transit != proof.transit {
                    return Err("public control conflicts with live identity");
                }
            }
            combined.insert(proof.endpoint,proof.transit);
        }
        if combined.len() > MAX_NODES { return Err("public identity capacity"); }
        self.active.admit(&path,&control.proofs,previous,neighbor,now)?;
        Ok(control.frame)
    }
    /// Unknown data cannot allocate state or extend another scope's lifetimes.
    /// The router still checks the path and its forwarding capabilities.
    pub fn data(&mut self, from: Node, frame: &Frame, now: u64) -> bool {
        if frame.scope != self.scope() || !self.direct.contains_key(&from) { return false; }
        let (path, at, reverse) = match &frame.message {
            Message::Data { path,cursor,.. } => (path,*cursor as usize,false),
            Message::Probe { path,cursor,reply,.. } => (path,*cursor as usize,*reply),
            _ => return false,
        };
        let roles = self.roles();
        if path.len() < 2 || path.len() > crate::routing::MAX_HOPS + 1
            || path.iter().collect::<std::collections::BTreeSet<_>>().len() != path.len()
            || path.iter().any(|node| !roles.contains_key(node))
            || path.iter().skip(1).take(path.len()-2).any(|node| roles.get(node) != Some(&true))
            || path.get(at) != Some(&self.node()) { return false; }
        let previous = if reverse { at.checked_add(1) } else { at.checked_sub(1) };
        if previous.and_then(|i|path.get(i)) != Some(&from) { return false; }
        // The local identity need not occur in discovery prefixes. Direct peers
        // remain known for the link lifetime; only remote identities need refresh.
        let remote: Vec<_> = path.iter().filter(|n| **n != self.node() && !self.direct.contains_key(*n)).copied().collect();
        self.active.touch(&remote,now)
    }
    pub fn expire(&mut self, now: u64) -> bool { !self.active.expire(now).is_empty() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use iroh::SecretKey;
    fn proofs() -> Vec<Binding> { (1..=4).map(|n|Binding::sign(&SecretKey::from([n;32]),[7;32],crate::policy::TransitPolicy::empty().digest(),1,n==2||n==3)).collect() }
    #[test]
    fn public_middle_learns_only_active_path_and_forgets_it_when_idle() {
        let p = proofs();
        let mut b = Admission::new(p[1].clone()).unwrap();
        b.neighbors(vec![p[0].clone(),p[2].clone()]).unwrap();
        let discover = Frame { scope:[7;32],message:Message::Discover { request:1,target:p[3].endpoint,path:vec![p[0].endpoint] } };
        let control = Control::build(discover,b.node(),|node|p.iter().find(|p|p.endpoint==*node).cloned()).unwrap();
        b.control(p[0].endpoint,control,0).unwrap();
        assert!(b.roles().contains_key(&p[3].endpoint));
        let forwarded = Frame { scope:[7;32],message:Message::Discover { request:1,target:p[3].endpoint,path:vec![p[0].endpoint,p[1].endpoint] } };
        let out = b.outgoing(forwarded,p[2].endpoint).unwrap();
        assert_eq!(out.proofs.len(),3);
        out.verify(p[2].endpoint,p[1].neighbor,&Default::default()).unwrap();
        let data = Frame {scope:[7;32],message:Message::Data { path:p.iter().map(|p|p.endpoint).collect(),cursor:1,packet:vec![1] }};
        assert!(b.data(p[0].endpoint,&data,40_000));
        assert!(!b.data(p[2].endpoint,&data,80_000));
        assert!(b.expire(85_000));
        assert!(!b.roles().contains_key(&p[3].endpoint));
        assert!(!b.data(p[0].endpoint,&data,85_000));
    }
    #[test]
    fn invalid_control_cannot_admit_a_target_or_change_a_live_neighbor() {
        let p = proofs();
        let mut b = Admission::new(p[1].clone()).unwrap();
        b.neighbors(vec![p[0].clone()]).unwrap();
        let discover = Frame { scope:[7;32],message:Message::Discover { request:1,target:p[3].endpoint,path:vec![p[0].endpoint] } };
        let mut control = Control::build(discover,b.node(),|node|p.iter().find(|p|p.endpoint==*node).cloned()).unwrap();
        control.proofs[0] = Binding::sign(&SecretKey::from([1;32]),[7;32],crate::policy::TransitPolicy::empty().digest(),2,false);
        assert!(b.control(p[0].endpoint,control,0).is_err());
        assert_eq!(b.roles().len(),2);
    }
}
