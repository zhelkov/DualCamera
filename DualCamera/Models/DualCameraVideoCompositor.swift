import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

struct PipPositionKeyframe {
    let time: TimeInterval
    let positionFraction: CGSize
    let widthFraction: CGFloat
}

struct CaptureLayoutKeyframe {
    let time: TimeInterval
    let layout: CaptureLayout
    let shape: PipShape
    let splitOrientation: SplitOrientation
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
    let pipPositionFraction: CGSize
    let pipWidthFraction: CGFloat
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
    let initialCamerasSwapped: Bool

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
         pipPositionFraction: CGSize,
         pipWidthFraction: CGFloat,
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
         initialCamerasSwapped: Bool) {
        self.timeRange = timeRange
        self.backTrackID = backTrackID
        self.frontTrackID = frontTrackID
        self.canvasSize = canvasSize
        self.layout = layout
        self.splitOrientation = splitOrientation
        self.shape = shape
        self.pipPositionFraction = pipPositionFraction
        self.pipWidthFraction = pipWidthFraction
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
        self.initialCamerasSwapped = initialCamerasSwapped
    }
}

final class DualCameraVideoCompositor: NSObject, AVVideoCompositing {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let overlayCacheLock = NSLock()
    private var overlayCache: [Int: CIImage] = [:]
    private var overlayCacheOrder: [Int] = []

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
                let width = min(instruction.canvasSize.width, instruction.canvasSize.height)
                    * layout.widthFraction
                let height = width * captureLayout.shape.aspectRatio
                let availableX = max(0, instruction.canvasSize.width - width - 32)
                let availableY = max(0, instruction.canvasSize.height - height - 32)
                let x = 16 + min(max(layout.position.width, 0), 1) * availableX
                let y = 16 + min(max(layout.position.height, 0), 1) * availableY
                frontRect = CGRect(x: x,
                                   y: y,
                                   width: width, height: height)
                    .verticallyMirrored(in: instruction.canvasSize.height)
                    .horizontallyMirrored(in: instruction.canvasSize.width)
                backRect = canvas
            case .splitScreen:
                if captureLayout.splitOrientation == .horizontal {
                    backRect = CGRect(x: 0, y: 0,
                                      width: instruction.canvasSize.width / 2,
                                      height: instruction.canvasSize.height)
                    frontRect = CGRect(x: instruction.canvasSize.width / 2, y: 0,
                                       width: instruction.canvasSize.width / 2,
                                       height: instruction.canvasSize.height)
                } else {
                    backRect = CGRect(x: 0, y: 0,
                                      width: instruction.canvasSize.width,
                                      height: instruction.canvasSize.height / 2)
                    frontRect = CGRect(x: 0, y: instruction.canvasSize.height / 2,
                                       width: instruction.canvasSize.width,
                                       height: instruction.canvasSize.height / 2)
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
            let mainSize = swapSources ? instruction.frontSourceSize : instruction.backSourceSize
            let secondarySize = swapSources ? instruction.backSourceSize : instruction.frontSourceSize
            // Both camera outputs capture the same interface orientation. Use
            // the primary track's orientation matrix for both source frames so
            // the front sensor's native sensor rotation doesn't turn its PiP.
            let mainTransform = instruction.backTransform
            let secondaryTransform = instruction.backTransform
            let main = place(mainSource,
                             sourceSize: instruction.backImage == nil ? mainSize : mainSource.extent.size,
                             transform: instruction.backImage == nil ? mainTransform : .identity,
                             in: backRect,
                             canvasHeight: instruction.canvasSize.height)
            let front = place(secondarySource,
                              sourceSize: instruction.frontImage == nil ? secondarySize : secondarySource.extent.size,
                              transform: instruction.frontImage == nil ? secondaryTransform : .identity,
                              in: frontRect,
                              canvasHeight: instruction.canvasSize.height)

            var composed = main.cropped(to: canvas)
            if captureLayout.layout == .pip, captureLayout.shape == .circle {
                let frontBottomRect = CGRect(x: frontRect.minX,
                                             y: instruction.canvasSize.height - frontRect.maxY,
                                             width: frontRect.width,
                                             height: frontRect.height)
                let center = CGPoint(x: frontBottomRect.midX, y: frontBottomRect.midY)
                let radius = min(frontBottomRect.width, frontBottomRect.height) / 2
                let mask = CIFilter.radialGradient()
                mask.center = center
                mask.radius0 = Float(max(0, radius - 0.5))
                mask.radius1 = Float(radius + 0.5)
                mask.color0 = CIColor.white
                mask.color1 = CIColor.black
                guard let maskImage = mask.outputImage?.cropped(to: canvas) else {
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
                composed = front.cropped(to: frontRectForCoreImage(frontRect,
                                                                   canvasHeight: instruction.canvasSize.height))
                    .composited(over: composed)
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
                                           splitOrientation: instruction.splitOrientation)
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

    private func layoutAt(_ instruction: DualCameraVideoCompositionInstruction,
                          time: TimeInterval) -> (position: CGSize, widthFraction: CGFloat) {
        let keyframes = instruction.pipPositionKeyframes
        guard let first = keyframes.first else {
            return (instruction.pipPositionFraction, instruction.pipWidthFraction)
        }
        guard time > first.time else { return (first.positionFraction, first.widthFraction) }
        for index in 1..<keyframes.count {
            let start = keyframes[index - 1]
            let end = keyframes[index]
            guard time <= end.time else { continue }
            let interval = max(0.0001, end.time - start.time)
            let progress = CGFloat(min(1, max(0, (time - start.time) / interval)))
            return (CGSize(width: start.positionFraction.width
                            + (end.positionFraction.width - start.positionFraction.width) * progress,
                          height: start.positionFraction.height
                            + (end.positionFraction.height - start.positionFraction.height) * progress),
                    start.widthFraction + (end.widthFraction - start.widthFraction) * progress)
        }
        guard let last = keyframes.last else { return (first.positionFraction, first.widthFraction) }
        return (last.positionFraction, last.widthFraction)
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
