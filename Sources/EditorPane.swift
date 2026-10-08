#if os(macOS)
import SwiftUI

/// Center editor for the VS Code layout. Obsidian-style: render Markdown nicely (Preview),
/// show the raw source (Edit), or both side-by-side (Split). Autosaves on edit.
struct EditorPane: View {
    @EnvironmentObject var store: VaultStore
    let url: URL
    @Binding var mode: EditorMode

    @State private var text = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var hasLoadedText = false
    @State private var loadedTextSnapshot = ""
    @State private var loadedURL: URL?
    @State private var isEditorReady = false
    @State private var loadError: String?
    @State private var isLoadingFromCloud = false
    @State private var reloadAttempt = 0
    @State private var loadRequestGate = DocumentLoadRequestGate()
    @State private var showInspector = false
    @State private var showPresentation = false
    @State private var scrollHeading: String?
    @State private var missingLink: String?
    @State private var showMissingLink = false

    private var normalizedURL: URL { url.standardizedFileURL }

    private struct LoadKey: Equatable {
        let url: URL
        let attempt: Int

        init(url: URL, attempt: Int) {
            self.url = url.standardizedFileURL
            self.attempt = attempt
        }
    }

    var body: some View {
        ZStack {
            if isEditorReady, hasLoadedText, loadedURL == normalizedURL {
                // Keep the native NSTextView out of the transition. Its initial layout and
                // syntax storage setup are synchronous, even when the document is empty.
                editorContent
            } else if loadError != nil {
                loadFailureView
            } else if isLoadingFromCloud {
                ProgressView("Downloading from iCloud…")
            } else {
                ProgressView("Reading document…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VSCode.editorBg)
        .task(id: LoadKey(url: url, attempt: reloadAttempt)) {
            // A cancelled `.task` still runs its body, so it must never be allowed to claim the load.
            guard let loadRequest = loadRequestGate.begin(for: url, isCancelled: Task.isCancelled) else {
                return
            }
            // The host view is reused across tabs; flush the previous document's pending edit
            // to its own file — never to the newly selected one.
            if let previous = loadedURL, previous != normalizedURL, text != loadedTextSnapshot {
                store.save(text, to: previous)
            }
            saveTask?.cancel()
            hasLoadedText = false
            isEditorReady = false
            loadedURL = nil
            loadedTextSnapshot = ""
            text = ""
            loadError = nil
            isLoadingFromCloud = false
            await Task.yield()
            guard loadRequestGate.accepts(loadRequest) else { return }
            let target = normalizedURL
            let readTask = Task.detached(priority: .utility) { () -> Result<String, Error> in
                do {
                    let loaded = try await VaultFileAccess.shared.readText(at: target) { phase in
                        guard phase == .downloading else { return }
                        Task { @MainActor in
                            guard loadRequestGate.accepts(loadRequest) else { return }
                            isLoadingFromCloud = true
                        }
                    }
                    return .success(loaded)
                } catch {
                    return .failure(error)
                }
            }
            // There is no system push transition on macOS, but one run-loop-sized grace period
            // keeps NSTextView construction out of the same event that changes the active tab.
            try? await Task.sleep(nanoseconds: 60_000_000)
            let result = await readTask.value
            // Apply the result even if this SwiftUI task was transiently cancelled during a
            // tab switch (an abandoned load would leave the pane spinning forever), but only
            // when no newer tab load has superseded this request.
            guard loadRequestGate.accepts(loadRequest) else { return }
            switch result {
            case .success(let loadedText):
                loadedTextSnapshot = loadedText
                text = loadedText
                loadedURL = target
                hasLoadedText = true
                isEditorReady = true
                scrollHeading = nil
                if let location = store.pendingNoteFragment {
                    if location.url == target, !location.fragment.isEmpty {
                        mode = .preview
                        scrollHeading = location.fragment
                    }
                    store.pendingNoteFragment = nil
                }
            case .failure(let error):
                loadError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
        .onDisappear { flush() }
        .onReceive(NotificationCenter.default.publisher(for: .saveBeforeSoftwareUpdate)) { _ in flush() }
        .onChange(of: store.lastLinkMutation) { _, mutation in
            guard let mutation, let current = loadedURL else { return }
            saveTask?.cancel()
            if mutation.isMerge && current == mutation.source { hasLoadedText = false; loadedURL = nil; isEditorReady = false; return }
            text = mutation.rewrite(text, at: current)
            loadedTextSnapshot = mutation.rewrite(loadedTextSnapshot, at: current)
            loadedURL = VaultDocumentMove(source: mutation.source, destination: mutation.destination).relocated(current)
            if text != loadedTextSnapshot, let loadedURL { store.save(text, to: loadedURL) }
        }
        .overlay(alignment: .bottomTrailing) {
            if isEditorReady {
                HStack {
                    Button("Start Presentation") { showPresentation = true }
                    Button { flush(); showInspector = true } label: { Label("Note Details", systemImage: "list.bullet.rectangle") }
                }.buttonStyle(.bordered).padding(8)
            }
        }
        .sheet(isPresented: $showInspector) {
            NoteInspectorView(url: normalizedURL, text: $text, onOpen: { flush(); store.selectedFileURL = $0 },
                              onHeading: { mode = .preview; scrollHeading = $0 })
        }
        .alert("Create Linked Note?", isPresented: $showMissingLink) {
            Button("Create") { if let missingLink { _ = store.openOrCreateNote(path: MarkdownKnowledge.splitTarget(missingLink).path) } }
            Button("Cancel", role: .cancel) { missingLink = nil }
        } message: { Text(missingLink ?? "") }
        .sheet(isPresented: $showPresentation) { NotePresentationView(text: text, url: normalizedURL) }
    }

    private var loadFailureView: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 42))
                .foregroundStyle(VSCode.muted)
            Text("Cannot Read Document")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(VSCode.fg)
            Text(loadError ?? "")
                .font(.system(size: 12))
                .foregroundStyle(VSCode.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                reloadAttempt &+= 1
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var editorContent: some View {
        switch mode {
        case .edit:
            rawEditor
        case .preview:
            preview
        case .split:
            HStack(spacing: 0) {
                rawEditor
                Divider().overlay(VSCode.border)
                preview
            }
        }
    }

    private var rawEditor: some View {
        CodeEditorView(text: $text, documentID: normalizedURL)
            .background(VSCode.editorBg)
            .onChange(of: text) { _, v in
                guard hasLoadedText else { return }
                schedule(v)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var preview: some View {
        MarkdownPreview(
            markdown: text,
            resolveImage: { store.resolveImageURL($0, relativeTo: normalizedURL) },
            documentURL: normalizedURL,
            vaultRootURL: store.rootURL,
            onToggleCheckbox: toggleCheckbox,
            onOpenNote: { target in
                Task {
                    if let resolved = await store.resolveNote(target, from: normalizedURL) {
                        if resolved == normalizedURL { scrollHeading = MarkdownKnowledge.splitTarget(target).fragment }
                        else {
                            flush()
                            store.pendingNoteFragment = (resolved, MarkdownKnowledge.splitTarget(target).fragment)
                            store.selectedFileURL = resolved
                        }
                    } else { missingLink = target; showMissingLink = true }
                }
            }, scrollHeading: scrollHeading)
    }

    /// Flip the Nth `- [ ]`/`- [x]` line in the source (Obsidian-style) and persist immediately.
    private func toggleCheckbox(_ index: Int) {
        guard hasLoadedText, let updated = MarkdownParser.togglingCheckbox(at: index, in: text) else { return }
        saveTask?.cancel()
        text = updated
        store.save(updated, to: normalizedURL)
    }

    private func schedule(_ value: String) {
        saveTask?.cancel()
        guard hasLoadedText, let target = loadedURL else { return }
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            store.save(value, to: target)
        }
    }

    private func flush() {
        // Never rewrite the document unless the text actually diverged from what was
        // loaded: a failed read must not be able to wipe the file with empty content.
        saveTask?.cancel()
        guard hasLoadedText, let target = loadedURL, text != loadedTextSnapshot else { return }
        store.save(text, to: target)
    }
}

/// Compact dark segmented control for Edit / Split / Preview.
struct ModeToggle: View {
    @Binding var mode: EditorMode

    var body: some View {
        HStack(spacing: 0) {
            ForEach(EditorMode.allCases) { m in
                Button { mode = m } label: {
                    Image(systemName: m.systemImage)
                        .font(.system(size: 11))
                        .foregroundStyle(mode == m ? VSCode.activeIcon : VSCode.muted)
                        .frame(width: 30, height: 22)
                        .background(mode == m ? VSCode.hoverBg : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(m.title)
            }
        }
        .background(VSCode.hoverBg, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(VSCode.border))
    }
}
#endif
