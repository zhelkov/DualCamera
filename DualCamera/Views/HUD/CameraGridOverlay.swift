import SwiftUI

struct CameraGridOverlay: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for division in 1..<Int(HUDTheme.gridDivisions) {
                let fraction = CGFloat(division) / HUDTheme.gridDivisions
                let x = size.width * fraction
                let y = size.height * fraction
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(HUDTheme.gridLineColor), lineWidth: HUDTheme.gridLineWidth)
        }
        .accessibilityLabel("Сетка кадра")
        .accessibilityHidden(true)
    }
}

struct CaptureAspectGuideView: View {
    var body: some View {
        Rectangle()
            .stroke(HUDTheme.aspectGuideLine,
                    style: StrokeStyle(lineWidth: HUDTheme.aspectGuideStrokeWidth,
                                       dash: [HUDTheme.aspectGuideDash]))
            .accessibilityLabel("Граница кадра")
            .accessibilityHidden(true)
    }
}
