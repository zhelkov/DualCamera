import AudioToolbox
import AVFoundation
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
        let audio = AVAudioSession.sharedInstance()
        var lines = [
            "Поддержка устройства: \(supportsHaptics ? "да" : "нет")",
            "Движок Core Haptics: \(engine != nil ? "запущен" : "не запущен")",
            "Аудиосессия: \(audio.category.rawValue), активна: \(audio.isActive ? "да" : "нет")",
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

    /// Отклик на обычное действие: короткий одиночный «тик», как в системных
    /// приложениях.
    static func selection() {
        tick(intensity: 0.9, sharpness: 0.5)
    }

    /// Отклик на значимое действие: чуть более плотный тик.
    static func impact() {
        tick(intensity: 1.0, sharpness: 0.7)
    }

    /// Проверка из настроек: сначала одиночный тик, затем системная вибрация.
    static func test() {
        tick(intensity: 1.0, sharpness: 0.7)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            vibrateSystem()
            lastMechanism = "тик + системная вибрация"
        }
    }

    /// Одиночный короткий импульс (transient) — самый отчётливый отклик.
    private static func tick(intensity: Float, sharpness: Float) {
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
        lastMechanism = "UIKit-генератор"
    }

    private static func playTransientCoreHaptics(intensity: Float, sharpness: Float) -> Bool {
        startEngineIfNeeded()
        guard let engine else { return false }
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
            // Пересоздадим движок при следующем вызове: если он попал
            // в нерабочее состояние, это единственный способ оживить.
            engine = nil
            return false
        }
    }

    /// Системная вибрация: не зависит от Core Haptics и аудиосессии камеры.
    private static func vibrateSystem() {
        AudioServicesPlaySystemSound(vibrateSoundID)
        lastMechanism = "системная вибрация"
    }
}
