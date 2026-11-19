import PhotosUI
import SwiftUI

struct TopControlsView: View {
    @Binding var layout: CaptureLayout
    @Binding var splitOrientation: SplitOrientation
    @Binding var pipShape: PipShape
    @Binding var isDrawingEnabled: Bool
    @Binding var selectedMediaItems: [PhotosPickerItem]

    let hasImportedMedia: Bool
    let isLandscape: Bool
    let onClearImportedMedia: () -> Void

    private var buttonSize: CGFloat {
        isLandscape ? HUDTheme.landscapeIconButtonSize : HUDTheme.iconButtonSize
    }

    private var variantSize: CGFloat {
        isLandscape ? HUDTheme.landscapeVariantButtonSize : HUDTheme.variantButtonSize
    }

    var body: some View {
        HStack(alignment: .center, spacing: HUDTheme.columnSpacing) {
            leftControls
            Spacer(minLength: 8)
            rightControls
        }
        .accessibilityElement(children: .contain)
    }

    private var leftControls: some View {
        VStack(spacing: isLandscape ? HUDTheme.landscapeModeColumnGap : HUDTheme.modeColumnGap) {
            VStack(spacing: isLandscape ? HUDTheme.landscapeButtonGap : HUDTheme.controlBlockGap) {
                modeButton(.splitScreen, symbol: "rectangle.split.2x1", label: "Сплит")
                modeButton(.pip, symbol: "pip", label: "Картинка в картинке")
            }
            .hudPanel()

            VStack(spacing: isLandscape ? HUDTheme.landscapeButtonGap : HUDTheme.controlBlockGap) {
                if layout == .splitScreen {
                    variantButton(
                        "rectangle.split.2x1",
                        label: "Сверху и снизу",
                        active: splitOrientation == .vertical
                    ) {
                        splitOrientation = .vertical
                    }
                    variantButton(
                        "rectangle.split.1x2",
                        label: "Слева и справа",
                        active: splitOrientation == .horizontal
                    ) {
                        splitOrientation = .horizontal
                    }
                } else {
                    variantButton("rectangle.portrait", label: "Прямоугольник", active: pipShape == .rectangle) {
                        pipShape = .rectangle
                    }
                    variantButton("square", label: "Квадрат", active: pipShape == .square) {
                        pipShape = .square
                    }
                    variantButton("circle", label: "Круг", active: pipShape == .circle) {
                        pipShape = .circle
                    }
                }
            }
            .frame(minHeight: isLandscape ? 0 : HUDTheme.splitVariantMinimumHeight)
            .hudPanel()
            .animation(.easeInOut(duration: HUDTheme.stateTransitionDuration), value: layout)
        }
    }

    private var rightControls: some View {
        VStack(spacing: isLandscape ? HUDTheme.landscapeModeColumnGap : HUDTheme.modeColumnGap) {
            VStack(spacing: isLandscape ? HUDTheme.landscapeButtonGap : HUDTheme.controlBlockGap) {
                if hasImportedMedia {
                    iconButton("xmark", label: "Убрать импортированное медиа", size: buttonSize, active: false,
                               action: onClearImportedMedia)
                } else {
                    PhotosPicker(selection: $selectedMediaItems,
                                 maxSelectionCount: 1,
                                 matching: .any(of: [.images, .videos])) {
                        HUDIconGlyph(systemName: "photo", size: buttonSize, isLandscape: isLandscape)
                    }
                    .buttonStyle(HUDIconButtonStyle(size: buttonSize))
                    .accessibilityLabel("Вставить фото или видео")
                }

                iconButton("pencil", label: "Рисунок", size: buttonSize,
                           active: isDrawingEnabled) {
                    isDrawingEnabled.toggle()
                }
                iconButton("hand.point.up.left", label: "Указатель", size: buttonSize,
                           active: false, enabled: false, action: {})
                iconButton("camera.filters", label: "Фильтры", size: buttonSize,
                           active: false, enabled: false, action: {})
            }
            .hudPanel()

            iconButton("pip", label: "Вторая камера", size: buttonSize,
                       active: false, enabled: false, action: {})
                .hudPanel()
        }
    }

    private func modeButton(_ value: CaptureLayout, symbol: String, label: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: HUDTheme.stateTransitionDuration)) { layout = value }
        } label: {
            HUDIconGlyph(systemName: symbol, size: buttonSize, isLandscape: isLandscape)
        }
        .buttonStyle(HUDIconButtonStyle(isActive: layout == value, size: buttonSize))
        .accessibilityLabel(label)
        .accessibilityAddTraits(layout == value ? .isSelected : [])
    }

    private func variantButton(_ symbol: String,
                               label: String,
                               active: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HUDIconGlyph(systemName: symbol, size: variantSize, isLandscape: isLandscape)
        }
        .buttonStyle(HUDIconButtonStyle(isActive: active, size: variantSize,
                                        cornerRadius: HUDTheme.variantCornerRadius))
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func iconButton(_ symbol: String,
                            label: String,
                            size: CGFloat,
                            active: Bool,
                            enabled: Bool = true,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HUDIconGlyph(systemName: symbol, size: size, isLandscape: isLandscape)
        }
        .buttonStyle(HUDIconButtonStyle(isActive: active, size: size))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}
