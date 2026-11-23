import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

struct PipPositionKeyframe {
    let time: TimeInterval
    let offsetFraction: CGSize
    let widthFraction: CGFloat
    /// Точный прямоугольник окна в долях кадра, если известен.
    var rectFraction: CGRect? = nil
}

struct CaptureLayoutKeyframe {
    let time: TimeInterval
    let layout: CaptureLayout
    let shape: PipShape
    let splitOrientation: SplitOrientation
    let splitRatio: CGFloat
    let isSecondaryCameraVisible: Bool
}

struct CameraSwapKeyframe {
    let time: TimeInterval
    let isSwapped: Bool
}

struct DrawingElementsKeyframe {
    let time: TimeInterval
    let elements: [DrawingElement]
}

struct PhotoOverlayKeyframe {
    let time: TimeInterval
    let offsetFraction: CGSize
    let widthFraction: CGFloat
    let image: UIImage?
    let imageID: UUID?
}

final class DualCameraVideoCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceSampleDataTrackIDs: [NSNumber] = []

    let backTrackID: CMPersistentTrackID
    let frontTrackID: CMPersistentTrackID
    let canvasSize: CGSize
    let layout: CaptureLayout
    let splitOrientation: SplitOrientation
    let shape: PipShape
    let mirrorFrontCamera: Bool
    let pipOffsetFraction: CGSize
    let pipWidthFraction: CGFloat
    var pipRectFraction: CGRect? = nil
    let pipPositionKeyframes: [PipPositionKeyframe]
    let drawingKeyframes: [DrawingElementsKeyframe]
    let backTransform: CGAffineTransform
    let frontTransform: CGAffineTransform
    let backSourceSize: CGSize
    let frontSourceSize: CGSize
    let backImage: CIImage?
    let frontImage: CIImage?
    let layoutKeyframes: [CaptureLayoutKeyframe]
    let cameraSwapKeyframes: [CameraSwapKeyframe]
    let videoFilter: VideoFilter
    let filterTarget: VideoFilterTarget
    let filterKeyframes: [VideoFilterKeyframe]
    let initialCamerasSwapped: Bool
    let dateTimeEnabled: Bool
    let timestampStartDate: Date?

    var requiredSourceTrackIDs: [NSValue]? {
        [NSNumber(value: backTrackID) as NSValue,
         NSNumber(value: frontTrackID) as NSValue]
    }

    init(timeRange: CMTimeRange,
         backTrackID: CMPersistentTrackID,
         frontTrackID: CMPersistentTrackID,
         canvasSize: CGSize,
         layout: CaptureLayout,
         splitOrientation: SplitOrientation,
         shape: PipShape,
         mirrorFrontCamera: Bool,
         pipOffsetFraction: CGSize,
         pipWidthFraction: CGFloat,
         pipRectFraction: CGRect? = nil,
         pipPositionKeyframes: [PipPositionKeyframe],
         drawingKeyframes: [DrawingElementsKeyframe],
         backTransform: CGAffineTransform,
         frontTransform: CGAffineTransform,
         backSourceSize: CGSize,
         frontSourceSize: CGSize,
         backImage: CIImage?,
         frontImage: CIImage?,
         layoutKeyframes: [CaptureLayoutKeyframe],
         cameraSwapKeyframes: [CameraSwapKeyframe],
         videoFilter: VideoFilter,
         filterTarget: VideoFilterTarget,
         filterKeyframes: [VideoFilterKeyframe],
         initialCamerasSwapped: Bool,
         dateTimeEnabled: Bool,
         timestampStartDate: Date?) {
        self.timeRange = timeRange
        self.backTrackID = backTrackID
        self.frontTrackID = frontTrackID
        self.canvasSize = canvasSize
        self.layout = layout
        self.splitOrientation = splitOrientation
        self.shape = shape
        self.mirrorFrontCamera = mirrorFrontCamera
        self.pipOffsetFraction = pipOffsetFraction
        self.pipWidthFraction = pipWidthFraction
        self.pipRectFraction = pipRectFraction
        self.pipPositionKeyframes = pipPositionKeyframes
        self.drawingKeyframes = drawingKeyframes
        self.backTransform = backTransform
        self.frontTransform = frontTransform
        self.backSourceSize = backSourceSize
        self.frontSourceSize = frontSourceSize
        self.backImage = backImage
        self.frontImage = frontImage
        self.layoutKeyframes = layoutKeyframes
        self.cameraSwapKeyframes = cameraSwapKeyframes
        self.videoFilter = videoFilter
        self.filterTarget = filterTarget
        self.filterKeyframes = filterKeyframes
        self.initialCamerasSwapped = initialCamerasSwapped
        self.dateTimeEnabled = dateTimeEnabled
        self.timestampStartDate = timestampStartDate
    }
}

