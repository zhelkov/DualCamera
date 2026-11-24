# DualCamera

## Stable rollback point

- **Stable release before the real-time recording experiment:** `v1.7.12`.
- Commit: `7102fce` (`Mirror front video horizontally in portrait`).
- This release keeps the existing workflow: record the front and rear camera clips separately, then merge them after Stop.
- The real-time composite recorder must remain selectable as an experiment; the legacy workflow remains the rollback option until device testing confirms the new path.
- To return the source tree to the stable release, use `git checkout v1.7.12` (or revert the experimental commits if newer work must be retained).

## Recording experiment

- The on-screen `Стандартная запись` / `Эксперимент: запись сразу` switch selects between the v1.7.12 recorder and the experimental live compositor.
- Standard mode continues recording both camera files and merging them after Stop.
- Experimental mode synchronizes both live camera outputs, composites each frame with the current split/PiP layout, photo overlay, and drawing, then writes the result to a temporary MOV as capture proceeds. Stop only finalizes the file; the existing result screen then saves it to Photos.
- Selecting experimental mode prepares the synchronized capture outputs before recording starts; switching back to standard mode removes them. This keeps session reconfiguration away from the Record/Stop interval.
- The live compositor retains the latest usable frame from each camera when the synchronizer reports a dropped or absent sample, and reports per-camera synchronization statistics if no composite frames reach the writer.
- The live writer emits at most one composite frame for each new, non-dropped sample from the synchronizer's main back-camera output. This avoids turning secondary-camera callbacks into extra high-frame-rate output frames.
- On iOS 18 and later, the live writer writes QuickTime `FullFrameRatePlaybackIntent = 1` to state that the composed video should play at full frame rate.
- The writer uses the later valid presentation timestamp from the synchronized camera samples. This behavior is retained based on device playback testing.
- The result screen reads the video samples and displays their PTS span, frame count, minimum/average/maximum PTS step, long-step count, nominal frame rate, QuickTime full-frame-rate playback intent, and audio duration.
- Timing diagnostics are overlaid on the preview, report read progress, and show an explicit reader error if sample reading fails.
- Imported video is not supported by the live compositor yet; use standard mode when a video has been picked from Photos.
- Keep the experiment opt-in and test it on the iPhone 12 for output orientation, PiP placement/shape, overlays, audio, dropped frames, and long recordings before considering it a replacement.

Нативное iOS-приложение (аналог MixCam) для одновременной съёмки с передней и задней камер через `AVCaptureMultiCamSession`.

## Механика поворота и зеркалирования изображений

Протокол зафиксирован по состоянию кода 1.8.44 (build 93). Ландшафт — самый проблемный режим, поэтому он расписан отдельно.

### Термины

- **Буфер камеры (источник)** — сырой кадр с `AVCaptureVideoDataOutput`, приходит в ориентации сенсора: 1080×1920 (вертикальный) независимо от того, как повёрнут телефон.
- **Холст (canvas)** — итоговый кадр. Размер задаёт `CameraSettingsSnapshot.outputSize(isPortrait:)`: в портрете 1080×1920, в ландшафте 1920×1080.
- **Родительское поле кадра** — рамка выбранного формата (9:16, 4:3, 1:1) в превью. Окно PiP позиционируется внутри неё.
- **Ориентация по датчику** — `UIDevice.orientation`; отображение `landscapeLeft → .landscapeRight` и наоборот (`updateVideoOrientationFromDevice`).
- Приложение закреплено в портрете (`INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone: UIInterfaceOrientationPortrait`), поэтому сам экран не поворачивается: геометрия окна в ландшафте остаётся портретной (390×844), а в ландшафтном режиме поворачиваются только значки HUD и вторичное превью.

### Состав слоёв и их повороты

#### Превью (то, что видно на экране)

