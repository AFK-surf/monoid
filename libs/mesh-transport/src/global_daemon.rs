//! The global relay keeps registration separate from its forwarding service.
//! A cached registration starts while cloud is unavailable. Healthy registration
//! is updated on address events, never on a polling timer.
use crate::{global_registration::{Client,Error,Invitation,Saved},public_service::{Scopes,BOOTSTRAP_ALPN},relay_store::Store};
use iroh::{Endpoint,RelayMode,Watcher,endpoint::presets::Minimal};
use std::{ffi::OsString,io::Read,path::PathBuf,sync::Arc,time::Duration};

pub fn start(args:&[OsString])->Result<(),String> {
    if args.is_empty()||args.len()>2{return Err("usage: mesh-relay --global DATA_DIRECTORY [INVITATION_JSON_FILE]".into());}
    let store=Arc::new(Store::open(&PathBuf::from(&args[0]))?);
    let invitation=args.get(1).map(|path|->Result<Invitation,String>{
        let mut bytes=Vec::new();std::fs::File::open(path).map_err(|e|e.to_string())?.take(16385).read_to_end(&mut bytes).map_err(|e|e.to_string())?;
        if bytes.len()>16384{return Err("global invitation too large".into());}
        serde_json::from_slice(&bytes).map_err(|e|e.to_string())
    }).transpose()?;
    let saved=if let Some(mut saved)=store.load_global()? {
        if let Some(invitation)=invitation {
            if saved.registration.is_some(){return Err("global relay is registered; restart with the data directory only".into());}
            if invitation.origin.trim_end_matches('/')!=saved.invitation.origin.trim_end_matches('/') {return Err("use a separate data directory for another cloud".into());}
            saved.invitation=invitation;store.save_global(&saved)?;
        }
        saved
    } else {
        let saved=Saved {invitation:invitation.ok_or("first global start needs an invitation JSON file")?,registration:None,revision:0,registry:vec![]};
        store.save_global(&saved)?;saved
    };
    saved.validate(store.key().public())?;
    tokio::runtime::Builder::new_multi_thread().enable_all().build().map_err(|e|e.to_string())?.block_on(run(store,saved))
}
async fn persist(store:&Arc<Store>,saved:&Saved)->Result<(),String> {
    let store=store.clone();let saved=saved.clone();
    tokio::task::spawn_blocking(move||store.save_global(&saved)).await.map_err(|e|e.to_string())?
}
enum Failure {Temporary(String),Stop(String)}
fn failure(error:Error)->Failure {
    match error {
        Error::Rejected {status,code} if status==400||status==401||status==403=>Failure::Stop(format!("{code}; obtain a new operator invitation if this relay was removed")),
        error=>Failure::Temporary(error.to_string()),
    }
}
async fn sync(client:&Client,store:&Arc<Store>,saved:&mut Saved,endpoint:&Endpoint)->Result<(),Failure> {
    let registry=client.list().await.map_err(failure)?;
    let registered=registry.iter().find(|r|r.node==endpoint.id()).cloned();
    if saved.registration.is_some() && registered.as_ref().is_none_or(|r|Some(r.generation)!=saved.registration.as_ref().map(|r|r.generation)) {
        saved.registration=None;saved.registry=registry;
        persist(store,saved).await.map_err(Failure::Stop)?;
        return Err(Failure::Stop("global registration was removed or replaced; restart with the current operator invitation".into()));
    }
    saved.registry=registry;
    if let Some(registration)=registered {
        saved.revision=saved.revision.max(registration.revision);
        saved.registration=Some(registration);
        saved.invitation.token.clear();
    }
    let address=crate::announcement::bounded_address(endpoint.addr());
    if saved.registration.as_ref().is_some_and(|r|r.address==address) {
        persist(store,saved).await.map_err(Failure::Stop)?;return Ok(());
    }
    saved.revision=saved.revision.checked_add(1).filter(|r|*r<=9_007_199_254_740_991).ok_or_else(||Failure::Stop("global address revision exhausted".into()))?;
    persist(store,saved).await.map_err(Failure::Stop)?;
    let token=if saved.registration.is_none(){
        if saved.invitation.token.is_empty(){return Err(Failure::Stop("global relay needs a new operator invitation".into()));}
        Some(saved.invitation.token.as_str())
    }else{None};
    let registration=match client.publish(&store.key(),token,saved.registration.as_ref().map(|r|r.generation),saved.revision,address).await {
        Ok(registration)=>registration,
        Err(error)=>{
            // Removal can race the list read above. Do not restart from a revoked cached registration.
            if matches!(&error,Error::Rejected {status:403,code} if code=="mesh_relay_not_registered") {
                saved.registration=None;
                saved.registry.retain(|r|r.node!=endpoint.id());
                persist(store,saved).await.map_err(Failure::Stop)?;
            }
            return Err(failure(error));
        }
    };
    saved.registration=Some(registration);saved.invitation.token.clear();
    persist(store,saved).await.map_err(Failure::Stop)
}
async fn control(client:Client,store:Arc<Store>,mut saved:Saved,endpoint:Endpoint,scopes:Arc<Scopes>)->Result<(),String> {
    let mut addresses=endpoint.watch_addr();let mut backoff=1;
    loop {
        let result=async {
            sync(&client,&store,&mut saved,&endpoint).await?;
            scopes.backbone(endpoint.clone(),saved.registry.clone()).await.map_err(Failure::Stop)?;
            let generation=saved.registration.as_ref().unwrap().generation;
            let mut events=match client.watch(&store.key(),generation).await {
                Ok(events)=>events,
                Err(error)=>{
                    if matches!(&error,Error::Rejected {status:403,code} if code=="mesh_relay_not_registered") {
                        saved.registration=None;saved.registry.retain(|r|r.node!=endpoint.id());
                        persist(&store,&saved).await.map_err(Failure::Stop)?;
                        return Err(Failure::Stop(error.to_string()));
                    }
                    return Err(Failure::Temporary(error.to_string()));
                }
            };
            loop {
                tokio::select! {
                    registry=events.next()=>{
                        let registry=registry.map_err(|e|Failure::Temporary(e.to_string()))?;
                        let own=registry.iter().find(|r|r.node==endpoint.id()&&r.generation==generation).cloned();
                        saved.registry=registry;
                        if own.is_none() {
                            saved.registration=None;persist(&store,&saved).await.map_err(Failure::Stop)?;
                            return Err(Failure::Stop("global registration was removed or replaced; restart with the current operator invitation".into()));
                        }
                        saved.registration=own;
                        persist(&store,&saved).await.map_err(Failure::Stop)?;
                        scopes.backbone(endpoint.clone(),saved.registry.clone()).await.map_err(Failure::Stop)?;
                        backoff=1;
                    }
                    address=addresses.updated()=>{address.map_err(|e|Failure::Temporary(e.to_string()))?;return Ok(());}
                }
            }
        }.await;
        match result {
            Ok(())=>{backoff=1;},
            Err(Failure::Stop(error))=>return Err(error),
            Err(Failure::Temporary(error))=>{
                eprintln!("global relay control unavailable; forwarding remains active: {error}");
                tokio::time::sleep(Duration::from_secs(backoff)).await;backoff=(backoff*2).min(60);
            }
        }
    }
}
async fn run(store:Arc<Store>,mut saved:Saved)->Result<(),String> {
    let endpoint=Endpoint::builder(Minimal).secret_key(store.key()).alpns(vec![BOOTSTRAP_ALPN.to_vec()])
        .relay_mode(if saved.invitation.relays.is_empty(){RelayMode::Disabled}else{RelayMode::custom(saved.invitation.relays.clone())})
        .bind().await.map_err(|e|e.to_string())?;
    let client=Client::new(&saved.invitation.origin)?;
    let mut backoff=1;
    while saved.registration.is_none() {
        let result=tokio::select! {result=sync(&client,&store,&mut saved,&endpoint)=>result,result=tokio::signal::ctrl_c()=>{endpoint.close().await;return result.map_err(|e|e.to_string());}};
        match result {
            Ok(())=>{},Err(Failure::Stop(error))=>{endpoint.close().await;return Err(error);}
            Err(Failure::Temporary(error))=>{
                eprintln!("global relay registration unavailable: {error}");
                tokio::select! {_=tokio::time::sleep(Duration::from_secs(backoff))=>{},result=tokio::signal::ctrl_c()=>{endpoint.close().await;return result.map_err(|e|e.to_string());}}
                backoff=(backoff*2).min(60);
            }
        }
    }
    let scopes=Scopes::new(store.key(),saved.invitation.relays.clone(),saved.registration.as_ref().unwrap().generation)?;
    scopes.backbone(endpoint.clone(),saved.registry.clone()).await?;
    let control=control(client,store,saved,endpoint.clone(),scopes.clone());tokio::pin!(control);
    let mut serving=tokio::task::JoinSet::new();
    let result=loop {
        tokio::select! {
            result=&mut control=>break result,
            result=tokio::signal::ctrl_c()=>break result.map_err(|e|e.to_string()),
            Some(_)=serving.join_next(),if !serving.is_empty()=>{},
            incoming=endpoint.accept(),if serving.len()<64=>{
                let Some(incoming)=incoming else {break Ok(())};let scopes=scopes.clone();
                serving.spawn(async move {
                    if let Ok(Ok(conn))=tokio::time::timeout(Duration::from_secs(10),incoming).await {let _=scopes.serve(conn).await;}
                });
            }
        }
    };
    serving.abort_all();while serving.join_next().await.is_some(){}
    scopes.close().await;endpoint.close().await;result
}
