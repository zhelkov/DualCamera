import SwiftUI

struct PointingHandShape: Shape {
    func path(in rect: CGRect) -> Path {
        let bounds = CGRect(x: 73, y: 25, width: 142, height: 241)
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        let offsetX = rect.midX - bounds.width * scale / 2
        let offsetY = rect.midY - bounds.height * scale / 2
        let translate = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
        let resize = CGAffineTransform(scaleX: scale, y: scale)
        let place = CGAffineTransform(translationX: offsetX, y: offsetY)

        var path = Path()
        path.move(to: CGPoint(x: 103, y: 25))
        path.addCurve(to: CGPoint(x: 91, y: 43), control1: CGPoint(x: 94, y: 25), control2: CGPoint(x: 91, y: 32))
        path.addLine(to: CGPoint(x: 90, y: 130))
        path.addLine(to: CGPoint(x: 80, y: 132))
        path.addCurve(to: CGPoint(x: 73, y: 151), control1: CGPoint(x: 74, y: 135), control2: CGPoint(x: 73, y: 143))
        path.addCurve(to: CGPoint(x: 91, y: 202), control1: CGPoint(x: 73, y: 170), control2: CGPoint(x: 80, y: 187))
        path.addCurve(to: CGPoint(x: 100, y: 226), control1: CGPoint(x: 97, y: 210), control2: CGPoint(x: 100, y: 216))
        path.addLine(to: CGPoint(x: 100, y: 239))
        path.addCurve(to: CGPoint(x: 122, y: 263), control1: CGPoint(x: 100, y: 253), control2: CGPoint(x: 107, y: 260))
        path.addCurve(to: CGPoint(x: 180, y: 263), control1: CGPoint(x: 139, y: 266), control2: CGPoint(x: 171, y: 263))
        path.addCurve(to: CGPoint(x: 197, y: 239), control1: CGPoint(x: 192, y: 261), control2: CGPoint(x: 197, y: 253))
        path.addLine(to: CGPoint(x: 197, y: 226))
        path.addCurve(to: CGPoint(x: 206, y: 201), control1: CGPoint(x: 197, y: 216), control2: CGPoint(x: 200, y: 210))
        path.addCurve(to: CGPoint(x: 215, y: 162), control1: CGPoint(x: 213, y: 190), control2: CGPoint(x: 215, y: 176))
        path.addLine(to: CGPoint(x: 215, y: 111))
        path.addCurve(to: CGPoint(x: 201, y: 95), control1: CGPoint(x: 215, y: 101), control2: CGPoint(x: 211, y: 96))
        path.addLine(to: CGPoint(x: 188, y: 98))
        path.addCurve(to: CGPoint(x: 164, y: 88), control1: CGPoint(x: 184, y: 88), control2: CGPoint(x: 175, y: 87))
        path.addLine(to: CGPoint(x: 155, y: 93))
        path.addCurve(to: CGPoint(x: 122, y: 89), control1: CGPoint(x: 149, y: 83), control2: CGPoint(x: 133, y: 84))
        path.addLine(to: CGPoint(x: 122, y: 90))
        path.addLine(to: CGPoint(x: 121, y: 43))
        path.addCurve(to: CGPoint(x: 103, y: 25), control1: CGPoint(x: 121, y: 32), control2: CGPoint(x: 116, y: 25))
        path.closeSubpath()

        path.move(to: CGPoint(x: 122, y: 90))
        path.addLine(to: CGPoint(x: 122, y: 100))
        path.move(to: CGPoint(x: 155, y: 93))
        path.addLine(to: CGPoint(x: 155, y: 100))
        path.move(to: CGPoint(x: 188, y: 98))
        path.addLine(to: CGPoint(x: 188, y: 100))
        path.move(to: CGPoint(x: 100, y: 226))
        path.addLine(to: CGPoint(x: 197, y: 226))
        path.move(to: CGPoint(x: 90, y: 130))
        path.addLine(to: CGPoint(x: 90, y: 146))

        return path.applying(translate).applying(resize).applying(place)
    }
}

struct PointerMarkerView: View {
    let color: Color

    var body: some View {
        PointingHandShape()
            .stroke(color,
                    style: StrokeStyle(lineWidth: HUDTheme.lineWidth,
                                       lineCap: .round,
                                       lineJoin: .round))
            .frame(width: HUDTheme.pointerMarkerSize, height: HUDTheme.pointerMarkerSize)
            .contentShape(Rectangle())
            .accessibilityLabel("Маркер-указатель")
    }
}

extension CGPath {
    /// Приближает путь ломаными: кривые Безье разбиваются на отрезки.
    func flattenedPolylines(curveSegments: Int = 12) -> [[CGPoint]] {
        let builder = PolylineBuilder(steps: max(curveSegments, 2))
        applyWithBlock { elementPointer in
            builder.handle(elementPointer.pointee)
        }
        return builder.finish()
    }
}

private final class PolylineBuilder {
    let steps: Int
    private var polylines: [[CGPoint]] = []
    private var current: [CGPoint] = []

    init(steps: Int) {
        self.steps = steps
    }

    func handle(_ element: CGPathElement) {
        switch element.type {
        case .moveToPoint:
            closeCurrent()
            current = [element.points[0]]
        case .addLineToPoint:
            current.append(element.points[0])
        case .addQuadCurveToPoint:
            appendQuad(control: element.points[0], end: element.points[1])
        case .addCurveToPoint:
            appendCubic(control1: element.points[0],
                        control2: element.points[1],
                        end: element.points[2])
        case .closeSubpath:
            if let first = current.first {
                current.append(first)
            }
            closeCurrent()
        @unknown default:
            break
        }
    }

    func finish() -> [[CGPoint]] {
        var result = polylines
        if current.count > 1 {
            result.append(current)
        }
        return result
    }

    private func closeCurrent() {
        if current.count > 1 {
            polylines.append(current)
        }
        current = []
    }

    private func appendQuad(control: CGPoint, end: CGPoint) {
        let start = current.last ?? control
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = Self.quadPoint(start: start, control: control, end: end, t: t)
            current.append(point)
        }
    }

    private func appendCubic(control1: CGPoint, control2: CGPoint, end: CGPoint) {
        let start = current.last ?? control2
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = Self.cubicPoint(start: start,
                                        control1: control1,
                                        control2: control2,
                                        end: end,
                                        t: t)
            current.append(point)
        }
    }

    private static func quadPoint(start: CGPoint,
                                  control: CGPoint,
                                  end: CGPoint,
                                  t: CGFloat) -> CGPoint {
        let inverse = 1 - t
        let w0 = inverse * inverse
        let w1 = 2 * inverse * t
        let w2 = t * t
        let x = w0 * start.x + w1 * control.x + w2 * end.x
        let y = w0 * start.y + w1 * control.y + w2 * end.y
        return CGPoint(x: x, y: y)
    }

    private static func cubicPoint(start: CGPoint,
                                   control1: CGPoint,
                                   control2: CGPoint,
                                   end: CGPoint,
                                   t: CGFloat) -> CGPoint {
        let inverse = 1 - t
        let i2 = inverse * inverse
        let i3 = i2 * inverse
        let t2 = t * t
        let t3 = t2 * t
        let w0 = i3
        let w1 = 3 * i2 * t
        let w2 = 3 * inverse * t2
        let w3 = t3
        let x = w0 * start.x + w1 * control1.x + w2 * control2.x + w3 * end.x
        let y = w0 * start.y + w1 * control1.y + w2 * control2.y + w3 * end.y
        return CGPoint(x: x, y: y)
    }
}