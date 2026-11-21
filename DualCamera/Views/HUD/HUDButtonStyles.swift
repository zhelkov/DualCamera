import SwiftUI

struct HUDIconButtonStyle: ButtonStyle {
    var isActive = false
    var isCapture = false
    var size = HUDTheme.iconButtonSize
    var cornerRadius: CGFloat = HUDTheme.iconButtonCornerRadius

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isActive ? HUDTheme.yellow : Color.white.opacity(0.9))
            .frame(width: size, height: size)
            .background(
                isCapture ? HUDTheme.glass : (isActive ? HUDTheme.activeFill : .clear),
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(isCapture
                            ? (isActive ? HUDTheme.captureActiveBorder : HUDTheme.captureBorder)
                            : (isActive ? HUDTheme.activeBorder : .clear),
                            lineWidth: HUDTheme.buttonBorderWidth)
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: HUDTheme.stateTransitionDuration), value: isActive)
            .animation(.easeOut(duration: HUDTheme.pressedTransitionDuration), value: configuration.isPressed)
    }
}

struct HUDIconGlyph: View {
    let systemName: String
    var size: CGFloat = HUDTheme.iconButtonSize
    var isLandscape = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * HUDTheme.iconScale, weight: .regular))
            .frame(width: size, height: size)
            .contentShape(Rectangle())
    }
}

struct HUDPanelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(HUDTheme.panelPadding)
            .background {
                RoundedRectangle(cornerRadius: HUDTheme.panelCornerRadius)
                    .fill(HUDTheme.glass)
                    .overlay {
                        RoundedRectangle(cornerRadius: HUDTheme.panelCornerRadius)
                            .stroke(Color.white.opacity(0.13), lineWidth: 1)
                    }
            }
    }
}

extension View {
    func hudPanel() -> some View {
        modifier(HUDPanelStyle())
    }
}
