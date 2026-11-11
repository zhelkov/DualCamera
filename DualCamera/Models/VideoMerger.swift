import AVFoundation
import CoreImage
import QuartzCore
import UIKit

/// Объединяет два записанных клипа (передняя и задняя камеры) в один файл.
enum VideoMerger {

    private struct PhotoSegment {
        let id: UUID
        let image: UIImage
        let keyframes: [PhotoOverlayKeyframe]
        let startTime: Double
        let endTime: Double
    }

    static func merge(back: URL,
                      front: URL,
                      layout: CaptureLayout,
                      shape: PipShape,
                      splitOrientation: SplitOrientation = .vertical,
                      pipOffsetFraction: CGSize = .zero,
                      pipWidthFraction: CGFloat = 0.3,
                      pipPositionKeyframes: [PipPositionKeyframe] = [],
                      layoutKeyframes: [CaptureLayoutKeyframe] = [],
                      cameraSwapKeyframes: [CameraSwapKeyframe] = [],
                      initialCamerasSwapped: Bool = false,
                      drawingKeyframes: [DrawingElementsKeyframe] = [],
                      photoOverlay: UIImage? = nil,
                      photoOverlayOffsetFraction: CGSize = .zero,
                      photoOverlayWidthFraction: CGFloat = 0.3,
                      photoOverlayKeyframes: [PhotoOverlayKeyframe] = [],
                      backImage: UIImage? = nil,
                      frontImage: UIImage? = nil,
                      elements: [DrawingElement] = []) async throws -> URL {
        let backAsset = AVURLAsset(url: back)
        let frontAsset = AVURLAsset(url: front)

        let backClip = try await ClipInfo(asset: backAsset)
        let frontClip = try await ClipInfo(asset: frontAsset)

        // Обрезаем по короткому клипу, чтобы оба кадра совпали по длине.
        let duration = CMTimeMinimum(backClip.duration, frontClip.duration)

        // Итоговый кадр — размер вертикального видео основной камеры.
        let canvas = backClip.displaySize

        // Рисунок поверх видео (если есть элементы).
        let effectiveDrawingKeyframes = drawingKeyframes.isEmpty
            ? [DrawingElementsKeyframe(time: 0, elements: elements)]
            : drawingKeyframes
        let effectivePhotoKeyframes: [PhotoOverlayKeyframe]
        if photoOverlayKeyframes.isEmpty, let photoOverlay {
            effectivePhotoKeyframes = [PhotoOverlayKeyframe(time: 0,
                                                              offsetFraction: photoOverlayOffsetFraction,
                                                              widthFraction: photoOverlayWidthFraction,
                                                              image: photoOverlay,
                                                              imageID: UUID())]
        } else {
            effectivePhotoKeyframes = photoOverlayKeyframes
        }
        let effectiveLayoutKeyframes = layoutKeyframes.isEmpty
            ? [CaptureLayoutKeyframe(time: 0,
                                     layout: layout,
                                     shape: shape,
                                     splitOrientation: splitOrientation)]
            : layoutKeyframes
        let normalizedBackImage = Self.normalizedCIImage(backImage)
        let normalizedFrontImage = Self.normalizedCIImage(frontImage)
        guard (backImage == nil || normalizedBackImage != nil),
              (frontImage == nil || normalizedFrontImage != nil) else {
            throw CameraError.videoMergeFailed
        }

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

        videoComposition.customVideoCompositorClass = DualCameraVideoCompositor.self
        videoComposition.instructions = [
            DualCameraVideoCompositionInstruction(
                timeRange: timeRange,
                backTrackID: backCompTrack.trackID,
                frontTrackID: frontCompTrack.trackID,
                canvasSize: canvas,
                layout: layout,
                splitOrientation: splitOrientation,
                shape: shape,
                pipOffsetFraction: pipOffsetFraction,
                pipWidthFraction: pipWidthFraction,
                pipPositionKeyframes: pipPositionKeyframes,
                drawingKeyframes: effectiveDrawingKeyframes,
                backTransform: backClip.preferredTransform,
                frontTransform: frontClip.preferredTransform,
                backSourceSize: backClip.naturalSize,
                frontSourceSize: frontClip.naturalSize,
                backImage: normalizedBackImage,
                frontImage: normalizedFrontImage,
                layoutKeyframes: effectiveLayoutKeyframes,
                cameraSwapKeyframes: cameraSwapKeyframes,
                initialCamerasSwapped: initialCamerasSwapped
            )
        ]

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
        guard effectivePhotoKeyframes.contains(where: { $0.image != nil }) else { return outputURL }
        do {
            let photoURL = try await Self.addPhotoOverlay(
                to: outputURL,
                keyframes: effectivePhotoKeyframes
            )
            try? FileManager.default.removeItem(at: outputURL)
            return photoURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    /// Applies the still image in a second, standard AVFoundation export pass.
    /// This keeps the working custom camera/drawing compositor independent from
    /// the Core Animation photo layer.
    private static func addPhotoOverlay(to sourceURL: URL,
                                        keyframes: [PhotoOverlayKeyframe]) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let sourceTrack = videoTracks.first else { throw CameraError.videoMergeFailed }

        let duration = try await asset.load(.duration)
        let naturalSize = try await sourceTrack.load(.naturalSize)
        let sourceTransform = try await sourceTrack.load(.preferredTransform)
        let sourceBounds = CGRect(origin: .zero, size: naturalSize)
            .applying(sourceTransform)
            .standardized
        guard sourceBounds.width > 0, sourceBounds.height > 0,
              duration.seconds.isFinite, duration.seconds > 0 else {
            throw CameraError.videoMergeFailed
        }

        let renderSize = sourceBounds.size
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw CameraError.videoMergeFailed }
        let timeRange = CMTimeRange(start: .zero, duration: duration)
        try videoTrack.insertTimeRange(timeRange, of: sourceTrack, at: .zero)

        for audioTrack in try await asset.loadTracks(withMediaType: .audio) {
            guard let destination = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            let audioRange = try await audioTrack.load(.timeRange)
            let copyDuration = CMTimeMinimum(duration, audioRange.duration)
            if copyDuration > .zero {
                try destination.insertTimeRange(CMTimeRange(start: .zero, duration: copyDuration),
                                                of: audioTrack,
                                                at: .zero)
            }
        }

        let normalizedTransform = CGAffineTransform(a: sourceTransform.a,
                                                    b: sourceTransform.b,
                                                    c: sourceTransform.c,
                                                    d: sourceTransform.d,
                                                    tx: sourceTransform.tx - sourceBounds.minX,
                                                    ty: sourceTransform.ty - sourceBounds.minY)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = timeRange
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(normalizedTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.bounds
        parentLayer.addSublayer(videoLayer)

        let segments = photoSegments(from: keyframes, duration: duration.seconds)
        guard !segments.isEmpty else { throw CameraError.videoMergeFailed }
        for segment in segments {
            guard let normalizedPhoto = normalizedUIImage(segment.image),
                  let photoCGImage = normalizedPhoto.cgImage else {
                throw CameraError.videoMergeFailed
            }
            let photoImage = UIImage(cgImage: photoCGImage, scale: 1, orientation: .up)
            let photoLayer = CALayer()
            photoLayer.contents = photoCGImage
            photoLayer.contentsGravity = .resizeAspectFill
            photoLayer.masksToBounds = true
            photoLayer.cornerRadius = 10
            photoLayer.opacity = 0
            parentLayer.addSublayer(photoLayer)

            let rects = photoRects(size: renderSize, photo: photoImage,
                                   keyframes: segment.keyframes,
                                   duration: duration)
            guard let first = rects.first else { throw CameraError.videoMergeFailed }
            photoLayer.bounds = CGRect(origin: .zero, size: first.rect.size)
            photoLayer.position = CGPoint(x: first.rect.midX,
                                          y: renderSize.height - first.rect.midY)
            if rects.count > 1 {
                let keyTimes = rects.map { NSNumber(value: $0.time / duration.seconds) }
                let position = CAKeyframeAnimation(keyPath: "position")
                position.values = rects.map {
                    NSValue(cgPoint: CGPoint(x: $0.rect.midX,
                                             y: renderSize.height - $0.rect.midY))
                }
                position.keyTimes = keyTimes
                position.calculationMode = .linear
                position.beginTime = AVCoreAnimationBeginTimeAtZero
                position.duration = duration.seconds
                position.fillMode = .both
                position.isRemovedOnCompletion = false
                photoLayer.add(position, forKey: "photo.position")

                let bounds = CAKeyframeAnimation(keyPath: "bounds")
                bounds.values = rects.map { NSValue(cgRect: CGRect(origin: .zero, size: $0.rect.size)) }
                bounds.keyTimes = keyTimes
                bounds.calculationMode = .linear
                bounds.beginTime = AVCoreAnimationBeginTimeAtZero
                bounds.duration = duration.seconds
                bounds.fillMode = .both
                bounds.isRemovedOnCompletion = false
                photoLayer.add(bounds, forKey: "photo.bounds")
            }
            addVisibilityAnimation(to: photoLayer,
                                   start: segment.startTime,
                                   end: segment.endTime,
                                   duration: duration.seconds)
        }

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )
        let outputURL = mergedMovieURL()
        guard let exporter = AVAssetExportSession(asset: composition,
                                                   presetName: AVAssetExportPresetHighestQuality) else {
            throw CameraError.videoMergeFailed
        }
        exporter.videoComposition = videoComposition
        exporter.outputURL = outputURL
        exporter.outputFileType = .mov
        try await runExport(exporter)
        return outputURL
    }

