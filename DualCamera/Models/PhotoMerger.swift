import UIKit

/// Склеивает снимки передней и задней камер в одно изображение.
enum PhotoMerger {

    static func merge(back: UIImage,
                      front: UIImage,
                      layout: CaptureLayout,
                      shape: PipShape,
                      splitOrientation: SplitOrientation = .vertical,
                      pipOffsetFraction: CGSize = .zero,
                      pipWidthFraction: CGFloat = 0.3,
                      photoOverlay: UIImage? = nil,
                      photoOverlayOffsetFraction: CGSize = .zero,
                      photoOverlayWidthFraction: CGFloat = 0.3,
                      elements: [DrawingElement] = []) -> UIImage {
        // Приводим к вертикальной ориентации, чтобы размеры были честными.
        let back = normalized(back)
        let front = normalized(front)

        let merged: UIImage
        switch layout {
        case .splitScreen:
            merged = splitOrientation == .horizontal
                ? horizontalSplit(back: back, front: front)
                : verticalSplit(back: back, front: front)
        case .pip:
            merged = pictureInPicture(back: back, front: front, shape: shape,
                                      pipOffsetFraction: pipOffsetFraction,
                                      pipWidthFraction: pipWidthFraction)
        }

        let withPhoto = photoOverlay.map {
            overlayPhoto($0, on: merged,
                         offsetFraction: photoOverlayOffsetFraction,
                         widthFraction: photoOverlayWidthFraction)
        } ?? merged
        return elements.isEmpty ? withPhoto : overlay(DrawingRenderer.render(elements, size: merged.size), on: withPhoto)
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
                                     widthFraction: CGFloat) -> UIImage {
        let size = image.size
        let width = size.width * widthFraction
        let height = width * photo.size.height / max(photo.size.width, 1)
        let x = min(max(0, 16 + offsetFraction.width * size.width), size.width - width)
        let y = min(max(0, 16 + offsetFraction.height * size.height), size.height - height)
        let target = CGRect(x: x, y: y, width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            image.draw(in: CGRect(origin: .zero, size: size))
            context.cgContext.saveGState()
            UIBezierPath(roundedRect: target, cornerRadius: 10).addClip()
            photo.draw(in: aspectFillRect(image: photo, in: target))
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
    private static func verticalSplit(back: UIImage, front: UIImage) -> UIImage {
        let width = max(back.size.width, front.size.width)
        let backHeight = back.size.height * (width / back.size.width)
        let frontHeight = front.size.height * (width / front.size.width)
        let size = CGSize(width: width, height: backHeight + frontHeight)

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            back.draw(in: CGRect(x: 0, y: 0, width: width, height: backHeight))
            front.draw(in: CGRect(x: 0, y: backHeight, width: width, height: frontHeight))
        }
    }

    /// Ландшафтный сплит: задняя камера слева, передняя — справа.
    private static func horizontalSplit(back: UIImage, front: UIImage) -> UIImage {
        let height = max(back.size.height, front.size.height)
        let backWidth = back.size.width * (height / back.size.height)
        let frontWidth = front.size.width * (height / front.size.height)
        let size = CGSize(width: backWidth + frontWidth, height: height)

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            back.draw(in: CGRect(x: 0, y: 0, width: backWidth, height: height))
            front.draw(in: CGRect(x: backWidth, y: 0, width: frontWidth, height: height))
        }
    }

    /// Картинка в картинке: задняя камера на весь кадр, передняя — в окне заданной формы.
    private static func pictureInPicture(back: UIImage,
                                         front: UIImage,
                                         shape: PipShape,
                                         pipOffsetFraction: CGSize,
                                         pipWidthFraction: CGFloat) -> UIImage {
        let size = back.size
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            back.draw(in: CGRect(origin: .zero, size: size))

            // Передняя камера занимает ~25% ширины кадра.
            let pipWidth = size.width * pipWidthFraction
            let pipHeight = pipWidth * shape.aspectRatio
            let inset: CGFloat = 16
            let x = min(max(0, size.width - pipWidth - inset + pipOffsetFraction.width * size.width),
                        size.width - pipWidth)
            let y = min(max(0, size.height - pipHeight - inset + pipOffsetFraction.height * size.height),
                        size.height - pipHeight)
            let pipRect = CGRect(x: x,
                                 y: y,
                                 width: pipWidth,
                                 height: pipHeight)

            // Обрезаем по форме окна и вписываем картинку с заполнением (aspect-fill).
            ctx.cgContext.saveGState()
            clipPath(for: shape, in: pipRect).addClip()
            front.draw(in: aspectFillRect(image: front, in: pipRect))
            ctx.cgContext.restoreGState()
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
