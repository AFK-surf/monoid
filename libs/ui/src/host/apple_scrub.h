// A finger going back along a video's timeline (op 9, NativeView::scrub), for apple_views.m's AVPlayer: each exact
// seek back has AVPlayer decode from the key frame before it, so a film whose key frames are far apart (a screen's
// recording: one in ten seconds) shows some ten frames a second going back, though forward its seeks keep up (the
// decoder goes on from where it is). Going back, the stretch before where the finger is is decoded at once, in order
// (AVAssetReader, through the same loader and its block cache), its frames kept at the view's size in points, and each
// seek into it shown from them at once over the player's picture; the player is taken there once the finger lets go.
// Frames shown so are the very frames, never a key frame near them. Included by apple_views.m (MBNative's).
#import <VideoToolbox/VideoToolbox.h>
__asm__(".linker_option \"-framework\", \"VideoToolbox\"");

// the most the kept frames take (bytes): on a Mac some three seconds of a 60 fps film at 800 × 450, a phone's less
#if TARGET_OS_OSX
static const double kScrubKeep = 256.0 * 1024 * 1024;
#else
static const double kScrubKeep = 96.0 * 1024 * 1024;
#endif
// a frame's time said with its fraction of a ms (Media's `snap`) is that frame's
static const double kScrubSlack = 0.5;

@implementation MBScrubFrames
@end

static MBScrubFrames *scrub_decode(AVAsset *asset, AVAssetTrack *track, double from, double to, size_t tw, size_t th,
                                   CFStringRef turn, BOOL (^stale)(void)) API_AVAILABLE(macos(13.0), ios(16.0));

@implementation MBNative (Scrub)

// A finger on its timeline (`on`), or let go: the player taken where the frames kept last showed, those let go of.
- (void)scrubOn:(BOOL)on {
  if (on == self.scrubbing) return;
  self.scrubbing = on;
  self.scrubLastMs = -1;
  if (on) return;
  self.scrubGen++;
  self.scrubFrames = nil;
  self.scrubWant = -1;
  // (shown from them: the player sent there, the picture kept over it until it is: seekTo's completion)
  if (self.scrubServed) {
    self.scrubServed = NO;
    self.scrubLanding = YES;
    [self seekTo:self.scrubShownMs];
  }
}

// An exact seek to `ms` while a finger is on its timeline: shown from the frames kept (YES), else the player's to
// take; going back past them, the stretch before `ms` asked to be decoded.
- (BOOL)scrubTo:(double)ms {
  double last = self.scrubLastMs;
  self.scrubLastMs = ms;
  if ([self scrubShow:ms]) {
    // (a seek of the player still to take is not wanted: the one on its way goes on, its picture under these)
    self.chasing = NO;
    // (going back into the first third of them, the stretch before decoded now: there before the finger is)
    MBScrubFrames *f = self.scrubFrames;
    if (last >= 0 && ms < last - kScrubSlack && f.from > 0 && ms < f.from + (f.to - f.from) / 3 && !self.scrubDecoding)
      [self scrubDecodeBefore:ms];
    return YES;
  }
  self.scrubServed = NO;
  if (last >= 0 && ms < last - kScrubSlack) [self scrubDecodeBefore:ms];
  return NO;
}

// The frame kept that shows at `ms` over the player's picture, if one is.
- (BOOL)scrubShow:(double)ms {
  MBScrubFrames *f = self.scrubFrames;
  if (!f || f.times.count == 0 || ms < f.from - kScrubSlack || ms >= f.to) return NO;
  NSArray<NSNumber *> *times = f.times;
  NSUInteger lo = 0, hi = times.count;
  while (lo < hi) {
    NSUInteger mid = (lo + hi) / 2;
    if (times[mid].doubleValue <= ms + kScrubSlack) lo = mid + 1;
    else hi = mid;
  }
  if (lo == 0) return NO;
  id picture = f.pictures[lo - 1];
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  if (!self.scrubLayer) {
    CALayer *l = [CALayer layer];
    l.contentsGravity = kCAGravityResize;
    l.zPosition = 1;
    [self.playerLayer addSublayer:l];
    self.scrubLayer = l;
  }
  self.scrubLayer.contents = picture;
  self.scrubLayer.hidden = NO;
  [self scrubLayout];
  [CATransaction commit];
  self.scrubServed = YES;
  self.scrubShownMs = ms;
  self.scrubPicture = (__bridge CGImageRef)picture;
  [self stood];
  mb_host_request_frame();
  return YES;
}

