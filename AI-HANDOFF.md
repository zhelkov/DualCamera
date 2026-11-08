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

Кадры передней камеры идут через отдельный `AVCaptureVideoDataOutput`, преобразуются из `CVPixelBuffer` в `UIImage` через `CIContext` и показываются в SwiftUI. Это обходит и `AVCaptureVideoPreviewLayer`, и `AVSampleBufferDisplayLayer`. Статус показывает разрешение, возрастающий номер кадра и яркость центрального пикселя; статус обновляется каждые 0,5 секунды, изображение — до 15 кадров/с. Отдельный `UIViewRepresentable` с `UIImageView` отображает кадры, а `ObservableObject` изолирует их частое обновление от остального SwiftUI-экрана.

Пользователь подтвердил, что яркость меняется при закрытии фронтального объектива: входной поток живой. Белый экран теперь локализован в пути вывода изображения. В версии 1.2.3 яркость обновлялась, но картинка ограничивалась 5 кадрами/с. Версия 1.2.4 повысила частоту до 15 кадров/с, 1.2.5 вынесла вывод в `UIImageView`. В 1.2.6 `clipShape` снят со вторичного окна в сплит-режиме; пользователь подтвердил, что фронтальная картинка в Split появилась. В 1.2.7 маска PiP применяется перед смещением окна, чтобы не обрезать его в старом месте. Проверить, что второе окно видно в PiP и его можно перетаскивать.
## Важные подводные камни

- `supportedMultiCamDeviceSets` у `AVCaptureMultiCamSession` недоступен в этом SDK (убрали).
- `AVCaptureConnection(inputPorts:output:)` в этом SDK возвращает **не optional**.
- Инициализатор превью-соединения: `AVCaptureConnection(inputPort:videoPreviewLayer:)` (параметр `inputPort` в единственном числе, не массив).
- Crash log пользователя нужно искать в «Данных аналитики» по имени `DualCamera` (системные `calaccessd`, `BackgroundShortcutRunner` — не наши).
