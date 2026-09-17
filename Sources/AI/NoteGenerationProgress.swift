import Foundation

/// What a capture can show the user while it is still working.
///
/// A local capture is slow enough — seconds, not milliseconds — that a single static
/// "Analyzing…" reads as "stuck". This is the typed channel the UI listens on: it says which
/// phase is running and, once the model starts answering, what it has produced so far.
///
/// It is deliberately engine-agnostic. `CaptureCoordinator` publishes these values without
/// knowing whether they came from MLX, Local Lite, or an online API (§17).
enum NoteGenerationProgress: Equatable, Sendable {
    /// The model is being brought into memory.
    ///
    /// This is a distinct phase because on the first capture it is a real wait (measured at
    /// 1.2–1.7 s on an iPhone 15 Pro) and it is the one phase that is *not* the model thinking.
    case preparingEngine(engineName: String)

    /// The engine is running and `preview` is what can already be read from its answer.
    case generating(preview: NotePreview)

    /// The answer arrived; the note is being classified and written to disk.
    case finishing

    /// The answer so far, when there is one. `nil` while the engine is still being prepared.
    var preview: NotePreview? {
        if case .generating(let preview) = self { return preview }
        return nil
    }
}


/// The part of a note that can be shown before the model has finished.
///
/// Fields appear as they complete: the title lands first, then the summary, then tags. A field
/// that is still streaming is reported as a partial value so the user sees text growing rather
/// than a placeholder.
struct NotePreview: Equatable, Sendable {
    var title: String?
    var summary: String?
    var tags: [String] = []
    /// How many characters of the raw answer have arrived. Drives the activity indicator, so
    /// it moves even while a long field is still being written.
    var charactersGenerated: Int = 0

    var isEmpty: Bool {
        (title?.isEmpty ?? true) && (summary?.isEmpty ?? true) && tags.isEmpty
    }
}
