# DualCamera — исходные данные и история проб (для ИИ-помощника)

## Что за проект

Нативное iOS-приложение (Swift, SwiftUI) для одновременной съёмки с двух камер через `AVCaptureMultiCamSession`. Аналог MixCam. Склейка фото и видео, рисование поверх, зум, сплит/картинка-в-картинке.

## Структура репозитория

- `project.yml` — конфиг XcodeGen (генерирует `.xcodeproj` на этапе сборки).
- `DualCamera/Models/CameraManager.swift` — ядро: сессия, устройства, соединения, захват, склейка, зум.
- `DualCamera/Models/PhotoMerger.swift`, `VideoMerger.swift` — склейка фото/видео.
- `DualCamera/Models/CaptureLayout.swift`, `PipShape.swift`, `DrawingEngine.swift`, `DrawingRenderer.swift`, `PhotoCaptureDelegate.swift`, `MovieCaptureDelegate.swift`.
- `DualCamera/Views/ContentView.swift` — экран (превью, кнопки, сплит, зум).
- `DualCamera/Views/CameraPreviewView.swift` — `UIViewRepresentable` для превью.
- `DualCamera/Views/MergedVideoView.swift`, `DrawingCanvas.swift`.
- `.github/workflows/build.yml` — сборка IPA в GitHub Actions (macOS-раннер).

## Окружение

- Устройство пользователя: **iPhone 12** (modelCode `iPhone13,2`), **iOS 26.2** (build `23C55`).
- Компьютер пользователя: **Windows** (нет Mac и Xcode).
- Установка на устройство: **AltStore** (подпись бесплатным Apple ID, действует 7 дней).
- Репозиторий: `https://github.com/zhelkov/DualCamera` (публичный).

## Ключевые параметры сборки

- `SWIFT_VERSION = 5.0` (в `project.yml`), deployment target iOS 17.0.
- XcodeGen генерирует проект на macOS-раннере.
- `TARGETED_DEVICE_FAMILY = 1` (только iPhone).

## Текущее состояние (главное)

Приложение **запускается и работает**. Задняя камера видна в превью. Фото и видео захватывают **обе** камеры (склейка работает). НО **превью передней камеры белое** (пустой прямоугольник) — и в сплите, и в режиме «картинка в картинке».

Диагностика на экране показывает:

`back active=true prev=true; front active=true prev=true`

То есть соединение передней камеры создано, активно, и слой получает видео (`isPreviewing = true`), но отображается **белым**. Это значит, что проблема не в подключении, а в самом отображаемом видеопотоке (вероятно, цвет/формат/рендеринг слоя).

## Что уже пробовали (НЕ сработало)

1. `connection.isVideoMirrored = true` — **краш** (SIGABRT, `-[AVCaptureConnection setVideoMirrored:]`) на iOS 26, в любом месте: до/после `addConnection`, после `startRunning`.
2. `connection.automaticallyAdjustsVideoMirroring = true` — не помогло.
3. Подключение превью **до** и **после** `startRunning()` — не помогло.
4. Перестановка порядка соединений (превью первыми) — не помогло.
5. Задняя камера `builtInDualWideCamera` (виртуальное устройство) — не помогло; вернули `builtInWideAngleCamera`.
6. Передняя камера `builtInTrueDepthCamera` — не помогло.
7. SDR: `device.activeColorSpace = .sRGB` — не помогло.
8. Формат передней камеры 720p, затем 480p — не помогло.
9. Зеркалирование `frontPreviewLayer` через `CATransform3DMakeScale(-1,1,1)` — не помогло.
10. Зеркалирование на уровне `UIView` (`PreviewContainerView.transform`) — не помогло.
11. Применение `videoRotationAngle` к превью-слоям — не помогло.
12. Полное отключение HDR (`activeColorSpace = .sRGB` + `automaticallyAdjustsVideoHDREnabled = false` + `isVideoHDREnabled = false`) — не помогло.

## Прочие известные задачи (в очереди)

- **Зум 0.5x**: был достигнут через `builtInDualWideCamera`, но откатили ради отладки превью. Сейчас задняя камера — широкая (1x).
- **Горизонтальный сплит**: добавлен enum `SplitOrientation` и переключатель в `ContentView`; склейка учитывает ориентацию.
- **Сохранение в медиатеку**: добавлен запрос `PHPhotoLibrary.requestAuthorization(for: .addOnly)`.
- **Фото в сплите**: склеивает два полных кадра (не обрезает, как на превью) — нужно решить, оставить или обрезать.
- **Swap камер (кнопка с двумя стрелками)**: после переключения туда-обратно превью основной камеры не возвращается до перезапуска приложения.

## Текущая диагностическая сборка

В код добавлен обход `AVCaptureVideoPreviewLayer`: кадры передней камеры идут через отдельный `AVCaptureVideoDataOutput` в `AVSampleBufferDisplayLayer`. В окне передней камеры приложение показывает сырой поток и строку с разрешением, яркостью центрального пикселя и форматом.

- Если сырое изображение видно и яркость меняется при закрытии камеры рукой, поток камеры исправен; проблема находится в `AVCaptureVideoPreviewLayer` или его подключении к интерфейсу.
- Если статус говорит «Сырые кадры», но изображение белое и центральная яркость близка к 255, белыми приходят сами кадры.
- Если яркость не близка к 255, а SampleBuffer-экран белый, вероятна проблема отображения sample buffer.
- Если остаётся «Ожидание кадров» или показана ошибка подключения, проверить, удалось ли добавить дополнительный выход к MultiCam-сессии.

Проверить на iPhone 12 в обеих раскладках. Прислать фотографию экрана и строку статуса. Фото и видео-захват камер остаются доступны.

## Важные подводные камни

- `supportedMultiCamDeviceSets` у `AVCaptureMultiCamSession` недоступен в этом SDK (убрали).
- `AVCaptureConnection(inputPorts:output:)` в этом SDK возвращает **не optional**.
- Инициализатор превью-соединения: `AVCaptureConnection(inputPort:videoPreviewLayer:)` (параметр `inputPort` в единственном числе, не массив).
- Crash log пользователя нужно искать в «Данных аналитики» по имени `DualCamera` (системные `calaccessd`, `BackgroundShortcutRunner` — не наши).
