import AVFoundation
import CoreImage
import UIKit

/// Объединяет два записанных клипа (передняя и задняя камеры) в один файл.
enum VideoMerger {

    static func merge(back: URL,
                      front: URL,
                      layout: CaptureLayout,
                      shape: PipShape,
                      splitOrientation: SplitOrientation = .vertical,
                      pipOffsetFraction: CGSize = .zero,
                      pipWidthFraction: CGFloat = 0.3,
                      pipPositionKeyframes: [PipPositionKeyframe] = [],
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
        let normalizedBackImage = Self.normalizedCIImage(backImage)
        let normalizedFrontImage = Self.normalizedCIImage(frontImage)
        let normalizedPhotoOverlay = Self.normalizedCIImage(photoOverlay)
        guard (backImage == nil || normalizedBackImage != nil),
              (frontImage == nil || normalizedFrontImage != nil),
              (photoOverlay == nil || normalizedPhotoOverlay != nil) else {
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

        var photoTrackID: CMPersistentTrackID?
        var stillPhotoMovieURL: URL?
        defer {
            if let stillPhotoMovieURL {
                try? FileManager.default.removeItem(at: stillPhotoMovieURL)
            }
        }
        if let normalizedPhotoOverlay {
            let movieURL = try await Self.createStillPhotoMovie(from: normalizedPhotoOverlay,
                                                                duration: duration)
            stillPhotoMovieURL = movieURL
            let photoAsset = AVURLAsset(url: movieURL)
            guard let photoSourceTrack = try await photoAsset.loadTracks(withMediaType: .video).first,
                  let photoCompTrack = composition.addMutableTrack(
                    withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else {
                throw CameraError.videoMergeFailed
            }
            try photoCompTrack.insertTimeRange(timeRange, of: photoSourceTrack, at: .zero)
            photoTrackID = photoCompTrack.trackID
        }

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
                photoTrackID: photoTrackID,
                canvasSize: canvas,
                layout: layout,
                splitOrientation: splitOrientation,
                shape: shape,
                pipOffsetFraction: pipOffsetFraction,
                pipWidthFraction: pipWidthFraction,
                pipPositionKeyframes: pipPositionKeyframes,
                drawingKeyframes: effectiveDrawingKeyframes,
                photoOverlayKeyframes: photoOverlayKeyframes.isEmpty
                    ? [PhotoOverlayKeyframe(time: 0,
                                            offsetFraction: photoOverlayOffsetFraction,
                                            widthFraction: photoOverlayWidthFraction)]
                    : photoOverlayKeyframes,
                backTransform: backClip.preferredTransform,
                frontTransform: frontClip.preferredTransform,
                backSourceSize: backClip.naturalSize,
                frontSourceSize: frontClip.naturalSize,
                backImage: normalizedBackImage,
                frontImage: normalizedFrontImage
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

    private static func createStillPhotoMovie(from image: CIImage,
                                              duration: CMTime) async throws -> URL {
        let width = max(2, Int(image.extent.width) / 2 * 2)
        let height = max(2, Int(image.extent.height) / 2 * 2)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dualcamera-photo-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video,
                                       outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                        AVVideoWidthKey: width,
                                                        AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ]
        )
        guard writer.canAdd(input) else { throw CameraError.videoMergeFailed }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? CameraError.videoMergeFailed
        }
        writer.startSession(atSourceTime: .zero)

        let frameCount = max(1, Int64(ceil(duration.seconds * 30)))
        let renderRect = CGRect(x: 0, y: 0, width: width, height: height)
        let scaledImage = image.transformed(by: CGAffineTransform(
            scaleX: CGFloat(width) / max(image.extent.width, 1),
            y: CGFloat(height) / max(image.extent.height, 1)
        )).cropped(to: renderRect)
        let ciContext = CIContext(options: [.cacheIntermediates: false])
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let queue = DispatchQueue(label: "com.dualcamera.photo-track-writer")
        var succeeded = false
        defer {
            if !succeeded {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var frameIndex: Int64 = 0
            var didFinish = false
            input.requestMediaDataWhenReady(on: queue) {
                guard !didFinish else { return }
                while input.isReadyForMoreMediaData {
                    if frameIndex >= frameCount {
                        didFinish = true
                        input.markAsFinished()
                        writer.finishWriting {
                            if writer.status == .completed {
                                continuation.resume()
                            } else {
                                continuation.resume(throwing: writer.error ?? CameraError.videoMergeFailed)
                            }
                        }
                        return
                    }

                    guard let pool = adaptor.pixelBufferPool else {
                        didFinish = true
                        writer.cancelWriting()
                        continuation.resume(throwing: CameraError.videoMergeFailed)
                        return
                    }
                    var optionalBuffer: CVPixelBuffer?
                    let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &optionalBuffer)
                    guard status == kCVReturnSuccess, let buffer = optionalBuffer else {
                        didFinish = true
                        writer.cancelWriting()
                        continuation.resume(throwing: CameraError.videoMergeFailed)
                        return
                    }
                    ciContext.render(scaledImage,
                                     to: buffer,
                                     bounds: renderRect,
                                     colorSpace: colorSpace)
                    let presentationTime = CMTime(value: frameIndex, timescale: 30)
                    guard adaptor.append(buffer, withPresentationTime: presentationTime) else {
                        didFinish = true
                        writer.cancelWriting()
                        continuation.resume(throwing: writer.error ?? CameraError.videoMergeFailed)
                        return
                    }
                    frameIndex += 1
                }
            }
        }
        succeeded = true
        return outputURL
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
