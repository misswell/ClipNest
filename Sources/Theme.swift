import SwiftUI

/// Single source of truth for the brand palette. Reference these tokens everywhere,
/// never raw `Color` literals (see the `mobile-ios-design` skill).
enum Theme {
    static let primary = Color(hex: 0x7C5CFF)     // violet — Obsidian-flavoured accent
    static let secondary = Color(hex: 0x4C8DFF)   // blue — links / selected
    static let highlight = Color(hex: 0xFFB020)   // amber — badges / highlights

    // The macOS shell is always dark, where the violet accent reads as low-contrast.
    // Use white there for legible buttons/controls; keep the brand violet on iOS.
    #if os(macOS)
    static let accent = Color.white
    #else
    static let accent = primary
    #endif

    #if os(macOS)
    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .underPageBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    #else
    static let background = Color(uiColor: .systemBackground)
    static let surface = Color(uiColor: .secondarySystemBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    #endif

    static let ink = Color.primary
    static let mutedInk = Color.secondary
    static let hairline = Color.primary.opacity(0.08)
}

/// Desktop editor chrome tokens. A refined dark theme with a violet brand accent —
/// flatter and quieter than the old VS Code "Dark Modern" blue, with softer white-alpha
/// hairlines so the chrome reads as one continuous surface instead of hard-edged panels.
enum VSCode {
    static let accent      = Theme.primary          // brand violet for active states
    static let editorBg    = Color(hex: 0x1E1E23)
    static let sidebarBg   = Color(hex: 0x18181C)
    static let activityBg  = Color(hex: 0x141417)
    static let panelBg     = Color(hex: 0x17171B)
    static let tabBarBg    = Color(hex: 0x17171B)
    static let tabActiveBg = Color(hex: 0x1E1E23)   // active tab merges into the editor
    static let statusBarBg = Color(hex: 0x121215)
    static let overlayBg   = Color(hex: 0x222228)   // floating palettes / popovers
    static let border      = Color.white.opacity(0.08)
    static let fg          = Color(hex: 0xD4D4D8)
    static let muted       = Color(hex: 0x8E8E96)
    static let activeIcon  = Color(hex: 0xECEDF2)
    static let hoverBg     = Color.white.opacity(0.05)
    static let fieldBg     = Color.white.opacity(0.07)   // text fields on the dark chrome
    static let selectionBg = Theme.primary.opacity(0.32)   // explorer selected row

    // Terminal colors (sRGB components, 0-1)
    static let termBg:    (r: Double, g: Double, b: Double) = (0x1E/255, 0x1E/255, 0x23/255)
    static let termFg:    (r: Double, g: Double, b: Double) = (0xD4/255, 0xD4/255, 0xD8/255)
    static let termCaret: (r: Double, g: Double, b: Double) = (0xAE/255, 0xAF/255, 0xAD/255)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

/// Reusable elevated card surface — white/elevated, continuous corners, hairline border.
/// Sizes come from `AppMetrics` so every card in the app shares one radius and inset.
struct AppCard: ViewModifier {
    var padding: CGFloat = AppMetrics.cardPadding
    var radius: CGFloat = AppMetrics.cardRadius

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.hairline)
            )
    }
}

extension View {
    func appCard(padding: CGFloat = AppMetrics.cardPadding,
                 radius: CGFloat = AppMetrics.cardRadius) -> some View {
        modifier(AppCard(padding: padding, radius: radius))
    }
}
