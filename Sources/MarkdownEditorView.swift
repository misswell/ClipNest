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
        // `pencil` rather than `square.and.pencil`: the pencil-in-a-square carries its ink down
        // and to the right, so inside a centred 44 pt bar target it reads as sitting lower than
        // the eye beside it. A single diagonal glyph is optically centred, which matters more
        // now that Edit and Preview are two states of one button — a mismatch made the button
        // appear to jump when it flipped.
        case .edit: return "pencil"
        case .split: return "rectangle.split.2x1"
        case .preview: return "eye"
        }
    }
}

extension EditorMode {
    /// The mode a single-button toggle offers while `current` is on screen.
    ///
    /// Compact widths offer only Edit and Preview, and one button carries both: the glyph names
    /// the mode you get by tapping, so an eye appears while editing and a pencil while reading.
    /// A `.split` current mode only occurs on wide layouts, where the toggle is not used; it
    /// falls back to Preview, matching the initial mode for a document opened by tapping.
    static func toggleTarget(from current: EditorMode) -> EditorMode {
        current == .preview ? .edit : .preview
    }
}

/// Why a note is being opened. A tap anywhere in the browse surfaces means "show me this
/// note", so the detail always starts in Preview. Only an explicit Edit affordance starts in
/// the raw editor. The previous implementation persisted Edit/Preview in `@AppStorage`, which
/// meant one Edit session leaked into every later note.
enum NoteOpenIntent: Hashable {
    case view
    case edit

    var initialMode: EditorMode {
        switch self {
        case .view: return .preview
        case .edit: return .edit
        }
    }
}

/// Editor + live preview for a single markdown/text file. Autosaves on edit.
struct MarkdownEditorView: View {
    @EnvironmentObject var store: VaultStore
    let url: URL
    /// The mode this document starts in. Reset for every newly opened note — never persisted.
    var intent: NoteOpenIntent = .view

