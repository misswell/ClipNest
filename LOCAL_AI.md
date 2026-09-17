# 本地 AI / OCR / 在线 AI 双模式 — 实现与验证报告

ClipNest 在中国区如何生成笔记、识别图片、搜索仓库，以及每一项设计背后的实测依据。

## 0. 一句话结论

全新安装时**不下载任何模型、不需要任何 API Key**：拍照 → Apple Vision OCR → 本地规则引擎
（Local Lite）生成标题/摘要/标签/分类 → 存成 Markdown → SQLite FTS5 本地搜索，全程
**0 次网络请求**。想要更强的改写能力时，用户可以自行下载 **351 MB** 的 Qwen3-0.6B-4bit
模型，之后整条链路依然 **0 次网络请求**。全程不依赖 Apple Intelligence / Foundation Models。

---

## 1. 两种模式（§8、§16）

只有两种，没有第三种：

| 模式 | 含义 | 默认 |
| --- | --- | --- |
| `local` 本地处理 | 全部在设备上完成，**永不联网** | ✅ |
| `online` 联网处理 | 使用用户配置的 OpenAI 兼容服务 | |

旧的 `automatic` 模式已删除。升级安装里残留的 `"automatic"` 会被
`AIConfigurationStore.loadProcessingMode()` 解析为 **`local`**：把「自动」解读成「联网」
等于在用户没要求的情况下开始上传内容，而解读成「本地」最坏也只是少一点改写质量。
`AIProcessingModeTests` 钉住了这个行为。

### 各能力由谁承担

| 能力 | 实现 | 联网 | 体积 |
| --- | --- | --- | --- |
| 拍照取字 | `VisionOCRService`（`VNRecognizeTextRequest`，`.accurate`，语言纠正） | 否 | 0 |
| 标题 / 摘要 / 正文 / 标签 / 分类 | `LocalLiteNoteProvider` + `LocalTextAnalyzer` / `LocalSummarizer` / `LocalTagExtractor` / `LocalSemanticClassifier` | 否 | 0 |
| 增强改写（可选） | `QwenLocalProvider` → `MLXQwenEngine` → `mlx-community/Qwen3-0.6B-4bit` | 否 | 351 MB（按需下载） |
| 全文搜索 | SQLite **FTS5** + `bm25()`，中文预切分为 bi-gram | 否 | 0 |
| 搜索查询扩展（可选） | `LocalQueryExpander` → 同一个 Qwen 模型 | 否 | 复用上面那个 |
| 语义搜索 | `NLEmbedding.sentenceEmbedding` + Accelerate | 否 | 0（系统自带） |
| 在线改写 | `OpenAICompatibleProvider`（原样保留） | **是** | 0 |

---

## 2. 隐私边界在 Router，不在 UI（§11、§17）

`CaptureCoordinator` 只认识 `NoteGenerating`，完全不知道 MLX、Qwen 或 HTTP 的存在。
模式判断只发生在 `NoteGenerationRouter` 里：

```
local   : Qwen3（已安装时） → 任何失败 → Local Lite        ← onlineProviderFactory 一次都不碰
online  : 用户配置的 Provider，错误照实抛出
```

关键点是 `generateLocally` 的 catch 覆盖**所有**非取消错误，而不是只处理「模型没装」：

```swift
do {
    return try await qwen.generate(...)
} catch is CancellationError {
    throw CancellationError()
} catch {
    // 加载失败、权重损坏、OOM、JSON 解析失败，以及任何意料之外的错误，
    // 全部降级到 Local Lite。这里没有回到网络的分支。
    return try await localLite.generate(...)
}
```

也就是说：**模型坏掉不是联网的理由**。`.local` 路径下根本不存在对
`onlineProviderFactory` 的引用，所以即使把 API Key 配好放在那里，也不会有请求发出去。

`PrivacyTests.testLocalModeNeverCreatesNetworkRequest` 用一个真实的 `URLProtocol`
计数器验证这一点，而不是断言某个内部标志位。

---

## 3. 模型：Qwen3-0.6B-4bit（§2、§18、§19）

- 仓库：`mlx-community/Qwen3-0.6B-4bit`，权重约 **335 MB**，仓库约 **351 MB**，**Apache-2.0**。
- 运行时：**MLX Swift / MLX Swift LM**，纯 Swift，没有 Python、没有 Ollama、
  没有 llama-server、没有后台 HTTP 服务。
- 版本锁定：`mlx-swift-lm` **3.31.4**（tag）+ `swift-transformers` **1.3.4**（tag），
  写在 `project.yml` 的 `exactVersion` 里。**不使用 `main` 分支。**
  `ClipNest.xcodeproj` 是 gitignore 的（由 XcodeGen 生成），所以 `project.yml` 才是版本
  的唯一权威来源，`Package.resolved` 只是一次解析的产物。
- 只用四个 product：`MLXLLM`、`MLXLMCommon`、`MLXHuggingFace`、`Tokenizers`。

`MLXQwenEngine` 通过 `loadModelContainer(from: modelDirectory, using:)` 从本地目录加载。
这个 API **不接受 Downloader 参数**，所以模型加载这条路径在结构上就没有联网能力。

### 为什么不是别的模型

| 候选 | 否决原因 |
| --- | --- |
| Qwen3-1.7B 及以上 | 体积和内存超出手机可接受范围 |
| Qwen3.5-0.8B / Qwen-VL / MiniCPM-V | 多模态，约 1.77 GB，而且图片走 VLM 会绕过 OCR |
| Apple Foundation Models | §1/§35 明确禁止：中国区不可用，且不可控 |

### 为什么 OCR 仍然是 Apple Vision（§5、§23）

图片**先经过 Vision OCR 变成文字**，文字再进入语言模型。图片本身永远不进 VLM。
OCR 侧只使用 Apple Vision，没有 PaddleOCR / PP-OCR / Tesseract。

`VNRecognizeTextRequest` 用 `.accurate` + `usesLanguageCorrection`，语言按内容在
`zh-Hans` / `en-US` 之间解析；`supportedRecognitionLanguages()` 用实例方法
（类方法自 macOS 12 / iOS 15 起废弃），设置页的读数与实际识别用的是同一个来源。

---

## 4. 模型分发：不打包、走国内 CDN（§3、§4）

**模型不进 IPA。** 全新安装的包体不变。用户在设置里主动点击下载，模型落到：

```
~/Library/Application Support/ClipNest/Models/qwen3-0.6b-4bit/
```