// Its frames over the player's picture as the player shows it: filling the view (turned as the player turns them
// as they are kept).
- (void)scrubLayout {
  self.scrubLayer.frame = self.playerLayer.bounds;
}

// The player's picture shown again: the frames' over it gone.
- (void)scrubHide {
  self.scrubServed = NO;
  self.scrubLanding = NO;
  self.scrubPicture = NULL;
  if (!self.scrubLayer) return;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  self.scrubLayer.hidden = YES;
  self.scrubLayer.contents = nil;
  [CATransaction commit];
}

// The stretch before `ms` decoded and kept (one at a time: asked again meanwhile, the last asked once it is done,
// unless what it brings shows it).
- (void)scrubDecodeBefore:(double)ms {
  if (self.scrubDecoding) {
    self.scrubWant = ms;
    return;
  }
  AVAssetTrack *track = nil;
  for (AVPlayerItemTrack *t in self.item.tracks)
    if ([t.assetTrack.mediaType isEqualToString:AVMediaTypeVideo]) track = t.assetTrack;
  CGSize shown = self.item.presentationSize;
  if (!track || shown.width <= 0 || shown.height <= 0 || self.w <= 0 || self.h <= 0) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  CGAffineTransform t = track.preferredTransform;
  double fps = track.nominalFrameRate;
#pragma clang diagnostic pop
  if (!(fps > 0)) fps = 60;
  // (turned as its track says the player shows it: a phone's upright film, a quarter turn clockwise)
  double angle = atan2(t.b, t.a) * 180 / M_PI;
  CFStringRef turn = fabs(angle - 90) < 1     ? kVTRotation_CW90
                     : fabs(angle + 90) < 1   ? kVTRotation_CCW90
                     : fabs(fabs(angle) - 180) < 1 ? kVTRotation_180
                                              : NULL;
  BOOL sideways = turn == kVTRotation_CW90 || turn == kVTRotation_CCW90;
  // (at the view's size in points, never more than the film's own; the decoder's frames are not turned yet)
  double k = fmin(1.0, fmax(self.w / shown.width, self.h / shown.height));
  size_t tw = (size_t)fmax(2, round((sideways ? shown.height : shown.width) * k));
  size_t th = (size_t)fmax(2, round((sideways ? shown.width : shown.height) * k));
  double frame = 1000.0 / fps;
  double count = fmax(2, floor(kScrubKeep / ((double)tw * th * 4)));
  double dur = [self durationMs];
  double to = dur > 0 ? fmin(dur, ms + 2 * frame) : ms + 2 * frame;
  double from = fmax(0, ms - count * frame);
  self.scrubDecoding = YES;
  self.scrubWant = -1;
  int gen = self.scrubGen;
  int32_t vid = self.vid;
  AVAsset *asset = self.item.asset;
  __weak MBNative *wv = self;
  static dispatch_queue_t q;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ q = dispatch_queue_create("mbui.scrub", DISPATCH_QUEUE_SERIAL); });
  double t0 = CACurrentMediaTime();
  dispatch_async(q, ^{
    BOOL (^stale)(void) = ^BOOL { MBNative *v = wv; return !v || v.scrubGen != gen; };
    MBScrubFrames *f = stale() ? nil : scrub_decode(asset, track, from, to, tw, th, turn, stale);
    dispatch_async(dispatch_get_main_queue(), ^{
      MBNative *v = wv;
      if (!v) return;
      v.scrubDecoding = NO;
      if (v.closed || v.scrubGen != gen || !v.scrubbing) return;
      if (f) {
        v.scrubFrames = f;
        vlog(@"view %d: scrub frames %.0f-%.0f ms (%lu at %zux%zu) in %.0f ms", vid, f.from, f.to,
             (unsigned long)f.times.count, tw, th, (CACurrentMediaTime() - t0) * 1000);
      }
      // where the finger is now: shown from them, else (gone back past them meanwhile) the next stretch
      double now = v.scrubLastMs;
      if (now >= 0 && [v scrubShow:now]) {
        v.chasing = NO;
      } else if (v.scrubWant >= 0) {
        double want = v.scrubWant;
        v.scrubWant = -1;
        [v scrubDecodeBefore:want];
      }
    });
  });
}

@end