    @State private var text: String = ""
    /// Edit / Split / Preview for the *currently open* document only.
    @State private var mode: EditorMode = .preview
    /// The URL whose `intent` has already been applied, so a retry does not snap the user
    /// back to Preview while they are fixing a failure.
    @State private var intentURL: URL?
    @State private var saveTask: Task<Void, Never>?
    @State private var hasLoadedText = false
    @State private var loadedTextSnapshot = ""
    @State private var loadedURL: URL?
    @State private var loadState: DocumentLoadState = .idle
    @State private var reloadAttempt = 0
    @State private var loadRequestGate = DocumentLoadRequestGate()
    @State private var showDeleteConfirmation = false
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.colorScheme) private var colorScheme

    private var isWide: Bool { hSize != .compact }

    private var normalizedURL: URL { url.standardizedFileURL }

    private var isDocumentReady: Bool {
        hasLoadedText && loadedURL == normalizedURL
    }

    private var availableModes: [EditorMode] {
        EditorMode.allCases.filter { isWide || $0 != .split }
    }

    /// On compact widths Split collapses to Edit (the panes are too narrow side by side).
    private var effectiveMode: EditorMode {
        (mode == .split && !isWide) ? .edit : mode
    }

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
            if let message = loadState.failureMessage {
                loadFailureView(message)
            } else if isDocumentReady {
                // Preview renders the moment the text is in memory. The native text view is
                // only built when the user asks for Edit/Split, so opening a note never waits
                // on UITextView construction and never needs a fixed settle delay.
                documentContent
            } else {
                loadingView
            }
        }
        .navigationTitle(url.deletingPathExtension().lastPathComponent)
        .modifier(NavigationSubtitleModifier(text: folderSubtitle))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if isDocumentReady {
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
            await loadDocument()
        }
        .onDisappear { flushSave() }
    }

    // MARK: - Loading

    private func loadDocument() async {
        // Detached iCloud reads can finish after a newer document has already loaded. Give
        // this request a generation before the first suspension so stale results can never
        // overwrite the current editor state.
        // A cancelled `.task` still runs its body, so it must never be allowed to claim the load.
        guard let loadRequest = loadRequestGate.begin(for: url, isCancelled: Task.isCancelled) else {
            return
        }
        // The host view is reused when the user switches notes, so `url` is already the
        // NEW document here while `text` still holds the previous one. Flush that pending
        // edit to its own file — never to the newly selected document.
        if let previous = loadedURL, previous != normalizedURL, text != loadedTextSnapshot {
            store.save(text, to: previous)
        }
        saveTask?.cancel()
        hasLoadedText = false
        loadedURL = nil
        loadedTextSnapshot = ""
        text = ""
        loadState = .reading
        // A brand-new note always opens with its requested intent. A retry of the same
        // document keeps whatever mode the user is already in.
        if intentURL != normalizedURL {
            intentURL = normalizedURL
            mode = resolvedInitialMode
        }
        await Task.yield()
        guard loadRequestGate.accepts(loadRequest) else { return }
        let target = normalizedURL
        // The read must not inherit this SwiftUI task's cancellation.
        //
        // SwiftUI cancels and restarts `.task(id:)` while a navigation transition is settling, and
        // `VaultFileAccess.readData` throws `CancellationError` at its `Task.checkCancellation()`.
        // Swallowing that left `loadState` sitting on `.reading` with no task left to move it —
        // a spinner that never ends, which is exactly what opening a *second* note produced while
        // the first was fine. `EditorPane` has carried this same guard for the same reason;
        // the detached read applies its result whenever no newer load has superseded it.
        let readTask = Task.detached(priority: .utility) { () -> Result<String, Error> in
            do {
                let loaded = try await VaultFileAccess.shared.readText(at: target) { phase in
                    Task { @MainActor in
                        guard loadRequestGate.accepts(loadRequest) else { return }
                        switch phase {
                        case .downloading:
                            loadState = .downloading
                        case .reading, .writing:
                            loadState = .reading
                        }
                    }
                }
                return .success(loaded)
            } catch {
                return .failure(error)
            }
        }

        let result = await readTask.value
        // Apply even if this SwiftUI task was transiently cancelled, but never over a newer load.
        guard loadRequestGate.accepts(loadRequest) else { return }
        switch result {
        case .success(let loaded):
            loadedTextSnapshot = loaded
            text = loaded
            loadedURL = target
            hasLoadedText = true
            loadState = .ready
        case .failure(let error):
            loadState = .failed((error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription)
        }
    }

    private var resolvedInitialMode: EditorMode {
        let requested = intent.initialMode
        return (!isWide && requested == .split) ? .edit : requested
    }

    @ViewBuilder
    private var loadingView: some View {
        switch loadState {
        case .downloading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Downloading from iCloud…")
                    .font(.subheadline)
                    .foregroundStyle(Theme.mutedInk)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        default:
            ProgressView("Reading document…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
        }
    }

    private func loadFailureView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 42))
                .foregroundStyle(Theme.mutedInk)
            Text("Cannot Read Document")
                .font(.headline)
            Text(message)
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

    // MARK: - Content

    @ViewBuilder
    private var documentContent: some View {
        VStack(spacing: 0) {
            // Pre-iOS 26 navigation bars cannot render a subtitle, so the folder falls back
            // to a small breadcrumb above the content there.
            if !showsNavigationSubtitle {
                HStack(spacing: 4) {
                    AppRowIcon(systemImage: "folder", tint: Theme.mutedInk)
                    Text(folderSubtitle)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .font(.caption)
                .foregroundStyle(Theme.mutedInk)
                .padding(.horizontal, AppMetrics.screenHorizontal)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.background)
            }
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
    }

    private var editor: some View {
        InsertableTextEditor(text: $text, documentID: normalizedURL, colorScheme: colorScheme)
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
            resolveImage: { src in store.resolveImageURL(src, relativeTo: normalizedURL) },
            documentURL: normalizedURL,
            vaultRootURL: store.rootURL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Folder of the open note, relative to the vault root. Notes at the root fall back to
    /// the vault name so the subtitle always says something meaningful.
    private var folderSubtitle: String {
        guard let root = store.rootURL else { return "" }
        let rootPath = root.standardizedFileURL.path
        let filePath = normalizedURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return store.vaultName }
        let folderComponents = filePath
            .dropFirst(rootPath.count + 1)
            .split(separator: "/")
            .dropLast()
        guard !folderComponents.isEmpty else { return store.vaultName }
        return folderComponents.joined(separator: " / ")
    }

    private var showsNavigationSubtitle: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // One `ToolbarItem` holding both controls, rather than two items in a group.
        //
        // Each icon already carries a 44 pt frame, so that frame *is* the touch target and the
        // padding between glyphs. A `ToolbarItemGroup` adds roughly 23 pt of its own spacing on
        // top: measured on device, the two icon centres sat 67 pt apart, which is what made the
        // bar read as too wide. Keeping the frames and dropping the extra group spacing brings
        // the centres to 44 pt, with the hit targets untouched.
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 0) {
                toolbarButtons
            }
        }
    }

    @ViewBuilder
    private var toolbarButtons: some View {
        Group {
            if availableModes.count == 2 {
                // Compact widths only ever offer Edit and Preview, so two separate buttons spent
                // 88 pt of bar on one binary choice — and the pair read as a wide, unevenly
                // centred row next to the ellipsis. Collapsed into one toggle: the icon is the
                // mode you get by tapping, so an eye while editing and a pencil while reading.
                modeToggleButton
            } else {
                ForEach(availableModes) { candidate in
                    AppToolbarIconButton(
                        systemImage: candidate.systemImage,
                        isSelected: mode == candidate,
                        label: candidate.rawValue
                    ) {
                        mode = candidate
                    }
                }
            }

            if store.selection.documentSource == .quickPaste {
                AppToolbarIconButton(
                    systemImage: "trash",
                    role: .destructive,
                    label: "Delete Note"
                ) {
                    showDeleteConfirmation = true
                }
            } else {
                // A toolbar Menu pops down anchored to this button, so the destructive entry
                // stays visually connected to the ellipsis (a confirmationDialog would slide
                // up from the bottom edge, disconnected from the control that opened it).
                Menu {
                    Button("Delete Note", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .appToolbarIcon()
                }
                .accessibilityLabel("More")
            }
        }
    }

    /// The single Edit ⇄ Preview control used where only those two modes exist.
    ///
    /// The glyph names the destination rather than the current state, which is what makes a
    /// one-button toggle legible: seeing an eye means tapping takes you to reading, seeing a
    /// pencil means tapping takes you to editing.
    private var modeToggleButton: some View {
        let target = EditorMode.toggleTarget(from: effectiveMode)
        return AppToolbarIconButton(systemImage: target.systemImage, label: target.rawValue) {
            mode = target
        }
    }

    // MARK: - Actions

    private func deleteCurrentNote() {
        // A debounced edit must not recreate a note after the user has just deleted it, and the
        // disappearance callback must not flush the editor back to the removed URL.
        saveTask?.cancel()
        hasLoadedText = false
        loadedURL = nil
        loadState = .idle
        store.delete(url)
    }

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
}

