# ClipNest

An **AI-powered Markdown inbox for iPhone, iPad, and Mac**. Copy useful material in any app, open
ClipNest, and it becomes a structured, categorized note in a plain Markdown Vault. The underlying
folder remains compatible with [Obsidian](https://obsidian.md), Files, Finder, and other editors.
On the Mac it presents a **VS Code-style workspace** — activity bar, explorer, editor, and
**embedded terminals** — with a live Edit · Split · Preview editor and an extension marketplace.

[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20iPadOS%20%7C%20iOS-blue)](https://developer.apple.com)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange?logo=swift)](https://swift.org)
[![UI](https://img.shields.io/badge/UI-SwiftUI-0A84FF?logo=swift)](https://developer.apple.com/xcode/swiftui/)
[![Terminal](https://img.shields.io/badge/Terminal-SwiftTerm-2ea44f)](https://github.com/migueldeicaza/SwiftTerm)
[![Xcode](https://img.shields.io/badge/Xcode-26-1575F9?logo=xcode)](https://developer.apple.com/xcode/)
[![License](https://img.shields.io/badge/license-MIT-green)](#license)

<!-- App Store listing will be added when ClipNest is published. -->


![ClipNest — VS Code-style macOS workspace with explorer, rendered Markdown, and an embedded terminal](screenshot.png)

## Features

- 📁 **Open any folder as a vault** — fully compatible with your existing **Obsidian** vault. Notes
  are plain `.md` files; nothing is locked into a proprietary store.
- 📋 **Clipboard to note** — copy → open ClipNest → AI-generated title, summary, Markdown, tags,
  classification, and automatic save with Inbox fallback. With auto-detection off, the home
  screen's **Capture Clipboard** button captures the clipboard manually.
- 📷 **Photo to note** — on-device OCR (Vision, 中文 + English) turns the **latest library photo**
  or any photo you pick into the same organized note. No network needed for recognition.
- 🌳 **File & folder management** — sidebar tree with create / rename / delete for notes and folders.
- ✍️ **Live preview editor** — switch between **Edit**, **Split**, and **Preview**; autosaves as you type.
- 🖼 **Images, Bear‑style** — renders standard `![alt](path.png)` *and* Obsidian embeds `![[image.png]]`,
  resolved relative to the note or anywhere in the vault.
- 📊 **Tables, Notion‑style** — GitHub‑flavoured pipe tables render as clean, bordered grids.
- ✅ **Lists, checklists, code blocks, block quotes & headings** — the everyday Markdown you actually use.
- 🍏 **One codebase, three platforms** — SwiftUI multiplatform: macOS app, plus universal iPad / iPhone.
- 🌐 **English & 简体中文** — fully localized (String Catalog); follows the system language, with per-app language override supported.
- 🎨 **App icon switcher** — follow the system light/dark appearance or pin the day / night icon in Settings.

### 🖥 Mac: VS Code-style workspace

- 🧭 **Activity bar · Explorer · Editor · Terminal** — collapsible, **drag-resizable** panels and a
  single-row title bar with a centered command/search bar (⌘P quick-open, ⌘B side bar, ⌃\` terminal).
- 💻 **Embedded terminals** — multiple **tabbed** shells, each opening **in the vault directory**
  (powered by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)).
- ⚡ **Slash commands** — type `/` for Markdown snippets (heading, todo, table, code, link…) and emoji.
- ☑️ **Interactive todos** — click a checkbox in Preview to toggle it, Obsidian-style.
- 🧩 **Extension marketplace** — browse / install / uninstall extensions:
  - **Wiki (LLM)** — turn the vault into a [Karpathy-style](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)
    self-maintaining wiki (ingest → query → lint) driven by Claude Code in the terminal.
  - **GitHub** — sign in and commit/push your vault via the `gh` CLI.
- 🤖 **AI-friendly** — a `Tools/mdwiki` CLI plus `CLAUDE.md` / `AGENTS.md` let AI agents create and
  update Markdown content deterministically.

## Screenshots

| iPhone — Open a Vault | iPhone — Editor | iPad — Split + Preview |
| --- | --- | --- |
| ![Open Vault](screenshots/iphone-open-vault.png) | ![Editor](screenshots/iphone-editor.png) | ![Split](screenshots/ipad-split-preview.png) |

## Tech Stack

| Area | Choice |
| --- | --- |
| Language | Swift 5.9 |
| UI | SwiftUI (multiplatform: iOS 17+ / macOS 14+) |
| Markdown | Custom dependency‑free block parser + native SwiftUI rendering |
| Editor | `NSTextView` source editor with a `/` slash-command menu |
| Terminal | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) embedded login shells (macOS) |
| File access | Bookmarks (`fileImporter`); desktop build runs **non-sandboxed** for terminals |
| Tooling | `Tools/mdwiki` CLI · `CLAUDE.md` / `AGENTS.md` agent guides |
| Project gen | [XcodeGen](https://github.com/yonohub/XcodeGen) (`project.yml`) |

## Architecture

```
Sources/
├─ Clipboard/                 # pasteboard access, hashing, content analysis, URL seam
├─ AI/                        # OpenAI-compatible provider, config, prompt and JSON decoding
├─ Capture/                   # foreground capture coordinator and progress state
├─ Notes/                     # generated note model, classification, Markdown and safe names
├─ MarkdownVaultApp.swift   # @main App + macOS menu commands (⌘N / ⌘O)
├─ RootView.swift           # TabView: Vault · Settings (iOS) / VSCodeLayout (macOS)
├─ Theme.swift              # Brand tokens + reusable card surface
├─ VaultStore.swift         # ObservableObject: vault, file tree, CRUD, bookmarks, image resolution
├─ FileNode.swift           # File/folder tree model
├─ VaultView.swift          # NavigationSplitView: sidebar tree + detail
├─ MarkdownEditorView.swift # Edit · Split · Preview, insert tools, autosave
├─ MarkdownParser.swift     # GFM-ish block parser
├─ MarkdownPreview.swift    # Native rendering (images, tables, lists, code…)
├─ AppIconManager.swift     # Light/dark app-icon preference (system · day · night)
└─ SettingsView.swift       # Vault, Clipboard, AI, classification and display preferences
Resources/SampleVault/      # Bundled onboarding vault (notes + image)
```

## Getting Started

Requirements: **macOS 14+**, **Xcode 26+**, and [XcodeGen](https://github.com/yonohub/XcodeGen)
(`brew install xcodegen`).

```bash
git clone https://github.com/alfredang/markdownapp.git
cd markdownapp
xcodegen generate           # creates ClipNest.xcodeproj from project.yml
open ClipNest.xcodeproj     # build & run for My Mac, an iPad, or an iPhone
```

Run from the command line instead:

```bash
# macOS
xcodebuild -scheme ClipNest -destination 'platform=macOS' build
# iOS Simulator
xcodebuild -scheme ClipNest -destination 'platform=iOS Simulator,name=iPhone 17' build
```

On first launch the app opens a bundled **Sample Vault** so you can explore immediately. Use
**Open Folder…** to point it at your own (or Obsidian) vault.

## Obsidian Compatibility

ClipNest reads and writes the same plain files Obsidian does — point both apps at the same folder
and they stay in sync on disk. Image embeds use Obsidian's `![[file]]` shorthand as well as
standard Markdown, so notes render the same in either app.

## Developer

**Tertiary Infotech Academy Pte Ltd** — [tertiaryinfotech.com](https://www.tertiaryinfotech.com)

## License

MIT

---

## 👨‍💻 作者的其他开源项目

**[MacPilot](https://github.com/misswell/MacPilot)** —— 开源 macOS 菜单栏效率工具箱（Swift 原生 · 零第三方依赖）：应用自动退出规则、BLE 靠近解锁、窗口切换器、剪贴板历史、平滑滚动、画中画、录屏、截图贴图等 11 合 1，Apple 公证签名，[免费下载](https://github.com/misswell/MacPilot/releases/latest)。觉得有用欢迎点个 Star ⭐