// The frames of `track` from `from` to `to` (ms), each at `tw` × `th` and then given `turn` (a VTRotation, or none),
// decoded in order (from the key frame before `from`): nil where the reader could not read them, or once `stale` says
// they are no longer wanted.
static MBScrubFrames *scrub_decode(AVAsset *asset, AVAssetTrack *track, double from, double to, size_t tw, size_t th,
                                   CFStringRef turn, BOOL (^stale)(void)) {
  NSError *e = nil;
  AVAssetReader *r = [AVAssetReader assetReaderWithAsset:asset error:&e];
  if (!r) return nil;
  r.timeRange = CMTimeRangeFromTimeToTime(CMTimeMake((int64_t)llround(from * 1000.0), 1000000),
                                          CMTimeMake((int64_t)llround(to * 1000.0), 1000000));
  NSDictionary *as = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
  };
  AVAssetReaderTrackOutput *o = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:as];
  o.alwaysCopiesSampleData = NO;
  if (![r canAddOutput:o]) return nil;
  [r addOutput:o];
  if (![r startReading]) return nil;
  VTPixelTransferSessionRef xfer = NULL;
  VTPixelRotationSessionRef rot = NULL;
  BOOL sideways = turn == kVTRotation_CW90 || turn == kVTRotation_CCW90;
  if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &xfer) != noErr ||
      (turn && (VTPixelRotationSessionCreate(kCFAllocatorDefault, &rot) != noErr ||
                VTSessionSetProperty(rot, kVTPixelRotationPropertyKey_Rotation, turn) != noErr))) {
    if (xfer) CFRelease(xfer);
    if (rot) CFRelease(rot);
    [r cancelReading];
    return nil;
  }
  NSMutableArray<NSNumber *> *times = [NSMutableArray new];
  NSMutableArray *pictures = [NSMutableArray new];
  CMSampleBufferRef sb;
  BOOL gaveUp = NO;
  while ((sb = [o copyNextSampleBuffer])) {
    if (stale()) {
      CFRelease(sb);
      gaveUp = YES;
      break;
    }
    CVImageBufferRef src = CMSampleBufferGetImageBuffer(sb);
    double pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb)) * 1000.0;
    if (src) {
      CVPixelBufferRef dst = NULL, turned = NULL;
      CGImageRef img = NULL;
      if (CVPixelBufferCreate(kCFAllocatorDefault, tw, th, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)as,
                              &dst) == kCVReturnSuccess &&
          VTPixelTransferSessionTransferImage(xfer, src, dst) == noErr &&
          (!rot || (CVPixelBufferCreate(kCFAllocatorDefault, sideways ? th : tw, sideways ? tw : th,
                                        kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)as,
                                        &turned) == kCVReturnSuccess &&
                    VTPixelRotationSessionRotateImage(rot, dst, turned) == noErr)) &&
          VTCreateCGImageFromCVPixelBuffer(turned ?: dst, NULL, &img) == noErr && img) {
        [times addObject:@(pts)];
        [pictures addObject:(__bridge_transfer id)img];
      }
      if (dst) CVPixelBufferRelease(dst);
      if (turned) CVPixelBufferRelease(turned);
    }
    CFRelease(sb);
  }
  VTPixelTransferSessionInvalidate(xfer);
  CFRelease(xfer);
  if (rot) {
    VTPixelRotationSessionInvalidate(rot);
    CFRelease(rot);
  }
  if (gaveUp) {
    [r cancelReading];
    return nil;
  }
  if (r.status != AVAssetReaderStatusCompleted || times.count == 0) return nil;
  // (in time order, whatever order the decoder gave them in)
  NSMutableArray<NSNumber *> *order = [NSMutableArray new];
  for (NSUInteger i = 0; i < times.count; i++) [order addObject:@(i)];
  [order sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
    return [times[a.unsignedIntegerValue] compare:times[b.unsignedIntegerValue]];
  }];
  NSMutableArray<NSNumber *> *sortedTimes = [NSMutableArray new];
  NSMutableArray *sortedPictures = [NSMutableArray new];
  for (NSNumber *i in order) {
    [sortedTimes addObject:times[i.unsignedIntegerValue]];
    [sortedPictures addObject:pictures[i.unsignedIntegerValue]];
  }
  times = sortedTimes;
  MBScrubFrames *f = [MBScrubFrames new];
  f.times = times;
  f.pictures = sortedPictures;
  f.from = times.firstObject.doubleValue;
  // (to the last one's end: as long as the one before it lasted)
  double last = times.lastObject.doubleValue;
  double step = times.count > 1 ? last - times[times.count - 2].doubleValue : 1000.0 / 60;
  f.to = fmin(to, last + step);
  return f;
}
