import CoreHaptics
import UIKit

/// Тактильная отдача. Основной путь — Core Haptics с `playsHapticsOnly`:
/// такой движок не вступает в конфликт с аудиосессией камеры.
/// UIKit-генераторы остаются как резерв.
enum Haptics {
    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static var engine: CHHapticEngine?

    /// Последняя ошибка движка — показываем в настройках для диагностики.
    private(set) static var lastError: String?

    /// Поддерживает ли железо тактильную отдачу.
    static var supportsHaptics: Bool {
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    /// Состояние движка для экрана настроек.
    static var diagnosticText: String {
        var lines = [
            "Поддержка устройства: \(supportsHaptics ? "да" : "нет")",
            "Движок: \(engine != nil ? "запущен" : "не запущен")"
        ]
        if let lastError {
            lines.append("Ошибка: \(lastError)")
        }
        return lines.joined(separator: "\n")
    }

    /// Прогревает моторы и запускает движок заранее.
    static func prepare() {
        lightGenerator.prepare()
        mediumGenerator.prepare()
        startEngineIfNeeded()
    }

    private static func startEngineIfNeeded() {
        guard supportsHaptics, engine == nil else { return }
        do {
            let newEngine = try CHHapticEngine()
            // Только тактильность: не трогаем аудиосессию, которую
            // занимает запись с камер.
            newEngine.playsHapticsOnly = true
            newEngine.isAutoShutdownEnabled = false
            newEngine.stoppedHandler = { _ in engine = nil }
            newEngine.resetHandler = {
                try? engine?.start()
            }
            try newEngine.start()
            engine = newEngine
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func play(intensity: Float, sharpness: Float) {
        startEngineIfNeeded()
        if let engine {
            let event = CHHapticEvent(eventType: .hapticTransient,
                                      parameters: [
                                        CHHapticEventParameter(parameterID: .hapticIntensity,
                                                               value: intensity),
                                        CHHapticEventParameter(parameterID: .hapticSharpness,
                                                               value: sharpness)
                                      ],
                                      relativeTime: 0)
            if let pattern = try? CHHapticPattern(events: [event], parameters: []),
               let player = try? engine.makePlayer(with: pattern) {
                do {
                    try player.start(atTime: CHHapticTimeImmediate)
                    return
                } catch {
                    lastError = error.localizedDescription
                }
            }
            do {
                try engine.start()
            } catch {
                lastError = error.localizedDescription
            }
            return
        }

        // Резерв: UIKit-генераторы, если Core Haptics недоступен.
        switch intensity {
        case 0.95...:
            mediumGenerator.impactOccurred(intensity: CGFloat(intensity))
            mediumGenerator.prepare()
        default:
            lightGenerator.impactOccurred(intensity: CGFloat(intensity))
            lightGenerator.prepare()
        }
    }

    /// Отклик на обычное действие: переходы, выбор режима, зум.
    static func selection() {
        play(intensity: 0.85, sharpness: 0.35)
    }

    /// Отклик на значимое действие: старт и стоп записи.
    static func impact() {
        play(intensity: 1.0, sharpness: 0.55)
    }

    /// Проверка из настроек: работает независимо от переключателя.
    static func test() {
        play(intensity: 1.0, sharpness: 0.5)
    }
}
