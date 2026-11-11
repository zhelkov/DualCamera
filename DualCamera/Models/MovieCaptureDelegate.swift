import AVFoundation

/// Делегат записи одного видео-клипа.
///
/// `AVCaptureMovieFileOutput` не удерживает переданного делегата, поэтому
/// `CameraManager` хранит экземпляры этого класса до конца записи.
final class MovieCaptureDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {

    /// Какой камере принадлежит запись.
    enum Camera {
        case back
        case front
    }

    let camera: Camera
    /// Вызывается один раз по завершении записи файла.
    var completion: ((Camera, URL?, Error?) -> Void)?

    init(camera: Camera) {
        self.camera = camera
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        let completion = self.completion
        self.completion = nil
        // Keep the URL with the error: AVFoundation may report a stop error
        // while also marking the movie as successfully finished.
        completion?(camera, outputFileURL, error)
    }
}
