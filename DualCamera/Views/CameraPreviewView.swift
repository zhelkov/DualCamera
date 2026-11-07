import SwiftUI
import AVFoundation
import UIKit

/// Обёртка для показа `AVCaptureVideoPreviewLayer` внутри SwiftUI.
struct CameraPreviewView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> PreviewContainerView {
        PreviewContainerView(previewLayer: previewLayer)
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        // Слой может смениться при перестановке камер местами.
        uiView.previewLayer = previewLayer
    }
}

/// UIView, который размещает превью-слой на весь свой размер.
final class PreviewContainerView: UIView {
    var previewLayer: AVCaptureVideoPreviewLayer {
        didSet {
            guard previewLayer !== oldValue else { return }
            oldValue.removeFromSuperlayer()
            layer.addSublayer(previewLayer)
            previewLayer.frame = bounds
        }
    }

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }
}
