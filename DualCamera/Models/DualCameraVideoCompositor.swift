import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

struct PipPositionKeyframe {
    let time: TimeInterval
    let offsetFraction: CGSize
    let widthFraction: CGFloat
}

struct DrawingElementsKeyframe {
    let time: TimeInterval
    let elements: [DrawingElement]
}

struct PhotoOverlayKeyframe {
    let time: TimeInterval
    let offsetFraction: CGSize
    let widthFraction: CGFloat
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
    let pipOffsetFraction: CGSize
    let pipWidthFraction: CGFloat
    let pipPositionKeyframes: [PipPositionKeyframe]
    let drawingKeyframes: [DrawingElementsKeyframe]
    let photoOverlayKeyframes: [PhotoOverlayKeyframe]
    let backTransform: CGAffineTransform
    let frontTransform: CGAffineTransform
    let backSourceSize: CGSize
    let frontSourceSize: CGSize
    let backImage: CIImage?
    let frontImage: CIImage?
    let photoOverlay: UIImage?

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
         pipOffsetFraction: CGSize,
         pipWidthFraction: CGFloat,
         pipPositionKeyframes: [PipPositionKeyframe],
         drawingKeyframes: [DrawingElementsKeyframe],
         photoOverlayKeyframes: [PhotoOverlayKeyframe],
         backTransform: CGAffineTransform,
         frontTransform: CGAffineTransform,
         backSourceSize: CGSize,
         frontSourceSize: CGSize,
         backImage: CIImage?,
         frontImage: CIImage?,
         photoOverlay: UIImage?) {
        self.timeRange = timeRange
        self.backTrackID = backTrackID
        self.frontTrackID = frontTrackID
        self.canvasSize = canvasSize
        self.layout = layout
        self.splitOrientation = splitOrientation
        self.shape = shape
        self.pipOffsetFraction = pipOffsetFraction
        self.pipWidthFraction = pipWidthFraction
        self.pipPositionKeyframes = pipPositionKeyframes
        self.drawingKeyframes = drawingKeyframes
        self.photoOverlayKeyframes = photoOverlayKeyframes
        self.backTransform = backTransform
        self.frontTransform = frontTransform
        self.backSourceSize = backSourceSize
        self.frontSourceSize = frontSourceSize
        self.backImage = backImage
        self.frontImage = frontImage
        self.photoOverlay = photoOverlay
    }
}

final class DualCameraVideoCompositor: NSObject, AVVideoCompositing {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let overlayCacheLock = NSLock()
    private var overlayCache: [Int: CIImage] = [:]
    private var overlayCacheOrder: [Int] = []
    private var photoOverlayCache: [Int: CIImage] = [:]
    private var photoOverlayCacheOrder: [Int] = []

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
            switch instruction.layout {
            case .pip:
                let layout = layoutAt(instruction, time: request.compositionTime.seconds)
                let width = instruction.canvasSize.width * layout.widthFraction
                let height = width * instruction.shape.aspectRatio
                let x = min(max(0, instruction.canvasSize.width - width - 16
                                + layout.offset.width * instruction.canvasSize.width),
                            instruction.canvasSize.width - width)
                let y = min(max(0, instruction.canvasSize.height - height - 16
                                + layout.offset.height * instruction.canvasSize.height),
                            instruction.canvasSize.height - height)
                frontRect = CGRect(x: x,
                                   y: y,
                                   width: width, height: height)
                    .verticallyMirrored(in: instruction.canvasSize.height)
                    .horizontallyMirrored(in: instruction.canvasSize.width)
                backRect = canvas
            case .splitScreen:
                if instruction.splitOrientation == .horizontal {
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

            let back = place(backSource,
                             sourceSize: instruction.backImage == nil ? instruction.backSourceSize : backSource.extent.size,
                             transform: instruction.backImage == nil ? instruction.backTransform : .identity,
                             in: backRect,
                             canvasHeight: instruction.canvasSize.height)
            let front = place(frontSource,
                              sourceSize: instruction.frontImage == nil ? instruction.frontSourceSize : frontSource.extent.size,
                              transform: instruction.frontImage == nil ? instruction.frontTransform : .identity,
                              in: frontRect,
                              canvasHeight: instruction.canvasSize.height)

            var composed = back.cropped(to: canvas)
            if instruction.layout == .pip, instruction.shape == .circle {
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

            if let photoImage = photoOverlay(at: request.compositionTime.seconds,
                                             instruction: instruction) {
                let correctedPhoto = photoImage.transformed(by: CGAffineTransform(
                    a: -1, b: 0, c: 0, d: -1,
                    tx: instruction.canvasSize.width,
                    ty: instruction.canvasSize.height
                ))
                let photoLayer = place(correctedPhoto,
                                       sourceSize: instruction.canvasSize,
                                       transform: .identity,
                                       in: canvas,
                                       canvasHeight: instruction.canvasSize.height)
                composed = photoLayer.composited(over: composed)
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

    private func photoOverlay(at time: TimeInterval,
                              instruction: DualCameraVideoCompositionInstruction) -> CIImage? {
        guard let photo = instruction.photoOverlay,
              let index = instruction.photoOverlayKeyframes.lastIndex(where: { $0.time <= time }) else {
            return nil
        }

        photoOverlayCacheLock.lock()
        defer { photoOverlayCacheLock.unlock() }
        if let cached = photoOverlayCache[index] { return cached }

        let keyframes = instruction.photoOverlayKeyframes
        let keyframe = keyframes[index]
        let canvasSize = instruction.canvasSize
        let width = canvasSize.width * keyframe.widthFraction
        let height = width * photo.size.height / max(photo.size.width, 1)
        let x = min(max(0, 16 + keyframe.offsetFraction.width * canvasSize.width),
                    canvasSize.width - width)
        let y = min(max(0, 16 + keyframe.offsetFraction.height * canvasSize.height),
                    canvasSize.height - height)
        let target = CGRect(x: x, y: y, width: width, height: height)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        let renderedPhoto = renderer.image { context in
            context.cgContext.saveGState()
            UIBezierPath(roundedRect: target, cornerRadius: 10).addClip()
            photo.draw(in: photoAspectFillRect(photo, in: target))
            context.cgContext.restoreGState()
        }
        guard let cgImage = renderedPhoto.cgImage else { return nil }
        let result = CIImage(cgImage: cgImage)
        photoOverlayCache[index] = result
        photoOverlayCacheOrder.append(index)
        while photoOverlayCacheOrder.count > 3 {
            photoOverlayCache.removeValue(forKey: photoOverlayCacheOrder.removeFirst())
        }
        return result
    }

    private func photoAspectFillRect(_ image: UIImage, in rect: CGRect) -> CGRect {
        let imageAspect = image.size.width / image.size.height
        let targetAspect = rect.width / rect.height
        if imageAspect > targetAspect {
            let width = rect.height * imageAspect
            return CGRect(x: rect.midX - width / 2,
                          y: rect.minY,
                          width: width,
                          height: rect.height)
        }
        let height = rect.width / imageAspect
        return CGRect(x: rect.minX,
                      y: rect.midY - height / 2,
                      width: rect.width,
                      height: height)
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
