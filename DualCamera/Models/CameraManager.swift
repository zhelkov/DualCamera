import AVFoundation
import CoreImage
import UIKit
import Observation

/// Менеджер камеры. Отвечает за одновременную съёмку с двух камер
/// через `AVCaptureMultiCamSession`.
///
/// Ключевые правила:
/// - Вся работа с сессией выполняется в последовательной очереди `sessionQueue`.
/// - Свойства, которые читает UI, обновляются только на главном потоке.
/// - Соединения создаются вручную через `AVCaptureConnection`,
///   а не автоматически сессией.
@Observable
final class CameraManager: NSObject, AVCaptureDataOutputSynchronizerDelegate,
                           AVCaptureAudioDataOutputSampleBufferDelegate {

    // MARK: - Состояние для UI (обновляется на главном потоке)

    /// Текст последней ошибки, который показываем пользователю.
    private(set) var errorMessage: String?
    /// Сессия настроена и готова к работе.
    private(set) var isConfigured = false
    /// Поток данных запущен (сессия работает).
    private(set) var isRunning = false
    /// Идёт процесс съёмки и склейки фото.
    private(set) var isCapturing = false
    /// Результат последней склейки двух снимков.
    private(set) var lastMergedPhoto: UIImage?
    /// Результат последней записи видео (объединённый файл).
    private(set) var lastMergedVideoURL: URL?
    /// Идёт ли запись видео.
    private(set) var isRecording = false
    private(set) var isApplyingSettings = false
    /// Длительность текущей записи.
    private(set) var recordingDuration: TimeInterval = 0
    /// Текущая раскладка превью (сплит или картинка в картинке).
    var layout: CaptureLayout = .pip
    /// Ориентация сплита: вертикально или горизонтально.
    var splitOrientation: SplitOrientation = .vertical
    /// Доля кадра, занимаемая основной камерой в сплит-режиме.
    var splitRatio: CGFloat = SplitRatio.defaultValue
    /// Показывается ли вторая камера.
    var isSecondaryCameraVisible = true
    /// Поменяны ли местами передняя и задняя камеры.
    var isCamerasSwapped = false
    /// Форма окна «картинка в картинке».
    var pipShape: PipShape = .rectangle
    /// Выбранный Core Image фильтр.
    var videoFilter: VideoFilter = .original
    /// Камера, к которой применяется выбранный фильтр.
    private(set) var activeFilterTarget: VideoFilterTarget = .primary
    /// Отфильтрованный кадр задней камеры для превью.
    private(set) var backFilteredPreviewImage: UIImage?
    /// Отфильтрованный кадр передней камеры для превью.
    private(set) var frontFilteredPreviewImage: UIImage?
    /// Текущий зум основной камеры.
    private(set) var zoomFactor: CGFloat = 1.0
    /// Доступный диапазон зума.
    private(set) var minZoomFactor: CGFloat = 1.0
    private(set) var maxZoomFactor: CGFloat = 1.0
    private(set) var exposureTargetBias: Float = 0
    private(set) var minExposureTargetBias: Float = -2
    private(set) var maxExposureTargetBias: Float = 2
    private(set) var isFocusExposureLocked = false
    /// Включён ли фонарик.
    private(set) var isTorchOn = false
    /// Поддерживает ли основная камера фонарик.
    private(set) var hasTorch = false
    /// Ориентация съёмки: портрет или ландшафт.
    private(set) var isPortrait = true
    /// Импортированное фото (используется вместо передней камеры).
    private(set) var importedPhoto: UIImage?
    /// Импортированное видео (используется вместо передней камеры).
    private(set) var importedVideoURL: URL?
    private var captureSettings = CameraSettingsSnapshot.defaults
    private var recordingCaptureSettings = CameraSettingsSnapshot.defaults
    private var recordingOutputSize = CGSize(width: 1080, height: 1920)

    /// Есть ли импортированный медиафайл.
    var hasImportedMedia: Bool {
        importedPhoto != nil || importedVideoURL != nil
    }

    // MARK: - Сессия и очередь

    private let session = AVCaptureMultiCamSession()
    /// Последовательная очередь: все операции с сессией выполняются только здесь.
    private let sessionQueue = DispatchQueue(label: "com.dualcamera.session", qos: .userInitiated)

    // MARK: - Устройства, входы, выходы

    private var backCamera: AVCaptureDevice?
    private var frontCamera: AVCaptureDevice?
    private var backRotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var frontRotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var backInput: AVCaptureDeviceInput?
    private var frontInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?

    private let backPhotoOutput = AVCapturePhotoOutput()
    private let frontPhotoOutput = AVCapturePhotoOutput()
    private let backMovieOutput = AVCaptureMovieFileOutput()
    private let frontMovieOutput = AVCaptureMovieFileOutput()
    private let backVideoDataOutput = AVCaptureVideoDataOutput()
    private let frontVideoDataOutput = AVCaptureVideoDataOutput()
    private let audioDataOutput = AVCaptureAudioDataOutput()
    private let realtimeCaptureQueue = DispatchQueue(label: "com.dualcamera.realtime-capture", qos: .userInitiated)
    private let realtimeWriterQueue = DispatchQueue(label: "com.dualcamera.realtime-writer", qos: .userInitiated)
    private let filterPreviewQueue = DispatchQueue(label: "com.dualcamera.filter-preview", qos: .userInitiated)
    private let realtimeWriterSlots = DispatchSemaphore(value: 2)
    private let filterPreviewSlot = DispatchSemaphore(value: 1)
    private let filterPreviewContext = CIContext(options: [.cacheIntermediates: false])
    private let filterStateLock = NSLock()
    private var captureVideoFilter: VideoFilter = .original
    private var captureFilterTarget: VideoFilterTarget = .primary
    private var filterPreviewCamera: MovieCaptureDelegate.Camera = .back
    private var filterPreviewErrorReported = false
    private var videoDataSynchronizer: AVCaptureDataOutputSynchronizer?
    private var realtimeVideoOutputsReady = false
    private var realtimeRecorder: RealtimeCompositeRecorder?
    private var isUsingRealtimeRecorder = false
    // AVCaptureDataOutputSynchronizer can report a dropped or absent sample for
    // one camera at a timestamp. Keep the most recent usable image from each
    // camera so one missed sample doesn't discard the entire composite frame.
    private var latestRealtimeBackBuffer: CVPixelBuffer?
    private var latestRealtimeFrontBuffer: CVPixelBuffer?
    private var lastRealtimeSubmittedBackPTS = CMTime.invalid
    /// До этого момента кадры не пишем: после старта записи камера ещё
    /// не отдала стабильную экспозицию, иначе файл начинается с тёмного кадра.
    private var realtimeWarmupDeadline: Date?
    /// Размер последнего кадра задней камеры — для диагностики ориентации.
    private(set) var lastBackBufferSize = CGSize.zero
    private var publishedBackBufferSize = CGSize.zero
    /// Кадр-заглушка на время переключения объектива: закрывает чёрный провал.
    private(set) var lensSwitchSnapshot: UIImage?
    /// Переключение объектива ещё идёт — заглушку не убираем.
    private var lensSwitchInFlight = false
    private let snapshotContext = CIContext()

    // MARK: - Ротация

    private var orientationObserverRegistered = false
    /// Последняя известная ориентация кадра по датчику устройства.
    private var lastVideoOrientation: AVCaptureVideoOrientation = .portrait
    private var backPhotoConnection: AVCaptureConnection?
    private var frontPhotoConnection: AVCaptureConnection?
    private var backMovieConnection: AVCaptureConnection?
    private var frontMovieConnection: AVCaptureConnection?
    private var frontVideoDataConnection: AVCaptureConnection?
    private var backVideoDataConnection: AVCaptureConnection?

    // MARK: - Превью-слои

    /// Превью задней камеры. Создаётся без автоматической связи —
    /// соединение добавляем вручную.
    let backPreviewLayer: AVCaptureVideoPreviewLayer
    /// Превью передней камеры.
    let frontPreviewLayer: AVCaptureVideoPreviewLayer

    // MARK: - Удержание делегатов фотосъёмки

    /// `AVCapturePhotoOutput` не удерживает делегата, поэтому храним его сами.
    /// Доступ защищён локом, т.к. оба захвата идут параллельно.
    private let delegatesLock = NSLock()
    private var activePhotoDelegates: [PhotoCaptureDelegate] = []

    // MARK: - Состояние видеозаписи

    private var recordingBackURL: URL?
    private var recordingFrontURL: URL?
    private var recordingElements: [DrawingElement] = []
    private var recordingPipOffsetFraction: CGSize = .zero
    private var recordingPipWidthFraction: CGFloat = 0.3
    private var recordingPipPositionKeyframes: [PipPositionKeyframe] = []
    private var recordingLayoutKeyframes: [CaptureLayoutKeyframe] = []
    private var recordingFilterKeyframes: [VideoFilterKeyframe] = []
    private var recordingCameraSwapKeyframes: [CameraSwapKeyframe] = []
    private var recordingDrawingKeyframes: [DrawingElementsKeyframe] = []
    private var recordingPhotoOverlay: UIImage?
    private var recordingPhotoOverlayID: UUID?
    private var recordingPhotoOverlayOffsetFraction: CGSize = .zero
    private var recordingPhotoOverlayWidthFraction: CGFloat = 0.3
    private var recordingPhotoOverlayInnerScale: CGFloat = 1
    private var recordingPhotoOverlayInnerOffsetFraction: CGSize = .zero
    private var recordingPhotoOverlayOpacity: CGFloat = 1
    private var recordingPhotoOverlayKeyframes: [PhotoOverlayKeyframe] = []
    private var recordingImportedVideoURL: URL?
    private var recordingLayout: CaptureLayout = .pip
    private var recordingShape: PipShape = .rectangle
    private var recordingSplitOrientation: SplitOrientation = .vertical
    private var recordingSplitRatio: CGFloat = SplitRatio.defaultValue
    private var recordingCamerasSwapped = false
    private var expectedRecordingCount = 0
    private var receivedRecordingCallbacks = 0
    private var recordedURLs: [MovieCaptureDelegate.Camera: URL] = [:]
    private var recordingError: Error?
    private let recordingLock = NSLock()
    private var recordingDelegates: [MovieCaptureDelegate] = []
    private var recordingTimer: Timer?
    private var recordingStartDate: Date?

    // MARK: - Инициализация

    override init() {
        // Превью-слои привязаны к сессии, но соединений пока нет —
        // их создадим в `connect(_:to:mirrored:)`.
        backPreviewLayer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        frontPreviewLayer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
        super.init()
        backPreviewLayer.videoGravity = .resizeAspectFill
        frontPreviewLayer.videoGravity = .resizeAspectFill
    }

    deinit {
        NotificationCenter.default.removeObserver(self,
                                                  name: UIDevice.orientationDidChangeNotification,
                                                  object: nil)
        lowLightTimer?.cancel()
        lowLightTimer = nil
        if orientationObserverRegistered {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
    }

    // MARK: - Публичное API

    /// Запрашивает доступ к камере и настраивает сессию.
    func requestAccessAndSetup() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        var authorized = status == .authorized
        if status == .notDetermined {
            authorized = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard authorized else {
            setError(.permissionDenied)
            return
        }

        // Микрофон нужен для записи звука в видео.
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }

        setupSession()
    }

    /// Настраивает `AVCaptureMultiCamSession` для двух камер и запускает поток.
    func setupSession() {
        // Правило №2: сначала проверяем поддержку MultiCam.
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            setError(.multiCamUnsupported)
            return
        }

        let initialOrientation = currentInterfaceVideoOrientation()
        registerOrientationObserver()
        sessionQueue.async { [weak self] in
            guard let self else { return }

            // Аудиосессию включаем только на время записи: активный
            // режим .playAndRecord глушит мотор тактильной отдачи.
            do {
                try self.configureSession()
                self.applyInterfaceOrientation(initialOrientation, forceCaptureOutputs: true)
                self.session.startRunning()
                if !self.session.isRunning {
                    // Повторяем запуск, но НЕ включаем аудиосессию: её
                    // активный режим записи глушит тактильную отдачу.
                    self.session.startRunning()
                }
                // Страховка: если аудиосессия осталась активной с прошлого
                // раза, освобождаем её — иначе мотор молчит.
                self.deactivateAudioSessionIfIdle()
                // Выходы синхронного захвата готовим сразу, а не в момент
                // старта записи: пересборка сессии на старте давала тёмный
                // кадр в превью и в начале готового видео.
                if !self.realtimeVideoOutputsReady {
                    try? self.configureRealtimeOutputs()
                }
                self.checkPreviewLayersAfterStart()
                self.startLowLightMonitoring()
                // Характеристики читаем на очереди сессии, применяем на главной.
                let unit = self.backCameraZoomUnit
                let minZoom = (self.backCamera?.minAvailableVideoZoomFactor ?? 1) * unit
                let maxZoom = (self.backCamera?.maxAvailableVideoZoomFactor ?? 1) * unit
                let hasTorch = self.backCamera?.hasTorch ?? false
                let currentZoom = (self.backCamera?.videoZoomFactor ?? 1) * unit
                let hasUltraWide = AVCaptureDevice.default(.builtInUltraWideCamera,
                                                           for: .video,
                                                           position: .back) != nil
                self.updateOnMain {
                    self.isConfigured = true
                    self.isRunning = self.session.isRunning
                    self.errorMessage = nil
                    self.hasUltraWideBackCamera = hasUltraWide
                    self.minZoomFactor = minZoom
                    self.maxZoomFactor = maxZoom
                    self.hasTorch = hasTorch
                    self.zoomFactor = currentZoom
                }
            } catch {
                self.updateOnMain {
                    self.errorMessage = (error as? LocalizedError)?.errorDescription
                        ?? "Не удалось настроить камеру."
                }
            }
        }
    }

    func startRunning() {
        let orientation = currentInterfaceVideoOrientation()
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.applyInterfaceOrientation(orientation, forceCaptureOutputs: true)
            self.session.startRunning()
            if !self.session.isRunning {
                self.session.startRunning()
            }
            self.deactivateAudioSessionIfIdle()
            self.startLowLightMonitoring()
            self.updateOnMain { self.isRunning = self.session.isRunning }
        }
    }

    func stopRunning() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.stopLowLightMonitoring()
            self.session.stopRunning()
            self.deactivateAudioSession()
            self.updateOnMain { self.isRunning = false }
        }
    }

    // MARK: - Аудио-сессия

    /// Настраивает аудио-сессию для одновременной записи звука и превью.
    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .videoRecording,
                                     options: [.defaultToSpeaker, .mixWithOthers])
        try audioSession.setActive(true)
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// В превью аудиосессия не нужна. Освобождаем её: активный режим
    /// записи глушит мотор тактильной отдачи.
    private func deactivateAudioSessionIfIdle() {
        guard !isRecording else { return }
        try? AVAudioSession.sharedInstance().setActive(false,
                                                       options: .notifyOthersOnDeactivation)
    }

    /// Текущее состояние аудиосессии — для диагностики тактильной отдачи.
    var audioSessionDiagnostics: String {
        let session = AVAudioSession.sharedInstance()
        return "аудиосессия \(session.category.rawValue)"
    }

    /// Фактическая ориентация съёмки — для диагностики геометрии кадра.
    var geometryDiagnostics: String {
        let device: String
        switch UIDevice.current.orientation {
        case .portrait: device = "портрет"
        case .portraitUpsideDown: device = "портрет ↓"
        case .landscapeLeft: device = "ландшафт ←"
        case .landscapeRight: device = "ландшафт →"
        case .faceUp: device = "экран вверх"
        case .faceDown: device = "экран вниз"
        default: device = "не определён"
        }
        let raw = UIDevice.current.orientation.rawValue
        let frameIsPortrait = lastVideoOrientation == .portrait
            || lastVideoOrientation == .portraitUpsideDown
        let canvas = captureSettings.outputSize(isPortrait: isPortrait)
        let buffer = lastBackBufferSize == .zero
            ? "нет"
            : "\(Int(lastBackBufferSize.width))×\(Int(lastBackBufferSize.height))"
        return "датчик: \(device)[\(raw)] · кадр: \(frameIsPortrait ? "портрет" : "ландшафт") · "
            + "холст: \(Int(canvas.width))×\(Int(canvas.height)) · буфер: \(buffer)"
    }

    /// Снимает фото одновременно с обеих камер, склеивает и накладывает рисунок.
    func captureBothCameras(elements: [DrawingElement] = [],
                            pipOffsetFraction: CGSize = .zero,
                            photoOverlayOffsetFraction: CGSize = .zero,
                            photoOverlayWidthFraction: CGFloat = 0.3,
                            photoOverlayInnerScale: CGFloat = 1,
                            photoOverlayInnerOffsetFraction: CGSize = .zero,
                            photoOverlayOpacity: CGFloat = 1) {
        guard isConfigured, !isCapturing, !isApplyingSettings else { return }
        let filterAtCapture = videoFilter
        let filterTargetAtCapture = activeFilterTarget
        refreshCaptureOrientation()
        let aspectRatioAtCapture = captureSettings.aspectRatio.ratio(isPortrait: isPortrait)
        let timestampAtCapture = captureSettings.dateTimeEnabled ? Date() : nil
        updateOnMain { self.isCapturing = true }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            Task {
                do {
                    let merged = try await self.captureAndMerge(elements: elements,
                                                                pipOffsetFraction: pipOffsetFraction,
                                                                photoOverlayOffsetFraction: photoOverlayOffsetFraction,
                                                                photoOverlayWidthFraction: photoOverlayWidthFraction,
                                                                photoOverlayInnerScale: photoOverlayInnerScale,
                                                                photoOverlayInnerOffsetFraction: photoOverlayInnerOffsetFraction,
                                                                photoOverlayOpacity: photoOverlayOpacity,
                                                                videoFilter: filterAtCapture,
                                                                filterTarget: filterTargetAtCapture,
                                                                outputAspectRatio: aspectRatioAtCapture,
                                                                timestamp: timestampAtCapture)
                    self.updateOnMain {
                        self.lastMergedPhoto = merged
                        self.isCapturing = false
                    }
                } catch {
                    self.updateOnMain {
                        self.errorMessage = (error as? LocalizedError)?.errorDescription
                            ?? "Не удалось сделать снимок."
                        self.isCapturing = false
                    }
                }
            }
        }
    }

    func clearError() {
        updateOnMain { self.errorMessage = nil }
    }

    func showError(_ message: String) {
        updateOnMain { self.errorMessage = message }
    }

    func clearMergedPhoto() {
        updateOnMain { self.lastMergedPhoto = nil }
    }

    func clearMergedVideo() {
        updateOnMain { self.lastMergedVideoURL = nil }
    }

    func applyCaptureSettings(_ settings: CameraSettingsSnapshot) {
        let previous = captureSettings
        let requiresSessionUpdate = previous.resolution != settings.resolution
            || previous.frameRate != settings.frameRate
            || previous.stabilizationEnabled != settings.stabilizationEnabled
        guard requiresSessionUpdate, isConfigured else {
            captureSettings = settings
            return
        }
        guard !isRecording else {
            updateOnMain { self.errorMessage = "Остановите запись перед изменением параметров камеры." }
            return
        }

        updateOnMain { self.isApplyingSettings = true }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isRecording,
                  let backCamera = self.backCamera,
                  let frontCamera = self.frontCamera else {
                self.updateOnMain {
                    self.isApplyingSettings = false
                    self.errorMessage = "Не удалось изменить параметры во время работы камеры."
                }
                return
            }

            do {
                guard let backFormat = self.bestMultiCamFormat(
                    for: backCamera,
                    target: settings.resolution.landscapeCaptureTarget,
                    frameRate: settings.frameRate.rawValue
                ), let frontFormat = self.bestMultiCamFormat(
                    for: frontCamera,
                    target: CGSize(width: 640, height: 480),
                    frameRate: settings.frameRate.rawValue
                ) else {
                    throw CameraError.noCompatibleFormat
                }

                self.session.beginConfiguration()
                do {
                    try self.applyFormat(backFormat, to: backCamera, frameRate: settings.frameRate.rawValue)
                    try self.applyFormat(frontFormat, to: frontCamera, frameRate: settings.frameRate.rawValue)
                    self.captureSettings = settings
                    self.applyStabilization(settings.stabilizationEnabled)
                    self.session.commitConfiguration()
                } catch {
                    self.session.commitConfiguration()
                    throw error
                }
                self.updateOnMain { self.isApplyingSettings = false }
            } catch {
                self.updateOnMain {
                    self.isApplyingSettings = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Импортированные медиа

    /// Подставляет фото из библиотеки вместо передней камеры.
    func setImportedPhoto(_ image: UIImage?) {
        updateOnMain {
            self.importedPhoto = image
            self.recordImportedPhotoChange(image)
        }
    }

    /// Подставляет видео из библиотеки вместо передней камеры.
    func setImportedVideo(_ url: URL?) {
        updateOnMain { self.importedVideoURL = url }
    }

    func clearImportedMedia() {
        updateOnMain {
            self.importedPhoto = nil
            self.recordImportedPhotoChange(nil)
            self.importedVideoURL = nil
        }
    }

    /// Меняет местами переднюю и заднюю камеры (основная ↔ вторичная).
    func swapCameras() {
        updateOnMain {
            self.isCamerasSwapped.toggle()
            self.backFilteredPreviewImage = nil
            self.frontFilteredPreviewImage = nil
            self.filterStateLock.lock()
            self.filterPreviewCamera = Self.physicalCamera(for: self.activeFilterTarget,
                                                           isSwapped: self.isCamerasSwapped)
            self.filterStateLock.unlock()
            guard self.isRecording else { return }
            self.recordingLock.lock()
            guard let start = self.recordingStartDate else {
                self.recordingLock.unlock()
                return
            }
            let keyframe = CameraSwapKeyframe(
                time: Date().timeIntervalSince(start),
                isSwapped: self.isCamerasSwapped
            )
            if self.recordingCameraSwapKeyframes.last?.isSwapped != keyframe.isSwapped {
                self.recordingCameraSwapKeyframes.append(keyframe)
            }
            self.recordingLock.unlock()
        }
    }

    func selectVideoFilter(_ filter: VideoFilter) {
        guard filter != videoFilter else { return }
        updateOnMain {
            self.videoFilter = filter
            self.backFilteredPreviewImage = nil
            self.frontFilteredPreviewImage = nil
        }

        filterStateLock.lock()
        captureVideoFilter = filter
        filterPreviewErrorReported = false
        let shouldCaptureFilteredPreview = filter != .original
        filterPreviewCamera = Self.physicalCamera(for: captureFilterTarget,
                                                  isSwapped: isCamerasSwapped)
        filterStateLock.unlock()
        updateRecordingFilter(filter, target: activeFilterTarget)

        guard isConfigured else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if shouldCaptureFilteredPreview && !self.realtimeVideoOutputsReady {
                do {
                    try self.configureRealtimeOutputs()
                } catch {
                    self.updateOnMain { self.errorMessage = error.localizedDescription }
                }
            } else if !shouldCaptureFilteredPreview && !self.isRecording && self.realtimeVideoOutputsReady {
                self.removeRealtimeOutputs()
            }
        }
    }

    func selectFilterTarget(_ target: VideoFilterTarget) {
        guard target != activeFilterTarget else { return }
        updateOnMain {
            self.activeFilterTarget = target
            self.backFilteredPreviewImage = nil
            self.frontFilteredPreviewImage = nil
        }
        filterStateLock.lock()
        captureFilterTarget = target
        filterPreviewCamera = Self.physicalCamera(for: target, isSwapped: isCamerasSwapped)
        filterPreviewErrorReported = false
        let shouldCaptureFilteredPreview = captureVideoFilter != .original
        filterStateLock.unlock()
        updateRecordingFilter(videoFilter, target: target)

        if shouldCaptureFilteredPreview && isConfigured {
            sessionQueue.async { [weak self] in
                guard let self, !self.realtimeVideoOutputsReady else { return }
                do {
                    try self.configureRealtimeOutputs()
                } catch {
                    self.updateOnMain { self.errorMessage = error.localizedDescription }
                }
            }
        }
    }

    private static func physicalCamera(for target: VideoFilterTarget,
                                       isSwapped: Bool) -> MovieCaptureDelegate.Camera {
        switch (target, isSwapped) {
        case (.primary, false), (.secondary, true): return .back
        case (.primary, true), (.secondary, false): return .front
        }
    }

    private func updateRecordingFilter(_ filter: VideoFilter, target: VideoFilterTarget) {
        guard isRecording else { return }
        recordingLock.lock()
        defer { recordingLock.unlock() }
        guard let recordingStartDate else { return }
        if let last = recordingFilterKeyframes.last,
           last.filter == filter, last.target == target {
            return
        }
        recordingFilterKeyframes.append(
            VideoFilterKeyframe(time: Date().timeIntervalSince(recordingStartDate),
                                filter: filter,
                                target: target)
        )
    }

    // MARK: - Зум, фонарик, фокус

    /// Живое изменение зума во время перетаскивания. Значение показываем
    /// сразу, а объектив переключаем на пороге: иначе ползунок замирает на 1×
    /// и перескакивает на 0,5× только при отпускании.
    func setZoom(_ factor: CGFloat) {
        pendingZoomFactor = factor
        updateOnMain { self.zoomFactor = factor }
        applyZoom(factor, publish: false)
        switchLensIfNeeded(for: factor)
    }

    /// Завершение жеста: фиксируем итоговое значение и, если нужно, объектив.
    func commitZoom() {
        let target = pendingZoomFactor ?? zoomFactor
        pendingZoomFactor = nil
        if switchLensIfNeeded(for: target) { return }
        applyZoom(target)
    }

    /// Переключает задний объектив, когда зум выходит за границы текущего.
    @discardableResult
    private func switchLensIfNeeded(for factor: CGFloat) -> Bool {
        guard !isRecording, !isCapturing else { return false }
        if factor < 0.9, backLens == .wide, hasUltraWideBackCamera {
            switchBackLens(to: .ultraWide, targetZoom: factor)
            return true
        }
        if factor > 1.1, backLens == .ultraWide {
            switchBackLens(to: .wide, targetZoom: factor)
            return true
        }
        return false
    }

    private func applyZoom(_ factor: CGFloat, publish: Bool = true) {
        let unit = backCameraZoomUnit
        let deviceFactor = factor / max(unit, 0.0001)

        sessionQueue.async { [weak self] in
            guard let self, let device = self.backCamera else { return }
            let clamped = min(max(deviceFactor, device.minAvailableVideoZoomFactor),
                              device.maxAvailableVideoZoomFactor)
            guard (try? device.lockForConfiguration()) != nil else { return }
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
            guard publish else { return }
            let displayZoom = clamped * self.backCameraZoomUnit
            self.updateOnMain { self.zoomFactor = displayZoom }
        }
    }

    /// Пересобирает сессию с другим задним объективом и применяет нужный зум.
    private func switchBackLens(to lens: BackLens, targetZoom: CGFloat) {
        guard !isRecording, !isCapturing, !isApplyingSettings else { return }
        guard lens != backLens else {
            applyZoom(targetZoom)
            return
        }
        let previousLens = backLens
        backLens = lens
        updateOnMain { self.isApplyingSettings = true }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            // Замораживаем последний кадр: пересборка сессии на время
            // отключает превью, и без заглушки экран мигал чёрным.
            let snapshot = self.latestRealtimeBackBuffer.flatMap { self.makeSnapshot($0) }
            self.lensSwitchInFlight = true
            self.updateOnMain { self.lensSwitchSnapshot = snapshot }
            // Сессию не останавливаем: остановка давала тёмный кадр на экране
            // при проходе зума через 1×. Пересобираем на ходу.
            self.resetSessionConfiguration()
            do {
                try self.configureSession()
                self.applyInterfaceOrientation(self.lastVideoOrientation, forceCaptureOutputs: true)
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                // После пересборки сессии синхронный захват нужен снова.
                if !self.realtimeVideoOutputsReady {
                    try? self.configureRealtimeOutputs()
                }
                let unit = self.backCameraZoomUnit
                let minZoom = (self.backCamera?.minAvailableVideoZoomFactor ?? 1) * unit
                let maxZoom = (self.backCamera?.maxAvailableVideoZoomFactor ?? 1) * unit
                let hasTorch = self.backCamera?.hasTorch ?? false
                self.updateOnMain {
                    self.isRunning = self.session.isRunning
                    self.minZoomFactor = minZoom
                    self.maxZoomFactor = maxZoom
                    self.hasTorch = hasTorch
                    self.isApplyingSettings = false
                }
                self.applyZoom(targetZoom)
                self.lensSwitchInFlight = false
                // Страховка: если кадры почему-то не пришли, заглушку снимаем сами.
                self.sessionQueue.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    guard let self, !self.lensSwitchInFlight else { return }
                    self.updateOnMain { self.lensSwitchSnapshot = nil }
                }
            } catch {
                self.backLens = previousLens
                self.lensSwitchInFlight = false
                self.updateOnMain { self.lensSwitchSnapshot = nil }
                self.sessionQueue.async {
                    self.resetSessionConfiguration()
                    try? self.configureSession()
                    if !self.session.isRunning {
                        self.session.startRunning()
                    }
                }
                self.updateOnMain {
                    self.isApplyingSettings = false
                    self.errorMessage = (error as? LocalizedError)?.errorDescription
                        ?? "Не удалось переключить объектив."
                }
            }
        }
    }

    /// Кадр-заглушка из последнего буфера камеры.
    private func makeSnapshot(_ buffer: CVPixelBuffer) -> UIImage? {
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = snapshotContext.createCGImage(image, from: image.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Ночной режим фронтальной камеры

    private var lowLightTimer: DispatchSourceTimer?
    /// Сколько проверок подряд сцена остаётся тёмной.
    private var darkChecks = 0
    /// Копия блокировки экспозиции: читается с очереди сессии без обращения
    /// к наблюдаемым свойствам.
    private var isFocusLockedForNight = false
    /// Флаг ночного режима для очереди съёмки.
    private var frontNightModeActive = false
    /// Виден ли ночной режим интерфейсу.
    private(set) var isFrontNightMode = false
    /// Подъём экспозиции фронтальной камеры в темноте (в ступенях EV).
    static let frontNightExposureEV: Float = 1.5

    /// Следит за освещённостью фронтальной камеры и включает ночной подъём
    /// экспозиции. Само устройство не настраиваем: в MultiCam изменение
    /// экспозиции на одном устройстве роняло приложение, поэтому яркость
    /// поднимаем в обработке кадра.
    private func startLowLightMonitoring() {
        guard lowLightTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.updateFrontNightMode() }
        timer.resume()
        lowLightTimer = timer
    }

    private func stopLowLightMonitoring() {
        lowLightTimer?.cancel()
        lowLightTimer = nil
        darkChecks = 0
        frontNightModeActive = false
        updateOnMain { self.isFrontNightMode = false }
    }

    /// Тёмной считаем сцену, где ISO подошёл к пределу активного формата.
    /// Решение принимается по двум проверкам подряд, чтобы не мигать
    /// на случайных кадрах.
    private func updateFrontNightMode() {
        guard !isFocusLockedForNight, let device = frontCamera else { return }
        let maxISO = device.activeFormat.maxISO
        guard maxISO > 0 else { return }
        let ratio = device.iso / maxISO
        guard ratio.isFinite else { return }
        if ratio > 0.7 {
            darkChecks = min(darkChecks + 1, 3)
        } else if ratio < 0.4 {
            darkChecks = 0
        }
        let shouldBoost = darkChecks >= 2
        guard shouldBoost != frontNightModeActive else { return }
        frontNightModeActive = shouldBoost
        updateOnMain { self.isFrontNightMode = shouldBoost }
        // Сбрасываем кадры превью, чтобы вернуться к живому слою камеры.
        if !shouldBoost {
            updateOnMain { self.frontFilteredPreviewImage = nil }
        }
    }

    /// Включает/выключает фонарик основной камеры.
    func toggleTorch() {        let newValue = !isTorchOn
        updateOnMain { self.isTorchOn = newValue }

        sessionQueue.async { [weak self] in
            guard let self, let device = self.backCamera, device.hasTorch else {
                self?.updateOnMain { self?.isTorchOn = false }
                return
            }
            guard (try? device.lockForConfiguration()) != nil else { return }
            device.torchMode = newValue ? .on : .off
            device.unlockForConfiguration()
        }
    }

    /// Sets focus and auto-exposure at a point converted by the camera preview layer.
    func focusAndExpose(at normalizedPoint: CGPoint,
                        target: VideoFilterTarget,
                        lock: Bool = false,
                        completion: @escaping (Bool) -> Void) {
        let point = CGPoint(x: min(max(normalizedPoint.x, 0), 1),
                            y: min(max(normalizedPoint.y, 0), 1))

        sessionQueue.async { [weak self] in
            guard let self else { return }
            let isBackCamera = target == .primary ? !self.isCamerasSwapped : self.isCamerasSwapped
            guard let device = isBackCamera ? self.backCamera : self.frontCamera else {
                self.updateOnMain { completion(false) }
                return
            }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                }

                // Сверхширокоугольная камера имеет фиксированный фокус:
                // фиксируем то, что поддерживается, и не показываем ошибку.
                let focusCanLock = device.isFocusModeSupported(.locked)
                    && device.isFocusPointOfInterestSupported
                let exposureCanLock = device.isExposureModeSupported(.locked)
                let didLock = lock && exposureCanLock
                if lock, focusCanLock, device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    device.focusMode = .locked
                } else if !lock || !focusCanLock {
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    } else if device.isFocusModeSupported(.autoFocus) {
                        device.focusMode = .autoFocus
                    }
                }
                if lock, exposureCanLock {
                    if device.isExposurePointOfInterestSupported {
                        device.exposurePointOfInterest = point
                    }
                    device.exposureMode = .locked
                } else {
                    if device.isExposurePointOfInterestSupported {
                        device.exposurePointOfInterest = point
                    }
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    } else if device.isExposureModeSupported(.autoExpose) {
                        device.exposureMode = .autoExpose
                    }
                    device.setExposureTargetBias(0, completionHandler: nil)
                }

                let minimumBias = device.minExposureTargetBias
                let maximumBias = device.maxExposureTargetBias
                let currentBias = didLock ? device.exposureTargetBias : 0
                device.unlockForConfiguration()
                self.updateOnMain {
                    self.minExposureTargetBias = minimumBias
                    self.maxExposureTargetBias = maximumBias
                    self.exposureTargetBias = currentBias
                    self.isFocusExposureLocked = didLock
                    self.isFocusLockedForNight = didLock
                    completion(didLock)
                }
            } catch {
                self.updateOnMain {
                    self.errorMessage = error.localizedDescription
                    completion(false)
                }
            }
        }
    }

    func setExposureTargetBias(_ bias: Float, target: VideoFilterTarget) {
        guard !isFocusExposureLocked else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let isBackCamera = target == .primary ? !self.isCamerasSwapped : self.isCamerasSwapped
            guard let device = isBackCamera ? self.backCamera : self.frontCamera else { return }
            do {
                try device.lockForConfiguration()
                let clamped = min(max(bias, device.minExposureTargetBias), device.maxExposureTargetBias)
                device.setExposureTargetBias(clamped, completionHandler: nil)
                let minimumBias = device.minExposureTargetBias
                let maximumBias = device.maxExposureTargetBias
                device.unlockForConfiguration()
                self.updateOnMain {
                    self.exposureTargetBias = clamped
                    self.minExposureTargetBias = minimumBias
                    self.maxExposureTargetBias = maximumBias
                }
            } catch {
                self.updateOnMain { self.errorMessage = error.localizedDescription }
            }
        }
    }

    // MARK: - Видеозапись

    /// Записывает и композитит обе камеры на лету; импортированное видео склеивается после записи.
    /// `elements` — рисунок, который вшивается в видео (снимок на момент старта).
    func startRecording(elements: [DrawingElement] = [],
                        pipOffsetFraction: CGSize = .zero,
                        photoOverlayOffsetFraction: CGSize = .zero,
                        photoOverlayWidthFraction: CGFloat = 0.3,
                        photoOverlayInnerScale: CGFloat = 1,
                        photoOverlayInnerOffsetFraction: CGSize = .zero,
                        photoOverlayOpacity: CGFloat = 1) {
        guard isConfigured, !isRecording, !isApplyingSettings else { return }
        if importedVideoURL != nil, captureSettings.audioQuality == .appleLossless {
            showError("Apple Lossless недоступен при записи с импортированным видео.")
            return
        }
        let importedPhotoAtStart = importedPhoto
        refreshCaptureOrientation()
        let orientationAtStart = currentInterfaceVideoOrientation()
        let swappedAtStart = isCamerasSwapped
        let importedVideoAtStart = importedVideoURL
        // Склейка идёт на лету, как раньше; импортированное видео
        // по-прежнему склеивается после остановки.
        let useRealtimeComposite = importedVideoAtStart == nil
        let layoutAtStart = layout
        let shapeAtStart = pipShape
        let splitOrientationAtStart = splitOrientation
        let splitRatioAtStart = splitRatio
        let secondaryCameraVisibleAtStart = isSecondaryCameraVisible
        let videoFilterAtStart = videoFilter
        let filterTargetAtStart = activeFilterTarget
        let settingsAtStart = captureSettings
        let portraitAtStart = orientationAtStart == .portrait || orientationAtStart == .portraitUpsideDown
        updateOnMain {
            self.isRecording = true
            self.recordingDuration = 0
            self.startRecordingTimer(initialOffsetFraction: pipOffsetFraction,
                                     widthFraction: 0.3,
                                     elements: elements,
                                     photoOffsetFraction: photoOverlayOffsetFraction,
                                     photoWidthFraction: photoOverlayWidthFraction,
                                     photoInnerScale: photoOverlayInnerScale,
                                     photoInnerOffsetFraction: photoOverlayInnerOffsetFraction,
                                     photoOpacity: photoOverlayOpacity,
                                     photo: importedPhotoAtStart,
                                     camerasSwapped: swappedAtStart,
                                     layout: layoutAtStart,
                                     shape: shapeAtStart,
                                     splitOrientation: splitOrientationAtStart,
                                     splitRatio: splitRatioAtStart,
                                     isSecondaryCameraVisible: secondaryCameraVisibleAtStart,
                                     videoFilter: videoFilterAtStart,
                                     filterTarget: filterTargetAtStart,
                                     captureSettings: settingsAtStart,
                                     isPortrait: portraitAtStart)
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }

            // Микрофон и аудиосессия нужны только на время записи.
            try? self.attachAudioInput()

            if !useRealtimeComposite && videoFilterAtStart == .original && self.realtimeVideoOutputsReady {
                self.removeRealtimeOutputs()
            }

            if useRealtimeComposite && !self.realtimeVideoOutputsReady {
                do {
                    try self.configureRealtimeOutputs()
                } catch {
                    self.updateOnMain {
                        self.isRecording = false
                        self.stopRecordingTimer()
                        self.errorMessage = error.localizedDescription
                    }
                    return
                }
            }

            guard !useRealtimeComposite || self.realtimeVideoOutputsReady else {
                self.updateOnMain {
                    self.isRecording = false
                    self.stopRecordingTimer()
                    self.errorMessage = "Не удалось подготовить синхронный захват камер."
                }
                return
            }

            self.applyInterfaceOrientation(orientationAtStart, forceCaptureOutputs: true)

            self.recordingElements = elements
            self.recordingPipOffsetFraction = pipOffsetFraction
            self.recordingLock.lock()
            self.isUsingRealtimeRecorder = false
            self.recordingLock.unlock()

            self.recordingLayout = layoutAtStart
            self.recordingShape = shapeAtStart
            self.recordingSplitOrientation = splitOrientationAtStart
            self.recordingSplitRatio = splitRatioAtStart
            self.recordingCamerasSwapped = swappedAtStart
            self.recordingImportedVideoURL = importedVideoAtStart

            if useRealtimeComposite {
                let size = settingsAtStart.outputSize(isPortrait: portraitAtStart)
                do {
                    let url = Self.tempMovieURL(camera: "live-composite")
                    let recorder = try RealtimeCompositeRecorder(url: url,
                                                                 renderSize: size,
                                                                 frameRate: settingsAtStart.frameRate,
                                                                 audioQuality: settingsAtStart.audioQuality)
                    self.recordingLock.lock()
                    self.realtimeRecorder = recorder
                    self.isUsingRealtimeRecorder = true
                    self.recordingLock.unlock()
                    self.realtimeWarmupDeadline = Date().addingTimeInterval(0.35)
                } catch {
                    self.recordingLock.lock()
                    self.isUsingRealtimeRecorder = false
                    self.recordingLock.unlock()
                    self.updateOnMain {
                        self.isRecording = false
                        self.stopRecordingTimer()
                        self.errorMessage = error.localizedDescription
                    }
                    return
                }
                return
            }

            self.recordingLock.lock()
            self.recordedURLs.removeAll()
            self.recordingError = nil
            self.expectedRecordingCount = 2
            self.receivedRecordingCallbacks = 0
            self.recordingLock.unlock()

            let backURL = Self.tempMovieURL(camera: "back")
            let frontURL = Self.tempMovieURL(camera: "front")
            self.recordingBackURL = backURL
            self.recordingFrontURL = frontURL

            let backDelegate = MovieCaptureDelegate(camera: .back)
            let frontDelegate = MovieCaptureDelegate(camera: .front)
            backDelegate.completion = { [weak self] camera, url, error in
                self?.handleMovieFinished(camera: camera, url: url, error: error)
            }
            frontDelegate.completion = { [weak self] camera, url, error in
                self?.handleMovieFinished(camera: camera, url: url, error: error)
            }
            self.recordingDelegates = [backDelegate, frontDelegate]

            self.backMovieOutput.startRecording(to: backURL, recordingDelegate: backDelegate)
            self.frontMovieOutput.startRecording(to: frontURL, recordingDelegate: frontDelegate)
        }
    }

    /// Останавливает запись и склеивает оба клипа в один файл.
    func stopRecording(elements: [DrawingElement]? = nil) {
        guard isRecording else { return }
        recordingLock.lock()
        let recordingStartDate = self.recordingStartDate ?? Date()
        recordingLock.unlock()
        let stopTime = Date().timeIntervalSince(recordingStartDate)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if let elements {
                self.recordingElements = elements
                self.recordingLock.lock()
                self.recordingDrawingKeyframes.append(
                    DrawingElementsKeyframe(time: stopTime, elements: elements)
                )
                self.recordingLock.unlock()
            }
            self.recordingLock.lock()
            let useRealtimeComposite = self.isUsingRealtimeRecorder
            self.recordingLock.unlock()
            if useRealtimeComposite {
                guard let recorder = self.realtimeRecorder else {
                    self.updateOnMain {
                        self.isRecording = false
                        self.stopRecordingTimer()
                        self.errorMessage = CameraError.videoMergeFailed.errorDescription
                    }
                    self.sessionQueue.async { self.resetRecordingState() }
                    return
                }
                self.recordingLock.lock()
                self.isUsingRealtimeRecorder = false
                self.recordingLock.unlock()
                self.realtimeCaptureQueue.sync {}
                self.realtimeWriterQueue.async { [weak self] in
                    recorder.finish { [weak self] result in
                        guard let self else { return }
                        switch result {
                        case .success(let url):
                            self.updateOnMain {
                                self.lastMergedVideoURL = url
                                self.isRecording = false
                                self.stopRecordingTimer()
                            }
                        case .failure(let error):
                            self.updateOnMain {
                                self.isRecording = false
                                self.stopRecordingTimer()
                                self.errorMessage = error.localizedDescription
                            }
                        }
                        self.sessionQueue.async { self.resetRecordingState() }
                    }
                }
                return
            }
            if self.backMovieOutput.isRecording { self.backMovieOutput.stopRecording() }
            if self.frontMovieOutput.isRecording { self.frontMovieOutput.stopRecording() }
        }
    }

    func updatePipOffsetFraction(_ offsetFraction: CGSize, widthFraction: CGFloat? = nil) {
        guard isRecording else { return }
        recordingLock.lock()
        defer { recordingLock.unlock() }
        guard let recordingStartDate else { return }
        let time = Date().timeIntervalSince(recordingStartDate)
        let width = widthFraction ?? recordingPipWidthFraction
        if let previous = recordingPipPositionKeyframes.last,
           time - previous.time < 0.025,
           abs(previous.offsetFraction.width - offsetFraction.width) < 0.0005,
           abs(previous.offsetFraction.height - offsetFraction.height) < 0.0005,
           abs(previous.widthFraction - width) < 0.0005 {
            return
        }
        recordingPipPositionKeyframes.append(
            PipPositionKeyframe(time: time, offsetFraction: offsetFraction, widthFraction: width)
        )
        recordingPipOffsetFraction = offsetFraction
        recordingPipWidthFraction = width
    }

    func updateRecordingLayout(layout: CaptureLayout,
                               shape: PipShape,
                               splitOrientation: SplitOrientation,
                               splitRatio: CGFloat,
                               isSecondaryCameraVisible: Bool) {
        guard isRecording else { return }
        recordingLock.lock()
        defer { recordingLock.unlock() }
        guard let recordingStartDate else { return }
        let time = Date().timeIntervalSince(recordingStartDate)
        if let previous = recordingLayoutKeyframes.last,
           previous.layout == layout,
           previous.shape == shape,
           previous.splitOrientation == splitOrientation,
           previous.isSecondaryCameraVisible == isSecondaryCameraVisible,
           abs(previous.splitRatio - splitRatio) < 0.0005 {
            return
        }
        recordingLayoutKeyframes.append(CaptureLayoutKeyframe(time: time,
                                                              layout: layout,
                                                              shape: shape,
                                                              splitOrientation: splitOrientation,
                                                              splitRatio: splitRatio,
                                                              isSecondaryCameraVisible: isSecondaryCameraVisible))
    }

    func updateRecordingElements(_ elements: [DrawingElement]) {
        guard isRecording else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.recordingElements = elements
            self.recordingLock.lock()
            let updateTime: TimeInterval
            if let start = self.recordingStartDate {
                updateTime = Date().timeIntervalSince(start)
            } else {
                updateTime = 0
            }
            if self.recordingDrawingKeyframes.last?.elements != elements {
                self.recordingDrawingKeyframes.append(
                    DrawingElementsKeyframe(time: updateTime, elements: elements)
                )
            }
            self.recordingLock.unlock()
        }
    }

    func updatePhotoOverlay(offsetFraction: CGSize,
                            widthFraction: CGFloat,
                            innerScale: CGFloat = 1,
                            innerOffsetFraction: CGSize = .zero,
                            opacity: CGFloat = 1) {
        guard isRecording else { return }
        recordingLock.lock()
        defer { recordingLock.unlock() }
        guard let recordingStartDate else { return }
        let time = Date().timeIntervalSince(recordingStartDate)
        if let previous = recordingPhotoOverlayKeyframes.last,
           previous.imageID == recordingPhotoOverlayID,
           time - previous.time < 0.025,
           abs(previous.offsetFraction.width - offsetFraction.width) < 0.0005,
           abs(previous.offsetFraction.height - offsetFraction.height) < 0.0005,
           abs(previous.widthFraction - widthFraction) < 0.0005,
           abs(previous.innerScale - innerScale) < 0.0005,
           abs(previous.innerOffsetFraction.width - innerOffsetFraction.width) < 0.0005,
           abs(previous.innerOffsetFraction.height - innerOffsetFraction.height) < 0.0005,
           abs(previous.opacity - opacity) < 0.0005 {
            return
        }
        recordingPhotoOverlayOffsetFraction = offsetFraction
        recordingPhotoOverlayWidthFraction = widthFraction
        recordingPhotoOverlayInnerScale = innerScale
        recordingPhotoOverlayInnerOffsetFraction = innerOffsetFraction
        recordingPhotoOverlayOpacity = opacity
        recordingPhotoOverlayKeyframes.append(
            PhotoOverlayKeyframe(time: time,
                                 offsetFraction: offsetFraction,
                                 widthFraction: widthFraction,
                                 image: recordingPhotoOverlay,
                                 imageID: recordingPhotoOverlayID,
                                 innerScale: innerScale,
                                 innerOffsetFraction: innerOffsetFraction,
                                 opacity: opacity)
        )
    }

    private func recordImportedPhotoChange(_ image: UIImage?) {
        guard isRecording else { return }
        recordingLock.lock()
        defer { recordingLock.unlock() }
        guard let recordingStartDate else { return }
        let time = Date().timeIntervalSince(recordingStartDate)
        let imageID = image == nil ? nil : UUID()
        recordingPhotoOverlay = image
        recordingPhotoOverlayID = imageID
        recordingPhotoOverlayKeyframes.append(
            PhotoOverlayKeyframe(time: time,
                                 offsetFraction: recordingPhotoOverlayOffsetFraction,
                                 widthFraction: recordingPhotoOverlayWidthFraction,
                                 image: image,
                                 imageID: imageID,
                                 innerScale: recordingPhotoOverlayInnerScale,
                                 innerOffsetFraction: recordingPhotoOverlayInnerOffsetFraction,
                                 opacity: recordingPhotoOverlayOpacity)
        )
    }

    // MARK: - Настройка сессии (выполняется в sessionQueue)

    private func configureRealtimeOutputs() throws {
        // Состояние могло остаться от прошлой конфигурации сессии.
        if realtimeVideoOutputsReady,
           !session.outputs.contains(backVideoDataOutput) || !session.outputs.contains(frontVideoDataOutput) {
            realtimeVideoOutputsReady = false
            videoDataSynchronizer?.setDelegate(nil, queue: nil)
            videoDataSynchronizer = nil
        }
        guard !realtimeVideoOutputsReady else { return }
        guard let backInput, let frontInput else {
            throw CameraError.connectionFailed
        }

        latestRealtimeBackBuffer = nil
        latestRealtimeFrontBuffer = nil
        lastRealtimeSubmittedBackPTS = .invalid

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        backVideoDataOutput.alwaysDiscardsLateVideoFrames = true
        frontVideoDataOutput.alwaysDiscardsLateVideoFrames = true
        let videoSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        backVideoDataOutput.videoSettings = videoSettings
        frontVideoDataOutput.videoSettings = videoSettings
        guard session.canAddOutput(backVideoDataOutput) else {
            throw CameraError.outputFailed
        }
        session.addOutputWithNoConnections(backVideoDataOutput)
        do {
            guard session.canAddOutput(frontVideoDataOutput) else {
                throw CameraError.outputFailed
            }
            session.addOutputWithNoConnections(frontVideoDataOutput)
            try connect(backInput, to: backVideoDataOutput, camera: .back)
            try connect(frontInput, to: frontVideoDataOutput, camera: .front)
            let orientation = currentInterfaceVideoOrientation()
            for connection in [backVideoDataConnection, frontVideoDataConnection] {
                if let connection, connection.isVideoOrientationSupported {
                    connection.videoOrientation = orientation
                }
            }
            applyStabilization(captureSettings.stabilizationEnabled)

            if let audioInput, let audioPort = audioInput.ports.first(where: { $0.mediaType == .audio }),
               session.canAddOutput(audioDataOutput) {
                session.addOutputWithNoConnections(audioDataOutput)
                let connection = AVCaptureConnection(inputPorts: [audioPort], output: audioDataOutput)
                if session.canAddConnection(connection) {
                    session.addConnection(connection)
                    audioDataOutput.setSampleBufferDelegate(self, queue: realtimeWriterQueue)
                } else {
                    session.removeOutput(audioDataOutput)
                }
            }

            frontVideoDataOutput.setSampleBufferDelegate(nil, queue: nil)
            videoDataSynchronizer = AVCaptureDataOutputSynchronizer(
                dataOutputs: [backVideoDataOutput, frontVideoDataOutput]
            )
            videoDataSynchronizer?.setDelegate(self, queue: realtimeCaptureQueue)
            guard videoDataSynchronizer != nil else {
                throw CameraError.outputFailed
            }
            realtimeVideoOutputsReady = true
        } catch {
            if let backVideoDataConnection {
                session.removeConnection(backVideoDataConnection)
                self.backVideoDataConnection = nil
            }
            if let frontVideoDataConnection {
                session.removeConnection(frontVideoDataConnection)
                self.frontVideoDataConnection = nil
            }
            if session.outputs.contains(backVideoDataOutput) {
                session.removeOutput(backVideoDataOutput)
            }
            if session.outputs.contains(frontVideoDataOutput) {
                session.removeOutput(frontVideoDataOutput)
            }
            if session.outputs.contains(audioDataOutput) {
                audioDataOutput.setSampleBufferDelegate(nil, queue: nil)
                session.removeOutput(audioDataOutput)
            }
            videoDataSynchronizer = nil
            realtimeVideoOutputsReady = false
            throw error
        }
    }

    private func removeRealtimeOutputs() {
        guard realtimeVideoOutputsReady else { return }
        session.beginConfiguration()
        videoDataSynchronizer?.setDelegate(nil, queue: nil)
        videoDataSynchronizer = nil
        if let backVideoDataConnection {
            session.removeConnection(backVideoDataConnection)
            self.backVideoDataConnection = nil
        }
        if let frontVideoDataConnection {
            session.removeConnection(frontVideoDataConnection)
            self.frontVideoDataConnection = nil
        }
        session.removeOutput(backVideoDataOutput)
        session.removeOutput(frontVideoDataOutput)
        if session.outputs.contains(audioDataOutput) {
            audioDataOutput.setSampleBufferDelegate(nil, queue: nil)
            session.removeOutput(audioDataOutput)
        }
        session.commitConfiguration()
        realtimeVideoOutputsReady = false
        latestRealtimeBackBuffer = nil
        latestRealtimeFrontBuffer = nil
    }

    /// Полностью очищает конфигурацию сессии, чтобы повторить настройку с другой камерой.
    private func resetSessionConfiguration() {
        videoDataSynchronizer?.setDelegate(nil, queue: nil)
        videoDataSynchronizer = nil
        audioDataOutput.setSampleBufferDelegate(nil, queue: nil)
        session.beginConfiguration()
        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }
        session.commitConfiguration()
        // Без этого синхронизатор остаётся «готовым», но держит выходы,
        // которых больше нет в сессии, и кадры никогда не приходят.
        realtimeVideoOutputsReady = false
        latestRealtimeBackBuffer = nil
        latestRealtimeFrontBuffer = nil
        lastRealtimeSubmittedBackPTS = .invalid
        backVideoDataConnection = nil
        frontVideoDataConnection = nil
        backMovieConnection = nil
        frontMovieConnection = nil
        backPhotoConnection = nil
        frontPhotoConnection = nil
        backInput = nil
        frontInput = nil
        audioInput = nil
        backCamera = nil
        frontCamera = nil
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // Аудиосессией управляем сами, только на время записи.
        session.automaticallyConfiguresApplicationAudioSession = false
        // Не используем пресеты — формат каждой камеры задаём вручную.
        session.sessionPreset = .inputPriority

        // 1. Выбираем совместимую пару устройств (передняя + задняя).
        let pair = selectMultiCamPair()
        guard let back = pair.back, let front = pair.front else {
            throw CameraError.noCompatibleDevices
        }
        backCamera = back
        frontCamera = front
        backCameraZoomUnit = back.deviceType == .builtInUltraWideCamera ? 0.5 : 1
        backRotationCoordinator = AVCaptureDevice.RotationCoordinator(device: back,
                                                                        previewLayer: backPreviewLayer)
        frontRotationCoordinator = AVCaptureDevice.RotationCoordinator(device: front,
                                                                         previewLayer: frontPreviewLayer)

        // Keep the front stream light enough for MultiCam while honoring the selected rate.
        try configureFormat(for: back,
                           target: captureSettings.resolution.landscapeCaptureTarget,
                           frameRate: captureSettings.frameRate.rawValue)
        try configureFormat(for: front,
                           target: CGSize(width: 640, height: 480),
                           frameRate: captureSettings.frameRate.rawValue)

        // 3. Добавляем входы БЕЗ автоматических соединений.
        let backDeviceInput = try AVCaptureDeviceInput(device: back)
        let frontDeviceInput = try AVCaptureDeviceInput(device: front)
        guard session.canAddInput(backDeviceInput), session.canAddInput(frontDeviceInput) else {
            throw CameraError.inputFailed
        }
        session.addInputWithNoConnections(backDeviceInput)
        session.addInputWithNoConnections(frontDeviceInput)
        backInput = backDeviceInput
        frontInput = frontDeviceInput

        // 4. Добавляем фото-выходы БЕЗ автоматических соединений.
        guard session.canAddOutput(backPhotoOutput), session.canAddOutput(frontPhotoOutput) else {
            throw CameraError.outputFailed
        }
        session.addOutputWithNoConnections(backPhotoOutput)
        session.addOutputWithNoConnections(frontPhotoOutput)

        // 5. Добавляем видео-выходы для записи (тоже без автосоединений).
        guard session.canAddOutput(backMovieOutput), session.canAddOutput(frontMovieOutput) else {
            throw CameraError.outputFailed
        }
        session.addOutputWithNoConnections(backMovieOutput)
        session.addOutputWithNoConnections(frontMovieOutput)

        // 6. Вручную соединяем входы с фото-выходами.
        try connect(backDeviceInput, to: backPhotoOutput, mirrored: false)
        try connect(frontDeviceInput, to: frontPhotoOutput, mirrored: true)

        // 7. Вручную соединяем входы с видео-выходами.
        try connect(backDeviceInput, to: backMovieOutput, camera: .back, mirrored: false)
        // Keep the recorded front-camera track unmirrored; the preview remains
        // mirrored independently on its own connection.
        try connect(frontDeviceInput, to: frontMovieOutput, camera: .front, mirrored: false)

        // 7. Микрофон подключаем только на время записи: в превью
        // активная аудиосессия глушит тактильную отдачу.

        // Подключаем preview-layer к конкретным портам внутри той же транзакции,
        // где добавлены inputs/outputs, как в примере Apple AVMultiCamPiP.
        try connectPreviewLayers()
        applyStabilization(captureSettings.stabilizationEnabled)
    }

    /// Добавляет микрофон и подключает его к обоим видео-выходам.
    /// Если доступа к микрофону нет — записываем видео без звука.
    /// Подключает микрофон на время записи. Соединения создаём вручную,
    /// как и для камер.
    private func attachAudioInput() throws {
        guard audioInput == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let audioDevice = AVCaptureDevice.default(for: .audio),
              let micInput = try? AVCaptureDeviceInput(device: audioDevice) else {
            return
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(micInput) else { return }
        session.addInputWithNoConnections(micInput)
        audioInput = micInput
        guard let audioPort = micInput.ports.first else { return }
        try connect(audioPort, to: backMovieOutput)
        try connect(audioPort, to: frontMovieOutput)
        if realtimeVideoOutputsReady {
            // Выход аудио для композитора мог не попасть в сессию при её
            // настройке: микрофон подключается только на время записи.
            if !session.outputs.contains(audioDataOutput) {
                if session.canAddOutput(audioDataOutput) {
                    session.addOutputWithNoConnections(audioDataOutput)
                }
            }
            if session.outputs.contains(audioDataOutput) {
                let connection = AVCaptureConnection(inputPorts: [audioPort], output: audioDataOutput)
                if session.canAddConnection(connection) {
                    session.addConnection(connection)
                    audioDataOutput.setSampleBufferDelegate(self, queue: realtimeWriterQueue)
                }
            }
        }
        try? configureAudioSession()
    }

    /// Убирает микрофон из сессии после записи и освобождает аудио.
    private func detachAudioInput() {
        guard let micInput = audioInput else {
            deactivateAudioSession()
            return
        }
        audioDataOutput.setSampleBufferDelegate(nil, queue: realtimeWriterQueue)
        session.beginConfiguration()
        let microphoneConnections = session.connections.filter { connection in
            connection.inputPorts.contains { $0.sourceDeviceType == .microphone }
        }
        for connection in microphoneConnections {
            session.removeConnection(connection)
        }
        session.removeInput(micInput)
        if session.outputs.contains(audioDataOutput) {
            session.removeOutput(audioDataOutput)
        }
        session.commitConfiguration()
        audioInput = nil
        deactivateAudioSession()
    }

    // MARK: - Ротация

    /// Подключает превью-слои к сессии и проверяет активность соединений.
    private func connectPreviewLayers() throws {
        guard let back = backInput, let front = frontInput else {
            throw CameraError.connectionFailed
        }
        try connect(back, to: backPreviewLayer)
        try connect(front, to: frontPreviewLayer)
    }

    private func checkPreviewLayersAfterStart() {
        // Через 2 секунды проверяем, получает ли превью видео.
        sessionQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            if !self.frontPreviewLayer.isPreviewing {
                self.updateOnMain { self.errorMessage = "Превью передней камеры не получает видео." }
            }
        }
    }

    private func registerOrientationObserver() {
        guard !orientationObserverRegistered else { return }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        updateVideoOrientationFromDevice()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(deviceOrientationDidChange),
                                               name: UIDevice.orientationDidChangeNotification,
                                               object: nil)
        orientationObserverRegistered = true
    }

    @objc private func deviceOrientationDidChange(_ notification: Notification) {
        updateVideoOrientationFromDevice()
        let orientation = lastVideoOrientation
        sessionQueue.async { [weak self] in
            self?.applyInterfaceOrientation(orientation)
        }
    }

    /// Интерфейс закреплён в портрете, поэтому ориентацию кадра берём
    /// с датчика устройства.
    private func updateVideoOrientationFromDevice() {
        switch UIDevice.current.orientation {
        case .portrait: lastVideoOrientation = .portrait
        case .portraitUpsideDown: lastVideoOrientation = .portraitUpsideDown
        case .landscapeLeft: lastVideoOrientation = .landscapeRight
        case .landscapeRight: lastVideoOrientation = .landscapeLeft
        default: break
        }
    }

    /// Обновляет ориентацию съёмки по датчику прямо перед снимком или записью:
    /// уведомление о повороте могло не дойти, и тогда кадр сохранится
    /// в неверных пропорциях. Вызывать на главном потоке.
    private func refreshCaptureOrientation() {
        updateVideoOrientationFromDevice()
        let orientation = lastVideoOrientation
        let portrait = orientation == .portrait || orientation == .portraitUpsideDown
        guard isPortrait != portrait else { return }
        isPortrait = portrait
        sessionQueue.async { [weak self] in
            self?.applyInterfaceOrientation(orientation)
        }
    }

    private func currentInterfaceVideoOrientation() -> AVCaptureVideoOrientation {
        lastVideoOrientation
    }

    private func applyInterfaceOrientation(_ orientation: AVCaptureVideoOrientation,
                                           forceCaptureOutputs: Bool = false) {
        updateOnMain {
            self.isPortrait = orientation == .portrait || orientation == .portraitUpsideDown
        }

        // Главное превью не поворачиваем: интерфейс закреплён в портрете.
        // PiP-окно поворачивается вслед за устройством.
        let mainLayer = isCamerasSwapped ? frontPreviewLayer : backPreviewLayer
        let secondaryLayer = isCamerasSwapped ? backPreviewLayer : frontPreviewLayer
        if let connection = mainLayer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        if let connection = secondaryLayer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = orientation
        }

        guard forceCaptureOutputs || !isRecording else { return }
        let captureConnections: [AVCaptureConnection?] = [
            backPhotoConnection,
            frontPhotoConnection,
            backVideoDataConnection,
            frontVideoDataConnection
        ]
        for connection in captureConnections {
            if let connection, connection.isVideoOrientationSupported {
                connection.videoOrientation = orientation
            }
        }

        setMovieRotation(backMovieConnection,
                         coordinator: backRotationCoordinator,
                         orientation: orientation)
        setMovieRotation(frontMovieConnection,
                         coordinator: frontRotationCoordinator,
                         orientation: orientation)
    }

    private func setMovieRotation(_ connection: AVCaptureConnection?,
                                  coordinator: AVCaptureDevice.RotationCoordinator?,
                                  orientation: AVCaptureVideoOrientation) {
        guard let connection else { return }
        // Landscape capture should follow the active interface orientation.
        // The horizon-level coordinator angle can choose the opposite landscape
        // direction for the recorded track, making both merged cameras upside down.
        // Keep the already-correct portrait path unchanged.
        if orientation == .landscapeLeft || orientation == .landscapeRight,
           connection.isVideoOrientationSupported {
            connection.videoOrientation = orientation
            return
        }
        if let coordinator {
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
                return
            }
        }
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = orientation
        }
    }

    /// Задняя камера: широкая (1x) или сверхширокоугольная (0,5x).
    enum BackLens: Equatable {
        case wide
        case ultraWide
    }

    /// Экранный зум на единицу зума устройства (у сверхширокой камеры 1.0 = 0,5x).
    private var backCameraZoomUnit: CGFloat = 1
    private var backLens: BackLens = .wide
    /// Есть ли сверхширокоугольная камера, то есть доступен зум 0,5.
    private(set) var hasUltraWideBackCamera = false
    /// Значение зума, выбранное пользователем в жесте.
    private var pendingZoomFactor: CGFloat?

    /// Находит пару «передняя + задняя», которую система разрешает
    /// использовать одновременно.
    private func selectMultiCamPair() -> (back: AVCaptureDevice?, front: AVCaptureDevice?) {
        let fronts = [
            AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front),
            AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        ].compactMap { $0 }
        let back = preferredBackDevice()
        return (back, fronts.first)
    }

    /// Виртуальные камеры в MultiCam недоступны, поэтому 0,5x даёт отдельная
    /// физическая сверхширокоугольная камера.
    private func preferredBackDevice() -> AVCaptureDevice? {
        let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        switch backLens {
        case .ultraWide:
            return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) ?? wide
        case .wide:
            return wide
        }
    }

    private func configureFormat(for device: AVCaptureDevice,
                                 target: CGSize,
                                 frameRate: Int) throws {
        guard let format = bestMultiCamFormat(for: device, target: target, frameRate: frameRate) else {
            throw CameraError.noCompatibleFormat
        }
        try applyFormat(format, to: device, frameRate: frameRate)
    }

    private func applyFormat(_ format: AVCaptureDevice.Format,
                             to device: AVCaptureDevice,
                             frameRate: Int) throws {
        try device.lockForConfiguration()
        device.activeFormat = format
        // Принудительно SDR: на новых iOS HDR-видео в превью может
        // показываться белым экраном (особенно у фронтальной камеры).
        device.activeColorSpace = .sRGB
        device.automaticallyAdjustsVideoHDREnabled = false
        device.isVideoHDREnabled = false
        let fps = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        device.activeVideoMinFrameDuration = fps
        device.activeVideoMaxFrameDuration = fps
        device.unlockForConfiguration()
    }

    /// Selects the closest format supported by MultiCam and the requested frame rate.
    private func bestMultiCamFormat(for device: AVCaptureDevice,
                                    target: CGSize,
                                    frameRate: Int) -> AVCaptureDevice.Format? {
        var bestFormat: AVCaptureDevice.Format?
        var bestScore = CGFloat.greatestFiniteMagnitude

        for format in device.formats {
            // Правило №4: формат должен поддерживать совместную работу камер.
            guard format.isMultiCamSupported else { continue }

            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let size = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))

            let supportsFrameRate = format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= Double(frameRate) && $0.maxFrameRate >= Double(frameRate)
            }
            guard supportsFrameRate else { continue }

            // Близость к 1080p: чем меньше суммарное отклонение, тем лучше.
            let score = abs(size.width - target.width) + abs(size.height - target.height)
            if score < bestScore {
                bestScore = score
                bestFormat = format
            }
        }
        return bestFormat
    }

    private func applyStabilization(_ enabled: Bool) {
        let connections: [AVCaptureConnection?] = [
            backPreviewLayer.connection,
            frontPreviewLayer.connection,
            backMovieConnection,
            frontMovieConnection,
            backVideoDataConnection,
            frontVideoDataConnection
        ]
        for connection in connections {
            guard let connection, connection.isVideoStabilizationSupported else { continue }
            connection.preferredVideoStabilizationMode = enabled ? .standard : .off
        }
    }

    // MARK: - Ручное создание соединений (правило №3)

    private func connect(_ input: AVCaptureDeviceInput,
                         to output: AVCapturePhotoOutput,
                         mirrored: Bool) throws {
        guard let port = input.ports.first else {
            throw CameraError.connectionFailed
        }
        let connection = AVCaptureConnection(inputPorts: [port], output: output)
        guard session.canAddConnection(connection) else {
            throw CameraError.connectionFailed
        }
        session.addConnection(connection)
        if mirrored { frontPhotoConnection = connection } else { backPhotoConnection = connection }
    }

    private func connect(_ input: AVCaptureDeviceInput,
                         to output: AVCaptureMovieFileOutput,
                         camera: MovieCaptureDelegate.Camera,
                         mirrored: Bool) throws {
        guard let port = input.ports.first else {
            throw CameraError.connectionFailed
        }
        let connection = AVCaptureConnection(inputPorts: [port], output: output)
        guard session.canAddConnection(connection) else {
            throw CameraError.connectionFailed
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
        session.addConnection(connection)
        switch camera {
        case .back: backMovieConnection = connection
        case .front: frontMovieConnection = connection
        }
    }

    /// Подключает аудио-порт к видео-выходу (добавляет звуковую дорожку).
    private func connect(_ port: AVCaptureInput.Port,
                         to output: AVCaptureMovieFileOutput) throws {
        let connection = AVCaptureConnection(inputPorts: [port], output: output)
        guard session.canAddConnection(connection) else {
            throw CameraError.connectionFailed
        }
        session.addConnection(connection)
    }

    private func connect(_ input: AVCaptureDeviceInput,
                         to layer: AVCaptureVideoPreviewLayer) throws {
        guard let port = input.ports(for: .video,
                                     sourceDeviceType: input.device.deviceType,
                                     sourceDevicePosition: input.device.position).first else {
            throw CameraError.connectionFailed
        }
        let connection = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
        guard session.canAddConnection(connection) else {
            throw CameraError.connectionFailed
        }
        session.addConnection(connection)
    }

    private func connect(_ input: AVCaptureDeviceInput,
                         to output: AVCaptureVideoDataOutput,
                         camera: MovieCaptureDelegate.Camera) throws {
        guard let port = input.ports(for: .video,
                                     sourceDeviceType: input.device.deviceType,
                                     sourceDevicePosition: input.device.position).first else {
            throw CameraError.connectionFailed
        }
        let connection = AVCaptureConnection(inputPorts: [port], output: output)
        guard session.canAddConnection(connection) else {
            throw CameraError.connectionFailed
        }
        session.addConnection(connection)
        switch camera {
        case .back: backVideoDataConnection = connection
        case .front: frontVideoDataConnection = connection
        }
    }

    // MARK: - Съёмка и склейка

    private func captureAndMerge(elements: [DrawingElement],
                                 pipOffsetFraction: CGSize,
                                 photoOverlayOffsetFraction: CGSize,
                                 photoOverlayWidthFraction: CGFloat,
                                 photoOverlayInnerScale: CGFloat,
                                 photoOverlayInnerOffsetFraction: CGSize,
                                 photoOverlayOpacity: CGFloat,
                                 videoFilter: VideoFilter,
                                 filterTarget: VideoFilterTarget,
                                 outputAspectRatio: CGFloat,
                                 timestamp: Date?) async throws -> UIImage {
        defer { clearPhotoDelegates() }

        // Запускаем оба захвата подряд. Вызовы возвращаются мгновенно,
        // а сенсоры камер срабатывают практически одновременно.
        async let frontData = capturePhoto(from: frontPhotoOutput)
        async let backData = capturePhoto(from: backPhotoOutput)
        let (front, back) = try await (frontData, backData)

        guard let backImage = UIImage(data: back) else {
            throw CameraError.captureFailed
        }

        guard let frontImage = UIImage(data: front) else {
            throw CameraError.captureFailed
        }

        let mirroredFrontImage = PhotoMerger.mirrorHorizontally(frontImage)
        let primary = isCamerasSwapped ? mirroredFrontImage : backImage
        let secondary = isCamerasSwapped ? backImage : mirroredFrontImage
        return try PhotoMerger.merge(back: primary,
                                 front: secondary,
                                 layout: layout,
                                 shape: pipShape,
                                 splitOrientation: splitOrientation,
                                 splitRatio: splitRatio,
                                 isSecondaryCameraVisible: isSecondaryCameraVisible,
                                 videoFilter: videoFilter,
                                 filterTarget: filterTarget,
                                 outputAspectRatio: outputAspectRatio,
                                 pipOffsetFraction: pipOffsetFraction,
                                 photoOverlay: importedPhoto,
                                 photoOverlayOffsetFraction: photoOverlayOffsetFraction,
                                 photoOverlayWidthFraction: photoOverlayWidthFraction,
                                 photoOverlayInnerScale: photoOverlayInnerScale,
                                 photoOverlayInnerOffsetFraction: photoOverlayInnerOffsetFraction,
                                 photoOverlayOpacity: photoOverlayOpacity,
                                 frontExposureEV: frontNightModeActive ? Self.frontNightExposureEV : 0,
                                 elements: elements,
                                 timestamp: timestamp)
    }

    private func capturePhoto(from output: AVCapturePhotoOutput) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = PhotoCaptureDelegate()
            delegate.completion = { [weak self] data, error in
                if let self {
                    self.releasePhotoDelegate(delegate)
                }
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? CameraError.captureFailed)
                }
            }
            retainPhotoDelegate(delegate)
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: delegate)
        }
    }

    private func retainPhotoDelegate(_ delegate: PhotoCaptureDelegate) {
        delegatesLock.lock()
        activePhotoDelegates.append(delegate)
        delegatesLock.unlock()
    }

    private func releasePhotoDelegate(_ delegate: PhotoCaptureDelegate) {
        delegatesLock.lock()
        activePhotoDelegates.removeAll { $0 === delegate }
        delegatesLock.unlock()
    }

    private func clearPhotoDelegates() {
        delegatesLock.lock()
        activePhotoDelegates.removeAll()
        delegatesLock.unlock()
    }

    // MARK: - Завершение видеозаписи

    private func handleMovieFinished(camera: MovieCaptureDelegate.Camera, url: URL?, error: Error?) {
        recordingLock.lock()
        receivedRecordingCallbacks += 1
        if let error {
            let nsError = error as NSError
            let finishedSuccessfully = (nsError.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? NSNumber)?.boolValue == true
            let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            let cameraName: String
            switch camera {
            case .back: cameraName = "задней"
            case .front: cameraName = "фронтальной"
            }
            if finishedSuccessfully, let url,
               FileManager.default.fileExists(atPath: url.path) {
                recordedURLs[camera] = url
            } else {
                let details = [
                    nsError.localizedFailureReason,
                    nsError.localizedRecoverySuggestion,
                    underlyingError?.localizedDescription,
                    underlyingError.map { "\($0.domain), код \($0.code)" }
                ].compactMap { $0 }.joined(separator: "; ")
                let message = [
                    "Сбой записи \(cameraName) камеры: \(nsError.localizedDescription) (\(nsError.domain), код \(nsError.code))",
                    details.isEmpty ? nil : details
                ].compactMap { $0 }.joined(separator: ". ")
                recordingError = NSError(
                    domain: "DualCamera.MovieCapture.\(nsError.domain)",
                    code: nsError.code,
                    userInfo: [NSLocalizedDescriptionKey: message,
                               NSUnderlyingErrorKey: nsError]
                )
            }
        } else if let url {
            recordedURLs[camera] = url
        }
        let allDone = receivedRecordingCallbacks >= expectedRecordingCount
        let urls = recordedURLs
        let firstError = recordingError
        recordingLock.unlock()

        guard allDone else { return }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.finishRecording(urls: urls, error: firstError)
        }
    }

    private func finishRecording(urls: [MovieCaptureDelegate.Camera: URL], error: Error?) {
        recordingDelegates.removeAll()
        updateOnMain { self.stopRecordingTimer() }

        if let error {
            updateOnMain {
                self.isRecording = false
                self.errorMessage = error.localizedDescription
            }
            resetRecordingState()
            return
        }

        guard let backURL = urls[.back], let frontURL = urls[.front] else {
            updateOnMain {
                self.isRecording = false
                self.errorMessage = CameraError.videoMergeFailed.errorDescription
            }
            resetRecordingState()
            return
        }

        recordingLock.lock()
        let pipKeyframes = recordingPipPositionKeyframes
        let layoutKeyframes = recordingLayoutKeyframes
        let filterKeyframes = recordingFilterKeyframes
        let cameraSwapKeyframes = recordingCameraSwapKeyframes
        let drawingKeyframes = recordingDrawingKeyframes
        let photoKeyframes = recordingPhotoOverlayKeyframes
        let outputPhotoOverlay = recordingPhotoOverlay
        let outputPhotoOffset = recordingPhotoOverlayOffsetFraction
        let outputPhotoWidth = recordingPhotoOverlayWidthFraction
        recordingLock.unlock()
        let outputLayout = recordingLayout
        let outputShape = recordingShape
        let outputSplitOrientation = recordingSplitOrientation
        let outputOffset = recordingPipOffsetFraction
        let outputImportedVideoURL = recordingImportedVideoURL
        let outputCamerasSwapped = recordingCamerasSwapped
        let outputElements = recordingElements
        let outputCaptureSettings = recordingCaptureSettings
        let outputSize = recordingOutputSize
        // Склейку выполняем в фоне, чтобы не блокировать очередь сессии.
        Task { [weak self] in
            guard let self else { return }
            do {
                // Второй слой: импортированное видео или запись передней камеры.
                let frontSource = outputImportedVideoURL ?? frontURL
                let primaryURL = outputCamerasSwapped ? frontSource : backURL
                let secondaryURL = outputCamerasSwapped ? backURL : frontSource
                let merged = try await VideoMerger.merge(
                    back: primaryURL,
                    front: secondaryURL,
                    layout: outputLayout,
                    shape: outputShape,
                    splitOrientation: outputSplitOrientation,
                    outputSize: outputSize,
                    frameRate: outputCaptureSettings.frameRate,
                    mirrorFrontCamera: outputImportedVideoURL == nil,
                    pipOffsetFraction: outputOffset,
                    pipWidthFraction: 0.3,
                    pipPositionKeyframes: pipKeyframes,
                    layoutKeyframes: layoutKeyframes,
                    cameraSwapKeyframes: cameraSwapKeyframes,
                    filterKeyframes: filterKeyframes,
                    initialCamerasSwapped: outputCamerasSwapped,
                    drawingKeyframes: drawingKeyframes,
                    photoOverlay: outputPhotoOverlay,
                    photoOverlayOffsetFraction: outputPhotoOffset,
                    photoOverlayWidthFraction: outputPhotoWidth,
                    photoOverlayKeyframes: photoKeyframes,
                    elements: outputElements,
                    dateTimeEnabled: outputCaptureSettings.dateTimeEnabled,
                    timestampStartDate: recordingStartDate
                )
                // Удаляем исходные клипы — остаётся только объединённый файл.
                Self.removeTemporaryFiles([backURL, frontURL])
                self.updateOnMain {
                    self.lastMergedVideoURL = merged
                    self.isRecording = false
                }
            } catch {
                self.updateOnMain {
                    self.isRecording = false
                    self.errorMessage = error.localizedDescription
                }
            }
            self.sessionQueue.async { self.resetRecordingState() }
        }
    }

    private func resetRecordingState() {
        // Запись закончилась: убираем микрофон и освобождаем аудиосессию,
        // иначе она глушит тактильную отдачу в превью.
        detachAudioInput()
        recordingLock.lock()
        realtimeWarmupDeadline = nil
        recordedURLs.removeAll()
        recordingError = nil
        recordingPipPositionKeyframes.removeAll()
        recordingLayoutKeyframes.removeAll()
        recordingFilterKeyframes.removeAll()
        recordingCameraSwapKeyframes.removeAll()
        recordingDrawingKeyframes.removeAll()
        recordingPhotoOverlayKeyframes.removeAll()
        recordingPhotoOverlay = nil
        recordingPhotoOverlayID = nil
        recordingPhotoOverlayOffsetFraction = .zero
        recordingPhotoOverlayWidthFraction = 0.3
        recordingPhotoOverlayInnerScale = 1
        recordingPhotoOverlayInnerOffsetFraction = .zero
        recordingPhotoOverlayOpacity = 1
        expectedRecordingCount = 0
        receivedRecordingCallbacks = 0
        isUsingRealtimeRecorder = false
        realtimeRecorder = nil
        recordingLock.unlock()
        recordingDelegates.removeAll()
        recordingBackURL = nil
        recordingFrontURL = nil
        recordingElements = []
        recordingPipOffsetFraction = .zero
        recordingPipWidthFraction = 0.3
        recordingImportedVideoURL = nil
        recordingLayout = .pip
        recordingShape = .rectangle
        recordingSplitOrientation = .vertical
        recordingSplitRatio = SplitRatio.defaultValue
        recordingCamerasSwapped = false
    }

    // MARK: - Таймер записи (главный поток)

    private func startRecordingTimer(initialOffsetFraction: CGSize,
                                     widthFraction: CGFloat,
                                     elements: [DrawingElement],
                                     photoOffsetFraction: CGSize,
                                     photoWidthFraction: CGFloat,
                                     photoInnerScale: CGFloat,
                                     photoInnerOffsetFraction: CGSize,
                                     photoOpacity: CGFloat,
                                     photo: UIImage?,
                                     camerasSwapped: Bool,
                                     layout: CaptureLayout,
                                     shape: PipShape,
                                     splitOrientation: SplitOrientation,
                                     splitRatio: CGFloat,
                                     isSecondaryCameraVisible: Bool,
                                     videoFilter: VideoFilter,
                                     filterTarget: VideoFilterTarget,
                                     captureSettings: CameraSettingsSnapshot,
                                     isPortrait: Bool) {
        recordingStartDate = Date()
        recordingPipWidthFraction = widthFraction
        recordingCaptureSettings = captureSettings
        recordingOutputSize = captureSettings.outputSize(isPortrait: isPortrait)
        recordingLock.lock()
        recordingPipPositionKeyframes = [
            PipPositionKeyframe(time: 0,
                                offsetFraction: initialOffsetFraction,
                                widthFraction: widthFraction)
        ]
        recordingLayoutKeyframes = [
            CaptureLayoutKeyframe(time: 0,
                                  layout: layout,
                                  shape: shape,
                                  splitOrientation: splitOrientation,
                                  splitRatio: splitRatio,
                                  isSecondaryCameraVisible: isSecondaryCameraVisible)
        ]
        recordingFilterKeyframes = [
            VideoFilterKeyframe(time: 0, filter: videoFilter, target: filterTarget)
        ]
        recordingCameraSwapKeyframes = [
            CameraSwapKeyframe(time: 0, isSwapped: camerasSwapped)
        ]
        recordingDrawingKeyframes = [
            DrawingElementsKeyframe(time: 0, elements: elements)
        ]
        recordingPhotoOverlay = photo
        recordingPhotoOverlayID = photo == nil ? nil : UUID()
        recordingPhotoOverlayOffsetFraction = photoOffsetFraction
        recordingPhotoOverlayWidthFraction = photoWidthFraction
        recordingPhotoOverlayInnerScale = photoInnerScale
        recordingPhotoOverlayInnerOffsetFraction = photoInnerOffsetFraction
        recordingPhotoOverlayOpacity = photoOpacity
        recordingPhotoOverlayKeyframes = [
            PhotoOverlayKeyframe(time: 0,
                                 offsetFraction: photoOffsetFraction,
                                 widthFraction: photoWidthFraction,
                                 image: photo,
                                 imageID: recordingPhotoOverlayID,
                                 innerScale: photoInnerScale,
                                 innerOffsetFraction: photoInnerOffsetFraction,
                                 opacity: photoOpacity)
        ]
        recordingLock.unlock()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let start = self.recordingStartDate else { return }
            self.recordingDuration = Date().timeIntervalSince(start)
        }
        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartDate = nil
        recordingDuration = 0
    }

    // MARK: - Временные файлы

    private static func tempMovieURL(camera: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dualcamera-\(camera)-\(UUID().uuidString).mov")
    }

    private static func removeTemporaryFiles(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Потокобезопасные помощники

    /// Выполняет блок на главном потоке (правило №5).
    private func updateOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    private func setError(_ error: CameraError) {
        updateOnMain { self.errorMessage = error.errorDescription }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard output === audioDataOutput else { return }
        recordingLock.lock()
        let recorder = isUsingRealtimeRecorder ? realtimeRecorder : nil
        recordingLock.unlock()
        recorder?.appendAudio(sampleBuffer)
    }

    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        let backData = synchronizedDataCollection.synchronizedData(for: backVideoDataOutput)
            as? AVCaptureSynchronizedSampleBufferData
        let frontData = synchronizedDataCollection.synchronizedData(for: frontVideoDataOutput)
            as? AVCaptureSynchronizedSampleBufferData
        let backDropped = backData?.sampleBufferWasDropped ?? true
        let frontDropped = frontData?.sampleBufferWasDropped ?? true

        recordingLock.lock()
        let activeRecorder = isUsingRealtimeRecorder ? realtimeRecorder : nil
        recordingLock.unlock()
        filterStateLock.lock()
        let filter = captureVideoFilter
        let previewCamera = filterPreviewCamera
        filterStateLock.unlock()
        let nightMode = frontNightModeActive
        guard activeRecorder != nil || filter != .original || nightMode else { return }
        activeRecorder?.recordSynchronizationEvent(backPresent: backData != nil,
                                                   frontPresent: frontData != nil,
                                                   backDropped: backDropped,
                                                   frontDropped: frontDropped)

        var backPTS = CMTime.invalid
        var currentBackBuffer: CVPixelBuffer?
        var currentFrontBuffer: CVPixelBuffer?
        if let backData, !backDropped,
           let buffer = CMSampleBufferGetImageBuffer(backData.sampleBuffer) {
            latestRealtimeBackBuffer = buffer
            currentBackBuffer = buffer
            backPTS = CMSampleBufferGetPresentationTimeStamp(backData.sampleBuffer)
            let size = CGSize(width: CVPixelBufferGetWidth(buffer),
                              height: CVPixelBufferGetHeight(buffer))
            if size != publishedBackBufferSize {
                publishedBackBufferSize = size
                updateOnMain { self.lastBackBufferSize = size }
            }
        }
        if let frontData, !frontDropped,
           let buffer = CMSampleBufferGetImageBuffer(frontData.sampleBuffer) {
            latestRealtimeFrontBuffer = buffer
            currentFrontBuffer = buffer
        }

        if currentBackBuffer != nil, lensSwitchSnapshot != nil, !lensSwitchInFlight {
            updateOnMain { self.lensSwitchSnapshot = nil }
        }

        // Превью: выбранный фильтр и/или ночной подъём экспозиции фронтальной камеры.
        let backNeedsImage = filter != .original && previewCamera == .back
        let frontNeedsImage = nightMode || (filter != .original && previewCamera == .front)
        if backNeedsImage, let buffer = currentBackBuffer {
            schedulePreviewImage(buffer, filter: filter, camera: .back, exposureEV: 0)
        }
        if frontNeedsImage, let buffer = currentFrontBuffer {
            let frontFilter: VideoFilter = previewCamera == .front ? filter : .original
            schedulePreviewImage(buffer,
                                 filter: frontFilter,
                                 camera: .front,
                                 exposureEV: nightMode ? Self.frontNightExposureEV : 0)
        }

        guard let activeRecorder else { return }
        // Пропускаем первые кадры: камера ещё не вышла на рабочую экспозицию.
        if let deadline = realtimeWarmupDeadline {
            guard Date() >= deadline else { return }
            realtimeWarmupDeadline = nil
        }
        guard let backBuffer = latestRealtimeBackBuffer,
              let frontBuffer = latestRealtimeFrontBuffer,
              backPTS.isValid,
              !lastRealtimeSubmittedBackPTS.isValid
                || CMTimeCompare(backPTS, lastRealtimeSubmittedBackPTS) > 0 else { return }
        recordingLock.lock()
        let state = realtimeFrameStateLocked()
        recordingLock.unlock()
        guard realtimeWriterSlots.wait(timeout: .now()) == .success else { return }
        lastRealtimeSubmittedBackPTS = backPTS
        realtimeWriterQueue.async { [realtimeWriterSlots] in
            defer { realtimeWriterSlots.signal() }
            activeRecorder.appendVideo(back: backBuffer, front: frontBuffer, time: backPTS, state: state)
        }
    }

    /// Готовит кадр превью в фоне: фильтр и/или подъём экспозиции.
    private func schedulePreviewImage(_ buffer: CVPixelBuffer,
                                      filter: VideoFilter,
                                      camera: MovieCaptureDelegate.Camera,
                                      exposureEV: Float) {
        guard filterPreviewSlot.wait(timeout: .now()) == .success else { return }
        let previewSlot = filterPreviewSlot
        filterPreviewQueue.async { [weak self, previewSlot] in
            defer { previewSlot.signal() }
            guard let self else { return }
            do {
                let image = try self.makeFilteredPreviewImage(buffer,
                                                              filter: filter,
                                                              exposureEV: exposureEV)
                self.updateOnMain {
                    // Кадр мог устареть, пока он готовился.
                    self.filterStateLock.lock()
                    let isCurrent = exposureEV > 0 || (self.captureVideoFilter == filter
                        && self.filterPreviewCamera == camera)
                    self.filterStateLock.unlock()
                    guard isCurrent else { return }
                    if camera == .back {
                        self.backFilteredPreviewImage = image
                    } else {
                        self.frontFilteredPreviewImage = image
                    }
                }
            } catch {
                self.reportFilterPreviewError(error)
            }
        }
    }

    private func makeFilteredPreviewImage(_ buffer: CVPixelBuffer,
                                          filter: VideoFilter,
                                          exposureEV: Float) throws -> UIImage {
        var source = CIImage(cvPixelBuffer: buffer)
        if exposureEV > 0 {
            source = source.applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: exposureEV
            ])
        }
        let filtered = try filter.applying(to: source)
        let maxDimension = max(filtered.extent.width, filtered.extent.height)
        let scale = min(1, VideoFilter.previewMaxDimension / max(maxDimension, 1))
        let preview = filtered.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = preview.extent.integral
        guard extent.width > 0, extent.height > 0,
              let cgImage = filterPreviewContext.createCGImage(preview, from: extent) else {
            throw CameraError.filterProcessingFailed
        }
        return UIImage(cgImage: cgImage)
    }

    private func reportFilterPreviewError(_ error: Error) {
        filterStateLock.lock()
        let shouldReport = !filterPreviewErrorReported
        filterPreviewErrorReported = true
        filterStateLock.unlock()
        guard shouldReport else { return }
        updateOnMain { self.errorMessage = error.localizedDescription }
    }

    private func realtimeFrameStateLocked() -> RealtimeCompositeRecorder.FrameState {
        let pip = recordingPipPositionKeyframes.last
        let layout = recordingLayoutKeyframes.last
        let filter = recordingFilterKeyframes.last
        let cameraSwap = recordingCameraSwapKeyframes.last
        let photo = recordingPhotoOverlayKeyframes.last
        let drawing = recordingDrawingKeyframes.last?.elements ?? recordingElements
        return RealtimeCompositeRecorder.FrameState(
            layout: layout?.layout ?? recordingLayout,
            pipShape: layout?.shape ?? recordingShape,
            splitOrientation: layout?.splitOrientation ?? recordingSplitOrientation,
            splitRatio: layout?.splitRatio ?? recordingSplitRatio,
            isSecondaryCameraVisible: layout?.isSecondaryCameraVisible ?? true,
            videoFilter: filter?.filter ?? .original,
            filterTarget: filter?.target ?? .primary,
            camerasSwapped: cameraSwap?.isSwapped ?? recordingCamerasSwapped,
            pipOffsetFraction: pip?.offsetFraction ?? recordingPipOffsetFraction,
            pipWidthFraction: pip?.widthFraction ?? recordingPipWidthFraction,
            photo: photo?.image,
            photoOffsetFraction: photo?.offsetFraction ?? recordingPhotoOverlayOffsetFraction,
            photoWidthFraction: photo?.widthFraction ?? recordingPhotoOverlayWidthFraction,
            photoInnerScale: photo?.innerScale ?? recordingPhotoOverlayInnerScale,
            photoInnerOffsetFraction: photo?.innerOffsetFraction ?? recordingPhotoOverlayInnerOffsetFraction,
            photoOpacity: photo?.opacity ?? recordingPhotoOverlayOpacity,
            frontExposureEV: frontNightModeActive ? Self.frontNightExposureEV : 0,
            drawing: drawing,
            dateTimeEnabled: recordingCaptureSettings.dateTimeEnabled,
            recordingStartDate: recordingStartDate
        )
    }
}
