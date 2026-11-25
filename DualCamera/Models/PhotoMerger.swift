import UIKit
import CoreImage

/// Склеивает снимки передней и задней камер в одно изображение.
enum PhotoMerger {
    private static let filterContext = CIContext(options: [.cacheIntermediates: false])

    /// Mirrors a captured front-camera image while preserving its displayed orientation.
    static func mirrorHorizontally(_ image: UIImage) -> UIImage {
        let image = normalized(image)
        let size = image.size
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            context.cgContext.translateBy(x: size.width, y: 0)
            context.cgContext.scaleBy(x: -1, y: 1)
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    static func merge(back: UIImage,
                      front: UIImage,
                      layout: CaptureLayout,
                      shape: PipShape,
                      splitOrientation: SplitOrientation = .vertical,
                      splitRatio: CGFloat = SplitRatio.defaultValue,
                      isSecondaryCameraVisible: Bool = true,
                      videoFilter: VideoFilter = .original,
                      filterTarget: VideoFilterTarget = .primary,
                      outputAspectRatio: CGFloat? = nil,
                      pipOffsetFraction: CGSize = .zero,
                      pipWidthFraction: CGFloat = 0.3,
                      photoOverlay: UIImage? = nil,
                      photoOverlayOffsetFraction: CGSize = .zero,
                      photoOverlayWidthFraction: CGFloat = 0.3,
                      photoOverlayInnerScale: CGFloat = 1,
                      photoOverlayInnerOffsetFraction: CGSize = .zero,
                      photoOverlayOpacity: CGFloat = 1,
                      frontExposureEV: Float = 0,
                      elements: [DrawingElement] = [],
                      timestamp: Date? = nil) throws -> UIImage {
        // Приводим к вертикальной ориентации, чтобы размеры были честными.
        var back = normalized(back)
        var front = normalized(front)

        // Ночной подъём экспозиции фронтальной камеры — тот же, что в превью.
        if frontExposureEV > 0 {
            front = try applyExposure(frontExposureEV, to: front)
        }

        // Если целевой кадр горизонтальный, а основной снимок вертикальный,
        // разворачиваем его: иначе в готовом файле картинка окажется боком.
        let targetRatio = outputAspectRatio ?? (back.size.width / max(back.size.height, 1))
        if targetRatio > 1, back.size.height > back.size.width {
            back = rotatedQuarterTurn(back)
        }

        if videoFilter != .original {
            switch filterTarget {
            case .primary:
                back = try apply(videoFilter, to: back)
            case .secondary:
                front = try apply(videoFilter, to: front)
            }
        }

        let merged: UIImage
        if !isSecondaryCameraVisible {
            merged = back
        } else {
            switch layout {
            case .splitScreen:
                merged = splitOrientation == .horizontal
                    ? horizontalSplit(back: back, front: front, mainRatio: splitRatio)
                    : verticalSplit(back: back, front: front, mainRatio: splitRatio)
            case .pip:
                merged = pictureInPicture(back: back, front: front, shape: shape,
                                          pipOffsetFraction: pipOffsetFraction,
                                          pipWidthFraction: pipWidthFraction)
            }
        }

        let aspectCorrected = outputAspectRatio.map { crop(merged, toAspectRatio: $0) } ?? merged

        let withPhoto = photoOverlay.map {
            overlayPhoto($0, on: aspectCorrected,
                         offsetFraction: photoOverlayOffsetFraction,
                         widthFraction: photoOverlayWidthFraction,
                         innerScale: photoOverlayInnerScale,
                         innerOffsetFraction: photoOverlayInnerOffsetFraction,
                         opacity: photoOverlayOpacity)
        } ?? aspectCorrected
        var result = elements.isEmpty
            ? withPhoto
            : overlay(DrawingRenderer.render(elements, size: aspectCorrected.size), on: withPhoto)
        if let timestamp {
            result = overlay(DrawingRenderer.renderTimestamp(timestamp, size: result.size), on: result)
        }
        return result
    }

    private static func applyExposure(_ ev: Float, to image: UIImage) throws -> UIImage {
        guard let source = CIImage(image: image) else { throw CameraError.captureFailed }
        let adjusted = source
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
            .applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.02,
                                                             "inputSharpness": 0.4])
        let extent = adjusted.extent.integral
        guard let cgImage = filterContext.createCGImage(adjusted, from: extent) else {
            throw CameraError.filterProcessingFailed
        }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: .up)
    }

    private static func apply(_ filter: VideoFilter, to image: UIImage) throws -> UIImage {
        guard let source = CIImage(image: image) else { throw CameraError.captureFailed }
        let extent = source.extent.integral
        guard let cgImage = filterContext.createCGImage(try filter.applying(to: source), from: extent) else {
            throw CameraError.filterProcessingFailed
        }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: .up)
    }

    private static func crop(_ image: UIImage, toAspectRatio aspectRatio: CGFloat) -> UIImage {
        let sourceSize = image.size
        let sourceRatio = sourceSize.width / max(sourceSize.height, 1)
        let cropSize: CGSize
        if sourceRatio > aspectRatio {
            cropSize = CGSize(width: sourceSize.height * aspectRatio, height: sourceSize.height)
        } else {
            cropSize = CGSize(width: sourceSize.width, height: sourceSize.width / aspectRatio)
        }
        let cropRect = CGRect(x: (sourceSize.width - cropSize.width) / 2,
                              y: (sourceSize.height - cropSize.height) / 2,
                              width: cropSize.width,
                              height: cropSize.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: cropSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(x: -cropRect.minX, y: -cropRect.minY,
                                  width: sourceSize.width, height: sourceSize.height))
        }
    }

    /// Накладывает прозрачное изображение рисунка поверх снимка.
    private static func overlay(_ overlay: UIImage, on image: UIImage) -> UIImage {
        let size = image.size
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
            overlay.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func overlayPhoto(_ photo: UIImage,
                                     on image: UIImage,
                                     offsetFraction: CGSize,
                                     widthFraction: CGFloat,
                                     innerScale: CGFloat,
                                     innerOffsetFraction: CGSize,
                                     opacity: CGFloat) -> UIImage {
        let size = image.size
        let width = size.width * min(max(widthFraction, 0.05), 1)
        let height = width * photo.size.height / max(photo.size.width, 1)
        let x = min(max(0, offsetFraction.width * size.width), max(0, size.width - width))
        let y = min(max(0, offsetFraction.height * size.height), max(0, size.height - height))
        let target = CGRect(x: x, y: y, width: width, height: height)
        // Картинка внутри полотна: увеличение и смещение, границы полотна неизменны.
        let zoom = max(innerScale, 1)
        let innerWidth = target.width * zoom
        let innerHeight = target.height * zoom
        let fillScale = max(innerWidth / max(photo.size.width, 1),
                            innerHeight / max(photo.size.height, 1))
        let drawSize = CGSize(width: photo.size.width * fillScale,
                              height: photo.size.height * fillScale)
        // Не позволяем краю картинки зайти внутрь полотна.
        let maxShiftX = max(0, (drawSize.width - target.width) / 2)
        let maxShiftY = max(0, (drawSize.height - target.height) / 2)
        let shiftX = min(max(innerOffsetFraction.width * size.width, -maxShiftX), maxShiftX)
        let shiftY = min(max(innerOffsetFraction.height * size.height, -maxShiftY), maxShiftY)
        let inner = CGRect(x: target.midX + shiftX - drawSize.width / 2,
                           y: target.midY + shiftY - drawSize.height / 2,
                           width: drawSize.width,
                           height: drawSize.height)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            image.draw(in: CGRect(origin: .zero, size: size))
            context.cgContext.saveGState()
            UIBezierPath(roundedRect: target, cornerRadius: 10).addClip()
            context.cgContext.setAlpha(min(max(opacity, 0), 1))
            photo.draw(in: inner)
            context.cgContext.restoreGState()
        }
    }

    /// Перерисовывает изображение в ориентацию .up.
    /// После этого `size` совпадает с видимыми размерами кадра.
    private static func normalized(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }

        var width = image.cgImage?.width ?? Int(image.size.width * image.scale)
        var height = image.cgImage?.height ?? Int(image.size.height * image.scale)
        switch image.imageOrientation {
        case .left, .right, .leftMirrored, .rightMirrored:
            swap(&width, &height)
        default:
            break
        }

        let scale = image.scale
        let size = CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Сплит: задняя камера сверху, передняя — снизу.
    private static func verticalSplit(back: UIImage, front: UIImage, mainRatio: CGFloat) -> UIImage {
        let width = max(back.size.width, front.size.width)
        let backHeight = back.size.height * (width / back.size.width)
        let frontHeight = front.size.height * (width / front.size.width)
        let size = CGSize(width: width, height: backHeight + frontHeight)
        let primaryHeight = size.height * boundedRatio(mainRatio)
        let secondaryHeight = size.height - primaryHeight
        let primaryRect = CGRect(x: 0, y: 0, width: width, height: primaryHeight)
        let secondaryRect = CGRect(x: 0, y: primaryHeight, width: width, height: secondaryHeight)

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            back.draw(in: aspectFillRect(image: back, in: primaryRect))
            front.draw(in: aspectFillRect(image: front, in: secondaryRect))
        }
    }

    /// Ландшафтный сплит: задняя камера слева, передняя — справа.
    private static func horizontalSplit(back: UIImage, front: UIImage, mainRatio: CGFloat) -> UIImage {
        let height = max(back.size.height, front.size.height)
        let backWidth = back.size.width * (height / back.size.height)
        let frontWidth = front.size.width * (height / front.size.height)
        let size = CGSize(width: backWidth + frontWidth, height: height)
        let primaryWidth = size.width * boundedRatio(mainRatio)
        let secondaryWidth = size.width - primaryWidth
        let primaryRect = CGRect(x: 0, y: 0, width: primaryWidth, height: height)
        let secondaryRect = CGRect(x: primaryWidth, y: 0, width: secondaryWidth, height: height)

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            back.draw(in: aspectFillRect(image: back, in: primaryRect))
            front.draw(in: aspectFillRect(image: front, in: secondaryRect))
        }
    }

    private static func boundedRatio(_ value: CGFloat) -> CGFloat {
        min(max(value, SplitRatio.minimum), SplitRatio.maximum)
    }

    /// Картинка в картинке: задняя камера на весь кадр, передняя — в окне заданной формы.
    /// `pipOffsetFraction` — доля кадра для левого верхнего угла окна,
    /// поэтому положение совпадает с превью.
    private static func pictureInPicture(back: UIImage,
                                         front: UIImage,
                                         shape: PipShape,
                                         pipOffsetFraction: CGSize,
                                         pipWidthFraction: CGFloat) -> UIImage {
        let size = back.size
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            back.draw(in: CGRect(origin: .zero, size: size))

            // Окно строится одинаково в портрете и ландшафте: короткая сторона
            // кадра задаёт ширину, форма — высоту.
            let shortSide = min(size.width, size.height)
            let pipWidth = shortSide * pipWidthFraction
            let pipHeight = pipWidth * shape.aspectRatio
            let margin: CGFloat = 2
            let x = min(max(margin, pipOffsetFraction.width * size.width),
                        max(margin, size.width - pipWidth - margin))
            let y = min(max(margin, pipOffsetFraction.height * size.height),
                        max(margin, size.height - pipHeight - margin))
            let pipRect = CGRect(x: x, y: y, width: pipWidth, height: pipHeight)

            // Обрезаем по форме окна и вписываем картинку с заполнением (aspect-fill).
            ctx.cgContext.saveGState()
            clipPath(for: shape, in: pipRect).addClip()
            front.draw(in: aspectFillRect(image: front, in: pipRect))
            ctx.cgContext.restoreGState()
        }
    }

    /// Поворот картинки на 90° по часовой стрелке.
    private static func rotatedQuarterTurn(_ image: UIImage) -> UIImage {
        let target = CGSize(width: image.size.height, height: image.size.width)
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { context in
            let cg = context.cgContext
            cg.translateBy(x: target.width / 2, y: target.height / 2)
            cg.rotate(by: .pi / 2)
            image.draw(in: CGRect(x: -image.size.width / 2,
                                  y: -image.size.height / 2,
                                  width: image.size.width,
                                  height: image.size.height))
        }
    }

    /// Контур окна PiP нужной формы.
    private static func clipPath(for shape: PipShape, in rect: CGRect) -> UIBezierPath {
        switch shape {
        case .rectangle: return UIBezierPath(roundedRect: rect, cornerRadius: 16)
        case .square: return UIBezierPath(roundedRect: rect, cornerRadius: 12)
        case .circle: return UIBezierPath(ovalIn: rect)
        }
    }

    /// Прямоугольник, в который картинка вписывается с заполнением (без пустых полей).
    private static func aspectFillRect(image: UIImage, in rect: CGRect) -> CGRect {
        let imageAspect = image.size.width / image.size.height
        let rectAspect = rect.width / rect.height
        var drawRect = rect
        if imageAspect > rectAspect {
            drawRect.size.height = rect.height
            drawRect.size.width = rect.height * imageAspect
            drawRect.origin.x = rect.midX - drawRect.width / 2
        } else {
            drawRect.size.width = rect.width
            drawRect.size.height = rect.width / imageAspect
            drawRect.origin.y = rect.midY - drawRect.height / 2
        }
        return drawRect
    }
}