不在 Documents、不在仓库目录、不在 iCloud；目录标记为 `isExcludedFromBackup`。
可以随时删除并重新下载。

### 生产环境**不**从 Hugging Face 下载

`LocalModelManager.configuredManifestURL()` 读取 `ai.localModelManifestURL`，由部署方指向
自己的腾讯云 COS / 阿里云 OSS 桶。**仓库里默认是空字符串**——没有配置时，设置页如实显示
「未配置下载地址」，下载按钮禁用并说明原因，而不是假装能下。这是刻意的：这个仓库里不
存在一个可用的生产 CDN。

**开发阶段怎么拿到权重**（本机实测：`huggingface.co` 超时返回 000，`hf-mirror.com` 与
`modelscope.cn` 均正常）：

```sh
Scripts/fetch-local-model.sh            # 从 hf-mirror 拉取 + SHA256 校验 + 安装
Scripts/fetch-local-model.sh --verify   # 只校验已有安装，不联网
```

`Scripts/model-manifest.qwen3-0.6b-4bit.json` 是**实测校验过的清单**（9 个文件的完整
SHA-256，总计 351,383,618 字节），可以直接当作 §4 要求的那份清单上传到你的 CDN：
文件与清单同桶放置，把 `ai.localModelManifestURL` 指向清单即可，下载器的路径校验、
断点续传与摘要校验立刻可用。

`LocalModelDownloader` 负责实际传输：

| 要求（§4） | 实现 |
| --- | --- |
| 清单 | `model-manifest.json`（`LocalModelManifest`），含 id / version / size / sha256 / files[] |
| 断点续传 | 4 MB 分块 + `Range` 请求，`.part` 文件留在原地，下次从断点继续 |
| 进度 | `AsyncThrowingStream<LocalModelDownloadEvent>`，`progress(fraction:bytesWritten:totalBytes:)` |
| 取消 | `Task` 取消 → 保留 `.part` 文件（取消不等于重来） |
| 重试 | 每块最多 4 次，线性退避；服务端忽略 `Range` 也不会写坏文件 |
| 校验 | 每文件流式 SHA-256（1 MiB 分块），先比大小再比摘要 |
| 版本管理 | 新版本整体替换旧版本，过渡目录 `replacement/` |
| 原子替换 | 校验通过后才 `rename`，崩溃在半途永远不会看起来像装好了 |

「装好了没有」以**磁盘为准**：模型目录里的 `model-manifest.json` 才是权威记录，
不是 UserDefaults。`isInstalled()` 只比对文件大小（每次启动重算 350 MB 摘要比它要防的
风险更糟）。

下载目的地是 `LocalModelStore`，清单 id 与目标模型不符、文件名带 `../`、清单空文件表、
缺 sha256，都会在**开始传输之前**被拒。

`LocalModelState` 是 `unsupportedDevice / notInstalled / downloading(fraction:) /
installed(version:bytes:) / failed`，设置页据此显示大小与状态（§28–§30）。

---

## 5. Local Lite：没有大模型时的完整能力（§12–§14）

`LocalLiteNoteProvider` 只用 Foundation + NaturalLanguage：

- 标题：`LocalTitleExtractor`（优先 Markdown H1，其次高频技术词）
- 摘要：`LocalSummarizer`，**抽取式**，不生成新句子
- 标签：`LocalTagExtractor` + `LocalTextAnalyzer.terms`
- 分类：`LocalSemanticClassifier`（词法 + 系统句向量的自适应融合）
- 正文：`MarkdownContentCleaner`

0 MB、0 网络、永远可用。这意味着**没装模型也完全没有功能缺口**，只是改写质量弱一些。

### 中文分词没有词典怎么办

`LocalTextAnalyzer` 用 `NLTokenizer` **并集** 一个脚本扫描器。并集不是保险起见：
`NLTokenizer` 会在中英交界处静默丢词，`MySQL和Spring` 会同时失去 `和` 和 `Spring`。

长中文串需要特别处理。`注意睡眠和饮食健康` 不是一个词，是一个从句。早期版本保留了整串、
又把里面的 bi-gram 当「冗余」删掉，结果是关于跑步的笔记（`每周跑步三次，注意睡眠和饮食健康…`）
和「生活」分类**没有任何共同词汇**，最后掉进 Inbox。修好它的规则：

- ≤ 6 字的串整体保留，**同时**展开成 bi-gram；更长的串只贡献 bi-gram。
- 只有「词形」的 key（≤ 4 字、技术词、或拉丁词）才能吞掉 bi-gram。
- 单个中文字在**索引侧**丢弃——`慢`、`最`、`用` 是分词噪声；查询侧同样有 2 字下限（见 §7）。
- `CategoryProfile.distinctiveKeys` 也把自己的中文关键词展开成 bi-gram，
  所以 `提示词` 这样的分类词仍然能在长从句里被找到。

### 分类置信度分三档（§16）

| 融合分 | 结果 |
| --- | --- |
| ≥ `autoAssign` (0.72) | 直接归入该分类 |
| `candidate` (0.58) … `autoAssign` | 记为 `suggestedCategory`，笔记进 Inbox |
| < `candidate` | 不动作 |

中间档存在的原因是「低置信度强行分类」比 Inbox 更糟：归错目录的笔记比待在 Inbox 更难找。

### 语义门限用「领先第二名」而不是「极差」

分类融合 `semantic × 0.7 + keyword × 0.3`，但只在嵌入**能区分**时才让它投票。
第一版门限是比较最优与**最差**（极差 ≥ 0.02），这是错的：

```
"SwiftUI 调用 Vision" 的余弦
  数据库=0.969  服务器运维=0.966  旅游=0.934  生活=0.948  iOS开发=0.921  AI=0.908
```

极差 0.061，轻松越过 0.02，可前两名只差 0.003——差距全来自尾部。旧门限下嵌入压过词法层，
基准仓库上 top-1 只有 **50%**。现在门限是领先**第二名**的幅度（`minimumSemanticMargin`，0.02）：
同一组数据 0.969 vs 0.966 → 0.003 → 不可区分 → 纯词法决定。`LocalSearchEngine` 用同一个
统计量决定要不要放行「仅语义」结果。

---

## 6. 小模型的 JSON 容错（§22）

0.6B 模型不会稳定输出合法 JSON，所以 `LocalGeneratedNoteDecoder` 逐级尝试：

