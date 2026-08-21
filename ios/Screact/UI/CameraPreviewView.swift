import AVFoundation
import SwiftUI

/// SwiftUI wrapper around AVCaptureVideoPreviewLayer, the iOS equivalent of the Compose
/// AndroidView(PreviewView). Uses aspect-fit so the full frame is visible (matches the Android
/// PreviewView.ScaleType.FIT_CENTER used for calibration).
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = UIColor(white: 0.85, alpha: 1.0)
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
    }

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
