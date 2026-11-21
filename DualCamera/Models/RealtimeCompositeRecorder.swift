import AVFoundation
import CoreImage
import UIKit

/// Writes the already-composited camera frame as it arrives from AVCaptureMultiCamSession.
final class RealtimeCompositeRecorder {
    struct FrameState {
        let layout: CaptureLayout
        let pipShape: PipShape
        let splitOrientation: SplitOrientation
        let splitRatio: CGFloat
        let isSecondaryCameraVisible: Bool
        let videoFilter: VideoFilter
        let filterTarget: VideoFilterTarget
        let camerasSwapped: Bool
        let pipOffsetFraction: CGSize
        let pipWidthFraction: CGFloat
        let photo: UIImage?
        let photoOffsetFraction: CGSize
        let photoWidthFraction: CGFloat
        let drawing: [DrawingElement]
        let dateTimeEnabled: Bool
        let recordingStartDate: Date?
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
    private var cachedTimestampSecond: Int?
    private var cachedTimestamp: CIImage?
    private var synchronizationCallbacks = 0
    private var backSamplesPresent = 0
    private var frontSamplesPresent = 0
    private var backSamplesDropped = 0
    private var frontSamplesDropped = 0

    init(url: URL,
         renderSize: CGSize,
         frameRate: VideoFrameRate,
         audioQuality: AudioRecordingQuality) throws {
        self.renderSize = renderSize
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let targetBitRate = Int(renderSize.width * renderSize.height
                                * CGFloat(frameRate.rawValue) * 0.12)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: min(max(targetBitRate, 4_000_000), 60_000_000),
                AVVideoExpectedSourceFrameRateKey: frameRate.rawValue,
                AVVideoMaxKeyFrameIntervalKey: frameRate.rawValue * 2
            ]
        ])
        let audioSettings: [String: Any]
        switch audioQuality {
        case .aac:
            audioSettings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: 128_000
            ]
        case .appleLossless:
            audioSettings = [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44_100,
                AVEncoderBitDepthHintKey: 16,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
        }
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
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
        if #available(iOS 18.0, *) {
            let playbackIntent = AVMutableMetadataItem()
            playbackIntent.identifier = .quickTimeMetadataFullFrameRatePlaybackIntent
            playbackIntent.dataType = kCMMetadataBaseDataType_UInt8 as String
            playbackIntent.value = NSNumber(value: 1)
            writer.metadata = [playbackIntent]
        }
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

    func recordSynchronizationEvent(backPresent: Bool,
                                    frontPresent: Bool,
                                    backDropped: Bool,
                                    frontDropped: Bool) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        synchronizationCallbacks += 1
        if backPresent { backSamplesPresent += 1 }
        if frontPresent { frontSamplesPresent += 1 }
        if backDropped { backSamplesDropped += 1 }
        if frontDropped { frontSamplesDropped += 1 }
        lock.unlock()
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
        guard poolStatus == kCVReturnSuccess, let outputBuffer else {
            lastVideoError = "Не удалось подготовить кадр (код буферного пула \(poolStatus))."
            return
        }
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(time, sessionStartTime))
        guard let image = compose(back: CIImage(cvPixelBuffer: back),
                                  front: CIImage(cvPixelBuffer: front),
                                  state: state,
                                  elapsed: elapsed) else {
            if lastVideoError == nil {
                lastVideoError = CameraError.videoMergeFailed.errorDescription
            }
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
            let syncDetails = "Synchronizer callbacks: \(synchronizationCallbacks); back samples: \(backSamplesPresent), dropped: \(backSamplesDropped); front samples: \(frontSamplesPresent), dropped: \(frontSamplesDropped)."
            let error = NSError(domain: "DualCamera.RealtimeRecorder",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Синхронный захват передал кадров до запуска writer: \(receivedVideoFrames). \(syncDetails)"])
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
                let details = "Синхронная запись: синхронизатор вызван \(self.synchronizationCallbacks) раз; получено кадров — \(self.receivedVideoFrames), записано — \(self.appendedVideoFrames); образцы задней камеры — \(self.backSamplesPresent) (пропуски \(self.backSamplesDropped)), передней — \(self.frontSamplesPresent) (пропуски \(self.frontSamplesDropped))."
                let message = [writer.error?.localizedDescription, self.lastVideoError, details]
                    .compactMap { $0 }
                    .joined(separator: " ")
                completion(.failure(NSError(domain: "DualCamera.RealtimeRecorder",
                                            code: 2,
                                            userInfo: [NSLocalizedDescriptionKey: message])))
            }
        }
    }

    private func compose(back: CIImage,
                         front: CIImage,
                         state: FrameState,
                         elapsed: TimeInterval) -> CIImage? {
        let canvas = CGRect(origin: .zero, size: renderSize)
        let rawMain = state.camerasSwapped ? front : back
        let rawSmall = state.camerasSwapped ? back : front
        let filteredMain: CIImage
        let filteredSmall: CIImage
        do {
            if state.filterTarget == .primary {
                filteredMain = try state.videoFilter.applying(to: rawMain)
                filteredSmall = rawSmall
            } else {
                filteredMain = rawMain
                filteredSmall = try state.videoFilter.applying(to: rawSmall)
            }
        } catch {
            lastVideoError = error.localizedDescription
            return nil
        }
        let mainSource = state.camerasSwapped ? mirrorHorizontally(filteredMain) : filteredMain
        let smallSource = state.camerasSwapped ? filteredSmall : mirrorHorizontally(filteredSmall)
        var composed: CIImage

        switch state.layout {
        case .splitScreen:
            if !state.isSecondaryCameraVisible {
                composed = fill(mainSource, in: canvas)
            } else {
                let first: CGRect
                let second: CGRect
                if state.splitOrientation == .vertical {
                    let splitY = renderSize.height * state.splitRatio
                    first = CGRect(x: 0, y: renderSize.height - splitY,
                                   width: renderSize.width, height: splitY)
                    second = CGRect(x: 0, y: 0,
                                    width: renderSize.width, height: renderSize.height - splitY)
                } else {
                    let splitX = renderSize.width * state.splitRatio
                    first = CGRect(x: 0, y: 0,
                                   width: splitX, height: renderSize.height)
                    second = CGRect(x: splitX, y: 0,
                                    width: renderSize.width - splitX, height: renderSize.height)
                }
                composed = fill(mainSource, in: first).composited(over: fill(smallSource, in: second))
            }
        case .pip:
            composed = fill(mainSource, in: canvas)
            let width = min(renderSize.width, renderSize.height) * state.pipWidthFraction
            let height = width * state.pipShape.aspectRatio
            let rect = CGRect(
                x: min(max(0, 16 + state.pipOffsetFraction.width * renderSize.width), renderSize.width - width),
                y: min(max(0, renderSize.height - height - 16
                           - state.pipOffsetFraction.height * renderSize.height),
                       renderSize.height - height),
                width: width,
                height: height
            )
            if state.isSecondaryCameraVisible {
                let pip = fill(smallSource, in: rect)
                guard let mask = shapeMask(rect, canvas: canvas, shape: state.pipShape) else { return nil }
                let blend = CIFilter.blendWithMask()
                blend.inputImage = pip
                blend.backgroundImage = composed
                blend.maskImage = mask
                guard let output = blend.outputImage else { return nil }
                composed = output
            }
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
        if state.dateTimeEnabled, let startDate = state.recordingStartDate,
           let timestamp = timestampOverlay(at: startDate.addingTimeInterval(elapsed)) {
            composed = timestamp.composited(over: composed)
        }
        return composed.cropped(to: canvas)
    }

    private func timestampOverlay(at date: Date) -> CIImage? {
        let second = Int(date.timeIntervalSince1970)
        if cachedTimestampSecond == second { return cachedTimestamp }
        let image = DrawingRenderer.renderTimestamp(date, size: renderSize)
        guard let cgImage = image.cgImage else { return nil }
        let overlay = CIImage(cgImage: cgImage)
        cachedTimestampSecond = second
        cachedTimestamp = overlay
        return overlay
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
