//! Workspace relay executable. Its private state directory holds the identity,
//! registration and last complete directory; the invitation file is needed once.
use mesh_transport::{announcement::{Descriptor, SignedAnnouncement, bounded_address}, directory_client::Subscription, enrollment::{self, Invitation}, relay::Forwarder, relay_store::{Saved, Store}};
use iroh::{Endpoint, RelayMode, Watcher, endpoint::presets::Minimal};
use std::{io::Read, path::PathBuf, sync::Arc, time::Duration};

struct Task<T>(tokio::task::JoinHandle<T>);
impl<T> Drop for Task<T> { fn drop(&mut self) { self.0.abort(); } }
fn main() {
    if let Err(error) = start() { eprintln!("mesh-relay: {error}"); std::process::exit(1); }
}
fn start() -> Result<(), String> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.first().is_some_and(|arg|arg=="--global") {return mesh_transport::global_daemon::start(&args[1..]);}
    if args.is_empty() || args.len() > 2 { return Err("usage: mesh-relay DATA_DIRECTORY [INVITATION_JSON_FILE]".into()); }
    let store = Arc::new(Store::open(&PathBuf::from(&args[0]))?);
    let invitation = args.get(1).map(|path| -> Result<Invitation,String> {
        let mut bytes = Vec::new();
        std::fs::File::open(path).map_err(|e| e.to_string())?.take(16*1024+1).read_to_end(&mut bytes).map_err(|e| e.to_string())?;
        if bytes.len() > 16*1024 { return Err("invitation file too large".into()); }
        serde_json::from_slice(&bytes).map_err(|e| e.to_string())
    }).transpose()?;
    let saved = if let Some(mut saved) = store.load()? {
        if let Some(invitation) = invitation {
            if saved.registration.is_some() { return Err("relay is registered; restart with the data directory only".into()); }
            if invitation.issuer != saved.invitation.issuer || invitation.scope != saved.invitation.scope {
                return Err("use a separate data directory for a different scope or issuer".into());
            }
            saved.invitation = invitation;
            saved.snapshot = None;
            store.save(&saved)?;
        }
        saved
    } else {
        let saved = Saved { invitation: invitation.ok_or("first start needs an invitation JSON file")?, registration:None, revision:0, snapshot:None };
        store.save(&saved)?;
        saved
    };
    let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build().map_err(|e| e.to_string())?;
    runtime.block_on(async {
        tokio::select! {
            result = run(store, saved) => result,
            result = tokio::signal::ctrl_c() => result.map_err(|e| e.to_string()),
        }
    })
}
async fn persist(store: &Arc<Store>, saved: &Saved) -> Result<(), String> {
    let store = store.clone(); let saved = saved.clone();
    tokio::task::spawn_blocking(move || store.save(&saved)).await.map_err(|e| e.to_string())?
}
async fn announce(store: &Arc<Store>, saved: &mut Saved, scope: [u8;32], descriptor: Descriptor) -> Result<SignedAnnouncement,String> {
    saved.revision = saved.revision.checked_add(1).filter(|n| *n <= 9_007_199_254_740_991).ok_or("relay revision exhausted")?;
    let signed = SignedAnnouncement::sign(&store.key(),scope,saved.revision,descriptor)?;
    persist(store,saved).await?;
    Ok(signed)
}
async fn session(store: &Arc<Store>, saved: &mut Saved, scope: [u8;32], generation: u64, control: &Endpoint, forwarder: &mut Forwarder) -> Result<(),String> {
    let mut endpoint = forwarder.endpoint();
    let mut addresses = endpoint.watch_addr();
    let mut descriptor = forwarder.descriptor();
    descriptor.address = bounded_address(addresses.get());
    let signed = announce(store,saved,scope,descriptor).await?;
    let subscription = Subscription::open(control,&saved.invitation,scope,generation,&signed).await?;
    let (updates,changed) = tokio::sync::watch::channel(signed);
    let (snapshots,mut received) = tokio::sync::mpsc::channel(1);
    let mut task = Task(tokio::spawn(subscription.run(changed,snapshots)));
    loop {
        tokio::select! {
            result = &mut task.0 => return result.map_err(|e| e.to_string())?,
            update = addresses.updated() => {
                let address = bounded_address(update.map_err(|e| e.to_string())?);
                let mut descriptor = forwarder.descriptor(); descriptor.address = address;
                let signed = announce(store,saved,scope,descriptor).await?;
                updates.send(signed).map_err(|_| "directory publisher ended".to_owned())?;
            }
            snapshot = received.recv() => {
                let snapshot = snapshot.ok_or("directory subscription ended")?;
                // Commit admission before publishing it so restart cannot undo a
                // revocation acknowledged by this relay's control connection.
                saved.snapshot = Some(snapshot.clone());
                persist(store,saved).await?;
                forwarder.apply(snapshot).await?;
                let current=forwarder.endpoint();
                if current.id()!=endpoint.id() {
                    endpoint=current;addresses=endpoint.watch_addr();
                    let mut descriptor=forwarder.descriptor();descriptor.address=bounded_address(addresses.get());
                    let signed=announce(store,saved,scope,descriptor).await?;
                    updates.send(signed).map_err(|_|"directory publisher ended".to_owned())?;
                }
            }
        }
    }
}
async fn run(store: Arc<Store>, mut saved: Saved) -> Result<(),String> {
    let scope_text = &saved.invitation.scope;
    if scope_text.len()!=64 || !scope_text.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()) { return Err("invalid workspace scope".into()); }
    let mut scope = [0;32];
    for (i,byte) in scope.iter_mut().enumerate() { *byte = u8::from_str_radix(&scope_text[i*2..i*2+2],16).map_err(|e| e.to_string())?; }
    let urls: Vec<_> = saved.invitation.endpoint.relays.iter().filter(|r| !saved.invitation.endpoint.disabled_relays.contains(r)).cloned().collect();
    let control = Endpoint::builder(Minimal).secret_key(store.key())
        .relay_mode(if urls.is_empty() {RelayMode::Disabled} else {RelayMode::custom(urls)}).bind().await.map_err(|e| e.to_string())?;
    let mut generation = 0;
    let mut forwarder = None;
    if let Some(signed) = &saved.registration {
        generation = signed.verify(saved.invitation.issuer,control.id(),&saved.invitation.scope)?.generation;
        let mut cached = Forwarder::bind_with_control(&store.key(),scope,saved.invitation.issuer,generation,control.clone()).await?;
        if let Some(snapshot) = &saved.snapshot { cached.apply(snapshot.clone()).await?; }
        forwarder = Some(cached);
    }
    let mut retry = 1u64;
    loop {
        // Resume first also recovers a lost enrollment reply after token use.
        let mut registration = enrollment::request_status(&control,&saved.invitation,true).await;
        if registration.is_err() && saved.registration.is_none() && !saved.invitation.token.is_empty() {
            registration = enrollment::request_status(&control,&saved.invitation,false).await;
        }
        let outcome = match registration {
            Err(error) if error.registration_removed() && saved.registration.is_some() => {
                saved.snapshot = None;
                saved.registration = None;
                persist(&store,&saved).await?;
                if let Some(old) = forwarder.take() { old.close().await; }
                control.close().await;
                return Err(format!("relay admission removed: {error}; enroll again with a new invitation"));
            }
            Err(error) => Err(error.to_string()),
            Ok(signed) => {
                let record = signed.verify(saved.invitation.issuer,control.id(),&saved.invitation.scope)?;
                if record.generation < generation { return Err("issuer returned an older registration".into()); }
                if record.generation != generation {
                    saved.snapshot = None;
                    if let Some(old) = forwarder.take() { old.close().await; }
                    generation = record.generation;
                    forwarder = Some(Forwarder::bind_with_control(&store.key(),scope,saved.invitation.issuer,generation,control.clone()).await?);
                }
                saved.registration = Some(signed);
                saved.invitation.token.clear();
                persist(&store,&saved).await?;
                let started = tokio::time::Instant::now();
                let result = session(&store,&mut saved,scope,generation,&control,forwarder.as_mut().ok_or("relay forwarding unavailable")?).await;
                if started.elapsed() >= Duration::from_secs(30) { retry = 1; }
                result
            }
        };
        if let Err(error) = outcome { eprintln!("relay control disconnected: {error}; retry in {retry}s"); }
        // A failed control connection does not own the forwarding instance.
        tokio::time::sleep(Duration::from_secs(retry)).await;
        retry = (retry*2).min(60);
    }
}
