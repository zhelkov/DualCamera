import SwiftUI

struct HUDOverlayView: View {
    let size: CGSize
    let safeTop: CGFloat
    let safeBottom: CGFloat
    let isLandscape: Bool
    let topControls: TopControlsView
    let captureBar: CaptureBarView
    let zoomControls: AnyView
    let drawingPalette: AnyView
    let debugControls: AnyView

    private var topStripHeight: CGFloat {
        max(HUDTheme.topStripMinimumHeight, safeTop + HUDTheme.topSafeAreaAddition)
    }

    private var bottomStripHeight: CGFloat {
        let minimum = isLandscape
            ? HUDTheme.landscapeBottomStripMinimumHeight
            : HUDTheme.bottomStripMinimumHeight
        let safeAreaAddition = isLandscape
            ? HUDTheme.landscapeBottomSafeAreaAddition
            : HUDTheme.bottomSafeAreaAddition
        return max(minimum, safeBottom + safeAreaAddition)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            strips

            topControls
                .frame(width: max(0, size.width - 2 * HUDTheme.controlColumnInset))
                .position(x: size.width / 2,
                          y: (topStripHeight + size.height - bottomStripHeight) / 2)

            settingsButton
                .position(x: size.width - HUDTheme.settingsRightInset - HUDTheme.settingsButtonSize / 2,
                          y: max(HUDTheme.settingsTopMinimum, safeTop + HUDTheme.settingsTopInset)
                            + HUDTheme.settingsButtonSize / 2)

            zoomControls
                .frame(width: size.width)
                .position(x: size.width / 2,
                          y: size.height - bottomStripHeight - HUDTheme.zoomControlBottomOffset)

            drawingPalette
                .frame(width: size.width)
                .position(x: size.width / 2,
                          y: max(HUDTheme.paletteTopMinimum, safeTop) + HUDTheme.paletteYOffset)

            captureBar
                .frame(width: size.width, height: bottomStripHeight, alignment: .center)
                .position(x: size.width / 2, y: size.height - bottomStripHeight / 2)

            debugControls
                .frame(width: size.width)
                .position(x: size.width / 2, y: topStripHeight + HUDTheme.debugControlsYOffset)
        }
        .frame(width: size.width, height: size.height)
    }

    private var strips: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                HUDTheme.ink
                Capsule()
                    .fill(HUDTheme.islandFill)
                    .frame(width: HUDTheme.islandWidth, height: HUDTheme.islandHeight)
                    .overlay {
                        Capsule().stroke(HUDTheme.islandBorder, lineWidth: 1)
                    }
                    .padding(.top, HUDTheme.islandTopInset)
            }
            .frame(height: topStripHeight)

            Spacer(minLength: 0)

            HUDTheme.ink
                .frame(height: bottomStripHeight)
        }
        .frame(width: size.width, height: size.height)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var settingsButton: some View {
        Button {} label: {
            Image(systemName: "gearshape")
                .font(.system(size: HUDTheme.settingsIconSize, weight: .regular))
                .rotationEffect(.degrees(isLandscape ? 90 : 0))
                .animation(.easeInOut(duration: HUDTheme.rotationDuration), value: isLandscape)
                .foregroundStyle(HUDTheme.primaryIcon)
                .frame(width: HUDTheme.settingsButtonSize, height: HUDTheme.settingsButtonSize)
                .background(HUDTheme.glass, in: Circle())
                .overlay(Circle().stroke(HUDTheme.settingsBorder,
                                         lineWidth: HUDTheme.buttonBorderWidth))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Настройки")
    }
}
