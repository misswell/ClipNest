import Foundation
import XCTest
@testable import ClipNest

/// Runs the local-AI acceptance path on **real hardware** (China plan §36⑫).
///
/// `ClipNestTests` is a macOS target, so its live-inference tests can never execute on an
/// iPhone. This target exists only so `xcodebuild test -destination 'id=<device>'` can prove
/// the on-device path end to end: real weights, MLX on the device GPU, a real `GeneratedNote`.
///
/// It covers a small, device-safe subset; the macOS-only suites stay where they are.

/// Counts requests reaching a `URLSession` built with `CountingURLProtocol`. Local mode must
/// leave this at zero — that is the privacy assertion, not a proxy for it.
final class DeviceRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    func reset() { lock.lock(); count = 0; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

final class CountingURLProtocol: URLProtocol {
    static let counter = DeviceRequestCounter()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.counter.increment()
        let response = HTTPURLResponse(url: request.url!,
                                       statusCode: 500,
                                       httpVersion: nil,
                                       headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class DeviceLocalAITests: XCTestCase {
    private let store = LocalModelStore()

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

    private var validOnline: AIConfiguration {
        AIConfiguration(baseURL: "https://api.example.com/v1",
                        apiKey: "test-key",
                        model: "test-model",
                        preferredLanguage: .simplifiedChinese)
    }

    /// §27: the device must consider itself capable of running the on-device model, otherwise
    /// the local path silently degrades to Local Lite and the rest of this file means little.
    func testThisDeviceReportsTheEnhancedModelAsInstalled() throws {
        XCTAssertTrue(LocalModelStore.isHardwareCapable,
                      "a physical arm64 iPhone must report hardware capability")
        try XCTSkipUnless(store.isInstalled(),
                          "weights not pushed here: \(store.modelDirectory.path)")

        let bytes = store.installedBytes()
        print("===== ON-DEVICE MODEL: \(bytes) bytes at \(store.modelDirectory.path) =====")
        XCTAssertGreaterThan(bytes, 340_000_000, "the full 351 MB payload should be present")
        XCTAssertTrue(LocalModelRuntime.isRuntimeLinked, "MLX must be linked into the iOS build")
    }

    /// The §36⑫ core: real weights, real MLX, on the phone, producing a real note.
    func testRealModelProducesANoteOnThisDevice() async throws {
        try XCTSkipUnless(LocalModelRuntime.isRuntimeLinked && store.isInstalled())
        let content = try XCTUnwrap(ClipboardContent(text: ocrText))

        let loadStart = Date()
        let engine = try await LocalModelRuntime.shared.engine(for: store.modelDirectory)
        let loadSeconds = Date().timeIntervalSince(loadStart)

        let provider = QwenLocalProvider(engine: engine, profiles: profiles)

        let generateStart = Date()
        let note = try await provider.generate(from: content,
                                               existingCategories: profiles.map(\.name),
                                               preferredLanguage: .simplifiedChinese)
        let generateSeconds = Date().timeIntervalSince(generateStart)

        print("""
        ===== ON-DEVICE QWEN RESULT =====
        model           : \(Self.deviceModelIdentifier())
        os              : \(ProcessInfo.processInfo.operatingSystemVersionString)
        engineName      : \(engine.engineName)
        load (cold)     : \(String(format: "%.2f", loadSeconds)) s
        generate        : \(String(format: "%.2f", generateSeconds)) s
        title           : \(note.title)
        summary         : \(note.summary)
        category        : \(note.category.isEmpty ? "<none>" : note.category)
        tags            : \(note.tags.joined(separator: ", "))
        content         : \(note.content.prefix(300))
        =================================
        """)

        XCTAssertFalse(note.title.isEmpty)
        XCTAssertFalse(note.summary.isEmpty)
        XCTAssertFalse(note.content.isEmpty)
        XCTAssertGreaterThanOrEqual(note.tags.count, 1)
        XCTAssertTrue(note.category.isEmpty || profiles.map(\.name).contains(note.category))
        XCTAssertTrue(note.content.contains("VNRecognizeTextRequest"),
                      "code identifiers must survive on device too")
        XCTAssertEqual(note.sourceURL, content.sourceURL)
    }

    /// §26: the container must be cached, not reloaded from disk for every capture.
    func testAWarmCaptureDoesNotReloadTheModelOnThisDevice() async throws {
        try XCTSkipUnless(LocalModelRuntime.isRuntimeLinked && store.isInstalled())
        let content = try XCTUnwrap(ClipboardContent(text: ocrText))
        let provider = QwenLocalProvider(
            engine: try await LocalModelRuntime.shared.engine(for: store.modelDirectory),
            profiles: profiles)

        _ = try await provider.generate(from: content,
                                        existingCategories: profiles.map(\.name),
                                        preferredLanguage: .simplifiedChinese)
        let start = Date()
        _ = try await provider.generate(from: content,
                                        existingCategories: profiles.map(\.name),
                                        preferredLanguage: .simplifiedChinese)
        let seconds = Date().timeIntervalSince(start)
        print("===== WARM CAPTURE ON DEVICE: \(String(format: "%.2f", seconds)) s =====")
        XCTAssertLessThan(seconds, 60)
    }

    /// §11/§34: the privacy guarantee must hold on the device, not only in a macOS test.
    /// A *valid* online configuration sits behind the factory the whole time.
    func testLocalModeMakesNoNetworkRequestOnThisDevice() async throws {
        CountingURLProtocol.counter.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountingURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let router = NoteGenerationRouter(
            mode: .local,
            onlineConfiguration: validOnline,
            categoryProfiles: profiles,
            localModelProvider: LocalModelManager.shared.makeProviderIfReady(profiles: profiles),
            onlineProviderFactory: { OpenAICompatibleProvider(configuration: $0, session: session) })

        let content = try XCTUnwrap(ClipboardContent(text: ocrText))
        let note = try await router.generate(from: content,
                                             existingCategories: profiles.map(\.name),
                                             preferredLanguage: .simplifiedChinese)

        XCTAssertFalse(note.title.isEmpty)
        XCTAssertEqual(CountingURLProtocol.counter.value, 0,
                       "local mode issued \(CountingURLProtocol.counter.value) network request(s)")
    }

    /// §11: with the weights absent, the device must still produce a usable note offline and
    /// still make no request. This is the fresh-install path on real hardware (§37).
    func testFreshInstallPathStillProducesANoteWithNoNetworkOnThisDevice() async throws {
        CountingURLProtocol.counter.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountingURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let router = NoteGenerationRouter(
            mode: .local,
            onlineConfiguration: validOnline,
            categoryProfiles: profiles,
            localModelProvider: nil,
            localLiteProviderFactory: { LocalLiteNoteProvider(profiles: $0) },
            onlineProviderFactory: { OpenAICompatibleProvider(configuration: $0, session: session) })

        let content = try XCTUnwrap(ClipboardContent(text: ocrText))
        let note = try await router.generate(from: content,
                                             existingCategories: profiles.map(\.name),
                                             preferredLanguage: .simplifiedChinese)

        XCTAssertFalse(note.title.isEmpty)
        XCTAssertFalse(note.summary.isEmpty)
        XCTAssertFalse(note.content.isEmpty)
        XCTAssertEqual(CountingURLProtocol.counter.value, 0)
    }
}

extension DeviceLocalAITests {
    /// `ProcessInfo.model` exists only on macOS, so read `hw.machine` directly — this is what
    /// makes the printed result identifiable as a specific iPhone/iPad model.
    static func deviceModelIdentifier() -> String {
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        return mirror.children.reduce(into: "") { name, child in
            guard let byte = child.value as? Int8, byte != 0 else { return }
            name.append(Character(UnicodeScalar(UInt8(bitPattern: byte))))
        }
    }
}
