import SwiftUI
import AVFoundation
import Combine
import Photos
import PhotosUI
import CoreTransferable
import UIKit
import UniformTypeIdentifiers

/// Угол рамки кадра, в который паркуется окно PiP при повороте.
enum PipParkCorner {
    case topLeading
    case topTrailing
    case bottomLeading
}

struct ContentView: View {
    @State private var camera = CameraManager()
    @State private var settings = CameraSettings()
    @Environment(\.scenePhase) private var scenePhase
    @State private var pipOffset: CGSize = .zero
    /// Размер родительского поля кадра — окно PiP паркуется от его границ.
    @State private var pipFieldSize: CGSize = .zero
    @State private var photoOverlayOffset: CGSize = .zero
    @State private var previewSize: CGSize = .zero
    @State private var importedImageWidthFraction: CGFloat = 0.3
    /// Увеличение картинки внутри полотна вставленного фото.
    @State private var importedPhotoInnerScale: CGFloat = 1
    /// Смещение картинки внутри полотна (в точках превью).
    @State private var importedPhotoInnerOffset: CGSize = .zero
    @State private var importedPhotoOpacity: Double = 1
    @State private var isPhotoControlsVisible = false
    @State private var photoInnerDragBase: CGSize?
    @State private var photoHoldWorkItem: DispatchWorkItem?
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
    /// Ориентация устройства по датчику — нужна, чтобы понять,
    /// какой угол кадра пользователь видит верхним левым.
    @State private var deviceOrientation: UIDeviceOrientation = .portrait
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
                                  hasImportedMedia: camera.importedVideoURL != nil,
                                  geometryDiagnostics: camera.geometryDiagnostics)
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
            .onChange(of: camera.importedPhoto != nil) { _, hasPhoto in
                isPhotoControlsVisible = false
                importedPhotoInnerScale = 1
                importedPhotoInnerOffset = .zero
                importedPhotoOpacity = 1
                photoOverlayDragBase = nil
                photoInnerDragBase = nil
                if !hasPhoto { photoOverlayOffset = .zero }
            }
            .onChange(of: settings.aspectRatio) { _, _ in
                // Сменился формат кадра: окно PiP снова паркуется в угол,
                // иначе прежнее смещение выводит его за границы кадра.
                pipDragBase = nil
                pipOffset = .zero
                camera.updatePipOffsetFraction(mediaPipOffsetFraction(for: .zero))
            }
            .onDisappear { camera.stopRunning() }
            .onChange(of: isDeviceLandscape) { _, _ in
                // Поворот экрана: окно PiP всегда возвращается
                // в парковочное место в левом верхнем углу кадра.
                pipDragBase = nil
                pipOffset = .zero
                camera.updatePipOffsetFraction(mediaPipOffsetFraction(for: .zero))
            }
            .onChange(of: deviceOrientation) { _, _ in
                // Поворот на 180° в ландшафте меняет угол, который виден
                // пользователю верхним левым.
                pipDragBase = nil
                pipOffset = .zero
                camera.updatePipOffsetFraction(mediaPipOffsetFraction(for: .zero))
            }
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
                // Аудиосессия записи глушит мотор: пересоздаём движок
                // в новом окружении, иначе во время записи тиков нет.
                Haptics.audioSessionDidChange()
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
            let previewRect = CGRect(x: 0,
                                     y: topStripHeight,
                                     width: geometry.size.width,
                                     height: max(0, geometry.size.height - topStripHeight - HUDTheme.bottomStripMinimumHeight))
            let aspectRatio = settings.aspectRatio.ratio(isPortrait: true)
            let guideWidth = min(previewRect.width, previewRect.height * aspectRatio)
            let guideHeight = guideWidth / max(aspectRatio, 0.0001)
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
            // Родительское поле кадра: та же рамка, что задаёт формат кадра
            // в настройках. Окно PiP живёт внутри неё, поэтому положение
            // на экране совпадает с положением в готовом файле.
            let fieldRect = Self.frameRect(in: size,
                                           safeInsets: geo.safeAreaInsets,
                                           aspectRatio: settings.aspectRatio.ratio(isPortrait: true))
            // Размер самой картинки PiP (портретный) и размер её окна на экране.
            // В ландшафте окно повёрнуто на 90°, поэтому стороны меняются местами,
            // иначе повёрнутый прямоугольник обрезается.
            let pipContentSize = Self.pipSize(for: camera.pipShape, in: fieldRect.size, widthFraction: 0.3)
            let pipSlotSize = isDeviceLandscape
                ? CGSize(width: pipContentSize.height, height: pipContentSize.width)
                : pipContentSize
            // В сплит-режиме вторичное окно — это ячейка сплита, а не PiP.
            let isPipLayout = camera.layout == .pip
            let secondaryContentSize = isPipLayout ? pipContentSize : .zero
            let frames = Self.layoutFrames(layout: camera.layout, size: size, pipSize: pipSlotSize,
                                           pipOffset: pipOffset,
                                           pipBounds: fieldRect,
                                           parkCorner: pipParkCorner,
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
                    photoOverlayView(photo, frame: frame)
                        .gesture(photoOverlayDrag)
                }

                if camera.layout == .splitScreen && camera.isSecondaryCameraVisible {
                    SplitDividerView(orientation: camera.splitOrientation,
                                     ratio: camera.splitRatio) { ratio in
                        camera.splitRatio = ratio
                    }
                    .frame(width: size.width, height: size.height)
                }

                // Рисунок — самый верхний слой, а его область совпадает
                // с рамкой кадра, поэтому координаты совпадают с файлом.
                DrawingCanvas(engine: drawing)
                    .frame(width: fieldRect.width, height: fieldRect.height)
                    .offset(x: fieldRect.minX, y: fieldRect.minY)
                    .allowsHitTesting(drawing.isDrawingEnabled)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: camera.layout)
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: camera.isCamerasSwapped)
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: camera.pipShape)
            .animation(.easeInOut(duration: 0.25), value: pipOffset)
            .animation(.easeInOut(duration: 0.25), value: deviceOrientation)
            .animation(.easeInOut(duration: HUDTheme.stateTransitionDuration),
                       value: camera.isSecondaryCameraVisible)
            .onAppear {
                previewSize = size
                pipFieldSize = fieldRect.size
            }
            .onChange(of: size) { _, newSize in
                previewSize = newSize
                pipFieldSize = fieldRect.size
            }
            .onChange(of: fieldRect) { _, newRect in
                pipFieldSize = newRect.size
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
            if let image = camera.lensSwitchSnapshot {
                FilteredCameraPreviewView(image: image, isMirrored: false)
            } else if let image = camera.backFilteredPreviewImage {
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

    private var photoOverlayOffsetFraction: CGSize {
        guard previewSize.width > 0, previewSize.height > 0,
              let photo = camera.importedPhoto else { return .zero }
        // Доля кадра для левого верхнего угла полотна: берём фактическое
        // положение в превью, чтобы файл совпал с экраном.
        let frame = photoOverlayFrame(for: photo, in: previewSize)
        return CGSize(width: frame.minX / previewSize.width,
                      height: frame.minY / previewSize.height)
    }

    private func photoOverlayFrame(for image: UIImage, in size: CGSize) -> CGRect {
        let width = size.width * min(max(importedImageWidthFraction, 0.05), 1)
        let height = width * image.size.height / max(image.size.width, 1)
        // По умолчанию полотно стоит по центру кадра, перетаскивание — смещение от центра.
        let x = min(max(0, (size.width - width) / 2 + photoOverlayOffset.width),
                    max(0, size.width - width))
        let y = min(max(0, (size.height - height) / 2 + photoOverlayOffset.height),
                    max(0, size.height - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Полотно фото: неизменные границы, внутри — увеличенная и сдвинутая картинка.
    private func photoOverlayView(_ photo: UIImage, frame: CGRect) -> some View {
        let zoom = max(importedPhotoInnerScale, 1)
        let innerWidth = frame.width * zoom
        let innerHeight = frame.height * zoom
        let fillScale = max(innerWidth / max(photo.size.width, 1),
                            innerHeight / max(photo.size.height, 1))
        let contentSize = CGSize(width: photo.size.width * fillScale,
                                 height: photo.size.height * fillScale)
        return ZStack {
            Image(uiImage: photo)
                .resizable()
                .frame(width: contentSize.width, height: contentSize.height)
                .offset(x: importedPhotoInnerOffset.width, y: importedPhotoInnerOffset.height)
        }
        .frame(width: frame.width, height: frame.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white, lineWidth: 2))
        .shadow(color: .black.opacity(0.35), radius: 5)
        .opacity(importedPhotoOpacity)
        .offset(x: frame.minX, y: frame.minY)
    }

    private func offsetFraction(for offset: CGSize) -> CGSize {
        guard previewSize.width > 0, previewSize.height > 0 else { return .zero }
        return CGSize(width: offset.width / previewSize.width,
                      height: offset.height / previewSize.height)
    }

    /// Доля кадра, в которой находится левый верхний угол окна PiP.
    /// Отсчитываем от парковочного отступа внутри родительского поля,
    /// поэтому экран и готовый файл совпадают.
    private func pipOffsetFraction(for offset: CGSize) -> CGSize {
        guard pipFieldSize.width > 0, pipFieldSize.height > 0 else { return .zero }
        return CGSize(width: (HUDTheme.pipParkInset + offset.width) / pipFieldSize.width,
                      height: (HUDTheme.pipParkInset + offset.height) / pipFieldSize.height)
    }

    /// Доля для записи и фото. Положение берём как есть: окно должно
    /// оказаться в том же углу, что и в превью.
    private func mediaPipOffsetFraction(for offset: CGSize) -> CGSize {
        pipOffsetFraction(for: offset)
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
                camera.updatePipOffsetFraction(mediaPipOffsetFraction(for: nextOffset))
            }
            .onEnded { _ in
                pipDragBase = nil
                camera.updatePipOffsetFraction(mediaPipOffsetFraction(for: pipOffset))
            }
    }

    /// Не даёт утащить картинку так, чтобы внутри полотна появился её край.
    private func clampPhotoInnerOffset(_ offset: CGSize, photo: UIImage?) -> CGSize {
        guard let photo, previewSize.width > 0, previewSize.height > 0 else { return offset }
        let frame = photoOverlayFrame(for: photo, in: previewSize)
        let zoom = max(importedPhotoInnerScale, 1)
        let innerWidth = frame.width * zoom
        let innerHeight = frame.height * zoom
        let fillScale = max(innerWidth / max(photo.size.width, 1),
                            innerHeight / max(photo.size.height, 1))
        let contentWidth = photo.size.width * fillScale
        let contentHeight = photo.size.height * fillScale
        let maxX = max(0, (contentWidth - frame.width) / 2)
        let maxY = max(0, (contentHeight - frame.height) / 2)
        return CGSize(width: min(max(offset.width, -maxX), maxX),
                      height: min(max(offset.height, -maxY), maxY))
    }

    private var photoOverlayDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // Первое касание запускает таймер удержания: меню появляется
                // по времени, не дожидаясь, пока палец отпустят.
                if photoHoldWorkItem == nil, photoInnerDragBase == nil, photoOverlayDragBase == nil {
                    schedulePhotoLongPress()
                }
                if abs(value.translation.width) > 6 || abs(value.translation.height) > 6 {
                    photoHoldWorkItem?.cancel()
                    photoHoldWorkItem = nil
                }
                // При увеличенной картинке тянем её внутри полотна,
                // иначе перемещаем само полотно.
                if importedPhotoInnerScale > 1.01 {
                    let base = photoInnerDragBase ?? importedPhotoInnerOffset
                    photoInnerDragBase = base
                    importedPhotoInnerOffset = clampPhotoInnerOffset(
                        CGSize(width: base.width + value.translation.width,
                               height: base.height + value.translation.height),
                        photo: camera.importedPhoto)
                } else {
                    let base = photoOverlayDragBase ?? photoOverlayOffset
                    photoOverlayDragBase = base
                    photoOverlayOffset = CGSize(width: base.width + value.translation.width,
                                                height: base.height + value.translation.height)
                }
                pushPhotoOverlayToCamera()
            }
            .onEnded { _ in
                photoHoldWorkItem?.cancel()
                photoHoldWorkItem = nil
                photoOverlayDragBase = nil
                photoInnerDragBase = nil
                pushPhotoOverlayToCamera()
            }
    }

    /// Показывает меню настроек фото через время удержания, не дожидаясь
    /// отпускания пальца.
    private func schedulePhotoLongPress() {
        let workItem = DispatchWorkItem {
            Haptics.selection()
            withAnimation(.easeInOut(duration: HUDTheme.stateTransitionDuration)) {
                isPhotoControlsVisible.toggle()
            }
            photoHoldWorkItem = nil
        }
        photoHoldWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    /// Передаёт настройки фото в запись: смещение полотна и картинки,
    /// увеличение внутри полотна и прозрачность.
    private func pushPhotoOverlayToCamera() {
        camera.updatePhotoOverlay(offsetFraction: photoOverlayOffsetFraction,
                                  widthFraction: importedImageWidthFraction,
                                  innerScale: importedPhotoInnerScale,
                                  innerOffsetFraction: importedPhotoInnerOffsetFraction,
                                  opacity: CGFloat(importedPhotoOpacity))
    }

    private var importedPhotoInnerOffsetFraction: CGSize {
        guard previewSize.width > 0, previewSize.height > 0 else { return .zero }
        return CGSize(width: importedPhotoInnerOffset.width / previewSize.width,
                      height: importedPhotoInnerOffset.height / previewSize.height)
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

    /// Прямоугольник родительского поля кадра в координатах превью:
    /// область между полосами HUD, вписанная в выбранный формат кадра.
    private static func frameRect(in size: CGSize,
                                  safeInsets: EdgeInsets,
                                  aspectRatio: CGFloat) -> CGRect {
        let topStripHeight = max(HUDTheme.topStripMinimumHeight,
                                 safeInsets.top + HUDTheme.topSafeAreaAddition)
        let previewRect = CGRect(x: 0,
                                 y: topStripHeight,
                                 width: size.width,
                                 height: max(0, size.height - topStripHeight - HUDTheme.bottomStripMinimumHeight))
        let width = min(previewRect.width, previewRect.height * aspectRatio)
        let height = width / max(aspectRatio, 0.0001)
        return CGRect(x: previewRect.minX + (previewRect.width - width) / 2,
                      y: previewRect.minY + (previewRect.height - height) / 2,
                      width: width,
                      height: height)
    }

    /// Считает прямоугольники основной и вторичной камер для выбранной раскладки.
    private static func layoutFrames(layout: CaptureLayout,
                                     size: CGSize,
                                     pipSize: CGSize,
                                     pipOffset: CGSize,
                                     pipBounds: CGRect,
                                     parkCorner: PipParkCorner,
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
            // Парковка — в тот угол кадра, который пользователь видит верхним левым.
            let inset = HUDTheme.pipParkInset
            let minX = pipBounds.minX + inset
            let minY = pipBounds.minY + inset
            let maxX = max(minX, pipBounds.maxX - pipSize.width - inset)
            let maxY = max(minY, pipBounds.maxY - pipSize.height - inset)
            let parkX: CGFloat
            let parkY: CGFloat
            switch parkCorner {
            case .topLeading:
                parkX = minX
                parkY = minY
            case .topTrailing:
                parkX = maxX
                parkY = minY
            case .bottomLeading:
                parkX = minX
                parkY = maxY
            }
            let x = min(max(minX, parkX + pipOffset.width), maxX)
            let y = min(max(minY, parkY + pipOffset.height), maxY)
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
                                                  pipOffsetFraction: mediaPipOffsetFraction(for: pipOffset),
                                                  photoOverlayOffsetFraction: photoOverlayOffsetFraction,
                                                  photoOverlayWidthFraction: importedImageWidthFraction,
                                                  photoOverlayInnerScale: importedPhotoInnerScale,
                                                  photoOverlayInnerOffsetFraction: importedPhotoInnerOffsetFraction,
                                                  photoOverlayOpacity: CGFloat(importedPhotoOpacity))
                    },
                    onStartRecording: {
                        camera.startRecording(elements: mediaDrawingElements(),
                                              pipOffsetFraction: mediaPipOffsetFraction(for: pipOffset),
                                              photoOverlayOffsetFraction: photoOverlayOffsetFraction,
                                              photoOverlayWidthFraction: importedImageWidthFraction,
                                              photoOverlayInnerScale: importedPhotoInnerScale,
                                              photoOverlayInnerOffsetFraction: importedPhotoInnerOffsetFraction,
                                              photoOverlayOpacity: CGFloat(importedPhotoOpacity))
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
                        if camera.importedPhoto != nil && isPhotoControlsVisible {
                            importedPhotoSizeControl
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                        }
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
        deviceOrientation = UIDevice.current.orientation
        switch UIDevice.current.orientation {
        case .landscapeLeft, .landscapeRight:
            isDeviceLandscape = true
        case .portrait, .portraitUpsideDown:
            isDeviceLandscape = false
        default:
            break
        }
    }

    /// Угол окна, который пользователь видит верхним левым.
    /// Экран закреплён в портрете, поэтому в ландшафте «верхний левый»
    /// на экране оказывается другим углом рамки кадра:
    /// кнопка «Домой» справа → верхний правый угол экрана,
    /// кнопка «Домой» слева → нижний левый угол экрана.
    private var pipParkCorner: PipParkCorner {
        switch deviceOrientation {
        case .landscapeLeft: return .topTrailing
        case .landscapeRight: return .bottomLeading
        default: return .topLeading
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
        VStack(spacing: 6) {
            photoSliderRow(title: "Полотно",
                           value: Binding(get: { Double(importedImageWidthFraction) },
                                          set: { newValue in
                                              importedImageWidthFraction = CGFloat(newValue)
                                              reclampPhotoInnerOffset()
                                          }),
                           range: 0.05...1.0,
                           display: "\(Int(importedImageWidthFraction * 100))%")
            photoSliderRow(title: "Фото",
                           value: Binding(get: { Double(importedPhotoInnerScale) },
                                          set: { newValue in
                                              importedPhotoInnerScale = CGFloat(newValue)
                                              importedPhotoInnerOffset = clampPhotoInnerOffset(
                                                  importedPhotoInnerOffset,
                                                  photo: camera.importedPhoto)
                                          }),
                           range: 1...4,
                           display: String(format: "%.1f×", importedPhotoInnerScale))
            photoSliderRow(title: "Прозрачность",
                           value: $importedPhotoOpacity,
                           range: 0.1...1.0,
                           display: "\(Int(importedPhotoOpacity * 100))%")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(HUDTheme.glass, in: RoundedRectangle(cornerRadius: 16))
    }

    private func photoSliderRow(title: String,
                                value: Binding<Double>,
                                range: ClosedRange<Double>,
                                display: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white)
                .frame(width: 82, alignment: .leading)
            Slider(value: value, in: range)
                .tint(.white)
                .frame(width: 130)
            Text(display)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 40, alignment: .trailing)
        }
        .onChange(of: value.wrappedValue) { _, _ in
            pushPhotoOverlayToCamera()
        }
    }

    /// При изменении размера полотна картинка остаётся на месте:
    /// смещение пересчитывается под новые границы.
    private func reclampPhotoInnerOffset() {
        importedPhotoInnerOffset = clampPhotoInnerOffset(importedPhotoInnerOffset,
                                                         photo: camera.importedPhoto)
        pushPhotoOverlayToCamera()
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
