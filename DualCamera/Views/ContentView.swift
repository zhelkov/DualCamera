import SwiftUI
import Photos
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var camera = CameraManager()
    @Environment(\.scenePhase) private var scenePhase
    @State private var pipOffset: CGSize = .zero
    @State private var photoOverlayOffset: CGSize = .zero
    @State private var previewSize: CGSize = .zero
    @State private var importedImageWidthFraction: CGFloat = 0.3
    @State private var pipDragBase: CGSize?
    @State private var photoOverlayDragBase: CGSize?
    @State private var isZoomSliderVisible = false
    @State private var drawing = DrawingEngine()
    @State private var selectedMediaItems: [PhotosPickerItem] = []

    var body: some View {
        @Bindable var camera = camera
        ZStack {
            previewStack
            DrawingCanvas(engine: drawing)
                .allowsHitTesting(drawing.isDrawingEnabled)
            controls
        }
        .ignoresSafeArea()
        .task { await camera.requestAccessAndSetup() }
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
        .onChange(of: drawing.elements) { _, elements in
            camera.updateRecordingElements(elements)
        }
        .onChange(of: drawing.draftElement) { _, _ in
            camera.updateRecordingElements(drawing.elementsIncludingDraft)
        }
        .onChange(of: camera.layout) { _, _ in
            camera.updateRecordingLayout(layout: camera.layout,
                                         shape: camera.pipShape,
                                         splitOrientation: camera.splitOrientation)
        }
        .onChange(of: camera.pipShape) { _, _ in
            camera.updateRecordingLayout(layout: camera.layout,
                                         shape: camera.pipShape,
                                         splitOrientation: camera.splitOrientation)
        }
        .onChange(of: camera.splitOrientation) { _, _ in
            camera.updateRecordingLayout(layout: camera.layout,
                                         shape: camera.pipShape,
                                         splitOrientation: camera.splitOrientation)
        }
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
    }

    // MARK: - Превью

    @ViewBuilder
    private var previewStack: some View {
        GeometryReader { geo in
            let size = geo.size
            let backIsMain = !camera.isCamerasSwapped
            let pip = Self.pipSize(for: camera.pipShape, in: size, widthFraction: 0.3)
            let frames = Self.layoutFrames(layout: camera.layout, size: size, pipSize: pip, pipOffset: pipOffset, splitOrientation: camera.splitOrientation)
            let pipRadius = camera.pipShape.cornerRadius(for: pip)

            ZStack(alignment: .topLeading) {
                if backIsMain {
                    CameraPreviewView(previewLayer: camera.backPreviewLayer, isMirrored: false)
                        .frame(width: frames.main.width, height: frames.main.height)
                        .offset(x: frames.main.minX, y: frames.main.minY)
                        .gesture(focusTap(in: frames.main.size))

                    frontCameraContent
                        .frame(width: frames.secondary.width, height: frames.secondary.height)
                        .modifier(SecondaryPreviewClip(layout: camera.layout, radius: pipRadius))
                        .offset(x: frames.secondary.minX, y: frames.secondary.minY)
                        .gesture(pipDrag)
                } else {
                    frontCameraContent
                        .frame(width: frames.main.width, height: frames.main.height)
                        .offset(x: frames.main.minX, y: frames.main.minY)
                        .gesture(focusTap(in: frames.main.size))

                    CameraPreviewView(previewLayer: camera.backPreviewLayer, isMirrored: false)
                        .frame(width: frames.secondary.width, height: frames.secondary.height)
                        .modifier(SecondaryPreviewClip(layout: camera.layout, radius: pipRadius))
                        .offset(x: frames.secondary.minX, y: frames.secondary.minY)
                        .gesture(pipDrag)
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
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: camera.layout)
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: camera.isCamerasSwapped)
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: camera.pipShape)
            .onAppear { previewSize = size }
            .onChange(of: size) { _, newSize in previewSize = newSize }
        }
    }

    @ViewBuilder
    private var frontCameraContent: some View {
        FrontCameraImageView(store: camera.frontPreviewStore)
    }

    private var pipOffsetFraction: CGSize {
        pipOffsetFraction(for: pipOffset)
    }

    private var photoOverlayOffsetFraction: CGSize {
        pipOffsetFraction(for: photoOverlayOffset)
    }

    private func photoOverlayFrame(for image: UIImage, in size: CGSize) -> CGRect {
        let width = size.width * importedImageWidthFraction
        let height = width * image.size.height / max(image.size.width, 1)
        let x = min(max(0, 16 + photoOverlayOffset.width), size.width - width)
        let y = min(max(0, 16 + photoOverlayOffset.height), size.height - height)
        return CGRect(x: x, y: y, width: width, height: height)
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
    private func focusTap(in size: CGSize) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard size.width > 0, size.height > 0 else { return }
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
                                     splitOrientation: SplitOrientation) -> (main: CGRect, secondary: CGRect) {
        switch layout {
        case .splitScreen:
            if splitOrientation == .vertical {
                return (
                    CGRect(x: 0, y: 0, width: size.width, height: size.height / 2),
                    CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
                )
            } else {
                return (
                    CGRect(x: 0, y: 0, width: size.width / 2, height: size.height),
                    CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
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
        VStack {
            HStack(spacing: 12) {
                Picker("Раскладка", selection: $camera.layout) {
                    ForEach(CaptureLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                .pickerStyle(.segmented)

                Button {
                    camera.swapCameras()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.4), in: Circle())
                }

                Button {
                    drawing.isDrawingEnabled.toggle()
                } label: {
                    Image(systemName: drawing.isDrawingEnabled ? "pencil.circle.fill" : "pencil")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(drawing.isDrawingEnabled ? .yellow : .white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.4), in: Circle())
                }

                if camera.hasImportedMedia {
                    Button {
                        camera.clearImportedMedia()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.4), in: Circle())
                    }
                } else {
                    PhotosPicker(selection: $selectedMediaItems, maxSelectionCount: 1, matching: .any(of: [.images, .videos])) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.4), in: Circle())
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            if camera.layout == .pip {
                Picker("Форма окна", selection: $camera.pipShape) {
                    ForEach(PipShape.allCases) { shape in
                        Image(systemName: shape.systemImage).tag(shape)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .padding(.top, 6)

            }

            if camera.importedPhoto != nil {
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
                .padding(.top, 4)
                .onChange(of: importedImageWidthFraction) { _, newValue in
                    camera.updatePhotoOverlay(offsetFraction: photoOverlayOffsetFraction,
                                              widthFraction: newValue)
                }
            }

            if camera.layout == .splitScreen {
                Picker("Ориентация сплита", selection: $camera.splitOrientation) {
                    ForEach(SplitOrientation.allCases) { orientation in
                        Image(systemName: orientation.systemImage).tag(orientation)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .padding(.top, 6)
            }

            if drawing.isDrawingEnabled {
                drawingToolbar
                    .padding(.top, 6)
            }

            Spacer()

            // Зум в нижней части экрана.
            zoomControls

            if camera.isRecording {
                VStack(spacing: 10) {
                    Text(durationString(camera.recordingDuration))
                        .font(.system(.headline, design: .monospaced))
                        .foregroundStyle(.white)
                    Button {
                        camera.stopRecording(elements: drawing.elements)
                    } label: {
                        ZStack {
                            Circle().stroke(.white, lineWidth: 4).frame(width: 72, height: 72)
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.red)
                                .frame(width: 28, height: 28)
                        }
                    }
                }
                .padding(.bottom, 24)
            } else {
                HStack(spacing: 26) {
                    flashButton

                    if camera.isCapturing {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                            .frame(width: 72, height: 72)
                    } else {
                        Button {
                            camera.captureBothCameras(elements: drawing.elements,
                                                      pipOffsetFraction: pipOffsetFraction,
                                                      photoOverlayOffsetFraction: photoOverlayOffsetFraction,
                                                      photoOverlayWidthFraction: importedImageWidthFraction)
                        } label: {
                            Circle()
                                .fill(.white)
                                .frame(width: 72, height: 72)
                                .overlay(Circle().stroke(.white.opacity(0.4), lineWidth: 6))
                        }
                    }

                    Button {
                        camera.startRecording(elements: drawing.elements,
                                              pipOffsetFraction: pipOffsetFraction,
                                              photoOverlayOffsetFraction: photoOverlayOffsetFraction,
                                              photoOverlayWidthFraction: importedImageWidthFraction)
                    } label: {
                        ZStack {
                            Circle().stroke(.white, lineWidth: 4).frame(width: 72, height: 72)
                            Circle().fill(.red).frame(width: 56, height: 56)
                        }
                    }
                }
                .padding(.bottom, 24)
            }
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
        VStack(spacing: 8) {
            if isZoomSliderVisible && camera.maxZoomFactor > camera.minZoomFactor {
                Slider(
                    value: Binding(
                        get: { Double(camera.zoomFactor) },
                        set: { camera.setZoom(CGFloat($0)) }
                    ),
                    in: Double(camera.minZoomFactor)...Double(camera.maxZoomFactor),
                    step: 0.1
                )
                .tint(.yellow)
                .padding(.horizontal, 24)
            }

            HStack(spacing: 10) {
                ForEach([0.5, 1.0, 2.0, 5.0], id: \.self) { value in
                    Button {
                        camera.setZoom(CGFloat(value))
                    } label: {
                        Text(zoomLabel(value))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isZoomActive(value) ? Color.black : Color.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                isZoomActive(value) ? Color.white.opacity(0.9) : Color.black.opacity(0.45),
                                in: Capsule()
                            )
                    }
                    .onLongPressGesture(minimumDuration: 0.4) {
                        withAnimation { isZoomSliderVisible = true }
                    }
                }
            }
        }
        .padding(.bottom, 8)
    }

    private var flashButton: some View {
        Group {
            if camera.hasTorch {
                Button {
                    camera.toggleTorch()
                } label: {
                    Image(systemName: camera.isTorchOn ? "bolt.fill" : "bolt.slash")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(camera.isTorchOn ? .yellow : .white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.4), in: Circle())
                }
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
    }

    private var drawingToolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ForEach(ToolMode.allCases) { mode in
                    Button {
                        drawing.toolMode = mode
                    } label: {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(drawing.toolMode == mode ? .black : .white)
                            .frame(width: 34, height: 34)
                            .background(drawing.toolMode == mode ? Color.white : Color.black.opacity(0.4), in: Circle())
                    }
                }
            }
            HStack(spacing: 10) {
                ForEach(DrawColor.allCases) { color in
                    Button {
                        drawing.selectedColor = color
                    } label: {
                        Circle()
                            .fill(color.color)
                            .frame(width: 24, height: 24)
                            .overlay(Circle().stroke(drawing.selectedColor == color ? .white : .clear, lineWidth: 2))
                    }
                }
            }
            HStack(spacing: 14) {
                Slider(value: $drawing.brushWidth, in: 2...20, step: 1)
                    .frame(width: 120)
                    .tint(.white)
                Button {
                    drawing.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                }
                Button {
                    drawing.clear()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                }
            }
        }
        .padding(10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    private func zoomLabel(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(value))×" : String(format: "%.1f×", value)
    }

    private func isZoomActive(_ value: Double) -> Bool {
        abs(camera.zoomFactor - CGFloat(value)) < 0.15
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
