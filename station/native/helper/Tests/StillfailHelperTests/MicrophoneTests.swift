import CoreAudio
import Foundation
import Testing
@testable import StillfailHelper

// MARK: - The ring (spec §4.8)

@Test
@available(macOS 15.0, *)
func ringReadersShareSamplesAndUnwrittenIsSilence() {
  let ring = AudioRingBuffer()
  #expect(ring.read(0) == 0)
  #expect(ring.read(12345) == 0)
  for f in UInt64(100)..<200 { ring.write(f, Float(f) / 1000) }
  // Any number of readers read the same sample; reading consumes nothing.
  for _ in 0..<3 { #expect(ring.read(150) == 0.15) }
  #expect(ring.read(99) == 0)
  #expect(ring.read(200) == 0)
  // A frame overwritten by the one a capacity later reads as silence, never as the newer sample.
  ring.write(150 + UInt64(AudioRingBuffer.capacity), 0.9)
  #expect(ring.read(150) == 0)
  #expect(ring.read(150 + UInt64(AudioRingBuffer.capacity)) == 0.9)
  // A slot being written is silence to a reader.
  ring.beginWrite(160)
  #expect(ring.read(160) == 0)
  ring.write(160, 0.5)
  #expect(ring.read(160) == 0.5)
  ring.clear()
  #expect(ring.read(170) == 0)
}

@Test
@available(macOS 15.0, *)
func ringConcurrentReadersNeverSeeATornOrForeignSample() async {
  let ring = AudioRingBuffer()
  // Each frame's sample is a function of the frame: whatever a reader gets is that or silence.
  let value = { (f: UInt64) -> Float in Float(f % 1000) + 1 }
  await withTaskGroup(of: Int.self) { group in
    group.addTask {
      for f in UInt64(0)..<200_000 { ring.write(f, value(f)) }
      return 0
    }
    for _ in 0..<3 {
      group.addTask {
        var bad = 0
        for f in UInt64(0)..<200_000 {
          let v = ring.read(f)
          if v != 0 && v != value(f) { bad += 1 }
        }
        return bad
      }
    }
    var bad = 0
    for await b in group { bad += b }
    #expect(bad == 0)
  }
}

@Test
@available(macOS 15.0, *)
func loopbackIsSilentUnlessTheFeedWritesAndClearsOnStartAndStop() {
  let mic = MicLoopback()
  let d = Double(AudioRingBuffer.readDelay)
  var out = [Float](repeating: 1, count: 4)
  let samples: [Float] = [0.1, 0.2, 0.3, 0.4]
  // Not writing: silence even with samples in the ring.
  samples.withUnsafeBufferPointer { mic.writeMixed(at: 0, $0) }
  out.withUnsafeMutableBufferPointer { mic.readInput(at: d, into: $0) }
  #expect(out == [0, 0, 0, 0])
  mic.startFeed()
  out.withUnsafeMutableBufferPointer { mic.readInput(at: d, into: $0) }
  #expect(out == [0, 0, 0, 0], "StartIO cleared what was there")
  samples.withUnsafeBufferPointer { mic.writeMixed(at: 4096, $0) }
  out.withUnsafeMutableBufferPointer { mic.readInput(at: 4096 + d, into: $0) }
  #expect(out == samples)
  // Two readers at once read the same.
  var other = [Float](repeating: 0, count: 4)
  other.withUnsafeMutableBufferPointer { mic.readInput(at: 4096 + d, into: $0) }
  #expect(other == samples)
  // Before D, not finite or negative times: silence, nothing written.
  out.withUnsafeMutableBufferPointer { mic.readInput(at: d - 1, into: $0) }
  #expect(out == [0, 0, 0, 0])
  samples.withUnsafeBufferPointer { mic.writeMixed(at: .nan, $0); mic.writeMixed(at: -5, $0) }
  mic.stopFeed()
  mic.startFeed()
  out.withUnsafeMutableBufferPointer { mic.readInput(at: 4096 + d, into: $0) }
  #expect(out == [0, 0, 0, 0], "StopIO cleared it")
}

// MARK: - Devices

private func device(_ id: AudioObjectID, _ uid: String, _ name: String, _ transport: String, input: Bool = true, output: Bool = true) -> MicHALDevice {
  MicHALDevice(id: id, uid: uid, name: name, transport: transport.isEmpty ? 0 : fourCC(transport), hasInput: input, hasOutput: output)
}

private let builtIn = device(10, "BuiltInMicrophoneDevice", "MacBook Pro Microphone", "bltn", output: false)
private let usb = device(11, "AppleUSBAudioEngine:mic", "USB Microphone", "usb ", output: false)

@Test
func pairsStillFailsOwnDevicesThenALoopbackNeverAPhysicalMicrophone() {
  #expect(MicDevices.pair([builtIn, usb]) == .failure(.notLoaded))
  let own = device(20, MicUIDs.input, "still.fail Microphone", "virt", output: false)
  let feed = device(21, MicUIDs.feed, "still.fail Microphone Feed", "virt", input: false)
  #expect(MicDevices.pair([builtIn, own]) == .failure(.feedMissing))
  let pair = try? MicDevices.pair([builtIn, own, feed]).get()
  #expect(pair?.input.id == 20 && pair?.feed.id == 21 && pair?.shared == false)
  // A loopback: the same device both ways.
  let hole = device(30, "BlackHole2ch_UID", "BlackHole 2ch", "virt")
  let lb = try? MicDevices.pair([builtIn, usb, hole]).get()
  #expect(lb?.input.id == 30 && lb?.shared == true)
  // Own devices win over a loopback; BlackHole 2ch over 16ch.
  #expect((try? MicDevices.pair([hole, own, feed]).get())?.input.id == 20)
  let hole16 = device(31, "BlackHole16ch_UID", "BlackHole 16ch", "virt")
  #expect((try? MicDevices.pair([hole16, hole]).get())?.input.id == 30)
  // Two of one name: ambiguous, not the first.
  let hole2 = device(32, "BlackHole2ch_UID_2", "BlackHole 2ch", "virt")
  if case .failure(.ambiguous) = MicDevices.pair([hole, hole2]) {} else { Issue.record("two BlackHole 2ch must be ambiguous") }
  // A device named like a loopback on a hardware transport, or one of unknown transport, is refused.
  #expect(MicDevices.pair([device(40, "x", "BlackHole 2ch", "usb ")]) == .failure(.physical("BlackHole 2ch")))
  #expect(MicDevices.pair([device(41, "y", "VB-Cable", "")]) == .failure(.physical("VB-Cable")))
  #expect(MicDevices.pair([device(42, MicUIDs.input, "still.fail Microphone", "bltn"), feed]) == .failure(.physical("still.fail Microphone")))
}

// MARK: - Demand (spec §4.4)

private final class FakeHAL: MicHAL {
  var list: [MicHALDevice] = []
  var running: [AudioObjectID: Bool] = [:]
  var others: [AudioObjectID: Bool] = [:]
  var failing: MicHALError?
  var refuseListeners = false
  var listeners: [(AudioObjectID, AudioObjectPropertySelector, Int)] = []

  func devices() throws -> [MicHALDevice] {
    if let failing { throw failing }
    return list
  }
  func isRunningSomewhere(_ id: AudioObjectID) throws -> Bool {
    if let failing { throw failing }
    return running[id] ?? false
  }
  func othersRecording(_ id: AudioObjectID, excluding pid: pid_t) throws -> Bool { others[id] ?? false }
  func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, token: Int) -> OSStatus {
    if refuseListeners { return -50 }
    listeners.append((object, selector, token))
    return noErr
  }
  func removeListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, token: Int) -> OSStatus {
    guard let i = listeners.firstIndex(where: { $0.0 == object && $0.1 == selector && $0.2 == token }) else { return -1 }
    listeners.remove(at: i)
    return noErr
  }
  /// What the HAL calls for a change of `selector` on `object`: the listener proc with its client data, the token.
  func change(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
    for (o, s, token) in listeners where o == object && s == selector {
      var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
      _ = micListenerProc(object, 1, &a, UnsafeMutableRawPointer(bitPattern: token))
    }
  }
}

