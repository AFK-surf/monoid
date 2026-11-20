// A virtual microphone on this Mac, the receiving side (virtual-mic spec §1, §3): what records it is read, never assumed,
// and what the station is sent from another machine's microphone is played into it only while something does.
//
// - `AudioRingBuffer` and `MicLoopback`: the lock-free, allocation-free ring of absolute frames the virtual device's two
//   halves share (the feed device writes, any number of readers of the input read the same samples, D frames behind;
//   a slot half written or overwritten reads as silence), and its IO semantics (§1.4, §1.5). The driver itself is an
//   AudioServerPlugIn of its own; this is its model, and what tests hold it to.
// - `MacMicDemandMonitor`: whether any other process records the virtual input, by CoreAudio's read-only properties,
//   with listeners keyed by an integer token, never a pointer, so a late callback after it is gone is harmless (§1.7,
//   §3.9). It knows still.fail's own device pair and, on a developer's Mac, a loopback device (BlackHole, VB-Cable),
//   never a physical microphone.
// - `MacMicFeeder`: plays 48 kHz mono PCM16 into the feed device by its UID, never the system's default output.
// - `MicCaptureGate`, `MicLeaseTable`, `MicReceiverDemand`: the pure state of the source's capture (permission ×
//   lease × audible, §3.2), its leases to receivers (§3.3) and the receiver's demand lifetimes (§1.7's epoch).
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

// MARK: - The ring (§1.4)

@available(macOS 15.0, *)
final class AudioRingBuffer: @unchecked Sendable {
  /// 16384 frames, 341 ms at 48 kHz.
  static let capacity = 16384
  /// How far the input reads behind the feed: the input device's latency (21.33 ms).
  static let readDelay = 1024
  static let empty = UInt64.max

  private let tags: UnsafeMutablePointer<Atomic<UInt64>>
  private let values: UnsafeMutablePointer<Atomic<UInt32>>

  init() {
    tags = .allocate(capacity: Self.capacity)
    values = .allocate(capacity: Self.capacity)
    for i in 0..<Self.capacity {
      (tags + i).initialize(to: Atomic(Self.empty))
      (values + i).initialize(to: Atomic(0))
    }
  }

  deinit {
    tags.deinitialize(count: Self.capacity)
    values.deinitialize(count: Self.capacity)
    tags.deallocate()
    values.deallocate()
  }

  @inline(__always) private static func slot(_ frame: UInt64) -> Int { Int(frame % UInt64(capacity)) }

  /// Frame `frame`'s sample: the slot marked empty while its value changes, then tagged with the frame.
  func write(_ frame: UInt64, _ sample: Float) {
    let s = Self.slot(frame)
    tags[s].store(Self.empty, ordering: .sequentiallyConsistent)
    values[s].store(sample.bitPattern, ordering: .sequentiallyConsistent)
    tags[s].store(frame, ordering: .sequentiallyConsistent)
  }

  /// Frame `frame`'s sample, or 0 when the slot holds another frame, none, or is being written (its tag read twice).
  func read(_ frame: UInt64) -> Float {
    let s = Self.slot(frame)
    guard frame != Self.empty, tags[s].load(ordering: .sequentiallyConsistent) == frame else { return 0 }
    let bits = values[s].load(ordering: .sequentiallyConsistent)
    guard tags[s].load(ordering: .sequentiallyConsistent) == frame else { return 0 }
    return Float(bitPattern: bits)
  }

  /// Every slot empty (only while the feed's IO is stopped).
  func clear() {
    for i in 0..<Self.capacity { tags[i].store(Self.empty, ordering: .sequentiallyConsistent) }
  }

  /// A write of `frame` begun and not finished, as a reader racing it sees the slot (tests).
  func beginWrite(_ frame: UInt64) {
    tags[Self.slot(frame)].store(Self.empty, ordering: .sequentiallyConsistent)
  }
}

/// The virtual device's two halves over one ring (§1.5): the feed's StartIO and StopIO clear it, the input reads
/// silence unless the feed is writing.
@available(macOS 15.0, *)
final class MicLoopback: @unchecked Sendable {
  let ring = AudioRingBuffer()
  private let writing = Atomic<Bool>(false)

  func startFeed() {
    ring.clear()
    writing.store(true, ordering: .sequentiallyConsistent)
  }

  func stopFeed() {
    writing.store(false, ordering: .sequentiallyConsistent)
    ring.clear()
  }