/// navigationSubtitle is iOS 26+ on iOS but has existed on macOS for years, so the
/// availability gate only needs the iOS version; on macOS the branch is always taken.
private struct NavigationSubtitleModifier: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 11.0, *) {
            content.navigationSubtitle(Text(text))
        } else {
            content
        }
    }
}

/// A plain cross-platform multiline text editor wrapper (keeps a single call-site
/// in case we later swap in a richer editor with cursor-aware insertion).
private struct InsertableTextEditor: View {
    @Binding var text: String
    let documentID: URL
    let colorScheme: ColorScheme

    var body: some View {
        #if os(iOS)
        ProgressiveTextEditor(text: $text, documentID: documentID, colorScheme: colorScheme)
        #else
        TextEditor(text: $text)
            .scrollContentBackground(.hidden)
            .padding(8)
        #endif
    }
}

#if os(iOS)
/// A UITextView that hydrates large documents in small main-run-loop slices.
///
/// `TextEditor` assigns its entire String while the native view is being created, which can
/// block for hundreds of milliseconds on a large note. Two tiers keep that optimization from
/// costing correctness:
///
/// * **Under 256 KB** the document is assigned directly. There is no blank window at all.
/// * **At or above 256 KB** the source is appended in attributed chunks so every inserted run
///   carries an explicit font/color/paragraph style. Inserting bare `String`s into
///   `NSTextStorage` leaves runs without a font attribute, which is what made a fully-read
///   document render as an apparently empty editor in dark mode.
///
/// All completion paths funnel through `finishHydration`, so a finished, empty, cancelled or
/// superseded hydration can never leave the view permanently read-only or mid-hydration.
private struct ProgressiveTextEditor: UIViewRepresentable {
    @Binding var text: String
    let documentID: URL
    let colorScheme: ColorScheme

    /// Documents below this size are assigned in one pass instead of streamed.
    static let progressiveThreshold = 256 * 1024
    static let chunkSize = 8_192

