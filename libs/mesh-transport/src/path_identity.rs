//! Identity proofs for a single path through public transit nodes. These are not
//! workspace membership grants: application endpoints still apply their own
//! admitted directory. A public relay learns only this bounded path, not a
//! workspace roster, and must enforce its own resource and relay-use policy.
use crate::{identity::Binding, routing::{MAX_HOPS, Node, Scope}};
use std::collections::{BTreeMap, BTreeSet};

const IDLE_MS: u64 = 45_000;
#[derive(Clone)]
struct Kept { proof: Binding, expires: u64 }
/// Public transit remembers only identities used by active paths. Its caller
/// supplies elapsed time; neither clock reads nor membership polling live here.
#[derive(Clone)]
pub struct Active {
    scope: Scope,
    kept: BTreeMap<Node, Kept>,
}
impl Active {
    pub fn new(scope: Scope) -> Self { Self { scope, kept: BTreeMap::new() } }
    pub fn admit(&mut self, path: &[Node], proofs: &[Binding], previous: usize, neighbor: Node, now: u64) -> Result<(), &'static str> {
        let minimum = self.kept.iter().map(|(node, kept)| (*node, kept.proof.generation)).collect();
        verify(self.scope, path, proofs, previous, neighbor, &minimum)?;
        let added = path.iter().filter(|node| !self.kept.contains_key(*node)).count();
        if self.kept.len() + added > crate::routing::MAX_NODES { return Err("public path identity capacity"); }
        for proof in proofs {
            if let Some(old) = self.kept.get(&proof.endpoint)
                && old.proof.generation == proof.generation
                && (old.proof.neighbor != proof.neighbor || old.proof.transit != proof.transit) {
                return Err("conflicting path identity generation");
            }
        }
        // No partial admission if any identity or capacity check failed.
        for proof in proofs {
            self.kept.insert(proof.endpoint, Kept { proof: proof.clone(), expires: now.saturating_add(IDLE_MS) });
        }
        Ok(())
    }
    /// Only call after a packet passed scope, path and authenticated-hop checks.
    /// Data packets may refresh an existing identity, never create one.
    pub fn touch(&mut self, path: &[Node], now: u64) -> bool {
        if path.len() > MAX_HOPS + 1 || path.iter().any(|node| self.kept.get(node).is_none_or(|kept| kept.expires <= now)) { return false; }
        for node in path { self.kept.get_mut(node).unwrap().expires = now.saturating_add(IDLE_MS); }
        true
    }
    pub fn expire(&mut self, now: u64) -> Vec<Node> {
        let removed: Vec<_> = self.kept.iter().filter(|(_, kept)| kept.expires <= now).map(|(node, _)| *node).collect();
        self.kept.retain(|_, kept| kept.expires > now);
        removed
    }
    pub fn proofs(&self) -> impl Iterator<Item = &Binding> { self.kept.values().map(|kept| &kept.proof) }
}

/// Check the whole proof set before the caller admits any new path identity.
/// `previous` is the path position of the authenticated neighbor that sent this
/// control frame. Endpoint and neighbor keys must not be confused.
pub fn verify(
    scope: Scope,
    path: &[Node],
    proofs: &[Binding],
    previous: usize,
    authenticated_neighbor: Node,
    minimum_generations: &BTreeMap<Node, u64>,
) -> Result<Vec<(Node, bool)>, &'static str> {
    if path.len() < 2 || path.len() > MAX_HOPS + 1 || proofs.len() != path.len() || previous >= path.len() {
        return Err("invalid path identity proof count");
    }
    let mut nodes = BTreeSet::new();
    let mut neighbors = BTreeSet::new();
    let mut roles = Vec::with_capacity(path.len());
    for (index, (node, proof)) in path.iter().zip(proofs).enumerate() {
        if proof.endpoint != *node || !nodes.insert(*node) || !neighbors.insert(proof.neighbor) {
            return Err("path identity duplicate or mismatch");
        }
        proof.verify(scope, minimum_generations.get(node).copied().unwrap_or(0))?;
        if proof.generation == 0 || proof.generation > 9_007_199_254_740_991 {
            return Err("invalid path identity generation");
        }
        if index > 0 && index + 1 < path.len() && !proof.transit {
            return Err("leaf identity cannot be a middle hop");
        }
        roles.push((*node, proof.transit));
    }
    if proofs[previous].neighbor != authenticated_neighbor {
        return Err("path proof does not bind the authenticated neighbor");
    }
    Ok(roles)
}

