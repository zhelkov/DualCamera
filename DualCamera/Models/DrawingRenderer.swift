import UIKit

/// Рисует элементы рисунка на прозрачном изображении (для вшивания в фото и видео).
enum DrawingRenderer {
    static func renderTimestamp(_ date: Date, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        let text = formatter.string(from: date)
        let fontSize = max(18, size.width * 0.028)
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
            .strokeColor: UIColor.black,
            .strokeWidth: -1.5
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let horizontalPadding = fontSize * 0.55
        let verticalPadding = fontSize * 0.32
        let margin = max(20, size.width * 0.035)
        let textRect = CGRect(x: size.width - margin - textSize.width,
                              y: size.height - margin - textSize.height,
                              width: textSize.width,
                              height: textSize.height)
        let backgroundRect = textRect.insetBy(dx: -horizontalPadding, dy: -verticalPadding)

        return renderer.image { context in
            UIColor.black.withAlphaComponent(0.48).setFill()
            UIBezierPath(roundedRect: backgroundRect, cornerRadius: verticalPadding).fill()
            (text as NSString).draw(in: textRect, withAttributes: attributes)
        }
    }

    static func render(_ elements: [DrawingElement], size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            for element in elements {
                draw(element, in: cg, size: size)
            }
        }
    }

    private static func draw(_ element: DrawingElement, in cg: CGContext, size: CGSize) {
        let lineWidth = element.lineWidth * size.width
        cg.setStrokeColor(element.color.uiColor.cgColor)
        cg.setLineWidth(lineWidth)

        switch element.kind {
        case .stroke(let points):
            guard points.count > 1 else { return }
            cg.move(to: denorm(points[0], size))
            for point in points.dropFirst() {
                cg.addLine(to: denorm(point, size))
            }
            cg.strokePath()

        case .rectangle(let rect):
            cg.stroke(denorm(rect, size))

        case .arrow(let from, let to):
            let start = denorm(from, size)
            let end = denorm(to, size)
            cg.move(to: start)
            cg.addLine(to: end)
            let headLength = max(lineWidth * 4, 8)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let wing: CGFloat = .pi / 6
            for sign: CGFloat in [-1, 1] {
                let a = angle + sign * wing
                cg.move(to: CGPoint(x: end.x - cos(a) * headLength, y: end.y - sin(a) * headLength))
                cg.addLine(to: end)
            }
            cg.strokePath()
        }
    }

    private static func denorm(_ point: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    private static func denorm(_ rect: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
               width: rect.width * size.width, height: rect.height * size.height)
    }
}
