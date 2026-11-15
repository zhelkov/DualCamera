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
    @State private var videoDiagnostics: String?

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

                if let videoDiagnostics {
                    Text(videoDiagnostics)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .padding(.horizontal)
                }

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
                inspectVideoTracks()
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

    private func inspectVideoTracks() {
        Task { @MainActor in
            let asset = AVURLAsset(url: videoURL)
            do {
                let assetDuration = try await asset.load(.duration).seconds
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)

                var videoDuration: Double = 0
                var frameRate: Float = 0
                if let track = videoTracks.first {
                    videoDuration = try await track.load(.timeRange).duration.seconds
                    frameRate = try await track.load(.nominalFrameRate)
                }

                var audioDurationText = "нет"
                if let track = audioTracks.first {
                    let range = try await track.load(.timeRange)
                    audioDurationText = String(format: "%.2f с", range.duration.seconds)
                }

                videoDiagnostics = String(
                    format: "Файл %.2f с · видео %.2f с · звук %@ · %.1f кадр/с",
                    assetDuration,
                    videoDuration,
                    audioDurationText,
                    frameRate
                )
            } catch {
                videoDiagnostics = "Не удалось прочитать параметры видео: \(error.localizedDescription)"
            }
        }
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