  /// The feed device's mixed output at sample time `time`.
  func writeMixed(at time: Double, _ samples: UnsafeBufferPointer<Float>) {
    guard time.isFinite, time >= 0 else { return }
    let base = UInt64(time.rounded(.down))
    for (i, v) in samples.enumerated() { ring.write(base + UInt64(i), v) }
  }

  /// The input device's client buffer at sample time `time`: silence unless the feed is writing and `time` is past D.
  func readInput(at time: Double, into out: UnsafeMutableBufferPointer<Float>) {
    for i in out.indices { out[i] = 0 }
    let d = Double(AudioRingBuffer.readDelay)
    guard writing.load(ordering: .sequentiallyConsistent), time.isFinite, time >= d else { return }
    let base = UInt64(time.rounded(.down)) - UInt64(AudioRingBuffer.readDelay)
    for i in out.indices { out[i] = ring.read(base + UInt64(i)) }
  }
}

// MARK: - Which devices are the virtual microphone (§1.2, §3.5)

/// still.fail's own driver's device UIDs.
enum MicUIDs {
  static let input = "fail.still.microphone.input.v1"
  static let feed = "fail.still.microphone.feed.v1"
}

struct MicHALDevice: Equatable {
  var id: AudioObjectID
  var uid: String
  var name: String
  /// kAudioDevicePropertyTransportType; 0 when it could not be read.
  var transport: UInt32
  var hasInput: Bool
  var hasOutput: Bool
}

/// The virtual input watched for demand, and the device the station plays into for it (the same device for a loopback).
struct MicDevicePair: Equatable {
  var input: MicHALDevice
  var feed: MicHALDevice
  var shared: Bool { input.id == feed.id }
}

enum MicPairError: Error, Equatable, CustomStringConvertible {
  case notLoaded
  case feedMissing
  case ambiguous([String])
  case physical(String)

  var description: String {
    switch self {
    case .notLoaded: return "no virtual microphone is loaded"
    case .feedMissing: return "the virtual microphone's feed device is not loaded"
    case .ambiguous(let names): return "more than one loopback device of one name: \(names.joined(separator: ", "))"
    case .physical(let name): return "\(name) is a physical device, not a virtual microphone"
    }
  }
}

func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

enum MicDevices {
  /// Transports of real hardware (§3.5): a device of one of them is never taken for a virtual microphone.
  static let physical: Set<UInt32> = Set(["bltn", "usb ", "blue", "blea", "pci ", "1394", "thun", "hdmi", "dprt"].map(fourCC))
  static let virtual = fourCC("virt")
  /// Loopback devices a developer's Mac may have, in the order preferred: each is its own input and feed.
  static let loopbacks = ["BlackHole 2ch", "BlackHole 16ch", "VB-Cable"]

  static func pair(_ devices: [MicHALDevice]) -> Result<MicDevicePair, MicPairError> {
    if let input = devices.first(where: { $0.uid == MicUIDs.input }) {
      if physical.contains(input.transport) { return .failure(.physical(input.name)) }
      guard let feed = devices.first(where: { $0.uid == MicUIDs.feed && $0.hasOutput }) else { return .failure(.feedMissing) }
      return .success(MicDevicePair(input: input, feed: feed))
    }
    for name in loopbacks {
      let found = devices.filter { $0.name == name }
      if found.isEmpty { continue }
      if found.count > 1 { return .failure(.ambiguous(found.map { "\($0.name) (\($0.uid))" })) }
      let d = found[0]
      // (a loopback only as the virtual device it is: never one whose transport is hardware, or unknown)
      guard d.transport == virtual, d.hasInput, d.hasOutput else { return .failure(.physical(d.name)) }
      return .success(MicDevicePair(input: d, feed: d))
    }
    return .failure(.notLoaded)
  }
}

// MARK: - CoreAudio, read only

/// What the monitor reads of CoreAudio, a fake in tests.
protocol MicHAL: AnyObject {
  func devices() throws -> [MicHALDevice]
  /// kAudioDevicePropertyDeviceIsRunningSomewhere ('gone'): any process's IO on the device.
  func isRunningSomewhere(_ id: AudioObjectID) throws -> Bool
  /// Whether a process other than `pid` runs input on the device (the process objects of macOS 14).
  func othersRecording(_ id: AudioObjectID, excluding pid: pid_t) throws -> Bool
  func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, token: Int) -> OSStatus
  func removeListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, token: Int) -> OSStatus
}

