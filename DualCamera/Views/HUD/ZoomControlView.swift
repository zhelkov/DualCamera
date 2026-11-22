import SwiftUI
import UIKit

/// Дискретные значения зума и полоса прокрутки.
///
/// Жест один на всю панель и живёт на контейнере, поэтому он не теряется,
/// когда панель меняет вид: удержание сразу открывает полосу, и в том же
/// касании можно продолжать вести палец.
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

    @State private var gestureState = ZoomGestureState()
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

    /// Второе дискретное значение: ниже 1x показываем 1, а не повтор 0,5.
    private var secondPresetValue: CGFloat {
        max(zoomFactor, 1)
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
        // система координат жеста.
        .frame(height: HUDTheme.zoomControlFixedHeight)
        // Ширина фиксирована в обоих состояниях: иначе при появлении полосы
        // меняется система координат жеста и значение скачет к пальцу.
        .frame(width: HUDTheme.zoomAdjusterMaximumWidth)
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
        .gesture(panelGesture)
        .padding(.bottom, HUDTheme.zoomControlBottomPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Увеличение")
        .accessibilityValue(zoomLabel(zoomFactor))
        .accessibilityAdjustableAction { direction in
            guard let zoomRange else { return }
            let step = direction == .increment ? 0.5 : -0.5
            let next = min(max(Double(zoomFactor) + step, zoomRange.lowerBound),
                           zoomRange.upperBound)
            onZoomChanged(CGFloat(next))
            onZoomCommitted()
        }
    }

    // MARK: - Свёрнутый вид

    private var collapsedContent: some View {
        HStack(spacing: HUDTheme.zoomPresetHitSize) {
            if showsHalfPreset {
                presetLabel("0,5×", isActive: isNear(zoomFactor, 0.5))
            }
            presetLabel(zoomLabel(secondPresetValue),
                        isActive: !isNear(zoomFactor, 0.5))
        }
        .padding(.horizontal, HUDTheme.zoomPresetSpacing)
        .allowsHitTesting(false)
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
        .allowsHitTesting(false)
    }

    /// Полоса — только индикатор: касание по ней значение не меняет.
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
    }

    // MARK: - Единый жест панели

    private var panelGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                gestureState.lastTranslation = value.translation.width
                if gestureState.startDate == nil {
                    gestureState.startDate = Date()
                    gestureState.base = zoomFactor
                    autoHideWorkItem?.cancel()
                    if isExpanded {
                        beginDrag()
                    } else {
                        startHoldTimer()
                    }
                    return
                }
                guard isExpanded else { return }
                applyDrag(value)
            }
            .onEnded { value in
                let startDate = gestureState.startDate
                gestureState.startDate = nil
                gestureState.holdTimer?.invalidate()
                gestureState.holdTimer = nil
                let duration = Date().timeIntervalSince(startDate ?? Date())
                let moved = abs(value.translation.width) > HUDTheme.zoomDragMovementThreshold

                if gestureState.didAdjust {
                    Haptics.selection()
                    onZoomCommitted()
                    resetDragState()
                    scheduleAutoHide()
                    return
                }
                resetDragState()

                if isExpanded {
                    scheduleAutoHide()
                    return
                }
                // Короткий тап: левая половина — 0,5x, правая — 1x.
                if !moved, duration < HUDTheme.zoomLongPressDuration, containerWidth > 0 {
                    let isLeft = value.startLocation.x < containerWidth / 2
                    let target: Double = (showsHalfPreset && isLeft)
                        ? HUDTheme.minimumZoomPreset
                        : 1
                    Haptics.selection()
                    onZoomChanged(CGFloat(target))
                    onZoomCommitted()
                }
            }
    }

    /// Удержание открывает полосу; палец при этом не отрывается,
    /// поэтому сразу после открытия можно продолжать вести.
    private func startHoldTimer() {
        gestureState.holdTimer?.invalidate()
        let state = gestureState
        let timer = Timer(timeInterval: HUDTheme.zoomLongPressDuration, repeats: false) { _ in
            guard !isExpanded, zoomRange != nil else { return }
            Haptics.selection()
            withAnimation(.easeInOut(duration: HUDTheme.stateTransitionDuration)) {
                isExpanded = true
            }
            beginDrag()
        }
        state.holdTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Точка отсчёта берётся из состояния жеста на момент открытия полосы,
    /// поэтому значение не прыгает к пальцу.
    private func beginDrag() {
        guard gestureState.base != nil else { return }
        gestureState.anchor = gestureState.lastTranslation
        gestureState.didAdjust = false
        gestureState.skipNextUpdate = true
        gestureState.lastHapticStep = Int(((gestureState.base ?? zoomFactor) * 10).rounded())
    }

    private func applyDrag(_ value: DragGesture.Value) {
        // Первое событие после открытия полосы только перезакрепляет точку
        // отсчёта: раскладка уже новая, старое смещение к ней не относится.
        if gestureState.skipNextUpdate {
            gestureState.skipNextUpdate = false
            gestureState.anchor = value.translation.width
            return
        }
        guard let zoomRange else { return }
        let deltaPoints = value.translation.width - gestureState.anchor
        if abs(deltaPoints) > HUDTheme.zoomDragMovementThreshold {
            gestureState.didAdjust = true
        }
        guard gestureState.didAdjust else { return }
        let delta = Double(deltaPoints) / HUDTheme.zoomDragPointsPerUnit
        let base = Double(gestureState.base ?? zoomFactor)
        let next = min(max(base + delta, zoomRange.lowerBound), zoomRange.upperBound)
        guard abs(next - Double(zoomFactor)) > 0.001 else { return }
        onZoomChanged(CGFloat(next))
        let step = Int((CGFloat(next) * 10).rounded())
        if step != gestureState.lastHapticStep {
            gestureState.lastHapticStep = step
            Haptics.selection()
        }
    }

    private func resetDragState() {
        gestureState.base = nil
        gestureState.didAdjust = false
        gestureState.anchor = 0
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

/// Состояние жеста в ссылочном типе: таймер удержания читает актуальные
/// значения, а не устаревшую копию структуры View.
private final class ZoomGestureState {
    var startDate: Date?
    var lastTranslation: CGFloat = 0
    var anchor: CGFloat = 0
    var base: CGFloat?
    var didAdjust = false
    var skipNextUpdate = false
    var lastHapticStep = 0
    var holdTimer: Timer?
}
