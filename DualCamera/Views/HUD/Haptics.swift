import AudioToolbox
import CoreHaptics
import UIKit

/// Тактильная отдача тремя путями:
/// 1. Core Haptics в режиме «только тактильность» — не конфликтует с записью;
/// 2. UIKit-генераторы;
/// 3. Системная вибрация через `AudioServices` — работает даже там, где
///    Core Haptics молчит из-за настроек энергосбережения или аудиосессии.
enum Haptics {
    /// Пользовательский выбор: всегда использовать системную вибрацию.
    static var preferSystemVibration = false

    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static var engine: CHHapticEngine?

    private(set) static var lastError: String?

    static var supportsHaptics: Bool {
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    /// Что произошло при последней попытке — показываем в настройках.
    private(set) static var lastMechanism = "ещё не запускали"

    /// Номер системного звука вибрации (kSystemSoundID_Vibrate).
    private static let vibrateSoundID: SystemSoundID = 4095

    static var diagnosticText: String {
        var lines = [
            "Поддержка устройства: \(supportsHaptics ? "да" : "нет")",
            "Движок Core Haptics: \(engine != nil ? "запущен" : "не запущен")",
            "Последний отклик: \(lastMechanism)",
            "Режим: \(preferSystemVibration ? "системная вибрация" : "тактильный отклик")"
        ]
        if let lastError {
            lines.append("Ошибка: \(lastError)")
        }
        return lines.joined(separator: "\n")
    }

    static func prepare() {
        lightGenerator.prepare()
        mediumGenerator.prepare()
        startEngineIfNeeded()
    }

    private static func startEngineIfNeeded() {
        guard supportsHaptics, engine == nil else { return }
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
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Публичные отклики

    /// Отклик на обычное действие: переходы, выбор режима, зум.
    static func selection() {
        emit(intensity: 0.85, sharpness: 0.35, duration: 0.02)
    }

    /// Отклик на значимое действие: старт и стоп записи.
    static func impact() {
        emit(intensity: 1.0, sharpness: 0.55, duration: 0.05)
    }

    /// Проверка из настроек. Даёт два импульса: сначала тактильный отклик,
    /// затем системную вибрацию, чтобы понять, какой путь работает.
    static func test() {
        emit(intensity: 1.0, sharpness: 0.6, duration: 0.15)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            vibrateSystem()
            lastMechanism = "оба пути: тактильный отклик и системная вибрация"
        }
    }

    private static func emit(intensity: Float,
                             sharpness: Float,
                             duration: TimeInterval) {
        if preferSystemVibration {
            vibrateSystem()
            return
        }
        if playCoreHaptics(intensity: intensity, sharpness: sharpness, duration: duration) {
            return
        }
        if intensity >= 0.95 {
            mediumGenerator.impactOccurred(intensity: CGFloat(intensity))
            mediumGenerator.prepare()
        } else {
            lightGenerator.impactOccurred(intensity: CGFloat(intensity))
            lightGenerator.prepare()
        }
        lastMechanism = "UIKit-генератор"
    }

    private static func playCoreHaptics(intensity: Float,
                                        sharpness: Float,
                                        duration: TimeInterval) -> Bool {
        startEngineIfNeeded()
        guard let engine else { return false }
        let parameters = [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
        ]
        let event = CHHapticEvent(eventType: .hapticContinuous,
                                  parameters: parameters,
                                  relativeTime: 0,
                                  duration: max(duration, 0.02))
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            lastMechanism = "Core Haptics"
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Системная вибрация: не зависит от Core Haptics и аудиосессии камеры.
    private static func vibrateSystem() {
        AudioServicesPlaySystemSound(vibrateSoundID)
        lastMechanism = "системная вибрация"
    }
}