#[cfg(test)]
mod tests {
    use super::*;
    use iroh::SecretKey;
    fn chain() -> (Vec<Node>, Vec<Binding>) {
        let proofs: Vec<_> = (1..=4).map(|i| Binding::sign(&SecretKey::from([i;32]),[99;32],crate::policy::TransitPolicy::empty().digest(),1,i==2||i==3)).collect();
        (proofs.iter().map(|p| p.endpoint).collect(),proofs)
    }
    #[test]
    fn transit_proof_checks_scope_roles_and_actual_neighbor_without_a_workspace_roster() {
        let (path,proofs) = chain();
        let roles = verify([99;32],&path,&proofs,1,proofs[1].neighbor,&BTreeMap::new()).unwrap();
        assert_eq!(roles.len(),4);
        assert_eq!(roles.iter().map(|p|p.1).collect::<Vec<_>>(),vec![false,true,true,false]);
        assert!(verify([98;32],&path,&proofs,1,proofs[1].neighbor,&BTreeMap::new()).is_err());
        assert!(verify([99;32],&path,&proofs,1,proofs[0].neighbor,&BTreeMap::new()).is_err());
        assert!(verify([99;32],&path,&proofs,1,proofs[1].neighbor,&BTreeMap::from([(path[2],2)])).is_err());
        let mut leaf = proofs.clone();
        leaf[1] = Binding::sign(&SecretKey::from([2;32]),[99;32],crate::policy::TransitPolicy::empty().digest(),1,false);
        assert!(verify([99;32],&path,&leaf,1,leaf[1].neighbor,&BTreeMap::new()).is_err());
    }
    #[test]
    fn partial_tampered_and_looping_proofs_are_rejected_as_a_whole() {
        let (path,proofs) = chain();
        assert!(verify([99;32],&path,&proofs[..3],1,proofs[1].neighbor,&BTreeMap::new()).is_err());
        let mut changed = proofs.clone(); changed[2].generation=2;
        assert!(verify([99;32],&path,&changed,1,proofs[1].neighbor,&BTreeMap::new()).is_err());
        let looped = vec![path[0],path[1],path[0]];
        let repeated = vec![proofs[0].clone(),proofs[1].clone(),proofs[0].clone()];
        assert!(verify([99;32],&looped,&repeated,1,proofs[1].neighbor,&BTreeMap::new()).is_err());
        assert!(verify([99;32],&vec![path[0];MAX_HOPS+2],&vec![proofs[0].clone();MAX_HOPS+2],0,proofs[0].neighbor,&BTreeMap::new()).is_err());
    }
    #[test]
    fn active_path_cache_expires_and_cannot_be_extended_by_unknown_data() {
        let (path, proofs) = chain();
        let mut active = Active::new([99;32]);
        assert!(!active.touch(&path,0));
        active.admit(&path,&proofs,1,proofs[1].neighbor,0).unwrap();
        assert!(active.touch(&path,44_999));
        assert!(active.expire(45_000).is_empty());
        assert!(!active.touch(&path,89_999));
        assert_eq!(active.expire(89_999).len(),4);
        assert_eq!(active.proofs().count(),0);
    }
    #[test]
    fn conflicting_generations_do_not_partly_change_the_active_directory() {
        let (path, proofs) = chain();
        let mut active = Active::new([99;32]);
        active.admit(&path,&proofs,1,proofs[1].neighbor,0).unwrap();
        let mut changed = proofs.clone();
        // A leaf changing its role must advance its binding generation.
        changed[0] = Binding::sign(&SecretKey::from([1;32]),[99;32],crate::policy::TransitPolicy::empty().digest(),1,true);
        assert!(active.admit(&path,&changed,1,proofs[1].neighbor,10).is_err());
        assert_eq!(active.proofs().find(|p|p.endpoint==path[0]).unwrap().transit,false);
        assert_eq!(active.expire(IDLE_MS).len(),4,"failed admission must not extend old lifetimes");
    }
}
