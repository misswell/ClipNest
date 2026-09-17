import Foundation
import XCTest
@testable import ClipNest

/// Where the on-device time actually goes, measured on real hardware.
///
/// Written because "can it be faster?" is unanswerable without knowing whether the seconds
/// are in Vision OCR, in the model's prompt prefill, or in token decode. Those three scale
/// with completely different things.
///
/// Run with the `ClipNestDevice` scheme (see `Scripts/deploy-ios.sh`).
@MainActor
final class DevicePerformanceTests: XCTestCase {
    private let store = LocalModelStore()

    /// A capture long enough to be realistic but not pathological.
    private let ocrText = """
    # Vision OCR 图片文字识别

    在 SwiftUI 里使用 VNRecognizeTextRequest 对图片做本地文字识别。
    recognitionLevel 设置为 accurate，并打开 usesLanguageCorrection。
    中文需要把 recognitionLanguages 设置为 zh-Hans。
    实测在 iPhone 15 Pro 上，一张 A4 文档大约 0.4 秒完成识别，全程不联网。
    """

    private var profiles: [CategoryProfile] {
        [CategoryProfile(name: "iOS开发", keywords: ["SwiftUI", "Vision", "Xcode"]),
         CategoryProfile(name: "数据库", keywords: ["MySQL", "索引", "SQL"]),
         CategoryProfile(name: "生活", keywords: ["旅行", "饮食"])]
    }

    private func requireModel() throws {
        try XCTSkipUnless(LocalModelRuntime.isRuntimeLinked && store.isInstalled())
    }

    /// §26, objective ①: preheating must take the load off the capture's critical path.
    ///
    /// The assertion is deliberately **structural, not a timing comparison**. Measured on this
    /// device: preload 1.14 s, cold capture 3.61 s, preheated capture 3.69 s — a *negative*
    /// saving, because generation time itself varies by more than a second between runs (thermal
    /// state, scheduling). An end-to-end `warm < cold` assertion is therefore flaky by
    /// construction and would be measuring noise, not the preload. What can be pinned down is the
    /// thing that actually matters: preloading performs a real load (1.1–1.7 s, matching the cold
    /// load it replaces) and leaves the engine resident, so the capture that follows finds it
    /// already in memory and pays only generation.
    func testPreheatingRemovesTheLoadFromTheCaptureOnThisDevice() async throws {
        try requireModel()
        let runtime = LocalModelRuntime.shared
        let directory = store.modelDirectory

        // 1. What the capture pays today when nothing is warm.
        await runtime.unload()
        let loadedBefore = await runtime.isLoaded
        XCTAssertFalse(loadedBefore, "this measurement needs a dropped model")
        let coldStart = Date()
        _ = try await runtime.engine(for: directory)
        let coldLoadSeconds = Date().timeIntervalSince(coldStart)

        // 2. The same load, moved off the critical path.
        await runtime.unload()
        let preloadStart = Date()
        let warmed = await runtime.preload(directory: directory)
        let preloadSeconds = Date().timeIntervalSince(preloadStart)

        XCTAssertTrue(warmed, "preloading the installed model should succeed")
        let loadedAfterPreload = await runtime.isLoaded
        XCTAssertTrue(loadedAfterPreload,
                      "after a preload the capture must not have to load anything")

        // The capture's own view of the world: it asks for the engine and gets it with no work.
        let captureStart = Date()
        _ = try await runtime.engine(for: directory)
        let engineLookupSeconds = Date().timeIntervalSince(captureStart)

        print("""

        ===== PREHEAT EFFECT (objective ①) =====
        device            : \(Self.deviceModelIdentifier())
        cold load         : \(String(format: "%.2f", coldLoadSeconds)) s  (what a capture pays today)
        preload           : \(String(format: "%.2f", preloadSeconds)) s  (same load, done early)
        engine lookup after preload: \(String(format: "%.3f", engineLookupSeconds)) s
        model resident after preload: \(loadedAfterPreload)
        ========================================
        """)

        // Both routes must do a real load; neither may be a no-op.
        XCTAssertGreaterThan(coldLoadSeconds, 0.1,
                             "a cold load should cost real time, otherwise this device is not a valid sample")
        XCTAssertGreaterThan(preloadSeconds, 0.1,
                             "the preload must be doing the actual work, not skipping it")
        // And the capture's lookup must be cache-hit cheap rather than another load.
        XCTAssertLessThan(engineLookupSeconds, max(preloadSeconds / 2, 0.05),
                          "a preheated capture must not pay the load again")
    }

    /// OCR is the other half of "识别". Measured so the model's share is not guessed at.
    func testVisionOCRTimeOnThisDevice() async throws {
        let image = try XCTUnwrap(Self.renderedTextImage(ocrText))
        let service = VisionOCRService()

        // One warm-up: the first Vision call pays framework initialisation.
        _ = try? await recognize(service, image)

        var samples: [Double] = []
        for _ in 0..<3 {
            let start = Date()
            let result = try await recognize(service, image)
            samples.append(Date().timeIntervalSince(start))
            XCTAssertFalse(result.text.isEmpty, "the rendered image must contain readable text")
        }
        print("""
        ===== ON-DEVICE OCR =====
        samples : \(samples.map { String(format: "%.3f", $0) }.joined(separator: ", ")) s
        chars   : \(ocrText.count)
        =========================
        """)
        XCTAssertLessThan(samples.min() ?? .infinity, 2.0)
    }