struct MicHALError: Error, CustomStringConvertible {
  var what: String
  var status: OSStatus
  var description: String { "\(what) failed (\(status))" }
}

/// Listeners' tokens: a token's epoch and its wake, looked up from the HAL's thread. A token gone is a callback ignored.
enum MicListenerRegistry {
  final class Entry: @unchecked Sendable {
    let lock = NSLock()
    private var value: UInt64 = 1
    let wake: () -> Void
    /// A change heard on it is a new lifetime (the input's own, the devices, coreaudiod): false for one that only wakes
    /// its owner to look again (the system's process list, which any app's audio changes).
    let bumps: Bool
    init(wake: @escaping () -> Void, bumps: Bool = true) {
      self.wake = wake
      self.bumps = bumps
    }
    var epoch: UInt64 { lock.withLock { value } }
    func bump() { lock.withLock { value &+= 1 } }
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var entries: [Int: Entry] = [:]
  nonisolated(unsafe) private static var next = 0

  static func register(wake: @escaping () -> Void, bumps: Bool = true) -> (Int, Entry) {
    lock.withLock {
      next += 1
      let entry = Entry(wake: wake, bumps: bumps)
      entries[next] = entry
      return (next, entry)
    }
  }

  static func unregister(_ token: Int) { _ = lock.withLock { entries.removeValue(forKey: token) } }

  /// A property changed for `token`: its epoch moves on (where it `bumps`) and it is woken. Nothing of the HAL is asked
  /// here.
  static func fire(_ token: Int) {
    guard let entry = lock.withLock({ entries[token] }) else { return }
    if entry.bumps { entry.bump() }
    entry.wake()
  }
}

/// The listener every token's registration uses; its client data is the token itself.
let micListenerProc: AudioObjectPropertyListenerProc = { _, _, _, data in
  MicListenerRegistry.fire(Int(bitPattern: data))
  return noErr
}

final class CoreAudioHAL: MicHAL {
  private func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }

  private func ids(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
    var a = address(selector, scope)
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size)
    guard status == noErr else { throw MicHALError(what: "listing \(selector)", status: status) }
    var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    status = list.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0.baseAddress!) }
    guard status == noErr else { throw MicHALError(what: "listing \(selector)", status: status) }
    return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
  }

  private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var a = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr, let v = value else { return nil }
    return v.takeRetainedValue() as String
  }

  private func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> UInt32 {
    var a = address(selector, scope)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value)
    guard status == noErr else { throw MicHALError(what: "reading \(selector)", status: status) }
    return value
  }

  private func hasStreams(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool {
    var a = address(kAudioDevicePropertyStreams, scope)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr && size >= UInt32(MemoryLayout<AudioStreamID>.size)
  }

  func devices() throws -> [MicHALDevice] {
    try ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).compactMap { id in
      guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
      return MicHALDevice(
        id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? "",
        transport: (try? uint32(id, kAudioDevicePropertyTransportType)) ?? 0,
        hasInput: hasStreams(id, kAudioObjectPropertyScopeInput), hasOutput: hasStreams(id, kAudioObjectPropertyScopeOutput))
    }
  }

  func isRunningSomewhere(_ id: AudioObjectID) throws -> Bool {
    try uint32(id, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0
  }

  func othersRecording(_ id: AudioObjectID, excluding pid: pid_t) throws -> Bool {
    for process in try ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
      guard let p = try? uint32(process, kAudioProcessPropertyPID), pid_t(bitPattern: p) != pid else { continue }
      guard (try? uint32(process, kAudioProcessPropertyIsRunningInput)) ?? 0 != 0 else { continue }
      if (try? ids(process, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput))?.contains(id) == true { return true }
    }
    return false
  }

  func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, token: Int) -> OSStatus {
    var a = address(selector)
    return AudioObjectAddPropertyListener(object, &a, micListenerProc, UnsafeMutableRawPointer(bitPattern: token))
  }

  func removeListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, token: Int) -> OSStatus {
    var a = address(selector)
    return AudioObjectRemovePropertyListener(object, &a, micListenerProc, UnsafeMutableRawPointer(bitPattern: token))
  }
}

// MARK: - Demand (§1.7)

/// One look at the demand: anything unknown, missing or unreadable is inactive, with its error.
struct MicDemandSample: Equatable {
  var active: Bool
  var epoch: UInt64
  var device: String?
  var error: String?
}

