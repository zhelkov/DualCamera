import AVFoundation
import UIKit
import CoreImage
import Observation
import Combine

final class FrontCameraPreviewStore: ObservableObject {
    @Published var image: UIImage?
}

/// Менеджер камеры. Отвечает за одновременную съёмку с двух камер
/// через `AVCaptureMultiCamSession`.
///
/// Ключевые правила:
/// - Вся работа с сессией выполняется в последовательной очереди `sessionQueue`.
/// - Свойства, которые читает UI, обновляются только на главном потоке.
/// - Соединения создаются вручную через `AVCaptureConnection`,
///   а не автоматически сессией.
@Observable
final class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

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
    /// Длительность текущей записи.
    private(set) var recordingDuration: TimeInterval = 0
    /// Текущая раскладка превью (сплит или картинка в картинке).
    var layout: CaptureLayout = .splitScreen
    /// Ориентация сплита: вертикально или горизонтально.
    var splitOrientation: SplitOrientation = .vertical
    /// Поменяны ли местами передняя и задняя камеры.
    var isCamerasSwapped = false
    /// Форма окна «картинка в картинке».
    var pipShape: PipShape = .rectangle
    /// Текущий зум основной камеры.
    private(set) var zoomFactor: CGFloat = 1.0
    /// Доступный диапазон зума.
    private(set) var minZoomFactor: CGFloat = 1.0
    private(set) var maxZoomFactor: CGFloat = 1.0
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
    private var backInput: AVCaptureDeviceInput?
    private var frontInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?

    private let backPhotoOutput = AVCapturePhotoOutput()
    private let frontPhotoOutput = AVCapturePhotoOutput()
    private let backMovieOutput = AVCaptureMovieFileOutput()
    private let frontMovieOutput = AVCaptureMovieFileOutput()
    private let frontVideoDataOutput = AVCaptureVideoDataOutput()
    private let frontVideoOutputQueue = DispatchQueue(label: "com.dualcamera.front-probe", qos: .userInitiated)
    private let frontProbeImageContext = CIContext()
    let frontPreviewStore = FrontCameraPreviewStore()
    private var lastFrontProbeImageUpdate: UInt64 = 0

    // MARK: - Ротация

    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var frontRotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var backPhotoConnection: AVCaptureConnection?
    private var frontPhotoConnection: AVCaptureConnection?
    private var backMovieConnection: AVCaptureConnection?
    private var frontMovieConnection: AVCaptureConnection?
    private var frontVideoDataConnection: AVCaptureConnection?

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
    private var recordingDrawingKeyframes: [DrawingElementsKeyframe] = []
    private var recordingPipPhoto: UIImage?
    private var recordingImportedVideoURL: URL?
    private var recordingLayout: CaptureLayout = .splitScreen
    private var recordingShape: PipShape = .rectangle
    private var recordingSplitOrientation: SplitOrientation = .vertical
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

        sessionQueue.async { [weak self] in
            guard let self else { return }

            // Настраиваем аудио-сессию для записи звука.
            // Если не получилось — камера всё равно заработает (видео без звука).
            try? self.configureAudioSession()

            do {
                try self.configureSession()
                // Подключаем превью-слои до запуска сессии.
                self.connectPreviewLayers()
                self.session.startRunning()
                // Ротация превью и соединений под устройство.
                self.configureRotationCoordinators()
                // Характеристики читаем на очереди сессии, применяем на главной.
                let minZoom = self.backCamera?.minAvailableVideoZoomFactor ?? 1
                let maxZoom = self.backCamera?.maxAvailableVideoZoomFactor ?? 1
                let hasTorch = self.backCamera?.hasTorch ?? false
                let currentZoom = self.backCamera?.videoZoomFactor ?? 1
                self.updateOnMain {
                    self.isConfigured = true
                    self.isRunning = self.session.isRunning
                    self.errorMessage = nil
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
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            // Возобновляем аудио-сессию (например, после возврата из фона).
            try? self.configureAudioSession()
            self.session.startRunning()
            self.updateOnMain { self.isRunning = self.session.isRunning }
        }
    }

    func stopRunning() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
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
                                     options: [.defaultToSpeaker])
        try audioSession.setActive(true)
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Снимает фото одновременно с обеих камер, склеивает и накладывает рисунок.
    func captureBothCameras(elements: [DrawingElement] = [],
                            pipOffsetFraction: CGSize = .zero,
                            pipWidthFraction: CGFloat = 0.3) {
        guard isConfigured, !isCapturing else { return }
        updateOnMain { self.isCapturing = true }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            Task {
                do {
                    let merged = try await self.captureAndMerge(elements: elements,
                                                                pipOffsetFraction: pipOffsetFraction,
                                                                pipWidthFraction: pipWidthFraction)
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

    func clearMergedPhoto() {
        updateOnMain { self.lastMergedPhoto = nil }
    }

    func clearMergedVideo() {
        updateOnMain { self.lastMergedVideoURL = nil }
    }

    // MARK: - Импортированные медиа

    /// Подставляет фото из библиотеки вместо передней камеры.
    func setImportedPhoto(_ image: UIImage?) {
        updateOnMain { self.importedPhoto = image }
    }

    /// Подставляет видео из библиотеки вместо передней камеры.
    func setImportedVideo(_ url: URL?) {
        updateOnMain { self.importedVideoURL = url }
    }

    func clearImportedMedia() {
        updateOnMain {
            self.importedPhoto = nil
            self.importedVideoURL = nil
        }
    }

    /// Меняет местами переднюю и заднюю камеры (основная ↔ вторичная).
    func swapCameras() {
        updateOnMain { self.isCamerasSwapped.toggle() }
    }

    // MARK: - Зум, фонарик, фокус

    /// Устанавливает зум основной камеры (значение ограничивается диапазоном устройства).
    func setZoom(_ factor: CGFloat) {
        let clamped = min(max(factor, minZoomFactor), maxZoomFactor)
        updateOnMain { self.zoomFactor = clamped }

        sessionQueue.async { [weak self] in
            guard let self, let device = self.backCamera else { return }
            let deviceClamped = min(max(clamped, device.minAvailableVideoZoomFactor),
                                    device.maxAvailableVideoZoomFactor)
            guard (try? device.lockForConfiguration()) != nil else { return }
            device.videoZoomFactor = deviceClamped
            device.unlockForConfiguration()
        }
    }

    /// Включает/выключает фонарик основной камеры.
    func toggleTorch() {
        let newValue = !isTorchOn
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

    /// Фокусировка и экспозиция по точке касания (координаты нормализованы 0...1).
    func focusAndExpose(at normalizedPoint: CGPoint) {
        let point = CGPoint(x: min(max(normalizedPoint.x, 0), 1),
                            y: min(max(normalizedPoint.y, 0), 1))

        sessionQueue.async { [weak self] in
            guard let self, let device = self.backCamera else { return }
            guard (try? device.lockForConfiguration()) != nil else { return }

            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                }
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
                if device.isExposureModeSupported(.autoExpose) {
                    device.exposureMode = .autoExpose
                }
            }
            device.unlockForConfiguration()
        }
    }

    // MARK: - Видеозапись

    /// Начинает одновременную запись видео с обеих камер.
    /// `elements` — рисунок, который вшивается в видео (снимок на момент старта).
    func startRecording(elements: [DrawingElement] = [],
                        pipOffsetFraction: CGSize = .zero,
                        pipWidthFraction: CGFloat = 0.3) {
        guard isConfigured, !isRecording else { return }
        let importedPhotoAtStart = importedPhoto
        let swappedAtStart = isCamerasSwapped
        let importedVideoAtStart = importedVideoURL
        let layoutAtStart = layout
        let shapeAtStart = pipShape
        let splitOrientationAtStart = splitOrientation
        updateOnMain {
            self.isRecording = true
            self.recordingDuration = 0
            self.startRecordingTimer(initialOffsetFraction: pipOffsetFraction,
                                     widthFraction: pipWidthFraction,
                                     elements: elements)
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }

            self.recordingElements = elements
            self.recordingPipOffsetFraction = pipOffsetFraction
            self.recordingPipPhoto = importedPhotoAtStart

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

            self.recordingLayout = layoutAtStart
            self.recordingShape = shapeAtStart
            self.recordingSplitOrientation = splitOrientationAtStart
            self.recordingCamerasSwapped = swappedAtStart
            self.recordingImportedVideoURL = importedVideoAtStart

            self.backMovieOutput.startRecording(to: backURL, recordingDelegate: backDelegate)
            self.frontMovieOutput.startRecording(to: frontURL, recordingDelegate: frontDelegate)
        }
    }

    /// Останавливает запись и склеивает оба клипа в один файл.
    func stopRecording(elements: [DrawingElement]? = nil) {
        guard isRecording else { return }
        let stopTime = Date().timeIntervalSince(recordingStartDate ?? Date())
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
        recordingPipWidthFraction = width
    }

    func updateRecordingElements(_ elements: [DrawingElement]) {
        guard isRecording else { return }
        let updateTime = Date().timeIntervalSince(recordingStartDate ?? Date())
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.recordingElements = elements
            self.recordingLock.lock()
            if self.recordingDrawingKeyframes.last?.elements != elements {
                self.recordingDrawingKeyframes.append(
                    DrawingElementsKeyframe(time: updateTime, elements: elements)
                )
            }
            self.recordingLock.unlock()
        }
    }

    // MARK: - Настройка сессии (выполняется в sessionQueue)

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // Не используем пресеты — формат каждой камеры задаём вручную.
        session.sessionPreset = .inputPriority

        // 1. Выбираем совместимую пару устройств (передняя + задняя).
        let pair = selectMultiCamPair()
        guard let back = pair.back, let front = pair.front else {
            throw CameraError.noCompatibleDevices
        }
        backCamera = back
        frontCamera = front

        // 2. Подбираем форматы: задняя 1080p, передняя минимальный 480p для диагностики.
        try configureFormat(for: back, target: CGSize(width: 1920, height: 1080))
        try configureFormat(for: front, target: CGSize(width: 640, height: 480))

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
        try connect(backDeviceInput, to: backMovieOutput, mirrored: false)
        try connect(frontDeviceInput, to: frontMovieOutput, mirrored: true)

        // Диагностический путь в обход AVCaptureVideoPreviewLayer.
        frontVideoDataOutput.alwaysDiscardsLateVideoFrames = true
        frontVideoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        if session.canAddOutput(frontVideoDataOutput) {
            session.addOutputWithNoConnections(frontVideoDataOutput)
            do {
                try connect(frontDeviceInput, to: frontVideoDataOutput)
                frontVideoDataOutput.setSampleBufferDelegate(self, queue: frontVideoOutputQueue)
            } catch {
                session.removeOutput(frontVideoDataOutput)
            }
        } else {
        }

        // 7а. Микрофон: добавляем вход и подключаем звук к обоим видео-выходам.
        try addAudioInput()
    }

    /// Добавляет микрофон и подключает его к обоим видео-выходам.
    /// Если доступа к микрофону нет — записываем видео без звука.
    private func addAudioInput() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let audioDevice = AVCaptureDevice.default(for: .audio),
              let micInput = try? AVCaptureDeviceInput(device: audioDevice),
              session.canAddInput(micInput) else {
            return
        }
        session.addInputWithNoConnections(micInput)
        audioInput = micInput

        guard let audioPort = micInput.ports.first else { return }
        try connect(audioPort, to: backMovieOutput)
        try connect(audioPort, to: frontMovieOutput)
    }

    // MARK: - Ротация

    /// Подключает превью-слои к сессии и проверяет активность соединений.
    private func connectPreviewLayers() {
        guard let back = backInput, let front = frontInput else { return }
        do {
            try connect(back, to: backPreviewLayer, mirrored: false)
            try connect(front, to: frontPreviewLayer, mirrored: true)
        } catch {
            updateOnMain { self.errorMessage = "Превью не подключилось: \(error)" }
            return
        }
        // Через 2 секунды проверяем, получает ли превью видео.
        sessionQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            if !self.frontPreviewLayer.isPreviewing {
                self.updateOnMain { self.errorMessage = "Превью передней камеры не получает видео." }
            }
        }
    }

    /// Настраивает ротацию превью и отслеживает поворот устройства.
    private func configureRotationCoordinators() {
        guard let back = backCamera, let front = frontCamera else { return }

        // Координаторы сами поворачивают превью-слои под устройство.
        let backCoordinator = AVCaptureDevice.RotationCoordinator(device: back, previewLayer: backPreviewLayer)
        let frontCoordinator = AVCaptureDevice.RotationCoordinator(device: front, previewLayer: frontPreviewLayer)
        rotationCoordinator = backCoordinator
        frontRotationCoordinator = frontCoordinator

        rotationObservation = backCoordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.initial, .new]
        ) { [weak self] _, change in
            guard let self, let previewAngle = change.newValue else { return }
            let backCapture = self.rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? previewAngle
            let frontCapture = self.frontRotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? previewAngle
            self.sessionQueue.async {
                self.applyRotation(previewAngle: previewAngle,
                                   backCapture: backCapture,
                                   frontCapture: frontCapture)
            }
        }
    }

    /// Применяет угол поворота к фото/видео-соединениям и обновляет флаг ориентации.
    private func applyRotation(previewAngle: CGFloat, backCapture: CGFloat, frontCapture: CGFloat) {
        let isPortrait = previewAngle.truncatingRemainder(dividingBy: 180) == 0
        updateOnMain { self.isPortrait = isPortrait }

        let pairs: [(AVCaptureConnection?, CGFloat)] = [
            (backPhotoConnection, backCapture),
            (frontPhotoConnection, frontCapture),
            (backMovieConnection, backCapture),
            (frontMovieConnection, frontCapture),
            (frontVideoDataConnection, frontCapture),
            (backPreviewLayer.connection, previewAngle),
            (frontPreviewLayer.connection, previewAngle)
        ]
        for (connection, angle) in pairs {
            if let connection, connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
    }

    /// Находит пару «передняя + задняя», которую система разрешает
    /// использовать одновременно.
    private func selectMultiCamPair() -> (back: AVCaptureDevice?, front: AVCaptureDevice?) {
        let back = preferredBackDevice()
        let front = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        return (back, front)
    }

    /// Для задней камеры используем обычную широкоугольную. Виртуальное
    /// устройство (сверхширокоугольная + широкоугольная) может занимать
    /// ресурсы портов и оставлять превью передней камеры пустым.
    private func preferredBackDevice() -> AVCaptureDevice? {
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    private func configureFormat(for device: AVCaptureDevice, target: CGSize) throws {
        guard let format = bestMultiCamFormat(for: device, target: target) else {
            throw CameraError.noCompatibleFormat
        }
        try device.lockForConfiguration()
        device.activeFormat = format
        // Принудительно SDR: на новых iOS HDR-видео в превью может
        // показываться белым экраном (особенно у фронтальной камеры).
        device.activeColorSpace = .sRGB
        device.automaticallyAdjustsVideoHDREnabled = false
        device.isVideoHDREnabled = false
        // Фиксируем 30 fps для стабильной совместной работы.
        let fps = CMTime(value: 1, timescale: 30)
        device.activeVideoMinFrameDuration = fps
        device.activeVideoMaxFrameDuration = fps
        device.unlockForConfiguration()
    }

    /// Подбирает формат: поддержка MultiCam обязательна,
    /// 1080p@30fps — в приоритете.
    private func bestMultiCamFormat(for device: AVCaptureDevice, target: CGSize) -> AVCaptureDevice.Format? {
        var bestFormat: AVCaptureDevice.Format?
        var bestScore = CGFloat.greatestFiniteMagnitude

        for format in device.formats {
            // Правило №4: формат должен поддерживать совместную работу камер.
            guard format.isMultiCamSupported else { continue }

            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let size = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))

            // Формат должен уметь отдавать хотя бы 30 fps.
            let supports30fps = format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
            guard supports30fps else { continue }

            // Близость к 1080p: чем меньше суммарное отклонение, тем лучше.
            let score = abs(size.width - target.width) + abs(size.height - target.height)
            if score < bestScore {
                bestScore = score
                bestFormat = format
            }
        }
        return bestFormat
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
                         mirrored: Bool) throws {
        guard let port = input.ports.first else {
            throw CameraError.connectionFailed
        }
        let connection = AVCaptureConnection(inputPorts: [port], output: output)
        guard session.canAddConnection(connection) else {
            throw CameraError.connectionFailed
        }
        session.addConnection(connection)
        if mirrored { frontMovieConnection = connection } else { backMovieConnection = connection }
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
                         to layer: AVCaptureVideoPreviewLayer,
                         mirrored: Bool) throws {
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
                         to output: AVCaptureVideoDataOutput) throws {
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
        frontVideoDataConnection = connection
    }

    // MARK: - Съёмка и склейка

    private func captureAndMerge(elements: [DrawingElement],
                                 pipOffsetFraction: CGSize,
                                 pipWidthFraction: CGFloat) async throws -> UIImage {
        defer { clearPhotoDelegates() }

        // Запускаем оба захвата подряд. Вызовы возвращаются мгновенно,
        // а сенсоры камер срабатывают практически одновременно.
        async let frontData = capturePhoto(from: frontPhotoOutput)
        async let backData = capturePhoto(from: backPhotoOutput)
        let (front, back) = try await (frontData, backData)

        guard let backImage = UIImage(data: back) else {
            throw CameraError.captureFailed
        }

        // Второй слой: импортированное фото или снимок передней камеры.
        let frontImage: UIImage
        if let imported = importedPhoto {
            frontImage = imported
        } else {
            guard let image = UIImage(data: front) else {
                throw CameraError.captureFailed
            }
            frontImage = image
        }

        // Если камеры поменяны местами — меняем и порядок склейки.
        let primary = isCamerasSwapped ? frontImage : backImage
        let secondary = isCamerasSwapped ? backImage : frontImage
        return PhotoMerger.merge(back: primary,
                                 front: secondary,
                                 layout: layout,
                                 shape: pipShape,
                                 splitOrientation: splitOrientation,
                                 pipOffsetFraction: pipOffsetFraction,
                                 pipWidthFraction: pipWidthFraction,
                                 elements: elements)
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
            recordingError = error
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
                self.errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Не удалось записать видео."
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
        let drawingKeyframes = recordingDrawingKeyframes
        recordingLock.unlock()
        let outputLayout = recordingLayout
        let outputShape = recordingShape
        let outputSplitOrientation = recordingSplitOrientation
        let outputOffset = recordingPipOffsetFraction
        let outputWidth = recordingPipWidthFraction
        let outputPipPhoto = recordingPipPhoto
        let outputImportedVideoURL = recordingImportedVideoURL
        let outputCamerasSwapped = recordingCamerasSwapped
        let outputElements = recordingElements

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
                    pipOffsetFraction: outputOffset,
                    pipWidthFraction: outputWidth,
                    pipPositionKeyframes: pipKeyframes,
                    drawingKeyframes: drawingKeyframes,
                    pipPhoto: outputPipPhoto,
                    elements: outputElements
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
        recordingLock.lock()
        recordedURLs.removeAll()
        recordingError = nil
        recordingPipPositionKeyframes.removeAll()
        recordingDrawingKeyframes.removeAll()
        expectedRecordingCount = 0
        receivedRecordingCallbacks = 0
        recordingLock.unlock()
        recordingDelegates.removeAll()
        recordingBackURL = nil
        recordingFrontURL = nil
        recordingElements = []
        recordingPipOffsetFraction = .zero
        recordingPipWidthFraction = 0.3
        recordingPipPhoto = nil
        recordingImportedVideoURL = nil
        recordingLayout = .splitScreen
        recordingShape = .rectangle
        recordingSplitOrientation = .vertical
        recordingCamerasSwapped = false
    }

    // MARK: - Таймер записи (главный поток)

    private func startRecordingTimer(initialOffsetFraction: CGSize,
                                     widthFraction: CGFloat,
                                     elements: [DrawingElement]) {
        recordingStartDate = Date()
        recordingPipWidthFraction = widthFraction
        recordingLock.lock()
        recordingPipPositionKeyframes = [
            PipPositionKeyframe(time: 0,
                                offsetFraction: initialOffsetFraction,
                                widthFraction: widthFraction)
        ]
        recordingDrawingKeyframes = [
            DrawingElementsKeyframe(time: 0, elements: elements)
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
        guard output === frontVideoDataOutput,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard lastFrontProbeImageUpdate == 0 || now - lastFrontProbeImageUpdate >= 66_666_667 else { return }
        lastFrontProbeImageUpdate = now
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        if let cgImage = frontProbeImageContext.createCGImage(ciImage, from: ciImage.extent) {
            let image = UIImage(cgImage: cgImage)
            updateOnMain { self.frontPreviewStore.image = image }
        }
    }
}
