import AVFoundation
import CoreImage
import UIKit

/// Writes the already-composited camera frame as it arrives from AVCaptureMultiCamSession.
/// This is an experimental path; the legacy AVAssetExportSession pipeline remains available.
final class RealtimeCompositeRecorder {
    struct FrameState {
        let layout: CaptureLayout
        let pipShape: PipShape
        let splitOrientation: SplitOrientation
        let camerasSwapped: Bool
        let pipOffsetFraction: CGSize
        let pipWidthFraction: CGFloat
        let photo: UIImage?
        let photoOffsetFraction: CGSize
        let photoWidthFraction: CGFloat
        let drawing: [DrawingElement]
    }

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let renderSize: CGSize
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let lock = NSLock()
    private var started = false
    private var stopped = false
    private var sessionStartTime = CMTime.invalid
    private var receivedVideoFrames = 0
    private var appendedVideoFrames = 0
    private var lastVideoError: String?

    init(url: URL, renderSize: CGSize) throws {
        self.renderSize = renderSize
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60
            ]
        ])
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 128_000
        ])
        videoInput.expectsMediaDataInRealTime = true
        audioInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(renderSize.width),
                kCVPixelBufferHeightKey as String: Int(renderSize.height),
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ]
        )
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw CameraError.videoMergeFailed
        }
        writer.add(videoInput)
        writer.add(audioInput)
        guard writer.startWriting() else {
            throw writer.error ?? CameraError.videoMergeFailed
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard started, !stopped, audioInput.isReadyForMoreMediaData,
              CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= sessionStartTime,
              writer.status == .writing else { return }
        _ = audioInput.append(sampleBuffer)
    }

    func appendVideo(back: CVPixelBuffer,
                     front: CVPixelBuffer,
                     time: CMTime,
                     state: FrameState) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, writer.status == .writing else { return }
        receivedVideoFrames += 1

        if !started {
            writer.startSession(atSourceTime: time)
            sessionStartTime = time
            started = true
        }
        // AVAssetWriter doesn't create the adaptor's pool until the writing session starts.
        guard videoInput.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else {
            lastVideoError = "Writer не готов принять кадр или буферный пул недоступен."
            return
        }

        var outputBuffer: CVPixelBuffer?
        let poolStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputBuffer)
        guard poolStatus == kCVReturnSuccess,
              let outputBuffer,
              let image = compose(back: CIImage(cvPixelBuffer: back),
                                  front: CIImage(cvPixelBuffer: front),
                                  state: state) else {
            lastVideoError = "Не удалось подготовить кадр (код буферного пула \(poolStatus))."
            return
        }

        ciContext.render(image, to: outputBuffer,
                         bounds: CGRect(origin: .zero, size: renderSize),
                         colorSpace: colorSpace)
        if adaptor.append(outputBuffer, withPresentationTime: time) {
            appendedVideoFrames += 1
        } else {
            lastVideoError = writer.error?.localizedDescription ?? "AVAssetWriter не принял собранный видеокадр."
        }
    }

    func finish(completion: @escaping (Result<URL, Error>) -> Void) {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            completion(.failure(CameraError.videoMergeFailed))
            return
        }
        stopped = true
        guard started else {
            let error = NSError(domain: "DualCamera.RealtimeRecorder",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey:
                                    "Синхронный захват передал кадров до запуска writer: \(receivedVideoFrames)."])
            lock.unlock()
            writer.cancelWriting()
            completion(.failure(error))
            return
        }
        videoInput.markAsFinished()
        audioInput.markAsFinished()
        lock.unlock()

        writer.finishWriting { [writer] in
            if writer.status == .completed, self.appendedVideoFrames > 0 {
                completion(.success(writer.outputURL))
            } else {
                let details = "Экспериментальная запись: получено кадров — \(self.receivedVideoFrames), записано — \(self.appendedVideoFrames)."
                let message = [writer.error?.localizedDescription, self.lastVideoError, details]
                    .compactMap { $0 }
                    .joined(separator: " ")
                completion(.failure(NSError(domain: "DualCamera.RealtimeRecorder",
                                            code: 2,
                                            userInfo: [NSLocalizedDescriptionKey: message])))
            }
        }
    }

    private func compose(back: CIImage, front: CIImage, state: FrameState) -> CIImage? {
        let canvas = CGRect(origin: .zero, size: renderSize)
        let rawMain = state.camerasSwapped ? front : back
        let rawSmall = state.camerasSwapped ? back : front
        let mainSource = state.camerasSwapped ? mirrorHorizontally(rawMain) : rawMain
        let smallSource = state.camerasSwapped ? rawSmall : mirrorHorizontally(rawSmall)
        var composed: CIImage

        switch state.layout {
        case .splitScreen:
            let first: CGRect
            let second: CGRect
            if state.splitOrientation == .vertical {
                first = CGRect(x: 0, y: renderSize.height / 2,
                               width: renderSize.width, height: renderSize.height / 2)
                second = CGRect(x: 0, y: 0,
                                width: renderSize.width, height: renderSize.height / 2)
            } else {
                first = CGRect(x: 0, y: 0,
                               width: renderSize.width / 2, height: renderSize.height)
                second = CGRect(x: renderSize.width / 2, y: 0,
                                width: renderSize.width / 2, height: renderSize.height)
            }
            composed = fill(mainSource, in: first).composited(over: fill(smallSource, in: second))
        case .pip:
            composed = fill(mainSource, in: canvas)
            let width = min(renderSize.width, renderSize.height) * state.pipWidthFraction
            let height = width * state.pipShape.aspectRatio
            let rect = CGRect(
                x: min(max(0, renderSize.width - width - 16 + state.pipOffsetFraction.width * renderSize.width), renderSize.width - width),
                y: min(max(0, 16 - state.pipOffsetFraction.height * renderSize.height), renderSize.height - height),
                width: width,
                height: height
            )
            let pip = fill(smallSource, in: rect)
            guard let mask = shapeMask(rect, canvas: canvas, shape: state.pipShape) else { return nil }
            let blend = CIFilter.blendWithMask()
            blend.inputImage = pip
            blend.backgroundImage = composed
            blend.maskImage = mask
            guard let output = blend.outputImage else { return nil }
            composed = output
        }

        if !state.drawing.isEmpty,
           let drawingCG = DrawingRenderer.render(state.drawing, size: renderSize).cgImage {
            composed = CIImage(cgImage: drawingCG).composited(over: composed)
        }

        if let photo = state.photo, let photoCI = normalizedPhoto(photo) {
            let width = renderSize.width * state.photoWidthFraction
            let height = width * photoCI.extent.height / max(photoCI.extent.width, 1)
            let rect = CGRect(x: min(max(0, 16 + state.photoOffsetFraction.width * renderSize.width), renderSize.width - width),
                              y: min(max(0, renderSize.height - 16 - height - state.photoOffsetFraction.height * renderSize.height), renderSize.height - height),
                              width: width, height: height)
            let placed = fill(photoCI, in: rect)
            if let mask = shapeMask(rect, canvas: canvas, shape: .rectangle, radiusFraction: 0.03) {
                let blend = CIFilter.blendWithMask()
                blend.inputImage = placed
                blend.backgroundImage = composed
                blend.maskImage = mask
                composed = blend.outputImage ?? composed
            }
        }
        return composed.cropped(to: canvas)
    }

    private func fill(_ image: CIImage, in rect: CGRect) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, rect.width > 0, rect.height > 0 else {
            return CIImage(color: .black).cropped(to: rect)
        }
        let scale = max(rect.width / extent.width, rect.height / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let x = rect.midX - scaled.extent.width / 2
        let y = rect.midY - scaled.extent.height / 2
        return scaled.transformed(by: CGAffineTransform(translationX: x - scaled.extent.minX,
                                                        y: y - scaled.extent.minY))
            .cropped(to: rect)
    }

    private func mirrorHorizontally(_ image: CIImage) -> CIImage {
        let bounds = image.extent
        return image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1,
                                                       tx: bounds.minX + bounds.maxX, ty: 0))
    }

    private func normalizedPhoto(_ image: UIImage) -> CIImage? {
        let source: CIImage
        if let cgImage = image.cgImage {
            source = CIImage(cgImage: cgImage)
        } else if let ciImage = image.ciImage {
            source = ciImage
        } else {
            return nil
        }
        let orientation: Int32
        switch image.imageOrientation {
        case .up: orientation = 1
        case .upMirrored: orientation = 2
        case .down: orientation = 3
        case .downMirrored: orientation = 4
        case .leftMirrored: orientation = 5
        case .right: orientation = 6
        case .rightMirrored: orientation = 7
        case .left: orientation = 8
        @unknown default: orientation = 1
        }
        let oriented = source.oriented(forExifOrientation: orientation)
        let bounds = oriented.extent.integral
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return oriented.transformed(by: CGAffineTransform(translationX: -bounds.minX,
                                                          y: -bounds.minY))
    }

    private func shapeMask(_ rect: CGRect,
                           canvas: CGRect,
                           shape: PipShape,
                           radiusFraction: CGFloat? = nil) -> CIImage? {
        switch shape {
        case .circle:
            let filter = CIFilter.radialGradient()
            filter.center = CGPoint(x: rect.midX, y: rect.midY)
            filter.radius0 = Float(min(rect.width, rect.height) / 2 - 1)
            filter.radius1 = Float(min(rect.width, rect.height) / 2 + 1)
            filter.color0 = .white
            filter.color1 = .black
            return filter.outputImage?.cropped(to: canvas)
        case .rectangle, .square:
            let fraction = radiusFraction ?? (shape == .rectangle ? 0.137 : 0.103)
            let portraitScale = min(canvas.width, canvas.height) / max(canvas.width, 1)
            let radius = min(rect.width * fraction * portraitScale, rect.height / 2)
            let filter = CIFilter.roundedRectangleGenerator()
            filter.extent = rect
            filter.radius = Float(radius)
            filter.color = .white
            return filter.outputImage?.cropped(to: canvas)
        }
    }
}
