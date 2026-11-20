import SwiftUI

struct DrawingPaletteView: View {
    @Bindable var engine: DrawingEngine

    var body: some View {
        VStack(spacing: HUDTheme.drawingPaletteRowSpacing) {
            HStack(spacing: HUDTheme.drawingToolSpacing) {
                ForEach(ToolMode.allCases) { mode in
                    Button {
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
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(color.title)
                    .accessibilityAddTraits(engine.selectedColor == color ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: HUDTheme.drawingAdjustmentSpacing) {
                Slider(value: $engine.brushWidth,
                       in: HUDTheme.drawingMinimumBrushWidth...HUDTheme.drawingMaximumBrushWidth,
                       step: 1)
                    .frame(width: HUDTheme.drawingBrushSliderWidth)
                    .tint(.white)
                    .accessibilityLabel("Толщина кисти")

                Text("\(Int(engine.brushWidth))")
                    .font(.system(size: HUDTheme.drawingBrushValueFontSize))
                    .foregroundStyle(HUDTheme.drawingBrushValueColor)
                    .frame(minWidth: HUDTheme.drawingBrushValueWidth)
                    .monospacedDigit()
                    .accessibilityHidden(true)

                Button {
                    engine.undo()
                } label: {
                    actionIcon("arrow.uturn.backward")
                }
                .buttonStyle(HUDIconButtonStyle(size: HUDTheme.drawingActionButtonSize))
                .disabled(engine.elements.isEmpty)
                .accessibilityLabel("Отменить последнее действие")

                Button {
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
}
