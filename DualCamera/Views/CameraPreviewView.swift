import SwiftUI
import AVFoundation
import UIKit
import Combine

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

/// Показывает кадры передней камеры в отдельном UIKit-контейнере.
struct FrontCameraImageView: UIViewRepresentable {
    @ObservedObject var store: FrontCameraPreviewStore

    func makeUIView(context: Context) -> FrontCameraImageContainerView {
        FrontCameraImageContainerView(store: store)
    }

    func updateUIView(_ uiView: FrontCameraImageContainerView, context: Context) {
        uiView.update(image: store.image)
    }
}

final class FrontCameraImageContainerView: UIView {
    private let imageView = UIImageView()
    init(store: FrontCameraPreviewStore) {
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.transform = CGAffineTransform(scaleX: -1, y: 1)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        update(image: store.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(image: UIImage?) {
        imageView.image = image
    }
}
