import SwiftUI
import AVKit
import Photos

/// Экран результата записи: показывает объединённое видео, которое сохраняется автоматически.
struct MergedVideoView: View {
    let videoURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var saveErrorMessage: String?
    @State private var saveStatus = "Сохраняем видео в Фото…"
    @State private var isSaving = true
    @State private var didStartSaving = false

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

                HStack(spacing: 8) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Image(systemName: saveErrorMessage == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    }
                    Text(saveStatus)
                        .font(.subheadline)
                }
                .padding()

                if saveErrorMessage != nil {
                    Button("Повторить сохранение") {
                        save()
                    }
                    .buttonStyle(.bordered)
                    .padding(.bottom)
                }
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
                guard !didStartSaving else { return }
                didStartSaving = true
                save()
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
        isSaving = true
        saveErrorMessage = nil
        saveStatus = "Сохраняем видео в Фото…"

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    isSaving = false
                    saveStatus = "Нет доступа к Фото"
                    saveErrorMessage = "Разрешите приложению добавлять видео в медиатеку в настройках iPhone."
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    if success {
                        isSaving = false
                        saveStatus = "Видео сохранено в Фото"
                    } else {
                        isSaving = false
                        saveStatus = "Не удалось сохранить видео"
                        saveErrorMessage = error?.localizedDescription ?? "Не удалось сохранить видео."
                    }
                }
            }
        }
    }
}
