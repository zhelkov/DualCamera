import SwiftUI
import AVFoundation
import UIKit

/// Обёртка для показа `AVCaptureVideoPreviewLayer` внутри SwiftUI.
struct CameraPreviewView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer
    let isMirrored: Bool

    func makeUIView(context: Context) -> PreviewContainerView {
        PreviewContainerView(previewLayer: previewLayer, isMirrored: isMirrored)
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        // Слой может смениться при перестановке камер местами.
        uiView.previewLayer = previewLayer
        uiView.isMirrored = isMirrored
    }
}

/// UIView, который размещает превью-слой на весь свой размер.
final class PreviewContainerView: UIView {
    var isMirrored: Bool {
        didSet { transform = isMirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity }
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        didSet {
            guard previewLayer !== oldValue else { return }
            oldValue.removeFromSuperlayer()
            layer.addSublayer(previewLayer)
            previewLayer.frame = bounds
        }
    }

    init(previewLayer: AVCaptureVideoPreviewLayer, isMirrored: Bool) {
        self.previewLayer = previewLayer
        self.isMirrored = isMirrored
        super.init(frame: .zero)
        transform = isMirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
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

/// Показывает необработанные кадры из AVCaptureVideoDataOutput для диагностики.
struct SampleBufferPreviewView: UIViewRepresentable {
    let sampleBufferLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> SampleBufferContainerView {
        SampleBufferContainerView(sampleBufferLayer: sampleBufferLayer)
    }

    func updateUIView(_ uiView: SampleBufferContainerView, context: Context) {}
}

final class SampleBufferContainerView: UIView {
    private let sampleBufferLayer: AVSampleBufferDisplayLayer

    init(sampleBufferLayer: AVSampleBufferDisplayLayer) {
        self.sampleBufferLayer = sampleBufferLayer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(sampleBufferLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        sampleBufferLayer.frame = bounds
    }
}
