import AVFoundation
import UIKit

/// Объединяет два записанных клипа (передняя и задняя камеры) в один файл.
enum VideoMerger {

    static func merge(back: URL, front: URL, layout: CaptureLayout, shape: PipShape, splitOrientation: SplitOrientation = .vertical, elements: [DrawingElement] = []) async throws -> URL {
        let backAsset = AVURLAsset(url: back)
        let frontAsset = AVURLAsset(url: front)

        let backClip = try await ClipInfo(asset: backAsset)
        let frontClip = try await ClipInfo(asset: frontAsset)

        // Обрезаем по короткому клипу, чтобы оба кадра совпали по длине.
        let duration = CMTimeMinimum(backClip.duration, frontClip.duration)

        // Итоговый кадр — размер вертикального видео основной камеры.
        let canvas = backClip.displaySize

        // Рисунок поверх видео (если есть элементы).
        let drawingImage = elements.isEmpty ? nil : DrawingRenderer.render(elements, size: canvas)

        let composition = AVMutableComposition()
        guard let backCompTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ), let frontCompTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw CameraError.videoMergeFailed
        }

        let timeRange = CMTimeRange(start: .zero, duration: duration)
        try backCompTrack.insertTimeRange(timeRange, of: backClip.track, at: .zero)
        try frontCompTrack.insertTimeRange(timeRange, of: frontClip.track, at: .zero)

        // Звук берём из клипа основной камеры (в обоих файлах он одинаковый).
        if let backAudioTrack = try await backAsset.loadTracks(withMediaType: .audio).first,
           let audioCompTrack = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try audioCompTrack.insertTimeRange(timeRange, of: backAudioTrack, at: .zero)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.renderSize = canvas

        switch layout {
        case .splitScreen:
            videoComposition.instructions = [
                splitInstruction(timeRange: timeRange,
                                 canvas: canvas,
                                 splitOrientation: splitOrientation,
                                 backClip: backClip,
                                 frontClip: frontClip,
                                 backTrack: backCompTrack,
                                 frontTrack: frontCompTrack)
            ]
            // Рисунок накладываем отдельным Core Animation слоем.
            if let drawingImage {
                videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
                    additionalLayer: drawingOverlayLayer(image: drawingImage, canvas: canvas),
                    asTrackID: kCMPersistentTrackID_Invalid
                )
            }
        case .pip:
            // PiP через Core Animation — так работают скругления и круг.
            videoComposition.animationTool = pipAnimationTool(canvas: canvas, shape: shape, drawingImage: drawingImage)
        }

        let outputURL = Self.mergedMovieURL()
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw CameraError.videoMergeFailed
        }
        exporter.videoComposition = videoComposition
        exporter.outputURL = outputURL
        exporter.outputFileType = .mov

        try await Self.runExport(exporter)
        return outputURL
    }

    /// Сплит: два клипа друг под другом через layer-инструкции.
    private static func splitInstruction(timeRange: CMTimeRange,
                                         canvas: CGSize,
                                         splitOrientation: SplitOrientation,
                                         backClip: ClipInfo,
                                         frontClip: ClipInfo,
                                         backTrack: AVMutableCompositionTrack,
                                         frontTrack: AVMutableCompositionTrack) -> AVMutableVideoCompositionInstruction {
        let backRect: CGRect
        let frontRect: CGRect
        if splitOrientation == .horizontal {
            // Ландшафт: бок о бок.
            backRect = CGRect(x: 0, y: 0, width: canvas.width / 2, height: canvas.height)
            frontRect = CGRect(x: canvas.width / 2, y: 0, width: canvas.width / 2, height: canvas.height)
        } else {
            // Портрет: друг под другом.
            backRect = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height / 2)
            frontRect = CGRect(x: 0, y: canvas.height / 2, width: canvas.width, height: canvas.height / 2)
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = timeRange

        let backLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: backTrack)
        backLayer.setTransform(makeTransform(for: backClip, targetRect: backRect), at: .zero)

        let frontLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: frontTrack)
        frontLayer.setTransform(makeTransform(for: frontClip, targetRect: frontRect), at: .zero)

        instruction.layerInstructions = [backLayer, frontLayer]
        return instruction
    }

    /// PiP: основная камера на весь кадр, вторая — в окне заданной формы.
    /// Собирается через Core Animation, чтобы работали скругления и круг.
    private static func pipAnimationTool(canvas: CGSize, shape: PipShape, drawingImage: UIImage?) -> AVVideoCompositionCoreAnimationTool {
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: canvas)
        // Видео рисуется сверху вниз, поэтому переворачиваем геометрию слоя.
        parentLayer.isGeometryFlipped = true

        let backLayer = CALayer()
        backLayer.frame = CGRect(origin: .zero, size: canvas)
        backLayer.contentsGravity = .resizeAspectFill

        let pipWidth = canvas.width * 0.25
        let pipHeight = pipWidth * shape.aspectRatio
        let pipRect = CGRect(x: canvas.width - pipWidth - 16,
                             y: canvas.height - pipHeight - 16,
                             width: pipWidth,
                             height: pipHeight)

        let frontLayer = CALayer()
        frontLayer.frame = pipRect
        frontLayer.contentsGravity = .resizeAspectFill
        frontLayer.masksToBounds = true
        switch shape {
        case .rectangle: frontLayer.cornerRadius = 16
        case .square: frontLayer.cornerRadius = 12
        case .circle: frontLayer.cornerRadius = pipWidth / 2
        }

        parentLayer.addSublayer(backLayer)
        parentLayer.addSublayer(frontLayer)

        if let drawingImage {
            parentLayer.addSublayer(drawingOverlayLayer(image: drawingImage, canvas: canvas))
        }

        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayers: [backLayer, frontLayer], in: parentLayer)
    }

    /// Слой рисунка, растянутый на весь кадр.
    private static func drawingOverlayLayer(image: UIImage, canvas: CGSize) -> CALayer {
        let layer = CALayer()
        layer.frame = CGRect(origin: .zero, size: canvas)
        layer.contents = image.cgImage
        layer.contentsGravity = .resize
        layer.isGeometryFlipped = true
        return layer
    }

    /// Считает трансформацию, которая ставит клип вертикально
    /// и вписывает его в целевой прямоугольник (по центру, без обрезки).
    private static func makeTransform(for clip: ClipInfo, targetRect: CGRect) -> CGAffineTransform {
        // 1. Применяем preferredTransform — приводит кадр в вертикальную ориентацию.
        var transform = clip.preferredTransform

        // 2. Масштаб: вписываем весь кадр в целевой прямоугольник.
        let scaleX = targetRect.width / clip.displaySize.width
        let scaleY = targetRect.height / clip.displaySize.height
        let scale = min(scaleX, scaleY)
        transform = transform.scaledBy(x: scale, y: scale)

        // 3. Центрируем кадр внутри целевого прямоугольника.
        let scaledWidth = clip.displaySize.width * scale
        let scaledHeight = clip.displaySize.height * scale
        let dx = targetRect.midX - scaledWidth / 2
        let dy = targetRect.midY - scaledHeight / 2
        transform = transform.translatedBy(x: dx, y: dy)

        return transform
    }

    private static func runExport(_ exporter: AVAssetExportSession) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: exporter.error ?? CameraError.videoMergeFailed)
                case .cancelled:
                    continuation.resume(throwing: CameraError.videoMergeFailed)
                default:
                    continuation.resume(throwing: CameraError.videoMergeFailed)
                }
            }
        }
    }

    private static func mergedMovieURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dualcamera-merged-\(UUID().uuidString).mov")
    }

    /// Готовый к использованию трек вместе с ориентацией и размером.
    private struct ClipInfo {
        let track: AVAssetTrack
        let preferredTransform: CGAffineTransform
        let duration: CMTime
        let displaySize: CGSize

        init(asset: AVURLAsset) async throws {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                throw CameraError.videoMergeFailed
            }
            let transform = try await videoTrack.load(.preferredTransform)
            let naturalSize = try await videoTrack.load(.naturalSize)
            let duration = try await asset.load(.duration)

            self.track = videoTrack
            self.preferredTransform = transform
            self.duration = duration

            // При повороте на 90/270° меняем ширину и высоту местами.
            if abs(transform.b) > 0.5 || abs(transform.c) > 0.5 {
                self.displaySize = CGSize(width: naturalSize.height, height: naturalSize.width)
            } else {
                self.displaySize = naturalSize
            }
        }
    }
}