1. 直接解析；
2. 去掉 ` thinking…` 推理块（含未闭合的情况）；
3. 去掉 ```json 围栏；
4. 从任意位置取出第一个**配对**的 `{...}`（正确跳过字符串内的花括号与转义）。

字段级容错：接受中英两套键名（`标题`/`摘要`/`正文`/`内容`/`分类`/`标签`），
标签既接受数组也接受逗号/顿号分隔的字符串，去重（忽略大小写）且上限 6 个。

**一个字段坏掉不丢整条笔记**——`QwenLocalProvider` 会把坏的字段就地补回来：

| 情况 | 处理 |
| --- | --- |
| 标题为空 | `LocalTitleExtractor` 从原文取 |
| 正文为空 / 模型把 JSON 回显进了正文 | 用清洗后的原文 |
| 摘要为空 | `LocalSummarizer` 本地生成 |
| 标签为空 | `LocalTagExtractor` 本地提取 |
| 分类不在给定列表里 | 丢弃，交给本地分类器 |

最后一条很重要：模型**只能从已有目录里挑**，它编出来的目录名永远不会变成仓库里真实存在的
文件夹；匹配是忽略大小写的，但写入的是用户原本的目录名。

正文的围栏处理是刻意收窄的：只有当外层围栏标记是 `markdown` / `md` / 无标记、
且闭合围栏之后没有别的内容时才剥掉。如果笔记正文本身就是一段 Swift 代码，它以 ``` 开头，
剥掉就会毁掉 prompt 明确要求保留的代码。

整个回答完全无法解析时，抛 `.generationFailed` → router 降级 Local Lite → **笔记照样保存**。

Prompt 侧（`LocalPromptBuilder`）：`/no_think` 关闭推理、最多 768 个生成 token、
输入上限 4000 字符（在行边界截断，全文仍然完整落盘）、列出可选目录白名单、
明确要求「必须保留代码、数字、URL 和原始事实。禁止编造原文没有的信息。」

---

## 7. 搜索：FTS5 + 查询扩展（§24、§25）

v1 用 SQLite FTS5，索引 title / tags / summary / filename / body / path，
权重 title 4、tags 3、summary 2、正文 1，`bm25()` 排序。中文按 bi-gram 预切分，
拉丁词最后一项做前缀匹配（边打字边搜：`Vis` 已经能找到 `Vision`）。

**不引入第二个 embedding 模型。** `BAAI/bge-small-zh-v1.5` 推迟到第二阶段——
词法层在基准仓库上已经 100%，而系统的 `NLEmbedding` 只有 12%，瓶颈是模型质量不是融合方式。
（`NLEmbedding` 是本机自带、0 MB、已经上线的，§24/§25 禁止的是**再下一个**模型。）

### 查询扩展

模型已安装时（且 `ai.localQueryExpansion` 打开，默认开），`LocalQueryExpander` 会用 Qwen
把查询扩成 2–4 个相关关键词，OR 进 FTS 表达式。它是纯粹的增强，三条退路都测过：

| 情况 | 行为 |
| --- | --- |
| 没装模型 | 不问模型，直接用原查询 |
| 模型太慢（> 700 ms） | 放弃扩展，屏幕上已经是字面查询的结果 |
| 模型答非所问 | 每个候选词都过校验（长度、词数、标点、停用词），不合格的丢掉 |

顺序上，**字面结果先出**，扩展结果到了再补一次搜索；并且用 `self.query == query` 挡住
过期的扩展覆盖新结果。用户继续打字时旧任务被取消。结果按查询串缓存，避免同一个查询反复
调用模型。

排序上，**字面命中永远优先于扩展命中**——不是靠乘一个惩罚系数（那个无法保证，
因为 BM25 分数无上界），而是 `SearchResult.matchedQueryLiterally` 作为独立排序档位。
没有扩展时每一行都是字面命中，排序行为与改动前完全一致。

> 顺带修掉一个真实缺陷：`NLTokenizer` 会把 `截图取字` 切成 `截图 / 取 / 字`，
> 而索引侧有 2 字下限，单个中文字**永远不可能**出现在索引里。可它过去会进入查询词，
> 于是 `matchedTerms` 的朴素子串判断会让一条只含「字」的笔记声称自己命中了字面查询。
> `queryTerms` 现在对单个中文字应用同样的下限（整查询折叠成一项仍然保留，
> 所以真的只搜一个字依然能用）。

---

## 8. 内存与线程（§26）

| 工作 | 在哪跑 |
| --- | --- |
| Vision OCR | `Task.detached(priority: .utility)` |
| 仓库扫描 / 分块 / 嵌入 / SQLite 写入 | `LocalSearchIndexer`（actor） |
| 模型权重 | `LocalModelRuntime`（actor），按需加载、缓存、空闲卸载 |
| 渲染结果 | 主线程，打字防抖 120 ms 之后 |

`LocalModelRuntime` 的三个出口：内存警告、App 进入后台（iOS）、空闲超时（120 s）
都会卸载权重。切换模型目录会让旧权重失效。同一个目录重复取用只加载一次。
`provider(modelDirectory:profiles:)` 是 `nonisolated` 且惰性的——构造它不会加载 350 MB。

分块 300–600 字符（目标 420）。索引只保存元数据与向量，不保存正文，所以内存随 chunk
数量而非仓库大小增长，笔记正文只在打开某条结果时再读一次。索引在 actor 上做，
主线程只负责赋值。

---

## 9. 设置界面（§27–§30）

`设置 → AI 处理`：本地/联网二选一 + 说明，默认本地。

`设置 → 本地增强模型`（仅本地模式显示）：
- 未安装 → 显示「约 351 MB」和下载按钮（未配置 CDN 时按钮禁用并说明原因）
- 下载中 → 进度、取消
- 已安装 → 版本、占用空间、删除

`设置 → 本机能力`（仅本地模式显示）逐项列出真实状态：

| 能力 | 状态来源 |
| --- | --- |
| 图像文字识别 | Apple Vision 是否可用 |
| 基础文本整理 | ClipNest Local Lite——**永远可用** |
| 增强 AI 改写 | 硬件（`arm64`）→ 运行时是否编入 → 模型是否已安装，三级都过才 ✓ |

状态字面量是算出来的，不是写死的。在没链接 MLX 的构建里，增强 AI 那行会如实显示
「未包含在此构建中」。持久化的键是 `ai.processingMode`、`ai.localModelInstalledVersion`、
`ai.localModelLastUsedAt`、`ai.localQueryExpansion`、`ai.localModelManifestURL`——
**模型路径不进 UserDefaults**。

