import PhotosUI
import SwiftUI
import UIKit

struct TopControlsView: View {
    @Binding var layout: CaptureLayout
    @Binding var splitOrientation: SplitOrientation
    @Binding var pipShape: PipShape
    @Binding var isSecondaryCameraVisible: Bool
    @Binding var isDrawingEnabled: Bool
    @Binding var selectedMediaItems: [PhotosPickerItem]
    @Binding var selectedFilter: VideoFilter
    @Binding var pointerPosition: CGPoint?

    @State private var isFilterCarouselVisible = false

    let hasImportedMedia: Bool
    let isLandscape: Bool
    let hapticsEnabled: Bool
    let onClearImportedMedia: () -> Void

    private var buttonSize: CGFloat {
        HUDTheme.iconButtonSize
    }

    private var variantSize: CGFloat {
        HUDTheme.variantButtonSize
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
        VStack(spacing: HUDTheme.modeColumnGap) {
            VStack(spacing: HUDTheme.controlBlockGap) {
                modeButton(.splitScreen, symbol: "rectangle.split.2x1", label: "Сплит")
                modeButton(.pip, symbol: "pip", label: "Картинка в картинке")
            }
            .hudPanel()

            VStack(spacing: HUDTheme.controlBlockGap) {
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
            .frame(minHeight: HUDTheme.splitVariantMinimumHeight)
            .hudPanel()
            .animation(.easeInOut(duration: HUDTheme.stateTransitionDuration), value: layout)
        }
    }

    private var rightControls: some View {
        VStack(spacing: HUDTheme.modeColumnGap) {
            VStack(spacing: HUDTheme.controlBlockGap) {
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
                    withAnimation(.easeInOut(duration: HUDTheme.stateTransitionDuration)) {
                        isDrawingEnabled.toggle()
                    }
                }
                Button {
                    playHaptic()
                    withAnimation(.easeInOut(duration: HUDTheme.stateTransitionDuration)) {
                        pointerPosition = pointerPosition == nil
                            ? CGPoint(x: 0.5, y: 0.5)
                            : nil
                    }
                } label: {
                    PointingHandShape()
                        .stroke(pointerPosition == nil ? HUDTheme.primaryIcon : HUDTheme.yellow,
                                style: StrokeStyle(lineWidth: HUDTheme.lineWidth,
                                                   lineCap: .round,
                                                   lineJoin: .round))
                        .frame(width: HUDTheme.pointerIconSize, height: HUDTheme.pointerIconSize)
                        .rotationEffect(.degrees(isLandscape ? 90 : 0))
                        .animation(.easeInOut(duration: HUDTheme.rotationDuration), value: isLandscape)
                        .frame(width: buttonSize, height: buttonSize)
                }
                .buttonStyle(HUDIconButtonStyle(isActive: pointerPosition != nil, size: buttonSize))
                .accessibilityLabel(pointerPosition == nil ? "Добавить указатель" : "Убрать указатель")
                .accessibilityAddTraits(pointerPosition == nil ? [] : .isSelected)
                iconButton("camera.filters", label: "Фильтры", size: buttonSize,
                           active: isFilterCarouselVisible || selectedFilter != .original) {
                    withAnimation(.easeInOut(duration: HUDTheme.stateTransitionDuration)) {
                        isFilterCarouselVisible.toggle()
                    }
                }
            }
            .hudPanel()

            iconButton("pip", label: isSecondaryCameraVisible
                       ? "Убрать вторую камеру" : "Показать вторую камеру",
                       size: buttonSize, active: isSecondaryCameraVisible) {
                withAnimation(.easeInOut(duration: HUDTheme.stateTransitionDuration)) {
                    isSecondaryCameraVisible.toggle()
                }
            }
            .hudPanel()

            if isFilterCarouselVisible {
                FilterCarouselView(selectedFilter: $selectedFilter,
                                   hapticsEnabled: hapticsEnabled)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
    }

    private func modeButton(_ value: CaptureLayout, symbol: String, label: String) -> some View {
        Button {
            playHaptic()
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
        Button {
            playHaptic()
            action()
        } label: {
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
        Button {
            playHaptic()
            action()
        } label: {
            HUDIconGlyph(systemName: symbol, size: size, isLandscape: isLandscape)
        }
        .buttonStyle(HUDIconButtonStyle(isActive: active, size: size))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func playHaptic() {
        guard hapticsEnabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }
}
