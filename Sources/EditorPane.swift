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
    @State private var reloadAttempt = 0
    @State private var loadRequestGate = DocumentLoadRequestGate()

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
            } else {
                ProgressView("Reading document…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VSCode.editorBg)
        .task(id: LoadKey(url: url, attempt: reloadAttempt)) {
            let loadRequest = loadRequestGate.begin(for: url)
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
            await Task.yield()
            guard loadRequestGate.accepts(loadRequest) else { return }
            let target = normalizedURL
            let readTask = Task.detached(priority: .utility) {
                Result { try VaultStore.readText(at: target) }
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
            case .failure(let error):
                loadError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
        .onDisappear { flush() }
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
                guard hasLoadedText, v != loadedTextSnapshot else { return }
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
            onToggleCheckbox: toggleCheckbox)
    }

    /// Flip the Nth `- [ ]`/`- [x]` line in the source (Obsidian-style) and persist immediately.
    private func toggleCheckbox(_ index: Int) {
        var lines = text.components(separatedBy: "\n")
        var count = -1
        for i in lines.indices {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            let isUnchecked = trimmed.hasPrefix("- [ ]")
            let isChecked = trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]")
            guard isUnchecked || isChecked else { continue }
            count += 1
            if count == index {
                if isUnchecked {
                    lines[i] = lines[i].replacingOccurrences(of: "- [ ]", with: "- [x]")
                } else {
                    lines[i] = lines[i].replacingOccurrences(of: "- [x]", with: "- [ ]")
                                       .replacingOccurrences(of: "- [X]", with: "- [ ]")
                }
                break
            }
        }
        text = lines.joined(separator: "\n")
        store.save(text, to: normalizedURL)
    }

    private func schedule(_ value: String) {
        guard hasLoadedText, value != loadedTextSnapshot else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            store.save(value, to: url)
        }
    }

    private func flush() {
        // Never rewrite the document unless the text actually diverged from what was
        // loaded: a failed read must not be able to wipe the file with empty content.
        guard hasLoadedText, text != loadedTextSnapshot else { return }
        saveTask?.cancel()
        store.save(text, to: url)
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
                .help(m.rawValue)
            }
        }
        .background(Color(hex: 0x2A2A2A), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(VSCode.border))
    }
}
#endif
