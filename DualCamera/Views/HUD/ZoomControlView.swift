import SwiftUI
import UIKit

struct ZoomControlView: View {
    let zoomFactor: CGFloat
    let minimumZoomFactor: CGFloat
    let maximumZoomFactor: CGFloat
    @Binding var isExpanded: Bool
    let showsHalfPreset: Bool
    let isLandscape: Bool
    let hapticsEnabled: Bool
    let onZoomChanged: (CGFloat) -> Void
    let onZoomCommitted: () -> Void

    @State private var gestureBaseZoom: CGFloat?
    @State private var didAdjustDuringGesture = false
    @State private var wasExpandedAtGestureStart = false
    @State private var containerWidth: CGFloat = 0
    @State private var autoHideWorkItem: DispatchWorkItem?

    private var zoomRange: ClosedRange<Double>? {
        let lower = showsHalfPreset
            ? HUDTheme.minimumZoomPreset
            : max(HUDTheme.minimumZoomPreset, Double(minimumZoomFactor))
        let upper = min(HUDTheme.maximumZoomPreset, Double(maximumZoomFactor))
        guard lower < upper else { return nil }
        return lower...upper
    }

    private var supportsHalfZoom: Bool {
        showsHalfPreset
    }

    var body: some View {
        VStack(spacing: HUDTheme.zoomAdjusterRowSpacing) {
            if isExpanded, zoomRange != nil {
                expandedContent
            } else {
                collapsedContent
            }
        }
        // Фиксированная высота: иначе при появлении ползунка меняется
        // система координат жеста и значение резко перескакивает.
        .frame(height: HUDTheme.zoomControlFixedHeight)
        .padding(.horizontal, HUDTheme.zoomAdjusterHorizontalPadding)
        .padding(.vertical, HUDTheme.zoomAdjusterVerticalPadding)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { containerWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, width in containerWidth = width }
            }
        }
        .contentShape(Rectangle())
        .gesture(zoomGesture)
        .padding(.bottom, HUDTheme.zoomControlBottomPadding)
        .accessibilityElement(children: .contain)
    }

    /// Второе дискретное значение: ниже 1x показываем 1, а не повтор 0,5.
    private var secondPresetValue: CGFloat {
        max(zoomFactor, 1)
    }

    // MARK: - Свёрнутый вид

    private var collapsedContent: some View {
        HStack(spacing: HUDTheme.zoomPresetHitSize) {
            if supportsHalfZoom {
                presetLabel("0,5×", isActive: isNear(zoomFactor, 0.5))
            }
            presetLabel(zoomLabel(secondPresetValue), isActive: true)
        }
        .padding(.horizontal, HUDTheme.zoomPresetSpacing)
    }

    private func presetLabel(_ text: String, isActive: Bool) -> some View {
        Text(text)
            .font(.system(size: HUDTheme.zoomPresetFontSize,
                          weight: isActive ? .semibold : .regular))
            .foregroundStyle(isActive ? HUDTheme.yellow : .white)
            .rotationEffect(.degrees(isLandscape ? 90 : 0))
            .animation(.easeInOut(duration: HUDTheme.rotationDuration), value: isLandscape)
            .frame(minWidth: HUDTheme.zoomPresetHitSize,
                   minHeight: HUDTheme.zoomPresetHitSize)
            .contentShape(Rectangle())
    }

    // MARK: - Развёрнутый вид

    private var expandedContent: some View {
        VStack(spacing: HUDTheme.zoomAdjusterRowSpacing) {
            Text(zoomLabel(zoomFactor))
                .font(.system(size: HUDTheme.zoomReadoutFontSize, weight: .medium))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(isLandscape ? 90 : 0))
                .animation(.easeInOut(duration: HUDTheme.rotationDuration), value: isLandscape)
                .monospacedDigit()

            HStack(spacing: HUDTheme.zoomAdjusterItemSpacing) {
                Image(systemName: "minus")
                    .font(.system(size: HUDTheme.zoomAdjusterIconSize, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: HUDTheme.zoomAdjusterButtonSize,
                           height: HUDTheme.zoomAdjusterButtonSize)
                track
                Image(systemName: "plus")
                    .font(.system(size: HUDTheme.zoomAdjusterIconSize, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: HUDTheme.zoomAdjusterButtonSize,
                           height: HUDTheme.zoomAdjusterButtonSize)
            }
        }
        .frame(maxWidth: HUDTheme.zoomAdjusterMaximumWidth)
    }

    private var track: some View {
        GeometryReader { geo in
            let range = zoomRange ?? 1...1
            let span = max(range.upperBound - range.lowerBound, 0.001)
            let progress = min(max((Double(zoomFactor) - range.lowerBound) / span, 0), 1)
            let usableWidth = max(geo.size.width - HUDTheme.zoomThumbSize, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .frame(height: HUDTheme.zoomTrackThickness)
                Circle()
                    .fill(.white)
                    .frame(width: HUDTheme.zoomThumbSize, height: HUDTheme.zoomThumbSize)
                    .offset(x: usableWidth * progress)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: HUDTheme.zoomThumbSize)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Увеличение")
    }

    // MARK: - Жест

    private var zoomGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let zoomRange else { return }
                autoHideWorkItem?.cancel()
                if gestureBaseZoom == nil {
                    gestureBaseZoom = zoomFactor
                    wasExpandedAtGestureStart = isExpanded
                    didAdjustDuringGesture = false
                    if !isExpanded {
                        withAnimation(.easeInOut(duration: HUDTheme.stateTransitionDuration)) {
                            isExpanded = true
                        }
                    }
                    return
                }
                guard isExpanded else { return }
                // Сдвиг пальца в точках: полоса только индикатор,
                // значение меняется исключительно перемещением.
                if abs(value.translation.width) > HUDTheme.zoomDragMovementThreshold {
                    didAdjustDuringGesture = true
                }
                guard didAdjustDuringGesture else { return }
                let delta = Double(value.translation.width) / HUDTheme.zoomDragPointsPerUnit
                let base = Double(gestureBaseZoom ?? zoomFactor)
                let next = min(max(base + delta, zoomRange.lowerBound), zoomRange.upperBound)
                guard abs(next - Double(zoomFactor)) > 0.001 else { return }
                onZoomChanged(CGFloat(next))
            }
            .onEnded { value in
                let didAdjust = didAdjustDuringGesture
                let wasExpanded = wasExpandedAtGestureStart
                gestureBaseZoom = nil
                didAdjustDuringGesture = false
                if didAdjust {
                    Haptics.selection()
                    onZoomCommitted()
                    scheduleAutoHide()
                    return
                }
                if wasExpanded {
                    scheduleAutoHide()
                    return
                }
                // Короткое касание по левой части — быстрый выбор 0,5x.
                if showsHalfPreset, containerWidth > 0,
                   value.startLocation.x < containerWidth / 2 {
                    Haptics.selection()
                    onZoomChanged(CGFloat(HUDTheme.minimumZoomPreset))
                    onZoomCommitted()
                }
                scheduleAutoHide()
            }
    }

    /// Полоса исчезает не сразу: за один свайп не всегда удаётся пройти
    /// весь диапазон, поэтому даём время вернуться пальцем.
    private func scheduleAutoHide() {
        autoHideWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            withAnimation(.easeInOut(duration: HUDTheme.stateTransitionDuration)) {
                isExpanded = false
            }
        }
        autoHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + HUDTheme.zoomAutoHideDelay,
                                      execute: workItem)
    }

    private func zoomLabel(_ value: CGFloat) -> String {
        let rounded = (Double(value) * 10).rounded() / 10
        return String(format: "%.1f×", locale: Locale.current, rounded)
    }

    private func isNear(_ value: CGFloat, _ preset: Double) -> Bool {
        abs(value - CGFloat(preset)) < HUDTheme.zoomPresetTolerance
    }
}