| № | Слой | Поворот | Зеркалирование |
|---|---|---|---|
| 1 | Основной слой превью: `AVCaptureVideoPreviewLayer`, `videoGravity = .resizeAspectFill` | `videoOrientation = .portrait` жёстко и всегда, независимо от датчика | нет |
| 2 | Вторичный слой превью: второй `AVCaptureVideoPreviewLayer` | `videoOrientation` = ориентация по датчику (портрет / landscapeLeft / landscapeRight) | AVFoundation автоматически зеркалит фронтальную камеру (`automaticallyAdjustsVideoMirroring` для превью-соединений не отключается) |
| 3 | SwiftUI-поворот вторичного слоя | `rotationEffect(90°)` — **только** для раскладки PiP в ландшафте | нет |
| 4 | Окно PiP (его прямоугольник) | в ландшафте стороны меняются местами: окно широкое, содержимое вписывается в повёрнутый слот | нет |
| 5 | Фильтрованное превью вместо слоя (`FilteredCameraPreviewView`), когда фильтр ≠ «Оригинал» | по размеру кадра, `scaledToFill` | задняя: нет; передняя: `scaleEffect(x: -1)` |
| 6 | Оверлеи: рисунок, фото из медиатеки, сетка, пунктирная рамка формата, дата/время, телесуфлёр, указатель, кнопки HUD | нет поворотов; пунктирная рамка всегда строится в портретном соотношении (`ratio(isPortrait: true)`) | нет |

#### Готовое фото (`CameraManager.captureAndMerge` → `PhotoMerger.merge`)

1. Захват обеих камер: соединения фото-выходов получают `videoOrientation` по датчику, поэтому в EXIF снимка ориентация уже «правильная».
2. `normalized()` — запекает `UIImage.imageOrientation` в пиксели, дальше размеры честные.
3. `PhotoMerger.mirrorHorizontally(frontImage)` в `CameraManager` — передняя камера зеркалится по горизонтали **всегда**.
4. Смена камер местами: `primary = front`, `secondary = back`.
5. `rotatedQuarterTurn(back)` — если холст горизонтальный (`targetRatio > 1`) и снимок основной камеры вертикальный.
6. Фильтр (Core Image) применяется к основной или ко вторичной камере.
7. Раскладка:
   - сплит — две ячейки;
   - PiP — в ландшафте окно широкое (`height = shortSide × доля`, `width = height × aspect`), содержимое окна **не поворачивается**, вписывается с заполнением.
8. `crop(toAspectRatio:)` под выбранный формат кадра.
9. Рисунок и дата/время накладываются уже в координатах итогового кадра.

#### Готовое видео — запись камер (`RealtimeCompositeRecorder`)

1. `renderSize` = холст; writer пишет без `preferredTransform`, поэтому размеры файла равны холсту (в ландшафте 1920×1080).
2. Кадры приходят из `AVCaptureDataOutputSynchronizer` буферами в ориентации сенсора; AVFoundation их не поворачивает.
3. Зеркалирование: `mainSource`/`smallSource` — передняя камера зеркалится по горизонтали всегда (`mirrorHorizontally`), независимо от того, она основная или вторичная.
4. `rotateQuarterTurn(mainSource)` — если холст горизонтальный, а буфер вертикальный.
5. Раскладка: сплит — ячейки; PiP — широкое окно в ландшафте, содержимое **не поворачивается** (просто заполняет окно), отступ 2 pt от края кадра.
6. Смена камер местами во время записи — по ключевым кадрам.
7. Рисунок, фото-оверлей, дата/время — в координатах холста.

#### Готовое видео — импортированное видео (`VideoMerger` + `DualCameraVideoCompositor`)

1. `preferredTransform` дорожки применяется при размещении кадра (`place`).
2. Ландшафт: основной слой получает `rotateHalfTurn` (180°), если это видео с камеры.
3. `rotateQuarterTurn` основного слоя — если содержимое вертикальное, а холст горизонтальный.
4. Передняя камера зеркалится по горизонтали (`mirrorForFinalVideo`).
5. Сплит: прямоугольники ячеек зеркалятся по вертикали и горизонтали.
6. PiP: широкое окно в ландшафте, содержимое без поворота.

### Матрица комбинаций

Режимы: **Ф** — фото, **Вк** — видео с камер (realtime), **Ви** — видео с импортированным клипом.

| Ориентация | Режим | Основной слой | Вторичный слой | Окно PiP |
|---|---|---|---|---|
| Портрет | Ф | EXIF-ориентация + зеркало фронта, без поворота | то же | портретное, содержимое без поворота |
| Портрет | Вк | буфер вертикальный, поворот не нужен | зеркало фронта | портретное, без поворота |
| Портрет | Ви | `preferredTransform` дорожки | зеркало фронта | портретное, без поворота |
| Ландшафт | Ф | поворот на 90°, если снимок вертикальный | зеркало фронта | широкое окно, содержимое без поворота |
| Ландшафт | Вк | поворот на 90° (буфер всегда вертикальный) | зеркало фронта | широкое окно, содержимое без поворота |
| Ландшафт | Ви | `preferredTransform` + `rotateHalfTurn` + при необходимости 90° | зеркало фронта | широкое окно, содержимое без поворота |