final class DualCameraVideoCompositor: NSObject, AVVideoCompositing {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let overlayCacheLock = NSLock()
    private var overlayCache: [Int: CIImage] = [:]
    private var overlayCacheOrder: [Int] = []
    private var cachedTimestampSecond: Int?
    private var cachedTimestamp: CIImage?

    var sourcePixelBufferAttributes: [String: Any]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: Any] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? DualCameraVideoCompositionInstruction,
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "DualCameraVideoCompositor",
                                         code: 1,
                                         userInfo: [NSLocalizedDescriptionKey: "Не удалось подготовить кадр видеокомпозиции."]))
            return
        }

        do {
            let canvas = CGRect(origin: .zero, size: instruction.canvasSize)
            var backRect: CGRect
            var frontRect: CGRect
            let captureLayout = captureLayoutAt(instruction,
                                                time: request.compositionTime.seconds)
            switch captureLayout.layout {
            case .pip:
                let layout = layoutAt(instruction, time: request.compositionTime.seconds)
                let rectFraction = pipRectAt(instruction, time: request.compositionTime.seconds)
                let width: CGFloat
                let height: CGFloat
                let rawX: CGFloat
                let rawY: CGFloat
                if let rectFraction {
                    width = rectFraction.width * instruction.canvasSize.width
                    height = rectFraction.height * instruction.canvasSize.height
                    rawX = rectFraction.minX * instruction.canvasSize.width
                    rawY = rectFraction.minY * instruction.canvasSize.height
                } else {
                    width = min(instruction.canvasSize.width, instruction.canvasSize.height)
                        * layout.widthFraction
                    height = width * captureLayout.shape.aspectRatio
                    rawX = layout.offset.width * instruction.canvasSize.width
                    rawY = layout.offset.height * instruction.canvasSize.height
                }
                // Окно задаём в координатах «сверху-слева» и держим небольшой
                // отступ от края кадра.
                let margin: CGFloat = 2
                let x = min(max(margin, rawX),
                            max(margin, instruction.canvasSize.width - width - margin))
                let y = min(max(margin, rawY),
                            max(margin, instruction.canvasSize.height - height - margin))
                // Двойное зеркало здесь не нужно: итоговый кадр всё равно
                // переворачивается на 180°, и прямоугольник вернулся бы
                // в противоположный угол.
                frontRect = captureLayout.isSecondaryCameraVisible
                    ? CGRect(x: x, y: y, width: width, height: height)
                    : .zero
                backRect = canvas
            case .splitScreen:
                if !captureLayout.isSecondaryCameraVisible {
                    backRect = canvas
                    frontRect = .zero
                } else if captureLayout.splitOrientation == .horizontal {
                    let splitX = instruction.canvasSize.width * captureLayout.splitRatio
                    backRect = CGRect(x: 0, y: 0,
                                      width: splitX,
                                      height: instruction.canvasSize.height)
                    frontRect = CGRect(x: splitX, y: 0,
                                       width: instruction.canvasSize.width - splitX,
                                       height: instruction.canvasSize.height)
                } else {
                    let splitY = instruction.canvasSize.height * captureLayout.splitRatio
                    backRect = CGRect(x: 0, y: 0,
                                      width: instruction.canvasSize.width, height: splitY)
                    frontRect = CGRect(x: 0, y: splitY,
                                       width: instruction.canvasSize.width,
                                       height: instruction.canvasSize.height - splitY)
                }
                backRect = backRect.verticallyMirrored(in: instruction.canvasSize.height)
                frontRect = frontRect.verticallyMirrored(in: instruction.canvasSize.height)
                backRect = backRect.horizontallyMirrored(in: instruction.canvasSize.width)
                frontRect = frontRect.horizontallyMirrored(in: instruction.canvasSize.width)
            }

            let backSource: CIImage?
            if let image = instruction.backImage {
                backSource = image
            } else if let buffer = request.sourceFrame(byTrackID: instruction.backTrackID) {
                backSource = CIImage(cvPixelBuffer: buffer)
            } else {
                backSource = nil
            }
            let frontSource: CIImage?
            if let image = instruction.frontImage {
                frontSource = image
            } else if let buffer = request.sourceFrame(byTrackID: instruction.frontTrackID) {
                frontSource = CIImage(cvPixelBuffer: buffer)
            } else {
                frontSource = nil
            }
            guard let backSource, let frontSource else {
                throw NSError(domain: "DualCameraVideoCompositor",
                              code: 2,
                              userInfo: [NSLocalizedDescriptionKey:
                                            "Не получены видеокадры источников \(instruction.backTrackID) и \(instruction.frontTrackID) в момент \(request.compositionTime.seconds) с."])
            }

            let swapState = cameraSwapAt(instruction, time: request.compositionTime.seconds)
            let swapSources = swapState.isSwapped != instruction.initialCamerasSwapped
            let mainSource = swapSources ? frontSource : backSource
            let secondarySource = swapSources ? backSource : frontSource
            let filterState = filterAt(instruction, time: request.compositionTime.seconds)
            let filteredMainSource: CIImage
            let filteredSecondarySource: CIImage
            if filterState.target == .primary {
                filteredMainSource = try filterState.filter.applying(to: mainSource)
                filteredSecondarySource = secondarySource
            } else {
                filteredMainSource = mainSource
                filteredSecondarySource = try filterState.filter.applying(to: secondarySource)
            }
            let mainSize = swapSources ? instruction.frontSourceSize : instruction.backSourceSize
            let secondarySize = swapSources ? instruction.backSourceSize : instruction.frontSourceSize
            // Both camera outputs capture the same interface orientation. Use
            // the primary track's orientation matrix for both source frames so
            // the front sensor's native sensor rotation doesn't turn its PiP.
            let mainTransform = swapSources ? instruction.frontTransform : instruction.backTransform
            let secondaryTransform = swapSources ? instruction.backTransform : instruction.frontTransform
            let mainIsCameraVideo = swapSources
                ? instruction.frontImage == nil
                : instruction.backImage == nil
            let secondaryIsCameraVideo = swapSources
                ? instruction.backImage == nil
                : instruction.frontImage == nil
            let mainIsFrontCamera = instruction.mirrorFrontCamera
                && (swapSources ? !instruction.initialCamerasSwapped : instruction.initialCamerasSwapped)
            let secondaryIsFrontCamera = instruction.mirrorFrontCamera && !mainIsFrontCamera
            let mainCell = frontRectForCoreImage(backRect,
                                                  canvasHeight: instruction.canvasSize.height)
            let placedMain = place(filteredMainSource,
                                   sourceSize: instruction.backImage == nil ? mainSize : filteredMainSource.extent.size,
                                   transform: instruction.backImage == nil ? mainTransform : .identity,
                                   in: backRect,
                                   canvasHeight: instruction.canvasSize.height)
            let isLandscape = instruction.canvasSize.width > instruction.canvasSize.height
            let mainWithMirror = mainIsFrontCamera
                ? mirrorForFinalVideo(placedMain, inside: mainCell)
                : placedMain
            let main = isLandscape && mainIsCameraVideo
                ? rotateHalfTurn(mainWithMirror, inside: mainCell)
                : mainWithMirror
            var composed = main.cropped(to: canvas)
            if captureLayout.isSecondaryCameraVisible {
                let frontCell = frontRectForCoreImage(frontRect,
                                                       canvasHeight: instruction.canvasSize.height)
                let placedFront = place(filteredSecondarySource,
                                        sourceSize: instruction.frontImage == nil ? secondarySize : filteredSecondarySource.extent.size,
                                        transform: instruction.frontImage == nil ? secondaryTransform : .identity,
                                        in: frontRect,
                                        canvasHeight: instruction.canvasSize.height)
                let frontWithMirror = secondaryIsFrontCamera
                    ? mirrorForFinalVideo(placedFront, inside: frontCell)
                    : placedFront
                let front = isLandscape && secondaryIsCameraVideo
                    ? rotateHalfTurn(frontWithMirror, inside: frontCell)
                    : frontWithMirror

                if captureLayout.layout == .pip {
                    let frontBottomRect = CGRect(x: frontRect.minX,
                                                 y: instruction.canvasSize.height - frontRect.maxY,
                                                 width: frontRect.width,
                                                 height: frontRect.height)
                    let maskImage: CIImage?
                    switch captureLayout.shape {
                    case .circle:
                        let center = CGPoint(x: frontBottomRect.midX, y: frontBottomRect.midY)
                        let radius = min(frontBottomRect.width, frontBottomRect.height) / 2
                        let mask = CIFilter.radialGradient()
                        mask.center = center
                        mask.radius0 = Float(max(0, radius - 0.5))
                        mask.radius1 = Float(radius + 0.5)
                        mask.color0 = CIColor.white
                        mask.color1 = CIColor.black
                        maskImage = mask.outputImage?.cropped(to: canvas)
                    case .rectangle, .square:
                        let radiusFraction: CGFloat = captureLayout.shape == .rectangle ? 0.137 : 0.103
                        let portraitScale = min(instruction.canvasSize.width,
                                                instruction.canvasSize.height)
                            / max(instruction.canvasSize.width, 1)
                        let radius = min(frontBottomRect.width * radiusFraction * portraitScale,
                                         frontBottomRect.height / 2)
                        let mask = CIFilter.roundedRectangleGenerator()
                        mask.extent = frontBottomRect
                        mask.radius = Float(radius)
                        mask.color = CIColor.white
                        maskImage = mask.outputImage?.cropped(to: canvas)
                    }
                    guard let maskImage else {
                        throw CameraError.videoMergeFailed
                    }
                    let blend = CIFilter.blendWithMask()
                    blend.inputImage = front.cropped(to: canvas)
                    blend.backgroundImage = composed
                    blend.maskImage = maskImage
                    guard let outputImage = blend.outputImage else {
                        throw CameraError.videoMergeFailed
                    }
                    composed = outputImage
                } else {
                    composed = front.cropped(to: frontCell).composited(over: composed)
                }
            }

            if let overlayImage = drawingOverlay(at: request.compositionTime.seconds,
                                                 keyframes: instruction.drawingKeyframes,
                                                 canvasSize: instruction.canvasSize) {
                let correctedOverlay = overlayImage.transformed(by: CGAffineTransform(a: -1, b: 0,
                                                                                         c: 0, d: -1,
                                                                                         tx: instruction.canvasSize.width,
                                                                                         ty: instruction.canvasSize.height))
                let overlay = place(correctedOverlay,
                                    sourceSize: instruction.canvasSize,
                                    transform: .identity,
                                    in: CGRect(origin: .zero, size: instruction.canvasSize),
                                    canvasHeight: instruction.canvasSize.height)
                composed = overlay.composited(over: composed)
            }

            if instruction.dateTimeEnabled,
               let startDate = instruction.timestampStartDate,
               let overlayImage = timestampOverlay(
                at: startDate.addingTimeInterval(request.compositionTime.seconds),
                canvasSize: instruction.canvasSize
               ) {
                let correctedOverlay = overlayImage.transformed(by: CGAffineTransform(a: -1, b: 0,
                                                                                       c: 0, d: -1,
                                                                                       tx: canvas.width,
                                                                                       ty: canvas.height))
                let overlay = place(correctedOverlay,
                                    sourceSize: instruction.canvasSize,
                                    transform: .identity,
                                    in: canvas,
                                    canvasHeight: instruction.canvasSize.height)
                composed = overlay.composited(over: composed)
            }

            let uprightFrame = composed.transformed(by: CGAffineTransform(a: -1, b: 0,
                                                                           c: 0, d: -1,
                                                                           tx: canvas.width,
                                                                           ty: canvas.height))
            context.render(uprightFrame.cropped(to: canvas),
                           to: output,
                           bounds: canvas,
                           colorSpace: colorSpace)
            request.finish(withComposedVideoFrame: output)
        } catch {
            request.finish(with: error)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}

    private func captureLayoutAt(_ instruction: DualCameraVideoCompositionInstruction,
                                 time: TimeInterval) -> CaptureLayoutKeyframe {
        var result = CaptureLayoutKeyframe(time: 0,
                                           layout: instruction.layout,
                                           shape: instruction.shape,
                                           splitOrientation: instruction.splitOrientation,
                                           splitRatio: SplitRatio.defaultValue,
                                           isSecondaryCameraVisible: true)
        for keyframe in instruction.layoutKeyframes {
            guard keyframe.time <= time else { break }
            result = keyframe
        }
        return result
    }

    private func cameraSwapAt(_ instruction: DualCameraVideoCompositionInstruction,
                              time: TimeInterval) -> CameraSwapKeyframe {
        var result = CameraSwapKeyframe(time: 0, isSwapped: instruction.initialCamerasSwapped)
        for keyframe in instruction.cameraSwapKeyframes {
            guard keyframe.time <= time else { break }
            result = keyframe
        }
        return result
    }

    private func filterAt(_ instruction: DualCameraVideoCompositionInstruction,
                          time: TimeInterval) -> VideoFilterKeyframe {
        var result = VideoFilterKeyframe(time: 0,
                                         filter: instruction.videoFilter,
                                         target: instruction.filterTarget)
        for keyframe in instruction.filterKeyframes {
            guard keyframe.time <= time else { break }
            result = keyframe
        }
        return result
    }

    /// Прямоугольник окна PiP в долях кадра: сначала точный, иначе из смещения.
    private func pipRectAt(_ instruction: DualCameraVideoCompositionInstruction,
                           time: TimeInterval) -> CGRect? {
        let keyframes = instruction.pipPositionKeyframes
        if let keyframe = keyframes.last(where: { $0.time <= time }),
           let rect = keyframe.rectFraction {
            return rect
        }
        if let rect = keyframes.first?.rectFraction {
            return rect
        }
        return instruction.pipRectFraction
    }

    private func layoutAt(_ instruction: DualCameraVideoCompositionInstruction,
                          time: TimeInterval) -> (offset: CGSize, widthFraction: CGFloat) {
        let keyframes = instruction.pipPositionKeyframes
        guard let first = keyframes.first else {
            return (instruction.pipOffsetFraction, instruction.pipWidthFraction)
        }
        guard time > first.time else { return (first.offsetFraction, first.widthFraction) }
        for index in 1..<keyframes.count {
            let start = keyframes[index - 1]
            let end = keyframes[index]
            guard time <= end.time else { continue }
            let interval = max(0.0001, end.time - start.time)
            let progress = CGFloat(min(1, max(0, (time - start.time) / interval)))
            return (CGSize(width: start.offsetFraction.width
                            + (end.offsetFraction.width - start.offsetFraction.width) * progress,
                          height: start.offsetFraction.height
                            + (end.offsetFraction.height - start.offsetFraction.height) * progress),
                    start.widthFraction + (end.widthFraction - start.widthFraction) * progress)
        }
        guard let last = keyframes.last else { return (first.offsetFraction, first.widthFraction) }
        return (last.offsetFraction, last.widthFraction)
    }

    private func drawingOverlay(at time: TimeInterval,
                                keyframes: [DrawingElementsKeyframe],
                                canvasSize: CGSize) -> CIImage? {
        guard let index = keyframes.lastIndex(where: { $0.time <= time }),
              !keyframes[index].elements.isEmpty else { return nil }

        overlayCacheLock.lock()
        defer { overlayCacheLock.unlock() }
        if let cached = overlayCache[index] { return cached }

        let image = DrawingRenderer.render(keyframes[index].elements, size: canvasSize)
        guard let cgImage = image.cgImage else { return nil }
        let result = CIImage(cgImage: cgImage)
        overlayCache[index] = result
        overlayCacheOrder.append(index)
        while overlayCacheOrder.count > 3 {
            overlayCache.removeValue(forKey: overlayCacheOrder.removeFirst())
        }
        return result
    }

    private func timestampOverlay(at date: Date, canvasSize: CGSize) -> CIImage? {
        let second = Int(date.timeIntervalSince1970)
        overlayCacheLock.lock()
        if cachedTimestampSecond == second {
            let cached = cachedTimestamp
            overlayCacheLock.unlock()
            return cached
        }
        overlayCacheLock.unlock()

        let image = DrawingRenderer.renderTimestamp(date, size: canvasSize)
        guard let cgImage = image.cgImage else { return nil }
        let rendered = CIImage(cgImage: cgImage)
        overlayCacheLock.lock()
        cachedTimestampSecond = second
        cachedTimestamp = rendered
        overlayCacheLock.unlock()
        return rendered
    }

    private func place(_ source: CIImage,
                       sourceSize: CGSize,
                       transform: CGAffineTransform,
                       in target: CGRect,
                       canvasHeight: CGFloat) -> CIImage {
        let orientedBounds = CGRect(origin: .zero, size: sourceSize)
            .applying(transform)
            .standardized
        let normalized = source.transformed(by: transform)
            .transformed(by: CGAffineTransform(translationX: -orientedBounds.minX,
                                                y: -orientedBounds.minY))
        let targetAspect = target.width / target.height
        let sourceAspect = orientedBounds.width / orientedBounds.height
        let crop: CGRect
        if sourceAspect > targetAspect {
            let width = orientedBounds.height * targetAspect
            crop = CGRect(x: (orientedBounds.width - width) / 2,
                          y: 0, width: width, height: orientedBounds.height)
        } else {
            let height = orientedBounds.width / targetAspect
            crop = CGRect(x: 0, y: (orientedBounds.height - height) / 2,
                          width: orientedBounds.width, height: height)
        }
        let bottomTarget = CGRect(x: target.minX,
                                  y: canvasHeight - target.maxY,
                                  width: target.width,
                                  height: target.height)
        let scale = target.width / crop.width
        return normalized.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: bottomTarget.minX,
                                               y: bottomTarget.minY))
    }

    private func frontRectForCoreImage(_ rect: CGRect, canvasHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX,
               y: canvasHeight - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    /// Corrects a landscape camera frame in place without moving its layout rectangle.
    private func rotateHalfTurn(_ image: CIImage, inside rect: CGRect) -> CIImage {
        let transform = CGAffineTransform(a: -1, b: 0,
                                          c: 0, d: -1,
                                          tx: rect.minX + rect.maxX,
                                          ty: rect.minY + rect.maxY)
        return image.transformed(by: transform).cropped(to: rect)
    }

    /// Mirrors the front camera left-to-right without changing its orientation or cell.
    private func mirrorForFinalVideo(_ image: CIImage, inside rect: CGRect) -> CIImage {
        let transform = CGAffineTransform(a: -1, b: 0,
                                          c: 0, d: 1,
                                          tx: rect.minX + rect.maxX, ty: 0)
        return image.transformed(by: transform).cropped(to: rect)
    }
}

private extension CGRect {
    func verticallyMirrored(in canvasHeight: CGFloat) -> CGRect {
        CGRect(x: minX,
               y: canvasHeight - maxY,
               width: width,
               height: height)
    }

    func horizontallyMirrored(in canvasWidth: CGFloat) -> CGRect {
        CGRect(x: canvasWidth - maxX,
               y: minY,
               width: width,
               height: height)
    }
}
