import XCTest
@testable import ClipNest

/// The unified note format: presets, requirement derivation, instruction budgets, the store
/// round-trip and the legacy `LocalBodyStyle` migration (方案 §5–§8, §24, §26, §34).
final class NoteFormatConfigurationTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "NoteFormatTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Presets (方案 §5)

    func testEveryBuiltInPresetCarriesADistinctConfiguration() {
        let configurations = [NoteFormatPreset.standard,
                              .clean,
                              .original,
                              .archive]
            .compactMap(\.configuration)
        for (index, outer) in configurations.enumerated() {
            for inner in configurations[(index + 1)...] {
                XCTAssertNotEqual(outer, inner, "the presets must be meaningfully different")
            }
        }
        XCTAssertEqual(configurations.map(\.preset),
                       [.standard, .clean, .original, .archive])
    }

    func testCleanIsTitleAndBodyOnly() {
        let clean = NoteFormatConfiguration.clean
        XCTAssertTrue(clean.includeTitle)
        XCTAssertTrue(clean.generatesBody)
        XCTAssertFalse(clean.includeSummary)
        XCTAssertFalse(clean.includeOriginalText)
        XCTAssertFalse(clean.includeTags)
        XCTAssertFalse(clean.includeFrontmatter)
    }

    func testTitleAndOriginalAsksTheModelForNoBody() {
        let original = NoteFormatConfiguration.titleAndOriginal
        XCTAssertFalse(original.includeGeneratedBody)
        XCTAssertEqual(original.bodyStyle, .original)
        XCTAssertFalse(original.generationRequirements.body,
                       "the model must not be asked for a body the renderer would discard (方案 §9)")
    }

    func testArchiveKeepsEverything() {
        let archive = NoteFormatConfiguration.archive
        for enabled in [archive.includeTitle, archive.includeSummary, archive.includeGeneratedBody,
                        archive.includeOriginalText, archive.includeOriginalImage, archive.includeTags,
                        archive.includeFrontmatter, archive.includeSourceURL, archive.includeCreatedAt] {
            XCTAssertTrue(enabled)
        }
    }

    // MARK: - Preset resolution (方案 §24)

    func testResolvedPresetMatchesByValue() {
        XCTAssertEqual(NoteFormatConfiguration.standard.resolvedPreset, .standard)
        XCTAssertEqual(NoteFormatConfiguration.clean.resolvedPreset, .clean)
        XCTAssertEqual(NoteFormatConfiguration.titleAndOriginal.resolvedPreset, .original)
        XCTAssertEqual(NoteFormatConfiguration.archive.resolvedPreset, .archive)

        var handTuned = NoteFormatConfiguration.standard
        handTuned.includeSummary = false
        XCTAssertEqual(handTuned.resolvedPreset, .custom,
                       "any hand-tuned combination reads as Custom")
    }

    func testApplyingTheCustomPresetKeepsTheCurrentToggles() {
        var handTuned = NoteFormatConfiguration.clean
        handTuned.includeTags = true
        let kept = handTuned.applyingPreset(.custom)
        XCTAssertEqual(kept, handTuned, "Custom must never destroy the user's combination")
    }

    func testApplyingAPresetKeepsTheCustomInstruction() {
        var configured = NoteFormatConfiguration.standard
        configured.customInstruction = "保持代码原样"
        let archived = configured.applyingPreset(.archive)
        XCTAssertEqual(archived.customInstruction, "保持代码原样")
        XCTAssertEqual(archived.preset, .archive)
    }

    // MARK: - Requirements (方案 §9, §30)

    func testCategoryIsAlwaysRequestedEvenWhenTheNoteShowsNoneOfIt() {
        var configuration = NoteFormatConfiguration.titleAndOriginal
        configuration.includeTags = false
        let requirements = configuration.generationRequirements
        XCTAssertTrue(requirements.category,
                      "classification is internal metadata, independent of the rendered note")
        XCTAssertTrue(requirements.title)
        XCTAssertFalse(requirements.summary)
        XCTAssertFalse(requirements.body)
        XCTAssertFalse(requirements.tags)
    }

    func testOriginalStyleDisablesTheGeneratedBody() {
        var configuration = NoteFormatConfiguration.clean
        configuration.bodyStyle = .original
        XCTAssertFalse(configuration.generatesBody)
        XCTAssertFalse(configuration.generationRequirements.body)
    }

    // MARK: - Instruction budgets (方案 §26)

    func testInstructionBudgetsAreProgramSideNotSecondInputFields() {
        var configuration = NoteFormatConfiguration.standard
        configuration.customInstruction = String(repeating: "字", count: 1500)

        XCTAssertEqual(configuration.onlineInstruction.count, 1500,
                       "the online model reads the full instruction")
        XCTAssertLessThanOrEqual(configuration.localInstruction.count,
                                 NoteFormatConfiguration.maximumLocalInstructionCharacters,
                                 "the 0.6B model only ever sees the compressed prefix")

        configuration.customInstruction = "  保持代码原样  "
        XCTAssertEqual(configuration.trimmedCustomInstruction, "保持代码原样")
    }

    // MARK: - Store round-trip and tolerant decoding (方案 §7)

    func testStoreRoundTripsTheConfiguration() {
        let defaults = makeDefaults()
        var configuration = NoteFormatConfiguration.clean
        configuration.customInstruction = "不要总结"
        NoteFormatConfigurationStore.save(configuration, defaults: defaults)
        XCTAssertEqual(NoteFormatConfigurationStore.load(defaults: defaults), configuration)
    }

    func testStoreFallsBackToTheDefaultForAFreshInstall() {
        let defaults = makeDefaults()
        XCTAssertEqual(NoteFormatConfigurationStore.load(defaults: defaults),
                       .default)
    }

    func testUnknownJSONFieldsDoNotBreakTheLoad() throws {
        let defaults = makeDefaults()
        var configuration = NoteFormatConfiguration.clean
        configuration.customInstruction = "keep code"
        NoteFormatConfigurationStore.save(configuration, defaults: defaults)

        // Simulate an older build having stored this object: a *future* field is present in
        // the blob, and decoding must not lose the rest (方案 §7).
        let data = defaults.data(forKey: ClipNestSettings.noteFormatConfiguration)!
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var migrated = object
        migrated["futureField"] = 42
        defaults.set(try JSONSerialization.data(withJSONObject: migrated),
                     forKey: ClipNestSettings.noteFormatConfiguration)

        let loaded = NoteFormatConfigurationStore.load(defaults: defaults)
        XCTAssertEqual(loaded.preset, .clean)
        XCTAssertEqual(loaded.customInstruction, "keep code")
    }

    // MARK: - Legacy migration (方案 §8, §34)

    func testAFreshInstallIsNotMigrated() {
        let defaults = makeDefaults()
        XCTAssertNil(NoteFormatConfigurationStore.legacyConfiguration(
            defaults: defaults, processingMode: .local))
    }

    func testAnExistingLocalUserKeepsTheSourceVerbatimBody() throws {
        let defaults = makeDefaults()
        defaults.set("abc", forKey: ClipNestSettings.lastClipboardHash)

        let configuration = try XCTUnwrap(NoteFormatConfigurationStore.legacyConfiguration(
            defaults: defaults, processingMode: .local))
        XCTAssertEqual(configuration.bodyStyle, .original)
        XCTAssertFalse(configuration.generationRequirements.body,
                       "a local user's notes did not carry model-written bodies")
        XCTAssertTrue(configuration.includeOriginalText)
        XCTAssertTrue(configuration.includeSummary)
        XCTAssertTrue(configuration.includeTags)
    }

    func testAnExistingOnlineUserKeepsAModelWrittenBody() throws {
        let defaults = makeDefaults()
        defaults.set("abc", forKey: ClipNestSettings.lastAttemptedClipboardHash)

        let configuration = try XCTUnwrap(NoteFormatConfigurationStore.legacyConfiguration(
            defaults: defaults, processingMode: .online))
        XCTAssertEqual(configuration.bodyStyle, .knowledge)
        XCTAssertTrue(configuration.generationRequirements.body,
                      "an online user's notes carried an organized body")
        XCTAssertTrue(configuration.includeOriginalText,
                      "the old builder always appended the quoted source")
    }

    func testLegacyModelRewriteMapsToTheKnowledgeStyle() throws {
        let defaults = makeDefaults()
        defaults.set("modelRewrite", forKey: ClipNestSettings.localBodyStyle)

        let configuration = try XCTUnwrap(NoteFormatConfigurationStore.legacyConfiguration(
            defaults: defaults, processingMode: .local))
        XCTAssertEqual(configuration.bodyStyle, .knowledge)
    }

    func testMigrationRunsOnceAndThenReadsTheStoredObject() throws {
        let defaults = makeDefaults()
        defaults.set("abc", forKey: ClipNestSettings.lastClipboardHash)

        let first = NoteFormatConfigurationStore.load(defaults: defaults)
        XCTAssertNotNil(defaults.data(forKey: ClipNestSettings.noteFormatConfiguration),
                        "the migrated configuration is persisted so migration is one-time")

        // Even if the legacy markers are gone afterwards, the stored object wins.
        defaults.removeObject(forKey: ClipNestSettings.lastClipboardHash)
        let second = NoteFormatConfigurationStore.load(defaults: defaults)
        XCTAssertEqual(first, second)
    }
}