    private static func photoSegments(from keyframes: [PhotoOverlayKeyframe],
                                      duration: Double) -> [PhotoSegment] {
        var segments: [PhotoSegment] = []
        var activeID: UUID?
        var activeImage: UIImage?
        var activeKeyframes: [PhotoOverlayKeyframe] = []
        var activeStart = 0.0

        func finishActive(at endTime: Double) {
            guard let activeID, let activeImage, !activeKeyframes.isEmpty,
                  endTime > activeStart else { return }
            segments.append(PhotoSegment(id: activeID,
                                         image: activeImage,
                                         keyframes: activeKeyframes,
                                         startTime: activeStart,
                                         endTime: endTime))
        }

        for frame in keyframes {
            let time = min(max(0, frame.time), duration)
            if let image = frame.image, let imageID = frame.imageID {
                if activeID == imageID {
                    activeKeyframes.append(PhotoOverlayKeyframe(time: time,
                                                                offsetFraction: frame.offsetFraction,
                                                                widthFraction: frame.widthFraction,
                                                                image: image,
                                                                imageID: imageID))
                } else {
                    finishActive(at: time)
                    activeID = imageID
                    activeImage = image
                    activeStart = time
                    activeKeyframes = [PhotoOverlayKeyframe(time: time,
                                                            offsetFraction: frame.offsetFraction,
                                                            widthFraction: frame.widthFraction,
                                                            image: image,
                                                            imageID: imageID)]
                }
            } else if activeID != nil {
                finishActive(at: time)
                activeID = nil
                activeImage = nil
                activeKeyframes = []
            }
        }
        finishActive(at: duration)
        return segments
    }

