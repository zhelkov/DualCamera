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
        case .pip:
            videoComposition.instructions = [
                pipInstruction(timeRange: timeRange,
                               canvas: canvas,
                               shape: shape,
                               backClip: backClip,
                               frontClip: frontClip,
                               backTrack: backCompTrack,
                               frontTrack: frontCompTrack)
            ]
        }

        if let drawingImage {
            videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
                additionalLayer: drawingOverlayLayer(image: drawingImage, canvas: canvas),
                asTrackID: kCMPersistentTrackID_Invalid
            )
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

        let backPlacement = makePlacement(for: backClip, targetRect: backRect)
        let backLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: backTrack)
        backLayer.setCropRectangle(backPlacement.cropRect, at: .zero)
        backLayer.setTransform(backPlacement.transform, at: .zero)

        let frontPlacement = makePlacement(for: frontClip, targetRect: frontRect)
        let frontLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: frontTrack)
        frontLayer.setCropRectangle(frontPlacement.cropRect, at: .zero)
        frontLayer.setTransform(frontPlacement.transform, at: .zero)

        instruction.layerInstructions = [frontLayer, backLayer]
        return instruction
    }

    /// PiP: основная камера заполняет кадр, вторая камера занимает маленькое окно.
    private static func pipInstruction(timeRange: CMTimeRange,
                                       canvas: CGSize,
                                       shape: PipShape,
                                       backClip: ClipInfo,
                                       frontClip: ClipInfo,
                                       backTrack: AVMutableCompositionTrack,
                                       frontTrack: AVMutableCompositionTrack) -> AVMutableVideoCompositionInstruction {
        let pipWidth = canvas.width * 0.25
        let pipHeight = pipWidth * shape.aspectRatio
        let pipRect = CGRect(x: canvas.width - pipWidth - 16,
                             y: canvas.height - pipHeight - 16,
                             width: pipWidth,
                             height: pipHeight)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = timeRange

        let backPlacement = makePlacement(for: backClip,
                                          targetRect: CGRect(origin: .zero, size: canvas))
        let backLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: backTrack)
        backLayer.setCropRectangle(backPlacement.cropRect, at: .zero)
        backLayer.setTransform(backPlacement.transform, at: .zero)

        let frontPlacement = makePlacement(for: frontClip, targetRect: pipRect)
        let frontLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: frontTrack)
        frontLayer.setCropRectangle(frontPlacement.cropRect, at: .zero)
        frontLayer.setTransform(frontPlacement.transform, at: .zero)

        instruction.layerInstructions = [frontLayer, backLayer]
        return instruction
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
    private static func makePlacement(for clip: ClipInfo, targetRect: CGRect) -> Placement {
        // 1. Применяем preferredTransform — приводит кадр в вертикальную ориентацию.
        let targetAspect = targetRect.width / targetRect.height
        let sourceAspect = clip.displaySize.width / clip.displaySize.height
        let displayCrop: CGRect
        if sourceAspect > targetAspect {
            let width = clip.displaySize.height * targetAspect
            displayCrop = CGRect(x: (clip.displaySize.width - width) / 2, y: 0,
                                 width: width, height: clip.displaySize.height)
        } else {
            let height = clip.displaySize.width / targetAspect
            displayCrop = CGRect(x: 0, y: (clip.displaySize.height - height) / 2,
                                 width: clip.displaySize.width, height: height)
        }
        let sourceCrop = displayCrop.applying(clip.preferredTransform.inverted()).standardized
        let scale = targetRect.width / displayCrop.width
        let transform = CGAffineTransform(
            a: clip.preferredTransform.a * scale,
            b: clip.preferredTransform.b * scale,
            c: clip.preferredTransform.c * scale,
            d: clip.preferredTransform.d * scale,
            tx: (clip.preferredTransform.tx - displayCrop.minX) * scale + targetRect.minX,
            ty: (clip.preferredTransform.ty - displayCrop.minY) * scale + targetRect.minY
        )
        return Placement(cropRect: sourceCrop, transform: transform)

        /*

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

        return Placement(cropRect: .zero, transform: transform)
        */
    }

    private struct Placement {
        let cropRect: CGRect
        let transform: CGAffineTransform
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
            self.displaySize = CGRect(origin: .zero, size: naturalSize)
                .applying(transform)
                .standardized
                .size
        }
    }
}
