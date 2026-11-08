import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

struct PipPositionKeyframe {
    let time: TimeInterval
    let offsetFraction: CGSize
}

final class DualCameraVideoCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let enablePostProcessing = false
    let containsTweening = false
    let requiredSourceSampleDataTrackIDs: [NSNumber] = []

    let backTrackID: CMPersistentTrackID
    let frontTrackID: CMPersistentTrackID
    let canvasSize: CGSize
    let layout: CaptureLayout
    let splitOrientation: SplitOrientation
    let shape: PipShape
    let pipOffsetFraction: CGSize
    let pipPositionKeyframes: [PipPositionKeyframe]
    let backTransform: CGAffineTransform
    let frontTransform: CGAffineTransform
    let backSourceSize: CGSize
    let frontSourceSize: CGSize
    let backImage: CIImage?
    let frontImage: CIImage?
    let overlayImage: CIImage?

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
         pipPositionKeyframes: [PipPositionKeyframe],
         backTransform: CGAffineTransform,
         frontTransform: CGAffineTransform,
         backSourceSize: CGSize,
         frontSourceSize: CGSize,
         backImage: CIImage?,
         frontImage: CIImage?,
         overlayImage: CIImage?) {
        self.timeRange = timeRange
        self.backTrackID = backTrackID
        self.frontTrackID = frontTrackID
        self.canvasSize = canvasSize
        self.layout = layout
        self.splitOrientation = splitOrientation
        self.shape = shape
        self.pipOffsetFraction = pipOffsetFraction
        self.pipPositionKeyframes = pipPositionKeyframes
        self.backTransform = backTransform
        self.frontTransform = frontTransform
        self.backSourceSize = backSourceSize
        self.frontSourceSize = frontSourceSize
        self.backImage = backImage
        self.frontImage = frontImage
        self.overlayImage = overlayImage
    }
}

final class DualCameraVideoCompositor: NSObject, AVVideoCompositing {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

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
            let backRect: CGRect
            let frontRect: CGRect
            switch instruction.layout {
            case .pip:
                let width = instruction.canvasSize.width * 0.3
                let height = width * instruction.shape.aspectRatio
                let offset = offsetFraction(instruction, at: request.compositionTime.seconds)
                let x = min(max(0, instruction.canvasSize.width - width - 16
                                + offset.width * instruction.canvasSize.width),
                            instruction.canvasSize.width - width)
                let y = min(max(0, instruction.canvasSize.height - height - 16
                                + offset.height * instruction.canvasSize.height),
                            instruction.canvasSize.height - height)
                frontRect = CGRect(x: x,
                                   y: y,
                                   width: width, height: height)
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

            if let overlayImage = instruction.overlayImage {
                let overlay = place(overlayImage,
                                    sourceSize: overlayImage.extent.size,
                                    transform: .identity,
                                    in: CGRect(origin: .zero, size: instruction.canvasSize),
                                    canvasHeight: instruction.canvasSize.height)
                composed = overlay.composited(over: composed)
            }

            let uprightFrame = composed.transformed(by: CGAffineTransform(a: 1, b: 0,
                                                                           c: 0, d: -1,
                                                                           tx: 0, ty: canvas.height))
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

    private func offsetFraction(_ instruction: DualCameraVideoCompositionInstruction,
                                at time: TimeInterval) -> CGSize {
        let keyframes = instruction.pipPositionKeyframes
        guard let first = keyframes.first else { return instruction.pipOffsetFraction }
        guard time > first.time else { return first.offsetFraction }
        for index in 1..<keyframes.count {
            let start = keyframes[index - 1]
            let end = keyframes[index]
            guard time <= end.time else { continue }
            let interval = max(0.0001, end.time - start.time)
            let progress = CGFloat(min(1, max(0, (time - start.time) / interval)))
            return CGSize(width: start.offsetFraction.width
                            + (end.offsetFraction.width - start.offsetFraction.width) * progress,
                          height: start.offsetFraction.height
                            + (end.offsetFraction.height - start.offsetFraction.height) * progress)
        }
        return keyframes.last?.offsetFraction ?? first.offsetFraction
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
