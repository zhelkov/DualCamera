import UIKit

/// Рисует элементы рисунка на прозрачном изображении (для вшивания в фото и видео).
enum DrawingRenderer {
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
