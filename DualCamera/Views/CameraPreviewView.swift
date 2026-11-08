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

/// Показывает кадры передней камеры как обычные изображения SwiftUI.
struct FrontCameraImageView: View {
    let camera: CameraManager

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.black
                if let image = camera.frontProbeImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .scaleEffect(x: -1, y: 1)
                }
                Text(camera.frontProbeStatus)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                    .padding(6)
            }
        }
        .clipped()
    }
}