---

## 10. 实测数据

`Tests/LocalBenchmarkTests.swift`。复现：

```sh
xcodebuild test -project ClipNest.xcodeproj -scheme ClipNest \
  -destination 'platform=macOS' -only-testing:ClipNestTests/LocalBenchmarkTests \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" \
  DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=
```

环境：macOS 15.7.7（Apple silicon）、Swift 6.2.4、Xcode 26.3、SDK macOS 26.2。

**延迟**

| 工作 | 实测 | 预算 |
| --- | --- | --- |
| Local Lite，短文本 | 1.2 ms | 50 ms |
| Local Lite，完整笔记 | 22.1 ms | 150 ms |
| 分类，冷启动 | 230–405 ms | 一次性 |
| 分类，稳态 | 21.5 ms | 100 ms |

冷启动要为每个分类档案算嵌入；稳态复用。这就是 `SystemEmbeddingProvider` 做记忆化的原因
（上限 512 条，整体清空）。基准跑出 72 命中 / 26 未命中 / 26 条。加缓存前稳态分类是
**215 ms**，超预算。

**8 条中文技术笔记 / 6 个分类的分类准确率**

| 引擎 | Top-1 |
| --- | --- |
| 只用 Apple 句向量 | 12% |
| 上线版本（自适应词法 + 向量） | **100%** |

嵌入不只是没用，是有害的：`MySQL 慢查询` 的最优匹配是 `服务器运维`（0.962），
正确项 `数据库`（0.959）排第二。

---

## 11. 验证状态与诚实边界

**已验证**

- 测试：**237 个，0 失败（1 个 skip）**。链接 MLX 后 `LocalModelRuntime.isRuntimeLinked == true`
  ——唯一被跳过的就是 `testTheDefaultFactoryRefusesWhenTheRuntimeIsNotLinked`，
  它由「通过」转为「skip」正是这个测试存在的意义：它证明了 MLX 真的被编进来了。
- 构建，全部成功且源码零警告：

  | 配置 | 结果 |
  | --- | --- |
  | macOS Debug（arm64） | ✅ |
  | macOS Release（arm64） | ✅ |
  | macOS Release（x86_64 / Intel） | ✅ |
  | iOS 17 Simulator | ✅ |
  | iOS 真机（arm64，本地 Team） | ✅ |

  **universal 分发没有被破坏，但要按正确方式构建。** `Scripts/distribute-app.sh` 用的
  `ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO` 构建成功，产出经 `lipo -archs` 确认为
  `x86_64 arm64`。注意：**单纯给 `ARCHS=x86_64` 会失败**，报
  `None of the architectures in ARCHS (x86_64) are valid … (in target 'MLXHuggingFaceMacros')`
  ——MLX 的宏目标 `VALID_ARCHS` 只有 arm64。宏是**构建期**在宿主机上运行的工具，
  不进入产物，所以这是命令写法的坑，不是分发能力的问题。
  运行时 Intel Mac 仍然按 §27 走 Local Lite（`LocalModelStore.isHardwareCapable`
  在非 `arm64` 下为 false，下载入口被挡住）。
- MLX 可行性在正式接入前先做了独立原型验证（§19）：macOS 14 完整栈构建通过
  （`Build complete! (209.11s)`，977 个任务）；iOS 17 Simulator 经 XcodeGen + `xcodebuild`
  得到 `** BUILD SUCCEEDED **`。原型验证通过后才把版本钉进 `project.yml`。

**真实权重已经跑通（本节曾写「模型从未生成过一个 token」，现已推翻）**

本机直连 `huggingface.co` 仍然超时（`curl` 返回 000），但 **`hf-mirror.com` 可达**，
所以 351.4 MB 权重已经真的下载、校验、安装，并驱动出真实的 `GeneratedNote`：

校验结果：**9/9 文件、351,383,618 字节全部通过**。其中两个 LFS blob 的摘要与
Hugging Face 官方发布的 oid 逐字节一致：

| 文件 | 大小 | SHA-256 |
| --- | --- | --- |
| `model.safetensors` | 335,450,584 | `392e8d46…7bce2` |
| `tokenizer.json` | 11,422,654 | `aeb13307…2dae4` |

完整清单见 `Scripts/model-manifest.qwen3-0.6b-4bit.json`（§4 详述）。

**真实推理实测**（`Tests/QwenLiveInferenceTests.swift`，4 个用例全绿；权重缺失时自动 skip）

| 指标 | 实测 |
| --- | --- |
| 冷加载 | **1.30–1.36 s**（首次加载 335 MB 权重） |
| 单条生成（768 token 上限） | **3.38–4.31 s** |
| 二次生成（热运行时） | 7.7 s / 2 次生成，不重复付加载成本 |
| 标题 / 摘要 / 分类 | 5/5 采样正确（修 prompt 之前标题 0/5） |
| 思维链 | 5/5 采样为 0（`enable_thinking: false` 生效） |

**接入 MLX 的真实体积代价（§3 / §37 要求「安装包增加很小」，这里给出真实数字）**

模型本身确实没进包（351.4 MB 全在 `Application Support`），但 **MLX 运行时是静态链接进
App 的**，代价不小。同一份代码，只切换 `project.yml` 里的包依赖，全部干净重编：

| 配置 | 不含 MLX | 含 MLX | 增量 |
| --- | --- | --- | --- |
| macOS Release（arm64）`.app` | 11 MB | 48 MB | +37 MB |
| macOS Release（arm64）二进制 | 8.2 MB | 42.0 MB | +33.8 MB |
| macOS Release（universal）二进制 | — | 86 MB | — |
| **iOS Release（arm64）`.app`** | **16 MB** | **53 MB** | **+37 MB** |
| **iOS Release（arm64）二进制** | **7.8 MB** | **41.1 MB** | **+33.3 MB** |
| **iOS 分发包（zip，≈ 用户下载量）** | **10.0 MB** | **17.7 MB** | **+7.7 MB** |

结论要说清楚，因为它和 §37 的措辞不完全一致：

- **用户下载量 +7.7 MB**（10.0 → 17.7 MB，压缩后），这个量级可以说「很小」。
- **装完占用的空间翻了 3 倍多**（16 → 53 MB），主要是 33 MB 的 MLX 静态代码加
  3.6 MB Metal kernel（`mlx-swift_Cmlx.bundle/default.metallib`）。
