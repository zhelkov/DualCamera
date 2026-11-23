import SwiftUI
import AVFoundation
import Combine
import Photos
import PhotosUI
import CoreTransferable
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var camera = CameraManager()
    @State private var settings = CameraSettings()
    @Environment(\.scenePhase) private var scenePhase
    @State private var pipOffset: CGSize = .zero
    /// Базовое смещение окна PiP в превью (точка отсчёта перетаскивания).
    @State private var pipBaseInset: CGPoint = CGPoint(x: HUDTheme.pipPreviewInset,
                                                       y: HUDTheme.topStripMinimumHeight + HUDTheme.pipPreviewInset)
    @State private var photoOverlayOffset: CGSize = .zero
    @State private var previewSize: CGSize = .zero
    @State private var importedImageWidthFraction: CGFloat = 0.3
    @State private var pipDragBase: CGSize?
    @State private var photoOverlayDragBase: CGSize?
    @State private var isZoomSliderVisible = false
    @State private var isSettingsPresented = false
    @State private var isFrontLightEnabled = false
    @State private var pointerPosition: CGPoint?
    @State private var pointerDragBase: CGPoint?
    @State private var focusIndicator: FocusIndicatorState?
    @State private var focusGestureStartDate: Date?
    @State private var exposureDragStartBias: Float?
    @State private var isDeviceLandscape = false
    @State private var isFilterLabelVisible = false
    @State private var filterLabelHideWorkItem: DispatchWorkItem?
    @State private var focusHideWorkItem: DispatchWorkItem?
    @State private var drawing = DrawingEngine()
    @State private var selectedMediaItems: [PhotosPickerItem] = []

    var body: some View { presentedCameraView }

    private var presentedCameraView: some View {
        recordingStateView
            .alert("Ошибка", isPresented: errorBinding) {
                Button("ОК", role: .cancel) {}
            } message: {
                Text(camera.errorMessage ?? "")
            }
            .sheet(isPresented: mergedPhotoBinding) {
                MergedPhotoView(photo: camera.lastMergedPhoto ?? UIImage())
            }
            .sheet(isPresented: mergedVideoBinding) {
                if let url = camera.lastMergedVideoURL {
                    MergedVideoView(videoURL: url)
                }
            }
            .sheet(isPresented: $isSettingsPresented) {
                SettingsSheetView(settings: settings,
                                  isRecording: camera.isRecording || camera.isApplyingSettings,
                                  hasImportedMedia: camera.importedVideoURL != nil)
                    .presentationDetents([.fraction(HUDTheme.settingsSheetHeight), .large])
                    .presentationDragIndicator(.hidden)
                    .presentationCornerRadius(HUDTheme.settingsSheetCornerRadius)
            }
    }

    private var recordingStateView: some View {
        lifecycleView
            .onChange(of: drawing.elements) { _, _ in
                camera.updateRecordingElements(mediaDrawingElements())
            }
            .onChange(of: drawing.draftElement) { _, _ in
                camera.updateRecordingElements(mediaDrawingElements(includeDraft: true))
            }
            .onChange(of: pointerPosition) { _, _ in
                camera.updateRecordingElements(mediaDrawingElements(includeDraft: drawing.isDragging))
            }
            .onChange(of: camera.layout) { _, _ in updateRecordingLayout() }
            .onChange(of: camera.pipShape) { _, _ in updateRecordingLayout() }
            .onChange(of: camera.splitOrientation) { _, _ in updateRecordingLayout() }
            .onChange(of: camera.splitRatio) { _, _ in updateRecordingLayout() }
            .onChange(of: camera.isSecondaryCameraVisible) { _, _ in
                if !camera.isSecondaryCameraVisible && camera.activeFilterTarget == .secondary {
                    camera.selectFilterTarget(.primary)
                }
                if !isFrontLightAvailable { isFrontLightEnabled = false }
                updateRecordingLayout()
            }
            .onChange(of: camera.isCamerasSwapped) { _, _ in
                if !isFrontLightAvailable { isFrontLightEnabled = false }
            }
            .onChange(of: camera.importedVideoURL) { _, _ in
                if !isFrontLightAvailable { isFrontLightEnabled = false }
            }
            .onChange(of: camera.videoFilter) { _, _ in
                showFilterLabelTemporarily()
            }
            .sensoryFeedback(.impact(weight: .light), trigger: camera.layout) { _, _ in settings.hapticsEnabled }
            .sensoryFeedback(.impact(weight: .light), trigger: camera.splitOrientation) { _, _ in settings.hapticsEnabled }
            .sensoryFeedback(.impact(weight: .light), trigger: camera.pipShape) { _, _ in settings.hapticsEnabled }
            .sensoryFeedback(.impact(weight: .light), trigger: camera.videoFilter) { _, _ in settings.hapticsEnabled }
            .sensoryFeedback(.impact(weight: .light), trigger: camera.isSecondaryCameraVisible) { _, _ in settings.hapticsEnabled }
            .sensoryFeedback(.impact(weight: .light), trigger: camera.isCamerasSwapped) { _, _ in settings.hapticsEnabled }
            .sensoryFeedback(.impact(weight: .light), trigger: camera.isTorchOn) { _, _ in settings.hapticsEnabled }
            .sensoryFeedback(.impact(weight: .light), trigger: isFrontLightEnabled) { _, _ in settings.hapticsEnabled }
            .sensoryFeedback(.impact(weight: .light), trigger: pointerPosition != nil) { _, _ in settings.hapticsEnabled }
            .sensoryFeedback(.impact(weight: .light), trigger: drawing.toolMode) { _, _ in settings.hapticsEnabled }
            .sensoryFeedback(.impact(weight: .light), trigger: drawing.selectedColor) { _, _ in settings.hapticsEnabled }
            .sensoryFeedback(.impact(weight: .medium), trigger: camera.isRecording) { _, _ in settings.hapticsEnabled }
            .sensoryFeedback(.impact(weight: .light), trigger: Int((camera.zoomFactor * 10).rounded())) { _, _ in
                settings.hapticsEnabled
            }
    }

    private var lifecycleView: some View {
        cameraScene
            .ignoresSafeArea()
            .task {
                camera.applyCaptureSettings(settings.snapshot)
                await camera.requestAccessAndSetup()
            }
            .onAppear {
                Haptics.preferSystemVibration = settings.systemVibrationEnabled
                Haptics.audioCanBeReleased = !camera.isRecording
                Haptics.prepare()
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                updateDeviceOrientation()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                updateDeviceOrientation()
            }
            .onDisappear { camera.stopRunning() }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    camera.startRunning()
                case .background:
                    camera.stopRunning()
                default:
                    break
                }
            }
            .onChange(of: selectedMediaItems) { _, items in
                handlePickedMedia(items)
            }
            .onChange(of: settings.snapshot) { _, snapshot in
                camera.applyCaptureSettings(snapshot)
            }
            .onChange(of: settings.systemVibrationEnabled) { _, enabled in
                Haptics.preferSystemVibration = enabled
            }
            .onChange(of: camera.isRecording) { _, recording in
                Haptics.audioCanBeReleased = !recording
            }
    }

    private var cameraScene: some View {
        ZStack {
            previewStack
            if isFrontLightEnabled && isFrontLightAvailable {
                Color.white.opacity(HUDTheme.frontLightOverlayOpacity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            cameraSettingsOverlay
            DrawingCanvas(engine: drawing)
                .allowsHitTesting(drawing.isDrawingEnabled)
            focusIndicatorOverlay
            pointerMarkerOverlay
            controls
        }
    }

    private func updateRecordingLayout() {
        camera.updateRecordingLayout(layout: camera.layout,
                                     shape: camera.pipShape,
                                     splitOrientation: camera.splitOrientation,
                                     splitRatio: camera.splitRatio,
                                     isSecondaryCameraVisible: camera.isSecondaryCameraVisible)
    }

    private var cameraSettingsOverlay: some View {
        GeometryReader { geometry in
            let topStripHeight = max(HUDTheme.topStripMinimumHeight,
                                     geometry.safeAreaInsets.top + HUDTheme.topSafeAreaAddition)
            let bottomStripHeight = HUDTheme.bottomStripMinimumHeight
            let previewRect = CGRect(x: 0,
                                     y: topStripHeight,
                                     width: geometry.size.width,
                                     height: max(0, geometry.size.height - topStripHeight - bottomStripHeight))
            let aspectRatio = settings.aspectRatio.ratio(isPortrait: true)
            let guideWidth = min(previewRect.width, previewRect.height * aspectRatio)
            let guideHeight = guideWidth / aspectRatio
            let guideRect = CGRect(x: previewRect.minX + (previewRect.width - guideWidth) / 2,
                                   y: previewRect.minY + (previewRect.height - guideHeight) / 2,
                                   width: guideWidth,
                                   height: guideHeight)
            ZStack {
                if settings.gridEnabled {
                    CameraGridOverlay()
                        .frame(width: guideWidth, height: guideHeight)
                        .position(x: guideRect.midX, y: guideRect.midY)
                        .allowsHitTesting(false)
                }

                CaptureAspectGuideView()
                    .frame(width: guideWidth, height: guideHeight)
                    .position(x: guideRect.midX, y: guideRect.midY)

                if settings.dateTimeEnabled {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(dateTimeString(context.date))
                            .font(.system(size: HUDTheme.cameraDateTimeFontSize,
                                          weight: .medium, design: .monospaced))
                            .foregroundStyle(.white)
                            .frame(width: guideWidth, height: guideHeight, alignment: .bottomTrailing)
                            .offset(x: -HUDTheme.cameraDateTimeEdgeInset,
                                    y: -HUDTheme.cameraDateTimeEdgeInset)
                            .position(x: guideRect.midX,
                                      y: guideRect.midY)
                            .allowsHitTesting(false)
                    }
                }

                if settings.teleprompterEnabled {
                    Text(settings.teleprompterText.isEmpty
                         ? "Текст телесуфлёра"
                         : settings.teleprompterText)
                        .font(.system(size: HUDTheme.teleprompterFontSize, weight: .medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(HUDTheme.teleprompterPreviewLineLimit)
                        .padding(HUDTheme.cameraOverlayHorizontalPadding)
                        .frame(maxWidth: geometry.size.width * HUDTheme.teleprompterWidthFraction)
                        .background(Color.black.opacity(0.48),
                                    in: RoundedRectangle(cornerRadius: HUDTheme.settingsTextFieldCornerRadius))
                        .position(x: previewRect.midX,
                                  y: max(previewRect.minY + HUDTheme.teleprompterTopMinimum,
                                         geometry.safeAreaInsets.top + HUDTheme.teleprompterTopInset)
                                    + HUDTheme.teleprompterYOffset)
                        .allowsHitTesting(false)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .allowsHitTesting(false)
    }

    private var pointerMarkerOverlay: some View {
        GeometryReader { geometry in
            if let pointerPosition {
                PointerMarkerView(color: .red)
                    .frame(width: HUDTheme.pointerMarkerSize,
                           height: HUDTheme.pointerMarkerSize)
                    .position(x: pointerPosition.x * geometry.size.width,
                              y: pointerPosition.y * geometry.size.height)
                    .gesture(pointerDrag(in: geometry.size))
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .ignoresSafeArea()
    }

    private var focusIndicatorOverlay: some View {
        GeometryReader { geometry in
            if let focusIndicator {
                let center = CGPoint(x: focusIndicator.position.x * geometry.size.width,
                                     y: focusIndicator.position.y * geometry.size.height)
                ZStack {
                    Rectangle()
                        .stroke(HUDTheme.yellow, lineWidth: HUDTheme.focusReticleStrokeWidth)
                        .frame(width: HUDTheme.focusReticleSize,
                               height: HUDTheme.focusReticleSize)
                        .position(x: center.x, y: center.y)

                    if focusIndicator.isLocked {
                        Text("AE/AF LOCK")
                            .font(.system(size: HUDTheme.focusLockFontSize, weight: .semibold))
                            .foregroundStyle(HUDTheme.yellow)
                            .padding(.horizontal, HUDTheme.focusLockHorizontalPadding)
                            .padding(.vertical, HUDTheme.focusLockVerticalPadding)
                            .background(Color.black.opacity(0.68), in: Capsule())
                            .position(x: center.x,
                                      y: center.y + HUDTheme.focusReticleSize / 2 + HUDTheme.focusLockVerticalOffset)
                            .accessibilityLabel("Фокус и экспозиция заблокированы")
                    } else {
                        VStack(spacing: HUDTheme.exposureIndicatorSpacing) {
                            Image(systemName: "sun.max.fill")
                                .font(.system(size: HUDTheme.exposureSunSize, weight: .medium))
                                .foregroundStyle(HUDTheme.yellow)
                                .frame(width: HUDTheme.exposureSunHitSize,
                                       height: HUDTheme.exposureSunHitSize)
                                .contentShape(Rectangle())
                                .gesture(exposureBiasDrag(target: focusIndicator.target))
                                .accessibilityLabel("Изменить экспозицию")
                            Text(exposureBiasLabel(camera.exposureTargetBias))
                                .font(.system(size: HUDTheme.exposureValueFontSize, weight: .medium))
                                .foregroundStyle(.white)
                                .monospacedDigit()
                        }
                        .position(x: min(max(center.x + HUDTheme.exposureIndicatorXOffset,
                                             HUDTheme.exposureSunHitSize / 2),
                                         geometry.size.width - HUDTheme.exposureSunHitSize / 2),
                                  y: center.y)
                    }
                }
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(true)
    }

    // MARK: - Превью

    @ViewBuilder
    private var previewStack: some View {
        GeometryReader { geo in
            let size = geo.size
            let backIsMain = !camera.isCamerasSwapped
            // Размер самой картинки PiP (портретный) и размер её окна на экране.
            // В ландшафте окно повёрнуто на 90°, поэтому стороны меняются местами,
            // иначе повёрнутый прямоугольник обрезается.
            let pipContentSize = Self.pipSize(for: camera.pipShape, in: size, widthFraction: 0.3)
            let pipSlotSize = isDeviceLandscape
                ? CGSize(width: pipContentSize.height, height: pipContentSize.width)
                : pipContentSize
            // В сплит-режиме вторичное окно — это ячейка сплита, а не PiP.
            let isPipLayout = camera.layout == .pip
            let secondaryContentSize = isPipLayout ? pipContentSize : .zero
            let pipTopInset = max(HUDTheme.topStripMinimumHeight,
                                  geo.safeAreaInsets.top + HUDTheme.topSafeAreaAddition)
                + HUDTheme.pipPreviewInset
            let frames = Self.layoutFrames(layout: camera.layout, size: size, pipSize: pipSlotSize,
                                           pipOffset: pipOffset,
                                           pipTopInset: pipTopInset,
                                           splitOrientation: camera.splitOrientation,
                                           splitRatio: camera.splitRatio,
                                           isSecondaryCameraVisible: camera.isSecondaryCameraVisible)
            let pipRadius = camera.pipShape.cornerRadius(for: pipSlotSize)

            ZStack(alignment: .topLeading) {
                if backIsMain {
                    backCameraContent
                        .frame(width: frames.main.width, height: frames.main.height)
                        .offset(x: frames.main.minX, y: frames.main.minY)
                        .gesture(focusTap(in: frames.main.size,
                                         origin: CGPoint(x: frames.main.minX, y: frames.main.minY),
                                         target: .primary))

                    if camera.isSecondaryCameraVisible {
                        secondaryPreview(frontCameraContent,
                                         contentSize: pipContentSize,
                                         slot: frames.secondary,
                                         radius: pipRadius)
                            .gesture(pipDrag)
                            .simultaneousGesture(focusTap(
                                in: frames.secondary.size,
                                origin: CGPoint(x: frames.secondary.minX, y: frames.secondary.minY),
                                target: .secondary
                            ))
                    }
                } else {
                    frontCameraContent
                        .frame(width: frames.main.width, height: frames.main.height)
                        .offset(x: frames.main.minX, y: frames.main.minY)
                        .gesture(focusTap(in: frames.main.size,
                                         origin: CGPoint(x: frames.main.minX, y: frames.main.minY),
                                         target: .primary))

                    if camera.isSecondaryCameraVisible {
                        secondaryPreview(backCameraContent,
                                         contentSize: pipContentSize,
                                         slot: frames.secondary,
                                         radius: pipRadius)
                            .gesture(pipDrag)
                            .simultaneousGesture(focusTap(
                                in: frames.secondary.size,
                                origin: CGPoint(x: frames.secondary.minX, y: frames.secondary.minY),
                                target: .secondary
                            ))
                    }
                }

                if let photo = camera.importedPhoto {
                    let frame = photoOverlayFrame(for: photo, in: size)
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                        .frame(width: frame.width, height: frame.height)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white, lineWidth: 2))
                        .shadow(color: .black.opacity(0.35), radius: 5)
                        .offset(x: frame.minX, y: frame.minY)
                        .gesture(photoOverlayDrag)
                }

                if camera.layout == .splitScreen && camera.isSecondaryCameraVisible {
                    SplitDividerView(orientation: camera.splitOrientation,
                                     ratio: camera.splitRatio) { ratio in
                        camera.splitRatio = ratio
                    }
                    .frame(width: size.width, height: size.height)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: camera.layout)
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: camera.isCamerasSwapped)
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: camera.pipShape)
            .animation(.easeInOut(duration: HUDTheme.stateTransitionDuration),
                       value: camera.isSecondaryCameraVisible)
            .onAppear {
                previewSize = size
                pipBaseInset = CGPoint(x: HUDTheme.pipPreviewInset, y: pipTopInset)
            }
            .onChange(of: size) { _, newSize in
                previewSize = newSize
                pipBaseInset = CGPoint(x: HUDTheme.pipPreviewInset, y: pipTopInset)
            }
            .onChange(of: pipTopInset) { _, newInset in
                pipBaseInset = CGPoint(x: HUDTheme.pipPreviewInset, y: newInset)
            }
        }
    }

    /// Второе превью. В режиме PiP картинка строится в своих пропорциях и
    /// поворачивается в ландшафте; в сплит-режиме она просто заполняет ячейку.
    private func secondaryPreview<Content: View>(_ content: Content,
                                                contentSize: CGSize,
                                                slot: CGRect,
                                                radius: CGFloat) -> some View {
        let isPip = camera.layout == .pip
        let innerSize = isPip ? contentSize : slot.size
        return content
            .frame(width: innerSize.width, height: innerSize.height)
            .rotationEffect(.degrees(isPip && isDeviceLandscape ? 90 : 0))
            .animation(.easeInOut(duration: HUDTheme.rotationDuration), value: isDeviceLandscape)
            .frame(width: slot.width, height: slot.height)
            .modifier(SecondaryPreviewClip(layout: camera.layout, radius: isPip ? radius : 0))
            .offset(x: slot.minX, y: slot.minY)
    }

    @ViewBuilder
    private var backCameraContent: some View {
        if let image = camera.backFilteredPreviewImage {
            FilteredCameraPreviewView(image: image, isMirrored: false)
        } else {
            CameraPreviewView(previewLayer: camera.backPreviewLayer, isMirrored: false)
        }
    }

    @ViewBuilder
    private var frontCameraContent: some View {
        if let image = camera.frontFilteredPreviewImage {
            FilteredCameraPreviewView(image: image, isMirrored: true)
        } else {
            CameraPreviewView(previewLayer: camera.frontPreviewLayer, isMirrored: false)
        }
    }

    private var pipOffsetFraction: CGSize {
        pipOffsetFraction(for: pipOffset)
    }

    private var photoOverlayOffsetFraction: CGSize {
        offsetFraction(for: photoOverlayOffset)
    }

    private func photoOverlayFrame(for image: UIImage, in size: CGSize) -> CGRect {
        let width = size.width * importedImageWidthFraction
        let height = width * image.size.height / max(image.size.width, 1)
        let x = min(max(0, 16 + photoOverlayOffset.width), size.width - width)
        let y = min(max(0, 16 + photoOverlayOffset.height), size.height - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func offsetFraction(for offset: CGSize) -> CGSize {
        guard previewSize.width > 0, previewSize.height > 0 else { return .zero }
        return CGSize(width: offset.width / previewSize.width,
                      height: offset.height / previewSize.height)
    }

    /// Доля кадра, в которой находится левый верхний угол окна PiP.
    /// Считаем от реального положения в превью, чтобы видео совпадало с экраном.
    private func pipOffsetFraction(for offset: CGSize) -> CGSize {
        guard previewSize.width > 0, previewSize.height > 0 else { return .zero }
        return CGSize(width: (pipBaseInset.x + offset.width) / previewSize.width,
                      height: (pipBaseInset.y + offset.height) / previewSize.height)
    }

    /// Точный прямоугольник окна PiP в долях кадра — по нему видео
    /// и фото ставят окно туда же, где оно на экране.
    private func pipRectFraction(for offset: CGSize, in size: CGSize) -> CGRect? {
        guard size.width > 0, size.height > 0 else { return nil }
        let content = Self.pipSize(for: camera.pipShape, in: size, widthFraction: 0.3)
        let slot = isDeviceLandscape
            ? CGSize(width: content.height, height: content.width)
            : content
        let frames = Self.layoutFrames(layout: .pip,
                                       size: size,
                                       pipSize: slot,
                                       pipOffset: offset,
                                       pipTopInset: pipBaseInset.y,
                                       splitOrientation: camera.splitOrientation,
                                       splitRatio: camera.splitRatio,
                                       isSecondaryCameraVisible: true)
        let rect = frames.secondary
        guard rect.width > 0, rect.height > 0 else { return nil }
        return CGRect(x: rect.minX / size.width,
                      y: rect.minY / size.height,
                      width: rect.width / size.width,
                      height: rect.height / size.height)
    }

    /// Готовый прямоугольник окна для текущего положения.
    private var currentPipRectFraction: CGRect? {
        pipRectFraction(for: pipOffset, in: previewSize)
    }

    /// Перетаскивание окна PiP (работает только в раскладке «картинка в картинке»).
    private var pipDrag: some Gesture {
        DragGesture()
            .onChanged { value in
                guard camera.layout == .pip else { return }
                if pipDragBase == nil {
                    pipDragBase = pipOffset
                }
                guard let base = pipDragBase else { return }
                let nextOffset = CGSize(width: base.width + value.translation.width,
                                        height: base.height + value.translation.height)
                pipOffset = nextOffset
                camera.updatePipOffsetFraction(pipOffsetFraction(for: nextOffset),
                                               rectFraction: pipRectFraction(for: nextOffset,
                                                                             in: previewSize))
            }
            .onEnded { _ in
                pipDragBase = nil
                camera.updatePipOffsetFraction(pipOffsetFraction,
                                               rectFraction: currentPipRectFraction)
            }
    }

    private var photoOverlayDrag: some Gesture {
        DragGesture()
            .onChanged { value in
                let base = photoOverlayDragBase ?? photoOverlayOffset
                photoOverlayDragBase = base
                photoOverlayOffset = CGSize(width: base.width + value.translation.width,
                                            height: base.height + value.translation.height)
                camera.updatePhotoOverlay(offsetFraction: photoOverlayOffsetFraction,
                                          widthFraction: importedImageWidthFraction)
            }
            .onEnded { _ in
                photoOverlayDragBase = nil
                camera.updatePhotoOverlay(offsetFraction: photoOverlayOffsetFraction,
                                          widthFraction: importedImageWidthFraction)
            }
    }

    private func focusTap(in size: CGSize,
                          origin: CGPoint,
                          target: VideoFilterTarget) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if focusGestureStartDate == nil { focusGestureStartDate = Date() }
            }
            .onEnded { value in
                let startDate = focusGestureStartDate ?? Date()
                focusGestureStartDate = nil
                let movement = hypot(value.translation.width, value.translation.height)
                guard size.width > 0, size.height > 0,
                      movement <= HUDTheme.focusTapMovementThreshold else { return }

                let localPoint = value.startLocation
                let layerPoint = previewLayer(for: target)
                    .captureDevicePointConverted(fromLayerPoint: localPoint)
                let viewPoint = CGPoint(x: origin.x + localPoint.x,
                                        y: origin.y + localPoint.y)
                let normalizedPoint = CGPoint(x: viewPoint.x / max(previewSize.width, 1),
                                              y: viewPoint.y / max(previewSize.height, 1))
                let shouldLock = Date().timeIntervalSince(startDate)
                    >= HUDTheme.focusLockLongPressDuration
                camera.selectFilterTarget(target)
                camera.focusAndExpose(at: layerPoint, target: target, lock: shouldLock) { didLock in
                    let marker = FocusIndicatorState(position: normalizedPoint,
                                                     target: target,
                                                     isLocked: didLock)
                    withAnimation(.easeInOut(duration: HUDTheme.stateTransitionDuration)) {
                        focusIndicator = marker
                    }
                    guard !didLock else { return }
                    scheduleFocusIndicatorHide(for: marker.id)
                }
            }
    }

    private func scheduleFocusIndicatorHide(for id: UUID) {
        focusHideWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            guard focusIndicator?.id == id else { return }
            withAnimation(.easeOut(duration: HUDTheme.stateTransitionDuration)) {
                focusIndicator = nil
            }
        }
        focusHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + HUDTheme.focusIndicatorDuration,
                                      execute: workItem)
    }

    private func previewLayer(for target: VideoFilterTarget) -> AVCaptureVideoPreviewLayer {
        let backIsTarget = target == .primary ? !camera.isCamerasSwapped : camera.isCamerasSwapped
        return backIsTarget ? camera.backPreviewLayer : camera.frontPreviewLayer
    }

    private func exposureBiasDrag(target: VideoFilterTarget) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // Пока палец на экране, индикатор фокуса не скрываем.
                focusHideWorkItem?.cancel()
                let startBias = exposureDragStartBias ?? camera.exposureTargetBias
                exposureDragStartBias = startBias
                let range = camera.maxExposureTargetBias - camera.minExposureTargetBias
                guard range > 0 else { return }
                let delta = Float(value.translation.height / HUDTheme.exposureSwipeTravel) * range
                let bias = min(max(startBias - delta,
                                   camera.minExposureTargetBias),
                               camera.maxExposureTargetBias)
                camera.setExposureTargetBias(bias, target: target)
            }
            .onEnded { _ in
                exposureDragStartBias = nil
                if let id = focusIndicator?.id {
                    scheduleFocusIndicatorHide(for: id)
                }
            }
    }

    private func exposureBiasLabel(_ value: Float) -> String {
        String(format: "%+.1f EV", Double(value))
    }

    /// Размер окна PiP в зависимости от выбранной формы.
    private static func pipSize(for shape: PipShape, in size: CGSize, widthFraction: CGFloat) -> CGSize {
        let width = min(size.width, size.height) * widthFraction
        return CGSize(width: width, height: width * shape.aspectRatio)
    }

    /// Считает прямоугольники основной и вторичной камер для выбранной раскладки.
    private static func layoutFrames(layout: CaptureLayout,
                                     size: CGSize,
                                     pipSize: CGSize,
                                     pipOffset: CGSize,
                                     pipTopInset: CGFloat,
                                     splitOrientation: SplitOrientation,
                                     splitRatio: CGFloat,
                                     isSecondaryCameraVisible: Bool) -> (main: CGRect, secondary: CGRect) {
        guard isSecondaryCameraVisible else {
            return (CGRect(origin: .zero, size: size), .zero)
        }
        switch layout {
        case .splitScreen:
            if splitOrientation == .vertical {
                let splitY = size.height * splitRatio
                return (
                    CGRect(x: 0, y: 0, width: size.width, height: splitY),
                    CGRect(x: 0, y: splitY, width: size.width, height: size.height - splitY)
                )
            } else {
                let splitX = size.width * splitRatio
                return (
                    CGRect(x: 0, y: 0, width: splitX, height: size.height),
                    CGRect(x: splitX, y: 0, width: size.width - splitX, height: size.height)
                )
            }
        case .pip:
            // Небольшой отступ, чтобы окно не прилипало вплотную к краю.
            let margin: CGFloat = 2
            let maxX = max(margin, size.width - pipSize.width - margin)
            let maxY = max(margin, size.height - pipSize.height - margin)
            let x = min(max(margin, 16 + pipOffset.width), maxX)
            let y = min(max(margin, pipTopInset + pipOffset.height), maxY)
            return (
                CGRect(origin: .zero, size: size),
                CGRect(x: x, y: y, width: pipSize.width, height: pipSize.height)
            )
        }
    }

    // MARK: - Управление

    private var controls: some View {
        GeometryReader { geometry in
            HUDOverlayView(
                size: geometry.size,
                safeTop: geometry.safeAreaInsets.top,
                isLandscape: isDeviceLandscape,
                isSettingsPresented: $isSettingsPresented,
                topControls: TopControlsView(
                    layout: $camera.layout,
                    splitOrientation: $camera.splitOrientation,
                    pipShape: $camera.pipShape,
                    isSecondaryCameraVisible: $camera.isSecondaryCameraVisible,
                    isDrawingEnabled: $drawing.isDrawingEnabled,
                    selectedMediaItems: $selectedMediaItems,
                    selectedFilter: Binding(
                        get: { camera.videoFilter },
                        set: { camera.selectVideoFilter($0) }
                    ),
                    pointerPosition: $pointerPosition,
                    hasImportedMedia: camera.hasImportedMedia,
                    isLandscape: isDeviceLandscape,
                    hapticsEnabled: settings.hapticsEnabled,
                    onClearImportedMedia: { camera.clearImportedMedia() }
                ),
                statusLabels: AnyView(statusLabels),
                filterLabel: AnyView(filterLabelView),
                hapticsEnabled: settings.hapticsEnabled,
                captureBar: CaptureBarView(
                    isLandscape: isDeviceLandscape,
                    hasTorch: camera.hasTorch,
                    isTorchOn: camera.isTorchOn,
                    isFrontLightOn: isFrontLightEnabled && isFrontLightAvailable,
                    isFrontLightAvailable: isFrontLightAvailable,
                    isRecording: camera.isRecording,
                    isCapturing: camera.isCapturing,
                    isApplyingSettings: camera.isApplyingSettings,
                    hapticsEnabled: settings.hapticsEnabled,
                    recordingDuration: durationString(camera.recordingDuration),
                    onToggleTorch: { camera.toggleTorch() },
                    onToggleFrontLight: {
                        withAnimation(.easeInOut(duration: HUDTheme.frontLightTransitionDuration)) {
                            isFrontLightEnabled.toggle()
                        }
                    },
                    onStopRecording: { camera.stopRecording(elements: mediaDrawingElements()) },
                    onCapturePhoto: {
                        camera.captureBothCameras(elements: mediaDrawingElements(),
                                                  pipOffsetFraction: pipOffsetFraction,
                                                  pipRectFraction: currentPipRectFraction,
                                                  photoOverlayOffsetFraction: photoOverlayOffsetFraction,
                                                  photoOverlayWidthFraction: importedImageWidthFraction)
                    },
                    onStartRecording: {
                        camera.startRecording(elements: mediaDrawingElements(),
                                              pipOffsetFraction: pipOffsetFraction,
                                              pipRectFraction: currentPipRectFraction,
                                              photoOverlayOffsetFraction: photoOverlayOffsetFraction,
                                              photoOverlayWidthFraction: importedImageWidthFraction)
                    },
                    onSwapCameras: { camera.swapCameras() }
                ),
                zoomControls: AnyView(zoomControls),
                drawingPalette: AnyView(
                    VStack(spacing: 8) {
                        if drawing.isDrawingEnabled {
                            DrawingPaletteView(engine: drawing, hapticsEnabled: settings.hapticsEnabled)
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                        }
                        if camera.importedPhoto != nil { importedPhotoSizeControl }
                    }
                )
            )
        }
    }

    private func durationString(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Интерфейс закреплён в портрете: по датчику поворачиваем только значки.
    private func updateDeviceOrientation() {
        switch UIDevice.current.orientation {
        case .landscapeLeft, .landscapeRight:
            isDeviceLandscape = true
        case .portrait, .portraitUpsideDown:
            isDeviceLandscape = false
        default:
            break
        }
    }

    private var statusLabels: some View {
        HStack(spacing: HUDTheme.statusLabelsSpacing) {
            Text(settings.resolution.rawValue)
            Text("\(settings.frameRate.rawValue) FPS")
            Text(settings.audioQuality == .aac ? "AAC" : "Lossless")
            if camera.isFocusExposureLocked {
                Text("AE/AF LOCK")
                    .foregroundStyle(HUDTheme.yellow)
            }
        }
        .font(.system(size: HUDTheme.zoomPresetFontSize, weight: .medium))
        .foregroundStyle(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .accessibilityElement(children: .combine)
    }

    private var filterLabelView: some View {
        Text(camera.videoFilter.title)
            .font(.system(size: HUDTheme.filterLabelFontSize))
            .foregroundStyle(.white)
            .lineLimit(1)
            .frame(maxWidth: HUDTheme.filterLabelMaximumWidth)
            .opacity(isFilterLabelVisible ? 1 : 0)
            .animation(.easeOut(duration: HUDTheme.stateTransitionDuration), value: isFilterLabelVisible)
            .accessibilityLabel("Фильтр: \(camera.videoFilter.title)")
            .allowsHitTesting(false)
    }

    /// Название фильтра показываем только в момент выбора и затем скрываем.
    private func showFilterLabelTemporarily() {
        filterLabelHideWorkItem?.cancel()
        withAnimation(.easeIn(duration: HUDTheme.stateTransitionDuration)) {
            isFilterLabelVisible = true
        }
        let workItem = DispatchWorkItem {
            withAnimation(.easeOut(duration: HUDTheme.stateTransitionDuration)) {
                isFilterLabelVisible = false
            }
        }
        filterLabelHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + HUDTheme.filterLabelVisibleDuration,
                                      execute: workItem)
    }

    private func dateTimeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func mediaDrawingElements(includeDraft: Bool = false) -> [DrawingElement] {
        var elements = includeDraft ? drawing.elementsIncludingDraft : drawing.elements
        if let pointerPosition {
            elements.append(contentsOf: pointerDrawingElements(at: pointerPosition))
        }
        return elements
    }

    private func pointerDrawingElements(at center: CGPoint) -> [DrawingElement] {
        guard previewSize.width > 0, previewSize.height > 0 else { return [] }
        // Рука должна остаться квадратной в готовом файле, поэтому по
        // вертикали пересчитываем масштаб через пропорции выходного кадра.
        let outputSize = settings.snapshot.outputSize(isPortrait: camera.isPortrait)
        let unitWidth = HUDTheme.pointerMarkerSize / previewSize.width
        let unitHeight = outputSize.height > 0
            ? unitWidth * (outputSize.width / outputSize.height)
            : unitWidth
        let lineWidth = HUDTheme.lineWidth / previewSize.width
        let shapePath = PointingHandShape()
            .path(in: CGRect(x: 0, y: 0, width: 1, height: 1))
            .cgPath
        return shapePath.flattenedPolylines().compactMap { polyline in
            guard polyline.count > 1 else { return nil }
            let points = polyline.map { point in
                CGPoint(x: center.x + (point.x - 0.5) * unitWidth,
                        y: center.y + (point.y - 0.5) * unitHeight)
            }
            return DrawingElement(kind: .stroke(points: points), color: .red, lineWidth: lineWidth)
        }
    }

    // MARK: - Импорт медиа

    private func handlePickedMedia(_ items: [PhotosPickerItem]) {
        guard let item = items.first else { return }
        Task {
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                if let movie = try? await item.loadTransferable(type: ImportedMovie.self) {
                    camera.setImportedVideo(movie.url)
                }
            } else if let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) {
                camera.setImportedPhoto(image)
            }
        }
    }

    // MARK: - Зум и фонарик

    private var zoomControls: some View {
        ZoomControlView(zoomFactor: camera.zoomFactor,
                        minimumZoomFactor: camera.minZoomFactor,
                        maximumZoomFactor: camera.maxZoomFactor,
                        isExpanded: $isZoomSliderVisible,
                        showsHalfPreset: camera.hasUltraWideBackCamera,
                        isLandscape: isDeviceLandscape,
                        hapticsEnabled: settings.hapticsEnabled,
                        onZoomChanged: { camera.setZoom($0) },
                        onZoomCommitted: { camera.commitZoom() })
    }

    private var importedPhotoSizeControl: some View {
        HStack(spacing: 8) {
            Text("Размер фото")
                .font(.caption)
                .foregroundStyle(.white)
            Slider(value: $importedImageWidthFraction, in: 0.15...0.6)
                .tint(.white)
                .frame(width: 120)
            Text("\(Int(importedImageWidthFraction * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(HUDTheme.glass, in: Capsule())
        .onChange(of: importedImageWidthFraction) { _, newValue in
            camera.updatePhotoOverlay(offsetFraction: photoOverlayOffsetFraction,
                                      widthFraction: newValue)
        }
    }

    private var isFrontLightAvailable: Bool {
        camera.isConfigured
            && camera.importedVideoURL == nil
            && (camera.isSecondaryCameraVisible || camera.isCamerasSwapped)
    }

    private func pointerDrag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard size.width > 0, size.height > 0 else { return }
                let start = pointerDragBase ?? pointerPosition ?? CGPoint(x: 0.5, y: 0.5)
                pointerDragBase = start
                let insetX = HUDTheme.pointerMarkerEdgeInset / size.width
                let insetY = HUDTheme.pointerMarkerEdgeInset / size.height
                pointerPosition = CGPoint(
                    x: min(max(start.x + value.translation.width / size.width, insetX), 1 - insetX),
                    y: min(max(start.y + value.translation.height / size.height, insetY), 1 - insetY)
                )
            }
            .onEnded { _ in pointerDragBase = nil }
    }

    // MARK: - Биндинги для алертов и листа

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { camera.errorMessage != nil },
            set: { if !$0 { camera.clearError() } }
        )
    }

    private var mergedPhotoBinding: Binding<Bool> {
        Binding(
            get: { camera.lastMergedPhoto != nil },
            set: { if !$0 { camera.clearMergedPhoto() } }
        )
    }

    private var mergedVideoBinding: Binding<Bool> {
        Binding(
            get: { camera.lastMergedVideoURL != nil },
            set: { if !$0 { camera.clearMergedVideo() } }
        )
    }
}

