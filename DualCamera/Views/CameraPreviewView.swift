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

struct FilteredCameraPreviewView: View {
    let image: UIImage
    let isMirrored: Bool

    var body: some View {
        GeometryReader { geometry in
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(x: isMirrored ? -1 : 1, y: 1)
                .clipped()
        }
    }
}

/// UIView, который размещает превью-слой на весь свой размер.
final class PreviewContainerView: UIView {
    var isMirrored: Bool {
        didSet { updatePreviewLayerTransform() }
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        didSet {
            guard previewLayer !== oldValue else { return }
            oldValue.removeFromSuperlayer()
            layer.addSublayer(previewLayer)
            previewLayer.frame = bounds
            updatePreviewLayerTransform()
        }
    }

    init(previewLayer: AVCaptureVideoPreviewLayer, isMirrored: Bool) {
        self.previewLayer = previewLayer
        self.isMirrored = isMirrored
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(previewLayer)
        previewLayer.frame = bounds
        updatePreviewLayerTransform()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        updatePreviewLayerTransform()
    }

    private func updatePreviewLayerTransform() {
        previewLayer.setAffineTransform(
            isMirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        )
    }
}
