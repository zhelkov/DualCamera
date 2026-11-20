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
