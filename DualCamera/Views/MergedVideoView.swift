import SwiftUI
import AVKit
import Photos

/// Экран результата записи: показывает объединённое видео и позволяет сохранить его.
struct MergedVideoView: View {
    let videoURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var saveErrorMessage: String?

    var body: some View {
        NavigationStack {
            VStack {
                if let player {
                    VideoPlayer(player: player)
                        .frame(height: 320)
                        .padding()
                } else {
                    Rectangle()
                        .fill(.black)
                        .frame(height: 320)
                        .padding()
                }

                Button("Сохранить в Фото") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
            .navigationTitle("Видео")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .onAppear {
                player = AVPlayer(url: videoURL)
            }
            .onDisappear {
                player?.pause()
            }
            .alert("Ошибка сохранения", isPresented: saveErrorBinding) {
                Button("ОК", role: .cancel) {}
            } message: {
                Text(saveErrorMessage ?? "")
            }
        }
    }

    private var saveErrorBinding: Binding<Bool> {
        Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )
    }

    private func save() {
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
        } completionHandler: { success, error in
            DispatchQueue.main.async {
                if success {
                    dismiss()
                } else {
                    saveErrorMessage = error?.localizedDescription ?? "Не удалось сохранить видео."
                }
            }
        }
    }
}
