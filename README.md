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
- Imported video is not supported by the live compositor yet; use standard mode when a video has been picked from Photos.
- Keep the experiment opt-in and test it on the iPhone 12 for output orientation, PiP placement/shape, overlays, audio, dropped frames, and long recordings before considering it a replacement.

Нативное iOS-приложение (аналог MixCam) для одновременной съёмки с передней и задней камер через `AVCaptureMultiCamSession`.

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
