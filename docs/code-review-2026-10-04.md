# ClipNest 代码审查与修复记录

后续更新（2026-10-05）：本文保留首轮审查记录。其中移动链接、内部链接与重命名同步已继续实现；当前功能范围和验证结果见 [Obsidian 对照记录](obsidian-compatibility-2026-10-05.md)。

审查日期：2026-10-04。范围为 `Sources/` 的 97 个 Swift 文件、相关测试与本次改动。全局检查后重点追踪文件操作、编辑保存、导航、搜索索引、回收站、模型下载和扩展命令的实际调用路径。本次未提交、推送或发布，未改动已有的 `Promo/`。

## 已处理的问题

| 优先级 | 原问题及触发方式 | 修复后的行为 | 主要位置 |
| --- | --- | --- | --- |
| P1 | 编辑中的文件重命名、移动或删除时，排队保存可能写回旧路径，重新生成旧文件；连续移动后编辑器仍持有旧 URL | 保存先入同一文件协调队列，跟踪移动路径与写入版本，只更新仍存在的文档；重命名文件夹时同步更新其后代文档路径 | `VaultFileAccess.swift`、`VaultStore.swift`、两个编辑器 |
| P1 | 回收站失败后继续永久删除；清单写入失败时文件与清单不一致 | 删除失败保留文件并显示错误；移入/恢复后的清单写入失败会回滚；清空、过期清理保留未成功删除的记录 | `Trash.swift`、`VaultStore.swift` |
| P1 | 新建失败后仍可能选中不存在的文件；文件名可以带路径或指向 vault 外部 | 新建采用独占创建，校验文件名与操作边界，失败不改变选中项并显示错误 | `VaultStore.swift`、`VaultFileAccess.swift` |
| P1 | 扩展命令中的提示词、笔记路径或提交信息包含 `$()`、反引号等时被 shell 解释 | 用统一的 POSIX 单引号转义传递参数 | `ShellArgument.swift`、`ExtensionPanels.swift` |
| P2 | 笔记详情缺少修改标题入口，移动入口不完整；重命名失败后难以纠正输入 | iOS 详情“更多”中提供重命名、移动和删除；iOS 文件树与 macOS 文件树共用重命名表单，保留扩展名，错误时保留输入 | `RenameItemView.swift`、`MarkdownEditorView.swift`、`VaultView.swift`、`ExplorerSidebar.swift` |
| P2 | 重命名或删除后，时间线导航、桌面标签页仍使用旧路径 | 同步更新导航和标签页；删除后返回列表；更换 vault 后清理旧路径 | `DocumentTimelineView.swift`、`VSCodeLayout.swift` |
| P2 | 预览待办无法可靠修改，代码块中的示例可能影响勾选序号 | iOS 支持预览勾选；两端都按实际渲染的待办映射源文本，跳过代码、引用等内容，保留缩进与原文 | `MarkdownParser.swift`、两个编辑器 |
| P2 | 文件变更与搜索索引不同步；取消全量索引可能删除尚未扫描的条目；切换 vault 后旧任务回写状态 | 成功落盘后通知索引；取消不清除未访问条目；取消旧任务并校验当前 indexer 身份 | `LocalSearchController.swift`、`LocalSearchIndexer.swift`、`VaultStore.swift` |
| P2 | 模型下载遇到空响应或短响应反复重试；校验失败保留损坏暂存文件 | 空/短响应明确失败，校验失败清理损坏暂存文件，重试重新下载 | `LocalModelDownloader.swift` |
| P2 | Wiki 初始化忽略写入错误，仍显示成功，也可能覆盖已有内容 | 初始化抛出错误并显示失败，已有文件保留，写入通过文件访问层 | `ExtensionPanels.swift` |

“修改标题”当前修改的是笔记文件名和界面导航标题。正文中的 `# 一级标题` 保持作为 Markdown 内容独立编辑；重命名不会自动改写正文。

## 仍未完整实现的功能

这些条目来自实际代码，不能视为本次已完成。

### P2：移动文档后的相对链接维护

`VaultStore.moveDocument` 负责文件移动，没有重写 Markdown 相对链接。`MarkdownNoteBuilder.embedLine` 为采集笔记生成 `../Attachments/...`，其假设是笔记处于 vault 根目录下一层。移动到不同深度后，这个路径可能失效；现有图片解析回退也不能保证重名附件的选择正确。

建议后续把“解析链接、移动文件、重写相对目标、恢复失败”作为同一操作实现，覆盖普通图片、普通链接、代码块排除、重名附件和跨层文件夹移动。涉及改写用户正文，需先确定支持的语法与失败恢复方式。

### P2：Obsidian 内部链接与重命名同步

`MarkdownPreview.inline` 当前只移除 `[[`、`]]` 以显示文本，尚未实现点击打开内部笔记，也没有在重命名时维护其他笔记的引用。`[[Note|Alias]]` 等语法也需要完整解析，不能通过字符串替换实现。

建议统一处理内部链接、别名、标题锚点和重名笔记，并使用索引查找反向引用；重命名时应支持预览受影响文件及协调写入失败后的恢复。

### P3：网页正文提取

`Clipboard/WebContentExtractor.swift` 只有预留协议；当前采集流程将 URL 本身交给 provider，不抓取、清洗文章正文。此处不是“已实现但偶尔失败”的功能，而是明确保留的后续能力。

建议先确定是否允许联网抓取及本地模式的行为，再补 HTTP 状态、超时、重定向、正文清洗与失败回退。当前不能宣传为完整网页正文剪藏。

## 验证结果

- macOS Debug 构建成功。
- macOS 测试执行 388 项：0 失败，1 项因当前构建已链接 MLX 而跳过。真实模型推理测试 `QwenLiveInferenceTests` 本次主动排除，未声称验证模型推理效果。
- iPhone 17 Pro / iOS 26.3.1 模拟器验证了 6 个界面场景：详情删除返回、时间线删除返回、重命名后标题/文件树/扩展名同步、切换标签页回列表、非法名称错误提示、图片全屏预览。前 4 项与后 2 项分两次测试通过；并非同一次完整 UI 套件全绿。
- 新增回归测试覆盖保存与重命名/连续移动/删除/同名复用的顺序、文件名边界、失败回滚、搜索取消和切换 vault、待办源行映射、shell 参数转义、Wiki 初始化失败及下载损坏后的重试。
- `git diff --check` 通过。
- UI 调试期间曾发现本次补丁把删除检查误放进加载函数；已纠正，并恢复模拟器中受影响的 9 个笔记，随后重新验证。未部署至真机。

未验证真实 iCloud 占位文件冲突、真机交互和发行签名/公证。测试通过表明上述路径的回归检查通过，不代表所有功能已经完善。

## 本地验证证据

- macOS 构建：`/tmp/clipnest-review-build-final.log`
- macOS 测试：`/tmp/clipnest-review-tests-final.log`
- iOS 前 4 项通过记录：`/tmp/clipnest-review-ios-final.log`（此轮图片场景失败，随后修正测试查找并单独通过）
- iOS 错误提示与图片预览通过记录：`/tmp/clipnest-review-ui-signed-checks.log`
- 最新 UI 结果：`/tmp/clipnest-review-ios/Logs/Test/Test-ClipNestUI-2026.10.04_23-46-28-+0800.xcresult`

`/tmp` 证据为本机临时产物，可能被系统清理。