/// Whether anything records the virtual input. Subscribed first, then read; sampled on one thread of its owner's.
final class MacMicDemandMonitor {
  static let system = AudioObjectID(kAudioObjectSystemObject)
  static let devicesChanged = kAudioHardwarePropertyDevices
  static let serviceRestarted = kAudioHardwarePropertyServiceRestarted
  static let processesChanged = kAudioHardwarePropertyProcessObjectList
  static let runningSomewhere = kAudioDevicePropertyDeviceIsRunningSomewhere

  private let hal: MicHAL
  private let pid: pid_t
  let token: Int
  private let entry: MicListenerRegistry.Entry
  /// The process list's own token: it only wakes (any app's audio starting or stopping changes it), so another app is
  /// never a new epoch; what records a loopback of one device is told only by it, looked at again.
  let processToken: Int
  /// The input device the 'gone' listener is on.
  private(set) var watched: AudioObjectID?
  private var closed = false

  /// `wake`: called on the HAL's thread when something changed (sample again then).
  init(hal: MicHAL = CoreAudioHAL(), pid: pid_t = getpid(), wake: @escaping () -> Void = {}) throws {
    self.hal = hal
    self.pid = pid
    (token, entry) = MicListenerRegistry.register(wake: wake)
    (processToken, _) = MicListenerRegistry.register(wake: wake, bumps: false)
    var added: [(AudioObjectPropertySelector, Int)] = []
    for (selector, t) in [(Self.devicesChanged, token), (Self.serviceRestarted, token), (Self.processesChanged, processToken)] {
      let status = hal.addListener(Self.system, selector, token: t)
      guard status == noErr else {
        for (s, t) in added { _ = hal.removeListener(Self.system, s, token: t) }
        MicListenerRegistry.unregister(token)
        MicListenerRegistry.unregister(processToken)
        throw MicHALError(what: "listening to the audio system", status: status)
      }
      added.append((selector, t))
    }
  }

  var epoch: UInt64 { entry.epoch }

  func sample() -> MicDemandSample {
    if closed { return MicDemandSample(active: false, epoch: entry.epoch, error: "closed") }
    let pair: MicDevicePair
    do {
      switch MicDevices.pair(try hal.devices()) {
      case .success(let p): pair = p
      case .failure(let e):
        move(to: nil)
        return MicDemandSample(active: false, epoch: entry.epoch, error: e.description)
      }
    } catch {
      return MicDemandSample(active: false, epoch: entry.epoch, error: "\(error)")
    }
    guard move(to: pair.input.id) else {
      return MicDemandSample(active: false, epoch: entry.epoch, device: pair.input.uid, error: "listening to \(pair.input.name) failed")
    }
    do {
      // A loopback's own feed is the station's IO on the same device: only other processes' input is demand there.
      let active = pair.shared ? try hal.othersRecording(pair.input.id, excluding: pid) : try hal.isRunningSomewhere(pair.input.id)
      return MicDemandSample(active: active, epoch: entry.epoch, device: pair.input.uid)
    } catch {
      return MicDemandSample(active: false, epoch: entry.epoch, device: pair.input.uid, error: "\(error)")
    }
  }

  /// The 'gone' listener moved to `id` (a new device, none, an ID reused after coreaudiod restarted): a new epoch.
  /// False: the listener could not be added (tried again on the next sample).
  @discardableResult
  private func move(to id: AudioObjectID?) -> Bool {
    guard id != watched else { return true }
    let moved = watched != nil
    if let old = watched { _ = hal.removeListener(old, Self.runningSomewhere, token: token) }
    watched = nil
    var listening = true
    if let id {
      if hal.addListener(id, Self.runningSomewhere, token: token) == noErr { watched = id } else { listening = false }
    }
    if moved || watched != nil { entry.bump() }
    return listening
  }

  func close() {
    guard !closed else { return }
    closed = true
    MicListenerRegistry.unregister(token)
    MicListenerRegistry.unregister(processToken)
    if let old = watched { _ = hal.removeListener(old, Self.runningSomewhere, token: token) }
    watched = nil
    _ = hal.removeListener(Self.system, Self.processesChanged, token: processToken)
    for selector in [Self.serviceRestarted, Self.devicesChanged] { _ = hal.removeListener(Self.system, selector, token: token) }
  }

  deinit { close() }
}

// MARK: - The feed