    private static func addVisibilityAnimation(to layer: CALayer,
                                                start: Double,
                                                end: Double,
                                                duration: Double) {
        guard duration > 0 else { return }
        let startTime = min(max(0, start / duration), 1)
        let endTime = min(max(startTime, end / duration), 1)
        let epsilon = min(1, endTime + 0.00001)
        var values: [NSNumber] = []
        var keyTimes: [NSNumber] = []

        if startTime > 0 {
            values.append(0); keyTimes.append(0)
            values.append(1); keyTimes.append(NSNumber(value: startTime))
        } else {
            values.append(1); keyTimes.append(0)
        }
        if endTime < 1 {
            values.append(1); keyTimes.append(NSNumber(value: endTime))
            values.append(0); keyTimes.append(NSNumber(value: epsilon))
            if epsilon < 1 {
                values.append(0); keyTimes.append(1)
            }
        } else if keyTimes.last?.doubleValue != 1 {
            values.append(1); keyTimes.append(1)
        }

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = values
        opacity.keyTimes = keyTimes
        opacity.calculationMode = .discrete
        opacity.beginTime = AVCoreAnimationBeginTimeAtZero
        opacity.duration = duration
        opacity.fillMode = .both
        opacity.isRemovedOnCompletion = false
        layer.add(opacity, forKey: "photo.opacity")
    }

