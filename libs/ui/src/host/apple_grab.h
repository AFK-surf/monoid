// Pure Foundation/CoreGraphics/CoreVideo/ImageIO frame downscale and JPEG encoder for apple_views.m (`grabShown:`),
// runnable on a background queue and testable standalone on macOS.
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include <math.h>

// Encode `img` (or, when `img` is NULL, 32BGRA `pb`) scaled so its longer side is at most `side` pixels (never upscaling;
// invalid `side <= 0` or non-finite falls back to 1:1) as 0.9-quality JPEG. Locks and unlocks `pb` on the caller's thread.
static inline NSData *mb_apple_encode_frame_jpeg(CGImageRef img, CVPixelBufferRef pb, double side) {
  if (!img && !pb) return nil;
  BOOL locked = NO;
  CGImageRef src = img;
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  if (!cs) return nil;

  if (!src) {
    if (CVPixelBufferGetPixelFormatType(pb) != kCVPixelFormatType_32BGRA || CVPixelBufferIsPlanar(pb)) {
      CGColorSpaceRelease(cs);
      return nil;
    }
    if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
      CGColorSpaceRelease(cs);
      return nil;
    }
    locked = YES;
    size_t pw = CVPixelBufferGetWidth(pb);
    size_t ph = CVPixelBufferGetHeight(pb);
    void *base = CVPixelBufferGetBaseAddress(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb);
    if (pw == 0 || ph == 0 || !base || bpr < pw * 4) {
      CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
      CGColorSpaceRelease(cs);
      return nil;
    }
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, base, bpr * ph, NULL);
    if (!provider) {
      CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
      CGColorSpaceRelease(cs);
      return nil;
    }
    src = CGImageCreate(pw, ph, 8, 32, bpr, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little, provider, NULL,
                        false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    if (!src) {
      CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
      CGColorSpaceRelease(cs);
      return nil;
    }
  }

  size_t w = CGImageGetWidth(src);
  size_t h = CGImageGetHeight(src);
  CGImageRef small = NULL;
  if (w > 0 && h > 0) {
    double maxDim = fmax((double)w, (double)h);
    double k = (side > 0.0 && isfinite(side)) ? fmin(1.0, side / maxDim) : 1.0;
    size_t tw = (size_t)llround((double)w * k);
    size_t th = (size_t)llround((double)h * k);
    if (tw < 1) tw = 1;
    if (th < 1) th = 1;
    CGContextRef c = CGBitmapContextCreate(NULL, tw, th, 8, 0, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    if (c) {
      CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
      CGContextDrawImage(c, CGRectMake(0, 0, (CGFloat)tw, (CGFloat)th), src);
      small = CGBitmapContextCreateImage(c);
      CGContextRelease(c);
    }
  }

  if (locked) {
    CGImageRelease(src);
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
  }
  CGColorSpaceRelease(cs);
  if (!small) return nil;

  NSMutableData *jpeg = [NSMutableData new];
  CGImageDestinationRef dst =
      CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpeg, CFSTR("public.jpeg"), 1, NULL);
  if (dst) {
    CGImageDestinationAddImage(
        dst, small, (__bridge CFDictionaryRef) @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @0.9});
    if (!CGImageDestinationFinalize(dst)) jpeg = nil;
    CFRelease(dst);
  } else {
    jpeg = nil;
  }
  CGImageRelease(small);
  return jpeg;
}
