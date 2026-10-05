import SwiftUI
import AVFoundation
import AVKit

struct NoteAudioRecorderView: View {
    @EnvironmentObject private var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    let document: URL
    @Binding var text: String
    @State private var recorder: AVAudioRecorder?
    @State private var temporaryURL: URL?
    @State private var error: String?
    @State private var isRecording = false
    @State private var isBusy = false

    var body: some View {
        NavigationStack {
            VStack(spacing: AppMetrics.sectionSpacing) {
                Image(systemName: isRecording ? "waveform" : "mic").font(.largeTitle).foregroundStyle(Theme.accent)
                TimelineView(.periodic(from: Date(), by: 1)) { _ in
                    Text(Duration.seconds(recorder?.currentTime ?? 0).formatted(.time(pattern: .minuteSecond)))
                        .font(.largeTitle.monospacedDigit())
                }
                if let error { Text(error).foregroundStyle(Theme.mutedInk) }
                if isRecording { Button("Stop and Save Recording") { finish() }.buttonStyle(.borderedProminent) }
                else { Button("Start Recording") { Task { await start() } }.buttonStyle(.borderedProminent) }
                Text("Recordings are saved as audio attachments in your vault.").font(.caption)
            }
            .padding(AppMetrics.screenHorizontal).frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Audio Recorder")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isBusy) } }
            .disabled(isBusy)
            .interactiveDismissDisabled(isBusy || isRecording)
            .onDisappear { cleanup() }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 360)
        #endif
    }

    private func start() async {
        isBusy = true
        defer { isBusy = false }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            error = String(localized: "Microphone access is disabled. Enable it in system settings to record audio.")
            return
        }
        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ClipNest-Recording-" + UUID().uuidString + ".m4a")
            temporaryURL = url
            let recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue])
            guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
            self.recorder = recorder
            isRecording = true
            error = nil
        } catch { self.error = error.localizedDescription; cleanup() }
    }

    private func finish() {
        recorder?.stop()
        isRecording = false
        guard let file = temporaryURL, let root = store.rootURL,
              VaultNoteCatalog.isInside(document, root: root) else { error = String(localized: "The vault is no longer available."); return }
        isBusy = true
        Task {
            do {
                let attachment = try await Task.detached(priority: .utility) { try VaultFileAccess.importMedia(from: file, root: root) }.value
                guard store.rootURL == root else { dismiss(); return }
                let path = MarkdownKnowledge.relativePath(attachment, to: document.deletingLastPathComponent())
                text += (text.hasSuffix("\n") ? "" : "\n") + "![Recording](" + path + ")\n"
                store.save(text, to: document)
                store.refresh(); store.notifyFileChanges([attachment])
                dismiss()
            } catch { self.error = error.localizedDescription }
            isBusy = false
        }
    }

    private func cleanup() {
        recorder?.stop()
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

struct NoteMediaPlayer: View {
    @EnvironmentObject private var store: VaultStore
    let source: String
    let document: URL
    @State private var player: AVPlayer?
    @State private var previewURL: URL?
    @State private var error: String?

    var body: some View {
        Group {
            if let player { VideoPlayer(player: player) }
            else if let error { Text(error).font(.caption).foregroundStyle(Theme.mutedInk) }
            else { ProgressView() }
        }
        .frame(height: ["m4a", "mp3", "wav", "aac", "ogg", "flac"].contains((source as NSString).pathExtension.lowercased()) ? 90 : 240)
        .task(id: source) {
            do {
                let expectedRoot = store.rootURL
                let resolved = await Task.detached(priority: .utility) { VaultStore.resolveImageURL(source, relativeTo: document, rootURL: expectedRoot) }.value
                guard let resolved, let root = store.rootURL, VaultNoteCatalog.isInside(resolved, root: root) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let copy = try await VaultFileAccess.shared.mediaPreviewCopy(at: resolved)
                guard !Task.isCancelled else { try? FileManager.default.removeItem(at: copy); return }
                previewURL = copy
                player = AVPlayer(url: copy)
            } catch { self.error = error.localizedDescription }
        }
        .onDisappear { player?.pause(); if let previewURL { try? FileManager.default.removeItem(at: previewURL) } }
    }
}
