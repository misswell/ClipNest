import SwiftUI
#if os(iOS)
import UIKit
#endif

enum EditorMode: String, CaseIterable, Identifiable {
    case edit = "Edit"
    case split = "Split"
    case preview = "Preview"
    static let persistenceKey = "editor.lastMode"

    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .edit: return "square.and.pencil"
        case .split: return "rectangle.split.2x1"
        case .preview: return "eye"
        }
    }
}

/// Editor + live preview for a single markdown/text file. Autosaves on edit.
struct MarkdownEditorView: View {
    @EnvironmentObject var store: VaultStore
    let url: URL

    @State private var text: String = ""
    // Split needs a wide layout. On iPhone it is intentionally hidden and Edit is
    // the useful initial mode instead of rendering a transient empty split editor.
    @AppStorage(EditorMode.persistenceKey) private var storedMode = EditorMode.edit.rawValue
    @State private var saveTask: Task<Void, Never>?
    @State private var hasLoadedText = false
    @State private var loadedTextSnapshot = ""
    @State private var loadedURL: URL?
    @State private var isEditorReady = false
    @State private var loadError: String?
    @State private var reloadAttempt = 0
    @State private var loadRequestGate = DocumentLoadRequestGate()
    @State private var showDeleteConfirmation = false
    @Environment(\.horizontalSizeClass) private var hSize

    private var isWide: Bool { hSize != .compact }

    private var mode: EditorMode {
        EditorMode(rawValue: storedMode) ?? .edit
    }

    private var modeBinding: Binding<EditorMode> {
        Binding(
            get: { EditorMode(rawValue: storedMode) ?? .edit },
            set: { storedMode = $0.rawValue }
        )
    }

    private struct LoadKey: Equatable {
        let url: URL
        let attempt: Int
    }