private let ownInput = device(20, MicUIDs.input, "still.fail Microphone", "virt", output: false)
private let ownFeed = device(21, MicUIDs.feed, "still.fail Microphone Feed", "virt", input: false)

@Test
func demandIsGoneOnTheVisibleInputOnlyAndAStopStartBetweenLooksIsANewEpoch() throws {
  let hal = FakeHAL()
  hal.list = [builtIn, ownInput, ownFeed]
  var woken = 0
  let monitor = try MacMicDemandMonitor(hal: hal, pid: 77, wake: { woken += 1 })
  // Subscribed to the system before anything is read.
  #expect(hal.listeners.map(\.1) == [kAudioHardwarePropertyDevices, kAudioHardwarePropertyServiceRestarted, kAudioHardwarePropertyProcessObjectList])
  #expect(hal.listeners.allSatisfy { $0.0 == AudioObjectID(kAudioObjectSystemObject) && $0.2 == monitor.token })
  let first = monitor.sample()
  #expect(first == MicDemandSample(active: false, epoch: 2, device: MicUIDs.input), "the 'gone' listener added: a new epoch")
  #expect(hal.listeners.contains { $0.0 == 20 && $0.1 == kAudioDevicePropertyDeviceIsRunningSomewhere })
  // Only the visible input counts: the feed running (the station's own playback) is no demand.
  hal.running[21] = true
  #expect(monitor.sample().active == false)
  // A consumer starts: the HAL calls back, the epoch moves on.
  hal.running[20] = true
  hal.change(20, kAudioDevicePropertyDeviceIsRunningSomewhere)
  let started = monitor.sample()
  #expect(started.active && started.epoch == 3 && woken == 1)
  // It stops and starts again before the next look: active both times, but the epoch says it was another lifetime.
  hal.running[20] = false
  hal.change(20, kAudioDevicePropertyDeviceIsRunningSomewhere)
  hal.running[20] = true
  hal.change(20, kAudioDevicePropertyDeviceIsRunningSomewhere)
  let again = monitor.sample()
  #expect(again.active && again.epoch == 5)
  var receiver = MicReceiverDemand()
  #expect(receiver.observe(started, now: 0, sessionOpen: false) == [.request(epoch: 3)])
  #expect(receiver.observe(again, now: 100, sessionOpen: true) == [.revoke, .request(epoch: 5)])
}