private struct FocusIndicatorState: Identifiable {
    let id = UUID()
    let position: CGPoint
    let target: VideoFilterTarget
    let isLocked: Bool
}

private struct SecondaryPreviewClip: ViewModifier {
    let layout: CaptureLayout
    let radius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if layout == .pip && radius > 0 {
            content.clipShape(AnimatableRoundedRectangle(radius: radius))
        } else {
            content
        }
    }
}

/// Экран результата: показывает склеенный снимок и позволяет сохранить его.
struct MergedPhotoView: View {
    let photo: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var saveErrorMessage: String?

    var body: some View {
        NavigationStack {
            VStack {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFit()
                    .padding()
                Button("Сохранить в Фото") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
            .navigationTitle("Снимок")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .alert("Ошибка сохранения", isPresented: saveErrorBinding) {
                Button("ОК", role: .cancel) {}
            } message: {
                Text(saveErrorMessage ?? "")
            }
        }
    }

    private var saveErrorBinding: Binding<Bool> {
        Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )
    }

    private func save() {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    saveErrorMessage = "Нет доступа к медиатеке. Разрешите доступ в настройках."
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: photo)
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    if success {
                        dismiss()
                    } else {
                        saveErrorMessage = error?.localizedDescription ?? "Не удалось сохранить фото."
                    }
                }
            }
        }
    }
}

/// Прямоугольник со скруглением, который умеет плавно анимировать радиус.
struct AnimatableRoundedRectangle: Shape {
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
    }
}

/// Медиафайл для импорта через `PhotosPicker`.
struct ImportedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = URL.documentsDirectory.appendingPathComponent("imported-\(UUID().uuidString).mov")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}
