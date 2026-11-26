import Foundation
import Testing
import VideoToolbox
@testable import StillfailHelper

@Test
func aResizedRegionWaitsForTheOldEncoderBeforeItCopiesPixels() throws {
  let sink = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
  defer { try? sink.close() }
  let view = ScreenView(channel: Channel(fd: sink.fileDescriptor),
                        options: ["synthetic": "still", "maxWidth": 160, "maxHeight": 90])
  defer { view.queue.sync { if let session = view.session { VTCompressionSessionInvalidate(session) } } }
  view.moved(CGRect(x: 0, y: 0, width: 1920, height: 1080))
  let region = [0.25, 0.2, 0.5, 0.5]

  try view.queue.sync {
    try #require(view.makeSession(320, 180))
    let old = try #require(view.session)
    view.wanted = 1
    view.took(view.picture(320, 180), 1)
    try #require(view.inFlight == 1)
    view.region = region
    view.wanted = 1
    view.took(view.picture(320, 180), 2)

    #expect(view.pool == nil)
    #expect(view.wanted == 1)
    #expect(view.fresh)
    #expect(view.session === old)
    try #require(VTCompressionSessionCompleteFrames(old, untilPresentationTimeStamp: .invalid) == noErr)
  }
  // The old encoder's callback runs on this queue and submits the pending picture to the new encoder.
  try view.queue.sync {
    #expect(view.size.0 == 160 && view.size.1 == 90)
    #expect(view.wanted == 0)
    let resized = try #require(view.session)
    try #require(VTCompressionSessionCompleteFrames(resized, untilPresentationTimeStamp: .invalid) == noErr)
  }
  view.queue.sync {
    #expect(view.inFlight == 0)
    #expect(view.toldRegion == region)
  }
}

@Test
func aSimulatorFrameKeepsTheSizeAndRegionItGotDuringCapture() throws {
  let sink = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
  defer { try? sink.close() }
  let view = SimulatorView(channel: Channel(fd: sink.fileDescriptor), options: ["codec": "jpeg"], udid: "test")
  view.queue.sync {
    view.region = [0.2, 0.1, 0.5, 0.5]
    // A picture from the capture queue can belong to an earlier region request.
    view.latestPart = [0.4, 0.2, 0.5, 0.5]
    view.wanted = 1
    view.took(view.picture(96, 160), 1)
    #expect(view.pool == nil)
    #expect(view.size.0 == 96 && view.size.1 == 160)
    #expect(view.toldRegion == view.latestPart)
    #expect(view.wanted == 0)
  }
}