@Test
func anErrorIsNoDemandAndCoreaudiodsReusedIDsMoveTheListener() throws {
  let hal = FakeHAL()
  hal.list = [ownInput, ownFeed]
  hal.running[20] = true
  let monitor = try MacMicDemandMonitor(hal: hal, pid: 77)
  #expect(monitor.sample().active)
  hal.failing = MicHALError(what: "reading 'gone'", status: -1)
  let failed = monitor.sample()
  #expect(failed.active == false && failed.error != nil)
  hal.failing = nil
  // coreaudiod restarted: the device is back under another ID.
  let epoch = monitor.epoch
  hal.change(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyServiceRestarted)
  var moved = ownInput
  moved.id = 50
  hal.list = [moved, ownFeed]
  hal.running[50] = true
  let back = monitor.sample()
  #expect(back.active && back.epoch == epoch + 2)
  #expect(!hal.listeners.contains { $0.0 == 20 } && hal.listeners.contains { $0.0 == 50 })
  // Unloaded: an error, the listener taken off.
  hal.list = [builtIn]
  let gone = monitor.sample()
  #expect(!gone.active && gone.error == MicPairError.notLoaded.description)
  #expect(!hal.listeners.contains { $0.0 == 50 })
}

@Test
func aLoopbacksOwnFeedIsNoDemandOnlyOtherProcessesInput() throws {
  let hal = FakeHAL()
  let hole = device(30, "BlackHole2ch_UID", "BlackHole 2ch", "virt")
  hal.list = [builtIn, hole]
  hal.running[30] = true  // the station plays into it
  let monitor = try MacMicDemandMonitor(hal: hal, pid: 77)
  #expect(monitor.sample().active == false)
  hal.others[30] = true
  #expect(monitor.sample().active)
}

