import SwiftUI

struct CaptureBarView: View {
    let isLandscape: Bool
    let safeBottom: CGFloat
    let hasTorch: Bool
    let isTorchOn: Bool
    let isRecording: Bool
    let isCapturing: Bool
    let recordingDuration: String
    let onToggleTorch: () -> Void
    let onStopRecording: () -> Void
    let onCapturePhoto: () -> Void
    let onStartRecording: () -> Void
    let onSwapCameras: () -> Void

    var body: some View {
        HStack(spacing: HUDTheme.captureBarItemSpacing) {
            Button {} label: {
                HUDIconGlyph(systemName: "sun.max", size: HUDTheme.captureButtonSize,
                             isLandscape: isLandscape)
            }
            .buttonStyle(HUDIconButtonStyle(isCapture: true, size: HUDTheme.captureButtonSize,
                                            cornerRadius: HUDTheme.captureButtonCornerRadius))
            .disabled(true)
            .accessibilityLabel("Фронтальная подсветка")

            Button(action: onToggleTorch) {
                HUDIconGlyph(systemName: isTorchOn ? "bolt.fill" : "bolt.slash",
                             size: HUDTheme.captureButtonSize, isLandscape: isLandscape)
            }
            .buttonStyle(HUDIconButtonStyle(isActive: isTorchOn, isCapture: true,
                                            size: HUDTheme.captureButtonSize,
                                            cornerRadius: HUDTheme.captureButtonCornerRadius))
            .disabled(!hasTorch)
            .accessibilityLabel(isTorchOn ? "Выключить фонарик" : "Включить фонарик")

            Spacer(minLength: 0)

            if isCapturing {
                ProgressView()
                    .tint(.white)
                    .frame(width: HUDTheme.recordButtonSize, height: HUDTheme.recordButtonSize)
                    .accessibilityLabel("Сохранение снимка")
            } else {
                Button(action: isRecording ? onStopRecording : onStartRecording) {
                    ZStack {
                        Circle()
                            .fill(HUDTheme.glass)
                            .frame(width: HUDTheme.recordButtonSize, height: HUDTheme.recordButtonSize)
                        Circle()
                            .stroke(HUDTheme.recordBorder, lineWidth: HUDTheme.lineWidth)
                            .frame(width: HUDTheme.recordButtonSize, height: HUDTheme.recordButtonSize)
                        RoundedRectangle(cornerRadius: isRecording
                                         ? HUDTheme.recordStopCornerRadius
                                         : HUDTheme.recordInnerSize / 2)
                            .fill(HUDTheme.captureRed)
                            .frame(width: isRecording ? HUDTheme.recordStopSize : HUDTheme.recordInnerSize,
                                   height: isRecording ? HUDTheme.recordStopSize : HUDTheme.recordInnerSize)
                            .animation(.easeInOut(duration: HUDTheme.stateTransitionDuration), value: isRecording)
                    }
                    .frame(width: HUDTheme.recordButtonSize, height: HUDTheme.recordButtonSize)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isRecording ? "Остановить запись" : "Начать запись")
            }

            Spacer(minLength: 0)

            Button(action: onSwapCameras) {
                HUDIconGlyph(systemName: "arrow.triangle.2.circlepath",
                             size: HUDTheme.captureButtonSize, isLandscape: isLandscape)
            }
            .buttonStyle(HUDIconButtonStyle(isCapture: true, size: HUDTheme.captureButtonSize,
                                            cornerRadius: HUDTheme.captureButtonCornerRadius))
            .accessibilityLabel("Поменять камеры местами")

            Button(action: onCapturePhoto) {
                HUDIconGlyph(systemName: "camera", size: HUDTheme.captureButtonSize,
                             isLandscape: isLandscape)
            }
            .buttonStyle(HUDIconButtonStyle(isCapture: true, size: HUDTheme.captureButtonSize,
                                            cornerRadius: HUDTheme.captureButtonCornerRadius))
            .disabled(isRecording || isCapturing)
            .accessibilityLabel("Сделать фото")
        }
        .overlay(alignment: .top) {
            if isRecording {
                Text(recordingDuration)
                    .font(.system(size: HUDTheme.recordingLabelFontSize, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .offset(y: -HUDTheme.recordingLabelOffset)
                    .accessibilityLabel("Длительность записи \(recordingDuration)")
            }
        }
        .padding(.horizontal, HUDTheme.captureBarInset)
        .padding(.top, HUDTheme.captureBarTopPadding)
        .padding(.bottom, max(HUDTheme.captureBarBottomMinimum, safeBottom))
    }
}
