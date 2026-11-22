// A virtual microphone on this Windows machine by way of VB-Audio's Virtual Cable (virtual-mic spec §2, §3.10): the
// station plays what another machine's microphone hears into the cable's render end ("CABLE Input"), and an app records
// it from the capture end ("CABLE Output"). Whether any app records it is read, never assumed: the capture endpoint's
// audio sessions, each one's state asked again on every look (only an Active one of another process is demand), on a
// thread of its own in the multithreaded apartment, new sessions handed to it as agile references, never as raw COM
// pointers. Anything unknown, missing or failing is no demand, with its error.
//
// The pure parts (which endpoint is which, the cable's hardware ID, which sessions count, the epoch) are plain Rust,
// tested on every platform; what talks to Windows is `win` below.
// (some of it only the tests and Windows use)
#![allow(dead_code)]

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

/// The cable's render end, the station's feed.
pub const RENDER_NAME: &str = "CABLE Input (VB-Audio Virtual Cable)";
/// The cable's capture end, the one apps record and whose sessions are watched.
pub const CAPTURE_NAME: &str = "CABLE Output (VB-Audio Virtual Cable)";
/// What a device's name has when it is the cable, whatever its endpoint is called.
pub const CABLE_NAME_MARK: &str = "VB-Audio Virtual Cable";
/// The cable's hardware ID, in any of its devices' IDs.
pub const CABLE_HARDWARE_ID: &str = "VBAUDIOVACWDM";
/// More sessions than this on one endpoint is not believed.
pub const MOST_SESSIONS: usize = 128;
/// 100 ms of 48 kHz mono: what the feed keeps queued at most, the oldest dropped first.
pub const FEED_MOST_FRAMES: usize = 4800;

/// One look at the demand, as macOS and the browser say it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Demand {
    pub active: bool,
    pub epoch: u64,
    pub error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EndpointError {
    Missing(String),
    /// Every endpoint of that name, by ID: the person chooses one, never the first.
    Ambiguous(Vec<String>),
}

impl std::fmt::Display for EndpointError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EndpointError::Missing(name) => write!(f, "no audio endpoint named {name}"),
            EndpointError::Ambiguous(ids) => write!(f, "more than one audio endpoint of that name: {}", ids.join(", ")),
        }
    }
}

/// The one endpoint named exactly `name` (its full name, the driver's in brackets), or `chosen` when the person chose
/// one of them by ID.
pub fn pick_endpoint(endpoints: &[(String, String)], name: &str, chosen: Option<&str>) -> Result<String, EndpointError> {
    let found: Vec<&String> = endpoints.iter().filter(|(_, n)| n == name).map(|(id, _)| id).collect();
    if let Some(chosen) = chosen {
        return found.into_iter().find(|id| id.as_str() == chosen).cloned().ok_or_else(|| EndpointError::Missing(name.to_string()));
    }
    match found.as_slice() {
        [] => Err(EndpointError::Missing(name.to_string())),
        [one] => Ok((*one).clone()),
        many => Err(EndpointError::Ambiguous(many.iter().map(|s| (*s).clone()).collect())),
    }
}

/// A REG_MULTI_SZ / VT_VECTOR of strings: its strings up to the empty one.
pub fn parse_multi_sz(wide: &[u16]) -> Vec<String> {
    wide.split(|&c| c == 0).take_while(|s| !s.is_empty()).map(String::from_utf16_lossy).collect()
}

/// Any of a device's hardware IDs is the cable's.
pub fn is_cable_hardware<S: AsRef<str>>(ids: &[S]) -> bool {
    ids.iter().any(|id| id.as_ref().to_uppercase().contains(CABLE_HARDWARE_ID))
}

