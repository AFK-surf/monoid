//! Private local relay state. The identity is durable before a token is redeemed.
//! Call filesystem methods before serving or on a blocking worker, never a Tokio
//! executor thread. One process owns a data directory for its entire lifetime.
use crate::{directory::Snapshot, enrollment::{Invitation, SignedRegistration}};
use iroh::SecretKey;
use serde::{Deserialize, Serialize};
use std::{fs::{self, File, OpenOptions}, io::{Read, Write}, path::{Path, PathBuf}};
const LIMIT: u64 = 8 * 1024 * 1024;
#[derive(Clone, Serialize, Deserialize)]
pub struct Saved {
    pub invitation: Invitation,
    pub registration: Option<SignedRegistration>,
    pub revision: u64,
    pub snapshot: Option<Snapshot>,
}
pub struct Store { root: PathBuf, _lock: File, key: SecretKey }
fn private_options() -> OpenOptions {
    let mut options = OpenOptions::new();
    options.write(true).read(true);
    #[cfg(unix)] { use std::os::unix::fs::OpenOptionsExt; options.mode(0o600); }
    options
}
fn sync_directory(root: &Path) -> Result<(), String> {
    #[cfg(unix)] { File::open(root).and_then(|f| f.sync_all()).map_err(|e| e.to_string())?; }
    Ok(())
}
impl Store {
    pub fn open(root: &Path) -> Result<Self, String> {
        let mut builder = fs::DirBuilder::new();
        builder.recursive(true);
        #[cfg(unix)] { use std::os::unix::fs::DirBuilderExt; builder.mode(0o700); }
        builder.create(root).map_err(|e| e.to_string())?;
        let meta = fs::symlink_metadata(root).map_err(|e| e.to_string())?;
        if !meta.is_dir() || meta.file_type().is_symlink() { return Err("relay data path must be a private directory".into()); }
        #[cfg(unix)] {
            use std::os::unix::fs::PermissionsExt;
            if meta.permissions().mode() & 0o077 != 0 { return Err("relay data directory must have mode 0700".into()); }
        }
        let lock = private_options().create(true).open(root.join("lock")).map_err(|e| e.to_string())?;
        lock.try_lock().map_err(|_| "relay data directory is already in use".to_owned())?;
        let key_path = root.join("identity");
        let key = match File::open(&key_path) {
            Ok(file) => {
                let mut bytes = Vec::new();
                file.take(33).read_to_end(&mut bytes).map_err(|e| e.to_string())?;
                let bytes: [u8;32] = bytes.try_into().map_err(|_| "invalid relay identity file".to_owned())?;
                SecretKey::from(bytes)
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                let key = SecretKey::generate();
                let mut file = private_options().create_new(true).open(&key_path).map_err(|e| e.to_string())?;
                file.write_all(&key.to_bytes()).and_then(|_| file.sync_all()).map_err(|e| e.to_string())?;
                sync_directory(root)?;
                key
            }
            Err(error) => return Err(error.to_string()),
        };
        Ok(Self { root: root.into(), _lock: lock, key })
    }
    pub fn key(&self) -> SecretKey { self.key.clone() }
    pub fn load(&self) -> Result<Option<Saved>, String> {
        if self.root.join("global.json").exists() {return Err("use a separate data directory for a workspace relay".into());}
        let file = match File::open(self.root.join("state.json")) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error.to_string()),
        };
        let mut bytes = Vec::new();
        file.take(LIMIT + 1).read_to_end(&mut bytes).map_err(|e| e.to_string())?;
        if bytes.len() as u64 > LIMIT { return Err("relay state is too large".into()); }
        let saved: Saved = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
        if let Some(registration) = &saved.registration {
            registration.verify(saved.invitation.issuer, self.key.public(), &saved.invitation.scope)?;
        }
        if saved.revision > 9_007_199_254_740_991 { return Err("invalid relay revision".into()); }
        Ok(Some(saved))
    }
    pub fn load_global(&self) -> Result<Option<crate::global_registration::Saved>,String> {
        if self.root.join("state.json").exists() {return Err("use a separate data directory for a global relay".into());}
        let file=match File::open(self.root.join("global.json")) {
            Ok(file)=>file,
            Err(error) if error.kind()==std::io::ErrorKind::NotFound=>return Ok(None),
            Err(error)=>return Err(error.to_string()),
        };
        let mut bytes=Vec::new();file.take(LIMIT+1).read_to_end(&mut bytes).map_err(|e|e.to_string())?;
        if bytes.len()as u64>LIMIT{return Err("global relay state is too large".into());}
        let saved:crate::global_registration::Saved=serde_json::from_slice(&bytes).map_err(|e|e.to_string())?;
        saved.validate(self.key.public())?;Ok(Some(saved))
    }
    pub fn save_global(&self,saved:&crate::global_registration::Saved)->Result<(),String> {
        if self.root.join("state.json").exists() {return Err("use a separate data directory for a global relay".into());}
        saved.validate(self.key.public())?;
        self.write_state("global",serde_json::to_vec(saved).map_err(|e|e.to_string())?)
    }
    pub fn save(&self, saved: &Saved) -> Result<(), String> {
        if self.root.join("global.json").exists() {return Err("use a separate data directory for a workspace relay".into());}
        self.write_state("state",serde_json::to_vec(saved).map_err(|e|e.to_string())?)
    }
    fn write_state(&self,name:&str,bytes:Vec<u8>)->Result<(),String> {
        if bytes.len() as u64 > LIMIT { return Err("relay state is too large".into()); }
        let temp = self.root.join(format!("{name}.tmp"));
        // The process lock makes an incomplete temporary file ours to replace.
        let mut file = private_options().create(true).truncate(true).open(&temp).map_err(|e| e.to_string())?;
        file.write_all(&bytes).and_then(|_| file.sync_all()).map_err(|e| e.to_string())?;
        fs::rename(temp, self.root.join(format!("{name}.json"))).map_err(|e| e.to_string())?;
        sync_directory(&self.root)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::enrollment::IssuerAddress;
    struct Temporary(PathBuf);
    impl Drop for Temporary { fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); } }
    fn directory() -> Temporary { Temporary(std::env::temp_dir().join(format!("mesh-store-{}", SecretKey::generate().public()))) }
    #[test]
    fn identity_survives_restart_and_state_replacement_ignores_partial_temporary_file() {
        let dir = directory();
        let store = Store::open(&dir.0).unwrap();
        let identity = store.key().public();
        assert!(Store::open(&dir.0).is_err(), "two processes must not share an identity directory");
        assert!(store.load().unwrap().is_none());
        let issuer = SecretKey::from([70;32]).public();
        let mut saved = Saved { invitation: Invitation { scope: "ab".repeat(32), issuer, token:"t".repeat(43),
            endpoint: IssuerAddress { id:issuer, relays:vec![], ips:vec![], disabled_relays:vec![] } },
            registration:None, revision:1, snapshot:None };
        store.save(&saved).unwrap();
        // A crash before rename must leave the last committed state readable.
        fs::write(dir.0.join("state.tmp"), b"partial").unwrap();
        drop(store);
        let store = Store::open(&dir.0).unwrap();
        assert_eq!(store.key().public(),identity);
        assert_eq!(store.load().unwrap().unwrap().revision,1);
        saved.revision = 2;
        saved.invitation.token.clear();
        store.save(&saved).unwrap();
        let loaded = store.load().unwrap().unwrap();
        assert_eq!(loaded.revision,2);
        assert!(loaded.invitation.token.is_empty());
        assert!(!dir.0.join("state.tmp").exists());
        drop(store);
        assert_eq!(Store::open(&dir.0).unwrap().key().public(),identity);
    }
    #[test]
    fn global_state_survives_restart_and_cannot_share_workspace_storage() {
        let dir=directory();
        let store=Store::open(&dir.0).unwrap();
        let identity=store.key().public();
        let saved=crate::global_registration::Saved {
            invitation:crate::global_registration::Invitation {origin:"https://cloud.example".into(),token:"t".repeat(43),relays:vec![]},
            registration:None,revision:7,registry:vec![],
        };
        store.save_global(&saved).unwrap();
        fs::write(dir.0.join("global.tmp"),b"incomplete").unwrap();
        drop(store);
        let store=Store::open(&dir.0).unwrap();
        assert_eq!(store.key().public(),identity);
        assert_eq!(store.load_global().unwrap().unwrap().revision,7);
        assert!(store.load().is_err());
        fs::write(dir.0.join("state.json"),b"{}").unwrap();
        assert!(store.save_global(&saved).is_err());
        assert!(store.load_global().is_err());
    }
    #[test]
    fn corrupt_identity_and_unbounded_state_fail_closed() {
        let dir = directory();
        drop(Store::open(&dir.0).unwrap());
        fs::write(dir.0.join("identity"), b"broken").unwrap();
        assert!(Store::open(&dir.0).is_err(), "never replace an enrolled identity after corruption");
        fs::write(dir.0.join("identity"), [71;32]).unwrap();
        let store = Store::open(&dir.0).unwrap();
        let file = File::create(dir.0.join("state.json")).unwrap();
        file.set_len(LIMIT+1).unwrap();
        assert!(store.load().is_err());
    }
}
