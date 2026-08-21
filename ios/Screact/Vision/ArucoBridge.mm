#import "ArucoBridge.h"

// Only pull in OpenCV when its headers are present (resolved via the OpenCV Swift Package, see
// project.yml). This keeps the default dependency-free build compiling. objdetect carries the
// ArUco API in OpenCV 4.7+.
#if __has_include(<opencv2/objdetect/aruco_detector.hpp>)
  #define ARUCO_OPENCV_AVAILABLE 1
  // Import only the modules ArUco detection needs. The umbrella <opencv2/opencv.hpp> also drags in
  // the `stitching` module, whose enums use the identifier `NO` — which collides with the
  // Objective-C `NO` macro and fails to compile in this Objective-C++ translation unit.
  #import <opencv2/core.hpp>
  #import <opencv2/imgproc.hpp>
  #import <opencv2/objdetect/aruco_detector.hpp>
#else
  #define ARUCO_OPENCV_AVAILABLE 0
#endif

@implementation ArucoBridge

+ (BOOL)isAvailable {
    return ARUCO_OPENCV_AVAILABLE ? YES : NO;
}

- (NSArray<NSDictionary<NSString *, id> *> *)detectMarkersInPixelBuffer:(CVPixelBufferRef)pixelBuffer {
#if ARUCO_OPENCV_AVAILABLE
    if (pixelBuffer == NULL) { return @[]; }
    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    const int width = (int)CVPixelBufferGetWidth(pixelBuffer);
    const int height = (int)CVPixelBufferGetHeight(pixelBuffer);
    void *base = CVPixelBufferGetBaseAddress(pixelBuffer);
    const size_t stride = CVPixelBufferGetBytesPerRow(pixelBuffer);

    // Camera output is 32BGRA (see CameraSession.videoSettings).
    cv::Mat bgra((int)height, (int)width, CV_8UC4, base, stride);
    cv::Mat gray;
    cv::cvtColor(bgra, gray, cv::COLOR_BGRA2GRAY);

    static cv::aruco::ArucoDetector detector(
        cv::aruco::getPredefinedDictionary(cv::aruco::DICT_4X4_50),
        cv::aruco::DetectorParameters());

    std::vector<std::vector<cv::Point2f>> corners;
    std::vector<int> ids;
    detector.detectMarkers(gray, corners, ids);

    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    NSMutableArray<NSDictionary<NSString *, id> *> *result = [NSMutableArray array];
    for (size_t i = 0; i < ids.size(); i++) {
        if (corners[i].size() != 4) { continue; }
        NSMutableArray<NSNumber *> *flat = [NSMutableArray arrayWithCapacity:8];
        for (const cv::Point2f &p : corners[i]) {
            [flat addObject:@(p.x)];
            [flat addObject:@(p.y)];
        }
        [result addObject:@{ @"id": @(ids[i]),
                             @"corners": flat,
                             @"width": @(width),
                             @"height": @(height) }];
    }
    return result;
#else
    (void)pixelBuffer;
    return @[];
#endif
}

@end
