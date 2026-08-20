#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C++ bridge to OpenCV's ArUco detector (DICT_4X4_50). Compiles with or without OpenCV:
/// when the opencv2 headers are absent (`pod install` not yet run) `isAvailable` is NO and detection
/// returns an empty array, keeping the pure-Swift build green. Once the OpenCV pod is installed the
/// same file performs real detection — no Swift changes required.
///
/// Each detected marker is returned as a dictionary:
///   @{ @"id": NSNumber, @"corners": @[x0,y0, x1,y1, x2,y2, x3,y3], @"width": w, @"height": h }
/// with corner coordinates in source pixels (Swift normalizes them by width/height).
@interface ArucoBridge : NSObject
@property (class, nonatomic, readonly) BOOL isAvailable;
- (NSArray<NSDictionary<NSString *, id> *> *)detectMarkersInPixelBuffer:(CVPixelBufferRef)pixelBuffer;
@end

NS_ASSUME_NONNULL_END