/// PCM16 waiting to be played, at most `most` frames (the oldest dropped first); a buffer filled from it is padded with
/// silence.
struct MicFeedQueue {
  /// 100 ms at 48 kHz.
  static let most = 4800
  private var samples: [Int16] = []
  private var head = 0
  private(set) var dropped = 0

  var count: Int { samples.count - head }

  mutating func append(pcm16le: Data) {
    pcm16le.withUnsafeBytes { raw in
      let n = raw.count / 2
      samples.reserveCapacity(samples.count + n)
      for i in 0..<n { samples.append(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: 2 * i, as: Int16.self))) }
    }
    if count > Self.most {
      dropped += count - Self.most
      head = samples.count - Self.most
    }
    if head > 8192 {
      samples.removeFirst(head)
      head = 0
    }
  }

  /// `out` filled with what is queued, the rest silence; how many frames were real.
  mutating func fill(_ out: UnsafeMutableBufferPointer<Int16>) -> Int {
    let n = min(out.count, count)
    for i in 0..<n { out[i] = samples[head + i] }
    for i in n..<out.count { out[i] = 0 }
    head += n
    if head == samples.count {
      samples.removeAll(keepingCapacity: true)
      head = 0
    }
    return n
  }

  mutating func clear() {
    samples.removeAll(keepingCapacity: true)
    head = 0
  }
}

/// Plays fed 48 kHz mono PCM16 into one device by its UID through an AudioQueue of three 20 ms buffers, silence when
/// nothing is fed. Never the system's default output: a device it cannot be bound to is an error.
final class MacMicFeeder: @unchecked Sendable {
  static let rate = 48_000.0
  static let framesPerBuffer = 960
  let deviceUID: String
  private let dispatch = DispatchQueue(label: "fail.still.helper.mic-feed", qos: .userInteractive)
  private let lock = NSLock()
  private var pending = MicFeedQueue()
  private var queue: AudioQueueRef?

  init(deviceUID: String) { self.deviceUID = deviceUID }

  var running: Bool { lock.withLock { queue != nil } }

  func start() throws {
    guard !running else { return }
    var format = AudioStreamBasicDescription(
      mSampleRate: Self.rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
      mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
    var q: AudioQueueRef?
    var status = AudioQueueNewOutputWithDispatchQueue(&q, &format, 0, dispatch) { [weak self] aq, buffer in
      self?.refill(buffer)
      AudioQueueEnqueueBuffer(aq, buffer, 0, nil)
    }
    guard status == noErr, let q else { throw MicHALError(what: "making the feed's audio queue", status: status) }
    var uid: CFString = deviceUID as CFString
    status = AudioQueueSetProperty(q, kAudioQueueProperty_CurrentDevice, &uid, UInt32(MemoryLayout<CFString>.size))
    guard status == noErr else {
      AudioQueueDispose(q, true)
      throw MicHALError(what: "binding the feed to \(deviceUID)", status: status)
    }
    for _ in 0..<3 {
      var buffer: AudioQueueBufferRef?
      status = AudioQueueAllocateBuffer(q, UInt32(Self.framesPerBuffer * 2), &buffer)
      guard status == noErr, let buffer else {
        AudioQueueDispose(q, true)
        throw MicHALError(what: "allocating the feed's buffers", status: status)
      }
      refill(buffer)
      AudioQueueEnqueueBuffer(q, buffer, 0, nil)
    }
    status = AudioQueueStart(q, nil)
    guard status == noErr else {
      AudioQueueDispose(q, true)
      throw MicHALError(what: "starting the feed on \(deviceUID)", status: status)
    }
    lock.withLock { queue = q }
  }

  private func refill(_ buffer: AudioQueueBufferRef) {
    let frames = Self.framesPerBuffer
    let out = UnsafeMutableBufferPointer(start: buffer.pointee.mAudioData.assumingMemoryBound(to: Int16.self), count: frames)
    _ = lock.withLock { pending.fill(out) }
    buffer.pointee.mAudioDataByteSize = UInt32(frames * 2)
  }

  /// 48 kHz mono little-endian PCM16; dropped when not running.
  func feed(_ pcm16le: Data) {
    lock.withLock {
      guard queue != nil else { return }
      pending.append(pcm16le: pcm16le)
    }
  }

  func stop() {
    guard let q = lock.withLock({ () -> AudioQueueRef? in
      let q = queue
      queue = nil
      pending.clear()
      return q
    }) else { return }
    AudioQueueStop(q, true)
    AudioQueueDispose(q, true)
  }

  deinit { stop() }
}

// MARK: - The source's capture (§3.2)

enum MicCaptureDecision: Equatable {
  /// No capture stream, no encoder, no sleep kept.
  case closed
  /// The stream released, the lease kept; `sleepBurst` said to receivers every tick.
  case mutedHold(sleepBurst: UInt32)
  /// Capturing with an encoder of burst `burst`.
  case open(burst: UInt32)
}

/// Permission × lease × audible: only all three open the microphone. Burst numbers only grow, so each new stretch
/// (a sleep, an encoder after it) is told apart by receivers.
struct MicCaptureGate {
  private(set) var lastBurst: UInt32 = 0
  private var held: UInt32?
  private var openBurst: UInt32?

