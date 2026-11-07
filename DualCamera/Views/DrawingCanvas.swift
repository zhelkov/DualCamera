import SwiftUI

/// Слой рисования поверх камеры: штрихи и фигуры в нормализованных координатах.
struct DrawingCanvas: View {
    let engine: DrawingEngine

    var body: some View {
        // Читаем элементы в body, чтобы SwiftUI отслеживал изменения.
        let elements = engine.elements
        let draft = engine.draftElement
        let selected = engine.selectedElement

        GeometryReader { geo in
            Canvas { context, size in
                for element in elements {
                    Self.draw(element, in: &context, size: size)
                }
                if let draft {
                    Self.draw(draft, in: &context, size: size)
                }
                if let selected {
                    Self.drawSelection(selected, in: &context, size: size)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let point = Self.normalized(value.location, in: geo.size)
                        if !engine.isDragging {
                            engine.begin(at: point, canvasSize: geo.size)
                        } else {
                            engine.update(at: point)
                        }
                    }
                    .onEnded { _ in
                        engine.end(canvasSize: geo.size)
                    }
            )
        }
    }

    private static func draw(_ element: DrawingElement, in context: inout GraphicsContext, size: CGSize) {
        let lineWidth = element.lineWidth * size.width
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        let shading = GraphicsContext.Shading.color(element.color.color)

        switch element.kind {
        case .stroke(let points):
            guard points.count > 1 else { return }
            var path = Path()
            path.move(to: denorm(points[0], size))
            for point in points.dropFirst() {
                path.addLine(to: denorm(point, size))
            }
            context.stroke(path, with: shading, style: style)

        case .rectangle(let rect):
            context.stroke(Path(denorm(rect, size)), with: shading, style: style)

        case .arrow(let from, let to):
            let start = denorm(from, size)
            let end = denorm(to, size)
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            let headLength = max(lineWidth * 4, 8)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let wing: CGFloat = .pi / 6
            for sign: CGFloat in [-1, 1] {
                let a = angle + sign * wing
                path.move(to: CGPoint(x: end.x - cos(a) * headLength, y: end.y - sin(a) * headLength))
                path.addLine(to: end)
            }
            context.stroke(path, with: shading, style: style)
        }
    }

    private static func drawSelection(_ element: DrawingElement, in context: inout GraphicsContext, size: CGSize) {
        let box = denorm(element.boundingBox, size).insetBy(dx: -6, dy: -6)
        context.stroke(Path(box), with: .color(.white),
                       style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        let handle = CGRect(x: box.maxX - 7, y: box.maxY - 7, width: 14, height: 14)
        context.fill(Path(ellipseIn: handle), with: .color(.white))
    }

    private static func denorm(_ point: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    private static func denorm(_ rect: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
               width: rect.width * size.width, height: rect.height * size.height)
    }

    private static func normalized(_ location: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGPoint(x: min(max(location.x / size.width, 0), 1),
                       y: min(max(location.y / size.height, 0), 1))
    }
}
