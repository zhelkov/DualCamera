import SwiftUI
import Photos
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var camera = CameraManager()
    @State private var settings = CameraSettings()
    @Environment(\.scenePhase) private var scenePhase
    @State private var pipOffset: CGSize = .zero
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
            .onChange(of: drawing.elements) { _, elements in
                camera.updateRecordingElements(elements)
            }
            .onChange(of: drawing.draftElement) { _, _ in
                camera.updateRecordingElements(drawing.elementsIncludingDraft)
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
    }

    private var lifecycleView: some View {
        cameraScene
            .ignoresSafeArea()
            .task {
                camera.applyCaptureSettings(settings.snapshot)
                await camera.requestAccessAndSetup()
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
            let isLandscape = geometry.size.width > geometry.size.height
            let topStripHeight = max(HUDTheme.topStripMinimumHeight,
                                     geometry.safeAreaInsets.top + HUDTheme.topSafeAreaAddition)
            let bottomStripHeight = isLandscape
                ? HUDTheme.landscapeBottomStripMinimumHeight
                : HUDTheme.bottomStripMinimumHeight
            let previewRect = CGRect(x: 0,
                                     y: topStripHeight,
                                     width: geometry.size.width,
                                     height: max(0, geometry.size.height - topStripHeight - bottomStripHeight))
            let isPortrait = !isLandscape
            let aspectRatio = settings.aspectRatio.ratio(isPortrait: isPortrait)
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
                        Text(context.date, format: .dateTime.year().month().day().hour().minute().second())
                            .font(.system(size: HUDTheme.cameraDateTimeFontSize,
                                          weight: .medium, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, HUDTheme.cameraOverlayHorizontalPadding)
                            .padding(.vertical, HUDTheme.cameraOverlayVerticalPadding)
                            .background(Color.black.opacity(0.56), in: Capsule())
                            .position(x: guideRect.midX,
                                      y: guideRect.maxY - HUDTheme.cameraDateTimeBottomInset)
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
    }

    private var pointerMarkerOverlay: some View {
        GeometryReader { geometry in
            if let pointerPosition {
                PointerMarkerView(color: drawing.selectedColor.color)
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

    // MARK: - Превью

    @ViewBuilder
    private var previewStack: some View {
        GeometryReader { geo in
            let size = geo.size
            let backIsMain = !camera.isCamerasSwapped
            let pip = Self.pipSize(for: camera.pipShape, in: size, widthFraction: 0.3)
            let frames = Self.layoutFrames(layout: camera.layout, size: size, pipSize: pip,
                                           pipOffset: pipOffset,
                                           splitOrientation: camera.splitOrientation,
                                           splitRatio: camera.splitRatio,
                                           isSecondaryCameraVisible: camera.isSecondaryCameraVisible)
            let pipRadius = camera.pipShape.cornerRadius(for: pip)

            ZStack(alignment: .topLeading) {
                if backIsMain {
                    backCameraContent
                        .frame(width: frames.main.width, height: frames.main.height)
                        .offset(x: frames.main.minX, y: frames.main.minY)
                        .gesture(focusTap(in: frames.main.size, target: .primary))

                    if camera.isSecondaryCameraVisible {
                        frontCameraContent
                            .frame(width: frames.secondary.width, height: frames.secondary.height)
                            .modifier(SecondaryPreviewClip(layout: camera.layout, radius: pipRadius))
                            .offset(x: frames.secondary.minX, y: frames.secondary.minY)
                            .gesture(pipDrag)
                            .simultaneousGesture(SpatialTapGesture().onEnded { _ in
                                camera.selectFilterTarget(.secondary)
                            })
                    }
                } else {
                    frontCameraContent
                        .frame(width: frames.main.width, height: frames.main.height)
                        .offset(x: frames.main.minX, y: frames.main.minY)
                        .gesture(focusTap(in: frames.main.size, target: .primary))

                    if camera.isSecondaryCameraVisible {
                        backCameraContent
                            .frame(width: frames.secondary.width, height: frames.secondary.height)
                            .modifier(SecondaryPreviewClip(layout: camera.layout, radius: pipRadius))
                            .offset(x: frames.secondary.minX, y: frames.secondary.minY)
                            .gesture(pipDrag)
                            .simultaneousGesture(SpatialTapGesture().onEnded { _ in
                                camera.selectFilterTarget(.secondary)
                            })
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

                if camera.videoFilter != .original
                    && (camera.activeFilterTarget == .primary || camera.isSecondaryCameraVisible) {
                    let labelFrame = camera.activeFilterTarget == .primary
                        ? frames.main
                        : frames.secondary
                    Text(camera.videoFilter.title)
                        .font(.system(size: HUDTheme.filterLabelFontSize))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: HUDTheme.filterLabelMaximumWidth)
                        .padding(.horizontal, HUDTheme.filterLabelHorizontalPadding)
                        .padding(.vertical, HUDTheme.filterLabelVerticalPadding)
                        .background(Color.black.opacity(0.56), in: Capsule())
                        .position(x: labelFrame.midX,
                                  y: labelFrame.maxY - HUDTheme.filterLabelYOffset)
                        .accessibilityLabel("Фильтр: \(camera.videoFilter.title)")
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: camera.layout)
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: camera.isCamerasSwapped)
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: camera.pipShape)
            .animation(.easeInOut(duration: HUDTheme.stateTransitionDuration),
                       value: camera.isSecondaryCameraVisible)
            .onAppear { previewSize = size }
            .onChange(of: size) { _, newSize in previewSize = newSize }
        }
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

    private func pipOffsetFraction(for offset: CGSize) -> CGSize {
        guard previewSize.width > 0, previewSize.height > 0 else { return .zero }
        return CGSize(width: offset.width / previewSize.width,
                      height: offset.height / previewSize.height)
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
                camera.updatePipOffsetFraction(pipOffsetFraction(for: nextOffset))
            }
            .onEnded { _ in
                pipDragBase = nil
                camera.updatePipOffsetFraction(pipOffsetFraction)
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

    /// Фокус и экспозиция по касанию основной камеры.
    private func focusTap(in size: CGSize, target: VideoFilterTarget) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard size.width > 0, size.height > 0 else { return }
                camera.selectFilterTarget(target)
                let point = CGPoint(x: value.location.x / size.width,
                                    y: value.location.y / size.height)
                camera.focusAndExpose(at: point)
            }
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
            let inset: CGFloat = 16
            let maxX = max(0, size.width - pipSize.width)
            let maxY = max(0, size.height - pipSize.height)
            let x = min(max(0, size.width - pipSize.width - inset + pipOffset.width), maxX)
            let y = min(max(0, size.height - pipSize.height - inset + pipOffset.height), maxY)
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
                isLandscape: geometry.size.width > geometry.size.height,
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
                    isLandscape: geometry.size.width > geometry.size.height,
                    onClearImportedMedia: { camera.clearImportedMedia() }
                ),
                captureBar: CaptureBarView(
                    isLandscape: geometry.size.width > geometry.size.height,
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
                    onStopRecording: { camera.stopRecording(elements: drawing.elements) },
                    onCapturePhoto: {
                        camera.captureBothCameras(elements: drawing.elements,
                                                  pipOffsetFraction: pipOffsetFraction,
                                                  photoOverlayOffsetFraction: photoOverlayOffsetFraction,
                                                  photoOverlayWidthFraction: importedImageWidthFraction)
                    },
                    onStartRecording: {
                        camera.startRecording(elements: drawing.elements,
                                              pipOffsetFraction: pipOffsetFraction,
                                              photoOverlayOffsetFraction: photoOverlayOffsetFraction,
                                              photoOverlayWidthFraction: importedImageWidthFraction)
                    },
                    onSwapCameras: { camera.swapCameras() }
                ),
                zoomControls: AnyView(zoomControls),
                drawingPalette: AnyView(
                    VStack(spacing: 8) {
                        if drawing.isDrawingEnabled {
                            DrawingPaletteView(engine: drawing)
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
                        onZoomChanged: { camera.setZoom($0) })
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