    /// UIKit's semantic `.label` is resolved while the text view is still detached from the
    /// window, where its trait collection is not yet dark. The hydrated text then keeps a
    /// concrete black foreground attribute, so the editor looks completely empty in dark mode
    /// even though the document is loaded. Resolve the semantic color against the SwiftUI
    /// color scheme explicitly and re-apply it whenever that scheme changes.
    private var resolvedTextColor: UIColor {
        UIColor.label.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light))
    }

    private static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.2
        return style
    }()

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, textColor: resolvedTextColor)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.autocorrectionType = .yes
        view.autocapitalizationType = .sentences
        view.textContainerInset = UIEdgeInsets(top: AppMetrics.screenTop,
                                              left: AppMetrics.screenHorizontal,
                                              bottom: AppMetrics.sectionSpacing,
                                              right: AppMetrics.screenHorizontal)
        view.textContainer.lineFragmentPadding = 0
        context.coordinator.startHydration(text, in: view, documentID: documentID)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        // A light/dark switch must recolor (and re-font) the already-inserted text storage:
        // the hydrated runs carry concrete attributes captured while the view was off-window.
        if context.coordinator.appliedTextColor != resolvedTextColor {
            context.coordinator.appliedTextColor = resolvedTextColor
            context.coordinator.applyBaseAttributes(to: view)
        }

        // A NavigationSplitView can reuse the same UITextView for a different note. Cancel the
        // old hydration before it can finish by writing the previous document into this view.
        if context.coordinator.documentID != documentID
            || (context.coordinator.isHydrating && context.coordinator.hydratingValue != text) {
            context.coordinator.startHydration(text, in: view, documentID: documentID)
            return
        }

        // The binding already contains the complete source while the text view is being
        // hydrated. Do not replace its progressively-built text with the full source here.
        guard !context.coordinator.isHydrating else { return }
        guard view.text != text else { return }
        let selectedRange = view.selectedRange
        view.text = text
        view.selectedRange = NSRange(
            location: min(selectedRange.location, (text as NSString).length),
            length: 0)
        context.coordinator.applyBaseAttributes(to: view)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let text: Binding<String>
        weak var textView: UITextView?
        private var hydrationTask: Task<Void, Never>?
        private(set) var documentID: URL?
        private(set) var hydratingValue = ""
        private var hydrationGeneration: UInt64 = 0
        private(set) var isHydrating = false
        /// The concrete color currently applied to the text storage, so a color-scheme change
        /// is applied exactly once instead of on every SwiftUI update.
        var appliedTextColor: UIColor?

        init(text: Binding<String>, textColor: UIColor) {
            self.text = text
            self.appliedTextColor = textColor
        }

        deinit {
            hydrationTask?.cancel()
        }

        private var baseAttributes: [NSAttributedString.Key: Any] {
            [
                .font: UIFont.monospacedSystemFont(ofSize: 17, weight: .regular),
                .foregroundColor: appliedTextColor ?? .label,
                .paragraphStyle: ProgressiveTextEditor.paragraphStyle,
            ]
        }

        /// Force the whole document (and subsequent typing) to the resolved attributes. Plain
        /// `String` inserts into `NSTextStorage` inherit a concrete default font/color, which
        /// would otherwise stay black-on-black in dark mode — or render with no font at all.
        func applyBaseAttributes(to view: UITextView) {
            let attributes = baseAttributes
            view.font = attributes[.font] as? UIFont
            view.textColor = attributes[.foregroundColor] as? UIColor
            view.typingAttributes = attributes
            let length = view.textStorage.length
            guard length > 0 else { return }
            view.textStorage.beginEditing()
            view.textStorage.setAttributes(attributes, range: NSRange(location: 0, length: length))
            view.textStorage.endEditing()
        }

        func startHydration(_ value: String, in view: UITextView, documentID: URL) {
            hydrationTask?.cancel()
            hydrationGeneration &+= 1
            let generation = hydrationGeneration
            self.documentID = documentID
            hydratingValue = value
            textView = view
            isHydrating = true
            view.isEditable = false

            // Small documents take the direct path: one assignment, no visible blank window.
            if value.utf8.count < ProgressiveTextEditor.progressiveThreshold {
                view.text = value
                finishHydration(in: view, generation: generation, documentID: documentID)
                return
            }

            view.text = ""
            hydrationTask = Task { @MainActor [weak self, weak view] in
                guard let self, let view else { return }
                var index = value.startIndex
                let chunkSize = ProgressiveTextEditor.chunkSize

                while index < value.endIndex {
                    guard !Task.isCancelled, self.isCurrent(generation, documentID) else { return }
                    let end = value.index(index, offsetBy: chunkSize, limitedBy: value.endIndex)
                        ?? value.endIndex
                    let chunk = String(value[index..<end])
                    let attributedChunk = NSAttributedString(string: chunk,
                                                             attributes: self.baseAttributes)
                    let storage = view.textStorage
                    storage.beginEditing()
                    storage.append(attributedChunk)
                    storage.endEditing()
                    index = end

                    // Let UIKit draw between chunks. This keeps a large note responsive while
                    // the remaining source is added, instead of producing one long frame hitch.
                    if index < value.endIndex {
                        try? await Task.sleep(nanoseconds: 2_000_000)
                    }
                }

                guard !Task.isCancelled else { return }
                self.finishHydration(in: view, generation: generation, documentID: documentID)
            }
        }

        private func isCurrent(_ generation: UInt64, _ documentID: URL) -> Bool {
            hydrationGeneration == generation && self.documentID == documentID
        }

        /// The single exit point for a hydration pass. A superseded pass returns early instead,
        /// because the newer pass owns the view's editability from that point on.
        private func finishHydration(in view: UITextView, generation: UInt64, documentID: URL) {
            guard isCurrent(generation, documentID) else { return }
            isHydrating = false
            view.isEditable = true
            applyBaseAttributes(to: view)
            view.setNeedsLayout()
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isHydrating else { return }
            text.wrappedValue = textView.text
        }
    }
}
#endif