    private static func photoRects(size: CGSize,
                                   photo: UIImage,
                                   keyframes: [PhotoOverlayKeyframe],
                                   duration: CMTime) -> [(time: Double, rect: CGRect)] {
        var result: [(time: Double, rect: CGRect)] = []
        for frame in keyframes {
            let time = min(max(0, frame.time), duration.seconds)
            let width = size.width * min(max(frame.widthFraction, 0.01), 1)
            let height = width * photo.size.height / max(photo.size.width, 1)
            guard width > 0, height > 0, height <= size.height else { continue }
            let x = min(max(0, 16 + frame.offsetFraction.width * size.width), size.width - width)
            let y = min(max(0, 16 + frame.offsetFraction.height * size.height), size.height - height)
            let rect = CGRect(x: x, y: y, width: width, height: height)
            if result.last?.time == time {
                result[result.count - 1] = (time, rect)
            } else {
                result.append((time, rect))
            }
        }
        return result
    }

    /// UIKit drawing normalizes UIImage orientation the same way as the working
    /// still-photo path, while limiting the bitmap size for video overlay export.
    private static func normalizedUIImage(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        var pixelWidth = cgImage.width
        var pixelHeight = cgImage.height
        switch image.imageOrientation {
        case .left, .right, .leftMirrored, .rightMirrored:
            swap(&pixelWidth, &pixelHeight)
        default:
            break
        }
        let scale = min(1, 1920 / CGFloat(max(pixelWidth, pixelHeight)))
        let size = CGSize(width: CGFloat(pixelWidth) * scale,
                          height: CGFloat(pixelHeight) * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
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

    private static func normalizedCIImage(_ image: UIImage?) -> CIImage? {
        guard let image else { return nil }
        let source: CIImage
        if let cgImage = image.cgImage {
            source = CIImage(cgImage: cgImage)
        } else if let ciImage = image.ciImage {
            source = ciImage
        } else {
            return nil
        }

        let exifOrientation: Int32
        switch image.imageOrientation {
        case .up: exifOrientation = 1
        case .upMirrored: exifOrientation = 2
        case .down: exifOrientation = 3
        case .downMirrored: exifOrientation = 4
        case .leftMirrored: exifOrientation = 5
        case .right: exifOrientation = 6
        case .rightMirrored: exifOrientation = 7
        case .left: exifOrientation = 8
        @unknown default: exifOrientation = 1
        }

        let oriented = source.oriented(forExifOrientation: exifOrientation)
        let extent = oriented.extent.integral
        guard extent.width > 0, extent.height > 0 else { return nil }
        let translated = oriented.transformed(by: CGAffineTransform(translationX: -extent.minX,
                                                                     y: -extent.minY))
        let scale = min(1, 1920 / max(extent.width, extent.height))
        let outputSize = CGSize(width: extent.width * scale,
                                height: extent.height * scale)
        return translated.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: CGRect(origin: .zero, size: outputSize))
    }

    /// Готовый к использованию трек вместе с ориентацией и размером.
    private struct ClipInfo {
        let track: AVAssetTrack
        let preferredTransform: CGAffineTransform
        let duration: CMTime
        let displaySize: CGSize
        let naturalSize: CGSize

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
            self.naturalSize = naturalSize

            // При повороте на 90/270° меняем ширину и высоту местами.
            self.displaySize = CGRect(origin: .zero, size: naturalSize)
                .applying(transform)
                .standardized
                .size
        }
    }
}
