import SwiftUI
import UIKit

struct ZoomControlView: View {
    let zoomFactor: CGFloat
    let minimumZoomFactor: CGFloat
    let maximumZoomFactor: CGFloat
    @Binding var isExpanded: Bool
    let hapticsEnabled: Bool
    let onZoomChanged: (CGFloat) -> Void

    private var zoomRange: ClosedRange<Double>? {
        let lower = max(HUDTheme.minimumZoomPreset, Double(minimumZoomFactor))
        let upper = min(HUDTheme.maximumZoomPreset, Double(maximumZoomFactor))
        guard lower <= upper else { return nil }
        return lower...upper
    }

    var body: some View {
        VStack(spacing: HUDTheme.zoomControlRowSpacing) {
            if isExpanded, let zoomRange {
                VStack(spacing: HUDTheme.zoomAdjusterRowSpacing) {
                    Text(zoomLabel(zoomFactor))
                        .font(.system(size: HUDTheme.zoomReadoutFontSize, weight: .medium))
                        .foregroundStyle(.white)
                        .monospacedDigit()

                    HStack(spacing: HUDTheme.zoomAdjusterItemSpacing) {
                        Button {
                            playHaptic()
                            adjustZoom(by: -HUDTheme.zoomAdjustmentStep, in: zoomRange)
                        } label: {
                            Image(systemName: "minus")
                                .font(.system(size: HUDTheme.zoomAdjusterIconSize, weight: .medium))
                                .frame(width: HUDTheme.zoomAdjusterButtonSize,
                                       height: HUDTheme.zoomAdjusterButtonSize)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Уменьшить зум")

                        Slider(
                            value: Binding(
                                get: { min(max(Double(zoomFactor), zoomRange.lowerBound), zoomRange.upperBound) },
                                set: { onZoomChanged(CGFloat($0)) }
                            ),
                            in: zoomRange,
                            step: HUDTheme.zoomAdjustmentStep
                        )
                        .tint(HUDTheme.yellow)
                        .accessibilityLabel("Увеличение")

                        Button {
                            playHaptic()
                            adjustZoom(by: HUDTheme.zoomAdjustmentStep, in: zoomRange)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: HUDTheme.zoomAdjusterIconSize, weight: .medium))
                                .frame(width: HUDTheme.zoomAdjusterButtonSize,
                                       height: HUDTheme.zoomAdjusterButtonSize)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Увеличить зум")
                    }
                }
                .padding(.horizontal, HUDTheme.zoomAdjusterHorizontalPadding)
                .padding(.vertical, HUDTheme.zoomAdjusterVerticalPadding)
                .frame(maxWidth: HUDTheme.zoomAdjusterMaximumWidth)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if !isExpanded {
                HStack(spacing: HUDTheme.zoomPresetSpacing) {
                    presetButton(0.5,
                                 isEnabled: minimumZoomFactor <= CGFloat(HUDTheme.minimumZoomPreset))
                    Button {
                        playHaptic()
                        onZoomChanged(1)
                    } label: {
                        Text(isNear(zoomFactor, 1) ? "1×" : zoomLabel(zoomFactor))
                            .font(.system(size: HUDTheme.zoomPresetFontSize,
                                          weight: isNear(zoomFactor, 1) ? .semibold : .regular))
                            .foregroundStyle(isNear(zoomFactor, 1) ? HUDTheme.yellow : .white)
                            .frame(minWidth: HUDTheme.zoomPresetHitSize,
                                   minHeight: HUDTheme.zoomPresetHitSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Зум \(zoomLabel(zoomFactor))")
                    .accessibilityAddTraits(isNear(zoomFactor, 1) ? .isSelected : [])
                }
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: HUDTheme.zoomLongPressDuration) {
                    guard zoomRange != nil else { return }
                    withAnimation(.easeInOut(duration: HUDTheme.stateTransitionDuration)) {
                        isExpanded = true
                    }
                }
            }
        }
        .padding(.bottom, HUDTheme.zoomControlBottomPadding)
        .animation(.easeInOut(duration: HUDTheme.stateTransitionDuration), value: isExpanded)
    }

    private func presetButton(_ value: Double, isEnabled: Bool) -> some View {
        Button {
            playHaptic()
            onZoomChanged(CGFloat(value))
            withAnimation(.easeInOut(duration: HUDTheme.stateTransitionDuration)) {
                isExpanded = false
            }
        } label: {
            Text("0,5×")
                .font(.system(size: HUDTheme.zoomPresetFontSize,
                              weight: isNear(zoomFactor, value) ? .semibold : .regular))
                .foregroundStyle(isNear(zoomFactor, value) ? HUDTheme.yellow : .white)
                .frame(minWidth: HUDTheme.zoomPresetHitSize,
                       minHeight: HUDTheme.zoomPresetHitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("Зум 0,5")
        .accessibilityAddTraits(isNear(zoomFactor, value) ? .isSelected : [])
    }

    private func adjustZoom(by step: Double, in range: ClosedRange<Double>) {
        let next = min(max(Double(zoomFactor) + step, range.lowerBound), range.upperBound)
        onZoomChanged(CGFloat(next))
    }

    private func zoomLabel(_ value: CGFloat) -> String {
        String(format: "%.1f×", locale: Locale.current, Double(value))
    }

    private func isNear(_ value: CGFloat, _ preset: Double) -> Bool {
        abs(value - CGFloat(preset)) < HUDTheme.zoomPresetTolerance
    }

    private func playHaptic() {
        guard hapticsEnabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }
}
