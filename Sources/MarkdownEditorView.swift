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
    var title: String {
        switch self {
        case .edit: return String(localized: "Edit")
        case .split: return String(localized: "Split")
        case .preview: return String(localized: "Preview")
        }
    }

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
    /// Carried so a note that just arrived from a capture can be told apart from one the user
    /// opened — the folder pill lights up only for the former.
    @EnvironmentObject private var selection: VaultSelection
    let url: URL
    /// The mode this document starts in. Reset for every newly opened note — never persisted.
    var intent: NoteOpenIntent = .view
    var initialHeading: String? = nil

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
    @State private var renameTarget: RenameItemTarget?
    @State private var moveTarget: MoveDocumentTarget?
    @State private var relocatedURL: URL?
    @State private var showInspector = false
    @State private var showPresentation = false
    @State private var showFolderHint = false
    @State private var linkedURL: URL?
    @State private var linkedHeading: String?
    @State private var scrollHeading: String?
    @State private var missingLink: String?
    @State private var showMissingLink = false
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.colorScheme) private var colorScheme

    private var isWide: Bool { hSize != .compact }

    private var normalizedURL: URL { (relocatedURL ?? url).standardizedFileURL }

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
        .navigationTitle(normalizedURL.deletingPathExtension().lastPathComponent)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if isDocumentReady {
                toolbarContent
            }
        }
        // The folder pill belongs on the page rather than only inside the "…" menu: a capture
        // files the note wherever the classifier guessed, and the moment to correct that is the
        // one the user is already looking at.
        .safeAreaInset(edge: .top, spacing: 0) {
            if isDocumentReady { folderChipRow }
        }
        .alert("Delete Note", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                deleteCurrentNote()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This note will be removed from the vault.")
        }
        .sheet(item: $renameTarget) { target in
            RenameItemView(fileURL: target.url)
        }
        .sheet(item: $moveTarget) { target in
            MoveDocumentView(fileURL: target.url)
        }
        .sheet(isPresented: $showInspector) {
            NoteInspectorView(url: normalizedURL, text: $text, onOpen: openNote,
                              onHeading: { mode = .preview; scrollHeading = $0 })
        }
        .navigationDestination(item: $linkedURL) { VaultDocumentDestination(url: $0, initialHeading: linkedHeading) }
        .sheet(isPresented: $showPresentation) { NotePresentationView(text: text, url: normalizedURL) }
        .alert("Create Linked Note?", isPresented: $showMissingLink) {
            Button("Create") {
                if let missingLink, let target = store.openOrCreateNote(path: MarkdownKnowledge.splitTarget(missingLink).path) { openNote(target) }
            }
            Button("Cancel", role: .cancel) { missingLink = nil }
        } message: { Text(missingLink ?? "") }
        .onChange(of: store.lastLinkMutation) { _, mutation in
            guard let mutation, let current = loadedURL else { return }
            saveTask?.cancel()
            if mutation.isMerge && current == mutation.source {
                hasLoadedText = false; loadedURL = nil; loadState = .idle
                return
            }
            text = mutation.rewrite(text, at: current)
            loadedTextSnapshot = mutation.rewrite(loadedTextSnapshot, at: current)
            let destination = VaultDocumentMove(source: mutation.source, destination: mutation.destination).relocated(current)
            if destination != current { relocatedURL = destination; loadedURL = destination; intentURL = destination }
            if text != loadedTextSnapshot { store.save(text, to: destination) }
        }
        .onChange(of: store.lastDocumentMove) { _, move in
            guard let move else { return }
            let previous = loadedURL ?? normalizedURL
            let destination = move.relocated(previous)
            guard destination != previous else { return }
            // Keep the loaded buffer: a reload could race a pending autosave.
            saveTask?.cancel()
            relocatedURL = destination
            loadedURL = destination
            intentURL = destination
            if text != loadedTextSnapshot { store.save(text, to: destination) }
        }
        .onChange(of: url) { _, _ in relocatedURL = nil }
        .task(id: selection.documentSource) {
            guard selection.documentSource == .quickPaste else {
                showFolderHint = false
                return
            }
            withAnimation { showFolderHint = true }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { showFolderHint = false }
        }
        .task(id: LoadKey(url: normalizedURL, attempt: reloadAttempt)) {
            if isDocumentReady { return }
            await loadDocument()
            if let initialHeading { scrollHeading = initialHeading }
        }
        .onDisappear { flushSave() }
    }

    // MARK: - Loading

    private func loadDocument() async {
        // Detached iCloud reads can finish after a newer document has already loaded. Give
        // this request a generation before the first suspension so stale results can never
        // overwrite the current editor state.
        // A cancelled `.task` still runs its body, so it must never be allowed to claim the load.
        guard let loadRequest = loadRequestGate.begin(for: normalizedURL, isCancelled: Task.isCancelled) else {
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
                guard hasLoadedText else { return }
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
            vaultRootURL: store.rootURL,
            onToggleCheckbox: toggleCheckbox,
            onOpenNote: followLink, scrollHeading: scrollHeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Folder of the open note, as the move control itself. A path the user can only read is a
    /// path they cannot fix, so this row is the pill rather than the subtitle it replaced.
    private var folderChipRow: some View {
        HStack(spacing: 0) {
            NoteFolderChip(fileURL: normalizedURL, emphasised: showFolderHint)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppMetrics.screenHorizontal)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(Theme.background)
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
                        label: candidate.title
                    ) {
                        mode = candidate
                    }
                }
            }

            Group {
                // A toolbar Menu pops down anchored to this button, so the destructive entry
                // stays visually connected to the ellipsis (a confirmationDialog would slide
                // up from the bottom edge, disconnected from the control that opened it).
                Menu {
                    Button("Start Presentation") { showPresentation = true }
                    Button("Command Palette") { store.showCommandPalette = true }
                    Menu("Insert") {
                        Button("Internal Link") { insert(snippet: "[[Note]]") }
                        Button("Todo / Checklist") { insert(snippet: "- [ ] ") }
                        Button("Table") { insert(snippet: "| Column A | Column B |\n| --- | --- |\n| | |\n") }
                        Button("Callout") { insert(snippet: "> [!note]\n> ") }
                        Button("Code Block") { insert(snippet: "```\n\n```\n") }
                    }
                    Button { flushSave(); showInspector = true } label: {
                        Label("Note Details", systemImage: "list.bullet.rectangle")
                    }
                    Button { renameTarget = RenameItemTarget(url: normalizedURL) } label: {
                        Label("Rename Note", systemImage: "pencil")
                    }
                    Button { moveTarget = MoveDocumentTarget(url: normalizedURL) } label: {
                        Label("Move to Folder…", systemImage: "folder")
                    }
                    Divider()
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
        return AppToolbarIconButton(systemImage: target.systemImage, label: target.title) {
            mode = target
        }
    }

    // MARK: - Actions

    private func openNote(_ target: URL) {
        flushSave()
        #if os(macOS)
        store.selectedFileURL = target
        #else
        linkedURL = target
        #endif
    }

    private func followLink(_ target: String) {
        Task {
            if let resolved = await store.resolveNote(target, from: normalizedURL) {
                if resolved == normalizedURL { mode = .preview; scrollHeading = MarkdownKnowledge.splitTarget(target).fragment }
                else { linkedHeading = MarkdownKnowledge.splitTarget(target).fragment; openNote(resolved) }
            } else { missingLink = target; showMissingLink = true }
        }
    }

    private func toggleCheckbox(_ index: Int) {
        guard isDocumentReady, let updated = MarkdownParser.togglingCheckbox(at: index, in: text) else { return }
        saveTask?.cancel()
        text = updated
        store.save(updated, to: normalizedURL)
    }

    private func deleteCurrentNote() {
        // A debounced edit must not recreate a note after the user has just deleted it, and the
        // disappearance callback must not flush the editor back to the removed URL.
        saveTask?.cancel()
        guard store.delete(normalizedURL) else { return }
        hasLoadedText = false
        loadedURL = nil
        loadState = .idle
    }

    private func scheduleSave(_ value: String) {
        saveTask?.cancel()
        guard hasLoadedText, let target = loadedURL else { return }
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            store.save(value, to: target)
        }
    }

    private func flushSave() {
        // Never rewrite the document unless the text actually diverged from what was
        // loaded: a failed read must not be able to wipe the file with empty content.
        saveTask?.cancel()
        guard hasLoadedText, let target = loadedURL, text != loadedTextSnapshot else { return }
        store.save(text, to: target)
    }

    // MARK: - Insert helpers (append-based; simple and reliable cross-platform)
    private func insert(snippet: String) {
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += snippet
    }
    private func insert(wrap: String) { insert(snippet: "\(wrap)text\(wrap)") }
    private func insertLinePrefix(_ prefix: String) { insert(snippet: "\(prefix)") }
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