  mutating func tick(permitted: Bool, leased: Bool, audible: Bool) -> MicCaptureDecision {
    guard permitted, leased else {
      held = nil
      openBurst = nil
      return .closed
    }
    if !audible {
      openBurst = nil
      if held == nil {
        lastBurst &+= 1
        held = lastBurst
      }
      return .mutedHold(sleepBurst: held!)
    }
    held = nil
    if openBurst == nil {
      lastBurst &+= 1
      openBurst = lastBurst
    }
    return .open(burst: openBurst!)
  }

  /// Audible: not muted and above zero volume.
  static func audible(muted: Bool, volumePercent: Int) -> Bool { !muted && volumePercent > 0 }
}

// MARK: - Leases (§3.3)

/// The receiver's output for one demand lifetime.
struct MicOutputBinding: Hashable {
  var receiverBoot: String
  /// max(the demand's epoch, 1)
  var demandEpoch: UInt64
  var outputEndpoint: String
}

/// What every message of one receiving session carries; compared whole.
struct MicSessionID: Hashable {
  var sourceBoot: String
  var output: MicOutputBinding
  var claimStamp: UInt64
  var nonce: [UInt8]
}

enum MicLeaseRefusal: Error, Equatable {
  case bootStale
  case routeChanged
  case outputUnavailable
  case busy
  case stateConflict
}

/// The source's own state the leases are checked against.
struct MicSourceState {
  var selfID: String
  var boot: String
  var claimHolder: String
  var claimStamp: UInt64
  var claimAvailable: Bool
}

struct MicLease: Equatable {
  var session: MicSessionID
  var streamID: UInt64
  var ready: Bool
  /// Milliseconds: expired from this moment on.
  var expiry: UInt64
}

struct MicLeaseTable {
  static let renewMs: UInt64 = 300
  static let leaseMs: UInt64 = 1500
  static let mostReceivers = 16

  /// One lease per receiving peer.
  private(set) var leases: [String: MicLease] = [:]
  private var generation: UInt64 = 0

  private func check(_ s: MicSessionID, peer: String, peerBoot: String, _ state: MicSourceState) -> MicLeaseRefusal? {
    if s.sourceBoot != state.boot || s.output.receiverBoot != peerBoot { return .bootStale }
    if s.claimStamp != state.claimStamp || state.claimHolder != state.selfID || !state.claimAvailable || peer == state.selfID { return .routeChanged }
    if s.output.outputEndpoint.isEmpty { return .outputUnavailable }
    return nil
  }

  /// A receiver's demand: its prepared stream (the same one again for the same live session), or why not.
  mutating func demand(_ s: MicSessionID, peer: String, peerBoot: String, state: MicSourceState, now: UInt64) -> Result<UInt64, MicLeaseRefusal> {
    if let refusal = check(s, peer: peer, peerBoot: peerBoot, state) { return .failure(refusal) }
    if let lease = leases[peer], lease.session == s, now < lease.expiry { return .success(lease.streamID) }
    if leases[peer] == nil, leases.count >= Self.mostReceivers { return .failure(.busy) }
    generation += 1
    leases[peer] = MicLease(session: s, streamID: generation, ready: false, expiry: now + Self.leaseMs)
    return .success(generation)
  }

  private func live(_ s: MicSessionID, stream: UInt64, peer: String, now: UInt64) -> MicLease? {
    guard let lease = leases[peer], lease.session == s, lease.streamID == stream, now < lease.expiry else { return nil }
    return lease
  }