@Test
func lateCallbacksAfterCloseAreHarmlessAndAFailedSubscriptionLeavesNothing() throws {
  let hal = FakeHAL()
  hal.list = [ownInput, ownFeed]
  var woken = 0
  var monitor: MacMicDemandMonitor? = try MacMicDemandMonitor(hal: hal, pid: 77, wake: { woken += 1 })
  _ = monitor?.sample()
  let token = monitor!.token
  monitor = nil
  #expect(hal.listeners.isEmpty, "every listener removed")
  // The HAL calling the old token anyway (a removal it did not honour): nothing happens.
  var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  #expect(micListenerProc(1, 1, &a, UnsafeMutableRawPointer(bitPattern: token)) == noErr)
  #expect(woken == 0)
  hal.refuseListeners = true
  #expect(throws: MicHALError.self) { try MacMicDemandMonitor(hal: hal, pid: 77) }
}

@Test
func demandIsSampledWhenNeverSampledActiveEvery300msOrWoken() {
  var r = MicReceiverDemand()
  #expect(r.due(now: 0, monitorEpoch: 1))
  _ = r.observe(MicDemandSample(active: false, epoch: 1), now: 0, sessionOpen: false)
  #expect(!r.due(now: 10_000, monitorEpoch: 1), "inactive: only when woken")
  #expect(r.due(now: 1, monitorEpoch: 2))
  _ = r.observe(MicDemandSample(active: true, epoch: 2), now: 1000, sessionOpen: false)
  #expect(!r.due(now: 1299, monitorEpoch: 2))
  #expect(r.due(now: 1300, monitorEpoch: 2))
  // An error is a fault and revokes; no request.
  #expect(r.observe(MicDemandSample(active: false, epoch: 2, error: "x"), now: 1300, sessionOpen: true) == [.revoke, .fault("x")])
  // Inactive with a session open: revoke.
  #expect(r.observe(MicDemandSample(active: false, epoch: 3), now: 1400, sessionOpen: true) == [.revoke])
  // The second look before Ready.
  _ = r.observe(MicDemandSample(active: true, epoch: 4), now: 1500, sessionOpen: false)
  #expect(r.confirms(MicDemandSample(active: true, epoch: 4)))
  #expect(!r.confirms(MicDemandSample(active: true, epoch: 5)))
  #expect(!r.confirms(MicDemandSample(active: false, epoch: 4)))
  #expect(!r.confirms(MicDemandSample(active: true, epoch: 4, error: "e")))
}

// MARK: - The feed's queue

@Test
func feedQueuePlaysInOrderPadsWithSilenceAndKeepsTheNewest100ms() {
  var q = MicFeedQueue()
  let pcm = { (values: [Int16]) -> Data in values.withUnsafeBufferPointer { Data(buffer: $0) } }
  q.append(pcm16le: pcm([1, 2, 3]))
  var out = [Int16](repeating: 9, count: 5)
  #expect(out.withUnsafeMutableBufferPointer { q.fill($0) } == 3)
  #expect(out == [1, 2, 3, 0, 0])
  #expect(out.withUnsafeMutableBufferPointer { q.fill($0) } == 0)
  #expect(out == [0, 0, 0, 0, 0], "an underrun is silence, never the old samples")
  q.append(pcm16le: pcm((0..<6000).map { Int16($0 % 30000) }))
  #expect(q.count == MicFeedQueue.most && q.dropped == 1200)
  var big = [Int16](repeating: 0, count: MicFeedQueue.most)
  _ = big.withUnsafeMutableBufferPointer { q.fill($0) }
  #expect(big.first == 1200 && big.last == 5999)
}

@Test
func feederToADeviceThatIsNotThereFailsAndNeverPlaysToTheDefault() {
  let feeder = MacMicFeeder(deviceUID: "fail.still.no-such-device")
  #expect(throws: MicHALError.self) { try feeder.start() }
  #expect(!feeder.running)
  feeder.feed(Data(count: 1920))
  feeder.stop()
}

