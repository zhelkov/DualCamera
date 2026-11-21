import SwiftUI
import UIKit

struct DrawingPaletteView: View {
    @Bindable var engine: DrawingEngine
    let hapticsEnabled: Bool

    var body: some View {
        VStack(spacing: HUDTheme.drawingPaletteRowSpacing) {
            HStack(spacing: HUDTheme.drawingToolSpacing) {
                ForEach(ToolMode.allCases) { mode in
                    Button {
                        playHaptic()
                        engine.toolMode = mode
                    } label: {
                        HUDIconGlyph(systemName: mode.systemImage,
                                     size: HUDTheme.drawingToolButtonSize)
                    }
                    .buttonStyle(HUDIconButtonStyle(isActive: engine.toolMode == mode,
                                                    size: HUDTheme.drawingToolButtonSize))
                    .accessibilityLabel(mode.title)
                    .accessibilityAddTraits(engine.toolMode == mode ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: HUDTheme.drawingColorSpacing) {
                ForEach(DrawColor.allCases) { color in
                    Button {
                        playHaptic()
                        engine.selectedColor = color
                    } label: {
                        Circle()
                            .fill(color.color)
                            .frame(width: HUDTheme.drawingColorSize,
                                   height: HUDTheme.drawingColorSize)
                            .overlay {
                                Circle()
                                    .stroke(engine.selectedColor == color
                                            ? HUDTheme.drawingSelectedColorBorder
                                            : .clear,
                                            lineWidth: HUDTheme.drawingSelectedColorBorderWidth)
                            }
                            .frame(width: HUDTheme.drawingToolButtonSize,
                                   height: HUDTheme.drawingToolButtonSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(color.title)
                    .accessibilityAddTraits(engine.selectedColor == color ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: HUDTheme.drawingAdjustmentSpacing) {
                CompactBrushSlider(value: $engine.brushWidth,
                                    range: HUDTheme.drawingMinimumBrushWidth...HUDTheme.drawingMaximumBrushWidth)
                    .frame(width: HUDTheme.drawingBrushSliderWidth,
                           height: HUDTheme.drawingActionButtonSize)
                    .accessibilityLabel("Толщина кисти")

                Text("\(Int(engine.brushWidth))")
                    .font(.system(size: HUDTheme.drawingBrushValueFontSize))
                    .foregroundStyle(HUDTheme.drawingBrushValueColor)
                    .frame(minWidth: HUDTheme.drawingBrushValueWidth)
                    .monospacedDigit()
                    .accessibilityHidden(true)

                Button {
                    playHaptic()
                    engine.undo()
                } label: {
                    actionIcon("arrow.uturn.backward")
                }
                .buttonStyle(HUDIconButtonStyle(size: HUDTheme.drawingActionButtonSize))
                .disabled(engine.elements.isEmpty)
                .accessibilityLabel("Отменить последнее действие")

                Button {
                    playHaptic()
                    engine.clear()
                } label: {
                    actionIcon("trash")
                }
                .buttonStyle(HUDIconButtonStyle(size: HUDTheme.drawingActionButtonSize))
                .disabled(engine.elements.isEmpty)
                .accessibilityLabel("Очистить рисунок")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(HUDTheme.drawingPalettePadding)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: HUDTheme.drawingPaletteCornerRadius)
                .fill(HUDTheme.glass)
                .overlay {
                    RoundedRectangle(cornerRadius: HUDTheme.drawingPaletteCornerRadius)
                        .stroke(Color.white.opacity(0.13), lineWidth: HUDTheme.buttonBorderWidth)
                }
        }
        .padding(.horizontal, HUDTheme.drawingPaletteHorizontalInset)
        .accessibilityElement(children: .contain)
    }

    private func actionIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: HUDTheme.drawingActionGlyphSize, weight: .regular))
            .foregroundStyle(HUDTheme.primaryIcon)
            .frame(width: HUDTheme.drawingActionButtonSize,
                   height: HUDTheme.drawingActionButtonSize)
            .contentShape(Rectangle())
    }

    private func playHaptic() {
        guard hapticsEnabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

private struct CompactBrushSlider: UIViewRepresentable {
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>

    func makeCoordinator() -> BrushSliderCoordinator {
        BrushSliderCoordinator(value: $value)
    }

    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider()
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        slider.value = Float(value)
        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.25)
        slider.setThumbImage(Self.thumbImage, for: .normal)
        slider.setThumbImage(Self.thumbImage, for: .highlighted)
        slider.addTarget(context.coordinator, action: #selector(BrushSliderCoordinator.valueChanged(_:)),
                         for: .valueChanged)
        return slider
    }

    func updateUIView(_ slider: UISlider, context: Context) {
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        if abs(CGFloat(slider.value) - value) > 0.01 {
            slider.value = Float(value)
        }
    }

    private static var thumbImage: UIImage {
        let size = CGSize(width: HUDTheme.drawingBrushThumbSize,
                          height: HUDTheme.drawingBrushThumbSize)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
    }
}

final class BrushSliderCoordinator: NSObject {
    private var value: Binding<CGFloat>

    init(value: Binding<CGFloat>) {
        self.value = value
    }

    @objc func valueChanged(_ slider: UISlider) {
        let snappedValue = CGFloat(slider.value).rounded()
        slider.value = Float(snappedValue)
        value.wrappedValue = snappedValue
    }
}
