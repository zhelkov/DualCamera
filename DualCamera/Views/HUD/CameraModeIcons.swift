import SwiftUI

/// Иконка режима «картинка в картинке» по макету: рамка и малое окно
/// в левом верхнем углу.
struct PipModeShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        var path = Path()
        path.addPath(Self.rounded(rect, side, x: 0.1458, y: 0.1667,
                                  width: 0.7083, height: 0.6667, radius: 0.125))
        path.addPath(Self.rounded(rect, side, x: 0.2708, y: 0.2708,
                                  width: 0.2708, height: 0.2292, radius: 0.05))
        return path
    }

    private static func rounded(_ rect: CGRect,
                                _ side: CGFloat,
                                x: CGFloat,
                                y: CGFloat,
                                width: CGFloat,
                                height: CGFloat,
                                radius: CGFloat) -> Path {
        let frame = CGRect(x: rect.minX + x * side,
                           y: rect.minY + y * side,
                           width: width * side,
                           height: height * side)
        return Path(roundedRect: frame, cornerRadius: radius * side)
    }
}

/// Иконка второй камеры по макету: два перекрывающихся кадра.
struct DualCameraShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        var path = Path()
        path.addPath(Self.rounded(rect, side, x: 0.125, y: 0.2917,
                                  width: 0.5833, height: 0.5, radius: 0.0833))
        path.addPath(Self.rounded(rect, side, x: 0.3333, y: 0.1667,
                                  width: 0.5417, height: 0.5, radius: 0.0833))
        return path
    }

    private static func rounded(_ rect: CGRect,
                                _ side: CGFloat,
                                x: CGFloat,
                                y: CGFloat,
                                width: CGFloat,
                                height: CGFloat,
                                radius: CGFloat) -> Path {
        let frame = CGRect(x: rect.minX + x * side,
                           y: rect.minY + y * side,
                           width: width * side,
                           height: height * side)
        return Path(roundedRect: frame, cornerRadius: radius * side)
    }
}

/// Иконка режима сплита по макету: рамка и разделительная линия.
struct SplitModeShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        var path = Path()
        let frame = CGRect(x: rect.minX + 0.1458 * side,
                           y: rect.minY + 0.1667 * side,
                           width: 0.7083 * side,
                           height: 0.6667 * side)
        path.addPath(Path(roundedRect: frame, cornerRadius: 0.125 * side))
        path.move(to: CGPoint(x: rect.minX + 0.1667 * side,
                              y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + 0.8333 * side,
                                 y: rect.midY))
        return path
    }
}

/// Отрисовка контурной иконки в стиле HUD.
struct HUDOutlineIcon<S: Shape>: View {
    let shape: S
    var size: CGFloat = HUDTheme.iconButtonSize
    var isLandscape = false
    var color: Color = HUDTheme.primaryIcon

    var body: some View {
        shape
            .stroke(color,
                    style: StrokeStyle(lineWidth: max(1, size * 0.0625),
                                       lineCap: .round,
                                       lineJoin: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(isLandscape ? 90 : 0))
            .animation(.easeInOut(duration: HUDTheme.rotationDuration), value: isLandscape)
            .contentShape(Rectangle())
    }
}
