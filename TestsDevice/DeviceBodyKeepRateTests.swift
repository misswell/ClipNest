import Foundation
import XCTest
@testable import ClipNest

/// How often does the model's rewritten body actually survive?
///
/// This decides whether asking for a body at all is worth its cost. On the iPhone the decode
/// phase is ~80% of the wait, and the body is most of the decoded tokens — so if the
/// fact-preservation guard rejects that body nearly every time, those seconds buy nothing and
/// the prompt should stop asking for it.
///
/// Run with the `ClipNestDevice` scheme.
@MainActor
final class DeviceBodyKeepRateTests: XCTestCase {
    private let store = LocalModelStore()

    private static let samples: [String] = [
        """
        # Vision OCR 图片文字识别

        在 SwiftUI 里使用 VNRecognizeTextRequest 对图片做本地文字识别。
        recognitionLevel 设置为 accurate，并打开 usesLanguageCorrection。
        中文需要把 recognitionLanguages 设置为 zh-Hans。
        实测在 iPhone 15 Pro 上，一张 A4 文档大约 0.4 秒完成识别，全程不联网。
        """,
        """
        # 数据库索引优化笔记

        MySQL 的联合索引遵循最左前缀原则，where 条件里跳过了第一列就用不上索引。
        用 EXPLAIN 看 type 列，range 比 index 好，ALL 说明全表扫描。
        覆盖索引可以避免回表，把要查的列都放进索引里。实测查询从 1.2 秒降到 0.03 秒。
        """,
        """
        # 本周复盘

        周一和周三各开了一次需求评审会，把 V2 的范围砍掉了一半。
        剩下三件事：修登录超时、补埋点、写上线方案。周五之前完成。
        另外记一下，团队现在 6 个人，下个月会来 2 个实习生。
        """
    ]

    private var profiles: [CategoryProfile] {
        [CategoryProfile(name: "iOS开发", keywords: ["SwiftUI", "Vision", "Xcode"]),
         CategoryProfile(name: "数据库", keywords: ["MySQL", "索引", "SQL"]),
         CategoryProfile(name: "工作", keywords: ["会议", "需求", "复盘"])]
    }

    func testHowOftenTheModelBodySurvivesTheFactGuard() async throws {
        try XCTSkipUnless(LocalModelRuntime.isRuntimeLinked && store.isInstalled())

        let engine = try await MLXQwenEngine.load(modelDirectory: store.modelDirectory)
        let provider = QwenLocalProvider(engine: engine, profiles: profiles)

        var kept = 0
        var total = 0
        var rejectedSamples = 0
        var lines: [String] = []

        for (index, text) in Self.samples.enumerated() {
            let content = try XCTUnwrap(ClipboardContent(text: text))
            for run in 1...2 {
                let note = try await provider.generate(from: content,
                                                       existingCategories: profiles.map(\.name),
                                                       preferredLanguage: .simplifiedChinese)
                let source = MarkdownContentCleaner.clean(text)
                total += 1
                // The provider returns the source verbatim when the guard fires.
                let didKeep = note.content != source
                if didKeep { kept += 1 } else { rejectedSamples += 1 }
                lines.append("sample \(index + 1).\(run): "
                             + (didKeep ? "model body KEPT" : "guard fired → source used"))
            }
        }

        print("""
        ===== ON-DEVICE BODY KEEP RATE =====
        \(lines.joined(separator: "\n"))
        kept \(kept)/\(total) model bodies; \(rejectedSamples) fell back to the source
        =====================================
        """)
        XCTAssertGreaterThan(total, 0)
    }
}