- 这正是「模型按需下载」换来的代价：351 MB 权重不在包里，但 33 MB 运行时必须在包里。

**如果这 33 MB 不可接受**，可选路径（本轮未做，因为它改变了架构）：把 MLX 运行时也做成
按需下载的动态框架，或为 Intel / 不下载模型的用户出一个不含 MLX 的构建变体。
`LocalModelRuntime.isRuntimeLinked` 与所有 `#if canImport(MLX*)` 守卫已经为「编进/不编进
MLX 都能正常工作」准备好了——本节的对照构建就是靠它们编译通过的。

一次真实输出：

```text
title    : Vision OCR 图片文字识别
summary  : 在 SwiftUI 里使用 VNRecognizeTextRequest 对图片做本地文字识别。设置
           recognitionLevel 为 accurate，并开启 usesLanguageCorrection。…
category : iOS开发
tags     : OCR, Vision, 图片, 文字, 识别, A4
```

**跑真机才暴露出来的四个缺陷（已全部修掉）**

这是本轮最有价值的部分：单元测试用脚本化引擎断言精确字符串，**结构上不可能发现这些**。

1. **`/no_think` 在这个模型上无效（§21 未真正满足）。** 原始输出以
   `<think>\n\n</think>` 开头，思维链照旧产生。改为走 Qwen3 聊天模板的
   `enable_thinking` 开关（`LocalPromptBuilder.chatTemplateContext`，由 `MLXQwenEngine`
   传给 tokenizer）后，5/5 采样思维链为 0。`/no_think` 已删除，并有测试禁止它回来。
2. **标题和标签被分类列表污染。** 旧 prompt 把分类列表单独放在原文前面，模型直接把它
   抄进了 `title` 和 `tags`（5/5 采样中标题错、3/5 标签错）。重写为编号规则、
   把分类并进它所属的那条规则后，标题 5/5 正确。
3. **正文被悄悄截断，丢掉事实。** 同一段原文采样 5 次，有 3 次正文把
   `iPhone 15 Pro` / `0.4 秒` 这类测量值整句丢掉，而 JSON 依然完好——所以既有的
   「字段为空才修复」逻辑根本不会触发。新增 `LocalFactPreservation`：正文与
   **正文+标题** 比对，URL、数字、技术标识符缺失即判定为数据丢失，改用清理后的原文正文。
   模型提供标题/摘要/标签/分类，正文在它证明自己忠实之前不采信。
4. **查询扩展把 `<think>` 当成关键词。** 实测返回 `["<think>", "<", "think>", …]`，
   这些词会被 OR 进 FTS 表达式。解析前先剥离推理块，并把 `<>` 加入分隔符。

**真机验证（§36⑫）：已在物理 iPhone 15 Pro 上跑通**

`ClipNestTests` 是 macOS-only target，在 iPhone 上**结构上无法运行**——所以新建了
`ClipNestDeviceTests`（iOS 17 target，`TestsDevice/`）与 `ClipNestDevice` scheme，
专门承载设备可跑的子集。这也是本轮新增的唯一工程结构。

```sh
Scripts/deploy-ios.sh                       # 构建 + 安装 + 启动
xcodebuild test -project ClipNest.xcodeproj -scheme ClipNestDevice \
  -destination "id=<UDID>" -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM=U8U443D7ZL CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Apple Development" PROVISIONING_PROFILE_SPECIFIER=
```

权重用 `xcrun devicectl device copy to --domain-type appDataContainer` 推进 App 容器
（335 MB 约 11 秒）。实测结果，**5/5 通过、0 失败**：

| 项目 | 实测 |
| --- | --- |
| 设备 | **iPhone 15 Pro（`iPhone16,1`）**，iOS 27.0 (24A437) |
| App 看到的模型 | `351,383,618` 字节，位于容器内 `Library/Application Support/ClipNest/Models/qwen3-0.6b-4bit` |
| 真实生成（设备 GPU） | **3.95 s** |
| 热生成 | **3.07 s**（连续调用不重载模型） |
| 冷启动 + 两次生成 | **10.1 s** 合计 |
| 输出正确性 | 标题/摘要/分类（`iOS开发`）/标签 全部正确，`VNRecognizeTextRequest` 等代码标识符保留 |
| **本地模式网络请求数** | **0**（同时挂着一个**有效**的在线配置） |
| 全新安装路径（无模型） | 仍产出可用笔记，网络请求 **0** |

两点必须如实说明：

- `load (cold)` 在输出里显示 `0.00 s`，是因为同一进程内更早的用例已经把模型加载过了
  （XCTest 按字母序执行）。真实的冷加载包含在上面「10.1 s 合计」里，未单独测得。
- 推送时 `devicectl` 报告的容器 UUID 与测试运行时 App 自报的容器 UUID 不一致
  （App 重装导致）。所以断言写的是**精确字节数**而不是路径——App 自己算出来是
  351,383,618 字节，这比路径更能证明它真的看得见权重。

**顺带修掉的两个既有缺陷**（它们在改动前的版本里就存在）

- **标签里出现跨词中文二元组。** `LocalTextAnalyzer.tokens` 为了搜索召回，把
  `图片文字识别` 拆成 `图片/片文/文字/字识/识别`；这些片段进入**用户可见的标签**
  就变成噪声（实测标签里出现过 `片文`）。根因是 `NLTokenizer` 其实分词完全正确
  （`图片/文字/识别`），污染来自我们自己叠加的 script-run 二元组。
  新增 `wordTokens` / `wordTerms`：只并集**非 CJK** 的 script run（保住
  `zh-Hans`、`MySQL和 Spring` 的 `Spring`），中文只信 `NLTokenizer`。
  标签与关键词标题走这条路，搜索索引不变。
- **`C++` / `C#` 被静默吞掉。** `normalizedKey` 会裁掉首尾的 `+` `#`，于是
  `C++`、`C#`、`C` 归一到同一个 key，先到先得——裸 `C` 赢，`C++` 消失。
  而该文件的注释恰恰声称 `C++` 会被完整保留。改用 `TokenCollector`：同 key 冲突时
  保留更具体的拼写。

**提速与进度可视化（本轮，按用户要求）**

用户问：「粘贴后是立刻就调用模型吗？模型是提前加载的吗？」并指出：不能让用户只看到一个
静止状态，要能看见生成过程。于是先在真机上量了时间都花在哪，再动手。