    /// The decisive measurement: what the two body styles actually cost on this hardware.
    ///
    /// The fast path was adopted because the model's body survived the fact guard 1 time in 6,
    /// which made its decode time pure waste. This measures whether removing it delivers the
    /// saving that reasoning predicts.
    func testBodyStyleCostOnThisDevice() async throws {
        try requireModel()
        let content = try XCTUnwrap(ClipboardContent(text: ocrText))

        let loadStart = Date()
        let engine = try await MLXQwenEngine.load(modelDirectory: store.modelDirectory)
        let loadSeconds = Date().timeIntervalSince(loadStart)

        var report: [String] = []
        for style in LocalBodyStyle.allCases {
            let builder = LocalPromptBuilder(bodyStyle: style)
            let prompt = builder.prompt(for: content,
                                        existingCategories: profiles.map(\.name),
                                        preferredLanguage: .simplifiedChinese)

            // Two runs: the first pays Metal kernel compilation, the second is the steady state
            // a user actually feels.
            var steady: LocalGenerationMetrics?
            for run in 1...2 {
                let (_, metrics) = try await engine.generateWithMetrics(
                    prompt: prompt, maximumTokens: builder.maximumTokens)
                if run == 2 { steady = metrics }
            }

            let provider = QwenLocalProvider(engine: engine,
                                             profiles: profiles,
                                             promptBuilder: builder)
            let endToEndStart = Date()
            let note = try await provider.generate(from: content,
                                                   existingCategories: profiles.map(\.name),
                                                   preferredLanguage: .simplifiedChinese)
            let endToEnd = Date().timeIntervalSince(endToEndStart)

            report.append("""
            [\(style.rawValue)]
              \(steady?.summary ?? "<no metrics>")
              end-to-end: \(String(format: "%.2f", endToEnd)) s
              prompt chars \(prompt.count) · title "\(note.title)" · tags \(note.tags.joined(separator: ", "))
              body from: \(note.content == MarkdownContentCleaner.clean(ocrText) ? "source" : "model")
            """)
        }

        print("""
        ===== ON-DEVICE BODY STYLE COST =====
        device     : \(Self.deviceModelIdentifier())
        model load : \(String(format: "%.2f", loadSeconds)) s
        \(report.joined(separator: "\n"))
        =====================================
        """)
    }

    /// Proves the streaming path really produces intermediate frames on the device, which is
    /// what the progress banner depends on. A single callback would mean the UI still shows one
    /// static state.
    func testStreamingProgressArrivesDuringRealGenerationOnThisDevice() async throws {
        try requireModel()
        let content = try XCTUnwrap(ClipboardContent(text: ocrText))

        let log = DeviceProgressLog()
        let provider = QwenLocalProvider(engine: try await MLXQwenEngine.load(
            modelDirectory: store.modelDirectory), profiles: profiles)

        let start = Date()
        _ = try await provider.generate(from: content,
                                        existingCategories: profiles.map(\.name),
                                        preferredLanguage: .simplifiedChinese,
                                        onProgress: { log.append($0) })
        let elapsed = Date().timeIntervalSince(start)

        let all = log.all
        let withPreview = all.filter { $0.preview != nil }
        let firstTitleAt = withPreview.first { $0.preview?.title?.isEmpty == false }
        let titleCharacters = withPreview.compactMap { $0.preview?.title?.count }.max() ?? 0

        print("""
        ===== ON-DEVICE STREAMING =====
        elapsed            : \(String(format: "%.2f", elapsed)) s
        progress callbacks : \(all.count)
        with a preview     : \(withPreview.count)
        first titled frame : \(firstTitleAt == nil ? "none" : "yes")
        longest title seen : \(titleCharacters) chars
        phases             : \(all.map { String(describing: $0).prefix(24) }.joined(separator: " → "))
        ===============================
        """)

        // The exact frame count is the library's business; what the banner needs is at least
        // one update from the model itself (not just the finishing phase) and a title that
        // becomes visible before the answer is complete.
        XCTAssertGreaterThanOrEqual(withPreview.count, 2,
                                    "the model must report more than a single frame")
        XCTAssertNotNil(firstTitleAt, "the title must become visible while generating")
    }

    private func recognize(_ service: VisionOCRService,
                                _ image: PlatformImage) async throws -> OCRResult {
        let cgImage = try XCTUnwrap(image.ocrCGImage)
        return try await service.recognizeText(cgImage: cgImage,
                                               languages: VisionOCRService.defaultLanguages)
    }

    /// Renders text into an image so OCR has something real to read.
    private static func renderedTextImage(_ text: String) -> PlatformImage? {
        let size = CGSize(width: 1000, height: 460)
        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 26),
                .foregroundColor: UIColor.black
            ]
            (text as NSString).draw(in: CGRect(x: 24, y: 24, width: size.width - 48,
                                               height: size.height - 48),
                                    withAttributes: attributes)
        }
        #else
        return nil
        #endif
    }

    private static func deviceModelIdentifier() -> String {
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        return mirror.children.reduce(into: "") { name, child in
            guard let byte = child.value as? Int8, byte != 0 else { return }
            name.append(Character(UnicodeScalar(UInt8(bitPattern: byte))))
        }
    }
}

/// Thread-safe collector for the progress callbacks, which arrive off the main actor.
final class DeviceProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [NoteGenerationProgress] = []
    func append(_ progress: NoteGenerationProgress) {
        lock.lock(); entries.append(progress); lock.unlock()
    }
    var all: [NoteGenerationProgress] { lock.lock(); defer { lock.unlock() }; return entries }
}