/// An input named as the cable: never captured as a microphone.
pub fn is_cable_name(name: &str) -> bool {
    name.contains(CABLE_NAME_MARK)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionState {
    Inactive,
    Active,
    Expired,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Added {
    Tracked,
    /// This process's own session: never demand.
    Own,
    /// Tracked already (the same instance identifier).
    Again,
}

/// The epoch: moved on by every change heard and every session added or gone; 1 to begin with.
#[derive(Clone)]
pub struct Epoch(Arc<AtomicU64>);

impl Default for Epoch {
    fn default() -> Self {
        Epoch(Arc::new(AtomicU64::new(1)))
    }
}

impl Epoch {
    pub fn bump(&self) {
        self.0.fetch_add(1, Ordering::AcqRel);
    }
    pub fn get(&self) -> u64 {
        self.0.load(Ordering::Acquire)
    }
}

/// The sessions watched, each with what it is held by (its COM objects on Windows; anything in tests).
pub struct Sessions<T> {
    items: Vec<(String, T)>,
    pub epoch: Epoch,
    /// A new session's notice could not be passed on: what is tracked is no longer all there is.
    pub lost: bool,
}

impl<T> Sessions<T> {
    pub fn new(epoch: Epoch) -> Self {
        Sessions { items: Vec::new(), epoch, lost: false }
    }

    pub fn len(&self) -> usize {
        self.items.len()
    }

    /// A session by its instance identifier and process: this process's skipped, one seen before ignored.
    pub fn add(&mut self, key: String, pid: u32, own_pid: u32, item: T) -> Result<Added, String> {
        if pid == own_pid {
            return Ok(Added::Own);
        }
        if self.items.iter().any(|(k, _)| *k == key) {
            return Ok(Added::Again);
        }
        if self.items.len() >= MOST_SESSIONS {
            return Err(format!("more than {MOST_SESSIONS} audio sessions on the cable"));
        }
        self.items.push((key, item));
        self.epoch.bump();
        Ok(Added::Tracked)
    }

    /// Each session's state asked again: any Active one is demand; Expired ones are let go (`gone`). Errors, and a lost
    /// notice, are no demand.
    pub fn sample(&mut self, mut state: impl FnMut(&T) -> Result<SessionState, String>, mut gone: impl FnMut(T)) -> Demand {
        if self.lost {
            return Demand { active: false, epoch: self.epoch.get(), error: Some("a new audio session's notice was lost".into()) };
        }
        let mut active = false;
        let mut error = None;
        let mut kept = Vec::with_capacity(self.items.len());
        for (key, item) in self.items.drain(..) {
            match state(&item) {
                Ok(SessionState::Active) => {
                    active = true;
                    kept.push((key, item));
                }
                Ok(SessionState::Inactive) => kept.push((key, item)),
                Ok(SessionState::Expired) => {
                    gone(item);
                    self.epoch.bump();
                }
                Err(e) => {
                    error.get_or_insert(e);
                    kept.push((key, item));
                }
            }
        }
        self.items = kept;
        match error {
            Some(e) => Demand { active: false, epoch: self.epoch.get(), error: Some(e) },
            None => Demand { active, epoch: self.epoch.get(), error: None },
        }
    }

    pub fn drain(&mut self) -> impl Iterator<Item = T> + '_ {
        self.items.drain(..).map(|(_, t)| t)
    }
}

/// PCM16 for the feed: at most `FEED_MOST_FRAMES` queued, the oldest dropped; a buffer filled from it is padded with
/// silence, so nothing old is played again.
#[derive(Default)]
pub struct FeedQueue {
    samples: std::collections::VecDeque<i16>,
    pub dropped: usize,
}

impl FeedQueue {
    pub fn push_pcm16le(&mut self, bytes: &[u8]) {
        for pair in bytes.chunks_exact(2) {
            self.samples.push_back(i16::from_le_bytes([pair[0], pair[1]]));
        }
        while self.samples.len() > FEED_MOST_FRAMES {
            self.samples.pop_front();
            self.dropped += 1;
        }
    }

    pub fn len(&self) -> usize {
        self.samples.len()
    }

    /// `out` (frames of `channels` interleaved, each mono sample copied to every channel) filled, the rest silence;
    /// how many frames were real.
    pub fn fill(&mut self, out: &mut [i16], channels: usize) -> usize {
        let frames = out.len() / channels.max(1);
        let mut real = 0;
        for f in 0..frames {
            let v = match self.samples.pop_front() {
                Some(v) => {
                    real += 1;
                    v
                }
                None => 0,
            };
            for c in 0..channels {
                out[f * channels + c] = v;
            }
        }
        real
    }

    pub fn clear(&mut self) {
        self.samples.clear();
    }
}

/// The most bytes of one packet the view is sent (message 12): 40 ms of 48 kHz mono PCM16.
pub const PACKET_MOST: usize = 3840;

/// A view's message 12: flags (bit 0 clear: 48 kHz mono PCM16), the recording's epoch (u32 big-endian), then an even
/// number of bytes of samples, none and at most `PACKET_MOST`; else None.
pub fn packet(payload: &[u8]) -> Option<(u32, &[u8])> {
    if payload.len() < 7 || payload.len() > 5 + PACKET_MOST || payload[0] & 1 != 0 || (payload.len() - 5) % 2 != 0 {
        return None;
    }
    Some((u32::from_be_bytes([payload[1], payload[2], payload[3], payload[4]]), &payload[5..]))
}

/// What a view says of a look (message 4 `{mic: {available, active, epoch}}`): available unless the look failed,
/// active only then, the epoch as the station's u32.
pub fn said(d: &Demand) -> (bool, bool, u32) {
    let available = d.error.is_none();
    (available, available && d.active, d.epoch as u32)
}

#[cfg(windows)]
#[allow(unused_imports)] // (endpoints and is_cable_endpoint: the tests')
pub use win::{WinMicFeeder, WinMicMonitor, endpoints, is_cable_endpoint};

#[cfg(windows)]
mod win {
    use super::*;
    use std::ffi::c_void;
    use std::sync::atomic::AtomicBool;
    use std::sync::mpsc::{Receiver, RecvTimeoutError, SyncSender, TrySendError, sync_channel};
    use std::sync::{Mutex, mpsc};
    use std::thread::JoinHandle;
    use std::time::Duration;
    use windows::Win32::Foundation::{PROPERTYKEY, RPC_E_CHANGED_MODE};
    use windows::Win32::Media::Audio::*;
    use windows::Win32::System::Com::StructuredStorage::{PROPVARIANT, PropVariantClear};
    use windows::Win32::System::Com::{CLSCTX_ALL, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize};
    use windows::Win32::System::WinRT::{AGILEREFERENCE_DEFAULT, IAgileReference, RoGetAgileReference};
    use windows::core::{GUID, HRESULT, IUnknown, Interface, PCWSTR, PWSTR, Ref, implement};

    /// The apartment of this thread, the multithreaded one, left last (after every interface of it is released).
    pub struct Apartment(bool);

    impl Apartment {
        pub fn enter() -> windows::core::Result<Self> {
            let hr = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
            if hr == RPC_E_CHANGED_MODE {
                return Err(windows::core::Error::new(hr, "this thread is in a single-threaded apartment already"));
            }
            hr.ok()?;
            Ok(Apartment(true))
        }
    }

    impl Drop for Apartment {
        fn drop(&mut self) {
            if self.0 {
                unsafe { CoUninitialize() };
            }
        }
    }

    /// A COM string taken and freed.
    unsafe fn take(p: PWSTR) -> String {
        if p.is_null() {
            return String::new();
        }
        let s = unsafe { p.to_string() }.unwrap_or_default();
        unsafe { CoTaskMemFree(Some(p.0 as *const c_void)) };
        s
    }

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    const PKEY_DEVICE_FRIENDLY_NAME: PROPERTYKEY = PROPERTYKEY { fmtid: GUID::from_u128(0xa45c254e_df1c_4efd_8020_67d146a850e0), pid: 14 };
    const PKEY_DEVICE_HARDWARE_IDS: PROPERTYKEY = PROPERTYKEY { fmtid: GUID::from_u128(0xa45c254e_df1c_4efd_8020_67d146a850e0), pid: 3 };
    const PKEY_DEVICE_INSTANCE_ID: PROPERTYKEY = PROPERTYKEY { fmtid: GUID::from_u128(0x78c34fc8_104a_4aca_9ea4_524d52996e57), pid: 256 };
    const VT_LPWSTR: u16 = 31;
    const VT_VECTOR: u16 = 0x1000;

    /// PROPVARIANT's layout on x64 as far as strings go: vt, then the union (an LPWSTR, or a CALPWSTR's count and array).
    #[repr(C)]
    struct RawVariant {
        vt: u16,
        reserved: [u16; 3],
        a: u64,
        b: u64,
    }
    const _: () = assert!(std::mem::size_of::<RawVariant>() == std::mem::size_of::<PROPVARIANT>());

    /// IPropertyStore, reached through the vtable: the crate's own needs a feature this crate does not build with.
    struct PropertyStore(IUnknown);

    impl PropertyStore {
        /// IMMDevice::OpenPropertyStore (vtable slot 4) with STGM_READ.
        unsafe fn of(device: &IMMDevice) -> windows::core::Result<Self> {
            type Open = unsafe extern "system" fn(*mut c_void, u32, *mut *mut c_void) -> HRESULT;
            unsafe {
                let vtable = *(device.as_raw() as *const *const usize);
                let open: Open = std::mem::transmute(*vtable.add(4));
                let mut store = std::ptr::null_mut();
                open(device.as_raw(), 0, &mut store).ok()?;
                Ok(PropertyStore(IUnknown::from_raw(store)))
            }
        }

        /// IPropertyStore::GetValue (vtable slot 5), the strings of it (one, or a vector's), the variant cleared.
        unsafe fn strings(&self, key: &PROPERTYKEY) -> Vec<String> {
            type Get = unsafe extern "system" fn(*mut c_void, *const PROPERTYKEY, *mut RawVariant) -> HRESULT;
            unsafe {
                let vtable = *(self.0.as_raw() as *const *const usize);
                let get: Get = std::mem::transmute(*vtable.add(5));
                let mut v = RawVariant { vt: 0, reserved: [0; 3], a: 0, b: 0 };
                if get(self.0.as_raw(), key, &mut v).is_err() {
                    return Vec::new();
                }
                let mut out = Vec::new();
                if v.vt == VT_LPWSTR && v.a != 0 {
                    out.push(PWSTR(v.a as *mut u16).to_string().unwrap_or_default());
                } else if v.vt == VT_VECTOR | VT_LPWSTR && v.b != 0 {
                    let items = v.b as *const PWSTR;
                    for i in 0..(v.a as u32).min(256) as usize {
                        let s = *items.add(i);
                        if !s.is_null() {
                            out.push(s.to_string().unwrap_or_default());
                        }
                    }
                }
                let _ = PropVariantClear(&mut v as *mut RawVariant as *mut PROPVARIANT);
                out
            }
        }
    }

    unsafe fn name_of(device: &IMMDevice) -> String {
        unsafe { PropertyStore::of(device).map(|p| p.strings(&PKEY_DEVICE_FRIENDLY_NAME).into_iter().next().unwrap_or_default()).unwrap_or_default() }
    }

    fn enumerator() -> windows::core::Result<IMMDeviceEnumerator> {
        unsafe { CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL) }
    }

    /// The active endpoints of a direction: (ID, full name). On a thread in the multithreaded apartment.
    pub fn endpoints(flow: EDataFlow) -> windows::core::Result<Vec<(String, String)>> {
        unsafe {
            let all = enumerator()?.EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE)?;
            let mut out = Vec::new();
            for i in 0..all.GetCount()? {
                let d = all.Item(i)?;
                out.push((take(d.GetId()?), name_of(&d)));
            }
            Ok(out)
        }
    }

    // SetupAPI, declared here: the crate's own needs a feature this crate does not build with.
    #[repr(C)]
    struct DevInfoData {
        size: u32,
        class: GUID,
        devinst: u32,
        reserved: usize,
    }
    #[link(name = "setupapi")]
    unsafe extern "system" {
        fn SetupDiCreateDeviceInfoList(class: *const GUID, parent: *mut c_void) -> isize;
        fn SetupDiOpenDeviceInfoW(set: isize, id: PCWSTR, parent: *mut c_void, flags: u32, data: *mut DevInfoData) -> i32;
        fn SetupDiGetDeviceRegistryPropertyW(set: isize, data: *const DevInfoData, property: u32, kind: *mut u32, buffer: *mut u8, size: u32, needed: *mut u32) -> i32;
        fn SetupDiDestroyDeviceInfoList(set: isize) -> i32;
    }
    const SPDRP_HARDWAREID: u32 = 1;

    /// A device instance's hardware IDs by SetupAPI (what Windows 11's property store may leave out).
    fn setup_hardware_ids(instance: &str) -> Vec<String> {
        unsafe {
            let set = SetupDiCreateDeviceInfoList(std::ptr::null(), std::ptr::null_mut());
            if set == -1 {
                return Vec::new();
            }
            let mut data = DevInfoData { size: std::mem::size_of::<DevInfoData>() as u32, class: GUID::zeroed(), devinst: 0, reserved: 0 };
            let id = wide(instance);
            let mut out = Vec::new();
            if SetupDiOpenDeviceInfoW(set, PCWSTR(id.as_ptr()), std::ptr::null_mut(), 0, &mut data) != 0 {
                let mut buf = vec![0u16; 4096];
                let mut needed = 0u32;
                if SetupDiGetDeviceRegistryPropertyW(set, &data, SPDRP_HARDWAREID, std::ptr::null_mut(), buf.as_mut_ptr() as *mut u8, (buf.len() * 2) as u32, &mut needed) != 0 {
                    buf.truncate((needed as usize / 2).min(buf.len()));
                    out = parse_multi_sz(&buf);
                }
            }
            SetupDiDestroyDeviceInfoList(set);
            out
        }
    }

    /// Whether a capture endpoint is the cable by its adapter's hardware IDs, not its name (which people can change):
    /// the property store's, else SetupAPI's by its instance ID. Anything failing is "not the cable" (this only ever
    /// excludes).
    pub fn is_cable_endpoint(endpoint_id: &str) -> bool {
        let check = || -> windows::core::Result<bool> {
            unsafe {
                let devices = enumerator()?;
                let id = wide(endpoint_id);
                let endpoint = devices.GetDevice(PCWSTR(id.as_ptr()))?;
                let topology: IDeviceTopology = endpoint.Activate(CLSCTX_ALL, None)?;
                let adapter_id = take(topology.GetConnector(0)?.GetDeviceIdConnectedTo()?);
                let aid = wide(&adapter_id);
                let adapter = devices.GetDevice(PCWSTR(aid.as_ptr()))?;
                let store = PropertyStore::of(&adapter)?;
                let ids = store.strings(&PKEY_DEVICE_HARDWARE_IDS);
                if is_cable_hardware(&ids) {
                    return Ok(true);
                }
                let instance = store.strings(&PKEY_DEVICE_INSTANCE_ID).into_iter().next().unwrap_or_default();
                Ok(!instance.is_empty() && is_cable_hardware(&setup_hardware_ids(&instance)))
            }
        };
        check().unwrap_or(false)
    }

    /// An agile reference to a new session, safe to hand to another thread.
    struct Agile(IAgileReference);
    // SAFETY: an agile reference is made to be resolved in any apartment, on any thread.
    unsafe impl Send for Agile {}

    struct Shared {
        epoch: Epoch,
        lost: AtomicBool,
        wake: Box<dyn Fn() + Send + Sync>,
    }

    #[implement(IAudioSessionNotification)]
    struct NewSessions {
        shared: Arc<Shared>,
        tx: SyncSender<Agile>,
    }

    impl IAudioSessionNotification_Impl for NewSessions_Impl {
        fn OnSessionCreated(&self, session: Ref<IAudioSessionControl>) -> windows::core::Result<()> {
            let passed = session.ok().and_then(|s| unsafe { RoGetAgileReference(AGILEREFERENCE_DEFAULT, &IAudioSessionControl::IID, s) });
            match passed.map(Agile) {
                Ok(a) => {
                    if let Err(TrySendError::Full(_) | TrySendError::Disconnected(_)) = self.tx.try_send(a) {
                        self.shared.lost.store(true, Ordering::Release);
                    }
                }
                Err(_) => self.shared.lost.store(true, Ordering::Release),
            }
            self.shared.epoch.bump();
            (self.shared.wake)();
            Ok(())
        }
    }

    #[implement(IAudioSessionEvents)]
    struct SessionEvents {
        shared: Arc<Shared>,
    }

    impl SessionEvents_Impl {
        fn changed(&self) {
            self.shared.epoch.bump();
            (self.shared.wake)();
        }
    }

    impl IAudioSessionEvents_Impl for SessionEvents_Impl {
        fn OnDisplayNameChanged(&self, _: &PCWSTR, _: *const GUID) -> windows::core::Result<()> {
            Ok(())
        }
        fn OnIconPathChanged(&self, _: &PCWSTR, _: *const GUID) -> windows::core::Result<()> {
            Ok(())
        }
        fn OnSimpleVolumeChanged(&self, _: f32, _: windows::core::BOOL, _: *const GUID) -> windows::core::Result<()> {
            Ok(())
        }
        fn OnChannelVolumeChanged(&self, _: u32, _: *const f32, _: u32, _: *const GUID) -> windows::core::Result<()> {
            Ok(())
        }
        fn OnGroupingParamChanged(&self, _: *const GUID, _: *const GUID) -> windows::core::Result<()> {
            Ok(())
        }
        fn OnStateChanged(&self, _: AudioSessionState) -> windows::core::Result<()> {
            self.changed();
            Ok(())
        }
        fn OnSessionDisconnected(&self, _: AudioSessionDisconnectReason) -> windows::core::Result<()> {
            self.changed();
            Ok(())
        }
    }

    struct Tracked {
        control: IAudioSessionControl,
        events: IAudioSessionEvents,
    }

    impl Drop for Tracked {
        fn drop(&mut self) {
            let _ = unsafe { self.control.UnregisterAudioSessionNotification(&self.events) };
        }
    }

    enum Ask {
        Sample(mpsc::Sender<Demand>),
    }

    /// Who records the cable's capture end, watched on a thread of its own (the multithreaded apartment).
    pub struct WinMicMonitor {
        asks: Option<mpsc::Sender<Ask>>,
        thread: Option<JoinHandle<()>>,
        epoch: Epoch,
    }

    struct Watch {
        device: IMMDevice,
        manager: IAudioSessionManager2,
        notifier: IAudioSessionNotification,
        new: Receiver<Agile>,
        sessions: Sessions<Tracked>,
        shared: Arc<Shared>,
    }

    impl Watch {
        fn open(id: &str, shared: Arc<Shared>) -> Result<Self, String> {
            unsafe {
                let w = wide(id);
                let device = enumerator().and_then(|d| d.GetDevice(PCWSTR(w.as_ptr()))).map_err(|e| e.to_string())?;
                let manager: IAudioSessionManager2 = device.Activate(CLSCTX_ALL, None).map_err(|e| e.to_string())?;
                let (tx, new) = sync_channel(MOST_SESSIONS);
                let notifier: IAudioSessionNotification = NewSessions { shared: shared.clone(), tx }.into();
                // Subscribed first, then listed: the list is what notices may not have been sent for.
                manager.RegisterSessionNotification(&notifier).map_err(|e| e.to_string())?;
                let mut watch = Watch { device, manager, notifier, new, sessions: Sessions::new(shared.epoch.clone()), shared };
                let list = watch.manager.GetSessionEnumerator().map_err(|e| e.to_string())?;
                let count = list.GetCount().map_err(|e| e.to_string())?;
                if count < 0 || count as usize > MOST_SESSIONS {
                    return Err(format!("{count} audio sessions on the cable"));
                }
                for i in 0..count {
                    let s = list.GetSession(i).map_err(|e| e.to_string())?;
                    watch.add(s)?;
                }
                Ok(watch)
            }
        }

        fn add(&mut self, control: IAudioSessionControl) -> Result<(), String> {
            unsafe {
                let two: IAudioSessionControl2 = control.cast().map_err(|e| e.to_string())?;
                let pid = two.GetProcessId().unwrap_or(0);
                let key = take(two.GetSessionInstanceIdentifier().map_err(|e| e.to_string())?);
                if pid == std::process::id() {
                    return Ok(());
                }
                let events: IAudioSessionEvents = SessionEvents { shared: self.shared.clone() }.into();
                control.RegisterAudioSessionNotification(&events).map_err(|e| e.to_string())?;
                // (registered before it is known to be new: one seen already is dropped, and its registration with it)
                self.sessions.add(key, pid, std::process::id(), Tracked { control, events })?;
                Ok(())
            }
        }

        fn sample(&mut self) -> Demand {
            let epoch = self.shared.epoch.get();
            if self.shared.lost.load(Ordering::Acquire) {
                self.sessions.lost = true;
            }
            match unsafe { self.device.GetState() } {
                Ok(s) if s == DEVICE_STATE_ACTIVE => {}
                _ => return Demand { active: false, epoch, error: Some("the cable's capture endpoint is gone".into()) },
            }
            for _ in 0..MOST_SESSIONS {
                let Ok(agile) = self.new.try_recv() else { break };
                match unsafe { agile.0.Resolve::<IAudioSessionControl>() } {
                    Ok(control) => {
                        if let Err(e) = self.add(control) {
                            return Demand { active: false, epoch: self.shared.epoch.get(), error: Some(e) };
                        }
                    }
                    Err(e) => return Demand { active: false, epoch: self.shared.epoch.get(), error: Some(e.to_string()) },
                }
            }
            self.sessions.sample(
                |t| match unsafe { t.control.GetState() } {
                    Ok(s) if s == AudioSessionStateActive => Ok(SessionState::Active),
                    Ok(s) if s == AudioSessionStateExpired => Ok(SessionState::Expired),
                    Ok(_) => Ok(SessionState::Inactive),
                    Err(e) => Err(e.to_string()),
                },
                drop,
            )
        }
    }

    impl Drop for Watch {
        fn drop(&mut self) {
            let _ = unsafe { self.manager.UnregisterSessionNotification(&self.notifier) };
            for t in self.sessions.drain() {
                drop(t);
            }
        }
    }

    impl WinMicMonitor {
        /// Starts watching the cable's capture end (`chosen`: its ID where there are several). `wake` is called on COM's
        /// threads when something changed: sample again then.
        pub fn start(chosen: Option<String>, wake: impl Fn() + Send + Sync + 'static) -> Result<Self, String> {
            Self::start_at(move || pick_endpoint(&endpoints(eCapture).map_err(|e| e.to_string())?, CAPTURE_NAME, chosen.as_deref()).map_err(|e| e.to_string()), wake)
        }

        /// Watching the endpoint `resolve` names, resolved on the audio thread (any endpoint: tests).
        pub(crate) fn start_at(resolve: impl FnOnce() -> Result<String, String> + Send + 'static, wake: impl Fn() + Send + Sync + 'static) -> Result<Self, String> {
            let epoch = Epoch::default();
            let shared = Arc::new(Shared { epoch: epoch.clone(), lost: AtomicBool::new(false), wake: Box::new(wake) });
            let (asks, rx) = mpsc::channel::<Ask>();
            let (ready_tx, ready_rx) = mpsc::channel::<Result<(), String>>();
            let thread = std::thread::Builder::new()
                .name("mic-demand".into())
                .spawn(move || {
                    let apartment = match Apartment::enter() {
                        Ok(a) => a,
                        Err(e) => {
                            let _ = ready_tx.send(Err(e.to_string()));
                            return;
                        }
                    };
                    let mut watch = match resolve().and_then(|id| Watch::open(&id, shared)) {
                        Ok(w) => w,
                        Err(e) => {
                            let _ = ready_tx.send(Err(e));
                            return;
                        }
                    };
                    let _ = ready_tx.send(Ok(()));
                    while let Ok(Ask::Sample(reply)) = rx.recv() {
                        let _ = reply.send(watch.sample());
                    }
                    drop(watch);
                    drop(apartment);
                })
                .map_err(|e| e.to_string())?;
            match ready_rx.recv() {
                Ok(Ok(())) => Ok(WinMicMonitor { asks: Some(asks), thread: Some(thread), epoch }),
                Ok(Err(e)) => {
                    let _ = thread.join();
                    Err(e)
                }
                Err(_) => Err("the audio thread ended".into()),
            }
        }

        pub fn epoch(&self) -> u64 {
            self.epoch.get()
        }

        pub fn sample(&self) -> Demand {
            let (tx, rx) = mpsc::channel();
            let asked = self.asks.as_ref().map(|a| a.send(Ask::Sample(tx)).is_ok()).unwrap_or(false);
            match asked.then(|| rx.recv_timeout(Duration::from_secs(2))) {
                Some(Ok(d)) => d,
                Some(Err(RecvTimeoutError::Timeout)) => Demand { active: false, epoch: self.epoch.get(), error: Some("the audio thread did not answer".into()) },
                _ => Demand { active: false, epoch: self.epoch.get(), error: Some("the audio thread ended".into()) },
            }
        }
    }

    impl Drop for WinMicMonitor {
        fn drop(&mut self) {
            self.asks.take();
            if let Some(t) = self.thread.take() {
                let _ = t.join();
            }
        }
    }

    /// Plays fed 48 kHz mono PCM16 into the cable's render end, in shared mode (Windows converting to the endpoint's
    /// format), silence when nothing is fed; never another endpoint, never the default.
    pub struct WinMicFeeder {
        queue: Arc<Mutex<FeedQueue>>,
        stop: Arc<AtomicBool>,
        thread: Option<JoinHandle<()>>,
    }

    impl WinMicFeeder {
        pub fn start(chosen: Option<String>) -> Result<Self, String> {
            Self::start_at(move || pick_endpoint(&endpoints(eRender).map_err(|e| e.to_string())?, RENDER_NAME, chosen.as_deref()).map_err(|e| e.to_string()))
        }

        /// Playing into the endpoint `resolve` names, resolved on the feed's thread (any endpoint: tests).
        pub(crate) fn start_at(resolve: impl FnOnce() -> Result<String, String> + Send + 'static) -> Result<Self, String> {
            let queue = Arc::new(Mutex::new(FeedQueue::default()));
            let stop = Arc::new(AtomicBool::new(false));
            let (ready_tx, ready_rx) = mpsc::channel::<Result<(), String>>();
            let (q, s) = (queue.clone(), stop.clone());
            let thread = std::thread::Builder::new()
                .name("mic-feed".into())
                .spawn(move || {
                    let _apartment = match Apartment::enter() {
                        Ok(a) => a,
                        Err(e) => {
                            let _ = ready_tx.send(Err(e.to_string()));
                            return;
                        }
                    };
                    let r = resolve().and_then(|id| play(&id, &q, &s, &ready_tx));
                    let _ = ready_tx.send(r);
                })
                .map_err(|e| e.to_string())?;
            match ready_rx.recv() {
                Ok(Ok(())) => Ok(WinMicFeeder { queue, stop, thread: Some(thread) }),
                Ok(Err(e)) => {
                    let _ = thread.join();
                    Err(e)
                }
                Err(_) => Err("the feed's thread ended".into()),
            }
        }

        pub fn feed(&self, pcm16le: &[u8]) {
            if let Ok(mut q) = self.queue.lock() {
                q.push_pcm16le(pcm16le);
            }
        }

        pub fn queued(&self) -> usize {
            self.queue.lock().map(|q| q.len()).unwrap_or(0)
        }

        pub fn stop(&mut self) {
            self.stop.store(true, Ordering::Release);
            if let Some(t) = self.thread.take() {
                let _ = t.join();
            }
        }
    }

    impl Drop for WinMicFeeder {
        fn drop(&mut self) {
            self.stop();
        }
    }

    fn play(id: &str, queue: &Mutex<FeedQueue>, stop: &AtomicBool, ready: &mpsc::Sender<Result<(), String>>) -> Result<(), String> {
        let e = |e: windows::core::Error| e.to_string();
        unsafe {
            let w = wide(id);
            let device = enumerator().and_then(|d| d.GetDevice(PCWSTR(w.as_ptr()))).map_err(e)?;
            let client: IAudioClient = device.Activate(CLSCTX_ALL, None).map_err(e)?;
            let format = WAVEFORMATEX { wFormatTag: 1, nChannels: 1, nSamplesPerSec: 48_000, nAvgBytesPerSec: 96_000, nBlockAlign: 2, wBitsPerSample: 16, cbSize: 0 };
            // 100 ms of buffer, in 100 ns units.
            client
                .Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY, 1_000_000, 0, &format, None)
                .map_err(e)?;
            let size = client.GetBufferSize().map_err(e)?;
            let render: IAudioRenderClient = client.GetService().map_err(e)?;
            client.Start().map_err(e)?;
            let _ = ready.send(Ok(()));
            let mut failed = None;
            while !stop.load(Ordering::Acquire) {
                let padding = match client.GetCurrentPadding() {
                    Ok(p) => p,
                    Err(err) => {
                        failed = Some(err.to_string());
                        break;
                    }
                };
                let free = size.saturating_sub(padding);
                if free > 0 {
                    match render.GetBuffer(free) {
                        Ok(p) => {
                            let out = std::slice::from_raw_parts_mut(p as *mut i16, free as usize);
                            if let Ok(mut q) = queue.lock() {
                                q.fill(out, 1);
                            } else {
                                out.fill(0);
                            }
                            let _ = render.ReleaseBuffer(free, 0);
                        }
                        Err(err) => {
                            failed = Some(err.to_string());
                            break;
                        }
                    }
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            let _ = client.Stop();
            failed.map_or(Ok(()), Err)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_views_packet_is_taken_only_whole_and_a_look_is_said_as_the_station_reads_it() {
        assert_eq!(packet(&[0, 0, 0, 0, 3, 1, 2]), Some((3, &[1u8, 2][..])));
        assert_eq!(packet(&[0, 0xff, 0xff, 0xff, 0xff, 1, 2, 3, 4]), Some((u32::MAX, &[1u8, 2, 3, 4][..])));
        // Too short, odd, flags set, too long.
        assert_eq!(packet(&[0, 0, 0, 0, 3]), None);
        assert_eq!(packet(&[0, 0, 0, 0, 3, 1]), None);
        assert_eq!(packet(&[0, 0, 0, 0, 3, 1, 2, 3]), None);
        assert_eq!(packet(&[1, 0, 0, 0, 3, 1, 2]), None);
        let mut most = vec![0u8; 5 + PACKET_MOST];
        assert!(packet(&most).is_some());
        most.extend_from_slice(&[0, 0]);
        assert_eq!(packet(&most), None);
        assert_eq!(said(&Demand { active: true, epoch: 7, error: None }), (true, true, 7));
        assert_eq!(said(&Demand { active: true, epoch: (1 << 32) + 2, error: Some("gone".into()) }), (false, false, 2));
        assert_eq!(said(&Demand { active: false, epoch: 3, error: None }), (true, false, 3));
    }

    fn eps(list: &[(&str, &str)]) -> Vec<(String, String)> {
        list.iter().map(|(a, b)| (a.to_string(), b.to_string())).collect()
    }

    #[test]
    fn endpoints_are_picked_by_their_full_name_one_or_none_never_the_first_of_many() {
        let one = eps(&[("{0.0.0}.{spk}", "Speakers (Realtek(R) Audio)"), ("{0.0.0}.{cable}", RENDER_NAME)]);
        assert_eq!(pick_endpoint(&one, RENDER_NAME, None), Ok("{0.0.0}.{cable}".into()));
        // The short name, or the default, is no match.
        assert_eq!(pick_endpoint(&eps(&[("x", "CABLE Input")]), RENDER_NAME, None), Err(EndpointError::Missing(RENDER_NAME.into())));
        assert_eq!(pick_endpoint(&[], CAPTURE_NAME, None), Err(EndpointError::Missing(CAPTURE_NAME.into())));
        let two = eps(&[("a", RENDER_NAME), ("b", RENDER_NAME)]);
        assert_eq!(pick_endpoint(&two, RENDER_NAME, None), Err(EndpointError::Ambiguous(vec!["a".into(), "b".into()])));
        assert_eq!(pick_endpoint(&two, RENDER_NAME, Some("b")), Ok("b".into()));
        assert_eq!(pick_endpoint(&two, RENDER_NAME, Some("c")), Err(EndpointError::Missing(RENDER_NAME.into())));
    }

    #[test]
    fn the_cable_is_known_by_its_hardware_id_in_any_case_from_a_multi_sz() {
        let w: Vec<u16> = "ROOT\\vbaudiovacwdm\0VBAudioVACMME\0\0garbage".encode_utf16().collect();
        let ids = parse_multi_sz(&w);
        assert_eq!(ids, vec!["ROOT\\vbaudiovacwdm".to_string(), "VBAudioVACMME".to_string()]);
        assert!(is_cable_hardware(&ids));
        assert!(!is_cable_hardware(&["HDAUDIO\\FUNC_01&VEN_10EC", "USB\\VID_046D"]));
        assert!(!is_cable_hardware::<&str>(&[]));
        assert!(parse_multi_sz(&[0, 0]).is_empty());
        assert!(is_cable_name("CABLE Output (VB-Audio Virtual Cable)"));
        assert!(!is_cable_name("Microphone (USB Audio)"));
    }

    #[test]
    fn only_an_active_session_of_another_process_is_demand_and_expired_ones_go() {
        let epoch = Epoch::default();
        let mut s: Sessions<&str> = Sessions::new(epoch.clone());
        assert_eq!(s.add("own".into(), 7, 7, "own"), Ok(Added::Own));
        assert_eq!(epoch.get(), 1, "our own session changes nothing");
        assert_eq!(s.add("sys".into(), 0, 7, "sys"), Ok(Added::Tracked));
        assert_eq!(s.add("app".into(), 42, 7, "app"), Ok(Added::Tracked));
        assert_eq!(s.add("app".into(), 42, 7, "app2"), Ok(Added::Again));
        assert_eq!(epoch.get(), 3);
        let states = |active: &'static [&'static str], expired: &'static [&'static str]| {
            move |t: &&str| {
                Ok(if expired.contains(t) {
                    SessionState::Expired
                } else if active.contains(t) {
                    SessionState::Active
                } else {
                    SessionState::Inactive
                })
            }
        };
        // The system's sounds session and an app that opened but does not record: Inactive, no demand.
        assert_eq!(s.sample(states(&[], &[]), drop), Demand { active: false, epoch: 3, error: None });
        assert_eq!(s.sample(states(&["app"], &[]), drop), Demand { active: true, epoch: 3, error: None });
        let mut let_go = vec![];
        assert_eq!(s.sample(states(&[], &["app"]), |t| let_go.push(t)), Demand { active: false, epoch: 4, error: None });
        assert_eq!(let_go, vec!["app"]);
        assert_eq!(s.len(), 1);
        // A new lifetime of the app is a new session: a new epoch, so the old one is retired even if never seen inactive.
        assert_eq!(s.add("app-2".into(), 42, 7, "app"), Ok(Added::Tracked));
        assert_eq!(s.sample(states(&["app"], &[]), drop).epoch, 5);
    }

    #[test]
    fn an_error_or_a_lost_notice_is_no_demand_and_there_are_at_most_128() {
        let mut s: Sessions<u32> = Sessions::new(Epoch::default());
        s.add("a".into(), 1, 7, 1).unwrap();
        s.add("b".into(), 2, 7, 2).unwrap();
        let d = s.sample(|t| if *t == 2 { Err("0x88890004".into()) } else { Ok(SessionState::Active) }, drop);
        assert_eq!((d.active, d.error.as_deref()), (false, Some("0x88890004")));
        assert_eq!(s.len(), 2, "a session failing to answer is kept, asked again next time");
        s.lost = true;
        let d = s.sample(|_| Ok(SessionState::Active), drop);
        assert!(!d.active && d.error.is_some());
        let mut full: Sessions<()> = Sessions::new(Epoch::default());
        for i in 0..MOST_SESSIONS {
            full.add(format!("s{i}"), 100 + i as u32, 7, ()).unwrap();
        }
        assert!(full.add("one more".into(), 1, 7, ()).is_err());
        assert_eq!(full.add("s0".into(), 100, 7, ()), Ok(Added::Again));
    }

    #[test]
    fn the_epoch_moves_on_for_every_change_heard_from_other_threads() {
        let epoch = Epoch::default();
        let threads: Vec<_> = (0..4)
            .map(|_| {
                let e = epoch.clone();
                std::thread::spawn(move || (0..1000).for_each(|_| e.bump()))
            })
            .collect();
        threads.into_iter().for_each(|t| t.join().unwrap());
        assert_eq!(epoch.get(), 4001);
    }

    #[test]
    fn the_feed_plays_in_order_pads_with_silence_keeps_the_newest_100ms_and_copies_mono_to_stereo() {
        let mut q = FeedQueue::default();
        let pcm = |v: &[i16]| v.iter().flat_map(|s| s.to_le_bytes()).collect::<Vec<u8>>();
        q.push_pcm16le(&pcm(&[1, 2, 3]));
        q.push_pcm16le(&[9]); // half a sample: nothing
        let mut out = [7i16; 5];
        assert_eq!(q.fill(&mut out, 1), 3);
        assert_eq!(out, [1, 2, 3, 0, 0]);
        assert_eq!(q.fill(&mut out, 1), 0);
        assert_eq!(out, [0; 5], "an underrun is silence, never the old samples");
        q.push_pcm16le(&pcm(&[5, -6]));
        let mut stereo = [1i16; 6];
        assert_eq!(q.fill(&mut stereo, 2), 2);
        assert_eq!(stereo, [5, 5, -6, -6, 0, 0]);
        let many: Vec<i16> = (0..6000).map(|i| (i % 30000) as i16).collect();
        q.push_pcm16le(&pcm(&many));
        assert_eq!((q.len(), q.dropped), (FEED_MOST_FRAMES, 1200));
        let mut all = vec![0i16; FEED_MOST_FRAMES];
        q.fill(&mut all, 1);
        assert_eq!((all[0], all[FEED_MOST_FRAMES - 1]), (1200, 5999));
    }

    /// On Windows: the endpoints are listed; where the cable is installed, its capture end is watched (no recorder: no
    /// demand, or an error, never a guess) and its render end fed.
    #[cfg(windows)]
    #[test]
    fn live_endpoints_monitor_and_feeder() {
        use windows::Win32::Media::Audio::{eCapture, eRender};
        let listed = std::thread::spawn(|| {
            let _a = win::Apartment::enter().unwrap();
            (endpoints(eRender).unwrap(), endpoints(eCapture).unwrap())
        })
        .join()
        .unwrap();
        let (render, capture) = listed;
        eprintln!("render endpoints: {:?}", render.iter().map(|e| &e.1).collect::<Vec<_>>());
        eprintln!("capture endpoints: {:?}", capture.iter().map(|e| &e.1).collect::<Vec<_>>());
        match WinMicMonitor::start(None, || {}) {
            Ok(m) => {
                let d = m.sample();
                eprintln!("cable demand: {d:?}");
                assert!(d.epoch >= 1);
                if d.error.is_some() {
                    assert!(!d.active);
                }
                if let Ok(id) = pick_endpoint(&capture, CAPTURE_NAME, None) {
                    let cable = std::thread::spawn(move || {
                        let _a = win::Apartment::enter().unwrap();
                        is_cable_endpoint(&id)
                    })
                    .join()
                    .unwrap();
                    eprintln!("capture end is the cable by hardware ID: {cable}");
                }
            }
            Err(e) => {
                eprintln!("no cable to watch: {e}");
                assert!(pick_endpoint(&capture, CAPTURE_NAME, None).is_err());
            }
        }
        // The same sequence on whatever real endpoint this machine has (the cable or not): its sessions listed and
        // asked, our own playback's session not demand, and its adapter not taken for the cable.
        if let Some((id, name)) = render.first().cloned() {
            let cable = {
                let id = id.clone();
                std::thread::spawn(move || {
                    let _a = win::Apartment::enter().unwrap();
                    is_cable_endpoint(&id)
                })
                .join()
                .unwrap()
            };
            assert!(!cable || is_cable_name(&name), "{name} taken for the cable");
            let watched = {
                let id = id.clone();
                WinMicMonitor::start_at(move || Ok(id), || {}).expect("watching a real endpoint's sessions")
            };
            let before = watched.sample();
            eprintln!("{name}: {before:?}");
            assert_eq!(before.error, None);
            let mut own = {
                let id = id.clone();
                WinMicFeeder::start_at(move || Ok(id)).expect("silence into a real endpoint")
            };
            own.feed(&[0u8; 1920]);
            std::thread::sleep(std::time::Duration::from_millis(100));
            let during = watched.sample();
            eprintln!("{name} with our own silence playing: {during:?}");
            assert_eq!(during.error, None);
            assert!(!during.active || before.active, "our own session became demand");
            own.stop();
        }
        match WinMicFeeder::start(None) {
            Ok(mut f) => {
                f.feed(&[0u8; 1920]);
                std::thread::sleep(std::time::Duration::from_millis(60));
                f.stop();
            }
            Err(e) => {
                eprintln!("no cable to feed: {e}");
                assert!(pick_endpoint(&render, RENDER_NAME, None).is_err());
            }
        }
    }
}
