import XCTest
@testable import ClipNest

final class OutputLanguageTests: XCTestCase {
    func testBothProvidersUseTheSelectedLanguageForEveryGeneratedField() {
        let content = ClipboardContent(text: "识别得到的原始文本")!
        for language in PreferredLanguage.allCases {
            let online = NotePromptBuilder.systemPrompt(existingCategories: ["开发"],
                                                         preferredLanguage: language,
                                                         format: .archive)
            let local = LocalPromptBuilder(format: .archive).prompt(for: content,
                                                                    existingCategories: ["开发"],
                                                                    preferredLanguage: language)
            XCTAssertTrue(online.contains(language.generationInstruction))
            XCTAssertTrue(local.contains(language.generationInstruction))
        }
        XCTAssertTrue(PreferredLanguage.english.generationInstruction.contains("rewritten body"))
        XCTAssertFalse(PreferredLanguage.automatic.generationInstruction.contains("优先使用中文"))
    }

    func testEnglishSectionsPreserveChineseSource() {
        let source = ClipboardContent(text: "这是需要保留的原始内容。")!
        let note = GeneratedNote(title: "Text recognition", summary: "An English summary.",
                                 content: "An English body.", category: "开发", tags: ["OCR"],
                                 sourceURL: nil)
        let markdown = MarkdownNoteBuilder.make(note: note, originalContent: source,
                                                format: .archive, preferredLanguage: .english)
        XCTAssertTrue(markdown.contains("## Summary"))
        XCTAssertTrue(markdown.contains("## Content"))
        XCTAssertTrue(markdown.contains("## Original Content"))
        XCTAssertTrue(markdown.contains(source.rawText))
        XCTAssertFalse(markdown.contains("## 摘要"))
    }

    func testAutomaticSectionsFollowGeneratedProseInsteadOfOriginalSource() {
        let source = ClipboardContent(text: "中文原始内容")!
        let note = GeneratedNote(title: "Recognition", summary: "English summary.",
                                 content: "English body quoting the term 中文.", category: "Inbox", tags: [], sourceURL: nil)
        let english = MarkdownNoteBuilder.make(note: note, originalContent: source, format: .archive)
        XCTAssertTrue(english.contains("## Summary"))
        let chinese = MarkdownNoteBuilder.make(note: note, originalContent: source,
                                               format: .archive, preferredLanguage: .simplifiedChinese)
        XCTAssertTrue(chinese.contains("## 摘要"))
    }

    @MainActor
    func testChangingSettingsWhileDraftIsOpenKeepsItsGenerationLanguageOnSave() async throws {
        let defaults = UserDefaults.standard
        let keys = [ClipNestSettings.aiPreferredLanguage, ClipNestSettings.noteFormatConfiguration]
        let previous = keys.map { defaults.object(forKey: $0) }
        let suiteName = "OutputLanguageTests-\(UUID().uuidString)"
        let captureDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        captureDefaults.set(ClipboardProcessingMode.confirmBeforeSave.rawValue,
                            forKey: ClipNestSettings.processingMode)
        defaults.set(PreferredLanguage.english.rawValue, forKey: ClipNestSettings.aiPreferredLanguage)
        NoteFormatConfigurationStore.save(.archive)
        defer {
            for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) }
            captureDefaults.removePersistentDomain(forName: suiteName)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = VaultStore()
        defer {
            store.closeVault()
            try? FileManager.default.removeItem(at: root)
        }
        store.openVault(at: root)
        let coordinator = CaptureCoordinator(store: store, clipboardService: ClipboardService(),
                                             noteGenerator: LanguageCheckingGenerator(),
                                             defaults: captureDefaults)
        await coordinator.captureText("保留这段识别得到的原始内容。")
        let draft = try XCTUnwrap(coordinator.pendingDraft)
        defaults.set(PreferredLanguage.simplifiedChinese.rawValue,
                     forKey: ClipNestSettings.aiPreferredLanguage)
        await coordinator.saveDraft(draft)
        let savedURL = try XCTUnwrap(coordinator.lastSavedURL)
        let markdown = try String(contentsOf: savedURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("## Summary"))
        XCTAssertTrue(markdown.contains("## Original Content"))
        XCTAssertTrue(markdown.contains(draft.originalText))
    }

    private struct LanguageCheckingGenerator: NoteGenerating {
        func generate(from content: ClipboardContent, existingCategories: [String],
                      preferredLanguage: PreferredLanguage) async throws -> GeneratedNote {
            XCTAssertEqual(preferredLanguage, .english)
            return GeneratedNote(title: "Recognition", summary: "English summary.",
                                 content: "English body.", category: "Inbox", tags: [], sourceURL: nil)
        }
    }
}