真机测量（iPhone 15 Pro，`DevicePerformanceTests`）：

| 阶段 | 实测 |
| --- | --- |
| Apple Vision OCR | **0.30 s**（三次 0.298 / 0.318 / 0.295）——不是瓶颈 |
| 模型加载（冷，一次性） | **1.17–1.65 s** |
| **prefill（272 tok）** | 0.89–1.13 s（240–306 tok/s） |
| **decode** | **占了约 80%**，只有 31–47 tok/s |

结论：**decode 是瓶颈**，而 decode 的产物大部分被丢掉了。于是又量了一次：

**模型正文的存活率 = 1/6。** 6 次真机采样里，模型重写的正文只有 1 次通过了事实保全守卫，
其余 5 次被判定丢事实、改用原文——**也就是那 5 次花几秒生成的正文，产出即废弃**。

因此把默认策略改成 `.sourceVerbatim`：模型只写标题/摘要/标签/分类，正文直接用清理后的
原文。这不是拿质量换速度——那 5/6 的情况下，省掉这一步后**存下来的笔记和慢路径逐字节相同**，
而且因为不再重写，它**不可能**再丢事实。想要模型重排正文的用户可以在设置里切回
`.modelRewrite`。

真机对照（同一台手机、同一次运行、同一段原文）：

同一个测试跑了两轮真机（iPhone 15 Pro，`ClipNestDevice` scheme），两轮都打印生成 token 数：

| 正文策略 | 生成 token | decode | 端到端 |
| --- | --- | --- | --- |
| `.sourceVerbatim`（新默认） | **70** | 0.76–2.23 s | 1.43–2.73 s |
| `.modelRewrite`（旧行为） | 203–225 | 2.55–4.72 s | 2.39–7.01 s |

**`end-to-end` 那一列的跨度是真实存在的，别只引用一个数。** 同一台手机、同一个测试、同一段原文，
两轮的绝对耗时差了接近 2 倍（热降频与调度）。**稳定可复现的是 token 数：70 对 203–225，即生成量降了约 3 倍**——
这是策略本身决定的，不随设备状态漂移。时间上的收益方向一致（预热那节里我也因为同样的原因放弃了用端到端计时下结论）。

macOS 上的同向对照：`sourceVerbatim` 89–123 tok / 1.25–1.71 s，`modelRewrite` 224–295 tok / 3.41–4.43 s。

**真机第三次对照（预处理耗时拆分，同一段原文）**

```
[sourceVerbatim]
  prompt 256 tok in 0.31s (822 tok/s) · generated 61 tok in 0.81s (75 tok/s)
  end-to-end: 1.81 s   · title "Vision OCR 图片文字识别"
[modelRewrite]
  prompt 272 tok in 0.33s (819 tok/s) · generated 200 tok in 2.99s (66 tok/s)
  end-to-end: 3.75 s   · title "Vision OCR 图片文字识别"
```

**模型加载 1.11 s、prefill 只占约 0.3 s**——所以「慢」几乎全部来自 **decode**，而不是读 prompt。
`modelRewrite` 的 3.75 s 里有 2.99 s 是逐字生成 200 个 token；`sourceVerbatim` 只生成 61 个。
两轮的**标题完全一样**（`Vision OCR 图片文字识别`），这支持「改写正文收益很小」的判断。

**为什么默认选 `sourceVerbatim`：`modelRewrite` 的正文几乎从不通过事实守卫。**

专用真机测试（6 个样本）结果：

```
kept 0/6 model bodies; 6 fell back to the source
```

**6 个样本里模型写的正文 0 个通过事实守卫，全部回退到原文。** 也就是说
`modelRewrite` 花 2 倍时间生成的那 200 个 token，**在真机上基本一定被丢掉**。
这从数据上印证了默认值的取舍；同时它也验证了 §22——6 次回退**全部优雅落回原文**，
没有一次导致笔记丢失。

**模型提前加载。** 之前是「首次使用时加载，随后保温」：启动后第一次粘贴要付
1.17–1.65 s 的加载。现在增加了预热——App 进入前台、用户还在浏览时就把权重读进内存，
于是**首次粘贴不再付这一秒多**。受设置项「保持模型就绪」控制（默认开），关掉就退回
按需加载。§26 的内存策略不变：内存压力与切后台仍然卸载，所以代价被限制在前台期间。

**进度可视化。** 之前只有一个静止状态。现在生成过程通过
`NoteGenerationProgress` 上报三个阶段——`preparingEngine`（读权重）、`generating`（带
**已经成形的标题与摘要**）、`finishing`——状态条实时显示。标题与摘要是**边生成边解析**的
（`LocalPartialJSON`），所以用户看到的文字在长，而不是一个转圈。
`LocalPartialJSON` 是纯逻辑、可测的，17 个测试覆盖半截 JSON、转义、代理对、键名误匹配。

真机实测（iPhone 15 Pro，`ClipNestDevice`，一次真实生成）：

```
===== ON-DEVICE STREAMING =====
elapsed            : 2.16 s
progress callbacks : 7
with a preview     : 6
first titled frame : yes
longest title seen : 17 chars
phases             : generating(preview: Clip → … ×6 … → finishing
```

**7 次回调里有 6 次带着已经开始成形的预览**，而且第一帧带标题的时刻**早于**整段完成——
这正是「不是卡住，是在长」的量化证据。

**顺带发现并修掉的一个真实缺陷：短 prompt 会让模型多打一个引号，导致 15% 的捕获被丢弃。**

跑真权重时出现 `generationFailed("The local model did not return JSON.")`。我第一次的结论是
「模型约 3–4% 的概率返回散文」——**这个结论是错的**，而且差点让我用一个错误的重试去糊住它。
写了个压测（20 次生成、把失败样本的原文打出来）之后才看清真相：

```
{"title":"...","category":"iOS开发","tags":["VNRecognizeTextRequest","zh-Hans","accurate"]"}
                                                                                        ↑ 多了一个引号
```

**内容是完好的 JSON，只是在 `]` 和 `}` 之间多了一个引号。** 压测结果 **3/20 = 15%**，
而且三次的形状完全一样。

为什么这会致命：`balancedObject` 用「字符串内/外」状态机找配对花括号。走到那个多余的引号时
它被当成「字符串开始」，于是后面的 `}` 被当成字符串内容，括号永远配不平 → 返回 nil；
`JSONSerialization` 也失败。**一个字符，整条答案作废。** 旧代码的后果是这次捕获静默降级到
Local Lite（仍然出笔记、仍然不联网，但质量下降）——而且 15% 的概率相当高。

