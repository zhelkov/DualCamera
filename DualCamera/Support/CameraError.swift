import Foundation

/// Ошибки камеры с понятным описанием для пользователя.
enum CameraError: LocalizedError {
    case multiCamUnsupported
    case permissionDenied
    case noCompatibleDevices
    case noCompatibleFormat
    case inputFailed
    case outputFailed
    case connectionFailed
    case captureFailed
    case videoMergeFailed

    var errorDescription: String? {
        switch self {
        case .multiCamUnsupported:
            return "Это устройство не поддерживает одновременную съёмку с двух камер."
        case .permissionDenied:
            return "Нет доступа к камере. Разрешите доступ в настройках."
        case .noCompatibleDevices:
            return "Не найдена совместимая пара передней и задней камер."
        case .noCompatibleFormat:
            return "Не найден формат, поддерживающий одновременную работу камер."
        case .inputFailed:
            return "Не удалось подключить камеру к сессии."
        case .outputFailed:
            return "Не удалось настроить захват фото."
        case .connectionFailed:
            return "Не удалось создать соединение для камеры."
        case .captureFailed:
            return "Не удалось сделать снимок."
        case .videoMergeFailed:
            return "Не удалось объединить видео."
        }
    }
}