    var body: some View {
        ZStack {
            // Do not construct TextEditor during the NavigationSplitView push. UIKit's text
            // view performs synchronous text-container setup even when its initial text is
            // empty, which is enough to hitch the transition on a real device. Mount it only
            // after the detached read has completed.
            if isEditorReady, hasLoadedText, loadedURL == url {
                editorContent
            } else if loadError != nil {
                loadFailureView
            } else if hasLoadedText, loadedURL == url {
                // This state is kept as a safety net for an interrupted load. Do not render a
                // second scroll view here: mounting it during a navigation push causes another
                // layout pass and was the remaining source of the visible hitch.
                ProgressView("Preparing editor…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Reading document…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(url.deletingPathExtension().lastPathComponent)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            // Keep the segmented control and delete action out of the push transaction together
            // with TextEditor until the document has finished loading.
            if isEditorReady, hasLoadedText, loadedURL == url {
                toolbarContent
            }
        }
        .alert("Delete Note", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                deleteCurrentNote()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This note will be removed from the vault.")
        }
        .task(id: LoadKey(url: url, attempt: reloadAttempt)) {
            // Detached iCloud reads can finish after a newer document has already loaded. Give
            // this request a generation before the first suspension so stale results can never
            // overwrite the current editor state.
            let loadRequest = loadRequestGate.begin(for: url)
            // The host view is reused when the user switches notes, so `url` is already the
            // NEW document here while `text` still holds the previous one. Flush that pending
            // edit to its own file — never to the newly selected document.
            if let previous = loadedURL, previous != url, text != loadedTextSnapshot {
                store.save(text, to: previous)
            }
            saveTask?.cancel()
            hasLoadedText = false
            isEditorReady = false
            loadedURL = nil
            loadedTextSnapshot = ""
            text = ""
            loadError = nil
            // Read immediately in the background, but do not mount UIKit's TextEditor until the
            // compact NavigationSplitView push has had time to finish. A fast read must not put
            // the expensive native text-container setup back into the transition.
            await Task.yield()
            guard loadRequestGate.accepts(loadRequest) else { return }
            let target = url
            let readTask = Task.detached(priority: .utility) {
                Result { try VaultStore.readText(at: target) }
            }
            // A local read often finishes before NavigationSplitView's compact push. Keep the
            // detail as a single lightweight ProgressView until that transition has settled;
            // otherwise replacing it with a ScrollView/TextEditor in the same animation causes
            // a frame hitch even though the file read itself is off the main actor.
            let settleNanoseconds: UInt64 = isWide ? 60_000_000 : 400_000_000
            try? await Task.sleep(nanoseconds: settleNanoseconds)
            let result = await readTask.value
            // The push transition can transiently cancel this SwiftUI task; early-returning on
            // cancellation would orphan the loading spinner forever (the id never changes after
            // that), so a still-current result is applied even after cancellation. The request
            // generation, rather than captured `url` values, proves that no newer load has begun.
            guard loadRequestGate.accepts(loadRequest) else { return }
            switch result {
            case .success(let loadedText):
                loadedTextSnapshot = loadedText
                text = loadedText
                loadedURL = url
                hasLoadedText = true
                isEditorReady = true
            case .failure(let error):
                loadError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
        .onDisappear { flushSave() }
    }

    private var loadFailureView: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 42))
                .foregroundStyle(Theme.mutedInk)
            Text("Cannot Read Document")
                .font(.headline)
            Text(loadError ?? "")
                .font(.subheadline)
                .foregroundStyle(Theme.mutedInk)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                reloadAttempt &+= 1
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    @ViewBuilder
    private var editorContent: some View {
        switch effectiveMode {
        case .edit:
            editor
        case .preview:
            preview
        case .split:
            HStack(spacing: 0) {
                editor
                Divider()
                preview
            }
        }
    }

    /// On compact widths Split collapses to Edit (panes too narrow side-by-side).
    private var effectiveMode: EditorMode {
        (mode == .split && !isWide) ? .edit : mode
    }

    private var editor: some View {
        InsertableTextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .onChange(of: text) { _, newValue in
                guard hasLoadedText, newValue != loadedTextSnapshot else { return }
                scheduleSave(newValue)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
    }

    private var preview: some View {
        MarkdownPreview(
            markdown: text,
            resolveImage: { src in store.resolveImageURL(src, relativeTo: url) },
            documentURL: url,
            vaultRootURL: store.rootURL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("View", selection: modeBinding) {
                ForEach(EditorMode.allCases.filter { isWide || $0 != .split }) { m in
                    Image(systemName: m.systemImage).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: isWide ? 130 : 88)

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Delete Note")
            .help("Delete Note")
        }
    }

    private func deleteCurrentNote() {
        // A debounced edit must not recreate a note after the user has just deleted it, and the
        // disappearance callback must not flush the editor back to the removed URL.
        saveTask?.cancel()
        hasLoadedText = false
        isEditorReady = false
        loadedURL = nil
        store.delete(url)
    }

    // MARK: - Saving
    private func scheduleSave(_ value: String) {
        guard hasLoadedText, value != loadedTextSnapshot else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            store.save(value, to: url)
        }
    }

    private func flushSave() {
        // Never rewrite the document unless the text actually diverged from what was
        // loaded: a failed read must not be able to wipe the file with empty content.
        guard hasLoadedText, text != loadedTextSnapshot else { return }
        saveTask?.cancel()
        store.save(text, to: url)
    }

    // MARK: - Insert helpers (append-based; simple and reliable cross-platform)
    private func insert(snippet: String) {
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += snippet
    }
    private func insert(wrap: String) { insert(snippet: "\(wrap)text\(wrap)") }
    private func insertLinePrefix(_ prefix: String) { insert(snippet: "\(prefix)") }

    private enum Snippets {
        static let table = """
        | Name | Status | Notes |
        | --- | --- | --- |
        | Item 1 | Done | First note |
        | Item 2 | In progress | Second note |
        """
        static let image = "![alt text](image.png)"
        static let codeBlock = "```swift\n// code\n```"
    }
}

/// A plain cross-platform multiline text editor wrapper (keeps a single call-site
/// in case we later swap in a richer editor with cursor-aware insertion).
private struct InsertableTextEditor: View {
    @Binding var text: String
    var body: some View {
        #if os(iOS)
        ProgressiveTextEditor(text: $text)
        #else
        TextEditor(text: $text)
            .scrollContentBackground(.hidden)
            .padding(8)
        #endif
    }
}

#if os(iOS)
/// A UITextView that hydrates large documents in small main-run-loop slices. TextEditor assigns
/// its entire String while the native view is being created, which can block a NavigationSplitView
/// push for hundreds of milliseconds on a large note. The document remains read-only for the very
/// short hydration window, then becomes a normal editable text view with the complete source.
private struct ProgressiveTextEditor: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = UIFont.monospacedSystemFont(ofSize: 17, weight: .regular)
        view.textColor = .label
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.autocorrectionType = .yes
        view.autocapitalizationType = .sentences
        view.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.textContainer.lineFragmentPadding = 0
        context.coordinator.startHydration(text, in: view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        // The binding already contains the complete source while the text view is being
        // hydrated. Do not replace its progressively-built text with the full source here.
        guard !context.coordinator.isHydrating else { return }
        guard view.text != text else { return }
        let selectedRange = view.selectedRange
        view.text = text
        view.selectedRange = NSRange(
            location: min(selectedRange.location, (text as NSString).length),
            length: 0)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let text: Binding<String>
        weak var textView: UITextView?
        private var hydrationTask: Task<Void, Never>?
        private(set) var isHydrating = false

        init(text: Binding<String>) {
            self.text = text
        }

        deinit {
            hydrationTask?.cancel()
        }

        func startHydration(_ value: String, in view: UITextView) {
            hydrationTask?.cancel()
            textView = view
            isHydrating = true
            view.isEditable = false
            view.text = ""

            hydrationTask = Task { @MainActor [weak self, weak view] in
                guard let self, let view else { return }
                var index = value.startIndex
                let chunkSize = 8_192

                while index < value.endIndex {
                    guard !Task.isCancelled else { return }
                    let end = value.index(
                        index,
                        offsetBy: chunkSize,
                        limitedBy: value.endIndex) ?? value.endIndex
                    let chunk = String(value[index..<end])

                    view.textStorage.beginEditing()
                    view.textStorage.replaceCharacters(
                        in: NSRange(location: view.textStorage.length, length: 0),
                        with: chunk)
                    view.textStorage.endEditing()
                    index = end

                    // Let UIKit draw between chunks. This keeps a large note responsive while
                    // the remaining source is added, instead of producing one long frame hitch.
                    if index < value.endIndex {
                        try? await Task.sleep(nanoseconds: 2_000_000)
                    }
                }

                guard !Task.isCancelled else { return }
                self.isHydrating = false
                view.isEditable = true
                view.setNeedsLayout()
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isHydrating else { return }
            text.wrappedValue = textView.text
        }
    }
}
#endif