  /// Nil: the lease is ready; else why not (answered with Stop).
  mutating func ready(_ s: MicSessionID, stream: UInt64, peer: String, now: UInt64) -> MicLeaseRefusal? {
    guard var lease = live(s, stream: stream, peer: peer, now: now) else { return .stateConflict }
    lease.ready = true
    lease.expiry = now + Self.leaseMs
    leases[peer] = lease
    return nil
  }

  /// Renews a ready lease; never makes one.
  mutating func renew(_ s: MicSessionID, stream: UInt64, peer: String, now: UInt64) -> MicLeaseRefusal? {
    guard var lease = live(s, stream: stream, peer: peer, now: now), lease.ready else { return .stateConflict }
    lease.expiry = now + Self.leaseMs
    leases[peer] = lease
    return nil
  }

  /// Removes the peer's lease only when it is of this very session.
  @discardableResult
  mutating func stop(_ s: MicSessionID, peer: String) -> Bool {
    guard leases[peer]?.session == s else { return false }
    leases[peer] = nil
    return true
  }

  /// Each tick: leases expired, of a claim no longer this source's, of a peer gone or rebooted, or of an old claim stamp.
  /// The peers whose leases went.
  @discardableResult
  mutating func sweep(now: UInt64, state: MicSourceState, peers: [String: String]) -> [String] {
    let mine = state.claimAvailable && state.claimHolder == state.selfID
    let gone = leases.filter { peer, lease in
      !mine || now >= lease.expiry || peers[peer] != lease.session.output.receiverBoot || lease.session.claimStamp != state.claimStamp
        || lease.session.sourceBoot != state.boot
    }.map(\.key)
    for peer in gone { leases[peer] = nil }
    return gone.sorted()
  }

  /// C of the gate: a ready lease not expired.
  func anyReady(now: UInt64) -> Bool { leases.values.contains { $0.ready && now < $0.expiry } }
}

// MARK: - The receiver's demand lifetimes (§1.7)

enum MicReceiverAction: Equatable {
  /// Stop the current session (send Stop, close the playback).
  case revoke
  /// Ask the source for a session of this demand epoch.
  case request(epoch: UInt64)
  case fault(String)
}

struct MicReceiverDemand {
  static let activeResampleMs: UInt64 = 300
  private(set) var saved: MicDemandSample?
  private var sampledAt: UInt64 = 0

  /// Sample when never sampled, when active and 300 ms on, or when the monitor's epoch moved (woken).
  func due(now: UInt64, monitorEpoch: UInt64) -> Bool {
    guard let saved else { return true }
    return (saved.active && now - sampledAt >= Self.activeResampleMs) || monitorEpoch != saved.epoch
  }

  /// What to do with a new sample, with a session open or not.
  mutating func observe(_ s: MicDemandSample, now: UInt64, sessionOpen: Bool) -> [MicReceiverAction] {
    let before = saved
    saved = s
    sampledAt = now
    var actions: [MicReceiverAction] = []
    if let error = s.error {
      if sessionOpen { actions.append(.revoke) }
      actions.append(.fault(error))
      return actions
    }
    if sessionOpen, !s.active || s.epoch != before?.epoch { actions.append(.revoke) }
    if s.active, !sessionOpen || s.epoch != before?.epoch { actions.append(.request(epoch: max(s.epoch, 1))) }
    return actions
  }

  /// The second look, once the playback is open and before saying Ready: still active, the same lifetime, no error.
  func confirms(_ s: MicDemandSample) -> Bool {
    s.error == nil && s.active && s.epoch == saved?.epoch
  }
}

// MARK: - A view's virtual microphone (ScreenView's messages 11 and 12)

/// What a view samples demand from (`MacMicDemandMonitor`), and what it plays into (`MacMicFeeder`).
protocol MicDemandSampling: AnyObject {
  func sample() -> MicDemandSample
  func close()
}
extension MacMicDemandMonitor: MicDemandSampling {}

protocol MicFeeding: AnyObject {
  func start() throws
  func feed(_ pcm16le: Data)
  func stop()
}
extension MacMicFeeder: MicFeeding {}

/// The virtual microphone of one view, while the station watches it (message 11): demand sampled at once and again as
/// the HAL wakes it (and every 500 ms on a loopback of one device, whose other recorders only the process list tells),
/// said as message 4 `{mic: {available, active, epoch}}` each time it changes; the feed played only while something
/// records, a packet (message 12: flags, epoch, PCM16) taken only in the epoch said. Everything on its own queue.
final class ViewMicrophone: @unchecked Sendable {
  static let loopbackLookMs = 500
  private let queue = DispatchQueue(label: "fail.still.helper.mic", qos: .userInteractive)
  private let say: ([String: Any]) -> Void
  private let monitorOf: (@escaping () -> Void) throws -> MicDemandSampling
  private let feederOf: (String) -> MicFeeding
  private var monitor: MicDemandSampling?
  private var timer: DispatchSourceTimer?
  private var feeder: MicFeeding?
  private var feeding: (device: String, epoch: UInt32)?
  private var told: (Bool, Bool, UInt32)?
  /// Watches started, so a wake of one stopped since is let be.
  private var generation = 0

