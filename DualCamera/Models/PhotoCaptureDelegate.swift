import AVFoundation

/// Делегат одиночного снимка.
///
/// `AVCapturePhotoOutput` не удерживает переданного делегата, поэтому
/// `CameraManager` хранит экземпляры этого класса до завершения съёмки.
final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {

    /// Вызывается один раз по завершении обработки фото.
    var completion: ((Data?, Error?) -> Void)?
    private var isFinished = false

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard !isFinished else { return }
        isFinished = true

        // Разрываем возможный цикл ссылок до вызова замыкания.
        let completion = self.completion
        self.completion = nil

        if let error {
            completion?(nil, error)
        } else if let data = photo.fileDataRepresentation() {
            completion?(data, nil)
        } else {
            completion?(nil, CameraError.captureFailed)
        }
    }
}
