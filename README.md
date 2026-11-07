# DualCamera

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