  init(say: @escaping ([String: Any]) -> Void,
       monitor: @escaping (@escaping () -> Void) throws -> MicDemandSampling = { wake in try MacMicDemandMonitor(wake: wake) },
       feeder: @escaping (String) -> MicFeeding = { MacMicFeeder(deviceUID: $0) }) {
    self.say = say
    self.monitorOf = monitor
    self.feederOf = feeder
  }

  /// Message 11: 1 watch, 0 no more.
  func watch(_ on: Bool) {
    queue.async { on ? self.start() : self.stop() }
  }

  /// Message 12: flags (bit 0 clear), the recording's epoch (u32 big-endian), 48 kHz mono PCM16, an even count.
  func feed(_ payload: Data) {
    guard payload.count >= 7, payload.count <= 5 + 3840, (payload.count - 5) % 2 == 0 else { return }
    let bytes = [UInt8](payload.prefix(5))
    guard bytes[0] & 1 == 0 else { return }
    let epoch = UInt32(bytes[1]) << 24 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 8 | UInt32(bytes[4])
    let pcm = Data(payload.dropFirst(5))
    queue.async {
      guard let feeder = self.feeder, self.feeding?.epoch == epoch else { return }
      feeder.feed(pcm)
    }
  }

  /// The view ended: stopped at once.
  func end() { queue.sync { stop() } }

  /// For tests: what was queued has run.
  func settle() { queue.sync {} }

  private func start() {
    guard monitor == nil else { return }
    generation += 1
    let g = generation
    do {
      monitor = try monitorOf { [weak self] in
        guard let self else { return }
        self.queue.async { if self.generation == g { self.look() } }
      }
    } catch {
      tell(false, false, 0)
      return
    }
    look()
  }

  private func stop() {
    generation += 1
    timer?.cancel()
    timer = nil
    stopFeed()
    monitor?.close()
    monitor = nil
    told = nil
  }

  private func stopFeed() {
    feeder?.stop()
    feeder = nil
    feeding = nil
  }

  private func look() {
    guard let monitor else { return }
    let s = monitor.sample()
    guard let device = s.device else {
      stopFeed()
      loopbackTimer(false)
      return tell(false, false, 0)
    }
    let epoch = UInt32(truncatingIfNeeded: s.epoch)
    // still.fail's own pair is fed by its feed device; a loopback (BlackHole) by the same device it records from.
    let feedDevice = device == MicUIDs.input ? MicUIDs.feed : device
    loopbackTimer(device != MicUIDs.input)
    var active = s.active && s.error == nil
    if active {
      if feeding?.device != feedDevice || feeder == nil {
        stopFeed()
        let f = feederOf(feedDevice)
        do {
          try f.start()
          feeder = f
        } catch {
          say(["micFeed": "\(error)"])
          active = false
        }
      }
      if feeder != nil { feeding = (feedDevice, epoch) }
    } else {
      stopFeed()
    }
    // Still there and still unrecorded: an epoch moved by something else (a device plugged in) is not said again.
    if !active, let told, told.0, !told.1 { return }
    tell(true, active, epoch)
  }

  private func loopbackTimer(_ on: Bool) {
    guard on != (timer != nil) else { return }
    if !on {
      timer?.cancel()
      timer = nil
      return
    }
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now() + .milliseconds(Self.loopbackLookMs), repeating: .milliseconds(Self.loopbackLookMs))
    t.setEventHandler { [weak self] in self?.look() }
    t.resume()
    timer = t
  }

  private func tell(_ available: Bool, _ active: Bool, _ epoch: UInt32) {
    if let told, told == (available, active, epoch) { return }
    told = (available, active, epoch)
    say(["mic": ["available": available, "active": active, "epoch": Int(epoch)]])
  }
}