@Test
func feederPlaysIntoALoopbackWhenThisMacHasOne() throws {
  guard let devices = try? CoreAudioHAL().devices(), case .success(let pair) = MicDevices.pair(devices) else { return }
  let feeder = MacMicFeeder(deviceUID: pair.feed.uid)
  try feeder.start()
  #expect(feeder.running)
  feeder.feed(Data(count: 1920))
  feeder.stop()
  #expect(!feeder.running)
}

@Test
func realHALIsReadableWithoutAVirtualMicrophone() throws {
  let monitor = try MacMicDemandMonitor()
  let s = monitor.sample()
  if s.error != nil { #expect(!s.active) }
  monitor.close()
}

// MARK: - The source's capture and leases (spec §4.1–4.3)

@Test
func onlyPermissionLeaseAndAudibleTogetherOpenTheMicrophone() {
  for p in [false, true] {
    for c in [false, true] {
      for a in [false, true] {
        var gate = MicCaptureGate()
        let d = gate.tick(permitted: p, leased: c, audible: a)
        switch (p, c, a) {
        case (true, true, true): if case .open = d {} else { Issue.record("1/1/1 opens") }
        case (true, true, false): if case .mutedHold = d {} else { Issue.record("1/1/0 holds muted") }
        default: #expect(d == .closed)
        }
      }
    }
  }
  #expect(MicCaptureGate.audible(muted: false, volumePercent: 1))
  #expect(!MicCaptureGate.audible(muted: true, volumePercent: 100))
  #expect(!MicCaptureGate.audible(muted: false, volumePercent: 0))
}

@Test
func mutedHoldRepeatsItsSleepBurstAndTheNextEncoderComesAfterIt() {
  var gate = MicCaptureGate()
  #expect(gate.tick(permitted: true, leased: true, audible: true) == .open(burst: 1))
  #expect(gate.tick(permitted: true, leased: true, audible: false) == .mutedHold(sleepBurst: 2))
  #expect(gate.tick(permitted: true, leased: true, audible: false) == .mutedHold(sleepBurst: 2), "the same each tick")
  #expect(gate.tick(permitted: true, leased: true, audible: true) == .open(burst: 3))
  #expect(gate.tick(permitted: true, leased: true, audible: true) == .open(burst: 3))
  // Demand gone: closed, no sleep kept; a later hold is a new, larger burst.
  #expect(gate.tick(permitted: true, leased: false, audible: false) == .closed)
  #expect(gate.tick(permitted: true, leased: true, audible: false) == .mutedHold(sleepBurst: 4))
}

private let state = MicSourceState(selfID: "src", boot: "b-src", claimHolder: "src", claimStamp: 7, claimAvailable: true)
private func session(_ peer: String = "rx", epoch: UInt64 = 1, nonce: UInt8 = 1) -> MicSessionID {
  MicSessionID(sourceBoot: "b-src", output: MicOutputBinding(receiverBoot: "b-\(peer)", demandEpoch: epoch, outputEndpoint: "feed"), claimStamp: 7, nonce: [UInt8](repeating: nonce, count: 16))
}

@Test
func leasesNeedReadyBeforeRenewExpireAtExactlyLAndRenewNeverMakesOne() {
  var t = MicLeaseTable()
  let s = session()
  let r1 = t.renew(s, stream: 1, peer: "rx", now: 0)
  #expect(r1 == .stateConflict, "renew makes no lease")
  #expect(t.leases.isEmpty)
  guard case .success(let stream) = t.demand(s, peer: "rx", peerBoot: "b-rx", state: state, now: 0) else { Issue.record("demand"); return }
  let r2 = t.demand(s, peer: "rx", peerBoot: "b-rx", state: state, now: 100)
  #expect(r2 == .success(stream), "the same session: the same prepared")
  let r3 = t.renew(s, stream: stream, peer: "rx", now: 100)
  #expect(r3 == .stateConflict, "not ready yet")
  #expect(!t.anyReady(now: 100))
  let r4 = t.ready(s, stream: stream + 1, peer: "rx", now: 100)
  #expect(r4 == .stateConflict)
  let r5 = t.ready(s, stream: stream, peer: "rx", now: 200)
  #expect(r5 == nil)
  #expect(t.anyReady(now: 200))
  let r6 = t.renew(s, stream: stream, peer: "rx", now: 500)
  #expect(r6 == nil)
  // Expired at exactly L after the last renewal.
  #expect(t.anyReady(now: 500 + MicLeaseTable.leaseMs - 1))
  #expect(!t.anyReady(now: 500 + MicLeaseTable.leaseMs))
  let r7 = t.renew(s, stream: stream, peer: "rx", now: 500 + MicLeaseTable.leaseMs)
  #expect(r7 == .stateConflict)
  let r8 = t.sweep(now: 500 + MicLeaseTable.leaseMs, state: state, peers: ["rx": "b-rx"])
  #expect(r8 == ["rx"])
}

@Test
func anOldSessionsLateReadyOrStopLeavesTheNewOneAndThe17thReceiverIsBusy() {
  var t = MicLeaseTable()
  let old = session(epoch: 1, nonce: 1)
  let new = session(epoch: 2, nonce: 2)
  guard case .success(let s1) = t.demand(old, peer: "rx", peerBoot: "b-rx", state: state, now: 0),
    case .success(let s2) = t.demand(new, peer: "rx", peerBoot: "b-rx", state: state, now: 10)
  else { Issue.record("demand"); return }
  #expect(s2 > s1, "a new stream generation")
  let r9 = t.ready(old, stream: s1, peer: "rx", now: 20)
  #expect(r9 == .stateConflict)
  let r10 = t.stop(old, peer: "rx")
  #expect(!r10)
  #expect(t.leases["rx"]?.session == new)
  let r11 = t.ready(new, stream: s2, peer: "rx", now: 30)
  #expect(r11 == nil)
  for i in 0..<15 {
    let p = "p\(i)"
    let r12 = t.demand(session(p), peer: p, peerBoot: "b-\(p)", state: state, now: 30)
    #expect((try? r12.get()) != nil)
  }
  let r13 = t.demand(session("p99"), peer: "p99", peerBoot: "b-p99", state: state, now: 30)
  #expect(r13 == .failure(.busy))
  let r14 = t.stop(new, peer: "rx")
  #expect(r14)
  let r15 = t.demand(session("p99"), peer: "p99", peerBoot: "b-p99", state: state, now: 30)
  #expect((try? r15.get()) != nil)
}

@Test
func demandsOfAStaleBootAnotherRouteOrNoOutputAreRefused() {
  var t = MicLeaseTable()
  var s = session()
  let r16 = t.demand(s, peer: "rx", peerBoot: "b-rx-new", state: state, now: 0)
  #expect(r16 == .failure(.bootStale))
  s.sourceBoot = "b-src-old"
  let r17 = t.demand(s, peer: "rx", peerBoot: "b-rx", state: state, now: 0)
  #expect(r17 == .failure(.bootStale))
  s = session()
  s.claimStamp = 6
  let r18 = t.demand(s, peer: "rx", peerBoot: "b-rx", state: state, now: 0)
  #expect(r18 == .failure(.routeChanged))
  var other = state
  other.claimHolder = "someone"
  let r19 = t.demand(session(), peer: "rx", peerBoot: "b-rx", state: other, now: 0)
  #expect(r19 == .failure(.routeChanged))
  let r20 = t.demand(session("src"), peer: "src", peerBoot: "b-src", state: state, now: 0)
  #expect(r20 == .failure(.routeChanged))
  s = session()
  s.output.outputEndpoint = ""
  let r21 = t.demand(s, peer: "rx", peerBoot: "b-rx", state: state, now: 0)
  #expect(r21 == .failure(.outputUnavailable))
  // Swept: the peer rebooted, the claim moved.
  _ = t.demand(session(), peer: "rx", peerBoot: "b-rx", state: state, now: 0)
  let r22 = t.sweep(now: 1, state: state, peers: ["rx": "b-rx2"])
  #expect(r22 == ["rx"])
  _ = t.demand(session(), peer: "rx", peerBoot: "b-rx", state: state, now: 0)
  var moved = state
  moved.claimStamp = 8
  let r23 = t.sweep(now: 1, state: moved, peers: ["rx": "b-rx"])
  #expect(r23 == ["rx"])
}