修法是加一个**定向修复** `repairingStrayQuotes`：扫一遍文本，遇到「不在字符串内、且后面
（跳过空白）紧跟 `}` 或 `]` 的引号」就认定它是多余的、丢掉。
关键性质：**它排在所有诚实解析之后才尝试**，所以永远不会掩盖一个本来就能解析的答案。
`LocalStrayQuoteRepairTests` 用**实测抓到的原始字符串**做断言，并覆盖了「合法空字符串」
「值里含 `}`」这些不能被误伤的情况。

修复后重跑同一个压测：**0/20**（原来 3/20）。真实套件连跑 6 轮全绿（修复前 8 轮里失败 2 轮）。

**重试仍然保留**，但它的定位变了：现在它只是兜底，覆盖真正非 JSON 的答案，不再是主要防线。
两者的取舍写清楚了——修复处理已知形状，重试处理未知形状。

**「合适的时机」到底是哪一刻（本轮补上的一块）**

上一轮把预热挂在 vault 视图的 `.task` 上——那等于「启动后用户进到保险库就预热」。**这个时机漏掉了本 App 最主要的用法。**

真机复测时才看清这条链路：`didEnterBackgroundNotification` → **卸载模型**（§26 要求），而 `.task` 只在视图出现时跑一次。所以真实流程是：

1. 启动 → 预热 ✓
2. 用户切到别的 App 去复制东西 ← **这恰恰是剪贴板类 App 的核心用法**
3. 切回来 → 后台卸载生效，而 `.task` 不会再跑 → **没有重新预热**
4. 粘贴 → 冷加载 1.35 s 原封不动地回到关键路径上

也就是说，预热在最需要它的那条路径上恰好失效了。现在把它挂到 `scenePhase == .active`：用户切回来的那一刻就开始加载，与读剪贴板、跑 OCR 并行，等真正需要模型时它已经在内存里。

**量化（iPhone 15 Pro，`ClipNestDevice` scheme，独立进程）**

| | 实测 |
| --- | --- |
| 冷加载（首次捕获必须付） | **1.35 s** |
| 热生成 | **1.37 s** |

**首次捕获里，加载占了大约一半。** 这就是「避免每次粘贴都付加载成本」的量化依据。

**顺带修掉一个预热自己引入的并发缺陷**

把预热挂到 `.active` 之后，**预热和它正在预热的捕获会同时发生**。而 `engine(for:)` 在 `await` 处会让出 actor，于是两个调用者都会看到「什么都没加载」，然后**各自造一个引擎**。用可注入的 factory 写了个计数测试，先复现：

```
XCTAssertEqual failed: ("2") is not equal to ("1")
  - preload must not duplicate the load the capture is already doing
```

**两次构造、两份 350 MB 权重**——而且正好发生在那条本来是为了省时间的路径上。改成 single-flight：同一个 directory 的加载只有一个 `Task`，后来者 `await` 同一个结果。7 个并发测试覆盖（含 public `preload` 入口的那条真实竞态、失败不缓存、`unload` 后必须重载、切换目录必须换引擎）。修复后 `2 → 1`。

**一个我没能证明的结论（如实记下）**

我原本想用真机端到端证明「预热后的捕获更快」，结果测出来是**负的**：

| | 实测 |
| --- | --- |
| 预热 | 1.14 s |
| 冷捕获（加载+生成） | 3.61 s |
| 预热后捕获（只生成） | 3.69 s |
| **省下** | **−0.08 s** |

原因不是预热没用，而是**生成耗时自己的波动（约 2.5–4.7 s，受热降频与调度影响）比要省的 1.14 s 还大**——端到端比时间测的是噪声。所以这个测试改成断言**结构性事实**：预热确实做了一次真实加载（>0.1 s）、预热后 `isLoaded == true`、随后捕获取引擎是缓存命中而不是再加载一次。这三条是确定的；「快 1.1 秒」这件事在当前设备上**无法用端到端计时可信地展示**，我没有把它写成结论。

**✅ 改写后的断言已在真机上跑过（10/10 通过）**

手机解锁后补跑了完整 `ClipNestDevice` 全量。改写后的预热测试**通过**，并打出真实数字：

```
===== PREHEAT EFFECT (objective ①) =====
device            : iPhone16,1
cold load         : 1.20 s  (what a capture pays today)
preload           : 1.12 s  (same load, done early)
engine lookup after preload: 0.000 s
model resident after preload: true
========================================
```

**关键那格是 `engine lookup after preload: 0.000 s`**：预热之后，捕获去取引擎是纯粹的缓存命中，**1.1 秒的加载被完整移出关键路径**。而 `preload: 1.12 s` 同时证明了预热**真的在做那次加载**（不是空转跳过）——所以这不是把成本藏起来，是把它挪到了用户还在读剪贴板内容的那段时间里。

**为什么真机测试无法用模拟器代替（本轮试过，已记录以免重复踩）**

为了在手机锁屏时也能验证设备测试的逻辑，我试过把 351 MB 权重拷进模拟器容器再跑
`ClipNestDevice` scheme。结果**在 MLX 的 C++ 层直接崩掉**：

```
libc++ Hardening assertion __s != nullptr failed: basic_string(const char*) detected nullptr
ClipNest encountered an error (Test crashed with signal abrt before establishing connection.)
```

编译是通的（`TEST BUILD SUCCEEDED`），但一跑到真实推理就 abort。**所以带真实权重的设备测试
只能在物理设备上跑，没有替代路径**——这不是我偷懒跳过，是技术上没有别的办法。（已把拷进去的
权重清掉。）

**仍未验证（环境不允许，如实列出）****仍未验证（环境不允许，如实列出）**

1. **真实 CDN 的端到端下载。** 仓库里没有可用的生产清单 URL，下载只在
   `FakeModelServer` 上验证过：分块、续传、截断、篡改、重试、取消、原子替换都是真实的
   HTTP 语义，但服务端是我们自己的假服务器。真机上的权重是用 `devicectl` 推进容器的，
   **没有走下载器**。
2. **iPad 与 M1–M5 各代 Mac。** 真机只覆盖了 iPhone 15 Pro（A17 Pro）一台。
3. **设备端耗时只有单次采样。** 3.95 s / 3.07 s 各来自一次运行，不是多次统计。
   冷加载未单独测得（见上）。

**已知取舍**

