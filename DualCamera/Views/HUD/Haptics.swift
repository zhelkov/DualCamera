import AudioToolbox
import AVFoundation
import CoreHaptics
import UIKit

/// Тактильная отдача.
///
/// Почему так сложно: на iPhone мотор тактильной отдачи висит на том же
/// аудиотракте, что и запись, поэтому активный режим `.playAndRecord`
/// глушит сразу все способы — Core Haptics, генераторы UIKit и системную
/// вибрацию. Поэтому перед запуском движка мы освобождаем аудиосессию,
/// если сейчас никто не пишет видео.
enum Haptics {
    /// Пользовательский выбор: всегда использовать системную вибрацию.
    static var preferSystemVibration = false
    /// Можно ли освободить аудиосессию: false, пока идёт запись.
    static var audioCanBeReleased = true

    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static var engine: CHHapticEngine?

    private(set) static var lastError: String?
    private(set) static var lastMechanism = "ещё не запускали"
    private(set) static var playCount = 0

    /// Номер системного звука вибрации (kSystemSoundID_Vibrate).
    private static let vibrateSoundID: SystemSoundID = 4095

    static var supportsHaptics: Bool {
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    static var diagnosticText: String {
        let audio = AVAudioSession.sharedInstance()
        var lines = [
            "Поддержка устройства: \(supportsHaptics ? "да" : "нет")",
            "Движок Core Haptics: \(engine != nil ? "запущен" : "не запущен")",
            "Аудиосессия: \(audio.category.rawValue)",
            "Освобождать аудио можно: \(audioCanBeReleased ? "да" : "нет")",
            "Откликов сыграно: \(playCount)",
            "Последний отклик: \(lastMechanism)",
            "Режим: \(preferSystemVibration ? "системная вибрация" : "тактильный отклик")"
        ]
        if let lastError {
            lines.append("Ошибка: \(lastError)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Подготовка

    static func prepare() {
        lightGenerator.prepare()
        mediumGenerator.prepare()
        _ = ensureEngineReady()
    }

    /// Освобождает аудиосессию, если запись не идёт. Возвращает true,
    /// если освобождение удалось.
    @discardableResult
    private static func releaseAudioIfPossible() -> Bool {
        guard audioCanBeReleased else { return false }
        do {
            // Повторное освобождение безопасно и для уже свободной сессии.
            try AVAudioSession.sharedInstance().setActive(false,
                                                          options: .notifyOthersOnDeactivation)
        } catch {
            return false
        }
        // После смены аудиоокружения старый движок может остаться глухим,
        // поэтому пересоздаём его.
        engine = nil
        return true
    }

    private static func ensureEngineReady() -> Bool {
        releaseAudioIfPossible()
        guard engine == nil else { return true }
        guard supportsHaptics else { return false }
        do {
            let newEngine = try CHHapticEngine()
            newEngine.playsHapticsOnly = true
            newEngine.isAutoShutdownEnabled = false
            newEngine.stoppedHandler = { _ in
                engine = nil
            }
            newEngine.resetHandler = { [weak newEngine] in
                try? newEngine?.start()
            }
            try newEngine.start()
            engine = newEngine
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            engine = nil
            return false
        }
    }

    // MARK: - Публичные отклики

    /// Отклик на обычное действие: короткий одиночный «тик».
    static func selection() {
        tick(intensity: 0.9, sharpness: 0.5)
    }

    /// Отклик на значимое действие: чуть плотнее.
    static func impact() {
        tick(intensity: 1.0, sharpness: 0.7)
    }

    private static func tick(intensity: Float, sharpness: Float) {
        playCount += 1
        if preferSystemVibration {
            vibrateSystem()
            return
        }
        if playTransientCoreHaptics(intensity: intensity, sharpness: sharpness) {
            return
        }
        if intensity >= 0.95 {
            mediumGenerator.impactOccurred(intensity: CGFloat(intensity))
            mediumGenerator.prepare()
        } else {
            lightGenerator.impactOccurred(intensity: CGFloat(intensity))
            lightGenerator.prepare()
        }
        lastMechanism = "генератор UIKit"
    }

    private static func playTransientCoreHaptics(intensity: Float, sharpness: Float) -> Bool {
        guard ensureEngineReady(), let engine else { return false }
        let event = CHHapticEvent(eventType: .hapticTransient,
                                  parameters: [
                                    CHHapticEventParameter(parameterID: .hapticIntensity,
                                                           value: intensity),
                                    CHHapticEventParameter(parameterID: .hapticSharpness,
                                                           value: sharpness)
                                  ],
                                  relativeTime: 0)
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            lastMechanism = "Core Haptics (тик)"
            return true
        } catch {
            lastError = error.localizedDescription
            Haptics.engine = nil
            return false
        }
    }

    private static func vibrateSystem() {
        AudioServicesPlaySystemSound(vibrateSoundID)
        lastMechanism = "системная вибрация"
    }

    // MARK: - Диагностика

    /// Пошаговая проверка: каждый способ отдельно, с отчётом в текстовом виде.
    static func runStepTest(log: @escaping (String) -> Void) {
        var lines: [String] = []
        func append(_ line: String) {
            lines.append(line)
            log(lines.joined(separator: "\n"))
        }

        append(diagnosticText)
        append("")
        append("Шаг 1 из 3: генератор UIKit")
        lightGenerator.prepare()
        mediumGenerator.impactOccurred(intensity: 1)
        append("  вызван")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            append("Шаг 2 из 3: Core Haptics")
            let audioFreed = releaseAudioIfPossible()
            if audioFreed {
                append("  аудиосессия освобождена перед запуском")
            }
            let played = playTransientCoreHaptics(intensity: 1.0, sharpness: 0.7)
            append(played ? "  сыграл" : "  НЕ сыграл")

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                append("Шаг 3 из 3: системная вибрация")
                vibrateSystem()
                append("  вызвана")
                append("")
                append("Если не ощутили ни одного шага — вибрация выключена")
                append("в настройках системы или включён режим энергосбережения.")
            }
        }
    }
}
