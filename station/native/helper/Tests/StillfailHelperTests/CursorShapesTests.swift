import AppKit
import Foundation
import Testing
@testable import StillfailHelper

/// A pointer of an app's own: `points` a side, its pixels one colour (so two of another colour differ).
@MainActor
private func cursor(points: CGFloat, pixels: Int? = nil, red: CGFloat = 1, hotSpot: NSPoint = NSPoint(x: 3, y: 5)) -> NSCursor {
  let side = pixels ?? Int(points)
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  for x in 0..<side { for y in 0..<side { rep.setColor(NSColor(deviceRed: red, green: 0.2, blue: CGFloat(x % 7) / 7, alpha: 0.8), atX: x, y: y) } }
  rep.size = NSSize(width: points, height: points)
  let image = NSImage(size: rep.size)
  image.addRepresentation(rep)
  return NSCursor(image: image, hotSpot: hotSpot)
}

@Test @MainActor
func theSystemsCursorsGoByTheirCSSNames() {
  // (the arrow alone: in a test run over SSH, with no display, the I-beam's and the hand's pictures do not come out
  // the same as the table's)
  #expect(CursorShapes.shape(of: NSCursor.arrow).0 == "default")
  #expect(CursorShapes.shape(of: NSCursor.arrow).1 == nil)
  #expect(CursorShapes.shape(of: nil).0 == "default")
  #expect(CursorShapes.shape(of: nil).1 == nil)
}

@Test @MainActor
func anAppsOwnIsSaidWithItsPicture() throws {
  let (shape, custom) = CursorShapes.shape(of: cursor(points: 24, pixels: 48))
  let c = try #require(custom)
  #expect(shape == "custom:\(c.id)")
  #expect(c.id.count == 16 && c.id.allSatisfy { "0123456789abcdef".contains($0) })
  let p = [UInt8](c.payload)
  #expect(Array(p[0..<4]) == [24, 24, 3, 5])
  #expect(String(decoding: p[4..<20], as: UTF8.self) == c.id)
  #expect(Array(p[20..<28]) == [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
  #expect(p.count - 20 <= CursorShapes.pngMost)
  // the PNG is the picture, at its pixels
  let png = try #require(NSBitmapImageRep(data: Data(p[20...])))
  #expect(png.pixelsWide == 48 && png.pixelsHigh == 48)
}

@Test @MainActor
func theSamePictureIsTheSameIdAndEncodedOnce() throws {
  let first = try #require(CursorShapes.shape(of: cursor(points: 16, red: 0.5)).1)
  let again = try #require(CursorShapes.shape(of: cursor(points: 16, red: 0.5)).1)
  #expect(first == again)
  #expect(CursorShapes.made[first.id] == first)
  let other = try #require(CursorShapes.shape(of: cursor(points: 16, red: 0.25)).1)
  #expect(other.id != first.id)
  let moved = try #require(CursorShapes.shape(of: cursor(points: 16, red: 0.5, hotSpot: NSPoint(x: 8, y: 8))).1)
  #expect(moved.id != first.id, "another hot spot is another pointer")
}

@Test @MainActor
func oneTooLargeIsTheDefault() {
  let (shape, custom) = CursorShapes.shape(of: cursor(points: 129))
  #expect(shape == "default" && custom == nil)
}

@Test @MainActor
func aHotSpotOutsideIsKeptWithin() throws {
  let c = try #require(CursorShapes.shape(of: cursor(points: 10, hotSpot: NSPoint(x: 40, y: -3))).1)
  #expect(Array([UInt8](c.payload)[0..<4]) == [10, 10, 10, 0])
}

@Test @MainActor
func fnv1aIsTheStandardOne() {
  #expect(CursorShapes.fnv1a(Data()) == 0xcbf2_9ce4_8422_2325)
  #expect(CursorShapes.fnv1a(Data("a".utf8)) == 0xaf63_dc4c_8601_ec8c)
}