- `isInstalled()` 只比大小不重算摘要。
- Intel Mac 按 §27 走 Local Lite + 在线，模型下载被硬件判定挡住。
- 保留 `NLEmbedding` 智能搜索与新的 FTS5 + 查询扩展并存。
- `ClipNestDeviceTests` 是新增的 iOS 测试 target，只为承载真机可跑的子集；
  `ClipNestTests` 仍是 macOS-only，两者不可互相替代。
- iOS 真机构建用的是本机 Team（`U8U443D7ZL`）；`project.yml` 里的
  `ClipNest AppStore` 描述文件属于上游仓库，本机没有，所以像 `Scripts/deploy-ios.sh`
  那样在命令行覆盖签名设置即可，不需要改 `project.yml`。
- `Scripts/deploy-ios.sh` 本轮补了 `-skipMacroValidation`：接入 MLX 后宏目标需要显式
  跳过校验，否则真机构建会以
  `Macro "MLXHuggingFaceMacros" … must be enabled before it can be used` 失败。
  这是 MLX 接入在本轮之前留下的一个真实破损，已修。

---

## 12. 测试清单（§34）

| 套件 | 覆盖 |
| --- | --- |
| `LocalModeTests` / `OnlineModeTests` | 两种模式的选择与互不干扰 |
| `AIProcessingModeTests` | 只有两种模式；旧 `automatic` 解析为本地 |
| `PrivacyTests` | `testLocalModeNeverCreatesNetworkRequest`——真实 URL 加载计数器；本地模式下拍照不碰图片端点 |
| `LocalModelFallbackTests` | 模型坏掉仍然出笔记，且计数器为 0；模型正常时不惊动 Local Lite |
| `QwenProviderTests` | 好/坏输出、字段修复、分类校验、取消传播、token 上限、prompt 形状 |
| `QwenLiveInferenceTests` | **真实权重**端到端：加载 → 生成 → `GeneratedNote`；权重缺失自动 skip |
| `DeviceLocalAITests`（`ClipNestDevice` scheme，iPhone 15 Pro） | **真机**真实权重、网络请求计数为 0、热生成不重载、全新安装路径 |
| `LocalBodyStyleTests` | 默认快路径：不再索要正文、忽略多返回的正文、token 预算、与慢路径字段一致 |
| `LocalPartialJSONTests` | 边生成边解析：半截 JSON、转义、`\uXXXX` 与代理对、键名误匹配、流式前缀单调 |
| `NoteGenerationProgressTests` | 阶段顺序（先加载后生成）、流式多帧、预览只增不减、不支持流式的引擎仍上报一次 |
| `LocalModelRetryTests` | 非 JSON 恰好重试一次；硬失败与取消不重试 |
| `LocalStrayQuoteRepairTests` | 实测抓到的多余引号必须修好；合法空字符串与值里含 `}` 不得误伤；修复排在最后 |
| `DevicePerformanceTests`（真机） | OCR 耗时、两种正文策略的 prefill/decode/端到端对照、流式帧数、预热把加载移出关键路径 |
| `LocalModelRuntimeConcurrencyTests` | single-flight：预热与捕获并发只加载一次；失败不缓存；unload 后重载；换目录换引擎 |
| `LocalModelPreloadDecisionTests` | 预热**决策**：本地模式+开关开→预热；开关关→不预热；全新安装默认预热；在线模式永不预热本地模型；关开关在所有模式下都优先 |
| `CaptureProgressBannerTests` | 阶段→横幅文案的映射；空预览不得顶掉文案；三个阶段文案必须互不相同且只能向前；捕获结束必须清空预览 |
| `LocalFactPreservationTests` | 正文丢事实的判定、标题豁免、URL/数字/连字符标识符、短文本 |
| `LocalTaggingRegressionTests` | 标签不含跨词二元组；`C++`/`C#` 不被裸 `C` 吞掉 |
| `LocalGeneratedNoteDecoderTests` | 推理块、围栏、噪声包裹、字符串内花括号、转义、中文键、标签解析 |
| `LocalPromptBuilderTests` | prompt 短、经聊天模板禁思考（非 `/no_think`）、带目录列表、防编造 |
| `ModelDownloaderTests` | 校验后原子替换、续传只取缺失尾部、篡改被拒、取消保留断点、重试、服务端忽略 Range、进度单调、版本替换、删除 |
| `ModelIntegrityTests` | 清单 id 校验、路径穿越、空文件表、摘要缺失、大小不符即失效、清单随权重落盘、目录位置 |
| `LocalQueryExpanderTests` | 解析各种真实输出、无模型、超时、缓存、短查询不扩展 |
| `ExpandedSearchTests` | 字面命中优先于扩展命中、扩展单独也能召回、无扩展时行为完全不变、恶意输入被引号保护、单字查询词回归 |
| `LocalModeAcceptanceTests` | §37 全新安装（无模型无 Key）离线拍照 → OCR → 标题/摘要/标签/分类 → 存盘 → 可搜索 |
| `LocalLiteTests` / `LocalSummaryTests` / `LocalTitleTests` / `LocalTagTests` / `LocalClassificationTests` | 抽取质量、不编造、置信度分档与门限 |
| `VisionOCRServiceTests` / `OCRTests` / `OCRTests 后处理` | 语言解析、渲染图识别、后处理 |
| `SearchRankingTests` / `SearchTests` | 排序、前缀/精确匹配、增量索引、自适应融合 |
| `LocalBenchmarkTests` | 延迟预算与质量门限 |
| `ClipNestLogicTests` / `ClipNestRegressionTests` / `PhotoCapturePipelineTests` / `TrashTests` | 既有行为不回归 |

---

## 13. 禁用项对照（§35）

| 禁用 | 状态 |
| --- | --- |
| Apple Foundation Models / Apple Intelligence | 不使用。`AppleFoundationNoteProvider.swift` 已删除 |
| Qwen3.5 VLM、1.7B+ | 不使用 |
| PaddleOCR / PP-OCR / Tesseract | 不使用，OCR 只有 Apple Vision |
| 大 embedding 模型 | 不新增（`bge-small-zh-v1.5` 推迟到第二阶段） |
| Ollama / Python 运行时 / llama.cpp server / 后台 HTTP 服务 | 不使用，纯 MLX Swift |
| 生产环境从 Hugging Face 下载 | 不使用，走自建 CDN 清单 |
| 350 MB 模型打进 IPA | 不打包，按需下载 |