### Особенности ландшафта, которые надо учитывать

1. Окно приложения остаётся портретным (390×844), но холст записи в ландшафте горизонтальный (1920×1080).
2. Основной слой превью жёстко `.portrait`, вторичный — по датчику; из-за этого картинки двух камер в ландшафте ориентированы по-разному.
3. Окно PiP в превью поворачивается на 90° (`rotationEffect`), а его содержимое в готовом файле — нет. Расхождение сознательное: в файле окно уже широкое.
4. Позиция PiP задаётся долями от родительского поля кадра; при повороте экрана окно принудительно паркуется в левый верхний угол (`pipOffset = .zero`).
5. Буфер камеры не подтверждён приборно: размеры берутся из кода (1080×1920). Диагностическая строка в настройках показывает `датчик / кадр / холст / буфер`.
6. Зеркалирование фронтальной камеры в превью выполняет AVFoundation; в готовом файле — наш код. Оба места должны оставаться согласованными.

## Что внутри

- `DualCamera/Models/CameraManager.swift` — ядро: настройка сессии, форматы, ручные соединения, захват и склейка.
- `DualCamera/Models/CaptureLayout.swift` — раскладки (сплит / картинка в картинке).
- `DualCamera/Models/PhotoCaptureDelegate.swift` — делегат одиночного снимка.
- `DualCamera/Models/PhotoMerger.swift` — склейка двух фото в одно.
- `DualCamera/Models/MovieCaptureDelegate.swift` — делегат записи видео-клипа.
- `DualCamera/Models/VideoMerger.swift` — объединение двух клипов в один файл.
- `DualCamera/Views/ContentView.swift` — экран с превью, кнопками фото и видео, переключением раскладки.
- `DualCamera/Views/CameraPreviewView.swift` — обёртка `AVCaptureVideoPreviewLayer` для SwiftUI.
- `DualCamera/Views/MergedVideoView.swift` — показ и сохранение готового видео.
- `DualCamera/Support/CameraError.swift` — ошибки с русским описанием.
- `DualCamera/Models/DrawingEngine.swift` — рисование поверх камеры (штрихи, кисть, палитра).
- `DualCamera/Views/DrawingCanvas.swift` — холст для рисования.
- `mockups/` — HTML-макеты экранов (раскладки, запись, результат).

## Требования

- Xcode 15+ (Swift 5.9, iOS 17+).
- **Реальное устройство**: `AVCaptureMultiCamSession` не работает в симуляторе.
- Многокамерная съёмка доступна на iPhone XS/XR и новее (чип A12 Bionic и выше).

> Запись видео со звуком: микрофон подключается к обоим видео-выходам.
> Если доступа к микрофону нет — запись идёт без звука.

## Сборка

### Вариант A — XcodeGen

```bash
brew install xcodegen
xcodegen generate
open DualCamera.xcodeproj
```

### Вариант B — вручную

1. Создайте новый проект iOS App в Xcode с именем `DualCamera`.
2. Удалите автогенерированные файлы и скопируйте папку `DualCamera/` из репозитория.
3. В настройках таргета укажите `iOS 17.0` как минимальную версию.
4. В `Info.plist` добавьте ключи:
   - `Privacy - Camera Usage Description`
   - `Privacy - Photo Library Additions Usage Description`
5. Подпишите таргет своим сертификатом и запустите на устройстве.

## Ключевые правила, которые соблюдены в коде

1. Используется только `AVCaptureMultiCamSession`.
2. Проверка `AVCaptureMultiCamSession.isMultiCamSupported` и `supportedMultiCamDeviceSets`.
3. Соединения создаются вручную через `AVCaptureConnection` (`addInputWithNoConnections` / `addOutputWithNoConnections` / `addConnection`).
4. Форматы выбираются по `format.isMultiCamSupported`, приоритет 1080p@30 fps.
5. Сессия работает в последовательной очереди, UI обновляется на главном потоке.
